import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes the document model into flat image formats (spec 0005, F-2; PRD §5.11 FMT-B).
/// Stateless and `Sendable`-friendly, like `ImageDecoder`. PNG is the only writable format
/// until 0028 (`.ora`) and 0029 (JPEG, HEIC, TIFF, BMP, GIF).
enum ImageEncoder {
    /// Encodes straight 8-bit sRGB RGBA pixels. Throws `.unsupportedWriteFormat` when the
    /// format can't be written yet; never premultiplies, never drops the color of fully
    /// transparent pixels, never converts to another color space (NF-9, FMT-B, D-33).
    static func encode(_ surface: TiledSurface, size: PixelSize, dpi: Double,
                       as format: FileFormat) throws(ImageCodecError) -> Data {
        guard format.canWrite else { throw .unsupportedWriteFormat(format) }
        switch format {
        case .png:
            return try encodePNG(surface: surface, size: size, dpi: dpi)
        case .jpeg:
            // Unreachable while `.jpeg.canWrite == false`; 0029 replaces it with the JPEG
            // writer. Kept explicit so a future `canWrite` flip must handle it on purpose.
            throw .unsupportedWriteFormat(format)
        }
    }

    /// Document-level entry point (interim rule 5): a document always has exactly one layer
    /// until 0024, and the PNG writer encodes that layer's surface. Any other layer count is
    /// refused with `.encodingFailed` — an alert, never a crash. 0029's `SavePlan` replaces
    /// this with flatten-on-export through `CPUCompositor`.
    static func encode(_ image: LayeredImage, as format: FileFormat) throws(ImageCodecError) -> Data {
        guard format.canWrite else { throw .unsupportedWriteFormat(format) }
        guard image.layers.count == 1 else { throw .encodingFailed }
        return try encode(image.layers[0].surface, size: image.size, dpi: image.dpi, as: format)
    }

    // MARK: - PNG

    private static func encodePNG(surface: TiledSurface, size: PixelSize, dpi: Double) throws(ImageCodecError) -> Data {
        // A size mismatch is a caller bug; refuse instead of reading out of bounds or
        // writing a file whose pixels contradict its header.
        guard surface.size == size else { throw .encodingFailed }
        guard LayeredImage.isValidDPI(dpi) else { throw .encodingFailed }
        // PNG's pHYs unit 1 = metre (the PNG specification): ppm = round(dpi / 0.0254),
        // 96 DPI → 3780, 72 → 2835, 300 → 11811. pHYs fields are UInt32.
        let pixelsPerMeter = (dpi / 0.0254).rounded()
        guard pixelsPerMeter >= 1, pixelsPerMeter <= Double(UInt32.max) else { throw .encodingFailed }
        let ppm = Int(pixelsPerMeter)

        // One contiguous straight-RGBA8 buffer; absent sparse tiles read as (0, 0, 0, 0).
        // Sizes are `Int` and `ImageLimits` has accepted the size before it became a surface.
        let bytes = surface.readPixels(in: surface.bounds)
        let bytesPerPixel = PixelFormat.rgba8.bytesPerPixel
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let colorSpace = CGColorSpace(name: PixelFormat.rgba8.colorSpaceName)
        else { throw .encodingFailed }
        // A CGImage straight over the buffer — no CGContext, which would premultiply and
        // lose straight-alpha precision (NF-9). The sRGB color space makes ImageIO embed
        // the sRGB profile (FMT-B "Saving always embeds an sRGB profile").
        guard let image = CGImage(
            width: size.width, height: size.height,
            bitsPerComponent: 8, bitsPerPixel: 8 * bytesPerPixel,
            bytesPerRow: size.width * bytesPerPixel,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ) else { throw .encodingFailed }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { throw .encodingFailed }
        let properties: [CFString: Any] = [
            // APP-5: the document's DPI travels with the file, in both encodings.
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGXPixelsPerMeter: ppm,
                kCGImagePropertyPNGYPixelsPerMeter: ppm,
            ] as CFDictionary,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw .encodingFailed }
        return output as Data
    }
}
