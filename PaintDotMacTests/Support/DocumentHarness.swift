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

    /// The per-harness `AppModel` (0006) on a throwaway suite, installed as the window's
    /// tool model so `shortcut`, `clickCanvas`, and `dragCanvas` drive the same dispatcher.
    let appModel: AppModel
    private let appModelSuiteName: String?

    private init(document: PaintDocument, windowController: DocumentWindowController,
                 window: NSWindow, appModel: AppModel, appModelSuiteName: String?) {
        self.document = document
        self.windowController = windowController
        self.window = window
        self.appModel = appModel
        self.appModelSuiteName = appModelSuiteName
    }

    /// Removes the harness's `AppModel` defaults suite (integration cleanup; mirrors what a
    /// relaunch on a fresh machine starts from).
    func discardAppModelSuite() {
        guard let appModelSuiteName else { return }
        UserDefaults(suiteName: appModelSuiteName)?.removePersistentDomain(forName: appModelSuiteName)
    }

    /// A fresh-suite `AppModel` (never the user's preferences, AGENTS.md).
    private static func makeAppModel() -> (AppModel, String?) {
        let suiteName = "DocumentHarness.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return (AppModel(), nil)
        }
        return (AppModel(defaults: defaults), suiteName)
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
        let (appModel, suiteName) = makeAppModel()
        windowController.appModel = appModel
        return DocumentHarness(document: paintDocument, windowController: windowController,
                               window: window, appModel: appModel, appModelSuiteName: suiteName)
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

    /// Synthesizes `keyDown` then `keyUp` and delivers them to `window.firstResponder`. Menu
    /// key equivalents are not dispatched this way; menu shortcuts are covered by the menu
    /// table tests plus `perform`.
    func key(_ characters: String, modifiers: NSEvent.ModifierFlags = []) {
        keyDown(characters, modifiers: modifiers)
        keyUp(characters, modifiers: modifiers)
    }

    /// One synthesized `keyDown` (0004: Space must be able to stay pressed while the mouse
    /// moves). `keyCode` is the virtual key code — 49 for Space.
    func keyDown(_ characters: String, keyCode: UInt16 = 0,
                 modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false) {
        deliverKey(.keyDown, characters: characters, keyCode: keyCode,
                   modifiers: modifiers, isRepeat: isRepeat)
    }

    func keyUp(_ characters: String, keyCode: UInt16 = 0,
               modifiers: NSEvent.ModifierFlags = []) {
        deliverKey(.keyUp, characters: characters, keyCode: keyCode,
                   modifiers: modifiers, isRepeat: false)
    }

    private func deliverKey(_ type: NSEvent.EventType, characters: String, keyCode: UInt16,
                            modifiers: NSEvent.ModifierFlags, isRepeat: Bool) {
        let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isRepeat,
            keyCode: keyCode
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

// MARK: - Zoom, pan, and status bar (spec 0004)

extension DocumentHarness {
    /// The window's Metal canvas. A document window without one (no Metal) is a harness
    /// misuse, not a user path; the failure names itself.
    var canvasView: CanvasView {
        guard let canvas = windowController.canvasView else {
            Issue.record("the document window has no Metal canvas")
            fatalError("DocumentHarness used against a Metal-less window")
        }
        return canvas
    }

    /// The window's status bar model (the SwiftUI view is its rendering).
    var statusBar: StatusBarModel { windowController.statusBarModel }

    /// View-space point showing the given canvas (image-pixel) point, through the current
    /// `CanvasTransform`.
    func viewPoint(forImagePoint point: CGPoint) -> CGPoint {
        canvasView.transform.canvasToView(point)
    }

    /// Delivers a synthesized `.mouseMoved` at a canvas-view point.
    func moveMouse(toView point: CGPoint) {
        sendMouse(.mouseMoved, atView: point) { self.canvasView.mouseMoved(with: $0) }
    }

    /// Delivers a synthesized `.mouseExited`. AppKit's mouse-event factory asserts on the
    /// `.mouseExited` type (`_NSEventMask64FromType` covers mouse buttons and moved only),
    /// and the app's handler ignores the payload, so the exit passes an inert event.
    func mouseExited() {
        canvasView.mouseExited(with: NSEvent())
    }

    /// Delivers a synthesized `.mouseMoved` at an image-space (canvas) point.
    func moveMouse(toImagePoint point: CGPoint) {
        moveMouse(toView: canvasView.transform.canvasToView(point))
    }

    /// ⌘-scroll zooms, plain scroll pans (0004). `precise` picks trackpad (point) vs.
    /// mouse-wheel (line) deltas; the event lands at `atView` (default: canvas center).
    ///
    /// Synthesized `NSEvent`s never carry `scrollingDeltaX/Y` (AppKit fills them only for
    /// events from the window server — they read 0 on any `NSEvent(cgEvent:)`), so this
    /// drives `CanvasNavigation.scroll` with the same values the real
    /// `CanvasView.scrollWheel(with:)` override forwards; that override is a pure
    /// value-forward of the event's accessors.
    func scroll(dx: CGFloat, dy: CGFloat, precise: Bool,
                modifiers: NSEvent.ModifierFlags = [], at view: CGPoint? = nil) {
        let canvas = canvasView
        guard let navigation = canvas.navigation else {
            Issue.record("the canvas has no navigation")
            return
        }
        let viewPoint = view ?? CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        navigation.scroll(deltaX: Double(dx), deltaY: Double(dy), isPrecise: precise,
                          zoomModifiers: modifiers.contains(.command), atView: viewPoint)
    }

    /// Pinch zoom around a canvas-view point (0004, CAN-2). macOS vends no public factory
    /// for `.magnify` events, so — exactly like `scroll` — this drives
    /// `CanvasNavigation.magnify` with the same values the real
    /// `CanvasView.magnify(with:)` override forwards from `NSEvent.magnification` and
    /// `locationInWindow` (AGENTS.md *Headless testing*).
    func pinch(magnification: Double, at view: CGPoint? = nil) {
        let canvas = canvasView
        guard let navigation = canvas.navigation else {
            Issue.record("the canvas has no navigation")
            return
        }
        let viewPoint = view ?? CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        navigation.magnify(magnification: magnification, atView: viewPoint)
    }

    private func sendMouse(_ type: NSEvent.EventType, atView point: CGPoint,
                           to deliver: (NSEvent) -> Void) {
        let canvas = canvasView
        let event = mouse(type, at: canvas.convert(point, to: nil))
        deliver(event)
    }
}

// MARK: - Tools (spec 0006)

/// Which physical button `clickCanvas`/`dragCanvas` synthesize.
enum CanvasPointerButton {
    case left
    case right
}

extension DocumentHarness {
    /// Sends a synthesized keyDown through the app's one shortcut entry point
    /// (`CanvasInputRouter.handleShortcutKeyDown`) with `appModel`; `in:` overrides the
    /// key window (headless runs have none). `keyCode` is the virtual key code the real
    /// keyboard would deliver (0018: ⌫ = 51 with `"\u{7F}"`, ⌦ = 117 with `"\u{F728}"`).
    /// The 0018 selection-pixel actions dispatch through this harness's responder-chain
    /// lookup — the headless equivalent of AppKit's `sendAction(to: nil)` from the key
    /// window's chain.
    @discardableResult
    func shortcut(_ characters: String, keyCode: UInt16 = 0,
                  modifiers: NSEvent.ModifierFlags = [],
                  in keyWindow: NSWindow? = nil) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: (keyWindow ?? window).windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )
        guard let event else {
            Issue.record("could not synthesize a keyDown event")
            return false
        }
        return CanvasInputRouter.handleShortcutKeyDown(event, model: appModel,
                                                       keyWindow: keyWindow ?? window) { [weak self] selector in
            guard let self, let target = self.target(for: selector) else { return false }
            return NSApp.sendAction(selector, to: target, from: nil)
        }
    }

    private func deliver(_ type: NSEvent.EventType, atView point: CGPoint,
                         modifiers: NSEvent.ModifierFlags,
                         to deliverEvent: (NSEvent) -> Void) {
        let canvas = canvasView
        let event = mouse(type, at: canvas.convert(point, to: nil), modifiers: modifiers)
        deliverEvent(event)
    }

    /// A synthesized press (down+up) on the canvas at a canvas-view point, delivered to
    /// `CanvasView`'s overrides — which route through `CanvasInputRouter`.
    func clickCanvas(at point: CGPoint, button: CanvasPointerButton = .left,
                     modifiers: NSEvent.ModifierFlags = []) {
        let canvas = canvasView
        switch button {
        case .left:
            deliver(.leftMouseDown, atView: point, modifiers: modifiers) {
                canvas.mouseDown(with: $0)
            }
            deliver(.leftMouseUp, atView: point, modifiers: modifiers) {
                canvas.mouseUp(with: $0)
            }
        case .right:
            deliver(.rightMouseDown, atView: point, modifiers: modifiers) {
                canvas.rightMouseDown(with: $0)
            }
            deliver(.rightMouseUp, atView: point, modifiers: modifiers) {
                canvas.rightMouseUp(with: $0)
            }
        }
    }

    /// A synthesized drag on the canvas: down, `steps` drags, up.
    func dragCanvas(from start: CGPoint, to end: CGPoint, steps: Int = 4,
                    button: CanvasPointerButton = .left,
                    modifiers: NSEvent.ModifierFlags = []) {
        canvasPress(at: start, button: button, modifiers: modifiers)
        for step in 1...max(1, steps) {
            let fraction = CGFloat(step) / CGFloat(max(1, steps))
            let point = CGPoint(x: start.x + (end.x - start.x) * fraction,
                                y: start.y + (end.y - start.y) * fraction)
            canvasDrag(to: point, button: button, modifiers: modifiers)
        }
        canvasRelease(at: end, button: button, modifiers: modifiers)
    }

    // Individual drag phases (spec 0013): tests that need a *pending* stroke — press,
    // drag, some other action, release.

    func canvasPress(at point: CGPoint, button: CanvasPointerButton = .left,
                     modifiers: NSEvent.ModifierFlags = []) {
        let canvas = canvasView
        switch button {
        case .left: deliver(.leftMouseDown, atView: point, modifiers: modifiers) { canvas.mouseDown(with: $0) }
        case .right: deliver(.rightMouseDown, atView: point, modifiers: modifiers) { canvas.rightMouseDown(with: $0) }
        }
    }

    func canvasDrag(to point: CGPoint, button: CanvasPointerButton = .left,
                    modifiers: NSEvent.ModifierFlags = []) {
        let canvas = canvasView
        switch button {
        case .left: deliver(.leftMouseDragged, atView: point, modifiers: modifiers) { canvas.mouseDragged(with: $0) }
        case .right: deliver(.rightMouseDragged, atView: point, modifiers: modifiers) { canvas.rightMouseDragged(with: $0) }
        }
    }

    func canvasRelease(at point: CGPoint, button: CanvasPointerButton = .left,
                       modifiers: NSEvent.ModifierFlags = []) {
        let canvas = canvasView
        switch button {
        case .left: deliver(.leftMouseUp, atView: point, modifiers: modifiers) { canvas.mouseUp(with: $0) }
        case .right: deliver(.rightMouseUp, atView: point, modifiers: modifiers) { canvas.rightMouseUp(with: $0) }
        }
    }
}

// MARK: - New Image (spec 0005)

extension DocumentHarness {
    /// Performs the File > New… user story in-process: installs the scripted presenter, a
    /// recording alert presenter, the private pasteboard, and `showsWindows = false` on the
    /// shared `PaintDocumentController`, calls `newDocument(nil)`, and restores the seams.
    /// Returns `nil` (and creates no document) when the flow was cancelled or never accepted;
    /// the window is built but never ordered onto the screen.
    @MainActor
    static func newImage(presenter: NewImagePresenting,
                         pasteboard: NSPasteboard,
                         alerts: RecordingAlertPresenter = RecordingAlertPresenter()) -> DocumentHarness? {
        guard let controller = NSDocumentController.shared as? PaintDocumentController else {
            Issue.record("the shared document controller is not a PaintDocumentController")
            return nil
        }
        let before = Set(NSDocumentController.shared.documents.map { ObjectIdentifier($0) })
        let original = (controller.newImagePresenter, controller.alertPresenter,
                        controller.showsWindows)
        let originalClipboard = ClipboardController.shared
        defer {
            (controller.newImagePresenter, controller.alertPresenter,
             controller.showsWindows) = original
            ClipboardController.shared = originalClipboard
            pasteboard.releaseGlobally()
        }
        // 0021: `newDocument` reads the clipboard through `ClipboardController.shared`.
        ClipboardController.shared = ClipboardController(pasteboard: pasteboard)
        controller.newImagePresenter = presenter
        controller.alertPresenter = alerts
        controller.showsWindows = false
        controller.newDocument(nil)

        guard let created = NSDocumentController.shared.documents.first(
            where: { !before.contains(ObjectIdentifier($0)) }
        ) as? PaintDocument else { return nil }
        if created.windowControllers.isEmpty {
            created.makeWindowControllers()
        }
        guard let windowController = created.windowControllers.first as? DocumentWindowController,
              let window = windowController.window else {
            Issue.record("the new document has no document window controller")
            return nil
        }
        let (appModel, suiteName) = makeAppModel()
        windowController.appModel = appModel
        return DocumentHarness(document: created, windowController: windowController,
                               window: window, appModel: appModel, appModelSuiteName: suiteName)
    }
}

// MARK: - Clipboard (spec 0021)

/// The 0021 clipboard seams on one harness (AGENTS.md *Headless testing*): a private
/// pasteboard behind `ClipboardController.shared`, a `RecordingAlertPresenter` and a
/// `ScriptedPasteExpandPrompt` on the window controller. `restore()` puts everything
/// back and releases the pasteboard; the user's clipboard is never touched.
@MainActor
final class ClipboardHarness {
    let pasteboard: NSPasteboard
    let alerts: RecordingAlertPresenter
    let prompt: ScriptedPasteExpandPrompt

    private weak var windowController: DocumentWindowController?
    private let original: (shared: ClipboardController, alerts: AlertPresenting,
                           prompt: PasteExpandPrompting?)
    private var restored = false

    fileprivate init(pasteboard: NSPasteboard, windowController: DocumentWindowController,
                     expandChoice: PasteCanvasChoice?) {
        self.pasteboard = pasteboard
        self.windowController = windowController
        self.alerts = RecordingAlertPresenter()
        self.prompt = ScriptedPasteExpandPrompt(choice: expandChoice)
        self.original = (ClipboardController.shared, windowController.alertPresenter,
                         windowController.pasteExpandPrompt)
        ClipboardController.shared = ClipboardController(pasteboard: pasteboard)
        windowController.alertPresenter = alerts
        windowController.pasteExpandPrompt = prompt
    }

    /// Restores `ClipboardController.shared` and the window controller's seams, and
    /// releases the private pasteboard. Idempotent.
    func restore() {
        guard !restored else { return }
        restored = true
        ClipboardController.shared = original.shared
        if let windowController {
            windowController.alertPresenter = original.alerts
            windowController.pasteExpandPrompt = original.prompt
        }
        pasteboard.releaseGlobally()
    }
}

extension DocumentHarness {
    /// Swaps in the 0021 clipboard seams on this harness's window controller; call
    /// `restore()` on the returned token at the test's end (`defer`).
    func useClipboard(_ pasteboard: NSPasteboard,
                      expandChoice: PasteCanvasChoice? = nil) -> ClipboardHarness {
        ClipboardHarness(pasteboard: pasteboard, windowController: windowController,
                         expandChoice: expandChoice)
    }
}

extension DocumentHarness {
    /// Performs Edit > Paste into New Image in-process with no document open (spec 0021
    /// `pasteIntoNewImageWithoutDocument`): swaps `ClipboardController.shared` to the
    /// private pasteboard, installs a recording alert presenter and `showsWindows =
    /// false` on the shared `PaintDocumentController`, calls `pasteIntoNewImage(nil)`,
    /// and restores the seams. Returns a harness over the created document, or `nil`
    /// when none was created (the failure cases). The window is never shown.
    @MainActor
    static func pasteIntoNewImage(pasteboard: NSPasteboard,
                                  alerts: RecordingAlertPresenter = RecordingAlertPresenter()
    ) -> DocumentHarness? {
        guard let controller = NSDocumentController.shared as? PaintDocumentController else {
            Issue.record("the shared document controller is not a PaintDocumentController")
            return nil
        }
        let before = Set(NSDocumentController.shared.documents.map { ObjectIdentifier($0) })
        let original = (controller.alertPresenter, controller.showsWindows)
        let originalClipboard = ClipboardController.shared
        defer {
            (controller.alertPresenter, controller.showsWindows) = original
            ClipboardController.shared = originalClipboard
            pasteboard.releaseGlobally()
        }
        ClipboardController.shared = ClipboardController(pasteboard: pasteboard)
        controller.alertPresenter = alerts
        controller.showsWindows = false
        controller.pasteIntoNewImage(nil)
        guard let created = NSDocumentController.shared.documents.first(
            where: { !before.contains(ObjectIdentifier($0)) }
        ) as? PaintDocument else { return nil }
        if created.windowControllers.isEmpty {
            created.makeWindowControllers()
        }
        guard let windowController = created.windowControllers.first as? DocumentWindowController,
              let window = windowController.window else {
            Issue.record("the pasted document has no document window controller")
            return nil
        }
        let (appModel, suiteName) = makeAppModel()
        windowController.appModel = appModel
        let harness = DocumentHarness(document: created, windowController: windowController,
                                      window: window, appModel: appModel,
                                      appModelSuiteName: suiteName)
        // The window is never ordered onto the screen, so keyboard input needs the
        // canvas as first responder (what showing the window would do).
        window.makeFirstResponder(harness.canvasView)
        return harness
    }
}
