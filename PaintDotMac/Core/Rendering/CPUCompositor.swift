import Foundation

/// The pixels of one composited region: `rect` (the requested rect clipped to the canvas)
/// and `pixels` row-major inside it, `rect.width × rect.height` entries (empty when the
/// intersection is empty). Spec 0012; 0002's `readPixels(in:)` returns raw bytes without a
/// rect, so this is a new type.
struct CompositedRegion: Equatable, Sendable {
    let rect: PixelRect
    let pixels: [ColorRGBA8]
}

/// The deterministic CPU reference compositor (PRD §4, D-16; spec 0012). The reference for
/// export, flatten, merge down, Copy Merged, and image-sampling tools; 0024's Metal
/// compositor must match it within ±1 per channel. Stateless — an instance so later specs
/// can add options such as a background.
///
/// The contract 0024 mirrors: per pixel, start from `(0, 0, 0, 0)`; for each layer **bottom
/// to top** that `isVisible` and has `opacity > 0`,
/// `dst = BlendOps.blend(layer.blendMode, dst: dst, src: src, opacity: layer.opacity)`,
/// where `src` is the layer's stored straight pixel. Inputs and outputs are **straight**
/// sRGB RGBA8; any premultiplication is internal to the blend step and never escapes
/// (AGENTS rule 4). The compositor mutates no layer and never touches history. Blend modes
/// come from `BlendOps` for free (only `.normal` today; 0026/0027/0059 add cases).
struct CPUCompositor: Sendable {
    /// Composites `image` over `rect`, clipped to the canvas bounds `(0, 0, image.size)`.
    /// The result is empty (`rect == .zero`, no pixels) when the intersection is empty;
    /// only the intersection is ever composited, never the whole image.
    func composite(_ image: LayeredImage, in rect: PixelRect) -> CompositedRegion {
        let clipped = rect.intersection(image.size.bounds)
        guard !clipped.isEmpty else { return CompositedRegion(rect: .zero, pixels: []) }
        // Visible, non-transparent layers bottom to top — the only ones the contract visits.
        var sources: [(surface: TiledSurface, opacity: UInt8, blendMode: BlendMode)] = []
        for layer in image.layers where layer.isVisible && layer.opacity > 0 {
            sources.append((layer.surface, layer.opacity, layer.blendMode))
        }
        var pixels = [ColorRGBA8](repeating: .clear, count: clipped.width * clipped.height)
        for row in 0..<clipped.height {
            let y = clipped.minY + row
            let rowBase = row * clipped.width
            for column in 0..<clipped.width {
                pixels[rowBase + column] = Self.compositePixel(
                    at: PixelPoint(x: clipped.minX + column, y: y), sources: sources)
            }
        }
        return CompositedRegion(rect: clipped, pixels: pixels)
    }

    /// The composite of one 256×256 canvas tile, edge tiles clipped to the canvas (matching
    /// how `TiledSurface` stores edge tiles), row-major. Returns `nil` — the result would be
    /// fully transparent — when no visible layer with `opacity > 0` has an allocated tile at
    /// `coordinate`, so sparse surfaces stay sparse; also for coordinates outside the grid.
    func compositeTile(_ coordinate: TileCoordinate, of image: LayeredImage) -> [ColorRGBA8]? {
        guard let tileRect = Self.tileRect(of: coordinate, size: image.size) else { return nil }
        let hasContribution = image.layers.contains { layer in
            layer.isVisible && layer.opacity > 0 && Self.tileExists(layer.surface, at: coordinate)
        }
        guard hasContribution else { return nil }
        return composite(image, in: tileRect).pixels
    }

    /// A new surface of `image.size` built tile by tile from `compositeTile`; tiles where it
    /// returns `nil` (and tiles whose composite is fully transparent, keeping the sparse
    /// invariant) stay unallocated. Used by 0024+ for Flatten / Merge Down / export.
    func flattened(_ image: LayeredImage) -> TiledSurface {
        var result = TiledSurface(size: image.size)
        for row in 0..<result.tileRows {
            for column in 0..<result.tileColumns {
                let coordinate = TileCoordinate(column: column, row: row)
                guard let pixels = compositeTile(coordinate, of: image),
                      let area = Self.tileRect(of: coordinate, size: image.size) else { continue }
                var composed = Tile()
                composed.withUnsafeMutableBytes { destination in
                    pixels.withUnsafeBytes { source in
                        for y in 0..<area.height {
                            let sourceOffset = y * area.width * PixelFormat.rgba8.bytesPerPixel
                            let destinationOffset = y * Tile.bytesPerRow
                            UnsafeMutableRawBufferPointer(
                                rebasing: destination[destinationOffset
                                                      ..< destinationOffset + area.width * 4])
                                .copyMemory(from: UnsafeRawBufferPointer(
                                    rebasing: source[sourceOffset
                                                     ..< sourceOffset + area.width * 4]))
                        }
                    }
                }
                // `setTile` demands the edge-padding invariant (the fresh `Tile` is zero
                // outside `area`) and the sparse invariant (skip a fully transparent result).
                if !composed.isFullyTransparent {
                    result.setTile(composed, at: coordinate)
                }
            }
        }
        return result
    }

    /// Paint.NET's Merge Layer Down (spec 0024 item 2, D-51): `upper` blended onto
    /// `lower`'s stored straight pixels with the **upper** layer's blend mode and
    /// opacity; the visibility of either layer is ignored (Paint.NET 3.36 renders the
    /// upper layer regardless). Result has `lower.size`; the lower layer's own opacity,
    /// blend mode, and visibility are *not* applied to its pixels — they still apply when
    /// the merged layer is composited.
    ///
    /// Per tile coordinate: when `upper.opacity == 0` or `upper` has no allocated tile
    /// there, the result tile **is** lower's tile (shared storage, or unallocated when
    /// lower has none). Otherwise only the tile's in-canvas region is blended
    /// (`lowerPixel = (0, 0, 0, 0)` where lower has no tile); a result whose valid pixels
    /// are all zero stays unallocated (sparse stays sparse), and edge-tile padding stays
    /// zero. The blended pixels are exactly what the D-16 loop produces for the
    /// two-layer stack with the lower layer plain, which the tests pin down.
    func merged(_ upper: Layer, onto lower: Layer) -> TiledSurface {
        precondition(upper.size == lower.size,
                     "merged needs equal layer sizes (upper \(upper.size), lower \(lower.size))")
        var result = TiledSurface(size: lower.size)
        guard upper.opacity > 0 else {
            // A 0-opacity upper layer contributes nothing to any pixel (spec edge case);
            // every tile is shared with lower unchanged.
            for row in 0..<lower.surface.tileRows {
                for column in 0..<lower.surface.tileColumns {
                    let coordinate = TileCoordinate(column: column, row: row)
                    result.setTile(lower.surface.tile(at: coordinate), at: coordinate)
                }
            }
            return result
        }
        for row in 0..<lower.surface.tileRows {
            for column in 0..<lower.surface.tileColumns {
                let coordinate = TileCoordinate(column: column, row: row)
                guard let upperTile = upper.surface.tile(at: coordinate) else {
                    result.setTile(lower.surface.tile(at: coordinate), at: coordinate)
                    continue
                }
                // Full 256×256 tiles; only the in-canvas area is read or written, so the
                // edge padding of every tile stays zero.
                let area = lower.surface.pixelRect(of: coordinate)
                let lowerTile = lower.surface.tile(at: coordinate)
                var out = Tile()
                out.withUnsafeMutableBytes { destination in
                    upperTile.withUnsafeBytes { upperBytes in
                        if let lowerTile {
                            lowerTile.withUnsafeBytes { lowerBytes in
                                Self.blendTileBytes(dst: lowerBytes, into: destination,
                                                    src: upperBytes, area: area,
                                                    blendMode: upper.blendMode,
                                                    opacity: upper.opacity)
                            }
                        } else {
                            // An unallocated lower tile reads (0, 0, 0, 0) per pixel —
                            // the destination buffer is already zero.
                            Self.blendTileBytes(dst: UnsafeRawBufferPointer(start: nil, count: 0),
                                                into: destination, src: upperBytes, area: area,
                                                blendMode: upper.blendMode,
                                                opacity: upper.opacity)
                        }
                    }
                }
                if !out.isFullyTransparent {
                    result.setTile(out, at: coordinate)
                }
            }
        }
        return result
    }

    /// Blends `src` over `dst` tile bytes into `destination` over `area` (the tile's
    /// in-canvas rect, tile-local origin). A nil/empty `dst` reads `(0, 0, 0, 0)`. Bytes
    /// outside `area` are left as they are in `destination` (a freshly zeroed tile).
    private static func blendTileBytes(dst: UnsafeRawBufferPointer,
                                       into destination: UnsafeMutableRawBufferPointer,
                                       src: UnsafeRawBufferPointer, area: PixelRect,
                                       blendMode: BlendMode, opacity: UInt8) {
        func pixel(_ buffer: UnsafeRawBufferPointer, _ offset: Int) -> ColorRGBA8 {
            guard !buffer.isEmpty else { return .clear }
            return ColorRGBA8(red: buffer[offset], green: buffer[offset + 1],
                              blue: buffer[offset + 2], alpha: buffer[offset + 3])
        }
        for y in 0..<area.height {
            let rowBase = y * Tile.bytesPerRow
            for x in 0..<area.width {
                let offset = rowBase + x * PixelFormat.rgba8.bytesPerPixel
                let blended = BlendOps.blend(blendMode,
                                             dst: pixel(dst, offset),
                                             src: pixel(src, offset),
                                             opacity: opacity)
                destination[offset] = blended.red
                destination[offset + 1] = blended.green
                destination[offset + 2] = blended.blue
                destination[offset + 3] = blended.alpha
            }
        }
    }

    // MARK: - Pixel contract

    /// The per-pixel loop of the D-16 contract, with the fast paths the spec requires —
    /// all bit-identical to `BlendOps.blend`:
    /// - a source pixel with `alpha == 0` returns `dst` unchanged (`blend`'s own `Sa == 0`
    ///   rule), and an unallocated tile reads `.clear`, so unallocated tiles are skipped;
    /// - `mul255(a, opacity) == 0` likewise returns `dst` unchanged;
    /// - a fully transparent destination is exactly `(0, 0, 0, 0)` (alpha only ever rises
    ///   from 0 once a contribution lands) and with Normal mode `blend` reproduces the
    ///   opacity-scaled source exactly, so the fast path returns it directly.
    private static func compositePixel(at point: PixelPoint,
                                       sources: [(surface: TiledSurface, opacity: UInt8,
                                                 blendMode: BlendMode)]) -> ColorRGBA8 {
        var dst = ColorRGBA8.clear
        for source in sources {
            let src = source.surface.pixel(at: point)
            guard src.alpha != 0 else { continue }
            let scaledAlpha = BlendOps.mul255(src.alpha, source.opacity)
            guard scaledAlpha != 0 else { continue }
            if dst.alpha == 0 && source.blendMode == .normal {
                dst = ColorRGBA8(red: src.red, green: src.green, blue: src.blue,
                                 alpha: scaledAlpha)
            } else {
                dst = BlendOps.blend(source.blendMode, dst: dst, src: src,
                                     opacity: source.opacity)
            }
        }
        return dst
    }

    /// The tile's canvas rect clipped to the image; `nil` when the coordinate is outside the
    /// tile grid (`TiledSurface.tile(at:)` would trap there).
    private static func tileRect(of coordinate: TileCoordinate, size: PixelSize) -> PixelRect? {
        let columns = (size.width + TiledSurface.tileSize - 1) / TiledSurface.tileSize
        let rows = (size.height + TiledSurface.tileSize - 1) / TiledSurface.tileSize
        guard coordinate.column >= 0, coordinate.row >= 0,
              coordinate.column < columns, coordinate.row < rows else { return nil }
        return PixelRect(x: coordinate.column * TiledSurface.tileSize,
                         y: coordinate.row * TiledSurface.tileSize,
                         width: TiledSurface.tileSize, height: TiledSurface.tileSize)
            .intersection(size.bounds)
    }

    /// `TiledSurface.tile(at:)` without trapping for an out-of-grid coordinate.
    private static func tileExists(_ surface: TiledSurface, at coordinate: TileCoordinate) -> Bool {
        let columns = (surface.size.width + TiledSurface.tileSize - 1) / TiledSurface.tileSize
        let rows = (surface.size.height + TiledSurface.tileSize - 1) / TiledSurface.tileSize
        guard coordinate.column >= 0, coordinate.row >= 0,
              coordinate.column < columns, coordinate.row < rows else { return false }
        return surface.tile(at: coordinate) != nil
    }
}
