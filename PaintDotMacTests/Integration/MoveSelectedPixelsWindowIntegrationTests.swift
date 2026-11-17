import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import PaintDotMac

/// Move Selected Pixels at window level (spec 0020 *Test plan*, headless): documents
/// through `DocumentHarness` (never shown), a fresh-suite `AppModel`, canvas input
/// through `harness.dragCanvas`, keys through `harness.shortcut`/`harness.keyDown`, the
/// handle frame through the overlay's `canvas.transformHandles` accessibility element;
/// pixels checked by saving and decoding the file. The fixture is a 200 × 200 PNG,
/// white with a red square (0, 0, 50, 50), and `setInitialSelection((0, 0, 50, 50))`.
@MainActor
@Suite(.serialized)
struct MoveSelectedPixelsWindowIntegrationTests {
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

    private func openFixture(_ fixtures: FixtureFiles) async throws -> DocumentHarness {
        let url = try fixtures.writePNG(named: "move-pixels-fixture.png",
                                        width: 200, height: 200) { x, y in
            x < 50 && y < 50 ? ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255) : .white
        }
        let harness = try await DocumentHarness.open(url)
        harness.window.setContentSize(NSSize(width: 1000, height: 800))
        harness.document.undoBridge.undoManager.groupsByEvent = false
        harness.appModel.setActiveSession(harness.windowController.toolSession)
        harness.windowController.setInitialSelection(PixelRect(x: 0, y: 0,
                                                               width: 50, height: 50))
        pumpMainRunLoop()
        return harness
    }

    /// The transform-handle overlay's accessibility value — the integer bounding box of
    /// the live corners as "x,y,w,h" (spec 0020 item 12); "missing" without the overlay.
    private func handlesValue(_ harness: DocumentHarness) -> String {
        guard let content = harness.window.contentView,
              let element = AX.withAccessibilityClient(
                  { AX.first(inRoot: content, identifier: "canvas.transformHandles") })
        else { return "missing" }
        return AX.value(of: element) ?? "none"
    }

    private func savedPixels(_ harness: DocumentHarness) async throws
        -> (Int, Int) -> ColorRGBA8
    {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests.movepixels.\(UUID().uuidString).png")
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

    private func names(_ harness: DocumentHarness) -> [String] {
        harness.document.undoBridge.history.steps.map(\.name)
    }

    /// View points of an image-space drag (the spec's "drags between the view points of
    /// image coordinates").
    private func view(_ harness: DocumentHarness, _ x: Double, _ y: Double) -> CGPoint {
        harness.viewPoint(forImagePoint: CGPoint(x: x, y: y))
    }

    // MARK: - Tests

    @Test func dragMovesPixelsAndFinish() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }
            #expect(harness.shortcut("m"))
            #expect(harness.appModel.activeToolID == .moveSelectedPixels)
            #expect(handlesValue(harness) == "0,0,50,50")
            harness.dragCanvas(from: view(harness, 25, 25), to: view(harness, 125, 25))
            pumpMainRunLoop()
            #expect(names(harness).last == "Move Pixels")
            #expect(handlesValue(harness) == "100,0,50,50")
            harness.keyDown("\r", keyCode: 36)
            pumpMainRunLoop()
            #expect(names(harness).last == "Finish Pixels")
            let at = try await savedPixels(harness)
            let isRed = { (p: (Int, Int)) in
                let c = at(p.0, p.1)
                return c.red == 255 && c.green == 0 && c.blue == 0 && c.alpha == 255
            }
            #expect(at(10, 10).alpha == 0, "the vacated square is transparent")
            #expect(isRed((110, 10)), "the moved square")
            var startX: Int?
            for x in 0..<200 where isRed((x, 10)) {
                startX = x
                break
            }
            if let startX {
                #expect(abs(startX - 100) <= 1,
                        "the red run on row 10 starts at 100 ± 1, got \(startX)")
            } else {
                Issue.record("no red pixels on row 10")
            }
        }
    }

    @Test func commandDragCopies() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }
            #expect(harness.shortcut("m"))
            harness.dragCanvas(from: view(harness, 25, 25), to: view(harness, 125, 25),
                               modifiers: [.command])
            pumpMainRunLoop()
            harness.keyDown("\r", keyCode: 36)
            pumpMainRunLoop()
            let at = try await savedPixels(harness)
            #expect(at(10, 10).red == 255 && at(10, 10).green == 0,
                    "⌘-drag leaves the original in place")
            #expect(at(110, 10).red == 255 && at(110, 10).green == 0, "…and lands the copy")
        }
    }

    @Test func toolSwitchFinishes() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }
            #expect(harness.shortcut("m"))
            harness.dragCanvas(from: view(harness, 25, 25), to: view(harness, 125, 25))
            pumpMainRunLoop()
            #expect(harness.shortcut("b"))
            pumpMainRunLoop()
            #expect(names(harness).last == "Finish Pixels")
            #expect(harness.appModel.activeToolID == .paintbrush)
        }
    }

    @Test func deselectFinishesFirst() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }
            #expect(harness.shortcut("m"))
            harness.dragCanvas(from: view(harness, 25, 25), to: view(harness, 125, 25))
            pumpMainRunLoop()
            // The Edit-menu path: `prepareForNavigation` (reason `.command`) first, then
            // the command's own step (spec 0020 item 9).
            let bridge = harness.document.undoBridge
            bridge.prepareForNavigation?()
            if let item = SelectionCommand.deselect.makeHistoryItem(for: bridge.state) {
                bridge.perform(item)
            }
            pumpMainRunLoop()
            #expect(names(harness).suffix(2) == ["Finish Pixels", "Deselect"])
        }
    }

    @Test func escapeCancels() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }
            #expect(harness.shortcut("m"))
            harness.dragCanvas(from: view(harness, 25, 25), to: view(harness, 125, 25))
            pumpMainRunLoop()
            harness.keyDown("\u{1b}", keyCode: 53)
            pumpMainRunLoop()
            let undoManager = harness.document.undoBridge.undoManager
            #expect(harness.document.undoBridge.history.canRedo,
                    "the session's step waits in redo")
            #expect(undoManager.redoMenuItemTitle == "Redo Move Pixels")
            #expect(!harness.document.undoBridge.history.canUndo, "back at the base step")
            let at = try await savedPixels(harness)
            #expect(at(10, 10).red == 255 && at(10, 10).green == 0,
                    "the fixture is exactly restored")
            #expect(at(110, 10) == .white, "white again")
        }
    }

    @Test func undoFinishRestoresFloating() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }
            #expect(harness.shortcut("m"))
            harness.dragCanvas(from: view(harness, 25, 25), to: view(harness, 125, 25))
            pumpMainRunLoop()
            #expect(harness.shortcut("b"))  // tool switch → "Finish Pixels"
            pumpMainRunLoop()
            #expect(harness.appModel.activeToolID == .paintbrush)
            let undoManager = harness.document.undoBridge.undoManager
            undoManager.undo()  // undo "Finish Pixels"…
            pumpMainRunLoop()
            #expect(harness.appModel.activeToolID == .moveSelectedPixels,
                    "…brings the pixels back and selects their tool (item 11)")
            #expect(handlesValue(harness) != "missing", "the handles are back on the frame")
            undoManager.undo()  // undo "Move Pixels" → the fixture again
            pumpMainRunLoop()
            #expect(!harness.document.undoBridge.history.canUndo, "at the base step")
            let at = try await savedPixels(harness)
            #expect(at(10, 10).red == 255 && at(10, 10).green == 0, "fixture red square")
            #expect(at(110, 10) == .white, "fixture background")
        }
    }

    @Test func mKeyCycles() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }
            #expect(harness.shortcut("m"))
            #expect(harness.appModel.activeToolID == .moveSelectedPixels)
            #expect(harness.shortcut("m"))
            #expect(harness.appModel.activeToolID == .moveSelection, "M M cycles (D-13)")
            #expect(harness.shortcut("b"))
            #expect(harness.shortcut("m", modifiers: [.shift]))
            #expect(harness.appModel.activeToolID == .moveSelection, "Shift+M goes last")
        }
    }
}
