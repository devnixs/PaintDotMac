import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `FloatingPixels` against `DocumentState` fixtures (spec 0020 *Test plan*): 8×8 opaque
/// layer `L(x, y) = (x·30, y·30, 100, 255)`, rect selection (2, 2, 3, 3) unless stated,
/// sessions moved with 0019's `translatedBy`/`applying`.
struct FloatingPixelsTests {
    private func l(_ x: Int, _ y: Int) -> ColorRGBA8 {
        ColorRGBA8(red: UInt8((30 * x) % 256), green: UInt8((30 * y) % 256), blue: 100, alpha: 255)
    }

    private func layerImage(width: Int = 8, height: Int = 8,
                            fill: (Int, Int) -> ColorRGBA8 = { x, y in ColorRGBA8(red: UInt8((30 * x) % 256), green: UInt8((30 * y) % 256), blue: 100, alpha: 255) },
                            isVisible: Bool = true) -> LayeredImage {
        var surface = TiledSurface(size: PixelSize(width: width, height: height))
        for y in 0..<height {
            for x in 0..<width {
                surface.setPixel(fill(x, y), at: PixelPoint(x: x, y: y))
            }
        }
        var image = LayeredImage(surface: surface)
        image.layers[0].isVisible = isVisible
        return image
    }

    private func selection(_ rect: CGRect, in size: PixelSize = PixelSize(width: 8, height: 8))
        throws -> Selection
    {
        try #require(Selection(rect: rect, canvasSize: size))
    }

    private func state(rect: CGRect = CGRect(x: 2, y: 2, width: 3, height: 3),
                       width: Int = 8, height: Int = 8, isVisible: Bool = true,
                       selection: Selection? = nil) throws -> DocumentState {
        let image = layerImage(width: width, height: height, isVisible: isVisible)
        let selection = try selection
            ?? self.selection(rect, in: image.size)
        return DocumentState(image: image, selection: selection)
    }

    private func lifted(duplicate: Bool = false,
                        rect: CGRect = CGRect(x: 2, y: 2, width: 3, height: 3),
                        width: Int = 8, height: Int = 8, isVisible: Bool = true) throws
        -> (FloatingPixels, DocumentState)
    {
        let state = try state(rect: rect, width: width, height: height, isVisible: isVisible)
        let floating = try #require(FloatingPixels.lift(from: state, duplicate: duplicate,
                                                        baseStepID: 0))
        return (floating, state)
    }

    private func bytes(_ surface: TiledSurface, _ rect: PixelRect) -> [UInt8] {
        surface.readPixels(in: rect)
    }

    // MARK: - Lift

    @Test func liftPunchesHole() throws {
        // A 600 × 600 layer so "outside the rect" can also check tile storage.
        let (floating, state) = try lifted(width: 600, height: 600)
        let rect = PixelRect(x: 2, y: 2, width: 3, height: 3)
        let layer = state.image.layers[0].surface
        // Source == L over the rect.
        #expect(floating.sourceRect == rect)
        #expect(bytes(floating.source, PixelRect(origin: .zero, size: rect.size))
                    == bytes(layer, rect))
        // Underlay: the rect is fully transparent, everything else byte-equal.
        for y in 2..<5 {
            for x in 2..<5 {
                #expect(floating.underlay.pixel(at: PixelPoint(x: x, y: y)) == .clear,
                        "hole at (\(x), \(y))")
            }
        }
        for y in [0, 1, 5, 599] {
            #expect(floating.underlay.readPixels(in: PixelRect(x: 0, y: y, width: 600, height: 1))
                        == layer.readPixels(in: PixelRect(x: 0, y: y, width: 600, height: 1)),
                    "row \(y) unchanged")
        }
        // Tiles that do not touch `sourceRect` share storage (CoW — NF-4); only the
        // holed tile is a copy.
        for column in 0..<3 {
            for row in 0..<3 {
                let coordinate = TileCoordinate(column: column, row: row)
                guard let a = floating.underlay.tile(at: coordinate),
                      let b = layer.tile(at: coordinate) else { continue }
                if column != 0 || row != 0 {
                    #expect(a.sharesStorage(with: b), "tile (\(column), \(row)) shared")
                } else {
                    #expect(!a.sharesStorage(with: b), "the holed tile is a copy")
                }
            }
        }
        // The lift itself mutates nothing: the state's layer is untouched.
        #expect(state.image.layers[0].surface == layer)
        let outline = try #require(floating.outline)
        #expect(outline == state.selection)
        #expect(floating.session.integerTranslation?.dx == 0
                    && floating.session.integerTranslation?.dy == 0)
        #expect(floating.restore.layerSurface == layer)
        #expect(floating.restore.selection == state.selection)
        #expect(floating.restore.baseStepID == 0)
    }

    @Test func liftAntialiasedEdges() throws {
        // Coverage 128 at (2, 2), 255 elsewhere inside the rect (2, 2, 3, 3).
        let mask = SelectionMask(size: PixelSize(width: 8, height: 8)) { x, y in
            (2...4).contains(x) && (2...4).contains(y) ? (x == 2 && y == 2 ? 128 : 255) : 0
        }
        let outline = CGPath(rect: CGRect(x: 2, y: 2, width: 3, height: 3), transform: nil)
        let selection = try #require(Selection(mask: mask, outline: outline))
        let state = DocumentState(image: layerImage(), selection: selection)
        let floating = try #require(FloatingPixels.lift(from: state, duplicate: false,
                                                        baseStepID: 0))
        // source alpha = mul255(255, 128) = 128; underlay alpha = mul255(255, 127) = 127;
        // colours unchanged.
        let sourcePixel = floating.source.pixel(at: PixelPoint(x: 0, y: 0))
        #expect(sourcePixel == ColorRGBA8(red: 60, green: 60, blue: 100, alpha: 128))
        let underlayPixel = floating.underlay.pixel(at: PixelPoint(x: 2, y: 2))
        #expect(underlayPixel == ColorRGBA8(red: 60, green: 60, blue: 100, alpha: 127))
        // Full coverage: source keeps the pixel, underlay is fully transparent (D-27).
        #expect(floating.source.pixel(at: PixelPoint(x: 1, y: 0))
                    == ColorRGBA8(red: 90, green: 60, blue: 100, alpha: 255))
        #expect(floating.underlay.pixel(at: PixelPoint(x: 3, y: 2)) == .clear)
    }

    @Test func liftWithoutSelectionReturnsNil() throws {
        let state = DocumentState(image: layerImage(), selection: nil)
        #expect(FloatingPixels.lift(from: state, duplicate: false, baseStepID: 0) == nil)
    }

    @Test func duplicateKeepsOriginal() throws {
        let (floating, state) = try lifted(duplicate: true)
        let layer = state.image.layers[0].surface
        #expect(floating.underlay == layer)
        // Shared storage — the duplicate does not copy the layer.
        let coordinate = TileCoordinate(column: 0, row: 0)
        #expect(floating.underlay.tile(at: coordinate)!.sharesStorage(with: layer.tile(at: coordinate)!))
    }

    @Test func liftTransparentArea() throws {
        let image = layerImage(fill: { _, _ in .clear })
        let selection = try selection(CGRect(x: 2, y: 2, width: 3, height: 3), in: image.size)
        let floating = try #require(FloatingPixels.lift(
            from: DocumentState(image: image, selection: selection),
            duplicate: false, baseStepID: 0))
        // The lift is allowed; the source is fully transparent, the outline still rides.
        #expect(floating.source.allocatedTileCount == 0)
        #expect(floating.underlay == image.layers[0].surface)
        #expect(floating.outline?.bounds == PixelRect(x: 2, y: 2, width: 3, height: 3))
    }

    @Test func hiddenLayerStillMoves() throws {
        let (floating, state) = try lifted(isVisible: false)
        // Visibility is the compositor's business — the lift sees the pixels.
        #expect(bytes(floating.source, PixelRect(origin: .zero, size: floating.sourceRect.size))
                    == bytes(state.image.layers[0].surface, floating.sourceRect))
    }

    // MARK: - Render

    @Test func renderIdentityMatchesOriginalForHardSelection() throws {
        let (floating, state) = try lifted()
        #expect(floating.resamplingMode == .nearestNeighbor, "identity is integer")
        var surface = state.image.layers[0].surface
        floating.render(into: &surface, region: state.image.size.bounds)
        #expect(surface == state.image.layers[0].surface, "identity render writes exactly L")
    }

    @Test func moveAndBackIsIdentity() throws {
        let (base, state) = try lifted()
        var floating = base
        floating.session = base.session.translatedBy(dx: 4, dy: 0)
        #expect(floating.resamplingMode == .nearestNeighbor)
        var surface = state.image.layers[0].surface
        let region = base.destinationBounds.union(floating.destinationBounds)
            .union(base.sourceRect)
        floating.render(into: &surface, region: region)
        // Columns 6–7 rows 2–4 carry source columns 2–3 (column 8 is clipped away).
        for row in 2...4 {
            #expect(surface.pixel(at: PixelPoint(x: 6, y: row)) == l(2, row))
            #expect(surface.pixel(at: PixelPoint(x: 7, y: row)) == l(3, row))
        }
        // The vacated rect is clear.
        for point in [PixelPoint(x: 2, y: 2), PixelPoint(x: 4, y: 2), PixelPoint(x: 3, y: 4)] {
            #expect(surface.pixel(at: point) == .clear, "hole at \(point)")
        }
        // Everything outside both rects is unchanged.
        for x in 5...7 {
            #expect(surface.pixel(at: PixelPoint(x: x, y: 6)) == l(x, 6))
        }
        #expect(surface.pixel(at: PixelPoint(x: 0, y: 0)) == l(0, 0))

        // Back by (−4, 0) → byte-identical to L.
        floating.session = floating.session.translatedBy(dx: -4, dy: 0)
        floating.render(into: &surface, region: region)
        #expect(surface == state.image.layers[0].surface, "round trip is exact")
    }

    @MainActor
    @Test func offCanvasPixelsSurvive() throws {
        let (base, state) = try lifted()
        var floating = base
        floating.session = base.session.translatedBy(dx: 20, dy: 0)  // wholly off-canvas
        #expect(floating.destinationBounds.isEmpty)
        #expect(floating.transformedSelection(antialiased: true) == nil,
                "nothing remains → ants hidden (handles still drawn from the session)")
        var surface = state.image.layers[0].surface
        floating.render(into: &surface, region: base.sourceRect)
        // Only the hole remains…
        #expect(surface.pixel(at: PixelPoint(x: 2, y: 2)) == .clear)
        // …and moving back restores the pixels exactly (source was never clipped).
        floating.session = floating.session.translatedBy(dx: -20, dy: 0)
        floating.render(into: &surface, region: state.image.size.bounds)
        #expect(surface == state.image.layers[0].surface)
    }

    @Test func finishOffCanvasDropsPixels() throws {
        let (base, state) = try lifted()
        var floating = base
        floating.session = base.session.translatedBy(dx: 20, dy: 0)
        var surface = state.image.layers[0].surface
        floating.render(into: &surface, region: base.sourceRect)
        // The finished layer keeps only the hole — the off-canvas pixels are dropped.
        for y in 0..<8 {
            for x in 0..<8 {
                let expected = base.sourceRect.contains(PixelPoint(x: x, y: y))
                    ? ColorRGBA8.clear : l(x, y)
                #expect(surface.pixel(at: PixelPoint(x: x, y: y)) == expected, "(\(x), \(y))")
            }
        }
    }

    @MainActor
    @Test func selectionFollowsPixels() throws {
        let (base, _) = try lifted()
        var floating = base
        floating.session = base.session.translatedBy(dx: 1, dy: 2)
        let moved = try #require(floating.transformedSelection(antialiased: true))
        let expected = try selection(CGRect(x: 3, y: 4, width: 3, height: 3))
        #expect(moved.mask == expected.mask, "integer path → exact mask shift")
        #expect(moved.bounds == PixelRect(x: 3, y: 4, width: 3, height: 3))
    }

    @Test func crossTileMove() throws {
        // 300 × 300 (2×2 tiles), selection (250, 250, 20, 20) moved (+10, +10): writes
        // only the four tiles around the (256, 256) corner, pixels exact.
        let (base, state) = try lifted(rect: CGRect(x: 250, y: 250, width: 20, height: 20),
                                       width: 300, height: 300)
        let before = state.image.layers[0].surface
        var floating = base
        floating.session = base.session.translatedBy(dx: 10, dy: 10)
        var surface = before
        let region = base.destinationBounds.union(floating.destinationBounds)
            .union(base.sourceRect.intersection(before.bounds))
        floating.render(into: &surface, region: region)
        // Writes are confined: pixels outside the hole and the destination are exact.
        #expect(surface.pixel(at: PixelPoint(x: 249, y: 249)) == l(249, 249))
        #expect(surface.pixel(at: PixelPoint(x: 279, y: 250)) == l(279, 250))
        #expect(surface.pixel(at: PixelPoint(x: 250, y: 279)) == l(250, 279))
        #expect(surface.pixel(at: PixelPoint(x: 299, y: 299)) == l(299, 299))
        // Destination pixels exact, source hole exact, far corner untouched.
        #expect(surface.pixel(at: PixelPoint(x: 260, y: 260)) == l(250, 250))
        #expect(surface.pixel(at: PixelPoint(x: 269, y: 269)) == l(259, 259))
        #expect(surface.pixel(at: PixelPoint(x: 250, y: 250)) == .clear)
        #expect(surface.pixel(at: PixelPoint(x: 264, y: 264)) == l(254, 254),
                "destination overlaps the hole: the moved pixel wins")
        #expect(surface.pixel(at: PixelPoint(x: 299, y: 0)) == l(299, 0))
    }

    @Test func onePixel() throws {
        // 1 × 1 image / 1 × 1 selection: lift, move off and back, rotate 90° → exact.
        let image = layerImage(width: 1, height: 1)
        let selection = try selection(CGRect(x: 0, y: 0, width: 1, height: 1),
                                      in: PixelSize(width: 1, height: 1))
        let floating = try #require(FloatingPixels.lift(
            from: DocumentState(image: image, selection: selection),
            duplicate: false, baseStepID: 0))
        var moved = floating
        moved.session = floating.session.translatedBy(dx: 5, dy: 5)
        var surface = image.layers[0].surface
        moved.render(into: &surface, region: floating.sourceRect)
        #expect(surface.pixel(at: .zero) == .clear, "moved off")
        moved.session = floating.session
        moved.render(into: &surface, region: floating.sourceRect)
        #expect(surface.pixel(at: .zero) == l(0, 0))
        // 90° about the single pixel centre (a rotate gesture, exactly quarter-turn
        // endpoints): the sampled centre maps to itself → exact.
        var turned = floating
        turned.session = floating.session.applying(
            .rotate, from: CGPoint(x: 10.5, y: 0.5), to: CGPoint(x: 0.5, y: 10.5),
            modifiers: [])
        turned.render(into: &surface, region: floating.sourceRect)
        #expect(surface.pixel(at: .zero) == l(0, 0))
    }

    // MARK: - Paste factory (0021's input)

    @Test func pasteFactory() throws {
        var clipboard = TiledSurface(size: PixelSize(width: 3, height: 3))
        for y in 0..<3 {
            for x in 0..<3 {
                clipboard.setPixel(ColorRGBA8(red: UInt8(x * 9), green: UInt8(y * 7), blue: 200),
                                   at: PixelPoint(x: x, y: y))
            }
        }
        let state = try state()
        let floating = FloatingPixels.paste(clipboard, at: PixelPoint(x: -1, y: -1),
                                            into: state, baseStepID: 0)
        #expect(floating.sourceRect == PixelRect(x: -1, y: -1, width: 3, height: 3))
        #expect(floating.underlay == state.image.layers[0].surface)
        let outline = try #require(floating.outline)
        let expected = try selection(CGRect(x: 0, y: 0, width: 2, height: 2))
        #expect(outline.mask == expected.mask, "outline clipped to the visible 2 × 2")
        // Identity render writes exactly the visible 2×2 part (opaque → exact).
        var surface = state.image.layers[0].surface
        floating.render(into: &surface, region: state.image.size.bounds)
        #expect(surface.pixel(at: PixelPoint(x: 0, y: 0))
                    == ColorRGBA8(red: 9, green: 7, blue: 200))
        #expect(surface.pixel(at: PixelPoint(x: 1, y: 1))
                    == ColorRGBA8(red: 18, green: 14, blue: 200))
        #expect(surface.pixel(at: PixelPoint(x: 2, y: 2)) == l(2, 2), "past the paste: untouched")
    }

    /// A fully off-canvas paste has no outline (`nil`) per the spec.
    @Test func pasteFullyOffCanvas() throws {
        let clipboard = TiledSurface(size: PixelSize(width: 2, height: 2))
        let state = try state()
        let floating = FloatingPixels.paste(clipboard, at: PixelPoint(x: 50, y: 50),
                                            into: state, baseStepID: 0)
        #expect(floating.outline == nil)
        #expect(floating.destinationBounds.isEmpty)
    }
}
