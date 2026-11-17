import AppKit
import Testing

@testable import PaintDotMac

/// Move Selection at window level (spec 0019 *Test plan*, headless): documents through
/// `DocumentHarness` (never shown), a fresh-suite `AppModel`, canvas input through
/// `harness.dragCanvas`, keys through `harness.shortcut`/`harness.keyDown`; pixels
/// checked by saving and decoding the file. The fixture is a 200 × 200 white PNG with
/// `setInitialSelection((50, 50, 100, 100))`. 0020 updates these three tests once Move
/// Selected Pixels joins the M group (M then selects it; use Shift+M here).
@MainActor
@Suite(.serialized)
struct MoveSelectionWindowIntegrationTests {
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

    private func openWhiteFixture(_ fixtures: FixtureFiles) async throws -> DocumentHarness {
        let url = try fixtures.writePNG(named: "move-fixture.png",
                                        width: 200, height: 200) { _, _ in .white }
        let harness = try await DocumentHarness.open(url)
        harness.window.setContentSize(NSSize(width: 1000, height: 800))
        harness.document.undoBridge.undoManager.groupsByEvent = false
        harness.appModel.setActiveSession(harness.windowController.toolSession)
        harness.windowController.setInitialSelection(
            PixelRect(x: 50, y: 50, width: 100, height: 100))
        pumpMainRunLoop()
        return harness
    }

    /// The marching-ants overlay's accessibility value ("hidden", "animated", "static").
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
            .appendingPathComponent("PaintDotMacTests.move.\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try await saveDocument(harness.document, to: url, ofType: "public.png",
                               for: .saveAsOperation)
        let data = try #require(try? Data(contentsOf: url))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return { x, y in
            let offset = (y * width + x) * 4
            return ColorRGBA8(red: bytes[offset], green: bytes[offset + 1],
                              blue: bytes[offset + 2], alpha: bytes[offset + 3])
        }
    }

    // MARK: - Tests

    @Test func mKeySelectsMoveSelection() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }

            #expect(harness.shortcut("m"))
            #expect(harness.appModel.activeToolID == .moveSelection)

            #expect(harness.shortcut("b"))
            #expect(harness.appModel.activeToolID == .paintbrush)
            // 0020 changes this to plain "m" once Move Selected Pixels leads the group.
            #expect(harness.shortcut("m", modifiers: [.shift]))
            #expect(harness.appModel.activeToolID == .moveSelection)
        }
    }

    @Test func dragMovesSelectionAndUndoes() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            let bridge = harness.document.undoBridge
            let manager = try #require(harness.window.undoManager)
            #expect(harness.shortcut("m"))

            harness.dragCanvas(
                from: harness.viewPoint(forImagePoint: CGPoint(x: 100, y: 100)),
                to: harness.viewPoint(forImagePoint: CGPoint(x: 120, y: 120)))
            pumpMainRunLoop()

            #expect(bridge.history.steps.map(\.name)
                        == ["Open Image", "Move Selection"])
            #expect(manager.undoMenuItemTitle == "Undo Move Selection")
            #expect(harness.statusBar.selectionSizeText == "100 × 100")
            #expect(antsMode(harness) == "animated", "the ants follow to the new place")
            #expect(bridge.state.selection?.bounds
                        == PixelRect(x: 70, y: 70, width: 100, height: 100))

            manager.undo()
            pumpMainRunLoop()
            #expect(!bridge.history.canUndo, "the row is undone (back to the base step)")
            #expect(bridge.history.canRedo)
            #expect(bridge.state.selection?.bounds
                        == PixelRect(x: 50, y: 50, width: 100, height: 100))

            // The untouched image still saves all white — the tool never touched pixels.
            let pixels = try await savedPixels(harness)
            let white = ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255)
            #expect(pixels(100, 100) == white)
            #expect(pixels(10, 10) == white)
            #expect(pixels(190, 190) == white)
        }
    }

    @Test func arrowKeysNudgeAndPaintingFollows() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            let bridge = harness.document.undoBridge
            #expect(harness.shortcut("m"))

            // ⌘→ to the canvas (first responder): the keyDown carries the right-arrow
            // virtual key code 124.
            harness.keyDown("\u{F703}", keyCode: 124, modifiers: .command)
            harness.keyUp("\u{F703}", keyCode: 124, modifiers: .command)
            pumpMainRunLoop()
            #expect(bridge.history.steps.map(\.name)
                        == ["Open Image", "Move Selection"])
            #expect(harness.statusBar.selectionSizeText == "100 × 100")
            #expect(bridge.state.selection?.bounds
                        == PixelRect(x: 60, y: 50, width: 100, height: 100))

            // Painting follows the moved selection (as in 0013's clipped test).
            #expect(harness.shortcut("b"))
            pumpMainRunLoop()
            harness.appModel.toolOptions.setValue(
                20.0, for: BrushOptions.keys(for: .paintbrush).width)
            harness.dragCanvas(
                from: harness.viewPoint(forImagePoint: CGPoint(x: -30, y: 100)),
                to: harness.viewPoint(forImagePoint: CGPoint(x: 230, y: 100)),
                steps: 10)
            pumpMainRunLoop()
            let pixels = try await savedPixels(harness)
            let black = ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255)
            let white = ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255)
            #expect(pixels(155, 100) == black, "inside the moved selection")
            #expect(pixels(55, 100) == white, "the vacated edge stays white")
        }
    }
}
