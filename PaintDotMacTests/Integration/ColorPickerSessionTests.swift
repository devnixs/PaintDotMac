import Foundation
import Testing

@testable import PaintDotMac

/// The Color Picker in the real gesture wiring (spec 0012 *Test plan*): a
/// `ToolDispatcher(registry: .standard())` over a `ToolContext` double backed by a real
/// `UndoBridge` — Paintbrush stroke, pick its color back with the Color Picker,
/// "Switch to previous tool" returns to the Paintbrush, and picking adds no History row
/// and survives Undo untouched.
@MainActor
@Suite(.serialized)
struct ColorPickerSessionTests {
    private let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)

    private func pointer(_ location: CGPoint) -> ToolPointerInput {
        ToolPointerInput(physicalButton: .left, location: location, viewLocation: location,
                         modifiers: [], clickCount: 1, pressure: 1, timestamp: 0)
    }

    private func pixel(_ image: LayeredImage, _ x: Int, _ y: Int) -> ColorRGBA8 {
        image.layers[0].surface.pixel(at: PixelPoint(x: x, y: y))
    }

    /// A `ToolContext` over a real `UndoBridge` whose `activateTool` forwards to the
    /// dispatcher — exactly `CanvasToolSession`'s wiring, which the 0010 support double
    /// (a recording no-op) does not model.
    @MainActor
    private final class DispatcherBackedContext: ToolContext {
        let bridge: UndoBridge
        let nav = FakeCanvasNavigation()
        var navigation: any CanvasNavigating { nav }
        let memoryOptions = InMemoryToolOptionStore()
        var options: any ToolOptionStore { memoryOptions }
        var colors: ColorSelection = .default
        var setColorCalls: [(color: ColorRGBA8, slot: ColorSlot)] = []
        var paintClipMask: (any BrushClipMask)?
        var previousToolID: ToolID?
        weak var dispatcher: ToolDispatcher?
        var image: LayeredImage { bridge.state.image }
        var transform: CanvasTransform { nav.transform }

        init(size: PixelSize, base: HistoryBaseStep) {
            var surface = TiledSurface(size: size)
            surface.fill(.white)
            bridge = UndoBridge(state: DocumentState(image: LayeredImage(surface: surface)),
                                base: base,
                                budgetBytes: HistoryStack.defaultBudgetBytes,
                                undoManager: NavigationUndoManager())
            bridge.undoManager.groupsByEvent = false
        }

        func activateTool(_ id: ToolID) { dispatcher?.requestToolSwitch(id) }
        func setColor(_ color: ColorRGBA8, for slot: ColorSlot) {
            colors[slot] = color
            setColorCalls.append((color, slot))
        }
        func setOverlay(_ overlay: ToolOverlay?) {}
        func invalidateCursor() {}
        func commitHistory(_ item: any HistoryItem) { bridge.commit(item) }
        func performHistory(_ item: any HistoryItem) { bridge.perform(item) }
        func updateImage(_ body: (inout LayeredImage) -> Void) {
            bridge.updateLiveState { state in body(&state.image) }
        }
    }

    @Test func pickAfterStrokeReturnsToPaintbrush() {
        // The white 800×600 one-layer "New Image" document (APP-9 / NewImageDefaults:
        // one visible, opaque, Normal "Background" layer at 96 DPI).
        let context = DispatcherBackedContext(size: PixelSize(width: 800, height: 600),
                                              base: .newImage)
        #expect(context.bridge.state.image.dpi == NewImageDefaults.fallbackDPI)
        #expect(context.bridge.state.image.layers.map(\.name) == [NewImageDefaults.backgroundLayerName])
        context.options.setValue(20.0, for: BrushOptions.keys(for: .paintbrush).width)
        context.colors = ColorSelection(primary: red, secondary: .white)

        let dispatcher = ToolDispatcher(registry: .standard())
        context.dispatcher = dispatcher
        dispatcher.setContext(context)
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
        let context = DispatcherBackedContext(size: PixelSize(width: 300, height: 300),
                                              base: .newImage)
        context.colors = ColorSelection(primary: red, secondary: .black)
        let dispatcher = ToolDispatcher(registry: .standard())
        context.dispatcher = dispatcher
        dispatcher.setContext(context)
        _ = dispatcher.selectTool(.colorPicker)
        func controlPointer(_ location: CGPoint) -> ToolPointerInput {
            ToolPointerInput(physicalButton: .left, location: location, viewLocation: location,
                             modifiers: [.control], clickCount: 1, pressure: 1, timestamp: 0)
        }
        dispatcher.pointerDown(controlPointer(CGPoint(x: 150, y: 150)))
        dispatcher.pointerUp(controlPointer(CGPoint(x: 150, y: 150)))
        #expect(context.colors.secondary == .white, "Control-click sets the white document pixel")
        #expect(context.colors.primary == red, "the primary is untouched")
    }
}
