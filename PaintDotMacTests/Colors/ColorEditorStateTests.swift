import Testing

@testable import PaintDotMac

/// The pure editing model behind the Colors panel (C-1, C-2): channel edits, the per-slot HSV
/// cache that keeps the hue alive through grays and black, hex, and wheel input. Expected
/// values are hand-computed from spec 0007's formulas.
struct ColorEditorStateTests {
    private func color(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int = 255) -> ColorRGBA8 {
        ColorRGBA8(red: UInt8(red), green: UInt8(green), blue: UInt8(blue), alpha: UInt8(alpha))
    }

    /// Primary black / secondary white unless stated.
    private func state(primary: ColorRGBA8 = .black, secondary: ColorRGBA8 = .white)
        -> ColorEditorState {
        ColorEditorState(selection: ColorSelection(primary: primary, secondary: secondary))
    }

    /// Primary (51,102,204): cache 220 / 75 / 80; secondary white: 0 / 0 / 100.
    private func stateWithBluePrimary() -> ColorEditorState {
        state(primary: color(51, 102, 204))
    }

    /// The editor always keeps a cache entry for both slots.
    private func cache(_ editor: ColorEditorState, _ slot: ColorSlot) throws -> HSVColor {
        try #require(editor.hsv[slot], "no cache for \(slot)")
    }

    @Test func initComputesCaches() throws {
        let fresh = state()
        #expect(fresh.hsv[.primary] == HSVColor(hue: 0, saturation: 0, value: 0))
        #expect(fresh.hsv[.secondary] == HSVColor(hue: 0, saturation: 0, value: 100))

        let blue = stateWithBluePrimary()
        expectClose(try cache(blue, .primary).hue, 220, message: "hue cache")
        expectClose(try cache(blue, .primary).saturation, 75, message: "saturation cache")
        expectClose(try cache(blue, .primary).value, 80, message: "value cache")
        #expect(blue.selection == ColorSelection(primary: color(51, 102, 204), secondary: .white))
    }

    @Test func activeSlotDefaultsToPrimary() {
        #expect(state().activeSlot == .primary)
        #expect(state(secondary: .clear).activeSlot == .primary)
    }

    @Test func valueReadsBothSlotsAndDefaultsToTheActiveOne() {
        var editor = stateWithBluePrimary()
        #expect(editor.value(of: .red) == 51)
        #expect(editor.value(of: .green) == 102)
        #expect(editor.value(of: .blue) == 204)
        #expect(editor.value(of: .hue) == 220)
        #expect(editor.value(of: .saturation) == 75)
        #expect(editor.value(of: .value) == 80)
        #expect(editor.value(of: .alpha) == 255)
        #expect(editor.value(of: .red, slot: .secondary) == 255)
        #expect(editor.value(of: .value, slot: .secondary) == 100)
        editor.switchActiveSlot()
        #expect(editor.value(of: .red) == 255, "with no explicit slot, the active slot is read")
    }

    @Test func setRGBChannel() {
        var editor = state()
        editor.set(.red, to: 255)
        #expect(editor.selection.primary == color(255, 0, 0))
        // Re-synced from RGB: (255,0,0) is hue 0, S 100, V 100.
        #expect(editor.value(of: .hue) == 0)
        #expect(editor.value(of: .saturation) == 100)
        #expect(editor.value(of: .value) == 100)
    }

    @Test func setClampsToRange() {
        var overflowing = stateWithBluePrimary()
        overflowing.set(.red, to: 300)
        #expect(overflowing.selection.primary == color(255, 102, 204))
        #expect(overflowing.value(of: .red) == 255)

        // Hue clamps to its range's 360, which is hue 0: HSV(0, 75, 80) → (204, 51, 51).
        var hue = stateWithBluePrimary()
        hue.set(.hue, to: 400)
        #expect(hue.value(of: .hue) == 0)
        #expect(hue.selection.primary == color(204, 51, 51))

        var negative = stateWithBluePrimary()
        negative.set(.saturation, to: -20)
        #expect(negative.value(of: .saturation) == 0)
        #expect(negative.selection.primary == color(204, 204, 204))
    }

    @Test func setHSVChannels() {
        var editor = stateWithBluePrimary()
        editor.set(.hue, to: 0)  // h 0, s 75, v 80: c 0.6, x 0, m 0.2
        #expect(editor.selection.primary == color(204, 51, 51))
        editor.set(.value, to: 100)  // c 0.75, m 0.25 → 63.75 → 64
        #expect(editor.selection.primary == color(255, 64, 64))
        #expect(editor.value(of: .value) == 100)
        editor.set(.saturation, to: 100)  // h 0, s 100, v 100
        #expect(editor.selection.primary == color(255, 0, 0))
    }

    @Test func hueSurvivesZeroSaturation() {
        var editor = stateWithBluePrimary()
        editor.set(.saturation, to: 0)
        #expect(editor.selection.primary == color(204, 204, 204))
        #expect(editor.value(of: .hue) == 220, "the cache holds the hue across a gray")
        editor.set(.saturation, to: 75)
        #expect(editor.selection.primary == color(51, 102, 204))
    }

    @Test func hueAndSaturationSurviveBlack() {
        var editor = state()
        editor.set(.hue, to: 120)
        #expect(editor.selection.primary == .black, "value 0 stays black")
        #expect(editor.value(of: .hue) == 120)
        editor.set(.saturation, to: 100)
        #expect(editor.selection.primary == .black)
        #expect(editor.value(of: .saturation) == 100)
        editor.set(.value, to: 100)
        #expect(editor.selection.primary == color(0, 255, 0), "raising value revives the hue")
    }

    @Test func externalGrayKeepsHue() throws {
        var gray = stateWithBluePrimary()
        gray.setColor(color(128, 128, 128), for: .primary)
        #expect(gray.value(of: .hue) == 220, "an external gray keeps the cached hue")
        #expect(gray.value(of: .saturation) == 0)
        expectClose(try cache(gray, .primary).value, 50.19607843137255, message: "gray value")

        var black = stateWithBluePrimary()
        black.setColor(.black, for: .primary)
        // Value 0 keeps both hue and saturation; only value drops.
        #expect(black.hsv[.primary] == HSVColor(hue: 220, saturation: 75, value: 0))
    }

    @Test func alphaEditDoesNotTouchHSV() {
        var editor = stateWithBluePrimary()
        let before = editor.hsv
        editor.set(.alpha, to: 10)
        #expect(editor.selection.primary == color(51, 102, 204, 10))
        #expect(editor.value(of: .alpha) == 10)
        #expect(editor.hsv == before, "alpha never disturbs the HSV cache")
        editor.set(.alpha, to: 0)
        #expect(editor.selection.primary
                == ColorRGBA8(red: 51, green: 102, blue: 204, alpha: 0))
    }

    @Test func applyHexSixDigitsKeepsAlpha() {
        var editor = state(primary: color(0, 0, 0, 100))
        let accepted = editor.applyHex("#FF0000")
        #expect(accepted)
        #expect(editor.selection.primary == color(255, 0, 0, 100))
        #expect(editor.hsv[.primary] == HSVColor(hue: 0, saturation: 100, value: 100))
    }

    @Test func applyHexEightDigitsSetsAlpha() {
        var editor = state()
        let accepted = editor.applyHex("#00FF0080")
        #expect(accepted)
        #expect(editor.selection.primary == color(0, 255, 0, 128))
        #expect(editor.value(of: .alpha) == 128)
    }

    @Test func applyHexInvalidIsNoOp() {
        var editor = stateWithBluePrimary()
        let before = editor
        let rejectedWord = editor.applyHex("nope")
        #expect(!rejectedWord)
        #expect(editor == before)
        let rejectedEmpty = editor.applyHex("")
        let rejectedShort = editor.applyHex("#12345")
        #expect(!rejectedEmpty)
        #expect(!rejectedShort)
        #expect(editor == before)
    }

    @Test func applyHexEditsTheActiveSlotOnly() {
        var editor = stateWithBluePrimary()
        editor.switchActiveSlot()
        let accepted = editor.applyHex("#00FF00")
        #expect(accepted)
        #expect(editor.selection.secondary == color(0, 255, 0))
        #expect(editor.selection.primary == color(51, 102, 204))
    }

    @Test func editsTargetActiveSlotOnly() {
        var editor = state(primary: color(51, 102, 204))
        editor.switchActiveSlot()
        editor.set(.red, to: 0)
        #expect(editor.selection.secondary == color(0, 255, 255))
        #expect(editor.selection.primary == color(51, 102, 204), "the other slot is untouched")
    }

    @Test func applyWheelOnBlackSetsValue100() {
        var editor = state()
        editor.applyWheel(hue: 0, saturation: 100, to: .primary)
        #expect(editor.selection.primary == color(255, 0, 0),
                "clicking the wheel on the default black yields the clicked color")
        #expect(editor.hsv[.primary]?.value == 100)
    }

    @Test func applyWheelKeepsAnExistingValue() {
        // White's cache is value 100: h 120, s 50 → c 0.5, x 0, m 0.5 → (127.5, 255, 127.5).
        var editor = state()
        editor.applyWheel(hue: 120, saturation: 50, to: .secondary)
        #expect(editor.selection.secondary == color(128, 255, 128))
    }

    @Test func applyWheelKeepsAlpha() throws {
        var editor = state()
        editor.setColor(color(9, 9, 9, 40), for: .primary)
        editor.applyWheel(hue: 200, saturation: 60, to: .primary)
        #expect(editor.selection.primary.alpha == 40)
        expectClose(try cache(editor, .primary).hue, 200, message: "wheel hue")
        expectClose(try cache(editor, .primary).saturation, 60, message: "wheel saturation")
    }

    @Test func applyWheelTargetsEitherSlot() {
        var editor = stateWithBluePrimary()
        editor.applyWheel(hue: 30, saturation: 100, to: .secondary)
        #expect(editor.selection.secondary == color(255, 128, 0))
        #expect(editor.selection.primary == color(51, 102, 204))
    }

    @Test func applyWheelAtCenterKeepsHue() {
        var editor = stateWithBluePrimary()
        // The view passes the cached hue at the exact center (geometry's own hue is 0 there).
        editor.applyWheel(hue: 220, saturation: 0, to: .primary)
        #expect(editor.selection.primary == color(204, 204, 204))
        #expect(editor.value(of: .hue) == 220)
        editor.set(.saturation, to: 75)
        #expect(editor.selection.primary == color(51, 102, 204))
    }

    @Test func swapAlsoSwapsHSVCaches() throws {
        var editor = stateWithBluePrimary()
        editor.swap()
        #expect(editor.selection.primary == .white)
        #expect(editor.selection.secondary == color(51, 102, 204))
        #expect(editor.hsv[.primary] == HSVColor(hue: 0, saturation: 0, value: 100))
        expectClose(try cache(editor, .secondary).hue, 220, message: "the cache travelled with it")
        #expect(editor.activeSlot == .primary, "swap never moves the outline")
    }

    @Test func resetSetsExactCaches() {
        var editor = ColorEditorState(selection: ColorSelection(primary: color(51, 102, 204, 7),
                                                               secondary: color(255, 0, 0, 10)))
        editor.switchActiveSlot()
        editor.reset()
        #expect(editor.selection == .default)
        #expect(editor.hsv[.primary] == HSVColor(hue: 0, saturation: 0, value: 0))
        #expect(editor.hsv[.secondary] == HSVColor(hue: 0, saturation: 0, value: 100))
        #expect(editor.activeSlot == .secondary, "reset keeps the active slot")
    }

    @Test func switchActiveSlotTogglesOnly() {
        var editor = state(primary: color(51, 102, 204))
        let selectionBefore = editor.selection
        let cachesBefore = editor.hsv
        editor.switchActiveSlot()
        #expect(editor.activeSlot == .secondary)
        #expect(editor.selection == selectionBefore)
        #expect(editor.hsv == cachesBefore)
        editor.set(.red, to: 0)
        #expect(editor.selection.secondary == color(0, 255, 255))
        #expect(editor.selection.primary == color(51, 102, 204))
        editor.switchActiveSlot()
        #expect(editor.activeSlot == .primary)
    }

    @Test func setColorTargetsTheRequestedSlot() {
        var editor = state()
        editor.setColor(color(9, 8, 7, 6), for: .secondary)
        #expect(editor.selection.secondary == color(9, 8, 7, 6))
        #expect(editor.selection.primary == .black, "an explicit slot ignores the active slot")
    }
}
