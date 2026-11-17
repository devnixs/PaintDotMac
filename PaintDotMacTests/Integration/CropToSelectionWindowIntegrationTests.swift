import AppKit
import Testing

@testable import PaintDotMac

/// Image > Crop to Selection at window level (spec 0022 *Test plan*, headless):
/// documents through `DocumentHarness` (never shown), a fresh-suite `AppModel`, the
/// command through `harness.perform(cropToSelection:)` (the responder chain, as AppKit's
/// menu dispatch does), the marching-ants accessibility value, the History rows, the
/// status-bar strings, and pixels checked by saving and decoding. Each test ends with
/// `HeadlessAssertions.closeAllDocuments()` and `noVisibleWindows()`.
@MainActor
@Suite(.serialized)
struct CropToSelectionWindowIntegrationTests {
    private static let cropAction = NSSelectorFromString("cropToSelection:")

    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    private func finish(_ harness: DocumentHarness) {
        harness.close()
        harness.discardAppModelSuite()
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    /// 400×300 `(x % 256, y % 256, 128, 255)`; a fresh-suite `AppModel`.
    private func openFixture(_ fixtures: FixtureFiles) async throws -> DocumentHarness {
        let url = try fixtures.writePNG(named: "crop-fixture.png", width: 400, height: 300) { x, y in
            ColorRGBA8(red: UInt8(x % 256), green: UInt8(y % 256), blue: 128, alpha: 255)
        }
        let harness = try await DocumentHarness.open(url)
        harness.window.setContentSize(NSSize(width: 1000, height: 800))
        harness.document.undoBridge.undoManager.groupsByEvent = false
        harness.appModel.setActiveSession(harness.windowController.toolSession)
        pumpMainRunLoop()
        return harness
    }

    private func selectRect(_ harness: DocumentHarness, _ rect: PixelRect) {
        harness.windowController.setInitialSelection(rect)
        pumpMainRunLoop()
    }

    /// The selection drag (spec 0014's proven pattern: press, drags, a short pump, then
    /// release).
    private func selectDrag(_ harness: DocumentHarness, from start: CGPoint, to end: CGPoint) {
        harness.canvasPress(at: start)
        for step in 1...4 {
            let fraction = CGFloat(step) / 4
            harness.canvasDrag(to: CGPoint(x: start.x + (end.x - start.x) * fraction,
                                           y: start.y + (end.y - start.y) * fraction))
        }
        pumpMainRunLoop(for: 0.08)
        harness.canvasRelease(at: end)
    }

    /// The overlay's accessibility value ("hidden", "animated", or "static").
    private func antsMode(_ harness: DocumentHarness) -> String {
        guard let content = harness.window.contentView,
              let element = AX.withAccessibilityClient(
                  { AX.first(inRoot: content, identifier: "canvas.marchingAnts") })
        else { return "missing" }
        return AX.value(of: element) ?? "none"
    }

    /// Saves through the document (no sheet) and decodes the file's pixels.
    private func savedPixels(_ harness: DocumentHarness) async throws
        -> (Int, Int) -> ColorRGBA8
    {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests.crop.\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try await saveDocument(harness.document, to: url, ofType: "public.png",
                               for: .saveAsOperation)
        let data = try #require(try? Data(contentsOf: url))
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let image = try #require(source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        _ = try #require(context)
        context!.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return { x, y in
            let offset = (y * width + x) * 4
            return ColorRGBA8(red: bytes[offset], green: bytes[offset + 1],
                              blue: bytes[offset + 2], alpha: bytes[offset + 3])
        }
    }

    private func historyRows(_ harness: DocumentHarness) -> [HistoryRow] {
        harness.appModel.historyPanel.model.rows
    }

    @Test func menuEnablement() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }

            #expect(!harness.isEnabled(Self.cropAction), "no selection → disabled")
            selectRect(harness, PixelRect(x: 50, y: 40, width: 120, height: 80))
            #expect(harness.isEnabled(Self.cropAction), "a selection → enabled")

            // Mid-gesture (0022's "disabled mid-gesture" validation row): hold a
            // Rectangle Select drag open — the selection is still in the state, but the
            // item must validate disabled and the action must no-op until release.
            for _ in 0..<4 where harness.appModel.activeToolID != .rectangleSelect {
                #expect(harness.shortcut("s"))
            }
            #expect(harness.appModel.activeToolID == .rectangleSelect)
            harness.canvasPress(at: harness.viewPoint(forImagePoint: CGPoint(x: 200, y: 150)))
            harness.canvasDrag(to: harness.viewPoint(forImagePoint: CGPoint(x: 260, y: 200)))
            pumpMainRunLoop()
            #expect(harness.appModel.dispatcher.isGestureInProgress, "mid-gesture")
            #expect(!harness.isEnabled(Self.cropAction), "mid-gesture → disabled")
            harness.perform(Self.cropAction)
            pumpMainRunLoop()
            #expect(harness.statusBar.imageSizeText == "400 × 300",
                    "the command is ignored while the gesture is open")
            harness.canvasRelease(at: harness.viewPoint(forImagePoint: CGPoint(x: 260, y: 200)))
            pumpMainRunLoop()
            #expect(harness.isEnabled(Self.cropAction), "released → enabled again")
        }
    }

    @Test func cropRectangleSelection() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }
            selectRect(harness, PixelRect(x: 50, y: 40, width: 120, height: 80))
            let zoomBefore = harness.canvasView.transform.zoom

            // The action through the real responder chain (the ⇧⌘X key equivalent itself
            // is pinned by `MainMenuTests.imageMenuItems` + `noDuplicateShortcuts`).
            harness.perform(Self.cropAction)
            pumpMainRunLoop()

            #expect(harness.statusBar.imageSizeText == "120 × 80")
            #expect(harness.canvasView.transform.zoom == zoomBefore, "the zoom stays")
            #expect(harness.statusBar.zoom == zoomBefore)
            let rows = historyRows(harness)
            #expect(rows.map(\.name) == ["Open Image", "Crop to Selection"])
            #expect(rows[1].isCurrent)
            #expect(antsMode(harness) == "animated", "the selection survives, around the new canvas")

            let pixels = try await savedPixels(harness)
            #expect(pixels(0, 0) == ColorRGBA8(red: 50, green: 40, blue: 128, alpha: 255))
            #expect(pixels(119, 79) == ColorRGBA8(red: 169, green: 119, blue: 128, alpha: 255))
        }
    }

    @Test func cropEllipseSelection() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }

            // S cycles Rectangle → Lasso → Ellipse (0014/0015/0016 joined the group).
            #expect(harness.shortcut("s"))
            #expect(harness.shortcut("s"))
            #expect(harness.shortcut("s"))
            #expect(harness.appModel.activeToolID == .ellipseSelect)

            // Drag across the middle of the canvas (image-space (100, 75) → (300, 225)).
            selectDrag(harness,
                       from: harness.viewPoint(forImagePoint: CGPoint(x: 100, y: 75)),
                       to: harness.viewPoint(forImagePoint: CGPoint(x: 300, y: 225)))
            pumpMainRunLoop()
            let selectionText = harness.statusBar.selectionSizeText
            let parts = selectionText.split(separator: " × ")
            #expect(parts.count == 2, "selection size text '\(selectionText)'")
            let width = try #require(parts.first.flatMap { Int($0) })
            let height = try #require(parts.last.flatMap { Int($0) })
            #expect(width > 100 && width <= 201 && height > 100 && height <= 151,
                    "the dragged ellipse's bounding box, got \(selectionText)")

            harness.perform(Self.cropAction)
            pumpMainRunLoop()
            #expect(harness.statusBar.imageSizeText == selectionText)

            let pixels = try await savedPixels(harness)
            #expect(pixels(0, 0).alpha == 0, "top-left corner outside the ellipse")
            #expect(pixels(width - 1, 0).alpha == 0)
            #expect(pixels(0, height - 1).alpha == 0)
            #expect(pixels(width - 1, height - 1).alpha == 0)
            // The bbox center is canvas (200, 150): opaque, and the fixture's color there.
            #expect(pixels(width / 2, height / 2)
                == ColorRGBA8(red: 200, green: 150, blue: 128, alpha: 255),
                "the center stays opaque")
        }
    }

    @Test func cropUndoRedo() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }
            selectRect(harness, PixelRect(x: 50, y: 40, width: 120, height: 80))
            let undoManager = try #require(harness.window.undoManager)

            harness.perform(Self.cropAction)
            pumpMainRunLoop()
            #expect(harness.statusBar.imageSizeText == "120 × 80")

            undoManager.undo()
            pumpMainRunLoop()
            #expect(harness.statusBar.imageSizeText == "400 × 300")
            var rows = historyRows(harness)
            #expect(rows[1].isUndone, "the Crop row shows undone")
            #expect(antsMode(harness) == "animated", "the original selection is restored")

            undoManager.redo()
            pumpMainRunLoop()
            #expect(harness.statusBar.imageSizeText == "120 × 80")
            rows = historyRows(harness)
            #expect(!rows[1].isUndone)

            // Select All (it may or may not add a row — the cropped selection already
            // covers the canvas), then crop again: a no-op adds no step.
            let rowsBefore = historyRows(harness).count
            harness.perform(NSSelectorFromString("selectAll:"))
            pumpMainRunLoop()
            let rowsAfterSelectAll = historyRows(harness).count
            #expect(rowsAfterSelectAll == rowsBefore || rowsAfterSelectAll == rowsBefore + 1)
            harness.perform(Self.cropAction)
            pumpMainRunLoop()
            #expect(historyRows(harness).count == rowsAfterSelectAll,
                    "a full-canvas crop adds no step (H-6)")
            #expect(harness.statusBar.imageSizeText == "120 × 80")
        }
    }
}
