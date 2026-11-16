import AppKit
import Testing

@testable import PaintDotMac

/// The Rectangle/Ellipse Select tools end to end (spec 0014 *Test plan*, headless):
/// documents through `DocumentHarness` (never shown), canvas input through synthesized
/// mouse events, keys through `harness.shortcut`, the status-bar selection size, the
/// options bar, and — for the scripted history test — a `FakeToolContext` behind the real
/// tools. Each test ends with `HeadlessAssertions.closeAllDocuments()` and
/// `noVisibleWindows()`. Fixtures are generated at test time.
@MainActor
@Suite(.serialized)
struct SelectionToolsIntegrationTests {
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

    private func resetUnit() {
        AppSettings().measurementUnit = .pixels
    }

    private func openFixture(_ fixtures: FixtureFiles, name: String, width: Int, height: Int,
                             rgba: (UInt8, UInt8, UInt8, UInt8)) async throws -> DocumentHarness {
        resetUnit()
        let url = try fixtures.writePNG(named: name, width: width, height: height,
                                        pixel: { _, _ in ColorRGBA8(red: rgba.0, green: rgba.1,
                                                                   blue: rgba.2, alpha: rgba.3) })
        let harness = try await DocumentHarness.open(url)
        harness.window.setContentSize(NSSize(width: 1000, height: 800))
        harness.document.undoBridge.undoManager.groupsByEvent = false
        harness.appModel.setActiveSession(harness.windowController.toolSession)
        pumpMainRunLoop()
        return harness
    }

    /// A drag the user could have taken longer than Paint.NET's 50 ms "too quick" window:
    /// the events are synthesized within microseconds of each other, so pump the run loop
    /// between the last drag and the release.
    private func selectDrag(_ harness: DocumentHarness, from start: CGPoint, to end: CGPoint,
                            modifiers: NSEvent.ModifierFlags = []) {
        harness.canvasPress(at: start, modifiers: modifiers)
        for step in 1...4 {
            let fraction = CGFloat(step) / 4
            harness.canvasDrag(to: CGPoint(x: start.x + (end.x - start.x) * fraction,
                                           y: start.y + (end.y - start.y) * fraction),
                               modifiers: modifiers)
        }
        pumpMainRunLoop(for: 0.08)
        harness.canvasRelease(at: end, modifiers: modifiers)
    }

    /// The options bar's accessibility identifiers visible in the window's content view.
    private func optionIdentifiers(_ harness: DocumentHarness) -> Set<String> {
        guard let content = harness.window.contentView else { return [] }
        pumpMainRunLoop()
        return AX.withAccessibilityClient { AX.identifiers(inRoot: content) }
    }

    private func optionValue(_ harness: DocumentHarness, identifier: String) -> String? {
        guard let content = harness.window.contentView else { return nil }
        pumpMainRunLoop()
        return AX.withAccessibilityClient {
            guard let item = AX.first(inRoot: content, identifier: identifier) else { return nil }
            return AX.value(of: item)
        }
    }

    // MARK: - Scripted history (FakeToolContext behind the real tools)

    /// The user story in one script: Rectangle, Ellipse ⌘, Rectangle ⌥, click-Deselect —
    /// then undo ×4, redo ×4 mask by mask, and a Paintbrush stroke through the restored
    /// selection, clipped.
    @Test func undoRedoRestoresMasks() {
        let context = FakeToolContext(size: PixelSize(width: 200, height: 150),
                                      background: .white)
        context.memoryOptions.setValue(20.0, for: BrushOptions.keys(for: .paintbrush).width)
        let rectTool = RectangleSelectTool()
        let ellipseTool = EllipseSelectTool()
        func event(_ x: Double, _ y: Double, _ t: TimeInterval,
                   modifiers: ToolModifiers = []) -> ToolEvent {
            ToolEvent(location: CGPoint(x: x, y: y), viewLocation: .zero, button: .primary,
                      modifiers: modifiers, clickCount: 1, pressure: 1, timestamp: t)
        }

        rectTool.mouseDown(event(10.4, 10.4, 1.0), context: context)
        rectTool.mouseDragged(event(59.4, 49.4, 1.2), context: context)
        rectTool.mouseUp(event(59.4, 49.4, 1.4), context: context)
        let maskAfterRect = context.selection?.mask
        ellipseTool.mouseDown(event(40.4, 30.4, 2.0, modifiers: [.command]), context: context)
        ellipseTool.mouseDragged(event(119.4, 89.4, 2.2, modifiers: [.command]), context: context)
        ellipseTool.mouseUp(event(119.4, 89.4, 2.4, modifiers: [.command]), context: context)
        let maskAfterEllipse = context.selection?.mask
        rectTool.mouseDown(event(0.4, 0.4, 3.0, modifiers: [.option]), context: context)
        rectTool.mouseDragged(event(29.4, 29.4, 3.2, modifiers: [.option]), context: context)
        rectTool.mouseUp(event(29.4, 29.4, 3.4, modifiers: [.option]), context: context)
        let maskAfterExclude = context.selection?.mask
        rectTool.mouseDown(event(150.5, 100.5, 4.0), context: context)
        rectTool.mouseUp(event(150.5, 100.5, 4.05), context: context)

        #expect(context.history.steps.map(\.name)
                    == ["New Image", "Rectangle Select", "Ellipse Select",
                        "Rectangle Select", "Deselect"])
        #expect(context.selection == nil)

        for _ in 0..<4 {
            context.navigateForTests { history, state in _ = history.undo(&state) }
        }
        #expect(context.selection == nil, "back to the base step")

        let redoMasks = [maskAfterRect, maskAfterEllipse, maskAfterExclude, nil]
        for mask in redoMasks {
            context.navigateForTests { history, state in _ = history.redo(&state) }
            #expect(context.selection?.mask == mask, "stepwise redo restores each mask")
        }

        // With the second-to-last selection active (after the ⌥ exclude), a Paintbrush
        // stroke across the canvas is clipped: (5,5) — excluded — stays white,
        // (45,20) — inside — is painted; (5,20) proves the clip bites mid-stroke.
        context.navigateForTests { history, state in _ = history.undo(&state) }
        #expect(context.selection?.mask == maskAfterExclude)
        let brush = PaintbrushTool()
        brush.mouseDown(event(-10, 20.5, 5.0), context: context)
        brush.mouseDragged(event(100, 20.5, 5.2), context: context)
        brush.mouseUp(event(210, 20.5, 5.4), context: context)
        let surface = context.state.image.layers[0].surface
        #expect(surface.pixel(at: PixelPoint(x: 5, y: 5)) == .white, "outside the selection")
        #expect(surface.pixel(at: PixelPoint(x: 5, y: 20)) == .white, "excluded corner")
        #expect(surface.pixel(at: PixelPoint(x: 45, y: 20)) == ColorRGBA8(red: 0, green: 0,
                                                                          blue: 0, alpha: 255),
                "inside the selection")
    }

    // MARK: - Window-level user stories

    @Test func sKeyCyclesSelectionTools() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "cycle.png",
                                                width: 200, height: 150, rgba: (255, 255, 255, 255))
            defer { finish(harness) }

            #expect(harness.shortcut("s"))
            #expect(harness.appModel.activeToolID == .rectangleSelect)
            #expect(harness.shortcut("s"))
            #expect(harness.appModel.activeToolID == .lassoSelect)
            #expect(harness.shortcut("s"))
            #expect(harness.appModel.activeToolID == .ellipseSelect)
            #expect(harness.shortcut("s"))
            #expect(harness.appModel.activeToolID == .rectangleSelect)

            let identifiers = optionIdentifiers(harness)
            #expect(identifiers.contains("toolOptions.selectionMode"))
            #expect(identifiers.contains("toolOptions.drawMode"), "Rectangle shows draw modes")
            #expect(optionValue(harness, identifier: "toolOptions.selectionMode") == "Replace")

            #expect(harness.shortcut("s"))   // → Lasso Select (0015 joined the group)
            #expect(harness.appModel.activeToolID == .lassoSelect)
            let lassoIdentifiers = optionIdentifiers(harness)
            #expect(lassoIdentifiers.contains("toolOptions.selectionMode"))
            #expect(!lassoIdentifiers.contains("toolOptions.drawMode"),
                    "Lasso has no draw-mode options")

            #expect(harness.shortcut("s"))   // → Ellipse Select
            #expect(harness.appModel.activeToolID == .ellipseSelect)
            let ellipseIdentifiers = optionIdentifiers(harness)
            #expect(ellipseIdentifiers.contains("toolOptions.selectionMode"))
            #expect(!ellipseIdentifiers.contains("toolOptions.drawMode"),
                    "Ellipse has no draw-mode options")
        }
    }

    @Test func rectangleSelectClipsPainting() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "gray.png",
                                                width: 4000, height: 2000, rgba: (128, 128, 128, 255))
            defer { finish(harness) }
            let manager = try #require(harness.window.undoManager)

            #expect(harness.shortcut("s"))
            selectDrag(harness,
                       from: harness.viewPoint(forImagePoint: CGPoint(x: 400.4, y: 800.4)),
                       to: harness.viewPoint(forImagePoint: CGPoint(x: 1600.4, y: 1200.4)))
            pumpMainRunLoop()
            let bridge = harness.document.undoBridge
            #expect(bridge.state.selection?.bounds
                        == PixelRect(x: 400, y: 800, width: 1201, height: 401))
            #expect(harness.appModel.historyPanel.model.rows.last?.name == "Rectangle Select")
            #expect(manager.undoMenuItemTitle == "Undo Rectangle Select")
            let sizeText = harness.statusBar.selectionSizeText
            let parts = sizeText.split(separator: " × ")
            #expect(parts.count == 2, "selection size text '\(sizeText)'")
            #expect((Int(parts.first ?? "") ?? 0) > 0, "W > 0 in '\(sizeText)'")
            #expect((Int(parts.last ?? "") ?? 0) > 0, "H > 0 in '\(sizeText)'")

            // Paintbrush width 20 across the vertical center: the paint lands exactly in
            // the selection.
            #expect(harness.shortcut("b"))
            harness.appModel.toolOptions.setValue(
                20.0, for: BrushOptions.keys(for: .paintbrush).width)
            harness.dragCanvas(
                from: harness.viewPoint(forImagePoint: CGPoint(x: 79.4, y: 1000.4)),
                to: harness.viewPoint(forImagePoint: CGPoint(x: 3920.4, y: 1000.4)),
                steps: 10)
            pumpMainRunLoop()

            let pixels = try await savedPixels(harness)
            let gray = ColorRGBA8(red: 128, green: 128, blue: 128, alpha: 255)
            let row = 1000
            var runStart: Int?
            var runLength = 0
            for x in 0..<4000 {
                if pixels(x, row) != gray {
                    if runStart == nil { runStart = x }
                    runLength += 1
                }
            }
            #expect(runLength == 1201, "exactly one run of W painted pixels")
            #expect(runStart == 400, "the run starts at the selection's left edge")
        }
    }

    @Test func ellipseSelectAddsStep() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "ellipse.png",
                                                width: 200, height: 150, rgba: (255, 255, 255, 255))
            defer { finish(harness) }

            #expect(harness.shortcut("s"))
            #expect(harness.shortcut("s"))   // Rectangle → Lasso → Ellipse (0015)
            #expect(harness.shortcut("s"))
            #expect(harness.appModel.activeToolID == .ellipseSelect)
            selectDrag(harness,
                       from: harness.viewPoint(forImagePoint: CGPoint(x: 30.4, y: 30.4)),
                       to: harness.viewPoint(forImagePoint: CGPoint(x: 90.4, y: 70.4)))
            pumpMainRunLoop()
            #expect(harness.appModel.historyPanel.model.rows.last?.name == "Ellipse Select")
            #expect(!harness.statusBar.selectionSizeText.isEmpty)

            harness.window.undoManager?.undo()
            pumpMainRunLoop()
            #expect(harness.statusBar.selectionSizeText == "", "undo clears the field")
            harness.window.undoManager?.redo()
            pumpMainRunLoop()
            #expect(!harness.statusBar.selectionSizeText.isEmpty, "redo restores it")
        }
    }

    @Test func commandDragAddsToSelection() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "union.png",
                                                width: 4000, height: 2000, rgba: (128, 128, 128, 255))
            defer { finish(harness) }

            #expect(harness.shortcut("s"))
            selectDrag(harness,
                       from: harness.viewPoint(forImagePoint: CGPoint(x: 400.4, y: 800.4)),
                       to: harness.viewPoint(forImagePoint: CGPoint(x: 800.4, y: 1000.4)))
            let firstWidth = harness.document.undoBridge.state.selection?.bounds.width
            selectDrag(harness,
                       from: harness.viewPoint(forImagePoint: CGPoint(x: 2400.4, y: 800.4)),
                       to: harness.viewPoint(forImagePoint: CGPoint(x: 2800.4, y: 1000.4)),
                       modifiers: .command)
            pumpMainRunLoop()
            #expect(harness.appModel.historyPanel.model.rows.suffix(2).map(\.name)
                        == ["Rectangle Select", "Rectangle Select"])
            let unionBounds = try #require(harness.document.undoBridge.state.selection?.bounds)
            #expect(unionBounds.width > 4 * (firstWidth ?? 0),
                    "bounding box of both drags: \(unionBounds.width) vs \(firstWidth ?? 0)")
        }
    }

    @Test func clickDeselects() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "click.png",
                                                width: 200, height: 150, rgba: (255, 255, 255, 255))
            defer { finish(harness) }

            #expect(harness.shortcut("s"))
            selectDrag(harness,
                       from: harness.viewPoint(forImagePoint: CGPoint(x: 30.4, y: 30.4)),
                       to: harness.viewPoint(forImagePoint: CGPoint(x: 90.4, y: 70.4)))
            pumpMainRunLoop()
            #expect(!harness.statusBar.selectionSizeText.isEmpty)

            harness.clickCanvas(at: harness.viewPoint(forImagePoint: CGPoint(x: 180.5, y: 130.5)))
            pumpMainRunLoop()
            #expect(harness.appModel.historyPanel.model.rows.last?.name == "Deselect")
            #expect(harness.statusBar.selectionSizeText == "")
            #expect(harness.document.undoBridge.state.selection == nil)
        }
    }

    @Test func fixedSizeSelection() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "fixed.png",
                                                width: 4000, height: 2000, rgba: (128, 128, 128, 255))
            defer { finish(harness) }

            #expect(harness.shortcut("s"))
            let options = harness.appModel.toolOptions
            options.setValue(SelectionDrawMode.fixedSize, for: SelectionToolOptions.drawMode)
            options.setValue(MeasurementUnit.pixels, for: SelectionToolOptions.fixedUnit)
            options.setValue(100.0, for: SelectionToolOptions.fixedWidth)
            options.setValue(50.0, for: SelectionToolOptions.fixedHeight)

            // Live while dragging: the preview's size is in the status bar.
            let start = harness.viewPoint(forImagePoint: CGPoint(x: 1200.4, y: 600.4))
            let end = harness.viewPoint(forImagePoint: CGPoint(x: 1400.4, y: 700.4))
            harness.canvasPress(at: start)
            harness.canvasDrag(to: end)
            pumpMainRunLoop()
            #expect(harness.statusBar.selectionSizeText == "100 × 50",
                    "live preview size in the status bar")
            harness.canvasRelease(at: end)
            pumpMainRunLoop()
            #expect(harness.statusBar.selectionSizeText == "100 × 50")
            #expect(harness.document.undoBridge.state.selection?.bounds
                        == PixelRect(x: 1400, y: 700, width: 100, height: 50))
        }
    }

    @Test func optionsPersistAndAreShared() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "persist.png",
                                                width: 200, height: 150, rgba: (255, 255, 255, 255))
            defer { finish(harness) }

            // Ellipse Select sets the shared mode and clipping (the same writes the
            // SwiftUI pickers make), plus the Rectangle-only draw mode.
            #expect(harness.shortcut("s"))
            #expect(harness.shortcut("s"))   // Rectangle → Lasso → Ellipse (0015)
            #expect(harness.shortcut("s"))
            let options = harness.appModel.toolOptions
            options.setValue(SelectionCombineMode.exclude, for: SelectionToolOptions.combineMode)
            options.setValue(SelectionQuality.pixelated, for: SelectionToolOptions.quality)
            options.setValue(SelectionDrawMode.fixedSize, for: SelectionToolOptions.drawMode)
            options.setValue(MeasurementUnit.pixels, for: SelectionToolOptions.fixedUnit)
            options.setValue(100.0, for: SelectionToolOptions.fixedWidth)
            options.setValue(50.0, for: SelectionToolOptions.fixedHeight)

            #expect(harness.shortcut("s"))   // back to Rectangle Select
            pumpMainRunLoop()
            #expect(harness.appModel.activeToolID == .rectangleSelect)
            #expect(optionValue(harness, identifier: "toolOptions.selectionMode") == "Subtract")
            #expect(optionValue(harness, identifier: "toolOptions.selectionQuality") == "Pixelated")

            // A fresh AppModel on the same suite is what a relaunch reads (TOOL-C).
            let relaunched = AppModel(defaults: harness.appModel.defaultsForTests)
            #expect(relaunched.toolOptions.value(SelectionToolOptions.combineMode) == .exclude)
            #expect(relaunched.toolOptions.value(SelectionToolOptions.quality) == .pixelated)
            #expect(relaunched.toolOptions.value(SelectionToolOptions.drawMode) == .fixedSize)
            #expect(relaunched.toolOptions.value(SelectionToolOptions.fixedUnit) == .pixels)
            #expect(relaunched.toolOptions.value(SelectionToolOptions.fixedWidth) == 100)
            #expect(relaunched.toolOptions.value(SelectionToolOptions.fixedHeight) == 50)
        }
    }

    /// Replace-drag hides the current selection's ants for the preview's duration, and
    /// Escape restores them without a step (manual check 5; 0013's ants contract). The
    /// Reduce Motion override pins the marching mode to the deterministic `.static`.
    @Test func replacePreviewHidesAntsAndEscapeRestores() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "antspreview.png",
                                                width: 200, height: 150, rgba: (255, 255, 255, 255))
            defer { finish(harness) }
            let ants = try #require(harness.windowController.marchingAntsOverlay)
            ants.reduceMotionOverride = true
            defer { ants.reduceMotionOverride = false }

            #expect(harness.shortcut("s"))
            selectDrag(harness,
                       from: harness.viewPoint(forImagePoint: CGPoint(x: 30.4, y: 30.4)),
                       to: harness.viewPoint(forImagePoint: CGPoint(x: 90.4, y: 70.4)))
            pumpMainRunLoop()
            #expect(ants.mode == .static, "the committed selection shows its ants")

            let start = harness.viewPoint(forImagePoint: CGPoint(x: 120.4, y: 20.4))
            let end = harness.viewPoint(forImagePoint: CGPoint(x: 160.4, y: 60.4))
            harness.canvasPress(at: start)
            harness.canvasDrag(to: end)
            pumpMainRunLoop()
            #expect(ants.mode == .hidden, "a Replace preview hides the current ants")
            #expect(harness.document.undoBridge.state.selection?.bounds
                        == PixelRect(x: 30, y: 30, width: 61, height: 41),
                    "the selection itself survives the Replace drag")

            harness.window.makeFirstResponder(harness.canvasView)
            harness.keyDown("\u{1b}", keyCode: 53)
            harness.keyUp("\u{1b}", keyCode: 53)
            pumpMainRunLoop()
            #expect(ants.mode == .static, "Escape brings the old ants back")
            #expect(harness.appModel.historyPanel.model.rows.map(\.name)
                        == ["Open Image", "Rectangle Select"], "Escape records no step")

            // The button is still down: the dispatcher swallows events until the matching
            // release (0006), which only ends the cancelled gesture.
            harness.canvasRelease(at: end)
            pumpMainRunLoop()
            #expect(harness.appModel.historyPanel.model.rows.map(\.name)
                        == ["Open Image", "Rectangle Select"],
                    "the release of a cancelled gesture commits nothing")

            // Releasing a Replace drag commits and the new selection shows its ants.
            harness.canvasPress(at: start)
            harness.canvasDrag(to: end)
            pumpMainRunLoop(for: 0.08)
            harness.canvasRelease(at: end)
            pumpMainRunLoop()
            #expect(ants.mode == .static, "the new selection's ants return on release")
            #expect(harness.appModel.historyPanel.model.rows.map(\.name)
                        == ["Open Image", "Rectangle Select", "Rectangle Select"])
            #expect(harness.document.undoBridge.state.selection?.bounds
                        == PixelRect(x: 120, y: 20, width: 41, height: 41))
        }
    }

    @Test func zoomToSelection() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "zoomsel.png",
                                                width: 200, height: 150, rgba: (255, 255, 255, 255))
            defer { finish(harness) }

            #expect(!harness.isEnabled(MainMenu.zoomToSelectionAction),
                    "disabled with no selection (D-44b)")
            #expect(harness.shortcut("s"))
            selectDrag(harness,
                       from: harness.viewPoint(forImagePoint: CGPoint(x: 20.4, y: 20.4)),
                       to: harness.viewPoint(forImagePoint: CGPoint(x: 30.4, y: 30.4)))
            pumpMainRunLoop()
            #expect(harness.isEnabled(MainMenu.zoomToSelectionAction))

            let zoomBefore = harness.canvasView.transform.zoom
            harness.perform(MainMenu.zoomToSelectionAction)
            pumpMainRunLoop()
            #expect(harness.canvasView.transform.zoom > zoomBefore, "zoomed into the selection")
            #expect(harness.statusBar.zoomText == "3200%",
                    "an 11 × 11 selection fits no larger than 3200 %")

            // Deselect → disabled again.
            harness.perform(NSSelectorFromString("deselect:"))
            pumpMainRunLoop()
            #expect(!harness.isEnabled(MainMenu.zoomToSelectionAction))
        }
    }

    /// Saves through the document (no sheet) and decodes the file's pixels.
    private func savedPixels(_ harness: DocumentHarness) async throws
        -> (Int, Int) -> ColorRGBA8
    {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests.0014.\(UUID().uuidString).png")
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
