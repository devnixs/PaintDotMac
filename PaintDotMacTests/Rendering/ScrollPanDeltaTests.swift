import CoreGraphics
import Testing
@testable import PaintDotMac

/// View space is bottom-left (y up), so the y component of a scrolling delta is negated
/// (positive scrollingDeltaY must move the content *down*).
@Suite(.serialized)
struct ScrollPanDeltaTests {
    @Test func precisePassesThrough() {
        let d = ScrollPanDelta.viewDelta(scrollingDeltaX: 3, scrollingDeltaY: -4, isPrecise: true)
        #expect(d == CGVector(dx: 3, dy: 4))
    }

    @Test func nonPreciseUsesLinePoints() {
        let d = ScrollPanDelta.viewDelta(scrollingDeltaX: 1, scrollingDeltaY: -2, isPrecise: false)
        #expect(d == CGVector(dx: 10, dy: 20))
    }

    @Test func positiveDeltaYMovesContentDown() {
        let d = ScrollPanDelta.viewDelta(scrollingDeltaX: 0, scrollingDeltaY: 5, isPrecise: true)
        #expect(d == CGVector(dx: 0, dy: -5))
    }

    @Test func nonFiniteBecomesZero() {
        let d = ScrollPanDelta.viewDelta(scrollingDeltaX: .nan, scrollingDeltaY: .infinity,
                                         isPrecise: true)
        #expect(d == .zero)
    }
}
