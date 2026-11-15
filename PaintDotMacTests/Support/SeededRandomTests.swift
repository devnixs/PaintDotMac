import Testing

@testable import PaintDotMac

struct SeededRandomTests {
    /// Published SplitMix64 reference values (checked by hand when writing the spec).
    @Test func splitMix64ReferenceValues() {
        var rng = SeededRandom(seed: 0)
        #expect(rng.next() == 0xE220_A839_7B1D_CDAF)
        #expect(rng.next() == 0x6E78_9E6A_A1B9_65F4)
        #expect(rng.next() == 0x06C4_5D18_8009_454F)
        var fortyTwo = SeededRandom(seed: 42)
        #expect(fortyTwo.next() == 0xBDD7_3226_2FEB_6E95)
        #expect(fortyTwo.next() == 0x28EF_E333_B266_F103)
    }

    @Test func resolvedSeedParsing() {
        #expect(SeededRandom.parseSeed("42") == 42)
        #expect(SeededRandom.parseSeed("0x2A") == 42)
        #expect(SeededRandom.parseSeed("zz") == nil)
        #expect(SeededRandom.parseSeed(nil) == nil)
        // The runner does not set the variable, so the default applies.
        #expect(SeededRandom.resolvedSeed(default: 7) == 7)
    }

    @Test func intStaysInRange() {
        var rng = SeededRandom(seed: 1)
        for _ in 0..<1_000 {
            #expect((-300...700).contains(rng.int(in: -300...700)))
        }
    }
}
