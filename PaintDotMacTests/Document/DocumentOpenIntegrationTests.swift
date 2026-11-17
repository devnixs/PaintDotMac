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
            #expect(paintDocument.image.size == PixelSize(width: 64, height: 48))
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
            let canvas = try #require(controllers.first?.canvasView)
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
            #expect(paintDocument.image.size == PixelSize(width: 40, height: 30))
            #expect(NSDocumentController.shared.documents.count == 1)

            paintDocument.makeWindowControllers()
            let controller = try #require(paintDocument.windowControllers.first as? DocumentWindowController)
            let window = try #require(controller.window)
            #expect(window.isVisible == false)
            let canvas = try #require(controller.canvasView)
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
            let error = try #require(result.error, "opening a corrupt file must fail")
            #expect(Self.codecError(in: error) == .unrecognizedFormat,
                    "expected ImageCodecError.unrecognizedFormat, got \(error)")
            // NSDocumentController wraps our error; its underlying error carries the text.
            let codecError = (error as? ImageCodecError)
                ?? (error as NSError).userInfo[NSUnderlyingErrorKey] as? ImageCodecError
            #expect(codecError?.localizedDescription.contains("isn\u{2019}t a supported image") == true,
                    "the alert text comes from ImageCodecError: \(error.localizedDescription)")
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

            // 0005: 0001's PaintDocument override that disabled the save actions is gone —
            // Save and Save As… are enabled for an open document (the File menu items
            // `MainMenuTests.fileMenuItems` pins). saveTo/revert/duplicate follow standard
            // `NSDocument` validation now; no File menu item uses them in M0.
            #expect(harness.isEnabled(NSSelectorFromString("saveDocument:")))
            #expect(harness.isEnabled(NSSelectorFromString("saveDocumentAs:")))
            // Acceptance: Undo stays disabled at the base step and Open… stays
            // enabled. 0013: `selectAll:` is answered by the window controller and
            // enabled for any open document. 0021 implements the clipboard actions:
            // Copy is enabled with a document open, Cut stays disabled while there is
            // no selection. Paste / Paste into New Image depend on the pasteboard —
            // their matrix is pinned in `ClipboardWindowIntegrationTests.menuEnablement`
            // on a private pasteboard, never asserted against the user's clipboard.
            #expect(harness.isEnabled(NSSelectorFromString("undo:")) == false,
                    "undo: stays disabled at the base step")
            #expect(harness.isEnabled(NSSelectorFromString("copy:")),
                    "0021: Copy is enabled with a document open")
            #expect(harness.isEnabled(NSSelectorFromString("cut:")) == false,
                    "0021: Cut needs a selection")
            #expect(harness.isEnabled(NSSelectorFromString("selectAll:")),
                    "0013: Select All is enabled with a document open")
            #expect(harness.isEnabled(#selector(NSDocumentController.openDocument(_:))))
            #expect(harness.isEnabled(#selector(NSWindow.performClose(_:))))
            #expect(harness.target(for: #selector(NSWindow.performClose(_:))) === harness.window)
        }
    }

    @Test func performCloseActionClosesUneditedDocument() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup() ; fixtures.removeAll() }

            let url = try fixtures.makePNG(named: "perform-close.png", width: 16, height: 12,
                                           rgba: (30, 40, 50, 255))
            let harness = try await DocumentHarness.open(url)
            // The ⌘W story end to end: the menu's performClose: (MainMenuTests.fileMenuItems
            // pins the binding) goes to the window, and an unedited viewer document closes
            // without any prompt.
            harness.perform(#selector(NSWindow.performClose(_:)))
            #expect(NSDocumentController.shared.documents.isEmpty)
            #expect(harness.window.isVisible == false)
        }
    }

    /// Edge case: opening the same file twice keeps NSDocumentController's standard behavior —
    /// the already-open document is returned, and no second document is created.
    @Test func openingSameFileTwiceYieldsOneDocument() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup() ; fixtures.removeAll() }

            let url = try fixtures.makePNG(named: "twice.png", width: 24, height: 16, rgba: (5, 6, 7, 255))
            let first = try await Self.open(url)
            let second = try await Self.open(url)
            #expect(second === first)
            #expect(NSDocumentController.shared.documents.count == 1)
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

    /// The `ImageCodecError`, directly or as the document controller's underlying error.
    static func codecError(in error: Error) -> ImageCodecError? {
        (error as? ImageCodecError) ?? (error as NSError).userInfo[NSUnderlyingErrorKey] as? ImageCodecError
    }

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
