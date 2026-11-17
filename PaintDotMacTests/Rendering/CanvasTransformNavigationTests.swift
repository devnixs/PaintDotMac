import CoreGraphics
import Testing
@testable import PaintDotMac

/// Hand-computed expected values (spec 0004 *Test plan*). View space is bottom-left (y up),
/// view height `H`; every case has an integer device origin, so 0003's origin rounding (≤ ½
/// device pixel) does not move the asserted values (tolerance 1e-9).
@Suite(.serialized)
struct CanvasTransformNavigationTests {
    private let ε = 1e-9

    private func transform(image: (Int, Int), view: (Double, Double),
                           scale: Double = 1, zoom: Double, center: CGPoint) -> CanvasTransform {
        CanvasTransform(imageSize: PixelSize(width: image.0, height: image.1),
                        viewSize: CGSize(width: view.0, height: view.1),
                        backingScale: scale, zoom: zoom, center: center)
    }

    private func expectClose(_ a: CGPoint, _ b: CGPoint, _ context: SourceLocation = #_sourceLocation) {
        #expect(abs(a.x - b.x) <= ε && abs(a.y - b.y) <= ε, "\(a) != \(b)", sourceLocation: context)
    }

    @Test func zoomKeepsAnchor() {
        let start = transform(image: (4000, 3000), view: (800, 600), zoom: 0.5,
                              center: CGPoint(x: 1000, y: 1000))
        // The start geometry itself, hand-checked: canvas (1000, 1000) at view (400, 300).
        expectClose(start.viewToCanvas(CGPoint(x: 400, y: 300)), CGPoint(x: 1000, y: 1000))

        let atCenter = start.zoomed(to: 1.0, anchoredAt: CGPoint(x: 400, y: 300))
        #expect(atCenter.zoom == 1.0)
        expectClose(atCenter.center, CGPoint(x: 1000, y: 1000))
        expectClose(atCenter.viewToCanvas(CGPoint(x: 400, y: 300)), CGPoint(x: 1000, y: 1000))

        // Anchor view (100, 50) → device (100, 550) with origin (−100, −200) → canvas (400, 1500).
        expectClose(start.viewToCanvas(CGPoint(x: 100, y: 50)), CGPoint(x: 400, y: 1500))
        let atCorner = start.zoomed(to: 2.0, anchoredAt: CGPoint(x: 100, y: 50))
        // center = (400 − (100−400)/2, 1500 − (550−300)/2) = (550, 1375).
        expectClose(atCorner.center, CGPoint(x: 550, y: 1375))
        expectClose(atCorner.viewToCanvas(CGPoint(x: 100, y: 50)), CGPoint(x: 400, y: 1500))
    }

    @Test func zoomKeepsAnchorRandomized() {
        var random = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0xA200_0000_0000_0004))
        for _ in 0..<500 {
            let width = random.int(in: 2000...20000)
            let height = random.int(in: 2000...20000)
            let viewWidth = Double(random.int(in: 400...1600))
            let viewHeight = Double(random.int(in: 400...1600))
            let scale = Double(1 + random.int(in: 0...1))
            let viewDeviceWidth = viewWidth * scale
            let viewDeviceHeight = viewHeight * scale
            // Start zoom in [8·fit, 32]: the zoomed image is larger than the view on both
            // axes, and the visible canvas stays inside the middle 50 % of the image, so no
            // clamp can move the center (the view half-extent ≤ one sixteenth of the image).
            let fit = max(viewDeviceWidth / Double(width), viewDeviceHeight / Double(height))
            let lower = min(8 * fit, 32)
            let startZoom = lower + (32 - lower) * fraction(&random)
            let endZoom = lower + (32 - lower) * fraction(&random)
            let start = transform(image: (width, height), view: (viewWidth, viewHeight),
                                  scale: scale, zoom: startZoom,
                                  center: CGPoint(x: Double(width) / 2, y: Double(height) / 2))
            // Anchor anywhere in the view (its canvas point is in the middle 50 %; check).
            let anchorView = CGPoint(x: random.double(in: 0...viewWidth),
                                     y: random.double(in: 0...viewHeight))
            let anchorCanvas = start.viewToCanvas(anchorView)
            #expect(anchorCanvas.x >= Double(width) * 0.25 - 1 &&
                    anchorCanvas.x <= Double(width) * 0.75 + 1, "\(random.comment) anchor x")
            #expect(anchorCanvas.y >= Double(height) * 0.25 - 1 &&
                    anchorCanvas.y <= Double(height) * 0.75 + 1, "\(random.comment) anchor y")

            let zoomed = start.zoomed(to: endZoom, anchoredAt: anchorView)
            let moved = zoomed.canvasToView(anchorCanvas)
            let slack = 0.5 / scale + 1e-9
            #expect(abs(moved.x - anchorView.x) <= slack, "\(random.comment) x")
            #expect(abs(moved.y - anchorView.y) <= slack, "\(random.comment) y")
            // The whole view shows image: every corner maps inside the image (within the
            // ≤ ½ device-pixel origin rounding: 0.5 / zoom canvas px).
            let cornerSlack = 0.5 / endZoom + 1e-9
            for corner in [CGPoint(x: 0, y: 0), CGPoint(x: viewWidth, y: 0),
                           CGPoint(x: 0, y: viewHeight), CGPoint(x: viewWidth, y: viewHeight)] {
                let canvas = zoomed.viewToCanvas(corner)
                #expect(canvas.x >= -cornerSlack && canvas.x <= Double(width) + cornerSlack,
                        "\(random.comment) corner x \(canvas)")
                #expect(canvas.y >= -cornerSlack && canvas.y <= Double(height) + cornerSlack,
                        "\(random.comment) corner y \(canvas)")
            }
        }
    }

    private func fraction(_ random: inout SeededRandom) -> Double {
        random.double(in: 0...1)
    }

    @Test func fittedToWindowCentersImage() {
        let large = transform(image: (4000, 3000), view: (800, 600), zoom: 1, center: .zero)
        let fitted = large.fittedToWindow()
        #expect(abs(fitted.zoom - 0.2) <= ε)
        #expect(abs(Double(fitted.imageOriginInDevice.x)) <= 1e-9)  // origin (0, 0)
        #expect(abs(Double(fitted.imageOriginInDevice.y)) <= 1e-9)
        expectClose(fitted.canvasToView(CGPoint(x: 2000, y: 1500)), CGPoint(x: 400, y: 300))
        expectClose(fitted.canvasToView(CGPoint(x: 0, y: 0)), CGPoint(x: 0, y: 600))
        expectClose(fitted.canvasToView(CGPoint(x: 4000, y: 3000)), CGPoint(x: 800, y: 0))

        let retina = transform(image: (4000, 3000), view: (800, 600), scale: 2, zoom: 1, center: .zero)
            .fittedToWindow()
        // Drawable 1600×1200 → fit 1600/4000 = 0.4.
        #expect(abs(retina.zoom - 0.4) <= ε)
        expectClose(retina.canvasToView(CGPoint(x: 2000, y: 1500)), CGPoint(x: 400, y: 300))
        expectClose(retina.canvasToView(CGPoint(x: 0, y: 0)), CGPoint(x: 0, y: 600))
        expectClose(retina.canvasToView(CGPoint(x: 4000, y: 3000)), CGPoint(x: 800, y: 0))

        let small = transform(image: (400, 300), view: (800, 600), zoom: 2, center: .zero)
            .fittedToWindow()
        #expect(small.zoom == 1.0)
        // Centered: origin (400 − 200, 300 − 150) = (200, 150).
        #expect(Double(small.imageOriginInDevice.x) == 200)
        #expect(Double(small.imageOriginInDevice.y) == 150)
        expectClose(small.canvasToView(CGPoint(x: 0, y: 0)), CGPoint(x: 200, y: 450))
        expectClose(small.canvasToView(CGPoint(x: 400, y: 300)), CGPoint(x: 600, y: 150))

        // The zoom equals `CanvasTransform.initial`'s for all three cases (CAN-6).
        for case let (image, view, scale) in [((4000, 3000), (800.0, 600.0), 1.0),
                                              ((4000, 3000), (800.0, 600.0), 2.0),
                                              ((400, 300), (800.0, 600.0), 1.0)] {
            let initial = CanvasTransform.initial(
                imageSize: PixelSize(width: image.0, height: image.1),
                viewSize: CGSize(width: view.0, height: view.1), backingScale: scale)
            let mine = transform(image: image, view: (view.0, view.1), scale: scale,
                                 zoom: 1, center: .zero).fittedToWindow()
            #expect(mine.zoom == initial.zoom)
        }
    }

    @Test func smallAxisStaysCentered() {
        // 100 image rows at zoom 1 fit inside 600 view rows → the y axis can't pan.
        let start = transform(image: (4000, 100), view: (800, 600), zoom: 1,
                              center: CGPoint(x: 2000, y: 50))
        #expect(abs(start.canvasToView(CGPoint(x: 0, y: 50)).y - 300) <= ε)
        let panned = start.panned(byView: CGVector(dx: -100, dy: 200))
        #expect(abs(panned.center.y - 50) <= ε)
        #expect(abs(panned.canvasToView(CGPoint(x: 0, y: 50)).y - 300) <= ε)
        // Content moved left 100: image column 2000 was at x 400, now at 300.
        #expect(abs(panned.canvasToView(CGPoint(x: 2000, y: 50)).x - 300) <= ε)
    }

    @Test func panMovesContent() {
        let start = transform(image: (4000, 3000), view: (800, 600), zoom: 1,
                              center: CGPoint(x: 1000, y: 1000))
        expectClose(start.canvasToView(CGPoint(x: 1000, y: 1000)), CGPoint(x: 400, y: 300))
        // Content follows the delta: right 50, down 30 → center = (1000 − 50, 1000 − 30).
        let panned = start.panned(byView: CGVector(dx: 50, dy: -30))
        expectClose(panned.center, CGPoint(x: 950, y: 970))
        expectClose(panned.canvasToView(CGPoint(x: 1000, y: 1000)), CGPoint(x: 450, y: 270))
    }

    @Test func panClampsAtEdges() {
        // Top-left limit: canvas (0, 0) exactly at the view's top-left corner.
        let topLeft = transform(image: (4000, 3000), view: (800, 600), zoom: 1,
                                center: CGPoint(x: 400, y: 300))
        expectClose(topLeft.viewToCanvas(CGPoint(x: 0, y: 600)), CGPoint(x: 0, y: 0))
        let pushedRightDown = topLeft.panned(byView: CGVector(dx: 100, dy: -100))
        expectClose(pushedRightDown.center, CGPoint(x: 400, y: 300))
        expectClose(pushedRightDown.viewToCanvas(CGPoint(x: 0, y: 600)), CGPoint(x: 0, y: 0))

        // Bottom-right limit.
        let bottomRight = transform(image: (4000, 3000), view: (800, 600), zoom: 1,
                                    center: CGPoint(x: 3600, y: 2700))
        expectClose(bottomRight.viewToCanvas(CGPoint(x: 800, y: 0)), CGPoint(x: 4000, y: 3000))
        let pushedLeftUp = bottomRight.panned(byView: CGVector(dx: -100, dy: 100))
        expectClose(pushedLeftUp.center, CGPoint(x: 3600, y: 2700))
    }

    @Test func tinyImage() {
        // 1×1 at 3200 %: the 32×32 device-pixel square stays centered; no panning possible.
        let start = transform(image: (1, 1), view: (800, 600), zoom: 32,
                              center: CGPoint(x: 0.5, y: 0.5))
            .clampedScroll()
        expectClose(start.center, CGPoint(x: 0.5, y: 0.5))
        #expect(Double(start.imageOriginInDevice.x) == 384)  // 400 − 0.5·32
        #expect(Double(start.imageOriginInDevice.y) == 284)  // 300 − 0.5·32
        expectClose(start.canvasToView(CGPoint(x: 0.5, y: 0.5)), CGPoint(x: 400, y: 300))
        let panned = start.panned(byView: CGVector(dx: 37, dy: 11))
        expectClose(panned.center, CGPoint(x: 0.5, y: 0.5))
    }

    @Test func resizeKeepsCenter() {
        let start = transform(image: (4000, 3000), view: (800, 600), zoom: 1,
                              center: CGPoint(x: 2000, y: 1500))
        let resized = start.resized(to: CGSize(width: 1000, height: 500))
        #expect(resized.viewSize == CGSize(width: 1000, height: 500))
        #expect(resized.zoom == 1)
        expectClose(resized.viewToCanvas(CGPoint(x: 500, y: 250)), CGPoint(x: 2000, y: 1500))
    }

    @Test func resizeReclamps() {
        // Bottom-right limit in 800×600; growing to 1000×800 pulls the limit in.
        let start = transform(image: (4000, 3000), view: (800, 600), zoom: 1,
                              center: CGPoint(x: 3600, y: 2700))
        let resized = start.resized(to: CGSize(width: 1000, height: 800))
        // halfX = 1000/2 = 500 → 4000 − 500 = 3500; halfY = 400 → 3000 − 400 = 2600.
        expectClose(resized.center, CGPoint(x: 3500, y: 2600))
        expectClose(resized.viewToCanvas(CGPoint(x: 1000, y: 0)), CGPoint(x: 4000, y: 3000))
    }

    @Test func zeroViewSizeIsNoOp() {
        let zero = transform(image: (4000, 3000), view: (0, 0), zoom: 2,
                             center: CGPoint(x: 1000, y: 1000))
        let scrolled = zero.clampedScroll()
        #expect(scrolled == zero)
        let fitted = zero.fittedToWindow()
        #expect(fitted.zoom == 1.0)
        #expect(fitted.center == CGPoint(x: 2000, y: 1500))
        let resized = transform(image: (4000, 3000), view: (800, 600), zoom: 2,
                                center: CGPoint(x: 1000, y: 1000))
            .resized(to: .zero)
        #expect(resized.viewSize == .zero)
        #expect(resized.zoom == 2)
        #expect(resized.center == CGPoint(x: 1000, y: 1000))
        for value in [scrolled, fitted, resized] {
            #expect(!value.center.x.isNaN && !value.center.y.isNaN)
            #expect(!value.viewToCanvas(CGPoint(x: 1, y: 1)).x.isNaN)
        }
    }

    @Test func panRoundTrip() {
        var random = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0xB400_0000_0000_0004))
        for _ in 0..<200 {
            let width = random.int(in: 4000...20000)
            let height = random.int(in: 4000...20000)
            let viewWidth = Double(random.int(in: 400...1200))
            let viewHeight = Double(random.int(in: 400...900))
            let scale = Double(1 + random.int(in: 0...1))
            let zoom = 1.0 + Double(random.int(in: 0...3))
            let halfX = viewWidth * scale / (2 * zoom)
            let halfY = viewHeight * scale / (2 * zoom)
            // Start and both round-trip legs stay strictly inside the clamp range, so no
            // leg is clamped and the round trip must be exact.
            let marginX = halfX + 200, marginY = halfY + 200
            let centerX = marginX + (Double(width) - 2 * marginX) * fraction(&random)
            let centerY = marginY + (Double(height) - 2 * marginY) * fraction(&random)
            let start = transform(image: (width, height), view: (viewWidth, viewHeight),
                                  scale: scale, zoom: zoom,
                                  center: CGPoint(x: centerX, y: centerY))
            let dx = Double(random.int(in: -100...100))
            let dy = Double(random.int(in: -100...100))
            let delta = CGVector(dx: dx, dy: dy)
            let forward = start.panned(byView: delta)
            // No clamp on either leg: the unclamped arithmetic is visible.
            expectClose(forward.center, CGPoint(
                x: start.center.x - dx * scale / zoom,
                y: start.center.y + dy * scale / zoom))
            let back = forward.panned(byView: CGVector(dx: -dx, dy: -dy))
            expectClose(back.center, start.center)
        }
    }

    // MARK: - Canvas-size changes (spec 0021)

    @Test func withImageSizeKeepsZoomAndRecenters() {
        let start = transform(image: (4000, 3000), view: (800, 600), zoom: 0.5,
                              center: CGPoint(x: 1000, y: 1000))
        // 1000×500 at zoom 0.5 → 500×250 device pixels, smaller than the 800×600 view:
        // centered, zoom kept (0004's `clampedScroll` centers a smaller image).
        let small = start.withImageSize(PixelSize(width: 1000, height: 500))
        #expect(small.zoom == 0.5)
        #expect(small.imageSize == PixelSize(width: 1000, height: 500))
        expectClose(small.center, CGPoint(x: 500, y: 250))
        expectClose(small.canvasToView(CGPoint(x: 500, y: 250)), CGPoint(x: 400, y: 300))

        // 3000×3000 at zoom 1 is larger than the view: center (1500, 1500) sits well
        // inside the clamp range, so the image center lands at the view center.
        let big = start.withImageSize(PixelSize(width: 3000, height: 3000))
        #expect(big.zoom == 0.5, "the zoom never changes (0021 / Open question 5)")
        #expect(big.center == CGPoint(x: 1500, y: 1500))
        expectClose(big.canvasToView(CGPoint(x: 1500, y: 1500)), CGPoint(x: 400, y: 300))
    }

    @Test func withImageSizeSameSizeIsIdentity() {
        // Panned away from center; a size that changes nothing must return `self`
        // exactly — no scroll jump for structure changes that keep the size.
        let start = transform(image: (4000, 3000), view: (800, 600), zoom: 2,
                              center: CGPoint(x: 1000, y: 2000))
        #expect(start.withImageSize(PixelSize(width: 4000, height: 3000)) == start)
    }
}
