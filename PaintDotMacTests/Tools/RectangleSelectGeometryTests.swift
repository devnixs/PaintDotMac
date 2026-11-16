import Testing
@testable import PaintDotMac

/// `RectangleSelectGeometry.rect` (spec 0014 *Test plan*): Paint.NET's pixel-inclusive
/// rectangle, Shift square, Fixed Ratio, Fixed Size, and the clip to the image. Expected
/// values are hand-computed from the spec's formulas (image 100 × 80 unless stated).
struct RectangleSelectGeometryTests {
    private let image = PixelSize(width: 100, height: 80)
    private let normal = RectangleSelectGeometry(drawMode: .normal,
                                                 ratio: SelectionRatio(width: 4, height: 3),
                                                 fixedPixelSize: PixelSize(width: 30, height: 20))
    private func geometry(_ mode: SelectionDrawMode, ratio: (Double, Double) = (4, 3),
                          size: (Int, Int) = (30, 20)) -> RectangleSelectGeometry {
        RectangleSelectGeometry(drawMode: mode,
                                ratio: SelectionRatio(width: ratio.0, height: ratio.1),
                                fixedPixelSize: PixelSize(width: size.0, height: size.1))
    }

    @Test func normalForwardAndBackward() throws {
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: 10, y: 10),
                                             current: PixelPoint(x: 20, y: 14),
                                             constrainSquare: false, geometry: normal,
                                             imageSize: image)
                    == PixelRect(x: 10, y: 10, width: 11, height: 5))
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: 20, y: 14),
                                             current: PixelPoint(x: 10, y: 10),
                                             constrainSquare: false, geometry: normal,
                                             imageSize: image)
                    == PixelRect(x: 10, y: 10, width: 11, height: 5))
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: 5, y: 5),
                                             current: PixelPoint(x: 5, y: 5),
                                             constrainSquare: false, geometry: normal,
                                             imageSize: image)
                    == PixelRect(x: 5, y: 5, width: 1, height: 1))
    }

    @Test func shiftSquare() {
        // Side = min(width, height), anchored at the start pixel, toward the pointer.
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: 10, y: 10),
                                             current: PixelPoint(x: 20, y: 14),
                                             constrainSquare: true, geometry: normal,
                                             imageSize: image)
                    == PixelRect(x: 10, y: 10, width: 5, height: 5))
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: 10, y: 10),
                                             current: PixelPoint(x: 4, y: 30),
                                             constrainSquare: true, geometry: normal,
                                             imageSize: image)
                    == PixelRect(x: 4, y: 10, width: 7, height: 7))
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: 10, y: 10),
                                             current: PixelPoint(x: 0, y: 0),
                                             constrainSquare: true, geometry: normal,
                                             imageSize: image)
                    == PixelRect(x: 0, y: 0, width: 11, height: 11))
    }

    @Test func fixedRatio() {
        let g = geometry(.fixedRatio, ratio: (4, 3))
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: 0, y: 0),
                                             current: PixelPoint(x: 39, y: 39),
                                             constrainSquare: false, geometry: g,
                                             imageSize: image)
                    == PixelRect(x: 0, y: 0, width: 40, height: 30))
        // s = min(21/4, 6/3) = 2 → 8 × 6; x grows leftward from the anchor.
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: 50, y: 50),
                                             current: PixelPoint(x: 30, y: 55),
                                             constrainSquare: false, geometry: g,
                                             imageSize: image)
                    == PixelRect(x: 43, y: 50, width: 8, height: 6))
        // Shift is ignored in Fixed Ratio.
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: 0, y: 0),
                                             current: PixelPoint(x: 39, y: 39),
                                             constrainSquare: true, geometry: g,
                                             imageSize: image)
                    == PixelRect(x: 0, y: 0, width: 40, height: 30))
    }

    @Test func fixedRatioThinDrag() {
        // s = min(1/4, 1/3) = 0.25 → w = 1, h = round(0.75) = 1.
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: 10, y: 10),
                                             current: PixelPoint(x: 10, y: 10),
                                             constrainSquare: false,
                                             geometry: geometry(.fixedRatio, ratio: (4, 3)),
                                             imageSize: image)
                    == PixelRect(x: 10, y: 10, width: 1, height: 1))
    }

    @Test func fixedSize() {
        let g = geometry(.fixedSize, size: (30, 20))
        // The top-left follows the pointer.
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: 0, y: 0),
                                             current: PixelPoint(x: 10, y: 20),
                                             constrainSquare: false, geometry: g,
                                             imageSize: image)
                    == PixelRect(x: 10, y: 20, width: 30, height: 20))
    }

    @Test func fixedSizeClipped() {
        let g = geometry(.fixedSize, size: (30, 20))
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: 0, y: 0),
                                             current: PixelPoint(x: 90, y: 70),
                                             constrainSquare: false, geometry: g,
                                             imageSize: image)
                    == PixelRect(x: 90, y: 70, width: 10, height: 10))
        let big = geometry(.fixedSize, size: (500, 500))
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: 0, y: 0),
                                             current: PixelPoint(x: 0, y: 0),
                                             constrainSquare: false, geometry: big,
                                             imageSize: image)
                    == PixelRect(x: 0, y: 0, width: 100, height: 80))
    }

    @Test func clippingPartial() {
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: 90, y: 70),
                                             current: PixelPoint(x: 120, y: 100),
                                             constrainSquare: false, geometry: normal,
                                             imageSize: image)
                    == PixelRect(x: 90, y: 70, width: 10, height: 10))
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: -5, y: -5),
                                             current: PixelPoint(x: 4, y: 4),
                                             constrainSquare: false, geometry: normal,
                                             imageSize: image)
                    == PixelRect(x: 0, y: 0, width: 5, height: 5))
    }

    @Test func clippingFullyOutside() {
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: -50, y: -50),
                                             current: PixelPoint(x: -10, y: -10),
                                             constrainSquare: false, geometry: normal,
                                             imageSize: image) == nil)
        // x = 100 is outside a 100-wide image.
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: 100, y: 0),
                                             current: PixelPoint(x: 120, y: 10),
                                             constrainSquare: false, geometry: normal,
                                             imageSize: image) == nil)
    }

    @Test func tinyImage() {
        #expect(RectangleSelectGeometry.rect(anchor: PixelPoint(x: 0, y: 0),
                                             current: PixelPoint(x: 3, y: -2),
                                             constrainSquare: false, geometry: normal,
                                             imageSize: PixelSize(width: 1, height: 1))
                    == PixelRect(x: 0, y: 0, width: 1, height: 1))
    }
}
