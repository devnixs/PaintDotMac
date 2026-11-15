import AppKit

/// The application delegate for the AppKit lifecycle (PRD §4 UI, D-4).
///
/// The delegate deliberately does **not** implement `application(_:open:)` or
/// `application(_:openFiles:)`: Apple Events from Finder and `open -a` go straight to
/// `NSDocumentController.shared`. Drops on the Dock icon and the app (FMT-C) arrive in 0030.
/// There are no launch hooks and no `-UITest*` arguments; tests configure the app in-process.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install(in: NSApp)
    }

    /// Permanent: the app never opens an untitled document at launch, also after the New Image
    /// dialog exists (0005). New images come only from File > New (⌘N).
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// The Mac document-app convention: the app keeps running with no windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
