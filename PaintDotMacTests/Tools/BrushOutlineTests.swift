import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `BrushOutline` geometry (spec 0009), all hand-computed. View space is 0003's: AppKit
/// bottom-left points, `device = view · backingScale`, `device = imageOrigin + canvas·zoom`.
struct BrushOutlineTests {
    private func options(width: Double, antialiasing: Bool) -> BrushOptions {
        BrushOptions(width: width, hardness: 75, antialiasing: antialiasing, blendMode: .normal)
    }

    @Test func antialiasedRectIsCenteredSquare() {
        #expect(BrushOutline.canvasRect(center: CGPoint(x: 10.25, y: 30.5),
                                        options: options(width: 20, antialiasing: true))
                    == CGRect(x: 0.25, y: 20.5, width: 20, height: 20))
        #expect(BrushOutline.canvasRect(center: .zero, options: options(width: 6.5, antialiasing: true))
                    == CGRect(x: -3.25, y: -3.25, width: 6.5, height: 6.5))
        // A stored width of 5000 clamps to 2000.
        #expect(BrushOutline.canvasRect(center: .zero,
                                        options: options(width: 5000, antialiasing: true))
                    == CGRect(x: -1000, y: -1000, width: 2000, height: 2000))
    }

    @Test func aliasedSnapsToPixels() {
        // Odd width → pixel center; even width → nearest pixel corner.
        #expect(BrushOutline.canvasRect(center: CGPoint(x: 10, y: 10),
                                        options: options(width: 3, antialiasing: false))
                    == CGRect(x: 9, y: 9, width: 3, height: 3))
        #expect(BrushOutline.canvasRect(center: CGPoint(x: 10.4, y: 20.6),
                                        options: options(width: 2, antialiasing: false))
                    == CGRect(x: 9, y: 20, width: 2, height: 2))
        // 2.5 rounds (half-up) to the odd side 3 → pixel-center snap at (5.5, 5.5).
        #expect(BrushOutline.canvasRect(center: CGPoint(x: 5, y: 5),
                                        options: options(width: 2.5, antialiasing: false))
                    == CGRect(x: 4, y: 4, width: 3, height: 3))
        #expect(BrushOutline.canvasRect(center: CGPoint(x: 5, y: 5),
                                        options: options(width: 2.4, antialiasing: false))
                    == CGRect(x: 4, y: 4, width: 2, height: 2))
        #expect(BrushOutline.canvasRect(center: CGPoint(x: 3.9, y: 4.1),
                                        options: options(width: 1, antialiasing: false))
                    == CGRect(x: 3, y: 4, width: 1, height: 1))
    }

    /// Image 1000×1000, view 500×500 pt, centered at `zoom`/`backingScale`.
    private func transform(zoom: Double, backing: Double) -> CanvasTransform {
        CanvasTransform(imageSize: PixelSize(width: 1000, height: 1000),
                        viewSize: CGSize(width: 500, height: 500),
                        backingScale: backing, zoom: zoom,
                        center: CGPoint(x: 500, y: 500))
    }

    @Test func viewDiameterScalesWithZoomAndBacking() {
        // View width = side · zoom / backingScale (points), height always equals width.
        func viewWidth(_ zoom: Double, _ backing: Double, width: Double) -> CGFloat {
            BrushOutline.viewRect(center: CGPoint(x: 500, y: 500),
                                  options: options(width: width, antialiasing: true),
                                  transform: transform(zoom: zoom, backing: backing)).width
        }
        #expect(viewWidth(1, 1, width: 50) == 50)
        #expect(viewWidth(1, 2, width: 50) == 25)
        #expect(viewWidth(4, 1, width: 50) == 200)
        #expect(viewWidth(0.5, 2, width: 50) == 12.5)
        #expect(viewWidth(32, 2, width: 2000) == 32_000)
        let rect = BrushOutline.viewRect(center: CGPoint(x: 500, y: 500),
                                         options: options(width: 50, antialiasing: true),
                                         transform: transform(zoom: 4, backing: 1))
        #expect(rect.height == rect.width)
    }

    @Test func viewRectFollowsCanvasPoint() {
        // Centered transform: the image center maps to the view center (250, 250).
        let transform = transform(zoom: 2, backing: 1)
        let atCenter = BrushOutline.viewRect(center: CGPoint(x: 500, y: 500),
                                             options: options(width: 10, antialiasing: true),
                                             transform: transform)
        #expect(abs(atCenter.midX - 250) < 1e-9 && abs(atCenter.midY - 250) < 1e-9)
        // +10 canvas px in x and y moves the view rect's mid by (+20, −20) pt (y flips).
        let moved = BrushOutline.viewRect(center: CGPoint(x: 510, y: 510),
                                          options: options(width: 10, antialiasing: true),
                                          transform: transform)
        #expect(abs(moved.midX - (atCenter.midX + 20)) < 1e-9)
        #expect(abs(moved.midY - (atCenter.midY - 20)) < 1e-9)
    }

    @Test func nonFiniteCenterIsNull() {
        let options = options(width: 10, antialiasing: true)
        let transform = transform(zoom: 1, backing: 1)
        for center in [CGPoint(x: Double.nan, y: 5), CGPoint(x: 5, y: Double.nan),
                       CGPoint(x: Double.infinity, y: 5)] {
            #expect(BrushOutline.canvasRect(center: center, options: options).isNull)
            #expect(BrushOutline.viewRect(center: center, options: options,
                                          transform: transform).isNull)
        }
    }

    @Test func tinyOutlineBelowMinimum() {
        // Width 2 at 1 % zoom, backing 1: 0.02 pt < the 3 pt minimum — the view draws
        // nothing and only the crosshair marks the spot.
        let rect = BrushOutline.viewRect(center: CGPoint(x: 500, y: 500),
                                         options: options(width: 2, antialiasing: true),
                                         transform: transform(zoom: 0.01, backing: 1))
        #expect(Double(rect.width) < BrushOutline.minimumViewDiameter)
        #expect(BrushOutline.minimumViewDiameter == 3)
    }
}
