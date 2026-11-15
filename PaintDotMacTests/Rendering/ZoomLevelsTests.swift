import CoreGraphics
import Testing
@testable import PaintDotMac

/// All expected values are hand-computed from spec 0004's rules (Paint.NET 4's `ScaleFactor`
/// stops, 1 % added lowest, tolerance 0.001 relative, `half away from zero` percentages).
@Suite(.serialized)
struct ZoomLevelsTests {
    @Test func stopsAreExact() {
        let stops = ZoomLevels.stops
        #expect(stops.count == 24)
        #expect(stops == [
            0.01,
            1.0 / 32.0, 1.0 / 24.0, 1.0 / 16.0, 1.0 / 12.0, 1.0 / 8.0, 1.0 / 6.0, 1.0 / 5.0,
            1.0 / 4.0, 1.0 / 3.0, 1.0 / 2.0, 2.0 / 3.0, 1.0,
            3.0 / 2.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 12.0, 16.0, 24.0, 32.0,
        ])
        #expect(stops.first == 0.01)
        #expect(stops.last == 32)
        #expect(stops.contains(1.0))
        for (previous, next) in zip(stops, stops.dropFirst()) {
            #expect(previous < next)
        }
    }

    @Test func clampBounds() {
        #expect(ZoomLevels.clamp(0.001) == 0.01)
        #expect(ZoomLevels.clamp(100) == 32)
        #expect(ZoomLevels.clamp(0.5) == 0.5)
        #expect(ZoomLevels.clamp(.nan) == 1)
        #expect(ZoomLevels.clamp(.infinity) == 1)
        #expect(ZoomLevels.clamp(-2) == 1)
        #expect(ZoomLevels.clamp(0) == 1)
    }

    @Test func nextLargerFromPresetsAndBetween() {
        // Hand-computed against the 24-stop ladder.
        #expect(ZoomLevels.nextLarger(than: 1.0) == 1.5)
        #expect(ZoomLevels.nextLarger(than: 1.2) == 1.5)
        #expect(ZoomLevels.nextLarger(than: 1.4995) == 2.0)   // within tolerance of 1.5
        #expect(ZoomLevels.nextLarger(than: 0.2) == 0.25)
        #expect(ZoomLevels.nextLarger(than: 0.01) == 1.0 / 32.0)
        #expect(ZoomLevels.nextLarger(than: 0.02) == 1.0 / 32.0)
        #expect(ZoomLevels.nextLarger(than: 24) == 32)
        #expect(ZoomLevels.nextLarger(than: 31.9) == 32)
        #expect(ZoomLevels.nextLarger(than: 32) == nil)
        #expect(ZoomLevels.nextLarger(than: 31.99) == nil)    // within tolerance of 32
    }

    @Test func nextSmallerFromPresetsAndBetween() {
        #expect(ZoomLevels.nextSmaller(than: 1.0) == 2.0 / 3.0)
        #expect(ZoomLevels.nextSmaller(than: 0.7) == 2.0 / 3.0)
        #expect(ZoomLevels.nextSmaller(than: 0.6667) == 0.5)  // within tolerance of 2/3
        #expect(ZoomLevels.nextSmaller(than: 1.0 / 32.0) == 0.01)
        #expect(ZoomLevels.nextSmaller(than: 0.02) == 0.01)
        #expect(ZoomLevels.nextSmaller(than: 0.035) == 1.0 / 32.0)
        #expect(ZoomLevels.nextSmaller(than: 0.0101) == 0.01)
        #expect(ZoomLevels.nextSmaller(than: 0.010005) == nil)  // within tolerance of 1 %
        #expect(ZoomLevels.nextSmaller(than: 0.01) == nil)
        #expect(ZoomLevels.nextSmaller(than: 32) == 24)
        #expect(ZoomLevels.nextSmaller(than: 2.5) == 2)
    }

    @Test func steppingVisitsEveryStop() {
        var zoom = 0.01
        for expected in ZoomLevels.stops.dropFirst() {
            let next = ZoomLevels.nextLarger(than: zoom)
            #expect(next == expected)
            zoom = next ?? zoom
        }
        #expect(ZoomLevels.nextLarger(than: zoom) == nil)

        zoom = 32
        for expected in ZoomLevels.stops.reversed().dropFirst() {
            let next = ZoomLevels.nextSmaller(than: zoom)
            #expect(next == expected)
            zoom = next ?? zoom
        }
        #expect(ZoomLevels.nextSmaller(than: zoom) == nil)
    }

    @Test func zoomInThenOutReturns() {
        for stop in ZoomLevels.stops.dropFirst().dropLast() {
            let larger = ZoomLevels.nextLarger(than: stop)
            let smaller = ZoomLevels.nextSmaller(than: stop)
            #expect(larger != nil && ZoomLevels.nextSmaller(than: larger!) == stop)
            #expect(smaller != nil && ZoomLevels.nextLarger(than: smaller!) == stop)
        }
    }

    @Test func canZoomAtLimits() {
        #expect(ZoomLevels.canZoomIn(from: 32) == false)
        #expect(ZoomLevels.canZoomIn(from: 1) == true)
        #expect(ZoomLevels.canZoomOut(from: 0.01) == false)
        #expect(ZoomLevels.canZoomOut(from: 1.0 / 32.0) == true)
    }

    @Test func fitZoomShrinks() {
        // 800/4000 = 0.2 ≤ 600/3000 = 0.2; 800/4000 = 0.2 ≤ 600/1000 = 0.6;
        // 800/1000 = 0.8 vs 600/4000 = 0.15.
        #expect(ZoomLevels.fitZoom(contentSize: CGSize(width: 4000, height: 3000),
                                   viewportSize: CGSize(width: 800, height: 600),
                                   allowsEnlargement: false) == 0.2)
        #expect(ZoomLevels.fitZoom(contentSize: CGSize(width: 4000, height: 1000),
                                   viewportSize: CGSize(width: 800, height: 600),
                                   allowsEnlargement: false) == 0.2)
        #expect(ZoomLevels.fitZoom(contentSize: CGSize(width: 1000, height: 4000),
                                   viewportSize: CGSize(width: 800, height: 600),
                                   allowsEnlargement: false) == 0.15)
    }

    @Test func fitZoomNeverEnlargesForWindow() {
        // 800/400 = 2, 600/300 = 2 → capped at 1.0 for the window; 2.0 when allowed.
        #expect(ZoomLevels.fitZoom(contentSize: CGSize(width: 400, height: 300),
                                   viewportSize: CGSize(width: 800, height: 600),
                                   allowsEnlargement: false) == 1.0)
        #expect(ZoomLevels.fitZoom(contentSize: CGSize(width: 400, height: 300),
                                   viewportSize: CGSize(width: 800, height: 600),
                                   allowsEnlargement: true) == 2.0)
        // 600/1 = 600 → clamped to 32.
        #expect(ZoomLevels.fitZoom(contentSize: CGSize(width: 1, height: 1),
                                   viewportSize: CGSize(width: 800, height: 600),
                                   allowsEnlargement: true) == 32)
    }

    @Test func fitZoomHugeClampsToMinimum() {
        // 500/65535 ≈ 0.00763 < 0.01 → clamps to 1 %.
        #expect(ZoomLevels.fitZoom(contentSize: CGSize(width: 65535, height: 65535),
                                   viewportSize: CGSize(width: 500, height: 500),
                                   allowsEnlargement: false) == 0.01)
    }

    @Test func fitZoomVeryWide() {
        let fit = ZoomLevels.fitZoom(contentSize: CGSize(width: 65535, height: 1),
                                     viewportSize: CGSize(width: 800, height: 600),
                                     allowsEnlargement: false)
        #expect(abs(fit - 800.0 / 65535.0) <= 1e-12)
    }

    @Test func fitZoomDegenerateInputs() {
        #expect(ZoomLevels.fitZoom(contentSize: CGSize(width: 400, height: 300),
                                   viewportSize: CGSize(width: 0, height: 600),
                                   allowsEnlargement: false) == 1.0)
        #expect(ZoomLevels.fitZoom(contentSize: CGSize(width: 0, height: 10),
                                   viewportSize: CGSize(width: 800, height: 600),
                                   allowsEnlargement: false) == 1.0)
        #expect(ZoomLevels.fitZoom(contentSize: CGSize(width: Double.nan, height: 10),
                                   viewportSize: CGSize(width: 800, height: 600),
                                   allowsEnlargement: true) == 1.0)
    }

    @Test func pinchScales() {
        #expect(ZoomLevels.zoom(1, magnifiedBy: 0.5) == 1.5)
        #expect(ZoomLevels.zoom(2, magnifiedBy: -0.25) == 1.5)
    }

    @Test func pinchClamps() {
        // 30 · 2 = 60 → 32; 0.011 · 0.5 = 0.0055 → 0.01.
        #expect(ZoomLevels.zoom(30, magnifiedBy: 1) == 32)
        #expect(ZoomLevels.zoom(0.011, magnifiedBy: -0.5) == 0.01)
    }

    @Test func pinchRejectsInvalid() {
        #expect(ZoomLevels.zoom(2, magnifiedBy: -1) == 2)
        #expect(ZoomLevels.zoom(2, magnifiedBy: -3) == 2)
        #expect(ZoomLevels.zoom(2, magnifiedBy: .nan) == 2)
    }

    @Test func preciseScrollZoom() {
        // 1 · 2^(100/100) = 2; 1 · 2^(-1) = 0.5; 0 delta unchanged.
        #expect(ZoomLevels.zoom(1, scrolledBy: 100, isPrecise: true) == 2)
        #expect(ZoomLevels.zoom(1, scrolledBy: -100, isPrecise: true) == 0.5)
        #expect(ZoomLevels.zoom(1, scrolledBy: 0, isPrecise: true) == 1)
    }

    @Test func preciseScrollZoomClamps() {
        // 16 · 2^5 = 512 → 32.
        #expect(ZoomLevels.zoom(16, scrolledBy: 500, isPrecise: true) == 32)
    }

    @Test func wheelScrollZoomSteps() {
        // One stop per wheel event regardless of magnitude.
        #expect(ZoomLevels.zoom(1, scrolledBy: 3, isPrecise: false) == 1.5)
        #expect(ZoomLevels.zoom(1, scrolledBy: -1, isPrecise: false) == 2.0 / 3.0)
        #expect(ZoomLevels.zoom(32, scrolledBy: 1, isPrecise: false) == 32)
        #expect(ZoomLevels.zoom(0.01, scrolledBy: -1, isPrecise: false) == 0.01)
    }

    @Test func percentStrings() {
        // Half away from zero: 12.5 → 13, 66.67 → 67, 3.125 → 3.
        #expect(ZoomLevels.percentString(1) == "100%")
        #expect(ZoomLevels.percentString(0.5) == "50%")
        #expect(ZoomLevels.percentString(2.0 / 3.0) == "67%")
        #expect(ZoomLevels.percentString(1.0 / 3.0) == "33%")
        #expect(ZoomLevels.percentString(1.0 / 8.0) == "13%")
        #expect(ZoomLevels.percentString(1.0 / 6.0) == "17%")
        #expect(ZoomLevels.percentString(1.0 / 32.0) == "3%")
        #expect(ZoomLevels.percentString(0.01) == "1%")
        #expect(ZoomLevels.percentString(1.5) == "150%")
        #expect(ZoomLevels.percentString(32) == "3200%")
        #expect(ZoomLevels.percentString(0.2) == "20%")
    }
}
