# 0037 — Flip and rotate the whole image (Flip Horizontal/Vertical, Rotate 90° ⌘] / ⌘[, Rotate 180° ⌘J)

> Source: PRD.md §5.5 IMG-4 ("Flip horizontal and vertical. Rotate 90° CW, 90° CCW, 180°.", P0); §5.12 / §12 D-12 (Rotate 90° CW / 90° CCW / 180°: Paint.NET Ctrl+H / Ctrl+G / Ctrl+J → **⌘] / ⌘[ / ⌘J**, because ⌘H is Hide); §5.7 H-6 / §12 D-34 (no-op edits add no step; undo doesn't change the active layer unless the step changed the stack); §12 D-7 (per-document DPI); D-33 (colour under alpha 0 preserved); D-40 (no selection = `nil`); NF-4 (tiled storage, history memory), NF-9 (straight RGBA8); §8 M4 ("Resize Image, Resize Canvas, rotate and flip"; exit: use case 2 works apart from Sharpen); AGENTS.md architecture rules (pixel changes only through history, 256×256 tiles, Core free of AppKit).
> Paint.NET docs (fetched 2026-11-07; `getpaint.net/doc/latest/…` redirects to `paint.net/doc/latest/…`): Image menu — https://paint.net/doc/latest/ImageMenu.html. Quoted: "This menu contains commands that affect all layers in the current image." Items "Flip Horizontal", "Flip Vertical": "These menu items allow the image to be flipped horizontally or vertically. Remember - ALL layers will undergo this transformation." "The next three menu items rotate the image by 90° (in either clockwise or counter-clockwise directions) or by 180 degrees." Item titles as shown in Paint.NET: **Rotate 90° Clockwise**, **Rotate 90° Counter-Clockwise**, **Rotate 180°**. Keyboard reference — https://paint.net/doc/latest/KeyboardMouseCommands.html (Ctrl+H rotate 90° clockwise, Ctrl+G 90° counter-clockwise, Ctrl+J 180°). The docs say nothing about the selection (Open question 1).
> Milestone: M4
> Depends on: 0036-resize-canvas (Image menu order: this spec's items go directly after its `menu.image.resizeCanvas` item; last canvas-size command before this one), 0035-resize-image (Image-menu command pattern, `ImageCommandRule` enablement incl. `isBusy`), and through them 0002 (`TiledSurface`, `Tile`), 0008 (`DocumentSnapshotHistoryItem`, `HistoryIcon.flipRotate`, `HistoryCost.unsharedTileBytes`, `UndoBridge.prepareForNavigation`), 0013 (`Selection`, `SelectionMask`), 0019 (`SelectionMask+Transform.swift`, `Selection+Transform.swift`), 0020 (`FloatingPixels`, "Finish Pixels"), 0021 (`CanvasTransform.withImageSize(_:)`, `.structure` hook), 0022 (Image menu, `runCropToSelection` static-driver pattern), 0024 (layers, Flatten last in the Image menu), 0031 (`UndoBridge.isBusy`, menu enablement rule shape).

## Context

Not yet implemented (specs only, no application code). What exists after 0001–0036 that this spec builds on:

- **`TiledSurface` / `Tile` (0002, `docs/specs/todo/0002-tiled-surface-and-image-decoding_TODO.md:98-130`)**: 256×256 RGBA8 tiles, row-major `[Tile?]` (`nil` = transparent), edge-tile invariant (pixels outside `bounds` are `(0,0,0,0)`), `init(size:)`, `tile(at:)`/`setTile(_:at:)`, `allocatedTileCoordinates`, `readPixels(in:)` / `readPixels(in:into:bytesPerRow:)` (unallocated and out-of-bounds read as zero), `writePixels`, `releaseTransparentTiles()`, `Tile(filledWith:)`, `Tile.withUnsafe(Mutable)Bytes`, `Tile.sharesStorage(with:)`, `Tile.isFullyTransparent`. `fill` shares one buffer among interior tiles (`:360-361`).
- **`LayeredImage` / `Layer` (0002 `:134-150`)**: `size`, `dpi`, `layers` (bottom first; `id`, `name`, `isVisible`, `opacity`, `blendMode`, `surface`), `activeLayerIndex`, `isConsistent`.
- **History (0008 `0008-history-stack-and-undo-bridge_TODO.md:53,83,89`)**: `HistoryIcon.flipRotate` already exists; `DocumentSnapshotHistoryItem(name:icon:before:after:)` is reserved for "rotate 0037", `change == .structure`, `byteCost = HistoryCost.unsharedTileBytes(before:after:)`, `isNoOp` default `false` (so this spec decides no-ops before building the item). `UndoBridge.perform(_:)`, `prepareForNavigation` (`:196`).
- **Selection (0013 `0013-selection-core-and-marching-ants_TODO.md:58-72,99-125`)**: `SelectionMask` (tiles `.empty/.full/.partial(SelectionMaskTileStorage)`, edge-tile padding always 0 in `.partial`, `.full` = every in-canvas pixel 255, normalized by `init(size:tiles:)`), `Selection` (`canvasSize`, normalized `path` clipped to the canvas, normative `mask`, `init?(mask:outline:)` intersects the outline with the canvas rect, `nil` = no selection). `DocumentState.selection` with the invariant `selection == nil || selection.canvasSize == image.size` (`:131`); "Operations that change the canvas size (0022, 0035–0037) are responsible for transforming or dropping the selection in their snapshot."
- **0019 (`0019-move-selection-tool_TODO.md:105-118`)** created `Core/Model/SelectionMask+Transform.swift` (`translated(dx:dy:)`) and `Core/Model/Selection+Transform.swift` (`Selection.transformed(_:by:antialiased:)`); 0022 added `SelectionMask.cropped(to:)` / `Selection.translatedAndCropped(to:)`. This spec extends the same two files additively.
- **Floating pixels (0020 `:98,137`)**: `DocumentState.floatingPixels`; snapshot operations only run with `floatingPixels == nil` because commands call `undoBridge.prepareForNavigation?()` first, which records **"Finish Pixels"**.
- **View (0021 `0021-clipboard-cut-copy-paste_TODO.md:168,195`)**: `CanvasTransform.withImageSize(_:)` keeps the zoom and re-centres (returns `self` when the size is unchanged); the `.structure` branch of `onStateChange` applies it. Reused unchanged.
- **Image menu (0022 `:78-82`, 0024 `:170`, 0035 item 4, 0036 item 5)**: Crop to Selection ⇧⌘X (`menu.image.cropToSelection`), Resize… ⌘R (`menu.image.resizeImage`), Canvas Size… ⇧⌘R (`menu.image.resizeCanvas`), separator, Flatten ⇧⌘F (`menu.image.flatten`, last). 0022's comment reserves the Flip/Rotate slot for this spec.
- **0031 (`0031…_TODO.md:254,263`)**: `UndoBridge.isBusy` disables every document command while an effect/resize runs. **0035 item 4a**: `ImageCommandRule.isEnabled(hasDocument:isGestureInProgress:isBusy:hasSheet:)` (`hasDocument && !isGestureInProgress && !isBusy && !hasSheet`), the shared rule for whole-image commands, tested by `ImageCommandRuleTests.enablement`; reused here unchanged.
- **No shortcut conflicts:** ⌘[ / ⌘] / ⌘J are used by no earlier spec; 0009 explicitly leaves ⌘[ / ⌘] to Rotate (`0009-paintbrush-tool_TODO.md:19,114`).

**Paint.NET behavior mirrored:** all five commands affect **every layer** (hidden ones too), are lossless pixel permutations (no resampling), keep layer properties, and record one history step named after the command. 90° rotations swap the canvas width and height.

## User story

As a PaintDotMac user, I choose **Image ▸ Flip Horizontal** or **Flip Vertical**, or press **⌘]** (Rotate 90° Clockwise), **⌘[** (Rotate 90° Counter-Clockwise) or **⌘J** (Rotate 180°). Every layer is flipped or rotated pixel-exactly; a 90° rotation swaps the image's width and height, the window keeps its zoom and re-centres the image, and the status bar shows the new size. My selection turns with the image. The History panel shows one step named after the command, which ⌘Z undoes exactly and ⇧⌘Z redoes. Floating pixels are finished first.

## Scope & changes

### Core — the operation (pure, headless, unit-tested; no AppKit/SwiftUI)

1. **`Core/Operations/FlipRotateImage.swift`** (new):
   ```swift
   public enum FlipRotateKind: String, CaseIterable, Sendable {
       case flipHorizontal, flipVertical, rotate90Clockwise, rotate90CounterClockwise, rotate180   // raw values frozen
       /// Menu title and history step name (Paint.NET spelling):
       /// "Flip Horizontal", "Flip Vertical", "Rotate 90° Clockwise", "Rotate 90° Counter-Clockwise", "Rotate 180°".
       public var name: String
       public var swapsDimensions: Bool                       // true for the two 90° rotations
       public var inverse: FlipRotateKind                     // flips and 180° are self-inverse; CW ↔ CCW
       public func destinationSize(for size: PixelSize) -> PixelSize
       /// Forward pixel map: source pixel (x, y) of an image of `size` → destination pixel.
       public func destinationPixel(x: Int, y: Int, sourceSize size: PixelSize) -> PixelPoint
       /// Inverse pixel map: destination pixel → source pixel (what the implementation actually uses).
       public func sourcePixel(x: Int, y: Int, sourceSize size: PixelSize) -> PixelPoint
       /// Continuous canvas-space map (y down, pixel edges at integers) for selection outlines.
       public func canvasTransform(sourceSize size: PixelSize) -> CGAffineTransform
   }
   public enum FlipRotateImage {
       public static let icon: HistoryIcon = .flipRotate
       // Enablement: 0035's ImageCommandRule.isEnabled (no separate rule here).
       /// Whole-surface transform; tiles processed independently (parallel), sparse tiles stay unallocated.
       public static func transformed(_ surface: TiledSurface, _ kind: FlipRotateKind) -> TiledSurface
       /// The transformed document, or nil when nothing would change (H-6).
       public static func transformedState(_ state: DocumentState, _ kind: FlipRotateKind) -> DocumentState?
       /// DocumentSnapshotHistoryItem(name: kind.name, icon: .flipRotate, before: state, after:) or nil (no-op).
       public static func makeHistoryItem(for state: DocumentState, _ kind: FlipRotateKind) -> DocumentSnapshotHistoryItem?
   }
   ```
   - **Pixel maps** (source `W × H`, `x ∈ 0..<W`, `y ∈ 0..<H`). Forward / inverse, destination size:

     | Kind | Destination size | Forward `(x, y) →` | Inverse: destination `(x', y')` reads source |
     |---|---|---|---|
     | flipHorizontal | W × H | `(W−1−x, y)` | `(W−1−x', y')` |
     | flipVertical | W × H | `(x, H−1−y)` | `(x', H−1−y')` |
     | rotate90Clockwise | **H × W** | `(H−1−y, x)` | `(y', H−1−x')` |
     | rotate90CounterClockwise | **H × W** | `(y, W−1−x)` | `(W−1−y', x')` |
     | rotate180 | W × H | `(W−1−x, H−1−y)` | `(W−1−x', H−1−y')` |

     "Clockwise" means clockwise as seen on screen (canvas y points down): the source's top-left pixel ends up at the top-right.
   - **Continuous map** (`canvasTransform`, used for paths): flipH `x' = W − x`; flipV `y' = H − y`; CW `(x', y') = (H − y, x)`; CCW `(x', y') = (y, W − x)`; 180° `(W − x, H − y)`. All coefficients are 0/±1 and the offsets are integers, so a path with integer or half-integer coordinates maps exactly in `Double`.
   - **`transformed(_:_:)` algorithm** (lossless; no resampling anywhere — IMG-4 is a permutation):
     - New `TiledSurface(size: kind.destinationSize(for: surface.size))`. For each destination tile `t` (row-major grid), `D = destination.pixelRect(of: t)` (clipped to bounds; its origin is the tile origin). The source rect `S` is the image of `D` under the inverse map (an axis-aligned rect of the same area, `S.width × S.height = D.height × D.width` for 90° rotations, else `D.size`), always inside the source bounds.
     - **Sparse:** if every source tile intersecting `S` is unallocated (`tile(at:) == nil`) → destination tile stays `nil` (no read, no allocation).
     - Otherwise: `surface.readPixels(in: S, into: buffer, bytesPerRow: S.width × 4)` (a ≤ 256 KB scratch per worker), then apply the tile-local permutation into a zero-initialized `Tile` at local `(0,0)` with `bytesPerRow 1024`: **Accelerate vImage** (allowed in Core, D-19) — `vImageHorizontalReflect_ARGB8888`, `vImageVerticalReflect_ARGB8888`, `vImageRotate90_ARGB8888` (rotation constant for 90°/270°/180°; `backColor` irrelevant for multiples of 90°), flag `kvImageDoNotTile` (we parallelize ourselves). The ARGB8888 functions only move whole 32-bit pixels, so they are channel-order agnostic and copy RGBA bytes unchanged. **Do not trust the rotation-constant names for direction: the hand-computed tests below (`rotateClockwise3x2`, `rotateCounterClockwise3x2`) are the oracle.** If vImage is unusable for some case, a plain `UInt32` gather loop using `sourcePixel` is an acceptable fallback provided the performance tests pass.
     - Pixels of the destination tile outside `D` stay `(0,0,0,0)` (edge-tile invariant).
     - **Transparent result:** a destination tile whose bytes are all zero stays `nil`.
     - **Uniform interior tiles stay shared:** if `D` is a full 256×256 tile and all its pixels are one colour `c` (checked with a `UInt64`/`UInt32` scan), the destination uses one shared `Tile(filledWith: c)` instance per distinct colour per call (a small dictionary keyed by the `ColorRGBA8` bit pattern, built serially after the parallel pass). So a freshly filled white image stays cheap in memory and history (NF-4). Colour under alpha 0 is kept exactly (D-33) — `(10,20,30,0)` is a colour like any other here; only all-zero tiles are dropped.
     - Destination tiles are computed with `DispatchQueue.concurrentPerform` over tile indices (each worker its own scratch buffer; results per tile are independent, so the output is bit-identical to a serial run), then installed serially with `setTile`.
     - Never allocate a full-image buffer.
   - **`transformedState(_:_:)`**:
     - Precondition: `state.floatingPixels == nil` (the command finishes them first).
     - **Geometric identity short-cut:** returns `nil` without work when the map is the identity: `flipHorizontal` with `W == 1`, `flipVertical` with `H == 1`, `rotate180` with `W == 1 && H == 1`, and the 90° rotations with `W == 1 && H == 1`.
     - Every layer, in order, **including hidden layers** ("ALL layers will undergo this transformation"), gets `transformed(layer.surface, kind)`; `id`, `name`, `isVisible`, `opacity`, `blendMode` unchanged; `activeLayerIndex` unchanged; **`dpi` unchanged** (D-7: a 90° rotation keeps one DPI for both axes). New `LayeredImage(size: kind.destinationSize(for:), …)` satisfies `isConsistent`.
     - **Selection** (Open question 1): `state.selection?.flippedOrRotated(kind)` (item 2) — transformed with the image, exact mask permutation; `nil` stays `nil`.
     - **Content no-op (H-6, D-34):** if the size is unchanged, every layer's surface `==` the source surface, and the selection masks are equal (or both `nil`), return `nil` (the selection's *path* is not compared: path booleans can reorder elements). Example: Flip Horizontal on a uniformly white image with no selection adds no step. A 90° rotation of a non-square image is never a no-op.
     - Result `DocumentState(image: newImage, selection: newSelection)`, `floatingPixels == nil`.
   - **History:** `DocumentSnapshotHistoryItem(name: kind.name, icon: .flipRotate, before: state, after: transformed)`, change `.structure` (also for flips: the canvas is re-uploaded with `invalidateAll()`; `withImageSize` returns `self` for an unchanged size, so the view does not jump). `byteCost` = 0008's `unsharedTileBytes` (≈ all old + all new tiles, minus shared uniform tiles). Undo restores the before-state exactly (tiles share storage with it); H-6's "undo doesn't change the active layer" holds because `activeLayerIndex` is the same on both sides.

2. **`Core/Model/SelectionMask+Transform.swift`** and **`Core/Model/Selection+Transform.swift`** (extend 0019's files; additive, no parallel types):
   ```swift
   extension SelectionMask {
       /// Exact permutation of coverage with FlipRotateKind's pixel map; size = kind.destinationSize(for: size).
       public func flippedOrRotated(_ kind: FlipRotateKind) -> SelectionMask
   }
   extension Selection {
       /// canvasSize = kind.destinationSize(for: canvasSize); mask = mask.flippedOrRotated(kind);
       /// outline = path transformed by kind.canvasTransform(sourceSize: canvasSize), via init?(mask:outline:).
       /// Never nil for a non-empty selection (a permutation of a non-empty mask is non-empty).
       public func flippedOrRotated(_ kind: FlipRotateKind) -> Selection
   }
   ```
   - Mask algorithm mirrors item 1 per destination tile: source rect `S`; if every source mask tile touching `S` is `.empty` → `.empty`; if every one is `.full` → `.full` (`S` lies inside the canvas, so all its pixels are 255 and so are all in-canvas pixels of the destination tile); otherwise gather the `S` coverage bytes into a scratch buffer (`.full` → 255, `.empty` → 0, `.partial` → row copies from the storage) and permute with `vImageHorizontalReflect_Planar8` / `vImageVerticalReflect_Planar8` / `vImageRotate90_Planar8` into a fresh 65,536-byte `.partial` storage with out-of-canvas padding 0. Result built with `init(size:tiles:)` (normalizes). `bounds` therefore maps exactly: the destination bounds is the transformed rect of the source bounds.
   - `Selection.flippedOrRotated`: `init?(mask:outline:)` cannot return `nil` here (non-empty mask, matching size). Don't trap: if it ever did, retry with the new canvas rect as the outline, and if that also fails return `Selection.all(canvasSize:)` of the new size. Comment it as unreachable and defensive.

### Platform glue (AppKit; UI tests, hosted tests, manual checks)

3. **`App/MainMenu.swift`** (extend 0022/0024/0035/0036): in `menu.image`, directly after 0036's Canvas Size… item (`menu.image.resizeCanvas`) and before Flatten's separator, in Paint.NET's order:

   | Item title | Key | Modifiers | Action | Identifier |
   |---|---|---|---|---|
   | *separator* | | | | |
   | Flip Horizontal | — | — | `flipImageHorizontal(_:)` | `menu.image.flipHorizontal` |
   | Flip Vertical | — | — | `flipImageVertical(_:)` | `menu.image.flipVertical` |
   | *separator* | | | | |
   | Rotate 90° Clockwise | `]` | ⌘ | `rotateImage90Clockwise(_:)` | `menu.image.rotate90Clockwise` |
   | Rotate 90° Counter-Clockwise | `[` | ⌘ | `rotateImage90CounterClockwise(_:)` | `menu.image.rotate90CounterClockwise` |
   | Rotate 180° | `j` | ⌘ | `rotateImage180(_:)` | `menu.image.rotate180` |

   Target `nil` (responder chain). Titles come from `FlipRotateKind.name` (U+00B0 degree sign, no space before it). Flip items have no shortcut (Paint.NET has none). The full Image menu after this spec is: Crop to Selection ⇧⌘X, Resize… ⌘R, Canvas Size… ⇧⌘R, separator, Flip Horizontal, Flip Vertical, separator, Rotate 90° Clockwise ⌘], Rotate 90° Counter-Clockwise ⌘[, Rotate 180° ⌘J, separator, Flatten ⇧⌘F. Update `MainMenuTests.imageMenuItems` to that exact list; `noDuplicateShortcuts` must still pass (0045 later moves these into `ShortcutTable`).

4. **`Document/DocumentWindowController.swift`** (extend):
   - Five `@objc` actions, each calling `Self.runFlipRotate(kind, bridge: undoBridge, gestureInProgress: AppModel.shared.dispatcher.isGestureInProgress, isBusy: undoBridge.isBusy, hasSheet: window?.attachedSheet != nil)`.
   - `@MainActor static func runFlipRotate(_ kind: FlipRotateKind, bridge: UndoBridge, gestureInProgress: Bool, isBusy: Bool, hasSheet: Bool)` (static, like 0022's `runCropToSelection`, so a hosted test drives it without a window): if `!ImageCommandRule.isEnabled(hasDocument: true, isGestureInProgress: gestureInProgress, isBusy: isBusy, hasSheet: hasSheet)` → return (no `prepareForNavigation` call); `bridge.prepareForNavigation?()` (reason `.command`: floating pixels record "Finish Pixels"; 0038–0040 commit pending shapes/text); then `if let item = FlipRotateImage.makeHistoryItem(for: bridge.state, kind) { bridge.perform(item) }`.
   - Runs **synchronously on the main actor** (a permutation is memory-bound and fast; see Performance). No progress sheet, no `isBusy`.
   - `validateMenuItem(_:)`: the five actions are enabled iff `ImageCommandRule.isEnabled(hasDocument: true, isGestureInProgress: AppModel.shared.dispatcher.isGestureInProgress, isBusy: undoBridge.isBusy, hasSheet: window?.attachedSheet != nil)` (the same rule as 0035/0036). They do **not** require a selection.
   - `onStateChange`: no change. 0021's `.structure` branch applies `withImageSize` (zoom kept, image re-centred after a 90° rotation; no jump for flips), refreshes the canvas, status-bar image size, marching ants and 0014's selection size.

5. `project.yml`: no target changes; run `xcodegen generate` (new files). No PRD/AGENTS edits in this spec (sub-agent rule); the decision to confirm is under Open questions.

### Performance (NF-4; flip/rotate has no NF target)
- Memory: one ≤ 256 KB scratch buffer per worker; history step ≈ all old + all new non-uniform tiles.
- Targets in the Debug test build, 4000×3000 single opaque layer filled with seeded noise (so no uniform-tile sharing): each of the five kinds `transformed` < 150 ms (gate 450 ms); 10 such layers + a full-canvas antialiased ellipse selection, `transformedState(.rotate90Clockwise)` < 1.5 s (gate 4.5 s); `SelectionMask.flippedOrRotated(.rotate90Clockwise)` of a 4000×3000 seeded random partial mask < 100 ms (gate 300 ms). Report measured numbers in the Verification status. If the 10-layer number exceeds 1 s in Release, report it (a progress sheet would then be a follow-up, not part of this spec).

## Acceptance criteria

- [ ] The Image menu contains, after Canvas Size and before Flatten, separator, **Flip Horizontal**, **Flip Vertical**, separator, **Rotate 90° Clockwise ⌘]**, **Rotate 90° Counter-Clockwise ⌘[**, **Rotate 180° ⌘J**, with the stated actions and identifiers; no shortcut duplicates. → `MainMenuTests.imageMenuItems`, `.noDuplicateShortcuts`; UI `FlipRotateImageUITests.testMenuItemsPresentAndEnabled`
- [ ] The commands are enabled with an open document (with or without a selection) and disabled mid-gesture, while busy, or with a sheet attached. → 0035's `ImageCommandRuleTests.enablement`, `FlipRotateCommandTests.ignoredWhenDisabled`; UI `testMenuItemsPresentAndEnabled`
- [ ] Each kind moves every pixel exactly per the table (hand-computed 3×2 cases), with no resampling and colour under alpha 0 preserved. → `FlipRotateImageTests.flipHorizontal3x2`, `.flipVertical3x2`, `.rotateClockwise3x2`, `.rotateCounterClockwise3x2`, `.rotate180_3x2`, `.keepsColorUnderZeroAlpha`, `.pixelMapsAreInverse`
- [ ] Results are correct across tile seams for aligned and unaligned sizes and match a naive per-pixel oracle; sparse layers stay sparse; uniform interior tiles are shared. → `FlipRotateImageTests.matchesOracleAcrossSeams`, `.alignedSizesMatchOracle`, `.sparseStaysSparse`, `.uniformTilesShareStorage`, `.edgeTilePaddingIsZero`
- [ ] 90° rotations swap width and height; flips and 180° keep the size. → `FlipRotateImageTests.destinationSizes`; UI `testRotateClockwiseShortcutAndSavedPNG`
- [ ] Every layer (hidden too) is transformed; layer ids, names, visibility, opacity, blend mode, active layer index and DPI are kept. → `FlipRotateImageTests.allLayersTransformedPropertiesKept`
- [ ] The selection is transformed with the image: exact mask permutation, `.full`/`.empty` tiles preserved, outline mapped; no selection stays none. → `SelectionFlipRotateTests.*`, `FlipRotateImageTests.selectionTransformed`; UI `testSelectionRotatesWithImage`
- [ ] Composition identities hold: 4× CW = identity, CW∘CCW = CCW∘CW = identity, flipH∘flipH = flipV∘flipV = identity, rotate180 = flipH∘flipV = flipV∘flipH = CW∘CW (pixels and selection masks). → `FlipRotatePropertyTests.*`
- [ ] One history step named exactly after the command (icon `.flipRotate`, change `.structure`); undo restores size, pixels, layers, DPI and selection exactly; redo restores the transformed state; a command that changes nothing adds no step. → `FlipRotateImageTests.historyItemNamesAndIcon`, `.identityNoOps`, `.contentNoOp`, `FlipRotateIntegrationTests.undoRedoRoundTrip`; UI `testCounterClockwiseAnd180UndoRedo`, `testFlipMenusAndSave`
- [ ] Floating pixels / pending edits are finished first ("Finish Pixels" precedes the rotate step). → `FlipRotateCommandTests.commitsPendingEditFirst`
- [ ] After a rotation (and its undo/redo) the zoom stays and the image is re-centred; the status bar shows the new size. → 0021's `CanvasTransformNavigationTests.withImageSize*` (reused), `FlipRotateIntegrationTests.undoRedoRoundTrip` (`.structure`); UI `testRotateClockwiseShortcutAndSavedPNG` (`statusBar.zoom` unchanged, `statusBar.imageSize`)
- [ ] The saved PNG holds the transformed pixels. → UI `testRotateClockwiseShortcutAndSavedPNG`, `testFlipMenusAndSave`
- [ ] Performance targets met within the 3× gate. → `FlipRotatePerformanceTests.*`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **1×1 image:** every kind is the identity → `nil`, no step. **W×1 / 1×H:** flipV of W×1 and flipH of 1×H are identities (no step); the others are real changes; rotating 65,535×1 gives 1×65,535 (tile grid 256×1 → 1×256), no limit check needed (sides stay in 1…65,535 and the pixel count is unchanged). → `FlipRotateImageTests.identityNoOps`, `.extremeAspectRotate`
- **Sizes that are multiples of 256 vs not** (512×768, 600×300, 257×1, 1×257): seams correct, padding zero. → `.alignedSizesMatchOracle`, `.matchesOracleAcrossSeams`, `.edgeTilePaddingIsZero`
- **Square image rotated 90°:** size unchanged; still a change unless content is symmetric. → `.contentNoOp` (a 4×4 image with 4-fold symmetry → no step for CW; an asymmetric 4×4 → step)
- **Empty (no tiles) layer and fully transparent image:** stays without tiles; with no selection the whole state is a content no-op → no step. → `.sparseStaysSparse`, `.contentNoOp`
- **Semi-transparent / alpha-0 pixels:** bytes moved unchanged (no premultiplication anywhere). → `.keepsColorUnderZeroAlpha`
- **Hidden active layer, layer opacity 77, non-Normal blend mode:** all kept. → `.allLayersTransformedPropertiesKept`
- **Selection covering everything (`Selection.all`):** rotated mask `isFull`, no partial tiles; antialiased ellipse and Magic-Wand-style random masks permuted exactly. → `SelectionFlipRotateTests.fullStaysFull`, `.randomMaskMatchesOracle`
- **Selection touching the canvas edge / inverted selection (outline includes the canvas border):** mask exact; outline bounds = transformed bounds. → `.outlineBoundsMapped`, `.invertedSelection`
- **Floating pixels present:** "Finish Pixels" first, then the step; undo of the rotate leaves the finished pixels. → `FlipRotateCommandTests.commitsPendingEditFirst`
- **Mid-gesture, while an effect/resize runs (busy), or with a sheet open:** menu item disabled, shortcut ignored, no step. → `.ignoredWhenDisabled`, `ImageCommandRuleTests.enablement` (0035)
- **Undo budget (H-5):** a large rotate step is counted like any snapshot; no special case.
- **Keyboard layouts:** ⌘[ / ⌘] are the key equivalents `"["`/`"]"`; on layouts where AppKit cannot produce them the menu items still work. → manual 3

## Test plan

Expected values below are hand-derived from the pixel-map table, never taken from the code under test. In the 3×2 cases the source is
```
row 0: a b c
row 1: d e f
```
with `a = (10,0,0,255)`, `b = (20,0,0,255)`, `c = (30,0,0,255)`, `d = (40,0,0,255)`, `e = (50,0,0,128)`, `f = (60,70,80,0)` (alpha 0 with colour, D-33).

- **Unit — `PaintDotMacTests/Operations/FlipRotateImageTests.swift`:**
  - `namesAndRawValues`: raw values `["flipHorizontal","flipVertical","rotate90Clockwise","rotate90CounterClockwise","rotate180"]`; names exactly "Flip Horizontal", "Flip Vertical", "Rotate 90° Clockwise", "Rotate 90° Counter-Clockwise", "Rotate 180°" (degree sign U+00B0); `inverse`: CW↔CCW, others self.
  - `destinationSizes`: 300×200 → flips/180 300×200, CW/CCW 200×300.
  - `pixelMapsAreInverse`: for 7×5 and every kind, `sourcePixel(destinationPixel(p)) == p` for all p, and `destinationPixel` is a bijection onto the destination grid.
  - `flipHorizontal3x2` → rows `c b a` / `f e d`. `flipVertical3x2` → `d e f` / `a b c`. `rotateClockwise3x2` → 2×3, rows `d a` / `e b` / `f c`. `rotateCounterClockwise3x2` → 2×3, rows `c f` / `b e` / `a d`. `rotate180_3x2` → `f e d` / `c b a`. Every byte checked.
  - `keepsColorUnderZeroAlpha`: in each result, the pixel holding `f` reads exactly `(60,70,80,0)`.
  - `matchesOracleAcrossSeams`: 600×300 seeded random (seed printed; ~30% pixels `(r,g,b,0)` with random colour, plus three 256×256-aligned regions left unallocated) → every kind equals a naive oracle in `PaintDotMacTests/Operations/FlipRotateReference.swift` (per-pixel loop from the table, written independently; does not call `sourcePixel`/`destinationPixel`); same for 257×1 and 1×257.
  - `alignedSizesMatchOracle`: 512×768 and 256×256 random → equals the oracle for every kind.
  - `edgeTilePaddingIsZero`: 600×300 opaque → CW (300×600): in tile (1,2) every byte at local x ≥ 44 or local y ≥ 88 is 0 (300 − 256 = 44, 600 − 512 = 88).
  - `sparseStaysSparse`: 1000×700, only pixels (10…20, 10…20) opaque (tile (0,0)): flipH → `allocatedTileCoordinates == [(3,0)]` (x' = 979…989); CW (700×1000) → `[(2,0)]` (x' = 699 − y = 679…689, y' = x); a surface with no tiles → result has no tiles.
  - `uniformTilesShareStorage`: 1000×700 `fill(.white)` → flipH: the six fully-in-bounds destination tiles (columns 0–2, rows 0–1) all `sharesStorage` with each other; edge tiles have zero padding and read white inside bounds. 1024×1024 white → CW: all 16 tiles share storage.
  - `allLayersTransformedPropertiesKept`: 3 layers (layer 1 hidden, opacity 77, blend `.multiply`), `activeLayerIndex 1`, dpi 300, 8×6 → CW: each layer's pixel equals the oracle; ids, names, `isVisible`, opacity, blend mode, `activeLayerIndex`, dpi 300 unchanged; `isConsistent`.
  - `selectionTransformed`: rect selection (10,20,30,40) on 300×200 → mask bounds per kind: flipH (260,20,30,40), flipV (10,140,30,40), CW (140,10,40,30), CCW (20,260,40,30), 180 (260,140,30,40); `canvasSize` = destination size; no selection → stays `nil`.
  - `historyItemNamesAndIcon`: for each kind on an asymmetric 4×3 image: item name == `kind.name`, icon `.flipRotate`, change `.structure`.
  - `identityNoOps`: 1×1 → all five `transformedState == nil`, `makeHistoryItem == nil`; 5×1: flipV nil, the others non-nil; 1×5: flipH nil.
  - `contentNoOp`: 4×4 white image without selection → flipH, flipV, 180, CW all `nil`; with a rect selection (0,0,2,2) → flipH non-nil (mask changes); asymmetric 4×4 → non-nil.
  - `extremeAspectRotate`: 65,535×1 with pixel x=65,534 green → CW gives 1×65,535 with (0, 65,534) green and `allocatedTileCoordinates == [(0,255)]`.
- **Unit — `PaintDotMacTests/Model/SelectionFlipRotateTests.swift`:**
  - `handValues3x2`: coverage `[[0, 64, 255],[128, 0, 1]]` → per kind the same permutations as the pixel cases (e.g. CW rows `[128, 0]`, `[0, 64]`, `[1, 255]`).
  - `fullStaysFull`: `Selection.all(1000×700)` → each kind: `mask.isFull`, `partialTileCount == 0`, canvas size swapped for 90°.
  - `emptyTilesStayEmpty`: rect (0,0,10,10) on 1000×700 → CW: only tile (2,0) is non-empty (x' = 690…699 → column 2).
  - `randomMaskMatchesOracle`: 40 seeded masks (sizes 1…700, antialiased random coverage, some `.full`/`.empty` tiles) → every kind equals a per-pixel oracle; normalized (`==` to `init(size:coverage:)` of the oracle).
  - `outlineBoundsMapped`: ellipse selection in rect (5,7,50,30) on 100×80 → CW outline `boundingBoxOfPath` == (80−37, 5, 30, 50) = (43,5,30,50) within 1e-9.
  - `invertedSelection`: `Selection(rect: (10,10,20,20)).inverted()` on 100×60 → flipH mask equals the oracle; the 20×20 hole is at (70,10).
- **Property — `PaintDotMacTests/Operations/FlipRotatePropertyTests.swift`** (`SeededRandom`, 60 iterations, seed printed; random sizes 1…600 per side, 1–3 layers with random sparse content, random selection or `nil`; compare every layer's `readPixels(in: bounds)`, sizes, and selection masks; paths compared by `boundingBoxOfPath` ± 1e-9):
  - `fourClockwiseIsIdentity`; `clockwiseThenCounterClockwiseIsIdentity` (both orders); `flipTwiceIsIdentity` (H and V); `rotate180EqualsBothFlips` (flipH∘flipV and flipV∘flipH); `twoClockwiseEqual180`. Use `transformedState` directly (treating `nil` as "unchanged") and `transformed` per surface.
  - `undoRedoRoundTrip`: random kind applied through a real `HistoryStack` + `DocumentSnapshotHistoryItem`; undo → every tile `sharesStorage` with (or `nil` like) the before-state and selection `==`; redo → equals the after-state.
- **Hosted — `PaintDotMacTests/Document/FlipRotateCommandTests.swift`** (`@MainActor`, real `UndoBridge`):
  - `appliesOneStep`: 400×300 → `runFlipRotate(.rotate90Clockwise, …)` → last step "Rotate 90° Clockwise", `state.image.size == 300×400`, `onStateChange` received `.structure`.
  - `commitsPendingEditFirst`: `prepareForNavigation` set to a closure that performs a fake "Finish Pixels" step and records the call; after `runFlipRotate(.flipHorizontal, …)` the closure ran once, before the state changed; steps end `["Finish Pixels", "Flip Horizontal"]`.
  - `ignoredWhenDisabled`: `gestureInProgress`, `isBusy`, `hasSheet` each true → no `prepareForNavigation` call, no step, state unchanged.
  - `noOpAddsNoStep`: 1×1 document → no step for every kind.
- **Integration — `PaintDotMacTests/Operations/FlipRotateIntegrationTests.swift`:** `undoRedoRoundTrip` — "New Image" 1000×700 white, dpi 150; a "Paintbrush" `TileDiffHistoryItem` (red rect (100,100,50,50)); "Rectangle Select" (100,100,50,50); Add New Layer (0024) with a blue pixel at (999,0); run CW, flipV, CCW, Rotate 180° → step names `["New Image","Paintbrush","Rectangle Select","Add New Layer","Rotate 90° Clockwise","Flip Vertical","Rotate 90° Counter-Clockwise","Rotate 180°"]`; after CW: size 700×1000, pixel (599,100) red (source (100,100) → (699−100, 100)), pixel (550,149) red (source (149,149)), blue at (699,999) (source (999,0)), selection bounds (550,100,50,50); after all four steps every layer equals `FlipRotateReference` applied in the same order to the pre-rotate layers; undo ×4 → size 1000×700, every tile shares storage with the pre-rotate state, selection restored, dpi 150, active layer index unchanged; redo ×4 → equals the final state; `.structure` reported on each undo/redo.
- **Menu — `PaintDotMacTests/App/MainMenuTests.swift`:** `imageMenuItems` now exactly `[Crop to Selection ⇧⌘X (cropToSelection:, menu.image.cropToSelection), Resize… ⌘R (resizeImage:, menu.image.resizeImage), Canvas Size… ⇧⌘R (resizeCanvas:, menu.image.resizeCanvas), separator, Flip Horizontal (no key, flipImageHorizontal:, menu.image.flipHorizontal), Flip Vertical (no key, flipImageVertical:, menu.image.flipVertical), separator, Rotate 90° Clockwise ⌘] (rotateImage90Clockwise:, menu.image.rotate90Clockwise), Rotate 90° Counter-Clockwise ⌘[ (rotateImage90CounterClockwise:, menu.image.rotate90CounterClockwise), Rotate 180° ⌘J (rotateImage180:, menu.image.rotate180), separator, Flatten ⇧⌘F (flattenImage:, menu.image.flatten)]` with exact key equivalents `"]"`, `"["`, `"j"` and modifier `[.command]` for the rotations, empty key equivalents for the flips; 0024's `imageMenuFlattenLast` and `noDuplicateShortcuts` pass.
- **UI — `PaintDotMacUITests/FlipRotateImageUITests.swift`** (fixture `UITestFixtures.writePNG` 300×200, pixel `(x % 256, y % 256, x >= 256 ? 200 : 100, 255)`, 96 DPI; decoded PNG pixels checked after ⌘S):
  - `testMenuItemsPresentAndEnabled`: open the Image menu → the five items exist with the exact titles and are enabled (no selection); Escape.
  - `testRotateClockwiseShortcutAndSavedPNG`: note `statusBar.zoom`; ⌘] → `statusBar.imageSize` "200 × 300", zoom unchanged, last History row "Rotate 90° Clockwise"; ⌘S, decode → size 200×300, (0,0) = `(0,199,100,255)`, (199,0) = `(0,0,100,255)`, (0,299) = `(43,199,200,255)`, (199,299) = `(43,0,200,255)`.
  - `testCounterClockwiseAnd180UndoRedo`: ⌘[ → "200 × 300", row "Rotate 90° Counter-Clockwise"; ⌘J → "200 × 300", row "Rotate 180°"; ⌘S, decode → (0,0) = `(0,199,100,255)` (CCW then 180 = CW); ⌘Z ⌘Z → "300 × 200"; ⇧⌘Z → "200 × 300".
  - `testFlipMenusAndSave`: Image ▸ Flip Horizontal (menu click) → rows "Flip Horizontal"; Image ▸ Flip Vertical → "Flip Vertical"; size "300 × 200"; ⌘S, decode → (0,0) = `(43,199,200,255)`, (299,199) = `(0,0,100,255)`; ⌘Z ⌘Z, ⌘S, decode → (0,0) = `(0,0,100,255)`.
  - `testSelectionRotatesWithImage`: launch with `-UITestSelectRect 0,0,100,50`; ⌘] → `statusBar.selectionSize` shows 50 × 100 (0014's format); Edit ▸ Deselect enabled; ⌘Z → 100 × 50.
- **Performance — `PaintDotMacTests/Performance/FlipRotatePerformanceTests.swift`** (XCTest `measure`): `testEachKind4000x3000` (per kind, gate 450 ms), `testRotateTenLayersWithSelection` (gate 4.5 s), `testMaskRotate4000x3000` (gate 300 ms). Report numbers.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build, no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open a landscape photo, ⌘]: it turns clockwise (the top edge is now on the right), the window keeps its zoom and the image is centred; ⌘[ twice and ⌘] once return to the original orientation; History shows four steps with the exact names.
  2. Layered `.ora` with a hidden layer and a 50%-opacity Multiply layer: Flip Horizontal, then toggle the hidden layer on — it is flipped too; opacity and blend mode unchanged.
  3. On a non-US keyboard layout (e.g. German), check that ⌘[ / ⌘] still trigger the rotate items (or note the actual key combination in `docs/shortcuts.md` for 0045).
  4. Make an elliptical selection, ⌘J: the marching ants turn with the image and sit on the same pixels; then Move Selected Pixels, drag, and ⌘] without pressing Return: "Finish Pixels" appears before "Rotate 90° Clockwise".

## Open questions

1. **Selection after Flip/Rotate.** The Paint.NET docs don't say what happens to the selection, and it could not be verified from its current behavior here (Paint.NET 3.36 may deselect, as 0035 assumed for Resize). This spec keeps the selection and transforms it with the image (exact mask permutation, outline mapped), and undo restores the original. The alternative is to deselect (as 0035 does for Resize Image). Recommended: transform it, as written — it is lossless here (unlike a resize) and keeps the user's work. Needs a PRD §5.5 IMG-4 / §12 entry.

## Out of scope

- Flip/rotate of a single layer and Layer Rotate/Zoom (L-7, spec 0060); arbitrary-angle image rotation.
- Rotating only the selected pixels (that is Move Selected Pixels, 0020).
- Resize Image (0035), Resize Canvas (0036), Auto-crop (0061).
- Moving the shortcuts into `ShortcutTable` (0045); a progress sheet for flip/rotate (not needed at the measured speeds).
