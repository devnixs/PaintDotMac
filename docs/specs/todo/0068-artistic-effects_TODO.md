# 0068 — Add Effects ▸ Artistic ▸ Ink Sketch, Oil Painting, and Pencil Sketch (first Artistic submenu)

> Source: PRD.md §5.9 (Artistic, v1.x P1: "Ink Sketch, Pencil Sketch, Oil Painting"; FX-A, FX-B, FX-C, FX-D, FX-E), §5.8 shared rules (live preview, Cancel, "Repeat last" ⌘F — they apply to effects through 0031's single session path), §5.7 H-1 (step names "Ink Sketch", "Oil Painting", "Pencil Sketch"), §12 D-16, D-17, D-19, D-22, D-26, D-34 (H-6: no step when nothing changes); AGENTS.md architecture rules 1, 2, 3, 4, 5 (one file per effect, schema-generated dialog), 7 (off-main-actor, cancellable, progress), 8.
> Paint.NET docs (fetched 2026-11-09): https://paint.net/doc/latest/EffectsArtisticMenu.html (linked from https://paint.net/doc/latest/EffectsMenu.html, whose submenu order starts with **Artistic**; `getpaint.net/doc/latest/…` redirects there). *Ink Sketch*: "makes an image appear as if it was inked using a pen. The **Ink Outline** control affects the weight or strength of the edging. Larger values result in a thicker/heavier line … The **Coloring** control determines how much color bleeds through into the resulting image." *Oil Painting*: "**Brush size** affects the apparent size of the virtual brush tip. Larger values result in a coarser appearance … **Coarseness** determines how much detail is captured in the transformation." *Pencil Sketch*: "**Pencil tip size** determines how sharp or blunt the virtual pencil is … **Range** dictates how much detail is captured in the sketch." The docs give **no numeric ranges or defaults** (FX-E fallback → Paint.NET source, below).
> Paint.NET 3.36 source (last published source), https://github.com/wangdeshui/paint.net: `src/Effects/InkSketchEffect.cs` (© 2007 David Issel "BoltBait", MIT; `Int32Property(InkOutline, 50, 0, 99)`, `Int32Property(Coloring, 50, 0, 100)`; 5×5 `conv` kernel, `GlowEffect` with Radius 6 and Brightness = Contrast = `−(coloring − 50) · 2`, `UnaryPixelOps.Desaturate`, threshold `inkOutline · 255 / 100`, `UserBlendOps.DarkenBlendOp.Apply(lhs: ink, rhs: glow)`), `src/Effects/PencilSketchEffect.cs` (`Int32Property(PencilTipSize, 2, 1, 20)`, `Int32Property(ColorRange, 0, −20, +20)`; `GaussianBlurEffect` radius = tip size → `BrightnessAndContrastAdjustment` brightness = range, contrast = −range, in place → `InvertColorsEffect` → `DesaturateEffect` → `UserBlendOps.ColorDodgeBlendOp.Apply(lhs: Desaturate(src), rhs: dst)`), `src/Effects/OilPaintingEffect.cs` (`Int32Property(BrushSize, 3, 1, 8)`, `Int32Property(Coarseness, 50, 3, 255)`; square window, intensity bins, mode bin, per-bin channel averages — transcribed below), `src/Effects/GlowEffect.cs`, `src/Effects/BrightnessAndContrastAdjustment.cs`, `src/Effects/DesaturateEffect.cs`, `src/Core/UnaryPixelOps.cs` (`Desaturate`), `src/Core/ColorBgra.cs` (`GetIntensityByte()` = `(7471·B + 38470·G + 19595·R) >> 16`), `src/Core/Utility.cs` (`FastScaleByteByByte(a, b)` = `r1 = a·b + 0x80; ((r1 >> 8) + r1) >> 8`; `ClampToByte(int)`), `src/Data/UserBlendOps.Generated.cs` (`DarkenBlendOp`, `ColorDodgeBlendOp`), `src/Strings/strings.resx` (`InkSketchEffect.Name` "Ink Sketch", `InkSketchEffect.ConfigDialog.InkOutlineLabel` "Ink Outline", `…ColoringLabel` "Coloring"; `PencilSketchEffect.Name` "Pencil Sketch", `…PencilTipSizeLabel` "Pencil tip size", `…RangeLabel` "Range"; `OilPaintingEffect.Name` "Oil Painting", `…Amount1Label` "Brush size", `…Amount2Label` "Coarseness"; `Effects.Artistic.Submenu.Name` "Artistic"). All formulas are transcribed below so the implementer needs no browsing.
> Milestone: v1.x (P1)
> Depends on: 0067-distort-effects-v1x (the registry/menu/kernel lists this spec extends exactly), and through the chain 0066 (`LocalHistogramKernel` + `LocalHistogram.metal` + `LocalHistogramReference`, extended here with an Oil Painting mode), 0065 (`Glow`, `GaussianBlur.blurred(_:radius:context:)`, `BrightnessContrast.adjusted(_:brightness:contrast:context:)`, `GlowReference`, `BlurStageCandidates`, `PaintDotNet336Glow`, the blur-tie rule), 0064 (`Unfocus.halfWidths(radius:)`, P1 test-file naming), 0051 (end of v1.0), 0042 (`Sharpen`'s canvas-rect "skip off-canvas taps" kernel pattern), 0041 (Effects-menu layout and test pattern, `GaussianBlur`, `GaussianBlurReference`, `PaintDotNet336GaussianBlur`, `UITestApp.chooseMenuItem(_:_:_:)`, `ReferenceEffectRenderer` whole-source dispatch, fidelity policy), 0043 (`Shaders/BlendOps.h` included by `EffectKernels.metal`), 0032 (`BlackAndWhite.intensity(r:g:b:)`, `BlackAndWhiteReference`), 0031 (effect framework, `EffectCategory.artistic`, `InvertColors`, `BrightnessContrast`, `InvertColorsReference`, `BrightnessContrastReference`), 0026/0027 (`BlendOps.colorDodge`/`darken`, `ColorDodgeOp`/`DarkenOp` in `BlendOps.h`, `BlendReference`), 0024 (`GoldenImage`), 0013 (`Selection`), 0008 (`UndoBridge`).

## Context

No application code exists yet; every name below is fixed by a lower-numbered spec.

- **Effect framework (0031):** `ImageEffect` (`id`, `name`, `category: EffectCategory`, `parameters`, `shortcut` default nil, `historyIcon` default `.effect`, `alphaMode`, `inputPadding(for:)`, `makeOutput(input:values:context:)`; `menuTitle` = `name + "…"` with parameters). **`EffectCategory` already has `case artistic`, first in its order** (`artistic, blurs, distort, noise, object, photo, render, stylize`, 0031 `:85`, Paint.NET 5's submenu order; menu title "Artistic"). `EffectRegistry.effectSubmenus` lists only categories that have ≥ 1 effect, so **this spec makes "Artistic" appear as the first Effects submenu** (right after "Repeat" and the separator). The category folder is `Artistic` and, because the category is new, the test prefix is the plain **`Artistic`** (brief's v1.x naming rule / 0064 `:36`: `ArtisticGoldenTests`, `ArtisticEffectsIntegrationTests`, `ArtisticEffectsUITests`, …).
- **0041 layout and fidelity policy** (`docs/specs/todo/0041-blur-effects_TODO.md:38-42`, `:29`): one file per effect under `Core/Effects/Effects/<Category>/`, kernels in `EffectKernels.metal` under `// MARK: - <Category>`, oracles in `PaintDotMacTests/Effects/Reference/`, full-list updates of `EffectRegistryTests.standardContents`, `.effectSubmenus`, `MainMenuEffectsTests.effectsMenuItems`, `CoreImageBridgeTests.kernelsLoad`, each extending the previous spec's list exactly; shared helpers defined once in the lowest spec that needs them. Fidelity: keep Paint.NET's weights/sample geometry; use real-number or exact-integer math a GPU can reproduce within ±1 of a CPU oracle; literal 3.36 transcriptions are kept in the test target and compared where the definitions coincide.
- **0065 Glow** (`0065-photo-effects-v1x_TODO.md:49-72`): `Glow.makeOutput` = `GaussianBlur.blurred(input, radius:)` (0065 item 4, extracted from 0041) → `BrightnessContrast.adjusted(_, brightness:, contrast:)` (0065 item 5, extracted from 0031) → color kernel `glowCompose(original, adjusted)` = `ScreenOp::apply(o, a)`. Definition: `out = compose(dst: S, src: BC(Blur(S)), Channel.screen)`. Test support: `GlowReference.apply/candidates`, `BlurStageCandidates` (blur-tie alternatives), `PaintDotNet336Glow` (literal 3.36 chain). **0065 *Open questions* 1** (Glow built from PaintDotMac's own blur with clamp-to-edge and correct alpha, not a bit-exact 3.36 port) is inherited here.
- **0066 local histogram** (`0066-noise-and-stylize-v1x_TODO.md:82-135`): `LocalHistogramKernel: CIImageProcessorKernel`, `LocalHistogramMode: Int32 { identity 0, median 1, reduceNoise 2, outline 3 }`, `LocalHistogramParameters { mode, radius, percentile, strength, intensity }`, `makeOutput(input:parameters:context:)`, pipeline `"localHistogram"` loaded by `CoreImageBridge.computeFunctionNames`, `EffectRenderContext.computePipeline(_:)`; `Shaders/LocalHistogram.metal` — one thread per output row segment, per-thread histograms in a scratch `MTLBuffer` (4 × 256 `uint`, 4 KiB/thread, row batches capped at 64 MiB), the window given row by row as **`halfWidths`** (`constant int*`, index `v + r`), sliding add/remove of whole pixels, canvas-clipped (off-canvas pixels never counted). Test support: `LocalHistogramReference.render(_:width:height:radius:apply:)` (literal 3.36 `RenderRect` with a disk) and `LocalHistogramKernelTests`.
- **0026/0027/0043 blend ops:** `BlendOps.colorDodge(dst:src:)`, `BlendOps.darken(dst:src:)` (`compose(dst:src:f)` = Paint.NET's composition with exact rounding, `F(A = dst channel, B = src channel)`, `Sa == 0` → `dst`); `Shaders/BlendOps.h` (`ColorDodgeOp::apply(uint4 dst, uint4 src)`, `DarkenOp::apply`, included by `EffectKernels.metal` since 0043). Color Dodge `F = B == 255 ? 255 : min(255, A·255 / (255 − B))`; Darken `F = min(A, B)`. Paint.NET's `XxxBlendOp.Apply(lhs, rhs)` puts `lhs` **below** (`A`) and `rhs` **above** (`B`), so `Apply(lhs, rhs)` ≡ `BlendOps.xxx(dst: lhs, src: rhs)`.
- **0032 `BlackAndWhite.intensity(r:g:b:)`** = `GetIntensityByte` = `(7471·B + 38470·G + 19595·R) >> 16` (Paint.NET's `Desaturate`; the `DesaturateEffect` used by Pencil Sketch *is* this op). **0031 `InvertColors`**: RGB `255 − c`, alpha kept.
- **Lists before this spec (0067 `0067-distort-effects-v1x_TODO.md:239`, final):** `EffectRegistry.standard` ids (33) `["invertColors","brightnessContrast","blackAndWhite","hueSaturation","posterize","sepia","levels","autoLevel","curves","gaussianBlur","motionBlur","sharpen","vignette","addNoise","clouds","emboss","edgeDetect","pixelate","radialBlur","zoomBlur","surfaceBlur","unfocus","glow","softenPortrait","redEyeRemoval","median","reduceNoise","outline","relief","bulge","twist","polarInversion","tileReflection"]`; `effectSubmenus` `[(.blurs, ["Gaussian Blur","Motion Blur","Radial Blur","Surface Blur","Unfocus","Zoom Blur"]), (.distort, ["Bulge","Pixelate","Polar Inversion","Tile Reflection","Twist"]), (.noise, ["Add Noise","Median","Reduce Noise"]), (.photo, ["Glow","Red Eye Removal","Sharpen","Soften Portrait","Vignette"]), (.render, ["Clouds"]), (.stylize, ["Edge Detect","Emboss","Outline","Relief"])]`; `CoreImageBridgeTests.kernelsLoad` (28) `["invertColors","brightnessContrast","blackAndWhite","hueSaturation","channelLookup","luminosityCurve","gaussianBlurVertical","gaussianBlurHorizontal","motionBlur","sharpen","vignette","addNoise","clouds","emboss","edgeDetect","pixelate","radialBlur","zoomBlur","surfaceBlur","unfocusRowPrefix","unfocus","glowCompose","softenPortraitCompose","redEyeRemoval","bulge","twist","polarInversion","tileReflection"]`; 0066's `computePipelinesLoad` (`localHistogram`) unchanged.

**Paint.NET 3.36 behavior (transcribed from the sources cited above).**

- *Ink Sketch* (`InkSketchEffect`, submenu Artistic). Properties **Ink Outline** (int 0…99, default 50) and **Coloring** (int 0…100, default 50). `OnSetRenderInfo`: a `GlowEffect` with **Radius 6**, **Brightness = Contrast = `−(coloring − 50) · 2`** (coloring 50 → 0/0, 0 → +100/+100, 100 → −100/−100). `OnRender`: first the Glow renders `src → dst`; then for each pixel `(x, y)`:
  ```
  conv (rows j = 0…4 = dy −2…+2, columns i = 0…4 = dx −2…+2):
      [-1 -1 -1 -1 -1]
      [-1 -1 -1 -1 -1]
      [-1 -1 30 -1 -1]
      [-1 -1 -1 -1 -1]
      [-1 -1 -5 -1 -1]          (note: asymmetric; the weights sum to 2)
  r, g, b = Σ conv[j][i] · src(x+i−2, y+j−2).{R,G,B}   over taps INSIDE the image only (top/bottom/left/right clipped; no renormalization)
  top = FromBgr(ClampToByte(b), ClampToByte(g), ClampToByte(r))        // alpha 255
  I   = GetIntensityByte(top)                                          // Desaturate
  ink = I > inkOutline · 255 / 100 (integer division) ? (255,255,255,255) : (0,0,0,255)
  dst = DarkenBlendOp.Apply(lhs: ink, rhs: dst(glow))                  // ink below, glow on top
  ```
  The ink layer reads only RGB (alpha ignored) and is always opaque, so in 3.36 the result is **always opaque** — transparent areas become solid (white in 3.36, whose "transparent" is `(255,255,255,0)`; black in PaintDotMac, whose cleared pixels are `(0,0,0,0)`, D-27). See *Open questions* 1.
- *Pencil Sketch* (`PencilSketchEffect`, submenu Artistic). Properties **Pencil tip size** (int 1…20, default 2) and **Range** (int −20…+20, default 0). `OnRender` (all stages on `dst`, in place): `GaussianBlur(src, radius = tip size)` → `BrightnessAndContrast(brightness = range, contrast = −range)` → `InvertColors` → `Desaturate`; then per pixel `dst = ColorDodgeBlendOp.Apply(lhs: Desaturate(src), rhs: dst)` (desaturated original below, inverted desaturated blur on top).
- *Oil Painting* (`OilPaintingEffect`, submenu Artistic; **not** a `LocalHistogramEffect` subclass — it keeps its own per-pixel histogram). Properties **Brush size** (int 1…8, default 3) and **Coarseness** (int 3…255, default 50). Per pixel `(x, y)`, with `b = brush size`, `levels = coarseness`:
  ```
  window: the SQUARE x−b…x+b × y−b…y+b, clipped to the image (off-image pixels not counted)
  zero count[0…levels], sumR/G/B/A[0…levels]
  for each pixel p in the window:
      bin = FastScaleByteByByte(GetIntensityByte(p), levels)     // 0…levels;  FastScale(a, b) = ((a·b + 128) + ((a·b + 128) >> 8)) >> 8
      count[bin] += 1; sumR[bin] += p.R; sumG[bin] += p.G; sumB[bin] += p.B; sumA[bin] += p.A
  chosen = 0; maxCount = 0
  for i in 0…levels: if count[i] > maxCount { chosen = i; maxCount = count[i] }   // strict: ties keep the LOWEST bin
  out = (sumR[chosen] / maxCount, sumG… , sumB…, sumA[chosen] / maxCount)         // unsigned integer division (truncation); straight, not alpha-weighted ("TODO: correct handling of alpha values?")
  ```
  `maxCount ≥ 1` always (the pixel itself is in the window). All integer.

**Fidelity decision applied in this spec (0041's policy; *Open questions* 2–4).**
- **Oil Painting is bit-exact to 3.36** (all-integer; the GPU equals the oracle with **0 differences**, and the oracle is the literal 3.36 loop). No deviation.
- **Ink Sketch** = PaintDotMac's **Glow** (0065: clamp-to-edge, correct alpha — 0065's recorded deviations) + the **exact 3.36 ink layer** (integer convolution with **3.36's clipped taps** — the GPU skips off-canvas taps with a canvas rect, as 0042's Sharpen does — `GetIntensityByte`, the integer threshold) + exact Darken composition. Deviation beyond Glow's: the ink layer's alpha is the **source pixel's alpha** instead of 255 (*Open questions* 1), so transparent areas stay transparent; on opaque pixels this is identical to 3.36.
- **Pencil Sketch** = PaintDotMac's **Gaussian Blur** (0041) → **Brightness / Contrast** (0031, 3.36-exact) → Invert → Desaturate (exact integer) → exact Color Dodge composition. The only deviations are 0041's blur deviations (clamp-to-edge, correct alpha, rounding to nearest), which Color Dodge can amplify near `B ≈ 255`; GPU vs oracle uses 0065's **blur-tie rule** (±1 against one of the oracle's blur-tie candidates).

## User story

As a Paint.NET switcher, I open **Effects ▸ Artistic** — the first Effects submenu — and find **Ink Sketch…**, **Oil Painting…** and **Pencil Sketch…**. Ink Sketch opens with **Ink Outline 50, Coloring 50** and turns my photo into black pen outlines over a soft glow; Oil Painting with **Brush size 3, Coarseness 50** turns it into flat daubs of paint; Pencil Sketch with **Pencil tip size 2, Range 0** turns it into a gray pencil drawing on white. Each preview updates live, **OK** adds one step named after the effect that I can undo, **⌘F** repeats the last one, Escape on a long run restores the image exactly, and with a selection only the selected pixels change, with soft edges.

## Scope & changes

Cross-cutting rules: one file per effect conforming to `ImageEffect`, registered in `EffectRegistry.standard`; no hand-written dialog (AGENTS rule 5); every pixel change goes through 0031's `EffectSessionController` → `UndoBridge`; storage stays straight 8-bit sRGB (rule 4); rendering stays off the main actor in 0031's runner (rule 7); `Core` imports no AppKit/SwiftUI (D-19). **No change to any 0031 API.** Existing helpers are reused, never duplicated: Glow (0065), Gaussian Blur and Brightness / Contrast extraction points (0065 items 4–5), `BlackAndWhite.intensity` (0032), `BlendOps` / `BlendOps.h` Color Dodge and Darken (0026/0027/0043), `LocalHistogramKernel` (0066), `Unfocus.halfWidths` (0064).

### Core (pure, headless, unit-tested)

1. **`PaintDotMac/Core/Effects/Effects/Artistic/InkSketch.swift`** (new).
   ```swift
   public struct InkSketch: ImageEffect {
       public init()
       public let id = "inkSketch"
       public let name = "Ink Sketch"
       public let category = EffectCategory.artistic
       public var parameters: [EffectParameter] {
           [.init(id: "inkOutline", label: "Ink Outline", kind: .integer(range: 0...99,  defaultValue: 50)),
            .init(id: "coloring",   label: "Coloring",    kind: .integer(range: 0...100, defaultValue: 50))]
       }
       public var alphaMode: EffectAlphaMode { .straight }                   // blur kernels premultiply themselves (0041)
       public func inputPadding(for values: EffectParameterValues) -> Int    // = max(glowRadius, 2) = 6
       public static let glowRadius = 6
       public static let convolution: [[Int]]                                // the 5×5 3.36 `conv`, rows dy −2…+2, columns dx −2…+2
       public static func glowAdjustment(coloring: Int) -> Int               // −(coloring − 50) · 2  (Brightness and Contrast of the Glow)
       public static func threshold(inkOutline: Int) -> Int                  // inkOutline · 255 / 100 (integer)
       /// The ink pixel at (x, y): 3.36 clipped convolution of RGB, ClampToByte, GetIntensityByte (via BlackAndWhite.intensity), threshold.
       /// Alpha = source alpha at (x, y) (Open questions 1). `pixel(x, y)` is only called for in-canvas coordinates.
       public static func inkPixel(x: Int, y: Int, width: Int, height: Int, threshold: Int, pixel: (Int, Int) -> ColorRGBA8) -> ColorRGBA8
       public func makeOutput(input: CIImage, values: EffectParameterValues, context: EffectRenderContext) throws -> CIImage
   }
   ```
   - No shortcut (Paint.NET has none; PRD §5.12 lists none); icon `.effect`; menu title "Ink Sketch…"; dialog rows "Ink Outline:" and "Coloring:" (slider + integer field each); history step "Ink Sketch".
   - **Definition** (the oracle implements exactly this). For every pixel with straight source `S`:
     1. `G = Glow(S, radius: 6, brightness: k, contrast: k)` with `k = glowAdjustment(coloring)` — 0065's Glow definition exactly (bytes).
     2. `ink = inkPixel(x, y, …, threshold: threshold(inkOutline))` — `(v, v, v, S.a)` with `v ∈ {0, 255}`.
     3. `out = BlendOps.darken(dst: ink, src: G)` — 0027's composition (`G.a == 0` → `ink`).
   - **`makeOutput`**: `let k = Self.glowAdjustment(coloring: values.integer("coloring"))`; `let glow = try Glow.glowed(input, radius: Self.glowRadius, brightness: k, contrast: k, context: context)` (item 4); `let canvas = context.ciRect(PixelRect(x: 0, y: 0, width: context.canvasSize.width, height: context.canvasSize.height))`; `try context.kernel("inkSketch").apply(extent: context.ciRect(context.outputRect), roiCallback: { index, rect in index == 0 ? rect.insetBy(dx: -2, dy: -2) : rect }, arguments: [input.samplingNearest(), glow, Float(Self.threshold(inkOutline: values.integer("inkOutline"))), CIVector(cgRect: canvas)])`; nil → `EffectError.renderFailed`.
   - No early-out: Ink Sketch has no identity setting (ink outline 0 still turns black pixels black and others white).

2. **`PaintDotMac/Core/Effects/Effects/Artistic/PencilSketch.swift`** (new).
   ```swift
   public struct PencilSketch: ImageEffect {
       public init()
       public let id = "pencilSketch"
       public let name = "Pencil Sketch"
       public let category = EffectCategory.artistic
       public var parameters: [EffectParameter] {
           [.init(id: "pencilTipSize", label: "Pencil tip size", kind: .integer(range: 1...20,   defaultValue: 2)),
            .init(id: "range",         label: "Range",           kind: .integer(range: -20...20, defaultValue: 0))]
       }
       public var alphaMode: EffectAlphaMode { .straight }
       public func inputPadding(for values: EffectParameterValues) -> Int    // = pencilTipSize
       /// Brightness / Contrast arguments for a Range value: (brightness: range, contrast: −range).
       public static func brightnessContrast(range: Int) -> (brightness: Int, contrast: Int)
       /// Per-pixel tail of the chain (Invert → Desaturate → Color Dodge over the desaturated original).
       public static func sketchPixel(original s: ColorRGBA8, adjusted a: ColorRGBA8) -> ColorRGBA8
       public func makeOutput(input: CIImage, values: EffectParameterValues, context: EffectRenderContext) throws -> CIImage
   }
   ```
   - No shortcut; icon `.effect`; menu title "Pencil Sketch…"; rows "Pencil tip size:" and "Range:"; history step "Pencil Sketch".
   - **Definition.** For every pixel with straight source `S`:
     1. `Bl = GaussianBlur(S, radius: pencilTipSize)` — 0041's definition (bytes).
     2. `Adj = BrightnessContrast(Bl, brightness: range, contrast: −range)` — 0031's integer formula; `Adj.a = Bl.a`.
     3. `sketchPixel(S, Adj)`: `inv = (255 − Adj.r, 255 − Adj.g, 255 − Adj.b)` (Invert), `D = BlackAndWhite.intensity(r: inv.r, g: inv.g, b: inv.b)` (Desaturate → `(D, D, D, Adj.a)`), `g = BlackAndWhite.intensity(r: S.r, g: S.g, b: S.b)` (→ `(g, g, g, S.a)`), `out = BlendOps.colorDodge(dst: (g, g, g, S.a), src: (D, D, D, Adj.a))`.
   - **`makeOutput`**: `let (b, c) = Self.brightnessContrast(range: values.integer("range"))`; `let blurred = try GaussianBlur.blurred(input, radius: values.integer("pencilTipSize"), context: context)`; `let adjusted = try BrightnessContrast.adjusted(blurred, brightness: b, contrast: c, context: context)`; `return try context.colorKernel("pencilSketchCompose").apply(extent: context.ciRect(context.outputRect), arguments: [input, adjusted])` (nil → `.renderFailed`).
   - No identity setting (tip size ≥ 1).

3. **`PaintDotMac/Core/Effects/Effects/Artistic/OilPainting.swift`** (new).
   ```swift
   public struct OilPainting: ImageEffect {
       public init()
       public let id = "oilPainting"
       public let name = "Oil Painting"
       public let category = EffectCategory.artistic
       public var parameters: [EffectParameter] {
           [.init(id: "brushSize",  label: "Brush size", kind: .integer(range: 1...8,   defaultValue: 3)),
            .init(id: "coarseness", label: "Coarseness", kind: .integer(range: 3...255, defaultValue: 50))]
       }
       public var alphaMode: EffectAlphaMode { .straight }
       public func inputPadding(for values: EffectParameterValues) -> Int    // = brushSize
       /// Paint.NET's Utility.FastScaleByteByByte: r1 = a·b + 128; ((r1 >> 8) + r1) >> 8  (== round(a·b/255)).
       public static func fastScale(_ a: UInt8, _ b: UInt8) -> UInt8
       /// Intensity bin of a pixel: fastScale(BlackAndWhite.intensity(r:g:b:), coarseness), 0…coarseness.
       public static func bin(_ p: ColorRGBA8, coarseness: Int) -> Int
       /// The output for one window (closed definition used by unit tests; the oracle and the GPU use the loop form).
       public static func paint(window: [ColorRGBA8], coarseness: Int) -> ColorRGBA8
       public func makeOutput(input: CIImage, values: EffectParameterValues, context: EffectRenderContext) throws -> CIImage
   }
   ```
   - No shortcut; icon `.effect`; menu title "Oil Painting…"; rows "Brush size:" and "Coarseness:"; history step "Oil Painting".
   - **Definition** = the 3.36 loop in *Context* (square window clipped to the canvas, strict-max mode bin with ties to the lowest bin, truncating per-bin averages of R, G, B, A).
   - **`makeOutput`**: `try LocalHistogramKernel.makeOutput(input: input, parameters: .init(mode: .oilPainting, radius: values.integer("brushSize"), percentile: 0, strength: 0, intensity: 0, coarseness: values.integer("coarseness"), window: .square), context: context)` (item 5).
   - Sparse layers stay sparse: a window of `(0,0,0,0)` pixels → bin 0, averages 0 → `(0,0,0,0)` → all-zero output tiles stay `nil` and a fully transparent layer adds no step (H-6).

4. **`PaintDotMac/Core/Effects/Effects/Photo/Glow.swift`** (modify 0065, **no behavior change**): extract the body of `makeOutput` into `public static func glowed(_ input: CIImage, radius: Int, brightness: Int, contrast: Int, context: EffectRenderContext) throws -> CIImage` (blurred → adjusted → `glowCompose` over `ciRect(outputRect)`, exactly 0065 item 1); `makeOutput` becomes `try Self.glowed(input, radius: …, brightness: …, contrast: …, context: context)`. All 0065 tests stay green unchanged. (0065 already extracted `GaussianBlur.blurred` and `BrightnessContrast.adjusted`; this spec only uses them.)

5. **`PaintDotMac/Core/Rendering/LocalHistogramKernel.swift`** (extend 0066, additive; Median / Reduce Noise / Outline unchanged):
   ```swift
   public enum LocalHistogramMode: Int32, Sendable { case identity = 0, median = 1, reduceNoise = 2, outline = 3, oilPainting = 4 }
   public enum LocalHistogramWindow: Sendable, Equatable {
       case disk, square
       /// Row half-widths, index v + r: disk → Unfocus.halfWidths(radius:) (0064); square → Array(repeating: r, count: 2r + 1).
       public func halfWidths(radius: Int) -> [Int]
   }
   public struct LocalHistogramParameters: Sendable, Equatable {
       // 0066's fields unchanged, plus (defaulted so every 0066 call site compiles unchanged):
       public var coarseness: Int = 0                  // Oil Painting 3…255
       public var window: LocalHistogramWindow = .disk
   }
   public extension LocalHistogramKernel {
       /// Scratch words per thread: 1024 (4 × 256 channel histograms) for 0066's modes, 1280 (count + 4 sums × 256 bins) for .oilPainting.
       static func scratchWordsPerThread(for mode: LocalHistogramMode) -> Int
   }
   ```
   - `makeOutput` passes `parameters.window.halfWidths(radius:)` (instead of always `Unfocus.halfWidths`) and `coarseness`; the scratch buffer size and the 64 MiB row-batch cap use `scratchWordsPerThread(for:)`. The `roi` is unchanged (`insetBy(−r, −r)`, a square already covers both windows).

6. **`PaintDotMac/Core/Rendering/Shaders/LocalHistogram.metal`** (extend 0066): `LocalHistogramParams` gains `int coarseness` (appended last; the Swift-side mirror struct gains the same field in the same position); scratch addressing uses `gid · wordsPerThread` passed in the params (`int wordsPerThread`, also appended). New `oilPainting` branch, **literal 3.36 integer math**:
   - layout per thread: `count[0…255]`, `sumR[256]`, `sumG[256]`, `sumB[256]`, `sumA[256]` (1,280 `uint`; only `0…coarseness` used); **add/remove** of a pixel `p = px(cx, cy)` (straight bytes): `bin = fastScale(intensity(p), coarseness)` with `intensity = (7471·B + 38470·G + 19595·R) >> 16`, `fastScale(a, b) = ((a·b + 128) + ((a·b + 128) >> 8)) >> 8`; `count[bin] ±= 1`, `sum*[bin] ±= channel` (uint, never negative because only previously-added pixels are removed). Init/slide exactly as 0066 (the square window comes from the `halfWidths` buffer).
   - **apply**: `chosen = 0, maxCount = 0; for i in 0…coarseness: if count[i] > maxCount { chosen = i; maxCount = count[i] }`; `out = uint4(sumR[chosen], sumG[chosen], sumB[chosen], sumA[chosen]) / maxCount` (integer division), written as `float4(out) / 255`.
   - Overflow: window ≤ 17 × 17 = 289 pixels, sums ≤ 73,695 — fits `uint`. Cost ≈ coarseness + 2·17 updates per pixel.

7. **`PaintDotMac/Core/Rendering/Shaders/EffectKernels.metal`** (extend) — new section `// MARK: - Artistic` (`BlendOps.h` already included, 0043). Bytes are recovered with `uint(rint(clamp(v, 0.0, 1.0) * 255))` per channel (alpha included) and results return `float4(bytes) / 255`:
   ```metal
   // General kernel. 25 taps at exact texel centers (integer offsets from dest.coord()); input sampled nearest.
   [[stitchable]] float4 inkSketch(coreimage::sampler src, coreimage::sampler glow, float threshold, float4 canvas, coreimage::destination dest);
       // c = dest.coord(); int3 acc = 0;
       // for j in 0…4, i in 0…4: p = c + float2(i − 2, −(j − 2))   (CI is y up: canvas row y + (j − 2) is CI y − (j − 2))
       //     skip unless canvas.x <= p.x < canvas.x + canvas.z && canvas.y <= p.y < canvas.y + canvas.w   (3.36 clipped taps)
       //     acc += W[j][i] * int3(bytes(src.sample(src.transform(p))).rgb)        // W = InkSketch.convolution, as a constant array
       // uint3 t = uint3(clamp(acc, 0, 255)); uint I = (7471u·t.b + 38470u·t.g + 19595u·t.r) >> 16;
       // uint v = I > uint(threshold) ? 255u : 0u;  uint4 ink = uint4(v, v, v, bytes(src.sample(src.transform(c))).a);
       // return float4(DarkenOp::apply(ink, bytes(glow.sample(glow.transform(c))))) / 255;
   // Color kernel.
   [[stitchable]] float4 pencilSketchCompose(coreimage::sample_t original, coreimage::sample_t adjusted);
       // o = bytes(original); a = bytes(adjusted);
       // uint D = (7471u·(255u − a.b) + 38470u·(255u − a.g) + 19595u·(255u − a.r)) >> 16;
       // uint g = (7471u·o.b + 38470u·o.g + 19595u·o.r) >> 16;
       // return float4(ColorDodgeOp::apply(uint4(g, g, g, o.a), uint4(D, D, D, a.a))) / 255;
   ```
   Add `"inkSketch"`, `"pencilSketchCompose"` to `CoreImageBridge`'s kernel name list (after 0067's names). Oil Painting uses the existing `localHistogram` compute pipeline (no new name in `computeFunctionNames`).

8. **`PaintDotMac/Core/Effects/EffectRegistry.swift`** (extend): `standard` appends `InkSketch(), PencilSketch(), OilPainting()` after 0067's effects → 36 ids (0067's 33 + `"inkSketch","pencilSketch","oilPainting"`; full lists in *Test plan*, "Registry/menu/bridge"). `effectSubmenus` gains, **first** (EffectCategory order), `(.artistic, ["Ink Sketch", "Oil Painting", "Pencil Sketch"])` (sorted by name); every other entry is 0067's unchanged. `EffectSchemaValidator` reports no problems (50 ∈ 0…99, 50 ∈ 0…100, 2 ∈ 1…20, 0 ∈ −20…20, 3 ∈ 1…8, 50 ∈ 3…255).

### Platform glue (covered by integration and UI tests)

9. **`App/MainMenu.swift`** — **no code change**: `MainMenu.makeEffectsMenu(registry:)` builds Effects as "Repeat" (`menu.effects.repeat`, ⌘F), separator, then submenu **"Artistic"** (`menu.effects.artistic`) **first**, followed by 0067's submenus unchanged. Artistic items: **"Ink Sketch…"** (`menu.effects.artistic.inkSketch`, `representedObject` "inkSketch", action `runEffect(_:)`, no key equivalent), **"Oil Painting…"** (`menu.effects.artistic.oilPainting`, "oilPainting"), **"Pencil Sketch…"** (`menu.effects.artistic.pencilSketch`, "pencilSketch"). All go through 0031's `runEffect(_:)` / `repeatLastEffect(_:)` (guards, "Finish Pixels" first, dialog sheet, progress sheet after 0.5 s, `remember` + `recordApplied` on `.done`); Repeat titles "Repeat Ink Sketch", "Repeat Oil Painting", "Repeat Pencil Sketch". Nothing new in `DocumentWindowController`.

10. **`UI/EffectDialogView.swift`** — **no code change** (generated). Accessibility identifiers used by UI tests: `effectDialog.inkOutline`, `effectDialog.inkOutline.field`, `effectDialog.coloring`, `effectDialog.coloring.field`, `effectDialog.pencilTipSize`, `effectDialog.pencilTipSize.field`, `effectDialog.range`, `effectDialog.range.field`, `effectDialog.brushSize`, `effectDialog.brushSize.field`, `effectDialog.coarseness`, `effectDialog.coarseness.field`.

11. **Test support** (test target): `PaintDotMacTests/Effects/Reference/ReferenceEffectRenderer.swift` dispatches `"inkSketch"`, `"pencilSketch"`, `"oilPainting"` to the oracles below over the **whole source surface** (0041's rule).

12. **`project.yml`** — no change (existing globs cover the new `Artistic/` folders). Run `xcodegen generate` after adding files. No new persisted defaults (no `LaunchOptions.resettableKeyPrefixes` change). No PRD change (the decisions applied are listed under *Open questions* for the planner to record in PRD §5.9/§12).

## Acceptance criteria

- [ ] Effects ▸ **Artistic** is the first Effects submenu (after Repeat and the separator) and contains "Ink Sketch…", "Oil Painting…", "Pencil Sketch…" in that order, generated from `EffectRegistry.standard`; all other submenus are 0067's unchanged; no shortcuts added, none duplicated. → `EffectRegistryTests.standardContents`, `.effectSubmenus`, `MainMenuEffectsTests.effectsMenuItems`, `MainMenuTests.noDuplicateShortcuts`, `ArtisticEffectsUITests.testArtisticSubmenu`
- [ ] FX-E: Ink Sketch **Ink Outline 0…99 default 50, Coloring 0…100 default 50**; Pencil Sketch **Pencil tip size 1…20 default 2, Range −20…20 default 0**; Oil Painting **Brush size 1…8 default 3, Coarseness 3…255 default 50**; labels exactly as Paint.NET spells them. → `InkSketchTests.metadata`, `PencilSketchTests.metadata`, `OilPaintingTests.metadata`, `EffectSchemaValidatorTests.standardRegistryIsValid`, `ArtisticEffectsUITests.testInkSketchDefaultsAndOK`, `.testPencilSketchDialogAndRepeat`, `.testOilPaintingDefaultsAndCancel`
- [ ] Ink Sketch = Glow(6, k, k) with `k = −(coloring − 50)·2` + the exact 3.36 ink layer (asymmetric 5×5 kernel, clipped taps, `GetIntensityByte`, threshold `inkOutline·255/100`) with the source alpha, Darken-composed; GPU within ±1 of an oracle candidate (blur-tie rule). → `InkSketchTests.*`, `InkSketchReferenceTests.*`, `ArtisticGoldenTests.inkSketch*`
- [ ] Pencil Sketch = 0041 Gaussian Blur(tip) → 0031 Brightness / Contrast(range, −range) → Invert → Desaturate → Color Dodge over the desaturated original; GPU within ±1 of an oracle candidate. → `PencilSketchTests.*`, `PencilSketchReferenceTests.*`, `ArtisticGoldenTests.pencilSketch*`
- [ ] Oil Painting equals Paint.NET 3.36 bit-exactly (square clipped window, `FastScaleByteByByte` bins, strict-max mode with ties to the lowest bin, truncating averages incl. alpha); GPU == oracle with **0 differences**. → `OilPaintingTests.*`, `OilPaintingReferenceTests.*`, `ArtisticGoldenTests.oilPainting*`, `LocalHistogramKernelTests.squareWindowHalfWidths`
- [ ] Reuse: Ink Sketch's glow is `Glow.glowed` (Glow's own results unchanged), Pencil Sketch uses `GaussianBlur.blurred` + `BrightnessContrast.adjusted` + `BlendOps`' Color Dodge, Oil Painting runs on 0066's `LocalHistogramKernel`; 0065's and 0066's tests stay green unchanged. → `PhotoV1xGoldenTests.*`, `NoiseV1xGoldenTests.*`, `StylizeV1xGoldenTests.outline*`, `LocalHistogramKernelTests.*`, `GlowTests.*`
- [ ] FX-D: with a selection only selected pixels change, antialiased edges blended by 0031's mask blend. → `ArtisticGoldenTests.selectionBlend`, `ArtisticEffectsIntegrationTests.selectionClippedApply`
- [ ] FX-C / H-1: OK commits exactly one step named "Ink Sketch" / "Pencil Sketch" / "Oil Painting" (icon `.effect`); preview adds no step; Cancel and Escape restore the image exactly; undo/redo restore exact bytes; ⌘F repeats with the last values. → `ArtisticEffectsIntegrationTests.*`, `ArtisticEffectsUITests.*`
- [ ] Results are chunk-independent (no seams at 256 px tile / chunk borders). → `ArtisticGoldenTests.chunkSeamsInvisible`
- [ ] Fidelity vs literal 3.36 is documented and tested where definitions coincide. → `ArtisticFidelityTests.*`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **1×1, 1×N, N×1, 2×2, 4×4 images:** Ink Sketch's clipped convolution has fewer taps (1×1: weight 30 only → `30·c` clamped); Oil Painting's window clips to the image (1×1 → the pixel itself); Pencil Sketch's blur clamps. No crash, no out-of-range reads. → `InkSketchReferenceTests.tinyImages`, `OilPaintingReferenceTests.tinyImages`, `ArtisticGoldenTests.tinyImagesGPU`
- **Canvas edges:** Ink Sketch's edge rows/columns see different weight sums (hand map below — edges get *brighter* ink sums, as in 3.36); the GPU must skip off-canvas taps, not clamp them. → `InkSketchTests.weightSumMap`, `ArtisticGoldenTests.inkSketchEdges`
- **Fully transparent layer:** Ink Sketch → stays `(0,0,0,0)` (ink alpha = source alpha 0, glow alpha 0) → tiles stay unallocated, no step; Pencil Sketch → `(0,0,0,0)` (Color Dodge with `Sa = 0` returns dst = `(0,0,0,0)`), no step; Oil Painting → `(0,0,0,0)`, no step. → `ArtisticEffectsIntegrationTests.emptyLayerAddsNoStep`
- **Opaque content next to transparency:** Glow / blur halos spread into transparent pixels (0065 behavior); Oil Painting may pick bin 0 where transparent black pixels dominate the window (erodes edges by up to `brushSize`, as 3.36 does). → `OilPaintingReferenceTests.transparentNeighborsDominate`
- **Semi-transparent pixels:** Oil Painting averages alpha and color straight (3.36); Ink Sketch uses the source alpha for the ink; Pencil Sketch composes with `Adj.a` = blurred alpha. → `ArtisticGoldenTests.semiTransparentFixture`
- **Ties:** Oil Painting bins with equal counts → lowest bin wins. → `OilPaintingTests.tieKeepsLowestBin`
- **Extreme parameters:** Ink Outline 0 (threshold 0: only intensity-0 ink is black) and 99 (threshold 252); Coloring 0 (glow +100/+100 — Contrast 100 is 0031's `divide == 0` threshold branch) and 100 (−100/−100); Range ±20; Pencil tip size 20; Brush size 8; Coarseness 3 and 255 (`fastScale(v, 255) == v`). → `ArtisticGoldenTests.*Grid`, `OilPaintingTests.fastScale`
- **Large brush / tip across chunks:** apron = `inputPadding` (6, tip size, brush size); results identical to a whole-canvas render. → `ArtisticGoldenTests.chunkSeamsInvisible`
- **Cancel mid-run** (large image): original restored byte-identically, no step, `!isBusy`. → `ArtisticEffectsIntegrationTests.cancelRestoresExactly`
- **Missing kernel / pipeline:** `kernel("inkSketch")` / `colorKernel("pencilSketchCompose")` absent → `.kernelMissing(name)`; `localHistogram` absent → `.kernelMissing("localHistogram")` → 0031's "The effect couldn’t be applied.", original restored, no crash. → `CoreImageBridgeTests.kernelsLoad`, `CoreImageBridgeTests.computePipelinesLoad`, 0031 `EffectSessionIntegrationTests.rendererErrorRestores` (path)
- **Hidden layer / floating pixels / busy document:** handled by 0031's guards ("Finish Pixels" first; effects run on hidden layers) — no new path.

## Test plan

Expected values below were hand-computed from the formulas above (gray `(v,v,v,255)` is written `v`; `intensity(v,v,v) = v` because the weights sum to 65,536).

- **CPU oracles** (`PaintDotMacTests/Effects/Reference/`, independent of the Core code and of the Metal code):
  - `InkSketchReference.apply(_:width:height:inkOutline:coloring:) -> [ColorRGBA8]` and `candidates(...) -> [[ColorRGBA8]]`: `GlowReference.apply`/`.candidates` (0065) with radius 6 and `k = -(coloring - 50) * 2` (written independently of `InkSketch.glowAdjustment`), a literal transcription of the 3.36 `OnRender` ink loop (its own `conv` table, `top/bottom/left/right` clipping, `ClampToByte(int)`, `GetIntensityByte` written out, `inkOutline * 255 / 100`) with ink alpha = source alpha, then `BlendReference.compositeDouble(.darken, dst: ink, src: G, opacity: 255, realF: false)` rounded half up (`G.a == 0` → ink).
  - `PencilSketchReference.apply(_:width:height:pencilTipSize:range:)` / `candidates(...)`: `GaussianBlurReference.apply` (or `BlurStageCandidates.candidates`) → `BrightnessContrastReference.apply(_, brightness: range, contrast: -range)` → `InvertColorsReference.apply` → `BlackAndWhiteReference.apply` → per pixel `BlendReference.compositeDouble(.colorDodge, dst: BlackAndWhiteReference(S), src: D, …)` rounded half up.
  - `OilPaintingReference.apply(_:width:height:brushSize:coarseness:) -> [ColorRGBA8]`: **literal transcription of 3.36 `OilPaintingEffect.OnRender`** (zeroed `intensityCount`/`avgRed`/… arrays of length `1 + coarseness` per pixel, the clipped `top/bottom/left/right` loops, `FastScaleByteByByte` and `GetIntensityByte` written out, the strict `>` mode loop, `UInt32` truncating division). Independent of `LocalHistogramReference` and of `OilPainting.paint`.
  - `PaintDotNet336InkSketch.apply(...)`, `PaintDotNet336PencilSketch.apply(...)`: literal 3.36 chains — `PaintDotNet336Glow` (0065), `PaintDotNet336GaussianBlur` (0041), `BrightnessContrastReference`, invert/desaturate, `BlendReference.paintNET336Composite`; ink alpha 255 (3.36). Used only by `ArtisticFidelityTests`.
- **Unit — `PaintDotMacTests/Effects/Artistic/InkSketchTests.swift`:**
  - `metadata`: id "inkSketch", name "Ink Sketch", `.artistic`, parameters in order `inkOutline` "Ink Outline" `.integer(0...99, default 50, step 1)`, `coloring` "Coloring" `.integer(0...100, 50)`, `hint == nil`, `menuTitle` "Ink Sketch…", no shortcut, icon `.effect`, `.straight`; `inputPadding` == 6 for any values.
  - `convolutionTable`: rows `[-1,-1,-1,-1,-1]`, `[-1,-1,-1,-1,-1]`, `[-1,-1,30,-1,-1]`, `[-1,-1,-1,-1,-1]`, `[-1,-1,-5,-1,-1]`; sum 2.
  - `glowAdjustment`: coloring 0 → 100, 25 → 50, 50 → 0, 51 → −2, 100 → −100. `threshold`: 0 → 0, 50 → 127, 99 → 252, 1 → 2.
  - `weightSumMap` (uniform gray 1 on 9×9 → `inkPixel` sums before clamping, exposed by evaluating `inkPixel` on uniform `v` and checking the threshold flip): interior 2; top edge (y 0, x 2…6) 12; second row (y 1) 7; bottom edge (y 8) 16; y 7 → 11; left edge (x 0) 12; x 1 → 7; right edge (x 8) 12; x 7 → 7; corners TL 18, TR 18, BL 22, BR 22. Checked through thresholds: uniform 10, Ink Outline 50 (threshold 127): interior `20 ≤ 127` → ink 0; TL `180 > 127` → 255; top edge `120` → 0; bottom edge `160` → 255; y 1 `70` → 0.
  - `inkThresholdFlip` (interior of a uniform 9×9): 63 → `126 ≤ 127` → 0; 64 → `128` → 255; Ink Outline 99 on 200 → `min(255, 400) = 255 > 252` → 255; on 126 → `252 ≤ 252` → 0; Ink Outline 0 on 0 → 0, on 1 → `2 > 0` → 255.
  - `inkUsesIntensityOfClampedChannels`: interior of uniform `(200, 10, 10, 255)`: sums `(400, 20, 20)` → clamped `(255, 20, 20)` → `I = (7471·20 + 38470·20 + 19595·255) >> 16 = (149,420 + 769,400 + 4,996,725) >> 16 = 5,915,545 >> 16 = 90` → `90 ≤ 127` → black.
  - `inkAlphaIsSourceAlpha`: uniform `(100,100,100,128)` → ink `(255,255,255,128)`; `(0,0,0,0)` → `(0,0,0,0)`.
- **Unit — `PaintDotMacTests/Effects/Artistic/InkSketchReferenceTests.swift`** (oracle vs hand math):
  - `handValuesDefaults` (uniform 9×9, defaults; glow = 0065's Screen of `v` over `v` at B/C 0): 100 → ink 255, glow `200 − round(10000/255) = 161` → **161** everywhere interior; 50 → ink `100 ≤ 127` → 0 → **0**; 10 → interior **0**, TL corner ink 255, glow `20 − 0 = 20` → **20**.
  - `handValuesColoring100` (uniform 100, coloring 100 → B/C −100/−100; 0065 `contrastExtremes`: Glow → 116): ink 255 → **116**.
  - `tinyImages`: 1×1 `v = 5` → sum `30·5 = 150 > 127` → ink 255; glow of 5 = `10 − 0 = 10` → **10**; 1×1 `v = 4` → `120` → **0**.
  - `transparentStaysTransparent`: 20×20 `(0,0,0,0)` → every pixel `(0,0,0,0)`.
- **Unit — `PaintDotMacTests/Effects/Artistic/PencilSketchTests.swift`:** `metadata` (id "pencilSketch", name "Pencil Sketch", `.artistic`, `pencilTipSize` "Pencil tip size" `.integer(1...20, 2)`, `range` "Range" `.integer(-20...20, 0)`, "Pencil Sketch…", no shortcut, `.effect`, `.straight`); `inputPaddingEqualsTipSize` (1, 2, 20); `brightnessContrastMapping` (−20 → (−20, 20), 0 → (0, 0), 7 → (7, −7)); `sketchPixel` hand values: `original 100, adjusted 125` → `inv 130`, `D 130`, `g 100` → `100·255 / 125 = 204` → `(204,204,204,255)`; `original 200, adjusted 150` → `D 105` → `51000/150 = 340` → 255; `adjusted 0` → `D 255` → 255 (Color Dodge guard); `original 0, adjusted 50` → `0`; `original (0,0,0,0)`, `adjusted (0,0,0,0)` → `(0,0,0,0)` (`Sa = 0` → dst).
- **Unit — `PaintDotMacTests/Effects/Artistic/PencilSketchReferenceTests.swift`:**
  - `uniformIsWhite`: uniform 100 (any size, tip 2, range 0) → 255 everywhere (blur exact, `100·255/100`); uniform 0 → 255 (`B = 255` guard).
  - `rowHandValues`: 3×1 `[100, 200, 100]`, tip 1, range 0 → blur (vertical clamps to the same row; horizontal tent `[1,2,1]/4`, clamp) `[125, 150, 125]` → `D = [130, 105, 130]` → **`[204, 255, 204]`**, alpha 255.
  - `rangeHandValues` (uniform 100, tip 2): range 20 → B/C (20, −20): `multiply 80, divide 100`, `shift = (100−127)·80/100 + 127 − 100 + 20 = −21 + 47 = 26` → `Adj 126` → `D 129` → `25500 / 126 = 202` → **202**; range −20 → B/C (−20, 20): `multiply 100, divide 80`, `shift = (100 − 127 − 20)·100/80 + 27 = −58 + 27 = −31` → `Adj 69` → `25500/69 = 369` → **255**.
- **Unit — `PaintDotMacTests/Effects/Artistic/OilPaintingTests.swift`:**
  - `metadata` (id "oilPainting", name "Oil Painting", `.artistic`, `brushSize` "Brush size" `.integer(1...8, 3)`, `coarseness` "Coarseness" `.integer(3...255, 50)`, "Oil Painting…", no shortcut, `.effect`, `.straight`); `inputPaddingEqualsBrushSize` (1, 3, 8).
  - `fastScale`: `(100, 50)` → 20; `(104, 50)` → 20; `(110, 50)` → 22; `(200, 50)` → 39; `(255, 50)` → 50; `(0, x)` → 0; exhaustive: `fastScale(a, b) == (a·b + 127) / 255` for all 65,536 pairs; `fastScale(v, 255) == v`.
  - `binOfColor`: `(200,100,50,255)` → intensity 124 → `fastScale(124, 50) = 24` (`6328 → (6328 + 24) >> 8 = 24`).
  - `paintHandValues`: window of five 100s, one 104, three 200s (coarseness 50) → bins 20 ×6, 39 ×3 → **`(100,100,100,255)`** (`604 / 6 = 100`); `tieKeepsLowestBin`: window `[100, 200]` → bins 20 and 39 each 1 → **100**; alpha averaging: `[(100,100,100,255), (100,100,100,0)]` → bin 20 ×2 → `(100,100,100,127)`.
- **Unit — `PaintDotMacTests/Effects/Artistic/OilPaintingReferenceTests.swift`:** `handValues3x3` (the `paintHandValues` window as a 3×3 image, brush 1 → center `(100,100,100,255)`; corner (0,0) window = 2×2 top-left); `tinyImages` (1×1 → unchanged pixel for any brush/coarseness; 2×1 `[100, 200]` → both 100); `transparentNeighborsDominate` (3×3, center opaque 200, eight `(0,0,0,0)`, brush 1 → center `(0,0,0,0)`); `paintMatchesOracle` (300 seeded random windows: `OilPainting.paint(window:coarseness:)` == the oracle's per-pixel result for a 1×1-center extraction).
- **Unit/GPU — `PaintDotMacTests/Rendering/LocalHistogramKernelTests.swift`** (extend 0066): `squareWindowHalfWidths` (`.square.halfWidths(radius: 3) == [3,3,3,3,3,3,3]`; `.disk.halfWidths(radius: r) == Unfocus.halfWidths(radius: r)` for r ∈ {0, 1, 10}); `scratchWords` (median/reduceNoise/outline/identity 1024, oilPainting 1280); `oilPaintingRowBatchesEqualSingleBatch` (1 MiB test-only cap, brush 8, coarseness 255 → identical bytes to uncapped); 0066's existing tests unchanged.
- **Golden — `PaintDotMacTests/Effects/Artistic/ArtisticGoldenTests.swift`** (new; real `CoreImageBridge` through `bridge.renderEffect`, seeded fixtures from `TestImages`/`SeededRandom` printing the seed; Ink/Pencil compared with 0065's **blur-tie rule**: every GPU pixel within ±1 of at least one oracle candidate, count of ±1 differences reported; Oil exact):
  - `inkSketchGrid`: inkOutline ∈ {0, 1, 50, 98, 99} × coloring ∈ {0, 25, 50, 75, 100} on a 300×200 photo-like fixture (gradients + noise + hard edges); `inkSketchRandom` (6 seeded); `inkSketchEdges` (9×9 and 300×200, edge rows/columns == oracle; fails if the kernel clamps instead of skipping).
  - `pencilSketchGrid`: tip ∈ {1, 2, 5, 20} × range ∈ {−20, −1, 0, 1, 20}; `pencilSketchRandom` (6 seeded).
  - `oilPaintingGrid`: brush ∈ {1, 2, 3, 8} × coarseness ∈ {3, 4, 50, 128, 255} → **0 differences**; `oilPaintingRandom` (6 seeded); `oilPaintingAcrossTiles` (brush 8 on 260×260 crossing the 256 border → 0 differences).
  - `tinyImagesGPU`: 1×1, 1×7, 7×1, 2×2, 4×4 for all three effects at defaults and at max sizes (ink defaults, tip 20, brush 8) → oracle rules above.
  - `semiTransparentFixture`: alpha gradient 0…255 with seeded colors, all three effects at defaults.
  - `chunkSeamsInvisible`: runner with `chunkTiles 1, maxConcurrentChunks 4` == single whole-canvas render (exact bytes) for Ink Sketch (defaults), Pencil Sketch (tip 20), Oil Painting (brush 8), on 600×520.
  - `selectionBlend`: antialiased ellipse + each effect through the runner vs oracle (whole layer) + `MaskBlendReference` (±1 / exact for Oil); coverage-0 pixels byte-identical.
- **Fidelity — `PaintDotMacTests/Effects/Artistic/ArtisticFidelityTests.swift`** (documents the deviations):
  - `oilPaintingIsLiteral336`: the oracle *is* the literal transcription — assert `OilPaintingReference` equals a second, independently written direct-definition loop (`OilPainting.paint` over each clipped window) on 4 seeded images (exact).
  - `inkLayerMatches336OnOpaque`: on opaque fixtures, the ink layer of `InkSketchReference` equals `PaintDotNet336InkSketch`'s ink layer exactly (including edges).
  - `inkSketchMatches336OnUniformOpaque` / `pencilSketchMatches336OnUniformOpaque`: on uniform opaque blocks larger than the blur apron (interior of 64×64 blocks of gray 10, 100, 200), full results equal the 3.36 chains exactly; on a seeded opaque photo-like fixture, report the max and 99th-percentile difference in interiors (≥ 6 px / ≥ tip size from edges) — recorded in the Verification status, asserted ≤ 255 only (Color Dodge amplifies 1-step blur differences by up to `255/(255 − B)`).
  - `inkSketchTransparentDiffers` (documents *Open questions* 1): uniform `(0,0,0,0)` 9×9 → PaintDotMac `(0,0,0,0)`, 3.36 chain (with PaintDotMac's transparent black input) → opaque `(0,0,0,255)`.
- **Integration — `PaintDotMacTests/Document/ArtisticEffectsIntegrationTests.swift`** (new; `@MainActor`, real `UndoBridge`, 600×400 two-layer document, layer 1 seeded opaque active, layer 0 opaque; `debounce: .zero`; real bridge for pixels):
  - `inkSketchOkCommitsOneStep` (defaults → one step "Ink Sketch", icon `.effect`, pixels per the golden rule; undo → original tiles share storage; redo → committed bytes); `pencilSketchOkCommitsOneStep` ("Pencil Sketch"); `oilPaintingOkCommitsOneStep` ("Oil Painting", == oracle exactly).
  - `previewWithoutStepAndCancel` (Oil Painting: no step after preview; Cancel restores storage identity; `!isBusy`).
  - `repeatUsesLastValues` (Pencil Sketch tip 5 range 10 OK, Repeat → two "Pencil Sketch" steps, second == oracle applied to the first result; two undos → original); `valuesRemembered` (Oil Painting OK brush 6 → reopen shows 6; cancelled 2 → still 6).
  - `selectionClippedApply` (rect (100,100,200,100), Ink Sketch defaults → outside byte-identical; inside == oracle on the whole layer, golden rule).
  - `emptyLayerAddsNoStep` (empty layer 1: each of the three effects → no step, no allocated tiles, `lastApplied` = that effect).
  - `onlyActiveLayerChanges` (layer 0 storage identity after each effect).
  - `cancelRestoresExactly` (2048×2048, Oil Painting brush 8 coarseness 255, cancel after the first progress callback → storage identity, no step, `!isBusy`).
- **Unit — registry/menu/bridge** (full lists, extending 0067's exactly):
  - `EffectRegistryTests.standardContents` → `["invertColors","brightnessContrast","blackAndWhite","hueSaturation","posterize","sepia","levels","autoLevel","curves","gaussianBlur","motionBlur","sharpen","vignette","addNoise","clouds","emboss","edgeDetect","pixelate","radialBlur","zoomBlur","surfaceBlur","unfocus","glow","softenPortrait","redEyeRemoval","median","reduceNoise","outline","relief","bulge","twist","polarInversion","tileReflection","inkSketch","pencilSketch","oilPainting"]` (36 ids = 0067's 33 + 3).
  - `EffectRegistryTests.effectSubmenus` → `[(.artistic, ["Ink Sketch","Oil Painting","Pencil Sketch"]), (.blurs, ["Gaussian Blur","Motion Blur","Radial Blur","Surface Blur","Unfocus","Zoom Blur"]), (.distort, ["Bulge","Pixelate","Polar Inversion","Tile Reflection","Twist"]), (.noise, ["Add Noise","Median","Reduce Noise"]), (.photo, ["Glow","Red Eye Removal","Sharpen","Soften Portrait","Vignette"]), (.render, ["Clouds"]), (.stylize, ["Edge Detect","Emboss","Outline","Relief"])]`.
  - `MainMenuEffectsTests.effectsMenuItems` → Repeat, separator, submenu **Artistic** (`menu.effects.artistic`) exactly `[("Ink Sketch…", "", [], runEffect:, "inkSketch", "menu.effects.artistic.inkSketch"), ("Oil Painting…", "", [], runEffect:, "oilPainting", "menu.effects.artistic.oilPainting"), ("Pencil Sketch…", "", [], runEffect:, "pencilSketch", "menu.effects.artistic.pencilSketch")]`, then 0067's submenus Blurs, Distort, Noise, Photo, Render, Stylize exactly as 0067 lists them; `MainMenuTests.noDuplicateShortcuts` passes.
  - `CoreImageBridgeTests.kernelsLoad` → `["invertColors","brightnessContrast","blackAndWhite","hueSaturation","channelLookup","luminosityCurve","gaussianBlurVertical","gaussianBlurHorizontal","motionBlur","sharpen","vignette","addNoise","clouds","emboss","edgeDetect","pixelate","radialBlur","zoomBlur","surfaceBlur","unfocusRowPrefix","unfocus","glowCompose","softenPortraitCompose","redEyeRemoval","bulge","twist","polarInversion","tileReflection","inkSketch","pencilSketchCompose"]` (30 names = 0067's 28 + 2); `computePipelinesLoad` unchanged (`localHistogram`).
  - `EffectSchemaValidatorTests.standardRegistryIsValid` stays green with the new effects.
- **UI tests — `PaintDotMacUITests/ArtisticEffectsUITests.swift`** (new; `UITestApp.launch(opening:)` with a generated 400×300 opaque gradient PNG fixture, `UITestApp.chooseMenuItem("Effects", "Artistic", …)`):
  - `testArtisticSubmenu`: the Effects menu's first submenu after Repeat is "Artistic"; it lists "Ink Sketch…", "Oil Painting…", "Pencil Sketch…" in order, all enabled.
  - `testInkSketchDefaultsAndOK`: open Ink Sketch… → `effectDialog` shows `effectDialog.inkOutline.field` "50" and `effectDialog.coloring.field` "50"; OK → `historyRow.1` titled "Ink Sketch"; ⌘Z → History back to 1 row.
  - `testPencilSketchDialogAndRepeat`: set `effectDialog.pencilTipSize.field` to "5", `effectDialog.range.field` to "-10", OK → "Pencil Sketch" row; Effects ▸ "Repeat Pencil Sketch" (⌘F) → a second "Pencil Sketch" row without a dialog.
  - `testOilPaintingDefaultsAndCancel`: open Oil Painting… → fields "3" and "50"; Cancel → no new history row; then OK with defaults → "Oil Painting" row; save through the panel as PNG and check (via `ImageDecoder` in the test) that a pixel of a flat fixture region equals the oracle value computed in the test.
- **Performance:** no new NF target; record in the Verification status the time of each effect at defaults on a 4000×3000 image (`ArtisticPerformanceTests`, `measure`, gating only at 3× the median of 0066's Median r 10 measurement).
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open a real photo (≥ 12 MP), run each Artistic effect at defaults: the preview fills the visible area first and stays responsive while dragging sliders; results look like Paint.NET's (ink lines over a glow; flat oil daubs; gray pencil lines on white).
  2. Ink Sketch on a layer with transparent areas: transparent areas stay transparent (compare with *Open questions* 1).
  3. Escape during an Oil Painting run at Brush size 8 / Coarseness 255 on a 24 MP image: cancels promptly, image unchanged.

## Open questions

Recommended answers are applied in the spec above.

1. **Ink Sketch on transparent pixels: Paint.NET 3.36 always outputs opaque pixels (its ink layer is opaque), which in PaintDotMac would turn every transparent area (stored as `(0,0,0,0)`) solid black — Paint.NET's own transparent white turned solid white.** Recommended (applied): give the ink layer the **source pixel's alpha**, so transparent areas stay transparent and sparse layers stay sparse; opaque pixels are identical to 3.36. Alternative: literal 3.36 (whole layer becomes opaque, black where it was transparent).
2. **Oil Painting is a bit-exact port of 3.36 (square window, intensity bins scaled by Coarseness, mode with ties to the lowest bin, straight per-bin averages including alpha, window clipped at the canvas edge), run on 0066's local-histogram compute kernel with a square window.** Note for the planner: the brief described Oil Painting as a `LocalHistogramEffect` mode — in 3.36 it is *not* a `LocalHistogramEffect` (it keeps its own intensity histogram with averages), but 0066's sliding-window compute kernel fits it, so it is added as a fifth mode there. Recommended: yes.
3. **Ink Sketch and Pencil Sketch are built from PaintDotMac's own Glow / Gaussian Blur (0041/0065: clamp-to-edge, correct alpha, rounding to nearest) instead of bit-exact 3.36 chains; the ink convolution keeps 3.36's clipped (skipped) edge taps.** Consequences: identical to 3.36 on uniform opaque areas; elsewhere small blur differences, which Pencil Sketch's Color Dodge can amplify where the inverted blur is near white. Recommended: yes (consistent with 0041/0065).
4. **Ranges, defaults and labels come from the 3.36 source because the docs give none** (Ink Outline 0–99 default 50, Coloring 0–100 default 50; Pencil tip size 1–20 default 2, Range −20–20 default 0; Brush size 1–8 default 3, Coarseness 3–255 default 50; labels "Ink Outline", "Coloring", "Pencil tip size", "Range", "Brush size", "Coarseness" — the docs use the same names). Paint.NET 5's dialog couldn't be inspected — please compare if you have it. Recommended: yes.

## Out of scope

- Other Artistic effects of later Paint.NET versions (none planned in PRD §5.9).
- Moving Sharpen onto `LocalHistogramKernel` (0066 *Out of scope*).
- Render and Object effects (0069: Julia Fractal, Mandelbrot Fractal, Drop Shadow, Outline Object).
- P2 effects (PRD §5.9 "Later").
