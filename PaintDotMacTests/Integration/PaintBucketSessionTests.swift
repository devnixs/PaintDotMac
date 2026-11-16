import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// The Paint Bucket end to end behind a real `UndoBridge` (spec 0017 *Test plan*): the
/// user story scripted through `BridgeToolContext` — Rectangle Select, then a bucket
/// click clipped to it (TOOL-B), then undo/redo ×2 through the bridge's `UndoManager`.
/// `paintClipMask` mirrors `CanvasToolSession`: it follows the bridge's selection.
@MainActor
@Suite(.serialized)
struct PaintBucketSessionTests {
    private func event(_ x: Double, _ y: Double, _ t: TimeInterval) -> ToolEvent {
        ToolEvent(location: CGPoint(x: x, y: y), viewLocation: CGPoint(x: x, y: y),
                  button: .primary, modifiers: [], clickCount: 1, pressure: 1,
                  timestamp: t)
    }

    @Test func fillInsideRectangleSelection() {
        let context = BridgeToolContext(size: PixelSize(width: 64, height: 64),
                                        base: .newImage, fill: .white)
        context.colors = ColorSelection(primary: .black, secondary: .white)

        // Rectangle Select (16, 16)–(48, 48) (0014).
        let rectangle = RectangleSelectTool()
        rectangle.mouseDown(event(16, 16, 1.0), context: context)
        rectangle.mouseDragged(event(48, 48, 1.1), context: context)
        rectangle.mouseUp(event(48, 48, 1.2), context: context)
        // The session's clip follows the selection (0013) — `BridgeToolContext` leaves
        // the seam settable for exactly this.
        context.paintClipMask = context.selection?.mask

        // Paint Bucket, contiguous, default options, black.
        let bucket = PaintBucketTool()
        bucket.mouseDown(event(32.5, 32.5, 2.0), context: context)

        func pixel(_ x: Int, _ y: Int) -> ColorRGBA8 {
            context.bridge.state.image.layers[0].surface.pixel(at: PixelPoint(x: x, y: y))
        }
        #expect(pixel(32, 32) == .black, "inside the selection")
        #expect(pixel(40, 40) == .black, "still inside")
        #expect(pixel(10, 10) == .white, "left of the selection")
        #expect(pixel(55, 55) == .white, "right of the selection")
        #expect(context.bridge.history.steps.map(\.name)
                    == ["New Image", "Rectangle Select", "Paint Bucket"])

        // Undo ×2: white canvas, no selection; redo ×2: the same fill again.
        context.bridge.undo()
        context.bridge.undo()
        #expect(pixel(32, 32) == .white, "undo restores white")
        #expect(context.bridge.state.selection == nil, "undo removes the selection")
        context.bridge.redo()
        context.bridge.redo()
        #expect(pixel(32, 32) == .black, "redo re-applies the fill")
        #expect(pixel(10, 10) == .white, "and keeps the clip")
        #expect(context.bridge.state.selection?.mask.coverage(x: 32, y: 32) == 255,
                "redo restores the ants")
    }
}
