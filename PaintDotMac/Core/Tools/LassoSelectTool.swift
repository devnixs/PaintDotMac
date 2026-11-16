import CoreGraphics
import Foundation

/// The Lasso Select drawing mode (spec 0015, PRD T-2 / D-39; Paint.NET 5 toolbar):
/// **Freeform** drags a freehand outline; **Polygon** clicks straight-edge vertices.
enum LassoMode: String, CaseIterable, Sendable {
    case freeform
    case polygon

    var displayName: String {
        switch self {
        case .freeform: "Freeform"
        case .polygon: "Polygon"
        }
    }
}

/// The pure lasso point list and its rules (spec 0015): view-space point thinning, the
/// always-kept release point, the degeneracy rule, and the closing straight line back to
/// the start with the **even-odd** fill rule (D-39 — a self-crossing outline encloses its
/// double-covered regions zero times, Paint.NET's `PdnGraphicsPath` alternate fill mode).
struct LassoPath: Sendable, Equatable {
    /// Canvas space, unsnapped Doubles. Points outside the canvas are kept — the
    /// rasterizer clips (0013).
    private(set) var points: [CGPoint] = []
    /// The view location of the last kept point (the thinning reference).
    private(set) var lastViewPoint: CGPoint?

    /// Freeform point thinning (spec 0015): a sample is kept only when it sits at least
    /// this many **view points** from the last kept point. Thinning in view space adapts
    /// to zoom — at 3200 % consecutive points can be 1/32 canvas px apart, at 10 % about
    /// 10 canvas px. No further simplification: the outline follows the pointer exactly
    /// as sampled.
    static let minimumViewSpacing: Double = 1.0

    /// Appends only when empty or at least `minimumViewSpacing` view points from
    /// `lastViewPoint`.
    mutating func appendFreeform(_ p: CGPoint, view v: CGPoint) {
        if let last = lastViewPoint {
            let dx = v.x - last.x
            let dy = v.y - last.y
            guard dx * dx + dy * dy >= Self.minimumViewSpacing * Self.minimumViewSpacing
            else { return }
        }
        points.append(p)
        lastViewPoint = v
    }

    /// The mouseUp point: appended unless it equals the last point exactly (no thinning —
    /// the outline ends where the pointer was released).
    mutating func appendFinal(_ p: CGPoint, view v: CGPoint) {
        guard points.last != p else { return }
        points.append(p)
        lastViewPoint = v
    }

    /// A Polygon-mode vertex (no thinning).
    mutating func appendVertex(_ p: CGPoint, view v: CGPoint) {
        points.append(p)
        lastViewPoint = v
    }

    /// Moves the just-placed vertex while its mouse is held down (press-and-drag).
    mutating func moveLastVertex(to p: CGPoint, view v: CGPoint) {
        guard !points.isEmpty else { return }
        points[points.count - 1] = p
        lastViewPoint = v
    }

    /// `true` when fewer than 3 distinct points, or all points are collinear: with
    /// `p0 = points[0]` and `pf` the point farthest from `p0`,
    /// `max_i |cross(pf − p0, p_i − p0)| ≤ 1e-9 × max(1, |pf − p0|)`. A figure-eight with
    /// zero *signed* area is not degenerate. Coordinates are bounded by the router's
    /// finite-value filter, so every Double product here stays finite.
    var isDegenerate: Bool {
        var distinct: [CGPoint] = []
        for p in points {
            if !distinct.contains(p) {
                distinct.append(p)
                if distinct.count >= 3 { break }
            }
        }
        guard distinct.count >= 3 else { return true }
        let p0 = points[0]
        var farthest = p0
        var bestDistance = -Double.infinity
        for p in points {
            let dx = p.x - p0.x
            let dy = p.y - p0.y
            let distance = dx * dx + dy * dy
            if distance > bestDistance {
                bestDistance = distance
                farthest = p
            }
        }
        let vx = farthest.x - p0.x
        let vy = farthest.y - p0.y
        var maxCross = 0.0
        for p in points {
            let cross = abs(vx * (p.y - p0.y) - vy * (p.x - p0.x))
            if cross > maxCross { maxCross = cross }
        }
        return maxCross <= 1e-9 * max(1, (vx * vx + vy * vy).squareRoot())
    }

    /// The closed outline: `nil` when `isDegenerate`; otherwise `move(to: points[0])`,
    /// `addLine(to:)` each following point, `closeSubpath()` — the straight closing line
    /// back to the start, as in Paint.NET — returned as `path.normalized(using:
    /// .evenOdd)`. The normalized path encloses exactly the even-odd region and fills
    /// identically under either rule, so 0013's `Selection` (which normalizes again with
    /// the `fillRule` it is given — a no-op here) and later path combinations stay
    /// correct. An empty normalized path gives `nil`.
    func closedPath() -> CGPath? {
        guard !isDegenerate else { return nil }
        let outline = CGMutablePath()
        outline.move(to: points[0])
        for p in points.dropFirst() { outline.addLine(to: p) }
        outline.closeSubpath()
        let normalized = outline.normalized(using: .evenOdd)
        guard !normalized.isEmpty else { return nil }
        return normalized
    }
}

/// The Lasso Select tool (T-2, spec 0015; Paint.NET LassoSelectionTool.html). Freeform
/// drags a freehand outline that follows the pointer; Polygon clicks vertices with a
/// rubber band. Either way the shape closes with a straight line back to the start, and
/// self-crossing outlines select with the even-odd rule (D-39). The modes, the click
/// rule, and the commit bookkeeping are 0014's: `SelectionToolOptions.combineMode` is
/// latched at the first mouseDown, `SelectionCommit.finish` records the single "Lasso
/// Select" step (or the click-without-drag outcome), and nothing rasterizes until the
/// outline finishes — per-event work stays O(new points).
@MainActor
final class LassoSelectTool: Tool {
    let id: ToolID = .lassoSelect

    /// `tool.lassoSelect.lassoMode` (TOOL-C), stored as the raw string; an unknown
    /// stored value reads as `.freeform`.
    static let lassoModeKey = ToolOptionKey<String>(
        tool: .lassoSelect, name: "lassoMode", defaultValue: "freeform")

    /// Polygon mode: a mouseDown within this many view points of the first vertex (with
    /// ≥ 3 vertices) closes the polygon instead of adding a vertex.
    static let closeSnapDistance: Double = 6

    private enum Phase: Equatable {
        case idle
        case freeformDragging
        case polygonEditing(vertexDragActive: Bool)
    }

    private var phase: Phase = .idle
    /// The live outline (exposed read-only for tests; the overlay draws it).
    private(set) var path = LassoPath()
    /// Latched at the first mouseDown of the lasso — never re-read mid-lasso (Paint.NET
    /// `SelectionTool.OnMouseDown`, spec 0014).
    private var combineMode: SelectionCombineMode?
    /// The Polygon hover point the rubber band follows (canvas space).
    private var rubberBand: CGPoint?
    private var finishOnMouseUp = false
    /// The mode the running polygon was started with — a change while editing commits it
    /// (the user's work is kept, not lost).
    private var editingMode: LassoMode?

    var hasPendingEdit: Bool { phase != .idle }

    private static func mode(from context: any ToolContext) -> LassoMode {
        LassoMode(rawValue: context.options.value(Self.lassoModeKey)) ?? .freeform
    }

    private func updateOverlay(context: any ToolContext) {
        context.setOverlay(.lassoPath(points: path.points, rubberBand: rubberBand))
    }

    func mouseDown(_ event: ToolEvent, context: any ToolContext) {
        switch phase {
        case .idle:
            combineMode = SelectionToolOptions.combineMode(
                picker: context.options.value(SelectionToolOptions.combineMode),
                button: event.button, modifiers: event.modifiers)
            path = LassoPath()
            rubberBand = nil
            finishOnMouseUp = false
            let mode = Self.mode(from: context)
            switch mode {
            case .freeform:
                path.appendFreeform(event.location, view: event.viewLocation)
                phase = .freeformDragging
            case .polygon:
                path.appendVertex(event.location, view: event.viewLocation)
                editingMode = mode
                phase = .polygonEditing(vertexDragActive: true)
            }
            updateOverlay(context: context)
        case .freeformDragging:
            break   // a second buttonDown never reaches the tool mid-gesture (0006)
        case .polygonEditing:
            if event.clickCount >= 2 {
                // Double-click finishes; the first click of the pair placed the vertex.
                finishOnMouseUp = true
            } else if path.points.count >= 3, let first = path.points.first,
                      hypot(event.viewLocation.x - context.transform.canvasToView(first).x,
                            event.viewLocation.y - context.transform.canvasToView(first).y)
                        <= Self.closeSnapDistance {
                // A click on the first vertex closes the polygon.
                finishOnMouseUp = true
            } else {
                path.appendVertex(event.location, view: event.viewLocation)
                phase = .polygonEditing(vertexDragActive: true)
                updateOverlay(context: context)
            }
        }
    }

    func mouseDragged(_ event: ToolEvent, context: any ToolContext) {
        switch phase {
        case .idle:
            break
        case .freeformDragging:
            path.appendFreeform(event.location, view: event.viewLocation)
            updateOverlay(context: context)
        case .polygonEditing(let vertexDragActive):
            guard vertexDragActive else { return }
            path.moveLastVertex(to: event.location, view: event.viewLocation)
            updateOverlay(context: context)
        }
    }

    func mouseUp(_ event: ToolEvent, context: any ToolContext) {
        switch phase {
        case .idle:
            break
        case .freeformDragging:
            path.appendFinal(event.location, view: event.viewLocation)
            finish(context: context)
        case .polygonEditing:
            phase = .polygonEditing(vertexDragActive: false)
            if finishOnMouseUp { finish(context: context) }
        }
    }

    /// Polygon mode: the rubber band follows the hover point.
    func mouseMoved(_ event: ToolEvent, context: any ToolContext) {
        guard case .polygonEditing = phase else { return }
        rubberBand = event.location
        updateOverlay(context: context)
    }

    /// Return/Enter (also tool or document switch, undo, and save via 0008's
    /// `prepareForNavigation`): finish the outline; idle is a no-op.
    func commit(context: any ToolContext) {
        guard phase != .idle else { return }
        finish(context: context)
    }

    /// Escape: no step, selection and ants unchanged.
    func cancel(context: any ToolContext) {
        path = LassoPath()
        rubberBand = nil
        finishOnMouseUp = false
        combineMode = nil
        editingMode = nil
        phase = .idle
        context.setOverlay(nil)
    }

    func optionsDidChange(context: any ToolContext) {
        // Changing the Lasso mode mid-polygon commits the work in hand.
        guard case .polygonEditing = phase, editingMode != nil,
              Self.mode(from: context) != editingMode else { return }
        commit(context: context)
    }

    /// Paint.NET's plus/minus selection cursors are not reproduced (0014's decision);
    /// the lasso is Rectangle Select's crosshair.
    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor { .crosshair }

    /// Rasterizes the closed outline once, hands the result to 0014's `SelectionCommit`,
    /// and resets to idle. A degenerate outline (plain click, straight-line drag, fewer
    /// than 3 non-collinear points) takes 0014's click-without-drag rule: Replace
    /// clears the selection ("Deselect"), the append modes do nothing.
    private func finish(context: any ToolContext) {
        context.setOverlay(nil)
        defer {
            path = LassoPath()
            rubberBand = nil
            finishOnMouseUp = false
            combineMode = nil
            editingMode = nil
            phase = .idle
        }
        guard let mode = combineMode else { return }
        let outcome: SelectionGestureOutcome
        var newSelection: Selection?
        if let closed = path.closedPath() {
            outcome = .emit
            newSelection = Selection(path: closed, canvasSize: context.image.size,
                                     antialiased: context.options.value(SelectionToolOptions.quality)
                                         == .antialiased,
                                     fillRule: .evenOdd)
        } else {
            outcome = mode == .replace ? .clear : .reset
        }
        SelectionCommit.finish(outcome: outcome, newSelection: newSelection, mode: mode,
                               name: "Lasso Select", icon: .lassoSelect, context: context)
    }
}
