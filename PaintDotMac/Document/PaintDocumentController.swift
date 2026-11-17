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
    var newImagePresenter: NewImagePresenting = ModalNewImagePresenter()
    var alertPresenter: AlertPresenting = ModalAlertPresenter()
    /// Integration tests set this `false` to build documents and windows offscreen.
    var showsWindows = true

    /// APP-9, D-30: the dialog opens with the clipboard image's size (its DPI is ignored) or
    /// 800×600. OK validates through `NewImageForm.validate(limits:)`; a refusal alerts
    /// and keeps the dialog open with the typed values. Cancel creates nothing.
    override func newDocument(_ sender: Any?) {
        let clipboardContents = ClipboardController.shared.contents()
        let clipboard = NewImageDefaults.clipboardImageSize(
            pngData: clipboardContents.pngData,
            tiffData: clipboardContents.tiffData
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
        guard let document = makeNewDocument() else { return }

        // The placeholder image is replaced before any window exists (interim rule: New
        // starts from the dialog's request, never from the 1×1 placeholder), and the
        // history begins at "New Image" — the document is clean (0008 item 11; APP-9,
        // D-30 supersede 0005's interim rule 3).
        document.undoBridge.reset(state: DocumentState(image: request.makeImage()),
                                  base: .newImage)
        presentNewDocument(document)
    }

    /// Edit > Paste into New Image ⌥⌘V (spec 0021 item 8; Paint.NET "Paste into New
    /// Image" / "Create New Image from Contents of Clipboard"): a new document *exactly*
    /// the clipboard image's size at 96 DPI (the clipboard DPI is ignored, APP-9 / D-30),
    /// made active, with the clipboard pasted at (0, 0) — history "New Image", "Paste",
    /// and the document edited. The document controller is the last responder, so this
    /// works with or without an open document. The active session's pending edit commits
    /// first (the `.command` path: floating pixels get "Finish Pixels", 0020 item 9).
    /// A no-image / too-large clipboard alerts app-modally (there may be no window).
    @objc func pasteIntoNewImage(_ sender: Any?) {
        AppModel.shared.dispatcher.commitPendingEdit()
        let clipboard = ClipboardController.shared
        let limits = PaintDocument.imageLimits
        let surface: TiledSurface
        switch clipboard.readImage(limits: limits) {
        case .failure(let error):
            alertPresenter.showAlert(message: error.alertMessage,
                                     informativeText: error.alertInformativeText)
            return
        case .success(let image):
            surface = image.surface
        }
        guard let document = makeNewDocument() else { return }
        let request = NewImageRequest(size: surface.size, dpi: NewImageDefaults.fallbackDPI)
        document.undoBridge.reset(state: DocumentState(image: request.makeImage()),
                                  base: .newImage)
        presentNewDocument(document)

        // The paste: sizes are equal, so no E-6 prompt is possible — origin (0, 0) over
        // the full-canvas visible rect (0020's policy activates Move Selected Pixels in
        // the new window).
        let bridge = document.undoBridge
        let size = surface.size
        let plan = PastePlanner.plan(
            clipboardSize: size, canvasSize: size,
            visibleCanvasRect: CGRect(x: 0, y: 0,
                                      width: CGFloat(size.width), height: CGFloat(size.height)),
            choice: nil)
        bridge.perform(PasteStep.makeHistoryItem(surface: surface, plan: plan,
                                                 state: bridge.state, expanded: nil,
                                                 baseStepID: bridge.history.currentStepID))
    }

    /// `Paste into New Image` is enabled whenever the pasteboard offers an image, with or
    /// without an open document (0021). `NSDocumentController` vends its own validation
    /// through `NSUserInterfaceValidations`, so the override lives there.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == NSSelectorFromString("pasteIntoNewImage:") {
            return ClipboardController.shared.canPaste
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - Shared New-document path

    /// The New Image creation half, shared by `newDocument(_:)` and
    /// `pasteIntoNewImage(_:)`: an untitled document or the "couldn't create" alert.
    private func makeNewDocument() -> PaintDocument? {
        do {
            guard let created = try makeUntitledDocument(
                ofType: FileFormat.defaultNewDocumentFormat.typeIdentifier
            ) as? PaintDocument else {
                throw CocoaError(.coderReadCorrupt)
            }
            return created
        } catch {
            // Only a broken Info.plist document-type table reaches this.
            alertPresenter.showAlert(message: "PaintDotMac couldn\u{2019}t create a new image.",
                                     informativeText: error.localizedDescription)
            return nil
        }
    }

    /// Register, build the window controllers, and show them (only when `showsWindows`,
    /// 0005) — headless tests build the windows through `DocumentHarness` instead.
    private func presentNewDocument(_ document: PaintDocument) {
        addDocument(document)
        document.makeWindowControllers()
        if showsWindows {
            document.showWindows()
        }
    }
}
