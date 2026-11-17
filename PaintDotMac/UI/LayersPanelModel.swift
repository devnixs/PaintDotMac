import AppKit
import CoreGraphics
import Foundation
import Observation

/// One detached thumbnail render's output: the image plus the exact surface it was
/// rendered from, so the cache can be keyed against that surface (spec 0025 item 6).
struct ThumbnailRenderResult: Sendable {
    let id: Layer.ID
    let surface: TiledSurface
    let image: ThumbnailImage
}

/// The Layers panel's document binding (spec 0025 item 7, PRD L-5/L-1): holds the active
/// document's `LayerListModel` and forwards every row, checkbox, drag, and button action
/// to its `UndoBridge` / the document's 0024 layer commands. One instance, owned by
/// `AppModel`, shared by the single app-wide Layers panel (0006, APP-2) — 0010's pattern.
///
/// **Pending edits first** (0020 item 9): every mutating action returns early while the
/// dispatcher is mid-gesture, then calls `bridge.prepareForNavigation?()` — floating
/// pixels record their "Finish Pixels" step on the *old* active layer — and only then
/// reads `bridge.state`, so no property/visibility/move item is ever built while
/// `floatingPixels != nil`.
///
/// **Selecting a layer is not a history step** (Paint.NET, H-6): `selectLayer` writes
/// `activeLayerIndex` through `updateLiveState` — no step, no edited-state change.
///
/// Thumbnails render off the main actor in at most one `Task.detached` at a time
/// (cancelled when a newer render starts or the document switches), throttled to ≤ 4
/// renders per second while a stroke runs (NF-1), and results are only applied while the
/// layer still exists. Thumbnails are never computed on the main actor.
@MainActor
@Observable
final class LayersPanelModel {
    /// The rows and enablement to render.
    private(set) var model: LayerListModel = .empty
    /// True while the bound document has the Layer Properties sheet attached: row
    /// clicks, checkboxes, drags, double-clicks, and buttons are disabled for that
    /// document (spec item 7; follows the presenter seam's `isPresenting`).
    /// Stored, not computed: the `SheetPresenting` seam is not observable, so SwiftUI
    /// would never re-evaluate the view when `isPresenting` flips. Every open/close
    /// path calls `refresh()`, which re-reads the seam here and re-renders the panel.
    private(set) var isDocumentBusy = false
    /// +1 per rebuild, for the tests that count refreshes.
    private(set) var refreshCount: Int = 0
    /// The last rendered thumbnail per layer, keyed by layer id.
    private(set) var thumbnails: [Layer.ID: CGImage] = [:]

    /// Weak: the document owns its session and bridge, so a closed document is never
    /// kept alive (0010's pattern).
    @ObservationIgnored private weak var session: CanvasToolSession?
    @ObservationIgnored private weak var bridge: UndoBridge?
    @ObservationIgnored private weak var appModel: AppModel?

    /// Chain markers (0010): re-arming bumps the token; an in-flight chain whose token
    /// no longer matches is stale and retires.
    @ObservationIgnored private var sessionToken = 0
    @ObservationIgnored private var revisionToken = 0
    /// Coalesces rebuilds to one per run-loop turn (a live stroke mutates `state` per
    /// event; the panel rebuilds once).
    @ObservationIgnored private var pendingRefresh = false

    // MARK: - Thumbnail machinery (all main-actor decisions; rendering is detached)

    @ObservationIgnored private var thumbnailCache = ThumbnailCache()
    @ObservationIgnored private var thumbnailThrottle = ThumbnailThrottle()
    @ObservationIgnored private var renderTask: Task<[ThumbnailRenderResult], Never>?
    /// Bumped per render start; a finished task applies its results only while its
    /// generation is still current (a newer render — or a document switch — supersedes).
    @ObservationIgnored private var renderGeneration = 0
    @ObservationIgnored private var trailingTask: Task<Void, Never>?
    /// Injected clock for the throttle so tests control time; the app uses system uptime.
    @ObservationIgnored var clock: @MainActor () -> TimeInterval = {
        ProcessInfo.processInfo.systemUptime
    }

    /// The currently bound bridge (`nil` with no active document); exposed for tests.
    var boundBridge: UndoBridge? { bridge }

    /// The bound document's window controller (0024's menu actions are the panel's
    /// command targets; its presenter seam is the busy flag).
    private var boundWindowController: DocumentWindowController? {
        session?.document?.windowControllers.first as? DocumentWindowController
    }

    /// Starts unbound and unobserved (the integration tests' `LayersPanelModel()`).
    /// `AppModel.init` creates one and immediately calls `follow(_:)`.
    init() {}

    /// Follows `appModel`'s active session — called once by the owning `AppModel` at the
    /// end of its `init` (leaking `self` earlier would be a definite-initialization
    /// violation).
    func follow(_ appModel: AppModel) {
        self.appModel = appModel
        observeActiveSession()
    }

    // MARK: - Binding

    /// Binds to the active document's session, or `nil` for "no document".
    func bind(to newSession: CanvasToolSession?) {
        bind(into: newSession?.undoBridge, session: newSession)
    }

    /// Binds to a bare bridge (0010's `HistoryPanelModel.bind(to:)` shape, used by the
    /// window-less integration tests): no session, so no window controller — commands
    /// need one, row/checkbox/drag actions drive the bridge directly.
    func bind(to newBridge: UndoBridge?) {
        bind(into: newBridge, session: nil)
    }

    private func bind(into newBridge: UndoBridge?, session newSession: CanvasToolSession?) {
        observeActiveSession()   // re-arm the active-session observer
        if bridge !== newBridge || session !== newSession {
            bridge = newBridge
            session = newSession
            // Switching documents: the running render is stale, and the other document
            // starts with an empty thumbnail cache.
            renderTask?.cancel()
            trailingTask?.cancel()
            renderGeneration += 1   // retire any finished-but-unapplied result
            thumbnailCache = ThumbnailCache()
            thumbnails = [:]
            observeBoundBridge()
        }
        refresh()
    }

    /// Rebuilds from the (weakly held) bridge; `.empty` when it is gone. Also
    /// re-publishes `isDocumentBusy` (the presenter seam is only observed through here).
    func refresh() {
        pendingRefresh = false
        if let bridge {
            model = LayerListModel(image: bridge.state.image)
        } else {
            model = .empty
        }
        isDocumentBusy = boundWindowController?.layerPropertiesPresenter.isPresenting ?? false
        refreshCount += 1
        scheduleThumbnails()
    }

    // MARK: - Panel actions (all: gesture guard → prepareForNavigation → act)

    /// A row click: make layer `index` active. Not a history step and not an edit
    /// (Paint.NET, H-6); with pixels floating it first records "Finish Pixels" on the
    /// layer they were lifted from, before the active layer changes.
    func selectLayer(index: Int) {
        guard canMutate, let bridge,
              bridge.state.image.layers.indices.contains(index),
              bridge.state.image.activeLayerIndex != index else { return }
        bridge.prepareForNavigation?()
        bridge.updateLiveState { $0.image.activeLayerIndex = index }
        refresh()
    }

    /// The row's visibility checkbox: one "Hide Layer"/"Show Layer" step; it does not
    /// change the active layer (H-6).
    func toggleVisibility(index: Int) {
        guard canMutate, let bridge else { return }
        bridge.prepareForNavigation?()
        let state = bridge.state
        guard let item = LayerListModel(image: state.image)
            .visibilityToggle(forLayerIndex: index, in: state.image) else { return }
        bridge.perform(item)
        refresh()
    }

    /// The List's `.onMove`: a drag across several positions is one "Move Layer Up"/
    /// "Move Layer Down" step; a no-op drop, multi-selection, or out-of-range input does
    /// nothing.
    func move(displaySource: IndexSet, displayDestination: Int) {
        guard canMutate, let bridge,
              let target = model.moveTarget(displaySource: displaySource,
                                            displayDestination: displayDestination) else { return }
        bridge.prepareForNavigation?()
        guard let item = LayerMove.makeHistoryItem(from: target.from, to: target.to,
                                                   for: bridge.state) else { return }
        bridge.perform(item)
        refresh()
    }

    /// A footer button: forwards 0024's menu action to the bound document's window
    /// controller, so menu and panel behave identically (L-1) — those actions already go
    /// through `LayerCommandRunner.run` (pending edit first).
    func perform(_ command: LayerPanelCommand) {
        guard canMutate, model.isEnabled(command),
              let target = boundWindowController else { return }
        let action: Selector
        switch command {
        case .addNewLayer: action = #selector(DocumentWindowController.addNewLayer(_:))
        case .deleteLayer: action = #selector(DocumentWindowController.deleteLayer(_:))
        case .duplicateLayer: action = #selector(DocumentWindowController.duplicateLayer(_:))
        case .mergeLayerDown: action = #selector(DocumentWindowController.mergeLayerDown(_:))
        case .moveLayerUp: action = #selector(DocumentWindowController.moveLayerUp(_:))
        case .moveLayerDown: action = #selector(DocumentWindowController.moveLayerDown(_:))
        case .layerProperties: action = #selector(DocumentWindowController.showLayerProperties(_:))
        }
        NSApp.sendAction(action, to: target, from: self)
    }

    /// A row double-click: Paint.NET opens the dialog for the clicked layer, which
    /// becomes active.
    func openProperties(index: Int) {
        selectLayer(index: index)
        perform(.layerProperties)
    }

    /// The shared guard for every mutating panel action: no gesture in flight (0006),
    /// and the document's Layer Properties sheet must not be attached (spec item 7).
    private var canMutate: Bool {
        appModel?.dispatcher.isGestureInProgress != true && !isDocumentBusy
    }

    // MARK: - Thumbnails (off the main actor, throttled, cancellable)

    private func scheduleThumbnails() {
        guard let bridge else {
            renderTask?.cancel()
            trailingTask?.cancel()
            thumbnails = [:]
            return
        }
        let image = bridge.state.image
        let liveIDs = Set(image.layers.map(\.id))
        thumbnailCache.retain(only: liveIDs)
        thumbnails = thumbnails.filter { liveIDs.contains($0.key) }
        let pending = image.layers.compactMap { layer -> (id: Layer.ID, surface: TiledSurface)? in
            thumbnailCache.needsRender(layerID: layer.id, surface: layer.surface)
                ? (layer.id, layer.surface) : nil
        }
        guard !pending.isEmpty else { return }
        switch thumbnailThrottle.requestRender(now: clock()) {
        case .renderNow:
            startRender(pending)
        case .scheduleAt(let time):
            scheduleTrailing(at: time)
        }
    }

    /// One trailing render at `time`. What it renders is recomputed when it fires (the
    /// surfaces may have moved on again in the meantime), so a request that becomes
    /// fully fresh meanwhile renders nothing.
    private func scheduleTrailing(at time: TimeInterval) {
        trailingTask?.cancel()
        let delay = max(0, time - clock())
        trailingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            // Re-check by the *current* clock: the window may have opened meanwhile (or a
            // test advanced the injected clock), and the surfaces may have changed again.
            guard let bridge = self.bridge else { return }
            let live = bridge.state.image.layers
            let current = live.compactMap { layer -> (id: Layer.ID, surface: TiledSurface)? in
                self.thumbnailCache.needsRender(layerID: layer.id, surface: layer.surface)
                    ? (layer.id, layer.surface) : nil
            }
            guard !current.isEmpty else { return }
            if case .renderNow = self.thumbnailThrottle.requestRender(now: self.clock()) {
                self.startRender(current)
            } else {
                self.scheduleTrailing(at: time)
            }
        }
    }

    /// One `Task.detached` at a time: a newer render cancels the in-flight one, and a
    /// cancelled or superseded result never overwrites a newer one (it is only applied
    /// through the task that is still current).
    private func startRender(_ pending: [(id: Layer.ID, surface: TiledSurface)]) {
        trailingTask?.cancel()
        renderTask?.cancel()
        thumbnailThrottle.didStartRender(at: clock())
        // `TiledSurface` is copy-on-write: passing the values out of the main actor
        // shares the tile buffers without copying pixels; the cache pin (item 6) keeps
        // the rendered-from surfaces alive.
        let task = Task.detached(priority: .utility) { () -> [ThumbnailRenderResult] in
            let renderer = ThumbnailRenderer()
            var results: [ThumbnailRenderResult] = []
            do {
                for item in pending {
                    results.append(ThumbnailRenderResult(id: item.id, surface: item.surface,
                                                         image: try renderer.render(item.surface)))
                }
            } catch {
                return []   // cancelled or failed: nothing to apply
            }
            return results
        }
        renderTask = task
        renderGeneration += 1
        let generation = renderGeneration
        Task { @MainActor [weak self] in
            let results = await task.value
            guard let self, !Task.isCancelled, self.renderGeneration == generation else { return }
            self.storeThumbnails(results)
        }
    }

    /// Applies finished results on the main actor — dropped when the layer no longer
    /// exists; a result is always cached against the exact surface it came from, so a
    /// newer generation triggers another (throttled) render.
    private func storeThumbnails(_ results: [ThumbnailRenderResult]) {
        guard let bridge, !results.isEmpty else { return }
        let liveIDs = Set(bridge.state.image.layers.map(\.id))
        var changed = false
        for result in results {
            guard liveIDs.contains(result.id), let cgImage = result.image.cgImage else { continue }
            thumbnailCache.store(result.image, for: result.id, surface: result.surface)
            thumbnails[result.id] = cgImage
            changed = true
        }
        if changed {
            // Surfaces may have moved on while this render ran — request the next
            // (throttled) pass.
            scheduleThumbnails()
        }
    }

    // MARK: - Observation (re-armed after each change, like 0010)

    private func observeActiveSession() {
        guard let appModel else { return }
        sessionToken += 1
        let token = sessionToken
        withObservationTracking {
            _ = appModel.activeSessionGeneration
        } onChange: { [weak self, weak appModel] in
            // Observation notifies on the main actor: `activeSessionGeneration` is only
            // ever mutated from `@MainActor` code (`AppModel.setActiveSession`).
            MainActor.assumeIsolated {
                guard let self, self.sessionToken == token else { return }
                self.bind(to: appModel?.activeSession)
            }
        }
    }

    /// Observes the bound bridge's `state` *and* `historyRevision`: commits, performs,
    /// undo/redo, and jumps bump the revision; `updateLiveState` (select-layer, live
    /// dialog preview) mutates only `state` — observing both is what refreshes the panel
    /// after every kind of change. Re-armed per change; the rebuild itself coalesces to
    /// one per run-loop turn.
    private func observeBoundBridge() {
        revisionToken += 1
        let token = revisionToken
        guard let bridge else { return }
        withObservationTracking {
            _ = bridge.state
            _ = bridge.historyRevision
        } onChange: { [weak self, weak bridge] in
            MainActor.assumeIsolated {
                guard let self, self.revisionToken == token, self.bridge === bridge else {
                    return
                }
                self.observeBoundBridge()
                self.scheduleRefresh()
            }
        }
    }

    private func scheduleRefresh() {
        guard !pendingRefresh else { return }
        pendingRefresh = true
        Task { @MainActor [weak self] in
            guard let self, self.pendingRefresh else { return }
            self.refresh()
        }
    }
}
