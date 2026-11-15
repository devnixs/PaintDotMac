import AppKit
import Testing
@testable import PaintDotMac

/// 0004's `CanvasNavigation` behind the 0006 `CanvasNavigating` protocol (spec 0006
/// *Test plan*): anchor-preserving zoom and content-following pan, asserted on the real
/// transform through the existential the tools see.
@MainActor
struct CanvasNavigationConformanceTests {
    /// The 0006 test geometry: image 4000×3000, view 800×600 pt, backing scale 1, zoom 1,
    /// centered — built the way 0004's tests build it (offscreen view, no window).
    private func makeNavigation() throws -> (any CanvasNavigating, CanvasView) {
        let canvasView = CanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        #expect(canvasView.isMetalAvailable)
        canvasView.transform = CanvasTransform(
            imageSize: PixelSize(width: 4000, height: 3000),
            viewSize: CGSize(width: 800, height: 600),
            backingScale: 1,
            zoom: 1,
            center: CGPoint(x: 2000, y: 1500)
        )
        let statusBar = StatusBarModel(imageSize: PixelSize(width: 4000, height: 3000),
                                       dpi: 96, zoom: 1)
        let navigation = CanvasNavigation(canvasView: canvasView, statusBar: statusBar)
        return (navigation, canvasView)
    }

    @Test func anchoredZoomThroughTheExistential() throws {
        let (navigation, canvasView) = try makeNavigation()
        let anchor = CGPoint(x: 100, y: 100)
        let canvasPointBefore = canvasView.transform.viewToCanvas(anchor)
        navigation.setZoom(2, anchoredAtView: anchor)
        let transform = navigation.transform
        #expect(transform.zoom == 2)
        let canvasPointAfter = transform.viewToCanvas(anchor)
        #expect(abs(canvasPointAfter.x - canvasPointBefore.x) < 1e-9)
        #expect(abs(canvasPointAfter.y - canvasPointBefore.y) < 1e-9)
    }

    @Test func panMovesContentWithThePointer() throws {
        let (navigation, canvasView) = try makeNavigation()
        let centerBefore = canvasView.transform.center
        let viewCenterBefore = canvasView.transform.canvasToView(centerBefore)
        navigation.beginPan(atView: CGPoint(x: 400, y: 300))
        navigation.continuePan(toView: CGPoint(x: 450, y: 300))
        navigation.endPan()
        let viewCenterAfter = navigation.transform.canvasToView(centerBefore)
        #expect(abs(viewCenterAfter.x - viewCenterBefore.x - 50) < 1e-9,
                "the same canvas point moves +50 view points in x")
        #expect(abs(viewCenterAfter.y - viewCenterBefore.y) < 1e-9)
        #expect(navigation.transform.zoom == 1, "pan never zooms")
    }
}
