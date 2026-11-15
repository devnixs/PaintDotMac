import Foundation
import Testing
@testable import PaintDotMac

/// PRD APP-9: the new image is one opaque white layer named "Background" at the chosen size
/// and DPI. Every pixel is checked by full scan against hand-computed (255, 255, 255, 255).
struct NewImageRequestTests {
    @Test func makeImageProducesWhiteBackground() throws {
        let image = NewImageRequest(size: PixelSize(width: 800, height: 600), dpi: 96).makeImage()
        #expect(image.size == PixelSize(width: 800, height: 600))
        #expect(image.dpi == 96)
        #expect(image.layers.count == 1)
        let layer = try #require(image.layers.first)
        #expect(layer.name == "Background")
        #expect(layer.isVisible)
        #expect(layer.opacity == 255)
        #expect(layer.blendMode == .normal)
        #expect(image.activeLayerIndex == 0)
        TestImages.expectPixels(layer.surface,
                                match: { _, _ in ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255) },
                                "every pixel of a new image is opaque white")
    }

    /// 1×1, a size crossing 256-pixel tile boundaries (257×257), and the widest legal side
    /// are each white at every pixel — no unfilled edge tiles.
    @Test(arguments: [(1, 1), (257, 257), (65_535, 1)])
    func makeImageTileEdges(_ sides: (Int, Int)) {
        let image = NewImageRequest(size: PixelSize(width: sides.0, height: sides.1), dpi: 96).makeImage()
        TestImages.expectPixels(image.layers[0].surface,
                                match: { _, _ in ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255) },
                                "\(sides.0)\u{00D7}\(sides.1) fully white")
    }
}
