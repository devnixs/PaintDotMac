import AppKit

/// The document (PRD §4 Document model, APP-1). Read-only PNG/JPEG (Viewer role): the pixel
/// model is the 0002 `LayeredImage`; 0005 adds writing and enables the Save items.
final class PaintDocument: NSDocument {
    /// `autosavesInPlace` is off, so a JPEG is never silently re-encoded (PRD §5.11 Saving, D-6).
    override class var autosavesInPlace: Bool { false }

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

    /// The limits `read(from:ofType:)` enforces (APP-10).
    @MainActor static var imageLimits: ImageLimits { imageLimitsOverride ?? .standard }

    /// The decoded image. A document that hasn't read anything yet holds a 1×1 transparent
    /// image until 0005 adds New Image; no code path force-unwraps it.
    @MainActor private(set) var image = LayeredImage.blank(size: PixelSize(width: 1, height: 1), fill: .clear)

    /// The actions 0001 disables; 0005 removes these overrides.
    private static let disabledActions: Set<Selector> = [
        NSSelectorFromString("saveDocument:"),
        NSSelectorFromString("saveDocumentAs:"),
        NSSelectorFromString("saveDocumentTo:"),
        NSSelectorFromString("revertDocumentToSaved:"),
        NSSelectorFromString("duplicateDocument:"),
    ]

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

    /// Writing arrives in 0005; if reached, NSDocument presents this as an alert, not a crash.
    override func data(ofType typeName: String) throws -> Data {
        throw CocoaError(.fileWriteUnknown)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let action = item.action, Self.disabledActions.contains(action) {
            return false
        }
        return super.validateUserInterfaceItem(item)
    }
}
