import AppKit
import Foundation
import ImageIO
import Testing

@testable import PaintDotMac

/// `PaintDocument.read(from:ofType:)` fills the 0002 `LayeredImage` (spec 0002 *Test plan*).
@MainActor
@Suite(.serialized)
struct PaintDocumentLoadingTests {
    @Test func readsPNGIntoLayeredImage() throws {
        let data = TestImages.encode(
            TestImages.cgImage(width: 300, height: 200,
                               bytes: TestImages.rgbaBytes(width: 300, height: 200) { x, y in
                                   ColorRGBA8(red: UInt8(truncatingIfNeeded: x &* 2),
                                              green: UInt8(truncatingIfNeeded: y &* 3),
                                              blue: UInt8(truncatingIfNeeded: (x ^ y) &* 5),
                                              alpha: 255)
                               }),
            as: .png,
            properties: [kCGImagePropertyDPIWidth: 150.0, kCGImagePropertyDPIHeight: 150.0])
        let document = PaintDocument()
        try document.read(from: data, ofType: "public.png")
        let image = document.image
        #expect(image.size == PixelSize(width: 300, height: 200))
        #expect(image.layers.count == 1)
        #expect(image.layers[0].name == "Background")
        #expect(abs(image.dpi - 150) <= 0.01, "dpi is \(image.dpi)")
        TestImages.expectPixels(image.layers[0].surface) { x, y in
            ColorRGBA8(red: UInt8(truncatingIfNeeded: x &* 2),
                       green: UInt8(truncatingIfNeeded: y &* 3),
                       blue: UInt8(truncatingIfNeeded: (x ^ y) &* 5),
                       alpha: 255)
        }
    }

    @Test func readsJPEGIntoLayeredImage() throws {
        func quadrant(_ x: Int, _ y: Int) -> ColorRGBA8 {
            switch (x < 32, y < 32) {
            case (true, true): ColorRGBA8(red: 255, green: 0, blue: 0)
            case (false, true): ColorRGBA8(red: 0, green: 255, blue: 0)
            case (true, false): ColorRGBA8(red: 0, green: 0, blue: 255)
            case (false, false): ColorRGBA8(red: 255, green: 255, blue: 255)
            }
        }
        let data = TestImages.encode(
            TestImages.cgImage(width: 64, height: 64,
                               bytes: TestImages.rgbaBytes(width: 64, height: 64, quadrant)),
            as: .jpeg,
            properties: [kCGImageDestinationLossyCompressionQuality: 0.95,
                         kCGImagePropertyDPIWidth: 72.0, kCGImagePropertyDPIHeight: 72.0])
        let document = PaintDocument()
        try document.read(from: data, ofType: "public.jpeg")
        #expect(document.image.size == PixelSize(width: 64, height: 64))
        #expect(document.image.layers.count == 1)
        #expect(document.image.dpi == 72)
        let surface = document.image.layers[0].surface
        for y in 0..<64 {
            for x in 0..<64 {
                #expect(surface.pixel(at: PixelPoint(x: x, y: y)).alpha == 255)
            }
        }
        for center in [(16, 16), (48, 16), (16, 48), (48, 48)] {
            TestImages.expectColor(surface.pixel(at: PixelPoint(x: center.0, y: center.1)),
                                   quadrant(center.0, center.1), tolerance: 8)
        }
    }

    /// Content is sniffed, not taken from the declared type.
    @Test func jpegBytesWithPNGTypeOpen() throws {
        let data = TestImages.encode(
            TestImages.cgImage(width: 8, height: 8,
                               bytes: [UInt8](repeating: 0x80, count: 8 * 8 * 4)),
            as: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.95])
        let document = PaintDocument()
        try document.read(from: data, ofType: "public.png")
        #expect(document.image.size == PixelSize(width: 8, height: 8))
    }

    @Test func corruptDataThrowsCodecError() throws {
        let full = TestImages.encode(
            TestImages.cgImage(width: 64, height: 64,
                               bytes: TestImages.rgbaBytes(width: 64, height: 64) { x, y in
                                   ColorRGBA8(red: UInt8(truncatingIfNeeded: x &* 5),
                                              green: UInt8(truncatingIfNeeded: y &* 9),
                                              blue: 33, alpha: 255)
                               }),
            as: .png)
        let document = PaintDocument()
        let imageBefore = document.image
        #expect(throws: ImageCodecError.corrupt) {
            try document.read(from: full.prefix(full.count / 2), ofType: "public.png")
        }
        #expect(document.image == imageBefore, "a failed read must leave the image unchanged")
    }

    @Test func documentUsesStandardLimitsByDefault() {
        #expect(PaintDocument.imageLimitsOverride == nil)
        #expect(PaintDocument.imageLimits == ImageLimits.standard)
    }
}
