# 0008 — Add the history stack with tile-diff undo and the NSUndoManager bridge

> Source: PRD.md §5.6 E-1; §5.7 H-3, H-5, H-6 (no-op edits add no step, an oversized step is kept, "1 GB" = 1 GiB, undo doesn't switch layers) (and H-1/H-2 data model for 0010); §5.1 APP-9 (an untouched new image has no unsaved changes; the edited state follows history); §6 NF-4; §7 design principle 2; §12 D-9, D-30, D-34; AGENTS.md architecture rules 2 and 3. Paint.NET History window: https://www.getpaint.net/doc/latest/HistoryWindow.html (step names "Open Image"/"New Image", undone steps kept until a new action discards them).
> Milestone: M1
> Depends on: 0005-new-image-and-png-save (and therefore 0001–0004); 0006-tool-framework-and-panels (this spec extends its `ToolContext` and `PanelController`; 0006 has a lower number, so it is built first).

## Context
Not yet implemented: there is no history system. After 0001–0007, `PaintDocument` (`PaintDotMac/Document/PaintDocument.swift`, 0001/0002/0005) holds the opened or newly created `LayeredImage` (0002), saves PNG (0005), and prompts on close with unsaved changes (0005) — but nothing can change pixels yet, so nothing can be undone. `ToolContext` (`PaintDotMac/Core/Tools/ToolContext.swift`, 0006) reserves `commitHistory(_:)` and `performHistory(_:)` for this spec.

**This spec supersedes 0005's interim rule 3** ("File > New marks the document edited"). From here on the edited state follows history only (PRD APP-9, D-30): an untouched new image (only its "New Image" base step) is clean and closes without a prompt, exactly like an untouched opened file. The 0005 code and tests that depend on the interim rule are rewritten here (Scope items 11 and 17); the close-prompt UI tests come back in 0009, which makes a real Paintbrush edit first.

This spec delivers the history engine every later pixel, selection, layer, and canvas operation records into:
- **E-1:** undo/redo with ⌘Z / ⇧⌘Z, unlimited within a memory budget.
- **NF-4:** undo stores only changed 256×256 tiles; the budget is injectable, default 1 GiB, shown as "1 GB" (H-6). (The Settings UI for it is 0046.)
- **H-5 / D-9:** when the budget is exceeded the oldest steps are dropped — never the base "Open Image"/"New Image" step — and they disappear from the History panel (the panel itself is 0010; it reads `HistoryStack.steps`).
- **H-3:** the stack is mirrored in `NSUndoManager`, so Edit > Undo/Redo titles ("Undo Paintbrush") and the document's edited state stay in sync. Jumping to a step (H-2, panel in 0010) is implemented as several undos or redos through the same manager.

Paint.NET behavior mirrored: the first History row is "Open Image" (opened file) or "New Image" (File > New); undone steps remain (greyed, 0010) and redoable until a new action discards them.

No pixel tool exists yet (Paintbrush is 0009), so the app-level UI test only proves Undo/Redo are disabled and the document is clean on a fresh document; the engine is proved by unit, property, and integration tests that drive `HistoryStack` with synthetic tile edits.

### Types this spec relies on from earlier specs
These are the real names from the earlier specs (read them in `docs/specs/done/`):
- **0002 `Core/Model/TiledSurface.swift`:** `struct TileCoordinate: Hashable, Comparable, Sendable { var column: Int; var row: Int }` (`<` is row-major); `struct Tile: Equatable, Sendable` — always a full 256×256 RGBA8 tile (edge tiles too; their out-of-bounds pixels stay zero), `static let byteCount = 262_144`, copy-on-write through its `[UInt8]` storage, `func sharesStorage(with: Tile) -> Bool`, `withUnsafeBytes(_:)`; `struct TiledSurface: Equatable, Sendable` with `func tile(at: TileCoordinate) -> Tile?` (nil = unallocated, fully transparent, costs no memory), `mutating func setTile(_: Tile?, at: TileCoordinate)` (stamps the tile's generation, so 0003 re-uploads it through `changedTiles(since:)`), `var allocatedTileCoordinates: [TileCoordinate]`, `func tileCoordinates(intersecting: PixelRect) -> [TileCoordinate]`, `var generation: UInt64`, `func changedTiles(since: UInt64) -> [TileCoordinate]`, `readPixels(in:)`, `writePixels(_:to:)`, `fill(_:in:)`, `releaseTransparentTiles()`. `==` compares pixels and ignores generations.
- **0002 `Core/Model/Layer.swift` / `LayeredImage.swift`:** `struct Layer: Identifiable, Equatable, Sendable` (`id: UUID`, so `Layer.ID == UUID`; `name`, `isVisible`, `opacity: UInt8`, `blendMode`, `surface`); `struct LayeredImage: Equatable, Sendable` (`size: PixelSize`, `dpi`, `layers` bottom→top, `activeLayerIndex`, `isConsistent`, `static func blank(size:dpi:fill:layerName:)`). Both are value types: copying a `LayeredImage` copies tile references only (O(layers × allocated tiles)) and later writes to the copy never change the original. Tile-diff capture below relies on that.
- **0002 test support:** `PaintDotMacTests/Support/SeededRandom.swift`.
- **0003 `Canvas/CanvasView.swift`:** `var image: LayeredImage?` (assigning the edited image is all a pixel edit needs: the renderer finds changed tiles itself through 0002's `generation` / `changedTiles(since:)`), `func invalidateAll()` (whole-image replacements, revert, and `.structure` changes).
- **0004 `Core/Settings/AppSettings.swift`:** injectable `UserDefaults`, keys under the `settings.` prefix (`settings.measurementUnit`), `.appSettingsDidChange`.
- **0005:** `NewImageRequest.makeImage()`, `PaintDocumentController.newDocument(_:)` (step 4 creates the document), `PaintDocument.init(type:)` (untitled path), PNG save, `SaveUITests`, `PaintDocumentSavingTests`.
- **0006:** `ToolContext`, `FakeToolContext` (test double), `CanvasToolSession` (the app-side conformer), `ToolDispatcher.commitPendingEdit()`, `AppModel.shared`, `PanelController`.

This spec adds one helper to `LayeredImage` in its own new file `Core/History/LayeredImage+History.swift`: `func layerIndex(for id: Layer.ID) -> Int?`.

## User story
As a PaintDotMac user, every edit I make becomes a named step I can undo with ⌘Z and redo with ⇧⌘Z; the Edit menu says what will be undone ("Undo Paintbrush"); undoing back to the state I last saved makes the window clean again; and on huge edit sessions the app silently forgets the oldest steps instead of running out of memory, but I can always get back to at least the image as it was after the oldest kept step.

## Scope & changes

### Core (pure Swift, headless, unit-tested) — `PaintDotMac/Core/`

1. **`Core/Model/DocumentState.swift`** (new): the complete undoable document state.
   ```swift
   public struct DocumentState: Sendable {
       public var image: LayeredImage
       public init(image: LayeredImage)
   }
   ```
   Doc comment: 0013 adds `selection: Selection`; any later undoable document-level state is added here, never beside it. History items mutate only a `DocumentState`.

2. **`Core/History/HistoryIcon.swift`** (new): `public enum HistoryIcon: String, CaseIterable, Sendable`. Cases (raw value = case name):
   - base: `openImage`, `newImage`;
   - tools (raw value equals the tool ID from the shared conventions): `rectangleSelect`, `lassoSelect`, `ellipseSelect`, `magicWand`, `moveSelectedPixels`, `moveSelection`, `paintBucket`, `gradient`, `paintbrush`, `eraser`, `pencil`, `cloneStamp`, `recolor`, `text`, `lineCurve`, `shapes`;
   - commands: `selectAll`, `deselect`, `invertSelection`, `eraseSelection`, `fillSelection`, `cut`, `paste`, `cropToSelection`, `resizeImage`, `resizeCanvas`, `flipRotate`, `layerAdd`, `layerDelete`, `layerDuplicate`, `layerMerge`, `layerMove`, `layerProperties`, `flatten`, `importLayer`, `adjustment`, `effect`;
   - `generic` (fallback).
   Every tool case's raw value is a `ToolID` raw value (0006); `colorPicker`, `zoom`, and `pan` have no case because they never record steps. Core contains no image names or SF Symbols; 0010 maps cases to symbols in `HistoryIcon+Symbol.swift`. Later specs add cases (and their symbols) as they need them.

3. **`Core/History/HistoryChange.swift`** (new): what a step touched, so the canvas knows what to redraw.
   ```swift
   public enum HistoryChange: Equatable, Sendable {
       case pixels([Layer.ID: Set<TileCoordinate>])   // only these tiles changed
       case structure                                  // size, layers, properties, or anything else: full refresh
       public func merged(with other: HistoryChange) -> HistoryChange
   }
   ```
   `merged`: pixels ∪ pixels = per-layer set union; anything with `.structure` = `.structure`. (0013 may add a `.selection` case and extend `merged`.)

4. **`Core/History/HistoryItem.swift`** (new): the protocol every undoable step conforms to, plus the generic items.
   ```swift
   public protocol HistoryItem: Sendable {
       var name: String { get }            // Paint.NET spelling: "Paintbrush", "Deselect", "Gaussian Blur"
       var icon: HistoryIcon { get }
       var byteCost: Int { get }           // fixed at init; memory this step keeps alive (see HistoryCost)
       var change: HistoryChange { get }
       var isNoOp: Bool { get }            // default implementation: false
       func apply(to state: inout DocumentState)   // redo direction: before → after
       func revert(_ state: inout DocumentState)   // undo direction: after → before
   }
   ```
   Contract: `apply` is only called on a state equal to the item's "before", `revert` only on its "after" (the stack guarantees this). Both are deterministic and leave the state exactly (pixel- and property-identical) as it was.

   Concrete items in this file:
   - **`TileDiffHistoryItem`** `(name:icon:diff: TileDiff)`: pixel changes on existing layers. `byteCost = diff.byteCost`, `change = .pixels(diff.changedTiles)`, `isNoOp = diff.isEmpty` (H-6: an action that changes nothing adds no step). Used by every painting tool, fill, erase/fill selection, and effect/adjustment.
   - **`DocumentSnapshotHistoryItem`** `(name:icon:before: DocumentState, after: DocumentState)`: whole-structure changes — layer add/delete/duplicate/merge/move/flatten and drag-reorder (0024/0025; 0025's Layer Properties and Hide/Show Layer steps use its own `LayerPropertiesHistoryItem` so undo never changes the active layer, H-6), canvas-size changes (crop 0022, resize image 0035, resize canvas 0036, rotate 0037), and selection changes until 0013 decides whether it needs a lighter item. `apply` assigns `after`, `revert` assigns `before` (cheap: tile storage is shared copy-on-write). `byteCost = HistoryCost.unsharedTileBytes(before:after:)`, `change = .structure`.
   - **`CompositeHistoryItem`** `(name:icon:items: [any HistoryItem])`: one user-visible step made of several items (for example Move Selected Pixels commit = pixels + selection). `apply` runs items in order, `revert` in reverse order; `byteCost` = sum; `change` = items' changes merged; `isNoOp` = all items are no-ops (an empty list is a no-op).

5. **`Core/History/HistoryCost.swift`** (new): memory accounting, one rule for every item: *a step costs the bytes of the tile storage it references on one side but not the other*.
   - `static func tileBytes(_ tile: Tile?) -> Int` — `tile == nil ? 0 : Tile.byteCount`.
   - `static func storageKey(_ tile: Tile) -> UInt` — the address of the tile's byte buffer (`tile.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }`, the same address 0002's `sharesStorage(with:)` compares; reading it never copies). Two tiles have the same key exactly when `sharesStorage(with:)` is true.
   - `static func unsharedTileBytes(before: DocumentState, after: DocumentState) -> Int` — collect the distinct `storageKey`s of all allocated tiles of all layers on each side (a storage shared by two layers on one side counts once); return `Tile.byteCount` × (number of keys only in `before` + number of keys only in `after`). Both states are alive while the keys are compared, so a key can't be reused by another buffer during the computation. Examples: Add New Layer (empty) = 0; Duplicate Layer = 0; Delete Layer = the deleted layer's tiles; a canvas resize that rewrites every tile = all old tiles + all new tiles.
   - `static let stepOverheadBytes = 1_024` — added by the stack per non-base step (bounds the number of zero-cost steps to ~1 M under the 1 GiB budget).
   - Accounting is deliberately conservative: a tile diff counts both its before and after tiles although the newest after-tiles are shared with the live image, so real memory ≤ accounted memory.

6. **`Core/History/TileDiff.swift`** (new): per-layer, per-tile before/after.
   ```swift
   public struct TileDiff: Sendable {
       public struct Entry: Sendable {
           public let layerID: Layer.ID
           public let coordinate: TileCoordinate
           public let before: Tile?     // nil = tile was absent (transparent)
           public let after: Tile?      // nil = tile is absent afterwards
       }
       public let entries: [Entry]      // ordered by layer (image order), then row, then column
       public var isEmpty: Bool
       public var byteCost: Int         // Σ HistoryCost.tileBytes(before) + tileBytes(after)
       public var changedTiles: [Layer.ID: Set<TileCoordinate>]
       public static func between(before: TiledSurface, after: TiledSurface, layerID: Layer.ID,
                                  candidates: Set<TileCoordinate>? = nil) -> TileDiff
       public static func between(before: LayeredImage, after: LayeredImage,
                                  candidates: [Layer.ID: Set<TileCoordinate>]? = nil) throws(TileDiffError) -> TileDiff
       public func apply(to image: inout LayeredImage)
       public func revert(_ image: inout LayeredImage)
   }
   public enum TileDiffError: Error, Equatable { case canvasSizeMismatch, layerStructureMismatch }
   ```
   - `between(surface…)`: examines `candidates` (nil = union of `allocatedTileCoordinates` of both surfaces). For each coordinate: both nil → skip; `sharesStorage(with:)` → skip (fast path); equal by content (`==`) → skip; one side nil and the other `isFullyTransparent` → skip (pixel-identical); otherwise add an entry. So writing identical pixels yields an empty diff.
   - `between(image…)`: throws `.canvasSizeMismatch` if sizes differ, `.layerStructureMismatch` unless both images have the same layer IDs in the same order (structural changes use `DocumentSnapshotHistoryItem`); otherwise concatenates per-layer diffs in layer order. `candidates` keys absent from the dictionary mean "no candidates for that layer"; a nil dictionary means "all tiles of all layers".
   - `apply` sets each entry's `after` tile on the layer with `layerID` (found with `layerIndex(for:)`; `setTile` stamps the tile's generation for 0003); `revert` sets `before`. Neither changes `activeLayerIndex` (H-6: undo doesn't switch layers). A missing layer ID is unreachable through `HistoryStack` (it guarantees ordering); guard it with `assertionFailure` and skip the entry.
   - **Capture pattern for tools (documented in the type's doc comment, used from 0009 on):** at `mouseDown`, keep `let before = context.image` (a free CoW copy, which carries its surfaces' `generation`s); draw into the live image while dragging; at `mouseUp`, compute candidates as `after.layers[i].surface.changedTiles(since: before.layers[i].surface.generation)`, call `TileDiff.between(before:after:candidates:)`, and `context.commitHistory(TileDiffHistoryItem(…))`. `cancel` reverts by `diff.revert(&image)`.

7. **`Core/History/HistoryStack.swift`** (new): the ordered list of steps, the current position, the budget, and the saved marker.
   ```swift
   public enum HistoryBaseStep: Sendable { case openImage, newImage }   // name "Open Image" / "New Image", icon .openImage / .newImage

   public struct HistoryStep: Identifiable, Sendable {
       public typealias ID = Int                  // monotonically increasing per stack; base = 0; never reused
       public let id: ID
       public let name: String
       public let icon: HistoryIcon
       public let item: (any HistoryItem)?        // nil only for the base step
       public var isBase: Bool { item == nil }
   }

   public struct HistoryCommitResult: Equatable, Sendable {
       public var recordedStepID: HistoryStep.ID?      // nil when the item was a no-op and was ignored
       public var discardedRedoStepIDs: [HistoryStep.ID]
       public var droppedStepIDs: [HistoryStep.ID]     // oldest steps folded into the base (H-5)
   }

   public struct HistoryStack: Sendable {
       public static let defaultBudgetBytes = 1_073_741_824   // "1 GB" = 1 GiB
       public init(base: HistoryBaseStep, budgetBytes: Int = HistoryStack.defaultBudgetBytes)
       public private(set) var steps: [HistoryStep]           // steps[0] is always the base step
       public private(set) var currentIndex: Int              // 0 ..< steps.count; state == after steps[currentIndex]
       public private(set) var totalBytes: Int                // Σ over non-base steps of item.byteCost + stepOverheadBytes
       public private(set) var budgetBytes: Int
       public private(set) var savedStepID: HistoryStep.ID?   // nil = the saved state is no longer reachable
       public var canUndo: Bool                               // currentIndex > 0
       public var canRedo: Bool                               // currentIndex < steps.count - 1
       public var undoStep: HistoryStep?                      // steps[currentIndex] when canUndo
       public var redoStep: HistoryStep?                      // steps[currentIndex + 1] when canRedo
       public var currentStepID: HistoryStep.ID
       public var isAtSavedState: Bool                        // savedStepID == currentStepID
       @discardableResult public mutating func commit(_ item: any HistoryItem) -> HistoryCommitResult
       @discardableResult public mutating func perform(_ item: any HistoryItem, on state: inout DocumentState) -> HistoryCommitResult
       public mutating func undo(_ state: inout DocumentState) -> HistoryChange?
       public mutating func redo(_ state: inout DocumentState) -> HistoryChange?
       public mutating func jump(to index: Int, _ state: inout DocumentState) -> [HistoryChange]
       @discardableResult public mutating func setBudget(_ bytes: Int) -> [HistoryStep.ID]
       public mutating func markSaved(stepID: HistoryStep.ID)
       public mutating func clearSavedState()
   }
   ```
   Behavior (each rule has a test below):
   - **Init:** one base step (`id` 0, name/icon from `HistoryBaseStep`), `currentIndex` 0, `totalBytes` 0, `savedStepID` 0 (a freshly opened file and a fresh New Image are clean, APP-9; 0021's Paste into New Image calls `clearSavedState()`). Negative budgets are treated as 0. `defaultBudgetBytes` is 1 GiB ("1 GB" in the UI, H-6).
   - **`commit`** (item already applied to the live state): if `item.isNoOp`, return `recordedStepID == nil` and change nothing (H-6). Otherwise discard every redo step (`steps[currentIndex+1...]`, subtracting their bytes; if `savedStepID` was among them, it becomes nil), append the new step (name and icon copied from the item), set `currentIndex` to it, add its bytes, then **enforce the budget**.
   - **`perform`**: if not a no-op, `item.apply(to: &state)` then `commit`.
   - **`undo`**: if `canUndo`, `steps[currentIndex].item.revert(&state)`, `currentIndex -= 1`, return the item's `change`; otherwise return nil and change nothing. **`redo`** symmetric with `apply`.
   - **`jump(to:)`**: repeated `undo`/`redo` until `currentIndex == index`; returns the changes in order. Out-of-range index or the current index → returns `[]`, no change. (The bridge does not call this; it jumps through `NSUndoManager` so both stay in sync — see UndoBridge.)
   - **Budget enforcement (H-5)**, run after `commit` and in `setBudget`: `while totalBytes > budgetBytes && currentIndex >= 2 { fold steps[1] into the base }`. *Folding* removes `steps[1]` and its bytes, decrements `currentIndex`, and appends its ID to the dropped list; the base step keeps its ID, name, and icon but now stands for the state after the dropped step, so undo stops there. Consequences: the base step is never dropped; the current step is never dropped (a single step larger than the budget is kept, H-6, so the last action is always undoable, and the budget stays exceeded until a later commit or budget change can drop it); redo steps are never dropped by enforcement (they are discarded by the next commit).
   - **Saved marker under folding:** if the folded step's ID == `savedStepID`, `savedStepID` becomes the base ID (the base now *is* that state); if `savedStepID` was the base ID, it becomes nil (that state is gone).
   - **`setBudget`**: stores `max(0, bytes)`, enforces, returns dropped IDs.
   - **`markSaved(stepID:)`**: sets `savedStepID` to that ID if a step with it exists, else nil. `clearSavedState()` sets nil.

8. **`Core/Settings/AppSettings.swift`** (extend 0004's type): `var undoBudgetBytes: Int`, UserDefaults key `"settings.undoBudgetBytes"` (`AppSettings.Key.undoBudgetBytes`, under 0004's `settings.` prefix so `-UITestResetDefaults` clears it, D-37), default `HistoryStack.defaultBudgetBytes`; a missing, non-integer, or negative stored value reads as the default. No UI (0046).

9. **`Core/Tools/ToolContext.swift`** (extend 0006's protocol) with the history commit hook:
   ```swift
   /// Records a step whose changes are already in `image` (live drawing). No-op items are ignored.
   func commitHistory(_ item: any HistoryItem)
   /// Applies the item to the document, then records it.
   func performHistory(_ item: any HistoryItem)
   /// Live drawing (in-progress strokes): mutates the document's image without recording a step.
   func updateImage(_ body: (inout LayeredImage) -> Void)
   ```
   Implement both in 0006's `CanvasToolSession` (item 15) and `FakeToolContext`: the fake gets `private(set) var state: DocumentState` (its existing `image` property now returns `state.image`), `private(set) var history: HistoryStack` (base `.newImage`), and `func updateImage(_ body: (inout LayeredImage) -> Void)` for live drawing in tests; `commitHistory` forwards to `history.commit`, `performHistory` to `history.perform(_:on: &state)`. Zoom and Pan never call them.

### Platform glue — `PaintDotMac/Document/`, `App/`, `Canvas/`

10. **`Document/UndoBridge.swift`** (new): `@MainActor @Observable final class UndoBridge`, one per document. It owns the document's live `DocumentState`, its `HistoryStack`, and an `UndoManager` that mirrors the stack one-to-one: undo-stack groups ↔ steps `1...currentIndex`, redo-stack groups ↔ steps `currentIndex+1...`.
   ```swift
   init(state: DocumentState, base: HistoryBaseStep, budgetBytes: Int, undoManager: UndoManager = UndoManager())
   @ObservationIgnored let undoManager: UndoManager
   private(set) var state: DocumentState
   private(set) var history: HistoryStack
   private(set) var historyRevision: Int              // +1 exactly once per history mutation (see below); observed by 0010
   @ObservationIgnored var prepareForNavigation: (() -> Void)?   // before undo/redo/jump/save: the active tool commits its pending edit (0006 Tool.commit)
   @ObservationIgnored var onStateChange: ((HistoryChange) -> Void)?   // canvas invalidation after perform/undo/redo/jump/reset
   @ObservationIgnored var onEditedChange: ((Bool) -> Void)?           // after every history mutation, with !history.isAtSavedState
   func updateLiveState(_ body: (inout DocumentState) -> Void)   // in-progress tool drawing, committed later via commit(_:)
   func commit(_ item: any HistoryItem)
   func perform(_ item: any HistoryItem)
   func undo()                      // undoManager.undo()
   func redo()                      // undoManager.redo()
   func jump(to index: Int)         // (currentIndex - index) × undoManager.undo(), or (index - currentIndex) × redo(); out of range or current → no-op
   func setBudget(_ bytes: Int)
   func markSaved(stepID: HistoryStep.ID)
   func reset(state: DocumentState, base: HistoryBaseStep)  // open/revert/new: undoManager.removeAllActions(), fresh stack
   ```
   - Each recorded step gets a `final class HistoryStepToken` (holds the step ID) kept in `[HistoryStep.ID: HistoryStepToken]`. `commit`/`perform` record into the stack; if a step was recorded, register `undoManager.registerUndo(withTarget: token) { … performUndo(token) }` and `undoManager.setActionName(step.name)`. If `undoManager.groupsByEvent` is false (tests), wrap registration and naming in `beginUndoGrouping()`/`endUndoGrouping()`; if true (the app), the automatic event group is the step's group. `performUndo` calls `prepareForNavigation`, `history.undo(&state)`, registers the redo with the same token target and sets the action name again, then calls `onStateChange` and `onEditedChange`. `performRedo` is symmetric. Undo/redo always go through `undoManager` (menu, ⌘Z, jumps), so the two stay in sync.
   - **Dropped steps (H-5):** for each ID in `droppedStepIDs` (from commit or `setBudget`), `undoManager.removeAllActions(withTarget: token)` and forget the token, so Edit > Undo can never name or reach a folded step. Discarded redo steps: `NSUndoManager` clears its redo stack itself when a new undo is registered; the bridge forgets their tokens.
   - `commit`/`perform` ignore no-op items entirely (nothing registered, no callbacks, no revision bump; H-6).
   - **Observation (for 0010's History panel):** `UndoBridge` is `@Observable`; `history` and `historyRevision` are its observed properties. `historyRevision` increases by exactly 1 after each recorded `commit`/`perform`, each single `undo`/`redo`, each `jump` that moves (once, at the end, however many steps it replays), each `setBudget` that drops steps, each `markSaved`, and each `reset`. Panels observe `historyRevision` (with `withObservationTracking` or from SwiftUI) and read `history.steps`, `history.currentIndex`, `history.canUndo`, `history.canRedo`.
   - **`jump(to:)` details:** calls `prepareForNavigation` once, then loops `undoManager.undo()`/`redo()`; while the loop runs, `performUndo`/`performRedo` skip their own `prepareForNavigation`, revision bump, and callbacks; after the loop the bridge calls `onStateChange` once with the merged change (`HistoryChange.merged`), `onEditedChange` once, and bumps `historyRevision` once.
   - The bridge is the only writer of the document's pixels; nothing else mutates `state`.

11. **`Document/PaintDocument.swift`** (extend):
   - `let undoBridge: UndoBridge`, created in `init` with budget `AppSettings.undoBudgetBytes`. The stored `LayeredImage` from 0002/0005 moves into `undoBridge.state.image`; `PaintDocument.image` becomes a get-only computed property forwarding to it, so save and the canvas keep working.
   - `read(from:ofType:)` (open and File > Revert To Saved) calls `undoBridge.reset(state:base: .openImage)`. `PaintDocument.init(type:)` (0005's untitled path) creates the bridge with base `.newImage`.
   - **0005 New Image path (rewritten, supersedes interim rule 3):** in `PaintDocumentController.newDocument(_:)` step 4, replace `image = request.makeImage()` and `updateChangeCount(.changeDone)` with `document.undoBridge.reset(state: DocumentState(image: request.makeImage()), base: .newImage)`. The new document is clean (APP-9, D-30).
   - **Save commits pending tool edits:** override `save(to:ofType:for:completionHandler:)` to call `undoBridge.prepareForNavigation?()` before `super`, so an uncommitted edit (0009's in-progress stroke, later shapes/text) is committed and lands in the file. 0009 relies on this and doesn't add its own call.
   - `hasUndoManager = false` in `init`, so `NSDocument` does not count changes from undo notifications (text-field typing must never dirty the document). The history is the single source of the edited state: `undoBridge.onEditedChange = { isEdited in super.updateChangeCount(isEdited ? .changeDone : .changeCleared) }` (via a private helper; `.changeDone` on every edit also lets the 0047 autosave see new changes).
   - Save bookkeeping: override `changeCountToken(for:)` to return `HistorySaveToken(stepID: undoBridge.history.currentStepID, superToken: super.changeCountToken(for:))`; override `updateChangeCount(withToken:for:)` to call `super` with `superToken`, then, for `.saveOperation` and `.saveAsOperation` only, `undoBridge.markSaved(stepID:)` (which re-syncs the edited state — an edit made while an async save was running keeps the document dirty). `.saveToOperation` and autosave operations never mark saved. `HistorySaveToken` is a small private struct in this file.
   - Closing: unchanged from 0005; it now prompts exactly when `!history.isAtSavedState`, so an untouched New image closes without a prompt.

12. **`Document/DocumentWindowController.swift`** (extend): the controller is the window's delegate and implements `windowWillReturnUndoManager(_:) -> UndoManager?` returning `(document as? PaintDocument)?.undoBridge.undoManager`. It sets `undoBridge.onStateChange` to refresh the canvas: `.pixels` → `canvasView.image = undoBridge.state.image` only (0003's renderer re-uploads exactly the tiles `setTile` stamped, through `changedTiles(since:)`); `.structure` → `canvasView.image = undoBridge.state.image`, `canvasView.invalidateAll()`, and the status bar's image size/DPI update (no re-fit: the zoom stays). It sets `undoBridge.prepareForNavigation` to `{ [weak self] in if let self, AppModel.shared.activeSession === self.session { AppModel.shared.dispatcher.commitPendingEdit() } }` (0006; `weak` because the document owns the bridge and the bridge owns the closure), which runs the active tool's `commit(context:)`.

13. **`App/PanelController.swift`** (extend 0006): each floating panel's delegate returns the current document's undo manager (`(NSDocumentController.shared.currentDocument as? PaintDocument)?.undoBridge.undoManager`) from `windowWillReturnUndoManager`, so ⌘Z works while a panel is key.

14. **`App/MainMenu.swift`**: no change. 0001 already has **Undo** (⌘Z, `undo(_:)`, target nil) and **Redo** (⇧⌘Z, `redo(_:)`, target nil) and no ⌘Y item (D-12). `NSWindow` validates both items and titles them from the undo manager this spec supplies ("Undo", "Undo Paintbrush", "Redo Paintbrush").

15. **`Canvas/CanvasToolSession.swift`** (0006's app-side `ToolContext` conformer): gains `let undoBridge: UndoBridge` (its document's bridge, passed in by `DocumentWindowController`; 0010's History panel reaches the active document's history through `AppModel.activeSession?.undoBridge`); `image` returns `undoBridge.state.image`; `commitHistory`/`performHistory` forward to `undoBridge.commit`/`perform`; it adds `func updateImage(_ body: (inout LayeredImage) -> Void)` (the `ToolContext` requirement from item 9) forwarding to `undoBridge.updateLiveState { body(&$0.image) }`, the only way tools write live pixels.

16. `project.yml`: no target changes; new files are picked up by the existing source globs. Run `xcodegen generate`.

No PRD.md change is needed: E-1, H-3, H-5, H-6, APP-9, NF-4, D-9, D-30, and D-34 already state this behavior.

17. **0005 tests rewritten (superseded interim rule 3):**
   - `PaintDocumentSavingTests.newDocumentIsEditedUntilSaved` → renamed `newDocumentIsCleanAndStaysCleanAfterSaveAs`: a document built through the new step-4 path → `isDocumentEdited == false`, one "New Image" step; after `save(to:ofType:for: .saveAsOperation)` to a temp URL → still clean, `fileURL` == that URL, `fileType == "public.png"`.
   - `SaveUITests.closeNewImageDontSave`, `.closeNewImageCancel`, `.quitWithUnsavedNewImagePrompts` → removed here (an untouched new image no longer prompts); 0009 re-adds them as `closeEditedNewImageDontSave`, `closeEditedNewImageCancel`, `quitWithEditedNewImagePrompts` with a Paintbrush stroke first.
   - `SaveUITests.closeNewImageSave` → rewritten as `saveAsNewImageWritesWhitePNG`: ⌘N, Return, ⌘S (untitled → save panel) → `saveThroughPanel(directory: tmp, name: "new.png")` → same decoded-file assertions as before (800×600, sampled pixels white, DPI within 0.05 of 96, sRGB profile); the window stays open and is clean.
   - 0005's acceptance criterion "Closing (⌘W) or quitting (⌘Q) with an unsaved new image asks whether to save" is superseded by this spec's criterion that an untouched new image closes without a prompt; 0005's manual step that relies on the interim rule is replaced by manual step 2 below.

### Performance and memory (NF-1, NF-4)
- **NF-4:** undo memory is proportional to changed tiles only: a 1-tile stroke on a 4000×3000 image costs 2 × 262,144 + 1,024 = 525,312 accounted bytes, not 48 MB. Sparse (absent) tiles cost nothing. With the 1 GiB default, about 10 full-layer edits of a 4000×3000 layer (2 × 192 tiles each ≈ 96 MiB accounted) fit before the oldest are dropped; real memory is lower because the newest after-tiles are shared with the live image. Disk spillover (H-4) is 0062.
- **NF-1:** history work happens once per stroke at `mouseUp` (diff over the dirty tiles with an identity fast path), never per frame. Measured by `HistoryPerformanceTests` below.
- NF-2/NF-3 are not affected.

## Acceptance criteria
- [ ] A new stack has exactly one step named "Open Image" (or "New Image"), cannot undo or redo, costs 0 bytes, and is at the saved state. → `HistoryStackTests.initialOpenImageStep`, `initialNewImageStep`
- [ ] Committing a step makes it undoable under its name; undo restores the previous state exactly and enables redo; redo restores the after state exactly. → `HistoryStackTests.commitUndoRedo`, `HistoryIntegrationTests.syntheticSessionUndoRedo`
- [ ] Committing after undo discards the redo steps and their bytes. → `HistoryStackTests.commitDiscardsRedo`
- [ ] Undo at the base step and redo at the newest step do nothing. → `HistoryStackTests.undoAtBaseAndRedoAtTopAreNoOps`
- [ ] Jumping to any step equals the corresponding number of undos/redos; out-of-range jumps do nothing. → `HistoryStackTests.jumpEqualsRepeatedUndoRedo`, `jumpOutOfRangeIsNoOp`
- [ ] Undo stores only changed tiles: unchanged and identical-content tiles are not recorded; cost equals stored before + after tile bytes. → `TileDiffTests.*`, `HistoryCostTests.*`
- [ ] Items whose diff is empty create no history step and don't dirty the document (H-6). → `HistoryStackTests.noOpItemIsIgnored`, `UndoBridgeTests.noOpItemRegistersNothing`, `TileDiffTests.identicalWriteIsEmpty`
- [ ] Structural snapshot and composite items undo and redo exactly and report the right change and cost. → `HistoryItemTests.*`
- [ ] The budget defaults to 1,073,741,824 bytes (1 GiB, H-6), is injectable, and is read from `AppSettings.undoBudgetBytes` (key `settings.undoBudgetBytes`). → `HistoryStackTests.defaultBudget`, `AppSettingsTests.undoBudget*`
- [ ] When the budget is exceeded, the oldest steps are dropped, never the base step and never the current step (a single oversized step is kept, H-6); after dropping, undo stops at the state after the last dropped step. → `HistoryBudgetTests.*`, `HistoryPropertyTests.budgetInvariants`
- [ ] Undoing or redoing a pixel step on a non-active layer doesn't change the active layer (H-6). → `HistoryItemTests.tileDiffKeepsActiveLayer`, `HistoryIntegrationTests.syntheticSessionUndoRedo`
- [ ] `UndoBridge.historyRevision` bumps exactly once per recorded step, undo, redo, moving jump, dropping `setBudget`, `markSaved`, and `reset`, and never for no-ops. → `UndoBridgeTests.revisionBumpsOncePerOperation`
- [ ] Undo then redo restores identical tiles over seeded random edit sessions, and every reachable state matches an independent pixel oracle. → `HistoryPropertyTests.randomSessionsMatchOracle`
- [ ] `NSUndoManager` mirrors the stack: `canUndo`/`canRedo` and "Undo <name>"/"Redo <name>" titles match after every operation, including jumps and budget drops. → `UndoBridgeTests.*`, `UndoBridgePropertyTests.managerMirrorsStack`
- [ ] The document's edited state follows the history: clean when opened or newly created (APP-9, superseding 0005's interim rule), dirty after a step, clean again after undoing back to the saved step, and clean after Save; autosave and Save To do not clear it; Save commits a pending tool edit first. → `PaintDocumentHistoryTests.*`, `PaintDocumentSavingTests.newDocumentIsCleanAndStaysCleanAfterSaveAs`, `SaveUITests.saveAsNewImageWritesWhitePNG`
- [ ] On a freshly opened PNG and a fresh New Image, Edit > Undo and Edit > Redo are disabled and titled "Undo"/"Redo", and closing the window does not ask to save. → `HistoryUITests.freshOpenedDocumentHasNothingToUndo`, `freshNewImageHasNothingToUndo`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases
- **Sparse tiles:** painting into an absent tile records `before == nil` (cost = one tile); undo removes the tile again (`tile(at:) == nil`), so undo frees memory.
- **Edge tiles** (canvas not a multiple of 256): 0002 stores every tile at full size, so each costs `Tile.byteCount` (262,144) like an interior tile; tests use a 600×520 canvas (3×3 tiles, last column 88 px, last row 8 px of image inside the tile).
- **Fully transparent and semi-transparent pixels** (straight alpha) round-trip exactly: undo/redo compare raw RGBA bytes, including RGB under alpha 0.
- **Identical writes** (same colour over same pixels): empty diff → no step, document stays clean.
- **A single step larger than the budget** is kept as the only non-base step; `totalBytes > budgetBytes` is then allowed.
- **Budget 0** keeps base + current step (+ redo steps until the next commit).
- **Budget lowered while steps are undone:** only steps older than the current one are dropped; redo steps survive until the next commit.
- **Saved state folded or discarded:** folded saved step → saved marker moves to the base; folding past it or discarding it → the document stays dirty until saved again.
- **Undo or save while a tool has an uncommitted edit:** `prepareForNavigation` commits it first (0006 `ToolDispatcher.commitPendingEdit()` → `Tool.commit`), so the undone step is the one just committed and the saved file contains it. No tool has pending state yet; 0009 (in-progress stroke) and later tools (0020, 0038–0040) rely on this hook.
- **⌘Z with no document window** (only panels open): Undo disabled — the panel returns nil when there is no current document.
- **Text fields in the document window** (tool options bar) register their typing undo on the same `UndoManager` while editing; they never change the edited state (NSDocument has no undo manager to observe). The bridge's mirror invariants hold whenever no field is being edited; AppKit removes field-editor actions when editing ends.
- **File > Revert To Saved:** history is reset to a single "Open Image" step and the undo manager is emptied.
- **Mismatched structure** passed to `TileDiff.between(before: LayeredImage, …)`: throws `canvasSizeMismatch` / `layerStructureMismatch`, never crashes.
- **Active layer (H-6, D-34):** undoing or redoing a tile diff on a non-active layer does not change `activeLayerIndex`; snapshot items restore it with the rest of the structure (the step itself changed the layer stack).
- **Step IDs** are never reused, even after drops and discards (`HistoryStep.ID` keeps increasing), so the History panel (0010) can key rows by ID.

## Test plan

Shared test support (new):
- `PaintDotMacTests/History/Support/SyntheticEdits.swift`: `fillRect(_ image: inout LayeredImage, layer: Int, rect: PixelRect, color: ColorRGBA8)` that writes straight RGBA through 0002's region write and returns the touched `TileCoordinate`s (computed independently as `floor(x/256)…floor((maxX-1)/256)` × rows); `ReferenceCanvas` — the oracle: one flat `[UInt8]` of `w × h × 4` per layer that `fillRect` also updates by direct byte writes; `assertMatches(_ image: LayeredImage, _ oracle: ReferenceCanvas)` reads every layer's full region and compares bytes, printing the first differing pixel.
- `PaintDotMacTests/History/Support/FakeHistoryItem.swift`: an item with explicit `byteCost`, name, and `change`, whose `apply`/`revert` set `state.image.layers[0].name` to `after`/`before` strings — lets budget tests use exact costs.
- Random tests use `SeededRandom` (0002) and print the seed on failure.

**Unit tests**
- `PaintDotMacTests/History/TileDiffTests.swift`
  - `unchangedTilesAreSkipped`: 512×512 opaque white layer; copy; no writes → `between` is empty, `byteCost == 0`.
  - `identicalWriteIsEmpty`: fill (10,10,20,20) white over white → empty diff.
  - `singleTileChange`: fill (10,10,20,20) red → 1 entry at (0,0), `before`/`after` non-nil, `byteCost == 524_288`, `changedTiles == [id: [(0,0)]]`.
  - `crossTileChange`: fill (250,250,10,10) → 4 entries (0,0),(1,0),(0,1),(1,1) in row-then-column order, cost 2_097_152.
  - `sparseBeforeTile`: empty layer (no tiles), fill (300,300,5,5) → 1 entry at (1,1), `before == nil`, cost 262_144; `revert` → `tile(at: (1,1)) == nil`.
  - `candidatesLimitTheScan`: change tiles (0,0) and (1,1), pass candidates [(0,0)] → only (0,0) recorded.
  - `applyRevertIdentity`: random edits (seeded, 100 seeds) on a 600×520 two-layer image: `revert` on after == before bytes; `apply` on before == after bytes.
  - `imageBetweenThrowsOnSizeMismatch`, `imageBetweenThrowsOnLayerMismatch` (added layer; reordered layers).
  - `imageBetweenOrdersByLayer`: changes on layers 1 and 0 → entries for layer 0 first.
- `PaintDotMacTests/History/HistoryCostTests.swift`
  - `tileBytesNilIsZero`, `tileBytesFullTile == 262_144`; `storageKeyMatchesSharesStorage`: a tile and its copy have equal keys and `sharesStorage`; after mutating the copy, the keys differ and `sharesStorage` is false.
  - `addEmptyLayerCostsZero`, `duplicateLayerCostsZero` (shared storage), `deleteLayerCostsItsTiles` (layer with 3 stored tiles → 786_432), `rewrittenCanvasCostsBothSides` (2 old tiles + 4 new → 1_572_864), `sharedStorageCountedOnce` (two layers sharing a tile on the before side, deleted together → 262_144).
- `PaintDotMacTests/History/HistoryItemTests.swift`
  - `tileDiffItemForwards`: name/icon/cost/change/isNoOp from its diff.
  - `snapshotItemRoundTrip`: before = 1 layer 400×300; after = canvas 512×512 with 2 layers and `activeLayerIndex` 1; `revert` restores size, layer count, names, active index, pixels; `apply` restores the after state; `change == .structure`.
  - `compositeOrder`: diff A (tile (0,0) white→red) then diff B (red→blue): `apply` → blue; `revert` → white; cost = A + B; change = merged pixels.
  - `compositeEmptyIsNoOp`, `compositeOfNoOpsIsNoOp`.
  - `historyChangeMerging`: pixels∪pixels union per layer; anything ∪ structure = structure.
  - `historyIconRawValues`: all raw values unique; for each tool case (`rectangleSelect` … `shapes`), `ToolID(rawValue: icon.rawValue) != nil`; `ToolID.colorPicker/zoom/pan` raw values are not `HistoryIcon` raw values.
  - `tileDiffKeepsActiveLayer` (H-6): 2-layer image, `activeLayerIndex` 1; a diff on layer 0; `revert` and `apply` leave `activeLayerIndex == 1`.
- `PaintDotMacTests/History/HistoryStackTests.swift`
  - `initialOpenImageStep`: steps.count 1, `steps[0].name == "Open Image"`, icon `.openImage`, `isBase`, id 0, `canUndo == false`, `canRedo == false`, `undoStep == nil`, `totalBytes == 0`, `isAtSavedState`.
  - `initialNewImageStep`: name "New Image", icon `.newImage`.
  - `defaultBudget`: `HistoryStack(base: .openImage).budgetBytes == 1_073_741_824`; `init(budgetBytes: -5).budgetBytes == 0`.
  - `commitUndoRedo`: commit a 1-tile `TileDiffHistoryItem` "Paintbrush" → `currentIndex 1`, `undoStep?.name == "Paintbrush"`, `totalBytes == 525_312`, `isAtSavedState == false`; `undo` returns `.pixels([id:[(0,0)]])`, pixels equal the pre-edit bytes, `redoStep?.name == "Paintbrush"`, `isAtSavedState`; `redo` → post-edit bytes.
  - `performAppliesThenRecords`: `perform` on the before state → state equals after; one step.
  - `commitDiscardsRedo`: commit A, B, C; undo twice; commit D → names [Open Image, A, D], `totalBytes` = A + D + 2 × 1_024, `discardedRedoStepIDs == [idB, idC]`.
  - `noOpItemIsIgnored`: empty-diff item → `recordedStepID == nil`, steps unchanged, still saved.
  - `undoAtBaseAndRedoAtTopAreNoOps`: return nil; state bytes unchanged.
  - `jumpEqualsRepeatedUndoRedo`: 5 steps; for every pair (from, to) the state after `jump` equals the state reached by explicit undos/redos (compared to oracle), `currentIndex == to`, changes count = |from − to|.
  - `jumpOutOfRangeIsNoOp`: `jump(to: -1)`, `jump(to: steps.count)`, `jump(to: currentIndex)` → `[]`.
  - `stepIDsAreNeverReused`: commit, undo, commit, force drops → all IDs ever issued are distinct and increasing.
  - `savedMarker`: markSaved at step 2; undo → not saved; redo → saved; undo, commit → `savedStepID == nil`, never saved again until `markSaved`; `markSaved(stepID: 999)` → nil.
- `PaintDotMacTests/History/HistoryBudgetTests.swift` (exact oracles from the rule in Scope §7)
  - `dropsOldestTileStep`: budget 1_048_576; 512×512 opaque layer; commit two 1-tile steps on different tiles (525_312 each) → after the 2nd: steps [Open Image, step2], `droppedStepIDs == [id1]`, `totalBytes == 525_312`; undo → pixels equal oracle after step 1 (not the opened image); `canUndo == false`; base name still "Open Image".
  - `keepsSingleOversizedStep`: budget 100; commit a 525_312 step → kept; `totalBytes > budgetBytes`; undo works.
  - `fakeCostSequence`: budget 10_000, `FakeHistoryItem` costs 3_000 (4_024 with overhead): A, B → 8_048; C → drops A, 8_048; undo once (current 1); `setBudget(0)` → returns [] (current < 2); redo; `setBudget(0)` → returns [idB], steps [base, C], `currentIndex 1`, `totalBytes 4_024`.
  - `redoStepsNeverDroppedByEnforcement`: 4 steps, undo to index 1, `setBudget(0)` → nothing dropped, `canRedo`.
  - `savedMarkerFollowsFold`: saved at A, fold A → `savedStepID == 0` and `isAtSavedState` when at base; saved at base, fold → nil.
- `PaintDotMacTests/Settings/AppSettingsTests.swift` (extend 0004's suite, isolated `UserDefaults(suiteName:)`): `undoBudgetDefault == 1_073_741_824`; `undoBudgetReadsStoredValue` (stored 5_000_000 under `"settings.undoBudgetBytes"` → 5_000_000); `undoBudgetNegativeFallsBack` (−1 → default); `undoBudgetWrongTypeFallsBack` (`"abc"` → default); `undoBudgetKeyIsReset`: `LaunchOptions.shouldReset(key: "settings.undoBudgetBytes") == true`.

**Round-trip and property tests** — `PaintDotMacTests/History/HistoryPropertyTests.swift`
- `randomSessionsMatchOracle` (200 seeds × 40 operations, 600×520 image with 2 layers, layer 0 opaque white, layer 1 empty): each operation is chosen at random among *edit* (random layer, rect 1…300 px possibly crossing tiles and the canvas edge (clipped), random colour including alpha 0 and 128), *undo*, *redo*, *jump to random index*. The model keeps a list of `ReferenceCanvas` states and an expected index (edits truncate the list after the expected index). After every operation: `assertMatches(state.image, model[expectedIndex])`, `currentIndex`, `canUndo`, `canRedo`, and `undoStep?.name`/`redoStep?.name` match the model. Specifically, every undo-then-redo pair restores byte-identical tiles. Budget = default (no drops).
- `budgetInvariants` (300 seeds × 60 ops with `FakeHistoryItem` random costs 0…5_000 and random budget 0…20_000, ops commit/undo/redo/setBudget): after every op `totalBytes == Σ(cost + 1_024)` over non-base steps; `steps[0]` is the base with ID 0 and original name; `0 ≤ currentIndex < steps.count`; after each commit/setBudget either `totalBytes ≤ budgetBytes` or `currentIndex < 2`; the surviving non-base step names are a suffix-preserving subsequence of the model (dropped ones are always the oldest); undoing to the base yields the layer name set by the newest dropped step (or the original if none).

**Integration tests** (headless) — `PaintDotMacTests/History/HistoryIntegrationTests.swift`
- `syntheticSessionUndoRedo`: create a 1000×700 "New Image" `DocumentState` (white "Background" via 0005's `NewImageRequest(size: 1000×700, dpi: 96).makeImage()`), stack base `.newImage`. Script: three synthetic strokes captured with the documented pattern (copy image → `fillRect` live → `TileDiff.between` over touched tiles → `TileDiffHistoryItem` "Paintbrush"), one snapshot "Add New Layer" (append an empty layer, active index 1), one stroke on the new layer. Undo all → pixels and layer count equal the oracle of the blank image; history names `["New Image","Paintbrush","Paintbrush","Paintbrush","Add New Layer","Paintbrush"]`; redo all → final oracle; costs sum exactly as hand-computed from touched-tile counts.
- `fourKOneTileStrokeCostsOneTile` (NF-4): 4000×3000 opaque layer, 1-tile stroke → `totalBytes == 525_312`.
- `fullLayerChangeCost`: 4000×3000 opaque layer, every pixel changed → 192 entries, `byteCost == 100_663_296` (2 × 192 × 262_144; 0002 stores every tile, edge tiles included, at full size).
- `toolContextCommitHook`: through `FakeToolContext` (0006, extended here), `performHistory` of a 1-tile item (state changes to its after bytes), then `updateImage` + `commitHistory` of a second item → `history.steps.map(\.name)` == `["New Image", <first>, <second>]`; a no-op item adds nothing.

**Document glue tests** (hosted unit tests in `PaintDotMacTests`, real Foundation `UndoManager`, no windows)
- `PaintDotMacTests/Document/UndoBridgeTests.swift` (bridge created with `UndoManager()` whose `groupsByEvent = false`)
  - `freshBridgeHasNothingToUndo`: `canUndo == false`, `undoMenuItemTitle == "Undo"`, `redoMenuItemTitle == "Redo"`.
  - `commitNamesUndo`: commit "Paintbrush" → `undoManager.canUndo`, `undoMenuItemTitle == "Undo Paintbrush"`.
  - `menuUndoRevertsState`: `undoManager.undo()` → state pixels equal before, `history.currentIndex == 0`, `redoMenuItemTitle == "Redo Paintbrush"`, `onStateChange` received the item's change, `onEditedChange` received `false`; `undoManager.redo()` → after bytes, `onEditedChange(true)`.
  - `commitAfterUndoClearsRedoInBoth`: both `canRedo` false.
  - `jumpUsesUndoManager`: 4 steps; `jump(to: 1)` → `history.currentIndex == 1`, `undoMenuItemTitle == "Undo <name of step 1>"`, `redoMenuItemTitle == "Redo <name of step 2>"`; `jump(to: 4)` back.
  - `budgetDropRemovesOldestActions`: budget forcing a drop of step 1 → after undoing every remaining step, `undoManager.canUndo == false` exactly when `history.canUndo == false`, and no undo action names the dropped step.
  - `noOpItemRegistersNothing`: `canUndo` stays false, no callbacks.
  - `prepareForNavigationRunsFirst`: the hook is called before the state changes on undo and on redo, and exactly once (before the first step) for a 3-step `jump` (record call order).
  - `revisionBumpsOncePerOperation`: start revision r; commit → r+1; no-op commit → r+1; `undoManager.undo()` → r+2; `redo()` → r+3; with 4 steps, `jump(to: 1)` (3 undos) → +1 only, and `onStateChange` called once with the merged `.pixels` change of the three steps; `jump(to: currentIndex)` → unchanged; `setBudget` that drops one step → +1, `setBudget` that drops none → unchanged; `markSaved` → +1; `reset` → +1.
  - `resetClearsEverything`: after `reset`, `canUndo`/`canRedo` false and one base step with the new base name.
  - `eventGroupedNaming`: with `groupsByEvent = true`, the test opens an outer `beginUndoGrouping()` (simulating the event group), commits, closes it → `undoActionName == "Paintbrush"`. The bridge calls `setActionName` after registration, outside any nested group, so the name lands on the event group.
- `PaintDotMacTests/Document/UndoBridgePropertyTests.swift` — `managerMirrorsStack` (100 seeds × 50 ops: commit fake items, `undoManager.undo()`, `undoManager.redo()`, `jump`, `setBudget`): after each op `undoManager.canUndo == history.canUndo`, `canRedo` matches, `undoActionName == (history.undoStep?.name ?? "")`, `redoActionName == (history.redoStep?.name ?? "")`.
- `PaintDotMacTests/Document/PaintDocumentHistoryTests.swift`
  - `openedDocumentIsClean`: read a generated PNG via `read(from:ofType:)` → `isDocumentEdited == false`, `hasUndoManager == false`, one "Open Image" step.
  - `editDirtiesAndUndoCleans`: commit → `isDocumentEdited`; `undoBridge.undo()` → clean; redo → dirty.
  - `saveClearsAtCurrentStep`: dirty; `updateChangeCount(withToken: changeCountToken(for: .saveOperation), for: .saveOperation)` → clean, `savedStepID == currentStepID`; undo → dirty; redo → clean.
  - `editDuringSaveStaysDirty`: take the save token, commit another step, then complete with that token → still dirty.
  - `autosaveAndSaveToDoNotClear`: same with `.autosaveElsewhereOperation` and `.saveToOperation` → still dirty, `savedStepID` unchanged.
  - `newImageIsCleanWithNewImageBase` (APP-9, supersedes 0005's interim rule): the rewritten step-4 path (`undoBridge.reset(state:base: .newImage)`) → base "New Image", `isDocumentEdited == false`; `PaintDocument(type:)` → base "New Image", clean.
  - `saveCommitsPendingEdit`: set `prepareForNavigation` to a closure that commits a 1-tile `TileDiffHistoryItem` (simulating a tool with a pending stroke); `save(to: tempURL, ofType: "public.png", for: .saveAsOperation)` → the closure ran before writing, the decoded file contains the edit's pixels, the history has 2 steps, and the document is clean.
  - `revertResetsHistory`: commit 2 steps, `revert(toContentsOf:ofType:)` with the temp PNG → one "Open Image" step, clean, `undoBridge.undoManager.canUndo == false`.
  - `windowControllerSuppliesBridgeUndoManager`: `DocumentWindowController.windowWillReturnUndoManager(window) === document.undoBridge.undoManager`.

**UI tests** — `PaintDotMacUITests/HistoryUITests.swift` (via `UITestApp`, fixture PNG generated into a temp dir)
- `freshOpenedDocumentHasNothingToUndo`: launch with `-UITestOpen <png>`; open the Edit menu: item "Undo" exists and `isEnabled == false`; item "Redo" exists and is disabled; no menu item titled with "Undo " prefix plus a name. Press ⌘W → the window closes with no "Do you want to save" sheet (`app.sheets.count == 0`, window count drops to 0).
- `freshNewImageHasNothingToUndo` (APP-9): launch empty, ⌘N, confirm the New Image dialog with defaults; Edit > Undo and Redo disabled; ⌘W closes without a save sheet; ⌘N, Return, ⌘Q quits without a save prompt (`app.wait(for: .notRunning, timeout: 5)`).
- `undoShortcutIsHarmlessOnFreshDocument`: with the PNG open, press ⌘Z and ⇧⌘Z; the canvas (`canvas`) and `statusBar.imageSize` are unchanged and the app is still running.

**Performance** — `PaintDotMacTests/Performance/HistoryPerformanceTests.swift` (XCTest `measure`)
- `testFullLayerDiffAndCommit`: 4000×3000 layer, every tile changed: `TileDiff.between` + `commit`. Report the time in Verification status; fail only above 150 ms (gross regression).
- `testOneTileStrokeCommit`: 4000×3000, 1 changed tile among 192 candidates' worth of identity checks: report; fail above 5 ms (well within the NF-1 16 ms frame).

**Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.

**Manual verification**
1. Open a PNG; open the Edit menu: "Undo" and "Redo" are greyed out; ⌘W closes without prompting. (Automated too; a quick visual check of the menu titles.)
2. File > New (⌘N), OK: same result.
3. With the History panel absent (0010) and no pixel tool (0009), nothing else is observable; "Undo Paintbrush" in the real menu is checked manually in 0009, and the close/quit prompts after a real edit are tested in 0009.

## Out of scope
- History panel UI, step icons, greyed-out undone rows, click-to-jump UI (0010; it uses `UndoBridge.jump(to:)`, `history.steps`, `history.currentIndex`, and observes `historyRevision`).
- Close/quit prompt UI tests after a real edit (0009, with the Paintbrush).
- Any pixel tool (Paintbrush 0009 is the first to commit `TileDiffHistoryItem`s).
- Selection state and `SelectionHistoryItem` (0013), layer operations and `LayerHistoryItem` (0024), canvas-size operations (0022, 0035–0037) — they build on `DocumentSnapshotHistoryItem`/`HistoryItem` from this spec.
- Settings UI for the undo budget and live budget changes across open documents (0046, calling `UndoBridge.setBudget`).
- Crash-recovery autosave (0047) and disk-backed history spillover (H-4, 0062).
