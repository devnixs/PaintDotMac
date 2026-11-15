import Testing

@testable import PaintDotMac

/// HSV ↔ RGB per spec 0007's formulas. Every expected value is hand-computed from those
/// formulas (never produced by the code under test).
struct HSVColorTests {
    @Test func rgbToHSVPrimaries() {
        let cases: [(ColorRGBA8, Double, Double, Double)] = [
            (ColorRGBA8(red: 255, green: 0, blue: 0), 0, 100, 100),
            (ColorRGBA8(red: 0, green: 255, blue: 0), 120, 100, 100),
            (ColorRGBA8(red: 0, green: 0, blue: 255), 240, 100, 100),
            (ColorRGBA8(red: 255, green: 255, blue: 0), 60, 100, 100),
            (ColorRGBA8(red: 0, green: 255, blue: 255), 180, 100, 100),
            (ColorRGBA8(red: 255, green: 0, blue: 255), 300, 100, 100),
        ]
        for (color, hue, saturation, value) in cases {
            let got = HSVColor(rgb: color)
            expectClose(got.hue, hue, message: "\(color) hue")
            expectClose(got.saturation, saturation, message: "\(color) saturation")
            expectClose(got.value, value, message: "\(color) value")
        }
    }

    @Test func rgbToHSVGraysAndBlack() {
        let black = HSVColor(rgb: .black)
        #expect(black.hue == 0 && black.saturation == 0 && black.value == 0)
        let white = HSVColor(rgb: .white)
        #expect(white.hue == 0 && white.saturation == 0 && white.value == 100)
        let gray = HSVColor(rgb: ColorRGBA8(red: 128, green: 128, blue: 128))
        #expect(gray.hue == 0, "a gray reports hue 0; the editor's cache keeps the real hue")
        #expect(gray.saturation == 0)
        expectClose(gray.value, 50.19607843137255, message: "gray 128 value")  // 128 / 255 × 100
    }

    @Test func rgbToHSVNonIntegerHue() {
        let orange = HSVColor(rgb: ColorRGBA8(red: 255, green: 128, blue: 0))
        expectClose(orange.hue, 30.11764705882353, message: "orange hue")  // 60 × 128 / 255
        #expect(orange.saturation == 100)
        #expect(orange.value == 100)

        let pink = HSVColor(rgb: ColorRGBA8(red: 255, green: 0, blue: 128))
        // 60 × (−128/255) + 360
        expectClose(pink.hue, 329.88235294117646, message: "pink hue")

        // (51,102,204): d = 153, mx = 204 → 60 × ((51 − 102)/153 + 4).
        let blue = HSVColor(rgb: ColorRGBA8(red: 51, green: 102, blue: 204))
        expectClose(blue.hue, 220, message: "blue hue")
        expectClose(blue.saturation, 75, message: "blue saturation")  // 153 / 204 × 100
        expectClose(blue.value, 80, message: "blue value")            // 204 / 255 × 100
    }

    /// `init(rgb:)` ignores alpha; `rgb(alpha:)` is the only place alpha enters.
    @Test func alphaIsIgnoredOnReadAndPassedThroughOnWrite() {
        let color = ColorRGBA8(red: 51, green: 102, blue: 204, alpha: 17)
        #expect(HSVColor(rgb: color) == HSVColor(rgb: ColorRGBA8(red: 51, green: 102, blue: 204)))
        #expect(HSVColor(rgb: color).rgb(alpha: 77).alpha == 77)
        #expect(HSVColor(hue: 220, saturation: 75, value: 80).rgb(alpha: 0).alpha == 0)
    }

    @Test func hsvToRGBExactSectors() {
        // Sector 3 (hue 210): c 0.4, x 0.2, m 0.4 → (102, 153, 204).
        #expect(HSVColor(hue: 210, saturation: 50, value: 80).rgb(alpha: 255)
                == ColorRGBA8(red: 102, green: 153, blue: 204))
        // Sector 3 (hue 220): c 0.6, x 0.2, m 0.2 → (51, 102, 204).
        #expect(HSVColor(hue: 220, saturation: 75, value: 80).rgb(alpha: 255)
                == ColorRGBA8(red: 51, green: 102, blue: 204))
        // Sector 1 (hue 60): c 0.5, x 0.5, m 0.5 → (255, 255, 127.5 → 128).
        #expect(HSVColor(hue: 60, saturation: 50, value: 100).rgb(alpha: 255)
                == ColorRGBA8(red: 255, green: 255, blue: 128))
        // Sector 5 (hue 300): c 1, x 0, m 0 → (255, 0, 255).
        #expect(HSVColor(hue: 300, saturation: 100, value: 100).rgb(alpha: 255)
                == ColorRGBA8(red: 255, green: 0, blue: 255))
        // Sector 2 (hue 120): c 0.5, x 0, m 0.5 → (128, 255, 128).
        #expect(HSVColor(hue: 120, saturation: 50, value: 100).rgb(alpha: 255)
                == ColorRGBA8(red: 128, green: 255, blue: 128))
        // Sector 4 (hue 240): c 0.5, x 0, m 0.5 → (128, 128, 255).
        #expect(HSVColor(hue: 240, saturation: 50, value: 100).rgb(alpha: 255)
                == ColorRGBA8(red: 128, green: 128, blue: 255))
        // Sector 0 (hue 0): c 0.5, x 0, m 0.5 → (255, 128, 128).
        #expect(HSVColor(hue: 0, saturation: 50, value: 100).rgb(alpha: 255)
                == ColorRGBA8(red: 255, green: 128, blue: 128))
    }

    @Test func hsvToRGBRoundsHalfAwayFromZero() {
        // Hue 30: green = (0.5 + 0) × 255 = 127.5 → 128, never 127.
        #expect(HSVColor(hue: 30, saturation: 100, value: 100).rgb(alpha: 255)
                == ColorRGBA8(red: 255, green: 128, blue: 0))
        // Value 50: red = 0.5 × 255 = 127.5 → 128.
        #expect(HSVColor(hue: 0, saturation: 100, value: 50).rgb(alpha: 255)
                == ColorRGBA8(red: 128, green: 0, blue: 0))
    }

    @Test func hsvToRGBEdges() {
        let red = ColorRGBA8(red: 255, green: 0, blue: 0)
        let blue = ColorRGBA8(red: 0, green: 0, blue: 255)
        #expect(HSVColor(hue: 360, saturation: 100, value: 100).rgb(alpha: 255) == red)
        // 359.9 stays in sector 5, and its blue term is 0.0016663 × 255 → 0.
        #expect(HSVColor(hue: 359.9, saturation: 100, value: 100).rgb(alpha: 255) == red)
        #expect(HSVColor(hue: -120, saturation: 100, value: 100).rgb(alpha: 255) == blue)
        #expect(HSVColor(hue: 220, saturation: 0, value: 100).rgb(alpha: 255) == .white)
        #expect(HSVColor(hue: 220, saturation: 75, value: 0).rgb(alpha: 255) == .black)
        // Non-finite inputs normalize; out-of-range S/V clamp (C-2 never traps).
        #expect(HSVColor(hue: .nan, saturation: 100, value: 100).rgb(alpha: 255) == red)
        #expect(HSVColor(hue: .infinity, saturation: 100, value: 100).rgb(alpha: 255) == red)
        #expect(HSVColor(hue: 0, saturation: 150, value: 100).rgb(alpha: 255) == red)
        #expect(HSVColor(hue: 0, saturation: 100, value: -5).rgb(alpha: 255) == .black)
    }

    @Test func initNormalizesComponents() {
        expectClose(HSVColor(hue: 480, saturation: 50, value: 50).hue, 120, message: "480°")
        expectClose(HSVColor(hue: -30, saturation: 0, value: 0).hue, 330, message: "−30°")
        let clamped = HSVColor(hue: 0, saturation: 150, value: -20)
        #expect(clamped.saturation == 100)
        #expect(clamped.value == 0)
        let nan = HSVColor(hue: .nan, saturation: .nan, value: .nan)
        #expect(nan == HSVColor(hue: 0, saturation: 0, value: 0))
    }

    @Test func displayValuesRound() {
        #expect(HSVColor(hue: 359.6, saturation: 0, value: 0).displayHue == 360)
        #expect(HSVColor(hue: 30.1176, saturation: 0, value: 0).displayHue == 30)
        #expect(HSVColor(hue: 0, saturation: 0, value: 50.196).displayValue == 50)
        #expect(HSVColor(hue: 0, saturation: 12.5, value: 0).displaySaturation == 13)
    }
}
