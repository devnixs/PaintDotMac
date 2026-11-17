import AppKit
import Foundation
import UniformTypeIdentifiers

@testable import PaintDotMac

/// A private pasteboard (AGENTS.md *Headless testing*: the user's clipboard is off limits).
/// `DocumentHarness.newImage` releases it with `releaseGlobally()` after the New Image flow
/// reads it; a leaked named pasteboard would be process-local garbage either way.
func makePrivatePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("PaintDotMacTests-\(UUID().uuidString)"))
}

/// The 0005 default clipboard image: deterministic gradient, opaque.
private func defaultPixel(_ x: Int, _ y: Int) -> ColorRGBA8 {
    ColorRGBA8(red: UInt8(x % 256), green: UInt8(y % 256), blue: UInt8((x &+ y) % 256), alpha: 255)
}

/// Puts a generated PNG (deterministic gradient, opaque) on `pasteboard` as a clipboard
/// image, the way a screenshot or Copy would.
func writeImage(width: Int, height: Int, to pasteboard: NSPasteboard) {
    writeImage(width: width, height: height, pixel: defaultPixel, to: pasteboard)
}

/// Puts a generated clipboard image on `pasteboard`: a PNG from a pixel closure, or —
/// with `asTIFFOnly` — only `public.tiff` (0021: the read-order and menu tests).
func writeImage(width: Int, height: Int, pixel: @escaping (Int, Int) -> ColorRGBA8,
                asTIFFOnly: Bool = false, to pasteboard: NSPasteboard) {
    let bytes = TestImages.rgbaBytes(width: width, height: height, pixel)
    let image = TestImages.cgImage(width: width, height: height, bytes: bytes)
    if asTIFFOnly {
        pasteboard.setData(TestImages.encode(image, as: .tiff),
                           forType: NSPasteboard.PasteboardType(ClipboardImageCodec.tiffType))
    } else {
        pasteboard.setData(TestImages.encode(image, as: .png),
                           forType: NSPasteboard.PasteboardType(ClipboardImageCodec.pngType))
    }
}

/// Puts a file URL on `pasteboard` the way a Finder ⌘C does (0021's file-URL read path).
func writeFileURL(_ url: URL, to pasteboard: NSPasteboard) {
    pasteboard.writeObjects([url as NSURL])
}

/// Puts plain text on `pasteboard` — the "not an image" validation case (0021).
func writeText(_ text: String, to pasteboard: NSPasteboard) {
    pasteboard.setString(text, forType: .string)
}

/// Decodes the pasteboard's PNG through 0002's decoder: its size and straight RGBA8
/// bytes, or `nil` when there is no PNG / it doesn't decode.
func readPNG(from pasteboard: NSPasteboard) -> (width: Int, height: Int, rgba: [UInt8])? {
    guard let data = pasteboard.data(forType: .png),
          let decoded = try? ImageDecoder.decode(data, limits: .standard)
    else { return nil }
    return (decoded.surface.size.width, decoded.surface.size.height,
            decoded.surface.readPixels(in: decoded.surface.bounds))
}

/// The first pasteboard item's type identifiers, in order (`[]` for an empty pasteboard).
func types(of pasteboard: NSPasteboard) -> [String] {
    pasteboard.pasteboardItems?.first?.types.map(\.rawValue) ?? []
}
