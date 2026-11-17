import CoreGraphics
import Foundation

// The Gradient (spec 0023; PRD T-10, TOOL-A, TOOL-B, D-15, D-17, D-33, D-50). The type and
// mode option values, the pure renderer math, and the tile-walking render — the deterministic
// CPU reference (PRD §4) the 0024 Metal parity will be checked against.

// MARK: - Option values

/// The five gradient types of PRD T-10, in Paint.NET's Gradient Tool window order. The
/// Paint.NET spirals are out of scope (spec *Out of scope*).
enum GradientType: String, CaseIterable, Sendable {
    case linear
    case linearReflected
    case diamond
    case radial
    case conical

    /// Paint.NET's Gradient Tool labels.
    var displayName: String {
        switch self {
        case .linear: "Linear"
        case .linearReflected: "Linear (Reflected)"
        case .diamond: "Diamond"
        case .radial: "Radial"
        case .conical: "Conical"
        }
    }
}

extension GradientType: ToolOptionValue {}

/// Color Mode affects all four channels (Paint.NET's default gradient); Transparency Mode
/// affects only the alpha channel and never uses a blend mode (D-50c).
enum GradientMode: String, CaseIterable, Sendable {
    case color
    case transparency

    /// Paint.NET's Gradient Tool labels.
    var displayName: String {
        switch self {
        case .color: "Color Mode"
        case .transparency: "Transparency Mode"
        }
    }
}

extension GradientMode: ToolOptionValue {}

/// Everything one gradient render needs — a frozen value type so `render` is a pure function
/// of `(parameters, before, clip)`. Coordinates are canvas space (image pixels, `Double`,
/// top-left origin, y down).
struct GradientParameters: Sendable, Equatable {
    var type: GradientType
    var mode: GradientMode
    /// Gradient start, `t = 0`.
    var start: CGPoint
    /// Gradient end, `t = 1`.
    var end: CGPoint
    /// Color at `t = 0` (Transparency Mode: only `.alpha` is used).
    var startColor: ColorRGBA8
    /// Color at `t = 1` (Transparency Mode: only `.alpha` is used).
    var endColor: ColorRGBA8
    /// Antialiasing: softens the selection edge only — the gradient itself has no hard
    /// edges (D-50a).
    var antialiasing: Bool
    /// Blend mode (D-15); ignored in Transparency Mode.
    var blendMode: BlendMode

    /// `start == end`, or any coordinate non-finite: the gesture renders nothing.
    var isDegenerate: Bool {
        start == end || !start.x.isFinite || !start.y.isFinite || !end.x.isFinite || !end.y.isFinite
    }
}

// MARK: - Renderer

/// The pure gradient math (spec 0023 *Core*): per-type position, weight, per-channel
/// interpolation over straight sRGB (NF-9 — no gamma round-trip), and the tile-walking
/// render. All formulas are Paint.NET's documented GradientTool behavior evaluated in the
/// exact order the spec's hand-computed tests rely on.
enum GradientRenderer {
    /// Bounded gradient position `t ∈ [0, 1]` at canvas point (`x`, `y`), sampled at the
    /// pixel center. Precondition: the parameters are not degenerate (the caller guards;
    /// a zero-length handle line would divide by zero and yield NaN → weight 0, never a
    /// trap).
    static func position(_ type: GradientType, start: CGPoint, end: CGPoint,
                         x: Double, y: Double) -> Double {
        let px = x + 0.5
        let py = y + 0.5
        let dx = px - start.x
        let dy = py - start.y
        let vx = end.x - start.x
        let vy = end.y - start.y
        let l2 = vx * vx + vy * vy
        switch type {
        case .linear:
            return min(max((dx * vx + dy * vy) / l2, 0), 1)
        case .linearReflected:
            return min(max(abs((dx * vx + dy * vy) / l2), 0), 1)
        case .diamond:
            // L1 norm in the handle frame: a square rotated so one corner points at `end`.
            let u = abs(dx * (vx / l2) + dy * (vy / l2)) + abs(dx * (vy / l2) - dy * (vx / l2))
            return min(max(u, 0), 1)
        case .radial:
            return min(max(sqrt(dx * dx + dy * dy) / sqrt(l2), 0), 1)
        case .conical:
            // Symmetric about the handle ray: t = 0 toward `end`, 1 on the opposite ray,
            // so there is no seam. At the exact start pixel center atan2(0, 0) = 0 → P.
            var d = atan2(dy, dx) - atan2(vy, vx)
            if d > .pi { d -= 2 * .pi }
            if d < -.pi { d += 2 * .pi }
            return min(max(abs(d) / .pi, 0), 1)
        }
    }

    /// `floor(clamp(t, 0, 1)·255 + 0.5)`; NaN → 0 (a poisoned evaluation paints nothing).
    static func weight(_ t: Double) -> UInt8 {
        guard !t.isNaN else { return 0 }
        return UInt8((min(max(t, 0), 1) * 255 + 0.5).rounded(.down))
    }

    /// Straight per-channel interpolation `(a·(255 − w) + b·w + 127) / 255`, integer;
    /// `w = 0` → `a`, `w = 255` → `b` exactly.
    static func lerp(_ a: UInt8, _ b: UInt8, weight w: UInt8) -> UInt8 {
        UInt8((UInt32(a) * UInt32(255 - w) + UInt32(b) * UInt32(w) + 127) / 255)
    }

    /// All four channels.
    static func lerp(_ a: ColorRGBA8, _ b: ColorRGBA8, weight w: UInt8) -> ColorRGBA8 {
        ColorRGBA8(red: lerp(a.red, b.red, weight: w),
                   green: lerp(a.green, b.green, weight: w),
                   blue: lerp(a.blue, b.blue, weight: w),
                   alpha: lerp(a.alpha, b.alpha, weight: w))
    }

    /// Clip coverage after the antialiasing option (D-50a): on, the 8-bit antialiased mask
    /// is used as-is; off, a partial edge becomes hard at the 128 threshold.
    static func effectiveClip(_ c: UInt8, antialiasing: Bool) -> UInt8 {
        antialiasing ? c : (c >= 128 ? 255 : 0)
    }

    /// One output pixel from the before-pixel, at pixel (`x`, `y`) with effective clip
    /// coverage `c` (1…255; `c == 0` leaves the pixel unchanged either way).
    ///
    /// Color mode: the lerped color with its alpha scaled by the coverage, composited with
    /// the selected blend mode (D-15/D-17 — the tool behaves as if painted on a layer above).
    /// `Sa == 0` → `before` bit-for-bit (BlendOps' source-over rule).
    ///
    /// Transparency Mode (D-50c, Paint.NET): the lerped gradient alpha multiplies the
    /// existing alpha and the result is mixed in by the coverage; RGB is never changed,
    /// even when the alpha lands on 0 (D-33). No blend mode.
    static func composePixel(before: ColorRGBA8, x: Int, y: Int, clip c: UInt8,
                             parameters: GradientParameters) -> ColorRGBA8 {
        let t = position(parameters.type, start: parameters.start, end: parameters.end,
                         x: Double(x), y: Double(y))
        let w = weight(t)
        switch parameters.mode {
        case .color:
            let g = lerp(parameters.startColor, parameters.endColor, weight: w)
            let sa = BlendOps.mul255(g.alpha, c)
            return BlendOps.blend(parameters.blendMode, dst: before,
                                  src: ColorRGBA8(red: g.red, green: g.green, blue: g.blue,
                                                  alpha: sa))
        case .transparency:
            let ga = lerp(parameters.startColor.alpha, parameters.endColor.alpha, weight: w)
            let target = BlendOps.mul255(before.alpha, ga)
            let newAlpha = UInt8((UInt32(before.alpha) * UInt32(255 - c)
                                      + UInt32(target) * UInt32(c) + 127) / 255)
            return ColorRGBA8(red: before.red, green: before.green, blue: before.blue,
                              alpha: newAlpha)
        }
    }

    /// Start/end colors for a gesture (spec "Endpoint colors", D-50b: captured when the
    /// gesture starts, fixed for the pending gradient). Transparency Mode follows Paint.NET:
    /// from the Primary alpha to the *inverse* of the Secondary alpha; reversed swaps them.
    static func endpointColors(mode: GradientMode, primary: ColorRGBA8, secondary: ColorRGBA8,
                               reversed: Bool) -> (start: ColorRGBA8, end: ColorRGBA8) {
        switch mode {
        case .color:
            return reversed ? (secondary, primary) : (primary, secondary)
        case .transparency:
            let opaque = ColorRGBA8(red: 0, green: 0, blue: 0, alpha: primary.alpha)
            let transparent = ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255 - secondary.alpha)
            return reversed ? (transparent, opaque) : (opaque, transparent)
        }
    }

    /// Rewrites `surface` from `before` over the render region (canvas ∩ `clip.bounds`,
    /// whole canvas when `clip == nil`), one tile at a time, and returns the region tiles it
    /// visited (NF-4 diff candidates). Every output tile is a pure function of
    /// (`parameters`, `before`, `clip`): region tiles are composed from `before`'s tile
    /// (absent = all `.clear`) and tiles outside the region are set back to `before`'s tile,
    /// so unchanged and untouched tiles keep `before`'s storage (COW, no allocation —
    /// `Tile.sharesStorage(with:)` stays true). Degenerate parameters copy nothing and
    /// return `[]` (the caller restores `before`).
    static func render(_ parameters: GradientParameters, before: TiledSurface,
                       into surface: inout TiledSurface,
                       clip: (any BrushClipMask)?) -> Set<TileCoordinate> {
        guard !parameters.isDegenerate else { return [] }
        let region = clip.map { surface.bounds.intersection($0.bounds) } ?? surface.bounds
        let antialiasing = parameters.antialiasing
        var visited: Set<TileCoordinate> = []
        for row in 0..<surface.tileRows {
            for column in 0..<surface.tileColumns {
                let coordinate = TileCoordinate(column: column, row: row)
                let tileRect = surface.pixelRect(of: coordinate)
                let area = tileRect.intersection(region)
                let base = before.tile(at: coordinate)
                if area.isEmpty {
                    // Outside the region: `before`'s tile, unchanged (usually the identical
                    // buffer; the write keeps `render` a pure function of its inputs).
                    surface.setTile(base, at: coordinate)
                    continue
                }
                visited.insert(coordinate)
                // Lazily copied output tile: `nil` while every pixel still equals `before`.
                var out: Tile?
                for py in area.minY..<area.maxY {
                    for px in area.minX..<area.maxX {
                        let c = effectiveClip(clip?.coverage(x: px, y: py) ?? 255,
                                              antialiasing: antialiasing)
                        guard c != 0 else { continue }  // `before` pixel wins
                        let lx = px - tileRect.minX
                        let ly = py - tileRect.minY
                        let pixel = base?.pixel(x: lx, y: ly) ?? .clear
                        let composed = composePixel(before: pixel, x: px, y: py, clip: c,
                                                    parameters: parameters)
                        if composed != pixel {
                            if out == nil { out = base ?? Tile() }  // COW: copies once
                            out?.setPixel(composed, x: lx, y: ly)
                        }
                    }
                }
                surface.setTile(out ?? base, at: coordinate)
            }
        }
        return visited
    }
}
