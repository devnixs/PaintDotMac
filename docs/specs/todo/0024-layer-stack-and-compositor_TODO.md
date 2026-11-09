# 0024 — Add layer stack operations, the Layers menu, Image > Flatten, and the Metal display compositor

> Source: PRD.md §5.4 L-1 (add, delete, duplicate, merge down, move up/down, flatten), §5.5 IMG-5 (Flatten), §5.12 (⇧⌘N Add New Layer, ⇧⌘⌫ Delete Layer, ⇧⌘D Duplicate Layer, ⌘E Merge Layer Down, ⇧⌘F Flatten), §4 *Rendering* (D-16: CPU reference compositor for flatten/merge/image sampling; Metal compositor for display only, ±1 per channel, golden tests), §5.7 H-1/H-6 (step names; undo doesn't change the active layer unless the step changed the layer stack; no-op adds no step), §6 NF-2 (pan/zoom ≥ 60 fps on a 10-layer 4K document — measured here), NF-1 (impact stated), NF-4/H-5 (step cost), NF-6 (golden tests), NF-9 (straight RGBA8, premultiplied only in the compositor), §12 D-12, D-16, D-17, D-34, D-40. AGENTS.md *Architecture rules* 1–4, 7; *Code style* (one blend mode per Metal function, named after the `BlendMode` case); *Testing expectations* (goldens in `PaintDotMacTests/Golden/`, ±1).
> Paint.NET docs (fetched 2026-11-05): Layers menu — https://www.getpaint.net/doc/latest/LayersMenu.html (now served at https://paint.net/doc/latest/LayersMenu.html); Image menu — https://www.getpaint.net/doc/latest/ImageMenu.html. Paint.NET 3.36 source (the last open-source release) for the merge/flatten math and naming details the docs don't state.
> Milestone: M3
> Depends on: 0023-gradient-tool (last M2 spec; M2 complete), 0010-history-panel (History panel rows used by the UI tests). Builds on 0002, 0003, 0006, 0008, 0009, 0012, 0013, 0020/0021 (floating pixels), 0022 (Image menu).

## Context

Not yet implemented (there is no application code; everything below is specified by the earlier specs):

- **Model (0002):** `struct Layer: Identifiable, Equatable, Sendable` (`id: UUID`, `name`, `isVisible`, `opacity: UInt8`, `blendMode: BlendMode`, `surface: TiledSurface`) in `PaintDotMac/Core/Model/Layer.swift`; `struct LayeredImage` (`size`, `dpi`, `layers` **index 0 = bottom**, `activeLayerIndex`, `activeLayer`, `isConsistent`, designated `init` with `precondition(isConsistent)`) in `Core/Model/LayeredImage.swift`. 0002 states: "Later specs that mutate `layers`/`size` (0024 layer ops …) keep `isConsistent` true and test it." `BlendMode` has only `.normal`; its raw value (`"normal"`) **is the Metal function name** (0002, AGENTS.md *Code style*). `TiledSurface` change tracking is `generation` + `changedTiles(since:)`; `Tile` is copy-on-write with `sharesStorage(with:)`; `tile(at:)` / `setTile(_:at:)`.
- **Display (0003):** `Core/Rendering/MetalCanvasRenderer.swift` draws **only `image.layers[0]`** ("0024 replaces this with the multi-layer `MetalCompositor` and must keep every other behavior of this spec", 0003 *Scope* item 8 and *Out of scope*). Its pipeline: per-frame change tracking on one layer (step 1a), per-tile upload of CPU-premultiplied, CPU-mipmapped textures at base level `L` (`TileMipmapper`, step 3), blit into an intermediate (step 4), one `canvas_fragment` pass with uniform `opacity` (step 5), deferred texture release (6), LRU budget eviction (7). `CanvasRendererStatistics` (`residentTileCount`, `residentTextureBytes`, `tilesUploadedLastFrame`, `lastFrameLevel`, `baseLevel(of:)`). Oracle: `PaintDotMacTests/Support/CanvasReferenceRenderer.swift`. 0003 says the 10-layer 4K part of NF-2 is measured here.
- **CPU compositor (0012):** `Core/Rendering/CPUCompositor.swift` — `composite(_:in:) -> CompositedRegion`, `compositeTile(_:of:) -> [ColorRGBA8]?` (nil when no visible layer with opacity > 0 has an allocated tile there), `flattened(_:) -> TiledSurface`. Algorithm: start transparent, for each visible layer with opacity > 0 bottom → top, `dst = BlendOps.blend(layer.blendMode, dst:, src:, opacity: layer.opacity)`. 0012: "the contract 0024's Metal compositor must match within ±1".
- **Blend math (0009):** `Core/Rendering/BlendOps.swift` — `mul255(a, b)` (`t = a·b + 128; ((t >> 8) + t) >> 8`, equal to `(a·b + 127) / 255`), `blend(_:dst:src:opacity:)` (first `src.a = mul255(src.a, opacity)`), `normal(dst:src:)`: `Sa == 0` → `dst` unchanged bit for bit; else `fa = Sa·255 + Da·(255 − Sa)`, `outA = (fa + 127) / 255`, `outC = (Sc·Sa·255 + Dc·Da·(255 − Sa) + fa/2) / fa` (UInt32, truncating division). 0009: "this formula is the normative one … and for the 0024 Metal parity (±1)."
- **History (0008, 0013):** `DocumentState` (`image`, `selection: Selection?`), `HistoryItem`, `DocumentSnapshotHistoryItem(name:icon:before:after:)` ("whole-structure changes — layer add/delete/duplicate/merge/move/flatten and layer properties (0024/0025)", `apply` assigns `after`, `revert` assigns `before`, `byteCost = HistoryCost.unsharedTileBytes(before:after:)`, `change = .structure`; carries the selection since 0013), `HistoryIcon` already has `layerAdd`, `layerDelete`, `layerDuplicate`, `layerMerge`, `layerMove`, `layerProperties`, `flatten` (0008) with SF Symbols mapped by 0010's `HistoryIcon+Symbol.swift`. `UndoBridge` (`Document/UndoBridge.swift`): `state`, `perform(_:)`, `updateLiveState(_:)`, `prepareForNavigation`, `onStateChange(HistoryChange)`; `.structure` → `DocumentWindowController` sets `canvasView.image` and calls `canvasView.invalidateAll()`.
- **Menu actions pattern (0013 item 15):** responder-chain `@objc` actions in `DocumentWindowController`; each returns early if `AppModel.dispatcher.isGestureInProgress`, calls `undoBridge.prepareForNavigation?()` (commits the active tool's pending edit, e.g. floating pixels from 0020/0021), builds the item from a pure command and `undoBridge.perform(item)`; `validateMenuItem` = `!isGestureInProgress && command.isEnabled(in: undoBridge.state)`. Menu item identifiers `menu.<menu>.<item>`.
- **Floating pixels (0020/0021):** `DocumentState.floatingPixels: FloatingPixels?` (default nil; invariant: its `layerID` exists and `underlay.size == image.size`), rendered straight into the active layer. `UndoBridge.pendingEditReason` (`PendingEditReason.command` / `.historyNavigation` / `.save`): `prepareForNavigation` with `.command` (every menu command, including this spec's) records **"Finish Pixels"** before the command's own step; undo/redo/jump/save never finish. 0020 states that snapshot operations (layer and canvas-size changes) only run with `floatingPixels == nil`.
- **Tools already target the active layer:** Paintbrush (0009), Pencil/Eraser (0011), Paint Bucket (0017), Erase/Fill Selection (0018), Cut/Copy/Paste (0021), Gradient (0023) write `image.layers[image.activeLayerIndex]` by layer ID. Color Picker "Image" sampling (0012) and Magic Wand / Paint Bucket "Image" sampling (0016/0017) already go through `CPUCompositor`. Until now every document has exactly one layer, so none of this was observable.
- **Saving (0005):** `ImageEncoder` throws `ImageCodecError.encodingFailed` ("The image couldn't be saved.") when `layers.count != 1` (interim rule 5). 0029's `SavePlan` adds flatten-on-export with the FMT-A confirmation; 0028 adds `.ora`.

Paint.NET behavior mirrored (LayersMenu.html, quoted):
- Add New Layer: "adds a new, completely transparent layer to the image immediately above the active layer." "The new layer will be given a generic name "Layer *X*" by default … *X* denotes the layer number." "New layers are filled with transparent black pixels (i.e. ARGB #00000000)."
- Delete Layer: "As all images must have at least one layer, the last remaining layer cannot be deleted."
- Duplicate Layer: "makes an exact copy of the active layer, including its contents, attributes and properties."
- Merge Layer Down: "Takes the active layer and combines or merges it into the layer immediately below it in the Layers Window list."
- Go to Layer Above / Below: "Shifts the editing focus to the layer immediately above / beneath the current one."
- Move Layer Up / Down: "Moves the active layer up one position / one position lower in the layer stack."
- Menu order: Add New Layer, Delete Layer, Duplicate Layer, Merge Layer Down, Toggle Layer Visibility, Import From File, Flip Horizontal, Flip Vertical, Rotate 180°, Rotate / Zoom, Go to Top Layer, Go to Layer Above, Go to Layer Below, Go to Bottom Layer, Move Layer to Top, Move Layer Up, Move Layer Down, Move Layer to Bottom, Layer Properties.
- Details the docs don't state, taken from Paint.NET 3.36's source (`AddNewBlankLayerFunction`, `DuplicateLayerFunction`, `MergeLayerDownFunction`, `Document.Flatten`): the new-layer number is `layers.count + 1` ("Layer 2" next to "Background"); the duplicate is named "`<name>` copy" and placed directly above the original; Merge Layer Down renders the upper layer onto the lower layer's pixels with the **upper** layer's blend op and opacity, and the merged layer keeps the **lower** layer's name and properties; Flatten renders the visible layers into the bottom layer. See *Open questions* 1–3 for the three points worth the user's confirmation; the spec already uses the recommended answers.

## User story

As a PaintDotMac user, I press ⇧⌘N to add a transparent "Layer 2" above the current one and paint on it without touching the background; I duplicate, delete, merge down, and reorder layers from the **Layers** menu, switch the layer I'm editing with Layers > Go to Layer Above/Below, flatten with Image > Flatten (⇧⌘F), see every visible layer composited on the canvas at every zoom, and undo or redo each of these as one named history step.

## Scope & changes

### Core — layer operations (pure, unit-tested)

1. **`PaintDotMac/Core/Operations/LayerOperations.swift`** (new):
   ```swift
   public enum LayerCommand: String, CaseIterable, Sendable {
       case addNewLayer, deleteLayer, duplicateLayer, mergeLayerDown, moveLayerUp, moveLayerDown, flatten
       public var name: String          // history step name = menu title (Paint.NET spelling)
       public var icon: HistoryIcon
       public func isEnabled(in state: DocumentState) -> Bool
       /// The new image, or nil when the command is disabled for `image`. Never mutates its input.
       public func applied(to image: LayeredImage, compositor: CPUCompositor = CPUCompositor()) -> LayeredImage?
       /// nil when disabled. before = state; after = state with image replaced (selection unchanged).
       public func makeHistoryItem(for state: DocumentState, compositor: CPUCompositor = CPUCompositor()) -> DocumentSnapshotHistoryItem?
   }
   public enum LayerNaming {
       public static let newLayerFormat = "Layer %d"
       /// "Layer N" with N = layers.count + 1, incremented while a layer with exactly that name exists.
       public static func newLayerName(existing layers: [Layer]) -> String
       /// "<name> copy" (no uniqueness check; Paint.NET allows duplicate names).
       public static func duplicateName(of name: String) -> String
   }
   public enum ActiveLayerStep: Sendable { case above, below
       /// The index the active layer moves to, or nil at the top/bottom.
       public func targetIndex(in image: LayeredImage) -> Int?
   }
   ```
   Names and icons (exact):

   | Case | `name` | `icon` | Enabled when (`i = activeLayerIndex`, `n = layers.count`) |
   |---|---|---|---|
   | `addNewLayer` | "Add New Layer" | `.layerAdd` | always |
   | `deleteLayer` | "Delete Layer" | `.layerDelete` | `n > 1` |
   | `duplicateLayer` | "Duplicate Layer" | `.layerDuplicate` | always |
   | `mergeLayerDown` | "Merge Layer Down" | `.layerMerge` | `i > 0` |
   | `moveLayerUp` | "Move Layer Up" | `.layerMove` | `i < n − 1` |
   | `moveLayerDown` | "Move Layer Down" | `.layerMove` | `i > 0` |
   | `flatten` | "Flatten" | `.flatten` | `n > 1` |

   Behavior of `applied(to:)` (every result satisfies `isConsistent`; size and dpi unchanged; layers not named below keep their `id`, properties, and tile storage — `sharesStorage` true):
   - **Add New Layer:** insert `Layer(name: LayerNaming.newLayerName(existing: layers), surface: TiledSurface(size: image.size))` (no allocated tiles = transparent black `#00000000`; visible, opacity 255, `.normal`, fresh `UUID`) at index `i + 1`; `activeLayerIndex = i + 1`.
   - **Delete Layer:** remove `layers[i]`; `activeLayerIndex = max(0, i − 1)` (the layer that was below becomes active; deleting the bottom layer makes the new bottom active).
   - **Duplicate Layer:** insert at `i + 1` a layer with a fresh `id`, `name = duplicateName(of: layers[i].name)`, the same `isVisible`, `opacity`, `blendMode`, and the **same `surface` value** (tiles shared copy-on-write, so the step costs 0 bytes); `activeLayerIndex = i + 1`.
   - **Merge Layer Down:** `lower = layers[i − 1]`, `upper = layers[i]`. Replace `lower.surface` with `compositor.merged(upper, onto: lower)` (item 2), keep `lower`'s `id`, `name`, `isVisible`, `opacity`, `blendMode`; remove `upper`; `activeLayerIndex = i − 1`. The upper layer's visibility is **not** consulted (Paint.NET 3.36 renders it regardless; see *Open questions* 2). The lower layer's own opacity, blend mode, and visibility are not applied to its pixels (they still apply when the merged layer is composited).
   - **Move Layer Up / Down:** swap `layers[i]` with `layers[i + 1]` / `layers[i − 1]`; the active index follows the moved layer (`i + 1` / `i − 1`).
   - **Flatten:** one layer with `id = layers[0].id`, `name = layers[0].name` ("Background" for opened and new images; see *Open questions* 3), visible, opacity 255, `.normal`, `surface = compositor.flattened(image)` (hidden and opacity-0 layers are discarded; unallocated composite tiles stay unallocated); `activeLayerIndex = 0`.
   - `makeHistoryItem(for:)`: `nil` when `!isEnabled(in:)`; else `DocumentSnapshotHistoryItem(name: name, icon: icon, before: state, after: DocumentState(image: applied, selection: state.selection, floatingPixels: nil))`. **Precondition `state.floatingPixels == nil`** (`assert` + doc comment): every caller finishes floating pixels first through `undoBridge.prepareForNavigation?()` (reason `.command`, 0020 item 9), so the snapshot never captures or drops a `FloatingPixels` value, and `FloatingPixels.layerID` can never point at a layer that a delete/merge/flatten removed or a move reordered. Both snapshots carry the selection (0013) and `floatingPixels == nil`. **The selection is never changed** by a layer command (it's a canvas-level path; the canvas size doesn't change). Every enabled command changes the layer list or the active index, so none is a no-op (H-6 has nothing to filter).
   - `ActiveLayerStep.targetIndex`: `.above` → `i + 1` if `i < n − 1` else nil; `.below` → `i − 1` if `i > 0` else nil.

   **History item decision — reuse 0008's `DocumentSnapshotHistoryItem`; no `Core/History/LayerHistoryItem.swift`.** Justification: (a) 0008 designed it for exactly these operations and computes the cost with `HistoryCost.unsharedTileBytes`, which is already optimal for value-typed CoW layers (Add = 0, Duplicate = 0, Move = 0, Delete = the deleted layer's unshared tiles, Merge = lower's rewritten tiles + upper's tiles, Flatten = all replaced tiles + the new ones); a bespoke item would store the same tiles; (b) `apply`/`revert` are O(layers) reference assignments; (c) its `.structure` change is exactly what the canvas needs (every visible composite tile may change after a reorder, merge, or delete); (d) it restores `activeLayerIndex` with the stack, which is what H-6 requires for layer-stack steps; (e) since 0013 it carries the selection (and since 0020 `floatingPixels`, always nil here), so undo of a layer step can't disturb it. The sibling map's `LayerHistoryItem.swift` is therefore not created. 0025's drag-reorder step reuses this item too (it changes the stack). 0025's "Layer Properties" and "Hide Layer"/"Show Layer" steps deliberately use a dedicated `LayerPropertiesHistoryItem` instead: a snapshot would restore `activeLayerIndex` on undo, and H-6 forbids that for a step that doesn't change the layer stack (0008's mention of layer properties under `DocumentSnapshotHistoryItem` is superseded by 0025 for that reason).

2. **`PaintDotMac/Core/Rendering/CPUCompositor.swift`** (extend 0012):
   ```swift
   /// Paint.NET Merge Layer Down: `upper` blended onto `lower`'s stored straight pixels with upper's blend
   /// mode and opacity; visibility of either layer is ignored. Result has lower.size.
   func merged(_ upper: Layer, onto lower: Layer) -> TiledSurface
   ```
   Per tile coordinate: if `upper.opacity == 0` or upper has no allocated tile there → the result tile **is** lower's tile (shared storage, or unallocated if lower has none). Otherwise per pixel of the valid (in-canvas) region: `out = BlendOps.blend(upper.blendMode, dst: lowerPixel, src: upperPixel, opacity: upper.opacity)`, with `lowerPixel = (0,0,0,0)` where lower has no tile. If lower had no tile and every `out` is `(0,0,0,0)`, the tile stays unallocated (sparse stays sparse). Edge-tile padding stays zero. Precondition `upper.size == lower.size` (programmer error). No other change to 0012's API or algorithm. 0026/0027 get new modes here for free through `BlendOps`.

### Core — Metal display compositor (pure Swift + Metal, no AppKit; GPU-tested)

3. **`PaintDotMac/Core/Rendering/Shaders/Blend.metal`** (new) — compute kernels, all **integer** arithmetic so the GPU is bit-exact with `BlendOps`/`TileMipmapper` (the ±1 tolerance is a safety margin, not an expected difference):
   - Shared helpers (`static inline`, in this file): `mul255(uint a, uint b)`: `t = a·b + 128; return ((t >> 8) + t) >> 8;` exactly as 0009; `blend_normal_op(uint4 dst, uint4 src) -> uint4` = 0009's Normal formula verbatim (`Sa == 0` → `dst` unchanged; `uint` arithmetic; truncating division).
   - A shared template `template <typename Op> inline void apply_layer(device uchar4* accum, device const uchar4* src, constant LayerBlendUniforms& u, uint2 gid)`: returns for `gid` outside `u.validSize`; `s = src[gid.y·256 + gid.x]`; `s.a = mul255(s.a, u.opacity)`; `accum[...] = Op::apply(accum[...], s)`.
   - **One kernel per blend mode, named exactly `BlendMode.rawValue`**: `kernel void normal(device uchar4* accum [[buffer(0)]], device const uchar4* src [[buffer(1)]], constant LayerBlendUniforms& u [[buffer(2)]], uint2 gid [[thread_position_in_grid]])` calling `apply_layer<NormalOp>`. 0026/0027/0059 add one `…Op` struct and one kernel per new case (AGENTS.md *Code style*).
   - `kernel void compositor_premultiply(device const uchar4* accum [[buffer(0)]], texture2d<uint, access::write> level0 [[texture(0)]], …)`: `rgb' = (rgb·a + 127) / 255`, `a' = a`, `a == 0` → `(0,0,0,0)` — identical to 0003's `TileMipmapper.premultiplied`; padding texels (outside `validSize`) written as 0.
   - `kernel void compositor_downsample(texture2d<uint, access::read> src [[texture(0)]], texture2d<uint, access::write> dst [[texture(1)]], uint2 gid)`: `dst = (s00 + s10 + s01 + s11 + 2) / 4` per channel — identical to `TileMipmapper.mipChain`.
   - `struct LayerBlendUniforms { uint opacity; uint2 validSize; }` declared here and mirrored by a Swift struct in `MetalCompositor.swift` (comment in both to keep them in sync).
   - Writes go through `.rgba8Uint` **texture views** (`makeTextureView(pixelFormat: .rgba8Uint)`) of the `.rgba8Unorm` tile textures (created with usage `.shaderRead | .shaderWrite | .pixelFormatView`), so integers land exactly, with no float conversion.

4. **`PaintDotMac/Core/Rendering/MetalCompositor.swift`** (new) — `@MainActor final class MetalCompositor`, imports `Metal` only:
   ```swift
   struct LayerBlendUniforms { var opacity: UInt32; var validSize: SIMD2<UInt32> }   // mirrors Blend.metal
   init(device: MTLDevice, library: MTLLibrary) throws(CanvasRendererError)   // one pipeline per BlendMode.allCases
                                                                              // (function name = rawValue) + premultiply + downsample;
                                                                              // a missing function → .functionMissing(name)
   /// Indices (bottom → top) of layers that contribute to `tile`: visible, opacity > 0, tile allocated. Pure.
   nonisolated static func contributingLayers(of image: LayeredImage, at tile: TileCoordinate) -> [Int]
   /// Encodes the composite of `tile` into `target` (a (256 >> baseLevel)² `.rgba8Unorm` texture with 7 − baseLevel
   /// mip levels, premultiplied, levels baseLevel…6). Returns false (encodes nothing) when no layer contributes.
   func encodeTile(_ tile: TileCoordinate, of image: LayeredImage, baseLevel: Int, into target: MTLTexture,
                   commandBuffer: MTLCommandBuffer) -> Bool
   /// Synchronous straight-alpha readback of one composite tile (commit + waitUntilCompleted).
   /// For tests and diagnostics only — never called on the display path. nil when no layer contributes.
   func compositeTilePixels(_ tile: TileCoordinate, of image: LayeredImage) -> [ColorRGBA8]?
   private(set) var layerTilesCopiedLastFrame: Int
   ```
   `encodeTile` algorithm: (1) `contributingLayers`; empty → return false. (2) Copy each contributing layer's tile bytes (0002 `tile(at:)`, 256 KB) into a staging `MTLBuffer` (`.storageModeShared`; pooled, returned to the pool only in the command buffer's completed handler, hopping to the main actor — never reused by an in-flight frame). (3) Accumulator buffer (256² `uchar4`, pooled likewise) zero-filled with a blit `fill`. (4) For each contributing layer bottom → top: dispatch the kernel named `layer.blendMode.rawValue` with `opacity = layer.opacity`, `validSize` = the tile's in-canvas size. (5) `compositor_premultiply` into level 0 of a full-chain 256² tile texture (the target itself when `baseLevel == 0`, else a pooled transient), then `compositor_downsample` level by level down to 6. (6) When `baseLevel > 0`, blit levels `baseLevel…6` of the transient into the target. This is the same per-tile result 0003's CPU path produced for one layer (`TileMipmapper.paddedPremultipliedTile` + `mipChain`), now for the whole stack.

5. **`PaintDotMac/Core/Rendering/CompositeChangeTracker.swift`** (new, pure, no Metal) — decides which composite tiles are stale, replacing 0003 step 1a's single-layer tracking:
   ```swift
   struct LayerStackSignature: Equatable, Sendable {   // everything except pixels that affects the composite
       var size: PixelSize
       var layers: [Entry]; struct Entry: Equatable, Sendable { var id: UUID; var isVisible: Bool; var opacity: UInt8; var blendMode: BlendMode }
       init(_ image: LayeredImage)
   }
   enum CompositeStaleness: Equatable, Sendable { case all, tiles(Set<TileCoordinate>) }
   struct CompositeChangeTracker: Sendable {
       mutating func update(for image: LayeredImage) -> CompositeStaleness
       mutating func reset()      // next update returns .all (invalidateAll)
   }
   ```
   `update`: `.all` on the first call, after `reset()`, when the signature differs (add/delete/reorder/visibility/opacity/blend mode/size), or when any layer's `surface.generation` is lower than the remembered one (an older surface swapped in, e.g. undo of a snapshot). Otherwise `.tiles(⋃ layers[k].surface.changedTiles(since: remembered[k]))` (all layers, hidden ones included — harmless and simpler). Then remembers the signature and every layer's generation. `activeLayerIndex` is **not** part of the signature (switching layers never recomposites).

### Platform glue — renderer, menus, window controller

6. **`PaintDotMac/Core/Rendering/MetalCanvasRenderer.swift`** (modify 0003) — switch to the multi-layer composite; every other 0003 behavior (transform, checkerboard, sampling, intermediate, seam-free tiling, texture lifetime, budget, `invalidateAll`, errors) is kept:
   - Owns a `MetalCompositor` (built from the same library in `init`) and a `CompositeChangeTracker`; resident tile textures are now **composite** tile textures.
   - Step 1a → `tracker.update(for: frame.image)`: `.all` marks every resident texture stale and forgets base levels; `.tiles(s)` marks those resident tiles stale. `invalidateAll()` also calls `tracker.reset()`.
   - Step 3 (per visible tile needing a texture): if `MetalCompositor.contributingLayers` is empty → drop any resident texture and skip (sparse, like 0003's "no allocated tile"); else create a fresh texture and `compositor.encodeTile(…, baseLevel: B, …)` **in the frame's command buffer** before the intermediate blit. **Base-level policy (new, for NF-2):** `B = 0` when `L ≤ 2` (zoom ≥ 25 %): composite tiles keep the full chain 0…6, so zooming anywhere between 25 % and 3200 % and panning re-composites nothing; `B = L` when `L ≥ 3` (zoom < 25 %), which bounds memory for huge images at low zoom (as 0003). A resident tile with base ≤ the needed level is reused as is (0003's rule).
   - Step 5: `CanvasUniforms.opacity = 1` (layer opacity and visibility are inside the composite now). An image with no contributing layer anywhere shows checkerboard only.
   - `CanvasRendererStatistics`: `tilesUploadedLastFrame` now counts **composite tiles built** in the frame (0003's tests keep their meaning); add `layerTilesCopiedLastFrame: Int` (Σ contributing layers over built tiles).
   - `TileMipmapper` stays (it is the oracle for the GPU kernels and for `CanvasReferenceRenderer`); the renderer no longer calls it.
   - Floating pixels (0020/0021): 0020 renders floating pixels straight into the live active layer (`FloatingPixels.render` writes `underlay ⊕ resampled source` into the layer's surface), so the compositor shows them like any other pixel edit through the changed tiles; no extra pass. 0020's tests stay green.
   - NF-1 impact: a paint stroke now re-composites each changed tile across all contributing layers (10 layers ≈ 2.5 MB copied per changed tile on unified memory); measured in the performance tests below, optimized further in 0048 if needed.

7. **`PaintDotMac/App/MainMenu.swift`** (extend):
   - New top-level **Layers** menu, inserted **right after the Image menu** (0022) and before Window (Paint.NET's bar order: File, Edit, View, Image, Layers, Adjustments, Effects, Window, Help; 0031 inserts Adjustments/Effects after Layers). Items in Paint.NET order (target nil, responder chain):

     | Title | Key equivalent | Modifiers | Action | Identifier |
     |---|---|---|---|---|
     | Add New Layer | `n` | ⇧⌘ | `addNewLayer(_:)` | `menu.layers.addNewLayer` |
     | Delete Layer | `"\u{8}"` (⌫) | ⇧⌘ | `deleteLayer(_:)` | `menu.layers.deleteLayer` |
     | Duplicate Layer | `d` | ⇧⌘ | `duplicateLayer(_:)` | `menu.layers.duplicateLayer` |
     | Merge Layer Down | `e` | ⌘ | `mergeLayerDown(_:)` | `menu.layers.mergeLayerDown` |
     | — separator — | | | | |
     | Go to Layer Above | none | | `goToLayerAbove(_:)` | `menu.layers.goToLayerAbove` |
     | Go to Layer Below | none | | `goToLayerBelow(_:)` | `menu.layers.goToLayerBelow` |
     | — separator — | | | | |
     | Move Layer Up | none | | `moveLayerUp(_:)` | `menu.layers.moveLayerUp` |
     | Move Layer Down | none | | `moveLayerDown(_:)` | `menu.layers.moveLayerDown` |

     Later specs slot in: 0030 "Import From File…" after Merge Layer Down; 0060 flips/rotate before Go to Layer Above; 0025 "Layer Properties…" at the end after a separator. PRD §5.12 gives no shortcut for Go to/Move Layer, so they get none (0045 audits).
   - **Image menu** (0022): append a separator and **Flatten** (`f`, ⇧⌘, action `flattenImage(_:)`, identifier `menu.image.flatten`) as the **last** item (Paint.NET's Image menu ends with Flatten).
   - **Temporary active-layer switch — decision:** "Go to Layer Above" / "Go to Layer Below" are Paint.NET's own Layers-menu items, so they are the switch until 0025's Layers panel and stay afterwards (no throwaway popup). Switching is **not** a history step and does not mark the document edited (Paint.NET doesn't record layer selection in history).

8. **`PaintDotMac/Document/LayerCommandRunner.swift`** (new, `@MainActor`, testable app-side glue):
   ```swift
   @MainActor enum LayerCommandRunner {
       /// Commits the pending tool edit first, then performs the command's item. Returns false when disabled.
       @discardableResult static func run(_ command: LayerCommand, bridge: UndoBridge, commitPendingEdit: () -> Void) -> Bool
       /// Commits the pending edit, then sets activeLayerIndex through bridge.updateLiveState (no history step,
       /// no change-count change, no canvas redraw needed: the composite doesn't depend on the active layer).
       @discardableResult static func goTo(_ step: ActiveLayerStep, bridge: UndoBridge, commitPendingEdit: () -> Void) -> Bool
   }
   ```
   `run`: `commitPendingEdit()` (in production `undoBridge.prepareForNavigation?()`, whose `pendingEditReason` is `.command`, so 0020's dispatcher records **"Finish Pixels"** for floating pixels) → `guard let item = command.makeHistoryItem(for: bridge.state) else { return false }` → `bridge.perform(item)` → true. The pending edit is committed **before** the item is built, so floating pixels land on the old active layer as their own "Finish Pixels" step first and `state.floatingPixels` is nil when the snapshot is taken (Paint.NET finishes Move Selected Pixels before a layer command). `goTo`: `commitPendingEdit()` → target index or return false → `bridge.updateLiveState { $0.image.activeLayerIndex = target }`.

9. **`PaintDotMac/Document/DocumentWindowController.swift`** (extend): `@objc` actions `addNewLayer(_:)`, `deleteLayer(_:)`, `duplicateLayer(_:)`, `mergeLayerDown(_:)`, `moveLayerUp(_:)`, `moveLayerDown(_:)`, `flattenImage(_:)`, `goToLayerAbove(_:)`, `goToLayerBelow(_:)`. Each: `guard !AppModel.shared.dispatcher.isGestureInProgress`; then `LayerCommandRunner.run(.x, bridge: undoBridge, commitPendingEdit: { undoBridge.prepareForNavigation?() })` (or `goTo`). `validateMenuItem`: enabled iff `!isGestureInProgress` and `command.isEnabled(in: undoBridge.state)` (Go to: `targetIndex != nil`). The existing `.structure` handling of `onStateChange` (0008: set `canvasView.image`, `invalidateAll()`, status bar) covers redraw; after `goTo` nothing needs redrawing. Tools keep reading `context.image.activeLayerIndex` at mouse-down, so painting lands on the newly active layer.

10. **`PaintDotMac/Core/IO/ImageEncoder.swift` / `ImageCodecError.swift`** (extend 0005's interim rule 5): a document with more than one layer can't be written to PNG until 0029 adds FMT-A's flatten-on-export confirmation. Replace the generic error for that case with `case layeredImageNeedsFlatten`, description "This image has more than one layer.", recovery suggestion "Choose Image > Flatten, then save again. Saving layered images arrives with OpenRaster (.ora) support." Zero layers stays `.encodingFailed`. 0029 removes this case.

11. **`PaintDotMacTests/Support/GoldenImage.swift`** (new test support — the shared golden helper for 0024, 0026, 0027, 0031+):
    ```swift
    struct GoldenComparison: Equatable, Sendable {
        let maxChannelDelta: Int; let mismatchCount: Int           // pixels with any channel delta > tolerance
        let firstMismatches: [(x: Int, y: Int, expected: ColorRGBA8, actual: ColorRGBA8)]  // up to 10, row-major
        var passed: Bool { mismatchCount == 0 }
    }
    enum GoldenImage {
        static let defaultTolerance = 1
        static var directory: URL { get }              // <repo>/PaintDotMacTests/Golden/, from #filePath
        static var isRecording: Bool { get }           // ProcessInfo env RECORD_GOLDENS == "1"
        /// Pure: straight RGBA8 buffers of equal size; `ignoreRGBWhereAlphaZero` compares only alpha where both alphas are 0.
        static func compare(_ actual: [ColorRGBA8], to expected: [ColorRGBA8], width: Int, height: Int,
                            tolerance: Int = defaultTolerance, ignoreRGBWhereAlphaZero: Bool = true) -> GoldenComparison
        /// Records an Issue (with the first mismatches) unless compare(...).passed.
        static func expectMatch(_ actual: [ColorRGBA8], _ expected: [ColorRGBA8], width: Int, height: Int,
                                tolerance: Int = defaultTolerance, sourceLocation: SourceLocation = #_sourceLocation)
        /// The golden workflow: always check actual vs oracle (±tolerance) first.
        ///  - not recording: load Golden/<name>.png (missing → Issue "Golden <name>.png missing; record it with
        ///    RECORD_GOLDENS=1 (TEST_RUNNER_RECORD_GOLDENS=1 for xcodebuild) after the oracle check passes"); compare ±tolerance.
        ///  - recording: if the oracle check failed → Issue, nothing written; else write `actual` as PNG
        ///    (0005 ImageEncoder, sRGB, straight alpha) and record an Issue "Recorded <name>.png — rerun without
        ///    RECORD_GOLDENS" so a recording run can never pass.
        static func assertGolden(_ actual: [ColorRGBA8], width: Int, height: Int, named name: String,
                                 oracle: [ColorRGBA8], tolerance: Int = defaultTolerance,
                                 sourceLocation: SourceLocation = #_sourceLocation)
        static func recordDecision(actual: [ColorRGBA8], oracle: [ColorRGBA8], width: Int, height: Int,
                                   tolerance: Int) -> RecordDecision   // pure: .write or .refuse(GoldenComparison)
        enum RecordDecision: Equatable { case write, refuse(maxChannelDelta: Int, mismatchCount: Int) }
    }
    ```
    Golden PNGs are read with 0002's `ImageDecoder` (straight alpha preserved, FMT-B) and stay well under 1 MB (AGENTS.md). They are located through `#filePath`, so no bundle resource is required; if XcodeGen copies `Golden/*.png` into the test bundle that is harmless.

12. **`project.yml`**: no structural change (new `.swift`/`.metal` files are picked up by the existing source globs); run `xcodegen generate`. New files: `Core/Operations/LayerOperations.swift`, `Core/Rendering/MetalCompositor.swift`, `Core/Rendering/CompositeChangeTracker.swift`, `Core/Rendering/Shaders/Blend.metal`, `Document/LayerCommandRunner.swift`, `PaintDotMacTests/Support/GoldenImage.swift`, `PaintDotMacTests/Golden/*.png` (recorded), and the test files below.

13. **PRD.md**: not edited by this spec (batch rule). The decisions above that the PRD doesn't yet state — layer naming, active layer after each command, merge/flatten math and naming, Go to Layer Above/Below without history, composite base-level policy, interim multi-layer PNG error — are listed under *Open questions* for the orchestrator to confirm and record in PRD §5.4/§12.

## Acceptance criteria

- [ ] L-1 Add New Layer (⇧⌘N): a transparent "Layer N" (N = count + 1, unique) is inserted directly above the active layer and becomes active. → `LayerOperationsTests.addInsertsAboveActive`, `.addFromMiddle`, `LayerNamingTests.*`, `LayersMenuUITests.testAddDuplicateMergeFlattenWithUndo`
- [ ] L-1 Delete Layer (⇧⌘⌫) removes the active layer, makes the layer below active (or the new bottom), and is disabled with one layer. → `LayerOperationsTests.deleteTopActivatesBelow`, `.deleteBottomActivatesNewBottom`, `.deleteDisabledWithOneLayer`, `LayersMenuUITests.testSingleLayerMenuState`
- [ ] L-1 Duplicate Layer (⇧⌘D) inserts "<name> copy" above with identical pixels and properties, sharing tiles, and makes it active. → `LayerOperationsTests.duplicateCopiesAbove`, `LayerHistoryTests.costs`
- [ ] L-1 Merge Layer Down (⌘E) blends the active layer into the one below with the upper layer's blend mode and opacity, keeps the lower's name/properties/id, makes it active, and is disabled on the bottom layer. → `CPUCompositorMergeTests.*`, `LayerOperationsTests.mergeDown*`
- [ ] L-1 Move Layer Up / Down reorder the active layer by one; the active index follows; disabled at the ends. → `LayerOperationsTests.moveUp`, `.moveDown`, `.moveDisabledAtEnds`
- [ ] L-1/IMG-5 Image > Flatten (⇧⌘F) produces one visible layer (opacity 255, Normal) equal to the CPU composite of the visible layers, named like the bottom layer; disabled with one layer. → `LayerOperationsTests.flatten*`, `LayersMenuUITests.testAddDuplicateMergeFlattenWithUndo`
- [ ] Every command is one history step with Paint.NET's name and icon; undo restores the exact previous state (layers, pixels, active index, selection), redo the exact next state; cost follows `HistoryCost`. → `LayerHistoryTests.*`, `LayerOperationsPropertyTests.randomSequencesUndoRedo`, `LayerWorkflowIntegrationTests.fullSession`
- [ ] Layer commands never change the selection; painting after them is still clipped to it. → `LayerHistoryTests.selectionUnchanged`, `LayerWorkflowIntegrationTests.selectionSurvivesLayerOps`
- [ ] Go to Layer Above/Below change the active layer without a history step or edited state, are disabled at the ends, and tools then paint on the new active layer only. → `ActiveLayerStepTests.*`, `LayerCommandRunnerTests.goToIsNotAHistoryStep`, `LayerWorkflowIntegrationTests.toolsPaintOnActiveLayer`
- [ ] H-6: undoing a pixel step after a layer switch doesn't change the active layer; undoing a layer step restores the active index of that step. → `LayerWorkflowIntegrationTests.undoKeepsActiveLayerH6`
- [ ] Pending tool edits are committed before a layer command or layer switch; floating pixels record "Finish Pixels" on the old active layer before the command's own step, and no layer snapshot carries floating pixels. → `LayerCommandRunnerTests.commitsPendingEditFirst`, `LayerWorkflowIntegrationTests.floatingPixelsFinishBeforeLayerCommand`
- [ ] Color Picker "Image" sampling reads the composite of all visible layers; "Layer" reads the active layer. → `LayerWorkflowIntegrationTests.colorPickerImageVsLayer`
- [ ] The canvas shows all visible layers composited with opacity (and blend mode), matching `CPUCompositor` within ±1 per channel at every tested zoom, with a golden image. → `MetalCompositorTests.*`, `MetalCanvasRendererTests.multiLayer*`, `MetalCompositorGoldenTests.*`
- [ ] Every `BlendMode` case has a Metal kernel of the same name. → `MetalCompositorTests.everyBlendModeHasKernel`
- [ ] Composite tiles are rebuilt only when needed: pixel edits rebuild only the changed tiles; layer structure/property changes rebuild everything visible; switching the active layer and panning/zooming between 25 % and 3200 % rebuild nothing. → `CompositeChangeTrackerTests.*`, `MetalCanvasRendererTests.multiLayerEditRebuildsOnlyChangedTile`, `.activeLayerSwitchRebuildsNothing`, `.zoomWithinFullChainRebuildsNothing`
- [ ] NF-2: pan/zoom on a 10-layer 3840×2160 document averages ≤ 16.7 ms per frame (gate: ≤ 50 ms). → `MetalCompositorPerformanceTests.testPanZoom10Layer4K` (number recorded in Verification status)
- [ ] Menus: Layers menu after Image with the items, order, shortcuts, and identifiers above; Image > Flatten last with ⇧⌘F. → `MainMenuTests.layersMenuItems`, `.imageMenuFlattenLast`, `.imageMenuItems` (0022's test, updated here to exactly `[Crop to Selection ⇧⌘X, separator, Flatten ⇧⌘F]`), `LayersMenuUITests.testSingleLayerMenuState`
- [ ] Saving a multi-layer image as PNG shows "This image has more than one layer." with the Flatten hint, no crash; after Flatten it saves and the file has the composite pixels. → `ImageEncoderTests.multiLayerNeedsFlatten`, `LayersMenuUITests.testPaintOnNewLayerFlattenAndSave`, `.testMultiLayerSaveShowsFlattenHint`
- [ ] `GoldenImage` compares ±1, refuses to record when the oracle disagrees, never passes while recording, and fails with instructions when a golden is missing. → `GoldenImageTests.*`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **One layer:** Delete Layer, Merge Layer Down, Move Layer Up/Down, Go to Layer Above/Below, and Flatten are disabled (menu) and `makeHistoryItem` returns nil (no step). Add and Duplicate are enabled.
- **Active at top / bottom:** Move Up and Go to Above disabled at the top; Merge Down, Move Down, Go to Below disabled at the bottom.
- **Hidden layers:** Flatten discards them. Merge Down merges a hidden upper layer anyway (3.36 behavior, *Open questions* 2) and keeps a hidden lower layer hidden. Tools still paint on a hidden active layer (0009 rule). The canvas skips hidden layers.
- **Opacity 0 upper layer:** Merge Down leaves the lower's pixels unchanged (tiles shared) but still removes the upper layer (a real step).
- **Sparse tiles:** a new layer allocates nothing; merging/flattening keeps unallocated tiles unallocated where the result is transparent; the canvas builds no texture for tiles where no layer contributes.
- **Edge tiles** (size not a multiple of 256, e.g. 300×300 or 1×1): merge/flatten/GPU composite process only the in-canvas region; padding stays zero.
- **Straight alpha with color under alpha 0:** `Sa == 0` source leaves the destination bit-identical on CPU and GPU; displayed RGB under alpha 0 never shows (premultiplied).
- **Many layers:** no layer-count limit (Paint.NET has none); Duplicate/Add cost no tile memory. 100 layers composite correctly (`MetalCompositorTests.hundredLayers`).
- **Huge images (65 535 px sides):** at zoom < 25 % composite tiles are built at base level L (memory bounded as in 0003); staging/accumulator buffers are pooled per in-flight frame, never per layer per frame unbounded.
- **Pending edits:** floating pixels ("Finish Pixels") or an in-progress shape/text are committed (their own step) before the layer command or Go to Layer switch; a command during a mouse drag is ignored (menu disabled). Undo/redo/jump never finish floating pixels (0020), and undoing a layer step can't bring back a floating state because layer steps are only recorded with `floatingPixels == nil`.
- **Undo/redo/jump across layer steps:** the snapshot restores layers and active index; the canvas does a full re-composite of visible tiles (`.structure` → `invalidateAll`). Undo budget dropping (H-5) works unchanged.
- **Undo of a layer step after a Go to Layer switch:** the active index returns to the one stored in the step's `before` (the step changed the layer stack; H-6).
- **Metal unavailable / missing kernel:** `MetalCompositor.init` throws `CanvasRendererError`, and the canvas follows 0003's existing error handling (no crash).
- **Saving a layered document as PNG:** alert with the Flatten hint, document stays open and edited (0005 error path).

## Test plan

Expected values below are hand-computed from 0009's Normal formula (`mul255(a, b) = (a·b + 127) / 255`) unless stated.

- **Unit — `PaintDotMacTests/Operations/LayerNamingTests.swift`:**
  - `newLayerNameCountsLayers`: `[Background]` → "Layer 2"; `[Background, Layer 2]` → "Layer 3"; `[A, B, C]` → "Layer 4".
  - `newLayerNameSkipsTakenNames`: `[Background, Layer 3]` → count+1 = 3 is taken → "Layer 4"; `[Layer 2, Layer 3]` → "Layer 4".
  - `duplicateName`: "Background" → "Background copy"; "Layer 2 copy" → "Layer 2 copy copy"; "" → " copy".
- **Unit — `PaintDotMacTests/Operations/LayerOperationsTests.swift`** (each also asserts `isConsistent`, unchanged `size`/`dpi`, and that untouched layers keep `id` and `sharesStorage` for every allocated tile):
  - `namesAndIcons`: the table above, exactly.
  - `enablementTable`: for n = 1 (i = 0), n = 3 with i = 0, 1, 2 → the enablement column, case by case.
  - `addInsertsAboveActive`: 300×200 white "Background" → 2 layers, `layers[1].name == "Layer 2"`, 0 allocated tiles, every sampled pixel `(0,0,0,0)`, visible, 255, `.normal`, new id ≠ background id, active 1.
  - `addFromMiddle`: 3 layers active 0 → new layer at index 1, active 1, former layers[1] now at 2.
  - `deleteTopActivatesBelow`: 3 layers active 2 → 2 layers, active 1, ids `[l0, l1]`; `deleteMiddle`: active 1 → ids `[l0, l2]`, active 0; `deleteBottomActivatesNewBottom`: active 0 → ids `[l1, l2]`, active 0; `deleteDisabledWithOneLayer`: `applied` nil, `makeHistoryItem` nil.
  - `duplicateCopiesAbove`: layer "Ink" (opacity 77, hidden, pixels seeded random) active 0 of 2 → index 1 is "Ink copy", opacity 77, hidden, same pixels, every tile `sharesStorage`, new id; active 1; former layers[1] at 2.
  - `mergeDownHandValues`: lower "Lower" `(255,0,0,255)` opacity 200, hidden, upper `(0,0,255,128)` opacity 255 → one layer: pixel `(127,0,128,255)`, `name == "Lower"`, opacity 200, hidden, `id == lower.id`, active 0.
  - `mergeDownUsesUpperOpacity`: lower opaque white, upper opaque red opacity 128 → `(255,127,127,255)`.
  - `mergeDownTwoSemiTransparent`: lower `(255,0,0,128)`, upper `(0,0,255,128)` → `(85,0,170,192)`.
  - `mergeDownHiddenUpperStillMerges`: upper hidden opaque blue over red → blue.
  - `mergeDownDisabledAtBottom`: active 0 → nil.
  - `mergeDownMiddleOfThree`: active 2 of 3 merges into index 1; layer 0 untouched; active 1.
  - `moveUp` / `moveDown`: ids reorder `[a,b,c]` active 1 → `[a,c,b]` active 2 / `[b,a,c]` active 0; `moveDisabledAtEnds`.
  - `flattenThreeLayers`: bottom opaque white "Background", middle `(255,0,0,255)` opacity 128, top `(0,0,255,255)` hidden → one layer, pixel `(255,127,127,255)`, name "Background", id = bottom id, visible, 255, `.normal`, active 0; pixels equal `CPUCompositor().flattened(before)` exactly over the full image.
  - `flattenUsesBottomName`: bottom named "Base" → result "Base".
  - `flattenAllHidden`: result has 0 allocated tiles.
  - `flattenDisabledWithOneLayer`.
- **Unit — `PaintDotMacTests/Rendering/CPUCompositorMergeTests.swift`:**
  - `opacityZeroSharesLowerTiles`: upper opacity 0 → every lower tile `sharesStorage` with the result.
  - `upperEmptyTileSharesLower`: 600×600, upper has only tile (1,1) allocated → result tiles other than (1,1) share lower's storage; (1,1) blended.
  - `transparentOverEmptyStaysSparse`: lower empty, upper tile allocated but all alpha 0 → result tile unallocated.
  - `zeroAlphaKeepsLowerBitIdentical`: upper `(10,20,30,0)` over lower `(1,2,3,200)` → `(1,2,3,200)`.
  - `edgeTilePaddingZero`: 300×300; tile (1,1) padding bytes beyond 44×44 are zero.
  - `mergeMatchesTwoLayerCompositeWhenLowerIsPlain`: 50 seeded random pairs, lower visible/255/normal → `merged` pixels equal `CPUCompositor.flattened` of the two-layer image with the upper forced visible (exact).
- **Unit — `PaintDotMacTests/History/LayerHistoryTests.swift`:**
  - `itemNamesIconsAndChange`: each command's item `name`, `icon`, `change == .structure`.
  - `applyRevertExact`: for each enabled command on a 3-layer 600×600 seeded stack with active 1: `revert(after)` == before state (`==` on `DocumentState`, including `activeLayerIndex`); `apply(before)` == after.
  - `selectionUnchanged`: state with `Selection(rect: (10,10,50,50))`; for each command `after.selection == before.selection`; after revert likewise.
  - `costs` (`HistoryCost`): Add = 0, Duplicate = 0, Move = 0; Delete of a layer with 3 allocated unshared tiles = 3 × `Tile.byteCount`; Merge where upper has 2 tiles over lower's 2 same-coordinate tiles = (2 lower before + 2 upper) + 2 new = 6 × `Tile.byteCount`.
- **Property — `PaintDotMacTests/Operations/LayerOperationsPropertyTests.swift` — `randomSequencesUndoRedo`:** 100 seeded runs (`SeededRandom`, seed printed): random 1–4 layer stacks (64×64 and one 300×300 per run, sparse random tiles, random visibility/opacity), 20 random commands each (only enabled ones, plus random Go to steps applied directly to `activeLayerIndex`), performed through a `HistoryStack` (0008). After each: `isConsistent`, layer ids unique. Undo all → state == initial; redo all → state == final.
- **Unit — `PaintDotMacTests/Operations/ActiveLayerStepTests.swift`:** `.above`/`.below` for n = 1, n = 3 at i = 0, 1, 2 (nil at ends).
- **Unit — `PaintDotMacTests/Rendering/CompositeChangeTrackerTests.swift`:** `firstUpdateIsAll`; `unchangedIsEmpty` (`.tiles([])`); `pixelEditOnAnyLayerReportsTiles` (write (300,10) on layer 2 of 3 → `.tiles([(1,0)])`); `hiddenLayerEditReportsTiles`; `visibilityChangeIsAll`; `opacityChangeIsAll`; `reorderIsAll`; `addAndDeleteAreAll`; `sizeChangeIsAll`; `olderGenerationIsAll` (swap in a copy captured before an edit); `activeLayerChangeIsEmpty`; `resetMakesAll`.
- **GPU — `PaintDotMacTests/Rendering/MetalCompositorTests.swift`** (Swift Testing, `@MainActor`, real `MTLCreateSystemDefaultDevice()`, default library of the app bundle as 0003's tests load it; comparisons with `GoldenImage.compare`, tolerance 1 unless "exact"):
  - `everyBlendModeHasKernel`: for each `BlendMode.allCases`, `library.makeFunction(name: rawValue) != nil`; init succeeds.
  - `handValuesExact`: 1×1 images; via `compositeTilePixels`: `(0,0,255,128)` over `(255,0,0,128)` → `(85,0,170,192)`; red opacity 128 over white → `(255,127,127,255)`; `(0,0,0,64)` over white → `(191,191,191,255)`; `(10,20,30,0)` over `(1,2,3,200)` → `(1,2,3,200)`; hidden top ignored; opacity-0 top ignored.
  - `contributingLayersRule`: hidden, opacity-0, and unallocated layers excluded; order bottom → top; empty → `encodeTile` returns false and `compositeTilePixels` nil.
  - `randomStacksMatchCPU`: 30 seeded stacks (1–10 layers, 600×600 so edge tiles are covered, random sparse tiles, alpha 0/255/random, random visibility/opacity): for every tile, `compositeTilePixels` vs `CPUCompositor.compositeTile` (RGB ignored where alpha is 0 in both) → passes at tolerance 1; additionally read back the encoded level-0 and every mip level of the target texture and compare with `TileMipmapper.paddedPremultipliedTile(cpu)` and `mipChain(level0:baseLevel:)` → tolerance 1. Seed printed on failure.
  - `baseLevelChain`: `encodeTile(baseLevel: 3)` → texture `32×32` with 4 levels, equal to `mipChain(…, baseLevel: 3)` within 1.
  - `edgeTilePadding`: 300×300 tile (1,1): premultiplied texels beyond 44×44 are exactly 0.
  - `hundredLayers`: 100 layers of `(255,255,255,3)` over transparent, 1×1 → equals CPU (±1).
- **Golden — `PaintDotMacTests/Rendering/MetalCompositorGoldenTests.swift`:**
  - `normalStack300`: 300×300 image, 4 layers generated in the test (bottom opaque horizontal gradient; red disc opacity 200; blue diagonal band `(0,0,255,128)`; a hidden green layer; one layer with only tile (1,1) allocated) → full-image straight composite from `compositeTilePixels` of the 4 tiles; `GoldenImage.assertGolden(…, named: "compositor-normal-stack-300", oracle: CPUCompositor().composite(image, in: full).pixels)`.
  - `canvasTenLayersAt50Percent`: a 512×512 10-layer stack rendered by `MetalCanvasRenderer` at zoom 0.5 into a 256×256 1× target → `assertGolden(named: "canvas-ten-layers-50", oracle: CanvasReferenceRenderer(pixels: CPUCompositor composite, opacity 1, visible))`.
- **GPU — `PaintDotMacTests/Rendering/MetalCanvasRendererTests.swift`** (extend 0003's):
  - `multiLayerMatchesOracleAtZooms`: 3-layer 700×500 seeded stack; zooms 1.0, 3.0, 0.5, 1/3, 0.1, 0.01, at 1× and 2× → readback equals `CanvasReferenceRenderer(CPUCompositor().composite(...).pixels, opacity: 1, isVisible: true)` within 1.
  - `multiLayerOpacityAndVisibility`: toggling a layer's visibility/opacity between frames changes the output to the new oracle; `tilesUploadedLastFrame` == number of visible non-empty tiles.
  - `multiLayerEditRebuildsOnlyChangedTile`: 1024×1024, 3 layers, all visible at 25 %; render; write one pixel in tile (2,1) of layer 1; render → `tilesUploadedLastFrame == 1`, `layerTilesCopiedLastFrame` == number of contributing layers at (2,1); output equals the oracle.
  - `activeLayerSwitchRebuildsNothing`: change only `activeLayerIndex` → 0 tiles built.
  - `zoomWithinFullChainRebuildsNothing`: render at 100 %, then 50 %, 25 %, 400 %, 3200 % over the same tiles → 0 tiles built after the first frame (base 0 kept); then 10 % (L = 3) → tiles reuse base 0 (0 built).
  - `structureChangeRebuildsVisible`: after `invalidateAll()` all visible non-empty tiles rebuild.
  - `emptyStackShowsCheckerboard`: all layers hidden → checkerboard only (`CheckerboardStyle` oracle), 0 resident tiles.
  - Update 0003's `zoomedOutUploadsCoarseBaseLevel` / `zoomingInUpgradesBaseLevel` to the new base-level policy: at 50 % base level is 0; at 10 % (L = 3) a fresh tile is built at base 3; zooming from 10 % to 100 % upgrades it to base 0. All other 0003 renderer tests stay unchanged and pass.
- **Unit — `PaintDotMacTests/Support/GoldenImageTests.swift`:** `identicalPasses`; `deltaOnePasses` (one channel +1 → `passed`, `maxChannelDelta == 1`); `deltaTwoFails` (`mismatchCount == 1`, `firstMismatches[0]` has the coordinates and both colors); `alphaZeroRGBIgnored` (both alpha 0, RGB differ by 200 → passes; with `ignoreRGBWhereAlphaZero: false` → fails); `sizeMismatchFails` (count ≠ width×height → `passed == false`, no crash); `recordDecisionRefusesWhenOracleDisagrees` (`.refuse(maxChannelDelta: 5, mismatchCount: 1)`); `recordDecisionWritesWhenOracleAgrees` (`.write`); `pngRoundTripIsExact` (write a 3×2 straight buffer incl. `(200,100,50,10)` and `(10,20,30,0)` with the same writer `assertGolden` uses to a temp dir, read back with `ImageDecoder` → identical including RGB under alpha 0); `directoryPointsAtGoldenFolder` (path ends with `PaintDotMacTests/Golden`).
- **Unit — `PaintDotMacTests/IO/ImageEncoderTests.swift`** (extend 0005's): `multiLayerNeedsFlatten` (2 layers → throws `.layeredImageNeedsFlatten`, `errorDescription == "This image has more than one layer."`, recovery suggestion contains "Image > Flatten"); 0005's `multiLayerRefused` updated to this case; zero layers → `.encodingFailed`.
- **Unit — `PaintDotMacTests/App/MainMenuTests.swift`** (extend): update 0022's `imageMenuItems` to expect exactly Crop to Selection (⇧⌘X), a separator, then Flatten (⇧⌘F); `layersMenuItems` — a top-level menu titled "Layers" directly after "Image" and before "Window"; items in the table's order with exact titles, key equivalents (`"n"`, `"\u{8}"`, `"d"`, `"e"`, none…), modifier masks, actions (`addNewLayer:` …), identifiers, separators at the stated positions. `imageMenuFlattenLast` — the Image menu's last item is "Flatten", key `"f"`, `[.command, .shift]`, action `flattenImage:`, preceded by a separator. `noShortcutCollisions` — the new key equivalents don't collide with any other item in the main menu (same key + modifiers).
- **Integration (headless, `@MainActor`) — `PaintDotMacTests/Document/LayerCommandRunnerTests.swift`** (real `UndoBridge` with `undoManager.groupsByEvent = false`, as 0010's tests):
  - `runPerformsOneStep`: Add → `history.steps.map(\.name) == ["New Image", "Add New Layer"]`; Edit undo title "Undo Add New Layer" (`undoManager.undoActionName == "Add New Layer"`); document edited.
  - `disabledReturnsFalse`: Delete on one layer → false, no step.
  - `commitsPendingEditFirst`: the `commitPendingEdit` closure commits a 1-tile `TileDiffHistoryItem` "Paintbrush" on layer 0; then Duplicate → steps `[…, "Paintbrush", "Duplicate Layer"]` and the duplicate contains the committed pixel (proves ordering).
  - `goToIsNotAHistoryStep`: 2 layers active 1; `goTo(.below)` → active 0, step count unchanged, `historyRevision` unchanged, `undoManager.canUndo` unchanged; `goTo(.below)` again → false.
- **Integration (headless) — `PaintDotMacTests/Integration/LayerWorkflowIntegrationTests.swift`** (UndoBridge + 0010's `BridgeToolContext` + real tools):
  - `toolsPaintOnActiveLayer`: 300×300 white image; Add New Layer; Paintbrush (black, width 10) drag (50,50)→(150,50) → layer 1 has opaque black at (100,50), layer 0 is still all white (every tile `sharesStorage` with before); Go to Layer Below; Pencil at (20,20) → layer 0 changes, layer 1 unchanged.
  - `colorPickerImageVsLayer`: image built directly: bottom opaque white, active top layer `(255,0,0,255)` at opacity 128 → Color Picker "Image" single pixel → `(255,127,127,255)`; "Layer" → `(255,0,0,255)`; hidden top → Image gives white.
  - `undoKeepsActiveLayerH6`: Add (active 1) → Go to Below (active 0) → stroke on layer 0 → undo → active still 0; undo again (Add New Layer) → 1 layer, active 0; redo → 2 layers, active 1 (from the step).
  - `floatingPixelsFinishBeforeLayerCommand`: 2 layers active 1, rect selection, Move Selected Pixels drag (+5, 0) through 0020's tool (floating); `LayerCommandRunner.run(.addNewLayer, bridge:, commitPendingEdit: { bridge.prepareForNavigation?() })` → last steps `"Move Pixels", "Finish Pixels", "Add New Layer"`; the moved pixels are on layer 1; `state.floatingPixels == nil`; the item's `before.floatingPixels` and `after.floatingPixels` are nil; undo → 2 layers, `floatingPixels == nil` (the Finish step is still done); undo again → floating again on layer 1. Same for `goTo(.below)`: "Finish Pixels" is recorded, then active 0, and no other step.
  - `selectionSurvivesLayerOps`: selection rect (0,0,100,100) via `DocumentState(selection:)`; Add, Duplicate, Move Down, Merge Down, Flatten, undo×5, redo×5 → selection equal throughout; a Paintbrush stroke across the selection edge after Add changes only pixels inside it on the new layer.
  - `fullSession`: New Image 1000×700 white; Add; stroke; Duplicate; Move Layer Down; Merge Layer Down; Add; stroke; Flatten → step names `["New Image","Add New Layer","Paintbrush","Duplicate Layer","Move Layer Down","Merge Layer Down","Add New Layer","Paintbrush","Flatten"]`; final pixels equal a hand-built oracle (the two strokes over white via `CPUCompositor`); undo all → equals the initial state; redo all → equals the final state; `HistoryListModel` (0010) row icons match the table.
- **UI tests — `PaintDotMacUITests/LayersMenuUITests.swift`** (fixture: 200×150 opaque white PNG generated at test time, `UITestApp` from 0001; History panel shown with ⌥⌘2):
  - `testSingleLayerMenuState`: Layers menu has the nine items in order; Add New Layer and Duplicate Layer enabled; Delete Layer, Merge Layer Down, Go to Layer Above/Below, Move Layer Up/Down disabled; Image > Flatten disabled.
  - `testAddDuplicateMergeFlattenWithUndo`: ⇧⌘N → `historyRow.1` label "Add New Layer"; Delete Layer, Merge Layer Down, Move Layer Down, Go to Layer Below enabled, Go to Layer Above and Move Layer Up disabled (new layer is on top). ⇧⌘D → "Duplicate Layer"; ⌘E → "Merge Layer Down"; ⇧⌘F → "Flatten", then Image > Flatten disabled. ⌘Z → Edit menu shows "Redo Flatten", Flatten enabled again; ⇧⌘Z → "Undo Flatten".
  - `testPaintOnNewLayerFlattenAndSave`: ⇧⌘N; press B; drag across the canvas center (primary black); Layers > Go to Layer Below; ⇧⌘N (new layer between) — Go to Layer Above enabled; ⇧⌘F; ⌘S → read the fixture file from disk: the dragged pixels are black (sampled along the stroke center), a corner is white, size 200×150.
  - `testMultiLayerSaveShowsFlattenHint`: ⇧⌘N; ⌘S → a sheet/alert with "This image has more than one layer." appears; dismiss with OK; window still open; app still running.
  - `testDeleteLayerShortcut`: ⇧⌘N, ⇧⌘⌫ → history row "Delete Layer"; Delete Layer now disabled.
- **Performance — `PaintDotMacTests/Rendering/MetalCompositorPerformanceTests.swift`** (XCTest `measure`, real device, offscreen 2560×1600 `.bgra8Unorm` target = a 1280×800-point window at 2×):
  - `testPanZoom10Layer4K` (NF-2): 3840×2160, 10 fully allocated layers (seeded noise, alpha mixed, opacities 255/200/128…, two hidden). Warm-up: one frame at each zoom used. Measured block: 120 frames alternating pan (scroll offset +37 device px per frame) and zoom steps through 25 %, 33 %, 50 %, 66.7 %, 100 %, 200 %, 400 % (0004 presets), each frame `encode` + `commit` + `waitUntilCompleted`. Report average ms/frame; target ≤ 16.7; **gate: average ≤ 50 ms** (3×). Record the number in Verification status.
  - `testSingleTileEditFrame` (NF-1 impact): same document at 100 %; per iteration write a 10×10 block into the top layer (one tile) and render → report ms/frame; gate ≤ 50 ms.
  - `testFullRecomposite10Layer4K`: `invalidateAll()` then one frame at fit-to-window zoom → report; gate ≤ 2 s.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green — clean build with no warnings, all tests pass with none skipped, UI tests ran, launch smoke passes. Goldens recorded once with `TEST_RUNNER_RECORD_GOLDENS=1` (only after the oracle check inside `assertGolden` passes), then the gate run without it.
- **Manual verification:**
  1. Open a photo, ⇧⌘N, paint over it with a semi-transparent color, set nothing else: strokes appear over the photo; Layers > Go to Layer Below then paint: strokes go under the earlier ones.
  2. Pan and pinch-zoom a 10-layer 4K document (build it: open a 4K photo, ⇧⌘D nine times): motion feels smooth (60 fps; check with Xcode's Metal HUD / `MTL_HUD_ENABLED=1`).
  3. Paint on the top layer of that document: no visible lag compared with a single-layer image.
  4. Zoom to 1 %, 12 %, 50 %, 100 %, 800 % on a layered image with transparency: no seams, no fringes, checkerboard correct, layers visible in the right order.
  5. History panel: each layer command shows its name and icon; clicking an earlier step restores the layer count (visible on the canvas) and redoing restores it.

## Open questions

These have recommended answers that the spec already uses; the implementer can proceed with them. The orchestrator should confirm them with the user and record them in PRD §5.4/§12 (this spec doesn't edit the PRD).

1. **Duplicate Layer name.** Paint.NET 3.36 names the copy "`<name>` copy"; the current docs say the duplicate is "named uniquely following the pattern described above (see Add New Layer)", which could mean "Layer N". **Recommended: "`<name>` copy"** (as the brief requested and as Paint.NET shows in practice).
2. **Merge Layer Down with a hidden upper layer.** Paint.NET 3.36 merges it regardless of visibility. **Recommended: merge regardless** (the user explicitly asked to merge; the content isn't silently discarded). Alternative: treat a hidden upper as contributing nothing.
3. **Flatten result name.** The brief says "Background"; Paint.NET flattens into the bottom layer, so the name is the bottom layer's ("Background" unless renamed). **Recommended: keep the bottom layer's name and id** — identical for every opened or new image.
4. **Active layer after Delete Layer.** Docs are silent. **Recommended: the layer below (`max(0, i − 1)`)**, as Paint.NET does.
5. **Interim PNG save of a layered image (until 0029).** **Recommended:** refuse with "This image has more than one layer." + "Choose Image > Flatten, then save again." rather than silently flattening (which would bypass FMT-A's confirmation).
6. **Layer selection is not a history step** and doesn't mark the document edited (Paint.NET behavior); "Go to Layer Above/Below" carry no shortcut until 0045.

## Out of scope

- Layers panel (thumbnails, drag-to-reorder, visibility checkboxes), Layer Properties dialog and its "Layer Properties" step, and the "Layer Properties…" menu item → **0025** (L-5, L-2). Toggle Layer Visibility menu item: not in v1.0 (the panel checkbox covers it; 0025 *Out of scope*).
- Blend modes beyond Normal in `BlendOps`, `Blend.metal`, goldens, and the brush list → **0026, 0027**; L-4 → **0059**.
- OpenRaster save/open (layered saving) → **0028**; flatten-on-export with the FMT-A confirmation and other flat formats → **0029**.
- Import From File, Copy Merged, Paste into New Layer, drag-and-drop as layer → **0030**.
- Layer flip/rotate/zoom → **0060**. Go to Top/Bottom Layer, Move Layer to Top/Bottom (not in L-1).
- Shortcut table refactor → **0045**; NF-1/NF-2 optimization beyond the measurements here → **0048**.
