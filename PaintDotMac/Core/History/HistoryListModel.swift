import Foundation

/// The state of one History-panel row (PRD H-2; spec 0010). The current step is what the
/// canvas shows; everything after it is undone — greyed until the next new action
/// discards it.
enum HistoryRowState: String, Sendable, Equatable {
    /// Applied, before the current step.
    case done
    /// The step the canvas is showing now (last applied).
    case current
    /// After the current step: shown greyed, discarded by the next new action.
    case undone
}

/// One History-panel row. `id` is 0008's `HistoryStep.ID` — stable across budget drops and
/// new steps — so SwiftUI keeps row identity when H-5 re-bases the indices.
struct HistoryRow: Identifiable, Sendable, Equatable {
    let id: HistoryStep.ID
    /// Position in the current list; 0 = the base step.
    let index: Int
    /// `HistoryItem.name`, e.g. "Paintbrush".
    let name: String
    let icon: HistoryIcon
    let state: HistoryRowState

    var isUndone: Bool { state == .undone }
    var isCurrent: Bool { state == .current }
    /// The accessibility value VoiceOver and the integration tests read:
    /// "current", "done", or "undone".
    var accessibilityValue: String { state.rawValue }
}

/// The History panel's whole view model: the pure mapping from 0008's `HistoryStack` to
/// rows, plus the click and button decisions (spec 0010). The SwiftUI view only renders
/// and forwards; jumping itself goes through `UndoBridge.jump(to:)`.
struct HistoryListModel: Sendable, Equatable {
    let rows: [HistoryRow]
    let currentIndex: Int

    /// Pure mapping. `steps` is the full list including the base step at 0. An
    /// out-of-range `currentIndex` clamps to `0...steps.count-1`; empty `steps` produce
    /// `.empty`. This can't happen with a valid stack, but the panel must not crash on it.
    init(steps: [(id: HistoryStep.ID, name: String, icon: HistoryIcon)], currentIndex: Int) {
        guard !steps.isEmpty else {
            self.rows = []
            self.currentIndex = 0
            return
        }
        let current = min(max(currentIndex, 0), steps.count - 1)
        self.currentIndex = current
        self.rows = steps.enumerated().map { offset, step in
            HistoryRow(id: step.id, index: offset, name: step.name, icon: step.icon,
                       state: offset < current ? .done
                            : offset == current ? .current : .undone)
        }
    }

    /// Convenience over 0008's `HistoryStack`; reads only, no mutation.
    init(stack: HistoryStack) {
        self.init(steps: stack.steps.map { (id: $0.id, name: $0.name, icon: $0.icon) },
                  currentIndex: stack.currentIndex)
    }

    /// No active document.
    static let empty = HistoryListModel(steps: [], currentIndex: 0)

    var canUndo: Bool { currentIndex > 0 }
    var canRedo: Bool { currentIndex < rows.count - 1 }

    /// The index to jump to when the user clicks the row at `index` — Paint.NET's toggle
    /// rule (H-2):
    /// - another row → that row;
    /// - the current row (not the base) → `currentIndex - 1`, stepping back once, which
    ///   reproduces Paint.NET's repeated-click toggle between it and the previous entry;
    /// - the current base row, or an out-of-range index → nil (no-op, no crash).
    func jumpTarget(forClickedRow index: Int) -> Int? {
        guard rows.indices.contains(index) else { return nil }
        guard index == currentIndex else { return index }
        return index > 0 ? index - 1 : nil
    }
}
