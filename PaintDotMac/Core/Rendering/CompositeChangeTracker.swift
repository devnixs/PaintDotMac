import Foundation

/// Everything about a layer stack except its pixels that affects the composite
/// (spec 0024 item 5): image size and, per layer in stack order, its identity,
/// visibility, opacity, and blend mode. `activeLayerIndex` is deliberately **not** part
/// of it — switching the active layer never recomposites.
struct LayerStackSignature: Equatable, Sendable {
    var size: PixelSize
    var layers: [Entry]

    struct Entry: Equatable, Sendable {
        var id: UUID
        var isVisible: Bool
        var opacity: UInt8
        var blendMode: BlendMode
    }

    init(_ image: LayeredImage) {
        size = image.size
        layers = image.layers.map { Entry(id: $0.id, isVisible: $0.isVisible,
                                          opacity: $0.opacity, blendMode: $0.blendMode) }
    }
}

/// What the composite needs: `.all` (every resident composite tile is stale — first
/// frame, structure/property change, or an older surface swapped in by undo), or the
/// exact set of tiles whose pixels changed.
enum CompositeStaleness: Equatable, Sendable {
    case all
    case tiles(Set<TileCoordinate>)
}

/// Decides which composite tiles are stale for a multi-layer image, replacing 0003
/// step 1a's single-layer tracking (spec 0024 item 5). Pure; one instance per renderer.
struct CompositeChangeTracker: Sendable {
    private var signature: LayerStackSignature?
    /// Per layer index, the `surface.generation` seen last (valid only while the
    /// signature matches — an equal signature implies an equal layer count).
    private var generations: [UInt64] = []

    /// `.all` on the first call, after `reset()`, when the signature differs
    /// (add/delete/reorder/visibility/opacity/blend mode/size), or when any layer's
    /// `surface.generation` went backwards (an older surface swapped in, e.g. undo of a
    /// snapshot). Otherwise `.tiles(⋃ layers[k].surface.changedTiles(since:
    /// remembered[k]))` — all layers, hidden ones included (harmless and simpler).
    mutating func update(for image: LayeredImage) -> CompositeStaleness {
        let currentSignature = LayerStackSignature(image)
        let currentGenerations = image.layers.map(\.surface.generation)
        defer {
            signature = currentSignature
            generations = currentGenerations
        }
        guard let remembered = signature else { return .all }
        if currentSignature != remembered { return .all }
        if zip(currentGenerations, generations).contains(where: { $0 < $1 }) { return .all }
        var changed: Set<TileCoordinate> = []
        for (index, layer) in image.layers.enumerated() {
            for coordinate in layer.surface.changedTiles(since: generations[index]) {
                changed.insert(coordinate)
            }
        }
        return .tiles(changed)
    }

    /// The next `update` returns `.all` (`invalidateAll`).
    mutating func reset() {
        signature = nil
        generations = []
    }
}
