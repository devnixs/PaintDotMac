import AppKit
import Testing

@testable import PaintDotMac

/// The History panel at window level (spec 0010 *Test plan*, headless): the real
/// `NSHostingView(HistoryPanelView)` inside the app-wide History `NSPanel` (built by
/// `PanelController`, never ordered on screen), driven through its accessibility tree —
/// rows are clicked with their default accessibility action, the same `clickRow` path a
/// mouse click takes. Strokes are synthesized drags on the real document window's canvas;
/// the pixel oracle is the programmatic PNG save's RGBA buffer.
@MainActor
@Suite(.serialized)
struct HistoryPanelWindowIntegrationTests {
    private struct Fixture {
        let harness: DocumentHarness
        let panelController: PanelController
        /// The History panel's hosting view — the accessibility root.
        let root: NSView
        let panel: HistoryPanelModel
    }

    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    private func finish(_ fixture: Fixture) {
        fixture.harness.close()
        fixture.harness.discardAppModelSuite()
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    /// Opens a 200×200 opaque white PNG with a fresh-suite `AppModel`, installs the window's
    /// session as the active one (what `windowDidBecomeMain` does), and pins the Paintbrush
    /// options: width 10, antialiasing off (the default tool is the Paintbrush, D-35).
    private func setUp(_ fixtures: FixtureFiles) async throws -> Fixture {
        let url = try fixtures.writePNG(named: "history-fixture.png", width: 200, height: 200) { _, _ in
            ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255)
        }
        let harness = try await DocumentHarness.open(url)
        // One undo group per stroke (see `stroke`): the bridge's explicit grouping takes
        // over what AppKit's event grouping would do for real dispatched events.
        harness.document.undoBridge.undoManager.groupsByEvent = false
        let panelController = PanelController(model: harness.appModel)
        let root = try #require(panelController.panels[.history]?.contentView)
        let keys = BrushOptions.keys(for: .paintbrush)
        #expect(harness.shortcut("b"), "fixture: Paintbrush selected with B (D-35 starts on it)")
        harness.appModel.toolOptions.setValue(10.0, for: keys.width)
        harness.appModel.toolOptions.setValue(false, for: keys.antialiasing)
        harness.appModel.setActiveSession(harness.windowController.toolSession)
        pumpMainRunLoop()
        return Fixture(harness: harness, panelController: panelController, root: root,
                       panel: harness.appModel.historyPanel)
    }

    /// One Paintbrush stroke across the 200-wide canvas at canvas-space `canvasY`.
    ///
    /// The window's `UndoManager` runs with `groupsByEvent = false` (set in `setUp`), so
    /// 0008's bridge registers each stroke as exactly one explicit undo group — the
    /// documented convention of every hosted bridge test (`NavigationUndoManager` and the
    /// app's real per-event grouping are exercised by 0008's own suites; the headless
    /// harness delivers events straight to the view, bypassing the event loop AppKit
    /// would bracket).
    private func stroke(_ fixture: Fixture, canvasY: Int) {
        let transform = fixture.harness.canvasView.transform
        let from = transform.canvasToView(CGPoint(x: 30, y: canvasY))
        let to = transform.canvasToView(CGPoint(x: 170, y: canvasY))
        fixture.harness.dragCanvas(from: from, to: to, steps: 10)
    }

    // MARK: - Accessibility reads on the hosted panel

    private struct RowFacts: Equatable {
        var label: String?
        var value: String?
        var selected: Bool
    }

    private func row(_ root: NSView, _ index: Int) -> RowFacts? {
        pumpMainRunLoop()
        return AX.withAccessibilityClient {
            guard let element = AX.first(inRoot: root, identifier: "historyRow.\(index)") else {
                return nil
            }
            let facts = RowFacts(label: AX.label(of: element), value: AX.value(of: element),
                                 selected: AX.isSelected(element))
            withExtendedLifetime(element) {}
            return facts
        }
    }

    private func values(_ root: NSView) -> [String?] {
        var collected: [String?] = []
        var index = 0
        while let facts = row(root, index) {
            collected.append(facts.value)
            index += 1
        }
        return collected
    }

    private func press(_ root: NSView, _ identifier: String) {
        pumpMainRunLoop()
        #expect(AX.pressButton(inRoot: root, identifier: identifier), "press \(identifier)")
        pumpMainRunLoop()
    }

    @discardableResult
    private func pressExpectingDisabled(_ root: NSView, _ identifier: String) -> Bool {
        pumpMainRunLoop()
        let pressed = AX.withAccessibilityClient {
            guard let element = AX.first(inRoot: root, identifier: identifier) else {
                Issue.record("no accessibility element \(identifier)")
                return true
            }
            let result = AX.press(element)
            withExtendedLifetime(element) {}
            return result
        }
        pumpMainRunLoop()
        return pressed
    }

    /// The saved PNG's RGBA buffer — the independent pixel oracle.
    private func savedBuffer(_ harness: DocumentHarness) async throws -> [UInt8] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests.history.\(UUID().uuidString).png")
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
        return bytes
    }

    private var allWhite200: [UInt8] { Array(repeating: UInt8(0xFF), count: 200 * 200 * 4) }

    // MARK: - Tests

    @Test func strokesAppearAsRows() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let fixture = try await setUp(fixtures)
            defer { finish(fixture) }

            stroke(fixture, canvasY: 40)
            stroke(fixture, canvasY: 100)
            stroke(fixture, canvasY: 160)

            #expect(row(fixture.root, 0)?.label == "Open Image")
            for index in 1...3 {
                #expect(row(fixture.root, index)?.label == "Paintbrush", "row \(index)")
            }
            #expect(row(fixture.root, 3)?.value == "current")
            #expect(row(fixture.root, 4) == nil, "no fourth stroke, no fourth row")
            #expect(values(fixture.root) == ["done", "done", "done", "current"])
        }
    }

    @Test func clickEarlierRowRestoresPixels() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let fixture = try await setUp(fixtures)
            defer { finish(fixture) }

            stroke(fixture, canvasY: 40)
            let p1 = try await savedBuffer(fixture.harness)
            stroke(fixture, canvasY: 100)
            let p2 = try await savedBuffer(fixture.harness)
            stroke(fixture, canvasY: 160)
            let p3 = try await savedBuffer(fixture.harness)
            let white = allWhite200
            #expect(p1 != white && p1 != p2 && p2 != p3, "the strokes differ")

            press(fixture.root, "historyRow.1")
            #expect(try await savedBuffer(fixture.harness) == p1, "row 1 shows exactly state P1")

            press(fixture.root, "historyRow.0")
            #expect(try await savedBuffer(fixture.harness) == white,
                    "row 0 is the opened image, every pixel FFFFFFFF")

            press(fixture.root, "historyRow.3")
            #expect(try await savedBuffer(fixture.harness) == p3, "the redo jump lands on P3")
        }
    }

    @Test func clickEarlierRowGreysLaterRows() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let fixture = try await setUp(fixtures)
            defer { finish(fixture) }
            stroke(fixture, canvasY: 40)
            stroke(fixture, canvasY: 100)
            stroke(fixture, canvasY: 160)

            press(fixture.root, "historyRow.1")
            #expect(values(fixture.root) == ["done", "current", "undone", "undone"])
            #expect(row(fixture.root, 1)?.selected == true, "the current row carries .isSelected")
            #expect(row(fixture.root, 2)?.selected == false)
        }
    }

    @Test func clickCurrentRowTogglesToPrevious() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let fixture = try await setUp(fixtures)
            defer { finish(fixture) }
            stroke(fixture, canvasY: 40)
            stroke(fixture, canvasY: 100)
            stroke(fixture, canvasY: 160)
            #expect(row(fixture.root, 3)?.value == "current")

            press(fixture.root, "historyRow.3")   // the Paint.NET toggle, click 1
            #expect(row(fixture.root, 2)?.value == "current")
            #expect(row(fixture.root, 3)?.value == "undone")

            press(fixture.root, "historyRow.3")   // click the same row again → redo
            #expect(row(fixture.root, 3)?.value == "current")
            #expect(row(fixture.root, 2)?.value == "done")
        }
    }

    @Test func editMenuFollowsPanelJump() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let fixture = try await setUp(fixtures)
            defer { finish(fixture) }
            stroke(fixture, canvasY: 40)
            stroke(fixture, canvasY: 100)
            stroke(fixture, canvasY: 160)
            let undo = NSSelectorFromString("undo:")
            let redo = NSSelectorFromString("redo:")

            press(fixture.root, "historyRow.1")
            #expect(fixture.harness.isEnabled(undo))
            #expect(fixture.harness.isEnabled(redo))
            #expect(fixture.harness.window.undoManager?.undoMenuItemTitle == "Undo Paintbrush")
            #expect(fixture.harness.window.undoManager?.redoMenuItemTitle == "Redo Paintbrush")

            press(fixture.root, "historyRow.0")
            #expect(!fixture.harness.isEnabled(undo), "nothing left to undo at the base step")
            #expect(fixture.harness.isEnabled(redo))
        }
    }

    @Test func keyboardUndoUpdatesRows() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let fixture = try await setUp(fixtures)
            defer { finish(fixture) }
            stroke(fixture, canvasY: 40)
            stroke(fixture, canvasY: 100)
            stroke(fixture, canvasY: 160)

            fixture.harness.perform(NSSelectorFromString("undo:"))
            #expect(row(fixture.root, 3)?.value == "undone")
            #expect(row(fixture.root, 2)?.value == "current")

            fixture.harness.perform(NSSelectorFromString("redo:"))
            #expect(row(fixture.root, 3)?.value == "current")
        }
    }

    @Test func footerButtons() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let fixture = try await setUp(fixtures)
            defer { finish(fixture) }
            stroke(fixture, canvasY: 40)
            stroke(fixture, canvasY: 100)
            stroke(fixture, canvasY: 160)

            press(fixture.root, "history.undo")
            #expect(row(fixture.root, 2)?.value == "current")

            press(fixture.root, "history.redo")
            #expect(row(fixture.root, 3)?.value == "current")
            #expect(!fixture.panel.model.canRedo)
            #expect(!pressExpectingDisabled(fixture.root, "history.redo"),
                    "Redo is disabled at the newest step")

            press(fixture.root, "historyRow.0")
            #expect(!fixture.panel.model.canUndo)
            #expect(!pressExpectingDisabled(fixture.root, "history.undo"),
                    "Undo is disabled at the base step")
            #expect(row(fixture.root, 0)?.value == "current")
        }
    }

    @Test func newStrokeDiscardsGreyedRows() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let fixture = try await setUp(fixtures)
            defer { finish(fixture) }
            stroke(fixture, canvasY: 40)
            let p1 = try await savedBuffer(fixture.harness)
            stroke(fixture, canvasY: 100)
            let p2 = try await savedBuffer(fixture.harness)
            stroke(fixture, canvasY: 160)

            press(fixture.root, "historyRow.1")
            stroke(fixture, canvasY: 180)

            #expect(values(fixture.root) == ["done", "done", "current"],
                    "exactly three rows; the greyed ones are gone")
            #expect(row(fixture.root, 3) == nil)
            #expect(row(fixture.root, 2)?.label == "Paintbrush")
            #expect(!values(fixture.root).contains("undone"))

            let buffer = try await savedBuffer(fixture.harness)
            #expect(buffer != p2 && buffer != p1, "S1 + the new stroke is its own state")
            #expect(!fixture.panel.model.canRedo)
            #expect(!pressExpectingDisabled(fixture.root, "history.redo"))
        }
    }

    @Test func panelFollowsActiveDocument() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let fixture = try await setUp(fixtures)
            defer { finish(fixture) }
            stroke(fixture, canvasY: 40)
            stroke(fixture, canvasY: 100)
            stroke(fixture, canvasY: 160)
            #expect(values(fixture.root).count == 4)

            // A second document, rewired onto the same shared `AppModel` — what the real
            // app has — then its window reports main (the `windowDidBecomeMain` path).
            let other = try #require(DocumentHarness.newImage(
                presenter: ScriptedNewImagePresenter(steps: [.ok]),
                pasteboard: makePrivatePasteboard()))
            defer {
                other.close()
                other.discardAppModelSuite()
            }
            other.windowController.appModel = fixture.harness.appModel
            fixture.harness.appModel.setActiveSession(other.windowController.toolSession)
            pumpMainRunLoop()

            #expect(values(fixture.root) == ["current"], "the new document shows one row")
            #expect(row(fixture.root, 0)?.label == "New Image")
            #expect(!fixture.panel.model.canUndo && !fixture.panel.model.canRedo)

            fixture.harness.appModel.setActiveSession(fixture.harness.windowController.toolSession)
            pumpMainRunLoop()
            #expect(values(fixture.root) == ["done", "done", "done", "current"],
                    "document A's history is back")

            other.close()   // untouched → closes without a prompt (APP-9)
            pumpMainRunLoop()
            #expect(values(fixture.root).count == 4, "the panel keeps showing A")
        }
    }
}
