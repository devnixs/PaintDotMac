import CoreGraphics
import Foundation
import Testing
@testable import PaintDotMac

/// `RectangleSelectTool` against `FakeToolContext` (spec 0014 *Test plan*): the emitted
/// steps and masks, the combine algebra from the picker and from modifiers, the Shift
/// toggle, the finish-rule cases, Return/Escape/context switches, and the huge-image case.
/// Events carry explicit timestamps (1.0 → 1.2 unless stated).
@MainActor
struct RectangleSelectToolTests {
    private func event(_ x: Double, _ y: Double, _ t: TimeInterval,
                       button: ToolMouseButton = .primary,
                       modifiers: ToolModifiers = []) -> ToolEvent {
        ToolEvent(location: CGPoint(x: x, y: y), viewLocation: .zero, button: button,
                  modifiers: modifiers, clickCount: 1, pressure: 1, timestamp: t)
    }

    private func keyEvent(_ key: ToolKey) -> ToolKeyEvent {
        ToolKeyEvent(key: key, characters: "", modifiers: [], isRepeat: false)
    }

    /// Install a pixelated existing selection through the history path.
    private func setExisting(_ context: FakeToolContext, _ rect: PixelRect) {
        let selection = Selection(rect: CGRect(x: Double(rect.x), y: Double(rect.y),
                                               width: Double(rect.width), height: Double(rect.height)),
                                  canvasSize: context.image.size, antialiased: false)
        context.performHistory(SelectionHistoryItem(name: "setup", icon: .generic,
                                                    before: nil, after: selection))
    }

    private func coverage(_ selection: Selection?, _ x: Int, _ y: Int) -> UInt8 {
        selection?.mask.coverage(x: x, y: y) ?? 0
    }

    @Test func dragEmitsRectangleSelect() throws {
        let context = FakeToolContext()   // 64 × 64, no selection
        let tool = RectangleSelectTool()
        tool.mouseDown(event(4.2, 6.7, 1.0), context: context)
        tool.mouseDragged(event(9.5, 12.1, 1.1), context: context)
        // Nothing is built or recorded while dragging.
        #expect(context.history.steps.count == 1, "no history work mid-drag")
        tool.mouseUp(event(9.5, 12.1, 1.2), context: context)

        let history = context.history
        #expect(history.steps.map(\.name) == ["New Image", "Rectangle Select"])
        #expect(history.steps[1].icon == .rectangleSelect)
        let selection = try #require(context.selection)
        #expect(selection.bounds == PixelRect(x: 4, y: 6, width: 6, height: 7))
        for y in 0..<64 {
            for x in 0..<64 {
                let inside = (4...9).contains(x) && (6...12).contains(y)
                #expect(coverage(context.selection, x, y) == (inside ? 255 : 0),
                        "(\(x), \(y)) \(inside ? "inside" : "outside")")
            }
        }
        // Recorded overlays: the 1 × 1 shape at mouse-down, the drag preview, the clear.
        #expect(context.overlays.count == 3)
        #expect(context.overlays[1]
                    == .selectionShape(SelectionShapePreview(shape: .rectangle,
                                                             rect: PixelRect(x: 4, y: 6, width: 6, height: 7),
                                                             hidesCurrentSelection: true)))
        #expect(context.overlays.last == .some(nil), "the preview clears at mouse-up")
    }

    @Test func combineModes() throws {
        // Existing A = 0…15 × 0…15, drag B = 8…23 × 8…23; expected per-pixel set algebra.
        let a: (Int, Int) -> Bool = { x, y in (0...15).contains(x) && (0...15).contains(y) }
        let b: (Int, Int) -> Bool = { x, y in (8...23).contains(x) && (8...23).contains(y) }
        for mode in SelectionCombineMode.allCases {
            let context = FakeToolContext()
            setExisting(context, PixelRect(x: 0, y: 0, width: 16, height: 16))
            context.memoryOptions.setValue(mode, for: SelectionToolOptions.combineMode)
            let stepsBefore = context.history.steps.count

            let tool = RectangleSelectTool()
            tool.mouseDown(event(8.4, 8.4, 1.0), context: context)
            tool.mouseDragged(event(23.4, 23.4, 1.1), context: context)
            tool.mouseUp(event(23.4, 23.4, 1.2), context: context)

            #expect(context.history.steps.count == stepsBefore + 1, "\(mode)")
            #expect(context.history.steps.last?.name == "Rectangle Select", "\(mode)")
            let selection = context.selection
            for y in 0..<64 {
                for x in 0..<64 {
                    let expected: Bool
                    switch mode {
                    case .replace: expected = b(x, y)
                    case .union: expected = a(x, y) || b(x, y)
                    case .exclude: expected = a(x, y) && !b(x, y)
                    case .intersect: expected = a(x, y) && b(x, y)
                    case .xor: expected = a(x, y) != b(x, y)
                    }
                    #expect(coverage(selection, x, y) == (expected ? 255 : 0),
                            "\(mode) at (\(x), \(y))")
                }
            }
        }
    }

    @Test func modeLatchedAtMouseDown() throws {
        // ⌘ at mouse-down, gone later → Union still applies.
        let context = FakeToolContext()
        setExisting(context, PixelRect(x: 0, y: 0, width: 8, height: 8))
        let tool = RectangleSelectTool()
        tool.mouseDown(event(20.4, 20.4, 1.0, modifiers: [.command]), context: context)
        tool.mouseDragged(event(30.4, 30.4, 1.1), context: context)
        tool.mouseUp(event(30.4, 30.4, 1.2), context: context)
        #expect(context.selection?.bounds == PixelRect(x: 0, y: 0, width: 31, height: 31),
                "union of both rects")

        // ⌥ + secondary at mouse-down → Intersect, even though up has no modifiers.
        let context2 = FakeToolContext()
        setExisting(context2, PixelRect(x: 0, y: 0, width: 8, height: 8))
        let tool2 = RectangleSelectTool()
        tool2.mouseDown(event(20.4, 20.4, 1.0, button: .secondary, modifiers: [.option]),
                        context: context2)
        tool2.mouseDragged(event(28.4, 28.4, 1.1, button: .secondary), context: context2)
        tool2.mouseUp(event(28.4, 28.4, 1.2, button: .secondary), context: context2)
        #expect(context2.selection == nil, "the disjoint intersection selects nothing")
    }

    @Test func shiftToggledMidDrag() throws {
        let context = FakeToolContext()
        let tool = RectangleSelectTool()
        tool.mouseDown(event(10.4, 10.4, 1.0), context: context)
        tool.mouseDragged(event(20.6, 14.4, 1.1), context: context)
        let rectOf = { (overlay: ToolOverlay??) -> PixelRect? in
            guard case .selectionShape(let preview)? = overlay ?? nil else { return nil }
            return preview.rect
        }
        #expect(rectOf(context.overlays.last) == PixelRect(x: 10, y: 10, width: 11, height: 5))
        tool.flagsChanged([.shift], context: context)   // no new pointer event
        #expect(rectOf(context.overlays.last) == PixelRect(x: 10, y: 10, width: 5, height: 5))
        tool.mouseUp(event(20.6, 14.4, 1.2, modifiers: [.shift]), context: context)
        #expect(context.selection?.bounds == PixelRect(x: 10, y: 10, width: 5, height: 5))
    }

    @Test func clickDeselects() {
        let context = FakeToolContext()
        setExisting(context, PixelRect(x: 0, y: 0, width: 16, height: 16))
        let tool = RectangleSelectTool()
        tool.mouseDown(event(30.5, 30.5, 1.0), context: context)
        tool.mouseUp(event(30.5, 30.5, 1.02), context: context)
        #expect(context.history.steps.map(\.name) == ["New Image", "setup", "Deselect"])
        #expect(context.history.steps.last?.icon == .deselect)
        #expect(context.selection == nil)
    }

    @Test func quickDragDeselects() {
        let context = FakeToolContext()
        setExisting(context, PixelRect(x: 40, y: 40, width: 8, height: 8))
        let tool = RectangleSelectTool()
        tool.mouseDown(event(0.4, 0.4, 1.0), context: context)
        tool.mouseDragged(event(20.4, 20.4, 1.02), context: context)
        tool.mouseUp(event(20.4, 20.4, 1.04), context: context)   // held 40 ms ≤ 50 ms
        #expect(context.history.steps.last?.name == "Deselect")
        #expect(context.selection == nil)
    }

    @Test func clickWithoutSelectionAddsNothing() {
        let context = FakeToolContext()
        let tool = RectangleSelectTool()
        tool.mouseDown(event(30.5, 30.5, 1.0), context: context)
        tool.mouseUp(event(30.5, 30.5, 1.02), context: context)
        #expect(context.history.steps.map(\.name) == ["New Image"])
        #expect(context.selection == nil)
    }

    @Test func appendClickIsNoOp() throws {
        let context = FakeToolContext()
        setExisting(context, PixelRect(x: 0, y: 0, width: 16, height: 16))
        let before = try #require(context.selection)
        let tool = RectangleSelectTool()
        tool.mouseDown(event(30.5, 30.5, 1.0, modifiers: [.command]), context: context)
        tool.mouseUp(event(30.5, 30.5, 1.02, modifiers: [.command]), context: context)
        #expect(context.history.steps.map(\.name) == ["New Image", "setup"])
        #expect(context.selection == before)
    }

    @Test func offCanvasReplaceDeselects() throws {
        let context = FakeToolContext()
        setExisting(context, PixelRect(x: 0, y: 0, width: 16, height: 16))
        let tool = RectangleSelectTool()
        tool.mouseDown(event(-30, -30, 1.0), context: context)
        tool.mouseDragged(event(-5, -5, 1.1), context: context)
        tool.mouseUp(event(-5, -5, 1.2), context: context)
        #expect(context.history.steps.last?.name == "Deselect")
        #expect(context.selection == nil)

        // With ⌥ the off-canvas drag changes nothing and adds no step.
        let context2 = FakeToolContext()
        setExisting(context2, PixelRect(x: 0, y: 0, width: 16, height: 16))
        let before = try #require(context2.selection)
        let tool2 = RectangleSelectTool()
        tool2.mouseDown(event(-30, -30, 1.0, modifiers: [.option]), context: context2)
        tool2.mouseDragged(event(-5, -5, 1.1, modifiers: [.option]), context: context2)
        tool2.mouseUp(event(-5, -5, 1.2, modifiers: [.option]), context: context2)
        #expect(context2.history.steps.map(\.name) == ["New Image", "setup"])
        #expect(context2.selection == before)
    }

    @Test func noEffectAddsNoStep() throws {
        // D-34: Union of a rect inside the selection changes no pixel — no step.
        let context = FakeToolContext()
        setExisting(context, PixelRect(x: 0, y: 0, width: 32, height: 32))
        let before = try #require(context.selection)
        let tool = RectangleSelectTool()
        tool.mouseDown(event(4.4, 4.4, 1.0, modifiers: [.command]), context: context)
        tool.mouseDragged(event(10.6, 10.6, 1.1, modifiers: [.command]), context: context)
        tool.mouseUp(event(10.6, 10.6, 1.2, modifiers: [.command]), context: context)
        #expect(context.history.steps.map(\.name) == ["New Image", "setup"],
                "a pixel-identical result must not record a step")
        #expect(context.selection?.mask == before.mask)
    }

    @Test func excludeEverything() {
        // The step IS recorded (the selection changed) and the result is "no selection".
        let context = FakeToolContext()
        setExisting(context, PixelRect(x: 8, y: 8, width: 8, height: 8))
        let tool = RectangleSelectTool()
        tool.mouseDown(event(0.4, 0.4, 1.0, modifiers: [.option]), context: context)
        tool.mouseDragged(event(40.4, 40.4, 1.1, modifiers: [.option]), context: context)
        tool.mouseUp(event(40.4, 40.4, 1.2, modifiers: [.option]), context: context)
        #expect(context.history.steps.last?.name == "Rectangle Select")
        #expect(context.selection == nil)
    }

    @Test func returnDeselects() {
        let context = FakeToolContext()
        setExisting(context, PixelRect(x: 0, y: 0, width: 16, height: 16))
        let tool = RectangleSelectTool()
        #expect(tool.keyDown(keyEvent(.returnKey), context: context))
        #expect(context.history.steps.last?.name == "Deselect")
        #expect(context.selection == nil)
        // With no selection: unhandled, no step.
        #expect(!tool.keyDown(keyEvent(.returnKey), context: context))
        #expect(context.history.steps.count == 3)

        let context2 = FakeToolContext()
        setExisting(context2, PixelRect(x: 0, y: 0, width: 16, height: 16))
        #expect(tool.keyDown(keyEvent(.enter), context: context2))
        #expect(context2.history.steps.last?.name == "Deselect")
    }

    @Test func escapeCancels() throws {
        let registry = ToolRegistry(factories: [.rectangleSelect: { RectangleSelectTool() }])
        let dispatcher = ToolDispatcher(registry: registry)
        let context = FakeToolContext()
        setExisting(context, PixelRect(x: 0, y: 0, width: 16, height: 16))
        let before = try #require(context.selection)
        dispatcher.setContext(context)

        dispatcher.pointerDown(.init(physicalButton: .left, location: CGPoint(x: 30, y: 30),
                                     viewLocation: .zero, modifiers: [], clickCount: 1,
                                     pressure: 1, timestamp: 1.0))
        dispatcher.pointerDragged(.init(physicalButton: .left, location: CGPoint(x: 40, y: 40),
                                        viewLocation: .zero, modifiers: [], clickCount: 0,
                                        pressure: 1, timestamp: 1.1))
        #expect(dispatcher.keyDown(keyEvent(.escape)))
        #expect(context.history.steps.map(\.name) == ["New Image", "setup"],
                "Escape records no step")
        #expect(context.selection == before, "the previous selection survives")
        #expect(context.overlays.last == .some(nil), "the preview clears")

        // The swallowed follow-up events must not resurrect the gesture.
        dispatcher.pointerDragged(.init(physicalButton: .left, location: CGPoint(x: 50, y: 50),
                                        viewLocation: .zero, modifiers: [], clickCount: 0,
                                        pressure: 1, timestamp: 1.2))
        dispatcher.pointerUp(.init(physicalButton: .left, location: CGPoint(x: 50, y: 50),
                                   viewLocation: .zero, modifiers: [], clickCount: 1,
                                   pressure: 0, timestamp: 1.3))
        #expect(context.history.steps.map(\.name) == ["New Image", "setup"])
        #expect(context.selection == before)
    }

    @Test func contextSwitchCancels() throws {
        let registry = ToolRegistry(factories: [.rectangleSelect: { RectangleSelectTool() }])
        let dispatcher = ToolDispatcher(registry: registry)
        let first = FakeToolContext()
        setExisting(first, PixelRect(x: 0, y: 0, width: 16, height: 16))
        let before = try #require(first.selection)
        dispatcher.setContext(first)
        dispatcher.pointerDown(.init(physicalButton: .left, location: CGPoint(x: 30, y: 30),
                                     viewLocation: .zero, modifiers: [], clickCount: 1,
                                     pressure: 1, timestamp: 1.0))
        dispatcher.pointerDragged(.init(physicalButton: .left, location: CGPoint(x: 40, y: 40),
                                        viewLocation: .zero, modifiers: [], clickCount: 0,
                                        pressure: 1, timestamp: 1.1))

        dispatcher.setContext(FakeToolContext())
        #expect(first.history.steps.map(\.name) == ["New Image", "setup"])
        #expect(first.selection == before)
        #expect(first.overlays.last == .some(nil), "the old context's preview clears")
    }

    @Test func undoRedo() throws {
        let context = FakeToolContext()
        let tool = RectangleSelectTool()
        tool.mouseDown(event(4.2, 6.7, 1.0), context: context)
        tool.mouseDragged(event(9.5, 12.1, 1.1), context: context)
        tool.mouseUp(event(9.5, 12.1, 1.2), context: context)
        let mask = try #require(context.selection).mask

        context.navigateForTests { history, state in _ = history.undo(&state) }
        #expect(context.selection == nil)
        context.navigateForTests { history, state in _ = history.redo(&state) }
        #expect(context.selection?.mask == mask, "redo restores the exact mask")
    }

    @Test func hugeImageSelection() throws {
        // 65,535 × 65,535 (0002 tiles): no per-drag work, one mask build at mouse-up, and
        // the 0013 rectangle fast path keeps every tile `.full` (no partial bytes).
        let context = FakeToolContext(size: PixelSize(width: 65_535, height: 65_535))
        let tool = RectangleSelectTool()
        tool.mouseDown(event(0.5, 0.5, 1.0), context: context)
        tool.mouseDragged(event(32_767.5, 32_767.5, 1.1), context: context)
        #expect(context.history.steps.count == 1, "no performHistory before mouse-up")
        #expect(context.overlays.allSatisfy { overlay in
            if case .selectionShape? = overlay { return true }
            return false
        }, "only shape previews are recorded")
        tool.mouseUp(event(65_534.5, 65_534.5, 1.2), context: context)

        let selection = try #require(context.selection)
        #expect(selection.bounds == PixelRect(x: 0, y: 0, width: 65_535, height: 65_535))
        #expect(selection.mask.coverage(x: 0, y: 0) == 255)
        #expect(selection.mask.coverage(x: 32_767, y: 32_767) == 255)
        #expect(selection.mask.coverage(x: 65_534, y: 65_534) == 255)
        #expect(selection.mask.partialTileCount == 0, "the rectangle fast path allocates no tile bytes")
    }
}
