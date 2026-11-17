import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `PastePlanner` — the E-6 decision, viewport placement, and the canvas expansion
/// snapshot (spec 0021 *Test plan*, unit).
struct PastePlannerTests {
    private let canvas = PixelSize(width: 800, height: 600)

    @Test func needsExpansionPrompt() {
        func needs(_ w: Int, _ h: Int) -> Bool {
            PastePlanner.needsExpansionPrompt(clipboardSize: PixelSize(width: w, height: h),
                                              canvasSize: canvas)
        }
        #expect(needs(800, 600) == false, "exact size never prompts (strict >)")
        #expect(needs(801, 600) == true)
        #expect(needs(800, 601) == true)
        #expect(needs(10, 10) == false)
    }

    @Test func placementTopLeftVisible() {
        let plan = PastePlanner.plan(clipboardSize: PixelSize(width: 50, height: 40),
                                     canvasSize: canvas,
                                     visibleCanvasRect: CGRect(x: -50, y: -20, width: 1000, height: 800),
                                     choice: nil)
        #expect(plan.origin == PixelPoint(x: 0, y: 0))
        #expect(plan.newCanvasSize == nil)
    }

    @Test func placementZoomedIn() {
        let plan = PastePlanner.plan(clipboardSize: PixelSize(width: 50, height: 40),
                                     canvasSize: canvas,
                                     visibleCanvasRect: CGRect(x: 300.7, y: 120.2, width: 100, height: 80),
                                     choice: nil)
        #expect(plan.origin == PixelPoint(x: 300, y: 120), "floor of the visible top-left")
        #expect(plan.pastedRect == PixelRect(x: 300, y: 120, width: 50, height: 40))
    }

    @Test func placementVisibleBeyondCanvas() {
        let plan = PastePlanner.plan(clipboardSize: PixelSize(width: 50, height: 40),
                                     canvasSize: canvas,
                                     visibleCanvasRect: CGRect(x: 900, y: 700, width: 50, height: 50),
                                     choice: nil)
        #expect(plan.origin == PixelPoint(x: 799, y: 599), "clamped to the last canvas pixel")
    }

    @Test func placementTopLeftEdgeInclusive() {
        let plan = PastePlanner.plan(clipboardSize: PixelSize(width: 5, height: 5),
                                     canvasSize: canvas,
                                     visibleCanvasRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                     choice: nil)
        #expect(plan.origin == PixelPoint(x: 0, y: 0), "closed on the top-left edges")
    }

    /// Placement fed through real `CanvasTransform.visibleCanvasRect` values at the
    /// zoom extremes (800 %, 25 %, 100 % panned both ways): the numbers are derived
    /// by hand from 0004's rule `visible = center ∓ drawable ÷ (2·zoom)` — view
    /// 800×600 pt at backing scale 2 → drawable 1600×1200 device px.
    @Test func placementFollowsViewportAtZoomExtremes() {
        let big = PixelSize(width: 4000, height: 3000)
        func origin(zoom: Double, center: CGPoint) -> PixelPoint {
            let transform = CanvasTransform(
                imageSize: big, viewSize: CGSize(width: 800, height: 600),
                backingScale: 2, zoom: zoom, center: center)
            return PastePlanner.plan(clipboardSize: PixelSize(width: 40, height: 30),
                                     canvasSize: big,
                                     visibleCanvasRect: transform.visibleCanvasRect,
                                     choice: nil).origin
        }
        // 800 %: half-extents 1600 ÷ 16 × 1200 ÷ 16 = 100 × 75 → visible (1400, 925, …).
        #expect(origin(zoom: 8, center: CGPoint(x: 1500, y: 1000)) == PixelPoint(x: 1400, y: 925))
        // 25 %: half-extents 3200 × 2400 — the canvas top-left is far inside the
        // (negative-min) visible rect → (0, 0).
        #expect(origin(zoom: 0.25, center: CGPoint(x: 1500, y: 1000)) == PixelPoint(x: 0, y: 0))
        // 100 % panned so (0, 0) shows at the top-left: visible minX = −700 → (0, 0).
        #expect(origin(zoom: 1, center: CGPoint(x: 100, y: 80)) == PixelPoint(x: 0, y: 0))
        // 100 % panned to the middle: half 800 × 600 → visible (700, 300, …) → (700, 300).
        #expect(origin(zoom: 1, center: CGPoint(x: 1500, y: 900)) == PixelPoint(x: 700, y: 300))
    }

    /// A corrupt transform (NaN / infinite / astronomical coordinates) can never
    /// trap or place the paste outside the canvas (`Int(1e300)` traps — the clamp
    /// runs on the Double before the conversion).
    @Test func placementNonFiniteVisibleRectStaysInCanvas() {
        func origin(_ rect: CGRect) -> PixelPoint {
            PastePlanner.plan(clipboardSize: PixelSize(width: 5, height: 5), canvasSize: canvas,
                              visibleCanvasRect: rect, choice: nil).origin
        }
        let nan = origin(CGRect(x: CGFloat.nan, y: CGFloat.infinity, width: 10, height: 10))
        #expect(nan == PixelPoint(x: canvas.width - 1, y: canvas.height - 1),
                "non-finite lands on the last canvas pixel")
        let huge = origin(CGRect(x: 1e300, y: -1e300, width: 1e308, height: 10))
        #expect(huge == PixelPoint(x: canvas.width - 1, y: 0), "finite-but-absurd clamps, never traps")
        let tiny = origin(CGRect(x: -1e300, y: -0.5, width: 10, height: 10))
        #expect(tiny == PixelPoint(x: 0, y: 0))
    }

    @Test func expandPlan() {
        let plan = PastePlanner.plan(clipboardSize: PixelSize(width: 1000, height: 500),
                                     canvasSize: canvas,
                                     visibleCanvasRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                                     choice: .expandCanvas)
        #expect(plan.newCanvasSize == PixelSize(width: 1000, height: 600))
        #expect(plan.origin == PixelPoint(x: 0, y: 0))
        #expect(plan.pastedRect == PixelRect(x: 0, y: 0, width: 1000, height: 500))
    }

    @Test func keepPlan() {
        let plan = PastePlanner.plan(clipboardSize: PixelSize(width: 1000, height: 500),
                                     canvasSize: canvas,
                                     visibleCanvasRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                                     choice: .keepCanvasSize)
        #expect(plan.newCanvasSize == nil)
        #expect(plan.origin == PixelPoint(x: 0, y: 0))
    }

    /// Only one side larger (900×100 onto 800×600) still prompts and expands to 900×600.
    @Test func expandOneSide() {
        #expect(PastePlanner.needsExpansionPrompt(clipboardSize: PixelSize(width: 900, height: 100),
                                                  canvasSize: canvas))
        let plan = PastePlanner.plan(clipboardSize: PixelSize(width: 900, height: 100),
                                     canvasSize: canvas,
                                     visibleCanvasRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                                     choice: .expandCanvas)
        #expect(plan.newCanvasSize == PixelSize(width: 900, height: 600))
    }

    @Test func expandedStateFillsBottomLayer() throws {
        let bottom = TestImages.surface(width: 300, height: 200) { _, _ in
            ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        }
        var top = TiledSurface(size: PixelSize(width: 300, height: 200))
        top.setPixel(ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255),
                     at: PixelPoint(x: 299, y: 199))
        let image = LayeredImage(
            size: PixelSize(width: 300, height: 200), dpi: 72,
            layers: [
                Layer(name: "Background", surface: bottom, isVisible: false, opacity: 128,
                      blendMode: .normal),
                Layer(name: "Layer 1", surface: top),
            ], activeLayerIndex: 1)
        var state = DocumentState(image: image)
        state.selection = try #require(
            Selection(rect: CGRect(x: 0, y: 0, width: 10, height: 10), canvasSize: image.size)
                as Selection?)
        let green = ColorRGBA8(red: 0, green: 255, blue: 0, alpha: 255)
        let expanded = try PastePlanner.expandedState(state, to: PixelSize(width: 600, height: 300),
                                                      background: green, limits: .standard)

        #expect(expanded.image.size == PixelSize(width: 600, height: 300))
        let newBottom = expanded.image.layers[0].surface
        let newTop = expanded.image.layers[1].surface
        // Bottom: the old area keeps its pixels, the new area is the background color.
        for point in [PixelPoint(x: 0, y: 0), PixelPoint(x: 299, y: 199)] {
            #expect(newBottom.pixel(at: point) == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        }
        #expect(newBottom.pixel(at: PixelPoint(x: 300, y: 0)) == green)
        #expect(newBottom.pixel(at: PixelPoint(x: 0, y: 200)) == green)
        #expect(newBottom.pixel(at: PixelPoint(x: 599, y: 299)) == green)
        // Top: existing pixels stay, the new area stays transparent.
        #expect(newTop.pixel(at: PixelPoint(x: 299, y: 199))
                == ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255))
        #expect(newTop.pixel(at: PixelPoint(x: 300, y: 0)) == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0))

        // Structure is untouched: ids, names, opacity, visibility, blend mode, active
        // layer, dpi; only the selection is dropped.
        #expect(expanded.image.layers.map { $0.id } == image.layers.map { $0.id })
        #expect(expanded.image.layers.map { $0.name } == ["Background", "Layer 1"])
        #expect(expanded.image.layers[0].opacity == 128)
        #expect(expanded.image.layers[0].isVisible == false)
        #expect(expanded.image.layers[0].blendMode == .normal)
        #expect(expanded.image.activeLayerIndex == 1)
        #expect(expanded.image.dpi == 72)
        #expect(expanded.selection == nil)
        #expect(expanded.floatingPixels == nil)
    }

    @Test func expandedStateRespectsLimits() throws {
        let state = DocumentState(image: LayeredImage.blank(size: PixelSize(width: 4, height: 4),
                                                            fill: .white))
        #expect(throws: ImageLimitError.exceedsMemoryCap(requiredBytes: 40_000, capBytes: 1_000),
                performing: {
                    _ = try PastePlanner.expandedState(state, to: PixelSize(width: 100, height: 100),
                                                       background: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255),
                                                       limits: ImageLimits(memoryCapBytes: 1_000))
                })
        // Nothing changed on the throw path.
        #expect(state.image.size == PixelSize(width: 4, height: 4))
    }
}
