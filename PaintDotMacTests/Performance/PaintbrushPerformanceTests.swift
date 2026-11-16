import XCTest

@testable import PaintDotMac

/// NF-1 (spec 0009): one stroke segment processed well within a frame on a 4000×3000
/// layer, gated at 3× the 16 ms frame budget (48 ms). `measure` tracks a baseline for
/// Xcode; the gated numbers are the explicit wall-time statistics below, recorded in the
/// spec's Verification status (0048 tightens to the real targets).
final class PaintbrushPerformanceTests: XCTestCase {

    private static let seed: UInt64 = 0x0009_0009_0009_0009

    /// 4000×3000 opaque layer, every tile materialised, filled with seeded noise
    /// (1 MiB SplitMix64 block tiled; deterministic).
    private func noisyImage() -> LayeredImage {
        let width = 4000, height = 3000
        var rng = SeededRandom(seed: Self.seed)
        let blockSide = 512
        var block = [UInt8](repeating: 0, count: blockSide * blockSide * 4)
        for offset in stride(from: 0, to: block.count, by: 4) {
            block[offset] = rng.byte()
            block[offset + 1] = rng.byte()
            block[offset + 2] = rng.byte()
            block[offset + 3] = 255
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for row in 0..<height {
            var column = 0
            while column < width {
                let chunkWidth = min(blockSide, width - column)
                let rowStart = (row % blockSide) * blockSide * 4
                for x in 0..<chunkWidth {
                    let pixel = rowStart + x * 4
                    bytes.append(contentsOf: block[pixel..<pixel + 4])
                }
                column += chunkWidth
            }
        }
        let surface = bytes.withUnsafeBytes { raw in
            TiledSurface(size: PixelSize(width: width, height: height),
                         rgba8: raw, bytesPerRow: width * 4)
        }
        return LayeredImage(surface: surface)
    }

    /// 240 seeded smooth-path points ~8 px apart spanning several tiles horizontally.
    private func pathPoints() -> [CGPoint] {
        var rng = SeededRandom(seed: Self.seed &+ 240)
        var points: [CGPoint] = []
        points.reserveCapacity(240)
        for index in 0..<240 {
            let x = 300 + Double(index) * 7.5 + rng.double(in: -0.5...0.5)
            let y = 1500 + 400 * sin(Double(index) / 25) + rng.double(in: -0.5...0.5)
            points.append(CGPoint(x: x, y: y))
        }
        return points
    }

    /// Runs one full stroke with `options`, timing every `extend` (coverage + compose +
    /// generation bump; no GPU upload). Returns (mean, p95, max) milliseconds.
    private func strokeLatencyStats(width: Double, hardness: Int,
                                    antialiasing: Bool) -> (mean: Double, p95: Double, max: Double) {
        let image = noisyImage()
        let options = BrushOptions(width: width, hardness: hardness,
                                   antialiasing: antialiasing, blendMode: .normal).clamped()
        var stroke = BrushStroke(
            canvasSize: image.size, options: options, clipMask: nil,
            compose: PaintbrushTool.paintbrushCompose(color: .black, blendMode: .normal))
        var surface = image.layers[0].surface
        let points = pathPoints()

        var timings: [Double] = []
        timings.reserveCapacity(points.count)
        _ = stroke.begin(at: points[0], on: &surface)
        for point in points.dropFirst() {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = stroke.extend(to: point, on: &surface)
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let sorted = timings.sorted()
        let mean = timings.reduce(0, +) / Double(timings.count)
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        return (mean, p95, sorted.last ?? 0)
    }

    private func assertFrameBudget(_ stats: (mean: Double, p95: Double, max: Double),
                                   label: String) {
        print("PaintbrushPerformanceTests.\(label): mean \(String(format: "%.3f", stats.mean)) ms, "
              + "p95 \(String(format: "%.3f", stats.p95)) ms, max \(String(format: "%.3f", stats.max)) ms")
        XCTAssertLessThanOrEqual(stats.mean, 48, "\(label): mean segment latency over the 48 ms NF-1 gate")
        XCTAssertLessThanOrEqual(stats.p95, 48, "\(label): p95 segment latency over the 48 ms NF-1 gate")
    }

    func testStrokeSegmentLatencyWidth50() {
        assertFrameBudget(strokeLatencyStats(width: 50, hardness: 75, antialiasing: true),
                          label: "width 50, hardness 75, AA")
    }

    func testStrokeSegmentLatencyWidth300() {
        assertFrameBudget(strokeLatencyStats(width: 300, hardness: 0, antialiasing: true),
                          label: "width 300, hardness 0, AA")
    }

    /// Timing only (no gate): `makeTileDiff` + history commit after a width-300 stroke.
    func testCommitDiffCost() {
        let image = noisyImage()
        let options = BrushOptions(width: 300, hardness: 0, antialiasing: true,
                                   blendMode: .normal).clamped()
        var stroke = BrushStroke(
            canvasSize: image.size, options: options, clipMask: nil,
            compose: PaintbrushTool.paintbrushCompose(color: .black, blendMode: .normal))
        var surface = image.layers[0].surface
        let points = pathPoints()
        _ = stroke.begin(at: points[0], on: &surface)
        for point in points.dropFirst() { _ = stroke.extend(to: point, on: &surface) }
        let layerID = image.layers[0].id

        let diffStart = DispatchTime.now().uptimeNanoseconds
        let diff = stroke.makeTileDiff(from: surface, layerID: layerID)
        // Same `LayeredImage` identity: the diff's entries name `image.layers[0].id`, so
        // the live state must carry that exact layer (a fresh `LayeredImage(surface:)`
        // would mint a new id and break the history invariant).
        var paintedImage = image
        paintedImage.layers[0].surface = surface
        var live = DocumentState(image: paintedImage)
        var stack = HistoryStack(base: .openImage)
        stack.perform(TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush, diff: diff),
                      on: &live)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - diffStart) / 1_000_000
        print("PaintbrushPerformanceTests.testCommitDiffCost: "
              + String(format: "%.1f ms (byteCost %d)", elapsed, diff.byteCost))
    }

    /// Baseline block for Xcode's performance tracking: a short width-50 stroke on a
    /// private 1024×1024 surface (self-contained per iteration; measure runs concurrently).
    func testMeasureShortStroke() {
        measure {
            var surface = TiledSurface(size: PixelSize(width: 1024, height: 1024))
            surface.fill(.white)
            var stroke = BrushStroke(
                canvasSize: PixelSize(width: 1024, height: 1024),
                options: BrushOptions(width: 50, hardness: 75, antialiasing: true,
                                      blendMode: .normal),
                clipMask: nil,
                compose: PaintbrushTool.paintbrushCompose(color: .black, blendMode: .normal))
            _ = stroke.begin(at: CGPoint(x: 200, y: 512), on: &surface)
            for index in 1..<24 {
                _ = stroke.extend(to: CGPoint(x: 200 + Double(index) * 8,
                                              y: 512 + 40 * sin(Double(index) / 4)),
                                  on: &surface)
            }
        }
    }
}
