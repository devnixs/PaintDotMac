import CoreGraphics
import Testing
@testable import PaintDotMac

/// The Pan tool (T-8, spec 0006 *Test plan*). Events carry deliberately wrong `location`s
/// to prove the tool uses `viewLocation` only.
@MainActor
struct PanToolTests {
    private func event(view: CGPoint, button: ToolMouseButton = .primary) -> ToolEvent {
        ToolEvent(location: .zero, viewLocation: view, button: button,
                  modifiers: [], clickCount: 1, pressure: 1, timestamp: 0)
    }

    @Test func dragPans() {
        let tool = PanTool()
        let context = FakeToolContext()
        tool.mouseDown(event(view: CGPoint(x: 100, y: 100)), context: context)
        tool.mouseDragged(event(view: CGPoint(x: 110, y: 100)), context: context)
        tool.mouseDragged(event(view: CGPoint(x: 130, y: 105)), context: context)
        tool.mouseUp(event(view: CGPoint(x: 130, y: 105)), context: context)
        #expect(context.nav.panCalls
                    == [.begin(CGPoint(x: 100, y: 100)),
                        .continue(CGPoint(x: 110, y: 100)),
                        .continue(CGPoint(x: 130, y: 105)),
                        .continue(CGPoint(x: 130, y: 105)),
                        .end])
        #expect(context.nav.setZoomCalls.isEmpty)
    }

    @Test func secondaryButtonPans() {
        let tool = PanTool()
        let context = FakeToolContext()
        tool.mouseDown(event(view: CGPoint(x: 100, y: 100), button: .secondary), context: context)
        tool.mouseDragged(event(view: CGPoint(x: 110, y: 100), button: .secondary), context: context)
        tool.mouseUp(event(view: CGPoint(x: 110, y: 100), button: .secondary), context: context)
        #expect(context.nav.panCalls
                    == [.begin(CGPoint(x: 100, y: 100)),
                        .continue(CGPoint(x: 110, y: 100)),
                        .continue(CGPoint(x: 110, y: 100)),
                        .end])
    }

    @Test func cursorStates() {
        let tool = PanTool()
        let context = FakeToolContext()
        #expect(tool.cursor(at: .zero, modifiers: []) == .openHand)
        tool.mouseDown(event(view: CGPoint(x: 5, y: 5)), context: context)
        #expect(tool.cursor(at: nil, modifiers: []) == .closedHand)
        tool.mouseUp(event(view: CGPoint(x: 5, y: 5)), context: context)
        #expect(tool.cursor(at: nil, modifiers: []) == .openHand)
        #expect(context.cursorInvalidations == 2, "down and up each invalidate the cursor")
    }

    @Test func cancelEndsPan() {
        let tool = PanTool()
        let context = FakeToolContext()
        tool.mouseDown(event(view: CGPoint(x: 20, y: 30)), context: context)
        tool.cancel(context: context)
        #expect(context.nav.panCalls
                    == [.begin(CGPoint(x: 20, y: 30)), .end])
        tool.mouseDragged(event(view: CGPoint(x: 40, y: 30)), context: context)
        tool.mouseUp(event(view: CGPoint(x: 40, y: 30)), context: context)
        #expect(context.nav.panCalls.count == 2, "after cancel the tool is idle")
    }

    @Test func orphanDragAndUpIgnored() {
        let tool = PanTool()
        let context = FakeToolContext()
        tool.mouseDragged(event(view: CGPoint(x: 1, y: 1)), context: context)
        tool.mouseUp(event(view: CGPoint(x: 1, y: 1)), context: context)
        #expect(context.nav.panCalls.isEmpty)
    }

    /// 0004's clamping keeps an image smaller than the view centered: the calls are made,
    /// nothing moves (0004 owns that math — `panned(byView:)` on the same geometry is
    /// covered there), and nothing crashes.
    @Test func smallImageStaysClamped() {
        let tool = PanTool()
        let context = FakeToolContext()
        context.nav.transform = CanvasTransform(
            imageSize: PixelSize(width: 64, height: 64),
            viewSize: CGSize(width: 800, height: 600),
            backingScale: 1, zoom: 1,
            center: CGPoint(x: 32, y: 32)
        )
        let transformBefore = context.nav.transform
        tool.mouseDown(event(view: CGPoint(x: 400, y: 300)), context: context)
        tool.mouseDragged(event(view: CGPoint(x: 500, y: 300)), context: context)
        tool.mouseUp(event(view: CGPoint(x: 500, y: 300)), context: context)
        #expect(context.nav.panCalls.count == 4)
        #expect(context.nav.transform == transformBefore)
        // 0004's clamp on the same drag: content follows 100 pt but the center stays put.
        #expect(transformBefore.panned(byView: CGVector(dx: 100, dy: 0)).center
                    == CGPoint(x: 32, y: 32))
    }

    @Test func noDocumentSideEffects() {
        let tool = PanTool()
        let context = FakeToolContext()
        let imageBefore = context.image
        tool.mouseDown(event(view: CGPoint(x: 10, y: 10)), context: context)
        tool.mouseDragged(event(view: CGPoint(x: 20, y: 20)), context: context)
        tool.mouseUp(event(view: CGPoint(x: 20, y: 20)), context: context)
        #expect(context.image == imageBefore, "the Pan tool must never touch pixels")
        #expect(context.overlays.isEmpty)
        #expect(context.nav.setZoomCalls.isEmpty)
    }
}
