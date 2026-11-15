import Testing

@testable import PaintDotMac

struct ColorRGBA8Tests {
    @Test func constants() {
        #expect(ColorRGBA8.clear == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0))
        #expect(ColorRGBA8.black == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255))
        #expect(ColorRGBA8.white == ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255))
        #expect(ColorRGBA8(red: 1, green: 2, blue: 3).alpha == 255)
        #expect(ColorRGBA8.clear.isTransparent)
        #expect(!ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 1).isTransparent)
    }

    @Test func unpremultiplyExamples() {
        #expect(ColorRGBA8.unpremultiply(50, alpha: 100) == 128)   // 127.5 rounds up
        #expect(ColorRGBA8.unpremultiply(25, alpha: 100) == 64)    // 63.75
        #expect(ColorRGBA8.unpremultiply(0, alpha: 0) == 0)
        #expect(ColorRGBA8.unpremultiply(200, alpha: 0) == 0)
        #expect(ColorRGBA8.unpremultiply(255, alpha: 255) == 255)
        #expect(ColorRGBA8.unpremultiply(1, alpha: 1) == 255)
        #expect(ColorRGBA8.unpremultiply(200, alpha: 100) == 255)  // clamp invalid input
        #expect(ColorRGBA8.unpremultiply(127, alpha: 255) == 127)
        #expect(ColorRGBA8.unpremultiply(64, alpha: 128) == 128)   // 127.5 → 128
    }

    /// Double oracle for the round-half-up rule, checked for all 65,536 inputs.
    @Test func unpremultiplyMatchesFormulaExhaustively() {
        for alphaValue in 0...255 {
            for componentValue in 0...255 {
                let component = UInt8(componentValue)
                let alpha = UInt8(alphaValue)
                let raw = alpha == 0
                    ? 0
                    : min(255, Int((Double(component) * 255 / Double(alpha) + 0.5).rounded(.down)))
                let expected = UInt8(clamping: raw)
                #expect(ColorRGBA8.unpremultiply(component, alpha: alpha) == expected,
                        "unpremultiply(\(component), alpha: \(alpha))")
            }
        }
    }

    @Test func unpremultipliedColor() {
        #expect(ColorRGBA8(red: 50, green: 25, blue: 0, alpha: 100).unpremultiplied()
                == ColorRGBA8(red: 128, green: 64, blue: 0, alpha: 100))
        #expect(ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 0).unpremultiplied() == .clear)
    }
}
