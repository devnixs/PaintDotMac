import Testing
@testable import PaintDotMac

/// Filter decision per zoom (spec 0003, CAN-3). Expected levels from the spec:
/// `zoom ≥ 1` → nearest; below 1, the largest `k ≤ 6` with `zoom · 2^k ≤ 1`.
struct CanvasSamplingTests {
    @Test(arguments: [
        (32.0, CanvasSampling.nearest),
        (1.0, CanvasSampling.nearest),
        // 0.9999 → area average level 0 (not nearest).
        (0.9999, CanvasSampling.areaAverage(level: 0)),
        (0.5, CanvasSampling.areaAverage(level: 1)),
        (0.4999, CanvasSampling.areaAverage(level: 1)),
        (0.25, CanvasSampling.areaAverage(level: 2)),
        (0.125, CanvasSampling.areaAverage(level: 3)),
        (0.0625, CanvasSampling.areaAverage(level: 4)),
        (0.03125, CanvasSampling.areaAverage(level: 5)),
        (0.015625, CanvasSampling.areaAverage(level: 6)),
        // log2(100) = 6.64 → clamped by maximumLevel.
        (0.01, CanvasSampling.areaAverage(level: 6)),
    ])
    func samplingForZoom(_ zoom: Double, _ expected: CanvasSampling) {
        #expect(CanvasSampling.forZoom(zoom) == expected)
        #expect(CanvasSampling.forZoom(zoom).level == expected.level)
    }

    @Test func levelOfNearestIsZero() {
        #expect(CanvasSampling.nearest.level == 0)
    }

    @Test func maximumLevelMatchesMinimumZoom() {
        #expect(CanvasSampling.maximumLevel == 6)
        // A 256-px tile at level 6 is 4×4 texels.
        #expect(TiledSurface.tileSize >> CanvasSampling.maximumLevel == 4)
    }
}
