# 0012 — Add the Color Picker tool (K) and the CPU reference compositor

> Source: PRD.md §5.3 T-14 (and the shared TOOL-A primary/secondary rule, TOOL-C option persistence), §12 D-28 (sampling sizes, ⌘-click Image sampling, after-click options and defaults), §5.12 (Ctrl → ⌘), PRD.md §4 "Rendering" (D-16: CPU reference compositor used for image-sampling tools), NF-9 (straight sRGB RGBA8, premultiplied only inside the compositor); Paint.NET docs: Color Picker tool, https://paint.net/doc/latest/ColorPicker.html (also mirrored at https://www.getpaint.net/doc/latest/ColorPicker.html)
> Milestone: M1
> Depends on: 0006-tool-framework-and-panels, 0007-colors-panel, 0008-history-stack-and-undo-bridge, 0009-paintbrush-tool, 0010-history-panel (UI test reads its rows), 0011-pencil-and-eraser (the Pencil for "Switch to Pencil tool"); transitively 0002

## Context

Not yet implemented: there is no application code yet. When this spec starts, the earlier specs have created (use these exact names and signatures):

- 0002: `Core/Model/ColorRGBA8.swift` (straight sRGB RGBA8), `PixelSize`, `PixelRect` (half-open; `intersection`), `PixelPoint`, `Core/Model/TiledSurface.swift` (256×256 sparse copy-on-write tiles, `TileCoordinate`, `pixel(at:)` (`.clear` outside bounds or in an absent tile), `tile(at:)`, `readPixels(in:) -> [UInt8]`), `Core/Model/BlendMode.swift` (`.normal` only), `Core/Model/Layer.swift` (`isVisible`, `opacity: UInt8`, `blendMode`, `surface`), `Core/Model/LayeredImage.swift` (`size`, `layers` bottom-to-top, `activeLayerIndex`), test support `TestImages.swift` and `SeededRandom.swift`.
- 0006: `Core/Tools/ToolEvent.swift` (`ToolID.colorPicker`/`.pencil`/`.paintbrush`; `ToolEvent.location` canvas space, image pixels, `Double`, top-left origin; `button` `.primary`/`.secondary` — right button and Control-left both arrive as `.secondary`; `modifiers` with `.command`), `Core/Tools/Tool.swift` (`mouseDown/mouseDragged/mouseUp(_:context:)`, `cursor(at:modifiers:)`, `commit(context:)`/`cancel(context:)` default no-ops, `hasPendingEdit` default false; the descriptor table already lists `colorPicker` "Color Picker", key `k`, symbol `eyedropper`, after `pencil`), `Core/Tools/ToolContext.swift` (`image`, `options`, `previousToolID`, `activateTool(_:)` — deferred until the current event handler returns —, `invalidateCursor()`; `ToolCursor.crosshair`), `ToolRegistry` (`standard()`, `shortcutGroup(for:)`), `ToolDispatcher` (tracks `previousToolID`), `ToolOptionStore` (`ToolOptionKey<V>`, `InMemoryToolOptionStore`), `App/AppModel.swift`, `UI/ToolsPanelView.swift`, `UI/ToolOptionsBar.swift`, `Canvas/CanvasToolSession.swift`, test double `FakeToolContext` (records `activatedTools`, settable `previousToolID`).
- 0007: `Core/Model/ColorSelection.swift` (`ColorSlot` `.primary`/`.secondary`, `ColorSelection`), `Core/Model/ColorHex.swift`, `AppModel.setColor(_:for:)`, `ToolContext.colors` (read-only; 0006 reserves the setter for this spec); `UI/ColorsPanelView.swift` with swatch identifiers `colors.primary` / `colors.secondary` whose accessibility value is `#RRGGBBAA` (uppercase, always 8 digits), and the hex field `colors.hex`.
- 0008: `HistoryStack`, `ToolContext.commitHistory(_:)`/`performHistory(_:)`, `UndoBridge`; edited state follows history. 0009: `Core/Rendering/BlendOps.swift` (`BlendOps.blend(_:dst:src:opacity:)` — opacity scales `src.a` with `mul255` first — and `BlendOps.mul255`, Paint.NET `UserBlendOps` rounding, Normal only), `PaintbrushTool`, `ToolContext.updateImage(_:)`. 0010: History panel (`historyList`, `historyRow.<index>`). 0011: `Core/Tools/PencilTool.swift` (`ToolID.pencil`).

Two things are missing:

1. **The CPU reference compositor.** PRD §4 (D-16) says a deterministic CPU compositor in `Core` is the reference for export, flatten, merge, Copy Merged, and image-sampling tools; the Metal compositor (0024) must match it within ±1. The Color Picker's "Image" sampling mode is its first user, so this spec creates `Core/Rendering/CPUCompositor.swift`. 0016 (Magic Wand / flood fill "Image" sampling), 0021/0030 (Copy Merged), 0024 (flatten, merge down, Metal parity, more blend modes via `BlendOps`), 0028 (`mergedimage.png`) and 0029 (flatten on export) build on it.
2. **The Color Picker tool (T-14).** PRD: "Samples a single pixel or an averaged area (3×3 to 51×51, alpha-weighted), from the layer or the image (⌘-click forces Image, Paint.NET's Ctrl-click). After clicking: do not switch tool (default), switch to the previous tool, or switch to the Pencil." Key **K**. Decided in PRD D-28: sizes Single pixel / 3×3 / 5×5 / 11×11 / 31×31 / 51×51; defaults Single pixel, Layer, Do not switch tool.

Paint.NET behavior mirrored (paint.net/doc/latest/ColorPicker.html):
- "Left-clicking sets the Primary color, right-clicking sets the Secondary color."
- **Sampling Modes**: **Layer** ("Sample Single Layer": only the active layer, as in earlier Paint.NET versions) and **Image** ("Sample All Layers": the composite image, as if all layers were flattened). Holding **Ctrl** while clicking samples the Image (PaintDotMac: **⌘**, per the PRD §5.12 rule Ctrl → ⌘; Control-click is already the secondary button on the Mac per TOOL-A).
- **Sampling Size**: squares of **one pixel, 3x3, 5x5, 11x11, 31x31 and 51x51**; when the area covers several colors they are averaged into one color.
- **After Click**: "**Do not switch tool**", "**Switch to previous tool**", "**Switch to Pencil tool**".
- The picked color includes alpha (the Colors panel has alpha, C-2).

## User story

As a PaintDotMac user, I press **K**, click a pixel with the left mouse button to make it my primary color (or right-click / Control-click for the secondary color), optionally averaging a 3×3 … 51×51 area and sampling either the active layer or the whole image, and, if I chose "Switch to previous tool", I'm back on my Paintbrush right after the click. Picking never adds a History step and never marks the document as edited.

## Scope & changes

### Core (headless, unit-tested)

- **`PaintDotMac/Core/Rendering/CPUCompositor.swift`** (new) — `struct CPUCompositor: Sendable` with no stored state (an instance so later specs can add options such as a background):
  - `func composite(_ image: LayeredImage, in rect: PixelRect) -> CompositedRegion` — intersects `rect` with the canvas bounds `(0, 0, image.size)`; returns the clipped rect and its pixels row-major (`[ColorRGBA8]`, count = width × height; empty when the intersection is empty). Define `struct CompositedRegion: Equatable, Sendable { let rect: PixelRect; let pixels: [ColorRGBA8] }` in the same file (0002's `readPixels(in:)` returns raw bytes without a rect, so this is a new type).
  - `func compositeTile(_ coordinate: TileCoordinate, of image: LayeredImage) -> [ColorRGBA8]?` — the composite of one 256×256 canvas tile (edge tiles clipped to the canvas, matching how `TiledSurface` stores edge tiles). Returns `nil` when **no visible layer with opacity > 0 has an allocated tile at that coordinate** (the result would be fully transparent; keeps sparse tiles sparse).
  - `func flattened(_ image: LayeredImage) -> TiledSurface` — a new surface of `image.size` built tile by tile from `compositeTile`; tiles where `compositeTile` returns `nil` stay unallocated. (Used by 0024+ for Flatten/Merge/export; tested here.)
  - **Algorithm (the contract 0024's Metal compositor must match within ±1):** per pixel, start from transparent `(0,0,0,0)`; for each layer **bottom to top** that `isVisible` and has `opacity > 0`: `dst = BlendOps.blend(layer.blendMode, dst: dst, src: src, opacity: layer.opacity)` (0009) where `src` is the layer's stored straight pixel; 0009's `blend` applies the opacity as `src.a = BlendOps.mul255(src.a, opacity)` (Paint.NET's exact rounding, `round(a·b / 255)`) before the mode function. The compositor defines no rounding helper of its own.
  - Inputs and outputs are **straight** (non-premultiplied) RGBA8. Any premultiplication is internal to the blend step and never escapes the compositor (AGENTS.md rule 4). The compositor does not mutate any layer and does not touch history.
  - Fast paths that must be bit-identical to the general path: skip hidden layers and layers with opacity 0; skip unallocated (fully transparent) tiles of a layer; when the destination is fully transparent and the mode is Normal, `dst = src` with opacity applied.
  - Blend modes: whatever `BlendMode` cases `BlendOps` supports (only `.normal` today; 0026/0027/0059 add cases to both and the compositor gets them for free via `BlendOps`).
- **`PaintDotMac/Core/Model/PixelSampler.swift`** (new):
  - `enum SamplingSize: Int, CaseIterable, Sendable { case singlePixel = 1, region3 = 3, region5 = 5, region11 = 11, region31 = 31, region51 = 51 }` with `var displayName: String`: "Single pixel", "3 x 3 region", "5 x 5 region", "11 x 11 region", "31 x 31 region", "51 x 51 region". (Sizes per PRD T-14 / D-28 and Paint.NET's doc, "one pixel, 3x3, 5x5, 11x11, 31x31 and 51x51". The doc page does not spell out the menu labels; these labels are a stated decision of this spec, changeable without affecting behavior.)
  - `enum SamplingMode: String, CaseIterable, Sendable { case layer, image }` with display names "Layer" and "Image". `SamplingMode` does **not** conform to `ToolOptionValue` in this spec (the `tool.colorPicker.samplingMode` key stores its raw `String`); 0016 adds `extension SamplingMode: ToolOptionValue {}`. 0016 (Magic Wand, Paint Bucket) reuses this type for their "Sampling" option.
  - `enum PixelSampler` with:
    - `static func sampleRect(center: PixelPoint, size: SamplingSize, canvas: PixelSize) -> PixelRect?` — the square `[x − h, x + h] × [y − h, y + h]` with `h = (n − 1) / 2`, intersected with the canvas; `nil` when `center` is outside the canvas (`x < 0 || y < 0 || x ≥ width || y ≥ height`).
    - `static func average(_ pixels: [ColorRGBA8]) -> ColorRGBA8` — **alpha-weighted (premultiplied) averaging**, chosen so fully transparent pixels contribute no color and edges of semi-transparent areas don't darken: with `n = count`, `S_a = Σ aᵢ`, `S_c = Σ cᵢ·aᵢ` for c ∈ {r, g, b} (integer `Int` arithmetic; max 2601 × 255 × 255 fits easily):
      - if `S_a == 0` → `(0, 0, 0, 0)`;
      - else `c = (2·S_c + S_a) / (2·S_a)` (round half up), `a = (2·S_a + n) / (2·n)` (round half up).
      - Precondition: `pixels` is non-empty (callers never pass an empty array; assert in debug, return `(0,0,0,0)` in release).
    - `static func sample(_ image: LayeredImage, at point: PixelPoint, size: SamplingSize, mode: SamplingMode, compositor: CPUCompositor = CPUCompositor()) -> ColorRGBA8?`
      - `nil` when `point` is outside the canvas or the image has no layers / an out-of-range `activeLayerIndex` (defensive; never crash).
      - **Single pixel:** returns the source pixel **exactly as stored**, including the RGB of a fully transparent pixel (no averaging, no zeroing).
      - **Area sizes:** averages only the pixels inside the clipped `sampleRect` (count = clipped pixel count, not n²) with `average(_:)`.
      - **Layer mode:** source = the active layer's stored pixels, read raw from its `TiledSurface`: the layer's visibility, opacity, and blend mode are **ignored** (Paint.NET samples the layer's own pixels).
      - **Image mode:** source = `compositor.composite(image, in: sampleRect)` — only the sampled rect is composited, never the whole image.
- **`PaintDotMac/Core/Tools/ColorPickerTool.swift`** (new) — conforms to `Tool`:
  - `@MainActor final class ColorPickerTool: Tool`, `id = .colorPicker` ("Color Picker", key **K**, its own single-tool key group, position after `.pencil` — all from 0006's descriptor table and `ToolID` order). Registered by adding `.colorPicker: { ColorPickerTool() }` to `ToolRegistry.standard()`.
  - Options (TOOL-C, via `context.options` with `ToolOptionKey(tool: .colorPicker, name:, defaultValue:)`, keys `tool.colorPicker.<option>`; defaults per PRD T-14 / D-28):
    | Key | Type / stored value | Default | Toolbar label |
    |---|---|---|---|
    | `tool.colorPicker.samplingSize` | `Int` raw value of `SamplingSize` (1, 3, 5, 11, 31, 51) | `1` (Single pixel) | "Sampling:" popup |
    | `tool.colorPicker.samplingMode` | `String` raw value of `SamplingMode` (`layer`/`image`) | `layer` | "Layer" / "Image" segmented control |
    | `tool.colorPicker.afterClick` | `String` raw value of `ColorPickerAfterClick` | `doNotSwitch` | "After click:" popup |
    Unknown or out-of-range stored values fall back to the default (no crash): `SamplingSize` and `ColorPickerAfterClick` opt into `ToolOptionValue` through their raw values, so an unknown raw value reads as missing.
  - `enum ColorPickerAfterClick: String, CaseIterable, Sendable { case doNotSwitch, switchToPreviousTool, switchToPencil }` (same file) with display names exactly "Do not switch tool", "Switch to previous tool", "Switch to Pencil tool", and a pure decision function:
    `func toolToActivate(current: ToolID, previous: ToolID?) -> ToolID?` — `doNotSwitch` → `nil`; `switchToPreviousTool` → `previous` when it is non-nil and `!= .colorPicker`, else `nil`; `switchToPencil` → `.pencil` (0006's `ToolID`).
  - Gesture behavior:
    - **`mouseDown(_:context:)`:** map the event's `location` to a pixel with `floor` on each axis (so `(9.999, 0.0)` → `(9, 0)` and `(-0.01, 5)` → `(-1, 5)`, i.e. outside). Effective mode = `.image` when the ⌘ (command) modifier is held, otherwise the stored `samplingMode`. Sample with `PixelSampler.sample`. If non-nil, call `context.setColor(sample, for: .primary)` for `button == .primary`, `.secondary` for `button == .secondary` (right-click and Control-click arrive as `.secondary` from 0006). Remember that the gesture picked a color.
    - **`mouseDragged(_:context:)`:** same as mouseDown at the new point, using the button from mouseDown and the ⌘ state of the current event (live update while dragging, as in Paint.NET). Points outside the canvas leave the color unchanged.
    - **`mouseUp(_:context:)`:** sample once more at the up point (same rules). Then, **only if the gesture picked at least one color**, evaluate `afterClick.toolToActivate(current: .colorPicker, previous: context.previousToolID)` and, when non-nil, call `context.activateTool(id)` (0006 defers the switch until the gesture's `pointerUp` returns; the dispatcher then records `.colorPicker` as the new previous tool). A gesture that never touched the canvas changes nothing and does not switch tools.
    - The tool never calls `commitHistory`/`performHistory` or `updateImage`, never mutates pixels, and never marks the document as edited: **picking is not a history step**.
    - `commit(context:)` and `cancel(context:)` keep 0006's no-op defaults and `hasPendingEdit` stays `false` (no pending state survives a gesture). `cursor(at:modifiers:)` → `.crosshair` on the canvas, `.arrow` for `nil`.
- **`Core/Tools/ToolContext.swift`** (extend; 0006 reserves "0012 adds a color setter", 0007 the path through `AppModel.setColor`): `func setColor(_ color: ColorRGBA8, for slot: ColorSlot)`. `CanvasToolSession` forwards to `AppModel.setColor(_:for:)` (which persists and updates the Colors panel, 0007). `FakeToolContext` applies it to its own `colors` and records `setColorCalls: [(ColorRGBA8, ColorSlot)]`. `activateTool(_:)` and `previousToolID` already exist (0006); previous-tool tracking stays in 0006's dispatcher and this spec only reads it.

### Platform glue (UI tests + manual checks)

- `ToolOptionsBar` (0006) shows, when the Color Picker is active: a "Sampling:" popup (accessibility id `toolOptions.samplingSize`, items `SamplingSize.displayName`), a "Layer"/"Image" segmented control (`toolOptions.samplingMode`), and an "After click:" popup (`toolOptions.afterClick`, items `ColorPickerAfterClick` display names). Each writes through `ToolOptionStore`. Built from the tool's options model the way 0006/0009 build the Paintbrush bar; no tool-specific AppKit code in `Core`.
- Tools panel button `tool.colorPicker` (SF Symbol `eyedropper`, help tag "Color Picker (K)") and the **K** key come from 0006's generic panel and shortcut code once the tool is registered; no tool-specific glue.
- Canvas cursor while the tool is active: `.crosshair` from `cursor(at:modifiers:)`, mapped to `NSCursor.crosshair` by 0006's `ToolCursor+AppKit.swift`. → `ColorPickerToolTests.cursorIsCrosshair`
- No new menu items. No `project.yml` changes beyond the new source files; run `xcodegen generate` after adding them.
- PRD: no update needed (T-14, D-28, and §4 D-16 already cover this; the option labels are this spec's decision, see `SamplingSize`).

### Performance

The CPU compositor is not on the display path (Metal is, from 0003/0024), so NF-1/NF-2 are unaffected. Image sampling composites at most 51×51 pixels per mouse event. A timed test guards against compositing the whole image by accident (see Test plan).

## Acceptance criteria

- [ ] K activates the Color Picker; its Tools panel button is `tool.colorPicker`. → `ColorPickerUITests.kKeyActivatesColorPicker`, `ToolRegistryColorPickerTests.kResolvesToColorPicker`
- [ ] Left-click sets the primary color to the sampled color (including alpha); right-click and Control-click set the secondary color; the other color is unchanged. → `ColorPickerToolTests.leftClickSetsPrimaryOnly`, `.rightClickSetsSecondaryOnly`, `ColorPickerUITests.clickPicksPrimaryAndRightClickPicksSecondary`
- [ ] Dragging updates the color live; the final color is the one under the mouse-up point; dragging outside the canvas leaves the last color. → `ColorPickerToolTests.dragUpdatesLive`, `.dragOutsideCanvasKeepsLastColor`
- [ ] Sampling sizes Single pixel, 3 x 3, 5 x 5, 11 x 11, 31 x 31, 51 x 51 region; areas average with alpha weighting over the pixels inside the canvas only. → `PixelSamplerTests.*`
- [ ] Layer mode samples the active layer's raw pixels (ignoring its visibility and opacity); Image mode samples the composite of visible layers; ⌘-click forces Image. → `PixelSamplerTests.layerVsImageMode`, `.layerModeIgnoresVisibilityAndOpacity`, `ColorPickerToolTests.commandClickSamplesImage`
- [ ] After click: "Do not switch tool" keeps the Color Picker, "Switch to previous tool" reactivates the previously used tool (no-op when there is none), "Switch to Pencil tool" activates the Pencil; nothing switches when the click was outside the canvas. → `ColorPickerAfterClickTests.*`, `ColorPickerToolTests.afterClick*`, `ColorPickerUITests.switchToPreviousToolReturnsToPaintbrush`
- [ ] Picking adds no History step, changes no pixels, and does not mark the document edited. → `ColorPickerToolTests.pickingIsNotAHistoryStep`, `ColorPickerUITests.pickingAddsNoHistoryRow`
- [ ] The three options persist under `tool.colorPicker.samplingSize|samplingMode|afterClick` with defaults Single pixel / Layer / Do not switch tool (PRD D-28); bad stored values fall back to defaults; the toolbar shows them and they survive relaunch. → `ColorPickerToolTests.optionsPersistAndDefault`, `.invalidStoredOptionsFallBack`, `ColorPickerUITests.switchToPreviousToolReturnsToPaintbrush`
- [ ] The canvas cursor is a crosshair while the Color Picker is active. → `ColorPickerToolTests.cursorIsCrosshair`
- [ ] `CPUCompositor` composites visible layers bottom to top with layer opacity through `BlendOps`, straight in/out, exact Paint.NET rounding, sparse tiles stay sparse, and region/tile/flatten results agree. → `CPUCompositorTests.*`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Canvas edges:** area squares are clipped to the canvas; the average divides by the clipped count (51×51 at `(0,0)` averages 26×26 = 676 pixels). A 1×1 image sampled with 51×51 returns its single pixel (for an opaque pixel; alpha-weighted rules otherwise).
- **Outside the canvas** (negative coordinates, `x == width`, `y == height`, far outside at any zoom): `sample` returns `nil`; the tool changes no color and does not switch tools.
- **Sub-pixel/zoom:** pixel mapping uses `floor` of the canvas-space point (correct at 1% and 3200%, 1×/2× backing scale; the transform itself is 0003's).
- **Transparent pixels:** Single pixel returns the stored pixel unchanged (e.g. `(10,20,30,0)`); an area that is fully transparent returns `(0,0,0,0)`; transparent pixels in a mixed area add no color but do lower the average alpha.
- **Hidden / zero-opacity active layer:** Layer mode still returns the raw pixels; Image mode excludes the layer.
- **All layers hidden:** Image mode returns `(0,0,0,0)` (composite over transparent, no white background).
- **Tile boundaries:** areas spanning tiles (e.g. 3×3 centered at `(256,256)`) read from all touched tiles, including unallocated (transparent) ones.
- **Defensive model states:** zero layers or an out-of-range `activeLayerIndex` → `nil`, no crash.
- **Overflow:** sums use `Int` (max `2601·255·255 ≈ 1.7×10⁸`).
- **No previous tool** (Color Picker was the first tool used) with "Switch to previous tool": stays on the Color Picker.
- **Previous tool is the Color Picker itself:** treated as no previous tool.
- **⌘ + right-click:** secondary color, Image mode.
- **Undo/redo:** not applicable to picking (not a history step); undo after picking undoes the previous pixel step and leaves the picked colors as they are (colors are app state, not document state).

## Test plan

- **Unit tests — `PaintDotMacTests/Rendering/CPUCompositorTests.swift`** (Swift Testing; images built with `TestImages`):
  - `emptyImageIsTransparent`: a 300×300 image with one layer with no allocated tiles → `composite(in: full rect)` is all `(0,0,0,0)` and `flattened` has zero allocated tiles.
  - `singleOpaqueLayerIsIdentity`: random opaque pixels (seeded) on one visible layer, opacity 255 → composite equals the layer pixels exactly.
  - `hiddenLayerIsIgnored`: bottom opaque red `(255,0,0,255)`, top opaque blue hidden → `(255,0,0,255)`.
  - `zeroOpacityLayerIsIgnored`: same with the top visible at opacity 0 → `(255,0,0,255)`.
  - `layerOpacityHalfOverWhite`: bottom opaque white, top opaque red at opacity 128 → exactly `(255,127,127,255)` (hand calc: `srcA = mul255(255,128) = 128`, `G = 255·127/255 = 127`).
  - `semiTransparentOverTransparent`: one layer `(0,0,255,128)` → `(0,0,255,128)` (straight values preserved, not premultiplied).
  - `semiTransparentOverOpaque`: bottom `(255,0,0,255)`, top `(0,0,255,128)` → `(127,0,128,255)`.
  - `twoSemiTransparentLayers`: bottom `(255,0,0,128)`, top `(0,0,255,128)` → `(85,0,170,192)` (hand calc: `y = mul255(128,127) = 64`, `x = mul255(128,128) = 64`, `aOut = 192`, `R = 255·64/192 = 85`, `B = (255·64 + 255·64)/192 = 170`).
  - `regionIsClippedToCanvas`: `composite(in: (-5,-5,20,20))` on a 10×10 image → returned rect `(0,0,10,10)`, 100 pixels; a rect fully outside → empty rect and no pixels.
  - `regionAcrossTileBoundaryMatchesPerPixel`: 600×600, three seeded random layers with mixed visibility/opacity; `composite(in: (250,250,20,20))` equals the same pixels from `flattened(_:)` and from `compositeTile` of the four tiles touched.
  - `sparseTilesStaySparse`: 1024×1024, a layer with a single painted pixel in tile (2,1) → `compositeTile` returns `nil` for every other tile; `flattened` has exactly one allocated tile.
  - `compositorDoesNotMutateLayers`: layer tiles are identical (by value) before and after `flattened`.
- **Property / oracle test — `CPUCompositorPropertyTests.randomStacksMatchFloatOracle`:** 50 seeded random stacks (1–4 layers, 64×64 plus a 300×300 one spanning tiles, random straight pixels including alpha 0 and 255, random visibility and opacity); oracle in the test target: Porter-Duff source-over in `Double` on straight values (with `as = (a/255)·(opacity/255)` and `ad` the accumulated alpha in 0…1: `aOut = as + ad(1 − as)`, `c = (cs·as + cd·ad(1 − as)) / aOut`, then `round(aOut·255)` and `round(c)`) → every channel within ±1 of `CPUCompositor`; RGB compared only where oracle `aOut > 0`. Seed printed on failure (`SeededRandom`).
- **Unit tests — `PaintDotMacTests/Model/PixelSamplerTests.swift`:**
  - `sampleRectClipping`: center `(0,0)` size 3 on 10×10 → `(0,0,2,2)`; center `(5,5)` size 51 on 10×10 → `(0,0,10,10)`; center `(10,3)` → `nil`; `(-1,0)` → `nil`; size 1 → 1×1 rect.
  - `singlePixelReturnsStoredPixelExactly`: pixel `(10,20,30,0)` → `(10,20,30,0)`; `(1,2,3,4)` → `(1,2,3,4)`.
  - `uniformAreaReturnsSameColor`: opaque `(12,34,56,255)` everywhere, each size at the center of a 100×100 image → `(12,34,56,255)`.
  - `alphaWeightedNotStraightAverage`: 3×3 area with 4 opaque red `(255,0,0,255)` and 5 `(0,0,0,0)` → `(255,0,0,113)` (a straight average would give R = 113; this test must fail for straight averaging).
  - `alphaWeightedWithEdgeClippingAndRounding`: 2×2 image `(0,0)=(255,0,0,255)`, `(1,0)=(0,0,255,85)`, `(0,1)=(0,255,0,0)`, `(1,1)=(255,255,255,170)`, size 3 at `(0,0)` (clipped to 4 pixels) → `(213,85,128,128)` (hand calc: `S_a = 510`; `R = 108375/510 = 212.5 → 213`; `G = 43350/510 = 85`; `B = 65025/510 = 127.5 → 128`; `A = 510/4 = 127.5 → 128`).
  - `fullyTransparentAreaIsClear`: all `(200,100,50,0)`, size 5 → `(0,0,0,0)`.
  - `largestAreaAtCornerUsesClippedCount`: 100×100, pixels at `x < 13` opaque white, else opaque black; size 51 at `(0,0)` → clipped 26×26: white fraction 13/26 → `(128,128,128,255)` (`255·338/676 = 127.5 → 128`).
  - `areaAcrossTileBoundary`: 3×3 at `(256,256)` on a 512×512 layer where only tile (1,1) is allocated with opaque green → 4 of 9 pixels opaque green: `(0,255,0,113)`.
  - `layerVsImageMode`: bottom `(255,0,0,255)`, active top `(0,0,255,128)`: Layer → `(0,0,255,128)`; Image → `(127,0,128,255)`.
  - `layerModeIgnoresVisibilityAndOpacity`: active layer hidden or at opacity 10 → Layer mode still returns its raw pixel.
  - `imageModeWithAllLayersHidden`: → `(0,0,0,0)`.
  - `outsideCanvasReturnsNil`: points `(-1,0)`, `(0,-1)`, `(w,0)`, `(0,h)` → `nil` for both modes and all sizes.
  - `defensiveStates`: image with no layers / `activeLayerIndex` out of range → `nil`.
  - `oneByOneImage`: 1×1 opaque `(9,8,7,255)`, size 51 → `(9,8,7,255)`.
- **Unit tests — `PaintDotMacTests/Tools/ColorPickerAfterClickTests.swift`:** full table of `toolToActivate`: doNotSwitch → nil (with and without previous); switchToPreviousTool with previous `paintbrush` → `paintbrush`, previous nil → nil, previous `colorPicker` → nil; switchToPencil → `pencil` (with any previous). Display names equal the three Paint.NET strings exactly.
- **Unit tests — `PaintDotMacTests/Tools/ColorPickerToolTests.swift`** (0006's `FakeToolContext` as extended by 0007–0009 and this spec: `InMemoryToolOptionStore`, `DocumentState` + real `HistoryStack` behind `commitHistory`, `colors`, `setColorCalls`, `activatedTools`, settable `previousToolID`):
  - `leftClickSetsPrimaryOnly` / `rightClickSetsSecondaryOnly`: start primary black, secondary white; click on a `(10,200,30,255)` pixel → only the matching color changes, to exactly that value.
  - `clickAtFractionalPointUsesFloor`: point `(4.999, 0.2)` picks pixel `(4,0)`; `(-0.01, 0)` changes nothing.
  - `dragUpdatesLive`: down on red, drag over green (color is green after the drag event), up on blue → final primary blue.
  - `dragOutsideCanvasKeepsLastColor`: down on red, drag to `(-50,-50)`, up at `(-50,-50)` → primary red.
  - `commandClickSamplesImage`: option mode Layer, two-layer image from `layerVsImageMode`; plain click → `(0,0,255,128)`; ⌘-click → `(127,0,128,255)`.
  - `samplingSizeOptionIsUsed`: option size 3 on the 9-pixel red/transparent fixture → `(255,0,0,113)`.
  - `pickingIsNotAHistoryStep`: after down/drag/up the fake's `HistoryStack` still has exactly the base step (`steps.count == 1`, `currentIndex == 0`, `isAtSavedState == true`), every layer's `generation` is unchanged, and the image equals the copy taken before the gesture.
  - `cursorIsCrosshair`: `cursor(at: (1,1), modifiers: [])` → `.crosshair`; `cursor(at: nil, …)` → `.arrow`; `hasPendingEdit` is false before, during, and after a gesture.
  - `afterClickDoNotSwitch` / `afterClickSwitchToPrevious` / `afterClickSwitchToPencil`: `previousToolID = .paintbrush`; after mouseUp the fake's `activatedTools` is `[]` / `[.paintbrush]` / `[.pencil]`; it is still `[]` after mouseDown and drag (requested exactly once, on mouseUp).
  - `afterClickOutsideCanvasDoesNotSwitch`: switchToPencil, click at `(-5,-5)` → no switch requested.
  - `optionsPersistAndDefault`: fresh store → size 1 (Single pixel), mode layer, afterClick doNotSwitch (PRD D-28); setting each writes `tool.colorPicker.samplingSize = 11`, `tool.colorPicker.samplingMode = "image"`, `tool.colorPicker.afterClick = "switchToPencil"`, and a new tool instance reads them back.
  - `invalidStoredOptionsFallBack`: stored size 7, mode `"foo"`, afterClick `""` → defaults.
- **Registry test — `PaintDotMacTests/Tools/ToolRegistryColorPickerTests.swift`:** `kResolvesToColorPicker`: `ToolRegistry.standard().shortcutGroup(for: "k") == [.colorPicker]`; `ToolShortcutResolver.resolve(key: "k", …)` returns `.colorPicker` from `.paintbrush`, and again `.colorPicker` when pressed within 1 s while it is active; `implementedIDs` contains `.colorPicker` exactly once, right after `.pencil`; its `displayName` is "Color Picker".
- **Integration test — `PaintDotMacTests/Integration/ColorPickerSessionTests.swift`:** headless session: a `ToolDispatcher(registry: .standard())` (starts on `.paintbrush`) with a `ToolContext` double over an 800×600 white "New Image" `DocumentState` (`NewImageDefaults`) and an `UndoBridge`; primary set to `(255,0,0,255)`; paint a Paintbrush stroke (width 20) through `pointerDown/Dragged/Up`; set the primary to black; `selectTool(.colorPicker)`; store afterClick `switchToPreviousTool`; click on the stroke center → primary is `(255,0,0,255)`, `dispatcher.activeToolID == .paintbrush`, `previousToolID == .colorPicker`, history names are exactly `["New Image", "Paintbrush"]`; `undoBridge.undo()` → stroke gone, primary still red.
- **Performance guard — `PaintDotMacTests/Performance/ColorPickerPerformanceTests.swift`** (XCTest `measure`): 4000×3000, 3 fully allocated layers, Image mode, size 51 → each sample well under 5 ms; gate fails only above 50 ms (proves only the sampled rect is composited). Report the measured number in the Verification status.
- **UI tests — `PaintDotMacUITests/ColorPickerUITests.swift`** (fixture generated at test time: 200×100 PNG, left half opaque `#FF0000`, right half opaque `#0000FF`, opened with `-UITestOpen`; `-UITestResetDefaults`):
  - `kKeyActivatesColorPicker`: press K → `tool.colorPicker` is selected.
  - `clickPicksPrimaryAndRightClickPicksSecondary`: press K, Actual Size (⌘0), click the left half → `colors.primary` value `#FF0000FF` (and `colors.hex` shows `#FF0000` while Primary is the active slot); right-click the right half → `colors.secondary` value `#0000FFFF`, primary still `#FF0000FF`; ⌘-click is not needed here (single layer).
  - `pickingAddsNoHistoryRow`: after the clicks `historyRow.0` ("Open Image") exists and `historyRow.1` does not, Edit > Undo is disabled, and ⌘W closes the window with no save sheet (`waitForDocumentWindowCount(0)`), i.e. the document is not edited (0008: edited state follows history).
  - `switchToPreviousToolReturnsToPaintbrush`: press B, press K, choose "Switch to previous tool" in `toolOptions.afterClick`, click the canvas → `tool.paintbrush` is selected; relaunch with the same defaults (no reset) → `toolOptions.afterClick` still shows "Switch to previous tool" (TOOL-C).
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build with no warnings, all tests pass with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open a photo, press K, set "Sampling:" to "11 x 11 region", click a textured area → the primary swatch shows a plausible averaged color, not the exact center pixel.
  2. Drag across the image with the left button held → the primary swatch updates continuously and smoothly.
  3. Control-click → secondary swatch changes (Mac secondary-click mapping).
  4. With one layer only before 0024 exists, "Layer" and "Image" give the same result; re-check ⌘-click Image sampling once layers exist (0024).
  5. Choose "Switch to Pencil tool", click → Pencil is active and draws.
  6. Zoom to 3200% and click the boundary between two pixels → the pixel under the cursor tip's pixel square is picked.
  7. Check the toolbar controls read correctly with VoiceOver ("Sampling", "Layer", "Image", "After click").

## Out of scope

- Screen-wide eyedropper via `NSColorSampler` (C-4) → 0054.
- Metal compositor, golden-image parity tests, `GoldenImage.swift`, Flatten/Merge Down commands → 0024. Blend modes beyond Normal → 0026, 0027, 0059.
- Magic Wand / Paint Bucket "Sampling" options (they reuse `SamplingMode` and `CPUCompositor`) → 0016, 0017.
- Copy Merged → 0030; ORA `mergedimage.png` → 0028; flatten on export → 0029.
- Pixel grid for precise picking (Paint.NET's tip) → 0053.
- A color-picker loupe/preview overlay (not in Paint.NET's doc).
