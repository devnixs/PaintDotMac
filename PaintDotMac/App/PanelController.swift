import AppKit
import SwiftUI

/// The four app-wide floating panels (PRD APP-2, D-5/D-36; spec 0006). Pure metadata:
/// titles, Window-menu key equivalents, persistence names, and the default frames.
enum PanelKind: String, CaseIterable {
    case tools
    case history
    case layers
    case colors

    var title: String {
        switch self {
        case .tools: "Tools"
        case .history: "History"
        case .layers: "Layers"
        case .colors: "Colors"
        }
    }

    /// Window menu key equivalents "1"…"4" (⌥⌘1–4, PRD §5.12).
    var menuKeyEquivalent: String {
        switch self {
        case .tools: "1"
        case .history: "2"
        case .layers: "3"
        case .colors: "4"
        }
    }

    static let menuKeyEquivalentModifiers: NSEvent.ModifierFlags = [.command, .option]

    /// AppKit stores `NSWindow Frame panel.<kind>` (mapped to a `test.` prefix in test-host
    /// mode by `AppDefaults.frameAutosaveName(_:)`).
    var frameAutosaveName: String { "panel.\(rawValue)" }
    var visibilityDefaultsKey: String { "panel.\(rawValue).visible" }
    var accessibilityIdentifier: String { "\(rawValue)Panel" }
    var menuItemIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("menu.window.panel.\(rawValue)")
    }

    /// Paint.NET's default layout, margin 16 pt: Tools top-left, History top-right,
    /// Layers bottom-right, Colors bottom-left. Only History/Layers/Colors resize.
    var isResizable: Bool { self != .tools }

    static func defaultFrame(for kind: PanelKind, size: CGSize, visibleFrame: CGRect) -> CGRect {
        let margin: CGFloat = 16
        let x = (kind == .tools || kind == .colors)
            ? visibleFrame.minX + margin
            : visibleFrame.maxX - margin - size.width
        let y = (kind == .tools || kind == .history)
            ? visibleFrame.maxY - margin - size.height
            : visibleFrame.minY + margin
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// `CanvasInputRouter` classifies key windows with this: panel windows carry the
    /// `panel.<kind>` window identifier.
    static func isPanelWindowIdentifier(_ identifier: NSUserInterfaceItemIdentifier?) -> Bool {
        identifier?.rawValue.hasPrefix("panel.") == true
    }
}

/// Owns the four floating `NSPanel`s (PRD APP-2; spec 0006), built at launch by
/// `AppDelegate`. A panel is on screen iff its kind is visible in `AppModel` and at least
/// one document window exists; in test-host mode `refresh()` never orders one on screen and
/// only records the decision in `lastAppliedVisibility`.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    /// The instance the document windows talk to (set by the newest controller — in the
    /// app that is `AppDelegate`'s; integration tests install their own).
    static weak var current: PanelController?

    let model: AppModel
    private(set) var panels: [PanelKind: NSPanel] = [:]
    /// What `refresh()` last applied per kind (the headless record of the order decisions).
    private(set) var lastAppliedVisibility: [PanelKind: Bool] = [:]

    init(model: AppModel) {
        self.model = model
        super.init()
        for kind in PanelKind.allCases {
            panels[kind] = makePanel(kind)
        }
        Self.current = self
    }

    /// A document exists that has a window controller with the `documentWindow` identifier.
    static var hasDocumentWindow: Bool { hasDocumentWindow(excluded: nil) }

    /// As `hasDocumentWindow`, treating `excluded` as already closed.
    static func hasDocumentWindow(excluded: NSWindow?) -> Bool {
        NSDocumentController.shared.documents.contains { document in
            document.windowControllers.contains { controller in
                guard let window = controller.window,
                      window.identifier == DocumentWindowController.windowIdentifier,
                      window !== excluded
                else { return false }
                return true
            }
        }
    }

    /// The pure showing rule (spec 0006).
    func shouldShow(_ kind: PanelKind) -> Bool {
        model.isPanelVisible(kind) && Self.hasDocumentWindow
    }

    /// Applies `shouldShow` — `orderFront(nil)` (never `makeKey`) / `orderOut(nil)` — except
    /// in test-host mode, where nothing is ever ordered on screen. `excludingWindow` lets a
    /// closing window request the post-close state before AppKit has dropped it from its
    /// document (the `windowWillClose` path).
    func refresh(excludingWindow: NSWindow? = nil) {
        for kind in PanelKind.allCases {
            let show = model.isPanelVisible(kind) && Self.hasDocumentWindow(excluded: excludingWindow)
            lastAppliedVisibility[kind] = show
            guard !TestHost.isActive, let panel = panels[kind] else { continue }
            if show {
                panel.orderFront(nil)
            } else {
                panel.orderOut(nil)
            }
        }
    }

    func kind(for window: NSWindow) -> PanelKind? {
        for (kind, panel) in panels where panel === window { return kind }
        return nil
    }

    // MARK: - NSWindowDelegate

    /// Only the close button persists "hidden" — app quit closes windows without this
    /// callback, so it never does.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let kind = kind(for: sender) else { return true }
        model.setPanelVisible(kind, false)
        sender.orderOut(nil)
        return false
    }

    /// ⌘Z typed while a panel is key must undo on the current document (0008); without
    /// this the responder chain dead-ends at the panel's own (empty) undo manager.
    /// The `documents.last` fallback only matters when no document window is main or key
    /// — impossible while panels are on screen in the app, and the normal state of an
    /// off-screen window in the headless tests.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        let controller = NSDocumentController.shared
        let document = (controller.currentDocument as? PaintDocument)
            ?? controller.documents.last as? PaintDocument
        return document?.undoBridge.undoManager
    }

    // MARK: - Panel construction

    private func content(for kind: PanelKind) -> AnyView {
        switch kind {
        case .tools:
            AnyView(ToolsPanelView(model: model))
        case .colors:
            AnyView(ColorsPanelView(model: model))
        case .history, .layers:
            // 0010 and 0025 replace their case with real content (D-36).
            AnyView(PanelPlaceholderView(kind: kind))
        }
    }

    private func makePanel(_ kind: PanelKind) -> NSPanel {
        let hosting = NSHostingView(rootView: content(for: kind))
        hosting.sizingOptions = [.intrinsicContentSize]
        var contentSize = hosting.intrinsicContentSize
        if contentSize.width <= 0 || contentSize.height <= 0 {
            contentSize = CGSize(width: 200, height: 200)
        }
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .utilityWindow]
        if kind.isResizable { styleMask.insert(.resizable) }
        let panel = PanelWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: styleMask, backing: .buffered, defer: false
        )
        panel.keepsTopLeftOnResize = kind.isResizable
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        // Clicking a tool button must not take key status from the document window, so
        // tool keys keep working (spec 0006).
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.title = kind.title
        panel.identifier = NSUserInterfaceItemIdentifier("panel.\(kind.rawValue)")
        panel.delegate = self
        panel.contentView = hosting

        // Frames persist under the mapped autosave name; a frame saved on a display that
        // is gone is constrained by AppKit, and a missing name falls back to the default.
        let autosaveName = AppDefaults.frameAutosaveName(kind.frameAutosaveName)
        if !panel.setFrameUsingName(autosaveName) {
            panel.setFrame(
                PanelKind.defaultFrame(for: kind, size: contentSize,
                                       visibleFrame: NSScreen.main?.visibleFrame
                                           ?? CGRect(x: 0, y: 0, width: 1440, height: 900)),
                display: false
            )
        }
        panel.setFrameAutosaveName(autosaveName)
        return panel
    }
}

/// A panel window that keeps its **top-left** corner fixed when its SwiftUI content drives a
/// resize. AppKit's content-driven resize anchors the bottom-left, which would drag the title bar
/// down as the Colors panel grows under `More »` (spec 0007: "the panel window resizes to fit,
/// keeping its top-left corner fixed"). Only height-only changes are re-anchored, so a
/// user's drag of a panel edge keeps following the pointer.
@MainActor
final class PanelWindow: NSPanel {
    var keepsTopLeftOnResize = false

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard keepsTopLeftOnResize, frameRect.width == frame.width,
              frameRect.height != frame.height
        else {
            super.setFrame(frameRect, display: flag)
            return
        }
        var pinned = frameRect
        pinned.origin.y = frame.maxY - frameRect.height
        super.setFrame(pinned, display: flag)
    }

    /// AppKit's content-driven resize may arrive here instead of `setFrame(_:display:)`.
    override func setContentSize(_ size: NSSize) {
        guard keepsTopLeftOnResize, size != contentView?.frame.size else {
            super.setContentSize(size)
            return
        }
        let top = frame.maxY
        let left = frame.minX
        super.setContentSize(size)
        setFrameTopLeftPoint(NSPoint(x: left, y: top))
    }
}
