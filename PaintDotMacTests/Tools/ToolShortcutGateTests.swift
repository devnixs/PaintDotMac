import Testing
@testable import PaintDotMac

/// The single gate every single-key shortcut passes (spec 0006 table).
struct ToolShortcutGateTests {
    private func allows(_ modifiers: ToolModifiers, keyWindow: ToolKeyWindowKind = .document,
                        textInputHasFocus: Bool = false, toolCapturesKeyboard: Bool = false,
                        gestureInProgress: Bool = false) -> Bool {
        ToolShortcutGate.allows(modifiers: modifiers, keyWindow: keyWindow,
                                textInputHasFocus: textInputHasFocus,
                                toolCapturesKeyboard: toolCapturesKeyboard,
                                gestureInProgress: gestureInProgress)
    }

    @Test func plainPressInDocumentWindowAllowed() {
        #expect(allows([]))
    }

    @Test func shiftAllowed() {
        // Shift steers the group cycle, so it must pass the gate.
        #expect(allows(.shift))
    }

    @Test func panelKeyAllowed() {
        // Clicking a Tools panel button leaves the document window key; even with the panel
        // key, tool letters must work.
        #expect(allows([], keyWindow: .panel))
    }

    @Test(arguments: [ToolModifiers.command, .option, .control])
    func modifiedPressesBlocked(_ modifiers: ToolModifiers) {
        #expect(!allows(modifiers))
        #expect(!allows([.shift, modifiers]))
    }

    @Test func otherWindowBlocked() {
        // Sheets, alerts, dialogs, Settings.
        #expect(!allows([], keyWindow: .other))
    }

    @Test func textFieldFocusBlocked() {
        #expect(!allows([], textInputHasFocus: true))
    }

    @Test func toolCapturingKeyboardBlocked() {
        // The Text tool owns typing while editing.
        #expect(!allows([], toolCapturesKeyboard: true))
    }

    @Test func gestureBlocked() {
        #expect(!allows([], gestureInProgress: true))
    }
}
