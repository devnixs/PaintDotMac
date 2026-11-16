import Foundation

/// One undoable step (spec 0008 Scope §4).
///
/// Contract: `apply` is only called on a state equal to the item's "before" and `revert`
/// only on its "after" — `HistoryStack` guarantees this ordering. Both must be
/// deterministic and leave the state exactly (pixel- and property-identical) as it was;
/// `change` tells the canvas what to redraw, and `byteCost` is fixed at init.
protocol HistoryItem: Sendable {
    /// Paint.NET's spelling: "Paintbrush", "Deselect", "Gaussian Blur".
    var name: String { get }
    var icon: HistoryIcon { get }
    /// Memory this step keeps alive — see `HistoryCost`.
    var byteCost: Int { get }
    var change: HistoryChange { get }
    /// H-6: an action that changes nothing adds no history step.
    var isNoOp: Bool { get }
    /// Redo direction: before → after.
    func apply(to state: inout DocumentState)
    /// Undo direction: after → before.
    func revert(_ state: inout DocumentState)
}

extension HistoryItem {
    var isNoOp: Bool { false }
}

/// Pixel changes on existing layers, stored as a `TileDiff` (AGENTS rules 2–3). Used by
/// every painting tool, fill, erase/fill selection, and effect/adjustment.
struct TileDiffHistoryItem: HistoryItem {
    let name: String
    let icon: HistoryIcon
    let diff: TileDiff

    var byteCost: Int { diff.byteCost }
    var change: HistoryChange { .pixels(diff.changedTiles) }
    var isNoOp: Bool { diff.isEmpty }

    func apply(to state: inout DocumentState) {
        diff.apply(to: &state.image)
    }

    func revert(_ state: inout DocumentState) {
        diff.revert(&state.image)
    }
}

/// Whole-structure changes: layer add/delete/duplicate/merge/move/flatten and
/// drag-reorder (0024/0025 — those use their own `LayerPropertiesHistoryItem` so undo
/// never changes the active layer, H-6), canvas-size changes (0022, 0035–0037), and
/// selection changes until 0013 decides whether it needs a lighter item. `apply`/`revert`
/// assign the captured states — cheap, because tile storage is shared copy-on-write.
struct DocumentSnapshotHistoryItem: HistoryItem {
    let name: String
    let icon: HistoryIcon
    let before: DocumentState
    let after: DocumentState
    let byteCost: Int

    init(name: String, icon: HistoryIcon, before: DocumentState, after: DocumentState) {
        self.name = name
        self.icon = icon
        self.before = before
        self.after = after
        self.byteCost = HistoryCost.unsharedTileBytes(before: before, after: after)
    }

    var change: HistoryChange { .structure }

    func apply(to state: inout DocumentState) { state = after }
    func revert(_ state: inout DocumentState) { state = before }
}

/// One user-visible step made of several items (for example Move Selected Pixels' commit
/// = pixels + selection). `apply` runs items in order, `revert` in reverse.
struct CompositeHistoryItem: HistoryItem {
    let name: String
    let icon: HistoryIcon
    let items: [any HistoryItem]

    var byteCost: Int { items.reduce(0) { $0 + $1.byteCost } }

    var change: HistoryChange {
        items.map(\.change).reduce(.pixels([:])) { $0.merged(with: $1) }
    }

    /// An empty list is a no-op, as is a list of no-ops.
    var isNoOp: Bool { items.allSatisfy(\.isNoOp) }

    func apply(to state: inout DocumentState) {
        for item in items { item.apply(to: &state) }
    }

    func revert(_ state: inout DocumentState) {
        for item in items.reversed() { item.revert(&state) }
    }
}
