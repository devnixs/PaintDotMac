import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// Cut / Copy / Paste / Paste into New Image at window level (spec 0021 *Test plan*,
/// headless): documents through `DocumentHarness` (never shown), a fresh-suite
/// `AppModel`, canvas input through `harness.dragCanvas`, keys through
/// `harness.keyDown`; menu validation through `harness.isEnabled` / `harness.perform`
/// on the real responder chain; pixels checked by saving and decoding the file. Every
/// test uses `DocumentHarness.useClipboard` (or the `pasteIntoNewImage` factory) with a
/// fresh private pasteboard — the user's clipboard is never touched (AGENTS.md *Headless
/// testing*).
@MainActor
@Suite(.serialized)
struct ClipboardWindowIntegrationTests {
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

    /// The fixture: a `width` × `height` PNG, white with a red square (0, 0, 40, 30)
    /// and a few alpha-128 pixels.
    nonisolated static func fixturePixel(_ x: Int, _ y: Int) -> ColorRGBA8 {
        if x < 40 && y < 30 { return ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255) }
        if (x &+ y) % 13 == 0 { return ColorRGBA8(red: 11, green: 22, blue: 33, alpha: 128) }
        return .white
    }

    private func openFixture(_ fixtures: FixtureFiles, width: Int = 200, height: Int = 150,
                             named: String = "clipboard-fixture.png",
                             pixel: @escaping (Int, Int) -> ColorRGBA8 = Self.fixturePixel)
        async throws -> DocumentHarness
    {
        let url = try fixtures.writePNG(named: named, width: width, height: height,
                                        pixel: pixel)
        let harness = try await DocumentHarness.open(url)
        harness.window.setContentSize(NSSize(width: 1000, height: 800))
        harness.document.undoBridge.undoManager.groupsByEvent = false
        harness.appModel.setActiveSession(harness.windowController.toolSession)
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

    private func names(_ harness: DocumentHarness) -> [String] {
        harness.document.undoBridge.history.steps.map(\.name)
    }

    private func currentName(_ harness: DocumentHarness) -> String {
        let history = harness.document.undoBridge.history
        return history.steps[history.currentIndex].name
    }

    /// Saves through the document (no sheet) and decodes the file's pixels with 0002's
    /// decoder (straight alpha, so alpha-128 pixels are checked exactly).
    private func savedPixels(_ harness: DocumentHarness) async throws
        -> (Int, Int) -> ColorRGBA8
    {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests.clipboard.\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try await saveDocument(harness.document, to: url, ofType: "public.png",
                               for: .saveAsOperation)
        let data = try #require(try? Data(contentsOf: url))
        let decoded = try ImageDecoder.decode(data, limits: .standard)
        let surface = decoded.surface
        return { x, y in surface.pixel(at: PixelPoint(x: x, y: y)) }
    }

    private func view(_ harness: DocumentHarness, _ x: Double, _ y: Double) -> CGPoint {
        harness.viewPoint(forImagePoint: CGPoint(x: x, y: y))
    }

    private let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)

    // MARK: - Menu validation

    @Test func menuEnablement() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, width: 64, height: 48,
                                                named: "menu.png")
            let clipboard = harness.useClipboard(makePrivatePasteboard())
            defer { clipboard.restore() }
            defer { finish(harness) }

            let copy = harness.isEnabled(Selector("copy:"))
            let cut = harness.isEnabled(Selector("cut:"))
            let paste = harness.isEnabled(Selector("paste:"))
            let pasteNew = harness.isEnabled(Selector("pasteIntoNewImage:"))
            #expect(copy, "Copy: a document is open")
            #expect(!cut, "Cut: no selection")
            #expect(!paste, "Paste: empty pasteboard")
            #expect(!pasteNew, "Paste into New Image: empty pasteboard")

            writeText("hi", to: clipboard.pasteboard)
            #expect(!harness.isEnabled(Selector("paste:")), "text is not an image")
            #expect(!harness.isEnabled(Selector("pasteIntoNewImage:")))

            writeImage(width: 10, height: 10, to: clipboard.pasteboard)
            #expect(harness.isEnabled(Selector("paste:")))
            #expect(harness.isEnabled(Selector("pasteIntoNewImage:")))

            harness.windowController.setInitialSelection(PixelRect(x: 0, y: 0,
                                                                   width: 10, height: 10))
            pumpMainRunLoop()
            #expect(harness.isEnabled(Selector("cut:")), "Cut with a selection")
        }
    }

    // MARK: - Copy / Cut

    @Test func copyWholeImage() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, width: 64, height: 48,
                                                named: "copy-whole.png")
            let clipboard = harness.useClipboard(makePrivatePasteboard())
            defer { clipboard.restore() }
            defer { finish(harness) }

            harness.perform(Selector("copy:"))
            pumpMainRunLoop()
            let pasteboardTypes = types(of: clipboard.pasteboard)
            #expect(pasteboardTypes.contains("public.png"))
            #expect(pasteboardTypes.contains("public.tiff"))
            let png = try #require(readPNG(from: clipboard.pasteboard), "PNG on the pasteboard")
            #expect(png.width == 64 && png.height == 48)
            let expected = TestImages.rgbaBytes(width: 64, height: 48, Self.fixturePixel)
            #expect(png.rgba == expected, "the copied PNG holds the layer exactly")
            #expect(names(harness) == ["Open Image"], "Copy adds no history step")
        }
    }

    @Test func copySelection() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, width: 64, height: 48,
                                                named: "copy-selection.png")
            let clipboard = harness.useClipboard(makePrivatePasteboard())
            defer { clipboard.restore() }
            defer { finish(harness) }
            harness.windowController.setInitialSelection(PixelRect(x: 10, y: 5,
                                                                   width: 20, height: 15))
            pumpMainRunLoop()

            harness.perform(Selector("copy:"))
            pumpMainRunLoop()
            let png = try #require(readPNG(from: clipboard.pasteboard))
            #expect(png.width == 20 && png.height == 15)
            func fixture(_ x: Int, _ y: Int) -> ColorRGBA8 { Self.fixturePixel(x, y) }
            func copied(_ x: Int, _ y: Int) -> ColorRGBA8 {
                let offset = (y * png.width + x) * 4
                return ColorRGBA8(red: png.rgba[offset], green: png.rgba[offset + 1],
                                  blue: png.rgba[offset + 2], alpha: png.rgba[offset + 3])
            }
            #expect(copied(0, 0) == fixture(10, 5))
            #expect(copied(19, 14) == fixture(29, 19))
            #expect(names(harness) == ["Open Image"],
                    "the History model still has only \u{201C}Open Image\u{201D}")
        }
    }

    @Test func cutSelection() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, width: 64, height: 48,
                                                named: "cut.png")
            let clipboard = harness.useClipboard(makePrivatePasteboard())
            defer { clipboard.restore() }
            defer { finish(harness) }
            harness.windowController.setInitialSelection(PixelRect(x: 10, y: 5,
                                                                   width: 20, height: 15))
            pumpMainRunLoop()
            #expect(antsMode(harness) == "animated")

            harness.perform(Selector("cut:"))
            pumpMainRunLoop()
            #expect(names(harness) == ["Open Image", "Cut"])
            #expect(antsMode(harness) == "hidden", "Cut deselects")
            let png = try #require(readPNG(from: clipboard.pasteboard))
            #expect(png.width == 20 && png.height == 15, "Cut copies like Copy")

            let at = try await savedPixels(harness)
            #expect(at(15, 10) == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0),
                    "inside the cut: transparent")
            #expect(at(0, 0) == Self.fixturePixel(0, 0), "outside the cut: unchanged")

            try #require(harness.window.undoManager).undo()
            pumpMainRunLoop()
            #expect(currentName(harness) == "Open Image", "the Cut step is undone")
            #expect(antsMode(harness) == "animated", "the selection is back")
            let back = try await savedPixels(harness)
            #expect(back(15, 10) == Self.fixturePixel(15, 10))
        }
    }

    // MARK: - Paste

    @Test func pasteActivatesMoveSelectedPixels() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            let clipboard = harness.useClipboard(makePrivatePasteboard())
            defer { clipboard.restore() }
            defer { finish(harness) }
            writeImage(width: 30, height: 20, pixel: { _, _ in self.red },
                       to: clipboard.pasteboard)

            harness.perform(Selector("paste:"))
            pumpMainRunLoop()
            #expect(names(harness) == ["Open Image", "Paste"])
            #expect(harness.appModel.activeToolID == .moveSelectedPixels,
                    "0020's policy activates Move Selected Pixels")
            #expect(harness.statusBar.selectionSizeText == "30 \u{00D7} 20")
            #expect(antsMode(harness) == "animated", "the pasted pixels are selected")
        }
    }

    @Test func pasteMoveAndUndo() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }

            // Pass 1: Paste, drag from the pasted area's center, Return, save.
            // A white 200 \u{00D7} 150 fixture: the spec's "white at (0, 0)" and
            // "saved pixels all white" check the paste against nothing else.
            let harness = try await openFixture(fixtures, named: "plain-white.png",
                                                pixel: { _, _ in .white })
            let clipboard = harness.useClipboard(makePrivatePasteboard())
            defer { clipboard.restore() }
            writeImage(width: 40, height: 30, pixel: { _, _ in self.red },
                       to: clipboard.pasteboard)
            harness.perform(Selector("paste:"))
            pumpMainRunLoop()
            harness.dragCanvas(from: view(harness, 20, 15), to: view(harness, 80, 60))
            pumpMainRunLoop()
            harness.keyDown("\r", keyCode: 36)
            pumpMainRunLoop()
            clipboard.restore()
            #expect(names(harness).suffix(2).map(\.self) == ["Paste", "Finish Pixels"]
                    || names(harness).last == "Finish Pixels")
            let at = try await savedPixels(harness)
            #expect(at(60, 45) == self.red, "the pasted block moved to (60, 45)")
            #expect(at(0, 0) == .white, "the original paste spot shows the white layer")
            finish(harness)

            // Pass 2: a fresh document — Paste then undo leaves only "Open Image".
            let second = try await openFixture(fixtures, named: "plain-white-2.png",
                                               pixel: { _, _ in .white })
            let secondClipboard = second.useClipboard(makePrivatePasteboard())
            defer { secondClipboard.restore() }
            writeImage(width: 40, height: 30, pixel: { _, _ in self.red },
                       to: secondClipboard.pasteboard)
            second.perform(Selector("paste:"))
            pumpMainRunLoop()
            secondClipboard.restore()
            try #require(second.window.undoManager).undo()
            pumpMainRunLoop()
            #expect(currentName(second) == "Open Image")
            let back = try await savedPixels(second)
            for y in stride(from: 0, to: 150, by: 7) {
                for x in stride(from: 0, to: 200, by: 7) {
                    #expect(back(x, y) == .white, "saved pixels all white at (\(x), \(y))")
                }
            }
            finish(second)
        }
    }

    @Test func pasteFromTIFFOnly() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            let clipboard = harness.useClipboard(makePrivatePasteboard())
            defer { clipboard.restore() }
            defer { finish(harness) }
            writeImage(width: 30, height: 20, pixel: { _, _ in self.red },
                       asTIFFOnly: true, to: clipboard.pasteboard)
            #expect(harness.isEnabled(Selector("paste:")), "TIFF alone is pasteable")

            harness.perform(Selector("paste:"))
            pumpMainRunLoop()
            #expect(names(harness) == ["Open Image", "Paste"])
            #expect(harness.statusBar.selectionSizeText == "30 \u{00D7} 20")
        }
    }

    @Test func pasteFromFileURL() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            let clipboard = harness.useClipboard(makePrivatePasteboard())
            defer { clipboard.restore() }
            defer { finish(harness) }
            let url = try fixtures.writePNG(named: "clip-25.png", width: 25, height: 25,
                                            pixel: { _, _ in self.red })
            writeFileURL(url, to: clipboard.pasteboard)
            #expect(harness.isEnabled(Selector("paste:")), "an image file URL is pasteable")

            harness.perform(Selector("paste:"))
            pumpMainRunLoop()
            #expect(names(harness) == ["Open Image", "Paste"])
            #expect(harness.statusBar.selectionSizeText == "25 \u{00D7} 25")
        }
    }

    // MARK: - E-6 expansion prompt

    @Test func pasteLargerExpand() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, width: 64, height: 48,
                                                named: "expand.png")
            let clipboard = harness.useClipboard(makePrivatePasteboard(),
                                                 expandChoice: .expandCanvas)
            defer { clipboard.restore() }
            defer { finish(harness) }
            writeImage(width: 100, height: 80, pixel: { _, _ in self.red },
                       to: clipboard.pasteboard)
            let zoomBefore = harness.statusBar.zoom

            harness.perform(Selector("paste:"))
            pumpMainRunLoop()
            #expect(clipboard.prompt.askCount == 1, "the E-6 prompt was asked")
            #expect(harness.statusBar.imageSizeText == "100 \u{00D7} 80")
            #expect(harness.statusBar.zoom == zoomBefore, "the zoom is kept")
            #expect(names(harness) == ["Open Image", "Paste"],
                    "the expansion is part of the Paste step")

            try #require(harness.window.undoManager).undo()
            pumpMainRunLoop()
            #expect(harness.statusBar.imageSizeText == "64 \u{00D7} 48",
                    "one undo restores the old canvas size")
        }
    }

    @Test func pasteLargerKeep() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, width: 64, height: 48,
                                                named: "keep.png")
            let clipboard = harness.useClipboard(makePrivatePasteboard(),
                                                 expandChoice: .keepCanvasSize)
            defer { clipboard.restore() }
            defer { finish(harness) }
            writeImage(width: 100, height: 80, pixel: { _, _ in self.red },
                       to: clipboard.pasteboard)

            harness.perform(Selector("paste:"))
            pumpMainRunLoop()
            #expect(clipboard.prompt.askCount == 1)
            #expect(harness.statusBar.imageSizeText == "64 \u{00D7} 48")
            #expect(names(harness) == ["Open Image", "Paste"])
        }
    }

    @Test func pasteLargerCancel() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, width: 64, height: 48,
                                                named: "cancel.png")
            let clipboard = harness.useClipboard(makePrivatePasteboard(),
                                                 expandChoice: nil)  // Cancel
            defer { clipboard.restore() }
            defer { finish(harness) }
            writeImage(width: 100, height: 80, pixel: { _, _ in self.red },
                       to: clipboard.pasteboard)

            harness.perform(Selector("paste:"))
            pumpMainRunLoop()
            #expect(clipboard.prompt.askCount == 1)
            #expect(names(harness) == ["Open Image"], "Cancel adds no Paste step")
            #expect(harness.statusBar.imageSizeText == "64 \u{00D7} 48")
            #expect(harness.document.undoBridge.state.floatingPixels == nil)
        }
    }

    @Test func pasteTooLarge() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            // The tiny cap applies to the paste, not to opening the fixture.
            PaintDocument.imageLimitsOverride = ImageLimits(memoryCapBytes: 40_000)
            defer { PaintDocument.imageLimitsOverride = nil }
            let clipboard = harness.useClipboard(makePrivatePasteboard())
            defer { clipboard.restore() }
            defer { finish(harness) }
            writeImage(width: 200, height: 200, pixel: { _, _ in self.red },
                       to: clipboard.pasteboard)

            harness.perform(Selector("paste:"))
            pumpMainRunLoop()
            #expect(clipboard.alerts.alerts.map(\.message)
                    == ["The image is too large to paste."])
            #expect(names(harness) == ["Open Image"], "nothing changes")

            // Paste into New Image: the same alert through the document controller,
            // and no new document.
            let controller = try #require(
                NSDocumentController.shared as? PaintDocumentController)
            let original = (controller.alertPresenter, controller.showsWindows)
            defer {
                (controller.alertPresenter, controller.showsWindows) = original
            }
            controller.alertPresenter = clipboard.alerts
            controller.showsWindows = false
            controller.pasteIntoNewImage(nil)
            pumpMainRunLoop()
            #expect(clipboard.alerts.alerts.count == 2,
                    "the same alert through the document controller")
            #expect(clipboard.alerts.alerts[1].message == "The image is too large to paste.")
            #expect(NSDocumentController.shared.documents.count == 1, "no new document")
        }
    }

    // MARK: - Paste into New Image (no document open)

    @Test func pasteIntoNewImageWithoutDocument() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            HeadlessAssertions.closeAllDocuments()
            let pasteboard = makePrivatePasteboard()
            let pattern: (Int, Int) -> ColorRGBA8 = { x, y in
                ColorRGBA8(red: UInt8((x &* 3) % 256), green: UInt8((y &* 5) % 256),
                           blue: 99, alpha: 255)
            }
            writeImage(width: 123, height: 45, pixel: pattern, to: pasteboard)
            let alerts = RecordingAlertPresenter()
            guard let harness = DocumentHarness.pasteIntoNewImage(pasteboard: pasteboard,
                                                                  alerts: alerts) else {
                Issue.record("Paste into New Image created no document")
                return
            }
            defer { finish(harness) }
            #expect(alerts.alerts.isEmpty)
            #expect(NSDocumentController.shared.documents.count == 1)
            harness.window.setContentSize(NSSize(width: 1000, height: 800))
            harness.appModel.setActiveSession(harness.windowController.toolSession)
            pumpMainRunLoop()
            #expect(harness.statusBar.imageSizeText == "123 \u{00D7} 45")
            #expect(names(harness) == ["New Image", "Paste"])
            #expect(harness.document.undoBridge.state.floatingPixels != nil,
                    "the pasted pixels float in the new document")
            // The suite's fresh `AppModel` installs after the creation paste (the policy
            // ran on the shared model), so select Move Selected Pixels here — the same
            // call the policy makes in the app — then commit with Return.
            harness.appModel.dispatcher.selectTool(.moveSelectedPixels)
            #expect(harness.appModel.activeToolID == .moveSelectedPixels)
            harness.keyDown("\r", keyCode: 36)
            pumpMainRunLoop()
            #expect(names(harness) == ["New Image", "Paste", "Finish Pixels"])

            let at = try await savedPixels(harness)
            for y in stride(from: 0, through: 44, by: 5) {
                for x in stride(from: 0, through: 122, by: 7) {
                    #expect(at(x, y) == pattern(x, y), "clipboard pixel at (\(x), \(y))")
                }
            }
            let full = try await readPNGBytes(harness)
            #expect(full.width == 123 && full.height == 45)
        }
    }

    /// Decodes the saved PNG's dimensions (the pixels above check the content).
    private func readPNGBytes(_ harness: DocumentHarness) async throws
        -> (width: Int, height: Int)
    {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests.clipboard.size.\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try await saveDocument(harness.document, to: url, ofType: "public.png",
                               for: .saveAsOperation)
        let data = try #require(try? Data(contentsOf: url))
        let decoded = try ImageDecoder.decode(data, limits: .standard)
        return (decoded.surface.size.width, decoded.surface.size.height)
    }
}
