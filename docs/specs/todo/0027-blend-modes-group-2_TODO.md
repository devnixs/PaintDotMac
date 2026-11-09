# 0027 — Add the Difference, Negation, Lighten, Darken, Screen, and Xor blend modes (completes L-3)

> Source: PRD.md §5.6 L-3 (part 2 of 2: Difference, Negation, Lighten, Darken, Screen, Xor; "Paint.NET's Xor is a per-channel color XOR, not Porter-Duff Xor"), L-2 (blend mode in Layer Properties), §5.3 T-11 (brush blend list grows with the layer modes), §4 *Rendering* (CPU reference compositor, Metal for display, ±1), NF-6 (blend modes have golden-image tests); §12 D-15 (brush blend-mode list = layer blend modes implemented so far), D-16 (CPU reference, Metal ±1 parity), D-17 (Paint.NET `UserBlendOps` formulas; Xor is color XOR). AGENTS.md *Code style* (one Metal function per blend mode, named after the `BlendMode` case) and *Testing expectations* (golden images in `PaintDotMacTests/Golden/`, ±1).
> Paint.NET sources: Paint.NET 3.36 (the last open-source release) `src/Data/UserBlendOps.Generated.cs`, read through its verbatim port in Pinta 1.6, which keeps the Paint.NET copyright header: https://github.com/PintaProject/Pinta/blob/1.6/Pinta.Core/Effects/UserBlendOps.Generated.cs (classes `DifferenceBlendOp`, `NegationBlendOp`, `LightenBlendOp`, `DarkenBlendOp`, `ScreenBlendOp`, `XorBlendOp`, each with a nested `…WithOpacity`; the classes appear in the file in exactly L-3 order, Normal … Xor). Paint.NET docs: https://www.getpaint.net/doc/latest/BlendModes.html (now served at https://paint.net/doc/latest/BlendModes.html): names, descriptions, and the order Normal, Multiply, Additive, Color Burn, Color Dodge, Reflect, Glow, Overlay, Difference, Negation, Lighten, Darken, Screen, Xor ("The Blend Mode drop-down … offers 14 blend modes"; the 15th heading, Overwrite, is tool-only and excluded by D-27).
> Milestone: M3
> Depends on: 0026-blend-modes-group-1 (and transitively 0002 `BlendMode`, 0009 `BlendOps`, 0011 Pencil popup, 0012 `CPUCompositor`/`PixelSampler`, 0017 Paint Bucket, 0023 Gradient, 0024 `MetalCompositor` + `Shaders/Blend.metal` + `GoldenImage.swift` + `LayerOperations`, 0025 Layer Properties dialog)

## Context

There is no application code yet; this spec builds on the files the earlier specs create.

- **0026** sets the pattern this spec follows exactly (read it first: `docs/specs/todo/0026-blend-modes-group-1_TODO.md`, moved to `done/` once built):
  - `Core/Model/BlendMode.swift` cases in L-3 order with frozen raw values (also the Metal kernel names) and Paint.NET `displayName`s; today `normal … overlay` (8 cases).
  - `Core/Rendering/BlendOps.swift`: `compose(dst:src:_:)` (the shared normative composition = 0009's exact Normal formula generalized with a per-channel function `F`, `Sa == 0` → `dst` bit-identical), nested `enum Channel` with one `static func <case>(_ a: UInt8, _ b: UInt8) -> UInt8` per mode (`a` = destination channel, `b` = source channel), one pixel function `static func <case>(dst:src:) -> ColorRGBA8` per mode, and one `case` per mode in `blend(_:dst:src:opacity:)`'s exhaustive switch. `normal(dst:src:)` stays 0009's own code.
  - `Core/Rendering/Shaders/Blend.metal` (structure from **0024**): shared `mul255(uint, uint)`, 0026's shared composition `compose_op(uint4 dst, uint4 src, uint3 f)`, `template <typename Op> apply_layer(…)`, one `…Op` struct plus one `kernel` per mode named exactly `BlendMode.rawValue` with `normal`'s signature (`device uchar4* accum [[buffer(0)]], device const uchar4* src [[buffer(1)]], constant LayerBlendUniforms& u [[buffer(2)]], uint2 gid [[thread_position_in_grid]]`). `MetalCompositor.init(device:library:)` builds one pipeline per `BlendMode.allCases` (function name = raw value) and throws `.functionMissing(name)` when one is absent, so a missing kernel fails `MetalCompositorTests` at once.
  - Test support: `PaintDotMacTests/Rendering/Reference/BlendReference.swift` (four exhaustive `switch`es: `paintNET336F`, `realF`, `compositeDouble`, `paintNET336Composite`; "0027 adds its six cases to all four switches"), `PaintDotMacTests/Support/BlendFixtures.swift` (`goldenPair(mode:)`, 300×300 two layers), and the suites `BlendModeTests`, `BlendChannelTests`, `BlendModeCompositionTests`, `PaintNET336FidelityTests` (including `generalWithinBound(mode:)` with its exhaustive per-mode bound `switch`), `BlendModeGoldenTests`, `BlendModeParityTests`, `BlendModeIntegrationTests`, `BlendModesUITests`. Mode-parameterized tests use `@Test(arguments: BlendMode.allCases.filter { $0 != .normal })`, so they run for this spec's six modes as soon as they exist; hand-computed spot tables and mode-specific tolerances are per-mode and must be extended here.
- **0025** `UI/LayerPropertiesDialog.swift`: "Blend mode:" popup `layerProperties.blendMode` built from `BlendMode.allCases` by `displayName` in enum order. **0009/0011/0017/0023** tool-option popups `toolOptions.blendMode` (Paintbrush, Pencil, Paint Bucket, Gradient) are also built from `BlendMode.allCases` (0026 made sure none hard-codes a list). So the six new cases appear everywhere automatically; this spec only proves it.
- **0012** `CPUCompositor` and `PixelSampler` (Image mode), and **0024**'s `LayerCommand.mergeLayerDown` / `.flatten` (through `CPUCompositor.merged(_:onto:)` / `flattened(_:)`), go through `BlendOps.blend`, so they need no change. **0024** `GoldenImage` (`assertGolden(_:width:height:named:oracle:tolerance:)`, `expectMatch`) and `MetalCompositor.compositeTilePixels(_:of:)` are the golden and GPU harnesses 0026's suites use.

### Paint.NET 3.36 `UserBlendOps`, transcribed exactly (this spec's six modes)

Notation as in 0026: `A` = **lhs** = destination (the composition below), `B` = **rhs** = source (the blend layer / tool paint on top), both channel values 0…255, applied to R, G, B separately. `INT_SCALE(p, q)` = `t = p·q + 0x80; ((t >> 8) + t) >> 8` = our `mul255`. Quoted from the generated `Apply(ColorBgra lhs, ColorBgra rhs)` bodies (blue channel shown; green and red are identical):

| Mode (Paint.NET class) | 3.36 source (verbatim, blue channel) | `F(A, B)` |
|---|---|---|
| Difference (`DifferenceBlendOp`) | `fB = Math.Abs(((rhs).B) - ((lhs).B));` | `|B − A|` |
| Negation (`NegationBlendOp`) | `fB = (255 - Math.Abs(255 - ((lhs).B) - ((rhs).B)));` | `255 − |255 − A − B|` |
| Lighten (`LightenBlendOp`) | `fB = Math.Max((lhs).B, (rhs).B);` | `max(A, B)` |
| Darken (`DarkenBlendOp`) | `fB = Math.Min((lhs).B, (rhs).B);` | `min(A, B)` |
| Screen (`ScreenBlendOp`) | `{ fB = ((rhs).B * (lhs).B + 0x80); fB = (((fB >> 8) + fB) >> 8); } fB = (rhs).B + (lhs).B - fB;` | `A + B − INT_SCALE(B, A)` |
| Xor (`XorBlendOp`) | `fB = (((lhs).B) ^ ((rhs).B));` | `A ^ B` (bitwise XOR of the 8-bit values) |

Facts the implementation and tests rely on:
- All six are **symmetric** in `A` and `B` (unlike Color Burn/Dodge/Reflect/Glow), so swapping operands in `F` gives the same value. The composition is still not symmetric (it weights `A` by the destination alpha and `B` by the source alpha), so the `(dst, src)` order of `compose` matters exactly as in 0026.
- No division, no zero guard. Every result is in 0…255 with no clamping needed: `|B − A| ≤ 255`; `|255 − A − B| ≤ 255` so Negation ∈ 0…255; Screen `A + B − round(AB/255)` ∈ 0…255 because `round(AB/255) ≥ A + B − 255` for all bytes (Screen(255, 255) = 255, Screen(0, x) = x). Intermediates: `255 − A − B` ranges −255…255, so Negation is computed in **signed** `Int32` (or as `A + B ≤ 255 ? A + B : 510 − A − B` in unsigned arithmetic — the identity `255 − |255 − s| = min(s, 510 − s)` for `s = A + B`).
- **Xor is the per-channel color XOR, not Porter-Duff Xor** (PRD L-3, D-17). Alpha is never XORed; it comes from the shared composition like every other mode. The Paint.NET doc: "Pixels in the blend layer which exactly match the composition will be rendered black" (opaque over opaque: `A ^ A = 0`).
- **Alpha composition:** Paint.NET 3.36 uses the same fixed-point `y/x/z/totalA` composition for these six as for 0026's seven (verified identical in every generated class, including `…WithOpacity`, which first scales `rhsA = INT_SCALE(rhs.A, opacity)`). PaintDotMac does **not** copy that fixed point; it uses 0026's normative exact-rounding composition (next section). The table of `masTable` divisions is irrelevant to these modes' `F` (no division in `F`).

### PaintDotMac's normative formula (unchanged from 0026)

With `Sa = mul255(src.a, opacity)`, `Da = dst.a`, all arithmetic in `UInt32` (the `F` for Negation in `Int32` or via `min(s, 510 − s)`):
```
if Sa == 0 { return dst }                                   // bit-identical
fa   = Sa·255 + Da·(255 − Sa)
outA = (fa + 127) / 255
outC = (Dc·Da·(255 − Sa) + Sc·Sa·(255 − Da) + F(Dc, Sc)·Sa·Da + fa/2) / fa      // C ∈ {R, G, B}
```
Consequences (all tested): opaque over opaque gives exactly `F`; a source over a fully transparent destination gives the source exactly; a transparent source (or opacity 0) leaves the destination bit-identical.

**Fidelity to Paint.NET 3.36's own fixed-point output** (measured by exhaustively checking every `(Da, Sa) ∈ 1…255²` against every `(A, B) ∈ 0…255²` channel pair, in a script independent of the app):

| Bound vs `BlendReference.paintNET336Composite` (RGB) | Difference | Negation | Lighten | Darken | Screen | Xor |
|---|---|---|---|---|---|---|
| `Da == 255` (layer over an opaque background) | ±1 | ±1 | ±1 | ±1 | ±1 | ±1 |
| `Da ≥ 128` and `Sa ≥ 128` | ±2 | ±2 | ±1 | ±1 | ±1 | ±2 |
| general (`Sa > 0`) | ±7 | ±7 | ±5 | ±5 | ±5 | ±7 |

Alpha always equals Paint.NET's `totalA` exactly. The worst cases are at tiny alphas, e.g. Difference with `Da = 8`, `Sa = 16`, `A = B = 255` (Paint.NET's rounded `x` and `y` weights dominate a tiny `totalA`). Against the **real-valued** `G` (the thing Paint.NET's fixed point approximates), the normative formula is within ±1 everywhere.

**0026's modes:** the same exhaustive check gives a general maximum of **5** for every 0026 mode (e.g. Multiply at `Da = 7, Sa = 19`; Overlay at `Da = 16, Sa = 8`) and for Normal, while the `Da == 255` bound (±1) holds. 0026 already states ±5 and owns `PaintNET336FidelityTests.generalWithinBound(mode:)` with an exhaustive per-mode `switch` (no `default`); this spec adds its six cases to that switch.

### Real-valued forms (for the `realF` reference)

Difference `|b − a|`; Negation `255 − |255 − a − b|`; Lighten `max(a, b)`; Darken `min(a, b)`; Screen `a + b − a·b/255`; Xor has no real-valued counterpart: `realF` returns `Double(Int(a) ^ Int(b))` (inputs are integral in every call). Max `|F − realF|` over all 65 536 pairs: 0 for Difference, Negation, Lighten, Darken, Xor; 0.498 for Screen.

## User story

As a PaintDotMac user, I can set a layer's blend mode to Difference, Negation, Lighten, Darken, Screen, or Xor in Layer Properties, and the canvas, Flatten, Merge Layer Down, and image sampling all render it the way Paint.NET does. Every blend-mode popup (Layer Properties, Paintbrush, Pencil, Paint Bucket, Gradient) now offers the complete Paint.NET list of 14 modes, in Paint.NET's order.

## Scope & changes

### Core (headless, unit-tested)

- **`PaintDotMac/Core/Model/BlendMode.swift`** (modify): append six cases **after `overlay`**, in L-3 order. After this spec `allCases` is the complete L-3 list (14 cases); 0059 appends L-4 after `xor`.

  | Case | Raw value (frozen forever; also the Metal kernel name) | `displayName` (Paint.NET spelling) |
  |---|---|---|
  | `difference` | `"difference"` | Difference |
  | `negation` | `"negation"` | Negation |
  | `lighten` | `"lighten"` | Lighten |
  | `darken` | `"darken"` | Darken |
  | `screen` | `"screen"` | Screen |
  | `xor` | `"xor"` | Xor |

  Raw values are persisted in `tool.<id>.blendMode` and (via 0028's `OpenRasterBlendMap`) map to `svg:difference`, `paintdotmac:negation`, `svg:lighten`, `svg:darken`, `svg:screen`, `paintdotmac:xor` (PRD FMT-E). Never rename them. Unknown raw values still read as `.normal`.
- **`PaintDotMac/Core/Rendering/BlendOps.swift`** (modify), exactly 0026's pattern:
  - `BlendOps.Channel`: add `static func difference(_ a: UInt8, _ b: UInt8) -> UInt8`, `negation`, `lighten`, `darken`, `screen`, `xor`, each the exact 3.36 `F(A = a, B = b)` from the table, with a doc comment quoting the formula. Screen uses `BlendOps.mul255(b, a)`. Negation must not underflow: compute `s = UInt32(a) + UInt32(b)` and return `s <= 255 ? s : 510 − s` (equivalent to `255 − |255 − s|`; doc-comment the identity), or use `Int32`. Checked arithmetic only (no `&+`/`&-`).
  - Pixel functions, named after the case, next to 0026's: `static func difference(dst: ColorRGBA8, src: ColorRGBA8) -> ColorRGBA8 { compose(dst: dst, src: src, Channel.difference) }`, and likewise `negation`, `lighten`, `darken`, `screen`, `xor`.
  - `blend(_:dst:src:opacity:)`: add the six `case`s to the exhaustive switch (no `default`).
- **`PaintDotMac/Core/Rendering/Shaders/Blend.metal`** (modify), 0024/0026 structure:
  - `static inline uint differenceChannel(uint a, uint b)`, `negationChannel`, `lightenChannel`, `darkenChannel`, `screenChannel`, `xorChannel` — the same integer formulas in `uint` (`differenceChannel`: `a > b ? a − b : b − a`; `negationChannel`: `s = a + b; s <= 255 ? s : 510 − s`; `lightenChannel`: `max(a, b)`; `darkenChannel`: `min(a, b)`; `screenChannel`: `a + b − mul255(b, a)`; `xorChannel`: `a ^ b`). No floating point, no signed underflow.
  - One `…Op` struct per mode (`DifferenceOp`, `NegationOp`, `LightenOp`, `DarkenOp`, `ScreenOp`, `XorOp`, each `static uint4 apply(uint4 dst, uint4 src)` calling the shared composition with its channel helper), and one `kernel` per mode named **exactly** `difference`, `negation`, `lighten`, `darken`, `screen`, `xor`, with `normal`'s signature, calling `apply_layer<…Op>`.
  - No Swift-side change: `MetalCompositor` keeps no mode → index table; its pipeline-per-`allCases` loop (function name = raw value) picks up the six kernels. Nothing GPU-side is persisted.
- **No `CPUCompositor`, `LayerOperations`, `PixelSampler`, or tool change.** They go through `BlendOps.blend`.

### Platform glue (covered by UI tests and manual checks)

- **Blend-mode popups:** no code change expected — Layer Properties (`layerProperties.blendMode`) and every `toolOptions.blendMode` popup (Paintbrush, Pencil, Paint Bucket, Gradient) list `BlendMode.allCases` by `displayName`. After this spec each lists exactly, in this order (Paint.NET's BlendModes page order and 3.36 class order): **Normal, Multiply, Additive, Color Burn, Color Dodge, Reflect, Glow, Overlay, Difference, Negation, Lighten, Darken, Screen, Xor**. Verify with `grep -rn "blendMode" PaintDotMac/UI PaintDotMac/Canvas` that no popup filters or truncates the list; fix any that does. The Eraser still has no blend mode (T-12); the Gradient popup stays disabled in Transparency Mode (0023).
- **Canvas display:** the `MetalCompositor` picks up the new kernels via the pipeline-per-case loop; mode changes redraw through 0025's existing path. No new invalidation code.
- No new menu items, history steps, or accessibility identifiers.
- **Existing tests to update in this change** (behavior changed on purpose):
  - 0026 `BlendModeTests.casesRawValuesAndNames`: the 14-case list (below).
  - 0026 `BlendModesUITests.layerPropertiesListsModesAndAppliesMultiply` and `.toolBlendPopupListsModesAndPersists`: 8 items → the 14 items in order.
  - 0026 `BlendChannelTests.closeToRealValuedFormula(mode:)`: add the per-mode tolerances (exact for Difference, Negation, Lighten, Darken, Xor; `≤ 0.5 + 1e-9` for Screen). Implement the tolerance as an exhaustive `switch` over `BlendMode` in the test (not an `if` chain), so 0059 must decide its tolerance.
  - 0026 `PaintNET336FidelityTests.generalWithinBound(mode:)`: add the six cases to its exhaustive bound `switch` — Difference, Negation, Xor ±7; Lighten, Darken, Screen ±5 (Context); 0026's seven stay ±5. Keep its 200 000 seeded random pairs and add the pinned worst cases (Test plan).
  - Any other 0026/0025/0017/0023/0011/0009 assertion on an item count of 8.
- `project.yml`: no change. Golden PNGs are read from `PaintDotMacTests/Golden/` through `#filePath` (0024 `GoldenImage.directory`), so no resource entry is needed. Run `xcodegen generate` after adding files.
- PRD: no change. L-3 and D-17 already define this; the composition and fidelity rules come from 0009/0026.

## Acceptance criteria

- [ ] `BlendMode.allCases` is exactly the 14 L-3 cases `[normal, multiply, additive, colorBurn, colorDodge, reflect, glow, overlay, difference, negation, lighten, darken, screen, xor]` with the raw values and display names in the tables (0026's and this spec's); the display-name list equals Paint.NET's BlendModes page order. → `BlendModeTests.casesRawValuesAndNames`, `BlendModeTests.completeL3ListMatchesPaintNETOrder`
- [ ] Unknown raw values still load as Normal; the six new raw values load as their cases. → `BlendModeTests.unknownRawValueReadsAsNormal`
- [ ] Each new channel function equals Paint.NET 3.36's `F` for all 65 536 `(a, b)` pairs. → `BlendChannelTests.matchesPaintNETTranscriptionExhaustive(mode:)` (0026's, now running for the six), `BlendChannelTests.groupTwoSpotValues`
- [ ] Each new channel function is symmetric, stays in 0…255 without wrapping, and is exact (Screen within 0.5) against the real-valued form. → `BlendChannelTests.groupTwoSymmetric`, `BlendChannelTests.closeToRealValuedFormula(mode:)`
- [ ] Xor is a per-channel color XOR: identical opaque colors give opaque black, alpha is never XORed. → `BlendChannelTests.groupTwoSpotValues`, `BlendModeCompositionTests.xorIsColorXorNotPorterDuff`
- [ ] Each new mode's pixel result follows the normative composition: alpha exact, RGB within ±1 of the independent `Double` reference, opaque-over-opaque = `F` exactly, transparent source leaves dst, transparent dst gives src, opacity scales source alpha first. → `BlendModeCompositionTests.*(mode:)` (0026's parameterized tests), `BlendModeCompositionTests.groupTwoPixelSpotValues`
- [ ] Results stay within the documented bounds of Paint.NET 3.36's own fixed-point output for all 13 non-Normal modes (±1 on an opaque destination; per-mode general bound). → `PaintNET336FidelityTests.opaqueDestinationWithinOne(mode:)`, `.generalWithinBound(mode:)`, `.pinnedWorstCases`
- [ ] `BlendOps.blend` dispatches each new case to its pixel function. → `BlendModeCompositionTests.dispatch(mode:)`
- [ ] Flatten, Merge Layer Down, Image-mode sampling, and Layer Properties honor the new modes, with undo/redo. → `BlendModeIntegrationTests.groupTwoMergeLayerDown(mode:)`, `.differenceFlattenUndoRedo`, `.imageSamplingSeesXor`, `.layerPropertiesScreenRoundTrip`
- [ ] The Paintbrush, Pencil, and Paint Bucket paint with the new modes. → `BlendModeIntegrationTests.paintbrushDifferenceStroke`, `.pencilDarkenPixel`, `.paintBucketXorFill`
- [ ] The Metal compositor matches the CPU compositor within ±1 for every new mode (channel grid and random stacks), and `MetalCompositor` builds a pipeline for all 14 cases. → `BlendModeParityTests.channelGridParity(mode:)`, `.randomStackParity(mode:)`, `MetalCompositorTests` pipeline construction (0024)
- [ ] Each new mode has a golden image (oracle-checked, CPU ±1, Metal ±1) and hand-computed spot pixels. → `BlendModeGoldenTests.goldenMatches(mode:)`, `.goldenSpotPixels`
- [ ] Layer Properties and every tool blend popup list all 14 modes in Paint.NET order; choosing Difference in Layer Properties adds a "Layer Properties" step that undo reverts; a tool's Xor choice persists across relaunch. → `BlendModesUITests.layerPropertiesListsAllFourteenModes`, `.toolPopupsListAllFourteenModes`, `.toolBlendPopupPersistsXor`
- [ ] The canvas visibly renders each new mode like the flattened result. → manual (look and feel), backed by parity tests.
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Negation underflow:** `255 − A − B` is negative when `A + B > 255`; in `UInt32` it would wrap/trap. Use `min(s, 510 − s)` with `s = A + B` (both terms non-negative because `s ≤ 510`) or `Int32`. Tested at `(255, 255) → 0`, `(0, 0) → 0`, `(128, 127) → 255`, `(128, 128) → 254`.
- **Difference underflow:** `B − A` with `A > B` must not wrap: compute `max − min`. Tested at `(255, 0)` and `(0, 255)` → 255.
- **Screen bounds:** `A + B − mul255(B, A)` never exceeds 255 or goes negative (exhaustive test); `A + B` computed in `UInt32` before subtracting.
- **Xor identity and black:** `F(A, A) = 0`, `F(A, 0) = A`, `F(A, 255) = 255 − A`. An Xor layer identical to an opaque background renders opaque black (Paint.NET doc), not transparent (no Porter-Duff Xor alpha).
- **Lighten/Darken with semi-transparency:** the result is not simply `max`/`min` of the straight colors — the composition blends `F` with both inputs by alpha (`dst (200,100,50,255)`, `src (100,200,128,128)` Darken → `(150,100,50,255)`, not `(100,100,50)`). Spot-tested.
- **Alpha extremes:** `Sa == 0` → dst unchanged (bit-identical, including garbage RGB under `Da == 0`); `Da == 0` → src exactly; `Sa = Da = 255` → `F`; `Sa`/`Da` of 1 stay within ±1 of the Double reference.
- **Bottom layer with a new mode** composites onto transparent and shows its own pixels.
- **Sparse tiles:** an absent tile on a Difference layer is a transparent source → destination unchanged; sparse stays sparse.
- **Tile boundaries:** goldens use 0026's 300×300 fixture (crosses the 256 seam); spot pixels in the second tile row and column.
- **Unknown/renamed raw values** in defaults or files → `.normal`, no crash.
- **Pipeline creation:** a missing kernel name throws `CanvasRendererError.functionMissing` (0024), which `MetalCompositorTests` would surface; never a crash at runtime.

## Test plan

All expected values below were computed independently of the implementation (by hand, or with a standalone script of the formulas in this spec). Swift Testing throughout. 0026's parameterized suites (`@Test(arguments: BlendMode.allCases.filter { $0 != .normal })`) automatically cover the six new modes once the reference functions exist; the items below are what this spec adds or changes.

- **Test support — `PaintDotMacTests/Rendering/Reference/BlendReference.swift`** (modify): add the six cases to all four exhaustive switches, written from this spec's tables in plain `Int` arithmetic (no app code):
  - `paintNET336F`: Difference `abs(b − a)`; Negation `255 − abs(255 − a − b)`; Lighten `max(a, b)`; Darken `min(a, b)`; Screen `b + a − (((t >> 8) + t) >> 8)` with `t = b·a + 128`; Xor `a ^ b`.
  - `realF`: the real-valued forms in Context (Xor → `Double(Int(a) ^ Int(b))`).
  - `compositeDouble` and `paintNET336Composite`: no per-mode code beyond `F` (they call `paintNET336F`/`realF`); add the cases if their switches are per-mode.
- **Unit — `PaintDotMacTests/Model/BlendModeTests.swift`** (modify):
  - `casesRawValuesAndNames`: `allCases` equals the 14 cases in order; raw values `normal, multiply, additive, colorBurn, colorDodge, reflect, glow, overlay, difference, negation, lighten, darken, screen, xor`; raw values unique.
  - `completeL3ListMatchesPaintNETOrder` (new): `BlendMode.allCases.map(\.displayName) == ["Normal", "Multiply", "Additive", "Color Burn", "Color Dodge", "Reflect", "Glow", "Overlay", "Difference", "Negation", "Lighten", "Darken", "Screen", "Xor"]` (literal array copied from the Paint.NET BlendModes page; cite the URL in a comment).
  - `unknownRawValueReadsAsNormal`: extend — storing `"xor"` in `tool.paintbrush.blendMode` loads `.xor`; `"Xor"` (wrong case) and `"exclusion"` load `.normal`; JSON `Codable` round trip of all 14 cases.
- **Unit — `PaintDotMacTests/Rendering/BlendChannelTests.swift`** (modify):
  - `matchesPaintNETTranscriptionExhaustive(mode:)` and `closeToRealValuedFormula(mode:)`: now run for the six (tolerances per the Scope bullet).
  - `groupTwoSymmetric` (new): for all 65 536 pairs and each of the six modes, `F(a, b) == F(b, a)` and `0 ≤ F ≤ 255` (computed in the Channel function's return type, so a wrap would trap or mismatch the reference).
  - `groupTwoSpotValues` (new; `(a = dst, b = src) → F`, hand-computed):
    - Difference: (128,128)→0, (200,100)→100, (100,200)→100, (0,255)→255, (255,0)→255, (30,250)→220, (127,128)→1, (64,192)→128.
    - Negation: (128,128)→254, (200,100)→210, (100,200)→210, (0,255)→255, (255,255)→0, (0,0)→0, (30,250)→230, (127,128)→255, (64,192)→254. Worked example: Negation(200,100): `255 − |255 − 300| = 255 − 45 = 210`.
    - Lighten: (200,100)→200, (100,200)→200, (0,255)→255, (127,128)→128, (64,192)→192.
    - Darken: (200,100)→100, (100,200)→100, (0,255)→0, (127,128)→127, (64,192)→64.
    - Screen: (128,128)→192, (200,100)→222, (0,255)→255, (255,255)→255, (0,0)→0, (30,250)→251, (127,128)→191, (64,192)→208. Worked example: Screen(200,100): `mul255(100,200) = round(78.43) = 78`, `200 + 100 − 78 = 222`.
    - Xor: (128,128)→0, (200,100)→172, (0,255)→255, (255,255)→0, (30,250)→228, (127,128)→255, (64,192)→128, (240,15)→255, (170,170)→0. Worked example: `200 ^ 100 = 0b11001000 ^ 0b01100100 = 0b10101100 = 172`.
- **Unit — `PaintDotMacTests/Rendering/BlendModeCompositionTests.swift`** (modify): 0026's parameterized tests (`opaqueOverOpaqueIsChannelFunction`, `transparentSourceLeavesDestination`, `overTransparentDestinationIsSource`, `matchesDoubleReferenceDenseGrid` — ±1 vs `round(compositeDouble(realF: false))`, within 1.5 of `realF: true`; measured maxima for the six: 1 and 0.96 — `matchesDoubleReferenceRandom`, `opacityScalesSourceAlpha`, `dispatch`) now include the six. Add:
  - `groupTwoPixelSpotValues` (hand-computed with the normative formula; dst, src → result):
    - `dst (200,100,50,255)`, `src (100,200,128,128)` → Difference `(150,100,64,255)`, Negation `(205,155,114,255)`, Lighten `(200,150,89,255)`, Darken `(150,100,50,255)`, Screen `(211,161,102,255)`, Xor `(186,136,114,255)`. Worked example, Difference R: `fa = 128·255 + 255·127 = 65025`, `F = |100 − 200| = 100`, `(200·255·127 + 100·128·0 + 100·128·255 + 32512) / 65025 = (6477000 + 3264000 + 32512) / 65025 = 9773512 / 65025 = 150`.
    - `dst (200,100,50,128)`, `src (100,200,128,255)` → Difference `(100,150,103,255)`, Negation `(155,205,153,255)`, Lighten `(150,200,128,255)`, Darken `(100,150,89,255)`, Screen `(161,211,141,255)`, Xor `(136,186,153,255)`.
    - `dst (200,100,50,128)`, `src (100,200,128,128)` → Difference `(133,133,85,192)`, Negation `(170,170,119,192)`, Lighten `(167,167,102,192)`, Darken `(133,133,76,192)`, Screen `(174,174,110,192)`, Xor `(157,157,119,192)`.
    - `dst (255,128,0,64)`, `src (64,192,255,192)` → Difference `(108,157,236,208)`, Negation `(108,187,236,208)`, Lighten `(123,187,236,208)`, Darken `(79,172,176,208)`, Screen `(123,195,236,208)`, Xor `(108,157,236,208)`.
    - `dst (10,20,30,0)`, `src (90,180,250,77)` → `(90,180,250,77)` for all six.
    - Opacity spot: Difference, `dst (200,100,50,255)`, `src (100,200,128,255)`, opacity 128 → `(150,100,64,255)` (same as `src.a = 128`).
  - `xorIsColorXorNotPorterDuff` (new): opaque `(12,34,56,255)` Xor over identical opaque `(12,34,56,255)` → `(0,0,0,255)` (alpha stays 255, not 0 as Porter-Duff Xor would give); `(240,170,15,255)` over `(15,170,255,255)` order-swapped and not → `(255,0,240,255)` both ways; semi-transparent `(12,34,56,128)` over `(12,34,56,255)` → `(6,17,28,255)`.
- **Unit — `PaintDotMacTests/Rendering/PaintNET336FidelityTests.swift`** (modify):
  - `opaqueDestinationWithinOne(mode:)`, `opaqueBothEqualsPaintNET(mode:)`: now include the six (bounds unchanged: ±1, exact).
  - `generalWithinBound(mode:)` (0026's test; this spec adds the six cases to its bound `switch`): 200 000 seeded random pairs with `Sa > 0` (30 % of alphas forced into 1…24 to reach the worst region) → RGB within the per-mode bound (0026's seven: 5; Difference, Negation, Xor: 7; Lighten, Darken, Screen: 5), alpha exactly equal to Paint.NET's `totalA`.
  - `pinnedWorstCases` (new; hand-computed):
    - Difference, Negation, and Xor with `dst (255,255,255,8)`, `src (255,255,255,16)` (`F = 0` for all three): normative `BlendOps.blend` → `(250,250,250,23)`; `BlendReference.paintNET336Composite` → `(243,243,243,23)`; difference exactly 7. Worked: normative `fa = 16·255 + 8·239 = 5992`, `outA = 6119/255 = 23`, `C = (255·8·239 + 255·16·247 + 0 + 2996)/5992 = 1498316/5992 = 250`; Paint.NET `y = INT_SCALE(8, 239) = 7`, `totalA = 23`, `x = INT_SCALE(8, 16) = 1`, `z = 15`, `C = (255·7 + 255·15 + 0·1)/23 = 5610/23 = 243`.
    - Lighten with `dst (0,0,0,7)`, `src (254,254,254,18)`: normative `(187,187,187,25)`, Paint.NET `(182,182,182,25)` (difference 5).
  - Plus the `both ≥ 128` bound: 50 000 seeded pairs with `Da, Sa ∈ 128…255` → Difference/Negation/Xor ±2, Lighten/Darken/Screen ±1, 0026's seven ±1.
- **Golden-image tests — `PaintDotMacTests/Rendering/BlendModeGoldenTests.swift`** (modify): `goldenMatches(mode:)` now covers the six with new goldens `blend-difference.png`, `blend-negation.png`, `blend-lighten.png`, `blend-darken.png`, `blend-screen.png`, `blend-xor.png` (same fixture `BlendFixtures.goldenPair(mode:)`, same oracle-before-record rule with `RECORD_GOLDENS=1`, CPU ±1 and Metal ±1). Extend `goldenSpotPixels` (hand-computed; bottom/top from 0026's fixture formulas; exact on CPU):
  - `(100, 50)`: bottom `(100,50,150,255)`, top `(200,86,155,255)` → Difference `(100,36,5,255)`, Negation `(210,136,205,255)`, Lighten `(200,86,155,255)`, Darken `(100,50,150,255)`, Screen `(222,119,214,255)`, Xor `(172,100,13,255)`.
  - `(200, 250)`: bottom `(200,250,194,82)`, top `(188,50,55,188)` → Difference `(138,114,94,210)`, Negation `(170,117,125,210)`, Lighten `(193,128,109,210)`, Darken `(189,71,69,210)`, Screen `(205,129,113,210)`, Xor `(168,114,124,210)`. Worked example, Xor R: `fa = 188·255 + 82·67 = 53434`, `outA = 53561/255 = 210`, `F = 200 ^ 188 = 116`, `(200·82·67 + 188·188·173 + 116·188·82 + 26717) / 53434 = (1098800 + 6114512 + 1788256 + 26717) / 53434 = 9028285 / 53434 = 168`.
  - `(280, 10)`: bottom `(24,10,34,255)`, top `(44,18,231,44)` → Difference `(23,10,62,255)`, Negation `(32,13,70,255)`, Lighten `(27,11,68,255)`, Darken `(24,10,34,255)`, Screen `(31,13,69,255)`, Xor `(29,12,62,255)`.
  - `(10, 299)`: bottom `(10,43,53,73)`, top `(96,33,245,255)` → Difference `(93,26,230,255)`, Negation `(99,45,236,255)`, Lighten `(96,36,245,255)`, Darken `(71,33,190,255)`, Screen `(98,44,246,255)`, Xor `(99,26,230,255)`.
- **Metal parity — `PaintDotMacTests/Rendering/BlendModeParityTests.swift`**: 0026's `channelGridParity(mode:)` and `randomStackParity(mode:)` now run for the six (random stacks draw modes from all 14 cases). Expected non-identical channel count 0.
- **Integration (headless) — `PaintDotMacTests/Integration/BlendModeIntegrationTests.swift`** (modify):
  - `groupTwoMergeLayerDown(mode:)` (arguments: the six): 4×4, bottom opaque `(200,100,50,255)`, top `(100,200,128,128)` with mode `mode` and opacity 128 (`Sa = mul255(128,128) = 64`). `LayerCommand.mergeLayerDown` through a `HistoryStack` → every pixel: Difference `(175,100,57,255)`, Negation `(203,128,82,255)`, Lighten `(200,125,70,255)`, Darken `(175,100,50,255)`, Screen `(206,131,76,255)`, Xor `(193,118,82,255)`. Worked example, Darken R: `fa = 64·255 + 255·191 = 65025`, `F = min(200,100) = 100`, `(200·255·191 + 0 + 100·64·255 + 32512) / 65025 = (9741000 + 1632000 + 32512) / 65025 = 11405512 / 65025 = 175`. Undo restores both layers, the top's mode and opacity; redo re-merges.
  - `differenceFlattenUndoRedo`: bottom opaque `(200,100,50,255)`, top `(100,200,128,128)` Difference → `LayerCommand.flatten` through a `HistoryStack` gives one layer of `(150,100,64,255)`; undo restores two layers (top `.difference`, pixels unchanged); redo flattens again.
  - `imageSamplingSeesXor`: `PixelSampler` Image mode on bottom `(240,170,15,255)` + top Xor `(15,170,255,255)` → `(255,0,240,255)`; Layer mode on the top → its raw `(15,170,255,255)`.
  - `paintbrushDifferenceStroke`: opaque `(128,128,128,255)` 32×32 layer, Paintbrush `blendMode = .difference`, color `(200,100,50,255)`, width 6, hardness 100, AA, dab at `(16.5,16.5)` → center `(72,28,78,255)` (opaque over opaque = `F`); a pixel outside the dab unchanged; undo restores.
  - `pencilDarkenPixel`: 0011 Pencil with `blendMode = .darken`, color `(100,150,50,255)`, one click on an opaque `(200,100,50,255)` layer → that pixel `(100,100,50,255)`; undo restores.
  - `paintBucketXorFill`: 0017 global fill on an opaque `(240,170,15,255)` 8×8 layer, color `(15,170,255,255)`, Xor → every pixel `(255,0,240,255)`; undo restores.
  - `layerPropertiesScreenRoundTrip`: real `UndoBridge`; 0025's `LayerPropertiesDialogModel` for the top layer, `edited.blendMode = .screen`, `ok()` → `undoBridge.commit(item)`, with top `(100,200,128,128)` over `(200,100,50,255)` to `.screen` → step "Layer Properties", composite `(211,161,102,255)`; undo → `.normal`, composite `(150,150,89,255)`; redo → `.screen`.
- **UI tests — `PaintDotMacUITests/BlendModesUITests.swift`** (modify):
  - `layerPropertiesListsAllFourteenModes` (replaces 0026's eight-item assertion in `layerPropertiesListsModesAndAppliesMultiply`, or a new test next to it): generated 64×64 PNG fixture, Layers > Add New Layer, double-click `layerRow.1` → `layerProperties.blendMode` lists exactly the 14 names in order. Choose Difference, OK → `historyList` gains "Layer Properties"; reopen shows Difference; Cancel; ⌘Z, reopen → Normal.
  - `toolPopupsListAllFourteenModes`: press B, P, F, G in turn → each `toolOptions.blendMode` lists the 14 names in order (Gradient in its default Color Mode, where the popup is enabled).
  - `toolBlendPopupPersistsXor`: press B, choose "Xor", relaunch without `-UITestResetDefaults` → popup shows "Xor"; then reset defaults.
- **Performance:** no new NF target; per-pixel cost stays a switch plus integer math (0048 re-measures NF-2).
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: no warnings, all tests (including the updated 0026 assertions) pass with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open a photo, add a layer, fill it with a black → white gradient. Cycle the layer through Difference, Negation, Lighten, Darken, Screen, Xor in Layer Properties: Difference and Negation both leave the photo unchanged where the layer is black and invert it where the layer is white, but differ in the mid-tones (Difference darkens where the layer matches the photo; Negation brightens there); Lighten/Darken keep the lighter/darker of the two; Screen brightens (black looks transparent); Xor gives harsh posterized colors and pure black where the layer exactly matches. No tile seams at 100 %, 33 %, 400 % on Retina.
  2. Duplicate the photo layer (⇧⌘D) and set the copy to Xor: the canvas is opaque black; set it to Difference: also black.
  3. Flatten (⇧⌘F) with a new-mode layer: no visible change at the moment of flattening.
  4. Open the Paintbrush's blend popup and Layer Properties: both show the 14 modes in Paint.NET order.
  5. Optional: compare with Paint.NET on Windows using the same two-layer image; expect identical results over an opaque background (±1) and small differences only on semi-transparent pixels.

## Out of scope

- L-4 modes (Hard Light, Soft Light, Color, Luminosity, Hue, Saturation; P1) → 0059 (appends after `xor`).
- ORA `composite-op` mapping for these modes (`svg:difference`, `svg:lighten`, `svg:darken`, `svg:screen`, `paintdotmac:negation`, `paintdotmac:xor`) → 0028 `OpenRasterBlendMap`.
- Paint.NET's tool-only "Overwrite" mode (D-27). Porter-Duff Xor (not a Paint.NET layer mode; PRD L-3).
- Layers panel, Layer Properties dialog, "Layer Properties" history step → 0025. Metal compositor architecture → 0024. The shared composition and test harness → 0026.
