import Testing

@testable import PaintDotMac

/// The X / D / C color keys (C-1, PRD §5.12, D-31): bare presses only — with ⌘/⌥/⌃ the event
/// must reach the menu — and never tool keys.
struct ColorKeyCommandTests {
    private func command(_ characters: String, command: Bool = false, option: Bool = false,
                         control: Bool = false) -> ColorKeyCommand? {
        ColorKeyCommand.command(forCharactersIgnoringModifiers: characters, command: command,
                                option: option, control: control)
    }

    @Test func xSwaps() {
        #expect(command("x") == .swap)
        #expect(command("X") == .swap)
    }

    @Test func dResets() {
        #expect(command("d") == .reset)
        #expect(command("D") == .reset)
    }

    @Test func cSwitchesSlot() {
        #expect(command("c") == .switchSlot)
        #expect(command("C") == .switchSlot)
    }

    /// Shift and Caps Lock are ignored; ⌘/⌥/⌃ block, so ⌘X/⌘D/⌘C keep their menu meanings.
    @Test func modifiersBlock() {
        #expect(command("x", command: true) == nil)
        #expect(command("d", command: true) == nil)
        #expect(command("c", command: true) == nil)
        #expect(command("x", option: true) == nil)
        #expect(command("d", control: true) == nil)
        #expect(command("c", control: true) == nil)
        #expect(command("c", command: true, option: true, control: true) == nil)
        #expect(command("x", command: true, option: true) == nil)
    }

    @Test func otherKeysIgnored() {
        for text in ["v", "xx", "", "b", "4", " ", "xd", "é"] {
            #expect(command(text) == nil, "\(text.debugDescription) is not a color key")
        }
    }

    @Test func xDAndCAreNotToolKeys() {
        for text in ["x", "X", "d", "D", "c", "C"] {
            #expect(ToolShortcutResolver.toolKey(fromCharactersIgnoringModifiers: text) == nil,
                    "\(text) must not be a tool key")
        }
        for key: Character in ["x", "d", "c"] {
            #expect(!ToolRegistry.allShortcutKeys.contains(key))
        }
    }
}
