import AppKit
import SwiftUI

/// The tool options bar (PRD APP-4; Paint.NET Toolbar.html; spec 0006), at the top of every
/// document window: the Tool chooser, the active tool's options, and the Finish button.
/// Zoom and Pan have no options (Paint.NET shows none for them).
struct ToolOptionsBar: View {
    /// Fixed height in points; the window controller reserves it above the canvas.
    static let barHeight: CGFloat = 30

    let model: AppModel
    /// Text fields of later specs call this on Return/Escape so tool keys work again
    /// right after editing a value (`DocumentWindowController` restores first responder).
    var onEndEditing: () -> Void = {}

    /// Pure helpers, asserted by `ToolOptionsBarModelTests`.
    static func showsFinish(for descriptor: ToolDescriptor) -> Bool {
        descriptor.supportsPendingEdits
    }

    static func finishEnabled(hasPendingEdit: Bool) -> Bool { hasPendingEdit }

    /// The blend-mode list both blend-mode pickers offer — the Paintbrush's and the
    /// Pencil's are the same list by D-15 (the implemented layer blend modes in L-3
    /// order; 0026/0027/0059 grow it).
    static var selectableBlendModes: [BlendMode] { BlendMode.allCases }

    var body: some View {
        let descriptor = ToolRegistry.descriptor(for: model.activeToolID)
        HStack(spacing: 8) {
            Picker(selection: Binding(
                get: { model.activeToolID },
                set: { model.selectTool($0) }
            )) {
                ForEach(model.implementedTools, id: \.id) { tool in
                    Label(tool.displayName, systemImage: tool.symbolName).tag(tool.id)
                }
            } label: {
                Label(descriptor.displayName, systemImage: descriptor.symbolName)
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("toolOptions.tool")
            .accessibilityValue(descriptor.displayName)

            Divider()

            ToolOptionsContent(toolID: model.activeToolID, model: model,
                               onEndEditing: onEndEditing)

            Spacer()

            if Self.showsFinish(for: descriptor) {
                Button("Finish") {
                    model.dispatcher.commitPendingEdit()
                }
                .disabled(!Self.finishEnabled(hasPendingEdit: model.hasPendingToolEdit))
                .accessibilityIdentifier("toolOptions.finish")
                .accessibilityLabel("Finish")
                .accessibilityHint("Commits the pending edit to the canvas (Enter)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.barHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolOptionsBar")
    }
}

/// One `case` per tool that has options, hand-built controls reading and writing through
/// `model.toolOptions` (identifiers `toolOptions.<option>`). 0012… add theirs; 0006's
/// tools (Zoom, Pan) have none.
struct ToolOptionsContent: View {
    let toolID: ToolID
    let model: AppModel
    /// Forwarded to the views with numeric fields (0014) so Return/Escape restore the
    /// canvas as first responder.
    var onEndEditing: () -> Void = {}

    /// The stored Lasso mode; reading `revision` registers the observation, an unknown
    /// stored string reads as the default (Freeform, spec 0015).
    static func lassoMode(in model: AppModel) -> LassoMode {
        _ = model.toolOptions.revision
        return LassoMode(rawValue: model.toolOptions.value(LassoSelectTool.lassoModeKey))
            ?? .freeform
    }

    var body: some View {
        switch toolID {
        case .rectangleSelect:
            // T-1 / D-44d: mode + clipping are shared with the other selection tools;
            // only Rectangle Select has the draw-mode controls.
            SelectionToolOptionsView(model: model, showsDrawMode: true,
                                     onEndEditing: onEndEditing)
        case .ellipseSelect:
            // T-3: Paint.NET's Ellipse Select has no draw-mode options.
            SelectionToolOptionsView(model: model, showsDrawMode: false,
                                     onEndEditing: onEndEditing)
        case .lassoSelect:
            // T-2 / 0015: the shared selection options (mode + clipping, no draw-mode
            // controls) plus the Lasso mode picker (Freeform / Polygon, `tool.lassoSelect
            // .lassoMode`, TOOL-C).
            HStack(spacing: 8) {
                SelectionToolOptionsView(model: model, showsDrawMode: false,
                                         onEndEditing: onEndEditing)
                Picker("Lasso mode", selection: Binding(
                    get: { Self.lassoMode(in: model) },
                    set: { model.toolOptions.setValue($0.rawValue,
                                                      for: LassoSelectTool.lassoModeKey) }
                )) {
                    ForEach(LassoMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Lasso mode")
                .accessibilityIdentifier("toolOptions.lassoMode")
                .accessibilityLabel("Lasso mode")
                .accessibilityValue(Self.lassoMode(in: model).displayName)
            }
        case .magicWand:
            // T-4 / 0016: the shared selection options with no clipping picker (the
            // wand's outline is pixel-exact, so Pixelated and Antialiased are
            // identical), then the flood options.
            HStack(spacing: 8) {
                SelectionToolOptionsView(model: model, showsDrawMode: false,
                                         showsQuality: false,
                                         onEndEditing: onEndEditing)
                Divider()
                FloodToolOptionsView(model: model, tool: .magicWand)
            }
        case .paintbrush:
            BrushToolOptionsView(model: model, tool: .paintbrush, showsBlendMode: true)
        case .eraser:
            // T-12/D-27: width, hardness, antialiasing under `tool.eraser.*`, no blend mode.
            BrushToolOptionsView(model: model, tool: .eraser, showsBlendMode: false)
        case .pencil:
            // T-13: the always-aliased one-pixel Pencil has only the blend mode (D-15).
            PencilToolOptionsView(model: model)
        case .colorPicker:
            // T-14 / D-28: sampling size, Layer/Image mode, and the After Click choice.
            ColorPickerToolOptionsView(model: model)
        case .zoom, .pan:
            // Paint.NET shows no Zoom/Pan options.
            EmptyView()
        default:
            // Options arrive with each tool's spec (0012 Color Picker, …).
            EmptyView()
        }
    }
}

/// The brush-shaped tools' options (spec 0009 for the Paintbrush, PRD T-11; spec 0011 for
/// the Eraser, T-12), Paint.NET's labels left to right: **Brush width** (decimal field +
/// ∓1 stepper, clamped to 1–2000 on commit; non-numeric input is ignored by reverting),
/// **Hardness** (slider 0–100 + `NN%` field, greyed while antialiasing is off because it
/// is ignored then), and **Antialiasing enabled**. The Paintbrush additionally shows the
/// **Blend Mode** popup listing the implemented modes in L-3 order (D-15 — today only
/// "Normal"); the Eraser has no blend mode (D-27), so `showsBlendMode` is false. All
/// values live under `tool.<tool>.*` (TOOL-C) and the view observes
/// `toolOptions.revision`, so `[`/`]` update it immediately.
struct BrushToolOptionsView: View {
    private enum Field { case width, hardness }

    let model: AppModel
    /// `.paintbrush` or `.eraser` — picks the `tool.<id>.*` key prefix.
    let tool: ToolID
    let showsBlendMode: Bool

    @State private var widthDraft = ""
    @State private var hardnessDraft = ""
    @FocusState private var focusedField: Field?

    private var keys: (width: ToolOptionKey<Double>, hardness: ToolOptionKey<Int>,
                       antialiasing: ToolOptionKey<Bool>,
                       blendMode: ToolOptionKey<BlendMode>) { BrushOptions.keys(for: tool) }

    /// Reading the store here also registers the observation: every write bumps
    /// `revision`, and the `onChange` below re-syncs the two text drafts.
    private var options: BrushOptions {
        _ = model.toolOptions.revision
        return BrushOptions.load(from: model.toolOptions, tool: tool)
    }

    var body: some View {
        let value = options
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("Brush width:")
                widthField(value: value)
                stepper(value: value)
            }
            HStack(spacing: 4) {
                Text("Hardness:")
                Slider(value: Binding(
                    get: { Double(value.hardness) },
                    set: { model.toolOptions.setValue(Int($0.rounded()), for: keys.hardness) }
                ), in: 0...100)
                .frame(width: 80)
                .disabled(!value.antialiasing)
                .accessibilityIdentifier("toolOptions.hardness.slider")
                TextField("", text: $hardnessDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 46)
                    .focused($focusedField, equals: .hardness)
                    .disabled(!value.antialiasing)
                    .onSubmit(commitHardness)
                    .accessibilityIdentifier("toolOptions.hardness")
            }
            Toggle("Antialiasing enabled", isOn: Binding(
                get: { value.antialiasing },
                set: { model.toolOptions.setValue($0, for: keys.antialiasing) }
            ))
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("toolOptions.antialiasing")
            if showsBlendMode {
                HStack(spacing: 4) {
                    Text("Blend Mode:")
                    Picker("", selection: Binding(
                        get: { value.blendMode },
                        set: { model.toolOptions.setValue($0, for: keys.blendMode) }
                    )) {
                        // D-15: the list is the implemented layer modes, in L-3 order;
                        // 0026/0027/0059 add theirs as they land.
                        ForEach(ToolOptionsBar.selectableBlendModes, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("toolOptions.blendMode")
                }
            }
        }
        .onAppear { syncDrafts(from: value) }
        .onChange(of: model.toolOptions.revision) { _, _ in
            // A store write from elsewhere (`[`, `]`, a programmatic change): the field
            // being edited keeps its in-progress draft; the other re-syncs.
            if focusedField != .width { widthDraft = Self.widthText(options.width) }
            if focusedField != .hardness { hardnessDraft = "\(options.hardness)%" }
        }
    }

    private func widthField(value: BrushOptions) -> some View {
        TextField("", text: $widthDraft)
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
            .focused($focusedField, equals: .width)
            .onSubmit(commitWidth)
            .accessibilityIdentifier("toolOptions.width")
            .accessibilityValue(Self.widthText(value.width))
    }

    private func stepper(value: BrushOptions) -> some View {
        // The app's single-key shortcut path steps the width (`[`/`]`); the bar's −/+
        // buttons use the same `BrushWidthAdjustable` contract through the same store,
        // which keeps one clamping rule. `adjustBrushWidth` needs the tool context, which
        // the bar does not own, so the stepper writes the clamped neighbor directly.
        HStack(spacing: 2) {
            Button {
                stepWidth(-1, from: value)
            } label: {
                Image(systemName: "minus")
            }
            .accessibilityIdentifier("toolOptions.width.decrease")
            Button {
                stepWidth(+1, from: value)
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityIdentifier("toolOptions.width.increase")
        }
    }

    private func stepWidth(_ delta: Double, from value: BrushOptions) {
        var updated = value
        updated.width = Swift.min(Swift.max(value.width + delta, BrushOptions.widthRange.lowerBound),
                                  BrushOptions.widthRange.upperBound)
        model.toolOptions.setValue(updated.width, for: keys.width)
    }

    private func commitWidth() {
        defer { focusedField = nil }
        guard let parsed = Double(widthDraft.trimmingCharacters(in: .whitespaces)),
              parsed.isFinite else {
            widthDraft = Self.widthText(options.width)  // non-numeric input is ignored
            return
        }
        var updated = options
        updated.width = parsed
        // Write only the keys this view owns — the Eraser must never store
        // `tool.eraser.blendMode` (D-27), so this must not use `BrushOptions.save`.
        let clamped = updated.clamped()
        model.toolOptions.setValue(clamped.width, for: keys.width)
        model.toolOptions.setValue(clamped.hardness, for: keys.hardness)
        model.toolOptions.setValue(clamped.antialiasing, for: keys.antialiasing)
        if showsBlendMode {
            model.toolOptions.setValue(clamped.blendMode, for: keys.blendMode)
        }
        widthDraft = Self.widthText(clamped.width)
    }

    private func commitHardness() {
        defer { focusedField = nil }
        let text = hardnessDraft.replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let parsed = Int(text) else {
            hardnessDraft = "\(options.hardness)%"
            return
        }
        model.toolOptions.setValue(
            Swift.min(Swift.max(parsed, BrushOptions.hardnessRange.lowerBound),
                      BrushOptions.hardnessRange.upperBound),
            for: keys.hardness
        )
        hardnessDraft = "\(options.hardness)%"
    }

    private func syncDrafts(from value: BrushOptions) {
        widthDraft = Self.widthText(value.width)
        hardnessDraft = "\(value.hardness)%"
    }

    /// Up to 2 fraction digits, trailing zeros stripped ("2", "37.5", "6.25").
    static func widthText(_ width: Double) -> String {
        let rounded = (width * 100).rounded() / 100
        guard rounded != rounded.rounded(.towardZero) || rounded < 1 || rounded > 2000 else {
            return String(Int(rounded))
        }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Pencil options (spec 0011, PRD T-13, D-15): the **Blend Mode** popup only. The Pencil
/// is always aliased and one pixel wide, so it has no width, hardness, or antialiasing
/// controls; the list is the Paintbrush's (D-15) and the value persists as
/// `tool.pencil.blendMode` (TOOL-C). Paint.NET's tool-only Overwrite is not in v1.0 (D-27).
struct PencilToolOptionsView: View {
    let model: AppModel

    /// Reading the store here registers the observation (every write bumps `revision`).
    private var blendMode: BlendMode {
        _ = model.toolOptions.revision
        return model.toolOptions.value(PencilTool.blendModeKey)
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("Blend Mode:")
            Picker("", selection: Binding(
                get: { blendMode },
                set: { model.toolOptions.setValue($0, for: PencilTool.blendModeKey) }
            )) {
                ForEach(ToolOptionsBar.selectableBlendModes, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("toolOptions.blendMode")
        }
    }
}

/// Color Picker options (spec 0012, PRD T-14, D-28), Paint.NET's ColorPicker.html controls
/// left to right: **Sampling:** (Single pixel / 3 x 3 … 51 x 51 region), the **Layer /
/// Image** sampling-mode segmented control (⌘-click still forces Image), and **After
/// click:** (Do not switch tool / Switch to previous tool / Switch to Pencil tool). Values
/// persist under `tool.colorPicker.*` (TOOL-C); the mode keeps storing the raw string
/// (0012's format — unchanged now that 0016 added `SamplingMode: ToolOptionValue` for the
/// wand / bucket keys), and an unknown stored value reads as the default (spec 0012). The
/// view observes `toolOptions.revision` like the others.
struct ColorPickerToolOptionsView: View {
    let model: AppModel

    private var samplingSize: SamplingSize {
        _ = model.toolOptions.revision
        return model.toolOptions.value(ColorPickerTool.samplingSizeKey)
    }

    private var samplingMode: SamplingMode {
        _ = model.toolOptions.revision
        return SamplingMode(rawValue: model.toolOptions.value(ColorPickerTool.samplingModeKey))
            ?? .layer
    }

    private var afterClick: ColorPickerAfterClick {
        _ = model.toolOptions.revision
        return model.toolOptions.value(ColorPickerTool.afterClickKey)
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("Sampling:")
                Picker("Sampling", selection: Binding(
                    get: { samplingSize },
                    set: { model.toolOptions.setValue($0, for: ColorPickerTool.samplingSizeKey) }
                )) {
                    ForEach(SamplingSize.allCases, id: \.self) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("toolOptions.samplingSize")
                .accessibilityLabel("Sampling")
            }
            Picker("Sampling Mode", selection: Binding(
                get: { samplingMode },
                set: { model.toolOptions.setValue($0.rawValue, for: ColorPickerTool.samplingModeKey) }
            )) {
                ForEach(SamplingMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .accessibilityIdentifier("toolOptions.samplingMode")
            .accessibilityLabel("Sampling mode")
            HStack(spacing: 4) {
                Text("After click:")
                Picker("After click", selection: Binding(
                    get: { afterClick },
                    set: { model.toolOptions.setValue($0, for: ColorPickerTool.afterClickKey) }
                )) {
                    ForEach(ColorPickerAfterClick.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("toolOptions.afterClick")
                .accessibilityLabel("After click")
            }
        }
    }
}
