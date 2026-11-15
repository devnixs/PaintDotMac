import Testing
@testable import PaintDotMac

/// The checkerboard (spec 0003, CAN-4). All expectations hand-computed: 8-pt squares,
/// #FFFFFF/#CCCCCC, top-left light, `floor` so negative offsets alternate.
struct CheckerboardStyleTests {
    private let style = CheckerboardStyle.standard
    private let white = ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255)
    private let gray = ColorRGBA8(red: 204, green: 204, blue: 204, alpha: 255)

    @Test func standardStyleMatchesPaintNet() {
        #expect(style.squareSize == 8)
        #expect(style.lightColor == white)
        #expect(style.darkColor == gray)
    }

    @Test func oneXAnchoredAtOrigin() {
        func color(_ x: Int, _ y: Int, origin: (x: Int, y: Int) = (0, 0), scale: Double = 1) -> ColorRGBA8 {
            style.color(deviceX: x, deviceY: y, imageOrigin: origin, backingScale: scale)
        }
        #expect(color(0, 0) == white)   // top-left square is light
        #expect(color(7, 7) == white)   // still inside square (0, 0)
        #expect(color(8, 0) == gray)    // first dark square
        #expect(color(0, 8) == gray)    // first dark square (vertical)
        #expect(color(8, 8) == white)   // (1 + 1) even → light
    }

    @Test func twoXSquaresAreSixteenDevicePixels() {
        #expect(style.color(deviceX: 15, deviceY: 0, imageOrigin: (0, 0), backingScale: 2) == white)
        #expect(style.color(deviceX: 16, deviceY: 0, imageOrigin: (0, 0), backingScale: 2) == gray)
    }

    @Test func anchoredToImageOriginIncludingNegativeOffsets() {
        // Origin (5, 3): (5, 3) is the light square's top-left; (13, 3) is i = 1 → dark;
        // (4, 3) is i = floor(−1/8) = −1 → odd → dark (floor, not truncation).
        #expect(style.color(deviceX: 5, deviceY: 3, imageOrigin: (5, 3), backingScale: 1) == white)
        #expect(style.color(deviceX: 13, deviceY: 3, imageOrigin: (5, 3), backingScale: 1) == gray)
        #expect(style.color(deviceX: 4, deviceY: 3, imageOrigin: (5, 3), backingScale: 1) == gray)
    }

    @Test func shiftingOriginByOneSquareFlipsColor() {
        let before = style.color(deviceX: 100, deviceY: 100, imageOrigin: (0, 0), backingScale: 1)
        let after = style.color(deviceX: 100, deviceY: 100, imageOrigin: (8, 0), backingScale: 1)
        #expect(before != after)
    }
}
