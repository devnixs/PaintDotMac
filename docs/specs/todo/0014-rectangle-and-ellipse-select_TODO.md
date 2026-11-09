# 0014 — Add the Rectangle Select and Ellipse Select tools, shared selection-tool options, Zoom to Selection, and the status-bar selection size

> Source: PRD.md §5.3 T-1 (Rectangle Select: selection modes replace/union/exclude/intersect/invert via modifier keys plus a toolbar picker; fixed ratio and fixed size), T-3 (Ellipse Select), TOOL-C (options persist); PRD.md §5.3 intro and §12 D-13 (S cycles Rectangle → Lasso → Ellipse → Magic Wand; selection changes are history steps "Rectangle Select", "Deselect", …), D-35 (cycling window); PRD.md §5.2 CAN-1 (Zoom to Selection — the part 0004 left out); PRD.md §5.1 APP-5 (selection size — the field 0004 created empty); PRD.md §5.12 (Zoom to Selection ⇧⌘B; Ctrl → ⌘, Alt → ⌥); PRD.md §12 D-34 (no-op edits add no step).
> Paint.NET references (fetched 2026-11-05; www.getpaint.net/doc/latest now redirects to paint.net/doc/latest):
> - Selection Tools — https://paint.net/doc/latest/SelectionTools.html (five modes and their modifiers; Selection Clipping Modes; deselect by Enter/Ctrl+D or by clicking with a selection tool).
> - Rectangle Select — https://paint.net/doc/latest/RectangleSelectionTool.html (Shift = square; Fixed Ratio; Fixed Size; units Pixels/Inches/Centimeters).
> - Ellipse Select — https://paint.net/doc/latest/EllipseSelectionTool.html (Shift = circle whose diameter is set by the starting click and the current pointer).
> - Keyboard & Mouse Commands — https://paint.net/doc/latest/KeyboardMouseCommands.html ("Create selection: Drag + Left or Right Mouse Button", "Add to selection: Ctrl + Drag + Left", "Subtract from selection: Alt + Drag + Left", "Invert selection mode: Ctrl + Drag + Right", "Intersect selection mode: Alt + Drag + Right", "Force Rectangle Select to square: Shift + Drag", "Force Ellipse Select to circle: Shift + Drag", "Deselect active selection: Ctrl + D or Enter"; resize nubs are listed only under the Move tools).
> - Paint.NET 3.36 source (the last published source; behavior details the docs omit): `src/tools/SelectionTool.cs`, `src/tools/RectangleSelectTool.cs`, `src/tools/EllipseSelectTool.cs`, `src/SelectionDrawModeInfo.cs`, `src/Core/Utility.cs` (`PointsToRectangle`, `PointsToConstrainedRectangle`) at https://github.com/wangdeshui/paint.net/tree/master/src.
> Milestone: M2
> Depends on: 0013-selection-core-and-marching-ants (and through it 0004, 0006, 0008, 0009, 0010, 0011)

## Context

Nothing of this exists yet (no application code). After 0013 the document has a selection model, Edit > Select All / Deselect / Invert Selection, marching ants, and painting clipped to the mask, but no tool can draw a selection. 0004 left two holes that this spec fills: View > Zoom to Selection (0004's View menu has a marked insertion point between "Zoom to Window" and "Actual Size", `docs/specs/todo/0004-zoom-pan-and-status-bar_TODO.md:104`) and `StatusBarModel.selectionSize`, which is always `nil` in 0004 (`0004…:110`, hook test `selectionSizeIsEmptyUntilSet` at `0004…:211`). 0004 already says Zoom to Selection uses `ZoomLevels.fitZoom(…, allowsEnlargement: true)` (`0004…:52`).

### Types this spec builds on (exact names from the sibling specs)

- 0006 (`docs/specs/todo/0006-tool-framework-and-panels_TODO.md:44-312`): `ToolID` (`.rectangleSelect`, `.ellipseSelect`), `ToolEvent` (`location`: canvas space = image pixels, `Double`, top-left origin, y down; `viewLocation`; `button` `.primary`/`.secondary` — right button **and Control-left** arrive as `.secondary` with `.control` kept in `modifiers`; `modifiers: ToolModifiers` `.shift/.option/.control/.command`; `timestamp`), `ToolKey`/`ToolKeyEvent`, the `Tool` protocol (`mouseDown/Dragged/Up`, `flagsChanged(_:context:)`, `keyDown(_:context:) -> Bool`, `cursor(at:modifiers:)`, `cancel`, `activate`/`deactivate`), `ToolContext` (`image`, `transform`, `options`, `setOverlay`, `invalidateCursor`), `ToolOverlay` (+ `Canvas/ToolOverlayView.swift`), `ToolCursor`, `ToolRegistry.standard()` and `shortcutGroup(for:)` (implemented tools only, `ToolID.allCases` order), `ToolDispatcher` (one gesture at a time: a second button pressed mid-gesture is ignored; Escape mid-gesture calls `cancel`), `ToolOptionKey`/`ToolOptionStore` (`tool.<id>.<name>`; String-raw-valued enums conform to `ToolOptionValue` with an empty extension), `UI/ToolOptionsBar.swift` (`ToolOptionsContent` switch, `onEndEditing`), `FakeToolContext`, `UITestApp` helpers.
- 0004: `ZoomLevels.fitZoom(contentSize:viewportSize:allowsEnlargement:)`, `CanvasTransform.clampedScroll(viewSize:imageSize:)` and `fittedToWindow(viewSize:imageSize:)` (the "navigation" extension next to which this spec adds one function), `CanvasNavigation` (`zoomToWindow()`, `setZoom(_:anchoredAtView:)`), `MeasurementUnit` (`.pixels/.inches/.centimeters`, `displayName`, `format…`), `StatusBarModel.selectionSize: PixelSize?` → `selectionSizeText`, `StatusBarView` (`statusBar.selectionSize`), `MainMenu.swift` View menu with `menu.view.*` identifiers, `DocumentWindowController.validateMenuItem`.
- 0003: `CanvasTransform` (`imageSize`, `viewSize` points, `backingScale`, `zoom`, `center` = canvas point at the view's center, `canvasRectToView`).
- 0008: `DocumentState` (0013 adds `selection`), `HistoryItem` (`isNoOp`), `HistoryIcon.rectangleSelect`, `.ellipseSelect`, `.deselect` (already listed in 0008), `ToolContext.performHistory(_:)`, `UndoBridge.onStateChange`.
- 0002: `PixelPoint`, `PixelSize`, `PixelRect`, `ImageLimits` (max side 65,535).

### What this spec consumes from 0013 (exact names)

- `Selection` (`Core/Model/Selection.swift`): `Selection?` with `nil` = no selection (a `Selection` value is never empty); `init?(rect: CGRect, canvasSize: PixelSize, antialiased: Bool = true)` (exact analytic rectangle coverage), `init?(path: CGPath, canvasSize: PixelSize, antialiased: Bool = true, fillRule: CGPathFillRule = .winding)` (path clipped to the canvas, rasterized by `MaskRasterizer`); both return `nil` when nothing is covered. `static func combine(_ existing: Selection?, _ operand: Selection?, mode: SelectionCombineMode, canvasSize: PixelSize) -> Selection?` (`nil` operands act as the empty set; `nil` result = no selection). `selection.bounds: PixelRect` = the mask's tight bounds of pixels with coverage > 0 (never `.zero` for a non-`nil` selection).
- `SelectionCombineMode` (`replace, union, exclude, intersect, xor`), `String`-raw-valued, `CaseIterable`, with `displayName` "Replace", "Add (Union)", "Subtract", "Intersect", "Invert (Xor)".
- `SelectionHistoryItem(name:icon:before:after:)` (`isNoOp` when `before == after`; change `.selection`).
- `DocumentState.selection`, `ToolContext.selection: Selection?` (read-only; `FakeToolContext` already backs it with its `DocumentState`).
- `MarchingAntsOverlay` (`Canvas/MarchingAntsOverlay.swift`, `update(selection:transform:)`), `SelectionCommand.deselect` (Edit > Deselect, which records `SelectionHistoryItem(name: "Deselect", icon: .deselect, before: selection, after: nil)`).

This spec adds no member to 0013's types; it only adds the `ToolOptionValue` conformance of `SelectionCombineMode` (empty extension; it is already `String`-raw-valued).

### Paint.NET behavior mirrored (from the docs and the 3.36 source above)

1. **Mode from modifiers, read once at mouse-down** (`SelectionTool.OnMouseDown`): Ctrl + left → Union; Alt + left → Exclude; Ctrl + right → Xor ("Invert"); Alt + right → Intersect; anything else → the toolbar's mode. Ctrl is tested before Alt, so Ctrl wins when both are held. A plain right-drag uses the toolbar mode ("Create selection: Drag + Left or Right Mouse Button").
2. **Pixel-inclusive rectangle** (`Utility.PointsToRectangle`): mouse positions are integer document pixels; the rectangle runs from the start pixel to the current pixel **inclusive** (`width = |a.x − b.x| + 1`). The rectangle is then intersected with the image bounds (`rect.Intersect(Document.Bounds)`). So rectangle selections always have integer edges.
3. **Shift → square** (`PointsToConstrainedRectangle`): side = min(width, height), anchored at the start pixel, extending toward the pointer. Shift is re-read on every key change while dragging (`OnKeyDown/OnKeyUp → Render`).
4. **Fixed Ratio / Fixed Size** (`RectangleSelectTool.CreateShape`, `SelectionDrawModeInfo`): draw modes `Normal`, `FixedRatio`, `FixedSize`; default `Normal`, width 4, height 3, units Inches (`CreateDefault()`). Fixed Ratio locks width:height while dragging (Shift is ignored). Fixed Size: the rectangle's top-left follows the pointer and has the specified size converted to pixels with the document's DPI; dragging moves it. Ellipse Select has no draw-mode options (`ToolBarConfigItems.None`).
5. **Ellipse** (`EllipseSelectTool.CreateShape`): the ellipse is inscribed in the same pixel-inclusive rectangle; with Shift it is a circle centered between the start and current points whose diameter is their distance (docs: "The diameter is then set by the starting click and the current pointer position").
6. **Finishing a drag** (`SelectionTool.Done`, its truth table quoted in full there): with `append` = mode ≠ Replace, `moved` = the pointer moved during the drag, `tooQuick` = the button was held ≤ 50 ms, `clipped` = the shape is empty after clipping to the image:
   - Replace: `moved && !tooQuick && !clipped` → **emit** a step named after the tool; else **clear** the selection — a **"Deselect"** step if the selection was not empty, nothing otherwise. This is "click to deselect" (also off-canvas: "Clicking anywhere off-canvas with one of the Selection Tools active will also deselect").
   - Union/Exclude/Intersect/Xor: `!moved || clipped` → **reset** (selection unchanged, no step); else emit.
7. Deselect from the keyboard: "Ctrl + D or Enter".
8. **Selection clipping mode**: "whether the selection edge is clipped to a per-pixel boundary, or if the edge is antialiased" — Pixelated / Antialiased.
9. **No handles on the Rectangle/Ellipse Select tools.** Neither tool page nor the keyboard table mentions nubs for these tools; resize nubs belong to Move Selection ("Resize the selection: Drag corner or edge nub", Move Tools section). Decision for PaintDotMac: no post-draw handles in this spec; adjusting a drawn selection is 0019 (Move Selection). See Open questions.
10. "Move selection while dragging: Drag + Left + Right Mouse Button" — not supported (0006's dispatcher ignores a second button mid-gesture); see Out of scope.

## User story

As a PaintDotMac user, I press S (S again for Ellipse Select), drag on the canvas, and get a rectangular or elliptical selection with marching ants; Shift makes it a square or circle; ⌘-drag adds, ⌥-drag subtracts, ⌘-right-drag inverts, ⌥-right-drag intersects (or I pick the mode in the toolbar); I can lock a ratio or an exact size; a click deselects; each change is a "Rectangle Select" / "Ellipse Select" / "Deselect" step I can undo; the status bar shows the selection's size; and ⇧⌘B zooms to the selection.

## Scope & changes

### Core (pure Swift, no AppKit/SwiftUI; unit-tested)

- **`Core/Tools/SelectionToolOptions.swift`** (new) — the shared selection-tool options and the modifier mapping. Lasso (0015) and Magic Wand (0016) reuse all of it except the draw-mode members.
  ```swift
  enum SelectionDrawMode: String, CaseIterable, Sendable, ToolOptionValue { case normal, fixedRatio, fixedSize
      var displayName: String }           // "Normal", "Fixed Ratio", "Fixed Size"
  enum SelectionQuality: String, CaseIterable, Sendable, ToolOptionValue { case pixelated, antialiased
      var displayName: String }           // "Pixelated", "Antialiased"
  extension SelectionCombineMode: ToolOptionValue {
      // displayName comes from 0013 ("Replace", "Add (Union)", "Subtract", "Intersect", "Invert (Xor)")
      var macModifierHint: String }       // "", "⌘-drag", "⌥-drag", "⌥-right-drag", "⌘-right-drag"
  extension MeasurementUnit: ToolOptionValue {}   // added here: 0004's MeasurementUnit is String-raw-valued and has no conformance yet
  enum SelectionToolOptions {
      // Shared by every selection tool (Paint.NET has one global selection mode and clipping mode):
      static let combineMode = ToolOptionKey<SelectionCombineMode>(tool: .rectangleSelect, name: "selectionMode", defaultValue: .replace)
      static let quality     = ToolOptionKey<SelectionQuality>(tool: .rectangleSelect, name: "selectionQuality", defaultValue: .antialiased)
      // Rectangle Select only:
      static let drawMode    = ToolOptionKey<SelectionDrawMode>(tool: .rectangleSelect, name: "drawMode", defaultValue: .normal)
      static let fixedWidth  = ToolOptionKey<Double>(tool: .rectangleSelect, name: "fixedWidth",  defaultValue: 4, range: 0.01...65535)
      static let fixedHeight = ToolOptionKey<Double>(tool: .rectangleSelect, name: "fixedHeight", defaultValue: 3, range: 0.01...65535)
      static let fixedUnit   = ToolOptionKey<MeasurementUnit>(tool: .rectangleSelect, name: "fixedUnit", defaultValue: .inches)

      static func combineMode(picker: SelectionCombineMode, button: ToolMouseButton, modifiers: ToolModifiers) -> SelectionCombineMode
      static func fixedSizeInPixels(width: Double, height: Double, unit: MeasurementUnit, dpi: Double) -> PixelSize
  }
  ```
  - The shared keys deliberately live under `tool.rectangleSelect.` (`tool.rectangleSelect.selectionMode`, `tool.rectangleSelect.selectionQuality`): every selection tool reads and writes these same two keys, so changing the mode in Ellipse Select also changes it for Rectangle Select, as in Paint.NET. Defaults: mode Replace, quality Antialiased (Paint.NET's default), draw mode Normal, 4 × 3 Inches (Paint.NET 3.36 `CreateDefault()`).
  - **`combineMode(picker:button:modifiers:)`** (Ctrl → ⌘, Alt → ⌥, right button = right-click or Control-click, which 0006 already delivers as `.secondary`): `⌘` held → `.union` for `.primary`, `.xor` for `.secondary`; else `⌥` held → `.exclude` for `.primary`, `.intersect` for `.secondary`; else `picker`. ⌘ wins over ⌥ when both are held (Paint.NET tests Ctrl first). Shift and Control don't affect the mode (Shift constrains the shape; Control only produced the secondary button).
  - **`fixedSizeInPixels`**: per axis `px = value` (pixels), `value × dpi` (inches), `value / 2.54 × dpi` (centimeters), with `dpi = MeasurementUnit.sanitizedDPI(dpi)`; then `Int(px.rounded(.toNearestOrAwayFromZero))` clamped to `1...65535` (`ImageLimits` max side). Non-finite → 1. (Paint.NET truncates; we round so that 2.54 cm at 96 DPI is exactly 96 px despite floating-point error. Implementation decision, not a product question.)

- **`Core/Tools/SelectionGesture.swift`** (new) — the gesture bookkeeping and Paint.NET's finish rule, shared by Rectangle, Ellipse, and Lasso (0015).
  ```swift
  enum SelectionGestureOutcome: Equatable, Sendable { case emit, clear, reset }
  struct SelectionGesture: Sendable, Equatable {
      static let tooQuickInterval: TimeInterval = 0.05            // Paint.NET: held ≤ 50 ms
      let mode: SelectionCombineMode
      let anchorPixel: PixelPoint
      let startTimestamp: TimeInterval
      private(set) var currentPixel: PixelPoint
      private(set) var hasMoved: Bool                              // false until currentPixel first differs from anchorPixel
      init?(event: ToolEvent, pickerMode: SelectionCombineMode)    // nil if event.location is non-finite
      mutating func update(with event: ToolEvent)                  // ignores non-finite locations
      static func pixel(for canvasPoint: CGPoint) -> PixelPoint?   // (floor x, floor y); nil if non-finite or |v| > 1e9
      static func outcome(mode: SelectionCombineMode, hasMoved: Bool, duration: TimeInterval, shapeIsEmpty: Bool) -> SelectionGestureOutcome
  }
  @MainActor enum SelectionCommit {
      static func finish(outcome: SelectionGestureOutcome, newSelection: Selection?, mode: SelectionCombineMode,
                         name: String, icon: HistoryIcon, context: any ToolContext)
      static func deselectIfNeeded(context: any ToolContext) -> Bool   // Return/Enter rule below
  }
  ```
  - `pixel(for:)` floors (the pixel under the pointer, the same convention as 0004's status-bar cursor: −0.5 → −1).
  - `hasMoved` deviates slightly from Paint.NET, which counts any mouse-move event: here it becomes `true` only once the pointer has entered a different **pixel** (sticky afterwards, even if the pointer returns to the anchor). At high zoom a jittery click therefore stays a click instead of a 1 × 1 selection.
  - **`outcome`** (Paint.NET's truth table): `mode == .replace` → `hasMoved && duration > tooQuickInterval && !shapeIsEmpty ? .emit : .clear`; any other mode → `!hasMoved || shapeIsEmpty ? .reset : .emit`. `duration` = mouse-up `timestamp` − `startTimestamp`.
  - **`finish`**:
    - `.emit`: `after = Selection.combine(context.selection, newSelection, mode: mode, canvasSize: context.image.size)` (for `.replace` this is `newSelection`); `context.performHistory(SelectionHistoryItem(name: name, icon: icon, before: context.selection, after: after))`. A result equal to the current selection (Union inside the selection, Exclude outside it) is a no-op item, so no step is added (D-34). A combined result with no selected pixels is `nil` (no selection, PRD E-3 / D-40).
    - `.clear`: if `context.selection != nil` → `context.performHistory(SelectionHistoryItem(name: "Deselect", icon: .deselect, before: context.selection, after: nil))` (exactly what Edit > Deselect records); else nothing.
    - `.reset`: nothing.
  - **`deselectIfNeeded(context:)`** — Paint.NET's "Enter deselects": if `context.selection != nil`, record the Deselect step (as in `.clear`) and return `true`; else return `false`. Rectangle and Ellipse Select call it from `keyDown` for `.returnKey`/`.enter` when no gesture is active (0013 has no global Return handling).

- **`Core/Tools/RectangleSelectTool.swift`** (new) — T-1. `final class RectangleSelectTool: Tool`, `id = .rectangleSelect`, `hasPendingEdit` false.
  - Pure geometry:
    ```swift
    struct RectangleSelectGeometry: Sendable, Equatable {
        var drawMode: SelectionDrawMode; var ratio: (w: Double, h: Double) /* Fixed Ratio */; var fixedPixelSize: PixelSize /* Fixed Size */
        static func rect(anchor a: PixelPoint, current b: PixelPoint, constrainSquare: Bool,
                         geometry: RectangleSelectGeometry, imageSize: PixelSize) -> PixelRect?   // nil = empty after clipping
    }
    ```
    (Make the tuple a small `struct SelectionRatio { var width: Double; var height: Double }` if `Equatable` synthesis needs it.)
    1. **Normal**: `w = |b.x − a.x| + 1`, `h = |b.y − a.y| + 1`. With `constrainSquare`: `w = h = min(w, h)`. Anchoring (used by Shift and Fixed Ratio): `x0 = b.x >= a.x ? a.x : a.x − w + 1`, `y0 = b.y >= a.y ? a.y : a.y − h + 1`. (Without Shift this equals `min(a.x, b.x)`.)
    2. **Fixed Ratio** (Shift ignored): `ex = |b.x − a.x| + 1`, `ey = |b.y − a.y| + 1`, `s = min(ex / ratio.w, ey / ratio.h)`, `w = max(1, Int((s × ratio.w).rounded(.toNearestOrAwayFromZero)))`, `h` likewise; anchored as above.
    3. **Fixed Size** (Shift ignored): `(x0, y0) = b` (the top-left follows the pointer), `(w, h) = fixedPixelSize`.
    4. Intersect `(x0, y0, w, h)` with `(0, 0, imageSize)`; empty → `nil`. All arithmetic in `Int` with `w, h ≤ 65535 + 1` and coordinates bounded by `pixel(for:)`'s 1e9 limit (no overflow).
  - State: `gesture: SelectionGesture?`, `lastModifiers: ToolModifiers`.
  - `mouseDown`: `gesture = SelectionGesture(event:, pickerMode: options.value(SelectionToolOptions.combineMode))` with the mode from `SelectionToolOptions.combineMode(picker:button:modifiers:)`; update the preview.
  - `mouseDragged`: `gesture.update`; update the preview. `flagsChanged(_:context:)`: store the modifiers; if a gesture is active, recompute the preview with the new Shift state (the mode stays latched); always `invalidateCursor()`.
  - **Preview**: `context.setOverlay(.selectionShape(SelectionShapePreview(shape: .rectangle, rect: r, hidesCurrentSelection: mode == .replace)))` with `r = rect(...)`, or `setOverlay(nil)` when `r` is `nil`. No selection is built and nothing is rasterized while dragging (keeps drags cheap at any image size). In Replace mode the current selection's ants are hidden during the drag (Paint.NET resets the selection at mouse-down; ours is only hidden, so Escape restores it).
  - `mouseUp`: final `update`; `r = rect(...)` (Shift from the event's modifiers); `outcome(mode:hasMoved:duration:shapeIsEmpty: r == nil)`; `newSelection = r.flatMap { Selection(rect: CGRect($0), canvasSize: context.image.size, antialiased: options.value(SelectionToolOptions.quality) == .antialiased) }`; `SelectionCommit.finish(... name: "Rectangle Select", icon: .rectangleSelect ...)`; `setOverlay(nil)`; `gesture = nil`.
  - `keyDown`: `.returnKey`/`.enter` with no gesture → `SelectionCommit.deselectIfNeeded` (returns its result); else the protocol default.
  - `cancel`: `setOverlay(nil)`, `gesture = nil` (no step; the selection is untouched). `deactivate`: same.
  - `cursor`: `.crosshair` (Paint.NET's plus/minus cursor variants are not reproduced).
  - Never changes pixels.

- **`Core/Tools/EllipseSelectTool.swift`** (new) — T-3. Same structure, `id = .ellipseSelect`, no draw-mode options.
  ```swift
  enum EllipseSelectGeometry {
      static func boundingRect(anchor a: PixelPoint, current b: PixelPoint, constrainCircle: Bool) -> PixelRect   // unclipped, w,h ≥ 1
      static func isEmpty(_ r: PixelRect, imageSize: PixelSize) -> Bool                                         // r ∩ image is empty
  }
  ```
  - Without Shift: the pixel-inclusive rectangle of rule 1 (`min`, `|Δ| + 1`).
  - With Shift (circle, Paint.NET): `cx = Double(a.x + b.x) / 2 + 0.5`, `cy = Double(a.y + b.y) / 2 + 0.5` (center between the two pixel centers; `Double` division, not integer), `d = Int(hypot(Double(b.x − a.x), Double(b.y − a.y)).rounded(.toNearestOrAwayFromZero)) + 1`, `x0 = Int((cx − Double(d) / 2).rounded(.down))`, `y0 = Int((cy − Double(d) / 2).rounded(.down))`, rect `(x0, y0, d, d)`.
  - `newSelection = Selection(path: CGPath(ellipseIn: CGRect(r), transform: nil), canvasSize: context.image.size, antialiased: quality == .antialiased)` on the **unclipped** rect, so an ellipse that runs past the canvas edge keeps its true shape; 0013's `Selection.init?(path:…)` clips the path to the canvas before `MaskRasterizer` rasterizes it. With quality Antialiased the edge pixels get fractional coverage; Pixelated gives 0/255 per 0013's rule. The marching ants follow the path ∩ canvas as 0013 draws them.
  - `shapeIsEmpty` = `isEmpty(r, imageSize:)`. Preview `.selectionShape(… shape: .ellipse, rect: r …)` on the unclipped rect. History name **"Ellipse Select"**, icon `.ellipseSelect`. Everything else (mode latch, Shift live, finish rule, Return/Enter, cancel, cursor) as Rectangle Select.

- **`Core/Tools/ToolContext.swift` / `ToolOverlay`** (extend 0006): add
  ```swift
  struct SelectionShapePreview: Sendable, Equatable { enum Shape: Sendable { case rectangle, ellipse }
      var shape: Shape; var rect: PixelRect; var hidesCurrentSelection: Bool }
  case selectionShape(SelectionShapePreview)    // new ToolOverlay case
  ```
- **Selection bounds** — use 0013's `selection.bounds` (mask-tight `PixelRect`); "no selection" is `selection == nil`. Below, `selectionBounds` means `state.selection?.bounds`.
- **Status-bar size decision** — `enum SelectionSizeDisplay { static func size(preview: SelectionShapePreview?, selectionBounds: PixelRect?, imageSize: PixelSize) -> PixelSize? }` (in `SelectionGesture.swift`): a preview wins — its rect ∩ image, as a size (`nil` if empty); else `selectionBounds?.size`; else `nil`. (Paint.NET shows the size live while dragging.)
- **Zoom to Selection math** — add next to 0004's `fittedToWindow` (same file, same style):
  `func zoomedToFit(_ rect: CGRect, viewSize: CGSize, imageSize: PixelSize) -> CanvasTransform` — zoom `ZoomLevels.fitZoom(contentSize: rect.size, viewportSize: viewSize × backingScale, allowsEnlargement: true)` (clamped 1 %–3200 % by `fitZoom`), `center = (rect.midX, rect.midY)`, then `clampedScroll(viewSize:imageSize:)`. A rect with a zero or non-finite side, or a zero view size, returns `self` unchanged.
- **`ToolRegistry.standard()`** (modify): register `.rectangleSelect → RectangleSelectTool()` and `.ellipseSelect → EllipseSelectTool()`. S now cycles Rectangle Select → Ellipse Select (only implemented tools cycle; 0015/0016 slot Lasso and Magic Wand in by `ToolID.allCases` order with no further change). The Tools panel shows the Selection section with these two buttons.

### Platform glue (AppKit/SwiftUI; UI tests and manual checks)

- **`UI/SelectionToolOptionsView.swift`** (new) — SwiftUI, reads/writes through `model.toolOptions`; `init(model: AppModel, showsDrawMode: Bool)`. 0015/0016 reuse it with `showsDrawMode: false`. Left to right:
  1. **Selection mode** — `Picker` (`.menu` style), `.help("Selection mode")`, items `SelectionCombineMode.allCases` in Paint.NET order Replace, Add (Union), Subtract, Intersect, Invert (Xor); each item shows `displayName` and, dimmed, `macModifierHint`. Accessibility identifier `toolOptions.selectionMode`, value = selected `displayName`.
  2. **Selection clipping** — segmented `Picker` "Pixelated" / "Antialiased", `.help("Selection clipping mode")`, identifier `toolOptions.selectionQuality`.
  3. Only when `showsDrawMode`: a `Divider`, **Drawing mode** popup "Normal" / "Fixed Ratio" / "Fixed Size" (`toolOptions.drawMode`); when not Normal, **Width** and **Height** numeric fields (decimals allowed, up to 2 fraction digits shown, clamped to 0.01–65535 on commit, non-numeric input reverts; `toolOptions.fixedWidth`, `toolOptions.fixedHeight`), a **swap** button (`arrow.left.arrow.right`, `.help("Swap width and height")`, `toolOptions.fixedSwap`); and, for Fixed Size only, a **Units** popup Pixels / Inches / Centimeters (`toolOptions.fixedUnit`). Fields call the bar's `onEndEditing` on Return/Escape (0006).
- **`UI/ToolOptionsBar.swift`** (modify): `case .rectangleSelect: SelectionToolOptionsView(model:, showsDrawMode: true)`; `case .ellipseSelect: SelectionToolOptionsView(model:, showsDrawMode: false)`.
- **`Canvas/ToolOverlayView.swift`** (modify): draw `.selectionShape(p)`: `transform.pixelRectToView(p.rect)` (for an ellipse, the inscribed ellipse of that view rect), stroked in the `.zoomRectangle` style (1 pt white line under a 1 pt black line dashed `[4, 4]`, static).
- **`Canvas/MarchingAntsOverlay.swift`** (modify 0013's): hide the current selection's ants while the tool overlay is a `.selectionShape` with `hidesCurrentSelection == true`; show them again when the overlay changes.
- **`Canvas/CanvasToolSession.swift`** (modify): when `setOverlay` receives a `.selectionShape` or `nil`, and whenever `UndoBridge.onStateChange` fires (any step, undo, redo, jump), set the window's `StatusBarModel.selectionSize = SelectionSizeDisplay.size(preview:selectionBounds: state.selection?.bounds, imageSize:)`. On open/new/revert it starts from the document's selection (`nil` for a fresh document).
- **`Canvas/CanvasNavigation.swift`** (modify): `func zoomToSelection(_ bounds: PixelRect)` → `zoomedToFit(CGRect(bounds), …)`, then the usual after-transform-change path (redraw, status-bar zoom).
- **`App/MainMenu.swift`** (modify): View menu item **"Zoom to Selection"**, key equivalent `b` with ⇧⌘, action `zoomToSelection(_:)`, target `nil`, identifier `menu.view.zoomToSelection`, inserted between "Zoom to Window" and "Actual Size" (Paint.NET order: Zoom In, Zoom Out, Zoom to Window, Zoom to Selection, Actual Size). Update 0004's `MainMenuTests`/`testViewMenuItemsAndShortcuts` expectations to include it.
- **`Document/DocumentWindowController.swift`** (modify): `@objc zoomToSelection(_:)` → `navigation.zoomToSelection(selection.bounds)` when `undoBridge.state.selection` is non-nil; `validateMenuItem`: enabled iff `undoBridge.state.selection != nil` (decision: disabled with no selection — see Open questions).
- **`PaintDotMacTests/Support/FakeToolContext.swift`**: no change needed (0013 already backs `selection` with the fake's `DocumentState`; `overlays` recorded as before).
- **`project.yml`**: no target changes; run `xcodegen generate` (new files).
- **PRD.md / AGENTS.md**: no changes in this spec (the decisions it records are listed under Open questions for the batch owner to confirm and copy into PRD §12).

## Acceptance criteria

- [ ] S selects Rectangle Select; S again within 1 s selects Ellipse Select; again → Rectangle Select (only implemented tools cycle). Both show in the Tools panel's Selection section. → `ToolRegistryTests.selectionGroupHasRectangleAndEllipse`; UI `SelectionToolsUITests.testSKeyCyclesSelectionTools`
- [ ] Dragging with Rectangle Select creates a rectangular selection from the start pixel to the pixel under the pointer, inclusive, clipped to the canvas, with integer edges; history step "Rectangle Select". → `RectangleSelectGeometryTests.normal*`, `.clipping*`, `RectangleSelectToolTests.dragEmitsRectangleSelect`; UI `testRectangleSelectClipsPainting`
- [ ] Dragging with Ellipse Select creates the inscribed ellipse with antialiased edges (Antialiased) or hard edges (Pixelated); history step "Ellipse Select". → `EllipseSelectGeometryTests.*`, `EllipseSelectToolTests.antialiasedMask`, `.pixelatedMask`; UI `testEllipseSelectAddsStep`
- [ ] Shift makes a square (anchored at the start pixel) / a circle (diameter = start-to-pointer distance), and toggling Shift mid-drag updates the preview. → `RectangleSelectGeometryTests.shiftSquare*`, `EllipseSelectGeometryTests.shiftCircle*`, `RectangleSelectToolTests.shiftToggledMidDrag`
- [ ] Mode mapping: ⌘ + left = Add (union), ⌥ + left = Subtract, ⌘ + right (or ⌘ + Control-click) = Invert (xor), ⌥ + right = Intersect, otherwise the toolbar mode; ⌘ wins over ⌥; the mode is fixed at mouse-down. → `SelectionToolOptionsTests.combineModeTable`, `RectangleSelectToolTests.modeLatchedAtMouseDown`; UI `testCommandDragAddsToSelection`
- [ ] All five modes combine correctly with the existing selection, from the picker and from modifiers. → `RectangleSelectToolTests.combineModes`
- [ ] Fixed Ratio keeps width:height; Fixed Size gives exactly the size (converted from in/cm with the document DPI) and follows the pointer. → `RectangleSelectGeometryTests.fixedRatio*`, `.fixedSize*`, `SelectionToolOptionsTests.fixedSizeInPixels*`; UI `testFixedSizeSelection`
- [ ] Click without drag (or a Replace drag ≤ 50 ms, or a shape entirely off the canvas) in Replace mode deselects with a "Deselect" step, or does nothing when nothing was selected; in the other modes it changes nothing and adds no step. → `SelectionGestureTests.outcomeTable`, `RectangleSelectToolTests.clickDeselects`, `.clickWithoutSelectionAddsNothing`, `.appendClickIsNoOp`; UI `testClickDeselects`
- [ ] Return/Enter with a selection tool active deselects ("Deselect" step). → `RectangleSelectToolTests.returnDeselects`
- [ ] Escape mid-drag cancels: no step, previous selection unchanged and visible again. → `RectangleSelectToolTests.escapeCancels`
- [ ] Undo/redo restore the exact previous/next selection mask. → `SelectionToolsIntegrationTests.undoRedoRestoresMasks`
- [ ] Options (mode, clipping, draw mode, width, height, units) persist across relaunch; mode and clipping are shared between Rectangle and Ellipse Select. → `SelectionToolOptionsTests.keysAndDefaults`, `.sharedKeys`; UI `testOptionsPersistAndAreShared`
- [ ] Status bar `statusBar.selectionSize` shows the selection's bounds size ("W × H" in the chosen unit) live while dragging and after commit/undo/redo, and is empty with no selection. → `SelectionSizeDisplayTests.*` (bounds come from 0013's `SelectionMaskTests.boundsAreTight`); UI `testFixedSizeSelection`, `testClickDeselects`
- [ ] View > Zoom to Selection (⇧⌘B), between Zoom to Window and Actual Size, fits the selection bounds into the window (enlarging up to 3200 %) and centers it; disabled with no selection. → `CanvasTransformZoomToFitTests.*`; UI `testZoomToSelection`, `testViewMenuItemsAndShortcuts` (updated)
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report. → quality-gate launch smoke (`quality-gate.sh`)

## Edge cases

- **1 × 1 image**: any drag inside gives the 1 × 1 rect `(0,0,1,1)`; Shift circle on a 1 × 1 canvas is not empty. → `RectangleSelectGeometryTests.tinyImage`, `EllipseSelectGeometryTests.tinyImage`
- **Drag starting or ending outside the canvas** (negative or ≥ size pixels): clipped; fully outside → empty → Replace clears (Deselect if needed), other modes no-op. → `RectangleSelectGeometryTests.clippingPartial`, `.clippingFullyOutside`, `RectangleSelectToolTests.offCanvasReplaceDeselects`
- **Ellipse partly outside the canvas**: the path keeps its full shape; the mask is clipped by 0013; `selection.bounds` is clipped. → `EllipseSelectToolTests.ellipsePastEdge`
- **Dragging back to the anchor pixel**: `hasMoved` stays `true`; the 1 × 1 selection is emitted. → `SelectionGestureTests.hasMovedIsSticky`
- **Sub-pixel jitter within the anchor pixel** (high zoom): still a click. → `SelectionGestureTests.jitterInsidePixelIsNotMove`
- **Union inside the selection / Exclude outside it**: no change → no step (D-34). → `RectangleSelectToolTests.noEffectAddsNoStep`
- **Exclude or Intersect leaving nothing selected**: a step is recorded (it changed the selection) and the result is "no selection" per 0013; status bar empty. → `RectangleSelectToolTests.excludeEverything`
- **Fixed Size larger than the canvas or past its edge**: clipped; bigger than 65,535 px after unit conversion → clamped to 65,535. → `RectangleSelectGeometryTests.fixedSizeClipped`, `SelectionToolOptionsTests.fixedSizeClamped`
- **Fixed Ratio with a zero-length drag on one axis**: extent is ≥ 1 pixel per axis, so `s ≥ 1 / ratio` and `w, h ≥ 1`. → `RectangleSelectGeometryTests.fixedRatioThinDrag`
- **Bad stored options** (negative, zero, NaN width/height, unknown enum raw value): `ToolOptionKey` sanitize/default; DPI ≤ 0 → 96. → `SelectionToolOptionsTests.sanitization`
- **Non-finite or enormous event locations** (±1e300, NaN): dropped by `pixel(for:)`; no crash, no overflow. → `SelectionGestureTests.nonFiniteAndHugeLocations`
- **Huge image (65,535 × 65,535) Select-All-sized rectangle**: no per-drag rasterization; one mask build at mouse-up through 0013's sparse mask. → `RectangleSelectToolTests.hugeImageSelection` (asserts `selection?.bounds` and a few mask samples; time-boxed, see Performance)
- **Right-button drag with no modifier**: toolbar mode (same as left). Second button mid-drag: ignored by the dispatcher (no "move while drawing"). → `SelectionToolOptionsTests.combineModeTable`
- **Tool switch / document switch mid-drag**: the dispatcher defers the switch / cancels the gesture; no step, overlay cleared. → `RectangleSelectToolTests.contextSwitchCancels` (through `ToolDispatcher` + `FakeToolContext`)
- **Zoom to Selection on a 1 × 1 selection**: zoom clamps to 3200 %; on a selection larger than the window: fits below 100 %; zero view size: no change. → `CanvasTransformZoomToFitTests.*`
- **No document window**: Zoom to Selection has no target → disabled by AppKit. → manual (responder-chain validation with no window; nothing to unit-test)

## Test plan

Expected values below are hand-computed from the formulas in this spec (Paint.NET's rules), never from running the code.

- **Unit tests**
  - `PaintDotMacTests/Tools/SelectionToolOptionsTests.swift`
    - `combineModeTable`: for picker ∈ {replace, intersect} and every (button, modifiers) row: (primary, []) → picker; (secondary, []) → picker; (secondary, [.control]) → picker; (primary, [.command]) → union; (primary, [.option]) → exclude; (secondary, [.command]) → xor; (secondary, [.option]) → intersect; (secondary, [.command, .control]) → xor; (primary, [.command, .option]) → union; (secondary, [.command, .option]) → xor; (primary, [.shift]) → picker; (primary, [.shift, .option]) → exclude.
    - `keysAndDefaults`: defaults keys exactly `tool.rectangleSelect.selectionMode`, `.selectionQuality`, `.drawMode`, `.fixedWidth`, `.fixedHeight`, `.fixedUnit`; defaults `.replace`, `.antialiased`, `.normal`, 4, 3, `.inches`; display names exactly "Replace", "Add (union)", "Subtract", "Intersect", "Invert (xor)", "Pixelated", "Antialiased", "Normal", "Fixed Ratio", "Fixed Size".
    - `sharedKeys`: writing the mode through an `InMemoryToolOptionStore` and reading it from an `EllipseSelectTool` gesture uses the written mode.
    - `sanitization`: stored `-5`, `0`, `NaN` width → 0.01 / 0.01 / default 4; stored `"bogus"` mode → `.replace`.
    - `fixedSizeInPixelsBasics`: (100, 50, px, 72) → 100 × 50; (4, 3, in, 96) → 384 × 288; (2.54, 1.27, cm, 96) → 96 × 48; (1, 1, in, 0) → 96 × 96 (DPI sanitized); (0.4, 0.4, px, 96) → 1 × 1. `fixedSizeClamped`: (1000, 1, in, 300) → 65535 × 300; (NaN, 1, px, 96) → 1 × 1.
  - `PaintDotMacTests/Tools/SelectionGestureTests.swift`
    - `pixelFloors`: (3.99, 0.0) → (3, 0); (−0.5, −0.01) → (−1, −1); NaN → nil; 2e9 → nil.
    - `outcomeTable`: all 2 × 2 × 2 × 2 combinations of (replace/union, hasMoved, duration 0.03/0.2, empty) → replace: emit only for (moved, 0.2, non-empty), else clear; union: reset when !moved or empty, else emit (duration irrelevant). Spot-check exclude/intersect/xor behave like union. Boundary: duration exactly 0.05 → replace clears.
    - `hasMovedIsSticky`, `jitterInsidePixelIsNotMove` (down at (10.1, 10.1), drags to (10.9, 10.8) → `hasMoved == false`; then (11.0, 10.5) → true; back to (10.2, 10.2) → still true).
    - `nonFiniteAndHugeLocations`: `init?` returns nil for NaN; `update` with NaN or 1e300 leaves `currentPixel` unchanged.
  - `PaintDotMacTests/Tools/RectangleSelectGeometryTests.swift` (image 100 × 80 unless stated)
    - `normalForwardAndBackward`: a (10,10), b (20,14) → (10,10,11,5); a (20,14), b (10,10) → (10,10,11,5); a = b (5,5) → (5,5,1,1).
    - `shiftSquare`: a (10,10), b (20,14) → (10,10,5,5); a (10,10), b (4,30) → (4,10,7,7); a (10,10), b (0,0) → (0,0,11,11).
    - `fixedRatio`: ratio 4:3, a (0,0), b (39,39) → (0,0,40,30); a (50,50), b (30,55) → ex 21, ey 6, s 2 → (43,50,8,6). `fixedRatioThinDrag`: ratio 4:3, a = b = (10,10) → s = min(1/4, 1/3) = 0.25 → w = 1, h = round(0.75) = 1 → (10,10,1,1). Shift ignored in Fixed Ratio.
    - `fixedSize`: size 30 × 20, a (0,0), b (10,20) → (10,20,30,20); `fixedSizeClipped`: b (90,70) → (90,70,10,10); size 500 × 500 at b (0,0) → (0,0,100,80).
    - `clippingPartial`: a (90,70), b (120,100) → (90,70,10,10); a (−5,−5), b (4,4) → (0,0,5,5). `clippingFullyOutside`: a (−50,−50), b (−10,−10) → nil; a (100,0), b (120,10) → nil (x = 100 is outside a 100-wide image).
    - `tinyImage`: image 1 × 1, a (0,0), b (3,−2) → (0,0,1,1).
  - `PaintDotMacTests/Tools/EllipseSelectGeometryTests.swift`
    - `boundingRectNormal`: a (2,3), b (11,8) → (2,3,10,6). `shiftCircle`: a (0,0), b (6,8) → d = 11, cx 3.5, cy 4.5 → (−2,−1,11,11); a (0,0), b (0,0) → (0,0,1,1); a (10,10), b (13,14) → d = 6, cx 12, cy 12.5 → (9,9,6,6).
    - `isEmpty`: (−20,−20,10,10) on 100 × 80 → true; (−5,−5,10,10) → false. `tinyImage`: 1 × 1 image, Shift circle a = b = (0,0) → not empty.
  - `PaintDotMacTests/Tools/RectangleSelectToolTests.swift` (`@MainActor`, `FakeToolContext` with a 64 × 64 image, no selection (`nil`), an `InMemoryToolOptionStore`; events with explicit timestamps 1.0 → 1.2 unless stated)
    - `dragEmitsRectangleSelect`: down (4.2, 6.7), drag (9.5, 12.1), up (9.5, 12.1) → one history step "Rectangle Select", icon `.rectangleSelect`; the selection mask is 255 exactly on x 4…9, y 6…12 and 0 elsewhere (checked on all 64 × 64 pixels); `selection?.bounds == (4,6,6,7)`; overlays recorded: `.selectionShape(rect (4,6,6,7), hidesCurrentSelection: true)` then `nil`.
    - `combineModes`: existing selection = pixelated rect (0,0,16,16); drag (8,8)→(23,23) with picker set to each mode → Replace: only (8,8,16,16); Union: union of both; Exclude: existing minus overlap; Intersect: (8,8,8,8); Xor: union minus overlap — compared pixel by pixel against set algebra on two oracle boolean masks built in the test.
    - `modeLatchedAtMouseDown`: down with `.command` (union), drag and up without it → Union result; down with secondary + `.option`, up with nothing → Intersect.
    - `shiftToggledMidDrag`: down (10,10), drag (20,14) → overlay rect (10,10,11,5); `flagsChanged([.shift])` → overlay rect (10,10,5,5) without a new pointer event; up with `.shift` → selection (10,10,5,5).
    - `clickDeselects`: existing selection (0,0,16,16); down/up at (30,30), no drag → one step "Deselect", icon `.deselect`, `selection == nil`. `quickDragDeselects`: drag (0,0)→(20,20) with up at 1.04 s → "Deselect". `clickWithoutSelectionAddsNothing`: no selection, click → no step. `appendClickIsNoOp`: with existing selection, ⌘-click → no step, selection identical.
    - `offCanvasReplaceDeselects`: existing selection, drag (−30,−30)→(−5,−5) → "Deselect"; with ⌥ → no step.
    - `noEffectAddsNoStep`: existing (0,0,32,32), ⌘-drag (4,4)→(10,10) → no new step (D-34).
    - `excludeEverything`: existing (8,8,8,8), ⌥-drag (0,0)→(40,40) → step "Rectangle Select", `selection == nil`.
    - `returnDeselects`: existing selection, `keyDown(.returnKey)` → returns true, step "Deselect"; with no selection → returns false, no step. `.enter` same.
    - `escapeCancels`: existing selection S0; down, drag, dispatcher Escape → `cancel` → no step, selection == S0, last overlay `nil`.
    - `contextSwitchCancels`: through `ToolDispatcher`, start a drag, `setContext(otherFake)` → no step in the first fake, overlay cleared.
    - `undoRedo`: after `dragEmitsRectangleSelect`, undo → `selection == nil`; redo → identical mask.
    - `hugeImageSelection`: 65,535 × 65,535 sparse image (0002 tiles), drag (0,0)→(65534,65534) → `selection?.bounds == (0,0,65535,65535)`, mask samples at (0,0), (32767,32767), (65534,65534) = 255. No per-drag work on the selection: before mouse-up the fake has recorded no `performHistory` call and only `.selectionShape` overlays; the 0013 rectangle fast path makes every interior tile `.full` (`selection?.mask.partialTileCount == 0`).
  - `PaintDotMacTests/Tools/EllipseSelectToolTests.swift`
    - `antialiasedMask`: quality Antialiased, drag (10,10)→(29,29) (rect (10,10,20,20), circle radius 10 centered (20,20)) → step "Ellipse Select"; mask (20,20) = 255; corners (10,10), (29,10), (10,29), (29,29) = 0; mirror symmetry `m(x,y) == m(39−x, y) == m(x, 39−y) == m(y, x)` for all pixels in the rect; at least one pixel on row 10 strictly between 0 and 255; total coverage Σm/255 within 1 % of π·10² = 314.16.
    - `pixelatedMask`: same drag with Pixelated → every mask value is 0 or 255, same symmetry, count of 255s within 3 % of 314.
    - `ellipsePastEdge`: 64 × 64 image, drag (40,40)→(79,79) (circle centered (60,60), r 20) → `selection != nil`, `selection?.bounds == (40,40,24,24)`; mask (63,63) = 255 (pixel center (63.5,63.5): 3.5² + 3.5² = 24.5 < 400) and (40,40) = 0 (19.5² × 2 = 760.5 > 400).
    - `shiftCircleAndOptionsIgnored`: drawMode Fixed Size set in options has no effect on Ellipse Select; Shift drag a (0,0) b (6,8) previews rect (−2,−1,11,11).
  - `PaintDotMacTests/Tools/SelectionSizeDisplayTests.swift`: preview (90,70,30,30) on 100 × 80 with bounds (0,0,5,5) → 10 × 10 (preview wins, clipped); preview fully outside → nil; no preview, bounds (1,2,3,4) → 3 × 4; neither → nil.
  - `PaintDotMacTests/Rendering/CanvasTransformZoomToFitTests.swift`: image 1000 × 800, view 500 × 400 pt, backing 2: rect (100,100,250,200) → zoom = min(1000/250, 800/200) = 4.0, center (225, 200); rect (0,0,1,1) → 32 (clamped), center (0.5, 0.5) then clamped by `clampedScroll` (assert equal to applying 0004's `clampedScroll` to the unclamped transform); rect (0,0,1000,800) → 1.0, centered; backing 1 with the same rect (100,100,250,200) → 2.0; zero-width rect, NaN rect, zero view size → transform unchanged.
  - `PaintDotMacTests/Tools/ToolRegistryTests.swift` (extend): `selectionGroupHasRectangleAndEllipse`: `standard().shortcutGroup(for: "s") == [.rectangleSelect, .ellipseSelect]`; resolver from Rectangle with a second S at +0.5 s → Ellipse; third at +0.9 s → Rectangle; Shift+S fresh → Ellipse (the group's last).
- **Round-trip and property tests** — `PaintDotMacTests/Tools/SelectionToolPropertyTests.swift` (`SeededRandom`, seed printed on failure, 300 iterations): random image size 1…300 per side, random anchor/current in −50…350, random Shift/draw mode/ratio → `RectangleSelectGeometry.rect` is nil or lies inside the image with w, h ≥ 1; Normal without Shift and with both points inside the image covers both pixels; Shift result is square unless clipped; Fixed Ratio result before clipping has `|w/h − ratio| ≤ 1/min(w,h)`. Random modes: perform then undo restores the exact previous mask; redo restores the exact new mask; Union then Exclude of the same rect with no selection → `nil`.
- **Integration tests** (headless) — `PaintDotMacTests/Integration/SelectionToolsIntegrationTests.swift`: `undoRedoRestoresMasks`: 0005 "New Image" 200 × 150 `DocumentState` + `HistoryStack` behind `FakeToolContext`; script: Rectangle drag (10,10)→(59,49); Ellipse ⌘-drag (40,30)→(119,89); Rectangle ⌥-drag (0,0)→(29,29); click (Deselect) → history names `["New Image","Rectangle Select","Ellipse Select","Rectangle Select","Deselect"]`; undo ×4 → `selection == nil`; redo ×4 stepwise, comparing each mask with the one captured after the corresponding forward step; finally 0009 Paintbrush stroke across the canvas with the second-to-last selection active is clipped (pixel at (5,5) outside unchanged, (45,20) inside painted).
- **UI tests** — `PaintDotMacUITests/SelectionToolsUITests.swift` (fixtures generated at test time by `UITestApp`; reset defaults):
  - `testSKeyCyclesSelectionTools`: type `s` → `tool.rectangleSelect` selected; `s` → `tool.ellipseSelect`; `s` → `tool.rectangleSelect`; `toolOptions.selectionMode` value "Replace"; `toolOptions.drawMode` exists for Rectangle and not for Ellipse.
  - `testRectangleSelectClipsPainting`: open a 4000 × 2000 opaque gray (128,128,128) PNG (opens fitted); `s`; `dragOnCanvas(from: (0.10, 0.40), to: (0.40, 0.60))` → History row "Rectangle Select", Edit menu "Undo Rectangle Select" enabled; read `statusBar.selectionSize` "W × H" (W, H > 0). Press `b`, set width 20, drag from (0.02, 0.5) to (0.98, 0.5); ⌘S; read the PNG: on row `imageHeight / 2` the pixels differing from (128,128,128,255) form exactly one contiguous run of length W.
  - `testEllipseSelectAddsStep`: `s s`, drag → History row "Ellipse Select"; ⌘Z → `statusBar.selectionSize` "" ; ⇧⌘Z → non-empty again.
  - `testCommandDragAddsToSelection`: drag (0.1,0.4)→(0.2,0.5); `XCUIElement.perform(withKeyModifiers: .command)` drag (0.6,0.4)→(0.7,0.5) → two "Rectangle Select" rows; selection width now > 4 × the first width (bounding box of both).
  - `testClickDeselects`: drag a selection, then click the canvas at (0.9, 0.9) → History row "Deselect", `statusBar.selectionSize` "".
  - `testFixedSizeSelection`: choose "Fixed Size" in `toolOptions.drawMode`, Units "Pixels", width 100, height 50 → drag (0.3,0.3)→(0.35,0.35) → `statusBar.selectionSize` exactly "100 × 50".
  - `testOptionsPersistAndAreShared`: in Ellipse Select choose "Subtract" and "Pixelated"; press `s` to Rectangle Select → `toolOptions.selectionMode` "Subtract", `toolOptions.selectionQuality` "Pixelated"; relaunch without reset → still "Subtract"; Fixed Size 100 × 50 px still set.
  - `testZoomToSelection`: open the View menu with no selection → "Zoom to Selection" exists between "Zoom to Window" and "Actual Size" and is disabled; draw a small selection → ⇧⌘B → `statusBar.zoom` value is larger than before (parse the percent).
  - Update 0004's `testViewMenuItemsAndShortcuts` to the five-item order.
- **Performance** (NF-1 smoothness): no rasterization per drag event (asserted in `hugeImageSelection`). `SelectionToolPerformanceTests` (XCTest `measure`): mouse-up of a 10,000 × 10,000 rectangle selection on a 10,000 × 10,000 image (0013's rectangle fast path) — report only, no gate (0013 sets targets only for 4000 × 3000).
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build with no warnings, all tests pass, none skipped, UI tests ran, launch smoke passes.
- **Manual verification**
  1. Draw rectangle selections at 100 %, 800 %, and 3200 %: edges land exactly on pixel boundaries; the dashed preview follows the pointer; marching ants appear on release.
  2. Draw an ellipse with Antialiased, fill it with the Paintbrush: smooth edge; repeat with Pixelated: stair-stepped edge.
  3. Hold and release Shift mid-drag: the preview snaps between free and square/circle immediately.
  4. ⌘-drag, ⌥-drag, ⌘-right-drag, ⌥-right-drag, and ⌘-Control-drag on a trackpad: Add, Subtract, Invert, Intersect, Invert.
  5. With a selection, Replace-drag a new one: the old ants disappear during the drag; press Escape mid-drag: the old ants come back, no history row.
  6. Click outside the image (gray area) with a selection: "Deselect".
  7. Fixed Ratio 16:9: drag in all four directions; the rectangle grows from the start corner.
  8. ⇧⌘B on a small selection at the canvas edge: the selection is as large as possible and as centered as the image edges allow.

## Open questions

These have a recommended answer already written into the spec; the implementer follows the spec unless the user decides otherwise. The batch owner should confirm them and copy them into PRD §12.

1. **No post-draw handles on Rectangle/Ellipse Select.** Paint.NET's docs list resize nubs only for the Move tools; resizing a drawn selection is 0019 (Move Selection). Recommended: keep it so for v1.0.
2. **Zoom to Selection with no selection is disabled** (Paint.NET may treat "no selection" as the whole image). Recommended: disabled — ⌘B already covers the whole image.
3. **`hasMoved` counts pixel changes, not raw mouse events** (a small deviation from Paint.NET 3.36 that avoids accidental 1 × 1 selections at high zoom). Recommended: keep.
4. **The selection mode and clipping options are shared across selection tools** and stored under `tool.rectangleSelect.*`. Recommended: keep (Paint.NET has one global selection mode).

## Out of scope

- Lasso Select (T-2) → 0015; Magic Wand (T-4) → 0016 (both reuse `SelectionToolOptions`, `SelectionGesture`, `SelectionCommit`, and `SelectionToolOptionsView`).
- Selection model, mask rasterization, marching ants, Select All / Deselect / Invert Selection menu items → 0013.
- Moving or resizing a selection outline (nubs, arrow-key nudging) → 0019; Move Selected Pixels → 0020.
- Paint.NET's "move the shape while drawing" (left + right button together) — not in v1.0 (0006's dispatcher allows one button per gesture).
- Paint.NET's plus/minus selection cursors (we show the crosshair in every mode).
- Live combined preview of the resulting selection while dragging (we preview the drawn shape only; the combined result appears on release).
- Erase/Fill Selection → 0018; Crop to Selection → 0022.
