import Foundation
import Testing

@testable import PaintDotMac

struct TileDiffTests {
    private func coord(_ column: Int, _ row: Int) -> TileCoordinate {
        TileCoordinate(column: column, row: row)
    }

    private func whiteImage(_ width: Int, _ height: Int) -> LayeredImage {
        .blank(size: PixelSize(width: width, height: height), fill: .white)
    }

    private func emptyImage(_ width: Int, _ height: Int) -> LayeredImage {
        LayeredImage(surface: TiledSurface(size: PixelSize(width: width, height: height)))
    }

    /// `diff` over the whole canvas (candidates nil), the capture pattern without candidates.
    private func fullDiff(before: LayeredImage, after: LayeredImage) throws(TileDiffError) -> TileDiff {
        try TileDiff.between(before: before, after: after)
    }

    @Test func unchangedTilesAreSkipped() throws {
        let before = whiteImage(512, 512)
        let after = before  // copy, no writes
        let diff = try fullDiff(before: before, after: after)
        #expect(diff.isEmpty)
        #expect(diff.entries.isEmpty)
        #expect(diff.byteCost == 0)
        #expect(diff.changedTiles.isEmpty)
    }

    @Test func identicalWriteIsEmpty() throws {
        let before = whiteImage(512, 512)
        var after = before
        fillRect(&after, layer: 0, rect: PixelRect(x: 10, y: 10, width: 20, height: 20),
                 color: .white)
        let diff = try fullDiff(before: before, after: after)
        #expect(diff.isEmpty, "writing identical pixels records nothing")
        #expect(diff.byteCost == 0)
    }

    @Test func singleTileChange() throws {
        let before = whiteImage(512, 512)
        var after = before
        let red = ColorRGBA8(red: 255, green: 0, blue: 0)
        fillRect(&after, layer: 0, rect: PixelRect(x: 10, y: 10, width: 20, height: 20),
                 color: red)
        let diff = try fullDiff(before: before, after: after)
        #expect(diff.entries.count == 1)
        let entry = try #require(diff.entries.first)
        #expect(entry.layerID == before.layers[0].id)
        #expect(entry.coordinate == coord(0, 0))
        #expect(entry.before != nil)
        #expect(entry.after != nil)
        #expect(diff.byteCost == 524_288)  // 2 × 262,144
        #expect(diff.changedTiles == [before.layers[0].id: [coord(0, 0)]])
    }

    @Test func crossTileChange() throws {
        let before = whiteImage(512, 512)
        var after = before
        fillRect(&after, layer: 0, rect: PixelRect(x: 250, y: 250, width: 10, height: 10),
                 color: .black)
        let diff = try fullDiff(before: before, after: after)
        #expect(diff.entries.map(\.coordinate)
                == [coord(0, 0), coord(1, 0), coord(0, 1), coord(1, 1)],
                "row-then-column order")
        #expect(diff.byteCost == 2_097_152)  // 4 × 2 × 262,144
    }

    @Test func sparseBeforeTile() throws {
        let before = emptyImage(512, 512)
        var after = before
        fillRect(&after, layer: 0, rect: PixelRect(x: 300, y: 300, width: 5, height: 5),
                 color: .white)
        let diff = try fullDiff(before: before, after: after)
        #expect(diff.entries.count == 1)
        let entry = try #require(diff.entries.first)
        #expect(entry.coordinate == coord(1, 1))
        #expect(entry.before == nil)
        #expect(entry.after != nil)
        #expect(diff.byteCost == 262_144)

        diff.revert(&after)
        #expect(after.layers[0].surface.tile(at: coord(1, 1)) == nil,
                "undoing a sparse write frees the tile again")
        diff.apply(to: &after)
        #expect(after.layers[0].surface.tile(at: coord(1, 1)) != nil)
    }

    @Test func candidatesLimitTheScan() throws {
        let layerID = UUID()
        let beforeSurface = TiledSurface(size: PixelSize(width: 512, height: 512))
        var afterSurface = beforeSurface
        let red = ColorRGBA8(red: 255, green: 0, blue: 0)
        afterSurface.fill(red, in: PixelRect(x: 10, y: 10, width: 5, height: 5))   // tile (0,0)
        afterSurface.fill(ColorRGBA8(red: 0, green: 0, blue: 255),
                          in: PixelRect(x: 300, y: 300, width: 5, height: 5))     // tile (1,1)
        let diff = TileDiff.between(before: beforeSurface, after: afterSurface,
                                    layerID: layerID, candidates: [coord(0, 0)])
        #expect(diff.entries.map(\.coordinate) == [coord(0, 0)])
        #expect(diff.entries.first?.layerID == layerID)
    }

    @Test(arguments: (1...100).map { UInt64(bitPattern: 0x5EED_0000 &+ Int64($0)) })
    func applyRevertIdentity(seed: UInt64) throws {
        var rng = SeededRandom(seed: seed)
        var image = emptyImage(600, 520)
        // Layer 1 starts opaque white so edge tiles carry real data.
        image.layers[0].surface.fill(.white)
        var oracle = ReferenceCanvas(image: image)
        // `oracle` advances to the edited state; this snapshot stays the before state.
        let beforeOracle = oracle
        var edited = image
        for _ in 0..<rng.int(in: 3...12) {
            let rect = PixelRect(
                x: rng.int(in: 0...599), y: rng.int(in: 0...519),
                width: rng.int(in: 1...300), height: rng.int(in: 1...300)
            )
            let color = ColorRGBA8(
                red: UInt8(rng.int(in: 0...255)), green: UInt8(rng.int(in: 0...255)),
                blue: UInt8(rng.int(in: 0...255)),
                alpha: [UInt8(0), 128, 255][rng.int(in: 0...2)]
            )
            fillRect(&edited, layer: 0, rect: rect, color: color, oracle: &oracle)
        }
        let diff = try fullDiff(before: image, after: edited)

        var reverted = edited
        diff.revert(&reverted)
        assertMatches(reverted, beforeOracle, "\(rng.comment): revert(on after) == before")

        var reapplied = image
        diff.apply(to: &reapplied)
        assertMatches(reapplied, oracle, "\(rng.comment): apply(on before) == after")
    }

    @Test func imageBetweenThrowsOnSizeMismatch() {
        let before = whiteImage(512, 512)
        let after = whiteImage(512, 256)
        #expect(throws: TileDiffError.canvasSizeMismatch) {
            try TileDiff.between(before: before, after: after)
        }
    }

    @Test func imageBetweenThrowsOnLayerMismatch() {
        let before = whiteImage(512, 512)

        var added = before
        added.layers.append(Layer(name: "Layer 2", surface: {
            var surface = TiledSurface(size: PixelSize(width: 512, height: 512))
            surface.fill(.white)
            return surface
        }()))
        #expect(throws: TileDiffError.layerStructureMismatch) {
            try TileDiff.between(before: before, after: added)
        }

        var twoLayers = before
        twoLayers.layers.append(Layer(name: "Layer 2", surface: {
            var surface = TiledSurface(size: PixelSize(width: 512, height: 512))
            surface.fill(.white)
            return surface
        }()))
        twoLayers.activeLayerIndex = 1
        var reordered = twoLayers
        reordered.layers.swapAt(0, 1)
        #expect(throws: TileDiffError.layerStructureMismatch) {
            try TileDiff.between(before: twoLayers, after: reordered)
        }
    }

    @Test func imageBetweenOrdersByLayer() throws {
        var before = whiteImage(512, 512)
        before.layers.append(Layer(name: "Layer 2", surface: {
            var surface = TiledSurface(size: PixelSize(width: 512, height: 512))
            surface.fill(.white)
            return surface
        }()))
        var after = before
        let layer0ID = try #require(before.layers.first?.id)
        let layer1ID = try #require(before.layers.last?.id)
        fillRect(&after, layer: 1, rect: PixelRect(x: 10, y: 10, width: 5, height: 5),
                 color: .black)
        fillRect(&after, layer: 0, rect: PixelRect(x: 20, y: 20, width: 5, height: 5),
                 color: .black)
        let diff = try fullDiff(before: before, after: after)
        #expect(diff.entries.count == 2)
        #expect(diff.entries.map(\.layerID) == [layer0ID, layer1ID],
                "entries are ordered by layer (image order), then row, then column")
    }

    @Test func imageBetweenCandidatesDictionaryLimitsPerLayer() throws {
        var before = whiteImage(512, 512)
        before.layers.append(Layer(name: "Layer 2", surface: {
            var surface = TiledSurface(size: PixelSize(width: 512, height: 512))
            surface.fill(.white)
            return surface
        }()))
        var after = before
        let layer0ID = try #require(before.layers.first?.id)
        let layer1ID = try #require(before.layers.last?.id)
        fillRect(&after, layer: 0, rect: PixelRect(x: 10, y: 10, width: 5, height: 5),
                 color: .black)
        fillRect(&after, layer: 1, rect: PixelRect(x: 300, y: 300, width: 5, height: 5),
                 color: .black)
        // Only layer 0 gets candidates; layer 1's absence from the dictionary means "no
        // candidates for that layer".
        let diff = try TileDiff.between(before: before, after: after,
                                        candidates: [layer0ID: [coord(0, 0)]])
        #expect(diff.entries.count == 1)
        #expect(diff.entries.first?.layerID == layer0ID)

        // An explicit empty set for layer 0 records nothing at all.
        let none = try TileDiff.between(before: before, after: after,
                                        candidates: [layer0ID: [], layer1ID: []])
        #expect(none.isEmpty)

        // The nil dictionary scans every tile of both layers.
        let all = try TileDiff.between(before: before, after: after, candidates: nil)
        #expect(Set(all.entries.map(\.layerID)) == [layer0ID, layer1ID])
    }

    @Test func transparentAndSemiTransparentPixelsRoundTripExactly() throws {
        // RGB under alpha 0 is preserved byte for byte (straight alpha, rule 4).
        let before = emptyImage(512, 512)
        var after = before
        let odd = ColorRGBA8(red: 12, green: 200, blue: 7, alpha: 0)
        let semi = ColorRGBA8(red: 3, green: 60, blue: 240, alpha: 128)
        fillRect(&after, layer: 0, rect: PixelRect(x: 5, y: 5, width: 4, height: 4), color: odd)
        fillRect(&after, layer: 0, rect: PixelRect(x: 20, y: 5, width: 4, height: 4), color: semi)
        let diff = try fullDiff(before: before, after: after)
        #expect(diff.entries.count == 1, "both rects sit in tile (0,0)")

        var restored = after
        diff.revert(&restored)
        #expect(restored.layers[0].surface.pixel(at: PixelPoint(x: 5, y: 5)) == .clear)
        diff.apply(to: &restored)
        #expect(restored.layers[0].surface.pixel(at: PixelPoint(x: 5, y: 5)) == odd,
                "RGB under alpha 0 survives the round trip")
        #expect(restored.layers[0].surface.pixel(at: PixelPoint(x: 20, y: 5)) == semi)
    }
}
