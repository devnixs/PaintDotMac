import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PaintDotMac

/// PNG write tests against the PNG specification (pHYs unit 1 = metre, ppm = round(dpi /
/// 0.0254)), the FMT-B straight-alpha/sRGB rules, and hand-built pixel patterns. Decoding
/// uses 0002's `ImageDecoder`, which is byte-exact for straight sRGB PNG sources; chunk
/// inspection uses the independent walker in `PNGChunks.swift`.
struct ImageEncoderTests {
    private func roundTrip(_ surface: TiledSurface, dpi: Double = 96) throws -> DecodedImage {
        let data = try ImageEncoder.encode(surface, size: surface.size, dpi: dpi, as: .png)
        return try ImageDecoder.decode(data)
    }

    @Test func pngSignature() throws {
        let surface = TestImages.surface(width: 2, height: 2) { _, _ in .white }
        let data = try ImageEncoder.encode(surface, size: surface.size, dpi: 96, as: .png)
        #expect([UInt8](data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// 300×200 crosses the 256-pixel tile boundary in both axes; the formula is evaluated
    /// independently on the decoded surface, never through the encoder.
    @Test func pngRoundTripIsByteExact() throws {
        let expected: (Int, Int) -> ColorRGBA8 = { x, y in
            ColorRGBA8(red: UInt8(x % 256),
                       green: UInt8(y % 256),
                       blue: UInt8((x &+ y) % 256),
                       alpha: UInt8((x &* 7 &+ y) % 256))
        }
        let surface = TestImages.surface(width: 300, height: 200, expected)
        let decoded = try roundTrip(surface)
        #expect(decoded.surface.size == PixelSize(width: 300, height: 200))
        TestImages.expectPixels(decoded.surface, match: expected)
    }

    /// Pixel (x, y) = (y, 255 − y, (x × 3) mod 256, x): every alpha 0…255 occurs (one full
    /// column per value) with many colors, including alpha 0 with non-zero RGB (column 0 is
    /// (y, 255−y, 0, 0)).
    @Test func allAlphaValuesRoundTrip() throws {
        let expected: (Int, Int) -> ColorRGBA8 = { x, y in
            ColorRGBA8(red: UInt8(y),
                       green: UInt8(255 &- y),
                       blue: UInt8((x &* 3) % 256),
                       alpha: UInt8(x))
        }
        let decoded = try roundTrip(TestImages.surface(width: 256, height: 256, expected))
        TestImages.expectPixels(decoded.surface, match: expected)
    }

    /// A 1/255-alpha pixel survives untouched — a premultiplying writer would return
    /// (200, 100, 50) → ~(255, 128, 64) here.
    @Test func straightAlphaNotPremultiplied() throws {
        let decoded = try roundTrip(TestImages.surface(width: 1, height: 1) { _, _ in
            ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 1)
        })
        #expect(decoded.surface.pixel(at: .zero) == ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 1))
    }

    /// An untouched sparse surface encodes as (0, 0, 0, 0) everywhere — absent tiles are
    /// transparent, not black-opaque.
    @Test func sparseSurfaceEncodesTransparent() throws {
        let surface = TiledSurface(size: PixelSize(width: 300, height: 300))
        let decoded = try roundTrip(surface)
        TestImages.expectPixels(decoded.surface, match: { _, _ in .clear })
    }

    @Test func onePixel() throws {
        let decoded = try roundTrip(TestImages.surface(width: 1, height: 1) { _, _ in
            ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        })
        #expect(decoded.surface.pixel(at: .zero) == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))
    }

    // MARK: - Color profile and DPI metadata

    /// FMT-B: saving always embeds an sRGB profile.
    @Test func embedsSRGBProfile() throws {
        let data = try ImageEncoder.encode(
            TestImages.surface(width: 8, height: 8) { _, _ in .white },
            size: PixelSize(width: 8, height: 8), dpi: 96, as: .png)
        let chunkTypes = Set((PNGChunks.read(data) ?? []).map(\.type))
        #expect(chunkTypes.contains("iCCP") || chunkTypes.contains("sRGB"),
                "PNG carries no color-profile chunk: \(chunkTypes.sorted())")
        let profileName = try #require(FixtureFiles.profileName(of: data))
        #expect(profileName.contains("sRGB"), "profile name is \(profileName)")
    }

    /// PNG's pHYs (unit byte 1 = metre) per the PNG specification: ppm = round(dpi / 0.0254)
    /// — 96 → 3780, 72 → 2835, 300 → 11811, 72.5 → 2854 — each ±1 ppm (ImageIO may round
    /// differently), and decoding lands within 0.05 DPI (APP-5).
    @Test(arguments: [(96.0, 3780), (72.0, 2835), (300.0, 11_811), (72.5, 2854)])
    func writesPHYsForDPI(_ pair: (Double, Int)) throws {
        let data = try ImageEncoder.encode(
            TestImages.surface(width: 4, height: 4) { _, _ in .white },
            size: PixelSize(width: 4, height: 4), dpi: pair.0, as: .png)
        let phys = try #require(PNGChunks.chunks(in: data, named: "pHYs").first)
        #expect(phys.data.count == 9)
        func be32(_ at: Int) -> Int {
            Int(UInt32(phys.data[phys.data.startIndex + at]) << 24
                | UInt32(phys.data[phys.data.startIndex + at + 1]) << 16
                | UInt32(phys.data[phys.data.startIndex + at + 2]) << 8
                | UInt32(phys.data[phys.data.startIndex + at + 3]))
        }
        #expect(abs(be32(0) - pair.1) <= 1, "pHYs X for \(pair.0) DPI")
        #expect(abs(be32(4) - pair.1) <= 1, "pHYs Y for \(pair.0) DPI")
        #expect(phys.data[phys.data.startIndex + 8] == 1, "pHYs unit must be metre")
        let decoded = try ImageDecoder.decode(data)
        #expect(abs(decoded.dpi - pair.0) <= 0.05, "decoded DPI for \(pair.0)")
    }

    // MARK: - Refusals

    @Test func unsupportedWriteFormat() throws {
        let surface = TestImages.surface(width: 2, height: 2) { _, _ in .white }
        #expect(throws: ImageCodecError.unsupportedWriteFormat(.jpeg)) {
            try ImageEncoder.encode(surface, size: surface.size, dpi: 96, as: .jpeg)
        }
        var image = LayeredImage(surface: surface, dpi: 96)
        #expect(throws: ImageCodecError.unsupportedWriteFormat(.jpeg)) {
            try ImageEncoder.encode(image, as: .jpeg)
        }
        // Even a multi-layer document reports the unsupported format before the layer count.
        image.layers.append(Layer(name: "Layer 2", surface: surface))
        #expect(throws: ImageCodecError.unsupportedWriteFormat(.jpeg)) {
            try ImageEncoder.encode(image, as: .jpeg)
        }
    }

    /// Interim rule 5: any layer count other than 1 is refused (a document always has one
    /// layer until 0024; a hand-built violation must alert, not crash).
    @Test func multiLayerRefused() throws {
        let surface = TestImages.surface(width: 2, height: 2) { _, _ in .white }
        var image = LayeredImage(surface: surface, dpi: 96)
        image.layers.append(Layer(name: "Layer 2", surface: surface))
        #expect(throws: ImageCodecError.encodingFailed) {
            try ImageEncoder.encode(image, as: .png)
        }
        image.layers = []
        #expect(throws: ImageCodecError.encodingFailed) {
            try ImageEncoder.encode(image, as: .png)
        }
    }
}
