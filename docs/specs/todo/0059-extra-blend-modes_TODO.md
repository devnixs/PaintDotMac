# 0059 — Add the Hard Light, Soft Light, Color, Luminosity, Hue, and Saturation blend modes (L-4)

> Source: PRD.md §5.6 L-4 (P1: "More blend modes from Paint.NET 5.x: Hard Light, Soft Light, Color, Luminosity, Hue, Saturation"), L-2 (blend mode in Layer Properties), §5.3 T-11 (brush blend list grows with the layer modes), §4 *Rendering* (CPU reference compositor, Metal for display, ±1), NF-6 (blend modes have golden-image tests), FMT-E (ORA `composite-op`: standard names where they exist); §12 D-15, D-16, D-17, D-18. AGENTS.md *Code style* (Metal shaders: one blend mode per function, named after the `BlendMode` case) and *Testing* (golden images in `PaintDotMacTests/Golden/`, ±1).
> Formula sources: **W3C Compositing and Blending Level 1**, §10.1 "Separable blend modes" (`hard-light`, `soft-light`) and §10.2 "Non-separable blend modes" (`hue`, `saturation`, `color`, `luminosity`, with `Lum`, `ClipColor`, `SetLum`, `Sat`, `SetSat`): https://www.w3.org/TR/compositing-1/#blending. Paint.NET docs (fetched 2026-11-08): https://www.paint.net/doc/latest/BlendModes.html lists only the 14 L-3 layer modes plus the tool-only Overwrite ("the Blend Mode drop-down list offers 14 blend modes") and gives no name, order, or formula for any L-4 mode (see *Open questions* 1–2). OpenRaster `composite-op` names: https://www.openraster.org/baseline/layer-stack-spec.html (`svg:hard-light`, `svg:soft-light`, `svg:color`, `svg:luminosity`, `svg:hue`, `svg:saturation`, as already listed in 0028 *Context*).
> Milestone: v1.x
> Depends on: 0051-use-case-acceptance-tests (v1.0 complete). Builds directly on 0026/0027 (blend pattern and test harness), 0024 (`MetalCompositor`, `Blend.metal`, `GoldenImage`), 0025 (Layer Properties), 0028 (`OpenRasterBlendMap`), 0043 (`Shaders/BlendOps.h`, `blend_mode_at`, `RenderGoldenTests.blendStage`).

## Context

There is no application code yet; this spec builds on the files the earlier specs create. Read 0026 and 0027 first: this spec follows their pattern exactly and only adds what is new (per-pixel functions and a few tests that can't be per-channel).

- **0002/0026/0027** `PaintDotMac/Core/Model/BlendMode.swift`: `enum BlendMode: String, CaseIterable, Codable, Sendable` with 14 cases in L-3 order `normal … xor`, frozen raw values (also the Metal kernel names) and Paint.NET `displayName`s. Unknown stored raw values read as `.normal`.
- **0009/0026/0027** `PaintDotMac/Core/Rendering/BlendOps.swift`: `mul255`, `compose(dst:src:_ f: (UInt8, UInt8) -> UInt8)` (0026's normative composition — 0009's exact-rounding Normal generalized with a **per-channel** `F`; `Sa == 0` → `dst` bit-identical), nested `enum Channel` (one `static func <case>(_ a: UInt8, _ b: UInt8) -> UInt8` per mode; `a` = destination, `b` = source), one pixel function `static func <case>(dst:src:) -> ColorRGBA8` per mode, and the exhaustive `switch` in `blend(_:dst:src:opacity:)`.
- **0024/0026/0027/0043** Metal: after 0043 the shared helpers live in `PaintDotMac/Core/Rendering/Shaders/BlendOps.h` (`#pragma once`, all `static inline`): `mul255`, `blend_normal_op`, `compose_op(uint4 dst, uint4 src, uint3 f)` (takes the three already-computed `F` values — **so it already works for per-pixel functions**), the `…Channel` helpers, every `…Op` struct, and `blend_mode_at(uint index, uint4 dst, uint4 src)`, a `switch` in `BlendMode.allCases` order (0 Normal … 13 Xor; unknown index → `blend_normal_op`), used by 0043's Clouds Core Image kernel in `EffectKernels.metal`. `Blend.metal` `#include`s the header and holds one kernel per mode named exactly `BlendMode.rawValue` with `normal`'s signature, calling `apply_layer<…Op>`. `MetalCompositor.init(device:library:)` builds one pipeline per `allCases` and throws `.functionMissing(name)` for a missing kernel.
- **0028** `PaintDotMac/Core/IO/OpenRasterBlendMap.swift`: `compositeOp(for:)` (exhaustive `switch`, no default — "makes 0059 (L-4) fail to compile until it adds `svg:hard-light`, `svg:soft-light`, `svg:color`, `svg:luminosity`, `svg:hue`, and `svg:saturation`") and `blendMode(forCompositeOp:)` (exact, case-sensitive match after trimming ASCII whitespace; unknown → `.normal`). `OpenRasterBlendMapTests.unknownOpsAreNormal` currently lists `"svg:hard-light"` as unknown.
- **Popups**: Layer Properties (`layerProperties.blendMode`, 0025), every `toolOptions.blendMode` (Paintbrush 0009, Pencil 0011, Paint Bucket 0017, Gradient 0023, Line/Curve 0038, Shapes 0039, Text 0040 where present), and Clouds' `effectDialog.blendMode` (0043) are built from `BlendMode.allCases` by `displayName`, so new cases appear everywhere automatically. `CPUCompositor`, `LayerCommand.flatten`/`.mergeLayerDown`, and `PixelSampler` go through `BlendOps.blend`.
- **Test harness (0026/0027)**: `PaintDotMacTests/Rendering/Reference/BlendReference.swift` (exhaustive switches `paintNET336F`, `realF`, `compositeDouble`, `paintNET336Composite`), `PaintDotMacTests/Support/BlendFixtures.swift` (`goldenPair(mode:)`, 300×300), suites `BlendModeTests`, `BlendChannelTests` (exhaustive tolerance `switch` in `closeToRealValuedFormula`), `BlendModeCompositionTests`, `PaintNET336FidelityTests` (exhaustive bound `switch` in `generalWithinBound`), `BlendModeGoldenTests`, `BlendModeParityTests`, `BlendModeIntegrationTests`, `BlendModesUITests`. Mode-parameterized tests use `BlendMode.allCases.filter { $0 != .normal }`.

### What is new here

1. **No Paint.NET definition exists.** Paint.NET's current docs list only the 14 L-3 layer modes, and the last published source (3.36 `UserBlendOps`) has none of the L-4 modes. This spec therefore defines them by the W3C Compositing and Blending Level 1 formulas (the formulas Krita, browsers, and the ORA `svg:*` names refer to), with the exact 8-bit arithmetic pinned below (*Open questions* 1).
2. **Four modes are non-separable.** Color, Luminosity, Hue, and Saturation compute all three output channels from both whole RGB triples, so they can't be a per-channel `F(a, b)`. The shared composition gets a per-pixel variant; the alpha composition itself is unchanged.
3. **No Paint.NET 3.36 fidelity bound applies** to these six modes (there is no 3.36 code to compare against). `PaintNET336FidelityTests` keep running for the 13 L-3 modes only.

### Normative formulas

Notation as in 0026: `A`/`a` = **destination** (backdrop, W3C `Cb`), `B`/`b` = **source** (blend layer or tool paint, W3C `Cs`). Byte values 0…255.

**Hard Light (separable, integer, exact).** W3C: `B(Cb, Cs) = Cs ≤ 0.5 ? Multiply(Cb, 2·Cs) : Screen(Cb, 2·Cs − 1)`. W3C defines Overlay as Hard Light with the operands swapped, so we use Paint.NET 3.36's Overlay arithmetic (0026) with the operands swapped:
```
hardLight(a, b) = b < 128 ? mul255(2·b, a) : 255 − mul255(2·(255 − b), 255 − a)
```
Identity (tested exhaustively): `hardLight(a, b) == overlay(b, a)`. `Cs ≤ 0.5` ⇔ `b ≤ 127` ⇔ `b < 128`. Max `|F − realF|` = 0.498.

**Soft Light (separable, integer, exact).** W3C: `Cs ≤ 0.5 → Cb − (1 − 2Cs)·Cb·(1 − Cb)`; else `Cb + (2Cs − 1)·(D(Cb) − Cb)` with `D(x) = x ≤ 0.25 ? ((16x − 12)x + 4)x : √x`. In bytes (`Cb ≤ 0.25` ⇔ `a ≤ 63`), all in `UInt32` except where noted:
```
if b <= 127:
    softLight = (a·65025 − (255 − 2b)·a·(255 − a) + 32512) / 65025          // round(real), numerator ≥ 0, ≤ 16 613 887
else:
    if a <= 63:  D = ((( 16a − 3060 )·a + 260100)·a + 32512) / 65025      // Int32: (16a − 3060) < 0; ((16a−3060)a + 260100) > 0 for all a; max 8 274 424
    else:        D = isqrtRounded(a·255)                                   // round(√(a·255)), a·255 ≤ 65 025
    softLight = a + ((2b − 255)·(D − a) + 127) / 255                       // D ≥ a always, so no negatives
```
`isqrtRounded(n)`: `s = ⌊√n⌋` (exact integer square root), then `s + 1` if `s·s + s < n` else `s` (√n ≥ s + ½ ⇔ n > s² + s for integers). Result always in 0…255 (`≤ D ≤ 255`). Max `|F − realF|` = 0.974 (at `a = 212, b = 252`). Worked examples: `softLight(200, 100) = (13 005 000 − 55·200·55 + 32 512)/65 025 = 12 432 512/65 025 = 191`; `softLight(64, 200)`: `D = round(√16 320 = 127.75) = 128`, `64 + (145·64 + 127)/255 = 64 + 9 407/255 = 64 + 36 = 100`.

**Non-separable (Double on the CPU, exactly in this operation order).** Channels are converted to `Double` as `c / 255.0`. Helpers (W3C §10.2), written left to right exactly as here:
```
lum(c)        = 0.3·c.r + 0.59·c.g + 0.11·c.b
clipColor(c)  : L = lum(c); n = min(c.r, c.g, c.b); x = max(c.r, c.g, c.b)
                if n < 0: c = L + (c − L)·L / (L − n)          (each channel)
                if x > 1: c = L + (c − L)·(1 − L) / (x − L)    (each channel; uses the c from the previous line, and the x computed before it)
setLum(c, l)  : d = l − lum(c); return clipColor(c + d)
sat(c)        = max(c) − min(c)
setSat(c, s, order): order = indices of the INTEGER byte channels sorted by (value, index) ascending → (iMin, iMid, iMax)
                if bytes[iMax] > bytes[iMin]: out[iMid] = (c[iMid] − c[iMin])·s / (c[iMax] − c[iMin]); out[iMax] = s; out[iMin] = 0
                else: out = (0, 0, 0)
```
```
hue(Cb, Cs)        = setLum(setSat(Cs, sat(Cb), order of Cs bytes), lum(Cb))
saturation(Cb, Cs) = setLum(setSat(Cb, sat(Cs), order of Cb bytes), lum(Cb))
color(Cb, Cs)      = setLum(Cs, lum(Cb))
luminosity(Cb, Cs) = setLum(Cb, lum(Cs))
byte(v)            = min(255, max(0, Int((v·255 + 0.5).rounded(.down))))
```
The sort order and the `max > min` decision use the **integer bytes**, never computed floats, so CPU and GPU always take the same `setSat` branch (ties between equal channels don't change the result: an equal mid takes `s` or 0 either way). `L − n > 0` whenever `n < 0` and `x − L > 0` whenever `x > 1` (because `lum(c + d) = l ∈ [0, 1]`), so neither division can be by zero; still guard both denominators with `> 0` (no-op otherwise) so a NaN can never reach `byte`. `byte` clamps before converting, so no trap. Identity: `color(a, b) == luminosity(b, a)` (the same computation; tested). Luminance is preserved: `|lum(result bytes) − lum(target)| ≤ 0.5` in byte units (measured max 0.5, the final rounding).

**Composition (unchanged from 0026).** With `Sa = mul255(src.a, opacity)`, `Da = dst.a`, in `UInt32`:
```
if Sa == 0 { return dst }                                                   // bit-identical
fa   = Sa·255 + Da·(255 − Sa);   outA = (fa + 127) / 255
outC = (Dc·Da·(255 − Sa) + Sc·Sa·(255 − Da) + Fc·Sa·Da + fa/2) / fa        // C ∈ {R, G, B}
```
For the separable modes `Fc = F(Dc, Sc)`; for the non-separable ones `(Fr, Fg, Fb) = P(dst.rgb, src.rgb)`. This is exactly the W3C general formula `co = cs·(1 − αb) + cb·(1 − αs) + αs·αb·B(Cb, Cs)` on straight colors, divided by the output alpha. Consequences (tested for all six): opaque over opaque = `F`/`P` exactly; a source over a transparent destination gives the source exactly; a transparent source (or opacity 0) leaves the destination bit-identical.

**GPU.** Hard Light and Soft Light are integer and bit-identical to the CPU (Soft Light's `isqrtRounded` starts from `uint(sqrt(float(n)))` and corrects with integer `while s·s > n { s −= 1 }; while (s+1)·(s+1) <= n { s += 1 }`, then rounds as above). The non-separable modes run in `float` with the same operation order and the same integer-byte sort; they match the `Double` CPU result within ±1 (a float simulation of 200 000 random pairs per mode: max 1, 0.08–0.43 % of channels differ by 1). This is within D-16's ±1 parity rule.

## User story

As a PaintDotMac user, I can set a layer (or the Paintbrush, Pencil, Paint Bucket, Gradient, shape and text tools, and Clouds) to Hard Light, Soft Light, Color, Luminosity, Hue, or Saturation. The canvas, Flatten, Merge Layer Down, Copy Merged, and image sampling all render them the same way, and an `.ora` file keeps them and opens with the same modes in Krita.

## Scope & changes

### Core (headless, unit-tested)

- **`PaintDotMac/Core/Model/BlendMode.swift`** (modify): append six cases **after `xor`**, in PRD L-4 order (*Open questions* 2). After this spec `allCases` has 20 cases; indices 0…13 are unchanged, so 0043's `Clouds.blendIndex` and `blend_mode_at` indices for L-3 stay the same.

  | Case | Raw value (frozen forever; also the Metal kernel name) | `displayName` | ORA `composite-op` |
  |---|---|---|---|
  | `hardLight` | `"hardLight"` | Hard Light | `svg:hard-light` |
  | `softLight` | `"softLight"` | Soft Light | `svg:soft-light` |
  | `color` | `"color"` | Color | `svg:color` |
  | `luminosity` | `"luminosity"` | Luminosity | `svg:luminosity` |
  | `hue` | `"hue"` | Hue | `svg:hue` |
  | `saturation` | `"saturation"` | Saturation | `svg:saturation` |

- **`PaintDotMac/Core/Rendering/BlendOps.swift`** (modify):
  - `BlendOps.Channel`: add `static func hardLight(_ a: UInt8, _ b: UInt8) -> UInt8` and `softLight` (integer formulas above, doc comments with the W3C formula, the byte thresholds, and the overflow bounds). Checked arithmetic only (no `&+`/`&*`). Add `static func isqrtRounded(_ n: UInt32) -> UInt32` (internal, tested) — use an exact integer method (e.g. `UInt32(Double(n).squareRoot())` followed by the same two integer correction loops as the GPU).
  - New nested `enum Pixel` with `static func color(_ a: SIMD3<UInt8>, _ b: SIMD3<UInt8>) -> SIMD3<UInt8>`, `luminosity`, `hue`, `saturation` (`a` = destination RGB, `b` = source RGB), plus internal helpers `lum`, `clipColor`, `setLum`, `sat`, `setSat` on `SIMD3<Double>`, written exactly as in *Normative formulas* (same operation order; sort on the integer bytes).
  - `@inline(__always) static func composePixel(dst: ColorRGBA8, src: ColorRGBA8, _ p: (SIMD3<UInt8>, SIMD3<UInt8>) -> SIMD3<UInt8>) -> ColorRGBA8`: the same normative composition as `compose`, with `F` from `p(dst.rgb, src.rgb)`. The `Sa == 0` early return comes before `p` is called. It may also skip `p` when `Da == 0` (its weight is 0; the result is then `src.rgb` exactly — must stay bit-identical, tested). `compose` (0026) is unchanged; a test pins `composePixel` with a per-channel-lifted `F` equal to `compose` for every separable mode.
  - Pixel functions next to 0026/0027's: `hardLight(dst:src:)`, `softLight(dst:src:)` via `compose(… Channel.…)`; `color(dst:src:)`, `luminosity`, `hue`, `saturation` via `composePixel(… Pixel.…)`.
  - `blend(_:dst:src:opacity:)`: add the six cases to the exhaustive switch (no `default`).
  - Performance note: the non-separable modes cost about 40–60 floating-point operations per pixel in `Double` on the CPU (export/flatten/merge/sampling only; display is Metal). No fast path is required; 0048's NF-2 measure stays Normal-based. Don't add a lookup table or `Float` path on the CPU (the CPU is the reference).
- **`PaintDotMac/Core/IO/OpenRasterBlendMap.swift`** (modify): add the six rows to `compositeOp(for:)` and to the reader (table above). These are the standard names PRD FMT-E says to use "where they exist" (0028 *Context* lists them as standard ops).
- **No `CPUCompositor`, `LayerOperations`, `PixelSampler`, `OpenRasterCodec`, or tool change.** They go through `BlendOps.blend` / `OpenRasterBlendMap`.

### Metal (`PaintDotMac/Core/Rendering/Shaders/`)

- **`BlendOps.h`** (modify; 0043 owns the structure):
  - `static inline uint hardLightChannel(uint a, uint b)`, `softLightChannel(uint a, uint b)` (with `static inline uint blend_isqrt_rounded(uint n)`), same integer formulas (Soft Light's `a ≤ 63` polynomial in `int`, then converted back).
  - Float helpers with a `blend_` prefix so they can't collide with effect-kernel helpers that include this header: `blend_lum(float3)`, `blend_clip_color(float3)`, `blend_set_lum(float3, float)`, `blend_sat(float3)`, `blend_set_sat(float3 c, float s, uint3 bytes)` (sort/branch on `bytes`), and `static inline uint3 colorPixel(uint3 a, uint3 b)`, `luminosityPixel`, `huePixel`, `saturationPixel` (convert `float3(x) / 255.0f`, compute, `byte` = `uint(clamp(floor(v·255 + 0.5), 0, 255))`). Guard both `clip_color` denominators with `> 0`.
  - Op structs `HardLightOp`, `SoftLightOp` (per-channel helper, then `compose_op`), `ColorOp`, `LuminosityOp`, `HueOp`, `SaturationOp` (`uint3 f = …Pixel(dst.rgb, src.rgb)`, then `compose_op(dst, src, f)`), each `static uint4 apply(uint4 dst, uint4 src)`.
  - `blend_mode_at`: append cases **14 Hard Light, 15 Soft Light, 16 Color, 17 Luminosity, 18 Hue, 19 Saturation** (= `BlendMode.allCases` indices). Unknown index → Normal (unchanged).
- **`Blend.metal`** (modify): six kernels named exactly `hardLight`, `softLight`, `color`, `luminosity`, `hue`, `saturation`, with `normal`'s signature, calling `apply_layer<…Op>`. No Swift change in `MetalCompositor`: its pipeline-per-`allCases` loop picks them up. (Checked: no other Metal function in the backlog uses these names — 0031–0044 kernels are `brightnessContrast`, `invertColors`, `hueSaturation`, `channelLookup`, `blackAndWhite`, `luminosityCurve`, `gaussianBlur*`, `motionBlur`, `vignette`, `sharpen`, `clouds`, `addNoise`, `emboss`, `pixelate`.)
- `EffectKernels.metal` (Clouds): no change; it calls `blend_mode_at` with `Clouds.blendIndex(mode)` = `allCases.firstIndex(of:)`, which now reaches 19.

### Platform glue (covered by UI tests and manual checks)

- **Popups:** no code change expected. Every blend popup lists, in this order: **Normal, Multiply, Additive, Color Burn, Color Dodge, Reflect, Glow, Overlay, Difference, Negation, Lighten, Darken, Screen, Xor, Hard Light, Soft Light, Color, Luminosity, Hue, Saturation**. Verify with `grep -rn "blendMode\|BlendMode" PaintDotMac/UI PaintDotMac/Canvas PaintDotMac/Document` that no popup filters, truncates, or hard-codes a count; fix any that does. No separator is added. The Eraser still has no blend mode (T-12); the Gradient popup stays disabled in Transparency Mode (0023).
- **Canvas:** mode changes redraw through 0025's existing path; no new invalidation code.
- No new menu items, history steps, settings, or accessibility identifiers.
- **Existing tests to update in this change** (the behavior changed on purpose):
  - 0026/0027 `BlendModeTests.casesRawValuesAndNames`: the 20-case list. `BlendModeTests.unknownRawValueReadsAsNormal`: its `BlendMode(rawValue: "hardLight") == nil` assertion is now false — replace `"hardLight"` with `"linearBurn"` and `"exclusion"` (still unknown), and add that `"softLight"` and `"saturation"` load their cases. 0027's `completeL3ListMatchesPaintNETOrder` becomes `Array(BlendMode.allCases.prefix(14)).map(\.displayName) == [the 14 L-3 names]` (the L-3 prefix is still Paint.NET's page order).
  - 0026 `BlendChannelTests.matchesPaintNETTranscriptionExhaustive(mode:)` and `closeToRealValuedFormula(mode:)`: arguments become `BlendFixtures.separableModes.filter { $0 != .normal }` (non-separable modes have no channel function); the tolerance `switch` gets `hardLight` → `≤ 0.5 + 1e-9`, `softLight` → `< 1.0` (measured 0.9745), and the four non-separable cases → `nil` (unreachable; the switch stays exhaustive).
  - 0026 `BlendModeCompositionTests.opaqueOverOpaqueIsChannelFunction(mode:)`: arguments → separable non-Normal modes (the new `opaqueOverOpaqueIsPixelFunction` covers the rest).
  - 0026/0027 `PaintNET336FidelityTests` (all parameterized tests): arguments → `BlendFixtures.l3Modes.filter { $0 != .normal }`; the bound `switch` returns `Int?` and gives `nil` for the six L-4 modes ("no Paint.NET reference"). Pinned worst cases unchanged.
  - 0028 `OpenRasterBlendMapTests.everyModeHasTheFMTEOp`: the 20-row table. `unknownOpsAreNormal`: remove `"svg:hard-light"`; add `"svg:dst-out"`, `"svg:dst-atop"`, `"SVG:HUE"`, `"svg:soft_light"`.
  - 0043 `RenderGoldenTests.blendStage(mode:)` (`@Test(arguments: BlendMode.allCases)`): for L-3 modes keep `BlendReference.paintNET336Composite`; for the six L-4 modes the expected value is `BlendReference.normativeComposite(mode, dst: a, src: C)` (new, below), within ±1. `CloudsTests.blendListIsAllCases` needs no change. 0043 `testCloudsDefaults`: `effectDialog.blendMode` has 20 items.
  - 0027 `BlendModesUITests.layerPropertiesListsAllFourteenModes` / `.toolPopupsListAllFourteenModes`: rename to `layerPropertiesListsAllModes` / `toolPopupsListAllModes` and assert the 20 names in order.
  - Any other assertion on an item count of 14.
- `project.yml`: no change (test files and goldens are picked up by globs / `#filePath`). Run `xcodegen generate` after adding files.
- PRD: not edited by this spec (spec-writer sub-agent rule). See *Open questions* 1–2 and the note in *Out of scope* about FMT-E's op list.

## Acceptance criteria

- [ ] `BlendMode.allCases` is the 14 L-3 cases followed by `hardLight, softLight, color, luminosity, hue, saturation`, with the raw values and display names in the table; unknown raw values still load as Normal; the new raw values load as their cases and round-trip through JSON. → `BlendModeTests.casesRawValuesAndNames`, `.unknownRawValueReadsAsNormal`, `.completeL3ListMatchesPaintNETOrder`, `.l4AppendedAfterXor`
- [ ] Hard Light and Soft Light equal the integer formulas for all 65 536 pairs, Hard Light equals Overlay with swapped operands, both stay within 0…255 and within the stated distance of the real-valued W3C formula. → `BlendChannelTests.matchesPaintNETTranscriptionExhaustive(mode:)`, `.closeToRealValuedFormula(mode:)`, `.hardLightIsSwappedOverlay`, `.l4SpotValues`, `BlendIsqrtTests.*`
- [ ] Color, Luminosity, Hue, and Saturation equal the independent W3C reference (exact except at exact .5 ties, ±1 there), preserve the target luminance within 0.5, satisfy `color(a, b) == luminosity(b, a)`, and give the hand-computed spot values including both `ClipColor` branches and gray inputs. → `BlendPixelTests.*`
- [ ] Each new mode's pixel result follows the normative composition (alpha exact, RGB within ±1 of the `Double` reference, opaque over opaque = `F`/`P`, transparent source leaves dst, transparent dst gives src, opacity first), and `composePixel` agrees with `compose` for every separable mode. → `BlendModeCompositionTests.*(mode:)`, `.opaqueOverOpaqueIsPixelFunction(mode:)`, `.composePixelMatchesCompose(mode:)`, `.l4PixelSpotValues`
- [ ] `BlendOps.blend` dispatches each new case. → `BlendModeCompositionTests.dispatch(mode:)`
- [ ] Flatten, Merge Layer Down, Image-mode sampling, Layer Properties, and the Paintbrush/Paint Bucket honor the new modes, with undo/redo. → `BlendModeIntegrationTests.l4MergeLayerDown(mode:)`, `.softLightFlattenUndoRedo`, `.imageSamplingSeesLuminosity`, `.layerPropertiesHueRoundTrip`, `.paintbrushSoftLightStroke`, `.paintBucketHueFill`
- [ ] The Metal compositor builds a pipeline for all 20 cases and matches the CPU within ±1 for every new mode (channel grid, RGB-cube grid for the non-separable modes, random stacks); `blend_mode_at` reaches every index. → `MetalCompositorTests.everyBlendModeHasKernel`, `BlendModeParityTests.channelGridParity(mode:)`, `.rgbCubeParity(mode:)`, `.randomStackParity(mode:)`, `RenderGoldenTests.blendStage(mode:)`
- [ ] Each new mode has an oracle-checked golden (CPU ±1, Metal ±1) and hand-computed spot pixels. → `BlendModeGoldenTests.goldenMatches(mode:)`, `.goldenSpotPixels`
- [ ] ORA maps the six modes to `svg:hard-light`, `svg:soft-light`, `svg:color`, `svg:luminosity`, `svg:hue`, `svg:saturation` both ways, and a layered image with all six round-trips through `.ora`. → `OpenRasterBlendMapTests.everyModeHasTheFMTEOp`, `.readBackIsIdentity`, `.unknownOpsAreNormal`, `OpenRasterL4RoundTripTests.allL4ModesRoundTrip`
- [ ] Every blend popup lists the 20 modes in order; choosing Soft Light in Layer Properties adds a "Layer Properties" step that undo reverts; a tool's Luminosity choice persists across relaunch; Clouds offers 20 modes. → `BlendModesUITests.layerPropertiesListsAllModes`, `.toolPopupsListAllModes`, `.toolBlendPopupPersistsLuminosity`, 0043 `testCloudsDefaults`
- [ ] The canvas visibly renders each new mode like the flattened result, and Krita opens the `.ora` with the same modes. → manual (look and feel, external app), backed by parity and ORA tests.
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Soft Light thresholds:** `b = 127` uses the first branch, `b = 128` the second; `a = 63` uses the polynomial, `a = 64` the square root (`softLight(63, 200) = 99`, `softLight(64, 200) = 100`). Tested.
- **Soft Light arithmetic:** `16a − 3060` is negative — compute the polynomial in `Int32` (or reorder to stay non-negative) and never in `UInt32` (would trap). `D ≥ a` always, so `(2b − 255)·(D − a)` is non-negative.
- **isqrt:** `isqrtRounded` is exact for every `n ∈ 0…65 025` (exhaustive test, including perfect squares and `n = s² + s` / `s² + s + 1`, where rounding flips).
- **Non-separable degenerate inputs:** gray destination with Saturation or Hue (`sat = 0`) → gray result at the destination's luminance; gray source with Hue (`setSat` of an all-equal triple) → `(0,0,0)` then `setLum` → gray of `lum(dst)`; black/white extremes (`color((0,0,0), (255,255,255)) = (0,0,0)`). Ties between channels (`(255,255,0)`, `(128,128,128)`) take the same branch on CPU and GPU because ordering uses the integer bytes.
- **ClipColor:** both branches (`n < 0`, `x > 1`) are exercised by spot values; denominators guarded; no NaN/Inf can reach `byte` (tested over the 17³ RGB-cube grid in both operand orders: every result finite and in 0…255).
- **Rounding ties:** the W3C non-separable functions produce exact `.5` values for some inputs (e.g. `luminosity((255,0,0), (0,0,255))` has a channel at 93.5 in exact arithmetic). The CPU result there depends on floating-point details; tests accept ±1 exactly where the reference's unrounded value is within `1e-9` of a `.5` tie and require equality elsewhere. Spot values below avoid ties (each ≥ 0.005 from a tie).
- **Alpha extremes:** `Sa == 0` → dst bit-identical (including garbage RGB under `Da == 0`); `Da == 0` → src exactly (the `Da == 0` shortcut in `composePixel`, if taken, is bit-identical); `Sa = Da = 255` → `F`/`P`.
- **Garbage RGB under alpha 0** in either operand never produces NaN or a trap (`P` is total over all byte triples).
- **Bottom layer / sparse tiles / hidden layers / opacity 0:** as in 0026 (absent tile = transparent source → destination unchanged).
- **Tile boundaries:** goldens use 0026's 300×300 fixture; spot pixels in the second tile row and column.
- **Unknown or mis-cased ORA ops** (`SVG:HUE`, `svg:soft_light`) → Normal, no crash. Krita-only ops (`krita:…`) → Normal.
- **Old files/defaults:** `.ora` files and `tool.*.blendMode` defaults written before this spec keep loading unchanged (indices 0…13 and raw values unchanged).
- **Pipeline creation:** a missing kernel throws `CanvasRendererError.functionMissing` (0024) and fails `MetalCompositorTests`; never a runtime crash.

## Test plan

All expected values were computed independently of the implementation, with a standalone script of this spec's formulas (Python, `Double` arithmetic in the stated order, `byte(v) = ⌊v·255 + 0.5⌋`). Swift Testing throughout.

- **Test support — `PaintDotMacTests/Support/BlendFixtures.swift`** (modify): add `static func isSeparable(_ m: BlendMode) -> Bool` (exhaustive `switch`, `false` only for `color, luminosity, hue, saturation`), `static let separableModes`, `nonSeparableModes`, `l3Modes` (`Array(allCases.prefix(14))`), `l4Modes` (`[.hardLight, .softLight, .color, .luminosity, .hue, .saturation]`).
- **Test support — `PaintDotMacTests/Rendering/Reference/BlendReference.swift`** (modify; plain `Int`/`Double`, written from this spec, no app code):
  - `paintNET336F`: add `hardLight`, `softLight` (this spec's integer formulas; doc comment: "L-4: no Paint.NET source; W3C in 8-bit as pinned by 0059"). The four non-separable cases `preconditionFailure("non-separable")` (never called: callers are parameterized over `separableModes`).
  - `realF`: Hard Light `b ≤ 127.5 ? 2ab/255 : 255 − 2(255−a)(255−b)/255`; Soft Light the W3C real formula ×255. Non-separable → `preconditionFailure`.
  - New `static func realPixel(_ mode:, _ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> (Double, Double, Double)` (the unrounded W3C non-separable result ×255, written from *Normative formulas*), `referencePixel` (= `byte` of `realPixel` for non-separable; per-channel `paintNET336F` otherwise), and `isNearTie(_ v: Double) -> Bool` (`abs(v − v.rounded(.down) − 0.5) < 1e-9`).
  - `compositeDouble`: uses `referencePixel` (or `realPixel`/`realF` when `realF == true`) so it works per pixel for every mode.
  - New `static func normativeComposite(_ mode:, dst:, src:, opacity: = 255) -> ColorRGBA8`: the normative integer composition in `Int` with `referencePixel` (used by 0043's `blendStage` for L-4).
  - `paintNET336Composite`: the six L-4 cases `preconditionFailure("no Paint.NET reference")` (callers are parameterized over `l3Modes`).
- **Unit — `PaintDotMacTests/Model/BlendModeTests.swift`** (modify): `casesRawValuesAndNames` (20 cases, raw values unique); `l4AppendedAfterXor` (new): `Array(allCases.suffix(6)).map(\.displayName) == ["Hard Light", "Soft Light", "Color", "Luminosity", "Hue", "Saturation"]` and `allCases.firstIndex(of: .hardLight) == 14`, `.saturation == 19`; `unknownRawValueReadsAsNormal` (updated as in *Scope*); JSON round trip of all 20.
- **Unit — `PaintDotMacTests/Rendering/BlendChannelTests.swift`** (modify):
  - `matchesPaintNETTranscriptionExhaustive(mode:)` / `closeToRealValuedFormula(mode:)`: now over separable modes, including the two new ones (tolerances in *Scope*).
  - `hardLightIsSwappedOverlay` (new): for all 65 536 `(a, b)`, `Channel.hardLight(a, b) == Channel.overlay(b, a)`.
  - `l4SpotValues` (new; `(a = dst, b = src) → F`):
    - Hard Light: (128,128)→128, (200,100)→157, (100,200)→188, (64,192)→161, (192,64)→96, (30,250)→246, (250,30)→59, (127,255)→255, (128,0)→0, (0,255)→255, (255,0)→0, (0,0)→0, (255,255)→255.
    - Soft Light: (128,128)→128, (200,100)→191, (100,200)→134, (64,192)→96, (192,64)→168, (30,250)→82, (250,30)→246, (127,255)→180, (128,0)→64, (0,255)→0, (255,0)→255, (0,0)→0, (255,255)→255, (16,200)→37, (63,200)→99, (64,200)→100.
- **Unit — `PaintDotMacTests/Rendering/BlendIsqrtTests.swift`** (new): `exhaustive`: for every `n ∈ 0…65 025`, `isqrtRounded(n) == Int((Double(n).squareRoot()).rounded(.toNearestOrAwayFromZero))` and `|isqrtRounded(n)² − n| ≤ isqrtRounded(n)`; spot: 0→0, 1→1, 2→1, 3→2, 6→2, 7→3, 16 320→128, 65 025→255.
- **Unit — `PaintDotMacTests/Rendering/BlendPixelTests.swift`** (new):
  - `matchesReferenceRGBCube(mode:)` (non-separable): every `(dst, src)` pair from the 9³ grid (channel values 0, 32, 64, …, 224, 255; 729 × 729 = 531 441 pairs per mode): `BlendOps.Pixel.<mode>` equals `BlendReference.referencePixel`, except channels where `isNearTie(realPixel)` → ±1.
  - `matchesReferenceRandom(mode:)`: 200 000 seeded random pairs per mode, same rule. Seed printed on failure.
  - `colorIsSwappedLuminosity`: 100 000 seeded pairs: `Pixel.color(a, b) == Pixel.luminosity(b, a)`.
  - `preservesLuminance(mode:)`: 100 000 seeded pairs: `|lum(result) − lum(dst)| ≤ 0.5 + 1e-6` for Color, Hue, Saturation; `|lum(result) − lum(src)| ≤ 0.5 + 1e-6` for Luminosity (`lum` on byte values with 0.3/0.59/0.11).
  - `finiteAndInRange(mode:)`: over the 17³ cube against 50 random partners each, no trap, every channel in 0…255.
  - `spotValues` (dst RGB, src RGB → result; none within 0.005 of a tie):
    - Color: (200,100,50),(100,200,128)→(62,162,90); (255,0,0),(0,0,255)→(54,54,255); (128,128,128),(255,0,0)→(255,74,74) (`x > 1` branch); (10,200,30),(250,240,20)→(144,138,0) (`n < 0` branch); (0,0,0),(255,255,255)→(0,0,0); (255,255,255),(0,0,0)→(255,255,255); (255,255,0),(0,128,255)→(208,231,255).
    - Luminosity: (200,100,50),(100,200,128)→(238,138,88); (0,0,255),(255,0,0)→(54,54,255); (255,0,0),(128,128,128)→(255,74,74); (10,200,30),(250,240,20)→(164,255,174); (0,0,0),(255,255,255)→(255,255,255); (255,255,255),(0,0,0)→(0,0,0); (255,255,0),(0,128,255)→(116,116,0).
    - Hue: (200,100,50),(100,200,128)→(31,181,73); (255,0,0),(0,0,255)→(54,54,255); (128,128,128),(255,0,0)→(128,128,128) (gray dst: sat 0); (10,200,30),(250,240,20)→(144,138,0); (90,90,90),(200,100,50)→(90,90,90); (255,255,0),(0,128,255)→(208,231,255); (0,0,0),(255,255,255)→(0,0,0).
    - Saturation: (200,100,50),(100,200,128)→(175,108,75); (255,0,0),(0,0,255)→(255,0,0); (0,0,255),(255,0,0)→(0,0,255); (128,128,128),(255,0,0)→(128,128,128); (10,200,30),(250,240,20)→(0,207,22); (90,90,90),(200,100,50)→(90,90,90); (255,255,0),(0,128,255)→(255,255,0).
    - Worked example for comments, Color (128,128,128),(255,0,0): `l = lum(0.502,0.502,0.502) = 0.50196`; `lum(1,0,0) = 0.3`, `d = 0.20196` → `(1.20196, 0.20196, 0.20196)`; `x = 1.20196 > 1`, `L = 0.50196`: `G = 0.50196 + (0.20196 − 0.50196)·0.49804/0.70000 = 0.28851` → 73.57 → 74; `R = 0.50196 + 0.70000·0.49804/0.70000 = 1.0` → 255.
- **Unit — `PaintDotMacTests/Rendering/BlendModeCompositionTests.swift`** (modify; 0026's parameterized tests now include the six — `transparentSourceLeavesDestination`, `overTransparentDestinationIsSource`, `matchesDoubleReferenceDenseGrid`, `matchesDoubleReferenceRandom`, `opacityScalesSourceAlpha`, `dispatch`; for the non-separable modes, the "±1 vs rounded `compositeDouble(realF: false)`" assertion is applied where `referencePixel` is not near a tie, ±2 where it is). Add:
  - `opaqueOverOpaqueIsPixelFunction(mode:)` (non-separable): 100 000 seeded opaque pairs → exactly `(Pixel.<mode>(d.rgb, s.rgb), 255)`.
  - `composePixelMatchesCompose(mode:)` (separable, all 16): 100 000 seeded pairs, `composePixel` with the lifted channel function == `compose`.
  - `l4PixelSpotValues` (dst, src → result):
    - `dst (200,100,50,255)`, `src (100,200,128,128)` → Hard Light `(178,144,51,255)`, Soft Light `(195,117,50,255)`, Color `(131,131,70,255)`, Luminosity `(219,119,69,255)`, Hue `(115,141,62,255)`, Saturation `(187,104,63,255)`. Worked, Color R: `P = (62,162,90)`, `fa = 65025`, `(200·255·127 + 0 + 62·128·255 + 32512)/65025 = (6 477 000 + 2 023 680 + 32 512)/65 025 = 8 533 192/65 025 = 131`.
    - `dst (200,100,50,128)`, `src (100,200,128,255)` → Hard Light `(129,194,89,255)`, Soft Light `(146,167,89,255)`, Color `(81,181,109,255)`, Luminosity `(169,169,108,255)`, Hue `(65,190,100,255)`, Saturation `(138,154,101,255)`.
    - `dst (200,100,50,128)`, `src (100,200,128,128)` → Hard Light `(152,163,76,192)`, Soft Light `(164,145,76,192)`, Color `(121,154,89,192)`, Luminosity `(179,146,89,192)`, Hue `(110,160,84,192)`, Saturation `(158,136,84,192)`.
    - `dst (255,128,0,64)`, `src (64,192,255,192)` → Hard Light `(93,187,236,208)`, Soft Light `(123,179,176,208)`, Color `(76,185,234,208)`, Luminosity `(123,175,181,208)`, Hue `(75,186,236,208)`, Saturation `(117,174,185,208)`.
    - `dst (10,20,30,0)`, `src (90,180,250,77)` → `(90,180,250,77)` for all six.
    - Opaque: `dst (200,100,50,255)`, `src (100,200,128,255)` → Hard Light `(157,188,51,255)`, Soft Light `(191,134,50,255)`, Color `(62,162,90,255)`, Luminosity `(238,138,88,255)`, Hue `(31,181,73,255)`, Saturation `(175,108,75,255)`.
- **Unit — `PaintDotMacTests/Rendering/PaintNET336FidelityTests.swift`** (modify): restricted to L-3 (Scope). Add `l4HasNoPaintNETBound`: the bound function returns `nil` for exactly the six `l4Modes`.
- **Unit — `PaintDotMacTests/IO/OpenRasterBlendMapTests.swift`** (modify): the 20-row table literally; `readBackIsIdentity` over all 20 (ops unique); `unknownOpsAreNormal` as updated in *Scope*; `" svg:hue "` → `.hue`.
- **Integration (headless) — `PaintDotMacTests/IO/OpenRasterL4RoundTripTests.swift`** (new): `allL4ModesRoundTrip`: a 16×16 image with 7 layers (Background Normal + one layer per L-4 mode, varied opacity 255/128/1, one hidden) → `OpenRasterCodec.encode` → `stack.xml` contains the six `composite-op="svg:…"` strings → `decode` → names, order, visibility, opacity, blend modes, and pixels equal; `mergedimage.png` decoded equals `CPUCompositor().flattened` of the original (exact).
- **Golden-image tests — `PaintDotMacTests/Rendering/BlendModeGoldenTests.swift`** (modify): `goldenMatches(mode:)` covers the six, with new goldens `blend-hardLight.png`, `blend-softLight.png`, `blend-color.png`, `blend-luminosity.png`, `blend-hue.png`, `blend-saturation.png` (0026's fixture; oracle = `compositeDouble(realF: false)` rounded, ±1; record only with `RECORD_GOLDENS=1` after the oracle check passes; Metal ±1 vs the golden). Extend `goldenSpotPixels` (exact on CPU):
  - `(100, 50)`: bottom `(100,50,150,255)`, top `(200,86,155,255)` → Hard Light `(188,34,173,255)`, Soft Light `(134,37,160,255)`, Color `(148,34,103,255)`, Luminosity `(152,102,202,255)`, Hue `(139,39,100,255)`, Saturation `(103,46,160,255)`.
  - `(200, 250)`: bottom `(200,250,194,82)`, top `(188,50,55,188)` → Hard Light `(200,84,78,210)`, Soft Light `(196,127,102,210)`, Color `(209,119,117,210)`, Luminosity `(153,89,70,210)`, Hue `(209,119,117,210)`, Saturation `(191,130,107,210)`.
  - `(280, 10)`: bottom `(24,10,34,255)`, top `(44,18,231,44)` → Hard Light `(21,8,65,255)`, Soft Light `(22,9,42,255)`, Color `(22,8,48,255)`, Luminosity `(30,16,40,255)`, Hue `(23,11,35,255)`, Saturation `(26,8,38,255)`.
  - `(10, 299)`: bottom `(10,43,53,73)`, top `(96,33,245,255)` → Hard Light `(71,27,243,255)`, Soft Light `(71,28,207,255)`, Color `(83,24,224,255)`, Luminosity `(83,48,202,255)`, Hue `(79,31,195,255)`, Saturation `(69,37,192,255)`.
- **Metal parity — `PaintDotMacTests/Rendering/BlendModeParityTests.swift`** (modify): `channelGridParity(mode:)` and `randomStackParity(mode:)` now run for the six (random stacks draw from all 20). Hard Light and Soft Light: expected non-identical count 0. Add `rgbCubeParity(mode:)` (non-separable): two 256×256 layers whose pixels enumerate the 9³ × 9³ grid pairs above (wrapping into as many tiles as needed), `(Da, Sa)` ∈ `{(255,255), (128,200), (1,254)}` → Metal within ±1 of CPU; record the non-identical channel count in the test output (expected < 1 %).
- **Effects — 0043 `PaintDotMacTests/Effects/Render/RenderGoldenTests.swift`** (modify): `blendStage(mode:)` uses `BlendReference.normativeComposite` for the six L-4 modes (Scope), ±1 — proves `blend_mode_at` indices 14…19.
- **Integration (headless) — `PaintDotMacTests/Integration/BlendModeIntegrationTests.swift`** (modify):
  - `l4MergeLayerDown(mode:)` (arguments: the six): 4×4, bottom opaque `(200,100,50,255)`, top `(100,200,128,128)` with `mode`, opacity 128 (`Sa = 64`) → every pixel: Hard Light `(189,122,50,255)`, Soft Light `(198,109,50,255)`, Color `(165,116,60,255)`, Luminosity `(210,110,60,255)`, Hue `(158,120,56,255)`, Saturation `(194,102,56,255)`. Undo restores both layers, mode and opacity; redo re-merges.
  - `softLightFlattenUndoRedo`: same two layers (top opacity 255) Soft Light → `LayerCommand.flatten` gives one layer of `(195,117,50,255)`; undo restores two layers (top `.softLight`); redo flattens again.
  - `imageSamplingSeesLuminosity`: `PixelSampler` Image mode on bottom `(240,170,15,255)` + top Luminosity `(15,170,255,255)` → `(188,130,0,255)`; Layer mode on the top → `(15,170,255,255)`.
  - `paintbrushSoftLightStroke`: opaque `(128,128,128,255)` 32×32 layer, Paintbrush `blendMode = .softLight`, color `(200,100,50,255)`, width 6, hardness 100, AA, dab at `(16.5,16.5)` → center `(158,114,89,255)`; a pixel outside the dab unchanged; undo restores.
  - `paintBucketHueFill`: 0017 global fill on an opaque `(200,100,50,255)` 8×8 layer, color `(100,200,128,255)`, Hue → every pixel `(31,181,73,255)`; undo restores.
  - `layerPropertiesHueRoundTrip`: real `UndoBridge`, 0025's `LayerPropertiesDialogModel` on the top layer `(100,200,128,128)` over `(200,100,50,255)`, `edited.blendMode = .hue`, `ok()` → step "Layer Properties", composite `(115,141,62,255)`; undo → `.normal`, composite `(150,150,89,255)`; redo → `.hue`.
- **UI tests — `PaintDotMacUITests/BlendModesUITests.swift`** (modify):
  - `layerPropertiesListsAllModes`: generated 64×64 PNG fixture, Layers > Add New Layer, double-click `layerRow.1` → `layerProperties.blendMode` lists the 20 names in order. Choose "Soft Light", OK → `historyList` gains "Layer Properties"; reopen shows Soft Light; Cancel; ⌘Z, reopen → Normal.
  - `toolPopupsListAllModes`: press B, P, F, G in turn → each `toolOptions.blendMode` lists the 20 names in order.
  - `toolBlendPopupPersistsLuminosity`: press B, choose "Luminosity", relaunch without `-UITestResetDefaults` → popup shows "Luminosity"; then reset defaults.
  - `oraKeepsSoftLight`: Layers > Add New Layer, set it to Soft Light in Layer Properties, Save As `.ora` to a temp path, close, reopen through `-UITestOpen` → `layerProperties.blendMode` of `layerRow.1` shows "Soft Light".
- **Performance:** no new NF target. The non-separable CPU path is slower than integer modes; 0048's NF-2 measure is unaffected (display is Metal). No measure test.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: no warnings, all tests (including the updated 0026/0027/0028/0043 assertions) pass with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open a photo, add a layer, fill it with a black → white gradient. Cycle the layer through Hard Light and Soft Light: Hard Light gives strong contrast (mid-gray layer = no change), Soft Light a gentle version of the same. Fill the layer with a saturated color instead and cycle Color (photo's brightness, layer's hue and saturation), Hue (only hue changes), Saturation (photo becomes as saturated as the layer; a gray layer makes it grayscale), Luminosity (layer's brightness with the photo's colors). No tile seams at 100 %, 33 %, 400 % on Retina.
  2. Flatten (⇧⌘F) with each new mode: no visible change at the moment of flattening.
  3. Save the image with all six modes as `.ora` and open it in Krita: each layer shows Krita's matching mode (Hard Light, Soft Light — Krita may label the W3C one "Soft Light (SVG)" — Color, Luminosity, Hue, Saturation) and looks the same as in PaintDotMac. Save from Krita and reopen in PaintDotMac: the modes are kept.
  4. Effects ▸ Render ▸ Clouds…: the Blend Mode list has 20 items; Hue over a photo recolors it with cloud hues.

## Open questions

1. **Formula source for the L-4 modes.** PRD L-4 says "More blend modes from Paint.NET 5.x", but Paint.NET's current documentation (https://www.paint.net/doc/latest/BlendModes.html, fetched 2026-11-08) lists only the 14 L-3 layer modes (plus the tool-only Overwrite) and no L-4 mode, and no Paint.NET source defines them, so there is no Paint.NET formula to follow (D-17 can't apply). **Recommended (applied in this spec):** use the W3C Compositing and Blending Level 1 formulas (https://www.w3.org/TR/compositing-1/#blending), including the W3C/SVG Soft Light (not Photoshop's or Direct2D's Soft Light, which differs), pinned to the 8-bit arithmetic above. This also matches what the ORA `svg:*` names mean, so `.ora` files look the same in Krita. If you'd rather match Paint.NET 5 pixel-for-pixel, someone needs to measure Paint.NET 5's output (if it has these modes at all) and this spec's formulas would change.
2. **Position and order of the six modes in the popups.** Paint.NET documents no 20-mode order. **Recommended (applied):** append them after Xor in PRD L-4 order — Hard Light, Soft Light, Color, Luminosity, Hue, Saturation — with no separator. This keeps the L-3 list in Paint.NET's order and keeps blend indices 0…13 (and 0043's `blend_mode_at`) stable. Alternatives: W3C order (Hard Light, Soft Light, Hue, Saturation, Color, Luminosity), or grouping Hard/Soft Light next to Overlay (would renumber indices; raw values would still be stable).

## Out of scope

- PRD edits: FMT-E's explicit op list doesn't yet name the six L-4 ops; this spec applies FMT-E's rule ("standard `composite-op` names where they exist"). The orchestrator should add them to FMT-E (and record Open questions 1–2 in §12) when resolving this spec.
- Other blend modes (Linear Burn, Exclusion, Vivid Light, …), Porter-Duff ops (`svg:dst-in`, …), and Paint.NET's tool-only Overwrite (D-27).
- A Paint.NET-fidelity bound for L-4 (no reference exists; *Open questions* 1).
- Shared composition, harness, and L-3 modes → 0026/0027; Metal compositor architecture → 0024; `BlendOps.h`/`blend_mode_at` structure → 0043; ORA codec → 0028; Layer Properties → 0025.
- Tablet pressure and other v1.x tool work (0055–0058).
