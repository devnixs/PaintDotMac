import AppKit
import CoreGraphics
import SwiftUI

/// One window per document (APP-1). Built in code with no nib; the content view is a stack of
/// the Metal `CanvasView` (0003) filling the window above the SwiftUI status bar (0004,
/// APP-5), or a label in place of the canvas when Metal is unavailable.
@MainActor
final class DocumentWindowController: NSWindowController, NSMenuItemValidation, NSWindowDelegate {
    /// The become-main/close hooks. AppKit never makes a programmatic window controller
    /// its window's delegate, so these notifications are observed directly — with the
    /// same box pattern `CanvasNavigation` already uses (spec 0006).
    private var windowMainObserver: NotificationObserverBox?
    private var windowCloseObserver: NotificationObserverBox?
    /// Native window tabs: `.automatic` follows the user's "Prefer tabs when opening documents"
    /// setting, and the shared tabbing identifier lets Window > Merge All Windows tab documents
    /// together (PRD §5.1 APP-1, D-36).
    static let tabbingIdentifier = "com.thera-engineering.paintdotmac.document"

    /// Tests and later code find document windows with this identifier, separate from the
    /// floating panels 0006 adds.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("documentWindow")

    private static let minimumContentSize = CGSize(width: 480, height: 360)
    private static let visibleFrameFraction: CGFloat = 0.8

    /// The window's canvas, or `nil` when Metal was unavailable and the window shows the
    /// `canvas.unavailable` label instead.
    private(set) weak var canvasView: CanvasView?

    /// The document window's status bar state (0004, APP-5).
    private(set) var statusBarModel: StatusBarModel

    /// The window's zoom/pan controller (0004); `nil` when Metal is unavailable (no canvas).
    private(set) var navigation: CanvasNavigation?

    /// The window's tool overlay (0006), above the canvas; `nil` without a canvas.
    private(set) weak var overlayView: ToolOverlayView?

    /// The window's `ToolContext` (0006); `nil` when Metal is unavailable (no canvas).
    private(set) var toolSession: CanvasToolSession?

    /// The window's event router (0006); `nil` when Metal is unavailable (no canvas).
    private(set) var inputRouter: CanvasInputRouter?

    /// The app state this window routes tools through. `DocumentHarness` installs a
    /// per-test model; the rewiring below keeps session, router, and options bar in step.
    var appModel: AppModel {
        get { wiredModel }
        set { rewiring(to: newValue) }
    }

    private var wiredModel: AppModel

    /// The hosted tool options bar (0006); rebound when `appModel` is replaced.
    private var optionsBarHosting: NSHostingView<AnyView>?

    /// `nonisolated` because AppKit's save path calls this off the main thread (its
    /// file-coordinator queue), where a MainActor entry check would trap; the window-title
    /// work itself always runs on the main thread.
    override nonisolated func synchronizeWindowTitleWithDocumentName() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { synchronizeWindowTitleWithDocumentNameOnMain() }
        } else {
            DispatchQueue.main.async { self.synchronizeWindowTitleWithDocumentNameOnMain() }
        }
    }

    @MainActor private func synchronizeWindowTitleWithDocumentNameOnMain() {
        super.synchronizeWindowTitleWithDocumentName()
    }

    init(image: LayeredImage, appModel: AppModel = .shared) {
        let backingScale = NSScreen.main?.backingScaleFactor ?? 1
        let contentSize = Self.initialContentSize(
            imageSize: CGSize(width: image.size.width, height: image.size.height),
            visibleFrameSize: NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900),
            backingScale: backingScale
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.tabbingMode = .automatic
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.identifier = Self.windowIdentifier
        window.minSize = CGSize(width: 320, height: 240)

        // The status bar (APP-5): a fixed-height strip at the bottom of the content view;
        // the tool options bar (APP-4, 0006) a fixed strip at the top; the canvas fills
        // the rest. Built before `super.init` (Swift requires every stored property
        // initialized there).
        statusBarModel = StatusBarModel(imageSize: image.size, dpi: image.dpi, zoom: 1)
        wiredModel = appModel
        super.init(window: window)

        let statusBarHeight = StatusBarView.statusBarHeight
        let optionsBarHeight = ToolOptionsBar.barHeight
        let canvasFrame = NSRect(x: 0, y: statusBarHeight,
                                 width: contentSize.width,
                                 height: max(0, contentSize.height - statusBarHeight - optionsBarHeight))
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))

        let model = statusBarModel
        let statusBar = NSHostingView(rootView: StatusBarView(model: model))
        statusBar.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: statusBarHeight)
        statusBar.autoresizingMask = [.width]

        let canvas = CanvasView(frame: canvasFrame)
        if canvas.isMetalAvailable {
            canvas.autoresizingMask = [.width, .height]
            canvasView = canvas
            // Space and later tool keys need the canvas in the responder chain first.
            window.initialFirstResponder = canvas
        } else {
            NSLog("PaintDotMac: Metal canvas unavailable: \(String(describing: canvas.metalFailure))")
            let placeholder = Self.metalUnavailableLabel()
            placeholder.frame = canvasFrame
            placeholder.autoresizingMask = [.width, .height]
            container.addSubview(placeholder)
        }
        if let canvasView {
            container.addSubview(canvasView)
            // The overlay (0006) sits above the canvas with the same frame and tracking;
            // `hitTest` returns nil so it never eats events.
            let overlay = ToolOverlayView(frame: canvasFrame)
            overlay.autoresizingMask = [.width, .height]
            overlay.canvasView = canvasView
            container.addSubview(overlay)
            overlayView = overlay
        }
        container.addSubview(statusBar)

        // The tool options bar (APP-4): full width, at the top of the content view — the
        // highest minY of the three strips in this non-flipped container. `installToolWiring`
        // installs the real content.
        let optionsBar = NSHostingView(rootView: AnyView(EmptyView()))
        optionsBar.frame = NSRect(x: 0, y: contentSize.height - optionsBarHeight,
                                  width: contentSize.width, height: optionsBarHeight)
        optionsBar.autoresizingMask = [.width, .minYMargin]
        container.addSubview(optionsBar)
        optionsBarHosting = optionsBar

        window.contentView = container
        if let canvasView {
            // Only valid once the view joined the window.
            window.makeFirstResponder(canvasView)
        }

        if let canvasView {
            // One hook covers every transform change — initial zoom, resize, navigation —
            // keeping the status-bar zoom in step (APP-5) and redrawing the overlay (0006).
            canvasView.onTransformChange = { [weak model, weak overlayView] transform in
                model?.zoom = transform.zoom
                overlayView?.needsDisplay = true
            }
            navigation = CanvasNavigation(canvasView: canvasView, statusBar: model)
            // Assigning the image after the view joined the window lets the initial zoom
            // use the window's real backing scale (CAN-6).
            canvasView.image = image
        }
        installToolWiring()

        windowMainObserver = NotificationObserverBox(
            center: .default, name: NSWindow.didBecomeMainNotification, object: window
        ) { [weak self] in
            MainActor.assumeIsolated { self?.handleWindowDidBecomeMain() }
        }
        // Close-path cleanup (session, cursor hook, panels) — see `windowCloseObserver`.
        windowCloseObserver = NotificationObserverBox(
            center: .default, name: NSWindow.willCloseNotification, object: window
        ) { [weak self] in
            MainActor.assumeIsolated { self?.handleWindowWillClose() }
        }

        shouldCascadeWindows = true
        // The window's undo manager comes from the document's bridge (0008), and the
        // field editor keeps typing on the window's own manager.
        window.delegate = self
        window.center()
    }

    // MARK: - Undo manager and history refresh (spec 0008)

    /// Edit > Undo/Redo validate and act through this manager (PRD E-1: the Edit menu and
    /// the History panel stay in sync).
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        (document as? PaintDocument)?.undoBridge.undoManager
    }

    /// Called from the `document` setter: hand the bridge to the session and hook the
    /// canvas refresh (0003 re-uploads exactly the changed tiles) and the save-time tool
    /// commit. `weak self`: the document outlives no window, and the document owns the
    /// bridge, so a stale window must not extend the bridge's life.
    private func attachBridge() {
        let bridge = (document as? PaintDocument)?.undoBridge
        toolSession?.attachUndoBridge(bridge)
        bridge?.prepareForNavigation = { [weak self] in
            guard let self, let session = self.toolSession,
                  self.wiredModel.activeSession === session
            else { return }
            self.wiredModel.dispatcher.commitPendingEdit()
        }
        bridge?.onStateChange = { [weak self] change in
            MainActor.assumeIsolated { self?.refreshCanvas(for: change) }
        }
    }

    /// Pushes the post-undo/redo/jump state to the canvas: `pixels` re-uploads only the
    /// touched tiles (0003 `changedTiles(since:)`), `structure` redraws everything; the
    /// zoom stays put (H-6), and the status bar's size/DPI fields follow.
    private func refreshCanvas(for change: HistoryChange) {
        guard let document = document as? PaintDocument else { return }
        if let canvasView {
            switch change {
            case .pixels: canvasView.image = document.image
            case .structure:
                canvasView.image = document.image
                canvasView.needsDisplay = true
            }
        }
        statusBarModel.update(image: document.image)
    }

    // MARK: - Tool wiring (spec 0006)

    /// (Re)creates this window's session and router for `wiredModel` and rebinds the tool
    /// options bar.
    private func installToolWiring() {
        inputRouter?.detach()
        canvasView?.inputRouter = nil
        if let canvasView, let navigation, let overlayView {
            let session = CanvasToolSession(canvasView: canvasView, navigation: navigation,
                                            overlayView: overlayView, model: wiredModel)
            let router = CanvasInputRouter(canvasView: canvasView, navigation: navigation,
                                           session: session, model: wiredModel)
            session.router = router
            canvasView.inputRouter = router
            toolSession = session
            inputRouter = router
        } else {
            toolSession = nil
            inputRouter = nil
        }
        optionsBarHosting?.rootView = AnyView(ToolOptionsBar(model: wiredModel) { [weak self] in
            guard let self, let canvas = self.canvasView else { return }
            // Tool keys work again right after editing an option value.
            self.window?.makeFirstResponder(canvas)
        })
    }

    private func rewiring(to model: AppModel) {
        guard model !== wiredModel else { return }
        if wiredModel.activeSession === toolSession {
            wiredModel.setActiveSession(nil)
        }
        wiredModel = model
        installToolWiring()
    }

    override var document: AnyObject? {
        get { super.document }
        set {
            super.document = newValue
            toolSession?.document = newValue as? PaintDocument
            attachBridge()
        }
    }

    // MARK: - Window open/close reporting (spec 0006)

    /// Fired by `windowMainObserver`: this window's session becomes the active one.
    private func handleWindowDidBecomeMain() {
        guard let toolSession else { return }
        wiredModel.setActiveSession(toolSession)
        PanelController.current?.refresh()
    }

    /// The close-path cleanup, fired by `windowCloseObserver`: this window's session is no
    /// longer usable, the router's cursor hook is gone, and the panels must re-evaluate
    /// "is there still a document window?" with this window already counted out
    /// (spec 0006, PRD §5.1 APP-2).
    private func handleWindowWillClose() {
        if wiredModel.activeSession === toolSession {
            wiredModel.setActiveSession(nil)
        }
        inputRouter?.detach()
        PanelController.current?.refresh(excludingWindow: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")  // the app loads no nibs; nothing can reach this
    }

    // MARK: - Zoom commands (View menu, spec 0004)

    @objc func zoomIn(_ sender: Any?) { navigation?.zoomIn() }

    @objc func zoomOut(_ sender: Any?) { navigation?.zoomOut() }

    @objc func zoomToWindow(_ sender: Any?) { navigation?.zoomToWindow() }

    @objc func actualSize(_ sender: Any?) { navigation?.actualSize() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(zoomIn(_:)): return navigation?.canZoomIn ?? false
        case #selector(zoomOut(_:)): return navigation?.canZoomOut ?? false
        default: return true
        }
    }

    /// Shown centered in place of the canvas when no Metal device or renderer is available.
    /// Not reachable on supported hardware; logged by `init`.
    private static func metalUnavailableLabel() -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: "Metal is not available on this Mac.")
        label.setAccessibilityIdentifier("canvas.unavailable")
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    /// The window content size for an image of `imageSize` device pixels on a screen whose
    /// visible frame is `visibleFrameSize` points at `backingScale` device pixels per point.
    /// The image size is first converted to points (`imageSize / backingScale` — at 100 % an
    /// image pixel is one device pixel, CAN-6), then 0001's formula applies unchanged: per
    /// axis `min(max(image, minimum), max(maximum, minimum))` with
    /// `maximum = floor(visible × 0.8)` and `minimum = (480, 360)`. A `backingScale` ≤ 0 or
    /// non-finite is treated as 1.
    static func initialContentSize(imageSize: CGSize, visibleFrameSize: CGSize,
                                   backingScale: CGFloat) -> CGSize {
        let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        let imageSizeInPoints = CGSize(width: imageSize.width / scale, height: imageSize.height / scale)
        let maximum = CGSize(
            width: (visibleFrameSize.width * visibleFrameFraction).rounded(.down),
            height: (visibleFrameSize.height * visibleFrameFraction).rounded(.down)
        )
        let minimum = minimumContentSize
        return CGSize(
            width: min(max(imageSizeInPoints.width, minimum.width), max(maximum.width, minimum.width)),
            height: min(max(imageSizeInPoints.height, minimum.height), max(maximum.height, minimum.height))
        )
    }
}
