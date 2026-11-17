import CoreGraphics
import Foundation
@testable import PaintDotMac

/// A `Tool` that records every call in order (spec 0006 test support): `"activate"`,
/// `"mouseDown(primary)"`, `"commit"`, …. Tests set `id`, `hasPendingEdit`,
/// `capturesKeyboard`, `keyDownResult`, `cursorValue`, and the optional per-event closures.
/// Pass a shared `ToolCallLog` to several stubs to assert cross-tool ordering.
@MainActor
final class StubTool: Tool {
    var id: ToolID
    var hasPendingEdit = false
    var capturesKeyboard = false
    var keyDownResult = false
    var cursorValue: ToolCursor = .arrow

    /// Optional hooks (e.g. to request a tool switch from inside a handler).
    var onMouseUp: ((ToolEvent, any ToolContext) -> Void)?
    var onMouseDragged: ((ToolEvent, any ToolContext) -> Void)?

    /// `"toolID:call"` entries; the `contexts` array is parallel for context-taking calls.
    private let log: ToolCallLog
    var calls: [String] { log.calls(for: id) }
    private(set) var receivedEvents: [ToolEvent] = []
    private(set) var receivedKeyEvents: [ToolKeyEvent] = []
    private(set) var receivedTexts: [String] = []
    /// The context each recorded call received (parallel to `calls`), for identity checks.
    var receivedContexts: [ObjectIdentifier?] { log.contexts(for: id) }

    init(id: ToolID = .pan, log: ToolCallLog? = nil) {
        self.id = id
        self.log = log ?? ToolCallLog()
    }

    private func record(_ call: String, context: (any ToolContext)? = nil) {
        log.append("\(id.rawValue):\(call)")
        log.appendContext(id: id, context.map(ObjectIdentifier.init))
    }

    // MARK: - Tool

    func activate(context: any ToolContext) { record("activate", context: context) }

    func deactivate(context: any ToolContext) {
        record("deactivate", context: context)
        // Mirrors the protocol default so `switchCommitsPendingEdit` exercises it.
        if hasPendingEdit { commit(context: context) }
    }

    func mouseDown(_ event: ToolEvent, context: any ToolContext) {
        receivedEvents.append(event)
        record("mouseDown(\(event.button))")
    }

    func mouseDragged(_ event: ToolEvent, context: any ToolContext) {
        receivedEvents.append(event)
        record("mouseDragged(\(event.button))")
        onMouseDragged?(event, context)
    }

    func mouseUp(_ event: ToolEvent, context: any ToolContext) {
        receivedEvents.append(event)
        record("mouseUp(\(event.button))")
        onMouseUp?(event, context)
    }

    func keyDown(_ event: ToolKeyEvent, context: any ToolContext) -> Bool {
        receivedKeyEvents.append(event)
        record("keyDown(\(event.key))")
        return keyDownResult
    }

    func insertText(_ text: String, context: any ToolContext) {
        receivedTexts.append(text)
        record("insertText(\(text))")
    }

    func prepareForHistoryNavigation(context: any ToolContext) {
        record("prepareForHistoryNavigation", context: context)
        // Mirrors the protocol default so `resolvePendingEditByReason` exercises it.
        if hasPendingEdit { commit(context: context) }
    }

    func commit(context: any ToolContext) { record("commit", context: context) }

    func cancel(context: any ToolContext) { record("cancel", context: context) }

    func optionsDidChange(context: any ToolContext) { record("optionsDidChange") }

    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor { cursorValue }
}

/// A shared, tool-keyed call recorder for cross-tool ordering assertions.
@MainActor
final class ToolCallLog {
    private(set) var all: [String] = []
    private var byTool: [ToolID: [String]] = [:]
    private var contextsByTool: [ToolID: [ObjectIdentifier?]] = [:]

    func append(_ entry: String) {
        all.append(entry)
        guard let raw = entry.split(separator: ":").first, let id = ToolID(rawValue: String(raw))
        else { return }
        byTool[id, default: []].append(String(entry.dropFirst(raw.count + 1)))
    }

    func appendContext(id: ToolID, _ context: ObjectIdentifier?) {
        contextsByTool[id, default: []].append(context)
    }

    func calls(for id: ToolID) -> [String] { byTool[id] ?? [] }

    func contexts(for id: ToolID) -> [ObjectIdentifier?] { contextsByTool[id] ?? [] }

    func reset(id: ToolID) {
        byTool[id] = []
        contextsByTool[id] = []
    }
}
