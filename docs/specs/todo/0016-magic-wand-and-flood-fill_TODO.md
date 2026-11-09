# 0016 — Add the Magic Wand tool on a shared, Paint.NET-exact flood-fill engine

> Source: PRD.md §5.3 T-4 ("Magic Wand — S — Tolerance, flood mode (contiguous or global), sampling (layer or image)"), §5.3 intro and D-13 (S group order Rectangle → Lasso → Ellipse → Magic Wand; selection changes are history steps), T-1 (shared selection modes), TOOL-C (options persist), APP-4 (tolerance in the tool options bar), E-3/TOOL-B, §4 Rendering and D-16 (the CPU compositor is used for image-sampling tools), §6 NF-6 (flood fill has unit tests), §11 R-2 ("Selection antialiasing and the magic wand are hard to get right and fast"), §12 D-28 (Layer/Image sampling as in the Color Picker), D-34 (no-op edits add no step). AGENTS.md rules 1–3, 6–8.
> Paint.NET: Magic Wand, https://paint.net/doc/latest/MagicWand.html (redirect target of https://www.getpaint.net/doc/latest/MagicWandTool.html); Selection Tools, https://paint.net/doc/latest/SelectionTools.html; Paint Bucket, https://paint.net/doc/latest/PaintBucket.html. Tolerance metric and scanline algorithm: Paint.NET 3.36 `FloodToolBase` (`CheckColor`, `FillStencilFromPoint`, `FillStencilByColor`), as ported verbatim (with the Paint.NET copyright header and the comment "These methods are ported from PDN.") in Pinta 1.6, https://raw.githubusercontent.com/PintaProject/Pinta/1.6/Pinta.Tools/Tools/FloodTool.cs. 4-connectivity is unchanged in Paint.NET 4.3's `FillStencilFromPoint` (Rick Brewster's gist, Aug 2021, https://gist.github.com/rickbrew/4146e7baa050a0cc09a19f1acef6f340).
> Milestone: M2
> Depends on: 0014-rectangle-and-ellipse-select (and through it 0013-selection-core-and-marching-ants, 0012-color-picker-tool, 0006, 0008, 0010)

## Context

Not yet implemented: there is no application code yet. When this spec starts, the earlier specs have created the following (exact names from the written specs; never create a parallel type):

- 0002 (`docs/specs/todo/0002-tiled-surface-and-image-decoding_TODO.md:37-131`): `PixelSize`, `PixelPoint`, `PixelRect` (half-open), `ColorRGBA8`, `Tile` (256×256, `bytes`, `withUnsafeBytes`, COW, `sharesStorage(with:)`), `TileCoordinate`, `TiledSurface` (`tile(at:)`, `pixel(at:)` → `.clear` outside bounds/unallocated, `pixelRect(of:)`), `Layer`, `LayeredImage` (`size`, `layers`, `activeLayerIndex`).
- 0006 (`0006-tool-framework-and-panels_TODO.md:44-200`): `ToolID.magicWand`, `ToolEvent` (`location` canvas space Double top-left y-down, `button` `.primary/.secondary` — Control-left arrives as `.secondary` with `.control` kept, `modifiers` `.shift/.option/.control/.command`, `clickCount`), the `@MainActor Tool` protocol, `ToolContext`, `ToolCursor`, `ToolOptionKey<V>` (`init(tool:name:defaultValue:range:)` clamps; String-raw enums conform to `ToolOptionValue` with an empty extension), `ToolOptionStore`, `ToolRegistry` (descriptor row `magicWand | Magic Wand | s | selection | wand.and.stars`; `standard()` factories; `shortcutGroup(for:)`), `UI/ToolOptionsBar.swift`, test doubles `FakeToolContext`, `StubTool`.
- 0008: `HistoryItem.isNoOp`, `HistoryIcon.magicWand` (already listed, `0008…:46`), `ToolContext.performHistory(_:)`. 0010: History panel (`historyList`, `historyRow.<index>`).
- 0012 (`0012-color-picker-tool_TODO.md:36-53`): `CPUCompositor` (`compositeTile(_:of:) -> [ColorRGBA8]?` — `nil` when no visible layer has a tile there; edge tiles clipped to the canvas), `enum SamplingMode: String { case layer, image }` (display "Layer"/"Image"; "0016 … reuses this type"), and the rule that **Layer** sampling reads the active layer's raw stored pixels (ignoring its visibility and opacity, keeping color under alpha 0) while **Image** samples the composite of visible layers. Accessibility id `toolOptions.samplingMode`.
- 0013 (`0013-selection-core-and-marching-ants_TODO.md:28-160`): `SelectionCombineMode`, `SelectionMask` (tiled 256; `.empty/.full/.partial(SelectionMaskTileStorage)`; `init(size:tiles:)` normalizes; edge-tile out-of-canvas bytes are 0), `MaskRasterizer.rasterize(_:size:antialiased:)` (non-zero winding, canvas coordinates), `Selection` with **`init?(mask: SelectionMask, outline: CGPath)` — "0016 Magic Wand: mask from FloodFill, outline traced by 0016"** (stores `outline ∩ canvasRect`; `nil` if the mask is empty), `Selection.combine(_:_:mode:canvasSize:)` (mask algebra is normative; `nil` = no selection), `SelectionHistoryItem(name:icon:before:after:)`, `ToolContext.selection`, marching ants drawn from `selection.path`.
- 0014 (`0014-rectangle-and-ellipse-select_TODO.md:63-176`): `SelectionToolOptions.combineMode` (key `tool.rectangleSelect.selectionMode`, **shared by all selection tools**), `SelectionToolOptions.combineMode(picker:button:modifiers:)` (⌘ → union/xor, ⌥ → exclude/intersect, else picker; **Shift and Control don't affect the mode**), `SelectionCommit.deselectIfNeeded(context:)` (Return/Enter deselects), `UI/SelectionToolOptionsView.swift` (`init(model:showsDrawMode:)`; mode picker `toolOptions.selectionMode`, clipping picker `toolOptions.selectionQuality`), status bar `statusBar.selectionSize`, View > Zoom to Selection.
- 0015: Lasso Select (S group now Rectangle → Lasso → Ellipse).

### Paint.NET behavior mirrored

From the Magic Wand doc page:
- Shortcut "S four times, or Shift + S" (D-13/D-35 cycling already gives this once the tool is registered).
- Selection modes as on the other selection tools, default Replace; Additive = Ctrl, Subtractive = Alt (Mac: ⌘, ⌥ — 0014's mapping).
- **Flood mode** — *Contiguous*: "the selection spreads from the click point until neighboring pixels fail the Tolerance setting"; *Global*: "the selection will extend to *all* the pixels in the layer which satisfy the Tolerance setting." **"The keyboard shortcut to enable Global selection mode is the Shift key."** Mac mapping: **Shift-click** (Shift has no other meaning for the wand, and 0014's mode mapping ignores Shift, so no conflict).
- **Tolerance** slider (the page shows 25 %, 31 %, 50 % examples; no default stated). PaintDotMac default **50 %** (Paint.NET's long-standing default; PRD T-4 / D-43).
- **Sampling** — *Image*: "pixels are polled from the composite image"; *Layer*: "pixels only within the active layer are polled". No default stated; PaintDotMac default **Layer** (Paint.NET 3.x only sampled the layer; same default as 0012; PRD T-4 / D-43).
- Not adopted here (see *Out of scope*): Paint.NET 5's "Tolerance Alpha Mode" (Premultiplied/Straight) and the "Control Nub" that lets the user drag the click point / re-tune the tolerance of an active wand selection.

From Paint.NET 3.36 `FloodToolBase` (exact formulas; the implementer must reproduce them bit for bit):

```csharp
// slider value 0…100 → float Tolerance = value / 100
int tol = (int)(Tolerance * Tolerance * 256);          // OnMouseDown

private static bool CheckColor(ColorBgra a, ColorBgra b, int tolerance)   // a = seed color, b = candidate
{
    int sum = 0; int diff;
    diff = a.R - b.R; sum += (1 + diff * diff) * a.A / 256;
    diff = a.G - b.G; sum += (1 + diff * diff) * a.A / 256;
    diff = a.B - b.B; sum += (1 + diff * diff) * a.A / 256;
    diff = a.A - b.A; sum += diff * diff;
    return (sum <= tolerance * tolerance * 4);
}
```

- All arithmetic is 32-bit integer; `/ 256` truncates (operands are non-negative, so it equals `floor`). The seed's alpha weights the RGB terms, so the metric is **asymmetric**, and a fully transparent seed ignores RGB entirely (any alpha-0 pixel matches it at 0 %).
- Consequences used as test oracles (hand-computed below): 0 % matches only identical pixels (an identical opaque pixel gives `sum = 3 × ⌊255/256⌋ = 0`); the largest possible `sum` is `3 × ⌊65026 × 255 / 256⌋ + 255² = 3 × 64771 + 65025 = 259 338`, below `256² × 4 = 262 144`, so **100 % selects every pixel**; at 50 % (`tol = 64`, limit 16 384) an opaque seed matches a single-channel difference `d` iff `⌊(1 + d²) × 255 / 256⌋ ≤ 16384` ⇔ `d ≤ 128`.
- **`FillStencilFromPoint`** (contiguous): a queue-based **scanline** fill. From each dequeued point it extends left and right along the row while pixels are unvisited and pass `CheckColor`, marks them, then scans the row above and the row below **only over the columns `localLeft…localRight` of that span**, enqueuing the start of each run of unvisited matching pixels. Diagonal neighbours are never examined: **4-connectivity**. Paint.NET 4.3 still does the same (gist above).
- **`FillStencilByColor`** (global): tests every pixel with `CheckColor` against the seed color; rows are independent (`Parallel.For` over rows).
- `limitToSelection` (Paint Bucket only): pixels outside the selection are treated as already visited (barriers) and are never filled.
- The seed color is the sampled pixel under the click; a click outside the canvas does nothing.
- Paint.NET builds the selection outline from the stencil as a polygon set along pixel edges (`PdnGraphicsPath` from a stencil), so the result is pixel-aligned and has hard edges regardless of any antialiasing setting.

## User story

As a PaintDotMac user, I press **S** until **Magic Wand** is active and click a region of similar color: everything connected to the clicked pixel within the **Tolerance** (default 50 %) is selected, with marching ants along its pixel edges. Shift-clicking (or choosing **Global** flood mode) selects every matching pixel in the image instead. **Sampling** chooses whether the active layer or the whole composite image is tested. ⌘/⌥ (or the mode picker) add, subtract, intersect, or invert as with the other selection tools. Each click is one "Magic Wand" history step that ⌘Z undoes, and it is quick even on a 24-megapixel photo.

## Scope & changes

### Core (pure Swift, no AppKit/SwiftUI; unit-tested) — `PaintDotMac/Core/Model/FloodFill.swift` (new)

The engine is shared with 0017 Paint Bucket, so it knows nothing about selections-as-tools or history. All types below live in this one file. Everything is `nonisolated`, `Sendable`, synchronous, and allocation-light; hot loops run over `withUnsafeBytes`/`UnsafeMutablePointer` (not `Array` subscripts or per-pixel closures) so that the Debug test run stays fast.

- **`enum FloodMode: String, CaseIterable, Sendable { case contiguous, global }`** with `displayName` "Contiguous" / "Global" (Paint.NET's words).

- **`struct FloodTolerance: Sendable, Equatable`** — Paint.NET's tolerance scaling.
  - `init(percent: Int)` clamps `percent` to `0…100` and stores it as `percent`.
  - `let scaled: Int` = `Int(t * t * 256)` computed in **`Float`** (C# `float`), `t = Float(percent) / 100`, truncation toward zero (`Int(_:)` of a non-negative `Float`). Table (normative, tested): 0 → 0, 10 → 2, 25 → 16, 30 → 23, 50 → 64, 70 → 125, 99 → 250, 100 → 256.
  - `var maxDistance: Int { scaled * scaled * 4 }` (0 … 262 144).
  - `static let `default` = FloodTolerance(percent: 50)`.

- **`enum FloodColorMetric`** — `static func distance(seed a: ColorRGBA8, candidate b: ColorRGBA8) -> Int` returns Paint.NET's `sum` exactly (formula above, with `a` = seed); `static func matches(seed:candidate:tolerance: FloodTolerance) -> Bool` = `distance ≤ tolerance.maxDistance`. Use `Int` (64-bit) arithmetic; the values are identical to C#'s 32-bit ones because nothing overflows (max intermediate `65026 × 255 = 16 581 630`).

- **`struct FloodFillSource: Sendable`** — the pixels a fill reads, as a grid of 256×256 `Tile?` (0002's type; `nil` = transparent black), so Layer sampling copies nothing.
  - `let size: PixelSize`.
  - `static func layer(_ surface: TiledSurface) -> FloodFillSource` — takes the surface's tiles as they are (COW: `Tile` values share storage with the layer; asserted by a test with `sharesStorage(with:)`).
  - `static func image(_ image: LayeredImage, compositor: CPUCompositor = CPUCompositor()) -> FloodFillSource` — for each tile coordinate, `compositor.compositeTile(_:of:)`; `nil` stays `nil`; otherwise the returned (edge-clipped) pixels are written into a zero-filled `Tile` row by row at stride 256.
  - `static func make(for image: LayeredImage, sampling: SamplingMode, compositor: CPUCompositor = CPUCompositor()) -> FloodFillSource` — `.layer` → `layer(image.layers[image.activeLayerIndex].surface)` (raw pixels; visibility and opacity ignored, per 0012); `.image` → `image(_:)`.
  - `func pixel(at p: PixelPoint) -> ColorRGBA8` — `.clear` outside `size` or in a `nil` tile (used by tests and the seed lookup; the fill loops read tile rows directly).
  - Memory: Layer sampling allocates nothing; Image sampling allocates at most one tile per allocated composite tile (96 MB for a fully allocated 24 MP image), released when the fill returns.

- **`struct FloodFillStencil: Sendable, Equatable`** — the 1-bit result (Paint.NET's `IBitVector2D` stencil).
  - `let size: PixelSize`; storage `[UInt64]`, row-major, **each row padded to whole 64-bit words** (`wordsPerRow = (width + 63) / 64`), so rows never share a word and global mode can fill rows concurrently. Bits beyond `width` are always 0. 24 MP → 3 MB.
  - `init(size:)` (empty); `func contains(_ p: PixelPoint) -> Bool` (`false` outside); `mutating func insert(_ p: PixelPoint)` (no-op outside); `var count: Int` (popcount); `var isEmpty: Bool`; `var bounds: PixelRect` (tight; `.zero` when empty); `func runs(inRow y: Int) -> [Range<Int>]` (maximal runs of set bits, ascending); `func intersection(_ other: FloodFillStencil) -> FloodFillStencil`, `func union(_:)`, `func subtracting(_:)` (word-wise; size mismatch → returns `self`, a defined no-op); `static func from(_ mask: SelectionMask) -> FloodFillStencil` (bit set iff coverage > 0; 0017 builds its "limit to selection" stencil this way).
  - **`func selectionMask() -> SelectionMask`** — coverage 255 where set, 0 elsewhere, built tile by tile with 0013's `SelectionMask(size:tiles:)`: a tile whose in-canvas bits are all set → `.full`, none → `.empty`, else `.partial` with bytes 255/0 (out-of-canvas bytes 0). No per-pixel closure.
  - **`func outline() -> CGPath`** — the pixel-edge boundary as closed polygons in canvas coordinates (y down), suitable for marching ants and for 0013's path booleans:
    1. For each row `y` (only rows in `bounds`), take `runs(inRow: y)` (`R(y)`, with `R(−1) = R(height) = ∅`).
    2. **Horizontal edges** on the grid line `y` (between rows `y−1` and `y`): *top edges* = segments of `R(y) ∖ R(y−1)`, directed **+x** (from `(x0, y)` to `(x1, y)`); *bottom edges* = segments of `R(y−1) ∖ R(y)`, directed **−x** (from `(x1, y)` to `(x0, y)`). Each set difference yields maximal segments.
    3. **Vertical edges** for each run `[x0, x1)` of row `y`: left side from `(x0, y+1)` to `(x0, y)` (−y), right side from `(x1, y)` to `(x1, y+1)` (+y). Join vertical edges of consecutive rows that share the same `x` and direction.
    4. This orientation runs clockwise on screen around every filled region and counter-clockwise around every hole, so **non-zero winding and even-odd give the same fill** (each boundary edge occurs exactly once; tested).
    5. **Link** edges into closed loops through a dictionary from start vertex to unused outgoing edges. At a vertex with two outgoing edges (two regions touching only diagonally, or a hole touching the outside diagonally) take the edge that turns **right** relative to the incoming direction (keeps diagonally-touching pixels as separate loops; either choice fills identically, the rule only makes output deterministic). Emit each loop as `move(to:)`, `addLine(to:)` per corner, `closeSubpath()`, **omitting collinear intermediate vertices**, so a loop has exactly one vertex per corner.
    6. Empty stencil → empty `CGPath`. Coordinates are integers stored as `CGFloat`.

- **`enum FloodFill`** — the algorithms.
  ```swift
  enum FloodFill {
      static func fill(_ source: FloodFillSource, from seed: PixelPoint, tolerance: FloodTolerance,
                       mode: FloodMode, limit: FloodFillStencil? = nil,
                       isCancelled: () -> Bool = { false }) -> FloodFillStencil?
  }
  ```
  - Returns `nil` when `seed` is outside `source.size`, when `limit` is non-nil and does not contain `seed`, when `limit.size != source.size`, or when `isCancelled()` returned `true` (checked once per dequeued span in contiguous mode and once per row band in global mode). Otherwise the result always contains `seed` (a pixel always matches itself: distance 0).
  - Seed color = `source.pixel(at: seed)`.
  - **Contiguous** (port of `FillStencilFromPoint`): explicit FIFO queue of `PixelPoint` (array + head index, no recursion); for each dequeued point, if it is already set or fails the limit, skip; scan left from `x−1` and right from `x` while in bounds, not set, inside `limit` (when given), and matching; set the span; then for the rows `y−1` and `y+1` (when in bounds) walk columns `left…right` and enqueue the first column of every maximal run of not-set, in-limit, matching pixels. **4-connected**: diagonals are only reached through a horizontal/vertical path. Read pixels through tile row pointers (switching tile every 256 columns), not through `pixel(at:)`.
  - **Global** (port of `FillStencilByColor`): every pixel inside `limit` (or every pixel when `limit == nil`) that matches the seed color; rows split into bands processed with `DispatchQueue.concurrentPerform` (each band writes only its own rows' words, so the result is bit-identical to a sequential run; tested). A `nil` source tile is read as `(0,0,0,0)` for its 256 × 256 block without per-pixel work (one comparison decides the whole block row).
  - The function is pure and nonisolated so a later spec (0048 performance pass) can move it off the main actor without changing the API (PRD T-4 / D-43: the fill runs synchronously on click).

### Core — `PaintDotMac/Core/Tools/MagicWandTool.swift` (new)

- **`enum FloodToolOptions`** — option keys shared with 0017 (which calls the same functions with `.paintBucket`):
  - `static func tolerance(for tool: ToolID) -> ToolOptionKey<Int>` → name `"tolerance"`, default 50, range `0...100` → defaults key `tool.magicWand.tolerance`.
  - `static func floodMode(for tool: ToolID) -> ToolOptionKey<FloodMode>` → `"floodMode"`, default `.contiguous` → `tool.magicWand.floodMode`. Add `extension FloodMode: ToolOptionValue {}`.
  - `static func samplingMode(for tool: ToolID) -> ToolOptionKey<SamplingMode>` → `"samplingMode"`, default `.layer` → `tool.magicWand.samplingMode`. 0012's spec declares `ToolOptionValue` only for `SamplingSize` and `ColorPickerAfterClick` (its `samplingMode` key stores the raw string), so add `extension SamplingMode: ToolOptionValue {}` in this file, unless the built 0012 code already declares it (a duplicate conformance does not compile). 0017 reuses it.
  - `static func effectiveFloodMode(stored: FloodMode, modifiers: ToolModifiers) -> FloodMode` — `.global` when `modifiers` contains `.shift`, else `stored` (Paint.NET: Shift = Global).
  - Unknown stored strings → default; out-of-range tolerance → clamped (0006's `ToolOptionKey` sanitize).

- **`final class MagicWandTool: Tool`** (`id = .magicWand`; no pending edit: `hasPendingEdit == false` always).
  - **`mouseDown(_:context:)`** — the whole operation happens here (Paint.NET fills on mouse-down; it gives immediate feedback):
    1. `seed = PixelPoint(x: Int(floor(location.x)), y: Int(floor(location.y)))`; non-finite or outside `context.image.size` → return (no step, no deselect).
    2. `mode = SelectionToolOptions.combineMode(picker: options.value(SelectionToolOptions.combineMode), button: event.button, modifiers: event.modifiers)` (0014; Shift is ignored there).
    3. `flood = FloodToolOptions.effectiveFloodMode(stored: options.value(floodMode(for: .magicWand)), modifiers: event.modifiers)`; `tolerance = FloodTolerance(percent: options.value(tolerance(for: .magicWand)))`; `sampling = options.value(samplingMode(for: .magicWand))`.
    4. `stencil = FloodFill.fill(FloodFillSource.make(for: context.image, sampling: sampling), from: seed, tolerance:, mode: flood)` (no `limit`: the wand's region is combined with the selection afterwards, not limited by it). `nil` → return.
    5. `operand = Selection(mask: stencil.selectionMask(), outline: stencil.outline())` (0013).
    6. `after = Selection.combine(context.selection, operand, mode: mode, canvasSize: context.image.size)`.
    7. `context.performHistory(SelectionHistoryItem(name: "Magic Wand", icon: .magicWand, before: context.selection, after: after))`. A no-op (`before == after`, e.g. Union with a region already selected) adds no step (D-34). An empty result is `nil` (no selection), per 0013.
  - `mouseDragged` / `mouseUp`: no-op (a drag after the click changes nothing; one click = one step).
  - `keyDown`: `.returnKey`/`.enter` → `SelectionCommit.deselectIfNeeded(context:)` (0014's "Enter deselects", same as Rectangle Select); otherwise the protocol default (returns `false`).
  - `cursor(at:modifiers:)` → `.crosshair` (same as the other selection tools; no custom wand cursor in v1.0).
  - The selection's quality option (`toolOptions.selectionQuality`) is **not** used: the outline is on pixel edges, so Pixelated and Antialiased rasterizations are identical (proved by `FloodFillStencilTests.outlineRasterizesBackExactly`).

- **`Core/Tools/ToolRegistry.swift`** (modify): `standard()` registers `.magicWand → MagicWandTool()`. The S group is now complete: Rectangle → Lasso → Ellipse → Magic Wand (D-13). Update 0006's registry list test to include `.magicWand`.

### Platform glue

- **`UI/FloodToolOptionsView.swift`** (new, SwiftUI; 0017 reuses it with `.paintBucket`): `init(model: AppModel, tool: ToolID)`, reading/writing through `model.toolOptions` and `FloodToolOptions`. Left to right:
  1. **Flood mode** — segmented `Picker` "Contiguous" / "Global", `.help("Flood mode (Shift-click for Global)")`, accessibility identifier `toolOptions.floodMode`, accessibility value = selected display name.
  2. **Tolerance** — label "Tolerance:", `Slider` 0…100 step 1, and a trailing text "NN%" (`Text("\(value)%")`, monospaced digits), `.help("Tolerance")`; accessibility identifier `toolOptions.tolerance` on the slider with accessibility value "NN%" (e.g. "50%"); arrow keys on the focused slider change it by 1.
  3. **Sampling** — segmented `Picker` "Layer" / "Image", `.help("Sampling")`, identifier `toolOptions.samplingMode` (same identifier as 0012; only one tool's bar is visible at a time).
- **`UI/SelectionToolOptionsView.swift`** (modify, 0014): add `showsQuality: Bool = true` to the initializer; when `false` the "Selection clipping" picker is omitted. Rectangle/Ellipse/Lasso callers are unchanged.
- **`UI/ToolOptionsBar.swift`** (modify): `case .magicWand:` → `SelectionToolOptionsView(model:, showsDrawMode: false, showsQuality: false)`, a `Divider`, then `FloodToolOptionsView(model:, tool: .magicWand)`.
- No new menu items, no overlay (the result appears as marching ants via 0013), no new launch hooks. The `tool.` prefix is already reset by `-UITestResetDefaults`.
- `project.yml`: no change beyond the new files → run `xcodegen generate`.
- No PRD change in this spec: T-4 and D-43 already record the defaults, the 3.36 metric, 4-connectivity, and synchronous execution.

## Acceptance criteria

- [ ] Pressing S four times within the cycling window (or Shift+S once) from another tool selects Magic Wand; the Tools panel highlights `tool.magicWand`. → `ToolRegistryMagicWandTests.sGroupIsComplete`, `MagicWandUITests.testSKeyCyclesToMagicWand`
- [ ] The tolerance metric is exactly Paint.NET 3.36's `CheckColor` with `tol = (int)(t·t·256)` in `Float`: 0 % matches only identical pixels, 50 % matches an opaque single-channel difference of ≤ 128 and not 129, 100 % matches every pixel, RGB terms are weighted by the seed's alpha (asymmetric). → `FloodToleranceTests.scaledTable`, `.clamps`, `FloodColorMetricTests.*`
- [ ] Contiguous mode selects exactly the 4-connected region of matching pixels around the click; diagonal-only neighbours are not included. → `FloodFillTests.diagonalNeighboursAreNotConnected`, `.contiguousMatchesBFSOracle`, `MagicWandToolTests.clickSelectsContiguousRegion`
- [ ] Global mode (option or Shift-click) selects every matching pixel in the image. → `FloodFillTests.globalMatchesPerPixelOracle`, `MagicWandToolTests.shiftClickIsGlobal`, `.storedGlobalMode`, `MagicWandUITests.testShiftClickSelectsGlobally`
- [ ] Sampling Layer reads the active layer's raw pixels (ignoring visibility/opacity, color under alpha 0 kept); Image reads the `CPUCompositor` composite. → `FloodFillSourceTests.layerSourceIsRawAndShared`, `.imageSourceMatchesCompositor`, `MagicWandToolTests.samplingLayerVsImage`
- [ ] The result is a `Selection` whose mask is binary (0/255) and equals the stencil, and whose outline runs along pixel edges (marching ants, combine modes, Zoom to Selection, status-bar size all work). → `FloodFillStencilTests.selectionMaskMatchesStencil`, `.outlineRasterizesBackExactly`, `.outlineVertexCounts`, `MagicWandToolTests.outlineFollowsPixelEdges`, `MagicWandUITests.testClickSelectsSquareAndUndoes`
- [ ] Replace / Add (union) / Subtract / Intersect / Invert (xor) via the shared picker and ⌘ / ⌥ / right-click combinations combine with the existing selection exactly like Rectangle Select; Shift does not change the mode. → `MagicWandToolTests.combineModes`, `.shiftWithCommandIsGlobalUnion`, `MagicWandUITests.testCommandClickAddsRegion`
- [ ] Each click is one history step "Magic Wand" (icon `magicWand`); undo restores the previous selection exactly, redo re-applies it; a no-op adds no step; a click outside the canvas or a drag adds nothing extra. → `MagicWandToolTests.historyStepUndoRedo`, `.noOpUnionAddsNoStep`, `.clickOutsideCanvasDoesNothing`, `.dragAddsOnlyOneStep`, `MagicWandSessionTests.wandThenPaintIsClipped`
- [ ] Return/Enter deselects (when a selection exists) as with the other selection tools. → `MagicWandToolTests.returnDeselects`
- [ ] Options persist (`tool.magicWand.tolerance` default 50, `tool.magicWand.floodMode` default Contiguous, `tool.magicWand.samplingMode` default Layer; selection mode shared via `tool.rectangleSelect.selectionMode`); the options bar shows mode picker, Flood mode, Tolerance, Sampling, and no clipping picker. → `MagicWandToolTests.optionsDefaultsAndPersistence`, `MagicWandUITests.testOptionsBarAndPersistence`
- [ ] Contiguous and Global fills on a 24 MP image are fast (Release expected well under 0.5 s); gated in the Debug test run at 3 s for the fill and 10 s for the whole click (fill + outline + mask + selection + history); measured numbers reported in the Verification status. → `MagicWandPerformanceTests.*`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report. → quality-gate launch smoke (`quality-gate.sh`)

## Edge cases

- **Click outside the canvas** (negative, ≥ size, non-finite, ±1e9): no fill, no step, selection unchanged. → `MagicWandToolTests.clickOutsideCanvasDoesNothing`, `FloodFillTests.seedOutsideReturnsNil`
- **1×1 image:** click selects the single pixel; Select-All-equivalent mask is `.full`; outline is the unit square. → `FloodFillStencilTests.onePixelImage`, `MagicWandToolTests.onePixelImage`
- **Whole image matches** (solid image or 100 %): mask is all `.full` tiles with no byte storage; outline is the canvas rectangle (4 vertices). → `FloodFillStencilTests.fullStencilIsAllFullTiles`
- **Unallocated (transparent) tiles:** read as `(0,0,0,0)`; clicking a transparent area at 0 % selects every transparent pixel connected to it, across empty tiles, without allocating anything per tile. → `FloodFillTests.unallocatedTilesReadTransparent`
- **Transparent seed:** any alpha-0 pixel matches regardless of its stored RGB (Paint.NET metric). → `FloodColorMetricTests.transparentSeedIgnoresRGB`
- **Regions crossing tile seams / non-multiple-of-256 sizes (300×257) / wide strips (65,535×1):** identical to the oracle; edge-tile out-of-canvas bits and mask bytes stay 0. → `FloodFillTests.contiguousMatchesBFSOracle` (300×257 cases), `FloodFillStencilTests.wideStrip`, `.selectionMaskMatchesStencil`
- **Holes and diagonal touches** (ring, checkerboard, two pixels touching at a corner): the outline fills back to exactly the stencil under both fill rules. → `FloodFillStencilTests.outlineRasterizesBackExactly`
- **Pathological outlines** (1024×1024 checkerboard, global mode at 0 %: 524,288 one-pixel loops): completes, no crash, no cap. → `MagicWandPerformanceTests.testCheckerboardGlobalClick` (gate 20 s Debug)
- **Combine yielding nothing** (Subtract the whole selection, Xor equal region): selection becomes `nil` with one step. → `MagicWandToolTests.combineModes`
- **Hidden active layer / opacity 0 in Layer mode:** still sampled raw (0012 rule). Image mode with every layer hidden: composite is transparent everywhere → global/contiguous selects the whole canvas from any click. → `MagicWandToolTests.samplingLayerVsImage`, `FloodFillSourceTests.imageSourceAllHidden`
- **Cancellation:** `isCancelled` returning `true` → `nil` from `fill` (no partial stencil). → `FloodFillTests.cancellationReturnsNil`
- **`limit` (0017's hook):** acts as a barrier in contiguous mode, intersects in global mode; seed outside the limit or size mismatch → `nil`. → `FloodFillTests.limitIsABarrier`, `.limitSizeMismatchReturnsNil`
- **Escape / tool switch / document switch:** nothing is pending; no-ops. → `MagicWandToolTests.noPendingEdit`
- **Undo while the wand is active:** ordinary selection-step undo (no pending edit). → `MagicWandToolTests.historyStepUndoRedo`
- **Huge images (65,535 × 65,535 cap):** stencil memory = `wordsPerRow × height × 8` (≈ 537 MB at the absolute maximum) — the fill guards the allocation with `ImageLimits.byteCount`-style overflow checks and returns `nil` (no crash) if the multiplication overflows; real documents that size are already gated by APP-10's memory cap. → `FloodFillStencilTests.sizeOverflowIsSafe` (uses a mocked size check, no real allocation)

## Test plan

Expected values come from Paint.NET's formula (hand-computed here) or from simple, independent oracles written in the test target (a per-pixel BFS with an explicit 4-neighbour set; a per-pixel global check; a `ReferenceMask`/per-pixel `[UInt8]` as in 0013). Seeds are printed on failure (`SeededRandom`).

- **Unit — `PaintDotMacTests/Model/FloodToleranceTests.swift`:**
  - `scaledTable`: percent → `scaled`/`maxDistance`: 0 → 0/0; 10 → 2/16; 25 → 16/1024; 30 → 23/2116; 50 → 64/16384; 70 → 125/62500; 99 → 250/250000; 100 → 256/262144.
  - `clamps`: −5 → percent 0; 150 → percent 100.
- **Unit — `PaintDotMacTests/Model/FloodColorMetricTests.swift`:**
  - `identicalIsZero`: `distance` of `(100,100,100,255)` to itself = 0; of `(0,0,0,0)` to itself = 0; `matches` at 0 % → true.
  - `oneStepFailsAtZero`: seed `(100,100,100,255)`, candidate `(101,100,100,255)` → distance 1 (`⌊2·255/256⌋`), no match at 0 %; candidate `(100,100,100,254)` → distance 1, no match at 0 %.
  - `fiftyPercentBoundary`: seed `(0,50,50,255)`; candidate R = 128 → distance `⌊16385·255/256⌋ = 16320` → match at 50 %; R = 129 → `⌊16642·255/256⌋ = 16576` → no match.
  - `transparentSeedIgnoresRGB`: seed `(0,0,0,0)`, candidate `(255,255,255,0)` → distance 0, match at 0 %; candidate `(255,255,255,255)` → 65025 → no at 50 %, yes at 100 %.
  - `extremesAtHundred`: seed `(255,255,255,255)`, candidate `(0,0,0,0)` → distance 259338; no at 99 % (limit 250000), yes at 100 %.
  - `semiTransparentWeighting`: seed `(100,0,0,128)`, candidate `(0,0,0,128)` → `⌊10001·128/256⌋ = 5000`; yes at 50 %, no at 25 % (limit 1024).
  - `asymmetry`: seed `(0,0,0,255)` vs candidate `(255,0,0,128)` → 64771 + 16129 = 80900 (no at 70 %); swapped seed `(255,0,0,128)` vs `(0,0,0,255)` → 32513 + 16129 = 48642 (yes at 70 %, limit 62500).
  - `oracleSweep`: 10 000 seeded random pairs × tolerances {0, 1, 13, 50, 87, 100}: `matches` equals a test-local transcription of the C# `CheckColor` using `Int32` arithmetic and `tol = Int32(Float(p)/100 * Float(p)/100 * 256)` — same formula, written independently from the cited source.
- **Unit — `PaintDotMacTests/Model/FloodFillSourceTests.swift`:**
  - `layerSourceIsRawAndShared`: 600×600 layer, hidden, opacity 10, a pixel `(10,20,30,0)` at (5,5) → `pixel(at: (5,5)) == (10,20,30,0)`; every source tile `sharesStorage(with:)` the layer's tile; unallocated tiles stay `nil`.
  - `imageSourceMatchesCompositor`: 300×300, two seeded random layers with mixed visibility/opacity → every `pixel(at:)` equals `CPUCompositor().composite(image, in: full rect)` pixels; tiles where `compositeTile` is `nil` stay `nil`.
  - `imageSourceAllHidden`: all layers hidden → every tile `nil`, every pixel `.clear`.
  - `makeDispatchesOnSampling`: `.layer` uses `activeLayerIndex` (set to the top layer of two) and `.image` the composite.
- **Unit — `PaintDotMacTests/Model/FloodFillTests.swift`:**
  - `diagonalNeighboursAreNotConnected`: 4×4 black opaque, white at (1,1) and (2,2); contiguous from (1,1) at 0 % → stencil `{(1,1)}`; global → `{(1,1),(2,2)}`.
  - `spanScanCoversConcaveShapes`: a hand-drawn 16×16 "U"/spiral maze of white on black (literal string fixture in the test) → contiguous from inside equals the hand-listed pixel set (proves the above/below rescans reach pockets that open left of the parent span).
  - `contiguousMatchesBFSOracle`: 300 seeded cases on 64×64 and 300×257 images with 2–4 random palette colors (so regions are big and irregular) plus random noise images, random seeds, tolerance ∈ {0, 10, 25, 50, 75, 100} → stencil equals a test-target BFS (4-neighbours) using `FloodColorMetric.matches`.
  - `globalMatchesPerPixelOracle`: same inputs, global → equals the per-pixel check; and equals the result of running the global row loop sequentially (bit-identical concurrency).
  - `toleranceGradient`: 64×1 opaque row, R = 4x → contiguous from x = 0: 0 % → {0}; 50 % → x 0…32 (d = 128 at x = 32; d = 132 at x = 33); 100 % → all 64.
  - `seedAlwaysIncluded`: 100 random noise images at 0 % → stencil contains the seed and `count ≥ 1`.
  - `seedOutsideReturnsNil`: (−1,0), (64,0), (0,64) on 64×64 → `nil`.
  - `unallocatedTilesReadTransparent`: 1024×1024 transparent image with one opaque red 10×10 square at (500,500); contiguous from (0,0) at 0 % → `count == 1024² − 100`, square excluded.
  - `limitIsABarrier`: 64×64 solid white; limit = left half plus right half minus a 1-px vertical wall at x = 32 → contiguous from (5,5) at 100 % = columns 0…31 only; global = limit itself; seed at (32,5) → `nil`.
  - `limitSizeMismatchReturnsNil`; `cancellationReturnsNil` (closure returns true on the first call → `nil`; returns true after N calls → `nil`).
- **Unit — `PaintDotMacTests/Model/FloodFillStencilTests.swift`:**
  - `basics`: insert/contains/count/bounds on 70×3 (row padding: bit 69 of row 0 doesn't leak into row 1); out-of-range insert is a no-op; `runs(inRow:)` on a hand pattern; set algebra on two hand patterns; size mismatch → `self`.
  - `selectionMaskMatchesStencil`: seeded random stencils on 300×257 → `coverage(x,y) == (contains ? 255 : 0)` for every pixel, out-of-canvas coverage 0; a tile fully set → `.full`, unset → `.empty`.
  - `fullStencilIsAllFullTiles`: all bits on 600×600 → `mask.isFull`, `partialTileCount == 0`; outline is one subpath with the 4 corners (0,0),(600,0),(600,600),(0,600).
  - `outlineVertexCounts`: 10×10 square at (2,3) → one subpath, 4 points (2,3),(12,3),(12,13),(2,13) in that (clockwise on screen) order; square with a 2×2 hole → 2 subpaths × 4 points; L-shape → 1 subpath, 6 points; two pixels touching at a corner → 8 corner points total in 2 subpaths; empty → empty path.
  - `outlineRasterizesBackExactly`: 200 seeded random stencils (density 10–90 %, blobs, rings, checkerboards, single pixels, full canvas, 1×1, 300×257 across seams) → `MaskRasterizer.rasterize(outline, size:, antialiased: true)` **and** `antialiased: false` both equal `selectionMask()`; `outline.contains(pixelCenter, using: .winding)` and `.evenOdd` both equal `contains` for every pixel.
  - `onePixelImage`, `wideStrip` (65,535×1 with alternating runs: runs, mask, outline loop count), `sizeOverflowIsSafe`.
- **Unit — `PaintDotMacTests/Tools/MagicWandToolTests.swift`** (`FakeToolContext`, opaque 64×64 unless stated; fixture A = white background, red `(255,0,0,255)` squares at (10,10,20,20) and (40,40,16,16)):
  - `clickSelectsContiguousRegion`: click (15.3,15.7) → `selection.mask` 255 exactly on (10…29)², 0 elsewhere; one step "Magic Wand", icon `.magicWand`; every mask value ∈ {0,255}.
  - `shiftClickIsGlobal`: Shift-click (15,15) → both squares; `storedGlobalMode`: option Global, plain click → both squares.
  - `toleranceOptionIsUsed`: the 64×1 gradient row of `toleranceGradient` with tolerance option 0 / 50 / 100 → 1 / 33 / 64 selected pixels.
  - `samplingLayerVsImage`: two layers 64×64 — bottom (active) opaque white, top a black opaque square (20,20,10,10), visible, opacity 255. Layer sampling, global click (5,5) → whole canvas; Image sampling → whole canvas minus the square. Set the top layer hidden → Image result is the whole canvas.
  - `combineModes`: existing selection = rect (0,0,16,16) via `Selection(rect:)` (pixelated); wand region = first red square; Replace / Union (⌘) / Exclude (⌥) / Intersect (secondary + ⌥) / Xor (secondary + ⌘) / picker set to Intersect with no modifiers → each mask equals the set-algebra oracle pixel by pixel; Exclude of a region covering the selection → selection `nil`.
  - `shiftWithCommandIsGlobalUnion`: ⌘⇧-click → global region unioned with the existing selection.
  - `outlineFollowsPixelEdges`: after `clickSelectsContiguousRegion`, `selection.path.boundingBoxOfPath == (10,10,20,20)`; `path.contains((10.5,10.5))`, not `(9.5,10.5)`.
  - `historyStepUndoRedo`: click, undo → selection identical to before (`==`), redo → identical to after; history names `["New Image", "Magic Wand"]`.
  - `noOpUnionAddsNoStep`: select the square, then ⌘-click inside it → still one "Magic Wand" step.
  - `clickOutsideCanvasDoesNothing`: (−0.5, 3), (64, 3), (NaN, 3) with an existing selection → no new step, selection unchanged.
  - `dragAddsOnlyOneStep`: mouseDown (15,15), drag to (50,50), mouseUp → exactly one step, region of the mouseDown pixel.
  - `returnDeselects`: after a click, `keyDown(.returnKey)` returns true and adds "Deselect"; with no selection returns false.
  - `optionsDefaultsAndPersistence`: fresh in-memory store → tolerance 50, `.contiguous`, `.layer`; defaults keys exactly `tool.magicWand.tolerance`, `tool.magicWand.floodMode`, `tool.magicWand.samplingMode`; stored 150 → 100, −3 → 0, `"bogus"` → defaults; `FloodToolOptions.tolerance(for: .paintBucket).defaultsKey == "tool.paintBucket.tolerance"`; changing `tool.rectangleSelect.selectionMode` changes the wand's picker mode.
  - `onePixelImage`: 1×1 → click (0.5,0.5) selects it; `selection.mask.isFull`.
  - `noPendingEdit`: after a click, `hasPendingEdit == false`; `keyDown(.escape)` returns `false`; `deactivate` and `cancel` add no step and leave the selection unchanged.
  - `effectiveFloodModeTable`: (contiguous, []) → contiguous; (contiguous, [.shift]) → global; (global, []) → global; (contiguous, [.command, .option, .control]) → contiguous.
- **Registry — `PaintDotMacTests/Tools/ToolRegistryMagicWandTests.swift`:** `sGroupIsComplete`: `shortcutGroup(for: "s") == [.rectangleSelect, .lassoSelect, .ellipseSelect, .magicWand]`; `makeTool(.magicWand) is MagicWandTool`.
- **Property — `MagicWandToolTests.undoRedoProperty`:** 100 seeded runs of 1–5 random wand clicks with random modes/tolerances/flood modes on palette images → undo all restores the initial selection, redo all reproduces each intermediate selection exactly.
- **Integration — `PaintDotMacTests/Integration/MagicWandSessionTests.swift`:** `wandThenPaintIsClipped`: new 64×64 image, fixture A painted on the layer; Magic Wand click (15,15); Paintbrush (width 200, black) drag across the whole image → only (10…29)² is black, the rest unchanged (TOOL-B); history `["New Image", "Magic Wand", "Paintbrush"]`; undo ×2 → original pixels and no selection; redo ×2 → same.
- **UI — `PaintDotMacUITests/MagicWandUITests.swift`** (fixtures written at test time with `UITestFixtures.writePNG`: F1 = 200×200 white with one black square (50,50,100,100); F2 = 200×200 white with black squares (20,20,40,40) and (140,140,40,40); `-UITestResetDefaults`; ⌘0 first):
  - `testSKeyCyclesToMagicWand`: press B, then S S S S quickly → `tool.magicWand` selected; options bar shows `toolOptions.selectionMode`, `toolOptions.floodMode` "Contiguous", `toolOptions.tolerance` "50%", `toolOptions.samplingMode` "Layer", and no `toolOptions.selectionQuality`.
  - `testClickSelectsSquareAndUndoes` (F1): click canvas (0.5,0.5) → last `historyList` row "Magic Wand", `statusBar.selectionSize` "100 × 100", Edit menu "Undo Magic Wand" enabled; ⌘Z → selection size empty; ⇧⌘Z → "100 × 100" again.
  - `testShiftClickSelectsGlobally` (F2): click (0.2,0.2) → "40 × 40"; Shift-click (0.2,0.2) → "160 × 160" (bounds of both squares).
  - `testCommandClickAddsRegion` (F2): click (0.2,0.2), ⌘-click (0.8,0.8) → two "Magic Wand" rows, "160 × 160".
  - `testOptionsBarAndPersistence`: set Flood mode "Global", tolerance slider to 0 (adjust to minimum), Sampling "Image"; relaunch without reset → the three controls show "Global", "0%", "Image".
- **Performance — `PaintDotMacTests/Performance/MagicWandPerformanceTests.swift`** (XCTest, Debug test run; fixture built in `setUp` as a 6000×4000 single-layer `TiledSurface`: opaque horizontal gradient R = ⌊x·255/5999⌋, G = B = 128, plus 20 seeded opaque black rectangles of 50–400 px):
  - `testContiguousFill24MP`: `measure` and one `ContinuousClock` timing of `FloodFill.fill` from (0,0) at 50 % contiguous (selects roughly the left half, ~12 MP, around the rectangles) → `XCTAssertLessThan(seconds, 3.0)`.
  - `testGlobalFill24MP`: same, global → `< 3.0`.
  - `testWholeClick24MP`: `MagicWandTool.mouseDown` through `FakeToolContext` (fill + `outline()` + `selectionMask()` + `Selection(mask:outline:)` + `Selection.combine` with an existing rectangle selection in Union mode + history) → `< 10.0`.
  - `testCheckerboardGlobalClick`: 1024×1024 checkerboard, global 0 % click → completes, `< 20.0`.
  - Report all measured numbers in the Verification status. (No PRD §6 target applies directly; NF-1/NF-2 aren't affected because nothing runs per frame. 0048 tightens these.)
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open a photo, press S ×4, click sky at 50 % → ants trace the sky's pixel edges at 800 % (stair-stepped, on pixel boundaries); status bar shows the bounds size.
  2. Lower the tolerance to 10 %, click again → smaller region; raise to 100 % → whole image.
  3. Shift-click a color that appears in separate places → all of them are selected; the Flood mode control is unchanged afterwards.
  4. ⌘-click / ⌥-click / ⌥-right-click / ⌘-right-click → add / subtract / intersect / invert, matching Rectangle Select.
  5. On a 6000×4000 photo, a click feels instant (no visible beach ball); repeat with Global and with Image sampling.
  6. Paint with the brush after a wand selection → paint stays inside the region; ⇧⌘B zooms to the selection.

## Open questions

None. Synchronous execution on click, the defaults (Tolerance 50 %, Sampling Layer), the Paint.NET 3.36 `CheckColor` metric without Tolerance Alpha Mode, and 4-connectivity, which an earlier draft asked about, are settled by PRD T-4 and D-43 and are applied above.

## Out of scope

- Paint Bucket (fill rendering, antialiasing, "fill selection" mode, using `limit`) → 0017; it reuses `FloodFill`, `FloodFillStencil`, `FloodToolOptions`, and `FloodToolOptionsView`.
- Paint.NET 5's Control Nub (dragging the click point / re-tuning the tolerance of an active wand selection) and "Tolerance Alpha Mode" (PRD T-4 / D-43).
- Smoothing or antialiasing the wand outline (Paint.NET's wand result is pixel-aligned).
- `SelectionToolOptions`, the mode mapping, Return-deselects, status-bar selection size, Zoom to Selection → 0014. Selection model, mask, path booleans, marching ants → 0013.
- Moving the selection afterwards → 0019; moving pixels → 0020.
- Off-main-actor execution and final performance tuning → 0048 (PRD T-4).
