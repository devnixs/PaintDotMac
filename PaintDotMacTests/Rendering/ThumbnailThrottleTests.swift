import Foundation
import Testing

@testable import PaintDotMac

/// `ThumbnailThrottle` (spec 0025 item 6): leading-edge renders, one coalesced trailing
/// render at `lastStart + 0.25`, on an injected clock.
struct ThumbnailThrottleTests {
    @Test func leadingEdgeAndCoalescedTrailing() {
        var throttle = ThumbnailThrottle()
        // t = 0: no render yet → leading edge.
        #expect(throttle.requestRender(now: 0) == .renderNow)
        throttle.didStartRender(at: 0)
        // Inside the window: one trailing render at 0.25; repeated requests coalesce
        // into the *same* scheduled time.
        #expect(throttle.requestRender(now: 0.1) == .scheduleAt(0.25))
        #expect(throttle.requestRender(now: 0.2) == .scheduleAt(0.25))
        throttle.didStartRender(at: 0.25)
        // Inside the new window: schedule at 0.5…
        #expect(throttle.requestRender(now: 0.3) == .scheduleAt(0.5))
        // …and at 0.6 (≥ 0.25 after 0.25) the leading edge fires again.
        #expect(throttle.requestRender(now: 0.6) == .renderNow)
    }

    @Test func exactlyMinimumIntervalRendersNow() {
        var throttle = ThumbnailThrottle()
        throttle.didStartRender(at: 1.0)
        #expect(throttle.requestRender(now: 1.25) == .renderNow)
        #expect(ThumbnailThrottle.minimumInterval == 0.25)
    }
}
