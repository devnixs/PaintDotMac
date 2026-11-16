import CoreGraphics
import Foundation

/// What the Color Picker does after a click that picked a color (spec 0012; PRD T-14 /
/// D-28; Paint.NET ColorPicker.html "After Click"). Stored under
/// `tool.colorPicker.afterClick` as the raw string; unknown values read as missing and
/// fall back to `.doNotSwitch` (TOOL-C).
enum ColorPickerAfterClick: String, CaseIterable, Sendable {
    case doNotSwitch
    case switchToPreviousTool
    case switchToPencil

    var displayName: String {
        switch self {
        case .doNotSwitch: "Do not switch tool"
        case .switchToPreviousTool: "Switch to previous tool"
        case .switchToPencil: "Switch to Pencil tool"
        }
    }

    /// The pure decision: `.doNotSwitch` → nil; `.switchToPreviousTool` → `previous` when
    /// non-nil and not the Color Picker itself (a previous of `.colorPicker` is treated as
    /// "no previous tool"); `.switchToPencil` → `.pencil`. `current` names the tool the
    /// decision is made for (`.colorPicker` today; kept for symmetry with the dispatcher).
    func toolToActivate(current: ToolID, previous: ToolID?) -> ToolID? {
        switch self {
        case .doNotSwitch:
            return nil
        case .switchToPreviousTool:
            guard let previous, previous != current else { return nil }
            return previous
        case .switchToPencil:
            return .pencil
        }
    }
}

extension ColorPickerAfterClick: ToolOptionValue {}

extension SamplingSize: ToolOptionValue {
    /// Reads the `Int` raw value; unknown or out-of-range stored values read as missing,
    /// so the option falls back to its default (spec 0012, no crash).
    init?(storedValue: Any) {
        guard let raw = Int(storedValue: storedValue), let size = SamplingSize(rawValue: raw)
        else { return nil }
        self = size
    }

    var storedValue: Any { rawValue }
}

/// The Color Picker, T-14 (spec 0012; PRD §5.3, D-28; Paint.NET ColorPicker.html).
/// Left-click sets the primary color, right-click / Control-click the secondary (TOOL-A);
/// ⌘-click forces Image sampling (Paint.NET's Ctrl-click, ⌘ per PRD §5.12). Dragging
/// updates the color live. Picking is **not** a history step: the tool never calls
/// `commitHistory`/`performHistory`/`updateImage`, never mutates pixels, and never marks
/// the document edited. `commit`/`cancel` keep 0006's defaults and `hasPendingEdit` stays
/// false — no pending state survives a gesture.
@MainActor
final class ColorPickerTool: Tool {
    let id: ToolID = .colorPicker

    /// TOOL-C keys, defaults per PRD T-14 / D-28: Single pixel / Layer / Do not switch
    /// tool. The mode stores the raw `String` because `SamplingMode` is not a
    /// `ToolOptionValue` until 0016 (spec 0012).
    static let samplingSizeKey = ToolOptionKey<SamplingSize>(
        tool: .colorPicker, name: "samplingSize", defaultValue: .singlePixel)
    static let samplingModeKey = ToolOptionKey<String>(
        tool: .colorPicker, name: "samplingMode", defaultValue: SamplingMode.layer.rawValue)
    static let afterClickKey = ToolOptionKey<ColorPickerAfterClick>(
        tool: .colorPicker, name: "afterClick", defaultValue: .doNotSwitch)

    /// True once this gesture has set at least one color; `mouseUp` consumes it. A gesture
    /// that never touched the canvas changes nothing and does not switch tools.
    private var gesturePickedColor = false

    // MARK: - Pointer

    func mouseDown(_ event: ToolEvent, context: any ToolContext) {
        gesturePickedColor = false
        pick(event, context: context)
    }

    /// Live update while dragging (Paint.NET), using the gesture's button and the ⌘ state
    /// of the current event. Points outside the canvas leave the color unchanged.
    func mouseDragged(_ event: ToolEvent, context: any ToolContext) {
        pick(event, context: context)
    }

    /// Samples once more at the up point, then — only if the gesture picked at least one
    /// color — applies the "After Click" choice. `activateTool` defers the switch until the
    /// dispatcher's `pointerUp` handler returns; the dispatcher then records
    /// `.colorPicker` as the new previous tool.
    func mouseUp(_ event: ToolEvent, context: any ToolContext) {
        pick(event, context: context)
        let picked = gesturePickedColor
        gesturePickedColor = false
        guard picked else { return }
        let afterClick = context.options.value(Self.afterClickKey)
        if let target = afterClick.toolToActivate(current: .colorPicker,
                                                  previous: context.previousToolID) {
            context.activateTool(target)
        }
    }

    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor {
        location == nil ? .arrow : .crosshair
    }

    // MARK: - Sampling

    /// Maps the canvas-space point to a pixel with `floor` on each axis, resolves the
    /// effective mode (⌘ forces Image, PRD §5.12), samples, and writes the slot. Outside
    /// the canvas (or a defensive model state) changes nothing.
    private func pick(_ event: ToolEvent, context: any ToolContext) {
        guard let x = Self.pixelIndex(event.location.x),
              let y = Self.pixelIndex(event.location.y) else { return }
        let mode: SamplingMode
        if event.modifiers.contains(.command) {
            mode = .image
        } else {
            mode = SamplingMode(rawValue: context.options.value(Self.samplingModeKey)) ?? .layer
        }
        let size = context.options.value(Self.samplingSizeKey)
        guard let color = PixelSampler.sample(context.image, at: PixelPoint(x: x, y: y),
                                              size: size, mode: mode) else { return }
        context.setColor(color, for: event.button == .primary ? .primary : .secondary)
        gesturePickedColor = true
    }

    /// `floor` of a canvas-space coordinate; nil for a non-finite value or one outside
    /// `Int` range (sampled as "outside the canvas" — never a conversion trap).
    private static func pixelIndex(_ coordinate: Double) -> Int? {
        guard coordinate.isFinite else { return nil }
        let floored = coordinate.rounded(.down)
        guard floored >= Double(Int.min) && floored < Double(Int.max) else { return nil }
        return Int(floored)
    }
}
