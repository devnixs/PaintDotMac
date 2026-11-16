import CoreGraphics
import Foundation

/// Option keys for the flood tools (spec 0016; 0017 calls the same functions with
/// `.paintBucket`, so the Paint Bucket reads its own `tool.paintBucket.*` copies of the
/// same three options — TOOL-C, PRD T-9). Defaults: Tolerance 50 %, Flood mode
/// Contiguous, Sampling Layer (PRD T-4 / D-43).
enum FloodToolOptions {
    /// `"tolerance"`, 0…100 (clamped by the key's sanitizer; TOOL-C).
    static func tolerance(for tool: ToolID) -> ToolOptionKey<Int> {
        ToolOptionKey(tool: tool, name: "tolerance",
                      defaultValue: FloodTolerance.default.percent, range: 0...100)
    }

    /// `"floodMode"`, stored as the raw string; an unknown stored string reads as the
    /// default (0006's `ToolOptionKey` sanitizing).
    static func floodMode(for tool: ToolID) -> ToolOptionKey<FloodMode> {
        ToolOptionKey(tool: tool, name: "floodMode", defaultValue: .contiguous)
    }

    /// `"samplingMode"`, stored as the raw string (0012's shared `SamplingMode`).
    static func samplingMode(for tool: ToolID) -> ToolOptionKey<SamplingMode> {
        ToolOptionKey(tool: tool, name: "samplingMode", defaultValue: .layer)
    }

    /// Paint.NET: "The keyboard shortcut to enable Global selection mode is the Shift
    /// key." Mac mapping: Shift-click forces Global (0014's mode mapping ignores Shift,
    /// so it conflicts with nothing).
    static func effectiveFloodMode(stored: FloodMode, modifiers: ToolModifiers) -> FloodMode {
        modifiers.contains(.shift) ? .global : stored
    }
}

extension FloodMode: ToolOptionValue {}

// 0012 deferred this conformance to 0016; the Color Picker's own key stores the raw
// `String` unchanged, and 0017 reuses this one.
extension SamplingMode: ToolOptionValue {}

/// The Magic Wand tool (T-4, spec 0016; Paint.NET MagicWand.html). One click fills a
/// region with the Paint.NET 3.36 `CheckColor` metric (Tolerance 50 % default) —
/// contiguous (4-connected) or global (Shift-click or the Flood mode option) — over the
/// active layer or the composited image (Sampling), and combines the region with the
/// current selection exactly like the other selection tools (0014's modes, modifiers,
/// Return-deselects, and commit rules). The result is pixel-aligned: marching ants and
/// the mask follow the pixel edges, and the quality picker is irrelevant (spec 0016).
/// The fill runs synchronously on mouse-down (D-43; 0048 moves it off the main actor);
/// the tool owns no pending edit.
@MainActor
final class MagicWandTool: Tool {
    let id: ToolID = .magicWand

    /// Paint.NET fills on mouse-down (immediate feedback). Clicks outside the canvas do
    /// nothing — no step, no deselect (spec 0016 Edge cases).
    func mouseDown(_ event: ToolEvent, context: any ToolContext) {
        guard event.location.x.isFinite, event.location.y.isFinite else { return }
        let size = context.image.size
        guard event.location.x >= 0, event.location.y >= 0,
              event.location.x < Double(size.width), event.location.y < Double(size.height)
        else { return }
        let seed = PixelPoint(x: Int(event.location.x.rounded(.down)),
                              y: Int(event.location.y.rounded(.down)))

        // The mode is read once at mouse-down like on the other selection tools
        // (Paint.NET `SelectionTool.OnMouseDown`; 0014's mapping ignores Shift).
        let mode = SelectionToolOptions.combineMode(
            picker: context.options.value(SelectionToolOptions.combineMode),
            button: event.button, modifiers: event.modifiers)
        let flood = FloodToolOptions.effectiveFloodMode(
            stored: context.options.value(FloodToolOptions.floodMode(for: .magicWand)),
            modifiers: event.modifiers)
        let tolerance = FloodTolerance(
            percent: context.options.value(FloodToolOptions.tolerance(for: .magicWand)))
        let sampling = context.options.value(FloodToolOptions.samplingMode(for: .magicWand))

        // The wand's region is combined with the selection afterwards, never limited
        // by it (spec 0016 step 4).
        let source = FloodFillSource.make(for: context.image, sampling: sampling)
        guard let stencil = FloodFill.fill(source, from: seed, tolerance: tolerance,
                                           mode: flood) else { return }
        guard let operand = Selection(mask: stencil.selectionMask(),
                                      outline: stencil.outline()) else { return }

        // One "Magic Wand" step; a no-op result (⌘-click inside the selection) adds no
        // step (D-34), an empty combined result is no selection (0013).
        SelectionCommit.finish(outcome: .emit, newSelection: operand, mode: mode,
                               name: "Magic Wand", icon: .magicWand, context: context)
    }

    /// A drag after the click changes nothing; one click = one step (spec 0016).
    func mouseDragged(_ event: ToolEvent, context: any ToolContext) {}

    func mouseUp(_ event: ToolEvent, context: any ToolContext) {}

    /// "Deselect active selection: Ctrl + D or Enter" — same rule as Rectangle Select
    /// (0014's `SelectionCommit`).
    func keyDown(_ event: ToolKeyEvent, context: any ToolContext) -> Bool {
        if event.key == .returnKey || event.key == .enter {
            return SelectionCommit.deselectIfNeeded(context: context)
        }
        return false
    }

    /// Paint.NET has no custom wand cursor; v1.0 uses the selection crosshair.
    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor { .crosshair }
}
