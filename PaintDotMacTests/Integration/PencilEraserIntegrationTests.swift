import AppKit
import Foundation
import Testing

@testable import PaintDotMac

/// The Pencil and Eraser end-to-end (spec 0011 *Test plan*), headless: a real
/// `UndoBridge` behind a `ToolContext` double drives the two tools as the document does —
/// one step per stroke, exact undo/redo pixels, redo pruning (H-5).
@MainActor
@Suite(.serialized)
struct PencilEraserIntegrationTests {
    /// A `ToolContext` forwarding `updateImage`/`commitHistory` to a real `UndoBridge`
    /// (base `.newImage`, `groupsByEvent = false` per 0008's test convention — the same
    /// double spec 0009 introduced).
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
        var image: LayeredImage { bridge.state.image }
        var transform: CanvasTransform { nav.transform }

        init(size: PixelSize) {
            var surface = TiledSurface(size: size)
            surface.fill(.white)
            bridge = UndoBridge(state: DocumentState(image: LayeredImage(surface: surface)),
                                base: .newImage,
                                budgetBytes: HistoryStack.defaultBudgetBytes,
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

    private func event(_ location: CGPoint, button: ToolMouseButton = .primary) -> ToolEvent {
        ToolEvent(location: location, viewLocation: location, button: button,
                  modifiers: [], clickCount: 1, pressure: 1, timestamp: 0)
    }

    private func pixel(_ image: LayeredImage, _ x: Int, _ y: Int) -> ColorRGBA8 {
        image.layers[0].surface.pixel(at: PixelPoint(x: x, y: y))
    }

    @Test func undoRedoRoundTrip() throws {
        let context = BridgeSessionContext(size: PixelSize(width: 100, height: 100))
        let white = ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255)
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        context.colors = ColorSelection(primary: red, secondary: .white)
        context.options.setValue(false, for: BrushOptions.keys(for: .eraser).antialiasing)
        context.options.setValue(4.0, for: BrushOptions.keys(for: .eraser).width)

        func pencil(from: CGPoint, to: CGPoint) {
            let tool = PencilTool()
            tool.mouseDown(event(from), context: context)
            tool.mouseDragged(event(CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)),
                              context: context)
            tool.mouseUp(event(to), context: context)
        }
        func eraser(from: CGPoint, to: CGPoint) {
            let tool = EraserTool()
            tool.mouseDown(event(from), context: context)
            tool.mouseDragged(event(to), context: context)
            tool.mouseUp(event(to), context: context)
        }

        pencil(from: CGPoint(x: 10.5, y: 10.5), to: CGPoint(x: 60.5, y: 30.5))
        eraser(from: CGPoint(x: 30.5, y: 50.5), to: CGPoint(x: 80.5, y: 50.5))
        pencil(from: CGPoint(x: 70.5, y: 70.5), to: CGPoint(x: 90.5, y: 90.5))
        #expect(context.bridge.history.steps.map(\.name)
                    == ["New Image", "Pencil", "Eraser", "Pencil"])
        #expect(pixel(context.image, 35, 50) == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0),
                "the eraser stroke cleared its pixels")
        #expect(pixel(context.image, 35, 20) == red, "the first pencil stroke painted")

        let finalState = context.image
        context.bridge.undo()
        context.bridge.undo()
        context.bridge.undo()
        for y in 0 ..< 100 {
            for x in 0 ..< 100 {
                #expect(pixel(context.image, x, y) == white, "undo ×3 → the white base at (\(x), \(y))")
            }
        }
        context.bridge.redo()
        context.bridge.redo()
        context.bridge.redo()
        #expect(context.image == finalState, "redo ×3 → the recorded post-stroke state")

        // H-5: a new stroke after one undo discards the redo step.
        context.bridge.undo()
        #expect(context.bridge.history.canRedo)
        pencil(from: CGPoint(x: 5.5, y: 95.5), to: CGPoint(x: 15.5, y: 95.5))
        #expect(context.bridge.history.steps.map(\.name)
                    == ["New Image", "Pencil", "Eraser", "Pencil"],
                "the undone step was replaced, not appended")
        #expect(!context.bridge.history.canRedo, "the redo step was discarded")
        // The replacement stroke's pixels landed.
        #expect(pixel(context.image, 10, 95) == red)
    }
}
