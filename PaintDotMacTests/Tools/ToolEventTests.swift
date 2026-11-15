import Testing
@testable import PaintDotMac

/// `ToolKey.init(keyCode:charactersIgnoringModifiers:)` (spec 0006 *Test plan*).
struct ToolEventTests {
    @Test(arguments: [
        // (keyCode, charactersIgnoringModifiers, expected)
        (UInt16(36), "\r", ToolKey.returnKey),
        (UInt16(76), "\u{3}", ToolKey.enter),
        (UInt16(53), "\u{1b}", ToolKey.escape),
        (UInt16(51), "\u{7f}", ToolKey.delete),
        (UInt16(117), "\u{f728}", ToolKey.forwardDelete),
        (UInt16(48), "\t", ToolKey.tab),
        (UInt16(49), " ", ToolKey.space),
        (UInt16(123), "\u{f702}", ToolKey.leftArrow),
        (UInt16(124), "\u{f703}", ToolKey.rightArrow),
        (UInt16(125), "\u{f701}", ToolKey.downArrow),
        (UInt16(126), "\u{f700}", ToolKey.upArrow),
        (UInt16(1), "S", ToolKey.character("s")),
        (UInt16(1), "", ToolKey.other(keyCode: 1)),
        (UInt16(1), "ab", ToolKey.other(keyCode: 1)),
    ])
    func toolKeyFromKeyCodes(_ testCase: (UInt16, String, ToolKey)) {
        let (keyCode, characters, expected) = testCase
        #expect(ToolKey(keyCode: keyCode, charactersIgnoringModifiers: characters) == expected)
    }

    @Test func toolModifiersAreIndependentOptions() {
        let all: ToolModifiers = [.shift, .option, .control, .command]
        #expect(all.rawValue == 0b1111)
        #expect(ToolModifiers().isEmpty)
        #expect(all.contains(.shift))
        #expect(!ToolModifiers.option.contains(.control))
    }
}
