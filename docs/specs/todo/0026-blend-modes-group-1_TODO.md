# 0026 — Add the Multiply, Additive, Color Burn, Color Dodge, Reflect, Glow, and Overlay blend modes

> Source: PRD.md §5.6 L-3 (part 1 of 2: Multiply, Additive, Color Burn, Color Dodge, Reflect, Glow, Overlay), L-2 (blend mode in Layer Properties), §5.3 T-11 (brush blend list grows with the layer modes), §4 *Rendering* (CPU reference compositor, Metal for display, ±1), NF-6 (blend modes have golden-image tests); §12 D-15 (brush blend-mode list = layer blend modes implemented so far), D-16 (CPU reference, Metal ±1 parity), D-17 (Paint.NET `UserBlendOps` formulas). AGENTS.md *Code style* (one Metal function per blend mode, named after the `BlendMode` case) and *Testing* (golden images in `PaintDotMacTests/Golden/`, ±1).
> Paint.NET sources: Paint.NET 3.36 (the last open-source release) `src/Data/UserBlendOps.Generated.cs` and `src/Data/UserBlendOps.cs`, read through their verbatim port in Pinta 1.6, which keeps the Paint.NET copyright header: https://github.com/PintaProject/Pinta/blob/1.6/Pinta.Core/Effects/UserBlendOps.Generated.cs (classes `MultiplyBlendOp`, `AdditiveBlendOp`, `ColorBurnBlendOp`, `ColorDodgeBlendOp`, `ReflectBlendOp`, `GlowBlendOp`, `OverlayBlendOp`, each with a nested `…WithOpacity`). Paint.NET docs: https://www.getpaint.net/doc/latest/BlendModes.html (names and descriptions).
> Milestone: M3
> Depends on: 0025-layers-panel-and-properties (and transitively 0002 `BlendMode`/`Layer`/`ColorRGBA8`, 0009 `BlendOps`, 0012 `CPUCompositor`, 0024 `MetalCompositor` + `Shaders/Blend.metal` + `GoldenImage.swift` + `LayerOperations`, 0017/0023 tool blend popups)

## Context

- **0002** creates `Core/Model/BlendMode.swift`: `enum BlendMode: String, CaseIterable, Codable, Sendable { case normal }` with `var displayName: String`. "The raw value is the Metal function name." 0002's test `BlendModeTests.blendModeNormal` asserts `BlendMode.allCases == [.normal]`.
- **0009** creates `Core/Rendering/BlendOps.swift` with `mul255(_:_:)` (`t = a·b + 128; ((t >> 8) + t) >> 8`, which equals `(a·b + 127) / 255` = `round(a·b / 255)` for every `a, b ∈ 0…255`), `blend(_ mode:, dst:, src:, opacity: = 255)` (first `src.a = mul255(src.a, opacity)`, then an exhaustive `switch` over `BlendMode`), and `normal(dst:src:)`. 0009 makes its own exact Normal formula normative (`fa = Sa·255 + Da·(255 − Sa)`, `outA = (fa + 127) / 255`, `outC = (Sc·Sa·255 + Dc·Da·(255 − Sa) + fa/2) / fa`, and `Sa == 0` returns `dst` bit-identical). Its Paintbrush blend popup (`toolOptions.blendMode`) lists "the `BlendMode` cases implemented so far, in L-3 order". 0017 (Paint Bucket) and 0023 (Gradient) reuse that popup.
- **0012** creates `Core/Rendering/CPUCompositor.swift`. It composites each visible layer bottom to top with `BlendOps.blend(layer.blendMode, dst:, src:, opacity: layer.opacity)`, so it gets new modes automatically through `BlendOps`.
- **0024** creates `Core/Rendering/Shaders/Blend.metal`: shared `static inline` `mul255(uint, uint)` and `blend_normal_op(uint4 dst, uint4 src)`, a template `apply_layer<Op>(accum, src, u, gid)` (applies `s.a = mul255(s.a, u.opacity)`, then `accum = Op::apply(accum, s)`), a `NormalOp` struct, and **one compute kernel per blend mode named exactly `BlendMode.rawValue`** (`kernel void normal(device uchar4* accum [[buffer(0)]], device const uchar4* src [[buffer(1)]], constant LayerBlendUniforms& u [[buffer(2)]], uint2 gid [[thread_position_in_grid]])`). There is no dispatch switch: `MetalCompositor.init(device:library:)` builds one pipeline per `BlendMode.allCases` (function name = raw value) and throws `CanvasRendererError.functionMissing(name)` for a missing one; `encodeTile` dispatches the pipeline of `layer.blendMode`. GPU harness: `MetalCompositor.compositeTilePixels(_:of:) -> [ColorRGBA8]?` (synchronous straight-alpha readback of one composite tile, tests only) and `MetalCompositorTests.everyBlendModeHasKernel` (iterates `allCases`). `PaintDotMacTests/Support/GoldenImage.swift`: `GoldenImage.compare(_:to:width:height:tolerance:ignoreRGBWhereAlphaZero:) -> GoldenComparison`, `expectMatch(_:_:width:height:tolerance:)`, `assertGolden(_:width:height:named:oracle:tolerance:)` (checks actual vs oracle ±1 first; writes `Golden/<name>.png` only with `RECORD_GOLDENS=1` and only when the oracle check passed; a recording run never passes). `Core/Operations/LayerOperations.swift`: `LayerCommand.mergeLayerDown` / `.flatten` (`applied(to:)`, `makeHistoryItem(for:) -> DocumentSnapshotHistoryItem?`), which go through `CPUCompositor.merged(_:onto:)` / `flattened(_:)` and so through `BlendOps`.
- **0025** creates `UI/LayerPropertiesDialog.swift` + `UI/LayerPropertiesDialogModel.swift` ("Blend mode:" popup `layerProperties.blendMode`, built from `BlendMode.allCases` by `displayName`; live preview through `updateLiveState`; OK commits `LayerPropertiesHistoryItem.properties(layerID:before:after:)`, the "Layer Properties" step, which by H-6 never changes the active layer) and the Layers panel (`layerRow.<index>`, double-click opens Layer Properties).
- Today only Normal exists. PRD L-3 requires 14 modes whose "formulas follow Paint.NET's own `UserBlendOps`". This spec adds the first seven and sets up the pattern (a generic composition, per-channel functions, a table-driven test reference, and parameterized tests over `BlendMode.allCases`), so that **0027** (Difference, Negation, Lighten, Darken, Screen, Xor) only adds cases, channel functions, Metal functions, reference functions, goldens, and spot values.

### Paint.NET 3.36 `UserBlendOps`, transcribed exactly

Notation: `lhs` = the **destination** (the composition below, Paint.NET's "A", alpha `a`); `rhs` = the **source** (the blend layer or tool paint on top, "B", alpha `b`). `INT_SCALE(p, q)` = `t = p·q + 0x80; ((t >> 8) + t) >> 8` = our `mul255`. `/` is truncating integer division. Paint.NET implements every `n / d` below with `masTable`, a multiply-add-shift reciprocal table (`(n·M + A) >> S`). We checked all 255 table rows: for every `d ∈ 1…255` and every `n ∈ 0…65 025` it equals `⌊n / d⌋`, so plain integer division is exact.

**Per-channel blend functions `F(A, B)`** (A = lhs channel, B = rhs channel, both 0…255; applied to R, G, B separately; result 0…255):

| Mode (Paint.NET class) | `F(A, B)` exactly as in 3.36 |
|---|---|
| Multiply (`MultiplyBlendOp`) | `INT_SCALE(A, B)` |
| Additive (`AdditiveBlendOp`) | `min(255, A + B)` |
| Color Burn (`ColorBurnBlendOp`) | `B == 0 ? 0 : max(0, 255 − ((255 − A)·255) / B)` |
| Color Dodge (`ColorDodgeBlendOp`) | `B == 255 ? 255 : min(255, (A·255) / (255 − B))` |
| Reflect (`ReflectBlendOp`) | `B == 255 ? 255 : min(255, (A·A) / (255 − B))` |
| Glow (`GlowBlendOp`) | `A == 255 ? 255 : min(255, (B·B) / (255 − A))` (= Reflect with the operands swapped) |
| Overlay (`OverlayBlendOp`) | `A < 128 ? INT_SCALE(2·A, B) : 255 − INT_SCALE(2·(255 − A), 255 − B)` |
| *(Normal, for reference)* | `B` |

Division-by-zero guards, exactly as Paint.NET writes them: Color Burn `B == 0 → 0`, even for `A == 255`. This is a Paint.NET quirk: the real-valued limit would be 255, but 0 is what it does, and we copy it. Color Dodge `B == 255 → 255`, even for `A == 0`. Reflect `B == 255 → 255`, even for `A == 0`. Glow `A == 255 → 255`, even for `B == 0`. Overlay's two `INT_SCALE` operands are at most 254, so both stay in `UInt8` range. Every intermediate value is ≤ 65 025.

**Paint.NET 3.36's alpha composition.** It is the same for every mode. The file header calls it `G(A,a,B,b,F) = (a − ab)·A + (b − ab)·B + ab·F(A,B)`, divided by the output alpha `a + b − ab`. `…WithOpacity` first scales `rhsA = INT_SCALE(rhs.A, opacity)`:
```
y = INT_SCALE(lhsA, 255 − rhsA)        // ≈ a(1 − b)
totalA = y + rhsA                      // output alpha
if totalA == 0 { return (0,0,0,0) }
x = INT_SCALE(lhsA, rhsA)              // ≈ ab
z = rhsA − x                           // ≈ b − ab
outC = (lhsC·y + rhsC·z + F(lhsC, rhsC)·x) / totalA      // truncating
outA = totalA
```
Because the weights `y` and `x` are rounded **before** a small `totalA` divides them, and the division truncates, this fixed-point form can be up to **5** per channel away from PaintDotMac's exact-rounding result at low alphas (exhaustive check over every `(Da, Sa) ∈ 1…255²` and channel pair; 0027 *Context*), including for Normal (max 5, at `Da = 7, Sa = 18`). Over an opaque destination it is within ±1. 0009's remark that Paint.NET's fixed point "differs by at most 1" therefore holds only over an opaque destination; 0009 is corrected to say so.

### PaintDotMac's normative formula (decision for this spec)

PaintDotMac uses Paint.NET's **per-channel functions `F` exactly** (table above, integer semantics included). It evaluates Paint.NET's **composition `G` exactly**, with the same exact-rounding fixed point that 0009 already made normative for Normal. With `Sa = mul255(src.a, opacity)`, `Da = dst.a`, and all arithmetic in `UInt32`:
```
if Sa == 0 { return dst }                         // bit-identical, as 0009's Normal
fa   = Sa·255 + Da·(255 − Sa)                     // = outA·255, in 1…65 025
outA = (fa + 127) / 255
outC = (Dc·Da·(255 − Sa) + Sc·Sa·(255 − Da) + F(Dc, Sc)·Sa·Da + fa/2) / fa     // for C ∈ {R, G, B}
```
This is `G` scaled by 255²: `(a − ab)·255² = Da·(255 − Sa)`, `(b − ab)·255² = Sa·(255 − Da)`, `ab·255² = Sa·Da`, and `(a + b − ab)·255² = fa`. With `F(A, B) = B`, it reduces **algebraically to 0009's Normal**, because `Sc·Sa·(255 − Da) + Sc·Sa·Da = Sc·Sa·255`. So Normal and the new modes share one composition. The largest numerator is `255·fa + fa/2 ≤ 16 613 887`, which fits in `UInt32` (and in Metal `uint`).

The rationale is that 0009 already chose exact rounding over Paint.NET's fixed-point approximation for Normal. Using a different composition for the other modes would make Normal ≠ "Paint.NET formula with `F = B`" and break the single-pipeline design. Fidelity is still bounded and tested:
- When the destination is opaque (`Da == 255`, the common case of a layer over an opaque background), the result is within ±1 of Paint.NET 3.36 on every channel.
- When both are opaque, the result is exactly `F`.
- In general, the result is within ±5 of Paint.NET 3.36 for every mode of this spec (see `PaintNET336FidelityTests.generalWithinBound(mode:)`; 0027 extends the per-mode table).

Consequences, which the tests prove:
- A source over a fully transparent destination (`Da == 0`, `Sa > 0`) gives the source exactly, `(Sc, Sa)`, in every mode. A blend-mode layer over nothing shows its own pixels, as in Paint.NET.
- An opaque source over an opaque destination gives exactly `(F(Dr,Sr), F(Dg,Sg), F(Db,Sb), 255)`.
- A transparent source (`Sa == 0`, including after opacity 0) leaves the destination bit-identical. Here Paint.NET 3.36 returns `(0,0,0,0)` when `totalA == 0`, so the two differ only in the RGB of a fully transparent destination. We keep 0009's rule.

Note: the Paint.NET doc page describes Reflect and Glow in loose prose ("black pixels in the blend layer are ignored as if they were transparent"). That doesn't literally hold for either operand order. The 3.36 source is normative (D-17): Reflect = `A²/(255 − B)`, and Glow is the same with lhs and rhs swapped. The docs agree on the swap ("the same as swapping the layer positions and using Reflect").

## User story

As a PaintDotMac user, I can set a layer's blend mode to Multiply, Additive, Color Burn, Color Dodge, Reflect, Glow, or Overlay in Layer Properties. I see the canvas update the way Paint.NET would render it. Flatten, Merge Layer Down, and image sampling all agree with what I see. I can also pick the same modes for the Paintbrush, Paint Bucket, and Gradient tools.

## Scope & changes

### Core (headless, unit-tested)

- **`PaintDotMac/Core/Model/BlendMode.swift`** (modify): add the cases in **L-3 order**, directly after `normal`. `allCases` is the order every popup shows. 0027 appends its six cases after `overlay` in the same way.

  | Case | Raw value (persisted; also the Metal function name) | `displayName` (Paint.NET spelling) |
  |---|---|---|
  | `normal` | `"normal"` | Normal |
  | `multiply` | `"multiply"` | Multiply |
  | `additive` | `"additive"` | Additive |
  | `colorBurn` | `"colorBurn"` | Color Burn |
  | `colorDodge` | `"colorDodge"` | Color Dodge |
  | `reflect` | `"reflect"` | Reflect |
  | `glow` | `"glow"` | Glow |
  | `overlay` | `"overlay"` | Overlay |

  Raw values are **stable forever**. They are stored in `tool.<id>.blendMode` defaults and in crash-recovery/ORA round trips through 0028's `OpenRasterBlendMap`, which maps them to `svg:*` / `paintdotmac:*` names. Never rename them. An unknown stored raw value still reads as `.normal` (0009's rule, unchanged).
- **`PaintDotMac/Core/Rendering/BlendOps.swift`** (modify). This is the pattern 0027 copies:
  - `static func compose(dst: ColorRGBA8, src: ColorRGBA8, _ f: (UInt8, UInt8) -> UInt8) -> ColorRGBA8`, marked `@inline(__always)`. It is the normative composition above (with the `Sa == 0` early return before `f` is called), where `f(dstChannel, srcChannel)` is the mode's channel function. It does **not** apply opacity, because `blend` does that first.
  - `enum Channel` nested in `BlendOps`, with one pure function per mode: `static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8`, `additive`, `colorBurn`, `colorDodge`, `reflect`, `glow`, `overlay`. Each one is the exact 3.36 `F(A = a, B = b)` from the table, computed in `UInt32` with truncating `/`, using `mul255` for `INT_SCALE`. Document each with its formula and its zero guard.
  - One pixel function per mode, named after the case, next to `normal`: `static func multiply(dst: ColorRGBA8, src: ColorRGBA8) -> ColorRGBA8 { compose(dst: dst, src: src, Channel.multiply) }`, and likewise `additive`, `colorBurn`, `colorDodge`, `reflect`, `glow`, `overlay`.
  - `blend(_:dst:src:opacity:)`: add one `case` per mode to the exhaustive switch. Keep `normal(dst:src:)` exactly as 0009 wrote it; don't route it through `compose`. A test pins the identity `compose(dst, src) { $1 } == normal(dst, src)`.
  - Performance: the switch stays outside `compose`, and the closure is a static function reference, so the per-pixel cost is a switch plus inlined integer math. No new compositor code is needed. `CPUCompositor` (0012) and every tool compose path (Paintbrush 0009, Pencil 0011, Paint Bucket 0017, Gradient 0023) pick the modes up through `blend`.
- **`PaintDotMac/Core/Rendering/Shaders/Blend.metal`** (modify; 0024 owns the file's structure and the dispatch):
  - One `static inline` channel helper per mode, `<case>Channel(uint a, uint b) -> uint` (`multiplyChannel`, `additiveChannel`, `colorBurnChannel`, `colorDodgeChannel`, `reflectChannel`, `glowChannel`, `overlayChannel`). They use **the same integer formulas** in `uint`, with `mul255(p, q) = ((t >> 8) + t) >> 8, t = p·q + 128`, plain `/`, and the same zero guards. No floating point, so CPU and GPU produce identical bits (the ±1 tolerance is a safety margin, not an expected gap).
  - A shared `static inline uint4 compose_op(uint4 dst, uint4 src, uint3 f)` implementing the normative composition, including the `Sa == 0` → `dst` early return. Opacity is already applied by 0024's `apply_layer`, as on the CPU. Each Op computes `f` eagerly with its channel helper (harmless: the zero guards make every helper total, and the GPU doesn't trap) and calls `compose_op`. 0024's `blend_normal_op` stays as is.
  - One `…Op` struct per mode (`MultiplyOp`, `AdditiveOp`, `ColorBurnOp`, `ColorDodgeOp`, `ReflectOp`, `GlowOp`, `OverlayOp`, each `static uint4 apply(uint4 dst, uint4 src)`) and one `kernel` per mode, **named exactly after the enum case / raw value** (AGENTS.md): `multiply`, `additive`, `colorBurn`, `colorDodge`, `reflect`, `glow`, `overlay`, each with 0024's `normal` signature and calling `apply_layer<…Op>`.
  - No Swift-side change in `MetalCompositor.swift`: its pipeline-per-`allCases` loop picks up the new kernels, and `MetalCompositorTests.everyBlendModeHasKernel` fails if one is missing. Nothing GPU-side is persisted.
- **No `CPUCompositor`, `LayerOperations`, or `PixelSampler` change.** They already go through `BlendOps.blend`. The tests below prove that Flatten, Merge Layer Down, and Image-mode sampling honor the new modes.

### Platform glue (covered by UI tests and manual checks)

- **Blend-mode popups.** Layer Properties (0025, `UI/LayerPropertiesDialog.swift`) and every `toolOptions.blendMode` popup (Paintbrush 0009, Pencil 0011, Paint Bucket 0017, Gradient 0023) must build their items from `BlendMode.allCases` in order, using `displayName` as the title. If any of them hard-codes `[.normal]` or a list, change it to `BlendMode.allCases` in this spec. Check with `grep -rn "blendMode" PaintDotMac/UI PaintDotMac/Canvas`. After this spec, every popup lists exactly: Normal, Multiply, Additive, Color Burn, Color Dodge, Reflect, Glow, Overlay. The Eraser still has no blend mode (PRD T-12), and the Gradient popup stays disabled in Transparency Mode (0023).
- **Canvas display:** the `MetalCompositor` renders a layer with a new mode through its kernel. Changing a layer's mode in Layer Properties (including 0025's live preview) changes 0024's `LayerStackSignature`, so `CompositeChangeTracker` rebuilds every visible tile. No new invalidation code is needed.
- **No new menu items, history steps, or accessibility identifiers.** Changing the mode is 0025's "Layer Properties" history step. UI tests use 0025's `layerProperties.blendMode` and 0009's `toolOptions.blendMode`.
- **Existing tests to update in this change** (the behavior changed on purpose):
  - 0002 `BlendModeTests.blendModeNormal`: replace `allCases == [.normal]` with the full eight-case list (see `BlendModeTests.casesRawValuesAndNames` below).
  - 0009 `PaintbrushUITests.pressingBSelectsPaintbrushAndShowsOptions`: "exactly one item" becomes the eight items in order.
  - 0025 `LayersPanelUITests.testDoubleClickOpensProperties` ("lists only Normal" → the eight items in order), and any 0017/0023 test that asserts a popup item count or a one-item list. (0025's `blendModeListIsImplementedModes` compares with `allCases` and needs no change.)
  - 0023 `GradientToolTests.transparencyIgnoresBlendMode`: compare `.normal` against `.multiply` and `.colorBurn`, which is the guard its comment anticipated.
- `project.yml`: no change. New test files are picked up by the source globs; golden PNGs are read from `PaintDotMacTests/Golden/` through `#filePath` (0024 `GoldenImage.directory`), so no resource entry is needed. Run `xcodegen generate` after adding files.
- PRD: no change. This spec implements L-3 part 1 as decided in D-17. The exact-rounding composition extends 0009's normative Normal formula to the shared `G`, and the per-channel `F` are Paint.NET's exactly.

## Acceptance criteria

- [ ] `BlendMode.allCases` is exactly `[normal, multiply, additive, colorBurn, colorDodge, reflect, glow, overlay]`, with the raw values and display names in the table. An unknown raw value still loads as Normal. → `BlendModeTests.casesRawValuesAndNames`, `BlendModeTests.unknownRawValueReadsAsNormal`
- [ ] Each channel function equals Paint.NET 3.36's `F` for all 65 536 `(a, b)` pairs, including the zero guards. → `BlendChannelTests.matchesPaintNETTranscriptionExhaustive(mode:)`, `BlendChannelTests.divisionGuards`, `BlendChannelTests.spotValues`
- [ ] Each channel function is within 1 of the real-valued formula (within 0.5 for Multiply and Overlay, and exact for Additive). → `BlendChannelTests.closeToRealValuedFormula(mode:)`
- [ ] Each mode's pixel result matches the normative composition: alpha exact, RGB within ±1 of an independent `Double` reference, and opaque-over-opaque = `F` exactly. → `BlendModeCompositionTests.*`
- [ ] A transparent source leaves the destination bit-identical. A source over a transparent destination gives the source. Opacity scales the source alpha first. → `BlendModeCompositionTests.transparentSourceLeavesDestination(mode:)`, `.overTransparentDestinationIsSource(mode:)`, `.opacityScalesSourceAlpha(mode:)`
- [ ] Results stay within the stated bounds of Paint.NET 3.36's own fixed-point output (±1 on an opaque destination, ±5 in general, with pinned worst cases). → `PaintNET336FidelityTests.opaqueDestinationWithinOne(mode:)`, `.opaqueBothEqualsPaintNET(mode:)`, `.generalWithinBound(mode:)`, `.pinnedWorstCasesGroupOne`
- [ ] `BlendOps.blend` dispatches every case to its pixel function, and Normal's identity with `compose` holds. → `BlendModeCompositionTests.dispatch(mode:)`, `.composeWithIdentityEqualsNormal`
- [ ] The CPU compositor, Flatten, Merge Layer Down, and Image-mode sampling use the layer's mode, and undo/redo restores it. → `BlendModeIntegrationTests.*`
- [ ] The Metal compositor matches the CPU compositor within ±1 per channel for every new mode, over a grid that covers every `(lhs, rhs)` channel pair and over random stacks with random opacity. → `BlendModeParityTests.channelGridParity(mode:)`, `.randomStackParity(mode:)`
- [ ] Each mode has a golden image, checked against the CPU result (±1) and the Metal result (±1), with hand-computed spot pixels. → `BlendModeGoldenTests.goldenMatches(mode:)`, `.goldenSpotPixels`
- [ ] The Paintbrush (and Paint Bucket and Gradient) paint with the selected mode. → `BlendModeIntegrationTests.paintbrushMultiplyStroke`, `.paintBucketColorBurnFill`
- [ ] Layer Properties and the tool options blend popup list the eight modes in L-3 order. Choosing Multiply in Layer Properties creates a "Layer Properties" step that undo reverts. The Paintbrush mode persists across relaunch. → `BlendModesUITests.*`
- [ ] The canvas visibly renders each mode like the flattened result. → manual (look and feel), backed by the parity tests.
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Zero guards.** Color Burn with a source channel of 0 → 0 (even if the destination is 255). Color Dodge or Reflect with a source of 255 → 255 (even if the destination is 0). Glow with a destination of 255 → 255. None of these may trap. Swift `/` by zero traps, so the guards come first. They are tested exhaustively.
- **Clamping.** Additive saturates at 255. Dodge, Reflect, and Glow clamp with `min(255, …)` before the composition. Burn clamps with `max(0, …)` in signed arithmetic (`Int32`, or check `q > 255` before subtracting in `UInt32`). Underflow must not wrap: `255 − 4 335` for `A = 0, B = 15` must give 0.
- **Overflow.** Every channel intermediate is ≤ 65 025, and every composition numerator is ≤ 16 613 887 (`UInt32`). No `&+`/`&*` wrapping arithmetic is allowed. Use checked arithmetic, so an overflow would trap in tests.
- **Alpha extremes:** `Sa == 0` gives the destination unchanged. `Da == 0` gives the source. `Sa == 255, Da == 255` gives `F`. `Sa == 1` or `Da == 1` (tiny `fa`) stay within ±1 of the reference.
- **Opacity 0** layers are skipped by 0012 (and are a no-op through `blend` anyway). **Hidden** layers are skipped regardless of mode.
- **Bottom layer with a non-Normal mode:** it composites onto transparent `(0,0,0,0)`, so it shows its own pixels (the `Da == 0` rule). This matches Paint.NET, where the background layer's blend mode has no visible effect unless it is semi-transparent over nothing.
- **Garbage RGB under alpha 0.** A destination of `(9,9,9,0)` with an opaque Multiply source gives exactly the source (`Da == 0`, so `F` has weight 0).
- **Sparse tiles:** an absent tile on a Multiply layer is `(0,0,0,0)` = transparent source, so the destination is unchanged and 0012's "sparse stays sparse" behavior is preserved.
- **Tile boundaries:** goldens use a 300×300 canvas, which crosses the 256 tile seam.
- **Unknown raw value** in defaults or a future file gives `.normal` (no crash).

## Test plan

All expected values below were computed by hand or with the formulas above, independently of the implementation. Tests are Swift Testing. Mode-parameterized tests use `@Test(arguments: BlendMode.allCases.filter { $0 != .normal })`, so 0027's cases are covered as soon as it adds them to the reference. The test-target reference `switch` is exhaustive, so 0027 fails to compile until it adds its reference functions.

- **Test support — `PaintDotMacTests/Rendering/Reference/BlendReference.swift`** (new). It is written independently of `BlendOps`: plain `Int` arithmetic, written out from the tables in this spec, with no use of `mul255` or `compose` from the app.
  - `static func paintNET336F(_ mode: BlendMode, _ a: Int, _ b: Int) -> Int`: the 3.36 table, with `INT_SCALE` written as `((t >> 8) + t) >> 8`, `t = p·q + 128`.
  - `static func realF(_ mode: BlendMode, _ a: Double, _ b: Double) -> Double`: the real-valued forms. Multiply `a·b/255`; Additive `min(255, a+b)`; Burn `b == 0 ? 0 : max(0, 255 − (255−a)·255/b)`; Dodge `b == 255 ? 255 : min(255, a·255/(255−b))`; Reflect `b == 255 ? 255 : min(255, a²/(255−b))`; Glow `a == 255 ? 255 : min(255, b²/(255−a))`; Overlay `a < 128 ? 2ab/255 : 255 − 2(255−a)(255−b)/255`.
  - `static func compositeDouble(_ mode:, dst:, src:, opacity:, realF: Bool) -> (r, g, b, a: Double)`: `α = Da/255`, `β = Sa'/255` with `Sa' = round(Sa·opacity/255)`. `β == 0` returns dst. `oa = α + β − αβ`. `c = ((α − αβ)·Dc + (β − αβ)·Sc + αβ·F)/oa`, with `F` = `paintNET336F` (or `realF` if `realF == true`). Alpha is `oa·255`.
  - `static func paintNET336Composite(_ mode:, dst:, src:, opacity:) -> ColorRGBA8`: Paint.NET's exact fixed-point `y/x/z/totalA` algorithm with truncating division, transcribed from §Context (including `totalA == 0 → (0,0,0,0)`).
  - **0027 adds its six cases to all four switches.**
- **Test support — `PaintDotMacTests/Support/BlendFixtures.swift`** (new; 0024 has no equivalent). `static func goldenPair(mode: BlendMode) -> LayeredImage` returns a 300×300 image (`dpi` 96) with two layers:
  - Bottom layer "Background", Normal, opacity 255. Pixel `(x, y)` = `(x & 255, y & 255, (x + y) & 255, y < 200 ? 255 : (3x + y) & 255)`.
  - Top layer "Layer 2", blend mode `mode`, opacity 255. Pixel `(x, y)` = `((2y + x) & 255, (x ^ y) & 255, (255 − x) & 255, x < 150 ? 255 : (x + 2y) & 255)`.
  - Integer arithmetic in `Int` (`&` on negative values wraps two's complement, so `(255 − 280) & 255 == 231`).
- **Unit — `PaintDotMacTests/Model/BlendModeTests.swift`** (extend 0002's):
  - `casesRawValuesAndNames`: `allCases` equals the eight cases in order. The raw values are `normal, multiply, additive, colorBurn, colorDodge, reflect, glow, overlay`. The display names are `Normal, Multiply, Additive, Color Burn, Color Dodge, Reflect, Glow, Overlay`. Raw values are unique.
  - `unknownRawValueReadsAsNormal`: `BlendMode(rawValue: "hardLight") == nil`. Through `ToolOptionStore` (in-memory), storing `"foo"` in `tool.paintbrush.blendMode` loads `.normal`, and storing `"colorDodge"` loads `.colorDodge`. JSON `Codable` round trip of every case.
- **Unit — `PaintDotMacTests/Rendering/BlendChannelTests.swift`** (new):
  - `matchesPaintNETTranscriptionExhaustive(mode:)`: for all 65 536 `(a, b)`, `BlendOps.Channel.<mode>(a, b)` (reached through a test helper `channel(_ mode:)` that switches to the function) equals `BlendReference.paintNET336F(mode, a, b)`.
  - `closeToRealValuedFormula(mode:)`: for all 65 536 pairs, `|F − realF| < 1`. For Multiply and Overlay, `≤ 0.5 + 1e-9`. For Additive, exactly equal. Both measured maxima are 0.996 for Burn/Dodge/Reflect/Glow and 0.498 for Multiply/Overlay.
  - `divisionGuards`: `colorBurn(255, 0) == 0`, `colorBurn(0, 0) == 0`, `colorDodge(0, 255) == 255`, `colorDodge(255, 255) == 255`, `reflect(0, 255) == 255`, `glow(255, 0) == 255`, `glow(255, 255) == 255`, `colorBurn(0, 15) == 0` (no underflow wrap).
  - `spotValues` (hand-computed, as `(a = dst, b = src) → F`):
    - Multiply: (128,128)→64, (200,100)→78, (30,250)→29, (127,255)→127, (255,255)→255, (0,255)→0.
    - Additive: (128,128)→255, (128,0)→128, (100,27)→127, (255,0)→255.
    - Color Burn: (128,128)→2, (200,100)→115, (100,200)→58, (64,192)→2, (192,64)→4, (30,250)→26, (250,30)→213, (127,255)→127, (255,255)→255.
    - Color Dodge: (128,0)→128, (200,100)→255, (64,128)→128, (10,200)→46, (0,254)→0, (127,255)→255.
    - Reflect: (128,128)→129, (100,200)→181, (64,192)→65, (192,64)→193, (128,0)→64, (30,250)→180, (0,0)→0.
    - Glow: (128,128)→129, (200,100)→181, (64,192)→193, (192,64)→65, (128,0)→0, (250,30)→180, (0,0)→0.
    - Overlay: (128,128)→128, (200,100)→188, (100,200)→157, (64,192)→96, (192,64)→161, (127,255)→254, (128,0)→1, (30,250)→59, (250,30)→246, (0,255)→0, (255,0)→255.
    - Worked examples to put in comments: Burn(200,100): `(55·255)/100 = 140`, `255 − 140 = 115`. Reflect(100,200): `10000/55 = 181`. Overlay(200,100): `255 − round(110·155/255 = 66.86) = 255 − 67 = 188`. Dodge(10,200): `2550/55 = 46`.
- **Unit — `PaintDotMacTests/Rendering/BlendModeCompositionTests.swift`** (new):
  - `opaqueOverOpaqueIsChannelFunction(mode:)`: for every `(l, r)` pair in 0…255², `dst = (l, 255−l, l/2, 255)`, `src = (r, r/3, 255−r, 255)` gives exactly `(F(l,r), F(255−l, r/3), F(l/2, 255−r), 255)`, with `F = BlendReference.paintNET336F`.
  - `transparentSourceLeavesDestination(mode:)`: `src.a == 0` (any RGB) over `(1,2,3,200)` and over `(9,9,9,0)` returns dst bit-identical. `blend(mode, dst:, src: (255,255,255,255), opacity: 0)` returns dst too.
  - `overTransparentDestinationIsSource(mode:)`: for 10 000 seeded random sources with `a ≥ 1`, `dst = (9,9,9,0)` returns `src` exactly.
  - `matchesDoubleReferenceDenseGrid(mode:)`: grid channel values `{0, 1, 2, 15, 30, …, 240 (step 15), 127, 128, 254, 255}` for dst and src (gray triples plus the mixed triple `(v, 255−v, v/2)`), and alphas `{0, 1, 2, 3, 64, 127, 128, 200, 254, 255}` for both. Alpha must equal `(Sa·255 + Da·(255−Sa) + 127)/255` exactly. Where the reference `oa > 0`, every RGB channel is within ±1 of `round(compositeDouble(…, realF: false))` and within 1.5 of `compositeDouble(…, realF: true)` (measured maximum 1.46).
  - `matchesDoubleReferenceRandom(mode:)`: 200 000 seeded random `(dst, src, opacity)` triples per mode (30 % of alphas forced to `{0, 1, 2, 255}`), with the same assertions. `SeededRandom` prints the seed on failure.
  - `opacityScalesSourceAlpha(mode:)`: `blend(mode, dst:, src:, opacity: o) == blend(mode, dst:, src: (src.rgb, mul255(src.a, o)))` for 10 000 seeded triples. Spot: Multiply, `dst (200,100,50,255)`, `src (100,200,128,255)`, opacity 128 → `(139,89,37,255)`.
  - `dispatch(mode:)`: `BlendOps.blend(mode, dst:, src:)` equals the named pixel function (`BlendOps.multiply(dst:src:)` etc.) over 1 000 seeded pairs.
  - `composeWithIdentityEqualsNormal`: `compose(dst:src:) { $1 } == normal(dst:src:)` over 200 000 seeded pairs plus the 0009 spot cases.
  - `pixelSpotValues` (hand-computed with the normative formula; dst then src; result):
    - `dst (200,100,50,255)`, `src (100,200,128,128)` → Multiply `(139,89,37,255)`, Additive `(228,178,114,255)`, Color Burn `(157,79,25,255)`, Color Dodge `(228,178,75,255)`, Reflect `(228,141,34,255)`, Glow `(190,178,65,255)`, Overlay `(194,129,50,255)`. Worked example for Multiply R: `fa = 128·255 + 255·127 = 65025`, `F = mul255(200,100) = 78`, `(200·255·127 + 0 + 78·128·255 + 32512)/65025 = 9055432/65025 = 139`.
    - `dst (200,100,50,128)`, `src (100,200,128,255)` → Multiply `(89,139,76,255)`, Additive `(178,228,153,255)`, Color Burn `(108,129,64,255)`, Color Dodge `(178,228,114,255)`, Reflect `(178,190,73,255)`, Glow `(141,228,103,255)`, Overlay `(144,178,89,255)`.
    - `dst (200,100,50,128)`, `src (100,200,128,128)` → Multiply `(126,126,68,192)`, Additive `(185,185,119,192)`, Color Burn `(138,119,59,192)`, Color Dodge `(185,185,93,192)`, Reflect `(185,160,66,192)`, Glow `(160,185,86,192)`, Overlay `(163,152,76,192)`.
    - `dst (255,128,0,64)`, `src (64,192,255,192)` → Multiply `(79,165,176,208)`, Additive `(123,202,236,208)`, Color Burn `(123,163,176,208)`, Color Dodge `(123,202,236,208)`, Reflect `(123,202,236,208)`, Glow `(123,202,236,208)`, Overlay `(123,187,176,208)`.
    - `dst (10,20,30,0)`, `src (90,180,250,77)` → `(90,180,250,77)` for every mode.
- **Unit — `PaintDotMacTests/Rendering/PaintNET336FidelityTests.swift`** (new):
  - `opaqueDestinationWithinOne(mode:)`: 100 000 seeded pairs with `Da = 255` and random `Sa`, `opacity`: every channel (alpha included) within ±1 of `BlendReference.paintNET336Composite`.
  - `opaqueBothEqualsPaintNET(mode:)`: `Da = Sa = 255`: equal to Paint.NET exactly (both give `F`).
  - `generalWithinBound(mode:)`: 200 000 seeded random pairs with `Sa > 0` (30 % of alphas forced into 1…24, the worst region): RGB within the mode's bound and alpha exactly Paint.NET's `totalA`. The bound comes from an exhaustive `switch` over `BlendMode` in the test (no `default`, so 0027 and 0059 must add theirs): ±5 for all seven modes here (exhaustive maximum over every `(Da, Sa)` and channel pair; `.normal` → 5 too, though the test arguments exclude it).
  - `pinnedWorstCasesGroupOne` (computed with a standalone script of this spec's formulas; gray triples, `dst (A,A,A,Da)`, `src (B,B,B,Sa)`, opacity 255; normative `BlendOps.blend` vs `BlendReference.paintNET336Composite`, difference exactly 5):
    - Multiply `dst (254,254,254,7)`, `src (0,0,0,19)` → `(65,65,65,25)` vs `(60,60,60,25)`. Worked: normative `fa = 19·255 + 7·236 = 6497`, `outA = 6624/255 = 25`, `C = (254·7·236 + 0 + 0 + 3248)/6497 = 422856/6497 = 65`; Paint.NET `y = INT_SCALE(7, 236) = 6`, `totalA = 25`, `x = INT_SCALE(7, 19) = 1`, `C = (254·6)/25 = 60`.
    - Additive `dst (1,1,1,6)`, `src (249,249,249,21)` → `(198,198,198,27)` vs `(193,193,193,27)`.
    - Color Burn `dst (247,247,247,6)`, `src (8,8,8,22)` → `(56,56,56,27)` vs `(51,51,51,27)`.
    - Color Dodge `dst (4,4,4,6)`, `src (252,252,252,21)` → `(201,201,201,27)` vs `(196,196,196,27)`.
    - Reflect `dst (1,1,1,7)`, `src (255,255,255,18)` → `(188,188,188,25)` vs `(183,183,183,25)`.
    - Glow `dst (4,4,4,6)`, `src (252,252,252,21)` → `(201,201,201,27)` vs `(196,196,196,27)`.
    - Overlay `dst (0,0,0,16)`, `src (243,243,243,8)` → `(78,78,78,23)` vs `(73,73,73,23)`.
- **Golden-image tests — `PaintDotMacTests/Rendering/BlendModeGoldenTests.swift`** (new), using 0024's `GoldenImage` helper:
  - `goldenMatches(mode:)`: `cpu` = the full 300×300 pixels of `CPUCompositor().flattened(BlendFixtures.goldenPair(mode:))`; `oracle` = a per-pixel recomputation with `BlendReference.compositeDouble(…, realF: false)`, rounded. `GoldenImage.assertGolden(cpu, width: 300, height: 300, named: "blend-<rawValue>", oracle: oracle)` (oracle check ±1 first; records only with `RECORD_GOLDENS=1` after it passes). The Metal result (the four tiles' `MetalCompositor.compositeTilePixels`, stitched) is checked with `GoldenImage.expectMatch(metal, golden, width: 300, height: 300)` (±1) against the same golden PNG loaded through `ImageDecoder`. Seven new PNGs: `blend-multiply.png`, `blend-additive.png`, `blend-colorBurn.png`, `blend-colorDodge.png`, `blend-reflect.png`, `blend-glow.png`, `blend-overlay.png` (0024's goldens are `compositor-normal-stack-300` and `canvas-ten-layers-50`; no `blend-normal.png`).
  - `goldenSpotPixels` (hand-computed; bottom/top pixel values from the fixture formulas; exact on CPU):
    - `(100, 50)`: bottom `(100,50,150,255)`, top `(200,86,155,255)` → Multiply `(78,17,91,255)`, Additive `(255,136,255,255)`, Color Burn `(58,0,83,255)`, Color Dodge `(255,75,255,255)`, Reflect `(181,14,225,255)`, Glow `(255,36,228,255)`, Overlay `(157,34,173,255)`.
    - `(200, 250)`: bottom `(200,250,194,82)`, top `(188,50,55,188)` → Multiply `(177,70,66,210)`, Additive `(209,130,125,210)`, Color Burn `(187,122,53,210)`, Color Dodge `(209,130,125,210)`, Reflect `(209,130,108,210)`, Glow `(209,130,68,210)`, Overlay `(200,127,99,210)`. Worked example for Multiply R: `fa = 188·255 + 82·67 = 53434`, `outA = 53561/255 = 210`, `F = mul255(200,188) = 147`, `(200·82·67 + 188·188·173 + 147·188·82 + 26717)/53434 = 9506181/53434 = 177`.
    - `(280, 10)` (second tile column): bottom `(24,10,34,255)`, top `(44,18,231,44)` → Multiply `(21,8,33,255)`, Additive `(32,13,72,255)`, Color Burn `(20,8,30,255)`, Color Dodge `(25,10,72,255)`, Reflect `(20,8,36,255)`, Glow `(21,8,70,255)`, Overlay `(21,8,39,255)`.
    - `(10, 299)` (second tile row): bottom `(10,43,53,73)`, top `(96,33,245,255)` → Multiply `(70,25,189,255)`, Additive `(99,45,248,255)`, Color Burn `(69,24,188,255)`, Color Dodge `(73,38,248,255)`, Reflect `(69,26,248,255)`, Glow `(79,25,248,255)`, Overlay `(71,27,204,255)`.
- **Metal parity — `PaintDotMacTests/Rendering/BlendModeParityTests.swift`** (new; `@MainActor`, real `MTLCreateSystemDefaultDevice()` and the app's default library as 0024's `MetalCompositorTests`; comparisons with `GoldenImage.compare` per tile of `MetalCompositor.compositeTilePixels` vs `CPUCompositor.compositeTile`; the quality gate allows no skipped tests):
  - `channelGridParity(mode:)`: 256×256 two-layer images. Bottom pixel `(x, 255−x, x, Da)` and top `(y, y, 255−y, Sa)` cover every `(lhs, rhs)` channel pair. For `(Da, Sa)` ∈ `{(255,255), (255,128), (128,200), (1,254), (77,3), (0,255)}` and top opacity ∈ `{255, 100}`, the Metal result is within ±1 of `CPUCompositor` on every channel. Report the count of non-identical channels (expected 0).
  - `randomStackParity(mode:)`: 10 seeded random stacks per mode (2–4 layers, 300×300, random mode among `allCases` per layer, random visibility, opacity, and straight pixels with forced 0/255 alphas): Metal within ±1 of CPU.
- **Integration (headless) — `PaintDotMacTests/Integration/BlendModeIntegrationTests.swift`** (new):
  - `flattenUsesBlendMode`: 4×4 image. Bottom opaque `(200,100,50,255)`, top `(100,200,128,128)` set to Color Dodge. `LayerCommand.flatten.makeHistoryItem(for:)` performed through a `HistoryStack` leaves one layer whose pixels are all `(228,178,75,255)`. Undo restores two layers, with the top layer's mode `.colorDodge` and its pixels unchanged. Redo flattens again.
  - `mergeLayerDownUsesBlendMode(mode:)`: the same two layers with top mode `mode` and top opacity 128 (so `src.a = mul255(128,128) = 64`). `LayerCommand.mergeLayerDown` (active = top, through a `HistoryStack`) gives every pixel `== BlendOps.blend(mode, dst: (200,100,50,255), src: (100,200,128,128), opacity: 128)`. Spot values (hand-computed with `Sa = 64`, `Da = 255`, so `fa = 64·255 + 255·191 = 65025` and `outA = 255`): Multiply `(169,94,44,255)` (R: `F = mul255(200,100) = 78`; `(200·255·191 + 100·64·0 + 78·64·255 + 32512)/65025 = (9741000 + 1272960 + 32512)/65025 = 11046472/65025 = 169`), Additive `(214,139,82,255)`, Color Burn `(179,89,37,255)`, Color Dodge `(214,139,63,255)`, Reflect `(214,120,42,255)`, Glow `(195,139,57,255)`, Overlay `(197,114,50,255)`. Undo restores both layers and the mode.
  - `imageSamplingSeesBlendMode`: `PixelSampler.sample(…, mode: .image)` (0012) on a Multiply stack returns the flattened pixel. `.layer` mode returns the top layer's raw pixel.
  - `paintbrushMultiplyStroke`: opaque gray `(128,128,128,255)` 32×32 layer, Paintbrush options `blendMode = .multiply`, color `(128,128,128,255)`, width 6, hardness 100, AA, and a dab at `(16.5,16.5)`. The center pixel is `(64,64,64,255)` (`F = mul255(128,128) = 64`, opaque over opaque). A fully outside pixel stays unchanged. Undo restores the original.
  - `paintBucketColorBurnFill`: 0017 fill on an opaque `(200,100,50,255)` 8×8 layer, color `(100,200,128,255)`, Color Burn, global fill → every pixel `(115,58,0,255)` (opaque over opaque = `F`: R = Burn(200,100) = `255 − (55·255)/100 = 255 − 140 = 115`; G = Burn(100,200) = `255 − (155·255)/200 = 255 − 197 = 58`; B = Burn(50,128) = `max(0, 255 − (205·255)/128) = max(0, 255 − 408) = 0`). Undo restores the original pixels.
  - `layerPropertiesBlendModeRoundTrip`: real `UndoBridge`; 0025's `LayerPropertiesDialogModel` for the top layer (its `apply` closure = `updateLiveState`), set `edited.blendMode = .glow`, `ok()` → `undoBridge.commit(item)` → history step "Layer Properties". `CPUCompositor` output changes to the Glow result. Undo → `.normal` and the Normal result. Redo → `.glow`.
- **UI tests — `PaintDotMacUITests/BlendModesUITests.swift`** (new):
  - `layerPropertiesListsModesAndAppliesMultiply`: launch with a generated 64×64 PNG fixture (`UITestFixtures.writePNG`). Layers > Add New Layer. Double-click `layerRow.1` to open Layer Properties. Its blend popup `layerProperties.blendMode` lists exactly `Normal, Multiply, Additive, Color Burn, Color Dodge, Reflect, Glow, Overlay` in that order. Choose Multiply, then OK. `historyList` gains a row "Layer Properties". Reopening the dialog shows Multiply. Cancel. ⌘Z, reopen → Normal.
  - `toolBlendPopupListsModesAndPersists`: press B → `toolOptions.blendMode` lists the same eight items. Choose "Color Burn", relaunch without `-UITestResetDefaults` → popup shows "Color Burn". Then reset defaults.
- **Performance:** no new NF target. `CPUCompositor` cost per pixel stays a switch plus integer math, and 0048 re-measures NF-2. No measure test here.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: no warnings, all tests (including the updated 0002/0009/0017/0023/0025 assertions) pass with none skipped, UI tests ran, and launch smoke passes.
- **Manual verification:**
  1. Open a photo, add a layer, and paint a gradient (black → white) on it. Cycle the layer through each new mode in Layer Properties. Multiply darkens (white looks transparent), Additive brightens (black looks transparent), Color Burn and Color Dodge give strong contrast, Reflect and Glow brighten highlights, and Overlay boosts contrast. The canvas updates without tile seams at 100 %, 33 %, and 400 % zoom on a Retina display.
  2. Flatten (⇧⌘F): the canvas does not change visibly at the moment of flattening (the CPU and Metal results agree).
  3. Optional: compare against Paint.NET 5 on Windows with the same two-layer image. Expect ±1 over an opaque background and differences up to 5 only on semi-transparent pixels (§Context fidelity bounds).

## Out of scope

- Difference, Negation, Lighten, Darken, Screen, Xor → 0027 (same pattern: add cases after `overlay`, `Channel` functions, pixel functions, `Blend.metal` functions, reference switch cases, goldens, and spot values).
- Hard Light, Soft Light, Color, Luminosity, Hue, Saturation (L-4, P1) → 0059.
- ORA `composite-op` mapping (`svg:multiply`, `svg:plus`, `svg:color-burn`, `svg:color-dodge`, `svg:overlay`, `paintdotmac:reflect`, `paintdotmac:glow`) → 0028 `OpenRasterBlendMap`.
- Layers panel, Layer Properties dialog, and the "Layer Properties" history step → 0025. Metal compositor architecture and dispatch → 0024.
- Paint.NET's tool-only "Overwrite" mode (not in v1.0, D-27).
