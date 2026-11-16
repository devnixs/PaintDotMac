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
        case nil:
            break
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
}
