# 0018 — Add Edit > Erase Selection (⌫ / ⌦) and Fill Selection (⌥⌫)

> Source: PRD.md §5.6 E-4 ("Erase Selection (⌫ Delete or ⌦ Forward Delete), Fill Selection with the primary color (⌥⌫ or menu)"); §5.12 row "Erase Selection / Fill Selection — Delete / Backspace → ⌫ or ⌦ / ⌥⌫" and D-12; §5.7 H-1, H-6 / D-34 (no-op edits add no step); §5.3 TOOL-B and D-40 (empty selection = no selection); NF-9 (straight 8-bit RGBA); NF-1, NF-4; D-27 (a fully erased pixel is transparent black); AGENTS.md architecture rules 1–4, 8, 9.
> Paint.NET docs (fetched 2026-11-05): Edit menu — https://www.getpaint.net/doc/latest/EditMenu.html (redirects to https://www.paint.net/doc/latest/EditMenu.html).
> Milestone: M2
> Depends on: 0013-selection-core-and-marching-ants (and therefore 0001–0012; 0014–0017 are lower-numbered and built first but not required)

## Context
Not yet implemented. After 0001–0017:
- `DocumentState` (`Core/Model/DocumentState.swift`, 0008 + 0013) holds `image: LayeredImage` and `selection: Selection?` (`nil` = no selection; a `Selection` is never empty, D-40).
- `Selection.mask: SelectionMask` (0013, `Core/Model/SelectionMask.swift`) is the normative 8-bit antialiased coverage, on the same 256×256 grid as `TiledSurface`, with per-tile `SelectionMaskTile` `.empty` / `.full` / `.partial(SelectionMaskTileStorage)` and `tile(at:)`, `coverage(x:y:)`, `bounds`. Edge-tile bytes outside the canvas are always 0.
- History (0008, 0013): `TileDiff.between(before:after:layerID:candidates:)`, `TileDiffHistoryItem(name:icon:diff:)`, `SelectionHistoryItem(name:icon:before:after:)`, `CompositeHistoryItem(name:icon:items:)`, `HistoryChange.pixelsAndSelection`. `HistoryIcon` already has `.eraseSelection` and `.fillSelection` (0008), with SF Symbols `delete.left` / `square.fill` (0010, `HistoryIcon+Symbol.swift`).
- `TiledSurface` (0002): `tile(at:)`, `setTile(_:at:)` (stamps generation), `pixelRect(of:)`, `fill(_:in:)` (shares one tile for fully covered interior tiles; edge tiles keep out-of-canvas pixels zero), `releaseTransparentTiles()`, `Tile(filledWith:)`, `Tile.isFullyTransparent`, `sharesStorage(with:)`.
- Per-pixel math (0009/0011): `BlendOps.mul255(a, b) = (a·b + 127) / 255`; `EraseOps.erase(_:strength:coverage:)` (`Core/Tools/EraseOps.swift`): `newA = (a·(65025 − s·c) + 32512) / 65025`, `newA == 0 → (0,0,0,0)`, RGB untouched otherwise.
- `SelectionCommand` (`Core/Operations/SelectionCommands.swift`, 0013) and the responder-chain actions `selectAll(_:)`, `deselect(_:)`, `invertSelection(_:)` in `Document/DocumentWindowController.swift` (0013): ignored while `AppModel.dispatcher.isGestureInProgress`, call `undoBridge.prepareForNavigation?()` first, then `undoBridge.perform(item)`; validated with `validateMenuItem`.
- `App/MainMenu.swift` Edit menu (0001 + 0013): … Select All ⌘A, Deselect ⌘D, Invert Selection ⌘I. 0013 reserves the slot for this spec "between Deselect and Invert Selection".
- Single-key shortcuts go through 0006's local key monitor `CanvasInputRouter.handleShortcutKeyDown(_:model:)` and `ToolShortcutGate.allows(modifiers:keyWindow:textInputHasFocus:toolCapturesKeyboard:gestureInProgress:)` (`Core/Tools/ToolRegistry.swift`), which rejects ⌘/⌥/⌃, text focus, `.other` key windows (sheets, dialogs), keyboard-capturing tools (Text, 0040), and gestures.
- Primary color: `AppModel.colors.primary` (0007, `ColorSelection`).

**Paint.NET behavior mirrored** (EditMenu.html, quoted):
- "**Erase Selection** (Delete): This command erases the currently selected region of the active layer. All pixels that lie within the selected region are replaced with transparent black pixels … The selection outline is removed following the completion of the action (i.e. the selection is deselected)."
- "**Fill Selection** (Backspace): If there is a selection active, this command will fill it with the current Primary color. The current selection remains active following the Fill operation."
- Note on the same page: "editing operations are clipped at the edge of the selection" (antialiased edges are partially affected).
- Paint.NET's Edit menu order is … Erase Selection, Fill Selection, Invert Selection, Select All, Deselect. PaintDotMac keeps 0013's order (Select All, Deselect, Invert Selection) and inserts the two items between Deselect and Invert Selection, as 0013 planned.

**Erase deselects, Fill keeps the selection** (Paint.NET doc, quoted above; 0013's note was corrected to match). 0013 needs no code change: Erase records a `CompositeHistoryItem` of its pixel diff and a `SelectionHistoryItem(before: selection, after: nil)`, which 0013's types already support.

## User story
As a PaintDotMac user, I select part of the image and press ⌫ (or ⌦) to erase it to transparency, after which the selection is gone, or ⌥⌫ to fill it with my primary color, after which the selection stays. Antialiased selection edges are erased or filled partially, so edges stay smooth. Both are also in the Edit menu, each is one History step ("Erase Selection", "Fill Selection") that ⌘Z undoes and ⇧⌘Z redoes, and pressing ⌫ while typing in a text field edits the text instead.

## Scope & changes

### Core (pure Swift, headless, unit-tested; no AppKit/SwiftUI imports)

1. **`Core/Operations/EraseSelection.swift`** (new)
   ```swift
   public enum EraseSelection {
       public static let name = "Erase Selection"            // menu title and history step (Paint.NET spelling)
       public static let icon = HistoryIcon.eraseSelection

       /// One pixel; coverage = selection mask value 0…255. Exactly EraseOps.erase(p, strength: 255, coverage: coverage).
       public static func erasePixel(_ p: ColorRGBA8, coverage: UInt8) -> ColorRGBA8
       /// Returns the erased surface and the tiles it touched. mask nil = the whole surface (no selection).
       public static func erase(_ surface: TiledSurface, mask: SelectionMask?) -> (surface: TiledSurface, touched: Set<TileCoordinate>)
       /// Always true for an open document (see "No selection" below).
       public static func isEnabled(in state: DocumentState) -> Bool
       /// nil when nothing would change (H-6).
       public static func makeHistoryItem(for state: DocumentState) -> (any HistoryItem)?
   }
   ```
   **Pixel math (normative).** With `m` = mask coverage at the pixel:
   ```
   m == 0          → p unchanged
   newA = (p.a × (255 − m) + 127) / 255             // = BlendOps.mul255(p.a, 255 − m), round-half-up of a·(1 − m/255)
   newA == 0       → (0, 0, 0, 0)                   // transparent black (Paint.NET doc; D-27; 0011 EraseOps)
   otherwise       → (p.r, p.g, p.b, newA)          // straight alpha: color channels untouched
   ```
   This is identical to `EraseOps.erase(p, strength: 255, coverage: m)` for every input (65025·newA rounding: `(255x + 32512)/65025` and `(x + 127)/255` floor to the same integer for every integer `x = a·(255−m)`, because no integer lies in `(127, 127.498]`). Implement `erasePixel` by calling `EraseOps.erase` so there is one erase rule in the app; the test proves the closed form above for all 65,536 `(a, m)` pairs. Consequences: `m == 255` → always `(0,0,0,0)`; alpha never increases; a pixel that is already `(0,0,0,0)` stays so.

   **Tile algorithm** (per tile coordinate of the grid; `mask == nil` behaves as every tile `.full`):
   - mask tile `.empty`, or surface tile unallocated (`nil`) → skip (unallocated = all `(0,0,0,0)`, which erasing leaves unchanged).
   - mask tile `.full` → `setTile(nil, at:)` (O(1), no pixel loop).
   - mask tile `.partial(storage)` → copy the surface tile, apply `erasePixel` to each in-canvas pixel whose mask byte is non-zero (a tight loop over the tile's bytes and the mask's `[UInt8]`), then store `nil` if the result `isFullyTransparent`, else the new tile.
   - Every tile actually replaced goes into `touched` (used as the `TileDiff` candidates). Partial tiles may be computed concurrently (`DispatchQueue.concurrentPerform` over the list of partial coordinates, each producing an independent `Tile?`), then written serially with `setTile`. Results are per-pixel independent, so they are bit-identical to the serial loop.

   **History item.** Active layer = `state.image.layers[state.image.activeLayerIndex]`.
   `diff = TileDiff.between(before: layer.surface, after: erased, layerID: layer.id, candidates: touched)`;
   `pixels = TileDiffHistoryItem(name: name, icon: icon, diff: diff)`;
   `deselect = SelectionHistoryItem(name: name, icon: icon, before: state.selection, after: nil)`;
   result = `CompositeHistoryItem(name: name, icon: icon, items: [pixels, deselect])`, or `nil` if `result.isNoOp` (no pixel changed **and** there was no selection). So erasing an already-transparent area while a selection exists still records one "Erase Selection" step that only deselects (something changed, H-6); with no selection and an empty layer there is no step. Undo restores both pixels and selection in one step; `change` is `.pixelsAndSelection(tiles)` (or `.selection` / `.pixels` per 0013's `merged` table).

2. **`Core/Operations/FillSelection.swift`** (new)
   ```swift
   public enum FillSelection {
       public static let name = "Fill Selection"
       public static let icon = HistoryIcon.fillSelection

       /// Overwrite p with color, weighted by coverage (see below).
       public static func fillPixel(_ p: ColorRGBA8, color: ColorRGBA8, coverage: UInt8) -> ColorRGBA8
       public static func fill(_ surface: TiledSurface, color: ColorRGBA8, mask: SelectionMask?) -> (surface: TiledSurface, touched: Set<TileCoordinate>)
       public static func isEnabled(in state: DocumentState) -> Bool        // always true for an open document
       public static func makeHistoryItem(for state: DocumentState, color: ColorRGBA8) -> (any HistoryItem)?
   }
   ```
   **Fill overwrites; it does not blend** (Open question 2 for confirmation). Where the mask is 255 the pixel becomes exactly the primary color, including its alpha, so a semi-transparent primary over an opaque pixel gives that semi-transparent color, not a composite. Paint.NET's doc says it fills the selection "with the current Primary color" (and Erase "replaces" pixels); Paint.NET 3.x's `FillSelectionFunction` cleared the clipped region to a constant color. That source detail is from memory and could not be re-checked online, hence the open question. On antialiased edges, the overwrite is weighted by the coverage: a premultiplied linear interpolation from `p` to `color` with weight `m/255`. That is the same rule as erase (erase = overwrite with `(0,0,0,0)`), and it is tested as such.

   **Pixel math (normative, integer):**
   ```
   m == 0          → p unchanged
   m == 255        → color.a == 0 ? (0,0,0,0) : color         // exact overwrite
   wD   = p.a × (255 − m)                                     // 0…65025
   wC   = color.a × m                                         // 0…65025
   sum  = wD + wC
   outA = (sum + 127) / 255
   outA == 0       → (0, 0, 0, 0)
   ch   = (p.ch × wD + color.ch × wC + sum / 2) / sum         // for ch in r, g, b; round-half-up; sum > 0 whenever outA > 0
   → (r, g, b, outA)
   ```
   (`Int` arithmetic; the largest intermediate is 255 × 65025 × 2 ≈ 33 M.) Properties tested: `color.a == 0` gives exactly `erasePixel(p, coverage: m)` for every `p` and `m` (the `wC = 0` branch reduces to `mul255(p.a, 255 − m)` with the channels unchanged); `color.a == 255` and `p` opaque gives `outA == 255`; `outA ≤ max(p.a, color.a)` and `≥ min(p.a, color.a)`.

   **Tile algorithm** (`mask == nil` = every tile `.full`):
   - mask tile `.empty` → skip.
   - mask tile `.full` → if `color.a == 0`, behave like erase (`setTile(nil)` when allocated, otherwise skip). Otherwise, for an interior tile, set **one shared** `Tile(filledWith: color)` created once per call (every full interior tile shares its storage until written, as 0002's `fill` does). For an edge tile (its `pixelRect(of:)` is narrower or shorter than 256), write a tile whose in-canvas pixels are `color` and whose out-of-canvas pixels stay 0 (0002 edge-tile invariant). Using `surface.fill(color, in: surface.pixelRect(of: coord))` is acceptable for edge tiles. A full tile that already equals the target (the shared tile, or bytes equal) is still written; `TileDiff.between` drops it as unchanged.
   - mask tile `.partial` → start from the surface tile (or `Tile()` if unallocated), apply `fillPixel` to each in-canvas pixel with a non-zero mask byte, and store `nil` if the result `isFullyTransparent`. This can happen only when `color.a == 0`, or when `p` was transparent and `outA` rounds to 0.
   - Same concurrency and `touched` rules as erase.

   **History item.** `TileDiffHistoryItem(name: "Fill Selection", icon: .fillSelection, diff:)` on the active layer. The selection is unchanged (no `SelectionHistoryItem`). `nil` when the diff is empty (H-6: filling an area that already has exactly that color records nothing).

3. **No selection = the whole active layer** (Open question 1 for confirmation). With `state.selection == nil`, both commands act on every pixel of the active layer (mask `nil` = all `.full`). This follows Paint.NET's model that "no selection" means everything is editable, which is also PaintDotMac's rule from 0013 (TOOL-B, D-40: `paintClipMask == nil` paints everywhere). So both menu items are **enabled whenever a document is open**. ⌫ with nothing selected clears the active layer (one undoable step "Erase Selection"), and ⌥⌫ fills it with the primary color. The EditMenu.html wording ("If there is a selection active") does not state the no-selection result, so this needs the user's confirmation.

4. **Shortcut resolution (pure)**: in `Core/Operations/EraseSelection.swift`, next to the command:
   ```swift
   public enum SelectionPixelCommand: CaseIterable, Sendable {
       case eraseSelection, fillSelection
       /// Mac virtual key codes: 51 = Delete (⌫, kVK_Delete), 117 = Forward Delete (⌦, kVK_ForwardDelete).
       /// ⌫ or ⌦ with no modifiers (Shift ignored = rejected, see below) → .eraseSelection; ⌥⌫ → .fillSelection;
       /// anything else (⌥⌦, ⌘⌫, ⌃⌫, ⇧⌫, other keys) → nil.
       public static func command(forKeyCode keyCode: UInt16, modifiers: ToolModifiers) -> SelectionPixelCommand?
   }
   ```
   - Key codes are used instead of characters because ⌫ delivers `"\u{7F}"` and ⌦ delivers `"\u{F728}"`, and ⌥ can change characters. Keyboard layouts don't move these keys.
   - ⇧⌫ returns `nil`. Paint.NET maps Shift+Backspace to "fill with the secondary color", which is not in PRD E-4 (Out of scope), so the key is left unhandled rather than silently erasing.
   - ⌘⌫ stays free for 0024's Delete Layer (⇧⌘⌫), and ⌘⌫ itself is unassigned.

5. **No Core changes elsewhere.** `EraseOps`, `SelectionMask`, history types, and `HistoryIcon` are reused unchanged.

### Platform glue (AppKit; covered by UI tests and manual checks)

6. **`App/MainMenu.swift`** (extend 0001/0013): Edit menu, after **Deselect** and before **Invert Selection**, add:
   - **Erase Selection**: `keyEquivalent = "\u{8}"` (`NSBackspaceCharacter`, shown as ⌫ and matched by the Delete key), no modifiers, action `eraseSelection(_:)`, target nil, identifier `menu.edit.eraseSelection`.
   - **Fill Selection**: `keyEquivalent = "\u{8}"`, modifiers `.option` (shown as ⌥⌫), action `fillSelection(_:)`, target nil, identifier `menu.edit.fillSelection`.
   - Update 0001's/0013's `MainMenuTests` expected Edit-menu table with the two rows. A menu item can have only one key equivalent, so ⌦ is handled by the key monitor (item 8) only; the menu shows ⌫.

7. **`Document/DocumentWindowController.swift`** (extend 0013):
   - `@objc func eraseSelection(_ sender: Any?)` and `@objc func fillSelection(_ sender: Any?)`, using the same pattern as 0013's selection actions: if `AppModel.shared.dispatcher.isGestureInProgress` → return; `undoBridge.prepareForNavigation?()` (commit the active tool's pending edit first; once 0020 lands this is reason `.command`, so floating pixels record "Finish Pixels" before "Erase Selection" / "Fill Selection" — 0020's `commandFinishesFirst` covers that path, since 0020 is built after this spec); build the item with `EraseSelection.makeHistoryItem(for: undoBridge.state)` / `FillSelection.makeHistoryItem(for: undoBridge.state, color: AppModel.shared.colors.primary)` (the primary color is read at invocation time); `if let item { undoBridge.perform(item) }`. Canvas invalidation and the marching ants follow automatically from 0013's `onStateChange` handling of `.pixels` / `.pixelsAndSelection`.
   - `validateMenuItem(_:)` for both: enabled iff `!isGestureInProgress && !textInputHasFocus && command.isEnabled(in: undoBridge.state)`. `textInputHasFocus` is the same predicate 0006's router computes: the key window's `firstResponder` is an `NSText` (field editor), or conforms to `NSTextInputClient` and isn't the `CanvasView`. 0006 computes it inline in `handleShortcutKeyDown`; factor it into one `static func textInputHasFocus(in window: NSWindow?) -> Bool` on `CanvasInputRouter` and use it in both places. **Why:** a menu key equivalent without ⌘ would otherwise take ⌫ / ⌥⌫ away from a focused text field. `NSMenu.performKeyEquivalent` doesn't fire a disabled item, so the field editor receives the key. While the Text tool captures the keyboard (0040), it is the canvas's input client, but item 8 never routes ⌫ to these commands then, and the validation also returns false while `dispatcher.activeTool.capturesKeyboard` is true, so ⌫ deletes text.

8. **`Canvas/CanvasInputRouter.swift`** (extend 0006/0007/0009) in `handleShortcutKeyDown(_:model:)`, after the tool and color lookups return `false`:
   - `if let command = SelectionPixelCommand.command(forKeyCode: event.keyCode, modifiers: mods)`, and `ToolShortcutGate.allows(modifiers: mods.subtracting(.option), keyWindow:, textInputHasFocus:, toolCapturesKeyboard:, gestureInProgress:)` is true, then send `NSApp.sendAction(#selector(DocumentWindowController.eraseSelection(_:)) / fillSelection(_:), to: nil, from: nil)` and return `true` (consumed). The action runs its own enablement checks. Option is removed before the gate only for this command, because ⌥⌫ is the documented chord. The gate still rejects ⌘/⌃, text focus, sheets/dialogs, capturing tools, and gestures.
   - Key repeat (`isARepeat`) is consumed and ignored, so holding ⌫ makes one step, not dozens.
   - The gate allows `.document` and `.panel` key windows, so ⌫ works right after clicking the Tools or Layers panel. `sendAction(to: nil)` reaches the main (document) window's controller through the responder chain.
   - The monitor runs before menu key-equivalent matching, so ⌫ handled here doesn't also fire the menu item (one step per press, tested).

9. `project.yml`: no target changes; run `xcodegen generate` after adding files. No PRD.md change is made by this spec (sub-agent rule). The decisions under Open questions need PRD entries once confirmed (E-4 text and §12).

### Performance (NF-1, NF-4)
- Select All / no selection: O(tile count). Erase sets tiles to `nil`, and fill shares one tile across all interior tiles. A 4000×3000 layer has 192 tiles, and a 65,535×65,535 layer has 65,536 tile slots with no pixel loop.
- An antialiased shape selection loops per pixel only over `.partial` mask tiles (the edge ring), concurrently.
- NF-4 cost = the `TileDiff` byte cost (before and after tiles of touched tiles). Erasing full tiles costs only the `before` tiles (`after` is `nil`). The selection part costs 0013's `selectionBytes`.
- Targets on 4000×3000 (Debug test build, gated at 3×, numbers reported in Verification status): Erase Selection with Select All < 10 ms; Fill Selection with no selection < 20 ms; Erase and Fill with a full-canvas antialiased ellipse selection < 100 ms each, including `TileDiff` and `perform`.

## Acceptance criteria
- [ ] Erase Selection sets every fully selected pixel of the active layer to `(0,0,0,0)` and scales alpha by `(255 − m)` on antialiased edges with the exact rounding above; colors are untouched while alpha > 0; unselected pixels and other layers are unchanged. → `EraseSelectionTests.pixelFormulaExhaustive`, `.matchesEraseOps`, `.rectSelectionErasesInside`, `.antialiasedEdgeHandValues`, `.otherLayersUntouched`
- [ ] Fill Selection overwrites fully selected pixels with exactly the primary color (alpha included, no blending) and weights edges by coverage with the exact integer formula; the selection stays. → `FillSelectionTests.*`
- [ ] Erase Selection deselects (Paint.NET doc); one undo restores both the pixels and the selection; redo erases and deselects again. → `EraseSelectionTests.deselectsAndUndoRestoresBoth`, `SelectionPixelCommandIntegrationTests.eraseFillSession`
- [ ] With no selection, both act on the whole active layer, and both menu items are enabled for any open document. → `EraseSelectionTests.noSelectionErasesWholeLayer`, `FillSelectionTests.noSelectionFillsWholeLayer`, `.alwaysEnabled`; `EraseFillSelectionUITests.testMenuItemsAndShortcuts`
- [ ] History steps are named "Erase Selection" / "Fill Selection" with icons `.eraseSelection` / `.fillSelection`; Edit > Undo reads "Undo Erase Selection" / "Undo Fill Selection". → `SelectionPixelCommandIntegrationTests.eraseFillSession`; `EraseFillSelectionUITests.testHistoryAndUndo`
- [ ] A command that changes nothing adds no step (H-6): Fill of an area already that color; Erase of an empty layer with no selection. → `FillSelectionTests.noOpAddsNoStep`, `EraseSelectionTests.noOpWithoutSelection`; Erase over already-transparent pixels with a selection records a deselect-only step → `EraseSelectionTests.transparentAreaStillDeselects`
- [ ] ⌫ and ⌦ erase, ⌥⌫ fills, only when no text field has focus, no sheet/dialog is key, no tool captures the keyboard, and no gesture is in progress; ⇧⌫, ⌘⌫, ⌃⌫, ⌥⌦ do nothing; one press = one step even with key repeat. → `SelectionPixelCommandTests.*`; `EraseFillSelectionUITests.testMenuItemsAndShortcuts`, `.testBackspaceInTextFieldEditsText`
- [ ] A pending tool edit is committed before the command, and the command is ignored mid-gesture. → `SelectionPixelCommandIntegrationTests.pendingEditCommitsFirst`; mid-gesture → manual (needs a held mouse button during a key press)
- [ ] Undo then redo is pixel- and selection-identical across random sessions. → `SelectionPixelCommandIntegrationTests.randomUndoRedoIdentity`
- [ ] Large-layer performance meets the targets above (gated at 3×). → `EraseFillSelectionPerformanceTests.*`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases
- **1×1 image**, **edge tiles** (e.g. 300×257): out-of-canvas tile bytes stay 0 after Fill with a full mask (edge tile invariant, `assert` in `setTile`); erase of a full edge tile sets `nil`. → `FillSelectionTests.edgeTilesKeepOutOfCanvasZero`, `EraseSelectionTests.onePixelImage`
- **Unallocated tiles**: Erase skips them (no allocation); Fill allocates them; a Fill whose result is all zero stores `nil`. → `EraseSelectionTests.unallocatedTilesStayUnallocated`, `FillSelectionTests.transparentColorReleasesTiles`
- **Primary color fully transparent** (alpha 0): Fill behaves exactly like Erase on pixels but keeps the selection and is named "Fill Selection". → `FillSelectionTests.transparentPrimaryEqualsEraseExhaustive`
- **Semi-transparent primary** over opaque pixels: overwrite, not composite. → `FillSelectionTests.semiTransparentOverwrites`
- **Semi-transparent destination** at an antialiased edge: premultiplied weighting. → `FillSelectionTests.edgeOverSemiTransparentHandValues`
- **Hidden active layer**: commands still apply to it (Paint.NET acts on the active layer regardless of visibility); the canvas shows no change until it's shown. → `EraseSelectionTests.hiddenLayerStillErased`
- **Multiple layers**: only the active layer changes; undo doesn't change `activeLayerIndex` (H-6). → `EraseSelectionTests.otherLayersUntouched`
- **Selection touching only part of a tile at a canvas edge, selection covering exactly whole tiles, selection crossing tile boundaries.** → `EraseSelectionTests.crossTileRect`, `FillSelectionTests.crossTileRect`
- **Largest sizes**: a 65,535×1 strip with Select All erases and fills through the `.full` fast path without a pixel loop (the test checks storage sharing on fill and `nil` tiles on erase). → `FillSelectionTests.wideStripSharesStorage`, `EraseSelectionTests.wideStripReleasesTiles`
- **Text field focused / Text tool typing**: ⌫ edits text; menu items are disabled. → UI test + `SelectionPixelCommandTests` gate rows
- **Sheet or dialog key (Save panel, New Image dialog, alert)**: ⌫ goes to the dialog. → gate `.other` row (0006 gate test) + manual
- **Key repeat**: consumed, no extra steps. → `SelectionPixelCommandTests.repeatIsIgnored` (router decision factored as a pure function, see Test plan)
- **Undo budget**: a full-layer Erase step on 4000×3000 costs 192 tiles × 262,144 B (before only) + overhead; a huge step is still kept (H-6). → `EraseSelectionTests.byteCostFullLayer`
- Every failure path is a defined no-op: no document → menu items disabled (no target in the chain); gesture in progress → action returns; a nil item → nothing recorded.

## Test plan
Expected values below are computed by hand from the formulas (independent oracles), never pasted from the implementation.

- **Unit — `PaintDotMacTests/Operations/EraseSelectionTests.swift`** (Swift Testing; fixtures from `TestImages`, masks from 0013's `SelectionMask(size:coverage:)` / `Selection(rect:canvasSize:)`):
  - `pixelFormulaExhaustive`: for all `a, m ∈ 0…255` with `p = (200, 100, 50, a)`: expected computed inline as `m == 0 ? p : { let n = (a*(255-m)+127)/255; n == 0 ? (0,0,0,0) : (200,100,50,n) }`; also `Int((Double(a*(255-m))/255).rounded())` equals `n` (no ties).
  - `matchesEraseOps`: for all `a, m` and three RGB triples, `erasePixel(p, coverage: m) == EraseOps.erase(p, strength: 255, coverage: m)`.
  - Hand values: `(255,255,255,255), m 128` → `(255,255,255,127)`; `(10,20,30,200), m 64` → `x = 200·191 = 38200`, `(38200+127)/255 = 150` → `(10,20,30,150)`; `(10,20,30,1), m 128` → `(0,0,0,0)`; `(10,20,30,1), m 127` → `(10,20,30,1)`; any `p`, `m 255` → `(0,0,0,0)`; `(0,0,0,0)` any `m` → `(0,0,0,0)`.
  - `rectSelectionErasesInside`: 300×300 opaque white, selection rect (40,20,100,50) → pixels in x 40…139, y 20…69 `(0,0,0,0)`; (39,20), (140,20), (40,19), (40,70) white (checks no Y flip and half-open bounds); `TestImages.expectPixels` over the whole surface.
  - `antialiasedEdgeHandValues`: 64×64 opaque `(200,100,50,255)`, selection rect (10.5, 0, 2, 64) antialiased (0013: columns 10 and 12 coverage 128, column 11 255) → (10,y) `(200,100,50,127)`, (11,y) `(0,0,0,0)`, (12,y) `(200,100,50,127)`, (9,y) and (13,y) unchanged.
  - `crossTileRect`: 600×600 opaque, rect (200,200,200,200) spans tiles (0,0),(1,0),(0,1),(1,1) → `touched` equals exactly those 4 coordinates; pixels match the rect oracle.
  - `fullTileFastPath`: rect (256,0,256,256) on 1024×256 → tile (1,0) is `nil` after erase; tiles (0,0), (2,0), (3,0) `sharesStorage` with the originals.
  - `unallocatedTilesStayUnallocated`: an empty 512×512 layer with Select All → `touched.isEmpty`, `allocatedTileCoordinates` empty; `makeHistoryItem` is a deselect-only composite (selection existed).
  - `partialTileBecomesNilWhenTransparent`: 256×256 tile whose only opaque pixels lie inside an ellipse selection whose mask is 255 there → the tile becomes `nil`.
  - `noSelectionErasesWholeLayer`: 300×300 opaque, no selection → every tile `nil`; history item `change == .pixels(...)` with all 4 tiles.
  - `noOpWithoutSelection`: empty layer, no selection → `makeHistoryItem == nil`.
  - `transparentAreaStillDeselects`: empty layer, rect selection → item non-nil, name "Erase Selection", applying it sets `selection == nil`, pixels unchanged.
  - `deselectsAndUndoRestoresBoth`: rect selection on opaque layer → `apply` → pixels erased and `selection == nil`; `revert` → original tiles (`==` and, for untouched tiles, `sharesStorage`) and the original `Selection` (`==`).
  - `otherLayersUntouched`: two-layer image, active index 1 → layer 0's tiles `sharesStorage` with the originals; `activeLayerIndex` unchanged after apply and revert.
  - `hiddenLayerStillErased`: active layer `isVisible = false` → erased as normal.
  - `onePixelImage`: 1×1 opaque, Select All → `(0,0,0,0)`, tile `nil`.
  - `wideStripReleasesTiles`: 65,535×1 opaque (via `fill`), Select All → all 256 tiles `nil`.
  - `byteCostFullLayer`: 4000×3000 opaque (`fill`, which shares interior tiles), Select All → the item's `byteCost` = `TileDiff` cost per 0008's rule (`Σ tileBytes(before)`, `after` nil) + 0013's `selectionBytes(Select All → nil)`, computed in the test from the tile count (192 × 262,144) and `Selection.all`'s `pathByteEstimate`.
  - `alwaysEnabled`: `isEnabled` true with and without a selection.
- **Unit — `PaintDotMacTests/Operations/FillSelectionTests.swift`:**
  - Hand values for `fillPixel`: `p = white opaque, color = (255,0,0,255)`: `m 255` → `(255,0,0,255)`; `m 0` → white; `m 128` → `wD = 32385, wC = 32640, sum = 65025, outA = 255, r = 255, g = b = (255·32385 + 32512)/65025 = 127` → `(255,127,127,255)`. `p = (0,0,0,0), color = (10,20,30,200), m 100` → `wC = 20000, outA = (20000+127)/255 = 78`, channels exact → `(10,20,30,78)`. `p = (0,0,255,255), color = (255,0,0,128), m 255` → `(255,0,0,128)`.
  - `edgeOverSemiTransparentHandValues`: `p = (0,0,255,100), color = (255,0,0,255), m 128` → `wD = 100·127 = 12700, wC = 32640, sum = 45340, outA = (45340+127)/255 = 178` (`45467/255 = 178.3`), `r = (255·32640 + 22670)/45340 = 8345870/45340 = 184` (184.07), `g = (0 + 0 + 22670)/45340 = 0`, `b = (255·12700 + 22670)/45340 = 3261170/45340 = 71` (71.93 → floor 71) → `(184,0,71,178)`. (Check: `b` = round-half-up of `255·12700/45340 = 71.43` → 71 ✓.)
  - `pixelFormulaReference`: for 20,000 seeded random `(p, color, m)` triples (`SeededRandom`, seed printed on failure), `fillPixel` equals a test-local `Double` reference: `outA = round(Da(1−f) + Ca·f)` and `ch = round((Dc·Da(1−f) + Cc·Ca·f) / (Da(1−f) + Ca·f))` with `f = m/255`, transparent → `(0,0,0,0)`, `m` 0/255 short-circuits, ±0 tolerance on alpha and ±1 on channels. The integer rule is normative; ±1 only allows for `Double` rounding at exact halves.
  - `transparentPrimaryEqualsEraseExhaustive`: for all `a, m ∈ 0…255` and RGB (200,100,50): `fillPixel(p, color: (9,9,9,0), coverage: m) == EraseSelection.erasePixel(p, coverage: m)`.
  - `alphaBounds`: over the seeded triples, `min(p.a, c.a) ≤ out.a ≤ max(p.a, c.a)` (for `0 < m < 255`).
  - `semiTransparentOverwrites`: 64×64 opaque blue, Select All, color `(255,0,0,128)` → every pixel `(255,0,0,128)`, exactly. A Normal blend would leave alpha 255 and keep some blue, so this proves the fill overwrites.
  - `rectSelectionFillsInside` / `crossTileRect`: as for erase, with primary `(0,128,255,255)`; selection unchanged after apply (`state.selection ==` before).
  - `noSelectionFillsWholeLayer`: 600×300 transparent, no selection, red → every pixel red; interior full tiles share storage with each other (`tile(at: (0,0)).sharesStorage(with: tile(at: (1,0)))`), and the edge tile (2,0) (width 88) has its out-of-canvas bytes 0.
  - `edgeTilesKeepOutOfCanvasZero`: 300×257, Select All, opaque color → for edge tiles, every tile-local byte outside `pixelRect(of:)` is 0.
  - `transparentColorReleasesTiles`: opaque layer, Select All, color `(0,0,0,0)` → all tiles `nil`.
  - `wideStripSharesStorage`: 65,535×1, Select All, red → 255 interior tiles share one storage; the last tile is an edge tile.
  - `noOpAddsNoStep`: red layer, Select All, fill red → `makeHistoryItem == nil`.
  - `primaryReadAtCallTime` is an integration concern (below); `makeHistoryItem` takes the color as a parameter.
- **Unit — `PaintDotMacTests/Operations/SelectionPixelCommandTests.swift`:**
  - Key table: `(51, [])` → `.eraseSelection`; `(117, [])` → `.eraseSelection`; `(51, .option)` → `.fillSelection`; `(117, .option)`, `(51, .shift)`, `(51, .command)`, `(51, .control)`, `(51, [.option, .shift])`, `(0 /* A */, [])` → `nil`.
  - Router decision, factored from item 8 as `static func selectionPixelShortcut(keyCode:modifiers:isRepeat:keyWindow:textInputHasFocus:toolCapturesKeyboard:gestureInProgress:) -> SelectionPixelShortcutDecision` (`.perform(command)`, `.consumeIgnored`, `.pass`), in `Core/Operations/EraseSelection.swift`: ⌥⌫ in `.document` → `.perform(.fillSelection)`; ⌫ with `textInputHasFocus` → `.pass`; `.other` window → `.pass`; capturing tool → `.pass`; gesture → `.pass`; `isRepeat` → `.consumeIgnored` (`repeatIsIgnored`); `.panel` window → `.perform(.eraseSelection)`.
  - `menuNamesAndIcons`: `EraseSelection.name == "Erase Selection"`, `FillSelection.name == "Fill Selection"`, icons `.eraseSelection` / `.fillSelection`.
- **Unit — `PaintDotMacTests/App/MainMenuTests.swift`** (extend): Edit menu order `… "Select All" ⌘A, "Deselect" ⌘D, "Erase Selection" (keyEquivalent "\u{8}", no modifiers, `eraseSelection(_:)`), "Fill Selection" ("\u{8}", `.option`, `fillSelection(_:)`), "Invert Selection" ⌘I`; identifiers `menu.edit.eraseSelection`, `menu.edit.fillSelection`.
- **Integration — `PaintDotMacTests/Integration/SelectionPixelCommandIntegrationTests.swift`** (`UndoBridge` + `DocumentState`, or 0010's `BridgeToolContext`):
  - `eraseFillSession`: 200×200 white "Open Image"; set selection rect (50,50,100,100) through `SelectionHistoryItem` "Rectangle Select" (0014 name); Fill with red → selection still rect; Erase → selection nil, rect pixels `(0,0,0,0)`. Step names `["Open Image", "Rectangle Select", "Fill Selection", "Erase Selection"]`; `undoManager.undoActionName == "Erase Selection"`. Undo → rect red, selection rect; undo → white; redo ×2 → back to erased with no selection. Pixels checked against oracles each time.
  - `pendingEditCommitsFirst`: a stub tool with `hasPendingEdit` whose `commit` records a "Paintbrush" step; `prepareForNavigation` + Erase → names end in `["Paintbrush", "Erase Selection"]`.
  - `primaryReadAtCallTime`: through the window-controller action helper (or its extracted `@MainActor` function taking `AppModel`): change `AppModel.colors.primary` to green before ⌥⌫ → filled green.
  - `randomUndoRedoIdentity` (property, `SeededRandom`, 50 sessions): random sequences of rect/ellipse selections, Deselect, Fill (random colors including alpha 0 and 128), Erase, and Paintbrush strokes on a 2-layer 600×400 image; undo all then redo all → at every step tiles `==` and `selection ==` the recorded states.
- **UI tests — `PaintDotMacUITests/EraseFillSelectionUITests.swift`** (`UITestApp`, 200×200 opaque white PNG fixture via `UITestFixtures.writePNG`, `-UITestResetDefaults` so primary is black, launched with `["-UITestSelectRect", "50,50,100,100"]`):
  - `testMenuItemsAndShortcuts`: Edit menu shows "Erase Selection" and "Fill Selection", both enabled; press ⌥⌫ → "Undo Fill Selection" present, `canvas.marchingAnts` still "animated"; ⌘S, read the PNG → (100,100) `(0,0,0,255)`, (20,20) white. Press ⌫ → `canvas.marchingAnts` "hidden"; ⌘S, read → (100,100) alpha 0, (20,20) white. ⌘Z → ants "animated", (100,100) black again after ⌘S. Then ⌘D and press ⌦ (`XCUIKeyboardKey.forwardDelete`) → whole image transparent after ⌘S (no selection = whole layer).
  - `testHistoryAndUndo`: ⌥⌘2; ⌥⌫, ⌫ → `historyRow.1` "Fill Selection", `historyRow.2` "Erase Selection"; ⌘Z → `historyRow.2` value "undone"; ⇧⌘Z → not undone.
  - `testBackspaceInTextFieldEditsText`: B (Paintbrush); click `toolOptions.width`, select its text, type "25", press ⌫ → field value "2"; press Return (focus back to canvas, 0006 `onEndEditing`); History panel has only the base row (no Erase step); ⌘S → (100,100) still white.
- **Performance — `PaintDotMacTests/Performance/EraseFillSelectionPerformanceTests.swift`** (XCTest `measure` + explicit timing, gated at 3× the targets in Scope, numbers reported in Verification status): `eraseSelectAll4000x3000`, `fillNoSelection4000x3000`, `eraseEllipse4000x3000`, `fillEllipse4000x3000` (ellipse inscribed in the canvas, antialiased, via 0013's `Selection(path:canvasSize:)`; each includes `makeHistoryItem` and `HistoryStack.perform`).
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build, zero warnings, all tests pass with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open a photo, draw an ellipse selection (0014), press ⌫: the inside becomes checkerboard with a smooth edge, the ants disappear; ⌘Z brings back pixels and ants together.
  2. Ellipse selection, set primary to a half-transparent red in the Colors panel, ⌥⌫: the inside shows half-transparent red over the checkerboard (overwritten, not mixed with the photo), the edge is smooth, the ants stay.
  3. With the Tools panel just clicked (key), press ⌫: it erases (panel key window allowed).
  4. Hold ⌫ for two seconds: exactly one "Erase Selection" step in History.
  5. Start a Paintbrush drag, press ⌫ while the mouse button is held: nothing is erased during the stroke (gesture gate); release: one "Paintbrush" step.
  6. Open File > New (dialog key) and press ⌫ in its width field: only the text changes.
  7. Press ⌫ with nothing selected: the whole active layer is cleared; ⌘Z restores it.

## Open questions
1. **No selection → whole active layer, items always enabled.** Recommended: yes. This is consistent with D-40 / TOOL-B ("no selection" = everything editable) and with Paint.NET treating an empty selection as the whole canvas. The doc page doesn't state the no-selection result explicitly, and live Paint.NET behavior could not be checked from here. The alternative is to disable both items without a selection.
2. **Fill Selection overwrites (alpha included) rather than Normal-blending the primary color.** Recommended: overwrite, with premultiplied coverage weighting on antialiased edges, as specified. Only semi-transparent primary colors over non-transparent pixels tell the two apart. The evidence is the doc wording ("fill it with the current Primary color", Erase "replaced with") and Paint.NET 3.x's constant-color clear, which is recalled from memory and was not re-verified.
3. **Shift+⌫ (Paint.NET: fill with the secondary color)** is not in E-4. Recommended: leave it unmapped in v1.0 (⇧⌫ does nothing), or add it to E-4 as "Fill Selection with the secondary color" if the user wants it.

Once confirmed, PRD.md E-4 and §12 need a new decision row (no selection = whole layer; Fill overwrites; Erase deselects, per the Paint.NET doc; ⇧⌫ unmapped).

## Out of scope
- Fill with the secondary color (⇧⌫) — Open question 3.
- Delete Layer ⇧⌘⌫ — **0024**. Cut (⌘X erases after copying through `EraseSelection.erase(_:mask:)`, as a step named "Cut") — **0021**.
- Deleting floating pixels during Move Selected Pixels — **0020** (⌫ while pixels float records 0020's "Finish Pixels" first, then erases).
- Paint Bucket and Magic Wand fills — **0016**, **0017**. Gradient — **0023**.
- Shortcut table centralization and `docs/shortcuts.md` — **0045** (it moves these two key equivalents and the ⌦ alias into `ShortcutTable`).
