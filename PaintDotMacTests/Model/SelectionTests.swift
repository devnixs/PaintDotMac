import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// The `Selection` value: nil-when-empty, clipping, inversion, path booleans, and the
/// combine algebra (spec 0013 *Test plan*).
struct SelectionTests {
    private static let canvas = PixelSize(width: 100, height: 100)

    @Test func selectAll() {
        let all = Selection.all(canvasSize: PixelSize(width: 300, height: 200))
        #expect(all.path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 300, height: 200))
        #expect(all.mask.isFull)
        #expect(all.bounds == PixelRect(x: 0, y: 0, width: 300, height: 200))
        #expect(all.mask.partialTileCount == 0, "Select All allocates no tile bytes")
    }

    @Test func rectInitClipsToCanvas() throws {
        let selection = try #require(Selection(rect: CGRect(x: -10, y: -10, width: 30, height: 30),
                                                canvasSize: Self.canvas))
        #expect(selection.bounds == PixelRect(x: 0, y: 0, width: 20, height: 20))
        #expect(selection.path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    @Test func pathOutsideCanvasIsNil() {
        #expect(Selection(rect: CGRect(x: 200, y: 200, width: 10, height: 10),
                          canvasSize: Self.canvas) == nil)
        let off = CGMutablePath()
        off.addRect(CGRect(x: 150, y: 0, width: 40, height: 40))
        #expect(Selection(path: off, canvasSize: Self.canvas) == nil)
    }

    @Test func zeroAreaPathIsNil() {
        let line = CGMutablePath()
        line.move(to: CGPoint(x: 0, y: 0))
        line.addLine(to: CGPoint(x: 50, y: 50))
        #expect(Selection(path: line, canvasSize: Self.canvas) == nil)
        #expect(Selection(rect: CGRect(x: 10, y: 10, width: 0, height: 40),
                          canvasSize: Self.canvas) == nil)
    }

    @Test func nonFiniteRectIsNil() {
        #expect(Selection(rect: CGRect(x: Double.nan, y: 0, width: 10, height: 10),
                          canvasSize: Self.canvas) == nil)
        #expect(Selection(rect: CGRect(x: 0, y: 0, width: Double.infinity, height: 10),
                          canvasSize: Self.canvas) == nil)
    }

    @Test func partlyOutsideIsClipped() throws {
        let selection = try #require(Selection(rect: CGRect(x: 90, y: -5, width: 30, height: 30),
                                                canvasSize: Self.canvas))
        #expect(selection.bounds == PixelRect(x: 90, y: 0, width: 10, height: 25))
        #expect(selection.mask.coverage(x: 95, y: 10) == 255)
        #expect(selection.mask.coverage(x: 99, y: 24) == 255)
    }

    @Test func emptyResultsAreNil() throws {
        let a = try #require(Selection(rect: CGRect(x: 10, y: 10, width: 20, height: 20),
                                        canvasSize: Self.canvas))
        let b = try #require(Selection(rect: CGRect(x: 70, y: 70, width: 20, height: 20),
                                        canvasSize: Self.canvas))
        #expect(a.combined(with: a, mode: .xor) == nil, "A ⊕ A = ∅")
        #expect(a.combined(with: a, mode: .exclude) == nil, "A ∖ A = ∅")
        #expect(a.combined(with: b, mode: .intersect) == nil, "disjoint intersection")
        #expect(Selection.all(canvasSize: Self.canvas).inverted() == nil,
                "inverting Select All deselects")
    }

    @Test func invertedIncludesCanvasBorder() throws {
        let rect = try #require(Selection(rect: CGRect(x: 10, y: 10, width: 20, height: 20),
                                           canvasSize: Self.canvas))
        let inverted = try #require(rect.inverted())
        #expect(inverted.path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 100, height: 100),
                "the ants also run along the canvas border")
        #expect(inverted.path.contains(CGPoint(x: 5, y: 5)) == true)
        #expect(inverted.path.contains(CGPoint(x: 20, y: 20)) == false)
        #expect(inverted.mask.coverage(x: 20, y: 20) == 0)
        #expect(inverted.mask.coverage(x: 5, y: 5) == 255)
        // Inverting again restores the rectangle.
        #expect(inverted.inverted()?.mask == rect.mask)
    }

    @Test func combinePaths() throws {
        let a = try #require(Selection(rect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                       canvasSize: Self.canvas))
        let b = try #require(Selection(rect: CGRect(x: 20, y: 20, width: 40, height: 40),
                                       canvasSize: Self.canvas))
        let union = try #require(a.combined(with: b, mode: .union))
        #expect(union.path.contains(CGPoint(x: 10, y: 10)))
        #expect(union.path.contains(CGPoint(x: 50, y: 50)))
        #expect(union.path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 60, height: 60))
        #expect(union.mask.bounds == PixelRect(x: 0, y: 0, width: 60, height: 60))
        #expect(union.mask.coverage(x: 30, y: 30) == 255)

        let exclude = try #require(a.combined(with: b, mode: .exclude))
        #expect(exclude.path.contains(CGPoint(x: 10, y: 10)))
        #expect(!exclude.path.contains(CGPoint(x: 30, y: 30)))
        #expect(!exclude.path.contains(CGPoint(x: 50, y: 50)))

        let intersect = try #require(a.combined(with: b, mode: .intersect))
        #expect(intersect.path.contains(CGPoint(x: 30, y: 30)))
        #expect(intersect.path.boundingBoxOfPath == CGRect(x: 20, y: 20, width: 20, height: 20))

        let xor = try #require(a.combined(with: b, mode: .xor))
        #expect(xor.path.contains(CGPoint(x: 10, y: 10)))
        #expect(xor.path.contains(CGPoint(x: 50, y: 50)))
        #expect(!xor.path.contains(CGPoint(x: 30, y: 30)))
        #expect(xor.mask.coverage(x: 30, y: 30) == 0)
        #expect(xor.mask.coverage(x: 10, y: 10) == 255)

        let replace = try #require(a.combined(with: b, mode: .replace))
        #expect(replace == b, "replace is the operand")
    }

    @Test func nilOperandsActAsEmpty() throws {
        let b = try #require(Selection(rect: CGRect(x: 20, y: 20, width: 40, height: 40),
                                       canvasSize: Self.canvas))
        let a = try #require(Selection(rect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                       canvasSize: Self.canvas))
        #expect(Selection.combine(nil, b, mode: .union, canvasSize: Self.canvas)?.mask == b.mask)
        #expect(Selection.combine(nil, b, mode: .exclude, canvasSize: Self.canvas) == nil)
        #expect(Selection.combine(nil, b, mode: .intersect, canvasSize: Self.canvas) == nil)
        #expect(Selection.combine(nil, b, mode: .xor, canvasSize: Self.canvas)?.mask == b.mask)
        #expect(Selection.combine(a, nil, mode: .union, canvasSize: Self.canvas) == a)
        #expect(Selection.combine(a, nil, mode: .intersect, canvasSize: Self.canvas) == nil)
        #expect(Selection.combine(nil, nil, mode: .union, canvasSize: Self.canvas) == nil)
    }

    @Test func sizeMismatchReturnsExisting() throws {
        let a100 = try #require(Selection(rect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                          canvasSize: Self.canvas))
        let b50 = try #require(Selection(rect: CGRect(x: 0, y: 0, width: 20, height: 20),
                                         canvasSize: PixelSize(width: 50, height: 50)))
        #expect(Selection.combine(a100, b50, mode: .union, canvasSize: Self.canvas) == a100,
                "a defined no-op, never a trap")
    }

    @Test func oneByOneCanvas() {
        let all = Selection.all(canvasSize: PixelSize(width: 1, height: 1))
        #expect(all.mask.tiles.count == 1)
        if case .full = all.mask.tile(at: TileCoordinate(column: 0, row: 0)) {} else {
            Issue.record("one .full tile")
        }
        #expect(all.bounds == PixelRect(x: 0, y: 0, width: 1, height: 1))
        #expect(all.inverted() == nil)
        #expect(all.mask.coverage(x: 0, y: 0) == 255)
        #expect(all.mask.coverage(x: 1, y: 0) == 0)
    }

    @Test func equalityUsesMaskAndPath() throws {
        let canvas = Self.canvas
        let a = try #require(Selection(rect: CGRect(x: 10, y: 10, width: 20, height: 20),
                                       canvasSize: canvas))
        let same = try #require(Selection(rect: CGRect(x: 10, y: 10, width: 20, height: 20),
                                          canvasSize: canvas))
        let other = try #require(Selection(rect: CGRect(x: 10, y: 10, width: 20, height: 30),
                                           canvasSize: canvas))
        #expect(a == same, "same mask and path content")
        #expect(a != other)
        let sameMaskDifferentOutline = try #require(Selection(
            mask: a.mask,
            outline: CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)))
        #expect(a != sameMaskDifferentOutline, "the outline participates in equality")
    }

    @Test func maskOutlineInit() throws {
        let mask = SelectionMask(size: PixelSize(width: 100, height: 100)) { x, y in
            (5...19).contains(x) && (5...19).contains(y) ? 255 : 0
        }
        let outline = CGPath(rect: CGRect(x: 5, y: 5, width: 15, height: 15), transform: nil)
        let selection = try #require(Selection(mask: mask, outline: outline))
        if case .partial(let storage) = selection.mask.tile(at: TileCoordinate(column: 0, row: 0)),
           case .partial(let original) = mask.tile(at: TileCoordinate(column: 0, row: 0)) {
            #expect(storage === original, "the mask is stored unchanged")
        } else {
            Issue.record("the builder mask should keep its partial tile")
        }
        #expect(selection.bounds == mask.bounds)
        // The outline is clipped to the canvas.
        let outside = Selection(mask: mask, outline: CGPath(rect: CGRect(x: 200, y: 200,
                                                                         width: 10, height: 10),
                                                            transform: nil))
        #expect(outside != nil)
        #expect(Selection(mask: SelectionMask(size: PixelSize(width: 10, height: 10)),
                          outline: outline) == nil, "an empty mask is no selection")
    }

    @Test func pathByteEstimateCountsElements() throws {
        let selection = try #require(Selection(rect: CGRect(x: 1, y: 2, width: 30, height: 40),
                                               canvasSize: Self.canvas))
        var count = 0
        selection.path.applyWithBlock { _ in count += 1 }
        #expect(selection.pathByteEstimate == 64 + 32 * count)
    }
}
