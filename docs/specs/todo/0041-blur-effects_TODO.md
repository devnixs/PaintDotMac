# 0041 — Add Effects ▸ Blurs ▸ Gaussian Blur and Motion Blur (first Effects-menu category) and measure NF-3

> Source: PRD.md §5.9 (Blurs, v1.0 P0: "Gaussian Blur, Motion Blur"; FX-A, FX-B, FX-C, FX-D, FX-E), §5.8 shared rules (live preview, Cancel, "Repeat last" ⌘F — they apply to effects through 0031's single session path), §6 **NF-3** ("Gaussian Blur (radius 20) on a 24 MP layer finishes in under 500 ms on an M1"), §5.7 H-1 (step name "Gaussian Blur"), §12 D-16, D-19, D-22, D-34 (H-6); AGENTS.md architecture rules 1, 2, 3, 4, **5** (one file per effect, schema-generated dialog), **7** (off-main-actor, cancellable, progress), 8.
> Paint.NET docs (fetched 2026-11-08): https://paint.net/doc/latest/EffectsBlursMenu.html (linked from https://paint.net/doc/latest/EffectsMenu.html; `getpaint.net/doc/latest/…` redirects there). *Gaussian Blur*: "applies the well known Gaussian blur formula to the image … **Radius**. This a measure of how strong the effect is. **Gamma Boost** … **Quality** …". *Motion Blur*: "The **Angle** of apparent motion is configurable as is the **Distance**, which is a measure of how far the effect shifts the original pixels. The **Centered** checkbox when checked will apply the blur from the center outwards. **Edge Behavior**: Options are Clamp, Wrap, Mirror and Transparent." The docs give **no numeric ranges or defaults**, so (FX-E fallback) they come from Paint.NET's source, below. Gamma Boost, Quality and Edge Behavior are Paint.NET 5 additions — see *Open questions* 3.
> Paint.NET 3.36 source (last published source), https://github.com/wangdeshui/paint.net: `src/Effects/GaussianBlurEffect.cs` (`new Int32Property(Radius, 2, 0, 200)`; `CreateGaussianBlurRow`; `OnRender`), `src/Effects/MotionBlurEffect.cs` (`new DoubleProperty(Angle, 25, -180, +180)`, `new BooleanProperty(Centered, true)`, `new Int32Property(Distance, 10, 1, 200)`; `OnSetRenderInfo` sample path; `OnRender`), `src/Core/Surface.cs` `GetBilinearSample(float,float)`, `src/Core/ColorBgra.cs` `BlendColors4W16IP`, `Blend(ColorBgra*, int)`, `Transparent`, `src/Core/Utility.cs` `Lerp(PointF, PointF, float)`, `src/Strings/strings.resx` (`BlurEffect.Name` "Gaussian Blur", `BlurEffect.ConfigDialog.SliderLabel` "Radius", `MotionBlurEffect.Name` "Motion Blur", `MotionBlurEffectConfigDialog.AngleHeader.Text` "Angle", `…DistanceHeader.Text` "Distance", `…CenteredCheckBox.Text` "Centered", submenu "Blurs").
> Milestone: M6
> Depends on: 0031-effect-framework-and-first-adjustments (effect framework), and — by filename order only, for the exact registry/menu lists the tests update — 0032, 0033, 0034 (adjustments appended to `EffectRegistry.standard`). No other dependency.

## Context

No application code exists yet; every name below is fixed by a lower-numbered spec.

- **Effect framework (0031, `docs/specs/todo/0031-effect-framework-and-first-adjustments_TODO.md`):**
  - `ImageEffect` (item 2, `:94`): `id`, `name`, `category: EffectCategory` (`.blurs` exists, menu title "Blurs"), `parameters: [EffectParameter]`, `shortcut` (default nil), `historyIcon` (default `.effect` for non-adjustments), `alphaMode: EffectAlphaMode` (`.straight` / `.premultiplied`), **`inputPadding(for:) -> Int`** (source pixels needed around each output pixel — the apron), `makeOutput(input:values:context:) throws -> CIImage`; `menuTitle` = `name + "…"` when it has parameters.
  - `EffectParameter.Kind` (item 1, `:43`): `.integer(range:defaultValue:step:)`, `.bool(defaultValue:)`, `.angle(range: -180...180, defaultValue:, decimals: 2)` (degrees, 0 = east, counter-clockwise positive), …; `EffectParameterValues` typed getters `integer(_:)`, `bool(_:)`, `angle(_:)`.
  - `EffectRenderContext` (`:114`): `canvasSize`, `inputRect`, `outputRect`, `ciRect(_:)`, `ciPoint(x:y:)`, `colorKernel(_:)`, **`kernel(_:) -> CIKernel`** (general kernels from the bridge's cache).
  - `CoreImageBridge` (item 6, `:166`): one Metal-backed `CIContext`, working space `NSNull`, **working format `RGBAf`** (so intermediates between two kernels are 32-bit float, never 8-bit), color management off end to end, input `CIImage` made from `inputRect` (= `outputRect` expanded by `inputPadding`, clipped to the canvas), `.premultiplyingAlpha()` for `.premultiplied` effects, then **`.clampedToExtent()` — samples beyond the canvas replicate the nearest edge pixel**; output cropped to `ciRect(outputRect)`, `.unpremultiplyingAlpha()` for `.premultiplied`, rendered to straight RGBA8. CI space within a region: origin bottom-left of `inputRect`, y up (`ciPoint(x, y) = (x − in.minX, in.maxY − y)`).
  - `EffectKernels.metal` (item 7, `:174`): stitchable Core Image kernels compiled into the app's default library; the bridge loads them by name.
  - `EffectRunner` (item 8, `:179`): chunked (`Configuration.chunkTiles = 2` → 512×512 px, `maxConcurrentChunks = 2`), visible chunks first, cancellable (`Task.checkCancellation` per chunk), monotonic `EffectProgress`, per tile `EffectMaskBlend.blendTile` with the selection mask (FX-D antialiased edges). Its "NF-3 design" bullet (`:208`) says chunk size and concurrency are configuration "so 0041 can tune them against NF-3 without API changes".
  - `EffectSessionController` (item 11), `DocumentWindowController.runEffect(_:)` / `repeatLastEffect(_:)` (item 13), `EffectDialogView` (item 15, identifiers `effectDialog`, `effectDialog.<id>`, `effectDialog.<id>.field`, `effectDialog.progress` "rendering"/"idle", `effectDialog.ok`/`.cancel`), `EffectProgressView` (item 16), `EffectParameterMemory` (per-session memory, Repeat slot "Repeat <name>").
  - `MainMenu.makeEffectsMenu(registry:)` (item 17, `:287`): first item **Repeat** (`menu.effects.repeat`, ⌘F), then — "if `effectSubmenus` is non-empty" — a separator and one submenu per category (`menu.effects.<category>`, items `menu.effects.<category>.<id>`); "0041 adds the first submenu". 0031 already builds and unit-tests this with a stub registry (`MainMenuEffectsTests.submenusFromStubRegistry`).
  - Test support: CPU oracles in `PaintDotMacTests/Effects/Reference/`, `ReferenceEffectRenderer: EffectTileRenderer` (wraps an oracle so runner/session tests run without the GPU), `MaskBlendReference`, `GoldenImage.compare` (±1, 0024), `SeededRandom`, `TestImages` (0002), `UITestApp` (`launch(opening:extraArguments:)`, `chooseMenuItem(_ menu:, _ item:)` (0001 `:221`), `menuItem`, `saveThroughPanel`), `UITestFixtures.writePNG`, `-UITestSelectRect x,y,w,h` (0013).
- **Registry before this spec (0034 item 6):** `EffectRegistry.standard` ids `["invertColors","brightnessContrast","blackAndWhite","hueSaturation","posterize","sepia","levels","autoLevel","curves"]`; `effectSubmenus` is empty; 0035–0040 add no effects.

**Paint.NET 3.36 behavior (transcribed from the source cited above).**
- *Gaussian Blur.* `radius == 0` → copy the source unchanged. Otherwise `CreateGaussianBlurRow(r)` gives `w[i] = 16·(i+1)` for `i ≤ r`, mirrored — a **tent** (triangle) of length `2r+1` with center weight `16(r+1)` and end weights 16; the 2-D weight is `w[wx]·w[wy]` (separable). Out-of-image taps are **skipped** and the weight sum renormalizes over in-image taps. Colors are alpha-weighted: per tap `wp = (w[wy]·(A + (A>>7))) >> 8`, color sums `Σ w[wx]·wp·C`, divided (truncating) by `(Σ w[wx]·w[wy]·(A + (A>>7))) >> 8`; alpha `= Σ w[wx]·wp·A / Σ w[wx]·w[wy]`. That alpha formula multiplies by `A` twice, so a uniform layer of alpha 128 comes out with alpha 64 (hand-checked in *Test plan*): 3.36 fades semi-transparent content. A pixel whose neighborhood is fully transparent becomes `(0,0,0,0)`.
- *Motion Blur.* `θ = (angle + 180)·2π/360`; `end = (d·cos θ, −d·sin θ)` (canvas y down), `start = (0,0)`; if **Centered**: `start = −end/2`, `end = end/2`. `n = ((1 + d)·3) / 2` (integer division) sample offsets `points[j] = Lerp(start, end, j/(n−1))` in `float` (`n == 1` → `(0,0)`). So the samples trail **opposite** the motion direction (non-centered) or straddle the pixel (centered). Per output pixel `(x, y)`: each sample at `(x, y) + points[j]` that lies inside `[0, W−1] × [0, H−1]` is taken with `GetBilinearSample` (8-bit fixed-point fractions, alpha-weighted `BlendColors4W16IP`); samples outside are **skipped**; the result is `ColorBgra.Blend` (alpha = mean of alphas, color = `Σ A·C / Σ A`, truncating; zero samples → `Transparent` = (255,255,255,0)).

**Fidelity decision applied in this spec (*Open questions* 1, 2):** both effects keep Paint.NET's **weights and sample geometry exactly** (tent weights `r+1−|i|`; the motion sample path, sample count and Float offsets), but are defined in **real-number, premultiplied-alpha math rounded to nearest**, with **clamp-to-edge** sampling (0031's bridge already clamps) and a **correct alpha** (`ΣwA / Σw`). This is what a GPU kernel can reproduce within ±1 of a CPU oracle (FX-B); a bit-exact 3.36 port cannot be done on the GPU (64-bit integer sums), and `CIGaussianBlur` cannot meet a ±1 oracle (its kernel truncation and downsampling for large sigma are internal). Agreement with literal 3.36 transcriptions is still tested where the definitions coincide (opaque interiors).

## User story

As a Paint.NET switcher, I open **Effects ▸ Blurs ▸ Gaussian Blur…**, see **Radius: 2**, drag it and watch the canvas blur live (visible area first), and **OK** adds one "Gaussian Blur" step I can undo; a radius-20 blur on a 24-megapixel photo finishes in about half a second. I open **Effects ▸ Blurs ▸ Motion Blur…** with **Angle 25°, Distance 10, Centered** on, change them, and get a directional streak; with a selection only the selected pixels change, with soft edges. **⌘F** ("Repeat Motion Blur") applies it again without the dialog, and Escape on a long run cancels it with the image exactly restored.

## Scope & changes

Cross-cutting rules: one file per effect conforming to `ImageEffect` with a schema, registered in `EffectRegistry.standard`; no hand-written dialog (AGENTS rule 5); every pixel change goes through 0031's `EffectSessionController` → `UndoBridge` (preview via `updateLiveState`, step via `commit`); storage stays straight 8-bit sRGB (premultiplication happens only inside the GPU kernels / bridge, rule 4); rendering stays off the main actor in 0031's runner (rule 7); `Core` imports no AppKit/SwiftUI (Core Image + Metal allowed, D-19). **No change to any 0031 API.**

**Layout established here for every Effects-menu spec (0042–0044, 0064–0069 follow it exactly):**
- Source: `PaintDotMac/Core/Effects/Effects/<Category>/<EffectName>.swift` (category folder = `EffectCategory` case title-cased: `Blurs`, `Photo`, `Noise`, `Render`, `Stylize`, `Distort`, `Artistic`, `Object`), one `public struct <EffectName>: ImageEffect` per file, plus its pure helper functions as `static` members of that struct.
- Kernels: appended to `PaintDotMac/Core/Rendering/Shaders/EffectKernels.metal` under a `// MARK: - <Category>` comment, named `<effectID>` or `<effectID><Pass>` (camelCase), and added to `CoreImageBridge`'s kernel name list.
- Tests: `PaintDotMacTests/Effects/<Category>/<EffectName>Tests.swift` (metadata + pure helpers + oracle hand checks), `PaintDotMacTests/Effects/<Category>/<Prefix>GoldenTests.swift` (GPU vs oracle), `PaintDotMacTests/Effects/<Category>/<Prefix>PerformanceTests.swift` (when the spec measures performance), `PaintDotMacTests/Effects/Reference/<EffectName>Reference.swift` (oracle), `PaintDotMacTests/Document/<Prefix>EffectsIntegrationTests.swift`, `PaintDotMacUITests/<Prefix>EffectsUITests.swift` — one set **per category** (a spec adding two categories adds two sets); `<Prefix>` = the category folder name, except `Blurs` → `Blur` (so `BlurGoldenTests`, `PhotoGoldenTests`, `NoiseGoldenTests`, `StylizeGoldenTests`, …); updates to `EffectRegistryTests.standardContents`, `EffectRegistryTests.effectSubmenus`, `MainMenuEffectsTests.effectsMenuItems` and `CoreImageBridgeTests.kernelsLoad` with the **full** new lists, each extending the previous Effects spec's list exactly (0041 → 0042 → 0043 → 0044). Shared helpers (this spec's general-kernel pattern and `UITestApp.chooseMenuItem(_:_:_:)`, 0043's `PixelHash`, `EffectSeedSource` and `BlendOps.h`) are defined once in the lowest spec that needs them and reused, never duplicated.

### Core (pure, headless, unit-tested)

1. **`PaintDotMac/Core/Effects/Effects/Blurs/GaussianBlur.swift`** (new).
   ```swift
   public struct GaussianBlur: ImageEffect {
       public init()
       public let id = "gaussianBlur"
       public let name = "Gaussian Blur"
       public let category = EffectCategory.blurs
       public var parameters: [EffectParameter] {
           [.init(id: "radius", label: "Radius", kind: .integer(range: 0...200, defaultValue: 2))]
       }
       public var alphaMode: EffectAlphaMode { .straight }            // kernels premultiply themselves, so radius 0 is a byte-exact identity
       public func inputPadding(for values: EffectParameterValues) -> Int   // = radius
       public static func tentWeights(radius: Int) -> [Int]            // [1, 2, …, r+1, …, 2, 1] (count 2r+1); radius 0 → [1]
       public func makeOutput(input: CIImage, values: EffectParameterValues, context: EffectRenderContext) throws -> CIImage
   }
   ```
   - No shortcut (Paint.NET has none; PRD §5.12 lists none); history icon default `.effect`; menu title "Gaussian Blur…"; dialog label "Radius:".
   - **Definition** (the oracle implements exactly this; the GPU matches within ±1). For output pixel `(x, y)` with radius `r ≥ 1`, taps `(x+i, y+j)` for `i, j ∈ −r…r`, weight `w(i)·w(j)` with `w(k) = r + 1 − |k|` (Paint.NET's tent; the common factor 16 cancels), the tapped pixel **clamped** to the canvas (`clamp(x+i, 0, W−1)`, `clamp(y+j, 0, H−1)`). With straight `(R, G, B, A)` per tap and `S = Σ w(i)w(j) = (r+1)⁴`:
     `A_out = round(Σ w·A / S)`; `C_out = Σ w·A == 0 ? 0 : round(Σ w·A·C / Σ w·A)` for C ∈ {R, G, B} (alpha-weighted = premultiplied average, then un-premultiplied). `round` = to nearest, ties away from zero. A fully transparent neighborhood → `(0,0,0,0)` (as 3.36). `radius == 0` → output = input bytes exactly (3.36 copies the source), including color under alpha 0.
   - **`makeOutput`** (two separable GPU passes, both general `CIKernel`s from `context.kernel(_:)`):
     - `radius == 0` → `return input` (the bridge's `.straight` round trip is byte-exact, 0031 `CoreImageBridgeTests.straightRoundTripExact`).
     - `let out = context.ciRect(context.outputRect)`; `let r = CGFloat(radius)`;
     - `let vertical = try context.kernel("gaussianBlurVertical").apply(extent: out.insetBy(dx: -r, dy: 0), roiCallback: { _, rect in rect.insetBy(dx: 0, dy: -r) }, arguments: [input, Float(radius)])` — output is the **premultiplied**, vertically normalized float image `V = Σⱼ w(j)·(a·rgb, a) / (r+1)²` (`a = A/255`); it stays `RGBAf` (0031 working format) — never quantized between passes.
     - `return try context.kernel("gaussianBlurHorizontal").apply(extent: out, roiCallback: { _, rect in rect.insetBy(dx: -r, dy: 0) }, arguments: [vertical, Float(radius)])` — `P = Σᵢ w(i)·V / (r+1)²`, then un-premultiplied: `P.a > 0 ? (P.rgb / P.a, P.a) : (0,0,0,0)` (straight output, as `.straight` requires).
     - A nil kernel apply → throw `EffectError.renderFailed`. The closures capture only `r` (a `CGFloat`), so they are `@Sendable`-safe.
   - Edges: the bridge's `clampedToExtent()` input supplies clamped taps beyond the canvas; inside the canvas every tap lies within `inputRect` because `inputPadding == radius` — this apron is what makes chunk seams invisible (tested).

2. **`PaintDotMac/Core/Effects/Effects/Blurs/MotionBlur.swift`** (new).
   ```swift
   public struct MotionBlur: ImageEffect {
       public init()
       public let id = "motionBlur"
       public let name = "Motion Blur"
       public let category = EffectCategory.blurs
       public var parameters: [EffectParameter] {
           [.init(id: "angle",    label: "Angle",    kind: .angle(range: -180...180, defaultValue: 25, decimals: 2)),
            .init(id: "distance", label: "Distance", kind: .integer(range: 1...200, defaultValue: 10)),
            .init(id: "centered", label: "Centered", kind: .bool(defaultValue: true))]
       }   // order = the docs' order (Angle, Distance, Centered); Paint.NET 3.36's property order was Angle, Centered, Distance
       public var alphaMode: EffectAlphaMode { .premultiplied }       // bridge premultiplies the input and un-premultiplies the output
       public struct SamplePath: Sendable, Equatable { public let start: SIMD2<Float>; public let end: SIMD2<Float>; public let count: Int }
       public static func samplePath(angle: Double, distance: Int, centered: Bool) -> SamplePath
       public static func sampleOffsets(_ path: SamplePath) -> [SIMD2<Float>]   // what the kernel computes; for tests and the padding
       public func inputPadding(for values: EffectParameterValues) -> Int        // centered ? (d + 1) / 2 + 1 : d + 1
       public func makeOutput(input: CIImage, values: EffectParameterValues, context: EffectRenderContext) throws -> CIImage
   }
   ```
   - No shortcut; icon `.effect`; menu title "Motion Blur…"; dialog rows "Angle:" (slider −180…180 + field with 2 decimals, "°" suffix per 0031), "Distance:" (slider 1…200 + field), "Centered" checkbox.
   - **`samplePath`** — Paint.NET 3.36 `OnSetRenderInfo`, transcribed: `θ = (angle + 180) · 2π / 360` in `Double`; `ex = Float(Double(d)·cos θ)`, `ey = Float(−(Double(d)·sin θ))`; centered → `start = (−ex/2, −ey/2)`, `end = (ex/2, ey/2)` (Float division); else `start = (0,0)`, `end = (ex, ey)`; `count = ((1 + d) · 3) / 2`.
   - **`sampleOffsets`**: `count == 1` → `[(0,0)]`; else for `j in 0..<count`: `t = Float(j) / Float(count − 1)`, offset = `start + t·(end − start)` per component (`Utility.Lerp` form `from + frac·(to − from)`, Float).
   - **Definition** (oracle = this; GPU within ±1): for output pixel `(x, y)` and each offset `o_j`, sample position `p = (Float(x) + o.x, Float(y) + o.y)` (canvas pixel-index space, y down — pixel `k`'s center is at `k`); **bilinear** sample with `ix = floor(p.x)`, `fx = p.x − ix` (same for y), the four texels `(ix, iy)`, `(ix+1, iy)`, `(ix, iy+1)`, `(ix+1, iy+1)` each **clamped** to the canvas, interpolated in **premultiplied** space (`(a·rgb, a)`, `a = A/255`); the output is the plain mean of the `count` premultiplied samples, un-premultiplied (`a == 0` → `(0,0,0,0)`), each channel `round(v·255)`. Every sample counts (clamping replaces 3.36's skipping, so there is never a zero-sample pixel).
   - **`makeOutput`**: `let path = Self.samplePath(...)`; `try context.kernel("motionBlur").apply(extent: context.ciRect(context.outputRect), roiCallback: { _, rect in rect.insetBy(dx: -pad, dy: -pad) }, arguments: [input, CIVector(x: CGFloat(path.start.x), y: CGFloat(path.start.y)), CIVector(x: CGFloat(path.end.x), y: CGFloat(path.end.y)), Float(path.count)])` with `pad = CGFloat(inputPadding(for: values))`; nil → `.renderFailed`.
   - **Padding** (apron): the largest offset component is `d/2` (centered) or `d` (not), plus one texel for the bilinear neighbor → `centered ? (d + 1) / 2 + 1 : d + 1`.

3. **`PaintDotMac/Core/Rendering/Shaders/EffectKernels.metal`** (extend 0031/0032/0034) — new section `// MARK: - Blurs`, three stitchable **general** kernels (`#include <CoreImage/CoreImage.h>`, `using namespace metal;`). All taps are read at **exact texel centers** (`dest.coord()` is a texel center, offsets are whole texels), so the sampler's filtering mode never changes a value and bilinear interpolation is done explicitly in float (hardware filtering precision is not relied upon).
   ```metal
   [[stitchable]] float4 gaussianBlurVertical(coreimage::sampler src, float radius, coreimage::destination dest) {
       int r = int(radius); float2 c = dest.coord(); float4 acc = 0; float norm = float(r + 1) * float(r + 1);
       for (int j = -r; j <= r; ++j) {
           float w = float(r + 1 - abs(j));
           float4 s = src.sample(src.transform(c + float2(0, float(j))));     // straight input
           acc += w * float4(s.rgb * s.a, s.a);                               // premultiply per tap
       }
       return acc / norm;                                                     // premultiplied intermediate (RGBAf)
   }
   [[stitchable]] float4 gaussianBlurHorizontal(coreimage::sampler src, float radius, coreimage::destination dest) {
       int r = int(radius); float2 c = dest.coord(); float4 acc = 0; float norm = float(r + 1) * float(r + 1);
       for (int i = -r; i <= r; ++i) { acc += float(r + 1 - abs(i)) * src.sample(src.transform(c + float2(float(i), 0))); }
       float4 p = acc / norm;
       return p.a > 0 ? float4(p.rgb / p.a, p.a) : float4(0);                 // straight output
   }
   [[stitchable]] float4 motionBlur(coreimage::sampler src, float2 start, float2 end, float count, coreimage::destination dest) {
       int n = int(count); float2 c = dest.coord(); float4 acc = 0;
       for (int j = 0; j < n; ++j) {
           float t = n == 1 ? 0.0 : float(j) / float(n - 1);
           float2 o = start + t * (end - start);                              // canvas offsets, y down
           float2 q = c + float2(o.x, -o.y) - 0.5;                            // CI is y up; texel centers at +0.5
           float2 i0 = floor(q); float2 f = q - i0;
           float4 s00 = src.sample(src.transform(i0 + float2(0.5, 0.5)));
           float4 s10 = src.sample(src.transform(i0 + float2(1.5, 0.5)));
           float4 s01 = src.sample(src.transform(i0 + float2(0.5, 1.5)));
           float4 s11 = src.sample(src.transform(i0 + float2(1.5, 1.5)));
           acc += mix(mix(s00, s10, f.x), mix(s01, s11, f.x), f.y);           // input is premultiplied (alphaMode .premultiplied)
       }
       return acc / float(n);                                                 // premultiplied; the bridge un-premultiplies
   }
   ```
   (In CI's y-up space `f.y` weights the texel row *above*; bilinear is symmetric, so this equals the canvas-space definition in item 2.) `CoreImageBridge`'s kernel name list gains `gaussianBlurVertical`, `gaussianBlurHorizontal`, `motionBlur`. No `project.yml` change (0031 already set `MTLLINKER_FLAGS`).

4. **`PaintDotMac/Core/Effects/EffectRegistry.swift`** (extend): `standard` appends `GaussianBlur(), MotionBlur()` → ids `["invertColors","brightnessContrast","blackAndWhite","hueSaturation","posterize","sepia","levels","autoLevel","curves","gaussianBlur","motionBlur"]`; `adjustments` unchanged; `effectSubmenus` = `[(.blurs, [GaussianBlur, MotionBlur])]` (names sorted: "Gaussian Blur" < "Motion Blur"). `EffectSchemaValidator` must report no problems (defaults on grid: 2 ∈ 0…200, 25.00 ∈ −180…180 with 2 decimals, 10 ∈ 1…200).

5. **NF-3 tuning (Core configuration only):** measure item 11's performance test with 0031's defaults (`chunkTiles 2`, `maxConcurrentChunks 2`). If the average exceeds 500 ms on the build machine, try `chunkTiles` ∈ {2, 4} × `maxConcurrentChunks` ∈ {2, 3, 4} and set the fastest combination as `EffectRunner.Configuration`'s defaults (no API change), provided 0031's `EffectRunnerTests` still pass and the dialog preview of a 4000×3000 image stays responsive (manual 1). Record the matrix, the chosen values and the machine (chip) in the Verification status. Do not add effect-specific runner paths.

### Platform glue (covered by integration and UI tests)

6. **`App/MainMenu.swift`** — **no code change**: the Effects menu is generated from the registry (0031 item 17), so it becomes: "Repeat" (`menu.effects.repeat`, ⌘F), separator, submenu **"Blurs"** (`menu.effects.blurs`) containing **"Gaussian Blur…"** (`menu.effects.blurs.gaussianBlur`, `representedObject` "gaussianBlur", action `runEffect(_:)`, no key equivalent) and **"Motion Blur…"** (`menu.effects.blurs.motionBlur`, "motionBlur"). Both run through 0031's `runEffect(_:)` (guards, `prepareForNavigation` → "Finish Pixels" first, dialog sheet, session controller, progress sheet after 0.5 s, `remember` + `recordApplied` on `.done`), and Repeat through `repeatLastEffect(_:)`. Nothing new in `DocumentWindowController`.

7. **`UI/EffectDialogView.swift`** — **no code change**: the dialog is generated (Radius slider + field; Angle slider + field with "°"; Distance slider + field; Centered checkbox). Accessibility identifiers used by UI tests: `effectDialog.radius`, `effectDialog.radius.field`, `effectDialog.angle`, `effectDialog.angle.field`, `effectDialog.distance`, `effectDialog.distance.field`, `effectDialog.centered`.

8. **`PaintDotMacUITests/Support/UITestApp.swift`** (extend 0001): `func chooseMenuItem(_ menu: String, _ submenu: String, _ item: String)` — opens the menu-bar item, hovers/clicks the submenu, clicks the item (every Effects-menu spec uses it).

9. **`PaintDotMacTests/Effects/Reference/ReferenceEffectRenderer.swift`** (extend 0031): dispatch `"gaussianBlur"` → `GaussianBlurReference`, `"motionBlur"` → `MotionBlurReference`; for these the renderer reads the **whole source surface** with canvas clamping (not just `inputRect`), so runner/session tests driven by the oracle are independent of the effect's `inputPadding`.

10. **`project.yml`** — no change; new files are picked up by the existing globs (`PaintDotMac/Core/**`, `PaintDotMacTests/**`). Run `xcodegen generate` after adding the files.

11. **Tests listed in *Test plan*** (new files under `PaintDotMacTests/Effects/Blurs/`, `PaintDotMacTests/Effects/Reference/`, `PaintDotMacTests/Document/`, `PaintDotMacUITests/`).

No PRD change in this spec (the decisions applied are listed under *Open questions* for the planner to record in PRD §5.9/§12).

## Acceptance criteria

- [ ] Effects ▸ Blurs contains "Gaussian Blur…" and "Motion Blur…" (in that order), generated from `EffectRegistry.standard`; the Effects menu is "Repeat", separator, "Blurs"; no new shortcuts and no duplicates. → `EffectRegistryTests.standardContents`, `.effectSubmenus`, `MainMenuEffectsTests.effectsMenuItems`, `MainMenuTests.noDuplicateShortcuts`, `BlurEffectsUITests.testBlursSubmenu`
- [ ] FX-E: Gaussian Blur has **Radius 0…200, default 2**; Motion Blur has **Angle −180…180 (2 decimals), default 25**, **Distance 1…200, default 10**, **Centered default on**; labels "Radius", "Angle", "Distance", "Centered". → `GaussianBlurTests.metadata`, `MotionBlurTests.metadata`, `EffectSchemaValidatorTests.standardRegistryIsValid`, `BlurEffectsUITests.testGaussianBlurDefaultsAndOK`, `.testMotionBlurDialogAndRepeat`
- [ ] Gaussian Blur uses Paint.NET's tent weights `r+1−|k|`, separable, alpha-weighted, clamp-to-edge, per the item 1 definition; radius 0 is the byte-exact identity. → `GaussianBlurTests.*`, `GaussianBlurReferenceTests.*`, `BlurGoldenTests.gaussian*`, `BlurGoldenTests.radiusZeroIsIdentity`
- [ ] Motion Blur uses Paint.NET's sample path (count `⌊3(1+d)/2⌋`, Float lerp offsets, centered/non-centered, samples trailing opposite the angle), bilinear premultiplied sampling, clamp-to-edge, per the item 2 definition. → `MotionBlurTests.*`, `MotionBlurReferenceTests.*`, `BlurGoldenTests.motion*`
- [ ] FX-B: both run on the GPU through `CoreImageBridge` and match their CPU oracles within ±1 per channel (expected count of ±1 differences reported); where the definitions coincide (opaque interiors) they stay within the stated bound of literal Paint.NET 3.36 transcriptions. → `BlurGoldenTests.*`, `CoreImageBridgeTests.kernelsLoad`, `BlurFidelityTests.*`
- [ ] Region/tile apron: results are independent of chunking (no seams at tile or chunk borders) for every radius/distance including 200. → `BlurGoldenTests.chunkSeamsInvisible`, `.largeRadiusAcrossTiles`
- [ ] FX-D: with an antialiased selection only selected pixels change, blended by mask coverage; pixels outside are byte-identical; pixels outside the selection are still read as blur input. → `BlurGoldenTests.selectionBlendGaussian`, `BlurEffectsIntegrationTests.selectionClippedApply`, `BlurEffectsUITests.testGaussianBlurRespectsSelection`
- [ ] §5.8/FX-C: live preview without a step, Cancel restores exactly, OK commits one step named "Gaussian Blur"/"Motion Blur" (icon `.effect`), undo/redo exact, parameters remembered for the session, ⌘F repeats with the same values and no dialog; a long run is cancellable with an exact restore. → `BlurEffectsIntegrationTests.*`, `BlurEffectsUITests.*`
- [ ] NF-3: Gaussian Blur radius 20 on a 24 MP (6000×4000) layer is measured; the test gates at 1.5 s (3× the 500 ms target) and the measured number (and chip) is recorded in the Verification status. → `BlurPerformanceTests.testGaussianRadius20On24MP`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Radius 0:** identity, including color under alpha 0 → no-op OK adds no step (H-6) but sets `lastApplied`. → `BlurGoldenTests.radiusZeroIsIdentity`, `BlurEffectsIntegrationTests.radiusZeroAddsNoStep`
- **Images smaller than the kernel** (1×1, 1×N, N×1, 3×3 with radius 200 / distance 200): clamping makes every tap the edge pixel(s); 1×1 opaque → unchanged; 1×1 `(10,20,30,0)` with radius ≥ 1 → `(0,0,0,0)` (alpha-weighted, as 3.36); Motion Blur on 1×1 → unchanged when alpha > 0. → `GaussianBlurReferenceTests.tinyImages`, `MotionBlurReferenceTests.tinyImages`, `BlurGoldenTests.tinyImagesGPU`
- **Edge tiles / non-multiple-of-256 sizes** (257×257, 300×200): out-of-canvas tile bytes stay 0 (0002 invariant), last row/column correct. → `BlurGoldenTests.edgeTiles`
- **Sparse layers:** a fully transparent layer stays unallocated (all outputs `(0,0,0,0)` → nil tiles); a transparent tile next to an opaque one becomes allocated with the blurred fringe only. → `BlurEffectsIntegrationTests.sparseTilesStaySparse`
- **Alpha 0 pixels with color:** for radius ≥ 1 and any Motion Blur their color contributes nothing (weight `a = 0`) — a red pixel with alpha 0 next to opaque blue does not tint the blue. → `GaussianBlurReferenceTests.alphaWeighted`, `BlurGoldenTests.gaussianAlphaWeighted`
- **Angle extremes and axis angles:** −180 and 180 give the same path within Float precision (results ±1); 0/90/−90/180 are axis-aligned (the y or x offsets are ~1e-16, harmless with clamping). → `MotionBlurTests.samplePathAxisAngles`, `BlurGoldenTests.motionAngleMinus180Equals180`
- **Large radius / distance (200):** apron 200 / 201 px around each 512×512 chunk; correct across chunk borders; memory bounded per chunk (≈ (512+400)² × 16 B float intermediate). → `BlurGoldenTests.largeRadiusAcrossTiles`
- **Cancel during a long run** (radius 200 on 2048×2048, or the progress sheet's Escape): exact restore, no step, values not remembered. → `BlurEffectsIntegrationTests.cancelLargeRadiusRestoresExactly`
- **Selection touching the canvas edge / partial coverage:** EffectMaskBlend per 0031; `.empty` mask tiles are not rendered. → `BlurGoldenTests.selectionBlendGaussian`
- **Hidden active layer, other layers, floating pixels:** handled by 0031's session path (effects run on the hidden layer; other layers untouched; "Finish Pixels" first). → `BlurEffectsIntegrationTests.onlyActiveLayerChanges`
- **GPU unavailable / kernel missing:** 0031 disables effect items without a bridge; a missing blur kernel surfaces as `EffectError.kernelMissing("gaussianBlurVertical")` → "The effect couldn’t be applied.", original restored, no crash. → `CoreImageBridgeTests.kernelsLoad` (presence), 0031 `EffectSessionIntegrationTests.rendererErrorRestores` (path)
- **65,535 × 1 image:** vertical pass clamps to the single row; result equals the 1-D tent blur. → `BlurGoldenTests.extremeAspect`

## Test plan

Expected values come from hand calculation, Paint.NET's transcribed definitions, or the CPU oracles — never from running the code under test. Hand examples are chosen so the exact results are not at `.5` ties.

- **CPU oracles** (`PaintDotMacTests/Effects/Reference/`):
  - `GaussianBlurReference.apply(_ pixels: [ColorRGBA8], width:, height:, radius:) -> [ColorRGBA8]` — **integer-exact**: column sums `Σⱼ w(j)·A`, `Σⱼ w(j)·A·C` as `Int64` over clamped rows, then row sums with `w(i)` over clamped columns; `A_out = (2·ΣwA + S) / (2·S)` (round half up), `C_out = ΣwA == 0 ? 0 : (2·ΣwAC + ΣwA) / (2·ΣwA)`; radius 0 returns the input. Weights written inline (`r + 1 − abs(k)`), not taken from `GaussianBlur.tentWeights`.
  - `MotionBlurReference.apply(_:width:height:angle:distance:centered:) -> [ColorRGBA8]` — computes start/end/count/offsets itself in `Double`→`Float` exactly as item 2 (independent code), positions in `Float`, bilinear on clamped indices in `Double` premultiplied space, mean, un-premultiply, round.
  - `PaintDotNet336GaussianBlur.apply(...)` and `PaintDotNet336MotionBlur.apply(...)` — **literal transcriptions** of 3.36 `OnRender` (including `CreateGaussianBlurRow`, the `A + (A>>7)` / `>> 8` integer steps, out-of-image skipping, `GetBilinearSample`'s 8-bit fractions and `BlendColors4W16IP`, `ColorBgra.Blend` truncation, `Transparent` = (255,255,255,0)). Used only by `BlurFidelityTests`.
- **Unit — `PaintDotMacTests/Effects/Blurs/GaussianBlurTests.swift`:** `metadata` (id "gaussianBlur", name "Gaussian Blur", `.blurs`, one parameter `radius` label "Radius" `.integer(0...200, default 2, step 1)`, `menuTitle` "Gaussian Blur…", no shortcut, icon `.effect`, `alphaMode .straight`); `tentWeights` (r 0 → [1]; r 1 → [1,2,1]; r 2 → [1,2,3,2,1]; r 200 → count 401, center 201, ends 1, symmetric); `inputPaddingEqualsRadius` (0, 2, 20, 200).
- **Unit — `PaintDotMacTests/Effects/Blurs/GaussianBlurReferenceTests.swift`** (oracle vs hand math; gray pixels `(v,v,v,255)` written as `v`):
  - `row1DExact`: 5×1 `[0,0,200,0,0]`, r 1 → `[0,50,100,50,0]` (vertical taps clamp to the same row: factor 4/4).
  - `edgeClamps`: 3×1 `[200,0,0]`, r 1 → `[150,50,0]` (x 0: taps −1→200·1, 200·2, 0·1 → 600/4; Paint.NET 3.36's skip rule would give 133 — the transcription test below asserts that).
  - `twoD3x3`: 3×3 zeros with center 160, r 1 → center 40 (160·4/16), edge (1,0) 20 (320/16), corner (0,0) 10 (160/16).
  - `radius2`: 5×1 `[0,0,255,255,255]`, r 2 → pixel 2 = 170 ((3+2+1)·255/9 = 1530/9), pixel 1 = 85 ((2+1)·255/9 = 765/9).
  - `alphaWeighted`: 3×1 `[(200,0,0,255),(0,0,200,0),(0,0,200,0)]`, r 1 → pixel 1 = (200,0,0,64) (ΣwA = 255·1·4 over S 16 → 63.75 → 64; color 200, blue 0), pixel 0 = (200,0,0,191) (765/4 = 191.25).
  - `uniformSemiTransparentUnchanged`: 3×3 all (100,100,100,128), r 1 → all (100,100,100,128).
  - `fullyTransparentNeighborhood`: (10,20,30,0) everywhere, r 3 → (0,0,0,0).
  - `radiusZeroIdentity`: seeded random 17×9 including alpha 0 with color → identical.
  - `tinyImages`: 1×1 (10,20,30,255) r 200 → unchanged; 1×1 (10,20,30,0) r 1 → (0,0,0,0); 3×3 r 200 equals r 200 computed by direct 2-D summation (a second, naive O(r²) loop in the test).
  - `symmetry`: seeded random 40×30, r 4: blur(mirrorX(img)) == mirrorX(blur(img)), same for mirrorY and transpose (exact, integer oracle).
- **Unit — `PaintDotMacTests/Effects/Blurs/MotionBlurTests.swift`:** `metadata` (id "motionBlur", name "Motion Blur", `.blurs`, parameters in order `angle` "Angle" `.angle(−180…180, 25, 2 decimals)`, `distance` "Distance" `.integer(1…200, 10)`, `centered` "Centered" `.bool(true)`, `menuTitle` "Motion Blur…", icon `.effect`, `alphaMode .premultiplied`); `sampleCount` (d 1 → 3, 2 → 4, 10 → 16, 199 → 300, 200 → 301); `samplePathDefaults` (25°, 10, centered: |start − (4.5315, −2.1131)| < 1e-3, end = −start, count 16 — hand: θ 205°, cos −0.90631, sin −0.42262 → e = (−9.0631, 4.2262)); `samplePathNonCentered` (0°, 2 → start (0,0), end ≈ (−2, 0), offsets ≈ [0, −0.6667, −1.3333, −2] in x, |y| < 1e-6); `samplePathAxisAngles` (90°, 2, not centered → end ≈ (0, 2): samples trail downward; −90° → (0, −2); 180° → (2, 0); |off-axis component| < 1e-6); `angleMinus180Equals180` (paths equal within 1e-5); `offsetsSingleSample` (count 1 → [(0,0)] — reachable only via a hand-built `SamplePath`); `inputPadding` (d 10 centered → 6, not → 11; d 1 centered → 2; d 200 centered → 101, not → 201); `offsetsMatchOracle` (Core `sampleOffsets` bitwise equal to `MotionBlurReference`'s own Float computation for 50 seeded (angle, distance, centered)).
- **Unit — `PaintDotMacTests/Effects/Blurs/MotionBlurReferenceTests.swift`** (oracle vs hand math):
  - `horizontalTrail`: 5×1 `[0,0,0,240,0]`, 0°, d 2, not centered → pixel 4 = 80 ((0 + 160 + 160 + 0)/4: samples at 4, 3.333, 2.667, 2), pixel 3 = 80 ((240 + 80 + 0 + 0)/4), pixel 0 = 0, pixel 1 = 0.
  - `edgeClampsNotSkips`: 5×1 `[0,0,0,0,240]`, 180°, d 2, not centered → pixel 3 = 160 (samples 3 → 0, 3.667 → 160, 4.333 → 240 (clamped), 5 → 240; 640/4); 3.36's skip rule would give 80.
  - `centeredVertical`: 1×5 column `[0,0,240,0,0]`, 90°, d 2, centered (path (0,−1) → (0,1), offsets y −1, −⅓, ⅓, 1) → pixel 2 = 80 (samples y 1 → 0, 1.667 → 160, 2.333 → 160, 3 → 0; 320/4), pixel 1 = 80 (0, 0, 80, 240), pixel 0 = 0 (taps above row 0 clamp to row 0).
  - `premultiplied`: 3×1 `[(200,0,0,255),(0,0,200,0),(0,0,200,0)]`, 180°, d 2, not centered (offsets x 0, ⅔, 4⁄3, 2) → pixel 0 = (200,0,0,85) (sample alphas 1, ⅓, 0, 0 → mean ⅓ → 85; premultiplied red only from P0, so color stays 200 and blue stays 0 — a straight average would give blue > 0).
  - `tinyImages`: 1×1 (10,20,30,255) any angle/distance/centered → unchanged; 1×1 (10,20,30,0) → (0,0,0,0).
  - `uniformImageUnchanged`: 9×7 all (40,90,200,77), 25°, d 10, centered → unchanged.
- **Fidelity — `PaintDotMacTests/Effects/Blurs/BlurFidelityTests.swift`** (oracle vs literal 3.36; documents the deviations):
  - `gaussian336HandValues`: the 3.36 transcription gives 133 for `edgeClamps`' pixel 0 (skip rule: 400/3 truncated) and **64** alpha for the 3×3 uniform alpha-128 image's center (hand: `wp = (16·129)>>8 = 8`, `(32·129)>>8 = 16`; column `aSums = (8+16+8)·128 = 4096`; `aSum = 64·4096`, `waSum = 64·64` → 64) — the alpha fade the spec deliberately does not reproduce.
  - `gaussianOpaqueInteriorWithinOneOf336`: seeded opaque 64×48, r ∈ {1, 2, 5}: for pixels at least r from every edge, `ours − pdn336 ∈ {0, 1}` per channel (same weights; 3.36 truncates, ours rounds; alpha equal 255).
  - `motionOpaqueInteriorWithinFourOf336`: seeded opaque 64×48, (angle, d, centered) ∈ {(25, 3, true), (−63, 10, false), (140, 7, true)}: for pixels whose every sample lies inside the canvas (≥ d+1 from the edges), `|ours − pdn336| ≤ 4` per channel. Bound derivation (write it in the test's doc comment): 3.36's 8-bit fractions err < 1/256 per axis (< 2 levels per sample), its per-sample truncation < 1, the final truncation < 1, ours rounds (≤ 0.5) → |diff| < 4.5.
  - `motionZeroSamples336`: 3.36 on 1×1, 25°, d 10, centered → (255,255,255,0) (no sample lands on (0,0)); ours → the pixel itself (clamping) — documents the deviation.
- **GPU — `PaintDotMacTests/Rendering/CoreImageBridgeTests.swift`** (extend): `kernelsLoad` finds every kernel of the full list `["invertColors","brightnessContrast","blackAndWhite","hueSaturation","channelLookup","luminosityCurve","gaussianBlurVertical","gaussianBlurHorizontal","motionBlur"]` (0031/0032/0034's six, then this spec's three).
- **Golden — `PaintDotMacTests/Effects/Blurs/BlurGoldenTests.swift`** (real `CoreImageBridge` + `EffectRunner` with 0031 defaults unless stated, vs oracle with `GoldenImage.compare` ±1; the count of ±1 differences is reported; fixture 600×400 seeded random straight RGBA, alpha from {0, 1, 77, 128, 254, 255}, spanning 3×2 tiles; seed printed):
  - `gaussianRadii`: r ∈ {1, 2, 3, 7, 20, 63}; `gaussianRandomRadii` (8 seeded r ∈ 1…40).
  - `largeRadiusAcrossTiles`: r 200 on the fixture (apron reaches across all tiles).
  - `radiusZeroIsIdentity`: r 0 → bytes identical to the source (exact, no tolerance), including alpha-0 colors.
  - `gaussianAlphaWeighted`: fixture with alpha-0 red pixels beside opaque blue → no red tint (oracle match).
  - `motionGrid`: (angle, d, centered) ∈ {(25,10,true) default, (25,10,false), (0,1,true), (0,2,false), (90,7,true), (−90,7,false), (180,13,true), (−180,13,true), (45,50,false), (−137.25,200,true)}; `motionRandom` (10 seeded triples).
  - `motionAngleMinus180Equals180`: GPU results for −180 and 180 (d 13, centered) within ±1 of each other.
  - `chunkSeamsInvisible`: for Gaussian r 20 and Motion (25, 30, false), runner output with `chunkTiles 1, maxConcurrentChunks 4` equals a single `bridge.renderEffect` over the whole canvas (expected 0 differences; tolerance ±1 reported).
  - `edgeTiles`: 257×257 and 300×200 fixtures, Gaussian r 5 and default Motion → oracle match; out-of-canvas tile bytes 0.
  - `tinyImagesGPU`: 1×1, 1×7, 7×1, 3×3 with r 200 and d 200 → oracle match.
  - `extremeAspect`: 65,535×1 seeded row, Gaussian r 20 → oracle match.
  - `selectionBlendGaussian`: antialiased ellipse `Selection(path:)` + Gaussian r 7 through the runner vs oracle + `MaskBlendReference` (±1); pixels whose mask coverage is 0 byte-identical to the source.
  - No PNG goldens are recorded: the oracle is the golden.
- **Unit — `PaintDotMacTests/Effects/EffectRegistryTests.swift`** (update): `standardContents` → the 11 ids in item 4; `adjustmentsSortedByName` unchanged (0034's list); replace 0031's `effectSubmenusEmptyNow` with `effectSubmenus` → `[(.blurs, ["Gaussian Blur", "Motion Blur"])]`. Later Effects specs update these two tests with their full lists. `EffectSchemaValidatorTests.standardRegistryIsValid` unchanged (now covers the blurs).
- **Unit — `PaintDotMacTests/App/MainMenuEffectsTests.swift`** (update): replace 0031's `effectsMenuHasRepeatOnly` with `effectsMenuItems` → exactly: "Repeat" (`f`, ⌘, `repeatLastEffect:`, `menu.effects.repeat`), separator, submenu "Blurs" (`menu.effects.blurs`) with `[("Gaussian Blur…", "", [], runEffect:, "gaussianBlur", "menu.effects.blurs.gaussianBlur"), ("Motion Blur…", "", [], runEffect:, "motionBlur", "menu.effects.blurs.motionBlur")]`. `MainMenuTests.noDuplicateShortcuts` still passes.
- **Integration — `PaintDotMacTests/Document/BlurEffectsIntegrationTests.swift`** (`@MainActor`, real `UndoBridge` with a 600×400 two-layer document, active layer 1 = seeded random, layer 0 opaque; `debounce: .zero`; real `CoreImageBridge` for pixel assertions, gated `ReferenceEffectRenderer` for timing):
  - `gaussianOkCommitsOneStep`: session r 5 → OK → one step "Gaussian Blur", icon `.effect`; live pixels = oracle ±1; undo → original bytes exactly (tiles share storage with the original); redo → the committed bytes exactly.
  - `motionOkCommitsOneStep`: same for Motion (25, 10, true) → "Motion Blur".
  - `previewWithoutStep`: after the preview completes, `history.steps.count` unchanged and pixels = oracle ±1; `cancelRestoresExactly` (tile storage identity, no step).
  - `parameterChangeRerenders`: radius 2 → 9 → committed pixels = r 9 oracle ±1.
  - `radiusZeroAddsNoStep`: r 0 OK → no step, `lastApplied` = gaussianBlur.
  - `repeatUsesLastValues`: Motion (0, 2, false) OK, then the Repeat path → two "Motion Blur" steps, pixels = oracle applied twice ±1 (oracle run on the GPU result of the first pass, so the tolerance does not accumulate); two undos → original.
  - `valuesRememberedOnOK`: after OK with radius 7, `effectMemory.initialValues(for: GaussianBlur())` → radius 7; after a cancelled session with 12 → still 7.
  - `selectionClippedApply`: selection rect (100,100,200,100), Gaussian r 10 → pixels outside the rect byte-identical; inside = oracle (computed on the whole layer, so outside pixels feed the blur) ±1.
  - `sparseTilesStaySparse`: empty layer 1 → Gaussian r 20 → no allocated tiles, no step; a layer with one opaque 10×10 block at (250,250) → only tiles within 20 px of the block are allocated.
  - `onlyActiveLayerChanges`: layer 0 tiles share storage before/after.
  - `cancelLargeRadiusRestoresExactly`: 2048×2048 layer, r 200, cancel after the first progress callback → every tile shares storage with the original, no step, `!isBusy`.
- **UI — `PaintDotMacUITests/BlurEffectsUITests.swift`** (fixture 300×200 PNG, columns 0…149 black (0,0,0,255) and 150…299 white (255,255,255,255), written with `UITestFixtures.writePNG`; pixel checks by ⌘S and decoding the PNG in the test; blurred values compared ±1, untouched values exactly):
  - `testBlursSubmenu`: Effects menu shows "Repeat" (disabled), then submenu "Blurs" whose items include "Gaussian Blur…" before "Motion Blur…" (asserted as a subsequence so P1 blurs don't break it).
  - `testGaussianBlurDefaultsAndOK`: `chooseMenuItem("Effects", "Blurs", "Gaussian Blur…")` → `effectDialog` with `effectDialog.radius.field` "2"; wait for `effectDialog.progress` "idle"; click `effectDialog.ok` → last history row "Gaussian Blur"; ⌘S → (149,100) = 85, (150,100) = 170 (hand: 765/9, 1530/9), (10,10) = (0,0,0,255), (290,10) = (255,255,255,255); ⌘Z → ⌘S → (149,100) = 0, (150,100) = 255; ⇧⌘Z → 85/170 again.
  - `testGaussianBlurCancelRestores`: open, type "20⇥" in `effectDialog.radius.field`, wait "idle", Escape → no new history row; ⌘S → (149,100) = 0 exactly; reopen → field "2" (Cancel not remembered); Cancel.
  - `testGaussianRepeat`: Gaussian OK at radius 2; Effects menu item "Repeat Gaussian Blur" enabled; ⌘F → two "Gaussian Blur" rows, no sheet; ⌘S → (150,100) = 157 (hand: first pass columns 148…152 = 28, 85, 170, 227, 255; second pass (28 + 170 + 510 + 454 + 255)/9 = 1417/9 = 157.4) and (149,100) = 98 (878/9 = 97.6).
  - `testMotionBlurDialogAndRepeat`: `chooseMenuItem("Effects", "Blurs", "Motion Blur…")` → `effectDialog.angle.field` "25.00", `effectDialog.distance.field` "10", `effectDialog.centered` value 1; type "0⇥" in the angle field and "2⇥" in the distance field; wait "idle"; OK → row "Motion Blur"; ⌘S → (149,100) = 85, (150,100) = 170 (hand: centered offsets 1, ⅓, −⅓, −1 → (255 + 85 + 0 + 0)/4 and (255 + 255 + 170 + 0)/4), (10,100) = (0,0,0,255); Effects menu shows "Repeat Motion Blur"; reopen Motion Blur… → angle "0.00", distance "2" (remembered); Cancel.
  - `testGaussianBlurRespectsSelection`: launch with `-UITestSelectRect 0,0,150,200`; Gaussian OK (radius 2) → ⌘S → (149,100) = 85 (white outside the selection feeds the blur), (150,100) = (255,255,255,255) exactly, (151,100) exactly white.
- **Performance — `PaintDotMacTests/Effects/Blurs/BlurPerformanceTests.swift`** (XCTest `measure`, real bridge, whole-layer `EffectRunner.run` to completion including tile assembly and `EffectMaskBlend`, no selection; fixture 6000×4000 opaque seeded random layer built once outside the measure block):
  - `testGaussianRadius20On24MP` — **NF-3**: target < 500 ms on an M1; **gate: average ≤ 1.5 s** (3×). Record the average, the chip, and the item 5 tuning matrix in the Verification status.
  - `testMotionBlurDefaultsOn24MP` — informational (no PRD target): default (25°, 10, centered), gate ≤ 3 s; record the number.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build without warnings, all tests pass, none skipped, UI tests ran, launch smoke passes.
- **Manual verification** (look and feel the tests can't judge):
  1. Open a ~4000×3000 photo at 100%, Effects ▸ Blurs ▸ Gaussian Blur…, drag Radius from 2 to 100 quickly: the visible area updates first and follows the slider without stutter or tile seams; Cancel restores the photo.
  2. Gaussian Blur at radius 200 on a 12000×8000 image: the progress sheet appears after ~0.5 s; Escape restores the image with no history row.
  3. Motion Blur on a photo with a bright point: at Angle 25 / Distance 50 non-centered the streak extends from the point toward the lower-left (opposite 25°, i.e. trailing a motion toward the upper-right); with Centered it extends both ways. Compare with Paint.NET if available.
  4. Blur a layer with transparent areas (e.g. text on transparency): edges fade smoothly, no dark or colored fringe, the semi-transparent interior keeps its opacity.
  5. Dark mode and VoiceOver: "Radius: 2", "Angle: 25.00°", "Distance: 10", "Centered, checkbox, checked" are read correctly.

## Open questions

Decided as stated (recommended answers applied in this spec); please confirm and record in PRD.md §5.9/§12:

1. **Gaussian Blur fidelity: Paint.NET 3.36's kernel shape (separable tent weights `r+1−|k|`, radius 0 = identity) in exact real-number, premultiplied-alpha math rounded to nearest, clamp-to-edge, with a correct alpha (`ΣwA/Σw`), run as two custom Metal passes — not a bit-exact 3.36 port and not `CIGaussianBlur`.** Bit-exact 3.36 would need 64-bit integer sums the GPU path can't do within ±1, would skip off-image taps instead of clamping, and would reproduce 3.36's alpha computation, which multiplies by alpha twice (a uniform 50 %-alpha layer comes out at 25 %). `CIGaussianBlur` needs a radius→sigma mapping Paint.NET doesn't document, approximates large radii by downsampling, and can't be matched by a ±1 CPU oracle (FX-B, D-22). Paint.NET 5's own GPU Gaussian kernel isn't published, so the 3.36 tent (the last published Paint.NET definition) is used. Consequences: on opaque interiors results equal 3.36 within +1 (truncation vs rounding); within `r` pixels of the edge they differ (clamp vs skip). Recommended: yes, as specified.
2. **Motion Blur fidelity: Paint.NET 3.36's sample path exactly (angle convention `θ = angle + 180°`, `⌊3(1+d)/2⌋` samples, Float lerp offsets, Centered splits the path around the pixel), with exact float bilinear sampling in premultiplied space, rounding to nearest, and clamp-to-edge instead of skipping off-image samples.** Consequences: within ±4 of 3.36 on opaque interiors (8-bit fractions and truncations in 3.36); at the edges the edge pixel repeats instead of being left out; a pixel can never have zero samples (3.36 returned transparent white). Recommended: yes.
3. **Paint.NET 5's extra options are not in v1.0: Gaussian Blur's *Gamma Boost* and *Quality*, and Motion Blur's *Edge Behavior* (Clamp/Wrap/Mirror/Transparent; v1.0 always behaves as Clamp).** The docs name them without ranges or defaults, and the parameter ranges/defaults used here (Radius 0–200 default 2; Angle −180…180 default 25; Distance 1–200 default 10; Centered on) come from the 3.36 source because the docs give none (FX-E fallback; Paint.NET 5's dialog couldn't be inspected here — please compare if you have it). The dialog order follows the docs: Angle, Distance, Centered. Recommended: omit the three options for v1.0 (they can be added later as schema parameters without breaking remembered values).

## Out of scope

- Other blurs: Radial, Zoom, Surface, Unfocus (P1, `0064-blur-effects-v1x`, D-26); Fragment, Bokeh (P2); Paint.NET 5's Sketch and Square blurs (not in PRD). Median is a Noise effect (P1, 0066).
- Sharpen and Vignette (0042), Add Noise and Clouds (0043), Emboss, Edge Detect, Pixelate (0044) — they follow this spec's layout and test pattern.
- Gamma Boost, Quality, Edge Behavior options (*Open questions* 3).
- Any change to the effect framework API (`ImageEffect`, `EffectRunner`, `CoreImageBridge`, dialog), beyond retuning `EffectRunner.Configuration` defaults per item 5.
- Moving effect shortcuts into `ShortcutTable` (0045; the blurs have none).
