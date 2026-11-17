import Foundation
import Testing

@testable import PaintDotMac

/// The history side of the layer commands (spec 0024): 0008's `DocumentSnapshotHistoryItem`
/// with Paint.NET's names and icons, exact apply/revert, an untouched selection (0013,
/// D-40), and `HistoryCost` accounting (NF-4, H-5).
struct LayerHistoryTests {
    private func seededStack(size: PixelSize = PixelSize(width: 600, height: 600),
                             layers: Int = 3, active: Int = 1) -> LayeredImage {
        var result: [Layer] = []
        for index in 0..<layers {
            var random = SeededRandom(seed: 0xA17 + UInt64(index))
            let surface = TestImages.surface(width: size.width, height: size.height) { _, _ in
                random.color()
            }
            result.append(Layer(name: "L\(index)", surface: surface))
        }
        return LayeredImage(size: size, layers: result, activeLayerIndex: active)
    }

    @Test func itemNamesIconsAndChange() throws {
        let state = DocumentState(image: seededStack(active: 1))
        for command in LayerCommand.allCases {
            let item = try #require(command.makeHistoryItem(for: state), "\(command.rawValue)")
            #expect(item.name == command.name, "\(command.rawValue)")
            #expect(item.icon == command.icon, "\(command.rawValue)")
            #expect(item.change == .structure, "\(command.rawValue)")
            #expect(!item.isNoOp, "\(command.rawValue)")
        }
    }

    @Test func applyRevertExact() throws {
        let before = DocumentState(image: seededStack(active: 1))
        // Add and Duplicate mint a fresh UUID per call, so those layers compare
        // everything but the id; every other layer keeps its identity.
        let freshIDCommands: [LayerCommand] = [.addNewLayer, .duplicateLayer]
        for command in LayerCommand.allCases {
            let item = try #require(command.makeHistoryItem(for: before), "\(command.rawValue)")
            var forward = before
            item.apply(to: &forward)
            #expect(forward == item.after, "\(command.rawValue) apply")
            let expected = try #require(command.applied(to: before.image),
                                        "\(command.rawValue) applied")
            #expect(forward.image.layers.count == expected.layers.count,
                    "\(command.rawValue) after count")
            let beforeIDs = Set(before.image.layers.map(\.id))
            for (got, want) in zip(forward.image.layers, expected.layers) {
                let fresh = freshIDCommands.contains(command) && !beforeIDs.contains(want.id)
                #expect(got.id == want.id || fresh, "\(command.rawValue) id \(want.name)")
                #expect(got.name == want.name, "\(command.rawValue) name")
                #expect(got.isVisible == want.isVisible && got.opacity == want.opacity,
                        "\(command.rawValue) properties \(want.name)")
                #expect(got.blendMode == want.blendMode, "\(command.rawValue) blend \(want.name)")
                #expect(got.surface == want.surface, "\(command.rawValue) pixels \(want.name)")
            }
            #expect(forward.image.activeLayerIndex == expected.activeLayerIndex,
                    "\(command.rawValue) active")
            var back = forward
            item.revert(&back)
            #expect(back == before, "\(command.rawValue) revert")
            #expect(back.image.activeLayerIndex == before.image.activeLayerIndex)
            #expect(back.image.layers.map(\.id) == before.image.layers.map(\.id))
        }
    }

    @Test func selectionUnchanged() throws {
        let image = seededStack(active: 1)
        let selection = try #require(Selection(rect: CGRect(x: 10, y: 10, width: 50, height: 50),
                                               canvasSize: image.size))
        let before = DocumentState(image: image, selection: selection)
        for command in LayerCommand.allCases {
            let item = try #require(command.makeHistoryItem(for: before), "\(command.rawValue)")
            #expect(item.after.selection == before.selection, "\(command.rawValue)")
            var forward = before
            item.apply(to: &forward)
            #expect(forward.selection == before.selection, "\(command.rawValue)")
            item.revert(&forward)
            #expect(forward.selection == before.selection, "\(command.rawValue)")
        }
    }

    @Test func costs() throws {
        let byteCount = Tile.byteCount
        let size = PixelSize(width: 600, height: 600)
        func blankLayer(_ name: String, tiles: [TileCoordinate]) -> Layer {
            var surface = TiledSurface(size: size)
            for tile in tiles {
                // Edge tiles must be zero outside the canvas; fill only in-bounds pixels.
                var filled = Tile()
                let originX = tile.column * TiledSurface.tileSize
                let originY = tile.row * TiledSurface.tileSize
                for y in 0..<TiledSurface.tileSize where originY + y < size.height {
                    for x in 0..<TiledSurface.tileSize where originX + x < size.width {
                        filled.setPixel(.black, x: x, y: y)
                    }
                }
                surface.setTile(filled, at: tile)
            }
            return Layer(name: name, surface: surface)
        }
        let c00 = TileCoordinate(column: 0, row: 0)
        let c10 = TileCoordinate(column: 1, row: 0)

        // Add: the new layer allocates nothing → 0.
        let addState = DocumentState(image: LayeredImage(size: size,
                                                         layers: [blankLayer("A", tiles: [c00, c10, TileCoordinate(column: 2, row: 2)])],
                                                         activeLayerIndex: 0))
        let add = try #require(LayerCommand.addNewLayer.makeHistoryItem(for: addState))
        #expect(add.byteCost == 0)

        // Duplicate: the copy shares every tile → 0.
        let dup = try #require(LayerCommand.duplicateLayer.makeHistoryItem(for: addState))
        #expect(dup.byteCost == 0)

        // Move: same storages, new order → 0.
        let moveState = DocumentState(image: seededStack(layers: 3, active: 1))
        let move = try #require(LayerCommand.moveLayerUp.makeHistoryItem(for: moveState))
        #expect(move.byteCost == 0)

        // Delete of the layer with 3 allocated unshared tiles → 3 tiles.
        let deleteState = DocumentState(image: LayeredImage(
            size: size,
            layers: [blankLayer("A", tiles: [c00, c10, TileCoordinate(column: 2, row: 2)]),
                     blankLayer("B", tiles: [])],
            activeLayerIndex: 0))
        let delete = try #require(LayerCommand.deleteLayer.makeHistoryItem(for: deleteState))
        #expect(delete.byteCost == 3 * byteCount)

        // Merge: upper's 2 tiles over lower's 2 same-coordinate tiles =
        // (2 lower before + 2 upper before) + 2 new after = 6 tiles.
        let mergeState = DocumentState(image: LayeredImage(
            size: size,
            layers: [blankLayer("A", tiles: [c00, c10]), blankLayer("B", tiles: [c00, c10])],
            activeLayerIndex: 1))
        let merge = try #require(LayerCommand.mergeLayerDown.makeHistoryItem(for: mergeState))
        #expect(merge.byteCost == 6 * byteCount)
    }
}
