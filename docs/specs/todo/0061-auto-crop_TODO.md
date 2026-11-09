# 0061 — Add Image ▸ Auto-Crop (⌥⌘X): trim uniform borders of the composite image from every layer

> Source: PRD.md §5.5 IMG-6 ("Auto-crop (trim uniform borders).", P1); §5.5 header rule shared with IMG-1 ("commands that affect all layers"); §5.12 (general rule Ctrl → ⌘, Alt → ⌥; Mac system shortcuts win); §5.7 H-6 / §12 D-34 (no-op edits add no step); §12 D-7 (per-document DPI), D-33 (colour under alpha 0 preserved), D-40 (no selection = `nil`), D-22 decision 22 (the CPU reference compositor is used for image sampling); §6 NF-1/NF-4; §8 v1.x ("… auto-crop …"); AGENTS.md architecture rules (pixel changes only through history, 256×256 tiles, Core free of AppKit).
> Paint.NET docs (fetched 2026-11-08; `getpaint.net/doc/latest/…` redirects to `paint.net/doc/latest/…`): Image menu — https://paint.net/doc/latest/ImageMenu.html (revision 15 Dec 2024) lists Crop to Selection, Resize, Canvas Size, Flip Horizontal/Vertical, Rotate 90° Clockwise/Counter-Clockwise, Rotate 180°, Color Profile, Flatten — **no Auto-Crop**. Keyboard reference — https://paint.net/doc/latest/KeyboardMouseCommands.html — its Ctrl+Alt+letter entries are only Ctrl+Alt+I (Invert Alpha), Ctrl+Alt+S (Save All Images), Ctrl+Alt+V (Paste into New Image); **no Ctrl+Alt+X**. The change log (https://paint.net/roadmap.html) mentions no auto-crop. So the brief's "Paint.NET 4.2+ Image ▸ Auto-Crop, Ctrl+Alt+X, based on the composite image" could not be verified from Paint.NET's own pages; this spec applies it as the recommended behavior and lists it under Open questions 1–3. Prior art for the border rule: GIMP *Image ▸ Crop to Content* / "Autocrop Image" ("removes the largest possible border area that is all the same color"), https://docs.gimp.org/2.8/en/plug-in-autocrop.html.
> Milestone: v1.x
> Depends on: 0051-use-case-acceptance-tests (v1.0 complete). Directly builds on 0008 (`DocumentSnapshotHistoryItem`, `HistoryIcon`, `UndoBridge`), 0010 (`HistoryIcon+Symbol.swift`), 0012/0024 (`CPUCompositor.compositeTile(_:of:)`, `flattened(_:)`), 0013 (`Selection`), 0021 (`CanvasTransform.withImageSize(_:)` + `.structure` hook), 0022 (Image menu, `runCropToSelection` static-driver pattern), 0035 (`ImageCommandRule`), 0036 (`ResizeCanvas.placed(_:in:offset:fill:)`, `Selection.repositioned(canvasSize:offset:)`), 0037 (`runFlipRotate` pattern, Image menu layout), 0045 (`ShortcutTable`, `MainMenu.item(_:action:identifier:)`, `docs/shortcuts.md`).

## Context

Not yet implemented (no application code exists; the names below are the ones fixed by the earlier specs).

- **Image menu after v1.0** (0022 `:78-82`, 0035 item 4, 0036 item 5, 0037 `:109-121`): Crop to Selection ⇧⌘X (`menu.image.cropToSelection`), Resize… ⌘R (`menu.image.resizeImage`), Canvas Size… ⇧⌘R (`menu.image.resizeCanvas`), separator, Flip Horizontal, Flip Vertical, separator, Rotate 90° Clockwise ⌘], Rotate 90° Counter-Clockwise ⌘[, Rotate 180° ⌘J, separator, Flatten ⇧⌘F (last). `MainMenuTests.imageMenuItems` asserts the exact list. Since 0045 every item is created through `MainMenu.item(_:action:identifier:)` and gets its chord from `ShortcutTable.menuChord(forMenuItem:)`; `MainMenuShortcutTests.everyItemMatchesTable` / `.noLiteralKeyEquivalentsInSource` enforce that (0045 `:308`, `:332`).
- **Whole-image command pattern** (0037 `:124-127`): `@objc` action → `@MainActor static func run…(bridge:gestureInProgress:isBusy:hasSheet:)`; if `!ImageCommandRule.isEnabled(hasDocument: true, isGestureInProgress:, isBusy:, hasSheet:)` → return without calling `prepareForNavigation`; else `bridge.prepareForNavigation?()` (floating pixels record "Finish Pixels", 0038–0040 commit pending shapes/text), then `if let item = …makeHistoryItem(for: bridge.state) { bridge.perform(item) }`. Synchronous on the main actor. `validateMenuItem` uses the same rule. `ImageCommandRule` lives in `Core/Operations/ImageCommandRule.swift` (0035 item 4a).
- **Crop helpers already specified:** 0036 `ResizeCanvas.placed(_ surface: TiledSurface, in size: PixelSize, offset: PixelPoint, fill: ColorRGBA8) -> TiledSurface` — places a layer surface at `offset` in a canvas of `size`; pixels that land outside are cropped; tile storage is shared when both offsets are multiples of 256; all-zero fill leaves the new area unallocated. 0036 `Selection.repositioned(canvasSize:offset:) -> Selection?` — same pixels at the new origin, clipped, `nil` when nothing remains (D-40). With `offset = (−R.x, −R.y)` and `size = R.size`, both are an exact crop to `R`, which is all this spec needs (no masking, unlike 0022).
- **Compositor** (0012 `:37-39`, extended by 0024/0026/0027/0059): `CPUCompositor.compositeTile(_ coordinate: TileCoordinate, of image: LayeredImage) -> [ColorRGBA8]?` (row-major tile pixels, edge tiles clipped to the canvas; `nil` when no visible layer with opacity > 0 has an allocated tile there, i.e. the tile is fully `(0,0,0,0)`); `flattened(_:) -> TiledSurface`. Visible layers only, opacity and blend modes applied. This is "the composite image" the bounds are computed from.
- **History:** `DocumentSnapshotHistoryItem(name:icon:before:after:)` (0008), `change == .structure`; `HistoryIcon` cases per 0008 `:50-55` ("later specs add cases"); 0010 `HistoryIcon+Symbol.swift` maps each case to an SF Symbol and `HistoryIconSymbolTests.everyCaseHasAnExistingSymbol` checks every case. 0021's `.structure` hook applies `CanvasTransform.withImageSize(_:)`: zoom kept, image re-centred (same rule as 0022/0035–0037).
- **Shortcuts:** ⌥⌘X appears nowhere in `ShortcutTable` (0045 item 2 rows), in `SystemReservedShortcuts.chords` (0045 `:284`), or in the earlier v1.x specs (0053 adds ⌘' and ⌥⌘R; 0054 adds pointer rows only; 0056/0057 change notes only; 0060 adds no binding — its `layers.rotateZoom` row stays `notMapped`). 0045's `ShortcutConflictTests.menuChordsUnique` guards against later collisions.

## User story

As a PaintDotMac user, I open a screenshot or a logo that has a plain border around it (white, any solid colour, or transparent) and choose **Image ▸ Auto-Crop** or press **⌥⌘X**. Every layer is cropped to the smallest rectangle that contains everything that differs from the border colour of the visible image; the window keeps its zoom and re-centres the image, and the status bar shows the new size. The History panel shows one "Auto-Crop" step that ⌘Z undoes exactly and ⇧⌘Z redoes. If there is nothing to trim (no uniform border, or the whole image is one colour), nothing happens and no step is added.

## Scope & changes

### Core (pure Swift, headless, unit-tested; no AppKit/SwiftUI imports)

1. **`PaintDotMac/Core/Operations/AutoCrop.swift`** (new):
   ```swift
   public enum AutoCrop {
       public static let name = "Auto-Crop"                 // menu title and history step name
       public static let icon: HistoryIcon = .autoCrop

       /// The border colour: the composite pixel at (0, 0) (top-left). Open question 2.
       public static func referenceColor(of image: LayeredImage, compositor: CPUCompositor = CPUCompositor()) -> ColorRGBA8

       /// Whether `pixel` counts as border for `reference` (exact match; Open question 3):
       /// reference.alpha == 0 → pixel.alpha == 0 (any RGB under alpha 0 is "transparent", D-33);
       /// otherwise all four channels equal (r, g, b, a).
       public static func matches(_ pixel: ColorRGBA8, reference: ColorRGBA8) -> Bool

       /// The tight bounding rectangle (half-open PixelRect) of every composite pixel that does NOT match the
       /// reference colour, or nil when every pixel matches (fully uniform image, including all-transparent and
       /// images whose layers are all hidden or at opacity 0).
       public static func contentBounds(of image: LayeredImage, compositor: CPUCompositor = CPUCompositor()) -> PixelRect?

       /// nil when contentBounds is nil (uniform) or equals the full canvas (nothing to trim) — H-6 / D-34.
       public static func cropRect(for state: DocumentState) -> PixelRect?

       /// The cropped after-state, or nil per cropRect.
       public static func croppedState(_ state: DocumentState) -> DocumentState?

       /// DocumentSnapshotHistoryItem(name: name, icon: icon, before: state, after: croppedState) or nil.
       public static func makeHistoryItem(for state: DocumentState) -> DocumentSnapshotHistoryItem?
   }
   ```
   - **Equivalence (normative definition of "trim uniform borders"):** the result is exactly what you get by repeatedly removing the outermost row or column on any side while every pixel in it matches the reference colour. That equals the bounding box of non-matching pixels, which is what `contentBounds` computes.
   - **Algorithm** (`contentBounds`): `ref = referenceColor`. Iterate the canvas tile grid (256×256, edge tiles clipped). For each tile: `px = compositor.compositeTile(coord, of: image)`; if `px == nil` the tile is all `(0,0,0,0)` → skip it when `ref.alpha == 0`, else it is entirely content (union its full clipped rect). Otherwise scan the tile's pixels and union `(x, y, 1, 1)` for every pixel with `!matches(p, ref)` (track `minX, minY, maxX, maxY` as `Int`; no per-pixel allocation). **Allowed optimization** (must not change the result): skip a tile whose clipped rect lies entirely inside the running bounds; process tiles in row-major order. Never build a full-image buffer (`flattened` is not used; at most one tile of composite pixels per worker). Per-tile work may run with `DispatchQueue.concurrentPerform`, merging per-tile min/max serially; the result is order-independent.
   - **Reference pixel:** `referenceColor` = the first element of `compositeTile(TileCoordinate(0, 0), of:)`, or `(0,0,0,0)` when that returns `nil`.
   - **Crop** (`croppedState`), with `R = cropRect`, `offset = PixelPoint(x: −R.x, y: −R.y)`:
     - every layer, in order, **including hidden and opacity-0 layers** (Paint.NET's Image menu rule "affect all layers"): `surface = ResizeCanvas.placed(layer.surface, in: R.size, offset: offset, fill: .clear)` (pixels are copied unchanged — no masking, alpha untouched, colour under alpha 0 preserved per D-33; tiles shared when `R.x`, `R.y` are multiples of 256). `id`, `name`, `isVisible`, `opacity`, `blendMode` kept; `activeLayerIndex` kept; `dpi` kept (D-7). Result satisfies `LayeredImage.isConsistent`.
     - **Selection** (Open question 4): `state.selection?.repositioned(canvasSize: R.size, offset: offset)` — stays on the same pixels, clipped to `R`, `nil` if it lay wholly outside `R` (D-40). `nil` stays `nil`.
     - `floatingPixels` is `nil` (the command commits them first, item 4).
     - `R` is inside the canvas and non-empty, so no `ImageLimits` check is needed.
   - **No-op rule:** `cropRect` returns `nil` (and so `croppedState`/`makeHistoryItem`) when the image is uniform or when `contentBounds == PixelRect(origin: .zero, size: image.size)`.

2. **`PaintDotMac/Core/History/HistoryIcon.swift`** (extend 0008): add case `autoCrop` (raw value `"autoCrop"`), placed after `cropToSelection`.

### Platform glue (AppKit; hosted/UI tests and manual checks)

3. **`PaintDotMac/UI/HistoryIcon+Symbol.swift`** (extend 0010): `.autoCrop → "arrow.down.right.and.arrow.up.left"`.

4. **`PaintDotMac/Document/DocumentWindowController.swift`** (extend):
   - `@objc func autoCrop(_ sender: Any?)` → `Self.runAutoCrop(bridge: undoBridge, gestureInProgress: AppModel.shared.dispatcher.isGestureInProgress, isBusy: undoBridge.isBusy, hasSheet: window?.attachedSheet != nil)`.
   - `@MainActor static func runAutoCrop(bridge: UndoBridge, gestureInProgress: Bool, isBusy: Bool, hasSheet: Bool)`: if `!ImageCommandRule.isEnabled(hasDocument: true, isGestureInProgress: gestureInProgress, isBusy: isBusy, hasSheet: hasSheet)` → return (no `prepareForNavigation`); `bridge.prepareForNavigation?()`; `if let item = AutoCrop.makeHistoryItem(for: bridge.state) { bridge.perform(item) }`. Synchronous on the main actor like 0037 (see Performance). Nothing to trim → silently nothing (no alert, no beep; Open question 5).
   - `validateMenuItem(_:)`: `autoCrop(_:)` enabled iff `ImageCommandRule.isEnabled(…)` (same arguments as 0037). It does **not** require a selection and is **not** disabled when there is nothing to trim (that would need a composite scan on every menu validation).
   - `.structure` handling is unchanged: 0021's `withImageSize` keeps the zoom and re-centres; marching ants and status-bar size/selection refresh as for 0022.

5. **`PaintDotMac/Core/Shortcuts/ShortcutTable.swift`** (extend 0045): add one row in section `.image`, directly after `image.cropToSelection`:
   | id | action | menu identifier | bindings | Paint.NET | status / notes |
   |---|---|---|---|---|---|
   | image.autoCrop | Auto-Crop | `menu.image.autoCrop` | ⌥⌘X ⓜ (`KeyChord(.character("x"), [.command, .option])`) | — | `.macStandard` — notes: "PaintDotMac addition (IMG-6). Paint.NET's keyboard reference lists no Auto-Crop; ⌥⌘X pairs it with Crop to Selection ⇧⌘X (Ctrl + Alt + X → ⌥⌘X if Paint.NET's binding is confirmed, Open question 1 of spec 0061)." |
   Regenerate `docs/shortcuts.md` from `ShortcutMarkdown.render()` (0045's byte-identity test, `RECORD_SHORTCUT_DOCS=1`). If the user confirms Paint.NET has Ctrl+Alt+X (Open question 1), the row instead gets Paint.NET `"Ctrl + Alt + X"` and status `.matchesPaintNET` — `ShortcutTableTests.matchingEntriesFollowCtrlToCommandRule` then checks it mechanically.

6. **`PaintDotMac/App/MainMenu.swift`** (extend): in `menu.image`, directly after "Crop to Selection" and before "Resize…": **"Auto-Crop"**, action `autoCrop(_:)`, target `nil`, identifier `menu.image.autoCrop`, created with 0045's `item(_:action:identifier:)` (no literal key equivalent). Full Image menu after this spec: Crop to Selection ⇧⌘X, **Auto-Crop ⌥⌘X**, Resize… ⌘R, Canvas Size… ⇧⌘R, separator, Flip Horizontal, Flip Vertical, separator, Rotate 90° Clockwise ⌘], Rotate 90° Counter-Clockwise ⌘[, Rotate 180° ⌘J, separator, Flatten ⇧⌘F (Open question 6 for the position).

7. Accessibility (0049): no catalog change — 0049 catalogues no menu items (menus are covered by `MainMenuTests.everyItemHasTitle`, which covers "Auto-Crop").

8. `project.yml`: no target changes; run `xcodegen generate` (new files). PRD.md / AGENTS.md: not edited here (sub-agent rule). Once Open questions are answered the orchestrator should add to PRD.md: §5.5 IMG-6 the border rule, tolerance, selection rule; §5.12 a row "Auto-Crop | — (or Ctrl+Alt+X) | ⌥⌘X"; a §12 decision row.

### Performance (NF-1, NF-4)
- `contentBounds` is O(composite of the visited tiles); `croppedState` is O(R) with tile sharing on aligned offsets. Target (Debug test build): 4000×3000, three opaque Normal layers, uniform white border with content rect (500, 400, 3000, 2200) → `makeHistoryItem` < 300 ms; gate at 3× (900 ms). Wide sparse case 65,535×300 transparent with two marker pixels → < 300 ms, gate 900 ms. Report numbers in the Verification status.
- NF-4: the step's cost is 0008's `HistoryCost.unsharedTileBytes(before:after:)` plus selection bytes (0013) — no special case; undo budget dropping (H-5) handled by 0008.

## Acceptance criteria

- [ ] Image ▸ **Auto-Crop** ⌥⌘X exists directly after Crop to Selection, action `autoCrop(_:)`, identifier `menu.image.autoCrop`; its chord comes from `ShortcutTable` and conflicts with nothing (menu, single keys, macOS reserved); `docs/shortcuts.md` lists it. → `MainMenuTests.imageMenuItems` (updated), 0045's `MainMenuShortcutTests.everyItemMatchesTable`, `.noLiteralKeyEquivalentsInSource`, `ShortcutConflictTests.*` on the real table, `ShortcutTableTests.imageRowsIncludeAutoCrop`, `ShortcutDocsTests.docsFileMatchesTable`; UI `AutoCropUITests.testMenuItemPresentAndEnabled`
- [ ] Enabled with an open document (with or without a selection); disabled mid-gesture, while busy, or with a sheet attached. → 0035's `ImageCommandRuleTests.enablement`, `AutoCropCommandTests.ignoredWhenDisabled`; UI `testMenuItemPresentAndEnabled`
- [ ] The border colour is the composite's top-left pixel; a pixel is border iff it matches exactly (all four channels), with any alpha-0 pixel matching an alpha-0 reference. → `AutoCropTests.matchesRule`, `.referenceIsTopLeftCompositePixel`
- [ ] The crop rectangle is the tight bounding box of non-matching composite pixels; each side is trimmed independently. → `AutoCropTests.allFourSidesTrimmed`, `.leftOnly`, `.topOnly`, `.rightAndBottomOnly`, `.singlePixelContent`, `.singleCornerPixelContent`, `AutoCropPropertyTests.randomBoundsMatchOracle`
- [ ] Transparent borders are trimmed (RGB under alpha 0 ignored); a pixel with alpha ≥ 1 is content. → `.transparentBorders`, `.semiTransparentPixelIsContent`
- [ ] Bounds come from the composite (visible layers, opacity, blend), but all layers including hidden ones are cropped; layer ids, names, visibility, opacity, blend mode, active layer index and DPI are kept; pixels inside the rectangle are copied bit-exactly. → `.compositeDrivesBounds`, `.hiddenLayerContentIgnoredButCropped`, `.croppedStateCropsAllLayersExactly`
- [ ] Fully uniform images and images with nothing to trim add no step and change nothing. → `.fullyUniformIsNil`, `.nothingToTrimIsNil`, `AutoCropCommandTests.noOpAddsNoStep`; UI `testShortcutAndSecondAutoCropIsNoOp`, `testUniformImageIsNoOp`
- [ ] Correct across tile seams, with tile sharing for 256-aligned crops, and on sparse very wide images without a full-image buffer. → `.tileBoundaries`, `.alignedCropSharesTiles`, `.largeSparseImage`
- [ ] The selection stays on the same pixels, clipped to the new canvas, or becomes no selection when it lay outside. → `.selectionRepositioned`, `.selectionOutsideBecomesNil`; UI `testSelectionFollowsCrop`
- [ ] One history step "Auto-Crop" (icon `.autoCrop`, `.structure`); undo restores size, every pixel, layers, and selection exactly; redo restores the cropped state exactly. → `.historyItemNameAndIcon`, `AutoCropIntegrationTests.undoRedoRoundTrip`, `AutoCropPropertyTests.randomApplyRevertIdentity`; UI `testAutoCropViaMenuThenUndoRedo`
- [ ] A pending edit (floating pixels, shape, text) is committed first and the crop sees the committed pixels. → `AutoCropCommandTests.commitsPendingEditFirst`
- [ ] After the crop and its undo/redo the zoom is kept, the image re-centred, and the status bar shows the new size. → `AutoCropIntegrationTests.undoRedoRoundTrip` (`.structure` received); UI `testAutoCropViaMenuThenUndoRedo` (`statusBar.imageSize`, `statusBar.zoom`)
- [ ] `HistoryIcon.autoCrop` has an existing SF Symbol. → 0010's `HistoryIconSymbolTests.everyCaseHasAnExistingSymbol` (covers the new case automatically), 0008's `historyIconRawValues`
- [ ] Performance targets met within the 3× gate. → `AutoCropPerformanceTests.content4000x3000ThreeLayers`, `.wideSparse`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **1×1 image:** always uniform → no-op. → `.fullyUniformIsNil`
- **Fully uniform opaque image / all-transparent image (no tiles, or alpha-0 pixels with mixed RGB) / every layer hidden / every visible layer at opacity 0:** composite uniform → no-op, no step. → `.fullyUniformIsNil`, `.compositeDrivesBounds`
- **Content touching all four edges** (top-left pixel differs from some pixel in every edge row/column): bounds = full canvas → no-op. → `.nothingToTrimIsNil`
- **Border only on the right/bottom while content covers the top-left pixel:** the reference is the content colour; with a uniform content block the "border" found is the content itself and the image is cropped to the non-matching strip — a documented consequence of the top-left rule (Open question 2). → `.referenceIsTopLeftCompositePixel`
- **Content pixel identical to the border colour inside the content** (e.g. white text on a white border inside a black box): only the outer bounding box matters; interior matches are kept. → `.allFourSidesTrimmed` (interior pixel equal to the reference stays)
- **Layer content that composites to the border colour** (white top-layer pixel over a white background, or content in a hidden layer): not content; hidden-layer pixels outside `R` are discarded (undo restores them). → `.hiddenLayerContentIgnoredButCropped`
- **Semi-transparent near-border pixel** `(255,255,255,254)` on an opaque white border: content (exact match). JPEG noise around a border is therefore content (Open question 3). → `.matchesRule`
- **Tile seams / unaligned offsets / aligned offsets:** pixel-exact; aligned crops share tile storage. → `.tileBoundaries`, `.alignedCropSharesTiles`
- **Very large sparse image** (65,535 × 300): correct, no full-image allocation (unallocated tiles skipped when the reference is transparent). → `.largeSparseImage`, `AutoCropPerformanceTests.wideSparse`
- **Selection wholly in the trimmed border:** becomes `nil` (Deselect then disabled). Undo restores it. → `.selectionOutsideBecomesNil`
- **Mid-gesture, busy (effect/resize running), sheet attached:** item disabled, shortcut ignored, no `prepareForNavigation`. → `AutoCropCommandTests.ignoredWhenDisabled`
- **Pending floating pixels:** "Finish Pixels" step, then "Auto-Crop" (two steps); if the committed result has nothing to trim, only the "Finish Pixels" step is added. → `.commitsPendingEditFirst`, `.noOpAddsNoStep`
- **Undo budget (H-5):** ordinary snapshot item; no special case.

## Test plan

Expected values are hand-computed below or come from an independent naive oracle in the test target; never from running the code under test. Images are built with 0022's test helper `layer(_ size, _ f: (x, y) -> ColorRGBA8)` / `TestImages.surface`; `W = (255,255,255,255)`, `K = (0,0,0,255)`, `CL = (0,0,0,0)`. For a single visible Normal layer at opacity 255, the composite of an opaque pixel is that pixel (0012's tested contract).

- **Unit — `PaintDotMacTests/Operations/AutoCropTests.swift`** (Swift Testing):
  - `matchesRule`: `matches((1,2,3,0), ref: (9,9,9,0)) == true`; `matches((1,2,3,1), ref: (9,9,9,0)) == false`; `matches((5,6,7,255), ref: (5,6,7,255)) == true`; `(5,6,8,255)` vs `(5,6,7,255)` → false; `(5,6,7,254)` vs `(5,6,7,255)` → false; `(0,0,0,0)` vs `(5,6,7,255)` → false; `(255,255,255,254)` vs `W` → false.
  - `allFourSidesTrimmed`: 12×9 `W`, `K` at x ∈ 2…8, y ∈ 3…6, but (5,4) = `W` (interior border-coloured pixel) → `contentBounds == (2,3,7,4)` (left 2, top 3, right 3, bottom 2 trimmed); `croppedState` 7×4; result (3,1) == `W`, (0,0) == `K`, (6,3) == `K`.
  - `leftOnly`: 12×9, `W` for x < 4, `K` for x ≥ 4 → `(4,0,8,9)`.
  - `topOnly`: 12×9, `W` for y < 3, `K` for y ≥ 3 → `(0,3,12,6)`.
  - `rightAndBottomOnly`: 12×9 `W`, `K` at (5,0), (0,4), (7,6) → `(0,0,8,7)` (right 4 and bottom 2 trimmed).
  - `referenceIsTopLeftCompositePixel`: 12×9, `K` for x ≤ 8, `W` for x ≥ 9 → `referenceColor == K`, `contentBounds == (9,0,3,9)`. Same image with (0,0) = `(1,1,1,255)` → `referenceColor == (1,1,1,255)`, `contentBounds == (0,0,12,9)` → `cropRect == nil`.
  - `singlePixelContent`: 7×5 `W`, (3,2) = `(0,0,255,255)` → `(3,2,1,1)`; `croppedState` 1×1 pixel `(0,0,255,255)`.
  - `singleCornerPixelContent`: 5×5 `W`, (4,4) = `(255,0,0,255)` → `(4,4,1,1)`.
  - `fullyUniformIsNil`: 6×4 all `(10,20,30,255)` → `contentBounds == nil`, `cropRect == nil`, `croppedState == nil`, `makeHistoryItem == nil`; 1×1 `(7,7,7,7)` → nil; 8×8 with alternating `(x,y,0,0)` (all alpha 0) → nil; 1024×1024 with zero allocated tiles → nil.
  - `nothingToTrimIsNil`: 6×6 `W` with `K` at (5,0), (0,5), (3,5), (5,3) → `contentBounds == (0,0,6,6)`, `cropRect == nil`.
  - `transparentBorders`: 10×10, no allocated pixels except (2,3) = `(200,0,0,128)`, (7,8) = `(0,0,255,255)`, (0,5) = `(9,9,9,0)` → reference `CL`-like alpha 0, `contentBounds == (2,3,6,6)`; result (0,0) == `(200,0,0,128)`, (5,5) == `(0,0,255,255)`.
  - `semiTransparentPixelIsContent`: 9×9 transparent, (4,4) = `(10,20,30,1)` → `(4,4,1,1)`; result pixel `(10,20,30,1)` (straight alpha, copied unchanged).
  - `compositeDrivesBounds`: 10×10, L0 opaque `W` everywhere; L1 visible transparent with (2,2) = `(255,0,0,255)` and (6,6) = `W` (white over white → no content); L2 hidden with (8,8) = `(0,0,255,255)`; L3 visible opacity 0 with (9,0) = `K` → `contentBounds == (2,2,1,1)`. Variant: all layers hidden → `nil`.
  - `hiddenLayerContentIgnoredButCropped`: the image above → `croppedState` 1×1; L2 surface 1×1 pixel == L2's source (2,2) = `CL` (its (8,8) content discarded); L3 pixel == its source (2,2).
  - `croppedStateCropsAllLayersExactly`: 8×6, layers "A" (L0: `W` except `K` on rect (2,1,3,4)), "B" (L1, opacity 77, blend `.multiply`: transparent except (3,2) = `(0,255,0,100)`), "C" (L2 hidden: (0,0) = `(255,0,0,255)`, (4,4) = `(0,200,0,255)`, (3,1) = `(10,20,30,0)`), fixed UUIDs, `activeLayerIndex 1`, dpi 150 → size 3×4; L0 all `K`; L1 (1,1) == `(0,255,0,100)`, other 11 pixels `CL`; L2 (2,3) == `(0,200,0,255)`, (1,0) == `(10,20,30,0)` (colour under alpha 0 preserved, D-33), others `CL`; ids/names/visibility/opacity/blend modes in the same order, `activeLayerIndex == 1`, `dpi == 150`, `isConsistent`.
  - `tileBoundaries`: (a) 600×520 transparent, opaque `K` at (256,255) and (511,513) → `(256,255,256,259)`; every result pixel equals the source at the offset (full scan). (b) 600×520 opaque `W`, `K` at (257,511) and (512,260) → `(257,260,256,252)`; result (0,251) == `K`, (255,0) == `K`, (1,1) == `W`. (c) 520×520 `W`, `K` at (255,255) only → `(255,255,1,1)`.
  - `alignedCropSharesTiles`: 1024×1024 transparent, opaque pixels (each a different colour) at (256,256), (511,300), (300,511) → `contentBounds == (256,256,256,256)`; result tile (0,0) `sharesStorage(with:)` source tile (1,1). Unaligned case (b) above → no result tile shares storage.
  - `largeSparseImage`: 65,535×300 transparent with `(1,2,3,255)` at (40000,10) and `(4,5,6,255)` at (59999,209) → `(40000,10,20000,200)`; result 20,000×200, (0,0) == `(1,2,3,255)`, (19999,199) == `(4,5,6,255)`.
  - `selectionRepositioned`: case `allFourSidesTrimmed` (R = (2,3,7,4)) with selection rect (0,0,5,5) → new selection `canvasSize == 7×4`, bounds `(0,0,3,2)`; with `Selection.all` → bounds `(0,0,7,4)`, `mask.isFull`; no selection → `nil`.
  - `selectionOutsideBecomesNil`: same image, selection rect (10,0,2,2) → `croppedState.selection == nil`.
  - `historyItemNameAndIcon`: `makeHistoryItem` → `name == "Auto-Crop"`, `icon == .autoCrop`, `change == .structure`; `HistoryIcon(rawValue: "autoCrop") == .autoCrop`.
- **Round-trip / property — `PaintDotMacTests/Operations/AutoCropPropertyTests.swift`** (50 seeded iterations, seed printed): random size 1…700 per side, 1–3 layers (random visibility/opacity/blend among implemented modes), background either opaque random colour or transparent, content painted in a random rect with sparse random pixels including its four extreme rows/columns:
  - `randomBoundsMatchOracle`: oracle in the test target = `CPUCompositor().composite(image, in: full rect)` (0012, already tested), take pixel 0 as reference, naive double loop with the `matches` rule written out inline in the test (not calling `AutoCrop.matches`) → expected bounds (or nil) == `contentBounds`; `cropRect` nil iff oracle nil or full canvas.
  - `randomApplyRevertIdentity`: when an item exists, `apply` then `revert` gives a state equal to the original (sizes, every pixel via `readPixels`, layer properties, selection mask), `apply` again equals the first result; every result layer pixel `(i, j)` equals source `(R.x+i, R.y+j)`.
- **Integration — `PaintDotMacTests/Operations/AutoCropIntegrationTests.swift`**: `undoRedoRoundTrip` — `UndoBridge` with a 1000×700 "New Image" white state, perform a `TileDiffHistoryItem` "Paintbrush" painting `(255,0,0,255)` on rect (100,100,50,50), a `SelectionHistoryItem` "Rectangle Select" (120,120,200,200), then `runAutoCrop(bridge:gestureInProgress: false, isBusy: false, hasSheet: false)` → history names exactly `["New Image","Paintbrush","Rectangle Select","Auto-Crop"]`, `state.image.size == 50×50`, selection bounds `(20,20,30,30)`, `onStateChange` received `.structure`; `undo()` → 1000×700, pixels and selection equal the pre-crop state; `redo()` → equals the cropped state.
- **Hosted — `PaintDotMacTests/Document/AutoCropCommandTests.swift`** (`@MainActor`, real `UndoBridge`): `ignoredWhenDisabled` (each of `gestureInProgress`, `isBusy`, `hasSheet` true → `prepareForNavigation` not called, no step, state unchanged); `commitsPendingEditFirst` (`prepareForNavigation` = closure performing a `TileDiffHistoryItem` named "Finish Pixels" that paints `K` at (5,5) on a uniform 20×20 `W` image → history ends `[…, "Finish Pixels", "Auto-Crop"]`, size 1×1); `noOpAddsNoStep` (uniform 20×20 → closure called once, history count unchanged, document not edited).
- **Menu / shortcuts:** `PaintDotMacTests/App/MainMenuTests.swift` — `imageMenuItems` == the exact list in Scope item 6 with Auto-Crop as `("Auto-Crop", "x", [.command, .option], autoCrop:, menu.image.autoCrop)` at index 1; `PaintDotMacTests/Shortcuts/ShortcutTableTests.swift` — add `imageRowsIncludeAutoCrop` (`entry(id: "image.autoCrop")`: action "Auto-Crop", menu identifier `menu.image.autoCrop`, binding display "⌥⌘X", status `.macStandard`, placed directly after `image.cropToSelection` in `entries`) and update `everyRowLiteral`; 0045's conflict tests (`menuChordsUnique`, reserved-chord check) stay green on the real table; `ShortcutDocsTests.docsFileMatchesTable` with the regenerated `docs/shortcuts.md`.
- **UI — `PaintDotMacUITests/AutoCropUITests.swift`** (fixture `UITestFixtures.writePNG` 40×30, 96 DPI: `W` everywhere except x ∈ 10…24, y ∈ 5…19 → `(x·8, y·8, 128, 255)`; launched with `-UITestOpen`, `-UITestResetDefaults`; saved PNGs decoded the way 0036/0037's UI tests do):
  - `testMenuItemPresentAndEnabled`: open the Image menu → the item after "Crop to Selection" is "Auto-Crop" and is enabled with no selection; Escape.
  - `testAutoCropViaMenuThenUndoRedo`: note `statusBar.zoom`; Image ▸ Auto-Crop → `statusBar.imageSize` "15 × 15", zoom unchanged, last `historyRow.*` label "Auto-Crop"; ⌘S, decode → 15×15, (0,0) == `(80,40,128,255)`, (14,14) == `(192,152,128,255)`, (14,0) == `(192,40,128,255)`; ⌘Z → "40 × 30", that row's value "undone"; ⇧⌘Z → "15 × 15".
  - `testShortcutAndSecondAutoCropIsNoOp`: ⌥⌘X → "15 × 15"; count `historyRow.*`; ⌥⌘X again → count unchanged, size still "15 × 15".
  - `testUniformImageIsNoOp`: fixture 20×20 all `(50,60,70,255)`; ⌥⌘X → "20 × 20", the History list has only its base row.
  - `testSelectionFollowsCrop`: launch with `-UITestSelectRect 0,0,20,10`; ⌥⌘X → `statusBar.selectionSize` "10 × 5" (pixels (10…19, 5…9)); ⌘Z → "20 × 10".
- **Performance — `PaintDotMacTests/Performance/AutoCropPerformanceTests.swift`** (XCTest `measure`): `content4000x3000ThreeLayers` (gate 900 ms), `wideSparse` (gate 900 ms). Report the numbers.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Take a macOS window screenshot with shadow (transparent margin), open it, press ⌥⌘X: the transparent margin up to the outermost shadow pixel is removed; the window keeps its zoom and the image is centred; ⌘Z restores it.
  2. Open a logo on a solid white background (PNG): Image ▸ Auto-Crop trims the white to the logo; the History row shows the Auto-Crop icon.
  3. Open the same logo saved as a JPEG (quality ~80): note whether compression noise prevents trimming (expected with exact matching, Open question 3) and report it.
  4. Layered `.ora` with a hidden layer that has content in the border: Auto-Crop, then show the hidden layer — its border content is gone; ⌘Z brings it back.
  5. With Move Selected Pixels mid-move, press ⌥⌘X: "Finish Pixels" then "Auto-Crop" appear as two History rows.
  6. ⌥⌘X shows next to the menu item and works on a non-US keyboard layout (e.g. German); note any difference in `docs/shortcuts.md`.

## Open questions

Recommended answers are applied in this spec; the user must confirm (they are product questions not answered by PRD §12).

1. **Paint.NET parity and shortcut.** Paint.NET's current docs (Image menu, keyboard reference, change log, fetched 2026-11-08) do not list an Auto-Crop command or Ctrl+Alt+X, so "mirror Paint.NET 4.2+ Auto-Crop, Ctrl+Alt+X" could not be verified. Recommended: ship it as a PaintDotMac addition named **"Auto-Crop"** with **⌥⌘X** (free: no menu, single-key, or macOS-reserved conflict; pairs with Crop to Selection ⇧⌘X), `ShortcutTable` status `.macStandard`, Paint.NET column "—". If you know Paint.NET's binding is Ctrl+Alt+X, switch the row to `.matchesPaintNET` / "Ctrl + Alt + X" (same chord). Needs a PRD §5.12 row either way.
2. **Which pixel defines the border colour.** Recommended: the **top-left pixel of the composite image**; trim the bounding box of everything that differs from it. Consequence: a border only on the right/bottom with content covering the top-left pixel is not trimmed (or the content block is treated as border). Alternative: GIMP's corner rule (use the top-left colour if it equals the top-right or bottom-left corner, else the bottom-right colour if it equals the top-right or bottom-left, else nothing to trim).
3. **Tolerance.** Recommended: **exact match** (all four channels; any alpha-0 pixel matches an alpha-0 border), no dialog and no option — deterministic and right for screenshots/PNGs, but JPEG borders with compression noise won't trim. Alternative: a fixed tolerance using the Magic Wand's Paint.NET 3.36 metric (D-43), e.g. 10%.
4. **Selection after Auto-Crop.** Recommended: keep it on the same pixels, clipped to the new canvas (0036's `repositioned`), `nil` when it lay entirely in the trimmed border — consistent with Crop to Selection (0022) and Canvas Size (0036). Alternative: always deselect.
5. **Feedback when there is nothing to trim.** Recommended: the menu item stays enabled; the command does nothing (no step, no alert, no beep), like Crop to Selection after Select All. Alternative: `NSSound.beep()`.
6. **Menu position.** Recommended: directly after Crop to Selection (both are crops). Alternative: after Canvas Size… or before Flatten.

## Out of scope

- Crop to Selection (0022), Resize Image (0035), Canvas Size (0036), Flip/Rotate (0037), Flatten (0024); layer-only flip/rotate/zoom (0060).
- A tolerance slider, per-side colours, or an "Auto-Crop dialog" (see Open questions 2–3).
- Auto-cropping a single layer or a selection; trimming by alpha only.
- PRD.md / AGENTS.md edits (orchestrator).
