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

    /// The marching-ants selection outline (0013), above the canvas and below the tool
    /// overlay; `nil` without a canvas.
    private(set) weak var marchingAntsOverlay: MarchingAntsOverlay?

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
            // The marching ants (0013): same frame as the canvas, above the canvas and
            // below the tool overlay; `hitTest` returns nil so it never eats events.
            let ants = MarchingAntsOverlay(frame: canvasFrame)
            ants.autoresizingMask = [.width, .height]
            overlay.autoresizingMask = [.width, .height]
            overlay.canvasView = canvasView
            container.addSubview(overlay)
            container.addSubview(ants, positioned: .below, relativeTo: overlay)
            marchingAntsOverlay = ants
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
            // keeping the status-bar zoom in step (APP-5), redrawing the overlay (0006),
            // and keeping the ants glued to the outline (0013).
            canvasView.onTransformChange = { [weak self, weak model, weak overlayView] transform in
                model?.zoom = transform.zoom
                overlayView?.needsDisplay = true
                self?.updateMarchingAnts()
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
        bridge?.prepareForNavigation = { [weak self, weak bridge] in
            guard let self, let session = self.toolSession,
                  self.wiredModel.activeSession === session, let bridge
            else { return }
            // 0020 item 9: the bridge stamps the reason — commands commit the pending
            // edit ("Finish Pixels" first), undo/redo/jump/save route through the
            // tool's navigation hook instead.
            self.wiredModel.dispatcher.resolvePendingEdit(for: bridge.pendingEditReason)
        }
        bridge?.onStateChange = { [weak self, weak bridge] change in
            MainActor.assumeIsolated {
                self?.refreshCanvas(for: change)
                self?.followFloatingPixels(bridge: bridge)
            }
        }
        // A document attached to a fresh (or rewired) window shows its current selection
        // (0013) — opens and Revert reset it to nil, so this starts the ants hidden and the
        // status-bar selection size from the document's selection (0014).
        updateMarchingAnts()
        toolSession?.refreshSelectionSize()
    }

    /// Pushes the post-undo/redo/jump state to the canvas: `pixels` re-uploads only the
    /// touched tiles (0003 `changedTiles(since:)`), `structure` redraws everything; the
    /// zoom stays put (H-6), and the status bar's size/DPI fields follow. The selection
    /// cases (0013): `.selection` updates only the ants — no tile upload — and
    /// `.pixelsAndSelection` does both.
    private func refreshCanvas(for change: HistoryChange) {
        guard let document = document as? PaintDocument else { return }
        if let canvasView {
            switch change {
            case .pixels: canvasView.image = document.image
            case .selection:
                break   // ants only; no pixels changed, no tile upload
            case .pixelsAndSelection:
                canvasView.image = document.image
            case .structure:
                // Whole-image replacement (0008 item 12): the renderer must forget every
                // resident tile texture, not just redraw the cached ones.
                canvasView.image = document.image
                canvasView.invalidateAll()
            }
        }
        statusBarModel.update(image: document.image)
        if change.affectsSelection { updateMarchingAnts() }
        // 0014: every step, undo, redo, jump, and reset re-reads the status-bar selection
        // size (the size also follows the image size for `structure` changes).
        toolSession?.refreshSelectionSize()
    }

    /// Spec 0020 item 11, after every history-driven refresh (this window's session
    /// active): re-mirror the dispatcher's pending-edit state (undo can create or clear
    /// floating pixels without a tool event), follow floating pixels across tools —
    /// undoing "Finish Pixels" selects Move Selected Pixels again (0021's Paste lands
    /// here too) — and let the tool redraw its idle handles over the new state.
    private func followFloatingPixels(bridge: UndoBridge?) {
        guard let bridge, let session = toolSession,
              wiredModel.activeSession === session else { return }
        let dispatcher = wiredModel.dispatcher
        dispatcher.refreshPendingState()
        if let id = FloatingPixelsPolicy.toolToActivate(
            hasFloatingPixels: bridge.state.floatingPixels != nil,
            activeTool: dispatcher.activeToolID) {
            dispatcher.selectTool(id)
        }
        if dispatcher.activeToolID == .moveSelectedPixels {
            // The tool re-runs its idle-overlay logic (its `optionsDidChange` hook).
            dispatcher.optionsDidChange()
        }
    }

    /// Re-reads the marching-ants outline from the document's selection under the current
    /// transform (0013).
    private func updateMarchingAnts() {
        guard let marchingAntsOverlay, let canvasView else { return }
        let selection = (document as? PaintDocument)?.undoBridge.state.selection
        marchingAntsOverlay.update(selection: selection, transform: canvasView.transform)
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
            // 0014: the selection tools keep the status-bar selection size live and hide
            // the ants during a Replace-mode preview.
            session.statusBar = statusBarModel
            session.marchingAntsOverlay = marchingAntsOverlay
            let router = CanvasInputRouter(canvasView: canvasView, navigation: navigation,
                                           session: session, model: wiredModel)
            session.router = router
            canvasView.inputRouter = router
            toolSession = session
            inputRouter = router
            // The `document` setter may have fired before this window existed (the window
            // is lazy-loaded), in which case its attach found no session. Re-attach here so
            // both orders land the bridge and the document on the new session.
            session.document = self.document as? PaintDocument
            attachBridge()
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

    // MARK: - Selection commands (Edit menu, spec 0013)

    /// Responder-chain actions for the Edit menu (target nil; the window controller sits
    /// in the main window's chain, so they work while a floating panel is key). A focused
    /// text field keeps handling ⌘A itself — it is first in the key window's chain.
    /// (`NSResponder` declares `selectAll(_:)` without implementing it — neither
    /// `NSView` nor `NSResponder` answers the selector at runtime, which is why the item
    /// is disabled until this class handles it, as spec 0001 observed.)
    override func selectAll(_ sender: Any?) { runSelectionCommand(.selectAll) }

    @objc func deselect(_ sender: Any?) { runSelectionCommand(.deselect) }

    @objc func invertSelection(_ sender: Any?) { runSelectionCommand(.invertSelection) }

    private func runSelectionCommand(_ command: SelectionCommand) {
        guard let bridge = (document as? PaintDocument)?.undoBridge,
              !appModel.dispatcher.isGestureInProgress else { return }
        // The active tool's pending edit commits first (its own step), then the
        // selection step — once 0020 lands this call carries the command's reason.
        bridge.prepareForNavigation?()
        if let item = command.makeHistoryItem(for: bridge.state) {
            bridge.perform(item)
        }
    }

    private func selectionCommandIsEnabled(_ command: SelectionCommand) -> Bool {
        guard let bridge = (document as? PaintDocument)?.undoBridge else { return false }
        return !appModel.dispatcher.isGestureInProgress && command.isEnabled(in: bridge.state)
    }

    // MARK: - Erase / Fill Selection (Edit menu, spec 0018)

    /// Responder-chain actions for the Edit menu and the ⌫/⌦/⌥⌫ key monitor (target nil;
    /// the window controller sits in the main window's chain, so they work while a
    /// floating panel is key — PRD D-45).
    @objc func eraseSelection(_ sender: Any?) { runSelectionPixelCommand(.eraseSelection) }

    @objc func fillSelection(_ sender: Any?) { runSelectionPixelCommand(.fillSelection) }

    private func runSelectionPixelCommand(_ command: SelectionPixelCommand) {
        guard let bridge = (document as? PaintDocument)?.undoBridge,
              !appModel.dispatcher.isGestureInProgress else { return }
        Self.performSelectionPixelCommand(command, bridge: bridge, model: appModel)
    }

    /// The shared command path, also exercised by integration tests: the active tool's
    /// pending edit commits first (its own step — once 0020 lands this call carries the
    /// command's reason, and `commandFinishesFirst` covers it), then exactly one
    /// "Erase Selection" / "Fill Selection" step. The primary color is read at invocation
    /// time (C-1), and the canvas/ants refresh follows `onStateChange` (0013 handles
    /// `.pixelsAndSelection`; Fill reports `.pixels`).
    static func performSelectionPixelCommand(_ command: SelectionPixelCommand,
                                             bridge: UndoBridge, model: AppModel) {
        bridge.prepareForNavigation?()
        let item: (any HistoryItem)?
        switch command {
        case .eraseSelection: item = EraseSelection.makeHistoryItem(for: bridge.state)
        case .fillSelection: item = FillSelection.makeHistoryItem(for: bridge.state,
                                                                  color: model.colors.primary)
        }
        if let item { bridge.perform(item) }
    }

    /// Enabled for any open document (D-45(a)) unless a gesture is in flight, a tool
    /// captures the keyboard (Text, 0040 — ⌫ deletes its text), or a text field has
    /// focus: the ⌫/⌥⌫ equivalents carry no ⌘, so `validateMenuItem` is what keeps them
    /// from stealing the key from the field editor (`NSMenu.performKeyEquivalent` never
    /// fires a disabled item).
    private func selectionPixelCommandIsEnabled(_ command: SelectionPixelCommand) -> Bool {
        guard let bridge = (document as? PaintDocument)?.undoBridge,
              !appModel.dispatcher.isGestureInProgress,
              !appModel.dispatcher.activeTool.capturesKeyboard,
              !CanvasInputRouter.textInputHasFocus(in: NSApp.keyWindow ?? window)
        else { return false }
        return command.isEnabled(in: bridge.state)
    }

    // MARK: - Test seam (spec 0013)

    /// Sets the document's selection without a history step — the document stays clean
    /// (not reachable from the UI; integration tests use it before 0014 adds selection
    /// tools). The reset re-runs the open path: canvas refresh, ants, clean state.
    func setInitialSelection(_ rect: PixelRect) {
        guard let document = document as? PaintDocument,
              let selection = Selection(rect: CGRect(x: rect.x, y: rect.y,
                                                     width: rect.width, height: rect.height),
                                        canvasSize: document.image.size)
        else { return }
        let bridge = document.undoBridge
        let base: HistoryBaseStep =
            bridge.history.steps.first?.name == HistoryBaseStep.newImage.name ? .newImage : .openImage
        bridge.reset(state: DocumentState(image: bridge.state.image, selection: selection),
                     base: base)
    }

    // MARK: - Zoom commands (View menu, spec 0004)

    @objc func zoomIn(_ sender: Any?) { navigation?.zoomIn() }

    @objc func zoomOut(_ sender: Any?) { navigation?.zoomOut() }

    @objc func zoomToWindow(_ sender: Any?) { navigation?.zoomToWindow() }

    /// View > Zoom to Selection (0014, CAN-1, ⇧⌘B): fit the selection's tight bounds into
    /// the window. Disabled with no selection (PRD D-44b).
    @objc func zoomToSelection(_ sender: Any?) {
        guard let selection = (document as? PaintDocument)?.undoBridge.state.selection else { return }
        navigation?.zoomToSelection(selection.bounds)
    }

    @objc func actualSize(_ sender: Any?) { navigation?.actualSize() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(zoomIn(_:)): return navigation?.canZoomIn ?? false
        case #selector(zoomOut(_:)): return navigation?.canZoomOut ?? false
        case #selector(zoomToSelection(_:)):
            return (document as? PaintDocument)?.undoBridge.state.selection != nil
        case #selector(selectAll(_:)): return selectionCommandIsEnabled(.selectAll)
        case #selector(deselect(_:)): return selectionCommandIsEnabled(.deselect)
        case #selector(eraseSelection(_:)): return selectionPixelCommandIsEnabled(.eraseSelection)
        case #selector(fillSelection(_:)): return selectionPixelCommandIsEnabled(.fillSelection)
        case #selector(invertSelection(_:)): return selectionCommandIsEnabled(.invertSelection)
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
