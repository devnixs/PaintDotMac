import CoreGraphics
import XCTest

@testable import PaintDotMac

/// NF-1 / NF-4 for selections (spec 0013): Select All, ellipse rasterization, inversion,
/// and a clipped Paintbrush segment on 4000×3000, gated at 3× the targets (15 ms /
/// 300 ms / 150 ms / 0009's 48 ms per-event gate); numbers are printed for the spec's
/// Verification status (0048 tightens to the real targets).
final class SelectionPerformanceTests: XCTestCase {

    private static let size = PixelSize(width: 4000, height: 3000)
    private static let seed: UInt64 = 0x0013_0013_0013_0013

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Select All allocates only the full-tile descriptors and the canvas-rect path —
    /// it must not touch pixels (target 5 ms, gate 15 ms).
    func testSelectAll4000x3000() {
        var timings: [Double] = []
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            let selection = Selection.all(canvasSize: Self.size)
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            _ = selection.mask.partialTileCount
        }
        let value = median(timings)
        print("SelectionPerformanceTests.selectAll4000x3000: \(String(format: "%.3f", value)) ms (gate 15)")
        XCTAssertLessThanOrEqual(value, 15)
    }

    /// Rasterizing a full-canvas ellipse (192 tiles, AA coverage) — target 100 ms,
    /// gate 300 ms.
    func testRasterizeEllipse4000x3000() {
        let ellipse = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 4000, height: 3000),
                             transform: nil)
        var timings: [Double] = []
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let selection = Selection(path: ellipse, canvasSize: Self.size)
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertNotNil(selection)
        }
        let value = median(timings)
        print("SelectionPerformanceTests.rasterizeEllipse4000x3000: \(String(format: "%.3f", value)) ms (gate 300)")
        XCTAssertLessThanOrEqual(value, 300)
    }

    /// Inverting an ellipse selection flips every tile — target 50 ms, gate 150 ms.
    func testInvertEllipse4000x3000() {
        let ellipse = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 4000, height: 3000),
                             transform: nil)
        let selection = try? XCTUnwrap(Selection(path: ellipse, canvasSize: Self.size))
        var timings: [Double] = []
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let inverted = selection?.inverted()
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertNotNil(inverted)
        }
        let value = median(timings)
        print("SelectionPerformanceTests.invertEllipse4000x3000: \(String(format: "%.3f", value)) ms (gate 150)")
        XCTAssertLessThanOrEqual(value, 150)
    }

    /// 0009's width-50 segment benchmark with an ellipse selection installed: the clip
    /// lookup must keep every `extend` within the 48 ms gate.
    func testPaintbrushSegmentWithSelection() {
        let ellipse = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 4000, height: 3000),
                             transform: nil)
        let clipMask = (try? XCTUnwrap(Selection(path: ellipse, canvasSize: Self.size)))?.mask
        XCTAssertNotNil(clipMask, "the ellipse selection rasterized")

        var rng = SeededRandom(seed: Self.seed)
        let width = 4000, height = 3000
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for offset in stride(from: 0, to: bytes.count, by: 4) where rng.int(in: 0...31) == 0 {
            bytes[offset] = rng.byte()
            bytes[offset + 1] = rng.byte()
            bytes[offset + 2] = rng.byte()
        }
        let surface = bytes.withUnsafeBytes { raw in
            TiledSurface(size: PixelSize(width: width, height: height),
                         rgba8: raw, bytesPerRow: width * 4)
        }
        let options = BrushOptions(width: 50, hardness: 75, antialiasing: true,
                                   blendMode: .normal).clamped()
        var stroke = BrushStroke(
            canvasSize: PixelSize(width: width, height: height), options: options,
            clipMask: clipMask,
            compose: PaintbrushTool.paintbrushCompose(color: .black, blendMode: .normal))
        var painted = surface

        var pathPoints: [CGPoint] = []
        pathPoints.reserveCapacity(240)
        var pointRng = SeededRandom(seed: Self.seed &+ 240)
        for index in 0..<240 {
            let x = 300 + Double(index) * 7.5 + pointRng.double(in: -0.5...0.5)
            let y = 1500 + 400 * sin(Double(index) / 25) + pointRng.double(in: -0.5...0.5)
            pathPoints.append(CGPoint(x: x, y: y))
        }

        var timings: [Double] = []
        timings.reserveCapacity(pathPoints.count)
        _ = stroke.begin(at: pathPoints[0], on: &painted)
        for point in pathPoints.dropFirst() {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = stroke.extend(to: point, on: &painted)
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let sorted = timings.sorted()
        let mean = timings.reduce(0, +) / Double(timings.count)
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        print("SelectionPerformanceTests.paintbrushSegmentWithSelection: "
              + "mean \(String(format: "%.3f", mean)) ms, p95 \(String(format: "%.3f", p95)) ms "
              + "(gate 48)")
        XCTAssertLessThanOrEqual(mean, 48, "mean segment latency over the 48 ms NF-1 gate")
        XCTAssertLessThanOrEqual(p95, 48, "p95 segment latency over the 48 ms NF-1 gate")
    }

    /// Baseline block for Xcode's performance tracking: Select All on a private
    /// 1024×1024 canvas (self-contained per iteration).
    func testMeasureSelectAllSmall() {
        measure {
            let selection = Selection.all(canvasSize: PixelSize(width: 1024, height: 1024))
            _ = selection.mask.partialTileCount
        }
    }
}
