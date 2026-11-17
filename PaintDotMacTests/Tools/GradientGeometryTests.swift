import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// Shift snapping and handle hit testing (spec 0023 *Test plan*), exact within 1e-9 —
/// expected values from the formulas, hand-derived.
struct GradientGeometryTests {
    private let tolerance = 1e-9

    private func transform(zoom: Double, backing: Double = 1) -> CanvasTransform {
        CanvasTransform(imageSize: PixelSize(width: 300, height: 300),
                        viewSize: CGSize(width: 300, height: 300),
                        backingScale: backing, zoom: zoom,
                        center: CGPoint(x: 150, y: 150))
    }

    // MARK: - Snapping

    @Test func snappedHorizontal() {
        let point = GradientGeometry.snapped(CGPoint(x: 10, y: 1), anchor: .zero)
        #expect(abs(point.x - Foundation.sqrt(101)) < tolerance)
        #expect(abs(point.y) < tolerance)
    }

    @Test func snapped45() {
        let point = GradientGeometry.snapped(CGPoint(x: 10, y: 9), anchor: .zero)
        let radius = Foundation.sqrt(181)
        #expect(abs(point.x - radius * cos(.pi / 4)) < tolerance)
        #expect(abs(point.y - radius * sin(.pi / 4)) < tolerance)
    }

    @Test func snapped180() {
        let point = GradientGeometry.snapped(CGPoint(x: -5, y: 0.1), anchor: .zero)
        let radius = Foundation.sqrt(25.01)
        #expect(abs(point.x + radius) < tolerance)
        #expect(abs(point.y) < tolerance)
        let down = GradientGeometry.snapped(CGPoint(x: 0, y: -7), anchor: .zero)
        #expect(abs(down.x) < tolerance)
        #expect(abs(down.y + 7) < tolerance)
    }

    @Test func snappedZeroLengthKeepsAnchor() {
        let anchor = CGPoint(x: 3, y: 4)
        #expect(GradientGeometry.snapped(anchor, anchor: anchor) == anchor)
    }

    // MARK: - Hit testing (view points)

    @Test func hitHandleRadius() {
        let transform = transform(zoom: 1)
        let handle = CGPoint(x: 10, y: 10)
        let view = transform.canvasToView(handle)
        #expect(GradientGeometry.hitHandle(atView: CGPoint(x: view.x + 5, y: view.y),
                                           start: handle, end: CGPoint(x: 200, y: 200),
                                           transform: transform) == .start,
                "5 pt away hits")
        #expect(GradientGeometry.hitHandle(atView: CGPoint(x: view.x + 7, y: view.y),
                                           start: handle, end: CGPoint(x: 200, y: 200),
                                           transform: transform) == nil,
                "7 pt away misses")
    }

    @Test func hitHandleNearerWinsTieGoesToEnd() {
        let transform = transform(zoom: 1)
        let start = transform.viewToCanvas(CGPoint(x: 100, y: 100))
        let end = transform.viewToCanvas(CGPoint(x: 110, y: 100))
        #expect(GradientGeometry.hitHandle(atView: CGPoint(x: 104, y: 100),
                                           start: start, end: end,
                                           transform: transform) == .start,
                "both in range → the nearer")
        #expect(GradientGeometry.hitHandle(atView: CGPoint(x: 105, y: 100),
                                           start: start, end: end,
                                           transform: transform) == .end,
                "exact tie → .end")
    }

    @Test func hitRadiusIsViewSpaceAt400Percent() {
        // At 400 % zoom 1 canvas px = 4 pt: the radius stays 6 pt in view space.
        let transform = transform(zoom: 4)
        let handle = CGPoint(x: 10, y: 10)
        let view = transform.canvasToView(handle)
        #expect(GradientGeometry.hitHandle(atView: CGPoint(x: view.x + 6, y: view.y),
                                           start: handle, end: CGPoint(x: 200, y: 200),
                                           transform: transform) == .start,
                "6 pt (1.5 canvas px) still hits at 400 %")
        #expect(GradientGeometry.hitHandle(atView: CGPoint(x: view.x + 8, y: view.y),
                                           start: handle, end: CGPoint(x: 200, y: 200),
                                           transform: transform) == nil,
                "8 pt (2 canvas px) misses at 400 %")
    }
}
