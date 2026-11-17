import Foundation

/// The floating-pixels part of a Move Selected Pixels step (spec 0020 item 4): it only
/// swaps `DocumentState.floatingPixels`, so its change is `.selection` — the ants and
/// the transform handles redraw, no tiles upload (the pixels ride in the `TileDiff`
/// beside it). "Finish Pixels" (Paint.NET 3.36's `Drop()`) is this item alone: the layer
/// already shows the rendered pixels and the selection already moved.
struct FloatingPixelsHistoryItem: HistoryItem {
    let name: String
    let before: FloatingPixels?
    let after: FloatingPixels?

    init(name: String, before: FloatingPixels?, after: FloatingPixels?) {
        self.name = name
        self.before = before
        self.after = after
    }

    var icon: HistoryIcon { .moveSelectedPixels }
    var change: HistoryChange { .selection }
    var isNoOp: Bool { before == after }

    /// A lift costs its source tiles plus the underlay tiles whose storage the hole
    /// punch (or a ⌘-stamp) actually copied — the rest share the live layer (CoW,
    /// NF-4). Every other step (session change, finish) costs 256 B.
    var byteCost: Int {
        if before == nil, let after {
            return after.byteCount + Self.copiedUnderlayTileBytes(after) * Tile.byteCount
        }
        return 256
    }

    /// True for the lift step of session `id` — Escape's exact-cancel test that the
    /// step right after `restore.baseStepID` is this session's start (spec 0020 item 6).
    func startsSession(_ id: UUID) -> Bool {
        before == nil && after?.id == id
    }

    func apply(to state: inout DocumentState) { state.floatingPixels = after }
    func revert(_ state: inout DocumentState) { state.floatingPixels = before }

    /// Tiles of `underlay` whose storage differs from the pre-session layer tile at the
    /// same coordinate — the bytes this lift keeps beyond the source.
    private static func copiedUnderlayTileBytes(_ floating: FloatingPixels) -> Int {
        let underlay = floating.underlay
        let layer = floating.restore.layerSurface
        let coordinates = Set(underlay.allocatedTileCoordinates)
            .union(layer.allocatedTileCoordinates)
        var copied = 0
        for coordinate in coordinates {
            let a = underlay.tile(at: coordinate)
            let b = layer.tile(at: coordinate)
            switch (a, b) {
            case (nil, nil): break
            case let (a?, b?): if !a.sharesStorage(with: b) { copied += 1 }
            default: copied += 1  // one side allocated, the other sparse
            }
        }
        return copied
    }
}

/// Names and composites for Move Selected Pixels steps (spec 0020 item 4; Paint.NET
/// 3.36 `Strings.resx` — `MoveTool.HistoryMemento.Translate/Scale/Rotate/DropPixels`).
enum MoveSelectedPixelsHistory {
    /// Paint.NET's step names per gesture.
    static func name(for gesture: TransformGesture) -> String {
        switch gesture {
        case .translate: "Move Pixels"
        case .scale: "Scale Pixels"
        case .rotate: "Rotate Pixels"
        }
    }

    static let finishStepName = "Finish Pixels"

    /// One user-visible step: the floating layer's tile diff, the selection change, and
    /// the floating-state change, all under one name and icon (Paint.NET records the
    /// three as one memento). The merged change is `.pixelsAndSelection` (0013's table).
    /// `before`/`after` carry the two full states; `candidates` bounds the diff scan to
    /// the rendered tiles of the gesture (old + new regions); `nil` scans both surfaces'
    /// allocated tiles (the budget-folded Escape restore).
    static func step(named name: String, before: DocumentState, after: DocumentState,
                     layerID: Layer.ID,
                     candidates: Set<TileCoordinate>?) -> CompositeHistoryItem {
        var items: [any HistoryItem] = []
        if let beforeIndex = before.image.layerIndex(for: layerID),
           let afterIndex = after.image.layerIndex(for: layerID) {
            let diff = TileDiff.between(
                before: before.image.layers[beforeIndex].surface,
                after: after.image.layers[afterIndex].surface,
                layerID: layerID, candidates: candidates)
            items.append(TileDiffHistoryItem(name: name, icon: .moveSelectedPixels, diff: diff))
        }
        items.append(SelectionHistoryItem(name: name, icon: .moveSelectedPixels,
                                          before: before.selection, after: after.selection))
        items.append(FloatingPixelsHistoryItem(name: name,
                                               before: before.floatingPixels,
                                               after: after.floatingPixels))
        return CompositeHistoryItem(name: name, icon: .moveSelectedPixels, items: items)
    }

    /// "Finish Pixels" (Paint.NET `Drop()`): ends the lifted state only — the layer
    /// already shows the rendered pixels and the selection already moved.
    static func finishStep(_ floating: FloatingPixels) -> FloatingPixelsHistoryItem {
        FloatingPixelsHistoryItem(name: finishStepName, before: floating, after: nil)
    }

    /// True when `step` contains the lift of floating session `id` (looks inside the
    /// `CompositeHistoryItem` gestures record).
    static func stepStartsSession(_ step: HistoryStep, id: UUID) -> Bool {
        guard let item = step.item else { return false }
        if let floating = item as? FloatingPixelsHistoryItem { return floating.startsSession(id) }
        if let composite = item as? CompositeHistoryItem {
            return composite.items.contains {
                ($0 as? FloatingPixelsHistoryItem)?.startsSession(id) == true
            }
        }
        return false
    }
}
