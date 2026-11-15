import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PaintDotMac

/// Synthetic fixtures and pixel assertions (CoreGraphics/ImageIO only; no binary fixture
/// files are committed).
enum TestImages {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Tightly packed straight RGBA8 bytes for `pixel(x, y)`.
    static func rgbaBytes(width: Int, height: Int, _ pixel: (Int, Int) -> ColorRGBA8) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = pixel(x, y)
                bytes.append(contentsOf: [color.red, color.green, color.blue, color.alpha])
            }
        }
        return bytes
    }

    static func surface(width: Int, height: Int, _ pixel: (Int, Int) -> ColorRGBA8) -> TiledSurface {
        let bytes = rgbaBytes(width: width, height: height, pixel)
        return bytes.withUnsafeBytes { buffer in
            TiledSurface(size: PixelSize(width: width, height: height), rgba8: buffer, bytesPerRow: width * 4)
        }
    }

    /// A `CGImage` over `bytes` (tightly packed). Component count comes from the color space
    /// plus alpha; float formats pass `.floatComponents` in `byteOrder`.
    static func cgImage(width: Int, height: Int, bitsPerComponent: Int = 8, bytes: [UInt8],
                        colorSpace: CGColorSpace = sRGB,
                        alphaInfo: CGImageAlphaInfo = .last,
                        byteOrder: CGBitmapInfo = []) -> CGImage {
        let hasAlpha = alphaInfo != .none && alphaInfo != .noneSkipLast && alphaInfo != .noneSkipFirst
        let components = colorSpace.numberOfComponents + (hasAlpha ? 1 : 0)
        let bitsPerPixel = bitsPerComponent * components
        let bytesPerRow = (width * bitsPerPixel + 7) / 8
        let bitmapInfo = CGBitmapInfo(rawValue: alphaInfo.rawValue).union(byteOrder)
        let expected = bytesPerRow * height
        precondition(bytes.count >= expected,
                     "cgImage buffer has \(bytes.count) bytes, needs \(expected) for \(width)×\(height) at \(bitsPerPixel) bpp")
        let provider = CGDataProvider(data: Data(bytes) as CFData)
        precondition(provider != nil, "could not build a data provider")
        let image = CGImage(
            width: width, height: height,
            bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo,
            provider: provider!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )
        precondition(image != nil, "could not build a CGImage (\(width)×\(height), \(bitsPerPixel) bpp)")
        return image!
    }

    static func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        precondition(destination != nil, "no image destination for \(type.identifier)")
        CGImageDestinationAddImage(destination!, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination!), "encoding as \(type.identifier) failed")
        return output as Data
    }

    static func encodeFrames(_ frames: [CGImage], as type: UTType) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, frames.count, nil)
        precondition(destination != nil, "no image destination for \(type.identifier)")
        for frame in frames { CGImageDestinationAddImage(destination!, frame, nil) }
        precondition(CGImageDestinationFinalize(destination!), "encoding \(frames.count) frames as \(type.identifier) failed")
        return output as Data
    }

    /// The PNG signature, an IHDR chunk (8-bit RGBA) and an IEND chunk, with correct CRCs.
    /// Tests huge limits without allocating huge images.
    static func pngHeaderOnly(width: UInt32, height: UInt32) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = [UInt8]()
        for value in [width, height] {
            header.append(contentsOf: value.bigEndianBytes)
        }
        header.append(contentsOf: [8, 6, 0, 0, 0])  // bit depth 8, color type 6 (RGBA)
        appendPNGChunk(&data, type: "IHDR", payload: header)
        appendPNGChunk(&data, type: "IEND", payload: [])
        return data
    }

    private static func appendPNGChunk(_ data: inout Data, type: String, payload: [UInt8]) {
        let length = UInt32(payload.count).bigEndianBytes
        data.append(contentsOf: length)
        let typeBytes = Array(type.utf8)
        data.append(contentsOf: typeBytes)
        data.append(contentsOf: payload)
        let crc = crc32(typeBytes + payload).bigEndianBytes
        data.append(contentsOf: crc)
    }

    /// CRC-32 (IEEE, reflected polynomial 0xEDB88320).
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var table: [UInt32] = []
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
            }
            table.append(value)
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Checks every pixel in `bounds`; records one issue listing the mismatch count and the
    /// first 10 mismatches as `(x, y): got … expected …`.
    static func expectPixels(_ surface: TiledSurface, match expected: (Int, Int) -> ColorRGBA8,
                             tolerance: Int = 0, _ comment: Comment? = nil,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        var mismatchCount = 0
        var samples: [String] = []
        for y in 0..<surface.size.height {
            for x in 0..<surface.size.width {
                let got = surface.pixel(at: PixelPoint(x: x, y: y))
                let want = expected(x, y)
                if !withinTolerance(got, want, tolerance) {
                    mismatchCount += 1
                    if samples.count < 10 {
                        samples.append("(\(x), \(y)): got \(got) expected \(want)")
                    }
                }
            }
        }
        guard mismatchCount > 0 else { return }
        let head = samples.joined(separator: "; ")
        Issue.record("\(mismatchCount) pixel mismatches, first \(min(10, mismatchCount)): \(head)\(suffix(for: comment))",
                     sourceLocation: sourceLocation)
    }

    static func expectColor(_ actual: ColorRGBA8, _ expected: ColorRGBA8, tolerance: Int = 0,
                            _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(withinTolerance(actual, expected, tolerance),
                "got \(actual), expected \(expected) ±\(tolerance)\(suffix(for: comment))",
                sourceLocation: sourceLocation)
    }

    private static func suffix(for comment: Comment?) -> String {
        guard let comment else { return "" }
        return " — \(comment)"
    }

    private static func withinTolerance(_ actual: ColorRGBA8, _ expected: ColorRGBA8, _ tolerance: Int) -> Bool {
        abs(Int(actual.red) - Int(expected.red)) <= tolerance
            && abs(Int(actual.green) - Int(expected.green)) <= tolerance
            && abs(Int(actual.blue) - Int(expected.blue)) <= tolerance
            && abs(Int(actual.alpha) - Int(expected.alpha)) <= tolerance
    }

    /// A fresh directory under the system temporary directory.
    static func temporaryFile(named name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8(truncatingIfNeeded: self >> 24), UInt8(truncatingIfNeeded: self >> 16),
         UInt8(truncatingIfNeeded: self >> 8), UInt8(truncatingIfNeeded: self)]
    }
}
