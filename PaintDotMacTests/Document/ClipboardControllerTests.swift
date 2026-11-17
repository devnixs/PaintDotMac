import AppKit
import Foundation
import Testing

@testable import PaintDotMac

/// `ClipboardController` against a private pasteboard (AGENTS.md *Headless testing*):
/// the exact two types on write, `canPaste` per state, and the change-count cache
/// (spec 0021 *Test plan*).
@MainActor
struct ClipboardControllerTests {
    private func controller() -> (ClipboardController, NSPasteboard) {
        let pasteboard = makePrivatePasteboard()
        return (ClipboardController(pasteboard: pasteboard), pasteboard)
    }

    @Test func writePutsPNGAndTIFF() throws {
        let (clipboard, pasteboard) = controller()
        defer { pasteboard.releaseGlobally() }
        let surface = TestImages.surface(width: 5, height: 4) { x, y in
            ColorRGBA8(red: UInt8(x * 40), green: UInt8(y * 50), blue: 7, alpha: 255)
        }
        try clipboard.write(surface, dpi: 96)
        #expect(types(of: pasteboard) == [ClipboardImageCodec.pngType, ClipboardImageCodec.tiffType],
                "exactly the two types, PNG first (E-5)")
        #expect(clipboard.canPaste == true)
        guard let read = readPNG(from: pasteboard) else { Issue.record("no PNG"); return }
        #expect(read.width == 5 && read.height == 4)
        #expect(read.rgba == surface.readPixels(in: surface.bounds), "the PNG decodes to the written pixels")
    }

    @Test func canPasteTracksThePasteboard() {
        let (clipboard, pasteboard) = controller()
        defer { pasteboard.releaseGlobally() }
        #expect(clipboard.canPaste == false, "empty pasteboard")
        writeText("hi", to: pasteboard)
        #expect(clipboard.canPaste == false, "text is not an image")
        writeImage(width: 8, height: 8, to: pasteboard)
        #expect(clipboard.canPaste == true)
        _ = pasteboard.clearContents()
        #expect(clipboard.canPaste == false, "clearContents changes changeCount → re-evaluated")
    }

    /// `write` encodes before `clearContents` (0021 item 7): a failed encode leaves the
    /// old clipboard untouched. The invalid DPI reaches the codec's DPI guard.
    @Test func writeFailureLeavesPasteboardUntouched() throws {
        let (clipboard, pasteboard) = controller()
        defer { pasteboard.releaseGlobally() }
        writeImage(width: 7, height: 5, to: pasteboard)
        let before = pasteboard.data(forType: .png)
        let surface = TestImages.surface(width: 4, height: 4) { _, _ in .white }
        #expect(throws: ImageCodecError.encodingFailed,
                performing: { try clipboard.write(surface, dpi: 0) })
        #expect(pasteboard.data(forType: .png) == before,
                "the old PNG survives the failed write")
        #expect(clipboard.canPaste == true, "nothing about the board changed")
    }

    /// A multi-item pasteboard (Finder-style: a text note item, then the image item):
    /// the type check spans items and the image item decodes.
    @Test func multiItemPasteboardReadsTheImageItem() throws {
        let (clipboard, pasteboard) = controller()
        defer { pasteboard.releaseGlobally() }
        let textItem = NSPasteboardItem()
        textItem.setString("a note", forType: .string)
        let surface = TestImages.surface(width: 6, height: 4) { x, y in
            ColorRGBA8(red: UInt8(x * 30), green: UInt8(y * 40), blue: 200, alpha: 255)
        }
        let (png, tiff) = try ClipboardImageCodec.encode(surface, dpi: 96)
        let imageItem = NSPasteboardItem()
        imageItem.setData(png, forType: NSPasteboard.PasteboardType(ClipboardImageCodec.pngType))
        imageItem.setData(tiff, forType: NSPasteboard.PasteboardType(ClipboardImageCodec.tiffType))
        pasteboard.writeObjects([textItem, imageItem])
        #expect(clipboard.canPaste == true, "the type list spans items")
        let image = try #require(try clipboard.readImage(limits: .standard).get().surface
                                    as TiledSurface?)
        #expect(image.size == PixelSize(width: 6, height: 4))
        TestImages.expectPixels(image, match: { x, y in
            surface.pixel(at: PixelPoint(x: x, y: y))
        }, "the second item's image decodes")
    }

    /// Untrusted bytes on the board: `canPaste` is type-only (it never decodes), so a
    /// corrupt PNG/TIFF pair stays "pasteable" but reads as `.noImage` — no crash, no
    /// allocation past the header checks.
    @Test func malformedPasteboardDataIsNoImage() throws {
        let (clipboard, pasteboard) = controller()
        defer { pasteboard.releaseGlobally() }
        var junk = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])  // PNG signature
        junk.append(contentsOf: (0..<512).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        pasteboard.setData(junk, forType: NSPasteboard.PasteboardType(ClipboardImageCodec.pngType))
        pasteboard.setData(Data("not a tiff".utf8),
                           forType: NSPasteboard.PasteboardType(ClipboardImageCodec.tiffType))
        #expect(clipboard.canPaste == true, "canPaste inspects types, never bytes")
        #expect(clipboard.readImage(limits: .standard) == .failure(.noImage))
    }

    @Test func readImageUsesContents() throws {
        let (clipboard, pasteboard) = controller()
        defer { pasteboard.releaseGlobally() }
        writeImage(width: 6, height: 3, to: pasteboard)
        let image = try #require(try clipboard.readImage(limits: .standard).get().surface
                                    as TiledSurface?)
        #expect(image.size == PixelSize(width: 6, height: 3))
        #expect(clipboard.changeCount == pasteboard.changeCount)
    }
}
