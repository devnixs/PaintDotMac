import Foundation

/// Memory accounting, one rule for every item (spec 0008 Scope §5): a step costs the bytes
/// of the tile storage it references on one side but not the other. Deliberately
/// conservative — a tile diff counts both its before and after tiles although the newest
/// after-tiles are shared with the live image — so real memory ≤ accounted memory.
enum HistoryCost {
    /// `tile == nil` (sparse, unallocated) costs nothing; every stored tile costs the full
    /// 262,144 bytes (0002 stores edge tiles at full size too).
    static func tileBytes(_ tile: Tile?) -> Int {
        tile == nil ? 0 : Tile.byteCount
    }

    /// The address of the tile's byte buffer — the same address 0002's
    /// `sharesStorage(with:)` compares; reading it never copies. Two tiles have the same
    /// key exactly when `sharesStorage(with:)` is true.
    static func storageKey(_ tile: Tile) -> UInt {
        tile.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
    }

    /// The distinct `storageKey`s of every allocated tile of every layer, per side (a
    /// storage shared by two layers on one side counts once). Both states are alive while
    /// the keys are compared, so a key cannot be reused by another buffer mid-computation.
    static func unsharedTileBytes(before: DocumentState, after: DocumentState) -> Int {
        let beforeKeys = storageKeys(of: before.image)
        let afterKeys = storageKeys(of: after.image)
        let onlyBefore = beforeKeys.subtracting(afterKeys).count
        let onlyAfter = afterKeys.subtracting(beforeKeys).count
        return (onlyBefore + onlyAfter) * Tile.byteCount
    }

    /// Added by `HistoryStack` per non-base step, bounding the number of zero-cost steps
    /// to roughly 1 M under the 1 GiB budget.
    static let stepOverheadBytes = 1_024

    private static func storageKeys(of image: LayeredImage) -> Set<UInt> {
        var keys: Set<UInt> = []
        for layer in image.layers {
            let surface = layer.surface
            for coordinate in surface.allocatedTileCoordinates {
                guard let tile = surface.tile(at: coordinate) else { continue }
                keys.insert(storageKey(tile))
            }
        }
        return keys
    }
}
