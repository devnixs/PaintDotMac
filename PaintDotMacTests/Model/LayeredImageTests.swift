import Foundation
import Testing

@testable import PaintDotMac

struct LayeredImageTests {
    private func surface(_ width: Int = 100, _ height: Int = 80) -> TiledSurface {
        TiledSurface(size: PixelSize(width: width, height: height))
    }

    @Test func singleLayerInit() {
        let s = surface()
        let image = LayeredImage(surface: s)
        #expect(image.layers.count == 1)
        #expect(image.layers[0].name == "Background")
        #expect(image.layers[0].isVisible)
        #expect(image.layers[0].opacity == 255)
        #expect(image.layers[0].blendMode == .normal)
        #expect(image.activeLayerIndex == 0)
        #expect(image.dpi == 96)
        #expect(image.size == s.size)
        #expect(image.isConsistent)
    }

    @Test func blankWhite() {
        let image = LayeredImage.blank(size: PixelSize(width: 800, height: 600), fill: .white)
        #expect(image.dpi == 96)
        let layer = image.layers[0]
        for p in [(0, 0), (255, 255), (256, 256), (799, 599)] {
            #expect(layer.surface.pixel(at: PixelPoint(x: p.0, y: p.1)) == .white, "\(p)")
        }
    }

    @Test func isConsistentDetectsInvalidStates() {
        var image = LayeredImage.blank(size: PixelSize(width: 10, height: 10), fill: .clear)
        #expect(image.isConsistent)
        image.layers = []
        #expect(!image.isConsistent)

        image = LayeredImage.blank(size: PixelSize(width: 10, height: 10), fill: .clear)
        image.layers[0] = Layer(id: image.layers[0].id, name: "wrong size", surface: surface(11, 10))
        #expect(!image.isConsistent)

        image = LayeredImage.blank(size: PixelSize(width: 10, height: 10), fill: .clear)
        image.layers.append(Layer(id: image.layers[0].id, name: "copy id", surface: surface(10, 10)))
        #expect(!image.isConsistent)

        image = LayeredImage.blank(size: PixelSize(width: 10, height: 10), fill: .clear)
        image.activeLayerIndex = image.layers.count
        #expect(!image.isConsistent)
        image.activeLayerIndex = -1
        #expect(!image.isConsistent)

        for dpi in [0.0, -1.0, .nan, .infinity] {
            var dpiImage = LayeredImage.blank(size: PixelSize(width: 10, height: 10), fill: .clear)
            dpiImage.dpi = dpi
            #expect(!dpiImage.isConsistent, "dpi \(dpi)")
        }

        var validDPI = LayeredImage.blank(size: PixelSize(width: 10, height: 10), fill: .clear)
        validDPI.dpi = 72.5
        #expect(validDPI.isConsistent)
        #expect(LayeredImage.isValidDPI(72.5))
        #expect(!LayeredImage.isValidDPI(0))
        #expect(!LayeredImage.isValidDPI(.nan))
    }

    @Test func activeLayerAccessor() {
        var image = LayeredImage(
            size: PixelSize(width: 10, height: 10),
            layers: [
                Layer(name: "Bottom", surface: surface(10, 10)),
                Layer(name: "Top", surface: surface(10, 10)),
            ],
            activeLayerIndex: 1
        )
        image.activeLayer.name = "Top 2"
        #expect(image.layers[1].name == "Top 2")
        #expect(image.layers[0].name == "Bottom")
    }

    @Test func layerEqualityIncludesPixels() {
        let id = UUID()
        var a = TiledSurface(size: PixelSize(width: 4, height: 4))
        a.setPixel(.white, at: PixelPoint(x: 1, y: 1))
        var b = TiledSurface(size: PixelSize(width: 4, height: 4))
        b.setPixel(.white, at: PixelPoint(x: 1, y: 1))
        let layerA = Layer(id: id, name: "L", surface: a)
        let layerB = Layer(id: id, name: "L", surface: b)
        #expect(layerA == layerB)
        b.setPixel(.black, at: PixelPoint(x: 3, y: 3))
        let layerC = Layer(id: id, name: "L", surface: b)
        #expect(layerA != layerC)
        #expect(Layer(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "L", surface: a)
                != layerA, "ids participate in equality")
    }

    @Test func blendModeNormal() {
        #expect(BlendMode.allCases == [.normal])
        #expect(BlendMode.normal.rawValue == "normal")
        #expect(BlendMode.normal.displayName == "Normal")
    }

    @Test func defaults() {
        #expect(LayeredImage.defaultDPI == 96)
        #expect(LayeredImage.defaultLayerName == "Background")
    }
}
