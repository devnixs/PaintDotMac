import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `MaskRasterizer` coverage placement (spec 0013 *Test plan*). Every expected value is
/// hand-computed from the spec formulas (rectangle overlap / pixel-center rules, circle
/// geometry, triangle geometry), never produced by the code under test. The triangle and
/// circle cases catch any Y flip.
struct MaskRasterizerTests {
    private func rasterize(_ rect: CGRect, size: PixelSize, antialiased: Bool) -> SelectionMask {
        MaskRasterizer.rasterize(CGPath(rect: rect, transform: nil), size: size,
                                 antialiased: antialiased)
    }

    private func assertOnly255Pixels(_ mask: SelectionMask, inside: Set<PixelPoint>,
                                     comment: Comment) {
        for y in 0..<mask.size.height {
            for x in 0..<mask.size.width {
                let value = mask.coverage(x: x, y: y)
                if inside.contains(PixelPoint(x: x, y: y)) {
                    #expect(value == 255, "(\(x), \(y)) should be 255 — \(comment)")
                } else {
                    #expect(value == 0, "(\(x), \(y)) should be 0 — \(comment)")
                }
            }
        }
    }

    // MARK: - Rectangle fast path

    @Test func integerRectIsExact() {
        let size = PixelSize(width: 64, height: 64)
        let inside = Set((20...24).flatMap { y in (10...14).map { PixelPoint(x: $0, y: y) } })
        // Antialiased: integer-aligned rects are exactly 255/0.
        assertOnly255Pixels(rasterize(CGRect(x: 10, y: 20, width: 5, height: 5), size: size,
                                      antialiased: true),
                            inside: inside, comment: "#expect antialiased integer rect")
        // Aliased.
        assertOnly255Pixels(rasterize(CGRect(x: 10, y: 20, width: 5, height: 5), size: size,
                                      antialiased: false),
                            inside: inside, comment: "#expect aliased integer rect")
    }

    @Test func halfPixelRectCoverage() {
        let size = PixelSize(width: 64, height: 64)
        let mask = rasterize(CGRect(x: 10.5, y: 0, width: 2, height: 1), size: size,
                             antialiased: true)
        #expect(mask.coverage(x: 10, y: 0) == 128, "255 × 0.5 = 127.5 → 128")
        #expect(mask.coverage(x: 11, y: 0) == 255)
        #expect(mask.coverage(x: 12, y: 0) == 128)
        #expect(mask.coverage(x: 9, y: 0) == 0)
        #expect(mask.coverage(x: 13, y: 0) == 0)

        // Quarter-pixel corner: round(255 × 0.75 × 0.75) = 143 at (0,0).
        let corner = rasterize(CGRect(x: 0.25, y: 0.25, width: 3, height: 3), size: size,
                               antialiased: true)
        #expect(corner.coverage(x: 0, y: 0) == 143)
    }

    @Test func aliasedRectUsesPixelCenters() {
        let size = PixelSize(width: 64, height: 64)
        // Columns ceil(9.9) = 10 ..< ceil(12.1) = 13 → x 10, 11, 12.
        let mask = rasterize(CGRect(x: 10.4, y: 0, width: 2.2, height: 1), size: size,
                             antialiased: false)
        for x in [10, 11, 12] {
            #expect(mask.coverage(x: x, y: 0) == 255, "column \(x)")
        }
        #expect(mask.coverage(x: 9, y: 0) == 0)
        #expect(mask.coverage(x: 13, y: 0) == 0)
    }

    @Test func rectAcrossTileSeams() {
        let size = PixelSize(width: 512, height: 512)
        let mask = rasterize(CGRect(x: 250, y: 250, width: 20, height: 20), size: size,
                             antialiased: true)
        for y in 250...269 {
            for x in 250...269 {
                #expect(mask.coverage(x: x, y: y) == 255, "(\(x), \(y)) across the seams")
            }
        }
        #expect(mask.coverage(x: 249, y: 250) == 0)
        #expect(mask.coverage(x: 270, y: 250) == 0)
        for column in [0, 1] {
            for row in [0, 1] {
                if case .partial = mask.tile(at: TileCoordinate(column: column, row: row)) {} else {
                    Issue.record("tile (\(column), \(row)) must be .partial")
                }
            }
        }
    }

    // MARK: - General paths

    @Test func triangleOrientation() {
        let wedge = CGMutablePath()
        wedge.move(to: CGPoint(x: 0, y: 0))
        wedge.addLine(to: CGPoint(x: 100, y: 0))
        wedge.addLine(to: CGPoint(x: 100, y: 10))
        wedge.closeSubpath()
        let mask = MaskRasterizer.rasterize(wedge, size: PixelSize(width: 128, height: 128),
                                            antialiased: true)
        #expect(mask.coverage(x: 95, y: 2) == 255, "inside the wedge at the top right")
        #expect(mask.coverage(x: 95, y: 97) == 0, "below the wedge — a Y flip would put it here")
        #expect(mask.coverage(x: 2, y: 95) == 0, "bottom left is outside")
    }

    @Test(.timeLimit(.minutes(1))) func circleAntialiased() {
        let circle = CGPath(ellipseIn: CGRect(x: 24, y: 24, width: 80, height: 80),
                            transform: nil)
        let mask = MaskRasterizer.rasterize(circle, size: PixelSize(width: 128, height: 128),
                                            antialiased: true)
        var sum = 0
        var edgePixels = 0
        for y in 0..<128 {
            for x in 0..<128 {
                let value = mask.coverage(x: x, y: y)
                sum += Int(value)
                if value > 0, value < 255 { edgePixels += 1 }
                let dx = Double(x) + 0.5 - 64, dy = Double(y) + 0.5 - 64
                let distance = (dx * dx + dy * dy).squareRoot()
                if distance < 39 {
                    #expect(value == 255, "(\(x), \(y)) distance \(distance) must be fully covered")
                } else if distance > 41 {
                    #expect(value == 0, "(\(x), \(y)) distance \(distance) must be uncovered")
                }
            }
        }
        #expect(edgePixels > 0, "antialiased edges exist strictly between 0 and 255")
        let area = Double(sum) / 255
        let expected = Double.pi * 40 * 40
        #expect(abs(area - expected) / expected < 0.005, "Σ coverage / 255 ≈ πr² (\(area) vs \(expected))")
    }

    @Test(.timeLimit(.minutes(1))) func circleAliasedIsBinary() {
        let circle = CGPath(ellipseIn: CGRect(x: 24, y: 24, width: 80, height: 80),
                            transform: nil)
        let mask = MaskRasterizer.rasterize(circle, size: PixelSize(width: 128, height: 128),
                                            antialiased: false)
        var count = 0
        for y in 0..<128 {
            for x in 0..<128 {
                let value = mask.coverage(x: x, y: y)
                #expect(value == 0 || value == 255, "aliased values are binary at (\(x), \(y))")
                if value == 255 { count += 1 }
            }
        }
        let expected = Double.pi * 40 * 40
        #expect(abs(Double(count) - expected) / expected < 0.01,
                "255-pixel count ≈ πr² (\(count) vs \(expected))")
    }

    @Test(.timeLimit(.minutes(1))) func largeCircleSpanningManyTiles() {
        let circle = CGPath(ellipseIn: CGRect(x: 1000, y: 500, width: 2000, height: 2000),
                            transform: nil)
        let mask = MaskRasterizer.rasterize(circle, size: PixelSize(width: 4000, height: 3000),
                                            antialiased: true)
        if case .empty = mask.tile(at: TileCoordinate(column: 0, row: 0)) {} else {
            Issue.record("tile (0,0) far outside must be .empty")
        }
        if case .empty = mask.tile(at: TileCoordinate(column: 15, row: 11)) {} else {
            Issue.record("tile (15,11) far outside must be .empty")
        }
        // Tile (7,5): x 1792…2303, y 1280…1535 — its corners are ~300 px from the center
        // (2000, 1500), deep inside r = 1000.
        if case .full = mask.tile(at: TileCoordinate(column: 7, row: 5)) {} else {
            Issue.record("interior tile (7,5) must be .full")
        }
        // Tile (3,5): the circle's left boundary (x ≈ 1000) crosses it.
        if case .partial = mask.tile(at: TileCoordinate(column: 3, row: 5)) {} else {
            Issue.record("edge tile (3,5) must be .partial")
        }
    }

    @Test func emptyAndNonFiniteInputs() {
        let size = PixelSize(width: 64, height: 64)
        #expect(MaskRasterizer.rasterize(CGPath(rect: .zero, transform: nil), size: size,
                                         antialiased: true).isEmpty)
        let nanPath = CGMutablePath()
        nanPath.move(to: CGPoint(x: Double.nan, y: 5))
        nanPath.addLine(to: CGPoint(x: 40, y: 50))
        nanPath.addLine(to: CGPoint(x: 10, y: 50))
        #expect(MaskRasterizer.rasterize(nanPath, size: size, antialiased: true).isEmpty)
        #expect(MaskRasterizer.rasterize(CGPath(rect: CGRect(x: 1, y: 1, width: 10, height: 10),
                                                transform: nil),
                                         size: PixelSize(width: 0, height: 0),
                                         antialiased: true).isEmpty)
    }

    // MARK: - Tile shortcut

    @Test(.timeLimit(.minutes(1))) func hugeRectUsesTileShortcut() {
        for antialiased in [true, false] {
            let huge = rasterize(CGRect(x: 0, y: 0, width: 65_535, height: 65_535),
                                 size: PixelSize(width: 65_535, height: 65_535),
                                 antialiased: antialiased)
            #expect(huge.isFull, "antialiased: \(antialiased)")
            #expect(huge.partialTileCount == 0, "antialiased: \(antialiased)")
        }

        let rect = CGRect(x: 100, y: 100, width: 1000, height: 1000)
        let mask = rasterize(rect, size: PixelSize(width: 4000, height: 3000), antialiased: true)
        // Interior tiles .full, edge tiles .partial, far tiles .empty.
        if case .full = mask.tile(at: TileCoordinate(column: 2, row: 2)) {} else {
            Issue.record("tile (2,2) x512..767 y512..767 lies wholly inside the rect → .full")
        }
        if case .full = mask.tile(at: TileCoordinate(column: 1, row: 1)) {} else {
            Issue.record("tile (1,1) x256..511 y256..511 lies wholly inside the rect → .full")
        }
        for coordinate in [TileCoordinate(column: 0, row: 0), TileCoordinate(column: 0, row: 1),
                           TileCoordinate(column: 1, row: 0)] {
            if case .partial = mask.tile(at: coordinate) {} else {
                Issue.record("tile \(coordinate) is crossed by an edge → .partial")
            }
        }
        if case .empty = mask.tile(at: TileCoordinate(column: 5, row: 5)) {} else {
            Issue.record("tile (5,5) x1280..1535 lies right of the rect → .empty")
        }
        // Coverage equals the overlap formula at every pixel of an edge tile.
        for y in [99, 100, 150, 255, 256] {
            for x in [99, 100, 110, 255, 1099, 1100, 1101] {
                let overlapX = max(0, min(Double(x + 1), rect.maxX) - max(Double(x), rect.minX))
                let overlapY = max(0, min(Double(y + 1), rect.maxY) - max(Double(y), rect.minY))
                let expected = UInt8((255 * overlapX * overlapY).rounded(.toNearestOrAwayFromZero))
                #expect(mask.coverage(x: x, y: y) == expected, "(\(x), \(y)) vs the formula")
            }
        }
    }
}
