import AppKit
import Foundation
import Observation

/// The bridge's `UndoManager`. Menu ⌘Z / ⇧⌘Z reach the manager as `undo()` / `redo()`
/// directly (AppKit dispatches them on the window's `windowWillReturnUndoManager` object),
/// so this is the one place where every navigation path can run the bridge's
/// `prepareForNavigation` hook *before* the undo/redo run begins. The hook must run
/// before the run: a `registerUndo` made while the manager is undoing lands in the run's
/// REDO group (verified empirically), so a tool's pending-edit commit issued from inside
/// `performUndo` would silently corrupt the manager/stack mirror (the new step's undo
/// action joins the redo stack, and the consumed step's undo action is never re-pushed —
/// ⌘Z then dead-ends while the stack still has undoable steps).
final class NavigationUndoManager: UndoManager {
    /// Set by `UndoBridge.init` when the bridge creates or adopts one of these. Weak: the
    /// bridge owns the manager, never the other way around.
    weak var bridge: UndoBridge?

    override func undo() {
        bridge?.prepareForManagerNavigation()
        super.undo()
    }

    override func redo() {
        bridge?.prepareForManagerNavigation()
        super.redo()
    }
}

/// Mirrors a document's `HistoryStack` one-to-one onto an `NSUndoManager`, so Edit >
/// Undo/Redo titles ("Undo Paintbrush"), the document's edited state, and the History
/// panel stay in sync (spec 0008 Scope §10; PRD E-1, H-3). Undo-stack groups ↔ steps
/// `1...currentIndex`, redo-stack groups ↔ steps `currentIndex+1...`.
///
/// The bridge is the only writer of the document's pixels; nothing else mutates `state`.
/// 0010's History panel observes `history` and `historyRevision` and reads
/// `history.steps` / `currentIndex` / `canUndo` / `canRedo`.
@MainActor
@Observable
final class UndoBridge {
    /// One recorded step; identity for `removeAllActions(withTarget:)`.
    private final class HistoryStepToken {
        let stepID: HistoryStep.ID

        init(stepID: HistoryStep.ID) {
            self.stepID = stepID
        }
    }

    @ObservationIgnored let undoManager: UndoManager
    private(set) var state: DocumentState
    private(set) var history: HistoryStack
    /// +1 exactly once per history mutation (recorded commit/perform, single undo/redo,
    /// moving jump, dropping setBudget, markSaved, reset); never for no-ops.
    private(set) var historyRevision: Int = 0

    /// Before undo/redo/jump/save: the active tool commits its pending edit (0006
    /// `Tool.commit`). Weak-owner pattern: the document owns the bridge, so the closure
    /// captures its owner weakly.
    @ObservationIgnored var prepareForNavigation: (@MainActor () -> Void)?
    /// Why the hook is about to run (spec 0020 item 9): `.historyNavigation` around the
    /// hook inside `prepareForManagerNavigation` (menu ⌘Z/⇧⌘Z) and `jump(to:)`, `.save`
    /// inside `prepareForSave()`; every direct caller of `prepareForNavigation` (the Edit
    /// commands and every later command) sees `.command`. The window controller forwards
    /// this value to `ToolDispatcher.resolvePendingEdit(for:)`.
    @ObservationIgnored private(set) var pendingEditReason: PendingEditReason = .command
    /// Canvas invalidation after perform/undo/redo/jump/reset.
    @ObservationIgnored var onStateChange: (@MainActor (HistoryChange) -> Void)?
    /// After every history mutation, with `!history.isAtSavedState`.
    @ObservationIgnored var onEditedChange: (@MainActor (Bool) -> Void)?

    private var tokens: [HistoryStep.ID: HistoryStepToken] = [:]
    /// A `jump` replays whole steps through `undoManager.undo()`/`redo()`; while the loop
    /// runs the per-step hooks, callbacks, and revision bumps are suppressed.
    private var isReplayingJump = false
    private var replayedChanges: [HistoryChange] = []

    init(state: DocumentState, base: HistoryBaseStep, budgetBytes: Int,
         undoManager: UndoManager = NavigationUndoManager()) {
        self.state = state
        self.history = HistoryStack(base: base, budgetBytes: budgetBytes)
        self.undoManager = undoManager
        (undoManager as? NavigationUndoManager)?.bridge = self
    }

    /// Called by `NavigationUndoManager` before every `undo()` / `redo()` — the hook that
    /// commits the active tool's pending edit. Skipped while `jump(to:)` replays (the
    /// jump calls the hook itself once, before its loop).
    func prepareForManagerNavigation() {
        guard !isReplayingJump else { return }
        withPendingEditReason(.historyNavigation) { prepareForNavigation?() }
    }

    /// Before a save (spec 0020 item 9): the hook runs with reason `.save` — Move
    /// Selected Pixels keeps its pixels floating and the file gets the rendered layer
    /// (D-47b).
    func prepareForSave() {
        withPendingEditReason(.save) { prepareForNavigation?() }
    }

    /// Stamps `pendingEditReason` for the hook, then restores it (top level → `.command`).
    private func withPendingEditReason(_ reason: PendingEditReason,
                                       _ hook: @MainActor () -> Void) {
        let previous = pendingEditReason
        pendingEditReason = reason
        defer { pendingEditReason = previous }
        hook()
    }

    /// In-progress tool drawing (0006 live strokes): mutates the state without recording
    /// a step; committed later via `commit(_:)`.
    func updateLiveState(_ body: (inout DocumentState) -> Void) {
        body(&state)
        assertSelectionConsistent()
    }

    /// Records a step whose changes are already in `state` (live drawing). No-op items are
    /// ignored entirely — nothing registered, no callbacks, no revision bump (H-6).
    func commit(_ item: any HistoryItem) {
        record(history.commit(item), change: nil)
    }

    /// Applies the item to the document, then records it.
    func perform(_ item: any HistoryItem) {
        let result = history.perform(item, on: &state)
        assertSelectionConsistent()
        record(result, change: result.recordedStepID == nil ? nil : item.change)
    }

    func undo() { undoManager.undo() }

    func redo() { undoManager.redo() }

    /// `(currentIndex - index)` × `undoManager.undo()`, or the reverse with `redo()`;
    /// out of range or the current index → no-op. All navigation goes through the
    /// manager, so the stack and the manager can never drift.
    func jump(to index: Int) {
        let distance = history.currentIndex - index
        guard index >= 0, index < history.steps.count, distance != 0 else { return }
        withPendingEditReason(.historyNavigation) { prepareForNavigation?() }
        isReplayingJump = true
        replayedChanges = []
        for _ in 0..<abs(distance) {
            if distance > 0 {
                undoManager.undo()
            } else {
                undoManager.redo()
            }
        }
        isReplayingJump = false
        let merged = replayedChanges.reduce(nil) { partial, next in
            partial.map { $0.merged(with: next) } ?? next
        }
        replayedChanges = []
        if let merged { onStateChange?(merged) }
        onEditedChange?(!history.isAtSavedState)
        historyRevision += 1
    }

    @discardableResult
    func setBudget(_ bytes: Int) -> [HistoryStep.ID] {
        let dropped = history.setBudget(bytes)
        guard !dropped.isEmpty else { return dropped }
        forget(steps: dropped)
        historyRevision += 1
        onEditedChange?(!history.isAtSavedState)
        return dropped
    }

    /// Re-syncs the edited state — an edit made while an async save was running keeps the
    /// document dirty (the token carries the step that was saved).
    func markSaved(stepID: HistoryStep.ID) {
        history.markSaved(stepID: stepID)
        historyRevision += 1
        onEditedChange?(!history.isAtSavedState)
    }

    /// Open / Revert / New: one fresh stack, an emptied undo manager, full canvas refresh.
    func reset(state newState: DocumentState, base: HistoryBaseStep) {
        state = newState
        assertSelectionConsistent()
        history = HistoryStack(base: base, budgetBytes: history.budgetBytes)
        tokens.removeAll()
        undoManager.removeAllActions()
        historyRevision += 1
        onStateChange?(.structure)
        onEditedChange?(false)
    }

    // MARK: - Invariants

    /// 0013: a selection is either absent or exactly canvas-sized; size-change specs
    /// (0022, 0035–0037) must transform or drop it in their snapshot (loud in debug, no
    /// release trap). 0020: floating pixels, when present, name a live layer and an
    /// underlay sized to the canvas — commands finish the session before snapshot
    /// operations run.
    private func assertSelectionConsistent() {
        assert(state.selection == nil || state.selection?.canvasSize == state.image.size,
               "DocumentState.selection must be nil or canvas-sized")
        assert(state.floatingPixels == nil
                   || (state.image.layerIndex(for: state.floatingPixels!.layerID) != nil
                       && state.floatingPixels!.underlay.size == state.image.size),
               "floating pixels need a live layer and a canvas-sized underlay")
    }

    // MARK: - Registration

    private func record(_ result: HistoryCommitResult, change: HistoryChange?) {
        guard let stepID = result.recordedStepID else { return }
        // A registration made while the manager is undoing/redoing lands in the run's
        // redo group and desynchronizes the mirror (verified empirically). Tool commits
        // from `prepareForNavigation` run before the manager's run, never here; this
        // asserts that invariant for future callers (loud in debug, no release trap).
        assert(!undoManager.isUndoing && !undoManager.isRedoing,
               "history must not record a step while the undo manager is undoing/redoing")
        // Discarded redo steps: `NSUndoManager` clears its redo stack itself when a new
        // undo is registered; the bridge only forgets their tokens.
        for discardedID in result.discardedRedoStepIDs { tokens.removeValue(forKey: discardedID) }
        forget(steps: result.droppedStepIDs)

        let name = history.steps[currentStepIndex(for: stepID)].name
        registerUndoAction(stepID: stepID, name: name)
        historyRevision += 1
        if let change { onStateChange?(change) }
        onEditedChange?(!history.isAtSavedState)
    }

    private func currentStepIndex(for stepID: HistoryStep.ID) -> Int {
        history.steps.firstIndex { $0.id == stepID } ?? history.currentIndex
    }

    private func registerUndoAction(stepID: HistoryStep.ID, name: String) {
        let token = HistoryStepToken(stepID: stepID)
        tokens[stepID] = token
        // Tests drive the manager with `groupsByEvent = false`, where an explicit pair
        // makes the registration exactly one group; the app's automatic event group is
        // then the step's group.
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: token) { [weak self] token in
            self?.performUndo(token)
        }
        undoManager.setActionName(name)
        if explicitGroup { undoManager.endUndoGrouping() }
    }

    /// Dropped steps (H-5): Edit > Undo must never name or reach a folded step.
    private func forget(steps dropped: [HistoryStep.ID]) {
        for stepID in dropped {
            guard let token = tokens.removeValue(forKey: stepID) else { continue }
            undoManager.removeAllActions(withTarget: token)
        }
    }

    // MARK: - Navigation (always driven by `undoManager`: menu, ⌘Z, jumps)

    /// Runs inside the manager's undo/redo run — `prepareForNavigation` already fired
    /// *before* the run in `NavigationUndoManager.undo()`/`redo()` (see the note there:
    /// committing from inside the run corrupts the mirror), so nothing here calls it.
    private func performUndo(_ token: HistoryStepToken) {
        guard let step = history.undoStep else { return }
        let change = history.undo(&state)
        assertSelectionConsistent()
        undoManager.registerUndo(withTarget: token) { [weak self] token in
            self?.performRedo(token)
        }
        undoManager.setActionName(step.name)
        finishNavigationStep(change: change)
    }

    private func performRedo(_ token: HistoryStepToken) {
        guard let step = history.redoStep else { return }
        let change = history.redo(&state)
        assertSelectionConsistent()
        undoManager.registerUndo(withTarget: token) { [weak self] token in
            self?.performUndo(token)
        }
        undoManager.setActionName(step.name)
        finishNavigationStep(change: change)
    }

    private func finishNavigationStep(change: HistoryChange?) {
        if isReplayingJump {
            if let change { replayedChanges.append(change) }
            return
        }
        if let change { onStateChange?(change) }
        historyRevision += 1
        onEditedChange?(!history.isAtSavedState)
    }
}
