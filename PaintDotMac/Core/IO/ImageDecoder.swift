import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A decoded surface plus the document DPI (APP-5).
struct DecodedImage: Equatable, Sendable {
    var surface: TiledSurface
    /// Always valid (`LayeredImage.isValidDPI`).
    var dpi: Double
}

/// ImageIO + vImage decoding into the straight sRGB RGBA8 working space (FMT-B, FMT-D,
/// APP-5, APP-10). Stateless and `Sendable`-friendly: concurrent decodes are safe. The
/// decoder never logs, asserts on input data, or traps on any byte sequence.
enum ImageDecoder {
    /// Decodes the first image in `data` into a single-layer `LayeredImage` named
    /// "Background".
    static func decodeImage(from data: Data, limits: ImageLimits = .standard) throws(ImageCodecError) -> LayeredImage {
        let decoded = try decode(data, limits: limits)
        return LayeredImage(surface: decoded.surface, dpi: decoded.dpi)
    }

    /// The full pipeline: container checks, limits, conversion, integrity, alpha-0 policy,
    /// orientation, tiling, DPI.
    static func decode(_ data: Data, limits: ImageLimits = .standard) throws(ImageCodecError) -> DecodedImage {
        // 1. Identify the container.
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache as String: false] as CFDictionary
        ), CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0 else {
            throw .unrecognizedFormat
        }

        // 2. Header properties. ImageIO withholds the dimensions of a PNG whose IDAT is
        // missing, so parse IHDR directly as a fallback — the limits must still be checked
        // before any pixel memory is allocated (APP-10).
        var properties: [CFString: Any] = [:]
        var width: Int?, height: Int?
        if let cfProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil),
           let read = cfProperties as? [CFString: Any],
           let readWidth = read[kCGImagePropertyPixelWidth] as? Int,
           let readHeight = read[kCGImagePropertyPixelHeight] as? Int {
            properties = read
            width = readWidth
            height = readHeight
        } else if let header = pngHeaderDimensions(data) {
            width = header.width
            height = header.height
        }
        guard let width, let height else { throw .corrupt }
        let orientation = ImageOrientation(exifValue: properties[kCGImagePropertyOrientation] as? Int)

        // 3. Limits on the oriented size, before any pixel memory is allocated.
        let orientedSize = orientation.orientedSize(PixelSize(width: width, height: height))
        do {
            try limits.validate(width: orientedSize.width, height: orientedSize.height)
        } catch {
            throw .limitExceeded(error)
        }

        // 4. PNG integrity: ImageIO silently decodes truncated PNGs, so walk the chunks.
        if let typeIdentifier = CGImageSourceGetType(source) as String?,
           let type = UTType(typeIdentifier), type.conforms(to: .png),
           !pngChunksAreComplete(data) {
            throw .corrupt
        }

        // 5. Decode the pixels (index 0 = the first frame of an animated GIF/WebP, FMT-D).
        guard let image = CGImageSourceCreateImageAtIndex(
            source, 0,
            [kCGImageSourceShouldCacheImmediately as String: true] as CFDictionary
        ) else {
            throw .corrupt
        }
        guard image.width == width, image.height == height else { throw .corrupt }

        // 6. Convert to straight sRGB RGBA8 (forces the pixel decode).
        var (pixels, sourceIsPremultiplied) = try convert(image)

        // 7. Truncated JPEGs still return an image, but not a complete status.
        guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw .corrupt }

        // 8. Alpha-0 policy (FMT-B, D-33): straight sources keep the stored color; on the
        // Path S premultiplied case the color is meaningless, so force (0, 0, 0, 0).
        if sourceIsPremultiplied { zeroTransparentPixels(&pixels) }

        // 9. Orientation, then 10. tiling. Intermediate buffers are released on return.
        guard let oriented = orientation.apply(to: pixels, size: PixelSize(width: width, height: height))
        else { throw .corrupt }
        pixels = []
        let size = oriented.size
        let surface = oriented.pixels.withUnsafeBytes { buffer in
            TiledSurface(size: size, rgba8: buffer, bytesPerRow: size.width * PixelFormat.rgba8.bytesPerPixel)
        }

        // 11. DPI.
        return DecodedImage(surface: surface, dpi: resolvedDPI(properties: properties, orientation: orientation))
    }

    /// Converts an already-decoded `CGImage` (no orientation, DPI 96) through the same
    /// conversion paths and limit check. Used by 0021 (clipboard) and 0030 (import).
    static func surface(from image: CGImage, limits: ImageLimits = .standard) throws(ImageCodecError) -> TiledSurface {
        do {
            try limits.validate(width: image.width, height: image.height)
        } catch {
            throw .limitExceeded(error)
        }
        let (pixels, sourceIsPremultiplied) = try convert(image)
        var orientedPixels = pixels
        if sourceIsPremultiplied { zeroTransparentPixels(&orientedPixels) }
        let size = PixelSize(width: image.width, height: image.height)
        return orientedPixels.withUnsafeBytes { buffer in
            TiledSurface(size: size, rgba8: buffer,
                         bytesPerRow: size.width * PixelFormat.rgba8.bytesPerPixel)
        }
    }

    /// Reads the width and height from a PNG's IHDR chunk (13-byte payload, big-endian).
    /// `nil` for anything that is not a PNG starting with a complete IHDR.
    static func pngHeaderDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count >= signature.count + 8 + 13 + 4,
              Array(bytes[..<signature.count]) == signature,
              bytes[8] == 0, bytes[9] == 0, bytes[10] == 0, bytes[11] == 13, // length 13
              bytes[12] == 0x49, bytes[13] == 0x48, bytes[14] == 0x44, bytes[15] == 0x52 // "IHDR"
        else { return nil }
        func bigEndian32(_ at: Int) -> Int {
            Int(UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16
                | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3]))
        }
        return (bigEndian32(16), bigEndian32(20))
    }

    /// PNG completeness: the 8-byte signature, then a walk over chunks (4-byte big-endian
    /// length ≤ 2³¹−1, 4-byte type, `length` data bytes, 4-byte CRC; CRCs are not verified)
    /// that must reach an `IEND` chunk with all of its bytes present. Bytes after `IEND` are
    /// ignored.
    static func pngChunksAreComplete(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count >= signature.count, Array(bytes[..<signature.count]) == signature else {
            return false
        }
        var offset = signature.count
        while true {
            // A chunk header (length + type) must be present, plus data and CRC.
            guard offset + 8 <= bytes.count else { return false }
            let rawLength = (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
                | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
            guard rawLength <= 0x7FFF_FFFF else { return false }
            let length = Int(rawLength)
            let dataStart = offset + 8  // past the 4-byte length and 4-byte type
            guard dataStart + length + 4 <= bytes.count else { return false }
            if bytes[offset + 4] == 0x49, bytes[offset + 5] == 0x45,
               bytes[offset + 6] == 0x4E, bytes[offset + 7] == 0x44 { // "IEND"
                return true
            }
            offset = dataStart + length + 4
        }
    }

    /// The DPI rule (APP-5, decision 10): horizontal, else vertical, else 96 — after the
    /// orientation swap for values 5–8. No rounding.
    static func resolvedDPI(properties: [CFString: Any], orientation: ImageOrientation) -> Double {
        let storedHorizontal = properties[kCGImagePropertyDPIWidth] as? Double
        let storedVertical = properties[kCGImagePropertyDPIHeight] as? Double
        // For orientations 5–8 the displayed horizontal axis was the stored vertical one.
        let horizontal = orientation.swapsDimensions ? storedVertical : storedHorizontal
        let vertical = orientation.swapsDimensions ? storedHorizontal : storedVertical
        if let horizontal, LayeredImage.isValidDPI(horizontal) { return horizontal }
        if let vertical, LayeredImage.isValidDPI(vertical) { return vertical }
        return LayeredImage.defaultDPI
    }

    // MARK: - Conversion paths (shared with `surface(from:)`)

    /// Converts a `CGImage` to a tightly packed straight sRGB RGBA8 buffer. Returns the
    /// pixels and whether the source was premultiplied (the alpha-0 rule needs it).
    ///
    /// - Path P (premultiplied 8-bit sRGB): convert to 8 bpc / 32 bpp / sRGB /
    ///   `.premultipliedLast` — a pure byte reorder with no rounding — then un-premultiply
    ///   with `ColorRGBA8.unpremultiply`, so the rounding is exactly the documented rule.
    /// - Path S (everything else): convert straight; vImage performs the ICC/ColorSync
    ///   conversion, bit-depth reduction, palette expansion, and any un-premultiplication.
    private static func convert(_ image: CGImage) throws(ImageCodecError) -> ([UInt8], Bool) {
        let alphaInfo = image.alphaInfo
        let isPremultipliedSource = alphaInfo == .premultipliedLast || alphaInfo == .premultipliedFirst
        let space = image.colorSpace
        let isSRGB8 = image.bitsPerComponent == 8
            && space?.model == .rgb
            && (space.map { $0.name == CGColorSpace.sRGB } ?? false)
        let pathP = isPremultipliedSource && isSRGB8
        // Path F: float sources. The CoreGraphics rasterizer silently zero-fills
        // `.floatComponents` images on this macOS when drawing or converting to 8-bit,
        // so quantize explicitly from a Float32 buffer (see `convertFloat`).
        if image.bitmapInfo.contains(.floatComponents) {
            return (try convertFloat(image), true)
        }
        // Path E: straight 8-bit sRGB sources copy byte-for-byte. vImage internally
        // premultiplies and would destroy the color under alpha 0 and low-alpha pixels
        // (FMT-B requires preserving them).
        let isStraightSource = alphaInfo == .last || alphaInfo == .first || alphaInfo == .none
        if isSRGB8, isStraightSource, let copied = exactStraightCopy(image) {
            return (copied, false)
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw .corrupt }
        let destinationAlpha: CGImageAlphaInfo = pathP ? .premultipliedLast : .last
        var format = vImage_CGImageFormat()
        format.bitsPerComponent = UInt32(8)
        format.bitsPerPixel = UInt32(8 * PixelFormat.rgba8.bytesPerPixel)
        format.colorSpace = Unmanaged.passUnretained(colorSpace)  // imported as Unmanaged
        format.bitmapInfo = CGBitmapInfo(rawValue: destinationAlpha.rawValue)
        format.renderingIntent = .defaultIntent
        var buffer = vImage_Buffer()
        let status = vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoFlags))
        guard status == kvImageNoError else { throw .corrupt }
        defer { free(buffer.data) }

        guard let base = buffer.data else { throw .corrupt }
        let byteCount = image.width * image.height * PixelFormat.rgba8.bytesPerPixel
        var pixels = [UInt8](UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: byteCount))

        if pathP {
            for offset in stride(from: 0, to: byteCount, by: 4) {
                let alpha = pixels[offset + 3]
                pixels[offset] = ColorRGBA8.unpremultiply(pixels[offset], alpha: alpha)
                pixels[offset + 1] = ColorRGBA8.unpremultiply(pixels[offset + 1], alpha: alpha)
                pixels[offset + 2] = ColorRGBA8.unpremultiply(pixels[offset + 2], alpha: alpha)
            }
        }
        return (pixels, isPremultipliedSource && !pathP)
    }

    /// Float sources (Path F): pull the pixels into a Float32 premultipliedLast buffer
    /// through vImage (verified byte-exact passthrough where the 8-bit conversion paths
    /// zero-fill) and quantize with Paint.NET's round-half-away-from-zero rule:
    /// `round(straight × 255 + 0.5)` on values clamped to 0…1. Reported as premultiplied,
    /// so the alpha-0 rule then zeroes colors under full transparency.
    private static func convertFloat(_ image: CGImage) throws(ImageCodecError) -> [UInt8] {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw .corrupt }
        var format = vImage_CGImageFormat()
        format.bitsPerComponent = 32
        format.bitsPerPixel = 4 * 32
        format.colorSpace = Unmanaged.passUnretained(colorSpace)  // imported as Unmanaged
        format.bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            .union(.floatComponents)
        format.renderingIntent = .defaultIntent
        var buffer = vImage_Buffer()
        let status = vImageBuffer_InitWithCGImage(&buffer, &format, nil, image,
                                                  vImage_Flags(kvImageNoFlags))
        guard status == 0 else { throw .corrupt }
        defer { free(buffer.data) }
        let width = Int(buffer.width), height = Int(buffer.height)
        let rowFloats = Int(buffer.rowBytes) / MemoryLayout<Float>.size
        let samples = buffer.data.assumingMemoryBound(to: Float.self)
        func quantize(_ sample: Float) -> UInt8 {
            let clamped = min(1, max(0, sample))
            return UInt8(clamping: Int((Float(clamped) * 255 + 0.5).rounded(.down)))
        }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let base = y * rowFloats + x * 4
                let alpha = samples[base + 3]
                let alphaByte = quantize(alpha)
                let d = (y * width + x) * 4
                if alphaByte == 0 {
                    out[d] = 0; out[d + 1] = 0; out[d + 2] = 0; out[d + 3] = 0
                } else {
                    // vImage premultiplied the source; un-premultiply in float before
                    // quantizing so the documented rounding is applied once.
                    out[d] = quantize(samples[base] / alpha)
                    out[d + 1] = quantize(samples[base + 1] / alpha)
                    out[d + 2] = quantize(samples[base + 2] / alpha)
                    out[d + 3] = alphaByte
                }
            }
        }
        return out
    }

    /// Byte-exact straight sRGB RGBA8 copy of an 8 bpc sRGB `CGImage` with `.last`,
    /// `.first`, or no alpha. `nil` when the layout or provider is unexpected — the caller
    /// then falls back to vImage.
    private static func exactStraightCopy(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard let providerData = image.dataProvider?.data else { return nil }
        let sourceStride = image.bytesPerRow
        let sourceBytes = [UInt8](providerData as Data)
        guard sourceBytes.count >= sourceStride * (height - 1) + width * 4 else { return nil }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        switch image.alphaInfo {
        case .last:
            guard image.bitsPerPixel == 32 else { return nil }
            for row in 0..<height {
                let source = row * sourceStride
                guard source + width * 4 <= sourceBytes.count else { return nil }
                out.replaceSubrange(row * width * 4 ..< (row + 1) * width * 4,
                                    with: sourceBytes[source ..< source + width * 4])
            }
        case .first:
            guard image.bitsPerPixel == 32 else { return nil }
            for row in 0..<height {
                let source = row * sourceStride
                guard source + width * 4 <= sourceBytes.count else { return nil }
                for column in 0..<width {
                    let s = source + column * 4
                    let d = (row * width + column) * 4
                    out[d] = sourceBytes[s + 1]
                    out[d + 1] = sourceBytes[s + 2]
                    out[d + 2] = sourceBytes[s + 3]
                    out[d + 3] = sourceBytes[s]
                }
            }
        case .none:
            guard image.bitsPerPixel == 3 * 8, sourceBytes.count >= sourceStride * (height - 1) + width * 3
            else { return nil }
            for row in 0..<height {
                let source = row * sourceStride
                for column in 0..<width {
                    let s = source + column * 3
                    let d = (row * width + column) * 4
                    out[d] = sourceBytes[s]
                    out[d + 1] = sourceBytes[s + 1]
                    out[d + 2] = sourceBytes[s + 2]
                    out[d + 3] = 255
                }
            }
        default:
            return nil
        }
        return out
    }

    /// Premultiplied sources carry no color under alpha 0: every alpha-0 pixel becomes
    /// `(0, 0, 0, 0)` regardless of what vImage left behind.
    private static func zeroTransparentPixels(_ pixels: inout [UInt8]) {
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] == 0 {
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
        }
    }
}
