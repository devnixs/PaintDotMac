import CoreGraphics
import Foundation

/// The temporary-pan (hold Space) state machine (spec 0004, CAN-2; 0006's `CanvasInputRouter`
/// and Pan tool reuse it unchanged). Paint.NET rule: releasing Space mid-drag does *not* end
/// the drag — the pan ends on mouse up.
struct SpacePanState: Equatable {
    enum Phase: Equatable {
        case idle
        /// Space held; the next mouse down pans.
        case armed
        /// Space held, dragging.
        case panning
        /// Dragging, Space released mid-drag.
        case panningSpaceReleased
    }

    enum PanCursor: Equatable {
        case none
        case openHand
        case closedHand
    }

    private(set) var phase: Phase = .idle

    mutating func spaceDown(isRepeat: Bool) {
        guard !isRepeat, phase == .idle else { return }
        phase = .armed
    }

    mutating func spaceUp() {
        switch phase {
        case .armed: phase = .idle
        case .panning: phase = .panningSpaceReleased
        case .idle, .panningSpaceReleased: break
        }
    }

    /// Returns `true` when this drag pans (phase `armed`). Otherwise the phase is unchanged
    /// and the caller routes the click elsewhere (in 0004 a plain drag does nothing).
    mutating func mouseDown() -> Bool {
        guard phase == .armed else { return false }
        phase = .panning
        return true
    }

    mutating func mouseUp() {
        switch phase {
        case .panning: phase = .armed  // Space still held
        case .panningSpaceReleased: phase = .idle
        case .idle, .armed: break
        }
    }

    /// Window resigns key, app deactivates, document closes: never stay stuck in pan mode.
    mutating func reset() { phase = .idle }

    var isPanning: Bool { phase == .panning || phase == .panningSpaceReleased }

    var cursor: PanCursor {
        switch phase {
        case .idle: return .none
        case .armed: return .openHand
        case .panning, .panningSpaceReleased: return .closedHand
        }
    }
}

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
