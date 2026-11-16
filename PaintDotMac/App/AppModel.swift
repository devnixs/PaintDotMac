import Foundation
import Observation

/// App-wide observable state (spec 0006): the tool dispatcher and its mirrors, the tool
/// options store, the active document window's tool session, the four panels'
/// visibility, and the app-wide colors (0007).
@MainActor
@Observable
final class AppModel {
    /// Created on first use by `AppDelegate`.
    static let shared = AppModel()

    @ObservationIgnored let dispatcher: ToolDispatcher
    @ObservationIgnored private let registry: ToolRegistry
    @ObservationIgnored private let defaults: UserDefaults
    /// The suite this model persists to — tests re-read it as a relaunch (0006/0007/0009
    /// persistence tests); nothing in the app reads it.
    var defaultsForTests: UserDefaults { defaults }

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

    // MARK: - Colors (spec 0007)

    @ObservationIgnored private let colorStore: ColorSelectionStore

    /// The Colors panel's editing state: the two slots, the active slot, and the HSV caches
    /// that keep a hue alive through grays and black.
    private(set) var colorEditor: ColorEditorState

    /// Whether the Colors panel shows the hex box and the sliders (`More »` / `« Less`).
    private(set) var colorsPanelExpanded: Bool

    /// The app-wide primary/secondary pair (C-1). Never a history step, never per document.
    var colors: ColorSelection { colorEditor.selection }

    /// The slot the panel edits; `C` moves it (D-31). Not persisted — every launch starts on
    /// Primary.
    var activeColorSlot: ColorSlot { colorEditor.activeSlot }

    init(defaults: UserDefaults = AppDefaults.shared, registry: ToolRegistry = .standard(),
         colorStore: ColorSelectionStore? = nil) {
        let dispatcher = ToolDispatcher(registry: registry)
        self.dispatcher = dispatcher
        self.registry = registry
        self.defaults = defaults
        // The colors live in the same suite as everything else app-wide (AGENTS.md: never
        // `UserDefaults.standard`); tests inject a throwaway `defaults`.
        let colorStore = colorStore ?? ColorSelectionStore(defaults: defaults)
        self.colorStore = colorStore
        self.colorEditor = ColorEditorState(selection: colorStore.load())
        self.colorsPanelExpanded = colorStore.loadPanelExpanded()
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

    // MARK: - Color edits (spec 0007)

    /// X and the swap arrow (C-1).
    func swapColors() {
        colorEditor.swap()
        saveColors()
    }

    /// D and the black/white reset icon (C-1).
    func resetColors() {
        colorEditor.reset()
        saveColors()
    }

    /// An external color set: 0012's Color Picker and the panel's swatch/hex paths.
    func setColor(_ color: ColorRGBA8, for slot: ColorSlot) {
        colorEditor.setColor(color, for: slot)
        saveColors()
    }

    /// One slider or numeric field, on the active slot.
    func setColorChannel(_ channel: ColorChannel, to value: Int) {
        colorEditor.set(channel, to: value)
        saveColors()
    }

    /// The hex box's commit. `false` means the text was not a hex color: nothing changed and
    /// nothing was written, so the field reverts with no alert (C-2).
    @discardableResult
    func applyHex(_ text: String) -> Bool {
        guard colorEditor.applyHex(text) else { return false }
        saveColors()
        return true
    }

    /// A wheel click or drag (the view has already applied the ⌘/⌥/⇧⌘ constraint).
    func applyWheel(hue: Double, saturation: Double, to slot: ColorSlot) {
        colorEditor.applyWheel(hue: hue, saturation: saturation, to: slot)
        saveColors()
    }

    func setActiveColorSlot(_ slot: ColorSlot) {
        colorEditor.activeSlot = slot
    }

    /// C (C-1, D-31): colors and caches stay put, so nothing is written.
    func switchActiveColorSlot() {
        colorEditor.switchActiveSlot()
    }

    func setColorsPanelExpanded(_ expanded: Bool) {
        colorsPanelExpanded = expanded
        colorStore.savePanelExpanded(expanded)
    }

    /// Every change goes straight to the store: `UserDefaults` writes are cheap, and a quit
    /// must never lose a color (C-1).
    private func saveColors() {
        colorStore.save(colorEditor.selection)
    }
}
