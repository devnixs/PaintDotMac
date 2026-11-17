import AppKit
import SwiftUI

/// Presents the New Image dialog (spec 0005). `present` returns true only when the user
/// confirmed and `onOK` accepted the typed values; on Cancel — or when the script/loop ends
/// without an accepted OK — it returns false and nothing is created. The presenter passes
/// each dialog edit through `onOK`, which validates; a false result keeps the dialog open
/// with the typed values unchanged.
@MainActor
protocol NewImagePresenting {
    func present(form: NewImageForm, onOK: @escaping (NewImageForm) -> Bool) -> Bool
}

/// Presents an error alert (New Image validation, save failures). Tests record instead.
@MainActor
protocol AlertPresenting {
    func showAlert(message: String, informativeText: String?)
}

/// The real New Image presenter: `NewImageDialog` in an app-modal `NSPanel`
/// (`NSHostingController`, `NSApp.runModal(for:)`), so it works with no document open.
@MainActor
final class ModalNewImagePresenter: NSObject, NewImagePresenting, NSWindowDelegate {
    /// Keeps the panel alive (and our delegate wiring) across the modal session.
    private var panel: NSPanel?

    func present(form initialForm: NewImageForm, onOK: @escaping (NewImageForm) -> Bool) -> Bool {
        var form = initialForm
        let dialog = NewImageDialog(
            form: Binding(get: { form }, set: { form = $0 }),
            onOK: {
                // Validation happens in the caller; a refusal alerts and stays open.
                if onOK(form) { NSApp.stopModal(withCode: .OK) }
            },
            onCancel: { NSApp.stopModal(withCode: .cancel) }
        )
        let panel = NSPanel(contentViewController: NSHostingController(rootView: dialog))
        panel.title = NewImageDialog.windowTitle
        panel.styleMask = [.titled]
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier(NewImageDialog.dialogIdentifier)
        panel.setAccessibilityIdentifier(NewImageDialog.dialogIdentifier)
        panel.delegate = self
        self.panel = panel
        panel.center()
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        panel.delegate = nil
        self.panel = nil
        return response == .OK
    }

    /// The close box is Cancel; closing the panel without stopping the modal session would
    /// hang the app.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.stopModal(withCode: .cancel)
        return false
    }
}

/// The real alert presenter: a one-button `NSAlert`. `sheetWindow` (0021) runs it as that
/// window's sheet — document-window alerts are sheets; with no window (document
/// controller) it stays app-modal.
@MainActor
struct ModalAlertPresenter: AlertPresenting {
    var sheetWindow: NSWindow?

    func showAlert(message: String, informativeText: String?) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informativeText ?? ""
        alert.addButton(withTitle: "OK")
        if let sheetWindow {
            alert.beginSheetModal(for: sheetWindow)
        } else {
            alert.runModal()
        }
    }
}
