import CoreGraphics
import Foundation

/// The Paintbrush (spec 0009; PRD T-11, TOOL-A, D-15, D-35, D-38). One stroke is one
/// "Paintbrush" history step; the pixels live in the document while the stroke runs
/// (`context.updateImage`) and the 0008 capture pattern turns the touched tiles into a
/// `TileDiffHistoryItem` at mouse-up — the only way pixels reach history (AGENTS rule 2).
@MainActor
final class PaintbrushTool: Tool, BrushWidthAdjustable {
    let id: ToolID = .paintbrush

    /// One live stroke plus everything frozen at mouse-down: the brush options, the color
    /// (TOOL-A — decided at mouse-down and fixed for the stroke), the clip mask, and the
    /// layer being painted.
    private struct ActiveStroke {
        var stroke: BrushStroke
        let layerID: Layer.ID
    }

    private var activeStroke: ActiveStroke?
    /// Cached options for the outline/cursor; re-read at mouse-down and on
    /// `optionsDidChange` (the store is the source of truth).
    private(set) var options = BrushOptions.default
    /// Last pointer location in canvas space; the outline and `[`/`]` need it to redraw.
    private var lastPointer: CGPoint?

    var hasPendingEdit: Bool { activeStroke != nil }

    // MARK: - Lifecycle

    func activate(context: any ToolContext) {
        options = BrushOptions.load(from: context.options, tool: id)
        outlineAtLastPointer(context: context)
    }

    /// Commits a pending stroke (0006's default behavior) and hides the outline (D-38: the
    /// outline disappears when the tool is deactivated).
    func deactivate(context: any ToolContext) {
        if hasPendingEdit { commit(context: context) }
        context.setOverlay(nil)
    }

    // MARK: - Pointer

    func mouseDown(_ event: ToolEvent, context: any ToolContext) {

        // A second button pressed while a stroke runs is ignored; the original button
        // decides the color until mouse-up (spec *Edge cases*).
        guard activeStroke == nil else { return }
        lastPointer = event.location
        let options = BrushOptions.load(from: context.options, tool: id).clamped()
        self.options = options
        let color = strokeColor(for: event, context: context)
        let layerID = context.image.activeLayer.id
        let stroke = BrushStroke(canvasSize: context.image.size, options: options,
                                 clipMask: context.paintClipMask,
                                 compose: Self.paintbrushCompose(color: color,
                                                                 blendMode: options.blendMode))
        // The stroke exists even when the dab lands off-canvas: `hasPendingEdit` is true
        // exactly between mouse-down and commit/cancel, and an empty diff records nothing.
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

    /// TOOL-A: right button (and Control-left, which 0006's dispatcher already delivers as
    /// `.secondary` with `.control` kept) paints the secondary color. The
    /// `.primary` + `.control` pair never arrives from the dispatcher — handled defensively.
    private func strokeColor(for event: ToolEvent, context: any ToolContext) -> ColorRGBA8 {
        if event.button == .secondary
            || (event.button == .primary && event.modifiers.contains(.control)) {
            return context.colors.secondary
        }
        return context.colors.primary
    }

    /// The Paintbrush compose rule: the stroke color with its alpha scaled by the
    /// effective coverage, blended onto the before-stroke pixel (D-15: `blendMode` today
    /// only ever `.normal`).
    nonisolated static func paintbrushCompose(color: ColorRGBA8,
                                              blendMode: BlendMode) -> BrushCompose {
        { before, coverage in
            BlendOps.blend(blendMode, dst: before,
                           src: ColorRGBA8(red: color.red, green: color.green, blue: color.blue,
                                           alpha: BlendOps.mul255(color.alpha, coverage)))
        }
    }

    // MARK: - Commit / cancel

    /// Finishes an in-progress stroke exactly like `mouseUp` at the last point: the pixels
    /// are already live, so a non-empty `TileDiff` becomes the "Paintbrush" step and an
    /// empty one records nothing (H-6/D-34). With no stroke it does nothing.
    func commit(context: any ToolContext) {
        guard let active = activeStroke else { return }
        activeStroke = nil
        guard let index = context.image.layerIndex(for: active.layerID) else { return }
        let diff = active.stroke.makeTileDiff(from: context.image.layers[index].surface,
                                              layerID: active.layerID)
        context.commitHistory(TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush,
                                                 diff: diff))
    }

    /// Escape during the gesture: the layer returns bit-identical to before mouse-down
    /// (absent tiles absent again) and no history step is recorded.
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
    /// stroke is unaffected.
    func adjustBrushWidth(by delta: Double, context: any ToolContext) {
        var updated = BrushOptions.load(from: context.options, tool: id)
        let base = updated.width.isFinite ? updated.width : BrushOptions.default.width
        updated.width = Swift.min(Swift.max(base + delta, BrushOptions.widthRange.lowerBound),
                                  BrushOptions.widthRange.upperBound)
        updated.save(to: context.options, tool: id)
        options = updated.clamped()
        outlineAtLastPointer(context: context)
    }

    // MARK: - Cursor & outline (D-38)

    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor {
        location == nil ? .arrow : .crosshair
    }

    private func outlineAtLastPointer(context: any ToolContext) {
        guard let pointer = lastPointer else { return }
        let rect = BrushOutline.canvasRect(center: pointer, options: options)
        guard !rect.isNull else { return }
        context.setOverlay(.brushOutline(rect))
    }
}
