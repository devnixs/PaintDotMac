import AppKit
import Foundation
import Testing

@testable import PaintDotMac

/// Headless user stories (spec 0002): open fixture files through `NSDocumentController`,
/// build windows offscreen, and read the decoded state through the canvas accessibility
/// value and document model. Nothing is ever put on screen.
@MainActor
@Suite(.serialized)
struct ImageDecodingIntegrationTests {
    @Test func opensTransparentPNGAtItsSize() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }

            let url = try fixtures.writePNG(
                named: "transparent-300x200.png", width: 300, height: 200,
                pixel: { x, _ in x < 150 ? .clear : ColorRGBA8(red: 255, green: 0, blue: 0) }
            )
            let harness = try await DocumentHarness.open(url)
            #expect(NSDocumentController.shared.documents.count == 1)
            #expect(harness.document.image.size == PixelSize(width: 300, height: 200))
            #expect(harness.document.image.layers.count == 1)
            #expect(harness.window.title.hasPrefix("transparent-300x200"))
            let canvas = try #require(harness.window.contentView)
            #expect(canvas.accessibilityValue() as? String == "300 × 200")
        }
    }

    @Test func rotatedJPEGOpensUpright() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }

            let url = try fixtures.writeJPEG(
                named: "rotated.jpg", width: 300, height: 200,
                pixel: { _, _ in ColorRGBA8(red: 10, green: 20, blue: 30) },
                properties: [kCGImagePropertyOrientation: 6]
            )
            let harness = try await DocumentHarness.open(url)
            let canvas = try #require(harness.window.contentView)
            #expect(canvas.accessibilityValue() as? String == "200 × 300")
        }
    }

    @Test func corruptFileFailsWithCodecError() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }

            let url = try fixtures.writeTruncatedPNG()
            let result = await Self.openResult(url)
            #expect(result.document == nil)
            let error = try #require(result.error, "opening a truncated PNG must fail")
            #expect(DocumentOpenIntegrationTests.codecError(in: error) == .corrupt,
                    "expected ImageCodecError.corrupt, got \(error)")
            let inner = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
            #expect((inner?.localizedDescription ?? error.localizedDescription)
                .contains("damaged or incomplete"), "alert text: \(error.localizedDescription)")
            #expect(NSDocumentController.shared.documents.isEmpty)
        }
    }

    @Test func imageAboveMemoryCapFails() async throws {
        try await TestRunGate.withLock {
            PaintDocument.imageLimitsOverride = ImageLimits(memoryCapBytes: 1_000)
            defer { PaintDocument.imageLimitsOverride = nil }
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }

            let url = try fixtures.writePNG(
                named: "over-cap.png", width: 100, height: 100,
                pixel: { _, _ in ColorRGBA8(red: 3, green: 4, blue: 5) }
            )
            let result = await Self.openResult(url)
            #expect(result.document == nil)
            let error = try #require(result.error, "a file over the memory cap must fail to open")
            let codecError = DocumentOpenIntegrationTests.codecError(in: error)
            if case .limitExceeded(.exceedsMemoryCap)? = codecError {} else {
                Issue.record("expected .exceedsMemoryCap, got \(String(describing: codecError))")
            }
            let innerError = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
            #expect(error.localizedDescription.contains("too large")
                || innerError?.localizedDescription.contains("too large") == true)
            #expect(NSDocumentController.shared.documents.isEmpty)
        }
    }

    // MARK: - Helpers

    /// Every test ends by closing documents and checking that nothing became visible.
    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    private static func openResult(_ url: URL) async -> (document: NSDocument?, error: Error?) {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<(NSDocument?, Error?), Never>) in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { document, _, error in
                continuation.resume(returning: (document, error))
            }
        }
    }
}
