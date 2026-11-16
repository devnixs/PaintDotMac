import XCTest

@testable import PaintDotMac

/// NF-1 smoothness support for spec 0014: the mouse-up mask build of a full-canvas
/// rectangle selection on 10,000 × 10,000 (0013's rectangle fast path — every tile
/// `.full`, no pixel bytes). Reported for the spec's Verification status; 0013 sets
/// explicit targets only for 4000 × 3000, so this has no gate.
final class SelectionToolPerformanceTests: XCTestCase {

    private static let size = PixelSize(width: 10_000, height: 10_000)

    /// One `RectangleSelectTool.mouseUp` on a 10,000 × 10,000 image.
    @MainActor
    func testRectangleMouseUp10000x10000() {
        let context = FakeToolContext(size: Self.size)
        let tool = RectangleSelectTool()
        func event(_ x: Double, _ t: TimeInterval) -> ToolEvent {
            ToolEvent(location: CGPoint(x: x, y: x), viewLocation: .zero, button: .primary,
                      modifiers: [], clickCount: 1, pressure: 1, timestamp: t)
        }

        var timings: [Double] = []
        for _ in 0..<3 {
            tool.mouseDown(event(0.5, 1.0), context: context)
            tool.mouseDragged(event(5_000.5, 1.1), context: context)
            let start = DispatchTime.now().uptimeNanoseconds
            tool.mouseUp(event(9_999.5, 1.3), context: context)
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            // Undo for the next round: same cost with the selection gone.
            context.navigateForTests { history, state in _ = history.undo(&state) }
        }
        let median = timings.sorted()[timings.count / 2]
        print("SelectionToolPerformanceTests.rectangleMouseUp10000x10000: "
            + "\(String(format: "%.3f", median)) ms (reported, no gate)")
    }
}
