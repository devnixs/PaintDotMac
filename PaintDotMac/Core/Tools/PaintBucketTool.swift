import CoreGraphics
import Foundation

// MARK: - Options (spec 0017, PRD T-9 / TOOL-C)

/// The Paint Bucket's **Fill** option (PRD T-9's "option to fill the selection",
/// spec 0017 Decisions): "Similar Color" runs the flood; "Selection" fills the whole
/// active selection with its own antialiased mask, ignoring tolerance, flood mode,
/// sampling, and the Antialiasing toggle — with no selection, the whole layer.
enum PaintBucketFillMode: String, CaseIterable, Sendable {
    case similarColor
    case selection

    var displayName: String {
        switch self {
        case .similarColor: "Similar Color"
        case .selection: "Selection"
        }
    }
}

extension PaintBucketFillMode: ToolOptionValue {}

/// The Paint Bucket's stored options (Paint.NET defaults: Fill Similar Color, Flood mode
/// Contiguous, Tolerance 50 %, Sampling Layer, Antialiasing on, Blend Mode Normal).
/// Flood mode / Tolerance / Sampling go through 0016's `FloodToolOptions` with
/// `.paintBucket`, so the keys are exactly `tool.paintBucket.*` — independent of the
/// Magic Wand's copies (TOOL-C). Missing or unknown stored values fall back to the
/// defaults; the tolerance key clamps 0…100 on read and write.
struct PaintBucketOptions: Equatable, Sendable {
    var fillMode: PaintBucketFillMode
    var floodMode: FloodMode
    var tolerance: FloodTolerance
    var samplingMode: SamplingMode
    var antialiasing: Bool
    var blendMode: BlendMode

    static let `default` = PaintBucketOptions(
        fillMode: .similarColor,
        floodMode: .contiguous,
        tolerance: FloodTolerance(percent: 50),
        samplingMode: .layer,
        antialiasing: true,
        blendMode: .normal
    )

    /// `tool.paintBucket.fillMode`, stored as the raw string.
    static var fillModeKey: ToolOptionKey<PaintBucketFillMode> {
        ToolOptionKey(tool: .paintBucket, name: "fillMode", defaultValue: .similarColor)
    }

    /// `tool.paintBucket.antialiasing`.
    static var antialiasingKey: ToolOptionKey<Bool> {
        ToolOptionKey(tool: .paintBucket, name: "antialiasing", defaultValue: true)
    }

    /// `tool.paintBucket.blendMode`, stored as the raw string (D-15 list).
    static var blendModeKey: ToolOptionKey<BlendMode> {
        ToolOptionKey(tool: .paintBucket, name: "blendMode", defaultValue: .normal)
    }

    @MainActor
    static func load(from store: any ToolOptionStore) -> PaintBucketOptions {
        PaintBucketOptions(
            fillMode: store.value(fillModeKey),
            floodMode: store.value(FloodToolOptions.floodMode(for: .paintBucket)),
            tolerance: FloodTolerance(
                percent: store.value(FloodToolOptions.tolerance(for: .paintBucket))),
            samplingMode: store.value(FloodToolOptions.samplingMode(for: .paintBucket)),
            antialiasing: store.value(antialiasingKey),
            blendMode: store.value(blendModeKey)
        )
    }

    @MainActor
    func save(to store: any ToolOptionStore) {
        store.setValue(fillMode, for: Self.fillModeKey)
        store.setValue(floodMode, for: FloodToolOptions.floodMode(for: .paintBucket))
        store.setValue(tolerance.percent, for: FloodToolOptions.tolerance(for: .paintBucket))
        store.setValue(samplingMode, for: FloodToolOptions.samplingMode(for: .paintBucket))
        store.setValue(antialiasing, for: Self.antialiasingKey)
        store.setValue(blendMode, for: Self.blendModeKey)
    }
}

// MARK: - Fill coverage (pure)

/// The Paint Bucket's coverage math (spec 0017): a per-tile 8-bit coverage map plus the
/// compose rule. The fill is committed on the click; this enum owns the pixel work it
/// does — pure, `Sendable`, and unit-tested independent of the tool.
enum PaintBucketFill {
    /// Per-tile coverage, one 256×256 row-major `[UInt8]` per tile (edge tiles keep the
    /// full buffer; entries outside the canvas are 0 and ignored). Only tiles with at
    /// least one non-zero value are stored.
    struct FillCoverage: Sendable, Equatable {
        let canvasSize: PixelSize
        private(set) var tiles: [TileCoordinate: [UInt8]]

        /// 0 outside the canvas or for absent tiles.
        func coverage(x: Int, y: Int) -> UInt8 {
            guard x >= 0, y >= 0, x < canvasSize.width, y < canvasSize.height else {
                return 0
            }
            guard let tile = tiles[TileCoordinate(column: x / Tile.size, row: y / Tile.size)]
            else { return 0 }
            return tile[(y % Tile.size) * Tile.size + (x % Tile.size)]
        }

        var isEmpty: Bool { tiles.isEmpty }

        /// The tight bounds of the non-zero coverage; `nil` when nothing is covered.
        var bounds: PixelRect? {
            var minX = Int.max
            var minY = Int.max
            var maxX = Int.min
            var maxY = Int.min
            for (coordinate, values) in tiles {
                let originX = coordinate.column * Tile.size
                let originY = coordinate.row * Tile.size
                let width = min(Tile.size, canvasSize.width - originX)
                let height = min(Tile.size, canvasSize.height - originY)
                for y in 0..<height {
                    let rowOffset = y * Tile.size
                    for x in 0..<width where values[rowOffset + x] > 0 {
                        minX = min(minX, originX + x)
                        minY = min(minY, originY + y)
                        maxX = max(maxX, originX + x)
                        maxY = max(maxY, originY + y)
                    }
                }
            }
            guard minX <= maxX, minY <= maxY else { return nil }
            return PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }

    /// The feather value: round-half-up of `255·k/9` — `UInt8((510·k + 9) / 18)` for
    /// `k ∈ 0…8` gives 0, 28, 57, 85, 113, 142, 170, 198, 227 (spec 0017 Decisions).
    static func featherCoverage(neighbours k: Int) -> UInt8 {
        UInt8((510 * k + 9) / 18)
    }

    /// The matched region's coverage. Aliased: 255 inside the region, 0 elsewhere.
    /// Antialiased (the one-pixel feather): `max(mask, round(box3×3(mask)))` — a pixel
    /// outside the region gets `featherCoverage(k)` for the `k` region pixels among its
    /// 8 in-canvas neighbours; the region itself stays at 255. Only pixels within
    /// `region.bounds` expanded by 1 (clamped to the canvas) are visited, so the ring
    /// never leaves the canvas.
    static func coverage(region: FloodFillStencil, canvasSize: PixelSize,
                         antialiasing: Bool) -> FillCoverage {
        var tiles: [TileCoordinate: [UInt8]] = [:]
        guard !region.isEmpty else { return FillCoverage(canvasSize: canvasSize, tiles: [:]) }
        let bounds = region.bounds
        let expand = antialiasing ? 1 : 0
        let x0 = max(0, bounds.minX - expand)
        let y0 = max(0, bounds.minY - expand)
        let x1 = min(canvasSize.width, bounds.maxX + expand)
        let y1 = min(canvasSize.height, bounds.maxY + expand)
        guard x1 > x0, y1 > y0 else { return FillCoverage(canvasSize: canvasSize, tiles: [:]) }
        for row in (y0 / Tile.size)...((y1 - 1) / Tile.size) {
            for column in (x0 / Tile.size)...((x1 - 1) / Tile.size) {
                let originX = column * Tile.size
                let originY = row * Tile.size
                let blockX0 = max(x0, originX)
                let blockY0 = max(y0, originY)
                let blockX1 = min(x1, originX + Tile.size)
                let blockY1 = min(y1, originY + Tile.size)
                var buffer = [UInt8](repeating: 0, count: Tile.size * Tile.size)
                var anyCoverage = false
                for y in blockY0..<blockY1 {
                    let valueRow = (y - originY) * Tile.size
                    for x in blockX0..<blockX1 {
                        let point = PixelPoint(x: x, y: y)
                        let value: UInt8
                        if region.contains(point) {
                            value = 255
                        } else {
                            guard antialiasing else { continue }
                            var neighbours = 0
                            for dy in -1...1 {
                                for dx in -1...1 where dx != 0 || dy != 0 {
                                    // `region.contains` is false off-canvas, which is the
                                    // in-canvas neighbour rule the spec pins.
                                    if region.contains(PixelPoint(x: x + dx, y: y + dy)) {
                                        neighbours += 1
                                    }
                                }
                            }
                            value = featherCoverage(neighbours: neighbours)
                        }
                        if value > 0 {
                            buffer[valueRow + (x - originX)] = value
                            anyCoverage = true
                        }
                    }
                }
                if anyCoverage {
                    tiles[TileCoordinate(column: column, row: row)] = buffer
                }
            }
        }
        return FillCoverage(canvasSize: canvasSize, tiles: tiles)
    }

    /// Fill = Selection: the selection's own antialiased mask coverage (the Antialiasing
    /// option is ignored); a `nil` clip covers the whole canvas with 255.
    static func selectionCoverage(clip: (any BrushClipMask)?,
                                  canvasSize: PixelSize) -> FillCoverage {
        var tiles: [TileCoordinate: [UInt8]] = [:]
        guard !canvasSize.isEmpty else { return FillCoverage(canvasSize: canvasSize, tiles: [:]) }
        let canvas = canvasSize.bounds
        let visit: PixelRect
        if let clip {
            visit = clip.bounds.intersection(canvas)
        } else {
            visit = canvas
        }
        guard !visit.isEmpty else { return FillCoverage(canvasSize: canvasSize, tiles: [:]) }
        for row in (visit.minY / Tile.size)...((visit.maxY - 1) / Tile.size) {
            for column in (visit.minX / Tile.size)...((visit.maxX - 1) / Tile.size) {
                let originX = column * Tile.size
                let originY = row * Tile.size
                let blockX0 = max(visit.minX, originX)
                let blockY0 = max(visit.minY, originY)
                let blockX1 = min(visit.maxX, originX + Tile.size)
                let blockY1 = min(visit.maxY, originY + Tile.size)
                var buffer = [UInt8](repeating: 0, count: Tile.size * Tile.size)
                var anyCoverage = false
                for y in blockY0..<blockY1 {
                    let valueRow = (y - originY) * Tile.size
                    for x in blockX0..<blockX1 {
                        // `clip == nil` means everything is covered (0009's rule).
                        let value: UInt8 = clip?.coverage(x: x, y: y) ?? 255
                        if value > 0 {
                            buffer[valueRow + (x - originX)] = value
                            anyCoverage = true
                        }
                    }
                }
                if anyCoverage {
                    tiles[TileCoordinate(column: column, row: row)] = buffer
                }
            }
        }
        return FillCoverage(canvasSize: canvasSize, tiles: tiles)
    }

    /// Composes `color` through the coverage onto `surface` with 0009's Paintbrush rule
    /// (D-17): `effCov = mul255(cov, clip.coverage)`, `Sa = mul255(color.a, effCov)`,
    /// then `BlendOps.blend(blendMode, dst: before, src: (r, g, b, Sa))`. A pixel whose
    /// result equals the existing pixel is not written, and a tile is touched only when
    /// at least one pixel was written — so a no-op fill never bumps the surface
    /// `generation` (D-34). Returns the touched tile coordinates (the diff candidates).
    static func apply(_ coverage: FillCoverage, clip: (any BrushClipMask)?,
                      color: ColorRGBA8, blendMode: BlendMode,
                      to surface: inout TiledSurface) -> Set<TileCoordinate> {
        var touched: Set<TileCoordinate> = []
        let canvas = coverage.canvasSize.bounds
        for (coordinate, values) in coverage.tiles {
            let tileRect = PixelRect(origin: PixelPoint(x: coordinate.column * Tile.size,
                                                        y: coordinate.row * Tile.size),
                                     size: PixelSize(width: Tile.size, height: Tile.size))
            let drawRect = tileRect.intersection(canvas)
            guard !drawRect.isEmpty else { continue }
            // Pixels outside the clip's bounds have coverage 0, so the whole tile is a
            // no-op when the clip does not touch it.
            if let clip, clip.bounds.intersection(drawRect).isEmpty { continue }
            var tile = surface.tile(at: coordinate) ?? Tile()
            var wrote = false
            tile.withUnsafeMutableBytes { buffer in
                guard let raw = buffer.baseAddress else { return }
                let base = raw.bindMemory(to: UInt8.self, capacity: Tile.byteCount)
                for y in drawRect.minY..<drawRect.maxY {
                    let rowOffset = (y - tileRect.minY) * Tile.bytesPerRow
                    let valueRow = (y - tileRect.minY) * Tile.size
                    for x in drawRect.minX..<drawRect.maxX {
                        let cov = values[valueRow + (x - tileRect.minX)]
                        guard cov > 0 else { continue }
                        let effectiveCoverage: UInt8
                        if let clip {
                            effectiveCoverage = BlendOps.mul255(cov, clip.coverage(x: x, y: y))
                        } else {
                            effectiveCoverage = cov
                        }
                        guard effectiveCoverage > 0 else { continue }
                        let sourceAlpha = BlendOps.mul255(color.alpha, effectiveCoverage)
                        guard sourceAlpha > 0 else { continue }
                        let offset = rowOffset + (x - tileRect.minX) * 4
                        let before = ColorRGBA8(red: base[offset], green: base[offset + 1],
                                                blue: base[offset + 2], alpha: base[offset + 3])
                        let result: ColorRGBA8
                        if sourceAlpha == 255, blendMode == .normal {
                            // Normal with a fully covered opaque source is the source
                            // itself (`BlendOps.normal` returns it exactly) — the hot
                            // interior path of a plain fill.
                            result = ColorRGBA8(red: color.red, green: color.green,
                                                blue: color.blue, alpha: 255)
                        } else {
                            result = BlendOps.blend(
                                blendMode, dst: before,
                                src: ColorRGBA8(red: color.red, green: color.green,
                                                blue: color.blue, alpha: sourceAlpha))
                        }
                        if result != before {
                            base[offset] = result.red
                            base[offset + 1] = result.green
                            base[offset + 2] = result.blue
                            base[offset + 3] = result.alpha
                            wrote = true
                        }
                    }
                }
            }
            if wrote {
                surface.setTile(tile, at: coordinate)
                touched.insert(coordinate)
            }
        }
        return touched
    }

    /// The pixels the fill may cover: 0016's flood over the chosen sampling source,
    /// **limited to the active selection** — a pixel with selection coverage 0 is
    /// neither matched nor traversed (Paint.NET: "pixels outside an active selection are
    /// ignored"). `nil` = no fill (seed off-canvas or outside the selection, or the
    /// source/limit mismatch 0016 defines).
    static func region(for options: PaintBucketOptions, effectiveFloodMode: FloodMode,
                       image: LayeredImage, seed: PixelPoint,
                       selection: Selection?) -> FloodFillStencil? {
        FloodFill.fill(FloodFillSource.make(for: image, sampling: options.samplingMode),
                       from: seed, tolerance: options.tolerance, mode: effectiveFloodMode,
                       limit: selection.map { FloodFillStencil.from($0.mask) })
    }
}

// MARK: - The tool

/// The Paint Bucket (T-9, spec 0017; Paint.NET PaintBucket.html). One click fills the
/// similar-color region — contiguous or global (Shift-click forces Global), Paint.NET
/// `CheckColor` tolerance via 0016, sampled from the active layer or the composite —
/// with the matched region feathered by one pixel when Antialiasing is on, or the whole
/// active selection when Fill is set to Selection. Left button fills with the primary
/// color, right / Control-left with the secondary (TOOL-A); the active selection clips
/// the paint (TOOL-B) and the flood never crosses it. The fill is applied and committed
/// on the click as one "Paint Bucket" step (Decisions / D-42 — Paint.NET 3.x behavior,
/// no live fill); there is no pending edit, and an empty diff records nothing (D-34).
@MainActor
final class PaintBucketTool: Tool {
    let id: ToolID = .paintBucket

    /// The whole operation (spec 0017 step list). Clicks outside the canvas or outside
    /// the selection do nothing — no step, no pending state.
    func mouseDown(_ event: ToolEvent, context: any ToolContext) {
        let options = PaintBucketOptions.load(from: context.options)
        guard event.location.x.isFinite, event.location.y.isFinite else { return }
        let image = context.image
        guard image.layers.indices.contains(image.activeLayerIndex) else { return }
        let size = image.size
        guard event.location.x >= 0, event.location.y >= 0,
              event.location.x < Double(size.width), event.location.y < Double(size.height)
        else { return }
        let seed = PixelPoint(x: Int(event.location.x.rounded(.down)),
                              y: Int(event.location.y.rounded(.down)))

        // TOOL-A: right button and Control-left arrive as `.secondary` (the dispatcher
        // keeps `.control`); both take the secondary color.
        let color = event.button == .secondary || event.modifiers.contains(.control)
            ? context.colors.secondary
            : context.colors.primary

        // TOOL-B: clicking outside the selection does nothing (spec 0017 step 4).
        let clip = context.paintClipMask
        if let clip, clip.coverage(x: seed.x, y: seed.y) == 0 { return }

        let coverage: PaintBucketFill.FillCoverage
        if options.fillMode == .selection {
            // Fill = Selection ignores tolerance, flood mode, sampling, and Antialiasing
            // (the selection carries its own AA edge).
            coverage = PaintBucketFill.selectionCoverage(clip: clip, canvasSize: size)
        } else {
            // Paint.NET: "The keyboard shortcut to enable Global fill mode is the Shift
            // key" — for that click only (0016's helper).
            let effectiveFloodMode = FloodToolOptions.effectiveFloodMode(
                stored: options.floodMode, modifiers: event.modifiers)
            guard let region = PaintBucketFill.region(for: options,
                                                      effectiveFloodMode: effectiveFloodMode,
                                                      image: image, seed: seed,
                                                      selection: context.selection)
            else { return }
            coverage = PaintBucketFill.coverage(region: region, canvasSize: size,
                                                antialiasing: options.antialiasing)
        }

        // One history step (AGENTS rule 2): the COW snapshot before the writes, the
        // writes through `updateImage`, and a `TileDiff` over the touched tiles only
        // (NF-4). The fill writes the active layer whatever its visibility (0009).
        let layerID = image.layers[image.activeLayerIndex].id
        let before = image.layers[image.activeLayerIndex].surface
        var touched = Set<TileCoordinate>()
        context.updateImage { live in
            guard let index = live.layerIndex(for: layerID) else { return }
            touched = PaintBucketFill.apply(coverage, clip: clip, color: color,
                                            blendMode: options.blendMode,
                                            to: &live.layers[index].surface)
        }
        guard let index = context.image.layerIndex(for: layerID) else { return }
        let diff = TileDiff.between(before: before,
                                    after: context.image.layers[index].surface,
                                    layerID: layerID, candidates: touched)
        context.commitHistory(TileDiffHistoryItem(name: "Paint Bucket", icon: .paintBucket,
                                                 diff: diff))
    }

    /// A drag after the click changes nothing; one click = one step.
    func mouseDragged(_ event: ToolEvent, context: any ToolContext) {}

    func mouseUp(_ event: ToolEvent, context: any ToolContext) {}

    /// The fill commits on the click (D-42): nothing is ever pending, so the protocol
    /// defaults (`hasPendingEdit == false`, no-op `commit`/`cancel`, and `keyDown` that
    /// consumes nothing) are exactly Paint.NET's behavior for the bucket.
    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor {
        location == nil ? .arrow : .crosshair
    }
}
