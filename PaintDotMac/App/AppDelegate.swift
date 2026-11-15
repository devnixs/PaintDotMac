import AppKit

/// The application delegate for the AppKit lifecycle (PRD §4 UI, D-4).
///
/// The delegate deliberately does **not** implement `application(_:open:)` or
/// `application(_:openFiles:)`: Apple Events from Finder and `open -a` go straight to
/// `NSDocumentController.shared`. Drops on the Dock icon and the app (FMT-C) arrive in 0030.
/// There are no launch hooks and no `-UITest*` arguments; tests configure the app in-process.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// App-wide tool/panel state (0006). Settable so integration tests install a model on a
    /// throwaway suite; the local key monitor below always uses this instance.
    var appModel = AppModel.shared
    /// The four floating panels (APP-2). Also settable for tests; `PanelController.current`
    /// points at the newest instance.
    private(set) var panelController: PanelController?

    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // `NSDocumentController.init` registers the receiver as the shared controller when
        // none exists yet, so creating it here — before anything touches
        // `NSDocumentController.shared` — makes our subclass the shared one (spec 0005).
        _ = PaintDocumentController()
        MainMenu.install(in: NSApp)
        panelController = PanelController(model: appModel)
        // At launch nothing is shown (test-host or not: no document windows exist yet).
        panelController?.refresh()

        // The one single-key shortcut entry point (0006). Consumed events return nil.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                CanvasInputRouter.handleShortcutKeyDown(event, model: self?.appModel ?? .shared)
            } ? nil : event
        }
    }

    /// Permanent: the app never opens an untitled document at launch, also after the New Image
    /// dialog exists (0005). New images come only from File > New (⌘N).
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// The Mac document-app convention: the app keeps running with no windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Panel toggles (APP-2, ⌥⌘1–4)

    /// The Window menu items' action; `representedObject` carries the `PanelKind` raw value.
    @objc func togglePanel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = PanelKind(rawValue: raw) else { return }
        appModel.togglePanel(kind)
        // `current` is the newest controller (an integration test may own it).
        PanelController.current?.refresh()
    }

    /// Checkmark = visible; enabled iff a document window is open (spec 0006).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == MainMenu.togglePanelAction,
              let raw = menuItem.representedObject as? String,
              let kind = PanelKind(rawValue: raw) else { return true }
        menuItem.state = appModel.isPanelVisible(kind) ? .on : .off
        return PanelController.hasDocumentWindow
    }
}
