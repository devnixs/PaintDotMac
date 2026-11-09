# 0019 — Add the Move Selection tool: move, scale, and rotate the selection outline with handles, arrow-key nudging, and shared transform-handle geometry

> Source: PRD.md §5.3 T-6 ("Move Selection — M — Moves only the selection outline", P0); §5.3 intro and §12 D-13 / D-35 / D-41 (M cycles Move Selected Pixels → Move Selection; only implemented tools cycle; Shift+M = the group's last tool; selection changes are history steps); §5.12 (Ctrl → ⌘, Alt → ⌥); §12 D-34 (no-op edits add no step), D-40 (empty selection = no selection); AGENTS.md architecture rules 1, 2, 6, 8.
> Paint.NET references (fetched 2026-11-05; www.getpaint.net/doc/latest redirects to paint.net/doc/latest):
> - Move Tools — https://paint.net/doc/latest/MoveTools.html ("This tool allows the user to move, rotate, and scale the selection outline. This does not change any pixels on the active layer."; Control Nubs on edges and corners; dragging a nub past the opposite one flips; a rotation corridor just outside the bounding rectangle; "The Right Mouse button always accesses rotation - regardless of the location of the cursor."; Shift while rotating → multiples of 15°; Shift keeps the aspect ratio; Alt "resizes the selection about it's center"; arrow keys nudge 1 px, Ctrl × 10).
> - Keyboard & Mouse Commands — https://paint.net/doc/latest/KeyboardMouseCommands.html, Move Tools section: "Move Selection tool — M x 2 or Shift + M", "Resize the selection — Drag corner or edge nub.", "Resize & keep proportions — Shift + drag corner nub", "Resize about selection center — Alt + drag corner nub", "Move selection — Drag with Left Mouse Button when pointer is a four-way arrow", "Move selection by 1px — arrow keys", "Move selection by 10px — Hold Ctrl and press any arrow key", "Rotate selection — Drag with Left Mouse Button when pointer is a double headed arrow or drag with Right Mouse Button", "Rotate by 15° increments — Hold Shift down while rotating".
> - Paint.NET 3.36 source (behavior details the docs omit): `src/tools/MoveToolBase.cs` and `src/tools/MoveSelectionTool.cs`, `src/Strings/Strings.resx` in https://github.com/wangdeshui/paint.net (history names, per-mouse-up steps, `ConstrainAngle`, `ConstrainScaling`, arrow-key nudging, auto Select All, `ToolBarConfigItems.None`).
> Milestone: M2
> Depends on: 0006-tool-framework-and-panels, 0008-history-stack-and-undo-bridge, 0013-selection-core-and-marching-ants, 0014-rectangle-and-ellipse-select

## Context

Nothing of this exists yet (no application code). After 0013–0017 the document has a `Selection` (vector path + 8-bit mask), marching ants, selection tools that create selections, and selection-clipped painting, but no way to adjust a selection after drawing it. 0014 deliberately left post-draw handles to this spec (`docs/specs/todo/0014-rectangle-and-ellipse-select_TODO.md:52`, `:301`, `:312`). 0006 already lists the tool: `ToolID.moveSelection`, descriptor row `moveSelection | Move Selection | m | move | selection.pin.in.out | supportsPendingEdits false` (`docs/specs/todo/0006-tool-framework-and-panels_TODO.md:49`, `:147`), and `HistoryIcon.moveSelection` exists (`0008…:52`). 0013 says the selection path is kept "for later transforms (0019)" and that 0019 re-rasterizes a moved path (`0013…:100`, `:121`).

### Types this spec builds on (exact names from the sibling specs)

- 0006: `Tool` (`mouseDown/Dragged/Up/Moved`, `flagsChanged`, `keyDown(_:context:) -> Bool`, `cursor(at:modifiers:)`, `activate`/`deactivate`, `cancel`), `ToolEvent` (`location` canvas space, Double, top-left origin, y down; `viewLocation` AppKit view points, bottom-left origin; `button` `.primary`/`.secondary` — right button **and Control-left** arrive as `.secondary`; `modifiers: ToolModifiers` `.shift/.option/.control/.command`; `timestamp`), `ToolKey` (`.leftArrow/.rightArrow/.upArrow/.downArrow` by key code 123/124/126/125), `ToolKeyEvent` (`key`, `modifiers`, `isRepeat`), `ToolContext` (`transform`, `options`, `setOverlay`, `invalidateCursor`), `ToolOverlay` + `Canvas/ToolOverlayView.swift`, `ToolCursor` + `Canvas/ToolCursor+AppKit.swift`, `ToolRegistry.standard()` / `shortcutGroup(for:)` (implemented tools only), `ToolDispatcher` (one gesture at a time; Escape mid-gesture → `cancel` and swallows the rest), `UI/ToolOptionsBar.swift` (`ToolOptionsContent`), `FakeToolContext`, `FakeCanvasNavigation`, `UITestApp`.
- 0008: `HistoryItem` (`isNoOp`), `HistoryIcon.moveSelection`, `.selectAll`, `ToolContext.performHistory(_:)`, `HistoryStack`, `UndoBridge.onStateChange`.
- 0013: `Selection` (`canvasSize`, `path` — normalized and clipped to the canvas, `mask`, `bounds: PixelRect`, `init?(path:canvasSize:antialiased:fillRule:)`, `init?(mask:outline:)`, `all(canvasSize:)`; `nil` = no selection; Equatable on canvas size + mask content + path), `SelectionMask` (256-px tiles `.empty`/`.full`/`.partial`; `init(size:tiles:)` normalizes; `coverage(x:y:)`; `tile(at:)`), `MaskRasterizer.rasterize(_:size:antialiased:)` (the only path → pixel conversion; non-zero winding), `SelectionHistoryItem(name:icon:before:after:)` (no-op when equal), `SelectionCommand.selectAll.makeHistoryItem(for:)`, `DocumentState.selection`, `ToolContext.selection`, `CanvasTransform.canvasToViewAffine`, `Canvas/MarchingAntsOverlay.swift` (identifier `canvas.marchingAnts`), launch hook `-UITestSelectRect x,y,w,h`.
- 0014: `SelectionToolOptions.quality` (`tool.rectangleSelect.selectionQuality`, `SelectionQuality.pixelated/.antialiased`, default antialiased — the shared Paint.NET "selection clipping mode"), the `ToolOverlay.selectionShape(SelectionShapePreview)` case and its `hidesCurrentSelection` rule in `MarchingAntsOverlay`, `SelectionSizeDisplay` and the status-bar selection-size refresh on every `UndoBridge.onStateChange` (so the size updates after each step of this tool with no extra work).
- 0002: `PixelSize`, `PixelRect`, `PixelPoint`, `TileCoordinate`.

### Paint.NET behavior mirrored

1. **Outline only.** Move Selection moves, scales, and rotates the outline; pixels never change (MoveTools.html).
2. **Gesture is chosen at mouse-down** (`MoveToolBase.DetermineMoveMode`): right button → **rotate**, wherever the pointer is; else the nearest nub under the pointer → **scale** from that nub; else (Paint.NET 4+ docs) inside the corridor just outside the frame → **rotate**; else → **translate** ("inside or well outside the selection").
3. **Translate** uses integer document offsets (3.36 works in integer document coordinates), so moved masks stay pixel-exact.
4. **Rotate** about the frame's center (3.36: center of the lifted bounds mapped through the current transform); angle delta = `atan2(current − c) − atan2(start − c)`; **Shift** snaps the *total* angle (`startAngle + delta`) with `ConstrainAngle` (nearest multiple of 15°, ties go up, result in (−180, 180]). The total angle accumulates across drags while the tool keeps its context (`context.startAngle`).
5. **Scale** happens in the frame's own (rotated) axes (3.36 un-rotates, scales, re-rotates). Edge nubs scale one axis, corner nubs both. **Shift + corner nub** keeps the proportions of the bounds at the start of the session (`ConstrainScaling`: `best = min(newW / liftedW, newH / liftedH)`); Shift on an edge nub does nothing (`allowConstrain = false`). **Alt (⌥) + nub** scales about the center (4.x docs). Dragging a nub past the opposite one flips.
6. **Arrow keys** (when not dragging) move by 1 px; **Ctrl (⌘)** × 10 (`OnKeyPress` simulates a down/move/up, i.e. one translate step per key press, auto-repeat included). Ignored while a drag is in progress.
7. **History: one step per mouse-up** (`OnMouseUp → FlushHistoryMementos`) named by the gesture (Strings.resx): **"Move Selection"** (translate, and every arrow-key nudge), **"Scale Selection"**, **"Rotate Selection"**. 3.36 also records a "Finish Selection" step when the tool is deactivated; for an outline-only move that step changes nothing, so PaintDotMac records none (D-34). See Open question 1.
8. **No selection → Select All first** (`MoveToolBase.OnMouseDown`: an empty selection pushes a "Select All" memento, then the move proceeds). Arrow keys go through the same path.
9. **No toolbar options** (`MoveSelectionTool`: `ToolBarConfigItems.None`). The resampling/gamma options in MoveTools.html belong to Move Selected Pixels (0020).
10. Ctrl-drag "move a copy" only matters for pixels → 0020. 4.x's draggable rotation pivot is not in v1.0 (Out of scope).

## User story

As a PaintDotMac user, with a selection drawn, I press M (or Shift+M) to get Move Selection; I see the marching ants plus eight nubs around the selection; I drag inside to move the outline, drag a nub to resize it (Shift keeps proportions, ⌥ resizes about the center), right-drag (or drag just outside the frame) to rotate it (Shift snaps to 15°), and nudge it with the arrow keys (⌘ for 10 px). No pixels change; each drag or nudge is one "Move Selection" / "Scale Selection" / "Rotate Selection" step that ⌘Z undoes; painting afterwards is clipped to the moved selection.

## Scope & changes

### Core (pure Swift, no AppKit/SwiftUI; unit-tested)

- **`Core/Tools/TransformHandles.swift`** (new) — the handle and transform geometry shared with 0020 (Move Selected Pixels reuses every type here unchanged and only adds to it). All coordinates are canvas space (image pixels, y down) unless named `view…`. Angles are degrees, positive = clockwise on screen (the y-down rotation `CGAffineTransform(rotationAngle:)` gives).
  ```swift
  enum TransformHandle: CaseIterable, Sendable, Equatable {
      case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
      var unit: (x: Int, y: Int)          // (-1,-1) (0,-1) (1,-1) (1,0) (1,1) (0,1) (-1,1) (-1,0)
      var isCorner: Bool                  // both components non-zero
  }
  enum TransformGesture: Sendable, Equatable { case translate, scale(TransformHandle), rotate }

  /// The box the handles sit on. `box` is in local (unrotated) coordinates and may be flipped (minX > maxX);
  /// `rigid` (rotation + translation only) maps local → canvas.
  struct TransformBox: Sendable, Equatable {
      var minX, minY, maxX, maxY: Double
      var center: CGPoint                  // ((minX+maxX)/2, (minY+maxY)/2)
      func localPoint(for handle: TransformHandle) -> CGPoint   // x: unit.x -1 → minX, 0 → center.x, +1 → maxX (same for y)
  }

  struct TransformSession: Sendable, Equatable {
      let sourceBounds: TransformBox       // R0: bounding box of the source outline at session start (never flipped, width/height > 0)
      private(set) var box: TransformBox   // R: current local box
      private(set) var rigid: CGAffineTransform  // local → canvas, rotation + translation; identity at start
      private(set) var angle: Double       // accumulated rotation, normalized to (-180, 180]
      init?(sourceBounds: CGRect)          // nil if empty, non-finite, or width/height ≤ 0
      var outlineTransform: CGAffineTransform   // source canvas → current canvas: map(R0 → R) then rigid
      var canvasCorners: [CGPoint]         // rigid(box corners) in order TL, TR, BR, BL
      func canvasPosition(of handle: TransformHandle) -> CGPoint
      var canvasCenter: CGPoint            // rigid(box.center): the rotation center
      var integerTranslation: (dx: Int, dy: Int)?  // non-nil iff outlineTransform is a pure integer translation (|a−1|,|b|,|c|,|d−1| ≤ 1e-9, tx/ty within 1e-9 of integers)

      /// Returns the session after applying a gesture from `start` to `current` (both canvas points) to `self`
      /// (the session as it was at mouse-down). Pure; the tool calls it with the mouse-down snapshot on every drag event.
      func applying(_ gesture: TransformGesture, from start: CGPoint, to current: CGPoint,
                    modifiers: ToolModifiers) -> TransformSession
      func translatedBy(dx: Int, dy: Int) -> TransformSession
  }

  enum TransformHandles {
      static let handleSize: Double = 7          // view points (drawn square side)
      static let handleHitRadius: Double = 6     // view points
      static let rotateCorridorWidth: Double = 20 // view points outside the frame edge
      static func hitTest(viewPoint: CGPoint, session: TransformSession, canvasToView: CGAffineTransform,
                          button: ToolMouseButton) -> TransformGesture
      static func translation(from start: CGPoint, to current: CGPoint) -> (dx: Int, dy: Int)
      static func constrainAngle(_ degrees: Double) -> Double
      static func nudge(for event: ToolKeyEvent) -> (dx: Int, dy: Int)?
  }
  ```
  - **`outlineTransform`** = `S · rigid`, where `S` maps R0 to R per axis: `x' = R.minX + (x − R0.minX) × (R.maxX − R.minX) / (R0.maxX − R0.minX)` (same for y). A flipped R gives a negative scale (flip). R0 has positive width/height, so there is never a division by zero.
  - **`hitTest`** (all distances in view points, so it behaves the same at every zoom and backing scale): `button == .secondary` → `.rotate`. Else map the 8 handle positions with `canvasToView` (the 0013 `canvasToViewAffine`); the nearest one within `handleHitRadius` → `.scale(that)` (ties: `allCases` order). Else, if `viewPoint` is inside the frame quad (the 4 view-mapped corners; even-odd point-in-polygon, works for flipped quads) → `.translate`; else if its distance to the quad's nearest edge segment is ≤ `rotateCorridorWidth` → `.rotate`; else `.translate`. A degenerate quad (zero area) has no inside: only handles, corridor, and translate apply.
  - **`translation(from:to:)`**: `(Int((to.x − from.x).rounded(.toNearestOrAwayFromZero)), …y)`; non-finite → `(0, 0)`; clamped to ±1,000,000.
  - **translate gesture**: `translatedBy(translation(from:to:))` → `rigid = rigid.concatenating(translate(dx, dy))`; `box`, `angle` unchanged. Shift does nothing for translate (no constraint documented).
  - **rotate gesture**: `c = canvasCenter`; `delta = degrees(atan2(current − c) − atan2(start − c))`, normalized to (−180, 180]; `total = angle + delta`; with `.shift`: `total = constrainAngle(total)`, `delta = total − angle`. `rigid = rigid · T(−c) · R(delta) · T(c)`; `angle = normalize(total)`. If `start == c` or `current == c` (atan2 undefined in meaning), delta = 0.
  - **`constrainAngle`** (Paint.NET `ConstrainAngle`): add 360 until ≥ 0; `i = Int(angle)`; `lower = (i / 15) × 15`, `upper = lower + 15`; pick the nearer (`lowerDiff < upperDiff` → lower, else upper, so a tie goes up); if > 180 subtract 360.
  - **scale gesture** from handle `h`: `d = rigid⁻¹` applied to the **vector** `current − start` (rotation only, no translation) — the drag delta in local axes, so grabbing a nub off-center doesn't jump. Per axis with `u = h.unit` component ≠ 0 (the other axis is unchanged):
    - without ⌥: the edge on the handle's side moves by `d` (`u = +1` → `max += d`, `u = −1` → `min += d`); the opposite edge stays (anchor).
    - with ⌥ (about center): the handle's edge moves by `d` and the opposite edge by `−d`.
    - with Shift **and** `h.isCorner`: `sx = (maxX − minX) / (R0.maxX − R0.minX)` and `sy` likewise (signed); `s = min(|sx|, |sy|)`; set width `= sign(sx) × s × R0.width` and height `= sign(sy) × s × R0.height` (sign(0) = +1), re-placed around the same anchor (the fixed opposite edges, or the center with ⌥). Shift on an edge nub is ignored (Paint.NET `allowConstrain = false`).
    - `rigid`/`angle` unchanged.
  - **`nudge(for:)`**: arrow keys → `(−1,0)`, `(1,0)`, `(0,−1)` (up), `(0,1)` (down); × 10 when `.command` is held (Paint.NET Ctrl); other keys → `nil`. `isRepeat` does not matter.
  - Everything is `Double`/`CGFloat` math with finite-input guards: a non-finite point leaves the session unchanged.

- **`Core/Model/SelectionMask+Transform.swift`** (new; extends 0013's type — no parallel type):
  `func translated(dx: Int, dy: Int) -> SelectionMask` — same size; `coverage'(x, y) = coverage(x − dx, y − dy)` (0 when the source is outside). Tile-aware: when `dx` and `dy` are multiples of 256 the tiles are re-indexed without touching bytes (`.full` stays `.full`, partial storages are shared); otherwise each destination tile is assembled from at most 4 source tiles (all-empty sources → `.empty`, all-full sources fully covering → `.full`). The result is normalized with `init(size:tiles:)`.

- **`Core/Model/Selection+Transform.swift`** (new; extends 0013's `Selection`):
  ```swift
  extension Selection {
      /// The selection obtained by applying `session` to `source` (the selection at session start).
      static func transformed(_ source: Selection, by session: TransformSession, antialiased: Bool) -> Selection?
  }
  ```
  - If `session.integerTranslation` is `(dx, dy)`: `Selection(mask: source.mask.translated(dx: dx, dy: dy), outline: source.path transformed by the translation)` — pixel-exact for any mask (Magic Wand, combined, antialiased); `nil` when the shifted mask is empty.
  - Otherwise: `Selection(path: source.path transformed by session.outlineTransform, canvasSize: source.canvasSize, antialiased: antialiased)` — re-rasterized through 0013's `MaskRasterizer` (via 0013's initializer; nothing here flips Y or touches pixels). `nil` when nothing of the shape is on the canvas.
  - Note: because 0013 clips `Selection.path` to the canvas, the *source* of a session is the clipped outline at session start; parts moved off-canvas and back **within one session** come back (the session keeps the source), parts already clipped before the session started do not.

- **`Core/Tools/MoveSelectionTool.swift`** (new) — T-6. `final class MoveSelectionTool: Tool`, `id = .moveSelection`, `hasPendingEdit` always `false` (every gesture is committed on mouse-up; matches 0006's descriptor `supportsPendingEdits false`).
  - State:
    ```swift
    private struct Context { var source: Selection; var session: TransformSession; var produced: Selection? }
    private var context: Context?                 // Paint.NET's tool "context"
    private struct Drag { var gesture: TransformGesture; var start: CGPoint; var sessionAtStart: TransformSession; var selectionAtStart: Selection? }
    private var drag: Drag?
    private var hoverGesture: TransformGesture?   // for the cursor
    ```
  - **Context validity** (`ensureContext(_ context: any ToolContext)`), called from `activate`, `mouseDown`, `mouseMoved`, `keyDown`: if `self.context` exists and `toolContext.selection == self.context.produced` it stays (rotation angle and rotated handles persist across drags, as 3.36's `startAngle`); otherwise it is rebuilt from the current selection: `source = selection`, `session = TransformSession(sourceBounds: selection.path.boundingBoxOfPath)`, `produced = selection`; no selection → `context = nil`. (A context whose `produced` is `nil` — outline moved fully off the canvas — stays valid while the document selection is `nil`.) So undo/redo, History-panel jumps, Edit menu commands, or another tool's selection change reset the frame to the new selection's axis-aligned bounds.
  - **Idle overlay**: whenever the context changes or the tool is activated: `setOverlay(.transformHandles(TransformHandlesPreview(outline: nil, corners: session.canvasCorners, showsHandles: true, center: nil, hidesCurrentSelection: false)))`, or `setOverlay(nil)` without a context.
  - **`mouseDown`**: ignore non-finite locations and a second gesture. `ensureContext` first; if there is still no context (no selection and no live off-canvas session), `if let item = SelectionCommand.selectAll.makeHistoryItem(for: state) { performHistory(item) }` (0013 returns an optional) — the "Select All" step (Paint.NET behavior 8) — then `ensureContext` again. Gesture = `TransformHandles.hitTest(viewPoint: event.viewLocation, session:, canvasToView: context.transform.canvasToViewAffine, button: event.button)`; store `Drag`.
  - **`mouseDragged`**: `newSession = drag.sessionAtStart.applying(gesture, from: drag.start, to: event.location, modifiers: event.modifiers)`; keep it in `self.context.session`; overlay `.transformHandles(TransformHandlesPreview(outline: source.path transformed by newSession.outlineTransform, corners: newSession.canvasCorners, showsHandles: true, center: gesture == .rotate ? newSession.canvasCenter : nil, hidesCurrentSelection: true))`. No selection is built and nothing is rasterized while dragging. `flagsChanged`: re-apply the last drag point with the new modifiers (Shift/⌥ act live, like 3.36's `OnKeyDown → Render`), then `invalidateCursor()`.
  - **`mouseUp`**: final `applying`; if the new session equals `sessionAtStart` → restore the idle overlay, no step (a click). Otherwise `after = Selection.transformed(source, by: newSession, antialiased: options.value(SelectionToolOptions.quality) == .antialiased)`; `performHistory(SelectionHistoryItem(name: name, icon: .moveSelection, before: toolContext.selection, after: after))` with `name` = **"Move Selection"** (translate), **"Scale Selection"** (scale), **"Rotate Selection"** (rotate); `produced = after`; idle overlay; `drag = nil`. An `after` equal to `before` is a no-op item (no step, D-34).
  - **`keyDown`**: `nudge(for:)` non-nil → if a drag is active return `true` and do nothing (Paint.NET ignores nudges while tracking); else `ensureContext` (Select All first when there is still no context, exactly as for mouse-down), `newSession = session.translatedBy(dx:dy:)`, `after = Selection.transformed(...)`, one **"Move Selection"** step per key event (auto-repeat included), idle overlay, return `true`. Every other key → the protocol default (returns `false`: nothing pending).
  - **`cancel`** (Escape mid-drag, via 0006's dispatcher): `context.session = drag.sessionAtStart`, `drag = nil`, idle overlay, no step. **`deactivate`**: `drag = nil`, `context = nil`, `setOverlay(nil)` (no step: Paint.NET's "Finish Selection" is a no-op here). **`activate`**: `ensureContext`, idle overlay.
  - **`mouseMoved`**: `ensureContext`; `hoverGesture = hitTest(...)` with `.primary` (nil without context); `invalidateCursor()` when it changed.
  - **`cursor(at:modifiers:)`**: during a drag → the drag gesture's cursor; else `location == nil` → `.arrow`; no context → `.move` (a drag will Select All and move); else by `hoverGesture`: `.translate` → `.move`, `.rotate` → `.rotate`, `.scale(h)` → `.resize(h)`.
  - Mouse-up without a matching mouse-down, and events with non-finite locations, are ignored.

- **`Core/Tools/ToolContext.swift` / `ToolOverlay` / `ToolCursor`** (extend 0006):
  ```swift
  struct TransformHandlesPreview: Sendable, Equatable {
      var outline: CGPath?          // canvas space; the live outline while dragging, nil when idle (0013's SendablePath wrapper if CGPath isn't Sendable)
      var corners: [CGPoint]        // canvas space, TL TR BR BL of the frame
      var showsHandles: Bool
      var center: CGPoint?          // rotation center marker, shown while rotating
      var hidesCurrentSelection: Bool
  }
  case transformHandles(TransformHandlesPreview)   // new ToolOverlay case
  var hidesCurrentSelection: Bool                  // ToolOverlay helper: true for .selectionShape/.transformHandles whose flag is set
  ```
  `ToolCursor` gains `.move`, `.rotate`, `.resize(TransformHandle)`.
- **`ToolRegistry.standard()`** (modify): register `.moveSelection → MoveSelectionTool()`. Until 0020 lands, M's group is `[.moveSelection]`: M and Shift+M both select Move Selection, and the Tools panel's Move section shows its button. 0020 adds Move Selected Pixels, which becomes the group's first tool by `ToolID.allCases` order with no change here (then M → Move Selected Pixels, M M / Shift+M → Move Selection, as Paint.NET documents).

### Platform glue (AppKit/SwiftUI; UI tests and manual checks)

- **`Canvas/TransformHandlesOverlay.swift`** (new; **created here, extended by 0020**, which owns it in the sibling map for its pixel transform UI): `@MainActor enum TransformHandlesOverlay { static func draw(_ preview: TransformHandlesPreview, transform: CanvasTransform, in ctx: CGContext) }`. Maps everything with `transform.canvasToViewAffine` (never flips Y inline, CAN-6):
  - `outline` (when non-nil): 1 pt white line under a 1 pt black line dashed `[4, 4]` (the static marching-ants style from 0013's `MarchingAnts` constants).
  - the frame (the 4 corners as a closed polygon): 1 pt line, 50 % opacity black over 50 % white, solid.
  - when `showsHandles`: a `TransformHandles.handleSize` square (axis-aligned in view space) at each of the 8 handle positions (corners and edge midpoints of the frame): white fill, 1 pt black stroke; corners drawn as circles (Paint.NET draws corner nubs as circles), edges as squares.
  - `center` (when non-nil): a 10 pt circle with a cross, same stroke.
- **`Canvas/ToolOverlayView.swift`** (modify): `case .transformHandles(p)` → `TransformHandlesOverlay.draw(p, transform:, in:)`. Redraws on overlay and transform changes (existing hook).
- **`Canvas/MarchingAntsOverlay.swift`** (modify, generalizing 0014's rule): hide the current selection's ants whenever the tool overlay's `hidesCurrentSelection` is true (covers 0014's `.selectionShape` and the new case); show them again when it becomes false.
- **`Canvas/ToolCursor+AppKit.swift`** (modify): `.move` → an `NSCursor` built once from SF Symbol `arrow.up.and.down.and.arrow.left.and.right` (16 pt, hotspot at the center); `.rotate` → SF Symbol `arrow.clockwise` likewise; `.resize(h)` → `NSCursor.frameResize(position:directions: .all)` (macOS 15) with the position matching `h` (topLeft → `.topLeft`, top → `.top`, …). Cursor images are not rotated with the frame in v1.0.
- **`UI/ToolOptionsBar.swift`** (modify): `case .moveSelection:` → no tool-specific controls (Paint.NET `ToolBarConfigItems.None`); the bar shows only what 0006 shows for every tool. The re-rasterization quality comes from the shared selection-clipping option set in the selection tools (0014).
- **Arrow keys reach the tool:** with the canvas as first responder, 0006's router sends non-Space `keyDown` to `dispatcher.keyDown`. 0006's local key monitor (`CanvasInputRouter.handleShortcutKeyDown`) does not consume arrow keys: their `charactersIgnoringModifiers` is a single function-key `Character` (e.g. U+F702), and 0006's `ToolDispatcher.toolKey(fromCharactersIgnoringModifiers:)` returns `nil` for anything that isn't a member of `allShortcutKeys`, so no code change is needed there. This spec adds the regression test `ToolDispatcherTests.functionKeyCharactersAreNotToolShortcuts` (below) so a later shortcut addition can't swallow arrows. ⌘-arrows have no menu equivalents (PRD §5.12), so they arrive as key events.
- **`PaintDotMacTests/Support/FakeToolContext.swift`** (extend): nothing new is required beyond 0013/0014 (selection, `performHistory`, `overlays`); add the convenience `var lastOverlay: ToolOverlay? { overlays.last ?? nil }` (0006's fake records `overlays: [ToolOverlay?]` but has no such accessor).
- **`project.yml`**: no target changes; run `xcodegen generate` (new files).
- **PRD.md / AGENTS.md**: no changes in this spec; the decisions under Open questions go to PRD §12 through the batch owner.

## Acceptance criteria

- [ ] M selects Move Selection while it is the only implemented M tool; Shift+M selects it; the Tools panel shows it in the Move section. → `ToolRegistryTests.moveGroupHasMoveSelection`; UI `MoveSelectionUITests.testMKeySelectsMoveSelection`
- [ ] Dragging inside the selection moves only the outline by the rounded integer offset; pixels are unchanged; one "Move Selection" step. → `MoveSelectionToolTests.dragTranslatesOutline`, `.pixelsUnchanged`; UI `MoveSelectionUITests.testDragMovesSelectionAndUndoes`
- [ ] Dragging an edge or corner nub scales the outline in the frame's axes; Shift + corner keeps the session-start proportions; Shift + edge is ignored; ⌥ scales about the center; dragging past the opposite nub flips; one "Scale Selection" step. → `TransformSessionTests.scale*`, `MoveSelectionToolTests.cornerHandleScales`, `.optionScalesAboutCenter`, `.shiftCornerKeepsProportions`
- [ ] Right-drag anywhere, or left-drag in the corridor just outside the frame, rotates about the frame center; Shift snaps the total angle to 15° steps; the angle accumulates across drags; one "Rotate Selection" step. → `TransformSessionTests.rotate*`, `TransformHandlesTests.constrainAngle*`, `MoveSelectionToolTests.rightDragRotates90`, `.shiftRotateSnaps`, `.rotationPersistsAcrossDrags`
- [ ] Handle hit-testing works in view points (same behavior at every zoom and backing scale): nearest nub wins, inside → translate, corridor → rotate, far outside → translate, right button → rotate. → `TransformHandlesTests.hitTest*`
- [ ] While dragging, the live outline and handles are drawn, the old ants are hidden, and the document selection is unchanged until mouse-up. → `MoveSelectionToolTests.dragPreviewOnly`; look → manual
- [ ] Arrow keys nudge 1 px, ⌘-arrows 10 px, one "Move Selection" step per key event (auto-repeat included), ignored mid-drag. → `TransformHandlesTests.nudgeMapping`, `MoveSelectionToolTests.arrowNudges`, `.nudgeIgnoredDuringDrag`; UI `MoveSelectionUITests.testArrowKeysNudgeAndPaintingFollows`
- [ ] Integer translations move the mask pixel-exactly (any mask, including antialiased and Magic Wand masks); other transforms re-rasterize the transformed path with the shared selection-clipping quality. → `SelectionMaskTranslateTests.*`, `SelectionTransformTests.*`, `MoveSelectionToolTests.pixelatedQualityGivesBinaryMask`
- [ ] Undo restores the exact previous selection, redo the moved one; after undo the frame resets to the restored selection. → `MoveSelectionToolTests.undoRedo`, `.contextResetsAfterExternalChange`
- [ ] A click without movement, and a drag that ends where it started, add no step; Escape mid-drag cancels with no step. → `MoveSelectionToolTests.clickIsNoOp`, `.escapeCancels`
- [ ] With no selection, a drag or arrow key first records "Select All", then moves (Paint.NET). → `MoveSelectionToolTests.noSelectionSelectsAllFirst`
- [ ] Moving the outline completely off the canvas leaves no selection (D-40) as an undoable step; dragging it back within the same session restores the full shape. → `MoveSelectionToolTests.offCanvasAndBack`
- [ ] Painting after a move is clipped to the moved selection. → `MoveSelectionIntegrationTests.paintClippedToMovedSelection`; UI `MoveSelectionUITests.testArrowKeysNudgeAndPaintingFollows`
- [ ] The cursor shows move / resize / rotate according to the hover target. → `MoveSelectionToolTests.cursorFollowsHover`; look → manual
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **No selection:** cursor `.move`; mouse-down/arrow → "Select All" step then the move (two steps; ⌘Z twice restores no selection). → `noSelectionSelectsAllFirst`
- **Selection moved entirely off the canvas:** `Selection.transformed` returns `nil`; the step records `after = nil` (no selection; painting is unrestricted, per D-40). The tool keeps its context because `selection == produced` (`nil == nil`), so the frame and handles stay visible off-canvas (pan to see them) and dragging back restores the shape. Switching tools then drops the context. → `offCanvasAndBack`
- **Partly off-canvas at session start:** the clipped part is gone (0013 clips the stored path); only parts moved off during this session can come back. → `SelectionTransformTests.sessionSourceKeepsOffCanvasParts`
- **Zero-size scale** (nub dragged exactly onto the opposite edge): the box width is 0, the transformed path has no area → `nil` result like off-canvas; continuing to drag in the same gesture past it flips. No division by zero (R0 is never degenerate). → `TransformSessionTests.scaleThroughZeroFlips`
- **1×1 selection / tiny frame at low zoom:** all handle hit circles overlap; the nearest handle wins, ties in `allCases` order; translate stays reachable from "well outside" (beyond the corridor), and arrow keys always work. → `TransformHandlesTests.hitTestTinyFrame`
- **Huge images (65,535 px sides):** dragging only transforms a path (no rasterization); mouse-up rasterizes through 0013's tiled rasterizer; integer moves shift tiles without rasterizing. → performance test below
- **Rotation exactly through 180°** normalizes to 180 (never −180); repeated rotations keep `angle` in (−180, 180]. → `TransformSessionTests.angleNormalization`
- **Non-finite events / mouse-up without down / second button mid-drag:** ignored (0006 dispatcher + guards). → `MoveSelectionToolTests.ignoresInvalidEvents`
- **Undo/redo, History jump, Edit > Select All/Deselect/Invert while the tool is active:** context resets on the next event/activation; never a crash, the frame always matches the current selection. → `contextResetsAfterExternalChange`
- **Undo mid-drag:** 0006/0008 ignore Undo during a gesture (menu disabled while `isGestureInProgress`). → covered by 0008/0013 tests; no new behavior
- **Document switch / tool switch mid-drag:** 0006's dispatcher ends the gesture; `deactivate` drops the drag with no step. → `MoveSelectionToolTests.deactivateMidDragAddsNoStep`
- **Flipped frame** (scale past the opposite nub): point-in-quad uses even-odd and works for any winding; nubs keep their identity relative to the box (`topLeft` is at `(minX, minY)` even when flipped), as in Paint.NET. → `TransformHandlesTests.hitTestFlippedFrame`

## Test plan

- **Unit — `PaintDotMacTests/Tools/TransformHandlesTests.swift`** (expected values by hand):
  - `handlePositionsIdentity`: session from (10,20,100,50) → TL (10,20), T (60,20), TR (110,20), R (110,45), BR (110,70), B (60,70), BL (10,70), L (10,45); `canvasCenter` (60,45).
  - `handlePositionsRotated90`: same session rotated +90° about (60,45) → TL at (85,−5), TR (85,95), BR (35,95), BL (35,−5) (±1e-9).
  - `hitTestIdentity` (canvasToView = identity): secondary at (500,500) → `.rotate`; (113,22) → `.scale(.topRight)` (distance ≈ 3.6 ≤ 6); (60,45) → `.translate`; (60,10) (10 pt above the top edge, 50 from nubs) → `.rotate`; (60,−20) (40 pt above) → `.translate`; (110,77) (7 from BR) → `.rotate` (outside the hit radius, inside the corridor).
  - `hitTestScalesWithZoom`: canvasToView = scale(4): canvas (111,21) is view distance ≈ 5.7 from TR → `.scale(.topRight)`; canvas (112,22) → view distance ≈ 11.3 → not a handle → `.rotate` (corridor).
  - `hitTestTinyFrame`: session (0,0,1,1), identity → (0,0) → `.scale(.topLeft)`; (0.5,0) → `.scale(.top)` (distance 0); (30,30) → `.translate`.
  - `hitTestFlippedFrame`: box flipped in x (minX 110, maxX 10) → inside point (60,45) → `.translate`; (10,20) → `.scale(.topRight)` (topRight sits at (maxX, minY) = (10,20)).
  - `translationRounding`: (10.2,10.2)→(13.7,9.4) = (4,−1); (0,0)→(−0.5,0.5) = (−1,1); NaN → (0,0); 1e12 → clamped 1,000,000.
  - `constrainAngle`: 50 → 45; 52.6 → 60; 52.5 → 60 (tie goes up); 7.5 → 15; 190 → −165; −10 → −15; 0 → 0; 180 → 180.
  - `nudgeMapping`: ← (−1,0), → (1,0), ↑ (0,−1), ↓ (0,1); ⌘→ (10,0); ⇧→ (1,0); `.character("a")` → nil.
- **Unit — `PaintDotMacTests/Tools/TransformSessionTests.swift`:**
  - `initRejectsDegenerate`: zero width, NaN → nil.
  - `translateComposes`: (0,0,100,50) translate (4,−1) then (−4,1) → `integerTranslation == (0,0)`, `outlineTransform` identity within 1e-9.
  - `rotateQuarterTurn`: center (50,25); start (100,25) → current (50,75) → angle 90; `canvasCorners` = TL (75,−25), TR (75,75), BR (25,75), BL (25,−25).
  - `rotateShiftSnapsTotal`: angle already 10; raw delta 37 (total 47) with Shift → total 45, angle 45.
  - `angleNormalization`: four +90 rotations → angle 0; two +90 → 180; then +90 → −90.
  - `scaleCornerBR`: (0,0,100,50), BR drag (50,25) → box (0,0,150,75).
  - `scaleEdgeRightFlip`: right drag (−150,0) → minX 0, maxX −50; `outlineTransform` maps (100,0) to (−50,0) and (0,0) to (0,0).
  - `scaleThroughZeroFlips`: right drag (−100,0) → width 0 (corners collinear); (−101,0) → maxX −1.
  - `scaleAboutCenter`: ⌥ right drag (10,0) → minX −10, maxX 110.
  - `scaleShiftCorner`: ⇧ BR (100,0) → candidate 200×50 → sx 2, sy 1 → s 1 → box (0,0,100,50); ⇧ BR (100,50) → (0,0,200,100); ⇧ right (100,0) → (0,0,200,50) (edge: ignored).
  - `scaleShiftUsesSessionStartAspect`: first plain right drag (100,0) → 200×50; then ⇧ BR (0,50) → sx 2, sy 2 → 200×100 (aspect of R0 = 2:1).
  - `scaleInRotatedFrame`: rotated +90° about the center, BR drag by canvas vector (0,20) → local (20,0) → box width 120, height 50.
  - `integerTranslationDetection`: after a rotate 90 + rotate −90 → `integerTranslation == (0,0)` (within tolerance); after scale ×1.5 → nil.
- **Unit — `PaintDotMacTests/Model/SelectionMaskTranslateTests.swift`** (reference oracle = per-pixel `coverage(x−dx, y−dy)` loop in the test):
  - `translateByOnePartial`: 300×300 mask with seeded random partial bytes in (100,100,120,120) → shift (1,0) → per-pixel equal to the oracle; column 0 is 0.
  - `translateByTileMultipleSharesStorage`: shift (256,0) → `.full` tiles stay `.full`; partial tiles `tileStorageIdentities` keys unchanged (no copy).
  - `translateOffCanvasIsEmpty`: shift (−300,0) on a 300-wide mask → `isEmpty`.
  - `translateAcrossTileSeams`: full tile at (0,0) shifted (128,128) on 512×512 → coverage 255 at (128..255, 128..255) and (256..383, 256..383), 0 at (127,127) and (384,384).
  - **Property** (`SeededRandom`, 200 iterations, seed printed on failure): random masks (sizes 1…700) and shifts in −800…800 → equal to the oracle; `translated(dx,dy).translated(−dx,−dy)` equals the original restricted to the pixels whose shifted position was on the canvas.
- **Unit — `PaintDotMacTests/Model/SelectionTransformTests.swift`:**
  - `integerTranslateUsesMaskShift`: source from `init?(mask:outline:)` with a seeded random antialiased mask → session translate (7,−3) → result mask equals `mask.translated(dx: 7, dy: −3)` exactly; path bbox moved by (7,−3).
  - `scaleRectReRasterizes`: rect (50,50,100,100) on 200×200, BR scale by (50,50) → mask equals `Selection(rect: (50,50,150,150)).mask`.
  - `rotateRectQuarterTurn`: rect (50,80,100,40), rotate 90 about (100,100) → `bounds == (80,50,40,100)`; coverage 255 at (100,100) and (85,55); 0 at (75,100) and (130,100); every pixel within ±1 of `Selection(rect: (80,50,40,100))`'s coverage.
  - `pixelatedGivesBinary`: rotate 45° with `antialiased: false` → every coverage value ∈ {0, 255}; with `true` → at least one value strictly between.
  - `offCanvasIsNil`: translate (500,0) on 200 wide → nil.
  - `sessionSourceKeepsOffCanvasParts`: source rect (50,50,100,100) on 200×200, session translate (120,0) → result bounds (170,50,30,100); then the same session translated back (−120,0) total (0,0) → result equals the source exactly.
- **Unit — `PaintDotMacTests/Tools/MoveSelectionToolTests.swift`** (`FakeToolContext` with a 200×200 opaque white image, `FakeCanvasNavigation.transform` at zoom 1 / backing 1 so view positions come from `transform.canvasToView`; selection `Selection(rect: (50,50,100,100))` unless stated; tool activated first):
  - `activateShowsHandles`: last overlay is `.transformHandles` with corners (50,50),(150,50),(150,150),(50,150), `showsHandles`, `outline == nil`, `hidesCurrentSelection == false`.
  - `dragTranslatesOutline`: down (100,100) primary, drag (110.4,95.6), up → steps end with "Move Selection" (icon `.moveSelection`); selection equals `Selection(rect: (60,46,100,100))`; exactly one new step.
  - `pixelsUnchanged`: after the drag every layer tile `sharesStorage` with the tiles before; history change reports `.selection` only.
  - `dragPreviewOnly`: during the drag `context.selection` still equals the original; last overlay outline bbox (60,46,100,100), `hidesCurrentSelection == true`; step count unchanged until mouse-up.
  - `cornerHandleScales`: down at the BR handle (150,150), drag by (+50,+50), up → "Scale Selection"; selection equals `Selection(rect: (50,50,150,150))`.
  - `optionScalesAboutCenter`: ⌥ BR drag (+20,+20) → `Selection(rect: (30,30,140,140))`.
  - `shiftCornerKeepsProportions`: selection rect (50,80,100,40); ⇧ BR drag (+100, 0) → bounds unchanged (s = 1) → no step; ⇧ BR drag (+100,+40) → 200×80 box → selection equals `Selection(rect: (50,80,200,80))` (clipped to the canvas by 0013 on both sides).
  - `rightDragRotates90`: selection rect (50,80,100,40), secondary down (150,100), drag (100,150), up → "Rotate Selection", bounds (80,50,40,100).
  - `shiftRotateSnaps`: secondary drag giving a raw 50° with ⇧ → the overlay corners match a 45° rotation (±1e-6).
  - `rotationPersistsAcrossDrags`: rotate 30°, up; the idle overlay corners are rotated 30°; a second drag on the (rotated) BR handle produces "Scale Selection" and scales along the rotated axis (BR moves along the 30° direction: hand-computed corners ±1e-6).
  - `contextResetsAfterExternalChange`: rotate 30° (step), then `history` undo through the fake → next `mouseMoved` → idle overlay corners axis-aligned (50,50)…(150,150).
  - `undoRedo`: drag, undo → selection == original (equal); redo → moved.
  - `clickIsNoOp`: down/up at the same point (primary and secondary) → no step; a drag that returns to its start → no step.
  - `escapeCancels`: down, drag (130,130), `cancel` → no step, selection unchanged, last overlay idle with the original corners.
  - `arrowNudges`: → returns true, selection (51,50,100,100), step "Move Selection"; ⌘← → (41,50,…); ↓ → (41,51,…); `isRepeat` → still a step; four steps total.
  - `nudgeIgnoredDuringDrag`: during a drag, → returns true, no step, selection unchanged.
  - `noSelectionSelectsAllFirst`: selection nil; drag (10,10)→(15,10) → step names `[…, "Select All", "Move Selection"]`, selection equals `Selection(rect: (5,0,195,200))`; undo twice → nil. Arrow → with no selection → `["Select All", "Move Selection"]`.
  - `offCanvasAndBack`: drag (100,100)→(400,100) → step "Move Selection", selection nil, overlay still `.transformHandles` (corners at x 350…450); then down at (400,100) (inside the off-canvas frame — no "Select All" step), drag to (110,100), up → selection equals `Selection(rect: (60,50,100,100))`; step names end `["Move Selection", "Move Selection"]`.
  - `pixelatedQualityGivesBinaryMask`: shared quality `.pixelated` in the fake option store; rotate 45° → mask values ∈ {0,255}.
  - `cursorFollowsHover`: mouseMoved over (150,150) → `.resize(.bottomRight)`; (100,100) → `.move`; (100,40) (10 above the top edge) → `.rotate`; `location nil` → `.arrow`; no selection → `.move`.
  - `ignoresInvalidEvents`: NaN mouseDown → nothing; mouseUp without down → nothing.
  - `deactivateMidDragAddsNoStep`: down, drag, `deactivate` → no step, last overlay nil.
  - `hasNoPendingEdit`: `hasPendingEdit == false` at every point; Return returns false.
- **Unit — `PaintDotMacTests/Tools/ToolRegistryTests.swift`** (extend): `moveGroupHasMoveSelection`: `standard().shortcutGroup(for: "m") == [.moveSelection]`; resolver: M → `.moveSelection`; Shift+M → `.moveSelection`.
- **Unit — `PaintDotMacTests/Tools/ToolDispatcherTests.swift`** (extend): `functionKeyCharactersAreNotToolShortcuts`: `toolKey(fromCharactersIgnoringModifiers:)` → nil for `"\u{F702}"`, `"\u{F703}"`, `"\u{F700}"`, `"\u{F701}"` (the four arrows).
- **Integration — `PaintDotMacTests/Integration/MoveSelectionIntegrationTests.swift`** (headless; `FakeToolContext`, real tools, `HistoryStack`):
  - `paintClippedToMovedSelection`: Rectangle Select drag (50,50)→(149,149); Move Selection nudge ⌘→ (10 px); Paintbrush (black, width 20, hardness 100, antialiasing off) horizontal stroke across row 100 from x 0 to 199 → pixel (155,100) black, (55,100) white, (165,100) white; history names `["New Image", "Rectangle Select", "Move Selection", "Paintbrush"]`; undo ×2 → selection back at (50,50,100,100), pixels white.
  - `rotateScaleTranslateUndoChain`: rotate 90, scale BR, translate → names `["Rotate Selection", "Scale Selection", "Move Selection"]`; undo all three → selection equal to the original; redo all → equal to the result before undo.
- **UI tests — `PaintDotMacUITests/MoveSelectionUITests.swift`** (fixture: 200×200 white PNG generated by `UITestApp`; reset defaults; `-UITestSelectRect 50,50,100,100`). **0020 updates these three tests:** once Move Selected Pixels exists, M selects it, so 0020 changes every "press M" below to Shift+M (and the B-then-Shift+M check in test 1 stays); `ToolRegistryTests.moveGroupHasMoveSelection` is likewise replaced by 0020's `moveGroupOrder`.
  1. `testMKeySelectsMoveSelection`: press M → `tool.moveSelection` selected; press B, then Shift+M → selected again.
  2. `testDragMovesSelectionAndUndoes`: M; `dragOnCanvas(from: (0.5,0.5), to: (0.6,0.6))` (the image is centered, so the start is inside the selection) → `historyList` gains a row "Move Selection"; `statusBar.selectionSize` still `"100 × 100"`; `canvas.marchingAnts` `"animated"`; ⌘Z → the row is gone (or greyed per 0010's redo display) and ⌘S of the untouched image still decodes all white (no pixel change).
  3. `testArrowKeysNudgeAndPaintingFollows`: M (the canvas is the document window's first responder after launch, so arrow keys reach it); ⌘→ → a "Move Selection" row and `statusBar.selectionSize` still `"100 × 100"`; B; width 20 via `toolOptions.width`; drag horizontally across the canvas through its vertical center (as in 0013's `testPaintingIsClippedToSelection`); ⌘S, read the PNG → (155,100) black, (55,100) white.
- **Performance — `PaintDotMacTests/Performance/MoveSelectionPerformanceTests.swift`** (XCTest `measure`): 8000×6000 canvas with an ellipse selection covering it; (a) integer nudge → `Selection.transformed` (mask shift); (b) 30° rotation → re-rasterization. Report numbers in the Verification status; gate only at 3 s (a) and 10 s (b) in Debug. Dragging itself never rasterizes, so NF-1 (≤ 16 ms per frame) is unaffected: the overlay draws one path.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build, zero warnings, all tests pass with none skipped, UI tests ran, launch smoke passes.
- **Manual verification** (look and feel the tests can't judge; also rotation and nub drags, which XCUITest can't do with the right button):
  1. Open a photo, draw a rectangle selection, press M: ants plus 8 nubs (round corners, square edges) appear; the cursor is a four-way arrow inside, a resize cursor on nubs, a rotate cursor just outside the frame.
  2. Drag inside: a dashed outline follows the pointer smoothly at 25 %, 100 %, 800 % on a Retina and a non-Retina display; the old ants disappear during the drag and the ants reappear at the new place on release; pixels never move.
  3. Drag a corner nub with Shift (proportions kept), with ⌥ (about the center), past the opposite nub (flip).
  4. Right-drag (and Control-drag): the outline rotates about the center marker; with Shift it snaps to 15° steps; release, then drag a nub: the nubs sit on the rotated frame.
  5. Arrow keys and ⌘-arrows move 1 / 10 px; holding an arrow key repeats; each press is one History row.
  6. Press B and paint: painting is confined to the moved/rotated selection with smooth edges (Antialiased) or hard edges after switching Selection clipping to Pixelated in Rectangle Select.

## Open questions

These are decided as stated (following Paint.NET 3.36 / the 4.x docs) so the spec is implementable; the batch owner should confirm them and copy them into PRD §12. (Not questions: the step names "Move Selection" / "Scale Selection" / "Rotate Selection" follow the batch convention that history names use Paint.NET's spelling, and the arrow-key routing is an implementation detail covered by `functionKeyCharactersAreNotToolShortcuts`.)

1. **One step per mouse-up and per arrow-key event** (auto-repeat included, as Paint.NET 3.36), and no "Finish Selection" step (it would change nothing, D-34). Recommended: yes.
2. **No selection → Select All, then move** (Paint.NET 3.36 `OnMouseDown`). Recommended: yes (two undoable steps).
3. **Moving the outline entirely off the canvas yields no selection** (D-40: an empty selection is no selection), recorded as an undoable step; the tool keeps the off-canvas frame so it can be dragged back until the tool is switched. Paint.NET keeps an "empty" off-canvas selection instead. Recommended: as specified.
4. **Rotation corridor (left-drag just outside the frame, 20 pt) and ⌥ = scale about center** come from the Paint.NET 4.x docs; 3.36 had only right-drag rotation and no Alt scaling. Recommended: include both (both are in the current docs). The draggable rotation pivot (4.x) is out of scope.

## Out of scope

- Move Selected Pixels (T-5), floating pixels, resampling, the resampling/gamma toolbar options, Ctrl-drag "move a copy", and the "Finish Pixels" commit → **0020** (which reuses `TransformHandles.swift`, `TransformSession`, the `.transformHandles` overlay case, `TransformHandlesOverlay.swift`, and the new cursors, and becomes the M group's first tool).
- Paint.NET 4.x's draggable rotation pivot, the angle readout in the status bar, cursors rotated with the frame, and Shift axis-locking for translate (not documented by Paint.NET).
- Live selection-size readout while dragging (the status bar updates on mouse-up through 0014's `onStateChange` hook).
- Selection creation, combine modes, quality picker → 0014/0015/0016; Erase/Fill Selection → 0018; Crop to Selection → 0022.
