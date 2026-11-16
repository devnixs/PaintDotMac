import XCTest

@testable import PaintDotMac

/// Spec 0017 *Performance* (Debug test run): one contiguous, antialiased Paint Bucket
/// click on a 4000 × 3000 opaque white layer — flood, coverage, compose, and the
/// `TileDiff` together. No PRD §6 target applies to a tool click; the gate is 5 s (a
/// gross-regression guard) and the measured number goes into the Verification status.
/// The coverage map is per-tile, so memory stays bounded by the touched tiles (NF-4:
/// the diff stores the changed tiles only). Nothing here is on the display path.
final class PaintBucketPerformanceTests: XCTestCase {
    private func timed(_ label: String, _ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let duration = start.duration(to: .now)
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        print("PaintBucketPerformance \(label): \(seconds)s")
        return seconds
    }

    @MainActor
    private func clickContext() -> FakeToolContext {
        FakeToolContext(size: PixelSize(width: 4000, height: 3000), background: .white)
    }

    @MainActor
    private func click(_ context: FakeToolContext) {
        let tool = PaintBucketTool()
        tool.mouseDown(ToolEvent(location: CGPoint(x: 2000.5, y: 1500.5),
                                 viewLocation: .zero, button: .primary, modifiers: [],
                                 clickCount: 1, pressure: 1, timestamp: 0),
                       context: context)
    }

    @MainActor
    func testLargeContiguousFill() throws {
        // `measure` gets a fresh white fixture per iteration: the fill is one step, so
        // re-clicking the same context would time a no-op.
        measure {
            click(clickContext())
        }
        let seconds = timed("contiguous AA click 4000 × 3000") {
            click(clickContext())
        }
        XCTAssertLessThan(seconds, 5.0, "Debug whole-image bucket click + diff")
    }
}
