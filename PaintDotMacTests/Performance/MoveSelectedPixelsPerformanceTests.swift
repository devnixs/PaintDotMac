import CoreGraphics
import XCTest

@testable import PaintDotMac

/// NF-1 support for spec 0020 (Performance): re-rendering a 1024 × 1024 floating region
/// per drag event. Rotated 30° (bilinear): target < 150 ms, gated at 3× (450 ms).
/// Integer translation (nearest): target < 60 ms, gated at 180 ms. Medians print for the
/// Verification status. Each iteration renders `lastRegion ∪ destinationBounds` into the
/// live surface — the exact per-event work of `mouseDragged`.
final class MoveSelectedPixelsPerformanceTests: XCTestCase {
    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    @MainActor
    private func lifted() throws -> (FloatingPixels, TiledSurface, DocumentState) {
        let size = PixelSize(width: 4_096, height: 3_072)
        var surface = TiledSurface(size: size)
        surface.fill(ColorRGBA8(red: 12, green: 34, blue: 56, alpha: 255),
                     in: PixelRect(origin: .zero, size: size))
        let state = DocumentState(
            image: LayeredImage(surface: surface),
            selection: try XCTUnwrap(Selection(
                rect: CGRect(x: 1_024, y: 1_024, width: 1_024, height: 1_024),
                canvasSize: size)))
        let floating = try XCTUnwrap(
            FloatingPixels.lift(from: state, duplicate: false, baseStepID: 0))
        return (floating, state.image.activeLayer.surface, state)
    }

    /// 30° rotation (bilinear). Gate: 450 ms per event.
    @MainActor
    func testRenderRotatedRegion() throws {
        let (base, _, _) = try lifted()
        var floating = base
        let center = CGPoint(x: 1_536, y: 1_536)
        floating.session = base.session.applying(
            .rotate, from: CGPoint(x: 2_536, y: 1_536),
            to: CGPoint(x: center.x + 1_000 * cos(.pi / 6),
                        y: center.y + 1_000 * sin(.pi / 6)),
            modifiers: [])
        let region = base.destinationBounds.union(floating.destinationBounds)
        var elapsed: [Double] = []
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            var surface = base.underlay
            let start = DispatchTime.now().uptimeNanoseconds
            floating.render(into: &surface, region: region)
            elapsed.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            withExtendedLifetime(surface) {}
        }
        let ms = median(elapsed)
        print("MoveSelectedPixelsPerformanceTests.renderRotatedRegion: "
            + "\(String(format: "%.1f", ms)) ms (gate 450 ms)")
        XCTAssertLessThanOrEqual(ms, 450)
    }

    /// Integer translation (nearest neighbor). Gate: 180 ms per event.
    @MainActor
    func testRenderIntegerMoveRegion() throws {
        let (base, _, _) = try lifted()
        var floating = base
        floating.session = base.session.translatedBy(dx: 64, dy: 48)
        let region = base.destinationBounds.union(floating.destinationBounds)
        var elapsed: [Double] = []
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            var surface = base.underlay
            let start = DispatchTime.now().uptimeNanoseconds
            floating.render(into: &surface, region: region)
            elapsed.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            withExtendedLifetime(surface) {}
        }
        let ms = median(elapsed)
        print("MoveSelectedPixelsPerformanceTests.renderIntegerMoveRegion: "
            + "\(String(format: "%.1f", ms)) ms (gate 180 ms)")
        XCTAssertLessThanOrEqual(ms, 180)
    }
}
