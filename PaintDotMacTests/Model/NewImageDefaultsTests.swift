import Foundation
import ImageIO
import Testing
@testable import PaintDotMac

/// Expected values from PRD APP-9 / D-30 (800×600 @ 96, clipboard DPI ignored, sides
/// 1–65,535) and the spec's *Test plan* — none computed by the code under test.
struct NewImageDefaultsTests {
    @Test func fallbackWhenNoClipboard() {
        #expect(NewImageDefaults.initialRequest(clipboardImageSize: nil)
                == NewImageRequest(size: PixelSize(width: 800, height: 600), dpi: 96))
    }

    @Test func clipboardSizeUsed() {
        #expect(NewImageDefaults.initialRequest(clipboardImageSize: (width: 123, height: 45))
                == NewImageRequest(size: PixelSize(width: 123, height: 45), dpi: 96))
    }

    @Test func clipboardSizeBounds() {
        // 1×1 and 65,535×1 (262 KB) are legal sides and stay.
        #expect(NewImageDefaults.initialRequest(clipboardImageSize: (width: 1, height: 1))
                == NewImageRequest(size: PixelSize(width: 1, height: 1), dpi: 96))
        #expect(NewImageDefaults.initialRequest(clipboardImageSize: (width: 65_535, height: 1))
                == NewImageRequest(size: PixelSize(width: 65_535, height: 1), dpi: 96))
        // Out-of-range or nonsensical sides → the 800×600 fallback, never a trap.
        let fallback = NewImageRequest(size: PixelSize(width: 800, height: 600), dpi: 96)
        #expect(NewImageDefaults.initialRequest(clipboardImageSize: (width: 65_536, height: 10)) == fallback)
        #expect(NewImageDefaults.initialRequest(clipboardImageSize: (width: 0, height: 10)) == fallback)
        #expect(NewImageDefaults.initialRequest(clipboardImageSize: (width: 10, height: -1)) == fallback)
    }

    /// The clipboard's DPI is ignored (D-30): even a size coming from a 300 DPI PNG still
    /// opens the dialog at 96.
    @Test func clipboardDPIAlwaysFallback() throws {
        let png = TestImages.encode(
            TestImages.cgImage(width: 40, height: 40, bytes: TestImages.rgbaBytes(width: 40, height: 40) { _, _ in .white }),
            as: .png,
            properties: [kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300]
        )
        let size = try #require(NewImageDefaults.clipboardImageSize(pngData: png, tiffData: nil))
        let request = NewImageDefaults.initialRequest(clipboardImageSize: size)
        #expect(request.size == PixelSize(width: 40, height: 40))
        #expect(request.dpi == 96)
    }

    // MARK: - clipboardImageSize (header only, PNG preferred)

    @Test func clipboardImageSizeReadsPNG() throws {
        let png = TestImages.encode(
            TestImages.cgImage(width: 123, height: 45,
                               bytes: TestImages.rgbaBytes(width: 123, height: 45) { _, _ in .white }),
            as: .png)
        #expect((NewImageDefaults.clipboardImageSize(pngData: png, tiffData: nil) ?? (0, 0)) == (123, 45))
    }

    @Test func pngPreferredOverTIFF() throws {
        let png = TestImages.encode(
            TestImages.cgImage(width: 10, height: 10,
                               bytes: TestImages.rgbaBytes(width: 10, height: 10) { _, _ in .white }),
            as: .png)
        let tiff = TestImages.encode(
            TestImages.cgImage(width: 20, height: 20,
                               bytes: TestImages.rgbaBytes(width: 20, height: 20) { _, _ in .white }),
            as: .tiff)
        #expect((NewImageDefaults.clipboardImageSize(pngData: png, tiffData: tiff) ?? (0, 0)) == (10, 10))
    }

    @Test func tiffUsedWhenPNGUnreadable() throws {
        let garbagePNG = Data([0x89, 0x50, 0x00, 0x01, 0x02, 0x03])  // not a PNG at all
        let tiff = TestImages.encode(
            TestImages.cgImage(width: 20, height: 20,
                               bytes: TestImages.rgbaBytes(width: 20, height: 20) { _, _ in .white }),
            as: .tiff)
        #expect((NewImageDefaults.clipboardImageSize(pngData: garbagePNG, tiffData: tiff) ?? (0, 0)) == (20, 20))
    }

    @Test func nothingReadable() throws {
        #expect(NewImageDefaults.clipboardImageSize(pngData: nil, tiffData: nil) == nil)
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF])
        #expect(NewImageDefaults.clipboardImageSize(pngData: garbage, tiffData: garbage) == nil)
        let text = Data("plain clipboard text".utf8)
        #expect(NewImageDefaults.clipboardImageSize(pngData: text, tiffData: text) == nil)
    }

    // MARK: - Form initial text

    @Test func formInitialText() {
        let form = NewImageForm(request: NewImageRequest(size: PixelSize(width: 800, height: 600), dpi: 96))
        #expect(form.widthText == "800")
        #expect(form.heightText == "600")
        #expect(form.resolutionText == "96")  // no trailing ".0"
        let fractional = NewImageForm(request: NewImageRequest(size: PixelSize(width: 8, height: 6), dpi: 72.5))
        #expect(fractional.resolutionText == "72.5")
    }

    @Test func constants() {
        #expect(NewImageDefaults.fallbackSize == PixelSize(width: 800, height: 600))
        #expect(NewImageDefaults.fallbackDPI == 96)
        #expect(NewImageDefaults.backgroundLayerName == "Background")
        #expect(NewImageDefaults.dpiRange == 1...10_000)
    }
}
