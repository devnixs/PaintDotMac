import Foundation

/// Edit > Fill Selection (spec 0018; PRD E-4, §5.12, D-45, H-6; Paint.NET EditMenu.html):
/// the selection fills with the Primary color — an overwrite, not a blend (D-45(b)), so
/// a semi-transparent primary over an opaque pixel gives that semi-transparent color —
/// and the selection stays ("The current selection remains active following the Fill
/// operation"). With no selection the whole active layer fills (D-45(a)). One
/// `TileDiffHistoryItem` "Fill Selection"; a fill of an area that already holds exactly
/// that color records nothing (H-6).
enum FillSelection {
    /// Menu title and history step (Paint.NET spelling).
    static let name = "Fill Selection"
    static let icon: HistoryIcon = .fillSelection

    /// Overwrite `p` with `color`, weighted by the coverage `m` (the selection mask
    /// value): a premultiplied linear interpolation from `p` to `color` with weight
    /// `m/255` — the same rule as erase, which is the overwrite with `(0,0,0,0)`.
    /// `m == 255` gives exactly `color` (`(0,0,0,0)` when its alpha is 0); `color.a == 0`
    /// reduces to `EraseSelection.erasePixel(p, coverage: m)` for every `p` and `m`.
    /// Exact integer arithmetic; the largest intermediate is 255 × 65,025 + 255 × 65,025
    /// + 32,512 ≈ 33 M (`UInt32`).
    static func fillPixel(_ p: ColorRGBA8, color: ColorRGBA8, coverage m: UInt8) -> ColorRGBA8 {
        if m == 0 { return p }
        if m == 255 { return color.alpha == 0 ? .clear : color }
        let wD = UInt32(p.alpha) * (255 - UInt32(m))     // destination weight, 0…65,025
        let wC = UInt32(color.alpha) * UInt32(m)         // color weight, 0…65,025
        let sum = wD + wC
        let outAlpha = (sum + 127) / 255                 // round-half-up of sum / 255
        if outAlpha == 0 { return .clear }
        let half = sum / 2
        func channel(_ destination: UInt8, _ source: UInt8) -> UInt8 {
            // `sum > 0` whenever `outAlpha > 0`; round-half-up of the premultiplied mix.
            UInt8((UInt32(destination) * wD + UInt32(source) * wC + half) / sum)
        }
        return ColorRGBA8(red: channel(p.red, color.red),
                          green: channel(p.green, color.green),
                          blue: channel(p.blue, color.blue),
                          alpha: UInt8(outAlpha))
    }

    /// The filled surface and the tiles it replaced (the `TileDiff` candidates).
    /// `mask == nil` behaves as every tile `.full`.
    ///
    /// Per tile: a `.empty` mask tile is skipped. A `.full` tile with `color.a == 0`
    /// behaves like erase (`nil`); otherwise every full tile with the same in-canvas
    /// size shares **one** `Tile(filledWith: color)` whose out-of-canvas pixels are zero
    /// (the 0002 edge-tile invariant), created once per call — Select All / no selection
    /// is O(tile count) with a single 256 KB buffer behind the interior. A `.partial`
    /// tile applies `fillPixel` where the coverage is non-zero (out-of-canvas mask bytes
    /// are always 0, so the edge padding stays zero), starting from the surface tile or
    /// a fresh zero tile; a fully transparent result is stored as `nil`. Partial tiles
    /// are computed concurrently and written serially, like `EraseSelection.erase`.
    /// Full tiles that already equal the target are still written; `TileDiff.between`
    /// drops them as unchanged.
    static func fill(_ surface: TiledSurface, color: ColorRGBA8, mask: SelectionMask?)
        -> (surface: TiledSurface, touched: Set<TileCoordinate>)
    {
        var result = surface
        var touched: Set<TileCoordinate> = []
        var jobs: [PartialFillJob] = []
        /// One shared filled tile per distinct in-canvas tile size (interior, the two
        /// edge strips, and the corner — at most four keys).
        var sharedTiles: [PixelSize: Tile] = [:]
        for row in 0..<surface.tileRows {
            for column in 0..<surface.tileColumns {
                let coordinate = TileCoordinate(column: column, row: row)
                switch mask?.tile(at: coordinate) ?? .full {
                case .empty:
                    continue
                case .full:
                    if color.alpha == 0 {
                        if surface.tile(at: coordinate) != nil {
                            result.setTile(nil, at: coordinate)
                            touched.insert(coordinate)
                        }
                    } else {
                        let area = surface.pixelRect(of: coordinate).size
                        let shared: Tile
                        if let cached = sharedTiles[area] {
                            shared = cached
                        } else {
                            var tile = Tile(filledWith: color)
                            tile.zeroPadding(outside: area)
                            sharedTiles[area] = tile
                            shared = tile
                        }
                        // Assigning the same `Tile` value shares its buffer until a tile
                        // is written (0002's `fill` does the same for interiors).
                        result.setTile(shared, at: coordinate)
                        touched.insert(coordinate)
                    }
                case .partial(let storage):
                    jobs.append(PartialFillJob(coordinate: coordinate,
                                               base: surface.tile(at: coordinate),
                                               storage: storage, color: color))
                }
            }
        }
        guard !jobs.isEmpty else { return (result, touched) }
        let partialJobs = jobs   // the copy-on-write reference the concurrent tasks read
        let boxes = partialJobs.map { _ in FilledTileBox() }
        DispatchQueue.concurrentPerform(iterations: partialJobs.count) { index in
            boxes[index].tile = filledPartialTile(partialJobs[index])
        }
        for (index, job) in partialJobs.enumerated() {
            if let tile = boxes[index].tile {
                result.setTile(tile, at: job.coordinate)
                touched.insert(job.coordinate)
            } else if surface.tile(at: job.coordinate) != nil {
                // Fully transparent result; `nil` replaces an allocated tile only.
                result.setTile(nil, at: job.coordinate)
                touched.insert(job.coordinate)
            }
        }
        return (result, touched)
    }

    /// Always true for an open document: with no selection the whole active layer is
    /// editable (D-45(a)).
    static func isEnabled(in state: DocumentState) -> Bool { true }

    /// The single "Fill Selection" step on the active layer, or `nil` when the fill
    /// changes nothing (H-6 — an area that already has exactly that color). The
    /// selection is unchanged, so there is no `SelectionHistoryItem` (Paint.NET keeps
    /// the ants after a Fill).
    static func makeHistoryItem(for state: DocumentState, color: ColorRGBA8) -> (any HistoryItem)? {
        let layer = state.image.layers[state.image.activeLayerIndex]
        let (filled, touched) = fill(layer.surface, color: color, mask: state.selection?.mask)
        let diff = TileDiff.between(before: layer.surface, after: filled,
                                    layerID: layer.id, candidates: touched)
        let item = TileDiffHistoryItem(name: name, icon: icon, diff: diff)
        return item.isNoOp ? nil : item
    }

    // MARK: - Partial-tile machinery

    /// One queued `.partial` mask tile with its base surface tile (nil = unallocated)
    /// and the fill color.
    private struct PartialFillJob {
        let coordinate: TileCoordinate
        let base: Tile?
        let storage: SelectionMaskTileStorage
        let color: ColorRGBA8
    }

    /// One partial tile's computed result (`nil` = fully transparent). Each
    /// `concurrentPerform` task writes only its own box — the `SelectionMaskTileBox`
    /// pattern — so the unchecked conformance is safe.
    private final class FilledTileBox: @unchecked Sendable {
        var tile: Tile?
    }

    /// The filled copy of one partial tile: `fillPixel` on every pixel whose coverage
    /// byte is non-zero (in-canvas only — out-of-canvas mask bytes are always 0, so the
    /// edge padding stays zero). `nil` when the result is fully transparent (possible
    /// only with `color.a == 0`, or where `outAlpha` rounds to 0).
    private static func filledPartialTile(_ job: PartialFillJob) -> Tile? {
        var tile = job.base ?? Tile()
        tile.withUnsafeMutableBytes { pixels in
            job.storage.bytes.withUnsafeBytes { coverage in
                for index in 0..<coverage.count {
                    let m = coverage[index]
                    guard m != 0 else { continue }
                    let offset = index * 4
                    let out = fillPixel(ColorRGBA8(red: pixels[offset], green: pixels[offset + 1],
                                                   blue: pixels[offset + 2], alpha: pixels[offset + 3]),
                                        color: job.color, coverage: m)
                    pixels[offset] = out.red
                    pixels[offset + 1] = out.green
                    pixels[offset + 2] = out.blue
                    pixels[offset + 3] = out.alpha
                }
            }
        }
        return tile.isFullyTransparent ? nil : tile
    }
}

private extension Tile {
    /// Zero every pixel outside the in-canvas area `(0, 0, area.width, area.height)` so
    /// an edge tile honours the 0002 padding invariant (`setTile` asserts it in Debug).
    mutating func zeroPadding(outside area: PixelSize) {
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
