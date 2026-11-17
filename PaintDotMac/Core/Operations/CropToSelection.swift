import Foundation

/// Image > Crop to Selection (spec 0022; PRD IMG-1, E-3/D-40, H-6/D-34, D-7, NF-4,
/// Paint.NET `CropToSelectionFunction` + ImageMenu.html). The image (every layer, hidden
/// ones included) shrinks to the selection's tight mask bounds; pixels outside the
/// selection lose their color, antialiased edge pixels keep their color with alpha
/// scaled by the coverage, and the selection follows (translated, never dropped). One
/// `DocumentSnapshotHistoryItem` — 0008's snapshot item reserved for canvas-size changes;
/// undo restores size, pixels, layer list, and selection exactly.
enum CropToSelection {
    /// Menu title and history step name (Paint.NET spelling).
    static let name = "Crop to Selection"
    static let icon: HistoryIcon = .cropToSelection

    /// Enabled iff the document has a selection (Paint.NET: "only available if a
    /// selection is active"; E-3/D-40: an empty selection is no selection).
    static func isEnabled(in state: DocumentState) -> Bool { state.selection != nil }

    /// The crop rectangle: the selection's tight mask bounds (every pixel with
    /// coverage > 0), in canvas pixels; `nil` when no selection. Never empty and always
    /// inside the canvas, so no `ImageLimits` check is needed (spec 0022).
    static func cropRect(for state: DocumentState) -> PixelRect? { state.selection?.bounds }

    /// The cropped state, or `nil` when disabled or when the crop would change nothing
    /// (H-6/D-34: `R == canvas` and a full mask — Select All then crop does nothing).
    static func croppedState(_ state: DocumentState) -> DocumentState? {
        guard let selection = state.selection else { return nil }
        let rect = selection.bounds
        guard rect != state.image.size.bounds || !selection.mask.isFull else { return nil }
        let mask = selection.mask
        var layers: [Layer] = []
        layers.reserveCapacity(state.image.layers.count)
        for layer in state.image.layers {
            var cropped = layer
            cropped.surface = croppedSurface(layer.surface, mask: mask, to: rect)
            layers.append(cropped)
        }
        let image = LayeredImage(size: rect.size, dpi: state.image.dpi, layers: layers,
                                 activeLayerIndex: state.image.activeLayerIndex)
        // The selection follows the pixels: `rect` contains ≥ 1 covered pixel, so the
        // cropped mask is never empty and this never returns nil (0013 invariant).
        guard let croppedSelection = selection.translatedAndCropped(to: rect) else {
            return nil
        }
        return DocumentState(image: image, selection: croppedSelection)
    }

    /// The "Crop to Selection" step, or `nil` when disabled or a no-op (H-6).
    static func makeHistoryItem(for state: DocumentState) -> DocumentSnapshotHistoryItem? {
        guard let after = croppedState(state) else { return nil }
        return DocumentSnapshotHistoryItem(name: name, icon: icon, before: state, after: after)
    }

    /// The per-pixel rule: the source pixel kept with selection coverage `c`. Fully
    /// covered pixels are bit-identical (color under alpha 0 survives, D-33); a zero
    /// result clears the color ("pixels outside the selection will be made transparent
    /// with the color information removed"); partial coverage scales only alpha — the
    /// straight-alpha convention of 0011's `EraseOps`.
    static func masked(_ pixel: ColorRGBA8, coverage c: UInt8) -> ColorRGBA8 {
        guard c != 255 else { return pixel }
        let alpha = BlendOps.mul255(pixel.alpha, c)
        guard alpha != 0 else { return .clear }
        return ColorRGBA8(red: pixel.red, green: pixel.green, blue: pixel.blue, alpha: alpha)
    }

    // MARK: - Surface crop (NF-4)

    /// One destination tile's planned storage (written by exactly one
    /// `concurrentPerform` task, read after it returns — the `SelectionMaskTileBox`
    /// pattern).
    private final class TileBox: @unchecked Sendable {
        var tile: Tile?
    }

    private enum MaskKind { case empty, full, mixed }

    private static func croppedSurface(_ source: TiledSurface, mask: SelectionMask,
                                       to rect: PixelRect) -> TiledSurface {
        var result = TiledSurface(size: rect.size)
        let columns = result.tileColumns
        let total = result.tileCount
        let aligned = rect.x % TiledSurface.tileSize == 0 && rect.y % TiledSurface.tileSize == 0
        let baseColumn = rect.x / TiledSurface.tileSize
        let baseRow = rect.y / TiledSurface.tileSize
        let boxes = (0..<total).map { _ in TileBox() }
        // Per-tile work is per-pixel independent, so the outcome is bit-identical to a
        // serial loop (NF-1); the surface is written serially afterwards.
        DispatchQueue.concurrentPerform(iterations: total) { index in
            let column = index % columns
            let row = index / columns
            let tileRect = PixelRect(x: column * TiledSurface.tileSize,
                                     y: row * TiledSurface.tileSize,
                                     width: TiledSurface.tileSize,
                                     height: TiledSurface.tileSize)
            let area = tileRect.intersection(rect.size.bounds)
            guard !area.isEmpty else { return }
            let sourceRect = PixelRect(x: rect.x + area.minX, y: rect.y + area.minY,
                                       width: area.width, height: area.height)
            if aligned, tileRect.maxX <= rect.width, tileRect.maxY <= rect.height,
               case .full = mask.tile(at: TileCoordinate(column: baseColumn + column,
                                                         row: baseRow + row)) {
                // Every source pixel is coverage 255: `masked` is the identity, so the
                // destination tile IS the source tile (shared storage, including a nil
                // source tile staying unallocated).
                boxes[index].tile = source.tile(at: TileCoordinate(column: baseColumn + column,
                                                                   row: baseRow + row))
                return
            }
            switch maskKind(of: sourceRect, in: mask) {
            case .empty:
                break   // the tile stays unallocated
            case .full:
                boxes[index].tile = copiedTile(from: source, rect: sourceRect)
            case .mixed:
                boxes[index].tile = maskedTile(from: source, rect: sourceRect, mask: mask)
            }
        }
        for index in 0..<total {
            guard let tile = boxes[index].tile else { continue }
            result.setTile(tile, at: TileCoordinate(column: index % columns,
                                                    row: index / columns))
        }
        // Wholly cleared destination tiles are unallocated (NF-4).
        result.releaseTransparentTiles()
        return result
    }

    /// The union of the mask tiles overlapping `rect`: all-`.full` → every pixel is
    /// 255; all-`.empty` → every pixel is 0; anything else runs the per-pixel loop.
    private static func maskKind(of rect: PixelRect, in mask: SelectionMask) -> MaskKind {
        var allFull = true
        var anyCoverage = false
        for row in (rect.minY >> 8)...((rect.maxY - 1) >> 8) {
            for column in (rect.minX >> 8)...((rect.maxX - 1) >> 8) {
                switch mask.tile(at: TileCoordinate(column: column, row: row)) {
                case .empty: allFull = false
                case .full: anyCoverage = true
                case .partial: allFull = false; anyCoverage = true
                }
            }
        }
        if allFull { return .full }
        return anyCoverage ? .mixed : .empty
    }

    /// A destination tile for an all-coverage-255 source rect: the source bytes copied
    /// row-wise into a zero-padded tile (`masked` is the identity).
    private static func copiedTile(from source: TiledSurface, rect: PixelRect) -> Tile {
        let bytes = source.readPixels(in: rect)
        if rect.width == TiledSurface.tileSize, rect.height == TiledSurface.tileSize {
            return Tile(bytes: bytes)
        }
        var out = [UInt8](repeating: 0, count: Tile.byteCount)
        bytes.withUnsafeBytes { input in
            out.withUnsafeMutableBytes { output in
                copyRegion(from: input, to: output, region: rect, inside: rect)
            }
        }
        return Tile(bytes: out)
    }

    /// A destination tile with the per-pixel rule applied through the mask coverage,
    /// processed per mask tile so `.full` areas bulk-copy, `.empty` areas stay zero, and
    /// only `.partial` areas run the (raw-pointer) pixel loop — the antialiased edge is
    /// the only per-pixel work (NF-1).
    private static func maskedTile(from source: TiledSurface, rect: PixelRect,
                                   mask: SelectionMask) -> Tile {
        let input = source.readPixels(in: rect)
        var out = [UInt8](repeating: 0, count: Tile.byteCount)
        input.withUnsafeBytes { input in
            out.withUnsafeMutableBytes { output in
                let firstRow = rect.minY >> 8, lastRow = (rect.maxY - 1) >> 8
                let firstColumn = rect.minX >> 8, lastColumn = (rect.maxX - 1) >> 8
                for row in firstRow...lastRow {
                    for column in firstColumn...lastColumn {
                        let overlap = rect.intersection(PixelRect(x: column << 8, y: row << 8,
                                                                  width: TiledSurface.tileSize,
                                                                  height: TiledSurface.tileSize))
                        guard !overlap.isEmpty else { continue }
                        switch mask.tile(at: TileCoordinate(column: column, row: row)) {
                        case .empty:
                            break   // the zero-initialized padding stays zero
                        case .full:
                            copyRegion(from: input, to: output, region: overlap, inside: rect)
                        case .partial(let storage):
                            storage.bytes.withUnsafeBytes { coverage in
                                for y in overlap.minY..<overlap.maxY {
                                    let coverageRow = (y & 255) << 8
                                    var read = ((y - rect.minY) * rect.width
                                                + (overlap.minX - rect.minX)) << 2
                                    var write = ((y - rect.minY) * TiledSurface.tileSize
                                                 + (overlap.minX - rect.minX)) << 2
                                    for x in overlap.minX..<overlap.maxX {
                                        let c = coverage[coverageRow | (x & 255)]
                                        if c == 255 {
                                            output[write] = input[read]
                                            output[write + 1] = input[read + 1]
                                            output[write + 2] = input[read + 2]
                                            output[write + 3] = input[read + 3]
                                        } else {
                                            // `masked` inlined: `mul255`, zero clears the
                                            // color, otherwise only alpha scales.
                                            let product = UInt32(input[read + 3]) * UInt32(c) + 128
                                            let alpha = UInt8(((product >> 8) + product) >> 8)
                                            if alpha == 0 {
                                                output[write] = 0
                                                output[write + 1] = 0
                                                output[write + 2] = 0
                                                output[write + 3] = 0
                                            } else {
                                                output[write] = input[read]
                                                output[write + 1] = input[read + 1]
                                                output[write + 2] = input[read + 2]
                                                output[write + 3] = alpha
                                            }
                                        }
                                        read += 4
                                        write += 4
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return Tile(bytes: out)
    }

    /// Row-wise `copyMemory` of `region` from a tightly packed `inside`-sized buffer
    /// into the zero-padded destination tile at the region's offset (both buffers use
    /// `inside`'s origin, so only `region`'s rows move).
    private static func copyRegion(from source: UnsafeRawBufferPointer,
                                   to destination: UnsafeMutableRawBufferPointer,
                                   region: PixelRect, inside: PixelRect) {
        let rowBytes = region.width << 2
        for y in region.minY..<region.maxY {
            let localY = y - inside.minY
            let sourceStart = (localY * inside.width + (region.minX - inside.minX)) << 2
            let destinationStart = (localY * TiledSurface.tileSize
                                    + (region.minX - inside.minX)) << 2
            UnsafeMutableRawBufferPointer(rebasing: destination[destinationStart
                                                                ..< destinationStart + rowBytes])
                .copyMemory(from: UnsafeRawBufferPointer(rebasing: source[sourceStart..<sourceStart + rowBytes]))
        }
    }
}
