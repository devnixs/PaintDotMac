import CoreGraphics
import Foundation

/// An integer pixel coordinate (FMT/NF geometry; spec 0002). Values may be negative — a
/// `PixelPoint` is just a position, not necessarily inside a surface.
struct PixelPoint: Hashable, Sendable, CustomStringConvertible {
    var x: Int
    var y: Int

    static let zero = PixelPoint(x: 0, y: 0)

    var description: String { "(\(x), \(y))" }
}

/// An integer pixel size in pixels per side. `precondition` guards only programmer errors;
/// user-supplied sizes go through `ImageLimits.validate` first.
struct PixelSize: Hashable, Sendable, CustomStringConvertible {
    var width: Int
    var height: Int

    init(width: Int, height: Int) {
        precondition(width >= 0 && height >= 0, "PixelSize sides must be >= 0, got \(width) × \(height)")
        self.width = width
        self.height = height
    }

    /// The rectangle `(0, 0, width, height)`.
    var bounds: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }

    var isEmpty: Bool { width == 0 || height == 0 }

    /// `"300 × 200"` — U+00D7 with single spaces (also the canvas accessibility value format).
    var description: String { "\(width) × \(height)" }
}

/// A half-open integer rectangle covering columns `x..<x+width` and rows `y..<y+height`
/// (spec 0002). Width and height are never negative; all queries are total.
struct PixelRect: Hashable, Sendable, CustomStringConvertible {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    init(x: Int, y: Int, width: Int, height: Int) {
        precondition(width >= 0 && height >= 0, "PixelRect sides must be >= 0, got \(width) × \(height)")
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(origin: PixelPoint, size: PixelSize) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    static let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)

    var minX: Int { x }
    var minY: Int { y }
    /// Exclusive.
    var maxX: Int { x + width }
    /// Exclusive.
    var maxY: Int { y + height }
    var size: PixelSize { PixelSize(width: width, height: height) }
    var origin: PixelPoint { PixelPoint(x: x, y: y) }
    var isEmpty: Bool { width == 0 || height == 0 }

    func contains(_ point: PixelPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    /// An empty `rect` is contained in any rect.
    func contains(_ rect: PixelRect) -> Bool {
        if rect.isEmpty { return true }
        return rect.minX >= minX && rect.maxX <= maxX && rect.minY >= minY && rect.maxY <= maxY
    }

    /// The overlap; `.zero` when disjoint or touching only at an edge.
    func intersection(_ other: PixelRect) -> PixelRect {
        let left = max(minX, other.minX)
        let top = max(minY, other.minY)
        let right = min(maxX, other.maxX)
        let bottom = min(maxY, other.maxY)
        guard right > left, bottom > top else { return .zero }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The smallest rect covering both; an empty operand is ignored, both empty → `.zero`.
    func union(_ other: PixelRect) -> PixelRect {
        if isEmpty, other.isEmpty { return .zero }
        if isEmpty { return other }
        if other.isEmpty { return self }
        let left = min(minX, other.minX)
        let top = min(minY, other.minY)
        let right = max(maxX, other.maxX)
        let bottom = max(maxY, other.maxY)
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    func offsetBy(dx: Int, dy: Int) -> PixelRect {
        PixelRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// The exact floating-point rect (0020: sessions and `Selection(rect:)` take canvas
    /// geometry; the conversion idiom of `CanvasTransform.pixelRectToView`).
    var cgRect: CGRect {
        CGRect(x: Double(x), y: Double(y), width: Double(width), height: Double(height))
    }

    var description: String { "(\(x), \(y), \(width) × \(height))" }
}
