import CoreGraphics
import Foundation

/// The pure Ellipse Select geometry (Paint.NET `EllipseSelectTool.CreateShape`, spec 0014).
/// The ellipse is inscribed in a pixel rect; `boundingRect` is unclipped — the shape keeps
/// its true form when it runs past the canvas and 0013's `Selection.init?(path:)` clips.
enum EllipseSelectGeometry {
    /// The pixel-inclusive bounding rect (w, h ≥ 1).
    ///
    /// Without Shift: the same pixel-inclusive rectangle as Rectangle Select. With Shift
    /// it is a circle whose diameter is the start-to-pointer distance, centered between
    /// the two pixel centers ("Force Ellipse Select to circle: Shift + Drag" — the
    /// diameter is then set by the starting click and the current pointer position).
    static func boundingRect(anchor a: PixelPoint, current b: PixelPoint,
                             constrainCircle: Bool) -> PixelRect {
        guard constrainCircle else {
            return PixelRect(x: min(a.x, b.x), y: min(a.y, b.y),
                             width: abs(b.x - a.x) + 1, height: abs(b.y - a.y) + 1)
        }
        let cx = Double(a.x + b.x) / 2 + 0.5   // center between the two pixel centers
        let cy = Double(a.y + b.y) / 2 + 0.5
        let diameter = Int(hypot(Double(b.x - a.x), Double(b.y - a.y))
            .rounded(.toNearestOrAwayFromZero)) + 1
        return PixelRect(x: Int((cx - Double(diameter) / 2).rounded(.down)),
                         y: Int((cy - Double(diameter) / 2).rounded(.down)),
                         width: diameter, height: diameter)
    }

    /// Paint.NET's `clipped`: the shape is empty once intersected with the image.
    static func isEmpty(_ r: PixelRect, imageSize: PixelSize) -> Bool {
        r.intersection(PixelRect(origin: .zero, size: imageSize)).isEmpty
    }
}

/// The Ellipse Select tool (T-3, spec 0014; Paint.NET EllipseSelectionTool.html). Same
/// gesture, mode, finish, and history rules as `RectangleSelectTool` — no draw-mode
/// options (Paint.NET's `ToolBarConfigItems.None`). Antialiased quality gives the edge
/// pixels fractional coverage; Pixelated gives 0/255 (0013's rule). Never touches pixels.
@MainActor
final class EllipseSelectTool: Tool {
    let id: ToolID = .ellipseSelect

    private var gesture: SelectionGesture?
    private var lastModifiers: ToolModifiers = []

    private func updatePreview(context: any ToolContext) {
        guard let gesture else { return }
        let rect = EllipseSelectGeometry.boundingRect(anchor: gesture.anchorPixel,
                                                      current: gesture.currentPixel,
                                                      constrainCircle: lastModifiers.contains(.shift))
        context.setOverlay(.selectionShape(SelectionShapePreview(
            shape: .ellipse, rect: rect, hidesCurrentSelection: gesture.mode == .replace)))
    }

    func mouseDown(_ event: ToolEvent, context: any ToolContext) {
        gesture = SelectionGesture(
            event: event, pickerMode: context.options.value(SelectionToolOptions.combineMode))
        lastModifiers = event.modifiers
        updatePreview(context: context)
    }

    func mouseDragged(_ event: ToolEvent, context: any ToolContext) {
        gesture?.update(with: event)
        lastModifiers = event.modifiers
        updatePreview(context: context)
    }

    func flagsChanged(_ modifiers: ToolModifiers, context: any ToolContext) {
        lastModifiers = modifiers
        if gesture != nil {
            // Recompute the preview with the new Shift state; the mode stays latched.
            updatePreview(context: context)
        }
        context.invalidateCursor()
    }

    func mouseUp(_ event: ToolEvent, context: any ToolContext) {
        defer {
            context.setOverlay(nil)
            gesture = nil
        }
        guard var gesture else { return }
        gesture.update(with: event)
        let rect = EllipseSelectGeometry.boundingRect(anchor: gesture.anchorPixel,
                                                      current: gesture.currentPixel,
                                                      constrainCircle: event.modifiers.contains(.shift))
        let quality = context.options.value(SelectionToolOptions.quality)
        let outcome = SelectionGesture.outcome(
            mode: gesture.mode, hasMoved: gesture.hasMoved,
            duration: event.timestamp - gesture.startTimestamp,
            shapeIsEmpty: EllipseSelectGeometry.isEmpty(rect, imageSize: context.image.size))
        // The unclipped rect: 0013's `Selection.init?(path:)` clips the path to the canvas
        // before `MaskRasterizer` rasterizes it.
        let newSelection = Selection(
            path: CGPath(ellipseIn: CGRect(x: Double(rect.x), y: Double(rect.y),
                                           width: Double(rect.width), height: Double(rect.height)),
                         transform: nil),
            canvasSize: context.image.size, antialiased: quality == .antialiased)
        SelectionCommit.finish(outcome: outcome, newSelection: newSelection,
                               mode: gesture.mode, name: "Ellipse Select",
                               icon: .ellipseSelect, context: context)
    }

    func keyDown(_ event: ToolKeyEvent, context: any ToolContext) -> Bool {
        if gesture == nil, event.key == .returnKey || event.key == .enter {
            return SelectionCommit.deselectIfNeeded(context: context)
        }
        return false
    }

    func cancel(context: any ToolContext) {
        context.setOverlay(nil)
        gesture = nil
    }

    func deactivate(context: any ToolContext) {
        cancel(context: context)   // nothing to commit; the selection is untouched
    }

    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor { .crosshair }
}
