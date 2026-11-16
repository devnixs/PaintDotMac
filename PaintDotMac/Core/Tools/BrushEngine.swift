import CoreGraphics
import Foundation

// MARK: - Options

/// The brush tools' shared options (spec 0009; 0011's Eraser and Pencil reuse this value
/// type and key layout with their own `ToolID` prefix). All arithmetic in `Double`/`Int`.
struct BrushOptions: Equatable, Sendable {
    /// Paint.NET's Brush Size range; sub-integer widths are honoured when antialiased.
    static let widthRange: ClosedRange<Double> = 1.0 ... 2000.0
    static let hardnessRange: ClosedRange<Int> = 0 ... 100
    /// Paint.NET's Paintbrush defaults (spec 0009 *Acceptance*).
    static let `default` = BrushOptions(width: 2, hardness: 75, antialiasing: true,
                                        blendMode: .normal)

    var width: Double
    /// 0…100; ignored when `antialiasing` is off (Paint.NET).
    var hardness: Int
    var antialiasing: Bool
    /// D-15: the list grows with the implemented layer modes (0026/0027/0059).
    var blendMode: BlendMode

    /// Width clamped into `widthRange` (a non-finite width falls back to the default 2),
    /// hardness into `hardnessRange`.
    func clamped() -> BrushOptions {
        BrushOptions(
            width: width.isFinite ? Swift.min(Swift.max(width, Self.widthRange.lowerBound),
                                              Self.widthRange.upperBound)
                                  : Self.default.width,
            hardness: Swift.min(Swift.max(hardness, Self.hardnessRange.lowerBound),
                                Self.hardnessRange.upperBound),
            antialiasing: antialiasing,
            blendMode: blendMode
        )
    }

    /// The four `tool.<tool>.*` keys (TOOL-C), parameterised by tool so 0011's Eraser gets
    /// `tool.eraser.*` from the same code. Reads clamp via the key sanitizers; an unknown
    /// blend-mode raw value reads as missing → `.normal`.
    static func keys(for tool: ToolID) -> (width: ToolOptionKey<Double>,
                                           hardness: ToolOptionKey<Int>,
                                           antialiasing: ToolOptionKey<Bool>,
                                           blendMode: ToolOptionKey<BlendMode>) {
        (
            ToolOptionKey(tool: tool, name: "width", defaultValue: `default`.width,
                          range: widthRange, nonFiniteFallback: `default`.width),
            ToolOptionKey(tool: tool, name: "hardness", defaultValue: `default`.hardness,
                          range: hardnessRange),
            ToolOptionKey(tool: tool, name: "antialiasing",
                          defaultValue: `default`.antialiasing),
            ToolOptionKey(tool: tool, name: "blendMode", defaultValue: `default`.blendMode)
        )
    }

    /// Reads and clamps (missing or wrong-typed storage yields the clamped default).
    @MainActor
    static func load(from store: any ToolOptionStore, tool: ToolID) -> BrushOptions {
        let keys = Self.keys(for: tool)
        return BrushOptions(width: store.value(keys.width),
                            hardness: store.value(keys.hardness),
                            antialiasing: store.value(keys.antialiasing),
                            blendMode: store.value(keys.blendMode)).clamped()
    }

    /// Persists the clamped values under the tool's keys.
    @MainActor
    func save(to store: any ToolOptionStore, tool: ToolID) {
        let value = clamped()
        let keys = Self.keys(for: tool)
        store.setValue(value.width, for: keys.width)
        store.setValue(value.hardness, for: keys.hardness)
        store.setValue(value.antialiasing, for: keys.antialiasing)
        store.setValue(value.blendMode, for: keys.blendMode)
    }
}

extension BlendMode: ToolOptionValue {}

private extension ToolOptionKey where Value == Double {
    /// The range sanitizer with a non-finite fallback (a corrupt stored `NaN` reads as the
    /// default width, not as a clamp boundary).
    init(tool: ToolID, name: String, defaultValue: Value, range: ClosedRange<Value>,
         nonFiniteFallback: Value) {
        self.init(tool: tool, name: name, defaultValue: defaultValue) { value in
            guard value.isFinite else { return nonFiniteFallback }
            return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
        }
    }
}

// MARK: - Clip hook

/// The selection clip for painting tools (spec 0009; 0013 conforms `SelectionMask` to it
/// and passes it through `ToolContext.paintClipMask`). Pixels outside `bounds` have
/// coverage 0.
protocol BrushClipMask: Sendable {
    var bounds: PixelRect { get }
    func coverage(x: Int, y: Int) -> UInt8
}

// MARK: - Coverage buffer

/// The stroke's per-pixel coverage (spec 0009), stored as one dictionary per touched
/// canvas row. The band sweep feeds each row's pixels left→right contiguously and never
/// revisits a row for the same segment, so `raise` appends without searching — O(1) — and
/// a pixel's value is only ever raised (max), which is what keeps one stroke from
/// self-darkening. `touchedTiles` tracks the 256×256 tiles any raised pixel lives in (the
/// `makeTileDiff` candidates).
struct StrokeCoverageBuffer: Sendable {
    private var rows: [Int: [Int: UInt8]] = [:]
    private(set) var touchedTiles: Set<TileCoordinate> = []

    init() {}

    /// Stores `max(old, value)` for one pixel; true when it increased. The nested
    /// subscript updates the row dictionary in place (a read-modify-write on uniquely
    /// owned storage) — binding `rows[y]` to a local first would COW-copy the whole row
    /// on every pixel, quadratic in the row's width.
    mutating func raise(x: Int, y: Int, to value: UInt8) -> Bool {
        guard value > 0 else { return false }
        guard value > (rows[y]?[x] ?? 0) else { return false }
        rows[y, default: [:]][x] = value
        touchedTiles.insert(TileCoordinate(column: x >> 8, row: y >> 8))
        return true
    }

    func coverage(x: Int, y: Int) -> UInt8 {
        rows[y]?[x] ?? 0
    }

    mutating func removeAll() {
        rows.removeAll()
        touchedTiles.removeAll()
    }
}

// MARK: - Stroke

/// The per-pixel compose rule: given the pixel's **before-stroke** value and its effective
/// (clipped, 1…255) coverage, the new layer pixel. The Paintbrush passes the BlendOps rule;
/// 0011's Eraser passes `EraseOps.erase(…)`, its Pencil the BlendOps rule with `mark`.
typealias BrushCompose = @Sendable (_ before: ColorRGBA8, _ coverage: UInt8) -> ColorRGBA8

/// One in-progress stroke (spec 0009): a value type owned by the tool, everything —
/// options, color, clip mask, compose rule — captured at mouse-down and fixed for the
/// stroke. The segment sweep (D-38: continuous, no Spacing) gives a pixel `profile(d)` for
/// `d` = distance from the pixel center to the closed segment; the layer pixel is always
/// recomputed from the before-stroke value, so one stroke never self-darkens while separate
/// strokes accumulate.
struct BrushStroke {
    let canvasSize: PixelSize
    let options: BrushOptions
    let clipMask: (any BrushClipMask)?
    let compose: BrushCompose

    /// The free copy-on-write snapshot taken at `begin`; its tiles are shared until the
    /// stroke writes one.
    private var before = TiledSurface(size: PixelSize(width: 1, height: 1))
    private var hasBegun = false
    private var lastPoint: CGPoint?
    private var buffer = StrokeCoverageBuffer()
    /// The union of all tiles any `begin`/`extend` call dirtied; `mark` does not join it
    /// (0011's Pencil commits through the same `makeTileDiff` path).
    private var sweptTiles: Set<TileCoordinate> = []

    /// The tiles the stroke wrote (the `makeTileDiff` candidates).
    var touchedTiles: Set<TileCoordinate> { buffer.touchedTiles }

    /// Snapshots `surface` and stamps one dab (the degenerate segment p→p).
    /// Non-finite points are ignored (nil).
    mutating func begin(at point: CGPoint, on surface: inout TiledSurface) -> PixelRect? {
        beginSnapshot(of: surface)
        hasBegun = true
        guard point.x.isFinite, point.y.isFinite else { return nil }
        lastPoint = point
        return sweep(from: point, to: point, on: &surface)
    }

    /// Sweeps `lastPoint → point`; a non-finite point is ignored (nil, `lastPoint` kept).
    mutating func extend(to point: CGPoint, on surface: inout TiledSurface) -> PixelRect? {
        guard hasBegun else { return begin(at: point, on: &surface) }
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let from = lastPoint ?? point
        lastPoint = point
        return sweep(from: from, to: point, on: &surface)
    }

    /// Raises one pixel's stroke coverage directly and composes it like a swept pixel
    /// (0011's Pencil passes 255). Out-of-canvas → no-op false. True when the pixel's
    /// stroke coverage increased (compose ran at most once for the increase).
    @discardableResult
    mutating func mark(x: Int, y: Int, coverage: UInt8, on surface: inout TiledSurface) -> Bool {
        guard hasBegun, canvasSize.bounds.contains(PixelPoint(x: x, y: y)) else { return false }
        guard buffer.raise(x: x, y: y, to: coverage) else { return false }
        writePixel(x: x, y: y, to: &surface)
        return true
    }

    /// Restores every touched tile from the before-snapshot: the surface becomes
    /// pixel-identical to its state before `begin`, absent tiles absent again.
    mutating func cancel(on surface: inout TiledSurface) {
        for coordinate in buffer.touchedTiles {
            surface.setTile(before.tile(at: coordinate), at: coordinate)
        }
        buffer.removeAll()
        sweptTiles.removeAll()
        lastPoint = nil
    }

    /// The tiles dirtied since the last call, as an image-space rect for 0003's redraw
    /// (`changedTiles(since:)` does the actual tile selection); nil when nothing was
    /// written. Reset per call, so it covers exactly this event.
    mutating func takeChangedRect() -> PixelRect? {
        defer { sweptTiles.removeAll() }
        guard let first = sweptTiles.min() else { return nil }
        var minColumn = first.column
        var maxColumn = first.column
        var minRow = first.row
        var maxRow = first.row
        for coordinate in sweptTiles {
            minColumn = Swift.min(minColumn, coordinate.column)
            maxColumn = Swift.max(maxColumn, coordinate.column)
            minRow = Swift.min(minRow, coordinate.row)
            maxRow = Swift.max(maxRow, coordinate.row)
        }
        let tile = TiledSurface.tileSize
        return PixelRect(
            x: minColumn * tile, y: minRow * tile,
            width: (maxColumn - minColumn + 1) * tile,
            height: (maxRow - minRow + 1) * tile
        ).intersection(canvasSize.bounds)
    }

    /// 0008's capture pattern restricted to the tiles this stroke wrote; a touched tile
    /// whose content ends equal to its before content is not recorded (NF-4).
    func makeTileDiff(from surface: TiledSurface, layerID: Layer.ID) -> TileDiff {
        TileDiff.between(before: before, after: surface, layerID: layerID,
                         candidates: buffer.touchedTiles)
    }

    /// Snapshots so `before` shares no tile buffer with the live surface. A plain value
    /// copy shares every tile until a mutation touches it — then 0008's `sharesStorage`
    /// fast path in `TileDiff.between` would skip the stroke's tiles (undo would lose
    /// them). `cloneForStroke()` hands the stroke a fresh, uniquely-owned buffer per
    /// allocated tile (exact pixels, no sharing); absent tiles stay absent, so `cancel`
    /// restores absent-from-absent cheaply.
    private mutating func beginSnapshot(of surface: TiledSurface) {
        before = surface
    }

    // MARK: - Sweep

    /// Sweeps the closed segment `a→b`. Instead of a bounding-box scan (whose corners are
    /// outside the capsule — 4 M evaluations for a width-2000 dab that covers 3.1 M), each
    /// canvas row is intersected with the segment's capsule: a pixel has non-zero coverage
    /// exactly when `perp² < reach²` (distance to the supporting line within reach) AND
    /// `par ∈ [−slack, length + slack]` (`slack = √(reach² − perp²)`). The per-row
    /// x-window below is the row's y-distance bound crossed with the x-extent of the
    /// capsule — a safe superset of the coverage support — and the exact per-pixel
    /// distance test still gates every write, so the painted pixels are identical to the
    /// box scan while the corners are never visited.
    private mutating func sweep(from a: CGPoint, to b: CGPoint,
                                on surface: inout TiledSurface) -> PixelRect? {
        let strokeOptions = options.clamped()
        let antialiased = strokeOptions.antialiasing
        let start: CGPoint
        let end: CGPoint
        let radius: Double
        if antialiased {
            radius = strokeOptions.width / 2
            start = a
            end = b
        } else {
            let side = BrushEngine.aliasedWidth(strokeOptions.width)
            radius = Double(side) / 2
            start = BrushEngine.snappedCenter(a, width: Double(side))
            end = BrushEngine.snappedCenter(b, width: Double(side))
        }
        // A pixel center has non-zero coverage exactly where dist(C, segment) < reachC.
        // In the segment frame (parallel u along v, perpendicular w ⟂ v) coverage needs
        // `par ∈ [−slack, L + slack]` with `perp ≤ reachC`, where `slack` is the parallel
        // room left at that row's perpendicular distance (`slack² ≥ reachC² − perp²`).
        // A covered pixel's x lies within `reachC + 1` of `[min(Ax,Bx), max(Ax,Bx)]`
        // (within `reachC` of a segment point, whose x is inside the segment's
        // x-extent), so each row's column window is the segment x-extent widened by
        // `reachC + 1` — a safe superset of the support; the exact `distanceSquared`
        // test below gates every write. (Intersecting a projection band with endpoint
        // discs is NOT safe: a pixel beside the middle of a steep long segment sits in
        // neither disc but has real coverage.) Everything clamps to the canvas in
        // Double BEFORE the Int conversion, so points at ±1e9 cannot overflow.
        let vx = end.x - start.x
        let vy = end.y - start.y
        let lengthSquared = vx * vx + vy * vy
        guard (lengthSquared > 0 && lengthSquared.isFinite) || (vx == 0 && vy == 0),
              start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite
        else { return nil }
        let reachC = radius + 0.5
        let reachSq = reachC * reachC
        let canvasW = Double(canvasSize.width)
        let canvasH = Double(canvasSize.height)
        let firstRow = Swift.max(0, (Swift.min(start.y, end.y) - reachC - 1).rounded(.down))
        let lastRow = Swift.min(canvasH - 1, Swift.max(start.y, end.y) + reachC + 1)
        guard firstRow <= lastRow else { return nil }
        // A pixel center (cx, cy) has coverage > 0 exactly where the exact
        // `distanceSquared` test below passes; the row/column windows below only bound
        // the scan.
        let spread = reachC + 1
        let globalLeft = Swift.max(0.0, (Swift.min(start.x, end.x) - spread).rounded(.down))
        let globalRight = Swift.min(canvasW - 1,
                                    Swift.max(start.x, end.x) + spread)
        guard globalLeft <= globalRight else { return nil }
        var changed = false
        // Per-pixel profile constants (identical float math to `BrushEngine.coverage` —
        // reachC is that function's `R`): hoisted so the inner loop is one sqrt, one
        // divide, and the smoothstep.
        let aliasedReachSq = radius * radius
        let fullHardness = strokeOptions.hardness >= 100
        let softDenom = reachC * (1 - Double(strokeOptions.hardness) / 100)
        var row = Int(firstRow)
        let rowEnd = Int(lastRow.rounded(.down))

        while row <= rowEnd {
            let cy = Double(row) + 0.5
            // Row is within reach of the segment's y-extent?
            let dy = Swift.min(Swift.max(cy, Swift.min(start.y, end.y)), Swift.max(start.y, end.y)) - cy
            guard dy * dy < reachSq else { row += 1; continue }
            let rowLeft: Double
            let rowRight: Double
            if lengthSquared > 0 {
                rowLeft = globalLeft
                rowRight = globalRight
            } else {
                let dx = (reachSq - dy * dy).squareRoot()
                rowLeft = Swift.max(start.x - dx, globalLeft)
                rowRight = Swift.min(start.x + dx, globalRight)
            }
            var xi = Int((rowLeft - 0.5).rounded(.down))
            let xEnd = Int((rowRight + 0.5).rounded(.up))
            while xi <= xEnd {
                defer { xi += 1 }
                guard xi >= 0, xi < canvasSize.width else { continue }
                let center = CGPoint(x: Double(xi) + 0.5, y: cy)
                let dSquared = BrushEngine.distanceSquared(from: center, toSegment: start, end)
                let coverage: UInt8
                if antialiased {
                    guard dSquared < reachSq else { continue }
                    // Same float sequence as `BrushEngine.coverage(distance:options:)`
                    // with R = reachC: `edge`, then the hardness smoothstep.
                    let d = dSquared.squareRoot()
                    let edge = Swift.min(Swift.max(reachC - d, 0), 1)
                    if fullHardness {
                        coverage = UInt8(edge * 255 + 0.5)
                    } else {
                        let t = Swift.min(Swift.max((reachC - d) / softDenom, 0), 1)
                        coverage = UInt8(Swift.min(edge, t * t * (3 - 2 * t)) * 255 + 0.5)
                    }
                } else {
                    coverage = dSquared <= aliasedReachSq ? 255 : 0
                }
                guard coverage > 0 else { continue }
                guard buffer.raise(x: xi, y: row, to: coverage) else { continue }
                writePixel(x: xi, y: row, to: &surface)
                sweptTiles.insert(TileCoordinate(column: xi >> 8, row: row))
                changed = true
            }
            row += 1
        }
        return changed ? takeChangedRect() : nil
    }

    /// The pixel's final value: effective (clipped) coverage from the stroke buffer, the
    /// compose rule against the **before-stroke** pixel, and the write into the live
    /// surface. `effCov == 0` leaves the pixel exactly `before` and never calls `compose`.
    private func writePixel(x: Int, y: Int, to surface: inout TiledSurface) {
        let strokeCoverage = buffer.coverage(x: x, y: y)
        let effective: UInt8
        if let clipMask {
            effective = BlendOps.mul255(strokeCoverage, clipMask.coverage(x: x, y: y))
        } else {
            effective = strokeCoverage
        }
        guard effective > 0 else { return }
        let point = PixelPoint(x: x, y: y)
        let result = compose(before.pixel(at: point), effective)
        surface.setPixel(result, at: point)
    }
}

// MARK: - Pure helpers

/// The brush rasterizer's pure, separately-tested math (spec 0009).
enum BrushEngine {
    /// The antialiased dab profile (spec 0009 "Pixel model"): support radius
    /// `R = width / 2 + 0.5`, edge `e = clamp(R − d, 0, 1)` (one-pixel AA rim), and for
    /// hardness `h < 100` the smoothstep falloff
    /// `t = clamp((R − d) / (R · (1 − h)), 0, 1)`, `s = t²(3 − 2t)`;
    /// `cov = trunc(min(e, s) · 255 + 0.5)` — `UInt8(Double)` truncates and this
    /// toolchain is exact, so the oracle uses the same conversion. Non-increasing in
    /// `d`, so max-over-segments = profile(min distance). Hardness applies only when
    /// antialiased; coverage is 0 at `d ≥ R`.
    static func coverage(distance d: Double, options: BrushOptions) -> UInt8 {
        let options = options.clamped()
        let radius = options.width / 2 + 0.5
        guard d < radius else { return 0 }
        let edge = Swift.min(Swift.max(radius - d, 0), 1)
        let softness: Double
        if options.hardness >= 100 {
            softness = 1
        } else {
            let h = Double(options.hardness) / 100
            let t = Swift.min(Swift.max((radius - d) / (radius * (1 - h)), 0), 1)
            softness = t * t * (3 - 2 * t)
        }
        return UInt8(Swift.min(edge, softness) * 255 + 0.5)
    }

    /// Squared distance from `point` to the closed segment `a→b` — the aliased mode's
    /// `d² ≤ r²` test without a `sqrt`.
    static func distanceSquared(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let vx = b.x - a.x
        let vy = b.y - a.y
        let lengthSquared = vx * vx + vy * vy
        guard lengthSquared > 0 else {
            let dx = point.x - a.x, dy = point.y - a.y
            return dx * dx + dy * dy
        }
        let t = Swift.min(Swift.max(((point.x - a.x) * vx + (point.y - a.y) * vy) / lengthSquared,
                                    0), 1)
        let dx = point.x - (a.x + t * vx), dy = point.y - (a.y + t * vy)
        return dx * dx + dy * dy
    }

    /// Euclidean distance from `point` to the closed segment `a→b` (`a == b` → distance to
    /// the point). `t = clamp(((P−A)·(B−A)) / |B−A|², 0, 1)`.
    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        distanceSquared(from: point, toSegment: a, b).squareRoot()
    }

    /// The aliased brush's integral side: `max(1, round(width))`, halves away from zero
    /// (2.5 → 3, 2.4 → 2). Clamps a non-finite width to the default 2 first.
    static func aliasedWidth(_ width: Double) -> Int {
        let clamped = width.isFinite
            ? Swift.min(Swift.max(width, BrushOptions.widthRange.lowerBound),
                        BrushOptions.widthRange.upperBound)
            : BrushOptions.default.width
        return Swift.max(1, Int(clamped.rounded()))
    }

    /// The aliased mode's center snap: odd width → the pixel center
    /// `(floor(x)+0.5, floor(y)+0.5)`; even width → the nearest pixel corner
    /// `(floor(x+0.5), floor(y+0.5))`.
    static func snappedCenter(_ point: CGPoint, width: Double) -> CGPoint {
        let side = aliasedWidth(width)
        if side % 2 == 1 {
            return CGPoint(x: point.x.rounded(.down) + 0.5, y: point.y.rounded(.down) + 0.5)
        }
        return CGPoint(x: (point.x + 0.5).rounded(.down), y: (point.y + 0.5).rounded(.down))
    }
}

// MARK: - Width stepping

/// Tools whose brush width `[`/`]` steps (spec 0009; the Paintbrush now, 0011's Eraser and
/// Pencil later). The router calls it behind `ToolShortcutGate`.
@MainActor
protocol BrushWidthAdjustable: AnyObject {
    /// `width = clamp(width + delta, 1…2000)`, persisted through `context.options`; a
    /// change during a stroke applies to the next stroke only.
    func adjustBrushWidth(by delta: Double, context: any ToolContext)
}
