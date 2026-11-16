import CoreGraphics
import Foundation

/// Immutable `CGPath`s are thread-safe (CoreGraphics paths are fixed at construction);
/// the unchecked box lets the per-tile `concurrentPerform` read one.
private struct SendableRasterizePath: @unchecked Sendable {
    let path: CGPath
}

/// Path → `SelectionMask` (spec 0013). The one place in the code that converts a selection
/// path to pixels; it never flips Y anywhere else.
///
/// The input path is in **canvas coordinates** (y down) and filled with the non-zero
/// winding rule (callers pass normalized paths — see `Selection`). An empty `size`, an
/// empty path, or a non-finite `boundingBoxOfPath` yields the empty mask.
enum MaskRasterizer {
    /// `CGRect.isFinite` is `package`-level in the macOS 26 SDK, so the four components
    /// are checked directly.
    static func rectIsFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
    }

    static func rasterize(_ path: CGPath, size: PixelSize, antialiased: Bool) -> SelectionMask {
        guard !size.isEmpty, !path.isEmpty, rectIsFinite(path.boundingBoxOfPath) else {
            return SelectionMask(size: size)
        }
        var rect = CGRect.zero
        if path.isRect(&rect) {
            return rasterizeRect(rect.standardized, size: size, antialiased: antialiased)
        }
        return rasterizeGeneral(path, size: size, antialiased: antialiased)
    }

    // MARK: - Axis-aligned rectangle fast path

    /// Exact analytic coverage — no CoreGraphics rendering — so rectangles (Select All's
    /// inverse, 0014 Rectangle Select, the UI-test hook) are deterministic. Tiles wholly
    /// inside the 255-interior are `.full` and tiles wholly outside are `.empty`, so a
    /// whole-canvas integer rectangle allocates no tile bytes (NF-1).
    private static func rasterizeRect(_ rect: CGRect, size: PixelSize,
                                      antialiased: Bool) -> SelectionMask {
        guard rect.width > 0, rect.height > 0 else { return SelectionMask(size: size) }
        let columns = size.width + SelectionMask.tileSize - 1
        let gridColumns = columns / SelectionMask.tileSize
        let gridRows = (size.height + SelectionMask.tileSize - 1) / SelectionMask.tileSize
        // Aliased: pixel (i, j) is 255 iff its center (i+0.5, j+0.5) is in the rect,
        // i.e. i ∈ ceil(minX − 0.5) ..< ceil(maxX − 0.5) (same for rows).
        let columnSpan: ClosedRange<Int>?
        let rowSpan: ClosedRange<Int>?
        if antialiased {
            columnSpan = nil
            rowSpan = nil
        } else {
            let firstColumn = Int((rect.minX - 0.5).rounded(.up))
            let lastColumnExclusive = Int((rect.maxX - 0.5).rounded(.up))
            let firstRow = Int((rect.minY - 0.5).rounded(.up))
            let lastRowExclusive = Int((rect.maxY - 0.5).rounded(.up))
            columnSpan = lastColumnExclusive > firstColumn
                ? firstColumn...(lastColumnExclusive - 1) : nil
            rowSpan = lastRowExclusive > firstRow ? firstRow...(lastRowExclusive - 1) : nil
        }
        var tiles: [SelectionMaskTile] = []
        tiles.reserveCapacity(gridColumns * gridRows)
        for row in 0..<gridRows {
            for column in 0..<gridColumns {
                let originX = column * SelectionMask.tileSize
                let originY = row * SelectionMask.tileSize
                let inCanvas = PixelRect(x: originX, y: originY,
                                         width: SelectionMask.tileSize,
                                         height: SelectionMask.tileSize)
                    .intersection(size.bounds)
                let tileRect = CGRect(x: inCanvas.minX, y: inCanvas.minY,
                                      width: inCanvas.width, height: inCanvas.height)
                if tileRect.isNull || tileRect.width <= 0 || tileRect.height <= 0
                    || tileRect.maxX <= rect.minX || tileRect.minX >= rect.maxX
                    || tileRect.maxY <= rect.minY || tileRect.minY >= rect.maxY {
                    tiles.append(.empty)
                    continue
                }
                let fullyInside: Bool
                if antialiased {
                    fullyInside = tileRect.minX >= rect.minX && tileRect.maxX <= rect.maxX
                        && tileRect.minY >= rect.minY && tileRect.maxY <= rect.maxY
                } else {
                    fullyInside = (columnSpan?.contains(inCanvas.minX) ?? false)
                        && (columnSpan?.contains(inCanvas.maxX - 1) ?? false)
                        && (rowSpan?.contains(inCanvas.minY) ?? false)
                        && (rowSpan?.contains(inCanvas.maxY - 1) ?? false)
                }
                if fullyInside {
                    tiles.append(.full)
                    continue
                }
                var bytes = [UInt8](repeating: 0, count: SelectionMaskTileStorage.byteCount)
                for y in inCanvas.minY..<inCanvas.maxY {
                    let rowStart = (y - originY) * SelectionMask.tileSize
                    for x in inCanvas.minX..<inCanvas.maxX {
                        var value: UInt8 = 0
                        if antialiased {
                            // coverage = round(255 · overlapX · overlapY), overlaps in 0…1.
                            let overlapX = max(0, min(Double(x + 1), rect.maxX)
                                - max(Double(x), rect.minX))
                            let overlapY = max(0, min(Double(y + 1), rect.maxY)
                                - max(Double(y), rect.minY))
                            value = UInt8((255 * overlapX * overlapY)
                                .rounded(.toNearestOrAwayFromZero))
                        } else {
                            if columnSpan?.contains(x) == true, rowSpan?.contains(y) == true {
                                value = 255
                            }
                        }
                        bytes[rowStart + x - originX] = value
                    }
                }
                tiles.append(.partial(SelectionMaskTileStorage(bytes: bytes)))
            }
        }
        // The grid-level shortcut above already yields only `.full`/`.empty`/mixed tiles,
        // and partial tiles keep out-of-canvas bytes 0; `init` re-normalizes defensively.
        return SelectionMask(size: size, tiles: tiles)
    }

    // MARK: - General paths

    /// Only tiles whose rect intersects `boundingBoxOfPath` expanded by 1 px render; each
    /// gets its own 256 × 256 8-bit gray context, filled winding with 1.0 gray. Tiles
    /// render concurrently, one context each; per-pixel results are independent, so the
    /// outcome is bit-identical to a serial rasterization.
    private static func rasterizeGeneral(_ path: CGPath, size: PixelSize,
                                         antialiased: Bool) -> SelectionMask {
        let gridColumns = (size.width + SelectionMask.tileSize - 1) / SelectionMask.tileSize
        let gridRows = (size.height + SelectionMask.tileSize - 1) / SelectionMask.tileSize
        let count = gridColumns * gridRows
        let bbox = path.boundingBoxOfPath.insetBy(dx: -1, dy: -1)
        var candidates: [Int] = []
        for row in 0..<gridRows {
            for column in 0..<gridColumns {
                let tileRect = CGRect(x: column * SelectionMask.tileSize,
                                      y: row * SelectionMask.tileSize,
                                      width: SelectionMask.tileSize, height: SelectionMask.tileSize)
                if tileRect.intersects(bbox) { candidates.append(row * gridColumns + column) }
            }
        }
        let indices = candidates
        // Immutable `CGPath`s are thread-safe; the box lets the concurrent loop read one.
        let pathBox = SendableRasterizePath(path: path)
        let boxes = indices.map { _ in SelectionMaskTileBox() }
        DispatchQueue.concurrentPerform(iterations: indices.count) { job in
            // One context per tile; per-pixel results are independent. concurrentPerform
            // returned before the reads below, so the box writes are visible.
            boxes[job].tile = Self.renderTile(pathBox.path, column: indices[job] % gridColumns,
                                              row: indices[job] / gridColumns, size: size,
                                              antialiased: antialiased) ?? .empty
        }
        var tiles = [SelectionMaskTile](repeating: .empty, count: count)
        for (job, box) in zip(indices, boxes) { tiles[job] = box.tile }
        // `renderTile` returns normalized tiles; non-candidates are `.empty` (NF-1:
        // no defensive second pass over 12 M bytes).
        return SelectionMask(size: size, normalizedTiles: tiles)
    }

    private static func renderTile(_ path: CGPath, column: Int, row: Int, size: PixelSize,
                                   antialiased: Bool) -> SelectionMaskTile? {
        let originX = column * SelectionMask.tileSize
        let originY = row * SelectionMask.tileSize
        let inCanvas = PixelRect(x: originX, y: originY,
                                 width: SelectionMask.tileSize, height: SelectionMask.tileSize)
            .intersection(size.bounds)
        guard !inCanvas.isEmpty else { return .empty }
        let buffer = UnsafeMutableRawPointer
            .allocate(byteCount: SelectionMaskTileStorage.byteCount, alignment: 64)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0,
                                count: SelectionMaskTileStorage.byteCount)
        guard let context = CGContext(data: buffer,
                                      width: SelectionMask.tileSize,
                                      height: SelectionMask.tileSize,
                                      bitsPerComponent: 8,
                                      bytesPerRow: SelectionMask.tileSize,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        // Canvas y-down → bitmap row 0 = canvas row `originY`:
        // translate(0, 256) · scale(1, −1) · translate(−originX, −originY).
        context.translateBy(x: 0, y: CGFloat(SelectionMask.tileSize))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: CGFloat(-originX), y: CGFloat(-originY))
        context.clip(to: CGRect(x: inCanvas.minX, y: inCanvas.minY,
                                width: inCanvas.width, height: inCanvas.height))
        context.setShouldAntialias(true)
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(path)
        context.fillPath(using: .winding)
        var bytes = Array(UnsafeBufferPointer(
            start: buffer.bindMemory(to: UInt8.self, capacity: SelectionMaskTileStorage.byteCount),
            count: SelectionMaskTileStorage.byteCount))
        if !antialiased {
            // Aliased general paths follow the exact pixel-center rule — the same rule
            // the rectangle fast path implements: a pixel is 255 iff its center is in
            // the path. Quartz's antialias-off fill includes whole pixels the path
            // merely touches (measured ~2–10 % too many, breaking the aliased circle's
            // area test), and thresholding the antialiased coverage at 128 drops real
            // concave spikes whose area is under half a pixel. So the antialiased fill
            // is used only as a cheap pre-classifier: coverage 255 proves the pixel is
            // covered, 0 means the fill saw nothing, and only boundary pixels
            // (0 < coverage < 255) pay a point-in-path test. The remaining deviation
            // from the literal rule needs sub-0.2 %-area needles at a pixel center.
            for y in inCanvas.minY..<inCanvas.maxY {
                let rowStart = (y - originY) * SelectionMask.tileSize
                for x in inCanvas.minX..<inCanvas.maxX {
                    let index = rowStart + x - originX
                    let coverage = bytes[index]
                    if coverage == 255 { continue }
                    let inside = coverage != 0 && path.contains(
                        CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), using: .winding)
                    bytes[index] = inside ? 255 : 0
                }
            }
        }
        // Normalize while the tile is hot in cache (one pass, NF-1): out-of-canvas bytes
        // are already 0 (zeroed buffer + clip), so only the in-canvas window decides the
        // all-0 / all-255 verdict.
        let localMinX = inCanvas.minX - originX, localMaxX = inCanvas.maxX - originX
        let localMinY = inCanvas.minY - originY, localMaxY = inCanvas.maxY - originY
        let fullyInside = localMinX == 0 && localMinY == 0
            && localMaxX == SelectionMask.tileSize && localMaxY == SelectionMask.tileSize
        var allZero = true
        var allFull = true
        if fullyInside {
            for value in bytes {
                if value != 0 { allZero = false }
                if value != 255 { allFull = false }
                if !allZero && !allFull { break }
            }
        } else {
            for y in localMinY..<localMaxY {
                let rowStart = y * SelectionMask.tileSize
                for x in localMinX..<localMaxX {
                    let value = bytes[rowStart + x]
                    if value != 0 { allZero = false }
                    if value != 255 { allFull = false }
                    if !allZero && !allFull { break }
                }
                if !allZero && !allFull { break }
            }
        }
        if allZero { return .empty }
        if allFull { return .full }
        return .partial(SelectionMaskTileStorage(bytes: bytes))
    }
}
