import Foundation

/// The layer-stack commands of PRD §5.4 L-1 / §5.5 IMG-5 (spec 0024): add, delete,
/// duplicate, merge down, move up/down, and flatten. Pure value semantics — `applied(to:)`
/// never mutates its input, and every result keeps `LayeredImage.isConsistent` true with
/// the same `size` and `dpi`. Untouched layers keep their `id`, properties, and tile
/// storage (`Tile.sharesStorage` stays true), so `HistoryCost.unsharedTileBytes` prices
/// Add / Duplicate / Move at 0 bytes.
///
/// The history item is 0008's `DocumentSnapshotHistoryItem` (whole-structure change,
/// `.structure`): it restores the whole stack *including* `activeLayerIndex` (H-6 — a
/// layer command changed the stack, so undo restores the active index of that step),
/// and both snapshots carry the selection (0013) with `floatingPixels == nil`. A layer
/// command never changes the selection — it is a canvas-level path.
enum LayerCommand: String, CaseIterable, Sendable {
    case addNewLayer
    case deleteLayer
    case duplicateLayer
    case mergeLayerDown
    case moveLayerUp
    case moveLayerDown
    case flatten

    /// History step name = menu title, Paint.NET's spelling (LayersMenu.html).
    var name: String {
        switch self {
        case .addNewLayer: "Add New Layer"
        case .deleteLayer: "Delete Layer"
        case .duplicateLayer: "Duplicate Layer"
        case .mergeLayerDown: "Merge Layer Down"
        case .moveLayerUp: "Move Layer Up"
        case .moveLayerDown: "Move Layer Down"
        case .flatten: "Flatten"
        }
    }

    var icon: HistoryIcon {
        switch self {
        case .addNewLayer: .layerAdd
        case .deleteLayer: .layerDelete
        case .duplicateLayer: .layerDuplicate
        case .mergeLayerDown: .layerMerge
        case .moveLayerUp, .moveLayerDown: .layerMove
        case .flatten: .flatten
        }
    }

    /// The enablement table (menu validation and the unit tests' `enablementTable`);
    /// `i = activeLayerIndex`, `n = layers.count`.
    func isEnabled(in state: DocumentState) -> Bool {
        let i = state.image.activeLayerIndex
        let n = state.image.layers.count
        switch self {
        case .addNewLayer, .duplicateLayer:
            // Paint.NET: Add is always available; Duplicate copies the active layer.
            return true
        case .deleteLayer, .flatten:
            // "As all images must have at least one layer, the last remaining layer
            // cannot be deleted." A one-layer image is already flat.
            return n > 1
        case .mergeLayerDown, .moveLayerDown:
            return i > 0
        case .moveLayerUp:
            return i < n - 1
        }
    }

    /// The new image, or nil when the command is disabled for `image`. Never mutates its
    /// input; the result satisfies `isConsistent` with unchanged `size` and `dpi`.
    func applied(to image: LayeredImage, compositor: CPUCompositor = CPUCompositor()) -> LayeredImage? {
        guard isEnabled(in: DocumentState(image: image)) else { return nil }
        var layers = image.layers
        let i = image.activeLayerIndex
        var activeLayerIndex = i

        switch self {
        case .addNewLayer:
            // A new, completely transparent layer directly above the active one — no
            // allocated tiles is Paint.NET's transparent black #00000000 (D-51).
            let newLayer = Layer(name: LayerNaming.newLayerName(existing: layers),
                                 surface: TiledSurface(size: image.size))
            layers.insert(newLayer, at: i + 1)
            activeLayerIndex = i + 1
        case .deleteLayer:
            layers.remove(at: i)
            // The layer that was below becomes active; deleting the bottom activates the
            // new bottom.
            activeLayerIndex = max(0, i - 1)
        case .duplicateLayer:
            // An exact copy placed directly above the original; the same `surface` value
            // shares every tile buffer copy-on-write, so the step costs 0 bytes.
            let source = layers[i]
            let copy = Layer(name: LayerNaming.duplicateName(of: source.name),
                             surface: source.surface,
                             isVisible: source.isVisible, opacity: source.opacity,
                             blendMode: source.blendMode)
            layers.insert(copy, at: i + 1)
            activeLayerIndex = i + 1
        case .mergeLayerDown:
            // Paint.NET 3.36 `MergeLayerDownFunction`: the upper layer renders onto the
            // lower layer's stored pixels with the *upper* layer's blend mode and
            // opacity (its visibility is not consulted, D-51); the merged layer keeps the
            // *lower* layer's id, name, and properties.
            let lower = layers[i - 1]
            let upper = layers[i]
            let merged = Layer(id: lower.id, name: lower.name,
                               surface: compositor.merged(upper, onto: lower),
                               isVisible: lower.isVisible, opacity: lower.opacity,
                               blendMode: lower.blendMode)
            layers[i - 1] = merged
            layers.remove(at: i)
            activeLayerIndex = i - 1
        case .moveLayerUp:
            layers.swapAt(i, i + 1)
            activeLayerIndex = i + 1
        case .moveLayerDown:
            layers.swapAt(i, i - 1)
            activeLayerIndex = i - 1
        case .flatten:
            // Paint.NET `Document.Flatten`: the visible layers render into the bottom
            // layer, which keeps its id and name (D-51); the result is visible, opaque,
            // Normal. Hidden and opacity-0 layers are discarded by `flattened`; tiles
            // whose composite is fully transparent stay unallocated.
            let bottom = layers[0]
            let flat = Layer(id: bottom.id, name: bottom.name,
                             surface: compositor.flattened(image),
                             isVisible: true, opacity: 255, blendMode: .normal)
            layers = [flat]
            activeLayerIndex = 0
        }

        return LayeredImage(size: image.size, dpi: image.dpi,
                            layers: layers, activeLayerIndex: activeLayerIndex)
    }

    /// nil when disabled; otherwise one `DocumentSnapshotHistoryItem` whose `before` is
    /// `state` and whose `after` replaces only the image (selection unchanged).
    ///
    /// **Precondition `state.floatingPixels == nil`:** every caller commits the active
    /// tool's pending edit first through `undoBridge.prepareForNavigation?()` (reason
    /// `.command`, 0020 item 9), so the snapshot never captures or drops a
    /// `FloatingPixels` value and `FloatingPixels.layerID` can never point at a layer a
    /// delete/merge/flatten removed or a move reordered (0020: snapshot operations only
    /// run with `floatingPixels == nil`).
    func makeHistoryItem(for state: DocumentState,
                                compositor: CPUCompositor = CPUCompositor()) -> DocumentSnapshotHistoryItem? {
        assert(state.floatingPixels == nil,
               "layer commands require floating pixels to be committed first (0020 item 9)")
        guard let applied = applied(to: state.image, compositor: compositor) else { return nil }
        return DocumentSnapshotHistoryItem(
            name: name, icon: icon,
            before: state,
            after: DocumentState(image: applied, selection: state.selection, floatingPixels: nil))
    }
}

/// Paint.NET's layer naming (LayersMenu.html, D-51).
enum LayerNaming {
    /// Paint.NET's generic new-layer name; `%d` is the layer number.
    static let newLayerFormat = "Layer %d"

    /// "Layer N" with N = `layers.count + 1`, incremented while a layer with exactly
    /// that name exists (so deleted layers' numbers are never reused by an add).
    static func newLayerName(existing layers: [Layer]) -> String {
        let taken = Set(layers.map(\.name))
        var number = layers.count + 1
        while taken.contains(String(format: newLayerFormat, number)) {
            number += 1
        }
        return String(format: newLayerFormat, number)
    }

    /// "<name> copy" — no uniqueness check (Paint.NET 3.36 allows duplicate names, so
    /// duplicating twice gives "…copy copy").
    static func duplicateName(of name: String) -> String {
        "\(name) copy"
    }
}

/// The Layers menu's "Go to Layer Above / Below" (L-1): a temporary switch of the editing
/// focus — not a history step and not an edit (Paint.NET does not record layer selection
/// in history; D-51).
enum ActiveLayerStep: Sendable {
    case above
    case below

    /// The index the active layer moves to, or nil at the top/bottom (menu disabled).
    func targetIndex(in image: LayeredImage) -> Int? {
        let i = image.activeLayerIndex
        switch self {
        case .above: return i < image.layers.count - 1 ? i + 1 : nil
        case .below: return i > 0 ? i - 1 : nil
        }
    }
}

/// The Layers panel's drag-to-reorder (spec 0025 item 4, PRD L-5): a move from one layer
/// index to any other, shifting the layers between. 0024's `LayerCommand` only has the
/// adjacent up/down swap; a drag across several positions is **one** step (one gesture =
/// one undo), named after its direction.
///
/// The step is 0024's kind — `DocumentSnapshotHistoryItem` — because the move *changes
/// the layer stack*, so undo restoring the recorded `activeLayerIndex` is exactly what
/// H-6 prescribes for stack changes. After the move the moved layer is active (Paint.NET:
/// the dragged layer stays selected). Every layer keeps its `id` and tile storage; only
/// the array order and the active index change.
enum LayerMove {
    /// Moves the layer at `from` to index `to` (both 0 = bottom), shifting the layers
    /// between. The moved layer becomes active. nil when `from == to` or either index is
    /// out of range.
    static func applied(from: Int, to: Int, in image: LayeredImage) -> LayeredImage? {
        guard from != to,
              image.layers.indices.contains(from),
              image.layers.indices.contains(to)
        else { return nil }
        var layers = image.layers
        let moved = layers.remove(at: from)
        layers.insert(moved, at: to)
        return LayeredImage(size: image.size, dpi: image.dpi,
                            layers: layers, activeLayerIndex: to)
    }

    /// nil when `applied` is nil; otherwise the one snapshot step named "Move Layer Up"
    /// (`to > from`) or "Move Layer Down" (`to < from`), icon `.layerMove`.
    ///
    /// **Precondition `state.floatingPixels == nil`** — like 0024's layer commands, the
    /// caller commits the pending tool edit first via `prepareForNavigation` (0020
    /// item 9), so the snapshot never captures a floating state on a reordered stack.
    static func makeHistoryItem(from: Int, to: Int,
                                for state: DocumentState) -> DocumentSnapshotHistoryItem? {
        assert(state.floatingPixels == nil,
               "layer moves require floating pixels to be committed first (0020 item 9)")
        guard let moved = applied(from: from, to: to, in: state.image) else { return nil }
        let name = to > from ? LayerCommand.moveLayerUp.name : LayerCommand.moveLayerDown.name
        return DocumentSnapshotHistoryItem(
            name: name, icon: .layerMove,
            before: state,
            after: DocumentState(image: moved, selection: state.selection, floatingPixels: nil))
    }
}
