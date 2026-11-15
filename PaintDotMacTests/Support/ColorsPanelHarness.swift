import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PaintDotMac

/// Headless driver for the Colors panel (spec 0007): hosts `ColorsPanelView` in an offscreen
/// `NSHostingView` with a throwaway `AppModel` suite, the pattern 0006 established for the Tools
/// panel. Nothing is ever ordered on screen (AGENTS.md, *Headless testing*); a focusable text
/// field is never made first responder — tests drive `ColorsPanelFields.commitHex` and
/// `ColorsPanelFields.commit` exactly as Return does — and `dispose()` closes the stash window the
/// field editor can end up in, never the panel's own window (the 0006 field-editor trap).
@MainActor
final class ColorsPanelHarness {
    let model: AppModel
    let fields: ColorsPanelFields
    let hosting: NSHostingView<AnyView>
    let window: NSWindow
    /// The panel window the production `PanelController` would use, hosting the same view, for
    /// the ⌥⌘4 and single-key tests.
    let panels: PanelController
    let suiteName: String
    /// Restored on `dispose()`: `PanelController.init` installs itself as `current`, and other
    /// suites install their own (0006).
    private let priorPanelController: PanelController?

    /// The window the shared field editor is moved into before anything closes (0006's
    /// `DocumentHarness.closeStashingFieldEditor`, same reason).
    private static let stash = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 8, height: 8),
        styleMask: .borderless, backing: .buffered, defer: false
    )

    convenience init(primary: ColorRGBA8 = .black, secondary: ColorRGBA8 = .white,
                     expanded: Bool = false, activeSlot: ColorSlot = .primary) throws {
        let name = "ColorsPanelHarness.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        store.set(ColorHex.format(primary, includeAlpha: true), forKey: ColorSelectionStore.primaryKey)
        store.set(ColorHex.format(secondary, includeAlpha: true),
                  forKey: ColorSelectionStore.secondaryKey)
        store.set(expanded, forKey: ColorSelectionStore.panelExpandedKey)
        self.init(store: store, suiteName: name, activeSlot: activeSlot)
    }

    /// The same suite, no reseeding: what the next launch reads back.
    convenience init(reusingSuiteNamed existing: String, activeSlot: ColorSlot = .primary) throws {
        let store = try #require(UserDefaults(suiteName: existing), "no suite \(existing)")
        self.init(store: store, suiteName: existing, activeSlot: activeSlot)
    }

    private init(store: UserDefaults, suiteName: String, activeSlot: ColorSlot) {
        self.suiteName = suiteName
        model = AppModel(defaults: store)
        model.setActiveColorSlot(activeSlot)
        fields = ColorsPanelFields()
        hosting = NSHostingView(rootView: AnyView(ColorsPanelView(model: model, fields: fields)))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "ColorsPanelHarness"
        // The real Colors panel window carries this identifier, and the router's key-window gate
        // reads it, so the harness window does too (spec 0006/0007).
        window.identifier = NSUserInterfaceItemIdentifier("panel.colors")
        window.isReleasedWhenClosed = false
        // Never ordered on screen, unlike a real panel window.
        window.contentView = hosting
        window.layoutIfNeeded()
        priorPanelController = PanelController.current
        panels = PanelController(model: model)
    }

    func dispose() {
        stashFieldEditor()
        for panel in panels.panels.values {
            panel.orderOut(nil)
        }
        window.close()
        PanelController.current = priorPanelController
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    /// The shared field editor belongs to whichever window was last key; closing a window that
    /// contains it crashes (0006), so it goes to the throwaway stash first.
    private func stashFieldEditor() {
        guard let editor = window.fieldEditor(true, for: nil), editor.window !== Self.stash else {
            return
        }
        Self.stash.contentView?.addSubview(editor)
    }

    // MARK: - Reads

    func identifierSet() -> Set<String> {
        pumpMainRunLoop()
        return AX.withAccessibilityClient { Set(AX.identifiers(inRoot: hosting)) }
    }

    func containsStaticText(_ text: String) -> Bool {
        pumpMainRunLoop()
        return AX.withAccessibilityClient { AX.containsStaticText(inRoot: hosting, text) }
    }

    /// The accessibility value of one element, as VoiceOver would read it.
    func accessibilityValue(_ identifier: String) throws -> String {
        pumpMainRunLoop()
        return try AX.withAccessibilityClient {
            let element = try #require(AX.first(inRoot: hosting, identifier: identifier),
                                      "no accessibility element \(identifier)")
            return try #require(AX.value(of: element), "\(identifier) exposes no value")
        }
    }

    func isSelected(_ identifier: String) throws -> Bool {
        pumpMainRunLoop()
        return AX.withAccessibilityClient { AX.isSelected(inRoot: hosting, identifier: identifier) }
    }

    /// The accessibility title of one element (a button's readable title text).
    func accessibilityTitle(_ identifier: String) throws -> String {
        pumpMainRunLoop()
        return try AX.withAccessibilityClient {
            let element = try #require(AX.first(inRoot: hosting, identifier: identifier),
                                      "no accessibility element \(identifier)")
            let title = AX.title(of: element) ?? AX.label(of: element)
            return try #require(title, "\(identifier) exposes no title or label")
        }
    }

    /// VoiceOver increment/decrement on one adjustable element, returning how many of the
    /// `limit` calls the element accepted (one accessibility-client scope, no per-step pump:
    /// the binding runs the model change synchronously).
    func driveAdjustable(_ identifier: String, up: Bool, limit: Int,
                         while condition: (AppModel) -> Bool) throws -> Int {
        pumpMainRunLoop()
        return try AX.withAccessibilityClient {
            let element = try #require(AX.first(inRoot: hosting, identifier: identifier),
                                       "no accessibility element \(identifier)")
            var performed = 0
            while performed < limit, condition(model) {
                guard (up ? AX.increment(element) : AX.decrement(element)) else { break }
                performed += 1
            }
            withExtendedLifetime(element) {}
            return performed
        }
    }

    func pressButton(_ identifier: String) throws {
        pumpMainRunLoop()
        try AX.withAccessibilityClient {
            _ = try #require(AX.pressButton(inRoot: hosting, identifier: identifier),
                             "no button \(identifier)")
        }
        pumpMainRunLoop()
    }

    /// The panel's text fields in tree order — the hex box first, then R, G, B, H, S, V, A.
    func textFields() -> [NSTextField] {
        pumpMainRunLoop()
        var found: [NSTextField] = []
        func search(_ view: NSView) {
            if let field = view as? NSTextField { found.append(field) }
            view.subviews.forEach(search)
        }
        search(hosting)
        return found
    }

    /// Makes a text field the window's first responder, as clicking into it does. The shared field
    /// editor moves into this window, which is why `dispose()` stashes it before closing (0006).
    @discardableResult
    func focus(_ field: NSTextField) -> NSTextField {
        window.makeFirstResponder(field)
        pumpMainRunLoop()
        return field
    }

    /// The wheel's AppKit view, reached through the hosting view's subviews.
    func wheelView() throws -> ColorWheelNSView {
        pumpMainRunLoop()
        func search(_ view: NSView) -> ColorWheelNSView? {
            if let match = view as? ColorWheelNSView { return match }
            for child in view.subviews {
                if let match = search(child) { return match }
            }
            return nil
        }
        return try #require(search(hosting), "the Colors panel has no color wheel view")
    }

    // MARK: - Wheel gestures

    enum WheelButton {
        case left
        case right
        case leftWithControl
    }

    enum WheelPhase {
        case down
        case dragged
        case up
    }

    /// The view point for a hue/saturation on the wheel, through the same geometry the view
    /// hit-tests, so a gesture asks for exactly the colour it names.
    func wheelPoint(hue: Double, saturation: Double) throws -> CGPoint {
        let wheel = try wheelView()
        let radius = Double(min(wheel.bounds.width, wheel.bounds.height)) / 2
        return ColorWheelGeometry.point(hue: hue, saturation: saturation,
                                       center: CGPoint(x: wheel.bounds.midX, y: wheel.bounds.midY),
                                       radius: radius)
    }

    /// One pointer event on the wheel, with the button and modifiers the spec names.
    func wheel(_ phase: WheelPhase, hue: Double, saturation: Double,
               button: WheelButton = .left, modifiers: NSEvent.ModifierFlags = []) throws {
        let wheel = try wheelView()
        let point = try wheelPoint(hue: hue, saturation: saturation)
        let type: NSEvent.EventType
        var flags = modifiers
        switch (phase, button) {
        case (.down, .left), (.down, .leftWithControl): type = .leftMouseDown
        case (.dragged, .left), (.dragged, .leftWithControl): type = .leftMouseDragged
        case (.up, .left), (.up, .leftWithControl): type = .leftMouseUp
        case (.down, .right): type = .rightMouseDown
        case (.dragged, .right): type = .rightMouseDragged
        case (.up, .right): type = .rightMouseUp
        }
        if button == .leftWithControl { flags.insert(.control) }
        let event = try Self.mouseEvent(type, at: wheel.convert(point, to: nil), modifiers: flags)
        switch type {
        case .leftMouseDown: wheel.mouseDown(with: event)
        case .leftMouseDragged: wheel.mouseDragged(with: event)
        case .leftMouseUp: wheel.mouseUp(with: event)
        case .rightMouseDown: wheel.rightMouseDown(with: event)
        case .rightMouseDragged: wheel.rightMouseDragged(with: event)
        default: wheel.rightMouseUp(with: event)
        }
        pumpMainRunLoop()
    }

    /// `NSEvent.mouseEvent(with:…)` is the available factory; `init(type:…)` is unavailable in
    /// Swift. The event number is the hardware button: 0 left, 1 right.
    private static func mouseEvent(_ type: NSEvent.EventType, at windowPoint: CGPoint,
                                   modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        let isRight = type == .rightMouseDown || type == .rightMouseDragged || type == .rightMouseUp
        let event = NSEvent.mouseEvent(
            with: type, location: windowPoint, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            eventNumber: isRight ? 1 : 0, clickCount: 1, pressure: 1
        )
        return try #require(event, "could not synthesize a \(type.rawValue) event")
    }

    // MARK: - Keys

    /// A synthesized key-down through the router's one entry point, with `keyWindow` standing in
    /// for the offscreen window (headless runs have no key window).
    @discardableResult
    func shortcut(_ characters: String, modifiers: NSEvent.ModifierFlags = [],
                  isRepeat: Bool = false, in keyWindow: NSWindow? = nil) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: (keyWindow ?? window).windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: isRepeat, keyCode: 0
        )
        guard let event else {
            Issue.record("could not synthesize a keyDown event")
            return false
        }
        let handled = CanvasInputRouter.handleShortcutKeyDown(event, model: model,
                                                             keyWindow: keyWindow ?? window)
        pumpMainRunLoop()
        return handled
    }

    /// A window that is not the Colors panel and not a document window: what `Window` ⇧⌥⌘4 and
    /// the router's `keyWindow` test seam need (spec 0007's key-window cases).
    func makeKeyWindow(identifyingAs kind: PanelKind? = nil, titled title: String = "Harness Key")
        -> NSWindow {
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        other.title = title
        other.isReleasedWhenClosed = false
        if let kind {
            other.identifier = NSUserInterfaceItemIdentifier("panel.\(kind.rawValue)")
        }
        return other
    }
}
