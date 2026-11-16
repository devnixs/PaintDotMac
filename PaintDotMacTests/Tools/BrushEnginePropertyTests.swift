import Foundation
import Testing

@testable import PaintDotMac

/// Property tests for the brush engine (spec 0009 *Test plan*): 200 seeded iterations each
/// against the in-test `StrokeOracle` (a direct re-read of the spec formulas — min distance
/// to the polyline, the profile, the clip scale, the Paintbrush compose, and the exact
/// integer Normal blend — never the engine).
@MainActor
struct BrushEnginePropertyTests {

    /// The independent reference (written from the spec text, not from `BrushEngine`).
    struct StrokeOracle {
        let width: Double
        let hardness: Int
        let antialiased: Bool
        let color: ColorRGBA8

        func coverage(x: Int, y: Int, snappedPoints: [CGPoint]) -> UInt8 {
            let center = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
            if antialiased {
                // Same profile as `BrushEngine.coverage` (spec formula): R = width/2 + 0.5,
                // one-pixel edge ramp, smoothstep hardness falloff.
                let radius = width / 2 + 0.5
                var d = Double.infinity
                for i in 0 ..< (snappedPoints.count - 1) {
                    d = min(d, Self.distance(center, snappedPoints[i], snappedPoints[i + 1]))
                }
                guard d < radius else { return 0 }
                let e = min(max(radius - d, 0), 1)
                var s = 1.0
                if hardness < 100 {
                    let h = Double(hardness) / 100
                    let t = min(max((radius - d) / (radius * (1 - h)), 0), 1)
                    s = t * t * (3 - 2 * t)
                }
                return UInt8(min(e, s) * 255 + 0.5)
            }
            let side = max(1, Int(width.rounded()))
            let radius = Double(side) / 2
            for i in 0 ..< (snappedPoints.count - 1) {
                let d = Self.distance(center, snappedPoints[i], snappedPoints[i + 1])
                if d * d <= radius * radius { return 255 }
            }
            return 0
        }

        /// The final pixel given the before value, the raw stroke coverage, and the clip.
        func compose(before: ColorRGBA8, rawCoverage: UInt8, clipCoverage: UInt8) -> ColorRGBA8 {
            let sa0 = Self.mul255(rawCoverage, clipCoverage)
            let sa = UInt32(Self.mul255(color.alpha, sa0))
            guard sa > 0 else { return before }
            let da = UInt32(before.alpha)
            let fa = sa * 255 + da * (255 - sa)
            func channel(_ sc: UInt8, _ dc: UInt8) -> UInt8 {
                UInt8((UInt32(sc) * sa * 255 + UInt32(dc) * da * (255 - sa) + fa / 2) / fa)
            }
            return ColorRGBA8(red: channel(color.red, before.red),
                              green: channel(color.green, before.green),
                              blue: channel(color.blue, before.blue),
                              alpha: UInt8((fa + 127) / 255))
        }

        static func snapped(_ p: CGPoint) -> CGPoint { p }

        static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
            let vx = b.x - a.x, vy = b.y - a.y
            let lengthSquared = vx * vx + vy * vy
            guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
            let t = min(max(((p.x - a.x) * vx + (p.y - a.y) * vy) / lengthSquared, 0), 1)
            return hypot(p.x - (a.x + t * vx), p.y - (a.y + t * vy))
        }

        static func mul255(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Int(a) * Int(b) + 127) / 255)
        }
    }

    /// The aliased mode's center snap, written from the spec text.
    private func aliasedSnap(_ p: CGPoint, width: Double) -> CGPoint {
        let side = max(1, Int(width.rounded()))
        if side % 2 == 1 {
            return CGPoint(x: p.x.rounded(.down) + 0.5, y: p.y.rounded(.down) + 0.5)
        }
        return CGPoint(x: (p.x + 0.5).rounded(.down), y: (p.y + 0.5).rounded(.down))
    }

    private struct RandomClip: BrushClipMask {
        let bounds: PixelRect
        let band: UInt8
        func coverage(x: Int, y: Int) -> UInt8 {
            guard bounds.contains(PixelPoint(x: x, y: y)) else { return 0 }
            // Three bands: full, half, and none.
            switch x % 3 {
            case 0: return 255
            case 1: return band
            default: return 0
            }
        }
    }

    @MainActor
    private func makeStroke(with rng: inout SeededRandom)
        -> (surface: TiledSurface, points: [CGPoint], options: BrushOptions, color: ColorRGBA8, clip: RandomClip?)
    {
        let size = PixelSize(width: rng.int(in: 1...600), height: rng.int(in: 1...600))
        let background = rng.color()
        let surface = TestImages.surface(width: size.width, height: size.height) { _, _ in background }
        let pointCount = rng.int(in: 1...20)
        var points: [CGPoint] = []
        for _ in 0 ..< pointCount {
            if rng.int(in: 0...4) == 0 {
                // Sometimes a wildly off-canvas point.
                points.append(CGPoint(x: rng.double(in: -2000 ... 2000),
                                      y: rng.double(in: -2000 ... 2000)))
            } else {
                points.append(CGPoint(x: rng.double(in: -20 ... Double(size.width) + 20),
                                      y: rng.double(in: -20 ... Double(size.height) + 20)))
            }
        }
        let options = BrushOptions(width: rng.double(in: 1 ... 60),
                                   hardness: rng.int(in: 0 ... 100),
                                   antialiasing: rng.int(in: 0 ... 1) == 1,
                                   blendMode: .normal)
        let clip = rng.int(in: 0 ... 2) == 0
            ? RandomClip(bounds: size.bounds, band: rng.byte()) : nil
        return (surface, points, options, rng.color(), clip)
    }

    private func paint(_ fixture: (surface: TiledSurface, points: [CGPoint],
                                   options: BrushOptions, color: ColorRGBA8, clip: RandomClip?),
                       points overridePoints: [CGPoint]? = nil) -> (TiledSurface, BrushStroke) {
        var surface = fixture.surface
        var stroke = BrushStroke(canvasSize: surface.size, options: fixture.options,
                                 clipMask: fixture.clip,
                                 compose: PaintbrushTool.paintbrushCompose(
                                    color: fixture.color, blendMode: fixture.options.blendMode))
        let points = overridePoints ?? fixture.points
        _ = stroke.begin(at: points[0], on: &surface)
        for point in points.dropFirst() { _ = stroke.extend(to: point, on: &surface) }
        return (surface, stroke)
    }

    @Test func matchesMinDistanceOracle() {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0D157A4E5))
        rng = SeededRandom(seed: 0xD157A4E5)
        for iteration in 0 ..< 200 {
            var local = rng
            let fixture = makeStroke(with: &local)
            let before = fixture.surface
            let (surface, _) = paint(fixture)
            let snapped = fixture.points
                .map { $0.x.isFinite && $0.y.isFinite ? $0 : nil }
                .compactMap { $0 }
            let effective = fixture.options.antialiasing
                ? snapped
                : snapped.map { aliasedSnap($0, width: fixture.options.width) }
            // A single point is the degenerate segment p→p; the oracle handles it via the
            // duplicated endpoint below (`polyline`).
            let oracle = StrokeOracle(width: fixture.options.width,
                                      hardness: fixture.options.hardness,
                                      antialiased: fixture.options.antialiasing,
                                      color: fixture.color)
            var polyline = effective
            if polyline.count == 1 { polyline.append(polyline[0]) }
            TestImages.expectPixels(surface, match: { x, y in
                let raw = oracle.coverage(x: x, y: y, snappedPoints: polyline)
                let clipCoverage: UInt8 = fixture.clip.map { $0.coverage(x: x, y: y) } ?? 255
                return oracle.compose(before: before.pixel(at: PixelPoint(x: x, y: y)),
                                      rawCoverage: raw, clipCoverage: clipCoverage)
            }, "iteration \(iteration) width=\(fixture.options.width) h=\(fixture.options.hardness) aa=\(fixture.options.antialiasing) points=\(fixture.points.count) \(local.comment)")
            rng = SeededRandom(seed: local.next())
        }
    }

    @Test func eventSplittingIsIrrelevant() {
        var rng = SeededRandom(seed: 0xE5E07111)
        for iteration in 0 ..< 200 {
            var local = rng
            let fixture = makeStroke(with: &local)
            let finite = fixture.points.filter { $0.x.isFinite && $0.y.isFinite }
            guard finite.count >= 2 else { continue }
            // Antialiased: split the exact float polyline — the profile is continuous,
            // so the union of the sub-segments' footprints equals the whole segment's
            // and the surfaces must match bit-for-bit. Aliased (spec *Test plan*): the
            // engine snaps centers to its sample grid, so both runs deliver snapped
            // points; each sub-segment splits at the exact grid steps on the line
            // (integer deltas, steps of gcd(|Δx|, |Δy|)) — exact collinear arithmetic,
            // so the sub-segments' half-open disc unions equal the whole's.
            let aliasedSide = BrushEngine.aliasedWidth(fixture.options.width)
            let basePoints = fixture.options.antialiasing
                ? finite
                : finite.map { BrushEngine.snappedCenter($0, width: Double(aliasedSide)) }
            func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
            var split: [CGPoint] = [basePoints[0]]
            for index in 0 ..< (basePoints.count - 1) {
                let a = basePoints[index], b = basePoints[index + 1]
                if fixture.options.antialiasing {
                    // Cap at 5 sub-segments (the spec's event density bound); float
                    // interpolation keeps every split point exactly collinear.
                    let parts = Swift.min(5, local.int(in: 2 ... 5))
                    var emitted = 0
                    for part in 1 ... parts {
                        let t = Double(part) / Double(parts)
                        let point = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                        if point.x.isFinite, point.y.isFinite, emitted < 4 {
                            split.append(point)
                            emitted += 1
                        }
                    }
                    split.append(b)
                } else {
                    let dx = Int((b.x - a.x).rounded()), dy = Int((b.y - a.y).rounded())
                    let g = gcd(dx, dy)
                    // (dx*k)/g is exact for every g | dx*k (both signs); unsplittable
                    // segments still contribute their endpoint to the polyline.
                    var step = 1
                    if g > 1 {
                        step = max(1, Int(Double(g) / 5.0 + 0.999999))
                        while g % step != 0 { step += 1 }
                        var k = step
                        while k < g {
                            split.append(CGPoint(x: a.x + Double((dx * k) / g),
                                                 y: a.y + Double((dy * k) / g)))
                            k += step
                        }
                    }
                    split.append(b)
                }
            }
            let (direct, _) = paint(fixture, points: basePoints)
            let (splitRun, _) = paint(fixture, points: split)
            #expect(direct == splitRun,
                    "iteration \(iteration) \(local.comment) — splitting must not change pixels")
            rng = SeededRandom(seed: local.next())
        }
    }

    @Test func undoRedoIdentity() throws {
        var rng = SeededRandom(seed: 0x01D0BEEF)
        for iteration in 0 ..< 200 {
            var local = rng
            let size = PixelSize(width: local.int(in: 8 ... 300), height: local.int(in: 8 ... 300))
            let context = FakeToolContextForProperties(size: size, background: local.color())
            let tool = PaintbrushTool()
            let pointCount = local.int(in: 1 ... 6)
            let points = (0 ..< pointCount).map { _ in
                CGPoint(x: local.double(in: -10 ... Double(size.width) + 10),
                        y: local.double(in: -10 ... Double(size.height) + 10))
            }
            let before = context.image
            for (index, point) in points.enumerated() {
                if index == 0 {
                    tool.mouseDown(TestEventFactory.at(point), context: context)
                } else {
                    tool.mouseDragged(TestEventFactory.at(point), context: context)
                }
            }
            tool.mouseUp(TestEventFactory.at(points[points.count - 1]), context: context)
            let after = context.image
            let hadChange = !(before == after)
            let stepCount = context.history.steps.count
            #expect(stepCount == (hadChange ? 2 : 1),
                    "iteration \(iteration): one step for a real stroke, none for a no-op (\(local.comment))")

            context.navigateForTests { history, state in _ = history.undo(&state) }
            #expect(context.image == before,
                    "iteration \(iteration): undo restores the pre-stroke tiles (\(local.comment))")
            context.navigateForTests { history, state in _ = history.redo(&state) }
            #expect(context.image == after,
                    "iteration \(iteration): redo restores the painted tiles (\(local.comment))")
            rng = SeededRandom(seed: local.next())
        }
    }
}

/// `FakeToolContext` with a background color instead of `.clear` (the property tests paint
/// on random backgrounds).
@MainActor
private func FakeToolContextForProperties(size: PixelSize, background: ColorRGBA8) -> FakeToolContext {
    FakeToolContext(size: size, background: background)
}

enum TestEventFactory {
    static func at(_ point: CGPoint, button: ToolMouseButton = .primary) -> ToolEvent {
        ToolEvent(location: point, viewLocation: .zero, button: button, modifiers: [],
                  clickCount: 1, pressure: 1, timestamp: 0)
    }
}

