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
        guard case .zoomRectangle(let rect)? = overlay, let canvasView else { return }
        // 1 pt white under a 1 pt black dashed line, inset half a point so the stroke lands
        // on the rect's edge (static, not animated — Paint.NET's marquee minus the ants).
        let viewRect = canvasView.transform.canvasRectToView(rect).insetBy(dx: 0.5, dy: 0.5)
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
}
