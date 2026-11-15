import AppKit
import SwiftUI

/// The New Image dialog's content (spec 0005, APP-9), hosted in `ModalNewImagePresenter`'s
/// app-modal panel. The view holds no validation logic: OK calls the `onOK` closure the
/// presenter supplies, which validates through `NewImageForm.validate(limits:)` and returns
/// whether the dialog may close.
@MainActor
struct NewImageDialog: View {
    static let windowTitle = "New Image"
    static let dialogIdentifier = "newImageDialog"

    @Binding private var form: NewImageForm
    private let onOK: () -> Void
    private let onCancel: () -> Void

    @FocusState private var focusedField: Field?

    enum Field { case width, height, resolution }

    init(form: Binding<NewImageForm>, onOK: @escaping () -> Void, onCancel: @escaping () -> Void) {
        _form = form
        self.onOK = onOK
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Pixel size") {
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 8) {
                    GridRow {
                        Text("Width:")
                        sizeField($form.widthText, field: .width, identifier: "newImage.width")
                        Text("pixels")
                    }
                    GridRow {
                        Text("Height:")
                        sizeField($form.heightText, field: .height, identifier: "newImage.height")
                        Text("pixels")
                    }
                }
                .padding(4)
            }
            Grid(alignment: .leading, horizontalSpacing: 6) {
                GridRow {
                    Text("Resolution:")
                    sizeField($form.resolutionText, field: .resolution, identifier: "newImage.resolution")
                    Text("pixels/inch")
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("newImage.cancel")
                Button("OK") { onOK() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("newImage.ok")
            }
        }
        .padding()
        .accessibilityIdentifier(Self.dialogIdentifier)
        .onAppear {
            // Paint.NET's New dialog focuses Width with the text selected, so typing replaces it.
            focusedField = .width
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private func sizeField(_ text: Binding<String>, field: Field, identifier: String) -> some View {
        TextField("", text: text)
            .labelsHidden()
            .frame(width: 90)
            .focused($focusedField, equals: field)
            .accessibilityIdentifier(identifier)
    }
}
