import AppKit
import Foundation
import Testing
@testable import PaintDotMac

/// Headless File > New… integration tests (spec 0005): the user story runs in-process
/// through `PaintDocumentController.newDocument(_:)` with scripted presenters and a private
/// pasteboard. No dialog, alert, or window is ever shown; each test ends by closing all
/// documents and checking that nothing became visible.
@MainActor
@Suite(.serialized)
struct NewImageIntegrationTests {
    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    /// The status bar shows plain pixel sizes when the shared unit is Pixels (0004).
    private func resetUnit() {
        AppSettings().measurementUnit = .pixels
    }

    @Test func newImageDefaultsWithoutClipboard() async throws {
        try await TestRunGate.withLock {
            defer { cleanup() }
            resetUnit()
            let presenter = ScriptedNewImagePresenter(steps: [.ok])
            let harness = try #require(
                DocumentHarness.newImage(presenter: presenter, pasteboard: makePrivatePasteboard())
            )

            // Prefilled 800 / 600 / 96 when the clipboard holds no image (APP-9).
            let form = try #require(presenter.presentedForms.first)
            #expect(form.widthText == "800")
            #expect(form.heightText == "600")
            #expect(form.resolutionText == "96")

            // One untitled document, windows built but never shown.
            #expect(NSDocumentController.shared.documents.count == 1)
            #expect(harness.document.fileURL == nil)
            #expect(harness.document.displayName.hasPrefix("Untitled"))
            #expect(harness.canvasView.accessibilityValue() as? String == "800 × 600")
            #expect(harness.statusBar.imageSizeText == "800 × 600")
            #expect(harness.window.isVisible == false)
        }
    }

    @Test func newImageUsesClipboardSize() async throws {
        try await TestRunGate.withLock {
            defer { cleanup() }
            resetUnit()
            let pasteboard = makePrivatePasteboard()
            writeImage(width: 123, height: 45, to: pasteboard)
            let presenter = ScriptedNewImagePresenter(steps: [.ok])
            let harness = try #require(
                DocumentHarness.newImage(presenter: presenter, pasteboard: pasteboard)
            )

            // Width/Height come from the clipboard image; Resolution stays 96 (its DPI is
            // ignored, D-30).
            let form = try #require(presenter.presentedForms.first)
            #expect(form.widthText == "123")
            #expect(form.heightText == "45")
            #expect(form.resolutionText == "96")
            #expect(harness.document.image.size == PixelSize(width: 123, height: 45))
            #expect(harness.statusBar.imageSizeText == "123 × 45")
        }
    }

    @Test func newImageCancelCreatesNothing() async throws {
        // Nothing in this body throws, so no `try` — Xcode 27 flags the redundant marker.
        await TestRunGate.withLock {
            defer { cleanup() }
            let before = NSDocumentController.shared.documents.count
            let presenter = ScriptedNewImagePresenter(steps: [.cancel])
            let harness = DocumentHarness.newImage(presenter: presenter,
                                                   pasteboard: makePrivatePasteboard())
            #expect(harness == nil)
            #expect(NSDocumentController.shared.documents.count == before)
            #expect(presenter.okResults.isEmpty)
        }
    }

    @Test func newImageRejectsInvalidWidth() async throws {
        try await TestRunGate.withLock {
            defer { cleanup() }
            let presenter = ScriptedNewImagePresenter(
                steps: [.edit(width: "65536"), .ok, .edit(width: "64"), .ok]
            )
            let alerts = RecordingAlertPresenter()
            let harness = try #require(
                DocumentHarness.newImage(presenter: presenter,
                                         pasteboard: makePrivatePasteboard(),
                                         alerts: alerts)
            )

            // The first OK is refused: exactly one alert with the invalid-width message, the
            // form keeps the typed value, and `onOK` returned false.
            #expect(presenter.okResults == [false, true])
            #expect(alerts.alerts.count == 1)
            #expect(alerts.alerts.first?.message == NewImageValidationError.invalidWidth.message)
            #expect(alerts.alerts.first?.informativeText == nil)
            #expect(presenter.okForms.first?.widthText == "65536")
            // The corrected second OK creates the document.
            #expect(harness.document.image.size == PixelSize(width: 64, height: 600))
            #expect(harness.canvasView.accessibilityValue() as? String == "64 × 600")
        }
    }

    @Test func fileActionsEnabledWithDocument() async throws {
        try await TestRunGate.withLock {
            defer { cleanup() }
            let fixtures = try FixtureFiles()
            defer { fixtures.removeAll() }
            let url = try fixtures.makePNG(named: "actions.png", width: 32, height: 24,
                                           rgba: (7, 8, 9, 255))
            let harness = try await DocumentHarness.open(url)
            // New…, Open…, Close, Save, and Save As… all have a validated target.
            #expect(harness.isEnabled(#selector(NSDocumentController.newDocument(_:))))
            #expect(harness.isEnabled(#selector(NSDocumentController.openDocument(_:))))
            #expect(harness.isEnabled(#selector(NSWindow.performClose(_:))))
            #expect(harness.isEnabled(NSSelectorFromString("saveDocument:")))
            #expect(harness.isEnabled(NSSelectorFromString("saveDocumentAs:")))
        }
    }
}
