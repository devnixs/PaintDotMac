# 0003 — Show the document on a Retina-aware Metal canvas with a checkerboard, nearest-neighbor zoom-in and mipmapped zoom-out

> Source: PRD.md §5.2 CAN-3 (nearest-neighbor above 100 %, high-quality downsampling below), CAN-4 (checkerboard behind transparency), CAN-6 (Retina-aware: one image pixel maps correctly to device pixels at every zoom); PRD.md §4 "Rendering" (D-16: Metal for display only, CPU compositor is the reference), NF-9 (straight sRGB RGBA8, premultiplied only in the compositor), NF-2 (pan/zoom ≥ 60 fps), §8 M0 ("display it on the Metal canvas"), §10 R-1 (Metal canvas complexity); AGENTS.md rules 1, 3, 4, 7.
> Milestone: M0
> Depends on: 0001-project-and-document-shell, 0002-tiled-surface-and-image-decoding

## Context

Not yet implemented: there is no application code yet. When this spec starts, the earlier specs have created (names from the backlog sibling map; if an earlier spec landed a slightly different spelling or signature, use what is in the code and keep the behavior below):

- **0001**: `project.yml` (scheme `PaintDotMac`; targets `PaintDotMac`, `PaintDotMacTests` hosted by the app, `PaintDotMacUITests`), `PaintDotMac/App/main.swift`, `AppDelegate.swift`, `App/MainMenu.swift`, `App/LaunchOptions.swift` (`-UITestOpen <path>`, `-ApplePersistenceIgnoreState YES`, `-UITestResetDefaults`), `PaintDotMac/Document/PaintDocument.swift` (NSDocument subclass), `PaintDotMac/Document/DocumentWindowController.swift`, and a **temporary** `PaintDotMac/Canvas/PlaceholderImageView.swift` (+ `PaintDotMacTests/Canvas/PlaceholderImageViewTests.swift`) that this spec deletes. The placeholder's accessibility is a **contract** 0001 asks this spec to keep: element, role `.image` (or `.group` if 0001 recorded that XCUITest needs it), identifier `canvas`, label `Canvas`, value `"<width> × <height>"` (U+00D7, e.g. `"64 × 48"`), which `LaunchUITests` asserts. `DocumentWindowController.initialContentSize(imageSize:visibleFrameSize:)` sizes a new window counting one image pixel as one point (80 % of the screen's visible frame at most, 480×360 at least). Test support `PaintDotMacUITests/Support/UITestApp.swift` (`makePNG(named:width:height:rgba:)` solid-color fixtures in a temp dir, `launch(opening:)`, `canvas`, `documentWindows`), `PaintDotMacUITests/LaunchUITests.swift`, `PaintDotMacTests/Document/DocumentWindowControllerTests.swift`.
- **0002**: `Core/Model/PixelFormat.swift`, `Core/Model/ColorRGBA8.swift` (straight sRGB RGBA8), `Core/Model/PixelSize.swift` (`PixelSize`, `PixelRect`, `PixelPoint`), `Core/Model/TiledSurface.swift` (256×256 sparse copy-on-write tiles, `TileCoordinate`, pixel/region read & write, change tracking through `generation` + `changedTiles(since:)`, `tile(at:)`), `Core/Model/ImageLimits.swift`, `Core/Model/BlendMode.swift` (`.normal` only), `Core/Model/Layer.swift` (`id`, `name`, `isVisible`, `opacity: UInt8`, `blendMode`, `surface`), `Core/Model/LayeredImage.swift` (`size`, `dpi`, `layers` bottom-to-top, `activeLayerIndex`); `PaintDocument` loads PNG/JPEG into a `LayeredImage` with exactly one layer. Test support `PaintDotMacTests/Support/TestImages.swift` and `SeededRandom.swift`.

What is missing: the document window shows the image through a placeholder view (0001), which is neither tiled, nor Retina-exact, nor able to show transparency. PRD §8 M0 requires the image to be displayed **on the Metal canvas**, and §5.2 requires:

- **CAN-3** "Nearest-neighbor rendering when zoomed above 100%, and high-quality downsampling when zoomed out."
- **CAN-4** "A checkerboard background shows transparency."
- **CAN-6** "Retina-aware rendering: one image pixel maps correctly to device pixels at every zoom level."

AGENTS.md rule 3 requires GPU uploads to work per 256×256 tile, and rule 4 says pixels are premultiplied only inside the compositor; the canvas renderer is the display compositor for M0–M2 (0024 replaces its single-layer path with the multi-layer `MetalCompositor`).

Paint.NET behavior mirrored: Paint.NET draws transparent areas over a light gray/white checkerboard whose squares do not scale with zoom, shows pixels as hard-edged squares when zoomed in, and smooths when zoomed out. When it opens an image that is larger than the window it zooms out to fit; otherwise it opens at 100 % (Paint.NET docs, "View menu" / "Zoom": https://www.getpaint.net/doc/latest/ViewMenu.html). Zoom commands, gestures, and the status bar are **0004**'s job; this spec only sets the initial zoom and renders whatever `CanvasTransform` says.

## Decisions made in this spec (within the PRD)

1. **Zoom is measured in device pixels per image pixel.** `zoom = 1.0` ("100 %", Actual Size ⌘0 in 0004) maps **one image pixel to one device pixel** on every display: on a 2× Retina display an image pixel is ½ × ½ point; on a 1× display it is 1 × 1 point. This is the only definition under which CAN-6 holds at 100 % on Retina (each image pixel is exactly one device pixel, with no resampling), and it matches Paint.NET on high-DPI Windows and Photoshop's 100 %. A Retina screenshot at 100 % therefore appears at the same physical size it had on screen (PRD §3 use case 1). Consequence: when a window moves between a 1× and a 2× display, the zoom percentage is kept and the image's size in points halves/doubles. This is PRD CAN-6 ("100% means one image pixel per device pixel") and D-29; sibling spec 0004 uses the same definition (its "Zoom units" section).
2. **Initial zoom when a document window opens (CAN-6, D-29):** `min(1.0, fit)`, where `fit = min(drawableWidth / imageWidth, drawableHeight / imageHeight)` in device pixels, clamped to `[0.01, 32]`; not snapped to a preset (0004's `ZoomLevels` owns presets). The image is centered in the view. Computed once, at the first layout where the canvas has a non-zero size and a document image; later window resizes keep the zoom and the canvas point at the view center.
3. **Display filtering:** `zoom ≥ 1` → nearest neighbor (at exactly 1.0 with the pixel-aligned origin this is an exact copy). `zoom < 1` → mipmapped high-quality downsampling: a premultiplied box-filter mip pyramid per tile (generated on the CPU, deterministic), then an exact **area-weighted box filter** from mip level `L = floor(log2(1 / zoom))` to the device pixels (footprint between 1 and 2 texels per axis). This is trilinear-quality or better and has a simple CPU oracle for tests.
4. **Seam-free tiling:** each frame first copies the visible tiles' level-`L` texels into one intermediate texture (exact texel copies, no filtering), then one fragment pass samples that intermediate. No filter ever straddles a tile boundary with clamped texels, so there are no seams at any zoom.
5. **Checkerboard (CAN-4):** squares of **8 points** (8 device pixels at 1×, 16 at 2×), colors **#FFFFFF** and **#CCCCCC**, the top-left square light, anchored to the image's top-left corner (it moves with the image when panning, does not scale with zoom). It is drawn only inside the image rectangle. `CheckerboardStyle.standard` is used directly until 0046 makes the style a setting (via `AppSettings`).
6. **Outside the image** the canvas is filled with the system's `NSColor.underPageBackgroundColor` (resolved for the current appearance, converted to sRGB, refreshed on appearance change), so light and dark mode work (APP-7).
7. **Color space:** the drawable is `.bgra8Unorm` with the `CAMetalLayer.colorspace` set to sRGB; compositing over the checkerboard happens on sRGB-encoded values (as Paint.NET and the CPU compositor of 0012 do), not in linear light. No `_srgb` pixel formats.
8. **What is drawn:** the bottom layer `image.layers[0]` (there is exactly one layer until 0024), honoring its `isVisible` (hidden → checkerboard only) and `opacity`. Its `blendMode` is `.normal` by construction. 0024 replaces this with the multi-layer `MetalCompositor` and must keep every other behavior of this spec.
9. **Draw on demand:** the `MTKView` is paused with `enableSetNeedsDisplay = true`; it redraws only when the transform, the image (including its pixels changing), the size, the backing scale, or the appearance change (NF-2: no idle GPU work).

## User story

As a PaintDotMac user, I open a PNG or JPEG and see it in its document window, centered, at 100 % if it fits or zoomed out to fit if it is larger; transparent areas show a light checkerboard; on my Retina display a 100 % image is pin-sharp with one image pixel per screen pixel; when zoomed in (once 0004 lets me) pixels are crisp squares, and when zoomed out the image is smooth with no shimmering, fringes, or tile seams.

## Scope & changes

### Core (headless, unit-tested; may import Foundation, CoreGraphics, Metal, simd, Accelerate — never AppKit/MetalKit)

- **`PaintDotMac/Core/Rendering/CanvasTransform.swift`** (new) — the single source of truth for every coordinate conversion on the canvas. Later specs (0004 navigation and status bar, 0006 tool events, 0013+ overlays) must use it and must never flip Y or apply the backing scale inline.

  Coordinate spaces (document them in the file header):
  - **View space** — AppKit points in the canvas view's bounds, origin **bottom-left**, y up (the `MTKView` is not flipped). Type `CGPoint`/`CGRect`.
  - **Device space** — drawable pixels, origin **top-left**, y down; `device = (view.x · s, (viewHeight − view.y) · s)` with `s = backingScale`. This is Metal's framebuffer/`position` space.
  - **Canvas space** — continuous image coordinates in image pixels as `Double` (`CGPoint`), origin at the image's **top-left**, y down. Image pixel `(i, j)` covers `[i, i+1) × [j, j+1)`; its center is `(i + 0.5, j + 0.5)`. Tool events (0006) use this space.
  - **Pixel space** — integer `PixelPoint` = `(floor(canvas.x), floor(canvas.y))` (floor, not truncation: canvas `−0.25` → pixel `−1`). Not clamped to the image; callers check bounds.

  ```swift
  struct CanvasTransform: Equatable, Sendable {
      static let minimumZoom: Double = 0.01   // 1 %
      static let maximumZoom: Double = 32     // 3200 %
      var imageSize: PixelSize
      var viewSize: CGSize          // points
      var backingScale: Double      // device pixels per point (1, 2, …); > 0
      private(set) var zoom: Double // device pixels per image pixel; 1.0 = 100 %
      var center: CGPoint           // canvas point shown at the view's center
      init(imageSize:viewSize:backingScale:zoom:center:)   // zoom clamped
      static func initial(imageSize: PixelSize, viewSize: CGSize, backingScale: Double) -> CanvasTransform
      mutating func setZoom(_ zoom: Double)   // clamps to [minimumZoom, maximumZoom]; non-finite or ≤ 0 → no change
      var zoomPercent: Int { get }            // Int((zoom * 100).rounded()), e.g. 0.6667 → 67
      var drawableSize: (width: Int, height: Int) { get }  // (Int((viewSize.width · s).rounded()), same for height); never negative
      var imageOriginInDevice: (x: Int, y: Int) { get }     // see below
      var imageRectInDevice: CGRect { get }   // (ox, oy, imageWidth · zoom, imageHeight · zoom)
      var drawnImageRectInDevice: PixelRect { get } // (ox, oy, ceil(w·zoom), ceil(h·zoom)) ∩ (0, 0, drawableSize): device pixels that show the image
      func viewToDevice(_ p: CGPoint) -> CGPoint
      func deviceToView(_ p: CGPoint) -> CGPoint
      func deviceToCanvas(_ p: CGPoint) -> CGPoint
      func canvasToDevice(_ p: CGPoint) -> CGPoint
      func viewToCanvas(_ p: CGPoint) -> CGPoint
      func canvasToView(_ p: CGPoint) -> CGPoint
      func viewToPixel(_ p: CGPoint) -> PixelPoint
      func canvasRectToView(_ r: CGRect) -> CGRect   // standardized (positive size), bottom-left origin
      func pixelRectToView(_ r: PixelRect) -> CGRect
      var visibleCanvasRect: CGRect { get }   // canvas rect covered by the whole view
      var visibleTileRange: TileRange? { get } // tiles intersecting visibleCanvasRect ∩ image bounds; nil if empty
  }
  struct TileRange: Equatable, Sendable { var columns: ClosedRange<Int>; var rows: ClosedRange<Int>; var count: Int; func contains(_: TileCoordinate) -> Bool; var coordinates: [TileCoordinate] /* row-major */ }
  ```
  - **Pixel-aligned origin (CAN-6):** `imageOriginInDevice = (ox, oy)` with `ox = (drawableWidth / 2 − center.x · zoom).rounded()`, `oy = (drawableHeight / 2 − center.y · zoom).rounded()` (Swift `.rounded()` = to nearest, ties away from zero; `drawableWidth`/`Height` are the `Int`s from `drawableSize` converted to `Double`). All conversions use this rounded origin: `deviceToCanvas(d) = ((d.x − ox) / zoom, (d.y − oy) / zoom)`, `canvasToDevice(c) = (ox + c.x · zoom, oy + c.y · zoom)`. Because the origin is an integer device pixel, at every integer zoom `n` each image pixel covers exactly an `n × n` block of whole device pixels, and at 100 % each image pixel is exactly one device pixel, on 1× and 2× alike.
  - `initial(...)`: `drawable = drawableSize` for the given view size and scale; if either drawable dimension or image dimension is 0, zoom = 1.0; else `zoom = clamp(min(1, min(dw / iw, dh / ih)), 0.01, 32)`; `center = (iw / 2, ih / 2)`.
  - `visibleTileRange`: tile size 256 (use 0002's tile-size constant, e.g. `TiledSurface.tileSize`); columns `floor(max(0, r.minX) / 256) … floor((min(iw, r.maxX) − ε) / 256)` with the canvas rect `r = visibleCanvasRect`, likewise rows; `nil` when the intersection with `(0, 0, iw, ih)` is empty or has zero area.
  - `TileRange` is a small helper struct defined in this file (`TileCoordinate` itself is 0002's; 0002 has no tile-range type).

- **`PaintDotMac/Core/Rendering/CanvasSampling.swift`** (new) — the filter decision, pure:
  ```swift
  enum CanvasSampling: Equatable, Sendable {
      case nearest                 // zoom ≥ 1
      case areaAverage(level: Int) // zoom < 1; level = mip level L
      static let maximumLevel = 6  // floor(log2(1 / 0.01)) = 6; tile is 4×4 at level 6
      static func forZoom(_ zoom: Double) -> CanvasSampling
      var level: Int { get }       // 0 for .nearest
  }
  ```
  `forZoom`: `zoom ≥ 1` → `.nearest`; else `L = min(maximumLevel, Int(floor(log2(1 / zoom))))` with a guard so that floating error at exact powers of two yields the exact level (0.5 → 1, 0.25 → 2, 0.125 → 3; compute `L` as the largest `k` with `zoom · 2^k ≤ 1 + 1e-12`).

- **`PaintDotMac/Core/Rendering/TileMipmapper.swift`** (new) — CPU-side preparation of one tile for upload, pure and deterministic:
  - `static let levelCount = CanvasSampling.maximumLevel + 1` (7: 256, 128, 64, 32, 16, 8, 4).
  - `static func premultiplied(_ c: ColorRGBA8) -> ColorRGBA8`: `rgb' = (rgb · a + 127) / 255` (integer division), `a' = a`. Fully transparent → `(0, 0, 0, 0)` whatever the stored RGB (so straight-alpha color under transparent pixels never leaks into averages).
  - `static func paddedPremultipliedTile(from pixels: [ColorRGBA8], validWidth: Int, validHeight: Int) -> [ColorRGBA8]` — a 256×256 row-major buffer: the valid region premultiplied, the rest (edge tiles beyond the image) `(0, 0, 0, 0)`. Accepts the full 256×256 tile bytes as 0002 stores them (`Tile.bytes`; 0002 keeps edge-tile padding zero, but `validWidth/Height` still come from the image size and the padding is overwritten anyway).
  - `static func mipChain(level0: [ColorRGBA8], baseLevel: Int) -> [[ColorRGBA8]]` — builds levels 1…6 from level 0, each texel `dst(x, y) = (s00 + s10 + s01 + s11 + 2) / 4` per channel (2×2 box, round half up) of the **previous level** (iterative, not from level 0), and returns levels `baseLevel…6` (so `count = 7 − baseLevel`; the first element is level `baseLevel`).
  - No `vImage` requirement; plain loops over 256² are fine (≈ 87 k texels per tile). If `Accelerate` is used it must produce bit-identical results to the formulas above (the tests check exact values).

- **`PaintDotMac/Core/Rendering/CheckerboardStyle.swift`** (new):
  ```swift
  struct CheckerboardStyle: Equatable, Sendable {
      var squareSize: Double          // points; > 0
      var lightColor: ColorRGBA8      // opaque
      var darkColor: ColorRGBA8       // opaque
      static let standard = CheckerboardStyle(squareSize: 8, lightColor: .init(r: 255, g: 255, b: 255, a: 255), darkColor: .init(r: 204, g: 204, b: 204, a: 255))
      /// Color of device pixel (dx, dy) for an image whose top-left is at device (ox, oy).
      func color(deviceX dx: Int, deviceY dy: Int, imageOrigin: (x: Int, y: Int), backingScale: Double) -> ColorRGBA8
  }
  ```
  `color`: `side = squareSize · backingScale` (device px); `i = floor(Double(dx − ox) / side)`, `j = floor(Double(dy − oy) / side)`; light when `(i + j)` is even (use `floor`, so negative offsets alternate correctly). The shader implements the same formula; the tests check both.

- **`PaintDotMac/Core/Rendering/Shaders/Canvas.metal`** (new) — compiled into the app's default Metal library (XcodeGen picks up `.metal` files under the app's sources). Functions:
  - `canvas_vertex`: a quad covering a device-pixel rect given in a uniform, mapped to clip space for a target of size `targetSize` (top-left device origin → NDC with y flipped).
  - `canvas_fragment`: inputs `[[position]]` (device pixel center, exact half-integers), the intermediate texture (premultiplied rgba8, read with `read()` — no sampler state), and a `CanvasUniforms` struct (shared layout declared in the `.metal` file and mirrored by a Swift `struct` with `simd` types in `MetalCanvasRenderer.swift`; keep both in sync with a comment): `intermediateOriginDevice: float2` (device position of the intermediate's texel (0,0) at its level, relative to the target, computed in `Double` on the CPU then converted), `devicePerTexel: float` (= `zoom · 2^L`), `isNearest: bool`, `intermediateSize: uint2`, `validTexelSize: uint2` (image size at level L inside the intermediate, i.e. texels beyond it are padding), `opacity: float` (`layer.opacity / 255`, 0 when hidden), `checkerOrigin: int2`, `checkerSide: float`, `checkerLight/Dark: float4`.
    - **Nearest (`zoom ≥ 1`, L = 0):** `t = floor((position.xy − intermediateOriginDevice) / devicePerTexel)`, clamped to `[0, validTexelSize − 1]`; `src = read(t)`.
    - **Area average (`zoom < 1`):** the device pixel's footprint in texel units is `[x0, x1) × [y0, y1)` with `x0 = (position.x − 0.5 − origin.x) / devicePerTexel`, `x1 = x0 + 1 / devicePerTexel` (between 1 and 2 texels wide); `src = Σ_{i,j} wx(i) · wy(j) · read(i, j) / ((x1 − x0)(y1 − y0))` over the ≤ 3 × 3 texels it overlaps, `wx(i) = max(0, min(x1, i + 1) − max(x0, i))`; texels outside `[0, intermediateSize)` count as transparent 0 (so image edges get partial coverage).
    - **Composite:** `src *= opacity` (premultiplied, all four channels); `out.rgb = src.rgb + (1 − src.a) · checker.rgb`, `out.a = 1`, where `checker` is the checkerboard color of this device pixel (formula above).
  - Device pixels outside `drawnImageRectInDevice` are never shaded: they keep the render pass's clear color (the background).

- **`PaintDotMac/Core/Rendering/MetalCanvasRenderer.swift`** (new) — `@MainActor final class MetalCanvasRenderer`. Imports `Metal` only (no MetalKit, no AppKit), so it can render headlessly into any texture.
  ```swift
  struct CanvasFrame {
      var image: LayeredImage
      var transform: CanvasTransform
      var checkerboard: CheckerboardStyle = .standard
      var backgroundColor: ColorRGBA8      // opaque, sRGB
  }
  struct CanvasRendererStatistics: Equatable, Sendable {
      var residentTileCount: Int          // tiles with a texture
      var residentTextureBytes: Int       // Σ bytes of all resident tile textures (all mip levels)
      var tilesUploadedLastFrame: Int
      var lastFrameLevel: Int             // L used by the last encoded frame
      func baseLevel(of tile: TileCoordinate) -> Int?  // nil when not resident
  }
  enum CanvasRendererError: Error { case libraryUnavailable, functionMissing(String), pipelineCreationFailed(String) }

  init(device: MTLDevice, targetPixelFormat: MTLPixelFormat = .bgra8Unorm, textureBudgetBytes: Int = 512 << 20) throws
  func invalidateAll()                      // forget every resident texture's contents (whole-image replacement)
  func encode(_ frame: CanvasFrame, to target: MTLTexture, in commandBuffer: MTLCommandBuffer)
  private(set) var statistics: CanvasRendererStatistics
  ```
  - Loads its shaders with `device.makeDefaultLibrary(bundle: Bundle(for: MetalCanvasRenderer.self))` so it works in the app and in the hosted unit tests; any failure throws a `CanvasRendererError` (never crashes).
  - **Per-frame algorithm** (`encode`):
    1. `L = CanvasSampling.forZoom(zoom).level`. If the target has zero size, return without encoding.
    1a. **Change tracking (0002's `generation` + `changedTiles(since:)`; no dirty set that callers must fill or clear):** the renderer remembers, from the previous frame, the drawn layer's `id`, the image `size`, and `lastSeenGeneration` (the layer surface's `generation` when it was last read). Each resident tile texture carries an `isStale` flag. If there is no previous frame, the layer `id` or image `size` differs, or `surface.generation < lastSeenGeneration` (an older copy of the surface was swapped in), every resident texture is marked stale and its base level forgotten. Otherwise every resident tile in `surface.changedTiles(since: lastSeenGeneration)` is marked stale (non-resident changed tiles need nothing: they upload when visible). Then `lastSeenGeneration = surface.generation`. This step runs every frame, also for a hidden layer, so no change is ever missed.
    2. Render pass on `target` with `loadAction = .clear` to `backgroundColor`. If `transform.visibleTileRange` is nil or `drawnImageRectInDevice` is empty, end the pass (background only).
    3. **Upload** (CPU → GPU, per tile, AGENTS.md rule 3): for every tile in the visible range — if the layer has **no allocated tile** there (0002's sparse "empty" state), drop any resident texture for it and skip; else, if the tile is stale, not resident, or resident with `baseLevel > L`: read its pixels with 0002's `TiledSurface.tile(at:)`, build `paddedPremultipliedTile` and `mipChain(baseLevel: L)`, and store them into a **fresh** texture of size `(256 >> L)²` with `7 − L` mip levels, `.rgba8Unorm`, usage `.shaderRead`, storage `.shared` when `device.hasUnifiedMemory` else `.managed` (`replace(region:mipmapLevel:…)` per level). The fresh texture is not stale. **Only visible tiles are uploaded**; stale tiles outside the view stay resident-but-stale until they become visible (re-upload) or are evicted (step 7). A tile resident with `baseLevel < L` is reused as is (it contains level L at mip index `L − baseLevel`).
    4. **Intermediate:** a `.private` `.rgba8Unorm` texture (usage `.shaderRead | .renderTarget`) of `(columns.count · (256 >> L)) × (rows.count · (256 >> L))` texels, reused across frames while large enough (grow-only, replaced when too small). Clear it to transparent with an otherwise empty render pass (`loadAction = .clear`, clear color 0), then blit-copy each resident visible tile's mip `L − baseLevel` (full `(256 >> L)²` region) to texel `((col − firstCol) · (256 >> L), (row − firstRow) · (256 >> L))`. If either intermediate dimension would exceed `16384` (the Apple-GPU 2D texture limit), use `L + 1` instead (coarser but valid; repeat until it fits; never crash). `validTexelSize = ceil((imageSize − firstTileOrigin) / 2^L)` clamped to the intermediate size.
    5. Draw one quad over `drawnImageRectInDevice` with `canvas_fragment` (uniforms from the transform: `intermediateOriginDevice = (ox + firstCol · 256 · zoom, oy + firstRow · 256 · zoom)` computed in `Double`; it stays within a few tiles of the target, so `float` precision is ample even at 3200 % on a 65 535 px image).
    6. **Texture lifetime:** a texture replaced in step 3 may still be read by an in-flight command buffer, so it is moved to a retired list and released (or returned to a reuse pool keyed by base level) only after `commandBuffer.addCompletedHandler` reports that frame finished (hop to the main actor). Never `replace` into a texture used by an uncompleted frame.
    7. **Budget:** after encoding, while `residentTextureBytes > textureBudgetBytes`, evict the least recently drawn **non-visible** tile textures (visible tiles are never evicted in the frame that needs them; if the visible set alone exceeds the budget it stays resident for this frame). Default budget 512 MiB, injectable for tests.
  - `invalidateAll()` marks every resident texture stale and forgets base levels, so the next frame re-uploads what is visible. Pixel edits never need it (step 1a finds them); it is for whole-image replacements where generations may not be comparable, such as revert and 0008's `.structure` history changes.
  - Opacity: `layer.isVisible == false` → uniform opacity 0 (only the checkerboard shows; tiles need not be uploaded for a hidden layer: skip step 3 and 4 and draw the checkerboard with opacity 0).

### Platform glue (AppKit + MetalKit; covered by UI tests and manual checks)

- **`PaintDotMac/Canvas/CanvasView.swift`** (new) — `@MainActor final class CanvasView: MTKView`:
  - Owns a `MetalCanvasRenderer`, an `MTLCommandQueue`, the current `LayeredImage` (set by the window controller), and a `CanvasTransform`. Public API used by later specs: `var image: LayeredImage?` (setter → initial-zoom logic if not yet applied, `needsDisplay = true`; the renderer finds changed tiles itself through `changedTiles(since:)`, so 0008/0009 only assign the updated image after an edit), `var transform: CanvasTransform { get set }` (setter → redraw; 0004 drives it), `func invalidateAll()` (→ `renderer.invalidateAll()`, `needsDisplay = true`; for revert and 0008's `.structure` changes), and an `onTransformChange: ((CanvasTransform) -> Void)?` hook for 0004's status bar.
  - Configuration: `device = MTLCreateSystemDefaultDevice()`; `colorPixelFormat = .bgra8Unorm`; `(layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)`; `isPaused = true`; `enableSetNeedsDisplay = true`; `autoResizeDrawable = true`; `framebufferOnly = true`; `clearColor` irrelevant (the renderer clears).
  - `draw(_:)`: build a `CanvasFrame` (background = `NSColor.underPageBackgroundColor` converted with `usingColorSpace(.sRGB)` to `ColorRGBA8`, resolved under `effectiveAppearance`), get `currentDrawable`, `renderer.encode(…, to: drawable.texture, …)`, present, commit. No drawable (window offscreen/minimized) → return.
  - Keeps the transform in sync: `setFrameSize` → `transform.viewSize = bounds.size` (center unchanged) and, the first time both a non-zero size and an image exist, `transform = .initial(…)`; `viewDidChangeBackingProperties` → `transform.backingScale = window?.backingScaleFactor ?? 1` (zoom unchanged) and redraw; `viewDidChangeEffectiveAppearance` → redraw.
  - Accessibility — **keep 0001's contract unchanged**: `setAccessibilityElement(true)`, role `.image` (or `.group` if 0001 switched to it), `setAccessibilityIdentifier("canvas")`, `setAccessibilityLabel("Canvas")`, `setAccessibilityValue("<width> × <height>")` of the current image (e.g. `"64 × 48"`, U+00D7), updated when `image` changes. The zoom is **not** exposed here (0004's `statusBar.zoom` shows it); `CanvasUITests` verify the zoom through screenshots instead.
  - **Metal unavailable** (`MTLCreateSystemDefaultDevice()` returns nil or the renderer init throws): the window controller shows a centered `NSTextField` label "Metal is not available on this Mac." in place of the canvas (accessibility identifier `canvas.unavailable`), logs the error, and does not crash. Not reachable on supported hardware; covered by a unit test of the init error path only (see Test plan).
  - The view does not handle mouse, scroll, or magnify events yet (0004 adds `CanvasNavigation`, 0006 `CanvasInputRouter`); it returns `acceptsFirstResponder = true` so later specs can route keys.
- **`PaintDotMac/Document/DocumentWindowController.swift`** (modified): replace the `PlaceholderImageView` with a `CanvasView` filling the window's content view (Auto Layout, all four edges; 0004/0006 later insert the status bar and tool options bar around it), hand it the document's `LayeredImage`, and call `canvasView.invalidateAll()` after the document reloads (revert). Tabbing and the other window settings stay as 0001 made them.
  - **Window size follows the 100 % definition:** change the pure helper to `static func initialContentSize(imageSize: CGSize, visibleFrameSize: CGSize, backingScale: CGFloat) -> CGSize`: the image size is first converted to points (`imageSize / backingScale`, `backingScale` = `NSScreen.main?.backingScaleFactor ?? 1`, values ≤ 0 treated as 1), then 0001's formula applies unchanged (`min(max(image, 480×360), max(floor(80 % of visible), 480×360))` per axis). So an image that fits the screen opens in a window where it shows at 100 % without large empty margins on Retina. Update 0001's `DocumentWindowControllerTests.initialContentSize*` to pass `backingScale: 1` (unchanged expectations) and add the 2× cases listed in the Test plan.
- **Delete `PaintDotMac/Canvas/PlaceholderImageView.swift` and `PaintDotMacTests/Canvas/PlaceholderImageViewTests.swift`** and every reference to them (its `imageRect` helper is superseded by `CanvasTransform`). `DocumentWindowControllerTests.makeWindowControllersCreatesOneDocumentWindow` now asserts that the window's content view contains a `CanvasView` (instead of being a `PlaceholderImageView`). `LaunchUITests` stay unchanged and must keep passing.
- **`project.yml`**: no new targets. Make sure `PaintDotMac/Core/Rendering/Shaders/*.metal` is compiled into the `PaintDotMac` target (0001's recursive `sources: [PaintDotMac]` already includes it) and `MetalKit.framework` is linked (`dependencies: - sdk: MetalKit.framework`). Run `xcodegen generate`. Metal compiler warnings count as warnings for the quality gate (`*.metal` is in its warning grep).
- **PRD.md**: not edited by this spec (the zoom-unit and initial-zoom decisions are already PRD CAN-6 / D-29).

### Test support (test targets only)

- **`PaintDotMacTests/Support/CanvasReferenceRenderer.swift`** (new) — the independent CPU oracle for the canvas. Given straight-alpha image pixels (`[ColorRGBA8]`, width, height), a `CanvasTransform`, layer `opacity`/`isVisible`, a `CheckerboardStyle`, and a background color, it returns the expected `width × height` device-pixel buffer for `transform.drawableSize`. It re-implements the math directly from this spec in `Double` (own premultiply, own whole-image 2×2 box mip pyramid with transparent padding to a multiple of `2^L` and the same iterative `(sum + 2) / 4` rounding, own nearest/area-average sampling, own checkerboard), using only `CanvasTransform.imageOriginInDevice`, `drawnImageRectInDevice` and `zoom` from production code (those are tested separately against hand values). It never uses tiles, so it is also the oracle for "no seams".
- **`PaintDotMacTests/Support/MetalTestTarget.swift`** (new) — helpers: `makeDevice()` (`#require(MTLCreateSystemDefaultDevice())` — tests **fail**, never skip, when Metal is missing), `makeTarget(width:height:)` (`.bgra8Unorm`, `.managed`, usage `.renderTarget`), `render(_ frame:, with renderer:) -> [ColorRGBA8]` (encode, blit `synchronize(resource:)`, `waitUntilCompleted`, `getBytes`, BGRA → RGBA), and `assertPixelsMatch(_:_:tolerance: 1)` that reports the first mismatching device pixel and channel (0002's `TestImages.expectPixels` compares surfaces, not device buffers, so this helper is separate; it reuses `TestImages.expectColor` for the per-pixel check).

## Acceptance criteria

- [ ] The document window shows the opened image on a Metal `CanvasView` (accessibility `canvas`); the placeholder view no longer exists. → `CanvasUITests.canvasShowsOpenedImage`, quality gate build (no reference to `PlaceholderImageView`).
- [ ] An image that fits the window opens at 100 % and centered; a larger image opens zoomed out to exactly fit (not above 100 %), centered. → `CanvasTransformTests.initialZoom*`, `CanvasViewTests.initialZoom*`, `CanvasUITests.smallImageOpensAt100Percent`, `CanvasUITests.largeImageOpensFittedAndCentered`.
- [ ] The canvas keeps 0001's accessibility contract (`canvas`, label "Canvas", value "<w> × <h>"), and new windows are sized in points so that a fitting image shows at 100 % (image pixels ÷ backing scale). → `CanvasViewTests.accessibilityContract`, `LaunchUITests` (unchanged), `DocumentWindowControllerTests.initialContentSizeRetina*`.
- [ ] CAN-6: at 100 % one image pixel is exactly one device pixel on 1× and 2× backing scales; at integer zoom n each image pixel is an exact n × n block of device pixels starting on integer device coordinates; view ↔ canvas ↔ pixel conversions are exact at 1×/2× and every zoom from 1 % to 3200 %. → `CanvasTransformTests.*`, `MetalCanvasRendererTests.actualSizeIsOneToOne1x`, `…actualSizeIsOneToOne2x`, `…integerZoomGivesExactBlocks`.
- [ ] CAN-3: above 100 % pixels are rendered nearest-neighbor (hard edges, no interpolation); below 100 % the image is downsampled by premultiplied box mip levels plus an area-weighted filter, matching the CPU oracle within ±1 per channel, with no tile seams. → `MetalCanvasRendererTests.nearestNeighborAbove100`, `…nonIntegerZoomMatchesOracle`, `…powerOfTwoZoomOutIsBoxAverage`, `…arbitraryZoomOutMatchesOracle`, `…noSeamsAcrossTileBoundaries`, `CanvasSamplingTests.*`.
- [ ] Transparent pixels never leak their stored RGB (no color fringes when zoomed out). → `MetalCanvasRendererTests.transparentColorDoesNotFringe`, `TileMipmapperTests.premultiplyZeroesTransparent`.
- [ ] CAN-4: transparency shows an 8-point #FFFFFF / #CCCCCC checkerboard anchored to the image's top-left, light square first, not scaled by zoom; outside the image the background color shows. → `CheckerboardStyleTests.*`, `MetalCanvasRendererTests.checkerboardBehindTransparency1x`, `…checkerboardBehindTransparency2x`, `…checkerboardMovesWithImage`, `…backgroundOutsideImage`, `CanvasUITests.checkerboardVisibleThroughTransparentPixels`.
- [ ] Semi-transparent pixels and layer opacity/visibility composite correctly over the checkerboard. → `MetalCanvasRendererTests.semiTransparentOverCheckerboard`, `…layerOpacityApplied`, `…hiddenLayerShowsCheckerboardOnly`.
- [ ] Textures are uploaded per tile, only for visible, non-empty tiles that changed since the last frame (`changedTiles(since:)`), are new, or need a finer level; changing one tile re-uploads only that tile and the next frame shows the new pixels; `invalidateAll` and an image swap re-upload what is visible. → `MetalCanvasRendererTests.uploadsOnlyVisibleTiles`, `…sparseTilesAreNotUploaded`, `…changedTileIsReuploadedAlone`, `…offscreenChangeUploadsWhenVisible`, `…olderSurfaceForcesFullReupload`, `…invalidateAllReuploadsVisibleTiles`, `…zoomedOutUploadsCoarseBaseLevel`, `…zoomingInUpgradesBaseLevel`, `…evictsNonVisibleTilesOverBudget`.
- [ ] Extreme cases render without crashing and correctly: 1×1 images at 1 % and 3200 %, a 65 535 px wide image at 3200 % far from the origin, a zero-size target, an image scrolled out of view. → `MetalCanvasRendererTests.extremes*`.
- [ ] NF-2 (partial, single layer): re-rendering a fitted 24 MP image with no changed tiles takes under 16 ms per frame on the author's M-series Mac (gate fails only above 48 ms); the cold first frame is reported. → `CanvasRenderPerformanceTests.testWarmFrame24MP`, `…testColdFrame24MP` (measured numbers go into Verification status).
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report. → quality-gate launch smoke.

## Edge cases

- **Zero or tiny sizes:** view of size 0×0 (window being created) → `initial` returns zoom 1, `drawableSize` (0, 0), `encode` returns without encoding, `draw` does nothing; the initial zoom is applied at the first non-zero layout. 1×1 image: at 3200 % a 32×32 device block; at 1 % `drawnImageRectInDevice` is 1×1 device pixel with partial coverage (alpha = 0.01·a, over the checkerboard).
- **Huge images:** 65 535 px sides (APP-10) with sparse tiles: unallocated tiles cost no texture; at 1 % (L = 6) resident tiles are single-level 4×4 textures (64 bytes each), so a fully allocated 65 535² image at 1 % needs ≈ 4 MB of textures (but a slow first frame because every tile must be mip-built on the CPU; acceptable for M0, revisited in 0048). Intermediate textures never exceed 16384 per side (level bump rule).
- **Float precision:** all large-magnitude math (origins, tile offsets) is done in `Double` on the CPU; the GPU only sees values relative to the target (bounded by the target size plus a few tiles · 32). Tested at 3200 % with the center near x = 65 530.
- **Exact sampling boundaries:** at non-integer zooms ≥ 1 a device pixel center can land exactly on a texel boundary (e.g. zoom 1.5); the rule is `floor`, so it picks the right/lower texel. Tests use zooms such as 4/3 where centers never land on boundaries, so GPU float rounding can't flake.
- **Edge tiles:** tiles at the right/bottom image edge are padded with transparent texels; the area filter gives the last partially covered device column/row partial alpha over the checkerboard; nearest-neighbor clamps to the last image pixel.
- **Straight-alpha color under alpha 0** (e.g. stored `(255, 0, 0, 0)`) never shows and never bleeds into zoomed-out neighbors (premultiply first).
- **Image scrolled entirely out of view** (possible once 0004 pans; testable now through `transform.center`): background only, no uploads.
- **Backing-scale change** (window dragged between a 1× and a 2× display): zoom kept, transform updated, frame redrawn, drawable resized; textures don't depend on the backing scale and are kept.
- **Appearance change:** background color re-resolved; checkerboard unchanged.
- **Document revert / image replaced:** a new layer `id` or size, an older `generation`, or `invalidateAll()` → visible tiles re-uploaded; stale textures for tiles that are now empty are dropped.
- **In-flight frames:** a changed tile is uploaded into a fresh texture; the old one is released only after its frame completes (no GPU/CPU race, no tearing of tile contents).
- **Metal or shader library missing:** `CanvasRendererError` thrown; window shows the "Metal is not available on this Mac." label; no crash.
- **More than one layer** cannot happen before 0024; if it does, only `layers[0]` is drawn (documented, no crash). An image with **no layers** draws the checkerboard only.

## Test plan

Expected values come from hand calculation or the formulas in this spec (via the independent `CanvasReferenceRenderer`), never from running the code under test.

- **Unit tests — `PaintDotMacTests/Rendering/CanvasTransformTests.swift`** (Swift Testing, no GPU):
  - `initialZoomSmallImageIs100Percent`: 800×600 image, view 1000×800 pt @1× → zoom 1.0, center (400, 300); same @2× (drawable 2000×1600) → 1.0.
  - `initialZoomLargeImageFits1x`: 4000×3000, view 1000×800 @1× → zoom = min(1000/4000, 800/3000) = 0.25. `…Fits2x`: same @2× → min(2000/4000, 1600/3000) = 0.5.
  - `initialZoomClampsToOnePercent`: 65 535×65 535 in 100×100 @1× → 0.01. `initialZoomWideImage`: 65 535×1 in 1000×800 @1× → 1000/65535 (≈ 0.015259, assert with 1e-12).
  - `initialZoomDegenerateViewIs100Percent`: view 0×0 → zoom 1.0, drawableSize (0, 0).
  - `setZoomClamps`: 0.001 → 0.01; 100 → 32; `.nan`, `.infinity`, 0, −1 → unchanged.
  - `zoomPercentRounds`: 1.0 → 100, 0.6667 → 67, 0.01 → 1, 32 → 3200, 0.125 → 13 (12.5 rounds away from zero).
  - `originIsPixelAligned1x`: 800×600, view 1000×800 @1×, zoom 1, center (400, 300) → `imageOriginInDevice` (100, 100). `…2x`: @2× → (2000/2 − 400, 1600/2 − 300) = (600, 500). `…oddSize`: 801×601, center (400.5, 300.5) @1× → (99.5 → 100, 99.5 → 100). `…zoom2At2x`: 800×600 @2×, zoom 2 → (1000 − 800, 800 − 600) = (200, 200).
  - `viewToCanvasHandValues1x` (800×600, view 1000×800 @1×, zoom 1, origin (100, 100)): view (100, 700) → device (100, 100) → canvas (0, 0); view (100.5, 699.5) → canvas (0.5, 0.5) → pixel (0, 0); view (99.9, 700) → canvas (−0.1, 0) → pixel (−1, 0); view (900, 100) → canvas (800, 600) → pixel (800, 600) (outside, not clamped).
  - `viewToCanvasHandValues2x` (same image and view @2×, zoom 1, origin (600, 500)): view (300, 550) → device (600, 500) → canvas (0, 0); view (300.25, 549.75) → device (600.5, 500.5) → canvas (0.5, 0.5); view (300.5, 550) → canvas (1, 0) (half a point = one image pixel at 100 % on Retina).
  - `viewToCanvasZoom2At2x` (origin (200, 200)): view (100, 700) → canvas (0, 0); view (101, 700) → canvas (1, 0); view (100.5, 700) → canvas (0.5, 0).
  - `viewToCanvasZoomedOut`: 4000×3000 @1×, view 1000×800, zoom 0.25, center (2000, 1500) → origin (0, 25); view (0, 775) → canvas (0, 0); view (1, 775) → canvas (4, 0).
  - `yAxisIsFlipped`: increasing view y strictly decreases canvas y (several points).
  - `pixelRectToViewAt2x`: `PixelRect(0, 0, 1, 1)` at zoom 1 @2× with origin (600, 500), view height 800 → view rect (300, 549.5, 0.5, 0.5). At zoom 4 @1× → 4×4 points.
  - `roundTripProperty` (seeded via `SeededRandom`, 1 000 cases, seed printed on failure): random image sizes 1…65 535, view sizes 1…3000, backing scales {1, 2, 3}, zooms in [0.01, 32], centers anywhere: `canvasToView(viewToCanvas(p)) ≈ p` and `viewToCanvas(canvasToView(c)) ≈ c` within 1e-9 relative; `imageOriginInDevice` components are integers and `|ox − (dw/2 − cx·z)| ≤ 0.5`.
  - `integerZoomBlocksAlign` (property): for zoom n ∈ {1, 2, 3, 7, 32} and both scales, `canvasToDevice(i, j)` is an integer device point for every integer pixel corner tested.
  - `drawnImageRect`: 3×2 image, zoom 4/3, origin (10, 10) → device rect (10, 10, ceil(4) = 4, ceil(2.667) = 3); clipped to the drawable when the image extends past it; empty when scrolled out.
  - `visibleTileRange*`: 800×600 at 100 % in a 1000×800 view → columns 0…3, rows 0…2 (12 tiles); 2048×2048, view 512×512 @1×, zoom 1, center (1024, 1024) → canvas (768…1280) → columns 3…4, rows 3…4 (4 tiles); image smaller than a tile → [(0, 0)]; 65 535² at 1 % fully visible → 256 × 256 = 65 536 tiles; center far outside → nil; exact tile boundary (visible rect maxX = 512.0) does not include column 2.
- **Unit tests — `PaintDotMacTests/Rendering/CanvasSamplingTests.swift`:** 32 → `.nearest`; 1.0 → `.nearest`; 0.9999 → level 0 area average; 0.5 → 1; 0.4999 → 1; 0.25 → 2; 0.125 → 3; 0.0625 → 4; 0.03125 → 5; 0.015625 → 6; 0.01 → 6 (clamped by maximumLevel and log2(100) = 6.64).
- **Unit tests — `PaintDotMacTests/Rendering/TileMipmapperTests.swift`:**
  - `premultiplyHandValues`: (255, 0, 0, 128) → (128, 0, 0, 128) [(255·128 + 127)/255 = 128]; (200, 100, 50, 255) → unchanged; (10, 20, 30, 1) → (0, 0, 0, 1) [(10 + 127)/255 = 0]; (255, 255, 255, 1) → (1, 1, 1, 1).
  - `premultiplyZeroesTransparent`: (255, 0, 0, 0) → (0, 0, 0, 0).
  - `boxDownsampleHandValues`: 2×2 premultiplied block (255, 0, 0, 255), (0, 0, 255, 255), (0, 0, 0, 0), (255, 255, 255, 255) → (128, 64, 128, 191) [r (510 + 2)/4 = 128, g (255 + 2)/4 = 64, b 128, a (765 + 2)/4 = 191].
  - `mipChainSizes`: base 0 → 7 levels of 256², 128², …, 4²; base 4 → 3 levels 16², 8², 4².
  - `uniformTileStaysUniform`: opaque (10, 200, 30, 255) tile → every texel of every level identical.
  - `paddingIsTransparent`: valid 100×50 region of opaque white → texels x ≥ 100 or y ≥ 50 are (0, 0, 0, 0) at level 0; level 1 texel (49, 0) is opaque white, texel (50, 0) is transparent; level 2 texel (24, 0) = 2×2 average of level 1 texels (48…49) = white, texel (25,0) = average of level-1 (50, 51) = 0.
  - `iterativeRounding`: a 4×4 tile region with values chosen so that iterative rounding differs from direct 4×4 averaging (e.g. level-0 r values 0,0,0,1 in each 2×2 → level 1 r = (1 + 2)/4 = 0 everywhere → level 2 r = 0, whereas direct average 4/16 = 0.25 → 0 too; pick 1,1,1,0 → level 1 = (3 + 2)/4 = 1 → level 2 = 1, direct 12/16 = 0.75 → 1; plus one asymmetric case computed by hand in the test comment) — asserts the documented iterative rule.
- **Unit tests — `PaintDotMacTests/Rendering/CheckerboardStyleTests.swift`:** `standard` is 8 pt, #FFFFFF / #CCCCCC; @1× with origin (0, 0): (0, 0) light, (7, 7) light, (8, 0) dark, (0, 8) dark, (8, 8) light; @2×: (15, 0) light, (16, 0) dark; origin (5, 3) @1×: (5, 3) light, (13, 3) dark, (4, 3) dark (negative offset, floor); origin shift by one full square flips the color at a fixed device pixel.
- **GPU golden tests — `PaintDotMacTests/Rendering/MetalCanvasRendererTests.swift`** (Swift Testing, `@MainActor`; real Metal device, offscreen `.managed` target, readback; every comparison against `CanvasReferenceRenderer` with ±1 per channel unless an exact value is stated; fixtures generated in the test with `TestImages`; background color in tests = (50, 60, 70, 255) so it is distinct from the checkerboard):
  - `actualSizeIsOneToOne1x`: 3×2 image [(255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255) / (255, 255, 255, 128), (0, 0, 0, 0), (10, 20, 30, 255)], 7×6 target, @1×, zoom 1 → origin (2, 2); device (2, 2) = (255, 0, 0); (3, 2) = (0, 255, 0); (4, 2) = (0, 0, 255); (2, 3) = white·128/255 + (1 − 128/255)·255 = (255, 255, 255) (over light square); (3, 3) = checker light (255, 255, 255); (4, 3) = (10, 20, 30); (0, 0) and (6, 5) = background (50, 60, 70) exactly.
  - `actualSizeIsOneToOne2x`: same image, view 3.5×3 pt @2× (target 7×6) → identical device output to the 1× case except the checkerboard side (16 device px, still light at those pixels).
  - `integerZoomGivesExactBlocks`: 4×4 random opaque image (seeded), zoom ∈ {2, 3, 8, 32}, @1× and @2×: every device pixel inside the image equals the source pixel `floor((d − o) / n)` exactly (±0, opaque pixels have no blending), blocks start at `o + k·n`.
  - `nearestNeighborAbove100`: 2×1 image black | white at zoom 8: device columns `o … o+7` are exactly (0, 0, 0) and `o+8 … o+15` exactly (255, 255, 255) — no intermediate gray anywhere (proves no linear filtering).
  - `nonIntegerZoomMatchesOracle`: 7×5 seeded random opaque image at zoom 4/3 and 7/3, @1× and @2×: equals oracle exactly.
  - `powerOfTwoZoomOutIsBoxAverage`: 64×64 one-pixel black/white checker (opaque) at zoom 0.5, 0.25, 0.125 → every fully covered device pixel is (128 ± 1, 128 ± 1, 128 ± 1) (nearest neighbor would give 0 or 255); plus a smooth random image compared to the oracle.
  - `arbitraryZoomOutMatchesOracle`: 300×200 seeded random RGBA (including semi-transparent) at zooms 0.9, 0.7, 0.33, 0.2, 0.05, 0.01 and both scales → oracle ±1.
  - `noSeamsAcrossTileBoundaries`: 700×600 opaque horizontal + vertical gradient (crosses tile edges at 256 and 512) at zooms 0.75, 0.33, 1.5, 2 → oracle (which has no tiles) ±1 over the whole target, with explicit checks of the device columns/rows adjacent to `canvasToDevice(256)` and `canvasToDevice(512)`.
  - `transparentColorDoesNotFringe`: 64×64, left half opaque blue (0, 0, 255, 255), right half stored as (255, 0, 0, 0) (red under alpha 0) at zoom 0.5 and 0.33 → full target equals the oracle ±1, and in every device pixel `|r − g| ≤ 1` (blue over a gray checkerboard has r = g; any leaked red would make r > g).
  - `checkerboardBehindTransparency1x` / `…2x`: fully transparent 64×64 image, zoom 1, origin (0, 0) target 64×64: device (0…7, 0…7) = (255, 255, 255), (8, 0) = (204, 204, 204) at 1×; at 2× the switch happens at x = 16. At zoom 4 the square side is still 8 device px at 1× (not scaled by zoom).
  - `checkerboardMovesWithImage`: changing `center` by +3 canvas px at zoom 1 shifts the checker pattern by −3 device px (compare two renders).
  - `backgroundOutsideImage`: 10×10 image centered in a 40×40 target → all pixels outside `drawnImageRectInDevice` are exactly (50, 60, 70).
  - `semiTransparentOverCheckerboard`: pixel (0, 0, 0, 128) over a light square → (1 − 128/255) · 255 = (127, 127, 127) ± 1; over a dark square → (1 − 128/255) · 204 = 101.6 → (102, 102, 102) ± 1; and the full target compared to the oracle.
  - `layerOpacityApplied`: opaque (0, 0, 0) image with layer opacity 128 → same values as the previous test; opacity 0 → checkerboard only.
  - `hiddenLayerShowsCheckerboardOnly`: `isVisible = false` → checkerboard everywhere inside the image, and `statistics.tilesUploadedLastFrame == 0`.
  - `uploadsOnlyVisibleTiles`: 2048×2048 fully allocated image, 512×512 target @1×, zoom 1, center (1024, 1024) → `tilesUploadedLastFrame == 4`, `residentTileCount == 4`; second identical frame → 0 uploads.
  - `sparseTilesAreNotUploaded`: 1024×1024 image with only tile (1, 1) allocated, all visible → 1 upload, `residentTileCount == 1`, other areas show the checkerboard.
  - `changedTileIsReuploadedAlone`: 1024×1024 fully allocated image, all 16 tiles visible; render; `setPixel` a new color in tile (0, 0) of the layer's surface (one `generation` bump) and render the updated image → `tilesUploadedLastFrame == 1` and the device pixels of that tile show the new colors (oracle ±1); a third identical frame → 0 uploads.
  - `offscreenChangeUploadsWhenVisible`: 2048×2048 allocated image, view showing only tile (0, 0); render; change a pixel in tile (7, 7) (not visible) → next frame 0 uploads; pan so (7, 7) is visible → it is uploaded with the new pixels (oracle ±1).
  - `olderSurfaceForcesFullReupload`: render image A (4 visible tiles, generation g); write to A twice more and render (generation g + 2); render the copy of A taken at generation g (same layer `id`, lower `generation`, different pixels) → 4 uploads and the target equals the oracle for the old pixels.
  - `invalidateAllReuploadsVisibleTiles`: render (4 uploads); `invalidateAll()` and render the same image → 4 uploads; a new image with a different layer `id` but the same size → 4 uploads.
  - `zoomedOutUploadsCoarseBaseLevel`: 4096×4096 allocated image, zoom 1/16 (L = 4), target 256×256 → every resident tile has `baseLevel == 4`, `residentTextureBytes == residentTileCount · (16²+8²+4²)·4`.
  - `zoomingInUpgradesBaseLevel`: then zoom 1 centered → the visible tiles are re-uploaded with `baseLevel == 0`; zooming back out to 1/16 uploads nothing new for those tiles (level 4 is inside their chain).
  - `evictsNonVisibleTilesOverBudget`: budget injected as 3 full base-level-0 tiles (3 · 349 504 bytes; one tile = (256² + 128² + 64² + 32² + 16² + 8² + 4²) · 4); render 4 different single-tile views in turn → after each frame `residentTextureBytes ≤ budget` unless the visible set alone exceeds it, and the visible tile is resident.
  - `extremesTinyImage`: 1×1 opaque red at 3200 % → a 32×32 red block; at 1 % → one device pixel = 0.01·red over checker (oracle ±1), no crash.
  - `extremesHugeSparseImageAtMaxZoom`: 65 535×1 image (sparse; only the last tile allocated, pixel 65 534 = blue, 65 533 = red), zoom 32, center (65 534, 0.5), target 128×64 → exact 32-px blocks of red then blue at the oracle positions (float-precision guard).
  - `extremesZeroSizeTargetAndScrolledOut`: a transform whose `viewSize` is 0×0 → `encode` encodes nothing, `statistics` unchanged, no crash; center (−10 000, −10 000) on a 100×100 image → every target pixel is the background exactly and `tilesUploadedLastFrame == 0`.
  - `initThrowsWithoutLibrary`: constructing the renderer with a bundle that has no metallib (inject the bundle via an internal initializer `init(device:bundle:…)`) throws `CanvasRendererError.libraryUnavailable`.
- **Integration test — `PaintDotMacTests/Rendering/CanvasDocumentRenderingTests.swift`:** encode a 300×200 PNG with transparency to a temp file with ImageIO, open it through 0002's `ImageDecoder` into a `LayeredImage`, build `CanvasTransform.initial` for a 400×300 pt view @2×, render offscreen, compare to the oracle ±1 — proves decode → tiles → upload → display end to end.
- **Hosted AppKit unit tests — `PaintDotMacTests/Canvas/CanvasViewTests.swift`** (`@MainActor`, no window needed; backing scale 1 when the view has no window):
  - `initialZoomSmallImage`: `CanvasView(frame: 1000×800)`, assign an 800×600 `LayeredImage` → `transform.zoom == 1`, `transform.center == (400, 300)`.
  - `initialZoomLargeImage`: 4000×3000 → `transform.zoom == 0.25`, center (2000, 1500).
  - `initialZoomAppliedAfterFirstNonZeroLayout`: create with frame `.zero`, assign the 4000×3000 image (zoom stays 1, nothing drawn), then `setFrameSize(1000×800)` → zoom 0.25; a second `setFrameSize(500×400)` keeps zoom 0.25 and center (2000, 1500).
  - `accessibilityContract`: identifier `canvas`, label `Canvas`, value `"800 × 600"`, `isAccessibilityElement() == true`; assigning a 30×20 image changes the value to `"30 × 20"`.
  - `isNotFlipped`: `isFlipped == false` (view space is bottom-left, as `CanvasTransform` documents).
- **Unit tests — `PaintDotMacTests/Document/DocumentWindowControllerTests.swift`** (extended): `initialContentSizeRetinaFitsAtActualSize`: image 2000×1600, visible 2560×1440, backingScale 2 → 1000×800; `initialContentSizeRetinaSmallImage`: 64×48 @2 → 480×360 (minimum); `initialContentSizeScale1Unchanged`: 2000×1600 @1 → (2000, 1152) as in 0001; `initialContentSizeInvalidScale`: backingScale 0 → treated as 1.
- **UI tests — `PaintDotMacUITests/CanvasUITests.swift`** (uses `UITestApp` from 0001; fixtures generated at test time with 0002's `UITestFixtures.writePNG(width:height:pixel:properties:)`):
  Screenshot helper (in `CanvasUITests` or `UITestApp`): `canvas.screenshot().image` → `CGImage`; `s = cgImage.width / canvas.frame.width` (screenshot pixels per point, i.e. the backing scale); `boundingBox(ofColor:tolerance:)` returns the device-pixel bounding box of pixels within ±40 per channel of a color (loose, because screenshots are color-matched to the display; exact pixels are covered by the GPU tests).
  - `canvasShowsOpenedImage`: open a 64×48 PNG; the element with identifier `canvas` exists, is hittable, and `value as? String == "64 × 48"`; no element with identifier `canvas.unavailable`.
  - `smallImageOpensAt100Percent`: 64×48 solid (30, 120, 220) PNG → the bounding box of that color in the canvas screenshot is 64 ± 1 by 48 ± 1 **screenshot pixels** (one image pixel per device pixel, on 1× and 2× alike) and centered: left and right margins differ by ≤ 2 px, top and bottom likewise.
  - `largeImageOpensFittedAndCentered`: 6000×4000 solid (30, 120, 220) PNG (generated; compresses to a few KB) → the bounding box spans the full canvas width or the full canvas height (± 2 px), lies inside the canvas, is centered (margins differ by ≤ 2 px), and its aspect ratio is 1.5 ± 2 % (fitted, not cropped).
  - `checkerboardVisibleThroughTransparentPixels`: open a 200×200 PNG whose left half is opaque (220, 30, 30) and right half fully transparent; take `canvas.screenshot()`, sample the CGImage around the canvas center: points in the left half are reddish (r > 150, g < 100, b < 100 — loose to tolerate display color matching), and the right half contains at least two distinct near-gray levels (≈ 255 and ≈ 204, ±25) — proves the checkerboard. (Screenshots are color-matched to the display, hence the loose bounds; exact pixels are covered by the GPU tests.)
  - The existing `LaunchUITests` from 0001 keep passing (they look up `canvas` by identifier).
- **Performance — `PaintDotMacTests/Rendering/CanvasRenderPerformanceTests.swift`** (XCTest `measure`, `@MainActor`): 6000×4000 (24 MP) seeded random opaque image, target 2560×1600, initial (fit) zoom:
  - `testColdFrame24MP`: fresh renderer, first frame including all uploads, `waitUntilCompleted`. Report only; fail only above 1 s (NF-2's "open in under 1 s" budget includes this).
  - `testWarmFrame24MP`: after a warm-up frame, change `center` by 37 canvas px per iteration (pan, no uploads) and render; target < 16 ms (60 fps, NF-2), fail only above 48 ms (3× gross-regression rule). Also assert `tilesUploadedLastFrame == 0` on the warm frames.
  - NF-2 impact statement: this spec makes pan/zoom redraws upload-free (tiles are cached per mip base level) and on-demand (no idle frames); the 10-layer 4K part of NF-2 is measured in 0024 and 0048, NF-1 in 0009/0048.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with no Swift or Metal warnings, all unit/golden/integration/UI tests pass with none skipped (GPU tests require a Metal device and fail, not skip, without one), launch smoke passes.
- **Manual verification** (look and feel the automated tests can't judge):
  1. Open a Retina screenshot (⇧⌘4 a window) on a Retina display: it opens at 100 % (if it fits) and is pixel-identical in sharpness to the original window — text has no blur or doubling.
  2. Open a PNG with transparency (e.g. an app icon exported as PNG): a white/light-gray 8-pt checkerboard shows through; semi-transparent edges blend smoothly into it.
  3. Open a large photo (e.g. 6000×4000): it opens zoomed to fit, centered, smooth (no jaggies or moiré on fine detail such as fabric or brick), with no visible lines at 256-px tile boundaries.
  4. Drag the window between a Retina and a non-Retina display (if available): the image redraws sharply on each, without a flash of stale content; the zoom value stays the same.
  5. Switch System Settings > Appearance between Light and Dark: the area around the image changes with the system; the checkerboard does not.
  6. Resize the window: the image stays centered (when smaller than the view) and the redraw is smooth.
  7. Temporarily set `transform.setZoom(8)` in a debug build (or use 0004's zoom once it exists) on a photo: pixels are hard-edged squares.

## Out of scope

- 0004 adds `CanvasTransform+Navigation` (scroll clamping, anchored zoom) and applies Zoom to Window on first layout, which yields the same initial zoom as this spec's `CanvasTransform.initial`; 0004 must express its view-space rules in this spec's bottom-left (non-flipped) view space, through `viewToCanvas`/`canvasToView`.
- Zoom commands, zoom presets, Zoom to Window/Selection, pinch, scroll-panning, Space-pan, and the status bar → **0004** (`ZoomLevels`, `CanvasNavigation`, `StatusBarView`). This spec only provides `CanvasTransform` and its setters.
- Mouse/keyboard tool input and canvas-space `ToolEvent`s → **0006** (`CanvasInputRouter`, using `CanvasTransform.viewToCanvas`).
- Redrawing after edits/undo: the renderer picks up pixel changes through `changedTiles(since:)` once callers (0008/0009) assign the edited image; `CanvasView.invalidateAll()` covers structural replacements.
- Multiple layers, layer blend modes, and the Metal compositor with ±1 CPU parity → **0024** (`MetalCompositor`, `Blend.metal`), which replaces the single-layer draw path while keeping this spec's transform, checkerboard, sampling, and tiling behavior.
- Selection marching ants and other overlays → **0013+**; pixel grid and rulers (CAN-5, P1) → **0053**.
- Checkerboard style as a user setting → **0046** (APP-8). Performance tuning for very large dense images (GPU mip generation, upload throttling, intermediate caching) → **0048**.
