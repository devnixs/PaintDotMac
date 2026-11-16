import CoreGraphics
import Foundation
import Testing
@testable import PaintDotMac

/// Unit tests for `CanvasTransform` (spec 0003, CAN-3/CAN-6). Every expected value is
/// hand-computed from the spec formulas, never produced by the code under test.
struct CanvasTransformTests {
    private func transform(image: PixelSize, view: CGSize, scale: Double,
                           zoom: Double = 1, center: CGPoint = .zero) -> CanvasTransform {
        CanvasTransform(imageSize: image, viewSize: view, backingScale: scale, zoom: zoom, center: center)
    }

    // MARK: - Initial zoom (CAN-6, D-29)

    @Test func initialZoomSmallImageIs100Percent() {
        let oneX = CanvasTransform.initial(
            imageSize: PixelSize(width: 800, height: 600), viewSize: CGSize(width: 1000, height: 800),
            backingScale: 1
        )
        #expect(oneX.zoom == 1.0)
        #expect(oneX.center == CGPoint(x: 400, y: 300))
        let twoX = CanvasTransform.initial(
            imageSize: PixelSize(width: 800, height: 600), viewSize: CGSize(width: 1000, height: 800),
            backingScale: 2
        )
        // drawable 2000×1600 ≥ image → still 100 %.
        #expect(twoX.zoom == 1.0)
    }

    @Test func initialZoomLargeImageFits1x() {
        // min(1000/4000, 800/3000) = min(0.25, 0.2666…) = 0.25
        let t = CanvasTransform.initial(
            imageSize: PixelSize(width: 4000, height: 3000), viewSize: CGSize(width: 1000, height: 800),
            backingScale: 1
        )
        #expect(t.zoom == 0.25)
        #expect(t.center == CGPoint(x: 2000, y: 1500))
    }

    @Test func initialZoomLargeImageFits2x() {
        // drawable 2000×1600: min(2000/4000, 1600/3000) = min(0.5, 0.5333…) = 0.5
        let t = CanvasTransform.initial(
            imageSize: PixelSize(width: 4000, height: 3000), viewSize: CGSize(width: 1000, height: 800),
            backingScale: 2
        )
        #expect(t.zoom == 0.5)
    }

    @Test func initialZoomClampsToOnePercent() {
        // fit = 100/65535 ≈ 0.001526 → clamped to 0.01.
        let t = CanvasTransform.initial(
            imageSize: PixelSize(width: 65_535, height: 65_535), viewSize: CGSize(width: 100, height: 100),
            backingScale: 1
        )
        #expect(t.zoom == 0.01)
    }

    @Test func initialZoomWideImage() {
        // fit = 1000/65535 ≈ 0.015259 — above 1 %, no clamp.
        let t = CanvasTransform.initial(
            imageSize: PixelSize(width: 65_535, height: 1), viewSize: CGSize(width: 1000, height: 800),
            backingScale: 1
        )
        #expect(abs(t.zoom - 1000.0 / 65_535.0) <= 1e-12)
    }

    @Test func initialZoomDegenerateViewIs100Percent() {
        let t = CanvasTransform.initial(
            imageSize: PixelSize(width: 800, height: 600), viewSize: .zero, backingScale: 1
        )
        #expect(t.zoom == 1.0)
        #expect(t.drawableSize.width == 0)
        #expect(t.drawableSize.height == 0)
    }

    @Test func initialZoomNotSnappedToPreset() {
        // 3000×2000 in a 1024×768 view: fit = min(1024/3000, 768/2000) = 1024/3000 = 0.3413…
        // — between presets, kept exactly.
        let t = CanvasTransform.initial(
            imageSize: PixelSize(width: 3000, height: 2000), viewSize: CGSize(width: 1024, height: 768),
            backingScale: 1
        )
        #expect(t.zoom == 1024.0 / 3000.0)
    }

    // MARK: - setZoom / zoomPercent

    @Test func setZoomClamps() {
        var t = transform(image: PixelSize(width: 10, height: 10), view: CGSize(width: 100, height: 100), scale: 1)
        t.setZoom(0.001)
        #expect(t.zoom == 0.01)
        t.setZoom(100)
        #expect(t.zoom == 32)
        t.setZoom(.nan)
        #expect(t.zoom == 32)
        t.setZoom(.infinity)
        #expect(t.zoom == 32)
        t.setZoom(0)
        #expect(t.zoom == 32)
        t.setZoom(-1)
        #expect(t.zoom == 32)
    }

    @Test func zoomPercentRounds() {
        func percent(_ zoom: Double) -> Int {
            transform(image: PixelSize(width: 10, height: 10), view: CGSize(width: 100, height: 100),
                      scale: 1, zoom: zoom).zoomPercent
        }
        #expect(percent(1.0) == 100)
        #expect(percent(0.6667) == 67)
        #expect(percent(0.01) == 1)
        #expect(percent(32) == 3200)
        #expect(percent(0.125) == 13)  // 12.5 rounds away from zero
    }

    /// `drawableSize` is `Int((view · backingScale).rounded())` — hand values for fractional
    /// point sizes (the product is rounded to the nearest device pixel, not truncated).
    @Test func drawableSizeRoundsFractionalPoints() {
        let t = transform(image: PixelSize(width: 10, height: 10),
                          view: CGSize(width: 3.3, height: 7.9), scale: 2)
        #expect(t.drawableSize.width == 7)    // 6.6 → 7
        #expect(t.drawableSize.height == 16)  // 15.8 → 16
        let oneX = transform(image: PixelSize(width: 10, height: 10),
                             view: CGSize(width: 1000.4, height: 999.5), scale: 1)
        #expect(oneX.drawableSize.width == 1000)  // 1000.4 → 1000
        #expect(oneX.drawableSize.height == 1000) // 999.5 → 1000 (ties away from zero)
    }

    // MARK: - Pixel-aligned origin (CAN-6)

    @Test func originIsPixelAligned1x() {
        // ox = 1000/2 − 400·1 = 100; oy = 800/2 − 300·1 = 100.
        let t = transform(image: PixelSize(width: 800, height: 600), view: CGSize(width: 1000, height: 800),
                          scale: 1, zoom: 1, center: CGPoint(x: 400, y: 300))
        let origin = t.imageOriginInDevice
        #expect(origin.x == 100)
        #expect(origin.y == 100)
    }

    @Test func originIsPixelAligned2x() {
        // ox = 2000/2 − 400 = 600; oy = 1600/2 − 300 = 500.
        let t = transform(image: PixelSize(width: 800, height: 600), view: CGSize(width: 1000, height: 800),
                          scale: 2, zoom: 1, center: CGPoint(x: 400, y: 300))
        let origin = t.imageOriginInDevice
        #expect(origin.x == 600)
        #expect(origin.y == 500)
    }

    @Test func originIsPixelAlignedOddSize() {
        // ox = 500 − 400.5 = 99.5 → 100 (rounded, ties away from zero); oy = 99.5 → 100.
        let t = transform(image: PixelSize(width: 801, height: 601), view: CGSize(width: 1000, height: 800),
                          scale: 1, zoom: 1, center: CGPoint(x: 400.5, y: 300.5))
        let origin = t.imageOriginInDevice
        #expect(origin.x == 100)
        #expect(origin.y == 100)
    }

    @Test func originIsPixelAlignedZoom2At2x() {
        // ox = 1000 − 400·2 = 200; oy = 800 − 300·2 = 200.
        let t = transform(image: PixelSize(width: 800, height: 600), view: CGSize(width: 1000, height: 800),
                          scale: 2, zoom: 2, center: CGPoint(x: 400, y: 300))
        let origin = t.imageOriginInDevice
        #expect(origin.x == 200)
        #expect(origin.y == 200)
    }

    // MARK: - Hand-value conversions

    private var hand1x: CanvasTransform {
        transform(image: PixelSize(width: 800, height: 600), view: CGSize(width: 1000, height: 800),
                  scale: 1, zoom: 1, center: CGPoint(x: 400, y: 300))   // origin (100, 100)
    }

    @Test func viewToCanvasHandValues1x() {
        let t = hand1x
        #expect(t.viewToCanvas(CGPoint(x: 100, y: 700)) == CGPoint(x: 0, y: 0))
        let half = t.viewToCanvas(CGPoint(x: 100.5, y: 699.5))
        #expect(half == CGPoint(x: 0.5, y: 0.5))
        #expect(t.viewToPixel(CGPoint(x: 100.5, y: 699.5)) == PixelPoint(x: 0, y: 0))
        let left = t.viewToCanvas(CGPoint(x: 99.9, y: 700))
        #expect(abs(left.x - (-0.1)) <= 1e-12)
        #expect(left.y == 0)
        // floor, not truncation: −0.1 → pixel −1.
        #expect(t.viewToPixel(CGPoint(x: 99.9, y: 700)) == PixelPoint(x: -1, y: 0))
        // Bottom-right corner: exactly outside (800, 600), not clamped.
        let corner = t.viewToCanvas(CGPoint(x: 900, y: 100))
        #expect(corner == CGPoint(x: 800, y: 600))
        #expect(t.viewToPixel(CGPoint(x: 900, y: 100)) == PixelPoint(x: 800, y: 600))
    }

    @Test func viewToCanvasHandValues2x() {
        let t = transform(image: PixelSize(width: 800, height: 600), view: CGSize(width: 1000, height: 800),
                          scale: 2, zoom: 1, center: CGPoint(x: 400, y: 300))   // origin (600, 500)
        #expect(t.viewToCanvas(CGPoint(x: 300, y: 550)) == CGPoint(x: 0, y: 0))
        let half = t.viewToCanvas(CGPoint(x: 300.25, y: 549.75))
        #expect(half == CGPoint(x: 0.5, y: 0.5))
        // Half a point is one image pixel at 100 % on Retina.
        let next = t.viewToCanvas(CGPoint(x: 300.5, y: 550))
        #expect(abs(next.x - 1) <= 1e-12)
        #expect(next.y == 0)
    }

    @Test func viewToCanvasZoom2At2x() {
        let t = transform(image: PixelSize(width: 800, height: 600), view: CGSize(width: 1000, height: 800),
                          scale: 2, zoom: 2, center: CGPoint(x: 400, y: 300))   // origin (200, 200)
        #expect(t.viewToCanvas(CGPoint(x: 100, y: 700)) == CGPoint(x: 0, y: 0))
        #expect(t.viewToCanvas(CGPoint(x: 101, y: 700)) == CGPoint(x: 1, y: 0))
        #expect(t.viewToCanvas(CGPoint(x: 100.5, y: 700)) == CGPoint(x: 0.5, y: 0))
    }

    @Test func viewToCanvasZoomedOut() {
        // origin: ox = 500 − 2000·0.25 = 0; oy = 400 − 1500·0.25 = 25.
        let t = transform(image: PixelSize(width: 4000, height: 3000), view: CGSize(width: 1000, height: 800),
                          scale: 1, zoom: 0.25, center: CGPoint(x: 2000, y: 1500))
        let origin = t.imageOriginInDevice
        #expect(origin.x == 0)
        #expect(origin.y == 25)
        let zero = t.viewToCanvas(CGPoint(x: 0, y: 775))
        #expect(abs(zero.x - 0) <= 1e-12)
        #expect(abs(zero.y - 0) <= 1e-12)
        let right = t.viewToCanvas(CGPoint(x: 1, y: 775))
        #expect(abs(right.x - 4) <= 1e-12)  // 1 / 0.25
        #expect(abs(right.y - 0) <= 1e-12)
    }

    @Test func yAxisIsFlipped() {
        let t = hand1x
        var lastCanvasY = Double.infinity
        for viewY in [0.0, 100.0, 400.0, 700.0, 799.0] {
            let canvasY = t.viewToCanvas(CGPoint(x: 500, y: viewY)).y
            #expect(canvasY < lastCanvasY)
            lastCanvasY = canvasY
        }
    }

    @Test func pixelRectToViewAt2x() {
        let t = transform(image: PixelSize(width: 800, height: 600), view: CGSize(width: 1000, height: 800),
                          scale: 2, zoom: 1, center: CGPoint(x: 400, y: 300))   // origin (600, 500)
        // Canvas (0,0)-(1,1) → device (600,500)-(601,501) → view x 300…300.5,
        // y (800 − 500/2) = 550 down to (800 − 501/2) = 549.5.
        #expect(t.pixelRectToView(PixelRect(x: 0, y: 0, width: 1, height: 1))
                == CGRect(x: 300, y: 549.5, width: 0.5, height: 0.5))
        let zoom4 = transform(image: PixelSize(width: 800, height: 600), view: CGSize(width: 1000, height: 800),
                              scale: 1, zoom: 4, center: CGPoint(x: 400, y: 300))
        #expect(zoom4.pixelRectToView(PixelRect(x: 0, y: 0, width: 1, height: 1)).size == CGSize(width: 4, height: 4))
    }

    // MARK: - Property tests

    /// Round-trip exactness. Expected relation from the spec: `canvasToView(viewToCanvas(p)) ≈ p`
    /// and the reverse, within 1e-9 **relative** to the magnitudes the conversions pass
    /// through (the device-space intermediates `ox + c·zoom`, bounded by origin + drawable) —
    /// absolute error scales with those, and `zoom` divides/multiplies them.
    @Test func roundTripProperty() {
        let seed = SeededRandom.resolvedSeed(default: 0x51EED)
        var random = SeededRandom(seed: seed)
        let scales: [Double] = [1, 2, 3]
        for _ in 0..<1000 {
            let image = PixelSize(width: random.int(in: 1...65_535), height: random.int(in: 1...65_535))
            let view = CGSize(width: CGFloat(random.int(in: 1...3000)), height: CGFloat(random.int(in: 1...3000)))
            let scale = scales[random.int(in: 0...2)]
            // Log-uniform over the full [0.01, 32] zoom range.
            let fraction = Double(random.next() % 1_000_000) / 1_000_000
            let zoom = 0.01 * pow(3200.0, fraction)
            let center = CGPoint(x: Double(random.int(in: 0...image.width)),
                                 y: Double(random.int(in: 0...image.height)))
            let t = CanvasTransform(imageSize: image, viewSize: view, backingScale: scale,
                                    zoom: zoom, center: center)
            let point = CGPoint(x: Double(random.int(in: 0...Int(view.width))) + 0.25,
                                y: Double(random.int(in: 0...Int(view.height))) + 0.75)
            let canvasPoint = CGPoint(x: Double(random.int(in: 0...image.width)) + 0.5,
                                      y: Double(random.int(in: 0...image.height)) + 0.5)
            let origin = t.imageOriginInDevice
            let drawable = t.drawableSize
            // Intermediates stay within these magnitudes; scale the relative check to them.
            let magnitude = max(1, abs(point.x), abs(point.y),
                                (abs(Double(origin.x)) + Double(drawable.width)) / scale,
                                (abs(Double(origin.y)) + Double(drawable.height)) / scale)
            let tolerance = 1e-9 * magnitude

            let back = t.canvasToView(t.viewToCanvas(point))
            #expect(abs(back.x - point.x) <= tolerance, "view→canvas→view x \(random.comment)")
            #expect(abs(back.y - point.y) <= tolerance, "view→canvas→view y \(random.comment)")
            let backCanvas = t.viewToCanvas(t.canvasToView(canvasPoint))
            #expect(abs(backCanvas.x - canvasPoint.x) <= 1e-9 * max(1, abs(canvasPoint.x)),
                    "canvas→view→canvas x \(random.comment)")
            #expect(abs(backCanvas.y - canvasPoint.y) <= 1e-9 * max(1, abs(canvasPoint.y)),
                    "canvas→view→canvas y \(random.comment)")
            // The rounded origin: integer, within half a device pixel of the exact value.
            #expect(abs(Double(origin.x) - (Double(drawable.width) / 2 - center.x * zoom)) <= 0.5,
                    "origin x \(random.comment)")
            #expect(abs(Double(origin.y) - (Double(drawable.height) / 2 - center.y * zoom)) <= 0.5,
                    "origin y \(random.comment)")
        }
    }

    /// At integer zoom `n` every integer canvas corner maps to an integer device point, so
    /// each image pixel covers an exact `n × n` block of whole device pixels (CAN-6).
    @Test func integerZoomBlocksAlign() {
        for scale in [1.0, 2.0] {
            for zoom in [1.0, 2.0, 3.0, 7.0, 32.0] {
                let t = CanvasTransform(imageSize: PixelSize(width: 600, height: 400),
                                        viewSize: CGSize(width: 320, height: 240),
                                        backingScale: scale, zoom: zoom,
                                        center: CGPoint(x: 300, y: 200))
                for pixel in stride(from: -20, through: 640, by: 37) {
                    // Integer pixel corners (image pixel (i, j) starts at canvas (i, j)).
                    let device = t.canvasToDevice(CGPoint(x: Double(pixel), y: Double(pixel)))
                    #expect(device.x == device.x.rounded(), "x at zoom \(zoom) scale \(scale)")
                    #expect(device.y == device.y.rounded(), "y at zoom \(zoom) scale \(scale)")
                }
            }
        }
    }

    // MARK: - drawnImageRectInDevice

    @Test func drawnImageRect() {
        // 3×2 at zoom 4/3, origin (10, 10): 3·4/3 = 4 → ceil 4; 2·4/3 = 2.667 → ceil 3.
        // center (7.5, 7.5): ox = 20 − 7.5·4/3 = 10; oy = 10.
        let t = transform(image: PixelSize(width: 3, height: 2), view: CGSize(width: 40, height: 40),
                          scale: 1, zoom: 4.0 / 3.0, center: CGPoint(x: 7.5, y: 7.5))
        #expect(t.imageOriginInDevice.x == 10)
        #expect(t.drawnImageRectInDevice == PixelRect(x: 10, y: 10, width: 4, height: 3))
    }

    @Test func drawnImageRectClippedToDrawable() {
        // ox = 20 − (−13.5)·4/3 = 20 + 18 = 38 → rect x 38…42 clipped to 38…40.
        let t = transform(image: PixelSize(width: 3, height: 2), view: CGSize(width: 40, height: 40),
                          scale: 1, zoom: 4.0 / 3.0, center: CGPoint(x: -13.5, y: 7.5))
        #expect(t.imageOriginInDevice.x == 38)
        #expect(t.drawnImageRectInDevice == PixelRect(x: 38, y: 10, width: 2, height: 3))
    }

    @Test func drawnImageRectEmptyWhenScrolledOut() {
        // ox = 20 + 400·4/3 = 553 → far right of the 40-px drawable.
        let t = transform(image: PixelSize(width: 3, height: 2), view: CGSize(width: 40, height: 40),
                          scale: 1, zoom: 4.0 / 3.0, center: CGPoint(x: 420, y: 7.5))
        #expect(t.drawnImageRectInDevice.isEmpty)
    }

    // MARK: - visibleTileRange

    @Test func visibleTileRangeWholeSmallImage() throws {
        // 800×600 at 100 % in a 1000×800 view: canvas [−100…900] × [−100…700] clipped to
        // the image → columns 0…3, rows 0…2 → 12 tiles.
        let t = transform(image: PixelSize(width: 800, height: 600), view: CGSize(width: 1000, height: 800),
                          scale: 1, zoom: 1, center: CGPoint(x: 400, y: 300))
        let range = try #require(t.visibleTileRange)
        #expect(range.columns == 0...3)
        #expect(range.rows == 0...2)
        #expect(range.count == 12)
        #expect(range.coordinates.first == TileCoordinate(column: 0, row: 0))
        // Row-major: after (3, 0) comes (0, 1).
        #expect(range.coordinates[3] == TileCoordinate(column: 3, row: 0))
        #expect(range.coordinates[4] == TileCoordinate(column: 0, row: 1))
        let inside = range.contains(TileCoordinate(column: 3, row: 2))
        let outside = range.contains(TileCoordinate(column: 4, row: 2))
        #expect(inside)
        #expect(!outside)
    }

    @Test func visibleTileRangeZoomedIn() throws {
        // 2048² at zoom 1, center (1024, 1024), 512×512 view: canvas (768…1280)² → 4 tiles.
        let t = transform(image: PixelSize(width: 2048, height: 2048), view: CGSize(width: 512, height: 512),
                          scale: 1, zoom: 1, center: CGPoint(x: 1024, y: 1024))
        let range = try #require(t.visibleTileRange)
        #expect(range.columns == 3...4)
        #expect(range.rows == 3...4)
        #expect(range.count == 4)
    }

    @Test func visibleTileRangeImageSmallerThanTile() throws {
        let t = transform(image: PixelSize(width: 64, height: 48), view: CGSize(width: 256, height: 256),
                          scale: 1, zoom: 1, center: CGPoint(x: 32, y: 24))
        let range = try #require(t.visibleTileRange)
        #expect(range.coordinates == [TileCoordinate(column: 0, row: 0)])
    }

    @Test func visibleTileRangeHugeImageAtOnePercent() throws {
        // Fully visible 65 535² at 1 %: 256 columns × 256 rows = 65 536 tiles.
        let t = transform(image: PixelSize(width: 65_535, height: 65_535),
                          view: CGSize(width: 6600, height: 6600),
                          scale: 1, zoom: 0.01, center: CGPoint(x: 32_767.5, y: 32_767.5))
        let range = try #require(t.visibleTileRange)
        #expect(range.count == 65_536)
        #expect(range.columns == 0...255)
        #expect(range.rows == 0...255)
    }

    @Test func visibleTileRangeNilFarOutside() {
        let t = transform(image: PixelSize(width: 100, height: 100), view: CGSize(width: 50, height: 50),
                          scale: 1, zoom: 1, center: CGPoint(x: -10_000, y: -10_000))
        #expect(t.visibleTileRange == nil)
    }

    @Test func visibleTileRangeExactBoundaryExcludesNextColumn() throws {
        // Visible canvas rect x ∈ [−1, 511.5)… use a center so maxX lands exactly on 512:
        // origin.x = 0 → visible [0…dw/zoom]; with view 128×128 @1, zoom 4: maxX = 32 — pick
        // instead: zoom 1, view 512×512, origin (0, 0) → canvas maxX = 512 exactly.
        let t = transform(image: PixelSize(width: 800, height: 600), view: CGSize(width: 512, height: 512),
                          scale: 1, zoom: 1, center: CGPoint(x: 256, y: 256))
        #expect(t.visibleCanvasRect.maxX == 512)
        let range = try #require(t.visibleTileRange)
        #expect(range.columns == 0...1)  // column 2 starts at x = 512 and is not touched
    }

    // MARK: - Helpers used by other suites

    /// `visibleCanvasRect` covers the whole view.
    @Test func visibleCanvasRectCoversView() {
        let t = transform(image: PixelSize(width: 800, height: 600), view: CGSize(width: 1000, height: 800),
                          scale: 2, zoom: 1, center: CGPoint(x: 400, y: 300))
        // drawable 2000×1600 at zoom 1, origin (600, 500): device (0…2000) → canvas
        // x ∈ [−600, 1400], y ∈ [−500, 1100] (canvas units are image pixels, not points).
        #expect(t.visibleCanvasRect == CGRect(x: -600, y: -500, width: 2000, height: 1600))
    }

    // MARK: - canvasToViewAffine (spec 0013)

    @Test func canvasToViewAffineMatchesFunction() {
        var rng = SeededRandom(seed: 0x0013_AF11E)
        for zoom in [0.01, 0.5, 1.0, 3.0, 32.0] {
            for backing in [1.0, 2.0] {
                let t = CanvasTransform(
                    imageSize: PixelSize(width: 4000, height: 3000),
                    viewSize: CGSize(width: 1000, height: 800),
                    backingScale: backing, zoom: zoom,
                    center: CGPoint(x: rng.double(in: 0...4000), y: rng.double(in: 0...3000)))
                let affine = t.canvasToViewAffine
                for _ in 0..<100 {
                    let p = CGPoint(x: rng.double(in: -100...4100),
                                    y: rng.double(in: -100...3100))
                    let viaAffine = p.applying(affine)
                    let viaFunction = t.canvasToView(p)
                    #expect(abs(viaAffine.x - viaFunction.x) < 1e-9
                            && abs(viaAffine.y - viaFunction.y) < 1e-9,
                            "zoom \(zoom) backing \(backing) at \(p): \(viaAffine) vs \(viaFunction)")
                }
            }
        }
    }
}
