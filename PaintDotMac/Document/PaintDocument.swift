import AppKit
import CoreGraphics
import ImageIO

/// The document (PRD §4 Document model, APP-1). In this spec it is read-only PNG/JPEG (Viewer
/// role): 0002 replaces `image` with `LayeredImage`, and 0005 adds writing and enables the Save
/// items.
final class PaintDocument: NSDocument {
    /// `autosavesInPlace` is off, so a JPEG is never silently re-encoded (PRD §5.11 Saving, D-6).
    override class var autosavesInPlace: Bool { false }

    /// Single source of truth; `readableTypes` exposes it in declaration order. `nonisolated`
    /// because `read(from:ofType:)` runs off the main actor path and this only holds constants.
    nonisolated private static let readableTypeNames: [String] = ["public.png", "public.jpeg"]

    override class var readableTypes: [String] { readableTypeNames }

    /// Reading happens on the main thread for now.
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    /// The decoded image. 0002 replaces this with the `LayeredImage` document model.
    private(set) var image: CGImage?

    /// The decoded image's width and height in pixels.
    var imagePixelSize: CGSize? {
        image.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// The actions 0001 disables; 0005 removes these overrides.
    private static let disabledActions: Set<Selector> = [
        NSSelectorFromString("saveDocument:"),
        NSSelectorFromString("saveDocumentAs:"),
        NSSelectorFromString("saveDocumentTo:"),
        NSSelectorFromString("revertDocumentToSaved:"),
        NSSelectorFromString("duplicateDocument:"),
    ]

    /// Content is decoded by sniffing, not by extension: a JPEG named `.png` opens. Color
    /// conversion, ICC handling, and size limits (FMT-B, APP-10) are 0002's job.
    override func read(from data: Data, ofType typeName: String) throws {
        guard Self.readableTypeNames.contains(typeName) else {
            throw CocoaError(.fileReadUnknown)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              // ImageIO calls truncated PNG/JPEG "complete" on macOS 27; see ContainerCompleteness.
              ContainerCompleteness.isComplete(data),
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0,
                  [kCGImageSourceShouldCacheImmediately as String: true] as CFDictionary),
              image.width > 0, image.height > 0
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // `read(from:ofType:)` is imported nonisolated, but this document returns
        // `canConcurrentlyReadDocuments == false`, so AppKit reads on the main thread.
        MainActor.assumeIsolated {
            self.image = image
        }
    }

    override func makeWindowControllers() {
        // After a successful read `image` is never nil; a document without an image gets no window.
        guard let image else { return }
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
