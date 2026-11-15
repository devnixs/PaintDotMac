import Foundation

/// Serializes the tests that share `NSDocumentController.shared` across suites. Swift Testing
/// only serializes within a suite, and `@MainActor` tests still interleave at `await` points —
/// for example while a document open is in flight. Tests that open or close shared documents
/// (`DocumentOpenIntegrationTests`) and tests that assert no document is open
/// (`TestHostTests.noWindowsAtLaunch`) run their whole body inside `withLock`, which also fixes
/// the relative order of both groups regardless of scheduling.
@MainActor
enum TestRunGate {
    private static var isLocked = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private static func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
        // The lock is handed over directly by `release()` before the continuation runs.
    }

    private static func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
