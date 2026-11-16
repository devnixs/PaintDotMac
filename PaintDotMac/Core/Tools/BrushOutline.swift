import CoreGraphics
import Foundation

/// The brush-outline circle (spec 0009, PRD D-38), pure geometry reused by 0011's Eraser.
/// `canvasRect` is the circle's bounding square in canvas space, so the outline scales with
/// zoom; `viewRect` maps it through 0003's `canvasRectToView` for `ToolOverlayView`.
enum BrushOutline {
    /// Below this view diameter (points) only the crosshair is shown (a width-2 brush at
    /// 1 % zoom is 0.02 device pixels — drawing it would just blur the pointer).
    static let minimumViewDiameter: Double = 3

    /// Antialiased: side = `width`, centred on `center`. Aliased: side = the rounded width
    /// and centre = `BrushEngine.snappedCenter`, so the circle sits on the pixels a click
    /// paints. A non-finite `center` → `.null`. Stored width is clamped.
    static func canvasRect(center: CGPoint, options: BrushOptions) -> CGRect {
        guard center.x.isFinite, center.y.isFinite else { return .null }
        let options = options.clamped()
        if options.antialiasing {
            let side = options.width
            return CGRect(x: center.x - side / 2, y: center.y - side / 2,
                          width: side, height: side)
        }
        let side = Double(BrushEngine.aliasedWidth(options.width))
        let snapped = BrushEngine.snappedCenter(center, width: options.width)
        return CGRect(x: snapped.x - side / 2, y: snapped.y - side / 2,
                      width: side, height: side)
    }

    /// Points; width = `side × zoom / backingScale`. `.null` input → `.null`.
    static func viewRect(center: CGPoint, options: BrushOptions,
                         transform: CanvasTransform) -> CGRect {
        let rect = canvasRect(center: center, options: options)
        guard !rect.isNull else { return .null }
        return transform.canvasRectToView(rect)
    }
}
