import AppKit
import SwiftUI

/// The selection tools' options (spec 0014, PRD T-1/T-3/TOOL-C), Paint.NET's order left to
/// right: **Selection mode** (Replace / Add (Union) / Subtract / Intersect / Invert (Xor),
/// each with its modifier hint), the **Selection clipping** segmented control
/// (Pixelated / Antialiased — Magic Wand 0016 hides it via `showsQuality: false` because
/// its outline is pixel-exact), and — Rectangle Select only (`showsDrawMode: false`
/// reuses this view for Lasso 0015 and Magic Wand 0016) — a divider, **Drawing mode**
/// (Normal / Fixed Ratio / Fixed Size) and, when it is not Normal, **Width** and **Height**
/// fields, a **swap** button, and (Fixed Size only) a **Units** popup.
///
/// Values persist under the shared `tool.rectangleSelect.*` keys (TOOL-C, D-44d: one global
/// mode and clipping mode for every selection tool); the view observes
/// `toolOptions.revision` like the others.
struct SelectionToolOptionsView: View {
    private enum Field: Hashable { case width, height }

    let model: AppModel
    let showsDrawMode: Bool
    /// Magic Wand (0016) passes `false`: the wand's outline sits on pixel edges, so
    /// Pixelated and Antialiased rasterizations are identical and the clipping picker
    /// would be meaningless. Rectangle / Lasso / Ellipse keep it.
    var showsQuality: Bool = true
    /// Return/Escape in a numeric field hands focus back to the canvas (0006's contract —
    /// `DocumentWindowController` restores the first responder so tool keys work again).
    var onEndEditing: () -> Void = {}

    @State private var widthDraft = ""
    @State private var heightDraft = ""
    @FocusState private var focusedField: Field?

    private var mode: SelectionCombineMode {
        _ = model.toolOptions.revision
        return model.toolOptions.value(SelectionToolOptions.combineMode)
    }

    private var quality: SelectionQuality {
        _ = model.toolOptions.revision
        return model.toolOptions.value(SelectionToolOptions.quality)
    }

    private var drawMode: SelectionDrawMode {
        _ = model.toolOptions.revision
        return model.toolOptions.value(SelectionToolOptions.drawMode)
    }

    private var fixedWidth: Double {
        _ = model.toolOptions.revision
        return model.toolOptions.value(SelectionToolOptions.fixedWidth)
    }

    private var fixedHeight: Double {
        _ = model.toolOptions.revision
        return model.toolOptions.value(SelectionToolOptions.fixedHeight)
    }

    private var fixedUnit: MeasurementUnit {
        _ = model.toolOptions.revision
        return model.toolOptions.value(SelectionToolOptions.fixedUnit)
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker("Selection mode", selection: Binding(
                get: { mode },
                set: { model.toolOptions.setValue($0, for: SelectionToolOptions.combineMode) }
            )) {
                ForEach(SelectionCombineMode.allCases, id: \.self) { item in
                    Text(item.displayName
                            + (item.macModifierHint.isEmpty ? "" : "  \(item.macModifierHint)"))
                        .tag(item)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Selection mode")
            .accessibilityIdentifier("toolOptions.selectionMode")
            .accessibilityLabel("Selection mode")
            .accessibilityValue(mode.displayName)

            if showsQuality {
                Picker("Selection clipping mode", selection: Binding(
                    get: { quality },
                    set: { model.toolOptions.setValue($0, for: SelectionToolOptions.quality) }
                )) {
                    ForEach(SelectionQuality.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                .help("Selection clipping mode")
                .accessibilityIdentifier("toolOptions.selectionQuality")
                .accessibilityLabel("Selection clipping mode")
                .accessibilityValue(quality.displayName)
            }

            if showsDrawMode {
                Divider()

                Picker("Drawing mode", selection: Binding(
                    get: { drawMode },
                    set: { model.toolOptions.setValue($0, for: SelectionToolOptions.drawMode) }
                )) {
                    ForEach(SelectionDrawMode.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("Drawing mode")
                .accessibilityIdentifier("toolOptions.drawMode")
                .accessibilityLabel("Drawing mode")
                .accessibilityValue(drawMode.displayName)

                if drawMode != .normal {
                    numericField("Width", draft: $widthDraft, field: .width,
                                 value: fixedWidth, key: SelectionToolOptions.fixedWidth,
                                 identifier: "toolOptions.fixedWidth")
                    numericField("Height", draft: $heightDraft, field: .height,
                                 value: fixedHeight, key: SelectionToolOptions.fixedHeight,
                                 identifier: "toolOptions.fixedHeight")
                    Button {
                        swapSize()
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .help("Swap width and height")
                    .accessibilityIdentifier("toolOptions.fixedSwap")
                    .accessibilityLabel("Swap width and height")

                    if drawMode == .fixedSize {
                        Picker("Units", selection: Binding(
                            get: { fixedUnit },
                            set: { model.toolOptions.setValue($0, for: SelectionToolOptions.fixedUnit) }
                        )) {
                            ForEach(MeasurementUnit.allCases, id: \.self) { item in
                                Text(item.displayName).tag(item)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .help("Units")
                        .accessibilityIdentifier("toolOptions.fixedUnit")
                        .accessibilityLabel("Units")
                        .accessibilityValue(fixedUnit.displayName)
                    }
                }
            }
        }
        .onAppear { syncDrafts() }
        .onChange(of: model.toolOptions.revision) { _, _ in
            // A store write from elsewhere: the field being edited keeps its draft.
            if focusedField != .width { widthDraft = Self.sizeText(fixedWidth) }
            if focusedField != .height { heightDraft = Self.sizeText(fixedHeight) }
        }
    }

    private func numericField(_ label: String, draft: Binding<String>, field: Field,
                              value: Double, key: ToolOptionKey<Double>,
                              identifier: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
            TextField("", text: draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .focused($focusedField, equals: field)
                .onSubmit { commit(draft: draft, key: key, field: field) }
                .onExitCommand {
                    // Escape reverts the draft and hands the canvas the focus back.
                    draft.wrappedValue = Self.sizeText(value)
                    focusedField = nil
                    onEndEditing()
                }
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(label)
                .accessibilityValue(Self.sizeText(value))
        }
    }

    private func commit(draft: Binding<String>, key: ToolOptionKey<Double>, field: Field) {
        defer {
            focusedField = nil
            onEndEditing()
        }
        guard let parsed = Double(draft.wrappedValue.trimmingCharacters(in: .whitespaces)),
              parsed.isFinite else {
            draft.wrappedValue = Self.sizeText(value(of: key))  // non-numeric input reverts
            return
        }
        // The key's range clamps to 0.01–65535 on the way in.
        model.toolOptions.setValue(parsed, for: key)
        draft.wrappedValue = Self.sizeText(value(of: key))
    }

    private func value(of key: ToolOptionKey<Double>) -> Double {
        model.toolOptions.value(key)
    }

    private func swapSize() {
        let width = fixedWidth
        model.toolOptions.setValue(fixedHeight, for: SelectionToolOptions.fixedWidth)
        model.toolOptions.setValue(width, for: SelectionToolOptions.fixedHeight)
        syncDrafts()
    }

    private func syncDrafts() {
        widthDraft = Self.sizeText(fixedWidth)
        heightDraft = Self.sizeText(fixedHeight)
    }

    /// Up to 2 fraction digits, trailing zeros stripped ("100", "37.5", "6.25").
    static func sizeText(_ value: Double) -> String {
        let rounded = (value * 100).rounded(.toNearestOrAwayFromZero) / 100
        guard rounded != rounded.rounded(.towardZero) else { return String(Int(rounded)) }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
