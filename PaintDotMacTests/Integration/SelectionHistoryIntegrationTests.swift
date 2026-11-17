import AppKit
import Foundation
import Testing

@testable import PaintDotMac

/// Selection steps through the real history machinery (spec 0013 *Test plan*, headless):
/// undo/redo identity over sessions mixing selection steps and strokes, no-op rules,
/// independence of pixel and selection undo, snapshot items, and budget folding (H-5).
@MainActor
struct SelectionHistoryIntegrationTests {
    // MARK: - Fixtures

    private final class BridgeSessionContext: ToolContext {
        let bridge: UndoBridge
        let nav = FakeCanvasNavigation()
        var navigation: any CanvasNavigating { nav }
        let memoryOptions = InMemoryToolOptionStore()
        var options: any ToolOptionStore { memoryOptions }
        var colors: ColorSelection = .default
        /// Like `CanvasToolSession` (0013): the document's selection mask clips painting,
        /// with the pixel-identical `isFull` shortcut, so the random sessions below
        /// interleave *clipped* strokes with selection steps (TOOL-B under undo/redo).
        var paintClipMask: (any BrushClipMask)? {
            guard let selection = bridge.state.selection, !selection.mask.isFull else { return nil }
            return selection.mask
        }
        var selection: Selection? { bridge.state.selection }
        var floatingPixels: FloatingPixels? { bridge.state.floatingPixels }
        var history: HistoryStack { bridge.history }
        func jumpHistory(to index: Int) { bridge.jump(to: index) }
        var previousToolID: ToolID?
        var image: LayeredImage { bridge.state.image }
        var transform: CanvasTransform { nav.transform }

        init(side: Int, budgetBytes: Int = HistoryStack.defaultBudgetBytes) {
            var surface = TiledSurface(size: PixelSize(width: side, height: side))
            surface.fill(.white)
            bridge = UndoBridge(state: DocumentState(image: LayeredImage(surface: surface)),
                                base: .openImage, budgetBytes: budgetBytes,
                                undoManager: NavigationUndoManager())
            bridge.undoManager.groupsByEvent = false
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

    private func event(_ location: CGPoint) -> ToolEvent {
        ToolEvent(location: location, viewLocation: .zero, button: .primary,
                  modifiers: [], clickCount: 1, pressure: 1, timestamp: 0)
    }

    private func rectSelection(_ rect: PixelRect, canvas: Int) throws -> Selection {
        try #require(Selection(
            rect: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
            canvasSize: PixelSize(width: canvas, height: canvas)))
    }

    private func digest(_ image: LayeredImage) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for layer in image.layers {
            for y in 0..<image.size.height {
                for x in 0..<image.size.width {
                    let p = layer.surface.pixel(at: PixelPoint(x: x, y: y))
                    for byte in [p.red, p.green, p.blue, p.alpha] {
                        hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
                    }
                }
            }
        }
        return hash
    }

    // MARK: - Command sessions

    @Test func selectAllDeselectInvertSession() throws {
        let context = BridgeSessionContext(side: 100)
        let state1 = context.bridge.state
        let selectAll = try #require(SelectionCommand.selectAll.makeHistoryItem(for: state1))
        context.bridge.perform(selectAll)
        let selectAllSelection = try #require(context.bridge.state.selection)

        let invert = try #require(SelectionCommand.invertSelection
            .makeHistoryItem(for: context.bridge.state))
        context.bridge.perform(invert)
        #expect(context.bridge.state.selection == nil, "inverting Select All deselects")

        #expect(context.bridge.history.steps.map(\.name)
                == ["Open Image", "Select All", "Invert Selection"])

        context.bridge.undo()
        #expect(context.bridge.state.selection == selectAllSelection)
        context.bridge.undo()
        #expect(context.bridge.state.selection == nil)
        context.bridge.redo()
        #expect(context.bridge.state.selection == selectAllSelection)
        context.bridge.redo()
        #expect(context.bridge.state.selection == nil)
    }

    @Test func noOpCommandsAddNoStep() throws {
        let context = BridgeSessionContext(side: 100)
        #expect(SelectionCommand.deselect.makeHistoryItem(for: context.bridge.state) == nil)
        let selectAll = try #require(SelectionCommand.selectAll
            .makeHistoryItem(for: context.bridge.state))
        context.bridge.perform(selectAll)
        #expect(SelectionCommand.selectAll.makeHistoryItem(for: context.bridge.state) == nil,
                "Select All twice: the second is a no-op (H-6)")
        #expect(context.bridge.history.steps.map(\.name) == ["Open Image", "Select All"])
        #expect(context.bridge.history.totalBytes
                == selectAll.byteCost + HistoryCost.stepOverheadBytes)
    }

    @Test func pixelAndSelectionUndoAreIndependent() throws {
        let context = BridgeSessionContext(side: 100)
        let rect = try rectSelection(PixelRect(x: 10, y: 10, width: 20, height: 20), canvas: 100)
        context.bridge.perform(SelectionHistoryItem(name: "Rectangle Select",
                                                    icon: .rectangleSelect,
                                                    before: nil, after: rect))
        let beforePaint = context.bridge.state.image
        context.bridge.updateLiveState { state in
            for y in 0..<100 {
                for x in 0..<100 where x >= 10 && x < 30 && y >= 10 && y < 30 {
                    state.image.layers[0].surface
                        .setPixel(ColorRGBA8(red: 255, green: 0, blue: 0),
                                  at: PixelPoint(x: x, y: y))
                }
            }
        }
        let diff = try TileDiff.between(before: beforePaint, after: context.bridge.state.image)
        context.bridge.commit(TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush,
                                                  diff: diff))
        context.bridge.undo()   // undo the paint
        #expect(context.bridge.state.selection == rect, "undo of pixels keeps the selection")
        let pixelsAfterPaintUndo = digest(context.bridge.state.image)
        context.bridge.undo()   // undo the selection
        #expect(context.bridge.state.selection == nil)
        #expect(digest(context.bridge.state.image) == pixelsAfterPaintUndo,
                "undo of the selection changes no pixels")
    }

    @Test func snapshotItemRestoresSelection() throws {
        let context = BridgeSessionContext(side: 100)
        let rect = try rectSelection(PixelRect(x: 5, y: 5, width: 10, height: 10), canvas: 100)
        let before = DocumentState(image: context.bridge.state.image, selection: rect)
        let after = DocumentState(image: context.bridge.state.image, selection: nil)
        let item = DocumentSnapshotHistoryItem(name: "Flip Horizontal", icon: .flipRotate,
                                              before: before, after: after)
        context.bridge.perform(item)
        #expect(context.bridge.state.selection == nil)
        context.bridge.undo()
        #expect(context.bridge.state.selection == rect, "the snapshot restores the selection")
    }

    @Test func budgetFoldingKeepsSelectionState() throws {
        // Budget fits exactly two selection steps: the first commit folds (H-5) and the
        // base now *is* its state — undoing everything back to the base must land on the
        // folded step's selection, not on "no selection".
        let selectAllCost = SelectionHistoryItem(
            name: "Select All", icon: .selectAll, before: nil,
            after: .all(canvasSize: PixelSize(width: 100, height: 100))).byteCost
        let budget = 2 * (selectAllCost + HistoryCost.stepOverheadBytes)
        let context = BridgeSessionContext(side: 100, budgetBytes: budget)
        let all = Selection.all(canvasSize: PixelSize(width: 100, height: 100))
        let rect = try rectSelection(PixelRect(x: 10, y: 10, width: 20, height: 20), canvas: 100)
        context.bridge.perform(SelectionHistoryItem(name: "Select All", icon: .selectAll,
                                                    before: nil, after: all))
        context.bridge.perform(SelectionHistoryItem(name: "Rectangle Select",
                                                    icon: .rectangleSelect,
                                                    before: all, after: rect))
        context.bridge.perform(SelectionHistoryItem(name: "Deselect", icon: .deselect,
                                                    before: rect, after: nil))
        // Each commit folds the previous step (the base moves forward, H-5); only the
        // newest step remains.
        #expect(context.bridge.history.steps.map(\.name) == ["Open Image", "Deselect"])
        context.bridge.undo()
        #expect(context.bridge.state.selection == rect,
                "the base now IS the last folded step — its selection survives")
        #expect(!context.bridge.history.canUndo)
    }

    @Test func pendingStrokeCommitsBeforeCommand() throws {
        // Core sequence: a pending paintbrush stroke commits as its own step *before*
        // the selection step (what the window controller's action does via
        // `prepareForNavigation`).
        let context = BridgeSessionContext(side: 100)
        let tool = PaintbrushTool()
        tool.mouseDown(event(CGPoint(x: 20.5, y: 20.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 60.5, y: 40.5)), context: context)
        #expect(context.bridge.history.steps.count == 1)   // pending, uncommitted
        tool.commit(context: context)
        #expect(context.bridge.history.steps.map(\.name) == ["Open Image", "Paintbrush"])
        let item = try #require(SelectionCommand.selectAll
            .makeHistoryItem(for: context.bridge.state))
        context.bridge.perform(item)
        #expect(context.bridge.history.steps.map(\.name)
                == ["Open Image", "Paintbrush", "Select All"])
        #expect(context.bridge.state.selection != nil)
        context.bridge.undo()
        #expect(context.bridge.state.selection == nil, "undo removes only the selection step")
        #expect(context.bridge.history.canUndo, "the Paintbrush step is still there")
    }

    // MARK: - Property: random sessions keep undo/redo identity

    @Test(.timeLimit(.minutes(3))) func randomSessionUndoRedoIdentity() {
        let seed = SeededRandom.resolvedSeed(default: 0x0013_5E55)
        let canvas = 64
        for sessionIndex in 0..<100 {
            var rng = SeededRandom(seed: seed &+ UInt64(sessionIndex))
            let context = BridgeSessionContext(side: canvas)
            var snapshots: [(selection: Selection?, digest: UInt64)] = [
                (context.bridge.state.selection, digest(context.bridge.state.image)),
            ]
            for _ in 0..<rng.int(in: 4...10) {
                switch rng.int(in: 0...3) {
                case 0:   // a selection command
                    let command = SelectionCommand.allCases[rng.int(in: 0...2)]
                    if let item = command.makeHistoryItem(for: context.bridge.state) {
                        context.bridge.perform(item)
                    }
                case 1:   // a random rectangle selection step
                    let x = rng.int(in: 0...canvas - 1), y = rng.int(in: 0...canvas - 1)
                    let w = rng.int(in: 1...(canvas - x)), h = rng.int(in: 1...(canvas - y))
                    if let rect = try? rectSelection(PixelRect(x: x, y: y, width: w, height: h),
                                                     canvas: canvas) {
                        let item = SelectionHistoryItem(name: "Rectangle Select",
                                                        icon: .rectangleSelect,
                                                        before: context.bridge.state.selection,
                                                        after: rect)
                        if !item.isNoOp { context.bridge.perform(item) }
                    }
                case 2:   // a tiny stroke
                    let start = CGPoint(x: rng.double(in: 4...60), y: rng.double(in: 4...60))
                    let end = CGPoint(x: rng.double(in: 4...60), y: rng.double(in: 4...60))
                    let tool = PaintbrushTool()
                    tool.mouseDown(event(start), context: context)
                    tool.mouseDragged(event(end), context: context)
                    tool.mouseUp(event(end), context: context)
                default:  // a stroke clipped by the current selection
                    _ = context.selection
                    let start = CGPoint(x: rng.double(in: 4...60), y: rng.double(in: 4...60))
                    let end = CGPoint(x: rng.double(in: 4...60), y: rng.double(in: 4...60))
                    let tool = EraserTool()
                    tool.mouseDown(event(start), context: context)
                    tool.mouseUp(event(end), context: context)
                }
                let snap = (selection: context.bridge.state.selection,
                            digest: digest(context.bridge.state.image))
                // No-op operations (a disabled command, an empty stroke) commit no
                // step; only state-changing operations get a snapshot so the undo and
                // redo loops step the history one-for-one.
                if snap.digest != snapshots.last?.digest
                    || snap.selection != snapshots.last?.selection { snapshots.append(snap) }
            }
            let comment: Comment = "session \(sessionIndex), seed=0x\(String(seed, radix: 16))"
            // Undo everything.
            for index in stride(from: snapshots.count - 1, through: 1, by: -1) {
                context.bridge.undo()
                #expect(context.bridge.state.selection == snapshots[index - 1].selection,
                        "undo \(index): selection — \(comment)")
                #expect(digest(context.bridge.state.image) == snapshots[index - 1].digest,
                        "undo \(index): pixels — \(comment)")
            }
            // Redo everything.
            for index in 1..<snapshots.count {
                context.bridge.redo()
                #expect(context.bridge.state.selection == snapshots[index].selection,
                        "redo \(index): selection — \(comment)")
                #expect(digest(context.bridge.state.image) == snapshots[index].digest,
                        "redo \(index): pixels — \(comment)")
            }
        }
    }
}
