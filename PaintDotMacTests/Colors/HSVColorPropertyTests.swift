import Testing

@testable import PaintDotMac

/// RGB → HSV → RGB is the identity for every 8-bit color (spec 0007 *Test plan*): the
/// rounding rule (half away from zero) and the sector ties are exactly what makes it hold,
/// so a mutation in either breaks this. Grid + corners are exhaustive-by-construction; the
/// random tail runs seeded with the seed printed on failure.
struct HSVColorPropertyTests {
    /// Every 5th value on each channel: 52³ = 140,608 colors.
    private static let gridStride = 5
    private static let randomCount = 100_000

    private func expectIdentity(_ color: ColorRGBA8, _ note: String, _ rng: SeededRandom) {
        let back = HSVColor(rgb: color).rgb(alpha: color.alpha)
        #expect(back == color, "\(note): \(color) → HSV → \(back) — \(rng.comment)")
    }

    @Test func rgbToHSVToRGBIsIdentity() {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x5EED_0701))

        for redValue in stride(from: 0, through: 255, by: Self.gridStride) {
            for greenValue in stride(from: 0, through: 255, by: Self.gridStride) {
                for blueValue in stride(from: 0, through: 255, by: Self.gridStride) {
                    expectIdentity(
                        ColorRGBA8(red: UInt8(redValue), green: UInt8(greenValue),
                                   blue: UInt8(blueValue), alpha: 255),
                        "grid", rng
                    )
                }
            }
        }

        // The corners and the extremes: mx == 0, d == 0, every sector boundary.
        let corners: [ColorRGBA8] = [
            .black, .white, .clear,
            ColorRGBA8(red: 255, green: 0, blue: 0),
            ColorRGBA8(red: 0, green: 255, blue: 0),
            ColorRGBA8(red: 0, green: 0, blue: 255),
            ColorRGBA8(red: 255, green: 255, blue: 0),
            ColorRGBA8(red: 0, green: 255, blue: 255),
            ColorRGBA8(red: 255, green: 0, blue: 255),
            ColorRGBA8(red: 1, green: 0, blue: 0),
            ColorRGBA8(red: 0, green: 1, blue: 0),
            ColorRGBA8(red: 0, green: 0, blue: 1),
            ColorRGBA8(red: 255, green: 128, blue: 0),
            ColorRGBA8(red: 128, green: 255, blue: 127),
            ColorRGBA8(red: 1, green: 255, blue: 254),
            ColorRGBA8(red: 254, green: 1, blue: 255),
        ]
        for corner in corners { expectIdentity(corner, "corner", rng) }

        for _ in 0..<Self.randomCount { expectIdentity(rng.color(), "random", rng) }
    }
}
