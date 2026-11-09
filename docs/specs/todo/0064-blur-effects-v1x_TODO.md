# 0064 — Add Effects ▸ Blurs ▸ Radial Blur, Zoom Blur, Surface Blur and Unfocus (P1)

> Source: PRD.md §5.9 (Blurs, v1.x P1: "Radial, Zoom, Surface, Unfocus"; FX-A, FX-B, FX-C, FX-D, FX-E), §5.8 shared rules (live preview, Cancel, "Repeat last" ⌘F through 0031's single session path), §5.7 H-1 (step names "Radial Blur", "Zoom Blur", "Surface Blur", "Unfocus"), §8 / §12 D-26 (v1.x P1 specs 0052–0069), D-16, D-19, D-22, D-34 (H-6: no-op edits add no step); AGENTS.md architecture rules 1, 2, 3, 4, **5** (one file per effect, schema-generated dialog), **7** (off-main-actor, cancellable, progress), 8.
> Paint.NET docs (fetched 2026-11-08): https://paint.net/doc/latest/EffectsBlursMenu.html (`getpaint.net/doc/latest/…` redirects there). *Radial Blur*: parameters **Center** ("The Center shows where the effect will be interpreted from"; "relocatable": double slider or drag the cross hair in the thumbnail) and **Quality** (low for previews, small images or small angles; high for final quality, large images, large angles); the text refers to the angle without naming a control. *Zoom Blur*: **Distance** ("determines how far the blurring will extend"), **Focus**, **Center** (relocatable, as Radial Blur), **Quality**. *Surface Blur*: **Radius** (sample size; larger samples usually give fewer details) and **Threshold** ("acts as a tolerance level. Low values will yield finer detail while higher values will lose more detail"). *Unfocus*: no section — a note says Paint.NET 5.0 replaced Unfocus with **Bokeh Blur** (Radius, Gamma, Quality). The docs give **no numeric ranges or defaults** for any of the four, so (FX-E fallback) they come from Paint.NET's source, below; see *Open questions* 3–5 for the Paint.NET 5 differences.
> Paint.NET 3.36 source (the last published source), https://github.com/wangdeshui/paint.net: `src/Effects/RadialBlurEffect.cs` (`DoubleProperty(Angle, 2, 0, 360)`, `DoubleVectorProperty(Offset, (0,0), (−2,−2), (+2,+2))`, `Int32Property(Quality, 2, 1, 5)`; `Rotate`, `OnRender`), `src/Effects/ZoomBlurEffect.cs` (`Int32Property(Amount, 10, 0, 100)`, `DoubleVectorProperty(Offset, (0,0), (−2,−2), (+2,+2))`; `OnRender`), `src/Effects/SurfaceBlurEffect.cs` (`Int32Property(Radius, 6, 1, 100)`, `Int32Property(Threshold, 15, 1, 100)`; `PrecalculateIntensityFunction`, `Apply`, `BlurChannel`), `src/Effects/UnfocusEffect.cs` (`Int32Property(Radius, 4, 1, 200)`; `ApplyWithAlpha`), `src/Effects/LocalHistogramEffect.cs` (`RenderRect`, `RenderRectWithAlpha`: disk `cutoff = ((2r+1)² + 2) / 4`, clipped to the image), `src/Core/Utility.cs` `ClampToByte(int)`, `src/Strings/strings.resx` (`RadialBlurEffect.Name` "Radial Blur", `…RadialLabel` "Angle", `…OffsetLabel` "Center", `…QualityLabel` "Quality", `…QualityDescription` "Low quality is useful for quick previews, small images, or small angle values. High quality is useful for final quality, large images, or large angle values."; `ZoomBlurEffect.Name` "Zoom Blur", `…AmountLabel` "Zoom Amount", `…Offset` "Center"; `SurfaceBlurEffect.Name` "Surface Blur", `…RadiusLabel` "Radius", `…ThresholdLabel` "Threshold"; `UnfocusEffect.Name` "Unfocus", `…AmountLabel` "Radius"; all four in `SubmenuNames.Blurs`).
> Milestone: v1.x (P1)
> Depends on: 0051-use-case-acceptance-tests (end of v1.0; this spec builds on the complete P0 effect set), and through it 0031 (effect framework), 0033 (`ImageEffect.prepare`, `EffectPreparation`, `EffectParameterValues.resolving`), **0041** (Blurs layout, kernel/test pattern, `UITestApp.chooseMenuItem(_:_:_:)`, `ReferenceEffectRenderer` whole-source dispatch), **0042** (`.offset` kind + `EffectOffset` + `OffsetControl`, `Sharpen.cutoff(radius:)` / `Sharpen.diskOffsets(radius:)`, the canvas-rect-in-CI kernel argument pattern), 0043/0044 (final P0 registry, menu and kernel lists that this spec extends), 0051 (`UITestApp.replaceText(_:with:commit:)`).

## Context

No application code exists yet; every name below is fixed by a lower-numbered spec.

- **Framework (0031):** `ImageEffect` (`id`, `name`, `category` — `.blurs` exists, menu title "Blurs" — `parameters`, `shortcut` default nil, `historyIcon` default `.effect`, `alphaMode` `.straight`/`.premultiplied`, `inputPadding(for:) -> Int`, `makeOutput(input:values:context:) throws -> CIImage`; `menuTitle` = `name + "…"`); `EffectParameter.Kind` (`.integer(range:defaultValue:step:)`, `.angle(range: ClosedRange<Double> = -180...180, defaultValue:, decimals: 2)` — degrees, 0 = east, counter-clockwise positive; `0031:49`); `EffectRenderContext` (`canvasSize`, `inputRect`, `outputRect`, `ciRect(_:)`, `ciPoint(x:y:)`, `kernel(_:)`); `CoreImageBridge` (working format `RGBAf`, color management off, input from `inputRect` = `outputRect` expanded by `inputPadding(for: values)` and clipped to the canvas (`0031:172`), `.clampedToExtent()`, CI origin bottom-left of `inputRect`, y up; texel centers at `x_ci = x − in.minX + 0.5`, `y_ci = in.maxY − y − 0.5`); `EffectKernels.metal`; `EffectRunner` (512×512 chunks, visible first, cancellable, `EffectMaskBlend` per tile); `EffectSessionController`, `EffectDialogView`, `EffectParameterMemory`, `MainMenu.makeEffectsMenu(registry:)`, `DocumentWindowController.runEffect(_:)` / `repeatLastEffect(_:)`.
- **0033:** `prepare(values:source:selection:) throws -> EffectPreparation` (`.render(values)` / `.noChange`), called once per render request before the first chunk; the runner passes the **prepared** values to every `renderEffect` call, so `inputPadding(for:)` and `makeOutput` see them (`0033:104-127`); prepared values are never remembered (Repeat re-prepares). `EffectParameterValues.resolving(_:to:)` sets a value without normalization.
- **0041 (`docs/specs/todo/0041-blur-effects_TODO.md`):** the per-category layout (`:39-42`), the general-kernel pattern with taps at exact texel centers and explicit float bilinear (`motionBlur`, `:117-131`), the fidelity policy (real-number premultiplied math rounded to nearest, clamp-to-edge, correct alpha; deviations recorded as open questions; literal 3.36 transcriptions used only by fidelity tests), `ReferenceEffectRenderer` dispatch reading the whole source (`:147`), and the Blurs submenu ("Gaussian Blur…", "Motion Blur…").
- **0042 (`docs/specs/todo/0042-photo-effects_TODO.md`):** `EffectParameter.Kind.offset(defaultValue: EffectOffset = .zero, decimals: Int = 2)`, `EffectParameterValues.offset(_:)`, `EffectOffset` (`x`, `y` each −1…1, y down; `point(in: PixelRect)` = `(minX + W·(1+x)·0.5, minY + H·(1+y)·0.5)`; `referenceBounds(selection:canvasSize:)` = selection bounds or the whole canvas; `:113-123`), the generated `OffsetControl` (`effectDialog.<id>`, `.pad`, `.x`, `.x.field`, `.y`, `.y.field`) with a thumbnail underlay of the reference bounds published by `EffectSessionController` for every effect that has an `.offset` parameter (`:164-168`); Vignette's prepared-key pattern (`PreparedKey`, center converted with `context.ciPoint(x: cx + 0.5, y: cy + 0.5)`, `:96-105`); `Sharpen.cutoff(radius:)` = `((2r+1)² + 2) / 4` and `Sharpen.diskOffsets(radius:)` (`:66-67`) — the LocalHistogram disk, reused here, not re-implemented; the `sharpen` kernel's `float4 canvas` (CI rect) argument and in-canvas tap test (`:136-149`).
- **Lists after 0044 (final P0, `0044:79`, `:140-142`):** `EffectRegistry.standard` ids `["invertColors","brightnessContrast","blackAndWhite","hueSaturation","posterize","sepia","levels","autoLevel","curves","gaussianBlur","motionBlur","sharpen","vignette","addNoise","clouds","emboss","edgeDetect","pixelate"]`; `effectSubmenus` `[(.blurs, ["Gaussian Blur","Motion Blur"]), (.distort, ["Pixelate"]), (.noise, ["Add Noise"]), (.photo, ["Sharpen","Vignette"]), (.render, ["Clouds"]), (.stylize, ["Edge Detect","Emboss"])]`; kernel list `["invertColors","brightnessContrast","blackAndWhite","hueSaturation","channelLookup","luminosityCurve","gaussianBlurVertical","gaussianBlurHorizontal","motionBlur","sharpen","vignette","addNoise","clouds","emboss","edgeDetect","pixelate"]`. Specs 0045–0063 change none of these lists. 0045's `effectShortcutsFromTable` iterates the registry; the four new effects have no shortcut (`ShortcutTable.effectChord` returns nil for them — no table change).

**Paint.NET 3.36 behavior (transcribed from the source cited above).** `(x, y)` are integer pixel coordinates (y down), `W × H` the canvas.

- *Radial Blur.* `fcx = (W << 15) + (int)(offsetX · (W << 15))`, `fcy` likewise (16.16 fixed point; the center is `W/2·(1 + offsetX)`, relative to the **whole canvas**, offset range ±2). `n = q²·(30 + q²)` (q 1…5 → 31, 136, 351, 736, 1375). `fr = (int)(angle · π · 65536 / 181)` (note **181**, a 3.36 quirk), `fsr = fr / n` (integer division) — the per-step rotation in 16.16 radians. Per pixel: the pixel itself is one sample; `(fx, fy) = (x << 16) − (fcx, fcy)`; for `i = 1…n` the vector is rotated by `+fsr` (one copy) and `−fsr` (another copy) with `Rotate` (small-angle fixed-point approximation: `fx' = cx − ((cy>>8)·fr>>8) − ((cx>>14)·(fr·fr>>11)>>8)`, `fy' = cy + ((cx>>8)·fr>>8) − ((cy>>14)·(fr·fr>>11)>>8)`, i.e. rotation by `fr/65536` rad with `cos ≈ 1 − φ²/2`), each copy sampled **nearest** at `u = (ox + fcx + 32768) >> 16`, `v = …` and **skipped unless `u > 0 && v > 0 && u < W && v < H`** (row 0 and column 0 are never sampled — a 3.36 bug). So each side sweeps `n · fsr / 65536 ≈ angle · π/181` rad: the blur spans about **±angle** around the pixel. Result: `sa = ΣA`, `sc` = sample count; `sa > 0` → `(ΣA·C / sa, sa / sc)` (truncating, `ClampToByte`), else `(0,0,0,0)`.
- *Zoom Blur.* `fcx = (long)(W · offsetX · 32768) + (W << 15)` (center `W/2·(1 + offsetX)`, whole canvas, ±2). `fz = amount` (0…100), 64 steps: `fx -= ((fx >> 4) · fz) >> 10` (≈ `fx · (1 − amount/16384)`), same for `fy`; sample nearest at `(fx + fcx + 32768) >> 16`, skipped unless inside the canvas (`IsVisible`); the pixel itself is the first sample. Samples lie on the segment from the pixel toward the center, the farthest at `k⁶⁴` of the way (`k = 1 − amount/16384`; amount 100 → 0.676). Result as Radial Blur (alpha-weighted color, mean alpha, truncating).
- *Surface Blur* (`LocalHistogramEffect.RenderRect`): per pixel, unweighted 256-bin histograms of B, G, R over the **disk** `u² + v² ≤ cutoff` **clipped to the image** (taps outside are not counted; no replication). `intensity[d] = max(0, Math.Round(255 − d · (96.0 / threshold), AwayFromZero))` for `d = 0…255`. Per channel with center value `c`: `t = h[bin] · intensity[|bin − c|]`, `sum = Σ t·bin`, `div = Σ t`; `div > 0 → (sum + div/2) / div` (integer, round half up) else `c`. **Alpha is copied unchanged** and color ignores alpha (a transparent pixel's hidden color counts fully).
- *Unfocus* (`RenderRectWithAlpha`): the same clipped disk; histograms are **alpha-weighted** (`h[C] += A`, `sum += A`, `area += 1`). `ApplyWithAlpha`: `C = Σ C·A / (area · 255)` (truncating), `A = ΣA / area` (truncating). That stores the **premultiplied** mean as a straight color: a uniform (200,200,200,128) area comes out (100,100,100,128) — 3.36 darkens semi-transparent content. Opaque content gives the plain disk mean (truncated).

**Fidelity decision applied in this spec (0041's policy; *Open questions* 1–2):** every effect keeps Paint.NET's sample geometry and weights (Radial: `n`, the integer step `fsr`, the 181 divisor, symmetric ±i·φ samples plus the pixel itself, center formula; Zoom: 64 samples at `k^i`, `k = 1 − amount/16384`, plus the pixel; Surface: the clipped disk and the exact integer intensity table; Unfocus: the clipped disk), but is defined in **real-number, premultiplied-alpha math rounded to nearest**: Radial and Zoom sample **bilinearly with clamp-to-edge** (instead of nearest with skipping — this makes the GPU match the oracle within ±1 and removes the row-0/column-0 bug), with exact rotation; Surface Blur weights each tap by `intensity · A` (instead of ignoring alpha) and keeps alpha; Unfocus un-premultiplies (`ΣAC / ΣA`) with mean alpha. Surface Blur and Unfocus keep 3.36's **clipped** disk (the mean is normalized by the counted taps, so clipping has none of the skip-rule artifacts 0041 removed; it also matches 0042's Sharpen). The Radial/Zoom **center** uses 0042's `EffectOffset` (−1…1 over the selection bounds, the same reference the dialog's thumbnail shows) — identical to 3.36's formula without a selection.

## User story

As a Paint.NET switcher, I open **Effects ▸ Blurs** and find, after Gaussian and Motion Blur, **Radial Blur…, Surface Blur…, Unfocus…, Zoom Blur…**. Radial Blur opens with **Angle 2°**, a **Center** pad over a thumbnail of my image with the cross hair in the middle, and **Quality 2**; I drag the cross hair onto a wheel hub, raise the angle and watch it spin live. Zoom Blur gives me a "warp speed" streak toward a center I place the same way. Surface Blur (**Radius 6, Threshold 15**) smooths skin and sky but keeps strong edges sharp; Unfocus (**Radius 4**) gives a soft, even defocus. Each OK adds one history step with the effect's name that I can undo and redo, ⌘F repeats it, Escape cancels a long run with the image restored exactly, and with a selection only the selected pixels change, with soft edges.

## Scope & changes

Cross-cutting rules (unchanged from 0031/0041/0042): one file per effect conforming to `ImageEffect` with a schema, registered in `EffectRegistry.standard`; no hand-written dialog (AGENTS rule 5 — Center uses 0042's generated `.offset` control); every pixel change goes through 0031's `EffectSessionController` → `UndoBridge`; straight 8-bit sRGB storage, premultiplication only inside the kernels (rule 4); rendering off the main actor in 0031's runner (rule 7); `Core` imports no AppKit/SwiftUI (D-19). **No change to any framework API** (`ImageEffect`, `EffectRunner`, `CoreImageBridge`, `EffectRenderContext`, `EffectParameter`, `EffectOffset`, `OffsetControl`, dialog).

**Test-file naming for a P1 spec that adds effects to an existing category:** 0041's per-category files keep their names; this spec adds a second set with the prefix **`BlurV1x`** (`BlurV1xGoldenTests`, `BlurV1xFidelityTests`, `BlurV1xPerformanceTests`, `BlurV1xEffectsIntegrationTests`, `BlurV1xEffectsUITests`). Later P1 specs adding to an existing category (0065 Photo, 0066 Noise/Stylize, 0067 Distort, 0069 Render) use `<Prefix>V1x` the same way; a new category (0068 Artistic, 0069 Object) uses the plain `<Prefix>`.

### Core (pure, headless, unit-tested)

1. **`PaintDotMac/Core/Effects/Effects/Blurs/RadialBlur.swift`** (new).
   ```swift
   public struct RadialBlur: ImageEffect {
       public init()
       public let id = "radialBlur"
       public let name = "Radial Blur"
       public let category = EffectCategory.blurs
       public var parameters: [EffectParameter] {
           [.init(id: "angle",   label: "Angle",   kind: .angle(range: 0...360, defaultValue: 2, decimals: 2)),
            .init(id: "center",  label: "Center",  kind: .offset(defaultValue: .zero, decimals: 2)),
            .init(id: "quality", label: "Quality", kind: .integer(range: 1...5, defaultValue: 2))]
       }   // order = Paint.NET 3.36's property order (Angle, Offset "Center", Quality)
       public var alphaMode: EffectAlphaMode { .straight }          // the kernel premultiplies each texel itself
       public struct Step: Sendable, Equatable { public let samplesPerSide: Int; public let fixedStep: Int; public var radians: Double { Double(fixedStep) / 65536 } }
       public static func step(angle: Double, quality: Int) -> Step   // n = q²(30+q²); fr = Int32(truncating: angle·π·65536/181); fsr = fr / n
       public enum PreparedKey { public static let centerX = "_centerX"; public static let centerY = "_centerY"; public static let padding = "_padding" }
       public static func padding(canvasSize: PixelSize, centerX: Double, centerY: Double, sweep: Double) -> Int
       public func prepare(values: EffectParameterValues, source: TiledSurface, selection: SelectionMask?) throws -> EffectPreparation
       public func inputPadding(for values: EffectParameterValues) -> Int     // prepared `_padding`; missing → 65_535 (whole canvas: correct, slower)
       public func makeOutput(input: CIImage, values: EffectParameterValues, context: EffectRenderContext) throws -> CIImage
   }
   ```
   - No shortcut; icon `.effect`; menu title "Radial Blur…"; dialog rows "Angle:" (slider 0…360 + field, 2 decimals, "°"), the Center pad + X/Y rows (0042), "Quality:" (slider 1…5 + field).
   - **`step`**: `n = q·q·(30 + q·q)`; `fr = Int(angle · Double.pi · 65536.0 / 181.0)` (Double, truncation toward zero, as C#'s `(int)`); `fsr = fr / n` (Swift `/` truncates like C#). Examples (hand/transcribed): (2, 2) → n 136, fr 2274, fsr 16; (30, 1) → 31, 34124, 1100; (360, 5) → 1375, 409499, 297; (0.5, 5) → fsr 0.
   - **`prepare`**: `let s = Self.step(...)`; `s.fixedStep == 0 → .noChange` (every sample is the pixel itself: byte-identical); `let (cx, cy) = values.offset("center").point(in: EffectOffset.referenceBounds(selection: selection, canvasSize: source.size))`; `.render(values.resolving(centerX, to: .double(cx)).resolving(centerY, to: .double(cy)).resolving(padding, to: .integer(Self.padding(canvasSize:centerX:centerY:sweep: Double(s.samplesPerSide) · s.radians))))`.
   - **`padding`** (the apron every sample of every output pixel needs): `dMax` = the largest distance from `(cx, cy)` to the four corner pixels `(0,0)`, `(W−1,0)`, `(0,H−1)`, `(W−1,H−1)`; `chord = 2 · dMax · sin(min(sweep, π) / 2)`; return `min(65_535, Int(chord.rounded(.up)) + 2)` (+1 for the bilinear neighbor, +1 for float slack). A sample's distance from its pixel is a chord of the circle through the pixel around the center, so it never exceeds this.
   - **Definition** (oracle = this; GPU within ±1). With `φ = fixedStep / 65536`, `n = samplesPerSide`, `d = (x − cx, y − cy)`: the `2n + 1` sample positions are `(x, y)` and `(cx, cy) + R(±iφ)·d` for `i = 1…n`, `R(θ)` the exact rotation matrix (`[cos −sin; sin cos]`; the direction is irrelevant because both signs are taken). Each is sampled **bilinearly in premultiplied space** (`ix = floor(p.x)`, `fx = p.x − ix`, the four texels clamped to the canvas, values `(a·rgb, a)`, `a = A/255`), exactly as 0041's Motion Blur. Output = mean of the `2n+1` premultiplied samples, un-premultiplied (`a == 0` → `(0,0,0,0)`), each channel `round(v · 255)` (to nearest).
   - **`makeOutput`**: read `centerX`/`centerY` (`.double`) and the step; missing prepared keys (programmer error) → `assertionFailure` and fall back to the canvas center formula with `values.offset("center")` and no selection. `let c = context.ciPoint(x: cx + 0.5, y: cy + 0.5)`; `try context.kernel("radialBlur").apply(extent: context.ciRect(context.outputRect), roiCallback: { _, rect in rect.insetBy(dx: -pad, dy: -pad) }, arguments: [input, CIVector(x: c.x, y: c.y), Float(step.fixedStep), Float(step.samplesPerSide)])` with `pad = CGFloat(inputPadding(for: values))`; nil → `EffectError.renderFailed`.

2. **`PaintDotMac/Core/Effects/Effects/Blurs/ZoomBlur.swift`** (new).
   ```swift
   public struct ZoomBlur: ImageEffect {
       public init()
       public let id = "zoomBlur"
       public let name = "Zoom Blur"
       public let category = EffectCategory.blurs
       public var parameters: [EffectParameter] {
           [.init(id: "amount", label: "Zoom Amount", kind: .integer(range: 0...100, defaultValue: 10)),
            .init(id: "center", label: "Center",      kind: .offset(defaultValue: .zero, decimals: 2))]
       }   // order and labels = Paint.NET 3.36 (Amount "Zoom Amount", Offset "Center")
       public var alphaMode: EffectAlphaMode { .straight }
       public static let stepCount = 64
       public static func scaleFactor(amount: Int) -> Double          // 1 − amount / 16384 (exact in Float too: 16384 = 2¹⁴)
       public enum PreparedKey { public static let centerX = "_centerX"; public static let centerY = "_centerY"; public static let padding = "_padding" }
       public static func padding(canvasSize: PixelSize, centerX: Double, centerY: Double, amount: Int) -> Int   // min(65_535, ceil((1 − k⁶⁴)·dMax) + 2)
       public func prepare(values: EffectParameterValues, source: TiledSurface, selection: SelectionMask?) throws -> EffectPreparation
       public func inputPadding(for values: EffectParameterValues) -> Int   // prepared `_padding`; missing → 65_535
       public func makeOutput(input: CIImage, values: EffectParameterValues, context: EffectRenderContext) throws -> CIImage
   }
   ```
   - No shortcut; icon `.effect`; menu title "Zoom Blur…"; dialog rows "Zoom Amount:" (slider 0…100 + field), Center pad + X/Y rows.
   - **`prepare`**: `amount == 0 → .noChange`; else center exactly as Radial Blur (`EffectOffset.point(in: referenceBounds)`), padding from `dMax` (same corner rule), resolved under the three keys.
   - **Definition** (oracle = this; GPU within ±1): with `k = scaleFactor(amount)` and `d = (x − cx, y − cy)`, the 65 sample positions are `(cx, cy) + d · kⁱ` for `i = 0…64` (`i = 0` is the pixel itself); bilinear premultiplied clamp-to-edge sampling, mean, un-premultiply, round — as item 1.
   - **`makeOutput`**: `try context.kernel("zoomBlur").apply(extent:, roiCallback: { _, rect in rect.insetBy(dx: -pad, dy: -pad) }, arguments: [input, CIVector(x: c.x, y: c.y), Float(Self.scaleFactor(amount:))])`, `c` as item 1.

3. **`PaintDotMac/Core/Effects/Effects/Blurs/SurfaceBlur.swift`** (new).
   ```swift
   public struct SurfaceBlur: ImageEffect {
       public init()
       public let id = "surfaceBlur"
       public let name = "Surface Blur"
       public let category = EffectCategory.blurs
       public var parameters: [EffectParameter] {
           [.init(id: "radius",    label: "Radius",    kind: .integer(range: 1...100, defaultValue: 6)),
            .init(id: "threshold", label: "Threshold", kind: .integer(range: 1...100, defaultValue: 15))]
       }
       public var alphaMode: EffectAlphaMode { .straight }
       public static func intensityTable(threshold: Int) -> [Int]       // 256 entries, transcription of PrecalculateIntensityFunction
       public func inputPadding(for values: EffectParameterValues) -> Int // = radius
       public func makeOutput(input: CIImage, values: EffectParameterValues, context: EffectRenderContext) throws -> CIImage
   }
   ```
   - No shortcut; icon `.effect`; menu title "Surface Blur…"; rows "Radius:", "Threshold:".
   - **`intensityTable`**: `slope = 96.0 / Double(threshold)`; `table[i] = max(0, Int((255 − Double(i) · slope).rounded(.toNearestOrAwayFromZero)))`. (Hand: threshold 15 → [0] 255, [10] 191, [39] 5, [40] 1, [90] 0.)
   - **Definition** (oracle = this; GPU within ±1): taps = `Sharpen.diskOffsets(radius: r)` (0042) applied at `(x+u, y+v)` and **kept only inside the canvas**. Per channel C ∈ {R,G,B} independently, with `C₀` the center's straight value and `(C_t, A_t)` each tap's straight bytes: `w_t = intensityTable[|C_t − C₀|] · A_t`; `C_out = Σw == 0 ? C₀ : ⌊(Σ w·C_t + ⌊Σw/2⌋) / Σw⌋` (3.36's integer round-half-up); `A_out = A₀`. On opaque images this equals 3.36 **exactly** (the common factor 255 cancels; proved in the oracle doc comment: `⌊(255S + ⌊255D/2⌋)/(255D)⌋ = ⌊(S + ⌊D/2⌋)/D⌋` because `S/D` is a half-integer only when `D` is even).
   - **`makeOutput`**: `let canvas = context.ciRect(PixelRect(x: 0, y: 0, width: W, height: H))`; `try context.kernel("surfaceBlur").apply(extent: context.ciRect(context.outputRect), roiCallback: { _, rect in rect.insetBy(dx: -r, dy: -r) }, arguments: [input, Float(r), Float(Sharpen.cutoff(radius: r)), Float(threshold), CIVector(cgRect: canvas)])`; nil → `.renderFailed`.

4. **`PaintDotMac/Core/Effects/Effects/Blurs/Unfocus.swift`** (new).
   ```swift
   public struct Unfocus: ImageEffect {
       public init()
       public let id = "unfocus"
       public let name = "Unfocus"
       public let category = EffectCategory.blurs
       public var parameters: [EffectParameter] { [.init(id: "radius", label: "Radius", kind: .integer(range: 1...200, defaultValue: 4))] }
       public var alphaMode: EffectAlphaMode { .straight }
       public static func halfWidths(radius r: Int) -> [Int]            // index v + r (v = −r…r): largest u ≥ 0 with u² + v² ≤ Sharpen.cutoff(radius: r)
       public static func prefixPassOffsets(width: Int) -> [Int]        // [1, 2, 4, …] while offset < width (Hillis–Steele scan), at least [1]: width 1 → [1] (that pass only premultiplies)
       public func inputPadding(for values: EffectParameterValues) -> Int   // = radius
       public func makeOutput(input: CIImage, values: EffectParameterValues, context: EffectRenderContext) throws -> CIImage
   }
   ```
   - No shortcut; icon `.effect`; menu title "Unfocus…"; row "Radius:" (slider 1…200 + field).
   - **Definition** (oracle = this; GPU within ±1): taps = the canvas-clipped disk (as item 3); `area` = number of taps; `A_out = round(ΣA / area)`; `C_out = ΣA == 0 ? 0 : round(Σ A·C / ΣA)` (premultiplied mean, un-premultiplied); a fully transparent neighborhood → `(0,0,0,0)`.
   - **`makeOutput`** — O(r) per pixel instead of O(r²) (radius 200 has 126,309 taps): row prefix sums of the premultiplied input over the `inputRect`, then one disk pass that adds, per disk row, `P(x₂) − P(x₁ − 1)`:
     - `var p = input`; for each `(index, offset)` in `prefixPassOffsets(width: inputRect.width)`: `p = try context.kernel("unfocusRowPrefix").apply(extent: context.ciRect(context.inputRect), roiCallback: { _, rect in rect.union(rect.offsetBy(dx: -o, dy: 0)) }, arguments: [p, Float(offset), Float(index == 0 ? 1 : 0)])` (the first pass premultiplies; with width 1 its only pass has no left neighbor and just premultiplies).
     - `return try context.kernel("unfocus").apply(extent: context.ciRect(context.outputRect), roiCallback: { _, _ in context.ciRect(context.inputRect) }, arguments: [p, Float(r), Float(Sharpen.cutoff(radius: r)), CIVector(x: CGFloat(inputRect.width), y: CGFloat(inputRect.height))])`.
     - Clipping to `inputRect` equals clipping to the canvas: `inputPadding == r`, so every in-canvas tap lies in `inputRect`, and `inputRect`'s edges that do not reach `r` past the output are canvas edges.
     - Precision: prefix values are at most the `inputRect` width (≤ 512·`chunkTiles` + 400, i.e. ≤ 1,424 with 0041's tuning range) in `RGBAf`; the float error of a span difference is < 3·10⁻⁴, far below 1/255 after dividing by `area`. A whole-canvas `renderEffect` wider than 4,096 px is not a supported precision regime (the runner never produces one); tests that render a whole canvas in one call stay ≤ 600 px wide.

5. **`PaintDotMac/Core/Rendering/Shaders/EffectKernels.metal`** (extend) — under the existing `// MARK: - Blurs`, a helper and five stitchable general kernels; names added to `CoreImageBridge`'s kernel name list: `radialBlur`, `zoomBlur`, `surfaceBlur`, `unfocusRowPrefix`, `unfocus`. Use `precise::` math.
   ```metal
   // Straight input, explicit bilinear in premultiplied space at exact texel centers; clamp-to-edge comes from the bridge's clampedToExtent input.
   static inline float4 premultipliedBilinear(coreimage::sampler src, float2 p) {       // p in CI coordinates (texel centers at +0.5)
       float2 q = p - 0.5; float2 i0 = floor(q); float2 f = q - i0;
       float4 s00 = src.sample(src.transform(i0 + float2(0.5, 0.5))), s10 = src.sample(src.transform(i0 + float2(1.5, 0.5)));
       float4 s01 = src.sample(src.transform(i0 + float2(0.5, 1.5))), s11 = src.sample(src.transform(i0 + float2(1.5, 1.5)));
       s00.rgb *= s00.a; s10.rgb *= s10.a; s01.rgb *= s01.a; s11.rgb *= s11.a;
       return mix(mix(s00, s10, f.x), mix(s01, s11, f.x), f.y);
   }
   static inline float4 unpremultiplied(float4 p) { return p.a > 0 ? float4(p.rgb / p.a, p.a) : float4(0); }

   [[stitchable]] float4 radialBlur(coreimage::sampler src, float2 center, float fixedStep, float count, coreimage::destination dest) {
       int n = int(count), fs = int(fixedStep); float2 c = dest.coord(); float2 d = c - center;
       float4 acc = premultipliedBilinear(src, c);
       for (int i = 1; i <= n; ++i) {
           float a = float(i * fs) / 65536.0;                       // i·fsr < 2²⁴: exact
           float cs = precise::cos(a), sn = precise::sin(a);
           acc += premultipliedBilinear(src, center + float2(d.x * cs - d.y * sn,  d.x * sn + d.y * cs));
           acc += premultipliedBilinear(src, center + float2(d.x * cs + d.y * sn, -d.x * sn + d.y * cs));
       }
       return unpremultiplied(acc / float(2 * n + 1));
   }
   [[stitchable]] float4 zoomBlur(coreimage::sampler src, float2 center, float k, coreimage::destination dest) {
       float2 c = dest.coord(); float2 d = c - center; float4 acc = premultipliedBilinear(src, c);
       for (int i = 1; i <= 64; ++i) { acc += premultipliedBilinear(src, center + d * precise::pow(k, float(i))); }
       return unpremultiplied(acc / 65.0);
   }
   [[stitchable]] float4 surfaceBlur(coreimage::sampler src, float radius, float cutoff, float threshold, float4 canvas, coreimage::destination dest) {
       // r = int(radius), co = int(cutoff); s0 = src.sample(src.transform(c)); c0 = int3(rint(s0.rgb * 255))
       // for v, u in −r…r with u*u + v*v <= co and inCanvas(c + float2(u, v)) (0042's sharpen test):
       //   t = sample; ti = int3(rint(t.rgb * 255)); at = rint(t.a * 255)
       //   per channel: w = max(0.0, rint_away(255 − float(|ti − c0| * 96) / threshold)) * at      // equals intensityTable (tested)
       //   num += w * ti; den += w
       // out = den > 0 ? floor(num / den + 0.5) : c0;  return float4(out / 255, s0.a)
   }
   [[stitchable]] float4 unfocusRowPrefix(coreimage::sampler src, float offset, float premultiply, coreimage::destination dest) {
       float2 c = dest.coord(); float4 a = src.sample(src.transform(c));
       float4 b = (c.x - offset > 0) ? src.sample(src.transform(c - float2(offset, 0))) : float4(0);
       if (premultiply > 0.5) { a.rgb *= a.a; b.rgb *= b.a; }
       return a + b;                                                // inclusive scan step; the region's first texel center is x = 0.5
   }
   [[stitchable]] float4 unfocus(coreimage::sampler prefix, float radius, float cutoff, float2 size, coreimage::destination dest) {
       // for v in −r…r: y = c.y + v; skip unless 0 < y < size.y
       //   hw = integer half width: u = int(sqrt(float(co − v*v))); fix up with while ((u+1)² + v² <= co) ++u; while (u² + v² > co) --u
       //   x1 = max(c.x − hw, 0.5); x2 = min(c.x + hw, size.x − 0.5)
       //   sum += P(x2, y) − (x1 − 1 > 0 ? P(x1 − 1, y) : 0);  area += x2 − x1 + 1
       // return float4(sum.a > 0 ? sum.rgb / sum.a : 0, sum.a / area)
   }
   ```
   `rint_away(x)` = `round(x)` (Metal's `round` rounds half away from zero, matching `Math.Round(…, AwayFromZero)`); `float(|Δ|·96)/threshold` is the exact quotient rounded once, which never lands on a false `.5` (ties exist only for threshold 64, where `96/64 = 1.5` is exact) — `SurfaceBlurTests.kernelIntensityFormulaMatchesTable` proves the formula equals `intensityTable` for every threshold 1…100 and Δ 0…255 (run in `Float` on the CPU).

6. **`PaintDotMac/Core/Effects/EffectRegistry.swift`** (extend): `standard` appends `RadialBlur(), ZoomBlur(), SurfaceBlur(), Unfocus()` → ids = 0044's 18 + `"radialBlur","zoomBlur","surfaceBlur","unfocus"` (22); `adjustments` unchanged; `effectSubmenus` (category order, names sorted) = `[(.blurs, ["Gaussian Blur","Motion Blur","Radial Blur","Surface Blur","Unfocus","Zoom Blur"]), (.distort, ["Pixelate"]), (.noise, ["Add Noise"]), (.photo, ["Sharpen","Vignette"]), (.render, ["Clouds"]), (.stylize, ["Edge Detect","Emboss"])]`. `EffectSchemaValidator` reports no problems (2.00 ∈ 0…360; `.zero` normalized; 2 ∈ 1…5; 10 ∈ 0…100; 6, 15 ∈ 1…100; 4 ∈ 1…200).

### Platform glue (covered by integration and UI tests)

7. **`App/MainMenu.swift`**, **`UI/EffectDialogView.swift`**, **`UI/EffectControls/OffsetControl.swift`**, **`Document/EffectSessionController.swift`** — **no code change**: the Blurs submenu becomes "Gaussian Blur…", "Motion Blur…", "Radial Blur…" (`menu.effects.blurs.radialBlur`), "Surface Blur…" (`…surfaceBlur`), "Unfocus…" (`…unfocus`), "Zoom Blur…" (`…zoomBlur`), each `representedObject` = id, action `runEffect(_:)`, no key equivalent; the dialogs are generated; the Center underlay is published by 0042's controller because the schema has an `.offset`. Identifiers used by tests: `effectDialog.angle(.field)`, `effectDialog.center`, `effectDialog.center.pad`, `effectDialog.center.x(.field)`, `effectDialog.center.y(.field)`, `effectDialog.quality(.field)`, `effectDialog.amount(.field)`, `effectDialog.radius(.field)`, `effectDialog.threshold(.field)`.

8. **`PaintDotMacTests/Effects/Reference/ReferenceEffectRenderer.swift`** (extend): dispatch `"radialBlur"` → `RadialBlurReference` (center from the prepared `_centerX`/`_centerY` values the runner passes), `"zoomBlur"` → `ZoomBlurReference` (same), `"surfaceBlur"` → `SurfaceBlurReference`, `"unfocus"` → `UnfocusReference`, each reading the **whole source surface** (0041 rule).

9. **`project.yml`** — no change (globs); run `xcodegen generate` after adding files.

No PRD change in this spec (decisions applied are listed under *Open questions* for the planner to record in PRD §5.9/§12).

## Acceptance criteria

- [ ] Effects ▸ Blurs lists "Gaussian Blur…", "Motion Blur…", "Radial Blur…", "Surface Blur…", "Unfocus…", "Zoom Blur…" in that order, generated from the registry; other submenus unchanged; no shortcuts added, no duplicates. → `EffectRegistryTests.standardContents`, `.effectSubmenus`, `MainMenuEffectsTests.effectsMenuItems`, `MainMenuTests.noDuplicateShortcuts`, `BlurV1xEffectsUITests.testBlursSubmenuV1x`
- [ ] FX-E: Radial Blur **Angle 0…360 (2 decimals) default 2, Center (0,0), Quality 1…5 default 2**; Zoom Blur **Zoom Amount 0…100 default 10, Center (0,0)**; Surface Blur **Radius 1…100 default 6, Threshold 1…100 default 15**; Unfocus **Radius 1…200 default 4**; labels and order per items 1–4. → `RadialBlurTests.metadata`, `ZoomBlurTests.metadata`, `SurfaceBlurTests.metadata`, `UnfocusTests.metadata`, `EffectSchemaValidatorTests.standardRegistryIsValid`, `BlurV1xEffectsUITests.testRadialBlurDefaultsAndOK`, `.testZoomBlurDefaultsAndRepeat`, `.testSurfaceBlurDefaults`, `.testUnfocusDefaultsAndCancel`
- [ ] Radial and Zoom Blur use Paint.NET's sample geometry (items 1–2: `n`, integer `fsr` with the 181 divisor, ±iφ pairs plus the pixel; 64 samples at `kⁱ` plus the pixel; center = `EffectOffset.point(in: referenceBounds)`), bilinear premultiplied clamp-to-edge sampling; zero sweep / zero amount is `.noChange`. → `RadialBlurTests.*`, `ZoomBlurTests.*`, `RadialBlurReferenceTests.*`, `ZoomBlurReferenceTests.*`
- [ ] Surface Blur uses the clipped disk, the exact intensity table, alpha-weighted taps, round-half-up and unchanged alpha; on opaque images it equals Paint.NET 3.36 exactly. Unfocus is the clipped-disk premultiplied mean with mean alpha; on opaque images it is within +1 of 3.36. → `SurfaceBlurTests.*`, `UnfocusTests.*`, `SurfaceBlurReferenceTests.*`, `UnfocusReferenceTests.*`, `BlurV1xFidelityTests.*`
- [ ] FX-B: all four run on the GPU through `CoreImageBridge` and match their CPU oracles within ±1 per channel (count of ±1 differences reported). → `BlurV1xGoldenTests.*`, `CoreImageBridgeTests.kernelsLoad`
- [ ] No chunk or tile seams, including Radial/Zoom with samples far from the pixel (padding from `prepare`) and Unfocus/Surface at their maximum radius. → `BlurV1xGoldenTests.chunkSeamsInvisible`, `.paddingCoversAllSamples`
- [ ] FX-D: with an antialiased selection only selected pixels change (blended by coverage), pixels outside are byte-identical and still feed the blur; the Radial/Zoom center follows the selection bounds. → `BlurV1xGoldenTests.selectionBlend*`, `BlurV1xEffectsIntegrationTests.selectionClippedApply`, `RadialBlurTests.prepareUsesSelectionBounds`, `BlurV1xEffectsUITests.testZoomBlurRespectsSelection`
- [ ] §5.8 / FX-C / H-6: live preview without a step, Cancel restores exactly, OK commits one step named "Radial Blur" / "Zoom Blur" / "Surface Blur" / "Unfocus" (icon `.effect`), undo/redo exact, values remembered for the session, ⌘F repeats without the dialog (re-preparing the center), a long run cancels with an exact restore, a no-op run adds no step. → `BlurV1xEffectsIntegrationTests.*`, `BlurV1xEffectsUITests.*`
- [ ] Performance is measured and recorded (no PRD target; informational gates in the test plan). → `BlurV1xPerformanceTests.*`
- [ ] The app launches, opens a PNG and a JPEG, and stays up (quality gate launch smoke).

## Edge cases

- **No-op parameters:** Radial angle with `fsr == 0` (e.g. 0, 0.01, or 0.5 at quality 5) and Zoom amount 0 → `prepare` returns `.noChange` → OK adds no step, `lastApplied` set (H-6). Surface/Unfocus with a uniform opaque image → output equals input → no step. Surface Blur on a hard black/white edge (|Δ| = 255 → weight 0) → unchanged → no step. → `RadialBlurTests.zeroStepIsNoChange`, `ZoomBlurTests.zeroAmountIsNoChange`, `BlurV1xEffectsIntegrationTests.noOpAddsNoStep`
- **Tiny images** (1×1, 1×N, N×1): Radial/Zoom on 1×1 opaque → unchanged (every sample clamps to the pixel); 1×1 `(10,20,30,0)` → `(0,0,0,0)` for Radial, Zoom and Unfocus; Surface Blur keeps it `(10,20,30,0)` (Σw = 0 → `C₀`; alpha copied). Unfocus/Surface radius larger than the image → the clipped disk is the whole image. → `*ReferenceTests.tinyImages`, `BlurV1xGoldenTests.tinyImagesGPU`
- **Center outside the image is not reachable** (`EffectOffset` is −1…1 of the reference bounds; *Open questions* 3). Center at a corner (±1, ±1) → `dMax` = the diagonal; padding correct. → `RadialBlurTests.paddingAtCorner`, `BlurV1xGoldenTests.paddingCoversAllSamples`
- **Angle 360 / quality 5** (sweep ≈ 357°, 2,751 samples): chord bound uses `min(sweep, π)` → `2·dMax`; the whole canvas is read per chunk; cancellable. → `BlurV1xGoldenTests.radialMaxSweep`, `BlurV1xEffectsIntegrationTests.cancelRadialMaxRestoresExactly`
- **Large canvases:** 3.36's `int` fixed point (`x << 16`) overflows for x ≥ 32,768; ours uses `Double`/`Float` positions — a 40,000 × 2 image works. → `BlurV1xGoldenTests.wideImageZoom`
- **Alpha 0 with color:** contributes nothing to Radial/Zoom/Unfocus (premultiplied) or Surface (weight × A); a hidden red under opaque blue neighbors never tints them. → `*ReferenceTests.alphaWeighted`, `BlurV1xGoldenTests.alphaWeighted`
- **Sparse layers:** a fully transparent layer → Radial/Zoom/Unfocus produce `(0,0,0,0)` → tiles stay unallocated; Surface leaves alpha 0 and color under alpha 0 unchanged (byte-identical → no step). → `BlurV1xEffectsIntegrationTests.sparseTilesStaySparse`
- **Edge tiles / non-multiple-of-256 sizes** (257×257, 300×200) and **extreme aspect** (65,535 × 1, Unfocus r 200 through the runner) → oracle match; out-of-canvas tile bytes stay 0. → `BlurV1xGoldenTests.edgeTiles`, `.extremeAspect`
- **Selection:** Radial/Zoom center = `EffectOffset.point(in: selection bounds)`; Repeat after changing the selection re-centers (prepared values not remembered). → `BlurV1xEffectsIntegrationTests.repeatRecentersOnNewSelection`
- **GPU unavailable / kernel missing:** 0031's behavior (items disabled / `EffectError.kernelMissing` → alert, original restored). → `CoreImageBridgeTests.kernelsLoad`

## Test plan

Expected values come from hand calculation, Paint.NET's transcribed definitions, or the CPU oracles — never from the code under test; hand examples avoid `.5` ties. Gray `(v,v,v,255)` is written `v`.

- **CPU oracles** (`PaintDotMacTests/Effects/Reference/`), each independent code (own disk/step/center math, `Double`, straight `[ColorRGBA8]` in/out):
  - `RadialBlurReference.apply(_:width:height:angle:quality:centerX:centerY:)`, `ZoomBlurReference.apply(_:width:height:amount:centerX:centerY:)` — item 1/2 definitions (bilinear on clamped indices, premultiplied, mean, un-premultiply, round to nearest).
  - `SurfaceBlurReference.apply(_:width:height:radius:threshold:)` — integer-exact (`Int64` sums), own disk loop over `u, v ∈ −r…r` with `u² + v² ≤ ((2r+1)² + 2)/4` written inline, own intensity table.
  - `UnfocusReference.apply(_:width:height:radius:)` — direct O(r²) disk sums in `Int64`; `A = (2ΣA + area) / (2·area)`, `C = ΣA == 0 ? 0 : (2ΣAC + ΣA) / (2ΣA)` (round half up).
  - `PaintDotNet336RadialBlur`, `PaintDotNet336ZoomBlur`, `PaintDotNet336SurfaceBlur`, `PaintDotNet336Unfocus` — literal transcriptions (C# `int`/`long` arithmetic with `>>` on negative values as arithmetic shifts, `Rotate`, nearest sampling with 3.36's skip tests including `u > 0 && v > 0`, `ClampToByte`, histogram math). Used only by `BlurV1xFidelityTests`.
- **Unit — `PaintDotMacTests/Effects/Blurs/RadialBlurTests.swift`:** `metadata` (id, name, `.blurs`, parameters/kinds/labels/order per item 1, `menuTitle` "Radial Blur…", no shortcut, icon `.effect`, `.straight`); `stepValues` (the four item 1 examples; (360, 1) → n 31, fsr 13209; (90, 3) → n 351, fsr 291); `sweepApproximatesAngle` (for angles 1…360 step 7 and q 1…5 with `fsr > 0`: `|n·φ − angle·π/181| ≤ (n + 1)/65536`); `zeroStepIsNoChange` (angle 0.5, quality 5 → `.noChange`); `prepareCentersOnCanvas` (600×400, center (0,0) → 300, 200; (−0.5, 0.5) → 150, 300); `prepareUsesSelectionBounds` (selection rect (100,100,200,100), center (0,0) → 200, 150); `paddingValues` (canvas 101×101, center (50.5, 50.5), sweep π/3 → `dMax` = √(50.5²·2) = 71.418 (corner (0,0)) → chord 2·71.418·sin(π/6) = 71.42 → 72 + 2 = 74; sweep ≥ π → `2·dMax` = 142.84 → 143 + 2 = 145); `paddingAtCorner` (center (0,0) on 300×200 → `dMax` = √(299² + 199²) = 359.17, sweep π → chord 718.34 → 719 + 2 = 721); `inputPaddingFallback` (values without `_padding` → 65,535).
- **Unit — `PaintDotMacTests/Effects/Blurs/ZoomBlurTests.swift`:** `metadata`; `scaleFactor` (0 → 1, 10 → 0.9993896484375, 100 → 0.993896484375; `Float(k) == k`); `zeroAmountIsNoChange`; `paddingValues` (amount 100: `1 − k⁶⁴` = 0.32418 (±1e-5); canvas 300×200 center (150,100): `dMax` = √(150² + 100²) = 180.28 → ceil(58.44) + 2 = 61); `prepareUsesSelectionBounds`.
- **Unit — `PaintDotMacTests/Effects/Blurs/SurfaceBlurTests.swift`:** `metadata`; `intensityTableHand` (threshold 15: [0] 255, [10] 191, [39] 5 (5.4), [40] 0 (−1 → 0), [255] 0; threshold 64: [1] 254 (253.5 rounds away), [3] 251 (250.5 → 251); threshold 100: [255] 10 (255 − 244.8 = 10.2)); `kernelIntensityFormulaMatchesTable` (all thresholds × Δ, the kernel's Float formula == table); `inputPaddingEqualsRadius`.
- **Unit — `PaintDotMacTests/Effects/Blurs/UnfocusTests.swift`:** `metadata`; `halfWidths` (r 1 → [1,1,1]; r 4 → [2,3,4,4,4,4,4,3,2]; r 6 → [2,4,5,5,6,6,6,6,6,5,5,4,2]); `halfWidthsMatchSharpenDisk` (for r ∈ {1…10, 50, 200}: `Σ (2·hw+1)` == `Sharpen.diskOffsets(radius:).count`, e.g. r 4 → 69, r 6 → 137, r 200 → 126,309); `prefixPassOffsets` (1 → [1], 2 → [1], 3 → [1,2], 912 → [1,2,…,512] (10 entries)).
- **Unit — oracle hand checks:**
  - `RadialBlurReferenceTests`: `rampMeanX` (201×201 opaque ramp `C = x`, center (100.5, 100.5), angle 30, quality 1 → pixel (150, 100) = 148 (hand: samples' x average `100.5 + 49.5·M`, `M = (1 + 2Σᵢ₌₁³¹ cos(i·1100/65536)) / 63 = 0.954068` → 147.73); `halvesFixture` (300×200, x < 150 black, ≥ 150 white, center (150,100): angle 30 q 1 → (150,50) = 130, (149,50) = 125, (150,100) = 255, (10,10) = 0; angle 2 q 2 → (150,50) = 166, (149,50) = 89); `uniformUnchanged` (9×7 (40,90,200,77), angle 45, q 3); `alphaWeighted` (opaque blue column beside alpha-0 red: no red in the output, alpha mean); `tinyImages`; `pairSymmetry` (mirroring the image and the center about x gives the mirrored result, exact).
  - `ZoomBlurReferenceTests`: `rampRow` (201×1 ramp `C = x`, center (100.5, 0.5): amount 100 → pixel 200 = 183 (`100.5 + 99.5·0.8275192` = 182.84), pixel 0 = 17 (17.33); amount 10 → pixel 200 = 198 (198.08)); `halvesFixture` (center (150,100), amount 100 → (149,100) = 44 (`255·(1 − 0.8275192)` = 43.98), (150,100) = 255, (148,100) = 0; amount 10 → (149,100) = 5 (4.92)); `uniformUnchanged`; `alphaWeighted`; `tinyImages`.
  - `SurfaceBlurReferenceTests`: `row3` (3×1 [100, 110, 200], r 1, T 15 → [104, 106, 200]: (255·100 + 191·110)/446 = 104.28; (191·100 + 255·110)/446 = 105.72; 200's neighbors have Δ 90 → weight 0); `grayHalves` (300×200, x < 150 = 100, else 110, r 6, T 15 → (149,100) = 104 (3,215,120/30,967 = 103.82: 75 taps of 100 × 255, 62 taps of 110 × 191), (150,100) = 106 (106.18), (10,10) = 100); `hardEdgeUnchanged` (black/white halves → identical); `alphaWeighted` (2×1 [(100,100,100,255), (104,104,104,0)], r 1, T 15 → pixel 0 = (100,100,100,255) (the alpha-0 neighbor's weight is 229·0 = 0; 3.36 gives 102 = (255·100 + 229·104)/484 = 101.89, asserted in `BlurV1xFidelityTests.surfaceAlphaIgnored336`), pixel 1 = (100,100,100,0) (its own weight is 255·0, the opaque neighbor's 229·255; alpha kept 0)); `alphaUnchanged` (seeded random: every output alpha == input alpha); `tinyImages`.
  - `UnfocusReferenceTests`: `row5` (5×1 [0,0,255,0,0]: r 1 → pixel 2 = 85, pixel 1 = 85, pixel 0 = 0; r 2 → pixel 2 = 51, pixel 0 = 85 (clipped: 3 taps; clamping would give 51)); `center3x3` (3×3 zeros, center 255, r 1 → center 28 (255/9 = 28.33), corner 64 (255/4 = 63.75, 4 taps)); `blackWhiteHalves` (r 4 → (149,100) = 111 (255·30/69 = 110.87), (150,100) = 144 (144.13)); `alphaWeighted` (3×1 [(200,0,0,255),(0,0,200,0),(0,0,200,0)], r 1 → pixel 1 = (200,0,0,85), pixel 2 = (0,0,0,0)); `uniformSemiTransparentUnchanged` (5×5 (200,200,200,128), r 2 → unchanged); `matchesDirectSum` (seeded 40×30, r 7: oracle == a second naive loop in the test).
- **Fidelity — `PaintDotMacTests/Effects/Blurs/BlurV1xFidelityTests.swift`** (oracle vs literal 3.36; documents deviations):
  - `surfaceOpaqueEqualsPDN336`: seeded opaque 64×48, (r, T) ∈ {(1,15), (6,15), (6,64), (13,100), (30,1)} → identical bytes everywhere (edges included).
  - `unfocusOpaqueWithinOneOfPDN336`: seeded opaque 64×48, r ∈ {1, 4, 9} → `ours − pdn336 ∈ {0, 1}` per channel, alpha 255 both.
  - `unfocusSemiTransparent336Darkens`: uniform (200,200,200,128) 5×5, r 2 → 3.36 gives (100,100,100,128) (200·128/255 = 100.39 truncated), ours unchanged.
  - `zoomSmoothInteriorWithinSix`: smooth opaque 96×64 fixture (bilinear upscale of a seeded 7×5 grid; max gradient ≤ 4 levels/px, asserted on the fixture), center (0,0), amounts {10, 50, 100} → `|ours − pdn336| ≤ 6` per channel (doc comment: nearest rounding moves a sample ≤ 0.71 px → ≤ 2.9 levels; 3.36's shift truncation ≤ 0.01 px; truncation vs rounding ≤ 1; bilinear vs nearest on a ≤ 4 levels/px surface ≤ 2).
  - `radialSmoothCoreWithinSix`: same fixture, center (0,0), (angle, q) ∈ {(10,1), (10,2), (30,1)}, pixels within 20 px of the center whose 3.36 samples never touch row 0/column 0 → `≤ 6` (same derivation plus the small-angle rotation error < 0.01 px at radius ≤ 20).
  - `radialRowZeroSkipped336`: 9×9 opaque image, row 0 red (255,0,0), rows 1…8 blue (0,0,255), angle 90, quality 1, center offset (0,0) → in 3.36 every pixel in rows 1…8 has red 0 (row 0 is never sampled); in ours pixel (0,1) has red > 0 (its rotated samples reach y < 0 and clamp to row 0) — documents the bug fix.
  - `surfaceAlphaIgnored336`: the 2×1 `SurfaceBlurReferenceTests.alphaWeighted` fixture → 3.36 pixel 0 = 102, ours 100.
- **GPU — `PaintDotMacTests/Rendering/CoreImageBridgeTests.swift`** (update 0044's): `kernelsLoad` finds every kernel of the full list `["invertColors","brightnessContrast","blackAndWhite","hueSaturation","channelLookup","luminosityCurve","gaussianBlurVertical","gaussianBlurHorizontal","motionBlur","sharpen","vignette","addNoise","clouds","emboss","edgeDetect","pixelate","radialBlur","zoomBlur","surfaceBlur","unfocusRowPrefix","unfocus"]`.
- **Golden — `PaintDotMacTests/Effects/Blurs/BlurV1xGoldenTests.swift`** (real bridge + runner with prepare, vs oracle, `GoldenImage.compare` ±1, ±1 count reported; 600×400 seeded random straight RGBA fixture with alphas {0, 1, 77, 128, 254, 255}; seed printed; Radial/Zoom oracles get the center computed **in the test** as `W/2·(1+x)`, `H/2·(1+y)` or from the selection rect):
  - `radialGrid`: (angle, q, center) ∈ {(2,2,0) default, (30,1,0), (10,3,(0.4,−0.3)), (90,2,(−1,−1)), (360,1,(1,0.5))}; `radialMaxSweep` (360, 5) on a 200×150 crop of the fixture.
  - `zoomGrid`: (amount, center) ∈ {(10,0) default, (1,0), (50,(0.5,0.5)), (100,(−1,1)), (100,(0.99,−0.99))}.
  - `surfaceGrid`: (r, T) ∈ {(6,15) default, (1,1), (3,100), (20,40), (100,15)}.
  - `unfocusGrid`: r ∈ {1, 4 default, 9, 37, 200}.
  - `chunkSeamsInvisible`: for each effect at a non-trivial setting (Radial 30/1 center (0.3,0.2), Zoom 100, Surface 20/40, Unfocus 37), runner with `chunkTiles 1, maxConcurrentChunks 4` vs one `bridge.renderEffect` over the whole canvas with the same prepared values → 0 differences expected for Radial/Zoom/Surface; Unfocus ±1 (prefix origin differs), count reported.
  - `paddingCoversAllSamples`: Radial (360, 1) and Zoom (100) with center (−1,−1): runner result == whole-canvas render (proves the prepared padding reaches every sample).
  - `edgeTiles` (257×257, 300×200), `tinyImagesGPU` (1×1, 1×7, 7×1, 3×3; Unfocus r 200, Surface r 100), `extremeAspect` (65,535 × 1, Unfocus r 200 and Zoom 100 through the runner), `wideImageZoom` (40,000 × 2, amount 100 → oracle match).
  - `alphaWeighted`: alpha-0 red beside opaque blue → no red tint for all four.
  - `selectionBlendRadial`, `selectionBlendSurface`: antialiased ellipse selection through the runner vs oracle + `MaskBlendReference` ±1; coverage-0 pixels byte-identical; Radial center = the selection bounds' center.
- **Unit — `PaintDotMacTests/Effects/EffectRegistryTests.swift`** (update): `standardContents` → the 22 ids of item 6; `effectSubmenus` → item 6's list; `adjustmentsSortedByName` unchanged. **`PaintDotMacTests/App/MainMenuEffectsTests.swift`** (update): `effectsMenuItems` → "Repeat", separator, submenus `["Blurs","Distort","Noise","Photo","Render","Stylize"]` with Blurs = `[("Gaussian Blur…", …"gaussianBlur"), ("Motion Blur…", …"motionBlur"), ("Radial Blur…", "", [], runEffect:, "radialBlur", "menu.effects.blurs.radialBlur"), ("Surface Blur…", "", [], runEffect:, "surfaceBlur", "menu.effects.blurs.surfaceBlur"), ("Unfocus…", "", [], runEffect:, "unfocus", "menu.effects.blurs.unfocus"), ("Zoom Blur…", "", [], runEffect:, "zoomBlur", "menu.effects.blurs.zoomBlur")]`, other submenus exactly 0044's. `MainMenuTests.noDuplicateShortcuts` passes.
- **Integration — `PaintDotMacTests/Document/BlurV1xEffectsIntegrationTests.swift`** (`@MainActor`, real `UndoBridge`, 600×400 two-layer document, active layer 1 seeded random, layer 0 opaque; `debounce: .zero`; real bridge):
  - `okCommitsOneStep` (parameterized over the four effects at their defaults): OK → one step named exactly "Radial Blur" / "Zoom Blur" / "Surface Blur" / "Unfocus", icon `.effect`; live pixels = oracle ±1; undo → original bytes (tile storage shared); redo → committed bytes.
  - `previewWithoutStep`, `cancelRestoresExactly`, `parameterChangeRerenders` (Unfocus 4 → 12).
  - `noOpAddsNoStep`: Radial angle 0, Zoom amount 0, Surface on a black/white halves layer → no step, `lastApplied` set.
  - `repeatUsesLastValues`: Zoom (40, (0.5, 0)) OK, Repeat → two "Zoom Blur" steps, pixels = oracle applied to the first GPU result ±1; two undos → original.
  - `repeatRecentersOnNewSelection`: Radial OK with selection A, change the selection to B, Repeat → the second pass is centered on B's bounds (oracle ±1 inside B).
  - `valuesRememberedOnOK` (Radial center (0.25, −0.5), quality 4 → `initialValues` returns them; a cancelled session doesn't overwrite).
  - `selectionClippedApply`: rect (100,100,200,100), Unfocus r 10 → outside byte-identical, inside = oracle on the whole layer ±1.
  - `sparseTilesStaySparse`: empty layer → all four leave no allocated tiles and add no step.
  - `onlyActiveLayerChanges`; `cancelRadialMaxRestoresExactly` (2048×2048, angle 360, quality 5, cancel after the first progress callback → tiles share storage, no step, `!isBusy`).
- **UI — `PaintDotMacUITests/BlurV1xEffectsUITests.swift`** (fixture 300×200 PNG, x < 150 black, ≥ 150 white unless stated, via `UITestFixtures.writePNG`; pixels checked by ⌘S + decode; blurred values ±1, untouched exact; fields set with 0051's `replaceText(_:with:commit: "\t")`, then wait for `effectDialog.progress` "idle"):
  - `testBlursSubmenuV1x`: Effects ▸ Blurs items are exactly "Gaussian Blur…", "Motion Blur…", "Radial Blur…", "Surface Blur…", "Unfocus…", "Zoom Blur…".
  - `testRadialBlurDefaultsAndOK`: `chooseMenuItem("Effects", "Blurs", "Radial Blur…")` → `effectDialog.angle.field` "2.00", `effectDialog.center.x.field` "0.00", `.y.field` "0.00", `effectDialog.center.pad` exists, `effectDialog.quality.field` "2"; set angle "30", quality "1"; OK → last row "Radial Blur"; ⌘S → (150,50) = 130, (149,50) = 125, (150,100) = 255, (10,10) = (0,0,0,255); ⌘Z → ⌘S → (150,50) = 255, (149,50) = 0; ⇧⌘Z → 130 again.
  - `testZoomBlurDefaultsAndRepeat`: open Zoom Blur… → `effectDialog.amount.field` "10", `effectDialog.center.x.field` "0.00", `.y.field` "0.00"; set amount "100"; OK → last row "Zoom Blur"; ⌘S → (149,100) = 44, (150,100) = 255, (100,100) = (0,0,0,255); the Effects menu shows "Repeat Zoom Blur" enabled; ⌘F → two "Zoom Blur" rows, no sheet; ⌘S → (150,100) = 255 and (100,100) = 0 still ((150,100) is the center, so all its samples are itself); reopen → amount "100" (remembered); Cancel; ⌘Z twice → ⌘S → (149,100) = 0.
  - `testSurfaceBlurDefaults`: fixture x < 150 = 100, else 110 → open Surface Blur… → `effectDialog.radius.field` "6", `effectDialog.threshold.field` "15"; OK → row "Surface Blur"; ⌘S → (149,100) = 104, (150,100) = 106, (10,10) = 100, (290,10) = 110.
  - `testSurfaceBlurKeepsHardEdgeNoStep`: black/white fixture, Surface Blur defaults, OK → no new history row (H-6); ⌘S → (149,100) = 0, (150,100) = 255.
  - `testUnfocusDefaultsAndCancel`: open Unfocus… → `effectDialog.radius.field` "4"; set "20", wait idle, Escape → no new row, ⌘S → (149,100) = 0 exactly; reopen → field "4"; OK → row "Unfocus"; ⌘S → (149,100) = 111, (150,100) = 144.
  - `testZoomBlurRespectsSelection`: launch with `-UITestSelectRect 0,0,150,200`; Zoom Blur amount 100 → center = the selection's center (75, 100) → (150,100) exactly white (outside), (149,100) = 0 (samples move toward x = 75: all black); (10,10) black.
- **Performance — `PaintDotMacTests/Effects/Blurs/BlurV1xPerformanceTests.swift`** (XCTest `measure`, real bridge, whole-layer runner, opaque seeded 6000×4000 layer built outside the block; heavy cases use `XCTMeasureOptions` with `iterationCount = 3`; all informational, no PRD target — record averages and the chip in the Verification status): `testRadialDefaultsOn24MP` (gate ≤ 10 s), `testZoomDefaultsOn24MP` (≤ 5 s), `testSurfaceDefaultsOn24MP` (≤ 5 s), `testSurfaceRadius100On3MP` (2000×1500, ≤ 60 s — brute-force O(r²) kernel; *Open questions* 6), `testUnfocusRadius200On24MP` (≤ 10 s).
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green (clean build, no warnings, all tests pass, none skipped, UI tests ran, launch smoke).
- **Manual verification:**
  1. Radial Blur on a photo of a wheel: drag the Center cross hair onto the hub, raise Angle to 30: the canvas updates live, visible area first; Quality 1 vs 5 differ visibly only in smoothness; Cancel restores.
  2. Zoom Blur at Zoom Amount 100 with the center on a subject: streaks point toward the center; with a selection, the center follows the selection and only selected pixels change, soft edges.
  3. Surface Blur on a portrait: skin smooths, eyes/hair edges stay sharp; raising Threshold loses more detail; text on transparency keeps its alpha exactly.
  4. Unfocus at radius 200 on a 6000×4000 photo: progress sheet after ~0.5 s, Escape restores with no row; at radius 4 the result looks like a soft defocus without dark fringes on transparent edges.
  5. Compare with Paint.NET (if available) at defaults: Radial/Zoom/Surface/Unfocus look the same to the eye on an opaque photo.
  6. VoiceOver reads "Angle: 2.00°", "Center", "X: 0.00", "Y: 0.00", "Quality: 2", "Zoom Amount: 10", "Radius: 6", "Threshold: 15", "Radius: 4".

## Open questions

Decided as stated (recommended answers applied in this spec); please confirm and record in PRD.md §5.9/§12:

1. **Radial and Zoom Blur fidelity: Paint.NET 3.36's sample geometry (Radial: `n = q²(30+q²)` per side, integer step `fsr = ⌊angle·π·65536/181⌋ / n`, ±i·φ pairs plus the pixel; Zoom: 64 samples at `(1 − amount/16384)ⁱ` plus the pixel) with exact rotation, bilinear premultiplied sampling, clamp-to-edge, rounding to nearest — not 3.36's nearest-neighbor sampling that skips off-image samples and (Radial) never samples row 0 or column 0.** Nearest sampling can't be matched within ±1 between a Float GPU kernel and a Double oracle (a position near a pixel boundary flips to a different pixel), and the row-0/column-0 skip is a bug. Consequences: smoother results; on smooth opaque interiors within ±6 of 3.36; near edges the edge pixels repeat instead of being left out. Recommended: yes.
2. **Surface Blur and Unfocus fidelity: 3.36's clipped disk (`cutoff = ((2r+1)²+2)/4`, taps outside the image not counted) and Surface Blur's exact integer intensity table, but alpha-correct: Surface Blur weights each tap by its alpha (3.36 ignores alpha, so hidden colors under alpha 0 bleed in) and keeps alpha; Unfocus un-premultiplies (3.36 writes the premultiplied mean as a straight color, darkening semi-transparent areas: (200,200,200,128) → (100,100,100,128)) and rounds instead of truncating.** Consequences: Surface Blur is byte-identical to 3.36 on opaque images; Unfocus is within +1 there. The disk stays clipped rather than clamp-to-edge (0041's rule) because a normalized mean over the counted taps has no edge artifact, and 0042's Sharpen uses the same clipped disk. Recommended: yes.
3. **Center for Radial and Zoom Blur uses 0042's `.offset` control: −1…1 over the selection bounds (the whole canvas without a selection), the same reference as the dialog thumbnail — not 3.36's ±2 over the whole canvas.** Without a selection the center formula equals 3.36's for offsets within ±1; centers outside the image (3.36's ±1…±2) are not reachable; with a selection the center follows the selection like Vignette (0042) and Paint.NET 5's selection-relative thumbnails. Extending `.offset` with a range would change 0042's API. Recommended: yes, keep −1…1 for v1.x.
4. **Zoom Blur keeps Paint.NET 3.36's single "Zoom Amount" (0…100, default 10) and Center; Paint.NET 5's documented Distance, Focus and Quality are not implemented, and Radial Blur has no Paint.NET 5 extras beyond Angle, Center, Quality.** The docs name Distance/Focus/Quality without ranges, defaults or formulas, and Paint.NET 5's algorithm isn't published; 3.36's is. Label "Zoom Amount" is Paint.NET's own string for this parameter. Recommended: yes (Paint.NET 5's options can be added later as schema parameters).
5. **Unfocus stays (PRD §5.9 lists it as P1) with 3.36's single Radius 1…200, default 4, although Paint.NET 5 replaced it with Bokeh Blur (P2 in the PRD).** Recommended: yes.
6. **Surface Blur's GPU kernel is brute force, O(r²) taps per pixel (radius 100 = 31,757 taps; seconds on a few megapixels), and only measured informationally; Unfocus uses an O(r) row-prefix-sum formulation.** No PRD performance target covers P1 effects; the runner keeps the UI responsive and cancellable. Recommended: accept, and revisit in a performance pass if users report it.

## Out of scope

- Fragment and Bokeh blurs (P2), Paint.NET 5's Zoom Blur Distance/Focus/Quality and other v5-only options (*Open questions* 4).
- Other P1 effects: Glow, Soften Portrait, Red Eye Removal (0065); Median, Reduce Noise, Outline, Relief (0066); Bulge, Twist, Polar Inversion, Tile Reflection (0067); Artistic (0068); Render/Object (0069).
- Any framework change (`ImageEffect`, `EffectRunner`, `CoreImageBridge`, `.offset`/`EffectOffset`/`OffsetControl`, dialog), and centers outside the reference bounds (*Open questions* 3).
- Effect shortcuts (none; 0045's table is unchanged).
