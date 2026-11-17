import AppKit

/// Transparent vector feedback above the canvas (spec 0006): the Zoom rectangle now, lasso
/// paths and shape handles later. Not flipped, like `CanvasView`, so 0003's view-space rects
/// draw without conversion; `hitTest` returns `nil` so it never eats mouse events.
@MainActor
final class ToolOverlayView: NSView {
    var overlay: ToolOverlay? {
        didSet {
            if overlay != oldValue { needsDisplay = true }
        }
    }

    /// The canvas whose transform maps canvas-space overlay rects into view space.
    weak var canvasView: CanvasView?

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvasView else { return }
        switch overlay {
        case .zoomRectangle(let rect)?:
            drawZoomRectangle(rect, transform: canvasView.transform)
        case .brushOutline(let rect)?:
            drawBrushOutline(rect, transform: canvasView.transform)
        case .selectionShape(let preview)?:
            drawSelectionShape(preview, transform: canvasView.transform)
        case .lassoPath(let points, let rubberBand)?:
            drawLassoPath(points: points, rubberBand: rubberBand, transform: canvasView.transform)
        case .transformHandles(let preview)?:
            if let ctx = NSGraphicsContext.current?.cgContext {
                TransformHandlesOverlay.draw(preview, transform: canvasView.transform, in: ctx)
            }
        case .gradientHandles(let start, let end)?:
            drawGradientHandles(start: start, end: end, transform: canvasView.transform)
        case nil:
            break
        }
    }

    /// The Gradient's endpoint handles (spec 0023): a 1 pt black line over a 1 pt white line
    /// (the white offset 1 pt so it rims the black on any background), and at each end a
    /// 10 pt circle — white fill, 1 pt black stroke.
    private func drawGradientHandles(start: CGPoint, end: CGPoint,
                                     transform: CanvasTransform) {
        let startView = transform.canvasToView(start)
        let endView = transform.canvasToView(end)
        NSGraphicsContext.current?.imageInterpolation = .none

        func line(offsetY: CGFloat) -> NSBezierPath {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: startView.x, y: startView.y + offsetY))
            path.line(to: CGPoint(x: endView.x, y: endView.y + offsetY))
            path.lineWidth = 1
            return path
        }

        let underline = line(offsetY: 1)
        NSColor.white.setStroke()
        underline.stroke()
        let overline = line(offsetY: 0)
        NSColor.black.setStroke()
        overline.stroke()

        for center in [startView, endView] {
            let circle = NSRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: circle).fill()
            let stroke = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
            stroke.lineWidth = 1
            NSColor.black.setStroke()
            stroke.stroke()
        }
    }

    private func drawZoomRectangle(_ rect: CGRect, transform: CanvasTransform) {
        // 1 pt white under a 1 pt black dashed line, inset half a point so the stroke lands
        // on the rect's edge (static, not animated — Paint.NET's marquee minus the ants).
        let viewRect = transform.canvasRectToView(rect).insetBy(dx: 0.5, dy: 0.5)
        guard viewRect.width > 0, viewRect.height > 0 else { return }
        NSGraphicsContext.current?.imageInterpolation = .none

        let underline = NSBezierPath(rect: viewRect)
        underline.lineWidth = 1
        NSColor.white.setStroke()
        underline.stroke()

        let dashes = NSBezierPath(rect: viewRect)
        dashes.lineWidth = 1
        dashes.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.black.setStroke()
        dashes.stroke()
    }

    /// The shape a selection tool drags (spec 0014): the rect (Rectangle) or the ellipse
    /// inscribed in the view-mapped rect (Ellipse), stroked in the Zoom-rectangle style —
    /// 1 pt white under a 1 pt black dashed `[4, 4]`, static (the ants come back on
    /// release, marching).
    private func drawSelectionShape(_ preview: SelectionShapePreview,
                                    transform: CanvasTransform) {
        let viewRect = transform.pixelRectToView(preview.rect).insetBy(dx: 0.5, dy: 0.5)
        guard viewRect.width > 0, viewRect.height > 0 else { return }
        NSGraphicsContext.current?.imageInterpolation = .none

        func shape() -> NSBezierPath {
            preview.shape == .rectangle
                ? NSBezierPath(rect: viewRect)
                : NSBezierPath(ovalIn: viewRect)
        }

        let underline = shape()
        underline.lineWidth = 1
        NSColor.white.setStroke()
        underline.stroke()

        let dashes = shape()
        dashes.lineWidth = 1
        dashes.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.black.setStroke()
        dashes.stroke()
    }

    /// The lasso outline in progress (spec 0015): the kept points as an open polyline in
    /// the Zoom-rectangle style — 1 pt white under a 1 pt black dashed `[4, 4]`, static —
    /// plus the closing segment from the last point (via the Polygon rubber-band hover
    /// point while hovering) back to the first point at 50 % opacity, so the user sees how
    /// the shape will close. One point without a rubber band draws nothing.
    private func drawLassoPath(points: [CGPoint], rubberBand: CGPoint?,
                               transform: CanvasTransform) {
        let mapped = points.map(transform.canvasToView)
        let tail = rubberBand.map(transform.canvasToView)
        guard let first = mapped.first, let last = mapped.last,
              mapped.count > 1 || tail != nil else { return }
        NSGraphicsContext.current?.imageInterpolation = .none

        func strokePolyline(_ pathPoints: [CGPoint], alpha: CGFloat) {
            guard pathPoints.count > 1 else { return }
            for dashed in [false, true] {
                let path = NSBezierPath()
                path.move(to: pathPoints[0])
                for point in pathPoints.dropFirst() { path.line(to: point) }
                path.lineWidth = 1
                if dashed { path.setLineDash([4, 4], count: 2, phase: 0) }
                (dashed ? NSColor.black : NSColor.white)
                    .withAlphaComponent(alpha).setStroke()
                path.stroke()
            }
        }

        strokePolyline(mapped, alpha: 1)
        var closing: [CGPoint] = [last]
        if let tail { closing.append(tail) }
        closing.append(first)
        strokePolyline(closing, alpha: 0.5)
    }

    /// The brush circle (spec 0009, D-38): the ellipse inscribed in the view-mapped square
    /// — identical to `BrushOutline.viewRect` — as a 1 pt white circle under a 1 pt black
    /// circle, inset 0.5 pt, so it stays visible on any background. Below
    /// `BrushOutline.minimumViewDiameter` points nothing is drawn (the crosshair cursor
    /// alone marks the spot). Nothing allocates with the outline's size — a width-2000
    /// circle at 3200 % is just one clipped ellipse path.
    private func drawBrushOutline(_ rect: CGRect, transform: CanvasTransform) {
        let viewRect = transform.canvasRectToView(rect)
        guard viewRect.width >= BrushOutline.minimumViewDiameter,
              viewRect.height >= BrushOutline.minimumViewDiameter else { return }
        let circle = viewRect.insetBy(dx: 0.5, dy: 0.5)
        let underline = NSBezierPath(ovalIn: circle)
        underline.lineWidth = 1
        NSColor.white.setStroke()
        underline.stroke()

        let overline = NSBezierPath(ovalIn: circle)
        overline.lineWidth = 1
        NSColor.black.setStroke()
        overline.stroke()
    }

    // MARK: - Accessibility (spec 0020 item 12)

    /// While the Move tools' transform frame is shown, one child element
    /// `canvas.transformHandles` whose value is the frame's integer bounding box
    /// `"x,y,w,h"` (floor of the min, ceil of the max, canvas coordinates) — for
    /// VoiceOver and the headless integration tests. Other overlays expose nothing.
    override func accessibilityRole() -> NSAccessibility.Role? {
        if case .transformHandles? = overlay { return .group }
        return super.accessibilityRole()
    }

    override func accessibilityChildren() -> [Any]? {
        guard case .transformHandles(let preview)? = overlay, !preview.corners.isEmpty else {
            return super.accessibilityChildren()
        }
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.group)
        element.setAccessibilityLabel("Transform handles")
        element.setAccessibilityIdentifier(Self.transformHandlesIdentifier)
        element.setAccessibilityValue(Self.transformHandlesValue(corners: preview.corners))
        return [element]
    }

    static let transformHandlesIdentifier = "canvas.transformHandles"

    /// The corners' integer bounding box as `"x,y,w,h"` — floor of the min, ceil of the
    /// max (canvas coordinates).
    static func transformHandlesValue(corners: [CGPoint]) -> String {
        let minX = floor(corners.map(\.x).min() ?? 0)
        let minY = floor(corners.map(\.y).min() ?? 0)
        let maxX = ceil(corners.map(\.x).max() ?? 0)
        let maxY = ceil(corners.map(\.y).max() ?? 0)
        return "\(Int(minX)),\(Int(minY)),\(Int(maxX - minX)),\(Int(maxY - minY))"
    }
}
