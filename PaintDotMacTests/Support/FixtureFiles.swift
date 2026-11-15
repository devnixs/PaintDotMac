import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

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
