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
