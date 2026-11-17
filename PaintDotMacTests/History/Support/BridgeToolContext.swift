import Foundation

@testable import PaintDotMac

/// A `ToolContext` backed by a real `UndoBridge` (spec 0010 *Test support*): `image`,
/// `updateImage`, `commitHistory`, and `performHistory` forward to the bridge; options and
/// navigation are the 0006 doubles; `colors` is settable (0007) and `setColor` is recorded
/// (0012); `paintClipMask` is nil (0009). Overlay and cursor requests are recorded no-ops;
/// `activateTool` records and, when `dispatcher` is set (0012), forwards the deferred
/// tool switch — `CanvasToolSession`'s wiring.
@MainActor
final class BridgeToolContext: ToolContext {
    /// The one source of truth for pixels and history: a real bridge on a white image.
    let bridge: UndoBridge
    /// The concrete fake (tests assert on it); `navigation` is the protocol-typed witness.
    let nav = FakeCanvasNavigation()
    var navigation: any CanvasNavigating { nav }
    let memoryOptions = InMemoryToolOptionStore()
    var options: any ToolOptionStore { memoryOptions }
    /// Settable so tests pin the stroke colors (opaque black is `.default`'s primary).
    var colors: ColorSelection = .default
    /// The Color Picker's slot writes, in order (0012).
    private(set) var setColorCalls: [(color: ColorRGBA8, slot: ColorSlot)] = []
    var paintClipMask: (any BrushClipMask)?
    /// 0013: the bridge's current selection.
    var selection: Selection? { bridge.state.selection }
    var previousToolID: ToolID?
    var image: LayeredImage { bridge.state.image }
    var transform: CanvasTransform { nav.transform }

    /// Recorded no-op calls, for tests that assert a tool asked for nothing surprising.
    private(set) var overlayChanges: [ToolOverlay?] = []
    private(set) var cursorInvalidations: Int = 0
    private(set) var activatedTools: [ToolID] = []
    /// 0012: when set, `activateTool` also forwards to the dispatcher's deferred switch —
    /// exactly `CanvasToolSession`'s wiring (`model.dispatcher.requestToolSwitch(_:)`) —
    /// so gesture tests can drive real tool switching through a `ToolDispatcher`.
    /// The request is always recorded in `activatedTools` as well.
    weak var dispatcher: ToolDispatcher?

    init(size: PixelSize, base: HistoryBaseStep = .openImage,
         budgetBytes: Int = HistoryStack.defaultBudgetBytes, fill: ColorRGBA8 = .white) {
        var surface = TiledSurface(size: size)
        surface.fill(fill)
        bridge = UndoBridge(state: DocumentState(image: LayeredImage(surface: surface)),
                            base: base,
                            budgetBytes: budgetBytes,
                            undoManager: NavigationUndoManager())
        // 0008's test convention: one registration is exactly one undo group.
        bridge.undoManager.groupsByEvent = false
    }

    /// 0018: a caller-built image (for multi-layer sessions).
    init(image: LayeredImage, base: HistoryBaseStep = .openImage,
         budgetBytes: Int = HistoryStack.defaultBudgetBytes) {
        bridge = UndoBridge(state: DocumentState(image: image),
                            base: base,
                            budgetBytes: budgetBytes,
                            undoManager: NavigationUndoManager())
        bridge.undoManager.groupsByEvent = false
    }

    func activateTool(_ id: ToolID) {
        activatedTools.append(id)
        dispatcher?.requestToolSwitch(id)
    }
    /// Applies to `colors` and records the call (0012).
    func setColor(_ color: ColorRGBA8, for slot: ColorSlot) {
        colors[slot] = color
        setColorCalls.append((color, slot))
    }
    func setOverlay(_ overlay: ToolOverlay?) { overlayChanges.append(overlay) }
    func invalidateCursor() { cursorInvalidations += 1 }

    func commitHistory(_ item: any HistoryItem) { bridge.commit(item) }
    func performHistory(_ item: any HistoryItem) { bridge.perform(item) }
    func updateImage(_ body: (inout LayeredImage) -> Void) {
        bridge.updateLiveState { state in body(&state.image) }
    }
}

extension BridgeToolContext {
    /// One horizontal `PaintbrushTool` stroke with a primary-button event sequence:
    /// `mouseDown` at canvas (100, `y`), `mouseDragged` to (290, `y`), `mouseUp` there.
    /// Options (`tool.paintbrush.*`) are read from `options` at stroke start.
    @MainActor
    func stroke(y: Int, using tool: PaintbrushTool = PaintbrushTool()) {
        func event(_ location: CGPoint) -> ToolEvent {
            ToolEvent(location: location, viewLocation: location, button: .primary,
                      modifiers: [], clickCount: 1, pressure: 1, timestamp: 0)
        }
        let start = CGPoint(x: 100, y: y)
        let end = CGPoint(x: 290, y: y)
        tool.mouseDown(event(start), context: self)
        tool.mouseDragged(event(end), context: self)
        tool.mouseUp(event(end), context: self)
    }
}
