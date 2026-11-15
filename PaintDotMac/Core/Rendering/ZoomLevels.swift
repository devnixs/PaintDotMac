import CoreGraphics
import Foundation

/// The zoom stop ladder, clamping, and zoom arithmetic (spec 0004, CAN-1/CAN-2, D-29).
/// Pure math over the `CanvasTransform` zoom unit (device pixels per image pixel, CAN-6).
enum ZoomLevels {
    /// CAN-1's range: 1 % … 3200 % (Paint.NET 4's `MinValue`/`MaxValue`).
    static let minimum: Double = 0.01
    static let maximum: Double = 32.0

    /// Paint.NET 4's `ScaleFactor.scales` (decompiled `ScaleFactor.cs`) with 1 % added as the
    /// lowest stop (D-29) so Zoom Out reaches the CAN-1 minimum and never zooms *in* (Paint.NET's
    /// own `GetNextSmaller()` bounces up to 3.125 % from 2 %). Ascending; 24 values.
    static let stops: [Double] = [
        0.01,
        1.0 / 32.0, 1.0 / 24.0, 1.0 / 16.0, 1.0 / 12.0, 1.0 / 8.0, 1.0 / 6.0, 1.0 / 5.0,
        1.0 / 4.0, 1.0 / 3.0, 1.0 / 2.0, 2.0 / 3.0, 1.0,
        3.0 / 2.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 12.0, 16.0, 24.0, 32.0,
    ]

    /// Relative slack so a zoom that landed within a hair of a stop (pinch, scroll) steps to
    /// the *next* stop instead of "repeating" the current one.
    static let tolerance: Double = 0.001

    /// Clamps to `[minimum, maximum]`; a non-finite or ≤ 0 input returns 1.0.
    static func clamp(_ zoom: Double) -> Double {
        guard zoom.isFinite, zoom > 0 else { return 1.0 }
        return min(max(zoom, minimum), maximum)
    }

    /// The first stop strictly above `zoom · (1 + tolerance)`; `nil` at (or within tolerance of)
    /// the maximum.
    static func nextLarger(than zoom: Double) -> Double? {
        guard zoom.isFinite else { return nil }
        return stops.first { $0 > zoom * (1 + tolerance) }
    }

    /// The last stop strictly below `zoom / (1 + tolerance)`; `nil` at (or within tolerance of)
    /// the minimum.
    static func nextSmaller(than zoom: Double) -> Double? {
        guard zoom.isFinite else { return nil }
        return stops.last { $0 < zoom / (1 + tolerance) }
    }

    static func canZoomIn(from zoom: Double) -> Bool { nextLarger(than: zoom) != nil }

    static func canZoomOut(from zoom: Double) -> Bool { nextSmaller(than: zoom) != nil }

    /// `min(viewportW / contentW, viewportH / contentH)`, capped at 1.0 when
    /// `allowsEnlargement == false` (Zoom to Window), then `clamp`. A ≤ 0 or non-finite
    /// dimension on either size returns 1.0. Both sizes are in the zoom's unit: content in
    /// image pixels, viewport in *device* pixels (CAN-6). No margin.
    static func fitZoom(contentSize: CGSize, viewportSize: CGSize, allowsEnlargement: Bool) -> Double {
        let values = [contentSize.width, contentSize.height, viewportSize.width, viewportSize.height]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return 1.0 }
        var fit = min(
            Double(viewportSize.width / contentSize.width),
            Double(viewportSize.height / contentSize.height)
        )
        if !allowsEnlargement { fit = min(fit, 1.0) }
        return clamp(fit)
    }

    /// Pinch: `clamp(zoom · (1 + magnification))`. `1 + magnification ≤ 0` or a non-finite
    /// magnification leaves the zoom unchanged.
    static func zoom(_ zoom: Double, magnifiedBy magnification: Double) -> Double {
        guard magnification.isFinite, 1 + magnification > 0 else { return zoom }
        return clamp(zoom * (1 + magnification))
    }

    /// ⌘+scroll zoom. Precise (trackpad) deltas are points: 100 points double the zoom.
    /// Non-precise (mouse wheel) events step exactly one stop per event, regardless of the
    /// delta's magnitude; a zero delta (or a limit) leaves the zoom unchanged.
    static func zoom(_ zoom: Double, scrolledBy deltaY: Double, isPrecise: Bool) -> Double {
        guard deltaY.isFinite, deltaY != 0 else { return zoom }
        if isPrecise {
            return clamp(zoom * pow(2.0, deltaY / 100.0))
        }
        if deltaY > 0 { return nextLarger(than: zoom) ?? zoom }
        return nextSmaller(than: zoom) ?? zoom
    }

    /// The status-bar zoom string: `1 → "100%"`, `1/8 → "13%"` (half away from zero).
    static func percentString(_ zoom: Double) -> String {
        "\(Int(clamped: (zoom * 100).rounded(.toNearestOrAwayFromZero)))%"
    }
}

private extension Int {
    /// Total `Double → Int` for the zoom display: non-finite or out-of-range input cannot
    /// trap (a NaN zoom must never crash the status bar).
    init(clamped value: Double) {
        guard value.isFinite, value >= -9.0e18, value <= 9.0e18 else { self = 0; return }
        self.init(value)
    }
}
