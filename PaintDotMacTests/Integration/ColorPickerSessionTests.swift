import Foundation
import Testing

@testable import PaintDotMac

/// The Color Picker in the real gesture wiring (spec 0012 *Test plan*): a
/// `ToolDispatcher(registry: .standard())` over the shared `BridgeToolContext` (a real
/// `UndoBridge`; its `activateTool` forwards to the dispatcher exactly like
/// `CanvasToolSession`) — Paintbrush stroke, pick its color back with the Color Picker,
/// "Switch to previous tool" returns to the Paintbrush, and picking adds no History row
/// and survives Undo untouched.
@MainActor
@Suite(.serialized)
struct ColorPickerSessionTests {
    private let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)

    private func pointer(_ location: CGPoint, modifiers: ToolModifiers = []) -> ToolPointerInput {
        ToolPointerInput(physicalButton: .left, location: location, viewLocation: location,
                         modifiers: modifiers, clickCount: 1, pressure: 1, timestamp: 0)
    }

    private func pixel(_ image: LayeredImage, _ x: Int, _ y: Int) -> ColorRGBA8 {
        image.layers[0].surface.pixel(at: PixelPoint(x: x, y: y))
    }

    private func session(size: PixelSize) -> (BridgeToolContext, ToolDispatcher) {
        let context = BridgeToolContext(size: size, base: .newImage)
        let dispatcher = ToolDispatcher(registry: .standard())
        context.dispatcher = dispatcher
        dispatcher.setContext(context)
        return (context, dispatcher)
    }

    @Test func pickAfterStrokeReturnsToPaintbrush() {
        // The white 800×600 one-layer "New Image" document (APP-9 / NewImageDefaults:
        // one visible, opaque, Normal "Background" layer at 96 DPI).
        let (context, dispatcher) = session(size: PixelSize(width: 800, height: 600))
        #expect(context.bridge.state.image.dpi == NewImageDefaults.fallbackDPI)
        #expect(context.bridge.state.image.layers.map(\.name) == [NewImageDefaults.backgroundLayerName])
        context.options.setValue(20.0, for: BrushOptions.keys(for: .paintbrush).width)
        context.colors = ColorSelection(primary: red, secondary: .white)
        #expect(dispatcher.activeToolID == .paintbrush, "D-35 start tool")

        dispatcher.pointerDown(pointer(CGPoint(x: 300, y: 300)))
        dispatcher.pointerDragged(pointer(CGPoint(x: 420, y: 300)))
        dispatcher.pointerUp(pointer(CGPoint(x: 500, y: 300)))
        #expect(pixel(context.image, 400, 300) == red, "the stroke is red (primary)")

        // Set the primary to black so the pick is observable.
        context.colors.primary = .black
        #expect(dispatcher.selectTool(.colorPicker))
        // The real wiring mirrors the dispatcher's previous tool into the context through
        // `AppModel` (`CanvasToolSession.previousToolID`); the double keeps it in sync.
        context.previousToolID = dispatcher.previousToolID
        #expect(context.previousToolID == .paintbrush)
        context.options.setValue(ColorPickerAfterClick.switchToPreviousTool,
                                 for: ColorPickerTool.afterClickKey)

        dispatcher.pointerDown(pointer(CGPoint(x: 400, y: 300)))
        dispatcher.pointerUp(pointer(CGPoint(x: 400, y: 300)))

        #expect(context.colors.primary == red, "the click picked the stroke color back")
        #expect(context.colors.secondary == .white, "the secondary is untouched")
        #expect(context.setColorCalls.map(\.slot) == [.primary, .primary],
                "down and up each write the slot exactly once")
        #expect(dispatcher.activeToolID == .paintbrush, "Switch to previous tool fired")
        #expect(dispatcher.previousToolID == .colorPicker,
                "the dispatcher records the Color Picker as the new previous tool")
        #expect(context.bridge.history.steps.map(\.name) == ["New Image", "Paintbrush"],
                "picking added no History step")

        context.bridge.undo()
        #expect(pixel(context.image, 400, 300) == .white, "undo removes the stroke")
        #expect(context.colors.primary == red,
                "undo never touches the picked colors (app state, not document state)")
    }

    @Test func controlClickSetsSecondaryThroughDispatcher() {
        // TOOL-A: Control-left arrives from the dispatcher as `.secondary`.
        let (context, dispatcher) = session(size: PixelSize(width: 300, height: 300))
        context.colors = ColorSelection(primary: red, secondary: .black)
        _ = dispatcher.selectTool(.colorPicker)
        dispatcher.pointerDown(pointer(CGPoint(x: 150, y: 150), modifiers: [.control]))
        dispatcher.pointerUp(pointer(CGPoint(x: 150, y: 150), modifiers: [.control]))
        #expect(context.colors.secondary == .white, "Control-click sets the white document pixel")
        #expect(context.colors.primary == red, "the primary is untouched")
    }
}
