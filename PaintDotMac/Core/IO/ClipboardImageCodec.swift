import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A decoded clipboard image (spec 0021; PRD E-5). The clipboard's DPI is ignored
/// (APP-9 / D-30) — only the pixels travel.
struct ClipboardImage: Equatable, Sendable {
    /// Straight sRGB RGBA8, exactly as 0002's decoder produced it (FMT-B: ICC converted,
    /// 8-bit, EXIF orientation applied; color under alpha 0 kept for straight sources).
    var surface: TiledSurface
    var size: PixelSize { surface.size }

    init(surface: TiledSurface) {
        self.surface = surface
    }
}

/// What the pasteboard offers, captured by the platform glue (spec 0021). Pure value;
/// tests build it directly.
struct ClipboardContents: Sendable {
    var pngData: Data?
    var tiffData: Data?
    /// In pasteboard order; only file URLs.
    var fileURLs: [URL]

    init(pngData: Data? = nil, tiffData: Data? = nil, fileURLs: [URL] = []) {
        self.pngData = pngData
        self.tiffData = tiffData
        self.fileURLs = fileURLs
    }
}

/// Why nothing could be pasted (spec 0021).
enum ClipboardReadError: Error, Equatable, Sendable {
    /// Nothing decodable.
    case noImage
    /// The first candidate that hit the limits (APP-10 / D-8 / D-32).
    case limitExceeded(ImageLimitError)
}

/// PNG/TIFF bytes ↔ surfaces, the read order of E-5, and the "can paste" decision
/// (spec 0021; PRD E-2, E-5, FMT-B, D-30).
enum ClipboardImageCodec {
    /// Pasteboard type identifiers the app writes and reads, in read order.
    static let pngType = "public.png"
    static let tiffType = "public.tiff"
    static let fileURLType = "public.file-url"

    /// E-5 write side: (png, tiff) encodings of `surface`. PNG through 0005's
    /// `ImageEncoder` (straight RGBA, sRGB profile, `dpi`); TIFF through
    /// `CGImageDestination` from the same `CGImage`. The PNG keeps alpha exactly
    /// ("PNG (with alpha)"); the TIFF may premultiply internally (ImageIO's choice), so it
    /// is exact only for opaque pixels and within ±1 per channel after un-premultiplying.
    static func encode(_ surface: TiledSurface, dpi: Double) throws(ImageCodecError) -> (png: Data, tiff: Data) {
        let png = try ImageEncoder.encode(surface, size: surface.size, dpi: dpi, as: .png)
        guard LayeredImage.isValidDPI(dpi) else { throw ImageCodecError.encodingFailed }
        let image = try ImageEncoder.makeCGImage(surface, size: surface.size)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.tiff.identifier as CFString, 1, nil
        ) else { throw ImageCodecError.encodingFailed }
        // APP-5: the DPI travels with the image; no compression key (ImageIO default).
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageCodecError.encodingFailed }
        return (png, output as Data)
    }

    /// E-5 read side. Order: pngData → tiffData → each file URL in order (read through
    /// `readFile`). The first candidate that decodes wins. Each candidate goes through
    /// 0002's `ImageDecoder.decode(_:limits:)`, so ICC/CMYK/16-bit/float/gray input
    /// becomes 8-bit sRGB and EXIF orientation is applied (FMT-B). The decoded DPI is
    /// ignored (D-30).
    ///
    /// A candidate that is unrecognized or corrupt (including empty `Data`), or a file
    /// URL whose `readFile` throws, is skipped. A candidate that hits the limits is
    /// remembered (first one only) and the next is tried — a valid later candidate still
    /// wins. File URLs are read only until the first success.
    static func read(_ contents: ClipboardContents, limits: ImageLimits,
                     readFile: (URL) throws -> Data) -> Result<ClipboardImage, ClipboardReadError> {
        var firstLimitError: ImageLimitError?
        func decoded(_ data: Data?) -> ClipboardImage? {
            // Empty data is "unrecognized" — skip without decoding.
            guard let data, !data.isEmpty else { return nil }
            do {
                return ClipboardImage(surface: try ImageDecoder.decode(data, limits: limits).surface)
            } catch ImageCodecError.limitExceeded(let error) {
                if firstLimitError == nil { firstLimitError = error }
                return nil
            } catch {
                return nil  // .unrecognizedFormat / .corrupt — try the next candidate
            }
        }
        if let image = decoded(contents.pngData) ?? decoded(contents.tiffData) {
            return .success(image)
        }
        for url in contents.fileURLs {
            guard let data = try? readFile(url) else { continue }  // unreadable file — skipped
            if let image = decoded(data) { return .success(image) }
        }
        if let firstLimitError { return .failure(.limitExceeded(firstLimitError)) }
        return .failure(.noImage)
    }

    /// Cheap menu-enablement test (no decoding; it runs on every menu validation): true
    /// iff `types` contains pngType or tiffType, or any `fileURLTypes` element conforms
    /// to `UTType.image`.
    static func canPaste(types: [String], fileURLTypes: [UTType]) -> Bool {
        if types.contains(pngType) || types.contains(tiffType) { return true }
        return fileURLTypes.contains { $0.conforms(to: .image) }
    }
}

extension ClipboardReadError {
    /// The Paste / Paste into New Image alert wording (spec 0021 item 7). The memory-cap
    /// row of 0002's `ImageCodecError.recoverySuggestion` is reworded for pasting
    /// (0002 reserved that row for exactly this).
    var alertMessage: String {
        switch self {
        case .noImage: "The clipboard doesn\u{2019}t contain an image."
        case .limitExceeded: "The image is too large to paste."
        }
    }

    var alertInformativeText: String? {
        switch self {
        case .noImage:
            nil
        case .limitExceeded(.exceedsMemoryCap(let requiredBytes, let capBytes)):
            "Pasting it needs \(ByteCountFormatter.string(fromByteCount: Int64(requiredBytes), countStyle: .memory))"
                + " of memory, but the limit is "
                + "\(ByteCountFormatter.string(fromByteCount: Int64(capBytes), countStyle: .memory))."
        case .limitExceeded(let error):
            ImageCodecError.limitExceeded(error).recoverySuggestion
        }
    }
}
