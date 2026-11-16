import CoreGraphics
import Foundation

/// The single source of truth for every coordinate conversion on the canvas (spec 0003,
/// CAN-3/CAN-4/CAN-6). Later specs (0004 navigation, 0006 tool events, 0013+ overlays) must
/// convert through this type and never flip Y or apply the backing scale inline.
///
/// Coordinate spaces:
///
/// - **View space** — AppKit points in the canvas view's bounds (`CGPoint`/`CGRect`), origin
///   **bottom-left**, y up (the `MTKView` is not flipped).
/// - **Device space** — drawable pixels, origin **top-left**, y down:
///   `device = (view.x · s, (viewHeight − view.y) · s)` with `s = backingScale`. This is
///   Metal's framebuffer / `position` space.
/// - **Canvas space** — continuous image coordinates in image pixels as `Double`
///   (`CGPoint`), origin at the image's **top-left**, y down. Image pixel `(i, j)` covers
///   `[i, i+1) × [j, j+1)`; its center is `(i + 0.5, j + 0.5)`. Tool events (0006) use this
///   space.
/// - **Pixel space** — integer `PixelPoint` = `(floor(canvas.x), floor(canvas.y))` (floor,
///   not truncation: canvas `-0.25` → pixel `-1`). Not clamped to the image; callers check
///   bounds.
///
/// Zoom is measured in **device pixels per image pixel**: `zoom == 1.0` ("100 %") maps one
/// image pixel to exactly one device pixel on every display (PRD CAN-6, D-29).
struct CanvasTransform: Equatable, Sendable {
    static let minimumZoom: Double = 0.01   // 1 %
    static let maximumZoom: Double = 32     // 3200 %

    /// Origins are clamped to this magnitude so every later integer conversion
    /// (`x + width`, device-pixel indexing) is safe from `Int` overflow. Real documents
    /// (65 535 px at 3200 % ≈ 2 × 10⁶) stay many orders of magnitude below it.
    private static let originLimit: Int = 1 << 48

    var imageSize: PixelSize
    /// Points. Sanitized to finite, non-negative values by `init`.
    var viewSize: CGSize
    /// Device pixels per point (1, 2, …). Sanitized to finite and > 0 by `init`.
    var backingScale: Double
    /// Device pixels per image pixel; 1.0 = 100 %. Always inside
    /// `minimumZoom...maximumZoom`.
    private(set) var zoom: Double
    /// The canvas point shown at the view's center.
    var center: CGPoint

    init(imageSize: PixelSize, viewSize: CGSize, backingScale: Double, zoom: Double, center: CGPoint) {
        self.imageSize = imageSize
        self.viewSize = CGSize(
            width: viewSize.width.isFinite ? max(0, viewSize.width) : 0,
            height: viewSize.height.isFinite ? max(0, viewSize.height) : 0
        )
        self.backingScale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        // A non-finite or non-positive zoom can only come from a programming error; fall back
        // to 100 % rather than producing NaN geometry.
        self.zoom = zoom.isFinite && zoom > 0
            ? min(max(zoom, Self.minimumZoom), Self.maximumZoom)
            : 1.0
        self.center = center
    }

    /// The transform a document window opens with (CAN-6, D-29): `min(1, fit)` in device
    /// pixels, clamped to `[minimumZoom, maximumZoom]`, image centered. Degenerate views or
    /// images (any zero dimension) open at 100 %.
    static func initial(imageSize: PixelSize, viewSize: CGSize, backingScale: Double) -> CanvasTransform {
        var transform = CanvasTransform(
            imageSize: imageSize,
            viewSize: viewSize,
            backingScale: backingScale,
            zoom: 1,
            center: CGPoint(x: Double(imageSize.width) / 2, y: Double(imageSize.height) / 2)
        )
        let drawable = transform.drawableSize
        guard drawable.width > 0, drawable.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return transform
        }
        let fit = min(
            1,
            Double(drawable.width) / Double(imageSize.width),
            Double(drawable.height) / Double(imageSize.height)
        )
        transform.setZoom(fit)
        return transform
    }

    /// Clamps to `minimumZoom...maximumZoom`. A non-finite or non-positive zoom leaves the
    /// transform unchanged.
    mutating func setZoom(_ zoom: Double) {
        guard zoom.isFinite, zoom > 0 else { return }
        self.zoom = min(max(zoom, Self.minimumZoom), Self.maximumZoom)
    }

    /// The zoom as shown to the user: `1.0 → 100`, `0.6667 → 67` (rounded).
    var zoomPercent: Int { Int(clampedDouble: (zoom * 100).rounded()) }

    /// The drawable size in device pixels. Never negative.
    var drawableSize: (width: Int, height: Int) {
        (
            width: Int(clampedDouble: Swift.max(0, (viewSize.width * backingScale).rounded())),
            height: Int(clampedDouble: Swift.max(0, (viewSize.height * backingScale).rounded()))
        )
    }

    /// The device pixel showing canvas point `(0, 0)` (CAN-6, pixel-aligned origin).
    /// `ox = (drawableWidth / 2 − center.x · zoom).rounded()`, likewise `oy` (y counts from
    /// the device top). All conversions go through this rounded origin, so at every integer
    /// zoom `n` an image pixel covers exactly an `n × n` block of whole device pixels.
    var imageOriginInDevice: (x: Int, y: Int) {
        let drawable = drawableSize
        return (
            x: Self.clampedOrigin(Double(drawable.width) / 2 - center.x * zoom),
            y: Self.clampedOrigin(Double(drawable.height) / 2 - center.y * zoom)
        )
    }

    private static func clampedOrigin(_ value: Double) -> Int {
        let rounded = value.rounded()
        guard rounded.isFinite else { return rounded.isNaN ? 0 : (rounded > 0 ? originLimit : -originLimit) }
        return min(max(Int(clampedDouble: rounded), -originLimit), originLimit)
    }

    /// The image rectangle in device space: `(ox, oy, imageWidth · zoom, imageHeight · zoom)`.
    var imageRectInDevice: CGRect {
        let origin = imageOriginInDevice
        return CGRect(
            x: Double(origin.x),
            y: Double(origin.y),
            width: Double(imageSize.width) * zoom,
            height: Double(imageSize.height) * zoom
        )
    }

    /// The device pixels that show the image: `imageRectInDevice` rounded up to whole device
    /// pixels and clipped to the drawable. Empty when the image is scrolled out of view.
    var drawnImageRectInDevice: PixelRect {
        let origin = imageOriginInDevice
        let drawable = drawableSize
        let rect = PixelRect(
            x: origin.x,
            y: origin.y,
            width: Int(clampedDouble: (Double(imageSize.width) * zoom).rounded(.up)),
            height: Int(clampedDouble: (Double(imageSize.height) * zoom).rounded(.up))
        )
        return rect.intersection(PixelRect(x: 0, y: 0, width: drawable.width, height: drawable.height))
    }

    // MARK: - Point conversions

    func viewToDevice(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * backingScale, y: (viewSize.height - p.y) * backingScale)
    }

    func deviceToView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / backingScale, y: viewSize.height - p.y / backingScale)
    }

    func deviceToCanvas(_ p: CGPoint) -> CGPoint {
        let origin = imageOriginInDevice
        return CGPoint(
            x: (p.x - Double(origin.x)) / zoom,
            y: (p.y - Double(origin.y)) / zoom
        )
    }

    func canvasToDevice(_ p: CGPoint) -> CGPoint {
        let origin = imageOriginInDevice
        return CGPoint(
            x: Double(origin.x) + p.x * zoom,
            y: Double(origin.y) + p.y * zoom
        )
    }

    func viewToCanvas(_ p: CGPoint) -> CGPoint {
        deviceToCanvas(viewToDevice(p))
    }

    func canvasToView(_ p: CGPoint) -> CGPoint {
        deviceToView(canvasToDevice(p))
    }

    /// The affine map equal to `canvasToView(_:)` (0013): built from `canvasToView` of
    /// (0,0), (1,0), and (0,1). Overlays (marching ants, handles) transform their
    /// `CGPath`s with this and never flip Y inline (CAN-6).
    var canvasToViewAffine: CGAffineTransform {
        let origin = canvasToView(.zero)
        let unitX = canvasToView(CGPoint(x: 1, y: 0))
        let unitY = canvasToView(CGPoint(x: 0, y: 1))
        // x' = a·x + c·y + tx, y' = b·x + d·y + ty: (a, b) is the image of (1, 0) minus
        // the origin, (c, d) the image of (0, 1) minus the origin.
        return CGAffineTransform(a: unitX.x - origin.x, b: unitX.y - origin.y,
                                 c: unitY.x - origin.x, d: unitY.y - origin.y,
                                 tx: origin.x, ty: origin.y)
    }

    func viewToPixel(_ p: CGPoint) -> PixelPoint {
        let canvas = viewToCanvas(p)
        return PixelPoint(x: Int(clampedDouble: floor(canvas.x)), y: Int(clampedDouble: floor(canvas.y)))
    }

    // MARK: - Rect conversions

    /// The canvas rectangle in view space — standardized (positive size), bottom-left origin.
    func canvasRectToView(_ r: CGRect) -> CGRect {
        let a = canvasToView(r.origin)
        let b = canvasToView(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    func pixelRectToView(_ r: PixelRect) -> CGRect {
        canvasRectToView(CGRect(x: Double(r.x), y: Double(r.y), width: Double(r.width), height: Double(r.height)))
    }

    // MARK: - Visibility

    /// The canvas rectangle covered by the whole view.
    var visibleCanvasRect: CGRect {
        let origin = imageOriginInDevice
        let drawable = drawableSize
        return CGRect(
            x: (0 - Double(origin.x)) / zoom,
            y: (0 - Double(origin.y)) / zoom,
            width: Double(drawable.width) / zoom,
            height: Double(drawable.height) / zoom
        )
    }

    /// The tiles intersecting `visibleCanvasRect ∩ image bounds`; `nil` when that
    /// intersection is empty or has zero area.
    var visibleTileRange: TileRange? {
        let visible = visibleCanvasRect
        let clip = CGRect(x: 0, y: 0, width: Double(imageSize.width), height: Double(imageSize.height))
        let intersection = visible.intersection(clip)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }
        let tileSide = Double(TiledSurface.tileSize)
        // `intersection.minX/minY ≥ 0` (clipped) and `maxX/maxY > 0`; the last column/row
        // uses `ceil − 1` so an exact tile boundary (maxX = 512) does not add the next tile.
        let firstColumn = Int(floor(max(intersection.minX, 0) / tileSide))
        let firstRow = Int(floor(max(intersection.minY, 0) / tileSide))
        let lastColumn = max(firstColumn, Int(ceil(min(Double(imageSize.width), intersection.maxX) / tileSide)) - 1)
        let lastRow = max(firstRow, Int(ceil(min(Double(imageSize.height), intersection.maxY) / tileSide)) - 1)
        return TileRange(columns: firstColumn...lastColumn, rows: firstRow...lastRow)
    }
}

/// A closed, inclusive block of tile coordinates (spec 0003; `TileCoordinate` itself is 0002's).
struct TileRange: Equatable, Sendable {
    var columns: ClosedRange<Int>
    var rows: ClosedRange<Int>

    var count: Int { columns.count * rows.count }

    func contains(_ coordinate: TileCoordinate) -> Bool {
        columns.contains(coordinate.column) && rows.contains(coordinate.row)
    }

    /// Row-major (row is the outer loop).
    var coordinates: [TileCoordinate] {
        var result: [TileCoordinate] = []
        result.reserveCapacity(count)
        for row in rows {
            for column in columns {
                result.append(TileCoordinate(column: column, row: row))
            }
        }
        return result
    }
}

extension Int {
    /// The nearest `Int` of a floating-point value: `±∞` saturates to `Int.min`/`Int.max`,
    /// `NaN` becomes 0. `init(clamping:)` covers integers only, and a bare `Int(x)` traps on
    /// out-of-range or non-finite input — never acceptable on a user-reachable path.
    init(clampedDouble value: some BinaryFloatingPoint) {
        let double = Double(value)
        if double.isNaN { self = 0; return }
        if double >= Double(Int.max) { self = Int.max; return }
        if double <= Double(Int.min) { self = Int.min; return }
        self = Int(double)
    }
}
