# 0020 — Add the Move Selected Pixels tool: floating pixels, transform handles, and the resampler

> Source: PRD.md §5.3 T-5 ("Translate, plus rotate and scale with handles. Pixels stay "floating" until committed. Resampling is bilinear while dragging and on commit, and nearest-neighbor when the transform is an integer translation/scale with no rotation."), §12 D-21 (that resampling rule), D-13 (M cycles Move Selected Pixels → Move Selection), D-34/H-6 (no-op edits add no step), D-27 (fully erased pixel = (0,0,0,0)), §5.12 (Ctrl → ⌘, Alt → ⌥), E-1/H-3 (history), AGENTS.md rules 2–4, 6, 8.
> Paint.NET references (fetched 2026-11-05; www.getpaint.net/doc/latest redirects to paint.net/doc/latest):
> - Move Tools — https://paint.net/doc/latest/MoveTools.html: moving leaves "an area of transparency … in place of the moved pixels"; with no selection the tool moves the whole layer; nubs resize, dragging a nub past the opposite one flips; left-drag in a corridor just outside the box rotates; "The Right Mouse button always accesses rotation - regardless of the location of the cursor"; Shift → 15° steps; arrow keys 1 px, Ctrl+arrow 10 px; "Move or rotate a copy of a selection by holding down the Ctrl key … leaving the original pixels untouched"; a toolbar resampling dropdown (Bicubic default) and Gamma split button.
> - Keyboard & Mouse Commands — https://paint.net/doc/latest/KeyboardMouseCommands.html, Move Tools rows ("Move copy of selection: Hold Ctrl and drag", "Rotate copy of selection: Hold Ctrl and drag … or drag with Right Mouse Button", "Shift + drag corner nub", "Alt + drag corner nub", "Rotate by 15° increments").
> - Paint.NET 3.36 source, https://github.com/wangdeshui/paint.net: `src/tools/MoveTool.cs` (lifting copies the selected pixels into a `MaskedSurface` and, **unless Ctrl is held, clears the selected region of the layer to transparent**; the moved pixels are drawn straight into the layer; `OnDeactivate` and `OnSelectionChanging` call `Drop()`), `src/Strings/Strings.resx` (history names **"Move Pixels"**, **"Scale Pixels"**, **"Rotate Pixels"**, **"Finish Pixels"** — `MoveTool.HistoryMemento.Translate/Scale/Rotate/DropPixels`).
> - A paint.net developer (forums.getpaint.net/topic/568): lifted pixels are dropped by the "Finish Pixels" step; undoing back past "Finish Pixels" returns them to the floating state.
> Milestone: M2
> Depends on: 0019-move-selection-tool (and transitively 0006, 0008, 0009, 0013, 0014)

## Context

Not yet implemented. After 0001–0019:

- **0006:** `Tool` (`hasPendingEdit`, `activate`/`deactivate` — default deactivate commits a pending edit, mouse handlers, `keyDown` default: Return/Enter with pending → `commit`, Escape with pending → `cancel`, `commit(context:)`, `cancel(context:)`, `cursor(at:modifiers:)`), `ToolEvent` (`location` canvas pixels y-down, `viewLocation`, `button` — right button and Control-left arrive as `.secondary`, `modifiers`), `ToolKeyEvent`, `ToolContext`, `ToolOverlay`, `ToolCursor`, `ToolDispatcher` (`commitPendingEdit()`, `setContext` deactivates the tool in the old document, Escape mid-gesture → `cancel`), `ToolDescriptor.supportsPendingEdits` (already `true` for `moveSelectedPixels`, so the options bar shows **Finish**, `toolOptions.finish`). One tool instance per `ToolID` for the app's lifetime, shared by all documents.
- **0008:** `DocumentState`, `HistoryItem`, `TileDiff`/`TileDiffHistoryItem`, `CompositeHistoryItem`, `HistoryStack` (`steps`, `currentIndex`, `currentStepID`, budget folding into the base step), `HistoryStep.ID`, `HistoryIcon.moveSelectedPixels`, `UndoBridge` (`prepareForNavigation` before undo/redo/jump/save; `perform`; `onStateChange`), `ToolContext.updateImage`/`commitHistory`/`performHistory`.
- **0009:** `BlendOps.blend(_:dst:src:opacity:)`, `BlendOps.mul255`.
- **0013:** `Selection` (`nil` = no selection, never empty; `bounds: PixelRect`; `mask.coverage(x:y:)`), `SelectionHistoryItem`, `SelectionCommand.selectAll`, `HistoryChange.selection`/`.pixelsAndSelection`, `MarchingAntsOverlay`, `ToolContext.selection`, `-UITestSelectRect`. Edit-menu commands in `DocumentWindowController` call `undoBridge.prepareForNavigation?()` before acting.
- **0014:** `SelectionToolOptions.quality` (`tool.rectangleSelect.selectionQuality`, default `.antialiased`).
- **0019 (reused unchanged; this spec only adds to it):** `Core/Tools/TransformHandles.swift` — `TransformHandle`, `TransformGesture` (`.translate`, `.scale(TransformHandle)`, `.rotate`), `TransformBox`, `TransformSession` (`init?(sourceBounds:)`, `outlineTransform`, `canvasCorners`, `canvasCenter`, `angle`, `integerTranslation`, `applying(_:from:to:modifiers:)`, `translatedBy(dx:dy:)`), `TransformHandles.hitTest(viewPoint:session:canvasToView:button:)` (handles 6 pt, corridor 20 pt, secondary → rotate), `.translation(from:to:)`, `.constrainAngle`, `.nudge(for:)` (arrows 1 px, ⌘ × 10); `Selection.transformed(_:by:antialiased:)`, `SelectionMask.translated(dx:dy:)`; `ToolOverlay.transformHandles(TransformHandlesPreview)` (`outline`, `corners`, `showsHandles`, `center`, `hidesCurrentSelection`) drawn by `Canvas/TransformHandlesOverlay.swift`; `ToolCursor.move/.rotate/.resize(TransformHandle)`; `MoveSelectionTool` (no selection → "Select All" step first; per-gesture steps "Move/Scale/Rotate Selection"). Until this spec, M's group is `[.moveSelection]`; registering this tool makes it the group's first tool by `ToolID.allCases` order (M → Move Selected Pixels, M M / Shift+M → Move Selection).

Paint.NET behaviour mirrored here: the first manipulation **lifts** the selected pixels of the active layer (leaving a transparent hole, or not with Ctrl/⌘), the pixels **float** while the user keeps moving/scaling/rotating them (each gesture is a history step, and the layer always shows the result), and they are **finished** ("Finish Pixels") when the tool is deactivated, Return/Finish is used, or the selection or document is changed by another command. Undo walks back through the floating steps without dropping the pixels.

## User story

As a PaintDotMac user, I select part of my image, press M, and drag the pixels elsewhere, leaving a transparent hole; I drag the nubs to scale, drag just outside the box (or right-drag) to rotate, use the arrow keys to nudge, and ⌘-drag to move a copy. Everything stays editable and undoable step by step until I press Return, click Finish, switch tools, or run another command; Escape puts everything back exactly as it was. Integer moves and integer scales stay pixel-perfect; rotations and fractional scales are smoothly resampled.

## Scope & changes

### Core (pure Swift; unit-tested)

1. **`Core/Rendering/Resampler.swift`** (new) — point-sampling resampler for affine transforms of straight RGBA8 surfaces. Built so 0035 adds `bicubic` and `supersampling` as new `ResamplingMode` cases plus one kernel each, without changing call sites.
   ```swift
   public enum ResamplingMode: String, CaseIterable, Sendable {
       case nearestNeighbor, bilinear          // 0035 adds bicubic, supersampling
       public var displayName: String          // "Nearest Neighbor", "Bilinear" (Paint.NET spelling)
   }
   public enum Resampler {
       public static let epsilon: Double = 1e-9
       /// D-21: nearest-neighbor iff the transform is an integer translation/scale with no rotation; else bilinear.
       public static func mode(for transform: CGAffineTransform) -> ResamplingMode
       /// Destination pixels that can receive a non-zero sample: bounding box of transform(sourceRect outset by
       /// 1 px for bilinear, 0 px for nearest), rounded outward (floor min, ceil max). Not clipped.
       public static func destinationBounds(sourceRect: PixelRect, transform: CGAffineTransform, mode: ResamplingMode) -> PixelRect
       /// Resamples `source` (its pixel (0,0) sits at canvas `sourceOrigin`) through `transform` (source canvas
       /// coordinates → destination canvas coordinates) into `destination` (tightly packed straight RGBA8,
       /// destination.width × destination.height × 4). Pixels outside the source read as transparent.
       public static func resample(_ source: TiledSurface, sourceOrigin: PixelPoint, transform: CGAffineTransform,
                                   mode: ResamplingMode, destination: PixelRect) -> [UInt8]
       /// One sample at a source-canvas point (used by tests as the per-pixel oracle path).
       public static func sample(_ source: TiledSurface, sourceOrigin: PixelPoint, at point: CGPoint, mode: ResamplingMode) -> ColorRGBA8
   }
   ```
   - **Snapping:** any coordinate or matrix entry within `epsilon` of an integer is treated as that integer (in `mode(for:)` and before every `floor` in sampling), so 90° rotations and exact scales built with `cos`/`sin`/`atan2` still hit pixel centres exactly.
   - **`mode(for:)`:** `.nearestNeighbor` iff `|b| ≤ ε`, `|c| ≤ ε`, `a` and `d` are non-zero integers (negative = flip), and `tx`, `ty` are integers; otherwise `.bilinear`.
   - **Sampling geometry (both modes):** destination pixel `(x, y)` is evaluated at its centre `(x + 0.5, y + 0.5)`; `p = transform.inverted()` of that point, minus `sourceOrigin` (source-local, pixel centres at `i + 0.5`). A non-invertible transform yields all-transparent output (defined no-op; the minimum box size in 0019/item 6 prevents it in practice).
   - **Nearest:** source pixel `(floor(p.x), floor(p.y))`, copied straight; outside the source → `(0,0,0,0)`.
   - **Bilinear (premultiplied, transparent outside):** `u = p.x − 0.5`, `v = p.y − 0.5`, `x0 = floor(u)`, `y0 = floor(v)`, `fx = u − x0`, `fy = v − y0`. Neighbours `(x0,y0)`, `(x0+1,y0)`, `(x0,y0+1)`, `(x0+1,y0+1)` with weights `(1−fx)(1−fy)`, `fx(1−fy)`, `(1−fx)fy`, `fx·fy`; a neighbour outside the source contributes `(0,0,0,0)`. In `Double`: `A = Σ w·a`, `Pc = Σ w·c·a` per colour channel. Output alpha `= min(255, Int(A + 0.5))` (round half up); output alpha 0 → `(0,0,0,0)`; otherwise colour `= min(255, Int(Pc / A + 0.5))` (un-premultiply with the unrounded `A`). Colour under alpha 0 never bleeds, and edges fade to transparent.
   - **Performance:** process the destination in 256-row bands with `DispatchQueue.concurrentPerform`; fetch the needed source band once with `readPixels(in:)` (no per-pixel `pixel(at:)` in the inner loop). Pure and `Sendable`.

2. **`Core/Model/FloatingPixels.swift`** (new) — lifted (or pasted) pixels plus everything needed to re-render, finish, and cancel them. Stored in `DocumentState`, so undo/redo restores it exactly (0021 relies on this: one undo cancels a floating paste).
   ```swift
   public struct FloatingPixels: Sendable, Equatable {
       public let id: UUID                         // one floating session (lift or paste)
       public let layerID: Layer.ID                // layer the pixels float over and are finished into
       public let sourceRect: PixelRect            // canvas rect of `source` at lift time (non-empty)
       public let source: TiledSurface             // lifted pixels, straight RGBA8, size = sourceRect.size
       public let outline: Selection?              // selection travelling with the pixels (lift-time canvas coords); nil only for a paste fully off-canvas
       public var underlay: TiledSurface           // the layer beneath the floating pixels (hole punched unless duplicated)
       public var session: TransformSession        // 0019's type; created with sourceBounds = CGRect(sourceRect)
       public let restore: FloatingRestorePoint    // exact pre-session state, for Escape
       public var affine: CGAffineTransform { session.outlineTransform }
       public var resamplingMode: ResamplingMode { Resampler.mode(for: affine) }
       public var destinationBounds: PixelRect     // Resampler.destinationBounds(sourceRect:transform:mode:) ∩ canvas bounds
       public func transformedSelection(antialiased: Bool) -> Selection?   // outline.map { Selection.transformed($0, by: session, antialiased:) } ?? nil
       public var byteCount: Int                   // Tile.byteCount × source.allocatedTileCount

       public static func lift(from state: DocumentState, duplicate: Bool, baseStepID: HistoryStep.ID) -> FloatingPixels?
       public static func paste(_ surface: TiledSurface, at origin: PixelPoint, into state: DocumentState,
                                baseStepID: HistoryStep.ID) -> FloatingPixels       // for 0021
       /// Writes underlay ⊕ resampled source over `region ∩ canvas` of `surface` (the live layer).
       public func render(into surface: inout TiledSurface, region: PixelRect)
       public func withUnderlay(_ surface: TiledSurface) -> FloatingPixels          // ⌘-drag "stamp a copy"
   }
   public struct FloatingRestorePoint: Sendable, Equatable {
       public let layerSurface: TiledSurface       // the layer before the session (CoW-shared)
       public let selection: Selection?            // the selection before the session
       public let baseStepID: HistoryStep.ID       // the step that was current before the session's first step
   }
   ```
   - **Lift:** layer = the active layer; `M` = `state.selection!.mask` (the tool guarantees a selection, see item 6; `lift` returns `nil` when `state.selection == nil` or the active layer index is invalid); `sourceRect = selection.bounds`. Per pixel of `sourceRect`, `cov = M(x, y)`: source = layer pixel with `alpha' = mul255(alpha, cov)`; hole (only if `!duplicate`) = layer pixel with `alpha' = mul255(alpha, 255 − cov)`; in both, `alpha' == 0` → `(0,0,0,0)` (D-27; Paint.NET clears to transparent). Outside `sourceRect` the underlay is the layer unchanged (shared tiles); with `duplicate` the whole underlay is the unchanged layer. `outline = state.selection`, `session = TransformSession(sourceBounds: CGRect(sourceRect))!` (non-empty rect; invariant, commented), `restore = (layer surface, state.selection, baseStepID)`. Lifting fully transparent pixels is allowed.
   - **Paste (0021):** `sourceRect = PixelRect(origin:, size: surface.size)` (may extend past the canvas), `source = surface`, `underlay` = active layer unchanged, `outline = Selection(rect: CGRect(sourceRect), canvasSize:)` (clipped; `nil` if fully off-canvas), `restore = (active layer, state.selection, baseStepID)`. 0021's `PasteStep` records its own "Paste" step with the three-part composition of item 4 (selection after = the outline; a leading `DocumentSnapshotHistoryItem` when the canvas is expanded; icon `.paste`), renders the floating pixels into the layer as `render` does, and relies on item 10's policy to activate this tool.
   - **Render:** for each pixel of `region ∩ canvas`: `dst = underlay(x, y)`, `src` = `Resampler` sample of `source` (origin `sourceRect.origin`, `affine`, `resamplingMode`), `out = BlendOps.blend(.normal, dst:, src:, opacity: 255)` (pixels outside `destinationBounds` are just `underlay`). Written with `writePixels` per touched tile band, so untouched tiles keep storage and generation.
   - **Off-canvas pixels are kept while floating:** `source` is never clipped; moving off the canvas and back restores them. Finishing with pixels off-canvas drops those pixels.
   - `Equatable` compares all stored properties (`TiledSurface ==` has the shared-storage fast path).

3. **`Core/Model/DocumentState.swift`** (extend 0008/0013): `public var floatingPixels: FloatingPixels?` (default `nil`, added to the initializer with default `nil`). Invariant (doc comment + 0013's `assert` in `UndoBridge`): `floatingPixels == nil || (image.layerIndex(for: floatingPixels.layerID) != nil && floatingPixels.underlay.size == image.size)`. Snapshot operations (layer/canvas-size changes) only run with `floatingPixels == nil` because commands finish first (item 9).

4. **`Core/History/FloatingPixelsHistoryItem.swift`** (new):
   ```swift
   public struct FloatingPixelsHistoryItem: HistoryItem {
       public init(name: String, before: FloatingPixels?, after: FloatingPixels?)
       // icon .moveSelectedPixels; change = .selection (repaints ants + handles, uploads no tiles);
       // isNoOp = (before == after); apply: state.floatingPixels = after; revert: = before.
       // byteCost: before == nil && after != nil → after.byteCount + Tile.byteCount × (underlay tiles of `after`
       //           whose storage differs from restore.layerSurface's tile at the same coordinate); otherwise 256.
       public func startsSession(_ id: UUID) -> Bool   // before == nil && after?.id == id
   }
   public enum MoveSelectedPixelsHistory {
       public static func name(for gesture: TransformGesture) -> String  // .translate → "Move Pixels", .scale → "Scale Pixels", .rotate → "Rotate Pixels"
       public static let finishStepName = "Finish Pixels"
       /// One user-visible step: TileDiff of the floating layer + selection change + floating-state change.
       public static func step(named name: String, before: DocumentState, after: DocumentState, layerID: Layer.ID,
                               candidates: Set<TileCoordinate>) -> CompositeHistoryItem
       public static func finishStep(_ floating: FloatingPixels) -> FloatingPixelsHistoryItem   // f → nil
       public static func stepStartsSession(_ step: HistoryStep, id: UUID) -> Bool               // looks inside CompositeHistoryItem
   }
   ```
   - `step` = `CompositeHistoryItem(name:, icon: .moveSelectedPixels, items: [TileDiffHistoryItem(TileDiff.between(before: before layer surface, after: after layer surface, layerID:, candidates:)), SelectionHistoryItem(before: before.selection, after: after.selection), FloatingPixelsHistoryItem(before: before.floatingPixels, after: after.floatingPixels)])` (all with the same name and icon). Its merged change is `.pixelsAndSelection(tiles)` (0013 table). An unchanged result is a no-op: no step (H-6).
   - **"Finish Pixels"** is `finishStep` alone: the layer already shows the rendered pixels and the selection already moved, so finishing changes no pixels and no selection; it only clears `floatingPixels` (Paint.NET 3.36 `Drop()` likewise only ends the lifted state).

5. **0019 geometry, reused unchanged** (`TransformSession`, `TransformHandles`, `Selection.transformed`). Additions here, all tool-side:
   - **Integer snapping for scale:** when the gesture is `.scale` and `|session.angle| ≤ 1e-9`, the tool rounds both the start and current canvas points to integers before calling `applying`, so the local drag delta is integral and the box edges stay on pixel boundaries (lift rects are integral) — this keeps integer scales on D-21's nearest path. Translate is already integral (0019). Rotation is never snapped (only Shift's 15°).
   - **Session source bounds:** this tool always builds its session from the **integer** `selection.bounds` (mask bounds), not 0019's `path.boundingBoxOfPath`, so nubs sit on pixel edges and `outlineTransform` maps whole source pixels.
   - Rotation is about the box centre (`canvasCenter`), as in 0019; there is no draggable pivot (0019 Out of scope).

6. **`Core/Tools/MoveSelectedPixelsTool.swift`** (new) — `@MainActor final class MoveSelectedPixelsTool: Tool`, `id = .moveSelectedPixels`, registered in `ToolRegistry.standard()`. No tool options (D-21 fixes resampling; Paint.NET's dropdown is out of scope).
   - **State:** `private weak var context: (any ToolContext)?` (set in `activate` and on every event); `private var drag: Drag?` with `gesture: TransformGesture`, `start: CGPoint`, `duplicate: Bool` (⌘ at mouse-down), `beforeState: DocumentState` (CoW snapshot at mouse-down, after any "Select All" step), `floating: FloatingPixels?` (the live one being edited; `nil` until the first change), `lastRegion: PixelRect`, `touched: Set<TileCoordinate>`; `private var hoverGesture: TransformGesture?`.
   - **Idle session** (for hit-testing, cursor, and the idle overlay): `context.floatingPixels?.session`, else `TransformSession(sourceBounds: CGRect(selection.bounds))`, else `nil` (no selection).
   - **`hasPendingEdit`** = `drag != nil || context?.floatingPixels != nil`.
   - **`mouseDown`:** ignore non-finite points. If there is no selection and nothing floats: `if let item = SelectionCommand.selectAll.makeHistoryItem(for: state) { performHistory(item) }` — the "Select All" step (Paint.NET `MoveToolBase`, same as 0019), so the whole layer is lifted. Gesture = `TransformHandles.hitTest(viewPoint: event.viewLocation, session: idleSession, canvasToView: context.transform.canvasToViewAffine, button: event.button)`. Store `Drag` (`beforeState` = current state). Nothing is lifted on mouse-down: a click without movement leaves pixels untouched (the "Select All" step, if any, stays, as in 0019).
   - **`mouseDragged`:** `session' = sessionAtStart.applying(gesture, from: start, to: event.location, modifiers:)` (with item 5's scale snapping). If `session'` equals the start session and nothing was lifted yet → nothing. Otherwise, on the first change: if nothing floats, `FloatingPixels.lift(from: beforeState, duplicate: drag.duplicate, baseStepID: context.history.currentStepID)`; if pixels already float and ⌘ was held at mouse-down, `withUnderlay(live layer surface)` (stamps the current rendering, so a copy stays behind — Paint.NET "move/rotate a copy"). Set `floating.session = session'`, `region = lastRegion ∪ floating.destinationBounds` (∪ `sourceRect` on the lifting event, so the hole appears), `context.updateImage { floating.render(into: &$0.layers[i].surface, region: region) }`, add the region's tiles to `touched`, `lastRegion = floating.destinationBounds`. Overlay: `.transformHandles(TransformHandlesPreview(outline: outline?.path transformed by affine, corners: session'.canvasCorners, showsHandles: true, center: gesture == .rotate ? session'.canvasCenter : nil, hidesCurrentSelection: true))`. Rendering always uses `floating.resamplingMode` (bilinear unless D-21's integer case).
   - **`mouseUp`:** if a change happened: `after` = `beforeState` with the live layer surface, `selection = floating.transformedSelection(antialiased: options.value(SelectionToolOptions.quality) == .antialiased)`, `floatingPixels = floating`; put the live layer back to `beforeState`'s surface (`updateImage`, free by CoW), then `context.performHistory(MoveSelectedPixelsHistory.step(named: name(for: gesture), before: beforeState, after: after, layerID:, candidates: touched))`, so canvas, ants, and handles refresh through `onStateChange`. Then `drag = nil` and the idle overlay (`outline: nil`, `hidesCurrentSelection: false`).
   - **Arrow keys** (`keyDown`): `TransformHandles.nudge(for:)` non-nil → during a drag return `true` and do nothing; else (Select All first if needed, lift if nothing floats, without duplicate) translate by the nudge and record one **"Move Pixels"** step through the mouse-up path; one step per key event, auto-repeat included. Return `true`.
   - **Return / Enter, Finish button:** `commit(context:)` (0006 default `keyDown` and `commitPendingEdit`).
   - **`commit(context:)`** (Finish, Return, tool switch via default `deactivate`, document switch, commands — item 9): end a drag in progress as `mouseUp` would; then if `context.floatingPixels` is non-nil, `performHistory(MoveSelectedPixelsHistory.finishStep(floating))` → **"Finish Pixels"**; idle overlay.
   - **`cancel(context:)`:** *during a drag* (0006 sends Escape-mid-gesture here): put the live layer back to `beforeState`'s surface, `drag = nil`, idle overlay; the session (if any) stays floating; no step. *Not dragging, with floating pixels* (Escape): cancel the session exactly — find the index `i` of `restore.baseStepID` in `context.history.steps`; if found and `stepStartsSession(steps[i + 1], id:)`, `context.jumpHistory(to: i)` (the session's steps become redo steps, like undo). Otherwise (the first step was folded into the base by H-5) `performHistory` one **"Move Pixels"** step restoring `restore.layerSurface`, `restore.selection`, and `floatingPixels = nil`. Either way, pixels and selection equal their pre-session values exactly. (A "Select All" step recorded just before the session stays: it precedes `baseStepID`.)
   - **`prepareForHistoryNavigation(context:)`** (item 8): during a drag → `cancel` (drag only); otherwise nothing. Floating state already lives in history, so undo/redo/jump/save never add "Finish Pixels".
   - **`mouseMoved`/`cursor(at:modifiers:)`:** as 0019: hover gesture → `.move`, `.rotate`, `.resize(h)`; during a drag → the drag's gesture cursor; `nil` location → `.arrow`; no session → `.move`.
   - **`activate`:** store the context, idle overlay. **`deactivate`:** the 0006 default (commits → "Finish Pixels" if floating), then `setOverlay(nil)`.

7. **`Core/Tools/ToolContext.swift`** (extend): `var floatingPixels: FloatingPixels? { get }`, `var history: HistoryStack { get }`, `func jumpHistory(to index: Int)`. `CanvasToolSession` → `undoBridge.state.floatingPixels`, `undoBridge.history`, `undoBridge.jump(to:)`; `FakeToolContext` → its `state`, `history`, `history.jump(to:&state)`.

8. **`Core/Tools/Tool.swift` + `ToolDispatcher`** (extend 0006):
   - `func prepareForHistoryNavigation(context: any ToolContext)` with default `if hasPendingEdit { commit(context:) }` (every existing tool behaves as before).
   - `public enum PendingEditReason: Sendable { case command, historyNavigation, save }`; `ToolDispatcher.resolvePendingEdit(for:)`: `.command` → `commitPendingEdit()`; `.historyNavigation`/`.save` → `activeTool.prepareForHistoryNavigation(context:)` when a context exists; then 0006's pending-edit mirroring.
   - `ToolDispatcher.refreshPendingState()` — re-runs the mirroring and fires `onStateChange` on change (undo can create or clear floating pixels without a tool event).

9. **Finish before commands, not before navigation:**
   - `UndoBridge` (extend 0008): `@ObservationIgnored public private(set) var pendingEditReason: PendingEditReason = .command`. `performUndo`/`performRedo`/`jump` set `.historyNavigation` around their `prepareForNavigation` call; new `func prepareForSave()` sets `.save` and calls the hook; the value resets to `.command` afterwards. Every other caller (0013's Edit commands and every later command that calls `undoBridge.prepareForNavigation?()` first) gets `.command`.
   - `DocumentWindowController`'s `prepareForNavigation` closure (0008) becomes `dispatcher.resolvePendingEdit(for: undoBridge.pendingEditReason)` (same active-session guard). `PaintDocument`'s save override (0008) calls `undoBridge.prepareForSave()`.
   - Result: Select All, Deselect, Invert Selection, and every later command (Erase/Fill Selection, Crop, Paste, layer operations, adjustments, effects) record **"Finish Pixels" first** and then their own step (Paint.NET drops on selection change); undo, redo, History-panel jumps, and save keep the pixels floating (save writes the layer, which already shows them).

10. **`Core/Tools/FloatingPixelsPolicy.swift`** (new): `static func toolToActivate(hasFloatingPixels: Bool, activeTool: ToolID) -> ToolID?` → `.moveSelectedPixels` when there are floating pixels and another tool is active; else `nil`. Used after undo/redo/jump (undoing "Finish Pixels" with the Paintbrush active brings back the floating pixels **and** Move Selected Pixels) and by 0021 after Paste.

### Platform glue (AppKit; UI tests + manual checks)

11. **`Document/DocumentWindowController.swift`** (extend): after every `onStateChange`, when this window's session is active: `dispatcher.refreshPendingState()`; `if let id = FloatingPixelsPolicy.toolToActivate(hasFloatingPixels: state.floatingPixels != nil, activeTool: dispatcher.activeToolID) { dispatcher.selectTool(id) }`; if Move Selected Pixels is active, ask it to refresh its idle overlay (via `dispatcher.optionsDidChange()`-style hook: the tool's `activate`-time overlay logic is re-run from a `refreshOverlay(context:)` method the tool exposes; keep it internal to the tool file).
12. **`Canvas/TransformHandlesOverlay.swift`** (created by 0019; extend): no drawing change. Add accessibility to `ToolOverlayView`: while the overlay is `.transformHandles`, it exposes a child element `canvas.transformHandles` whose value is the integer bounding box of `corners` as `"x,y,w,h"` (floor of min, ceil of max), for UI tests. (0019 adds no such element; this spec creates it.)
13. **Registry / Tools panel:** `ToolRegistry.standard()` registers `.moveSelectedPixels → MoveSelectedPixelsTool()`; the Move section shows both tools; M → Move Selected Pixels, M M and Shift+M → Move Selection (0019 notes this needs no other change). **0019 tests this spec updates** (they assumed M = Move Selection): in `PaintDotMacUITests/MoveSelectionUITests.swift`, `testMKeySelectsMoveSelection` (first key press becomes Shift+M; renamed `testShiftMSelectsMoveSelection`), `testDragMovesSelectionAndUndoes` and `testArrowKeysNudgeAndPaintingFollows` (their opening `M` becomes Shift+M); in `PaintDotMacTests/Tools/ToolRegistryTests.swift`, `moveGroupHasMoveSelection` is replaced by `moveGroupOrder` (below). `MoveSelectionIntegrationTests` and `MoveSelectionToolTests` drive the tool directly and need no change.
14. `project.yml`: no target changes; run `xcodegen generate`. No PRD.md change in this spec (sub-agent rule); see Open questions.

### Performance (NF-1, NF-4)
- Each drag event re-renders only `lastRegion ∪ newBounds` and the canvas uploads only those tiles (0003's `changedTiles(since:)`). Target: re-rendering a 1024 × 1024 floating region rotated 30° (bilinear) < 150 ms per event in the Debug test build, gated at 3× (450 ms); an integer move (nearest) of the same region < 60 ms, gated at 180 ms.
- NF-4: a lift step costs the changed layer tiles (before + after) plus the source tiles; later steps the changed layer tiles; "Finish Pixels" 256 B. `underlay`, `restore.layerSurface`, and history "before" tiles share storage (CoW).

## Acceptance criteria
- [ ] `Resampler.mode(for:)` follows D-21. → `ResamplerTests.modeSelectionTable`
- [ ] Nearest-neighbor is exact for integer translations, 2× scale (pixel replication), and flips. → `ResamplerTests.nearestTranslate`, `.nearestScale2x`, `.nearestFlip`
- [ ] 90°, 180°, 270° rotations about the box centre give exactly the rotated pixels (4×4 and 3×1). → `ResamplerTests.rotate90Exact`, `.rotate180Exact`, `.rotate270Exact`, `.rotate90OddLength`, `MoveSelectedPixelsToolTests.shiftRightDragRotates90Exactly`
- [ ] Bilinear premultiplies, treats outside as transparent, rounds half up, and never bleeds colour from alpha-0 pixels. → `ResamplerTests.bilinearScale2xEdges`, `.bilinearHalfPixelRotation`, `.bilinearIgnoresColorUnderZeroAlpha`, `.resampleMatchesPerPixelSample`
- [ ] Lifting leaves a transparent hole (coverage-weighted on antialiased edges); lifted pixels carry the coverage; ⌘-drag leaves the original untouched. → `FloatingPixelsTests.liftPunchesHole`, `.liftAntialiasedEdges`, `.duplicateKeepsOriginal`, `MoveSelectedPixelsToolTests.commandDragDuplicates`
- [ ] Moving and moving back restores the layer exactly; off-canvas pixels survive while floating. → `FloatingPixelsTests.moveAndBackIsIdentity`, `.offCanvasPixelsSurvive`
- [ ] The selection outline moves with the pixels; with no selection, "Select All" is recorded and the whole layer moves. → `FloatingPixelsTests.selectionFollowsPixels`, `MoveSelectedPixelsToolTests.noSelectionSelectsAllFirst`
- [ ] Each drag/nudge is one "Move Pixels" / "Scale Pixels" / "Rotate Pixels" step; Return, Finish, tool switch, document switch, and commands add "Finish Pixels" (commands before their own step); undo/redo/jump/save never finish. → `MoveSelectedPixelsToolTests.*`, `MoveSelectedPixelsIntegrationTests.*`, `UndoBridgeTests.pendingEditReason`, `ToolDispatcherTests.resolvePendingEditByReason`
- [ ] Undo walks back through the floating steps; undoing "Finish Pixels" restores the floating state and the tool. → `MoveSelectedPixelsIntegrationTests.undoRedoThroughSession`, `FloatingPixelsPolicyTests.table`, `MoveSelectedPixelsUITests.testUndoFinishRestoresFloating`
- [ ] Escape restores the pre-session pixels and selection exactly (history jump, or a restoring step after budget folding). → `MoveSelectedPixelsIntegrationTests.escapeCancelsExactly`, `.escapeAfterBudgetFold`
- [ ] Scale nubs keep integer edges while unrotated, so integer scales use nearest-neighbor. → `MoveSelectedPixelsToolTests.scaleSnapsToWholePixels`, `.cornerDrag2xIsPixelReplication`
- [ ] M selects Move Selected Pixels; M M / Shift+M select Move Selection; 0019's M-key tests are updated to Shift+M and still pass. → `ToolRegistryTests.moveGroupOrder` (replaces 0019's `moveGroupHasMoveSelection`), UI `MoveSelectedPixelsUITests.testMKeyCycles`, `MoveSelectionUITests.testShiftMSelectsMoveSelection`
- [ ] The tool works in the app. → `MoveSelectedPixelsUITests.*`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases
- **Click without moving:** no lift, no pixel step (H-6); with no selection the "Select All" step stays (0019 parity). → `MoveSelectedPixelsToolTests.clickAddsNoPixelStep`
- **Transparent area lifted:** allowed; the step still moves the outline. → `FloatingPixelsTests.liftTransparentArea`
- **Moved wholly or partly off-canvas:** render clips to the canvas; `transformedSelection` is `nil` when nothing remains (ants hidden, handles still drawn from the floating session); Finish drops the off-canvas pixels. → `.offCanvasPixelsSurvive`, `.finishOffCanvasDropsPixels`
- **Tile boundaries:** writes only the touched tiles; diff candidates cover old and new regions. → `FloatingPixelsTests.crossTileMove`
- **Flip through the opposite nub / zero width:** 0019's session handles it; a zero-area box renders nothing (non-invertible → transparent) and records the outline as `nil`; continuing the drag flips. → `MoveSelectedPixelsToolTests.flipThroughOppositeNub`, `ResamplerTests.fullyTransparentResultIsClear`
- **1×1 image / 1×1 selection:** lift, move off and back, rotate 90° → exact. → `FloatingPixelsTests.onePixel`
- **Hidden layer / layer opacity:** the active layer's pixels move regardless of visibility; opacity is applied by the compositor, not by `render`. → `FloatingPixelsTests.hiddenLayerStillMoves`
- **Escape during a drag:** only that drag is undone; the session stays floating. → `MoveSelectedPixelsToolTests.escapeDuringDragCancelsOnlyDrag`
- **Escape with nothing floating:** not handled (`false`). → `.escapeWithoutFloatingNotHandled`
- **Undo during a drag:** Edit commands are ignored mid-gesture (0008/0013); `prepareForHistoryNavigation` cancels a drag if ever reached. → `.navigationCancelsDrag`
- **Document switch while floating:** 0006's `setContext` deactivates the tool in the old document → "Finish Pixels" there. → `.contextSwitchFinishesOldDocument`
- **Save while floating:** no Finish; the file contains the rendered layer; still floating afterwards. → `MoveSelectedPixelsIntegrationTests.saveKeepsFloating`
- **Auto-repeat arrows:** one step per event; H-5 folds old steps. → `MoveSelectedPixelsToolTests.nudgeSteps`

## Test plan

Expected values are hand-computed from the formulas above; never pasted from the code under test.

- **Unit — `PaintDotMacTests/Rendering/ResamplerTests.swift`** (transforms written as literal `CGAffineTransform(a:b:c:d:tx:ty:)`, independent of 0019):
  - `modeSelectionTable`: identity → nearest; translate (3, −2) → nearest; scale 2 → nearest; (a −1, tx 4) → nearest; scale 2 + tx 0.5 → bilinear; scale 0.5 → bilinear; scale 1.5 → bilinear; (a 0, b 1, c −1, d 0) → bilinear; a = 2 + 1e-10 → nearest; b = 1e-12 with integer rest → nearest.
  - `nearestTranslate`: 3×2 source, 6 distinct opaque colours, origin (0,0), translate (3, −2), destination (3, −2, 3, 2) → identical bytes; destination (2, −2, 1, 2) → all `(0,0,0,0)`.
  - `nearestScale2x`: 2×2 `[A B; C D]` at (10, 10), `(a 2, d 2, tx −10, ty −10)`, destination (10, 10, 4, 4) → rows `A A B B / A A B B / C C D D / C C D D`.
  - `nearestFlip`: 3×1 `[A B C]` at (0,0), `(a −1, tx 3)` → `[C B A]`.
  - `rotate90Exact`: 4×4, 16 distinct opaque colours `s(i, j)` at (0,0); `(a 0, b 1, c −1, d 0, tx 4, ty 0)` (+90° about (2,2)); mode bilinear; destination (0,0,4,4) → `dest(x, y) == s(y, 3 − x)` for all 16; the 1-px ring of `destinationBounds` around it is all `(0,0,0,0)`. Repeat with the same matrix computed via `CGAffineTransform(rotationAngle: .pi/2)` about (2,2) (entries off by ~1e-16) → same bytes (snapping).
  - `rotate180Exact`: `(a −1, d −1, tx 4, ty 4)` → `dest(x, y) == s(3 − x, 3 − y)`. `rotate270Exact`: `(a 0, b −1, c 1, d 0, tx 0, ty 4)` → `dest(x, y) == s(3 − y, x)`.
  - `rotate90OddLength`: 3×1 `[A B C]` at (5, 5), +90° about (6.5, 5.5) = `(a 0, b 1, c −1, d 0, tx 12, ty −1)` → (6, 4) = A, (6, 5) = B, (6, 6) = C; every other pixel of `destinationBounds` transparent.
  - `bilinearScale2xEdges`: 2×1 `[black (0,0,0,255), white (255,255,255,255)]` at (0,0), `(a 2, d 2)` forced `.bilinear`, destination (−1, −1, 6, 4). Expected (alpha, gray) for rows y = 0 and y = 1: x = −1 → (48, 0); 0 → (143, 0); 1 → (191, 64); 2 → (191, 191); 3 → (143, 255); 4 → (48, 255). Row y = −1, x = 1 → (64, 64). (Comment: per-axis weights 0.75/0.25, transparent outside, alpha `Int(A + 0.5)`, colour `Int(P/A + 0.5)`.)
  - `bilinearHalfPixelRotation`: 2×1 opaque red at (0,0), +90° about (1, 0.5) = `(a 0, b 1, c −1, d 0, tx 1.5, ty −0.5)`; dest (0, 0) → `(255, 0, 0, 128)` (four samples × 0.25, two outside).
  - `bilinearIgnoresColorUnderZeroAlpha`: 2×1 `[(255,0,0,255), (0,0,255,0)]`, `sample(at: (1.0, 0.5))` → `(255, 0, 0, 128)` (a straight average would be `(128, 0, 128, 128)`).
  - `fullyTransparentResultIsClear`: far outside → clear; non-invertible (a 0, d 0) → all clear.
  - `resampleMatchesPerPixelSample` (property, `SeededRandom`, 50 cases, seed printed): random source ≤ 300×300 crossing tiles, random affine (rotation, scale 0.3–3, translation) → `resample` bytes == per-pixel `sample` for every destination pixel.
  - `destinationBoundsCoverSupport`: for the same random cases, every non-clear sample lies inside `destinationBounds`.
- **Unit — `PaintDotMacTests/Model/FloatingPixelsTests.swift`** (8×8 opaque layer `L(x, y) = (x·30, y·30, 100, 255)`, rect selection (2, 2, 3, 3) unless stated; sessions moved with 0019's `translatedBy`/`applying`):
  - `liftPunchesHole`: source == `L` over the rect; underlay rect pixels `(0,0,0,0)`, outside unchanged with shared tile storage; `outline == selection`; `session.integerTranslation == (0, 0)`.
  - `liftAntialiasedEdges`: `Selection(mask:outline:)` with coverage 128 at (2, 2), 255 at (3, 2): source alpha at (2, 2) = `mul255(255, 128)` = 128, underlay alpha = `mul255(255, 127)` = 127, colours unchanged; (3, 2): source 255, underlay `(0,0,0,0)`.
  - `liftWithoutSelectionReturnsNil`; `duplicateKeepsOriginal` (underlay == layer, shared storage).
  - `renderIdentityMatchesOriginalForHardSelection`: identity session, `render` → exactly `L`.
  - `moveAndBackIsIdentity`: `translatedBy(4, 0)`, render region = old ∪ new → columns 6–7 rows 2–4 == `L(2…3, 2…4)`, (2…4, 2…4) clear except where covered, others unchanged; back by (−4, 0), render → byte-identical to `L`.
  - `offCanvasPixelsSurvive` (+20, 0 then back), `finishOffCanvasDropsPixels` (render at +20, take the layer → only the hole).
  - `selectionFollowsPixels`: translate (+1, +2) → `transformedSelection(antialiased: true) == Selection(rect: (3, 4, 3, 3))` (integer path of 0019 → mask shift, exact).
  - `liftTransparentArea`, `crossTileMove` (300×300 layer, selection (250, 250, 20, 20) moved (+10, +10): changed tiles ⊆ the 4 tiles around (256, 256); pixels exact), `onePixel`, `hiddenLayerStillMoves`.
  - `pasteFactory`: 3×3 surface at (−1, −1) → `sourceRect (−1,−1,3,3)`, underlay == layer, `outline == Selection(rect: (0,0,2,2))`; identity render writes the visible 2×2 part (opaque → exact).
- **Unit — `PaintDotMacTests/History/FloatingPixelsHistoryItemTests.swift`:** `applyRevert`; `noOpWhenEqual`; `changeIsSelection`; `byteCostLiftVsLater` (lift of a 3×3 rect in one tile: source 1 tile + 1 holed underlay tile → 524,288; later 256); `stepComposition` (`step(named: "Rotate Pixels", …)`: name, icon, merged change `.pixelsAndSelection` with the touched tiles); `gestureNames` (translate/scale/rotate → "Move Pixels"/"Scale Pixels"/"Rotate Pixels"); `stepStartsSession`.
- **Unit — `PaintDotMacTests/Tools/MoveSelectedPixelsToolTests.swift`** (`FakeToolContext`, 8×8 layer `L`, rect selection (2, 2, 3, 3), base "New Image", `canvasToView` identity so view points = canvas points):
  - `dragRecordsOneStep`: down (3, 3), drag (5, 3), (7, 3), up → steps `["New Image", "Move Pixels"]`, pixels as `moveAndBackIsIdentity` at +4, `state.selection == Selection(rect: (6, 2, 2, 3))` (clipped to the canvas), `floatingPixels != nil`, `hasPendingEdit`.
  - `secondDragAddsStep`; `clickAddsNoPixelStep`; `returnFinishes` (last step "Finish Pixels", `floatingPixels == nil`, layer and selection unchanged by the finish); `commitFinishes`; `deactivateFinishes`; `contextSwitchFinishesOldDocument` (two fake contexts through `ToolDispatcher.setContext`).
  - `noSelectionSelectsAllFirst`: selection nil, drag inside → steps `["New Image", "Select All", "Move Pixels"]`; column 0 clear after +1 move; selection == canvas rect moved (+1, 0) clipped.
  - `commandDragDuplicates`: ⌘ at the first mouse-down → original rect unchanged and a copy at +4; a second ⌘-drag leaves a second copy.
  - `shiftRightDragRotates90Exactly`: 4×4 selection (2, 2, 4, 4); secondary button from (8, 4) to (4, 8) with Shift (centre (4, 4)) → one "Rotate Pixels" step; layer rect pixels == `L` rotated with `dest(x, y) = L(2 + (y − 2), 2 + (3 − (x − 2)))`; outside the rect unchanged.
  - `scaleSnapsToWholePixels`: right nub at (5, 3.5) dragged to (6.4, 3.5) → box maxX 6 exactly; `floatingPixels.resamplingMode == .nearestNeighbor` only when the scale is integral (here 4/3 → bilinear).
  - `cornerDrag2xIsPixelReplication`: selection (2, 2, 2, 2), bottom-right nub (4, 4) → (6.2, 5.8) → box (2, 2)–(6, 6), mode nearest, pixels = each source pixel as a 2×2 block.
  - `flipThroughOppositeNub`: right nub (5, 3.5) → (−1, 3.5) → box x from 2 to −1 (scale −1, affine `x' = 4 − x`), mode nearest; rows 2–4: dest column 1 = `L(2, y)`, column 0 = `L(3, y)` (source column 4 lands at −1, off-canvas, kept while floating); columns 2–4 clear.
  - `nudgeSteps`: → +1 px, ⌘→ +10 px (off-canvas, pixels kept), `isRepeat` also a step; each named "Move Pixels"; nudges ignored mid-drag.
  - `escapeDuringDragCancelsOnlyDrag`, `escapeWithoutFloatingNotHandled`, `navigationCancelsDrag` (`prepareForHistoryNavigation` mid-drag: pre-drag pixels, no step), `navigationKeepsFloating` (no step, still floating), `cursorRoles` (hover inside → `.move`, nub → `.resize(h)`, corridor → `.rotate`, nil → `.arrow`).
- **Unit — `PaintDotMacTests/Tools/FloatingPixelsPolicyTests.swift`:** `table` over hasFloating × all 19 tool IDs.
- **Unit — `PaintDotMacTests/Tools/ToolDispatcherTests.swift`** (extend): `resolvePendingEditByReason` (`StubTool` with `hasPendingEdit`: `.command` → `"commit"`; `.historyNavigation`/`.save` → `"prepareForHistoryNavigation"` then the default's `"commit"`); `refreshPendingStateFiresOnChange`. **`ToolRegistryTests.moveGroupOrder`:** group `[.moveSelectedPixels, .moveSelection]`; M → Move Selected Pixels; M M within 1 s and Shift+M → Move Selection.
- **Unit — `PaintDotMacTests/History/UndoBridgeTests.swift`** (extend): `pendingEditReason` — the hook sees `.historyNavigation` during `undo`, `redo`, and once for a 3-step `jump`; `.save` during `prepareForSave()`; `.command` when called directly; `.command` again afterwards.
- **Integration — `PaintDotMacTests/Integration/MoveSelectedPixelsIntegrationTests.swift`** (`UndoBridge` + `ToolDispatcher` + the real tool via a `FakeToolContext` backed by the bridge):
  - `undoRedoThroughSession`: move (+2, 0), move (0, +3), Shift-rotate 90°, Return → steps `["New Image", "Move Pixels", "Move Pixels", "Rotate Pixels", "Finish Pixels"]`. Undo → floating again (`session.angle == 90`), pixels unchanged; undo → unrotated; undo → first move only; undo → original pixels and selection, `floatingPixels == nil`; redo ×4 → byte-identical to each recorded state.
  - `commandFinishesFirst`: after a move, the Deselect path (`prepareForNavigation` with reason `.command`, then `SelectionCommand.deselect`) → steps end `"Finish Pixels", "Deselect"`.
  - `escapeCancelsExactly`: two moves + rotation, Escape → `currentIndex == 0`, layer == original bytes, selection == original, `floatingPixels == nil`, three redo steps remain.
  - `escapeAfterBudgetFold`: tiny budget so the first step folds into the base; Escape → a new "Move Pixels" step; layer and selection == pre-session values.
  - `saveKeepsFloating`: `prepareForSave()` while floating → no step, still floating; 0005's PNG encoding of the image decodes to the rendered layer.
  - `randomSessionsUndoRedoIdentity` (property, `SeededRandom`, 100 sessions on 600×400: random selections, moves, nudges, rotations, scales, ⌘-duplicates, finishes, Escapes) → undo-all then redo-all reproduces identical tiles, `==` selections, and `==` floating states at every step.
- **UI tests — `PaintDotMacUITests/MoveSelectedPixelsUITests.swift`** (fixture from `UITestFixtures.writePNG`: 200×200 opaque white, red square (0, 0, 50, 50); launch with `-UITestSelectRect 0,0,50,50`; drags with `dragOnCanvas(from:to:)`; pixel checks by ⌘S to the temp fixture and decoding it with ImageIO):
  - `testDragMovesPixelsAndFinish`: `m` → `tool.moveSelectedPixels` selected and `canvas.transformHandles` = `"0,0,50,50"`; drag (0.125, 0.125) → (0.625, 0.125) → History row "Move Pixels"; Return → "Finish Pixels"; ⌘S → (10, 10) has alpha 0, (110, 10) red, the red run on row 10 starts at x = 100 ± 1.
  - `testCommandDragCopies`: ⌘-drag, Return, ⌘S → (10, 10) and (110, 10) red.
  - `testToolSwitchFinishes`: drag, `b` → last row "Finish Pixels".
  - `testDeselectFinishesFirst`: drag, ⌘D → last rows "Finish Pixels", "Deselect".
  - `testEscapeCancels`: drag, Escape → Edit menu "Redo Move Pixels" enabled, Undo disabled; ⌘S → (10, 10) red, (110, 10) white.
  - `testUndoFinishRestoresFloating`: drag, `b`, ⌘Z → `tool.moveSelectedPixels` selected again and `canvas.transformHandles` present; ⌘Z → back to the fixture (Undo disabled).
  - `testMKeyCycles`: `m` → Move Selected Pixels; `m` again → Move Selection; Shift+M → Move Selection.
- **Performance — `PaintDotMacTests/Performance/MoveSelectedPixelsPerformanceTests.swift`** (XCTest `measure`): the two re-render cases from *Performance*; report numbers in Verification status.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green (no warnings, nothing skipped, UI tests ran, launch smoke).
- **Manual verification:**
  1. At 100 %, 400 %, and fit zoom on Retina: nubs and frame look right and keep a constant on-screen size; the hole shows the checkerboard.
  2. Cursors: four-way arrow inside, resize on nubs, rotate in the corridor and while right-dragging.
  3. Rotating a 1000 × 1000 photo selection by dragging feels smooth; edges are antialiased; Shift-rotation by 90° is pixel-sharp; a 2× nub drag stays pixel-sharp.
  4. The live outline follows the pixels while dragging and marching ants resume at the new place on release; works in dark mode.

## Open questions
Decided as stated so the spec is implementable; please confirm and record in PRD.md §5.3/§12. (Settled, not questions: the step names "Move Pixels" / "Scale Pixels" / "Rotate Pixels" / "Finish Pixels" follow the batch rule that history names use Paint.NET's spelling; ⌘-drag duplicates because PRD §5.12 maps Ctrl → ⌘; no resampling/gamma toolbar option because D-21 fixes the resampling.)
1. **Escape cancels the whole floating session exactly** (an undo-like jump; steps stay redoable). Paint.NET's keyboard table lists Esc as committing tool drawings; 0006's default asks for cancel. Recommended: cancel (Return/Finish commit).
2. **The layer always shows the transformed pixels** (as Paint.NET 3.36 draws into the layer); `floatingPixels` keeps the source for re-transforming. Save, sampling, and thumbnails see the moved pixels; save doesn't finish. Recommended: yes.
3. **Undo/redo/jump/save never finish; every other command finishes first** (a "Finish Pixels" step before the command's own step); undoing into a floating state re-selects Move Selected Pixels. Recommended: yes.
4. **Scale nubs snap to whole pixels while unrotated** (keeps D-21's nearest path reachable and edges sharp). Recommended: yes.

## Out of scope
- The shared handle geometry, outline-only moves, and their tests → **0019** (reused unchanged).
- Cut/Copy/Paste; paste creates `FloatingPixels.paste(...)` and records "Paste" → **0021**.
- Bicubic and supersampling, Resize Image → **0035** (adds `ResamplingMode` cases and kernels).
- Paint.NET's resampling dropdown, Gamma split button, draggable rotation pivot, status-bar angle readout.
- Finishing when the active layer changes in the Layers panel → **0025** must call `undoBridge.prepareForNavigation?()` (reason `.command`) before switching layers.
- Layer Flip/Rotate/Zoom → **0060**; image rotation → **0037**.
