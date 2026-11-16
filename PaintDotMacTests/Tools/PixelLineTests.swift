import Foundation
import Testing

@testable import PaintDotMac

/// `PixelLine` (spec 0011 *Test plan*): the exact Bresenham sequences hand-computed from
/// the spec's algorithm, the walk properties over seeded random pairs, and the extreme
/// clamp-range run.
struct PixelLineTests {
    private func point(_ x: Int, _ y: Int) -> PixelPoint { PixelPoint(x: x, y: y) }

    @Test func shallowLine() {
        #expect(PixelLine.pixels(from: point(0, 0), to: point(5, 2))
                    == [point(0, 0), point(1, 0), point(2, 1),
                        point(3, 1), point(4, 2), point(5, 2)])
    }

    @Test func shallowLineReversed() {
        #expect(PixelLine.pixels(from: point(5, 2), to: point(0, 0))
                    == [point(5, 2), point(4, 2), point(3, 1),
                        point(2, 1), point(1, 0), point(0, 0)])
    }

    @Test func steepLine() {
        #expect(PixelLine.pixels(from: point(0, 0), to: point(1, 3))
                    == [point(0, 0), point(0, 1), point(1, 2), point(1, 3)])
    }

    @Test func horizontal() {
        #expect(PixelLine.pixels(from: point(2, 7), to: point(6, 7))
                    == [point(2, 7), point(3, 7), point(4, 7), point(5, 7), point(6, 7)])
    }

    @Test func vertical() {
        #expect(PixelLine.pixels(from: point(4, 1), to: point(4, -2))
                    == [point(4, 1), point(4, 0), point(4, -1), point(4, -2)])
    }

    @Test func diagonal() {
        #expect(PixelLine.pixels(from: point(0, 0), to: point(-3, -3))
                    == [point(0, 0), point(-1, -1), point(-2, -2), point(-3, -3)])
    }

    @Test func singlePoint() {
        #expect(PixelLine.pixels(from: point(9, 9), to: point(9, 9)) == [point(9, 9)])
    }

    /// Walk properties over 1 000 seeded endpoint pairs in [−300, 300]²: exactly
    /// `max(|dx|, |dy|) + 1` pixels, `a` first, `b` last, consecutive pixels at Chebyshev
    /// distance exactly 1, and every pixel inside the endpoints' bounding box.
    @Test func walkProperties() {
        let seed = SeededRandom.resolvedSeed(default: 0x0011_0011_0011)
        var rng = SeededRandom(seed: seed)
        for _ in 0 ..< 1000 {
            let a = point(rng.int(in: -300 ... 300), rng.int(in: -300 ... 300))
            let b = point(rng.int(in: -300 ... 300), rng.int(in: -300 ... 300))
            let line = PixelLine.pixels(from: a, to: b)
            let expectedCount = max(abs(b.x - a.x), abs(b.y - a.y)) + 1
            let detail = "a=\(a) b=\(b) \(SeededRandom(seed: seed).comment)"
            #expect(line.count == expectedCount, "count \(expectedCount) \(detail)")
            #expect(line.first == a, "first is a \(detail)")
            #expect(line.last == b, "last is b \(detail)")
            let left = min(a.x, b.x), right = max(a.x, b.x)
            let top = min(a.y, b.y), bottom = max(a.y, b.y)
            for (index, pixel) in line.enumerated() {
                #expect(left ... right ~= pixel.x && top ... bottom ~= pixel.y,
                        "pixel \(pixel) inside the bounding box \(detail)")
                guard index > 0 else { continue }
                let previous = line[index - 1]
                let chebyshev = max(abs(pixel.x - previous.x), abs(pixel.y - previous.y))
                #expect(chebyshev == 1, "8-connected step \(previous) → \(pixel) \(detail)")
            }
        }
    }

    /// The clamp-range diagonal: (−65 536, −65 536) → (131 071, 131 071) visits
    /// 196 608 pixels and the `2 × err` arithmetic does not overflow.
    @Test func extremeCoordinatesDoNotOverflow() {
        var count = 0
        PixelLine.forEachPixel(from: point(-65_536, -65_536), to: point(131_071, 131_071)) { _ in
            count += 1
        }
        #expect(count == 196_608)
    }
}
