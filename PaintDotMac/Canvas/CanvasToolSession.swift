import AppKit

/// The main document window's `ToolContext` (spec 0006), one per document window. All
/// pixel writes flow through the document's `UndoBridge` (0008, AGENTS rule 2).
@MainActor
final class CanvasToolSession: ToolContext {
    /// Set by `DocumentWindowController.setDocument(_:)`; a session whose document vanished
    /// reports the 1×1 placeholder — never a crash.
    weak var document: PaintDocument?

    /// The document's undo bridge (0008), attached by `DocumentWindowController` whenever
    /// a document attaches; `nil` only before a document exists — history calls then no-op
    /// instead of crashing. 0010's History panel reaches the active document's history
    /// through `AppModel.activeSession?.undoBridge`.
    private(set) var undoBridge: UndoBridge?

    private weak var canvasView: CanvasView?
    private let canvasNavigation: CanvasNavigation
    private weak var overlayView: ToolOverlayView?
    weak var router: CanvasInputRouter?
    let model: AppModel

    init(canvasView: CanvasView, navigation: CanvasNavigation,
         overlayView: ToolOverlayView, model: AppModel) {
        self.canvasView = canvasView
        self.canvasNavigation = navigation
        self.overlayView = overlayView
        self.model = model
    }

    func attachUndoBridge(_ bridge: UndoBridge?) { undoBridge = bridge }

    var image: LayeredImage {
        undoBridge?.state.image
            ?? document?.image
            ?? .blank(size: PixelSize(width: 1, height: 1), fill: .clear)
    }

    var transform: CanvasTransform { canvasView?.transform ?? navigation.transform }

    var navigation: any CanvasNavigating { canvasNavigation }

    var options: any ToolOptionStore { model.toolOptions }

    var colors: ColorSelection { model.colors }

    /// 0013 returns the selection mask; until then nothing clips painting (spec 0009).
    var paintClipMask: (any BrushClipMask)? { nil }

    var previousToolID: ToolID? { model.previousToolID }

    func activateTool(_ id: ToolID) {
        model.dispatcher.requestToolSwitch(id)
    }

    func setOverlay(_ overlay: ToolOverlay?) {
        overlayView?.overlay = overlay
    }

    func invalidateCursor() {
        router?.refreshCursor()
    }

    // MARK: - History (spec 0008)

    func commitHistory(_ item: any HistoryItem) {
        undoBridge?.commit(item)
    }

    func performHistory(_ item: any HistoryItem) {
        undoBridge?.perform(item)
    }

    func updateImage(_ body: (inout LayeredImage) -> Void) {
        undoBridge?.updateLiveState { state in body(&state.image) }
        // Live tool writes must reach the screen in this frame (spec 0009 *Display*):
        // `CanvasView` draws on demand (`isPaused`), and the 0003 renderer uploads exactly
        // the tiles `changedTiles(since:)` reports in that draw. Without the request a
        // stroke would only appear at commit (mouse-up) or the next transform change.
        canvasView?.needsDisplay = true
    }
}
