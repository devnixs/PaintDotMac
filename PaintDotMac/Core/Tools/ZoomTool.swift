import CoreGraphics
import Foundation

/// The Zoom tool (T-7, spec 0006; Paint.NET ViewTools.html). Click zooms in one preset
/// around the click point; Option-click or right-click zooms out; a drag of ≥ 3 view points
/// draws a dashed rectangle and zooms so it fills the view, centered. Never touches pixels,
/// history, or the document's edited state.
@MainActor
final class ZoomTool: Tool {
    /// Rectangle mode engages at this view-space drag distance (points — independent of zoom
    /// and backing scale).
    static let dragThreshold: Double = 3

    let id: ToolID = .zoom

    private struct Press {
        var downViewLocation: CGPoint
        var downCanvasLocation: CGPoint
        var button: ToolMouseButton
        var modifiers: ToolModifiers
    }

    private var press: Press?
    private var isRectangle = false

    func mouseDown(_ event: ToolEvent, context: any ToolContext) {
        press = Press(downViewLocation: event.viewLocation,
                      downCanvasLocation: event.location,
                      button: event.button,
                      modifiers: event.modifiers)
        isRectangle = false
    }

    func mouseDragged(_ event: ToolEvent, context: any ToolContext) {
        guard let press else { return }
        if !isRectangle {
            let distance = max(abs(event.viewLocation.x - press.downViewLocation.x),
                               abs(event.viewLocation.y - press.downViewLocation.y))
            guard distance >= Self.dragThreshold else { return }
            isRectangle = true
        }
        context.setOverlay(.zoomRectangle(Self.rectangle(from: press.downCanvasLocation,
                                                        to: event.location)))
    }

    func mouseUp(_ event: ToolEvent, context: any ToolContext) {
        defer {
            press = nil
            isRectangle = false
        }
        guard let press else { return }
        if isRectangle {
            // Button and modifiers don't matter in rectangle mode.
            context.setOverlay(nil)
            let rect = Self.rectangle(from: press.downCanvasLocation, to: event.location)
            let before = context.navigation.transform
            let target = Self.rectangleZoom(for: rect, transform: before)
            context.navigation.setZoom(target, anchoredAtView: before.canvasToView(rect.midpoint))
            // Center the rectangle (0004's clamping may stop short near image edges).
            let anchor = context.navigation.transform.canvasToView(rect.midpoint)
            let viewCenter = CGPoint(x: before.viewSize.width / 2, y: before.viewSize.height / 2)
            context.navigation.beginPan(atView: anchor)
            context.navigation.continuePan(toView: viewCenter)
            context.navigation.endPan()
            return
        }
        let zoomsOut = press.button == .secondary || press.modifiers.contains(.option)
        let zoom = context.navigation.transform.zoom
        let next = zoomsOut ? ZoomLevels.nextSmaller(than: zoom) : ZoomLevels.nextLarger(than: zoom)
        if let next {
            // The clicked point stays under the pointer (0004's anchored zoom).
            context.navigation.setZoom(next, anchoredAtView: press.downViewLocation)
        }
    }

    func cancel(context: any ToolContext) {
        context.setOverlay(nil)
        press = nil
        isRectangle = false
    }

    func deactivate(context: any ToolContext) {
        cancel(context: context)  // nothing to commit
    }

    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor {
        modifiers.contains(.option) ? .zoomOut : .zoomIn
    }

    /// The standardized canvas rect spanning the two drag points.
    static func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Paint.NET "maximizes the specified area": `fitZoom(content, drawable, allowsEnlargement:
    /// true)` clamped to 1 %–3200 %, not snapped to a preset. A degenerate side counts as one
    /// device pixel (`1 / zoom` canvas units).
    static func rectangleZoom(for rect: CGRect, transform: CanvasTransform) -> Double {
        let minSide = 1 / transform.zoom
        let content = CGSize(width: max(rect.width, minSide), height: max(rect.height, minSide))
        let drawable = transform.drawableSize
        return ZoomLevels.fitZoom(
            contentSize: content,
            viewportSize: CGSize(width: Double(drawable.width), height: Double(drawable.height)),
            allowsEnlargement: true
        )
    }
}

extension CGRect {
    fileprivate var midpoint: CGPoint { CGPoint(x: midX, y: midY) }
}
