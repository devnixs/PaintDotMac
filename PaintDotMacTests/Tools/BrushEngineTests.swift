import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// The brush rasterizer (spec 0009 *Test plan*). Every expected value is computed here by
/// hand or by the in-test `BrushOracle` — which re-implements the spec's formulas directly
/// (min distance to the polyline, the profile, the clip scale, the Paintbrush compose, the
/// Normal blend) — never by calling the engine.
struct BrushEngineTests {

    // MARK: - Test-target oracle

    /// The independent reference: straight re-read of the spec formulas.
    enum BrushOracle {
        static func profile(distance d: Double, width: Double, hardness: Int) -> UInt8 {
            let radius = width / 2 + 0.5
            guard d < radius else { return 0 }
            let edge = min(max(radius - d, 0), 1)
            let softness: Double
            if hardness >= 100 {
                softness = 1
            } else {
                let h = Double(hardness) / 100
                let t = min(max((radius - d) / (radius * (1 - h)), 0), 1)
                softness = t * t * (3 - 2 * t)
            }
            return UInt8(min(edge, softness) * 255 + 0.5)
        }

        static func snapped(_ p: CGPoint, width: Double, antialiased: Bool) -> CGPoint {
            guard !antialiased else { return p }
            let w = max(1, Int(width.rounded()))
            if w % 2 == 1 { return CGPoint(x: p.x.rounded(.down) + 0.5, y: p.y.rounded(.down) + 0.5) }
            return CGPoint(x: (p.x + 0.5).rounded(.down), y: (p.y + 0.5).rounded(.down))
        }

        static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
            let vx = b.x - a.x, vy = b.y - a.y
            let lengthSquared = vx * vx + vy * vy
            guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
            let t = min(max(((p.x - a.x) * vx + (p.y - a.y) * vy) / lengthSquared, 0), 1)
            return hypot(p.x - (a.x + t * vx), p.y - (a.y + t * vy))
        }

        /// Stroke coverage at a pixel center: profile(min distance) (antialiased) or the
        /// 0/255 disc test against the snapped polyline (aliased).
        static func strokeCoverage(x: Int, y: Int, points: [CGPoint],
                                   options: BrushOptions) -> UInt8 {
            let center = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
            guard points.count >= 2 else { return 0 }
            if options.antialiasing {
                var best = Double.infinity
                for index in 0..<(points.count - 1) {
                    best = min(best, distance(center, points[index], points[index + 1]))
                }
                return profile(distance: best, width: options.width, hardness: options.hardness)
            }
            let w = max(1, Int(options.width.rounded()))
            let radius = Double(w) / 2
            let snappedPoints = points.map { snapped($0, width: options.width, antialiased: false) }
            for index in 0..<(snappedPoints.count - 1) {
                let d = distance(center, snappedPoints[index], snappedPoints[index + 1])
                if d * d <= radius * radius { return 255 }
            }
            return 0
        }

        /// The final pixel: coverage → alpha, composed onto `before` with the exact
        /// integer Normal formula (re-derived here, not calling `BlendOps`).
        static func pixel(before: ColorRGBA8, x: Int, y: Int, points: [CGPoint],
                          color: ColorRGBA8, options: BrushOptions,
                          clip: ((Int, Int) -> UInt8)? = nil) -> ColorRGBA8 {
            var coverage = strokeCoverage(x: x, y: y, points: points, options: options)
            if let clip { coverage = mul255(coverage, clip(x, y)) }
            guard coverage > 0 else { return before }
            let sa = UInt32(mul255(color.alpha, coverage))
            guard sa > 0 else { return before }
            let da = UInt32(before.alpha)
            let fa = sa * 255 + da * (255 - sa)
            let outA = UInt8((fa + 127) / 255)
            func channel(_ sc: UInt8, _ dc: UInt8) -> UInt8 {
                UInt8((UInt32(sc) * sa * 255 + UInt32(dc) * da * (255 - sa) + fa / 2) / fa)
            }
            return ColorRGBA8(red: channel(color.red, before.red),
                              green: channel(color.green, before.green),
                              blue: channel(color.blue, before.blue), alpha: outA)
        }

        static func mul255(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Int(a) * Int(b) + 127) / 255)
        }
    }

    /// Runs a stroke through the engine and returns the surface + the changed rect of the
    /// last call.
    private func paint(surface: inout TiledSurface, points: [CGPoint], color: ColorRGBA8,
                       options: BrushOptions, clip: (any BrushClipMask)? = nil) -> PixelRect? {
        var stroke = BrushStroke(
            canvasSize: surface.size, options: options, clipMask: clip,
            compose: PaintbrushTool.paintbrushCompose(color: color, blendMode: options.blendMode)
        )
        var result: PixelRect?
        if let first = points.first {
            result = stroke.begin(at: first, on: &surface)
            for point in points.dropFirst() {
                if let next = stroke.extend(to: point, on: &surface) {
                    result = result?.union(next) ?? next
                }
            }
        }
        return result
    }

    private func expectAgainstOracle(surface: TiledSurface, points: [CGPoint], color: ColorRGBA8,
                                     options: BrushOptions, background: ColorRGBA8,
                                     clip: ((Int, Int) -> UInt8)? = nil,
                                     _ comment: Comment = "",
                                     sourceLocation: SourceLocation = #_sourceLocation) {
        TestImages.expectPixels(surface, match: { x, y in
            BrushOracle.pixel(before: background, x: x, y: y, points: points,
                              color: color, options: options, clip: clip)
        }, comment, sourceLocation: sourceLocation)
    }

    private func options(width: Double, hardness: Int = 100, antialiasing: Bool = true,
                         blendMode: BlendMode = .normal) -> BrushOptions {
        BrushOptions(width: width, hardness: hardness, antialiasing: antialiasing,
                     blendMode: blendMode)
    }

    // MARK: - Coverage profile

    @Test func coverageProfileHandValues() {
        // width 10, hardness 100: R = 5.5; only the one-pixel edge ramp.
        #expect(BrushEngine.coverage(distance: 0, options: options(width: 10, hardness: 100)) == 255)
        #expect(BrushEngine.coverage(distance: 4.5, options: options(width: 10, hardness: 100)) == 255)
        #expect(BrushEngine.coverage(distance: 5, options: options(width: 10, hardness: 100)) == 128)
        #expect(BrushEngine.coverage(distance: 5.5, options: options(width: 10, hardness: 100)) == 0)

        // width 10, hardness 0: half coverage where the smoothstep cone passes 0.502,
        // i.e. t ≈ 0.5 → R − d = 3.0 → d = 2.55; the value at d = 2.75 is exactly 0.502
        // (t = 0.5455, s = 0.5025 → c·255 = 128.1).
        #expect(BrushEngine.coverage(distance: 0, options: options(width: 10, hardness: 0)) == 255)
        #expect(BrushEngine.coverage(distance: 2.75, options: options(width: 10, hardness: 0)) == 128)

        // width 10, hardness 50 (R·(1−h) = 2.75): d=3 → t=0.909… s=0.9752, e=1 → 249;
        // d=4 → t=0.5455 s=0.5671 → 145; d=5 → t=0.1818 s=0.0862 → 22.
        #expect(BrushEngine.coverage(distance: 3, options: options(width: 10, hardness: 50)) == 249)
        #expect(BrushEngine.coverage(distance: 4, options: options(width: 10, hardness: 50)) == 145)
        #expect(BrushEngine.coverage(distance: 5, options: options(width: 10, hardness: 50)) == 22)

        // width 10, hardness 75 (R·(1−h) = 1.375): d=4 → t=1 → 255;
        // d=5 → t=0.3636, s=0.3010, e=0.5 → 0.3010 → 77.
        #expect(BrushEngine.coverage(distance: 4, options: options(width: 10, hardness: 75)) == 255)
        #expect(BrushEngine.coverage(distance: 5, options: options(width: 10, hardness: 75)) == 77)

        // width 1: R = 1.0; the pixel-center diagonal √0.5 → e = s = 0.2929 → 75 at both
        // hardnesses (h=75: t = 0.2929/0.25 > 1 → s = e). d = 1 → outside the edge ramp.
        let sqrtHalf = 2.squareRoot() / 2
        #expect(BrushEngine.coverage(distance: sqrtHalf, options: options(width: 1, hardness: 75)) == 75)
        #expect(BrushEngine.coverage(distance: sqrtHalf, options: options(width: 1, hardness: 100)) == 75)
        #expect(BrushEngine.coverage(distance: 1, options: options(width: 1, hardness: 75)) == 0)
        #expect(BrushEngine.coverage(distance: 1, options: options(width: 1, hardness: 100)) == 0)

        // width 20, hardness 0 (R = 10.5, cone = R): d=1 → t=0.9048 s=0.9775 → 249;
        // d=11 ≥ R → 0.
        #expect(BrushEngine.coverage(distance: 1, options: options(width: 20, hardness: 0)) == 249)
        #expect(BrushEngine.coverage(distance: 11, options: options(width: 20, hardness: 0)) == 0)

        // The profile is non-increasing over [0, R+1] for a spread of widths × hardnesses.
        for width in [1.0, 2.0, 6.5, 50.0, 2000.0] {
            for hardness in [0, 25, 75, 100] {
                let options = options(width: width, hardness: hardness)
                let limit = width / 2 + 0.5 + 1
                var previous = UInt8.max
                var d = 0.0
                while d <= limit {
                    let value = BrushEngine.coverage(distance: d, options: options)
                    #expect(value <= previous, "width \(width) hardness \(hardness) at d=\(d)")
                    previous = value
                    d += 0.01
                }
            }
        }

        // The engine agrees with the independent oracle on a dense sweep.
        for width in [1.0, 2.0, 6.5, 50.0] {
            for hardness in [0, 25, 75, 100] {
                var d = 0.0
                while d <= width / 2 + 1.5 {
                    #expect(BrushEngine.coverage(distance: d, options: options(width: width, hardness: hardness))
                                == BrushOracle.profile(distance: d, width: width, hardness: hardness),
                            "oracle disagreement at width \(width) hardness \(hardness) d=\(d)")
                    d += 0.025
                }
            }
        }
    }

    @Test func singleDabMatchesProfile() {
        var surface = TestImages.surface(width: 100, height: 100) { _, _ in .clear }
        let changed = paint(surface: &surface, points: [CGPoint(x: 50.5, y: 50.5)],
                            color: .black, options: options(width: 10, hardness: 100))
        #expect(surface.pixel(at: PixelPoint(x: 50, y: 50)) == ColorRGBA8.black)
        let edge = surface.pixel(at: PixelPoint(x: 55, y: 50))     // d = 5 → 128
        #expect(edge.alpha == 128 && edge.red == 0 && edge.green == 0 && edge.blue == 0)
        #expect(surface.tile(at: TileCoordinate(column: 0, row: 0))?.pixel(x: 56, y: 50) == .clear,
                "(56,50) reads transparent (d = 6 > R)")
        #expect(surface.pixel(at: PixelPoint(x: 54, y: 50)).alpha == 255)  // d = 3.5
        if let changed {
            #expect(PixelRect(x: 44, y: 44, width: 13, height: 13).contains(changed),
                    "changed rect \(changed) ⊆ (44…56)")
        } else {
            Issue.record("the dab changed nothing")
        }
    }

    // MARK: - Aliased dabs

    @Test func aliasedDabShapes() {
        func check(width: Double, at point: CGPoint, expect expected: Set<PixelPoint>) {
            var surface = TestImages.surface(width: 32, height: 32) { _, _ in .clear }
            paint(surface: &surface, points: [point], color: .black,
                  options: options(width: width, hardness: 50, antialiasing: false))
            var painted: Set<PixelPoint> = []
            for y in 0..<32 {
                for x in 0..<32 {
                    let color = surface.pixel(at: PixelPoint(x: x, y: y))
                    if color == .black {
                        painted.insert(PixelPoint(x: x, y: y))
                    } else {
                        #expect(color == .clear, "unexpected \(color) at (\(x), \(y)) width \(width)")
                    }
                }
            }
            #expect(painted == expected, "width \(width) at \(point)")
        }
        func block(_ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>) -> Set<PixelPoint> {
            Set((xs.lowerBound...xs.upperBound).flatMap { x in
                (ys.lowerBound...ys.upperBound).map { PixelPoint(x: x, y: $0) } })
        }
        check(width: 1, at: CGPoint(x: 10.3, y: 20.9), expect: [PixelPoint(x: 10, y: 20)])
        check(width: 2, at: CGPoint(x: 10.4, y: 20.6),
              expect: [PixelPoint(x: 9, y: 20), PixelPoint(x: 10, y: 20),
                       PixelPoint(x: 9, y: 21), PixelPoint(x: 10, y: 21)])
        check(width: 3, at: CGPoint(x: 5.2, y: 5.7), expect: block(4...6, 4...6))
        check(width: 4, at: CGPoint(x: 10.0, y: 10.0),
              expect: block(8...11, 8...11).subtracting([
                  PixelPoint(x: 8, y: 8), PixelPoint(x: 11, y: 8),
                  PixelPoint(x: 8, y: 11), PixelPoint(x: 11, y: 11),
              ]))
        check(width: 2.5, at: CGPoint(x: 5.2, y: 5.7), expect: block(4...6, 4...6))
        check(width: 2.4, at: CGPoint(x: 10.4, y: 20.6),
              expect: [PixelPoint(x: 9, y: 20), PixelPoint(x: 10, y: 20),
                       PixelPoint(x: 9, y: 21), PixelPoint(x: 10, y: 21)])
    }

    @Test func aliasedIgnoresHardness() {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0A11AE22))
        let points = (0..<5).map { _ in
            CGPoint(x: rng.double(in: 2...30), y: rng.double(in: 2...30))
        }
        var soft = TestImages.surface(width: 32, height: 32) { _, _ in .clear }
        var hard = TestImages.surface(width: 32, height: 32) { _, _ in .clear }
        paint(surface: &soft, points: points, color: .black,
              options: options(width: 7, hardness: 0, antialiasing: false))
        paint(surface: &hard, points: points, color: .black,
              options: options(width: 7, hardness: 100, antialiasing: false))
        #expect(soft == hard, rng.comment)
    }

    // MARK: - Segments

    @Test func horizontalSegmentHandValues() {
        var surface = TestImages.surface(width: 100, height: 100) { _, _ in .clear }
        paint(surface: &surface,
              points: [CGPoint(x: 10, y: 50.5), CGPoint(x: 90, y: 50.5)],
              color: .black, options: options(width: 10, hardness: 100))
        for x in 10...89 {
            #expect(surface.pixel(at: PixelPoint(x: x, y: 50)).alpha == 255, "row (x=\(x), 50)")
        }
        #expect(surface.pixel(at: PixelPoint(x: 50, y: 45)).alpha == 128)  // d = 5
        #expect(surface.pixel(at: PixelPoint(x: 50, y: 55)).alpha == 128)
        #expect(surface.pixel(at: PixelPoint(x: 50, y: 44)) == .clear)     // d = 6
        #expect(surface.pixel(at: PixelPoint(x: 50, y: 56)) == .clear)
        // Round caps at both ends.
        #expect(surface.pixel(at: PixelPoint(x: 5, y: 50)).alpha == 255)   // d = 4.5 to (10, 50.5)
        #expect(surface.pixel(at: PixelPoint(x: 4, y: 50)) == .clear)      // d = 5.5 → 0
        #expect(surface.pixel(at: PixelPoint(x: 94, y: 50)).alpha == 255)  // center 94.5, d = 4.5
        #expect(surface.pixel(at: PixelPoint(x: 95, y: 50)) == .clear)     // d = 5.5 → 0
        // Full agreement with the independent oracle over the whole canvas.
        expectAgainstOracle(surface: surface,
                            points: [CGPoint(x: 10, y: 50.5), CGPoint(x: 90, y: 50.5)],
                            color: .black, options: options(width: 10, hardness: 100),
                            background: .clear, "horizontal segment vs oracle")
    }

    // MARK: - Overlap semantics

    @Test func selfOverlapDoesNotDarken() {
        // White dst, black @128 one-pass value: fa=65025, C=(0+255·255·127+32512)/65025=127.
        let onePass = ColorRGBA8(red: 127, green: 127, blue: 127, alpha: 255)
        var surface = TestImages.surface(width: 64, height: 64) { _, _ in .white }
        paint(surface: &surface,
              points: [CGPoint(x: 5.5, y: 32.5), CGPoint(x: 58.5, y: 32.5), CGPoint(x: 5.5, y: 32.5)],
              color: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 128),
              options: options(width: 8, hardness: 100))
        #expect(surface.pixel(at: PixelPoint(x: 32, y: 32)) == onePass, "back-and-forth stroke")

        var crossing = TestImages.surface(width: 64, height: 64) { _, _ in .white }
        paint(surface: &crossing,
              points: [CGPoint(x: 8, y: 8), CGPoint(x: 56, y: 56),
                       CGPoint(x: 8, y: 56), CGPoint(x: 56, y: 8)],
              color: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 128),
              options: options(width: 8, hardness: 100))
        #expect(crossing.pixel(at: PixelPoint(x: 32, y: 32)) == onePass, "X-shaped single stroke")
    }

    @Test func secondStrokeAccumulates() {
        // Second pass over (127,127,127,255) with black @128:
        // C = (0 + 127·255·127 + 32512)/65025 = 63.
        var surface = TestImages.surface(width: 64, height: 64) { _, _ in .white }
        let points = [CGPoint(x: 5.5, y: 32.5), CGPoint(x: 58.5, y: 32.5)]
        let color = ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 128)
        paint(surface: &surface, points: points, color: color,
              options: options(width: 8, hardness: 100))
        #expect(surface.pixel(at: PixelPoint(x: 32, y: 32))
                    == ColorRGBA8(red: 127, green: 127, blue: 127, alpha: 255))
        paint(surface: &surface, points: points, color: color,
              options: options(width: 8, hardness: 100))
        #expect(surface.pixel(at: PixelPoint(x: 32, y: 32))
                    == ColorRGBA8(red: 63, green: 63, blue: 63, alpha: 255))
    }

    @Test func crossesTileBoundaryWithoutSeams() {
        let background = ColorRGBA8(red: 200, green: 120, blue: 40, alpha: 120)
        var surface = TestImages.surface(width: 600, height: 600) { _, _ in background }
        let points = [CGPoint(x: 200.3, y: 100.7), CGPoint(x: 311.9, y: 300.2),
                      CGPoint(x: 250, y: 520)]
        let color = ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 200)
        let brushOptions = options(width: 31, hardness: 60)
        var stroke = BrushStroke(
            canvasSize: surface.size, options: brushOptions, clipMask: nil,
            compose: PaintbrushTool.paintbrushCompose(color: color, blendMode: .normal)
        )
        stroke.begin(at: points[0], on: &surface)
        for point in points.dropFirst() { stroke.extend(to: point, on: &surface) }

        expectAgainstOracle(surface: surface, points: points, color: color,
                            options: brushOptions, background: background,
                            "cross-tile stroke vs min-distance oracle")
        // The diff candidates that differ are exactly the tiles containing a changed pixel.
        let before = TestImages.surface(width: 600, height: 600) { _, _ in background }
        let diff = stroke.makeTileDiff(from: surface, layerID: UUID())
        let inDiff = Set(diff.entries.map(\.coordinate))
        var changed: Set<TileCoordinate> = []
        for y in 0..<600 {
            for x in 0..<600 {
                if surface.pixel(at: PixelPoint(x: x, y: y)) != before.pixel(at: PixelPoint(x: x, y: y)) {
                    changed.insert(TileCoordinate(column: x / 256, row: y / 256))
                }
            }
        }
        #expect(inDiff == changed, "diff tiles must equal changed-pixel tiles")
    }

    // MARK: - Clip mask

    private struct TestClipMask: BrushClipMask {
        let bounds: PixelRect
        func coverage(x: Int, y: Int) -> UInt8 {
            guard bounds.contains(PixelPoint(x: x, y: y)) else { return 0 }
            if x < 18 { return 255 }
            if x == 18 { return 128 }
            return 0
        }
    }

    @Test func clipMaskScalesCoverage() {
        var surface = TestImages.surface(width: 40, height: 20) { _, _ in .white }
        let mask = TestClipMask(bounds: PixelSize(width: 40, height: 20).bounds)
        let changed = paint(surface: &surface,
                            points: [CGPoint(x: 2.5, y: 10.5), CGPoint(x: 37.5, y: 10.5)],
                            color: .black, options: options(width: 6, hardness: 100), clip: mask)
        _ = changed
        #expect(surface.pixel(at: PixelPoint(x: 10, y: 10)) == ColorRGBA8.black)
        // (18,10): strokeCov 255 × clip 128 → effCov 128 → Sa 128 over opaque white → 127.
        #expect(surface.pixel(at: PixelPoint(x: 18, y: 10))
                    == ColorRGBA8(red: 127, green: 127, blue: 127, alpha: 255))
        for x in 19...39 {
            #expect(surface.pixel(at: PixelPoint(x: x, y: 10)) == .white, "x=\(x) stays white")
        }

        // A mask whose bounds exclude the stroke paints nothing.
        var untouched = TestImages.surface(width: 40, height: 20) { _, _ in .white }
        struct OutsideMask: BrushClipMask {
            var bounds: PixelRect { PixelRect(x: 0, y: 0, width: 0, height: 0) }
            func coverage(x: Int, y: Int) -> UInt8 { 0 }
        }
        var stroke = BrushStroke(
            canvasSize: untouched.size, options: options(width: 6, hardness: 100),
            clipMask: OutsideMask(),
            compose: PaintbrushTool.paintbrushCompose(color: .black, blendMode: .normal)
        )
        stroke.begin(at: CGPoint(x: 2.5, y: 10.5), on: &untouched)
        #expect(stroke.makeTileDiff(from: untouched, layerID: UUID()).isEmpty)
    }

    // MARK: - Edge cases

    @Test func offCanvasAndNonFinitePointsAreSafe() {
        var surface = TestImages.surface(width: 50, height: 50) { _, _ in .clear }
        #expect(paint(surface: &surface,
                      points: [CGPoint(x: -1e9, y: -1e9), CGPoint(x: -1e9, y: 1e9)],
                      color: .black, options: options(width: 10)) == nil)
        let generationAfterOffCanvas = surface.generation
        #expect(surface.generation == generationAfterOffCanvas)
        TestImages.expectPixels(surface, match: { _, _ in .clear }, "far-off-canvas stroke")

        // A stroke that starts off-canvas paints only its in-bounds part.
        let points = [CGPoint(x: -20, y: 25.5), CGPoint(x: 70, y: 25.5)]
        paint(surface: &surface, points: points, color: .black,
              options: options(width: 10, hardness: 100))
        expectAgainstOracle(surface: surface, points: points, color: .black,
                            options: options(width: 10, hardness: 100), background: .clear,
                            "clipped horizontal stroke")

        // A NaN point is ignored: the surface equals the run without it.
        var withNaN = TestImages.surface(width: 50, height: 50) { _, _ in .clear }
        let pointsWithNaN = [CGPoint(x: 10, y: 25.5),
                             CGPoint(x: Double.nan, y: 25.5),
                             CGPoint(x: 40, y: 25.5)]
        paint(surface: &withNaN, points: pointsWithNaN, color: .black,
              options: options(width: 10, hardness: 100))
        var withoutNaN = TestImages.surface(width: 50, height: 50) { _, _ in .clear }
        paint(surface: &withoutNaN,
              points: [CGPoint(x: 10, y: 25.5), CGPoint(x: 40, y: 25.5)],
              color: .black, options: options(width: 10, hardness: 100))
        #expect(withNaN == withoutNaN, "NaN point ignored")
    }

    @Test func oneByOneImage() {
        var surface = TestImages.surface(width: 1, height: 1) { _, _ in .clear }
        #expect(paint(surface: &surface, points: [CGPoint(x: 0.5, y: 0.5)], color: .black,
                      options: options(width: 1)) != nil)
        #expect(surface.pixel(at: .zero) == ColorRGBA8.black)
        var elsewhere = TestImages.surface(width: 1, height: 1) { _, _ in .clear }
        #expect(paint(surface: &elsewhere, points: [CGPoint(x: 5, y: 5)], color: .black,
                      options: options(width: 1)) == nil)
        #expect(elsewhere.pixel(at: .zero) == .clear)
    }

    @Test func zeroAlphaColorChangesNothing() {
        var surface = TestImages.surface(width: 40, height: 40) { _, _ in .white }
        let generation = surface.generation
        var stroke = BrushStroke(
            canvasSize: surface.size, options: options(width: 10), clipMask: nil,
            compose: PaintbrushTool.paintbrushCompose(color: ColorRGBA8(red: 255, green: 0,
                                                                         blue: 0, alpha: 0),
                                                      blendMode: .normal)
        )
        stroke.begin(at: CGPoint(x: 20, y: 20), on: &surface)
        stroke.extend(to: CGPoint(x: 30, y: 20), on: &surface)
        TestImages.expectPixels(surface, match: { _, _ in .white }, "alpha-0 color paints nothing")
        #expect(surface.generation == generation,
                "a stroke whose compose returns the before value writes nothing at all")
        #expect(stroke.makeTileDiff(from: surface, layerID: UUID()).isEmpty)
    }

    // MARK: - Compose contract and mark

    @Test func customComposeReceivesBeforeAndCoverage() {
        final class Recorder: @unchecked Sendable {
            struct Call { let before: ColorRGBA8; let coverage: UInt8 }
            private let lock = NSLock()
            private var storage: [Call] = []
            var calls: [Call] {
                get { lock.lock(); defer { lock.unlock() }; return storage }
                set { lock.lock(); storage = newValue; lock.unlock() }
            }
            func append(_ call: Call) { lock.lock(); storage.append(call); lock.unlock() }
        }
        let recorder = Recorder()
        let pre = ColorRGBA8(red: 9, green: 9, blue: 9, alpha: 9)
        var surface = TestImages.surface(width: 20, height: 20) { _, _ in pre }
        let point = CGPoint(x: 10.5, y: 10.5)
        var stroke = BrushStroke(canvasSize: surface.size,
                                 options: options(width: 10, hardness: 100), clipMask: nil,
                                 compose: { before, coverage in
            recorder.append(.init(before: before, coverage: coverage))
            return ColorRGBA8(red: coverage, green: 0, blue: 0, alpha: 255)
        })
        stroke.begin(at: point, on: &surface)
        stroke.extend(to: point, on: &surface)   // sweep back over the same dab
        #expect(!recorder.calls.isEmpty)
        #expect(recorder.calls.allSatisfy { $0.before == pre },
                "compose always sees the before-stroke pixel")
        #expect(recorder.calls.allSatisfy { $0.coverage > 0 }, "coverage-0 pixels never compose")
        #expect(surface.pixel(at: PixelPoint(x: 10, y: 10)) == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        #expect(surface.pixel(at: PixelPoint(x: 15, y: 10)) == ColorRGBA8(red: 128, green: 0, blue: 0, alpha: 255))
        // The AA rim composes at partial coverage and the core at full: the recorded
        // coverages span more than one value, all of them > 0.
        let coverages = Set(recorder.calls.map(\.coverage))
        #expect(coverages.count >= 2, "the edge ramp composes at partial coverage")
        #expect(coverages.contains(255), "the dab core composes at full coverage")
    }

    @Test func recomposeUsesBeforePixelWhenCoverageIncreasesMidStroke() {
        // A pixel first painted at partial coverage and later raised to full (a second
        // segment passing closer) recomposes from the BEFORE-stroke pixel — never from
        // the partially painted value. Hand-computed, black @128 over white, w 10 h 100:
        // coverage 128 → Sa 64 → (191,191,191,255); coverage 255 → Sa 128 → (127,127,127,255)
        // (the single-pass value). Recomposing from (191,…) would give (95,95,95,255).
        var surface = TestImages.surface(width: 20, height: 20) { _, _ in .white }
        var stroke = BrushStroke(canvasSize: surface.size,
                                 options: options(width: 10, hardness: 100), clipMask: nil,
                                 compose: PaintbrushTool.paintbrushCompose(
                                    color: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 128),
                                    blendMode: .normal))
        // Dab centred 5 px right of pixel (10,10)'s center → d = 5 → edge 0.5 → cov 128.
        stroke.begin(at: CGPoint(x: 15.5, y: 10.5), on: &surface)
        #expect(surface.pixel(at: PixelPoint(x: 10, y: 10))
                    == ColorRGBA8(red: 191, green: 191, blue: 191, alpha: 255),
                "partial pass at coverage 128")
        // Sweep to the pixel's center: its coverage raises to 255, forcing a recompose.
        stroke.extend(to: CGPoint(x: 10.5, y: 10.5), on: &surface)
        #expect(surface.pixel(at: PixelPoint(x: 10, y: 10))
                    == ColorRGBA8(red: 127, green: 127, blue: 127, alpha: 255),
                "recomposed from the before-stroke pixel, not the painted one")
    }

    @Test func markRaisesSinglePixel() {
        var surface = TestImages.surface(width: 20, height: 20) { _, _ in .white }
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var storage = 0
            var count: Int { lock.lock(); defer { lock.unlock() }; return storage }
            func bump() { lock.lock(); storage += 1; lock.unlock() }
        }
        let counter = Counter()
        var stroke = BrushStroke(canvasSize: surface.size,
                                 options: options(width: 4, hardness: 100), clipMask: nil,
                                 compose: { before, coverage in
            counter.bump()
            return PaintbrushTool.paintbrushCompose(color: .black, blendMode: .normal)(before, coverage)
        })
        stroke.begin(at: CGPoint(x: 100, y: 100), on: &surface)   // off-canvas begin paints nothing
        #expect(stroke.mark(x: 3, y: 4, coverage: 255, on: &surface))
        #expect(surface.pixel(at: PixelPoint(x: 3, y: 4)) == ColorRGBA8.black)
        let marksAfterFirst = counter.count
        #expect(!stroke.mark(x: 3, y: 4, coverage: 255, on: &surface), "second mark cannot raise")
        #expect(counter.count == marksAfterFirst, "a failed mark never composes")
        #expect(!stroke.mark(x: -1, y: 0, coverage: 255, on: &surface))
        #expect(!stroke.mark(x: 20, y: 0, coverage: 255, on: &surface))
        TestImages.expectPixels(surface, match: { x, y in
            (x == 3 && y == 4) ? .black : .white
        }, "only (3,4) painted")
    }

    // MARK: - Cancel and extremes

    @Test func cancelRestoresBitIdentical() {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0CA4CE1B))
        // A random opaque/semi-transparent 300×300 surface; rows ≥ 200 stay fully
        // transparent so absent tiles are involved.
        var surface = TestImages.surface(width: 300, height: 300) { x, y in
            guard x < 200 else { return .clear }
            let alpha = UInt8(rng.int(in: 0...1) * 255)
            return ColorRGBA8(red: rng.byte(), green: rng.byte(), blue: rng.byte(), alpha: alpha)
        }
        // Force some non-empty sparse tiles.
        surface.setPixel(ColorRGBA8(red: 7, green: 7, blue: 7, alpha: 7),
                         at: PixelPoint(x: 299, y: 299))
        let copy = surface
        var stroke = BrushStroke(canvasSize: surface.size,
                                 options: options(width: 60, hardness: 40), clipMask: nil,
                                 compose: PaintbrushTool.paintbrushCompose(color: .black,
                                                                           blendMode: .normal))
        stroke.begin(at: CGPoint(x: 30.5, y: 20.5), on: &surface)
        stroke.extend(to: CGPoint(x: 280.5, y: 290.5), on: &surface)
        stroke.extend(to: CGPoint(x: 200.5, y: 30.5), on: &surface)
        stroke.cancel(on: &surface)
        #expect(surface == copy, "cancel is pixel-identical, absent tiles absent \(rng.comment)")
    }

    @Test func width2000DabCompletes() throws {
        var surface = TestImages.surface(width: 4000, height: 3000) { _, _ in .white }
        let center = CGPoint(x: 2000.5, y: 1500.5)
        var stroke = BrushStroke(canvasSize: surface.size,
                                 options: options(width: 2000, hardness: 75), clipMask: nil,
                                 compose: PaintbrushTool.paintbrushCompose(color: .black,
                                                                           blendMode: .normal))
        stroke.begin(at: center, on: &surface)
        #expect(surface.pixel(at: PixelPoint(x: 2000, y: 1500)) == ColorRGBA8.black)
        #expect(surface.pixel(at: PixelPoint(x: 3001, y: 1500)) == .white,
                "pixel at d ≥ R unchanged")
        let diff = stroke.makeTileDiff(from: surface, layerID: UUID())
        #expect(!diff.isEmpty)
        // Undo the whole dab through the diff.
        diff.revert(to: &surface)
        #expect(surface.pixel(at: PixelPoint(x: 2000, y: 1500)) == .white)
    }
}

private extension TileDiff {
    /// Applies the `before` side (undo direction) — a thin local wrapper so the test can
    /// revert a surface without a full `LayeredImage`.
    func revert(to surface: inout TiledSurface) {
        for entry in entries { surface.setTile(entry.before, at: entry.coordinate) }
    }
}
