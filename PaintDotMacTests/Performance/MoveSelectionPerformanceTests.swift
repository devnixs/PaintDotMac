import XCTest

@testable import PaintDotMac

/// NF-1 support for spec 0019, on an 8000 × 6000 canvas with an ellipse selection
/// covering it: (a) an integer nudge through `Selection.transformed` (the pixel-exact
/// mask shift, whole tiles shared) and (b) a 30° rotation (full re-rasterization).
/// Gated at 3 s (a) and 10 s (b) in Debug; the medians are reported for the spec's
/// Verification status. Dragging itself never rasterizes — the overlay draws one path —
/// so per-frame cost (NF-1, ≤ 16 ms) is unaffected.
final class MoveSelectionPerformanceTests: XCTestCase {
    private static let size = PixelSize(width: 8_000, height: 6_000)

    @MainActor
    private func ellipseSelection() throws -> Selection {
        try XCTUnwrap(Selection(
            path: CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 8_000, height: 6_000),
                         transform: nil),
            canvasSize: Self.size, antialiased: true))
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// (a) Integer nudge → the mask shift. Gate: 3 s.
    @MainActor
    func testIntegerNudge8000x6000() throws {
        let selection = try ellipseSelection()
        let session = try XCTUnwrap(TransformSession(sourceBounds: CGRect(x: 0, y: 0,
                                                                         width: 8_000,
                                                                         height: 6_000)))
            .translatedBy(dx: 10, dy: -5)
        var elapsed: [Double] = []
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: options) {
            let start = DispatchTime.now().uptimeNanoseconds
            let moved = Selection.transformed(selection, by: session, antialiased: true)
            elapsed.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            withExtendedLifetime(moved) {}
        }
        let ms = median(elapsed)
        print("MoveSelectionPerformanceTests.integerNudge8000x6000: "
            + "\(String(format: "%.1f", ms)) ms (gate 3000 ms)")
        XCTAssertLessThanOrEqual(ms, 3_000)
    }

    /// (b) 30° rotation → re-rasterization. Gate: 10 s.
    @MainActor
    func testRotate30Degrees8000x6000() throws {
        let selection = try ellipseSelection()
        let center = CGPoint(x: 4_000, y: 3_000)
        let session = try XCTUnwrap(TransformSession(sourceBounds: CGRect(x: 0, y: 0,
                                                                         width: 8_000,
                                                                         height: 6_000)))
            .applying(.rotate, from: CGPoint(x: 8_000, y: 3_000),
                      to: CGPoint(x: center.x + 4_000 * cos(.pi / 6),
                                  y: center.y + 4_000 * sin(.pi / 6)),
                      modifiers: [])
        var elapsed: [Double] = []
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: options) {
            let start = DispatchTime.now().uptimeNanoseconds
            let turned = Selection.transformed(selection, by: session, antialiased: true)
            elapsed.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            withExtendedLifetime(turned) {}
        }
        let ms = median(elapsed)
        print("MoveSelectionPerformanceTests.rotate30Degrees8000x6000: "
            + "\(String(format: "%.1f", ms)) ms (gate 10000 ms)")
        XCTAssertLessThanOrEqual(ms, 10_000)
    }
}
