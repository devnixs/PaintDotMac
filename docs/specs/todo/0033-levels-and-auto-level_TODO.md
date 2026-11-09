# 0033 — Add Levels (⌘L) with its histogram dialog control and Auto-Level (⇧⌘L)

> Source: PRD.md §5.8 (ADJ-7 Levels, ADJ-1 Auto-Level, and the shared rule "All adjustments (P0): apply to the active layer and selection, show a live canvas preview while the dialog is open, and support Cancel and 'Repeat last' (⌘F)"), §5.9 FX-A, FX-B, FX-C, FX-D, FX-E, §5.12 (Levels Ctrl+L → ⌘L; general rule Ctrl → ⌘ for Auto-Level Ctrl+Shift+L → ⇧⌘L), §12 D-22, D-34 (H-6); AGENTS.md architecture rule 5 (effects are data-driven; dialogs generated from the schema).
> Paint.NET docs (fetched 2026-11-07; `getpaint.net/doc/latest/…` redirects to `paint.net/doc/latest/…`): Adjustments menu — https://paint.net/doc/latest/AdjustmentsMenu.html ("Auto-Level is used to equalize the range of colors in an image."; "Auto-Level has no configurable options and does not display a dialog."; "The Auto-Level adjustment is equivalent to using the Levels adjustment and clicking the Auto button."); Levels — https://paint.net/doc/latest/Levels.html (shortcut Ctrl + L; Input side with white and black points "(255 for white and 0 for black)"; Output side with white, black and grey points; "These colors can be adjusted using the numeric inputs, the slider, or by double-clicking on the color swatch itself."; "Every adjustment that is performed on an image will cause the output histogram to be updated"; "With default settings, the output histogram matches the input histogram"; "By using the R, G, B checkboxes individual channels can be adjusted separately or in pairs."). The docs give no ranges beyond 0/255 and say nothing about Auto/Reset, so those come from Paint.NET's source (FX-E fallback).
> Paint.NET 3.36 source (last published source), https://github.com/wangdeshui/paint.net: `src/Core/UnaryPixelOps.cs` (`ChannelCurve`, `Level`: property setters, `SetGamma`, `AutoFromLoMdHi`, `UpdateLookupTable`, `Apply`, `UnApply`), `src/Core/Histogram.cs` (`GetPercentile`, `GetMean`), `src/Core/HistogramRGB.cs` (`AddSurfaceRectangleToHistogram`, `GetMeanColor`, `GetPercentileColor`, `MakeLevelsAuto`, `SetFromLeveledHistogram`), `src/Effects/AutoLevelEffect.cs`, `src/Effects/LevelsEffect.cs`, `src/Effects/LevelsEffectConfigToken.cs`, `src/Effects/LevelsEffectConfigDialog.cs` (`MaskAvg`, `UpdateByMask`, `MaskGamma`, `UpdateGammaByMask`, `InitDialogFromToken`, Auto/Reset handlers, numeric ranges), `src/Menus/AdjustmentsMenu.cs` (Auto-Level Ctrl+Shift+L, Levels Ctrl+L), `src/Strings/Strings.resx` (names below).
> Milestone: M4
> Depends on: 0032-basic-adjustments (`ChannelLookupTable` + `channelLookup` kernel, `EffectParameterEditor`, `ImageEffect.parameterRules`; and, through it, 0031 effect framework: `ImageEffect`, `EffectParameter`, `EffectParameterValues`, `EffectRegistry`, `EffectParameterMemory`, `EffectMaskBlend`, `CoreImageBridge`, `EffectRunner`, `EffectSessionController`, `EffectDialogView`, `EffectKernels.metal`, Adjustments menu; 0013 `SelectionMask`; 0002 `TiledSurface`; 0008 `UndoBridge`/`TileDiffHistoryItem`)

## Context

No Levels/histogram code exists yet. This spec builds on 0031's framework exactly as specified there (`docs/specs/todo/0031-effect-framework-and-first-adjustments_TODO.md`):

- `EffectParameter.Kind` has `integer/double/bool/choice/color/angle/seed` and a comment "0033 adds `.levels`, 0034 adds `.curve` (with their own value cases and dialog controls)" (0031 item 1). `EffectParameterValue` has the matching value cases; `EffectParameterValues` has typed getters, `setting(_:to:schema:)`, `normalized(for:)`; `EffectParameterText.format/parse`; `EffectSchemaValidator`.
- `ImageEffect.makeOutput(input:values:context:)` renders **one region** (`EffectRenderContext.inputRect/outputRect`, 0031 item 2). There is **no hook for an effect that needs whole-layer data** (a histogram) before rendering. Auto-Level needs exactly that (Paint.NET computes the histogram in `OnSetRenderInfo` from the source surface within the selection, then renders every ROI with the resulting `Level`). This spec adds that hook (`prepare`, item 4).
- `EffectRunner.run` streams chunks; zero affected tiles → finishes immediately with no yield (0031 item 8). `EffectSessionController` commits `TileDiffHistoryItem(name: effect.name, …)`; an empty diff adds no step (H-6) and `lastApplied` is still recorded (0031 item 11, *Edge cases*). Repeat (⌘F) re-runs `lastApplied` with the remembered (unprepared) values.
- `EffectDialogView` builds one row per parameter from the schema; `EffectDialogModel` forwards changes to `EffectSessionController.update(_:to:)` (0031 item 15).
- **0032** (exactly as specified in `docs/specs/todo/0032-basic-adjustments_TODO.md`): `EffectRegistry.standard` = `[InvertColors(), BrightnessContrast(), BlackAndWhite(), HueSaturation(), Posterize(), Sepia()]`; `EffectRegistry.adjustments` is sorted by name. `ImageEffect.parameterRules: [EffectParameterRule]` (default `[]`; Levels and Auto-Level keep it). `EffectParameterEditor` is the single place an edit is normalized: `EffectSessionController.update(_:to:)` sets the value through an editor built from `effect.parameters` + `effect.parameterRules`, `EffectSessionController.values` returns `editor.values`, and `EffectParameterMemory.initialValues` results pass through an editor's `init` before a session starts — so `.levels` values are normalized by item 6's rule on every path. `ChannelLookupTable` + the `channelLookup` general kernel (reused here, item 2/9). `BlackAndWhite.intensity(r:g:b:)`.
- `EffectKernels.metal` holds Core Image stitchable kernels; `EffectRenderContext.kernel(_:)` returns a cached general `CIKernel` (0031 items 2, 7).

**Paint.NET behavior mirrored (3.36 source, transcribed in *Scope*).**
- *Levels* (`LevelsEffect`): the token is one `UnaryPixelOps.Level` = per channel (B, G, R) input low/high, output low/high (bytes) and gamma (float, 0.1…10). Rendering applies the 256-entry per-channel lookup table built by `UpdateLookupTable` from `Level.Apply(j, j, j)`; alpha is copied. Dialog (title "Levels Adjustment" in 3.36; our dialog title is the effect name "Levels", per 0031): Input Histogram | Input (white field + swatch, two-handle gradient, black swatch + field) | Output (white field + swatch, gamma field, grey swatch, black swatch + field, three-handle gradient) | Output Histogram; R, G, B checkboxes; Auto; Reset; OK; Cancel. Field ranges: input/output white and black 0…255 (integers; initial 255/0); gamma 0.1…10, 2 decimals, increment 0.1, initial 1.
- *Auto-Level* (`AutoLevelEffect`): no properties, no dialog. Histogram of the source within the selection → `MakeLevelsAuto()` (0.5 % / 99.5 % percentiles and the mean color) → `Level.AutoFromLoMdHi`; renders only `if (levels.isValid)`.
- Names (Strings.resx): "Levels", "Auto-Level"; group titles "Input Histogram", "Input", "Output", "Output Histogram"; checkboxes "R", "G", "B"; buttons "Auto", "Reset"; tooltips "Input White Point", "Input Black Point", "Output White Point", "Output Black Point", "Output Gamma" (3.36 appends "(double click to choose)" to the swatch tooltips; the Mac swatches open on a single click, so that suffix is dropped).

## User story

As a Paint.NET switcher, I press **⌘L** (Adjustments ▸ Levels…) and see the input histogram of my active layer (or selection) next to Input and Output controls. I drag the input white point down or type a value, untick G and B to touch only the red channel, raise the output grey point to brighten midtones, or click **Auto** — and the canvas and the output histogram update live. **Reset** returns to the identity mapping, **Cancel** restores every pixel, **OK** adds one "Levels" step. **⇧⌘L** (Adjustments ▸ Auto-Level) does the Auto stretch in one step named "Auto-Level", with no dialog, and ⌘F repeats it on the current pixels.

## Scope & changes

Cross-cutting rules (unchanged from 0031): every pixel change goes through `UndoBridge` (preview via `updateLiveState`, the step via `commit`); `Core` imports no AppKit/SwiftUI; straight 8-bit sRGB, math on encoded values (Core Image color management off, 0031 item 6); GPU rendering through `CoreImageBridge` with a CPU oracle in the test target (±1, expected 0); one schema-generated dialog (the `.levels` kind gets a dedicated control, as 0031 item 1 foresaw — still no per-effect dialog).

### Core (pure, headless, unit-tested)

1. **`Core/Effects/LevelsMapping.swift`** (new) — the Levels value type and Paint.NET's `Level` math.
   ```swift
   public enum LevelsChannel: Int, CaseIterable, Sendable { case red, green, blue }
   public struct LevelsColor: Hashable, Sendable {               // one byte per channel (Paint.NET ColorBgra without alpha)
       public var red, green, blue: UInt8
       public init(red: UInt8, green: UInt8, blue: UInt8)
       public init(gray: UInt8)
       public subscript(_ c: LevelsChannel) -> UInt8 { get set }
   }
   public struct LevelsGamma: Hashable, Sendable {
       public var red, green, blue: Float
       public subscript(_ c: LevelsChannel) -> Float { get set }
   }
   public struct LevelsValue: Hashable, Sendable {
       public var inputLow: LevelsColor      // input black point
       public var inputHigh: LevelsColor     // input white point
       public var outputLow: LevelsColor     // output black point
       public var outputHigh: LevelsColor    // output white point
       public var gamma: LevelsGamma
       public static let identity: LevelsValue   // in 0/255, out 0/255, gamma 1 — Paint.NET `new Level()`
       public func normalized() -> LevelsValue
       public var isIdentity: Bool               // == .identity
   }
   public enum LevelsMapping {
       public static func apply(_ j: Int, channel: LevelsChannel, levels: LevelsValue) -> UInt8   // Level.Apply for one channel
       public static func lut(for levels: LevelsValue) -> ChannelLookupTable                       // UpdateLookupTable (0032's type)
       public static func auto(lo: LevelsColor, md: LevelsColor, hi: LevelsColor) -> LevelsValue?  // AutoFromLoMdHi; nil = !isValid
       public static func auto(from histogram: Histogram) -> LevelsValue?                          // MakeLevelsAuto
       public static func unapply(_ after: UInt8, channel: LevelsChannel, levels: LevelsValue) -> (before: Float, slope: Float)  // UnApply
   }
   ```
   **`apply` (transcription of `Level.Apply`, per channel; Float/Double exactly as C#):**
   ```
   v = Float(j − inLow)                                   // C#: float v = input[i] − colorInLow[i]
   if v < 0                         → outLow
   else if v + Float(inLow) >= Float(inHigh) → outHigh
   else x = Float(v) / Float(inHigh − inLow)              // float / int → float division
        r = Double(outLow) + Double(outHigh − outLow) · pow(Double(x), Double(gamma))   // Math.Pow is double
        → UInt8(truncating: clamp(r, 0, 255))             // (byte)Utility.Clamp(double, 0, 255): truncation toward zero
   ```
   **`lut(for:)`**: `ChannelLookupTable(red: (0...255).map { apply($0, .red, …) }, green: …, blue: …)`. The caller always passes a normalized value, so Paint.NET's `isValid` failure path of `UpdateLookupTable` never applies to Levels.
   **`normalized()`** (the invariants Paint.NET's property setters maintain, applied per channel; this is also `EffectParameterValues` normalization for `.levels`): gamma NaN/±inf → 1, then clamp to `0.1…10` (`SetGamma`); `inputLow = min(inputLow, 254)`; `inputHigh = max(inputHigh, inputLow + 1)`; `outputLow = min(outputLow, 254)`; `outputHigh = max(outputHigh, outputLow + 1)`. (Every normalized value is `isValid` in Paint.NET's sense: `inHigh > inLow`, `outHigh ≥ outLow`, gamma ≥ 0.)
   **`auto(lo:md:hi:)` (transcription of `AutoFromLoMdHi`):** per channel `γ = (lo < md && md < hi) ? Float(clamp(log(0.5) / log(Double(Float(md − lo) / Float(hi − lo))), 0.1, 10.0)) : 1` (C# `Math.Log(0.5, base)` = `ln 0.5 / ln base`, base is a float division); result `inputLow = lo`, `inputHigh = hi`, `outputLow = 0`, `outputHigh = 255`, `gamma = γ`. **Validity (`UpdateLookupTable`'s `isValid`):** if any channel has `hi <= lo` the whole result is invalid → return `nil` (Auto-Level then changes nothing, exactly like `if (this.levels.isValid)` in `AutoLevelEffect.OnRender`). See *Open questions* 3.
   **`auto(from:)`** = `auto(lo: histogram.percentile(0.005), md: histogram.meanColor(), hi: histogram.percentile(0.995))`.
   **`unapply` (transcription of `UnApply`, used only for the output-histogram display):** `t = Float(Int(after) − outLow) / Float(outHigh − outLow)`; `before = Float(inLow) + Float(inHigh − inLow) · Float(pow(Double(t), Double(1 / gamma)))`; `slope = Float(inHigh − inLow) / (Float(outHigh − outLow) · gamma) · Float(pow(Double(t), Double(1 / gamma − 1)))`, slope NaN/inf → 0.

2. **Lookup table — no new type.** `LevelsMapping.lut(for:)` returns 0032's `ChannelLookupTable` (`Core/Effects/ChannelLookupTable.swift`: `red/green/blue` × 256, `identity`, `isIdentity`, `apply(_ c: ColorRGBA8)` = `(red[R], green[G], blue[B], A)`, `makeImage()`, `apply(to:context:)` with the `channelLookup` kernel) — Paint.NET's `ChannelCurve`. 0033 adds nothing to that type or kernel.

3. **`Core/Effects/Histogram.swift`** (new) — Paint.NET's `HistogramRgb`.
   ```swift
   public struct Histogram: Equatable, Sendable {
       public private(set) var red: [Int], green: [Int], blue: [Int]   // 256 bins each
       public init()                                                    // all zero
       public init(red: [Int], green: [Int], blue: [Int])               // tests; precondition 256 each
       public var pixelCount: Int                                       // Σ red
       public static func compute(surface: TiledSurface, selection: SelectionMask?) throws -> Histogram
       public func percentile(_ fraction: Float) -> LevelsColor         // GetPercentileColor
       public func meanColor() -> LevelsColor                          // GetMeanColor
       public func leveled(by levels: LevelsValue) -> Histogram         // SetFromLeveledHistogram (output histogram display)
       public func bins(_ c: LevelsChannel) -> [Int]
   }
   ```
   - **`compute`** (transcription of `AddSurfaceRectangleToHistogram` over the selection's region): every **in-canvas pixel that belongs to the selection** adds 1 to `red[R]`, `green[G]`, `blue[B]`. **Alpha is ignored** (3.36 counts every pixel's stored color, transparent or not; *Open questions* 1). Membership: `selection == nil` → every pixel; otherwise mask tile `.full` → every in-canvas pixel of the tile, `.empty` → none, `.partial` → pixels with `coverage ≥ 128` (Paint.NET's aliased selection region ≈ pixel center inside the path). **Unallocated tiles** count their member pixels as `(0,0,0)` in O(1) per tile (no per-pixel loop). Walk tiles row-major, reading tile bytes through `withUnsafeBytes` with raw-pointer counters (this runs in Debug test builds; no per-pixel `Array` bounds checks). `try Task.checkCancellation()` once per tile.
   - **`percentile(f)`** (transcription of `GetPercentile`, per channel): `sum = Σ bins`; walk `j = 0…255`, `integral += bins[j]`, return the first `j` with `Float(integral) > Float(sum) * f` (C#: long·float is float; long compared with float as float); if none (empty histogram) → 0.
   - **`meanColor()`** (`GetMean` + `GetMeanColor`): per channel `mean = sum == 0 ? 0 : Float(Σ j·bins[j]) / Float(sum)` (Float, as C#), byte = `UInt8(truncating: mean + 0.5)` (`(byte)(mean + 0.5f)`).
   - **`leveled(by:)`** (transcription of `SetFromLeveledHistogram`, per channel `c`, for each output value `v` 0…255): `(before, slope) = LevelsMapping.unapply(v, c, levels)`; if `v > outHigh || v < outLow || floor(before) < 0 || ceil(before) > 255 || before.isNaN` → 0; else if `before <= Float(inLow)` → `Σ input[0…inLow]`; else if `before >= Float(inHigh)` → `Σ input[inHigh…255]`; else `Int(Double(slope) * lerp(Double(input[floor(before)]), Double(input[ceil(before)]), Double(before) − floor(Double(before))))` (truncation). Display only; never used for pixels.

4. **`Core/Effects/ImageEffect.swift`** (extend 0031) — the whole-layer preparation hook.
   ```swift
   public enum EffectPreparation: Sendable, Equatable {
       case render(EffectParameterValues)   // render every chunk with these values
       case noChange                        // the effect leaves every pixel unchanged: render nothing
   }
   public protocol ImageEffect {
       // … 0031 requirements and 0032's `parameterRules` …
       /// Called once per render request, off the main actor, before any chunk; may read the whole source layer.
       /// Must be deterministic and check `Task.checkCancellation()` in long loops.
       func prepare(values: EffectParameterValues, source: TiledSurface, selection: SelectionMask?) throws -> EffectPreparation
   }
   public extension ImageEffect {
       func prepare(values: EffectParameterValues, source: TiledSurface, selection: SelectionMask?) throws -> EffectPreparation { .render(values) }
   }
   ```
   Every existing effect keeps the default. Prepared values are **never** remembered or recorded: `EffectParameterMemory.remember`/`recordApplied` keep receiving the controller's unprepared values, so Repeat recomputes from the then-current pixels (Paint.NET's `OnSetRenderInfo` runs again on every render).

5. **`Core/Effects/EffectRunner.swift`** (extend 0031 item 8): inside `run`'s producer task, before the first chunk, call `try request.effect.prepare(values: request.values, source: request.source, selection: request.selection)`. `.noChange` → finish the stream immediately with no yield (the same path as zero affected tiles); `.render(v)` → pass `v` (not `request.values`) to every `renderEffect` call. Cancellation during `prepare` finishes the stream with `CancellationError`; any other thrown error finishes it with that error. `chunkOrder` and the affected-tile set are unchanged.

6. **`Core/Effects/EffectParameter.swift`** (extend 0031 item 1):
   - `EffectParameter.Kind.levels(defaultValue: LevelsValue = .identity)`; `EffectParameterValue.levels(LevelsValue)`; typed getter `public func levels(_ id: String) -> LevelsValue` (missing/mistyped → `assertionFailure` + `.identity`, like the other getters).
   - Normalization: `.levels(v)` → `.levels(v.normalized())`; a wrong-case value → the default.
   - `EffectParameterText.format` returns `""` and `parse` returns `nil` for `.levels` (the kind has no text field of its own).
   - `EffectSchemaValidator`: a `.levels` default must equal `default.normalized()`.
   - `EffectParameterValues.resolving(_ id: String, to value: EffectParameterValue) -> EffectParameterValues` — sets a value **without** schema normalization (the schema of a no-parameter effect would drop it). Documented as "only for `ImageEffect.prepare` results"; used by Auto-Level.

7. **`Core/Effects/Adjustments/Levels.swift`** (new) — `public struct Levels: ImageEffect`: `id "levels"`, `name "Levels"` (menu "Levels…"), `.adjustment`, `shortcut EffectShortcut(key: "l", modifiers: [.command])` (PRD §5.12), `.straight`, `inputPadding 0`, parameters `[EffectParameter(id: "levels", label: "Levels", kind: .levels(defaultValue: .identity))]`, default `prepare`. `makeOutput`: `try LevelsMapping.lut(for: values.levels("levels")).apply(to: input, context: context)` (item 9). Output `(lut.red[R], lut.green[G], lut.blue[B], A)`; color under alpha 0 is mapped too (0031 *Open questions* 4).

8. **`Core/Effects/Adjustments/AutoLevel.swift`** (new) — `public struct AutoLevel: ImageEffect`: `id "autoLevel"`, `name "Auto-Level"` (no dialog, menu "Auto-Level"), `.adjustment`, `shortcut EffectShortcut(key: "l", modifiers: [.command, .shift])` (Paint.NET Ctrl+Shift+L → ⇧⌘L by PRD §5.12's general rule; see *Open questions* 4), `.straight`, no parameters.
   - `prepare`: `let h = try Histogram.compute(surface: source, selection: selection)`; `guard let levels = LevelsMapping.auto(from: h), !levels.isIdentity else { return .noChange }`; `return .render(values.resolving("levels", to: .levels(levels)))`. (Identity → `.noChange` is an optimization: the result would be byte-identical.)
   - `makeOutput`: identical to Levels (`values.levels("levels")` → `LevelsMapping.lut(for:)` → `ChannelLookupTable.apply(to:context:)`).

9. **GPU path:** Levels and Auto-Level render with `try LevelsMapping.lut(for: values.levels("levels")).apply(to: input, context: context)` — 0032's `ChannelLookupTable.apply(to:context:)` and its `channelLookup` kernel, unchanged (nil result → `EffectError.renderFailed`, as 0032 specifies).

10. **`Core/Rendering/Shaders/EffectKernels.metal`:** no change (no new kernel; `CoreImageBridge`'s kernel-name list is unchanged).

11. **`Core/Effects/LevelsEditor.swift`** (new) — the dialog control's logic as a pure value type (transcriptions of `LevelsEffectConfigDialog`), so the SwiftUI control only renders and forwards.
    ```swift
    public struct LevelsChannelMask: Hashable, Sendable { public var red = true, green = true, blue = true; public var isEmpty: Bool }
    public enum LevelsField: String, CaseIterable, Sendable { case inputWhite, inputBlack, outputWhite, outputGamma, outputBlack }
    public enum LevelsPoint: String, CaseIterable, Sendable { case inputWhite, inputBlack, outputWhite, outputGray, outputBlack }
    public struct LevelsDialogFields: Equatable, Sendable {
        public var inputWhite: Int, inputBlack: Int, outputWhite: Int, outputBlack: Int   // 0…255
        public var outputGamma: Double                                                     // shown with 2 decimals
        public var outputGrayPosition: Int        // gradient middle handle: Int(Double(lo) + Double(hi − lo) · pow(0.5, gamma))
    }
    public enum LevelsEditor {
        public static func maskAverage(_ c: LevelsColor, mask: LevelsChannelMask) -> Int         // MaskAvg: Σ masked / count (integer division); 0 when mask empty
        public static func maskGamma(_ g: LevelsGamma, mask: LevelsChannelMask) -> Float         // MaskGamma: Float average; 1 when mask empty
        public static func updateByMask(_ c: LevelsColor, to value: UInt8, mask: LevelsChannelMask) -> LevelsColor
        public static func updateGammaByMask(_ g: LevelsGamma, to value: Float, mask: LevelsChannelMask) -> LevelsGamma
        public static func fields(for levels: LevelsValue, mask: LevelsChannelMask) -> LevelsDialogFields   // InitDialogFromToken
        public static func setting(_ field: LevelsField, to text: Double, in levels: LevelsValue, mask: LevelsChannelMask) -> LevelsValue
        public static func setting(_ point: LevelsPoint, color: LevelsColor, in levels: LevelsValue, mean: LevelsColor) -> LevelsValue  // swatch color choice
        public static func draggingOutputGray(to position: Int, in levels: LevelsValue, mask: LevelsChannelMask) -> LevelsValue
        public static func gradientValue(forY y: Double, height: Double) -> Int                    // vertical gradient: bottom 0 … top 255, rounded, clamped
        public static func outputGrayPreview(_ levels: LevelsValue, mean: LevelsColor) -> LevelsColor   // grey swatch = Apply(mean color)
    }
    ```
    - **`updateByMask`** (verbatim `UpdateByMask`): empty mask → unchanged. Loop A (do-while): `old = average; average = maskAverage(after)`; `if average == 0 break`; `factor = Float(value) / Float(average)`; each masked channel `= clampToByte(Float(after[c]) * factor)` (`ClampToByte(float)`: >255 → 255, <0 → 0, else truncate); repeat while `average != value && old != average`. Loop B: while `average != value`: `average = maskAverage(after)`; `diff = value − average`; each masked channel `= clamp(after[c] + diff, 0, 255)`. (Both loops terminate — Loop B moves the masked average monotonically toward `value` — but add a hard cap of 1,024 iterations each with `assertionFailure` as a safety net.)
    - **`updateGammaByMask`** (verbatim `UpdateGammaByMask`): empty mask → unchanged; do { `average = maskGamma(g)`; `factor = value / average`; each masked channel `= clamp(factor · g[c], 0.1, 10)` } while `abs(value − average) > 0.001` (cap 1,024 iterations).
    - **`setting(field:…)`**: applies **only the edited field** (Paint.NET re-applies all five fields on every change; unchanged ones are no-ops except a tiny gamma re-normalization — *Open questions* 2): the text value is clamped to the field range (0…255 integers; gamma 0.1…10 rounded to 2 dp) then
      - `inputWhite` → `inputHigh = updateByMask(inputHigh, v)`, then the per-channel `ColorInHigh` setter rule: channel 0 → 1; if `inputLow[c] > inputHigh[c] − 1` → `inputLow[c] = inputHigh[c] − 1`;
      - `inputBlack` → `inputLow = updateByMask(…)`, setter: 255 → 254; if `inputHigh[c] < inputLow[c] + 1` → `inputHigh[c] = inputLow[c] + 1`;
      - `outputWhite` / `outputBlack` → the same with the output pair;
      - `outputGamma` → `gamma = updateGammaByMask(gamma, Float(v))`;
      - result `.normalized()`. Empty mask → value unchanged (Paint.NET disables the controls).
      The setter rules are applied **per channel** (3.36's `ColorInLow`/`ColorInHigh` setters copy `value.R` into G and B — a bug not reproduced, *Open questions* 2).
    - **`setting(point:color:…)`** (swatch color choice; ignores the mask, like 3.36): the four end points set the whole `LevelsColor` through the same setter rules; `outputGray` sets per channel `γ = clamp(log(a) / log(b), 0.1, 10)` with `a = Double(color[c] − outLow) / Double(outHigh − outLow)`, `b = Double(mean[c] − inLow) / Double(inHigh − inLow)` (Double division — 3.36 divides integers here, a bug not reproduced); a channel where `a ≤ 0`, `b ≤ 0`, `b ≥ 1`, or the result is not finite keeps its gamma.
    - **`draggingOutputGray(to:)`**: with `lo = maskAverage(outputLow)`, `hi = maskAverage(outputHigh)`, `p = clamp(position, lo + 1, hi − 1)`, `r = Double(p − lo) / Double(hi − lo)` → `gamma = updateGammaByMask(gamma, Float(clamp(log(r) / log(0.5), 0.1, 10)))` — the exact inverse of the handle-position formula, so the handle stays under the pointer (3.36 sets `1 / log₀.₅ r`, which makes the handle jump; *Open questions* 2). `hi − lo < 2` → unchanged.
    - **Auto / Reset** are not here: the control calls `LevelsMapping.auto(from: inputHistogram)` (nil → value unchanged and `NSSound.beep()` in the view — consistent with Auto-Level changing nothing; *Open questions* 3) and `.identity` (Reset; mask unchanged, as 3.36).

### Platform glue (covered by integration and UI tests)

12. **`Document/EffectSessionController.swift`** (extend 0031 item 11): `private(set) var inputHistogram: Histogram?` (observable through the dialog model). In `start()`, if any schema parameter is `.levels`, launch a detached task computing `Histogram.compute(surface: before…activeLayer.surface, selection: before.selection?.mask)` and publish it on the main actor; cancelled with the session. The live preview never waits for it.

13. **`UI/EffectDialogView.swift`** (extend 0031 item 15): a `.levels` parameter renders `LevelsControl` spanning the full dialog width, **without** the `"<label>:"` row label (the label is the control's accessibility label). `EffectDialogModel` exposes `inputHistogram` from the controller and forwards `LevelsControl` edits as `update("levels", to: .levels(newValue))` (normalized by 0032's `EffectParameterEditor` inside the controller; Levels has no `parameterRules`).

14. **`UI/EffectControls/LevelsControl.swift`** (new, SwiftUI; rendering only, all math in `LevelsEditor`/`Histogram`). Root identifier `effectDialog.levels`. Layout left → right, as Paint.NET:
    - **Input Histogram** (`effectDialog.levels.inputHistogram`): the three channels drawn as filled curves in red/green/blue at 50 % opacity (unticked channels at 15 %), heights linear in the bin count normalized to the largest bin over all three channels; a "Computing…" placeholder until `inputHistogram` arrives.
    - **Input** group: field `effectDialog.levels.inputWhite` (top), swatch `effectDialog.levels.inputWhiteSwatch`, vertical gradient `effectDialog.levels.inputGradient` (black → mask color, two triangle handles: black point bottom, white point top), swatch `effectDialog.levels.inputBlackSwatch`, field `effectDialog.levels.inputBlack` (bottom).
    - **Output** group: field `effectDialog.levels.outputWhite`, swatch `effectDialog.levels.outputWhiteSwatch`, field `effectDialog.levels.outputGamma` (2 decimals, stepper ±0.1), swatch `effectDialog.levels.outputGraySwatch` (shows `outputGrayPreview` with the input histogram's mean), swatch `effectDialog.levels.outputBlackSwatch`, field `effectDialog.levels.outputBlack`, gradient `effectDialog.levels.outputGradient` with three handles (black, grey at `outputGrayPosition`, white).
    - **Output Histogram** (`effectDialog.levels.outputHistogram`): `inputHistogram.leveled(by: value)`, same drawing.
    - Bottom row: checkboxes **R** `effectDialog.levels.red`, **G** `effectDialog.levels.green`, **B** `effectDialog.levels.blue` (mask; all ticked each time the dialog opens; view state, not part of the value); buttons **Auto** `effectDialog.levels.auto` (disabled until the histogram is ready) and **Reset** `effectDialog.levels.reset`. Unticking all three disables fields and gradients (they show `fields(for:mask:)` = 0/0/0/0/1.00).
    - Fields commit on Tab/Return/focus loss through `EffectParameterText`-style parsing (integers; gamma decimals, "." separator); invalid text reverts. Field values always display `LevelsEditor.fields(for: value, mask:)`.
    - Swatches are SwiftUI `ColorPicker`s (sRGB 8-bit, opacity off) → `LevelsEditor.setting(point:color:…)`.
    - Gradient drags call `gradientValue(forY:height:)` then `setting(.inputWhite/.inputBlack/.outputWhite/.outputBlack, …)` or `draggingOutputGray(to:)`; handles never cross (the setter rules enforce it).
    - Tooltips: "Input White Point", "Input Black Point", "Output White Point", "Output Black Point", "Output Gamma", and Paint.NET's histogram/Auto/R/G/B tooltips ("Automatically adjusts the input white point, black point, and output gamma to equalize the image", "Toggle manipulation of the red channel", …).
    - Labels "Input Histogram", "Input", "Output", "Output Histogram".

15. **`Core/Effects/EffectRegistry.swift`** (extend): `standard` = `[InvertColors(), BrightnessContrast(), BlackAndWhite(), HueSaturation(), Posterize(), Sepia(), Levels(), AutoLevel()]`; `adjustments.map(\.name) == ["Auto-Level", "Black and White", "Brightness / Contrast", "Hue / Saturation", "Invert Colors", "Levels", "Posterize", "Sepia"]`.

16. **`App/MainMenu.swift`**: no code change — the Adjustments menu is built from the registry; it gains "Auto-Level ⇧⌘L" (first) and "Levels… ⌘L". Both run through 0031's `DocumentWindowController.runEffect(_:)` / `repeatLastEffect(_:)` (guards: no gesture in progress, `!undoBridge.isBusy`, no sheet attached; then `undoBridge.prepareForNavigation?()` with reason `.command` before the histogram or any render), so there is no new command path. `MainMenuTests.noDuplicateShortcuts` must stay green (⌘L and ⇧⌘L are unused elsewhere as of this spec).

17. **`project.yml`**: no change (new files are picked up by the source globs; the kernel lives in the existing `EffectKernels.metal`). Run `xcodegen generate`.

No PRD change in this spec (PRD §5.12 has no Auto-Level row; *Open questions* 4).

## Acceptance criteria

- [ ] ADJ-7: Levels maps each channel through Paint.NET's `Level.Apply` LUT (input black/white, output black/white, per-channel gamma 0.1…10), alpha unchanged, GPU = CPU oracle (±1, expected 0). → `LevelsMappingTests.*`, `EffectGoldenTests.levelsGrid`, `.levelsRandom`
- [ ] ADJ-7: the Levels dialog shows input and output histograms of the active layer within the selection, Input/Output fields, swatches and gradients, R/G/B checkboxes, Auto and Reset; defaults 0/255/0/255/1.00; edits preview live; OK adds one "Levels" step; Cancel restores exactly. → `LevelsEditorTests.*`, `HistogramTests.*`, `LevelsSessionIntegrationTests.*`, `LevelsUITests.testLevelsInputWhiteOK`, `.testLevelsCancel`, `.testLevelsChannelMask`, `.testLevelsAutoAndReset`
- [ ] R/G/B checkboxes restrict edits to the ticked channels with Paint.NET's `UpdateByMask`/`UpdateGammaByMask` averaging. → `LevelsEditorTests.updateByMask*`, `.gammaByMask*`, `LevelsUITests.testLevelsChannelMask`
- [ ] ADJ-1: Auto-Level (⇧⌘L, no dialog) computes the RGB histogram of the active layer within the selection, takes the 0.5 %/99.5 % percentiles and the mean color, builds `AutoFromLoMdHi` levels and applies them as one "Auto-Level" step; equals clicking Auto in Levels then OK. → `HistogramTests.*`, `AutoLevelTests.*`, `EffectGoldenTests.autoLevelMatchesOracle`, `LevelsSessionIntegrationTests.autoLevelCommitsOneStep`, `.autoButtonEqualsAutoLevel`, `LevelsUITests.testAutoLevel`
- [ ] Auto-Level changes nothing (no step, H-6) when any channel's low and high percentiles are equal (3.36 `isValid`), and Repeat (⌘F) recomputes the histogram from the current pixels. → `AutoLevelTests.degenerateChannelIsNoChange`, `LevelsSessionIntegrationTests.autoLevelNoOp`, `.repeatAutoLevelRecomputes`, `LevelsUITests.testAutoLevelUniformSelectionNoOp`
- [ ] FX-D: with a selection only selected pixels change; the histogram counts only selected pixels. → `HistogramTests.selectionMembership`, `LevelsSessionIntegrationTests.selectionClipped`
- [ ] The framework's `prepare` hook runs once per request off the main actor; `.noChange` renders nothing; cancellation during `prepare` stops the run. → `EffectRunnerPrepareTests.*`
- [ ] Undo/redo of Levels and Auto-Level steps restore exact bytes. → `LevelsSessionIntegrationTests.levelsUndoRedo`, `.autoLevelUndoRedo`
- [ ] Adjustments menu lists "Auto-Level" (⇧⌘L) and "Levels…" (⌘L) in name order; no duplicate shortcuts. → `MainMenuEffectsTests.adjustmentsIncludeLevels`, `MainMenuTests.noDuplicateShortcuts`, `LevelsUITests.testMenus`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Empty histogram** (selection with no pixel at coverage ≥ 128, e.g. a sub-pixel antialiased sliver): percentiles 0, mean 0 → `auto` returns nil → Auto-Level `.noChange`, Auto button beeps; Levels dialog shows an empty histogram. → `HistogramTests.emptyHistogram`, `AutoLevelTests.emptyHistogramIsNoChange`
- **Solid-color layer / uniform selection** → lo == hi → no change, no step, `lastApplied` set (Repeat title "Repeat Auto-Level"). → `AutoLevelTests.degenerateChannelIsNoChange`, UI test
- **Transparent / unallocated tiles:** counted as `(0,0,0)` in the histogram (alpha ignored); Levels maps the color under alpha 0 too, so with `outputLow > 0` transparent tiles get allocated as `(o,o,o,0)`; all-zero results stay unallocated (0031 runner rule). → `HistogramTests.unallocatedTilesCountAsBlack`, `LevelsSessionIntegrationTests.sparseTiles`
- **Edge tiles (257×257, 1×1):** out-of-canvas bytes are never counted. → `HistogramTests.edgeTilesCountOnlyInCanvas`
- **Large images (24 MP):** histogram computed off the main actor, cancellable per tile; Auto-Level's progress sheet follows 0031's 0.5 s rule (histogram time counts). → `HistogramPerformanceTests.testHistogram24MP`, `EffectRunnerPrepareTests.cancelDuringPrepare`
- **Out-of-range or inconsistent values** (from a remembered value, a field, or a test): normalized (`inLow ≤ 254`, `inHigh ≥ inLow + 1`, outputs likewise, gamma 0.1…10, NaN → 1). → `LevelsMappingTests.normalization`
- **Typing input black ≥ input white:** the setter pushes the other point (black 250 with white 200 → white 251). → `LevelsEditorTests.settersPushOtherPoint`
- **All channels unticked:** controls disabled; fields show 0/0/0/0/1.00; edits ignored. → `LevelsEditorTests.emptyMask`
- **Repeat Levels** re-applies the remembered `LevelsValue` without a dialog; **Repeat Auto-Level** recomputes. → integration tests
- **Hidden active layer, floating pixels, busy document, GPU unavailable:** handled by 0031's framework unchanged (covered by 0031 tests; `LevelsSessionIntegrationTests.pendingEditFinishedFirst` re-checks once for Auto-Level).
- **Histogram still computing when OK/Cancel is pressed:** the task is cancelled with the session; no crash. → `LevelsSessionIntegrationTests.histogramTaskCancelledWithSession`

## Test plan

Expected values come from Paint.NET's formulas (transcribed above) and hand calculation; the few float-sensitive numbers below were double-checked with an independent IEEE-754 float32/double transcription — never from running the code under test.

- **CPU oracles** (`PaintDotMacTests/Effects/Reference/`): `LevelsReference.apply(_ pixels: [ColorRGBA8], levels: LevelsValue) -> [ColorRGBA8]` — computes `Level.Apply` **per pixel directly** (no LUT; written independently of `LevelsMapping`); `AutoLevelReference.levels(for pixels: [ColorRGBA8], member: [Bool]) -> LevelsValue?` — its own histogram arrays, percentile loop, mean and `AutoFromLoMdHi` transcription (independent of `Histogram`/`LevelsMapping`); `ReferenceEffectRenderer` (0031) gains Levels/Auto-Level support through these oracles.
- **Unit — `PaintDotMacTests/Effects/LevelsMappingTests.swift`:**
  - `identityLUTIsIdentity`: `lut(.identity)` maps every j 0…255 to j (all three channels).
  - `gammaValues` (in 0/255, out 0/255): γ 2 → 0→0, 64→16 (4096/255 = 16.06), 128→64, 191→143, 254→253, 255→255; γ 0.5 → 1→15 (√255 = 15.97), 64→127 (√16320 = 127.75), 128→180, 254→254, 255→255.
  - `inputRange` (in 50/200, γ 1): 0→0, 49→0, 50→0, 51→1 (255/150 = 1.7), 100→85, 125→127 (127.5), 199→253, 200→255, 255→255.
  - `outputRange` (out 20/230): 0→20, 1→20 (20.82), 100→102, 128→125, 254→229, 255→230.
  - `combined` (in 10/240, γ 1.5, out 5/250): 0→5, 10→5, 11→5, 100→64, 125→91, 239→248, 240→250.
  - `perChannelIndependence`: red in 50/200, green γ 2, blue out 20/230 → pixel (100, 128, 1, 77) → (85, 64, 20, 77) (alpha kept).
  - `normalization`: in (255, 0) → inLow 254, inHigh 255; in (100, 100) → (100, 101); out (255, 3) → (254, 255); γ 0.05 → 0.1, 20 → 10, NaN → 1; `identity.normalized() == identity`.
  - `autoFromLoMdHi`: lo (40,0,0), md (120,112,50), hi (200,255,99) → in low (40,0,0), high (200,255,99), out 0/255, γ red 1.0 exactly (ln 0.5 / ln 0.5), green 0.84246 (±1e-5; ln 0.5 / ln(112/255)), blue 1.01471 (±1e-5; ln 0.5 / ln(50/99)); `md == lo` or `md == hi` → γ 1; clamping: lo 0, md 254, hi 255 → ln 0.5 / ln(254/255) = 176.4 → γ 10; lo 0, md 1, hi 255 → 0.12509 (±1e-5; with byte inputs the 0.1 lower clamp is unreachable).
  - `autoInvalidWhenAnyChannelFlat`: lo (10,20,30), hi (200,20,250) → nil.
  - `unapplyIdentity`: identity, after 0/128/255 → before 0/128/255 (±1e-3), slope 1 (±1e-4).
  - `lutIsChannelLookupTable`: `lut(for: in 50/200, γ 1)` is a `ChannelLookupTable` whose `red` equals `(0...255).map { apply($0, .red, …) }` and `lut(.identity) == ChannelLookupTable.identity`.
- **Unit — `PaintDotMacTests/Effects/HistogramTests.swift`:**
  - `countsTenByTen`: 10×10 surface, pixel index i (row-major) = (R 40 if i < 50 else 200, G `[0,64,128,255][i/25]`, B i, A 255) → red bins 40:50, 200:50; green 25 each at 0/64/128/255; blue 1 at 0…99; `pixelCount == 100`.
  - `percentiles` on that histogram: `percentile(0.005)` = (40, 0, 0); `percentile(0.995)` = (200, 255, 99) (blue: integral 99 at j = 98 is not > 99.5).
  - `meanColor`: (120, 112, 50) (green 111.75 + 0.5 → 112; blue 49.5 + 0.5 → 50).
  - `alphaIgnored`: same colors with alpha 0 → identical histogram.
  - `unallocatedTilesCountAsBlack`: 600×300 surface with one allocated tile filled (10,20,30,255) → red bin 10 = 65,536, bin 0 = 180,000 − 65,536.
  - `edgeTilesCountOnlyInCanvas`: 257×257 filled (5,5,5,255) → `pixelCount == 66,049`, all in bin 5.
  - `selectionMembership`: rect selection (2,0,3,10) on the 10×10 → `pixelCount == 30`; a `.partial` mask tile with coverage 127 at one pixel and 128 at another → only the 128 pixel counted.
  - `emptyHistogram`: percentile → (0,0,0), mean → (0,0,0).
  - `leveledIdentityMatchesInput` (each bin within ±1, bins 0 and 255 exact); `leveledRespectsOutputRange` (out 20/230 → bins < 20 and > 230 are 0); `leveledInputBlackGathers` (in low 100 → output bin 0 == Σ input[0…100]).
  - `cancellation`: compute inside a cancelled task throws `CancellationError`.
- **Unit — `PaintDotMacTests/Effects/LevelsEditorTests.swift`:**
  - `maskAverage`: (10,20,31) all → 20; red+blue → 20; none → 0. `maskGamma`: (1,2,3) red+green → 1.5; none → 1.
  - `updateByMaskZeroStart`: (0,0,0) → 10, all → (10,10,10).
  - `updateByMaskScale`: (255,255,255) → 200 all → (200,200,200); red only → 128 → (128,255,255).
  - `updateByMaskTwoChannels`: (100,200,50), red+green → 100 → (66,134,50) (hand trace: avg 150, factor ⅔ → (66,133); avg 99, factor 100/99 → (66,134); avg 100 → stop).
  - `updateByMaskAdditivePhase`: (0,128,255) all → 255 → (255,255,255) (multiplicative phase stalls at avg 170, additive phase finishes).
  - `updateByMaskAlreadyThere`: (10,20,30) all → 20 → unchanged.
  - `gammaByMask`: (1,1,1) all → 2 → (2,2,2); (8, 2, 1) red+green → 9 → red 10 (clamped), `abs(maskGamma(red+green) − 9) ≤ 0.002`, blue 1 (untouched).
  - `fieldsDefault`: identity, all → (inputWhite 255, inputBlack 0, outputWhite 255, outputBlack 0, gamma 1.00, grayPosition 127 = Int(255 · 0.5)).
  - `settingInputWhite`: identity, all, 200 → inputHigh (200,200,200); with mask red only → (200,255,255).
  - `settersPushOtherPoint`: in (0…200), set inputBlack 250 → inputLow (250…), inputHigh (251,251,251); set outputWhite 0 → outputHigh (1,1,1), outputLow (0,0,0).
  - `perChannelSetterNoCrossTalk`: red-only mask, inputLow (0,100,0), set inputWhite 50 → green's inputHigh stays 255 and green's inputLow stays 100 (3.36's `value.R` bug not reproduced).
  - `gammaField`: identity all, 2.5 → (2.5,2.5,2.5); 12 → 10; 0.04 → 0.1.
  - `outputGrayDragInverse`: out 0/255, drag to 191 → γ = ln(0.749)/ln(0.5) ≈ 0.4169 (±1e-3), and `fields(...).outputGrayPosition` back = 191 ± 1.
  - `swatchPoints`: set inputWhite color (200,150,100) → inputHigh exactly that; outputGray with mean (128,128,128) on identity and color (191,64,128) → γ red = ln(191/255)/ln(128/255) ≈ 0.4193 (±1e-3), green = ln(64/255)/ln(128/255) ≈ 2.0057 (±1e-3), blue = 1.0 (±1e-6); a = 0 channel → gamma unchanged.
  - `emptyMask`: fields → 0/0/0/0/1.00; `setting` → value unchanged.
  - `gradientValue`: y 0 → 0, y = height → 255, y = height/2 → 128 (127.5 rounded), out of range clamps.
- **Unit — `PaintDotMacTests/Effects/AutoLevelTests.swift`:** metadata (id "autoLevel", name "Auto-Level", no parameters, `hasDialog == false`, `menuTitle == "Auto-Level"`, shortcut `l` + [.command, .shift], icon `.adjustment`); `prepareTenByTen` (the 10×10 fixture → `.render` with levels == `autoFromLoMdHi` case above); `prepareMatchesReferenceOracle` (seeded 64×64 random surfaces, 20 seeds, `prepare` levels == `AutoLevelReference`); `degenerateChannelIsNoChange` (solid (128,64,32,255) → `.noChange`); `emptyHistogramIsNoChange` (selection rect of a tile that is `.partial` with all coverage < 128 → `.noChange`); `identityResultIsNoChange` (a surface whose percentiles are 0 and 255 with mean making γ = 1 in every channel → `.noChange`).
- **Unit — `PaintDotMacTests/Effects/LevelsTests.swift`:** metadata (id "levels", name "Levels", `menuTitle "Levels…"`, one parameter id "levels" kind `.levels(defaultValue: .identity)`, shortcut `l` + [.command], `inputPadding 0`); `EffectParameterTests`-style: `.levels` normalization, wrong-case → default, `format == ""`, `parse == nil`, `resolving` bypasses normalization; validator flags a non-normalized `.levels` default.
- **Unit — `PaintDotMacTests/Effects/EffectRunnerPrepareTests.swift`** (with `ReferenceEffectRenderer`): `prepareCalledOncePerRun` (counting stub effect, 3 chunks → 1 call); `preparedValuesReachRenderer` (stub returns `.render` with a resolved value → every `renderEffect` call receives it); `noChangeYieldsNothing` (stream finishes with no element, renderer never called); `cancelDuringPrepare` (stub blocking in `prepare` on a semaphore, cancel consumer → `CancellationError`, renderer never called); `prepareErrorPropagates`; `defaultPrepareIsIdentity` (Invert's `prepare` → `.render(values)`).
- **GPU — `PaintDotMacTests/Rendering/CoreImageBridgeTests.swift`** (extend; `kernelsLoad` unchanged): `channelLookupFullGrid` (0032's `ChannelLookupTable` with `red[i] = 255 − i`, `green[i] = i / 2`, `blue[i] = (i * 7) % 256` on a 256×256 surface where pixel (x,y) = (x, y, (x+y)%256, x%256 as alpha) → every byte equals the CPU `ChannelLookupTable.apply`).
- **Golden — `PaintDotMacTests/Effects/EffectGoldenTests.swift`** (extend; GPU via `CoreImageBridge` + runner vs oracle, `GoldenImage.compare` ±1, expected 0 differences, reported; fixture 600×400 seeded random as in 0031): `levelsGrid` (identity; in 50/200; out 20/230; γ 0.1, 0.5, 2, 10; combined 10/240/1.5/5/250; per-channel mixed value from `perChannelIndependence`); `levelsRandom` (20 seeded random normalized `LevelsValue`s, seed printed); `autoLevelMatchesOracle` (3 seeded fixtures with narrowed ranges, e.g. channels drawn from 30…180, plus the selection ellipse case through `EffectMaskBlend` + `MaskBlendReference`).
- **Integration — `PaintDotMacTests/Document/LevelsSessionIntegrationTests.swift`** (`@MainActor`, real `UndoBridge`, 600×400 two-layer document, active layer 1, `debounce: .zero`, renderer `CoreImageBridge`): `levelsPreviewAndOK` (start Levels, update to in 50/200 → live pixels == oracle, no step; OK → one "Levels" step, icon `.adjustment`); `levelsCancel` (exact restore, tiles share storage); `levelsUndoRedo` (undo → original bytes, redo → oracle bytes); `autoLevelCommitsOneStep` (fixture with narrowed ranges → "Auto-Level" step, pixels == `LevelsReference(AutoLevelReference(...))`); `autoLevelUndoRedo`; `autoLevelNoOp` (solid layer → no step, `effectMemory.lastApplied?.effectID == "autoLevel"`); `repeatAutoLevelRecomputes` (Auto-Level OK, then paint a new extreme pixel region through `updateLiveState` + commit a `TileDiffHistoryItem`, Repeat → second step's pixels == oracle on the then-current pixels, not the first step's levels); `repeatLevelsUsesRememberedValue`; `autoButtonEqualsAutoLevel` (dialog-model path: `inputHistogram` ready → Auto → OK → bytes identical to running Auto-Level on the same document); `selectionClipped` (rect selection (100,100,200,100): pixels outside byte-identical; Auto-Level's levels computed only from the selected pixels — equals `AutoLevelReference` with that membership); `sparseTiles` (Levels out low 10 on a layer with unallocated tiles → those tiles become (10,10,10,0); out low 0 leaves them unallocated); `histogramPublishedForLevelsOnly` (Levels session publishes `inputHistogram` == `Histogram.compute` of layer 1; a Brightness / Contrast session leaves it nil); `histogramTaskCancelledWithSession`; `pendingEditFinishedFirst` (floating pixels → steps "Finish Pixels", "Auto-Level").
- **Unit — `PaintDotMacTests/App/MainMenuEffectsTests.swift`** (extend): `adjustmentsIncludeLevels` — items "Auto-Level" (`l`, ⇧⌘, `menu.adjustments.autoLevel`) and "Levels…" (`l`, ⌘, `menu.adjustments.levels`) at their sorted positions; **updates 0031/0032's `adjustmentsItems`** to exactly `[("Auto-Level","l",[.command,.shift],"autoLevel"), ("Black and White","g",[.command,.shift],"blackAndWhite"), ("Brightness / Contrast…","",[],"brightnessContrast"), ("Hue / Saturation…","u",[.command,.shift],"hueSaturation"), ("Invert Colors","i",[.command,.shift],"invertColors"), ("Levels…","l",[.command],"levels"), ("Posterize…","p",[.command,.shift],"posterize"), ("Sepia","e",[.command,.shift],"sepia")]`.
- **Unit — `PaintDotMacTests/Effects/EffectRegistryTests.swift`** (update 0031/0032's): `standardContents` → ids `["invertColors","brightnessContrast","blackAndWhite","hueSaturation","posterize","sepia","levels","autoLevel"]`; `adjustmentsSortedByName` → item 15's list. `EffectSchemaValidatorTests.standardRegistryIsValid` still passes. 0031's `EffectsUITests.testMenus` and 0032's `BasicAdjustmentsUITests.testMenus` assert relative order only and need no change.
- **UI — `PaintDotMacUITests/LevelsUITests.swift`** (pixel checks by ⌘S and decoding the PNG in the test, as 0031):
  - Fixture A: 300×200 PNG filled with (200,100,50,255). Fixture B ("halves"): x < 150 → (40,0,0,255), x ≥ 150 → (200,64,49,255).
  - `testMenus`: Adjustments shows "Auto-Level" (⇧⌘L) before "Black and White" and "Levels…" (⌘L) after "Invert Colors".
  - `testLevelsInputWhiteOK` (A): ⌘L → `effectDialog.levels` exists; fields inputWhite "255", inputBlack "0", outputWhite "255", outputGamma "1.00", outputBlack "0"; R, G, B checked; type "200⇥" into inputWhite; wait `effectDialog.progress` "idle"; OK → last history row "Levels"; ⌘S → pixel (10,10) == (255,127,63,255) (200 ≥ 200 → 255; 100/200·255 = 127.5; 50/200·255 = 63.75); ⌘Z → ⌘S → (200,100,50,255).
  - `testLevelsCancel` (A): ⌘L, inputWhite "200⇥", Escape → no new row, pixels unchanged.
  - `testLevelsChannelMask` (A): ⌘L, untick G and B → inputWhite still "255"; type "200⇥"; OK → (255,100,50,255).
  - `testLevelsAutoAndReset` (B): ⌘L, wait until `effectDialog.levels.auto` is enabled, click it → inputBlack "13" ((40+0+0)/3), inputWhite "104" ((200+64+49)/3), outputGamma "1.01"; OK → ⌘S → (10,10) == (0,0,0,255), (200,10) == (255,255,255,255). ⌘L again → inputWhite "104" (remembered); click Reset → "255"/"0"/"1.00"; Cancel.
  - `testAutoLevel` (B): ⇧⌘L → no sheet, last row "Auto-Level"; ⌘S → (10,10) == (0,0,0,255), (200,10) == (255,255,255,255); ⌘Z → original.
  - `testAutoLevelUniformSelectionNoOp` (B, `-UITestSelectRect 0,0,150,200`): ⇧⌘L → history row count unchanged; Effects menu shows "Repeat Auto-Level".
- **Performance — `PaintDotMacTests/Effects/HistogramPerformanceTests.swift`** (XCTest `measure`): `testHistogram24MP` (6000×4000 opaque random layer, no selection) — informational; gate only on gross regression: average ≤ 3 s in the Debug test build. Record the number in Verification status.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build without warnings, all tests pass, none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open an under-exposed photo, ⌘L: the input histogram shows the three channels; drag the input white handle down and the output grey handle up — the canvas and the output histogram update live and the grey handle stays under the pointer; untick G and B and move the white point — only red changes; Reset → identity; Cancel → photo exact.
  2. Click each swatch: the color panel opens; choosing a color sets that point (grey swatch changes gamma); the dialog remains usable afterwards.
  3. ⇧⌘L on the same photo: visibly stretched contrast, one "Auto-Level" row; compare with ⌘L → Auto → OK on the original (⌘Z first): same look.
  4. Dark mode and VoiceOver: histogram labels, fields ("Input White Point"), checkboxes and buttons are announced; the dialog fits on a 13" screen without clipping.

## Open questions

Decided as stated (recommended answers applied in this spec); please confirm and record in PRD.md §5.8/§5.12/§12:

1. **The histogram (Levels dialog and Auto-Level) ignores alpha, like Paint.NET 3.36:** every selected pixel counts its stored color, so fully transparent areas (stored as (0,0,0,0)) count as black and pull Auto-Level's black point to 0; selection membership is mask coverage ≥ 128 (pixel center inside). Alternative: skip alpha-0 pixels or weight by alpha. Recommended: mirror 3.36.
2. **Paint.NET 3.36 Levels-dialog quirks are not reproduced:** (a) the input-point setters copy the red value into green/blue when pushing the other point — applied per channel here; (b) dragging the grey handle sets gamma to `1/log₀.₅ r`, which makes the handle jump — here the exact inverse of the handle formula; (c) the grey swatch divides integers (gamma becomes 0.1 or 10) — here Double division; (d) every field edit re-applies all five fields (re-normalizing gamma to the 2-decimal display) — here only the edited field is applied. The applied pixel math (`Level.Apply`, `AutoFromLoMdHi`, histogram percentiles/mean) is transcribed exactly. Recommended: yes.
3. **Auto-Level does nothing at all when any one channel has equal 0.5 % and 99.5 % percentiles** (e.g. a pure-red image whose blue channel is all 0), because 3.36 marks the whole `Level` invalid; the Levels dialog's Auto button then leaves the values unchanged and beeps (docs: Auto-Level ≡ Levels + Auto). Alternative: leave only the flat channel unchanged and level the others. Recommended: mirror 3.36.
4. **Auto-Level shortcut ⇧⌘L** (Paint.NET Ctrl+Shift+L via PRD §5.12's Ctrl → ⌘ rule; the §5.12 table has no Auto-Level row; ⇧⌘L is not a macOS-reserved shortcut and is unused in the app). Recommended: yes; add the row to PRD §5.12 and 0045's `docs/shortcuts.md`.

## Out of scope

- Curves and the `.curve` kind (0034; it uses 0032's `ChannelLookupTable` too).
- Luminosity (non-RGB) histograms, Paint.NET 4+/5 Levels UI changes, eyedropper point pickers (not in Paint.NET's docs).
- Persisting Levels values across launches (0031: per-session memory only).
- Moving the shortcuts into `Core/Shortcuts/ShortcutTable.swift` (0045).
