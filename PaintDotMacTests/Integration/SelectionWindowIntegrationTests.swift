import AppKit
import Testing

@testable import PaintDotMac

/// The selection commands and the marching ants at window level (spec 0013 *Test plan*,
/// headless): documents through `DocumentHarness` (never shown), menu enabling and undo
/// titles, History panel rows, the `canvas.marchingAnts` accessibility value, Reduce
/// Motion, the initial-selection seam, and a real-pixel save through the selection clip.
@MainActor
@Suite(.serialized)
struct SelectionWindowIntegrationTests {
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

    private func openWhiteFixture(_ fixtures: FixtureFiles, side: Int = 200) async throws
        -> DocumentHarness
    {
        let url = try fixtures.writePNG(named: "selection-fixture-\(side).png",
                                        width: side, height: side) { _, _ in .white }
        let harness = try await DocumentHarness.open(url)
        harness.window.setContentSize(NSSize(width: 1000, height: 800))
        harness.document.undoBridge.undoManager.groupsByEvent = false
        harness.appModel.setActiveSession(harness.windowController.toolSession)
        pumpMainRunLoop()
        return harness
    }

    /// The overlay's accessibility value ("hidden", "animated", or "static").
    private func antsMode(_ harness: DocumentHarness) -> String {
        guard let content = harness.window.contentView,
              let element = AX.withAccessibilityClient(
                  { AX.first(inRoot: content, identifier: "canvas.marchingAnts") })
        else { return "missing" }
        return AX.value(of: element) ?? "none"
    }

    private func overlay(_ harness: DocumentHarness) throws -> MarchingAntsOverlay {
        try #require(harness.windowController.marchingAntsOverlay)
    }

    // MARK: - Menu enablement and undo titles

    @Test func menuEnablement() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            let manager = try #require(harness.window.undoManager)

            #expect(harness.isEnabled(NSSelectorFromString("selectAll:")))
            #expect(!harness.isEnabled(NSSelectorFromString("deselect:")))
            #expect(!harness.isEnabled(NSSelectorFromString("invertSelection:")))

            harness.perform(NSSelectorFromString("selectAll:"))
            pumpMainRunLoop()
            #expect(harness.isEnabled(NSSelectorFromString("deselect:")))
            #expect(harness.isEnabled(NSSelectorFromString("invertSelection:")))
            #expect(manager.undoMenuItemTitle == "Undo Select All")

            harness.perform(NSSelectorFromString("deselect:"))
            pumpMainRunLoop()
            #expect(!harness.isEnabled(NSSelectorFromString("deselect:")))
            #expect(manager.undoMenuItemTitle == "Undo Deselect")
        }
    }

    @Test func menuShortcutFiresSelectAll() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }

            // The responder chain must route the menu item itself, not a direct call.
            let item = try #require(NSApp.menu?.item(withTitle: "Edit")?.submenu?
                .item(withTitle: "Select All"))
            let target = try #require(harness.target(for: NSSelectorFromString("selectAll:")))
            #expect(target is DocumentWindowController,
                    "the window controller answers selectAll:")
            NSApp.sendAction(NSSelectorFromString("selectAll:"), to: target, from: item)
            pumpMainRunLoop()
            #expect(harness.document.undoBridge.state.selection
                    == .all(canvasSize: harness.document.undoBridge.state.image.size))
        }
    }

    @Test func selectAllDeselectInvertUndoTitles() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            let manager = try #require(harness.window.undoManager)
            let bridge = harness.document.undoBridge

            // (⌘A itself is wired through the menu — MainMenuTests pins the key; the
            // harness `shortcut` helper only drives tool keys and View shortcuts.)
            harness.perform(NSSelectorFromString("selectAll:"))
            pumpMainRunLoop()
            #expect(manager.undoMenuItemTitle == "Undo Select All")
            #expect(bridge.history.steps.map(\.name) == ["Open Image", "Select All"])

            harness.perform(NSSelectorFromString("invertSelection:"))
            pumpMainRunLoop()
            #expect(bridge.state.selection == nil, "Invert on Select All deselects")
            #expect(manager.undoMenuItemTitle == "Undo Invert Selection")
            #expect(bridge.history.steps.map(\.name)
                    == ["Open Image", "Select All", "Invert Selection"])

            manager.undo()
            #expect(bridge.state.selection == .all(canvasSize: bridge.state.image.size))
            manager.undo()
            #expect(bridge.state.selection == nil)
            manager.redo()
            #expect(bridge.state.selection == .all(canvasSize: bridge.state.image.size))
            manager.redo()
            #expect(bridge.state.selection == nil)
        }
    }

    @Test func noOpAddsNoStepThroughMenu() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            let bridge = harness.document.undoBridge

            harness.perform(NSSelectorFromString("deselect:"))   // nothing selected
            #expect(bridge.history.steps.count == 1)
            harness.perform(NSSelectorFromString("selectAll:"))
            harness.perform(NSSelectorFromString("selectAll:"))  // second is a no-op
            #expect(bridge.history.steps.map(\.name) == ["Open Image", "Select All"])
        }
    }

    @Test func commandDisabledDuringGestureAndStrokeCommitsOnRelease() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            let bridge = harness.document.undoBridge
            #expect(harness.shortcut("b"))
            pumpMainRunLoop()
            let start = harness.viewPoint(forImagePoint: CGPoint(x: 20, y: 50))
            let end = harness.viewPoint(forImagePoint: CGPoint(x: 70, y: 50))
            // Mid-gesture: the commands are disabled and the action no-ops (0013
            // *Edge cases*).
            harness.canvasPress(at: start)
            harness.canvasDrag(to: end)
            pumpMainRunLoop()
            #expect(!harness.isEnabled(NSSelectorFromString("selectAll:")),
                    "disabled while a gesture is in progress")
            harness.perform(NSSelectorFromString("selectAll:"))
            #expect(bridge.history.steps.count == 1, "the action no-ops mid-gesture")
            #expect(bridge.state.selection == nil)

            // On release the stroke commits as its own step; the command then runs and
            // lands after it.
            harness.canvasRelease(at: end)
            pumpMainRunLoop()
            #expect(bridge.history.steps.map(\.name) == ["Open Image", "Paintbrush"])
            harness.perform(NSSelectorFromString("selectAll:"))
            pumpMainRunLoop()
            let names = bridge.history.steps.map(\.name)
            #expect(names == ["Open Image", "Paintbrush", "Select All"],
                    "the stroke committed before the selection step: \(names)")
        }
    }

    @Test func pasteOnEmptyBoardDoesNotCrash() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            let clipboard = harness.useClipboard(makePrivatePasteboard())
            defer { clipboard.restore() }
            defer { finish(harness) }
            // 0021: `paste:` is implemented — with an empty board it alerts through the
            // injected presenter, changes nothing, and leaves no residue; the selection
            // commands keep working afterwards.
            harness.perform(NSSelectorFromString("paste:"))
            pumpMainRunLoop()
            #expect(clipboard.alerts.alerts.map(\.message)
                    == ["The clipboard doesn\u{2019}t contain an image."])
            #expect(harness.document.undoBridge.history.steps.map(\.name) == ["Open Image"])
            harness.perform(NSSelectorFromString("selectAll:"))
            pumpMainRunLoop()
            #expect(harness.document.undoBridge.state.selection
                    == .all(canvasSize: harness.document.undoBridge.state.image.size))
        }
    }

    // MARK: - History panel rows

    @Test func selectionStepsInHistory() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }

            harness.perform(NSSelectorFromString("selectAll:"))
            harness.perform(NSSelectorFromString("invertSelection:"))
            pumpMainRunLoop()
            var model = harness.appModel.historyPanel.model
            #expect(model.rows.map(\.name) == ["Open Image", "Select All", "Invert Selection"])
            #expect(model.rows[1].accessibilityValue == "done")
            #expect(model.rows[2].accessibilityValue == "current")

            harness.perform(NSSelectorFromString("undo:"))
            pumpMainRunLoop()
            model = harness.appModel.historyPanel.model
            #expect(model.rows.count == 3)
            #expect(model.rows[1].name == "Select All")
            #expect(model.rows[1].accessibilityValue == "current")
            #expect(model.rows[2].name == "Invert Selection")
            #expect(model.rows[2].accessibilityValue == "undone",
                    "the undone row keeps its name and shows \"undone\"")

            // A new command after the undo drops the undone redo branch (0008 rules).
            harness.perform(NSSelectorFromString("deselect:"))
            pumpMainRunLoop()
            model = harness.appModel.historyPanel.model
            #expect(model.rows.map(\.name) == ["Open Image", "Select All", "Deselect"])
        }
    }

    // MARK: - Marching ants

    @Test func overlayInHierarchyAndIdentified() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            let canvas = harness.canvasView
            let ants = try overlay(harness)
            let toolOverlay = try #require(harness.windowController.overlayView)
            let siblings = canvas.superview?.subviews ?? []
            guard siblings.contains(where: { $0 === canvas }),
                  let antsIndex = siblings.firstIndex(of: ants),
                  let overlayIndex = siblings.firstIndex(of: toolOverlay) else {
                Issue.record("ants overlay is not a sibling of the canvas")
                return
            }
            #expect(overlayIndex > antsIndex, "ToolOverlayView above the ants")
            let hit = canvas.superview?.hitTest(NSPoint(x: canvas.frame.midX,
                                                        y: canvas.frame.midY))
            #expect(hit === canvas, "the ants never eat events")
            let ids = AX.withAccessibilityClient { AX.identifiers(inRoot: canvas.superview!) }
            #expect(ids.contains("canvas.marchingAnts"))
            #expect(ants.mode == .hidden, "no selection at open")
            _ = antsIndex
        }
    }

    @Test func antsModeFollowsSelection() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            let bridge = harness.document.undoBridge
            #expect(antsMode(harness) == "hidden")

            harness.perform(NSSelectorFromString("selectAll:"))
            pumpMainRunLoop()
            #expect(antsMode(harness) == "animated",
                    "NSWorkspace Reduce Motion is off under the test runner")
            let dash = try #require(overlay(harness).dashLayer)
            #expect(dash.animation(forKey: "lineDashPhase") != nil, "the ants animate")
            #expect(dash.lineDashPattern?.map(\.doubleValue) == [4, 4])

            harness.perform(NSSelectorFromString("invertSelection:"))   // all → none
            pumpMainRunLoop()
            #expect(antsMode(harness) == "hidden")
            #expect(dash.path == nil, "hidden clears the path")

            bridge.undo()
            pumpMainRunLoop()
            #expect(antsMode(harness) == "animated", "undo brings the ants back")

            // Close and reopen: the fresh document starts without a selection.
            let url = harness.document.fileURL
            finish(harness)
            let reopened = try await DocumentHarness.open(try #require(url))
            defer { finish(reopened) }
            pumpMainRunLoop()
            #expect(antsMode(reopened) == "hidden")
        }
    }

    @Test func reduceMotionMakesAntsStatic() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            let ants = try overlay(harness)
            ants.reduceMotionOverride = true
            harness.perform(NSSelectorFromString("selectAll:"))
            pumpMainRunLoop()
            #expect(antsMode(harness) == "static")
            let dash = try #require(ants.dashLayer)
            #expect(dash.animation(forKey: "lineDashPhase") == nil, "NF-7: no animation")
            #expect(dash.path != nil, "the static ants still draw")
            ants.reduceMotionOverride = false
            #expect(ants.mode == .animated, "flipping back animates without a relaunch")
            #expect(dash.animation(forKey: "lineDashPhase") != nil)
        }
    }

    @Test func antsFollowZoom() async throws {
        // The `onTransformChange` hook re-renders the outline under the new transform
        // (0013 item 14c) — the path stays glued to the image border.
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            harness.perform(NSSelectorFromString("selectAll:"))
            pumpMainRunLoop()
            let dash = try #require(overlay(harness).dashLayer)
            let canvasRect = CGRect(x: 0, y: 0, width: 200, height: 200)

            let assertPathMatchesCanvasRect = { (label: String) throws in
                let transform = harness.canvasView.transform
                let box = try #require(dash.path, "ants path missing (\(label))")
                    .boundingBoxOfPath
                let expected = transform.canvasRectToView(canvasRect)
                #expect(abs(box.minX - expected.minX) < 1e-6 && abs(box.minY - expected.minY) < 1e-6
                        && abs(box.maxX - expected.maxX) < 1e-6 && abs(box.maxY - expected.maxY) < 1e-6,
                        "\(label): ants path \(box) vs image rect \(expected)")
            }
            try assertPathMatchesCanvasRect("initial zoom")

            let zoomBefore = harness.canvasView.transform.zoom
            harness.perform(NSSelectorFromString("zoomIn:"))
            pumpMainRunLoop()
            #expect(harness.canvasView.transform.zoom > zoomBefore, "zoomIn changed the zoom")
            try assertPathMatchesCanvasRect("after zoomIn")
        }
    }

    @Test func initialSelectionIsNotAStep() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            harness.windowController.setInitialSelection(
                PixelRect(x: 50, y: 50, width: 100, height: 100))
            pumpMainRunLoop()
            #expect(harness.document.undoBridge.state.selection?.bounds
                    == PixelRect(x: 50, y: 50, width: 100, height: 100))
            #expect(!harness.document.isDocumentEdited)
            #expect(harness.document.undoBridge.history.steps.count == 1)
            #expect(antsMode(harness) == "animated")
        }
    }

    // MARK: - Real pixels through the selection clip

    @Test func paintingIsClippedToSelection() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }
            let bridge = harness.document.undoBridge
            harness.windowController.setInitialSelection(
                PixelRect(x: 50, y: 50, width: 100, height: 100))
            #expect(harness.shortcut("b"))
            pumpMainRunLoop()
            harness.appModel.toolOptions.setValue(
                20.0, for: BrushOptions.keys(for: .paintbrush).width)

            // Horizontal stroke through canvas row 100 across the whole view.
            harness.dragCanvas(
                from: harness.viewPoint(forImagePoint: CGPoint(x: -30, y: 100)),
                to: harness.viewPoint(forImagePoint: CGPoint(x: 230, y: 100)),
                steps: 10)
            pumpMainRunLoop()
            var pixels = try await savedPixels(harness)
            let black = ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255)
            let white = ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255)
            #expect(pixels(100, 100) == black, "inside the selection")
            #expect(pixels(20, 100) == white, "before the selection")
            #expect(pixels(180, 100) == white, "past the selection")

            // Invert Selection, then a vertical stroke through canvas column 100.
            harness.perform(NSSelectorFromString("invertSelection:"))
            pumpMainRunLoop()
            harness.dragCanvas(
                from: harness.viewPoint(forImagePoint: CGPoint(x: 100, y: -30)),
                to: harness.viewPoint(forImagePoint: CGPoint(x: 100, y: 230)),
                steps: 10)
            pumpMainRunLoop()
            pixels = try await savedPixels(harness)
            #expect(pixels(100, 20) == black, "outside the old rect is now selected")
            #expect(pixels(100, 180) == black)
            #expect(pixels(100, 60) == white, "inside the old rect is now clipped")
            #expect(pixels(100, 100) == black, "the first stroke's pixels are untouched")
            #expect(bridge.state.selection != nil)
        }
    }

    /// Saves through the document (no sheet) and decodes the file's pixels.
    private func savedPixels(_ harness: DocumentHarness) async throws
        -> (Int, Int) -> ColorRGBA8
    {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests.selection.\(UUID().uuidString).png")
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
}
