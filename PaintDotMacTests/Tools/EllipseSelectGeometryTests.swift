import Testing
@testable import PaintDotMac

/// `EllipseSelectGeometry` (spec 0014 *Test plan*): the pixel-inclusive bounding rect and
/// the Shift circle (center between the two pixel centers, diameter = start-to-pointer
/// distance). Expected values are hand-computed from the spec's formulas.
struct EllipseSelectGeometryTests {
    @Test func boundingRectNormal() {
        #expect(EllipseSelectGeometry.boundingRect(anchor: PixelPoint(x: 2, y: 3),
                                                   current: PixelPoint(x: 11, y: 8),
                                                   constrainCircle: false)
                    == PixelRect(x: 2, y: 3, width: 10, height: 6))
    }

    @Test func shiftCircle() {
        // a (0,0), b (6,8): d = round(10) + 1 = 11, c = (3.5, 4.5).
        #expect(EllipseSelectGeometry.boundingRect(anchor: PixelPoint(x: 0, y: 0),
                                                   current: PixelPoint(x: 6, y: 8),
                                                   constrainCircle: true)
                    == PixelRect(x: -2, y: -1, width: 11, height: 11))
        // a = b: the 1 × 1 circle at the anchor.
        #expect(EllipseSelectGeometry.boundingRect(anchor: PixelPoint(x: 0, y: 0),
                                                   current: PixelPoint(x: 0, y: 0),
                                                   constrainCircle: true)
                    == PixelRect(x: 0, y: 0, width: 1, height: 1))
        // a (10,10), b (13,14): d = round(5) + 1 = 6, c = (12, 12.5).
        #expect(EllipseSelectGeometry.boundingRect(anchor: PixelPoint(x: 10, y: 10),
                                                   current: PixelPoint(x: 13, y: 14),
                                                   constrainCircle: true)
                    == PixelRect(x: 9, y: 9, width: 6, height: 6))
    }

    @Test func isEmpty() {
        let image = PixelSize(width: 100, height: 80)
        #expect(EllipseSelectGeometry.isEmpty(PixelRect(x: -20, y: -20, width: 10, height: 10),
                                              imageSize: image))
        #expect(!EllipseSelectGeometry.isEmpty(PixelRect(x: -5, y: -5, width: 10, height: 10),
                                               imageSize: image))
    }

    @Test func tinyImage() {
        // The Shift circle on a 1 × 1 canvas touches the canvas.
        let circle = EllipseSelectGeometry.boundingRect(anchor: PixelPoint(x: 0, y: 0),
                                                        current: PixelPoint(x: 0, y: 0),
                                                        constrainCircle: true)
        #expect(!EllipseSelectGeometry.isEmpty(circle, imageSize: PixelSize(width: 1, height: 1)))
    }
}
