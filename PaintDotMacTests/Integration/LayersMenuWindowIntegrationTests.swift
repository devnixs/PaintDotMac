import AppKit
import Foundation
import Testing

@testable import PaintDotMac

/// The Layers menu and Image > Flatten at window level (spec 0024 *Test plan*, headless):
/// documents through `DocumentHarness` (never shown), menu items checked with
/// `isEnabled`/`perform` on the actions of the Layers and Image menus, history read from
/// the History panel model, pixels checked by saving and decoding the file.
@MainActor
@Suite(.serialized)
struct LayersMenuWindowIntegrationTests {
    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    private func finish(_ harness: DocumentHarness) {
        harness.close()
        harness.discardAppModelSuite()
        cleanup()
    }

    /// The fixture: a 200 × 150 opaque white PNG, zoom pinned to 1 px/point.
    private func openFixture(_ fixtures: FixtureFiles) async throws -> DocumentHarness {
        let url = try fixtures.writePNG(named: "layers-fixture.png",
                                        width: 200, height: 150) { _, _ in .white }
        let harness = try await DocumentHarness.open(url)
        harness.window.setContentSize(NSSize(width: 800, height: 600))
        // Pin the zoom to the backing scale so canvas↔view is exactly 1 px per point
        // (the fit-zoom race on never-shown windows, 0022 CAN-6).
        let backing = harness.canvasView.transform.backingScale
        harness.canvasView.navigation?.setZoom(
            backing,
            anchoredAtView: CGPoint(x: harness.canvasView.bounds.midX,
                                    y: harness.canvasView.bounds.midY))
        harness.document.undoBridge.undoManager.groupsByEvent = false
        harness.appModel.setActiveSession(harness.windowController.toolSession)
        pumpMainRunLoop()
        return harness
    }

    private func rowNames(_ harness: DocumentHarness) -> [String] {
        harness.appModel.historyPanel.model.rows.map(\.name)
    }

    private func view(_ harness: DocumentHarness, _ x: Double, _ y: Double) -> CGPoint {
        harness.viewPoint(forImagePoint: CGPoint(x: x, y: y))
    }

    private func savedPixels(_ harness: DocumentHarness) async throws
        -> (Int, Int) -> ColorRGBA8
    {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests.layers.\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try await saveDocument(harness.document, to: url, ofType: "public.png",
                               for: .saveAsOperation)
        let data = try #require(try? Data(contentsOf: url))
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let image = try #require(source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &bytes, width: width, height: height,
                                             bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return { x, y in
            let offset = (y * width + x) * 4
            return ColorRGBA8(red: bytes[offset + 2], green: bytes[offset + 1],
                              blue: bytes[offset], alpha: bytes[offset + 3])
        }
    }

    // MARK: - Menu state

    @Test func singleLayerMenuState() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }
            // One layer: Add and Duplicate work; everything stack-relative is off.
            #expect(harness.isEnabled(NSSelectorFromString("addNewLayer:")))
            #expect(harness.isEnabled(NSSelectorFromString("duplicateLayer:")))
            #expect(!harness.isEnabled(NSSelectorFromString("deleteLayer:")))
            #expect(!harness.isEnabled(NSSelectorFromString("mergeLayerDown:")))
            #expect(!harness.isEnabled(NSSelectorFromString("goToLayerAbove:")))
            #expect(!harness.isEnabled(NSSelectorFromString("goToLayerBelow:")))
            #expect(!harness.isEnabled(NSSelectorFromString("moveLayerUp:")))
            #expect(!harness.isEnabled(NSSelectorFromString("moveLayerDown:")))
            #expect(!harness.isEnabled(NSSelectorFromString("flattenImage:")))
        }
    }

    @Test func addDuplicateMergeFlattenWithUndo() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }
            harness.perform(NSSelectorFromString("addNewLayer:"))
            #expect(rowNames(harness) == ["Open Image", "Add New Layer"])
            // The new layer is on top with a layer below it.
            #expect(harness.isEnabled(NSSelectorFromString("deleteLayer:")))
            #expect(harness.isEnabled(NSSelectorFromString("mergeLayerDown:")))
            #expect(harness.isEnabled(NSSelectorFromString("moveLayerDown:")))
            #expect(harness.isEnabled(NSSelectorFromString("goToLayerBelow:")))
            #expect(!harness.isEnabled(NSSelectorFromString("goToLayerAbove:")))
            #expect(!harness.isEnabled(NSSelectorFromString("moveLayerUp:")))

            harness.perform(NSSelectorFromString("duplicateLayer:"))
            harness.perform(NSSelectorFromString("mergeLayerDown:"))
            harness.perform(NSSelectorFromString("flattenImage:"))
            #expect(rowNames(harness) == ["Open Image", "Add New Layer", "Duplicate Layer",
                                          "Merge Layer Down", "Flatten"])
            #expect(!harness.isEnabled(NSSelectorFromString("flattenImage:")),
                    "one layer after Flatten")

            harness.window.undoManager?.undo()
            #expect(harness.window.undoManager?.redoMenuItemTitle == "Redo Flatten")
            #expect(harness.isEnabled(NSSelectorFromString("flattenImage:")),
                    "two layers again → Flatten enabled")
            harness.window.undoManager?.redo()
            #expect(harness.window.undoManager?.undoMenuItemTitle == "Undo Flatten")
        }
    }

    @Test func deleteLayerFromMenu() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }
            harness.perform(NSSelectorFromString("addNewLayer:"))
            harness.perform(NSSelectorFromString("deleteLayer:"))
            #expect(rowNames(harness) == ["Open Image", "Add New Layer", "Delete Layer"])
            #expect(!harness.isEnabled(NSSelectorFromString("deleteLayer:")),
                    "Delete Layer disabled back at one layer")
        }
    }

    // MARK: - Paint, flatten, save

    @Test func paintOnNewLayerFlattenAndSave() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }
            harness.perform(NSSelectorFromString("addNewLayer:"))
            #expect(harness.shortcut("b"), "switch to the Paintbrush")
            harness.dragCanvas(from: view(harness, 60, 75), to: view(harness, 140, 75))
            pumpMainRunLoop()
            // Go to Layer Below, then Add New Layer lands between the two.
            harness.perform(NSSelectorFromString("goToLayerBelow:"))
            harness.perform(NSSelectorFromString("addNewLayer:"))
            #expect(harness.isEnabled(NSSelectorFromString("goToLayerAbove:")),
                    "the middle layer can go up again")
            harness.perform(NSSelectorFromString("flattenImage:"))
            let pixel = try await savedPixels(harness)
            #expect(pixel(100, 75) == .black, "the stroke is in the flattened file")
            #expect(pixel(2, 2) == .white, "a corner is still white")
        }
    }

    @Test func multiLayerSaveShowsFlattenHint() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }
            harness.perform(NSSelectorFromString("addNewLayer:"))
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("PaintDotMacTests.layers.\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: url) }
            await #expect(throws: (any Error).self) {
                try await saveDocument(harness.document, to: url, ofType: "public.png",
                                       for: .saveAsOperation)
            }
            do {
                try await saveDocument(harness.document, to: url, ofType: "public.png",
                                       for: .saveAsOperation)
                Issue.record("multi-layer PNG save must throw")
            } catch {
                // NSDocument wraps the typed error; the alert text is the underlying's
                // (same unwrap as the open-error tests, 0005).
                let inner = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
                let surfaced = inner ?? (error as NSError)
                #expect(surfaced.localizedDescription
                            == "This image has more than one layer.",
                        "error: \(error.localizedDescription) inner: \(inner?.localizedDescription ?? "nil")")
            }
            // Still open, nothing crashed; Flatten makes the save work.
            harness.perform(NSSelectorFromString("flattenImage:"))
            try await saveDocument(harness.document, to: url, ofType: "public.png",
                                   for: .saveAsOperation)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
