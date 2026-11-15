import Testing

@testable import PaintDotMac

/// Hex parsing and formatting per spec 0007 (C-2): CSS order `RRGGBB` / `RRGGBBAA`,
/// case-insensitive, whitespace-trimmed, nothing else accepted.
struct ColorHexTests {
    private func color(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int = 255) -> ColorRGBA8 {
        ColorRGBA8(red: UInt8(red), green: UInt8(green), blue: UInt8(blue), alpha: UInt8(alpha))
    }

    @Test func parsesSixDigits() {
        let parsed = ColorHex.Parsed(red: 51, green: 102, blue: 204, alpha: nil)
        #expect(ColorHex.parse("#3366CC") == parsed)
        #expect(ColorHex.parse("3366cc") == parsed)
        #expect(ColorHex.parse("  #3366Cc\n") == parsed)
        #expect(ColorHex.parse("#ffffff") == ColorHex.Parsed(red: 255, green: 255, blue: 255,
                                                            alpha: nil))
    }

    @Test func parsesEightDigits() {
        #expect(ColorHex.parse("#3366CC80")
                == ColorHex.Parsed(red: 51, green: 102, blue: 204, alpha: 128))
        #expect(ColorHex.parse("00000000")
                == ColorHex.Parsed(red: 0, green: 0, blue: 0, alpha: 0))
        #expect(ColorHex.parse("FFFFFFFF")
                == ColorHex.Parsed(red: 255, green: 255, blue: 255, alpha: 255))
    }

    @Test func rejectsInvalid() {
        let invalid: [String] = [
            "",
            "#",
            "#FFF",          // 3-digit CSS shorthand is not accepted
            "#FFFF",         // 4-digit shorthand either
            "#FFFFF",
            "#FFFFFFF",
            "#FFFFFFFFF",
            "#GG0000",
            "GGGGGG",
            "0x3366CC",      // no C-style prefix
            "#33 66CC",      // no inner spaces
            "33 66 CC",
            "3366CC 80",
            "##3366CC",      // one optional leading # only
            "#３３６６ＣＣ",  // full-width digits
            "＃3366CC",      // a full-width number sign is not a leading #
            "#3366CC8G",     // 8 characters, one not a hex digit
            "-3366CC8",
            "3366CC80.0",
        ]
        for text in invalid {
            #expect(ColorHex.parse(text) == nil, "must reject \(text.debugDescription)")
        }
    }

    @Test func formats() {
        #expect(ColorHex.format(.black, includeAlpha: true) == "#000000FF")
        #expect(ColorHex.format(.black, includeAlpha: false) == "#000000")
        #expect(ColorHex.format(.white, includeAlpha: true) == "#FFFFFFFF")
        #expect(ColorHex.format(.clear, includeAlpha: true) == "#00000000")
        let low = color(10, 11, 255, 1)
        #expect(ColorHex.format(low, includeAlpha: false) == "#0A0BFF")
        #expect(ColorHex.format(low, includeAlpha: true) == "#0A0BFF01")
    }

    @Test func displayStringDependsOnAlpha() {
        #expect(ColorHex.displayString(color(51, 102, 204, 255)) == "#3366CC")
        #expect(ColorHex.displayString(color(51, 102, 204, 128)) == "#3366CC80")
        #expect(ColorHex.displayString(color(51, 102, 204, 0)) == "#3366CC00")
    }

    @Test func formatParseRoundTrip() {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x5EED_0702))
        for _ in 0..<10_000 {
            let color = rng.color()
            let text = ColorHex.format(color, includeAlpha: true)
            let parsed = ColorHex.parse(text)
            #expect(parsed?.red == color.red && parsed?.green == color.green
                    && parsed?.blue == color.blue && parsed?.alpha == color.alpha,
                    "\(text) must parse back to \(color) — \(rng.comment)")
        }
    }
}
