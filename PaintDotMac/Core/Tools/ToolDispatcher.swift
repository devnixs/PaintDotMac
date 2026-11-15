import CoreGraphics
import Foundation

/// The physical button the router saw. The middle button never reaches the dispatcher — the
/// router pans with it itself.
enum ToolPhysicalButton: Sendable {
    case left
    case right
}

/// One pointer event before button mapping (the AppKit glue builds these).
struct ToolPointerInput: Sendable, Equatable {
    var physicalButton: ToolPhysicalButton
    var location: CGPoint
    var viewLocation: CGPoint
    var modifiers: ToolModifiers
    var clickCount: Int
    var pressure: Double
    var timestamp: TimeInterval
}

/// The single owner of tool instances, the active/previous tool, gestures, and shortcut
/// resolution (spec 0006). One instance in `AppModel`; the context switches to whichever
/// document window is active.
@MainActor
final class ToolDispatcher {
    private let registry: ToolRegistry
    private var tools: [ToolID: any Tool] = [:]
    private var resolver = ToolShortcutResolver()

    private(set) var activeToolID: ToolID
    private(set) var previousToolID: ToolID?
    private(set) var context: (any ToolContext)?

    private struct Gesture {
        var physicalButton: ToolPhysicalButton
        var button: ToolMouseButton
        var cancelled = false
    }

    private var gesture: Gesture?
    /// A switch requested while a handler runs; applied after the outermost handler returns
    /// (and after the gesture ends), last request wins.
    private var pendingSwitch: ToolID?
    private var isHandlingEvent = false

    var onStateChange: (@MainActor () -> Void)?

    private var lastMirroredActiveToolID: ToolID
    private var lastMirroredHasPendingEdit: Bool

    init(registry: ToolRegistry) {
        self.registry = registry
        self.activeToolID = registry.defaultToolID
        self.lastMirroredActiveToolID = registry.defaultToolID
        self.lastMirroredHasPendingEdit = false
        // Fully initialized; mirror the real tool's state (no user path where this differs).
        lastMirroredHasPendingEdit = activeTool.hasPendingEdit
    }

    /// The active tool's lazily created, app-lifetime instance.
    var activeTool: any Tool { tool(for: activeToolID) }

    var isGestureInProgress: Bool { gesture != nil }

    var hasPendingEdit: Bool { activeTool.hasPendingEdit }

    private func tool(for id: ToolID) -> any Tool {
        if let existing = tools[id] { return existing }
        // The active ID always comes from the registry (`selectTool` checks, `defaultToolID`
        // picks an implemented ID); a missing factory is a programming error.
        guard let created = registry.makeTool(id) else {
            preconditionFailure("Tool \(id.rawValue) is active but not registered")
        }
        tools[id] = created
        return created
    }

    // MARK: - Context

    /// Switches the tool context (document window). A running gesture is cancelled against
    /// the old context, the active tool deactivates into the old context (committing pending
    /// state into the old document), and it activates in the new one.
    func setContext(_ context: (any ToolContext)?) {
        guard context !== self.context else { return }
        let old = self.context
        if let old {
            if gesture != nil {
                activeTool.cancel(context: old)
            }
            activeTool.deactivate(context: old)
        }
        gesture = nil
        pendingSwitch = nil
        self.context = context
        if let context {
            activeTool.activate(context: context)
        }
        mirrorState()
    }

    // MARK: - Selection

    /// Not implemented → false, no change. The active tool → true, no calls. During a
    /// gesture → remembered and applied when the gesture ends (last request wins).
    @discardableResult
    func selectTool(_ id: ToolID) -> Bool {
        handle {
            guard registry.isImplemented(id) else { return false }
            if id == activeToolID { return true }
            if gesture != nil {
                pendingSwitch = id
                return true
            }
            let old = activeTool
            if let context { old.deactivate(context: context) }
            previousToolID = activeToolID
            activeToolID = id
            if let context { activeTool.activate(context: context) }
            mirrorState()
            return true
        }
    }

    /// What `ToolContext.activateTool(_:)` calls. Inside a tool handler the switch is queued
    /// and applied right after that handler returns (after the gesture ends when the handler
    /// is part of one), so a tool is never deactivated from inside its own handler. Outside
    /// a handler this behaves like `selectTool`.
    func requestToolSwitch(_ id: ToolID) {
        if isHandlingEvent {
            guard registry.isImplemented(id) else { return }
            pendingSwitch = id
            return
        }
        selectTool(id)
    }

    private func applyPendingSwitch() {
        guard let id = pendingSwitch else { return }
        pendingSwitch = nil
        selectTool(id)
    }

    // MARK: - Pointer events

    /// Starts a gesture only when none is in progress — a second button pressed
    /// mid-gesture is ignored, as is its up.
    func pointerDown(_ input: ToolPointerInput) {
        handle {
            guard let context, gesture == nil else { return }
            let button: ToolMouseButton
            switch input.physicalButton {
            case .left:
                // TOOL-A / 0012: Control-left arrives as secondary with `.control` kept.
                button = input.modifiers.contains(.control) ? .secondary : .primary
            case .right:
                button = .secondary
            }
            gesture = Gesture(physicalButton: input.physicalButton, button: button)
            activeTool.mouseDown(
                ToolEvent(location: input.location, viewLocation: input.viewLocation,
                          button: button, modifiers: input.modifiers,
                          clickCount: input.clickCount, pressure: input.pressure,
                          timestamp: input.timestamp),
                context: context
            )
            mirrorState()
        }
    }

    func pointerDragged(_ input: ToolPointerInput) {
        handle {
            guard let context, let gesture, gesture.physicalButton == input.physicalButton,
                  !gesture.cancelled else { return }
            activeTool.mouseDragged(
                ToolEvent(location: input.location, viewLocation: input.viewLocation,
                          button: gesture.button, modifiers: input.modifiers,
                          clickCount: 0, pressure: input.pressure, timestamp: input.timestamp),
                context: context
            )
            mirrorState()
        }
    }

    func pointerUp(_ input: ToolPointerInput) {
        handle {
            guard let context, let gesture, gesture.physicalButton == input.physicalButton else { return }
            self.gesture = nil
            guard !gesture.cancelled else { return }  // Escape already cancelled; swallow the up
            activeTool.mouseUp(
                ToolEvent(location: input.location, viewLocation: input.viewLocation,
                          button: gesture.button, modifiers: input.modifiers,
                          clickCount: input.clickCount, pressure: input.pressure,
                          timestamp: input.timestamp),
                context: context
            )
            mirrorState()
        }
    }

    func pointerMoved(location: CGPoint, viewLocation: CGPoint,
                      modifiers: ToolModifiers, timestamp: TimeInterval) {
        handle {
            guard let context else { return }
            activeTool.mouseMoved(
                ToolEvent(location: location, viewLocation: viewLocation,
                          button: .primary, modifiers: modifiers,
                          clickCount: 0, pressure: 1.0, timestamp: timestamp),
                context: context
            )
            mirrorState()
        }
    }

    func flagsChanged(_ modifiers: ToolModifiers) {
        handle {
            guard let context else { return }
            activeTool.flagsChanged(modifiers, context: context)
            mirrorState()
        }
    }

    // MARK: - Key events

    /// Escape during a gesture cancels it (later drags are swallowed; the matching up only
    /// ends the gesture). Otherwise the event goes to the active tool.
    @discardableResult
    func keyDown(_ event: ToolKeyEvent) -> Bool {
        handle {
            guard let context else { return false }
            if event.key == .escape, gesture != nil {
                activeTool.cancel(context: context)
                gesture?.cancelled = true
                mirrorState()
                return true
            }
            let handled = activeTool.keyDown(event, context: context)
            mirrorState()
            return handled
        }
    }

    func insertText(_ text: String) {
        handle {
            guard let context else { return }
            activeTool.insertText(text, context: context)
            mirrorState()
        }
    }

    // MARK: - Shortcuts

    /// The single-key tool shortcut path (the `CanvasInputRouter` calls it). False when the
    /// gate blocks or the key is not a tool letter; true when consumed — auto-repeats and
    /// keys of unimplemented tools are consumed silently.
    @discardableResult
    func handleShortcut(charactersIgnoringModifiers: String, modifiers: ToolModifiers,
                        isRepeat: Bool, timestamp: TimeInterval,
                        keyWindow: ToolKeyWindowKind, textInputHasFocus: Bool) -> Bool {
        guard ToolShortcutGate.allows(
            modifiers: modifiers, keyWindow: keyWindow,
            textInputHasFocus: textInputHasFocus,
            toolCapturesKeyboard: activeTool.capturesKeyboard,
            gestureInProgress: isGestureInProgress
        ) else { return false }
        guard let key = ToolShortcutResolver.toolKey(
            fromCharactersIgnoringModifiers: charactersIgnoringModifiers
        ) else { return false }
        if !isRepeat {
            let toolID = resolver.resolve(
                key: key, shift: modifiers.contains(.shift),
                group: registry.shortcutGroup(for: key),
                activeTool: activeToolID, timestamp: timestamp
            )
            if let toolID { selectTool(toolID) }
        }
        return true
    }

    // MARK: - Commands

    /// The Finish button; later 0008's undo and save call it too.
    func commitPendingEdit() {
        handle {
            guard let context else { return }
            activeTool.commit(context: context)
            mirrorState()
        }
    }

    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor {
        activeTool.cursor(at: location, modifiers: modifiers)
    }

    func optionsDidChange() {
        handle {
            guard let context else { return }
            activeTool.optionsDidChange(context: context)
            mirrorState()
        }
    }

    // MARK: - Plumbing

    /// Runs one event handler, then applies a queued tool switch once no gesture remains,
    /// and mirrors state changes into `onStateChange`.
    @discardableResult
    private func handle<T>(_ body: () -> T) -> T {
        isHandlingEvent = true
        let result = body()
        isHandlingEvent = false
        if gesture == nil { applyPendingSwitch() }
        return result
    }

    private func mirrorState() {
        guard activeToolID != lastMirroredActiveToolID
            || hasPendingEdit != lastMirroredHasPendingEdit else { return }
        lastMirroredActiveToolID = activeToolID
        lastMirroredHasPendingEdit = hasPendingEdit
        onStateChange?()
    }
}
