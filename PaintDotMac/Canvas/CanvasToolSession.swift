import AppKit

/// The main document window's `ToolContext` (spec 0006), one per document window. Pixels
/// stay untouched here: `image` is read-only until 0008 adds history-backed writes.
@MainActor
final class CanvasToolSession: ToolContext {
    /// Set by `DocumentWindowController.setDocument(_:)`; a session whose document vanished
    /// reports the 1×1 placeholder — never a crash.
    weak var document: PaintDocument?

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

    var image: LayeredImage {
        document?.image ?? .blank(size: PixelSize(width: 1, height: 1), fill: .clear)
    }

    var transform: CanvasTransform { canvasView?.transform ?? navigation.transform }

    var navigation: any CanvasNavigating { canvasNavigation }

    var options: any ToolOptionStore { model.toolOptions }

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
}
