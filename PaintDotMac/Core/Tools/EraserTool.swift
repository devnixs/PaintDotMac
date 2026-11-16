import CoreGraphics
import Foundation

/// The Eraser (spec 0011; PRD T-12, D-27, D-38, TOOL-A, TOOL-C, H-6). A circular tip
/// rasterized entirely by 0009's `BrushStroke` — continuous segment sweep, hardness and
/// antialiasing profile, max-combined per-stroke coverage, the 0013 clip hook — with the
/// Paint.NET destination-out rule `EraseOps.erase` as its compose. One stroke is one
/// "Eraser" history step; pixels live in the document while the stroke runs and the
/// touched tiles become a `TileDiffHistoryItem` at commit (AGENTS rule 2).
///
/// Strength is the alpha of the color slot in use (T-12/D-27: primary for the left button,
/// secondary for right-/Control-left, captured at mouse-down for the whole stroke); the
/// RGB of that color is irrelevant and there is no blend mode. Options are the
/// Paintbrush's width/hardness/antialiasing under `tool.eraser.*`, independent of the
/// Paintbrush's values (TOOL-C).
@MainActor
final class EraserTool: Tool, BrushWidthAdjustable {
    let id: ToolID = .eraser

    /// One live stroke plus the layer it erases; options, strength, clip and compose are
    /// frozen inside the `BrushStroke` at mouse-down (the Paintbrush's pattern).
    private struct ActiveStroke {
        var stroke: BrushStroke
        let layerID: Layer.ID
    }

    private var activeStroke: ActiveStroke?
    /// Cached options for the outline/cursor; re-read at mouse-down and on
    /// `optionsDidChange` (the store is the source of truth). Its `blendMode` is ignored.
    private(set) var options = BrushOptions.default
    /// Last pointer location in canvas space; the outline and `[`/`]` need it to redraw.
    private var lastPointer: CGPoint?

    var hasPendingEdit: Bool { activeStroke != nil }

    // MARK: - Lifecycle

    func activate(context: any ToolContext) {
        options = BrushOptions.load(from: context.options, tool: id)
        outlineAtLastPointer(context: context)
    }

    /// Commits a pending stroke (0006's default behavior) and hides the outline (D-38).
    func deactivate(context: any ToolContext) {
        if hasPendingEdit { commit(context: context) }
        context.setOverlay(nil)
    }

    // MARK: - Pointer

    func mouseDown(_ event: ToolEvent, context: any ToolContext) {
        // A second button pressed while a stroke runs is ignored; the original button
        // decides the strength until mouse-up (0009's rule).
        guard activeStroke == nil else { return }
        lastPointer = event.location
        let options = BrushOptions.load(from: context.options, tool: id).clamped()
        self.options = options
        let strength = strokeStrength(for: event, context: context)
        let layerID = context.image.activeLayer.id
        let stroke = BrushStroke(canvasSize: context.image.size, options: options,
                                 clipMask: context.paintClipMask,
                                 compose: Self.eraseCompose(strength: strength))
        // The stroke exists even when the dab lands off-canvas; an empty diff records
        // nothing (H-6).
        var active = ActiveStroke(stroke: stroke, layerID: layerID)
        context.updateImage { image in
            guard let index = image.layerIndex(for: layerID) else { return }
            _ = active.stroke.begin(at: event.location, on: &image.layers[index].surface)
            activeStroke = active
        }
        outlineAtLastPointer(context: context)
    }

    func mouseDragged(_ event: ToolEvent, context: any ToolContext) {
        lastPointer = event.location
        extend(event.location, context: context)
        outlineAtLastPointer(context: context)
    }

    func mouseUp(_ event: ToolEvent, context: any ToolContext) {
        lastPointer = event.location
        guard activeStroke != nil else { return }
        extend(event.location, context: context)
        commit(context: context)
    }

    func mouseMoved(_ event: ToolEvent, context: any ToolContext) {
        lastPointer = event.location
        outlineAtLastPointer(context: context)
    }

    private func extend(_ point: CGPoint, context: any ToolContext) {
        guard var active = activeStroke else { return }
        let layerID = active.layerID
        context.updateImage { image in
            guard let index = image.layerIndex(for: layerID) else { return }
            _ = active.stroke.extend(to: point, on: &image.layers[index].surface)
            activeStroke = active
        }
    }

    /// T-12/D-27: strength = the alpha of the color slot the button selects (TOOL-A —
    /// right button and Control-left, which 0006's dispatcher delivers as `.secondary`,
    /// use the Secondary color's alpha; the `.primary` + `.control` pair is handled
    /// defensively, as on the Paintbrush). The RGB of the color is irrelevant.
    private func strokeStrength(for event: ToolEvent, context: any ToolContext) -> UInt8 {
        if event.button == .secondary
            || (event.button == .primary && event.modifiers.contains(.control)) {
            return context.colors.secondary.alpha
        }
        return context.colors.primary.alpha
    }

    /// The Eraser's compose rule: destination-out with the stroke's frozen strength and
    /// the pixel's effective (clipped) coverage. Overlapping dabs never compound — the
    /// engine always composes from the before-stroke pixel.
    nonisolated static func eraseCompose(strength: UInt8) -> BrushCompose {
        { before, coverage in EraseOps.erase(before, strength: strength, coverage: coverage) }
    }

    // MARK: - Commit / cancel

    /// Finishes an in-progress stroke exactly like `mouseUp` at the last point: a
    /// non-empty `TileDiff` becomes the "Eraser" step; an empty one — strength 0 or a
    /// stroke that changed nothing — records nothing (H-6/D-34).
    func commit(context: any ToolContext) {
        guard let active = activeStroke else { return }
        activeStroke = nil
        guard let index = context.image.layerIndex(for: active.layerID) else { return }
        let diff = active.stroke.makeTileDiff(from: context.image.layers[index].surface,
                                              layerID: active.layerID)
        context.commitHistory(TileDiffHistoryItem(name: "Eraser", icon: .eraser, diff: diff))
    }

    /// Escape during the gesture: the layer returns bit-identical to before mouse-down
    /// and no history step is recorded.
    func cancel(context: any ToolContext) {
        guard var active = activeStroke else { return }
        activeStroke = nil
        let layerID = active.layerID
        context.updateImage { image in
            guard let index = image.layerIndex(for: layerID) else { return }
            active.stroke.cancel(on: &image.layers[index].surface)
        }
    }

    // MARK: - Options & width stepping

    func optionsDidChange(context: any ToolContext) {
        options = BrushOptions.load(from: context.options, tool: id)
        // A change during a stroke applies to the next stroke only — the live stroke keeps
        // its frozen options; only the outline follows the new values.
        outlineAtLastPointer(context: context)
    }

    /// `[` / `]` (PRD §5.12, D-12): step by `delta` within 1…2000 and persist; the current
    /// stroke is unaffected. Writes only `tool.eraser.width` — the Eraser never stores
    /// `tool.eraser.blendMode` (D-27), so this must not go through `BrushOptions.save`.
    func adjustBrushWidth(by delta: Double, context: any ToolContext) {
        var updated = BrushOptions.load(from: context.options, tool: id)
        let base = updated.width.isFinite ? updated.width : BrushOptions.default.width
        updated.width = Swift.min(Swift.max(base + delta, BrushOptions.widthRange.lowerBound),
                                  BrushOptions.widthRange.upperBound)
        context.options.setValue(updated.width, for: BrushOptions.keys(for: id).width)
        options = updated.clamped()
        outlineAtLastPointer(context: context)
    }

    // MARK: - Cursor & outline (D-38)

    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor {
        location == nil ? .arrow : .crosshair
    }

    /// The brush-outline circle at the Eraser's own width (D-38), the Paintbrush's rule.
    private func outlineAtLastPointer(context: any ToolContext) {
        guard let pointer = lastPointer else { return }
        let rect = BrushOutline.canvasRect(center: pointer, options: options)
        guard !rect.isNull else { return }
        context.setOverlay(.brushOutline(rect))
    }
}
