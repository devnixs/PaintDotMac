# 0025 — Add the Layers panel (live thumbnails, drag-to-reorder, visibility checkboxes) and the Layer Properties dialog

> Source: PRD.md §5.4 L-5 (Layers panel with live thumbnails, drag-to-reorder, visibility checkboxes), L-2 (Layer properties: name, visibility, opacity 0–255, blend mode), L-1 (the panel's buttons reuse 0024's commands), §5.1 APP-2 (Layers panel, ⌥⌘3), §5.12 ("Layer Properties: double-click the layer row"), §5.7 H-6 (no-op actions add no step; undo doesn't change the active layer unless the step changed the layer stack), §6 NF-1 (painting latency must not suffer from thumbnails), NF-7 (VoiceOver labels), §7 principle 2 (every change is a `HistoryItem`), §12 D-5, D-15, D-34, D-36. Paint.NET docs: [Layers Window](https://paint.net/doc/latest/LayersWindow.html), [Layers Menu](https://paint.net/doc/latest/LayersMenu.html) (Layer Properties, Toggle Layer Visibility), [Working with Layers](https://paint.net/doc/latest/WorkingWithLayers.html).
> Milestone: M3 (Layers)
> Depends on: 0024-layer-stack-and-compositor (and transitively 0001–0023, in particular 0006, 0008, 0010, 0012)

## Context

There is no application code yet. When this spec is built, the earlier specs provide:

- **0002** `Core/Model/Layer.swift`: `struct Layer: Identifiable, Equatable, Sendable` (`id: UUID`, `name`, `isVisible`, `opacity: UInt8` 0–255, `blendMode: BlendMode`, `surface: TiledSurface`). `Core/Model/LayeredImage.swift`: `layers` (index 0 = bottom, last = top), `activeLayerIndex`, `activeLayer`, `isConsistent`. `Core/Model/BlendMode.swift`: `enum BlendMode: String, CaseIterable, Codable, Sendable` with `displayName` (`.normal` "Normal" only; 0026/0027 add cases). `TiledSurface` change tracking: `generation: UInt64` + `changedTiles(since:)`; `tile(at:)`; `Tile.sharesStorage(with:)` (0002 line 128 explicitly names 0025's thumbnails as a `generation` consumer).
- **0003** `Core/Rendering/CheckerboardStyle.swift` (`CheckerboardStyle.standard`: light #FFFFFF, dark #CCCCCC, top-left light), `Canvas/CanvasView.swift` (`image`, `invalidateAll()`).
- **0006** `App/PanelController.swift`: `PanelKind.layers` (title "Layers", ⌥⌘3, frame autosave `panel.layers`, accessibility `layersPanel`, `.resizable`, `becomesKeyOnlyIfNeeded = true`); `makeContent(for: .layers)` currently returns `PanelPlaceholderView(kind:)` ("Not available yet.", D-36). `App/AppModel.swift`: `activeSession: CanvasToolSession?` + observable `activeSessionGeneration`, `dispatcher.commitPendingEdit()`.
- **0008** `Core/History/HistoryItem.swift` (`HistoryItem` protocol: `name`, `icon`, `byteCost`, `change`, `isNoOp`, `apply(to:)`, `revert(_:)`; `DocumentSnapshotHistoryItem`), `HistoryChange` (`.pixels`, `.structure`), `HistoryIcon` (has `layerProperties`, `layerMove`, …), `HistoryCost`, `DocumentState` (`image`, + `selection` from 0013), `Document/UndoBridge.swift` (`state`, `history`, `historyRevision`, `updateLiveState(_:)`, `commit(_:)`, `perform(_:)`, `onStateChange`, `prepareForNavigation`), `Canvas/CanvasToolSession.swift` (`undoBridge`). `DocumentWindowController` maps `onStateChange(.structure)` to `canvasView.image = …; canvasView.invalidateAll()`.
- **0010** `Core/History/HistoryListModel.swift`, `Core/History/HistoryIcon+Symbol.swift` (exhaustive `symbolName` switch), `UI/HistoryPanelModel.swift` (bind-to-active-document pattern: weak bridge, `withObservationTracking` re-armed, `refreshCount`), `UI/HistoryPanelView.swift`. **This spec mirrors 0010's structure exactly**: a pure Core list model, an `@Observable` panel model owned by `AppModel`, and a SwiftUI view that only renders and forwards.
- **0012** `Core/Rendering/CPUCompositor.swift` (not used for thumbnails: a layer thumbnail shows that layer's own pixels, see below).
- **0020** `DocumentState.floatingPixels: FloatingPixels?` (rendered straight into the active layer; `layerID` must stay valid), `UndoBridge.pendingEditReason` (`PendingEditReason`): calling `undoBridge.prepareForNavigation?()` outside undo/redo/jump/save uses reason `.command`, which records **"Finish Pixels"** before the caller's own step. `prepareForNavigation` is the single "commit the pending tool edit" entry point for document commands (its closure already guards on the window's session being the active one).
- **0024** `Core/Operations/LayerOperations.swift`: `LayerCommand` (`addNewLayer`, `deleteLayer`, `duplicateLayer`, `mergeLayerDown`, `moveLayerUp`, `moveLayerDown`, `flatten`; `name`, `icon`, `isEnabled(in: DocumentState)`, `applied(to:)`, `makeHistoryItem(for:) -> DocumentSnapshotHistoryItem?`), `LayerNaming`, `ActiveLayerStep`. Layer-stack steps reuse 0008's **`DocumentSnapshotHistoryItem`** (no `LayerHistoryItem`); snapshots are only taken with `floatingPixels == nil` and carry the selection. `Document/LayerCommandRunner.swift`: `run(_:bridge:commitPendingEdit:)`, `goTo(_:bridge:commitPendingEdit:)`. `Core/Rendering/MetalCompositor.swift` + `CompositeChangeTracker` (display composites every visible layer with opacity and blend mode; any signature change — visibility, opacity, blend mode, order — rebuilds every visible tile; `activeLayerIndex` is not part of it). **Layers menu** actions on `DocumentWindowController`: `addNewLayer(_:)` ⇧⌘N, `deleteLayer(_:)` ⇧⌘⌫, `duplicateLayer(_:)` ⇧⌘D, `mergeLayerDown(_:)` ⌘E, `goToLayerAbove(_:)`, `goToLayerBelow(_:)`, `moveLayerUp(_:)`, `moveLayerDown(_:)`, and Image > Flatten `flattenImage(_:)` ⇧⌘F; `validateMenuItem` = `!isGestureInProgress && command.isEnabled(in: undoBridge.state)`. 0024 reserves the end of the Layers menu (after a separator) for this spec's "Layer Properties…".

### Paint.NET behavior this mirrors

- Layers Window: "There is always one active layer. It can be identified by the highlighting in the Layers Window." To change it, "click on any layer's name in the Layers Window." Double-click "on the layer name in the Layers Window" opens the Layer Properties dialog for that layer. "Click and 'drag' any layer in the Layers Window to relocate the layer in the list"; releasing the mouse drops it there.
- Layers Window buttons, in this order: **Add New Layer** (transparent layer above the active one), **Delete Layer** (the last remaining layer can't be deleted), **Duplicate Layer**, **Merge Layer Down**, **Move Layer Up**, **Move Layer Down**, **Layer Properties** (opens the dialog for the active layer).
- Layers menu: **Toggle Layer Visibility** "has the same functionality as checking and unchecking the layer visibility checkbox." **Layer Properties**: "In this dialog the layer name, visibility, blend mode and opacity can all be set."
- Paint.NET's Layer Properties dialog (Paint.NET 4/5) has a **General** group (Name, Visible) and a **Blending** group (Blend mode, Opacity as a slider plus a 0–255 numeric box). Changes preview live on the canvas; **Cancel** reverts them; **OK** records one history step named **"Layer Properties"**.
- Rows show, top to bottom, the top layer first: a thumbnail of the layer's own pixels on a checkerboard, the name, and a visibility checkbox.

## User story

As a PaintDotMac user, I open the Layers panel (⌥⌘3) and see every layer of the front document, top layer first, each with a live thumbnail, its name, and a visibility checkbox. The active layer is highlighted; clicking another row makes it active. Unchecking a box hides that layer on the canvas and adds a "Hide Layer" step I can undo. I drag a row up or down to reorder the stack (one "Move Layer Up"/"Move Layer Down" step). The buttons at the bottom add, delete, duplicate, merge down, move, and open properties exactly like the Layers menu. Double-clicking a row opens Layer Properties, where I rename the layer, hide it, change its blend mode, and set its opacity 0–255 with a slider or a number; the canvas previews every change, Cancel puts everything back, and OK adds a single "Layer Properties" step. While I paint, the active layer's thumbnail catches up within a fraction of a second without slowing the brush.

## Scope & changes

### Core (pure, unit-tested)

1. **`Core/Model/LayerProperties.swift`** (new):
   ```swift
   public struct LayerProperties: Equatable, Sendable {
       public var name: String
       public var isVisible: Bool
       public var opacity: UInt8          // 0–255 (L-2)
       public var blendMode: BlendMode
   }
   extension Layer { public var properties: LayerProperties { get set } }   // get/set the four fields; surface and id untouched
   ```

2. **`Core/History/LayerPropertiesHistoryItem.swift`** (new): `struct LayerPropertiesHistoryItem: HistoryItem` with `init(name: String, icon: HistoryIcon, layerID: Layer.ID, before: LayerProperties, after: LayerProperties)`.
   - `apply` sets `after` on the layer with `layerID`; `revert` sets `before`. Neither touches pixels, other layers, the selection, or `activeLayerIndex` (H-6: the step doesn't change the layer stack, so undo/redo never switch the active layer). A missing layer ID is unreachable through `HistoryStack`; guard with `assertionFailure` and do nothing.
   - `isNoOp = (before == after)` (H-6). `byteCost = 0` (the stack adds `stepOverheadBytes`). `change = .structure` (visibility, opacity, and blend mode change the composite everywhere; the canvas does a full refresh, which 0008 already maps to `invalidateAll()`).
   - **Why a dedicated item and not 0024's `DocumentSnapshotHistoryItem`** (decision, stated identically in 0024 item 1): a snapshot restores the whole `DocumentState`, including `activeLayerIndex`. Property and visibility steps don't change the layer stack, so by H-6 undoing them must not change the active layer — e.g. hide layer 0, click layer 2 in the panel, ⌘Z: layer 0 is shown again and layer 2 stays active. A snapshot would switch back to the layer that was active when the step was recorded. Steps that do change the stack (0024's commands and this spec's drag-reorder) keep using the snapshot. This supersedes 0008's mention of "layer properties" under `DocumentSnapshotHistoryItem`.
   - Never touches `floatingPixels`; callers finish floating pixels first (item 7), so the step is never recorded while pixels float.
   - **Named constructors** (same file, `extension LayerPropertiesHistoryItem`):
     - `static func properties(layerID:before:after:) -> Self` → name **"Layer Properties"**, icon `.layerProperties`.
     - `static func visibility(layerID:before:after:) -> Self` (only `isVisible` differs) → name **"Hide Layer"** when `after.isVisible == false`, **"Show Layer"** when true; icon `.layerVisibility` (new, item 3). See Open questions on the exact Paint.NET spelling.

3. **`Core/History/HistoryIcon.swift`** (extend 0008): add case `layerVisibility`. **`Core/History/HistoryIcon+Symbol.swift`** (extend 0010): `layerVisibility` → `eye`.

4. **`Core/Operations/LayerOperations.swift`** (extend 0024; 0024 has no multi-position move):
   ```swift
   public enum LayerMove {
       /// Moves the layer at `from` to index `to` (both 0 = bottom), shifting the layers between.
       /// The moved layer becomes active. nil when from == to or either index is out of range.
       public static func applied(from: Int, to: Int, in image: LayeredImage) -> LayeredImage?
       /// nil when `applied` is nil. Precondition (assert): state.floatingPixels == nil.
       public static func makeHistoryItem(from: Int, to: Int, for state: DocumentState) -> DocumentSnapshotHistoryItem?
   }
   ```
   The item is 0024's kind: `DocumentSnapshotHistoryItem(name:icon:before: state, after: DocumentState(image: moved, selection: state.selection, floatingPixels: nil))`, named **"Move Layer Up"** (`LayerCommand.moveLayerUp.name`) when `to > from` and **"Move Layer Down"** when `to < from`, icon `.layerMove`. Decision: a drag across several positions is a single step (one gesture = one undo), named after its direction. After the move, `activeLayerIndex` = `to` (Paint.NET: the dragged layer is the one selected); undo restores the previous order and active index (the step changed the stack, so H-6 allows it). `isConsistent` holds; every layer keeps its `id` and tile storage. For `|to − from| == 1` the result equals `LayerCommand.moveLayerUp/Down.applied(to:)` when `from` is the active index (tested).

5. **`Core/Model/LayerListModel.swift`** (new; mirrors 0010's `HistoryListModel`): mapping from the document to panel rows plus every click/drag/button decision, so the SwiftUI view only renders and forwards.
   ```swift
   public struct LayerRow: Identifiable, Sendable, Equatable {
       public let id: Layer.ID
       public let index: Int            // index in LayeredImage.layers (0 = bottom); used in accessibility ids
       public let name: String
       public let isVisible: Bool
       public let isActive: Bool
       public var accessibilityValue: String { isActive ? "active" : "inactive" }
   }
   public enum LayerPanelCommand: String, CaseIterable, Sendable {
       case addNewLayer, deleteLayer, duplicateLayer, mergeLayerDown, moveLayerUp, moveLayerDown, layerProperties
   }
   public struct LayerListModel: Sendable, Equatable {
       public init(image: LayeredImage)
       public static let empty: LayerListModel              // no document: no rows, every command disabled
       public let rows: [LayerRow]                          // DISPLAY order: top layer first (rows[0].index == layers.count - 1)
       public let activeIndex: Int?                         // nil when empty
       public func isEnabled(_ command: LayerPanelCommand) -> Bool
       public func displayPosition(ofLayerIndex i: Int) -> Int?      // count - 1 - i, nil if out of range
       public func layerIndex(atDisplayPosition p: Int) -> Int?      // count - 1 - p, nil if out of range
       /// SwiftUI List.onMove semantics in display order: `source` must contain exactly one position;
       /// `destination` is the display index the item is inserted before (0...count).
       /// Returns (from, to) as LAYER indices, or nil for multi-selection, out-of-range input, or a no-op drop.
       public func moveTarget(displaySource: IndexSet, displayDestination: Int) -> (from: Int, to: Int)?
       /// The visibility step for clicking the checkbox of layer `index`, or nil if out of range.
       public func visibilityToggle(forLayerIndex index: Int, in image: LayeredImage) -> LayerPropertiesHistoryItem?
   }
   ```
   - Enablement (must equal 0024's `LayerCommand.isEnabled(in:)` for the matching command; the test checks both): `addNewLayer`, `duplicateLayer`, `layerProperties` → enabled whenever a document is bound; `deleteLayer` → `layers.count > 1`; `mergeLayerDown`, `moveLayerDown` → `activeIndex > 0`; `moveLayerUp` → `activeIndex < layers.count - 1`. All disabled for `.empty`.
   - `moveTarget`: with `s` the single source position and `D` the destination, the new display position is `p = D > s ? D - 1 : D`; `p == s` → nil; otherwise `from = count-1-s`, `to = count-1-p`.
   - Defensive: an image that isn't `isConsistent` (should never happen) yields rows for the layers present and `activeIndex` clamped into range; never crash.

6. **`Core/Rendering/ThumbnailRenderer.swift`** (new): pure, `Sendable`, no AppKit; runs off the main actor.
   ```swift
   public struct ThumbnailImage: Equatable, Sendable { public let size: PixelSize; public let pixels: [ColorRGBA8] }  // opaque, row-major, top-left origin
   public struct ThumbnailRenderer: Sendable {
       public static let boxPixels = 80                          // 40 pt at 2× (row shows it at 40×40 pt)
       public static let checkerSquarePixels = 4                 // thumbnail-space square size, colors from CheckerboardStyle.standard
       /// Aspect-correct fit of `imageSize` into a square box; each side ≥ 1.
       public static func fittedSize(for imageSize: PixelSize, box: Int = boxPixels) -> PixelSize
       /// Renders one layer's own pixels (its visibility, opacity, and blend mode are IGNORED, as in Paint.NET)
       /// over the checkerboard. Checks Task.isCancelled once per output row; throws CancellationError if cancelled.
       public func render(_ surface: TiledSurface, box: Int = boxPixels) throws -> ThumbnailImage
   }
   ```
   - `fittedSize`: `scale = min(box / w, box / h)` (Double); `size = (max(1, round(w × scale)), max(1, round(h × scale)))`. Small images are scaled up (a 1×1 image gives an 80×80 thumbnail; a 1×65535 image gives 1×80).
   - Sampling: each thumbnail pixel `(tx, ty)` covers the source rect `[tx·w/W, (tx+1)·w/W) × [ty·h/H, (ty+1)·h/H)`. When `scale < 1` it is the **box-filter average of premultiplied** source pixels whose centers fall inside that rect (at least one source pixel — the one containing the rect's center if none do); when `scale ≥ 1`, nearest neighbor (the source pixel containing the rect's center). Absent tiles count as transparent and are skipped without reading memory. The averaged premultiplied color is composited **over** the checkerboard color of that thumbnail pixel: `out = src_premul + checker × (255 − A) / 255`, rounded to nearest, alpha 255. Checker color: light when `(tx / 4 + ty / 4)` is even.
   - Output is fully opaque, so the view can draw it without any further compositing.
   - **`ThumbnailCache`** (same file, value type): `mutating func needsRender(layerID:, surface:) -> Bool` and `mutating func store(_:for:surface:)`, `func thumbnail(for:) -> ThumbnailImage?`, `mutating func retain(only ids: Set<Layer.ID>)`. A cached entry keeps a copy of the `TiledSurface` it was rendered from (copy-on-write: no pixel copy). `needsRender` is true when there's no entry, when `surface.generation != cached.generation`, or when any tile coordinate's storage differs (`tile(at:)` presence differs, or `!sharesStorage(with:)`). Reason: snapshot undo (0008) can restore an older surface whose `generation` number collides with a newer, different one; keeping the rendered surface alive also guarantees tile addresses can't be reused. Deleted layers are dropped by `retain(only:)`.
   - **`ThumbnailThrottle`** (same file, value type, injected clock): `minimumInterval = 0.25 s`. `mutating func requestRender(now: TimeInterval) -> ThrottleDecision` returns `.renderNow` when ≥ 0.25 s have passed since the last render start (leading edge), otherwise `.scheduleAt(lastStart + 0.25)` (one trailing render; repeated requests inside the window coalesce into the same scheduled time). `mutating func didStartRender(at:)`. This bounds thumbnail work while a stroke is being painted to ≤ 4 renders per second per document.

### Platform glue

7. **`UI/LayersPanelModel.swift`** (new): `@MainActor @Observable final class LayersPanelModel`, one instance owned by `AppModel` (`layersPanel`), mirroring 0010's `HistoryPanelModel`.
   - `func bind(to session: CanvasToolSession?)`: holds the session's `undoBridge` **weakly**, observes `AppModel.activeSessionGeneration` exactly as 0010 does, and rebuilds `model = LayerListModel(image: bridge.state.image)` whenever the bound bridge's `state` or `historyRevision` changes (`withObservationTracking`, re-armed after each change; coalesce to one rebuild per run-loop turn). `private(set) var refreshCount`. No document → `.empty`, all buttons disabled, no rows.
   - `var isDocumentBusy: Bool` — true while the bound document window has an attached sheet (the Layer Properties dialog or any other sheet); then row clicks, checkboxes, drags, double-clicks, and buttons are disabled for that document.
   - **Pending edits first:** every mutating panel action (select, toggle visibility, drag-reorder, open properties) returns early while `AppModel.dispatcher.isGestureInProgress`, then calls **`bridge.prepareForNavigation?()`** (reason `.command`; floating pixels record "Finish Pixels" on the *old* active layer) and only then reads `bridge.state` to build its item or new state, so `state.floatingPixels == nil` when any item is built.
   - `func selectLayer(index:)`: no-op if out of range or already active. Otherwise `bridge.prepareForNavigation?()`, then `bridge.updateLiveState { $0.image.activeLayerIndex = index }`. **Selecting a layer is not a history step and does not mark the document edited** (Paint.NET; H-6) — only the "Finish Pixels" step, when pixels were floating, is recorded.
   - `func toggleVisibility(index:)`: `bridge.prepareForNavigation?()`, then `bridge.perform(LayerListModel(image: bridge.state.image).visibilityToggle(forLayerIndex:in:))`. It does not change the active layer.
   - `func move(displaySource:displayDestination:)`: compute `model.moveTarget`; nil → nothing; else `bridge.prepareForNavigation?()`, then `bridge.perform(LayerMove.makeHistoryItem(from:to:for: bridge.state))`.
   - `func perform(_ command: LayerPanelCommand)`: if `model.isEnabled(command)`, sends 0024's menu action selector — `addNewLayer(_:)`, `deleteLayer(_:)`, `duplicateLayer(_:)`, `mergeLayerDown(_:)`, `moveLayerUp(_:)`, `moveLayerDown(_:)` — or, for `.layerProperties`, `showLayerProperties(_:)` (item 9) with `NSApp.sendAction(_:to:from:)` targeted at the bound document's `DocumentWindowController`. Those actions already go through `LayerCommandRunner.run` (pending edit first), so the panel never re-implements a layer operation and menu and panel behave identically (L-1).
   - `func openProperties(index:)`: `selectLayer(index:)` then `perform(.layerProperties)` (double-click: Paint.NET opens the dialog for the clicked layer, which becomes active).
   - Thumbnails: `private(set) var thumbnails: [Layer.ID: CGImage]` (the only AppKit/CG conversion: `ThumbnailImage` → `CGImage` in a small helper `ThumbnailImage+CGImage.swift` in `UI/`). On each refresh, for layers where `ThumbnailCache.needsRender` is true, ask `ThumbnailThrottle`; render in **one** `Task.detached(priority: .utility)` per document at a time (the previous task is cancelled when a new render starts), copying the needed `TiledSurface` values (COW, no pixel copy) before leaving the main actor. Results are stored back on the main actor only if the layer still exists; a result is still cached against the surface it was rendered from, so a newer generation triggers another (throttled) render. Switching documents cancels the task. Thumbnails are never computed on the main actor.

8. **`UI/LayersPanelView.swift`** (new): hosted by `PanelController` for `PanelKind.layers`, replacing 0006's placeholder. Panel title "Layers" (0006).
   - A `List` of `model.rows` (display order, top layer first) with `.onMove` → `move(displaySource:displayDestination:)`, then a footer bar with seven icon buttons in Paint.NET's order: Add New Layer (`plus.square.on.square`), Delete Layer (`minus.square`), Duplicate Layer (`square.on.square`), Merge Layer Down (`square.stack.3d.down.right`), Move Layer Up (`arrow.up`), Move Layer Down (`arrow.down`), Layer Properties (`slider.horizontal.3`) — the same symbols as 0010's history icons where they exist. Tooltips and accessibility labels are the Paint.NET names ("Add New Layer", "Delete Layer", "Duplicate Layer", "Merge Layer Down", "Move Layer Up", "Move Layer Down", "Layer Properties"). Disabled per `isEnabled` and `isDocumentBusy`.
   - Row: thumbnail at 40×40 pt (the CGImage drawn aspect-fit, centered, with a 1 px `separatorColor` border; a neutral placeholder rectangle until the first render arrives), the name (one line, truncated in the middle), and a trailing checkbox (`Toggle(.checkbox)`) bound to `isVisible` whose action calls `toggleVisibility(index:)` (the toggle never writes state itself; the model refresh sets its value). The active row uses the selection highlight (accent background); selection is driven by `model.activeIndex`, not by SwiftUI's own `List` selection (same approach as 0010).
   - Single click on the row (outside the checkbox) → `selectLayer(index:)`; double click → `openProperties(index:)`. Clicking the checkbox does not select the row.
   - The list scrolls the active row into view when the active index changes.
   - Accessibility (NF-7 and UI tests): content root `layersPanel` (0006); list `layersList`, label "Layers"; each row `layerRow.<index>` (`index` = layer index, 0 = bottom), label = layer name, value = `"active"`/`"inactive"`, `.isSelected` trait on the active row, default action = select; checkbox `layerVisibility.<index>`, label "Visible" + layer name (e.g. "Visible: Background"), value 1/0; thumbnail image `layerThumbnail.<index>` (decorative label "Thumbnail"); footer buttons `layers.add`, `layers.delete`, `layers.duplicate`, `layers.mergeDown`, `layers.moveUp`, `layers.moveDown`, `layers.properties`.

9. **`UI/LayerPropertiesDialog.swift`** (new) + **`UI/LayerPropertiesDialogModel.swift`** (new, `@MainActor @Observable`):
   - Presented by `DocumentWindowController.showLayerProperties(_:)` (new action) as a **sheet** on the document window (`NSHostingController` in `window.beginSheet`), for the **active layer**. Window title / heading **"Layer Properties"**. The sheet window's delegate returns its own private `UndoManager` from `windowWillReturnUndoManager`, so ⌘Z inside the name field never reaches document history. While the sheet is attached, the document controller's menu actions are not in the responder chain (they are disabled), and `LayersPanelModel.isDocumentBusy` is true.
   - Layout (Paint.NET grouping): **General** — "Name:" text field (`layerProperties.name`), "Visible" checkbox (`layerProperties.visible`); **Blending** — "Blend mode:" pop-up (`layerProperties.blendMode`) listing `BlendMode.allCases` by `displayName` in enum order (only implemented modes: just "Normal" until 0026/0027 add cases; D-15), "Opacity:" slider 0–255 step 1 (`layerProperties.opacitySlider`) plus an integer field (`layerProperties.opacityField`). Buttons **Cancel** (`layerProperties.cancel`, Escape) and **OK** (`layerProperties.ok`, default button, Return). Root identifier `layerProperties`.
   - Model: `init(layerID:, original: LayerProperties, apply: @escaping (LayerProperties) -> Void)`; `var edited: LayerProperties`; every change calls `apply(edited)` (live preview); `func cancel()` calls `apply(original)` and closes; `func ok() -> LayerPropertiesHistoryItem?` returns `.properties(layerID:before: original, after: edited)` (nil-free; the stack ignores it when `isNoOp`). The window controller's `apply` closure is `undoBridge.updateLiveState { set properties on layerID }` followed by the `.structure` canvas refresh (`canvasView.image = …; canvasView.invalidateAll()`) — live preview never records history. On OK the controller calls `undoBridge.commit(item)` (state already holds `edited`). Exactly one "Layer Properties" step per OK with changes; none for OK without changes; none for Cancel (H-6).
   - Opacity field parsing (pure, in the model file, tested): `static func parseOpacity(_ text: String, fallback: UInt8) -> UInt8` — trims whitespace; an integer clamps to 0…255 (`"300"` → 255, `"-5"` → 0); a decimal rounds half up (`"127.5"` → 128); empty or non-numeric → `fallback` (the last valid value). Applied when the field commits (Return/focus loss); the slider and the field always show the same value.
   - Name: taken as typed (no trimming; an empty name is allowed, as in Paint.NET). Live preview updates the panel row's name.
   - `showLayerProperties(_:)` returns early while `isGestureInProgress`, then calls `undoBridge.prepareForNavigation?()` (floating pixels → "Finish Pixels") before reading the active layer's properties. It is a no-op if a sheet is already attached. `validateMenuItem`: enabled iff `!isGestureInProgress` and no sheet is attached.

10. **`App/MainMenu.swift`** (modify 0024's Layers menu): append a separator and **"Layer Properties…"** as the last item (no key equivalent; PRD §5.12 maps it to double-click; identifier `menu.layers.properties`, action `showLayerProperties(_:)`, target nil), enabled per item 9's `validateMenuItem`. Extend 0024's `MainMenuTests.layersMenuItems` with it.

11. **`App/PanelController.swift`** (modify): `.layers` → `LayersPanelView(model: AppModel.shared.layersPanel)`. With 0007, 0010, and this spec done, no panel uses `PanelPlaceholderView` any more: delete it and its tests (`PanelControllerTests.placeholderIdentifiers`, `PanelsUITests.testPlaceholderText`). **`App/AppModel.swift`** (modify): own `layersPanel: LayersPanelModel` and start its active-session observation alongside `historyPanel`.

12. New files: `Core/Model/LayerProperties.swift`, `Core/Model/LayerListModel.swift`, `Core/History/LayerPropertiesHistoryItem.swift`, `Core/Rendering/ThumbnailRenderer.swift`, `UI/LayersPanelModel.swift`, `UI/LayersPanelView.swift`, `UI/LayerPropertiesDialog.swift`, `UI/LayerPropertiesDialogModel.swift`, `UI/ThumbnailImage+CGImage.swift`, and the tests below. Modified: `HistoryIcon.swift`, `HistoryIcon+Symbol.swift`, `LayerOperations.swift`, `DocumentWindowController.swift`, `MainMenu.swift`, `PanelController.swift`, `AppModel.swift`. Run `xcodegen generate`. No new persisted defaults (so no `LaunchOptions.resettableKeyPrefixes` change). No PRD change.

Cross-cutting rules: every layer-property change goes through `UndoBridge` (live preview via `updateLiveState`, final step via `commit`/`perform`); Core files import no AppKit/SwiftUI; thumbnails off the main actor, cancellable, throttled; panel UI on `@MainActor`.

## Acceptance criteria

- [ ] Window > Layers (⌥⌘3) shows the Layers panel instead of "Not available yet."; rows are listed top layer first with thumbnail, name, and checkbox. → `LayerListModelTests.rowsAreTopFirst`, `LayersPanelUITests.testPanelListsLayersTopFirst`
- [ ] The active layer is highlighted; clicking a row makes it active without adding a history step or marking the document edited. → `LayersPanelIntegrationTests.selectLayerIsNotAHistoryStep`, `LayersPanelUITests.testClickRowSelectsLayer`
- [ ] Selecting a layer, toggling visibility, dragging, or opening properties while pixels float first records "Finish Pixels" with the pixels on the old active layer; no property/visibility/move step is recorded while `floatingPixels != nil`. → `LayersPanelIntegrationTests.panelActionsFinishFloatingPixelsFirst`
- [ ] Unchecking/checking a visibility box hides/shows the layer on the canvas composite and adds one "Hide Layer"/"Show Layer" step; undo/redo restore it; the active layer is unchanged. → `LayerPropertiesHistoryItemTests.visibilityNamesAndRoundTrip`, `LayersPanelIntegrationTests.toggleVisibilityStepAndComposite`, `LayersPanelUITests.testVisibilityCheckboxAddsHistoryStep`
- [ ] Dragging a row reorders the stack as one "Move Layer Up"/"Move Layer Down" step; the moved layer becomes active; undo restores the order. → `LayerListModelTests.moveTargetMapping`, `LayerOperationsMoveTests.*`, `LayersPanelUITests.testDragReorders`
- [ ] The seven footer buttons run the same commands as the Layers menu, with the same enablement. → `LayerListModelTests.enablementMatchesMenuValidation`, `LayersPanelUITests.testFooterButtons`
- [ ] Double-clicking a row (or the Properties button / Layers > Layer Properties…) opens Layer Properties for that layer with Name, Visible, Blend mode (implemented modes only), Opacity 0–255 slider + field. → `LayersPanelUITests.testDoubleClickOpensProperties`, `LayerPropertiesDialogModelTests.blendModeListIsImplementedModes`
- [ ] Changes in the dialog preview live; Cancel restores the original properties with no step; OK records exactly one "Layer Properties" step (none if nothing changed); undo/redo round-trip. → `LayerPropertiesDialogModelTests.*`, `LayersPanelIntegrationTests.propertiesDialogFlow`, `LayersPanelUITests.testPropertiesOKAndCancel`
- [ ] Opacity field input is clamped/rounded/rejected as specified. → `LayerPropertiesDialogModelTests.parseOpacity`
- [ ] Undoing a property or visibility step never changes the active layer (H-6). → `LayerPropertiesHistoryItemTests.keepsActiveLayerAndSelection`
- [ ] Thumbnails show the layer's own pixels, aspect-correct, over a checkerboard, and update after painting (throttled, off the main actor); stale/cancelled renders never overwrite newer ones. → `ThumbnailRendererTests.*`, `ThumbnailCacheTests.*`, `ThumbnailThrottleTests.*`, `LayersPanelIntegrationTests.thumbnailUpdatesAfterEdit`, manual 3
- [ ] The panel follows the active document and is empty with disabled buttons when no document is open. → `LayersPanelIntegrationTests.followsActiveDocument`, `LayersPanelUITests.testPanelFollowsActiveDocument`
- [ ] Quality gate green; the app launches, opens a PNG and a JPEG, and stays up with no crash report (launch smoke).

## Edge cases

- **Single layer:** Delete disabled; Merge Down and Move Down disabled (active index 0); Move Up disabled. Drag of the only row → nil target, nothing happens.
- **Hiding every layer:** allowed; canvas shows only the checkerboard. Hiding the active layer is allowed and painting still affects it (0009 rule).
- **Drop on the same position / multi-row drag / out-of-range destination:** `moveTarget` → nil, no step.
- **Opacity 0 and 255, blend Normal only:** opacity 0 makes the layer invisible in the composite but its thumbnail still shows its pixels (thumbnails ignore opacity, visibility, blend mode).
- **Dialog OK with no change, or changing a value and changing it back:** no step (`isNoOp`). Cancel after many previews restores exactly `original` (all four fields).
- **Empty name / very long name / Unicode:** stored as typed; row truncates in the middle; no crash.
- **Opacity text** "", "abc", "-5", "300", "127.5", " 42 ": fallback, fallback, 0, 255, 128, 42.
- **Tiny and extreme aspect images:** 1×1 → 80×80 nearest-neighbor thumbnail; 65,535×1 → 80×1; 1×65,535 → 1×80 (no zero-sized thumbnail, no division by zero).
- **Sparse layers:** a new empty layer's thumbnail is pure checkerboard and reads no tile memory.
- **Fast painting:** at most 4 thumbnail renders/second per document; a render in flight for an old surface is cancelled when a newer one starts; a result for a deleted layer is dropped.
- **Snapshot undo restoring an older surface with a colliding generation:** detected by the storage comparison in `ThumbnailCache` and re-rendered.
- **Pending tool edit** (floating pixels from 0020/0021, or an uncommitted shape later): selecting a layer, toggling visibility, dragging, or opening properties calls `prepareForNavigation` first, so floating pixels are finished ("Finish Pixels") on the layer they were lifted from before the active layer changes. Undo of a later panel step never re-enters a floating state on the wrong layer.
- **Sheet already open / document busy:** panel controls disabled for that document; a second `showLayerProperties` is a no-op; menu items targeting the document are disabled.
- **Closing the document / switching documents while a thumbnail render runs:** task cancelled, no crash, panel rebinds.
- **Defensive inconsistent image:** rows built, active index clamped, no crash.

## Test plan

- **Unit tests**
  - `PaintDotMacTests/Model/LayerListModelTests.swift`:
    - `rowsAreTopFirst`: 3 layers A(0), B(1), C(2), active 1 → rows names `[C, B, A]`, indices `[2, 1, 0]`, only B `isActive`, B's `accessibilityValue == "active"`, others `"inactive"`; `isVisible` copied per layer.
    - `emptyModel`: `.empty.rows.isEmpty`, `activeIndex == nil`, every command disabled.
    - `enablementMatchesMenuValidation`: for stacks of 1, 2, 3 layers and every active index, the table from item 5 (hand-written expected values) **and** equality with `LayerCommand.<matching case>.isEnabled(in: DocumentState(image:))` for the six layer commands.
    - `moveTargetMapping` (count 4, hand-computed): source {0}, dest 2 → (3, 2); source {0}, dest 4 → (3, 0); source {3}, dest 0 → (0, 3); source {2}, dest 1 → (1, 2); source {1}, dest 1 → nil; source {1}, dest 2 → nil; multi {0,1} → nil; source {5} → nil; dest 9 → nil.
    - `displayIndexConversion`: count 3: position 0 ↔ layer 2; out of range → nil.
    - `inconsistentImageDoesNotCrash`: `activeLayerIndex` set out of range on a copy → `activeIndex` clamped.
  - `PaintDotMacTests/History/LayerPropertiesHistoryItemTests.swift`:
    - `applyRevertRoundTrip`: 2 layers; item for layer 1 before (name "L", visible, 255, normal) after ("X", hidden, 128, normal) → `apply` gives exactly the after properties on layer 1, layer 0 untouched, surfaces identical (`sharesStorage` on every tile); `revert` restores before.
    - `visibilityNamesAndRoundTrip`: `.visibility(... after.isVisible false)` → name "Hide Layer", icon `.layerVisibility`; true → "Show Layer"; `.properties` → "Layer Properties", `.layerProperties`.
    - `noOpWhenEqual`: before == after → `isNoOp`; `HistoryStack.commit` records nothing.
    - `costAndChange`: `byteCost == 0`, `change == .structure`.
    - `keepsActiveLayerAndSelection` (H-6): 3 layers, active 2, a selection set; revert/apply of an item on layer 0 leave `activeLayerIndex == 2` and the selection equal.
  - `PaintDotMacTests/History/HistoryIconSymbolTests.swift` (extend 0010's): `layerVisibility.symbolName == "eye"`, and the existing "every symbol exists" check covers it.
  - `PaintDotMacTests/Operations/LayerOperationsMoveTests.swift`: 4 layers A,B,C,D (0..3), active 0: `LayerMove.makeHistoryItem(from: 0, to: 2, for:)` → order B,C,A,D, active 2, name "Move Layer Up", icon `.layerMove`, `change == .structure`, `isConsistent`, `after.selection == before.selection`, `after.floatingPixels == nil`; `from: 3, to: 0` → D,A,B,C, active 0, "Move Layer Down"; `from == to` → nil; out of range → nil; `adjacentMatchesLayerCommand`: `applied(from: i, to: i ± 1)` with active `i` == `LayerCommand.moveLayerUp/Down.applied(to:)`; undo through `HistoryStack` restores the original order, active index, and pixels exactly, redo re-applies; layer tiles share storage before/after (no pixel copy).
  - `PaintDotMacTests/Rendering/ThumbnailRendererTests.swift` (expected values by hand):
    - `fittedSize`: 800×600 → 80×60; 600×800 → 60×80; 80×80 → 80×80; 1×1 → 80×80; 65535×1 → 80×1; 1×65535 → 1×80; 3×2 → 80×53.
    - `opaqueRedLayer`: 160×160 all (255,0,0,255) → 80×80, every pixel (255,0,0,255).
    - `transparentLayerIsCheckerboard`: 160×160 empty → pixel (0,0) and (3,3) = #FFFFFF, (4,0) = #CCCCCC, (4,4) = #FFFFFF; zero allocated tiles read (a surface with no tiles).
    - `halfAlphaOverChecker`: 8×8 of (0,0,255,128) → 80×80 (upscale, nearest); pixel (0,0) over white: premul B = round(255×128/255)=128, out = (0 + 255×127/255, same, 128 + 255×127/255) = (127,127,255) (round to nearest); pixel (4,0) over #CC: (102,102,230) — compute: 204×127/255 = 101.6 → 102; 128 + 101.6 = 229.6 → 230.
    - `boxAverage`: 2×1 image [(255,255,255,255), (0,0,0,255)] fitted into box 1 → 1×1 = (128,128,128,255) (average 127.5 rounds half up).
    - `premultipliedAverage`: 2×1 [(255,0,0,255), (0,255,0,0)] → box 1 → premul avg (127.5, 0, 0, 127.5) over white → (255×… ) hand value (255×127.5/255 + 127.5 = 255 → R 255; G 127.5 → 128; B 127.5 → 128) = (255,128,128,255). Verifies transparent color is not bleeding green.
    - `ignoresLayerProperties`: the renderer takes a surface, so a hidden, opacity-0 layer's thumbnail equals the visible one's.
    - `crossesTileBoundary`: 600×300 seeded random surface vs a straightforward reference box-filter implementation in the test target → exact equality.
    - `cancellation`: render inside a cancelled `Task` → throws `CancellationError`.
  - `PaintDotMacTests/Rendering/ThumbnailCacheTests.swift`: empty cache → needsRender; after `store`, same surface → false; after `setPixel` (generation +1) → true; **generation collision**: copy S0 (gen g), mutate copy to S1 (gen g+1), store S1, then a different surface S2 built from S0 and mutated once to reach gen g+1 with different pixels → needsRender true (storage differs); `retain(only:)` drops removed IDs.
  - `PaintDotMacTests/Rendering/ThumbnailThrottleTests.swift` (injected times): first request at t=0 → renderNow; t=0.1 → scheduleAt(0.25); t=0.2 → scheduleAt(0.25) (coalesced); after didStartRender(0.25), t=0.3 → scheduleAt(0.5); t=0.6 → renderNow.
  - `PaintDotMacTests/UI/LayerPropertiesDialogModelTests.swift` (`@MainActor`, closure spy for `apply`):
    - `parseOpacity`: the table from Edge cases, fallback 77.
    - `livePreviewCallsApply`: setting name, visible, opacity, blend mode each calls `apply` with the full edited properties, in order.
    - `cancelRestoresOriginal`: after edits, `cancel()` → last `apply` argument == original.
    - `okBuildsSingleStep`: edits → `ok()` item name "Layer Properties", before == original, after == edited; no edits → item `isNoOp`.
    - `blendModeListIsImplementedModes`: options == `BlendMode.allCases.map(\.displayName)` (today `["Normal"]`).
- **Round-trip / property tests** (`PaintDotMacTests/History/LayerPanelPropertyTests.swift`): 100 seeded random sessions (seed printed on failure) over 1–6-layer images: random sequences of visibility toggles, property changes, and `moveLayer` steps through `HistoryStack.perform`; then undo all → layers' IDs, order, properties, and tile storage equal the start; redo all → equal the end state; `activeLayerIndex` after undoing a property/visibility step equals the value before that undo.
- **Integration tests** (headless, `@MainActor`, `PaintDotMacTests/UI/LayersPanelIntegrationTests.swift`, using a real `UndoBridge` with `groupsByEvent = false` and 0010's `BridgeToolContext` support):
  - `selectLayerIsNotAHistoryStep`: 2 layers, `selectLayer(index: 1)` → `state.image.activeLayerIndex == 1`, `history.steps.count` unchanged, `historyRevision` unchanged, `isAtSavedState` still true.
  - `toggleVisibilityStepAndComposite`: 2 layers (bottom opaque white, top opaque red), `toggleVisibility(index: 1)` → step "Hide Layer", `CPUCompositor` pixel (0,0) = white; undo → red and checkbox model `isVisible` true; redo → white; `undoManager.undoMenuItemTitle == "Undo Hide Layer"`; active index unchanged throughout.
  - `moveViaPanel`: `move(displaySource: [0], displayDestination: 2)` on 3 layers → one step, order and active as computed; undo restores.
  - `propertiesDialogFlow`: open properties model for layer 1, set opacity 128 and name "Glass" → `bridge.state` shows them live and `history.steps.count` unchanged; Cancel → original, still no step; repeat and OK → exactly one new "Layer Properties" step; undo → original; redo → edited.
  - `panelActionsFinishFloatingPixelsFirst`: 2 layers, active 1, rect selection, 0020 Move Selected Pixels drag (+4, 0) → floating. `selectLayer(index: 0)` → last steps `"Move Pixels", "Finish Pixels"`, the moved pixels are on layer 1, layer 0 unchanged, `floatingPixels == nil`, active 0. Repeat the float on layer 1 then `toggleVisibility(index: 0)` → steps end `"Finish Pixels", "Hide Layer"`; then `move(displaySource: [1], displayDestination: 0)` after another float → `"Finish Pixels", "Move Layer Up"`, and that snapshot's `before.floatingPixels == nil`.
  - `followsActiveDocument`: two bridges; binding to each shows its rows; bind(nil) → `.empty`; `refreshCount` +1 per history change.
  - `thumbnailUpdatesAfterEdit`: bind, await thumbnail for layer 0 (poll ≤ 2 s), paint a pixel block through `updateLiveState` + commit, advance the injected throttle clock → the new CGImage's sampled pixel changes to the painted color; a deleted layer's thumbnail entry is removed.
- **UI tests** (`PaintDotMacUITests/LayersPanelUITests.swift`, `UITestApp` with a generated 200×150 opaque PNG fixture; 0024's ⇧⌘N to add layers):
  - `testPanelListsLayersTopFirst`: ⇧⌘N twice → `layersList` has `layerRow.2`, `layerRow.1`, `layerRow.0` in that vertical order (row frames' minY ascending); `layerRow.0` label "Background"; the newest layer row value "active".
  - `testClickRowSelectsLayer`: click `layerRow.0` → value "active", `layerRow.2` "inactive"; `historyList` row count unchanged.
  - `testVisibilityCheckboxAddsHistoryStep`: click `layerVisibility.0` → value 0, last `historyRow.<n>` label "Hide Layer"; ⌘Z → value 1; Edit menu shows "Redo Hide Layer".
  - `testDragReorders`: with 3 layers named via the dialog ("A","B","C" bottom to top), drag `layerRow.0` above `layerRow.2` → row labels top-first "A","C","B"; history shows "Move Layer Up"; ⌘Z → "C","B","A".
  - `testFooterButtons`: `layers.add` → 2 rows, history "Add New Layer" (0024's name); `layers.duplicate` → 3 rows; `layers.moveDown` → active row moved; `layers.mergeDown` → 2 rows; `layers.delete` → 1 row and `layers.delete`, `layers.mergeDown` disabled.
  - `testDoubleClickOpensProperties`: double-click `layerRow.0` → `layerProperties` sheet appears, `layerProperties.name` value "Background", `layerProperties.blendMode` lists only "Normal", opacity field "255".
  - `testPropertiesOKAndCancel`: change name to "Paper", opacity field 100 ⏎, uncheck Visible, Cancel → row label "Background", history unchanged; reopen, same edits, OK → row label "Paper", checkbox 0, exactly one new "Layer Properties" history row; ⌘Z → "Background".
  - `testPanelFollowsActiveDocument`: open two fixtures, add a layer in the second only; switching windows switches row count 2 ↔ 1.
  - Update/remove 0006's `testPlaceholderText` and `PanelControllerTests.placeholderIdentifiers` (item 11).
- **Performance** (`PaintDotMacTests/Performance/ThumbnailPerformanceTests.swift`, XCTest `measure`): render the thumbnail of a 4000×3000 fully allocated layer; target ≤ 50 ms on M1 (fails only above 150 ms); report the number. Relevant to NF-1: thumbnails are off the main actor and throttled to ≤ 4/s, so they don't count against brush latency; manual 3 checks it perceptually.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: zero warnings, all tests pass with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Light and dark mode: active-row highlight, checkbox, thumbnail border, and footer icons are legible in both (APP-7).
  2. Thumbnails: open a wide photo and a tall screenshot → thumbnails are aspect-correct and centered; a new empty layer shows a checkerboard.
  3. Paint continuous strokes on a 4000×3000 image with 5 layers: brush stays smooth; the active layer's thumbnail updates a few times per second during the stroke and matches after it ends.
  4. Drag a row slowly: an insertion indicator appears between rows; dropping on itself does nothing.
  5. Layer Properties: drag the opacity slider → canvas fades live; Escape cancels; Return confirms; Tab moves through the controls (NF-7).
  6. VoiceOver: rows read the layer name and "selected" for the active row; checkboxes read "Visible: <name>"; footer buttons read their Paint.NET names.

## Open questions

- **Visibility step names.** The Paint.NET docs don't name the history step for the visibility checkbox. This spec uses **"Hide Layer"** / **"Show Layer"** (recommended); alternatives are "Layer Visibility" or "Layer Properties". Confirm, or verify in Paint.NET 5 (toggle a checkbox and read the History window), then record the choice in the PRD (§5.4 L-5 / §12).
- **Drag-reorder = one step named after its direction** ("Move Layer Up"/"Move Layer Down", even for a multi-position drag) — recommended and specified above; confirm and record in the PRD (§12).

## Out of scope

- Blend modes beyond Normal (0026, 0027, 0059); the dialog's list grows automatically.
- Layer operations themselves, the Layers menu, and the Metal compositor (0024); Import From File (0030); layer flip/rotate/zoom (0060).
- Toggle Layer Visibility and Move Layer to Top/Bottom menu items (not in the PRD's L-requirements for v1.0; the visibility checkbox covers toggling). Go to Layer Above/Below already exist (0024).
- Docked panels (0052); inline rename in the row (rename via Layer Properties only); multi-layer selection.
- OpenRaster storage of properties (0028).
