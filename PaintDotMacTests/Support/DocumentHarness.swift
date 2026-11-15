import AppKit
import Testing
@testable import PaintDotMac

/// In-process replacement for a UI-test driver (AGENTS.md *Headless testing*): it performs user
/// stories against a document whose window is built but never put on screen. Later specs extend
/// it: 0003 adds canvas drags in image coordinates, 0005 adds `newImage` and `exportPNG`, 0006
/// adds tool keys.
@MainActor
final class DocumentHarness {
    let document: PaintDocument
    var windowController: DocumentWindowController
    /// Built, never ordered onto the screen.
    var window: NSWindow

    private init(document: PaintDocument, windowController: DocumentWindowController, window: NSWindow) {
        self.document = document
        self.windowController = windowController
        self.window = window
    }

    /// Opens through `NSDocumentController.shared` with `display: false` — which makes AppKit
    /// create no window controller and show nothing — then builds the window controllers itself.
    static func open(_ url: URL) async throws -> DocumentHarness {
        let opened = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NSDocument, Error>) in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { document, _, error in
                if let document {
                    continuation.resume(returning: document)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
        guard let paintDocument = opened as? PaintDocument else {
            throw CocoaError(.fileReadUnknown)
        }
        paintDocument.makeWindowControllers()
        guard let windowController = paintDocument.windowControllers.first as? DocumentWindowController,
              let window = windowController.window
        else { throw CocoaError(.fileReadUnknown) }
        return DocumentHarness(document: paintDocument, windowController: windowController, window: window)
    }

    /// Mirrors AppKit's action lookup without a key window: the window's first responder and its
    /// `nextResponder` chain, then the window, its controller, the document,
    /// `NSDocumentController.shared`, `NSApp`, and `NSApp.delegate`; returns the first object
    /// that responds to the action.
    func target(for action: Selector) -> AnyObject? {
        var visited: Set<ObjectIdentifier> = []
        var responder: NSResponder? = window.firstResponder
        while let candidate = responder, visited.insert(ObjectIdentifier(candidate)).inserted {
            if candidate.responds(to: action) { return candidate }
            responder = candidate.nextResponder
        }
        var tail: [AnyObject] = [window, windowController, document, NSDocumentController.shared, NSApp]
        if let delegate = NSApp.delegate {
            tail.append(delegate as AnyObject)
        }
        for candidate in tail where candidate.responds(to: action) {
            return candidate
        }
        return nil
    }

    /// What AppKit's menu auto-enabling would report: build an `NSMenuItem` with the action and
    /// ask the target's `validateMenuItem(_:)` / `validateUserInterfaceItem(_:)` — true when the
    /// target implements neither, false when there is no target.
    func isEnabled(_ action: Selector) -> Bool {
        guard let target = target(for: action) else { return false }
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        let validateMenuItem = NSSelectorFromString("validateMenuItem:")
        let validateUserInterfaceItem = NSSelectorFromString("validateUserInterfaceItem:")
        if target.responds(to: validateMenuItem), let validation = target as? NSMenuItemValidation {
            return validation.validateMenuItem(item)
        }
        if target.responds(to: validateUserInterfaceItem), let validation = target as? NSUserInterfaceValidations {
            return validation.validateUserInterfaceItem(item)
        }
        return true
    }

    /// Sends the action to `target(for:)` with an explicit target. Never leaves the process and
    /// never opens UI.
    func perform(_ action: Selector, sender: Any? = nil) {
        guard let target = target(for: action) else {
            Issue.record("nothing responds to \(NSStringFromSelector(action))")
            return
        }
        _ = NSApp.sendAction(action, to: target, from: sender)
    }

    /// Synthesizes `keyDown`/`keyUp` and delivers them to `window.firstResponder`. Menu key
    /// equivalents are not dispatched this way; menu shortcuts are covered by the menu-table
    /// tests plus `perform`.
    func key(_ characters: String, modifiers: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: 0
            )
            guard let event else {
                Issue.record("could not synthesize a \(type == .keyDown ? "keyDown" : "keyUp") event")
                return
            }
            guard let firstResponder = window.firstResponder else {
                Issue.record("the window has no first responder")
                return
            }
            switch type {
            case .keyDown: firstResponder.keyDown(with: event)
            case .keyUp: firstResponder.keyUp(with: event)
            default: Issue.record("unexpected key event type")
            }
        }
    }

    /// Builds a mouse event for this window; later specs' drag helpers call the view's
    /// `mouseDown(with:)` / `mouseDragged(with:)` / `mouseUp(with:)` (or the right-mouse
    /// variants) with it.
    func mouse(_ type: NSEvent.EventType, at pointInWindow: CGPoint,
               modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1,
               pressure: Float = 0) -> NSEvent {
        let event = NSEvent.mouseEvent(
            with: type,
            location: pointInWindow,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: pressure
        )
        guard let event else {
            Issue.record("could not synthesize a mouse event")
            return NSEvent()
        }
        return event
    }

    /// Never goes through a path that can present a save sheet.
    func close() {
        document.close()
    }
}
