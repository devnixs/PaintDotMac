import AppKit

/// The only code that changes the canvas transform for navigation (spec 0004, CAN-1/CAN-2):
/// zoom commands, pinch, ⌘+scroll zoom, scroll/Space-drag pan, and the status-bar cursor
/// field. One per document window, owned by `DocumentWindowController`; 0006's
/// `CanvasInputRouter` calls `magnify`/`scrollWheel`/Space first and its Pan tool reuses
/// `beginPan`/`continuePan`/`endPan`.
@MainActor
final class CanvasNavigation {
    /// Space's virtual key code (spec 0004; system shortcuts with ⌘/⌥/⌃ pass through).
    static let spaceKeyCode: UInt16 = 49

    private weak var canvasView: CanvasView?
    private weak var statusBar: StatusBarModel?
    private(set) var spacePan = SpacePanState()
    private var panLastViewPoint: CGPoint?
    /// Losing key focus or closing the window must never leave the canvas armed or panning.
    /// The boxes remove themselves on deinit (Swift 6 deinit isolation).
    private var resignKeyObserver: NotificationObserverBox?
    private var windowCloseObserver: NotificationObserverBox?

    init(canvasView: CanvasView, statusBar: StatusBarModel,
         notificationCenter: NotificationCenter = .default) {
        self.canvasView = canvasView
        self.statusBar = statusBar
        canvasView.navigation = self
        // Assigned after `self` is fully initialized (the handlers reference `self` weakly).
        resignKeyObserver = NotificationObserverBox(
            center: notificationCenter, name: NSWindow.didResignKeyNotification,
            object: canvasView.window
        ) { [weak self] in
            Task { @MainActor [weak self] in self?.reset() }
        }
        windowCloseObserver = NotificationObserverBox(
            center: notificationCenter, name: NSWindow.willCloseNotification,
            object: canvasView.window
        ) { [weak self] in
            Task { @MainActor [weak self] in self?.reset() }
        }
    }

    // MARK: - Transform access

    /// The transform 0004 last assigned to `CanvasView`; 0006's `CanvasNavigating`
    /// conformance (extension file) exposes it to tools.
    var currentTransform: CanvasTransform? { canvasView?.transform }

    private var viewCenter: CGPoint {
        guard let view = canvasView else { return .zero }
        return CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    private func apply(_ updated: CanvasTransform) {
        canvasView?.transform = updated  // 0003's API: redraws and fires `onTransformChange`
    }

    // MARK: - Zoom commands (View menu)

    var canZoomIn: Bool { ZoomLevels.canZoomIn(from: currentTransform?.zoom ?? 1) }
    var canZoomOut: Bool { ZoomLevels.canZoomOut(from: currentTransform?.zoom ?? 1) }

    func zoomIn() {
        guard let transform = currentTransform,
              let target = ZoomLevels.nextLarger(than: transform.zoom) else { return }
        setZoom(target, anchoredAtView: viewCenter)
    }

    func zoomOut() {
        guard let transform = currentTransform,
              let target = ZoomLevels.nextSmaller(than: transform.zoom) else { return }
        setZoom(target, anchoredAtView: viewCenter)
    }

    func actualSize() { setZoom(1.0, anchoredAtView: viewCenter) }

    func zoomToWindow() {
        guard let transform = currentTransform else { return }
        apply(transform.fittedToWindow())
    }

    /// The shared zoom entry point (0006's Zoom tool and 0014's Zoom to Selection use it).
    func setZoom(_ zoom: Double, anchoredAtView point: CGPoint) {
        guard let transform = currentTransform else { return }
        apply(transform.zoomed(to: zoom, anchoredAt: point))
    }

    // MARK: - Gestures

    /// Pinch: zoom around the pointer (CAN-2). `magnification` is `NSEvent.magnification`.
    func magnify(magnification: Double, atView point: CGPoint) {
        guard let transform = currentTransform else { return }
        let target = ZoomLevels.zoom(transform.zoom, magnifiedBy: magnification)
        apply(transform.zoomed(to: target, anchoredAt: point))
    }

    /// ⌘+scroll zooms around the pointer (Paint.NET's Ctrl+wheel); plain scroll pans
    /// (CAN-2). `deltaX/deltaY` are `NSEvent.scrollingDeltaX/Y` (natural scrolling already
    /// applied by AppKit), `isPrecise` is `NSEvent.hasPreciseScrollingDeltas`.
    func scroll(deltaX: Double, deltaY: Double, isPrecise: Bool,
                zoomModifiers: Bool, atView point: CGPoint) {
        guard let transform = currentTransform else { return }
        if zoomModifiers {
            let target = ZoomLevels.zoom(transform.zoom, scrolledBy: deltaY, isPrecise: isPrecise)
            apply(transform.zoomed(to: target, anchoredAt: point))
        } else {
            let delta = ScrollPanDelta.viewDelta(
                scrollingDeltaX: deltaX, scrollingDeltaY: deltaY, isPrecise: isPrecise
            )
            apply(transform.panned(byView: delta))
        }
    }

    // MARK: - Space panning

    /// `true` when consumed (Space without ⌘/⌥/⌃ — system shortcuts pass through).
    @discardableResult
    func keyDown(_ event: NSEvent) -> Bool {
        guard event.keyCode == Self.spaceKeyCode,
              event.modifierFlags.isDisjoint(with: [.command, .option, .control])
        else { return false }
        spacePan.spaceDown(isRepeat: event.isARepeat)
        updateCursor()
        return true
    }

    @discardableResult
    func keyUp(_ event: NSEvent) -> Bool {
        guard event.keyCode == Self.spaceKeyCode,
              event.modifierFlags.isDisjoint(with: [.command, .option, .control])
        else { return false }
        spacePan.spaceUp()
        updateCursor()
        return true
    }

    /// `true` when this mouse-down pans (Space armed). Otherwise the caller forwards the
    /// event (in 0004 a plain drag does nothing; 0006 routes it to the active tool).
    @discardableResult
    func mouseDown(atView point: CGPoint) -> Bool {
        guard spacePan.mouseDown() else { return false }
        updateCursor()
        beginPan(atView: point)
        return true
    }

    func mouseDragged(toView point: CGPoint) {
        if spacePan.isPanning { continuePan(toView: point) }
        updateCursorPosition(atView: point)
    }

    func mouseUp() {
        guard spacePan.isPanning else { return }
        spacePan.mouseUp()
        endPan()
        updateCursor()
    }

    /// Pan drag steps, also used by 0006's Pan tool.
    func beginPan(atView point: CGPoint) { panLastViewPoint = point }

    func continuePan(toView point: CGPoint) {
        guard let last = panLastViewPoint, let transform = currentTransform else {
            panLastViewPoint = point
            return
        }
        panLastViewPoint = point
        apply(transform.panned(byView: CGVector(dx: point.x - last.x, dy: point.y - last.y)))
    }

    func endPan() { panLastViewPoint = nil }

    /// Window resigns key, app deactivates, document closes.
    func reset() {
        spacePan.reset()
        endPan()
        updateCursor()
    }

    // MARK: - Cursor and status bar

    func updateCursor() {
        switch spacePan.cursor {
        case .none: NSCursor.arrow.set()
        case .openHand: NSCursor.openHand.set()
        case .closedHand: NSCursor.closedHand.set()
        }
    }

    func cursorMoved(toView point: CGPoint) { updateCursorPosition(atView: point) }

    func cursorExited() { statusBar?.cursorPixel = nil }

    private func updateCursorPosition(atView point: CGPoint) {
        guard let transform = currentTransform else { return }
        statusBar?.setCursor(canvasPoint: transform.viewToCanvas(point))
    }

    /// Window resize (live included): keep the zoom and the view-center point, re-clamp.
    func viewResized(to size: CGSize) {
        guard let transform = currentTransform else { return }
        apply(transform.resized(to: size))
    }
}
