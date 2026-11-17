import CoreGraphics
import Foundation

/// What a tool may touch (spec 0006). The main document window's canvas session
/// (`Canvas/CanvasToolSession.swift`) implements it; tests use `FakeToolContext`.
///
/// Reserved extensions owned by later specs: 0013 replaces the `paintClipMask` stub with
/// the selection mask. Each spec that grows this protocol implements the new members in
/// `CanvasToolSession` and `FakeToolContext`.
/// `activateTool(_:)` and `previousToolID` live here so 0012 does not re-declare them.
@MainActor
protocol ToolContext: AnyObject {
    /// The document's image. Pixel writes go through `updateImage(_:)` +
    /// `commitHistory(_:)` — or `performHistory(_:)` — never any other way (AGENTS rule 2).
    var image: LayeredImage { get }
    /// The current view ↔ canvas mapping.
    var transform: CanvasTransform { get }
    var navigation: any CanvasNavigating { get }
    /// `tool.<id>.<option>` persistence (TOOL-C).
    var options: any ToolOptionStore { get }
    /// The app-wide primary/secondary pair (C-1); 0009 reads it at stroke start (TOOL-A) and
    /// 0012 adds the setter path through `AppModel.setColor(_:for:)`.
    var colors: ColorSelection { get }
    /// Sets one Colors-panel slot (0012, T-14): through `AppModel.setColor(_:for:)`, which
    /// persists the pair (C-1) and updates the Colors panel. Never a history step.
    func setColor(_ color: ColorRGBA8, for slot: ColorSlot)
    /// The document's current selection (0013): `nil` = no selection, the whole image is
    /// editable. The selection tools (0014–0016) read it; painting consumes it through
    /// `paintClipMask`.
    var selection: Selection? { get }
    /// The selection clip for painting tools (0009; 0013 fills it with the selection's
    /// antialiased mask). Pixels outside it are never written (TOOL-B); `nil` clips
    /// nothing — a full-canvas mask may be reported as `nil` because
    /// `BlendOps.mul255(c, 255) == c` for all `c` (pixel-identical).
    var paintClipMask: (any BrushClipMask)? { get }
    /// The tool that was active before the current one (T-14's "switch to previous tool").
    var previousToolID: ToolID? { get }
    /// Requests a tool switch, deferred until the current event handler returns
    /// (see `ToolDispatcher`).
    func activateTool(_ id: ToolID)
    /// Transient vector feedback drawn above the canvas.
    func setOverlay(_ overlay: ToolOverlay?)
    /// Re-query the effective tool's cursor now.
    func invalidateCursor()

    // MARK: - History (spec 0008)

    /// Records a step whose changes are already in `image` (live drawing). No-op items
    /// are ignored (H-6).
    func commitHistory(_ item: any HistoryItem)
    /// Applies the item to the document, then records it.
    func performHistory(_ item: any HistoryItem)
    /// Live drawing (in-progress strokes): mutates the document's image without recording
    /// a step. The only way tools write live pixels.
    func updateImage(_ body: (inout LayeredImage) -> Void)

    // MARK: - Floating pixels and history navigation (spec 0020)

    /// The lifted (or pasted, 0021) pixels floating over the layer, or `nil` (0020).
    var floatingPixels: FloatingPixels? { get }
    /// The document's recorded steps — Escape uses them to find the session's start
    /// (0020 item 6).
    var history: HistoryStack { get }
    /// History-panel-style navigation: the tool jumps to `index` so Escape cancels a
    /// whole floating session exactly, leaving the session's steps as redo steps.
    func jumpHistory(to index: Int)
}

/// The navigation surface tools use — 0004's `CanvasNavigation` semantics, clamped
/// (0006's Zoom-rectangle uses `ZoomLevels.fitZoom(…, allowsEnlargement: true)`).
@MainActor
protocol CanvasNavigating: AnyObject {
    var transform: CanvasTransform { get }
    /// Clamps to 1 %–3200 % and keeps the canvas point under `viewPoint` under it.
    func setZoom(_ zoom: Double, anchoredAtView viewPoint: CGPoint)
    func beginPan(atView viewPoint: CGPoint)
    /// Content follows the pointer, clamped (0004).
    func continuePan(toView viewPoint: CGPoint)
    func endPan()
}

/// Transient vector feedback drawn above the canvas. Later specs add cases (lasso path,
/// shape handles, brush outline) and draw them in `Canvas/ToolOverlayView.swift`.
enum ToolOverlay: Sendable, Equatable {
    /// Canvas space, standardized.
    case zoomRectangle(CGRect)
    /// Canvas space, the brush circle's bounding square (spec 0009, D-38); drawn as the
    /// ellipse inscribed in the view-mapped rect, hidden below `BrushOutline.minimumViewDiameter`.
    case brushOutline(CGRect)
    /// The shape a selection tool drags (spec 0014), drawn in the marquee style.
    case selectionShape(SelectionShapePreview)
    /// The Lasso outline in progress (spec 0015), canvas space: the kept points in order
    /// plus the Polygon rubber-band hover point (`nil` while Freeform dragging).
    case lassoPath(points: [CGPoint], rubberBand: CGPoint?)
    /// The Move tools' transform frame with its 8 nubs (spec 0019, extended by 0020).
    case transformHandles(TransformHandlesPreview)
}

extension ToolOverlay {
    /// True when the overlay asks the marching ants to hide while it lives (0014's
    /// Replace-mode shape preview, 0019's transform-handle drag).
    var hidesCurrentSelection: Bool {
        switch self {
        case .selectionShape(let preview): preview.hidesCurrentSelection
        case .transformHandles(let preview): preview.hidesCurrentSelection
        default: false
        }
    }
}

/// The transform frame the Move tools draw (spec 0019; 0020 adds its pixel-preview use).
/// `outline` is the live outline while dragging (canvas space; `nil` when idle),
/// `corners` the frame's TL/TR/BR/BL corners (canvas space, any winding), `center` the
/// rotation-center marker shown while rotating, and `hidesCurrentSelection` the drag's
/// "the live outline replaces the ants" rule.
struct TransformHandlesPreview: Sendable, Equatable {
    private let storedOutline: SendablePath?
    /// Canvas space; the live outline while dragging, `nil` when idle.
    var outline: CGPath? { storedOutline?.path }
    var corners: [CGPoint]
    var showsHandles: Bool
    var center: CGPoint?
    var hidesCurrentSelection: Bool

    init(outline: CGPath?, corners: [CGPoint], showsHandles: Bool,
         center: CGPoint?, hidesCurrentSelection: Bool) {
        self.storedOutline = outline.map { SendablePath(path: $0) }
        self.corners = corners
        self.showsHandles = showsHandles
        self.center = center
        self.hidesCurrentSelection = hidesCurrentSelection
    }
}

/// The rectangle/ellipse outline a selection tool previews while dragging (spec 0014; the
/// Lasso 0015 previews a path instead). `rect` is a canvas-space pixel rect — an ellipse is
/// the ellipse inscribed in it, and for the ellipse tool the rect may run past the canvas
/// (the shape keeps its true form; 0013's mask clips). `hidesCurrentSelection` is the
/// Replace mode's "reset at mouse-down": the current selection's ants stay hidden while
/// the preview lives (Escape restores them — the selection itself is untouched).
struct SelectionShapePreview: Sendable, Equatable {
    enum Shape: String, Sendable, Equatable {
        case rectangle
        case ellipse
    }

    var shape: Shape
    var rect: PixelRect
    var hidesCurrentSelection: Bool
}

/// The cursor a tool requests. `location nil` in `Tool.cursor(at:modifiers:)` means the
/// pointer is outside the canvas.
enum ToolCursor: Sendable, Equatable {
    case arrow
    case crosshair
    case zoomIn
    case zoomOut
    case openHand
    case closedHand
    case iBeam
    /// Four-way move arrow (spec 0019).
    case move
    /// Rotation cursor (spec 0019).
    case rotate
    /// The frame-resize cursor matching a transform handle (spec 0019).
    case resize(TransformHandle)
}
