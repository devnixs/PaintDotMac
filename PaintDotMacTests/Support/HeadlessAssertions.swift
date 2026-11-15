import AppKit
import Testing

/// Shared headless checks; every integration test that creates a document or window calls both
/// at its end (AGENTS.md *Headless testing*).
@MainActor
enum HeadlessAssertions {
    /// Records an issue for every window that became visible.
    static func noVisibleWindows(sourceLocation: SourceLocation = #_sourceLocation) {
        for window in NSApp.windows where window.isVisible {
            let identifier = window.identifier?.rawValue ?? "none"
            Issue.record(
                "a window became visible during the test: \(type(of: window)) (identifier: \(identifier))",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Closes every open document with `close()` — never through a path that can prompt — so
    /// tests do not leak documents into each other.
    static func closeAllDocuments() {
        for document in NSDocumentController.shared.documents {
            document.close()
        }
    }
}
