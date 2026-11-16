import CoreGraphics
import Foundation

// MARK: - Flood mode (spec 0016, PRD T-4)

/// How a flood fill spreads from the seed (Paint.NET MagicWand.html "Flood Mode":
/// *Contiguous* spreads until neighbors fail the Tolerance; *Global* takes every pixel
/// in the layer that satisfies it). Shared with 0017's Paint Bucket.
enum FloodMode: String, CaseIterable, Sendable {
    case contiguous
    case global

    var displayName: String {
        switch self {
        case .contiguous: "Contiguous"
        case .global: "Global"
        }
    }
}

// MARK: - Tolerance (Paint.NET 3.36 `FloodToolBase`)

/// Paint.NET's tolerance scaling: the slider value 0…100 maps to the integer
/// `tol = (int)(t · t · 256)` computed in `Float` (`t = percent / 100`), exactly as
/// `FloodToolBase.OnMouseDown` does. The comparison threshold is `tol² × 4`
/// (`CheckColor`'s `sum <= tolerance * tolerance * 4`).
struct FloodTolerance: Sendable, Equatable {
    /// The clamped slider value (0…100).
    let percent: Int
    /// `Int(t · t · 256)` in `Float` with C#'s truncation (non-negative → floor).
    /// Normative table (spec 0016): 0→0, 10→2, 25→16, 30→23, 50→64, 70→125, 99→250,
    /// 100→256.
    let scaled: Int

    init(percent: Int) {
        let clamped = min(max(percent, 0), 100)
        let t = Float(clamped) / 100
        self.percent = clamped
        self.scaled = Int(t * t * 256)
    }

    /// The inclusive `CheckColor` limit, 0 … 262 144.
    var maxDistance: Int { scaled * scaled * 4 }

    /// Paint.NET's long-standing default (PRD T-4 / D-43).
    static let `default` = FloodTolerance(percent: 50)
}

// MARK: - Color metric

/// Paint.NET 3.36's `FloodToolBase.CheckColor` transcribed exactly (spec 0016; the same
/// code Pinta 1.6 ports verbatim in `FloodTool.cs`). `a` is the seed color: the RGB
/// differences are weighted by the **seed's** alpha, so the metric is asymmetric, and a
/// fully transparent seed ignores RGB entirely. `Int` (64-bit) arithmetic gives
/// bit-identical results to C#'s 32-bit version because the largest intermediate is
/// `65 026 × 255 = 16 581 630` (no overflow), and `/ 256` of non-negative operands is
/// the same truncating division C# performs.
enum FloodColorMetric {
    /// The `sum` of `CheckColor` (`a` = seed, `b` = candidate).
    static func distance(seed a: ColorRGBA8, candidate b: ColorRGBA8) -> Int {
        let ar = Int(a.red)
        let ag = Int(a.green)
        let ab = Int(a.blue)
        let aa = Int(a.alpha)
        var sum = 0
        var diff = ar - Int(b.red)
        sum += (1 + diff * diff) * aa / 256
        diff = ag - Int(b.green)
        sum += (1 + diff * diff) * aa / 256
        diff = ab - Int(b.blue)
        sum += (1 + diff * diff) * aa / 256
        diff = aa - Int(b.alpha)
        sum += diff * diff
        return sum
    }

    static func matches(seed: ColorRGBA8, candidate: ColorRGBA8,
                        tolerance: FloodTolerance) -> Bool {
        distance(seed: seed, candidate: candidate) <= tolerance.maxDistance
    }
}

// MARK: - Source

/// The pixels a flood fill reads (spec 0016). A flat row-major grid of 256×256 `Tile?`
/// (`nil` = transparent black), so **Layer** sampling copies nothing — the `Tile` values
/// share storage with the live layer (COW) — and **Image** sampling holds at most one
/// composited tile per allocated composite tile, released when the fill returns.
struct FloodFillSource: Sendable {
    let size: PixelSize
    /// ⌈width / 256⌉ × ⌈height / 256⌉, row-major, `tiles.count == gridColumns × gridRows`
    /// for every source the app builds.
    let gridColumns: Int
    let gridRows: Int
    let tiles: [Tile?]

    init(size: PixelSize, tiles: [Tile?]) {
        self.size = size
        self.gridColumns = Self.gridExtent(size.width)
        self.gridRows = Self.gridExtent(size.height)
        self.tiles = tiles
    }

    static func gridExtent(_ side: Int) -> Int {
        side <= 0 ? 0 : (side - 1) / Tile.size + 1
    }

    /// The active layer's **raw stored pixels** — visibility and opacity are ignored and
    /// the color under alpha 0 is kept (0012's Layer-sampling rule; PRD D-28). Takes the
    /// surface's tiles as they are: every source tile `sharesStorage(with:)` the layer's.
    static func layer(_ surface: TiledSurface) -> FloodFillSource {
        var tiles: [Tile?] = []
        tiles.reserveCapacity(surface.tileCount)
        for row in 0..<surface.tileRows {
            for column in 0..<surface.tileColumns {
                tiles.append(surface.tile(at: TileCoordinate(column: column, row: row)))
            }
        }
        return FloodFillSource(size: surface.size, tiles: tiles)
    }

    /// The composite of the visible layers (0012's `CPUCompositor`; PRD D-16). For each
    /// tile coordinate `compositeTile` decides: `nil` stays `nil` (sparse stays sparse);
    /// otherwise the edge-clipped row-major pixels are written into a zero-filled `Tile`
    /// at the 1 024-byte stride.
    static func image(_ image: LayeredImage,
                      compositor: CPUCompositor = CPUCompositor()) -> FloodFillSource {
        let columns = gridExtent(image.size.width)
        let rows = gridExtent(image.size.height)
        var tiles: [Tile?] = []
        tiles.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                guard let pixels = compositor.compositeTile(
                    TileCoordinate(column: column, row: row), of: image), !pixels.isEmpty
                else {
                    tiles.append(nil)
                    continue
                }
                let clippedWidth = min(Tile.size, image.size.width - column * Tile.size)
                let clippedHeight = min(Tile.size, image.size.height - row * Tile.size)
                var tile = Tile()
                tile.withUnsafeMutableBytes { destination in
                    pixels.withUnsafeBytes { source in
                        guard let destinationBase = destination.baseAddress,
                              let sourceBase = source.baseAddress else { return }
                        for line in 0..<clippedHeight {
                            destinationBase
                                .advanced(by: line * Tile.bytesPerRow)
                                .copyMemory(
                                    from: sourceBase.advanced(by: line * clippedWidth * 4),
                                    byteCount: clippedWidth * 4)
                        }
                    }
                }
                tiles.append(tile)
            }
        }
        return FloodFillSource(size: image.size, tiles: tiles)
    }

    static func make(for image: LayeredImage, sampling: SamplingMode,
                     compositor: CPUCompositor = CPUCompositor()) -> FloodFillSource {
        switch sampling {
        case .layer: Self.layer(image.layers[image.activeLayerIndex].surface)
        case .image: Self.image(image, compositor: compositor)
        }
    }

    /// `.clear` outside `size`, beyond the tile grid, or in a `nil` tile. Used by tests
    /// and the seed lookup; the fill loops read tile rows directly.
    func pixel(at point: PixelPoint) -> ColorRGBA8 {
        guard point.x >= 0, point.y >= 0, point.x < size.width, point.y < size.height else {
            return .clear
        }
        let index = (point.y / Tile.size) * gridColumns + point.x / Tile.size
        guard index < tiles.count, let tile = tiles[index] else { return .clear }
        return tile.pixel(x: point.x % Tile.size, y: point.y % Tile.size)
    }
}

// MARK: - Stencil

/// The 1-bit fill result — Paint.NET's `IBitVector2D` stencil. Row-major bits, each row
/// padded to whole 64-bit words (`wordsPerRow = ⌈width / 64⌉`) so rows never share a
/// word and the Global mode can fill rows concurrently. Bits at or beyond `width` are
/// always 0. A 24 MP image costs 3 MB.
struct FloodFillStencil: Sendable, Equatable {
    let size: PixelSize
    let wordsPerRow: Int
    /// `wordsPerRow × size.height` words. Internal so `FloodFill` can hot-loop over the
    /// buffer; every mutator keeps the padding bits 0.
    var words: [UInt64]

    /// `⌈width / 64⌉`, or `nil` for a negative or absurd width. `precondition`-free: the
    /// fill consults it *before* allocating (APP-10 overflow rule).
    static func wordsPerRow(width: Int) -> Int? {
        guard width >= 0 else { return nil }
        return width == 0 ? 0 : (width - 1) / 64 + 1
    }

    /// Total word count, or `nil` when the multiplication overflows.
    static func storageWordCount(width: Int, height: Int) -> Int? {
        guard height >= 0, let wordsPerRow = wordsPerRow(width: width) else { return nil }
        let product = wordsPerRow.multipliedReportingOverflow(by: height)
        return product.overflow ? nil : product.partialValue
    }

    /// An all-zero stencil. `precondition` guards programmer errors exactly like
    /// `TiledSurface.init`: user sizes pass `ImageLimits` first, and `FloodFill.fill`
    /// consults `storageWordCount` before constructing anything, so no user path reaches
    /// an unrepresentable allocation.
    init(size: PixelSize) {
        precondition(
            (ImageLimits.minimumSide...ImageLimits.maximumSide).contains(size.width)
                && (ImageLimits.minimumSide...ImageLimits.maximumSide).contains(size.height),
            "FloodFillStencil needs ImageLimits-sized sides, got \(size)")
        self.size = size
        self.wordsPerRow = Self.wordsPerRow(width: size.width) ?? 0
        self.words = [UInt64](repeating: 0, count: wordsPerRow * size.height)
    }

    func contains(_ point: PixelPoint) -> Bool {
        guard point.x >= 0, point.y >= 0,
              point.x < size.width, point.y < size.height else { return false }
        let word = words[point.y * wordsPerRow + (point.x >> 6)]
        return (word >> UInt64(point.x & 63)) & 1 == 1
    }

    mutating func insert(_ point: PixelPoint) {
        guard point.x >= 0, point.y >= 0,
              point.x < size.width, point.y < size.height else { return }
        let index = point.y * wordsPerRow + (point.x >> 6)
        words[index] |= UInt64(1) << UInt64(point.x & 63)
    }

    var count: Int {
        words.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    var isEmpty: Bool {
        words.allSatisfy { $0 == 0 }
    }

    /// The tight rectangle of set bits; `.zero` when empty.
    var bounds: PixelRect {
        var minY = -1
        var maxY = -1
        var minX = Int.max
        var maxX = Int.min
        for y in 0..<size.height {
            let base = y * wordsPerRow
            var rowIsClear = true
            for word in 0..<wordsPerRow where words[base + word] != 0 {
                rowIsClear = false
                break
            }
            guard !rowIsClear else { continue }
            if minY < 0 { minY = y }
            maxY = y
            for word in 0..<wordsPerRow {
                let bits = words[base + word]
                if bits != 0 {
                    minX = min(minX, word * 64 + bits.trailingZeroBitCount)
                    break
                }
            }
            for word in stride(from: wordsPerRow - 1, through: 0, by: -1) {
                let bits = words[base + word]
                if bits != 0 {
                    maxX = max(maxX, word * 64 + 63 - bits.leadingZeroBitCount)
                    break
                }
            }
        }
        guard minY >= 0 else { return .zero }
        return PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The maximal runs of set bits in row `y`, ascending; `[]` outside the canvas.
    func runs(inRow y: Int) -> [Range<Int>] {
        guard y >= 0, y < size.height else { return [] }
        let base = y * wordsPerRow
        var result: [Range<Int>] = []
        var runStart: Int?
        var x = 0
        while x < size.width {
            let word = words[base + (x >> 6)]
            if (word >> UInt64(x & 63)) & 1 == 1 {
                if runStart == nil { runStart = x }
                x += 1
            } else {
                if let start = runStart {
                    result.append(start..<x)
                    runStart = nil
                }
                // Skip the rest of a word holding no further set bits (padding bits at
                // or past `width` are always 0, so this terminates).
                x = (word >> UInt64(x & 63)) == 0 ? (x & ~63) + 64 : x + 1
            }
        }
        if let start = runStart { result.append(start..<x) }
        return result
    }

    // MARK: Set algebra (word-wise; a size mismatch is a defined no-op returning `self`)

    func intersection(_ other: FloodFillStencil) -> FloodFillStencil {
        combining(other) { $0 & $1 }
    }

    func union(_ other: FloodFillStencil) -> FloodFillStencil {
        combining(other) { $0 | $1 }
    }

    func subtracting(_ other: FloodFillStencil) -> FloodFillStencil {
        combining(other) { $0 & ~$1 }
    }

    private func combining(_ other: FloodFillStencil,
                           _ operation: (UInt64, UInt64) -> UInt64) -> FloodFillStencil {
        guard other.size == size, other.wordsPerRow == wordsPerRow else { return self }
        var result = self
        for index in result.words.indices {
            result.words[index] = operation(result.words[index], other.words[index])
        }
        return result
    }

    /// Bit set iff coverage > 0 (0017 builds its "limit to selection" stencil this way).
    static func from(_ mask: SelectionMask) -> FloodFillStencil {
        var stencil = Self(size: mask.size)
        let columns = FloodFillSource.gridExtent(mask.size.width)
        let rows = FloodFillSource.gridExtent(mask.size.height)
        for row in 0..<rows {
            for column in 0..<columns {
                guard case .partial(let storage) = mask.tile(
                    at: TileCoordinate(column: column, row: row)) else { continue }
                let x0 = column * Tile.size
                let y0 = row * Tile.size
                let width = min(Tile.size, mask.size.width - x0)
                let height = min(Tile.size, mask.size.height - y0)
                for y in 0..<height {
                    let base = (y0 + y) * stencil.wordsPerRow
                    let rowOffset = y * Tile.size
                    for x in 0..<width where storage.bytes[rowOffset + x] > 0 {
                        stencil.words[base + ((x0 + x) >> 6)] |= UInt64(1) << UInt64((x0 + x) & 63)
                    }
                }
            }
        }
        return stencil
    }

    /// `count` set bits starting at `firstBit` of a 64-bit word.
    static func bitMask(firstBit: Int, count: Int) -> UInt64 {
        guard count > 0 else { return 0 }
        let lowered: UInt64 = count >= 64 ? ~0 : (UInt64(1) << UInt64(count)) &- 1
        return lowered << UInt64(firstBit)
    }

    /// Set bits of row `y` over columns `from ..< from + count`, word-wise.
    private func rowSetBitCount(y: Int, from x0: Int, count: Int) -> Int {
        var total = 0
        var x = x0
        let end = x0 + count
        while x < end {
            let word = words[y * wordsPerRow + (x >> 6)]
            let firstBit = x & 63
            let bitCount = min(64 - firstBit, end - x)
            total += (word & Self.bitMask(firstBit: firstBit, count: bitCount)).nonzeroBitCount
            x += bitCount
        }
        return total
    }

    // MARK: Selection conversion (spec 0013 interop)

    /// Coverage 255 where set, 0 elsewhere, built tile by tile with 0013's
    /// `SelectionMask(size:tiles:)`: all in-canvas bits set → `.full`, none → `.empty`,
    /// else `.partial` with 255/0 bytes and 0 outside the canvas. No per-pixel closure.
    func selectionMask() -> SelectionMask {
        let columns = FloodFillSource.gridExtent(size.width)
        let rows = FloodFillSource.gridExtent(size.height)
        var tiles: [SelectionMaskTile] = []
        tiles.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let x0 = column * Tile.size
                let y0 = row * Tile.size
                let width = min(Tile.size, size.width - x0)
                let height = min(Tile.size, size.height - y0)
                var setTotal = 0
                for y in y0..<(y0 + height) {
                    setTotal += rowSetBitCount(y: y, from: x0, count: width)
                }
                switch setTotal {
                case 0:
                    tiles.append(.empty)
                case width * height:
                    tiles.append(.full)
                default:
                    var bytes = [UInt8](repeating: 0, count: SelectionMaskTileStorage.byteCount)
                    bytes.withUnsafeMutableBytes { buffer in
                        guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                            return
                        }
                        for y in y0..<(y0 + height) {
                            let wordBase = y * wordsPerRow
                            let lineBase = (y - y0) * Tile.size
                            for x in x0..<(x0 + width) {
                                let bit = (words[wordBase + (x >> 6)] >> UInt64(x & 63)) & 1
                                base[lineBase + (x - x0)] = bit == 1 ? 255 : 0
                            }
                        }
                    }
                    tiles.append(.partial(SelectionMaskTileStorage(bytes: bytes)))
                }
            }
        }
        return SelectionMask(size: size, tiles: tiles)
    }

    // MARK: Outline

    /// The pixel-edge boundary as closed loops in canvas coordinates (y down) — the way
    /// Paint.NET builds its wand outline from the stencil (`PdnGraphicsPath` from a
    /// stencil): pixel-aligned, hard-edged, exactly one vertex per corner.
    ///
    /// Construction (spec 0016): per row the runs `R(y)`; on grid line `y` the top edges
    /// `R(y) ∖ R(y−1)` run **+x** and the bottom edges `R(y−1) ∖ R(y)` run **−x**; each
    /// run's left side runs **−y** and its right side **+y**, joined across rows. Each
    /// boundary edge then occurs exactly once, so the orientation is clockwise on screen
    /// around every region and counter-clockwise around every hole — non-zero winding and
    /// even-odd fill identically. Loops are linked through a dictionary from start vertex
    /// to unused outgoing edges; at a vertex with two outgoing edges (pixels touching
    /// only diagonally) the edge turning **right** relative to the incoming direction
    /// wins, keeping diagonally-touching pixels as separate loops (either choice fills
    /// identically; the rule makes output deterministic). Loop starts visit unused edges
    /// by ascending vertex, so a square's first loop starts at its top-left corner and
    /// runs clockwise. Collinear intermediate vertices are omitted. An empty stencil
    /// yields an empty path. Coordinates are integers stored as `CGFloat`.
    func outline() -> CGPath {
        let path = CGMutablePath()
        let box = bounds
        guard box.width > 0, box.height > 0 else { return CGMutablePath() }
        let top = box.minY
        let bottom = box.maxY // exclusive row index
        let runsByRow: [[Range<Int>]] = (top..<bottom).map { runs(inRow: $0) }
        let empty: [Range<Int>] = []

        // Vertices are pixel-grid corners; 64-bit keys keep the linking dictionaries
        // small. A vertex has at most two outgoing edges (exactly two when two filled
        // pixels touch only diagonally at that corner).
        struct Edge {
            let toKey: UInt64
            let direction: FloodOutlineDirection
        }
        func vertexKey(x: Int, y: Int) -> UInt64 {
            (UInt64(y) << 32) | UInt64(x)
        }
        func vertexPoint(_ key: UInt64) -> CGPoint {
            CGPoint(x: CGFloat(Int(key & 0xFFFF_FFFF)), y: CGFloat(Int(key >> 32)))
        }
        var outgoing: [UInt64: (first: Edge?, second: Edge?)] = [:]
        func addEdge(from key: UInt64, _ edge: Edge) {
            if var slot = outgoing[key] {
                if slot.first == nil {
                    slot.first = edge
                } else {
                    slot.second = edge
                }
                outgoing[key] = slot
            } else {
                outgoing[key] = (edge, nil)
            }
        }

        func horizontalEdges(line y: Int, above: [Range<Int>], below: [Range<Int>]) {
            for segment in Self.subtractRuns(below, above) {
                addEdge(from: vertexKey(x: segment.lowerBound, y: y),
                        Edge(toKey: vertexKey(x: segment.upperBound, y: y), direction: .east))
            }
            for segment in Self.subtractRuns(above, below) {
                addEdge(from: vertexKey(x: segment.upperBound, y: y),
                        Edge(toKey: vertexKey(x: segment.lowerBound, y: y), direction: .west))
            }
        }
        for offset in runsByRow.indices {
            horizontalEdges(line: top + offset,
                            above: offset == 0 ? empty : runsByRow[offset - 1],
                            below: runsByRow[offset])
        }
        horizontalEdges(line: bottom, above: runsByRow[runsByRow.count - 1], below: empty)

        // Vertical edges, joined across consecutive rows: a left edge opens on the first
        // row whose run starts at `x` (covering that row) and closes on the first row
        // that does not; a right edge likewise on run ends.
        var openLeft: [Int: Int] = [:]   // x → top grid line of the open edge
        var openRight: [Int: Int] = [:]  // x → top grid line of the open edge
        for offset in runsByRow.indices {
            let y = top + offset
            var starts: Set<Int> = []
            var ends: Set<Int> = []
            for run in runsByRow[offset] {
                starts.insert(run.lowerBound)
                ends.insert(run.upperBound)
            }
            for x in starts where openLeft[x] == nil { openLeft[x] = y }
            for x in openLeft.keys where !starts.contains(x) {
                if let openTop = openLeft[x] {
                    addEdge(from: vertexKey(x: x, y: y),
                            Edge(toKey: vertexKey(x: x, y: openTop), direction: .north))
                    openLeft[x] = nil
                }
            }
            for x in ends where openRight[x] == nil { openRight[x] = y }
            for x in openRight.keys where !ends.contains(x) {
                if let openTop = openRight[x] {
                    addEdge(from: vertexKey(x: x, y: openTop),
                            Edge(toKey: vertexKey(x: x, y: y), direction: .south))
                    openRight[x] = nil
                }
            }
        }
        // Edges still open after the last row run to the `bottom` grid line.
        for (x, openTop) in openLeft {
            addEdge(from: vertexKey(x: x, y: bottom),
                    Edge(toKey: vertexKey(x: x, y: openTop), direction: .north))
        }
        for (x, openTop) in openRight {
            addEdge(from: vertexKey(x: x, y: openTop),
                    Edge(toKey: vertexKey(x: x, y: bottom), direction: .south))
        }

        // Link the edges into closed loops. `used` is a bitmask because a vertex has at
        // most two outgoing edges; from the two candidates at a diagonally-touching
        // vertex the edge turning right relative to the incoming direction wins, and the
        // loop ends when it returns to its start vertex with no such edge left — every
        // edge is consumed by the loop it starts in, so outer loops fill clockwise and
        // holes counter-clockwise.
        var used: [UInt64: UInt8] = [:]
        used.reserveCapacity(outgoing.count)
        func isUsed(_ key: UInt64, _ slot: Int) -> Bool {
            (used[key] ?? 0) & UInt8(1 << slot) != 0
        }
        func slotOf(_ key: UInt64, _ slot: Int) -> Edge? {
            guard let slots = outgoing[key] else { return nil }
            return slot == 0 ? slots.first : slots.second
        }
        for startKey in outgoing.keys.sorted() {
            for startSlot in 0..<2 {
                guard let startEdge = slotOf(startKey, startSlot),
                      !isUsed(startKey, startSlot) else { continue }
                var points: [CGPoint] = [vertexPoint(startKey)]
                var vertex = startKey
                var slotIndex = startSlot
                var current = startEdge
                var incoming: FloodOutlineDirection?
                while true {
                    used[vertex, default: 0] |= UInt8(1 << slotIndex)
                    if let incoming, current.direction != incoming {
                        points.append(vertexPoint(vertex))
                    }
                    vertex = current.toKey
                    incoming = current.direction
                    let candidates = outgoing[vertex] ?? (first: nil, second: nil)
                    let desired = current.direction.right
                    var next: (index: Int, edge: Edge)?
                    if let first = candidates.first, first.direction == desired,
                       !isUsed(vertex, 0) {
                        next = (0, first)
                    } else if let second = candidates.second, second.direction == desired,
                              !isUsed(vertex, 1) {
                        next = (1, second)
                    } else if vertex != startKey {
                        // Defensive fallback: no diagonal touch here, so a vertex offers
                        // at most one unused edge; take it. (A dead end cannot occur for
                        // a closed boundary — every vertex has equal in- and out-degree.)
                        if let first = candidates.first, !isUsed(vertex, 0) {
                            next = (0, first)
                        } else if let second = candidates.second, !isUsed(vertex, 1) {
                            next = (1, second)
                        }
                    }
                    guard let next else { break }
                    slotIndex = next.index
                    current = next.edge
                }
                guard points.count >= 3 else { continue }
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
            }
        }
        return path
    }

    /// Maximal segments of `a ∖ b` for ascending disjoint run lists.
    static func subtractRuns(_ a: [Range<Int>], _ b: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var bIndex = 0
        for run in a {
            var cursor = run.lowerBound
            while bIndex < b.count, b[bIndex].upperBound <= cursor { bIndex += 1 }
            var probe = bIndex
            while probe < b.count, b[probe].lowerBound < run.upperBound {
                let blocker = b[probe]
                if blocker.lowerBound > cursor { result.append(cursor..<blocker.lowerBound) }
                cursor = max(cursor, blocker.upperBound)
                probe += 1
            }
            if cursor < run.upperBound { result.append(cursor..<run.upperBound) }
        }
        return result
    }
}

/// One directed pixel-edge direction on screen (canvas coordinates, y down).
enum FloodOutlineDirection: UInt8 {
    case east, south, west, north

    /// Turning right while facing this direction (screen coordinates, y down).
    var right: FloodOutlineDirection {
        switch self {
        case .east: .south
        case .south: .west
        case .west: .north
        case .north: .east
        }
    }
}

// MARK: - The fills (spec 0016)

/// Concurrent tasks of the global-mode fill set the same flag from different bands;
/// the writes are idempotent and `concurrentPerform` establishes the ordering edge
/// before the flag is read — the same pattern `SelectionMaskTileBox` uses (spec 0013).
private final class FloodCancelBox: @unchecked Sendable {
    var flagged = false
}

/// The raw pointers the global-mode bands share (the stencil's words, the tile bases,
/// the limit's words). `@unchecked Sendable` is justified like `SelectionMaskTileBox`:
/// the storage is owned by the synchronous `fill` call for its whole duration, the
/// buffers are never reallocated or copied while the bands run, and each band writes
/// only the words of its own disjoint row range.
private struct FloodBandStorage: @unchecked Sendable {
    let words: UnsafeMutableBufferPointer<UInt64>
    let bases: [UnsafeRawPointer?]
    let gridColumns: Int
    let limitWords: UnsafePointer<UInt64>?
}

/// The flood-fill algorithms — a port of Paint.NET 3.36's `FloodToolBase`
/// `FillStencilFromPoint` (contiguous) and `FillStencilByColor` (global), unchanged in
/// Paint.NET 4.3 (4-connectivity). The functions are pure and `nonisolated` so 0048 can
/// move them off the main actor without changing the API (PRD T-4 / D-43: today the fill
/// runs synchronously on click).
enum FloodFill {
    /// Fills from `seed` in `source`. Returns `nil` when `seed` is outside
    /// `source.size`, when `limit` is non-nil and does not contain `seed` or disagrees
    /// in size, when `isCancelled()` returned `true` (checked once per dequeued span in
    /// contiguous mode and once per row band in global mode), or when the stencil
    /// allocation would overflow. Otherwise the result always contains `seed` (a pixel
    /// always matches itself: distance 0).
    ///
    /// `limit` (0017's "fill within the selection" hook) acts as a barrier in contiguous
    /// mode and an intersection in global mode; pixels outside it are never set.
    static func fill(_ source: FloodFillSource, from seed: PixelPoint, tolerance: FloodTolerance,
                     mode: FloodMode, limit: FloodFillStencil? = nil,
                     isCancelled: @escaping @Sendable () -> Bool = { false }) -> FloodFillStencil? {
        guard seed.x >= 0, seed.y >= 0,
              seed.x < source.size.width, seed.y < source.size.height else { return nil }
        if let limit {
            guard limit.size == source.size, limit.contains(seed) else { return nil }
        }
        guard !isCancelled() else { return nil }
        // APP-10 overflow rule: decide the allocation (and the tile-grid size) before
        // touching either; mocked oversized sources return `nil` here without
        // allocating or trapping.
        guard source.size.width > 0, source.size.height > 0,
              FloodFillStencil.storageWordCount(width: source.size.width,
                                                height: source.size.height) != nil
        else { return nil }
        let gridProduct = source.gridColumns.multipliedReportingOverflow(by: source.gridRows)
        guard !gridProduct.overflow, source.tiles.count >= gridProduct.partialValue
        else { return nil }

        var stencil = FloodFillStencil(size: source.size)
        let seedColor = source.pixel(at: seed)

        // Pixel reads go through tile row pointers (spec 0016: "read pixels through tile
        // row pointers, switching tile every 256 columns"). The base addresses stay
        // valid for the whole call: `source` holds the only mutation path to those byte
        // buffers, `Tile` is a copy-on-write value, and nothing writes during a
        // synchronous fill — a writer elsewhere would detach to a *new* buffer, so the
        // bytes read here stay alive and stable throughout.
        let gridColumns = source.gridColumns
        let bases: [UnsafeRawPointer?] = source.tiles.map { tile in
            tile?.bytes.withUnsafeBytes { $0.baseAddress }
        }
        let size = source.size
        let wordsPerRow = stencil.wordsPerRow
        let seedR = Int(seedColor.red)
        let seedG = Int(seedColor.green)
        let seedB = Int(seedColor.blue)
        let seedA = Int(seedColor.alpha)
        let maxDistance = tolerance.maxDistance
        let clearMatches = colorMatches(red: 0, green: 0, blue: 0, alpha: 0,
                                        seedR: seedR, seedG: seedG, seedB: seedB, seedA: seedA,
                                        maxDistance: maxDistance)

        var cancelled = false
        // The limit's words as a bare pointer for the duration of this synchronous
        // call; `limit` is a `let` parameter and the array is never mutated while the
        // fill runs (same reasoning as the tile bases above).
        let limitWords: UnsafePointer<UInt64>? = limit.flatMap { limitStencil in
            limitStencil.words.withUnsafeBufferPointer { $0.baseAddress }
        }
        stencil.words.withUnsafeMutableBufferPointer { words in
            switch mode {
            case .contiguous:
                cancelled = contiguousFill(
                    words: words, wordsPerRow: wordsPerRow, size: size,
                    bases: bases, gridColumns: gridColumns,
                    limitWords: limitWords,
                    seedR: seedR, seedG: seedG, seedB: seedB, seedA: seedA,
                    maxDistance: maxDistance, seed: seed, isCancelled: isCancelled)
            case .global:
                cancelled = globalFill(
                    storage: FloodBandStorage(words: words, bases: bases,
                                              gridColumns: gridColumns,
                                              limitWords: limitWords),
                    wordsPerRow: wordsPerRow, size: size,
                    seedR: seedR, seedG: seedG, seedB: seedB, seedA: seedA,
                    maxDistance: maxDistance, clearMatches: clearMatches,
                    isCancelled: isCancelled)
            }
        }
        return cancelled ? nil : stencil
    }

    /// The inlined `CheckColor` (identical arithmetic to
    /// `FloodColorMetric.distance(seed:candidate:)`).
    @inline(__always)
    private static func colorMatches(red bR: Int, green bG: Int, blue bB: Int, alpha bA: Int,
                                     seedR: Int, seedG: Int, seedB: Int, seedA: Int,
                                     maxDistance: Int) -> Bool {
        var diff = seedR - bR
        var sum = (1 + diff * diff) * seedA / 256
        diff = seedG - bG
        sum += (1 + diff * diff) * seedA / 256
        diff = seedB - bB
        sum += (1 + diff * diff) * seedA / 256
        diff = seedA - bA
        sum += diff * diff
        return sum <= maxDistance
    }

    @inline(__always)
    private static func colorMatches(color c: ColorRGBA8,
                                     seedR: Int, seedG: Int, seedB: Int, seedA: Int,
                                     maxDistance: Int) -> Bool {
        colorMatches(red: Int(c.red), green: Int(c.green), blue: Int(c.blue), alpha: Int(c.alpha),
                     seedR: seedR, seedG: seedG, seedB: seedB, seedA: seedA,
                     maxDistance: maxDistance)
    }

    @inline(__always)
    private static func tileBase(_ bases: [UnsafeRawPointer?], gridColumns: Int,
                                 x: Int, y: Int) -> UnsafeRawPointer? {
        bases[(y >> 8) * gridColumns + (x >> 8)]
    }

    @inline(__always)
    private static func color(at base: UnsafeRawPointer, x: Int, y: Int) -> ColorRGBA8 {
        base.loadUnaligned(fromByteOffset: (((y & 255) << 8) | (x & 255)) << 2,
                           as: ColorRGBA8.self)
    }

    /// Port of `FillStencilFromPoint`: an explicit FIFO of span seeds (array + head
    /// index, no recursion); per span the row extends left/right and the rows above and
    /// below are rescanned **only over the span's columns**, enqueueing the first column
    /// of every maximal matching run. Diagonal neighbours are never examined —
    /// 4-connectivity, unchanged in Paint.NET 4.3.
    ///
    /// - Returns: `true` when cancelled (the partial stencil must be discarded).
    private static func contiguousFill(
        words: UnsafeMutableBufferPointer<UInt64>, wordsPerRow: Int, size: PixelSize,
        bases: [UnsafeRawPointer?], gridColumns: Int,
        limitWords: UnsafePointer<UInt64>?,
        seedR: Int, seedG: Int, seedB: Int, seedA: Int, maxDistance: Int,
        seed: PixelPoint, isCancelled: @Sendable () -> Bool
    ) -> Bool {
        let width = size.width
        let height = size.height
        var queue: [PixelPoint] = [seed]
        var head = 0

        @inline(__always) func isSet(_ x: Int, _ y: Int) -> Bool {
            (words[y * wordsPerRow + (x >> 6)] >> UInt64(x & 63)) & 1 == 1
        }
        @inline(__always) func inLimit(_ x: Int, _ y: Int) -> Bool {
            guard let limitWords else { return true }
            return (limitWords[y * wordsPerRow + (x >> 6)] >> UInt64(x & 63)) & 1 == 1
        }
        @inline(__always) func matches(_ x: Int, _ y: Int) -> Bool {
            guard let base = tileBase(bases, gridColumns: gridColumns, x: x, y: y) else {
                // An unallocated tile is `(0, 0, 0, 0)` — one comparison decides it.
                return colorMatches(red: 0, green: 0, blue: 0, alpha: 0,
                                    seedR: seedR, seedG: seedG, seedB: seedB, seedA: seedA,
                                    maxDistance: maxDistance)
            }
            return colorMatches(color: color(at: base, x: x, y: y),
                                seedR: seedR, seedG: seedG, seedB: seedB, seedA: seedA,
                                maxDistance: maxDistance)
        }
        @inline(__always) func predicate(_ x: Int, _ y: Int) -> Bool {
            !isSet(x, y) && inLimit(x, y) && matches(x, y)
        }

        while head < queue.count {
            if isCancelled() { return true } // once per dequeued span (spec 0016)
            let point = queue[head]
            head += 1
            let y = point.y
            if isSet(point.x, y) || !inLimit(point.x, y) || !matches(point.x, y) { continue }

            // Extend left from x−1 and right from x.
            var left = point.x
            while left - 1 >= 0, predicate(left - 1, y) { left -= 1 }
            var right = point.x // exclusive
            while right < width, predicate(right, y) { right += 1 }

            // Mark the span.
            var x = left
            while x < right {
                let firstBit = x & 63
                let count = min(64 - firstBit, right - x)
                words[y * wordsPerRow + (x >> 6)] |=
                    FloodFillStencil.bitMask(firstBit: firstBit, count: count)
                x += count
            }

            // Rescan the rows above and below over the span's columns only; enqueue the
            // first column of every maximal not-set, in-limit, matching run.
            for neighborY in [y - 1, y + 1] where (0..<height).contains(neighborY) {
                var scan = left
                while scan < right {
                    while scan < right, !predicate(scan, neighborY) { scan += 1 }
                    if scan >= right { break }
                    queue.append(PixelPoint(x: scan, y: neighborY))
                    scan += 1
                    while scan < right, predicate(scan, neighborY) { scan += 1 }
                }
            }
        }
        return false
    }

    /// Port of `FillStencilByColor`: every pixel inside `limit` (or every pixel) that
    /// matches the seed color. Rows are split into bands processed with
    /// `concurrentPerform`; each band writes only its own rows' words, so the result is
    /// bit-identical to a sequential run (a `nil` tile is decided by one comparison for
    /// its whole block row).
    ///
    /// - Returns: `true` when cancelled (the partial stencil must be discarded).
    private static func globalFill(
        storage: FloodBandStorage, wordsPerRow: Int, size: PixelSize,
        seedR: Int, seedG: Int, seedB: Int, seedA: Int, maxDistance: Int,
        clearMatches: Bool, isCancelled: @escaping @Sendable () -> Bool
    ) -> Bool {
        let width = size.width
        let height = size.height
        let bandCount = max(1, min(height, ProcessInfo.processInfo.activeProcessorCount * 4))
        let bandHeight = (height + bandCount - 1) / bandCount
        let cancelBox = FloodCancelBox()

        DispatchQueue.concurrentPerform(iterations: bandCount) { band in
            // Re-read from the Sendable box so the closure captures only that.
            let words = storage.words
            let bases = storage.bases
            let gridColumns = storage.gridColumns
            let limitWords = storage.limitWords
            if isCancelled() { // once per row band (spec 0016)
                cancelBox.flagged = true
                return
            }
            let lower = band * bandHeight
            let upper = min(height, lower + bandHeight)
            // With ceil band heights the last bands can start past the image (and
            // empty `Range`s trap): they cover nothing and simply return.
            guard lower < upper else { return }
            for y in lower..<upper {
                let rowBase = y * wordsPerRow
                let tileRow = y >> 8
                var x = 0
                while x < width {
                    let tileColumn = x >> 8
                    let chunkEnd = min(width, (tileColumn + 1) << 8)
                    let base = bases[tileRow * gridColumns + tileColumn]
                    if let base {
                        var pixel = x
                        while pixel < chunkEnd {
                            let wordIndex = rowBase + (pixel >> 6)
                            let firstBit = pixel & 63
                            let bitCount = min(64 - firstBit, chunkEnd - pixel)
                            var word: UInt64 = 0
                            for bit in 0..<bitCount {
                                if colorMatches(color: color(at: base, x: pixel + bit, y: y),
                                                seedR: seedR, seedG: seedG, seedB: seedB,
                                                seedA: seedA, maxDistance: maxDistance) {
                                    word |= UInt64(1) << UInt64(firstBit + bit)
                                }
                            }
                            if let limitWords { word &= limitWords[wordIndex] }
                            words[wordIndex] |= word
                            pixel += bitCount
                        }
                    } else if clearMatches {
                        // A nil tile matches everywhere: one decision for the block row
                        // (intersected with the limit when given).
                        var pixel = x
                        while pixel < chunkEnd {
                            let wordIndex = rowBase + (pixel >> 6)
                            let firstBit = pixel & 63
                            let bitCount = min(64 - firstBit, chunkEnd - pixel)
                            var value = FloodFillStencil.bitMask(firstBit: firstBit,
                                                                 count: bitCount)
                            if let limitWords { value &= limitWords[wordIndex] }
                            words[wordIndex] |= value
                            pixel += bitCount
                        }
                    }
                    x = chunkEnd
                }
            }
        }
        return cancelBox.flagged
    }
}
