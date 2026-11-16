import Foundation

/// The document's first step, mirroring Paint.NET's History window (spec 0008 Scope §7).
enum HistoryBaseStep: Sendable {
    case openImage
    case newImage

    var name: String {
        switch self {
        case .openImage: "Open Image"
        case .newImage: "New Image"
        }
    }

    var icon: HistoryIcon {
        switch self {
        case .openImage: .openImage
        case .newImage: .newImage
        }
    }
}

/// One row of the History list (0010 renders it). `item` is nil only for the base step.
struct HistoryStep: Identifiable, Sendable {
    typealias ID = Int  // monotonically increasing per stack; base = 0; never reused

    let id: ID
    let name: String
    let icon: HistoryIcon
    let item: (any HistoryItem)?

    var isBase: Bool { item == nil }
}

/// What one `commit`/`perform` did, so callers (the `UndoBridge`) can mirror it (spec 0008).
struct HistoryCommitResult: Equatable, Sendable {
    /// nil when the item was a no-op and was ignored (H-6).
    var recordedStepID: HistoryStep.ID?
    /// Redo steps the commit discarded (a new action erases the redo branch).
    var discardedRedoStepIDs: [HistoryStep.ID]
    /// Oldest steps folded into the base because the budget was exceeded (H-5).
    var droppedStepIDs: [HistoryStep.ID]
}

/// The ordered steps, the current position, the memory budget, and the saved marker
/// (PRD E-1, H-5, H-6, NF-4; AGENTS rule 2). The live state equals `steps[currentIndex]`'s
/// after state.
struct HistoryStack: Sendable {
    /// "1 GB" in the UI means 1 GiB (H-6).
    static let defaultBudgetBytes = 1_073_741_824

    /// `steps[0]` is always the base step.
    private(set) var steps: [HistoryStep]
    /// `0 ..< steps.count`; the state equals `after` of `steps[currentIndex]`.
    private(set) var currentIndex: Int
    /// Σ over non-base steps of `item.byteCost + HistoryCost.stepOverheadBytes`.
    private(set) var totalBytes: Int
    private(set) var budgetBytes: Int
    /// nil = the saved state is no longer reachable.
    private(set) var savedStepID: HistoryStep.ID?
    private var nextStepID: HistoryStep.ID

    init(base: HistoryBaseStep, budgetBytes: Int = HistoryStack.defaultBudgetBytes) {
        steps = [HistoryStep(id: 0, name: base.name, icon: base.icon, item: nil)]
        currentIndex = 0
        totalBytes = 0
        self.budgetBytes = max(0, budgetBytes)
        // A freshly opened file and a fresh New Image are both clean (APP-9).
        savedStepID = 0
        nextStepID = 1
    }

    var canUndo: Bool { currentIndex > 0 }
    var canRedo: Bool { currentIndex < steps.count - 1 }
    var undoStep: HistoryStep? { canUndo ? steps[currentIndex] : nil }
    var redoStep: HistoryStep? { canRedo ? steps[currentIndex + 1] : nil }
    var currentStepID: HistoryStep.ID { steps[currentIndex].id }
    var isAtSavedState: Bool { savedStepID == currentStepID }

    /// Records a step whose changes are already in the live state. A no-op item changes
    /// nothing at all (H-6). Otherwise the redo branch is discarded, the step is appended
    /// under the item's name and icon, and the budget is enforced (H-5).
    @discardableResult
    mutating func commit(_ item: any HistoryItem) -> HistoryCommitResult {
        guard !item.isNoOp else {
            return HistoryCommitResult(recordedStepID: nil, discardedRedoStepIDs: [],
                                       droppedStepIDs: [])
        }
        var discarded: [HistoryStep.ID] = []
        if currentIndex < steps.count - 1 {
            for step in steps[(currentIndex + 1)...] {
                totalBytes -= step.byteCostWithOverhead
                discarded.append(step.id)
                if savedStepID == step.id { savedStepID = nil }
            }
            steps.removeSubrange((currentIndex + 1)...)
        }
        let step = HistoryStep(id: nextStepID, name: item.name, icon: item.icon, item: item)
        nextStepID += 1
        steps.append(step)
        currentIndex = steps.count - 1
        totalBytes += step.byteCostWithOverhead
        let dropped = enforceBudget()
        return HistoryCommitResult(recordedStepID: step.id, discardedRedoStepIDs: discarded,
                                   droppedStepIDs: dropped)
    }

    /// Applies the item to `state`, then records it. A no-op is neither applied nor
    /// recorded.
    @discardableResult
    mutating func perform(_ item: any HistoryItem, on state: inout DocumentState) -> HistoryCommitResult {
        guard !item.isNoOp else {
            return HistoryCommitResult(recordedStepID: nil, discardedRedoStepIDs: [],
                                       droppedStepIDs: [])
        }
        item.apply(to: &state)
        return commit(item)
    }

    @discardableResult
    mutating func undo(_ state: inout DocumentState) -> HistoryChange? {
        guard canUndo, let item = steps[currentIndex].item else { return nil }
        item.revert(&state)
        currentIndex -= 1
        return item.change
    }

    @discardableResult
    mutating func redo(_ state: inout DocumentState) -> HistoryChange? {
        guard canRedo, let item = steps[currentIndex + 1].item else { return nil }
        item.apply(to: &state)
        currentIndex += 1
        return item.change
    }

    /// Repeated undo/redo until `currentIndex == index`; the changes in order. Out-of-range
    /// or the current index returns `[]` and changes nothing. (The bridge does not call
    /// this; it jumps through `NSUndoManager` so both stay in sync — see `UndoBridge`.)
    @discardableResult
    mutating func jump(to index: Int, _ state: inout DocumentState) -> [HistoryChange] {
        guard steps.indices.contains(index), index != currentIndex else { return [] }
        var changes: [HistoryChange] = []
        while currentIndex > index {
            guard let change = undo(&state) else { break }
            changes.append(change)
        }
        while currentIndex < index {
            guard let change = redo(&state) else { break }
            changes.append(change)
        }
        return changes
    }

    /// Stores `max(0, bytes)` and enforces the budget; the dropped IDs in fold order.
    @discardableResult
    mutating func setBudget(_ bytes: Int) -> [HistoryStep.ID] {
        budgetBytes = max(0, bytes)
        return enforceBudget()
    }

    /// Sets the saved marker to that ID if a step with it exists, else nil.
    mutating func markSaved(stepID: HistoryStep.ID) {
        savedStepID = steps.contains(where: { $0.id == stepID }) ? stepID : nil
    }

    /// 0021's Paste into New Image: the copied content was never saved.
    mutating func clearSavedState() {
        savedStepID = nil
    }

    /// H-5: while over budget, fold `steps[1]` into the base. The base step is never
    /// dropped, the current step is never dropped (a single oversized step is kept, H-6 —
    /// the budget may then stay exceeded), and redo steps are never dropped by enforcement
    /// (the next commit discards them).
    private mutating func enforceBudget() -> [HistoryStep.ID] {
        var dropped: [HistoryStep.ID] = []
        while totalBytes > budgetBytes, currentIndex >= 2 {
            let folded = steps.remove(at: 1)
            totalBytes -= folded.byteCostWithOverhead
            currentIndex -= 1
            dropped.append(folded.id)
            if savedStepID == folded.id {
                // The base now *is* that state.
                savedStepID = steps[0].id
            } else if savedStepID == steps[0].id {
                // The base moved forward, so the saved state is gone.
                savedStepID = nil
            }
        }
        return dropped
    }
}

private extension HistoryStep {
    var byteCostWithOverhead: Int { (item?.byteCost ?? 0) + HistoryCost.stepOverheadBytes }
}
