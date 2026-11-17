import Foundation
import Testing

@testable import PaintDotMac

/// `CompositeChangeTracker` (spec 0024 item 5): what makes composite tiles stale and
/// what must not recomposite anything.
struct CompositeChangeTrackerTests {
    private let size = PixelSize(width: 600, height: 300)   // 3 × 2 tiles

    private func stack(layers: Int) -> LayeredImage {
        var layersArray: [Layer] = []
        for index in 0..<layers {
            var surface = TiledSurface(size: size)
            var tile = Tile()
            tile.setPixel(ColorRGBA8(red: UInt8(index), green: 1, blue: 2, alpha: 255),
                          x: 0, y: 0)
            surface.setTile(tile, at: TileCoordinate(column: 0, row: 0))
            layersArray.append(Layer(name: "L\(index)", surface: surface))
        }
        return LayeredImage(size: size, layers: layersArray, activeLayerIndex: 0)
    }

    @Test func firstUpdateIsAll() {
        var tracker = CompositeChangeTracker()
        #expect(tracker.update(for: stack(layers: 2)) == .all)
    }

    @Test func unchangedIsEmpty() {
        var tracker = CompositeChangeTracker()
        let image = stack(layers: 2)
        _ = tracker.update(for: image)
        #expect(tracker.update(for: image) == .tiles([]))
    }

    @Test func pixelEditOnAnyLayerReportsTiles() {
        var tracker = CompositeChangeTracker()
        var image = stack(layers: 3)
        _ = tracker.update(for: image)
        image.layers[2].surface.setPixel(.white, at: PixelPoint(x: 300, y: 10))
        #expect(tracker.update(for: image) == .tiles([TileCoordinate(column: 1, row: 0)]))
    }

    @Test func hiddenLayerEditReportsTiles() {
        var tracker = CompositeChangeTracker()
        var image = stack(layers: 2)
        _ = tracker.update(for: image)
        image.layers[1].isVisible = false
        _ = tracker.update(for: image)   // visibility change → .all
        var edited = image
        edited.layers[1].surface.setPixel(.white, at: PixelPoint(x: 0, y: 260))
        // Hidden layers are watched too (harmless and simpler).
        #expect(tracker.update(for: edited) == .tiles([TileCoordinate(column: 0, row: 1)]))
    }

    @Test func visibilityChangeIsAll() {
        var tracker = CompositeChangeTracker()
        var image = stack(layers: 2)
        _ = tracker.update(for: image)
        image.layers[1].isVisible = false
        #expect(tracker.update(for: image) == .all)
    }

    @Test func opacityChangeIsAll() {
        var tracker = CompositeChangeTracker()
        var image = stack(layers: 2)
        _ = tracker.update(for: image)
        image.layers[0].opacity = 200
        #expect(tracker.update(for: image) == .all)
    }

    @Test func reorderIsAll() {
        var tracker = CompositeChangeTracker()
        var image = stack(layers: 3)
        _ = tracker.update(for: image)
        image.layers.swapAt(0, 1)
        #expect(tracker.update(for: image) == .all)
    }

    @Test func addAndDeleteAreAll() {
        var tracker = CompositeChangeTracker()
        var image = stack(layers: 2)
        _ = tracker.update(for: image)
        image.layers.append(Layer(name: "L2", surface: TiledSurface(size: size)))
        #expect(tracker.update(for: image) == .all)
        var shrunk = image
        shrunk.layers.removeLast()
        #expect(tracker.update(for: shrunk) == .all)
    }

    @Test func sizeChangeIsAll() {
        var tracker = CompositeChangeTracker()
        _ = tracker.update(for: stack(layers: 1))
        #expect(tracker.update(for: LayeredImage.blank(size: PixelSize(width: 512, height: 512),
                                                      fill: .white)) == .all)
    }

    @Test func olderGenerationIsAll() {
        var tracker = CompositeChangeTracker()
        let before = stack(layers: 2)
        _ = tracker.update(for: before)
        var after = before
        after.layers[0].surface.setPixel(.white, at: PixelPoint(x: 5, y: 5))
        #expect(tracker.update(for: after) == .tiles([TileCoordinate(column: 0, row: 0)]))
        // The copy captured before the edit: same ids, lower generation (undo of a
        // snapshot) → everything is stale.
        #expect(tracker.update(for: before) == .all)
    }

    @Test func activeLayerChangeIsEmpty() {
        var tracker = CompositeChangeTracker()
        var image = stack(layers: 3)
        _ = tracker.update(for: image)
        image.activeLayerIndex = 2
        #expect(tracker.update(for: image) == .tiles([]))
    }

    @Test func resetMakesAll() {
        var tracker = CompositeChangeTracker()
        let image = stack(layers: 2)
        _ = tracker.update(for: image)
        #expect(tracker.update(for: image) == .tiles([]))
        tracker.reset()
        #expect(tracker.update(for: image) == .all)
    }
}
