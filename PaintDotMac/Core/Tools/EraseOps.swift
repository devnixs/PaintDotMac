import Foundation

/// The Eraser's per-pixel function (spec 0011; PRD T-12, D-27), separate from `BlendOps`
/// because erasing is not a layer blend mode — Paint.NET's Eraser page documents none.
/// Straight alpha, destination-out: the color channels survive while alpha drops, and a
/// fully erased pixel becomes `(0, 0, 0, 0)` — Paint.NET replaces the RGB of completely
/// erased areas with black (`EraserTool.html`).
enum EraseOps {
    /// The exact integer formula (spec 0011, the normative form):
    /// `e = strength × coverage` (0…65025),
    /// `newA = (p.a × (65025 − e) + 32512) / 65025` — integer division, i.e. round-half-up
    /// of `a × (1 − e/65025)`. `e == 0` returns the pixel bit-for-bit; `newA == 0` returns
    /// `(0, 0, 0, 0)`; otherwise the RGB is untouched. Properties (all asserted by
    /// `EraseOpsTests`): `newA ≤ p.a` always; strength 255 at full coverage erases fully;
    /// on an opaque pixel at full coverage `newA = 255 − strength` exactly (Paint.NET's
    /// 60 → 195, 120 → 135, 255 → 0 examples).
    ///
    /// `strength` is the color slot's alpha (TOOL-A: primary for the left button,
    /// secondary for right/Control), `coverage` the effective (clipped) brush coverage.
    static func erase(_ p: ColorRGBA8, strength: UInt8, coverage: UInt8) -> ColorRGBA8 {
        let e = UInt32(strength) * UInt32(coverage)
        guard e > 0 else { return p }
        let newAlpha = (UInt32(p.alpha) * (65025 - e) + 32512) / 65025
        guard newAlpha > 0 else { return ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0) }
        // `newAlpha ≤ p.alpha` (proven by 0011's exhaustive property test), so the
        // `UInt8` conversion cannot trap for any strength/coverage pair.
        return ColorRGBA8(red: p.red, green: p.green, blue: p.blue, alpha: UInt8(newAlpha))
    }
}
