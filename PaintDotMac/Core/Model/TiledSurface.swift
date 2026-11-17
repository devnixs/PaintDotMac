import CoreGraphics
import Foundation

/// A tile grid position (NF-4). Comparison is row-major.
struct TileCoordinate: Hashable, Comparable, Sendable {
    var column: Int
    var row: Int

    static func < (lhs: TileCoordinate, rhs: TileCoordinate) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

/// One 256×256 RGBA8 tile (NF-4). Swift array copy-on-write is the tile's copy-on-write:
/// copying a `Tile` shares the buffer until one copy is mutated.
struct Tile: Equatable, Sendable {
    static let size = 256
    static let bytesPerRow = size * PixelFormat.rgba8.bytesPerPixel  // 1,024
    static let byteCount = size * bytesPerRow                        // 262,144

    /// Exactly `byteCount` bytes, row-major, R G B A per pixel.
    private(set) var bytes: [UInt8]

    init() {
        bytes = [UInt8](repeating: 0, count: Self.byteCount)
    }

    init(filledWith color: ColorRGBA8) {
        var pattern: [UInt8] = [color.red, color.green, color.blue, color.alpha]
        while pattern.count < Self.byteCount {
            pattern.append(contentsOf: pattern)
        }
        bytes = pattern
    }

    init(bytes: [UInt8]) {
        precondition(bytes.count == Self.byteCount, "Tile needs \(Self.byteCount) bytes, got \(bytes.count)")
        self.bytes = bytes
    }

    /// Tile-local coordinates.
    func pixel(x: Int, y: Int) -> ColorRGBA8 {
        precondition((0..<Self.size).contains(x) && (0..<Self.size).contains(y), "tile pixel (\(x), \(y)) out of range")
        let offset = y * Self.bytesPerRow + x * PixelFormat.rgba8.bytesPerPixel
        // The offset is derived from validated in-range coordinates, so the four bytes exist.
        return ColorRGBA8(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2], alpha: bytes[offset + 3])
    }

    mutating func setPixel(_ color: ColorRGBA8, x: Int, y: Int) {
        precondition((0..<Self.size).contains(x) && (0..<Self.size).contains(y), "tile pixel (\(x), \(y)) out of range")
        let offset = y * Self.bytesPerRow + x * PixelFormat.rgba8.bytesPerPixel
        bytes[offset] = color.red
        bytes[offset + 1] = color.green
        bytes[offset + 2] = color.blue
        bytes[offset + 3] = color.alpha
    }

    /// Every byte is 0. Scanned 8 bytes at a time (`loadUnaligned`: the byte buffer's base
    /// address is not guaranteed 8-aligned).
    var isFullyTransparent: Bool {
        withUnsafeBytes { buffer in
            var offset = 0
            while offset + 8 <= buffer.count {
                if buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self) != 0 { return false }
                offset += 8
            }
            while offset < buffer.count {
                if buffer[offset] != 0 { return false }
                offset += 1
            }
            return true
        }
    }

    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes(body)
    }

    mutating func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeMutableBytes(body)
    }

    /// True when both tiles use the same buffer. Used by tests and by 0008 to prove that
    /// diffs share memory. Two live `Array` buffers never share an address without sharing
    /// storage, so a base-address comparison is exact here.
    func sharesStorage(with other: Tile) -> Bool {
        bytes.withUnsafeBufferPointer { $0.baseAddress }
            == other.bytes.withUnsafeBufferPointer { $0.baseAddress }
    }
}

/// Sparse, copy-on-write 256×256-tiled RGBA8 pixel store (NF-4, APP-10, AGENTS rule 3).
/// A fully transparent tile is not allocated; copying the surface shares every tile buffer
/// until a mutation touches it. Edge tiles are full 256×256 tiles whose pixels outside
/// `bounds` are always `(0, 0, 0, 0)`.
struct TiledSurface: Equatable, Sendable {
    static let tileSize = Tile.size

    let size: PixelSize
    let format: PixelFormat
    var bounds: PixelRect { size.bounds }

    /// ⌈width / 256⌉
    let tileColumns: Int
    /// ⌈height / 256⌉
    let tileRows: Int
    var tileCount: Int { tileColumns * tileRows }

    /// Row-major; `nil` means fully transparent.
    private var tiles: [Tile?]
    /// Same count as `tiles`; the value of `generation` when the tile last changed.
    private var tileGenerations: [UInt64]

    /// Starts at 0; every mutating call that touches at least one tile increments it by 1.
    private(set) var generation: UInt64 = 0

    init(size: PixelSize, format: PixelFormat = .rgba8) {
        precondition(
            (ImageLimits.minimumSide...ImageLimits.maximumSide).contains(size.width)
                && (ImageLimits.minimumSide...ImageLimits.maximumSide).contains(size.height),
            "surface size \(size) outside \(ImageLimits.minimumSide)…\(ImageLimits.maximumSide); validate user sizes with ImageLimits.validate"
        )
        self.size = size
        self.format = format
        tileColumns = (size.width + Self.tileSize - 1) / Self.tileSize
        tileRows = (size.height + Self.tileSize - 1) / Self.tileSize
        tiles = [Tile?](repeating: nil, count: tileColumns * tileRows)
        tileGenerations = [UInt64](repeating: 0, count: tileColumns * tileRows)
    }

    /// Bulk import from a tightly or loosely packed straight RGBA8 buffer. Copies row
    /// segments with `copyMemory` and does not allocate any tile whose pixels are all zero.
    /// Used by the decoder and by 0021's clipboard codec.
    init(size: PixelSize, format: PixelFormat = .rgba8, rgba8 source: UnsafeRawBufferPointer, bytesPerRow: Int) {
        precondition(bytesPerRow >= size.width * format.bytesPerPixel,
                     "bytesPerRow \(bytesPerRow) narrower than \(size.width) px")
        precondition(source.count >= bytesPerRow * (size.height - 1) + size.width * format.bytesPerPixel,
                     "source buffer (\(source.count) bytes) too small for \(size)")
        self.init(size: size, format: format)
        let bpp = format.bytesPerPixel
        for row in 0..<tileRows {
            for column in 0..<tileColumns {
                let coordinate = TileCoordinate(column: column, row: row)
                let area = pixelRect(of: coordinate)
                var tile = Tile()
                var sawNonZeroByte = false
                tile.withUnsafeMutableBytes { destination in
                    for y in 0..<area.height {
                        let sourceOffset = (area.minY + y) * bytesPerRow + area.minX * bpp
                        let destinationOffset = y * Tile.bytesPerRow + 0
                        UnsafeMutableRawBufferPointer(rebasing: destination[destinationOffset ..< destinationOffset + area.width * bpp])
                            .copyMemory(from: UnsafeRawBufferPointer(rebasing: source[sourceOffset ..< sourceOffset + area.width * bpp]))
                    }
                    var offset = 0
                    while offset + 8 <= Tile.byteCount {
                        if destination.loadUnaligned(fromByteOffset: offset, as: UInt64.self) != 0 {
                            sawNonZeroByte = true
                            break
                        }
                        offset += 8
                    }
                    if !sawNonZeroByte {
                        while offset < Tile.byteCount {
                            if destination[offset] != 0 {
                                sawNonZeroByte = true
                                break
                            }
                            offset += 1
                        }
                    }
                }
                if sawNonZeroByte { tiles[index(of: coordinate)] = tile }
            }
        }
    }

    // MARK: - Grid queries

    func pixelRect(of tile: TileCoordinate) -> PixelRect {
        PixelRect(x: tile.column * Self.tileSize, y: tile.row * Self.tileSize,
                  width: Self.tileSize, height: Self.tileSize)
            .intersection(bounds)
    }

    func tileCoordinate(containing point: PixelPoint) -> TileCoordinate {
        precondition(bounds.contains(point), "point \(point) outside \(bounds)")
        return TileCoordinate(column: point.x / Self.tileSize, row: point.y / Self.tileSize)
    }

    /// Row-major tiles intersecting `rect` (clipped to `bounds` first). Empty for an empty
    /// or fully out-of-bounds rect.
    func tileCoordinates(intersecting rect: PixelRect) -> [TileCoordinate] {
        let clipped = rect.intersection(bounds)
        guard !clipped.isEmpty else { return [] }
        let firstColumn = clipped.minX / Self.tileSize
        let lastColumn = (clipped.maxX - 1) / Self.tileSize
        let firstRow = clipped.minY / Self.tileSize
        let lastRow = (clipped.maxY - 1) / Self.tileSize
        var result: [TileCoordinate] = []
        result.reserveCapacity((lastRow - firstRow + 1) * (lastColumn - firstColumn + 1))
        for row in firstRow...lastRow {
            for column in firstColumn...lastColumn {
                result.append(TileCoordinate(column: column, row: row))
            }
        }
        return result
    }

    private func index(of coordinate: TileCoordinate) -> Int {
        precondition((0..<tileColumns).contains(coordinate.column) && (0..<tileRows).contains(coordinate.row),
                     "tile coordinate \(coordinate) outside the \(tileColumns) × \(tileRows) grid")
        return coordinate.row * tileColumns + coordinate.column
    }

    private func coordinate(at index: Int) -> TileCoordinate {
        TileCoordinate(column: index % tileColumns, row: index / tileColumns)
    }

    func tile(at coordinate: TileCoordinate) -> Tile? {
        tiles[index(of: coordinate)]
    }

    /// The low-level hook for 0008 (undo/redo restores whole tiles). Always stamps the tile
    /// as changed. In Debug builds a non-nil tile must honour the edge-padding invariant.
    mutating func setTile(_ tile: Tile?, at coordinate: TileCoordinate) {
        let i = index(of: coordinate)
        #if DEBUG
        if let tile, !Self.paddingIsZero(tile, inBoundsSize: pixelRect(of: coordinate).size) {
            preconditionFailure("setTile received a tile with non-zero pixels outside bounds")
        }
        #endif
        tiles[i] = tile
        stamp([i])
    }

    var allocatedTileCoordinates: [TileCoordinate] {
        (0..<tiles.count).compactMap { tiles[$0] != nil ? coordinate(at: $0) : nil }
    }

    var allocatedTileCount: Int { tiles.lazy.filter { $0 != nil }.count }

    // MARK: - Pixels

    /// `.clear` for an unallocated tile and for any point outside `bounds` (no trap).
    func pixel(at point: PixelPoint) -> ColorRGBA8 {
        guard bounds.contains(point) else { return .clear }
        let tile = tiles[index(of: tileCoordinate(containing: point))]
        guard let tile else { return .clear }
        return tile.pixel(x: point.x % Self.tileSize, y: point.y % Self.tileSize)
    }

    /// A no-op outside `bounds`. Writing all-zero bytes into an unallocated tile is a no-op;
    /// any other write allocates the tile if needed and stamps it.
    mutating func setPixel(_ color: ColorRGBA8, at point: PixelPoint) {
        guard bounds.contains(point) else { return }
        let i = index(of: tileCoordinate(containing: point))
        if tiles[i] == nil {
            if color == .clear { return }
            tiles[i] = Tile()
        }
        // Allocated just above (or already allocated); `!` is safe on this branch.
        tiles[i]!.setPixel(color, x: point.x % Self.tileSize, y: point.y % Self.tileSize)
        stamp([i])
    }

    // MARK: - Regions

    /// `rect.width × rect.height × 4` bytes, row-major, tightly packed. Pixels outside
    /// `bounds` and in unallocated tiles read as zero.
    func readPixels(in rect: PixelRect) -> [UInt8] {
        let bpp = format.bytesPerPixel
        var result = [UInt8](repeating: 0, count: rect.width * rect.height * bpp)
        guard !rect.isEmpty else { return result }
        result.withUnsafeMutableBytes { buffer in
            readPixels(in: rect, into: buffer, bytesPerRow: rect.width * bpp)
        }
        return result
    }

    /// Same, into a caller buffer with the given row stride.
    func readPixels(in rect: PixelRect, into destination: UnsafeMutableRawBufferPointer, bytesPerRow: Int) {
        let bpp = format.bytesPerPixel
        let required = rect.isEmpty ? 0 : bytesPerRow * (rect.height - 1) + rect.width * bpp
        precondition(destination.count >= required,
                     "destination (\(destination.count) bytes) too small for \(rect) at stride \(bytesPerRow)")
        let clipped = rect.intersection(bounds)
        guard !clipped.isEmpty else { return }
        for coordinate in tileCoordinates(intersecting: clipped) {
            guard let tile = tiles[index(of: coordinate)] else { continue }
            let tileRect = Self.fullRect(of: coordinate)
            let overlap = tileRect.intersection(clipped)
            tile.withUnsafeBytes { source in
                for row in 0..<overlap.height {
                    let destinationOffset = (overlap.minY + row - rect.y) * bytesPerRow
                        + (overlap.minX - rect.x) * bpp
                    let sourceOffset = (overlap.minY + row - tileRect.y) * Tile.bytesPerRow
                        + (overlap.minX - tileRect.x) * bpp
                    UnsafeMutableRawBufferPointer(rebasing: destination[destinationOffset ..< destinationOffset + overlap.width * bpp])
                        .copyMemory(from: UnsafeRawBufferPointer(rebasing: source[sourceOffset ..< sourceOffset + overlap.width * bpp]))
                }
            }
        }
    }

    /// Writes `rect.width × rect.height × 4` tightly packed bytes; parts of `rect` outside
    /// `bounds` are clipped silently. An unallocated tile whose incoming bytes are all zero
    /// stays unallocated.
    mutating func writePixels(_ source: UnsafeRawBufferPointer, bytesPerRow: Int, to rect: PixelRect) {
        let bpp = format.bytesPerPixel
        let required = rect.isEmpty ? 0 : bytesPerRow * (rect.height - 1) + rect.width * bpp
        precondition(source.count >= required,
                     "source (\(source.count) bytes) too small for \(rect) at stride \(bytesPerRow)")
        writeRegions(in: rect) { tile, overlap, tileRect in
            for row in 0..<overlap.height {
                let sourceOffset = (overlap.minY + row - rect.y) * bytesPerRow
                    + (overlap.minX - rect.x) * bpp
                let destinationOffset = (overlap.minY + row - tileRect.y) * Tile.bytesPerRow
                    + (overlap.minX - tileRect.x) * bpp
                UnsafeMutableRawBufferPointer(rebasing: tile[destinationOffset ..< destinationOffset + overlap.width * bpp])
                    .copyMemory(from: UnsafeRawBufferPointer(rebasing: source[sourceOffset ..< sourceOffset + overlap.width * bpp]))
            }
        } incomingAreZero: { overlap in
            Self.regionIsZero(in: source, bytesPerRow: bytesPerRow, rect: overlap, relativeTo: rect.origin, bpp: bpp)
        }
    }

    mutating func writePixels(_ bytes: [UInt8], to rect: PixelRect) {
        precondition(bytes.count == rect.width * rect.height * format.bytesPerPixel,
                     "expected \(rect.width * rect.height * format.bytesPerPixel) bytes, got \(bytes.count)")
        bytes.withUnsafeBytes { buffer in
            writePixels(buffer, bytesPerRow: rect.width * format.bytesPerPixel, to: rect)
        }
    }

    /// Fill `rect` (nil means `bounds`), clipped to `bounds`. All-zero color releases fully
    /// covered tiles and zeroes partly covered ones without allocating. Any other color:
    /// fully covered interior tiles share one `Tile` buffer; fully covered edge tiles get
    /// their own tile with zero padding; partly covered tiles are written pixel by pixel.
    mutating func fill(_ color: ColorRGBA8, in rect: PixelRect? = nil) {
        let clipped = (rect ?? bounds).intersection(bounds)
        guard !clipped.isEmpty else { return }
        var isAllZeroColor: Bool { color.red == 0 && color.green == 0 && color.blue == 0 && color.alpha == 0 }
        var touched: [Int] = []
        var sharedTile: Tile?

        for coordinate in tileCoordinates(intersecting: clipped) {
            let i = index(of: coordinate)
            let tileRect = Self.fullRect(of: coordinate)
            let area = tileRect.intersection(bounds)          // the tile's in-bounds area
            let covered = area.intersection(clipped)
            let fullyCovered = covered == area
            let isInterior = area == tileRect

            if isAllZeroColor {
                if fullyCovered {
                    if tiles[i] != nil {
                        tiles[i] = nil
                        touched.append(i)
                    }
                } else if tiles[i] != nil {
                    let origin = tileRect.origin
                    tiles[i]!.zeroRect(covered, relativeTo: origin)  // allocated on this branch
                    touched.append(i)
                }
            } else if fullyCovered {
                if isInterior {
                    if sharedTile == nil { sharedTile = Tile(filledWith: color) }
                    // Assigning the same `Tile` value shares its buffer until a tile is written.
                    tiles[i] = sharedTile
                } else {
                    var tile = Tile(filledWith: color)
                    tile.zeroOutside(area: area.size)   // edge tile: keep out-of-bounds pixels zero
                    tiles[i] = tile
                }
                touched.append(i)
            } else {
                if tiles[i] == nil { tiles[i] = Tile() }
                let origin = tileRect.origin
                tiles[i]!.fillRect(color, covered, relativeTo: origin)  // allocated just above
                touched.append(i)
            }
        }
        stamp(touched)
    }

    /// Frees every allocated tile that is fully transparent. Writes never free tiles on
    /// their own; operations that may clear large areas (0018, 0008) call this.
    mutating func releaseTransparentTiles() {
        var touched: [Int] = []
        for i in tiles.indices {
            if let tile = tiles[i], tile.isFullyTransparent {
                tiles[i] = nil
                touched.append(i)
            }
        }
        stamp(touched)
    }

    /// Row-major tiles whose generation is greater than the argument (0003's renderer,
    /// 0025's thumbnails).
    func changedTiles(since generation: UInt64) -> [TileCoordinate] {
        (0..<tileGenerations.count).compactMap { tileGenerations[$0] > generation ? coordinate(at: $0) : nil }
    }

    // MARK: - CGImage

    /// A straight-alpha sRGB CGImage of the whole surface, built from `readPixels(in:
    /// bounds)`. `nil` only if `CGImage(...)` fails.
    func makeCGImage() -> CGImage? {
        let bpp = format.bytesPerPixel
        let bytes = readPixels(in: bounds)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let colorSpace = CGColorSpace(name: format.colorSpaceName)
        else { return nil }
        return CGImage(
            width: size.width, height: size.height,
            bitsPerComponent: 8, bitsPerPixel: 8 * bpp,
            bytesPerRow: size.width * bpp,
            space: colorSpace, bitmapInfo: format.cgBitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    // MARK: - Equality

    /// Equal `size` and equal pixels; an unallocated tile equals an allocated all-zero
    /// tile. Generations are ignored.
    static func == (lhs: TiledSurface, rhs: TiledSurface) -> Bool {
        guard lhs.size == rhs.size, lhs.format == rhs.format else { return false }
        for i in lhs.tiles.indices {
            switch (lhs.tiles[i], rhs.tiles[i]) {
            case (nil, nil): break
            case let (left?, right?): if left != right { return false }
            case let (left?, nil): if !left.isFullyTransparent { return false }
            case let (nil, right?): if !right.isFullyTransparent { return false }
            }
        }
        return true
    }

    // MARK: - Private helpers

    private static func fullRect(of coordinate: TileCoordinate) -> PixelRect {
        PixelRect(x: coordinate.column * tileSize, y: coordinate.row * tileSize,
                  width: tileSize, height: tileSize)
    }

    /// Every byte of `tile` outside its in-bounds area of `inBoundsSize` is zero.
    private static func paddingIsZero(_ tile: Tile, inBoundsSize: PixelSize) -> Bool {
        tile.paddingIsZero(inBounds: inBoundsSize)
    }

    /// Mutating-write scaffold shared by the `writePixels` variants: for every tile the
    /// clipped rect touches, allocates it when needed (skipping it when it is unallocated
    /// and the incoming bytes are all zero), runs `write` with the tile's mutable bytes and
    /// the overlap in image coordinates, then stamps all written tiles.
    private mutating func writeRegions(
        in rect: PixelRect,
        write: (UnsafeMutableRawBufferPointer, _ overlap: PixelRect, _ tileRect: PixelRect) -> Void,
        incomingAreZero: (PixelRect) -> Bool
    ) {
        let clipped = rect.intersection(bounds)
        guard !clipped.isEmpty else { return }
        var touched: [Int] = []
        for coordinate in tileCoordinates(intersecting: clipped) {
            let i = index(of: coordinate)
            let tileRect = Self.fullRect(of: coordinate)
            let overlap = tileRect.intersection(clipped)
            if tiles[i] == nil {
                if incomingAreZero(overlap) { continue }
                tiles[i] = Tile()
            }
            // Allocated just above (or already allocated); `!` is safe on this branch.
            tiles[i]!.withUnsafeMutableBytes { buffer in
                write(buffer, overlap, tileRect)
            }
            touched.append(i)
        }
        stamp(touched)
    }

    /// True when every byte the clipped `rect` would read from the source is zero. The
    /// rect's coordinates are absolute image positions mapped by `origin`.
    private static func regionIsZero(in source: UnsafeRawBufferPointer, bytesPerRow: Int,
                                     rect: PixelRect, relativeTo origin: PixelPoint, bpp: Int) -> Bool {
        for row in 0..<rect.height {
            let rowStart = (rect.minY + row - origin.y) * bytesPerRow + (rect.minX - origin.x) * bpp
            let end = rowStart + rect.width * bpp
            for byte in rowStart..<end where source[byte] != 0 {
                return false
            }
        }
        return true
    }

    /// One generation bump for the touched tiles (deduplicated), none for an empty set.
    private mutating func stamp(_ indices: [Int]) {
        guard !indices.isEmpty else { return }
        generation &+= 1
        for i in Set(indices) { tileGenerations[i] = generation }
    }
}

private extension Tile {
    /// Zero the absolute image `rect` (mapped by `origin`); caller guarantees it lies
    /// inside the tile.
    mutating func zeroRect(_ rect: PixelRect, relativeTo origin: PixelPoint) {
        withUnsafeMutableBytes { buffer in
            for row in 0..<rect.height {
                let offset = (rect.minY + row - origin.y) * Tile.bytesPerRow + (rect.minX - origin.x) * 4
                for byte in offset..<offset + rect.width * 4 { buffer[byte] = 0 }
            }
        }
    }

    /// Write `color` into the absolute image `rect` (mapped by `origin`), pixel by pixel.
    mutating func fillRect(_ color: ColorRGBA8, _ rect: PixelRect, relativeTo origin: PixelPoint) {
        withUnsafeMutableBytes { buffer in
            for row in 0..<rect.height {
                let base = (rect.minY + row - origin.y) * Tile.bytesPerRow + (rect.minX - origin.x) * 4
                for column in 0..<rect.width {
                    let offset = base + column * 4
                    buffer[offset] = color.red
                    buffer[offset + 1] = color.green
                    buffer[offset + 2] = color.blue
                    buffer[offset + 3] = color.alpha
                }
            }
        }
    }

    /// True when every byte outside the in-bounds area `(0, 0, inBounds.width,
    /// inBounds.height)` is zero.
    func paddingIsZero(inBounds area: PixelSize) -> Bool {
        withUnsafeBytes { buffer in
            // Every padding run is one contiguous row segment (columns `firstColumn…`
            // of the row), so scan it 8 bytes at a time; `isFullyTransparent` does the
            // same (0002). The DEBUG `setTile` check calls this per stored tile, and a
            // per-byte loop costs more than the fill itself on a 4000×3000 layer (0018).
            for y in 0..<Tile.size {
                let firstColumn = y < area.height ? area.width : 0
                var offset = y * Tile.bytesPerRow + firstColumn * 4
                let end = (y + 1) * Tile.bytesPerRow
                while offset + 8 <= end {
                    if buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self) != 0 { return false }
                    offset += 8
                }
                while offset < end {
                    if buffer[offset] != 0 { return false }
                    offset += 1
                }
            }
            return true
        }
    }
}

extension Tile {
    /// Zero every pixel outside the in-canvas area `(0, 0, area.width, area.height)`,
    /// so a tile stored at an edge coordinate honours the padding invariant `setTile`
    /// asserts. One helper for every writer that stamps `Tile(filledWith:)` — which
    /// fills the padding too — onto a partially covered coordinate (0002's `fill`,
    /// 0018's Fill Selection).
    mutating func zeroOutside(area: PixelSize) {
        guard area.width < Self.size || area.height < Self.size else { return }
        withUnsafeMutableBytes { buffer in
            for y in 0..<Self.size {
                let firstColumn = y < area.height ? area.width : 0
                for x in firstColumn..<Self.size {
                    let offset = y * Self.bytesPerRow + x * 4
                    buffer[offset] = 0
                    buffer[offset + 1] = 0
                    buffer[offset + 2] = 0
                    buffer[offset + 3] = 0
                }
            }
        }
    }
}

