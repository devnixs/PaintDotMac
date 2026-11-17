import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `MoveSelectionTool` against `FakeToolContext` (spec 0019 *Test plan*): the outline
/// gestures, the history contract, the Select-All-first rule, the off-canvas session,
/// the cursor map, and the invalid-event guards. Fixture: 200 × 200 opaque white, zoom
/// 1 / backing 1 (view positions come from `transform.canvasToView`), selection rect
/// (50, 50, 100, 100) unless stated. The tool is activated first.
@MainActor
struct MoveSelectionToolTests {
    private let size = PixelSize(width: 200, height: 200)

    // MARK: - Fixture helpers

    private func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    private func makeContext() -> FakeToolContext {
        let context = FakeToolContext(size: size, background: .white)
        context.nav.transform = CanvasTransform(
            imageSize: size, viewSize: CGSize(width: 200, height: 200),
            backingScale: 1, zoom: 1, center: point(100, 100))
        return context
    }

    /// Activated tool + selection `rect` (default (50, 50, 100, 100)) through a setup
    /// step; step-name assertions slice off the setup.
    private func activated(rect: CGRect?) throws -> (MoveSelectionTool, FakeToolContext) {
        let context = makeContext()
        if let rect, let selection = Selection(rect: rect, canvasSize: size) {
            context.performHistory(SelectionHistoryItem(name: "setup", icon: .generic,
                                                        before: nil, after: selection))
        }
        let tool = MoveSelectionTool()
        tool.activate(context: context)
        return (tool, context)
    }

    private func event(_ context: FakeToolContext, _ x: Double, _ y: Double,
                       button: ToolMouseButton = .primary,
                       modifiers: ToolModifiers = []) -> ToolEvent {
        let location = point(x, y)
        return ToolEvent(location: location,
                         viewLocation: context.transform.canvasToView(location),
                         button: button, modifiers: modifiers,
                         clickCount: 1, pressure: 1, timestamp: 1)
    }

    private func key(_ key: ToolKey, _ modifiers: ToolModifiers = [],
                     repeat_: Bool = false) -> ToolKeyEvent {
        ToolKeyEvent(key: key, characters: "", modifiers: modifiers, isRepeat: repeat_)
    }

    private func drag(_ tool: MoveSelectionTool, _ context: FakeToolContext,
                      from: CGPoint, to: CGPoint,
                      button: ToolMouseButton = .primary,
                      modifiers: ToolModifiers = []) {
        tool.mouseDown(event(context, from.x, from.y, button: button, modifiers: modifiers),
                       context: context)
        tool.mouseDragged(event(context, to.x, to.y, button: button, modifiers: modifiers),
                          context: context)
        tool.mouseUp(event(context, to.x, to.y, button: button, modifiers: modifiers),
                     context: context)
    }

    private func names(_ context: FakeToolContext) -> [String] {
        context.history.steps.map(\.name)
    }

    private func handlesOverlay(_ context: FakeToolContext) throws -> TransformHandlesPreview {
        guard case .transformHandles(let preview)? = context.lastOverlay else {
            Issue.record("expected a .transformHandles overlay, got \(String(describing: context.lastOverlay))")
            struct NotHandles: Error {}
            throw NotHandles()
        }
        return preview
    }

    private func cornersClose(_ got: [CGPoint], _ want: [CGPoint], _ comment: Comment) {
        #expect(got.count == want.count, comment)
        guard got.count == want.count else { return }
        for (g, w) in zip(got, want) {
            #expect(abs(g.x - w.x) <= 1e-6 && abs(g.y - w.y) <= 1e-6,
                    "corner \(g) ≠ \(w) \(comment)")
        }
    }

    /// The rigid rotation by `degrees` about `center` (independent of the tool code).
    private func rotation(_ degrees: Double, about center: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)
    }

    private func rotate(_ corners: [CGPoint], _ degrees: Double, about center: CGPoint)
        -> [CGPoint]
    {
        corners.map { $0.applying(rotation(degrees, about: center)) }
    }

    private func rectSelection(_ x: Double, _ y: Double, _ w: Double, _ h: Double) throws
        -> Selection
    {
        try #require(Selection(rect: CGRect(x: x, y: y, width: w, height: h), canvasSize: size))
    }

    // MARK: - Idle state

    @Test func activateShowsHandles() throws {
        let (_, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        let preview = try handlesOverlay(context)
        cornersClose(preview.corners,
                     [point(50, 50), point(150, 50), point(150, 150), point(50, 150)],
                     "frame corners")
        #expect(preview.showsHandles)
        #expect(preview.outline == nil)
        #expect(!preview.hidesCurrentSelection)
        #expect(preview.center == nil)
    }

    // MARK: - Translate

    @Test func dragTranslatesOutline() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        let before = context.history.steps.count
        drag(tool, context, from: point(100, 100), to: point(110.4, 95.6))
        #expect(names(context).last == "Move Selection")
        #expect(context.history.steps.last?.icon == .moveSelection)
        #expect(context.selection == (try rectSelection(60, 46, 100, 100)),
                "exactly one new step, selection moved by (10, −4)")
        #expect(context.history.steps.count == before + 1)
    }

    @Test func pixelsUnchanged() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        // A 200 × 200 image is a single 256 × 256 tile.
        let coordinate = TileCoordinate(column: 0, row: 0)
        let before = try #require(context.image.layers[0].surface.tile(at: coordinate))
        drag(tool, context, from: point(100, 100), to: point(120, 120))
        let after = try #require(context.image.layers[0].surface.tile(at: coordinate))
        #expect(before.sharesStorage(with: after), "no tile was touched")
        // The step reports a selection-only change.
        var change: HistoryChange?
        context.navigateForTests { history, state in change = history.undo(&state) }
        #expect(change == .selection)
    }

    @Test func dragPreviewOnly() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        let stepsBefore = context.history.steps.count
        let original = context.selection
        tool.mouseDown(event(context, 100, 100), context: context)
        tool.mouseDragged(event(context, 110.4, 95.6), context: context)
        #expect(context.selection == original, "the document selection is unchanged mid-drag")
        let preview = try handlesOverlay(context)
        #expect(preview.hidesCurrentSelection)
        let box = try #require(preview.outline).boundingBoxOfPath
        #expect(abs(box.minX - 60) <= 1e-9 && abs(box.minY - 46) <= 1e-9
                    && abs(box.width - 100) <= 1e-9 && abs(box.height - 100) <= 1e-9,
                "live outline bbox (60, 46, 100, 100)")
        #expect(context.history.steps.count == stepsBefore, "no step until mouse-up")
        tool.mouseUp(event(context, 110.4, 95.6), context: context)
        #expect(context.history.steps.count == stepsBefore + 1)
    }

    // MARK: - Scale

    @Test func cornerHandleScales() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        drag(tool, context, from: point(150, 150), to: point(200, 200))
        #expect(names(context).last == "Scale Selection")
        let expected = try rectSelection(50, 50, 150, 150)
        #expect(context.selection?.mask == expected.mask,
                "selection equals Selection(rect: (50, 50, 150, 150))")
    }

    @Test func optionScalesAboutCenter() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        drag(tool, context, from: point(150, 150), to: point(170, 170),
             modifiers: [.option])
        #expect(names(context).last == "Scale Selection")
        let expected = try rectSelection(30, 30, 140, 140)
        #expect(context.selection?.mask == expected.mask,
                "⌥ BR (+20, +20) → Selection(rect: (30, 30, 140, 140))")
    }

    @Test func shiftCornerKeepsProportions() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 80, width: 100, height: 40))
        let stepsBefore = context.history.steps.count
        // ⇧ BR (+100, 0): candidate 200 × 40 → s = min(2, 1) = 1 → unchanged → no step.
        drag(tool, context, from: point(150, 120), to: point(250, 120),
             modifiers: [.shift])
        #expect(context.history.steps.count == stepsBefore, "s = 1 → no step")
        // ⇧ BR (+100, +40): candidate 200 × 80 → s = 2 → 200 × 80 box, clipped both ways.
        drag(tool, context, from: point(150, 120), to: point(250, 160),
             modifiers: [.shift])
        #expect(names(context).last == "Scale Selection")
        let expected = try rectSelection(50, 80, 200, 80)
        #expect(context.selection?.mask == expected.mask,
                "selection equals Selection(rect: (50, 80, 200, 80)) clipped by 0013")
    }

    // MARK: - Rotate

    @Test func rightDragRotates90() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 80, width: 100, height: 40))
        drag(tool, context, from: point(150, 100), to: point(100, 150), button: .secondary)
        #expect(names(context).last == "Rotate Selection")
        #expect(context.selection?.bounds == PixelRect(x: 80, y: 50, width: 40, height: 100),
                "bounds (80, 50, 40, 100)")
    }

    @Test func shiftRotateSnaps() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        // Raw 50° with Shift → snapped total 45°.
        let target = point(100 + 50 * cos(50 * Double.pi / 180), 100 + 50 * sin(50 * Double.pi / 180))
        tool.mouseDown(event(context, 150, 100, button: .secondary), context: context)
        tool.mouseDragged(event(context, target.x, target.y, button: .secondary,
                                modifiers: [.shift]), context: context)
        let preview = try handlesOverlay(context)
        cornersClose(preview.corners,
                     rotate([point(50, 50), point(150, 50), point(150, 150), point(50, 150)],
                            45, about: point(100, 100)),
                     "overlay corners match a 45° rotation")
        if let center = preview.center {
            #expect(abs(center.x - 100) <= 1e-9 && abs(center.y - 100) <= 1e-9,
                    "center marker shown at (100, 100)")
        } else {
            Issue.record("expected the rotation center marker")
        }
        tool.mouseUp(event(context, target.x, target.y, button: .secondary,
                           modifiers: [.shift]), context: context)
    }

    @Test func rotationPersistsAcrossDrags() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        let target30 = point(100 + 50 * cos(30 * Double.pi / 180), 100 + 50 * sin(30 * Double.pi / 180))
        drag(tool, context, from: point(150, 100), to: target30, button: .secondary)
        #expect(names(context).last == "Rotate Selection")
        let frame = [point(50, 50), point(150, 50), point(150, 150), point(50, 150)]
        let rotatedFrame = rotate(frame, 30, about: point(100, 100))
        cornersClose(try handlesOverlay(context).corners, rotatedFrame, "idle overlay at 30°")

        // The (rotated) BR handle sits at rotate30(150, 150).
        let br = rotatedFrame[2]
        // Drag it by the canvas vector (+20, 0): in the 30° frame that is the local
        // vector (+20·cos30, −20·sin30) — the box grows along its own axes.
        let localX = 20 * cos(30 * Double.pi / 180)
        let localY = -20 * sin(30 * Double.pi / 180)
        let expectedCorners = rotate(
            [point(50, 50), point(150 + localX, 50),
             point(150 + localX, 150 + localY), point(50, 150 + localY)],
            30, about: point(100, 100))
        drag(tool, context, from: br, to: point(br.x + 20, br.y))
        #expect(names(context).last == "Scale Selection")
        cornersClose(try handlesOverlay(context).corners, expectedCorners,
                     "BR moved along the 30° direction")
    }

    @Test func nudgeAfterRotateMovesAlongDocumentAxes() throws {
        // Paint.NET nudges in document coordinates: with the frame at 30°, ⌘→ still
        // moves the selection exactly 10 canvas px right.
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        let target30 = point(100 + 50 * cos(30 * Double.pi / 180),
                             100 + 50 * sin(30 * Double.pi / 180))
        drag(tool, context, from: point(150, 100), to: target30, button: .secondary)
        #expect(names(context).last == "Rotate Selection")
        let rotatedFrame = [point(50, 50), point(150, 50), point(150, 150), point(50, 150)]
            .map { rotate([$0], 30, about: point(100, 100))[0] }
        #expect(tool.keyDown(key(.rightArrow, .command), context: context))
        #expect(names(context).last == "Move Selection")
        let expected = rotatedFrame.map { point($0.x + 10, $0.y) }
        cornersClose(try handlesOverlay(context).corners, expected,
                     "the nudged 30° frame moved by exactly (+10, 0) on the canvas")
    }

    @Test func flagsChangedSnapsRotateLive() throws {
        // Pressed without Shift at a raw 50°, Shift mid-drag re-applies the gesture:
        // the preview snaps to the 45° total; releasing keeps 45° (one Rotate step).
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        let target = point(100 + 50 * cos(50 * Double.pi / 180),
                           100 + 50 * sin(50 * Double.pi / 180))
        tool.mouseDown(event(context, 150, 100, button: .secondary), context: context)
        tool.mouseDragged(event(context, target.x, target.y, button: .secondary),
                          context: context)
        let frame = [point(50, 50), point(150, 50), point(150, 150), point(50, 150)]
        cornersClose(try handlesOverlay(context).corners,
                     rotate(frame, 50, about: point(100, 100)), "raw 50° before Shift")
        tool.flagsChanged([.shift], context: context)
        cornersClose(try handlesOverlay(context).corners,
                     rotate(frame, 45, about: point(100, 100)),
                     "Shift acts live mid-drag (total snaps to 45°)")
        tool.mouseUp(event(context, target.x, target.y, button: .secondary,
                           modifiers: [.shift]), context: context)
        #expect(names(context).last == "Rotate Selection")
        cornersClose(try handlesOverlay(context).corners,
                     rotate(frame, 45, about: point(100, 100)), "committed at 45°")
    }

    // MARK: - Context validity

    @Test func contextResetsAfterExternalChange() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        let target30 = point(100 + 50 * cos(30 * Double.pi / 180), 100 + 50 * sin(30 * Double.pi / 180))
        drag(tool, context, from: point(150, 100), to: target30, button: .secondary)
        context.navigateForTests { history, state in _ = history.undo(&state) }
        tool.mouseMoved(event(context, 100, 100), context: context)
        cornersClose(try handlesOverlay(context).corners,
                     [point(50, 50), point(150, 50), point(150, 150), point(50, 150)],
                     "after undo the frame is the restored selection's axis-aligned box")
    }

    @Test func undoRedo() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        let original = context.selection
        drag(tool, context, from: point(100, 100), to: point(120, 100))
        let moved = context.selection
        #expect(moved == (try rectSelection(70, 50, 100, 100)))
        context.navigateForTests { history, state in _ = history.undo(&state) }
        #expect(context.selection == original, "undo restores the exact previous selection")
        context.navigateForTests { history, state in _ = history.redo(&state) }
        #expect(context.selection == moved, "redo restores the moved one")
    }

    // MARK: - No-ops and cancels

    @Test func clickIsNoOp() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        let stepsBefore = context.history.steps.count
        tool.mouseDown(event(context, 100, 100), context: context)
        tool.mouseUp(event(context, 100, 100), context: context)
        tool.mouseDown(event(context, 100, 100, button: .secondary), context: context)
        tool.mouseUp(event(context, 100, 100, button: .secondary), context: context)
        // A drag that ends where it started adds nothing either.
        tool.mouseDown(event(context, 100, 100), context: context)
        tool.mouseDragged(event(context, 130, 120), context: context)
        tool.mouseUp(event(context, 100, 100), context: context)
        #expect(context.history.steps.count == stepsBefore)
        #expect(context.selection == (try rectSelection(50, 50, 100, 100)))
    }

    @Test func escapeCancels() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        let stepsBefore = context.history.steps.count
        tool.mouseDown(event(context, 100, 100), context: context)
        tool.mouseDragged(event(context, 130, 130), context: context)
        tool.cancel(context: context)
        #expect(context.history.steps.count == stepsBefore, "no step")
        #expect(context.selection == (try rectSelection(50, 50, 100, 100)), "selection unchanged")
        let preview = try handlesOverlay(context)
        #expect(preview.outline == nil, "idle overlay")
        #expect(!preview.hidesCurrentSelection)
        cornersClose(preview.corners,
                     [point(50, 50), point(150, 50), point(150, 150), point(50, 150)],
                     "original corners")
    }

    @Test func deactivateMidDragAddsNoStep() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        let stepsBefore = context.history.steps.count
        tool.mouseDown(event(context, 100, 100), context: context)
        tool.mouseDragged(event(context, 130, 130), context: context)
        tool.deactivate(context: context)
        #expect(context.history.steps.count == stepsBefore)
        #expect(context.lastOverlay == nil, "deactivate cleared the overlay")
    }

    @Test func ignoresInvalidEvents() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        let stepsBefore = context.history.steps.count
        let bad = ToolEvent(location: point(.nan, 100), viewLocation: point(.nan, 100),
                            button: .primary, modifiers: [], clickCount: 1,
                            pressure: 1, timestamp: 1)
        tool.mouseDown(bad, context: context)
        tool.mouseDragged(event(context, 130, 130), context: context)
        tool.mouseUp(event(context, 130, 130), context: context)
        // A mouse-up without a matching down does nothing.
        tool.mouseUp(event(context, 90, 90), context: context)
        // Non-finite hover and drag points are ignored too (no context churn, no step).
        let badMove = ToolEvent(location: point(.nan, .nan), viewLocation: point(.nan, .nan),
                                button: .primary, modifiers: [], clickCount: 1,
                                pressure: 1, timestamp: 1)
        tool.mouseMoved(badMove, context: context)
        tool.mouseDown(event(context, 100, 100), context: context)
        tool.mouseDragged(badMove, context: context)
        tool.mouseUp(event(context, 100, 100), context: context)
        #expect(context.history.steps.count == stepsBefore)
        #expect(context.selection == (try rectSelection(50, 50, 100, 100)))
    }

    @Test func hasNoPendingEdit() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        #expect(!tool.hasPendingEdit)
        tool.mouseDown(event(context, 100, 100), context: context)
        #expect(!tool.hasPendingEdit, "never pending — commits at mouse-up")
        #expect(!tool.keyDown(key(.returnKey), context: context))
        tool.mouseUp(event(context, 120, 100), context: context)
        #expect(!tool.hasPendingEdit)
    }

    // MARK: - Arrow keys

    @Test func arrowNudges() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        let stepsBefore = context.history.steps.count
        #expect(tool.keyDown(key(.rightArrow), context: context))
        #expect(context.selection == (try rectSelection(51, 50, 100, 100)))
        #expect(names(context).last == "Move Selection")
        #expect(tool.keyDown(key(.leftArrow, .command), context: context))
        #expect(context.selection == (try rectSelection(41, 50, 100, 100)))
        #expect(tool.keyDown(key(.downArrow), context: context))
        #expect(context.selection == (try rectSelection(41, 51, 100, 100)))
        #expect(tool.keyDown(key(.rightArrow, [], repeat_: true), context: context))
        #expect(context.selection == (try rectSelection(42, 51, 100, 100)))
        #expect(context.history.steps.count == stepsBefore + 4, "four steps total")
    }

    @Test func nudgeIgnoredDuringDrag() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        let stepsBefore = context.history.steps.count
        let original = context.selection
        tool.mouseDown(event(context, 100, 100), context: context)
        #expect(tool.keyDown(key(.rightArrow), context: context))
        #expect(context.history.steps.count == stepsBefore)
        #expect(context.selection == original)
        tool.mouseUp(event(context, 100, 100), context: context)
        #expect(context.history.steps.count == stepsBefore)
    }

    // MARK: - Select All first

    @Test func noSelectionSelectsAllFirst() throws {
        let (tool, context) = try activated(rect: nil)
        drag(tool, context, from: point(10, 10), to: point(15, 10))
        // Steps: base "New Image", then "Select All", then "Move Selection".
        #expect(names(context) == ["New Image", "Select All", "Move Selection"])
        let expected = try rectSelection(5, 0, 195, 200)
        #expect(context.selection?.mask == expected.mask,
                "Select All moved by (5, 0) → rect (5, 0, 195, 200)")
        context.navigateForTests { history, state in _ = history.undo(&state) }
        context.navigateForTests { history, state in _ = history.undo(&state) }
        #expect(context.selection == nil, "⌘Z twice restores no selection")
    }

    @Test func noSelectionArrowSelectsAllFirst() throws {
        let (tool, context) = try activated(rect: nil)
        #expect(tool.keyDown(key(.rightArrow), context: context))
        #expect(names(context) == ["New Image", "Select All", "Move Selection"])
    }

    // MARK: - Off-canvas

    @Test func offCanvasAndBack() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        drag(tool, context, from: point(100, 100), to: point(400, 100))
        #expect(names(context).last == "Move Selection")
        #expect(context.selection == nil, "moved fully off-canvas → no selection (D-40)")
        let preview = try handlesOverlay(context)
        #expect(abs(preview.corners[0].x - 350) <= 1e-9
                    && abs(preview.corners[2].x - 450) <= 1e-9,
                "the frame stays visible off-canvas (x 350…450)")
        // Back: no "Select All" step (the off-canvas session is still live).
        drag(tool, context, from: point(400, 100), to: point(110, 100))
        #expect(context.selection == (try rectSelection(60, 50, 100, 100)),
                "the full shape returns within the session")
        #expect(Array(context.history.steps.suffix(2)).map(\.name)
                    == ["Move Selection", "Move Selection"])
    }

    @Test func noStepWhileFullyOffCanvas() throws {
        // D-34 at the off-canvas boundary (D-40): once the outline is fully off-canvas
        // the document selection is nil; further nudges keep moving the frame but each
        // produces `after == before == nil` — no step — and the shape still returns
        // when dragged back.
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        drag(tool, context, from: point(100, 100), to: point(400, 100))
        let stepsAfterOffCanvas = context.history.steps.count
        #expect(stepsAfterOffCanvas > 1 && names(context).last == "Move Selection")
        #expect(context.selection == nil)
        #expect(tool.keyDown(key(.rightArrow, .command), context: context))
        #expect(tool.keyDown(key(.rightArrow, .command), context: context))
        #expect(tool.keyDown(key(.downArrow), context: context))
        #expect(context.history.steps.count == stepsAfterOffCanvas,
                "nil → nil nudges change nothing (H-6/D-34)")
        #expect(context.selection == nil)
        // The session kept moving the frame (now x 370…470, y 51…151); drag it back
        // from inside that off-canvas frame — no "Select All" step.
        drag(tool, context, from: point(420, 101), to: point(110, 101))
        #expect(context.selection == (try rectSelection(60, 51, 100, 100)),
                "the shape returns after the no-step nudges")
        #expect(names(context).last == "Move Selection")
    }

    // MARK: - Quality

    @Test func pixelatedQualityGivesBinaryMask() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        context.memoryOptions.setValue(SelectionQuality.pixelated,
                                       for: SelectionToolOptions.quality)
        let target45 = point(100 + 50 * cos(45 * Double.pi / 180), 100 + 50 * sin(45 * Double.pi / 180))
        drag(tool, context, from: point(150, 100), to: target45, button: .secondary)
        let selection = try #require(context.selection)
        for y in 0..<200 {
            for x in 0..<200 {
                let value = selection.mask.coverage(x: x, y: y)
                #expect(value == 0 || value == 255, "(\(x), \(y)) = \(value)")
            }
        }
    }

    // MARK: - Cursor

    @Test func cursorFollowsHover() throws {
        let (tool, context) = try activated(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        tool.mouseMoved(event(context, 150, 150), context: context)
        #expect(tool.cursor(at: point(150, 150), modifiers: []) == .resize(.bottomRight))
        tool.mouseMoved(event(context, 100, 100), context: context)
        #expect(tool.cursor(at: point(100, 100), modifiers: []) == .move)
        tool.mouseMoved(event(context, 100, 40), context: context)
        #expect(tool.cursor(at: point(100, 40), modifiers: []) == .rotate,
                "10 points above the top edge → the rotate corridor")
        #expect(tool.cursor(at: nil, modifiers: []) == .arrow, "outside the canvas")

        let (tool2, _) = try activated(rect: nil)
        #expect(tool2.cursor(at: point(100, 100), modifiers: []) == .move,
                "no selection: a drag will Select All and move")
    }
}
