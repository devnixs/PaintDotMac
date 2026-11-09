# 0056 — Add the Clone Stamp tool (L): ⌥-click sets the source, drag paints copied pixels

> Source: PRD.md §5.3 T-15 (P1: "Clone Stamp | L | Option-click sets the source (Paint.NET uses Ctrl-click)"), TOOL-A (left = primary, right/⌃-left = secondary), TOOL-B (clipped to the selection), TOOL-C (options persist), TOOL-D (pressure, via 0055), §5.12 (Ctrl → ⌥ for this gesture; tool key L), §12 D-14 (pressure P1), D-15 (brush blend list = implemented layer blend modes), D-35 (tool-key cycling), D-38 (continuous strokes, no Spacing/Smoothing options, brush-outline cursor), H-6 / D-34 (no-op edits add no step), §6 NF-1 (brush latency).
> Paint.NET: https://paint.net/doc/latest/CloneStamp.html — "Set the source point by holding down the Ctrl key and clicking on the source image."; "Repeating Ctrl + Click sequence resets the source to the newly clicked location."; "The relationship between the source and destination is fixed once the actual cloning is started."; "Once the relationship is set, the points remain locked together."; "This relationship will persist through tool changes and other editing operations."; "To break the link, set a new source point by holding down the Ctrl key and clicking at a different location."; "The source and destination can be on the same layer or different layers within the same image."; "While cloning, circles are drawn to indicate the location of the source and destination."; "Clone Stamp inherits the opacity of the Primary color if the Left mouse button is used … the Right mouse button makes the Clone Stamp inherit the opacity of the Secondary color."; "If Pressure Sensitivity is enabled, pressure on the hardware will be reflected in the size of the cloned region."; "If aliasing is selected, the Hardness setting will be ignored."; "A Blend Mode may be applied to the cloned path, much like a layer blend only specific to the tool". Toolbar (page order): Brush size, Pressure Sensitivity, Hardness, Spacing, Path Smoothing, Antialiasing, Blending mode, Selection Quality. The page lists **no** Sampling option and **no** aligned/non-aligned option.
> Paint.NET 3.36 source (`src/tools/CloneStampTool.cs`, https://github.com/wangdeshui/paint.net): Ctrl-click stores `takeFrom = (e.X, e.Y)` and the **active layer** as the source layer (`wr = new WeakReference((BitmapLayer)ActiveLayer)`); the offset persists across strokes (static data, not reset on mouse-up); if the source layer is no longer in the document the source is reset; same-layer cloning reads from `ScratchSurface` (a copy) rather than the live layer; the copied pixel's alpha is multiplied by the brush edge alpha and the color alpha; RGB comes from the source, not the color.
> Milestone: v1.x
> Depends on: 0055-tablet-pressure (and through it all of v1.0: 0006 `Tool`/`ToolContext`/`ToolOverlay`/`ToolRegistry`/`ToolDispatcher`, 0008 `TileDiffHistoryItem`/`HistoryIcon.cloneStamp`, 0009 `BrushEngine`/`BrushStroke`/`BrushOptions`/`BrushOutline`/`BrushWidthAdjustable`, 0012 `CPUCompositor`/`SamplingMode`, 0013 `paintClipMask`, 0016 `SamplingMode: ToolOptionValue`, 0026/0027 blend modes, 0045 `ShortcutTable`, 0048 brush performance, 0049 `AccessibilityCatalog`)

## Context

Today (once 0055 is built):

- `ToolID.cloneStamp` exists with descriptor row `cloneStamp | Clone Stamp | l | photo | seal | false` (`docs/specs/todo/0006-tool-framework-and-panels_TODO.md:156`), but no factory is registered in `ToolRegistry.standard()`, so L is "consumed silently" (0006 line 245, test `ToolDispatcherTests.unimplementedKeyConsumed` uses `"l"`, 0006 line 424) and the Tools panel hides it (`ToolsPanelUITests.testShowsImplementedToolsOnly` asserts `tool.cloneStamp` doesn't exist, 0006 line 470; "0056/0057 update this test").
- `HistoryIcon.cloneStamp` exists (0008 line 52) with SF Symbol `seal` (0010 line 98).
- 0045's `ShortcutTable` already has the rows `tools.l` ("Tool is P1 (0056); until then the key is consumed silently (0006).") and `cloneStamp.setSource` (⌥-click, remapped from Ctrl + Left Mouse click) (`0045-shortcut-audit_TODO.md:224`, `:257`), and 0045 line 350 pins "Unimplemented tools (L, R)".
- `BrushStroke` (0009 `Core/Tools/BrushEngine.swift`, 0009 lines 52–83; extended by 0055 with `pressureSensitivity:` and `begin/extend(…, pressure:)`) composes each pixel through `BrushCompose = (before, coverage) -> ColorRGBA8`. That closure does **not** receive the pixel position, which the Clone Stamp needs (it reads the source pixel at `(x + dx, y + dy)`).
- `BrushPressure.key(for:)` (0055) documents "0056 adds .cloneStamp, 0057 .recolor".
- `CPUCompositor.compositeTile(_:of:) -> [ColorRGBA8]?` and `SamplingMode` (`layer`/`image`, display "Layer"/"Image") exist (0012 lines 38, 46); 0016 adds `SamplingMode: ToolOptionValue`.

Missing: the tool itself, the source/offset state, position-aware compositing, the source indicator overlay, the options-bar section, and the registration.

## User story

As a PaintDotMac user retouching a photo, I press **L**, ⌥-click a clean patch of skin to set the source, then paint over a blemish: the brush copies the pixels from the source, and a crosshair circle shows where they come from, moving in lockstep with my brush. When I start a new stroke elsewhere, the source keeps the same offset until I ⌥-click a new source. Each stroke is one "Clone Stamp" history step that ⌘Z undoes.

## Scope & changes

### Core (pure Swift, unit-tested; no AppKit/SwiftUI imports)

1. **`PaintDotMac/Core/Tools/BrushEngine.swift`** (extend 0009/0055; no behavior change for existing callers):
   - Add `typealias BrushPixelCompose = @Sendable (_ x: Int, _ y: Int, _ before: ColorRGBA8, _ coverage: UInt8) -> ColorRGBA8` — like `BrushCompose` but with the pixel's canvas coordinates.
   - Add `BrushStroke.init(canvasSize: PixelSize, options: BrushOptions, clipMask: (any BrushClipMask)?, pixelCompose: @escaping BrushPixelCompose, pressureSensitivity: PressureSensitivity = .off)`. The existing `init(…, compose:, pressureSensitivity:)` becomes a convenience that wraps `compose` as `{ _, _, before, cov in compose(before, cov) }`. Everything else (coverage model, `StrokeCoverageBuffer`, clip, region, before-snapshot, `touchedTiles`, `makeTileDiff`, `cancel`) is unchanged. Thread-safety rule unchanged: `pixelCompose` may be called concurrently for different pixels (0009's `concurrentPerform` note), so it must be `@Sendable` and pure per pixel.
2. **`PaintDotMac/Core/Tools/CloneStamp.swift`** (new) — the source/offset model, the source sampler, and the compose rule:
   ```swift
   /// Per-document clone source (Paint.NET's takeFrom + source layer). Not persisted.
   struct CloneSourceState: Sendable, Equatable {
       private(set) var sourcePixel: PixelPoint?        // set by ⌥-click; nil = no source
       private(set) var sourceLayerID: Layer.ID?        // the layer active at the ⌥-click
       private(set) var offset: PixelPoint?             // source − destination, fixed at the first stroke after ⌥-click
       var hasSource: Bool { sourcePixel != nil }
       /// ⌥-click. Ignored (returns false, state unchanged) when `location` is non-finite or its pixel is outside `canvas`.
       mutating func setSource(at location: CGPoint, layerID: Layer.ID, canvas: PixelSize) -> Bool
       /// Start of a stroke at `location`. No source → nil. First stroke after setSource fixes
       /// offset = sourcePixel − floor(location); later strokes reuse it (aligned). Returns the offset.
       mutating func beginStroke(at location: CGPoint) -> PixelPoint?
       /// Clears everything when the source layer no longer exists in `image` (Paint.NET 3.36 resets too).
       mutating func validate(against image: LayeredImage)
       /// Canvas-space center of the source indicator for a pointer at `pointer`:
       /// no source → nil; offset not fixed yet → (sourcePixel.x + 0.5, sourcePixel.y + 0.5);
       /// otherwise pointer + offset (Double). Non-finite pointer → nil.
       func indicatorCenter(pointer: CGPoint) -> CGPoint?
   }
   ```
   - `floor` maps a canvas location to its pixel (0009 coordinates: pixel `(i, j)` covers `[i, i+1) × [j, j+1)`). The offset is **integer**, so cloned pixels are copied exactly (no resampling).
   - ```swift
     /// Before-stroke source pixels. Reads outside the canvas return .clear.
     struct CloneSourceSampler: Sendable {
         static func layer(_ surface: TiledSurface) -> CloneSourceSampler          // raw pixels; visibility/opacity ignored (0012 Layer rule)
         static func image(_ image: LayeredImage, compositor: CPUCompositor = CPUCompositor()) -> CloneSourceSampler
         func pixel(x: Int, y: Int) -> ColorRGBA8
     }
     ```
     `layer` keeps a copy-on-write copy of the surface (free; no pixels are copied). `image` keeps a COW copy of the `LayeredImage` and composites **lazily, one 256×256 tile at a time**, through `compositor.compositeTile(_:of:)` (`nil` → transparent), caching each composited tile for the stroke's lifetime in a `final class` box protected by an `NSLock` (`@unchecked Sendable`, documented). It never composites the whole image up front. The implementation may instead pre-composite the tiles a segment needs on the main actor before calling `extend`, as long as the result is identical.
   - ```swift
     enum CloneStampCompose {
         /// The Clone Stamp's per-pixel rule.
         static func pixel(before: ColorRGBA8, source: ColorRGBA8, slotAlpha: UInt8, coverage: UInt8, blendMode: BlendMode) -> ColorRGBA8
     }
     ```
     **Normative:** `Sa = BlendOps.mul255(BlendOps.mul255(source.a, slotAlpha), coverage)`; if `Sa == 0` return `before` unchanged (bit-for-bit); else `BlendOps.blend(blendMode, dst: before, src: (source.r, source.g, source.b, Sa))` (opacity 255). `coverage` is the stroke's effective (clipped, pressure-scaled) coverage from `BrushStroke`. Consequences: a transparent source pixel or a source pixel outside the canvas paints nothing; the color's RGB is never used, only its alpha (Paint.NET doc: "inherits the opacity of the Primary color"). (Paint.NET 3.36 raised the color alpha to the 4th power; this spec uses the linear alpha, matching the Paint.NET 5 doc's wording and the Paintbrush.)
3. **`PaintDotMac/Core/Tools/CloneStampTool.swift`** (new) — `@MainActor final class CloneStampTool: Tool, BrushWidthAdjustable`, `id = .cloneStamp`; displayName "Clone Stamp", key `l`, group, and symbol come from 0006's descriptor table. Register `.cloneStamp: { CloneStampTool() }` in `ToolRegistry.standard()`.
   - **Options** (re-read at each `mouseDown` and in `optionsDidChange`), Paint.NET's set minus Spacing / Path Smoothing (D-38) and Selection Quality (not offered by any v1.0 brush tool):
     - `BrushOptions.load/save(from:tool: .cloneStamp)` → `tool.cloneStamp.width` (default 2), `.hardness` (75), `.antialiasing` (true), `.blendMode` (`.normal`; the list = `BlendMode` cases implemented, D-15).
     - `BrushPressure.load(from:tool: .cloneStamp)` → `tool.cloneStamp.pressureSensitivity` (default `.size`). (0055's `BrushPressure.key(for:)` already lists `.cloneStamp`; it takes any `ToolID`, so no allow-list change.)
     - `static let samplingKey = ToolOptionKey<SamplingMode>(tool: .cloneStamp, name: "samplingMode", defaultValue: .layer)` → `tool.cloneStamp.samplingMode` (Open questions 2).
   - **Per-document source state.** The tool instance is app-wide and shared by all documents (0006/0020), but the source belongs to one image (Paint.NET: "within the same image"). The tool keeps `[ObjectIdentifier: (owner: WeakContextBox, state: CloneSourceState)]` keyed by the `ToolContext` object (0006: `ToolContext: AnyObject`, one `CanvasToolSession` per document window), pruning entries whose `owner` is gone on every access. State survives tool switches, undo/redo, and other edits (Paint.NET: "persist through tool changes and other editing operations"); it is not persisted across launches or documents.
   - **⌥-click (set source):** `mouseDown` with `.option` in `modifiers` (either button) → `state.setSource(at: event.location, layerID: activeLayer.id, canvas: image.size)`; no stroke, no history step, `hasPendingEdit` stays false; the following drag/up events of that gesture are ignored. Refresh the overlay. (0045 row `cloneStamp.setSource`.)
   - **Stroke** (`mouseDown` without ⌥): `state.validate(against: context.image)`; `offset = state.beginStroke(at: event.location)`; if `nil` (no source) the gesture is ignored entirely (no pixels, no step). Otherwise snapshot at mouse-down and fix for the stroke: options (clamped), pressure sensitivity, sampling mode, clip (`context.paintClipMask`), destination layer ID (= active layer), slot alpha (TOOL-A color choice exactly as 0009: `.secondary`, or `.primary` + `.control`, → `colors.secondary.a`; else `colors.primary.a`), and the **source sampler from the before-stroke image**: Layer mode → `CloneSourceSampler.layer(image.layers[index of sourceLayerID].surface)`; Image mode → `CloneSourceSampler.image(context.image)`. Build `BrushStroke(canvasSize:, options:, clipMask:, pixelCompose: { x, y, before, cov in CloneStampCompose.pixel(before: before, source: sampler.pixel(x: x + offset.x, y: y + offset.y), slotAlpha:, coverage: cov, blendMode:) }, pressureSensitivity:)` and `begin(at:pressure:)` / `extend(to:pressure:)` with `event.pressure`, inside `context.updateImage` on the destination layer (gone → cancel), exactly as `PaintbrushTool`.
     - **No self-feedback:** the sampler reads the snapshot taken at mouse-down, so pixels painted earlier in the same stroke are never re-sampled (same-layer clones copy original pixels; Paint.NET 3.36 also reads a copy).
   - **Commit / cancel / pending:** as `PaintbrushTool`: `hasPendingEdit` true only during a stroke; commit on mouse-up, `commit(context:)` (tool switch, Return, undo/redo/save via 0008's `prepareForNavigation`) → `context.commitHistory(TileDiffHistoryItem(name: "Clone Stamp", icon: .cloneStamp, diff: stroke.makeTileDiff(from:layerID:)))`; empty diff → no step (H-6). `cancel` (Escape) → `BrushStroke.cancel`, no step. A mouse-down during a stroke is ignored.
   - **Width keys:** `BrushWidthAdjustable.adjustBrushWidth(by:context:)` as the Paintbrush (`[`/`]`, clamp 1…2000, persisted, overlay refreshed).
   - **Overlay / cursor.** `cursor(at:modifiers:)` = `.crosshair` inside the canvas, else `.arrow`. `mouseMoved`, `mouseDown`, `mouseDragged`, `adjustBrushWidth`, `optionsDidChange`, and ⌥-click set `context.setOverlay(.cloneStamp(CloneStampOverlay(brushOutline: BrushOutline.canvasRect(center: pointer, options:), source: state.indicatorCenter(pointer:).map { BrushOutline.canvasRect(center: $0, options:) })))`; `deactivate` sets `nil` after committing. The outline uses the full brush width (0055 Open question 5).
4. **`PaintDotMac/Core/Tools/ToolContext.swift`** (extend `ToolOverlay`): `case cloneStamp(CloneStampOverlay)` with `struct CloneStampOverlay: Sendable, Equatable { var brushOutline: CGRect; var source: CGRect? }` (canvas space; `source` = bounding square of the source circle, its midpoint is the source crosshair; `nil` = no source).
5. **`PaintDotMac/Core/Shortcuts/ShortcutTable.swift`** (0045): row `tools.l` note becomes "" (plain `matchesPaintNET`), row `cloneStamp.setSource` drops "(P1)" from its label → "Set source (Clone Stamp)"; regenerate `docs/shortcuts.md` with `RECORD_SHORTCUT_DOCS=1` (0045's `ShortcutDocsTests.docsFileMatchesTable`) and update both rows in 0045's `ShortcutTableTests.everyRowLiteral` literal. Tests that used L as the unimplemented key switch to R (Recolor is 0057, still unimplemented here): `ToolDispatcherTests.unimplementedKeyConsumed` uses `"r"`; 0045's "Unimplemented tools" edge-case test covers R only.

### Platform glue (AppKit/SwiftUI; UI tests and manual checks)

6. **`Canvas/ToolOverlayView.swift`** (extend): draws `.cloneStamp(o)`: the destination circle exactly like `.brushOutline(o.brushOutline)` (0009: 1 pt white under 1 pt black, hidden below `BrushOutline.minimumViewDiameter`); and when `o.source != nil`, the source circle in the same style but **dashed `[3, 3]`** plus a crosshair at its center (two 1 pt black-over-white lines, 11 pt long, always drawn even when the circle is below the minimum diameter). Hidden while the pointer is outside the canvas view, like the brush outline.
7. **`UI/ToolOptionsBar.swift`** (extend 0009/0055): for the Clone Stamp, left to right with Paint.NET's labels: **Brush width** (`toolOptions.width`, `.decrease`, `.increase`), **Pressure Sensitivity** (`toolOptions.pressureSensitivity`), **Hardness** (`toolOptions.hardness`, disabled while antialiasing is off), **Antialiasing** (`toolOptions.antialiasing`), **Blend mode** (`toolOptions.blendMode`), **Sampling** segmented "Layer" / "Image" (`toolOptions.samplingMode`, the 0012/0016 control). Reuse the Paintbrush's controls (no duplicated views). When the active document has no source, a secondary-colored hint label **"⌥-click to set the source"** (accessibility `toolOptions.cloneStampHint`) is shown at the end; it disappears once a source is set (Open questions 4). The bar observes the tool's per-document state through `AppModel` (the tool posts `onStateChange`, or the bar re-reads on overlay changes — implementer's choice, tested by the UI test).
8. **`Core/Accessibility/AccessibilityCatalog.swift`** (extend 0049): the reused controls keep their existing entries (`toolOptions.width`, `.pressureSensitivity` (0055), `.hardness`, `.antialiasing`, `.blendMode`, `.samplingMode` (0012 "Sampling")); add an exact `.documentWindow` entry `toolOptions.cloneStampHint`, role `.staticText`, label "⌥-click to set the source" (fixed), value `.none`, after `toolOptions.samplingMode`. Static text is not in Tab order (0049 rule).
9. **`App/MainMenu.swift`**: no new items. Edit > Undo/Redo titles "Undo Clone Stamp"/"Redo Clone Stamp" come from 0008.
10. No `project.yml` change beyond new files; run `xcodegen generate`. No new defaults prefix (`tool.` is already reset by `-UITestResetDefaults`, D-37). No PRD edit in this spec (the batch owner records the open-question answers in PRD §5.3 T-15 / §12).

## Acceptance criteria

- [ ] L selects the Clone Stamp; the Tools panel shows `tool.cloneStamp`; the options bar shows Brush width, Pressure Sensitivity, Hardness, Antialiasing, Blend mode, Sampling, with defaults 2 / Size / 75 / on / Normal / Layer. → `CloneStampUITests.pressingLSelectsCloneStamp`, `CloneStampToolTests.defaults`, updated `ToolsPanelUITests.testShowsImplementedToolsOnly`
- [ ] The source hint is catalogued for accessibility and every Clone Stamp options-bar control has its 0049 catalog label. → `AccessibilityCatalogTests.cloneStampHintEntry`, `CloneStampUITests.pressingLSelectsCloneStamp` (asserts labels)
- [ ] ⌥-click sets the source (pixel + active layer) without a history step; ⌥-click again replaces it; ⌥-click outside the canvas is ignored. → `CloneSourceStateTests.setSource*`, `CloneStampToolTests.optionClickSetsSourceWithoutStep`
- [ ] Without a source, a drag paints nothing and adds no step. → `CloneStampToolTests.noSourceIsNoOp`, `CloneStampUITests.dragWithoutSourceAddsNoStep`
- [ ] The offset is fixed at the first stroke after ⌥-click and reused by later strokes, across tool switches and undo/redo, until the next ⌥-click (aligned, Paint.NET). → `CloneSourceStateTests.offsetFixedAtFirstStroke`, `CloneStampToolTests.offsetPersistsAcrossStrokesAndToolSwitch`
- [ ] Pixels are copied exactly through the integer offset, including across 256-px tile boundaries in both source and destination. → `CloneStampToolTests.copiesExactPixelsAcrossTileBoundaries`
- [ ] Sampling reads the before-stroke snapshot (no self-feedback). → `CloneStampToolTests.noSelfFeedbackOnSameLayer`, `.imageModeNoSelfFeedback`
- [ ] Source pixels outside the canvas (or transparent) paint nothing. → `CloneStampToolTests.sourceOutsideCanvasPaintsNothing`, `CloneStampComposeTests.transparentSourceIsNoOp`
- [ ] Layer sampling reads the layer active at ⌥-click (raw pixels, even when hidden), so cloning works across layers; Image sampling reads the composite of visible layers. → `CloneStampToolTests.crossLayerClone`, `.layerVsImageSampling`, `CloneSourceSamplerTests.*`
- [ ] Coverage follows the brush model (width, hardness, antialiasing, pressure from 0055); opacity = slot alpha (primary for left, secondary for right/⌃-left); blend mode applies. → `CloneStampComposeTests.*`, `CloneStampToolTests.antialiasedEdge`, `.secondaryUsesSecondaryAlpha`, `.pressureSize`, `.blendModeApplies`
- [ ] Painting is clipped to the selection. → `CloneStampToolTests.clippedToSelection`
- [ ] Each stroke is one "Clone Stamp" step with icon `.cloneStamp`; undo restores identical tiles, redo re-applies; Escape cancels with no step; tool switch / undo / save commit a pending stroke. → `CloneStampToolTests.historyStepAndUndoRedo`, `.escapeCancels`, `CloneStampIntegrationTests.*`
- [ ] Source indicator: crosshair circle at the source point before the first stroke, then following the brush at pointer + offset; none without a source. → `CloneSourceStateTests.indicatorCenter`, `CloneStampToolTests.overlayShowsSource`; manual look
- [ ] Source state is per document and cleared when its source layer is deleted. → `CloneStampToolTests.sourceIsPerDocument`, `.deletedSourceLayerClearsSource`
- [ ] `[`/`]` change the width. → `CloneStampToolTests.widthKeys`
- [ ] Existing `BrushStroke` callers are unchanged. → `BrushStrokePixelComposeTests.wrappedComposeIsIdentical`
- [ ] End to end: ⌥-click then drag clones pixels into the saved PNG, and undo removes them. → `CloneStampUITests.optionClickThenDragClones`
- [ ] NF-1: a width-300 Clone Stamp stroke stays within the 0009 gate in both sampling modes. → `CloneStampPerformanceTests.*`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **No source / source layer deleted / document closed:** no-op stroke, no step; hint label shown. Undoing a layer deletion does not resurrect a cleared source (validation clears it at the next mouse-down or overlay refresh).
- **⌥-click outside the canvas or with a non-finite point:** ignored; previous source kept.
- **⌥ pressed or released mid-stroke:** no effect (only the mouse-down modifiers count). Mouse-down during a stroke ignored.
- **Offset (0,0)** (stroke starts on the source pixel): copies pixels onto themselves → empty diff → no step.
- **Source region off the canvas** (partly or fully, including after Crop/Resize Canvas shrank the image): those pixels read `.clear` → unchanged; no crash, no overflow (`x + offset.x` computed in `Int`; offsets are bounded by ±65,535 from APP-10 limits).
- **Destination off the canvas:** handled by 0009's region clamping.
- **Same-layer overlapping source/destination:** before-snapshot, no repetition artefacts.
- **Transparent / semi-transparent source:** alpha multiplies; transparent source never erases the destination (Paint.NET behavior).
- **Slot alpha 0** (e.g. secondary color fully transparent, right-drag): nothing painted, no step.
- **Hidden source layer (Layer mode):** still sampled (0012 Layer rule). **All layers hidden (Image mode):** composite is transparent → nothing painted.
- **Active layer changed after ⌥-click:** strokes paint the new active layer, still sampling the source layer (cross-layer clone).
- **Antialiasing off:** hardness ignored; aliased coverage 0/255 (pressure-scaled per 0055).
- **Selection:** clip mask applied by `BrushStroke`; source sampling is not clipped (pixels outside the selection may be copied into it).
- **Huge brush (2000) on a 4000×3000 image in Image mode:** lazy per-tile compositing only of tiles actually read.
- **Two documents:** each has its own source; ⌥-click in A does not give B a source.
- **Escape mid-stroke:** layer restored exactly; source and offset unchanged.

## Test plan

Notation: **pattern(x, y)** = `(x % 256, y % 256, (x + y) % 256, 255)` — every pixel identifies its position, so copied pixels prove the exact offset. Unless stated: Normal blend, primary `(0,0,0,255)` (only its alpha matters), secondary `(255,255,255,255)`, antialiasing **off** and hardness 100 (aliased coverage is exactly 255 inside the disc, so a cloned pixel equals the source pixel: with `Sa = 255`, 0009's Normal formula returns `src` exactly), pressure 1, `FakeToolContext` with the stated `LayeredImage`. Aliased width 5 at a pixel-center point covers the 21 pixels with `dx² + dy² ≤ 6.25` (5×5 minus its 4 corners); width 3 covers the full 3×3; width 1 one pixel (0009).

- **Unit — `PaintDotMacTests/Tools/CloneSourceStateTests.swift`:**
  - `setSourceStoresPixelAndLayer`: `setSource(at: (10.7, 20.2), layerID: L, canvas: 64×64)` → true, `sourcePixel (10,20)`, `sourceLayerID L`, `offset nil`.
  - `setSourceOutsideIgnored`: (−0.5, 3), (64, 3), (3, 64.0), (NaN, 1) → false; prior state unchanged.
  - `offsetFixedAtFirstStroke`: source (10,20); `beginStroke(at: (30.9, 25.1))` → (−20, −5); `beginStroke(at: (0.5, 0.5))` → (−20, −5) again; `setSource` again at (1,1) → offset nil; `beginStroke(at: (4.5, 4.5))` → (−3, −3).
  - `noSourceBeginsNothing`: fresh state → `beginStroke` nil.
  - `validateClearsMissingLayer`: image without layer L → all fields nil; with L → unchanged.
  - `indicatorCenter`: no source → nil; source (10,20), no offset, pointer (40.2, 30.9) → (10.5, 20.5); after `beginStroke(at: (30.5, 20.5))` (offset (−20, 0)) pointer (40.2, 30.9) → (20.2, 30.9); pointer NaN → nil.
- **Unit — `PaintDotMacTests/Tools/CloneStampComposeTests.swift`** (`CloneStampCompose.pixel`; values by hand from 0009's Normal formula):
  - `opaqueSourceFullCoverageCopies`: before (10,20,30,255), source (200,100,50,255), slot 255, cov 255 → (200,100,50,255).
  - `slotAlphaHalves`: before (255,255,255,255), source (255,0,0,255), slot 128, cov 255 → Sa 128 → (255,127,127,255) (`outG = (255·255·127 + 32512) / 65025 = 127`).
  - `semiTransparentSource`: before white, source (0,0,255,128), slot 255, cov 255 → (127,127,255,255).
  - `coverageScales`: before white, source (255,0,0,255), slot 255, cov 128 → (255,127,127,255).
  - `overTransparent`: before (0,0,0,0), source (255,0,0,255), slot 255, cov 64 → (255,0,0,64).
  - `transparentSourceIsNoOp`: source (9,9,9,0) or slot 0 or cov 0 → returns `before` bit-identical, including before (7,8,9,0).
  - `blendModeDelegates`: for every implemented `BlendMode` and 50 seeded (before, source, slot, cov) tuples → equals `BlendOps.blend(mode, dst: before, src: (s.r, s.g, s.b, mul255(mul255(s.a, slot), cov)))` when that alpha > 0 (BlendOps is independently tested by 0009/0026/0027/0059).
- **Unit — `PaintDotMacTests/Tools/CloneSourceSamplerTests.swift`:**
  - `layerReadsRawPixels`: 300×300 surface with pattern → `pixel(x: 257, y: 3)` = (1,3,4,255); (−1, 0), (300, 0), (0, 300) → `.clear`; layer surface shares storage (`sharesStorage(with:)` on tile (0,0)).
  - `imageCompositesVisibleLayers`: 2 layers 300×300: bottom opaque (0,0,255,255); top hidden (255,0,0,255) → (5,5) = (0,0,255,255); top visible opacity 255 → (255,0,0,255); top visible opacity 128 → (128,0,127,255) (0009's Normal formula with Sa = mul255(255,128) = 128 over opaque blue: R = (255·128·255 + 32512)/65025 = 128, B = (255·255·127 + 32512)/65025 = 127), which also equals `CPUCompositor().composite(image, in: (5,5,1,1)).pixels[0]`.
  - `imageIsLazy`: 1024×1024, 3 fully allocated layers; read one pixel in tile (2,2) → the sampler's cache holds exactly 1 composited tile (expose `cachedTileCount` for tests, `internal`).
  - `imageConcurrentReads`: `DispatchQueue.concurrentPerform(iterations: 64)` reading random seeded pixels across 9 tiles → every value equals the sequential read.
- **Unit — `PaintDotMacTests/Tools/BrushStrokePixelComposeTests.swift`:**
  - `wrappedComposeIsIdentical`: 200 seeded strokes (0009's random generator: size ≤ 400, width 1–60, hardness, AA, some off-canvas points, with/without clip) → `init(compose:)` and `init(pixelCompose:)` with `{ _, _, b, c in compose(b, c) }` produce identical surfaces and `touchedTiles`.
  - `pixelComposeReceivesCoordinates`: a pixelCompose returning `(UInt8(x % 256), UInt8(y % 256), 0, 255)` for a width-3 aliased dab at (300.5, 10.5) on 600×64 → pixel (299,9) = (43,9,0,255), (301,11) = (45,11,0,255).
- **Unit — `PaintDotMacTests/Tools/CloneStampToolTests.swift`** (`FakeToolContext`; events via 0006's test helpers; `ToolEvent.modifiers` contains `.option` for ⌥-clicks):
  - `defaults`: empty store → width 2, hardness 75, antialiasing true, `.normal`, pressure `.size`, sampling `.layer`; keys exactly `tool.cloneStamp.width/.hardness/.antialiasing/.blendMode/.pressureSensitivity/.samplingMode`.
  - `optionClickSetsSourceWithoutStep`: ⌥-down/up at (10.5,10.5) → no `commitHistory` call, layer `generation` unchanged, `hasPendingEdit` false after down, overlay `.cloneStamp(source: canvasRect(center: (10.5,10.5)))`.
  - `noSourceIsNoOp`: drag (5.5,5.5)→(40.5,5.5) without ⌥-click → surface identical, no history call, `hasPendingEdit` false.
  - `copiesExactPixelsAcrossTileBoundaries`: 600×300 one layer with pattern, width 5. ⌥-click (250.5, 100.5); drag (230.5, 254.5) → (280.5, 254.5); offset (20, −154). Expected: dest (256,256) = pattern(276,102) = (20,102,122,255); (255,255) = pattern(275,101) = (19,101,120,255); (254,256) = pattern(274,102) = (18,102,120,255); (228,254) = pattern(248,100) = (248,100,92,255); (282,254) = pattern(302,100) = (46,100,146,255); unchanged: (227,254) = pattern(227,254) = (227,254,225,255), (283,254), (256,257), (230,251). Full check: every pixel equals `pattern(x+20, y−154)` iff the pixel center is within distance 2.5 of segment (230.5,254.5)–(280.5,254.5) (test-local distance function), else `pattern(x,y)`. Diff tiles = {(0,0),(1,0),(0,1),(1,1)}; history one step "Clone Stamp", icon `.cloneStamp`.
  - `noSelfFeedbackOnSameLayer`: 64×64 pattern, width 1. ⌥-click (10.5,20.5); drag (12.5,20.5)→(40.5,20.5) (offset (−2,0)) → (40,20) = pattern(38,20) = (38,20,58,255) (a live read would give pattern(10,20) = (10,20,30,255)); every x in 12…40: (x,20) = pattern(x−2,20).
  - `imageModeNoSelfFeedback`: same with sampling `.image` on the single visible layer → same values.
  - `offsetPersistsAcrossStrokesAndToolSwitch`: 64×64 pattern, width 1. ⌥-click (10.5,10.5); click (30.5,10.5) → (30,10) = pattern(10,10); click (30.5,40.5) → (30,40) = pattern(10,40) = (10,40,50,255) (offset kept, not reset to the source point); `deactivate`/`activate` (switch to Pan and back), click (50.5,50.5) → pattern(30,50) = (30,50,80,255); undo the last step then click (51.5,50.5) → pattern(31,50); ⌥-click (5.5,5.5), click (50.5,20.5) → (50,20) = pattern(5,5) = (5,5,10,255).
  - `sourceOutsideCanvasPaintsNothing`: 64×64 pattern, width 9 (aliased, odd → center pixel (50,32), r 4.5, row 32 spans x 46…54). ⌥-click (2.5,32.5); click (50.5,32.5) (offset (−48,0)) → (46,32) and (47,32) unchanged (= pattern(46,32), pattern(47,32)); (48,32) = pattern(0,32) = (0,32,32,255); (54,32) = pattern(6,32) = (6,32,38,255).
  - `crossLayerClone`: 64×64, L0 opaque (0,0,255,255), L1 transparent. Active L0, ⌥-click (4.5,4.5); set active L1; width 3, click (44.5,44.5) → L1 (43…45, 43…45) = (0,0,255,255), (42,44) = (0,0,0,0); L0 unchanged. Hide L0 and repeat at (20.5,44.5) → same (Layer mode ignores visibility).
  - `layerVsImageSampling`: L0 opaque (0,0,255,255); L1 (active) transparent except red (255,0,0,255) square x,y 10…19. Layer mode: ⌥-click (14.5,14.5), click (44.5,14.5) width 3 → L1 (43…45, 13…15) red. New source ⌥-click (4.5,40.5): Layer mode click (44.5,40.5) → nothing, no step (L1 transparent there). Image mode, same ⌥-click and click → L1 (43…45, 39…41) = (0,0,255,255).
  - `antialiasedEdge`: 100×100 opaque white layer with a red (255,0,0,255) block at x,y 0…29; antialiasing on, hardness 100, width 10. ⌥-click (15.5,15.5); click (60.5,15.5) (offset (−45,0)). (60,15) = (255,0,0,255); (65,15) (d 5, R 5.5, cov 128; source (20,15) red) → (255,127,127,255); (66,15) → white.
  - `secondaryUsesSecondaryAlpha`: secondary alpha 128, right-button click (aliased width 1) copying opaque red onto white → (255,127,127,255); Control-left → same; secondary alpha 0 → unchanged, no step.
  - `pressureSize`: transparent destination layer L1 over source L0 filled red; antialiasing on, hardness 100, width 10, `.size`; ⌥-click on L0 (5.5,5.5), active L1, click (50.5,50.5) with pressure 0.5 → L1 (53,50) = (255,0,0,64) (0055: cov 64; `overTransparent`); `.off` → (53,50) = (255,0,0,255).
  - `blendModeApplies`: `.multiply`, source opaque (128,128,128,255), destination opaque (200,100,50,255) → equals `BlendOps.blend(.multiply, dst: (200,100,50,255), src: (128,128,128,255))`.
  - `clippedToSelection`: 64×64 pattern, selection rect (0,0,32,64) via `paintClipMask`, width 3, ⌥-click (5.5,40.5), drag (25.5,10.5)→(40.5,10.5) (offset (5 − 25, 40 − 10) = (−20, 30)) → (31,10) = pattern(11,40) = (11,40,51,255); (32,10) = pattern(32,10) unchanged.
  - `historyStepAndUndoRedo`: after the tile-boundary stroke → steps ["…", "Clone Stamp"]; undo → every tile equal to before (`TiledSurface ==`); redo → equal to after; source/offset unchanged by undo.
  - `escapeCancels`: Escape mid-drag → surface identical to before, no step, `hasPendingEdit` false; next stroke reuses the same offset.
  - `commitOnToolSwitch`: drag without mouse-up, `deactivate` → one "Clone Stamp" step.
  - `overlayShowsSource`: before ⌥-click, `mouseMoved` (20.2,20.2) → `.cloneStamp(CloneStampOverlay(brushOutline: BrushOutline.canvasRect(center:(20.2,20.2), options:), source: nil))`; after ⌥-click (10.3,10.7) and `mouseMoved` (40.2,30.9) → source rect centered (10.5,10.5); after a stroke starting (30.5,10.5) and `mouseMoved` (40.2,30.9) → source rect centered (20.2,30.9), width = options width; `deactivate` → last overlay `nil`.
  - `sourceIsPerDocument`: two `FakeToolContext`s A and B; ⌥-click in A; drag in B → no change in B; drag in A → clones. Release B; next access prunes it (`internal var sourceStateCount` = 1).
  - `deletedSourceLayerClearsSource`: ⌥-click on L1; remove L1 from the fake image; drag on L0 → no step; overlay `source == nil`.
  - `widthKeys`: `adjustBrushWidth(by: +1)` from 2 → 3 persisted at `tool.cloneStamp.width`; −5 from 3 → 1.
- **Property tests — `PaintDotMacTests/Tools/CloneStampPropertyTests.swift`** (200 seeded iterations each, seed printed on failure):
  - `matchesOracle`: random 1–3 layers ≤ 400×400 with random (semi-transparent) pixels, random source pixel and layer, random sampling mode, random 1–10-point stroke (some points off canvas), width 1–60, hardness, AA, random pressures and sensitivity, random slot alpha, random clip (none or a random rect selection), Normal or a random implemented blend mode → every destination pixel equals the oracle: `cov` from 0055's `BrushCoverageOracle.coverage(…)` (`PaintDotMacTests/Support/BrushCoverageOracle.swift`) clipped with `mul255`, source from a test-local reader of the **mouse-down** image (Layer: raw surface of the source layer; Image: `CPUCompositor().composite` of the mouse-down image), then `CloneStampCompose` rule written out in the test with `BlendOps`. Exact equality.
  - `uniformSourceEqualsPaintbrush`: source layer filled with random opaque color C, slot alpha random, same random stroke through `CloneStampTool` (onto another layer) and through `PaintbrushTool` with color (C.rgb, slotAlpha) on an identical copy → identical destination surfaces (cross-check with 0009/0055).
  - `undoRedoIdentity`: random stroke → undo restores pre-stroke tiles, redo post-stroke tiles.
- **Integration — `PaintDotMacTests/Integration/CloneStampIntegrationTests.swift`** (0009's headless `UndoBridge` + `ToolDispatcher(registry: .standard())`, 800×600 white with a red 100×100 block at (50,50)):
  - `cloneStrokeIsOneStep`: L key via `handleShortcut("l")` → active `.cloneStamp`; ⌥ pointerDown/up at (100.5,100.5); pointer drag (400.5,100.5)→(450.5,100.5) width 20 → history ["New Image", "Clone Stamp"]; (420,100) red; undo → white; redo → red. Edit menu title via `UndoBridge` "Undo Clone Stamp".
  - `saveCommitsPendingStroke`: drag without up, then the save path's `prepareForNavigation` → step recorded before encoding.
  - `shortcutTableAgrees`: `ShortcutTable` row `tools.l` resolves to `.cloneStamp` (implemented) and `cloneStamp.setSource` is ⌥-click; `docs/shortcuts.md` matches the generator output (0045's existing check).
- **Unit — `PaintDotMacTests/Accessibility/AccessibilityCatalogTests.swift`** (extend 0049): `cloneStampHintEntry` — `entry(matching: "toolOptions.cloneStampHint")` is `.staticText`, fixed "⌥-click to set the source", surface `.documentWindow`.
- **UI tests — `PaintDotMacUITests/CloneStampUITests.swift`** (`UITestApp`, `-UITestResetDefaults`, fixture generated at test time: 300×200 PNG, x < 150 = (255,0,0,255) red, x ≥ 150 = (0,0,255,255) blue, opened with `-UITestOpen`; press ⌘B (Zoom to Window) and map image points to canvas coordinates with a helper `UITestApp.canvasCoordinate(forImagePoint:imageSize:)` that assumes the fitted image is centered in `canvas` with scale `min(w/300, h/200)`; regions are wide so small mapping errors don't matter):
  - `pressingLSelectsCloneStamp`: type "l" → `tool.cloneStamp` selected; `toolOptions.width`, `.pressureSensitivity`, `.hardness`, `.antialiasing`, `.blendMode`, `.samplingMode` (value "Layer") and `toolOptions.cloneStampHint` exist; labels "Brush width", "Pressure Sensitivity", "Hardness", "Antialiasing", "Blend mode", "Sampling", and "⌥-click to set the source".
  - `dragWithoutSourceAddsNoStep`: drag across the blue half → `historyList` still has 1 row; Edit > Undo disabled.
  - `optionClickThenDragClones`: set width to 20 (type in `toolOptions.width`); ⌥-click (`XCUIElement.perform(withKeyModifiers: .option)`) at image (75,100) → hint disappears, history still 1 row; drag from image (225,100) to (265,100) → history row "Clone Stamp" (`historyRow.1`); ⌘S, read the file with ImageIO → (245,100) = (255,0,0,255), (245,180) = (0,0,255,255), (75,100) = (255,0,0,255). ⌘Z, ⌘S → (245,100) = (0,0,255,255).
  - Update `ToolsPanelUITests.testShowsImplementedToolsOnly` (0006): `tool.cloneStamp` exists; `tool.recolor` still doesn't (0057).
- **Performance (NF-1) — `PaintDotMacTests/Performance/CloneStampPerformanceTests.swift`** (XCTest `measure`, 0009's 4000×3000 setup, 3 fully allocated layers): `testStrokeSegmentLatencyWidth300Layer` and `testStrokeSegmentLatencyWidth300Image` → mean and p95 per `extend` ≤ 48 ms (0009's 3× gate); report the numbers in the Verification status.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open a photo, L, width 40, ⌥-click a clean area, paint over a blemish → the area is replaced by the source texture; the dashed source circle with crosshair moves in lockstep with the brush.
  2. Release, start a new stroke elsewhere → the source circle jumps to the same relative offset (aligned); ⌥-click again → the circle sits on the new source until the next stroke.
  3. Paint across the source area itself (same layer) → no smeared repetition.
  4. Hardness 0 vs 100 and antialiasing off → soft vs hard vs pixelated edges.
  5. Two layers: ⌥-click on the bottom layer, select the top layer, paint → pixels appear on the top layer. Sampling Image: copies what you see.
  6. With a tablet (if available) and Pressure Sensitivity Size: light pressure clones a thinner line.
  7. At 1% and 3200% zoom the indicator crosshair stays visible and aligned to the source pixel.
  8. Light and dark appearance: the dashed source circle is visible on light and dark images.

## Open questions

Recommended answers are applied in this spec; the user should confirm each.

1. **Aligned vs non-aligned.** Paint.NET has no option: the offset is fixed at the first stroke after Ctrl-click and kept for later strokes ("aligned") until a new source is set. *Recommended:* aligned only, no option; the source is per document, survives tool switches and undo/redo, and is not saved or restored across launches.
2. **Sampling Layer vs Image.** The Paint.NET Clone Stamp page lists no Sampling option; Paint.NET clones from the layer that was active at the Ctrl-click (3.36 source), which may differ from the destination layer. *Recommended:* add a **Sampling** option (Layer default / Image), reusing `SamplingMode`, as on the Color Picker, Magic Wand, and Paint Bucket; Layer reads the layer active at the ⌥-click.
3. **Source pixels outside the canvas.** Paint.NET 3.36 resets the anchor when the source leaves the layer bounds. *Recommended:* treat them as transparent, so those destination pixels are left unchanged, and keep the offset.
4. **Dragging with no source set.** Paint.NET does nothing. *Recommended:* do nothing (no step, no beep), and show a hint "⌥-click to set the source" in the options bar while the document has no source.
5. **Default brush settings.** *Recommended:* the same defaults as the Paintbrush (width 2, hardness 75, antialiasing on, Normal) and Pressure Sensitivity Size (0055), each stored separately under `tool.cloneStamp.*`.

## Out of scope

- Spacing, Path Smoothing, and Selection Quality options (D-38; no v1.0 brush tool has them).
- Non-aligned mode, cloning from another document, rotated/scaled cloning, a healing brush.
- Pen eraser-end switching and pressure curves (0055 out of scope).
- Recolor (0057).
