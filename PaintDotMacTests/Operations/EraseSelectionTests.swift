import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `EraseSelection` (spec 0018; E-4, D-27, D-45, H-6, NF-4): the pixel formula (proved
/// against `EraseOps` and the closed form for all 65,536 `(a, m)` pairs), the tile
/// algorithm (full-tile fast path, partial edges, unallocated skips, tile release), the
/// deselect semantics, and the H-6 no-op rules. Expected values are hand-computed from
/// the spec formulas — independent oracles.
struct EraseSelectionTests {
    private let size100 = PixelSize(width: 100, height: 100)

    private func opaque(_ color: ColorRGBA8, width: Int, height: Int) -> TiledSurface {
        var surface = TiledSurface(size: PixelSize(width: width, height: height))
        surface.fill(color)
        return surface
    }

    private func state(_ surface: TiledSurface, selection: Selection? = nil,
                       layers: [Layer]? = nil) -> DocumentState {
        let image: LayeredImage
        if let layers {
            image = LayeredImage(size: surface.size, layers: layers, activeLayerIndex: 1)
        } else {
            image = LayeredImage(surface: surface)
        }
        return DocumentState(image: image, selection: selection)
    }

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double,
                      canvas: PixelSize) -> Selection {
        Selection(rect: CGRect(x: x, y: y, width: w, height: h), canvasSize: canvas)!
    }

    // MARK: - Pixel formula

    @Test func pixelFormulaExhaustive() {
        for a in UInt8.min...UInt8.max {
            for m in UInt8.min...UInt8.max {
                let p = ColorRGBA8(red: 200, green: 100, blue: 50, alpha: a)
                let expected: ColorRGBA8
                if m == 0 {
                    expected = p
                } else {
                    let n = (Int(a) * (255 - Int(m)) + 127) / 255
                    expected = n == 0
                        ? ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0)
                        : ColorRGBA8(red: 200, green: 100, blue: 50, alpha: UInt8(n))
                }
                #expect(EraseSelection.erasePixel(p, coverage: m) == expected,
                        "a=\(a) m=\(m)")
                // The closed form is round-half-up of `a·(1 − m/255)` with no ties.
                let n = (Int(a) * (255 - Int(m)) + 127) / 255
                #expect(Int((Double(a) * Double(255 - Int(m)) / 255).rounded()) == n,
                        "no ties: a=\(a) m=\(m)")
            }
        }
    }

    @Test func matchesEraseOps() {
        for rgb in [(UInt8(200), UInt8(100), UInt8(50)), (UInt8(255), UInt8(255), UInt8(255)),
                    (UInt8(1), UInt8(128), UInt8(254))] {
            for a in UInt8.min...UInt8.max {
                for m in UInt8.min...UInt8.max {
                    let p = ColorRGBA8(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: a)
                    #expect(EraseSelection.erasePixel(p, coverage: m)
                                == EraseOps.erase(p, strength: 255, coverage: m),
                            "p=\(p) m=\(m)")
                }
            }
        }
    }

    @Test func handValues() {
        // All hand-computed from `newA = (a·(255 − m) + 127) / 255`.
        #expect(EraseSelection.erasePixel(.white, coverage: 128)
                    == ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 127),
                "(255·127 + 127)/255 = 127")
        #expect(EraseSelection.erasePixel(ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 200),
                                          coverage: 64)
                    == ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 150),
                "x = 200·191 = 38,200; (38,200 + 127)/255 = 150")
        #expect(EraseSelection.erasePixel(ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 1),
                                          coverage: 128) == .clear,
                "(127 + 127)/255 = 0 → transparent black")
        #expect(EraseSelection.erasePixel(ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 1),
                                          coverage: 127)
                    == ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 1),
                "(128 + 127)/255 = 0 is 255/255 = 1")
        for a in UInt8.min...UInt8.max {
            let rgb: UInt8 = a == 0 ? 7 : 13   // even a colored transparent pixel → clear
            #expect(EraseSelection.erasePixel(ColorRGBA8(red: rgb, green: rgb, blue: rgb, alpha: a),
                                              coverage: 255) == .clear,
                    "m = 255 erases fully")
        }
        for m in UInt8.min...UInt8.max {
            #expect(EraseSelection.erasePixel(.clear, coverage: m) == .clear, "m=\(m)")
        }
    }

    // MARK: - Tile algorithm

    @Test func rectSelectionErasesInside() {
        let surface = opaque(.white, width: 300, height: 300)
        let selection = rect(40, 20, 100, 50, canvas: PixelSize(width: 300, height: 300))
        let (erased, touched) = EraseSelection.erase(surface, mask: selection.mask)
        #expect(touched == [TileCoordinate(column: 0, row: 0)], "one tile is partially covered")
        TestImages.expectPixels(erased) { x, y in
            (40..<140).contains(x) && (20..<70).contains(y) ? .clear : .white
        }
    }

    @Test func antialiasedEdgeHandValues() {
        // 0013 rasterizes rect (10.5, 0, 2, 64) with columns 10 and 12 at coverage 128
        // and column 11 at 255. a = 255: (255·127 + 127)/255 = 127.
        let surface = opaque(ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 255),
                             width: 64, height: 64)
        let selection = rect(10.5, 0, 2, 64, canvas: PixelSize(width: 64, height: 64))
        let (erased, _) = EraseSelection.erase(surface, mask: selection.mask)
        let edge = ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 127)
        for y in 0..<64 {
            #expect(erased.pixel(at: PixelPoint(x: 10, y: y)) == edge, "column 10 (m = 128)")
            #expect(erased.pixel(at: PixelPoint(x: 11, y: y)) == .clear, "column 11 (m = 255)")
            #expect(erased.pixel(at: PixelPoint(x: 12, y: y)) == edge, "column 12 (m = 128)")
            #expect(erased.pixel(at: PixelPoint(x: 9, y: y))
                        == ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 255), "column 9")
            #expect(erased.pixel(at: PixelPoint(x: 13, y: y))
                        == ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 255), "column 13")
        }
    }

    @Test func crossTileRect() {
        let surface = opaque(.white, width: 600, height: 600)
        let selection = rect(200, 200, 200, 200, canvas: PixelSize(width: 600, height: 600))
        let (erased, touched) = EraseSelection.erase(surface, mask: selection.mask)
        #expect(touched == [TileCoordinate(column: 0, row: 0), TileCoordinate(column: 1, row: 0),
                            TileCoordinate(column: 0, row: 1), TileCoordinate(column: 1, row: 1)])
        TestImages.expectPixels(erased) { x, y in
            (200..<400).contains(x) && (200..<400).contains(y) ? .clear : .white
        }
    }

    @Test func fullTileFastPath() throws {
        let surface = opaque(.white, width: 1024, height: 256)
        let selection = rect(256, 0, 256, 256, canvas: PixelSize(width: 1024, height: 256))
        let (erased, touched) = EraseSelection.erase(surface, mask: selection.mask)
        #expect(touched == [TileCoordinate(column: 1, row: 0)])
        #expect(erased.tile(at: TileCoordinate(column: 1, row: 0)) == nil)
        for column in [0, 2, 3] {
            let coordinate = TileCoordinate(column: column, row: 0)
            let original = try #require(surface.tile(at: coordinate))
            let kept = try #require(erased.tile(at: coordinate))
            #expect(kept.sharesStorage(with: original), "untouched tiles share storage")
        }
    }

    @Test func unallocatedTilesStayUnallocated() throws {
        let surface = TiledSurface(size: PixelSize(width: 512, height: 512))
        let selection = Selection.all(canvasSize: surface.size)
        let (erased, touched) = EraseSelection.erase(surface, mask: selection.mask)
        #expect(touched.isEmpty)
        #expect(erased.allocatedTileCoordinates.isEmpty, "no allocation for erasing nothing")

        let before = state(surface, selection: selection)
        let item = try #require(EraseSelection.makeHistoryItem(for: before))
        #expect(item.name == "Erase Selection")
        var after = before
        item.apply(to: &after)
        #expect(after.selection == nil)
        #expect(after.image == before.image, "pixels unchanged — a deselect-only step")
    }

    @Test func allocatedTransparentTilesAreAnEraseNoOp() throws {
        // An allocated but fully transparent tile (before `releaseTransparentTiles` runs,
        // or restored by undo) erases to "absent", which is pixel-identical: no diff
        // entry, no byte cost — with a selection the step is the deselect, without one
        // there is no step at all (H-6). Exercises the `TileDiff` transparent-tile
        // classification through the real command.
        var surface = TiledSurface(size: PixelSize(width: 512, height: 512))
        surface.setTile(Tile(), at: TileCoordinate(column: 0, row: 0))
        surface.setTile(Tile(), at: TileCoordinate(column: 1, row: 1))
        let selection = Selection.all(canvasSize: surface.size)
        let (erased, touched) = EraseSelection.erase(surface, mask: selection.mask)
        #expect(touched == [TileCoordinate(column: 0, row: 0), TileCoordinate(column: 1, row: 1)],
                "the tiles are replaced, but the replacement equals the old pixels")
        #expect(erased.allocatedTileCoordinates.isEmpty)

        #expect(EraseSelection.makeHistoryItem(for: state(surface)) == nil,
                "transparent tiles, no selection: no step")
        let item = try #require(EraseSelection.makeHistoryItem(for: state(surface, selection: selection)))
        // Deselect-only steps merge to the degenerate `.pixelsAndSelection([:])` (0013's
        // table starts from `.pixels([:])); the empty tile set uploads nothing and
        // `affectsSelection` still refreshes the ants.
        #expect(item.change == .pixelsAndSelection([:]))
        #expect(item.change.affectsSelection)
    }

    @Test func partialTileBecomesNilWhenTransparent() {
        // Opaque pixels only where the ellipse's mask is 255 → erasing empties the tile.
        var surface = TiledSurface(size: PixelSize(width: 256, height: 256))
        surface.fill(.white, in: PixelRect(x: 64, y: 64, width: 129, height: 129))
        let ellipse = Selection(path: CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 256, height: 256),
                                             transform: nil),
                                canvasSize: PixelSize(width: 256, height: 256))!
        #expect(ellipse.mask.tile(at: TileCoordinate(column: 0, row: 0)).isPartial,
                "the ellipse leaves one partial tile")
        #expect(ellipse.mask.coverage(x: 128, y: 128) == 255)
        let (erased, touched) = EraseSelection.erase(surface, mask: ellipse.mask)
        #expect(touched == [TileCoordinate(column: 0, row: 0)])
        #expect(erased.tile(at: TileCoordinate(column: 0, row: 0)) == nil)
    }

    // MARK: - History semantics

    @Test func noSelectionErasesWholeLayer() throws {
        let surface = opaque(.white, width: 300, height: 300)
        let (erased, touched) = EraseSelection.erase(surface, mask: nil)
        #expect(erased.allocatedTileCoordinates.isEmpty, "every tile released")
        #expect(touched.count == 4)

        let live = state(surface)
        let item = try #require(EraseSelection.makeHistoryItem(for: live))
        let tiles: [Layer.ID: Set<TileCoordinate>] = [
            live.image.layers[0].id:
                [TileCoordinate(column: 0, row: 0), TileCoordinate(column: 1, row: 0),
                 TileCoordinate(column: 0, row: 1), TileCoordinate(column: 1, row: 1)],
        ]
        #expect(item.change == .pixels(tiles))
        var after = live
        item.apply(to: &after)
        #expect(after.selection == nil)
    }

    @Test func noOpWithoutSelection() {
        let surface = TiledSurface(size: PixelSize(width: 100, height: 100))
        #expect(EraseSelection.makeHistoryItem(for: state(surface)) == nil,
                "empty layer, no selection: no step (H-6)")
    }

    @Test func transparentAreaStillDeselects() throws {
        let surface = TiledSurface(size: size100)
        let selection = rect(10, 10, 30, 30, canvas: size100)
        let before = state(surface, selection: selection)
        let item = try #require(EraseSelection.makeHistoryItem(for: before))
        #expect(item.name == "Erase Selection")
        #expect(item.icon == .eraseSelection)
        var after = before
        item.apply(to: &after)
        #expect(after.selection == nil, "something changed — the deselect is a step (H-6)")
        #expect(after.image == before.image)
    }

    @Test func deselectsAndUndoRestoresBoth() throws {
        let before = opaque(.white, width: 300, height: 300)
        let selection = rect(40, 20, 100, 50, canvas: PixelSize(width: 300, height: 300))
        var stack = HistoryStack(base: .newImage)
        var live = state(before, selection: selection)
        let item = try #require(EraseSelection.makeHistoryItem(for: live))
        _ = stack.perform(item, on: &live)

        TestImages.expectPixels(live.image.layers[0].surface) { x, y in
            (40..<140).contains(x) && (20..<70).contains(y) ? .clear : .white
        }
        #expect(live.selection == nil, "Erase Selection deselects (EditMenu.html)")
        #expect(item.change == .pixelsAndSelection([live.image.layers[0].id: [TileCoordinate(column: 0, row: 0)]]))

        _ = stack.undo(&live)
        #expect(live.image.layers[0].surface == before, "pixels restored")
        #expect(live.selection == selection, "the selection returns in the same step")
        for coordinate in [TileCoordinate(column: 0, row: 1), TileCoordinate(column: 1, row: 0),
                           TileCoordinate(column: 1, row: 1)] {
            let original = try #require(before.tile(at: coordinate))
            let kept = try #require(live.image.layers[0].surface.tile(at: coordinate))
            #expect(kept.sharesStorage(with: original), "untouched tiles keep their storage")
        }
        _ = stack.redo(&live)
        #expect(live.selection == nil)
        #expect(live.image.layers[0].surface.pixel(at: PixelPoint(x: 100, y: 40)) == .clear)
    }

    @Test func otherLayersUntouched() throws {
        let bottom = opaque(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255), width: 100, height: 100)
        let top = opaque(.white, width: 100, height: 100)
        let layers = [Layer(name: "Bottom", surface: bottom),
                      Layer(name: "Top", surface: top)]
        let selection = rect(10, 10, 30, 30, canvas: size100)
        var live = state(top, selection: selection, layers: layers)
        let item = try #require(EraseSelection.makeHistoryItem(for: live))
        item.apply(to: &live)
        #expect(live.image.activeLayerIndex == 1)
        for coordinate in bottom.allocatedTileCoordinates {
            let original = try #require(bottom.tile(at: coordinate))
            let kept = try #require(live.image.layers[0].surface.tile(at: coordinate))
            #expect(kept.sharesStorage(with: original),
                    "the inactive layer's tiles are never rewritten")
        }
        #expect(live.image.layers[1].surface.pixel(at: PixelPoint(x: 15, y: 15)) == .clear)
        item.revert(&live)
        #expect(live.image.activeLayerIndex == 1, "undo never switches layers (H-6)")
        #expect(live.image.layers[1].surface == top)
    }

    @Test func hiddenLayerStillErased() throws {
        var layer = Layer(name: "Hidden", surface: opaque(.white, width: 100, height: 100))
        layer.isVisible = false
        let image = LayeredImage(size: size100, layers: [layer], activeLayerIndex: 0)
        var live = DocumentState(image: image, selection: rect(10, 10, 30, 30, canvas: size100))
        let item = try #require(EraseSelection.makeHistoryItem(for: live))
        item.apply(to: &live)
        #expect(live.image.layers[0].surface.pixel(at: PixelPoint(x: 15, y: 15)) == .clear,
                "Paint.NET acts on the active layer regardless of visibility")
    }

    @Test func onePixelImage() throws {
        let surface = opaque(.white, width: 1, height: 1)
        let (erased, touched) = EraseSelection.erase(surface, mask: Selection.all(canvasSize: PixelSize(width: 1, height: 1)).mask)
        #expect(erased.tile(at: TileCoordinate(column: 0, row: 0)) == nil)
        #expect(erased.pixel(at: PixelPoint(x: 0, y: 0)) == .clear)
        #expect(touched == [TileCoordinate(column: 0, row: 0)])
    }

    @Test func wideStripReleasesTiles() {
        let surface = opaque(.white, width: 65_535, height: 1)
        let (erased, touched) = EraseSelection.erase(surface, mask: nil)
        #expect(touched.count == 256)
        #expect(erased.allocatedTileCoordinates.isEmpty,
                "Select All erases the 65,535×1 strip through the full-tile fast path")
    }

    // MARK: - Cost and enablement

    @Test func byteCostFullLayer() throws {
        let size = PixelSize(width: 4000, height: 3000)
        let surface = opaque(.white, width: 4000, height: 3000)
        let all = Selection.all(canvasSize: size)
        let item = try #require(EraseSelection.makeHistoryItem(for: state(surface, selection: all)))
        // 192 before-tiles (every `after` is `nil`) + 0013's selection bytes for Select
        // All → nil (the path estimate; full mask tiles cost nothing).
        let expected = 192 * Tile.byteCount + HistoryCost.selectionBytes(before: all, after: nil)
        #expect(item.byteCost == expected)
    }

    @Test func alwaysEnabled() {
        let surface = opaque(.white, width: 10, height: 10)
        #expect(EraseSelection.isEnabled(in: state(surface)))
        #expect(EraseSelection.isEnabled(in: state(surface, selection: .all(canvasSize: PixelSize(width: 10, height: 10)))))
    }
}

private extension SelectionMaskTile {
    var isPartial: Bool {
        if case .partial = self { return true }
        return false
    }
}
