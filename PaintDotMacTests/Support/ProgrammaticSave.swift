import AppKit
import Foundation

/// Awaits `NSDocument.save(to:ofType:for:completionHandler:)` — the programmatic save path.
/// It never runs a panel; failures arrive as the completion's error, which this rethrows.
@MainActor
func saveDocument(_ document: NSDocument, to url: URL, ofType typeName: String,
                  for saveOperation: NSDocument.SaveOperationType) async throws {
    // In a windowless process (the headless test host has no Dock presence), AppKit's file
    // coordinator runs the whole save — including its finisher, which updates the document's
    // window controllers (represented URL, edited dot) — on a background queue. A never-shown
    // window services those notifications inline and AppKit raises "NSWindow geometry should
    // only be modified on the main thread!". Shown windows in the real app coalesce the same
    // updates onto the main thread, so this is a test-host-only hazard: save with the window
    // controllers detached and reattach them afterwards.
    let controllers = document.windowControllers
    controllers.forEach(document.removeWindowController)
    defer { controllers.forEach(document.addWindowController) }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        document.save(to: url, ofType: typeName, for: saveOperation) { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}
