import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// The Magic Wand end to end behind the real history and clipping paths (spec 0016 *Test
/// plan*): the user story scripted through `FakeToolContext` — wand click, Paintbrush
/// clipped to the region (TOOL-B), then undo/redo through the selection step.
@MainActor
@Suite(.serialized)
struct MagicWandSessionTests {
    private func event(_ x: Double, _ y: Double, _ t: TimeInterval) -> ToolEvent {
        ToolEvent(location: CGPoint(x: x, y: y), viewLocation: CGPoint(x: x, y: y),
                  button: .primary, modifiers: [], clickCount: 1, pressure: 1,
                  timestamp: t)
    }

    @Test func wandThenPaintIsClipped() {
        let context = FakeToolContext(size: PixelSize(width: 64, height: 64),
                                      background: .white)
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        context.updateImage { image in
            image.layers[0].surface.fill(red, in: PixelRect(x: 10, y: 10, width: 20, height: 20))
        }
        context.memoryOptions.setValue(200.0, for: BrushOptions.keys(for: .paintbrush).width)

        // Wand click inside the red square → the square's region.
        let wand = MagicWandTool()
        wand.mouseDown(event(15, 15, 1.0), context: context)
        #expect(context.selection?.mask.bounds
                    == PixelRect(x: 10, y: 10, width: 20, height: 20))

        // A width-200 Paintbrush stroke across the whole image: black only inside the
        // region, the rest untouched (TOOL-B).
        let brush = PaintbrushTool()
        brush.mouseDown(event(-60, 19.5, 2.0), context: context)
        brush.mouseDragged(event(0, 19.5, 2.2), context: context)
        brush.mouseDragged(event(63, 19.5, 2.4), context: context)
        brush.mouseUp(event(120, 19.5, 2.6), context: context)

        var surface: TiledSurface? { context.state.image.layers[0].surface }
        let black = ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255)
        #expect(surface?.pixel(at: PixelPoint(x: 15, y: 15)) == black, "inside the square")
        #expect(surface?.pixel(at: PixelPoint(x: 10, y: 10)) == black, "square corner")
        #expect(surface?.pixel(at: PixelPoint(x: 5, y: 5)) == .white, "above the square")
        #expect(surface?.pixel(at: PixelPoint(x: 35, y: 15)) == .white, "right of the square")
        #expect(surface?.pixel(at: PixelPoint(x: 15, y: 35)) == .white, "below the square")
        #expect(context.history.steps.map(\.name) == ["New Image", "Magic Wand", "Paintbrush"])

        // Undo twice → the fixture's pixels and no selection; redo twice → the same.
        for _ in 0..<2 {
            context.navigateForTests { history, state in _ = history.undo(&state) }
        }
        #expect(context.selection == nil, "undo of the selection step clears it")
        #expect(surface?.pixel(at: PixelPoint(x: 15, y: 15)) == red, "undo restores red")
        #expect(surface?.pixel(at: PixelPoint(x: 5, y: 5)) == .white)
        for _ in 0..<2 {
            context.navigateForTests { history, state in _ = history.redo(&state) }
        }
        #expect(surface?.pixel(at: PixelPoint(x: 15, y: 15)) == black, "redo repaints")
        #expect(surface?.pixel(at: PixelPoint(x: 5, y: 5)) == .white)
        #expect(context.selection?.mask.bounds
                    == PixelRect(x: 10, y: 10, width: 20, height: 20), "redo restores the mask")
    }
}
