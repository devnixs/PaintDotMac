import Foundation

/// Straight-alpha per-pixel blend functions keyed by `BlendMode` (spec 0009; AGENTS rule 4:
/// pixels are straight RGBA; premultiply only inside the compositor).
///
/// The `.normal` case is Porter-Duff source-over in straight alpha — the exact integer form
/// of Paint.NET's `UserBlendOps.NormalBlendOp`, and the normative formula for the 0024 Metal
/// parity (±1). 0012's `CPUCompositor` calls `blend(layer.blendMode, dst:src:opacity:)`;
/// the brush calls it with `opacity` 255 and the coverage already folded into `src.a`.
/// 0026/0027/0059 add one function per new `BlendMode` case here.
enum BlendOps {
    /// `round(a·b / 255)` exactly, Paint.NET's rounding: `t = a·b + 128; ((t >> 8) + t) >> 8`.
    /// Equal to `(a·b + 127) / 255` for all inputs (no ties, since 255 is odd).
    static func mul255(_ a: UInt8, _ b: UInt8) -> UInt8 {
        let t = UInt32(a) * UInt32(b) + 128
        return UInt8(((t >> 8) + t) >> 8)
    }

    /// `src.a` is first scaled by `opacity` (`src.a = mul255(src.a, opacity)`), then the
    /// mode's function is applied.
    static func blend(_ mode: BlendMode, dst: ColorRGBA8, src: ColorRGBA8,
                      opacity: UInt8 = 255) -> ColorRGBA8 {
        // `mul255(a, 255) == a`, so the scaling is exact and branch-free at full opacity.
        let src = ColorRGBA8(red: src.red, green: src.green, blue: src.blue,
                             alpha: mul255(src.alpha, opacity))
        switch mode {
        case .normal:
            return normal(dst: dst, src: src)
        }
    }

    /// Porter-Duff source-over in straight alpha, exact integer arithmetic (spec 0009):
    /// with `Sa == 0` the destination is returned bit-for-bit unchanged (including its RGB
    /// when `Da == 0`); otherwise
    /// `fa = Sa·255 + Da·(255 − Sa)`, `outA = (fa + 127) / 255`,
    /// `outC = (Sc·Sa·255 + Dc·Da·(255 − Sa) + fa/2) / fa` per channel.
    /// Every intermediate fits `UInt32` (max ≈ 3.4·10⁷); `/` is truncating.
    static func normal(dst: ColorRGBA8, src: ColorRGBA8) -> ColorRGBA8 {
        let sa = UInt32(src.alpha)
        let da = UInt32(dst.alpha)
        if sa == 0 { return dst }
        let fa = sa * 255 + da * (255 - sa)          // outA·255, range 1…65025 here
        let outAlpha = UInt8((fa + 127) / 255)
        let halfFa = fa / 2
        let inverse = 255 - sa
        func channel(_ sc: UInt8, _ dc: UInt8) -> UInt8 {
            UInt8((UInt32(sc) * sa * 255 + UInt32(dc) * da * UInt32(inverse) + halfFa) / fa)
        }
        return ColorRGBA8(red: channel(src.red, dst.red),
                          green: channel(src.green, dst.green),
                          blue: channel(src.blue, dst.blue),
                          alpha: outAlpha)
    }
}
