import Testing

@testable import PaintDotMac

/// `ColorPickerAfterClick` (spec 0012 *Test plan*): the full decision table and the exact
/// Paint.NET display strings.
struct ColorPickerAfterClickTests {
    @Test(arguments: ColorPickerAfterClick.allCases)
    func doNotSwitchNeverActivates(_ afterClick: ColorPickerAfterClick) throws {
        guard afterClick == .doNotSwitch else { return }
        #expect(afterClick.toolToActivate(current: .colorPicker, previous: nil) == nil)
        #expect(afterClick.toolToActivate(current: .colorPicker,
                                          previous: .paintbrush) == nil)
        #expect(afterClick.toolToActivate(current: .colorPicker,
                                          previous: .colorPicker) == nil)
    }

    @Test func switchToPreviousToolUsesPrevious() {
        let choice = ColorPickerAfterClick.switchToPreviousTool
        #expect(choice.toolToActivate(current: .colorPicker, previous: .paintbrush) == .paintbrush)
        #expect(choice.toolToActivate(current: .colorPicker, previous: .pencil) == .pencil)
        #expect(choice.toolToActivate(current: .colorPicker, previous: .pan) == .pan)
        // No previous tool (Color Picker was first): no switch.
        #expect(choice.toolToActivate(current: .colorPicker, previous: nil) == nil)
        // A previous of the Color Picker itself is treated as "no previous tool".
        #expect(choice.toolToActivate(current: .colorPicker, previous: .colorPicker) == nil)
    }

    @Test func switchToPencilIgnoresPrevious() {
        let choice = ColorPickerAfterClick.switchToPencil
        #expect(choice.toolToActivate(current: .colorPicker, previous: nil) == .pencil)
        #expect(choice.toolToActivate(current: .colorPicker, previous: .paintbrush) == .pencil)
        #expect(choice.toolToActivate(current: .colorPicker, previous: .colorPicker) == .pencil)
    }

    @Test func displayNamesMatchPaintNET() {
        // paint.net/doc/latest/ColorPicker.html, exact.
        #expect(ColorPickerAfterClick.allCases.map(\.displayName)
                    == ["Do not switch tool", "Switch to previous tool", "Switch to Pencil tool"])
        #expect(ColorPickerAfterClick.allCases.map(\.rawValue)
                    == ["doNotSwitch", "switchToPreviousTool", "switchToPencil"])
    }

    /// TOOL-C storage: raw string in, unknown values read as missing (→ the option's
    /// default).
    @Test(arguments: ColorPickerAfterClick.allCases)
    func optionValueRoundTrip(_ choice: ColorPickerAfterClick) throws {
        let raw = try #require(choice.storedValue as? String)
        #expect(raw == choice.rawValue)
        #expect(ColorPickerAfterClick(storedValue: raw) == choice)
    }

    @Test(arguments: ["", "foo", "Do not switch tool"])
    func optionValueRejectsUnknownStrings(stored: String) {
        #expect(ColorPickerAfterClick(storedValue: stored) == nil)
    }

    @Test func optionValueRejectsNonString() {
        #expect(ColorPickerAfterClick(storedValue: 7) == nil)
        #expect(ColorPickerAfterClick(storedValue: true) == nil)
    }
}
