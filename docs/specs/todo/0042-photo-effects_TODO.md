# 0042 — Add Effects ▸ Photo ▸ Sharpen and Vignette (with the `.offset` center-point schema kind)

> Source: PRD.md §5.9 (Photo, v1.0 P0: "Sharpen, Vignette"; FX-A, FX-B, FX-C, FX-D, FX-E), §5.8 shared rules (live preview, Cancel, "Repeat last" ⌘F — they apply to effects through 0031's single session path), §3 use case 2 ("… sharpen, resize, and export a JPEG"; PRD §8 M4 exit criterion "Use case 2 works, apart from Sharpen" — this spec closes that gap), §8 M6, §5.7 H-1 (step names "Sharpen", "Vignette"), §12 D-16, D-19, D-22, D-34 (H-6); AGENTS.md architecture rules 1, 2, 3, 4, **5** (one file per effect, schema-generated dialog — the center point gets a schema kind with its own control, not a hand-written dialog), **7** (off-main-actor, cancellable, progress), 8.
> Paint.NET docs (fetched 2026-11-08): https://paint.net/doc/latest/EffectsPhotoMenu.html (linked from https://paint.net/doc/latest/EffectsMenu.html; `getpaint.net/doc/latest/…` redirects there). *Sharpen*: "Sharpen is used to reduce softness in an image … **Amount** which controls the strength of the effect. **Threshold** determines which pixels will be changed by the effect. A low threshold will change more pixels than a high threshold." *Vignette*: "This effect is used to create a darkened elliptical halo around the edges of an image. **Center** … The Center shows the focal point of the effect … Center is relocatable: use the double slider control or drag the cross hair in the thumbnail preview. **Radius** determines the strength of the effect by controlling the size of the darkening halo. **Strength** determines how dark the vignette will be … Lower values generate a lighter halo." "The color of the vignette … is not configurable." The docs give **no numeric ranges or defaults** for either effect (FX-E fallback → Paint.NET source, below). Threshold is a Paint.NET 5 addition — see *Open questions* 1.
> Paint.NET source, https://github.com/wangdeshui/paint.net (the 3.36 source clone, the last published Paint.NET source): `src/Effects/SharpenEffect.cs` (`new Int32Property(Amount, 2, 1, 20)`; `Apply` = `ColorBgra.Lerp(src, GetPercentile(50, …), -0.5f)`; `OnRender` → `RenderRect(this.amount, …)`, i.e. **Amount is the neighborhood radius**), `src/Effects/LocalHistogramEffect.cs` (`RenderRect` sliding disk histogram, `cutoff`, `GetPercentile`), `src/Core/ColorBgra.cs` `Lerp(ColorBgra, ColorBgra, float)`, `src/Core/Utility.cs` `Lerp(float,float,float)`, `ClampToByte(float)`; `src/Effects/VignetteEffect.cs` (© 2007, 2008 Ed Harvey, MIT; `DoubleVectorProperty(Offset, (0,0), (−1,−1), (1,1))`, `DoubleProperty(Radius, 0.5, 0.1, 4.0)`, `DoubleProperty(Amount, 1.0, 0.0, 1.0)`, display names "Center", "Radius", "Density"; `OnSetRenderInfo` / `OnRender` transcribed below), `src/Effects/SrgbUtility.cs` (`ToLinear`, `ToSrgb`, `ToSrgbClamped`), `src/Strings/strings.resx` (`SharpenEffect.Name` "Sharpen", `SharpenEffect.ConfigDialog.SliderLabel` "Amount", `VignetteEffect.Name` "Vignette", `…CenterLabel` "Center", `…RadiusLabel` "Radius", `…DensityLabel` "Density"; submenu `SubmenuNames.Photo` "Photo"). **Note for the planner:** the brief's guess "Sharpen Amount 1–20, default 10" is wrong — the source says default **2**.
> Milestone: M6
> Depends on: 0041-blur-effects (Effects-menu layout and test pattern, `UITestApp.chooseMenuItem(_:_:_:)`, `ReferenceEffectRenderer` whole-source dispatch, registry/menu test names), and through it 0031 (effect framework), 0032 (`EffectParameterEditor`), 0033 (`.levels` custom-kind pattern, `ImageEffect.prepare(values:source:selection:)`, `EffectParameterValues.resolving(_:to:)`), 0034 (registry list), 0025 (`ThumbnailRenderer`), 0024 (`GoldenImage`), 0013 (`SelectionMask.bounds`), 0008 (`UndoBridge`).

## Context

No application code exists yet; every name below is fixed by a lower-numbered spec.

- **Effect framework (0031, `docs/specs/todo/0031-effect-framework-and-first-adjustments_TODO.md`):** `EffectParameter` / `Kind` / `EffectParameterValue` / `EffectParameterValues` (typed getters, `subscript(id:) -> EffectParameterValue?`, `setting`, `normalized(for:)`), `EffectParameterText`, `EffectSchemaValidator` (item 1, `:37`); `ImageEffect` (`id`, `name`, `category` — `.photo` exists, menu title "Photo" — `parameters`, `shortcut`, `historyIcon` default `.effect`, `alphaMode`, `inputPadding(for:)`, `makeOutput(input:values:context:)`; `:81`); `EffectRenderContext` (`canvasSize`, `inputRect`, `outputRect`, `ciRect(_:)`, `ciPoint(x:y:)`, `colorKernel(_:)`, `kernel(_:)`; `:114`); `CoreImageBridge` (color management off end to end, working format `RGBAf`, `.straight` input passes the 8-bit values untouched, input `.clampedToExtent()`, CI space origin bottom-left of `inputRect`, y up; `:166`); `EffectKernels.metal` (`:174`); `EffectRunner` (chunked, visible-first, cancellable, `EffectMaskBlend` per tile; `:179`); `EffectSessionController` (`:233`); `EffectDialogView` + `EffectDialogModel` (`:272`); `MainMenu.makeEffectsMenu(registry:)` (`:285`).
- **0032:** `EffectParameterEditor` normalizes every edit in `EffectSessionController.update(_:to:)`.
- **0033 (`docs/specs/todo/0033-levels-and-auto-level_TODO.md`):** the **custom schema-kind pattern** (`Kind.levels(defaultValue:)` + `EffectParameterValue.levels(_)` + typed getter `levels(_:)` with `assertionFailure` + default on a missing/mistyped id; normalization through the value type's own `normalized()`; `EffectParameterText.format` → `""` and `parse` → `nil`; validator check "default == default.normalized()"; `EffectDialogView` renders the kind's control from `UI/EffectControls/`; the control's logic in a pure Core type; `:121-127`, `:179-186`), the **`prepare(values:source:selection:) -> EffectPreparation` hook** called once per render request before the first chunk (`:102-118`; prepared values are never remembered — Repeat re-prepares, like Paint.NET's `OnSetRenderInfo`), `EffectParameterValues.resolving(_:to:)` ("only for `ImageEffect.prepare` results", `:127`), and the session-controller side task pattern (`inputHistogram`, `:177`).
- **0041 (`docs/specs/todo/0041-blur-effects_TODO.md`):** the Effects-menu layout every Effects spec follows (`:39-42`): sources in `PaintDotMac/Core/Effects/Effects/<Category>/<EffectName>.swift`, kernels appended to `EffectKernels.metal` under `// MARK: - <Category>` named after the effect id and added to `CoreImageBridge`'s kernel name list, tests in `PaintDotMacTests/Effects/<Category>/`, oracles in `PaintDotMacTests/Effects/Reference/`, `PaintDotMacTests/Document/<Category>EffectsIntegrationTests.swift`, `PaintDotMacUITests/<Category>EffectsUITests.swift`, and full-list updates of `EffectRegistryTests.standardContents`, `EffectRegistryTests.effectSubmenus`, `MainMenuEffectsTests.effectsMenuItems`, `CoreImageBridgeTests.kernelsLoad`. Neighborhood kernels are general `CIKernel`s with an ROI callback growing the destination rect by `inputPadding`, taps read at exact texel centers. `ReferenceEffectRenderer` dispatches by effect id and reads the whole source surface (`:147`). `UITestApp.chooseMenuItem(_ menu:, _ submenu:, _ item:)` (`:145`). Registry after 0041: ids `["invertColors","brightnessContrast","blackAndWhite","hueSaturation","posterize","sepia","levels","autoLevel","curves","gaussianBlur","motionBlur"]`, `effectSubmenus == [(.blurs, [GaussianBlur, MotionBlur])]`.
- **0025:** `ThumbnailRenderer.render(_ surface:, box:) throws -> ThumbnailImage` (opaque, over the checkerboard; `fittedSize(for:box:)`; `:103`). **0013:** `SelectionMask.bounds` — tight bounds of pixels with coverage > 0 (`:61`).
- **0043/0044** build their registry/menu lists on this spec's ids `"sharpen"`, `"vignette"` and the Photo submenu "Sharpen…", "Vignette…".

**Paint.NET behavior (transcribed from the source cited above).**

- *Sharpen* (`SharpenEffect : LocalHistogramEffect`). One property **Amount, integer 1…20, default 2**, label "Amount"; it is passed as the **radius** of a local histogram (`RenderRect(this.amount, …)`). For each pixel, `RenderRect` keeps per-channel 256-bin histograms (B, G, R, A separately) of the source pixels in a **disk**: offsets `(u, v)` with `u² + v² ≤ cutoff`, `cutoff = ((2r+1)² + 2) / 4` (integer division; "approximately (r + 0.5)²"), **clipped to the image** (offsets outside `[0, W−1] × [0, H−1]` are not counted; `area` = number of counted pixels — edges are *not* replicated). The sliding window update (`leadingEdgeX`, trailing/leading edge add/subtract) is an optimization equal to that direct disk definition. `Apply` → `median = GetPercentile(50, area, …)`, then `ColorBgra.Lerp(src, median, −0.5f)` on all four channels including alpha.
  - `GetPercentile(p, area, h)` per channel: `minCount = area · p / 100`; `b = 0`; skip empty bins (`while b < 255 && h[b] == 0 { b += 1 }`); then `while b < 255 && count < minCount { count += h[b]; b += 1 }`; return `b`. Closed form (proved in *Scope* item 1): with the counted samples sorted ascending `s₁ ≤ … ≤ s_area` and `k = area / 2`: `median = k == 0 ? s₁ : min(255, s_k + 1)`. **The `+1` is a 3.36 quirk** (the loop increments `b` after the bin that reaches `minCount`): a flat area of value 100 has "median" 101 — see *Open questions* 2.
  - `Lerp(from, to, frac)` = `ClampToByte(from + frac·(to − from))` in `float`, `ClampToByte(float)` = `> 255 → 255`, `< 0 → 0`, else `(byte)x` (truncation). With `frac = −0.5` and integer inputs the float math is exact: `out = clamp(trunc(1.5·c − 0.5·m))`, i.e. `n = 3c − m; out = n < 0 ? 0 : min(255, n / 2)`.
- *Vignette* (`VignetteEffect`). Properties **Offset** (`DoubleVectorProperty`, default (0, 0), each component −1…1; display name "Center"; up/down increment 0.01; shown over a thumbnail of the selection bounds with a draggable cross hair), **Radius** (double 0.1…4.0, default 0.5, increment 0.01, exponential slider), **Amount** (double 0…1, default 1.0, increment 0.01, exponential slider; display name "Density" in this source, "Strength" in the Paint.NET 5 docs). `OnSetRenderInfo`, per render:
  ```
  bounds = selection bounds (GetSelection(src.Bounds).GetBoundsInt()) — the whole canvas without a selection
  W = bounds.Width; H = bounds.Height                            (double)
  xC = bounds.Left + W · (1 + offset.x) · 0.5
  yC = bounds.Top  + H · (1 + offset.y) · 0.5                     (canvas y down: +y moves the center down)
  R  = max(W, H) · 0.5 · radius;  R2 = R · R;  radiusR = π / (8 · R2)
  amount1 = 1 − amount
  ```
  `OnRender`, per pixel at integer canvas coordinates `(x, y)`:
  ```
  d = ((y − yC)² + (x − xC)²) · radiusR;  f = cos(d)
  if f <= 0 || d > π { f = amount1 } else { f = amount1 + amount · f⁴ }
  C' = (byte)(0.5 + 255 · ToSrgbClamped(ToLinear(C) · f))   for C ∈ {R, G, B};  A' = A
  ToLinear(C)  = s ≤ 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055)^2.4,  s = C / 255   (256-entry Double table)
  ToSrgb(l)    = l ≤ 0.0031308 ? 12.92 · l : 1.055 · l^(1/2.4) − 0.055;  ToSrgbClamped clamps l to 0…1 first
  ```
  So the darkening is done in **linear light** (Paint.NET's own formula, done inside the effect — Core Image color management stays off, 0031 item 6), the unchanged disk ends where `d = π/2`, i.e. at distance `2R` from the center, and pixels beyond keep `1 − amount` of their linear intensity. Alpha is copied.

## User story

As a photo editor following use case 2, I open **Effects ▸ Photo ▸ Sharpen…**, see **Amount: 2**, raise it and watch fine detail crisp up live; **OK** adds one "Sharpen" step I can undo, and **⌘F** ("Repeat Sharpen") sharpens again. I open **Effects ▸ Photo ▸ Vignette…**, see a thumbnail with a cross hair at the center, **Radius 0.50** and **Strength 1.00**; I drag the cross hair (or type X/Y) to move the focal point onto my subject and lower Strength for a lighter halo, watching the canvas darken toward the edges. With a selection, the vignette centers on the selection and only selected pixels change, with soft edges.

## Scope & changes

Cross-cutting rules (unchanged from 0031/0041): one file per effect conforming to `ImageEffect` with a schema, registered in `EffectRegistry.standard`; no hand-written effect dialog (AGENTS rule 5 — the new `.offset` kind gets a reusable schema control); every pixel change goes through 0031's `EffectSessionController` → `UndoBridge` (preview via `updateLiveState`, step via `commit`); straight 8-bit sRGB storage; rendering off the main actor in 0031's runner; `Core` imports no AppKit/SwiftUI (Core Image, Metal, CoreGraphics allowed, D-19). The only framework additions are the `.offset` kind (following 0033's custom-kind pattern) and a `region:` overload on 0025's `ThumbnailRenderer`; `EffectRunner`, `CoreImageBridge`, `EffectRenderContext` and `EffectTileRenderer` are **unchanged** (Vignette gets its selection bounds through 0033's `prepare` hook).

### Core (pure, headless, unit-tested)

1. **`PaintDotMac/Core/Effects/Effects/Photo/Sharpen.swift`** (new).
   ```swift
   public struct Sharpen: ImageEffect {
       public init()
       public let id = "sharpen"
       public let name = "Sharpen"
       public let category = EffectCategory.photo
       public var parameters: [EffectParameter] {
           [.init(id: "amount", label: "Amount", kind: .integer(range: 1...20, defaultValue: 2))]
       }
       public var alphaMode: EffectAlphaMode { .straight }                   // Paint.NET works on straight BGRA, all four channels
       public func inputPadding(for values: EffectParameterValues) -> Int    // = amount (the disk radius)
       public static func cutoff(radius r: Int) -> Int                       // ((2r+1)² + 2) / 4
       public static func diskOffsets(radius r: Int) -> [(u: Int, v: Int)]   // row-major (v, then u) offsets with u² + v² ≤ cutoff
       public static func median(sortedSamples s: [UInt8]) -> UInt8         // GetPercentile(50) closed form: k = count/2; k == 0 ? s[0] : min(255, s[k−1] + 1)
       public static func sharpenChannel(_ c: UInt8, median m: UInt8) -> UInt8   // n = 3c − m; n < 0 ? 0 : min(255, n / 2)
       public func makeOutput(input: CIImage, values: EffectParameterValues, context: EffectRenderContext) throws -> CIImage
   }
   ```
   - No shortcut (Paint.NET has none; PRD §5.12 lists none); icon `.effect`; menu title "Sharpen…"; dialog row "Amount:" (slider 1…20 + integer field).
   - **Closed form of `GetPercentile(50)` (write this derivation as the doc comment of `median`).** Bins below `s₁` are empty, so the skip loop stops at `b = s₁` with `count = 0`. Each iteration of the second loop adds `h[b]` and increments `b`, so after it `count = #(samples < b)`. It stops at the first `b ≥ s₁` with `#(samples < b) ≥ minCount`, or at 255. If `minCount = 0` (only when `area = 1`) the result is `s₁`. Otherwise the smallest `b` with `#(samples < b) ≥ k` is `s_k + 1`; capped at 255. Areas: `r = 1` → cutoff 2, area 9 (3×3); `r = 2` → cutoff 6, area 21; `r = 3` → 12, 37; `r = 10` → 110, 349; `r = 20` → 420, 1313 (interior; fewer near the canvas edges).
   - **Definition** (the oracle implements exactly 3.36's `RenderRect`; the GPU must equal it **exactly** — all math is integer): for output pixel `(x, y)`, the samples are the source pixels `(x+u, y+v)` for every disk offset that lies inside the canvas (no clamping, no replication — `area` shrinks at the edges); per channel R, G, B, A independently: `m = median(sorted samples)`, `out = sharpenChannel(c, m)`. 1×1 image → `area 1` → `m = c` → `out = c` (unchanged).
   - **`makeOutput`**: `let r = values.integer("amount")`; `let out = context.ciRect(context.outputRect)`; `let canvas = context.ciRect(PixelRect(x: 0, y: 0, width: context.canvasSize.width, height: context.canvasSize.height))`; `try context.kernel("sharpen").apply(extent: out, roiCallback: { _, rect in rect.insetBy(dx: -CGFloat(r), dy: -CGFloat(r)) }, arguments: [input.samplingNearest(), Float(r), Float(Self.cutoff(radius: r)), CIVector(cgRect: canvas)])`; nil → `EffectError.renderFailed`. The kernel excludes taps outside `canvas` itself, so the bridge's `clampedToExtent()` replication never contributes.
   - Sparse layers stay sparse: a fully transparent neighborhood `(0,0,0,0)` gives `m = 1` per channel → `out = 0` → all-zero output tiles stay `nil`.

2. **`PaintDotMac/Core/Effects/Effects/Photo/Vignette.swift`** (new).
   ```swift
   public struct Vignette: ImageEffect {
       public init()
       public let id = "vignette"
       public let name = "Vignette"
       public let category = EffectCategory.photo
       public var parameters: [EffectParameter] {
           [.init(id: "center",   label: "Center",   kind: .offset(defaultValue: .zero, decimals: 2)),
            .init(id: "radius",   label: "Radius",   kind: .double(range: 0.1...4.0, defaultValue: 0.5, step: 0.01, decimals: 2)),
            .init(id: "strength", label: "Strength", kind: .double(range: 0.0...1.0, defaultValue: 1.0, step: 0.01, decimals: 2))]
       }   // order and labels = the Paint.NET 5 docs (Center, Radius, Strength); ranges/defaults = VignetteEffect.cs
       public var alphaMode: EffectAlphaMode { .straight }
       // inputPadding: default 0 (point operation)
       public struct Geometry: Sendable, Equatable { public let centerX: Double; public let centerY: Double; public let radiusR: Double }  // canvas pixel coordinates
       public static func geometry(bounds: PixelRect, center: EffectOffset, radius: Double) -> Geometry      // OnSetRenderInfo
       public static func factor(distanceSquared: Double, radiusR: Double, strength: Double) -> Double         // the f of OnRender
       public enum PreparedKey { public static let centerX = "_centerX"; public static let centerY = "_centerY"; public static let radiusR = "_radiusR" }
       public func prepare(values: EffectParameterValues, source: TiledSurface, selection: SelectionMask?) throws -> EffectPreparation
       public func makeOutput(input: CIImage, values: EffectParameterValues, context: EffectRenderContext) throws -> CIImage
   }
   ```
   - No shortcut; icon `.effect`; menu title "Vignette…".
   - **`geometry`** transcribes `OnSetRenderInfo` exactly as in *Context* (all `Double`; `bounds.minX`, `.minY`, `.width`, `.height` as `Double`; `center.x`/`center.y` are the offset components).
   - **`factor`**: `d = distanceSquared · radiusR`; `(d > .pi || cos(d) <= 0) ? 1 − strength : (1 − strength) + strength · cos(d)⁴` (the `d > π` test first, so `cos` is never needed for huge arguments; for `d ≤ π` it is the same as Paint.NET's order).
   - **`prepare`** (0033's hook — Paint.NET's `OnSetRenderInfo` reads the selection on every render): `let bounds = EffectOffset.referenceBounds(selection: selection, canvasSize: source.size)` (item 3); `let g = Self.geometry(bounds:center: values.offset("center"), radius: values.double("radius"))`; `if values.double("strength") == 0 { return .noChange }` (f = 1 everywhere: byte-identical, see *Edge cases*); else `.render(values.resolving(PreparedKey.centerX, to: .double(g.centerX)).resolving(PreparedKey.centerY, to: .double(g.centerY)).resolving(PreparedKey.radiusR, to: .double(g.radiusR)))`. Prepared values are not remembered (0033 item 4), so Repeat recomputes the center for the then-current selection.
   - **`makeOutput`**: read the prepared geometry with `values[PreparedKey.centerX]` etc. (`.double` cases); if any is missing (programmer error — `prepare` always runs first) → `assertionFailure` and fall back to `geometry(bounds: whole canvas, …)`. `let c = context.ciPoint(x: g.centerX + 0.5, y: g.centerY + 0.5)` — CI destination coordinates are texel centers (`x_ci = x − in.minX + 0.5`, `y_ci = in.maxY − y − 0.5`), so `dest.coord() − c` equals `(x − xC, −(y − yC))`, whose squared length is Paint.NET's `(x − xC)² + (y − yC)²` at integer pixel coordinates. `try context.colorKernel("vignette").apply(extent: context.ciRect(context.outputRect), arguments: [input, CIVector(x: c.x, y: c.y), Float(g.radiusR), Float(values.double("strength"))])`; nil → `.renderFailed`.
   - Sparse layers stay sparse (`(0,0,0,0)` → `(0,0,0,0)`); color under alpha 0 is darkened like any color (0031 *Open questions* 4); alpha is never changed.

3. **`PaintDotMac/Core/Effects/EffectOffset.swift`** (new) — the value type of the new kind (0033 pattern: the value type owns its normalization and pure control math).
   ```swift
   public struct EffectOffset: Sendable, Hashable {
       public var x: Double; public var y: Double                             // each −1…1; (−1,−1) = top-left of the reference bounds, (1,1) = bottom-right, y down
       public static let zero: EffectOffset
       public init(x: Double, y: Double)
       public func normalized(decimals: Int) -> EffectOffset                   // per component: NaN/±inf → 0, clamp −1…1, round to `decimals` (0031's rule: (v·10^d).rounded(.toNearestOrAwayFromZero)/10^d)
       public func point(in bounds: PixelRect) -> (x: Double, y: Double)       // (minX + W·(1+x)·0.5, minY + H·(1+y)·0.5) — the Vignette center formula
       public static func referenceBounds(selection: SelectionMask?, canvasSize: PixelSize) -> PixelRect   // selection?.bounds ?? (0, 0, canvas) — Paint.NET's GetSelection(bounds).GetBoundsInt()
       public init(padLocation p: CGPoint, padSize s: CGSize, decimals: Int)  // crosshair drag: x = 2·p.x/s.width − 1, y = 2·p.y/s.height − 1 (top-left origin, y down), then normalized(decimals:)
       public func padLocation(in s: CGSize) -> CGPoint                        // inverse: ((x+1)/2·w, (y+1)/2·h)
       public static func componentKind(decimals: Int) -> EffectParameter.Kind // .double(range: -1...1, defaultValue: 0, step: 10^-decimals, decimals:) — used by the control's X/Y fields with 0031's EffectParameterText
   }
   ```
   A zero-sized pad (`s.width` or `s.height` ≤ 0) → `.zero` (no division by zero).

4. **`PaintDotMac/Core/Effects/EffectParameter.swift`** (extend 0031 item 1 / 0033 item 6, same pattern as `.levels`):
   - `EffectParameter.Kind.offset(defaultValue: EffectOffset = .zero, decimals: Int = 2)`; `EffectParameterValue.offset(EffectOffset)`; typed getter `public func offset(_ id: String) -> EffectOffset` (missing/mistyped → `assertionFailure` + the schema default, like the others).
   - Normalization: `.offset(v)` → `.offset(v.normalized(decimals:))`; a wrong-case value → the default.
   - `EffectParameterText.format` → `""` and `parse` → `nil` for `.offset` (the control formats its two components through `EffectOffset.componentKind`).
   - `EffectSchemaValidator`: an `.offset` kind reports `decimals` outside 0…4 and a default that differs from `default.normalized(decimals:)`.
   - `EffectParameterMemory` needs no change (an offset is remembered like any value).

5. **`PaintDotMac/Core/Rendering/ThumbnailRenderer.swift`** (extend 0025 item 6): `public func render(_ surface: TiledSurface, region: PixelRect, box: Int = boxPixels) throws -> ThumbnailImage` — identical sampling, checkerboard and cancellation rules, but over `region` (clipped to the canvas; an empty intersection → a 1×1 checker-colored thumbnail) with `fittedSize(for: region.size, box:)`; the existing `render(_:box:)` becomes `render(surface, region: whole canvas, box:)` with byte-identical output (0025's tests unchanged).

6. **`PaintDotMac/Core/Rendering/Shaders/EffectKernels.metal`** (extend 0031/0032/0034/0041) — new section `// MARK: - Photo`; kernel names added to `CoreImageBridge`'s kernel name list: `sharpen`, `vignette`.
   ```metal
   // General kernel. Taps at exact texel centers (integer offsets from dest.coord()); input sampled nearest.
   [[stitchable]] float4 sharpen(coreimage::sampler src, float radius, float cutoff, float4 canvas, coreimage::destination dest) {
       int r = int(radius), co = int(cutoff); float2 c = dest.coord();
       // inCanvas(p): canvas.x <= p.x < canvas.x + canvas.z && canvas.y <= p.y < canvas.y + canvas.w   (canvas = CI rect x, y, w, h)
       // pass 0: area = number of offsets (u, v), u*u + v*v <= co, with inCanvas(c + float2(u, v))
       // k = area / 2
       // 8 radix passes, all four channels at once (int4): t = 0;
       //   for bit 7…0: cand = t | (1 << bit); below = Σ (int4(rint(sample * 255)) < cand) over the same taps; t = select(t, cand, below < k)
       //   → t = k-th smallest sample per channel (largest t with #(samples < t) < k)
       // m = (k == 0) ? self : min(t + 1, 255)                 // self = int4(rint(src.sample(c) * 255)); k == 0 only for area == 1
       // n = 3 * self − m;  o = n < 0 ? 0 : min(n / 2, 255)   // per channel, integer
       // return float4(o) / 255.0
   }
   // Color kernel with destination (point op, straight input).
   [[stitchable]] float4 vignette(coreimage::sample_t s, float2 center, float radiusR, float strength, coreimage::destination dest) {
       float2 q = dest.coord() - center; float d = dot(q, q) * radiusR;
       float f = (d > M_PI_F || precise::cos(d) <= 0) ? 1 - strength : (1 - strength) + strength * pow4(precise::cos(d));
       // per rgb channel: lin = c <= 0.04045 ? c / 12.92 : precise::pow((c + 0.055) / 1.055, 2.4)
       //                  l = clamp(lin * f, 0, 1); e = l <= 0.0031308 ? 12.92 * l : 1.055 * precise::pow(l, 1 / 2.4) - 0.055
       //                  out = floor(0.5 + 255 * e) / 255      (Paint.NET's (byte)(0.5 + 255·…); exact k/255 so the RGBA8 render is exact)
       return float4(out.rgb, s.a);
   }
   ```
   Use `precise::` math so the GPU stays within ±1 of the `Double` oracle. The sharpen kernel's cost is ≈ 9 · area taps per pixel (≈ 190 at the default Amount 2, ≈ 11,800 at Amount 20); if the item 11 performance gate fails, the implementer may replace the kernel body with a faster exact formulation (for example a `CIImageProcessorKernel` with a Metal compute function using threadgroup memory) **as long as `PhotoGoldenTests.sharpen*` still show 0 differences**; record which was used in the Verification status.

7. **`PaintDotMac/Core/Effects/EffectRegistry.swift`** (extend): `standard` appends `Sharpen(), Vignette()` → ids `["invertColors","brightnessContrast","blackAndWhite","hueSaturation","posterize","sepia","levels","autoLevel","curves","gaussianBlur","motionBlur","sharpen","vignette"]`; `adjustments` unchanged; `effectSubmenus` = `[(.blurs, [GaussianBlur, MotionBlur]), (.photo, [Sharpen, Vignette])]` ("Sharpen" < "Vignette"). `EffectSchemaValidator` reports no problems (2 ∈ 1…20; 0.50 on the 0.01 grid from 0.1; 1.00 on the grid from 0; `.offset` default `.zero` normalized).

### Platform glue (covered by integration and UI tests)

8. **`Document/EffectSessionController.swift`** (extend 0031 item 11 / 0033 item 12): `private(set) var offsetUnderlay: ThumbnailImage?` (observable through the dialog model). In `start()`, if any schema parameter is `.offset`, launch a detached task computing `ThumbnailRenderer().render(before.image.layers[idx].surface, region: EffectOffset.referenceBounds(selection: before.selection?.mask, canvasSize: before.image.size), box: OffsetControl.underlayBoxPixels)` and publish it on the main actor; cancelled with the session; the preview never waits for it. Also expose `private(set) var offsetReferenceSize: PixelSize` (the reference bounds' size, for the pad's aspect ratio) set synchronously in `start()`.

9. **`UI/EffectControls/OffsetControl.swift`** (new, SwiftUI; rendering and event forwarding only — all mapping in `EffectOffset`). `static let underlayBoxPixels = 240` (shown at ≤ 120 pt on its long side, aspect = `offsetReferenceSize`). Root identifier `effectDialog.<id>` (Vignette: `effectDialog.center`), accessibility label = the parameter label. Layout (Paint.NET's double-vector control): header text `label` ("Center"); a **pad** `effectDialog.<id>.pad` showing `offsetUnderlay` (a checkerboard placeholder until it arrives) with a cross hair drawn at `value.padLocation(in: padSize)`; click or drag in the pad → `EffectOffset(padLocation:padSize:decimals:)` (drag location clamped to the pad by the normalization); below it two rows **"X:"** and **"Y:"**, each a `Slider` −1…1 step 0.01 (`effectDialog.<id>.x` / `.y`, value = formatted component) and a numeric field (`effectDialog.<id>.x.field` / `.y.field`, formatted and parsed through `EffectParameterText` with `EffectOffset.componentKind(decimals:)`; commit on Tab, focus loss, Return; invalid text reverts). Every change calls the model's `update(id, to: .offset(new))`; normalization happens in the controller (0032's `EffectParameterEditor`).

10. **`UI/EffectDialogView.swift`** (extend 0031/0033/0034): an `.offset` parameter renders `OffsetControl` spanning the dialog width (its header replaces the `"<label>:"` row label, as `.levels`/`.curve` do); `EffectDialogModel` exposes `offsetUnderlay` and `offsetReferenceSize` from the controller and forwards `OffsetControl` edits as `update(id, to: .offset(newValue))`. Everything else (Amount, Radius, Strength rows) is generated as before. Accessibility identifiers used by tests: `effectDialog.amount`, `effectDialog.amount.field`, `effectDialog.center`, `effectDialog.center.pad`, `effectDialog.center.x`, `effectDialog.center.x.field`, `effectDialog.center.y`, `effectDialog.center.y.field`, `effectDialog.radius`, `effectDialog.radius.field`, `effectDialog.strength`, `effectDialog.strength.field`.

11. **`App/MainMenu.swift`** — **no code change**: the Effects menu is generated from the registry and becomes "Repeat" (`menu.effects.repeat`, ⌘F), separator, submenu "Blurs" (0041's items), submenu **"Photo"** (`menu.effects.photo`) with **"Sharpen…"** (`menu.effects.photo.sharpen`, `representedObject` "sharpen", action `runEffect(_:)`, no key equivalent) and **"Vignette…"** (`menu.effects.photo.vignette`, "vignette"). Both go through 0031's `runEffect(_:)` / `repeatLastEffect(_:)` (guards, "Finish Pixels" first, dialog sheet, progress sheet after 0.5 s, `remember` + `recordApplied` on `.done`). Nothing new in `DocumentWindowController`.

12. **`PaintDotMacTests/Effects/Reference/ReferenceEffectRenderer.swift`** (extend 0031/0041): dispatch `"sharpen"` → `SharpenReference` over the **whole source surface** (0041's rule); `"vignette"` → `VignetteReference.apply(_:width:height:geometry:strength:)` using the prepared geometry from the values it is given (the runner passes `prepare`'s result, 0033 item 5).

13. **`project.yml`** — no change (existing globs cover the new files, 0031 already set `MTLLINKER_FLAGS`). Run `xcodegen generate` after adding the files. No new persisted defaults (no `LaunchOptions.resettableKeyPrefixes` change).

No PRD change in this spec (the decisions applied are listed under *Open questions* for the planner to record in PRD §5.9/§12).

## Acceptance criteria

- [ ] Effects ▸ Photo contains "Sharpen…" then "Vignette…", generated from `EffectRegistry.standard`; the Effects menu is "Repeat", separator, "Blurs", "Photo"; no new shortcuts, no duplicates. → `EffectRegistryTests.standardContents`, `.effectSubmenus`, `MainMenuEffectsTests.effectsMenuItems`, `MainMenuTests.noDuplicateShortcuts`, `PhotoEffectsUITests.testPhotoSubmenu`
- [ ] FX-E: Sharpen has **Amount 1…20, default 2** (label "Amount"); Vignette has **Center (−1…1 per axis, default 0,0, 2 decimals)**, **Radius 0.1…4.0, default 0.50**, **Strength 0…1, default 1.00** (labels "Center", "Radius", "Strength"). → `SharpenTests.metadata`, `VignetteTests.metadata`, `EffectSchemaValidatorTests.standardRegistryIsValid`, `PhotoEffectsUITests.testSharpenDefaultsAndOK`, `.testVignetteDefaultsAndCenter`
- [ ] Sharpen equals Paint.NET 3.36 `SharpenEffect` exactly: disk `u²+v² ≤ ((2r+1)²+2)/4` clipped to the canvas, per-channel `GetPercentile(50)` (including the `+1` quirk), `Lerp(src, median, −0.5)` with truncation, alpha included; the GPU result equals the oracle with **0 differences**. → `SharpenTests.*`, `SharpenReferenceTests.*`, `PhotoGoldenTests.sharpen*`
- [ ] Vignette equals Paint.NET's `VignetteEffect` (center/radius from the selection bounds or the canvas, `cos⁴` falloff to `1 − strength`, linear-light scaling, `(byte)(0.5 + 255·…)`, alpha copied) within ±1 per channel on the GPU. → `VignetteTests.*`, `VignetteReferenceTests.*`, `PhotoGoldenTests.vignette*`
- [ ] The `.offset` schema kind normalizes, validates, formats (component fields), is remembered, and drives a generated control with a draggable cross hair over a thumbnail of the reference bounds. → `EffectOffsetTests.*`, `EffectParameterTests.offset*`, `EffectSchemaValidatorTests.offsetProblems`, `ThumbnailRendererTests.region*`, `PhotoEffectsIntegrationTests.offsetUnderlayPublished`, `PhotoEffectsUITests.testVignetteDefaultsAndCenter`
- [ ] Region/tile apron: Sharpen results are independent of chunking for every Amount up to 20; Vignette is a point op with a prepared, chunk-independent center. → `PhotoGoldenTests.sharpenChunkSeamsInvisible`, `.vignetteChunkIndependent`
- [ ] FX-D: with an antialiased selection only selected pixels change, blended by mask coverage; outside pixels are byte-identical; Sharpen reads pixels outside the selection as input; Vignette centers on the selection bounds. → `PhotoGoldenTests.sharpenSelectionBlend`, `PhotoEffectsIntegrationTests.vignetteCentersOnSelection`, `.sharpenSelectionClippedApply`, `PhotoEffectsUITests.testVignetteRespectsSelection`
- [ ] §5.8/FX-C: live preview without a step, Cancel restores exactly, OK commits one step "Sharpen"/"Vignette" (icon `.effect`), undo/redo exact, values remembered for the session (including the center), ⌘F repeats with the same values and no dialog; long runs cancel with an exact restore. → `PhotoEffectsIntegrationTests.*`, `PhotoEffectsUITests.*`
- [ ] Use case 2 now includes Sharpen (PRD §8 M4/M6). → `PhotoEffectsUITests.testSharpenDefaultsAndOK` (manual 4 for the photo workflow)
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **1×1, 1×N, N×1, 2×2 images (Sharpen):** the disk is clipped; 1×1 → area 1 → unchanged; `k = area/2 ≥ 1` otherwise. → `SharpenReferenceTests.tinyImages`, `PhotoGoldenTests.sharpenTinyImagesGPU`
- **Sharpen at the canvas edge:** samples are clipped, not replicated (3×1 `[10,50,90]`, Amount 1 → `[9,69,109]`; replication would give 89 for the last pixel). → `SharpenReferenceTests.edgeClipsNotReplicates`, `PhotoGoldenTests.sharpenEdgeTiles`
- **Flat areas (3.36 quirk):** flat 100 → 99; flat 0 → 0; flat 255 → 255; flat alpha 128 → 127; flat alpha 255 stays 255. → `SharpenReferenceTests.flatAreas`
- **Sparse/transparent layers:** both effects keep fully transparent tiles unallocated (no step if nothing changes); Sharpen next to content may change alpha-0 pixels' color (only towards 0) but never raises alpha 0. → `PhotoEffectsIntegrationTests.sparseTilesStaySparse`
- **Sharpen Amount 20 across tiles / chunks:** apron 20 px; seams invisible. → `PhotoGoldenTests.sharpenChunkSeamsInvisible`
- **Vignette Strength 0:** `prepare` returns `.noChange` → no render, no step (H-6), `lastApplied` still set. (The full formula would also be the identity: `round(255·ToSrgb(ToLinear(c)))== c` for all 256 values — asserted.) → `VignetteTests.strengthZeroIsNoChange`, `VignetteReferenceTests.srgbRoundTripIdentity`, `PhotoEffectsIntegrationTests.strengthZeroAddsNoStep`
- **Vignette Strength 1 beyond the halo** (`d ≥ π/2`): color → 0, alpha kept. Center pixel (`d = 0`) unchanged. → `VignetteReferenceTests.handValues`
- **Center at ±1:** the center lies on (or one past) the bounds edge (`x = L + W` for `x = 1`); still valid. Typed values beyond ±1 clamp. NaN text → reverts (0031 field rule). → `EffectOffsetTests.normalization`, `VignetteTests.geometryAtCorners`
- **Selection bounds:** `SelectionMask.bounds` (tight coverage > 0) may be up to 1 px larger than Paint.NET's path bounds for antialiased shapes — accepted. Repeat with a different selection re-centers (prepared values are not remembered). → `PhotoEffectsIntegrationTests.vignetteCentersOnSelection`, `.vignetteRepeatRecentersOnNewSelection`
- **Huge images (65,535 × 1, 6000 × 4000):** Vignette float precision: `dot(q,q)` up to ~4.3·10⁹ stays within ±1 (golden on 65,535×1); `d > π` is tested before `cos`. → `PhotoGoldenTests.vignetteExtremeAspect`
- **Pad of zero size** (layout not yet done) → offset `.zero`, no crash. → `EffectOffsetTests.zeroPad`
- **Thumbnail underlay:** computed off the main actor, cancelled with the session; never blocks the preview; a cancelled render publishes nothing. → `PhotoEffectsIntegrationTests.offsetUnderlayPublished`, `.cancelBeforeUnderlayDoesNotPublish`
- **Hidden active layer, other layers, floating pixels, GPU unavailable / missing kernel:** 0031's session path ("Finish Pixels" first, hidden layer processed, other layers untouched, "The effect couldn’t be applied." with restore). → `PhotoEffectsIntegrationTests.onlyActiveLayerChanges`, `CoreImageBridgeTests.kernelsLoad`
- **Cancel during a long run** (Sharpen Amount 20 on 2048×2048, or Escape on the progress sheet): exact restore, no step, values not remembered. → `PhotoEffectsIntegrationTests.cancelLongSharpenRestoresExactly`

## Test plan

Expected values come from hand calculation (checked with an independent script while writing this spec), Paint.NET's transcribed source, or the CPU oracles — never from running the code under test. Gray pixels `(v,v,v,255)` are written as `v`.

- **CPU oracles** (`PaintDotMacTests/Effects/Reference/`):
  - `SharpenReference.apply(_ pixels: [ColorRGBA8], width:, height:, amount:) -> [ColorRGBA8]` — a **literal transcription of 3.36 `LocalHistogramEffect.RenderRect`** (per-row histogram initialization, `leadingEdgeX`, the four trailing/leading-edge loops, `area` bookkeeping), `GetPercentile` (the two `while` loops, not the closed form) and `ColorBgra.Lerp(…, −0.5f)` with `Float` math and `ClampToByte(Float)`. Independent of `Sharpen.median`/`sharpenChannel` and of the kernel's radix select.
  - `VignetteReference.apply(_:width:height:bounds:center:radius:strength:)` — literal `OnSetRenderInfo` + `OnRender` in `Double` with `SrgbUtility`'s 256-entry `ToLinear` table, `ToSrgbClamped`, `Math.Cos`, `(byte)(0.5 + …)` truncation; and `apply(_:width:height:geometry:strength:)` (the `OnRender` half) used by `ReferenceEffectRenderer`.
- **Unit — `PaintDotMacTests/Effects/Photo/SharpenTests.swift`:** `metadata` (id "sharpen", name "Sharpen", `.photo`, one parameter `amount` label "Amount" `.integer(1...20, default 2, step 1)`, `menuTitle` "Sharpen…", no shortcut, icon `.effect`, `alphaMode .straight`); `cutoffAndArea` (r 1 → 2/9, 2 → 6/21, 3 → 12/37, 10 → 110/349, 20 → 420/1313; area = `diskOffsets(radius:).count`); `diskShapeRadius2` (contains (2,1), (1,2), (0,2); excludes (2,2)); `inputPaddingEqualsAmount` (1, 2, 20); `medianClosedForm` (`[100]` → 100 (k 0); `[0,0,0,0,200,0,0,0,0]` sorted → 1; nine 100s → 101; `[10,50]` → 11; `[50,90]` → 51; `[255,255,255]` → 255; `[254,255,255,255]` → 255); `medianMatchesGetPercentileLoop` (1,000 seeded sample multisets of size 1…1313: closed form == a test-local transcription of the two-loop `GetPercentile`); `sharpenChannelHand` ((100, 101) → 99; (0, 1) → 0; (200, 1) → 255; (150, 51) → 199; (50, 51) → 49; (101, 100) → 101; (255, 255) → 255; (128, 129) → 127).
- **Unit — `PaintDotMacTests/Effects/Photo/SharpenReferenceTests.swift`** (oracle vs hand math):
  - `edgeClipsNotReplicates`: 3×1 `[10,50,90]`, Amount 1 → `[9,69,109]` (x 0: samples {10,50}, k 1 → m 11 → 19/2; x 1: {10,50,90} → m 11 → 139/2; x 2: {50,90} → m 51 → 219/2), alpha 255.
  - `isolatedPoint`: 5×5 zeros (opaque) with center 200, Amount 1 → center 255 ((600 − 1)/2 clamps), (1,1) 0, (0,0) 0.
  - `thinLineBrightens`: 12×7 background 50 with column 6 = 150, Amount 2 → row 3 = `[49,49,49,49,49,49,199,49,49,49,49,49]`.
  - `barWidthVsAmount`: 40×30 background 50, columns 24…26 = 150 → pixel (25,15): Amount 1, 2 → 149; Amount 3 → 149 at (25,15) and 199 at (24,15); Amount 4, 5, 20 → 199 (more dark than bright samples in the larger disk).
  - `flatAreas`: 4×4 flat 100, Amount 2 → 99; flat (0,0,0,0) → (0,0,0,0); flat 255 → 255; 3×3 flat (100,100,100,128), Amount 1 → (99,99,99,127).
  - `twiceOnThinLine`: the `thinLineBrightens` image sharpened twice (Amount 2): line → 255, background → 48.
  - `tinyImages`: 1×1 (10,20,30,40) any Amount → unchanged; 2×2 seeded and 1×7/7×1 seeded → equal to a test-local naive direct-disk computation.
  - `slidingEqualsDirect`: seeded random 37×23 RGBA (alpha from {0, 1, 77, 128, 254, 255}), Amount ∈ {1, 2, 5, 11, 20}: the transcribed sliding histogram == a naive per-pixel disk + sort + `Sharpen.median` + `Sharpen.sharpenChannel` (exact).
- **Unit — `PaintDotMacTests/Effects/Photo/VignetteTests.swift`:** `metadata` (id "vignette", name "Vignette", `.photo`, parameters in order `center` "Center" `.offset(.zero, 2)`, `radius` "Radius" `.double(0.1...4.0, 0.5, step 0.01, 2)`, `strength` "Strength" `.double(0...1, 1.0, step 0.01, 2)`, `menuTitle` "Vignette…", icon `.effect`, `alphaMode .straight`, `inputPadding == 0`); `geometryDefaults` (bounds (0,0,200,100), center 0, radius 0.5 → center (100, 50), radiusR = π/20,000 (R = 50)); `geometryOffsetAndSelection` (bounds (100,100,200,100), center (0.5, −0.5), radius 1 → center (250, 125), R = 100, radiusR = π/80,000); `geometryAtCorners` (center (1,1) on (0,0,300,200) → (300, 200); (−1,−1) → (0,0)); `factorHand` (d 0 → 1; distance² 2500 with radiusR π/20,000 (d = π/8) → cos⁴(π/8) = 0.728553 (±1e-6); strength 0.5 → 0.864277; d = 0.625π → 0 (strength 1) / 0.5 (strength 0.5); d = 4 → 1 − strength (no cos)); `prepareResolvesGeometry` (600×400 source, selection rect (100,100,200,100) → resolved `_centerX` 200, `_centerY` 150, `_radiusR` π/20,000; no selection → 300, 200, π/(8·150²)); `strengthZeroIsNoChange` (`prepare` → `.noChange`); `prepareDoesNotTouchSchemaValues` (`center`/`radius`/`strength` unchanged in the result).
- **Unit — `PaintDotMacTests/Effects/Photo/VignetteReferenceTests.swift`** (oracle vs hand math; a 200×100 opaque layer, no selection, defaults unless stated):
  - `handValues`: pixel (100,50) of 200 → 200 (d 0); (150,50): 200 → 174, 100 → 86 (d π/8, f 0.728553; hand: 0.5 + 255·ToSrgb(0.577580·f) = 174.04, 86.40); (0,0): 200 → 0 (d 0.625π); strength 0.5: (150,50) 200 → 187, (0,0) 200 → 146; (175,50) of 255 → 112 (d 0.28125π, f 0.161970 → 112.48); radius 1.0, strength 1, (150,50) of 200 → 198; alpha always copied ((150,50) of (200,200,200,77) → (174,174,174,77)).
  - `offsetMovesCenter`: center (−0.5, −0.5) → center (50, 25); pixel (50,25) of 200 → 200.
  - `srgbRoundTripIdentity`: for all c 0…255, `(byte)(0.5 + 255·ToSrgbClamped(ToLinear(c)))` == c.
  - `transparentStaysZero`: (0,0,0,0) → (0,0,0,0) everywhere; (90,60,30,0) at (0,0) → (0,0,0,0) (color under alpha 0 darkened).
- **Unit — `PaintDotMacTests/Effects/EffectOffsetTests.swift`:** `normalization` ((1.5, −2) → (1, −1); (0.123, 0.125) at 2 decimals → (0.12, 0.13); NaN/±inf → 0); `pointInBounds` ((0,0) in (100,100,200,100) → (200,150); (1,1) → (300,200); (−1,−1) → (100,100)); `referenceBounds` (nil selection on 600×400 → (0,0,600,400); selection rect (100,100,200,100) → its mask bounds); `padMapping` (pad 120×80: (60,40) → (0,0); (0,0) → (−1,−1); (120,80) → (1,1); (90,40) → (0.5,0); (−10, 500) → (−1, 1) clamped; `padLocation` inverse round trip for 50 seeded offsets within 1e-9); `zeroPad` (size 0×80 → `.zero`); `componentKind` (`.double(−1…1, 0, step 0.01, decimals 2)`; `EffectParameterText.format(.double(0.5), kind:)` == "0.50").
- **Unit — `PaintDotMacTests/Effects/EffectParameterTests.swift`** (extend): `offsetNormalization` (`.offset((2, 0.555))` → `.offset((1, 0.56))`); `offsetWrongCaseFallsBack` (`.double(1)` for an `.offset` id → default); `offsetTextIsEmpty` (`format` → "", `parse("0.5")` → nil); `offsetGetter` (`offset("center")`); `offsetDefaults` (`defaults(for: Vignette().parameters, …)` → center `.zero`).
- **Unit — `PaintDotMacTests/Effects/EffectSchemaValidatorTests.swift`** (extend): `offsetProblems` (stub with `.offset(defaultValue: (0.123, 0), decimals: 2)` → "default not normalized"; `decimals: 5` → reported); `standardRegistryIsValid` unchanged (now covers Photo).
- **Unit — `PaintDotMacTests/Effects/EffectParameterMemoryTests.swift`** (extend): `offsetRemembered` (remember Vignette with center (0.5, −0.25) → `initialValues` center (0.5, −0.25)).
- **Unit — `PaintDotMacTests/Rendering/ThumbnailRendererTests.swift`** (extend 0025): `regionCropsSource` (400×200 surface, left half red opaque, right half blue opaque; `region: (200,0,200,200)` box 100 → 100×100 all blue); `regionFullCanvasEqualsDefault` (seeded 300×200 → `render(_:region: whole)` == `render(_:box:)` byte-identical); `regionOutsideCanvas` (region (500,500,10,10) on 300×200 → 1×1, no crash).
- **GPU — `PaintDotMacTests/Rendering/CoreImageBridgeTests.swift`** (update 0041's): `kernelsLoad` finds every kernel of the full list `["invertColors","brightnessContrast","blackAndWhite","hueSaturation","channelLookup","luminosityCurve","gaussianBlurVertical","gaussianBlurHorizontal","motionBlur","sharpen","vignette"]` (0041's list + this spec's two).
- **Golden — `PaintDotMacTests/Effects/Photo/PhotoGoldenTests.swift`** (real `CoreImageBridge` + `EffectRunner` with the current `Configuration` defaults unless stated, vs oracle with `GoldenImage.compare`; fixture 600×400 seeded random straight RGBA, alpha from {0, 1, 77, 128, 254, 255}, spanning 3×2 tiles; seed printed; count of ±1 differences reported):
  - `sharpenAmounts`: Amount ∈ {1, 2, 3, 7, 13, 20} → **0 differences** (exact; the tolerance is 0 for Sharpen); `sharpenRandomAmounts` (6 seeded Amounts 1…20, 0 differences).
  - `sharpenChunkSeamsInvisible`: Amount 20, runner with `chunkTiles 1, maxConcurrentChunks 4` == single `bridge.renderEffect` over the whole canvas == oracle (0 differences).
  - `sharpenEdgeTiles`: 257×257 and 300×200 fixtures, Amount 5 → oracle exact; out-of-canvas tile bytes 0.
  - `sharpenTinyImagesGPU`: 1×1, 1×7, 7×1, 2×2, 3×3 with Amount 20 → oracle exact.
  - `sharpenSelectionBlend`: antialiased ellipse `Selection(path:)` + Amount 3 through the runner vs oracle (whole layer) + `MaskBlendReference` (±1); coverage-0 pixels byte-identical.
  - `vignetteGrid`: (center, radius, strength) ∈ {defaults, ((0.5,−0.5), 0.5, 1), ((−1,−1), 4.0, 1), ((1,1), 0.1, 1), ((0,0), 0.1, 0.3), ((0.25,0.75), 2.37, 0.62), ((0,0), 4.0, 0.01)} → ±1; `vignetteRandom` (10 seeded triples, ±1).
  - `vignetteChunkIndependent`: defaults, runner with `chunkTiles 1` == whole-canvas render (0 differences between the two GPU paths).
  - `vignetteSelectionBounds`: selection rect (100,100,200,100) through the runner (prepare → bounds of the selection) vs oracle with `bounds: (100,100,200,100)` + mask blend → ±1; pixels outside the rect byte-identical.
  - `vignetteExtremeAspect`: 65,535×1 seeded row, defaults → ±1.
  - No PNG goldens are recorded: the oracle is the golden.
- **Unit — `PaintDotMacTests/Effects/EffectRegistryTests.swift`** (update 0041's): `standardContents` → the 13 ids in item 7; `effectSubmenus` → `[(.blurs, ["Gaussian Blur", "Motion Blur"]), (.photo, ["Sharpen", "Vignette"])]`; `adjustmentsSortedByName` unchanged.
- **Unit — `PaintDotMacTests/App/MainMenuEffectsTests.swift`** (update 0041's): `effectsMenuItems` → exactly "Repeat" (`f`, ⌘, `repeatLastEffect:`, `menu.effects.repeat`), separator, submenu "Blurs" (`menu.effects.blurs`, 0041's two items unchanged), submenu "Photo" (`menu.effects.photo`) with `[("Sharpen…", "", [], runEffect:, "sharpen", "menu.effects.photo.sharpen"), ("Vignette…", "", [], runEffect:, "vignette", "menu.effects.photo.vignette")]`. `MainMenuTests.noDuplicateShortcuts` still passes.
- **Integration — `PaintDotMacTests/Document/PhotoEffectsIntegrationTests.swift`** (`@MainActor`, real `UndoBridge` with a 600×400 two-layer document, active layer 1 = seeded random, layer 0 opaque; `debounce: .zero`; real `CoreImageBridge` for pixel assertions, gated `ReferenceEffectRenderer` for timing):
  - `sharpenOkCommitsOneStep`: Amount 3 → OK → one step "Sharpen", icon `.effect`; live pixels == oracle exactly; undo → original bytes (tiles share storage with the original); redo → committed bytes exactly.
  - `vignetteOkCommitsOneStep`: defaults → "Vignette"; pixels == oracle ±1; undo/redo exact.
  - `previewWithoutStep` and `cancelRestoresExactly` (both effects; tile storage identity, no step, `!isBusy`).
  - `parameterChangeRerenders`: Sharpen Amount 2 → 9 → committed == Amount 9 oracle; Vignette center (0,0) → (0.5,0.5) → committed == oracle at (0.5,0.5) ±1.
  - `strengthZeroAddsNoStep`: Vignette strength 0 OK → no step, `lastApplied` = vignette.
  - `repeatUsesLastValues`: Sharpen Amount 2 OK, then the Repeat path → two "Sharpen" steps, pixels == oracle applied twice (exact); two undos → original.
  - `valuesRememberedOnOK`: Vignette OK with center (0.5,−0.25), strength 0.4 → `effectMemory.initialValues(for: Vignette())` returns them; a cancelled session with other values → unchanged.
  - `vignetteCentersOnSelection`: layer 1 uniform (200,100,50,255), selection rect (100,100,200,100), defaults → (200,150) == (200,100,50,255) (±1); (250,150) == (174,86,43,255) (±1; hand: B 42.59 → 43); (100,100) == (0,0,0,255); (99,99) byte-identical (outside); the same document **without** a selection → (300,200) unchanged and (200,150) darkened (canvas center differs).
  - `vignetteRepeatRecentersOnNewSelection` (layer 1 uniform (200,100,50,255)): OK with selection A = rect (0,0,300,400) (center (150,200), R 100); change the selection to B = rect (300,0,300,400) via `SelectionCommand`; Repeat → second "Vignette" step centered on B: (450,200) == (200,100,50,255) (B's center), (350,200) == (174,86,43,255) ±1 (distance 100 = R, d = π/8; untouched by the first step because outside A), (150,200) == (200,100,50,255) (A's center, outside B).
  - `sharpenSelectionClippedApply`: selection rect (100,100,200,100), Amount 5 → outside byte-identical; inside == oracle computed on the whole layer (pixels outside feed the disk).
  - `sparseTilesStaySparse`: empty layer 1 → Sharpen 20 and Vignette defaults → no allocated tiles, no step.
  - `onlyActiveLayerChanges`: layer 0 tiles share storage before/after.
  - `offsetUnderlayPublished`: starting a Vignette session publishes `offsetUnderlay` (size = `fittedSize(for: (600,400), box: 240)` = 240×160) and `offsetReferenceSize` (600×400); with selection (100,100,200,100) → 200×100 reference, underlay 240×120; Sharpen sessions leave it `nil`.
  - `cancelBeforeUnderlayDoesNotPublish`: cancel immediately after `start()` → `offsetUnderlay` stays nil after the run loop drains.
  - `cancelLongSharpenRestoresExactly`: 2048×2048 layer, Amount 20, cancel after the first progress callback → every tile shares storage with the original, no step, `!isBusy`.
- **UI — `PaintDotMacUITests/PhotoEffectsUITests.swift`** (pixel checks by ⌘S and decoding the PNG in the test; Sharpen values exact, Vignette ±1; fixtures written with `UITestFixtures.writePNG`):
  - Sharpen fixture: 300×200 background (50,50,50,255), column 100 = (150,150,150,255), columns 199…201 = (150,150,150,255). Vignette fixture: 300×200 filled (200,100,50,255) (0031's fixture).
  - `testPhotoSubmenu`: Effects menu shows "Repeat" (disabled), submenu "Blurs", then submenu "Photo" whose items include "Sharpen…" before "Vignette…" (submenu titles and items asserted as subsequences, so 0043/0044's Noise, Render, Distort, Stylize submenus and P1 photo effects don't break it).
  - `testSharpenDefaultsAndOK`: `chooseMenuItem("Effects", "Photo", "Sharpen…")` → `effectDialog`, `effectDialog.amount.field` "2"; wait `effectDialog.progress` "idle"; OK → last history row "Sharpen"; ⌘S → (100,100) = 199, (101,100) = 49, (200,100) = 149, (10,10) = 49; ⌘Z → ⌘S → (100,100) = 150, (10,10) = 50; ⇧⌘Z → 199 again.
  - `testSharpenAmountAndRepeat`: open Sharpen, type "5⇥" in `effectDialog.amount.field`, wait "idle", OK → ⌘S → (200,100) = 199 (Amount 5 vs 149 at Amount 2), (100,100) = 199; Effects menu shows "Repeat Sharpen"; ⌘F → two "Sharpen" rows, no sheet; ⌘S → (100,100) = 255, (10,10) = 48; reopen → field "5" (remembered); Cancel.
  - `testSharpenCancelRestores`: open, type "20⇥", wait "idle", Escape → no new row, ⌘S → (100,100) = 150, (10,10) = 50; reopen → field "2".
  - `testVignetteDefaultsAndCenter`: `chooseMenuItem("Effects", "Photo", "Vignette…")` → `effectDialog.center.x.field` "0.00", `effectDialog.center.y.field` "0.00", `effectDialog.radius.field` "0.50", `effectDialog.strength.field` "1.00", `effectDialog.center.pad` exists; click the pad at normalized offset (0.75, 0.5) → the X field reads 0.50 ± 0.02 and Y 0.00 ± 0.02; type "0.5⇥" into X and "0⇥" into Y (exact values); wait "idle"; OK → row "Vignette"; ⌘S → (225,100) = (200,100,50,255) (new center), (0,0) = (0,0,0,255), (150,100) = (174,86,43,255) (distance 75 = R, d = π/8). Reopen → X "0.50" (remembered); Cancel.
  - `testVignetteStrengthAndUndo`: defaults but type "0.5⇥" in `effectDialog.strength.field` → OK → ⌘S → (0,0) = (146,71,34,255) ±1 (hand: f 0.5 → 146.81, 71.90, 34.44) and (150,100) = (200,100,50,255); ⌘Z → ⌘S → (0,0) = (200,100,50,255).
  - `testVignetteRespectsSelection`: launch with `-UITestSelectRect 0,0,150,200`; Vignette defaults OK → ⌘S → (75,100) = (200,100,50,255) (selection center; R = 50), (125,100) = (174,86,43,255), (0,0) = (0,0,0,255), (225,100) = (200,100,50,255) exactly (outside).
- **Performance — `PaintDotMacTests/Effects/Photo/PhotoPerformanceTests.swift`** (XCTest `measure`, real bridge, whole-layer `EffectRunner.run` to completion, 6000×4000 opaque seeded layer built once outside the block):
  - `testSharpenDefaultOn24MP` — informational (no PRD target): Amount 2; gate ≤ 2 s. Record the number.
  - `testSharpenAmount20On12MP` — informational: 4000×3000, Amount 20; gate ≤ 30 s (worst case; see item 6's optimization clause). Record the number and which kernel variant was used.
  - `testVignetteOn24MP` — informational: defaults; gate ≤ 1.5 s. Record the number.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build without warnings, all tests pass, none skipped, UI tests ran, launch smoke passes.
- **Manual verification** (look and feel the tests can't judge):
  1. Open a ~4000×3000 photo at 100%, Effects ▸ Photo ▸ Sharpen…, drag Amount 1 → 20: fine detail and edges crisp up, the visible area updates first, no tile seams; Cancel restores the photo. Compare with Paint.NET if available.
  2. Effects ▸ Photo ▸ Vignette…: the pad shows the photo thumbnail with a cross hair; dragging it moves the dark halo's center on the canvas live; Radius widens the bright area; Strength 0.3 gives a light gray halo; the halo is round (circular in image pixels, sized from the longer side), not stretched.
  3. Make an elliptical selection on part of the photo and run Vignette: the pad shows only the selection's bounding box, the halo centers on it, and only the selection changes, with a soft edge.
  4. Use case 2 end to end: open a JPEG, Levels/Curves/Hue-Saturation, Sharpen (default), Resize Image, save as JPEG at a chosen quality — every step works and appears in History.
  5. Dark mode and VoiceOver: "Amount: 2", "Center", "X: 0.00", "Y: 0.00", "Radius: 0.50", "Strength: 1.00" are read correctly; the pad has an accessibility label "Center".

## Open questions

Decided as stated (recommended answers applied in this spec); please confirm and record in PRD.md §5.9/§12:

1. **Sharpen's parameter set is Paint.NET 3.36's single Amount (1–20, default 2, used as the neighborhood radius); Paint.NET 5's Threshold option is not in v1.0.** The Paint.NET 5 docs name Amount and Threshold but give no ranges or defaults, and Paint.NET 5's algorithm isn't published; 3.36's `SharpenEffect` is the last published definition (FX-E fallback). (The planning brief's "Amount default 10" is not what the source says — it is 2.) Recommended: ship Amount only; Threshold can be added later as a schema parameter without breaking remembered values.
2. **Sharpen reproduces 3.36 bit-exactly, including `GetPercentile`'s off-by-one (the "median" is one level above the true median), so flat areas darken by one level (100 → 99, alpha 128 → 127) and repeated Sharpen keeps darkening flats by about one level per pass; edges are clipped, not replicated; alpha is sharpened like a color channel.** These are Paint.NET 3.36's actual results and keep the GPU equal to the oracle with zero differences. Alternative: use the true median (flat areas unchanged). Recommended: keep the exact 3.36 behaviour.
3. **Vignette follows Paint.NET's `VignetteEffect.cs` exactly (Ed Harvey's algorithm: `cos⁴` falloff ending at twice the radius, darkening in linear light, `1 − strength` beyond the halo, always black) with its ranges and defaults (Center −1…1 per axis default (0,0); Radius 0.1–4.0 default 0.5; Amount 0–1 default 1), but labels from the Paint.NET 5 docs ("Strength", not the source's "Density").** The docs give no ranges, and Paint.NET 5's own implementation isn't published; this source file is the only published Paint.NET vignette. Paint.NET's exponential slider scaling for Radius and Strength isn't supported by the 0031 schema, so both sliders are linear (fields accept any value with 2 decimals). Recommended: yes.
4. **Vignette's Center is relative to the selection's bounding box (or the whole canvas without a selection), as in Paint.NET — not always to the canvas.** The pad shows a thumbnail of that box, and Repeat re-centers on the then-current selection. The planning brief suggested canvas-relative semantics; Paint.NET's `OnSetRenderInfo` uses `GetSelection(...).GetBoundsInt()`. Recommended: follow Paint.NET.

## Out of scope

- Other Photo effects: Glow, Soften Portrait, Red Eye Removal (P1, `0065-photo-effects-v1x`, D-26); Paint.NET 5's Straighten (not in PRD).
- Sharpen's Threshold and Paint.NET 5's exponential slider scaling (*Open questions* 1, 3); a colored vignette (Paint.NET's docs point to the Gradient tool instead).
- Add Noise and Clouds (0043), Emboss, Edge Detect, Pixelate (0044) — they follow 0041's layout and this spec's registry/menu list updates.
- Any change to `EffectRunner`, `CoreImageBridge`, `EffectRenderContext` or `EffectTileRenderer` (beyond item 6's kernels), and per-parameter reset buttons in the dialog (0031 out of scope).
- Moving effect shortcuts into `ShortcutTable` (0045; these effects have none).
