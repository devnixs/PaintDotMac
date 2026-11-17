import Foundation
import Testing

@testable import PaintDotMac

/// `LayerNaming` (spec 0024 *Test plan*): Paint.NET's generic "Layer *X*" numbering and
/// the "`<name>` copy" duplicate name (L-1, D-51).
struct LayerNamingTests {
    private func layer(_ name: String) -> Layer {
        Layer(name: name, surface: TiledSurface(size: PixelSize(width: 1, height: 1)))
    }

    @Test func newLayerNameCountsLayers() {
        #expect(LayerNaming.newLayerName(existing: [layer("Background")]) == "Layer 2")
        #expect(LayerNaming.newLayerName(existing: [layer("Background"), layer("Layer 2")])
                == "Layer 3")
        #expect(LayerNaming.newLayerName(existing: [layer("A"), layer("B"), layer("C")])
                == "Layer 4")
    }

    @Test func newLayerNameSkipsTakenNames() {
        // count + 1 = 3 is taken → "Layer 4".
        #expect(LayerNaming.newLayerName(existing: [layer("Background"), layer("Layer 3")])
                == "Layer 4")
        #expect(LayerNaming.newLayerName(existing: [layer("Layer 2"), layer("Layer 3")])
                == "Layer 4")
    }

    @Test func duplicateName() {
        #expect(LayerNaming.duplicateName(of: "Background") == "Background copy")
        #expect(LayerNaming.duplicateName(of: "Layer 2 copy") == "Layer 2 copy copy")
        #expect(LayerNaming.duplicateName(of: "") == " copy")
    }
}
