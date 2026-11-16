import CoreGraphics
import Testing
@testable import PaintDotMac

/// `CanvasTransform.zoomedToFit` (spec 0014 *Test plan*, CAN-1): fit with enlargement,
/// center on the rect, then `clampedScroll`. Expected values hand-computed (image
/// 1000 × 800, view 500 × 400 pt).
struct CanvasTransformZoomToFitTests {
    private func transform(backing: Double = 2) -> CanvasTransform {
        CanvasTransform(imageSize: PixelSize(width: 1000, height: 800),
                        viewSize: CGSize(width: 500, height: 400),
                        backingScale: backing, zoom: 1,
                        center: CGPoint(x: 500, y: 400))
    }

    @Test func fitsAndCenters() {
        // viewport 1000 × 800 device px / content 250 × 200 → min(4, 4).
        let result = transform().zoomedToFit(CGRect(x: 100, y: 100, width: 250, height: 200))
        #expect(result.zoom == 4.0)
        #expect(result.center == CGPoint(x: 225, y: 200))
    }

    @Test func clampsToMaximumAndScrolls() throws {
        let result = transform().zoomedToFit(CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(result.zoom == 32.0, "3200 % clamp")
        let unclamped = CanvasTransform(imageSize: PixelSize(width: 1000, height: 800),
                                        viewSize: CGSize(width: 500, height: 400),
                                        backingScale: 2, zoom: 32,
                                        center: CGPoint(x: 0.5, y: 0.5))
        #expect(result == unclamped.clampedScroll(),
                "center (0.5, 0.5) then the standard scroll clamp")
    }

    @Test func wholeImageStaysAt100Percent() {
        let result = transform().zoomedToFit(CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(result.zoom == 1.0)
        #expect(result.center == CGPoint(x: 500, y: 400))
    }

    @Test func backingScaleOne() {
        // viewport 500 × 400 device px → min(2, 2).
        let result = transform(backing: 1).zoomedToFit(CGRect(x: 100, y: 100, width: 250, height: 200))
        #expect(result.zoom == 2.0)
        #expect(result.center == CGPoint(x: 225, y: 200))
    }

    @Test func degenerateInputsChangeNothing() {
        let base = transform()
        #expect(base.zoomedToFit(CGRect(x: 5, y: 5, width: 0, height: 10)) == base)
        #expect(base.zoomedToFit(CGRect(x: 5, y: 5, width: CGFloat.nan, height: 10)) == base)
        #expect(base.zoomedToFit(CGRect(x: .nan as CGFloat, y: 5, width: 10, height: 10)) == base)
        let zeroView = CanvasTransform(imageSize: PixelSize(width: 1000, height: 800),
                                       viewSize: .zero, backingScale: 2, zoom: 1,
                                       center: .zero)
        #expect(zeroView.zoomedToFit(CGRect(x: 0, y: 0, width: 10, height: 10)) == zeroView)
    }
}
