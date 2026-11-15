import Testing

@testable import PaintDotMac

struct PixelGeometryTests {
    @Test func rectEdges() {
        let rect = PixelRect(x: 2, y: 3, width: 4, height: 5)
        #expect(rect.minX == 2)
        #expect(rect.minY == 3)
        #expect(rect.maxX == 6)
        #expect(rect.maxY == 8)
        #expect(rect.contains(PixelPoint(x: 2, y: 3)))
        #expect(rect.contains(PixelPoint(x: 5, y: 7)))
        #expect(!rect.contains(PixelPoint(x: 6, y: 7)))
        #expect(!rect.contains(PixelPoint(x: 5, y: 8)))
        #expect(rect.size == PixelSize(width: 4, height: 5))
        #expect(rect.origin == PixelPoint(x: 2, y: 3))
    }

    @Test func intersection() {
        #expect(PixelRect(x: 0, y: 0, width: 10, height: 10)
            .intersection(PixelRect(x: 5, y: 5, width: 10, height: 10))
            == PixelRect(x: 5, y: 5, width: 5, height: 5))
        #expect(PixelRect(x: 0, y: 0, width: 10, height: 10)
            .intersection(PixelRect(x: 10, y: 0, width: 5, height: 5)) == .zero)
        #expect(PixelRect(x: 0, y: 0, width: 4, height: 4)
            .intersection(PixelRect(x: 9, y: 9, width: 2, height: 2)) == .zero)
        #expect(PixelRect(x: 0, y: 0, width: 10, height: 10)
            .intersection(PixelRect(x: 2, y: 3, width: 4, height: 5))
            == PixelRect(x: 2, y: 3, width: 4, height: 5))
    }

    @Test func union() {
        #expect(PixelRect(x: 0, y: 0, width: 2, height: 2)
            .union(PixelRect(x: 5, y: 5, width: 1, height: 1))
            == PixelRect(x: 0, y: 0, width: 6, height: 6))
        let empty = PixelRect(x: 9, y: 9, width: 0, height: 4)
        let other = PixelRect(x: 1, y: 2, width: 3, height: 4)
        #expect(empty.union(other) == other)
        #expect(other.union(empty) == other)
        #expect(empty.union(PixelRect(x: 7, y: 7, width: 0, height: 0)) == .zero)
    }

    @Test func containsRect() {
        let outer = PixelRect(x: 0, y: 0, width: 10, height: 10)
        #expect(outer.contains(PixelRect(x: 4, y: 4, width: 0, height: 0)))
        #expect(outer.contains(PixelRect(x: -5, y: -5, width: 0, height: 0)))
        #expect(outer.contains(outer))
        #expect(outer.contains(PixelRect(x: 9, y: 9, width: 1, height: 1)))
        #expect(!outer.contains(PixelRect(x: 9, y: 9, width: 2, height: 1)))
    }

    @Test func offset() {
        #expect(PixelRect(x: 1, y: 2, width: 3, height: 4)
            .offsetBy(dx: -3, dy: 10) == PixelRect(x: -2, y: 12, width: 3, height: 4))
    }

    @Test func sizeDescription() {
        #expect(PixelSize(width: 300, height: 200).description == "300 × 200")
        #expect(PixelSize(width: 0, height: 5).isEmpty)
        #expect(PixelSize(width: 5, height: 0).isEmpty)
        #expect(!PixelSize(width: 1, height: 1).isEmpty)
        #expect(PixelSize(width: 4, height: 2).bounds == PixelRect(x: 0, y: 0, width: 4, height: 2))
        #expect(PixelRect(x: 1, y: 2, width: 0, height: 3).isEmpty)
        #expect(PixelPoint.zero == PixelPoint(x: 0, y: 0))
    }
}
