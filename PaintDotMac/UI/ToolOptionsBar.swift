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

            ToolOptionsContent(toolID: model.activeToolID, model: model)

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
/// `model.toolOptions` (identifiers `toolOptions.<option>`). 0011/0012… add theirs; 0006's
/// tools (Zoom, Pan) have none.
struct ToolOptionsContent: View {
    let toolID: ToolID
    let model: AppModel

    var body: some View {
        switch toolID {
        case .paintbrush:
            PaintbrushToolOptionsView(model: model)
        case .zoom, .pan:
            // Paint.NET shows no Zoom/Pan options.
            EmptyView()
        default:
            // Options arrive with each tool's spec (0011 Eraser/Pencil, 0012 Color Picker, …).
            EmptyView()
        }
    }
}

/// Paintbrush options (spec 0009, PRD T-11), Paint.NET's labels left to right: **Brush
/// width** (decimal field + ∓1 stepper, clamped to 1–2000 on commit; non-numeric input is
/// ignored by reverting), **Hardness** (slider 0–100 + `NN%` field, greyed while
/// antialiasing is off because it is ignored then), **Antialiasing enabled** toggle, and
/// the **Blend Mode** popup listing the implemented modes in L-3 order (D-15 — today only
/// "Normal"). The view observes `toolOptions.revision`, so `[`/`]` update it immediately.
struct PaintbrushToolOptionsView: View {
    private enum Field { case width, hardness }

    let model: AppModel

    @State private var widthDraft = ""
    @State private var hardnessDraft = ""
    @FocusState private var focusedField: Field?

    private var keys: (width: ToolOptionKey<Double>, hardness: ToolOptionKey<Int>,
                       antialiasing: ToolOptionKey<Bool>,
                       blendMode: ToolOptionKey<BlendMode>) { BrushOptions.keys(for: .paintbrush) }

    /// Reading the store here also registers the observation: every write bumps
    /// `revision`, and the `onChange` below re-syncs the two text drafts.
    private var options: BrushOptions {
        _ = model.toolOptions.revision
        return BrushOptions.load(from: model.toolOptions, tool: .paintbrush)
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
            HStack(spacing: 4) {
                Text("Blend Mode:")
                Picker("", selection: Binding(
                    get: { value.blendMode },
                    set: { model.toolOptions.setValue($0, for: keys.blendMode) }
                )) {
                    // D-15: the list is the implemented layer modes, in L-3 order; 0026/
                    // 0027/0059 add theirs as they land.
                    ForEach(BlendMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("toolOptions.blendMode")
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
        updated.save(to: model.toolOptions, tool: .paintbrush)  // clamps to 1–2000
        widthDraft = Self.widthText(updated.width)
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
