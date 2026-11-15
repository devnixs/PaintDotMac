import AppKit

/// The shared document controller (spec 0005): File > New… shows the New Image dialog (APP-9)
/// prefilled from the clipboard and creates the white "Background" document. Instantiated by
/// `AppDelegate.applicationWillFinishLaunching(_:)` before anything touches
/// `NSDocumentController.shared`, so it becomes the shared controller.
///
/// Every presentation goes through an injectable seam (AGENTS.md *Headless testing*):
/// integration tests install a scripted presenter, a recording alert presenter, a private
/// pasteboard, and `showsWindows = false`, so no dialog, alert, or window ever appears.
@MainActor
final class PaintDocumentController: NSDocumentController {
    /// The clipboard source (AGENTS.md: app code takes the pasteboard as a dependency).
    var pasteboard: NSPasteboard = .general
    var newImagePresenter: NewImagePresenting = ModalNewImagePresenter()
    var alertPresenter: AlertPresenting = ModalAlertPresenter()
    /// Integration tests set this `false` to build documents and windows offscreen.
    var showsWindows = true

    /// APP-9, D-30: the dialog opens with the clipboard image's size (its DPI is ignored) or
    /// 800×600 @ 96. OK validates through `NewImageForm.validate(limits:)`; a refusal alerts
    /// and keeps the dialog open with the typed values. Cancel creates nothing.
    override func newDocument(_ sender: Any?) {
        let clipboard = NewImageDefaults.clipboardImageSize(
            pngData: pasteboard.data(forType: .png),
            tiffData: pasteboard.data(forType: .tiff)
        )
        let initialForm = NewImageForm(
            request: NewImageDefaults.initialRequest(clipboardImageSize: clipboard)
        )
        var acceptedRequest: NewImageRequest?
        let confirmed = newImagePresenter.present(form: initialForm) { form in
            switch form.validate(limits: PaintDocument.imageLimits) {
            case .success(let request):
                acceptedRequest = request
                return true
            case .failure(let error):
                // Returning false keeps the dialog open with the typed values unchanged.
                self.alertPresenter.showAlert(message: error.message, informativeText: nil)
                return false
            }
        }
        guard confirmed, let request = acceptedRequest else { return }

        let document: PaintDocument
        do {
            guard let created = try makeUntitledDocument(
                ofType: FileFormat.defaultNewDocumentFormat.typeIdentifier
            ) as? PaintDocument else {
                throw CocoaError(.coderReadCorrupt)
            }
            document = created
        } catch {
            // Only a broken Info.plist document-type table reaches this.
            alertPresenter.showAlert(message: "PaintDotMac couldn\u{2019}t create a new image.",
                                     informativeText: error.localizedDescription)
            return
        }
        // The placeholder image is replaced before any window exists (interim rule: New
        // starts from the dialog's request, never from the 1×1 placeholder).
        document.image = request.makeImage()
        addDocument(document)
        document.makeWindowControllers()
        if showsWindows {
            document.showWindows()
        }
        // Interim rule 3 until 0008's history-driven edited state: a new image is edited
        // until saved, so the close and quit prompts (PRD §5.11) are live now.
        document.updateChangeCount(.changeDone)
    }
}
