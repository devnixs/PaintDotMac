import Foundation

/// One rendered layer thumbnail (spec 0025 item 6): opaque, row-major, top-left origin.
/// The checkerboard is baked in — the layer's own pixels composited over it — so the view
/// draws the buffer without any further compositing.
struct ThumbnailImage: Equatable, Sendable {
    let size: PixelSize
    let pixels: [ColorRGBA8]   // opaque, row-major, top-left origin
}

/// A `ThumbnailThrottle.requestRender(now:)` decision (spec 0025 item 6).
enum ThrottleDecision: Equatable, Sendable {
    /// Start a render immediately (the leading edge).
    case renderNow
    /// One trailing render at this time; repeated requests inside the window coalesce
    /// into the same scheduled time.
    case scheduleAt(TimeInterval)
}

/// Renders one layer's **own pixels** for the Layers panel (spec 0025 item 6, PRD L-5):
/// visibility, opacity, and blend mode are ignored (Paint.NET thumbnails show the layer's
/// content as-is), sampled aspect-correct into an 80 px box (40 pt at 2×) over
/// `CheckerboardStyle.standard`. Pure value code with no AppKit — it runs off the main
/// actor inside a `Task.detached` (NF-1: painting latency must not suffer from
/// thumbnails) and checks `Task.isCancelled` once per output row.
///
/// Sampling (spec item 6): thumbnail pixel `(tx, ty)` covers the source rect
/// `[tx·w/W, (tx+1)·w/W) × [ty·h/H, (ty+1)·h/H)`. Down-scales take the box-filter
/// average of the **premultiplied** source pixels whose centers fall in that rect
/// (never fewer than one — with a bin ≥ 1 px wide the center rule guarantees it);
/// up-scales take the nearest source pixel (the one containing the rect's center).
/// Absent tiles count as transparent and are skipped without reading memory. The
/// averaged premultiplied color composites over the checkerboard:
/// `out = src_premul + checker × (255 − A) / 255`, rounded to nearest (half up),
/// alpha 255.
struct ThumbnailRenderer: Sendable {
    /// 40 pt at 2× — the row shows the thumbnail at 40×40 pt.
    static let boxPixels = 80
    /// Checkerboard square side in thumbnail-space pixels (the canvas's 8 pt checker is
    /// too fine at 40 pt; 4 thumbnail pixels ≈ the same visual weight).
    static let checkerSquarePixels = 4

    /// Aspect-correct fit of `imageSize` into a square box; each side ≥ 1. Small images
    /// scale **up** (a 1×1 image fills the box); a degenerate aspect keeps one pixel on
    /// the short side (a 1×65535 image gives 1×80).
    static func fittedSize(for imageSize: PixelSize, box: Int = boxPixels) -> PixelSize {
        let scale = min(Double(box) / Double(imageSize.width),
                        Double(box) / Double(imageSize.height))
        return PixelSize(
            width: max(1, Int((Double(imageSize.width) * scale).rounded())),
            height: max(1, Int((Double(imageSize.height) * scale).rounded())))
    }

    /// Renders `surface`'s pixels over the checkerboard. Throws `CancellationError` when
    /// the surrounding task is cancelled (checked once per output row).
    func render(_ surface: TiledSurface, box: Int = boxPixels) throws -> ThumbnailImage {
        let out = Self.fittedSize(for: surface.size, box: box)
        let w = surface.size.width, h = surface.size.height
        // `scale < 1`: at least one axis shrinks → box filter; otherwise nearest.
        let downscale = Double(out.width) < Double(w) || Double(out.height) < Double(h)
        // Source rows: bin `t` samples pixels with centers in `[t·h/H, (t+1)·h/H)`,
        // i.e. indices `[⌈t·h/H − 0.5⌉, ⌈(t+1)·h/H − 0.5⌉)`; nearest takes the pixel
        // containing the bin center.
        let rowStarts = Self.binStarts(source: h, thumb: out.height)
        let columnStarts = Self.binStarts(source: w, thumb: out.width)
        let nearestColumn = (0..<out.width).map { tx in
            min(w - 1, max(0, Int(floor((Double(tx) + 0.5) * Double(w) / Double(out.width)))))
        }
        let nearestRow = (0..<out.height).map { ty in
            min(h - 1, max(0, Int(floor((Double(ty) + 0.5) * Double(h) / Double(out.height)))))
        }
        let light = CheckerboardStyle.standard.lightColor
        let dark = CheckerboardStyle.standard.darkColor

        var pixels = [ColorRGBA8](repeating: .white, count: out.width * out.height)
        // Per-output-pixel premultiplied sums (Float — 12 M accumulate steps on a large
        // layer must not pay per-pixel Double↔Int conversions) and center counts.
        var sums = ThumbnailRowAccumulator(width: out.width)

        for ty in 0..<out.height {
            if Task.isCancelled { throw CancellationError() }
            sums.reset()
            if downscale {
                accumulateBox(surface: surface, sourceY0: rowStarts[ty],
                              sourceY1: rowStarts[ty + 1], columnStarts: columnStarts,
                              sums: &sums)
            } else {
                accumulateNearest(surface: surface, sy: nearestRow[ty],
                                  nearestColumn: nearestColumn, sums: &sums)
            }
            let rowParity = (ty / Self.checkerSquarePixels) & 1 == 0
            let rowBase = ty * out.width
            for tx in 0..<out.width {
                let checker = (rowParity == ((tx / Self.checkerSquarePixels) & 1 == 0))
                    ? light : dark
                pixels[rowBase + tx] = sums.composited(at: tx, over: checker)
            }
        }
        return ThumbnailImage(size: out, pixels: pixels)
    }

    // MARK: - Sampling geometry

    /// First source index whose pixel center `(i + 0.5)` is ≥ `t · source / thumb`:
    /// `⌈t·source/thumb − 0.5⌉`, clamped to `0...source`. Non-decreasing;
    /// `starts[0] == 0`, `starts[thumb] == source`.
    private static func binStarts(source: Int, thumb: Int) -> [Int] {
        (0...thumb).map { t in
            let exact = Double(t) * Double(source) / Double(thumb) - 0.5
            return min(source, max(0, Int(ceil(exact))))
        }
    }

    // MARK: - Accumulation

    /// The down-scale path: walk the source rows once, adding every pixel's premultiplied
    /// color into the thumbnail bin its center falls in. Absent tiles are counted
    /// (transparent) without touching their memory.
    private func accumulateBox(surface: TiledSurface, sourceY0: Int, sourceY1: Int,
                               columnStarts: [Int], sums: inout ThumbnailRowAccumulator) {
        guard sourceY1 > sourceY0 else { return }
        for sy in sourceY0..<sourceY1 {
            let tileRow = sy / TiledSurface.tileSize
            guard tileRow < surface.tileRows else { continue }
            let localY = sy % TiledSurface.tileSize
            for tx in 0..<sums.width {
                let x0 = columnStarts[tx], x1 = columnStarts[tx + 1]
                guard x1 > x0 else { continue }
                var sx = x0
                while sx < x1 {
                    let tileColumn = sx / TiledSurface.tileSize
                    let runEnd = min(x1, (tileColumn + 1) * TiledSurface.tileSize)
                    if tileColumn < surface.tileColumns,
                       let tile = surface.tile(at: TileCoordinate(column: tileColumn,
                                                                  row: tileRow)) {
                        let localStart = sx % TiledSurface.tileSize
                        tile.withUnsafeBytes { buffer in
                            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
                            var p = base + localY * Tile.bytesPerRow + localStart * 4
                            for _ in 0..<(runEnd - sx) {
                                sums.add(red: p[0], green: p[1], blue: p[2], alpha: p[3],
                                         at: tx)
                                p += 4
                            }
                        }
                    } else {
                        // Absent tile: transparent pixels, counted, nothing read.
                        sums.addTransparent(count: runEnd - sx, at: tx)
                    }
                    sx = runEnd
                }
            }
        }
    }

    /// The up-scale path: one nearest-neighbor sample per thumbnail pixel.
    private func accumulateNearest(surface: TiledSurface, sy: Int,
                                   nearestColumn: [Int], sums: inout ThumbnailRowAccumulator) {
        let tileRow = sy / TiledSurface.tileSize
        let localY = sy % TiledSurface.tileSize
        for tx in 0..<sums.width {
            guard tileRow < surface.tileRows,
                  let tile = surface.tile(at: TileCoordinate(
                    column: nearestColumn[tx] / TiledSurface.tileSize, row: tileRow))
            else { continue }   // absent tile: transparent, adds nothing
            let c = tile.pixel(x: nearestColumn[tx] % TiledSurface.tileSize, y: localY)
            sums.add(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha, at: tx)
        }
    }
}

/// One output row's premultiplied sums (Float) and counted centers, plus the
/// over-checkerboard compositing rule `out = src_premul + checker × (255 − A) / 255`
/// rounded half up (spec 0025 item 6).
struct ThumbnailRowAccumulator {
    let width: Int
    private var red: [Float]
    private var green: [Float]
    private var blue: [Float]
    private var alpha: [Float]
    private var counts: [Float]

    init(width: Int) {
        self.width = width
        red = [Float](repeating: 0, count: width)
        green = [Float](repeating: 0, count: width)
        blue = [Float](repeating: 0, count: width)
        alpha = [Float](repeating: 0, count: width)
        counts = [Float](repeating: 0, count: width)
    }

    mutating func reset() {
        for i in 0..<width {
            red[i] = 0; green[i] = 0; blue[i] = 0; alpha[i] = 0; counts[i] = 0
        }
    }

    /// Adds one source pixel's premultiplied color (`component × alpha / 255`, in Float).
    @inline(__always)
    mutating func add(red r: UInt8, green g: UInt8, blue b: UInt8, alpha a: UInt8, at i: Int) {
        let fa = Float(a)
        let scale = fa / 255
        red[i] += Float(r) * scale
        green[i] += Float(g) * scale
        blue[i] += Float(b) * scale
        alpha[i] += fa
        counts[i] += 1
    }

    /// Counts transparent source pixels (centers counted, nothing premultiplied).
    @inline(__always)
    mutating func addTransparent(count: Int, at i: Int) {
        counts[i] += Float(count)
    }

    /// The averaged premultiplied color composited over `checker`, opaque result.
    func composited(at i: Int, over checker: ColorRGBA8) -> ColorRGBA8 {
        let count = counts[i]
        let r: Float, g: Float, b: Float, a: Float
        if count == 0 {
            r = 0; g = 0; b = 0; a = 0   // no source pixels at all: pure checkerboard
        } else {
            r = red[i] / count; g = green[i] / count
            b = blue[i] / count; a = alpha[i] / count
        }
        let inverse = (255 - a) / 255
        return ColorRGBA8(red: Self.compose(r, checker.red, inverse),
                          green: Self.compose(g, checker.green, inverse),
                          blue: Self.compose(b, checker.blue, inverse),
                          alpha: 255)
    }

    private static func compose(_ premul: Float, _ checker: UInt8, _ inverseAlpha: Float) -> UInt8 {
        UInt8(min(255, max(0, (premul + Float(checker) * inverseAlpha + 0.5).rounded(.down))))
    }
}

/// Remembers the last thumbnail per layer and decides when it must be re-rendered
/// (spec 0025 item 6). An entry keeps a copy of the `TiledSurface` it was rendered from
/// (copy-on-write: no pixel copy) so staleness is proven, not guessed: `generation`
/// equality alone is not enough, because a snapshot undo (0008) can restore an older
/// surface whose `generation` collides with a newer, different one. Keeping the rendered
/// surface alive also pins its tile buffers, so an address can never be recycled by a
/// different tile and fool `sharesStorage`.
struct ThumbnailCache {
    private struct Entry {
        let image: ThumbnailImage
        let surface: TiledSurface
    }

    private var entries: [Layer.ID: Entry] = [:]

    /// The stored thumbnail, or nil when the layer has none yet.
    func thumbnail(for id: Layer.ID) -> ThumbnailImage? { entries[id]?.image }

    /// True when there is no entry, when generations differ, or when any tile
    /// coordinate's storage differs (presence or `sharesStorage`).
    func needsRender(layerID: Layer.ID, surface: TiledSurface) -> Bool {
        guard let cached = entries[layerID]?.surface,
              cached.generation == surface.generation,
              cached.tileCount == surface.tileCount
        else { return true }
        for row in 0..<surface.tileRows {
            for column in 0..<surface.tileColumns {
                let coordinate = TileCoordinate(column: column, row: row)
                switch (cached.tile(at: coordinate), surface.tile(at: coordinate)) {
                case (nil, nil): continue
                case (.some, .none), (.none, .some): return true
                case let (cached?, current?):
                    if !cached.sharesStorage(with: current) { return true }
                }
            }
        }
        return false
    }

    /// Stores the render together with the surface it came from.
    mutating func store(_ image: ThumbnailImage, for id: Layer.ID, surface: TiledSurface) {
        entries[id] = Entry(image: image, surface: surface)
    }

    /// Drops entries for layers that no longer exist.
    mutating func retain(only ids: Set<Layer.ID>) {
        entries = entries.filter { ids.contains($0.key) }
    }
}

/// Bounds thumbnail work while a stroke is being painted to at most 4 renders per second
/// per document (spec 0025 item 6, NF-1). Leading edge: a request at least
/// `minimumInterval` after the last render start renders now; requests inside the window
/// coalesce into one trailing render at `lastStart + minimumInterval`. The clock is
/// injected by the caller so tests control time.
struct ThumbnailThrottle {
    static let minimumInterval: TimeInterval = 0.25

    private var lastRenderStart: TimeInterval?

    /// `.renderNow` when ≥ `minimumInterval` has passed since the last render start
    /// (or none has happened), else `.scheduleAt(lastStart + minimumInterval)`.
    mutating func requestRender(now: TimeInterval) -> ThrottleDecision {
        guard let last = lastRenderStart else { return .renderNow }
        guard now - last >= Self.minimumInterval else { return .scheduleAt(last + Self.minimumInterval) }
        return .renderNow
    }

    /// Stamps the start of the render the caller is beginning.
    mutating func didStartRender(at time: TimeInterval) {
        lastRenderStart = time
    }
}
