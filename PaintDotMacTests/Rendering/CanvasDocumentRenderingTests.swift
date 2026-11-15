import Foundation
import Metal
import Testing
@testable import PaintDotMac

/// End-to-end proof for spec 0003: a PNG with transparency is decoded by 0002's
/// `ImageDecoder` into a `LayeredImage`, uploaded tile-by-tile by the renderer, and the
/// offscreen device pixels match the independent CPU oracle ±1 — decode → tiles → upload →
/// display, with no window involved.
@MainActor
@Suite(.serialized)
struct CanvasDocumentRenderingTests {
    @Test func decodedPNGRendersLikeTheOracle() throws {
        let fixtures = try FixtureFiles()
        defer { fixtures.removeAll() }
        let device = try MetalTestTarget.makeDevice()
        let url = try fixtures.writePNG(named: "decoded.png", width: 300, height: 200) { x, y in
            // Diagonal bands of opaque, semi-transparent, and fully transparent pixels so
            // premultiplication, the checkerboard, and edge mips are all exercised.
            switch (x + y) % 6 {
            case 0, 1: ColorRGBA8(red: UInt8(truncatingIfNeeded: x &* 3), green: UInt8(truncatingIfNeeded: y &* 2),
                                  blue: 90, alpha: 255)
            case 2, 3: ColorRGBA8(red: 20, green: UInt8(truncatingIfNeeded: x &* 2), blue: 200, alpha: 128)
            case 4: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 0)   // color under alpha 0
            default: .clear
            }
        }
        let data = try Data(contentsOf: url)
        let image = try ImageDecoder.decodeImage(from: data)
        #expect(image.size == PixelSize(width: 300, height: 200))

        // A 400×300 pt view on a 2× display: the whole image is visible, zoom fits to 1.
        let transform = CanvasTransform.initial(imageSize: image.size,
                                                viewSize: CGSize(width: 400, height: 300),
                                                backingScale: 2)
        #expect(transform.zoom == 1)   // 800×600 device view around a 300×200 image

        let frame = CanvasFrame(image: image, transform: transform,
                                backgroundColor: CanvasReferenceRenderer.testBackground)
        let renderer = try MetalCanvasRenderer(device: device)
        let drawable = transform.drawableSize
        let output = try MetalTestTarget.render(frame, with: renderer, device: device,
                                                width: drawable.width, height: drawable.height)
        let expected = CanvasReferenceRenderer.render(image: image, transform: transform,
                                                      backgroundColor: CanvasReferenceRenderer.testBackground)
        MetalTestTarget.assertPixelsMatch(output, match: expected,
                                          width: drawable.width, height: drawable.height,
                                          tolerance: 1, "decoded PNG vs oracle")
    }
}
