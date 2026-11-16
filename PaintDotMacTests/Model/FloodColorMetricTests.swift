import Testing

@testable import PaintDotMac

/// `FloodColorMetric` — Paint.NET 3.36's `CheckColor` sum, checked against the exact
/// numbers hand-computed in spec 0016, plus a seeded sweep against an independent
/// `Int32` transcription of the C# source (Pinta 1.6 `FloodTool.cs`, which ports
/// `FloodToolBase.CheckColor` verbatim).
struct FloodColorMetricTests {
    private func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> ColorRGBA8 {
        ColorRGBA8(red: UInt8(r), green: UInt8(g), blue: UInt8(b), alpha: UInt8(a))
    }

    /// A test-local transcription of the C# `CheckColor`, written from the cited
    /// Paint.NET formula with `Int32` arithmetic and C#'s `tol` computation — never
    /// derived from the code under test.
    private func checkColor(a: ColorRGBA8, b: ColorRGBA8, percent: Int) -> Bool {
        func term(_ x: Int32, _ y: Int32, _ weight: Int32) -> Int32 {
            let diff = x &- y
            return (1 &+ diff &* diff) &* weight / Int32(256)
        }
        let aR = Int32(a.red), aG = Int32(a.green), aB = Int32(a.blue), aA = Int32(a.alpha)
        var sum = term(aR, Int32(b.red), aA)
        sum &+= term(aG, Int32(b.green), aA)
        sum &+= term(aB, Int32(b.blue), aA)
        let diffA = aA &- Int32(b.alpha)
        sum &+= diffA &* diffA
        let t = Float(percent) / Float(100)
        let tol = Int32(t * t * Float(256))
        return sum <= tol &* tol &* Int32(4)
    }

    @Test func identicalIsZero() {
        let gray = rgba(100, 100, 100, 255)
        #expect(FloodColorMetric.distance(seed: gray, candidate: gray) == 0)
        #expect(FloodColorMetric.distance(seed: .clear, candidate: .clear) == 0)
        #expect(FloodColorMetric.matches(seed: gray, candidate: gray,
                                         tolerance: FloodTolerance(percent: 0)))
    }

    @Test func oneStepFailsAtZero() {
        let seed = rgba(100, 100, 100, 255)
        // ⌊2 · 255 / 256⌋ = 1.
        #expect(FloodColorMetric.distance(seed: seed, candidate: rgba(101, 100, 100, 255)) == 1)
        #expect(FloodColorMetric.distance(seed: seed, candidate: rgba(100, 100, 100, 254)) == 1)
        #expect(!FloodColorMetric.matches(seed: seed, candidate: rgba(101, 100, 100, 255),
                                          tolerance: FloodTolerance(percent: 0)))
        #expect(!FloodColorMetric.matches(seed: seed, candidate: rgba(100, 100, 100, 254),
                                          tolerance: FloodTolerance(percent: 0)))
    }

    @Test func fiftyPercentBoundary() {
        let seed = rgba(0, 50, 50, 255)
        // R = 128: ⌊16385 · 255 / 256⌋ = 16320 ≤ 16384 → match.
        #expect(FloodColorMetric.distance(seed: seed, candidate: rgba(128, 50, 50, 255)) == 16320)
        #expect(FloodColorMetric.matches(seed: seed, candidate: rgba(128, 50, 50, 255),
                                         tolerance: FloodTolerance(percent: 50)))
        // R = 129: ⌊16642 · 255 / 256⌋ = 16576 > 16384 → no match.
        #expect(FloodColorMetric.distance(seed: seed, candidate: rgba(129, 50, 50, 255)) == 16576)
        #expect(!FloodColorMetric.matches(seed: seed, candidate: rgba(129, 50, 50, 255),
                                          tolerance: FloodTolerance(percent: 50)))
    }

    @Test func transparentSeedIgnoresRGB() {
        let seed = ColorRGBA8.clear
        #expect(FloodColorMetric.distance(seed: seed, candidate: rgba(255, 255, 255, 0)) == 0)
        #expect(FloodColorMetric.matches(seed: seed, candidate: rgba(255, 255, 255, 0),
                                         tolerance: FloodTolerance(percent: 0)))
        let opaqueWhite = rgba(255, 255, 255, 255)
        #expect(FloodColorMetric.distance(seed: seed, candidate: opaqueWhite) == 65025)
        #expect(!FloodColorMetric.matches(seed: seed, candidate: opaqueWhite,
                                          tolerance: FloodTolerance(percent: 50)))
        #expect(FloodColorMetric.matches(seed: seed, candidate: opaqueWhite,
                                         tolerance: FloodTolerance(percent: 100)))
    }

    @Test func extremesAtHundred() {
        // 3 × ⌊65026 · 255 / 256⌋ + 255² = 3 × 64771 + 65025 = 259338.
        let white = rgba(255, 255, 255, 255)
        let clear = ColorRGBA8.clear
        #expect(FloodColorMetric.distance(seed: white, candidate: clear) == 259338)
        #expect(!FloodColorMetric.matches(seed: white, candidate: clear,
                                          tolerance: FloodTolerance(percent: 99)))
        #expect(FloodColorMetric.matches(seed: white, candidate: clear,
                                         tolerance: FloodTolerance(percent: 100)))
    }

    @Test func semiTransparentWeighting() {
        // ⌊10001 · 128 / 256⌋ = 5000.
        let seed = rgba(100, 0, 0, 128)
        let candidate = rgba(0, 0, 0, 128)
        #expect(FloodColorMetric.distance(seed: seed, candidate: candidate) == 5000)
        #expect(FloodColorMetric.matches(seed: seed, candidate: candidate,
                                         tolerance: FloodTolerance(percent: 50)))
        #expect(!FloodColorMetric.matches(seed: seed, candidate: candidate,
                                          tolerance: FloodTolerance(percent: 25)))
    }

    @Test func asymmetry() {
        // The seed's alpha weights the RGB terms — swapping seed/candidate changes
        // the distance.
        let blackOpaque = rgba(0, 0, 0, 255)
        let redSemi = rgba(255, 0, 0, 128)
        #expect(FloodColorMetric.distance(seed: blackOpaque, candidate: redSemi) == 80900)
        #expect(!FloodColorMetric.matches(seed: blackOpaque, candidate: redSemi,
                                          tolerance: FloodTolerance(percent: 70)))
        #expect(FloodColorMetric.distance(seed: redSemi, candidate: blackOpaque) == 48642)
        #expect(FloodColorMetric.matches(seed: redSemi, candidate: blackOpaque,
                                         tolerance: FloodTolerance(percent: 70)))
    }

    @Test func oracleSweep() {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0016_CE01))
        let comment = rng.comment
        let percents = [0, 1, 13, 50, 87, 100]
        for _ in 0..<10_000 {
            let seed = rng.color()
            let candidate = rng.color()
            for percent in percents {
                #expect(FloodColorMetric.matches(seed: seed, candidate: candidate,
                                                 tolerance: FloodTolerance(percent: percent))
                            == checkColor(a: seed, b: candidate, percent: percent),
                        "seed \(seed) candidate \(candidate) at \(percent) % — \(comment)")
            }
        }
    }
}
