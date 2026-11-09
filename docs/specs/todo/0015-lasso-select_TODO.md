# 0015 — Add the Lasso Select tool (freeform and polygon)

> Source: PRD.md §5.3 T-2 ("Lasso Select — S — Freehand polygon"), §5.3 intro and D-13 (S group order Rectangle → Lasso → Ellipse → Magic Wand; selection changes are history steps), T-1 (shared selection modes: replace, union, exclude, intersect, invert, modifier keys plus a toolbar picker), TOOL-C (options persist), E-3/TOOL-B (selection = vector path + 8-bit antialiased mask, painting clipped to it), AGENTS.md rule 8, §12 D-34 (no-op edits add no step). Paint.NET docs: Lasso Select, https://paint.net/doc/latest/LassoSelectionTool.html (also https://www.getpaint.net/doc/latest/LassoSelectionTool.html); Selection Tools, https://paint.net/doc/latest/SelectionTools.html.
> Milestone: M2
> Depends on: 0014-rectangle-and-ellipse-select (and through it 0013-selection-core-and-marching-ants, 0006, 0008, 0010)

## Context

Not yet implemented: there is no application code yet. When this spec starts, the earlier specs have created (exact names from the written specs):

- 0006: `Core/Tools/Tool.swift` (`Tool` protocol: `hasPendingEdit`, `activate`/`deactivate` (default deactivate commits a pending edit), `mouseDown/Dragged/Up/Moved`, `keyDown` (default: Return/Enter with pending edit → `commit`, Escape → `cancel`), `cursor(at:modifiers:)`, `commit`, `cancel`, `optionsDidChange`), `ToolEvent.swift` (`ToolID.lassoSelect`; `ToolEvent.location` canvas space Double, top-left, y down; `viewLocation` view points; `button` primary/secondary — Control-left arrives as `.secondary` with `.control` kept; `clickCount`), `ToolContext.swift` (`transform`, `options`, `setOverlay`, `invalidateCursor`), `ToolOverlay` (+ `Canvas/ToolOverlayView.swift` draws it), `ToolCursor`, `ToolRegistry` (descriptor row `lassoSelect | Lasso Select | s | selection | lasso | supportsPendingEdits false`; `standard()` factories), `ToolOptionKey`/`ToolOptionStore`, `UI/ToolOptionsBar.swift` (`ToolOptionsContent` switch), test doubles `FakeToolContext`, `StubTool`.
- 0008: `ToolContext.commitHistory`/`performHistory`, `HistoryItem.isNoOp`, `HistoryIcon.lassoSelect`. 0010: History panel (`historyList`, `historyRow.<index>`).
- 0013: `Selection` (`Core/Model/Selection.swift`; `nil` = no selection, never empty; `init?(path: CGPath, canvasSize: PixelSize, antialiased: Bool = true, fillRule: CGPathFillRule = .winding)` normalizes the path with `fillRule`, clips it to the canvas, and rasterizes it with `MaskRasterizer`; `nil` when nothing is covered; `static func combine(_:_:mode:canvasSize:)`), `SelectionMask` (8-bit, tiled 256), `MaskRasterizer`, `SelectionCombineMode` (`replace, union, exclude, intersect, xor` — xor is Paint.NET's "Invert"), `SelectionHistoryItem(name:icon:before:after:)`, `ToolContext.selection: Selection?`, `MarchingAntsOverlay`, painting clipped through `paintClipMask`.
- 0014: `RectangleSelectTool`, `EllipseSelectTool`; `SelectionToolOptions` (`Core/Tools/SelectionToolOptions.swift`: shared keys `SelectionToolOptions.combineMode` (`tool.rectangleSelect.selectionMode`) and `SelectionToolOptions.quality` (`SelectionQuality` `.pixelated`/`.antialiased`, `tool.rectangleSelect.selectionQuality`), and `static func combineMode(picker:button:modifiers:) -> SelectionCombineMode`; the fixed ratio/size keys are Rectangle-only and Lasso does **not** use them); `SelectionGestureOutcome` (`.emit`, `.clear`, `.reset`) and `SelectionCommit.finish(outcome:newSelection:mode:name:icon:context:)` (`Core/Tools/SelectionGesture.swift`: `.emit` combines `newSelection` with `context.selection` through `Selection.combine` and records a `SelectionHistoryItem` named after the tool, a no-op result adding no step; `.clear` records a "Deselect" step when a selection exists; `.reset` does nothing); `SelectionToolOptionsView(model:showsDrawMode:)` (`UI/SelectionToolOptionsView.swift`); status bar `statusBar.selectionSize` (fed from `SelectionSizeDisplay` and `selection.bounds`). 0014's click-without-drag rule: in Replace mode a click → `.clear`; in the other modes → `.reset`.

Paint.NET behavior being mirrored:
- Lasso Select doc page: "This tool is used to create a freeform selection." "The edge of the selected region will follow the mouse cursor as it is dragged around the canvas." "The shape will automatically be closed with a straight line from the current cursor location back to the start point." Shortcut "S twice or Shift + S three times" (our D-13/D-35 cycling already gives this).
- Paint.NET 5 adds a **Polygon** lasso mode next to the default **Freeform** mode in the toolbar (click to place vertices). The doc page above still only describes freeform; the polygon gestures below (vertex per click, close by Return / double-click / clicking the first vertex, Escape cancels) are PRD T-2 / D-39.
- Selection Tools page: five modes — Replace (default), Add (union; Ctrl), Subtract (Alt), Intersect (Alt + right button), Invert/xor (Ctrl + right button); and a Selection clipping setting: "Pixelated" (each pixel fully in or out) or "Antialiased". Mac mapping (Ctrl → ⌘, Alt → ⌥, right button = right-click or Control-click) is owned by 0014's `SelectionToolOptions`; Lasso reuses it unchanged.
- **Fill rule.** A self-intersecting lasso uses the **even-odd ("alternate") rule**: regions enclosed an even number of times (for example the center pentagon of a pentagram) are *not* selected. This is Paint.NET's behavior (its selection paths are filled with the GDI+/Direct2D *alternate* fill mode, the `PdnGraphicsPath` default). PRD T-2 / D-39.

## User story

As a PaintDotMac user, I press **S** until **Lasso Select** is active, drag a freehand outline around an object (or switch the options bar to **Polygon** and click corner points, then press Return), and get a selection with marching ants that is closed with a straight line back to the start. Holding ⌘/⌥ (or using the mode picker) adds to, subtracts from, intersects, or inverts the existing selection, exactly like Rectangle Select. Each lasso is one "Lasso Select" history step that ⌘Z undoes.

## Scope & changes

### Core (pure Swift, no AppKit/SwiftUI; unit-tested) — `PaintDotMac/Core/Tools/LassoSelectTool.swift` (new)

All types below live in this one file.

- **`enum LassoMode: String, CaseIterable, Sendable { case freeform, polygon }`** with `displayName` "Freeform" / "Polygon". Option key `static let lassoModeKey = ToolOptionKey<String>(tool: .lassoSelect, name: "lassoMode", defaultValue: "freeform")` → defaults key `tool.lassoSelect.lassoMode`; an unknown stored string reads as `.freeform`.

- **`struct LassoPath: Sendable, Equatable`** — the pure point list and its rules.
  - `private(set) var points: [CGPoint]` (canvas space, unsnapped Doubles; points outside the canvas are kept — the rasterizer clips).
  - `private(set) var lastViewPoint: CGPoint?` (view location of the last kept point).
  - `static let minimumViewSpacing: Double = 1.0` (points) — **point thinning**: `mutating func appendFreeform(_ p: CGPoint, view v: CGPoint)` appends only when `points` is empty or the view distance from `lastViewPoint` is `≥ minimumViewSpacing`. Thinning is in **view** space so it adapts to zoom (at 3200 % consecutive kept points can be 1/32 px apart; at 10 % about 10 px apart). No further simplification (no Douglas–Peucker): the outline follows the pointer exactly as sampled.
  - `mutating func appendFinal(_ p: CGPoint, view v: CGPoint)` — the mouseUp point: appended unless it is exactly equal to the last point (no thinning, so the outline ends where the pointer was released).
  - `mutating func appendVertex(_ p: CGPoint, view v: CGPoint)` / `mutating func moveLastVertex(to p: CGPoint, view v: CGPoint)` (polygon mode; no thinning).
  - `var isDegenerate: Bool` — `true` when there are fewer than 3 distinct points, or when all points are collinear: with `p0 = points[0]` and `pf` = the point farthest from `p0`, `max_i |cross(pf − p0, p_i − p0)| ≤ 1e-9 × max(1, |pf − p0|)`. (A figure-eight with zero *signed* area is not degenerate.)
  - `func closedPath() -> CGPath?` — `nil` when `isDegenerate`. Otherwise a `CGMutablePath` `move(to: points[0])`, `addLine(to:)` each following point, `closeSubpath()` (the straight closing line back to the start, as in Paint.NET), then returned as **`path.normalized(using: .evenOdd)`** (CoreGraphics, macOS 13+). The normalized path encloses exactly the even-odd region and fills identically under either rule, so 0013's `Selection` (which normalizes with the `fillRule` it is given; the tool passes `.evenOdd`, a no-op on an already-normalized path) and later path combinations (0013 `combine`, 0019 transforms) stay correct. If `normalized` returns an empty path (no area), return `nil`.

- **`final class LassoSelectTool: Tool`** (`id = .lassoSelect`).
  - State: `enum Phase { case idle, freeformDragging, polygonEditing(vertexDragActive: Bool) }`, `var path: LassoPath`, `var combineMode: SelectionCombineMode?` (fixed at the first mouseDown of the lasso), `var rubberBand: CGPoint?` (polygon hover point), `var finishOnMouseUp: Bool`.
  - `hasPendingEdit` = `phase != .idle`.
  - **Mode resolution.** On the mouseDown that starts a lasso, `combineMode = SelectionToolOptions.combineMode(picker: context.options.value(SelectionToolOptions.combineMode), button: event.button, modifiers: event.modifiers)`. The mode is not re-read later in the same lasso. Antialiasing is read at commit time: `antialiased = context.options.value(SelectionToolOptions.quality) == .antialiased`.
  - **Freeform** (`LassoMode.freeform`):
    - `mouseDown`: `path = LassoPath()`, `appendFreeform(location, view:)`, phase `.freeformDragging`, overlay.
    - `mouseDragged`: `appendFreeform`, update overlay.
    - `mouseUp`: `appendFinal`, then `finish(context:)`.
  - **Polygon** (`LassoMode.polygon`):
    - `mouseDown` while idle: start a new path with vertex = location; phase `.polygonEditing(vertexDragActive: true)`.
    - `mouseDown` while editing:
      - `clickCount ≥ 2` → `finishOnMouseUp = true`, add no vertex (the first click of the double-click already placed it).
      - else if `points.count ≥ 3` and the view distance between `event.viewLocation` and `context.transform.canvasToView(points[0])` is `≤ closeSnapDistance` (`static let closeSnapDistance: Double = 6` points) → `finishOnMouseUp = true`, no vertex added.
      - else `appendVertex(location)`; `vertexDragActive = true`.
    - `mouseDragged` with `vertexDragActive` → `moveLastVertex(to: location)` (press-and-drag positions the new vertex).
    - `mouseUp` → `vertexDragActive = false`; if `finishOnMouseUp` → `finish(context:)`.
    - `mouseMoved` while editing → `rubberBand = location`, overlay updated.
    - Return/Enter → default `keyDown` → `commit` → `finish`. Escape → `cancel`.
  - **`commit(context:)`** = `finish(context:)` when not idle (Return, tool switch via `deactivate`, document switch, undo/save hooks from 0008). **`cancel(context:)`**: clear path, overlay `nil`, phase idle; no history step, selection unchanged.
  - **`finish(context:)`**: overlay `nil`; then
    - `path.closedPath() == nil` (degenerate: a plain click, a straight-line drag, < 3 distinct points) → 0014's click-without-drag rule: `SelectionCommit.finish(outcome: combineMode == .replace ? .clear : .reset, newSelection: nil, mode: combineMode, name: "Lasso Select", icon: .lassoSelect, context:)` (Replace with an existing selection → one "Deselect" step; otherwise nothing). Lasso adds no step of its own. (0014's 50 ms "too quick" rule does not apply to the lasso: a lasso with ≥ 3 non-collinear points is never a click.)
    - otherwise `newSelection = Selection(path: closed, canvasSize: context.image.size, antialiased: antialiased, fillRule: .evenOdd)` (`nil` when the lasso covers no canvas pixel) and `SelectionCommit.finish(outcome: .emit, newSelection:, mode: combineMode, name: "Lasso Select", icon: .lassoSelect, context:)`. If the result equals the current selection (for example Union with a lasso fully inside it), the item is a no-op and no step is added (D-34). An empty combined result is `nil` ("no selection", PRD E-3 / D-40).
    - reset to idle, `combineMode = nil`, `finishOnMouseUp = false`, `rubberBand = nil`.
  - **`optionsDidChange`**: if `lassoMode` changed while a polygon is being edited, `commit` it first (the user's work is kept, not lost).
  - **`cursor`**: `.crosshair`, as Rectangle Select (0014).
  - **Overlay.** Add `case lassoPath(points: [CGPoint], rubberBand: CGPoint?)` to 0006's `ToolOverlay` (canvas space). Freeform sets `rubberBand: nil`. The overlay is the live feedback; the committed selection's marching ants appear on finish. There is no live combined-selection preview (0014 has none either); the current selection's ants stay visible while lassoing.

- **`Core/Tools/ToolRegistry.swift`** (modify): `standard()` registers `.lassoSelect → LassoSelectTool()`. The S group becomes Rectangle → Lasso → Ellipse (+ Magic Wand later), per D-13.

### Platform glue

- **`Canvas/ToolOverlayView.swift`** (modify): draw `.lassoPath`: map every point with `transform.canvasToView`; stroke the open polyline (points in order) with the same style as `.zoomRectangle` (1 pt white line under a 1 pt black line dashed `[4, 4]`, static); then draw the closing segment from the last point (or `rubberBand` when non-nil, via the segment last point → rubberBand) back to `points[0]` with the same style at 50 % opacity, so the user sees how the shape will close. One point → nothing visible. Redraw on overlay and transform changes (existing hook).
- **`UI/ToolOptionsBar.swift`** (modify): `case .lassoSelect:` → `SelectionToolOptionsView(model:, showsDrawMode: false)` (mode picker, clipping; **no** fixed ratio/size controls) followed by a **Lasso mode** segmented `Picker` "Freeform" / "Polygon" (`.help("Lasso mode")`, accessibility identifier `toolOptions.lassoMode`, accessibility value = selected display name), bound to `tool.lassoSelect.lassoMode`.
- No new menu items. No project.yml change beyond the new file → run `xcodegen generate`.
- No PRD change in this spec: T-2 and D-39 already record the Freeform/Polygon modes and the even-odd rule.

## Acceptance criteria

- [ ] Pressing S cycles Rectangle Select → Lasso Select → Ellipse Select within 1 s; the Tools panel shows and highlights `tool.lassoSelect`. → `LassoSelectUITests.sKeyCyclesToLasso`, `ToolRegistryLassoTests.sGroupOrder`
- [ ] Freeform: dragging a closed outline selects its interior; the outline is closed by a straight line from the release point to the start point. → `LassoSelectToolTests.freeformSquareSelectsInterior`, `.openOutlineClosesWithStraightLine`
- [ ] Polygon: each click adds a vertex (press-and-drag positions it); Return, a double-click, or clicking within 6 pt of the first vertex (≥ 3 vertices) closes the polygon; Escape cancels with no step. → `LassoSelectToolTests.polygonClicksThenReturn`, `.polygonDoubleClickFinishes`, `.polygonClickOnFirstVertexCloses`, `.polygonDragPositionsVertex`, `.polygonEscapeCancels`, `LassoSelectUITests.polygonTriangleSelectsAndUndoes`, `.polygonEscapeAddsNoStep`
- [ ] Self-intersecting outlines use the even-odd rule. → `LassoPathTests.pentagramCenterIsHoleEvenOdd`, `LassoSelectToolTests.pentagramMask`
- [ ] Freeform point thinning: points closer than 1 view point to the last kept point are dropped; the release point is always kept. → `LassoPathTests.thinningInViewSpace`, `.finalPointAlwaysKept`
- [ ] Fewer than 3 distinct points or collinear points → treated as a click (0014's rule); no "Lasso Select" step. → `LassoPathTests.degenerateCases`, `LassoSelectToolTests.clickActsLikeSelectionClick`, `LassoSelectUITests.straightDragAddsNoLassoStep`
- [ ] Pixelated vs Antialiased selection clipping is honoured. → `LassoSelectToolTests.pixelatedMaskIsBinary`, `.antialiasedEdgeIsPartial`
- [ ] Replace / Union / Exclude / Intersect / Invert (picker and modifiers, mode fixed at the first mouseDown) combine with the existing selection exactly like Rectangle Select. → `LassoSelectToolTests.combineModes`, `.modeFixedAtFirstMouseDown`, `LassoSelectUITests.commandAddsToSelection`
- [ ] Each lasso is one history step "Lasso Select" (icon `lassoSelect`); undo restores the previous selection exactly, redo re-applies it; a no-op result adds no step. → `LassoSelectToolTests.historyStepUndoRedo`, `.noOpUnionAddsNoStep`, `LassoSessionTests.paintClippedToLasso`
- [ ] Switching tools or documents mid-polygon commits it; changing the Lasso mode mid-polygon commits it. → `LassoSelectToolTests.deactivateCommitsPolygon`, `.modeChangeCommitsPolygon`
- [ ] The Lasso mode persists across launches (`tool.lassoSelect.lassoMode`, default Freeform). → `LassoSelectToolTests.lassoModeDefaultsAndPersistence`, `LassoSelectUITests.lassoModePersists`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report. → quality-gate launch smoke (`quality-gate.sh`)

## Edge cases

- **Points outside the canvas / lasso entirely off-canvas:** kept in the path; the mask is clipped by `MaskRasterizer`. A lasso fully off-canvas in Replace mode gives an empty mask → stored as "no selection" (`nil`, a "Lasso Select" step that clears the existing selection); if there was no selection before, it is a no-op (no step). → `LassoSelectToolTests.offCanvasLasso`
- **Far-away points (±1e7):** no overflow or crash; bounds computed in Double and clipped before any Int conversion (0013). → `LassoSelectToolTests.hugeCoordinatesDoNotCrash`
- **Crossing tile boundaries:** a lasso spanning 4 tiles (300×300 image) produces the same mask as an oracle on every tile. → `LassoSelectToolTests.crossesTileBoundaries`
- **1×1 image:** a lasso around the whole canvas selects the single pixel (255 pixelated). → `LassoSelectToolTests.onePixelImage`
- **Duplicate points** (mouse not moving): never appended twice (thinning / equality), so a stationary click is degenerate. → `LassoPathTests.finalPointAlwaysKept`, `.degenerateCases`
- **Very long drags** (100 000 kept points): commit finishes, no crash; no extra cap. → `LassoSelectToolTests.manyPointsCommit` (time checked loosely: < 2 s).
- **Polygon with 1–2 vertices + Return:** degenerate → click rule, no "Lasso Select" step. → `LassoSelectToolTests.polygonTooFewVerticesActsAsClick`
- **Double-click as the very first action:** first click starts the polygon (1 vertex), second (clickCount 2) finishes → degenerate → click rule. → `LassoSelectToolTests.polygonDoubleClickFirstIsClick`
- **Escape during a freeform drag:** 0006's dispatcher calls `cancel`; overlay cleared, no step, later drags swallowed. → `LassoSelectToolTests.escapeDuringFreeformCancels`
- **Undo while a polygon is being edited:** 0008's `prepareForNavigation` calls `commit(context:)` first, then undo removes that "Lasso Select" step (consistent with other pending-edit tools; 0020's default `prepareForHistoryNavigation` keeps this). → `LassoSelectToolTests.commitFinishesPolygon`
- **Zoom / pan during polygon editing:** vertices are canvas space, so they stay on the image; the close-snap distance uses the current transform. → `LassoSelectToolTests.closeSnapUsesCurrentTransform`
- **No document / no context:** the dispatcher ignores events (0006); nothing to do here (covered by 0006's dispatcher tests).

## Test plan

- **Unit tests — `PaintDotMacTests/Tools/LassoPathTests.swift`** (pure `LassoPath`):
  - `thinningInViewSpace`: append view points (0,0), (0.4,0), (0.9,0), (1.0,0), (1.5,0), (2.0,0) with canvas points = view/2 → kept canvas points exactly [(0,0), (0.5,0), (1.0,0)].
  - `finalPointAlwaysKept`: after (0,0), (10,0) append final (10.3,0) → kept; append final equal to last → not duplicated.
  - `degenerateCases`: 0, 1, 2 points; 3 equal points; 3 collinear diagonal points (0,0),(5,5),(10,10) → `isDegenerate` and `closedPath() == nil`; (0,0),(10,0),(0,10) → not degenerate; figure-eight (0,0),(10,10),(10,0),(0,10) → not degenerate.
  - `pentagramCenterIsHoleEvenOdd`: vertices on a circle r = 20 at (32,32), angles −90° + 72°·k, visited in order k = 0,2,4,1,3 → `closedPath()` contains (32.5,15.5) (tip, winding 1) and does **not** contain (31.5,31.5) (center, winding 2) under **both** `.winding` and `.evenOdd` `CGPath.contains` (proves normalization).
  - `closedPathEndsAtStart`: three points (2,2),(10,2),(10,10) → path bounding box is (2,2,8,8) and contains (9,3) but not (3,9) (triangle, closed by the straight line back to the start).
- **Unit tests — `PaintDotMacTests/Tools/LassoSelectToolTests.swift`** (with `FakeToolContext`, 64×64 image unless stated; expected masks are hand-computed from pixel-center containment, the independent oracle):
  - `freeformSquareSelectsInterior`: Pixelated, freeform drag (2,2)→(10,2)→(10,10)→(2,10), release at (2,10) → mask 255 exactly for x,y ∈ 2…9, 0 elsewhere; one history step named "Lasso Select", icon `.lassoSelect`.
  - `openOutlineClosesWithStraightLine`: drag (2,2)→(20,2)→(20,20), release → mask equals the right triangle oracle (pixel center (x+0.5,y+0.5) with y ≤ x within the square), e.g. (15,5)=255, (5,15)=0.
  - `pixelatedMaskIsBinary`: the triangle above with Pixelated → every mask value ∈ {0,255}.
  - `antialiasedEdgeIsPartial`: Antialiased, square (2.5,2.5)–(10.5,10.5) → interior pixels (3…9) 255; edge pixel (2,5) ∈ 126…129 (half coverage); corner (2,2) ∈ 62…66 (quarter); (12,12) = 0.
  - `pentagramMask`: pentagram above, Pixelated → (32,15) = 255, (31,31) = 0.
  - `polygonClicksThenReturn`: Polygon mode; clicks at (2,2), (20,2), (20,20); `keyDown(.returnKey)` returns true → triangle mask as above; one step.
  - `polygonDoubleClickFinishes`: three clicks, then mouseDown with `clickCount 2` at (20,20) + mouseUp → same mask; vertex count 3 (no duplicate added).
  - `polygonClickOnFirstVertexCloses`: transform at 100 %; three vertices, then click 4 view pt from vertex 0 → finishes, 3 vertices; click 7 pt away instead → a 4th vertex is added and the tool is still editing (`hasPendingEdit`).
  - `polygonDragPositionsVertex`: second vertex mouseDown at (20,2), drag to (30,2), up → stored vertex (30,2).
  - `polygonEscapeCancels` / `escapeDuringFreeformCancels`: no step, selection unchanged, last overlay `nil`, `hasPendingEdit == false`.
  - `clickActsLikeSelectionClick`: with an existing Rectangle selection, freeform click (down/up same point) in Replace → one "Deselect" step (as `RectangleSelectToolTests.clickDeselects`); in Union → no step.
  - `combineModes`: existing selection = pixelated rect (0,0)–(16,16); lasso square (8,8)–(24,24) with each picker mode → Replace: only the lasso square; Union: L-shaped union; Exclude: rect minus overlap; Intersect: (8…15)²; Invert (xor): union minus overlap — each checked pixel-by-pixel against set-algebra on the two oracle masks.
  - `modeFixedAtFirstMouseDown`: start with ⌘ held (union), release ⌘ during the drag/polygon → still Union. Also right button + ⌥ → Intersect, right + ⌘ → Invert, left + ⌥ → Exclude (through 0014's mapping).
  - `historyStepUndoRedo`: lasso, `undo` → selection identical to before (mask tiles equal), `redo` → identical to after; history names `["New Image", "Lasso Select"]`.
  - `noOpUnionAddsNoStep`: Union with a lasso fully inside the existing pixelated selection → no new step.
  - `deactivateCommitsPolygon` / `modeChangeCommitsPolygon`: 3 vertices, then `deactivate` (or set `lassoMode` to freeform + `optionsDidChange`) → one "Lasso Select" step.
  - `lassoModeDefaultsAndPersistence`: fresh store → `.freeform`; writing `"polygon"` stores `tool.lassoSelect.lassoMode = "polygon"` and a new tool instance reads it; stored `"bogus"` → `.freeform`.
  - `offCanvasLasso`, `hugeCoordinatesDoNotCrash`, `crossesTileBoundaries` (300×300, pixelated diamond through (150,10),(290,150),(150,290),(10,150); every pixel compared with the containment oracle), `onePixelImage`, `manyPointsCommit` (seeded random walk of 100 000 points via `SeededRandom`, seed printed; asserts commit produces one step and every mask value is 0 or 255 in Pixelated mode).
  - `polygonTooFewVerticesActsAsClick`: existing rect selection, Polygon, clicks (2,2), (20,2), Return → one "Deselect" step (Replace), no "Lasso Select"; same with ⌘ (Union) → no step.
  - `polygonDoubleClickFirstIsClick`: no selection, Polygon, mouseDown/up at (5,5), then mouseDown `clickCount 2` + up at (5,5) → no step, `hasPendingEdit == false`.
  - `commitFinishesPolygon`: 3 vertices, then `commit(context:)` → one "Lasso Select" step with the triangle mask, `hasPendingEdit == false`.
  - `closeSnapUsesCurrentTransform`: 3 vertices placed at 100 %, then the fake's transform changes to 400 %; a click 1 canvas px (4 view pt) from vertex 0 closes; at 100 % again, a click 7 canvas px away (7 pt) adds a 4th vertex.
  - `overlayFollowsGesture`: freeform drag records `.lassoPath(points:, rubberBand: nil)` with the kept points; polygon `mouseMoved` records `rubberBand` = the hover point.
- **Property test — `LassoSelectToolTests.undoRedoProperty`:** 200 seeded random polygons (3–12 vertices, random modes, random existing selection): apply → undo restores the exact prior mask, redo the exact result; Invert applied twice with the same lasso restores the original mask (pixelated).
- **Registry test — `PaintDotMacTests/Tools/ToolRegistryLassoTests.swift`:** `sGroupOrder` (`shortcutGroup(for: "s")` starts `[.rectangleSelect, .lassoSelect, .ellipseSelect]`; `makeTool(.lassoSelect) is LassoSelectTool`); update 0006's `standardRegistersZoomAndPan`-style list test to include `.lassoSelect`.
- **Integration test — `PaintDotMacTests/Integration/LassoSessionTests.swift`:** `paintClippedToLasso`: new 64×64 white image; freeform lasso triangle (Pixelated); Paintbrush (width 100, primary black) drag across the whole image → pixels inside the triangle black, outside still white (TOOL-B); history `["New Image", "Lasso Select", "Paintbrush"]`; undo twice → white image, no selection; redo twice → same result.
- **UI tests — `PaintDotMacUITests/LassoSelectUITests.swift`** (fixture generated at test time: 200×200 opaque white PNG via `UITestApp.makePNG`, `-UITestOpen`, `-UITestResetDefaults`; ⌘0 first):
  - `sKeyCyclesToLasso`: press B, then S, S quickly → `tool.lassoSelect` selected.
  - `polygonTriangleSelectsAndUndoes`: select Lasso, choose "Polygon" in `toolOptions.lassoMode`, click canvas at normalized (0.2,0.2), (0.8,0.2), (0.5,0.8), press Return → last `historyList` row "Lasso Select"; `statusBar.selectionSize` non-empty and ≈ "120 × 120" (±2 px per side, parse the numbers); ⌘Z → selection size empty, last row "Open Image" selected.
  - `polygonEscapeAddsNoStep`: two clicks then Escape → history has only "Open Image".
  - `straightDragAddsNoLassoStep`: Freeform, `dragOnCanvas` from (0.2,0.2) to (0.8,0.8) (a straight line is degenerate) → no "Lasso Select" row.
  - `commandAddsToSelection`: Polygon triangle as above; then with `perform(withKeyModifiers: .command)` click a second triangle at (0.1,0.85),(0.3,0.85),(0.2,0.95) and press Return → two "Lasso Select" rows and the selection size grows to the union bounds (height ≈ 150).
  - `lassoModePersists`: set Polygon, relaunch without reset → `toolOptions.lassoMode` value "Polygon".
- **Performance:** no NF target applies directly; `manyPointsCommit` guards gross regressions.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build with no warnings, all tests pass with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Freeform: drag a wobbly loop around an object at 100 % → the dashed outline follows the pointer smoothly, a faint closing line shows how it will close; on release marching ants appear along the drawn edge.
  2. Draw a figure-eight / star crossing itself → the doubly enclosed region is not selected (even-odd).
  3. Polygon: click 5 corners, watch the rubber band follow the pointer, click on the first vertex → closes; repeat finishing with a double-click and with Return.
  4. Hold ⌘ / ⌥ / right-click+⌥ / right-click+⌘ while starting a lasso → add / subtract / intersect / invert, matching Rectangle Select.
  5. Toggle Antialiased vs Pixelated and fill or paint the selection at 800 % → soft vs hard stair-stepped edges.
  6. Zoom to 3200 % and to 10 % while drawing freeform → outline stays smooth, no lag on a long drag.

## Open questions

None. The polygon gestures and the even-odd fill rule an earlier draft asked about are settled by PRD T-2 and D-39 and are applied above.

## Out of scope

- Rectangle/Ellipse Select, `SelectionToolOptions`, the click-without-drag rule, status-bar selection size, Zoom to Selection → 0014. Selection model, mask rasterization, marching ants, Select All / Deselect / Invert Selection → 0013.
- Moving the selection while drawing it with the second mouse button (Paint.NET Selection Tools tip): not in v1.0 for Lasso (0006's dispatcher ignores a second button mid-gesture).
- Magic Wand → 0016; Move Selection / Move Selected Pixels → 0019 / 0020.
- Path simplification beyond view-space thinning; editing vertices after commit.
