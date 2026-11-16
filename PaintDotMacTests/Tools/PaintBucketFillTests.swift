import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// A `BrushClipMask` over a 1×1 canvas row of hand-picked coverage values (`nil`
/// coordinates inside `bounds` read 0) — the clip double for the pure coverage tests.
private struct RowClip: BrushClipMask {
    let values: [UInt8]

    var bounds: PixelRect { PixelRect(x: 0, y: 0, width: values.count, height: 1) }

    func coverage(x: Int, y: Int) -> UInt8 {
        guard y == 0, values.indices.contains(x) else { return 0 }
        return values[x]
    }
}

/// `PaintBucketFill` pure unit tests (spec 0017 *Test plan*): hand-computed coverage and
/// compose expectations. Regions are `FloodFillStencil`s built with `insert` from
/// hand-listed points.
@MainActor
struct PaintBucketFillTests {
    private func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> ColorRGBA8 {
        ColorRGBA8(red: UInt8(r), green: UInt8(g), blue: UInt8(b), alpha: UInt8(a))
    }

    /// A stencil of exactly `points` on a `width × height` canvas.
    private func stencil(_ width: Int, _ height: Int, _ points: [PixelPoint])
        -> FloodFillStencil
    {
        var region = FloodFillStencil(size: PixelSize(width: width, height: height))
        for point in points { region.insert(point) }
        return region
    }

    private func rectPoints(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> [PixelPoint] {
        (y0...y1).flatMap { y in (x0...x1).map { PixelPoint(x: $0, y: y) } }
    }

    // MARK: Feather table & aliased basics

    @Test func featherValues() {
        let expected: [UInt8] = [0, 28, 57, 85, 113, 142, 170, 198, 227]
        for k in 0...8 {
            #expect(PaintBucketFill.featherCoverage(neighbours: k) == expected[k], "k = \(k)")
        }
    }

    @Test func aliasedIsBinary() {
        let region = stencil(10, 10, rectPoints(2, 2, 5, 5))
        let coverage = PaintBucketFill.coverage(region: region,
                                                canvasSize: PixelSize(width: 10, height: 10),
                                                antialiasing: false)
        for y in 0..<10 {
            for x in 0..<10 {
                let inside = (2...5).contains(x) && (2...5).contains(y)
                #expect(coverage.coverage(x: x, y: y) == (inside ? 255 : 0), "(\(x), \(y))")
            }
        }
        #expect(coverage.bounds == PixelRect(x: 2, y: 2, width: 4, height: 4))
    }

    // MARK: Antialiased feather

    @Test func antialiasedStraightEdge() {
        // Region = columns 0…4, all rows.
        let region = stencil(10, 10, rectPoints(0, 0, 4, 9))
        let coverage = PaintBucketFill.coverage(region: region,
                                                canvasSize: PixelSize(width: 10, height: 10),
                                                antialiasing: true)
        for y in 0..<10 {
            #expect(coverage.coverage(x: 4, y: y) == 255, "(4, \(y)) inside")
            let ring = y >= 1 && y <= 8 ? UInt8(85) : UInt8(57) // k = 3, or 2 at the edge
            #expect(coverage.coverage(x: 5, y: y) == ring, "(5, \(y)) ring")
            #expect(coverage.coverage(x: 6, y: y) == 0, "(6, \(y)) outside the ring")
        }
    }

    @Test func antialiasedCorner() {
        // Single pixel (5,5): its 8 neighbours each have exactly k = 1 region neighbour.
        let single = PaintBucketFill.coverage(
            region: stencil(10, 10, [PixelPoint(x: 5, y: 5)]),
            canvasSize: PixelSize(width: 10, height: 10), antialiasing: true)
        #expect(single.coverage(x: 5, y: 5) == 255)
        for dy in -1...1 {
            for dx in -1...1 where dx != 0 || dy != 0 {
                #expect(single.coverage(x: 5 + dx, y: 5 + dy) == 28, "neighbour (\(dx), \(dy))")
            }
        }
        #expect(single.coverage(x: 7, y: 5) == 0)

        // 2×2 block (4,4)…(5,5): corner (3,3) has k = 1 → 28; edge (3,4) and (6,5) have
        // k = 2 → 57; corner (6,6) has k = 1 → 28.
        let block = PaintBucketFill.coverage(
            region: stencil(10, 10, rectPoints(4, 4, 5, 5)),
            canvasSize: PixelSize(width: 10, height: 10), antialiasing: true)
        #expect(block.coverage(x: 3, y: 3) == 28)
        #expect(block.coverage(x: 3, y: 4) == 57)
        #expect(block.coverage(x: 6, y: 5) == 57)
        #expect(block.coverage(x: 6, y: 6) == 28)
    }

    @Test func featherClippedToCanvas() {
        let coverage = PaintBucketFill.coverage(
            region: stencil(3, 3, [PixelPoint(x: 0, y: 0)]),
            canvasSize: PixelSize(width: 3, height: 3), antialiasing: true)
        #expect(coverage.coverage(x: 0, y: 0) == 255)
        #expect(coverage.coverage(x: 1, y: 0) == 28)
        #expect(coverage.coverage(x: 0, y: 1) == 28)
        #expect(coverage.coverage(x: 1, y: 1) == 28)
        // Nothing outside the canvas is accessible.
        #expect(coverage.coverage(x: -1, y: 0) == 0)
        #expect(coverage.coverage(x: 0, y: -1) == 0)
        #expect(coverage.coverage(x: 3, y: 0) == 0)
    }

    @Test func onePixelCanvas() {
        let coverage = PaintBucketFill.coverage(
            region: stencil(1, 1, [PixelPoint(x: 0, y: 0)]),
            canvasSize: PixelSize(width: 1, height: 1), antialiasing: true)
        #expect(coverage.coverage(x: 0, y: 0) == 255)
        #expect(coverage.tiles.count == 1)
        #expect(coverage.bounds == PixelRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func tileBoundary() {
        // 300 × 10, region x ≤ 255 → the feather ring at x = 256 lives in tile (1, 0).
        let region = stencil(300, 10, rectPoints(0, 0, 255, 9))
        let coverage = PaintBucketFill.coverage(region: region,
                                                canvasSize: PixelSize(width: 300, height: 10),
                                                antialiasing: true)
        // (256, 5): three region neighbours ((255,4), (255,5), (255,6)) → k = 3 → 85.
        #expect(coverage.coverage(x: 256, y: 5) == 85)
        #expect(Set(coverage.tiles.keys)
                    == [TileCoordinate(column: 0, row: 0), TileCoordinate(column: 1, row: 0)])
    }

    // MARK: Compose (0009's rule through BlendOps)

    /// The 0009 Normal formula restated independently of `BlendOps` (spec 0017): `Sa` is
    /// the color alpha scaled by coverage with round-half-up `(a·b + 127) / 255`, then
    /// integer straight-alpha source-over.
    private func normalCompose(dst: ColorRGBA8, color: ColorRGBA8, coverage: UInt8)
        -> ColorRGBA8
    {
        let sa = (Int(color.alpha) * Int(coverage) + 127) / 255
        guard sa > 0 else { return dst }
        let da = Int(dst.alpha)
        let fa = sa * 255 + da * (255 - sa)
        let halfFa = fa / 2
        let inverse = 255 - sa
        func channel(_ sc: Int, _ dc: Int) -> UInt8 {
            UInt8((sc * sa * 255 + dc * da * inverse + halfFa) / fa)
        }
        return ColorRGBA8(red: channel(Int(color.red), Int(dst.red)),
                          green: channel(Int(color.green), Int(dst.green)),
                          blue: channel(Int(color.blue), Int(dst.blue)),
                          alpha: UInt8((fa + 127) / 255))
    }

    @Test func composeMatchesBlendOps() throws {
        var surface = TiledSurface(size: PixelSize(width: 4, height: 1))
        let before = [rgba(255, 255, 255, 255), rgba(0, 0, 255, 128),
                      rgba(0, 0, 0, 0), rgba(10, 20, 30, 255)]
        for (x, color) in before.enumerated() {
            surface.setPixel(color, at: PixelPoint(x: x, y: 0))
        }
        let coverages: [UInt8] = [255, 255, 128, 85]
        let coverage = PaintBucketFill.FillCoverage(
            canvasSize: PixelSize(width: 4, height: 1),
            tiles: [TileCoordinate(column: 0, row: 0): coverages
                + [UInt8](repeating: 0, count: Tile.size * Tile.size - 4)])
        let color = rgba(200, 0, 0, 200)

        let touched = PaintBucketFill.apply(coverage, clip: nil, color: color,
                                            blendMode: .normal, to: &surface)
        #expect(touched == [TileCoordinate(column: 0, row: 0)])
        // Hand-computed pins (spec 0017): Sa = mul255(200, cov) = 200, 200, 100, 67.
        let expected = [rgba(212, 55, 55, 255), rgba(176, 0, 31, 228),
                        rgba(200, 0, 0, 100), rgba(60, 15, 22, 255)]
        for (x, want) in expected.enumerated() {
            #expect(surface.pixel(at: PixelPoint(x: x, y: 0)) == want, "pixel \(x)")
            #expect(want == normalCompose(dst: before[x], color: color, coverage: coverages[x]),
                    "pixel \(x) against the restated formula")
        }
    }

    @Test func clipMultipliesCoverage() {
        var surface = TiledSurface(size: PixelSize(width: 3, height: 1))
        surface.fill(.white)
        let coverage = PaintBucketFill.selectionCoverage(clip: nil,
                                                         canvasSize: PixelSize(width: 3, height: 1))
        let clip = RowClip(values: [255, 128, 0])
        let red = rgba(255, 0, 0, 255)

        let touched = PaintBucketFill.apply(coverage, clip: clip, color: red,
                                            blendMode: .normal, to: &surface)
        // effCov = mul255(255, [255, 128, 0]) = [255, 128, 0]; pixel 2 stays white.
        #expect(surface.pixel(at: PixelPoint(x: 0, y: 0)) == red)
        // Pixel 1: Sa = mul255(255, 128) = 128, Normal over white →
        // R = (255·128·255 + 255·255·127 + 32 512)/65 025 = 255, G = B = 8 290 687/65 025 = 127.
        #expect(surface.pixel(at: PixelPoint(x: 1, y: 0))
                    == rgba(255, 127, 127, 255), "half-covered → half-strength red")
        #expect(surface.pixel(at: PixelPoint(x: 2, y: 0)) == .white)
        #expect(touched == [TileCoordinate(column: 0, row: 0)])
    }

    @Test func zeroAlphaColorIsNoOp() {
        var surface = TiledSurface(size: PixelSize(width: 4, height: 1))
        surface.fill(.white)
        let generation = surface.generation
        let coverage = PaintBucketFill.selectionCoverage(clip: nil,
                                                         canvasSize: PixelSize(width: 4, height: 1))
        let touched = PaintBucketFill.apply(coverage, clip: nil, color: rgba(255, 0, 0, 0),
                                            blendMode: .normal, to: &surface)
        #expect(touched.isEmpty)
        #expect(surface.generation == generation)
    }

    @Test func identicalResultWritesNothing() {
        var surface = TiledSurface(size: PixelSize(width: 4, height: 1))
        surface.fill(.white)
        let generation = surface.generation
        let coverage = PaintBucketFill.selectionCoverage(clip: nil,
                                                         canvasSize: PixelSize(width: 4, height: 1))
        let touched = PaintBucketFill.apply(coverage, clip: nil, color: .white,
                                            blendMode: .normal, to: &surface)
        #expect(touched.isEmpty)
        #expect(surface.generation == generation)
    }

    // MARK: Fill = Selection coverage

    @Test func selectionCoverageCopiesMask() {
        let clip = RowClip(values: [0, 77, 255])
        let coverage = PaintBucketFill.selectionCoverage(clip: clip,
                                                         canvasSize: PixelSize(width: 3, height: 1))
        #expect(coverage.coverage(x: 0, y: 0) == 0)
        #expect(coverage.coverage(x: 1, y: 0) == 77)
        #expect(coverage.coverage(x: 2, y: 0) == 255)

        let full = PaintBucketFill.selectionCoverage(clip: nil,
                                                     canvasSize: PixelSize(width: 3, height: 2))
        for y in 0..<2 {
            for x in 0..<3 {
                #expect(full.coverage(x: x, y: y) == 255, "(\(x), \(y))")
            }
        }
        // Entries outside the canvas stay 0 and the tight bounds hold.
        #expect(full.coverage(x: 3, y: 0) == 0)
        #expect(full.bounds == PixelRect(x: 0, y: 0, width: 3, height: 2))
    }
}
