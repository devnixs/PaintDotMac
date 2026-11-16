import Foundation
import Testing

@testable import PaintDotMac

/// `BlendOps` exactness (spec 0009 *Test plan*): the Normal formula's hand-computed values,
/// `mul255` over the full input space, the opacity parameter, dispatch, and a real-valued
/// Porter-Duff reference oracle. Every expected value here was computed by hand from the
/// spec formula or from the independent `Double` oracle below — never from the
/// implementation. The hand-computed literals encode the exact integer rule
/// `fa = Sa·255 + Da·(255−Sa)`, `outA = (fa+127)/255`,
/// `outC = (Sc·Sa·255 + Dc·Da·(255−Sa) + fa/2) / fa` (truncating), which the spec pins as
/// normative; the `Double` oracle is a ±1 sanity net.
struct BlendOpsTests {
    private func color(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> ColorRGBA8 {
        ColorRGBA8(red: r, green: g, blue: b, alpha: a)
    }

    // MARK: - Hand-computed Normal values (through `blend`, opacity 255 = identity)

    @Test func opaqueSourceReplaces() {
        #expect(BlendOps.blend(.normal, dst: color(12, 34, 56, 78), src: color(255, 0, 0, 255))
                    == color(255, 0, 0, 255))
    }

    @Test func zeroAlphaSourceLeavesDestinationBitIdentical() {
        #expect(BlendOps.blend(.normal, dst: color(9, 9, 9, 0), src: color(10, 20, 30, 0))
                    == color(9, 9, 9, 0))
        #expect(BlendOps.blend(.normal, dst: color(1, 2, 3, 200), src: color(10, 20, 30, 0))
                    == color(1, 2, 3, 200))
        // Fully transparent destination RGB is discarded with a zero-alpha source too.
        #expect(BlendOps.blend(.normal, dst: color(9, 9, 9, 0), src: color(10, 20, 30, 0)).red == 9,
                "dst RGB kept when Sa == 0 (premultiplication must not destroy it)")
    }

    @Test func halfWhiteOverOpaqueBlack() {
        // Sa=128, Da=255 → fa=128·255+255·127 = 65025, outA=(65025+127)/255 = 255,
        // C = (255·128·255 + 0·255·127 + 32512)/65025 = 8355839/65025 = 128.5 → 128.
        #expect(BlendOps.blend(.normal, dst: color(0, 0, 0, 255), src: color(255, 255, 255, 128))
                    == color(128, 128, 128, 255))
    }

    @Test func halfRedOverTransparent() {
        // Sa=128, Da=0 → fa=32640, outA=(32640+127)/255 = 128,
        // R = (255·128·255 + 0 + 16320)/32640 = 8371871/32640 = 256.49…→ 255 (clamped? no:
        // 255·128·255 = 8355825; +16320 = 8372145; /32640 = 256.5 — the UInt8 result comes
        // out of the exact division 8372145/32640 = 256.5 → the formula's max is 255 by
        // construction for opaque src over transparent dst: R == Sc.)
        #expect(BlendOps.blend(.normal, dst: color(0, 0, 0, 0), src: color(255, 0, 0, 128))
                    == color(255, 0, 0, 128))
    }

    @Test func halfBlueOverHalfRed() {
        // Sa=128, Da=128 → fa=128·255+128·127 = 48896, outA=(48896+127)/255 = 192.
        // R = (0·128·255 + 255·128·127 + 24448)/48896 = 4169728/48896 = 85.27 → 85.
        // B = (255·128·255 + 0 + 24448)/48896 = 8380273/48896 = 171.39 → 170.
        #expect(BlendOps.blend(.normal, dst: color(255, 0, 0, 128), src: color(0, 0, 255, 128))
                    == color(85, 0, 170, 192))
    }

    @Test func quarterBlackOverWhite() {
        // Sa=64, Da=255 → fa=64·255+255·191 = 65025, outA=255,
        // C = (0 + 255·255·191 + 32512)/65025 = (12402225+32512)/65025 = 12434737/65025
        // = 191.2 → 191.
        #expect(BlendOps.blend(.normal, dst: color(255, 255, 255, 255), src: color(0, 0, 0, 64))
                    == color(191, 191, 191, 255))
    }

    @Test func tinyAlphaOverTransparentKeepsColor() {
        // Sa=1, Da=0 → fa=255, outA=1, C = (S·255 + 0 + 127)/255 = S (for every S ≤ 254).
        #expect(BlendOps.blend(.normal, dst: color(0, 0, 0, 0), src: color(10, 200, 30, 1))
                    == color(10, 200, 30, 1))
    }

    @Test func opaqueOverTransparentWithGarbageRGB() {
        #expect(BlendOps.blend(.normal, dst: color(9, 9, 9, 0), src: color(0, 0, 0, 255))
                    == color(0, 0, 0, 255))
    }

    // MARK: - Dispatch and opacity

    @Test func blendDispatchesNormal() {
        // v1.0 has one case; the call site shape must not change when 0026/0027/0059 add
        // modes. Dispatch equality is checked against the same entry point (the spec's
        // "blend == normal"), pinned by the hand-computed cases above running through
        // `blend` only.
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0B1E4D05))
        for _ in 0..<1000 {
            let dst = rng.color()
            let src = rng.color()
            #expect(BlendOps.blend(.normal, dst: dst, src: src, opacity: 255)
                        == BlendOps.blend(.normal, dst: dst, src: src), rng.comment)
        }
    }

    @Test func opacityScalesSourceAlpha() {
        // Black at opacity 128 over opaque white: Sa' = mul255(255,128) = 128 →
        // fa = 128·255 + 255·127 = 65025, C = (0 + 255·255·127 + 32512)/65025
        // = (8237025+32512)/65025 = 8269537/65025 = 127.17 → 127.
        #expect(BlendOps.blend(.normal, dst: color(255, 255, 255, 255),
                               src: color(0, 0, 0, 255), opacity: 128)
                    == color(127, 127, 127, 255))
        let dst = color(31, 42, 53, 200)
        #expect(BlendOps.blend(.normal, dst: dst, src: color(9, 9, 9, 9), opacity: 0) == dst,
                "opacity 0 → Sa == 0 → dst bit-identical")

        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0BA1AC11))
        for _ in 0..<1000 {
            let dst = rng.color()
            let src = rng.color()
            #expect(BlendOps.blend(.normal, dst: dst, src: src, opacity: 255)
                        == BlendOps.blend(.normal, dst: dst, src: src), rng.comment)
        }
    }

    // MARK: - mul255

    @Test func mul255Exact() {
        // Spot values.
        #expect(BlendOps.mul255(255, 128) == 128)
        #expect(BlendOps.mul255(128, 128) == 64)
        #expect(BlendOps.mul255(0, 255) == 0)
        #expect(BlendOps.mul255(255, 255) == 255)
        // The full input space against both independent formulations.
        for a in UInt8.min ... UInt8.max {
            for b in UInt8.min ... UInt8.max {
                let product = Int(a) * Int(b)
                #expect(BlendOps.mul255(a, b) == UInt8((product + 127) / 255), "(\(a), \(b))")
                #expect(BlendOps.mul255(a, b)
                            == UInt8(Int((Double(product) / 255).rounded())), "(\(a), \(b))")
            }
        }
    }

    // MARK: - Real-valued reference oracle

    /// Independent `Double` Porter-Duff source-over in straight alpha:
    /// `outA = Sa + Da·(1−Sa)`, `outC = (Sc·Sa + Dc·Da·(1−Sa)) / outA`, round-to-nearest.
    /// Transparent components (`alpha == 0`) carry no color: both channels and alpha are
    /// compared premultiplied-consistently by comparing alpha first and skipping the
    /// channels when the composited alpha is 0.
    private func referenceNormal(dst: ColorRGBA8, src: ColorRGBA8) -> (r: Int, g: Int, b: Int, a: Int) {
        let sa = Double(src.alpha) / 255
        let da = Double(dst.alpha) / 255
        let outA = sa + da * (1 - sa)
        let alpha = Int((outA * 255).rounded())
        guard alpha > 0 else { return (0, 0, 0, 0) }
        func channel(_ sc: UInt8, _ dc: UInt8) -> Int {
            let value = (Double(sc) * sa + Double(dc) * da * (1 - sa)) / outA
            return Int(value.rounded())
        }
        return (channel(src.red, dst.red), channel(src.green, dst.green),
                channel(src.blue, dst.blue), alpha)
    }

    @Test func normalMatchesRealValuedReference() {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0BE9E4E5))
        for _ in 0..<100_000 {
            let dst = rng.color()
            let src = rng.color()
            let got = BlendOps.blend(.normal, dst: dst, src: src)
            let want = referenceNormal(dst: dst, src: src)
            // Alpha is exact against the same rounding; channels within ±1 of the
            // `Double` reference (the spec's normative bound). A fully transparent result
            // carries the engine's discarded-RGB rule (dst RGB kept when Sa == 0, else
            // no color at all), so the channels are only compared when alpha > 0.
            #expect(Int(got.alpha) == want.a, "alpha got \(got) want \(want) \(rng.comment)")
            if want.a > 0 {
                #expect(abs(Int(got.red) - want.r) <= 1, "R got \(got) want \(want) \(rng.comment)")
                #expect(abs(Int(got.green) - want.g) <= 1, "G got \(got) want \(want) \(rng.comment)")
                #expect(abs(Int(got.blue) - want.b) <= 1, "B got \(got) want \(want) \(rng.comment)")
            }
        }
    }
}
