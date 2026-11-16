import Foundation
import Testing

@testable import PaintDotMac

/// `EraseOps.erase` (spec 0011 *Test plan*): Paint.NET's worked examples, the hand-computed
/// formula cases, and an exhaustive property sweep against an independent round-half-up
/// oracle written from the spec text.
struct EraseOpsTests {
    private func color(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> ColorRGBA8 {
        ColorRGBA8(red: r, green: g, blue: b, alpha: a)
    }

    @Test func docExamples() {
        // EraserTool.html on an opaque layer: alpha 60 → 255−60 = 195; 120 → 135; 255 → 0.
        #expect(EraseOps.erase(color(200, 100, 50, 255), strength: 60, coverage: 255)
                    == color(200, 100, 50, 195))
        #expect(EraseOps.erase(color(200, 100, 50, 255), strength: 120, coverage: 255)
                    == color(200, 100, 50, 135))
        #expect(EraseOps.erase(color(200, 100, 50, 255), strength: 255, coverage: 255)
                    == color(0, 0, 0, 0))
    }

    @Test func partialCoverage() {
        // e = 255 × 128 = 32640; newA = (255 × 32385 + 32512) / 65025 = 8290687 / 65025 = 127.
        #expect(EraseOps.erase(color(200, 100, 50, 255), strength: 255, coverage: 128)
                    == color(200, 100, 50, 127))
    }

    @Test func semiTransparentSource() {
        #expect(EraseOps.erase(color(10, 20, 30, 100), strength: 255, coverage: 255)
                    == color(0, 0, 0, 0))
        // e = 51 × 255 = 13005; newA = (100 × 52020 + 32512) / 65025 = 5234512 / 65025 = 80.
        #expect(EraseOps.erase(color(10, 20, 30, 100), strength: 51, coverage: 255)
                    == color(10, 20, 30, 80))
    }

    @Test func roundingBoundary() {
        // (1 × (65025 − 32640) + 32512) / 65025 = 64897 / 65025 = 0 → fully erased → black.
        #expect(EraseOps.erase(color(10, 20, 30, 1), strength: 128, coverage: 255)
                    == color(0, 0, 0, 0))
        // (1 × 32640 + 32512) / 65025 = 65152 / 65025 = 1 → unchanged.
        #expect(EraseOps.erase(color(10, 20, 30, 1), strength: 127, coverage: 255)
                    == color(10, 20, 30, 1))
    }

    @Test func zeroStrengthOrCoverageIsIdentity() {
        for p in [color(9, 99, 200, 255), color(1, 2, 3, 1), color(5, 6, 7, 0)] {
            #expect(EraseOps.erase(p, strength: 0, coverage: 255) == p, "e = 0 is identity")
            #expect(EraseOps.erase(p, strength: 255, coverage: 0) == p, "e = 0 is identity")
            // …including a pixel whose alpha is already 0 but whose RGB is not.
            #expect(EraseOps.erase(p, strength: 0, coverage: 0) == p)
        }
    }

    @Test func transparentStaysTransparent() {
        for strength in stride(from: UInt8(0), through: 255, by: 17) {
            #expect(EraseOps.erase(color(0, 0, 0, 0), strength: strength, coverage: 255)
                        == color(0, 0, 0, 0))
        }
    }

    /// Every alpha 0…255 against strengths {1, 60, 128, 254, 255} and coverages
    /// {1, 64, 128, 255} checked against the independent oracle
    /// `floor(a·(65025 − s·c)/65025 + 0.5)` (round-half-up; the numerator and denominator
    /// are exact integers in `Double` and an `n + 0.5` quotient is exactly representable,
    /// matching the spec's `+ 32512` integer form), plus the general properties: alpha
    /// never rises, RGB survives while alpha > 0, and alpha 0 means `(0, 0, 0, 0)`.
    @Test func exhaustiveAgainstOracle() {
        for alpha in UInt8(0) ... 255 {
            for strength in [UInt8(1), 60, 128, 254, 255] {
                for coverage in [UInt8(1), 64, 128, 255] {
                    let source = color(11, 222, 33, alpha)
                    let result = EraseOps.erase(source, strength: strength, coverage: coverage)
                    let product = Int(strength) * Int(coverage)
                    let oracle = Int((Double(Int(alpha) * (65025 - product)) / 65025.0
                                      + 0.5).rounded(.down))
                    #expect(Int(result.alpha) == oracle,
                            "a=\(alpha) s=\(strength) c=\(coverage)")
                    #expect(result.alpha <= alpha, "alpha never rises")
                    if result.alpha > 0 {
                        #expect(result.red == 11 && result.green == 222 && result.blue == 33,
                                "RGB untouched while alpha > 0")
                    } else {
                        #expect(result == color(0, 0, 0, 0), "fully erased → (0, 0, 0, 0)")
                    }
                }
            }
        }
    }
}
