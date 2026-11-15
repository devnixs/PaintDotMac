import Testing

@testable import PaintDotMac

/// The two color slots (C-1): defaults, swap, reset, subscript, and `ColorSlot.other`.
struct ColorSelectionTests {
    private func color(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int = 255) -> ColorRGBA8 {
        ColorRGBA8(red: UInt8(red), green: UInt8(green), blue: UInt8(blue), alpha: UInt8(alpha))
    }

    @Test func defaultsAreBlackAndWhite() {
        #expect(ColorSelection.defaultPrimary == .black)
        #expect(ColorSelection.defaultSecondary == .white)
        #expect(ColorSelection.default.primary == .black)
        #expect(ColorSelection.default.secondary == .white)
    }

    @Test func swapExchangesSlots() {
        var selection = ColorSelection(primary: color(51, 102, 204), secondary: color(10, 20, 30, 7))
        selection.swap()
        #expect(selection.primary == color(10, 20, 30, 7))
        #expect(selection.secondary == color(51, 102, 204))
        selection.swap()
        #expect(selection == ColorSelection(primary: color(51, 102, 204),
                                           secondary: color(10, 20, 30, 7)),
                "swapping twice is the identity")
    }

    @Test func resetRestoresDefaults() {
        var selection = ColorSelection(primary: color(51, 102, 204, 100),
                                      secondary: color(255, 0, 0, 33))
        selection.reset()
        #expect(selection.primary == .black, "reset is opaque black, whatever the alpha was")
        #expect(selection.secondary == .white)
        var alreadyDefault = ColorSelection.default
        alreadyDefault.reset()
        #expect(alreadyDefault == .default)
    }

    @Test func subscriptReadsAndWrites() {
        var selection = ColorSelection.default
        #expect(selection[.primary] == .black)
        #expect(selection[.secondary] == .white)
        selection[.primary] = color(51, 102, 204, 128)
        #expect(selection[.primary] == color(51, 102, 204, 128))
        #expect(selection.primary == color(51, 102, 204, 128))
        selection[.secondary] = .clear
        #expect(selection.secondary == .clear)
    }

    @Test func slotOther() {
        #expect(ColorSlot.primary.other == .secondary)
        #expect(ColorSlot.secondary.other == .primary)
        #expect(ColorSlot.allCases == [.primary, .secondary])
        #expect(ColorSlot.primary.rawValue == "primary")
        #expect(ColorSlot.secondary.rawValue == "secondary")
    }
}
