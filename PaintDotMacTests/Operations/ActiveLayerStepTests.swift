import Foundation
import Testing

@testable import PaintDotMac

/// `ActiveLayerStep.targetIndex` (spec 0024): Go to Layer Above / Below move the editing
/// focus one step and are nil at the ends (menu disabled; L-1, D-51).
struct ActiveLayerStepTests {
    private func image(layerCount: Int, active: Int) -> LayeredImage {
        let surface = TiledSurface(size: PixelSize(width: 1, height: 1))
        return LayeredImage(size: PixelSize(width: 1, height: 1),
                            layers: (0..<layerCount).map { Layer(name: "\($0)", surface: surface) },
                            activeLayerIndex: active)
    }

    @Test func singleLayerEndsAreNil() {
        let one = image(layerCount: 1, active: 0)
        #expect(ActiveLayerStep.above.targetIndex(in: one) == nil)
        #expect(ActiveLayerStep.below.targetIndex(in: one) == nil)
    }

    @Test func threeLayerStack() {
        #expect(ActiveLayerStep.above.targetIndex(in: image(layerCount: 3, active: 0)) == 1)
        #expect(ActiveLayerStep.below.targetIndex(in: image(layerCount: 3, active: 0)) == nil)
        #expect(ActiveLayerStep.above.targetIndex(in: image(layerCount: 3, active: 1)) == 2)
        #expect(ActiveLayerStep.below.targetIndex(in: image(layerCount: 3, active: 1)) == 0)
        #expect(ActiveLayerStep.above.targetIndex(in: image(layerCount: 3, active: 2)) == nil)
        #expect(ActiveLayerStep.below.targetIndex(in: image(layerCount: 3, active: 2)) == 1)
    }
}
