import CoreGraphics
import Foundation

/// T-5 "Move Selected Pixels — M — moves the selected pixels" (PRD §5.3; spec 0020;
/// Paint.NET `MoveTool`). The first manipulation **lifts** the selected pixels of the
/// active layer (leaving a transparent hole, or not with ⌘), the pixels **float** while
/// the user keeps moving/scaling/rotating them — each gesture is one history step
/// ("Move Pixels" / "Scale Pixels" / "Rotate Pixels") and the layer always shows the
/// result — and they are **finished** ("Finish Pixels", Paint.NET 3.36 `Drop()`) by
/// Return, Finish, tool/document switch, or another command. Undo walks back through the
/// floating steps without dropping the pixels; Escape cancels the whole session exactly
/// (D-47a). Resampling follows D-21 via `Resampler` — integer translations/scales stay
/// pixel-perfect, rotations resample bilinearly. No tool options (D-21 fixes resampling;
/// Paint.NET's dropdown is out of scope).
@MainActor
final class MoveSelectedPixelsTool: Tool {
    let id: ToolID = .moveSelectedPixels

    private weak var context: (any ToolContext)?

    private struct Drag {
        var gesture: TransformGesture
        var start: CGPoint
        var sessionAtStart: TransformSession
        /// ⌘ at mouse-down: lift a copy (or stamp the current rendering as underlay).
        var duplicate: Bool
        /// The state at mouse-down, after any "Select All" step (CoW — free).
        var beforeState: DocumentState
        /// The live session state being edited; `nil` until the first change lifts it.
        var floating: FloatingPixels?
        /// This drag lifted (punched the hole), so its first render must cover
        /// `sourceRect` too.
        var lifted = false
        /// A change happened — mouse-up records a step.
        var changed = false
        /// Union of every region rendered this drag (canvas coordinates).
        var lastRegion = PixelRect.zero
        /// Tiles any render this drag wrote (the step's diff candidates).
        var touched: Set<TileCoordinate> = []
        var lastPoint: CGPoint
        var lastModifiers: ToolModifiers
    }

    private var drag: Drag?
    /// The hover gesture, for the cursor.
    private var hoverGesture: TransformGesture?

    var hasPendingEdit: Bool { drag != nil || context?.floatingPixels != nil }

    // MARK: - Sessions and overlays

    /// The idle frame's session: the floating session while one runs, else the current
    /// selection's integer bounds (0020 item 5 — nubs sit on pixel edges), else none.
    private func idleSession(_ context: any ToolContext) -> TransformSession? {
        if let floating = context.floatingPixels { return floating.session }
        guard let selection = context.selection else { return nil }
        return TransformSession(sourceBounds: selection.bounds.cgRect)
    }

    /// The idle frame: handles on the idle session, no live outline, ants visible.
    private func showIdleOverlay(_ context: any ToolContext) {
        guard let session = idleSession(context) else {
            context.setOverlay(nil)
            return
        }
        context.setOverlay(.transformHandles(TransformHandlesPreview(
            outline: nil, corners: session.canvasCorners, showsHandles: true,
            center: nil, hidesCurrentSelection: false)))
    }

    private func showDragPreview(_ floating: FloatingPixels, gesture: TransformGesture,
                                 _ context: any ToolContext) {
        context.setOverlay(.transformHandles(TransformHandlesPreview(
            outline: floating.outline?.path.copying(using: floating.affine),
            corners: floating.session.canvasCorners, showsHandles: true,
            center: gesture == .rotate ? floating.session.canvasCenter : nil,
            hidesCurrentSelection: true)))
    }

    /// Paint.NET `MoveToolBase.OnMouseDown`: an empty selection pushes a "Select All"
    /// memento, then the whole layer lifts. Nothing floats and pixels floating keep
    /// their own frame.
    private func ensureSelectAll(_ context: any ToolContext) {
        guard context.floatingPixels == nil, context.selection == nil else { return }
        let state = DocumentState(image: context.image, selection: context.selection)
        if let item = SelectionCommand.selectAll.makeHistoryItem(for: state) {
            context.performHistory(item)
        }
    }

    // MARK: - Live rendering

    /// Applies the gesture (absolute, from the mouse-down snapshot) to the drag: lifts on
    /// the first change, re-renders `lastRegion ∪ destinationBounds` live, and tracks the
    /// region/tiles for the step's diff. Zero pixel writes happen without a change.
    private func applyDrag(_ drag: inout Drag, to point: CGPoint,
                           modifiers: ToolModifiers, _ context: any ToolContext) {
        guard point.componentsAreFinite else { return }
        // Integer snapping for scale (item 5): while unrotated, round both canvas points
        // so the local drag delta is integral and box edges stay on pixel boundaries —
        // integer scales keep D-21's nearest path. Rotation is never snapped (only Shift's
        // 15°); translate is already integral.
        var from = drag.start
        var to = point
        if case .scale = drag.gesture, abs(drag.sessionAtStart.angle) <= 1e-9 {
            from = CGPoint(x: from.x.rounded(.toNearestOrAwayFromZero),
                           y: from.y.rounded(.toNearestOrAwayFromZero))
            to = CGPoint(x: to.x.rounded(.toNearestOrAwayFromZero),
                         y: to.y.rounded(.toNearestOrAwayFromZero))
        }
        let session = drag.sessionAtStart.applying(drag.gesture, from: from, to: to,
                                                   modifiers: modifiers)
        guard session != drag.sessionAtStart || drag.floating != nil else { return }

        var floating = drag.floating
        if floating == nil {
            if let existing = context.floatingPixels {
                // Already floating: ⌘ stamps the current rendering as the new underlay
                // so a copy stays behind (Paint.NET "move/rotate a copy").
                floating = drag.duplicate
                    ? existing.withUnderlay(existing.activeLayerSurface(in: context.image))
                    : existing
                if drag.lastRegion == .zero {
                    // The session was rendered before this drag started (a Paste
                    // session per 0021, or a second gesture on a live session): its
                    // currently drawn destination must be part of the first live
                    // render, or the old copy is left behind on the layer.
                    drag.lastRegion = existing.destinationBounds
                        .intersection(context.image.size.bounds)
                }
            } else {
                floating = FloatingPixels.lift(from: drag.beforeState,
                                               duplicate: drag.duplicate,
                                               baseStepID: context.history.currentStepID)
                drag.lifted = true
            }
        }
        guard var floating else { return }
        floating.session = session

        let canvas = context.image.size.bounds
        var region = drag.lastRegion.union(floating.destinationBounds)
        if drag.lifted, drag.floating == nil {
            // The lifting event must also clear the hole (`sourceRect`).
            region = region.union(floating.sourceRect.intersection(canvas))
        }
        let surface = floating.activeLayerSurface(in: context.image)
        let tileCoordinates = surface.tileCoordinates(intersecting: region)
        let layerID = floating.layerID
        context.updateImage { image in
            guard let index = image.layerIndex(for: layerID) else { return }
            floating.render(into: &image.layers[index].surface, region: region)
        }
        drag.floating = floating
        drag.lastRegion = region
        drag.touched.formUnion(tileCoordinates)
        drag.changed = true
        drag.lastPoint = point
        drag.lastModifiers = modifiers
        showDragPreview(floating, gesture: drag.gesture, context)
    }

    /// The mouse-up commit for a changed drag (also the arrow-key path and the
    /// mid-drag `commit`): one step over `beforeState`, then the idle overlay.
    private func commitDrag(_ drag: Drag, _ context: any ToolContext) {
        guard drag.changed, let floating = drag.floating else { return }
        let antialiased = context.options.value(SelectionToolOptions.quality) == .antialiased
        var after = drag.beforeState
        after.image = context.image  // the live rendering
        after.selection = floating.transformedSelection(antialiased: antialiased)
        after.floatingPixels = floating
        let step = MoveSelectedPixelsHistory.step(
            named: MoveSelectedPixelsHistory.name(for: drag.gesture),
            before: drag.beforeState, after: after,
            layerID: floating.layerID, candidates: drag.touched)
        // Put the live layer back to `beforeState`'s surface (free by CoW); the step's
        // apply re-lands the after tiles, so canvas, ants, and handles refresh through
        // `onStateChange` exactly like undo/redo would.
        restoreLayer(drag.beforeState, layerID: floating.layerID, context)
        context.performHistory(step)
    }

    /// Restores the floating layer's surface from `state` without recording anything.
    private func restoreLayer(_ state: DocumentState, layerID: Layer.ID,
                              _ context: any ToolContext) {
        guard let from = state.image.layerIndex(for: layerID) else { return }
        let surface = state.image.layers[from].surface
        context.updateImage { image in
            guard let index = image.layerIndex(for: layerID) else { return }
            image.layers[index].surface = surface
        }
    }

    // MARK: - Escape (whole-session cancel)

    /// D-47a: Escape cancels the whole move — pixels and selection return to their exact
    /// pre-session values. Normally that is a History jump to `restore.baseStepID` (the
    /// session's steps become redo steps, like undo); when the lift step was already
    /// folded into the base by the budget (H-5), one restoring "Move Pixels" step writes
    /// the restore point back instead.
    private func cancelSession(_ floating: FloatingPixels, _ context: any ToolContext) {
        let steps = context.history.steps
        if let index = steps.firstIndex(where: { $0.id == floating.restore.baseStepID }),
           index + 1 < steps.count,
           MoveSelectedPixelsHistory.stepStartsSession(steps[index + 1], id: floating.id) {
            context.jumpHistory(to: index)
        } else {
            let before = DocumentState(image: context.image, selection: context.selection,
                                       floatingPixels: floating)
            var after = DocumentState(image: context.image,
                                      selection: floating.restore.selection,
                                      floatingPixels: nil)
            if let index = after.image.layerIndex(for: floating.layerID) {
                after.image.layers[index].surface = floating.restore.layerSurface
            }
            context.performHistory(MoveSelectedPixelsHistory.step(
                named: "Move Pixels", before: before, after: after,
                layerID: floating.layerID, candidates: nil))
        }
        showIdleOverlay(context)
    }

    // MARK: - Tool

    func activate(context: any ToolContext) {
        self.context = context
        drag = nil
        hoverGesture = nil
        showIdleOverlay(context)
    }

    /// 0006's default (commit a pending edit → "Finish Pixels" while floating), then the
    /// overlay is gone.
    func deactivate(context: any ToolContext) {
        if hasPendingEdit { commit(context: context) }
        drag = nil
        hoverGesture = nil
        context.setOverlay(nil)
    }

    func mouseDown(_ event: ToolEvent, context: any ToolContext) {
        self.context = context
        guard event.location.componentsAreFinite, event.viewLocation.componentsAreFinite,
              drag == nil else { return }
        ensureSelectAll(context)
        guard let session = idleSession(context) else { return }
        let gesture = TransformHandles.hitTest(
            viewPoint: event.viewLocation, session: session,
            canvasToView: context.transform.canvasToViewAffine, button: event.button)
        // Nothing lifts on mouse-down: a click without movement leaves pixels untouched.
        drag = Drag(gesture: gesture, start: event.location, sessionAtStart: session,
                    duplicate: event.modifiers.contains(.command),
                    beforeState: DocumentState(image: context.image,
                                               selection: context.selection,
                                               floatingPixels: context.floatingPixels),
                    lastPoint: event.location, lastModifiers: event.modifiers)
    }

    func mouseDragged(_ event: ToolEvent, context: any ToolContext) {
        self.context = context
        guard var drag else { return }
        applyDrag(&drag, to: event.location, modifiers: event.modifiers, context)
        self.drag = drag
    }

    func mouseUp(_ event: ToolEvent, context: any ToolContext) {
        self.context = context
        guard var drag else { return }
        self.drag = nil
        // An unusable up finishes at the last known point rather than wedging.
        let point = event.location.componentsAreFinite ? event.location : drag.lastPoint
        let modifiers = event.location.componentsAreFinite ? event.modifiers : drag.lastModifiers
        applyDrag(&drag, to: point, modifiers: modifiers, context)
        commitDrag(drag, context)
        showIdleOverlay(context)
    }

    func mouseMoved(_ event: ToolEvent, context: any ToolContext) {
        self.context = context
        guard event.viewLocation.componentsAreFinite else { return }
        let hover: TransformGesture?
        if let session = idleSession(context) {
            hover = TransformHandles.hitTest(
                viewPoint: event.viewLocation, session: session,
                canvasToView: context.transform.canvasToViewAffine, button: .primary)
        } else {
            hover = nil
        }
        guard hover != hoverGesture else { return }
        hoverGesture = hover
        context.invalidateCursor()
    }

    /// Shift / ⌥ act live mid-drag (3.36's `OnKeyDown → Render`).
    func flagsChanged(_ modifiers: ToolModifiers, context: any ToolContext) {
        self.context = context
        if var drag {
            applyDrag(&drag, to: drag.lastPoint, modifiers: modifiers, context)
            self.drag = drag
        }
        context.invalidateCursor()
    }

    func keyDown(_ event: ToolKeyEvent, context: any ToolContext) -> Bool {
        self.context = context
        guard let offset = TransformHandles.nudge(for: event) else {
            // 0006's defaults: Return/Enter commits, Escape cancels, when pending.
            switch event.key {
            case .returnKey, .enter:
                guard hasPendingEdit else { return false }
                commit(context: context)
                return true
            case .escape:
                guard hasPendingEdit else { return false }
                cancel(context: context)
                return true
            default:
                return false
            }
        }
        if drag != nil { return true }  // Paint.NET ignores nudges while tracking
        ensureSelectAll(context)
        let beforeState = DocumentState(image: context.image, selection: context.selection,
                                        floatingPixels: context.floatingPixels)
        let lifted = context.floatingPixels
            ?? FloatingPixels.lift(from: beforeState, duplicate: false,
                                   baseStepID: context.history.currentStepID)
        guard var floating = lifted else { return true }
        let oldBounds = floating.destinationBounds
        floating.session = floating.session.translatedBy(dx: offset.dx, dy: offset.dy)
        let canvas = context.image.size.bounds
        var region = oldBounds.union(floating.destinationBounds)
        if beforeState.floatingPixels == nil {
            region = region.union(floating.sourceRect.intersection(canvas))
        }
        let layerID = floating.layerID
        let surface = floating.activeLayerSurface(in: context.image)
        let touched = Set(surface.tileCoordinates(intersecting: region))
        context.updateImage { image in
            guard let index = image.layerIndex(for: layerID) else { return }
            floating.render(into: &image.layers[index].surface, region: region)
        }
        // One "Move Pixels" step per key event — auto-repeat included (3.36's
        // `OnKeyPress` simulates a full down/move/up per press) — through mouse-up's path.
        let antialiased = context.options.value(SelectionToolOptions.quality) == .antialiased
        var after = beforeState
        after.image = context.image
        after.selection = floating.transformedSelection(antialiased: antialiased)
        after.floatingPixels = floating
        restoreLayer(beforeState, layerID: layerID, context)
        context.performHistory(MoveSelectedPixelsHistory.step(
            named: "Move Pixels", before: beforeState, after: after,
            layerID: layerID, candidates: touched))
        showIdleOverlay(context)
        return true
    }

    /// Finish button, Return, tool switch (0006's default `deactivate`), document switch,
    /// and every command (item 9): end a drag as mouse-up would, then "Finish Pixels"
    /// (Paint.NET `Drop()`) if anything floats.
    func commit(context: any ToolContext) {
        self.context = context
        if var drag {
            applyDrag(&drag, to: drag.lastPoint, modifiers: drag.lastModifiers, context)
            self.drag = nil
            commitDrag(drag, context)
        }
        if let floating = context.floatingPixels {
            context.performHistory(MoveSelectedPixelsHistory.finishStep(floating))
        }
        showIdleOverlay(context)
    }

    /// Escape (0006 routes Escape-mid-gesture here too): *during a drag* only that drag
    /// rolls back to mouse-down and the session stays floating; *not dragging* it cancels
    /// the whole session exactly (D-47a).
    func cancel(context: any ToolContext) {
        self.context = context
        if let drag {
            self.drag = nil
            if drag.changed, let floating = drag.floating {
                restoreLayer(drag.beforeState, layerID: floating.layerID, context)
            }
            showIdleOverlay(context)
            return
        }
        guard let floating = context.floatingPixels else { return }
        cancelSession(floating, context)
    }

    /// Undo/redo/jump/save never add "Finish Pixels" (D-47c) — the floating state lives
    /// in history itself. A drag in flight is the one thing navigation must undo.
    func prepareForHistoryNavigation(context: any ToolContext) {
        self.context = context
        if drag != nil { cancel(context: context) }
    }

    /// The window controller re-runs the idle-overlay logic after every state change
    /// (spec 0020 item 11) through this hook.
    func optionsDidChange(context: any ToolContext) {
        self.context = context
        showIdleOverlay(context)
    }

    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor {
        if let drag { return Self.cursor(for: drag.gesture) }
        guard location != nil else { return .arrow }
        guard context?.floatingPixels != nil || context?.selection != nil else {
            return .move  // a drag will Select All and move
        }
        return switch hoverGesture ?? .translate {
        case .translate: .move
        case .rotate: .rotate
        case .scale(let handle): .resize(handle)
        }
    }

    private static func cursor(for gesture: TransformGesture) -> ToolCursor {
        switch gesture {
        case .translate: .move
        case .rotate: .rotate
        case .scale(let handle): .resize(handle)
        }
    }
}

extension FloatingPixels {
    /// The floating layer's current surface in `image`. `layerID` always resolves — the
    /// `DocumentState` invariant (0020 item 3) guarantees it while pixels float; an
    /// unmatched id yields the (unused) transparent fallback rather than a trap.
    func activeLayerSurface(in image: LayeredImage) -> TiledSurface {
        guard let index = image.layerIndex(for: layerID) else {
            return TiledSurface(size: underlay.size)
        }
        return image.layers[index].surface
    }
}
