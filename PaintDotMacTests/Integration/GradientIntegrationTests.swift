import AppKit
import Foundation
import Testing

@testable import PaintDotMac

/// The Gradient end-to-end (spec 0023 *Test plan*), headless: an 800×600 white "Background"
/// behind a real `UndoBridge` (base `.newImage`) with a `ToolContext` double forwarding
/// `updateImage`/`commitHistory`, driven through `GradientTool`.
@MainActor
struct GradientIntegrationTests {
    private func pixel(_ image: LayeredImage, _ x: Int, _ y: Int) -> ColorRGBA8 {
        image.layers[0].surface.pixel(at: PixelPoint(x: x, y: y))
    }

    /// A `ToolContext` forwarding to a real `UndoBridge`.
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
        var floatingPixels: FloatingPixels? { bridge.state.floatingPixels }
        var history: HistoryStack { bridge.history }
        func jumpHistory(to index: Int) { bridge.jump(to: index) }
        var image: LayeredImage { bridge.state.image }
        var transform: CanvasTransform { nav.transform }

        init(size: PixelSize, fill: ColorRGBA8 = .white) {
            var surface = TiledSurface(size: size)
            if fill != .clear { surface.fill(fill) }
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

    private func event(_ location: CGPoint, button: ToolMouseButton = .primary,
                       modifiers: ToolModifiers = []) -> ToolEvent {
        ToolEvent(location: location, viewLocation: location, button: button,
                  modifiers: modifiers, clickCount: 1, pressure: 1, timestamp: 0)
    }

    private func pressReturn(_ tool: GradientTool, _ context: BridgeSessionContext) {
        _ = tool.keyDown(ToolKeyEvent(key: .returnKey, characters: "\r", modifiers: [],
                                      isRepeat: false),
                         context: context)
    }

    // MARK: - Undo / redo exactness

    @Test func undoRedoRoundTrip() throws {
        let context = BridgeSessionContext(size: PixelSize(width: 800, height: 600))
        let white = context.image
        let tool = GradientTool()
        tool.mouseDown(event(CGPoint(x: 0, y: 300)), context: context)
        tool.mouseDragged(event(CGPoint(x: 800, y: 300)), context: context)
        tool.mouseUp(event(CGPoint(x: 800, y: 300)), context: context)
        pressReturn(tool, context)
        #expect(context.bridge.history.steps.map(\.name) == ["New Image", "Gradient"])
        let snapshot = context.image
        context.bridge.undo()
        #expect(context.image == white, "undo restores the exact before tiles")
        context.bridge.redo()
        #expect(context.image == snapshot, "redo restores the exact after tiles")
    }

    @Test func seededUndoRedoIdentities() {
        // 50 random gradients — type, mode, endpoints, colors — each followed by the
        // undo/redo identity (spec *Test plan*; seed printed on failure).
        let seed = UInt64(0x0023_0301)
        var rng = SeededRandom(seed: seed)
        let context = BridgeSessionContext(size: PixelSize(width: 800, height: 600))
        for iteration in 0..<50 {
            let tool = GradientTool()
            context.memoryOptions.setValue(
                GradientType.allCases.randomElement(using: &rng)!,
                for: GradientOptions.keys().type)
            context.memoryOptions.setValue(
                rng.next() % 2 == 0 ? GradientMode.color : GradientMode.transparency,
                for: GradientOptions.keys().mode)
            context.colors = ColorSelection(primary: rng.color(), secondary: rng.color())
            let before = context.image
            let start = CGPoint(x: rng.double(in: 0...800), y: rng.double(in: 0...600))
            let end = CGPoint(x: rng.double(in: 0...800), y: rng.double(in: 0...600))
            tool.mouseDown(event(start), context: context)
            tool.mouseDragged(event(end), context: context)
            tool.mouseUp(event(end), context: context)
            pressReturn(tool, context)
            let committed = context.image
            context.bridge.undo()
            #expect(context.image == before,
                    "iteration \(iteration) (seed \(seed)): undo ≠ before")
            context.bridge.redo()
            #expect(context.image == committed,
                    "iteration \(iteration) (seed \(seed)): redo ≠ committed")
        }
    }

    @Test func undoWhilePendingCommitsFirst() throws {
        let context = BridgeSessionContext(size: PixelSize(width: 800, height: 600))
        let tool = GradientTool()
        // 0008/0020's wiring: navigation runs the tool's commit hook first.
        context.bridge.prepareForNavigation = { tool.commit(context: context) }
        tool.mouseDown(event(CGPoint(x: 100, y: 300)), context: context)
        tool.mouseDragged(event(CGPoint(x: 700, y: 300)), context: context)
        context.bridge.undo()   // → prepareForNavigation → commit → undo of that step
        #expect(context.bridge.history.steps.map(\.name) == ["New Image", "Gradient"])
        #expect(context.bridge.history.currentIndex == 0)
        #expect(pixel(context.image, 400, 300) == .white)
        #expect(context.bridge.history.redoStep?.name == "Gradient")
    }

    // MARK: - No-ops (H-6 / D-34)

    @Test func noOpAddsNoStep() {
        // Transparency mode on a fully transparent layer changes nothing.
        let context = BridgeSessionContext(size: PixelSize(width: 800, height: 600),
                                           fill: .clear)
        context.memoryOptions.setValue(GradientMode.transparency,
                                       for: GradientOptions.keys().mode)
        let tool = GradientTool()
        tool.mouseDown(event(CGPoint(x: 0, y: 300)), context: context)
        tool.mouseDragged(event(CGPoint(x: 800, y: 300)), context: context)
        tool.mouseUp(event(CGPoint(x: 800, y: 300)), context: context)
        pressReturn(tool, context)
        #expect(context.bridge.history.steps.map(\.name) == ["New Image"])

        // Color mode with both colors at alpha 0.
        context.colors = ColorSelection(primary: ColorRGBA8(red: 10, green: 20, blue: 30,
                                                            alpha: 0),
                                        secondary: ColorRGBA8(red: 40, green: 50, blue: 60,
                                                              alpha: 0))
        context.memoryOptions.setValue(GradientMode.color, for: GradientOptions.keys().mode)
        let second = GradientTool()
        second.mouseDown(event(CGPoint(x: 0, y: 300)), context: context)
        second.mouseDragged(event(CGPoint(x: 800, y: 300)), context: context)
        second.mouseUp(event(CGPoint(x: 800, y: 300)), context: context)
        pressReturn(second, context)
        #expect(context.bridge.history.steps.map(\.name) == ["New Image"])
        #expect(!context.bridge.history.canUndo)
    }

    // MARK: - Selection clip (TOOL-B)

    @Test func selectionClipsGradient() throws {
        let context = BridgeSessionContext(size: PixelSize(width: 800, height: 600))
        let selection = try #require(
            Selection(rect: CGRect(x: 100, y: 100, width: 200, height: 200),
                      canvasSize: PixelSize(width: 800, height: 600)))
        context.selection = selection
        context.paintClipMask = selection.mask
        let tool = GradientTool()
        tool.mouseDown(event(CGPoint(x: 0, y: 300)), context: context)
        tool.mouseDragged(event(CGPoint(x: 800, y: 300)), context: context)
        tool.mouseUp(event(CGPoint(x: 800, y: 300)), context: context)
        pressReturn(tool, context)
        #expect(context.bridge.history.steps.map(\.name) == ["New Image", "Gradient"])
        for (x, y) in [(50, 300), (700, 300), (400, 50), (110, 300), (290, 310)] {
            #expect(pixel(context.image, x, y) == .white, "(\(x), \(y)) outside the rect")
        }
        #expect(pixel(context.image, 200, 150) != .white, "inside: the ramp landed")
    }
}
