# 0022 — Add the Image menu and Crop to Selection (⇧⌘X)

> Source: PRD.md §5.5 IMG-1 (Crop to Selection, P0); §5.12 (Crop to Selection Ctrl+Shift+X → ⇧⌘X); §5.6 E-3 / §12 D-40 (an empty selection is no selection); §5.7 H-6 / §12 D-34 (no-op edits add no step); §12 D-7 (per-document DPI); §8 M2 (Crop to Selection is in the M2 exit set, use case 1 "open a screenshot, crop it, …"); §6 NF-4 (history memory); AGENTS.md architecture rules 1–4 and 8.
> Paint.NET docs (fetched 2026-11-05; `getpaint.net/doc/latest/…` redirects to `paint.net/doc/latest/…`): Image menu — https://paint.net/doc/latest/ImageMenu.html. Paint.NET 3.36 source (last published source, for details the docs omit): `src/HistoryFunctions/CropToSelectionFunction.cs` at https://github.com/wangdeshui/paint.net/tree/master/src.
> Milestone: M2
> Depends on: 0014-rectangle-and-ellipse-select, 0021-clipboard-cut-copy-paste (`CanvasTransform.withImageSize(_:)` and the `.structure` resize hook), and through them 0001–0008, 0013, 0020

## Context

Not yet implemented. After 0001–0021 (all specs, no application code yet):

- `App/MainMenu.swift` (0001, `docs/specs/todo/0001-project-and-document-shell_TODO.md:100-143`) builds the menu bar in code; the top-level menus are `PaintDotMac, File, Edit, View, Window, Help` with identifiers `menu.app` … `menu.help`, and 0001 says: "Later specs only add items. They insert the Image, Layers, Adjustments, and Effects top-level menus, in that order, between View and Window, which is Paint.NET's order." `MainMenuTests.topLevelMenusInOrder` (0001 `:319`) asserts the list; `noDuplicateShortcuts` checks the whole tree. **This spec creates the Image menu.** Later specs append to it: 0024 Flatten (⇧⌘F), 0035 Resize Image (⌘R), 0036 Resize Canvas (⇧⌘R), 0037 Flip/Rotate.
- `LayeredImage` (0002): `size`, `dpi`, `layers: [Layer]` (bottom first), `activeLayerIndex`, `isConsistent`; `Layer` (`id`, `name`, `isVisible`, `opacity`, `blendMode`, `surface`); `TiledSurface` (256×256 copy-on-write tiles; `init(size:)`, `tile(at:)`/`setTile(_:at:)`, `readPixels(in:)`, `writePixels(_:to:)`, `pixelRect(of:)`, `releaseTransparentTiles()`, `Tile.sharesStorage(with:)`). `PixelSize`, `PixelRect` (half-open), `PixelPoint`.
- 0008 (`0008…_TODO.md:41-90`): `DocumentState`, `HistoryItem`, `HistoryIcon` (already has `.cropToSelection`), `HistoryChange.structure`, **`DocumentSnapshotHistoryItem(name:icon:before:after:)`** — explicitly reserved for "canvas-size changes (crop 0022, …)"; `apply` assigns `after`, `revert` assigns `before`; `byteCost = HistoryCost.unsharedTileBytes(before:after:)` (0013 adds the selection bytes to it). `UndoBridge` (`perform(_:)`, `prepareForNavigation`, `onStateChange`). `DocumentWindowController`'s `onStateChange` handler (0008 item 12): `.structure` → `canvasView.image = …`, `canvasView.invalidateAll()`, status-bar image size/DPI update, "no re-fit: the zoom stays". 0021 (Paste with Expand, the first canvas-size change) adds `CanvasTransform.withImageSize(_:)` in `Core/Rendering/CanvasTransform+Navigation.swift` (same zoom, re-centered, scroll-clamped; identity for an unchanged size) and extends that `.structure` branch to apply it whenever `state.image.size` differs from `transform.imageSize`; this spec reuses both unchanged.
- 0013 (`0013…_TODO.md`): `Selection` (`canvasSize`, `path` in canvas coords y-down, `mask: SelectionMask` — normative for pixels, `bounds: PixelRect { mask.bounds }` = tight bounds of pixels with coverage > 0, `init?(mask:outline:)`, `init?(rect:canvasSize:)`, `Selection.all(canvasSize:)`), `SelectionMask` (`.empty/.full/.partial` tiles, `coverage(x:y:)`, `isFull`, `init(size:coverage:)`, `init(size:tiles:)`, `tile(at:)`, out-of-canvas bytes 0), `DocumentState.selection: Selection?` (`nil` = no selection; never an empty `Selection`), invariant `selection == nil || selection.canvasSize == image.size` — "Operations that change the canvas size (0022, 0035–0037) are responsible for transforming or dropping the selection in their snapshot." Edit-menu actions in `DocumentWindowController` follow the pattern: ignore while `AppModel.dispatcher.isGestureInProgress`; call `undoBridge.prepareForNavigation?()`; build the item from `undoBridge.state`; `undoBridge.perform(item)`. `MarchingAntsOverlay.update` runs on `.structure`. Debug hook `-UITestSelectRect x,y,w,h`.
- 0014: Rectangle/Ellipse Select tools, `StatusBarModel.selectionSize` refreshed on every `onStateChange`; `CanvasTransform+Navigation` (0004) has `clampedScroll()` and `fittedToWindow()`.
- 0009: `BlendOps.mul255(a, b) == (a·b + 127) / 255`.

**Paint.NET behavior mirrored** (ImageMenu.html, quoted): "This menu contains commands that affect all layers in the current image." "**Crop to Selection** … This menu item is only available if a selection is active. Clicking this menu item will cause the current image to be cropped and replaced by the area that was selected. If the selection is not rectangular or square, the bounding rectangle minimally surrounding the selection will be used. Pixels outside the selection will be made transparent with the color information removed." Paint.NET's Image menu order is: Crop to Selection, Resize, Canvas Size, Flip Horizontal, Flip Vertical, Rotate 90° Clockwise, Rotate 90° Counter-Clockwise, Rotate 180°, (Color Profile), Flatten. PRD §5.12 gives ⇧⌘X.

Paint.NET 3.36 `CropToSelectionFunction.cs` (verified): bounding box = `GetRegionBounds(selection)`; new document of that size; each layer copied from the bounding box; the region `boundingBox − selection` is cleared to transparent; layer properties kept; one compound history step (document replacement + the selection before). 3.36 clears to transparent *white* and works on hard region edges; the current docs say "with the color information removed", and PaintDotMac selections are antialiased 8-bit masks, so this spec defines the antialiased rule below (see Open question 1).

## User story

As a PaintDotMac user, I select part of a screenshot (rectangle, ellipse, lasso, or magic wand), choose **Image > Crop to Selection** or press ⇧⌘X, and the image (every layer) shrinks to the selection's bounding box; with a non-rectangular selection, everything outside the selection becomes transparent (soft-edged where the selection is antialiased). The selection stays on the same pixels. The History panel shows one "Crop to Selection" step; ⌘Z restores the original size, pixels, and selection exactly, and ⇧⌘Z crops again. Without a selection the command is disabled.

## Scope & changes

### Core (pure Swift, headless, unit-tested; no AppKit/SwiftUI imports)

1. **`Core/Operations/CropToSelection.swift`** (new):
   ```swift
   public enum CropToSelection {
       public static let name = "Crop to Selection"          // menu title and history step name (Paint.NET spelling)
       public static let icon: HistoryIcon = .cropToSelection
       /// Enabled iff the document has a selection (Paint.NET: "only available if a selection is active").
       public static func isEnabled(in state: DocumentState) -> Bool        // state.selection != nil
       /// The crop rectangle: the selection's tight mask bounds (every pixel with coverage > 0), in canvas pixels.
       public static func cropRect(for state: DocumentState) -> PixelRect?   // nil when no selection
       /// The cropped state, or nil when disabled or when the crop would change nothing (H-6).
       public static func croppedState(_ state: DocumentState) -> DocumentState?
       /// DocumentSnapshotHistoryItem(name: name, icon: icon, before: state, after: croppedState) or nil.
       public static func makeHistoryItem(for state: DocumentState) -> DocumentSnapshotHistoryItem?
       /// Per-pixel rule (exposed for tests): the source pixel kept with selection coverage c.
       public static func masked(_ pixel: ColorRGBA8, coverage c: UInt8) -> ColorRGBA8
   }
   ```
   - **Crop rectangle** `R = selection.bounds` (0013's `mask.bounds`: union of `.full` tile rects clipped to the canvas and the tight non-zero rows/columns of `.partial` tiles). Any pixel with coverage ≥ 1 is inside `R`. It is never empty (0013 never stores an empty selection) and always inside the canvas, so `1 ≤ R.width ≤ old width`, likewise height: no `ImageLimits` check or alert is needed.
   - **No-op rule (H-6, D-34):** if `R == image.size.bounds` **and** `selection.mask.isFull`, nothing would change → `croppedState` returns `nil`, `makeHistoryItem` returns `nil`, and the command adds no step. (Select All then ⇧⌘X does nothing.) If `R` is the whole canvas but the mask is partial (an ellipse touching all four edges), it is *not* a no-op: pixels outside the ellipse become transparent.
   - **Per-pixel rule** `masked(p, coverage: c)`: `c == 255` → `p` unchanged; otherwise `a' = BlendOps.mul255(p.alpha, c)`; `a' == 0` → `ColorRGBA8.clear` `(0,0,0,0)` ("color information removed"); else `(p.r, p.g, p.b, a')` (straight alpha: color kept, only alpha scaled — the same convention as 0011's `EraseOps`). So unselected pixels (`c == 0`) become `(0,0,0,0)`, fully selected pixels are bit-identical, and antialiased edge pixels keep their color with proportionally reduced alpha.
   - **Layers:** every layer, in order, **including hidden layers** ("affect all layers"), gets a new `TiledSurface(size: R.size)` holding `masked(old.pixel(R.x + i, R.y + j), coverage: mask.coverage(R.x + i, R.y + j))` at `(i, j)`. `id`, `name`, `isVisible`, `opacity`, `blendMode` are kept unchanged (same `Layer.ID`, so the Layers panel keeps its row identity), `activeLayerIndex` is kept, `dpi` is kept (D-7). Result `LayeredImage(size: R.size, dpi: old.dpi, layers:…, activeLayerIndex:…)` satisfies `isConsistent`.
   - **Tile reuse (memory, NF-4):** when `R.x` and `R.y` are both multiples of 256, a destination tile whose source tile rect lies entirely inside `R` and whose mask tile is `.full` is assigned the **same** `Tile` (`setTile(old.tile(at: src), at: dst)`, storage shared, including `nil` for unallocated source tiles). Every other destination tile is built by reading the source rect (`readPixels(in:)`, out-of-canvas = 0), applying `masked` per pixel with the mask coverage (fast paths: mask tile `.full` → copy bytes; `.empty` → the tile stays unallocated), and writing it; finish with `releaseTransparentTiles()` so wholly transparent destination tiles are unallocated. Per-tile work may run concurrently (`DispatchQueue.concurrentPerform` over destination tiles; results are per-pixel independent, so bit-identical); writes into the surface happen serially afterwards.
   - **Selection after the crop** (translated, not dropped): `newSelection = selection.translatedAndCropped(to: R)` (item 2). Because `R` contains every selected pixel, the new mask holds exactly the old coverage values at their new positions; a rectangular selection with integer edges becomes a full-canvas selection (`mask.isFull`). It is never `nil` (R contains ≥ 1 selected pixel).
   - Result: `DocumentState(image: newImage, selection: newSelection)`.

2. **`Core/Model/SelectionMask.swift`** and **`Core/Model/Selection.swift`** (extend 0013; additive only):
   ```swift
   extension SelectionMask {
       /// The coverage inside `rect` (in this mask's coordinates), moved to the origin; size = rect.size.
       /// Precondition: rect is non-empty and inside 0..<size. Tiles reused (same storage) when rect.x/rect.y
       /// are multiples of 256 and the source tile lies fully inside rect; otherwise per-pixel copy; normalized.
       public func cropped(to rect: PixelRect) -> SelectionMask
   }
   extension Selection {
       /// canvasSize = rect.size; mask = mask.cropped(to: rect);
       /// path = path transformed by translate(−rect.x, −rect.y), intersected with the new canvas rect.
       /// nil when the cropped mask is empty.
       public func translatedAndCropped(to rect: PixelRect) -> Selection?
   }
   ```
   0024/0035–0037 may reuse these; they don't change 0013's existing API.

3. **View after the crop:** no new code. 0021's `CanvasTransform.withImageSize(_:)` and its `.structure` hook keep the zoom and re-center the cropped image, for the crop and for its undo/redo (Open question 2).

### Platform glue (AppKit; UI tests and manual checks)

4. **`App/MainMenu.swift`** (extend 0001): new top-level menu **"Image"**, identifier `menu.image`, inserted **after View and before Window**. One item for now:
   | Item title | Key | Modifiers | Action | Identifier |
   |---|---|---|---|---|
   | Crop to Selection | `x` | ⇧⌘ | `cropToSelection(_:)` | `menu.image.cropToSelection` |
   Target `nil` (first responder). Add a comment that 0024 (Flatten), 0035 (Resize…), 0036 (Canvas Size… / Resize Canvas), and 0037 (Flip/Rotate) append their items in Paint.NET order after this one, and that 0024's Layers, 0031's Adjustments and Effects menus go between Image and Window. Update `MainMenuTests.topLevelMenusInOrder` to `["PaintDotMac", "File", "Edit", "View", "Image", "Window", "Help"]` (identifiers incl. `menu.image`) and add `imageMenuItems`.

5. **`Document/DocumentWindowController.swift`** (extend):
   - `@objc func cropToSelection(_ sender: Any?)` → `Self.runCropToSelection(bridge: undoBridge, gestureInProgress: AppModel.shared.dispatcher.isGestureInProgress)`.
   - `@MainActor static func runCropToSelection(bridge: UndoBridge, gestureInProgress: Bool)` (static so a hosted unit test can drive it without a window): if `gestureInProgress` → return; `bridge.prepareForNavigation?()` (reason `.command`, 0020: floating pixels record **"Finish Pixels"** first; 0038–0040 shapes/text commit their pending edit — so the crop uses the committed pixels and the committed selection); then `if let item = CropToSelection.makeHistoryItem(for: bridge.state) { bridge.perform(item) }`.
   - `validateMenuItem(_:)`: `cropToSelection(_:)` enabled iff `!isGestureInProgress && CropToSelection.isEnabled(in: undoBridge.state)`.
   - `onStateChange` `.structure` branch: unchanged here; 0021's size check applies `withImageSize`, so the zoom percentage stays and the cropped image is re-centered and scroll-clamped (no automatic Zoom to Window — ⌘B if wanted; Open question 2). Undo restores the original size centered at the same zoom. Marching ants (0013) and the status-bar selection size (0014) already refresh on `.structure`.

6. `project.yml`: no target changes; run `xcodegen generate` (new files). PRD.md / AGENTS.md: no edits in this spec (sub-agent rule); the decisions below to confirm are listed under Open questions.

### Performance (NF-1, NF-4)
- Crop is O(destination pixels) with a full-tile fast path; NF-4: a crop step costs the destination tiles that don't share storage with the source plus the source tiles no longer referenced (0008's `unsharedTileBytes`), plus 0013's selection bytes. Target: 4000×3000 single opaque layer, rectangle selection (1000, 700, 2000, 1500) (unaligned) → `croppedState` < 150 ms in the Debug test build, gated at 3× (450 ms). Report the measured number in the Verification status.

## Acceptance criteria

- [ ] The menu bar has a top-level **Image** menu between View and Window containing **Crop to Selection** ⇧⌘X with action `cropToSelection(_:)`; no shortcut duplicates. → `MainMenuTests.topLevelMenusInOrder` (updated), `.imageMenuItems`, `.noDuplicateShortcuts`; UI `CropToSelectionUITests.testMenuEnablement`
- [ ] Crop to Selection is disabled without a selection and enabled with one (and disabled mid-gesture). → `CropToSelectionTests.enablement`, `CropToSelectionCommandTests.ignoredDuringGesture`; UI `testMenuEnablement`
- [ ] With a rectangular selection, every layer becomes exactly the selected rectangle's pixels; size = rectangle size. → `CropToSelectionTests.rectangleCropsAllLayers`; UI `testCropRectangleSelection`
- [ ] With a non-rectangular selection, the canvas is the tight bounding box of every pixel with coverage > 0; pixels with coverage 0 become `(0,0,0,0)`; partially covered pixels keep their color with alpha `mul255(a, c)`; fully covered pixels are unchanged. → `CropToSelectionTests.nonRectangularMaskHandValues`, `.maskedPixelRule`, `.boundingBoxIncludesCoverageOne`, `.ellipseCropMatchesOracle`; UI `testCropEllipseSelection`
- [ ] Hidden layers are cropped too; layer ids, names, visibility, opacity, blend mode, active layer index, and DPI are preserved. → `CropToSelectionTests.layerPropertiesAndDPIKept`
- [ ] After the crop the selection covers the same pixels, translated to the new origin (a rectangle becomes a full-canvas selection). → `CropToSelectionTests.selectionIsTranslated`, `SelectionCropTests.*`
- [ ] One history step "Crop to Selection" (icon `.cropToSelection`, change `.structure`); undo restores the original size, every pixel, layer list, and selection exactly; redo restores the cropped state exactly; Select All + crop adds no step. → `CropToSelectionTests.historyItemNameAndIcon`, `.noOpWhenSelectAll`, `CropToSelectionIntegrationTests.undoRedoRoundTrip`, `CropToSelectionPropertyTests.randomCropsRoundTrip`; UI `testCropUndoRedo`
- [ ] A pending tool edit is committed before cropping, and the crop sees the committed state. → `CropToSelectionCommandTests.commitsPendingEditFirst`
- [ ] After a crop (and its undo/redo) the view keeps its zoom, re-centers the new image, and the status bar shows the new image size. → `CropToSelectionIntegrationTests.undoRedoRoundTrip` (`.structure` received), 0021's `CanvasTransformNavigationTests.withImageSize*` (reused); UI `testCropRectangleSelection` (`statusBar.imageSize`, `statusBar.zoom`), `testCropUndoRedo`
- [ ] Memory accounting: aligned full tiles are shared, not copied. → `CropToSelectionTests.alignedFullTilesShareStorage`, `.historyCostCountsOnlyUnsharedTiles`
- [ ] Performance target met within the 3× gate. → `CropToSelectionPerformanceTests.crop4000x3000`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **No selection / no document:** menu item disabled; `makeHistoryItem` returns `nil`; the action is a no-op if invoked anyway (e.g. via a stale menu). No document window → no target → AppKit disables it. → `CropToSelectionTests.enablement`
- **Select All (or a full-canvas integer rectangle):** no-op, no step, document stays clean. → `CropToSelectionTests.noOpWhenSelectAll`
- **Full-canvas bounding box with a partial mask** (ellipse inscribed in the canvas): same size, corners become transparent, one step. → `CropToSelectionTests.fullBoundsPartialMaskIsNotNoOp`
- **1×1 crop** (single selected pixel, coverage 1): result 1×1, pixel `(r,g,b, mul255(a,1))` (0 → `(0,0,0,0)`), selection 1×1 with coverage 1. → `CropToSelectionTests.onePixelCrop`
- **1×1 image with Select All:** no-op. → covered by `noOpWhenSelectAll` (1×1 case)
- **Disjoint multi-part selection** (two separated rectangles, e.g. via Union): bounding box spans both; the gap becomes transparent. → `CropToSelectionTests.disjointSelectionGapIsTransparent`
- **Crop rect crossing tile seams at unaligned offsets** (e.g. (255, 255, 3, 3), (100, 300, 600, 300)): pixels correct on every side of each seam. → `CropToSelectionTests.unalignedTileSeams`
- **Transparent and semi-transparent source pixels:** `(10,20,30,0)` with c = 255 stays `(10,20,30,0)` (D-33: color under alpha 0 preserved when fully selected); with c < 255 → `(0,0,0,0)`; `(10,20,30,1)` with c = 128 → `mul255(1,128) = 1` → `(10,20,30,1)`; with c = 127 → `mul255(1,127) = 0` → `(0,0,0,0)`. → `CropToSelectionTests.maskedPixelRule`
- **Sparse/unallocated source tiles** stay unallocated in the result; wholly cleared destination tiles are released. → `CropToSelectionTests.sparseTilesStaySparse`
- **Large image** (65,535 × 300, selection (40,000, 10, 20,000, 200)): completes, correct pixels at the four corners of the result, no full-image buffer allocated (only per-tile buffers). → `CropToSelectionTests.wideImageCrop`
- **Mid-gesture ⇧⌘X:** ignored (`isGestureInProgress`). → `CropToSelectionCommandTests.ignoredDuringGesture`
- **Pending edit (floating pixels, uncommitted shape/text):** committed first, then cropped — two steps (the commit's step, then "Crop to Selection"). → `CropToSelectionCommandTests.commitsPendingEditFirst`
- **Undo after crop with a different active layer or zoom:** undo restores size and layers; zoom stays as the user left it; the image is re-centered. → `CropToSelectionIntegrationTests.undoRedoRoundTrip`, UI `testCropUndoRedo`
- **Undo budget** (H-5): the step's cost is fixed at init and counted like any snapshot item; dropping it from the oldest end is handled by 0008. No special case.

## Test plan

Expected values are hand-computed below or come from the simple oracle in the test target; never from running the code under test. `mul255(a,b) = (a·b + 127) / 255`.

- **Unit tests — `PaintDotMacTests/Operations/CropToSelectionTests.swift`** (Swift Testing). Helper: `layer(_ size, _ f: (x, y) -> ColorRGBA8)` via `TestImages.surface`; selections via `Selection(rect:canvasSize:)` or `Selection(mask: SelectionMask(size:coverage:), outline: CGPath(rect: …))`.
  - `enablement`: `DocumentState` 8×6 without selection → `isEnabled == false`, `cropRect == nil`, `makeHistoryItem == nil`, `croppedState == nil`; with `Selection(rect: (2,1,3,4))` → `isEnabled == true`, `cropRect == (2,1,3,4)`.
  - `rectangleCropsAllLayers`: 8×6, two layers: L0 `(x·10, y·10, 7, 255)`, L1 `(255−x, y, 0, 100)`; selection rect (2,1,3,4) → `image.size == 3×4`; for all `(i,j)` in 3×4: L0 pixel == `((i+2)·10, (j+1)·10, 7, 255)`, L1 == `(255−(i+2), j+1, 0, 100)`.
  - `nonRectangularMaskHandValues`: 6×6 single layer all `(200,100,50,255)`; mask coverage (1,1)=255, (3,2)=128, (2,4)=1, else 0 → `cropRect == (1,1,3,4)`; result 3×4: (0,0) `(200,100,50,255)`; (2,1) `(200,100,50,128)` (mul255(255,128)=128); (1,3) `(200,100,50,1)`; the other 9 pixels `(0,0,0,0)`.
  - `maskedPixelRule`: table — `masked((10,20,30,0), 255) == (10,20,30,0)`; `masked((10,20,30,0), 254) == (0,0,0,0)`; `masked((10,20,30,1),128) == (10,20,30,1)`; `masked((10,20,30,1),127) == (0,0,0,0)`; `masked((200,100,50,255),0) == (0,0,0,0)`; `masked((200,100,50,200),64) == (200,100,50,50)` ((200·64+127)/255 = 12927/255 = 50); plus an exhaustive check over all 65,536 (alpha, c) pairs against the formula with color (1,2,3).
  - `boundingBoxIncludesCoverageOne`: 10×10, mask 255 on (4,4)…(5,5) and coverage 1 at (9,0) → `cropRect == (4,0,6,6)`; result (5,0) == source (9,0) with alpha `mul255(a,1)`.
  - `ellipseCropMatchesOracle`: 300×280 image (seeded random colors via `SeededRandom`, seed printed), `Selection(path: CGPath(ellipseIn: (20.5, 30.25, 250, 200)), canvasSize:)` antialiased → `cropRect == selection.mask.bounds` and equals the oracle's tight bbox of coverage > 0 (computed by scanning `mask.coverage` over the whole canvas in the test); every result pixel equals the oracle `masked(src, cov)` written out in the test (independent per-pixel loop). Crosses the tile seam at x = 256.
  - `layerPropertiesAndDPIKept`: three layers (one hidden, opacity 77, names "A","B","C", fixed UUIDs), `activeLayerIndex 1`, dpi 150 → after crop the same ids/names/visibility/opacity/blendMode in the same order, `activeLayerIndex == 1`, `dpi == 150`, `isConsistent`; the hidden layer's pixels are cropped (checked at two points).
  - `selectionIsTranslated`: 8×6, rect (2,1,3,4) → `selection.canvasSize == 3×4`, `mask.isFull`, `bounds == (0,0,3,4)`. Non-rect case from `nonRectangularMaskHandValues` → new mask coverage (0,0)=255, (2,1)=128, (1,3)=1, all else 0; path bounding box translated by (−1,−1).
  - `historyItemNameAndIcon`: `makeHistoryItem` → `name == "Crop to Selection"`, `icon == .cropToSelection`, `change == .structure`, `isNoOp == false`.
  - `noOpWhenSelectAll`: `Selection.all` on 8×6 and on 1×1 → `croppedState == nil`, `makeHistoryItem == nil`; `Selection(rect: (0,0,8,6))` → nil too.
  - `fullBoundsPartialMaskIsNotNoOp`: 8×8 opaque white, mask = 255 everywhere except (0,0)=0 and (7,7)=0 but (7,0)=255,(0,7)=255 so bounds are the full canvas → item non-nil; result 8×8 with (0,0) and (7,7) `(0,0,0,0)`, (3,3) white.
  - `onePixelCrop`: 5×5 opaque `(9,8,7,255)`, coverage 1 only at (3,2) → result 1×1 pixel `(9,8,7,1)`; selection 1×1 coverage 1.
  - `disjointSelectionGapIsTransparent`: 20×10, union of rects (1,1,2,2) and (15,6,3,3) → `cropRect == (1,1,17,8)`; (0,0) == src(1,1); (16,7) == src(17,8); (7,3) `(0,0,0,0)`.
  - `unalignedTileSeams`: 600×600 with `(x%256, y%256, (x/256)·100 + (y/256)·10, 255)`; rect crops (255,255,3,3) and (100,300,500,300) → every result pixel equals the source formula at the offset position (full scan).
  - `alignedFullTilesShareStorage`: 1024×768 opaque, rect (256,256,512,512) → destination tiles (0,0),(1,0),(0,1),(1,1) `sharesStorage(with:)` the source tiles (1,1),(2,1),(1,2),(2,2). Unaligned rect (1,0,512,256) → no destination tile shares storage.
  - `historyCostCountsOnlyUnsharedTiles`: the aligned case above → `item.byteCost` == `Tile.byteCount × (source tiles only in before)` = 12 tiles (4×3 grid) − 4 shared = 8 × `Tile.byteCount` + the selection bytes per 0013's `selectionBytes(before:after:)` (both rect selections: full tiles only, so path estimates only: `before.pathByteEstimate + after.pathByteEstimate`).
  - `sparseTilesStaySparse`: 1024×1024 with only tile (3,3) allocated, rect (0,0,600,600) → result has no allocated tiles; rect (700,700,300,300) → allocated, values correct.
  - `wideImageCrop`: 65,535×300 layer filled via `fill` with one color except a marker pixel at (40,000,10) and (59,999, 209) → result 20,000×200, (0,0) and (19,999,199) markers correct.
- **Unit tests — `PaintDotMacTests/Model/SelectionCropTests.swift`**: `maskCroppedHandValues` (mask from the hand case → exact coverages), `maskCroppedReusesAlignedTiles` (partial tile storage identity kept when aligned: `tileStorageIdentities` keys overlap), `maskCroppedNormalizesFull` (rect area of a partial mask that is all 255 → `.full`, `isFull`), `maskCroppedEdgeOutOfCanvasZero` (crop to 300×257 from a 600×600 full mask → edge tiles report 255 only in-canvas, `coverage(300, 0) == 0`), `selectionTranslatedPath` (path bbox (10,20,30,40) cropped at (5,5,…) → (5,15,30,40)), `croppedToEmptyIsNil` (rect outside the coverage → `nil`).
- **Round-trip / property tests — `PaintDotMacTests/Operations/CropToSelectionPropertyTests.swift`**: `randomCropsRoundTrip` — 50 seeded iterations (seed printed): random image 1…700 px per side, 1–3 layers with random sparse content, random selection (rect, ellipse, or union of two) → if an item exists: `apply` then `revert` on a `DocumentState` gives an image `==` the original (sizes, every pixel via `readPixels(in: bounds)`, layer props) and an equal selection; `apply` again equals the first result; result size == oracle bbox; every result pixel == oracle `masked`.
- **Integration tests — `PaintDotMacTests/Operations/CropToSelectionIntegrationTests.swift`**: `undoRedoRoundTrip` — `UndoBridge` with a 1000×700 "New Image" white state (base `.newImage`), perform a "Paintbrush"-style `TileDiffHistoryItem` (fill rect (100,100,50,50) red), a `SelectionHistoryItem` "Ellipse Select" (ellipse in (80,90,300,200)), then `runCropToSelection(bridge:gestureInProgress: false)` → history names exactly `["New Image","Paintbrush","Ellipse Select","Crop to Selection"]`, `state.image.size == bbox size`, `onStateChange` received `.structure`; `undo()` → size 1000×700, pixels and selection equal the pre-crop state; `redo()` → equal to the cropped state; document edited state toggles per 0008.
- **Hosted unit tests — `PaintDotMacTests/Document/CropToSelectionCommandTests.swift`** (`@MainActor`): `ignoredDuringGesture` (gestureInProgress true → no step, `prepareForNavigation` not called); `commitsPendingEditFirst` (set `prepareForNavigation` to a closure that performs a `SelectionHistoryItem` moving the selection from (0,0,10,10) to (20,20,10,10) — simulating a floating-pixels commit — then the crop uses (20,20,10,10): image 10×10 equals the source at offset (20,20); history ends `[…, "Finish Pixels", "Crop to Selection"]` (the fake commit uses 0020's step name; the real floating-pixels case is 0020's `commandFinishesFirst` pattern)); `noSelectionIsNoOp` (no step, closure still called once).
- **Menu tests — `PaintDotMacTests/App/MainMenuTests.swift`** (update 0001's): `topLevelMenusInOrder` → `["PaintDotMac","File","Edit","View","Image","Window","Help"]`, identifiers include `menu.image`; `imageMenuItems` → exactly `[("Crop to Selection", "x", [.command, .shift], NSSelectorFromString("cropToSelection:"))]`, identifier `menu.image.cropToSelection`; `noDuplicateShortcuts` still passes.
- **UI tests — `PaintDotMacUITests/CropToSelectionUITests.swift`** (fixture via `UITestFixtures.writePNG`, 400×300, pixel `(x % 256, y % 256, 128, 255)`):
  - `testMenuEnablement`: launch without a selection hook → Image > Crop to Selection disabled; relaunch with `-UITestSelectRect 50,40,120,80` → enabled.
  - `testCropRectangleSelection`: launch with `-UITestSelectRect 50,40,120,80`; note `statusBar.zoom`; press ⇧⌘X → `statusBar.imageSize` value `"120 × 80"`, `statusBar.zoom` unchanged, ⌥⌘2 History shows `historyRow.1` labelled "Crop to Selection"; `canvas.marchingAnts` value `"animated"` (selection kept); ⌘S, decode the saved PNG → 120×80, (0,0) == `(50,40,128,255)`, (119,79) == `(169,119,128,255)`.
  - `testCropEllipseSelection`: open the fixture; press S, S (Ellipse Select); drag across the middle of the canvas; read `statusBar.selectionSize` (e.g. `"W × H"`); ⇧⌘X → `statusBar.imageSize` equals that string; ⌘S, decode → the four corner pixels have alpha 0 and are `(0,0,0,0)`, the center pixel is opaque.
  - `testCropUndoRedo`: rectangle hook as above; ⇧⌘X; ⌘Z → `statusBar.imageSize` `"400 × 300"`, `historyRow.1` value `"undone"`, selection ants still `"animated"`; ⇧⌘Z → `"120 × 80"`. Then ⌘A (it may or may not add a "Select All" row, since the cropped selection already covers the canvas), count the `historyRow.*` elements, press ⇧⌘X → the count is unchanged and `statusBar.imageSize` is still `"120 × 80"` (no-op crop adds no step).
- **Performance — `PaintDotMacTests/Performance/CropToSelectionPerformanceTests.swift`**: `crop4000x3000` (timed Swift Testing integration test, or XCTest `measure`): opaque 4000×3000 single layer, rect (1000,700,2000,1500) → mean < 450 ms (3× of 150 ms); report the number.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open a screenshot, Rectangle Select a region, Image > Crop to Selection: the window shows only that region at the same zoom, centered; the marching ants run around the whole (new) canvas; ⌘Z restores the full screenshot with the original selection.
  2. Ellipse Select (Antialiased) and ⇧⌘X: the corners show the checkerboard, and the ellipse edge is smooth (no jagged halo); with Pixelated the edge is hard.
  3. With two layers (once 0024 exists — otherwise skip), hide the top layer, crop, show it again: it was cropped too.
  4. With Move Selected Pixels (0020) mid-move (floating), press ⇧⌘X: the move commits first and then the crop happens, as two History rows.
  5. The Image menu sits between View and Window; ⇧⌘X is shown next to the item.

## Open questions

1. **Transparent color and antialiased edges.** Paint.NET 3.36 clears outside pixels to transparent *white* with hard region edges; the current docs say "made transparent with the color information removed". This spec uses `(0,0,0,0)` for unselected pixels and scales alpha by the coverage on antialiased edges (color kept, `(0,0,0,0)` when alpha reaches 0). Recommended: yes, as written (matches D-27's "full erase → transparent black" and 0013's antialiased masks). Needs a PRD §5.5 IMG-1 / §12 entry.
2. **Zoom after crop.** Same question as 0021's Open question 5 (one answer covers both): keep the zoom percentage and re-center the cropped image (no automatic Zoom to Window), for the crop and for its undo/redo, via 0021's `CanvasTransform.withImageSize`. Recommended: yes (predictable; ⌘B fits on demand; 0035–0037 reuse the same rule).
3. **Selection after crop.** This spec keeps the selection, translated to the new origin (a rectangle crop becomes a full-canvas selection), rather than deselecting. Recommended: yes. Needs a PRD IMG-1 note.

## Out of scope

- Other Image menu items: Flatten (0024), Resize Image (0035), Resize Canvas (0036), Flip/Rotate (0037); Auto-crop (0061, IMG-6, v1.x); Color Profile (not planned).
- Layers, Adjustments, and Effects top-level menus (0024, 0031).
- Cropping a single layer or cropping by dragging a crop rectangle tool (Paint.NET has no crop tool).
- Crop with expansion beyond the canvas (selections are always clipped to the canvas, 0013).
- Moving all shortcuts into `ShortcutTable` (0045).
