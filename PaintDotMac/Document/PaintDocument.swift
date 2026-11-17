import AppKit

/// The document (PRD §4 Document model, APP-1). Reads PNG/JPEG; 0005 adds PNG writing (F-2)
/// and the §5.11 "Saving" rules. 0028 adds `.ora`; 0029 completes the writable formats.
/// Not `final`: the headless tests subclass it to record `saveAs(_:)` routing (the save
/// panel itself can never run in a test).
class PaintDocument: NSDocument {
    /// `autosavesInPlace` is off, so a JPEG is never silently re-encoded (PRD §5.11 Saving, D-6).
    override class var autosavesInPlace: Bool { false }

    /// Permanent until 0047 (interim rule 4): returning the `.ora` autosave type here is
    /// 0047's crash-recovery work; `nil` keeps `NSDocument` from ever writing a PNG autosave.
    override var autosavingFileType: String? { nil }

    /// Single source of truth; `readableTypes` exposes it in declaration order. `nonisolated`
    /// because `read(from:ofType:)` runs off the main actor path and this only holds constants.
    nonisolated private static let readableTypeNames: [String] = ["public.png", "public.jpeg"]

    override class var readableTypes: [String] { readableTypeNames }

    /// Reading happens on the main thread for now. `LayeredImage` is `Sendable`, so a later
    /// switch to background reads stays safe.
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    /// Test seam for the APP-10 memory cap (integration tests set it and restore `nil` in a
    /// `defer`).
    @MainActor static var imageLimitsOverride: ImageLimits?

    /// The limits `read(from:ofType:)` and the New Image dialog enforce (APP-10).
    @MainActor static var imageLimits: ImageLimits { imageLimitsOverride ?? .standard }

    /// The history bridge (spec 0008): the single source of the document's pixels and of
    /// the edited state. Its budget comes from `AppSettings.undoBudgetBytes` (NF-4).
    let undoBridge: UndoBridge

    /// The document model. A document that hasn't read or created anything yet holds a 1×1
    /// transparent placeholder; File > New replaces it before any window is made (0005),
    /// the history owns every later change (0008), and no code path force-unwraps it.
    @MainActor var image: LayeredImage { undoBridge.state.image }

    override init() {
        undoBridge = UndoBridge(
            state: DocumentState(image: .blank(size: PixelSize(width: 1, height: 1),
                                               fill: .clear)),
            base: .newImage,
            budgetBytes: AppSettings().undoBudgetBytes
        )
        super.init()
        // NSDocument must not count changes from undo notifications — the field editor's
        // typing registers on the window's undo manager, and the history is the single
        // source of the edited state (0008 item 11). `init(type:)` (the untitled path)
        // runs through here too: AppKit's `initWithType:` calls `init`.
        hasUndoManager = false
        undoBridge.onEditedChange = { [weak self] isEdited in
            // `.changeDone` on every edit also lets the 0047 autosave see new changes.
            self?.updateChangeCount(isEdited ? .changeDone : .changeCleared)
        }
    }

    /// Content is decoded by sniffing, not by extension: a JPEG named `.png` opens.
    /// `ImageCodecError` propagates unchanged, so `NSDocumentController` shows its standard
    /// alert with our `errorDescription` and `recoverySuggestion` (FMT-B, APP-10). A failed
    /// read leaves the state unchanged; a successful one resets the history to a single
    /// "Open Image" step (also the File > Revert To Saved path), so an opened document is
    /// clean (APP-9).
    override func read(from data: Data, ofType typeName: String) throws {
        guard Self.readableTypeNames.contains(typeName) else {
            throw CocoaError(.fileReadUnknown)
        }
        // `read(from:ofType:)` is imported nonisolated, but this document returns
        // `canConcurrentlyReadDocuments == false`, so AppKit reads on the main thread.
        let limits = MainActor.assumeIsolated { Self.imageLimits }
        let decoded = try ImageDecoder.decodeImage(from: data, limits: limits)
        MainActor.assumeIsolated {
            self.undoBridge.reset(state: DocumentState(image: decoded), base: .openImage)
        }
    }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(image: image))
    }

    // MARK: - Writing (spec 0005, F-2)

    /// Only PNG is writable in M0, for every save operation; the save panel's format list and
    /// the Save As type follow from this (0028 adds `.ora`, 0029 the rest).
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        FileFormat.writableFormats.map(\.typeIdentifier)
    }

    /// The save panel's extension per format ("public.png" → "png"); unknown names keep
    /// `NSDocument`'s behavior.
    override func fileNameExtension(forType typeName: String,
                                    saveOperation: NSDocument.SaveOperationType) -> String? {
        FileFormat(typeIdentifier: typeName)?.preferredFilenameExtension
            ?? super.fileNameExtension(forType: typeName, saveOperation: saveOperation)
    }

    /// Encoding is synchronous in M0 (0048 revisits asynchronous writing). Errors propagate
    /// so `NSDocument` shows its standard error alert; the document stays open and keeps its
    /// edited state. `nonisolated` because `NSDocument` calls this on its background save
    /// queue (saving is asynchronous since 10.7); the `@MainActor` model is snapshotted
    /// thread-safely below — `LayeredImage` is `Sendable`, and while a save is in flight the
    /// main thread is idle (the save was fired off it), so the hop can never deadlock.
    nonisolated override func data(ofType typeName: String) throws -> Data {
        let image = imageSnapshot()
        guard let format = FileFormat(typeIdentifier: typeName) else {
            throw ImageCodecError.encodingFailed
        }
        return try ImageEncoder.encode(image, as: format)
    }

    private nonisolated func imageSnapshot() -> LayeredImage {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { self.image }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { self.image } }
    }

    /// §5.11: ⌘S writes the document in its own format. A document whose format can't be
    /// written yet (JPEG until 0029) behaves exactly like File > Save As…; untitled documents
    /// go through `super`, which already runs the save panel.
    override func save(_ sender: Any?) {
        let action = FileFormat.saveAction(for: FileFormat(typeIdentifier: fileType ?? ""))
        if fileURL != nil, case .saveAs = action {
            saveAs(sender)
            return
        }
        super.save(sender)
    }

    /// The save panel offers only the writable formats, suggests the base name with the PNG
    /// extension, and opens in the current file's folder. `NSDocument` keeps its default
    /// format accessory, which now lists only PNG.
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowedContentTypes = FileFormat.writableFormats.map(\.utType)
        savePanel.nameFieldStringValue = FileFormat.suggestedFilename(
            original: fileURL?.lastPathComponent,
            untitledName: displayName,
            format: FileFormat.defaultNewDocumentFormat
        )
        if let directory = fileURL?.deletingLastPathComponent() {
            savePanel.directoryURL = directory
        }
        return true
    }

    // MARK: - Edited state and saved marker (spec 0008)

    /// Save commits a pending tool edit first (0009's in-progress stroke, later shapes
    /// and text), so an uncommitted edit is committed and lands in the file. 0020: the
    /// reason is `.save` — Move Selected Pixels keeps its pixels floating and the file
    /// simply gets the rendered layer (D-47b).
    override func save(to url: URL, ofType typeName: String,
                       for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        undoBridge.prepareForSave()
        super.save(to: url, ofType: typeName, for: saveOperation,
                   completionHandler: completionHandler)
    }

    /// The save token carries the history step that is being saved (0008 item 11), so a
    /// successful save marks exactly that step saved — an edit made while the async save
    /// was running keeps the document dirty.
    override func changeCountToken(for saveOperation: NSDocument.SaveOperationType) -> Any {
        let superToken = Optional(super.changeCountToken(for: saveOperation)) as? String
        return HistorySaveToken(stepID: undoBridge.history.currentStepID,
                                superToken: superToken).encoded
    }

    override func updateChangeCount(withToken changeCountToken: Any,
                                    for saveOperation: NSDocument.SaveOperationType) {
        guard let encoded = changeCountToken as? String,
              let token = HistorySaveToken(decode: encoded) else {
            super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
            return
        }
        guard saveOperation == .saveOperation || saveOperation == .saveAsOperation else {
            // `.saveToOperation` and autosave operations never mark saved and never
            // clear the edited state (0008; PRD §5.11) — NSDocument's own token logic
            // would clear the flag, so it is deliberately not consulted here.
            return
        }
        if let superToken = token.superToken {
            super.updateChangeCount(withToken: superToken, for: saveOperation)
        }
        // `markSaved` re-syncs the edited state through `onEditedChange`.
        undoBridge.markSaved(stepID: token.stepID)
    }
}

/// `NSDocument`'s change-count token is a string; this encodes the history step the save
/// captures plus the superclass token (spec 0008 item 11).
private struct HistorySaveToken {
    var stepID: HistoryStep.ID
    var superToken: String?

    private static let prefix = "PaintDotMac.history:"

    var encoded: String { Self.prefix + "\(stepID):" + (superToken ?? "") }

    init(stepID: HistoryStep.ID, superToken: String?) {
        self.stepID = stepID
        self.superToken = superToken
    }

    init?(decode token: String) {
        guard token.hasPrefix(Self.prefix) else { return nil }
        let body = token.dropFirst(Self.prefix.count)
        guard let colon = body.firstIndex(of: ":"),
              let stepID = Int(body[..<colon])
        else { return nil }
        let tail = body[body.index(after: colon)...]
        self.init(stepID: stepID, superToken: tail.isEmpty ? nil : String(tail))
    }
}
