# 0032 — Add the Black and White, Hue / Saturation, Posterize, and Sepia adjustments

> Source: PRD.md §5.8 (ADJ-2 Black and White, ADJ-5 Hue / Saturation, ADJ-8 Posterize, ADJ-9 Sepia, and the shared rule "All adjustments (P0): apply to the active layer and selection, show a live canvas preview while the dialog is open, and support Cancel and 'Repeat last' (⌘F)"), §5.9 FX-A, FX-B, FX-C, FX-D, FX-E, §5.12 (Hue/Saturation ⇧⌘U; general rule Ctrl → ⌘, Mac system shortcuts win), §12 D-22; AGENTS.md architecture rules 2, 4, 5, 7, 8, 9.
> Paint.NET docs (fetched 2026-11-05; `getpaint.net/doc/latest/…` redirects to `paint.net/doc/latest/…`): https://paint.net/doc/latest/AdjustmentsMenu.html — Black and White: "This adjustment desaturates an image, removing all color information and rendering the image in grayscale … Black and White has no configurable options and does not display a dialog."; Hue / Saturation: controls **Hue**, **Saturation**, **Lightness** ("The initial value of the Lightness control is zero"; examples "Hue rotated to 157", "Saturation increased to 136", "Lightness value of -18"); Posterize: "limits the range from as few as 2 to a maximum of 64 possible values … The RGB color channels can be manipulated independently if the ☐ Linked checkbox is unchecked. If the ☑ Linked checkbox is checked … the controls are forced to use the same value."; Sepia: "rendering the image in black & white, and adding a sepia tone … Sepia has a single control which sets the intensity or strength of the effect." (Paint.NET 5; see *Open questions* 2). "If a selection is active when the adjustment is run, the effect will only be applied to the selected region." The docs list no shortcuts and no numeric defaults, so those come from Paint.NET's source (FX-E fallback).
> Paint.NET 3.36 source (last published source; mirror https://github.com/rivy/OpenPDN, identical to the `wangdeshui/paint.net` mirror 0031 cites): `src/Effects/DesaturateEffect.cs` (Black and White), `src/Effects/SepiaEffect.cs`, `src/Effects/PosterizeAdjustment.cs` (`PosterizePixelOp`), `src/Effects/HueAndSaturationAdjustment.cs`, `src/Core/UnaryPixelOps.cs` (`Desaturate`, `Level`, `BlendConstant`, `HueSaturationLightness`), `src/Core/ColorBgra.cs` (`GetIntensityByte`; indexer 0 = B, 1 = G, 2 = R), `src/Core/HsvColor.cs` (`ToRgb`), `src/Core/RgbColor.cs` (`ToHsv`), `src/Base/PropertySystem/LinkValuesBasedOnBooleanRule`2.cs`, `src/Menus/AdjustmentsMenu.cs` (`GetEffectShortcutKeys`), `src/Strings/Strings.resx` (names and labels). All formulas below are transcribed from these files.
> Milestone: M4
> Depends on: 0031-effect-framework-and-first-adjustments (and, through it, 0008 history/UndoBridge, 0013 selection, 0024 GoldenImage, 0025 sheets)

## Context

Spec 0031 builds the whole effect framework (not implemented yet; names below are the ones it fixes): `ImageEffect` (`id`, `name`, `category`, `parameters`, `shortcut: EffectShortcut?`, `historyIcon`, `alphaMode`, `inputPadding(for:)`, `makeOutput(input:values:context:)`), `EffectParameter` (`.integer(range:defaultValue:step:)`, `.bool(defaultValue:)`, …), `EffectParameterValues` (`integer(_:)`, `bool(_:)`, `setting(_:to:schema:)`, `normalized(for:)`), `EffectSchemaValidator`, `EffectRegistry.standard` ("0032–0034 … append here"; `adjustments` sorted by name), `EffectParameterMemory`, `EffectMaskBlend` (FX-D), `CoreImageBridge` (one Metal-backed `CIContext`, color management off, `.straight` input passes the 8-bit values untouched, `EffectRenderContext.colorKernel(_:)` / `kernel(_:)` from a name → kernel cache), `Core/Rendering/Shaders/EffectKernels.metal` (stitchable CI kernels named after the effect id), `EffectRunner` (chunked, cancellable, visible-first), `Document/EffectSessionController.swift` (preview via `updateLiveState`, one `TileDiffHistoryItem` named `effect.name` on OK, exact restore on Cancel, `update(_:to:)` debounced), `UI/EffectDialogView.swift` (generated from the schema; `effectDialog`, `effectDialog.<id>`, `effectDialog.<id>.field`, `effectDialog.progress` "rendering"/"idle", `effectDialog.ok`, `effectDialog.cancel`), `MainMenu` Adjustments menu built from the registry (`menu.adjustments.<id>`, key equivalent from `shortcut`), Effects ▸ Repeat ⌘F (`menu.effects.repeat`). Test support: `PaintDotMacTests/Effects/Reference/` oracles + `ReferenceEffectRenderer`, `GoldenImage.compare` (±1), `SeededRandom`, `TestImages`, `UITestApp`, `UITestFixtures.writePNG`, `-UITestSelectRect`. 0031's adjustments: Invert Colors (⇧⌘I) and Brightness / Contrast. 0031 open question 4 (applied there): per-pixel adjustments also transform the color under alpha 0; this spec follows it.

This spec adds the four remaining "simple" adjustments of PRD §5.8 as four `ImageEffect`s, plus two small framework additions they need: a shared **channel lookup table** kernel (Posterize and Sepia are per-channel 256-entry tables) and **linked parameters** (Posterize's "Linked" checkbox, Paint.NET's `LinkValuesBasedOnBooleanRule`).

**Paint.NET behavior mirrored (3.36 source, verified):**

| Adjustment | Class | Parameters (name, range, default) | Dialog | Paint.NET shortcut |
|---|---|---|---|---|
| Black and White | `DesaturateEffect` (`DesaturateEffect.Name` = "Black and White") | none | no | Ctrl+Shift+G |
| Hue / Saturation | `HueAndSaturationAdjustment` | **Hue** −180…180, 0; **Saturation** 0…200, 100; **Lightness** −100…100, 0 (`Int32Property`) | yes | Ctrl+Shift+U |
| Posterize | `PosterizeAdjustment` | **Red** 2…64, 16; **Green** 2…64, 16; **Blue** 2…64, 16; **Linked** checkbox, on | yes | Ctrl+Shift+P |
| Sepia | `SepiaEffect` | none (3.36) | no (3.36) | Ctrl+Shift+E |

All four keep alpha unchanged and operate on straight, sRGB-encoded 8-bit values (0031's `.straight` mode).

## User story

As a Paint.NET switcher, I press ⇧⌘G and my layer (or just my selection, with soft edges) turns gray as one "Black and White" step; ⇧⌘E gives it a warm sepia tone as one "Sepia" step. I press ⇧⌘U, drag Hue, Saturation, and Lightness and watch the canvas update live, then OK records one "Hue / Saturation" step. I open Adjustments ▸ Posterize…, and with "Linked" on, moving Red moves Green and Blue too; I uncheck Linked to set each channel separately. Cancel always restores the image exactly, ⌘Z undoes each step, and ⌘F repeats the last one.

## Scope & changes

Cross-cutting rules (from 0031, unchanged): every pixel change goes through `EffectSessionController` → `UndoBridge`; `Core` imports no AppKit/SwiftUI; GPU rendering through `CoreImageBridge`; one generated dialog; selection clipping by `EffectMaskBlend`; rendering off the main actor, cancellable, chunked.

### Core (pure, headless, unit-tested)

1. **`Core/Effects/ChannelLookupTable.swift`** (new) — a per-channel 8-bit lookup table and its GPU form. The only lookup-table type and kernel in the app: 0033 Levels / Auto-Level (`LevelsMapping.lut(for:) -> ChannelLookupTable`, rendered with `apply(to:context:)`) and 0034 Curves (RGB mode through `apply(to:context:)`; Luminosity mode passes `makeImage()` to its own `luminosityCurve` kernel) use it unchanged and add no parallel type.
   ```swift
   public struct ChannelLookupTable: Sendable, Equatable {
       public let red: [UInt8]     // exactly 256 entries each (precondition)
       public let green: [UInt8]
       public let blue: [UInt8]
       public init(red: [UInt8], green: [UInt8], blue: [UInt8])
       public static let identity: ChannelLookupTable            // [0…255] for each channel
       public var isIdentity: Bool
       public func apply(_ c: ColorRGBA8) -> ColorRGBA8          // (red[R], green[G], blue[B], A) — CPU convenience for tests and future CPU paths
       /// 256×1 RGBA8 image, pixel i = (red[i], green[i], blue[i], 255), `CIImage(bitmapData:…, format: .RGBA8, colorSpace: nil)` (color management off, 0031 item 6), `.samplingNearest()`.
       public func makeImage() -> CIImage
       /// Applies the table to `input` with the `channelLookup` kernel (item 6) over `context.ciRect(context.outputRect)`.
       public func apply(to input: CIImage, context: EffectRenderContext) throws -> CIImage
   }
   ```
   `apply(to:context:)`: `try context.kernel("channelLookup").apply(extent: context.ciRect(context.outputRect), roiCallback: { index, rect in index == 0 ? rect : CGRect(x: 0, y: 0, width: 256, height: 1) }, arguments: [input, makeImage()])`; a nil result → `EffectError.renderFailed`.

2. **`Core/Effects/EffectParameter.swift`** (extend 0031) — linked parameters, data-driven (AGENTS rule 5: no per-effect dialog code).
   ```swift
   public enum EffectParameterRule: Sendable, Equatable {
       /// Paint.NET `LinkValuesBasedOnBooleanRule` (inverse = false): while the bool `source` is true, every id in `targets` holds the same value.
       case linkIntegers(targets: [String], source: String)
   }
   ```
   - `ImageEffect` gains `var parameterRules: [EffectParameterRule] { get }` with a protocol-extension default `[]` (0031's effects need no change).
   - **`EffectSchemaValidator.problems(in:)`** (extend): a rule must have ≥ 2 distinct targets, every target must exist and be `.integer` with identical range and step, `source` must exist, be `.bool`, and not be a target; a target may appear in only one rule. Each violation is one problem string.

3. **`Core/Effects/EffectParameterEditor.swift`** (new) — the single place where a parameter edit is normalized and rules are applied (the dialog and the session controller never do it themselves).
   ```swift
   public struct EffectParameterEditor: Sendable, Equatable {
       public init(schema: [EffectParameter], rules: [EffectParameterRule], values: EffectParameterValues)
       public private(set) var values: EffectParameterValues
       public mutating func set(_ id: String, to value: EffectParameterValue)   // returns nothing; `values` reflects the edit
   }
   ```
   Semantics, transcribed from `LinkValuesBasedOnBooleanRule.Sync`:
   - `init`: `values = values.normalized(for: schema)`; each rule keeps a private `lastChanged` target id, initially `targets[0]`; then **sync** every rule.
   - `set(id, value)`: `values = values.setting(id, to: value, schema: schema)` (0031 normalization: clamp + snap). If `id` is a target of a rule: that rule's `lastChanged = id`, then sync it. If `id` is a rule's `source`: sync that rule.
   - **sync(rule):** if `values.bool(source)` is true, set every target to `values.integer(lastChanged)` (already normalized; identical ranges are guaranteed by the validator). If false, nothing changes (the values keep whatever they were).
   - **0031 change:** `EffectSessionController.update(_:to:)` uses an `EffectParameterEditor` built from `effect.parameters` and `effect.parameterRules` instead of calling `setting` directly; "if changed" compares the editor's whole `values` before and after. `EffectSessionController.values` returns `editor.values`, so the dialog (which renders the controller's values) shows linked sliders moving together. `EffectParameterMemory.initialValues` results are passed through an editor's `init` before the session starts (so remembered or default values are always rule-consistent).

4. **`Core/Effects/Adjustments/BlackAndWhite.swift`** (new) — `public struct BlackAndWhite: ImageEffect`: `id "blackAndWhite"`, `name "Black and White"`, `.adjustment`, no parameters (no dialog, `menuTitle == "Black and White"`), `shortcut EffectShortcut(key: "g", modifiers: [.command, .shift])` (*Open questions* 1), `alphaMode .straight`, `inputPadding 0`. `makeOutput` applies `context.colorKernel("blackAndWhite")` with `[input]` over `context.ciRect(context.outputRect)`.
   **Formula (`UnaryPixelOps.Desaturate` + `ColorBgra.GetIntensityByte`):**
   ```
   I = (7471·B + 38470·G + 19595·R) >> 16          // weights sum to 65,536; truncating
   out = (I, I, I, A)
   ```
   Public helper `public static func intensity(r: UInt8, g: UInt8, b: UInt8) -> UInt8` (the same formula) — used by `Sepia` and `HueSaturation` documentation and tests; the GPU kernels inline the same integer expression.

5. **`Core/Effects/Adjustments/Sepia.swift`** (new) — `public struct Sepia: ImageEffect`: `id "sepia"`, `name "Sepia"`, `.adjustment`, no parameters (no dialog; *Open questions* 2), `shortcut EffectShortcut(key: "e", modifiers: [.command, .shift])` (*Open questions* 1), `.straight`.
   **Formula (`SepiaEffect` = `Desaturate` then `Level(in 0…255, gamma {1.2f, 1.0f, 0.8f} in B,G,R order, out 0…255)`):** with `I` from item 4,
   ```
   out = (curveR[I], I, curveB[I], A)
   curve(j, gamma): j ≥ 255 → 255; else trunc(clamp(255 · pow(Double(Float(j) / Float(255)), Double(gamma)), 0, 255))
   curveR uses gamma = Float(0.8), curveB uses gamma = Float(1.2)      // Float literals widened to Double, as C# does
   ```
   (`Level.Apply(float r, float g, float b)` computes `v / (inHigh − inLow)` in `float`, then `Math.Pow` in `double` with the `float` gamma, multiplies by 255 in `double`, and the `(byte)` cast truncates. `j = 0` → 0.) Green is the identity because its gamma is 1.0.
   - `public static let table: ChannelLookupTable` — computed once with the formula above: `red = curveR`, `green = identity`, `blue = curveB`.
   - `makeOutput`: `gray = blackAndWhite color kernel applied to input` (item 4's kernel), then `Sepia.table.apply(to: gray, context:)`.

6. **`Core/Effects/Adjustments/Posterize.swift`** (new) — `public struct Posterize: ImageEffect`: `id "posterize"`, `name "Posterize"`, `.adjustment`, `.straight`, `shortcut EffectShortcut(key: "p", modifiers: [.command, .shift])` (*Open questions* 1), parameters in this order:
   `.init(id: "red", label: "Red", kind: .integer(range: 2...64, defaultValue: 16))`, `.init(id: "green", label: "Green", kind: .integer(range: 2...64, defaultValue: 16))`, `.init(id: "blue", label: "Blue", kind: .integer(range: 2...64, defaultValue: 16))`, `.init(id: "linked", label: "Linked", kind: .bool(defaultValue: true))`; `parameterRules = [.linkIntegers(targets: ["red", "green", "blue"], source: "linked")]`. `menuTitle == "Posterize…"`.
   **Formula (`PosterizePixelOp.CalcLevels`, per channel with `n` levels):**
   ```
   t1[0] = 0;  t1[i] = (255·i) / (n − 1)  for 1 ≤ i < n            // integer division
   j = 0; k = 0
   for i in 0…255 { levels[i] = t1[j]; k += n; if k > 255 { k −= 255; j += 1 } }
   out = (levelsR[R], levelsG[G], levelsB[B], A)
   ```
   Closed form (equivalent for every `n` in 2…64 and every input, proven by a test): `levels[c] = (255 · ((c·n − 1) / 255)) / (n − 1)` with C-style truncating division (`c = 0` → `(−1)/255 = 0`).
   - `public static func levels(count n: Int) -> [UInt8]` — the closed form (production code); the test oracle uses the loop above.
   - `public static func table(for values: EffectParameterValues) -> ChannelLookupTable` — `levels(count: red)`, `levels(count: green)`, `levels(count: blue)`.
   - `makeOutput`: `Posterize.table(for: values).apply(to: input, context:)`.
   - The "Linked" value itself has no effect on the pixels; it only drives the rule (item 3).

7. **`Core/Effects/Adjustments/HueSaturation.swift`** (new) — `public struct HueSaturation: ImageEffect`: `id "hueSaturation"`, `name "Hue / Saturation"`, `.adjustment`, `.straight`, `shortcut EffectShortcut(key: "u", modifiers: [.command, .shift])` (PRD §5.12), parameters `.init(id: "hue", label: "Hue", kind: .integer(range: -180...180, defaultValue: 0))`, `.init(id: "saturation", label: "Saturation", kind: .integer(range: 0...200, defaultValue: 100))`, `.init(id: "lightness", label: "Lightness", kind: .integer(range: -100...100, defaultValue: 0))`. `menuTitle == "Hue / Saturation…"`.
   ```swift
   public struct KernelArguments: Sendable, Equatable { public let hueDelta: Int; public let satFactor: Int; public let blendAlpha: Int; public let blendTarget: Int }
   public static func kernelArguments(hue: Int, saturation: Int, lightness: Int) -> KernelArguments?   // nil = identity
   ```
   **Parameter mapping (`HueAndSaturationAdjustment.OnSetRenderInfo` + `HueSaturationLightness` constructor):**
   ```
   if hue == 0 && saturation == 100 && lightness == 0 → nil (identity: output = input, no quantization)
   satMapped = saturation > 100 ? (saturation − 100)·3 + 100 : saturation      // 101…200 → 103…400
   satFactor = (satMapped · 1024) / 100                                          // integer division
   lightness > 0 → blendAlpha = (lightness·255)/100, blendTarget = 255
   lightness < 0 → blendAlpha = (−lightness·255)/100, blendTarget = 0
   lightness == 0 → blendAlpha = 0, blendTarget = 0
   ```
   `makeOutput`: `nil` → return `input` unchanged; else `context.colorKernel("hueSaturation")` with `[input, Float(hueDelta), Float(satFactor), Float(blendAlpha), Float(blendTarget)]`.
   **Per-pixel formula (`HueSaturationLightness.Apply`), in the integer-exact form this spec ships** (`floorDiv` = floor division, `/` on non-negative operands = integer division):
   ```
   I = (7471·B + 38470·G + 19595·R) >> 16
   for each c in R,G,B: c1 = clamp(floorDiv(I·1024 + (c − I)·satFactor, 1024), 0, 255)          // C# ">> 10" on Int32 = floor
   // RgbColor.ToHsv with integer results (H 0…359, S 0…100, V 0…100):
   M = max(r1,g1,b1); m = min(r1,g1,b1); D = M − m
   V = (100·M) / 255
   if M == 0 || D == 0 { S = 0; H = 0 } else {
       S = (100·D) / M
       num = (r1 == M) ? 60·(g1 − b1) : (g1 == M) ? 120·D + 60·(b1 − r1) : 240·D + 60·(r1 − g1)   // r1 tested first, then g1
       H = floorDiv(num, D); if H < 0 { H += 360 }
   }
   H += hueDelta; while H < 0 { H += 360 }; while H > 360 { H −= 360 }                         // H may be 360
   // HsvColor.ToRgb with integer results:
   h = H % 360; sector = h / 60; f = h % 60
   v = (255·V)/100; p = (255·V·(100 − S))/10000
   q = (255·V·(6000 − S·f))/600000; t = (255·V·(6000 − S·(60 − f)))/600000
   (r2,g2,b2) = sector 0:(v,t,p) 1:(q,v,p) 2:(p,v,t) 3:(p,q,v) 4:(t,p,v) 5:(v,p,q)                 // S == 0 gives p = q = t = v
   // BlendConstant toward white/black (only when blendAlpha > 0):
   c3 = (c2·(255 − blendAlpha) + blendTarget·blendAlpha) / 256                                  // "/ 256" is Paint.NET's (so Lightness +100 gives 254)
   out = (r3, g3, b3, A)
   ```
   All intermediates fit in `Int32` (largest: 255·100·6000 = 153,000,000). **Why integer-exact instead of Paint.NET's `double`:** `RgbColor.ToHsv`/`HsvColor.ToRgb` truncate `double` results such as `(int)(s * 100)` where the exact value is an integer but the `double` is just below it (for example RGB (5,5,50): exact S = 90, `double` gives 89). Metal has no `double`, so the GPU can't reproduce those artifacts, and a ±1 golden would fail. The integer form computes the exact rational floor everywhere. Measured over all 2²⁴ colors for 20 parameter sets, it differs from the literal 3.36 `double` transcription by at most 6 per channel on at most 0.47% of colors, and is identical on most colors (*Open questions* 3). The integer-percent HSV quantization itself (S and V in whole percent) is Paint.NET's and is kept, so a non-identity setting can shift a gray by one level: (128,128,128) with Hue 77 / Saturation 180 → (127,127,127).

8. **`Core/Effects/EffectRegistry.swift`** (extend): `standard` = `[InvertColors(), BrightnessContrast(), BlackAndWhite(), HueSaturation(), Posterize(), Sepia()]`. `adjustments.map(\.name)` = `["Black and White", "Brightness / Contrast", "Hue / Saturation", "Invert Colors", "Posterize", "Sepia"]` (Paint.NET's alphabetical menu).

9. **`Core/Rendering/Shaders/EffectKernels.metal`** (extend 0031) — three new kernels, named as `CoreImageBridge` looks them up. The bridge's kernel name list (0031 item 6/7) gains `blackAndWhite`, `hueSaturation` (color kernels) and `channelLookup` (general kernel):
   - `[[stitchable]] float4 blackAndWhite(coreimage::sample_t s)` — `int r = int(rint(s.r·255))` (same for g, b), `int i = (7471·b + 38470·g + 19595·r) >> 16` (operands non-negative, so the shift is exact), returns `float4(float(i)/255, float(i)/255, float(i)/255, s.a)`.
   - `[[stitchable]] float4 hueSaturation(coreimage::sample_t s, float hueDelta, float satFactor, float blendAlpha, float blendTarget)` — converts the arguments with `int(rint(x))`, runs item 7's integer formula verbatim. `floorDiv(a, b)` for `b > 0` is written explicitly as `a >= 0 ? a / b : -((-a + b - 1) / b)` (never rely on `>>` of a negative `int`, nor on `/` rounding toward zero for negatives). Returns `float4(float(r3)/255, …, s.a)`.
   - `[[stitchable]] float4 channelLookup(coreimage::sampler src, coreimage::sampler lut, coreimage::destination dest)` — `float4 s = src.sample(src.transform(dest.coord()))`; `int r = clamp(int(rint(s.r·255)), 0, 255)` (g, b likewise); `out.r = lut.sample(lut.transform(float2(float(r) + 0.5, 0.5))).r`, `out.g = … (g) … .g`, `out.b = … (b) … .b`, `out.a = s.a`.
   - The kernels change nothing about 0031's color-space setup: input bytes reach the kernel as `k/255` and `rint(x·255)` recovers `k` exactly.

### Platform glue (covered by integration and UI tests)

10. **`App/MainMenu.swift`** — no code change: all four adjustments run through 0031's `DocumentWindowController.runEffect(_:)` / `repeatLastEffect(_:)` (guards: no gesture in progress, `!undoBridge.isBusy`, no sheet attached; then `undoBridge.prepareForNavigation?()` with reason `.command` before anything else), so there is no new command path. The Adjustments menu is built from the registry, so it now lists, in order, "Black and White ⇧⌘G", "Brightness / Contrast…", "Hue / Saturation… ⇧⌘U", "Invert Colors ⇧⌘I", "Posterize… ⇧⌘P", "Sepia ⇧⌘E" with identifiers `menu.adjustments.blackAndWhite`, `….hueSaturation`, `….posterize`, `….sepia`. 0031's `MainMenuEffectsTests.adjustmentsItems` and `EffectRegistryTests.standardContents`/`adjustmentsSortedByName` are updated to the new lists (item 8). `MainMenuTests.noDuplicateShortcuts` must still pass: ⇧⌘G, ⇧⌘E, ⇧⌘P and ⇧⌘U are not used elsewhere in the menu tree (⌘E Merge Layer Down, ⌘G/⌘P unused, ⇧⌘C Copy Merged). ⇧⌘G is also macOS's "Go to Folder" inside open/save panels; those panels are key windows and handle it before the main menu, and 0031 disables effect items while a sheet is attached, so the save-panel helpers (0005, 0030) keep working — proven by `BasicAdjustmentsUITests.testGoToFolderStillWorksInSavePanel`.

11. **`UI/EffectDialogView.swift`** — no per-effect code. The only change: the dialog binds to `EffectSessionController.values`, which now comes from the editor (item 3), so when Red changes with Linked on, the Green and Blue sliders and fields update in the same pass. The `.bool` row shows a checkbox titled "Linked" (`effectDialog.linked`).

12. **`project.yml`:** no change (new files are picked up by the existing globs; `MTLLINKER_FLAGS` is already set by 0031). Run `xcodegen generate`.

No PRD change in this spec; the open questions below record the product decisions applied.

## Acceptance criteria

- [ ] ADJ-2: Black and White (no dialog, ⇧⌘G, menu "Black and White") maps `(R,G,B,A) → (I,I,I,A)` with Paint.NET's `GetIntensityByte`, as one "Black and White" step; undo/redo exact. → `BlackAndWhiteTests.*`, `BasicAdjustmentGoldenTests.blackAndWhite*`, `BasicAdjustmentsIntegrationTests.blackAndWhiteStepUndoRedo`, `BasicAdjustmentsUITests.testBlackAndWhiteShortcutAndUndo`
- [ ] ADJ-9: Sepia (no dialog, ⇧⌘E, menu "Sepia") = desaturate then the gamma 0.8 / 1.0 / 1.2 curves on R / G / B, as one "Sepia" step; undo/redo exact. → `SepiaTests.*`, `BasicAdjustmentGoldenTests.sepia*`, `BasicAdjustmentsIntegrationTests.sepiaStepUndoRedo`, `BasicAdjustmentsUITests.testSepiaShortcutAndRepeat`
- [ ] ADJ-8: Posterize has Red, Green, Blue (2…64, default 16) and Linked (default on); Linked keeps the three equal, unchecked lets them differ; output matches `PosterizePixelOp` exactly. → `PosterizeTests.*`, `EffectParameterEditorTests.*`, `BasicAdjustmentGoldenTests.posterize*`, `BasicAdjustmentsUITests.testPosterizeLinkedAndUnlinked`
- [ ] ADJ-5: Hue / Saturation has Hue (−180…180, 0), Saturation (0…200, 100), Lightness (−100…100, 0), ⇧⌘U; defaults are the identity (no step on OK); output equals the integer-exact formula on the GPU (±1, expected 0) and stays within the stated bound of the literal 3.36 `double` transcription. → `HueSaturationTests.*`, `HueSaturationReferenceTests.*`, `BasicAdjustmentGoldenTests.hueSaturation*`, `BasicAdjustmentsUITests.testHueSaturationDialog`
- [ ] FX-B: every new adjustment runs on the GPU through `CoreImageBridge` and has a CPU oracle in `PaintDotMacTests/Effects/Reference/`; goldens match within ±1. → `BasicAdjustmentGoldenTests.*`, `CoreImageBridgeTests.kernelsLoad`
- [ ] FX-D: with an antialiased selection, only selected pixels change, blended by coverage; pixels outside are byte-identical. → `BasicAdjustmentsIntegrationTests.selectionClipped*`, `BasicAdjustmentGoldenTests.selectionBlendSepia`, `BasicAdjustmentsUITests.testBlackAndWhiteRespectsSelection`
- [ ] §5.8: live preview without a step, Cancel restores exactly, OK commits one step named after the adjustment, ⌘F repeats with the same values and no dialog. → `BasicAdjustmentsIntegrationTests.*`, `BasicAdjustmentsUITests.*`
- [ ] Alpha is never changed by any of the four; color under alpha 0 is transformed like any other color. → `*Tests.alphaUntouched`, golden fixtures with alpha {0, 1, 77, 128, 254, 255}
- [ ] Linked parameters are declared as data (`EffectParameterRule`), validated, and applied in one Core type used by the session controller. → `EffectSchemaValidatorTests.linkRuleProblems`, `EffectParameterEditorTests.*`
- [ ] Adjustments menu lists the six adjustments alphabetically with the shortcuts above; no duplicate shortcuts; ⇧⌘G still opens "Go to Folder" in save panels. → `MainMenuEffectsTests.adjustmentsItems`, `MainMenuTests.noDuplicateShortcuts`, `BasicAdjustmentsUITests.testMenus`, `.testGoToFolderStillWorksInSavePanel`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Identity settings:** Hue / Saturation 0/100/0 returns the input (no HSV round trip) → OK adds no step (H-6) but sets Repeat's `lastApplied` (0031). Posterize can't be identity (max 64 levels), but posterizing an already posterized image with the same idempotent level count (e.g. 16) is a no-op → no step. Black and White on a gray image → no step. → `BasicAdjustmentsIntegrationTests.identityAddsNoStep`, `.posterizeTwiceNoStep`
- **Extremes:** Posterize 2 (values 0/255, threshold at 128), 64; Hue ±180 (same result for +180 and −180), Saturation 0 (gray via quantized V), 101 (maps to 103), 200 (maps to 400, clamps), Lightness ±100 (white/black targets reach 254 / 0 — Paint.NET's `/256`). → `HueSaturationReferenceTests.*`, `PosterizeTests.*`
- **Gray, black, and white pixels** through Hue / Saturation: `D == 0` → S = 0, H = 0, no division by zero; black `M == 0`. → `HueSaturationReferenceTests.graysAndBlack`
- **Negative intermediates:** `(c − I)·satFactor` and `num` can be negative; floor division is explicit on both CPU and GPU. → `HueSaturationReferenceTests.negativeFloorDivision`, golden with saturation 0…200
- **Transparent pixels / unallocated tiles:** read as (0,0,0,0); Black and White, Posterize, and Hue / Saturation map (0,0,0,0) to (0,0,0,0) (Lightness > 0 maps it to (k,k,k,0) and allocates the tile, as 0031 OQ 4); Sepia maps black to black. → `BasicAdjustmentsIntegrationTests.sparseLayerStaysSparse`, `.lightnessAllocatesTransparent`
- **Edge tiles** (257×257, 300×200) and 1×1 images: the runner's invariants hold; the LUT kernel never reads outside the 256×1 table (indices clamped). → golden fixtures 600×400 and 257×257
- **Linked edge cases:** turning Linked on copies the most recently edited channel (initially Red) to the others; typing an out-of-range value (e.g. 99) with Linked on gives 64 everywhere; turning Linked off keeps the current values. Remembered values from an earlier OK are rule-consistent on reopen. → `EffectParameterEditorTests.*`
- **Hidden active layer, floating pixels, busy document, cancellation, GPU failure:** inherited from 0031 unchanged (no new code path).
- **⇧⌘G in save/open panels** keeps meaning "Go to Folder"; while a sheet is attached the effect items are disabled. → `testGoToFolderStillWorksInSavePanel`

## Test plan

Expected values come from the Paint.NET 3.36 formulas transcribed above and hand calculation (shown), never from running the code under test.

- **CPU oracles** (`PaintDotMacTests/Effects/Reference/`), each a straightforward, independent transcription:
  - `BlackAndWhiteReference.apply(_ pixels: [ColorRGBA8]) -> [ColorRGBA8]` — `GetIntensityByte` per pixel.
  - `SepiaReference.apply(_:)` — literal `UnaryPixelOps.Level` transcription: a `Level` struct with `inLow/inHigh/outLow/outHigh` per channel in B,G,R index order, `gamma: [Float] = [1.2, 1.0, 0.8]`, the three-branch `Apply(float r, float g, float b)` (`v < 0`, `v + inLow ≥ inHigh`, `pow` branch with `Float` division and `Double` pow), lookup tables built by `UpdateLookupTable` for `j` in 0…255, applied after `BlackAndWhiteReference`.
  - `PosterizeReference.apply(_:red:green:blue:)` — the `CalcLevels` loop (with `k`/`j`), not the closed form.
  - `HueSaturationReference.exact(_:hue:saturation:lightness:)` — item 7's integer formula written plainly in Swift (`Int`, explicit floor division, the `switch` on sector), including the identity short-circuit and the saturation mapping; this is the golden oracle for the GPU.
  - `HueSaturationReference.paintDotNet336(_:hue:saturation:lightness:)` — the literal 3.36 transcription with `Double` (`RgbColor.ToHsv`: `Double(R)/255` …, `h *= 60`, `if h < 0 { h += 360 }`, `Int(h)`, `Int(s*100)`, `Int(v*100)`; `HsvColor.ToRgb`: `Double(Hue % 360)`, `sectorPos = h/60`, `floor`, `fractionalSector`, `Int(r*255)`; `>> 10` on `Int32`; `BlendConstant` `/ 256`). Used only to bound the integer form's deviation.
  - `ReferenceEffectRenderer` (0031) gains cases for the four oracles so runner/session tests can run without the GPU.
- **Unit — `PaintDotMacTests/Effects/BlackAndWhiteTests.swift`:** metadata (id "blackAndWhite", name "Black and White", `.adjustment`, no parameters, `hasDialog == false`, `menuTitle == "Black and White"`, shortcut `g` + [.command, .shift], icon `.adjustment`, `inputPadding == 0`); oracle spot values by hand: (255,0,0,255) → 19,595·255 = 4,996,725 >> 16 = **76**; (0,255,0) → 9,809,850 >> 16 = **149**; (0,0,255) → 1,905,105 >> 16 = **29**; (255,255,255) → 65,536·255 >> 16 = **255**; (200,100,50) → 3,919,000 + 3,847,000 + 373,550 = 8,139,550 >> 16 = **124**; (100,150,200) → **140**; (10,20,30) → **18**; `alphaUntouched` ((200,100,50,77) → (124,124,124,77); (0,0,0,0) → (0,0,0,0)); `grayIsFixedPoint` (for all v in 0…255, (v,v,v) → v, because the weights sum to 65,536).
- **Unit — `PaintDotMacTests/Effects/SepiaTests.swift`:** metadata (id "sepia", name "Sepia", no parameters, shortcut `e` + [.command, .shift]); `tableMatchesReferenceLevel` (`Sepia.table` == the oracle's `Level` tables for all 256 entries; green is identity); hand spot values of the curves: `j = 124` → R = trunc(255·0.486275^0.8) = trunc(255·0.56167) = **143**, B = trunc(255·0.486275^1.2) = trunc(255·0.42097) = **107**; `j = 0` → (0, 0); `j = 255` → (255, 255); `j = 128` → (146, 111); `j = 1` → (3, 0); `j = 254` → (254, 253); full-pixel values (200,100,50,255) → (**143,124,107**,255), (255,0,0) → (96,76,59), (0,255,0) → (165,149,133), (0,0,255) → (44,29,18), (128,128,128) → (146,128,111); `alphaUntouched`; `rIsAtLeastGIsAtLeastB` (for all j: curveR[j] ≥ j ≥ curveB[j]).
- **Unit — `PaintDotMacTests/Effects/PosterizeTests.swift`:** metadata (id, name "Posterize", `menuTitle == "Posterize…"`, shortcut `p` + [.command, .shift], parameters `red`/`green`/`blue` labels "Red"/"Green"/"Blue" range 2…64 default 16 step 1, `linked` label "Linked" default true, `parameterRules == [.linkIntegers(targets: ["red","green","blue"], source: "linked")]`); `closedFormEqualsLoop` (for every n in 2…64 and c in 0…255, `Posterize.levels(count:)` == the oracle's loop); hand values n = 16: c = 200 → j = (3200 − 1)/255 = 12 → 255·12/15 = **204**; c = 100 → j = 6 → **102**; c = 50 → j = 3 → **51**; c = 15 → 0, c = 16 → **17**, c = 239 → 238, c = 240 → **255**; n = 2: c = 127 → 0, c = 128 → **255**; n = 3: breakpoints 86 → 127 and 171 → 255; n = 64: c = 252 → 255, c = 251 → 250; `everyCountHasExactlyNLevels` (distinct outputs == n, `levels[0] == 0`, `levels[255] == 255`, monotonic non-decreasing); `tableForUnlinkedValues` (red 2, green 16, blue 64 → each channel uses its own count); `alphaUntouched`.
- **Unit — `PaintDotMacTests/Effects/HueSaturationTests.swift`:** metadata (id "hueSaturation", name "Hue / Saturation", `menuTitle == "Hue / Saturation…"`, shortcut `u` + [.command, .shift], parameters hue −180…180/0, saturation 0…200/100, lightness −100…100/0, labels "Hue", "Saturation", "Lightness"); `kernelArguments`: (0,100,0) → nil; (0,50,0) → satFactor 512; (0,100,1) → non-nil, satFactor 1024, blendAlpha 2 (255/100), target 255; (0,101,0) → satMapped 103 → satFactor 1054 (105,472/100); (0,200,0) → 400 → 4096; (0,0,0) → 0; lightness 100 → alpha 255 target 255; −100 → 255 target 0; −18 → 45 (4,590/100) target 0; (30,100,0) → hueDelta 30.
- **Unit — `PaintDotMacTests/Effects/HueSaturationReferenceTests.swift`** (validates the oracles against hand math): (255,0,0) hue +120 → H 0 + 120 = 120, sector 2, (p, v, t) = (0, 255, 0) → **(0,255,0)**; hue −120 → 240 → **(0,0,255)**; (200,100,50) hue 45: satFactor 1024 leaves the color; M 200, m 50, D 150 → V = 20,000/255 = 78, S = 15,000/200 = 75, H = 60·50/150 = 20 → 65 → sector 1, f = 5: v = 19,890/100 = 198, p = 497,250/10,000 = 49, q = 255·78·5,625/600,000 = 186 → **(186,198,49)**; (200,100,50) saturation 0 → I = 124 → V = 12,400/255 = 48 → 12,240/100 = **(122,122,122)** (quantization); saturation 50 → **(160,111,86)**; saturation 200 → **(255,25,0)**; (255,255,255) lightness 100 → (0·0 + 255·255)/256 = **254** each; (0,0,0) lightness 50 → alpha 127 → 32,385/256 = **126**; (100,150,200) lightness −50 → **(49,74,99)**; (100,150,200) (90,120,20) → **(237,112,237)**; (128,128,128) (77,180,0) → **(127,127,127)**; `graysAndBlack` ((0,0,0), (255,255,255), (77,77,77) with hue 90 → S 0, H 0, no trap); `negativeFloorDivision` ((0,0,255) saturation 50: I = 29, B = (29,696 + 226·512)/1024 = 142, R = G = (29,696 − 29·512)/1024 = 14 (14.5 floored) → M 142, D 128 → V = 14,200/255 = 55, S = 12,800/142 = 90, H = 240 → v = 140, p = 255·55·10/10,000 = 14 → **(14,14,140)**; saturation 150 (satFactor 2,560): R = floor(−44,544/1024) = −44 → clamped 0; hue floor with `num < 0`: (255,0,10) hue +3: num = 60·(0 − 10) = −600, D = 255 → floor(−2.35) = −3 → H = 357 + 3 = 360 → h = 0, f = 0 → t = 0 → **(255,0,0)**; truncation would give H = 358 + 3 = 361 → 1 → t = 25,500·100/600,000 = 4 → (255,4,0), so this case proves the floor); `plusAndMinus180Agree` (hue +180 and −180 give identical output for 4,096 grid colors); every hand value above also holds for `paintDotNet336` except where noted (all listed values agree).
  - `integerFormStaysCloseToPaintDotNet336` (property): colors = the 16³ grid `stride(0, through: 255, by: 17)` plus 100,000 `SeededRandom` colors (seed printed), parameter sets = the 20 listed below plus 10 seeded random (hue, saturation, lightness); assert per channel `|exact − paintDotNet336| ≤ 8` and the fraction of colors with a difference > 1 is ≤ 1% per parameter set; report the measured maxima in the test log. (Bound measured during spec research over all 2²⁴ colors: max 6, fraction ≤ 0.47%.) Parameter sets: (30,100,0), (0,50,0), (0,150,0), (−90,50,−40), (180,200,60), (1,100,0), (0,0,0), (0,100,100), (0,100,−100), (180,100,0), (−180,100,0), (0,1,0), (0,101,0), (0,200,0), (90,100,0), (115,149,1), (−15,38,1), (94,24,−7), (105,34,−26), (34,36,38).
- **Unit — `PaintDotMacTests/Effects/ChannelLookupTableTests.swift`:** `identityIsIdentity`; `applyMapsChannelsIndependently` (red = reversed, green = identity, blue = all 7 → (10,20,30,40) → (245,20,7,40)); `makeImageIs256x1` (extent (0,0,256,1); rendering it back through `CoreImageBridge` yields the table bytes exactly); `precondition` on wrong length is documented (not tested by crashing).
- **Unit — `PaintDotMacTests/Effects/EffectParameterEditorTests.swift`** (Posterize schema + rules): `initSyncsToFirstTarget` (values red 5, green 9, blue 30, linked true → all 5); `initUnlinkedKeepsValues` (linked false → 5/9/30); `linkedEditMovesAll` (set green 40 → 40/40/40); `unlinkedEditMovesOne` (linked false; set blue 2 → 16/16/2); `turningLinkOnUsesLastChanged` (linked false, set green 7, set blue 50, set linked true → 50/50/50); `turningLinkOnBeforeAnyEditUsesRed` (unlinked init 5/9/30, set linked true → 5/5/5); `outOfRangeClampsThenLinks` (set red 99 → 64 everywhere; set red 1 → 2 everywhere); `turningLinkOffKeepsValues`; `noRulesBehavesLikeSetting` (Brightness / Contrast schema: editor result == `values.setting(...)`).
- **Unit — `PaintDotMacTests/Effects/EffectSchemaValidatorTests.swift`** (extend 0031): `linkRuleProblems` — stub effects with: one target; unknown target; non-integer target; mismatched ranges; missing source; non-bool source; source listed as a target; a target in two rules → one problem each; `standardRegistryIsValid` still passes with the six effects.
- **Unit — `PaintDotMacTests/Effects/EffectRegistryTests.swift`** (update 0031's): `standardContents` (ids `["invertColors","brightnessContrast","blackAndWhite","hueSaturation","posterize","sepia"]`); `adjustmentsSortedByName` (the list in item 8). 0033 and 0034 update both again.
- **Unit — `PaintDotMacTests/App/MainMenuEffectsTests.swift`** (update 0031's `adjustmentsItems`): exactly `[("Black and White","g",[.command,.shift],"blackAndWhite"), ("Brightness / Contrast…","",[],"brightnessContrast"), ("Hue / Saturation…","u",[.command,.shift],"hueSaturation"), ("Invert Colors","i",[.command,.shift],"invertColors"), ("Posterize…","p",[.command,.shift],"posterize"), ("Sepia","e",[.command,.shift],"sepia")]`, action `runEffect:`, identifiers `menu.adjustments.<id>`; `MainMenuTests.noDuplicateShortcuts` passes. 0033 and 0034 update this exact list again.
- **GPU — `PaintDotMacTests/Rendering/CoreImageBridgeTests.swift`** (extend): `kernelsLoad` also finds `blackAndWhite`, `hueSaturation`, `channelLookup`; `channelLookupExact` (a 256×1 ramp image R = G = B = x with a table red = reversed, green = identity, blue = `x/2` → output bytes equal the table lookups exactly, alpha preserved, for both alpha 255 and alpha 0 rows).
- **Golden — `PaintDotMacTests/Effects/BasicAdjustmentGoldenTests.swift`** (GPU through `CoreImageBridge` + `EffectRunner` vs oracle with `GoldenImage.compare`, tolerance ±1, expected 0 differences, reported). Fixtures generated in the test: (a) 600×400 seeded random straight RGBA (alpha drawn from {0, 1, 77, 128, 254, 255}, colors uniform), spanning 3×2 tiles; (b) "color plane" 1536×256: tile k (k = 0…5) holds every (R, G) pair with B ∈ {0, 1, 127, 128, 254, 255}, alpha 255; (c) 257×257 random (edge tiles). Tests: `blackAndWhiteRandom`, `blackAndWhiteColorPlane`, `sepiaRandom`, `sepiaColorPlane`, `posterizeGrid` (n ∈ {(16,16,16), (2,2,2), (64,64,64), (2,16,64), (3,17,63)} on (a) and (b)), `hueSaturationGrid` (the 20 parameter sets above on (a) and (b)), `hueSaturationRandom` (15 seeded parameter sets on (a), seed printed), `edgeTiles` (each adjustment on (c)), `selectionBlendSepia` (antialiased ellipse `Selection(path:)` over (a), Sepia via runner vs `SepiaReference` + 0031's `MaskBlendReference`), `identityReturnsInput` (Hue / Saturation defaults → output bytes == input bytes). No PNG goldens are recorded: the oracle is the golden.
- **Integration — `PaintDotMacTests/Document/BasicAdjustmentsIntegrationTests.swift`** (`@MainActor`, real `UndoBridge`, 600×400 two-layer document with random pixels on the active layer 1, `debounce: .zero`, renderer = `CoreImageBridge`):
  - `blackAndWhiteStepUndoRedo`, `sepiaStepUndoRedo`: no-dialog run (`start()` + `ok()`) → exactly one new step named "Black and White" / "Sepia", icon `.adjustment`; layer 1 equals the oracle; undo → original bytes (tile storage shared with the original); redo → oracle bytes; layer 0 unchanged.
  - `posterizePreviewCancelOK`: start Posterize with defaults → live state equals the oracle(16,16,16), no step; `update("red", .integer(4))` (linked) → controller values 4/4/4 and live state equals oracle(4,4,4); cancel → exact restore, no step; second session OK → one "Posterize" step; undo/redo exact.
  - `hueSaturationPreviewOK`: update hue 30, saturation 150, lightness −20 → live state equals `HueSaturationReference.exact` (±1 via `GoldenImage.compare`); OK → one "Hue / Saturation" step; undo/redo exact.
  - `identityAddsNoStep`: Hue / Saturation defaults OK → no step, `lastApplied` set; Black and White on an all-gray layer → no step.
  - `posterizeTwiceNoStep`: Posterize 16 OK, then Repeat → second run adds no step (16 levels is idempotent).
  - `sepiaRepeatAppliesTwice`: Sepia, then Repeat → two "Sepia" steps; pixel (200,100,50,255) becomes (143,124,107) then (145,127,110) (hand: I = (7,471·107 + 38,470·124 + 19,595·143) >> 16 = 127; curves at 127 → 145 / 110).
  - `selectionClippedBlackAndWhite` / `selectionClippedHueSaturation`: selection rect (100,100,200,100) → pixels inside equal the oracle, pixels outside byte-identical, one step, undo exact.
  - `sparseLayerStaysSparse`: Black and White, Posterize, Sepia, and Hue / Saturation (hue 40) on an empty 600×300 layer → no tiles allocated, no step.
  - `lightnessAllocatesTransparent`: Hue / Saturation lightness +50 on an empty layer → blend alpha (50·255)/100 = 127 toward white: (0·128 + 255·127)/256 = **126** → pixel (599,299) == (126,126,126,0); every tile allocated; one step.
  - `rememberedPosterizeValuesStayLinked`: OK with red 8 (linked) → reopen initial values 8/8/8, linked true; OK with linked off and 2/16/64 → reopen 2/16/64, linked false.
- **UI — `PaintDotMacUITests/BasicAdjustmentsUITests.swift`** (fixture: 300×200 PNG filled with (200,100,50,255) via `UITestFixtures.writePNG`; pixel checks by ⌘S and decoding the PNG in the test):
  - `testMenus`: Adjustments menu items "Black and White", "Brightness / Contrast…", "Hue / Saturation…", "Invert Colors", "Posterize…", "Sepia" appear in this relative order (asserted as a subsequence, so 0033/0034's added items don't break it), with ⇧⌘G, ⇧⌘U, ⇧⌘I, ⇧⌘P, ⇧⌘E shown on the right items.
  - `testBlackAndWhiteShortcutAndUndo`: ⇧⌘G → no sheet appears, last history row "Black and White"; ⌘S → pixel (10,10) == (124,124,124,255); ⌘Z → history back to one row; ⌘S → (200,100,50,255); ⇧⌘Z → "Black and White" row again.
  - `testSepiaShortcutAndRepeat`: choose Adjustments ▸ Sepia from the menu → row "Sepia"; ⌘S → (143,124,107,255); Effects menu shows "Repeat Sepia"; ⌘F → two "Sepia" rows, ⌘S → (145,127,110,255).
  - `testHueSaturationDialog`: ⇧⌘U → `effectDialog` appears with `effectDialog.hue.field` "0", `effectDialog.saturation.field` "100", `effectDialog.lightness.field` "0"; type "45⇥" into the hue field, wait for `effectDialog.progress` "idle"; Escape → no new row, ⌘S → (200,100,50,255); ⇧⌘U again → hue field "0" (Cancel not remembered); type "45⇥", click `effectDialog.ok` → row "Hue / Saturation", ⌘S → (186,198,49,255).
  - `testPosterizeLinkedAndUnlinked`: Adjustments ▸ Posterize… → fields "16", "16", "16", `effectDialog.linked` checked; OK → row "Posterize", ⌘S → (204,102,51,255); ⌘Z; reopen, type "4⇥" in the red field → green and blue fields show "4"; uncheck Linked, type "2⇥" in red → green/blue still "4"; type "16⇥" in green and "16⇥" in blue; OK → ⌘S → (255,102,51,255) (n = 2: 200 → 255; n = 16: 100 → 102, 50 → 51).
  - `testBlackAndWhiteRespectsSelection`: launch with `-UITestSelectRect 0,0,100,200`; ⇧⌘G; ⌘S → (50,10) == (124,124,124,255), (150,10) == (200,100,50,255).
  - `testGoToFolderStillWorksInSavePanel`: ⇧⌘S → save panel; ⇧⌘G → the panel's "Go to folder" text field appears; Escape twice → panel closed; History still has one row (no "Black and White").
- **Performance:** none new (NF-3 is measured in 0041; these are point operations like 0031's Invert). The 0031 `testInvert24MP` bound still applies to the shared runner.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build without warnings, all tests pass, none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open a colorful photo; Adjustments ▸ Hue / Saturation…: drag Hue from −180 to 180 — colors cycle smoothly in the preview with no flashes; Saturation 0 gives a gray image, 200 a vivid one; Lightness ±100 nearly white/black. Cancel restores the photo exactly.
  2. Compare Black and White and Sepia side by side with Paint.NET (Windows) on the same image if one is available: same gray levels and the same warm tone (exact match expected for these two).
  3. Posterize…: with Linked on, drag Red — Green and Blue sliders follow live; uncheck Linked and drag Blue alone — only blue banding changes in the preview.
  4. Check the Adjustments menu in Dark Mode and with VoiceOver: the Linked checkbox reads "Linked", sliders read "Red: 16" etc.

## Open questions

Decided as stated (recommended answers applied in this spec); please confirm and record in PRD.md §5.12/§5.8/§12:

1. **Shortcuts for Black and White ⇧⌘G, Sepia ⇧⌘E, and Posterize ⇧⌘P** follow PRD §5.12's Ctrl → ⌘ rule from Paint.NET's Ctrl+Shift+G / Ctrl+Shift+E / Ctrl+Shift+P (`AdjustmentsMenu.GetEffectShortcutKeys`); the PRD table lists only Hue/Saturation. Possible conflicts with Mac conventions: ⇧⌘G is "Find Previous" in apps with a Find menu and "Go to Folder" in open/save panels (PaintDotMac has no Find menu; the panels keep their own ⇧⌘G, tested), and ⇧⌘P is the standard "Page Setup…" (PaintDotMac has no printing in v1.0). ⇧⌘E has no standard meaning. Recommended: keep all three and add rows "Black and White | Ctrl+Shift+G | ⇧⌘G", "Sepia | Ctrl+Shift+E | ⇧⌘E", "Posterize | Ctrl+Shift+P | ⇧⌘P" to §5.12 (0045 records them in `docs/shortcuts.md`); if printing is ever added, Page Setup would take ⇧⌘P and Posterize would lose its shortcut.
2. **Sepia has no dialog.** Paint.NET 3.36's Sepia has no parameters, but the current Paint.NET docs (FX-E's primary source) say "Sepia has a single control which sets the intensity or strength of the effect", without naming it or giving a range or default. Recommended: ship the 3.36 behavior (no dialog, full strength) as planned for this spec; an intensity slider can be added later once its range/default are known.
3. **Hue / Saturation uses the integer-exact form of Paint.NET 3.36's formula** (item 7), not a bit-for-bit copy of its `double` HSV round trip, because the GPU can't reproduce those `double` truncation artifacts. It differs from 3.36 by at most a few levels on under 0.5% of colors; Paint.NET's whole-percent HSV quantization (which can shift grays by one level when any setting is non-default) is kept. Recommended: accept.
4. **Hue / Saturation's Saturation range is 0…200 with default 100** (3.36 source: `Int32Property(Saturation, 100, 0, 200)`, with 101…200 mapped to 103…400 internally). The current docs say "The starting value of the Saturation control is zero" but their own example ("Saturation increased to 136 … more vibrant") only fits the 0…200 / 100 scale. Recommended: 0…200, default 100, as specified.

## Out of scope

- Levels, Auto-Level and the `.levels` schema kind (0033); Curves and `.curve` (0034).
- A Sepia intensity control and Paint.NET 5's newer adjustments (Exposure, Highlights / Shadows, Temperature and Tint = ADJ-10, P2; Invert Alpha, not in PRD).
- Moving effect shortcuts into `Core/Shortcuts/ShortcutTable.swift` and `docs/shortcuts.md` (0045).
- Any change to the effect runner, session lifecycle, dialog layout, or Repeat semantics beyond items 3 and 11 (0031).
