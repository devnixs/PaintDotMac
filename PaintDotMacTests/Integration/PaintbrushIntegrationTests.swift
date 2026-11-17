import AppKit
import Foundation
import Testing

@testable import PaintDotMac

/// The Paintbrush end-to-end (spec 0009 *Test plan*), headless. Part 1 drives a real
/// `UndoBridge` + `ToolDispatcher` through `ToolContext` doubles (history, edited state,
/// the save/undo commit hooks). Part 2 drives the real document window with synthesized
/// mouse/key events through `CanvasInputRouter`, and reads pixels back from the saved PNG.
@MainActor
@Suite(.serialized)
struct PaintbrushIntegrationTests {
    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    private func pixel(_ image: LayeredImage, _ x: Int, _ y: Int) -> ColorRGBA8 {
        image.layers[0].surface.pixel(at: PixelPoint(x: x, y: y))
    }

    // MARK: - Part 1 — bridge/session doubles

    /// A `ToolContext` forwarding `updateImage`/`commitHistory` to a real `UndoBridge`
    /// (base `.newImage`, `groupsByEvent = false` per 0008's test convention).
    private final class BridgeSessionContext: ToolContext {
        let bridge: UndoBridge
        let nav = FakeCanvasNavigation()
        var navigation: any CanvasNavigating { nav }
        let memoryOptions = InMemoryToolOptionStore()
        var options: any ToolOptionStore { memoryOptions }
        var colors: ColorSelection = .default
        var paintClipMask: (any BrushClipMask)?
        var selection: Selection?
        var previousToolID: ToolID?
        var editedChanges: [Bool] = []
        var floatingPixels: FloatingPixels? { bridge.state.floatingPixels }
        var history: HistoryStack { bridge.history }
        func jumpHistory(to index: Int) { bridge.jump(to: index) }
        var image: LayeredImage { bridge.state.image }
        var transform: CanvasTransform { nav.transform }

        init(size: PixelSize) {
            let surface = TiledSurface(size: size)
            var filled = surface
            filled.fill(.white)
            bridge = UndoBridge(state: DocumentState(image: LayeredImage(surface: filled)),
                                base: .newImage,
                                budgetBytes: HistoryStack.defaultBudgetBytes,
                                undoManager: NavigationUndoManager())
            bridge.undoManager.groupsByEvent = false
            bridge.onEditedChange = { [weak self] edited in
                self?.editedChanges.append(edited)
            }
        }

        func activateTool(_ id: ToolID) {}
        func setColor(_ color: ColorRGBA8, for slot: ColorSlot) { colors[slot] = color }
        func setOverlay(_ overlay: ToolOverlay?) {}
        func invalidateCursor() {}
        func commitHistory(_ item: any HistoryItem) { bridge.commit(item) }
        func performHistory(_ item: any HistoryItem) { bridge.perform(item) }
        func updateImage(_ body: (inout LayeredImage) -> Void) {
            bridge.updateLiveState { state in body(&state.image) }
        }
    }

    private func pointer(_ button: ToolPhysicalButton, _ location: CGPoint,
                         modifiers: ToolModifiers = []) -> ToolPointerInput {
        ToolPointerInput(physicalButton: button, location: location, viewLocation: location,
                         modifiers: modifiers, clickCount: 1, pressure: 1, timestamp: 0)
    }

    private func event(_ location: CGPoint, button: ToolMouseButton = .primary,
                       modifiers: ToolModifiers = []) -> ToolEvent {
        ToolEvent(location: location, viewLocation: location, button: button,
                  modifiers: modifiers, clickCount: 1, pressure: 1, timestamp: 0)
    }

    @Test func strokeIsOneUndoableStep() {
        let context = BridgeSessionContext(size: PixelSize(width: 800, height: 600))
        let tool = PaintbrushTool()
        tool.mouseDown(event(CGPoint(x: 300, y: 300)), context: context)
        tool.mouseDragged(event(CGPoint(x: 360, y: 320)), context: context)
        tool.mouseDragged(event(CGPoint(x: 420, y: 300)), context: context)
        tool.mouseUp(event(CGPoint(x: 480, y: 310)), context: context)
        #expect(context.bridge.history.steps.map(\.name) == ["New Image", "Paintbrush"])
        #expect(pixel(context.image, 390, 308).alpha == 255, "a pixel at the stroke middle")
        context.bridge.undo()
        #expect(pixel(context.image, 390, 308) == .white)
        #expect(context.bridge.history.currentIndex == 0)
        context.bridge.redo()
        #expect(pixel(context.image, 390, 308).alpha == 255)
    }

    @Test func noOpStrokeAddsNoHistory() {
        let context = BridgeSessionContext(size: PixelSize(width: 800, height: 600))
        let tool = PaintbrushTool()
        // Fully off-canvas.
        tool.mouseDown(event(CGPoint(x: -4000, y: -4000)), context: context)
        tool.mouseDragged(event(CGPoint(x: -3900, y: -3900)), context: context)
        tool.mouseUp(event(CGPoint(x: -3800, y: -3800)), context: context)
        // Alpha-0 color on-canvas.
        context.colors = ColorSelection(primary: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 0),
                                        secondary: .white)
        tool.mouseDown(event(CGPoint(x: 100, y: 100)), context: context)
        tool.mouseDragged(event(CGPoint(x: 200, y: 150)), context: context)
        tool.mouseUp(event(CGPoint(x: 300, y: 100)), context: context)
        #expect(context.bridge.history.steps.map(\.name) == ["New Image"])
        #expect(!context.bridge.history.canUndo)
    }

    @Test func diffContainsOnlyChangedTiles() throws {
        let context = BridgeSessionContext(size: PixelSize(width: 800, height: 600))
        let tool = PaintbrushTool()
        context.options.setValue(6.0, for: BrushOptions.keys(for: .paintbrush).width)
        // A short stroke wholly inside tile (0,0).
        tool.mouseDown(event(CGPoint(x: 20, y: 20)), context: context)
        tool.mouseDragged(event(CGPoint(x: 40, y: 30)), context: context)
        tool.mouseUp(event(CGPoint(x: 60, y: 20)), context: context)
        let step = try #require(context.bridge.history.undoStep)
        let item = try #require(step.item as? TileDiffHistoryItem)
        #expect(item.diff.entries.count == 1, "one changed tile for a short stroke")
        #expect(Set(item.diff.entries.map(\.coordinate)) == [TileCoordinate(column: 0, row: 0)])
        let oneTileCost = 2 * HistoryCost.tileBytes(Tile()) + HistoryCost.stepOverheadBytes
        #expect(context.bridge.history.totalBytes == oneTileCost,
                "NF-4 byte cost = before+after of the one tile + step overhead")

        // A stroke across x = 256 touches exactly two tiles.
        let second = PaintbrushTool()
        second.mouseDown(event(CGPoint(x: 246, y: 100)), context: context)
        second.mouseDragged(event(CGPoint(x: 266, y: 100)), context: context)
        second.mouseUp(event(CGPoint(x: 266, y: 101)), context: context)
        let step2 = try #require(context.bridge.history.steps.last?.item as? TileDiffHistoryItem)
        #expect(Set(step2.diff.entries.map(\.coordinate))
                    == Set([TileCoordinate(column: 0, row: 0), TileCoordinate(column: 1, row: 0)]),
                "exactly the two tiles the stroke crosses")
    }

    @Test func rightClickStrokeUsesSecondary() {
        let context = BridgeSessionContext(size: PixelSize(width: 800, height: 600))
        context.colors = ColorSelection(primary: .black, secondary: ColorRGBA8(red: 255, green: 0, blue: 0))
        // Width 20 so the drag leaves a fully opaque core well clear of the AA rim.
        context.memoryOptions.setStoredValue(20.0, forKey: BrushOptions.keys(for: .paintbrush).width.defaultsKey)
        let dispatcher = ToolDispatcher(registry: .standard())
        dispatcher.setContext(context)
        dispatcher.pointerDown(pointer(.right, CGPoint(x: 100, y: 120)))
        dispatcher.pointerDragged(pointer(.right, CGPoint(x: 180, y: 120)))
        dispatcher.pointerUp(pointer(.right, CGPoint(x: 240, y: 120)))
        #expect(pixel(context.image, 170, 120) == ColorRGBA8(red: 255, green: 0, blue: 0))
        #expect(context.bridge.history.steps.map(\.name) == ["New Image", "Paintbrush"])
    }

    @Test func undoDuringStrokeCommitsFirst() throws {
        let context = BridgeSessionContext(size: PixelSize(width: 800, height: 600))
        let dispatcher = ToolDispatcher(registry: .standard())
        dispatcher.setContext(context)
        // 0008's `DocumentWindowController` wiring: navigation commits the pending stroke.
        context.bridge.prepareForNavigation = { dispatcher.commitPendingEdit() }
        let blank = context.image

        dispatcher.pointerDown(pointer(.left, CGPoint(x: 120, y: 120)))
        dispatcher.pointerDragged(pointer(.left, CGPoint(x: 200, y: 160)))
        dispatcher.pointerDragged(pointer(.left, CGPoint(x: 280, y: 120)))
        context.bridge.undo()   // → prepareForNavigation → commit → undo of that step

        #expect(context.bridge.history.steps.map(\.name) == ["New Image", "Paintbrush"])
        #expect(context.bridge.history.currentIndex == 0)
        assertMatches(context.image, ReferenceCanvas(image: blank),
                      "undo-after-commit equals the blank image")
        #expect(context.bridge.history.redoStep?.name == "Paintbrush")
        context.bridge.redo()
        #expect(pixel(context.image, 200, 158).alpha == 255, "redo brings the stroke back")
    }

    @Test func saveCommitsPendingStroke() {
        let context = BridgeSessionContext(size: PixelSize(width: 800, height: 600))
        let dispatcher = ToolDispatcher(registry: .standard())
        dispatcher.setContext(context)
        dispatcher.pointerDown(pointer(.left, CGPoint(x: 100, y: 400)))
        dispatcher.pointerDragged(pointer(.left, CGPoint(x: 200, y: 420)))
        dispatcher.commitPendingEdit()   // what PaintDocument.save runs first
        #expect(context.bridge.history.steps.map(\.name) == ["New Image", "Paintbrush"])
        #expect(!dispatcher.hasPendingEdit)
        // The still-pending mouse-up after the commit adds no second step.
        dispatcher.pointerUp(pointer(.left, CGPoint(x: 220, y: 410)))
        #expect(context.bridge.history.steps.count == 2)
    }

    @Test func editedStateFollowsHistory() throws {
        let context = BridgeSessionContext(size: PixelSize(width: 400, height: 400))
        let tool = PaintbrushTool()
        tool.mouseDown(event(CGPoint(x: 80, y: 80)), context: context)
        tool.mouseDragged(event(CGPoint(x: 160, y: 120)), context: context)
        tool.mouseUp(event(CGPoint(x: 240, y: 80)), context: context)
        #expect(context.editedChanges.last == true, "a real edit dirties the document")
        context.bridge.undo()
        #expect(context.editedChanges.last == false, "back at the base step = saved state")
        context.bridge.redo()
        #expect(context.editedChanges.last == true)
    }

    // MARK: - Part 2 — the real window, synthesized events

    private func openGrayFixture(_ fixtures: FixtureFiles) async throws -> DocumentHarness {
        let url = try fixtures.writePNG(named: "brush-fixture.png", width: 300, height: 200) { _, _ in
            ColorRGBA8(red: 128, green: 128, blue: 128, alpha: 255)
        }
        let harness = try await DocumentHarness.open(url)
        harness.window.setContentSize(NSSize(width: 1000, height: 800))
        return harness
    }

    private func newWhiteHarness() -> DocumentHarness? {
        DocumentHarness.newImage(presenter: ScriptedNewImagePresenter(steps: [.ok]),
                                 pasteboard: makePrivatePasteboard())
    }

    private func finish(_ harness: DocumentHarness) {
        harness.close()
        harness.discardAppModelSuite()
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    /// View-space points along a horizontal canvas-space segment (the harness drag
    /// helpers take view points; the window opens at fit zoom, so compute from the
    /// live transform instead of assuming 100 %).
    private func viewSegment(_ harness: DocumentHarness, canvasY: Int,
                             fromX: Int, toX: Int) -> (CGPoint, CGPoint) {
        let t = harness.canvasView.transform
        return (t.canvasToView(CGPoint(x: Double(fromX), y: Double(canvasY))),
                t.canvasToView(CGPoint(x: Double(toX), y: Double(canvasY))))
    }

    /// Saves through the document (no sheet) and decodes the file's pixels.
    private func savedPixels(_ harness: DocumentHarness) async throws -> (Int, Int) -> ColorRGBA8 {
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

    /// The window content view's accessibility values, with the client flag on.
    private func optionValues(_ harness: DocumentHarness) -> [String: String?] {
        guard let content = harness.window.contentView else { return [:] }
        return AX.withAccessibilityClient {
            var values: [String: String?] = [:]
            for id in ["toolOptions.width", "toolOptions.hardness", "toolOptions.antialiasing"] {
                values[id] = AX.first(inRoot: content, identifier: id).map { AX.value(of: $0) }
            }
            values["toolOptions.blendMode"] =
                AX.first(inRoot: content, identifier: "toolOptions.blendMode").map { AX.value(of: $0) }
            return values
        }
    }

    private func identifiers(_ harness: DocumentHarness) -> Set<String> {
        guard let content = harness.window.contentView else { return [] }
        return AX.withAccessibilityClient { AX.identifiers(inRoot: content) }
    }

    @Test func pressingBSelectsPaintbrushAndShowsOptions() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openGrayFixture(fixtures)
            defer { finish(harness) }

            #expect(harness.shortcut("b"))
            #expect(harness.appModel.activeToolID == .paintbrush)
            let values = optionValues(harness)
            #expect(values["toolOptions.width"] == .some("2"))
            #expect(values["toolOptions.hardness"] == .some("75%"))
            let toggle = (values["toolOptions.antialiasing"] ?? "") ?? ""
            #expect(toggle == "1" || toggle.lowercased() == "on" || toggle == "checked"
                        || toggle.isEmpty, "antialiasing on (value \(toggle))")
            #expect(values["toolOptions.blendMode"] == .some("Normal"))
            let identifiers = identifiers(harness)
            for id in ["toolOptions.width", "toolOptions.hardness", "toolOptions.antialiasing",
                       "toolOptions.blendMode", "toolOptions.width.decrease",
                       "toolOptions.width.increase"] {
                #expect(identifiers.contains(id), "accessibility element \(id)")
            }
        }
    }

    @Test func paintUndoRedoSavesAndDecodes() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openGrayFixture(fixtures)
            defer { finish(harness) }
            #expect(harness.appModel.activeToolID == .paintbrush, "D-35 start tool")

            harness.appModel.toolOptions.setValue(
                20.0, for: BrushOptions.keys(for: .paintbrush).width)
            let (from, to) = viewSegment(harness, canvasY: 100, fromX: 90, toX: 310)
            harness.dragCanvas(from: from, to: to, steps: 12)

            let manager = try #require(harness.window.undoManager)
            #expect(manager.undoMenuItemTitle == "Undo Paintbrush")
            #expect(harness.isEnabled(NSSelectorFromString("undo:")))
            var pixels = try await savedPixels(harness)
            #expect(pixels(200, 100) == .black,
                    "the stroke center is painted black in the saved file")
            #expect(pixels(2, 2) == ColorRGBA8(red: 128, green: 128, blue: 128, alpha: 255),
                    "untouched pixels keep the fixture gray")

            harness.perform(NSSelectorFromString("undo:"))
            #expect(harness.window.undoManager?.redoMenuItemTitle == "Redo Paintbrush")
            pixels = try await savedPixels(harness)
            #expect(pixels(200, 100) == ColorRGBA8(red: 128, green: 128, blue: 128, alpha: 255),
                    "after undo the file is the fixture again")
        }
    }

    @Test func updateImageRequestsCanvasRedraw() {
        // Spec 0009 *Display*: every `CanvasToolSession.updateImage` requests a canvas
        // redraw. `CanvasView` draws on demand (`isPaused` + `enableSetNeedsDisplay`);
        // without the request a live stroke would only appear at commit (mouse-up) or the
        // next transform change. Windowless view (created, never added to a window);
        // the count is read through `CanvasView.redrawRequests` because AppKit's
        // `needsDisplay` getter is not observable for never-displayed views.
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let navigation = CanvasNavigation(
            canvasView: canvas,
            statusBar: StatusBarModel(imageSize: PixelSize(width: 64, height: 64), dpi: 72)
        )
        let overlay = ToolOverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let suiteName = "PaintDotMacTests.redraw.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let session = CanvasToolSession(canvasView: canvas, navigation: navigation,
                                        overlayView: overlay, model: AppModel(defaults: suite))
        var surface = TiledSurface(size: PixelSize(width: 64, height: 64))
        surface.fill(.white)
        let bridge = UndoBridge(state: DocumentState(image: LayeredImage(surface: surface)),
                                base: .newImage,
                                budgetBytes: HistoryStack.defaultBudgetBytes,
                                undoManager: NavigationUndoManager())
        session.attachUndoBridge(bridge)

        let tool = PaintbrushTool()
        let baseline = canvas.redrawRequests
        tool.mouseDown(event(CGPoint(x: 32, y: 32)), context: session)
        #expect(canvas.redrawRequests == baseline + 1,
                "the mouse-down `updateImage` requests exactly one canvas redraw")
        tool.mouseDragged(event(CGPoint(x: 40, y: 36)), context: session)
        #expect(canvas.redrawRequests == baseline + 2,
                "each drag segment requests its redraw — the stroke follows the pointer")
        tool.mouseUp(event(CGPoint(x: 48, y: 32)), context: session)
        #expect(canvas.redrawRequests == baseline + 3, "the mouse-up extension requests one")
        #expect(bridge.history.steps.map(\.name) == ["New Image", "Paintbrush"],
                "the stroke still commits exactly one step")
    }

    @Test func rightDragPaintsSecondary() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openGrayFixture(fixtures)
            defer { finish(harness) }
            harness.appModel.toolOptions.setValue(
                20.0, for: BrushOptions.keys(for: .paintbrush).width)
            let (from, to) = viewSegment(harness, canvasY: 100, fromX: 80, toX: 220)
            harness.dragCanvas(from: from, to: to, steps: 8, button: .right)
            let pixels = try await savedPixels(harness)
            #expect(pixels(150, 100) == ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255),
                    "right-drag paints the secondary color (default secondary: white)")
        }
    }

    @Test func controlDragPaintsSecondary() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openGrayFixture(fixtures)
            defer { finish(harness) }
            harness.appModel.toolOptions.setValue(
                20.0, for: BrushOptions.keys(for: .paintbrush).width)
            let canvas = harness.canvasView
            let center = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
            let (from, to) = viewSegment(harness, canvasY: 100, fromX: 80, toX: 220)
            harness.dragCanvas(from: from, to: to, steps: 8, modifiers: [.control])
            let pixels = try await savedPixels(harness)
            #expect(pixels(150, 100) == ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255),
                    "Control-drag paints the secondary color (default secondary: white)")
            // No context menu appears for the canvas during the control-drag.
            let down = harness.mouse(.leftMouseDown,
                                     at: canvas.convert(center, to: nil))
            #expect(canvas.menu(for: down) == nil, "no context menu for Control-left")
        }
    }

    @Test func bracketKeysChangeWidth() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openGrayFixture(fixtures)
            defer { finish(harness) }
            #expect(harness.shortcut("b"))
            // Real key routing needs the canvas focused, which happens on the first click;
            // the click also installs the window's session on the dispatcher.
            harness.clickCanvas(at: .zero)
            let widthKey = BrushOptions.keys(for: .paintbrush).width
            for _ in 0..<3 { #expect(harness.shortcut("]")) }
            #expect(harness.appModel.toolOptions.value(widthKey) == 5)
            pumpMainRunLoop()
            #expect(optionValues(harness)["toolOptions.width"] == .some("5"))
            for _ in 0..<10 { #expect(harness.shortcut("[")) }
            #expect(harness.appModel.toolOptions.value(widthKey) == 1, "clamped at 1")
        }
    }

    @Test func brushWidthPersistsForNewModel() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openGrayFixture(fixtures)
            defer { finish(harness) }
            #expect(harness.shortcut("b"))
            harness.appModel.toolOptions.setValue(33.0,
                                                  for: BrushOptions.keys(for: .paintbrush).width)
            // A new AppModel on the same suite is what a relaunch reads.
            let relaunched = AppModel(defaults: harness.appModel.defaultsForTests)
            #expect(relaunched.toolOptions.value(BrushOptions.keys(for: .paintbrush).width) == 33)
        }
    }

    @Test func newAppModelStartsWithPaintbrush() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openGrayFixture(fixtures)
            defer { finish(harness) }
            #expect(harness.appModel.activeToolID == .paintbrush,
                    "D-35: a fresh model starts on the Paintbrush without any key")
            harness.appModel.selectTool(.pan)
            #expect(harness.appModel.activeToolID == .pan)
            let relaunched = AppModel(defaults: harness.appModel.defaultsForTests)
            #expect(relaunched.activeToolID == .paintbrush, "the active tool is not remembered")
        }
    }

    // MARK: - Edited state after a real edit (APP-9 / D-30)

    @Test func strokeMarksNewImageEdited() async throws {
        try await TestRunGate.withLock {
            defer { cleanup() }
            let harness = try #require(newWhiteHarness())
            defer { finish(harness) }
            let (from, to) = viewSegment(harness, canvasY: 100, fromX: 100, toX: 300)
            harness.dragCanvas(from: from, to: to, steps: 8)
            #expect(harness.document.isDocumentEdited,
                    "a real edit dirties the document (so ⌘W/⌘Q prompt)")
            #expect(harness.window.undoManager?.undoMenuItemTitle == "Undo Paintbrush")
        }
    }

    @Test func undoToCleanIsNotEdited() async throws {
        try await TestRunGate.withLock {
            defer { cleanup() }
            let harness = try #require(newWhiteHarness())
            defer { finish(harness) }
            let (from, to) = viewSegment(harness, canvasY: 100, fromX: 100, toX: 300)
            harness.dragCanvas(from: from, to: to, steps: 8)
            #expect(harness.document.isDocumentEdited)
            harness.perform(NSSelectorFromString("undo:"))
            #expect(!harness.document.isDocumentEdited,
                    "back at the base step the document is clean (⌘W closes without a prompt)")
        }
    }
}
