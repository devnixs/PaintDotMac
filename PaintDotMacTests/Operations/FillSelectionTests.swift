import Foundation
import Testing

@testable import PaintDotMac

/// `FillSelection` (spec 0018; E-4, D-45(b), H-6, NF-4): the overwrite pixel formula
/// (hand values, a `Double` reference oracle, the erase equivalence for alpha 0, and
/// alpha bounds), the shared-tile fill algorithm (storage sharing, edge-tile padding,
/// tile release for transparent colors), and the H-6 no-op rule. Expected values are
/// hand-computed from the spec formulas — independent oracles.
struct FillSelectionTests {
    private func opaque(_ color: ColorRGBA8, width: Int, height: Int) -> TiledSurface {
        var surface = TiledSurface(size: PixelSize(width: width, height: height))
        surface.fill(color)
        return surface
    }

    private func state(_ surface: TiledSurface, selection: Selection? = nil) -> DocumentState {
        DocumentState(image: LayeredImage(surface: surface), selection: selection)
    }

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double,
                      canvas: PixelSize) -> Selection {
        Selection(rect: CGRect(x: x, y: y, width: w, height: h), canvasSize: canvas)!
    }

    private let blue = ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255)
    private let azure = ColorRGBA8(red: 0, green: 128, blue: 255, alpha: 255)

    // MARK: - Pixel formula

    @Test func handValues() {
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        // p white opaque, color red: m 255 → the color itself; m 0 → white.
        #expect(FillSelection.fillPixel(.white, color: red, coverage: 255) == red)
        #expect(FillSelection.fillPixel(.white, color: red, coverage: 0) == .white)
        // m 128: wD = 255·127 = 32,385, wC = 255·128 = 32,640, sum = 65,025,
        // outA = 255, r = 255, g = b = (255·32,385 + 32,512)/65,025 = 127.
        #expect(FillSelection.fillPixel(.white, color: red, coverage: 128)
                    == ColorRGBA8(red: 255, green: 127, blue: 127, alpha: 255))
        // p clear, color (10,20,30,200), m 100: wC = 20,000, outA = (20,000+127)/255 = 78,
        // channels exact → (10,20,30,78).
        #expect(FillSelection.fillPixel(.clear,
                                        color: ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 200),
                                        coverage: 100)
                    == ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 78))
        // Overwrite, not blend: opaque blue + (255,0,0,128) at m 255 → that color exactly.
        #expect(FillSelection.fillPixel(blue, color: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 128),
                                        coverage: 255)
                    == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 128))
        // Any p at m 0 stays bit-for-bit, including a colored transparent pixel.
        let ghost = ColorRGBA8(red: 9, green: 8, blue: 7, alpha: 0)
        #expect(FillSelection.fillPixel(ghost, color: red, coverage: 0) == ghost)
    }

    @Test func edgeOverSemiTransparentHandValues() {
        // p = (0,0,255,100), color red, m 128: wD = 100·127 = 12,700, wC = 255·128 = 32,640,
        // sum = 45,340; outA = (45,340+127)/255 = 178;
        // r = (255·32,640 + 22,670)/45,340 = 184; g = 22,670/45,340 = 0;
        // b = (255·12,700 + 22,670)/45,340 = 71.
        let out = FillSelection.fillPixel(ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 100),
                                          color: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255),
                                          coverage: 128)
        #expect(out == ColorRGBA8(red: 184, green: 0, blue: 71, alpha: 178))
    }

    /// The integer rule against an independent `Double` reference:
    /// `outA = round(Da·(1−f) + Ca·f)`, `ch = round((Dc·Da(1−f) + Cc·Ca·f) / (Da(1−f) + Ca·f))`
    /// with `f = m/255`; alpha exact, channels exact — ±1 only where the reference
    /// quotient sits at an exact half (`Double` cannot resolve which way an exact tie
    /// rounds; every other quotient is ≥ 1⁄(2·sum) ≈ 7.7 µ away from a half, far outside
    /// the reference's ~1e-12 rounding error, so anything else must match to the byte).
    @Test func pixelFormulaReference() {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0018_F115_0000_0001))
        for _ in 0..<20_000 {
            let p = rng.color()
            let color = rng.color()
            let m = UInt8(truncatingIfNeeded: rng.int(in: 0...255))
            let got = FillSelection.fillPixel(p, color: color, coverage: m)
            guard m != 0 else {
                #expect(got == p, "m 0 is a no-op: p=\(p) — \(rng.comment)")
                continue
            }
            let f = Double(m) / 255
            let wD = Double(p.alpha) * (1 - f)
            let wC = Double(color.alpha) * f
            let sum = wD + wC
            let outA = Int(sum.rounded())
            #expect(Int(got.alpha) == outA, "alpha exact: p=\(p) c=\(color) m=\(m) — \(rng.comment)")
            if outA == 0 {
                #expect(got == .clear, "p=\(p) c=\(color) m=\(m) — \(rng.comment)")
                continue
            }
            func check(_ gotChannel: UInt8, _ dest: UInt8, _ src: UInt8, _ name: String) {
                let q = (Double(dest) * wD + Double(src) * wC) / sum
                let expected = UInt8(min(255, q.rounded()))
                let nearTie = abs((q - q.rounded(.towardZero)) - 0.5) < 1e-9
                #expect(abs(Int(gotChannel) - Int(expected)) <= (nearTie ? 1 : 0),
                        "\(name) p=\(p) c=\(color) m=\(m) — \(rng.comment)")
            }
            check(got.red, p.red, color.red, "red")
            check(got.green, p.green, color.green, "green")
            check(got.blue, p.blue, color.blue, "blue")
        }
    }

    @Test func roundingBoundaryIsExact() {
        // The channel rule's `sum / 2` bias is round-half-up, and no pair of
        // (p, color, m) produces an exact .5 quotient — the closest are the
        // r = (sum−1)/2 / r = (sum+1)/2 neighbours at 0.5 ∓ 1/(2·sum). A rounding bias
        // off by ±1 flips the byte there and nowhere else nearby, so this sweep —
        // pinned below the 0.5±1e-9 near-tie window of `pixelFormulaReference` —
        // catches any half-value mutation deterministically (12+ of its triples sit
        // exactly on such a boundary). Expected = the spec's normative integer formula.
        let pRGB = (UInt8(255), UInt8(128), UInt8(7))
        let cRGB = (UInt8(13), UInt8(200), UInt8(60))
        for pa in UInt8(0)...47 {
            for ca in UInt8(0)...47 {
                for m in UInt8(1)...47 {
                    let p = ColorRGBA8(red: pRGB.0, green: pRGB.1, blue: pRGB.2, alpha: pa)
                    let color = ColorRGBA8(red: cRGB.0, green: cRGB.1, blue: cRGB.2, alpha: ca)
                    let out = FillSelection.fillPixel(p, color: color, coverage: m)
                    let wD = UInt32(pa) * (255 - UInt32(m))
                    let wC = UInt32(ca) * UInt32(m)
                    let sum = wD + wC
                    let outA = (sum + 127) / 255
                    #expect(Int(out.alpha) == Int(outA), "alpha pa=\(pa) ca=\(ca) m=\(m)")
                    if outA == 0 {
                        #expect(out == .clear, "pa=\(pa) ca=\(ca) m=\(m)")
                        continue
                    }
                    func expected(_ d: UInt8, _ c: UInt8) -> UInt8 {
                        UInt8((UInt32(d) * wD + UInt32(c) * wC + sum / 2) / sum)
                    }
                    #expect(out.red == expected(p.red, color.red), "red pa=\(pa) ca=\(ca) m=\(m)")
                    #expect(out.green == expected(p.green, color.green),
                            "green pa=\(pa) ca=\(ca) m=\(m)")
                    #expect(out.blue == expected(p.blue, color.blue),
                            "blue pa=\(pa) ca=\(ca) m=\(m)")
                }
            }
        }
    }

    @Test func transparentPrimaryEqualsEraseExhaustive() {
        for a in UInt8.min...UInt8.max {
            for m in UInt8.min...UInt8.max {
                let p = ColorRGBA8(red: 200, green: 100, blue: 50, alpha: a)
                let color = ColorRGBA8(red: 9, green: 9, blue: 9, alpha: 0)
                #expect(FillSelection.fillPixel(p, color: color, coverage: m)
                            == EraseSelection.erasePixel(p, coverage: m),
                        "alpha-0 color erases: a=\(a) m=\(m)")
            }
        }
    }

    @Test func alphaBounds() {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0018_F115_0000_0002))
        for _ in 0..<20_000 {
            let p = rng.color()
            let color = rng.color()
            let m = UInt8(truncatingIfNeeded: rng.int(in: 1...254))
            let out = FillSelection.fillPixel(p, color: color, coverage: m)
            #expect(Int(min(p.alpha, color.alpha))...Int(max(p.alpha, color.alpha)) ~= Int(out.alpha),
                    "min ≤ out ≤ max: p=\(p) c=\(color) m=\(m) — \(rng.comment)")
        }
    }

    @Test func opaqueOverOpaqueStaysOpaque() {
        for a in UInt8.min...UInt8.max {
            let p = ColorRGBA8(red: 11, green: 22, blue: 33, alpha: 255)
            let color = ColorRGBA8(red: 44, green: 55, blue: 66, alpha: a)
            for m in UInt8.min...UInt8.max {
                let out = FillSelection.fillPixel(p, color: color, coverage: m)
                #expect(out.alpha <= 255, "a=\(a) m=\(m)")
            }
            // color fully opaque, destination opaque → stays opaque.
            #expect(FillSelection.fillPixel(p, color: .white, coverage: 128).alpha == 255)
        }
    }

    // MARK: - Tile algorithm

    @Test func semiTransparentOverwrites() throws {
        // A Normal blend would leave alpha 255 and keep some blue — this proves overwrite.
        let size = PixelSize(width: 64, height: 64)
        let surface = opaque(blue, width: 64, height: 64)
        var live = state(surface, selection: .all(canvasSize: size))
        let item = try #require(FillSelection.makeHistoryItem(
            for: live, color: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 128)))
        item.apply(to: &live)
        TestImages.expectPixels(live.image.layers[0].surface) { _, _ in
            ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 128)
        }
    }

    @Test func rectSelectionFillsInside() throws {
        let surface = opaque(.white, width: 300, height: 300)
        let selection = rect(40, 20, 100, 50, canvas: PixelSize(width: 300, height: 300))
        let before = state(surface, selection: selection)
        let item = try #require(FillSelection.makeHistoryItem(for: before, color: azure))
        var after = before
        item.apply(to: &after)
        #expect(after.selection == selection, "the selection stays active after a Fill")
        TestImages.expectPixels(after.image.layers[0].surface) { x, y in
            (40..<140).contains(x) && (20..<70).contains(y) ? azure : .white
        }
    }

    @Test func crossTileRect() throws {
        let surface = opaque(.white, width: 600, height: 600)
        let selection = rect(200, 200, 200, 200, canvas: PixelSize(width: 600, height: 600))
        let (filled, touched) = FillSelection.fill(surface, color: azure, mask: selection.mask)
        #expect(touched == [TileCoordinate(column: 0, row: 0), TileCoordinate(column: 1, row: 0),
                            TileCoordinate(column: 0, row: 1), TileCoordinate(column: 1, row: 1)])
        TestImages.expectPixels(filled) { x, y in
            (200..<400).contains(x) && (200..<400).contains(y) ? azure : .white
        }
        let before = state(surface, selection: selection)
        let item = try #require(FillSelection.makeHistoryItem(for: before, color: azure))
        var after = before
        item.apply(to: &after)
        #expect(after.selection == selection, "Fill never touches the selection")
    }

    @Test func noSelectionFillsWholeLayer() throws {
        let surface = TiledSurface(size: PixelSize(width: 600, height: 300))
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        let (filled, _) = FillSelection.fill(surface, color: red, mask: nil)
        TestImages.expectPixels(filled) { _, _ in red }
        let interior = try #require(filled.tile(at: TileCoordinate(column: 0, row: 0)))
        let interior2 = try #require(filled.tile(at: TileCoordinate(column: 1, row: 0)))
        #expect(interior.sharesStorage(with: interior2), "interior full tiles share one storage")
        let edge = try #require(filled.tile(at: TileCoordinate(column: 2, row: 0)))
        #expect(edge.pixel(x: 87, y: 255) == red, "last in-canvas pixel of the 88-wide edge tile")
        #expect(edge.pixel(x: 88, y: 0) == .clear, "out-of-canvas byte stays zero")
    }

    @Test func edgeTilesKeepOutOfCanvasZero() throws {
        let surface = TiledSurface(size: PixelSize(width: 300, height: 257))
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        let (filled, _) = FillSelection.fill(surface, color: red,
                                             mask: Selection.all(canvasSize: surface.size).mask)
        // Edge tiles: (1,0) 44×256, (0,1) 256×1, (1,1) 44×1 — every byte outside each
        // tile's `pixelRect(of:)` must stay 0 (the setTile invariant).
        for coordinate in [TileCoordinate(column: 1, row: 0), TileCoordinate(column: 0, row: 1),
                           TileCoordinate(column: 1, row: 1)] {
            let tile = try #require(filled.tile(at: coordinate))
            let area = filled.pixelRect(of: coordinate).size
            tile.bytes.withUnsafeBytes { buffer in
                for y in 0..<Tile.size {
                    for x in 0..<Tile.size where x >= area.width || y >= area.height {
                        let offset = y * Tile.bytesPerRow + x * 4
                        for byte in 0..<4 {
                            #expect(buffer[offset + byte] == 0, "\(coordinate) local (\(x),\(y)) byte \(byte)")
                        }
                    }
                }
            }
        }
    }

    @Test func transparentColorReleasesTiles() {
        let surface = opaque(.white, width: 300, height: 300)
        let (filled, _) = FillSelection.fill(surface, color: .clear,
                                             mask: Selection.all(canvasSize: surface.size).mask)
        #expect(filled.allocatedTileCoordinates.isEmpty, "alpha-0 fill releases every full tile")
    }

    @Test func wideStripSharesStorage() throws {
        let surface = opaque(.white, width: 65_535, height: 1)
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        let (filled, touched) = FillSelection.fill(surface, color: red, mask: nil)
        #expect(touched.count == 256)
        let first = try #require(filled.tile(at: TileCoordinate(column: 0, row: 0)))
        for column in 1..<255 {
            let tile = try #require(filled.tile(at: TileCoordinate(column: column, row: 0)))
            #expect(tile.sharesStorage(with: first), "tile \(column) shares the one shared tile")
        }
        let last = try #require(filled.tile(at: TileCoordinate(column: 255, row: 0)))
        #expect(!last.sharesStorage(with: first), "the 255-wide last tile is its own edge tile")
        #expect(last.pixel(x: 254, y: 0) == red)
        #expect(last.pixel(x: 255, y: 0) == .clear, "edge padding")
        #expect(first.pixel(x: 0, y: 1) == .clear, "rows below the strip stay zero")
    }

    @Test func noOpAddsNoStep() {
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        let surface = opaque(red, width: 100, height: 100)
        #expect(FillSelection.makeHistoryItem(
            for: state(surface, selection: .all(canvasSize: PixelSize(width: 100, height: 100))),
            color: red) == nil,
            "filling an area that already has exactly that color records nothing (H-6)")
        // Partial mask tiles too: an alpha-0 fill of a transparent area changes nothing.
        let clear = TiledSurface(size: PixelSize(width: 64, height: 64))
        #expect(FillSelection.makeHistoryItem(
            for: state(clear, selection: rect(10.5, 0, 2, 64, canvas: PixelSize(width: 64, height: 64))),
            color: .clear) == nil, "alpha-0 fill of a transparent area records nothing")
    }

    @Test func alwaysEnabled() {
        let surface = opaque(.white, width: 10, height: 10)
        #expect(FillSelection.isEnabled(in: state(surface)))
        #expect(FillSelection.isEnabled(in: state(surface, selection: .all(canvasSize: PixelSize(width: 10, height: 10)))))
    }
}
