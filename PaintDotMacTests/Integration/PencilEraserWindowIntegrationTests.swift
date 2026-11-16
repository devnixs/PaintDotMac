import AppKit
import Testing

@testable import PaintDotMac

/// The Pencil and Eraser at window level (spec 0011 *Test plan*, headless): documents
/// opened through `DocumentHarness` (never shown), tool keys through `harness.shortcut`,
/// painting through synthesized canvas drags, the History panel model (0010), and pixels
/// read back from a programmatic save.
@MainActor
@Suite(.serialized)
struct PencilEraserWindowIntegrationTests {
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

    /// The opaque white 200×200 PNG fixture generated at test time.
    private func openWhiteFixture(_ fixtures: FixtureFiles) async throws -> DocumentHarness {
        let url = try fixtures.writePNG(named: "pencil-eraser-fixture.png",
                                        width: 200, height: 200) { _, _ in
            ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255)
        }
        let harness = try await DocumentHarness.open(url)
        harness.window.setContentSize(NSSize(width: 1000, height: 800))
        return harness
    }

    /// View-space endpoints of a horizontal canvas-space segment (fit zoom ≠ 100 %).
    private func viewSegment(_ harness: DocumentHarness, canvasY: Int,
                             fromX: Int, toX: Int) -> (CGPoint, CGPoint) {
        let t = harness.canvasView.transform
        return (t.canvasToView(CGPoint(x: Double(fromX), y: Double(canvasY))),
                t.canvasToView(CGPoint(x: Double(toX), y: Double(canvasY))))
    }

    private func identifiers(_ harness: DocumentHarness) -> Set<String> {
        guard let content = harness.window.contentView else { return [] }
        return AX.withAccessibilityClient { AX.identifiers(inRoot: content) }
    }

    /// Saves through the document (no sheet) and decodes the file's pixels.
    private func savedPixels(_ harness: DocumentHarness) async throws -> (Int, Int) -> ColorRGBA8 {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests.pencilEraser.\(UUID().uuidString).png")
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

    // MARK: - Tool keys and the options bar (T-12, T-13)

    @Test func toolKeysSelectTools() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }

            #expect(harness.shortcut("p"))
            pumpMainRunLoop()
            #expect(harness.appModel.activeToolID == .pencil)
            pumpMainRunLoop()
            var ids = identifiers(harness)
            #expect(ids.contains("toolOptions.blendMode"), "the Pencil shows the blend mode")
            #expect(!ids.contains("toolOptions.width"),
                    "the Pencil shows no width (T-13: always one pixel wide)")

            #expect(harness.shortcut("e"))
            pumpMainRunLoop()
            #expect(harness.appModel.activeToolID == .eraser)
            pumpMainRunLoop()
            ids = identifiers(harness)
            for id in ["toolOptions.width", "toolOptions.hardness", "toolOptions.antialiasing"] {
                #expect(ids.contains(id), "the Eraser shows \(id)")
            }
            #expect(!ids.contains("toolOptions.blendMode"),
                    "the Eraser has no blend mode (T-12/D-27)")
        }
    }

    // MARK: - History panel rows and the Edit menu

    @Test func historyStepsAndUndo() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            // One undo group per stroke (0010's convention) and the History panel bound
            // to this window's session.
            harness.document.undoBridge.undoManager.groupsByEvent = false
            harness.appModel.setActiveSession(harness.windowController.toolSession)
            pumpMainRunLoop()

            #expect(harness.shortcut("p"))
            var segment = viewSegment(harness, canvasY: 60, fromX: 40, toX: 160)
            harness.dragCanvas(from: segment.0, to: segment.1, steps: 8)
            #expect(harness.shortcut("e"))
            segment = viewSegment(harness, canvasY: 120, fromX: 40, toX: 160)
            harness.dragCanvas(from: segment.0, to: segment.1, steps: 8)

            let manager = try #require(harness.window.undoManager)
            #expect(manager.undoMenuItemTitle == "Undo Eraser")
            pumpMainRunLoop()
            let rowNames = harness.appModel.historyPanel.model.rows.map(\.name)
            #expect(rowNames == ["Open Image", "Pencil", "Eraser"],
                    "the History panel (0010) shows rows 1 and 2 as Pencil/Eraser — got \(rowNames)")

            harness.perform(NSSelectorFromString("undo:"))
            #expect(manager.undoMenuItemTitle == "Undo Pencil")
            pumpMainRunLoop()
            harness.perform(NSSelectorFromString("redo:"))
            #expect(manager.undoMenuItemTitle == "Undo Eraser")
        }
    }

    // MARK: - Pixels through the real canvas

    @Test func eraserMakesPixelsTransparent() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            #expect(harness.shortcut("e"))
            harness.appModel.toolOptions.setValue(
                40.0, for: BrushOptions.keys(for: .eraser).width)
            let segment = viewSegment(harness, canvasY: 100, fromX: 40, toX: 160)
            harness.dragCanvas(from: segment.0, to: segment.1, steps: 10)

            let pixels = try await savedPixels(harness)
            #expect(pixels(100, 100) == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0),
                    "the fully erased center is (0,0,0,0) in the saved file")
            #expect(pixels(2, 2) == ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255),
                    "far from the stroke the fixture is intact")
        }
    }

    // MARK: - Options-bar stepper writes the Eraser's own keys (D-27)

    @Test func eraserStepperWritesEraserKeysOnly() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            #expect(harness.shortcut("e"))
            pumpMainRunLoop()
            let content = try #require(harness.window.contentView)
            // The parameterized bar must step `tool.eraser.width`, not the Paintbrush's,
            // and the Eraser must never store a blend-mode key (T-12/D-27).
            #expect(AX.pressButton(inRoot: content, identifier: "toolOptions.width.increase"),
                    "the + stepper exists for the Eraser")
            pumpMainRunLoop()
            let eraserWidth = BrushOptions.keys(for: .eraser).width.defaultsKey
            let brushWidth = BrushOptions.keys(for: .paintbrush).width.defaultsKey
            #expect(harness.appModel.defaultsForTests.double(forKey: eraserWidth) == 3,
                    "default 2 + one step, under the eraser prefix")
            #expect(harness.appModel.defaultsForTests.object(forKey: brushWidth) == nil,
                    "the Paintbrush's keys stay untouched")
            #expect(harness.appModel.defaultsForTests.object(forKey: "tool.eraser.blendMode") == nil,
                    "the Eraser has no blend mode (D-27)")
            #expect(AX.pressButton(inRoot: content, identifier: "toolOptions.width.decrease"))
            pumpMainRunLoop()
            #expect(harness.appModel.defaultsForTests.double(forKey: eraserWidth) == 2)
        }
    }

    // MARK: - `[`/`]` persistence

    @Test func eraserWidthPersists() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            #expect(harness.shortcut("e"))
            // Real key routing needs the canvas focused, which happens on the first click;
            // the click also installs the window's session on the dispatcher (0009's rule).
            harness.clickCanvas(at: .zero)
            for _ in 0 ..< 3 { #expect(harness.shortcut("]")) }
            let widthKey = BrushOptions.keys(for: .eraser).width
            #expect(harness.appModel.toolOptions.value(widthKey) == 5,
                    "default 2 + three steps")

            // A new `AppModel` on the same suite is what a relaunch reads.
            let relaunched = AppModel(defaults: harness.appModel.defaultsForTests)
            relaunched.selectTool(.eraser)
            #expect(relaunched.activeToolID == .eraser)
            #expect(relaunched.toolOptions.value(widthKey) == 5,
                    "the Eraser width survives the relaunch, per tool (TOOL-C)")
        }
    }
}
