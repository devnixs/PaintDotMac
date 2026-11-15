import CoreGraphics
import Foundation
import Testing
@testable import PaintDotMac

/// The Zoom tool (T-7, spec 0006 *Test plan*). Default fake geometry: image 4000×3000,
/// view 800×600 pt, backing scale 1, zoom 1, center (2000, 1500). Events carry
/// `location == transform.viewToCanvas(viewLocation)`.
@MainActor
struct ZoomToolTests {
    private func makeContext(zoom: Double = 1, backingScale: Double = 1,
                             center: CGPoint = CGPoint(x: 2000, y: 1500)) -> FakeToolContext {
        let context = FakeToolContext()
        context.nav.transform = CanvasTransform(
            imageSize: PixelSize(width: 4000, height: 3000),
            viewSize: CGSize(width: 800, height: 600),
            backingScale: backingScale,
            zoom: zoom,
            center: center
        )
        return context
    }

    private func event(view: CGPoint, transform: CanvasTransform,
                       button: ToolMouseButton = .primary,
                       modifiers: ToolModifiers = []) -> ToolEvent {
        ToolEvent(location: transform.viewToCanvas(view), viewLocation: view,
                  button: button, modifiers: modifiers, clickCount: 1, pressure: 1, timestamp: 0)
    }

    private func click(_ tool: ZoomTool, context: FakeToolContext, view: CGPoint,
                       button: ToolMouseButton = .primary, modifiers: ToolModifiers = []) {
        let event = self.event(view: view, transform: context.nav.transform,
                               button: button, modifiers: modifiers)
        tool.mouseDown(event, context: context)
        tool.mouseUp(event, context: context)
    }

    // MARK: - Click zooming

    @Test func clickZoomsInAroundPoint() {
        let tool = ZoomTool()
        let context = makeContext()
        click(tool, context: context, view: CGPoint(x: 100, y: 200))
        #expect(context.nav.setZoomCalls == [ZoomCall(zoom: 1.5, anchor: CGPoint(x: 100, y: 200))])
        #expect(context.nav.panCalls.isEmpty)
        #expect(context.overlays.isEmpty, "a click never draws an overlay")
    }

    @Test func optionClickZoomsOut() {
        let tool = ZoomTool()
        let context = makeContext()
        click(tool, context: context, view: CGPoint(x: 100, y: 200), modifiers: [.option])
        #expect(context.nav.setZoomCalls.count == 1)
        #expect(context.nav.setZoomCalls.first?.zoom == 2.0 / 3.0)
        #expect(context.nav.setZoomCalls.first?.anchor == CGPoint(x: 100, y: 200))
    }

    @Test func secondaryClickZoomsOut() {
        let tool = ZoomTool()
        let context = makeContext()
        click(tool, context: context, view: CGPoint(x: 100, y: 200), button: .secondary)
        #expect(context.nav.setZoomCalls.count == 1)
        #expect(context.nav.setZoomCalls.first?.zoom == 2.0 / 3.0)
    }

    @Test func zoomFromNonPreset() {
        let tool = ZoomTool()
        let context = makeContext(zoom: 1.2)
        click(tool, context: context, view: .zero)
        #expect(context.nav.setZoomCalls.first?.zoom == 1.5)
        let context2 = makeContext(zoom: 1.2)
        click(tool, context: context2, view: .zero, modifiers: [.option])
        #expect(context2.nav.setZoomCalls.first?.zoom == 1.0)
    }

    @Test func noOpAtLimits() {
        let tool = ZoomTool()
        let maxed = makeContext(zoom: 32)
        click(tool, context: maxed, view: CGPoint(x: 10, y: 10))
        #expect(maxed.nav.setZoomCalls.isEmpty)
        let min = makeContext(zoom: 0.01)
        click(tool, context: min, view: CGPoint(x: 10, y: 10), modifiers: [.option])
        #expect(min.nav.setZoomCalls.isEmpty)
    }

    // MARK: - Drag threshold

    @Test func dragThreshold() {
        let tool = ZoomTool()
        // 2.9 view points in each axis: still a click.
        let context = makeContext()
        let down = CGPoint(x: 100, y: 200)
        tool.mouseDown(event(view: down, transform: context.nav.transform),
                       context: context)
        tool.mouseDragged(event(view: CGPoint(x: 102.9, y: 202.9),
                                transform: context.nav.transform), context: context)
        tool.mouseUp(event(view: CGPoint(x: 102.9, y: 202.9),
                           transform: context.nav.transform), context: context)
        #expect(context.overlays.isEmpty)
        #expect(context.nav.setZoomCalls == [ZoomCall(zoom: 1.5, anchor: down)])

        // Exactly 3 points: rectangle mode. Canvas down = (1700, 1600) for view (100, 200)
        // with center (2000, 1500) at zoom 1: ox = 400 − 2000, oy = 300 − 1500 (hand-computed).
        let context2 = makeContext()
        tool.mouseDown(event(view: down, transform: context2.nav.transform),
                       context: context2)
        tool.mouseDragged(event(view: CGPoint(x: 103, y: 200),
                                transform: context2.nav.transform), context: context2)
        #expect(context2.overlays == [.zoomRectangle(CGRect(x: 1700, y: 1600, width: 3, height: 0))])
    }

    /// The threshold is in view points: identical outcome at 32×, 1 %, and 2× backing scale.
    @Test(arguments: [(zoom: 1.0, backingScale: 1.0), (zoom: 32.0, backingScale: 1.0),
                      (zoom: 0.01, backingScale: 1.0), (zoom: 1.0, backingScale: 2.0)])
    func thresholdIndependentOfZoom(zoom: Double, backingScale: Double) {
        let tool = ZoomTool()
        let down = CGPoint(x: 400, y: 300)

        // A pure click at this zoom is the reference outcome (at 32x zooming in is a no-op
        // for the zoom limit, exactly like `noOpAtLimits`).
        let reference = makeContext(zoom: zoom, backingScale: backingScale)
        click(tool, context: reference, view: down)

        let context = makeContext(zoom: zoom, backingScale: backingScale)
        tool.mouseDown(event(view: down, transform: context.nav.transform), context: context)
        tool.mouseDragged(event(view: CGPoint(x: 402.9, y: 302.9),
                                transform: context.nav.transform), context: context)
        tool.mouseUp(event(view: CGPoint(x: 402.9, y: 302.9),
                           transform: context.nav.transform), context: context)
        #expect(context.overlays.isEmpty, "2.9 pt must stay a click at zoom \(zoom)/\(backingScale)x")
        #expect(context.nav.setZoomCalls == reference.nav.setZoomCalls,
                "2.9 pt must behave like a click at zoom \(zoom)/\(backingScale)x")

        let context2 = makeContext(zoom: zoom, backingScale: backingScale)
        tool.mouseDown(event(view: down, transform: context2.nav.transform), context: context2)
        tool.mouseDragged(event(view: CGPoint(x: 400, y: 303),
                                transform: context2.nav.transform), context: context2)
        #expect(context2.overlays.count == 1, "3 pt must become a rectangle at zoom \(zoom)/\(backingScale)x")
    }

    // MARK: - rectangleZoom math (hand-computed)

    private func transform(zoom: Double, backingScale: Double) -> CanvasTransform {
        CanvasTransform(imageSize: PixelSize(width: 4000, height: 3000),
                        viewSize: CGSize(width: 800, height: 600),
                        backingScale: backingScale, zoom: zoom,
                        center: CGPoint(x: 2000, y: 1500))
    }

    @Test func rectangleZoomMath() {
        // 200×100 canvas rect at zoom 1, scale 1 → viewport 800×600 → min(800/200, 600/100) = 4.
        #expect(ZoomTool.rectangleZoom(for: CGRect(x: 100, y: 100, width: 200, height: 100),
                                       transform: transform(zoom: 1, backingScale: 1)) == 4.0)
        // Same rect at 2× backing scale → viewport 1600×1200 → min(8, 12) = 8.
        #expect(ZoomTool.rectangleZoom(for: CGRect(x: 100, y: 100, width: 200, height: 100),
                                       transform: transform(zoom: 1, backingScale: 2)) == 8.0)
        // A rect bigger than the view zooms out: min(800/1600, 600/600) = 0.5.
        #expect(ZoomTool.rectangleZoom(for: CGRect(x: 0, y: 0, width: 1600, height: 600),
                                       transform: transform(zoom: 1, backingScale: 1)) == 0.5)
        // Tiny rect at high zoom: fit 60 … clamps to the 3200 % maximum.
        #expect(ZoomTool.rectangleZoom(for: CGRect(x: 0, y: 0, width: 10, height: 10),
                                       transform: transform(zoom: 4, backingScale: 1)) == 32.0)
        // Huge rect at minimum zoom: fit 0.006 … clamps to the 1 % minimum.
        #expect(ZoomTool.rectangleZoom(for: CGRect(x: 0, y: 0, width: 100_000, height: 100_000),
                                       transform: transform(zoom: 0.01, backingScale: 1)) == 0.01)
    }

    @Test func zeroHeightRectangle() {
        // A zero side counts as one device pixel (1 / zoom); the fit follows the other side:
        // content 200×1 → min(800/200, 600/1) = 4.
        #expect(ZoomTool.rectangleZoom(for: CGRect(x: 0, y: 50, width: 200, height: 0),
                                       transform: transform(zoom: 1, backingScale: 1)) == 4.0)
    }

    @Test func rectangleLargerZoomsOut() {
        // Edge case alias of the 1600×600 row: 0.5.
        #expect(ZoomTool.rectangleZoom(for: CGRect(x: 10, y: 10, width: 1600, height: 600),
                                       transform: transform(zoom: 1, backingScale: 1)) == 0.5)
    }

    @Test func rectangleClampsToMaximum() {
        #expect(ZoomTool.rectangleZoom(for: CGRect(x: 0, y: 0, width: 2, height: 2),
                                       transform: transform(zoom: 8, backingScale: 1)) == 32.0)
    }

    // MARK: - The full rectangle gesture

    /// Center (400, 300): the image origin lands at device (0, 0), so with 0003's bottom-left
    /// view space `canvasToView((x, y)) = (x, 600 − y)`.
    private func makeCenteredContext() -> FakeToolContext {
        makeContext(center: CGPoint(x: 400, y: 300))
    }

    @Test func rectangleGesture() {
        let tool = ZoomTool()
        let context = makeCenteredContext()
        let downView = CGPoint(x: 100, y: 500)
        let upView = CGPoint(x: 300, y: 400)
        let transform = context.nav.transform
        #expect(transform.viewToCanvas(downView) == CGPoint(x: 100, y: 100))
        #expect(transform.viewToCanvas(upView) == CGPoint(x: 300, y: 200))

        tool.mouseDown(event(view: downView, transform: transform), context: context)
        tool.mouseDragged(event(view: CGPoint(x: 150, y: 475), transform: transform), context: context)
        tool.mouseDragged(event(view: upView, transform: transform), context: context)
        tool.mouseUp(event(view: upView, transform: transform), context: context)

        #expect(context.overlays.last == .some(nil), "clearing records a nil overlay")
        #expect(context.overlays
                    == [.zoomRectangle(CGRect(x: 100, y: 100, width: 50, height: 25)),
                        .zoomRectangle(CGRect(x: 100, y: 100, width: 200, height: 100)),
                        nil])
        // The rect's mid (200, 150) in bottom-left view space is (200, 450); a top-left
        // mistake would give (200, 150).
        #expect(context.nav.setZoomCalls == [ZoomCall(zoom: 4.0, anchor: CGPoint(x: 200, y: 450))])
        // The fake never moves its transform, so the post-zoom anchor equals the pre-zoom one.
        #expect(context.nav.panCalls
                    == [.begin(CGPoint(x: 200, y: 450)), .continue(CGPoint(x: 400, y: 300)), .end])
    }

    @Test func reversedDrag() {
        let tool = ZoomTool()
        let context = makeCenteredContext()
        let transform = context.nav.transform
        let from = CGPoint(x: 300, y: 400)   // canvas (300, 200)
        let to = CGPoint(x: 100, y: 500)     // canvas (100, 100)
        tool.mouseDown(event(view: from, transform: transform), context: context)
        tool.mouseDragged(event(view: to, transform: transform), context: context)
        tool.mouseUp(event(view: to, transform: transform), context: context)
        #expect(context.overlays.first == .zoomRectangle(CGRect(x: 100, y: 100, width: 200, height: 100)))
        #expect(context.nav.setZoomCalls == [ZoomCall(zoom: 4.0, anchor: CGPoint(x: 200, y: 450))])
        #expect(context.nav.panCalls
                    == [.begin(CGPoint(x: 200, y: 450)), .continue(CGPoint(x: 400, y: 300)), .end])
    }

    @Test func optionDragStillZoomsIn() {
        let tool = ZoomTool()
        let context = makeCenteredContext()
        let transform = context.nav.transform
        tool.mouseDown(event(view: CGPoint(x: 100, y: 500), transform: transform,
                             modifiers: [.option]), context: context)
        tool.mouseDragged(event(view: CGPoint(x: 300, y: 400), transform: transform,
                                modifiers: [.option]), context: context)
        tool.mouseUp(event(view: CGPoint(x: 300, y: 400), transform: transform,
                           modifiers: [.option]), context: context)
        #expect(context.nav.setZoomCalls.first?.zoom == 4.0)
    }

    @Test func escapeCancelsRectangle() {
        let tool = ZoomTool()
        let context = makeCenteredContext()
        let transform = context.nav.transform
        let downView = CGPoint(x: 100, y: 500)
        let upView = CGPoint(x: 300, y: 400)
        tool.mouseDown(event(view: downView, transform: transform), context: context)
        tool.mouseDragged(event(view: upView, transform: transform), context: context)
        #expect(context.overlays.count == 1)
        tool.cancel(context: context)
        #expect(context.overlays.last == .some(nil), "clearing records a nil overlay")
        #expect(context.nav.setZoomCalls.isEmpty)
        tool.mouseUp(event(view: upView, transform: transform), context: context)
        // After cancel the tool is idle: the stale up does nothing.
        #expect(context.nav.setZoomCalls.isEmpty)
        #expect(context.nav.panCalls.isEmpty)
        #expect(context.overlays.filter { $0 != nil }.count == 1)
    }

    // MARK: - Cursor and side-effect freedom

    @Test func cursorFollowsOption() {
        let tool = ZoomTool()
        #expect(tool.cursor(at: .zero, modifiers: []) == .zoomIn)
        #expect(tool.cursor(at: nil, modifiers: []) == .zoomIn)
        #expect(tool.cursor(at: .zero, modifiers: [.option]) == .zoomOut)
        #expect(tool.cursor(at: .zero, modifiers: [.option, .shift]) == .zoomOut)
    }

    @Test func clickThenOptionClickRoundTrip() throws {
        // For every preset except the ends: click in, then Option-click out lands back on
        // the starting zoom.
        let presets = ZoomLevels.stops.dropFirst().dropLast()
        let tool = ZoomTool()
        for start in presets {
            let context = makeContext(zoom: start)
            click(tool, context: context, view: CGPoint(x: 50, y: 50))
            let zoomedIn = try #require(context.nav.setZoomCalls.first?.zoom)
            #expect(zoomedIn == ZoomLevels.nextLarger(than: start), "zoom in from \(start)")
            // Feed the first result back in, then Option-click.
            let context2 = makeContext(zoom: zoomedIn)
            click(tool, context: context2, view: CGPoint(x: 50, y: 50), modifiers: [.option])
            let zoomedOut = try #require(context2.nav.setZoomCalls.first?.zoom)
            #expect(zoomedOut == start, "round trip from \(start) went \(zoomedIn) → \(zoomedOut)")
        }
    }

    @Test func noDocumentSideEffects() {
        let tool = ZoomTool()
        let context = makeCenteredContext()
        let imageBefore = context.image
        let transformBefore = context.nav.transform

        click(tool, context: context, view: CGPoint(x: 100, y: 200))
        click(tool, context: context, view: CGPoint(x: 100, y: 200), modifiers: [.option])
        click(tool, context: context, view: CGPoint(x: 100, y: 200), button: .secondary)
        let transform = context.nav.transform
        tool.mouseDown(event(view: CGPoint(x: 100, y: 500), transform: transform), context: context)
        tool.mouseDragged(event(view: CGPoint(x: 300, y: 400), transform: transform), context: context)
        tool.mouseUp(event(view: CGPoint(x: 300, y: 400), transform: transform), context: context)

        #expect(context.image == imageBefore, "the Zoom tool must never touch pixels")
        #expect(context.nav.transform == transformBefore, "the fake never moves — and the tool must not either")
        #expect(context.cursorInvalidations == 0, "the Zoom tool does not invalidate the cursor")
    }
}
