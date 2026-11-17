import Foundation

// Spec 0019: Move Selection's pixel-exact integer translate (extends 0013's type —
// no parallel type).
extension SelectionMask {
    /// The mask shifted by an integer document offset:
    /// `coverage'(x, y) = coverage(x − dx, y − dy)`, 0 where the source is outside.
    /// Same size. Tile-aware: a whole-tile shift re-indexes the tiles without touching
    /// bytes (`.full` stays `.full`, `.partial` storages are shared); any other shift
    /// assembles each destination tile from at most 4 source tiles. The result goes
    /// through `init(size:tiles:)`, so it is normalized like every other mask.
    func translated(dx: Int, dy: Int) -> SelectionMask {
        guard dx != 0 || dy != 0 else { return self }
        guard size.width > 0, size.height > 0 else { return self }
        func divided(_ n: Int) -> (tiles: Int, bytes: Int) {
            let q = n / Self.tileSize, r = n % Self.tileSize   // Euclidean: r in 0..<256
            return r < 0 ? (q - 1, r + Self.tileSize) : (q, r)
        }
        let (tileDX, byteDX) = divided(dx)
        let (tileDY, byteDY) = divided(dy)
        let columns = max(1, gridColumns)

        if byteDX == 0, byteDY == 0 {
            // Whole-tile shift: pure re-indexing, no byte copies (NF-1).
            var tiles: [SelectionMaskTile] = []
            tiles.reserveCapacity(gridRows * columns)
            for row in 0..<gridRows {
                for column in 0..<columns {
                    tiles.append(tile(at: TileCoordinate(column: column - tileDX,
                                                         row: row - tileDY)))
                }
            }
            return SelectionMask(size: size, tiles: tiles)
        }

        var tiles: [SelectionMaskTile] = []
        tiles.reserveCapacity(gridRows * columns)
        for row in 0..<gridRows {
            for column in 0..<columns {
                tiles.append(translatedTile(atColumn: column, row: row,
                                                 tileDX: tileDX, tileDY: tileDY,
                                                 byteDX: byteDX, byteDY: byteDY))
            }
        }
        return SelectionMask(size: size, tiles: tiles)
    }

    /// One destination tile. Its pixels read the source tiles `(sc, sr)` and, when the
    /// byte offsets pull the read window across a seam, the column to the left and/or
    /// the row above: local `lx < byteDX` reads column `sc − 1`, likewise for `ly`.
    private func translatedTile(atColumn column: Int, row: Int, tileDX: Int, tileDY: Int,
                                byteDX: Int, byteDY: Int) -> SelectionMaskTile {
        let sourceColumn = column - tileDX
        let sourceRow = row - tileDY
        let main = tile(at: TileCoordinate(column: sourceColumn, row: sourceRow))
        let left = byteDX == 0 ? .empty
            : tile(at: TileCoordinate(column: sourceColumn - 1, row: sourceRow))
        let up = byteDY == 0 ? .empty
            : tile(at: TileCoordinate(column: sourceColumn, row: sourceRow - 1))
        let upLeft = byteDX == 0 || byteDY == 0 ? .empty
            : tile(at: TileCoordinate(column: sourceColumn - 1, row: sourceRow - 1))

        if case .empty = main, case .empty = left, case .empty = up, case .empty = upLeft {
            return .empty
        }
        // Every source tile the destination can read is `.full` → every destination
        // pixel is 255 (`init(size:tiles:)` re-applies the edge-tile invariant). Only
        // possible when the referenced tiles are all `.full`; tiles forced to `.empty`
        // above simply keep the tile on the slow path, where `init` normalizes it.
        if case .full = main, case .full = left, case .full = up, case .full = upLeft {
            return .full
        }

        var bytes = [UInt8](repeating: 0, count: SelectionMaskTileStorage.byteCount)
        for localY in 0..<Self.tileSize {
            let readsUp = localY < byteDY
            let rowTile = readsUp ? up : main
            let rowTileLeft = readsUp ? upLeft : left
            let yLocal = readsUp ? localY - byteDY + Self.tileSize : localY - byteDY
            let rowStart = localY * Self.tileSize
            for localX in 0..<byteDX {
                bytes[rowStart + localX] = Self.pixel(of: rowTileLeft,
                                                      x: localX - byteDX + Self.tileSize,
                                                      y: yLocal)
            }
            for localX in byteDX..<Self.tileSize {
                bytes[rowStart + localX] = Self.pixel(of: rowTile,
                                                      x: localX - byteDX,
                                                      y: yLocal)
            }
        }
        return .partial(SelectionMaskTileStorage(bytes: bytes))
    }

    private static func pixel(of tile: SelectionMaskTile, x: Int, y: Int) -> UInt8 {
        switch tile {
        case .empty: 0
        case .full: 255
        case .partial(let storage): storage.bytes[y * tileSize + x]
        }
    }
}
