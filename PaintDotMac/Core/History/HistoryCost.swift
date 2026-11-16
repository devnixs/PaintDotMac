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
    /// 0013: a structural step that also changes the selection accounts for it too.
    static func unsharedTileBytes(before: DocumentState, after: DocumentState) -> Int {
        let beforeKeys = storageKeys(of: before.image)
        let afterKeys = storageKeys(of: after.image)
        let onlyBefore = beforeKeys.subtracting(afterKeys).count
        let onlyAfter = afterKeys.subtracting(beforeKeys).count
        return (onlyBefore + onlyAfter) * Tile.byteCount
            + selectionBytes(before: before.selection, after: after.selection)
    }

    /// The bytes a selection step keeps alive (0013, NF-4): the mask-tile storages
    /// (65,536 B each) present on only one side — by storage identity, so combined
    /// selections that share tiles cost nothing — plus each side's `pathByteEstimate`
    /// whose path is not the identical object (`!==`) of the other side's path. A `nil`
    /// side contributes 0. Undo/redo share the same values, so the cost is fixed at init.
    static func selectionBytes(before: Selection?, after: Selection?) -> Int {
        let beforeIdentities = before?.mask.tileStorageIdentities ?? [:]
        let afterIdentities = after?.mask.tileStorageIdentities ?? [:]
        let beforeKeys = Set(beforeIdentities.keys)
        let afterKeys = Set(afterIdentities.keys)
        var total = beforeKeys.subtracting(afterKeys)
            .reduce(0) { $0 + (beforeIdentities[$1] ?? 0) }
        total += afterKeys.subtracting(beforeKeys)
            .reduce(0) { $0 + (afterIdentities[$1] ?? 0) }
        if let before, pathsDiffer(before, after) { total += before.pathByteEstimate }
        if let after, pathsDiffer(after, before) { total += after.pathByteEstimate }
        return total
    }

    /// `true` unless both sides carry the identical `CGPath` object.
    private static func pathsDiffer(_ a: Selection, _ b: Selection?) -> Bool {
        guard let b else { return true }
        return a.path !== b.path
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
