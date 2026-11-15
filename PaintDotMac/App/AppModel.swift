import Foundation
import Observation

/// App-wide observable state (spec 0006): the tool dispatcher and its mirrors, the tool
/// options store, the active document window's tool session, and the four panels'
/// visibility. Later specs add init parameters with defaults (0007 adds its color store).
@MainActor
@Observable
final class AppModel {
    /// Created on first use by `AppDelegate`.
    static let shared = AppModel()

    @ObservationIgnored let dispatcher: ToolDispatcher
    @ObservationIgnored private let registry: ToolRegistry
    @ObservationIgnored private let defaults: UserDefaults

    /// Mirrors of the dispatcher's state, updated from `dispatcher.onStateChange`.
    private(set) var activeToolID: ToolID
    private(set) var previousToolID: ToolID?
    private(set) var hasPendingToolEdit: Bool

    let toolOptions: UserDefaultsToolOptionStore

    /// The document window whose canvas is the dispatcher's context (0010/0025's panels
    /// observe `activeSessionGeneration`).
    @ObservationIgnored private(set) weak var activeSession: CanvasToolSession?
    private(set) var activeSessionGeneration: Int = 0

    /// The tool options bar / active tool changed while a pointer may sit over a canvas;
    /// routers register here to re-query their cursor immediately.
    @ObservationIgnored private var cursorRefreshHooks: [UUID: @MainActor () -> Void] = [:]

    private var panelVisibility: [PanelKind: Bool] = [:]

    init(defaults: UserDefaults = AppDefaults.shared, registry: ToolRegistry = .standard()) {
        let dispatcher = ToolDispatcher(registry: registry)
        self.dispatcher = dispatcher
        self.registry = registry
        self.defaults = defaults
        self.activeToolID = dispatcher.activeToolID
        self.previousToolID = dispatcher.previousToolID
        self.hasPendingToolEdit = dispatcher.hasPendingEdit
        self.toolOptions = UserDefaultsToolOptionStore(defaults: defaults)
        for kind in PanelKind.allCases {
            // Default true when missing or not a Bool (spec 0006).
            panelVisibility[kind] = (defaults.object(forKey: kind.visibilityDefaultsKey) as? Bool) ?? true
        }
        // Options the tools write flow back to the live tool (and, via `revision`, to the
        // options bar).
        toolOptions.onChange = { [dispatcher] _ in
            dispatcher.optionsDidChange()
        }
        dispatcher.onStateChange = { [weak self] in
            self?.mirrorDispatcherState()
        }
    }

    private func mirrorDispatcherState() {
        let toolChanged = dispatcher.activeToolID != activeToolID
        activeToolID = dispatcher.activeToolID
        previousToolID = dispatcher.previousToolID
        hasPendingToolEdit = dispatcher.hasPendingEdit
        if toolChanged {
            // The active tool changed while the pointer may sit over a canvas: re-query now.
            for hook in cursorRefreshHooks.values { hook() }
        }
    }

    // MARK: - Tools

    func selectTool(_ id: ToolID) {
        dispatcher.selectTool(id)
    }

    /// Implemented tools' descriptors, in `ToolID.allCases` order.
    var implementedTools: [ToolDescriptor] {
        registry.implementedIDs.map { ToolRegistry.descriptor(for: $0) }
    }

    // MARK: - Active document session

    func setActiveSession(_ session: CanvasToolSession?) {
        guard session !== activeSession else { return }
        activeSession = session
        activeSessionGeneration += 1
        dispatcher.setContext(session)
    }

    /// Registers a cursor re-query hook (the document window's router); the token removes
    /// it when the window closes.
    func addCursorRefreshHook(_ hook: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        cursorRefreshHooks[token] = hook
        return token
    }

    func removeCursorRefreshHook(_ token: UUID) {
        cursorRefreshHooks[token] = nil
    }

    // MARK: - Panels

    func isPanelVisible(_ kind: PanelKind) -> Bool {
        panelVisibility[kind] ?? true
    }

    func setPanelVisible(_ kind: PanelKind, _ visible: Bool) {
        panelVisibility[kind] = visible
        // Persisted as `panel.<kind>.visible` (the close button and ⌥⌘1–4 both land here).
        defaults.set(visible, forKey: kind.visibilityDefaultsKey)
    }

    func togglePanel(_ kind: PanelKind) {
        setPanelVisible(kind, !isPanelVisible(kind))
    }
}
