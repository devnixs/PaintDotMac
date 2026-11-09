# 0017 — Add the Paint Bucket tool (tolerance, contiguous/global, antialiasing, fill selection)

> Source: PRD.md §5.3 T-9 ("Paint Bucket — F — Tolerance, contiguous or global fill, antialiasing, and an option to fill the selection"), TOOL-A (left = primary, right / Control-left = secondary), TOOL-B (painting is confined to the active selection), TOOL-C (settings persist), APP-4 (tool options bar shows fill mode, tolerance, …), §4 / NF-9 (straight RGBA8), NF-4 (undo stores changed tiles only), NF-6 (flood fill has unit tests), H-6 / D-34 (no-op edits add no step), D-15 (tool blend list = implemented layer blend modes), D-17 (`UserBlendOps` formulas). Paint.NET docs: Paint Bucket, https://paint.net/doc/latest/PaintBucket.html (old URL https://www.getpaint.net/doc/latest/PaintBucket.html); Tool Bar, https://paint.net/doc/latest/Toolbar.html (Flood Mode, Tolerance, Antialiasing, Blend Mode); Paint.NET blog "The Paint Bucket in paint.net 4.0" (2012-10-02, sampling layer/image, antialiasing).
> Milestone: M2
> Depends on: 0016-magic-wand-and-flood-fill (and through it 0014, 0013, 0012, 0009, 0008, 0007, 0006)

## Context

Not yet implemented: there is no application code. This spec builds on the following types from lower-numbered specs (exact names from the written specs; never create a parallel type).

- 0006: `Core/Tools/Tool.swift` (`@MainActor protocol Tool`: `id`, `hasPendingEdit`, `mouseDown/Dragged/Up/Moved(_:context:)`, `cursor(at:modifiers:) -> ToolCursor`, `commit`, `cancel`, `optionsDidChange`), `ToolEvent` (`location` = canvas space, image pixels, `Double`, top-left origin, y down; `button` `.primary`/`.secondary` — right button and Control-left both arrive as `.secondary` with `.control` kept; `modifiers`), `ToolID.paintBucket`, the descriptor row `paintBucket | Paint Bucket | f | fill | drop.fill | supportsPendingEdits false`, `ToolRegistry.standard()` factories, `ToolOptionKey`/`ToolOptionStore`/`InMemoryToolOptionStore`, `UI/ToolOptionsBar.swift` (`ToolOptionsContent` switch), `FakeToolContext`.
- 0007: `ToolContext.colors` (`ColorSelection`, `.primary` default `(0,0,0,255)`, `.secondary` default `(255,255,255,255)`).
- 0008: `TileDiff.between(before:after:layerID:candidates:)`, `TileDiffHistoryItem(name:icon:diff:)` (no-op when `diff.isEmpty`), `HistoryIcon.paintBucket`, `ToolContext.commitHistory(_:)`, `UndoBridge`.
- 0009: `BlendOps.blend(_:dst:src:opacity:)` and `BlendOps.mul255` (`Core/Rendering/BlendOps.swift`), `BrushClipMask` (`bounds: PixelRect`, `coverage(x:y:) -> UInt8`; pixels outside `bounds` have coverage 0), `ToolContext.paintClipMask: (any BrushClipMask)?` (nil = no selection = everything paintable) and `ToolContext.updateImage(_:)`, the Paintbrush compose rule (`Sa = mul255(color.a, effCov)`, `blend(mode, dst: before, src: (r,g,b,Sa))`), the blend-mode popup pattern (`toolOptions.blendMode`, implemented `BlendMode` cases in L-3 order), `BlendMode: ToolOptionValue`.
- 0010: history row icon for `.paintBucket` is `drop.fill`.
- 0012: `CPUCompositor`, `SamplingMode` (`layer`/`image`, display names "Layer"/"Image" — 0012 says "0016 (Magic Wand, Paint Bucket) reuses this type").
- 0013: `Selection` (`nil` = no selection; a `Selection` is never empty, PRD E-3 / D-40) with `mask: SelectionMask` (8-bit antialiased, tiled 256), which conforms to `BrushClipMask`; `ToolContext.selection: Selection?`; `ToolContext.paintClipMask` returns `selection?.mask` (or `nil` when the mask is full, which is pixel-identical).
- 0014: `Core/Tools/RectangleSelectTool.swift` (used by the UI test to make a selection).
- 0016 (`Core/Model/FloodFill.swift`, `Core/Tools/MagicWandTool.swift`, `UI/FloodToolOptionsView.swift`): `FloodMode` (`contiguous`, `global`; "Contiguous"/"Global"; `ToolOptionValue`), `FloodTolerance(percent:)` (clamps 0…100), `FloodFillSource.make(for: LayeredImage, sampling: SamplingMode, compositor:)` (Layer = the active layer's raw pixels; Image = the `CPUCompositor` composite), `FloodFillStencil` (1-bit result: `size`, `contains(_ p: PixelPoint) -> Bool`, `bounds: PixelRect` (`.zero` when empty), `static func from(_ mask: SelectionMask) -> FloodFillStencil` = bit set iff coverage > 0), `FloodFill.fill(_ source:, from seed: PixelPoint, tolerance:, mode:, limit: FloodFillStencil? = nil, isCancelled:) -> FloodFillStencil?` (`limit` pixels outside it are barriers in contiguous mode and excluded in global mode; returns `nil` when the seed is outside the canvas or outside `limit`), `FloodToolOptions` (`tolerance(for: ToolID)` → `ToolOptionKey<Int>` default 50 range 0…100, `floodMode(for:)` default `.contiguous`, `samplingMode(for:)` default `.layer`, `effectiveFloodMode(stored:modifiers:)` = `.global` when Shift is held), `SamplingMode: ToolOptionValue`, and `FloodToolOptionsView(model:tool:)` (Flood mode `toolOptions.floodMode`, Tolerance slider `toolOptions.tolerance` with value "NN%", Sampling `toolOptions.samplingMode`). This spec reuses all of them unchanged.

Paint.NET behavior being mirrored (PaintBucket.html unless noted):
- "Left-click fills with the Primary color; right-click fills with the Secondary color."
- **Flood Mode**: **Contiguous** (default) — "the fill spreads outward from the click point until neighboring pixels fail the Tolerance setting"; **Global** — "the fill covers all pixels in the layer that meet the Tolerance setting". "The keyboard shortcut to enable Global fill mode is the Shift key" (holding Shift while clicking makes that click Global). Toolbar.html: "The Flood Mode affects only the Magic Wand Tool and Paint Bucket Tools."
- **Tolerance**: "A low setting requires pixels to closely match the click point pixel, a high setting admits a wider variance." Same metric as the Magic Wand (owned by 0016). Paint.NET default 50 %.
- **Sampling**: **Layer** — samples only the active layer; **Image** — samples the composite image, "the fill applies only to the active layer". Pixels outside an active selection are ignored.
- **Antialiasing** (Toolbar.html, Rasterization): "If enabled, the edges of the tool path will be smoothed"; for the bucket, a Paint.NET developer describes it on the forum as feathering applied to the pixels adjacent to the region the tolerance selects. Default on.
- **Blend Mode** (Toolbar.html): "will mimic the tool being applied to a layer immediately above the active layer", then merged into it. Default Normal.
- Paint.NET 4+ keeps the fill "live" after the click (tolerance/color edits re-run the fill, a draggable nub moves the seed, Finish/Enter commits) and offers patterned **Fill Styles**. Neither is in PRD T-9; see Decisions and Out of scope.
- "Option to fill the selection" (PRD T-9) has no Paint.NET 5 doc counterpart; this spec realises it as a **Fill** option "Similar Color" / "Selection" (see Decisions; PRD T-9 / D-42).

## User story

As a PaintDotMac user, I press **F**, choose Contiguous or Global, a tolerance, sampling, antialiasing, and a blend mode in the tool options bar, and click the canvas: the area of similar color (or, with Fill set to Selection, the whole selection) is filled with the primary color (right-click or Control-click: secondary), with smooth edges when antialiasing is on, never outside the active selection. Shift-click fills globally. Each click is one "Paint Bucket" step that ⌘Z undoes.

## Scope & changes

All new code is in **`PaintDotMac/Core/Tools/PaintBucketTool.swift`** (Core, headless, unit-tested) except the options-bar case (platform glue).

- **Options (Core)** in `PaintBucketTool.swift`:
  ```swift
  enum PaintBucketFillMode: String, CaseIterable, Sendable, ToolOptionValue {
      case similarColor, selection          // display names "Similar Color", "Selection"
  }
  struct PaintBucketOptions: Equatable, Sendable {
      var fillMode: PaintBucketFillMode     // default .similarColor
      var floodMode: FloodMode              // 0016; default .contiguous
      var tolerance: FloodTolerance         // 0016; default FloodTolerance(percent: 50), range 0…100 %
      var samplingMode: SamplingMode        // 0012; default .layer
      var antialiasing: Bool                // default true
      var blendMode: BlendMode              // default .normal
      static let `default`: PaintBucketOptions
      @MainActor static func load(from store: any ToolOptionStore) -> PaintBucketOptions
      @MainActor func save(to store: any ToolOptionStore)
  }
  ```
  Keys (TOOL-C): `tool.paintBucket.fillMode` (`ToolOptionKey<PaintBucketFillMode>(tool: .paintBucket, name: "fillMode", defaultValue: .similarColor)`), and through 0016's helpers `FloodToolOptions.floodMode(for: .paintBucket)` → `tool.paintBucket.floodMode`, `FloodToolOptions.tolerance(for: .paintBucket)` → `tool.paintBucket.tolerance` (`Int`, clamped 0…100, wrapped as `FloodTolerance(percent:)`), `FloodToolOptions.samplingMode(for: .paintBucket)` → `tool.paintBucket.samplingMode`; plus `tool.paintBucket.antialiasing` (Bool), `tool.paintBucket.blendMode` (raw String). Missing or unknown raw values → defaults; out-of-range tolerance → clamped. The Paint Bucket's keys are independent of the Magic Wand's.

- **Fill coverage (Core, pure)** — `enum PaintBucketFill` in the same file:
  - `struct FillCoverage: Sendable, Equatable { let canvasSize: PixelSize; private(set) var tiles: [TileCoordinate: [UInt8]] }` — 256×256 row-major coverage per tile (edge tiles use the full 256×256 buffer; entries outside the canvas are 0 and ignored). Only tiles with at least one non-zero value are stored. `func coverage(x: Int, y: Int) -> UInt8` (0 outside the canvas or for absent tiles); `var isEmpty: Bool`; `var bounds: PixelRect?` (tight bounds of non-zero coverage).
  - `static func featherCoverage(neighbours k: Int) -> UInt8` = `UInt8((510 * k + 9) / 18)` for `k ∈ 0…8` (= round-half-up of `255·k/9`): k → 0, 28, 57, 85, 113, 142, 170, 198, 227.
  - `static func coverage(region: FloodFillStencil, canvasSize: PixelSize, antialiasing: Bool) -> FillCoverage`:
    - Aliased: `cov(p) = 255` if `region.contains(p)`, else 0.
    - **Antialiased** (the feather; this is how edge coverage is computed): `cov(p) = 255` if `region.contains(p)`; otherwise `cov(p) = featherCoverage(k)` where `k` = number of pixels `q` in the 3×3 neighbourhood of `p` (8 neighbours; `p` itself is not in the region) with `q` inside the canvas and `region.contains(q)`. Equivalently `max(mask, round(box3×3(mask)))` over the binary region mask: the filled region stays fully covered (no gaps against neighbouring tolerance-matched pixels), and a one-pixel feather ring is added outside it. The ring never leaves the canvas. Only pixels within `region.bounds` expanded by 1 (clamped to the canvas) are visited.
  - `static func selectionCoverage(clip: (any BrushClipMask)?, canvasSize: PixelSize) -> FillCoverage` — Fill = Selection: `cov(p) = clip.coverage(p)` (the selection's own antialiased mask; the Antialiasing option is ignored), or 255 for every canvas pixel when `clip == nil`.
  - `static func apply(_ coverage: FillCoverage, clip: (any BrushClipMask)?, color: ColorRGBA8, blendMode: BlendMode, to surface: inout TiledSurface) -> Set<TileCoordinate>` — returns the touched tiles. Per pixel with `cov > 0`: `effCov = clip == nil ? cov : BlendOps.mul255(cov, clip.coverage(x, y))`; if `effCov == 0` the pixel is untouched; else `Sa = BlendOps.mul255(color.a, effCov)`, and if `Sa == 0` the pixel is untouched; else `new = BlendOps.blend(blendMode, dst: before, src: ColorRGBA8(r: color.r, g: color.g, b: color.b, a: Sa), opacity: 255)` — exactly 0009's Paintbrush compose rule (D-17 formulas). A pixel whose `new == before` is not written, and a tile is "touched" only when at least one pixel was written (so `generation` doesn't change for a no-op fill). Unallocated tiles are allocated only when a pixel in them is written.

- **Region selection (Core)**: `static func region(for options: PaintBucketOptions, effectiveFloodMode: FloodMode, image: LayeredImage, seed: PixelPoint, selection: Selection?) -> FloodFillStencil?` = `FloodFill.fill(FloodFillSource.make(for: image, sampling: options.samplingMode), from: seed, tolerance: options.tolerance, mode: effectiveFloodMode, limit: selection.map { FloodFillStencil.from($0.mask) })`, so **a pixel with selection coverage 0 is neither matched nor traversed** (Paint.NET: "pixels outside an active selection are ignored"); `nil` (seed outside the canvas or the selection) → no fill. 0016's `limit` parameter and its tests (`FloodFillTests.limitIsABarrier`, `.limitSizeMismatchReturnsNil`) already exist; this spec adds no parameter to `FloodFill`. Image sampling reads the composite through `FloodFillSource` (`CPUCompositor`); the write always goes to the active layer.

- **`PaintBucketTool` (Core)** — `@MainActor final class PaintBucketTool: Tool`, `id = .paintBucket`, registered by adding `.paintBucket: { PaintBucketTool() }` to `ToolRegistry.standard()`; it then appears in the Tools panel as `tool.paintBucket` ("Paint Bucket", `drop.fill`, key **F**) with no other panel change.
  - `hasPendingEdit` is always `false`: the fill is applied and committed on the click (Decisions, D-42). `commit`/`cancel` are no-ops.
  - `cursor(at:modifiers:)` → `.crosshair` when `location != nil`, else `.arrow`.
  - **`mouseDown`** (the whole operation; `mouseDragged`/`mouseUp` do nothing):
    1. Read `PaintBucketOptions.load(from: context.options)`.
    2. `seed = PixelPoint(x: Int(floor(location.x)), y: Int(floor(location.y)))`. If the seed is outside `[0, w) × [0, h)` → no-op (no step).
    3. Color (TOOL-A): `event.button == .secondary` or `.control ∈ modifiers` → `colors.secondary`, else `colors.primary`.
    4. `clip = context.paintClipMask`. If `clip != nil` and `clip.coverage(seed) == 0` → no-op (clicking outside the selection does nothing, TOOL-B).
    5. Coverage: `fillMode == .selection` → `selectionCoverage(clip:canvasSize:)`. Otherwise `effectiveFloodMode = FloodToolOptions.effectiveFloodMode(stored: options.floodMode, modifiers: event.modifiers)` (Shift-click = Global, Paint.NET), `region(for:effectiveFloodMode:image:seed:selection: context.selection)` (`nil` → no-op), then `coverage(region:canvasSize:antialiasing:)`.
    6. Remember the active layer's `Layer.ID`; `let before = layer.surface` (COW snapshot); `context.updateImage { touched = PaintBucketFill.apply(coverage, clip: clip, color:, blendMode: options.blendMode, to: &image.layers[i].surface) }`.
    7. `diff = TileDiff.between(before: before, after: layer.surface, layerID:, candidates: touched)`; `context.commitHistory(TileDiffHistoryItem(name: "Paint Bucket", icon: .paintBucket, diff: diff))`. An empty diff adds no step (D-34).
  - No active layer → no-op. The fill writes to the active layer regardless of its visibility (same as 0009's Paintbrush).

- **Platform glue — `UI/ToolOptionsBar.swift`** (modify): `case .paintBucket:` left to right:
  - **Fill** popup "Similar Color" / "Selection" — `toolOptions.fillMode`, accessibility value = selected display name, `.help("Fill")`.
  - `FloodToolOptionsView(model:, tool: .paintBucket)` (0016: **Flood mode** `toolOptions.floodMode`, **Tolerance** `toolOptions.tolerance`, **Sampling** `toolOptions.samplingMode`), wrapped in `.disabled(fillMode == .selection)`.
  - **Antialiasing** toggle — `toolOptions.antialiasing` (0009's control); disabled while Fill = Selection.
  - **Blend mode** popup (0009's) — `toolOptions.blendMode`.
  All read/write through `model.toolOptions` with the `tool.paintBucket.*` keys. No Finish button (`supportsPendingEdits` false).

- No `project.yml` change beyond new files; run `xcodegen generate` after adding test files.
- No PRD update in this spec: the decisions below are already PRD T-9 / D-42.

## Acceptance criteria

- [ ] Pressing F selects the Paint Bucket; the options bar shows Fill, Flood mode, Tolerance, Sampling, Antialiasing, Blend mode with defaults Similar Color, Contiguous, 50 %, Layer, on, Normal. → `PaintBucketUITests.pressingFSelectsToolAndShowsOptions`, `PaintBucketOptionsTests.defaultsMatchPaintNET`, `ToolRegistryTests.paintBucketKey`
- [ ] Options persist under `tool.paintBucket.*`, independent of the Magic Wand; bad stored values fall back/clamp. → `PaintBucketOptionsTests.roundTripThroughStore`, `.invalidStoredValues`, `PaintBucketUITests.optionsPersistAcrossRelaunch`
- [ ] Contiguous fills only the connected matching area; Global fills every matching pixel of the layer; Shift-click is Global for that click. → `PaintBucketToolTests.contiguousStopsAtBorder`, `.globalFillsDisconnectedAreas`, `.shiftClickIsGlobal`
- [ ] Tolerance is passed to 0016's metric (0 % = exact color only; 100 % = everything). → `PaintBucketToolTests.toleranceZeroIsExact`, `.toleranceHundredFillsAll`, `.regionMatchesFloodFillOracle`
- [ ] Left = primary, right/Control-click = secondary. → `PaintBucketToolTests.buttonsPickColors`
- [ ] Antialiased fill adds the one-pixel feather ring with exactly `featherCoverage(k)`; aliased fill has binary edges. → `PaintBucketFillTests.featherValues`, `.antialiasedStraightEdge`, `.antialiasedCorner`, `.aliasedIsBinary`, `.featherClippedToCanvas`
- [ ] Compositing equals 0009's rule through `BlendOps` (semi-transparent colors, semi-transparent destination, blend mode from the options). → `PaintBucketFillTests.composeMatchesBlendOps`, `.zeroAlphaColorIsNoOp`
- [ ] With a selection: the flood neither matches nor crosses unselected pixels, coverage is multiplied by the selection mask, and a click outside the selection does nothing (TOOL-B). → `PaintBucketToolTests.floodStopsAtSelection`, `.antialiasedSelectionEdgeScalesCoverage`, `.clickOutsideSelectionIsNoOp`, `PaintBucketSessionTests.fillInsideRectangleSelection`, `PaintBucketUITests.fillIsClippedToSelection`
- [ ] Fill = Selection fills the whole selection (its own AA edge) ignoring tolerance; with no selection it fills the whole layer. → `PaintBucketToolTests.fillSelectionModeIgnoresTolerance`, `.fillSelectionWithoutSelectionFillsLayer`
- [ ] Image sampling reads the composite but writes only the active layer. → `PaintBucketToolTests.imageSamplingWritesActiveLayerOnly`
- [ ] Each effective click is one "Paint Bucket" step (icon `paintBucket`); undo restores the layer exactly, redo re-applies it; no-op clicks add no step. → `PaintBucketToolTests.historyUndoRedo`, `.noOpClicksAddNoStep`, `PaintBucketUITests.clickFillsAndUndoes`
- [ ] Off-canvas clicks, no active layer, and huge canvases don't crash. → `PaintBucketToolTests.offCanvasClickIsNoOp`, `.noActiveLayerIsNoOp`, `PaintBucketPerformanceTests.testLargeContiguousFill`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report. → quality-gate launch smoke (`quality-gate.sh`)

## Edge cases

- **Seed off-canvas** (negative, ≥ size, NaN/∞ location): no-op, no step, surface `generation` unchanged. → `PaintBucketToolTests.offCanvasClickIsNoOp`
- **1×1 canvas:** contiguous fill covers the one pixel; AA adds no ring (nothing outside the canvas). → `PaintBucketFillTests.onePixelCanvas`
- **Region touching the canvas edge / spanning tile boundaries:** feather counts only in-canvas neighbours; tiles across the 256 boundary filled seamlessly. → `PaintBucketFillTests.featherClippedToCanvas`, `.tileBoundary`
- **Region = whole canvas** (e.g. uniform image): AA ring empty; every pixel covered 255.
- **Unallocated (transparent) tiles:** a contiguous fill on a fresh transparent layer allocates exactly the tiles it writes; Layer sampling treats unallocated tiles as `(0,0,0,0)`. → `PaintBucketToolTests.unallocatedTilesAllocatedOnlyWhenWritten`
- **Color alpha 0**, or blend result identical to the existing pixels (filling white on white with Normal): empty diff, no step.
- **Semi-transparent color / destination:** straight-alpha Normal formula from 0009; color under alpha 0 handled exactly as `BlendOps` defines.
- **Selection:** seed in a pixel with selection coverage 0 → no-op; seed in a partially selected (AA edge) pixel → allowed, coverage scaled; an empty selection is "no selection" (0013), so the whole layer is fillable.
- **Fill = Selection with no selection:** fills the whole layer (like Edit › Fill Selection with nothing selected); Shift has no effect.
- **Image sampling on a hidden active layer:** the composite excludes the hidden layer; the fill still writes the active (hidden) layer. → `PaintBucketToolTests.imageSamplingWritesActiveLayerOnly`
- **Escape/Return:** nothing pending, default `keyDown` returns false. → `PaintBucketToolTests.cursorIsCrosshair`
- **Large images** (4000×3000 global fill): completes, one diff of only changed tiles; memory stays within the per-tile coverage map.

## Test plan

- **Unit tests — `PaintDotMacTests/Tools/PaintBucketFillTests.swift`** (pure `PaintBucketFill`, hand-computed expectations; regions are `FloodFillStencil`s built with `insert` from a hand-listed `Set<PixelPoint>`):
  - `featherValues`: `featherCoverage(neighbours:)` for k = 0…8 → `[0, 28, 57, 85, 113, 142, 170, 198, 227]`.
  - `aliasedIsBinary`: 10×10, region = rect (2,2)–(5,5) inclusive, AA off → coverage 255 inside, 0 at every other pixel; `bounds == (2,2,4,4)`.
  - `antialiasedStraightEdge`: 10×10, region = columns 0…4 (all rows), AA on → (4,y) 255; (5,y) for y in 1…8 → 85 (k=3); (5,0) and (5,9) → 57 (k=2, canvas edge); (6,y) → 0.
  - `antialiasedCorner`: 10×10, region = single pixel (5,5) → (5,5) 255; its 8 neighbours 28; (7,5) 0. Region = 2×2 block (4,4)–(5,5) → (3,3) 28, (3,4) 57, (6,5) 57, (6,6) 28.
  - `featherClippedToCanvas`: region = (0,0) on a 3×3 → (1,0) 28, (0,1) 28, (1,1) 28, nothing out of range accessed; `coverage(x: -1, y: 0) == 0`.
  - `onePixelCanvas`: 1×1, region {(0,0)}, AA on → coverage (0,0) 255, `tiles.count == 1`, `bounds == (0,0,1,1)`.
  - `tileBoundary`: 300×10, region = x ≤ 255 → (256, 5) = 85 lives in tile (1,0); `tiles.keys == {(0,0), (1,0)}`.
  - `composeMatchesBlendOps`: 4×1 surface `[(255,255,255,255), (0,0,255,128), (0,0,0,0), (10,20,30,255)]`, coverage `[255, 255, 128, 85]`, color `(200,0,0,200)`, Normal → each pixel equals the 0009 Normal formula computed by hand in the test (independent restatement: `Sa = (200·cov + 127)/255`, then the integer source-over formula); e.g. pixel 0: Sa 200 → `(212,55,55,255)` (compute and pin all four values in the test from the formula).
  - `clipMultipliesCoverage`: coverage 255 everywhere, clip `[255, 128, 0]` → effCov `[255, 128, 0]`; pixel 2 untouched; touched tiles only where written.
  - `zeroAlphaColorIsNoOp`: color alpha 0 → returned touched set empty, surface `generation` unchanged.
  - `identicalResultWritesNothing`: opaque white surface, color white, Normal → no tile touched.
  - `selectionCoverageCopiesMask`: test clip with values 0/77/255 → `selectionCoverage` equals the mask; `nil` clip → 255 at all canvas pixels.
- **Unit tests — `PaintDotMacTests/Tools/PaintBucketOptionsTests.swift`**: `defaultsMatchPaintNET` (similarColor, contiguous, 50, layer, true, normal); `roundTripThroughStore` (set every option, new tool instance reads them back; keys are exactly `tool.paintBucket.fillMode/floodMode/tolerance/samplingMode/antialiasing/blendMode`; Magic Wand keys untouched); `invalidStoredValues` (tolerance −5 → 0, 400 → 100; `fillMode "foo"` → similarColor; `floodMode "foo"` → contiguous; `samplingMode "foo"` → layer; `blendMode "foo"` → normal).
- **Unit tests — `PaintDotMacTests/Tools/PaintBucketToolTests.swift`** (`FakeToolContext` with `DocumentState` + `HistoryStack`, `ColorSelection`; selections are set on the fake's `DocumentState.selection` (built with 0013's `Selection(rect:canvasSize:antialiased:)` or `Selection(mask:outline:)` from a hand-built `SelectionMask`), so `selection` and `paintClipMask` agree):
  - `contiguousStopsAtBorder`: 20×20 white with a black vertical line at x = 10; click (3.5, 3.5), AA off, primary red → every x < 10 red, x = 10 black, x > 10 white.
  - `globalFillsDisconnectedAreas`: same image, floodMode global → both white halves red, line black.
  - `shiftClickIsGlobal`: contiguous option + `.shift` → same result as global; option stays `contiguous` in the store.
  - `toleranceZeroIsExact`: white image with one `(254,255,255,255)` pixel; tolerance 0, global → that pixel unchanged, all others red. `toleranceHundredFillsAll`: tolerance 100, contiguous, from the line image → every pixel red.
  - `regionMatchesFloodFillOracle`: 50 seeded random 32×32 images of 4 palette colors × random tolerance/mode/seed, AA off, opaque color → filled pixels == `FloodFill.fill(...)`'s stencil for the same inputs (0016's metric is tested there; this checks the wiring); seed printed on failure.
  - `buttonsPickColors`: primary red / secondary blue; `.primary` click → red; `.secondary` → blue; `.primary` + `.control` → blue.
  - `floodStopsAtSelection`: uniform white 20×20; pixelated clip = x < 8; contiguous, AA on → pixels x < 8 red; x ≥ 8 white (feather ring is masked to 0 by the clip). Traversal check: clip = x < 8 **or** x ≥ 12 (two selected bands joined only through unselected columns 8…11), click (3.5, 3.5), contiguous → only x < 8 filled; x ≥ 12 stays white (the flood doesn't cross unselected pixels); with Global both bands fill.
  - `antialiasedSelectionEdgeScalesCoverage`: clip x < 8 → 255, x == 8 → 128, else 0; uniform white, black fill, AA off → (8,y) = `(127,127,127,255)`, (9,y) white.
  - `clickOutsideSelectionIsNoOp`: clip as above, click (15.5, 5.5) → no step, `imageUpdates` 0.
  - `fillSelectionModeIgnoresTolerance`: line image, Fill = Selection, clip = x in 5…14 (crossing the line), tolerance 0 → x 5…14 all red (including the black line), rest unchanged. `fillSelectionWithoutSelectionFillsLayer`: no clip → whole layer red.
  - `imageSamplingWritesActiveLayerOnly`: two layers: bottom white with black line at x = 10, top (active) transparent; Sampling = Image, contiguous, click (3.5,3.5) → top layer red for x < 10 and transparent elsewhere; bottom layer unchanged. Same setup with Sampling = Layer → whole top layer red (uniform transparent layer).
  - `historyUndoRedo`: fill → history names `["New Image", "Paint Bucket"]`, icon `.paintBucket`; undo → layer tiles equal the before tiles (`sharesStorage` or pixel-equal); redo → equal to after.
  - `noOpClicksAddNoStep`: color alpha 0; white on white; fully clipped → history unchanged each time.
  - `offCanvasClickIsNoOp` (locations (−1, 5), (20, 5), (5, 20), NaN) and `noActiveLayerIsNoOp`.
  - `cursorIsCrosshair`: on canvas `.crosshair`, nil location `.arrow`; `hasPendingEdit` false after a click; `keyDown(.escape)` and `keyDown(.returnKey)` return `false` and add no step.
  - `unallocatedTilesAllocatedOnlyWhenWritten`: 600×600 fully transparent layer (no allocated tiles), pixelated rect selection (10,10,20,20), contiguous red click at (15.5,15.5), AA off → allocated tile coordinates == `{(0,0)}`; the 20×20 rect red, everything else `(0,0,0,0)`.
- **Unit tests — `ToolRegistryTests.paintBucketKey`**: `shortcutGroup(for: "f") == [.paintBucket]`; `implementedIDs` contains `.paintBucket`.
- **Property test — `PaintBucketToolTests.undoRedoProperty`:** 200 seeded random fills (random 64×64 images of 3 colors with alpha, random options, buttons, optional random clip): apply → undo restores identical tiles, redo identical to the after-state; a feathered fill never changes a pixel whose coverage is 0 (checked against an oracle coverage computed by a naive 3×3 loop in the test).
- **Integration test — `PaintDotMacTests/Integration/PaintBucketSessionTests.swift`:** `fillInsideRectangleSelection`: new 64×64 white image (0005 helper) behind an `UndoBridge`; Rectangle Select (0014) (16,16)–(48,48); Paint Bucket contiguous at (32.5, 32.5) black → inside black, outside white; history `["New Image", "Rectangle Select", "Paint Bucket"]`; undo ×2 → white, no selection; redo ×2 → same result; export PNG via 0005's encoder, decode → same pixels.
- **UI tests — `PaintDotMacUITests/PaintBucketUITests.swift`** (fixture generated at test time: 200×200 PNG, left half opaque red `(255,0,0)`, right half opaque white; `UITestApp`):
  - `pressingFSelectsToolAndShowsOptions`: type `f` → `tool.paintBucket` selected; `toolOptions.fillMode` "Similar Color", `toolOptions.floodMode` "Contiguous", `toolOptions.tolerance` "50%", `toolOptions.samplingMode` "Layer", `toolOptions.antialiasing` on, `toolOptions.blendMode` "Normal".
  - `clickFillsAndUndoes`: ⌘0, click canvas at normalized (0.75, 0.5) → last `historyRow` "Paint Bucket", Edit menu "Undo Paint Bucket"; ⌘S, decode the PNG → (150,100) `(0,0,0,255)`, (50,100) `(255,0,0,255)`; ⌘Z → last row "Open Image".
  - `fillIsClippedToSelection`: press S (Rectangle Select), drag over the right-half middle region (normalized (0.6,0.4)→(0.9,0.6)); F, click inside → after save: a pixel inside the selection black, (190, 10) still white.
  - `optionsPersistAcrossRelaunch`: set Flood mode Global and Fill Selection, relaunch without `-UITestResetDefaults`, F → both values restored.
- **Performance — `PaintDotMacTests/Performance/PaintBucketPerformanceTests.swift`** (XCTest `measure`): `testLargeContiguousFill`: 4000×3000 opaque white layer, contiguous, AA on, one click → time to fill + diff. No PRD §6 target applies; fail only above 5 s (gross regression), report the number in the Verification status.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification**
  1. Draw an antialiased black circle with the Paintbrush on white, F, click inside with red at 800 %: fill meets the circle with a soft one-pixel feather, no white gap ring; with Antialiasing off the edge is hard and a light fringe from the circle's AA pixels may remain (Paint.NET-like).
  2. Raise tolerance to ~60 % and repeat: the fill eats into the AA fringe.
  3. Shift-click on an image with disconnected same-color areas: all are filled.
  4. Ellipse-select (antialiased), Fill = Selection, click inside: the whole ellipse fills with soft edges; clicking outside does nothing.
  5. Two layers, Sampling = Image: fill on an empty top layer follows the shapes on the layer below.
  6. Right-click and Control-click fill with the secondary color.

## Decisions (confirmed by the user; PRD §5.3 T-9, §12 D-42)

- **Commit on click.** The fill is applied and committed on the click as one "Paint Bucket" history step (Paint.NET 3.x behavior). There is no live, editable fill; changing options affects the next click.
- **Fill option.** A **Fill** option: "Similar Color" (default) / "Selection". Selection fills the whole active selection with its own antialiased mask, ignoring tolerance, flood mode, sampling, and the antialiasing toggle; with no selection it fills the whole layer.
- **Antialiasing.** The one-pixel 3×3-box feather ring outside the matched region: coverage `max(mask, box3(mask))` with box3 = round(255·k/9) for k matched neighbors in the 3×3 box; it never reduces coverage inside the matched region.
- **Tolerance Alpha Mode.** Follows 0016, which uses Paint.NET 3.36's `CheckColor` metric as-is and does not adopt Paint.NET 5's Tolerance Alpha Mode. So the Paint Bucket has no alpha-mode option and no `tool.paintBucket.toleranceAlphaMode` key.

## Out of scope

- Paint.NET Fill Styles (patterned fills using both colors) — not in PRD T-9.
- Live fill editing, seed nub, Finish button (see Decisions), and Paint.NET 5's Tolerance Alpha Mode (follows 0016).
- The tolerance metric, flood algorithms, and Magic Wand (0016); Edit › Fill Selection / Erase Selection (0018); blend modes other than Normal (0026, 0027, 0059 — they appear in this tool's blend popup automatically); Recolor tolerance (0057).
