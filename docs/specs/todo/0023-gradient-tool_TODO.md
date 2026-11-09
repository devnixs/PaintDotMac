# 0023 — Add the Gradient tool (five types, color and transparency modes, editable handles)

> Source: PRD.md §5.3 T-10 ("Gradient — G — Linear, linear reflected, diamond, radial, and conical types. Color mode and transparency mode."), TOOL-A (left = primary, right / Control-left = secondary), TOOL-B (painting is confined to the active selection), TOOL-C (settings persist), APP-4 (tool options bar; Finish button), §4 / NF-9 (straight RGBA8), NF-4 (undo stores changed tiles only), H-6 / D-34 (no-op edits add no step), D-15 (tool blend list = implemented layer blend modes), D-17 (`UserBlendOps` formulas), D-33 (color under alpha 0 preserved). Paint.NET docs: Gradient Tool, https://paint.net/doc/latest/GradientTool.html (old URL https://www.getpaint.net/doc/latest/GradientTool.html); Tool Bar, https://paint.net/doc/latest/Toolbar.html (Antialiasing, Blend Mode). Per-type formulas follow Paint.NET's open-source 3.36 `GradientRenderers` (`LinearClamped`, `LinearReflected`, `LinearDiamond`, `Radial`, `Conical`).
> Milestone: M2
> Depends on: 0013-selection-core-and-marching-ants (and through it 0011, 0009, 0008, 0007, 0006, 0003, 0002)

## Context

Not yet implemented: there is no application code. This spec builds on these types from lower-numbered specs (use their exact names and signatures):

- **0002**: `ColorRGBA8` (straight sRGB, `UInt8` r/g/b/a), `PixelSize`, `PixelRect` (half-open), `TileCoordinate`, `TiledSurface` (256×256 sparse COW tiles; `pixel(at:)`, `setPixel(_:at:)`, `tile(at:)`/`setTile(_:at:)`, `generation`, `changedTiles(since:)`; `Tile.sharesStorage(with:)`), `Layer` (`id`, `surface`, `isVisible`), `LayeredImage` (`size`, `layers`, `activeLayerIndex`), `BlendMode` (`.normal` only until 0026).
- **0003**: `CanvasTransform` with `canvasToView(_:)` / `viewToCanvas(_:)` (view space = AppKit points, bottom-left origin, unflipped).
- **0006** (`Core/Tools/`): `@MainActor protocol Tool` (`id`, `hasPendingEdit`, `activate`/`deactivate` (default deactivate commits a pending edit), `mouseDown/Dragged/Up/Moved(_:context:)`, `keyDown` default (Return/Enter commit, Escape cancel when `hasPendingEdit`), `cursor(at:modifiers:) -> ToolCursor`, `commit(context:)`, `cancel(context:)`, `optionsDidChange(context:)`), `ToolEvent` (`location` canvas space, image pixels, `Double`, top-left origin, y down; `viewLocation`; `button` `.primary`/`.secondary` — right button and Control-left arrive as `.secondary`; `modifiers` incl. `.shift`), `ToolContext` (`image`, `transform`, `options`, `setOverlay(_:)`, `invalidateCursor()`), `ToolOverlay`, `ToolCursor` (`.arrow, .crosshair, .openHand, .closedHand, …`), `ToolID.gradient`, the descriptor row `gradient | Gradient | g | fill | circle.lefthalf.filled | supportsPendingEdits false` (changed here), `ToolRegistry.standard()` factories, `ToolOptionKey`/`ToolOptionStore`/`ToolOptionValue` (String-raw-value enums opt in), `InMemoryToolOptionStore`, `ToolDispatcher.commitPendingEdit()`, `UI/ToolOptionsBar.swift` (`ToolOptionsContent` switch; Finish button `toolOptions.finish` shown iff `descriptor.supportsPendingEdits`, enabled iff `hasPendingToolEdit`; `ToolOptionsBar.showsFinish(for:)`), `Canvas/ToolOverlayView.swift`, `PaintDotMacTests/Support/FakeToolContext.swift`, `StubTool`.
- **0007**: `ToolContext.colors: ColorSelection` (`.primary` default `(0,0,0,255)`, `.secondary` default `(255,255,255,255)`).
- **0008**: `TileDiff.between(before:after:layerID:candidates:)` (`isEmpty`, `apply`, `revert`), `TileDiffHistoryItem(name:icon:diff:)` (no-op when `diff.isEmpty`), `HistoryIcon.gradient` (already a case), `ToolContext.commitHistory(_:)` (records an already-applied item), `ToolContext.updateImage(_:)` (live pixel writes; the app redraws changed tiles), `UndoBridge` (`prepareForNavigation` commits the active tool's pending edit before undo/redo/jump and before Edit/Image commands). **0020** routes undo/redo/jump and save (`undoBridge.prepareForSave()`) through `Tool.prepareForHistoryNavigation(context:)`, whose default commits a pending edit, and commands through `commit(context:)`; the Gradient keeps both defaults, so a pending gradient is committed before every one of them.
- **0009**: `BlendOps.mul255`, `BlendOps.blend(_:dst:src:opacity:)` (`Core/Rendering/BlendOps.swift`; Normal = exact straight-alpha source-over, `Sa == 0` → `dst` unchanged), `protocol BrushClipMask: Sendable { var bounds: PixelRect; func coverage(x:y:) -> UInt8 }`, `ToolContext.paintClipMask`, `BlendMode: ToolOptionValue`, the blend-mode popup pattern (`toolOptions.blendMode`, implemented `BlendMode` cases in L-3 order), the `toolOptions.antialiasing` toggle pattern, the brush-outline overlay pattern (`ToolOverlay` case + drawing in `ToolOverlayView`).
- **0010**: History panel; icon for `.gradient` (0010 maps every `HistoryIcon` case).
- **0013**: `Selection` / `SelectionMask` (conforms to `BrushClipMask`), `ToolContext.paintClipMask` returns `selection?.mask` (nil = no selection = everything paintable), `DocumentState.selection`, debug launch hook `-UITestSelectRect x,y,w,h`.

Paint.NET behavior being mirrored (GradientTool.html, quoted):
- Types: "There are seven types of gradient" — Linear, Linear (Reflected), Diamond, Radial, Conical, Spiral (Clockwise), Spiral (Anticlockwise). PRD T-10 covers the first five; the spirals are out of scope.
- Color mode (default): "a color gradient that affects all color channels and the alpha channel … it fades from the Primary color to the Secondary color." Right-button drag: "the roles of the Primary and Secondary colors will be reversed."
- Transparency mode: "will only affect the alpha channel of the active layer", fading "from the alpha value of the Primary color to the inverse of the alpha value of the Secondary color." "If the Right Mouse Button is used the gradient will transition in the opposite direction."
- After drawing, "the gradient can be adjusted by dragging the Control Nubs." "Right-clicking on a nub will swap the roles of the Primary and Secondary colors."
- Blend mode: the gradient is "reinterpreted as if the pixels were on their own layer with the layer blend mode set." (Toolbar.html: the tool blend mode "will mimic the tool being applied to a layer immediately above the active layer".)
- Repeat modes (No Repeat / Repeat Wrapped / Repeat Reflected) exist in Paint.NET 5 but are not in PRD T-10; this spec implements **No Repeat** only (Out of scope).

## User story

As a PaintDotMac user, I press **G**, choose a gradient type (Linear, Linear (Reflected), Diamond, Radial, Conical), Color Mode or Transparency Mode, antialiasing, and a blend mode in the tool options bar, and drag on the canvas: a gradient from the primary to the secondary color (right-drag: reversed) fills the active layer, confined to the selection. Shift snaps the angle to 15° steps. Two handles stay on the canvas so I can drag either end to adjust the gradient live, right-click a handle to swap the colors, and press Return (or Finish, or switch tools) to commit it as one "Gradient" step that ⌘Z undoes; Escape discards it.

## Scope & changes

### Core (headless, unit-tested)

- **`PaintDotMac/Core/Model/GradientRenderer.swift`** (new, pure; no AppKit):
  ```swift
  enum GradientType: String, CaseIterable, Sendable, ToolOptionValue {
      case linear, linearReflected, diamond, radial, conical
      var displayName: String   // "Linear", "Linear (Reflected)", "Diamond", "Radial", "Conical"
  }
  enum GradientMode: String, CaseIterable, Sendable, ToolOptionValue {
      case color, transparency
      var displayName: String   // "Color Mode", "Transparency Mode"
  }
  struct GradientParameters: Sendable, Equatable {
      var type: GradientType
      var mode: GradientMode
      var start: CGPoint          // canvas space (image pixels, Double, top-left origin, y down)
      var end: CGPoint
      var startColor: ColorRGBA8  // color at t = 0 (transparency mode: only .a is used)
      var endColor: ColorRGBA8    // color at t = 1 (transparency mode: only .a is used)
      var antialiasing: Bool
      var blendMode: BlendMode    // ignored in transparency mode
      var isDegenerate: Bool      // start == end, or any coordinate non-finite
  }
  enum GradientRenderer {
      /// Bounded gradient position t ∈ [0, 1] at canvas point (x, y). Precondition: !isDegenerate.
      static func position(_ type: GradientType, start: CGPoint, end: CGPoint, x: Double, y: Double) -> Double
      /// 8-bit weight: floor(clamp(t, 0, 1) · 255 + 0.5).
      static func weight(_ t: Double) -> UInt8
      /// Straight per-channel interpolation (all four channels): (a·(255 − w) + b·w + 127) / 255, integer.
      static func lerp(_ a: UInt8, _ b: UInt8, weight w: UInt8) -> UInt8
      static func lerp(_ a: ColorRGBA8, _ b: ColorRGBA8, weight w: UInt8) -> ColorRGBA8
      /// Clip coverage after the antialiasing option: antialiasing ? c : (c >= 128 ? 255 : 0).
      static func effectiveClip(_ c: UInt8, antialiasing: Bool) -> UInt8
      /// One output pixel from the before-pixel, at pixel (x, y) with effective clip coverage c (1…255).
      static func composePixel(before: ColorRGBA8, x: Int, y: Int, clip c: UInt8, parameters: GradientParameters) -> ColorRGBA8
      /// Rewrites `surface` from `before` over the render region; returns the tiles it visited.
      static func render(_ parameters: GradientParameters, before: TiledSurface, into surface: inout TiledSurface,
                         clip: (any BrushClipMask)?) -> Set<TileCoordinate>
      /// Start/end colors for a gesture (see "Endpoint colors").
      static func endpointColors(mode: GradientMode, primary: ColorRGBA8, secondary: ColorRGBA8,
                                 reversed: Bool) -> (start: ColorRGBA8, end: ColorRGBA8)
  }
  ```
  - **Sample point.** Pixel `(x, y)` is evaluated at its center `px = Double(x) + 0.5`, `py = Double(y) + 0.5`. Let `dx = px − start.x`, `dy = py − start.y`, `vx = end.x − start.x`, `vy = end.y − start.y`, `L² = vx·vx + vy·vy`, `L = sqrt(L²)`. Evaluate in exactly this order (the hand-computed tests rely on exact binary results):
  - **Per-type formula** (unbounded `u` → bounded `t`):
    | Type | `u` | `t` |
    |---|---|---|
    | Linear | `(dx·vx + dy·vy) / L²` | `clamp(u, 0, 1)` |
    | Linear (Reflected) | `(dx·vx + dy·vy) / L²` | `clamp(abs(u), 0, 1)` |
    | Diamond | `abs(dx·(vx/L²) + dy·(vy/L²)) + abs(dx·(vy/L²) − dy·(vx/L²))` | `clamp(u, 0, 1)` |
    | Radial | `sqrt(dx·dx + dy·dy) / L` | `clamp(u, 0, 1)` |
    | Conical | `d = atan2(dy, dx) − atan2(vy, vx)`; if `d > π` then `d −= 2π`; if `d < −π` then `d += 2π` | `clamp(abs(d) / π, 0, 1)` |
    Linear: t = 0 on the line through `start` perpendicular to the handle line, t = 1 on the parallel line through `end`. Reflected: mirrored about the start line. Diamond: a square rotated so one corner points at `end`, t = 1 on its outline (L1 norm in the handle frame). Radial: circles around `start` with radius `L`. Conical: t = 0 along the ray from `start` toward `end`, t = 1 along the opposite ray (symmetric, so there is no seam). At the exact start pixel center `atan2(0, 0) = 0` (Swift/C semantics); no special case.
  - **Weight**: `w = weight(t)`; `weight(0.5) == 128`, `weight(0.375) == 96`, `weight(1) == 255`; NaN → 0.
  - **Endpoint colors** (`endpointColors`): Color mode: `(primary, secondary)`; reversed: `(secondary, primary)`. Transparency mode: `start = (0,0,0, primary.a)`, `end = (0,0,0, 255 − secondary.a)` (Paint.NET: "the inverse of the alpha value of the Secondary color", so the default black/white colors fade opaque → transparent); reversed swaps them (`start = (0,0,0, 255 − secondary.a)`, `end = (0,0,0, primary.a)`). Colors are taken from `context.colors` when the gesture that creates the gradient starts and are fixed for the pending gradient (Open question 2).
  - **Compose, Color mode**: `g = lerp(startColor, endColor, weight: w)`; `Sa = mul255(g.a, c)`; result `BlendOps.blend(parameters.blendMode, dst: before, src: (g.r, g.g, g.b, Sa))` (opacity 255). `Sa == 0` → `before` unchanged bit-for-bit.
  - **Compose, Transparency mode**: `ga = lerp(startColor.a, endColor.a, weight: w)`; `target = mul255(before.a, ga)` (the gradient alpha multiplies the existing alpha, as Paint.NET's transparency gradient does); `newA = (UInt32(before.a)·(255 − c) + UInt32(target)·c + 127) / 255`; result `(before.r, before.g, before.b, newA)` — RGB is never changed, even when `newA == 0` (D-33). Blend mode is not used.
  - **Clip & region (TOOL-B)**: `c = effectiveClip(clip?.coverage(x, y) ?? 255, antialiasing:)`. With antialiasing off, a partial selection edge becomes hard (threshold 128); with it on the 8-bit antialiased mask is used as-is. The gradient itself has no hard edges, so the antialiasing option only affects selection edges (Open question 1). Region = canvas ∩ `clip.bounds` (whole canvas when `clip == nil`), visited tile by tile. `c == 0` → pixel = `before`. `isDegenerate` → `render` copies nothing and returns `[]` (caller restores `before`).
  - **`render`**: for every tile `T` intersecting the region: build the output tile from `before.tile(at: T)` (absent = all `.clear`), compose each region pixel; if the result equals the before tile, `setTile` the **before** tile (shared storage, no allocation for untouched/absent tiles — `Tile.sharesStorage(with:)` stays true); otherwise `setTile` the new tile. Tiles of `surface` outside the region are set back to `before`'s tiles if they differ (they can't for a fixed region, but the render must be a pure function of `(parameters, before, clip)`). Returns the set of region tiles. Implementations may process tiles concurrently (`DispatchQueue.concurrentPerform`) as long as the output is deterministic; per-pixel work must not allocate.

- **`PaintDotMac/Core/Tools/GradientTool.swift`** (new):
  - **Options** (TOOL-C), `struct GradientOptions: Equatable, Sendable { var type: GradientType; var mode: GradientMode; var antialiasing: Bool; var blendMode: BlendMode; static let `default` = GradientOptions(type: .linear, mode: .color, antialiasing: true, blendMode: .normal); @MainActor static func load(from: any ToolOptionStore) -> GradientOptions; @MainActor func save(to: any ToolOptionStore) }`. Keys: `tool.gradient.type` (raw String), `tool.gradient.mode` (raw String), `tool.gradient.antialiasing` (Bool), `tool.gradient.blendMode` (raw String). Missing/unknown raw values → defaults.
  - **Handle helpers (pure, same file)**:
    ```swift
    enum GradientHandle: Sendable, Equatable { case start, end }
    enum GradientGeometry {
        static let snapStepDegrees: Double = 15
        static let handleHitRadius: Double = 6        // view points
        /// Shift: keeps |moving − anchor|, rounds the angle of (moving − anchor) to the nearest 15° (ties away from zero).
        static func snapped(_ moving: CGPoint, anchor: CGPoint) -> CGPoint
        /// Handle under the view point (≤ 6 pt from the handle's view position); both in range → the nearer; exact tie → .end.
        static func hitHandle(atView p: CGPoint, start: CGPoint, end: CGPoint, transform: CanvasTransform) -> GradientHandle?
    }
    ```
    `snapped`: `r = hypot(dx, dy)`; `r == 0` → `anchor`; `θ = atan2(dy, dx)`; `step = 15° in radians`; `θs = (θ / step).rounded(.toNearestOrAwayFromZero) · step`; result `anchor + (r·cos θs, r·sin θs)`.
  - **State machine** (`final class GradientTool: Tool`, `id = .gradient`): `idle` → `drawing(start)` → `editing` ⇄ `draggingHandle(GradientHandle)`. Stored while not idle: `layerID: Layer.ID`, `before: TiledSurface` (the active layer's surface at gesture start; COW snapshot), `clip: (any BrushClipMask)?` (captured from `context.paintClipMask` at gesture start, fixed for the pending gradient), `colors` (primary/secondary captured at gesture start), `reversed: Bool`, `start`, `end`, `touchedTiles: Set<TileCoordinate>` (union of every `render` result).
    - `hasPendingEdit` = state ≠ `idle`.
    - **`mouseDown`**, state `editing`: if `hitHandle(atView: event.viewLocation, …)` returns a handle → `draggingHandle(h)`; if `event.button == .secondary` also toggle `reversed` and re-render (Paint.NET: right-click a nub swaps the colors). Cursor `.closedHand`. Otherwise (outside the handles) → `commit(context:)` first, then start a new gradient as in idle.
    - **`mouseDown`**, state `idle`: if the active layer index is invalid, ignore. Capture `layerID`, `before`, `clip`, colors, `reversed = (event.button == .secondary)`, `start = end = event.location` → `drawing`. Nothing is rendered yet (degenerate). Set overlay.
    - **`mouseDragged`**: `drawing`: `end = shift ? snapped(location, anchor: start) : location`. `draggingHandle(h)`: the dragged handle moves to the pointer (`snapped` against the other handle when Shift is held). Both re-render and update the overlay.
    - **`mouseUp`**: `drawing`: apply the drag rule once more; if the result is degenerate (`start == end`) → restore `before` (inside `updateImage`), clear the overlay, `idle`, no history; else → `editing`. `draggingHandle` → `editing` (a handle dragged onto the other handle so they coincide renders nothing; the gradient stays pending and can be dragged apart again; committing it while degenerate behaves like cancel).
    - **Re-render**: options are read from `context.options` (`GradientOptions.load`), parameters built with `endpointColors(mode:primary:secondary:reversed:)`; `context.updateImage { img in GradientRenderer.render(p, before: before, into: &img.layers[i].surface, clip: clip) }` where `i` is the index of `layerID` (layer gone → `cancel`); degenerate → write `before` back. `touchedTiles.formUnion(result)`.
    - **`optionsDidChange(context:)`** while pending: re-render with the new type/mode/antialiasing/blend mode (Paint.NET updates the pending gradient live).
    - **`commit(context:)`** (Return/Enter via the default `keyDown`, Finish button, tool switch via `deactivate`, document switch, `prepareForNavigation` before undo/redo/jump/save and commands (via 0020's default `prepareForHistoryNavigation` / `PendingEditReason.command`), mouse-down outside the handles): in `drawing`/`draggingHandle` first apply the last known pointer location as in `mouseUp`. If degenerate → same as `cancel`. Else `diff = TileDiff.between(before: before, after: layer.surface, layerID:, candidates: touchedTiles)`; `context.commitHistory(TileDiffHistoryItem(name: "Gradient", icon: .gradient, diff: diff))` (empty diff → no step, H-6/D-34); clear the overlay; `idle`.
    - **`cancel(context:)`** (Escape): write `before` back into the layer inside `updateImage` (pixel-identical, no history), clear the overlay, `idle`.
    - **`deactivate`**: default (commits a pending gradient), then `setOverlay(nil)`.
    - **Cursor**: `cursor(at:modifiers:)` → `.closedHand` while `draggingHandle`; `.crosshair` when `location != nil` otherwise. (The pure `hitHandle` needs view coordinates the cursor API doesn't receive; `mouseMoved` remembers whether the pointer is over a handle and `cursor` returns `.openHand` then, calling `context.invalidateCursor()` when that flag changes.)
    - **Overlay**: while not idle, `context.setOverlay(.gradientHandles(start: start, end: end))` after every change.
  - **`Core/Tools/ToolContext.swift`** (extend 0006's `ToolOverlay`): `case gradientHandles(start: CGPoint, end: CGPoint)` (canvas space).
  - **`Core/Tools/ToolRegistry.swift`** (modify 0006): register `.gradient → GradientTool()` in `standard()`; change the `gradient` descriptor row to `supportsPendingEdits: true` (the Finish button commits a pending gradient, as in Paint.NET). Update 0006's `ToolRegistryTests.descriptorsMatchTable` and `ToolOptionsBarModelTests.finishVisibility` expectations accordingly (true for moveSelectedPixels, gradient, text, lineCurve, shapes; false for the other 14).

### Platform glue (AppKit/SwiftUI; UI tests and manual checks)

- **`Canvas/ToolOverlayView.swift`** (extend): draw `.gradientHandles(start, end)`: map both points with `transform.canvasToView`; a 1 pt black line over a 1 pt white line (offset so it shows on any background) between them, and at each end a 10 pt diameter circle (white fill, 1 pt black stroke). Redraw on every transform change (0006 already does).
- **`UI/ToolOptionsBar.swift`** (extend `ToolOptionsContent`): case `.gradient`, left to right with Paint.NET's labels:
  - **Gradient type**: segmented control (or `.menu` picker) with the five types in enum order, labels = `displayName`. Identifier `toolOptions.gradientType`, accessibility value = display name.
  - **Mode**: picker "Color Mode" / "Transparency Mode". Identifier `toolOptions.gradientMode`.
  - **Antialiasing** toggle, identifier `toolOptions.antialiasing` (0009 pattern).
  - **Blend mode** popup, identifier `toolOptions.blendMode` (0009 pattern, implemented modes in L-3 order); **disabled in Transparency Mode** (not used).
  - Each change saves through `GradientOptions.save` and the dispatcher calls `optionsDidChange` (live re-render of a pending gradient).
  - The Finish button (0006) now appears for the Gradient and is enabled while a gradient is pending.
- **Tools panel**: the Gradient button `tool.gradient` appears automatically (implemented tools only, fill group).
- No `project.yml` change beyond the new files; run `xcodegen generate`.
- **No PRD update needed** for the implemented behavior beyond the open questions below (T-10 is unchanged; the formulas, the transparency-mode inverse-secondary rule from Paint.NET's docs, and the handle behavior are implementation detail recorded here).

## Acceptance criteria

- [ ] Pressing G selects the Gradient; the options bar shows Gradient type (Linear default), Mode (Color Mode default), Antialiasing (on), Blend mode (Normal), and a Finish button. → `GradientUITests.pressingGSelectsGradientAndShowsOptions`, `GradientToolTests.defaultsMatchPaintNET`
- [ ] Each of the five types produces exactly the hand-computed pixel values below. → `GradientRendererTests.linear*`, `.reflected*`, `.diamond*`, `.radial*`, `.conical*`
- [ ] Color mode interpolates primary → secondary in straight sRGB including alpha and composites with the selected blend mode. → `GradientRendererTests.colorLerpIncludesAlpha`, `.colorModeOverOpaqueUsesNormalBlend`
- [ ] Transparency mode changes only alpha: primary alpha → 255 − secondary alpha, multiplied into the existing alpha; RGB untouched. → `GradientRendererTests.transparencyRamp`, `.transparencyMultipliesExistingAlpha`, `.transparencyKeepsRGBUnderZeroAlpha`
- [ ] Right-drag (or Control-drag) reverses the gradient in both modes; right-clicking a handle toggles the reversal. → `GradientToolTests.secondaryDragReverses`, `.rightClickHandleSwapsColors`, `GradientRendererTests.endpointColors`
- [ ] Shift snaps the handle angle to 15° steps while keeping the length. → `GradientGeometryTests.snapped*`, `GradientToolTests.shiftSnapsDuringDrawAndHandleDrag`
- [ ] Handles stay editable until commit; dragging a handle re-renders from the original pixels; Return, Finish, tool switch, and clicking outside the handles commit one "Gradient" step; Escape restores the layer with no step. → `GradientToolTests.handleDragRerendersFromBefore`, `.returnCommits`, `.deactivateCommits`, `.clickOutsideCommitsAndStartsNew`, `.escapeCancels`; `GradientUITests.drawCommitUndoRedo`, `.escapeDiscards`
- [ ] Changing an option while pending re-renders live. → `GradientToolTests.optionChangeRerendersPending`
- [ ] Painting is confined to the selection; antialiasing on uses the antialiased mask edge, off thresholds it at 128. → `GradientRendererTests.clipPartialCoverage`, `.antialiasingOffThresholdsClip`, `.outsideClipBoundsUntouched`; `GradientUITests.gradientClippedToSelection`
- [ ] Undo restores the exact before tiles, redo the exact after tiles; no-op gradients add no step. → `GradientIntegrationTests.undoRedoRoundTrip`, `.noOpAddsNoStep`, `GradientToolTests.clickWithoutDragAddsNoStep`
- [ ] Options persist under `tool.gradient.*`. → `GradientToolTests.optionsRoundTripThroughStore`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Click without drag** (start == end): nothing changes, no step, tool returns idle. → `clickWithoutDragAddsNoStep`
- **Handle dragged onto the other**: degenerate → layer shows `before`; committing then behaves like cancel. → `GradientToolTests.degeneratePendingCommitsNothing`
- **Handles outside the canvas** (drag starts/ends off-image): formulas work on any finite coordinates; t clamps. → `GradientRendererTests.linearClampsBeforeStartAndAfterEnd`
- **Non-finite coordinates**: `isDegenerate` → nothing rendered, no crash. → `GradientRendererTests.nonFiniteIsDegenerate`
- **Huge distance** (e.g. start (0,0), end (1e7, 0)): no overflow (Double math); pixel (0,0) weight 0.
- **Transparent layer / absent tiles**: color mode allocates tiles it paints; transparency mode on a fully transparent layer changes nothing → no step and no tile allocated (`sharesStorage`). → `GradientRendererTests.transparencyOnEmptyLayerAllocatesNothing`, `GradientIntegrationTests.noOpAddsNoStep`
- **Both colors alpha 0** in color mode → no change, no step.
- **Selection entirely outside the canvas region / tiny selection**: only the region's tiles are visited. → `outsideClipBoundsUntouched`
- **Tile boundaries**: a gradient across tile (255/256) boundaries is continuous. → `GradientRendererTests.continuousAcrossTileBoundary`
- **1×1 canvas** works for all five types. → `GradientRendererTests.oneByOneCanvas`
- **Hidden active layer**: the gradient still writes the active layer (as the brush and 0017 do).
- **Active layer removed while pending** (later layer ops): next re-render or commit cancels without history.
- **Undo/redo/save while pending**: 0008/0006 commit the pending gradient first, so ⌘Z undoes the just-committed "Gradient" step. → `GradientIntegrationTests.undoWhilePendingCommitsFirst`
- **Second button mid-gesture**: ignored by 0006's dispatcher.

## Test plan

Expected values below are hand-computed (verified by hand arithmetic, not by running the code). `P = (0,0,0,255)` (black), `S = (255,255,255,255)` (white) unless stated; "gray k" = `(k,k,k,255)`. Single-layer surfaces built with `TestImages`.

- **Unit tests — `PaintDotMacTests/Model/GradientRendererTests.swift`** (exact equality):
  - `weightRounding`: `weight(0) == 0`, `weight(0.5) == 128`, `weight(0.375) == 96`, `weight(0.625) == 159`, `weight(0.75) == 191`, `weight(0.25) == 64`, `weight(1) == 255`, `weight(-3) == 0`, `weight(7) == 255`, `weight(.nan) == 0`.
  - `colorLerpIncludesAlpha`: `lerp((255,0,0,255), (0,0,255,51), weight: 128) == (127,0,128,153)`; weight 0 → first color, 255 → second color exactly (all 4 channels, 1000 seeded random pairs).
  - `linearRamp`: 256×1 transparent layer, Linear, start (0.5,0.5), end (255.5,0.5), Color mode P→S, Normal → pixel x == `(x,x,x,255)` for all x in 0…255.
  - `linearClampsBeforeStartAndAfterEnd`: 300×1, start (100.5,0.5), end (200.5,0.5): x=50 → `P`, x=150 → gray 128, x=250 → `S`.
  - `linearIsPerpendicularInvariant`: 4×10, start (0.5,0.5), end (0.5,8.5): every pixel in row 4 is gray 128 (t = 4/8), row 0 is `P`, row 9 is `S`.
  - `reflected`: 300×1, Linear (Reflected), start (100.5,0.5), end (200.5,0.5): x=0 → `S`, x=50 → gray 128, x=100 → `P`, x=150 → gray 128, x=250 → `S`.
  - `diamondAxisAligned`: 101×101, start (50.5,50.5), end (58.5,50.5): (50,50) → `P`; (54,50) → gray 128; (52,51) → gray 96; (46,48) → gray 191; (50,58) → `S`; (60,60) → `S`.
  - `diamondRotated`: start (50.5,50.5), end (54.5,54.5): (52,52) → gray 128; (52,48) → gray 128; (54,50) → `S`.
  - `radial`: start (50.5,50.5), end (58.5,50.5): (50,50) → `P`; (53,54) → gray 159 (distance 5 → 0.625); (50,56) → gray 191; (56,58) → `S` (distance 10 > 8); radial symmetry: (46,50) == (54,50) == (50,46) == (50,54).
  - `conical`: start (50.5,50.5), end (60.5,50.5): (60,50) → `P`; (40,50) → `S`; (50,60) → gray 128; (50,40) → gray 128; (55,55) → gray 64; (50,50) (start pixel, atan2(0,0)=0) → `P`. Rotated: end (50.5,60.5): (40,50) → gray 128; (50,40) → `S`; (60,50) → gray 128.
  - `colorModeOverOpaqueUsesNormalBlend`: 1×1 opaque white layer; Linear with start/end so pixel (0,0) has t = 0.5 (start (−0.5,0.5), end (1.5,0.5)), startColor (255,0,0,255), endColor (0,0,255,51) → `(178,102,179,255)`; same over a transparent layer → `(127,0,128,153)`.
  - `endpointColors`: color: `(P, S)`, reversed `(S, P)`; transparency with primary.a 200, secondary.a 100 → start.a 200, end.a 155; reversed → start.a 155, end.a 200; defaults (both 255) → start.a 255, end.a 0.
  - `transparencyRamp`: 256×1 opaque red `(255,0,0,255)`, Transparency mode, start (0.5,0.5), end (255.5,0.5), default colors → pixel x == `(255,0,0,255−x)`; reversed → `(255,0,0,x)`.
  - `transparencyMultipliesExistingAlpha`: pixel `(10,20,30,128)` at gradient alpha 127 (startColor.a 127 = endColor.a) → `(10,20,30,64)`.
  - `transparencyKeepsRGBUnderZeroAlpha`: pixel x=255 of `transparencyRamp` is `(255,0,0,0)` (RGB kept, D-33).
  - `transparencyIgnoresBlendMode`: parameters differing only in `blendMode` give identical output (once 0026 adds modes, still identical; today assert via `.normal` vs the same params — documented as a guard).
  - `clipPartialCoverage`: 1×1 opaque white, color mode at t = 0 with startColor `P`, clip coverage 128, AA on → `(127,127,127,255)`; transparency mode default colors at t = 0 on that pixel with coverage 128 → alpha unchanged 255 (target 255); at t = 1 (target 0) with coverage 128 → alpha 127.
  - `antialiasingOffThresholdsClip`: `effectiveClip(127, antialiasing: false) == 0`, `(128, false) == 255`, `(1, true) == 1`; rendering with clip 127 and AA off leaves the pixel equal to before.
  - `outsideClipBoundsUntouched`: 600×300 white, clip mask (test double) covering only (300…340, 100…140) → every pixel outside equals before; the returned tile set == the tiles intersecting that rect ({(1,0)}).
  - `continuousAcrossTileBoundary`: 512×1, Linear start (0.5,0.5), end (511.5,0.5) → |r(255) − r(256)| ≤ 1 and the row is non-decreasing.
  - `transparencyOnEmptyLayerAllocatesNothing`: absent-tile 300×300 surface → after render, every tile `sharesStorage(with:)` the before tile (or both absent); `TileDiff.between(…)` is empty.
  - `nonFiniteIsDegenerate` / `oneByOneCanvas`: NaN start → `isDegenerate`, render returns `[]`, surface unchanged; 1×1 canvas, each type with start (0,0), end (1,1) → no crash, pixel channels within 0…255 and equal to `composePixel` for (0,0).
  - `renderIsPureFunctionOfBefore`: render params A, then params B into the same surface → equals rendering B directly from `before` (property test, 200 seeded random parameter pairs on 300×300 random images, seed printed).
- **Unit tests — `PaintDotMacTests/Tools/GradientGeometryTests.swift`**:
  - `snappedHorizontal`: anchor (0,0), moving (10,1) → (√101, 0) within 1e-9.
  - `snapped45`: moving (10,9) → (r·cos 45°, r·sin 45°), r = √181, within 1e-9.
  - `snapped180`: moving (−5, 0.1) → (−r, ~0) within 1e-9; moving (0,−7) → (0,−7) within 1e-9; zero length → anchor.
  - `hitHandle`: with a 100% transform (backing scale 1), handle at canvas (10,10): view point 5 pt away → hit; 7 pt → nil; both within range → nearer; exact tie → `.end`; at 400% zoom 1 canvas px = 4 pt so the radius stays 6 pt in view space.
- **Unit tests — `PaintDotMacTests/Tools/GradientToolTests.swift`** (`FakeToolContext` with a `DocumentState` 300×300 white, `InMemoryToolOptionStore`, colors default):
  - `defaultsMatchPaintNET`: empty store → `GradientOptions.default` (`.linear`, `.color`, AA true, `.normal`); descriptor `gradient.supportsPendingEdits == true`; `ToolRegistry.standard().isImplemented(.gradient)`.
  - `optionsRoundTripThroughStore`: save `(.conical, .transparency, false, .normal)` → keys `tool.gradient.type == "conical"`, `.mode == "transparency"`, `.antialiasing == false`, `.blendMode == "normal"`; new tool reads them back; unknown raw `"spiral"` → `.linear`.
  - `drawShowsHandlesAndPending`: down (10,150) primary, drag (290,150) → overlay `.gradientHandles(start: (10,150), end: (290,150))`, `hasPendingEdit`; up → still pending, `commitHistory` not called; pixel (5,150) == `P`, (295,150) == `S`.
  - `secondaryDragReverses`: same drag with `.secondary` → pixel (5,150) == `S`, (295,150) == `P`.
  - `rightClickHandleSwapsColors`: after drawing, secondary down at the end handle's view point, up without moving → (5,150) == `S`; still pending.
  - `shiftSnapsDuringDrawAndHandleDrag`: down (100,100), drag (200,105) with `.shift` → overlay end == (100 + √10025, 100) within 1e-9; then drag the end handle to (150,190) with Shift → end at 45°·k from start, length preserved.
  - `handleDragRerendersFromBefore`: draw, then drag the start handle twice; the final pixels equal a fresh render from the original white surface with the final handles (no accumulation).
  - `optionChangeRerendersPending`: pending linear; store `.radial` + `optionsDidChange` → pixels equal the radial render of `before`.
  - `returnCommits`: Return → `commitHistory` called once with name "Gradient", icon `.gradient`, non-empty diff; `hasPendingEdit == false`; overlay nil.
  - `deactivateCommits`: pending → `deactivate` → one "Gradient" commit.
  - `clickOutsideCommitsAndStartsNew`: pending, mouse down far from both handles → one commit, then a new `drawing` state started at that point.
  - `escapeCancels`: Escape → layer pixel-identical to before (every tile `sharesStorage` or equal), no commit, overlay nil.
  - `clickWithoutDragAddsNoStep` / `degeneratePendingCommitsNothing`: down/up at the same point → not pending, no commit, pixels unchanged; drag a handle onto the other then Return → no commit, pixels unchanged.
  - `respectsClipHook`: `paintClipMask` = test mask (x < 150 → 255, else 0) → after commit, every pixel with x ≥ 150 is white.
- **Integration tests — `PaintDotMacTests/Integration/GradientIntegrationTests.swift`** (headless: `DocumentState` 800×600 white "Background" via 0005's New Image helper, `UndoBridge` base `.newImage`, a `ToolContext` double forwarding `updateImage`/`commitHistory`, `GradientTool`):
  - `undoRedoRoundTrip`: draw linear (0,300)→(800,300), Return → history names `["New Image", "Gradient"]`; snapshot tiles; undo → every tile equals the original white; redo → equals the snapshot; seeded 50 random gradients (type, mode, endpoints, colors) each followed by undo/redo identity (seed printed).
  - `undoWhilePendingCommitsFirst`: pending gradient, `undoBridge.undo()` (with the 0008 `prepareForNavigation` hook wired to the tool's commit) → the "Gradient" step was committed then undone: pixels white, redo available named "Gradient".
  - `noOpAddsNoStep`: transparency mode on a transparent layer (new transparent image) → history unchanged; color mode with both colors alpha 0 → unchanged.
  - `selectionClipsGradient`: `DocumentState.selection = Selection(rect: (100,100,200,200))`, draw linear across the canvas → pixels outside the rect unchanged white; inside non-white for t < 1.
- **UI tests — `PaintDotMacUITests/GradientUITests.swift`** (fixture generated at test time with `UITestApp.makePNG`, reset defaults):
  - `pressingGSelectsGradientAndShowsOptions`: type `g` → `tool.gradient` selected; `toolOptions.gradientType` value "Linear", `toolOptions.gradientMode` "Color Mode", `toolOptions.antialiasing` on, `toolOptions.blendMode` "Normal"; `toolOptions.finish` exists and is disabled. Choose "Transparency Mode" → `toolOptions.blendMode` disabled.
  - `drawCommitUndoRedo`: open a 4000×1000 opaque white PNG (opens fitted, spanning the view width); `g`; `dragOnCanvas(from: (0.25, 0.5), to: (0.75, 0.5))`; `toolOptions.finish` enabled; press Return → History row "Gradient", Edit menu "Undo Gradient"; ⌘S; read the PNG: pixel (100,500) == `(0,0,0,255)`, (3900,500) == `(255,255,255,255)`, (2000,500) red channel in 100…155, row 500 non-decreasing in red, pixel (2000,10) == (2000,990). ⌘Z, ⌘S, reread → all sampled pixels white. ⇧⌘Z → "Gradient" again.
  - `escapeDiscards`: draw as above, Escape → no "Gradient" history row, Edit menu has no "Undo Gradient"; ⌘S → pixel (100,500) white.
  - `gradientClippedToSelection`: launch with `["-UITestSelectRect", "1000,250,2000,500"]` on the 4000×1000 fixture; draw the same gradient; Return; ⌘S → pixels (500,500) and (3500,500) and (2000,100) white; (1200,500) non-white.
- **Performance**: `PaintDotMacTests/Performance/GradientPerformanceTests.swift` (XCTest `measure`): full re-render of a linear and a conical gradient on a 4000×3000 opaque layer. Report only (no gate); record the numbers in Verification status. (Affects NF-1 perceived responsiveness while dragging handles; NF-4: the diff holds only changed tiles.)
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green (clean build, no warnings, all tests pass, none skipped, UI tests ran, launch smoke).
- **Manual verification:**
  1. Each of the five types at 100% and 400% zoom on 1× and 2× displays: smooth banding-free ramps; conical has no seam; diamond corner points at the end handle.
  2. Handles: visible on white, black, and photos; dragging either handle updates live without visible lag on a 4000×3000 image; cursor shows open hand over a handle and closed hand while dragging.
  3. Shift-drag snaps to 15° steps (horizontal, 45°, vertical are easy to hit).
  4. Right-drag and Control-drag reverse colors; right-click a handle swaps them.
  5. Transparency Mode on a photo: fades the photo to transparent (checkerboard visible) with the default colors.
  6. With a soft-edged selection (ellipse select, 0014), antialiasing on shows a smooth edge; off shows a hard edge.

## Open questions

1. **Meaning of the Antialiasing option for the Gradient.** The gradient has no geometric edges, so this spec defines antialiasing as using the antialiased selection edge (on) vs thresholding the mask at 128 (off). Recommended: yes (matches how Paint.NET's antialiasing toggle affects selection-clipped fills).
2. **Color changes while a gradient is pending.** This spec captures the primary/secondary colors when the gradient is created (right-click on a handle still swaps them). Paint.NET 4+ updates a pending gradient live when the palette changes. Recommended: keep capture-at-creation for v1.0; live color updates would need a `ToolContext` color-change notification (could be added with 0054 or later).
3. **Transparency mode endpoint.** The brief described transparency mode as "primary alpha → secondary alpha"; Paint.NET's documentation says "to the inverse of the alpha value of the Secondary color" (so default opaque colors fade opaque → transparent; primary → secondary alpha would be a no-op with defaults). This spec follows Paint.NET. Recommended: confirm and, if accepted, record it next to T-10 in PRD §5.3.

## Out of scope

- Spiral gradients and repeat modes (Paint.NET 5 has No Repeat / Repeat Wrapped / Repeat Reflected and two spiral types; PRD T-10 lists none of them, so v1.0 is No Repeat only).
- Live update of a pending gradient on palette changes (Open question 2).
- Blend modes other than Normal in the popup (0026, 0027, 0059 extend `BlendOps` and the list automatically).
- Selection tools themselves (0014+; tests use `-UITestSelectRect` and `Selection(rect:)`).
- Metal compositing of the result (0024); the canvas shows the live layer via 0003's tile upload.
- Tablet pressure (0055).
