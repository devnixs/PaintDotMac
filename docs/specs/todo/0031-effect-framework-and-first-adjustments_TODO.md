# 0031 — Build the effect framework (schema, registry, runner, Core Image bridge, generated dialog, live preview, Repeat ⌘F) with Invert Colors and Brightness / Contrast

> Source: PRD.md §5.8 (ADJ-3 Brightness / Contrast, ADJ-6 Invert Colors, and the shared rule "All adjustments (P0): apply to the active layer and selection, show a live canvas preview while the dialog is open, and support Cancel and 'Repeat last' (⌘F)"), §5.9 FX-A, FX-B, FX-C, FX-D, FX-E, §5.12 (Invert Colors ⇧⌘I, Repeat last effect ⌘F), §6 NF-3 (design only; measured in 0041) and NF-4, §7 principles 2, 3, 5; §12 D-16, D-19, D-22, D-34 (H-6); AGENTS.md architecture rules 1, 2, 3, 4, 5, 7, 8.
> Paint.NET docs (fetched 2026-11-05; `getpaint.net/doc/latest/…` redirects to `paint.net/doc/latest/…`): Adjustments menu — https://paint.net/doc/latest/AdjustmentsMenu.html ("If a selection is active when the adjustment is run, the effect will only be applied to the selected region."; "Invert Colors has no configurable options and does not display a dialog."; alpha inversion is the separate command Invert Alpha); Effects menu — https://paint.net/doc/latest/EffectsMenu.html ("The top item in the Effects menu is the most recently used effect (if one has been used). The keyboard shortcut to repeat the last Effect is Ctrl + F. Using this shortcut or the menu entry directly will reapply the effect with the same parameters. No configuration dialog will be shown."; submenus in the order Artistic, Blurs, Color, Distort, Noise, Object, Photo, Render, Stylize). The docs give no numeric ranges for Brightness / Contrast, so the ranges come from Paint.NET's own source (FX-E fallback).
> Paint.NET 3.36 source (last published source), https://github.com/wangdeshui/paint.net: `src/Effects/BrightnessAndContrastAdjustment.cs` (parameters and formula, transcribed below), `src/Effects/InvertColorsEffect.cs` + `src/Core/UnaryPixelOps.cs` `Invert` (alpha kept), `src/Core/ColorBgra.cs` `GetIntensityByte`, `src/Core/Utility.cs` `ClampToByte(int)`, `src/Strings/strings.resx` (names "Brightness / Contrast", "Brightness", "Contrast", "Invert Colors", repeat item format "Repeat {0}").
> Milestone: M4
> Depends on: 0030-import-layer-paste-layer-drag-drop (and, through it, 0001 MainMenu, 0006 tools/dispatcher, 0008 history/UndoBridge, 0010 History panel, 0013 Selection/SelectionMask, 0020 PendingEditReason, 0022 Image menu, 0024 Layers menu/active layer/MetalCompositor/GoldenImage, 0025 sheet pattern and Layers panel)

## Context

No effect code exists yet. Everything this spec touches is defined by lower-numbered specs (names below are the ones those specs fix; nothing here is implemented yet):

- **Model (0002):** `TiledSurface` (256×256 sparse copy-on-write tiles; `tile(at:)`/`setTile(_:at:)` stamps `generation`; `changedTiles(since:)`; `readPixels(in:into:bytesPerRow:)`; edge-tile invariant: bytes outside the canvas are always 0, asserted by `setTile` in Debug), `Tile` (`byteCount` 262,144, `isFullyTransparent` = every byte 0, `withUnsafeBytes`/`withUnsafeMutableBytes`, `sharesStorage(with:)`), `ColorRGBA8`, `PixelSize`, `PixelRect`, `TileCoordinate`, `Layer` (`id`, `isVisible`, `surface`), `LayeredImage` (`layers` index 0 = bottom, `activeLayerIndex`).
- **History (0008):** `DocumentState` (`image`, + `selection: Selection?` from 0013), `HistoryItem`, `TileDiff.between(before:after:layerID:candidates:)`, `TileDiffHistoryItem(name:icon:diff:)` ("used by every … effect/adjustment"; `isNoOp` when the diff is empty, H-6), `HistoryIcon` (already has `.adjustment` and `.effect`), `UndoBridge` (`state`, `updateLiveState(_:)`, `commit(_:)`, `perform(_:)`, `onStateChange`, `prepareForNavigation`). Live drawing without a step goes through `updateLiveState`, the step through `commit` (0008 item 6 capture pattern, 0025 Layer Properties live preview).
- **Selection (0013):** `Selection?` (`nil` = no selection = whole layer), `SelectionMask` (`tile(at:)` → `.empty`/`.full`/`.partial(storage)`, `coverage(x:y:)`, `bounds`, `isFull`).
- **Pending edits (0020):** commands call `undoBridge.prepareForNavigation?()` first, with `PendingEditReason.command`, so floating pixels record **"Finish Pixels"** before the command's own step.
- **Menus (0001, 0022, 0024):** `App/MainMenu.swift` builds the bar in code; top-level order today `PaintDotMac, File, Edit, View, Image, Layers, Window, Help`; 0001/0022/0024 reserve the slots **after Layers and before Window** for 0031's **Adjustments** and **Effects** menus (Paint.NET's bar order). Menu actions are responder-chain `@objc` methods on `DocumentWindowController` that return early while `AppModel.shared.dispatcher.isGestureInProgress`, commit the pending edit, then perform; `validateMenuItem` mirrors that (0013 item 15, 0024 item 9). `MainMenuTests.noDuplicateShortcuts` checks the whole tree.
- **Sheets (0025):** dialogs are SwiftUI views in an `NSHostingController` presented with `window.beginSheet`; the sheet window's delegate returns a private `UndoManager`; `LayersPanelModel.isDocumentBusy` is true while a sheet is attached.
- **Display (0003/0024):** the canvas re-uploads exactly the tiles whose `generation` changed (`changedTiles(since:)`), composited by `MetalCompositor` over all visible layers, so writing preview tiles into the live state through `updateLiveState` is all the canvas needs. `CanvasTransform.visibleCanvasRect` (0003) gives the visible canvas rect.
- **Test support:** `TestImages`, `SeededRandom` (0002), `GoldenImage.compare` (±1, 0024), `FakeToolContext`, `UITestApp` (`launch(opening:extraArguments:)`, `chooseMenuItem`, `menuItem`, `saveThroughPanel(directory:name:format:)`), `UITestFixtures.writePNG` (0002), `-UITestSelectRect x,y,w,h` (0013).

**Paint.NET behavior mirrored.**
- *Invert Colors* (`InvertColorsEffect`, `UnaryPixelOps.Invert`): `(R,G,B,A) → (255−R, 255−G, 255−B, A)`; no dialog; alpha untouched.
- *Brightness / Contrast* (`BrightnessAndContrastAdjustment`): two integer properties, **Brightness −100…100, default 0** and **Contrast −100…100, default 0** (verified: `new Int32Property(Brightness, 0, -100, +100)`, `new Int32Property(Contrast, 0, -100, +100)`; dialog labels "Brightness" and "Contrast"; menu/history name "Brightness / Contrast"). Exact formula transcribed in *Scope* item 9.
- Effects apply to the active layer, clipped to the selection (AdjustmentsMenu.html); the dialog previews its cumulative result on the canvas; Cancel discards; OK records one history step named after the effect; Ctrl+F repeats the last effect with the same parameters and no dialog (EffectsMenu.html). Paint.NET remembers each effect's last-used settings for the rest of the session (not across launches) — see *Open questions* 2.

## User story

As a Paint.NET switcher, I choose **Adjustments ▸ Invert Colors** (⇧⌘I) and the active layer — or only my selection, with soft edges — inverts at once, as one "Invert Colors" step I can undo. I choose **Adjustments ▸ Brightness / Contrast…**, drag the sliders or type numbers, and watch the canvas update live (the visible part first, then the rest, tile by tile); **Cancel** puts every pixel back exactly, **OK** adds one "Brightness / Contrast" step. The dialog remembers my last values while the app runs. **⌘F** ("Repeat Brightness / Contrast" at the top of the Effects menu) applies the same adjustment again without a dialog. On a huge image a progress sheet lets me cancel with Escape.

## Scope & changes

Cross-cutting rules: every pixel change goes through `UndoBridge` (preview via `updateLiveState`, the step via `commit`); `Core` imports no AppKit/SwiftUI (Core Image and Metal are allowed, D-19); straight 8-bit sRGB in storage; rendering off the main actor in cancellable `Task`s that check cancellation per chunk and report progress; tiles everywhere (render chunks are whole tiles); one dialog generated from the schema for every effect — **no hand-written effect dialogs** (AGENTS rule 5).

### Core (pure, headless, unit-tested)

1. **`Core/Effects/EffectParameter.swift`** (new) — the schema.
   ```swift
   public struct EffectParameter: Sendable, Identifiable, Equatable {
       public let id: String          // stable camelCase; accessibility "effectDialog.<id>", memory key
       public let label: String       // Paint.NET spelling, shown with a trailing ":" by the dialog
       public let kind: Kind
       public enum Kind: Sendable, Equatable {
           case integer(range: ClosedRange<Int>, defaultValue: Int, step: Int = 1)                 // slider + integer field
           case double(range: ClosedRange<Double>, defaultValue: Double, step: Double, decimals: Int) // slider + decimal field
           case bool(defaultValue: Bool)                                                         // checkbox
           case choice(options: [EffectChoice], defaultValue: String)                            // pop-up (EffectChoice.id)
           case color(defaultValue: EffectColorDefault)                                          // swatch
           case angle(range: ClosedRange<Double> = -180...180, defaultValue: Double, decimals: Int = 2) // degrees, 0 = east, counter-clockwise positive (Paint.NET)
           case seed                                                                              // "Reseed" button
           // 0033 adds `.levels`, 0034 adds `.curve`, 0042 adds `.offset` (center point; with their own value cases and dialog controls).
       }
   }
   public struct EffectChoice: Sendable, Equatable, Identifiable { public let id: String; public let label: String }
   public enum EffectColorDefault: Sendable, Equatable { case primary, secondary, fixed(ColorRGBA8) }   // resolved from ColorSelection (0007) when the dialog opens
   public enum EffectParameterValue: Sendable, Hashable {
       case integer(Int), double(Double), bool(Bool), choice(String), color(ColorRGBA8), angle(Double), seed(UInt64)
   }
   public struct EffectParameterValues: Sendable, Hashable {
       public init()                                                     // empty (no-parameter effects)
       public static func defaults(for schema: [EffectParameter], colors: ColorSelection, seed: UInt64) -> EffectParameterValues
       public subscript(id: String) -> EffectParameterValue? { get }
       public func integer(_ id: String) -> Int                          // typed getters; a missing/mistyped id is a programmer error: assertionFailure + the schema default
       public func double(_ id: String) -> Double
       public func bool(_ id: String) -> Bool
       public func choice(_ id: String) -> String
       public func color(_ id: String) -> ColorRGBA8
       public func angle(_ id: String) -> Double
       public func seed(_ id: String) -> UInt64
       public func setting(_ id: String, to value: EffectParameterValue, schema: [EffectParameter]) -> EffectParameterValues   // normalizes (below)
       public func normalized(for schema: [EffectParameter]) -> EffectParameterValues   // drops unknown ids, fills missing with defaults, normalizes each
   }
   public enum EffectParameterText {   // field ↔ value, used by the dialog's numeric fields
       public static func format(_ value: EffectParameterValue, kind: EffectParameter.Kind) -> String          // integer "-20"; double/angle with `decimals` places, "." decimal separator (POSIX), no grouping
       public static func parse(_ text: String, kind: EffectParameter.Kind) -> EffectParameterValue?           // trims spaces; accepts "+5", "-5", "5.0" for integers only if integral; nil for non-numeric/NaN/inf
   }
   ```
   **Normalization** (single source of truth; the dialog never clamps on its own): integer → clamp to range, then snap to `lowerBound + k·step` (nearest, ties toward the larger value); double/angle → clamp, then round to `decimals` places (`(v · 10^d).rounded(.toNearestOrAwayFromZero) / 10^d`); choice → an unknown id becomes `defaultValue`; color/bool/seed unchanged; a value of the wrong case becomes the default. Typing out-of-range text into a field therefore shows the clamped value (Paint.NET's numeric boxes clamp likewise).
   **Schema validation:** `public enum EffectSchemaValidator { static func problems(in effect: any ImageEffect) -> [String] }` — reports duplicate parameter ids, empty ids/labels, empty ranges, `step ≤ 0`, defaults outside their range or not on the step grid, `decimals` outside 0…4, empty choice lists, duplicate choice ids, and choice defaults that are not an option. `EffectRegistry.init` asserts `problems.isEmpty` in Debug; a test runs it over the standard registry.

2. **`Core/Effects/ImageEffect.swift`** (new) — the protocol (FX-A).
   ```swift
   public enum EffectCategory: String, CaseIterable, Sendable {
       case adjustment                                                   // the Adjustments menu
       case artistic, blurs, distort, noise, object, photo, render, stylize   // Effects submenus, in this (Paint.NET 5) order
       public var menuTitle: String   // "Artistic", "Blurs", "Distort", "Noise", "Object", "Photo", "Render", "Stylize"; adjustment → "Adjustments"
   }
   public struct EffectShortcut: Sendable, Equatable {
       public struct Modifiers: OptionSet, Sendable { command, shift, option, control }   // Core-side; MainMenu maps to NSEvent.ModifierFlags
       public let key: String           // keyEquivalent, lowercase
       public let modifiers: Modifiers
   }
   public enum EffectAlphaMode: Sendable { case straight, premultiplied }   // see CoreImageBridge
   public protocol ImageEffect: Sendable {
       var id: String { get }                 // stable camelCase ("invertColors", "brightnessContrast"); menu id, memory key, Repeat key
       var name: String { get }               // Paint.NET spelling: menu title stem, dialog title, history step name
       var category: EffectCategory { get }
       var parameters: [EffectParameter] { get }       // empty → no dialog, runs immediately
       var shortcut: EffectShortcut? { get }           // default nil (0045 later moves it into ShortcutTable)
       var historyIcon: HistoryIcon { get }            // default: .adjustment for category .adjustment, else .effect
       var alphaMode: EffectAlphaMode { get }          // default .straight
       func inputPadding(for values: EffectParameterValues) -> Int   // pixels of source needed around an output pixel; default 0 (point operation)
       /// Builds the effect's output for one render region. `input` is the clamped-to-extent source (CoreImageBridge item 6);
       /// return any CIImage — the bridge crops it to `context.outputRect` and converts it back. Must not capture mutable state.
       func makeOutput(input: CIImage, values: EffectParameterValues, context: EffectRenderContext) throws -> CIImage
   }
   public extension ImageEffect {
       var hasDialog: Bool { !parameters.isEmpty }
       var menuTitle: String { hasDialog ? name + "…" : name }        // "Brightness / Contrast…", "Invert Colors" (Paint.NET shows "..." for dialog commands; Mac uses "…")
   }
   // Later requirements, each with a protocol-extension default so earlier effects need no change:
   // 0032 adds `var parameterRules: [EffectParameterRule]` (default []); 0033 adds
   // `func prepare(values:source:selection:) throws -> EffectPreparation` (default `.render(values)`).
   public struct EffectRenderContext: Sendable {
       public let canvasSize: PixelSize
       public let inputRect: PixelRect        // canvas pixels read for this region (outputRect expanded by inputPadding, clipped to the canvas)
       public let outputRect: PixelRect       // canvas pixels produced
       public func ciRect(_ canvasRect: PixelRect) -> CGRect          // canvas (y down) → this region's CI space (see item 6)
       public func ciPoint(x: Double, y: Double) -> CGPoint           // canvas point → CI point (for geometric effects in 0041+)
       public func colorKernel(_ name: String) throws(EffectError) -> CIColorKernel   // from the bridge's kernel cache
       public func kernel(_ name: String) throws(EffectError) -> CIKernel
   }
   public enum EffectError: Error, Equatable { case gpuUnavailable, kernelMissing(String), renderFailed }
   ```
   If `CIImage`/`CIColorKernel`/`CIKernel` are not `Sendable` in the macOS 26 SDK, `EffectRenderContext` holds the kernel cache in a `private struct KernelCacheBox: @unchecked Sendable` with a comment (compiled kernels are immutable and thread-safe), and `makeOutput` is only ever called inside one render task, so `CIImage` values never cross isolation domains.

3. **`Core/Effects/EffectRegistry.swift`** (new).
   ```swift
   public struct EffectRegistry: Sendable {
       public static let standard: EffectRegistry       // [InvertColors(), BrightnessContrast()]; 0032–0034, 0041–0044, 0064–0069 append here
       public init(effects: [any ImageEffect])           // Debug asserts: unique ids, EffectSchemaValidator clean
       public let effects: [any ImageEffect]
       public func effect(id: String) -> (any ImageEffect)?
       public var adjustments: [any ImageEffect]          // category .adjustment, sorted by name (String <): Paint.NET's alphabetical Adjustments menu
       public var effectSubmenus: [(category: EffectCategory, effects: [any ImageEffect])]   // non-adjustment categories that have ≥ 1 effect, in EffectCategory order; effects sorted by name
   }
   ```
   With this spec: `adjustments.map(\.name) == ["Brightness / Contrast", "Invert Colors"]`, `effectSubmenus` is empty.

4. **`Core/Effects/EffectParameterMemory.swift`** (new) — Paint.NET's in-session settings memory and the Repeat slot.
   ```swift
   public struct EffectParameterMemory: Sendable, Equatable {
       public init()
       public func initialValues(for effect: any ImageEffect, colors: ColorSelection, seed: UInt64) -> EffectParameterValues   // remembered (normalized) else defaults
       public mutating func remember(_ values: EffectParameterValues, for effect: any ImageEffect)   // on OK only
       public private(set) var lastApplied: (effectID: String, values: EffectParameterValues)?        // set on OK / on a no-dialog run / on Repeat, even when the result was a no-op
       public mutating func recordApplied(_ effect: any ImageEffect, values: EffectParameterValues)
       public func repeatTitle(registry: EffectRegistry) -> String   // "Repeat <name>" (strings.resx "Repeat {0}"), or "Repeat" when nothing ran
   }
   ```
   App-wide, in memory only (not `UserDefaults`), owned by `AppModel` (item 14). Cancel neither remembers values nor changes `lastApplied`. A `.seed` value is remembered like any other value (Repeat is deterministic; **note:** 0043 changes Repeat for seeded effects to draw a fresh seed for each `.seed` parameter via `EffectParameterValues.reseeded(for:using:)` / `EffectParameterMemory.repeatRequest(registry:seeds:)` — dialog memory is unchanged); a `.color` parameter whose default is `.primary`/`.secondary` and was never changed is re-resolved from the current colors when the dialog opens (remember only explicitly edited colors — store a flag per value in the memory's private storage).

5. **`Core/Effects/EffectMaskBlend.swift`** (new) — FX-D: blend effect output with the original by the antialiased mask coverage `m` (0…255), straight RGBA8, integer-exact:
   - `m == 255` → effect pixel exactly; `m == 0` → original pixel exactly.
   - otherwise `a = (aO·(255−m) + aF·m + 127) / 255` (integer division);
     - if `a == 0`: each color channel `c = (cO·(255−m) + cF·m + 127) / 255` (keeps color under alpha 0, D-33 spirit);
     - else each color channel `c = min(255, (cO·aO·(255−m) + cF·aF·m + (a·255)/2) / (a·255))` (alpha-weighted, i.e. the premultiplied lerp, then un-premultiplied; equals the plain straight lerp ±1 when `aO == aF`).
   ```swift
   public enum EffectMaskBlend {
       public static func blend(original: ColorRGBA8, effect: ColorRGBA8, coverage m: UInt8) -> ColorRGBA8
       public static func blendTile(original: Tile?, effect: Tile?, mask: SelectionMaskTile, tileOrigin: PixelPoint, canvasSize: PixelSize) -> Tile?
   }
   ```
   `blendTile`: `.full` → `effect`; `.empty` → `original` (same storage, no copy); `.partial` → per in-canvas pixel `blend`, out-of-canvas bytes 0; a result whose bytes are all zero → `nil` (stays sparse). `nil` tiles read as all-zero pixels.

6. **`Core/Rendering/CoreImageBridge.swift`** (new) — `public final class CoreImageBridge: Sendable` (FX-B). One instance per app (`AppModel` owns it; tests create their own).
   - `public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), kernelLibrary: Data?) throws(EffectError)` — throws `.gpuUnavailable` when `device` is nil. Creates **one Metal-backed `CIContext`** `CIContext(mtlDevice:options:)` with `.workingColorSpace: NSNull()`, `.workingFormat: CIFormat.RGBAf`, `.cacheIntermediates: false`, `.useSoftwareRenderer: false`. Loads the CI kernels named in item 7 from `kernelLibrary` (the app's `default.metallib` data: `Bundle.main.url(forResource: "default", withExtension: "metallib")`, the same library 0003's tests load) into a name → kernel cache; a missing name is reported lazily by `EffectRenderContext.colorKernel(_:)` as `.kernelMissing(name)`.
   - **Color space ("sRGB working space"):** pixels are sRGB-encoded 8-bit values and all effect math runs on those encoded values, exactly like Paint.NET. Core Image color management is therefore **off end to end** (input images created with `CIImageOption.colorSpace: NSNull()`, working space `NSNull`, render with `colorSpace: nil`), so no sRGB↔linear conversion ever happens. (Tagging the input as sRGB with the default linear working space would make Brightness / Contrast diverge from Paint.NET's formula.)
   - **Region in:** `func makeInputImage(from surface: TiledSurface, rect: PixelRect, alphaMode: EffectAlphaMode) -> CIImage` — reads `rect` with `readPixels(in:into:bytesPerRow:)` (unallocated tiles read as zeros) into a fresh tightly-packed buffer, builds `CIImage(bitmapData:bytesPerRow:size:format: .RGBA8, colorSpace: nil)`; for `.premultiplied` applies `.premultiplyingAlpha()` (the bytes are straight, Core Image treats RGBA8 as premultiplied); for `.straight` passes the bytes through untouched (point/color effects then see straight colors, and color under alpha 0 survives). Then `.clampedToExtent()` — **edge handling**: samples beyond the canvas replicate the nearest edge pixel; samples beyond `rect` but inside the canvas never happen because `rect` already includes `inputPadding`.
   - **CI coordinate convention:** within a region, CI space has its origin at the bottom-left of `inputRect` and y up: `ciRect(r) = CGRect(x: r.minX − in.minX, y: in.maxY − r.maxY, width: r.width, height: r.height)`; `ciPoint(x, y) = (x − in.minX, in.maxY − y)`. `CIImage(bitmapData:)` puts the buffer's first row at the top, so canvas row `in.minY` is the top row of the extent. This is the only place canvas↔CI coordinates are converted.
   - **Region out:** `func render(_ image: CIImage, alphaMode:, context: EffectRenderContext) throws(EffectError) -> [UInt8]` — crops to `ciRect(outputRect)`, for `.premultiplied` applies `.unpremultiplyingAlpha()`, then `CIContext.render(_:toBitmap:rowBytes:bounds:format: .RGBA8, colorSpace: nil)` into `outputRect.width × outputRect.height × 4` straight bytes. A nil/empty extent or a render error → `.renderFailed`.
   - `func renderEffect(_ effect: any ImageEffect, values:, source: TiledSurface, outputRect: PixelRect) throws -> [UInt8]` — `inputRect = outputRect.insetBy(−padding) ∩ canvas`, context, `makeInputImage` → `effect.makeOutput` → `render`. Conforms to `EffectTileRenderer` (item 8). Thread-safe (`CIContext` is thread-safe; the kernel cache is immutable after init).

7. **`Core/Rendering/Shaders/EffectKernels.metal`** (new) — Core Image **stitchable** color kernels (`#include <CoreImage/CoreImage.h>`, `[[stitchable]] float4 name(coreimage::sample_t s, …)`), compiled into the app's default Metal library together with the canvas/blend shaders. One function per point effect, named after the effect id:
   - `invertColors(sample_t s)` → `float4(1 − s.r, 1 − s.g, 1 − s.b, s.a)`.
   - `brightnessContrast(sample_t s, float brightness, float contrast)` → converts `s.rgb` to integers with `int(rint(s.x * 255))`, runs **item 9's integer formula verbatim** (C-style truncating `/`, which MSL `int` division matches), returns `float4(float(r)/255, float(g)/255, float(b)/255, s.a)`.
   - **`project.yml`:** add `MTLLINKER_FLAGS: "-framework CoreImage"` to the app target's settings (required to link stitchable CI kernels into the default library; no `-fcikernel` flag, so the existing 0003/0024 shaders compile unchanged). Run `xcodegen generate`. If the toolchain refuses to mix them, compile `EffectKernels.metal` into a separate `EffectKernels.metallib` with a build rule and pass that file's data to `CoreImageBridge`; record which variant was used in the spec's Verification status. `CoreImageBridgeTests.kernelsLoad` proves either variant.

8. **`Core/Effects/EffectRunner.swift`** (new) — rendering a request off the main actor, chunk by chunk (FX-C, NF-3 design).
   ```swift
   public protocol EffectTileRenderer: Sendable {
       func renderEffect(_ effect: any ImageEffect, values: EffectParameterValues, source: TiledSurface, outputRect: PixelRect) throws -> [UInt8]
   }
   public struct EffectRequest: Sendable {
       public let effect: any ImageEffect
       public let values: EffectParameterValues          // normalized
       public let layerID: Layer.ID
       public let source: TiledSurface                   // the active layer's surface BEFORE the effect (CoW snapshot); never the live preview
       public let selection: SelectionMask?              // nil = whole layer
       public init?(effect:values:state: DocumentState)  // active layer + selection?.mask; nil only if the image has no layers (unreachable)
       public var affectedTiles: [TileCoordinate]        // row-major: every canvas tile when selection is nil; otherwise tiles whose mask tile is not .empty
   }
   public struct EffectChunk: Sendable {                 // one finished render unit
       public let tiles: [(TileCoordinate, Tile?)]       // final layer tiles = EffectMaskBlend.blendTile(source, effect, mask); nil = transparent/unallocated
   }
   public struct EffectProgress: Sendable, Equatable { public let completedTiles: Int; public let totalTiles: Int; public var fraction: Double }
   public struct EffectRunner: Sendable {
       public struct Configuration: Sendable { public var chunkTiles: Int = 2; public var maxConcurrentChunks: Int = 2 }   // chunk = up to chunkTiles × chunkTiles affected tiles (512×512 px)
       public init(renderer: any EffectTileRenderer, configuration: Configuration = .init())
       public static func chunkOrder(_ request: EffectRequest, priorityRect: PixelRect?, chunkTiles: Int) -> [[TileCoordinate]]
       public func run(_ request: EffectRequest, priorityRect: PixelRect?) -> AsyncThrowingStream<(EffectChunk, EffectProgress), Error>
   }
   ```
   - **Chunking:** group the affected tiles by `(col / chunkTiles, row / chunkTiles)`; each chunk renders the union rect of its tiles clipped to the canvas (one `renderEffect` call), then splits it into tiles.
   - **Order (progressive preview, visible tiles first):** chunks that intersect `priorityRect` (the visible canvas rect) first, sorted by the squared distance from their center to the `priorityRect` center (ties row-major); then all other chunks row-major. `priorityRect == nil` → row-major.
   - **Execution:** `run` starts a child task group with at most `maxConcurrentChunks` chunks in flight, yields `(chunk, progress)` as each finishes (progress counts tiles, strictly increasing, last yield `completedTiles == totalTiles`), finishes the stream after the last chunk; zero affected tiles → finishes immediately with no yield. Checks `Task.checkCancellation()` before each chunk and after each render; cancellation (consumer cancels its iteration task, or `onTermination`) cancels the group and finishes the stream by throwing `CancellationError`; a renderer error finishes it with that error. Never touches the main actor.
   - **Per tile:** `effectTile` = bytes for that tile from the chunk buffer, padded to 256×256 with zeros outside the canvas; `Tile` built from them, `nil` if all-zero; then `EffectMaskBlend.blendTile(original: source.tile(at:), effect:, mask: selection?.tile(at:) ?? .full, …)`. Out-of-canvas bytes stay 0 (0002 invariant).
   - **NF-3 design:** no whole-image buffers (memory per chunk ≈ (512 + 2·padding)² × 4 B in, 512² × 4 B out); GPU work per chunk; chunk size and concurrency are configuration so 0041 can tune them against NF-3 without API changes.

9. **`Core/Effects/Adjustments/BrightnessContrast.swift`** (new) — `public struct BrightnessContrast: ImageEffect`: `id "brightnessContrast"`, `name "Brightness / Contrast"`, `.adjustment`, no shortcut (Paint.NET has none; PRD §5.12 lists none), `.straight`, parameters `[.init(id: "brightness", label: "Brightness", kind: .integer(range: -100...100, defaultValue: 0)), .init(id: "contrast", label: "Contrast", kind: .integer(range: -100...100, defaultValue: 0))]`. `makeOutput` applies `context.colorKernel("brightnessContrast")` with arguments `[input, Float(brightness), Float(contrast)]`, ROI = destination rect (point op).
   **Formula (Paint.NET 3.36 `OnSetRenderInfo`/`OnRender`, transcribed; `/` truncates toward zero; `clamp` = `ClampToByte(int)` to 0…255), per pixel with straight `R, G, B, A`:**
   ```
   I = (7471·B + 38470·G + 19595·R) >> 16                      // GetIntensityByte
   if contrast < 0      { multiply = contrast + 100; divide = 100 }
   else if contrast > 0 { multiply = 100;            divide = 100 − contrast }
   else                 { multiply = 1;              divide = 1 }
   if divide == 0 {                                              // contrast == 100: threshold
       v = (I + brightness < 128) ? 0 : 255;  out = (v, v, v, A)
   } else if divide == 100 {                                     // contrast < 0
       shift = (I − 127) · multiply / divide + 127 − I + brightness
       out = (clamp(R + shift), clamp(G + shift), clamp(B + shift), A)
   } else {                                                      // contrast ≥ 0 (incl. 0: multiply = divide = 1)
       shift = (I − 127 + brightness) · multiply / divide + 127 − I
       out = (clamp(R + shift), clamp(G + shift), clamp(B + shift), A)
   }
   ```
   Note the asymmetry (brightness inside the multiplication for contrast ≥ 0, outside for contrast < 0) is Paint.NET's and is kept. Alpha is never changed.

10. **`Core/Effects/Adjustments/InvertColors.swift`** (new) — `public struct InvertColors: ImageEffect`: `id "invertColors"`, `name "Invert Colors"`, `.adjustment`, `shortcut EffectShortcut(key: "i", modifiers: [.command, .shift])` (PRD §5.12), no parameters (no dialog), `.straight`; `makeOutput` applies `context.colorKernel("invertColors")`. Output `(255−R, 255−G, 255−B, A)`; color under alpha 0 is inverted too (Paint.NET's per-pixel op), so a transparent (unallocated) tile becomes `(255,255,255,0)` and is allocated (see *Open questions* 4).

### Platform glue (covered by integration and UI tests)

11. **`Document/EffectSessionController.swift`** (new, `@MainActor final class`, no AppKit import — testable headlessly with a real `UndoBridge`). One live session per document at a time.
    ```swift
    @MainActor final class EffectSessionController {
        enum Phase: Equatable { case previewing, finishing, done, cancelled, failed(EffectError?) }
        init(effect: any ImageEffect, initialValues: EffectParameterValues, bridge: UndoBridge, runner: EffectRunner,
             priorityRect: @escaping () -> PixelRect?, debounce: Duration = .milliseconds(80),
             onProgress: @escaping (EffectProgress) -> Void, onFinish: @escaping (Phase) -> Void)
        private(set) var values: EffectParameterValues
        private(set) var phase: Phase
        private(set) var isRenderComplete: Bool        // the current values' render has delivered every chunk
        func start()                                   // snapshot `before = bridge.state`, request = EffectRequest(effect:values:state:), set bridge busy, render immediately
        func update(_ id: String, to value: EffectParameterValue)   // normalize; if changed: bump generation, cancel the running render task, restart after `debounce` of quiet (0032 routes the normalization through `EffectParameterEditor`)
        func ok()                                      // commit (below)
        func cancel()                                  // restore (below)
    }
    ```
    - **Begin:** the caller has already committed the pending tool edit (item 13). `start` captures `before` (CoW, free), sets `bridge.isBusy = true` (item 12), and launches render generation 1.
    - **Rendering:** each generation runs `runner.run(request(values), priorityRect: priorityRect())` in a `Task` (the stream's producer runs off the main actor); for each `(chunk, progress)` the controller — on the main actor — **ignores it unless the generation number captured by that render task still equals `currentGeneration`** (stale chunks delivered after a parameter change are dropped; the generation is controller state, not part of `EffectChunk`), then writes the tiles into the live state: `bridge.updateLiveState { s in for (c, t) in chunk.tiles { s.image.layers[idx].surface.setTile(t, at: c) } }` (layer found by `layerID`), adds `c` to `touched`, calls `onProgress`. The canvas updates through 0008's `onStateChange` / generation tracking. Tiles from an earlier generation stay on screen until the new generation overwrites them (the affected tile set is identical across generations because the selection can't change during a session), so the canvas never flashes back to the original.
    - **Debounce:** `update` cancels the running task immediately, then waits `debounce` (cancellable sleep) before starting the next generation; further updates within the window restart the wait. `debounce == .zero` restarts at once (tests).
    - **OK:** if `isRenderComplete` → commit now; else `phase = .finishing`, keep (or start) the current generation's render, commit when its stream finishes. **Commit** = `TileDiff.between(before: before.image.layers[idx].surface, after: bridge.state…surface, layerID:, candidates: touched)` → `bridge.commit(TileDiffHistoryItem(name: effect.name, icon: effect.historyIcon, diff:))` (state already holds the result; an empty diff is ignored by the stack, H-6), `bridge.isBusy = false`, `phase = .done`, `onFinish`.
    - **Cancel (any phase before done):** cancel the task, restore every touched tile with `bridge.updateLiveState { setTile(before…tile(at: c), at: c) }` — the restored tiles share storage with `before` (byte-identical, no copy) — `bridge.isBusy = false`, `phase = .cancelled`, no history step, `onFinish`.
    - **Errors:** a renderer error → restore as Cancel, `phase = .failed(error)`, `onFinish`; the window controller shows the alert "The effect couldn’t be applied." (informative text = effect name). Never crashes.
    - **No-dialog effects and Repeat** use the same controller: `start()` then immediately `ok()` (so the phase goes straight to `.finishing`), with `priorityRect` = visible rect.

12. **`Document/UndoBridge.swift`** (extend 0008): `var isBusy: Bool = false` (observable). While true: `DocumentWindowController.validateMenuItem` disables every document command, Undo/Redo, Save/Save As/Revert, every effect and Repeat (closing the window stays possible, see item 13); 0010's History panel rows and Undo/Redo buttons are disabled (`HistoryPanelView` adds `|| bridge.isBusy` to their disabled state); 0025's `LayersPanelModel.isDocumentBusy` becomes `attachedSheet != nil || bridge.isBusy`; 0006's `CanvasInputRouter` ignores mouse-down on that document's canvas (tool-key shortcuts still switch tools; no tool has a pending edit because it was committed). `UndoBridge` itself asserts (Debug) that `commit`/`perform`/`undo`/`redo`/`jump` are not called by anyone else while busy (the session's own final `commit` happens after it clears the flag).

13. **`Document/DocumentWindowController.swift`** (extend):
    - `@objc func runEffect(_ sender: Any?)` — the menu item's `representedObject` is the effect id. Guard: not gesture-in-progress, not busy, no attached sheet. Then `undoBridge.prepareForNavigation?()` (reason `.command` → "Finish Pixels" first if pixels float, 0020), `let values = AppModel.shared.effectMemory.initialValues(for:colors:seed:)` (seed from `SystemRandomNumberGenerator`; 0043 replaces this with `AppModel.effectSeeds`, an `EffectSeedSource`), then:
      - **with parameters:** create the controller, present `EffectDialogView` (item 15) as a sheet (0025 pattern: `NSHostingController`, `window.beginSheet`, sheet delegate returns a private `UndoManager`), `start()`. Dialog OK → `controller.ok()`; the sheet closes immediately and, if the render isn't complete, the progress sheet (item 16) follows the 0.5 s rule below. On `.done`: `effectMemory.remember(values)` and `recordApplied`. Dialog Cancel/Escape → `controller.cancel()`, close the sheet.
      - **without parameters:** create the controller, `start()`, `ok()`; `recordApplied` on `.done`.
    - `@objc func repeatLastEffect(_ sender: Any?)` (⌘F): same guards; `prepareForNavigation`; look up `effectMemory.lastApplied` in the registry; run like a no-dialog effect with the remembered values (no dialog even for dialog effects, EffectsMenu.html). (0043 reseeds `.seed` parameters here via `EffectParameterMemory.repeatRequest`.)
    - **Progress sheet rule:** whenever a controller is in `.finishing` and has not finished **0.5 s** after entering it, present `EffectProgressView` as a sheet; its Cancel button and Escape call `controller.cancel()`. Dismiss it on finish. (Small images never show it.)
    - **Hidden active layer:** effects run normally (the result is not visible until the layer is shown) — see *Open questions* 3. No layer locking exists in PRD/Paint.NET.
    - `validateMenuItem`: effect items and Repeat are enabled iff a document is open, `!isGestureInProgress`, `!undoBridge.isBusy`, no sheet attached; Repeat additionally requires `effectMemory.lastApplied != nil` and its title is `effectMemory.repeatTitle(registry:)` (set during validation so the menu always shows "Repeat <name>").
    - `windowShouldClose` / document close while busy: `controller.cancel()` first (restores the original pixels synchronously on the main actor), then the normal close flow (unsaved-changes prompt etc.). With a dialog sheet attached AppKit already blocks the close button.
    - The `onStateChange` handling of 0008 needs no change (`updateLiveState` tile writes are picked up by generation tracking; the final `commit` reports `.pixels`).

14. **`App/AppModel.swift`** (extend): `let effectRegistry = EffectRegistry.standard`, `var effectMemory = EffectParameterMemory()`, `lazy var coreImageBridge: CoreImageBridge?` (nil + logged when Metal is unavailable; effect items are then disabled, never a crash), `func makeEffectRunner() -> EffectRunner`.

15. **`UI/EffectDialogView.swift`** (new, SwiftUI) — generated from the schema; the only effect dialog in the app.
    - Root accessibility identifier `effectDialog`; title text = `effect.name`. One row per parameter in schema order, label `"\(label):"`:
      - `.integer` / `.double` / `.angle`: `Slider` (range, step) with identifier `effectDialog.<id>` (value = formatted current value) + a numeric `TextField` `effectDialog.<id>.field` (commits on Tab, focus loss, or Return; invalid text reverts to the current value; parsed through `EffectParameterText`, normalized by the controller). Angle: same slider + field, label suffix "°".
      - `.bool`: `Toggle` checkbox `effectDialog.<id>`.
      - `.choice`: `Picker` pop-up `effectDialog.<id>` with the option labels.
      - `.color`: a swatch button `effectDialog.<id>` showing the color with `ColorPicker` (sRGB 8-bit result).
      - `.seed`: button **"Reseed"** `effectDialog.<id>` (new random `UInt64`; injectable generator for tests).
    - A small `ProgressView` `effectDialog.progress` whose accessibility value is `"rendering"` while the current generation is incomplete and `"idle"` when complete (UI tests wait on it).
    - Buttons **Cancel** (`effectDialog.cancel`, `.cancelAction` / Escape) and **OK** (`effectDialog.ok`, `.defaultAction` / Return). OK first commits the focused field's text, then calls the controller.
    - The view only renders a `@Observable` `EffectDialogModel` (in the same file) that forwards every change to `EffectSessionController.update`; no clamping, formatting or effect logic in the view.

16. **`UI/EffectProgressView.swift`** (new, SwiftUI): `init(title: String, fraction: Double, onCancel: @escaping () -> Void)` — a plain-string title so non-effect commands (0035 Resize Image) reuse it unchanged; identifier `effectProgress`; title = effect name for effects; determinate `ProgressView(value: fraction)` (`effectProgress.bar`); **Cancel** (`effectProgress.cancel`, Escape).

17. **`App/MainMenu.swift`** (extend 0001/0022/0024): two new top-level menus inserted **after Layers, before Window**: **Adjustments** (`menu.adjustments`) and **Effects** (`menu.effects`), built from `AppModel.shared.effectRegistry` by `static func makeAdjustmentsMenu(registry:)` / `makeEffectsMenu(registry:)` (pure functions of the registry, unit-tested):
    - Adjustments: one item per `registry.adjustments` (sorted by name): title `menuTitle`, identifier `menu.adjustments.<id>`, action `runEffect(_:)`, target nil, `representedObject` = id, key equivalent from `shortcut` (Invert Colors: `i`, ⇧⌘). Result now: "Brightness / Contrast…", "Invert Colors ⇧⌘I".
    - Effects: first item **Repeat** (title updated by validation to "Repeat <name>"), key `f` ⌘, action `repeatLastEffect(_:)`, identifier `menu.effects.repeat`; then, if `effectSubmenus` is non-empty, a separator and one submenu per category (`menu.effects.<category>`, title `category.menuTitle`) containing its effects (`menu.effects.<category>.<id>`). With this spec the Effects menu holds only "Repeat" (disabled until an effect ran); 0041 adds the first submenu.
    - `MainMenuTests.topLevelMenusInOrder` → `["PaintDotMac","File","Edit","View","Image","Layers","Adjustments","Effects","Window","Help"]`.

18. **Test-only hook:** none new (`-UITestSelectRect` and `-UITestOpen` suffice). 0043 adds `-UITestEffectSeed <UInt64>` (deterministic seeds for dialogs, Reseed and Repeat).

19. **`project.yml`:** `MTLLINKER_FLAGS` (item 7); new files are picked up by the existing source globs, including `PaintDotMacTests/Effects/Reference/`. Run `xcodegen generate`.

No PRD change in this spec; the open questions below record the product decisions applied.

## Acceptance criteria

- [ ] FX-A: effects are declared once (`ImageEffect` + schema) and registered in `EffectRegistry.standard`; the standard registry passes schema validation; menus and the dialog are generated from it. → `EffectRegistryTests.*`, `EffectSchemaValidatorTests.*`, `MainMenuEffectsTests.*`
- [ ] ADJ-6: Invert Colors (⇧⌘I, no dialog) maps `(R,G,B,A) → (255−R,255−G,255−B,A)` on the active layer, recorded as one "Invert Colors" step; undo/redo exact. → `InvertColorsTests.*`, `EffectGoldenTests.invertMatchesOracle`, `EffectSessionIntegrationTests.noDialogEffectCommitsOneStep`, `EffectsUITests.testInvertColorsShortcutAndUndo`
- [ ] ADJ-3: Brightness / Contrast has parameters Brightness and Contrast, −100…100, default 0, and matches Paint.NET's formula (all three branches) within ±1 (expected exactly 0). → `BrightnessContrastReferenceTests.*`, `EffectGoldenTests.brightnessContrastGrid`, `.brightnessContrastRandom`
- [ ] FX-B: effects render on the GPU through a Metal-backed `CIContext`; each has a CPU oracle in `PaintDotMacTests/Effects/Reference/`. → `CoreImageBridgeTests.*`, `EffectGoldenTests.*`
- [ ] FX-D: with a selection, only selected pixels change, antialiased edges are blended by mask coverage, and pixels outside are byte-identical. → `EffectMaskBlendTests.*`, `EffectRunnerTests.selectionClipsAndSkipsEmptyTiles`, `EffectSessionIntegrationTests.selectionClippedApply`, `EffectsUITests.testInvertRespectsSelection`
- [ ] §5.8 live preview: while the dialog is open the canvas shows the effect on the active layer, with no history step; changing a parameter cancels the running render and re-renders (debounced); visible tiles render first. → `EffectSessionIntegrationTests.previewWritesLiveStateWithoutStep`, `.parameterChangeCancelsAndRestarts`, `.staleChunksIgnored`, `EffectRunnerTests.visibleChunksFirst`, manual 1
- [ ] §5.8 Cancel restores the layer exactly (tile storage identical), no step; OK commits exactly one step named after the effect (none if nothing changed). → `EffectSessionIntegrationTests.cancelRestoresExactly`, `.okCommitsOneStep`, `.noOpAddsNoStep`, `EffectsUITests.testBrightnessContrastCancelAndOK`
- [ ] FX-C: rendering is cancellable and reports monotonic progress; a long run shows a progress sheet after 0.5 s that Escape/Cancel cancels with an exact restore. → `EffectRunnerTests.cancellationStops`, `.progressIsMonotonic`, `EffectSessionIntegrationTests.cancelDuringFinishing`, manual 2
- [ ] §5.8 Repeat last (⌘F) re-runs the last applied effect with its values without a dialog; disabled and titled "Repeat" until something was applied; titled "Repeat <name>" after. → `EffectParameterMemoryTests.*`, `EffectSessionIntegrationTests.repeatUsesLastValues`, `EffectsUITests.testRepeatLast`
- [ ] Parameters are remembered per effect for the session (on OK only). → `EffectParameterMemoryTests.rememberOnOKOnly`, `EffectsUITests.testBrightnessContrastCancelAndOK`
- [ ] Only the active layer changes; other layers are byte-identical; hidden active layers are processed. → `EffectSessionIntegrationTests.onlyActiveLayerChanges`, `.hiddenActiveLayer`
- [ ] Floating pixels / pending tool edits are finished ("Finish Pixels") before the effect, and the document is locked (menus, undo, History/Layers panels, canvas input) while an effect session runs. → `EffectSessionIntegrationTests.pendingEditFinishedFirst`, `.busyFlagLifecycle`, `EffectMenuValidationTests.*`
- [ ] Adjustments and Effects menus sit between Layers and Window with the listed items, identifiers, and shortcuts; no duplicate shortcuts. → `MainMenuEffectsTests.*`, `MainMenuTests.noDuplicateShortcuts`, `EffectsUITests.testMenus`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **1×1, 255×255, 257×257, 300×200 images** (edge tiles, partial tiles): out-of-canvas tile bytes stay 0; results correct on the last row/column. → `EffectRunnerTests.edgeTilesKeepInvariant`
- **Unallocated (transparent) source tiles:** read as zeros; Invert allocates them as `(255,255,255,0)`; Brightness / Contrast with brightness > 0 on `(0,0,0,0)` produces `(b,b,b,0)` and allocates; outputs that are all-zero stay unallocated. → `EffectRunnerTests.sparseTiles`
- **Alpha-0 pixels with color:** `.straight` effects keep and transform that color (no premultiply loss). → `CoreImageBridgeTests.straightRoundTripExact`
- **Selection partly transparent / antialiased:** blend per `EffectMaskBlend`; `.empty` mask tiles are not rendered at all; `.full` tiles are not blended. → `EffectMaskBlendTests.*`, `EffectRunnerTests.selectionClipsAndSkipsEmptyTiles`
- **Effect that changes nothing** (Brightness / Contrast 0/0, or Invert twice through Repeat → second step exists, restoring the original): 0/0 adds no step (H-6) and still sets `lastApplied`. → `.noOpAddsNoStep`
- **OK before the preview finished:** the current generation continues and commits; no pixel of an older generation survives. → `.okBeforeRenderComplete`
- **Rapid slider drags:** each change cancels the running render; only the final values are committed. → `.parameterChangeCancelsAndRestarts`
- **Escape in the dialog** = Cancel; **Escape on the progress sheet** = Cancel (exact restore, no step, values not remembered).
- **GPU/Core Image failure** (no Metal device, missing kernel, render error): menu items disabled when no bridge; render errors restore the original and show "The effect couldn’t be applied."; no crash. → `CoreImageBridgeTests.noDeviceThrows`, `EffectSessionIntegrationTests.rendererErrorRestores`
- **Document closed while a no-dialog effect runs:** cancel + restore, then the normal close prompt. → `EffectSessionIntegrationTests.cancelIsSynchronous` + manual 3
- **Other documents** stay fully usable while one document runs an effect (the busy flag is per `UndoBridge`). → `.busyIsPerDocument`
- **Huge images (65,535 × 1 and 6,000 × 4,000):** chunked; memory bounded per chunk. → `EffectRunnerTests.extremeAspect`, `EffectRunnerPerformanceTests.testInvert24MP`
- **Repeat after the remembered effect's document closed / in another document:** Repeat is app-wide and applies to the front document.
- **Gesture in progress / sheet attached:** effect items and Repeat disabled. → `EffectMenuValidationTests.*`

## Test plan

Expected values come from Paint.NET's formula (transcribed above), hand calculation, or the CPU oracles — never from running the code under test.

- **CPU oracles** (`PaintDotMacTests/Effects/Reference/`): `InvertColorsReference.apply(_ pixels: [ColorRGBA8]) -> [ColorRGBA8]`; `BrightnessContrastReference.apply(_:brightness:contrast:)` — a literal transcription of Paint.NET 3.36 including its 65,536-entry `rgbTable` construction and the `divide == 0` branch (deliberately table-based, unlike the kernel, so it is an independent implementation); `MaskBlendReference.apply(original:effect:mask:)` written with `Double` math and rounding, independent of `EffectMaskBlend`'s integer form. `ReferenceEffectRenderer: EffectTileRenderer` wraps an oracle so runner/session tests can run without the GPU.
- **Unit — `PaintDotMacTests/Effects/BrightnessContrastReferenceTests.swift`** (validates the oracle against hand math): pixel (200,100,50,255): I = 124 (hand: 8,139,550 >> 16); b=20,c=0 → (220,120,70,255); b=0,c=50 → shift −3 → (197,97,47,255); b=0,c=−50 → shift (−150/100 = −1) + 3 = 2 → (202,102,52,255); b=0,c=100 → (0,0,0,255); b=4,c=100 → I+b = 128 → (255,255,255,255); (250,250,250,77) b=20,c=0 → (255,255,255,77) (clamp, alpha kept); (0,0,0,0) b=−100,c=0 → (0,0,0,0).
- **Unit — `PaintDotMacTests/Effects/InvertColorsTests.swift`:** metadata (id, name "Invert Colors", `.adjustment`, no parameters, `hasDialog == false`, `menuTitle == "Invert Colors"`, shortcut `i` + [.command,.shift], icon `.adjustment`); oracle (10,20,30,40) → (245,235,225,40), (0,0,0,0) → (255,255,255,0).
- **Unit — `PaintDotMacTests/Effects/BrightnessContrastTests.swift`:** metadata (id, name, parameters `brightness`/`contrast` labels "Brightness"/"Contrast", ranges −100…100, defaults 0, step 1, `menuTitle == "Brightness / Contrast…"`, no shortcut, `inputPadding == 0`).
- **Unit — `PaintDotMacTests/Effects/EffectParameterTests.swift`:** `normalizationClampsAndSnaps` (integer 150 → 100, −101 → −100; step 5 range 0…100: 12 → 10, 13 → 15, 12.5-equivalent tie → larger); `doubleRoundsToDecimals` (2 dp: 1.005 → 1.01 with `.toNearestOrAwayFromZero` on the scaled value 100.5 → 101); `unknownChoiceFallsBack`; `wrongCaseFallsBack`; `defaultsFromSchema` (color `.primary` resolves to the given `ColorSelection.primary`); `normalizedDropsUnknownAndFillsMissing`; `textFormatAndParse` ("−20"/"-20" → −20, " 7 " → 7, "abc" → nil, "1e400"/"nan" → nil, "2.50" for decimals 2 → 2.5, integer kind "3.0" → 3, "3.5" → nil).
- **Unit — `PaintDotMacTests/Effects/EffectSchemaValidatorTests.swift`:** each problem kind detected with a stub effect (duplicate ids, empty range, step 0, default off-grid, default out of range, bad choice default, decimals 5); `standardRegistryIsValid` (no problems).
- **Unit — `PaintDotMacTests/Effects/EffectRegistryTests.swift`:** `standardContents` (ids `["invertColors","brightnessContrast"]` in registration order, unique); `adjustmentsSortedByName` (["Brightness / Contrast","Invert Colors"]); `effectSubmenusEmptyNow`; `submenusOrderedByCategory` (stub registry with photo, blurs, artistic effects → categories artistic, blurs, photo; effects inside sorted by name; empty categories omitted); `lookupById` (unknown → nil). 0032, 0033 and 0034 each update `standardContents` and `adjustmentsSortedByName` to their exact lists.
- **Unit — `PaintDotMacTests/Effects/EffectParameterMemoryTests.swift`:** `initialIsDefaults`; `rememberOnOKOnly` (remember b=20 → next initial b=20; a session that is cancelled doesn't call remember — asserted at controller level); `rememberedValuesAreNormalized` (stored 150 → 100); `repeatTitle` ("Repeat" → after `recordApplied(BrightnessContrast)` "Repeat Brightness / Contrast"); `colorDefaultReResolvedUntilEdited`; `appWideNotPerDocument` (one memory instance used by two sessions).
- **Unit — `PaintDotMacTests/Effects/EffectMaskBlendTests.swift`:** endpoints exact (m 0 / 255) incl. storage identity for `.empty` tiles in `blendTile`; m=128, orig (0,0,0,255), fx (255,255,255,255) → (128,128,128,255) (hand: alpha 65,152/255 = 255; color 8,355,712/65,025 = 128); alpha-weighted case orig (255,0,0,255), fx (0,0,255,0), m=128 → a = (32,385+127)/255 = 127, color r = (255·255·127 + 16,192)/(127·255) = 8,274,367/32,385 = 255, b = 0 (fx alpha 0 contributes nothing) → (255,0,0,127); both alpha 0 → straight lerp of colors; seeded property test (1,000 random triples, `SeededRandom`) vs `MaskBlendReference` within ±1; `blendTileOutOfCanvasZero`; `allZeroResultIsNil`.
- **Unit — `PaintDotMacTests/Effects/EffectRunnerTests.swift`** (with `ReferenceEffectRenderer`, `maxConcurrentChunks: 1` unless stated): `affectedTilesWholeLayer` (700×300 → 3×2 tiles); `selectionClipsAndSkipsEmptyTiles` (selection rect (300,0,100,100) on 700×300 → affected `[(1,0)]`, the renderer is called only for that chunk, pixels outside the rect equal the source, inside inverted); `chunkOrderRowMajor` (5×3 tiles, chunkTiles 2 → 6 chunks row-major); `visibleChunksFirst` (priority rect over tiles (3…4, 1…2) → that chunk first, then nearest, then the rest row-major — exact expected list written out); `progressIsMonotonic` (strictly increasing, last == total, total = affected tile count); `cancellationStops` (renderer that blocks on a semaphore after the first chunk; cancel the consumer → stream throws `CancellationError`, renderer called ≤ 2 times); `rendererErrorPropagates`; `edgeTilesKeepInvariant` (257×257 Invert → tile (1,1) pixel (0,0) inverted, bytes outside the canvas 0); `sparseTiles` (Invert on an empty 600×300 layer → all 3 tiles allocated, pixel (599,299) == (255,255,255,0); BC b=−50 on empty → no tiles allocated); `zeroAffectedTilesFinishesEmpty`; `extremeAspect` (65,535×1 Invert via oracle renderer: pixel (65,534,0) inverted, 256 tiles); `concurrentEqualsSerial` (`maxConcurrentChunks: 4` result tiles == serial result).
- **GPU — `PaintDotMacTests/Rendering/CoreImageBridgeTests.swift`** (Swift Testing, real device and the app's metallib): `kernelsLoad` (`invertColors`, `brightnessContrast` found); `noDeviceThrows` (`init(device: nil, …)` → `.gpuUnavailable`); `straightRoundTripExact` (identity effect returning `input`, seeded random 300×200 incl. alpha 0 with non-zero color and alpha 255 → bytes identical); `premultipliedRoundTrip` (alpha > 0 pixels identical; alpha-0 pixels → (0,0,0,0)); `orientationAndOffset` (region (256,0,44,200) of a surface whose pixels encode their coordinates → the identity render returns exactly those coordinates row by row, top row first); `clampedEdges` (effect = `input.transformed(by: translationX: 1)`; output column 0 equals input column 0 (replicated edge)); `ciRectMath` (hand-computed `ciRect`/`ciPoint` for inputRect (100,50,300,200)).
- **Golden — `PaintDotMacTests/Effects/EffectGoldenTests.swift`** (GPU vs oracle with `GoldenImage.compare`, tolerance ±1; expected 0 differences, reported): fixture 600×400 seeded random straight RGBA (alpha drawn from {0, 1, 77, 128, 254, 255}, colors uniform), spanning 3×2 tiles: `invertMatchesOracle`; `brightnessContrastGrid` (b,c ∈ {(0,0),(20,0),(−100,0),(100,0),(0,50),(0,−50),(0,99),(0,100),(4,100),(−30,100),(37,−63),(−100,−100),(100,100)}); `brightnessContrastRandom` (20 seeded (b,c) pairs, seed printed); `selectionBlendGolden` (antialiased ellipse selection via `Selection(path:)` + Invert through `CoreImageBridge` + runner vs oracle + `MaskBlendReference`). No PNG goldens are recorded: the oracle is the golden.
- **Integration — `PaintDotMacTests/Document/EffectSessionIntegrationTests.swift`** (`@MainActor`, real `UndoBridge` with a 600×400 two-layer document, active layer 1, `debounce: .zero` unless stated; renderer = `CoreImageBridge` for pixel tests, `ReferenceEffectRenderer`/gated stub for timing tests): `previewWritesLiveStateWithoutStep` (start BC b=20 → after completion live layer-1 pixels equal the oracle, `history.steps.count` unchanged, `isBusy`); `cancelRestoresExactly` (after preview, cancel → every tile of layer 1 `sharesStorage` with the original or both nil; no step; `!isBusy`); `okCommitsOneStep` (OK → one step "Brightness / Contrast", icon `.adjustment`; undo → original bytes; redo → oracle bytes); `noOpAddsNoStep` (0/0 OK → no step, `lastApplied` set); `noDialogEffectCommitsOneStep` (Invert → "Invert Colors" step); `parameterChangeCancelsAndRestarts` (gated stub: update b three times synchronously → only one new generation rendered with the final value; the first generation's task is cancelled); `staleChunksIgnored` (a chunk of generation 1 delivered after generation 2 started is not written); `okBeforeRenderComplete` (OK while gated → phase `.finishing`; release → committed pixels equal the final values' oracle); `cancelDuringFinishing` (exact restore, no step); `selectionClippedApply` (`-UITestSelectRect`-equivalent selection rect (100,100,200,100) → only those pixels change, step recorded, undo exact); `onlyActiveLayerChanges` (layer 0 tiles share storage before/after); `hiddenActiveLayer` (layer 1 hidden → effect applied, step recorded); `pendingEditFinishedFirst` (floating pixels from 0020 → steps end "Finish Pixels", "Invert Colors"); `busyFlagLifecycle` (true from start until done/cancel/failure); `busyIsPerDocument`; `rendererErrorRestores` (failing stub → original bytes, phase `.failed`, no step); `cancelIsSynchronous` (after `cancel()` returns, without awaiting, the live bytes are the original); `repeatUsesLastValues` (OK b=20 → repeat → second step "Brightness / Contrast", pixels = oracle applied twice); `undoAfterRepeat` (two undos → original).
- **Unit — `PaintDotMacTests/App/MainMenuEffectsTests.swift`** (`@MainActor`): `topLevelOrder` (list above, identifiers `menu.adjustments`, `menu.effects`); `adjustmentsItems` (exactly `[("Brightness / Contrast…", "", [], runEffect:, "brightnessContrast"), ("Invert Colors", "i", [.command,.shift], runEffect:, "invertColors")]`, identifiers); `effectsMenuHasRepeatOnly` (one item "Repeat", `f` + ⌘, `repeatLastEffect:`, `menu.effects.repeat`); `submenusFromStubRegistry` (stub registry with a blurs effect → separator + submenu "Blurs" `menu.effects.blurs` containing `menu.effects.blurs.<id>`); `MainMenuTests.noDuplicateShortcuts` still passes (⇧⌘I, ⌘F unique). 0032, 0033 and 0034 each update `adjustmentsItems` to their exact full list.
- **Unit — `PaintDotMacTests/Document/EffectMenuValidationTests.swift`:** the enablement rule as a pure function `EffectMenuRule.isEnabled(hasDocument:isGestureInProgress:isBusy:hasSheet:hasLastApplied:isRepeat:hasBridge:)` (put in `Document/EffectSessionController.swift`), full truth table.
- **UI — `PaintDotMacUITests/EffectsUITests.swift`** (fixture: 300×200 PNG filled with (200,100,50,255), written with `UITestFixtures.writePNG`; pixel checks by ⌘S and decoding the PNG in the test):
  - `testMenus`: Adjustments menu items "Brightness / Contrast…" and "Invert Colors" (⇧⌘I shown) appear in that relative order (asserted as a subsequence, so 0032–0034's added items don't break it); Effects menu "Repeat" disabled.
  - `testInvertColorsShortcutAndUndo`: ⇧⌘I → last history row "Invert Colors"; ⌘S → pixel (10,10) == (55,155,205,255); ⌘Z → one history row; ⌘S → (200,100,50,255).
  - `testBrightnessContrastCancelAndOK`: Adjustments ▸ Brightness / Contrast… → `effectDialog` appears, `effectDialog.brightness.field` "0", `effectDialog.contrast.field` "0"; type "20⇥" in the brightness field, wait for `effectDialog.progress` value "idle"; Escape → sheet gone, history unchanged, ⌘S → (200,100,50,255). Reopen → field "0" (Cancel not remembered); type "20⇥", click `effectDialog.ok` → history row "Brightness / Contrast", ⌘S → (220,120,70,255). Reopen → field "20"; click `effectDialog.cancel`.
  - `testRepeatLast`: B/C 20 OK; Effects menu shows "Repeat Brightness / Contrast" enabled; ⌘F → two "Brightness / Contrast" rows, no sheet appeared, ⌘S → (240,140,90,255).
  - `testInvertRespectsSelection`: launch with `-UITestSelectRect 0,0,100,200`; ⇧⌘I; ⌘S → (50,10) == (55,155,205,255), (150,10) == (200,100,50,255).
  - `testMenusDisabledWhileDialogOpen`: with the dialog open, the Edit menu's Undo and the Adjustments items are disabled; Cancel.
- **Performance — `PaintDotMacTests/Effects/EffectRunnerPerformanceTests.swift`** (XCTest `measure`): `testInvert24MP` (6000×4000 opaque layer, real bridge, whole run) — informational for NF-3's design (NF-3 itself is Gaussian Blur, measured in 0041); gate only on gross regression: average ≤ 1.5 s. Record the number in Verification status.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build without warnings, all tests pass, none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open a ~4000×3000 photo, zoom to 100% on a corner, open Brightness / Contrast…, drag Brightness quickly: the visible area updates first and follows the slider without stutter; tiles off-screen finish shortly after; Cancel restores the photo exactly (toggle with ⌘Z shows no step).
  2. Open a 12000×8000 image, press ⇧⌘I: after ~0.5 s a progress sheet appears; press Escape → image unchanged, no history row. Run again to completion → one "Invert Colors" row.
  3. Start Invert on the huge image and close the window (⌘W) during the run: the effect is cancelled and the normal close prompt (if any) appears; no crash.
  4. Dark mode and VoiceOver: the dialog's labels, sliders and fields are read correctly ("Brightness: 0").

## Open questions

Decided as stated (recommended answers applied in this spec); please confirm and record in PRD.md §5.8/§5.9/§12:

1. **Repeat (⌘F) covers adjustments too, with one shared "last applied" slot shown at the top of the Effects menu as "Repeat <name>".** PRD §5.8 requires "Repeat last" for adjustments, while Paint.NET's docs only describe repeating effects. Recommended: yes — one app-wide slot for both menus, item in the Effects menu only.
2. **Effect parameters are remembered per effect for the app session only (in memory, app-wide, updated on OK only, not on Cancel); nothing is persisted across launches.** This mirrors Paint.NET. Recommended: yes.
3. **Effects run on a hidden active layer** (no preview is visible until the layer is shown), as Paint.NET allows editing hidden layers. Recommended: yes.
4. **Invert Colors (and every per-pixel adjustment) also transforms the color stored under fully transparent pixels**, so inverting a layer with transparent areas allocates those tiles as `(255,255,255,0)` (invisible, but they cost memory and file size). This is Paint.NET's per-pixel behaviour and keeps the GPU result equal to the oracle. Alternative: skip pixels with alpha 0. Recommended: keep Paint.NET's behaviour.
5. **The progress sheet appears only when a run (no-dialog effect, Repeat, or OK before the preview finished) takes longer than 0.5 s**; the dialog itself shows a small busy indicator during preview. Recommended: yes.

## Out of scope

- Remaining adjustments: Black and White, Hue / Saturation, Posterize, Sepia (0032); Levels, Auto-Level and the `.levels` schema kind (0033); Curves and `.curve` (0034).
- All Effects-menu effects and their category submenus (0041–0044; P1 0064–0069); NF-3 measurement and tuning of `EffectRunner.Configuration` (0041).
- Moving effect shortcuts into `Core/Shortcuts/ShortcutTable.swift` (0045).
- Autosave while an effect session is active: 0047 must skip crash-recovery autosave while `UndoBridge.isBusy` (the live state then contains preview pixels).
- A per-parameter "reset to default" button, an angle dial control, and a before/after toggle in the dialog (not required by the PRD).
- Effects on multiple layers at once, Invert Alpha, and plugins (not in PRD).
