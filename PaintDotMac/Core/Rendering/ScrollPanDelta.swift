import CoreGraphics
import Foundation

/// Maps scroll-event deltas to a content delta in view points (spec 0004, CAN-2). AppKit has
/// already applied the natural-scrolling setting: positive `scrollingDeltaY` must move the
/// content down. View space is bottom-left (y up), hence the negation. Precise deltas are
/// points; non-precise (mouse wheel) deltas are lines scaled by `linePoints`.
enum ScrollPanDelta {
    /// Points per wheel line, matching AppKit's own legacy scroll line height.
    static let linePoints: Double = 10

    static func viewDelta(scrollingDeltaX: Double, scrollingDeltaY: Double, isPrecise: Bool) -> CGVector {
        let k = isPrecise ? 1.0 : linePoints
        return CGVector(
            dx: (scrollingDeltaX.isFinite ? scrollingDeltaX : 0) * k,
            dy: (scrollingDeltaY.isFinite ? scrollingDeltaY : 0) * -k
        )
    }
}
