import AppKit

/// Input routing (spec 0006). The static `handleShortcutKeyDown` is the single entry point
/// for single-key shortcuts: the tool letters first (0006), then the Colors keys X, D, and C
/// (0007), and 0009 adds `[`/`]` after the same lookup. The instance owns one document window's
/// mouse/key routing: 0004 keeps magnify/scroll/Space-pan, everything else goes to the active
/// tool through `ToolDispatcher`.
@MainActor
final class CanvasInputRouter {
    // MARK: - Single-key shortcuts (app-wide)

    /// The `keyWindow` parameter is the test seam: integration tests pass their offscreen
    /// document window or panel, since nothing is key in a headless run.
    @discardableResult
    static func handleShortcutKeyDown(_ event: NSEvent, model: AppModel,
                                      keyWindow: NSWindow? = NSApp.keyWindow) -> Bool {
        let windowKind: ToolKeyWindowKind
        if keyWindow?.identifier == DocumentWindowController.windowIdentifier {
            windowKind = .document
        } else if PanelKind.isPanelWindowIdentifier(keyWindow?.identifier) {
            windowKind = .panel
        } else {
            // Sheets, alerts, dialogs, Settings — no tool keys.
            windowKind = .other
        }
        let textInputHasFocus = hasTextInputFocus(in: keyWindow)
        let modifiers = modifiers(from: event.modifierFlags)
        if model.dispatcher.handleShortcut(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            modifiers: modifiers,
            isRepeat: event.isARepeat,
            timestamp: event.timestamp,
            keyWindow: windowKind,
            textInputHasFocus: textInputHasFocus
        ) {
            return true
        }
        if handleBrushWidthKey(event, model: model, modifiers: modifiers,
                               keyWindow: windowKind, textInputHasFocus: textInputHasFocus) {
            return true
        }
        return handleColorKey(event, model: model, modifiers: modifiers,
                              keyWindow: windowKind, textInputHasFocus: textInputHasFocus)
    }

    /// `[` / `]` (PRD §5.12, D-12; spec 0009): step the active brush tool's width by ∓1/±1
    /// when it is `BrushWidthAdjustable`, behind the same gate as every single-key shortcut
    /// (no ⌘/⌥/⌃, no text field focused, no gesture in flight — a gesture would race the
    /// stroke; the stroke keeps its frozen options anyway). Auto-repeat repeats the step.
    /// ⌘[ / ⌘] stay Rotate, so Paint.NET's Ctrl+`[`/`]` ×5 step is not mapped.
    private static func handleBrushWidthKey(_ event: NSEvent, model: AppModel,
                                            modifiers: ToolModifiers, keyWindow: ToolKeyWindowKind,
                                            textInputHasFocus: Bool) -> Bool {
        guard ToolShortcutGate.allows(
            modifiers: modifiers, keyWindow: keyWindow,
            textInputHasFocus: textInputHasFocus,
            toolCapturesKeyboard: model.dispatcher.activeTool.capturesKeyboard,
            gestureInProgress: model.dispatcher.isGestureInProgress
        ), let delta = brushWidthDelta(forCharactersIgnoringModifiers:
                                        event.charactersIgnoringModifiers ?? "") else {
            // ⌘[ / ⌘] stay Rotate (D-12): a modified bracket is not ours.
            return false
        }
        // A brush tool owns the unmodified bracket even with no context yet (the gate
        // passed, so this is a real bare `[`/`]` in a document window).
        guard let tool = model.dispatcher.activeTool as? any BrushWidthAdjustable else { return false }
        if let context = model.dispatcher.context {
            tool.adjustBrushWidth(by: delta, context: context)
        }
        return true
    }

    /// −1 for `[`, +1 for `]`, nil for anything else.
    static func brushWidthDelta(forCharactersIgnoringModifiers characters: String) -> Double? {
        switch characters {
        case "[": return -1
        case "]": return 1
        default: return nil
        }
    }

    /// X / D / C (C-1, D-31), behind the same gate as the tool letters: the Colors or Tools
    /// panel or a document window is key, no text field is focused, no ⌘/⌥/⌃, no tool capturing
    /// the keyboard, and no gesture in flight. Auto-repeat is consumed but ignored, so holding
    /// X does not flicker. Paint.NET has no menu items for these, so none were added.
    private static func handleColorKey(_ event: NSEvent, model: AppModel,
                                       modifiers: ToolModifiers, keyWindow: ToolKeyWindowKind,
                                       textInputHasFocus: Bool) -> Bool {
        guard ToolShortcutGate.allows(
            modifiers: modifiers, keyWindow: keyWindow,
            textInputHasFocus: textInputHasFocus,
            toolCapturesKeyboard: model.dispatcher.activeTool.capturesKeyboard,
            gestureInProgress: model.dispatcher.isGestureInProgress
        ), let command = ColorKeyCommand.command(
            forCharactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            command: modifiers.contains(.command), option: modifiers.contains(.option),
            control: modifiers.contains(.control)
        ) else { return false }
        guard !event.isARepeat else { return true }
        switch command {
        case .swap: model.swapColors()
        case .reset: model.resetColors()
        case .switchSlot: model.switchActiveColorSlot()
        }
        return true
    }

    /// The field editor of any `NSTextField`/SwiftUI `TextField` is an `NSText`; other text
    /// input clients (SwiftUI hosting views) answer `NSTextInputClient`. The `CanvasView`
    /// itself never counts — it is the non-text first responder tool keys need.
    static func hasTextInputFocus(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is CanvasView { return false }
        if responder is NSText { return true }
        return responder is NSTextInputClient
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> ToolModifiers {
        var modifiers: ToolModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    // MARK: - Per-window routing

    private weak var canvasView: CanvasView?
    private let navigation: CanvasNavigation
    let session: CanvasToolSession
    private let model: AppModel
    private var cursorHookToken: UUID

    /// Which path claimed the current mouse-down (0004's order preserved: Space-pan first,
    /// then the tool; the middle button pans by itself).
    private enum DragOwner {
        case none
        case spacePan
        case tool
        case middleButton
    }

    private var dragOwner: DragOwner = .none
    /// Last pointer position in canvas-view points; nil once the pointer left the canvas.
    private var lastPointerViewLocation: CGPoint?

    init(canvasView: CanvasView, navigation: CanvasNavigation,
         session: CanvasToolSession, model: AppModel) {
        self.canvasView = canvasView
        self.navigation = navigation
        self.session = session
        self.model = model
        self.cursorHookToken = UUID()
        // Assigned post-initialization: the hook closure captures `self`.
        cursorHookToken = model.addCursorRefreshHook { [weak self] in
            self?.refreshCursor()
        }
    }

    /// The document window closed: stop refreshing this canvas's cursor.
    func detach() {
        model.removeCursorRefreshHook(cursorHookToken)
        dragOwner = .none
        lastPointerViewLocation = nil
    }

    /// Re-query and set the effective cursor (tool change, modifier change, …).
    func refreshCursor() {
        applyCursor(at: lastPointerViewLocation, modifiers: NSEvent.modifierFlags)
    }

    // MARK: - Pointer events (CanvasView overrides forward here)

    func mouseDown(with event: NSEvent) {
        canvasView?.window?.makeFirstResponder(canvasView)
        activateSessionIfNeeded()
        guard let point = viewPoint(of: event) else { return }
        if navigation.mouseDown(atView: point) {
            // 0004's Space-pan claims the click.
            dragOwner = .spacePan
        } else {
            dragOwner = .tool
            model.dispatcher.pointerDown(pointerInput(.left, event: event, view: point))
        }
        applyCursor(at: point, modifiers: event.modifierFlags)
    }

    func mouseDragged(with event: NSEvent) {
        guard let point = viewPoint(of: event) else { return }
        lastPointerViewLocation = point
        switch dragOwner {
        case .spacePan, .none:
            // 0004: `mouseDragged` tracks the status-bar cursor and continues a Space pan.
            navigation.mouseDragged(toView: point)
        case .tool:
            navigation.mouseDragged(toView: point)
            model.dispatcher.pointerDragged(pointerInput(.left, event: event, view: point))
        case .middleButton:
            navigation.continuePan(toView: point)
        }
        applyCursor(at: point, modifiers: event.modifierFlags)
    }

    func mouseUp(with event: NSEvent) {
        defer { dragOwner = .none }
        guard let point = viewPoint(of: event) else { return }
        switch dragOwner {
        case .spacePan, .none:
            navigation.mouseUp()
        case .tool:
            model.dispatcher.pointerUp(pointerInput(.left, event: event, view: point))
            navigation.mouseUp()
        case .middleButton:
            navigation.endPan()
        }
        applyCursor(at: point, modifiers: event.modifierFlags)
    }

    func rightMouseDown(with event: NSEvent) {
        canvasView?.window?.makeFirstResponder(canvasView)
        activateSessionIfNeeded()
        guard dragOwner == .none, let point = viewPoint(of: event) else { return }
        dragOwner = .tool
        model.dispatcher.pointerDown(pointerInput(.right, event: event, view: point))
        applyCursor(at: point, modifiers: event.modifierFlags)
    }

    func rightMouseDragged(with event: NSEvent) {
        guard dragOwner == .tool, let point = viewPoint(of: event) else { return }
        lastPointerViewLocation = point
        model.dispatcher.pointerDragged(pointerInput(.right, event: event, view: point))
        applyCursor(at: point, modifiers: event.modifierFlags)
    }

    func rightMouseUp(with event: NSEvent) {
        defer { dragOwner = .none }
        guard dragOwner == .tool, let point = viewPoint(of: event) else { return }
        model.dispatcher.pointerUp(pointerInput(.right, event: event, view: point))
        applyCursor(at: point, modifiers: event.modifierFlags)
    }

    /// Middle button (any tool): pan, unless a tool gesture owns the mouse.
    func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, !model.dispatcher.isGestureInProgress,
              let point = viewPoint(of: event) else { return }
        canvasView?.window?.makeFirstResponder(canvasView)
        dragOwner = .middleButton
        navigation.beginPan(atView: point)
        applyCursor(at: point, modifiers: event.modifierFlags)
    }

    func otherMouseDragged(with event: NSEvent) {
        guard dragOwner == .middleButton, event.buttonNumber == 2,
              let point = viewPoint(of: event) else { return }
        navigation.continuePan(toView: point)
    }

    func otherMouseUp(with event: NSEvent) {
        guard dragOwner == .middleButton, event.buttonNumber == 2 else { return }
        dragOwner = .none
        navigation.endPan()
        refreshCursor()
    }

    func mouseMoved(with event: NSEvent) {
        guard let point = viewPoint(of: event) else { return }
        lastPointerViewLocation = point
        navigation.cursorMoved(toView: point)  // 0004's status-bar tracking stays
        model.dispatcher.pointerMoved(
            location: canvasPoint(of: point) ?? .zero, viewLocation: point,
            modifiers: Self.modifiers(from: event.modifierFlags), timestamp: event.timestamp
        )
        applyCursor(at: point, modifiers: event.modifierFlags)
    }

    func mouseExited(with event: NSEvent) {
        lastPointerViewLocation = nil
        navigation.cursorExited()
    }

    func flagsChanged(with event: NSEvent) {
        model.dispatcher.flagsChanged(Self.modifiers(from: event.modifierFlags))
        applyCursor(at: lastPointerViewLocation, modifiers: event.modifierFlags)
    }

    func cursorUpdate(with event: NSEvent) {
        let point = viewPoint(of: event)
        lastPointerViewLocation = point
        applyCursor(at: point, modifiers: event.modifierFlags)
    }

    // MARK: - Key events

    /// True when consumed; false lets `CanvasView` forward up the responder chain.
    func keyDown(with event: NSEvent) -> Bool {
        let capturesKeyboard = model.dispatcher.activeTool.capturesKeyboard
        if event.keyCode == CanvasNavigation.spaceKeyCode, !capturesKeyboard {
            // 0004's Space-pan first; modified Space falls through like 0004.
            if navigation.keyDown(event) { return true }
        }
        let keyEvent = ToolKeyEvent(
            key: ToolKey(keyCode: event.keyCode,
                         charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? ""),
            characters: event.characters ?? "",
            modifiers: Self.modifiers(from: event.modifierFlags),
            isRepeat: event.isARepeat
        )
        if model.dispatcher.keyDown(keyEvent) { return true }
        if capturesKeyboard {
            // IME-capable typing path; `insertText(_:)` forwards back to the dispatcher.
            canvasView?.interpretKeyEvents([event])
            return true
        }
        return false
    }

    func keyUp(with event: NSEvent) -> Bool {
        guard !model.dispatcher.activeTool.capturesKeyboard else { return false }
        return navigation.keyUp(event)
    }

    func insertText(_ text: String) {
        model.dispatcher.insertText(text)
    }

    // MARK: - Plumbing

    private func activateSessionIfNeeded() {
        if model.dispatcher.context !== session {
            model.setActiveSession(session)
        }
    }

    private func viewPoint(of event: NSEvent) -> CGPoint? {
        guard let canvasView else { return nil }
        let point = canvasView.convert(event.locationInWindow, from: nil)
        return point.x.isFinite && point.y.isFinite ? point : nil
    }

    /// CAN-6: conversions go through `CanvasTransform`; a non-finite result drops the event.
    private func canvasPoint(of viewPoint: CGPoint) -> CGPoint? {
        guard let canvasView else { return nil }
        let point = canvasView.transform.viewToCanvas(viewPoint)
        return point.x.isFinite && point.y.isFinite ? point : nil
    }

    private func pointerInput(_ button: ToolPhysicalButton, event: NSEvent,
                              view: CGPoint) -> ToolPointerInput {
        ToolPointerInput(
            physicalButton: button,
            location: canvasPoint(of: view) ?? view,
            viewLocation: view,
            modifiers: Self.modifiers(from: event.modifierFlags),
            clickCount: event.clickCount,
            pressure: Double(event.pressure),
            timestamp: event.timestamp
        )
    }

    /// 0004's Space cursor wins when armed; then the middle-button pan's closed hand; then
    /// the active tool's cursor.
    private func applyCursor(at viewPoint: CGPoint?, modifiers: NSEvent.ModifierFlags) {
        switch navigation.spacePan.cursor {
        case .openHand:
            NSCursor.openHand.set()
            return
        case .closedHand:
            NSCursor.closedHand.set()
            return
        case .none:
            break
        }
        if dragOwner == .middleButton {
            NSCursor.closedHand.set()
            return
        }
        let canvasPoint = viewPoint.flatMap { self.canvasPoint(of: $0) }
        let cursor = model.dispatcher.cursor(
            at: canvasPoint, modifiers: Self.modifiers(from: modifiers)
        )
        cursor.nsCursor.set()
    }
}
