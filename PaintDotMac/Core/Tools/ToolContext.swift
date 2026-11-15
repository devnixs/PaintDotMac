import CoreGraphics
import Foundation

/// What a tool may touch (spec 0006). The main document window's canvas session
/// (`Canvas/CanvasToolSession.swift`) implements it; tests use `FakeToolContext`.
///
/// Reserved extensions owned by later specs: 0007 adds `var colors: ColorSelection { get }`;
/// 0008 adds `commitHistory(_:)`, `performHistory(_:)`, and `updateImage(_:)`; 0009 adds
/// `var paintClipMask` and the `.brushOutline` overlay case; 0012 adds `setColor(_:for:)`;
/// 0013 adds the selection. Each spec that grows this protocol implements the new members in
/// `CanvasToolSession` and `FakeToolContext`. `activateTool(_:)` and `previousToolID` live
/// here so 0012 does not re-declare them.
@MainActor
protocol ToolContext: AnyObject {
    /// The document's image (read; pixel writes arrive with 0008's history).
    var image: LayeredImage { get }
    /// The current view ↔ canvas mapping.
    var transform: CanvasTransform { get }
    var navigation: any CanvasNavigating { get }
    /// `tool.<id>.<option>` persistence (TOOL-C).
    var options: any ToolOptionStore { get }
    /// The tool that was active before the current one (T-14's "switch to previous tool").
    var previousToolID: ToolID? { get }
    /// Requests a tool switch, deferred until the current event handler returns
    /// (see `ToolDispatcher`).
    func activateTool(_ id: ToolID)
    /// Transient vector feedback drawn above the canvas.
    func setOverlay(_ overlay: ToolOverlay?)
    /// Re-query the effective tool's cursor now.
    func invalidateCursor()
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
}
