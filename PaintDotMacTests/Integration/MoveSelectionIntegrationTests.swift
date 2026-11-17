import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// Move Selection end to end behind `FakeToolContext` with the real tools and a real
/// `HistoryStack` (spec 0019 *Test plan*, integration): painting clips to the moved
/// selection, and the rotate → scale → translate chain undoes and redoes step by step.
@MainActor
struct MoveSelectionIntegrationTests {
    private let size = PixelSize(width: 200, height: 200)

    private func event(_ context: FakeToolContext, _ x: Double, _ y: Double,
                       button: ToolMouseButton = .primary,
                       modifiers: ToolModifiers = [],
                       t: TimeInterval = 1) -> ToolEvent {
        let location = CGPoint(x: x, y: y)
        return ToolEvent(location: location,
                         viewLocation: context.transform.canvasToView(location),
                         button: button, modifiers: modifiers,
                         clickCount: 1, pressure: 1, timestamp: t)
    }

    private func key(_ key: ToolKey, _ modifiers: ToolModifiers = []) -> ToolKeyEvent {
        ToolKeyEvent(key: key, characters: "", modifiers: modifiers, isRepeat: false)
    }

    @Test func paintClippedToMovedSelection() throws {
        let context = FakeToolContext(size: size, background: .white)
        let brushKeys = BrushOptions.keys(for: .paintbrush)
        context.memoryOptions.setValue(20.0, for: brushKeys.width)
        context.memoryOptions.setValue(100, for: brushKeys.hardness)
        context.memoryOptions.setValue(false, for: brushKeys.antialiasing)

        // Rectangle Select (50,50)→(149,149).
        let rectTool = RectangleSelectTool()
        rectTool.mouseDown(event(context, 50, 50, t: 1.0), context: context)
        rectTool.mouseDragged(event(context, 149, 149, t: 1.2), context: context)
        rectTool.mouseUp(event(context, 149, 149, t: 1.4), context: context)

        // Move Selection nudges it 10 px right with ⌘→.
        let moveTool = MoveSelectionTool()
        moveTool.activate(context: context)
        #expect(moveTool.keyDown(key(.rightArrow, .command), context: context))

        // A Paintbrush stroke across row 100, from x 0 to x 199.
        let brush = PaintbrushTool()
        brush.mouseDown(event(context, 0, 100, t: 2.0), context: context)
        brush.mouseDragged(event(context, 100, 100, t: 2.2), context: context)
        brush.mouseUp(event(context, 199, 100, t: 2.4), context: context)

        let surface = context.state.image.layers[0].surface
        let black = ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255)
        #expect(surface.pixel(at: PixelPoint(x: 155, y: 100)) == black,
                "painted inside the moved selection")
        #expect(surface.pixel(at: PixelPoint(x: 55, y: 100)) == .white,
                "the vacated left edge stays white")
        #expect(surface.pixel(at: PixelPoint(x: 165, y: 100)) == .white,
                "the brush past the new right edge is clipped")

        #expect(context.history.steps.map(\.name)
                    == ["New Image", "Rectangle Select", "Move Selection", "Paintbrush"])

        // Undo Paintbrush + Move Selection → the selection is back at (50,50,100,100) and
        // the pixels are white again.
        context.navigateForTests { history, state in _ = history.undo(&state) }
        context.navigateForTests { history, state in _ = history.undo(&state) }
        #expect(context.selection?.bounds == PixelRect(x: 50, y: 50, width: 100, height: 100))
        let restored = context.state.image.layers[0].surface
        #expect(restored.pixel(at: PixelPoint(x: 155, y: 100)) == .white)
        #expect(restored.pixel(at: PixelPoint(x: 100, y: 100)) == .white)
    }

    @Test func rotateScaleTranslateUndoChain() throws {
        let context = FakeToolContext(size: size, background: .white)
        let original = try #require(Selection(rect: CGRect(x: 50, y: 80, width: 100,
                                                           height: 40), canvasSize: size))
        context.performHistory(SelectionHistoryItem(name: "setup", icon: .generic,
                                                    before: nil, after: original))
        let tool = MoveSelectionTool()
        tool.activate(context: context)
        func point(_ x: Double, _ y: Double, _ t: TimeInterval,
                   button: ToolMouseButton = .primary,
                   modifiers: ToolModifiers = []) -> ToolEvent {
            event(context, x, y, button: button, modifiers: modifiers, t: t)
        }

        // Rotate 90° (center (100, 100)): (150, 100) → (100, 150), right button.
        tool.mouseDown(point(150, 100, 1.0, button: .secondary), context: context)
        tool.mouseDragged(point(100, 150, 1.2, button: .secondary), context: context)
        tool.mouseUp(point(100, 150, 1.4, button: .secondary), context: context)

        // Scale: the 90° rotation about (100, 100) maps the frame's local BR (150, 120)
        // to canvas (100 − 20, 100 − 20) = (80, 150); drag it by (+20, +20).
        tool.mouseDown(point(80, 150, 2.0), context: context)
        tool.mouseDragged(point(100, 170, 2.2), context: context)
        tool.mouseUp(point(100, 170, 2.4), context: context)

        // Translate: (110, 100) sits inside the rotated+scaled frame, away from any nub
        // (local (100, 90) in the frame's 90° coordinates).
        tool.mouseDown(point(110, 100, 3.0), context: context)
        tool.mouseDragged(point(122, 108, 3.2), context: context)
        tool.mouseUp(point(122, 108, 3.4), context: context)

        let names = context.history.steps.map(\.name)
        #expect(names.suffix(3).elementsEqual(
            ["Rotate Selection", "Scale Selection", "Move Selection"]), "\(names)")
        let result = context.selection

        for _ in 0..<3 {
            context.navigateForTests { history, state in _ = history.undo(&state) }
        }
        #expect(context.selection == original, "undo ×3 → the original selection")
        for _ in 0..<3 {
            context.navigateForTests { history, state in _ = history.redo(&state) }
        }
        #expect(context.selection == result, "redo ×3 → the chain's result")
    }

    @Test func rotateScaleNudgeAreSelectionOnly() throws {
        // NF/History contract: every Move Selection gesture step is a
        // `SelectionHistoryItem` with a `.selection` change — no pixel diff, and no
        // tile's storage is ever rewritten.
        let context = FakeToolContext(size: size, background: .white)
        let original = try #require(Selection(rect: CGRect(x: 50, y: 80, width: 100,
                                                           height: 40), canvasSize: size))
        context.performHistory(SelectionHistoryItem(name: "setup", icon: .generic,
                                                    before: nil, after: original))
        let tool = MoveSelectionTool()
        tool.activate(context: context)
        let coordinate = TileCoordinate(column: 0, row: 0)
        let tileBefore = try #require(context.image.layers[0].surface.tile(at: coordinate))

        func gesturePoint(_ x: Double, _ y: Double, _ t: TimeInterval,
                          button: ToolMouseButton = .primary) -> ToolEvent {
            event(context, x, y, button: button, t: t)
        }
        tool.mouseDown(gesturePoint(150, 100, 1.0, button: .secondary), context: context)
        tool.mouseDragged(gesturePoint(100, 150, 1.2, button: .secondary), context: context)
        tool.mouseUp(gesturePoint(100, 150, 1.4, button: .secondary), context: context)
        tool.mouseDown(gesturePoint(80, 150, 2.0), context: context)
        tool.mouseDragged(gesturePoint(100, 170, 2.2), context: context)
        tool.mouseUp(gesturePoint(100, 170, 2.4), context: context)
        #expect(tool.keyDown(ToolKeyEvent(key: .rightArrow, characters: "",
                                          modifiers: [.command], isRepeat: false),
                             context: context))

        let steps = context.history.steps
        #expect(steps.suffix(3).map(\.name)
                    == ["Rotate Selection", "Scale Selection", "Move Selection"])
        for step in steps.suffix(3) {
            #expect(step.item is SelectionHistoryItem, "\(step.name) is a selection step")
            #expect(step.item?.change == .selection, "\(step.name) changes no pixels")
        }
        let tileAfter = try #require(context.image.layers[0].surface.tile(at: coordinate))
        #expect(tileBefore.sharesStorage(with: tileAfter), "the layer tile was never rewritten")
    }
}
