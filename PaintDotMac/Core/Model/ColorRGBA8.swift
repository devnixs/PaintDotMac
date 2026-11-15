import Foundation

/// One 8-bit sRGB pixel with straight (non-premultiplied) alpha (NF-9). Premultiplication
/// happens only inside the compositor (AGENTS.md rule 4).
struct ColorRGBA8: Hashable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static let clear = ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0)
    static let black = ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255)
    static let white = ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255)

    var isTransparent: Bool { alpha == 0 }

    /// The one rounding rule for un-premultiplying in the whole app: round-half-up of
    /// `component × 255 / alpha`, clamped to 255; `alpha == 0 → 0`. A premultiplied component
    /// larger than its alpha is invalid input and clamps to 255.
    static func unpremultiply(_ component: UInt8, alpha: UInt8) -> UInt8 {
        guard alpha > 0 else { return 0 }
        let numerator = Int(component) * 255 + Int(alpha) / 2
        return UInt8(min(255, numerator / Int(alpha)))
    }

    /// Treats `self` as premultiplied and un-premultiplies the color channels.
    /// An `alpha == 0` input gives `.clear`.
    func unpremultiplied() -> ColorRGBA8 {
        guard alpha > 0 else { return .clear }
        return ColorRGBA8(
            red: Self.unpremultiply(red, alpha: alpha),
            green: Self.unpremultiply(green, alpha: alpha),
            blue: Self.unpremultiply(blue, alpha: alpha),
            alpha: alpha
        )
    }
}
