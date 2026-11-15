import CoreGraphics
import Testing

@testable import PaintDotMac

/// Wheel ↔ hue/saturation mapping in view coordinates with **y down** (spec 0007): hue 0 at
/// 3 o'clock increasing counterclockwise, saturation along the radius. Expected values are
/// hand-computed.
struct ColorWheelGeometryTests {
    private let center = CGPoint(x: 100, y: 100)
    private let radius = 100.0
    private let tolerance = 1e-9

    private func sample(_ point: CGPoint) -> (hue: Double, saturation: Double) {
        guard let value = ColorWheelGeometry.hueSaturation(at: point, center: center,
                                                           radius: radius)
        else { Issue.record("no hue/saturation for \(point)"); return (-1, -1) }
        return value
    }

    @Test func cardinalPoints() {
        let east = sample(CGPoint(x: 200, y: 100))
        expectClose(east.hue, 0, tolerance: tolerance, message: "3 o'clock")
        expectClose(east.saturation, 100, tolerance: tolerance)

        let north = sample(CGPoint(x: 100, y: 0))
        expectClose(north.hue, 90, tolerance: tolerance, message: "12 o'clock is hue 90")
        expectClose(north.saturation, 100, tolerance: tolerance)

        let west = sample(CGPoint(x: 0, y: 100))
        expectClose(west.hue, 180, tolerance: tolerance, message: "9 o'clock")
        expectClose(west.saturation, 100, tolerance: tolerance)

        let south = sample(CGPoint(x: 100, y: 200))
        expectClose(south.hue, 270, tolerance: tolerance, message: "6 o'clock")
        expectClose(south.saturation, 100, tolerance: tolerance)
    }

    @Test func diagonalAndHalfRadius() {
        let half = sample(CGPoint(x: 150, y: 100))
        expectClose(half.hue, 0, tolerance: tolerance)
        expectClose(half.saturation, 50, tolerance: tolerance)

        let diagonal = sample(CGPoint(x: 150, y: 50))
        expectClose(diagonal.hue, 45, tolerance: tolerance)
        expectClose(diagonal.saturation, 70.71067811865476, tolerance: tolerance,
                    message: "50√2 of a 100 px radius")
    }

    @Test func clampsOutsideRim() {
        let outside = sample(CGPoint(x: 300, y: 100))
        expectClose(outside.hue, 0, tolerance: tolerance)
        #expect(outside.saturation == 100, "a drag that leaves the wheel pins the rim")
    }

    @Test func centerIsZeroSaturation() {
        let middle = sample(center)
        #expect(middle.saturation == 0)
        #expect(middle.hue == 0, "the center has no direction; the view passes the cached hue")
    }

    @Test func zeroRadiusReturnsNil() {
        #expect(ColorWheelGeometry.hueSaturation(at: center, center: center, radius: 0) == nil)
        #expect(ColorWheelGeometry.hueSaturation(at: center, center: center, radius: -5) == nil)
    }

    @Test func pointInverse() {
        let marker = ColorWheelGeometry.point(hue: 90, saturation: 50, center: center,
                                              radius: radius)
        expectClose(Double(marker.x), 100, message: "90° is on the vertical spoke")
        expectClose(Double(marker.y), 50, message: "y is down, so 90° sits above the center")

        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x5EED_0703))
        for _ in 0..<1_000 {
            // Exact multiples of 0.001° below 360, and saturation 0…100.
            let hue = Double(rng.int(in: 0...359_999)) / 1__000
            let saturation = Double(rng.int(in: 0...100_000)) / 1_000
            let point = ColorWheelGeometry.point(hue: hue, saturation: saturation, center: center,
                                                 radius: radius)
            let back = sample(point)
            // Hue is circular: 359.9999999 and 0 are the same direction.
            let hueError = min(abs(back.hue - hue), 360 - abs(back.hue - hue))
            #expect(hueError <= tolerance, "hue \(hue) came back as \(back.hue) — \(rng.comment)")
            #expect(abs(back.saturation - saturation) <= tolerance,
                    "saturation \(saturation) came back as \(back.saturation) — \(rng.comment)")
        }
    }

    @Test func constraintFromModifiers() {
        typealias Constraint = ColorWheelGeometry.Constraint
        #expect(Constraint.constraint(command: true, option: false, shift: false) == .hueOnly)
        #expect(Constraint.constraint(command: false, option: true, shift: false) == .saturationOnly)
        #expect(Constraint.constraint(command: true, option: false, shift: true) == .hueSnapped,
                "⇧⌘ snaps the hue")
        #expect(Constraint.constraint(command: true, option: true, shift: false) == .hueOnly,
                "⌘ wins over ⌥")
        #expect(Constraint.constraint(command: false, option: false, shift: true) == .free)
        #expect(Constraint.constraint(command: false, option: false, shift: false) == .free)
    }

    @Test func constrained() {
        let current = HSVColor(hue: 200, saturation: 40, value: 80)

        var result = ColorWheelGeometry.constrained(hue: 10, saturation: 90, current: current,
                                                    constraint: .hueOnly)
        #expect(result.hue == 10 && result.saturation == 40)

        result = ColorWheelGeometry.constrained(hue: 10, saturation: 90, current: current,
                                                constraint: .saturationOnly)
        #expect(result.hue == 200 && result.saturation == 90)

        result = ColorWheelGeometry.constrained(hue: 52, saturation: 90, current: current,
                                                constraint: .hueSnapped)
        #expect(result.hue == 45 && result.saturation == 40, "52 → 3.47 steps → 45")

        result = ColorWheelGeometry.constrained(hue: 353, saturation: 90, current: current,
                                                constraint: .hueSnapped)
        #expect(result.hue == 0, "24 steps = 360 normalizes to 0")
        #expect(result.saturation == 40)

        result = ColorWheelGeometry.constrained(hue: 7.5, saturation: 90, current: current,
                                                constraint: .hueSnapped)
        #expect(result.hue == 15, "half a step rounds away from zero")

        result = ColorWheelGeometry.constrained(hue: 10, saturation: 90, current: current,
                                                constraint: .free)
        #expect(result.hue == 10 && result.saturation == 90)
    }
}
