import CoreGraphics

// 0006: `CanvasNavigation` is the `CanvasNavigating` tools navigate through — the same
// clamped 0004 `setZoom`/`beginPan`/`continuePan`/`endPan` entry points.
extension CanvasNavigation: CanvasNavigating {
    /// The transform 0004 last assigned to `CanvasView`. A detached navigation (canvas view
    /// gone) reports a 1×1 / 100 % transform rather than crashing.
    var transform: CanvasTransform {
        currentTransform ?? CanvasTransform(
            imageSize: PixelSize(width: 1, height: 1),
            viewSize: .zero,
            backingScale: 1,
            zoom: 1,
            center: CGPoint(x: 0.5, y: 0.5)
        )
    }
}
