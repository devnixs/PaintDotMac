# 0060 — Add layer-level Flip Horizontal, Flip Vertical, Rotate 180°, and the Rotate / Zoom dialog (L-7)

> Source: PRD.md §5.4 L-7 ("Layer-level flip horizontal/vertical, rotate, and zoom.", P1, `PRD.md:143`); §5.7 H-6 / §12 D-34 (no-op edits add no step; undo doesn't switch layers); §5.8 shared adjustment rules (live preview, Cancel restores exactly) and FX-A–FX-D (schema-generated dialog, selection-clipped apply); §5.12 + 0045 Q6 (Paint.NET's Ctrl+Shift+Z for Rotate / Zoom collides with Redo ⇧⌘Z → no shortcut); D-33 (colour under alpha 0 preserved by permutations); NF-6 (resampling has unit tests); NF-9 (straight RGBA8, premultiplied only for math); AGENTS.md architecture rules 1–5 and 7 (Core without AppKit, pixels only through history, 256×256 tiles, schema-generated dialogs, heavy work off the main actor).
> Paint.NET docs (fetched 2026-11-08; `getpaint.net/doc/latest/…` redirects to `paint.net/doc/latest/…`):
> - Layers menu — https://paint.net/doc/latest/LayersMenu.html. Quoted: "The commands in this menu only affect the active layer, as chosen in the Layers Window." **Flip Horizontal**: "This command flips the active layer so left becomes right and vice versa." **Flip Vertical**: "This flips the active layer so the top becomes bottom and vice versa." **Rotate 180°**: "Rotates the active layer by 180 degrees." **Rotate / Zoom**: "This command allows the active layer to be rotated, panned and enlarged or reduced." Menu order: Add New Layer, Delete Layer, Duplicate Layer, Merge Layer Down, Toggle Layer Visibility, Import From File, **Flip Horizontal, Flip Vertical, Rotate 180°, Rotate / Zoom**, Go to Top Layer, Go to Layer Above, … Layer Properties. No shortcut is listed for the flips or Rotate 180°.
> - Rotate/Zoom — https://paint.net/doc/latest/RotateZoom.html. Opened from the Layers menu "or with **Ctrl + Shift + Z**". Controls: *Roll / Rotate* (outer ring = rotation about the layer centre, Shift = 15° steps; plus Tilt 0–90° and Direction −180…180 for a 3-D roll), *Pan* ("moves the layer within its own plane"; a pad plus horizontal/vertical sliders), *Zoom* ("Higher values enlarge … smaller values shrink"), *Quality* (supersampling), *Tiling* (None: "Areas not covered by the image become transparent"; Repeat; Mirror), *Sampling* (Bilinear, Nearest Neighbor).
> - Paint.NET API reference for the effect behind the dialog — https://paintdotnet.github.io/apidocs/api/PaintDotNet.Effects.Gpu.PdnRotateZoomEffect.Props.html: `RollAngle` −180…+180 default 0; `RollAmount` (tilt) 0…90 default 0; `RollDirection` −180…+180 default 0; `Offset` (pan) "translation offset … in normalized coordinates" (−10,−10)…(+10,+10) default (0,0); `Zoom` **0.06…16.0, default 1.0**.
> Milestone: v1.x
> Depends on: 0051-use-case-acceptance-tests (v1.0 complete), and through it 0002 (`TiledSurface`, `Tile`), 0008 (`TileDiff`, `TileDiffHistoryItem`, `HistoryIcon.flipRotate`, `UndoBridge`), 0013 (`Selection`, `SelectionMask`), 0020 (`Resampler`, `ResamplingMode`, "Finish Pixels"), 0024 (Layers menu, `LayerCommandRunner` pattern), 0025 (Layer Properties… last), 0030 (Import From File… slot), 0031 (`ImageEffect`, `EffectParameter`, `EffectRunner`, `EffectTileRenderer`, `EffectSessionController`, `EffectDialogView`, `UndoBridge.isBusy`, progress sheet), 0032 (`EffectParameterEditor`), 0033 (`ImageEffect.prepare`, `EffectPreparation`, `EffectParameterValues.resolving`), 0035 (`ResamplingMode.bicubic`, `ImageCommandRule`), 0037 (`FlipRotateKind`, `FlipRotateImage.transformed`), 0042 (`.offset` parameter kind, `EffectOffset`, `OffsetControl`), 0045 (`ShortcutTable`, `docs/shortcuts.md`).

## Context

No application code exists yet (specs only). What the earlier specs provide, which this spec reuses without parallel types:

- **Whole-image flips/rotations (0037, `docs/specs/todo/0037-flip-and-rotate-image_TODO.md:35-75`)**: `FlipRotateKind` (`flipHorizontal`, `flipVertical`, `rotate90Clockwise`, `rotate90CounterClockwise`, `rotate180`) with exact pixel maps (`sourcePixel(x:y:sourceSize:)`), and `FlipRotateImage.transformed(_ surface: TiledSurface, _ kind: FlipRotateKind) -> TiledSurface` (`:54`): a lossless, tile-parallel permutation (vImage), sparse tiles stay unallocated, uniform interior tiles shared, edge-tile padding zero. Flips and 180° keep the surface size, which is exactly what a layer flip needs.
- **History (0008)**: `TileDiff.between(before: TiledSurface, after: TiledSurface, layerID:, candidates:)` and `TileDiffHistoryItem(name:icon:diff:)` (`isNoOp` when the diff is empty, H-6; change `.pixels`; keyed by layer ID, so undo never changes `activeLayerIndex`). `HistoryIcon.flipRotate` exists (0008 `:50-55`). `UndoBridge.perform(_:)`, `prepareForNavigation` (reason `.command` → 0020 records "Finish Pixels" first).
- **Layers menu (0024 `0024-layer-stack-and-compositor_TODO.md:155-169`)**: Add New Layer ⇧⌘N, Delete Layer ⇧⌘⌫, Duplicate Layer ⇧⌘D, Merge Layer Down ⌘E, (0030: Import From File…), separator, Go to Layer Above, Go to Layer Below, separator, Move Layer Up, Move Layer Down, (0025: separator, Layer Properties…). 0024 `:169` reserves the slot "0060 flips/rotate before Go to Layer Above".
- **Command enablement (0035 item 4a, used by 0037 `:125-128`)**: `ImageCommandRule.isEnabled(hasDocument:isGestureInProgress:isBusy:hasSheet:)`; 0037's static driver pattern `runFlipRotate(_:bridge:gestureInProgress:isBusy:hasSheet:)` so hosted tests run without a window.
- **Effect framework (0031 `0031-effect-framework-and-first-adjustments_TODO.md:37-275`)**: `ImageEffect` (`id`, `name`, `category`, `parameters`, `historyIcon`, `alphaMode`, `inputPadding`, `makeOutput`), `EffectCategory` (`adjustment`, `artistic`, `blurs`, `distort`, `noise`, `object`, `photo`, `render`, `stylize`), `EffectRegistry` (`adjustments`, `effectSubmenus`), `EffectParameterValues.defaults(for:colors:seed:)`, `EffectRequest`, `EffectTileRenderer` (`renderEffect(_:values:source:outputRect:) -> [UInt8]`), `EffectRunner(renderer:configuration:)` (chunked, cancellable, progress, selection clip through `EffectMaskBlend`), `EffectSessionController` (live preview via `updateLiveState`, debounce, OK → `TileDiffHistoryItem(name: effect.name, …)`, Cancel restores touched tiles sharing storage with the original, `isBusy`), `EffectDialogView` (sheet; identifiers `effectDialog`, `effectDialog.<id>`, `effectDialog.<id>.field`, `effectDialog.ok`, `effectDialog.cancel`), the 0.5 s progress-sheet rule, `runEffect(_:)` in `DocumentWindowController` (item 13, `:259`). 0033 adds `prepare(values:source:selection:) -> EffectPreparation` (`.render(values)` / `.noChange`) and `EffectParameterValues.resolving(_:to:)` (`0033…:104-127`). 0042 adds the `.offset` kind (`EffectOffset` x, y ∈ −1…1, `point(in:)`, `referenceBounds(selection:canvasSize:)`, `OffsetControl` with pad + X/Y sliders and fields `effectDialog.<id>.x(.field)` / `.y(.field)`; `0042…:110-170`).
- **Resampling (0020 `0020-move-selected-pixels_TODO.md:33-62`, 0035 item 1)**: `Resampler.resample(_ source:, sourceOrigin:, transform: CGAffineTransform, mode:, destination: PixelRect) -> [UInt8]` (destination pixel centres mapped through the inverse transform; nearest = `floor`; bilinear premultiplied 2×2, **transparent outside**, alpha `Int(A + 0.5)`, colour `Int(P/A + 0.5)`; entries within `epsilon = 1e-9` of an integer snapped). 0035 adds `.bicubic` to the affine path (Keys a = −0.5, 4×4 premultiplied, transparent outside, overshoot clamped) and `ResamplingMode.displayName` ("Nearest Neighbor", "Bilinear", "Bicubic", "Supersampling").
- **Shortcuts (0045 `0045-shortcut-audit_TODO.md:184,414`)**: row `layers.rotateZoom` — action "Rotate / Zoom", no menu identifier, no bindings, Paint.NET "Ctrl + Shift + Z", `notMapped — "⇧⌘Z is Redo; feature is P1 (0060)."`; Q6 recommends no shortcut when 0060 adds the item. Items with no shortcut on either side have no table row (`everyItemMatchesTable`: an item without an entry must have no key equivalent).

What's missing: L-7. Paint.NET's Layers menu has Flip Horizontal, Flip Vertical, Rotate 180° and Rotate / Zoom for the **active layer only**; PaintDotMac has only the whole-image versions (0037).

## User story

As a PaintDotMac user, I choose **Layers ▸ Flip Horizontal**, **Flip Vertical**, or **Rotate 180°** and only the active layer is mirrored or turned, pixel-exactly, with the canvas size unchanged; the History panel shows "Flip Layer Horizontal" (etc.) and ⌘Z undoes it. I choose **Layers ▸ Rotate / Zoom…**, drag the Angle, Pan, and Zoom controls and pick the Sampling, watch the layer update live on the canvas, then click OK to record one "Rotate / Zoom Layer" step — or Cancel to get my layer back exactly as it was.

## Scope & changes

### Core — layer flips (pure, headless, unit-tested)

1. **`PaintDotMac/Core/Operations/LayerFlipRotate.swift`** (new):
   ```swift
   public enum LayerFlipKind: String, CaseIterable, Sendable {
       case flipHorizontal, flipVertical, rotate180          // raw values frozen; menu order
       /// Layers-menu title (Paint.NET spelling): "Flip Horizontal", "Flip Vertical", "Rotate 180°" (U+00B0, no space).
       public var menuTitle: String
       /// History step name: "Flip Layer Horizontal", "Flip Layer Vertical", "Rotate Layer 180°" (Open question 3).
       public var historyName: String
       /// The 0037 permutation used: .flipHorizontal, .flipVertical, .rotate180 (all size-preserving).
       public var imageKind: FlipRotateKind
   }
   public enum LayerFlipRotate {
       public static let icon: HistoryIcon = .flipRotate
       /// The active layer's surface permuted by `kind`; never mutates its input.
       public static func transformedActiveLayer(of image: LayeredImage, _ kind: LayerFlipKind) -> TiledSurface
       /// TileDiffHistoryItem(name: kind.historyName, icon: .flipRotate, diff:) for the active layer,
       /// or nil when the diff is empty (H-6: symmetric content, empty layer, 1-pixel axis).
       public static func makeHistoryItem(for state: DocumentState, _ kind: LayerFlipKind) -> TileDiffHistoryItem?
   }
   ```
   - `transformedActiveLayer` = `FlipRotateImage.transformed(image.layers[image.activeLayerIndex].surface, kind.imageKind)` (0037; lossless, sparse, uniform tiles shared, padding zero). No new pixel code.
   - `makeHistoryItem`: precondition `state.floatingPixels == nil` (`assert` + doc comment; the caller finishes them first). `let layer = state.image.layers[activeLayerIndex]`; `after = transformedActiveLayer(...)`; `diff = TileDiff.between(before: layer.surface, after: after, layerID: layer.id)` (all tiles are candidates); `diff.isEmpty → nil`; else the item. Applying the item through `UndoBridge.perform` writes `after`'s tiles into that layer.
   - **Only the active layer changes**: other layers keep `sharesStorage` on every tile; layer `id`, `name`, `isVisible`, `opacity`, `blendMode`, `activeLayerIndex`, image size and DPI unchanged. Hidden active layers are flipped too (Paint.NET applies Layers commands to the active layer regardless of visibility).
   - **Selection is ignored and unchanged** (Open question 2): the whole layer is flipped, `state.selection` is not read or modified.
   - **Why `TileDiffHistoryItem` and not 0037's `DocumentSnapshotHistoryItem`:** only one layer's pixels change, so the step is a pixel step keyed by layer ID. Undo after the user has switched to another layer restores the flipped layer's pixels without switching layers (H-6/D-34); a snapshot would restore the old `activeLayerIndex`. The cost equals the changed tiles (before + after), as for any paint step.

### Core — Rotate / Zoom as a layer effect (pure, headless, unit-tested)

2. **`PaintDotMac/Core/Effects/EffectCategory`** — in `Core/Effects/ImageEffect.swift` (extend 0031 item 2): add `case layer` **last** (`menuTitle` "Layers"). Layer effects are never registered in `EffectRegistry`: `EffectRegistry.init` Debug-asserts that no effect has category `.layer`, and `adjustments` / `effectSubmenus` filter `.layer` out explicitly (defence in depth). Every `switch` over `EffectCategory` gains the case. Update 0031's category test (`allCases` order) accordingly.

3. **`Core/Effects/ImageEffect.swift`** (extend 0031/0033) — history step name separate from the dialog title:
   ```swift
   public protocol ImageEffect {
       // … existing requirements …
       /// History step name. Default: `name`. Only layer effects override it.
       var historyName: String { get }
   }
   public extension ImageEffect { var historyName: String { name } }
   ```
   `EffectSessionController`'s commit (0031 item 11) uses `effect.historyName` instead of `effect.name`. Every existing effect keeps its step name (default), so their tests are unchanged; add one assertion `EffectSessionTests.historyNameDefaultsToName`.

4. **`PaintDotMac/Core/Effects/Layer/LayerRotateZoom.swift`** (new):
   ```swift
   public struct LayerRotateZoom: ImageEffect {
       public init()
       public let id = "layerRotateZoom"
       public let name = "Rotate / Zoom"                 // dialog title; menu title "Rotate / Zoom…"
       public var historyName: String { "Rotate / Zoom Layer" }
       public let category: EffectCategory = .layer
       public var historyIcon: HistoryIcon { .flipRotate }
       public let alphaMode: EffectAlphaMode = .straight
       public var parameters: [EffectParameter] { get }  // table below
       public func inputPadding(for values: EffectParameterValues) -> Int   // 0 (unused: rendered on the CPU from the whole source)
       /// Never called: LayerRotateZoomRenderer renders this effect. Throws EffectError.renderFailed.
       public func makeOutput(input: CIImage, values: EffectParameterValues, context: EffectRenderContext) throws -> CIImage
       /// 0033 hook: resolves the pivot and target into prepared values, or .noChange for the identity.
       public func prepare(values: EffectParameterValues, source: TiledSurface, selection: SelectionMask?) throws -> EffectPreparation

       public enum PreparedKey { public static let pivotX = "_pivotX", pivotY = "_pivotY", targetX = "_targetX", targetY = "_targetY" }
       /// Exact (cos, sin) for multiples of 90° (after reducing to −180…180), else (cos(θ·π/180), sin(θ·π/180)).
       public static func cosSin(degrees: Double) -> (cos: Double, sin: Double)
       /// Source-canvas → destination-canvas affine map (y down).
       public static func transform(angle: Double, zoom: Double, pivot: (x: Double, y: Double), target: (x: Double, y: Double)) -> CGAffineTransform
       public static func samplingMode(_ values: EffectParameterValues) -> ResamplingMode
       /// Renders `outputRect` of the transformed layer: Resampler.resample(source, sourceOrigin: (0,0),
       /// transform: transform(...prepared values...), mode: samplingMode(values), destination: outputRect).
       public static func render(source: TiledSurface, values: EffectParameterValues, outputRect: PixelRect) -> [UInt8]
   }
   ```
   **Parameters** (schema order = dialog order; labels as Paint.NET; Open question 1):

   | id | label | kind | range | default |
   |---|---|---|---|---|
   | `angle` | Angle | `.angle(range: -180...180, defaultValue: 0, decimals: 2)` | −180…180° (0 = east, counter-clockwise positive, 0031's convention) | 0 |
   | `pan` | Pan | `.offset(defaultValue: .zero, decimals: 2)` (0042) | x, y ∈ −1…1 | (0, 0) |
   | `zoom` | Zoom | `.double(range: 0.06...16, defaultValue: 1, step: 0.01, decimals: 2)` | 0.06…16 | 1.00 |
   | `sampling` | Sampling | `.choice(options: [bilinear "Bilinear", bicubic "Bicubic", nearestNeighbor "Nearest Neighbor"], defaultValue: "bilinear")` | — | Bilinear |

   Choice ids are `ResamplingMode` raw values and labels are `ResamplingMode.displayName` (0035). `EffectSchemaValidator` must report no problems (0 on the 0.01 angle grid; 1.00 on the 0.01 grid from 0.06 — if the validator requires `default − lowerBound` to be a multiple of `step`, it is: 0.94 = 94 × 0.01 within the validator's tolerance; if not, change the range lower bound to 0.05 and record it in the Verification status).

   **Geometry** (all `Double`; canvas y down; pixel edges at integers):
   - `bounds = EffectOffset.referenceBounds(selection: selection, canvasSize: source.size)` (0042: the selection's bounding rect, or the whole canvas when there is no selection).
   - `pivot = (bounds.minX + bounds.width / 2, bounds.minY + bounds.height / 2)` — the rotation and zoom centre (the canvas centre without a selection).
   - `target = values.offset("pan").point(in: bounds)` = `(minX + W·(1 + x)/2, minY + H·(1 + y)/2)` — where the pivot ends up; pan (0, 0) → target = pivot; x = 1 moves the content right by half the bounds width; y = 1 moves it down by half the bounds height.
   - `(c, s) = cosSin(degrees: angle)`, `z = zoom`. Forward map `p ↦ target + M·(p − pivot)` with `x' = z(c·dx + s·dy)`, `y' = z(−s·dx + c·dy)`, i.e. `CGAffineTransform(a: z·c, b: −z·s, c: z·s, d: z·c, tx: target.x − (z·c·pivot.x + z·s·pivot.y), ty: target.y − (−z·s·pivot.x + z·c·pivot.y))`. A positive angle turns the content **counter-clockwise on screen** (the top-right corner moves toward the top-left).
   - `cosSin`: reduce `θ` to (−180, 180]; for θ ∈ {0, 90, 180, −90} return exactly (1, 0), (0, 1), (−1, 0), (0, −1); otherwise `cos`/`sin` of radians. So right-angle transforms have exact integer coefficients and land on pixel centres (no reliance on snapping).
   - `prepare`: compute `bounds`, `pivot`, `target`; if `angle` reduces to 0 **and** `zoom == 1` **and** `pan == .zero` → `.noChange` (identity: the result would be byte-identical in every mode); else `.render(values.resolving(PreparedKey.pivotX, to: .double(pivot.x))…resolving(PreparedKey.targetY, to: .double(target.y)))`. Prepared values are never remembered (0033 rule).
   - `render`: reads the four prepared values (if missing — programmer error — `assertionFailure` and treat as the canvas centre), builds the transform, calls `Resampler.resample` over `outputRect`. Pixels whose source point falls outside the layer are transparent `(0,0,0,0)` (Tiling "None"); content transformed outside the canvas is discarded (the layer is canvas-sized).
   - **Selection (FX-D, Open question 2):** the source is the **whole** active layer (pixels outside the selection can rotate into it); the output is clipped to the selection by 0031's `EffectRunner` / `EffectMaskBlend` (unselected pixels byte-identical, antialiased edges blended by coverage). Only tiles whose mask tile is not `.empty` are rendered (0031 `affectedTiles`).

5. **`PaintDotMac/Core/Effects/Layer/LayerRotateZoomRenderer.swift`** (new):
   ```swift
   public struct LayerRotateZoomRenderer: EffectTileRenderer {
       public init()
       /// Calls LayerRotateZoom.render(source:values:outputRect:). Any other effect → throws EffectError.renderFailed.
       public func renderEffect(_ effect: any ImageEffect, values: EffectParameterValues, source: TiledSurface, outputRect: PixelRect) throws -> [UInt8]
   }
   ```
   CPU only (deterministic, exact hand-computable results; no Metal needed, so Rotate / Zoom works even when `AppModel.coreImageBridge` is nil). `Resampler.resample` already parallelizes in 256-row bands; the runner's `maxConcurrentChunks` (default 2) applies unchanged. Checks nothing on the main actor; `Sendable`.

### Platform glue (AppKit/SwiftUI; hosted tests, UI tests, manual checks)

6. **`PaintDotMac/App/MainMenu.swift`** (extend 0024/0025/0030): in the Layers menu, directly after **Import From File…** (0030) and before the separator that precedes Go to Layer Above, insert (Paint.NET order):

   | Item title | Key | Action | Identifier |
   |---|---|---|---|
   | *separator* | | | |
   | Flip Horizontal | none | `flipLayerHorizontal(_:)` | `menu.layers.flipHorizontal` |
   | Flip Vertical | none | `flipLayerVertical(_:)` | `menu.layers.flipVertical` |
   | Rotate 180° | none | `rotateLayer180(_:)` | `menu.layers.rotate180` |
   | Rotate / Zoom… | none | `rotateZoomLayer(_:)` | `menu.layers.rotateZoom` |

   Target nil (responder chain). Titles from `LayerFlipKind.menuTitle` and `LayerRotateZoom().menuTitle` ("Rotate / Zoom…", U+2026). The full Layers menu becomes: Add New Layer ⇧⌘N, Delete Layer ⇧⌘⌫, Duplicate Layer ⇧⌘D, Merge Layer Down ⌘E, Import From File…, separator, Flip Horizontal, Flip Vertical, Rotate 180°, Rotate / Zoom…, separator, Go to Layer Above, Go to Layer Below, separator, Move Layer Up, Move Layer Down, separator, Layer Properties… (Go to Layer Above ⌥⇞ and Go to Layer Below ⌥⇟ keep 0045's bindings; Layer Properties… has none). Update `MainMenuTests.layersMenuItems` to that exact list.

7. **`PaintDotMac/Core/Shortcuts/ShortcutTable.swift`** (extend 0045): change the `layers.rotateZoom` row to `menuItemIdentifier: "menu.layers.rotateZoom"`, bindings `[]`, status `.notMapped(reason: "⇧⌘Z is Redo.")`, `paintNET: "Ctrl + Shift + Z"`, notes `""`. No rows for the three other items (no shortcut in Paint.NET or here). Regenerate `docs/shortcuts.md` with `RECORD_SHORTCUT_DOCS=1` (0045's `ShortcutDocsTests`), then run again without it. Update the `layers.rotateZoom` row in 0045's `ShortcutTableTests.everyRowLiteral` literal (menu identifier `menu.layers.rotateZoom`, status `notMapped`).

8. **`PaintDotMac/Document/DocumentWindowController.swift`** (extend):
   - Three `@objc` actions `flipLayerHorizontal(_:)`, `flipLayerVertical(_:)`, `rotateLayer180(_:)` → `Self.runLayerFlip(kind, bridge: undoBridge, gestureInProgress: AppModel.shared.dispatcher.isGestureInProgress, isBusy: undoBridge.isBusy, hasSheet: window?.attachedSheet != nil)`.
   - `@MainActor static func runLayerFlip(_ kind: LayerFlipKind, bridge: UndoBridge, gestureInProgress: Bool, isBusy: Bool, hasSheet: Bool)` (0037's static-driver pattern): if `!ImageCommandRule.isEnabled(hasDocument: true, isGestureInProgress:, isBusy:, hasSheet:)` → return (no `prepareForNavigation`); `bridge.prepareForNavigation?()` ("Finish Pixels" first); `if let item = LayerFlipRotate.makeHistoryItem(for: bridge.state, kind) { bridge.perform(item) }`. Synchronous on the main actor (a permutation of one layer; see Performance).
   - `@objc func rotateZoomLayer(_:)`: same guards; `undoBridge.prepareForNavigation?()`; `values = EffectParameterValues.defaults(for: effect.parameters, colors: AppModel.shared.colors, seed: 0)` — **always the defaults**, never `effectMemory.initialValues` (Open question 4); create `EffectSessionController(effect: LayerRotateZoom(), initialValues: values, bridge: undoBridge, runner: AppModel.shared.makeLayerEffectRunner(), …)` and present `EffectDialogView` as a sheet exactly as `runEffect(_:)` does for dialog effects (sheet, `start()`, OK → `ok()` + 0.5 s progress-sheet rule, Cancel/Escape → `cancel()`, error alert "The effect couldn’t be applied." with informative text "Rotate / Zoom"). On `.done`: **no** `effectMemory.remember` and **no** `recordApplied` — Rotate / Zoom never becomes the ⌘F Repeat target and doesn't change the Repeat title.
   - Refactor: extract the sheet/progress/finish part of 0031's `runEffect(_:)` into `private func presentEffectSession(_ effect: any ImageEffect, initialValues: EffectParameterValues, runner: EffectRunner, onDone: @escaping (EffectParameterValues) -> Void)`; `runEffect` passes its existing remember/recordApplied as `onDone`; `rotateZoomLayer` passes `{ _ in }`. Behavior of `runEffect` unchanged (its tests stay green).
   - `validateMenuItem`: the four actions are enabled iff `ImageCommandRule.isEnabled(hasDocument: true, isGestureInProgress: …, isBusy: undoBridge.isBusy, hasSheet: window?.attachedSheet != nil)`; they need no selection, and Rotate / Zoom does not need `coreImageBridge`.
   - `onStateChange`: no change. Flip steps report `.pixels` (canvas, Layers-panel thumbnail and composite refresh through generation tracking); the Rotate / Zoom preview uses the session's `updateLiveState` path (0031).

9. **`PaintDotMac/App/AppModel.swift`** (extend 0031 item 14): `func makeLayerEffectRunner() -> EffectRunner { EffectRunner(renderer: LayerRotateZoomRenderer()) }`.

10. **`EffectDialogView`** — no code change: the dialog is generated from the schema (`.angle` slider + field, 0042's `OffsetControl` for `pan` with its canvas thumbnail pad, `.double` slider + field for `zoom`, pop-up for `sampling`). Identifiers used by tests: `effectDialog`, `effectDialog.angle`, `effectDialog.angle.field`, `effectDialog.pan`, `effectDialog.pan.pad`, `effectDialog.pan.x.field`, `effectDialog.pan.y.field`, `effectDialog.zoom`, `effectDialog.zoom.field`, `effectDialog.sampling`, `effectDialog.ok`, `effectDialog.cancel`. Shift-constrained 15° dragging of a roll ring is not part of this spec (no ring control; Open question 1).

11. **`project.yml`**: no target changes; new files are picked up by the source globs. Run `xcodegen generate`. New files: `Core/Operations/LayerFlipRotate.swift`, `Core/Effects/Layer/LayerRotateZoom.swift`, `Core/Effects/Layer/LayerRotateZoomRenderer.swift`, and the tests below.

12. **PRD:** no edit in this spec (sub-agent rule). When the open questions are answered, the batch owner records the answers in PRD §5.4 (L-7 detail) and §12, and adds "Rotate / Zoom — Ctrl+Shift+Z — none (⇧⌘Z is Redo)" to §5.12.

### Performance (no NF target for L-7; NF-4 history memory applies)
- Flip: one layer's permutation (0037's code path); a flip step costs that layer's changed tiles (before + after).
- Rotate / Zoom: CPU resampling of every affected tile, chunked and cancellable; the preview shows visible tiles first (0031 priority order). Targets in the Debug test build, 4000×3000 opaque seeded-noise layer, no selection, angle 30, zoom 1.1: full render through `EffectRunner` with `LayerRotateZoomRenderer` — bilinear < 1.5 s (gate 4.5 s), bicubic < 3 s (gate 9 s), nearest < 1 s (gate 3 s); `LayerFlipRotate.makeHistoryItem(.flipHorizontal)` < 200 ms (gate 600 ms). Report measured numbers in the Verification status.

## Acceptance criteria

- [ ] The Layers menu contains, after Import From File… and before Go to Layer Above, a separator then **Flip Horizontal**, **Flip Vertical**, **Rotate 180°**, **Rotate / Zoom…**, none with a key equivalent, with the stated actions and identifiers. → `MainMenuTests.layersMenuItems`, `MainMenuShortcutTests.everyItemMatchesTable` (0045); UI `LayerFlipRotateZoomUITests.testLayersMenuItems`
- [ ] Rotate / Zoom has no shortcut; the shortcut table row points at `menu.layers.rotateZoom` with "⇧⌘Z is Redo."; `docs/shortcuts.md` matches the table; ⇧⌘Z still performs Redo. → `ShortcutTableTests.layerRotateZoomNotMapped`, `.everyRowLiteral` (updated), `ShortcutDocsTests.docsFileMatchesTable` (0045); UI `testFlipHorizontalUndoRedo` (⇧⌘Z redoes)
- [ ] The four items are enabled with an open document (with or without a selection, any layer count) and disabled mid-gesture, while busy, or with a sheet (e.g. the Rotate / Zoom dialog) attached; disabled invocations do nothing. → `LayerFlipCommandTests.ignoredWhenDisabled`, `ImageCommandRuleTests.enablement` (0035); UI `testLayersMenuItems`
- [ ] Flip Horizontal / Flip Vertical / Rotate 180° permute the active layer's pixels exactly (hand-computed 3×2), canvas size unchanged, colour under alpha 0 preserved, no resampling. → `LayerFlipRotateTests.flipHorizontal3x2`, `.flipVertical3x2`, `.rotate180_3x2`, `.keepsColorUnderZeroAlpha`, `.sizeUnchanged`
- [ ] Only the active layer changes: other layers' tiles share storage; layer properties, active index, DPI, and the selection are unchanged; a hidden active layer is flipped too. → `LayerFlipRotateTests.onlyActiveLayerChanges`, `.selectionIgnoredAndKept`, `.hiddenActiveLayerFlipped`
- [ ] Each flip is one history step named "Flip Layer Horizontal" / "Flip Layer Vertical" / "Rotate Layer 180°" (icon `.flipRotate`, change `.pixels`); undo restores the layer exactly (tile storage shared with the original), redo restores the flipped tiles; undo after switching layers does not switch layers; a flip that changes nothing adds no step. → `LayerFlipRotateTests.historyNamesAndIcon`, `.noOpAddsNoStep`, `LayerFlipIntegrationTests.undoRedoRoundTrip`, `.undoDoesNotSwitchLayers`; UI `testFlipHorizontalUndoRedo`, `testFlipVerticalThenRotate180`
- [ ] Flip identities hold on the active layer: flipH∘flipH = flipV∘flipV = rotate180∘rotate180 = identity; rotate180 = flipH∘flipV. → `LayerFlipRotatePropertyTests.*`
- [ ] Floating pixels / pending edits are finished first ("Finish Pixels" precedes the layer step) for all four commands. → `LayerFlipCommandTests.commitsPendingEditFirst`, `LayerRotateZoomSessionTests.commitsPendingEditFirst`
- [ ] Rotate / Zoom's schema is Angle (−180…180, 0), Pan (offset, (0,0)), Zoom (0.06…16, 1.00), Sampling (Bilinear default, Bicubic, Nearest Neighbor); the dialog is the generated `EffectDialogView` titled "Rotate / Zoom" and always opens with the defaults. → `LayerRotateZoomTests.metadataAndSchema`, `.schemaValidates`, `LayerRotateZoomSessionTests.opensWithDefaults`; UI `testRotateZoomDialogAppliesAngle`
- [ ] Rotation and zoom are about the canvas centre (selection-bounds centre with a selection), positive angle = counter-clockwise, pan moves the pivot to `EffectOffset.point(in: bounds)`, uncovered areas are transparent, and content moved off-canvas is discarded. → `LayerRotateZoomTests.transformMatrix90`, `.transformMatrixGeneral`, `.cosSinExactRightAngles`, `.rotate90Square`, `.rotateMinus90Square`, `.rotate180Square`, `.rotate90NonSquareLosesCorners`, `.panShiftsContent`, `.zoomHalfNearest`, `.selectionPivot`
- [ ] 90°/180° rotations are exact in all three sampling modes when the pivot lands on pixel centres; zoom 2× gives the hand-computed bilinear, bicubic, and nearest values; bilinear/bicubic premultiply and never bleed colour from alpha-0 pixels. → `LayerRotateZoomTests.rightAnglesExactAllModes`, `.zoom2xRamp`, `.zoom2xNearest`, `.zoom2xStepEdgeBilinearVsBicubic`, `.rotate90ParityMismatchBilinear`, `.noBleedFromTransparent`
- [ ] The identity (angle 0, zoom 1, pan 0) is `.noChange`: OK adds no step and pixels are untouched. → `LayerRotateZoomTests.identityIsNoChange`, `LayerRotateZoomSessionTests.identityOkAddsNoStep`
- [ ] With a selection, only selected pixels change (antialiased edges blended by coverage) and pixels outside are byte-identical. → `LayerRotateZoomTests.selectionPivot`, `LayerRotateZoomSessionTests.selectionClippedApply`; UI `testRotateZoomRespectsSelection`
- [ ] While the dialog is open the canvas shows a live preview of the active layer and no history step exists; OK records one step "Rotate / Zoom Layer" (icon `.flipRotate`) on the active layer only; Cancel restores every tile exactly (shared storage), adds no step, and clears `isBusy`; undo/redo of the step are exact. → `LayerRotateZoomSessionTests.previewWithoutStep`, `.okRecordsOneStep`, `.cancelRestoresExactly`, `.undoRedoExact`, `.onlyActiveLayerChanges`; UI `testRotateZoomDialogAppliesAngle`, `testRotateZoomCancelRestores`
- [ ] Rotate / Zoom never becomes the ⌘F Repeat target and never changes remembered effect values; existing effects keep their history names. → `LayerRotateZoomSessionTests.notRecordedForRepeat`, `EffectSessionTests.historyNameDefaultsToName`
- [ ] `.layer` effects never appear in the Adjustments or Effects menus. → `EffectRegistryTests.layerCategoryExcluded`, `MainMenuTests.effectMenusUnchanged`
- [ ] Performance targets met within the 3× gate. → `LayerRotateZoomPerformanceTests.*`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

- [ ] The Rotate / Zoom dialog (a `.layer` effect, not in `EffectRegistry.standard`, so 0049's `registryEffectsAllCatalogued` doesn't cover it) has catalog entries generated with 0049's `effectDialogEntries(for: LayerRotateZoom())` and a keyboard plan like other effect dialogs. → `AccessibilityCatalogTests.layerRotateZoomDialogCatalogued`, `AccessibilityAuditUITests.testRotateZoomDialog`

## Edge cases

- **1×1 layer:** every flip is the identity → no step. **W×1:** Flip Vertical is the identity (no step); **1×H:** Flip Horizontal is the identity. → `LayerFlipRotateTests.noOpAddsNoStep`
- **Symmetric content / empty (no tiles) layer / uniformly filled layer:** empty diff → no step; Rotate / Zoom of an empty layer renders all-zero tiles → empty diff → no step. → `.noOpAddsNoStep`, `LayerRotateZoomSessionTests.emptyLayerAddsNoStep`
- **Sizes across tile seams** (600×300, 257×1, 512×512): flips match 0037's per-pixel map on the active layer; edge padding zero. → `LayerFlipRotateTests.matchesOracleAcrossSeams`
- **Semi-transparent and alpha-0 pixels:** flips move bytes unchanged; resampling premultiplies (no colour bleed), alpha-0 results are `(0,0,0,0)`. → `.keepsColorUnderZeroAlpha`, `LayerRotateZoomTests.noBleedFromTransparent`
- **Rotation by 90° when W − H is odd** (pivot on a pixel edge in one axis): samples fall between pixels; bilinear averages (hand-computed), not an error. → `.rotate90ParityMismatchBilinear`
- **Angle ±180:** both give the same exact result. → `LayerRotateZoomTests.cosSinExactRightAngles`, `.rotate180Square` (run with 180 and −180)
- **Zoom extremes:** 0.06 shrinks the layer to a few pixels around the pivot (rest transparent); 16 shows 1/16 of the area magnified; out-of-range text in the field reverts/clamps through 0031/0032 normalization. → `LayerRotateZoomTests.zoomExtremes` (0.06 on a 100×100 opaque layer: pixels farther than 4 px from the centre in both axes are transparent; 16 on a 2-colour split layer: the centre pixel colour equals the source centre colour), `EffectParameterTests` (0031) normalization
- **Pan extremes:** (1, 1) moves the pivot to the bounds' bottom-right corner; content beyond the canvas is discarded. → `.panShiftsContent` (includes x = 1 on a 4×4: target x = 4 → shift +2 px)
- **Selection:** antialiased ellipse → coverage blend; selection touching the canvas edge → pivot = its bounds centre; a selection entirely in one tile → only that tile rendered. → `LayerRotateZoomSessionTests.selectionClippedApply`, `.selectionPivot`
- **Hidden active layer:** both commands run (the effect isn't visible until shown). → `.hiddenActiveLayerFlipped`, `LayerRotateZoomSessionTests.hiddenActiveLayer`
- **Floating pixels present:** "Finish Pixels" first, then the step. → `commitsPendingEditFirst` (both)
- **Mid-gesture / busy (another effect running) / sheet attached:** menu items disabled, no step. → `LayerFlipCommandTests.ignoredWhenDisabled`
- **Closing the window while the dialog's render runs:** 0031's close path (`controller.cancel()` first) applies unchanged. → covered by 0031's `EffectSessionTests` (no new code)
- **Cancel during the progress sheet after OK:** restores exactly. → `LayerRotateZoomSessionTests.cancelWhileFinishing`
- **Undo budget (H-5):** steps are ordinary tile diffs; no special case.
- **GPU unavailable:** Rotate / Zoom still works (CPU renderer); flips never need the GPU. → `LayerFlipCommandTests` and `LayerRotateZoomSessionTests` run with no `CoreImageBridge`

## Test plan

Expected values below are derived by hand from the formulas above (never by running the code under test).

**Flip fixture (3×2, active layer):**
```
row 0: a b c
row 1: d e f
```
`a = (10,0,0,255)`, `b = (20,0,0,255)`, `c = (30,0,0,255)`, `d = (40,0,0,255)`, `e = (50,0,0,128)`, `f = (60,70,80,0)` (alpha 0 with colour, D-33).

- **Unit — `PaintDotMacTests/Operations/LayerFlipRotateTests.swift`:**
  - `flipHorizontal3x2` → `[c b a / f e d]`; `flipVertical3x2` → `[d e f / a b c]`; `rotate180_3x2` → `[f e d / c b a]`, each read back with `readPixels` after `UndoBridge`-free `diff.apply`.
  - `keepsColorUnderZeroAlpha`: after flipH, pixel (0,1) is exactly `(60,70,80,0)`.
  - `sizeUnchanged`: image size and DPI equal before/after for all three kinds.
  - `onlyActiveLayerChanges`: 3 layers (bottom opaque white, middle = fixture as active index 1, top seeded noise); after each kind every tile of layers 0 and 2 `sharesStorage` with the original; the diff's `changedTiles.keys == [middle.id]`; `activeLayerIndex == 1`; ids/names/visibility/opacity 77/blend mode `.multiply` of the active layer unchanged.
  - `selectionIgnoredAndKept`: rect selection (0,0,1,1) on the 3×2 fixture → flipH result is the full `[c b a / f e d]`; `after.selection` equals `before.selection` (mask equality).
  - `hiddenActiveLayerFlipped`: active layer `isVisible = false` → item non-nil, pixels flipped.
  - `historyNamesAndIcon`: `LayerFlipKind.allCases.map(\.historyName) == ["Flip Layer Horizontal", "Flip Layer Vertical", "Rotate Layer 180°"]`, `menuTitle`s `["Flip Horizontal", "Flip Vertical", "Rotate 180°"]`, `imageKind`s `[.flipHorizontal, .flipVertical, .rotate180]`; item `name`, `icon == .flipRotate`, `change == .pixels`.
  - `noOpAddsNoStep`: 1×1 layer (all kinds) → nil; 3×1 flipV → nil; 1×3 flipH → nil; empty layer → nil; 4×4 uniformly red (`fill`) → nil for all kinds; a horizontally symmetric 3×1 `[a b a]` flipH → nil.
  - `matchesOracleAcrossSeams`: sizes 600×300, 257×1, 1×257, 512×512, seeded random content (`SeededRandom`, seed printed) → result equals a naive per-pixel oracle written in the test (`out(x,y) = src(W−1−x, y)` / `src(x, H−1−y)` / `src(W−1−x, H−1−y)`); padding outside the canvas in edge tiles is zero.
- **Property — `PaintDotMacTests/Operations/LayerFlipRotatePropertyTests.swift`** (20 seeded 37×23 two-layer images): applying flipH twice, flipV twice, rotate180 twice yields pixels equal to the original; flipH then flipV equals rotate180; other layer untouched in all cases.
- **Hosted — `PaintDotMacTests/Document/LayerFlipCommandTests.swift`** (real `UndoBridge`, `groupsByEvent = false`):
  - `ignoredWhenDisabled`: `runLayerFlip(.flipHorizontal, …)` with `gestureInProgress: true`, then `isBusy: true`, then `hasSheet: true` → no step, `prepareForNavigation` not called (counting closure), pixels unchanged.
  - `commitsPendingEditFirst`: rect selection, 0020 Move Selected Pixels drag (+1, 0) → floating; `runLayerFlip(.flipVertical, …)` → last step names `["Move Pixels", "Finish Pixels", "Flip Layer Vertical"]`, `floatingPixels == nil`.
- **Integration — `PaintDotMacTests/Document/LayerFlipIntegrationTests.swift`:**
  - `undoRedoRoundTrip`: 2 layers, active 1 = fixture; flipH → undo → every tile of layer 1 `sharesStorage` with the original and pixels `[a b c / d e f]`; redo → `[c b a / f e d]`; History list names end with "Flip Layer Horizontal"; document edited after flip, clean after undo.
  - `undoDoesNotSwitchLayers`: flip layer 1, `LayerCommandRunner.goTo(.below)` (active 0), undo → layer 1 restored, `activeLayerIndex == 0`.
- **Unit — `PaintDotMacTests/Effects/LayerRotateZoomTests.swift`** (renders through `LayerRotateZoom.render` after `prepare`; helper `run(_ surface, angle:, pan:, zoom:, mode:, selection:)` returns the full-canvas pixels; colours `src(x,y)` on 4×4 = `(10 + 40x, 10 + 40y, 7, 255)` unless stated):
  - `metadataAndSchema`: id "layerRotateZoom", name "Rotate / Zoom", `menuTitle == "Rotate / Zoom…"`, `historyName == "Rotate / Zoom Layer"`, category `.layer`, icon `.flipRotate`, parameter ids `["angle","pan","zoom","sampling"]`, labels `["Angle","Pan","Zoom","Sampling"]`, kinds/ranges/defaults exactly as the table, sampling options `[("bilinear","Bilinear"),("bicubic","Bicubic"),("nearestNeighbor","Nearest Neighbor")]`. `schemaValidates`: `EffectSchemaValidator` reports nothing. `makeOutputThrows`: `makeOutput` throws `.renderFailed`.
  - `cosSinExactRightAngles`: 0 → (1,0); 90 → (0,1); −90 → (0,−1); 180 and −180 → (−1,0) — all `==` exact; 30 → (cos 30°, sin 30°) within 1e-15.
  - `transformMatrix90`: canvas 4×4, angle 90, zoom 1, pivot = target = (2,2) → exactly `CGAffineTransform(a: 0, b: −1, c: 1, d: 0, tx: 0, ty: 4)` (hand: point (4,0) ↦ (0,0)). `transformMatrixGeneral`: angle 30, zoom 2, pivot (5,3), target (6,1) → a = 2·cos30 = 1.7320508…, b = −1, c = 1, d = 1.7320508…, tx = 6 − (1.7320508·5 + 1·3) = −5.660254…, ty = 1 − (−1·5 + 1.7320508·3) = 0.803848… (within 1e-12).
  - `rotate90Square` (angle 90, all three modes): `out(x,y) == src(3−y, x)` for every pixel (counter-clockwise: source top-right → destination top-left); also equals 0037's `FlipRotateKind.rotate90CounterClockwise.sourcePixel` mapping. `rotateMinus90Square`: `out(x,y) == src(y, 3−x)`. `rotate180Square` (180 and −180): `out(x,y) == src(3−x, 3−y)`. `rightAnglesExactAllModes`: the same three with one source pixel `(200,100,50,128)` → the moved pixel is exactly `(200,100,50,128)` in bilinear and bicubic.
  - `rotate90NonSquareLosesCorners`: 4×2 canvas (pivot (2,1)), `src(x,y) = (10 + 40x, 10 + 100y, 7, 255)`, angle 90, nearest and bilinear → `out(1,0) = src(2,0)`, `out(2,0) = src(2,1)`, `out(1,1) = src(1,0)`, `out(2,1) = src(1,1)`; columns 0 and 3 are `(0,0,0,0)` (hand: destination centre (x+.5, y+.5) ↦ source (2.5 − y, x − 0.5)).
  - `rotate90ParityMismatchBilinear`: 3×2 opaque gray, row 0 `[0, 40, 80]`, row 1 `[120, 160, 200]`, angle 90, bilinear (pivot (1.5, 1); destination centre ↦ source (2 − y, x)) → `out(1,0) = (120,120,120,255)` (mean of 40, 80, 160, 200); `out(1,1) = (80,80,80,255)` (mean of 0, 40, 120, 160); `out(0,0) = (60,60,60,128)` (two inside taps of weight 0.25: A = 127.5 → 128, colour (40+80)/2 = 60).
  - `panShiftsContent` (angle 0, zoom 1, nearest and bilinear): pan (0.5, 0) → target (3, 2) → `out(x,y) = src(x−1, y)`, column 0 transparent; pan (0, −0.5) → `out(x,y) = src(x, y+1)`, row 3 transparent; pan (1, 0) → shift +2 px, columns 0–1 transparent.
  - `zoomHalfNearest`: 4×4, zoom 0.5, nearest (source = 2x − 1 per axis) → `out(1,1) = src(1,1)`, `out(2,1) = src(3,1)`, `out(1,2) = src(1,3)`, `out(2,2) = src(3,3)`, all 12 other pixels `(0,0,0,0)`.
  - `zoom2xRamp`: 8×8 opaque gray, every row `v(x) = 20x` (`[0,20,…,140]`), zoom 2 (source x = 2.25 + x/2): bilinear and bicubic both give, for x, y ∈ 2…5, gray `[55, 65, 75, 85]` across x (linear functions are reproduced exactly by both kernels), alpha 255. `zoom2xNearest`: row values for x = 0…7 → `[40,40,60,60,80,80,100,100]`.
  - `zoom2xStepEdgeBilinearVsBicubic`: 8×8 opaque gray, columns 0–3 = 0, 4–7 = 255, zoom 2; rows y ∈ 2…5: x = 3 → bilinear 64 (63.75), bicubic 52 (51.796875); x = 4 → bilinear 191 (191.25), bicubic 203 (203.203125); x = 2 → 0 in both; x = 5 → 255 in both (hand: Keys a = −0.5 weights −0.0703125, 0.8671875, 0.2265625, −0.0234375 at u = 3.25; mirrored at u = 3.75; same numbers as 0035's `bicubicOvershootClamped`).
  - `noBleedFromTransparent`: 2×2 with left column `(255,0,0,255)` and right column `(0,0,255,0)`, zoom 2, bilinear → every non-transparent output pixel has blue 0 and red 255.
  - `selectionPivot`: 8×8, `src(x,y) = (10 + 30x, 10 + 30y, 7, 255)`, rect selection (4,0,4,4), angle 180, nearest, rendered through `EffectRunner` with `LayerRotateZoomRenderer` → inside the selection `out(x,y) = src(11 − x, 3 − y)` (pivot (6,2)); every pixel outside the selection equals `src(x,y)`; tiles outside the mask not rendered.
  - `identityIsNoChange`: angle 0, zoom 1, pan zero, with and without selection → `prepare` returns `.noChange`; angle 0.01 → `.render`.
  - `zoomExtremes`: as in Edge cases.
- **Unit — `PaintDotMacTests/Effects/EffectRegistryTests.swift`** (extend 0031): `layerCategoryExcluded` — `EffectRegistry.standard` contains no `.layer` effect; a registry built with a test-only `.layer` stub in Release-style mode (assertions off is not testable, so build the filters directly) → `adjustments` and `effectSubmenus` exclude it; `EffectCategory.allCases.last == .layer`, `menuTitle == "Layers"`.
- **Unit — `PaintDotMacTests/Shortcuts/ShortcutTableTests.swift`** (extend 0045): `layerRotateZoomNotMapped` — `entry(menuItemIdentifier: "menu.layers.rotateZoom")?.bindings == []`, status `.notMapped(reason: "⇧⌘Z is Redo.")`, `paintNET == "Ctrl + Shift + Z"`; `menuChord(forMenuItem: "menu.edit.redo")` is still ⇧⌘Z.
- **Hosted integration — `PaintDotMacTests/Document/LayerRotateZoomSessionTests.swift`** (real `UndoBridge`; `EffectSessionController` with `runner: EffectRunner(renderer: LayerRotateZoomRenderer())`, `debounce: .zero`; awaits `isRenderComplete`):
  - `opensWithDefaults`: the values `rotateZoomLayer` uses (factored as `static func initialRotateZoomValues(colors:)`) equal the schema defaults even after `effectMemory.remember` was called with angle 45 for that effect id.
  - `previewWithoutStep`: 2 layers, active 1 = 4×4 fixture; start, `update("angle", .angle(90))` → live layer 1 pixels equal `src(3−y, x)`, layer 0 tiles share storage, history unchanged, `isBusy == true`.
  - `okRecordsOneStep`: then `ok()` → exactly one new step "Rotate / Zoom Layer", icon `.flipRotate`, diff keyed only by layer 1, `isBusy == false`.
  - `undoRedoExact`: undo → layer 1 tiles share storage with the original; redo → rotated pixels.
  - `cancelRestoresExactly`: start, update angle 30 and zoom 1.5, wait for a render, `cancel()` → every tile shares storage with `before`, no step, `phase == .cancelled`, `isBusy == false`. `cancelWhileFinishing`: 2048×2048 seeded layer, `ok()` then `cancel()` after the first progress callback → same assertions.
  - `onlyActiveLayerChanges`: layers 0 and 2 untouched after OK (storage shared).
  - `identityOkAddsNoStep`: start, `ok()` with defaults → no step, pixels storage-shared.
  - `emptyLayerAddsNoStep`: active layer with no tiles, angle 45 → OK → no step.
  - `selectionClippedApply`: antialiased ellipse selection on an 8×8 layer, angle 180 → fully selected pixels equal the oracle of `selectionPivot`-style mapping with the ellipse bounds' centre, unselected pixels byte-identical, partial-coverage pixels equal 0031's `MaskBlendReference.apply(original:effect:mask:)` within ±1.
  - `hiddenActiveLayer`: active layer hidden → step recorded, pixels transformed.
  - `commitsPendingEditFirst`: floating pixels → driving `rotateZoomLayer`'s factored entry point (`static func beginRotateZoom(bridge:…) -> EffectSessionController?`, used by the action) records "Finish Pixels" before the session starts.
  - `notRecordedForRepeat`: after OK, `AppModel`'s `effectMemory.lastApplied` is unchanged (nil, or the previous effect) and `effectMemory.initialValues(for: LayerRotateZoom(), …)` still returns defaults.
- **Unit — `PaintDotMacTests/Effects/EffectSessionTests.swift`** (extend 0031): `historyNameDefaultsToName` — Invert Colors' step is named "Invert Colors"; a stub effect with `historyName` "X Layer" records "X Layer".
- **Menu — `PaintDotMacTests/App/MainMenuTests.swift`** (extend): `layersMenuItems` exact list (item 6) with identifiers and empty key equivalents for the four new items; `effectMenusUnchanged` — Adjustments and Effects menus contain no item titled "Rotate / Zoom…".
- **Performance — `PaintDotMacTests/Performance/LayerRotateZoomPerformanceTests.swift`** (XCTest `measure`): the targets in *Performance*; gate at 3×.
- **UI tests — `PaintDotMacUITests/LayerFlipRotateZoomUITests.swift`** (fixture generated at test time with `UITestFixtures.writePNG`: 200×200 opaque, quadrants top-left red `(255,0,0)`, top-right green `(0,255,0)`, bottom-left blue `(0,0,255)`, bottom-right white; `UITestApp` launch; History panel shown with ⌥⌘2; pixel checks by ⌘S over the fixture and decoding with ImageIO):
  - `testLayersMenuItems`: the Layers menu shows the full list of item 6 in order; Flip Horizontal, Flip Vertical, Rotate 180°, Rotate / Zoom… enabled; none shows a key equivalent.
  - `testFlipHorizontalUndoRedo`: Layers ▸ Flip Horizontal → last `historyRow` "Flip Layer Horizontal"; ⌘Z → row gone; ⇧⌘Z → row back; ⌘S → (10,10) green, (190,10) red, (10,190) white, (99,10) green, (100,10) red; `statusBar.imageSize` unchanged "200 × 200".
  - `testFlipVerticalThenRotate180`: Flip Vertical → (10,10) blue after save; then Rotate 180° → rows "Flip Layer Vertical", "Rotate Layer 180°"; saved (10,10) green (flipV then 180° = flipH).
  - `testRotateZoomDialogAppliesAngle`: Layers ▸ Rotate / Zoom… → `effectDialog` appears with title "Rotate / Zoom"; `effectDialog.angle.field` shows "0.00", `effectDialog.zoom.field` "1.00", `effectDialog.sampling` "Bilinear"; type `90` + Return in `effectDialog.angle.field`; while the sheet is open the History row count is unchanged; `effectDialog.ok` → last row "Rotate / Zoom Layer"; ⌘S → (10,10) green, (190,190) blue, (190,10) white, (10,190) red.
  - `testRotateZoomCancelRestores`: Flip Horizontal (so the document is edited), Rotate / Zoom…, angle 45 + Return, zoom 0.5 + Return, wait 1 s, `effectDialog.cancel` → History row count unchanged since the flip; ⌘S → pixels equal the flipped image exactly at (10,10), (99,10), (100,10), (190,190), (0,0), (199,199).
  - `testRotateZoomPanAndZoom`: Rotate / Zoom…, zoom 0.5 + Return, `effectDialog.pan.x.field` 0.5 + Return (target x = 150), OK → ⌘S → (5,5) alpha 0; (110,60) red (source x = 2(110.5 − 150) + 100 = 21, y = 2(60.5 − 100) + 100 = 21); (190,60) green (source x = 181); (60,60) alpha 0 (source x = −79, outside).
  - `testRotateZoomRespectsSelection`: launch with `-UITestSelectRect 50,0,100,100`; Rotate / Zoom…, angle 180 + Return, OK → ⌘S → (60,10) green, (140,10) red (pivot (100,50): (x,y) ← (199 − x, 99 − y)); outside the selection (10,10) red, (190,10) green, (60,150) blue unchanged.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification** (look and feel only):
  1. Open a photo, add a layer, paint on it, Layers ▸ Rotate / Zoom…: drag Angle — the canvas follows smoothly, visible area first; the pan pad shows a thumbnail of the layer; dragging the pad crosshair moves the layer; Zoom slider enlarges/shrinks about the centre. Expected: no flicker back to the original between updates; other layers stay still.
  2. Pick Bicubic vs Nearest Neighbor at angle 30, zoom 3: Nearest shows hard pixel edges, Bicubic is smooth with no colour fringes on transparent edges.
  3. With a large (6000×4000) layer, click OK while the preview is still rendering: the progress sheet appears after about 0.5 s and Cancel restores the layer.
  4. Dark mode: the dialog and pad render legibly.

## Open questions

1. **Which Rotate / Zoom controls?** Paint.NET 5's dialog also has a 3-D roll (Tilt 0–90°, Direction −180…180), Quality (supersampling), and Tiling (None / Repeat / Mirror); its pan offset range is ±10 (API) and Sampling offers Bilinear and Nearest Neighbor. **Recommended (applied):** Angle −180…180 (default 0), Pan as 0042's offset pad ±1 of the reference bounds (the pivot can move to the bounds' edge), Zoom 0.06…16 (default 1), Sampling Bilinear (default) / Bicubic / Nearest Neighbor; Tiling fixed to None (transparent); no Tilt/Direction, no Quality, no Shift-15° ring.
2. **Selection behavior.** Paint.NET's Layers docs say the commands affect the active layer and say nothing about selections. **Recommended (applied):** Flip Horizontal / Flip Vertical / Rotate 180° ignore the selection and permute the whole layer (selection unchanged); Rotate / Zoom works like an effect: it samples the whole layer, pivots on the selection's bounding-box centre (canvas centre without a selection), and changes only selected pixels (FX-D coverage blend).
3. **Names, and including Rotate 180°.** Paint.NET's Layers menu has Rotate 180° next to the flips; L-7 says "rotate". History names aren't in the docs. **Recommended (applied):** include Layers ▸ Rotate 180° (no shortcut); menu titles "Flip Horizontal", "Flip Vertical", "Rotate 180°", "Rotate / Zoom…"; history steps "Flip Layer Horizontal", "Flip Layer Vertical", "Rotate Layer 180°", "Rotate / Zoom Layer"; dialog title "Rotate / Zoom".
4. **Dialog memory and Repeat.** **Recommended (applied):** the Rotate / Zoom dialog always opens at the defaults (a remembered 30° would compound on the next use), and it is not a ⌘F Repeat target (Repeat stays for Adjustments/Effects).

## Out of scope

- Whole-image flips and 90°/180° rotations → **0037**. Layer 90° rotations (not in Paint.NET's Layers menu; they would change the canvas aspect).
- Tilt/Direction 3-D roll, Quality supersampling, Repeat/Mirror tiling, a roll-ring control with Shift-15° snapping (Open question 1).
- A keyboard shortcut for Rotate / Zoom (⇧⌘Z is Redo; 0045 Q6).
- Toggle Layer Visibility, Go to Top/Bottom Layer, Move Layer to Top/Bottom menu items (0045 Q5).
- On-canvas handles for layer rotate/zoom (the dialog is the Paint.NET UI; on-canvas transforms are Move Selected Pixels, 0020).
- PRD edits (batch owner, after the open questions are answered).
