import AppKit
import Foundation
import UniformTypeIdentifiers

/// The only code that touches `NSPasteboard` for images (spec 0021 item 6; PRD E-5,
/// D-30). `PaintDocumentController.newDocument(_:)` reads the New Image size through it
/// too. The pasteboard is an injected dependency (AGENTS.md *Headless testing*): tests
/// pass a private `NSPasteboard(name:)` and never touch the user's clipboard.
@MainActor
final class ClipboardController {
    /// The app-wide controller. Integration tests swap in one on a private pasteboard
    /// (`DocumentHarness.useClipboard`) and restore it afterwards.
    static var shared = ClipboardController(pasteboard: .general)

    let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// E-5 write side: clears the pasteboard and puts exactly two types — `public.png`
    /// then `public.tiff` — on one item. Encoding runs before `clearContents`, so a
    /// failed encode never changes what is on the pasteboard (the caller alerts instead).
    func write(_ surface: TiledSurface, dpi: Double) throws(ImageCodecError) {
        let (png, tiff) = try ClipboardImageCodec.encode(surface, dpi: dpi)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: NSPasteboard.PasteboardType(ClipboardImageCodec.pngType))
        item.setData(tiff, forType: NSPasteboard.PasteboardType(ClipboardImageCodec.tiffType))
        pasteboard.writeObjects([item])
    }

    /// Menu-validation decision, cached so the file-URL `resourceValues` checks stay
    /// cheap (`validateMenuItem` runs on every menu tracking cycle). The cache key is
    /// the change count *and* the cheap snapshot (declared types + file-URL list):
    /// `NSPasteboard.setData` on a named (test) pasteboard changes the contents without
    /// bumping `changeCount`, so the change count alone would go stale.
    var canPaste: Bool {
        let snapshot = PasteboardSnapshot(changeCount: changeCount,
                                          types: pasteboard.types?.map(\.rawValue) ?? [],
                                          fileURLs: contents().fileURLs)
        if let cache = canPasteCache, cache.snapshot == snapshot { return cache.value }
        let value = ClipboardImageCodec.canPaste(
            types: snapshot.types,
            fileURLTypes: snapshot.fileURLs.compactMap(Self.contentType(of:)))
        canPasteCache = (snapshot, value)
        return value
    }

    private struct PasteboardSnapshot: Equatable {
        var changeCount: Int
        var types: [String]
        var fileURLs: [URL]
    }

    /// The pasteboard's image offers, in E-5 order. No file is opened: only the URL list
    /// is read here; `readImage` fetches file contents lazily through the codec.
    func contents() -> ClipboardContents {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return ClipboardContents(
            pngData: pasteboard.data(forType: NSPasteboard.PasteboardType(ClipboardImageCodec.pngType)),
            tiffData: pasteboard.data(forType: NSPasteboard.PasteboardType(ClipboardImageCodec.tiffType)),
            fileURLs: urls
        )
    }

    /// `contents()` through `ClipboardImageCodec.read` (E-5 read order, 0002's decoder,
    /// 0002's limits). `readFile` is `Data(contentsOf:)` — a deleted file throws and the
    /// codec skips that candidate.
    func readImage(limits: ImageLimits) -> Result<ClipboardImage, ClipboardReadError> {
        ClipboardImageCodec.read(contents(), limits: limits, readFile: { try Data(contentsOf: $0) })
    }

    /// Lets `canPaste` cache per change (pasteboard changeCount; spec 0021 item 6).
    var changeCount: Int { pasteboard.changeCount }

    private var canPasteCache: (snapshot: PasteboardSnapshot, value: Bool)?

    /// The URL's UTType without opening it: the Finder's content type first, the
    /// filename extension as fallback (a missing file has no resource values — the
    /// codec skips it when reading).
    private static func contentType(of url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension)
    }
}
