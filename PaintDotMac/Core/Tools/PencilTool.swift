import CoreGraphics
import Foundation

/// The Pencil (spec 0011; PRD T-13, TOOL-A, D-15, D-38, H-6). Aliased, one image pixel
/// wide (T-13): a click paints the one pixel under the cursor, a drag the exact Bresenham
/// line between successive event pixels (`PixelLine`), and the stroke composites through
/// 0009's `BrushStroke` with binary coverage — one stroke is one "Pencil" history step,
/// pixels live in the document via `context.updateImage`, and the touched tiles become a
/// `TileDiffHistoryItem` at commit (AGENTS rule 2; the same lifecycle as `PaintbrushTool`).
///
/// The pixels behave "as if they were on their own layer" (Pencil.html): a pixel marked
/// twice in one stroke composes once from its before-stroke value, so a semi-transparent
/// color never compounds at self-crossings.
@MainActor
final class PencilTool: Tool {
    let id: ToolID = .pencil

    /// The Pencil's single option (TOOL-C): `tool.pencil.blendMode`. D-15 — the selectable
    /// list is the Paintbrush's (the implemented layer blend modes); Paint.NET's tool-only
    /// Overwrite is not in v1.0 (D-27). There is no width/hardness/antialiasing option:
    /// the Pencil is always aliased and one pixel wide (T-13).
    nonisolated static let blendModeKey = ToolOptionKey<BlendMode>(tool: .pencil,
                                                                   name: "blendMode",
                                                                   defaultValue: .normal)

    /// The blend-mode list the picker offers — the Paintbrush's list (D-15);
    /// 0026/0027/0059 grow the shared `BlendMode` enum and both pickers follow.
    nonisolated static var selectableBlendModes: [BlendMode] { BlendMode.allCases }

    /// The fixed one-pixel aliased brush: width 1, hardness 100, antialiasing off, the
    /// stored blend mode (the blend mode is the only live option).
    private static func strokeOptions(blendMode: BlendMode) -> BrushOptions {
        BrushOptions(width: 1, hardness: 100, antialiasing: false, blendMode: blendMode)
    }

    /// One live stroke plus the layer it paints; everything else (color, blend mode, clip)
    /// is frozen inside the `BrushStroke` at mouse-down, as on the Paintbrush (TOOL-A).
    private struct ActiveStroke {
        var stroke: BrushStroke
        let layerID: Layer.ID
    }

    private var activeStroke: ActiveStroke?
    /// The pixel of the last mapped pointer event; `nil` while no finite event has
    /// arrived (an off-canvas pixel is still remembered — the line runs through
    /// unbounded integer space so a stroke that leaves and re-enters draws correctly).
    private var lastPixel: PixelPoint?

    var hasPendingEdit: Bool { activeStroke != nil }

    /// The canvas-point → pixel mapping: pixel `(i, j)` covers
    /// `[i, i+1) × [j, j+1)` in canvas space (0006's `ToolEvent.location` convention,
    /// the same as 0009's brush model). Non-finite input → `nil`; finite coordinates are
    /// clamped to `[-65_536, 131_071]` before flooring so a wild event can never produce
    /// an unbounded Bresenham loop.
    nonisolated static func pixel(for point: CGPoint) -> PixelPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return PixelPoint(x: floorCoordinate(point.x), y: floorCoordinate(point.y))
    }

    private nonisolated static func floorCoordinate(_ value: Double) -> Int {
        Int(Swift.min(Swift.max(value, -65_536), 131_071).rounded(.down))
    }

    // MARK: - Pointer

    func mouseDown(_ event: ToolEvent, context: any ToolContext) {
        // A second button pressed while a stroke runs is ignored; the original button
        // decides the color until mouse-up (0009's rule).
        guard activeStroke == nil else { return }
        lastPixel = Self.pixel(for: event.location)
        let color = strokeColor(for: event, context: context)
        let blendMode = context.options.value(Self.blendModeKey)
        let layerID = context.image.activeLayer.id
        let stroke = BrushStroke(canvasSize: context.image.size,
                                 options: Self.strokeOptions(blendMode: blendMode),
                                 clipMask: context.paintClipMask,
                                 compose: PaintbrushTool.paintbrushCompose(color: color,
                                                                           blendMode: blendMode))
        // The stroke exists even when the click lands off-canvas: `hasPendingEdit` is
        // true exactly between mouse-down and commit/cancel, and an empty diff records
        // nothing (H-6).
        var active = ActiveStroke(stroke: stroke, layerID: layerID)
        context.updateImage { image in
            guard let index = image.layerIndex(for: layerID) else { return }
            // `begin` takes the before-stroke snapshot; its degenerate dab and the `mark`
            // below hit the same pixel (width 1, hardness 100, aliased → coverage 255 on
            // the floor-mapped pixel only), and coverage is max-combined, so the pair is
            // idempotent.
            _ = active.stroke.begin(at: event.location, on: &image.layers[index].surface)
            if let pixel = lastPixel {
                active.stroke.mark(x: pixel.x, y: pixel.y, coverage: 255,
                                   on: &image.layers[index].surface)
            }
            activeStroke = active
        }
    }

    func mouseDragged(_ event: ToolEvent, context: any ToolContext) {
        guard activeStroke != nil else { return }
        // A non-finite point is a pure no-op (the previous `lastPixel` is kept, so the
        // next finite event continues the line from where the stroke actually was).
        guard let pixel = Self.pixel(for: event.location) else { return }
        guard pixel != lastPixel else { return }
        markLine(to: pixel, context: context)
    }

    func mouseUp(_ event: ToolEvent, context: any ToolContext) {
        guard activeStroke != nil else { return }
        if let pixel = Self.pixel(for: event.location), pixel != lastPixel {
            markLine(to: pixel, context: context)
        }
        commit(context: context)
    }

    /// Marks every pixel of `lastPixel → pixel` (inclusive; `PixelLine`, unbounded
    /// integer space — `mark` skips the ones outside the canvas) and moves `lastPixel`.
    private func markLine(to pixel: PixelPoint, context: any ToolContext) {
        guard var active = activeStroke else { return }
        let from = lastPixel ?? pixel
        lastPixel = pixel
        let layerID = active.layerID
        context.updateImage { image in
            guard let index = image.layerIndex(for: layerID) else { return }
            PixelLine.forEachPixel(from: from, to: pixel) { point in
                active.stroke.mark(x: point.x, y: point.y, coverage: 255,
                                   on: &image.layers[index].surface)
            }
            activeStroke = active
        }
    }

    /// TOOL-A: right button (and Control-left, which 0006's dispatcher delivers as
    /// `.secondary`) paints the secondary color; the `.primary` + `.control` pair is
    /// handled defensively, exactly as on the Paintbrush.
    private func strokeColor(for event: ToolEvent, context: any ToolContext) -> ColorRGBA8 {
        if event.button == .secondary
            || (event.button == .primary && event.modifiers.contains(.control)) {
            return context.colors.secondary
        }
        return context.colors.primary
    }

    // MARK: - Commit / cancel

    /// Finishes an in-progress stroke like `mouseUp`: a non-empty `TileDiff` becomes the
    /// "Pencil" step; an empty one records nothing (H-6/D-34). With no stroke it does
    /// nothing, and `deactivate` (0006's default) routes through here.
    func commit(context: any ToolContext) {
        guard let active = activeStroke else { return }
        activeStroke = nil
        lastPixel = nil
        guard let index = context.image.layerIndex(for: active.layerID) else { return }
        let diff = active.stroke.makeTileDiff(from: context.image.layers[index].surface,
                                              layerID: active.layerID)
        context.commitHistory(TileDiffHistoryItem(name: "Pencil", icon: .pencil, diff: diff))
    }

    /// Escape during the gesture: the layer returns bit-identical to before mouse-down
    /// and no history step is recorded.
    func cancel(context: any ToolContext) {
        guard var active = activeStroke else { return }
        activeStroke = nil
        lastPixel = nil
        let layerID = active.layerID
        context.updateImage { image in
            guard let index = image.layerIndex(for: layerID) else { return }
            active.stroke.cancel(on: &image.layers[index].surface)
        }
    }

    // MARK: - Cursor (D-38 decision for the Pencil)

    /// The crosshair's hotspot marks the pixel that gets painted; the Pencil has no brush
    /// outline (the tip is always exactly one pixel) and never calls `setOverlay`.
    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor {
        location == nil ? .arrow : .crosshair
    }
}
