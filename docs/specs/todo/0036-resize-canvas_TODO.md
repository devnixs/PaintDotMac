# 0036 — Change the canvas size (⇧⌘R) with a 9-position anchor, by percentage, pixel size, or print size

> Source: PRD.md §5.5 IMG-3 ("Resize Canvas: anchor grid and new dimensions", P0); §5.12 (Resize Image / Canvas Ctrl+R / Ctrl+Shift+R → ⌘R / ⇧⌘R); §5.6 E-6 (the expand-canvas fill rule decided in 0021, reused here); §5.1 APP-10 / §12 D-8, D-32 (image limits, refused with an alert); APP-5 / §12 D-7 (per-document DPI); APP-9 / D-30 (DPI range 1–10,000); §5.7 H-6 / §12 D-34 (no-op edits add no step); E-3 / D-40 (an empty selection is no selection); NF-4 (history memory), NF-9 (straight 8-bit storage); §8 M4 ("Resize Image, Resize Canvas, rotate and flip"); AGENTS.md architecture rules 1–4 and 7.
> Paint.NET docs (fetched 2026-11-07; `getpaint.net/doc/latest/…` redirects to `paint.net/doc/latest/…`): Image menu, "Canvas Size" section — https://paint.net/doc/latest/ImageMenu.html. Quoted below.
> Milestone: M4
> Depends on: 0035-resize-image (`ResizeImageForm`, `ResizeBy`, `PrintUnit`, `ResizeImageValidationError`, the sheet/menu/validation pattern, the Image menu slot), and through it 0002 (`TiledSurface`, `Tile`, `ImageLimits`), 0004 (`MeasurementUnit`, `AppSettings`), 0007 (`ColorSelection` secondary color), 0008 (`DocumentSnapshotHistoryItem`, `HistoryIcon.resizeCanvas`, `UndoBridge`), 0013 (`Selection`, `SelectionMask`), 0019 (`SelectionMask.translated`), 0020/0021 (floating pixels, `prepareForNavigation`, `PastePlanner.expandedState`, `CanvasTransform.withImageSize(_:)` + `.structure` hook), 0022 (Image menu, `Selection.translatedAndCropped`), 0024 (layers, Flatten as the last Image item), 0031 (`UndoBridge.isBusy`, menu rule shape).

## Context

Not yet implemented (specs only, no application code). What exists after 0001–0035:

- **Tiles (0002, `0002…_TODO.md:100-130`)**: `TiledSurface(size:)`, `tile(at:)`/`setTile(_:at:)`, `pixelRect(of:)` (tile rect clipped to bounds), `tileCoordinates(intersecting:)`, `readPixels(in:)` (outside bounds / unallocated → zero), `writePixels(_:to:)` (clipped), `fill(_:in:)` (fully covered tiles share **one** `Tile` value; all-zero fill releases tiles), `releaseTransparentTiles()`, `Tile.sharesStorage(with:)`. **Invariant (`:113`): edge tiles are full 256×256 tiles whose pixels outside `bounds` are always `(0,0,0,0)`.** This constrains tile sharing below.
- **`ImageLimits.validate(width:height:format:) throws(ImageLimitError) -> Int`** (0002 `:91`; "0035/0036 (resize) call the same `validate`"); `PaintDocument.imageLimits` honours `-UITestMemoryCapBytes`.
- **History (0008)**: `HistoryIcon.resizeCanvas` already exists (`0008…_TODO.md:53`; 0010 maps it to SF Symbol `aspectratio`, `0010…_TODO.md:105`). `DocumentSnapshotHistoryItem(name:icon:before:after:)`, `change == .structure`, `byteCost = HistoryCost.unsharedTileBytes(before:after:)` (+ 0013's selection bytes). M3 rule: every canvas-size command calls `undoBridge.prepareForNavigation?()` first; snapshot ops assume `floatingPixels == nil` and carry the selection.
- **0021 E-6 expand (`0021…_TODO.md:109-142`)**: `PastePlanner.expandedState(_:to:background:limits:) throws(ImageLimitError) -> DocumentState` grows every layer anchored **top-left**; "the bottom layer's new area is the **secondary color** and every other layer's new area is transparent — Paint.NET's Resize Canvas convention. 0036 … must use the same rule and may refactor `expandedState` to call its `ResizeCanvas` with anchor top-left; the behavior must stay the same." Its after-state has `selection = nil`; dpi, layer properties and `activeLayerIndex` kept. Test `PastePlannerTests.expandedStateFillsBottomLayer` (`:277`) pins the behavior. The app reads the color from `AppModel.shared.colors.secondary` (`:194`).
- **View (0021 `:167-168,195`)**: `CanvasTransform.withImageSize(_:)` keeps the zoom and re-centres; the `.structure` branch of `onStateChange` applies it whenever the size changes (also on undo/redo). Reused unchanged.
- **Selections**: 0013 `Selection` (`canvasSize`, `path` y-down, `mask` normative for pixels, `init?(mask:outline:)`, never empty; `nil` = no selection); 0019 `SelectionMask.translated(dx:dy:)` (same size, tile-aware when offsets are multiples of 256); 0022 `SelectionMask.cropped(to:)` / `Selection.translatedAndCropped(to:)` (rect must lie inside the canvas — so neither handles a *growing* canvas; this spec adds one helper that does both).
- **0035 (`0035-resize-image_TODO.md`)**: `ResizeImageForm` (all size/percentage/aspect/print-size/resolution arithmetic and validation, exact messages), `ResizeBy`, `PrintUnit`, `ResizeImageValidationError`, `ResizeImageRequest`, `UI/ResizeImageDialog.swift` (sheet via `NSHostingController`), `ResizeImageCommand`, `ResizeImageCommand.begin(bridge:gestureInProgress:hasSheet:unit:)` entry pattern, menu item "Resize…" ⌘R with identifier `menu.image.resizeImage` and the comment "0036 inserts 'Canvas Size…' after it", and `Core/Operations/ImageCommandRule.swift` — `ImageCommandRule.isEnabled(hasDocument:isGestureInProgress:isBusy:hasSheet:)` (document open, no gesture, not busy, no sheet), tested by `ImageCommandRuleTests.enablement`.
- **Image menu today**: Crop to Selection ⇧⌘X, Resize… ⌘R, separator, Flatten ⇧⌘F.

**Paint.NET behavior mirrored** (ImageMenu.html, "Canvas Size", quoted): "This command enlarges or shrinks the canvas without affecting the size of the image on it." "Canvas Size works similarly to the Resize dialog, but adds an Anchor selector and removes the Resampling options." "The anchor determines the point the canvas will be enlarged/reduced from." "If the canvas size is reduced, the edges of the existing image outside of the new area will be cropped." "When enlarging the Fill dropdown specifies which color will be used to fill any new areas" (Paint.NET 5: Transparent, Primary Color, Secondary Color, White, Black). Shortcut Ctrl+Shift+R (PRD §5.12). The menu applies to all layers ("This menu contains commands that affect all layers in the current image"). The docs give no rounding rule for a centred anchor with an odd size difference and say nothing about the selection; both are decided below (Open questions 2 and 3). Paint.NET 5's Fill dropdown is **not** adopted: PaintDotMac keeps the classic Paint.NET rule already decided for E-6 in 0021 (secondary color on the bottom layer, transparent on the others) — Open question 1.

## User story

As a PaintDotMac user, I press ⇧⌘R (Image ▸ Canvas Size…), enter a new width/height in pixels (or a percentage, or a print size with a resolution), click one of nine anchor squares (centre by default), and click OK. Every layer keeps its pixels unscaled: growing adds a border (the secondary color on the bottom layer, transparent on the other layers) around the side opposite the anchor; shrinking crops the edges away from the anchor. My selection stays on the same pixels. The zoom stays, the image re-centres, the status bar shows the new size, and History shows one "Canvas Size" step that ⌘Z undoes exactly. Sizes beyond the image limits show an alert instead of crashing.

## Scope & changes

### Core — the operation (pure, headless, unit-tested)

1. **`Core/Operations/ResizeCanvas.swift`** (new):
   ```swift
   /// The nine anchor positions (Paint.NET "Anchor"); raw values frozen.
   public enum CanvasAnchor: String, CaseIterable, Sendable {
       case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
       public var displayName: String      // "Top Left", "Top", "Top Right", "Left", "Middle", "Right",
                                           // "Bottom Left", "Bottom", "Bottom Right" (Paint.NET AnchorEdge names)
       public var column: Int              // 0 left, 1 centre, 2 right
       public var row: Int                 // 0 top, 1 middle, 2 bottom
       public init(column: Int, row: Int)  // precondition 0...2 each; grid order = allCases order (row-major)
   }

   public struct ResizeCanvasRequest: Equatable, Sendable {
       public var size: PixelSize
       public var dpi: Double              // finite, 1…10,000
       public var anchor: CanvasAnchor
   }

   public enum ResizeCanvasError: Error, Equatable, Sendable { case limitExceeded(ImageLimitError) }

   public enum ResizeCanvas {
       public static let name = "Canvas Size"          // history step + dialog title (Paint.NET spelling)
       public static let menuTitle = "Canvas Size…"    // Image menu item (U+2026)
       public static let icon: HistoryIcon = .resizeCanvas

       /// Where the old image's top-left lands in the new canvas (y down). Per axis, d = new − old:
       /// column/row 0 → 0; 1 → d / 2 (Swift integer division, truncates toward zero); 2 → d.
       public static func offset(from old: PixelSize, to new: PixelSize, anchor: CanvasAnchor) -> PixelPoint

       /// One layer surface placed at `offset` in a canvas of `size`. Pixels that land outside are cropped;
       /// the new area (canvas minus the placed old rect) is `fill` (all-zero fill = transparent, no tiles).
       public static func placed(_ surface: TiledSurface, in size: PixelSize, offset: PixelPoint,
                                 fill: ColorRGBA8) -> TiledSurface

       /// Every layer placed; bottom layer (index 0) new area = `background`, other layers transparent.
       /// Layer ids, names, visibility, opacity, blend mode, activeLayerIndex kept; dpi unchanged. No limit check.
       public static func resizedImage(_ image: LayeredImage, to size: PixelSize, anchor: CanvasAnchor,
                                       background: ColorRGBA8) -> LayeredImage

       public static func isNoOp(_ request: ResizeCanvasRequest, for state: DocumentState) -> Bool // same size && same dpi

       /// Validates request.size with `limits` before allocating, then builds the after-state
       /// (image per resizedImage, dpi = request.dpi, selection repositioned, floatingPixels nil).
       /// nil for a no-op.
       public static func resizedState(_ state: DocumentState, request: ResizeCanvasRequest,
                                       background: ColorRGBA8, limits: ImageLimits) throws(ResizeCanvasError) -> DocumentState?

       public static func makeHistoryItem(before: DocumentState, after: DocumentState) -> DocumentSnapshotHistoryItem
   }
   ```
   - **Anchor offset math (normative; Open question 2).** `dW = new.width − old.width`, `dH = new.height − old.height`. `dx = 0` (column 0), `dW / 2` (column 1), `dW` (column 2); `dy` likewise with rows. `/` is Swift `Int` division (**truncation toward zero**), so with an odd difference the extra pixel is always added at, or removed from, the **right/bottom** side: 2→5 centred adds 1 left, 2 right (`dx = 1`); 5→2 centred removes 1 left, 2 right (`dx = −1`, keeps old columns 1…2). Axes are independent (width may grow while height shrinks). Destination pixel `(x, y)` = source pixel `(x − dx, y − dy)` when that lies inside the old bounds, else the fill.
   - **`placed` algorithm (tile-aware; `placedRect = PixelRect(x: dx, y: dy, w: oldW, h: oldH) ∩ newBounds`):**
     1. `out = TiledSurface(size:)`. If `fill` is not all-zero, `out.fill(fill, in: r)` for each of the ≤ 4 rectangles of `newBounds − placedRect` (top band, bottom band, left and right strips between them) — 0002's `fill` shares one tile value for fully covered tiles, so a huge border costs O(tiles).
     2. `placedRect` is never empty: for every anchor the overlap per axis is `min(old, new) ≥ 1` (assert it). For each destination tile `T'` in `out.tileCoordinates(intersecting: placedRect)`:
        - **Aligned share:** when `dx % 256 == 0 && dy % 256 == 0`, the source tile `T = T' − (dx/256, dy/256)` is reused as-is (`setTile(source.tile(at: T), at: T')`, storage shared, `nil` stays `nil`) **iff** `source.pixelRect(of: T)` translated by `(dx, dy)` equals `out.pixelRect(of: T')` — i.e. the tile's in-bounds area maps exactly onto the destination tile's in-bounds area, so no fill pixel is needed and the edge-tile padding invariant holds on both sides. Otherwise fall through.
        - **Copy:** `src = (out.pixelRect(of: T') ∩ placedRect)` translated by `(−dx, −dy)`; if every source tile intersecting `src` is unallocated, leave `T'` as is (sparse: no allocation for transparent areas); else `out.writePixels(source.readPixels(in: src), to: dstRect)`. (Pixels beyond bounds are never written; `writePixels` clips.)
     3. Pure, synchronous, `O(destination pixels in placedRect)` byte copies; no blending (pixels are copied exactly, alpha 0 colour preserved — D-33).
   - **Fill rule (0021 E-6, unchanged):** bottom layer (`layers[0]`, whether visible or not) uses `background` — the **secondary color, stored as is** (straight RGBA, including its alpha); every other layer uses `(0,0,0,0)`. The rule applies even if the bottom layer is otherwise transparent.
   - **Selection after the resize (Open question 3):** `after.selection = state.selection?.repositioned(canvasSize: new, offset: (dx, dy))` (item 2) — the selection stays on the same pixels; parts that fall off the canvas are cut; fully cut off → `nil` (D-40). Undo restores the old selection (before-state).
   - **DPI:** `after.image.dpi = request.dpi` (the dialog's resolution; unchanged unless the user edited it, as in 0035). **DPI-only change** (same size, different DPI): layers reused (tiles shared), selection kept, still one "Canvas Size" step.
   - **No-op (H-6/D-34):** same size and same DPI → `resizedState` returns `nil` whatever the anchor; no step.
   - **Limits first:** `limits.validate(width:height:)` on `request.size` before any allocation; failure → `.limitExceeded(error)`.
   - **Floating pixels:** `precondition`-style `assert(state.floatingPixels == nil)` + doc comment (the command calls `prepareForNavigation` first); after-state `floatingPixels == nil`. Result `image.isConsistent`; selection canvas size == image size (0013 invariant).
   - **History:** `DocumentSnapshotHistoryItem(name: "Canvas Size", icon: .resizeCanvas, before:, after:)`, `.structure`, cost per 0008/0013 (aligned shared tiles cost nothing).

2. **`Core/Model/SelectionMask.swift`** and **`Core/Model/Selection.swift`** (extend 0013; additive only):
   ```swift
   extension SelectionMask {
       /// A mask of `size` with coverage'(x, y) = coverage(x − offset.x, y − offset.y) (0 outside the old mask).
       /// Tile-aware exactly like `placed` above: when both offsets are multiples of 256, tiles whose in-bounds
       /// areas map exactly are re-indexed (.full stays .full, partial storage shared); otherwise assembled
       /// per pixel from ≤ 4 source tiles. Normalized (all-zero tiles → .empty, all-255 in-bounds → .full).
       public func repositioned(in size: PixelSize, offset: PixelPoint) -> SelectionMask
   }
   extension Selection {
       /// canvasSize = size; mask = mask.repositioned(in: size, offset:); path translated by offset and
       /// intersected with the new canvas rect. nil when the new mask is empty.
       public func repositioned(canvasSize size: PixelSize, offset: PixelPoint) -> Selection?
   }
   ```
   Same-size zero offset returns an equal selection (fast path: `self`).

3. **`Core/Operations/PastePlanner.swift`** (refactor 0021; behavior identical): `expandedState(_:to:background:limits:) throws(ImageLimitError)` keeps 0021's exact signature and becomes `_ = try limits.validate(width: newSize.width, height: newSize.height)` (same `ImageLimitError` thrown as before) + `DocumentState(image: ResizeCanvas.resizedImage(state.image, to: newSize, anchor: .topLeft, background: background), selection: nil, floatingPixels: nil)`. Its own copy/fill code is deleted. `PastePlannerTests.expandedStateFillsBottomLayer`, `.expandedStateRespectsLimits` and `PasteIntegrationTests.expandIsPartOfPasteStep` must pass **unchanged** (they are the regression proof).

### Core — the form (pure, unit-tested)

4. **`Core/Operations/ResizeCanvasForm.swift`** (new) — wraps 0035's `ResizeImageForm` (composition; **no** second copy of the size arithmetic):
   ```swift
   public struct ResizeCanvasForm: Equatable, Sendable {
       public init(imageSize: PixelSize, dpi: Double, layerCount: Int, unit: MeasurementUnit)
       public private(set) var size: ResizeImageForm   // all percentage/pixel/print/resolution fields and setters
       public var anchor: CanvasAnchor                  // default .center (Paint.NET default "Middle")
       // Forwarders used by the dialog model: setPercentageText, setWidthText, setHeightText, setPrintWidthText,
       // setPrintHeightText, setResolutionText, setPrintUnit, setMaintainAspectRatio, setResizeBy, plus the
       // read-only texts, pixelFieldsEnabled, newSizeBytes.
       public func validate(limits: ImageLimits) -> Result<ResizeCanvasRequest, ResizeImageValidationError>
   }
   ```
   - **Defaults (Open question 4):** `resizeBy = .absoluteSize` (set via `size.setResizeBy(.absoluteSize)` after init; percentage text stays "100"), `maintainAspectRatio = true`, anchor `.center`, width/height = image size, print size and resolution as 0035 (print unit cm when the status-bar unit is cm, else inches). `size.resampling` exists but is ignored and never shown.
   - **Validation:** `size.validate(limits:)` → same errors, same order, same exact messages as 0035 (e.g. "Width must be a whole number from 1 to 65,535 pixels.", "The image is too large. An image of <w> × <h> pixels needs more memory than PaintDotMac allows."); success maps `ResizeImageRequest(size, dpi, _)` → `ResizeCanvasRequest(size:, dpi:, anchor:)`.
   - `newSizeBytes` = w × h × 4 × layerCount (0035's, Paint.NET "New size").

### Platform glue (AppKit/SwiftUI; UI tests, hosted tests, manual checks)

5. **`App/MainMenu.swift`** (extend 0035): in `menu.image`, directly after "Resize…": **"Canvas Size…"** key `r`, modifiers ⇧⌘, action `resizeCanvas(_:)`, target nil, identifier `menu.image.resizeCanvas`. The full Image menu after this spec is: Crop to Selection ⇧⌘X, Resize… ⌘R, Canvas Size… ⇧⌘R, separator, Flatten ⇧⌘F (0037 inserts its Flip/Rotate group directly after `menu.image.resizeCanvas`). Update `MainMenuTests.imageMenuItems` to that exact list; `noDuplicateShortcuts` must still pass.

6. **`UI/ResizeCanvasDialog.swift`** (new, SwiftUI; same sheet hosting as 0035: `NSHostingController`, `window.beginSheet`, private `UndoManager` from the sheet delegate). Title "Canvas Size". Binds an `@Observable ResizeCanvasDialogModel` (same file) wrapping `ResizeCanvasForm`; no arithmetic in the view. Layout top to bottom (Paint.NET order; same controls as 0035 minus Resampling, plus Anchor):
   - "New size: <bytes>" (`ByteCountFormatter`, `.memory`; "—" when nil) — `resizeCanvas.newSize`.
   - Radio "By percentage:" `resizeCanvas.byPercentage` + field `resizeCanvas.percentage` + "%".
   - Radio "By absolute size" `resizeCanvas.byAbsoluteSize`; checkbox "Maintain aspect ratio" `resizeCanvas.maintainAspectRatio`.
   - "Pixel size": "Width:" `resizeCanvas.width` "pixels", "Height:" `resizeCanvas.height` "pixels".
   - "Print size": "Width:" `resizeCanvas.printWidth`, "Height:" `resizeCanvas.printHeight` (unit "inches"/"centimeters"), "Resolution:" `resizeCanvas.resolution` + pop-up `resizeCanvas.resolutionUnit` ("pixels/inch", "pixels/centimeter").
   - **"Anchor:"** a 3×3 grid of square buttons (`resizeCanvas.anchor.<rawValue>`, e.g. `resizeCanvas.anchor.topLeft`; accessibility label = `displayName`; the selected one has the `.isSelected` trait and shows a filled dot, the eight neighbours show arrows (SF Symbols `arrow.up.left`, `arrow.up`, … pointing away from it), others blank). Clicking sets `form.anchor`. Arrow keys are not required (manual check only for looks).
   - Buttons "Cancel" (`resizeCanvas.cancel`, Escape) and "OK" (`resizeCanvas.ok`, Return). Root identifier `resizeCanvasDialog`.
   - Fields commit to the model on every keystroke (dependents update live, as 0035). Pixel/print/resolution controls disabled in percentage mode; percentage disabled in absolute mode. Width field focused with its text selected on open (absolute mode is the default). Nothing remembered between openings (Open question 4).

7. **`Document/ResizeCanvasCommand.swift`** (new, `@MainActor`, synchronous like 0022's crop — a canvas resize is byte copies, no progress sheet):
   ```swift
   @MainActor enum ResizeCanvasCommand {
       enum Outcome: Equatable { case applied, noOp, failed(ResizeCanvasError) }
       /// Window-controller entry (static for hosted tests), same contract as 0035's ResizeImageCommand.begin:
       /// nil when `ImageCommandRule.isEnabled(hasDocument: true, …, isBusy: bridge.isBusy, …)` is false (gesture in
       /// progress, busy, sheet attached) — prepareForNavigation is then NOT called; else calls
       /// bridge.prepareForNavigation?() exactly once (reason .command) and returns the initial form.
       static func begin(bridge: UndoBridge, gestureInProgress: Bool, hasSheet: Bool, unit: MeasurementUnit) -> ResizeCanvasForm?
       /// Applies a validated request. Precondition: begin() already ran (no floating pixels).
       static func run(bridge: UndoBridge, request: ResizeCanvasRequest, background: ColorRGBA8, limits: ImageLimits) -> Outcome
   }
   ```
   - `run`: `ResizeCanvas.resizedState(bridge.state, …)` → `nil` → `.noOp`; a state → `bridge.perform(ResizeCanvas.makeHistoryItem(before: bridge.state, after:))` → `.applied` (the `.structure` change reaches 0021's `withImageSize` hook: zoom kept, image re-centred, status bar size, marching ants); thrown → `.failed`.

8. **`Document/DocumentWindowController.swift`** (extend):
   - `@objc func resizeCanvas(_:)`: `guard let form = ResizeCanvasCommand.begin(bridge: undoBridge, gestureInProgress: AppModel.shared.dispatcher.isGestureInProgress, hasSheet: window?.attachedSheet != nil, unit: AppSettings().measurementUnit)` (also returns nil when `undoBridge.isBusy`); present the sheet.
   - OK: `form.validate(limits: PaintDocument.imageLimits)`; failure → `NSAlert` (message = `error.message`, button "OK") as a sheet on the dialog; the dialog stays open with the typed values. Success → close the dialog, `ResizeCanvasCommand.run(…, background: AppModel.shared.colors.secondary, limits: PaintDocument.imageLimits)` (the secondary color read **at OK time**); `.failed` → the `.tooLarge` alert for the request's size. Cancel/Escape → close, no change.
   - `validateMenuItem`: `resizeCanvas(_:)` enabled iff `ImageCommandRule.isEnabled(hasDocument: true, isGestureInProgress: AppModel.shared.dispatcher.isGestureInProgress, isBusy: undoBridge.isBusy, hasSheet: window?.attachedSheet != nil)` (0035's rule; no selection required).
   - No change to `onStateChange` (0021's `.structure` branch handles the size change and its undo/redo).

9. `project.yml`: no target changes; run `xcodegen generate` (new files). No PRD/AGENTS edits in this spec (sub-agent rule); decisions to confirm are under Open questions.

### Performance (NF-4; no NF target for canvas size)
- `placed` copies only the overlapping area; borders filled with shared tiles. Targets in the Debug test build: 4000×3000 opaque single layer → 5000×4000 centre (unaligned offset (500, 500)) < 200 ms; → 3000×2000 centre (shrink) < 120 ms; 4096×3072 → 4352×3328 bottom-right (aligned offset (256, 256)) < 20 ms (tile sharing). Gate at 3×; report the numbers in Verification status.

## Acceptance criteria

- [ ] Image ▸ **Canvas Size…** ⇧⌘R sits directly after Resize… and before the Flatten separator; disabled while busy, mid-gesture, or with a sheet attached. → `MainMenuTests.imageMenuItems`, `.noDuplicateShortcuts`, 0035's `ImageCommandRuleTests.enablement`, `ResizeCanvasCommandTests.ignoredWhileBusyOrGesture`; UI `ResizeCanvasUITests.testOpenAndCancel`
- [ ] `CanvasAnchor` has exactly the nine cases in grid order with Paint.NET display names; the dialog shows a 3×3 anchor grid defaulting to Middle. → `ResizeCanvasTests.anchorCasesAndNames`, `ResizeCanvasFormTests.defaults`; UI `testOpenAndCancel`
- [ ] Anchor offsets follow the truncating rule for all nine anchors, growing, shrinking, mixed, and odd differences. → `ResizeCanvasTests.offsetsGrowAllAnchors`, `.offsetsShrinkAllAnchors`, `.offsetsMixedAxes`, `.offsetsOddDifferences`
- [ ] Growing keeps every old pixel unchanged at `(x + dx, y + dy)`; the new area of the bottom layer is the secondary color (as is, alpha included), other layers' new area is `(0,0,0,0)`, hidden layers included. → `ResizeCanvasTests.growCenterHandValues`, `.growAllAnchorsMatchOracle`, `.bottomLayerFillOthersTransparent`, `.semiTransparentSecondaryStoredAsIs`, `.hiddenBottomLayerStillFilled`
- [ ] Shrinking crops the pixels outside the new canvas; kept pixels are unchanged. → `.shrinkCenterHandValues`, `.shrinkAllAnchorsMatchOracle`
- [ ] Tile-aligned offsets share tile storage; exposed edge tiles are never shared and edge-tile padding stays zero; transparent areas stay unallocated. → `.alignedOffsetSharesTiles`, `.edgeTileNotSharedWhenExposed`, `.shrinkKeepsPaddingZero`, `.sparseStaysSparse`, `ResizeCanvasPropertyTests.randomResizesMatchOracle`
- [ ] Unaligned offsets copy correctly across tile seams. → `.unalignedSeams`
- [ ] Layer properties and active layer kept; DPI is the request's; one "Canvas Size" step (`.resizeCanvas`, `.structure`); same size and DPI adds no step for any anchor; DPI-only change is one step with shared tiles. → `.layerPropertiesKept`, `.historyItem`, `.noOpAnyAnchor`, `.dpiOnlyChange`, `ResizeCanvasCommandTests.noOpAddsNoStep`
- [ ] The selection moves with the anchor offset, is clipped when the canvas shrinks, and becomes no selection when cut off completely; undo restores it. → `SelectionRepositionTests.*`, `ResizeCanvasTests.selectionRepositioned`, `.selectionCutOffBecomesNil`; UI `testSelectionFollowsAnchor`
- [ ] Undo restores size, pixels, layers, DPI and selection exactly; redo restores the resized state. → `ResizeCanvasIntegrationTests.undoRedoRoundTrip`, `ResizeCanvasPropertyTests.undoRedoRoundTrip`; UI `testGrowCenterUndoRedo`
- [ ] Sizes outside 1…65,535 or beyond the memory cap are refused with the exact 0035 alert texts before any allocation; the dialog stays open; nothing changes. → `ResizeCanvasTests.limitsCheckedBeforeAllocation`, `ResizeCanvasFormTests.validationDelegates`; UI `testInvalidWidthAlert`, `testTooLargeAlert`
- [ ] The form reuses 0035's size arithmetic (percentage, aspect ratio, print size, resolution, unit) and maps to a `ResizeCanvasRequest` carrying the anchor. → `ResizeCanvasFormTests.*`
- [ ] A pending edit (floating pixels) is committed before the dialog opens. → `ResizeCanvasCommandTests.commitsPendingEditFirst`
- [ ] Paste with Expand (E-6) behaves exactly as before, now through `ResizeCanvas`. → 0021's `PastePlannerTests.expandedStateFillsBottomLayer`, `.expandedStateRespectsLimits`, `PasteIntegrationTests.expandIsPartOfPasteStep` (unchanged), `ResizeCanvasTests.pastePlannerUsesTopLeft`
- [ ] After the resize (and undo/redo) the zoom stays and the image re-centres; the status bar shows the new size. → 0021's `CanvasTransformNavigationTests.withImageSize*` (reused), `ResizeCanvasCommandTests.appliesOneStep` (`.structure` received); UI `testGrowCenterUndoRedo` (`statusBar.zoom` unchanged)
- [ ] Performance targets met within the 3× gate. → `ResizeCanvasPerformanceTests.*`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **1×1 → 1×1 any anchor:** no-op. **1×1 → 3×3 centre:** old pixel at (1,1), 8 fill pixels. **3×3 → 1×1 centre:** keeps old (1,1). → `ResizeCanvasTests.tinySizes`
- **Odd differences:** 2→5 centre `dx = 1`; 5→2 centre `dx = −1`; 4→7 `dx = 1`; 7→4 `dx = −1`; 4→1 centre `dx = −1` (keeps old column 1). → `.offsetsOddDifferences`
- **Width grows while height shrinks** (and vice versa): axes independent; fill only in the grown columns. → `.offsetsMixedAxes`, `.mixedAxesHandValues`
- **Overlap is always `min(old, new) ≥ 1` px per axis** for every anchor: asserted; no empty `placedRect` path exists. → covered by `ResizeCanvasPropertyTests` (random sizes 1…600 incl. 1).
- **Huge growth** (1×1 → 65,535×65,535 within a generous injected cap, bottom fill white): completes; fully covered border tiles share one storage (distinct storages ≤ 257). → `.hugeGrowthSharesFillTiles`
- **Memory cap / > 65,535:** `.limitExceeded`, no allocation; UI alert. → `.limitsCheckedBeforeAllocation`, UI `testTooLargeAlert`
- **Secondary color transparent `(0,0,0,0)`:** bottom layer's new area stays unallocated. **Semi-transparent `(10,20,30,128)`:** stored exactly. → `.transparentSecondaryStaysSparse`, `.semiTransparentSecondaryStoredAsIs`
- **Colour under alpha 0** in kept pixels preserved (byte copy). → `.copyPreservesZeroAlphaColor`
- **Selection entirely in the cropped-away area:** after-state `selection == nil`; Deselect disabled (D-40); undo restores it. → `.selectionCutOffBecomesNil`
- **Antialiased selection** (partial coverage) repositioned exactly (coverage values moved, not re-rasterized). → `SelectionRepositionTests.partialCoverageExact`
- **Same size, different anchor:** no-op (nothing moves). **Same size, different DPI:** DPI-only step. → `.noOpAnyAnchor`, `.dpiOnlyChange`
- **⇧⌘R mid-gesture, busy (effect or resize running), or sheet attached:** disabled / `begin` returns nil. → `ImageCommandRuleTests.enablement` (0035), `ResizeCanvasCommandTests.ignoredWhileBusyOrGesture`
- **Floating pixels / uncommitted shape or text:** committed ("Finish Pixels") before the dialog opens — one extra step even if the dialog is then cancelled (same as 0035). → `.commitsPendingEditFirst`
- **Cancel / Escape in the dialog:** no change, no step. → UI `testOpenAndCancel`
- **Undo budget (H-5):** counted like any snapshot step; no special case.

## Test plan

Expected values below are hand-computed from the rules in this spec, never taken from the code under test. Source fixture `v(x, y) = (x·10 % 256, y·10 % 256, 7, 255)` unless stated; `BG` = background `(0, 255, 0, 255)`; `CL` = `(0,0,0,0)`.

- **Unit — `PaintDotMacTests/Operations/ResizeCanvasTests.swift`:**
  - `anchorCasesAndNames`: `allCases.map(\.rawValue) == ["topLeft","top","topRight","left","center","right","bottomLeft","bottom","bottomRight"]`; display names "Top Left", "Top", "Top Right", "Left", "Middle", "Right", "Bottom Left", "Bottom", "Bottom Right"; `(column,row)` = `(i % 3, i / 3)` for index `i`; `init(column:row:)` round-trips.
  - `offsetsGrowAllAnchors`: old 4×4 → new 7×6 (dW 3, dH 2): topLeft (0,0), top (1,0), topRight (3,0), left (0,1), center (1,1), right (3,1), bottomLeft (0,2), bottom (1,2), bottomRight (3,2).
  - `offsetsShrinkAllAnchors`: old 7×6 → new 4×4 (dW −3, dH −2): topLeft (0,0), top (−1,0), topRight (−3,0), left (0,−1), center (−1,−1), right (−3,−1), bottomLeft (0,−2), bottom (−1,−2), bottomRight (−3,−2).
  - `offsetsMixedAxes`: old 4×6 → new 7×3 center → (1, −1); bottomRight → (3, −3); topLeft → (0, 0).
  - `offsetsOddDifferences`: center x-offset for (old→new): 2→5 = 1, 5→2 = −1, 4→7 = 1, 7→4 = −1, 4→1 = −1, 1→4 = 1, 4→8 = 2, 8→4 = −2, 4→4 = 0.
  - `growCenterHandValues`: single layer 4×4 `v` → 7×6 center, background BG: (1,1) == v(0,0) = (0,0,7,255); (4,4) == v(3,3) = (30,30,7,255); (2,3) == v(1,2) = (10,20,7,255); BG at (0,0), (0,5), (5,1), (6,5), (4,0), (3,5); 42 pixels total, 16 equal to `v`, 26 equal BG.
  - `shrinkCenterHandValues`: 7×6 `v` → 4×4 center: (0,0) == v(1,1) = (10,10,7,255); (3,3) == v(4,4) = (40,40,7,255); no BG anywhere.
  - `mixedAxesHandValues`: 4×6 → 7×3 center: (1,0) == v(0,1); (4,2) == v(3,3); (0,1) and (5,1), (6,2) == BG.
  - `growAllAnchorsMatchOracle` / `shrinkAllAnchorsMatchOracle`: for each of the 9 anchors, 4×4 → 7×6 and 7×6 → 4×4 compared pixel-by-pixel with a naive oracle in the test target (`PaintDotMacTests/Operations/ResizeCanvasReference.swift`: `dst(x,y) = inOld(x−dx, y−dy) ? src : fill`, offsets taken from the hand tables above, not from `offset(...)`).
  - `bottomLayerFillOthersTransparent`: 2 layers 3×2 (bottom opaque red, top one blue pixel at (2,1)) → 5×4 bottomRight (offset (2,2)): bottom (2..4, 2..3) red, (0,0), (4,1), (1,3) BG; top (4,3) blue, (0,0) and (2,2) CL.
  - `hiddenBottomLayerStillFilled`: same with bottom `isVisible = false` → bottom (0,0) == BG.
  - `semiTransparentSecondaryStoredAsIs`: background (10,20,30,128) → new-area pixel bytes exactly (10,20,30,128). `transparentSecondaryStaysSparse`: 300×300 opaque → 1000×1000 topLeft with background CL: tiles whose rect lies outside (0..<300)² — e.g. (2,0), (3,3) — are `nil`.
  - `copyPreservesZeroAlphaColor`: source pixel (9,8,7,0) at (0,0) → after 3×3 → 5×5 center, (1,1) bytes == (9,8,7,0).
  - `unalignedSeams`: 300×300 `v'(x,y) = (x % 256, y % 256, (x/256)·100 + (y/256)·50, 255)` → 600×600 center (offset (150,150)): (149,149) BG; (150,150) == v'(0,0); (255,255) == v'(105,105); (256,256) == v'(106,106); (405,405) == v'(255,255); (406,406) == v'(256,256); (449,449) == v'(299,299); (450,450) BG; plus the oracle over every pixel.
  - `alignedOffsetSharesTiles`: 512×512 random opaque → 1024×1024 bottomRight (offset (512,512)): for tiles T ∈ {0,1}², `result.tile(at: T + (2,2))!.sharesStorage(with: source.tile(at: T)!)`; tiles (0,0)…(1,1) of the result are a BG fill (one shared storage). Also 512×512 → 1000×600 topLeft: source tiles (0,0),(1,0),(0,1),(1,1) shared.
  - `edgeTileNotSharedWhenExposed`: 300×300 opaque (`v'`) → 600×600 topLeft (offset 0): result tile (1,1) does **not** share storage with source tile (1,1); result (300,300) == BG, (299,299) == v'(299,299), (511,511) == BG; tile (0,0) **does** share.
  - `shrinkKeepsPaddingZero`: 1024×1024 opaque → 300×300 topLeft: result tile (1,1) not shared with source tile (1,1); `result.tile(at: (1,1))!.pixel(x: 50, y: 50) == CL` (padding beyond x = 300); tile (0,0) shared.
  - `sparseStaysSparse`: 1024×1024 with only tile (0,0) allocated (top layer, fill CL) → 2048×2048 center (offset (512,512)): only result tile (2,2) allocated (shares storage).
  - `hugeGrowthSharesFillTiles`: `ImageLimits(memoryCapBytes: .max)`, 1×1 → 65,535×65,535 topLeft, background white: result (0,0) == source pixel, (65,534, 65,534) == white, (65,534, 0) == white; every tile below row 0 shares one storage (fully covered by the bottom band), so distinct storages ≤ 257 (the 256 row-0 tiles + 1); completes (no full-image buffer).
  - `layerPropertiesKept`: 3 layers (opacity 77, blend `.multiply` on one, one hidden, names, ids), `activeLayerIndex 1`, dpi 72 → after: all equal, `isConsistent`.
  - `historyItem`: name "Canvas Size", icon `.resizeCanvas`, change `.structure`; `menuTitle == "Canvas Size\u{2026}"`.
  - `noOpAnyAnchor`: same size + same dpi → `isNoOp` true and `resizedState` nil for all 9 anchors.
  - `dpiOnlyChange`: same size, dpi 96 → 300: every tile `sharesStorage` with before, dpi 300, selection equal.
  - `selectionRepositioned`: 4×4 with `Selection(rect: (1,1,2,2))` → 7×6 center → `selection.bounds == (2,2,2,2)`, canvasSize 7×6; shrink 7×6 with rect (0,0,3,3) → 4×4 center (offset (−1,−1)) → bounds (0,0,2,2).
  - `selectionCutOffBecomesNil`: 7×6 selection rect (0,0,1,1) → 4×4 bottomRight (offset (−3,−2)) → `selection == nil`.
  - `limitsCheckedBeforeAllocation`: `ImageLimits(memoryCapBytes: 1023)`, request 16×16 → throws `.limitExceeded(.exceedsMemoryCap(requiredBytes: 1024, capBytes: 1023))`; width 65,536 → `.limitExceeded(.dimensionsOutOfRange…)` (0002's case).
  - `tinySizes`: the 1×1/3×3 cases from Edge cases.
  - `pastePlannerUsesTopLeft`: for a 2-layer 300×200 state, `PastePlanner.expandedState(state, to: 600×300, background: BG, limits:)` image equals `ResizeCanvas.resizedImage(state.image, to: 600×300, anchor: .topLeft, background: BG)` pixel for pixel and its selection is nil.
- **Unit — `PaintDotMacTests/Model/SelectionRepositionTests.swift`:** `growAndShrink` (hand masks: 4×4 mask with coverage 255 at (1,1), 128 at (2,1) → `repositioned(in: 7×6, offset: (1,1))`: 255 at (2,2), 128 at (3,2), 0 elsewhere); `partialCoverageExact` (seeded random antialiased mask 300×300 → 600×600 offset (150,150) equals the per-pixel oracle; seed printed); `alignedReindexesTiles` (512×512 full mask → offset (256,0) in 1024×512: tile (1,0) `.full`, tiles (0,0) and (3,0) `.empty`); `cutOffIsEmpty` (`Selection.repositioned` → nil); `identityFastPath` (same size, offset 0 → equal); `pathTranslated` (rect path (1,1,2,2) + (3,2) → path bbox (4,3,2,2), clipped to the new canvas).
- **Unit — `PaintDotMacTests/Operations/ResizeCanvasFormTests.swift`:** `defaults` (800×600 @96, unit px: `resizeBy == .absoluteSize`, percentage "100", width "800", height "600", print "8.33"/"6.25", resolution "96", aspect on, anchor `.center`); `anchorSetter` (anchor `.bottomLeft` → validated request carries it); `widthEditKeepsAspect` (width "1000" → height "750"; aspect off → 600 unchanged); `percentageMode` (switch to percentage, "50" → 400×300); `validationDelegates` (width "65536" → `.invalidWidth` with 0035's exact message; cap 1,023 with 16×16 → `.tooLarge(16,16)`); `requestMapping` (valid form → `ResizeCanvasRequest(size: 1000×750, dpi: 96, anchor: .center)`); `dpiUnchangedWhenNotEdited` (dpi 72.27 → request dpi exactly 72.27); `newSizeBytes` (800×600, 2 layers → 3,840,000).
- **Hosted — `PaintDotMacTests/Document/ResizeCanvasCommandTests.swift`** (`@MainActor`, real `UndoBridge`): `appliesOneStep` (400×300 → 500×400 center: `.applied`, last history name "Canvas Size", size 500×400, `onStateChange` received `.structure`); `noOpAddsNoStep` (same size + dpi, anchor topRight → `.noOp`, history count unchanged, document not edited); `failedLeavesState` (cap 1,000 → `.failed(.limitExceeded…)`, state unchanged, no step); `commitsPendingEditFirst` (a fake pending edit recording "Finish Pixels" is committed by `begin` exactly once; history `[…, "Finish Pixels", "Canvas Size"]` after `run`); `ignoredWhileBusyOrGesture` (`begin` returns nil and calls no `prepareForNavigation` when `isBusy`, gesture, or sheet).
- **Integration — `PaintDotMacTests/Operations/ResizeCanvasIntegrationTests.swift`:** `undoRedoRoundTrip` — "New Image" 300×200 white; a "Paintbrush" `TileDiffHistoryItem` (red rect (10,10,20,20)); a "Rectangle Select" (10,10,20,20); Add New Layer (0024) with a blue pixel at (299,199); command 300×200 → 401×301 center, background black → offset (50,50); names `["New Image","Paintbrush","Rectangle Select","Add New Layer","Canvas Size"]`; bottom (60,60) red (old (10,10)), (0,0) black, (400,300) black, (349,249) white (old (299,199)); top (349,249) blue, (0,0) CL; selection bounds (60,60,20,20); undo → size 300×200, every tile of both layers shares storage with before, selection (10,10,20,20), dpi 96; redo → equal to the resized state.
- **Property — `PaintDotMacTests/Operations/ResizeCanvasPropertyTests.swift`** (`SeededRandom`, seed printed): `randomResizesMatchOracle` — 60 iterations: random sizes 1…600 per side (old and new), random anchor, random background, 1–3 layers with ~30% unallocated tiles and some alpha-0 pixels → every pixel of every layer equals the oracle; edge-tile padding of every allocated tile is zero; `isConsistent`. `undoRedoRoundTrip` — 20 iterations through a `HistoryStack`: apply/undo/redo → image and selection equal before/after exactly.
- **Regression (unchanged 0021 tests):** `PastePlannerTests.expandedStateFillsBottomLayer`, `.expandedStateRespectsLimits`, `PasteIntegrationTests.expandIsPartOfPasteStep`, `ClipboardUITests.testPasteLargerExpand` pass without edits.
- **Menu — `PaintDotMacTests/App/MainMenuTests.swift`:** `imageMenuItems` == exactly `[Crop to Selection ⇧⌘X (cropToSelection:, menu.image.cropToSelection), Resize… ⌘R (resizeImage:, menu.image.resizeImage), Canvas Size… ⇧⌘R (key "r", [.command, .shift], resizeCanvas:, menu.image.resizeCanvas), separator, Flatten ⇧⌘F (flattenImage:, menu.image.flatten)]`; 0024's `imageMenuFlattenLast` and `noDuplicateShortcuts` pass.
- **UI — `PaintDotMacUITests/ResizeCanvasUITests.swift`** (fixture `UITestFixtures.writePNG` 40×30, pixel `(x·5, y·5, 128, 255)`, 96 DPI; `-UITestResetDefaults` so the secondary color is the 0007 default white `(255,255,255,255)`):
  - `testOpenAndCancel`: ⇧⌘R → `resizeCanvasDialog`; `resizeCanvas.width` "40", `resizeCanvas.height` "30", `resizeCanvas.byAbsoluteSize` selected, `resizeCanvas.anchor.center` selected; no resampling control exists; Escape → dialog gone, `statusBar.imageSize` "40 × 30", no new `historyRow`.
  - `testGrowCenterUndoRedo`: note `statusBar.zoom`; ⇧⌘R, uncheck Maintain aspect ratio, width "50", height "40", OK → "50 × 40", zoom unchanged, History row "Canvas Size"; ⌘S, decode → (0,0) white, (5,5) == (0,0,128,255), (44,34) == (195,145,128,255), (45,35) white, (49,39) white; ⌘Z → "40 × 30"; ⇧⌘Z → "50 × 40".
  - `testShrinkBottomRight`: ⇧⌘R, aspect off, width "20", height "10", click `resizeCanvas.anchor.bottomRight`, OK → "20 × 10"; save, decode → (0,0) == (100,100,128,255) (old (20,20)), (19,9) == (195,145,128,255).
  - `testSelectionFollowsAnchor`: launch with `-UITestSelectRect 0,0,10,10`; ⇧⌘R, aspect off, 50 × 40, center, OK → `statusBar.selectionSize` still "10 × 10" and Edit ▸ Deselect enabled; ⇧⌘R, 5 × 5, anchor bottomRight (offset (−45,−35)) → Deselect disabled (selection cut off); ⌘Z → Deselect enabled.
  - `testInvalidWidthAlert`: width "65536", OK → alert "Width must be a whole number from 1 to 65,535 pixels."; OK → dialog still shown with "65536"; Cancel.
  - `testTooLargeAlert`: launch with `-UITestMemoryCapBytes 10000`; width "100", height "100" (aspect off), OK → alert "The image is too large. An image of 100 × 100 pixels needs more memory than PaintDotMac allows."; size unchanged.
- **Performance — `PaintDotMacTests/Performance/ResizeCanvasPerformanceTests.swift`** (XCTest `measure`): `testGrowCenterUnaligned` (< 600 ms gate), `testShrinkCenter` (< 360 ms), `testGrowAlignedShares` (< 60 ms). Report numbers.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build, no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open a photo, set the secondary color to red, ⇧⌘R, +100 px each side (centre): red border on the bottom layer; add a layer first and repeat: the upper layer's border is transparent (checkerboard visible where the bottom is hidden).
  2. Click each of the nine anchor squares: the dot/arrow glyphs move, look right in light and dark mode, and VoiceOver reads "Top Left" … "Bottom Right".
  3. Shrink with each corner anchor: the kept corner matches the anchor.
  4. Make a selection, grow the canvas centred: marching ants stay on the same pixels; shrink so it's cut off: ants disappear; ⌘Z brings them back.
  5. Return confirms, Escape cancels; the sheet tab order reaches the anchor grid.

## Open questions

Decided as stated (recommended answers applied); the batch owner should confirm and record them in PRD §5.5 IMG-3 / §12.

1. **Fill of the new area.** Paint.NET 5 adds a Fill dropdown (Transparent, Primary Color, Secondary Color, White, Black). This spec keeps the rule already decided for E-6 in 0021: the bottom layer's new area is the secondary color, other layers transparent, with no Fill control. Recommended: yes, as written (a Fill dropdown can be a v1.x addition).
2. **Odd size differences with a centred anchor.** The offset is `(new − old) / 2` with truncation toward zero, so the odd pixel is always added to or removed from the right/bottom side (2→5 adds 1 left / 2 right; 5→2 removes 1 left / 2 right). Paint.NET's docs don't specify it. Recommended: yes, as written.
3. **Selection after Canvas Size.** This spec keeps the selection on the same pixels (translated by the anchor offset, clipped to the new canvas, dropped if nothing remains), as 0022 does for Crop to Selection; 0035 clears it for Resize Image because the pixels are rescaled there. Paint.NET's docs say nothing. Recommended: keep it translated, as written.
4. **Dialog defaults.** The dialog opens on "By absolute size" with the current pixel size, "Maintain aspect ratio" checked, anchor Middle, and remembers nothing between openings (Paint.NET's Canvas Size opens on absolute size with the anchor in the middle). Recommended: yes, as written.
5. **DPI field.** As in 0035, the print-size/resolution group is shown and an edited resolution becomes the document's DPI (keeping the print size, so the pixel size changes); an unchanged resolution leaves the DPI exactly as it was. Recommended: yes, as written.

## Out of scope

- Resize Image (0035), Flip/Rotate (0037), Auto-crop (0061, v1.x), Crop to Selection (0022).
- A Fill dropdown (Paint.NET 5), per-layer canvas changes, layer offsets (layers always equal the canvas size).
- Moving shortcuts into `ShortcutTable` (0045); remembering dialog values across openings or launches.
