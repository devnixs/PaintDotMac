import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PaintDotMac

/// Writes fixture files for integration tests into a private temporary directory. Tests call
/// `removeAll()` at their end — also on failure, via `defer` — and `deinit` removes the
/// directory as a safety net, so no binaries are ever committed.
final class FixtureFiles {
    enum Failure: Error {
        case imageCreationFailed
        case encodingFailed
    }

    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        removeAll()
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A solid-color sRGB PNG.
    func makePNG(named name: String, width: Int, height: Int,
                 rgba: (UInt8, UInt8, UInt8, UInt8)) throws -> URL {
        try writeSolidImage(named: name, width: width, height: height, rgba: rgba,
                            uti: UTType.png.identifier, jpegQuality: nil)
    }

    /// A solid-color opaque JPEG at quality 0.9.
    func makeJPEG(named name: String, width: Int, height: Int,
                  rgba: (UInt8, UInt8, UInt8, UInt8)) throws -> URL {
        try writeSolidImage(named: name, width: width, height: height, rgba: rgba,
                            uti: UTType.jpeg.identifier, jpegQuality: 0.9)
    }

    /// Raw bytes, for corrupt fixtures.
    func makeFile(named name: String, contents: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    // MARK: - Helpers

    private func writeSolidImage(named name: String, width: Int, height: Int,
                                 rgba: (UInt8, UInt8, UInt8, UInt8), uti: String,
                                 jpegQuality: Double?) throws -> URL {
        let image = try Self.solidImage(width: width, height: height, rgba: rgba)
        let url = directory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, uti as CFString, 1, nil
        ) else { throw Failure.encodingFailed }
        var properties: CFDictionary?
        if let jpegQuality {
            properties = [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        return url
    }

    /// A solid sRGB RGBA8 image used by the fixtures.
    static func solidImage(width: Int, height: Int,
                           rgba: (UInt8, UInt8, UInt8, UInt8)) throws -> CGImage {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              // The fill color must be built in sRGB: `CGColor(red:green:blue:alpha:)` lives in
              // a non-sRGB space and the color-matched fill would store shifted values.
              let color = CGColor(colorSpace: sRGB, components: [
                  CGFloat(rgba.0) / 255, CGFloat(rgba.1) / 255, CGFloat(rgba.2) / 255, CGFloat(rgba.3) / 255,
              ])
        else { throw Failure.imageCreationFailed }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw Failure.imageCreationFailed }
        return image
    }
}

// MARK: - Patterned fixtures (spec 0002)

extension FixtureFiles {
    /// A straight RGBA8 PNG whose pixels come from `pixel`.
    func writePNG(named name: String = "fixture.png", width: Int, height: Int,
                  pixel: @escaping (Int, Int) -> ColorRGBA8,
                  properties: [CFString: Any] = [:]) throws -> URL {
        try writeImage(named: name, width: width, height: height, pixel: pixel,
                       type: .png, properties: properties)
    }

    /// An RGBA8 JPEG whose pixels come from `pixel` (the format stores no alpha; quality
    /// 0.9 keeps colors close to the source).
    func writeJPEG(named name: String = "fixture.jpg", width: Int, height: Int,
                   pixel: @escaping (Int, Int) -> ColorRGBA8,
                   properties: [CFString: Any] = [:]) throws -> URL {
        var jpegProperties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        for (key, value) in properties { jpegProperties[key] = value }
        return try writeImage(named: name, width: width, height: height, pixel: pixel,
                              type: .jpeg, properties: jpegProperties)
    }

    /// A valid 64×64 pattern PNG cut to half its bytes (truncated container).
    func writeTruncatedPNG() throws -> URL {
        let data = TestImages.encode(
            TestImages.cgImage(width: 64, height: 64,
                               bytes: TestImages.rgbaBytes(width: 64, height: 64) { x, y in
                                   ColorRGBA8(red: UInt8(truncatingIfNeeded: x &* 3),
                                              green: UInt8(truncatingIfNeeded: y &* 5),
                                              blue: UInt8(truncatingIfNeeded: (x ^ y) &* 7),
                                              alpha: 255)
                               }),
            as: .png)
        return try makeFile(named: "truncated.png", contents: data.prefix(data.count / 2))
    }

    private func writeImage(named name: String, width: Int, height: Int,
                            pixel: @escaping (Int, Int) -> ColorRGBA8, type: UTType,
                            properties: [CFString: Any]) throws -> URL {
        let image = TestImages.cgImage(width: width, height: height,
                                       bytes: TestImages.rgbaBytes(width: width, height: height, pixel))
        return try makeFile(named: name, contents: TestImages.encode(image, as: type, properties: properties))
    }
}
