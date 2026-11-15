import Foundation
import Testing
@testable import PaintDotMac

/// Headless end-to-end (spec 0005 *Test plan*): dialog values → validation → the new image →
/// PNG bytes → decode. Pure Core, no document.
struct NewImageSaveIntegrationTests {
    @Test func newImageRoundTrip() throws {
        let form = NewImageForm(request: NewImageRequest(size: PixelSize(width: 640, height: 480), dpi: 300))
        let request = try #require(form.validate(limits: .standard).success)
        let image = request.makeImage()
        let data = try ImageEncoder.encode(image, as: .png)

        let decoded = try ImageDecoder.decodeImage(from: data)
        #expect(decoded.size == PixelSize(width: 640, height: 480))
        #expect(decoded.layers.count == 1)
        #expect(decoded.layers[0].name == "Background")
        TestImages.expectPixels(decoded.layers[0].surface,
                                match: { _, _ in ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255) })
        #expect(abs(decoded.dpi - 300) <= 0.05)
    }
}
