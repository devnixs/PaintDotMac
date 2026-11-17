import AppKit
import Foundation
import Testing

@testable import PaintDotMac

/// Full workflow through the real `UndoBridge` + `BridgeToolContext` + real tools
/// (spec 0024 L-1/D-51 integration): every paint path targets the ACTIVE layer, the
/// color picker's Image mode reads the composite, undo keeps the active layer (H-6),
/// layer commands finish floating pixels first, selections survive every layer
/// operation, and a whole session replays exactly.
@MainActor
@Suite(.serialized)
struct LayerWorkflowIntegrationTests {
    // MARK: - Helpers

    private func context(width: Int = 300, height: Int = 300) -> BridgeToolContext {
        let context = BridgeToolContext(size: PixelSize(width: width, height: height),
                                        base: .newImage,
                                        budgetBytes: HistoryStack.defaultBudgetBytes)
        context.nav.transform = CanvasTransform(
            imageSize: PixelSize(width: width, height: height),
            viewSize: CGSize(width: width, height: height),
            backingScale: 1, zoom: 1,
            center: CGPoint(x: Double(width) / 2, y: Double(height) / 2))
        // Headless steps have no NSEvent boundaries; without this the undo manager
        // coalesces every `perform` into one event group (the window tests do the same).
        context.bridge.undoManager.groupsByEvent = false
        return context
    }

    private func event(_ context: BridgeToolContext, _ x: Double, _ y: Double,
                       seed: Int = 0) -> ToolEvent {
        let location = CGPoint(x: x, y: y)
        return ToolEvent(location: location,
                         viewLocation: context.transform.canvasToView(location),
                         button: .primary, modifiers: [],
                         clickCount: 1, pressure: 1, timestamp: Double(seed + 1))
    }

    private func names(_ context: BridgeToolContext) -> [String] {
        context.bridge.history.steps.map(\.name)
    }

    /// The window controller's wiring (0020 item 9): navigation resolves the pending
    /// edit through the dispatcher.
    private func wireDispatcher(_ context: BridgeToolContext) -> ToolDispatcher {
        let dispatcher = ToolDispatcher(registry: .standard())
        dispatcher.setContext(context)
        context.dispatcher = dispatcher
        context.bridge.prepareForNavigation = { [weak dispatcher, weak context] in
            guard let dispatcher, let context else { return }
            dispatcher.resolvePendingEdit(for: context.bridge.pendingEditReason)
        }
        return dispatcher
    }

    private func moveTool(_ dispatcher: ToolDispatcher) throws -> MoveSelectedPixelsTool {
        #expect(dispatcher.selectTool(.moveSelectedPixels))
        return try #require(dispatcher.activeTool as? MoveSelectedPixelsTool)
    }

    private func paintStroke(_ context: BridgeToolContext, from: CGPoint, to: CGPoint) {
        let tool = PaintbrushTool()
        tool.mouseDown(event(context, from.x, from.y), context: context)
        tool.mouseDragged(event(context, to.x, to.y, seed: 1), context: context)
        tool.mouseUp(event(context, to.x, to.y, seed: 2), context: context)
    }

    private func pixel(_ image: LayeredImage, _ layer: Int, _ x: Int, _ y: Int) -> ColorRGBA8 {
        image.layers[layer].surface.pixel(at: PixelPoint(x: x, y: y))
    }

    /// Lift a selection and move it +5 px in x; ends with a "Move Pixels" step and the
    /// pixels floating (0020). Returns the dispatcher so the caller keeps it alive —
    /// `BridgeToolContext.dispatcher` is weak and the finish hook resolves through it.
    @discardableResult
    private func moveFloating(_ context: BridgeToolContext, selection: Selection) throws
        -> ToolDispatcher
    {
        let dispatcher = wireDispatcher(context)
        context.performHistory(SelectionHistoryItem(name: "Select", icon: .generic,
                                                    before: nil, after: selection))
        let tool = try moveTool(dispatcher)
        tool.mouseDown(event(context, 60, 60), context: context)
        tool.mouseDragged(event(context, 65, 60, seed: 1), context: context)
        tool.mouseUp(event(context, 65, 60, seed: 2), context: context)
        return dispatcher
    }

    // MARK: - Paint paths target the active layer

    @Test func toolsPaintOnActiveLayer() throws {
        let context = context()
        let bridge = context.bridge
        #expect(LayerCommandRunner.run(.addNewLayer, bridge: bridge, commitPendingEdit: {}))
        let beforeStroke = bridge.state.image
        paintStroke(context, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 50))
        let after = bridge.state.image
        #expect(after.layers.count == 2)
        #expect(pixel(after, 1, 100, 50) == .black, "the stroke lands on the active layer 1")
        #expect(pixel(after, 0, 100, 50) == .white, "layer 0 unchanged")
        // Layer 0's tiles were never copied.
        for coordinate in beforeStroke.layers[0].surface.allocatedTileCoordinates {
            #expect(beforeStroke.layers[0].surface.tile(at: coordinate)!
                .sharesStorage(with: after.layers[0].surface.tile(at: coordinate)!),
                "tile \(coordinate) of the untouched layer copied")
        }
        // Go to Layer Below; the pencil now hits layer 0.
        #expect(LayerCommandRunner.goTo(.below, bridge: bridge, commitPendingEdit: {}))
        let pencil = PencilTool()
        pencil.mouseDown(event(context, 20, 20), context: context)
        pencil.mouseUp(event(context, 20, 20, seed: 1), context: context)
        let final = bridge.state.image
        #expect(pixel(final, 0, 20, 20) == .black, "the pencil lands on layer 0")
        #expect(final.layers[1].surface == after.layers[1].surface, "layer 1 unchanged")
    }

    /// Every remaining pixel-writing path targets the ACTIVE layer (0024; L-1 made
    /// multi-layer stacks observable): Paint Bucket, Eraser, Erase/Fill Selection, and
    /// Cut on layer 3 of 3 — layers below keep their tile storage — plus a Duplicate
    /// whose copy is painted: copy-on-write keeps the original bit-identical.
    @Test func fillEraseAndClipboardPathsTargetActiveLayer() throws {
        let context = context()
        let bridge = context.bridge
        // Stack: white Background, opaque gray Middle, transparent Top (active).
        bridge.updateLiveState { state in
            let size = state.image.size
            var gray = TiledSurface(size: size)
            gray.fill(ColorRGBA8(red: 128, green: 128, blue: 128, alpha: 255))
            state.image = LayeredImage(
                size: size,
                layers: [state.image.layers[0],
                         Layer(name: "Middle", surface: gray),
                         Layer(name: "Top", surface: TiledSurface(size: size))],
                activeLayerIndex: 2)
        }
        func expectBelowUntouched(_ before: LayeredImage) {
            let after = bridge.state.image
            for index in [0, 1] {
                for coordinate in before.layers[index].surface.allocatedTileCoordinates {
                    #expect(before.layers[index].surface.tile(at: coordinate)!
                                .sharesStorage(with: after.layers[index].surface
                                    .tile(at: coordinate)!),
                            "layer \(index) tile \(coordinate) was written")
                }
            }
            #expect(after.layers[0].surface == before.layers[0].surface)
            #expect(after.layers[1].surface == before.layers[1].surface)
        }

        // 1) Paint Bucket (contiguous, black) on the transparent Top layer.
        context.colors = ColorSelection(primary: .black, secondary: .white)
        var before = bridge.state.image
        PaintBucketTool().mouseDown(event(context, 150, 150), context: context)
        #expect(pixel(bridge.state.image, 2, 150, 150) == .black,
                "the bucket fills the ACTIVE layer")
        expectBelowUntouched(before)

        // 2) Eraser drags on the Top layer.
        before = bridge.state.image
        let eraser = EraserTool()
        eraser.mouseDown(event(context, 100, 100), context: context)
        eraser.mouseDragged(event(context, 140, 100, seed: 1), context: context)
        eraser.mouseUp(event(context, 140, 100, seed: 2), context: context)
        #expect(pixel(bridge.state.image, 2, 120, 100) == .clear,
                "the eraser erases the ACTIVE layer")
        expectBelowUntouched(before)

        // 3) Fill Selection / Erase Selection on the Top layer (0018's router items).
        let selection = try #require(Selection(rect: CGRect(x: 40, y: 220, width: 30, height: 30),
                                               canvasSize: before.size))
        context.performHistory(SelectionHistoryItem(name: "Select", icon: .generic,
                                                    before: nil, after: selection))
        before = bridge.state.image
        let fillItem = try #require(FillSelection.makeHistoryItem(for: bridge.state,
                                                                  color: .white))
        bridge.perform(fillItem)
        #expect(pixel(bridge.state.image, 2, 50, 230) == .white, "Fill Selection hit layer 2")
        expectBelowUntouched(before)
        before = bridge.state.image
        let eraseItem = try #require(EraseSelection.makeHistoryItem(for: bridge.state))
        bridge.perform(eraseItem)
        #expect(pixel(bridge.state.image, 2, 50, 230) == .clear, "Erase Selection cleared layer 2")
        expectBelowUntouched(before)

        // 4) Cut (0021) erases the selection from the ACTIVE layer only.
        context.performHistory(SelectionHistoryItem(name: "Select", icon: .generic,
                                                    before: nil, after: selection))
        PaintBucketTool().mouseDown(event(context, 50, 230, seed: 3), context: context)
        let fillLayer = bridge.state.image.layers[2].surface
        #expect(fillLayer.pixel(at: PixelPoint(x: 50, y: 230)) == .black)
        before = bridge.state.image
        let pasteboard = makePrivatePasteboard()
        defer { pasteboard.releaseGlobally() }
        DocumentWindowController.performCut(bridge: bridge,
                                            clipboard: ClipboardController(pasteboard: pasteboard),
                                            alerts: RecordingAlertPresenter())
        #expect(pixel(bridge.state.image, 2, 50, 230) == .clear, "Cut erased the ACTIVE layer")
        #expect(bridge.state.selection == nil)
        expectBelowUntouched(before)
        // The clipboard holds the cropped ACTIVE-layer region (0021), not another layer.
        let pngData = try #require(pasteboard.data(forType: NSPasteboard.PasteboardType(
            ClipboardImageCodec.pngType)))
        let cutSurface = try ImageDecoder.decode(pngData).surface
        #expect(cutSurface.size == PixelSize(width: 30, height: 30))
        #expect(cutSurface.pixel(at: PixelPoint(x: 10, y: 10)) == .black,
                "Cut copied the Top layer's fill")

        // 5) Duplicate + paint: copy-on-write keeps the original bit-identical.
        #expect(LayerCommandRunner.run(.duplicateLayer, bridge: bridge, commitPendingEdit: {}))
        #expect(bridge.state.image.activeLayerIndex == 3)
        context.colors = ColorSelection(primary: .white, secondary: .black)
        before = bridge.state.image
        #expect(before.layers[3].surface.tile(at: TileCoordinate(column: 0, row: 0))!
                    .sharesStorage(with: before.layers[2].surface
                        .tile(at: TileCoordinate(column: 0, row: 0))!),
                "the duplicate shares its original's tiles")
        let pencil = PencilTool()
        pencil.mouseDown(event(context, 20, 20), context: context)
        pencil.mouseUp(event(context, 20, 20, seed: 1), context: context)
        let painted = bridge.state.image
        #expect(pixel(painted, 3, 20, 20) == .white, "the pencil paints the duplicate")
        #expect(pixel(painted, 2, 20, 20) == .black,
                "painting the duplicate leaves the original bit-identical (copy-on-write)")
        #expect(painted.layers[2].surface == before.layers[2].surface)
    }

    @Test func colorPickerImageVsLayer() throws {
        let size = PixelSize(width: 8, height: 8)
        var bottom = TiledSurface(size: size)
        bottom.fill(.white)
        var top = TiledSurface(size: size)
        top.fill(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        let point = PixelPoint(x: 4, y: 4)
        let stack = LayeredImage(size: size,
                                 layers: [Layer(name: "B", surface: bottom),
                                          Layer(name: "T", surface: top, opacity: 128)],
                                 activeLayerIndex: 1)
        // "Image" (Sample All Layers): the composite; "Layer": the stored active pixels.
        #expect(PixelSampler.sample(stack, at: point, size: .singlePixel, mode: .image)
                == ColorRGBA8(red: 255, green: 127, blue: 127, alpha: 255))
        #expect(PixelSampler.sample(stack, at: point, size: .singlePixel, mode: .layer)
                == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        var hiddenTop = stack
        hiddenTop.layers[1].isVisible = false
        #expect(PixelSampler.sample(hiddenTop, at: point, size: .singlePixel, mode: .image)
                == .white, "hidden top layer is not composited")
    }

    // MARK: - History semantics (H-6)

    @Test func undoKeepsActiveLayerH6() throws {
        let context = context()
        let bridge = context.bridge
        let initial = bridge.state
        #expect(LayerCommandRunner.run(.addNewLayer, bridge: bridge, commitPendingEdit: {}))
        #expect(bridge.state.image.activeLayerIndex == 1)
        #expect(LayerCommandRunner.goTo(.below, bridge: bridge, commitPendingEdit: {}))
        #expect(bridge.state.image.activeLayerIndex == 0)
        paintStroke(context, from: CGPoint(x: 50, y: 150), to: CGPoint(x: 250, y: 150))
        #expect(names(context) == ["New Image", "Add New Layer", "Paintbrush"])
        bridge.undo()   // the Paintbrush step: pixels only, active layer untouched (H-6)
        #expect(bridge.state.image.activeLayerIndex == 0)
        #expect(pixel(bridge.state.image, 0, 150, 150) == .white)
        bridge.undo()   // Add New Layer
        #expect(bridge.state.image.layers.count == 1)
        #expect(bridge.state.image.activeLayerIndex == 0)
        #expect(bridge.state == initial)
        bridge.redo()
        #expect(bridge.state.image.layers.count == 2)
        #expect(bridge.state.image.activeLayerIndex == 1, "the step restores its active layer")
    }

    @Test func floatingPixelsFinishBeforeLayerCommand() throws {
        let context = context()
        let bridge = context.bridge
        #expect(LayerCommandRunner.run(.addNewLayer, bridge: bridge, commitPendingEdit: {}))
        let selection = try #require(Selection(rect: CGRect(x: 30, y: 30, width: 120, height: 120),
                                               canvasSize: PixelSize(width: 300, height: 300)))
        let dispatcher = try moveFloating(context, selection: selection)
        #expect(dispatcher.activeTool is MoveSelectedPixelsTool)
        #expect(names(context).last == "Move Pixels")
        #expect(context.floatingPixels != nil)
        let afterMove = bridge.state

        #expect(LayerCommandRunner.run(.addNewLayer, bridge: bridge,
                                       commitPendingEdit: { bridge.prepareForNavigation?() }))
        #expect(names(context)
                    == ["New Image", "Add New Layer", "Select", "Move Pixels",
                        "Finish Pixels", "Add New Layer"])
        // The moved pixels are on layer 1 (finished before the add touched the stack).
        #expect(bridge.state.image.layers.count == 3)
        #expect(bridge.state.image.layers[1].surface == afterMove.image.layers[1].surface,
                "the move landed on layer 1")
        #expect(context.floatingPixels == nil)
        // Undo the Add: still no floating pixels (the Finish step stays done).
        bridge.undo()
        #expect(bridge.state.image.layers.count == 2)
        #expect(context.floatingPixels == nil, "undoing Add does not revive floating pixels")
        // Undo Finish Pixels: the lifted state returns on layer 1 (H-3).
        bridge.undo()
        let floating = try #require(context.floatingPixels)
        #expect(floating.layerID == bridge.state.image.layers[1].id, "floating is on layer 1 again")
    }

    @Test func goToAlsoFinishesFloatingPixels() throws {
        let context = context()
        let bridge = context.bridge
        #expect(LayerCommandRunner.run(.addNewLayer, bridge: bridge, commitPendingEdit: {}))
        let selection = try #require(Selection(rect: CGRect(x: 30, y: 30, width: 120, height: 120),
                                               canvasSize: PixelSize(width: 300, height: 300)))
        let dispatcher = try moveFloating(context, selection: selection)
        #expect(dispatcher.activeTool is MoveSelectedPixelsTool)
        #expect(LayerCommandRunner.goTo(.below, bridge: bridge,
                                        commitPendingEdit: { bridge.prepareForNavigation?() }))
        #expect(names(context) == ["New Image", "Add New Layer", "Select", "Move Pixels",
                                   "Finish Pixels"], "goTo records nothing but the finish")
        #expect(bridge.state.image.activeLayerIndex == 0)
        #expect(context.floatingPixels == nil)
    }

    // MARK: - Selection invariant (E-3, D-40)

    @Test func selectionSurvivesLayerOps() throws {
        let context = context()
        let bridge = context.bridge
        let canvas = PixelSize(width: 300, height: 300)
        let selection = try #require(Selection(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                                               canvasSize: canvas))
        context.performHistory(SelectionHistoryItem(name: "Select", icon: .generic,
                                                    before: nil, after: selection))
        // The mask is the session's wiring (CanvasToolSession), not the tool's; the
        // integration harnesses set it explicitly, like SelectionPixelCommandTests.
        context.paintClipMask = bridge.state.selection?.mask
        let expected = bridge.state.selection
        let commands: [LayerCommand] = [.addNewLayer, .duplicateLayer, .moveLayerDown,
                                        .mergeLayerDown, .flatten]
        for command in commands {
            #expect(LayerCommandRunner.run(command, bridge: bridge, commitPendingEdit: {}),
                    "\(command.rawValue)")
            #expect(bridge.state.selection == expected, "\(command.rawValue)")
        }
        #expect(bridge.state.image.layers.count == 1)
        var undoGuard = 0
        // Undo every LAYER step — each one's revert keeps the selection (D-40); the
        // walk stops above the "Select" step, whose own revert legitimately clears it.
        while bridge.history.canUndo,
              bridge.history.steps[bridge.history.currentIndex].name != "Select",
              undoGuard < 50 {
            bridge.undo()
            undoGuard += 1
            #expect(bridge.state.selection == expected, "undo keeps the selection (D-40)")
        }
        var redoGuard = 0
        while bridge.history.canRedo, redoGuard < 50 {
            bridge.redo()
            redoGuard += 1
            #expect(bridge.state.selection == expected, "redo keeps the selection (D-40)")
        }
        // A stroke across the selection edge after Add changes only pixels inside it.
        #expect(LayerCommandRunner.run(.addNewLayer, bridge: bridge, commitPendingEdit: {}))
        paintStroke(context, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 50))
        let image = bridge.state.image
        #expect(pixel(image, 1, 60, 50).alpha == 255, "inside the selection painted")
        #expect(pixel(image, 1, 150, 50) == .clear, "outside the selection untouched")
    }

    // MARK: - Full session

    @Test func fullSession() throws {
        let context = context(width: 1000, height: 700)
        let bridge = context.bridge
        let initial = bridge.state
        #expect(LayerCommandRunner.run(.addNewLayer, bridge: bridge, commitPendingEdit: {}))
        paintStroke(context, from: CGPoint(x: 100, y: 350), to: CGPoint(x: 400, y: 350))
        #expect(LayerCommandRunner.run(.duplicateLayer, bridge: bridge, commitPendingEdit: {}))
        #expect(LayerCommandRunner.run(.moveLayerDown, bridge: bridge, commitPendingEdit: {}))
        #expect(LayerCommandRunner.run(.mergeLayerDown, bridge: bridge, commitPendingEdit: {}))
        #expect(LayerCommandRunner.run(.addNewLayer, bridge: bridge, commitPendingEdit: {}))
        paintStroke(context, from: CGPoint(x: 600, y: 200), to: CGPoint(x: 900, y: 200))
        let beforeFlatten = bridge.state.image
        #expect(LayerCommandRunner.run(.flatten, bridge: bridge, commitPendingEdit: {}))

        #expect(names(context) == ["New Image", "Add New Layer", "Paintbrush",
                                   "Duplicate Layer", "Move Layer Down", "Merge Layer Down",
                                   "Add New Layer", "Paintbrush", "Flatten"])
        // Flatten produced exactly the CPU composite of the stack before it.
        #expect(bridge.state.image.layers.count == 1)
        #expect(bridge.state.image.layers[0].surface
                == CPUCompositor().flattened(beforeFlatten))

        // History panel rows (0010): every step shows its name and icon.
        let rows = HistoryListModel(stack: bridge.history).rows
        #expect(rows.map(\.name) == names(context))
        let expectedIcons: [HistoryIcon] = [.layerAdd, .paintbrush, .layerDuplicate,
                                            .layerMove, .layerMerge, .layerAdd,
                                            .paintbrush, .flatten]
        #expect(Array(rows.dropFirst().map(\.icon)) == expectedIcons)
        #expect(rows.last?.state == .current)

        // Undo all → the initial state; redo all → the final state.
        let final = bridge.state
        var undoGuard = 0
        while bridge.history.canUndo, undoGuard < 50 {
            bridge.undo()
            undoGuard += 1
        }
        #expect(undoGuard == 8)
        #expect(bridge.state == initial)
        var redoGuard = 0
        while bridge.history.canRedo, redoGuard < 50 {
            bridge.redo()
            redoGuard += 1
        }
        #expect(redoGuard == 8)
        #expect(bridge.state == final)
    }
}
