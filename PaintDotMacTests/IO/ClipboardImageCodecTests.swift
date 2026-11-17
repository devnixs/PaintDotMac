import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PaintDotMac

/// `ClipboardImageCodec` — the E-5 read order, the PNG/TIFF write side, FMT-B conversion,
/// limits, and the cheap `canPaste` decision (spec 0021 *Test plan*, unit).
struct ClipboardImageCodecTests {
    /// The 3×2 reference surface: opaque, semi-transparent, near-invisible alpha, zero
    /// alpha with a real color, white, and fully clear.
    private var referenceSurface: TiledSurface {
        TestImages.surface(width: 3, height: 2) { x, y in
            switch (x, y) {
            case (0, 0): ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
            case (1, 0): ColorRGBA8(red: 0, green: 255, blue: 0, alpha: 128)
            case (2, 0): ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 1)
            case (0, 1): ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 0)
            case (1, 1): ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255)
            default: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0)
            }
        }
    }

    private func profileName(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return properties[kCGImagePropertyProfileName] as? String
    }

    @Test func encodeWritesLosslessPNG() throws {
        let (png, _) = try ClipboardImageCodec.encode(referenceSurface, dpi: 72)
        let decoded = try ImageDecoder.decode(png, limits: .standard)
        #expect(decoded.surface.size == PixelSize(width: 3, height: 2))
        TestImages.expectPixels(decoded.surface, match: { x, y in
            self.referenceSurface.pixel(at: PixelPoint(x: x, y: y))
        }, "PNG keeps every byte, alpha 0 colors included")
        #expect(profileName(of: png)?.contains("sRGB") == true,
                "the clipboard PNG carries the sRGB profile (FMT-B)")
    }

    @Test func encodeTIFFRoundTrip() throws {
        let (_, tiff) = try ClipboardImageCodec.encode(referenceSurface, dpi: 72)
        let source = try #require(CGImageSourceCreateWithData(tiff as CFData, nil))
        #expect(CGImageSourceGetType(source) == UTType.tiff.identifier as CFString)
        let decoded = try ImageDecoder.decode(tiff, limits: .standard)
        #expect(decoded.surface.size == PixelSize(width: 3, height: 2))
        // TIFF may premultiply internally (ImageIO's choice): exact for opaque pixels,
        // within ±1 per channel after un-premultiplying for alpha ≥ 128.
        TestImages.expectColor(decoded.surface.pixel(at: .zero),
                               ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255),
                               "opaque exact")
        TestImages.expectColor(decoded.surface.pixel(at: PixelPoint(x: 1, y: 1)),
                               ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255),
                               "opaque exact")
        TestImages.expectColor(decoded.surface.pixel(at: PixelPoint(x: 1, y: 0)),
                               ColorRGBA8(red: 0, green: 255, blue: 0, alpha: 128),
                               tolerance: 1, "alpha 128 within ±1")
    }

    // MARK: - Read order (E-5)

    private func png(width: Int, height: Int, _ color: ColorRGBA8) -> Data {
        TestImages.encode(TestImages.cgImage(width: width, height: height,
                                             bytes: TestImages.rgbaBytes(width: width, height: height) { _, _ in color }),
                          as: .png)
    }

    private func tiff(width: Int, height: Int, _ color: ColorRGBA8) -> Data {
        TestImages.encode(TestImages.cgImage(width: width, height: height,
                                             bytes: TestImages.rgbaBytes(width: width, height: height) { _, _ in color }),
                          as: .tiff)
    }

    private static let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
    private static let blue = ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255)

    @Test func readOrderPrefersPNG() throws {
        let contents = ClipboardContents(pngData: png(width: 2, height: 2, Self.red),
                                         tiffData: tiff(width: 3, height: 3, Self.blue))
        let image = try ClipboardImageCodec.read(contents, limits: .standard,
                                                          readFile: { _ -> Data in Issue.record("no file read expected"); throw CocoaError(.fileReadUnknown) }).get()
        #expect(image.size == PixelSize(width: 2, height: 2))
        #expect(image.surface.pixel(at: .zero) == Self.red)
    }

    @Test func readOrderFallsBackToTIFF() throws {
        let contents = ClipboardContents(pngData: Data("junk".utf8),
                                         tiffData: tiff(width: 3, height: 3, Self.blue))
        let image = try ClipboardImageCodec.read(contents, limits: .standard,
                                                          readFile: { _ -> Data in throw CocoaError(.fileReadUnknown) }).get()
        #expect(image.size == PixelSize(width: 3, height: 3))
        #expect(image.surface.pixel(at: .zero) == Self.blue)
    }

    @Test func readOrderFallsBackToFileURL() throws {
        let fixtures = try FixtureFiles()
        defer { fixtures.removeAll() }
        let text = try fixtures.makeFile(named: "note.txt", contents: Data("not an image".utf8))
        let imageFile = try fixtures.writePNG(named: "pic.png", width: 2, height: 1) { _, _ in Self.blue }
        var readURLs: [URL] = []
        let contents = ClipboardContents(fileURLs: [text, imageFile])
        let image = try ClipboardImageCodec.read(contents, limits: .standard, readFile: { url in
            readURLs.append(url)
            return try Data(contentsOf: url)
        }).get()
        #expect(image.size == PixelSize(width: 2, height: 1))
        #expect(readURLs == [text, imageFile], "candidates are read in pasteboard order")
    }

    @Test func readStopsAtFirstSuccess() throws {
        let first = try TestImages.temporaryFile(named: "first.png", contents: png(width: 4, height: 4, Self.red))
        let second = try TestImages.temporaryFile(named: "second.png", contents: png(width: 8, height: 8, Self.blue))
        var readURLs: [URL] = []
        let contents = ClipboardContents(fileURLs: [first, second])
        let image = try ClipboardImageCodec.read(contents, limits: .standard, readFile: { url in
            readURLs.append(url)
            return try Data(contentsOf: url)
        }).get()
        #expect(image.size == PixelSize(width: 4, height: 4))
        #expect(readURLs == [first], "the second URL is never read")
    }

    @Test func skipsCorruptPNG() throws {
        let full = png(width: 64, height: 64, Self.red)
        let truncated = full.prefix(full.count / 2)
        let contents = ClipboardContents(pngData: Data(truncated),
                                         tiffData: tiff(width: 3, height: 3, Self.blue))
        let image = try ClipboardImageCodec.read(contents, limits: .standard,
                                                          readFile: { _ -> Data in throw CocoaError(.fileReadUnknown) }).get()
        #expect(image.size == PixelSize(width: 3, height: 3))
    }

    @Test func noImage() {
        func expectNoImage(_ contents: ClipboardContents,
                           readFile: (URL) throws -> Data = { _ in throw CocoaError(.fileReadUnknown) }) {
            #expect(ClipboardImageCodec.read(contents, limits: .standard, readFile: readFile)
                    == .failure(.noImage))
        }
        expectNoImage(ClipboardContents())
        expectNoImage(ClipboardContents(pngData: Data(), tiffData: Data()))  // empty = unrecognized
        expectNoImage(ClipboardContents(fileURLs: [URL(fileURLWithPath: "/tmp/note.txt")]))
        // A text file that exists but never decodes.
        let data = Data("plain text".utf8)
        expectNoImage(ClipboardContents(fileURLs: [URL(fileURLWithPath: "/tmp/note.txt")]),
                      readFile: { _ in data })
    }

    @Test func readFileThrowingIsSkipped() {
        let contents = ClipboardContents(fileURLs: [URL(fileURLWithPath: "/gone/gone.png")])
        #expect(ClipboardImageCodec.read(contents, limits: .standard,
                                         readFile: { _ throws -> Data in throw CocoaError(.fileReadNoSuchFile) })
                == .failure(.noImage))
    }

    @Test func limitExceededReported() throws {
        // Dimensions are validated from the header before any allocation (0002).
        let huge = TestImages.pngHeaderOnly(width: 70_000, height: 10)
        #expect(ClipboardImageCodec.read(ClipboardContents(pngData: huge), limits: .standard,
                                         readFile: { _ -> Data in throw CocoaError(.fileReadUnknown) })
                == .failure(.limitExceeded(.dimensionsOutOfRange(width: 70_000, height: 10))))

        let small = png(width: 10, height: 10, Self.red)
        #expect(ClipboardImageCodec.read(ClipboardContents(pngData: small),
                                         limits: ImageLimits(memoryCapBytes: 100),
                                         readFile: { _ -> Data in throw CocoaError(.fileReadUnknown) })
                == .failure(.limitExceeded(.exceedsMemoryCap(requiredBytes: 400, capBytes: 100))))

        // A valid later candidate still wins over a remembered limit error.
        let contents = ClipboardContents(pngData: huge, tiffData: tiff(width: 3, height: 3, Self.blue))
        let image = try ClipboardImageCodec.read(contents, limits: .standard,
                                                          readFile: { _ -> Data in throw CocoaError(.fileReadUnknown) }).get()
        #expect(image.size == PixelSize(width: 3, height: 3))
    }

    // MARK: - FMT-B conversion through the read side

    @Test func displayP3ConvertedToSRGB() throws {
        let displayP3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let data = TestImages.encode(
            TestImages.cgImage(width: 1, height: 1, bytes: [255, 0, 0, 255], colorSpace: displayP3),
            as: .png)
        let viaCodec = try ClipboardImageCodec.read(ClipboardContents(pngData: data),
                                                             limits: .standard,
                                                             readFile: { _ -> Data in throw CocoaError(.fileReadUnknown) }).get()
        // Same pipeline as 0002's decoder (identity), and P3 red clips out of sRGB.
        let viaDecoder = try ImageDecoder.decode(data, limits: .standard).surface
        #expect(viaCodec.surface == viaDecoder)
        let pixel = viaCodec.surface.pixel(at: .zero)
        #expect(pixel.red > 250 && pixel.green == 0, "got \(pixel)")
    }

    @Test func sixteenBitReduced() throws {
        var bytes = [UInt8]()
        for value: UInt16 in [0xFFFF, 0x8080, 0x0000, 0xFFFF] {
            bytes.append(UInt8(value >> 8)); bytes.append(UInt8(value & 0xFF))
        }
        let data = TestImages.encode(
            TestImages.cgImage(width: 1, height: 1, bitsPerComponent: 16, bytes: bytes), as: .png)
        let image = try ClipboardImageCodec.read(ClipboardContents(pngData: data),
                                                          limits: .standard,
                                                          readFile: { _ -> Data in throw CocoaError(.fileReadUnknown) }).get()
        TestImages.expectColor(image.surface.pixel(at: .zero),
                               ColorRGBA8(red: 255, green: 128, blue: 0, alpha: 255), tolerance: 1)
    }

    @Test func grayExpanded() throws {
        let gray = try #require(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let data = TestImages.encode(
            TestImages.cgImage(width: 1, height: 1, bytes: [77], colorSpace: gray, alphaInfo: .none),
            as: .png)
        let image = try ClipboardImageCodec.read(ClipboardContents(pngData: data),
                                                          limits: .standard,
                                                          readFile: { _ -> Data in throw CocoaError(.fileReadUnknown) }).get()
        TestImages.expectColor(image.surface.pixel(at: .zero),
                               ColorRGBA8(red: 77, green: 77, blue: 77, alpha: 255), tolerance: 1)
    }

    @Test func orientationApplied() throws {
        // 2×1 with orientation 6 (rotate 90° CW): the result stands 1×2 (0002's pipeline).
        let data = TestImages.encode(
            TestImages.cgImage(width: 2, height: 1, bytes: [255, 0, 0, 255, 0, 0, 255, 255]),
            as: .png, properties: [kCGImagePropertyOrientation: 6])
        let image = try ClipboardImageCodec.read(ClipboardContents(pngData: data),
                                                          limits: .standard,
                                                          readFile: { _ -> Data in throw CocoaError(.fileReadUnknown) }).get()
        #expect(image.size == PixelSize(width: 1, height: 2))
    }

    // MARK: - canPaste

    @Test func canPaste() {
        func can(_ types: [String], _ fileTypes: [UTType] = []) -> Bool {
            ClipboardImageCodec.canPaste(types: types, fileURLTypes: fileTypes)
        }
        #expect(can(["public.png"]) == true)
        #expect(can(["public.tiff"]) == true)
        #expect(can(["public.utf8-plain-text"]) == false)
        #expect(can([]) == false)
        #expect(can([], [.png]) == true)
        #expect(can([], [.plainText]) == false)
        #expect(can([], [.plainText, .jpeg]) == true)
    }
}
