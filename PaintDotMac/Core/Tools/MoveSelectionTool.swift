import CoreGraphics
import Foundation

/// T-6 "Move Selection — M — Moves only the selection outline" (PRD §5.3; spec 0019;
/// Paint.NET `MoveSelectionTool`). Moves, scales, and rotates the selection outline;
/// pixels never change (MoveTools.html). Every gesture is one history step committed on
/// mouse-up — "Move Selection" / "Scale Selection" / "Rotate Selection" — so the tool
/// never holds a pending edit (`supportsPendingEdits false`, 0006's descriptor row).
///
/// Paint.NET's tool "context" survives across gestures: while the document selection
/// still equals the selection this tool last produced, the session keeps its rotation
/// angle and rotated handles (3.36's `startAngle`); any other selection change (undo,
/// redo, History jump, Edit menu, another tool) resets the frame to the new selection's
/// axis-aligned bounds.
@MainActor
final class MoveSelectionTool: Tool {
    let id: ToolID = .moveSelection
    var hasPendingEdit: Bool { false }

    private struct Context {
        /// The selection at context start; the session's transform source.
        var source: Selection
        var session: TransformSession
        /// The selection this context last produced (`nil` = its outline sits fully
        /// off-canvas); compared against the document selection for validity.
        var produced: Selection?
    }

    private struct Drag {
        var gesture: TransformGesture
        var start: CGPoint
        var sessionAtStart: TransformSession
        /// The latest drag point, so `flagsChanged` can re-apply the gesture live
        /// (3.36's `OnKeyDown → Render`).
        var lastPoint: CGPoint
    }

    private var context: Context?
    private var drag: Drag?
    /// The hover gesture, for the cursor.
    private var hoverGesture: TransformGesture?

    // MARK: - Context

    /// Keeps a still-valid context (the document selection equals what we produced) or
    /// rebuilds it from the current selection; no selection → no context.
    private func ensureContext(_ toolContext: any ToolContext) {
        if let context, toolContext.selection == context.produced { return }
        guard let selection = toolContext.selection,
              let session = TransformSession(sourceBounds: selection.path.boundingBoxOfPath)
        else {
            context = nil
            return
        }
        self.context = Context(source: selection, session: session, produced: selection)
    }

    /// Paint.NET `MoveToolBase.OnMouseDown`: an empty selection pushes a "Select All"
    /// memento, then the gesture proceeds.
    private func ensureContextWithSelectAll(_ toolContext: any ToolContext) {
        ensureContext(toolContext)
        guard context == nil else { return }
        let state = DocumentState(image: toolContext.image, selection: toolContext.selection)
        if let item = SelectionCommand.selectAll.makeHistoryItem(for: state) {
            toolContext.performHistory(item)
        }
        ensureContext(toolContext)
    }

    /// The idle frame: handles on the current session, no live outline, ants visible.
    private func showIdleOverlay(_ toolContext: any ToolContext) {
        guard let context else {
            toolContext.setOverlay(nil)
            return
        }
        toolContext.setOverlay(.transformHandles(TransformHandlesPreview(
            outline: nil, corners: context.session.canvasCorners, showsHandles: true,
            center: nil, hidesCurrentSelection: false)))
    }

    private func showDragPreview(_ session: TransformSession, gesture: TransformGesture,
                                 source: Selection, _ toolContext: any ToolContext) {
        let outline = source.path.copying(using: session.outlineTransform)
        toolContext.setOverlay(.transformHandles(TransformHandlesPreview(
            outline: outline, corners: session.canvasCorners, showsHandles: true,
            center: gesture == .rotate ? session.canvasCenter : nil,
            hidesCurrentSelection: true)))
    }

    private func transformAntialiased(_ toolContext: any ToolContext) -> Bool {
        toolContext.options.value(SelectionToolOptions.quality) == .antialiased
    }

    /// The result of a finished gesture plus its Paint.NET step name (`Strings.resx`).
    private func finish(gesture: TransformGesture, session: TransformSession,
                        producedFrom source: Selection, toolContext: any ToolContext) {
        let name: String = switch gesture {
        case .translate: "Move Selection"
        case .scale: "Scale Selection"
        case .rotate: "Rotate Selection"
        }
        let after = Selection.transformed(source, by: session,
                                          antialiased: transformAntialiased(toolContext))
        toolContext.performHistory(SelectionHistoryItem(name: name, icon: .moveSelection,
                                                        before: toolContext.selection,
                                                        after: after))
        context?.session = session
        context?.produced = after
    }

    // MARK: - Tool

    func activate(context: any ToolContext) {
        drag = nil
        hoverGesture = nil
        ensureContext(context)
        showIdleOverlay(context)
    }

    /// No step (D-34): Paint.NET's "Finish Selection" deactivation memento changes
    /// nothing for an outline-only move.
    func deactivate(context: any ToolContext) {
        drag = nil
        self.context = nil
        hoverGesture = nil
        context.setOverlay(nil)
    }

    func mouseDown(_ event: ToolEvent, context: any ToolContext) {
        guard event.location.componentsAreFinite, event.viewLocation.componentsAreFinite,
              drag == nil else { return }
        ensureContextWithSelectAll(context)
        guard let sessionContext = self.context else { return }
        let gesture = TransformHandles.hitTest(
            viewPoint: event.viewLocation, session: sessionContext.session,
            canvasToView: context.transform.canvasToViewAffine, button: event.button)
        drag = Drag(gesture: gesture, start: event.location,
                    sessionAtStart: sessionContext.session, lastPoint: event.location)
    }

    func mouseDragged(_ event: ToolEvent, context: any ToolContext) {
        guard event.location.componentsAreFinite, let drag, let source = self.context?.source
        else { return }
        var stored = drag
        stored.lastPoint = event.location
        self.drag = stored
        applyDrag(stored, to: event.location, modifiers: event.modifiers,
                  source: source, context)
    }

    /// Recomputes the session from the mouse-down snapshot — so the gesture is absolute
    /// and modifiers act live.
    private func applyDrag(_ drag: Drag, to point: CGPoint, modifiers: ToolModifiers,
                           source: Selection, _ toolContext: any ToolContext) {
        let session = drag.sessionAtStart.applying(drag.gesture, from: drag.start,
                                                   to: point, modifiers: modifiers)
        context?.session = session
        showDragPreview(session, gesture: drag.gesture, source: source, toolContext)
    }

    func mouseUp(_ event: ToolEvent, context: any ToolContext) {
        guard let drag, let source = self.context?.source else { return }
        guard event.location.componentsAreFinite else {
            // An unusable up must not wedge the tool: treat it as a cancel (no step).
            cancel(context: context)
            return
        }
        self.drag = nil
        let session = drag.sessionAtStart.applying(drag.gesture, from: drag.start,
                                                   to: event.location,
                                                   modifiers: event.modifiers)
        guard session != drag.sessionAtStart else {
            // A click, or a drag that returned to its start: no step (D-34).
            self.context?.session = drag.sessionAtStart
            showIdleOverlay(context)
            return
        }
        finish(gesture: drag.gesture, session: session, producedFrom: source,
               toolContext: context)
        showIdleOverlay(context)
    }

    func mouseMoved(_ event: ToolEvent, context: any ToolContext) {
        guard event.viewLocation.componentsAreFinite else { return }
        let previousProduced = self.context?.produced
        ensureContext(context)
        if self.context?.produced != previousProduced {
            // An external change (undo, menu, another tool) replaced the selection —
            // redraw the frame over the new one.
            showIdleOverlay(context)
        }
        let hover: TransformGesture?
        if let sessionContext = self.context {
            hover = TransformHandles.hitTest(
                viewPoint: event.viewLocation, session: sessionContext.session,
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
        if let drag, let source = self.context?.source {
            applyDrag(drag, to: drag.lastPoint, modifiers: modifiers,
                      source: source, context)
        }
        context.invalidateCursor()
    }

    func keyDown(_ event: ToolKeyEvent, context: any ToolContext) -> Bool {
        guard let offset = TransformHandles.nudge(for: event) else { return false }
        if drag != nil { return true }  // Paint.NET ignores nudges while tracking
        ensureContextWithSelectAll(context)
        guard let sessionContext = self.context else { return true }
        let session = sessionContext.session
            .translatedBy(dx: offset.dx, dy: offset.dy)
        // One "Move Selection" step per key event — auto-repeat included (3.36's
        // `OnKeyPress` simulates a full down/move/up per press).
        finish(gesture: .translate, session: session, producedFrom: sessionContext.source,
               toolContext: context)
        showIdleOverlay(context)
        return true
    }

    /// Escape mid-drag (0006's dispatcher): the session rolls back to mouse-down, no
    /// step.
    func cancel(context: any ToolContext) {
        guard let drag else { return }
        self.drag = nil
        self.context?.session = drag.sessionAtStart
        showIdleOverlay(context)
    }

    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor {
        if let drag {
            return Self.cursor(for: drag.gesture)
        }
        guard location != nil else { return .arrow }
        guard context != nil else { return .move }  // a drag will Select All and move
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
