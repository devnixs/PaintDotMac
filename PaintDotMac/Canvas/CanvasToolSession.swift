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
    /// The window's status bar (0014): the selection tools keep `selectionSize` live while
    /// dragging; wired by `DocumentWindowController.installToolWiring`.
    weak var statusBar: StatusBarModel?
    /// The window's marching-ants overlay (0014): the Replace-mode preview hides the
    /// current selection's ants for the duration of the drag.
    weak var marchingAntsOverlay: MarchingAntsOverlay?
    weak var router: CanvasInputRouter?
    let model: AppModel

    /// The selection-shape preview the tool is currently drawing (`nil` otherwise); the
    /// status-bar selection size follows it while it lives, else the document's selection
    /// (0014, APP-5).
    private(set) var selectionPreview: SelectionShapePreview?

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

    /// 0012 (T-14): the Color Picker's slot write — persists and updates the Colors panel
    /// through the app model (C-1).
    func setColor(_ color: ColorRGBA8, for slot: ColorSlot) {
        model.setColor(color, for: slot)
    }

    /// 0013: the document's selection (TOOL-B). A full-canvas mask is reported as `nil` —
    /// `BlendOps.mul255(c, 255) == c` for all `c`, so clipping is pixel-identical and the
    /// stroke skips the mask lookup (NF-1).
    var selection: Selection? { undoBridge?.state.selection }

    var paintClipMask: (any BrushClipMask)? {
        guard let selection, !selection.mask.isFull else { return nil }
        return selection.mask
    }

    var previousToolID: ToolID? { model.previousToolID }

    func activateTool(_ id: ToolID) {
        model.dispatcher.requestToolSwitch(id)
    }

    func setOverlay(_ overlay: ToolOverlay?) {
        overlayView?.overlay = overlay
        // 0014: a selection-shape preview (or its removal) drives the status-bar selection
        // size, and the Replace mode hides the current ants for the drag's duration.
        switch overlay {
        case .selectionShape(let preview):
            selectionPreview = preview
            marchingAntsOverlay?.suppressesSelection = preview.hidesCurrentSelection
            refreshSelectionSize()
        case nil:
            selectionPreview = nil
            marchingAntsOverlay?.suppressesSelection = false
            refreshSelectionSize()
        default:
            break
        }
    }

    /// Re-reads the status bar's selection size (0014, APP-5): the live preview wins, then
    /// the document's selection bounds (0013's tight mask bounds); empty with no selection.
    /// Called on preview changes and on every `UndoBridge.onStateChange` (any step, undo,
    /// redo, jump) through `DocumentWindowController.refreshCanvas(for:)`.
    func refreshSelectionSize() {
        statusBar?.selectionSize = SelectionSizeDisplay.size(
            preview: selectionPreview,
            selectionBounds: undoBridge?.state.selection?.bounds,
            imageSize: image.size)
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
