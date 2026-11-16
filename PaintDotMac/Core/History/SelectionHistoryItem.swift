import Foundation

/// The lightweight item for selection-only changes (spec 0013) — chosen over
/// `DocumentSnapshotHistoryItem` so that undoing a selection step re-uploads no tiles and
/// reports `.selection`. Used for "Select All", "Deselect", and "Invert Selection" here,
/// and by 0014–0016/0019 for "Rectangle Select", "Ellipse Select", "Lasso Select",
/// "Magic Wand", and "Move Selection". Pixel + selection steps (0018, 0020) wrap this in a
/// `CompositeHistoryItem` with a `TileDiffHistoryItem`.
struct SelectionHistoryItem: HistoryItem {
    let name: String
    let icon: HistoryIcon
    let before: Selection?
    let after: Selection?

    init(name: String, icon: HistoryIcon, before: Selection?, after: Selection?) {
        self.name = name
        self.icon = icon
        self.before = before
        self.after = after
    }

    var byteCost: Int { HistoryCost.selectionBytes(before: before, after: after) }
    var change: HistoryChange { .selection }
    /// H-6: a step that leaves the selection equal changes nothing.
    var isNoOp: Bool { before == after }

    func apply(to state: inout DocumentState) {
        state.selection = after
    }

    func revert(_ state: inout DocumentState) {
        state.selection = before
    }
}
