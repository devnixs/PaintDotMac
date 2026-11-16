import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// The Lasso tool end to end behind the real history and clipping paths (spec 0015 *Test
/// plan*): the user story scripted through `FakeToolContext` — lasso, Paintbrush clipped
/// to it (TOOL-B), then undo/redo through the selection step.
@MainActor
@Suite(.serialized)
struct LassoSessionTests {
    private func event(_ x: Double, _ y: Double, _ t: TimeInterval) -> ToolEvent {
        ToolEvent(location: CGPoint(x: x, y: y), viewLocation: CGPoint(x: x, y: y),
                  button: .primary, modifiers: [], clickCount: 1, pressure: 1,
                  timestamp: t)
    }

    @Test func paintClippedToLasso() {
        let context = FakeToolContext(size: PixelSize(width: 64, height: 64),
                                      background: .white)
        context.memoryOptions.setValue(SelectionQuality.pixelated,
                                       for: SelectionToolOptions.quality)
        context.memoryOptions.setValue(100.0,
                                       for: BrushOptions.keys(for: .paintbrush).width)

        // Freeform triangle (8, 8) → (56, 8) → (8, 56), closed by the release line.
        let lasso = LassoSelectTool()
        lasso.mouseDown(event(8, 8, 1.0), context: context)
        lasso.mouseDragged(event(56, 8, 1.2), context: context)
        lasso.mouseDragged(event(8, 56, 1.4), context: context)
        lasso.mouseUp(event(8, 56, 1.6), context: context)

        // A width-100 Paintbrush stroke across the whole image: black inside the
        // triangle, untouched outside it (TOOL-B).
        let brush = PaintbrushTool()
        brush.mouseDown(event(-60, 31.5, 2.0), context: context)
        brush.mouseDragged(event(0, 31.5, 2.2), context: context)
        brush.mouseDragged(event(63, 31.5, 2.4), context: context)
        brush.mouseUp(event(120, 31.5, 2.6), context: context)

        var surface: TiledSurface? { context.state.image.layers[0].surface }
        let black = ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255)
        #expect(surface?.pixel(at: PixelPoint(x: 30, y: 30)) == black, "inside the triangle")
        #expect(surface?.pixel(at: PixelPoint(x: 50, y: 31)) == .white, "past the hypotenuse")
        #expect(surface?.pixel(at: PixelPoint(x: 2, y: 31)) == .white, "left of the triangle")
        #expect(context.history.steps.map(\.name)
                    == ["New Image", "Lasso Select", "Paintbrush"])

        // Undo twice → white image, no selection; redo twice → the same result.
        for _ in 0..<2 {
            context.navigateForTests { history, state in _ = history.undo(&state) }
        }
        #expect(context.selection == nil, "undo of the selection step clears it")
        #expect(surface?.pixel(at: PixelPoint(x: 30, y: 30)) == .white, "undo restores white")
        for _ in 0..<2 {
            context.navigateForTests { history, state in _ = history.redo(&state) }
        }
        #expect(surface?.pixel(at: PixelPoint(x: 30, y: 30)) == black, "redo re-applies")
        #expect(surface?.pixel(at: PixelPoint(x: 50, y: 31)) == .white, "redo keeps outside")
        #expect(context.selection != nil, "redo restores the selection")
    }
}
