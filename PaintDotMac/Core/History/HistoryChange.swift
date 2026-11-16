import Foundation

/// What a step touched, so the canvas knows what to redraw (spec 0008 Scope §3; 0013 adds
/// the selection cases).
enum HistoryChange: Equatable, Sendable {
    /// Only these tiles of these layers changed.
    case pixels([Layer.ID: Set<TileCoordinate>])
    /// Only the selection changed (no pixels) — the ants update, no tile upload (0013).
    case selection
    /// These tiles and the selection (for example 0018's Erase Selection) (0013).
    case pixelsAndSelection([Layer.ID: Set<TileCoordinate>])
    /// Size, layers, properties, or anything else: full refresh.
    case structure

    /// The per-layer tile sets of `.pixels`/`.pixelsAndSelection`; nil otherwise.
    var pixelTiles: [Layer.ID: Set<TileCoordinate>]? {
        switch self {
        case .pixels(let tiles), .pixelsAndSelection(let tiles): tiles
        case .selection, .structure: nil
        }
    }

    /// True when the marching ants must be re-read after this change (0013).
    var affectsSelection: Bool {
        switch self {
        case .selection, .pixelsAndSelection, .structure: true
        case .pixels: false
        }
    }

    /// The symmetric merge table: pixels+pixels → pixels(∪); selection+selection →
    /// selection; pixels+selection → pixelsAndSelection(tiles); pixelsAndSelection with
    /// pixels/selection/pixelsAndSelection → pixelsAndSelection(∪); anything with
    /// `.structure` → `.structure`.
    func merged(with other: HistoryChange) -> HistoryChange {
        switch (self, other) {
        case (.structure, _), (_, .structure):
            return .structure
        case (.pixels(let lhs), .pixels(let rhs)):
            return .pixels(Self.union(lhs, rhs))
        case (.selection, .selection):
            return .selection
        case (.selection, .pixels(let rhs)):
            return .pixelsAndSelection(rhs)
        case (.pixels(let lhs), .selection):
            return .pixelsAndSelection(lhs)
        case (.pixelsAndSelection(let lhs), .pixels(let rhs)):
            return .pixelsAndSelection(Self.union(lhs, rhs))
        case (.pixels(let lhs), .pixelsAndSelection(let rhs)):
            return .pixelsAndSelection(Self.union(lhs, rhs))
        case (.pixelsAndSelection(let lhs), .selection),
             (.selection, .pixelsAndSelection(let lhs)):
            return .pixelsAndSelection(lhs)
        case (.pixelsAndSelection(let lhs), .pixelsAndSelection(let rhs)):
            return .pixelsAndSelection(Self.union(lhs, rhs))
        }
    }

    private static func union(_ lhs: [Layer.ID: Set<TileCoordinate>],
                              _ rhs: [Layer.ID: Set<TileCoordinate>]) -> [Layer.ID: Set<TileCoordinate>] {
        var merged = lhs
        for (layerID, tiles) in rhs { merged[layerID, default: []].formUnion(tiles) }
        return merged
    }
}
