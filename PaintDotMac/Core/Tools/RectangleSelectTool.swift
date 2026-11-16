import CoreGraphics
import Foundation

/// A locked width:height ratio for Fixed Ratio drawing (spec 0014). A small `struct` so
/// `RectangleSelectGeometry` synthesizes `Equatable`.
struct SelectionRatio: Sendable, Equatable {
    var width: Double
    var height: Double
}

/// The pure Rectangle Select geometry (Paint.NET `RectangleSelectTool.CreateShape` +
/// `Utility.PointsToRectangle` / `PointsToConstrainedRectangle`, spec 0014).
struct RectangleSelectGeometry: Sendable, Equatable {
    var drawMode: SelectionDrawMode
    /// Fixed Ratio.
    var ratio: SelectionRatio
    /// Fixed Size, already converted to pixels (`SelectionToolOptions.fixedSizeInPixels`).
    var fixedPixelSize: PixelSize

    /// The drawn rectangle, clipped to the image; `nil` = empty after clipping.
    ///
    /// 1. **Normal** (`PointsToRectangle`): mouse positions are integer pixels and the
    ///    rectangle runs start → current **inclusive** (`width = |a.x − b.x| + 1`).
    ///    With Shift (`PointsToConstrainedRectangle`): square side `min(w, h)`, anchored
    ///    at the start pixel and extending toward the pointer.
    /// 2. **Fixed Ratio** (Shift ignored): scale the extents so `w : h = ratio`,
    ///    anchored the same way.
    /// 3. **Fixed Size** (Shift ignored): the rectangle's top-left follows the pointer
    ///    and the size is `fixedPixelSize`.
    ///
    /// All arithmetic is `Int` on coordinates bounded by `SelectionGesture.pixel(for:)`'s
    /// 10⁹ limit (no overflow); the result is intersected with the image bounds, so
    /// rectangle edges are always integers (Paint.NET's `rect.Intersect(Document.Bounds)`).
    static func rect(anchor a: PixelPoint, current b: PixelPoint, constrainSquare: Bool,
                     geometry: RectangleSelectGeometry, imageSize: PixelSize) -> PixelRect? {
        let x0: Int
        let y0: Int
        let w: Int
        let h: Int
        switch geometry.drawMode {
        case .normal:
            var width = abs(b.x - a.x) + 1
            var height = abs(b.y - a.y) + 1
            if constrainSquare {
                width = min(width, height)
                height = width
            }
            // Without Shift this equals `min(a.x, b.x)`.
            x0 = b.x >= a.x ? a.x : a.x - width + 1
            y0 = b.y >= a.y ? a.y : a.y - height + 1
            w = width
            h = height
        case .fixedRatio:
            let ex = Double(abs(b.x - a.x) + 1)
            let ey = Double(abs(b.y - a.y) + 1)
            let scale = min(ex / geometry.ratio.width, ey / geometry.ratio.height)
            w = max(1, Int((scale * geometry.ratio.width).rounded(.toNearestOrAwayFromZero)))
            h = max(1, Int((scale * geometry.ratio.height).rounded(.toNearestOrAwayFromZero)))
            x0 = b.x >= a.x ? a.x : a.x - w + 1
            y0 = b.y >= a.y ? a.y : a.y - h + 1
        case .fixedSize:
            x0 = b.x
            y0 = b.y
            w = geometry.fixedPixelSize.width
            h = geometry.fixedPixelSize.height
        }
        let clipped = PixelRect(x: x0, y: y0, width: w, height: h)
            .intersection(PixelRect(origin: .zero, size: imageSize))
        return clipped.isEmpty ? nil : clipped
    }
}

/// The Rectangle Select tool (T-1, spec 0014; Paint.NET RectangleSelectionTool.html).
/// Drags the rectangular selection with the modes, Shift-square, Fixed Ratio / Fixed Size,
/// click-to-deselect, and finish rules of `SelectionGesture` / `SelectionCommit`. The
/// shape is previewed as an overlay while dragging — nothing rasterizes until mouse-up —
/// and the tool never touches pixels.
@MainActor
final class RectangleSelectTool: Tool {
    let id: ToolID = .rectangleSelect

    private var gesture: SelectionGesture?
    /// The latest `flagsChanged` state — Shift is re-read live (Paint.NET
    /// `OnKeyDown/OnKeyUp → Render`), the mode stays latched.
    private var lastModifiers: ToolModifiers = []

    private func geometry(from context: any ToolContext) -> RectangleSelectGeometry {
        let width = context.options.value(SelectionToolOptions.fixedWidth)
        let height = context.options.value(SelectionToolOptions.fixedHeight)
        return RectangleSelectGeometry(
            drawMode: context.options.value(SelectionToolOptions.drawMode),
            ratio: SelectionRatio(width: width, height: height),
            fixedPixelSize: SelectionToolOptions.fixedSizeInPixels(
                width: width, height: height,
                unit: context.options.value(SelectionToolOptions.fixedUnit),
                dpi: context.image.dpi))
    }

    /// The preview: the drawn shape as an overlay, or `nil` when the shape is empty. No
    /// selection is built and nothing rasterizes while dragging (drags stay cheap at any
    /// image size). In Replace mode the current selection's ants hide for the drag
    /// (`hidesCurrentSelection`). Shift comes from `lastModifiers`, which every pointer and
    /// flags event refreshes — the mode stays latched.
    private func updatePreview(context: any ToolContext) {
        guard let gesture else { return }
        let rect = RectangleSelectGeometry.rect(
            anchor: gesture.anchorPixel, current: gesture.currentPixel,
            constrainSquare: lastModifiers.contains(.shift), geometry: geometry(from: context),
            imageSize: context.image.size)
        guard let rect else {
            context.setOverlay(nil)
            return
        }
        context.setOverlay(.selectionShape(SelectionShapePreview(
            shape: .rectangle, rect: rect, hidesCurrentSelection: gesture.mode == .replace)))
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
        let rect = RectangleSelectGeometry.rect(
            anchor: gesture.anchorPixel, current: gesture.currentPixel,
            constrainSquare: event.modifiers.contains(.shift),
            geometry: geometry(from: context), imageSize: context.image.size)
        let outcome = SelectionGesture.outcome(
            mode: gesture.mode, hasMoved: gesture.hasMoved,
            duration: event.timestamp - gesture.startTimestamp, shapeIsEmpty: rect == nil)
        let newSelection = rect.flatMap { r -> Selection? in
            Selection(rect: CGRect(x: Double(r.x), y: Double(r.y),
                                   width: Double(r.width), height: Double(r.height)),
                      canvasSize: context.image.size,
                      antialiased: context.options.value(SelectionToolOptions.quality) == .antialiased)
        }
        SelectionCommit.finish(outcome: outcome, newSelection: newSelection,
                               mode: gesture.mode, name: "Rectangle Select",
                               icon: .rectangleSelect, context: context)
    }

    /// "Deselect active selection: Ctrl + D or Enter" — Return/Enter with no gesture active
    /// (the ⌘D menu item is 0013's Deselect).
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

    /// Paint.NET's plus/minus selection cursors are not reproduced (spec 0014 Out of scope).
    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor { .crosshair }
}
