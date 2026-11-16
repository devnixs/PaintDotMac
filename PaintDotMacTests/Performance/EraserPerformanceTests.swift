import XCTest

@testable import PaintDotMac

/// NF-1 (spec 0011): the Eraser shares 0009's `BrushStroke`, so its per-event cost is the
/// brush sweep with the destination-out compose — a 4000×3000 opaque layer, width 50,
/// antialiasing on, a 200-point diagonal drag, gated at 3× the 16 ms frame budget (48 ms)
/// on mean and p95 `mouseDragged` latency (the 0009 `PaintbrushPerformanceTests`
/// convention; 0048 tightens to the real targets). The Pencil's per-event cost is
/// O(segment length) and needs no perf test.
@MainActor
final class EraserPerformanceTests: XCTestCase {

    private static let seed: UInt64 = 0x0011_0011_0011_0011

    /// 4000×3000 opaque layer, every tile materialised, filled with seeded noise
    /// (the 0009 perf test's 1 MiB SplitMix64 block tiled; deterministic).
    private func noisyContext() -> FakeToolContext {
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
        let context = FakeToolContext(size: PixelSize(width: width, height: height))
        let image = LayeredImage(surface: surface)
        context.updateImage { $0 = image }
        return context
    }

    /// 200 diagonal points ~20 px apart, top-left to bottom-right.
    private func diagonalPoints() -> [CGPoint] {
        (0..<200).map { index in
            CGPoint(x: 100.0 + Double(index) * 19.0, y: 100.0 + Double(index) * 14.0)
        }
    }

    private func event(_ location: CGPoint) -> ToolEvent {
        ToolEvent(location: location, viewLocation: location, button: .primary,
                  modifiers: [], clickCount: 1, pressure: 1, timestamp: 0)
    }

    /// Runs one full Eraser stroke through `mouseDragged`, timing every event.
    private func dragLatencyStats() -> (mean: Double, p95: Double, max: Double) {
        let context = noisyContext()
        context.options.setValue(50.0, for: BrushOptions.keys(for: .eraser).width)
        context.options.setValue(75, for: BrushOptions.keys(for: .eraser).hardness)
        context.options.setValue(true, for: BrushOptions.keys(for: .eraser).antialiasing)
        let tool = EraserTool()
        tool.activate(context: context)
        let points = diagonalPoints()
        tool.mouseDown(event(points[0]), context: context)

        var timings: [Double] = []
        timings.reserveCapacity(points.count - 1)
        for point in points.dropFirst() {
            let start = DispatchTime.now().uptimeNanoseconds
            tool.mouseDragged(event(point), context: context)
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        tool.mouseUp(event(points[points.count - 1]), context: context)
        let sorted = timings.sorted()
        let mean = timings.reduce(0, +) / Double(timings.count)
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        return (mean, p95, sorted.last ?? 0)
    }

    func testDragEventLatencyWidth50() {
        let stats = dragLatencyStats()
        print("EraserPerformanceTests.testDragEventLatencyWidth50: "
              + "mean \(String(format: "%.3f", stats.mean)) ms, "
              + "p95 \(String(format: "%.3f", stats.p95)) ms, "
              + "max \(String(format: "%.3f", stats.max)) ms")
        XCTAssertLessThanOrEqual(stats.mean, 48, "mean mouseDragged latency over the 48 ms NF-1 gate")
        XCTAssertLessThanOrEqual(stats.p95, 48, "p95 mouseDragged latency over the 48 ms NF-1 gate")
    }

    /// Baseline block for Xcode's performance tracking: a short width-50 erase stroke on
    /// a private 1024×1024 surface (self-contained per iteration).
    func testMeasureShortStroke() {
        measure {
            var surface = TiledSurface(size: PixelSize(width: 1024, height: 1024))
            surface.fill(.white)
            var stroke = BrushStroke(
                canvasSize: PixelSize(width: 1024, height: 1024),
                options: BrushOptions(width: 50, hardness: 75, antialiasing: true,
                                      blendMode: .normal),
                clipMask: nil,
                compose: EraserTool.eraseCompose(strength: 255))
            _ = stroke.begin(at: CGPoint(x: 200, y: 512), on: &surface)
            for index in 1..<24 {
                _ = stroke.extend(to: CGPoint(x: 200 + Double(index) * 8,
                                              y: 512 + 40 * sin(Double(index) / 4)),
                                  on: &surface)
            }
        }
    }
}
