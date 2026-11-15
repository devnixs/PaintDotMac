import AppKit

/// The document (PRD §4 Document model, APP-1). Reads PNG/JPEG; 0005 adds PNG writing (F-2)
/// and the §5.11 "Saving" rules. 0028 adds `.ora`; 0029 completes the writable formats.
final class PaintDocument: NSDocument {
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

    /// The document model. A document that hasn't read or created anything yet holds a 1×1
    /// transparent placeholder; File > New replaces it before any window is made (0005), and
    /// no code path force-unwraps it.
    @MainActor var image = LayeredImage.blank(size: PixelSize(width: 1, height: 1), fill: .clear)

    /// Content is decoded by sniffing, not by extension: a JPEG named `.png` opens.
    /// `ImageCodecError` propagates unchanged, so `NSDocumentController` shows its standard
    /// alert with our `errorDescription` and `recoverySuggestion` (FMT-B, APP-10). A failed
    /// read leaves `image` unchanged.
    override func read(from data: Data, ofType typeName: String) throws {
        guard Self.readableTypeNames.contains(typeName) else {
            throw CocoaError(.fileReadUnknown)
        }
        // `read(from:ofType:)` is imported nonisolated, but this document returns
        // `canConcurrentlyReadDocuments == false`, so AppKit reads on the main thread.
        let limits = MainActor.assumeIsolated { Self.imageLimits }
        let decoded = try ImageDecoder.decodeImage(from: data, limits: limits)
        MainActor.assumeIsolated {
            self.image = decoded
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
}
