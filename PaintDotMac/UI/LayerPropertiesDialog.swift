import AppKit
import SwiftUI

/// The presentation seam for document sheets (spec 0025 item 9; AGENTS.md *Headless
/// testing*): the real implementation runs `window.beginSheet`; integration tests install
/// a recording one that keeps the controller without ever showing it. `isPresenting`
/// drives `LayersPanelModel.isDocumentBusy` and the menu validation.
@MainActor
protocol SheetPresenting: AnyObject {
    var isPresenting: Bool { get }
    func present(_ controller: NSViewController, on window: NSWindow,
                 completion: @escaping () -> Void)
    func dismiss()
}

/// The production `SheetPresenting`: `beginSheet` with a one-window sheet whose delegate
/// vends its **own private `UndoManager`**, so ⌘Z typed in the name field never reaches
/// the document's history (spec item 9).
@MainActor
final class DocumentSheetPresenter: NSObject, SheetPresenting, NSWindowDelegate {
    private(set) var isPresenting = false
    private var sheetWindow: NSWindow?
    private var completionHandler: (() -> Void)?
    /// The sheet's private undo manager (the field editor's typing undo).
    private let fieldUndoManager = UndoManager()

    func present(_ controller: NSViewController, on window: NSWindow,
                 completion: @escaping () -> Void) {
        guard !isPresenting else { return }
        let sheet = NSWindow(contentViewController: controller)
        sheet.styleMask = [.titled]
        sheet.delegate = self
        sheetWindow = sheet
        completionHandler = completion
        isPresenting = true
        window.beginSheet(sheet) { [weak self] _ in self?.finish() }
    }

    func dismiss() {
        guard let sheet = sheetWindow else { return }
        if let parent = sheet.sheetParent {
            // Ends the sheet; the `beginSheet` completion handler runs `finish()`.
            parent.endSheet(sheet)
        } else {
            finish()
        }
    }

    private func finish() {
        let completion = completionHandler
        completionHandler = nil
        sheetWindow = nil
        isPresenting = false
        completion?()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        fieldUndoManager
    }
}

/// Paint.NET's Layer Properties dialog (spec 0025 item 9): a **General** group (Name,
/// Visible) and a **Blending** group (Blend mode pop-up of the implemented modes, Opacity
/// slider 0–255 plus a number field), Cancel (Escape) and OK (Return, default). Every
/// edit goes through `LayerPropertiesDialogModel` — the view only binds and forwards.
struct LayerPropertiesDialogView: View {
    @Bindable var model: LayerPropertiesDialogModel
    @FocusState private var opacityFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Layer Properties")
                .font(.headline)

            GroupBox("General") {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Text("Name:")
                        TextField("", text: $model.edited.name)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Name")
                            .accessibilityIdentifier("layerProperties.name")
                    }
                    GridRow {
                        Toggle("Visible", isOn: $model.edited.isVisible)
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("layerProperties.visible")
                    }
                }
                .frame(maxWidth: .infinity)
            }

            GroupBox("Blending") {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Text("Blend mode:")
                        Picker("Blend mode",
                               selection: Binding(get: { model.edited.blendMode },
                                                  set: { model.edited.blendMode = $0 })) {
                            ForEach(model.blendModeOptions, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("layerProperties.blendMode")
                    }
                    GridRow {
                        Text("Opacity:")
                        HStack(spacing: 8) {
                            Slider(value: Binding(get: { Double(model.edited.opacity) },
                                                  set: { model.edited.opacity = UInt8($0) }),
                                   in: 0...255, step: 1)
                                .accessibilityLabel("Opacity")
                                .accessibilityIdentifier("layerProperties.opacitySlider")
                            TextField("", text: $model.opacityText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 48)
                                .focused($opacityFieldFocused)
                                // Commit on Return and on focus loss (spec item 9).
                                .onSubmit { model.commitOpacityText() }
                                .onChange(of: opacityFieldFocused) { _, focused in
                                    if !focused { model.commitOpacityText() }
                                }
                                .accessibilityLabel("Opacity")
                                .accessibilityIdentifier("layerProperties.opacityField")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("layerProperties.cancel")
                Button("OK") { _ = model.ok() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("layerProperties.ok")
            }
        }
        .padding(16)
        .frame(width: 320)
        .accessibilityIdentifier("layerProperties")
    }
}
