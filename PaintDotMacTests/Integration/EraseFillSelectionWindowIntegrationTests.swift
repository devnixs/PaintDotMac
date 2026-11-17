import AppKit
import Testing

@testable import PaintDotMac

/// Edit > Erase / Fill Selection at window level (spec 0018 *Test plan*, headless):
/// documents through `DocumentHarness` (never shown), the fresh-suite `AppModel`'s black
/// primary, keys through `harness.shortcut` with the real virtual key codes (⌫ = 51
/// `"\u{7F}"`, ⌦ = 117 `"\u{F728}"`), the marching-ants accessibility value, the History
/// panel rows, and pixels checked by saving and decoding. Each test ends with
/// `HeadlessAssertions.closeAllDocuments()` and `noVisibleWindows()`.
@MainActor
@Suite(.serialized)
struct EraseFillSelectionWindowIntegrationTests {
    private static let backspace = "\u{7F}"     // the Delete key's character
    private static let forwardDelete = String(utf16CodeUnits: [unichar(NSDeleteFunctionKey)], count: 1)
    private static let backspaceKeyCode: UInt16 = 51
    private static let forwardDeleteKeyCode: UInt16 = 117

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

    /// 200×200 opaque white; a fresh-suite `AppModel` (primary black), ants live.
    private func openWhiteFixture(_ fixtures: FixtureFiles) async throws -> DocumentHarness {
        let url = try fixtures.writePNG(named: "erasefill-fixture.png",
                                        width: 200, height: 200) { _, _ in .white }
        let harness = try await DocumentHarness.open(url)
        harness.window.setContentSize(NSSize(width: 1000, height: 800))
        harness.document.undoBridge.undoManager.groupsByEvent = false
        harness.appModel.setActiveSession(harness.windowController.toolSession)
        pumpMainRunLoop()
        return harness
    }

    /// 0013's in-process seam: the selection is a rect (50, 50, 100, 100) with no step.
    private func selectRect(_ harness: DocumentHarness) {
        harness.windowController.setInitialSelection(PixelRect(x: 50, y: 50, width: 100, height: 100))
        pumpMainRunLoop()
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
            .appendingPathComponent("PaintDotMacTests.saved.\(UUID().uuidString).png")
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

    @Test func menuItemsAndShortcuts() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            selectRect(harness)
            let undoManager = try #require(harness.window.undoManager)

            // Both items are enabled for any open document (D-45(a)).
            #expect(harness.isEnabled(NSSelectorFromString("eraseSelection:")))
            #expect(harness.isEnabled(NSSelectorFromString("fillSelection:")))

            // ⌥⌫: fill with the fresh model's black primary; the ants stay.
            #expect(harness.shortcut(Self.backspace, keyCode: Self.backspaceKeyCode,
                                     modifiers: .option))
            pumpMainRunLoop()
            #expect(undoManager.undoMenuItemTitle == "Undo Fill Selection")
            #expect(antsMode(harness) == "animated", "Fill keeps the selection active")
            var pixels = try await savedPixels(harness)
            #expect(pixels(100, 100) == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255))
            #expect(pixels(20, 20) == .white, "outside the selection stays white")

            // ⌫: erase to transparency and deselect.
            #expect(harness.shortcut(Self.backspace, keyCode: Self.backspaceKeyCode))
            pumpMainRunLoop()
            #expect(undoManager.undoMenuItemTitle == "Undo Erase Selection")
            #expect(antsMode(harness) == "hidden", "Erase Selection deselects")
            pixels = try await savedPixels(harness)
            #expect(pixels(100, 100).alpha == 0)
            #expect(pixels(20, 20) == .white)

            // Undo: pixels and ants return together.
            undoManager.undo()
            pumpMainRunLoop()
            #expect(antsMode(harness) == "animated")
            pixels = try await savedPixels(harness)
            #expect(pixels(100, 100) == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                    "black again after saving")
            #expect(pixels(20, 20) == .white)

            // Deselect, then ⌦ with no selection: the whole layer erases (D-45(a)).
            harness.perform(NSSelectorFromString("deselect:"))
            pumpMainRunLoop()
            #expect(harness.shortcut(Self.forwardDelete, keyCode: Self.forwardDeleteKeyCode))
            pumpMainRunLoop()
            pixels = try await savedPixels(harness)
            #expect(pixels(100, 100).alpha == 0)
            #expect(pixels(20, 20).alpha == 0, "no selection = the whole active layer")
        }
    }

    @Test func historyAndUndo() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            selectRect(harness)
            let undoManager = try #require(harness.window.undoManager)

            #expect(harness.shortcut(Self.backspace, keyCode: Self.backspaceKeyCode,
                                     modifiers: .option))
            #expect(harness.shortcut(Self.backspace, keyCode: Self.backspaceKeyCode))
            pumpMainRunLoop()
            var rows = historyRows(harness)
            #expect(rows.map(\.name) == ["Open Image", "Fill Selection", "Erase Selection"])
            #expect(rows[1].state == .done && rows[2].isCurrent)

            undoManager.undo()
            pumpMainRunLoop()
            rows = historyRows(harness)
            #expect(rows[2].isUndone, "row 2 shows undone")
            #expect(undoManager.undoMenuItemTitle == "Undo Fill Selection")
            #expect(undoManager.redoMenuItemTitle == "Redo Erase Selection")

            undoManager.redo()
            pumpMainRunLoop()
            rows = historyRows(harness)
            #expect(!rows[2].isUndone)
            #expect(rows[2].isCurrent)
        }
    }

    @Test func backspaceInTextFieldDoesNotErase() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            selectRect(harness)

            // A text field (standing in for `toolOptions.width`) is the first responder.
            #expect(harness.shortcut("b"), "the Paintbrush tool key still works")
            let field = NSTextField(frame: NSRect(x: 8, y: 8, width: 120, height: 22))
            field.stringValue = "10"
            harness.window.contentView?.addSubview(field)
            harness.window.makeFirstResponder(field)
            pumpMainRunLoop()
            #expect(CanvasInputRouter.textInputHasFocus(in: harness.window),
                    "the field editor took the key")

            // ⌫ goes to the text, not the canvas: not consumed, menu disabled, no step.
            #expect(!harness.shortcut(Self.backspace, keyCode: Self.backspaceKeyCode))
            #expect(!harness.isEnabled(NSSelectorFromString("eraseSelection:")))
            #expect(!harness.isEnabled(NSSelectorFromString("fillSelection:")))
            #expect(historyRows(harness).count == 1, "only the base step")
            let pixels = try await savedPixels(harness)
            #expect(pixels(100, 100) == .white)
        }
    }
}
