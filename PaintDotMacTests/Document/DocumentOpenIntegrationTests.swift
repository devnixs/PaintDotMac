import AppKit
import Foundation
import Testing
@testable import PaintDotMac

/// Headless integration tests for the user story (spec 0001): open PNG/JPEG through
/// `NSDocumentController` with `display: false`, build windows offscreen, and assert on
/// document, window, and accessibility state. Nothing is ever put on screen.
@MainActor
@Suite(.serialized)
struct DocumentOpenIntegrationTests {
    @Test func opensPNGThroughDocumentController() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup() ; fixtures.removeAll() }

            let url = try fixtures.makePNG(named: "launch-fixture.png", width: 64, height: 48,
                                           rgba: (200, 100, 50, 255))
            let document = try await Self.open(url)
            let paintDocument = try #require(document as? PaintDocument)
            #expect(paintDocument.imagePixelSize == CGSize(width: 64, height: 48))
            #expect(NSDocumentController.shared.documents.count == 1)

            paintDocument.makeWindowControllers()
            let controllers = paintDocument.windowControllers.compactMap { $0 as? DocumentWindowController }
            #expect(controllers.count == 1)
            let window = try #require(controllers.first?.window)
            #expect(window.identifier == NSUserInterfaceItemIdentifier("documentWindow"))
            #expect(window.isVisible == false)
            // The title starts with the base name; whether the extension shows follows the
            // Finder "show extensions" setting, so it is not checked.
            #expect(window.title.hasPrefix("launch-fixture"))
            let canvas = try #require(window.contentView)
            #expect(canvas.accessibilityValue() as? String == "64 × 48")
        }
    }

    @Test func opensJPEGThroughDocumentController() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup() ; fixtures.removeAll() }

            let url = try fixtures.makeJPEG(named: "launch-fixture.jpg", width: 40, height: 30,
                                            rgba: (10, 200, 90, 255))
            let document = try await Self.open(url)
            let paintDocument = try #require(document as? PaintDocument)
            #expect(paintDocument.imagePixelSize == CGSize(width: 40, height: 30))
            #expect(NSDocumentController.shared.documents.count == 1)

            paintDocument.makeWindowControllers()
            let controller = try #require(paintDocument.windowControllers.first as? DocumentWindowController)
            let window = try #require(controller.window)
            #expect(window.isVisible == false)
            let canvas = try #require(window.contentView)
            #expect(canvas.accessibilityValue() as? String == "40 × 30")
        }
    }

    /// The programmatic API does not present the error, so nothing appears on screen; the real
    /// app shows the standard alert (manual step 7).
    @Test func corruptFileFailsWithoutDocument() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup() ; fixtures.removeAll() }

            let url = try fixtures.makeFile(named: "corrupt.png", contents: Data("not an image".utf8))
            let result = await Self.openResult(url)
            #expect(result.document == nil)
            let error = try #require(result.error, "opening a corrupt file must fail") as NSError
            #expect(error.domain == NSCocoaErrorDomain)
            #expect(error.code == CocoaError.Code.fileReadCorruptFile.rawValue)
            #expect(NSDocumentController.shared.documents.isEmpty)
        }
    }

    @Test func missingFileFailsWithoutDocument() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup() ; fixtures.removeAll() }

            let url = fixtures.directory.appendingPathComponent("absent.png")
            let result = await Self.openResult(url)
            #expect(result.document == nil)
            #expect(result.error != nil)
            #expect(NSDocumentController.shared.documents.isEmpty)
        }
    }

    /// Two documents can be merged into native tabs of one window (APP-1); the merge itself is
    /// manual step 5.
    @Test func twoDocumentsShareTabbingIdentifier() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup() ; fixtures.removeAll() }

            let first = try fixtures.makePNG(named: "first.png", width: 30, height: 20, rgba: (1, 2, 3, 255))
            let second = try fixtures.makeJPEG(named: "second.jpg", width: 50, height: 40, rgba: (4, 5, 6, 255))
            let firstHarness = try await DocumentHarness.open(first)
            let secondHarness = try await DocumentHarness.open(second)
            #expect(NSDocumentController.shared.documents.count == 2)

            for harness in [firstHarness, secondHarness] {
                #expect(harness.window.tabbingMode == .automatic)
                #expect(harness.window.tabbingIdentifier == "com.thera-engineering.paintdotmac.document")
                #expect(harness.window.isVisible == false)
            }
            #expect(firstHarness.window.tabbingIdentifier == secondHarness.window.tabbingIdentifier)
        }
    }

    @Test func harnessFindsDocumentActions() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup() ; fixtures.removeAll() }

            let url = try fixtures.makePNG(named: "actions.png", width: 32, height: 24, rgba: (7, 8, 9, 255))
            let harness = try await DocumentHarness.open(url)

            #expect(harness.isEnabled(NSSelectorFromString("saveDocument:")) == false)
            #expect(harness.isEnabled(NSSelectorFromString("saveDocumentAs:")) == false)
            #expect(harness.target(for: #selector(NSWindow.performClose(_:))) === harness.window)
        }
    }

    @Test func uneditedDocumentClosesWithoutPrompt() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup() ; fixtures.removeAll() }

            let url = try fixtures.makePNG(named: "close-me.png", width: 16, height: 12, rgba: (30, 40, 50, 255))
            let harness = try await DocumentHarness.open(url)
            #expect(harness.document.isDocumentEdited == false)
            harness.close()
            #expect(NSDocumentController.shared.documents.isEmpty)
        }
    }

    // MARK: - Helpers

    /// Every test ends by closing documents (never through a path that can prompt) and checking
    /// that nothing became visible.
    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    private static func open(_ url: URL) async throws -> NSDocument {
        let document = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NSDocument, Error>) in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { document, _, error in
                if let document {
                    continuation.resume(returning: document)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
        return document
    }

    /// For the failure cases: returns both halves instead of throwing.
    private static func openResult(_ url: URL) async -> (document: NSDocument?, error: Error?) {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<(NSDocument?, Error?), Never>) in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { document, _, error in
                continuation.resume(returning: (document, error))
            }
        }
    }
}
