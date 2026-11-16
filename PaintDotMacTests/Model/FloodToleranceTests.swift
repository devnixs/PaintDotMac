import Testing

@testable import PaintDotMac

/// `FloodTolerance` — Paint.NET's `tol = (int)(t·t·256)` scaling and the `tol² × 4`
/// limit (spec 0016 *Test plan*; the table is normative, hand-computed from Paint.NET
/// 3.36 `FloodToolBase`).
struct FloodToleranceTests {
    @Test func scaledTable() {
        // percent → (scaled, maxDistance)
        let table: [(Int, Int, Int)] = [
            (0, 0, 0),
            (10, 2, 16),
            (25, 16, 1024),
            (30, 23, 2116),
            (50, 64, 16384),
            (70, 125, 62500),
            (99, 250, 250000),
            (100, 256, 262144),
        ]
        for (percent, scaled, maxDistance) in table {
            let tolerance = FloodTolerance(percent: percent)
            #expect(tolerance.percent == percent, "percent \(percent)")
            #expect(tolerance.scaled == scaled, "scaled at \(percent) %")
            #expect(tolerance.maxDistance == maxDistance, "maxDistance at \(percent) %")
        }
    }

    @Test func clamps() {
        #expect(FloodTolerance(percent: -5).percent == 0)
        #expect(FloodTolerance(percent: -5).scaled == 0)
        #expect(FloodTolerance(percent: 150).percent == 100)
        #expect(FloodTolerance(percent: 150).scaled == 256)
    }

    @Test func defaultValue() {
        #expect(FloodTolerance.default.percent == 50)
        #expect(FloodTolerance.default.scaled == 64)
    }
}
