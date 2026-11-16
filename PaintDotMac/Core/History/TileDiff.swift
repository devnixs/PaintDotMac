import Foundation

/// Per-layer, per-tile before/after (spec 0008 Scope §6, AGENTS rules 2–3): the diff is
/// the undo record every pixel operation stores — only changed 256×256 tiles.
///
/// **Capture pattern for tools (used from 0009 on):** at `mouseDown`, keep
/// `let before = context.image` (a free CoW copy that carries the surfaces'
/// `generation`s); draw into the live image with `context.updateImage` while dragging;
/// at `mouseUp`, compute candidates as
/// `after.layers[i].surface.changedTiles(since: before.layers[i].surface.generation)`,
/// call `TileDiff.between(before:after:candidates:)`, and
/// `context.commitHistory(TileDiffHistoryItem(…))`. `cancel` reverts with `diff.revert`.
struct TileDiff: Sendable {
    struct Entry: Sendable {
        let layerID: Layer.ID
        let coordinate: TileCoordinate
        /// nil = the tile was absent (fully transparent) before.
        let before: Tile?
        /// nil = the tile is absent afterwards.
        let after: Tile?
    }

    /// Ordered by layer (image order), then row, then column.
    let entries: [Entry]

    var isEmpty: Bool { entries.isEmpty }

    /// Σ tileBytes(before) + tileBytes(after) — see `HistoryCost`.
    var byteCost: Int {
        entries.reduce(0) { $0 + HistoryCost.tileBytes($1.before) + HistoryCost.tileBytes($1.after) }
    }

    var changedTiles: [Layer.ID: Set<TileCoordinate>] {
        var result: [Layer.ID: Set<TileCoordinate>] = [:]
        for entry in entries { result[entry.layerID, default: []].insert(entry.coordinate) }
        return result
    }

    /// One layer's diff. `candidates` nil means the union of both surfaces' allocated
    /// tiles. A coordinate is skipped when both sides are nil, share storage (fast path),
    /// hold equal bytes, or one side is absent while the other is fully transparent
    /// (pixel-identical). So writing identical pixels yields an empty diff.
    static func between(before: TiledSurface, after: TiledSurface, layerID: Layer.ID,
                        candidates: Set<TileCoordinate>? = nil) -> TileDiff {
        let coordinates: [TileCoordinate]
        if let candidates {
            coordinates = candidates.sorted()
        } else {
            coordinates = Set(before.allocatedTileCoordinates)
                .union(after.allocatedTileCoordinates)
                .sorted()
        }
        var entries: [Entry] = []
        entries.reserveCapacity(coordinates.count)
        for coordinate in coordinates {
            let beforeTile = before.tile(at: coordinate)
            let afterTile = after.tile(at: coordinate)
            if beforeTile == nil && afterTile == nil { continue }
            if let beforeTile, let afterTile, beforeTile.sharesStorage(with: afterTile) {
                continue  // identity fast path — no memcmp
            }
            if beforeTile == afterTile { continue }  // content-identical
            if (beforeTile == nil && afterTile?.isFullyTransparent == true)
                || (afterTile == nil && beforeTile?.isFullyTransparent == true) {
                continue  // absent and transparent are pixel-identical
            }
            entries.append(Entry(layerID: layerID, coordinate: coordinate,
                                 before: beforeTile, after: afterTile))
        }
        return TileDiff(entries: entries)
    }

    /// Whole-image diff for pixel-only steps. Throws `.canvasSizeMismatch` when the sizes
    /// differ and `.layerStructureMismatch` unless both images hold the same layer IDs in
    /// the same order — structural changes use `DocumentSnapshotHistoryItem` instead.
    /// A `candidates` key absent from the dictionary means "no candidates for that
    /// layer"; a nil dictionary means "all tiles of all layers".
    static func between(before: LayeredImage, after: LayeredImage,
                        candidates: [Layer.ID: Set<TileCoordinate>]? = nil) throws(TileDiffError) -> TileDiff {
        guard before.size == after.size else { throw .canvasSizeMismatch }
        guard before.layers.map(\.id) == after.layers.map(\.id) else {
            throw .layerStructureMismatch
        }
        var entries: [Entry] = []
        for (beforeLayer, afterLayer) in zip(before.layers, after.layers) {
            let layerCandidates: Set<TileCoordinate>?
            if let candidates {
                layerCandidates = candidates[beforeLayer.id] ?? []
            } else {
                layerCandidates = nil
            }
            entries.append(contentsOf: between(
                before: beforeLayer.surface, after: afterLayer.surface,
                layerID: beforeLayer.id, candidates: layerCandidates
            ).entries)
        }
        return TileDiff(entries: entries)
    }

    /// Sets every entry's `after` tile (stamping the generation for 0003's renderer).
    /// Never changes `activeLayerIndex` (H-6: undo doesn't switch layers).
    func apply(to image: inout LayeredImage) {
        mutate(image: &image, side: \.after)
    }

    /// Sets every entry's `before` tile; a tile that was absent is freed again, so undo
    /// actually releases memory.
    func revert(_ image: inout LayeredImage) {
        mutate(image: &image, side: \.before)
    }

    private func mutate(image: inout LayeredImage, side: KeyPath<Entry, Tile?>) {
        for entry in entries {
            guard let index = image.layerIndex(for: entry.layerID) else {
                // Unreachable through `HistoryStack`, which guarantees a step only runs on
                // the state pair it captured. A snapshot step owns structure changes.
                assertionFailure("TileDiff layer \(entry.layerID) missing from the state — history invariant broken")
                continue
            }
            image.layers[index].surface.setTile(entry[keyPath: side], at: entry.coordinate)
        }
    }
}

enum TileDiffError: Error, Equatable {
    case canvasSizeMismatch
    case layerStructureMismatch
}
