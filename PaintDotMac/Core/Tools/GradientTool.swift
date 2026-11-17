import CoreGraphics
import Foundation

// The Gradient tool (spec 0023; PRD T-10, TOOL-A, TOOL-B, TOOL-C, APP-4). One gesture is one
// "Gradient" history step: mouse-down captures the layer surface, the selection clip, and
// the colors (D-50b); every drag re-renders the whole gradient live from that snapshot
// through `context.updateImage`; Return / Finish / tool switch / a click outside the handles
// commits the touched tiles as a `TileDiffHistoryItem` (H-6/D-34: an empty diff records
// nothing); Escape restores the snapshot with no step.

// MARK: - Options

/// The Gradient's options (TOOL-C): `tool.gradient.type`, `.mode`, `.antialiasing`,
/// `.blendMode`. Missing or unknown stored values read as the defaults.
struct GradientOptions: Equatable, Sendable {
    /// Paint.NET's Gradient Tool defaults (spec *Acceptance*).
    static let `default` = GradientOptions(type: .linear, mode: .color, antialiasing: true,
                                           blendMode: .normal)

    var type: GradientType
    var mode: GradientMode
    var antialiasing: Bool
    /// D-15: the list grows with the implemented layer modes; ignored in Transparency Mode.
    var blendMode: BlendMode

    /// The four `tool.gradient.*` keys (TOOL-C, AGENTS.md rule 6).
    static func keys() -> (type: ToolOptionKey<GradientType>, mode: ToolOptionKey<GradientMode>,
                           antialiasing: ToolOptionKey<Bool>,
                           blendMode: ToolOptionKey<BlendMode>) {
        (
            ToolOptionKey(tool: .gradient, name: "type", defaultValue: `default`.type),
            ToolOptionKey(tool: .gradient, name: "mode", defaultValue: `default`.mode),
            ToolOptionKey(tool: .gradient, name: "antialiasing",
                          defaultValue: `default`.antialiasing),
            ToolOptionKey(tool: .gradient, name: "blendMode", defaultValue: `default`.blendMode)
        )
    }

    /// Reads the store (missing or wrong-typed storage yields the default).
    @MainActor
    static func load(from store: any ToolOptionStore) -> GradientOptions {
        let keys = Self.keys()
        return GradientOptions(type: store.value(keys.type),
                               mode: store.value(keys.mode),
                               antialiasing: store.value(keys.antialiasing),
                               blendMode: store.value(keys.blendMode))
    }

    /// Persists all four values under `tool.gradient.*`.
    @MainActor
    func save(to store: any ToolOptionStore) {
        let keys = Self.keys()
        store.setValue(type, for: keys.type)
        store.setValue(mode, for: keys.mode)
        store.setValue(antialiasing, for: keys.antialiasing)
        store.setValue(blendMode, for: keys.blendMode)
    }
}

// MARK: - Handle geometry

/// Which endpoint of the pending gradient the pointer grabbed.
enum GradientHandle: Sendable, Equatable {
    case start, end
}

/// The Gradient's pure handle math (spec 0023): Shift snapping and view-space hit testing.
enum GradientGeometry {
    /// Paint.NET snaps the gradient angle to 15° steps while Shift is held.
    static let snapStepDegrees: Double = 15
    /// Handle grab radius in view points (0006's `viewLocation` space, so it is zoom-
    /// independent — 0019's nub convention).
    static let handleHitRadius: Double = 6

    /// Shift: keeps `|moving − anchor|` and rounds the angle of `moving − anchor` to the
    /// nearest 15° (ties away from zero). Zero length → `anchor`.
    static func snapped(_ moving: CGPoint, anchor: CGPoint) -> CGPoint {
        let dx = moving.x - anchor.x
        let dy = moving.y - anchor.y
        let radius = hypot(dx, dy)
        guard radius > 0 else { return anchor }
        let step = snapStepDegrees * .pi / 180
        let angle = (atan2(dy, dx) / step).rounded(.toNearestOrAwayFromZero) * step
        return CGPoint(x: anchor.x + radius * cos(angle), y: anchor.y + radius * sin(angle))
    }

    /// The handle under the view point (within `handleHitRadius` of the handle's view
    /// position); both in range → the nearer; an exact tie → `.end`.
    static func hitHandle(atView p: CGPoint, start: CGPoint, end: CGPoint,
                          transform: CanvasTransform) -> GradientHandle? {
        let startView = transform.canvasToView(start)
        let endView = transform.canvasToView(end)
        let startDistance = hypot(p.x - startView.x, p.y - startView.y)
        let endDistance = hypot(p.x - endView.x, p.y - endView.y)
        let nearStart = startDistance <= handleHitRadius
        let nearEnd = endDistance <= handleHitRadius
        switch (nearStart, nearEnd) {
        case (false, false): return nil
        case (true, false): return .start
        case (false, true): return .end
        case (true, true): return startDistance < endDistance ? .start : .end
        }
    }
}

// MARK: - Tool

/// The Gradient tool (PRD T-10): five types, Color and Transparency modes, editable handles.
/// `idle` → `drawing` → `editing` ⇄ `draggingHandle`; the pending gradient stays live on the
/// canvas until commit (Paint.NET's Control-Nub editing).
@MainActor
final class GradientTool: Tool {
    let id: ToolID = .gradient

    private enum State {
        case idle
        case drawing
        case editing
        case draggingHandle(GradientHandle)
    }

    /// Everything frozen at gesture start plus the live handles: the layer, its surface
    /// snapshot (COW — free), the selection clip captured at gesture start (TOOL-B, fixed
    /// for the pending gradient), the colors (D-50b), the button reversal, the two handle
    /// positions, and the union of every `render` result (the diff candidates, NF-4).
    private struct Pending {
        var layerID: Layer.ID
        var before: TiledSurface
        var clip: (any BrushClipMask)?
        var primary: ColorRGBA8
        var secondary: ColorRGBA8
        var reversed: Bool
        var start: CGPoint
        var end: CGPoint
        var touchedTiles: Set<TileCoordinate>
    }

    private var state: State = .idle
    private var pending: Pending?
    /// Whether the hover pointer sits over a handle — `mouseMoved` remembers it because the
    /// pure `hitHandle` needs view coordinates the cursor API does not receive.
    private var pointerOverHandle = false

    var hasPendingEdit: Bool { pending != nil }

    // MARK: - Lifecycle

    /// Default behavior (commit a pending gradient, 0006), then hide the handles.
    func deactivate(context: any ToolContext) {
        if hasPendingEdit { commit(context: context) }
        context.setOverlay(nil)
    }

    // MARK: - Pointer

    func mouseDown(_ event: ToolEvent, context: any ToolContext) {
        switch state {
        case .idle:
            beginGesture(at: event, context: context)
        case .editing:
            guard let pending else { return }
            if let handle = GradientGeometry.hitHandle(atView: event.viewLocation,
                                                       start: pending.start, end: pending.end,
                                                       transform: context.transform) {
                state = .draggingHandle(handle)
                if event.button == .secondary {
                    // Paint.NET: right-clicking a nub swaps the Primary/Secondary roles.
                    var updated = pending
                    updated.reversed.toggle()
                    self.pending = updated
                    rerender(context: context)
                }
                context.invalidateCursor()
                return
            }
            // Outside the handles: commit the pending gradient, then start a new one here.
            commit(context: context)
            beginGesture(at: event, context: context)
        case .drawing, .draggingHandle:
            // A second button pressed mid-gesture is ignored (0006's dispatcher drops it
            // too; defensive here for direct drivers).
            break
        }
    }

    func mouseDragged(_ event: ToolEvent, context: any ToolContext) {
        guard var pending else { return }
        switch state {
        case .drawing:
            pending.end = Self.dragPoint(to: event.location, anchor: pending.start,
                                         shifted: event.modifiers.contains(.shift))
        case .draggingHandle(let handle):
            let anchor = handle == .start ? pending.end : pending.start
            let point = Self.dragPoint(to: event.location, anchor: anchor,
                                       shifted: event.modifiers.contains(.shift))
            if handle == .start { pending.start = point } else { pending.end = point }
        case .idle, .editing:
            return
        }
        self.pending = pending
        rerender(context: context)
        updateOverlay(context: context)
    }

    func mouseUp(_ event: ToolEvent, context: any ToolContext) {
        guard var pending else { return }
        switch state {
        case .drawing:
            // Apply the drag rule once more at the release point.
            pending.end = Self.dragPoint(to: event.location, anchor: pending.start,
                                         shifted: event.modifiers.contains(.shift))
            self.pending = pending
            rerender(context: context)
            guard pending.start != pending.end else {
                // Zero-length gesture: nothing changed, no step, back to idle.
                cancelRestoringBefore(context: context)
                return
            }
            guard self.pending != nil else { return }  // the layer vanished → rerender cancelled
            state = .editing
        case .draggingHandle:
            // Even degenerate (handles coinciding renders nothing): the gradient stays
            // pending and can be dragged apart again.
            state = .editing
        case .idle, .editing:
            return
        }
        updateOverlay(context: context)
        context.invalidateCursor()
    }

    func mouseMoved(_ event: ToolEvent, context: any ToolContext) {
        guard let pending, case .editing = state,
              GradientGeometry.hitHandle(atView: event.viewLocation, start: pending.start,
                                         end: pending.end,
                                         transform: context.transform) != nil
        else {
            if pointerOverHandle {
                pointerOverHandle = false
                context.invalidateCursor()
            }
            return
        }
        if !pointerOverHandle {
            pointerOverHandle = true
            context.invalidateCursor()
        }
    }

    /// Shift keeps the anchor→pointer distance and snaps the angle to 15° steps.
    private static func dragPoint(to location: CGPoint, anchor: CGPoint,
                                  shifted: Bool) -> CGPoint {
        shifted ? GradientGeometry.snapped(location, anchor: anchor) : location
    }

    /// TOOL-A: right button (Control-left arrives as `.secondary`) reverses the colors.
    private func beginGesture(at event: ToolEvent, context: any ToolContext) {
        let image = context.image
        guard image.layers.indices.contains(image.activeLayerIndex) else { return }
        pending = Pending(
            layerID: image.layers[image.activeLayerIndex].id,
            before: image.layers[image.activeLayerIndex].surface,  // COW snapshot, free
            clip: context.paintClipMask,
            primary: context.colors.primary,
            secondary: context.colors.secondary,
            reversed: event.button == .secondary,
            start: event.location,
            end: event.location,
            touchedTiles: []
        )
        state = .drawing
        // Nothing is rendered yet — a zero-length gradient is degenerate.
        updateOverlay(context: context)
    }

    // MARK: - Rendering

    /// Re-renders the pending gradient from the gesture's `before` snapshot with the
    /// current handles and the freshly-read options; accumulates the visited tiles. A
    /// degenerate handle pair writes `before` back (renders nothing). The layer disappearing
    /// mid-gesture cancels the pending gradient.
    private func rerender(context: any ToolContext) {
        guard var pending else { return }
        let options = GradientOptions.load(from: context.options)
        let endpoints = GradientRenderer.endpointColors(mode: options.mode,
                                                        primary: pending.primary,
                                                        secondary: pending.secondary,
                                                        reversed: pending.reversed)
        let parameters = GradientParameters(type: options.type, mode: options.mode,
                                            start: pending.start, end: pending.end,
                                            startColor: endpoints.start, endColor: endpoints.end,
                                            antialiasing: options.antialiasing,
                                            blendMode: options.blendMode)
        let before = pending.before
        let clip = pending.clip
        let layerID = pending.layerID
        var visited: Set<TileCoordinate> = []
        var layerGone = false
        context.updateImage { image in
            guard let index = image.layerIndex(for: layerID) else {
                layerGone = true
                return
            }
            if parameters.isDegenerate {
                image.layers[index].surface = before
            } else {
                visited = GradientRenderer.render(parameters, before: before,
                                                  into: &image.layers[index].surface,
                                                  clip: clip)
            }
        }
        guard !layerGone else {
            cancel(context: context)
            return
        }
        pending.touchedTiles.formUnion(visited)
        self.pending = pending
    }

    private func updateOverlay(context: any ToolContext) {
        guard let pending else { return }
        context.setOverlay(.gradientHandles(start: pending.start, end: pending.end))
    }

    // MARK: - Commit / cancel

    /// Return / Enter (the default `keyDown`), Finish, tool switch, document switch,
    /// `prepareForHistoryNavigation` before undo/redo/jump/save and commands, or a mouse
    /// down outside the handles: the live pixels are already in place, so a non-empty diff
    /// becomes the single "Gradient" step and an empty one records nothing (H-6/D-34). A
    /// degenerate pending gradient behaves like `cancel`.
    func commit(context: any ToolContext) {
        guard let pending else { return }
        self.pending = nil
        state = .idle
        pointerOverHandle = false
        guard let index = context.image.layerIndex(for: pending.layerID) else {
            // The layer disappeared: nothing to record (cancel's write-back also skips).
            context.setOverlay(nil)
            return
        }
        guard pending.start != pending.end else {
            cancelRestoringBefore(context: context)
            return
        }
        let diff = TileDiff.between(before: pending.before,
                                    after: context.image.layers[index].surface,
                                    layerID: pending.layerID,
                                    candidates: pending.touchedTiles)
        context.commitHistory(TileDiffHistoryItem(name: "Gradient", icon: .gradient,
                                                 diff: diff))
        context.setOverlay(nil)
        context.invalidateCursor()
    }

    /// Escape: the layer returns bit-identical to the snapshot (shared tile storage, absent
    /// tiles absent again), no history step, handles gone.
    func cancel(context: any ToolContext) {
        guard pending != nil else { return }
        cancelRestoringBefore(context: context)
    }

    /// Shared restore path: writes `before` back inside `updateImage`, clears the state and
    /// the overlay (no step).
    private func cancelRestoringBefore(context: any ToolContext) {
        guard let pending else { return }
        self.pending = nil
        state = .idle
        pointerOverHandle = false
        let before = pending.before
        let layerID = pending.layerID
        context.updateImage { image in
            guard let index = image.layerIndex(for: layerID) else { return }
            image.layers[index].surface = before
        }
        context.setOverlay(nil)
        context.invalidateCursor()
    }

    // MARK: - Options

    /// Paint.NET restyles the pending gradient live; the parameters are re-read on every
    /// re-render, so a re-render is all it takes.
    func optionsDidChange(context: any ToolContext) {
        guard pending != nil else { return }
        rerender(context: context)
    }

    // MARK: - Cursor

    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor {
        if case .draggingHandle = state { return .closedHand }
        if pointerOverHandle { return .openHand }
        return location == nil ? .arrow : .crosshair
    }
}
