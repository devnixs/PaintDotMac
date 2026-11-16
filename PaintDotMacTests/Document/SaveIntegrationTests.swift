import AppKit
import Foundation
import Testing
@testable import PaintDotMac

/// Headless save integration tests (spec 0005): ⌘S in place on PNG, Save As to PNG on JPEG,
/// the edited state that drives `NSDocument`'s close/quit prompts, and the M0 exit criterion
/// (open a PNG, view it, re-save it, identical pixels). Save panels are created for
/// configuration checks but never run; saving uses the programmatic path (no sheet).
@MainActor
@Suite(.serialized)
struct SaveIntegrationTests {
    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    /// The M0 exit fixture: 300×200 with semi-transparent and alpha-0 pixels at 300 DPI.
    private static func mixedPixel(_ x: Int, _ y: Int) -> ColorRGBA8 {
        let alpha: UInt8 = (x * y) % 11 == 0 ? 0 : UInt8((x &+ y) % 256)
        return ColorRGBA8(red: UInt8(x % 256), green: UInt8((y &* 3) % 256),
                          blue: UInt8((x &* y) % 256), alpha: alpha)
    }

    /// 0008 (APP-9, D-30) supersedes 0005's interim rule 3: a new image is clean; Save As
    /// writes the white PNG and the document stays clean. The close/quit prompts after a
    /// real edit are tested in 0009 with the Paintbrush.
    @Test func saveAsNewImageWritesWhitePNG() async throws {
        try await TestRunGate.withLock {
            defer { cleanup() }
            let presenter = ScriptedNewImagePresenter(steps: [.ok])
            let harness = try #require(
                DocumentHarness.newImage(presenter: presenter, pasteboard: makePrivatePasteboard())
            )
            // The edited state follows history: untouched → clean (no close prompt).
            #expect(harness.document.isDocumentEdited == false)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("PaintDotMacTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("new.png")
            defer {
                try? FileManager.default.removeItem(
                    at: url.deletingLastPathComponent())
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await saveDocument(harness.document, to: url, ofType: "public.png",
                                   for: .saveAsOperation)
            #expect(harness.document.isDocumentEdited == false)

            let saved = try FixtureFiles.decodePNG(at: url)
            #expect(saved.width == 800)
            #expect(saved.height == 600)
            func pixel(_ x: Int, _ y: Int) -> [UInt8] {
                let offset = (y * saved.width + x) * 4
                return Array(saved.pixels[offset..<offset + 4])
            }
            for point in [(0, 0), (799, 0), (0, 599), (799, 599), (400, 300), (255, 255), (256, 256)] {
                #expect(pixel(point.0, point.1) == [255, 255, 255, 255], "pixel \(point)")
            }
            #expect(abs(saved.dpi - 96) <= 0.05)
            #expect(saved.profileName?.contains("sRGB") == true,
                    "profile is \(saved.profileName ?? "none")")
        }
    }

    /// Documents opened from disk are always clean (0008: the edited state follows history,
    /// and opening marks the base step saved).
    @Test func openedPNGIsNotEdited() async throws {
        try await TestRunGate.withLock {
            defer { cleanup() }
            let fixtures = try FixtureFiles()
            defer { fixtures.removeAll() }
            let url = try fixtures.makePNG(named: "clean.png", width: 16, height: 12,
                                           rgba: (30, 40, 50, 255))
            let harness = try await DocumentHarness.open(url)
            #expect(harness.document.isDocumentEdited == false)
        }
    }

    /// M0 exit criterion: open a fixture PNG, view it, and re-save it with identical decoded
    /// pixels, DPI, and sRGB profile — through the path `saveDocument(_:)` takes for a PNG
    /// (`.writeInPlace`, no panel).
    @Test func reSaveOpenedPNG() async throws {
        try await TestRunGate.withLock {
            defer { cleanup() }
            let fixtures = try FixtureFiles()
            defer { fixtures.removeAll() }
            let url = try fixtures.writePNG(named: "photo.png", width: 300, height: 200,
                                            pixel: Self.mixedPixel,
                                            properties: [kCGImagePropertyDPIWidth: 300,
                                                         kCGImagePropertyDPIHeight: 300])
            // Record the decoded pixels independently of the document.
            let recorded = try ImageDecoder.decode(Data(contentsOf: url))
            let recordedPixels = recorded.surface.readPixels(in: recorded.surface.bounds)
            let modifiedBefore = try #require(
                url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

            let harness = try await DocumentHarness.open(url)
            let fileType = try #require(harness.document.fileType)
            #expect(FileFormat.saveAction(for: FileFormat(typeIdentifier: fileType))
                    == .writeInPlace(.png))

            try await Task.sleep(for: .milliseconds(50))
            try await saveDocument(harness.document, to: url, ofType: fileType,
                                   for: .saveOperation)

            let modifiedAfter = try #require(
                url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            #expect(modifiedAfter > modifiedBefore, "the file was not rewritten")

            let saved = try FixtureFiles.decodePNG(at: url)
            #expect(saved.pixels == recordedPixels, "re-saving changed the pixels")
            #expect(abs(saved.dpi - 300) <= 0.05)
            #expect(saved.profileName?.contains("sRGB") == true,
                    "profile is \(saved.profileName ?? "none")")
            #expect(harness.document.isDocumentEdited == false)
        }
    }

    /// ⌘S on a JPEG prepares a Save As panel that offers only PNG, named "<base>.png", in
    /// the JPEG's folder. The panel is created, never run.
    @Test func jpegSavePreparesPNGPanel() async throws {
        try await TestRunGate.withLock {
            defer { cleanup() }
            let fixtures = try FixtureFiles()
            defer { fixtures.removeAll() }
            let url = try fixtures.writeJPEG(named: "photo.jpg", width: 40, height: 30,
                                             pixel: { x, y in
                                                 ColorRGBA8(red: UInt8(x % 256), green: UInt8(y % 256), blue: 128)
                                             })
            let harness = try await DocumentHarness.open(url)
            #expect(FileFormat.saveAction(for: .jpeg) == .saveAs(offering: [.png], suggested: .png))

            let panel = NSSavePanel()
            #expect(harness.document.prepareSavePanel(panel))
            #expect(panel.nameFieldStringValue == "photo.png")
            #expect(panel.allowedContentTypes == [.png])
            #expect(panel.directoryURL?.standardizedFileURL
                    == fixtures.directory.standardizedFileURL)
            #expect(harness.document.fileURL == url, "configuring the panel must not touch the document")
        }
    }

    /// The JPEG → Save As → PNG → in-place story: the JPEG on disk is never touched, and
    /// after the save the document is the PNG.
    @Test func jpegSaveAsPNGThenSavesInPlace() async throws {
        try await TestRunGate.withLock {
            defer { cleanup() }
            let fixtures = try FixtureFiles()
            defer { fixtures.removeAll() }
            let jpegURL = try fixtures.writeJPEG(named: "photo.jpg", width: 40, height: 30,
                                                 pixel: { x, y in
                                                     ColorRGBA8(red: UInt8(x % 256), green: UInt8(y % 256), blue: 64)
                                                 })
            let jpegBytesBefore = try Data(contentsOf: jpegURL)
            let harness = try await DocumentHarness.open(jpegURL)

            let pngURL = fixtures.directory.appendingPathComponent("photo.png")
            try await saveDocument(harness.document, to: pngURL, ofType: "public.png",
                                   for: .saveAsOperation)

            let saved = try FixtureFiles.decodePNG(at: pngURL)
            let decodedJPEG = try ImageDecoder.decode(jpegBytesBefore)
            #expect(saved.width == decodedJPEG.surface.size.width)
            #expect(saved.height == decodedJPEG.surface.size.height)
            #expect(try Data(contentsOf: jpegURL) == jpegBytesBefore,
                    "the JPEG on disk changed")
            #expect(harness.document.fileURL == pngURL)
            #expect(harness.document.fileType == "public.png")
            #expect(harness.document.displayName.hasPrefix("photo"))

            // The document is now a PNG: ⌘S writes in place and rewrites photo.png.
            #expect(FileFormat.saveAction(for: FileFormat(typeIdentifier: harness.document.fileType ?? ""))
                    == .writeInPlace(.png))
            let pngModifiedBefore = try #require(
                pngURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            try await Task.sleep(for: .milliseconds(50))
            try await saveDocument(harness.document, to: pngURL, ofType: "public.png",
                                   for: .saveOperation)
            let pngModifiedAfter = try #require(
                pngURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            #expect(pngModifiedAfter > pngModifiedBefore, "the PNG was not rewritten in place")
            #expect(try Data(contentsOf: jpegURL) == jpegBytesBefore)
        }
    }

    /// `DocumentWindowController.synchronizeWindowTitleWithDocumentName()` is `nonisolated`
    /// because AppKit's file-coordinator save finisher can call it on a background queue
    /// (`ProgrammaticSave.swift` documents the windowless-host case). The off-main call must
    /// not trap and must land the document's current file name on the window via the main
    /// thread — this is the regression test for the MainActor-entry-check fix.
    @Test func windowTitleSynchronizesFromBackgroundQueue() async throws {
        try await TestRunGate.withLock {
            defer { cleanup() }
            let fixtures = try FixtureFiles()
            defer { fixtures.removeAll() }
            let url = try fixtures.makePNG(named: "titled.png", width: 16, height: 12,
                                           rgba: (1, 2, 3, 255))
            let harness = try await DocumentHarness.open(url)
            let renamed = fixtures.directory.appendingPathComponent("renamed.png")
            harness.document.fileURL = renamed
            nonisolated(unsafe) let windowController = harness.windowController
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    windowController.synchronizeWindowTitleWithDocumentName()
                    continuation.resume()
                }
            }
            // The re-hop runs on the main queue; suspending this test lets it drain.
            try await Task.sleep(for: .milliseconds(100))
            #expect(harness.window.representedURL == renamed,
                    "an off-main title sync must re-hop to the main thread and update the window")
        }
    }
}
