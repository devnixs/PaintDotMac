import CoreGraphics
import Foundation

/// What finishing a selection drag does (Paint.NET `SelectionTool.Done`'s truth table,
/// spec 0014).
enum SelectionGestureOutcome: Equatable, Sendable {
    /// Record a step named after the tool with the combined selection.
    case emit
    /// Clear the selection — a "Deselect" step when one was set, nothing otherwise
    /// (Paint.NET's "click to deselect").
    case clear
    /// Change nothing and record nothing.
    case reset
}

/// The bookkeeping one selection-tool drag shares (Rectangle, Ellipse, and — 0015 — Lasso):
/// the mode latched at mouse-down, the pixel-inclusive anchor/current pair, and the
/// moved/quick/empty finish rule.
struct SelectionGesture: Sendable, Equatable {
    /// Paint.NET's `tooQuick`: a Replace-mode button held ≤ 50 ms is a click, not a drag.
    static let tooQuickInterval: TimeInterval = 0.05

    /// Latched at init from the button + modifiers (Paint.NET reads them once per drag).
    let mode: SelectionCombineMode
    let anchorPixel: PixelPoint
    let startTimestamp: TimeInterval
    private(set) var currentPixel: PixelPoint
    /// `false` until the pointer first enters a pixel other than the anchor. Deviates
    /// slightly from Paint.NET (which counts any mouse-move event): at high zoom a jittery
    /// click stays a click instead of becoming a 1 × 1 selection (PRD D-44c). Sticky
    /// afterwards, even if the pointer returns to the anchor.
    private(set) var hasMoved: Bool

    /// `nil` when `event.location` is not a finite, bounded canvas point.
    init?(event: ToolEvent, pickerMode: SelectionCombineMode) {
        guard let pixel = Self.pixel(for: event.location) else { return nil }
        mode = SelectionToolOptions.combineMode(picker: pickerMode, button: event.button,
                                                modifiers: event.modifiers)
        anchorPixel = pixel
        startTimestamp = event.timestamp
        currentPixel = pixel
        hasMoved = false
    }

    /// Ignores non-finite locations (the router already drops them; belt and braces).
    mutating func update(with event: ToolEvent) {
        guard let pixel = Self.pixel(for: event.location) else { return }
        currentPixel = pixel
        if pixel != anchorPixel { hasMoved = true }
    }

    /// The pixel under a canvas point — the same convention as 0004's status-bar cursor
    /// (floor: −0.5 → −1). `nil` for a non-finite coordinate or |value| > 10⁹, which also
    /// bounds every later `Int` computation.
    static func pixel(for canvasPoint: CGPoint) -> PixelPoint? {
        guard canvasPoint.x.isFinite, canvasPoint.y.isFinite,
              abs(canvasPoint.x) <= 1e9, abs(canvasPoint.y) <= 1e9 else { return nil }
        return PixelPoint(x: Int(canvasPoint.x.rounded(.down)),
                          y: Int(canvasPoint.y.rounded(.down)))
    }

    /// Paint.NET's finish rule (`SelectionTool.Done`): with `moved`, `tooQuick`
    /// (held ≤ 50 ms) and `shapeIsEmpty` (the shape is empty after clipping to the image) —
    /// Replace: emit only for a moved, unhurried drag over a non-empty shape; anything else
    /// clears. The append modes: a non-moved or empty shape resets (no step); else emit.
    static func outcome(mode: SelectionCombineMode, hasMoved: Bool,
                        duration: TimeInterval, shapeIsEmpty: Bool) -> SelectionGestureOutcome {
        if mode == .replace {
            return hasMoved && duration > tooQuickInterval && !shapeIsEmpty ? .emit : .clear
        }
        return !hasMoved || shapeIsEmpty ? .reset : .emit
    }
}

/// The two commit rules of every selection tool (spec 0014): finishing a drag and the
/// Enter-deselects rule.
@MainActor
enum SelectionCommit {
    /// `.emit`: `after = combine(current, newSelection, mode:)` and a step named after the
    /// tool; `.clear`: the exact "Deselect" step Edit > Deselect records, only when a
    /// selection existed; `.reset`: nothing.
    ///
    /// A result whose mask equals the current selection's (Union inside the selection,
    /// Exclude outside it) changes no pixel — no step is recorded (D-34). The check is by
    /// mask, the normative per-pixel value: `Selection.==` also compares the outline `CGPath`
    /// by `CFEqual`, and a CoreGraphics path boolean re-encodes even a geometrically
    /// unchanged outline, so `SelectionHistoryItem.isNoOp` alone would miss this case.
    static func finish(outcome: SelectionGestureOutcome, newSelection: Selection?,
                       mode: SelectionCombineMode, name: String, icon: HistoryIcon,
                       context: any ToolContext) {
        switch outcome {
        case .emit:
            let before = context.selection
            let after = Selection.combine(before, newSelection, mode: mode,
                                          canvasSize: context.image.size)
            guard before?.mask != after?.mask else { return }
            context.performHistory(SelectionHistoryItem(name: name, icon: icon,
                                                        before: before, after: after))
        case .clear:
            deselectIfNeeded(context: context)
        case .reset:
            break
        }
    }

    /// Paint.NET's "Ctrl + D or Enter": with a selection, record the Deselect step and
    /// return `true`; without one, return `false` and change nothing.
    @discardableResult
    static func deselectIfNeeded(context: any ToolContext) -> Bool {
        guard let selection = context.selection else { return false }
        context.performHistory(SelectionHistoryItem(name: "Deselect", icon: .deselect,
                                                    before: selection, after: nil))
        return true
    }
}

/// The status-bar selection size (APP-5): the live preview wins while a selection tool
/// drags (Paint.NET shows the size live), then the committed selection's tight bounds
/// (0013's `Selection.bounds`); `nil` = the field is empty.
enum SelectionSizeDisplay {
    static func size(preview: SelectionShapePreview?, selectionBounds: PixelRect?,
                     imageSize: PixelSize) -> PixelSize? {
        if let preview {
            let visible = preview.rect.intersection(
                PixelRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height))
            return visible.isEmpty ? nil : visible.size
        }
        return selectionBounds?.size
    }
}
