import CoreGraphics
import Foundation

// Navigation operations on 0003's transform (spec 0004, CAN-1/CAN-2/CAN-6). Every function
// returns a new value; none rounds `center` — device-pixel alignment stays 0003's rounded
// `imageOriginInDevice`.
extension CanvasTransform {
    /// Re-anchors `center` so panning cannot pull an image edge inside the view (the image
    /// always covers the view when it is larger), and keeps the image centered on any axis
    /// where it is smaller than the view. A zero or non-finite view size changes nothing.
    func clampedScroll() -> CanvasTransform {
        guard viewSize.width > 0, viewSize.height > 0 else { return self }
        var updated = self
        let viewWidth = Double(viewSize.width) * backingScale
        let viewHeight = Double(viewSize.height) * backingScale
        let imageWidth = Double(imageSize.width) * zoom
        let imageHeight = Double(imageSize.height) * zoom
        updated.center.x = Self.axisCenter(
            center: center.x, extent: Double(imageSize.width),
            imageExtent: imageWidth, viewExtent: viewWidth, zoom: zoom
        )
        updated.center.y = Self.axisCenter(
            center: center.y, extent: Double(imageSize.height),
            imageExtent: imageHeight, viewExtent: viewHeight, zoom: zoom
        )
        return updated
    }

    /// One axis of `clampedScroll`: centered when the zoomed image is no larger than the
    /// viewport, otherwise the canvas point at the view center keeps the image edge from
    /// coming inside the view edge. The visible half-extent is `viewExtent / (2 · zoom)`.
    private static func axisCenter(center: Double, extent: Double,
                                   imageExtent: Double, viewExtent: Double, zoom: Double) -> Double {
        let middle = extent / 2
        guard imageExtent > viewExtent else { return middle }
        let half = viewExtent / (2 * zoom)
        return min(max(center, half), extent - half)
    }

    /// Sets the zoom keeping the canvas point under `viewPoint` under it afterwards (up to
    /// 0003's ≤ ½-device-pixel origin rounding, and unless `clampedScroll` must move it).
    func zoomed(to newZoom: Double, anchoredAt viewPoint: CGPoint) -> CanvasTransform {
        let anchorCanvas = viewToCanvas(viewPoint)
        let anchorDevice = viewToDevice(viewPoint)
        let target = ZoomLevels.clamp(newZoom)
        let drawable = drawableSize
        var updated = self
        updated.center = CGPoint(
            x: anchorCanvas.x - (anchorDevice.x - Double(drawable.width) / 2) / target,
            y: anchorCanvas.y - (anchorDevice.y - Double(drawable.height) / 2) / target
        )
        updated.setZoom(target)
        return updated.clampedScroll()
    }

    /// Moves the image content by `delta` view points (content follows the delta: a positive
    /// `dy` moves content up), then clamps.
    func panned(byView delta: CGVector) -> CanvasTransform {
        guard zoom > 0 else { return self }
        var updated = self
        updated.center.x -= delta.dx * backingScale / zoom
        updated.center.y += delta.dy * backingScale / zoom
        return updated.clampedScroll()
    }

    /// Zoom to Window (CAN-1): Paint.NET's fit, capped at 100 % (CAN-6), image centered.
    /// Equals `CanvasTransform.initial` for the same sizes.
    func fittedToWindow() -> CanvasTransform {
        let drawable = drawableSize
        var updated = self
        updated.setZoom(ZoomLevels.fitZoom(
            contentSize: CGSize(width: Double(imageSize.width), height: Double(imageSize.height)),
            viewportSize: CGSize(width: Double(drawable.width), height: Double(drawable.height)),
            allowsEnlargement: false
        ))
        updated.center = CGPoint(x: Double(imageSize.width) / 2, y: Double(imageSize.height) / 2)
        return updated.clampedScroll()
    }

    /// A canvas-size change (0021's expanding Paste first; 0022 and 0035–0037 reuse it
    /// unchanged): same `viewSize`, `backingScale`, and **zoom**, `imageSize = size`, the
    /// new image centered, then `clampedScroll` (PRD Open question 5's rule — the zoom is
    /// kept, the image re-centers). Returns `self` when the size is unchanged, so a
    /// structure change that keeps the size (a layer op) never jumps the scroll.
    func withImageSize(_ size: PixelSize) -> CanvasTransform {
        guard size != imageSize else { return self }
        var updated = self
        updated.imageSize = size
        updated.center = CGPoint(x: Double(size.width) / 2, y: Double(size.height) / 2)
        return updated.clampedScroll()
    }

    /// Window resize: keeps the zoom and the canvas point at the view center, then re-clamps.
    /// A zero new size updates only `viewSize` (`clampedScroll` is a no-op there).
    func resized(to newViewSize: CGSize) -> CanvasTransform {
        var updated = self
        updated.viewSize = newViewSize
        return updated.clampedScroll()
    }

    /// Zoom to Selection (CAN-1, spec 0014): Paint.NET's "Zoom to Selection" — the rect
    /// fitted into the view with `ZoomLevels.fitZoom(…, allowsEnlargement: true)` (clamped
    /// 1 %–3200 % by `fitZoom`), the rect centered, then `clampedScroll` (the selection is
    /// "as centered as the image edges allow"). A rect with a zero or non-finite side or
    /// origin, or a zero view size, changes nothing.
    func zoomedToFit(_ rect: CGRect) -> CanvasTransform {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return self }
        let drawable = drawableSize
        var updated = self
        updated.setZoom(ZoomLevels.fitZoom(
            contentSize: CGSize(width: rect.width, height: rect.height),
            viewportSize: CGSize(width: Double(drawable.width), height: Double(drawable.height)),
            allowsEnlargement: true
        ))
        updated.center = CGPoint(x: rect.midX, y: rect.midY)
        return updated.clampedScroll()
    }
}
