import Foundation

/// One tile's 8-bit coverage bytes (spec 0013). Immutable; the object's identity is the
/// memory-accounting key (`HistoryCost.selectionBytes`), so sharing a storage between
/// masks costs nothing. Exactly 256 × 256 bytes, row-major, tile-local.
final class SelectionMaskTileStorage: Sendable, CustomStringConvertible {
    static let byteCount = SelectionMask.tileSize * SelectionMask.tileSize   // 65,536

    let bytes: [UInt8]

    init(bytes: [UInt8]) {
        precondition(bytes.count == Self.byteCount,
                     // Programmer error: every call site builds a full tile buffer.
                     "mask tile needs \(Self.byteCount) bytes, got \(bytes.count)")
        self.bytes = bytes
    }

    var description: String { "SelectionMaskTileStorage(\(ObjectIdentifier(self)))" }
}

/// One mutable slot per tile in a parallel combine pass. Each `concurrentPerform` task
/// writes only its own box, and `concurrentPerform` establishes the ordering edge before
/// the results are read back — so the unchecked conformance is safe (the same pattern as
/// `MetalCanvasRenderer.TileChainBox`).
final class SelectionMaskTileBox: @unchecked Sendable {
    var tile: SelectionMaskTile = .empty
}

/// One tile of a `SelectionMask`: the two constant tiles carry no byte storage at all, so
/// Select All / Deselect stay O(tiles) with zero pixel memory (NF-1/NF-4).
enum SelectionMaskTile: Sendable, Equatable {
    /// Every pixel 0 coverage.
    case empty
    /// Every *in-canvas* pixel 255 coverage.
    case full
    /// Anything else; equal by identity first, then by bytes.
    case partial(SelectionMaskTileStorage)

    static func == (lhs: SelectionMaskTile, rhs: SelectionMaskTile) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty), (.full, .full):
            return true
        case (.partial(let a), .partial(let b)):
            return a === b || a.bytes == b.bytes
        default:
            return false
        }
    }
}

/// Memo box for `SelectionMask.bounds`. A lazily computed, immutable value: concurrent
/// first reads may compute the same value twice (the computation is pure and the writes
/// idempotent), which is benign — the same pattern as `SelectionMaskTileBox`.
final class SelectionMaskBoundsBox: @unchecked Sendable {
    var value: PixelRect?
}

/// The cached, rasterized 8-bit antialiased selection mask on the same 256×256 tile grid
/// as `TiledSurface` (AGENTS rules 3 and 8; spec 0013).
///
/// Grid: `ceil(width/256) × ceil(height/256)` tiles, row-major. **Invariant:** pixels of
/// an edge tile that lie outside `size` are always 0 in `.partial` storage; `.full` means
/// every in-canvas pixel is 255. Every operation computes only in-canvas pixels and
/// normalizes its result (an all-0 `.partial` becomes `.empty`, an all-255 one `.full`),
/// so two masks with equal coverage everywhere compare `==` and `isEmpty`/`isFull` are
/// exact. `bounds` is the tight rectangle of pixels with coverage > 0.
struct SelectionMask: Sendable, Equatable {
    static let tileSize = 256

    let size: PixelSize
    private(set) var tiles: [SelectionMaskTile]
    /// Union of the `.full` tile rects (clipped to `size`) and the tight non-zero rows and
    /// columns of the `.partial` tiles; `.zero` when the mask is empty (`BrushClipMask`).
    /// Computed on first read (NF-1: mask construction and inversion stay O(pixels
    /// touched), not O(pixels scanned twice)) and memoized thereafter.
    private let boundsBox = SelectionMaskBoundsBox()
    var bounds: PixelRect {
        if let value = boundsBox.value { return value }
        let computed = Self.computeBounds(tiles: tiles, size: size)
        boundsBox.value = computed
        return computed
    }

    var gridColumns: Int { Self.gridColumns(size: size) }
    var gridRows: Int { Self.gridRows(size: size) }

    /// The empty mask: every tile `.empty`, no byte storage.
    init(size: PixelSize) {
        self.init(size: size, tiles: Array(repeating: SelectionMaskTile.empty,
                                           count: Self.gridTileCount(size: size)))
    }

    /// The full mask: every tile `.full`, no byte storage (Select All, NF-1).
    static func full(size: PixelSize) -> SelectionMask {
        SelectionMask(size: size, tiles: Array(repeating: SelectionMaskTile.full,
                                               count: Self.gridTileCount(size: size)))
    }

    /// Builder (tests, 0016's flood fill): queries `coverage` for every in-canvas pixel;
    /// out-of-canvas bytes stay 0. The tile grid is normalized by `init(size:tiles:)`.
    init(size: PixelSize, coverage: (_ x: Int, _ y: Int) -> UInt8) {
        var tiles: [SelectionMaskTile] = []
        tiles.reserveCapacity(Self.gridTileCount(size: size))
        for row in 0..<max(0, Self.gridRows(size: size)) {
            for column in 0..<max(0, Self.gridColumns(size: size)) {
                let inCanvas = Self.inCanvasRect(column: column, row: row, size: size)
                var bytes = [UInt8](repeating: 0, count: SelectionMaskTileStorage.byteCount)
                for y in inCanvas.minY..<inCanvas.maxY {
                    let rowStart = (y - row * Self.tileSize) * Self.tileSize
                    for x in inCanvas.minX..<inCanvas.maxX {
                        bytes[rowStart + x - column * Self.tileSize] = coverage(x, y)
                    }
                }
                tiles.append(.partial(SelectionMaskTileStorage(bytes: bytes)))
            }
        }
        self.init(size: size, tiles: tiles)
    }

    /// Row-major tile grid; every tile is normalized (out-of-canvas bytes forced 0,
    /// all-0 → `.empty`, all-255-in-canvas → `.full`). A short array is padded with
    /// `.empty`; extra entries are ignored.
    init(size: PixelSize, tiles: [SelectionMaskTile]) {
        let count = Self.gridTileCount(size: size)
        let columns = max(1, Self.gridColumns(size: size))
        var normalized: [SelectionMaskTile] = []
        normalized.reserveCapacity(count)
        for index in 0..<count {
            let column = index % columns
            let row = index / columns
            let tile = index < tiles.count ? tiles[index] : .empty
            normalized.append(Self.normalize(tile, column: column, row: row, size: size))
        }
        self.size = size
        self.tiles = normalized
    }

    /// Equal by size and tiles (storage-identity fast path inside `SelectionMaskTile ==`).
    static func == (lhs: SelectionMask, rhs: SelectionMask) -> Bool {
        lhs.size == rhs.size && lhs.tiles == rhs.tiles
    }

    /// Trusted grid: every tile is already normalized and the array already has exactly
    /// `gridTileCount(size:)` entries. The internal hot paths (`inverted`, `combined`,
    /// the rasterizer) normalize once while producing tiles and skip the defensive
    /// second pass (NF-1).
    init(size: PixelSize, normalizedTiles tiles: [SelectionMaskTile]) {
        self.size = size
        self.tiles = tiles
    }

    /// Out-of-grid coordinates read `.empty`.
    func tile(at coordinate: TileCoordinate) -> SelectionMaskTile {
        guard coordinate.column >= 0, coordinate.row >= 0,
              coordinate.column < gridColumns, coordinate.row < gridRows else { return .empty }
        return tiles[coordinate.row * gridColumns + coordinate.column]
    }

    /// Coverage of one pixel; 0 outside `size` (`BrushClipMask`).
    func coverage(x: Int, y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < size.width, y < size.height else { return 0 }
        return switch tiles[(y >> 8) * gridColumns + (x >> 8)] {
        case .empty: 0
        case .full: 255
        case .partial(let storage):
            storage.bytes[(y & 255) * Self.tileSize + (x & 255)]
        }
    }

    var isEmpty: Bool {
        for tile in tiles { if case .empty = tile { continue }; return false }
        return true
    }

    var isFull: Bool {
        guard !tiles.isEmpty else { return false }
        for tile in tiles { if case .full = tile { continue }; return false }
        return true
    }

    var partialTileCount: Int {
        tiles.reduce(0) { partial, tile in
            if case .partial = tile { partial + 1 } else { partial }
        }
    }

    /// Distinct `.partial` storages → their byte count (65,536 each); the identity map
    /// `HistoryCost.selectionBytes` diffs (NF-4).
    var tileStorageIdentities: [ObjectIdentifier: Int] {
        var result: [ObjectIdentifier: Int] = [:]
        for case let .partial(storage) in tiles {
            result[ObjectIdentifier(storage)] = SelectionMaskTileStorage.byteCount
        }
        return result
    }

    /// `255 − coverage` per in-canvas pixel; `.empty ↔ .full` without touching any
    /// bytes. The `.partial` tiles invert independently (`concurrentPerform`, so the
    /// outcome is bit-identical to the serial loop; NF-1).
    func inverted() -> SelectionMask {
        let columns = max(1, gridColumns)
        var result: [SelectionMaskTile] = []
        result.reserveCapacity(tiles.count)
        var jobs: [(index: Int, storage: SelectionMaskTileStorage,
                    column: Int, row: Int)] = []
        for (index, tile) in tiles.enumerated() {
            switch tile {
            case .empty:
                result.append(.full)
            case .full:
                result.append(.empty)
            case .partial(let storage):
                result.append(.empty)   // replaced below
                jobs.append((index, storage, index % columns, index / columns))
            }
        }
        if !jobs.isEmpty {
            let items = jobs
            let boxes = items.map { _ in SelectionMaskTileBox() }
            let maskSize = size
            DispatchQueue.concurrentPerform(iterations: items.count) { jobIndex in
                boxes[jobIndex].tile = Self.invertNormalized(
                    items[jobIndex].storage,
                    inCanvas: Self.inCanvasRect(column: items[jobIndex].column,
                                                row: items[jobIndex].row, size: maskSize))
            }
            // concurrentPerform returned, so every box's write is visible here.
            for box in zip(items, boxes) { result[box.0.index] = box.1.tile }
        }
        return SelectionMask(size: size, normalizedTiles: result)
    }

    /// Per-tile combination with constant fast paths; `concurrentPerform` over the
    /// remaining partial/partial pairs (results are per-pixel independent, so the outcome
    /// is bit-identical to the serial loop). A different size is a defined no-op.
    func combined(with operand: SelectionMask, mode: SelectionCombineMode) -> SelectionMask {
        guard operand.size == size else { return self }
        let columns = max(1, gridColumns)
        var result = tiles
        var jobs: [(index: Int, a: SelectionMaskTileStorage, b: SelectionMaskTileStorage)] = []
        for index in tiles.indices {
            let a = tiles[index]
            let b = operand.tiles[index]
            if let fast = Self.fastPath(a: a, b: b, mode: mode, column: index % columns,
                                        row: index / columns, size: size) {
                result[index] = Self.normalize(fast, column: index % columns,
                                               row: index / columns, size: size)
            } else if case let .partial(storageA) = a, case let .partial(storageB) = b {
                jobs.append((index, storageA, storageB))
            }
        }
        if !jobs.isEmpty {
            let items = jobs
            let boxes = items.map { _ in SelectionMaskTileBox() }
            DispatchQueue.concurrentPerform(iterations: items.count) { jobIndex in
                boxes[jobIndex].tile = Self.combinePartialTiles(items[jobIndex].a,
                                                                items[jobIndex].b, mode: mode)
            }
            // concurrentPerform returned, so every box's write is visible here.
            for (job, box) in zip(items, boxes) {
                result[job.index] = Self.normalize(box.tile, column: job.index % columns,
                                                   row: job.index / columns, size: size)
            }
        }
        return SelectionMask(size: size, normalizedTiles: result)
    }

    // MARK: - Internals

    private static func gridColumns(size: PixelSize) -> Int {
        (size.width + tileSize - 1) / tileSize
    }

    private static func gridRows(size: PixelSize) -> Int {
        (size.height + tileSize - 1) / tileSize
    }

    private static func gridTileCount(size: PixelSize) -> Int {
        max(0, gridColumns(size: size)) * max(0, gridRows(size: size))
    }

    /// The tile's pixels that lie inside `size`, in canvas coordinates.
    private static func inCanvasRect(column: Int, row: Int, size: PixelSize) -> PixelRect {
        PixelRect(x: column * tileSize, y: row * tileSize, width: tileSize, height: tileSize)
            .intersection(size.bounds)
    }

    /// `.partial` → out-of-canvas bytes zeroed, all-0 → `.empty`, all-255-in-canvas →
    /// `.full`; unchanged storages are reused, never copied.
    private static func normalize(_ tile: SelectionMaskTile, column: Int, row: Int,
                                  size: PixelSize) -> SelectionMaskTile {
        guard case let .partial(storage) = tile else { return tile }
        let inCanvas = inCanvasRect(column: column, row: row, size: size)
        if inCanvas.isEmpty { return .empty }
        let localMinX = inCanvas.minX - column * tileSize
        let localMaxX = inCanvas.maxX - column * tileSize
        let localMinY = inCanvas.minY - row * tileSize
        let localMaxY = inCanvas.maxY - row * tileSize
        let tileFullyInside = localMinX == 0 && localMinY == 0
            && localMaxX == tileSize && localMaxY == tileSize
        let bytes = storage.bytes
        var allZero = true
        var allFull = true
        var outsideDirty = false
        if tileFullyInside {
            for value in bytes {
                if value != 0 { allZero = false }
                if value != 255 { allFull = false }
                if !allZero && !allFull { break }
            }
        } else {
            for y in 0..<tileSize {
                let rowStart = y * tileSize
                let insideRow = y >= localMinY && y < localMaxY
                for x in 0..<tileSize {
                    let value = bytes[rowStart + x]
                    if insideRow && x >= localMinX && x < localMaxX {
                        if value != 0 { allZero = false }
                        if value != 255 { allFull = false }
                    } else if value != 0 {
                        outsideDirty = true
                    }
                }
            }
        }
        if allZero { return .empty }
        if allFull { return .full }
        guard outsideDirty else { return tile }
        var cleaned = bytes
        for y in localMaxY..<tileSize {
            let rowStart = y * tileSize
            for x in 0..<tileSize { cleaned[rowStart + x] = 0 }
        }
        for y in 0..<localMinY {
            let rowStart = y * tileSize
            for x in 0..<tileSize { cleaned[rowStart + x] = 0 }
        }
        for y in localMinY..<localMaxY {
            let rowStart = y * tileSize
            for x in 0..<localMinX { cleaned[rowStart + x] = 0 }
            for x in localMaxX..<tileSize { cleaned[rowStart + x] = 0 }
        }
        return .partial(SelectionMaskTileStorage(bytes: cleaned))
    }

    /// Constant-tile shortcuts; every result equals the per-pixel table (tested for every
    /// tile-kind pair and mode). `nil` = run the per-pixel path.
    private static func fastPath(a: SelectionMaskTile, b: SelectionMaskTile,
                                 mode: SelectionCombineMode, column: Int, row: Int,
                                 size: PixelSize) -> SelectionMaskTile? {
        let aIsEmpty: Bool = if case .empty = a { true } else { false }
        let bIsEmpty: Bool = if case .empty = b { true } else { false }
        let aIsFull: Bool = if case .full = a { true } else { false }
        let bIsFull: Bool = if case .full = b { true } else { false }
        /// `255 − partial` over the in-canvas rectangle (out-of-canvas bytes stay 0),
        /// normalized — the constant-tile form of the per-pixel table.
        func inverted(_ tile: SelectionMaskTile) -> SelectionMaskTile {
            guard case let .partial(storage) = tile else {
                switch tile {
                case .empty: return .full
                case .full: return .empty
                case .partial: return tile
                }
            }
            let invertedTile: SelectionMaskTile =
                .partial(invertBytes(storage, inCanvas: inCanvasRect(column: column,
                                                                     row: row, size: size)))
            return normalize(invertedTile, column: column, row: row, size: size)
        }
        switch mode {
        case .replace:
            return b
        case .union:
            if aIsEmpty { return b }
            if bIsEmpty { return a }
            if aIsFull || bIsFull { return .full }
            return nil
        case .intersect:
            if aIsEmpty || bIsEmpty { return .empty }
            if aIsFull { return b }
            if bIsFull { return a }
            return nil
        case .exclude:
            if aIsEmpty { return .empty }
            if bIsEmpty { return a }
            if bIsFull { return .empty }
            if aIsFull { return inverted(b) }   // full ∖ partial = invert(partial)
            return nil
        case .xor:
            if aIsEmpty { return b }
            if bIsEmpty { return a }
            if aIsFull { return inverted(b) }
            if bIsFull { return inverted(a) }
            return nil
        }
    }

    /// `255 − v` over the in-canvas rectangle, out-of-canvas bytes staying 0.
    /// Invert + normalize in a single pass: the source is scanned once, the inverted
    /// bytes are written, and the all-0 / all-255 (in-canvas) verdict is decided on the
    /// fly, so `inverted()` never rescans the grid (NF-1). Out-of-canvas bytes stay 0.
    private static func invertNormalized(_ storage: SelectionMaskTileStorage,
                                         inCanvas: PixelRect) -> SelectionMaskTile {
        var bytes = [UInt8](repeating: 0, count: SelectionMaskTileStorage.byteCount)
        var allZero = true
        var allFull = true
        storage.bytes.withUnsafeBufferPointer { source in
            bytes.withUnsafeMutableBufferPointer { target in
                for y in inCanvas.minY..<inCanvas.maxY {
                    let rowStart = (y & 255) * tileSize
                    for x in inCanvas.minX..<inCanvas.maxX {
                        let value = 255 &- source[rowStart + (x & 255)]
                        target[rowStart + (x & 255)] = value
                        if value != 0 { allZero = false }
                        if value != 255 { allFull = false }
                    }
                }
            }
        }
        if allZero { return .empty }
        if allFull { return .full }
        return .partial(SelectionMaskTileStorage(bytes: bytes))
    }

    private static func invertBytes(_ storage: SelectionMaskTileStorage,
                                    inCanvas: PixelRect) -> SelectionMaskTileStorage {
        var bytes = [UInt8](repeating: 0, count: SelectionMaskTileStorage.byteCount)
        storage.bytes.withUnsafeBufferPointer { source in
            bytes.withUnsafeMutableBufferPointer { target in
                for y in inCanvas.minY..<inCanvas.maxY {
                    let rowStart = (y & 255) * tileSize
                    for x in inCanvas.minX..<inCanvas.maxX {
                        target[rowStart + (x & 255)] = 255 &- source[rowStart + (x & 255)]
                    }
                }
            }
        }
        return SelectionMaskTileStorage(bytes: bytes)
    }

    /// The per-pixel loop for a partial/partial pair, reusing an operand's storage when
    /// every byte of the result equals it. Out-of-canvas bytes are 0 in both operands, so
    /// every mode keeps the invariant there.
    private static func combinePartialTiles(_ a: SelectionMaskTileStorage,
                                            _ b: SelectionMaskTileStorage,
                                            mode: SelectionCombineMode) -> SelectionMaskTile {
        var result = [UInt8](repeating: 0, count: SelectionMaskTileStorage.byteCount)
        var differsFromA = false
        var differsFromB = false
        a.bytes.withUnsafeBufferPointer { left in
            b.bytes.withUnsafeBufferPointer { right in
                result.withUnsafeMutableBufferPointer { out in
                    for offset in 0..<SelectionMaskTileStorage.byteCount {
                        let value = mode.combine(left[offset], right[offset])
                        out[offset] = value
                        if value != left[offset] { differsFromA = true }
                        if value != right[offset] { differsFromB = true }
                    }
                }
            }
        }
        if !differsFromA { return .partial(a) }
        if !differsFromB { return .partial(b) }
        return .partial(SelectionMaskTileStorage(bytes: result))
    }

    private static func computeBounds(tiles: [SelectionMaskTile], size: PixelSize) -> PixelRect {
        let columns = max(1, gridColumns(size: size))
        var result = PixelRect.zero
        for (index, tile) in tiles.enumerated() {
            let column = index % columns
            let row = index / columns
            switch tile {
            case .empty:
                continue
            case .full:
                result = result.union(inCanvasRect(column: column, row: row, size: size))
            case .partial(let storage):
                let inCanvas = inCanvasRect(column: column, row: row, size: size)
                var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
                for y in inCanvas.minY..<inCanvas.maxY {
                    let rowStart = (y & 255) * tileSize
                    for x in inCanvas.minX..<inCanvas.maxX where storage.bytes[rowStart + (x & 255)] != 0 {
                        if x < minX { minX = x }
                        if x >= maxX { maxX = x + 1 }
                        if y < minY { minY = y }
                        if y >= maxY { maxY = y + 1 }
                    }
                }
                if maxX > minX {
                    result = result.union(PixelRect(x: minX, y: minY,
                                                    width: maxX - minX, height: maxY - minY))
                }
            }
        }
        return result
    }
}

extension SelectionMask: BrushClipMask {}
