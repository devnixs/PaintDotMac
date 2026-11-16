import Foundation
import Testing

@testable import PaintDotMac

struct HistoryCostTests {
    private func whiteSurface(_ width: Int, _ height: Int) -> TiledSurface {
        var surface = TiledSurface(size: PixelSize(width: width, height: height))
        surface.fill(.white)
        return surface
    }

    private func image(_ surfaces: [TiledSurface]) -> LayeredImage {
        LayeredImage(size: surfaces[0].size,
                     layers: surfaces.enumerated().map { index, surface in
                         Layer(name: "Layer \(index + 1)", surface: surface)
                     },
                     activeLayerIndex: 0)
    }

    @Test func tileBytesNilIsZero() {
        #expect(HistoryCost.tileBytes(nil) == 0)
    }

    @Test func tileBytesFullTile() {
        #expect(HistoryCost.tileBytes(Tile()) == 262_144)
        #expect(HistoryCost.tileBytes(Tile(filledWith: .white)) == 262_144)
    }

    @Test func storageKeyMatchesSharesStorage() {
        let tile = Tile(filledWith: .white)
        var copy = tile  // CoW: still the same buffer
        #expect(copy.sharesStorage(with: tile))
        #expect(HistoryCost.storageKey(copy) == HistoryCost.storageKey(tile))

        copy.setPixel(.black, x: 0, y: 0)  // CoW split
        #expect(!copy.sharesStorage(with: tile))
        #expect(HistoryCost.storageKey(copy) != HistoryCost.storageKey(tile))
    }

    @Test func addEmptyLayerCostsZero() {
        let before = DocumentState(image: image([whiteSurface(512, 512)]))
        var afterLayers = before.image.layers
        afterLayers.append(Layer(name: "Layer 2",
                                 surface: TiledSurface(size: PixelSize(width: 512, height: 512))))
        var afterImage = before.image
        afterImage.layers = afterLayers
        #expect(HistoryCost.unsharedTileBytes(before: before, after: DocumentState(image: afterImage))
                == 0)
    }

    @Test func duplicateLayerCostsZero() {
        let surface = whiteSurface(512, 512)
        let before = DocumentState(image: image([surface]))
        var afterImage = before.image
        afterImage.layers.append(Layer(name: "Copy", surface: surface))  // shared storage
        #expect(HistoryCost.unsharedTileBytes(before: before, after: DocumentState(image: afterImage))
                == 0)
    }

    @Test func deleteLayerCostsItsTiles() throws {
        // A layer with 3 separately written (never shared) tiles.
        var surface = TiledSurface(size: PixelSize(width: 512, height: 512))
        surface.fill(.white, in: PixelRect(x: 0, y: 0, width: 256, height: 256))
        surface.fill(ColorRGBA8(red: 255, green: 0, blue: 0), in: PixelRect(x: 256, y: 0, width: 256, height: 256))
        surface.fill(ColorRGBA8(red: 0, green: 255, blue: 0), in: PixelRect(x: 0, y: 256, width: 256, height: 256))
        #expect(surface.allocatedTileCoordinates.count == 3)
        var beforeImage = image([surface, whiteSurface(512, 512)])
        beforeImage.layers[1].surface = TiledSurface(size: PixelSize(width: 512, height: 512))
        // Only the deleted layer carries tiles; each of the 3 fills used its own buffer.
        let keys = Set(beforeImage.layers[0].surface.allocatedTileCoordinates.compactMap {
            beforeImage.layers[0].surface.tile(at: $0).map(HistoryCost.storageKey)
        })
        #expect(keys.count == 3)
        let before = DocumentState(image: beforeImage)
        var afterImage = beforeImage
        afterImage.layers.remove(at: 0)
        #expect(HistoryCost.unsharedTileBytes(before: before, after: DocumentState(image: afterImage))
                == 3 * 262_144)
    }

    @Test func rewrittenCanvasCostsBothSides() throws {
        // before: 2 distinct tiles; after: 4 distinct tiles, none of them shared.
        var beforeSurface = TiledSurface(size: PixelSize(width: 512, height: 256))
        beforeSurface.fill(.white, in: PixelRect(x: 0, y: 0, width: 256, height: 256))
        beforeSurface.fill(ColorRGBA8(red: 255, green: 0, blue: 0),
                           in: PixelRect(x: 256, y: 0, width: 256, height: 256))
        var afterSurface = TiledSurface(size: PixelSize(width: 512, height: 512))
        for (index, point) in [(0, 0), (256, 0), (0, 256), (256, 256)].enumerated() {
            afterSurface.fill(ColorRGBA8(red: UInt8(index + 1), green: 0, blue: 0),
                              in: PixelRect(x: point.0, y: point.1, width: 256, height: 256))
        }
        let before = DocumentState(image: image([beforeSurface]))
        let after = DocumentState(image: image([afterSurface]))
        #expect(HistoryCost.unsharedTileBytes(before: before, after: after)
                == (2 + 4) * 262_144)
    }

    @Test func sharedStorageCountedOnce() throws {
        // Two layers share one tile buffer; deleting both costs one tile, not two.
        let shared = Tile(filledWith: .white)
        let size = PixelSize(width: 512, height: 512)
        var surfaceA = TiledSurface(size: size)
        var surfaceB = TiledSurface(size: size)
        surfaceA.setTile(shared, at: TileCoordinate(column: 0, row: 0))
        surfaceB.setTile(shared, at: TileCoordinate(column: 0, row: 0))
        let before = DocumentState(image: image([surfaceA, surfaceB]))
        var afterImage = before.image
        afterImage.layers.removeSubrange(0...)
        afterImage.layers = [Layer(name: "Empty", surface: TiledSurface(size: size))]
        #expect(HistoryCost.unsharedTileBytes(before: before, after: DocumentState(image: afterImage))
                == 262_144)
    }

    @Test func stepOverheadIs1024() {
        #expect(HistoryCost.stepOverheadBytes == 1_024)
    }
}
