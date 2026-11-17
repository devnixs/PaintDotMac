import Foundation
import Testing

@testable import PaintDotMac

/// The ⌫/⌦/⌥⌫ chord resolution, the router decision table, and the command names/icons
/// (spec 0018; E-4, §5.12, D-12, D-45). Key codes: 51 = ⌫ (`kVK_Delete`),
/// 117 = ⌦ (`kVK_ForwardDelete`), 0 = the `a` key.
struct SelectionPixelCommandTests {
    private func mods(_ flags: ToolModifiers) -> ToolModifiers { flags }

    @Test func keyTable() {
        #expect(SelectionPixelCommand.command(forKeyCode: 51, modifiers: []) == .eraseSelection)
        #expect(SelectionPixelCommand.command(forKeyCode: 117, modifiers: []) == .eraseSelection)
        #expect(SelectionPixelCommand.command(forKeyCode: 51, modifiers: mods(.option)) == .fillSelection)
        // ⌥⌦, ⇧⌫ (secondary-color fill is out of scope — left unhandled), ⌘⌫ (0024's
        // space), ⌃⌫, ⌥⇧⌫, and other keys resolve to nothing.
        #expect(SelectionPixelCommand.command(forKeyCode: 117, modifiers: mods(.option)) == nil)
        #expect(SelectionPixelCommand.command(forKeyCode: 51, modifiers: mods(.shift)) == nil)
        #expect(SelectionPixelCommand.command(forKeyCode: 51, modifiers: mods(.command)) == nil)
        #expect(SelectionPixelCommand.command(forKeyCode: 51, modifiers: mods(.control)) == nil)
        #expect(SelectionPixelCommand.command(forKeyCode: 51,
                                              modifiers: mods([.option, .shift])) == nil)
        #expect(SelectionPixelCommand.command(forKeyCode: 117, modifiers: mods(.shift)) == nil)
        #expect(SelectionPixelCommand.command(forKeyCode: 0, modifiers: []) == nil)
    }

    /// The `selectionPixelShortcut` table (spec 0018 Test plan): the pure router decision.
    @Test func routerDecisions() {
        func decide(keyCode: UInt16, modifiers: ToolModifiers = [], isRepeat: Bool = false,
                    keyWindow: ToolKeyWindowKind = .document, textInputHasFocus: Bool = false,
                    toolCapturesKeyboard: Bool = false, gestureInProgress: Bool = false)
            -> SelectionPixelShortcutDecision
        {
            SelectionPixelCommand.selectionPixelShortcut(
                keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat,
                keyWindow: keyWindow, textInputHasFocus: textInputHasFocus,
                toolCapturesKeyboard: toolCapturesKeyboard, gestureInProgress: gestureInProgress)
        }

        #expect(decide(keyCode: 51) == .perform(.eraseSelection))
        #expect(decide(keyCode: 117) == .perform(.eraseSelection))
        #expect(decide(keyCode: 51, modifiers: .option) == .perform(.fillSelection),
                "⌥⌫ in a document window fills")
        #expect(decide(keyCode: 51, keyWindow: .panel) == .perform(.eraseSelection),
                "⌫ works right after clicking the Tools or Layers panel")
        #expect(decide(keyCode: 51, textInputHasFocus: true) == .pass,
                "a focused text field keeps ⌫")
        #expect(decide(keyCode: 51, keyWindow: .other) == .pass,
                "sheets and dialogs keep ⌫")
        #expect(decide(keyCode: 51, toolCapturesKeyboard: true) == .pass,
                "the Text tool keeps ⌫ (0040)")
        #expect(decide(keyCode: 51, gestureInProgress: true) == .pass,
                "no erase mid-gesture")
        #expect(decide(keyCode: 51, modifiers: .option, textInputHasFocus: true) == .pass)
        #expect(decide(keyCode: 51, isRepeat: true) == .consumeIgnored,
                "repeatIsIgnored: one step while holding ⌫")
        #expect(decide(keyCode: 51, modifiers: .option, isRepeat: true) == .consumeIgnored)
        #expect(decide(keyCode: 51, isRepeat: true, keyWindow: .other) == .pass,
                "the dialog still receives the repeat")
        // ⌘ and ⌃ chords are not ours (the gate rejects them even though the resolver
        // already returns nil; ⇧⌫ passes so the field editor / menu see it).
        #expect(decide(keyCode: 51, modifiers: [.command, .option]) == .pass)
        #expect(decide(keyCode: 51, modifiers: [.control]) == .pass)
        #expect(decide(keyCode: 51, modifiers: [.shift]) == .pass)
        #expect(decide(keyCode: 0) == .pass)
    }

    @Test func menuNamesAndIcons() {
        #expect(EraseSelection.name == "Erase Selection")
        #expect(FillSelection.name == "Fill Selection")
        #expect(EraseSelection.icon == .eraseSelection)
        #expect(FillSelection.icon == .fillSelection)
    }
}
