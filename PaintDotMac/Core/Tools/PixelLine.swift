import Foundation

/// The Pencil's one-pixel line (spec 0011, PRD T-13): the exact integer all-octant
/// Bresenham walk in the spec's error form, both endpoints inclusive. The algorithm is
/// normative as written in spec 0011 (mirrored from Paint.NET's Pencil.html "draw a single
/// pixel at a time" dragging behavior); its proven properties, all asserted by
/// `PixelLineTests`: exactly `max(|dx|, |dy|) + 1` pixels, consecutive pixels 8-connected
/// (Chebyshev distance 1), first `a`, last `b`, and `a == b` visits one pixel.
///
/// All arithmetic is `Int` (64-bit), so `2 × err` cannot overflow for any coordinate in
/// the `[-65_536, 131_071]` clamp range the Pencil maps its events into (`ImageLimits`
/// caps image sides at 65 535, so `err` stays within ±4·10⁵ there).
enum PixelLine {
    /// Non-allocating visit of every pixel on the line, in walk order.
    static func forEachPixel(from a: PixelPoint, to b: PixelPoint, _ body: (PixelPoint) -> Void) {
        var x0 = a.x
        var y0 = a.y
        let x1 = b.x
        let y1 = b.y
        let dx = abs(x1 - x0)
        let sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0)   // the spec's signed-negative form
        let sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            body(PixelPoint(x: x0, y: y0))
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x0 += sx }
            if e2 <= dx { err += dx; y0 += sy }
        }
    }

    /// Every pixel on the line, in walk order (`a` first, `b` last).
    static func pixels(from a: PixelPoint, to b: PixelPoint) -> [PixelPoint] {
        var result: [PixelPoint] = []
        result.reserveCapacity(max(abs(b.x - a.x), abs(b.y - a.y)) + 1)
        forEachPixel(from: a, to: b) { result.append($0) }
        return result
    }
}
