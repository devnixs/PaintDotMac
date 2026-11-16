import Foundation

/// What a step touched, so the canvas knows what to redraw (spec 0008 Scope §3).
/// 0013 may add a `.selection` case and extend `merged`.
enum HistoryChange: Equatable, Sendable {
    /// Only these tiles of these layers changed.
    case pixels([Layer.ID: Set<TileCoordinate>])
    /// Size, layers, properties, or anything else: full refresh.
    case structure

    /// pixels ∪ pixels = per-layer set union; anything with `.structure` = `.structure`.
    func merged(with other: HistoryChange) -> HistoryChange {
        switch (self, other) {
        case (.structure, _), (_, .structure):
            return .structure
        case (.pixels(let lhs), .pixels(let rhs)):
            var merged = lhs
            for (layerID, tiles) in rhs { merged[layerID, default: []].formUnion(tiles) }
            return .pixels(merged)
        }
    }
}
