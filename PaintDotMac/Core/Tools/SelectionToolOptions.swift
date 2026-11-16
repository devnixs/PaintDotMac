import Foundation

/// Shared selection-tool options and the Paint.NET modifier mapping (spec 0014, T-1/TOOL-C;
/// PRD D-44d). Lasso (0015) and Magic Wand (0016) reuse everything here except the
/// draw-mode members.
///
/// The shared keys deliberately live under `tool.rectangleSelect.`
/// (`tool.rectangleSelect.selectionMode`, `tool.rectangleSelect.selectionQuality`): every
/// selection tool reads and writes these same two keys, so changing the mode in Ellipse
/// Select also changes it for Rectangle Select, as in Paint.NET (one global selection mode
/// and clipping mode). Defaults: mode Replace, quality Antialiased (Paint.NET's default),
/// draw mode Normal, 4 × 3 Inches (Paint.NET 3.36 `SelectionDrawModeInfo.CreateDefault()`).

/// Rectangle Select's drawing mode (Paint.NET `RectangleSelectTool`): free, a locked
/// width:height ratio, or an exact size that follows the pointer.
enum SelectionDrawMode: String, CaseIterable, Sendable, ToolOptionValue {
    case normal
    case fixedRatio
    case fixedSize

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .fixedRatio: "Fixed Ratio"
        case .fixedSize: "Fixed Size"
        }
    }
}

/// Selection clipping mode (Paint.NET SelectionTools.html): the edge is either clipped to
/// a per-pixel boundary or antialiased.
enum SelectionQuality: String, CaseIterable, Sendable, ToolOptionValue {
    case pixelated
    case antialiased

    var displayName: String {
        switch self {
        case .pixelated: "Pixelated"
        case .antialiased: "Antialiased"
        }
    }
}

extension SelectionCombineMode: ToolOptionValue {
    /// The modifier gesture that forces this mode while dragging, shown dimmed after the
    /// name in the Selection mode picker (Paint.NET SelectionTools.html; ⌘ = Ctrl,
    /// ⌥ = Alt per PRD §5.12).
    var macModifierHint: String {
        switch self {
        case .replace: ""
        case .union: "⌘-drag"
        case .exclude: "⌥-drag"
        case .intersect: "⌥-right-drag"
        case .xor: "⌘-right-drag"
        }
    }
}

extension MeasurementUnit: ToolOptionValue {}

enum SelectionToolOptions {
    // Shared by every selection tool (D-44d): one global mode and clipping mode.
    static let combineMode = ToolOptionKey<SelectionCombineMode>(
        tool: .rectangleSelect, name: "selectionMode", defaultValue: .replace)
    static let quality = ToolOptionKey<SelectionQuality>(
        tool: .rectangleSelect, name: "selectionQuality", defaultValue: .antialiased)

    // Rectangle Select only.
    static let drawMode = ToolOptionKey<SelectionDrawMode>(
        tool: .rectangleSelect, name: "drawMode", defaultValue: .normal)
    static let fixedWidth = ToolOptionKey<Double>(
        tool: .rectangleSelect, name: "fixedWidth", defaultValue: 4, range: 0.01...65535)
    static let fixedHeight = ToolOptionKey<Double>(
        tool: .rectangleSelect, name: "fixedHeight", defaultValue: 3, range: 0.01...65535)
    static let fixedUnit = ToolOptionKey<MeasurementUnit>(
        tool: .rectangleSelect, name: "fixedUnit", defaultValue: .inches)

    /// Paint.NET `SelectionTool.OnMouseDown`: the mode is read once at mouse-down.
    /// ⌘ + left → Union; ⌘ + right → Xor ("Invert"); ⌥ + left → Exclude; ⌥ + right →
    /// Intersect; anything else → the toolbar picker. ⌘ is tested before ⌥, so ⌘ wins when
    /// both are held (Paint.NET tests Ctrl first). The right button is the right mouse
    /// button or a Control-click (0006's dispatcher already delivers both as `.secondary`).
    /// Shift and Control never change the mode (Shift constrains the shape; Control only
    /// produced the secondary button).
    static func combineMode(picker: SelectionCombineMode, button: ToolMouseButton,
                            modifiers: ToolModifiers) -> SelectionCombineMode {
        if modifiers.contains(.command) {
            return button == .primary ? .union : .xor
        }
        if modifiers.contains(.option) {
            return button == .primary ? .exclude : .intersect
        }
        return picker
    }

    /// Fixed Size in image pixels: per axis `value` (pixels), `value × dpi` (inches),
    /// `value / 2.54 × dpi` (centimeters) with `dpi = MeasurementUnit.sanitizedDPI(dpi)`;
    /// then rounded half away from zero and clamped to `1...65_535` (`ImageLimits` max
    /// side). A non-finite value gives 1. Paint.NET truncates; we round so 2.54 cm at
    /// 96 DPI is exactly 96 px despite floating-point error (implementation decision,
    /// spec 0014).
    static func fixedSizeInPixels(width: Double, height: Double,
                                  unit: MeasurementUnit, dpi: Double) -> PixelSize {
        PixelSize(width: axisPixels(width, unit: unit, dpi: dpi),
                  height: axisPixels(height, unit: unit, dpi: dpi))
    }

    private static func axisPixels(_ value: Double, unit: MeasurementUnit, dpi: Double) -> Int {
        guard value.isFinite else { return 1 }
        let resolved = MeasurementUnit.sanitizedDPI(dpi)
        let pixels: Double
        switch unit {
        case .pixels: pixels = value
        case .inches: pixels = value * resolved
        case .centimeters: pixels = value / 2.54 * resolved
        }
        guard pixels.isFinite else { return 1 }
        return min(max(Int(pixels.rounded(.toNearestOrAwayFromZero)), ImageLimits.minimumSide),
                   ImageLimits.maximumSide)
    }
}
