# 0039 — Add the Shapes tool (Rectangle, Rounded Rectangle, Ellipse, and the Basic shapes; outline / fill / both; editable until committed)

> Source: PRD.md §5.3 T-19 ("Shapes — O — Rectangle, rounded rectangle, ellipse, and a starter set of other shapes. Outline, fill, or both. Editable until committed."), §5.3 intro (O group: Line / Curve → Shapes; D-13/D-35/D-41 cycling: O cycles, Shift+O selects the group's last tool = Shapes), §3 use case 1 ("add arrows, text, and highlight rectangles, then export a PNG"), TOOL-A (left = primary, right / Control-left = secondary), TOOL-B (confined to the selection), TOOL-C (settings persist), APP-4 (tool options bar, Finish), §5.12 (`[` / `]` brush width), NF-9 (straight RGBA8), NF-4 (undo stores changed tiles only), H-6 / D-34 (no-op edits add no step), D-15 (tool blend list = implemented layer blend modes), D-17 (`UserBlendOps`), D-19 (CoreGraphics in Core). T-20 (extended shape library) is P1 and belongs to 0058. Paint.NET docs: Shapes Tool, https://paint.net/doc/latest/ShapeTools.html (old URL https://www.getpaint.net/doc/latest/ShapeTools.html, revision of 27 Feb 2024); Tool Bar, https://paint.net/doc/latest/Toolbar.html (Brush Width, Antialiasing, Blend Mode, Finish).
> Milestone: M5
> Depends on: 0038-line-curve-tool (shared `EditableShapeEditor`, `EditableShapeGeometry`, `ShapeRasterizer`, `ShapePaint`, `ShapeRenderParameters`, `ShapeStrokeStyle`/`DashStyle`, `ShapeHandlesOverlay`, `ToolOverlay.shapeHandles`); functionally on 0019 (`TransformSession`, `TransformHandles`, `TransformHandle`, `TransformBox`, cursors `.move/.rotate/.resize`), 0023 (`GradientRenderer.effectiveClip`, pending-edit precedent), 0020 (`PendingEditReason`, `prepareForHistoryNavigation`), 0013 (selection clip, `-UITestSelectRect`), 0009 (`BlendOps`, `BrushOptions.widthRange`, `BrushWidthAdjustable`), 0008 (history, `HistoryIcon.shapes`), 0007 (colors, `colors.hex`), 0006 (tool framework).

## Context

Not yet implemented: there is no application code. This spec builds on these types from lower-numbered specs (use their exact names and signatures):

- **0006**: `@MainActor protocol Tool` (`hasPendingEdit`, `activate`/`deactivate` (default commits), `mouseDown/Dragged/Up/Moved`, `flagsChanged(_:context:)`, `keyDown(_:context:) -> Bool` with the default Return/Enter → commit and Escape → cancel while pending, `cursor(at:modifiers:)`, `commit(context:)`, `cancel(context:)`, `optionsDidChange(context:)`), `ToolEvent` (`location` canvas space, Double, top-left origin, y down; `viewLocation` AppKit view points; `button` `.primary/.secondary`, Control-left → `.secondary`; `modifiers` `.shift/.option/.control/.command`), `ToolKey`/`ToolKeyEvent` (`.character(Character)` lowercased, arrows), `ToolContext` (`image`, `transform`, `options`, `colors`, `setOverlay`, `invalidateCursor`, `commitHistory`, `updateImage`, `paintClipMask`), `ToolID.shapes`, descriptor row `shapes | Shapes | o | textAndShape | square.on.circle | supportsPendingEdits true` (unchanged here), `ToolRegistry.standard()` / `shortcutGroup(for:)`, `ToolOptionKey(tool:name:defaultValue:range:)`, `ToolOptionValue` (String raw-value enums opt in), `ToolOptionStore`, `InMemoryToolOptionStore`, `ToolDispatcher.commitPendingEdit()`, `UI/ToolOptionsBar.swift` (`ToolOptionsContent`; Finish `toolOptions.finish`), `Canvas/ToolOverlayView.swift`, `FakeToolContext`.
- **0007**: `ColorSelection` (`.primary` default black, `.secondary` default white); Colors panel hex field `colors.hex`.
- **0008**: `TileDiffHistoryItem(name:icon:diff:)`, `HistoryIcon.shapes` (already a case; 0010 maps it to `square.on.circle`), `UndoBridge`.
- **0009**: `BlendOps.blend(_:dst:src:opacity:)`, `BlendOps.mul255`, `BrushOptions.widthRange` (1…2000), `BrushWidthAdjustable` (`[`/`]` ±1), `BrushClipMask`; toolbar control patterns `toolOptions.width` / `.width.decrease` / `.width.increase` / `.antialiasing` / `.blendMode`.
- **0013**: `Selection`, `SelectionMask` (a `BrushClipMask`), `paintClipMask = selection?.mask`, `-UITestSelectRect x,y,w,h`.
- **0019** (`PaintDotMac/Core/Tools/TransformHandles.swift`), reused unchanged as the Shapes edit frame: `TransformHandle` (8 cases in order topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left; `unit`, `isCorner`), `TransformGesture` (`.translate`, `.scale(TransformHandle)`, `.rotate`), `TransformBox` (may be flipped; `localPoint(for:)`), `TransformSession` (`init?(sourceBounds:)` — nil unless width/height > 0; `box`, `rigid`, `angle`, `canvasCorners`, `canvasPosition(of:)`, `canvasCenter`, `applying(_:from:to:modifiers:)` with Shift-corner proportions from R0, ⌥ about center, flipping past the opposite nub, Shift rotation snapped by `constrainAngle` to 15°, integer translation; `translatedBy(dx:dy:)`), `TransformHandles.hitTest(viewPoint:session:canvasToView:button:)` (secondary → `.rotate`; nub within 6 pt → `.scale`; inside the frame quad → `.translate`; within the 20 pt corridor → `.rotate`; else `.translate`), `TransformHandles.nudge(for:)` (arrows, ⌘ × 10), `ToolCursor.move/.rotate/.resize(TransformHandle)`.
- **0023**: `GradientRenderer.effectiveClip` (antialiasing off → clip thresholded at 128), used inside 0038's `ShapeRasterizer`.
- **0038** (`PaintDotMac/Core/Tools/Shapes/`): `DashStyle` (solid, dash, dot, dashDot, dashDotDot; `unitPattern`), `ShapeStrokeStyle` (`width`, `dashStyle`, `startCap`, `endCap`, `clamped()`, `dashLengths`), `ShapePaint(path:fillRule:color:)`, `ShapeRenderParameters(paints:antialiasing:blendMode:)` (paints composited in order, later on top), `ShapeRasterizer.coverage(of:fillRule:antialiasing:in:)` / `render(_:before:into:clip:)` / `composePixel(...)`, `ShapeHandleKind` (`.endpoint`, `.control`; this spec adds `.corner`, `.edge`), `ShapeHandle`, `ShapeGuide`, `ShapeHandlesOverlayModel`, `protocol EditableShapeGeometry` (`handles`, `guides`, `isDegenerate`, `moveHandle(_:to:constrained:)`, `translate(by:)`, `bodyHit(atView:transform:tolerance:)`, `dragBody(from:parameter:delta:)`), `ShapeEditCapture` (`layerID`, `before`, `clip`, `color` = slot of the gesture's button, `secondaryColor` = the other slot), `ShapeEditPhase` (`idle`, `drawing`, `editing`, `draggingHandle(Int)`, `draggingBody(parameter:grab:)`; this spec adds `.rotating`), `EditableShapeEditor<Geometry>` (`init(historyName:icon:)`, `begin`, `setPhase`, `update`, `rerender`, `commit`, `cancel`, `touchedTiles`; commit = one `TileDiffHistoryItem`, empty diff → no step; cancel restores `before` bit-for-bit), `ToolOverlay.shapeHandles(ShapeHandlesOverlayModel)`, `Canvas/ShapeHandlesOverlay.swift`, `LineCurveTool` (state-machine precedent; mirror it).

Paint.NET behavior being mirrored (ShapeTools.html, quoted or paraphrased):
- Shapes are chosen from a Tool Bar drop-down; "Pressing A cycles forward through shapes and Shift + A cycles backward". Paint.NET 5's list is grouped: **Basic** — Rectangle, Rounded Rectangle, Ellipse, Diamond, Trapezoid, Parallelogram, Triangle, Right Angle Triangle; Polygons & Stars; Arrows; Callouts; Symbols. This spec ships the **Basic** group (Open question 1); the other groups are T-20 / 0058.
- **Draw mode**: "Shape Outline", "Filled Shape", or "Filled Shape with Outline".
- **Colors**: Outline or Filled Shape — left button uses the Primary color, right button the Secondary color. Filled Shape with Outline — "Left button fills with Secondary and outlines with Primary. Right button reverses this."
- **Brush Size** sets the outline width and accepts decimals; **Corner Size** applies only to Rounded Rectangle (corner radius); **Line Styles** solid or dashes/dots; **Antialiasing**; **Blend Mode**. (Fill Styles patterns and Selection Quality are not in v1.0 — Out of scope.)
- **Shift** while creating or resizing keeps the proportions; while rotating snaps to 15°. **Alt** resizes about the center (⌥ here, PRD §5.12). **Ctrl + arrow** moves 10 px (⌘ here).
- **Control nubs** on the bounding box resize from the opposite nub; dragging past the opposite nub flips the shape. **Move** by dragging inside the shape or with arrow keys. **Rotate** by right-dragging, or by left-dragging just outside the shape (curved-arrow cursor).
- A new shape "stays in Edit mode", where it can still be resized, rotated, and changed in fill, antialiasing, and blend mode. Commit: "Pressing Enter", "Clicking outside the shape's bounding box", "Clicking Finish in the Tool Bar", "Drawing a new shape".
- Not mirrored in v1.0 (Open question 3): the movable Rotation Point (rotation is always about the frame center, as 0019), the pulsing move icon, live recoloring while editing (colors are captured at creation, as 0023/0038), arrow-key rotation with the right button held.

## User story

As a PaintDotMac user annotating a screenshot, I press **O** twice (or Shift+O) to get Shapes, pick Rectangle (or another Basic shape; **A** cycles them), choose "Shape Outline", a brush width of 8 and red as my primary color, and drag around the area I want to highlight. A crisp red rectangle appears with eight nubs; I drag a nub to resize it (Shift keeps the proportions, ⌥ resizes about the center), drag inside to move it, right-drag to rotate it (Shift snaps to 15°), nudge it with the arrow keys, and change the draw mode, width, dash style, corner size, antialiasing, or blend mode while it is still editable. Return, Finish, switching tools, or clicking away commits it as one "Shapes" history step that ⌘Z undoes; Escape discards it. The shape never paints outside the selection.

## Scope & changes

### Core (headless, unit-tested)

- **`PaintDotMac/Core/Tools/Shapes/ShapeCatalog.swift`** (new, pure):
  ```swift
  enum ShapeCatalogGroup: String, CaseIterable, Sendable { case basic }   // 0058 adds polygonsAndStars, arrows, callouts, symbols
  enum ShapeKind: String, CaseIterable, Sendable, ToolOptionValue {
      case rectangle, roundedRectangle, ellipse, diamond, trapezoid, parallelogram, triangle, rightTriangle
      var displayName: String   // "Rectangle", "Rounded Rectangle", "Ellipse", "Diamond", "Trapezoid",
                                // "Parallelogram", "Triangle", "Right Angle Triangle" (Paint.NET 5 spelling)
      var group: ShapeCatalogGroup        // all .basic
      var usesCornerRadius: Bool          // true only for .roundedRectangle
  }
  enum ShapeCatalog {
      static let defaultCornerRadius: Double = 20
      static let cornerRadiusRange: ClosedRange<Double> = 0...1000
      /// Picker order = ShapeKind.allCases. A / Shift+A step through it, wrapping.
      static func next(after kind: ShapeKind, backward: Bool) -> ShapeKind
      /// Vertices in the unit square (u, v ∈ [0, 1], v down) for polygon kinds, in this exact order; nil for
      /// rectangle, roundedRectangle, ellipse (built from CGRect primitives).
      static func unitPolygon(for kind: ShapeKind) -> [CGPoint]?
      /// The closed shape outline in *local* box coordinates (before `rigid`); nil when the box is
      /// non-finite or |width| < 1e-9 or |height| < 1e-9.
      static func localPath(for kind: ShapeKind, in box: TransformBox, cornerRadius: Double) -> CGPath?
  }
  ```
  - Unit polygons (map `x = box.minX + u·(box.maxX − box.minX)`, `y = box.minY + v·(box.maxY − box.minY)`, so a flipped box mirrors the shape): diamond `(0.5,0) (1,0.5) (0.5,1) (0,0.5)`; trapezoid `(0.25,0) (0.75,0) (1,1) (0,1)`; parallelogram `(0.25,0) (1,0) (0.75,1) (0,1)`; triangle (isosceles, apex up) `(0.5,0) (1,1) (0,1)`; right angle triangle (right angle bottom-left) `(0,0) (1,1) (0,1)`. Each is `move` + `addLine`s + `closeSubpath`.
  - Rectangle: `addRect(r)`; ellipse: `addEllipse(in: r)`; rounded rectangle: `CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil)` with `c = clamp(cornerRadius, 0, min(r.width, r.height) / 2)` (CoreGraphics traps when `2c` exceeds a side, so the clamp is mandatory; non-finite radius → `defaultCornerRadius`, then clamped); `c == 0` → `addRect(r)`. Here `r` = the box standardized (min ≤ max); these three are symmetric, so a flip does not change them.
  - The catalog is data + path builders only; adding a kind (0058) means adding a case, its name, its group, and its unit polygon or builder.

- **`PaintDotMac/Core/Tools/Shapes/ShapePaintPlan.swift`** (new, pure) — turns a shape outline + draw mode into 0038 `ShapePaint`s:
  ```swift
  enum ShapeDrawMode: String, CaseIterable, Sendable, ToolOptionValue {
      case outline, fill, outlineAndFill
      var displayName: String   // "Shape Outline", "Filled Shape", "Filled Shape with Outline"
      var drawsOutline: Bool    // outline, outlineAndFill
      var drawsFill: Bool       // fill, outlineAndFill
  }
  enum ShapePaintPlan {
      /// The outline band: the part of the shape within `width` of its edge (the outline lies *inside* the shape's bounds).
      /// = shape.intersection(dashed(shape).copy(strokingWithWidth: 2·width, lineCap: .butt, lineJoin: .miter, miterLimit: 10), using: .winding)
      /// where dashed(shape) = shape for .solid, else shape.copy(dashingWithPhase: 0, lengths: unitPattern × width).
      static func outlineBand(of shape: CGPath, width: Double, dashStyle: DashStyle) -> CGPath
      /// The interior inset by width/2 (the outline's centerline):
      /// = shape.subtracting(shape.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .miter, miterLimit: 10), using: .winding)
      static func insetFill(of shape: CGPath, width: Double) -> CGPath
      /// outline        → [band(color)]
      /// fill           → [shape(color)]
      /// outlineAndFill → [insetFill(otherColor), band(color)]   (fill first, outline on top)
      static func paints(shape: CGPath, mode: ShapeDrawMode, stroke: ShapeStrokeStyle,
                         color: ColorRGBA8, otherColor: ColorRGBA8) -> [ShapePaint]
  }
  ```
  - All `ShapePaint.fillRule` = `.winding`. `stroke.startCap`/`endCap` are ignored (closed shapes have no ends). `stroke` is `clamped()` first.
  - **Why inside + inset** (Open question 2): the dragged box is the shape's outer edge, so with pixel-snapped corners (see `ShapesGeometry`) an unrotated rectangle's outline is pixel-exact at every integer width, antialiased or not — this is what a "highlight rectangle" needs. In Filled Shape with Outline the fill stops at the outline's centerline, which lies under fully covered outline pixels, so no fill color fringes outside the outline. CGPath boolean operations (`intersection`/`subtracting`, macOS 13+) are in CoreGraphics (D-19).
  - A width ≥ half the shape's smaller side makes the band equal the whole shape and the inset fill empty; both are valid (no crash).

- **`PaintDotMac/Core/Tools/ShapesTool.swift`** (new):
  - **Geometry** `struct ShapesGeometry: EditableShapeGeometry`:
    ```swift
    struct ShapesGeometry: EditableShapeGeometry {
        var session: TransformSession?          // nil while the creation drag has no area
        /// Creation rectangle from the (already snapped) mouse-down point to the (snapped) current point.
        static func creating(from down: CGPoint, to current: CGPoint, modifiers: ToolModifiers) -> ShapesGeometry
        /// Integer snapping of a pointer location (round half away from zero) — always while creating, and for
        /// edits while `session.angle == 0`; unchanged when rotated.
        static func snapped(_ p: CGPoint, rotated: Bool) -> CGPoint
        /// Canvas-space outline: ShapeCatalog.localPath(kind, session.box, radius) transformed by session.rigid.
        func path(kind: ShapeKind, cornerRadius: Double) -> CGPath?
    }
    ```
    - `creating`: `d = current − down`. Shift → `s = max(|dx|, |dy|)`, `dx = sign(dx)·s`, `dy = sign(dy)·s` (sign(0) = +1) — a square/circle. ⌥ → rect spans `down − d … down + d` (about the mouse-down point); else `down … down + d`. Standardized; `session = TransformSession(sourceBounds: rect)` (nil for zero width or height).
    - `handles`: when `session != nil`, the 8 `TransformHandle.allCases` positions `session.canvasPosition(of:)`, in that order, kind `.corner` for corners, `.edge` for edge midpoints; else `[]`. Handle index `i` ⇔ `TransformHandle.allCases[i]`.
    - `guides`: the 4 frame edges between consecutive `session.canvasCorners` (TL→TR→BR→BL→TL); `[]` without a session.
    - `isDegenerate`: `session == nil`, any non-finite value, or `|box.maxX − box.minX| < 1e-9` or `|box.maxY − box.minY| < 1e-9` (squashed flat by a nub).
    - `moveHandle(i, to: p, constrained:)`: `session = session.applying(.scale(allCases[i]), from: session.canvasPosition(of: allCases[i]), to: p, modifiers: constrained ? [.shift] : [])`.
    - `translate(by: v)`: `session = session.translatedBy(dx: Int(v.dx.rounded(.toNearestOrAwayFromZero)), dy: …)`.
    - `bodyHit(atView:transform:tolerance:)`: `0` when the view point is inside the view-mapped frame quad (even-odd point-in-polygon on `session.canvasCorners` mapped with `transform.canvasToViewAffine`; `tolerance` unused), else `nil`.
    - `dragBody(from original, parameter _, delta)`: `self = original` translated by `TransformHandles.translation(from: .zero, to: CGPoint(delta))`.
  - **Options** (TOOL-C): `struct ShapesOptions: Equatable, Sendable { var kind: ShapeKind; var drawMode: ShapeDrawMode; var stroke: ShapeStrokeStyle; var cornerRadius: Double; var antialiasing: Bool; var blendMode: BlendMode; static let `default` = ShapesOptions(kind: .rectangle, drawMode: .outline, stroke: .default, cornerRadius: 20, antialiasing: true, blendMode: .normal); @MainActor static func load(from: any ToolOptionStore) -> ShapesOptions; @MainActor func save(to: any ToolOptionStore) }`. Keys: `tool.shapes.shapeType` (raw String, `rectangle`), `tool.shapes.drawMode` (raw, `outline`), `tool.shapes.width` (Double, 2, range `BrushOptions.widthRange`), `tool.shapes.dashStyle` (raw, `solid`), `tool.shapes.cornerRadius` (Double, 20, range `ShapeCatalog.cornerRadiusRange`), `tool.shapes.antialiasing` (Bool, true), `tool.shapes.blendMode` (raw, `normal`). Missing/unknown → defaults; numeric values clamped on load; non-finite → default. Caps are not stored (`stroke.startCap`/`endCap` stay `.flat`).
  - **Render closure** (`EditableShapeEditor.Renderer`): read `ShapesOptions.load(from: context.options)` at every render (so every option is live, including the shape type); `guard let path = g.path(kind: o.kind, cornerRadius: o.cornerRadius) else { return nil }`; `ShapeRenderParameters(paints: ShapePaintPlan.paints(shape: path, mode: o.drawMode, stroke: o.stroke, color: capture.color, otherColor: capture.secondaryColor), antialiasing: o.antialiasing, blendMode: o.blendMode)`. So: Outline/Filled with the left button use the primary color, with the right button the secondary; Filled Shape with Outline left = primary outline + secondary fill, right = the reverse (Paint.NET).
  - **`ShapeEditPhase`** (extend 0038's enum in `Core/Tools/Shapes/EditableShape.swift`): add `case rotating` (a rotation drag; overlay `activeHandle == nil`; `hasPendingEdit` true because `phase != .idle`).
  - **`ShapeHandleKind`** (extend 0038's enum, same file): add `case corner, edge`.
  - **Changes to 0038's code** (required so the new cases compile; 0038 allows exhaustive switches and leaves these branches to this spec). `LineCurveTool` never enters `.rotating` and never creates `.corner`/`.edge` handles, so every added branch is unreachable there and behaves as stated:
    - `LineCurveTool.mouseDragged` and `mouseUp`: `case .rotating:` → same as `.editing` (nothing to apply; `mouseUp` leaves the phase unchanged).
    - `LineCurveTool.commit` / `cancel` ("apply the last pointer location first" for drawing/dragging phases): `.rotating` applies nothing, then the editor's commit/cancel, as `.editing`.
    - `LineCurveTool.keyDown` "not mid-gesture" test: `.rotating` counts as mid-gesture (arrow keys → `false`), like `.draggingHandle`/`.draggingBody`.
    - `LineCurveTool` cursor: `.rotating` → `.closedHand`, like the other drag phases.
    - `EditableShapeEditor.update` overlay: `activeHandle` stays "index while `draggingHandle`, else nil", so `.rotating` → nil (no code change if written with `if case`).
    - `ShapeHandlesOverlay.draw` switch on `ShapeHandleKind`: add `.corner`/`.edge` (drawing below, Platform glue).
    No 0038 behavior changes; 0038's test suite runs unchanged (acceptance criterion "Line / Curve keeps working").
  - **State machine** (`final class ShapesTool: Tool, BrushWidthAdjustable`, `id = .shapes`; owns `EditableShapeEditor<ShapesGeometry>(historyName: "Shapes", icon: .shapes)`; private `drag: (gesture: TransformGesture?, start: CGPoint, sessionAtStart: TransformSession?, lastLocation: CGPoint)?` where `gesture == nil` means the creation drag):
    - `hasPendingEdit` = editor's.
    - **`mouseDown`, idle** (either button): ignore non-finite locations; `down = snapped(location, rotated: false)`; `editor.begin(ShapesGeometry(session: nil), button: event.button, context:)` (false → stay idle); phase `drawing`; nothing is drawn yet.
    - **`mouseDown`, editing** (`session != nil`): `gesture = TransformHandles.hitTest(viewPoint: event.viewLocation, session:, canvasToView: context.transform.canvasToViewAffine, button: event.button)`. If `event.button == .primary`, `gesture == .translate`, and `bodyHit == nil` (outside the frame and outside the 20 pt corridor) → `commit` ("Clicking outside the shape's bounding box"), then start a new shape exactly as in idle with this event ("Draw a new shape"). Otherwise store the drag with `sessionAtStart = session` and set the phase: `.scale(h)` → `draggingHandle(index of h)`, `.translate` → `draggingBody(parameter: 0, grab: location)`, `.rotate` → `rotating`. (So while a shape is pending, the right button always rotates, as in Paint.NET.)
    - **`mouseDragged`**: `p` = the location snapped with `ShapesGeometry.snapped(_:rotated: false)` for the creation drag (always) and for `.translate`/`.scale` drags while `sessionAtStart.angle == 0`; the raw location for `.rotate` drags and for any drag on a rotated shape; creation → `ShapesGeometry.creating(from: down, to: p, modifiers:)`; else `session = sessionAtStart.applying(gesture, from: drag.start, to: p, modifiers: event.modifiers)` (`drag.start` is the snapped mouse-down location by the same rule). `editor.update(...)`. Remember `lastLocation`.
    - **`flagsChanged`** mid-drag: re-apply `lastLocation` with the new modifiers (Shift/⌥ act live, as 0019), then `invalidateCursor()`.
    - **`mouseUp`**: apply once more; creation with a degenerate result (click, or a drag that rounds to zero width or height) → `cancel` (no step, idle); otherwise → `editing`.
    - **`keyDown`** (not mid-gesture): arrow keys while pending → `TransformHandles.nudge(for:)` → `translate`, re-render, `true`. `.character("a")` (idle or pending) → consumed only when `ToolShortcutGate.allows(modifiers: event.modifiers, keyWindow: .document, textInputHasFocus: false, toolCapturesKeyboard: capturesKeyboard /* false */, gestureInProgress: phase is .drawing/.draggingHandle/.draggingBody/.rotating)` is true — the same gate every single-key shortcut uses (0006, AGENTS.md rule 9). `keyWindow: .document` and `textInputHasFocus: false` are true by construction: tool `keyDown` is only reached from 0006's `CanvasInputRouter` `keyDown` with the `CanvasView` as first responder of the document window. If the gate allows it: `event.isRepeat` → consumed and ignored (`true`, as 0006 treats repeated tool keys); else `kind = ShapeCatalog.next(after: kind, backward: event.modifiers.contains(.shift))`, saved to `tool.shapes.shapeType`, `optionsDidChange` path (re-render if pending), `true`. Gate false (⌘A = Select All, ⌥/⌃, mid-gesture) or any other key → 0006's default (Return/Enter commit, Escape cancel, else `false`). Arrow keys while idle → `false`. `a` is not in `ToolRegistry.allShortcutKeys` and not an X/D/C (0007), `[`/`]` (0009), or ⌫ (0018) key, so 0006's local monitor (`CanvasInputRouter.handleShortcutKeyDown`) returns `false` and the event reaches the canvas; pinned by `ToolDispatcherTests.aIsNotAGlobalShortcut`.
    - **`commit` / `cancel`**: in `drawing`/dragging/rotating phases apply `lastLocation` first, then the editor's commit/cancel. Callers as 0038: Return/Enter, Finish, tool switch (`deactivate` default) and document switch, `prepareForHistoryNavigation` default before undo/redo/jump/save, `PendingEditReason.command`, click outside.
    - **`optionsDidChange`** while pending → `editor.rerender` (shape type, draw mode, width, dash, corner size, antialiasing, blend mode are live). **`adjustBrushWidth(by:context:)`** (`[`/`]`): width clamped to 1…2000, persisted, re-render a pending shape.
    - **Cursor** (`cursor(at:modifiers:)`): `location == nil` → `.arrow`; during a drag → creation `.crosshair`, `.translate` `.move`, `.rotate` `.rotate`, `.scale(h)` `.resize(h)`; hovering a pending shape (from `mouseMoved`, `invalidateCursor()` on change) → the `hitTest` gesture's cursor, except "outside" (as defined in mouseDown) → `.crosshair`; idle → `.crosshair`.
    - **`deactivate`**: default (commit) then `setOverlay(nil)`.
  - **`Core/Tools/ToolRegistry.swift`** (modify): register `.shapes → ShapesTool()` in `standard()`. The O group becomes `[.lineCurve, .shapes]`: O selects Line / Curve, O again within 1 s cycles to Shapes, Shift+O selects Shapes (D-41).

### Platform glue (AppKit/SwiftUI; UI tests and manual checks)

- **`PaintDotMac/Canvas/ShapeHandlesOverlay.swift`** (extend 0038): `.corner` → 8 pt circle, `.edge` → 7 pt square (0019's `TransformHandles.handleSize`), white fill, 1 pt black stroke; guides (the frame) use 0038's dashed black-over-white style. Constant size in view points at every zoom/backing scale; points mapped with `transform.canvasToViewAffine`.
- **`UI/ToolOptionsBar.swift`** (extend `ToolOptionsContent`): case `.shapes`, left to right:
  - **Shape type** popup `toolOptions.shapeType` (`ShapeKind.allCases`, label `displayName`, each with a small preview drawn from `ShapeCatalog.localPath` in a 16×16 box).
  - **Draw mode** popup `toolOptions.drawMode` ("Shape Outline", "Filled Shape", "Filled Shape with Outline").
  - **Brush width** field + −/+ (`toolOptions.width`, `.width.decrease`, `.width.increase`) and **Dash style** popup `toolOptions.dashStyle` (0038's items) — both disabled in "Filled Shape" (no outline is drawn).
  - **Corner size** field `toolOptions.cornerRadius` (0…1000 px, decimals allowed) — enabled only when the shape type is Rounded Rectangle.
  - **Antialiasing** toggle `toolOptions.antialiasing`; **Blend mode** popup `toolOptions.blendMode` (implemented `BlendMode` cases, 0009 pattern).
  - Finish (`toolOptions.finish`) visible (descriptor `supportsPendingEdits: true`), enabled while a shape is pending.
  - Changes save through `ShapesOptions.save` and call `optionsDidChange` (live re-render).
- **Tools panel**: `tool.shapes` appears automatically (implemented tools only).
- `project.yml`: no change beyond new files; run `xcodegen generate`.
- **No PRD edit in this spec** (sub-agent rule). Open questions 1–6 record decisions to be added next to T-19 in PRD §5.3 / §12 once confirmed.

## Acceptance criteria

- [ ] O, O (within 1 s) or Shift+O selects Shapes; the options bar shows Shape type "Rectangle", Draw mode "Shape Outline", Brush width 2, Dash style "Solid", Corner size disabled, Antialiasing on, Blend mode "Normal", and a disabled Finish button. → `ShapesUITests.shiftOSelectsShapesAndShowsOptions`, `ShapesToolTests.defaultsAndRegistration`
- [ ] The picker offers exactly Rectangle, Rounded Rectangle, Ellipse, Diamond, Trapezoid, Parallelogram, Triangle, Right Angle Triangle, in that order; A / Shift+A cycle them (tool-local, through 0006's `ToolShortcutGate`). → `ShapeCatalogTests.kindsAndNames`, `.nextWraps`, `ShapesToolTests.aKeyCyclesShapes`, `ToolDispatcherTests.aIsNotAGlobalShortcut`, `ShapesUITests.shiftOSelectsShapesAndShowsOptions`
- [ ] Each shape's coverage matches the hand-computed values: rectangle edges at odd and even widths, antialiased and aliased; ellipse symmetry and area; rounded corners; polygon areas. → `ShapeCoverageTests.*`
- [ ] Outline uses the gesture's color; Filled Shape uses it for the fill; Filled Shape with Outline outlines in the primary and fills in the secondary (right button reversed). → `ShapesToolTests.fillModeUsesButtonColor`, `.outlineAndFillColors`, `.secondaryDragUsesSecondaryColor`, `ShapePaintPlanTests.*`
- [ ] Shift draws a square/circle, ⌥ draws from the center; corner points snap to whole pixels. → `ShapesGeometryTests.creating*`, `ShapesToolTests.drawRectangleOutline`
- [ ] Until committed, the shape can be resized with 8 nubs (Shift keeps proportions, ⌥ about the center, past the opposite nub flips), moved by dragging inside or with arrow keys (⌘: 10 px), and rotated by right-drag or the corridor (Shift: 15°), always re-rendered from the original pixels. → `ShapesToolTests.cornerHandleResizes`, `.shiftCornerKeepsProportions`, `.optionScalesAboutCenter`, `.dragPastOppositeFlips`, `.translateByDragInside`, `.arrowKeysNudge`, `.rightDragRotates90`, `.corridorLeftDragRotates`, `.shiftRotateSnaps`
- [ ] Changing any option (shape type, draw mode, width, dash, corner size, antialiasing, blend mode) or `[`/`]` while pending re-renders live. → `ShapesToolTests.optionChangeRerendersPending`, `.bracketKeysResizePending`
- [ ] Return, Finish, tool switch, and clicking outside commit exactly one "Shapes" step (icon `shapes`); Escape restores the layer with no step; a click without drag adds nothing. → `ShapesToolTests.returnCommits`, `.deactivateCommits`, `.clickOutsideCommitsAndStartsNew`, `.escapeCancels`, `.clickWithoutDragAddsNoStep`; `ShapesUITests.drawHighlightRectangleSavePNG`, `.escapeDiscards`
- [ ] The shape is confined to the selection. → `ShapesToolTests.respectsClipHook`, `ShapesIntegrationTests.selectionClipsShape`, `ShapesUITests.filledShapeClippedToSelection`
- [ ] Undo/redo restore exact before/after tiles; undo while editing first commits. → `ShapesIntegrationTests.undoRedoRoundTrip`, `.undoWhileEditingCommitsFirst`
- [ ] Options persist under `tool.shapes.*`. → `ShapesToolTests.optionsRoundTripThroughStore`, `ShapesUITests.optionsPersistAcrossRelaunch`
- [ ] Line / Curve (0038) keeps working unchanged. → existing `LineCurveToolTests.*`, `LineCurveUITests.*` stay green
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Click without drag**, or a drag that rounds to zero width or height (e.g. (50,60) → (150,60.3)) → no shape, no step, idle. → `ShapesToolTests.clickWithoutDragAddsNoStep`, `.zeroHeightDragDrawsNothing`
- **Squashed flat by a nub** while pending → renders nothing (layer shows `before`), still pending; dragging on past it flips and draws again; committing while flat = cancel (no step). → `ShapesToolTests.squashFlatThenCommitAddsNoStep`
- **Outline wider than half the shape** → the band fills the whole shape; Filled Shape with Outline shows only the outline color. → `ShapeCoverageTests.wideOutlineFillsShape`, `ShapePaintPlanTests.insetFillEmptyWhenWide`
- **Corner size larger than half the shorter side** → clamped (a rounded square becomes a circle); 0 → a plain rectangle; non-finite → 20. → `ShapeCoverageTests.roundedRadiusClamps`, `.roundedRadiusZeroIsRectangle`, `ShapeCatalogTests.nonFiniteRadius`
- **Dash style in Filled Shape** → ignored (no outline). → `ShapePaintPlanTests.fillIgnoresDash`
- **Flipped box** (nub dragged past its opposite) → asymmetric shapes (triangles, trapezoid, parallelogram) mirror. → `ShapeCoverageTests.flippedTriangle`, `ShapesToolTests.dragPastOppositeFlips`
- **Rotated shapes**: pointer locations are no longer snapped; aliased rendering uses CG pixel-center sampling. → `ShapesToolTests.rightDragRotates90`
- **Off-canvas parts** and shapes entirely off the canvas → only canvas tiles are visited; fully off-canvas commits no step (empty diff). → `ShapesIntegrationTests.offCanvasShapeAddsNoStep`
- **Non-finite events** → ignored on mouseDown; non-finite geometry is degenerate. → `ShapesGeometryTests.nonFiniteIsDegenerate`
- **Huge shapes** (4000×3000 ellipse, width 2000) → per-tile coverage (0038), memory independent of canvas size. → `ShapeCoverageTests.hugeShapeCompletes`
- **Tile boundaries**: a rectangle crossing x = 256 has a continuous outline. → `ShapeCoverageTests.continuousAcrossTileBoundary`
- **Color alpha 0** or clip coverage 0 everywhere → no change, no step. → `ShapesIntegrationTests.noOpAddsNoStep`
- **Right button while pending** → rotates (never starts a secondary-color shape); finish first to draw with the secondary color. → `ShapesToolTests.rightDragRotates90`
- **⌘A while pending** → not consumed by the tool (Select All commits first through `PendingEditReason.command`). → `ShapesToolTests.aKeyCyclesShapes`
- **Active layer deleted while pending** → next render/commit cancels without history (0038 editor). **Hidden active layer** → still writes it. **Undo/redo/save/commands while pending** → commit first. **Arrow keys or A mid-drag** → ignored (`false`). **1×1 canvas** → draws without crash.

## Test plan

Expected values are hand-computed. `W = (255,255,255,255)`, `P = (0,0,0,255)`, `R = (255,0,0,255)`, `B = (0,0,255,255)`. Coverage tests call `ShapeRasterizer.coverage(of: paint.path, fillRule: .winding, antialiasing:, in: region)` on the paths from `ShapePaintPlan.paints(...)` for a `ShapesGeometry.creating(...)` geometry (unrotated unless stated). "≈128" means 126…129 and "≈191" 189…193 (CoreGraphics area coverage; the only tolerance used, as in 0038). The reference box is `(10,10)–(50,30)` (pixels x 10…49, y 10…29) in region `(0,0,64,48)`.

- **Unit — `PaintDotMacTests/Tools/Shapes/ShapeCoverageTests.swift`:**
  - `rectangleOutlineWidth2`: AA on and off: columns 10, 11, 48, 49 for rows 10…29 = 255; rows 10, 11, 28, 29 for columns 10…49 = 255; (12,15), (47,15), (30,12), (30,27) = 0; outside the box (9,15), (50,15), (30,9), (30,30) = 0; covered pixel count = 2·(40·2) + 2·(16·2) = 224.
  - `rectangleOutlineWidth1Odd`: columns 10 and 49, rows 10 and 29 = 255; (11,15) = 0; count 116; AA and aliased identical.
  - `rectangleOutlineWidth3Odd`: columns 10…12 and 47…49, rows 10…12 and 27…29 = 255; (13,15) = 0; count 2·(40·3) + 2·(14·3) = 324.
  - `rectangleFill`: 10…49 × 10…29 = 255 (800 pixels), every other pixel 0, AA and aliased.
  - `aliasedIsBinary`: every coverage value of every Basic shape (fill and outline, width 2, box (0,0)–(64,64)) with antialiasing off is 0 or 255.
  - `fractionalEdgeAntialiased`: fill, box built directly as `TransformSession(sourceBounds: (10.25,10,39.75,20))` → column 10 ≈191, column 11 = 255; with minX 10.5 → column 10 ≈128; aliased with minX 10.25 → column 10 = 255, with 10.75 → 0.
  - `wideOutlineFillsShape`: box (10,10)–(20,20), width 6 → all 100 pixels 255, others 0 (outline band == shape).
  - `ellipseFillSymmetry` (box (0,0)–(64,64), region (0,0,64,64), AA): for all x,y: |c(x,y) − c(63−x,y)| ≤ 2, |c(x,y) − c(x,63−y)| ≤ 2, |c(x,y) − c(y,x)| ≤ 2.
  - `ellipseFillAreaAndPoints`: Σc/255 within 0.5% of 1024π = 3216.99; c(32,32) = 255; c(32,1) = 255 (farthest corner (33,1) is 31.02 from the center); c(1,32) = 255; c(4,4) = 0 (nearest corner (5,5) is 38.2 away); aliased: count of 255s within 1% of 3216.99 and at most 4 pixels break the left/right mirror symmetry.
  - `ellipseOutlineBand`: width 4, AA: Σc/255 within 1.5% of π(32² − 28²) = 753.98; c(32,32) = 0; c(32,1) = 255; c(32,5) = 0 (pixel spans radii 26…27 < 28).
  - `roundedRectangleCorners` (box (0,0)–(64,64), radius 16, fill, AA): c(0,0) = 0; c(16,0) = 255; c(0,16) = 255; c(4,4) in 1…254; c(6,6) = 255; c(63,63) = 0; c(59,59) in 1…254; Σc/255 within 0.5% of 4096 − (4 − π)·256 = 3876.25.
  - `roundedRadiusZeroIsRectangle`: radius 0 → coverage identical to `.rectangle` (byte-equal). `roundedRadiusClamps`: radius 1000 → each pixel within ±2 of the ellipse fill coverage of the same box.
  - `polygonAreas` (box (0,0)–(64,64), fill, AA, Σc/255 within 0.5%): diamond 2048, triangle 2048, right angle triangle 2048, trapezoid 3072, parallelogram 3072. Points: triangle c(32,60) = 255, c(2,2) = 0, c(61,2) = 0; right angle triangle c(2,60) = 255, c(60,2) = 0; diamond c(32,32) = 255, c(2,2) = 0, c(61,61) = 0; parallelogram c(2,2) = 0, c(61,61) = 0, c(32,32) = 255; trapezoid c(2,2) = 0, c(2,62) = 255.
  - `flippedTriangle`: box (0,0)–(64,64), `moveHandle(1 /* top */, to: (32,128), constrained: false)` → box minY 128, maxY 64; region (0,0,64,140), fill, AA: c(32,125) = 255 (width 3 at y 125), c(2,126) = 0, c(32,66) = 255, c(2,66) = 255 (width 62 at y 66 spans 1…63), c(32,20) = 0.
  - `continuousAcrossTileBoundary`: 512×64 W surface, outline width 2, box (100,10)–(400,50), rendered with `ShapeRasterizer.render` → rows 10/11 for every x in 100…399 = P (straddles tile column 1).
  - `hugeShapeCompletes`: 4000×3000 W, ellipse box (0,0)–(4000,3000), Filled Shape with Outline width 2000, color P, otherColor B → completes; width 2000 ≥ half of 3000, so the band covers the whole ellipse: (2000,1500) = P and (2000,10) = P; (0,0) = W; no pixel equals B.
  - `renderIsPureFunctionOfBefore` (property, 200 seeded random kind/mode/width/dash/box pairs on 300×300 random images, seed printed): render A then B == render B from before.
  - `integerTranslationShiftsCoverage` (property, 100 seeds): translating a geometry by integer (dx,dy) shifts coverage exactly (±1 per pixel).
- **Unit — `PaintDotMacTests/Tools/Shapes/ShapePaintPlanTests.swift`:**
  - `paintOrderAndColors`: outline → 1 paint, color = `color`; fill → 1 paint with the full shape, color = `color`; outlineAndFill → 2 paints, `[0]` = inset fill in `otherColor`, `[1]` = band in `color`.
  - `outlineAndFillPixels` (tool-independent, `ShapeRasterizer.render` over W, box (10,10)–(50,30), width 2, color R, otherColor B): (10,20), (11,20), (30,10), (30,11), (49,20) = R; (12,20), (30,12), (30,20), (47,20) = B; (9,20), (30,30) = W.
  - `insetFillEmptyWhenWide`: box 10×10, width 6 → `insetFill` has empty bounding box; outlineAndFill pixels all = `color`.
  - `dashedRectangleTopEdge`: box (10,10)–(50,30), width 2, Dash (pattern [6, 2] px starting at (10,10) going +x, CGPath rect order): rows 10 and 11: x 10…15 = 255, 16…17 = 0, 18…23 = 255, 24…25 = 0; (12,12) = 0.
  - `fillIgnoresDash`: fill mode with `.dashDot` == fill mode with `.solid` (byte-equal coverage).
  - `capsIgnored`: stroke with `startCap: .filledArrow, endCap: .rounded` == `.flat` (byte-equal).
- **Unit — `PaintDotMacTests/Tools/Shapes/ShapeCatalogTests.swift`:**
  - `kindsAndNames`: `allCases` order and display names exactly as listed; all `group == .basic`; `usesCornerRadius` only for `.roundedRectangle`; raw values stable (`"rectangle"`, …, `"rightTriangle"`).
  - `nextWraps`: next(after: .rectangle) = .roundedRectangle; next(after: .rightTriangle) = .rectangle; backward from .rectangle = .rightTriangle.
  - `unitPolygons`: exact vertex lists above; nil for rectangle, roundedRectangle, ellipse.
  - `localPathNilForDegenerate`: zero width, zero height, NaN box → nil.
  - `nonFiniteRadius`: radius NaN on box (0,0)–(64,64) → path equal (bounding box and coverage) to radius 20.
  - `drawModeNames`: "Shape Outline", "Filled Shape", "Filled Shape with Outline"; `drawsOutline`/`drawsFill` per case.
- **Unit — `PaintDotMacTests/Tools/Shapes/ShapesGeometryTests.swift`:**
  - `snapping`: `snapped((10.5, 9.49), rotated: false) == (11, 9)`; `(-0.5, 2.5)` → `(-1, 3)`; rotated → unchanged.
  - `creatingPlain`: (50,60)→(150,120) → box (50,60)–(150,120); dragging up-left (150,120)→(50,60) gives the same standardized box.
  - `creatingShiftSquare`: (50,50)→(150,80) Shift → (50,50)–(150,150); (50,50)→(20,70) Shift → s = 30, dx = −30, dy = +30 → (20,50)–(50,80).
  - `creatingOptionFromCenter`: (100,100)→(130,120) ⌥ → (70,80)–(130,120); Shift+⌥ → (70,70)–(130,130).
  - `creatingZeroIsNil`: (50,60)→(150,60) → `session == nil`, `isDegenerate`.
  - `handlesOrderAndKinds`: box (50,60)–(150,120) → positions (50,60), (100,60), (150,60), (150,90), (150,120), (100,120), (50,120), (50,90); kinds corner, edge, corner, edge, …; 4 guides TL→TR, TR→BR, BR→BL, BL→TL.
  - `moveHandleUsesSessionScale`: moveHandle(4 /* bottomRight */, to: (200,150)) → box (50,60)–(200,150); constrained with (250,130) → proportions of R0 kept: sx 2, sy 70/60 → s = 7/6 → box (50,60)–(166.666…,130) within 1e-9.
  - `translateRounds`: translate(by: (10.4, −2.6)) → box shifted by (10, −3).
  - `dragBodyFromOriginal`: dragBody(from: g, parameter: 0, delta: (5.5, 0)) twice from the same original → shifted by (6, 0) once, not twice.
  - `bodyHitInsideQuad`: 100% backing 1 transform: center → 0; 3 pt outside the right edge → nil.
  - `nonFiniteIsDegenerate`; `pathAppliesRigid`: after rotating the session by 90° about its center (via `applying(.rotate, …)`), `path(kind: .rectangle, …)`'s bounding box ≈ (70,40)–(130,140) for box (50,60)–(150,120) within 1e-6.
- **Unit — `PaintDotMacTests/Tools/ShapesToolTests.swift`** (`FakeToolContext`, 300×300 W `DocumentState`, `InMemoryToolOptionStore`, default colors, transform 100% backing 1 so view ↔ canvas is a known flip; "draw" = down (50.4,60.2), drag (149.6,120.4), up → box (50,60)–(150,120)):
  - `defaultsAndRegistration`: empty store → `ShapesOptions.default` (rectangle, outline, width 2, solid, radius 20, AA on, normal); `ToolRegistry.standard().isImplemented(.shapes)`; `shortcutGroup(for: "o") == [.lineCurve, .shapes]`; `ToolShortcutResolver` with Shift+O (no prior press) → `.shapes`.
  - `optionsRoundTripThroughStore`: save ellipse, outlineAndFill, width 7.5, dot, radius 12.5, AA off → `tool.shapes.shapeType == "ellipse"`, `.drawMode == "outlineAndFill"`, `.width == 7.5`, `.dashStyle == "dot"`, `.cornerRadius == 12.5`, `.antialiasing == false`, `.blendMode == "normal"`; reloaded equal; unknown `"hexagon"` → `.rectangle`; cornerRadius 5000 → 1000; `BrushOptions`/`LineCurveOptions` defaults unaffected (independent prefixes).
  - `drawRectangleOutline`: draw → overlay `.shapeHandles` with the 8 handles of `handlesOrderAndKinds` and 4 guides; pending; no `commitHistory`; pixels (50,90), (51,90), (148,90), (149,90), (100,60), (100,61), (100,118), (100,119) = P; (52,90), (147,90), (100,62), (100,117), (100,90), (49,90), (150,90), (100,59), (100,120) = W.
  - `secondaryDragUsesSecondaryColor`: primary R, secondary B, secondary-button draw → (50,90) = B.
  - `fillModeUsesButtonColor`: drawMode fill, primary R → (100,90) = R, (50,60) = R, (150,90) = W; secondary-button draw with secondary B → (100,90) = B.
  - `outlineAndFillColors`: primary R, secondary B, outlineAndFill: primary draw → (50,90) = R, (100,90) = B; secondary draw → (50,90) = B, (100,90) = R.
  - `cornerHandleResizes`: draw; mouseDown at the view position of the bottomRight nub (150,120); drag to (200,150); up → box (50,60)–(200,150); (149,90) = W (old band gone, re-rendered from before), (199,90) = P.
  - `shiftCornerKeepsProportions`: drag bottomRight nub to (250,130) with Shift → box (50,60)–(166.666…,130) (±1e-9).
  - `optionScalesAboutCenter`: drag the right nub from (150,90) to (160,90) with ⌥ → box (40,60)–(160,120).
  - `dragPastOppositeFlips`: triangle, fill; drag the bottom nub (100,120) to (100,0) → box minY 60, maxY 0; (100,57) = P (width 5 at y 57), (55,3) = P, (55,57) = W.
  - `translateByDragInside`: drag from (100,90) to (110.4,95.6) → box (60,66)–(160,126); (50,90) = W.
  - `rightDragRotates90`: fill; secondary-button down at (200,90), drag to (100,190), up → `angle == 90`; frame ≈ (70,40)–(130,140); c(100,45): pixel has channel values ≤ 1 (black, alpha ≥ 254); (60,90) and (140,90) = W within ±1; the color is still primary P (rotation does not change the captured color).
  - `corridorLeftDragRotates`: primary down 10 view pt above the top edge midpoint → phase `.rotating`; dragging changes `angle`.
  - `shiftRotateSnaps`: rotate by ≈ 50° (down (200,90), drag to (100 + 100·cos 50°, 90 + 100·sin 50°)) with Shift → `angle == 45`.
  - `arrowKeysNudge`: pending → `.rightArrow` → box +1 x, returns true; `.downArrow` + ⌘ → +10 y; idle `.leftArrow` → false.
  - `aKeyCyclesShapes`: idle `a` → stored `rectangle` → `roundedRectangle`, returns true; Shift+`a` → `rectangle`; Shift+`a` again → `rightTriangle`; pending draw then `a` → shape re-rendered as the next kind (pixels change); `a` with ⌘, with ⌥, or with ⌃ → returns false, kind unchanged; `a` with `isRepeat` → true, kind unchanged; `a` mid-drag (between mouseDown and mouseUp of a nub drag) → false, kind unchanged.
- **Unit — `PaintDotMacTests/Tools/ToolDispatcherTests.swift`** (extend): `aIsNotAGlobalShortcut`: `handleShortcut(charactersIgnoringModifiers: "a", modifiers: [], …, keyWindow: .document, textInputHasFocus: false)` → `false` and the active tool is unchanged, with Shapes or any other tool active; with `ShapesTool` active, `dispatcher.keyDown(ToolKeyEvent(key: .character("a"), …))` → `true`.
  - `optionChangeRerendersPending`: draw; store drawMode `.fill` + `optionsDidChange` → (100,90) = P; store kind `.ellipse` + `optionsDidChange` → (50,60) = W, (100,90) = P.
  - `bracketKeysResizePending`: `adjustBrushWidth(by: +1)` → width 3 persisted; (52,90) = P, (53,90) = W.
  - `returnCommits`: Return → one `commitHistory` named "Shapes", icon `.shapes`, non-empty diff; not pending; overlay nil. `deactivateCommits` likewise. `escapeCancels`: layer pixel-identical (tiles `sharesStorage`), no commit.
  - `clickOutsideCommitsAndStartsNew`: pending; primary down at (20,250) (well beyond the 20 pt corridor) → one commit; a new creation drag has begun at (20,250).
  - `clickWithoutDragAddsNoStep`; `zeroHeightDragDrawsNothing`; `squashFlatThenCommitAddsNoStep` (drag the bottom nub onto y 60, Return → no commit, pixels W).
  - `respectsClipHook`: clip mask x < 100 → 255 else 0, fill mode → after commit every pixel with x ≥ 100 is W; (75,90) = P.
  - `colorsCapturedAtCreation`: change `colors.primary` to R while pending, then an option change → shape stays P.
  - `hoverCursor`: pending; mouseMoved at (150,120) → `.resize(.bottomRight)`; (100,90) → `.move`; (100,50) (10 above the top edge) → `.rotate`; (20,250) → `.crosshair`; location nil → `.arrow`; idle → `.crosshair`.
- **Integration — `PaintDotMacTests/Integration/ShapesIntegrationTests.swift`** (0005 New Image 800×600 W, `UndoBridge`, forwarding `ToolContext`, `ShapesTool`):
  - `undoRedoRoundTrip`: draw + resize + rotate + Return → history `["New Image", "Shapes"]`; undo → all tiles equal the original; redo → equal the committed snapshot; 50 seeded random shapes (kind, mode, width, dash, AA, button, box, rotation) each undo/redo identity (seed printed).
  - `undoWhileEditingCommitsFirst`: pending shape, `undoBridge.undo()` through the 0020 hook → pixels W, redo available named "Shapes".
  - `noOpAddsNoStep`: primary alpha 0 → no step; selection disjoint from the shape → no step. `offCanvasShapeAddsNoStep`: shape moved entirely off the canvas with arrow-key nudges (⌘ × 10 repeated) then Return → no step.
  - `selectionClipsShape`: `Selection(rect: (100,100,200,200))`, Filled Shape over (0,0)–(800,600) → pixels outside the rect W, (200,200) P, (99,200) W, (100,200) P.
  - `twoShapesTwoSteps`: draw, click outside to start and draw a second shape, Return → history `["New Image", "Shapes", "Shapes"]`; one undo removes only the second.
- **UI — `PaintDotMacUITests/ShapesUITests.swift`** (fixture 4000×1000 opaque white via `UITestApp.makePNG`, reset defaults; the saved PNG is read back as in 0023):
  - `shiftOSelectsShapesAndShowsOptions`: type Shift+O → `tool.shapes` selected; `toolOptions.shapeType` "Rectangle", `toolOptions.drawMode` "Shape Outline", `toolOptions.width` "2", `toolOptions.dashStyle` "Solid", `toolOptions.cornerRadius` disabled, `toolOptions.antialiasing` on, `toolOptions.blendMode` "Normal"; `toolOptions.finish` exists, disabled. Choose "Rounded Rectangle" → `toolOptions.cornerRadius` enabled showing 20; choose "Filled Shape" → `toolOptions.width` and `toolOptions.dashStyle` disabled. Choose "Rectangle", click the canvas once (focus; a click without drag adds nothing), type `a` → `toolOptions.shapeType` "Rounded Rectangle"; Shift+`a` → "Rectangle"; `tool.shapes` still selected. Then type `b`, then `o`, `o` quickly → `tool.shapes` selected again.
  - `drawHighlightRectangleSavePNG` (PRD §3 use case 1): enter `FF0000` + Return in `colors.hex` (primary); Shift+O; set `toolOptions.width` to 8; `dragOnCanvas(from: (0.25, 0.45), to: (0.75, 0.55))`; `toolOptions.finish` enabled; Return → History row "Shapes", Edit menu "Undo Shapes"; ⌘S; read the PNG: column x = 2000 contains exactly 16 pixels equal to `(255,0,0,255)` in two runs of 8 consecutive rows and every other pixel in the column is white; let `yMid` = midpoint between the runs: row `yMid` contains exactly 16 red pixels in two runs of 8, the left run starting in 920…1080 and the right run ending in 2920…3080; every pixel of that row is exactly white or exactly red (pixel-snapped corners, no antialiasing fringe); (2000, yMid) is white. ⌘Z, ⌘S, reread → column 2000 all white; ⇧⌘Z → History row "Shapes" again.
  - `filledShapeClippedToSelection`: launch with `["-UITestSelectRect", "0,0,2000,1000"]`; Shift+O; choose "Filled Shape"; drag (0.25,0.45)→(0.75,0.55); Return; ⌘S → at the vertical center of the filled area: (1500, y) = `(0,0,0,255)`, (1999, y) black, (2000, y) white, (2500, y) white.
  - `escapeDiscards`: draw as above, Escape → no "Shapes" row, Edit menu has no "Undo Shapes"; ⌘S → column 2000 all white.
  - `optionsPersistAcrossRelaunch`: choose Shape type "Ellipse" and Draw mode "Filled Shape with Outline", quit, relaunch without reset → both popups show those values.
- **Performance** — `PaintDotMacTests/Performance/ShapesPerformanceTests.swift` (XCTest `measure`, report only): re-render of an antialiased Filled Shape with Outline ellipse, width 20, dashed, spanning a 4000×3000 layer (nub-drag responsiveness, NF-1); record in Verification status. NF-4: diffs hold only touched tiles (covered by 0038's `noAllocationOutsideShape` pattern; `ShapesIntegrationTests.undoRedoRoundTrip` checks the diff's tile set ⊆ the shape's bounds).
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green (clean build, no warnings, all tests pass, none skipped, UI tests ran, launch smoke).
- **Manual verification:**
  1. Draw each of the 8 shapes in all 3 draw modes at widths 1, 8, 40 at 100% and 800% on 1× and 2× displays: rectangles are crisp; ellipses and rotated shapes smooth with antialiasing on and hard-edged with it off; no fill color shows outside the outline.
  2. Nubs keep their on-screen size and are visible on white, black, and photos; the cursor shows resize arrows over nubs, the move cursor inside, the rotate cursor in the corridor and while right-dragging, and a crosshair elsewhere.
  3. Resizing (Shift, ⌥, Shift+⌥), flipping past the opposite nub, moving, rotating (Shift 15°), and arrow/⌘-arrow nudges follow the pointer without lag on a 4000×3000 image.
  4. Changing shape type (picker and A / Shift+A), draw mode, width, dash, corner size, antialiasing, and blend mode while a shape is pending updates it immediately.
  5. Use case 1: open a screenshot, crop it, draw a red highlight rectangle, an arrow (Line / Curve), and text, export a PNG, and check it in Preview.
  6. With a soft ellipse selection, a filled shape fades at the selection edge with antialiasing on.

## Open questions

1. **Starter shape set.** PRD T-19 asks for "Rectangle, rounded rectangle, ellipse, and a starter set of other shapes"; T-20 (P1, 0058) is the extended library. This spec ships Paint.NET 5's whole **Basic** group: Rectangle, Rounded Rectangle, Ellipse, Diamond, Trapezoid, Parallelogram, Triangle, Right Angle Triangle (proportions as listed in `ShapeCatalog`). Polygons & Stars, Arrows, Callouts, and Symbols are 0058. Recommended: yes; record next to T-19 / T-20 in PRD §5.3.
2. **Outline placement and pixel snapping.** The outline is drawn *inside* the dragged box (the box is the shape's outer edge), corner points snap to whole pixels while the shape is not rotated, and in Filled Shape with Outline the fill stops at the outline's centerline. This makes highlight rectangles pixel-exact at any integer width. (Paint.NET's docs don't say where the outline sits relative to the box.) Recommended: yes; record in PRD T-19.
3. **Edit gestures.** The edit frame reuses Move Selection's (0019) eight nubs and rotation corridor. Rotation is always about the frame center (no movable Rotation Point), there is no pulsing move icon, and while a shape is pending the right button always rotates (as Paint.NET's docs say), so a secondary-color shape can only be started after finishing. ⌥ while creating draws from the center, and Shift draws a square/circle. Colors are captured when the shape is created and aren't recolored live, as with Gradient and Line / Curve. Recommended: yes for v1.0.
4. **History.** Each committed shape is one step named **"Shapes"** (the tool name, like 0038's "Line/Curve"), icon `shapes`. Undo while a shape is pending first commits it and then undoes it, as in 0023/0038. (Paint.NET 4+ records individual edits while a shape is pending and may name steps after the shape type, which its docs don't specify.) Recommended: "Shapes", one step per shape.
5. **Defaults and omitted options.** Defaults: Shape type Rectangle, Draw mode Shape Outline, Brush width 2, Dash style Solid, Corner size 20 px (range 0–1000), Antialiasing on, Blend mode Normal. Paint.NET 5's Fill Styles (pattern fills) and Selection Quality options aren't in v1.0. Recommended: yes.
6. **A / Shift+A shape cycling.** Paint.NET cycles shapes with A (Shift+A goes backward) while the Shapes tool is active. This spec implements it as a tool-local key handled in `ShapesTool.keyDown`, consumed only when 0006's `ToolShortcutGate` allows it (no ⌘/⌥/⌃, canvas focused in a document window, no gesture in progress). It needs a line in PRD §5.12 and in 0045's shortcut table. Recommended: yes.

## Out of scope

- Extended shape library (Polygons & Stars, Arrows, Callouts, Symbols) → **0058** (T-20), which adds `ShapeKind` cases and `ShapeCatalogGroup` cases.
- Line / Curve and its caps/arrowheads → **0038**; Text → **0040**.
- Movable rotation point, pulsing move handle, arrow-key rotation, live recoloring of a pending shape (Open question 3); per-edit history steps while pending (Open question 4).
- Fill Styles (patterns), Selection Quality, Paint.NET's tool-only Overwrite blend mode; blend modes beyond those implemented (0026/0027/0059 extend the list automatically).
- Tablet pressure (0055). Shortcut-table registration of A (0045 audits it).
