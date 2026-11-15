import AppKit
import CoreGraphics
import ImageIO
import Testing
@testable import PaintDotMac

@MainActor
@Suite(.serialized)
struct PaintDocumentTests {
    // MARK: - Fixtures (drawn and encoded here; nothing is committed)

    /// Draws a solid sRGB image and encodes it with `CGImageDestination`.
    private func encode(width: Int, height: Int, rgba: (UInt8, UInt8, UInt8, UInt8),
                        type: String) throws -> Data {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.encoding }
        // The fill color must be built in sRGB: `CGColor(red:green:blue:alpha:)` lives in a
        // non-sRGB space and the color-matched fill would store shifted values.
        let color = CGColor(colorSpace: sRGB, components: [
            CGFloat(rgba.0) / 255, CGFloat(rgba.1) / 255, CGFloat(rgba.2) / 255, CGFloat(rgba.3) / 255,
        ])
        context.setFillColor(try #require(color))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encoding }
        return output as Data
    }

    /// A deterministic gradient PNG: neighboring pixels differ, so the IDAT stream spans most
    /// of the file and truncation always cuts it.
    private func gradientPNGData(side: Int) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let index = (y * side + x) * 4
                pixels[index] = UInt8(truncatingIfNeeded: x &* 7 &+ y &* 13)
                pixels[index + 1] = UInt8(truncatingIfNeeded: x &* x &+ y &* 5)
                pixels[index + 2] = UInt8(truncatingIfNeeded: (x ^ y) &+ (x &* y))
                pixels[index + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encoding }
        return output as Data
    }

    private enum Failure: Error { case encoding }

    @discardableResult
    private func read(_ data: Data, as type: String) throws -> PaintDocument {
        let document = PaintDocument()
        try document.read(from: data, ofType: type)
        return document
    }

    /// A rejected read throws the exact `ImageCodecError` and leaves the image unchanged
    /// (still the 1×1 transparent image a fresh document holds).
    private func expectReadError(_ error: ImageCodecError, data: Data, type: String) throws {
        let document = PaintDocument()
        let imageBefore = document.image
        #expect(throws: error) {
            try document.read(from: data, ofType: type)
        }
        #expect(document.image == imageBefore, "a rejected read must leave the image unchanged")
    }

    // MARK: - Successful reads

    @Test func readsPNG() throws {
        let data = try encode(width: 64, height: 48, rgba: (10, 20, 30, 255), type: "public.png")
        let document = try read(data, as: "public.png")
        #expect(document.image.size == PixelSize(width: 64, height: 48))
    }

    @Test func readsJPEG() throws {
        let data = try encode(width: 40, height: 30, rgba: (200, 120, 40, 255), type: "public.jpeg")
        let document = try read(data, as: "public.jpeg")
        #expect(document.image.size == PixelSize(width: 40, height: 30))
    }

    @Test func readsOnePixel() throws {
        let data = try encode(width: 1, height: 1, rgba: (0, 0, 0, 255), type: "public.png")
        let document = try read(data, as: "public.png")
        #expect(document.image.size == PixelSize(width: 1, height: 1))
    }

    /// Content is decoded by sniffing, not by extension.
    @Test func readsJPEGDataDeclaredAsPNG() throws {
        let data = try encode(width: 40, height: 30, rgba: (200, 120, 40, 255), type: "public.jpeg")
        let document = try read(data, as: "public.png")
        #expect(document.image.size == PixelSize(width: 40, height: 30))
    }

    /// Proves the decoded image is the file's content, not just its size: the pixel round-trips
    /// exactly (PNG is lossless, so exact values are the correct expectation).
    @Test func pngPixelRoundTrip() throws {
        let data = try encode(width: 8, height: 8, rgba: (200, 100, 50, 255), type: "public.png")
        let document = try read(data, as: "public.png")
        let pixel = document.image.layers[0].surface.pixel(at: .zero)
        #expect(pixel == ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 255),
                "decoded pixel at (0, 0) is \(pixel)")
    }

    // MARK: - Rejections (never a crash)

    @Test func rejectsGarbage() throws {
        try expectReadError(.unrecognizedFormat, data: Data("not an image".utf8), type: "public.png")
    }

    @Test func rejectsTruncatedPNG() throws {
        let data = try gradientPNGData(side: 256)
        try expectReadError(.corrupt, data: data.prefix(data.count / 2), type: "public.png")
    }

    @Test func rejectsTruncatedJPEG() throws {
        let data = try encode(width: 256, height: 256, rgba: (90, 140, 190, 255), type: "public.jpeg")
        try expectReadError(.corrupt, data: data.prefix(data.count / 2), type: "public.jpeg")
    }

    @Test func rejectsEmptyData() throws {
        try expectReadError(.unrecognizedFormat, data: Data(), type: "public.png")
    }

    /// SOI + EOI with nothing between: no image frames.
    @Test func rejectsJPEGWithNoFrames() throws {
        try expectReadError(.unrecognizedFormat,
                            data: Data([0xFF, 0xD8, 0xFF, 0xD9]), type: "public.jpeg")
    }

    @Test func rejectsUnsupportedType() throws {
        let data = try encode(width: 8, height: 8, rgba: (1, 2, 3, 255), type: "public.png")
        let document = PaintDocument()
        #expect(throws: CocoaError.self) {
            do {
                try document.read(from: data, ofType: "com.compuserve.gif")
            } catch let error as CocoaError {
                #expect(error.code == .fileReadUnknown)
                throw error
            }
        }
        #expect(document.image.size == PixelSize(width: 1, height: 1),
                "a rejected read must leave the image unchanged")
    }

    // MARK: - Document configuration

    @Test func doesNotAutosaveInPlace() {
        #expect(PaintDocument.autosavesInPlace == false)
    }

    @Test func readableTypes() {
        #expect(PaintDocument.readableTypes == ["public.png", "public.jpeg"])
    }

    // `saveActionsAreDisabled` and `writingThrows` were 0001's; 0005 enabled saving and
    // writing — the replacements live in `PaintDocumentSavingTests`
    // (`saveActionsAreEnabled`, `dataOfTypePNGRoundTrips`, `dataOfTypeJPEGThrows`).

    @Test func makeWindowControllersCreatesOneDocumentWindow() throws {
        let data = try encode(width: 64, height: 48, rgba: (10, 20, 30, 255), type: "public.png")
        let document = try read(data, as: "public.png")
        document.makeWindowControllers()

        #expect(document.windowControllers.count == 1)
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        let window = try #require(controller.window)
        #expect(window.identifier == NSUserInterfaceItemIdentifier("documentWindow"))
        #expect(controller.canvasView != nil)
        window.close()
    }

    /// A document that hasn't read a file holds the 1×1 transparent placeholder image and can
    /// still build its window (until 0005 adds New Image).
    @Test func unreadDocumentHoldsBlankOnePixelImage() {
        let document = PaintDocument()
        #expect(document.image.size == PixelSize(width: 1, height: 1))
        #expect(document.image.layers.count == 1)
        #expect(document.image.layers[0].name == "Background")
        #expect(document.image.layers[0].surface.pixel(at: .zero) == .clear)
        document.makeWindowControllers()
        #expect(document.windowControllers.count == 1)
        (document.windowControllers.first?.window)?.close()
    }
}
