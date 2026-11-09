# 0011 — Add the Pencil and Eraser tools

> Source: PRD.md §5.3 T-12 (Eraser, key E: width, hardness, antialiasing as on the Paintbrush, no blend mode; strength = alpha of the color slot in use; fully erased → (0,0,0,0)), T-13 (Pencil, key P, "Aliased, one pixel wide"), §12 D-27 (Eraser options and strength; Overwrite not in v1.0), D-38 (continuous strokes; brush-outline cursor), D-15 (tool blend list = implemented layer modes), H-6 / D-34 (no-op edits add no step), TOOL-A (primary/secondary), TOOL-B (selection clipping, wired in 0013), TOOL-C (options persist); §4 / NF-9 (straight 8-bit sRGB RGBA); §6 NF-1, NF-4; AGENTS.md architecture rules 2, 3, 4, 6.
> Paint.NET docs: Pencil — https://paint.net/doc/latest/Pencil.html · Eraser — https://paint.net/doc/latest/EraserTool.html · Blend modes (tool blend modes, Overwrite) — https://paint.net/doc/latest/BlendModes.html · Tool Bar (antialiasing toggle) — https://paint.net/doc/latest/Toolbar.html (all fetched 2026-11-04; `getpaint.net/doc/latest/…` redirects there).
> Milestone: M1
> Depends on: 0006-tool-framework-and-panels, 0007-colors-panel, 0008-history-stack-and-undo-bridge, 0009-paintbrush-tool, 0010-history-panel (UI test reads its rows)

## Context
Not yet implemented; there is no application code. When this spec starts, the following exist (use their exact names and signatures):

- 0006: `Core/Tools/ToolEvent.swift` (`ToolID.pencil`/`.eraser`; `ToolEvent.location` = canvas space, image pixels, `Double`, top-left origin, y down; `button` `.primary`/`.secondary` — right button and Control-left both arrive as `.secondary`), `Core/Tools/Tool.swift` (`@MainActor protocol Tool: AnyObject`: `id`, `hasPendingEdit`, `activate/deactivate(context:)` (default `deactivate` commits a pending edit), `mouseDown/mouseDragged/mouseUp/mouseMoved(_:context:)`, `keyDown(_:context:)` (default Return commits, Escape cancels), `cursor(at:modifiers:) -> ToolCursor`, `commit(context:)`, `cancel(context:)`, `optionsDidChange(context:)`; `displayName`/`shortcutKey` from the descriptor table, which already lists `eraser` "Eraser" `e` (`eraser` symbol) and `pencil` "Pencil" `p` (`pencil` symbol) in the drawing group right after `paintbrush`), `Core/Tools/ToolContext.swift` (`image`, `options`, `setOverlay(_:)`, `invalidateCursor()`, …), `Core/Tools/ToolRegistry.swift` (`ToolRegistry.standard()`, `shortcutGroup(for:)`), `Core/Tools/ToolOptionStore.swift` (`ToolOptionKey<V>`, `InMemoryToolOptionStore`), `Core/Tools/ToolDispatcher.swift` (tool switches requested during a gesture apply when it ends), `UI/ToolsPanelView.swift`, `UI/ToolOptionsBar.swift`, `Canvas/CanvasInputRouter.swift`, test double `FakeToolContext`.
- 0007: `Core/Model/ColorSelection.swift` (primary/secondary `ColorRGBA8`, including alpha), `ToolContext.colors`.
- 0008: `TileDiffHistoryItem(name:icon:diff:)` (no-op when `diff.isEmpty`), `HistoryIcon` (already has `.pencil` and `.eraser`), `TileDiff`, `HistoryStack`, `ToolContext.commitHistory(_:)`, `UndoBridge` (`prepareForNavigation` commits the active tool's pending edit before undo/redo/jump; Edit menu "Undo <name>").
- 0009: `Core/Rendering/BlendOps.swift` (`BlendOps.blend(_:dst:src:opacity:)`, `mul255`, `.normal` only), `Core/Tools/BrushEngine.swift` (`BrushOptions` with `keys(for:)`, `load(from:tool:)`, `save(to:tool:)`, defaults width 2 / hardness 75 / antialiasing on, width 1–2000, hardness 0–100; `BrushClipMask`; `StrokeCoverageBuffer`; `BrushStroke` (`begin`/`extend` continuous segment sweep with max-combined per-stroke coverage, `mark(x:y:coverage:on:)`, `cancel(on:)`, `makeTileDiff(from:layerID:)`, compose closure `BrushCompose` that always receives the before-stroke pixel); `BrushWidthAdjustable.adjustBrushWidth(by:context:)`), `Core/Tools/BrushOutline.swift` + `ToolOverlay.brushOutline(CGRect)` (brush-outline cursor), `Core/Tools/PaintbrushTool.swift` (the reference for stroke lifecycle: `hasPendingEdit` during a stroke, writes through `ToolContext.updateImage(_:)`, clip from `ToolContext.paintClipMask`, commit via `commitHistory`, empty diff → no step, `cancel(context:)` restores the layer), toolbar identifiers `toolOptions.width`, `toolOptions.hardness`, `toolOptions.antialiasing`, `toolOptions.blendMode`.
- 0010: the History panel (`historyList`, `historyRow.<index>`).

### Paint.NET behavior mirrored
**Pencil** (Pencil.html): "The Pencil Tool is used to draw a single pixel at a time"; dragging makes a one-pixel-wide line. Left button paints with the Primary color, right button with the Secondary color. It "inherits the opacity of the source color". A Tool Bar blend mode can be applied: the pixels behave "as if they were on their own layer" with that blend mode (BlendModes.html: "as if the tool was being used on a new layer"). The Pencil has no width, hardness, or antialiasing option (it is always aliased). Paint.NET's tool blend-mode list additionally contains **Overwrite** (a tool-only "copy" mode, BlendModes.html); it is not in v1.0 (PRD D-27, D-15).

**Eraser** (EraserTool.html): circular tip; options Brush size (`[`/`]`), Hardness ("ignored when Antialiasing is off"), Antialiasing, plus Spacing, Path Smoothing, Selection Quality, Pressure Sensitivity (not in v1.0: PRD D-38 and TOOL-D; see Out of scope). PRD T-12 / D-27 settle PaintDotMac's Eraser: width, hardness, and antialiasing only (no blend mode), strength = alpha of the color slot in use, a fully erased pixel becomes (0,0,0,0). Strength comes from the color slot's alpha: "The left mouse button uses the Primary color's Alpha value. The right mouse button uses the Secondary color's Alpha value." Worked examples on an opaque layer: alpha 60 → resulting opacity 255−60 = 195; alpha 120 → 135; alpha 255 → 0. "Areas *completely* erased will have the original RGB color information replaced with black (#000000)." Partial erasure keeps the original RGB and lowers opacity. The Eraser page documents no blend mode.

## User story
As a PaintDotMac user, I press **P** and drag to draw crisp one-pixel lines in the primary (left-drag) or secondary (right-/Control-drag) color, and I press **E** and drag to erase the active layer to transparency with a round, adjustable brush, each stroke appearing in the History panel as "Pencil" or "Eraser" and undoable with ⌘Z.

## Scope & changes

### Core (headless, unit-tested)

- **`Core/Tools/PixelLine.swift`** (new, pure): `enum PixelLine { static func pixels(from a: PixelPoint, to b: PixelPoint) -> [PixelPoint] }` plus a non-allocating visitor `static func forEachPixel(from:to:_ body: (PixelPoint) -> Void)`. Exact algorithm (integer all-octant Bresenham, error form, both endpoints **inclusive**):
  ```
  dx = |x1 − x0|, sx = x0 < x1 ? 1 : −1
  dy = −|y1 − y0|, sy = y0 < y1 ? 1 : −1
  err = dx + dy
  loop:
    visit(x0, y0)
    if x0 == x1 && y0 == y1: break
    e2 = 2 × err
    if e2 >= dy: err += dy; x0 += sx
    if e2 <= dx: err += dx; y0 += sy
  ```
  Properties: visits exactly `max(|dx|, |dy|) + 1` pixels, consecutive pixels are 8-connected, first is `a`, last is `b`, `a == b` visits one pixel. Use `Int` (64-bit) arithmetic so `2 × err` cannot overflow for any coordinate in the clamp range below.
- **Pixel mapping of a `ToolEvent` point** (in `PencilTool`): canvas point `(x, y)` maps to pixel `(Int(floor(x)), Int(floor(y)))` — pixel `(i, j)` covers `[i, i+1) × [j, j+1)` in canvas space (0006's `ToolEvent.location` convention, the same as 0009's brush model). The mapping is a pure `static func PencilTool.pixel(for point: CGPoint) -> PixelPoint?` (nil for non-finite input), unit-tested. Non-finite coordinates (NaN/±∞) are ignored (the event is a no-op). Finite coordinates are clamped to `[-65_536, 131_071]` before flooring so a wild event can never produce an unbounded loop.
- **`Core/Tools/PencilTool.swift`** (new): `@MainActor final class PencilTool: Tool`; `id = .pencil` (name "Pencil", key `p`, its own single-tool key group, from 0006's descriptor table). Registered by adding `.pencil: { PencilTool() }` to `ToolRegistry.standard()`. Behavior:
  - `mouseDown(_:context:)`: picks the stroke color — `colors.primary` for `.primary`, `colors.secondary` for `.secondary` (right button and Control-left, per 0006) — and builds a 0009 `BrushStroke(canvasSize:, options: BrushOptions(width: 1, hardness: 100, antialiasing: false, blendMode: blendMode), clipMask: context.paintClipMask, compose:)` with 0009's Paintbrush compose rule (`Sa = mul255(color.a, effCov)`, `BlendOps.blend(blendMode, dst: before, src: (color.rgb, Sa))`). It remembers the active layer's `Layer.ID`, marks the pixel under the cursor, and remembers it as `lastPixel`. All writes happen inside `context.updateImage { … }` (0009).
  - `mouseDragged(_:context:)`: maps the point to pixel `p`; if `p == lastPixel` does nothing; otherwise marks every pixel of `PixelLine.pixels(from: lastPixel, to: p)` and sets `lastPixel = p`. `mouseUp(_:context:)` does the same for the up point, then commits. Pixels outside `0..<width × 0..<height` are skipped (`mark` returns `false`; the line is still computed in unbounded integer space, so a stroke that leaves and re-enters the canvas is drawn correctly where it is inside).
  - "Marking" = `BrushStroke.mark(x:y:coverage: 255, on:)`: binary coverage (0 or 255, never anything else), max-combined, through the same clip as the brush (`effCov = mul255(255, clip)`), so 0013 confines it to the selection without touching this file. A pixel marked twice in one stroke is composed once from its before-stroke value, so a semi-transparent color never compounds within a stroke — consistent with Paint.NET's "as if on its own layer". Unmarked pixels are untouched.
  - **Commit** (`mouseUp`, and `commit(context:)` mid-stroke): `context.commitHistory(TileDiffHistoryItem(name: "Pencil", icon: .pencil, diff: stroke.makeTileDiff(from:layerID:)))`; an empty diff records nothing (H-6). `cancel(context:)` restores the layer via `BrushStroke.cancel`. `hasPendingEdit` is true exactly during a stroke. A second mouse-down during a stroke is ignored.
  - Options: `blendMode` only, `ToolOptionKey<BlendMode>(tool: .pencil, name: "blendMode", defaultValue: .normal)` → `tool.pencil.blendMode`; the selectable list is the Paintbrush's (D-15: implemented layer blend modes; `.normal` only today). No width/hardness/antialiasing options. `PencilTool` does not conform to `BrushWidthAdjustable`, so 0009's router ignores `[` and `]` while it is active (no beep, no crash).
  - **Cursor (PRD D-38 decision for the Pencil):** `cursor(at:modifiers:)` → `.crosshair` on the canvas (`.arrow` for `nil`), and **no brush outline** overlay. Paint.NET's Pencil shows a pencil glyph and no brush outline (the tip is always exactly one pixel); 0006's `ToolCursor` has no glyph cursors, so the crosshair's hotspot marks the pixel. The Pencil never calls `setOverlay`.
- **`Core/Tools/EraseOps.swift`** (new, pure): the eraser per-pixel function, separate from `BlendOps` because erasing is not a layer blend mode:
  ```swift
  /// strength = color-slot alpha (0...255); coverage = brush coverage (0...255).
  static func erase(_ p: ColorRGBA8, strength: UInt8, coverage: UInt8) -> ColorRGBA8
  ```
  Exact integer formula (straight alpha, destination-out):
  ```
  e     = strength × coverage                         // 0 ... 65025
  newA  = (p.a × (65025 − e) + 32512) / 65025         // integer division = round-half-up of a × (1 − e/65025)
  if e == 0        → return p unchanged
  if newA == 0     → return (0, 0, 0, 0)              // Paint.NET: completely erased → #000000
  else             → return (p.r, p.g, p.b, newA)     // colour channels untouched
  ```
  Properties: `newA ≤ p.a` always; `strength = 255, coverage = 255` → `(0,0,0,0)`; on an opaque pixel at full coverage, `newA = 255 − strength` exactly (matches the doc's 60 → 195, 120 → 135, 255 → 0).
- **`Core/Tools/EraserTool.swift`** (new): `@MainActor final class EraserTool: Tool, BrushWidthAdjustable`; `id = .eraser` (name "Eraser", key `e`, its own key group, from the descriptor table). Registered by adding `.eraser: { EraserTool() }` to `ToolRegistry.standard()`. Behavior:
  - Uses 0009's `BrushStroke` exactly as `PaintbrushTool` does (continuous segment sweep, coverage profile, hardness, antialiasing, max-combined per-stroke coverage, clip from `context.paintClipMask`, writes in `context.updateImage`), with compose `{ before, coverage in EraseOps.erase(before, strength: strength, coverage: coverage) }`. With antialiasing off, coverage is binary and hardness is ignored (Paint.NET: "If aliasing is selected, the Hardness setting will be ignored") — this is 0009's engine behavior; the Eraser must not re-implement it.
  - Strength (PRD T-12 / D-27) = `colors.primary.a` for `.primary`, `colors.secondary.a` for `.secondary` (right button and Control-left), captured at `mouseDown` for the whole stroke. RGB of the color is irrelevant. The eraser does **not** use `BlendOps` and has no blend mode.
  - **Commit** like the Pencil with `TileDiffHistoryItem(name: "Eraser", icon: .eraser, diff:)`; strength 0 or a stroke that changes nothing → empty diff → no step (H-6). `cancel(context:)`, `hasPendingEdit`, and second mouse-down rules as the Paintbrush.
  - Options (PRD T-12 / D-27): `width`, `hardness`, `antialiasing` only — 0009's `BrushOptions.keys(for: .eraser)` width/hardness/antialiasing keys (`tool.eraser.width`, `tool.eraser.hardness`, `tool.eraser.antialiasing`), same types, ranges, and defaults (2 / 75 / on) as the Paintbrush, independent of the Paintbrush's values. The Eraser reads them with `BrushOptions.load(from:tool: .eraser)` (its `blendMode` is ignored) and writes only those three keys (never `tool.eraser.blendMode`). `adjustBrushWidth(by:context:)` (`[` / `]`) changes `tool.eraser.width` with 0009's step rule (±1, clamped 1–2000).
  - **Brush outline (PRD D-38):** same as the Paintbrush: `cursor` → `.crosshair` on the canvas, and `setOverlay(.brushOutline(BrushOutline.canvasRect(center:options:)))` on move/down/drag, after `adjustBrushWidth` and `optionsDidChange`, `nil` on `deactivate`, using the Eraser's own options.
- **`ToolRegistry.standard()`**: add the two factory lines. The order in the panel and key groups comes from `ToolID` (paintbrush, eraser, pencil, colorPicker, …); no other registry change.

### Platform glue (UI tests + manual checks)
- `UI/ToolsPanelView.swift`: no code change; 0006's generic panel shows the newly implemented tools as `tool.eraser` and `tool.pencil` (labels "Eraser" / "Pencil", SF Symbols `eraser` and `pencil` from the descriptor table).
- `UI/ToolOptionsBar.swift`: Eraser shows width, hardness, antialiasing using the Paintbrush's identifiers (`toolOptions.width`, `toolOptions.hardness`, `toolOptions.antialiasing`); Pencil shows only the blend-mode picker (`toolOptions.blendMode`).
- History panel (0010): rows "Pencil" / "Eraser" appear with the symbols 0010 maps for `.pencil` / `.eraser`; no change in 0010's code.
- `Canvas/CanvasInputRouter.swift`: no change; E and P activate the tools through 0006's key groups, and `[`/`]` reach the Eraser through 0009's `BrushWidthAdjustable` check. Cursor: crosshair only for the Pencil; crosshair plus 0009's brush-outline overlay (drawn by `ToolOverlayView`) at the Eraser's own width.
- New files are under existing source globs; run `xcodegen generate`.
- No PRD change: T-12, T-13, D-27, D-38 already state this behavior.

## Acceptance criteria
- [ ] Pressing P selects the Pencil and E selects the Eraser (tools panel shows them selected). → `PencilEraserUITests.toolKeysSelectTools`, `ToolRegistryTests.pencilAndEraserKeys`, `PencilToolTests.pixelMapping`
- [ ] `PixelLine` produces the exact Bresenham pixel sequence specified above, inclusive endpoints, 8-connected, `max(|dx|,|dy|)+1` pixels. → `PixelLineTests.*`
- [ ] A Pencil click paints exactly the one pixel under the cursor; a drag paints exactly the union of the Bresenham lines between successive event pixels; no other pixel changes; coverage is binary. → `PencilToolTests.clickPaintsOnePixel`, `.dragPaintsBresenhamUnion`, `.noAntialiasing`
- [ ] Pencil left-drag uses the primary color and right-/Control-drag the secondary color, including its alpha (Normal: straight-alpha source-over against the stroke-start pixel; no compounding when the stroke crosses itself). → `PencilToolTests.primaryAndSecondary`, `.semiTransparentOverWhite`, `.selfCrossingDoesNotCompound`
- [ ] Pencil options contain only the blend mode, persisted as `tool.pencil.blendMode`; `[`/`]` do nothing. → `PencilToolTests.optionsAndPersistence`, `.bracketKeysIgnored`
- [ ] Eraser lowers alpha by `EraseOps.erase` exactly: opaque pixel at full coverage with strength 60/120/255 → alpha 195/135/0; RGB unchanged while alpha > 0; fully erased pixels become `(0,0,0,0)`; alpha never increases. → `EraseOpsTests.*`
- [ ] Eraser uses the primary color's alpha for left-drag and the secondary color's alpha for right-/Control-drag; it has no blend-mode option (PRD T-12 / D-27). → `EraserToolTests.strengthFromColorSlot`, `EraserToolTests.optionsPersistIndependently`, `PencilEraserUITests.toolKeysSelectTools`
- [ ] Eraser shape comes from `BrushEngine`: antialiasing off gives binary coverage regardless of hardness; antialiasing on gives soft edges that depend on hardness; overlapping dabs do not compound. → `EraserToolTests.aliasedIgnoresHardness`, `.antialiasedEdgeHandValues`, `.overlappingDabsDoNotCompound`
- [ ] Eraser options width/hardness/antialiasing persist under `tool.eraser.*` independently of the Paintbrush, and `[`/`]` change the Eraser width. → `EraserToolTests.optionsPersistIndependently`, `.bracketKeysChangeWidth`
- [ ] Each stroke is one history step named "Pencil" / "Eraser"; undo restores the exact stroke-start tiles, redo the exact stroke result; Edit menu shows "Undo Pencil" / "Undo Eraser". → `PencilEraserIntegrationTests.undoRedoRoundTrip`, `PencilEraserPropertyTests.revertApplyIdentity`, `PencilEraserUITests.historyStepsAndUndo`
- [ ] Strokes that change nothing (alpha-0 Pencil color, Eraser strength 0, entirely off canvas) add no history step (H-6); Escape mid-stroke restores the layer and adds no step; tool switch or undo mid-stroke commits first. → `PencilToolTests.emptyStrokeAddsNoStep`, `EraserToolTests.zeroStrengthIsEmptyStroke`, `PencilToolTests.cancelMidStrokeRestores`, `EraserToolTests.cancelMidStrokeRestores`, `PencilToolTests.deactivateMidStrokeCommits`
- [ ] Cursor: the Eraser shows 0009's brush outline at its own width (tracking `[`/`]`); the Pencil shows a crosshair and no outline (PRD D-38). → `EraserToolTests.outlineUsesEraserWidth`, `PencilToolTests.cursorIsCrosshairWithoutOutline`; look → manual
- [ ] Strokes that cross tile boundaries and the canvas edge are correct and record only touched tiles. → `PencilToolTests.crossesTileBoundary`, `.leavesAndReentersCanvas`, `EraserToolTests.crossesTileBoundary`
- [ ] Strokes on a fully transparent region are well defined: Pencil paints the color; Eraser leaves `(0,0,0,0)` pixels unchanged as `(0,0,0,0)`. → `PencilToolTests.onTransparent`, `EraseOpsTests.transparentStaysTransparent`
- [ ] Both tools route coverage through the BrushEngine clip hook (so 0013 can confine them to the selection). → `PencilToolTests.respectsClipHook`, `EraserToolTests.respectsClipHook`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases
- 1×1 image: Pencil click at (0.5, 0.5) paints the only pixel; a drag far outside paints nothing more; Eraser click erases it per formula.
- Points exactly on pixel borders (x = 3.0) map to pixel 3; negative fractional points (−0.5) map to −1 and are skipped.
- NaN/∞ event coordinates: ignored, no crash. Huge finite coordinates: clamped, loop bounded.
- `mouseDragged` repeated on the same pixel: no work, no duplicate marking.
- Stroke entirely outside the canvas: changes nothing → empty diff → no history step (H-6).
- Color alpha 0: Pencil with Normal changes nothing (`Sa = 0` returns the destination bit-for-bit) → empty diff → no step; Eraser strength 0 → no change → no step.
- Eraser on pixels with alpha already 0 but non-zero RGB: if `e > 0`, `newA = 0` → returned as `(0,0,0,0)`; documented and tested.
- Rounding boundary: `EraseOps.erase((10,20,30,1), strength: 128, coverage: 255)` → newA = (1×(65025−32640)+32512)/65025 = 64897/65025 = 0 → `(0,0,0,0)`; with strength 127 → (1×32640+32512)/65025 = 65152/65025 = 1 → `(10,20,30,1)`.
- Hidden active layer (painting still happens), Escape mid-stroke (`cancel(context:)` restores), tool switch / undo / save mid-stroke (`commit(context:)` first), and the largest image size: exactly 0009's Paintbrush rules; no new behavior.
- Switching tools mid-drag: 0006's shortcut gate ignores tool keys during a gesture, and a switch requested during a gesture applies when it ends, so a stroke always finishes on the tool that started it.
- Pencil and `[`/`]`: no effect, no beep. Eraser width change mid-stroke applies to the next stroke.

## Test plan
Expected values below are hand-computed from the formulas in this spec and Paint.NET's documentation, never from running the code.

- **Unit tests — `PaintDotMacTests/Tools/PixelLineTests.swift`**
  - `shallowLine`: (0,0)→(5,2) = `[(0,0),(1,0),(2,1),(3,1),(4,2),(5,2)]`.
  - `shallowLineReversed`: (5,2)→(0,0) = `[(5,2),(4,2),(3,1),(2,1),(1,0),(0,0)]`.
  - `steepLine`: (0,0)→(1,3) = `[(0,0),(0,1),(1,2),(1,3)]`.
  - `horizontal`/`vertical`/`diagonal`: (2,7)→(6,7) = x 2…6 at y 7; (4,1)→(4,−2) = y 1,0,−1,−2 at x 4; (0,0)→(−3,−3) = `[(0,0),(−1,−1),(−2,−2),(−3,−3)]`.
  - `singlePoint`: (9,9)→(9,9) = `[(9,9)]`.
  - Property (`SeededRandom`, 1 000 random endpoint pairs in [−300, 300]², seed printed on failure): count = `max(|dx|,|dy|)+1`; first = a; last = b; every consecutive pair has Chebyshev distance exactly 1; every pixel lies within the bounding box of a and b.
  - `extremeCoordinatesDoNotOverflow`: (−65 536, −65 536)→(131 071, 131 071) via `forEachPixel` counts 196 608 pixels.
- **Unit tests — `PaintDotMacTests/Tools/EraseOpsTests.swift`**
  - `docExamples`: `erase((200,100,50,255), strength: 60, coverage: 255)` = `(200,100,50,195)`; strength 120 → `(200,100,50,135)`; strength 255 → `(0,0,0,0)`.
  - `partialCoverage`: `erase((200,100,50,255), strength: 255, coverage: 128)` → e = 32640, newA = (255×32385+32512)/65025 = 8290687/65025 = 127 → `(200,100,50,127)`.
  - `semiTransparentSource`: `erase((10,20,30,100), strength: 255, coverage: 255)` = `(0,0,0,0)`; `erase((10,20,30,100), strength: 51, coverage: 255)` → e = 13005, newA = (100×52020+32512)/65025 = 5234512/65025 = 80 → `(10,20,30,80)`.
  - `roundingBoundary`: the two cases from Edge cases (strength 128 → `(0,0,0,0)`, 127 → `(10,20,30,1)`).
  - `zeroStrengthOrCoverageIsIdentity`: strength 0 or coverage 0 returns the input unchanged, including `(5,6,7,0)`.
  - `transparentStaysTransparent`: `(0,0,0,0)` → `(0,0,0,0)` for all strengths.
  - Exhaustive property over all `a` in 0…255, strength in {1, 60, 128, 254, 255}, coverage in {1, 64, 128, 255}, against an independent round-half-up oracle `Int((Double(a * (65025 - s*c)) / 65025.0 + 0.5).rounded(.down))` (numerator and denominator are exact integers in `Double`, and an `n + 0.5` quotient is exactly representable, so ties round up as in the spec; assert equality): newA matches; newA ≤ a; RGB unchanged when newA > 0; `(0,0,0,0)` when newA = 0.
- **Unit tests — `PaintDotMacTests/Tools/PencilToolTests.swift`** (0006's `FakeToolContext` as extended by 0007–0009: `InMemoryToolOptionStore`, `DocumentState` + `HistoryStack` behind `commitHistory`, settable `paintClipMask`, recorded `overlays`; 16×16 opaque white `(255,255,255,255)` layer unless stated)
  - `pixelMapping`: `PencilTool.pixel(for:)`: (3.0, 4.0) → (3,4); (2.999, 4.0) → (2,4); (−0.5, 0) → (−1, 0); (1e12, −1e12) → (131 071, −65 536); NaN or ∞ → nil.
  - `clickPaintsOnePixel`: primary `(0,0,0,255)`, down+up at (3.5, 4.9) → only pixel (3,4) is `(0,0,0,255)`; all others unchanged.
  - `borderMapping`: click at (3.0, 4.0) → pixel (3,4); click at (2.999, 4.0) → pixel (2,4).
  - `dragPaintsBresenhamUnion`: down (0.5,0.5), drag (5.5,2.5), drag (5.5,6.5), up → painted set = `PixelLine(0,0→5,2) ∪ PixelLine(5,2→5,6)` = {(0,0),(1,0),(2,1),(3,1),(4,2),(5,2),(5,3),(5,4),(5,5),(5,6)}; every other pixel unchanged.
  - `noAntialiasing`: after a diagonal drag every pixel is either exactly the stroke result or exactly unchanged; the coverage buffer contains only 0 and 255.
  - `primaryAndSecondary`: primary `(255,0,0,255)`, secondary `(0,0,255,255)`; left click (1,1) → red; right click (2,2) → blue; Control-left click (3,3) (arrives as secondary) → blue.
  - `semiTransparentOverWhite`: primary `(255,0,0,128)`, Normal → touched pixel `(255,127,127,255)` (source-over: α = 128 + 255×127/255 = 255; G = B = 255×127/255 = 127; R = (255×128 + 255×127)/255 = 255).
  - `onTransparent`: transparent layer, primary `(255,0,0,128)` → touched pixel `(255,0,0,128)`.
  - `selfCrossingDoesNotCompound`: primary `(255,0,0,128)`, drag (0.5,0.5)→(5.5,0.5)→(0.5,0.5) → pixels (0…5, 0) are all `(255,127,127,255)`, not darker.
  - `samePixelDragIsNoOp`: 50 drags inside pixel (4,4) mark one pixel; result identical to a click.
  - `crossesTileBoundary`: 512×512 layer, drag (250.5,10.5)→(260.5,10.5) → pixels x 250…260 at y 10 painted; the history item's tile diff contains exactly tiles (0,0) and (1,0).
  - `leavesAndReentersCanvas`: 16×16, drag (2.5,2.5)→(−10.5,2.5)→(8.5,2.5) → painted = x 0…8 at y 2; no crash, nothing outside written.
  - `nonFiniteIgnored`: drag to (NaN, 3) and (∞, 3) between valid drags → result equals the same stroke without those events.
  - `respectsClipHook`: set `FakeToolContext.paintClipMask` to a test mask allowing only x < 3 → drag (0.5,0.5)→(6.5,0.5) paints only x 0…2.
  - `emptyStrokeAddsNoStep`: primary `(255,0,0,0)` click → layer unchanged, history still only the base step; a stroke entirely at x < 0 → same.
  - `cancelMidStrokeRestores`: down + drag, `cancel(context:)` → layer pixel-identical to before, no step, `hasPendingEdit == false`.
  - `deactivateMidStrokeCommits`: down + drag, `deactivate(context:)` → exactly one "Pencil" step.
  - `cursorIsCrosshairWithoutOutline`: `cursor(at: (1,1), …)` → `.crosshair`, `cursor(at: nil, …)` → `.arrow`; after move/down/drag/up the fake's `overlays` is empty.
  - `undoRedo`: stroke, undo through the fake's stack → layer equals the pre-stroke copy; redo → equals the post-stroke copy.
  - `optionsAndPersistence`: Pencil exposes only `blendMode`; setting it writes `tool.pencil.blendMode`; a new `PencilTool` over the same store reads it back; default `.normal`; offered list equals the Paintbrush's list.
  - `bracketKeysIgnored`: `[`/`]` with the Pencil active change no option value.
  - `historyName`: committed step name is exactly `"Pencil"` and its icon is `HistoryIcon.pencil`.
- **Unit tests — `PaintDotMacTests/Tools/EraserToolTests.swift`** (64×64 opaque `(200,100,50,255)` layer unless stated)
  - `aliasedHardPixel`: antialiasing off, width 1, primary alpha 255, click at (10.5,10.5) → (10,10) is `(0,0,0,0)`; all other pixels unchanged (0009's aliased w=1 footprint is one pixel).
  - `strengthFromColorSlot`: primary alpha 60, secondary alpha 120, antialiasing off, width 5: left click centre pixel → `(200,100,50,195)`; right click elsewhere → `(200,100,50,135)`; Control-left → 135.
  - `aliasedIgnoresHardness`: antialiasing off, width 9, hardness min vs max → identical result layers, and each pixel is either `(0,0,0,0)` or unchanged.
  - `antialiasedEdgeHandValues`: antialiasing on, width 20, strength 255, click at (32.5, 32.5) (0009 profile, `R = 10.5`, then `EraseOps.erase`). Hardness 50: pixels (32,32) and (37,32) → `(0,0,0,0)`; (40,32) (d=8, cov 118) → `(200,100,50,137)`; (41,32) (d=9, cov 51) → `(200,100,50,204)`; (42,32) (d=10, cov 6) → `(200,100,50,249)`; (43,32) (d=11) unchanged. Hardness 100: (40,32) and (41,32) → `(0,0,0,0)`; (42,32) (cov 128) → `(200,100,50,127)`; (43,32) unchanged.
  - `overlappingDabsDoNotCompound`: antialiasing off, strength 128, drag back and forth over the same 30 px three times → every touched pixel has alpha exactly 127 (= 255−128), none lower.
  - `rgbUntouchedWhilePartial`: every pixel after any stroke with strength < 255 has RGB `(200,100,50)`.
  - `crossesTileBoundary`: 512×512, horizontal stroke over x = 256 → tiles (0,0) and (1,0) in the diff and both sides erased.
  - `respectsClipHook`: like the Pencil test, erased pixels only where the clip allows.
  - `optionsPersistIndependently`: set eraser width 37, paintbrush width 5 → `tool.eraser.width` = 37 and `tool.paintbrush.width` = 5; new tool instances read them back; eraser defaults are width 2, hardness 75, antialiasing on; after any Eraser option change the store has no `tool.eraser.blendMode` key.
  - `bracketKeysChangeWidth`: `]` then `[` with the Eraser active change `tool.eraser.width` by 0009's step rule and leave `tool.paintbrush.width` untouched.
  - `zeroStrengthIsEmptyStroke`: primary alpha 0 → no pixel changes and the history stack still has only the base step.
  - `cancelMidStrokeRestores`: as for the Pencil.
  - `outlineUsesEraserWidth`: eraser width 30, paintbrush width 5; `mouseMoved` at (20, 20) → last overlay `.brushOutline((5, 5, 30, 30))`; `adjustBrushWidth(by: +1, context:)` → `(4.5, 4.5, 31, 31)`; `deactivate` → `nil`; `cursor(at: (20,20), …)` → `.crosshair`.
  - `undoRedo`: stroke, undo → pre-stroke layer; redo → post-stroke layer.
  - `historyName`: `"Eraser"` and `HistoryIcon.eraser`.
- **Unit tests — `PaintDotMacTests/Tools/ToolRegistryTests.swift`** (extend): `pencilAndEraserKeys`: `ToolRegistry.standard()` has `shortcutGroup(for: "p") == [.pencil]` and `shortcutGroup(for: "e") == [.eraser]`; `implementedIDs` lists `.paintbrush, .eraser, .pencil` consecutively; `defaultToolID` is still `.paintbrush`.
- **Round-trip and property tests — `PaintDotMacTests/Tools/PencilEraserPropertyTests.swift`** `revertApplyIdentity` (`SeededRandom`, 200 random strokes of 2–20 points on a random-noise 300×300 layer, both tools, random colors/alphas/options; seed printed): applying the history item's revert restores tiles byte-identical to the stroke-start snapshot; re-applying gives byte-identical stroke result; Eraser never increases any alpha and never changes RGB of a pixel whose new alpha > 0; Pencil changes only pixels in the union of the `PixelLine`s of its event pixels.
- **Integration tests — `PaintDotMacTests/Integration/PencilEraserIntegrationTests.swift`**: `undoRedoRoundTrip` — new 100×100 white document, Pencil stroke, Eraser stroke, Pencil stroke through Core; history names `["New Image", "Pencil", "Eraser", "Pencil"]`; undo ×3 → pixels equal the white base; redo ×3 → pixels equal the recorded post-stroke state; a new stroke after one undo discards the redo step.
- **UI tests — `PaintDotMacUITests/PencilEraserUITests.swift`** (fixture: opaque white 200×200 PNG generated at test time, `UITestApp`):
  - `toolKeysSelectTools`: press P → `tool.pencil` is selected and the options bar shows `toolOptions.blendMode` but not `toolOptions.width`; press E → `tool.eraser` selected and `toolOptions.width`, `toolOptions.hardness`, `toolOptions.antialiasing` exist and `toolOptions.blendMode` does not (PRD T-12).
  - `historyStepsAndUndo`: P, drag on `canvas`; E, drag on `canvas`; Edit menu shows "Undo Eraser"; the History panel (0010) rows `historyRow.1` and `historyRow.2` are labelled "Pencil" and "Eraser"; ⌘Z → Edit menu shows "Undo Pencil"; ⇧⌘Z → "Undo Eraser" again.
  - `eraserMakesPixelsTransparent`: E, width 40 via `toolOptions.width`, drag across the canvas center; ⌘S (PNG), read the file back with ImageIO → the image-center pixel is `(0,0,0,0)` and pixel (2,2) is `(255,255,255,255)`.
  - `eraserWidthPersists`: E, press `]` three times, read `toolOptions.width`, relaunch the app (without `-UITestResetDefaults`), press E → same width.
- **Performance** (NF-1 applies to the Eraser, which shares BrushEngine): `PaintDotMacTests/Performance/EraserPerformanceTests.swift` (XCTest `measure`): 4000×3000 opaque layer, width 50, antialiasing on, 200-point diagonal drag → time per `mouseDragged` event. Fail only above 48 ms (3× the 16 ms target); record the measured number in the Verification status. The Pencil's per-event cost is O(segment length) and needs no perf test.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification**
  1. Open a photo, press P, zoom to 800%, drag slowly and quickly: lines are gap-free, exactly one device-aligned image pixel wide, no antialiasing; the cursor is a crosshair whose center sits on the pixel that gets painted, and no circle is drawn. Right-drag paints the secondary color.
  2. Set the primary alpha to ~50% in the Colors panel, draw a self-crossing Pencil scribble: crossings are not darker.
  3. Press E on a single-layer photo: the checkerboard shows through; antialiasing on gives soft edges that sharpen as hardness goes up; antialiasing off gives a hard stair-stepped edge; `[`/`]` resize the brush-outline cursor.
  4. Set the primary alpha to 60 and erase: the area becomes visibly semi-transparent (≈ 76% opaque), not fully cleared.
  5. Quit and relaunch: Eraser width/hardness/antialiasing and Pencil blend mode are restored.

## Out of scope
- Selection clipping (TOOL-B) wiring: 0013 feeds the selection mask into the BrushEngine clip hook; this spec only guarantees both tools go through it.
- History panel UI and icons rendering: 0010.
- Eraser Spacing, Path Smoothing, Selection Quality options (not in v1.0, PRD D-38) and pressure sensitivity (TOOL-D, 0055).
- Shift-constrained straight lines for Pencil/Eraser: not in the PRD.
- Paint.NET's tool-only Overwrite blend mode (not in v1.0, PRD D-27) and any blend mode other than the ones the Paintbrush offers (0026/0027/0059 grow the shared list).
- Color Picker's "switch back to Pencil" option: 0012.
