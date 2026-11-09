# 0013 — Add the selection model, Select All / Deselect / Invert Selection, marching ants, and selection-clipped painting

> Source: PRD.md §5.6 E-3 (Select All, Deselect, Invert Selection); §5.2 CAN-7 (animated "marching ants"); §5.3 TOOL-B (painting is confined to the active selection) and the §5.3 rule "Selection changes are history steps … ("Rectangle Select", "Deselect", "Invert Selection", …)" (D-13); §5.12 (Select All ⌘A, Deselect ⌘D, Invert Selection ⌘I); §6 NF-7 (Reduce Motion → static marching ants), NF-1, NF-4; §5.7 H-6 / D-34 (no-op edits add no step); §7 (Model: "Selection (path + rasterized mask)"); §11 R-2; AGENTS.md architecture rules 1–3 and 8.
> Paint.NET docs (fetched 2026-11-05): Edit menu — https://www.getpaint.net/doc/latest/EditMenu.html · Selection tools and modes — https://www.getpaint.net/doc/latest/SelectionTools.html · Tool Bar (Selection Mode, Selection Clipping) — https://www.getpaint.net/doc/latest/Toolbar.html (`getpaint.net/doc/latest/…` redirects to `paint.net/doc/latest/…`).
> Milestone: M2
> Depends on: 0011-pencil-and-eraser (and therefore 0001–0010; 0012 is independent but lower-numbered and built first)

## Context
Not yet implemented: there is no selection. After 0001–0012:
- `DocumentState` (`PaintDotMac/Core/Model/DocumentState.swift`, 0008) holds only `image: LayeredImage`; its doc comment reserves `selection` for this spec.
- `HistoryItem`, `HistoryChange` (`.pixels`, `.structure`), `TileDiffHistoryItem`, `DocumentSnapshotHistoryItem`, `CompositeHistoryItem`, `HistoryCost`, `HistoryStack`, `HistoryIcon` (already has `selectAll`, `deselect`, `invertSelection`) live in `Core/History/` (0008); `UndoBridge` (`Document/UndoBridge.swift`, 0008) owns the live `DocumentState`, has `prepareForNavigation` (commits the active tool's pending edit) and `onStateChange(HistoryChange)`, which `DocumentWindowController` uses to invalidate the canvas.
- `BrushEngine.swift` (0009) declares `protocol BrushClipMask: Sendable { var bounds: PixelRect { get }; func coverage(x: Int, y: Int) -> UInt8 }`; `BrushStroke` multiplies stroke coverage by `BlendOps.mul255(strokeCov, clip.coverage(x, y))`. `ToolContext.paintClipMask: (any BrushClipMask)?` exists and `CanvasToolSession` returns `nil`; `FakeToolContext` has a settable `paintClipMask`. Paintbrush (0009), Pencil and Eraser (0011) capture `context.paintClipMask` at mouse-down and route every pixel through it (`PencilToolTests.respectsClipHook`, `EraserToolTests.respectsClipHook`).
- `CanvasTransform` (`Core/Rendering/CanvasTransform.swift`, 0003): canvas space = image pixels, top-left origin, y down; view space = AppKit bottom-left points; `canvasToView(_:)`. The window content is `ToolOptionsBar` / container (`CanvasView` + `ToolOverlayView`) / status bar (0006). `ToolDispatcher.isGestureInProgress` (0006).
- `App/MainMenu.swift` (0001) already has Edit > **Select All** ⌘A with action `selectAll(_:)` (target nil); nothing implements it on the canvas, so it is disabled except in text fields.
- `App/LaunchOptions.swift` (0001) parses the `#if DEBUG` launch hooks `-UITestOpen`, `-UITestResetDefaults`.

**Paint.NET behavior mirrored** (EditMenu.html): "**Select All** (Ctrl + A): This causes the entire active layer to become selected." "**Deselect** (Ctrl + D): Deselect forces all selected pixels to be deselected. In other words, no pixels will remain selected." "**Invert Selection** (Ctrl + I): If there is a selection active, this command will cause all pixels that are selected to be deselected, and vice-versa." The item is named "Deselect" (not "Deselect All"). SelectionTools.html: an active selection is shown with a "dashed moving outline"; "It is not possible to edit outside an active selection"; the five selection modes are **Replace**, **Add (Union)**, **Subtract**, **Intersect**, **Invert ("xor")** — "This acts like Add mode except that overlapping regions are *removed* from the total selection." Selection edges are antialiased ("The fill color is subtly extended into pixels which are partially covered by the selection").

This spec builds the selection *engine* (model, mask, combination algebra, history, clipping, display) plus the three Edit commands. The selection tools that create shaped selections (0014–0016) and the commands that consume selections (0018–0023) build on it.

## User story
As a PaintDotMac user, I press ⌘A to select the whole image and see marching ants around it (static if I turned on Reduce Motion), ⌘I to invert the selection, and ⌘D to drop it; each is a History step ("Select All", "Invert Selection", "Deselect") that ⌘Z undoes; and while a selection exists the Paintbrush, Pencil, and Eraser only change pixels inside it, with smooth (antialiased) edges. With no selection, the whole image is editable.

## Scope & changes

### Core (pure Swift, headless, unit-tested; no AppKit/SwiftUI imports)

1. **`Core/Model/SelectionCombineMode.swift`** (new)
   ```swift
   public enum SelectionCombineMode: String, CaseIterable, Sendable {
       case replace, union, exclude, intersect, xor
       public var displayName: String   // "Replace", "Add (Union)", "Subtract", "Intersect", "Invert (Xor)" — Paint.NET SelectionTools.html names; 0014 shows them in its picker
       /// Exact 8-bit coverage algebra. a = existing coverage, b = operand coverage, both 0…255.
       public func combine(_ a: UInt8, _ b: UInt8) -> UInt8
   }
   ```
   **Normative mask algebra** (all exact integer ops, no rounding):
   | mode | result | Paint.NET |
   |---|---|---|
   | `replace` | `b` | Replace |
   | `union` | `max(a, b)` | Add (Union) |
   | `exclude` | `a − min(a, b)` (= `max(0, a − b)`) | Subtract |
   | `intersect` | `min(a, b)` | Intersect |
   | `xor` | `max(a, b) − min(a, b)` (= `|a − b|`) | Invert ("xor") |

   Why these (and not fuzzy `min(a, 255−b)` forms): they agree with the geometric path booleans in the self-case, so A ∖ A = ∅ and A ⊕ A = ∅ exactly even on antialiased edges, and they satisfy `xor = union − intersect`, `exclude + intersect = a`, `invert(a) = 255 − a = xor(full, a) = exclude(full, a)`, and De Morgan (`255 − max(a,b) = min(255−a, 255−b)`). Document the table in the file header.

2. **`Core/Model/SelectionMask.swift`** (new) — the cached, rasterized, 8-bit antialiased mask on the same 256×256 tile grid as `TiledSurface` (AGENTS rule 3).
   ```swift
   public final class SelectionMaskTileStorage: Sendable {      // immutable; identity = memory accounting key
       public let bytes: [UInt8]                                 // exactly 256 × 256, row-major, tile-local
   }
   public enum SelectionMaskTile: Sendable, Equatable {
       case empty                                               // every pixel 0
       case full                                                // every in-canvas pixel 255
       case partial(SelectionMaskTileStorage)                   // anything else; == by identity, then by bytes
   }
   public struct SelectionMask: Sendable, Equatable, BrushClipMask {
       public static let tileSize = 256
       public let size: PixelSize
       public let bounds: PixelRect                 // tight bounds of pixels with coverage > 0; .zero when empty (BrushClipMask)
       public var isEmpty: Bool { get }             // every tile .empty
       public var isFull: Bool { get }              // every tile .full
       public var partialTileCount: Int { get }
       public init(size: PixelSize)                                            // empty
       public static func full(size: PixelSize) -> SelectionMask               // all tiles .full, no byte storage
       public init(size: PixelSize, coverage: (_ x: Int, _ y: Int) -> UInt8)  // builder (tests, 0016 flood fill)
       public init(size: PixelSize, tiles: [SelectionMaskTile])                // row-major grid; normalizes
       public func tile(at coordinate: TileCoordinate) -> SelectionMaskTile    // out of grid → .empty
       public func coverage(x: Int, y: Int) -> UInt8                           // outside size → 0 (BrushClipMask)
       public func inverted() -> SelectionMask
       public func combined(with operand: SelectionMask, mode: SelectionCombineMode) -> SelectionMask
       public var tileStorageIdentities: [ObjectIdentifier: Int] { get }       // distinct partial storages → byte count (65,536)
   }
   ```
   - Grid: `ceil(width/256) × ceil(height/256)` tiles, same `TileCoordinate` (0002) as the image. **Invariant:** pixels of an edge tile that lie outside `size` are always 0 in `.partial` storage; `.full` means every *in-canvas* pixel is 255. Every operation computes only in-canvas pixels.
   - **Normalization** (in every initializer and operation result): a `.partial` tile whose in-canvas pixels are all 0 becomes `.empty`, all 255 becomes `.full`. So two masks with equal coverage everywhere are `==`, and `isEmpty`/`isFull` are exact.
   - `inverted()`: `.empty ↔ .full`; `.partial` → new storage with `255 − v` for in-canvas pixels (out-of-canvas stays 0), then normalize. Unchanged tiles are never copied.
   - `combined(with:mode:)` (if sizes differ: returns `self` unchanged — a defined no-op, never a trap; unreachable through the app): per tile, with constant fast paths that must equal the per-pixel table (tested): `replace` → operand tile; `union`: empty∪X = X, full∪X = full; `intersect`: empty∩X = empty, full∩X = X; `exclude`: empty∖X = empty, X∖empty = X, X∖full = empty, full∖partial = invert(partial); `xor`: empty⊕X = X, full⊕X = invert(X). Remaining partial/partial pairs run `mode.combine` per in-canvas pixel (a tight loop over `[UInt8]`; may use `concurrentPerform` over tiles — results are per-pixel independent, so bit-identical). A result tile that is identical to an input tile reuses that tile's storage (no copy).
   - `bounds`: computed once at init: union of `.full` tile rects (clipped to `size`) and, for `.partial` tiles, the tight rows/columns with a non-zero byte.
   - Conformance to 0009's `BrushClipMask` is declared here (`bounds`, `coverage(x:y:)`).

3. **`Core/Model/MaskRasterizer.swift`** (new) — path → `SelectionMask`.
   ```swift
   public enum MaskRasterizer {
       public static func rasterize(_ path: CGPath, size: PixelSize, antialiased: Bool) -> SelectionMask
   }
   ```
   - Input path is in **canvas coordinates** (y down), filled with the **non-zero winding** rule (callers pass normalized paths, see `Selection`).
   - Empty `size`, an empty path, or a non-finite `boundingBoxOfPath` → empty mask.
   - **Axis-aligned rectangle fast path** (`path.isRect(&rect)` true): exact analytic coverage, no CoreGraphics rendering, so rectangles (Select All's inverse, 0014 Rectangle Select, the UI-test hook) are deterministic:
     - antialiased: `coverage(i, j) = UInt8((255 × ox × oy).rounded(.toNearestOrAwayFromZero))` where `ox = max(0, min(i+1, rect.maxX) − max(i, rect.minX))`, `oy` likewise (both in 0…1). Integer-aligned rects → exactly 255 inside, 0 outside.
     - aliased: pixel `(i, j)` is 255 iff its center `(i+0.5, j+0.5)` lies in `[minX, maxX) × [minY, maxY)`, i.e. `i ∈ ceil(minX − 0.5) ..< ceil(maxX − 0.5)` (same for rows), else 0.
     - Tile-level shortcut (both modes): a tile whose in-canvas rect lies entirely in the 255-coverage interior is `.full`, one entirely outside the rect is `.empty`; only tiles crossed by the rect's edges are computed per pixel. So a whole-canvas or huge integer rectangle (0014's 65,535 × 65,535 drag) allocates no tile bytes and costs O(tiles + edge pixels).
   - **General paths:** only tiles whose rect intersects `boundingBoxOfPath` expanded by 1 px are rendered; others are `.empty`. Each such tile gets its own 256×256 8-bit `CGContext` (`CGColorSpaceCreateDeviceGray()`, `CGImageAlphaInfo.none`, bytesPerRow 256, zero-filled), clipped to the tile's in-canvas rect, with the transform `translate(0, 256) · scale(1, −1) · translate(−originX, −originY)` (canvas y-down → bitmap; memory row 0 = canvas row `originY`), `setShouldAntialias(antialiased)`, gray fill 1.0, `fillPath(using: .winding)`. Tiles may be rendered concurrently (`DispatchQueue.concurrentPerform`, one context per tile). Result normalized. This is the only place in the code that converts a selection path to pixels; it must not flip Y anywhere else.

4. **`Core/Model/Selection.swift`** (new) — the selection value: the vector outline plus its mask (AGENTS rule 8, R-2).
   ```swift
   public struct Selection: Sendable, Equatable {
       public let canvasSize: PixelSize
       public let path: CGPath          // canvas coordinates, normalized, clipped to the canvas rect; outline for display (ants) and later transforms (0019)
       public let mask: SelectionMask   // coverage used for every pixel operation; normative
       public let pathByteEstimate: Int // 64 + 32 × path element count (counted once with applyWithBlock); history accounting
       public var bounds: PixelRect { mask.bounds }

       public init?(path: CGPath, canvasSize: PixelSize, antialiased: Bool = true, fillRule: CGPathFillRule = .winding)
       public init?(rect: CGRect, canvasSize: PixelSize, antialiased: Bool = true)
       public init?(mask: SelectionMask, outline: CGPath)       // 0016 Magic Wand: mask from FloodFill, outline traced by 0016
       public static func all(canvasSize: PixelSize) -> Selection // "Select All"
       public func inverted() -> Selection?
       public func combined(with operand: Selection?, mode: SelectionCombineMode) -> Selection?
       public static func combine(_ existing: Selection?, _ operand: Selection?, mode: SelectionCombineMode, canvasSize: PixelSize) -> Selection?
   }
   ```
   - **"No selection" is `nil`** everywhere (`DocumentState.selection == nil`): the whole image is editable, no ants are drawn, `paintClipMask` is `nil`. A `Selection` value is never empty: every initializer and operation that would produce an all-zero mask returns `nil` instead (zero-area path, path outside the canvas, A ⊕ A, A ∖ A, disjoint intersection, inverting a full selection). PRD E-3 / D-40.
   - `init?(path:…)`: `clipped = path.normalized(using: fillRule).intersection(CGPath(rect: canvasRect, transform: nil))` (CoreGraphics path booleans, macOS 13+), `mask = MaskRasterizer.rasterize(clipped, size: canvasSize, antialiased:)`; `nil` if `mask.isEmpty` or `canvasSize.isEmpty`.
   - `init?(rect:…)`: `CGPath(rect: rect.standardized ∩ canvasRect)`, rasterized through the rect fast path. Non-finite rect → `nil`.
   - `all(canvasSize:)`: path = canvas rect, mask = `SelectionMask.full(size:)` (O(tiles), no rasterization, no byte storage). Precondition: non-empty size (images are ≥ 1×1, APP-10).
   - `init?(mask:outline:)`: stores `outline.intersection(canvasRect)` and the given mask; `nil` if `mask.isEmpty` or sizes differ.
   - `inverted()`: path = `canvasRectPath.subtracting(path)` (the ants then also run along the canvas border, as in Paint.NET), mask = `mask.inverted()`; `nil` when the new mask is empty.
   - `combine(existing, operand, mode, canvasSize)`: `nil` operands count as the empty set for the algebra. Path: `replace` → operand path; `union` → `a.union(b)`; `exclude` → `a.subtracting(b)`; `intersect` → `a.intersection(b)`; `xor` → `a.symmetricDifference(b)` (with the `nil` side treated as an empty path). Mask: `existingMask.combined(with: operandMask, mode:)`. Result `nil` when the mask is empty. Sizes must match; a mismatch returns `existing` unchanged (defined no-op).
   - **Path vs mask:** the mask of a combination is the exact per-pixel algebra of the operand masks; it is *not* re-rasterized from the combined path. Both describe the same region; they can differ only in edge-pixel antialiasing. The mask is normative for pixels; the path is for display (and for 0019, which re-rasterizes a moved path).
   - `Equatable`: `canvasSize`, `mask` (by content, with the storage-identity fast path), and `path` (`CGPath ==`, i.e. `CFEqual`).
   - If `CGPath` is not `Sendable` in the macOS 26 SDK, store it in a private `struct SendablePath: @unchecked Sendable { let path: CGPath }` (an immutable `CGPath` is thread-safe; say so in a comment) and expose `path` as a computed property.

5. **`Core/Model/DocumentState.swift`** (extend 0008): `public var selection: Selection?` (default `nil`), `init(image: LayeredImage, selection: Selection? = nil)`. Invariant (doc comment + `assert` in `UndoBridge` after each mutation): `selection == nil || selection.canvasSize == image.size`. Operations that change the canvas size (0022, 0035–0037) are responsible for transforming or dropping the selection in their snapshot.

6. **`Core/History/HistoryChange.swift`** (extend 0008):
   ```swift
   case selection                                              // only the selection changed (no pixels)
   case pixelsAndSelection([Layer.ID: Set<TileCoordinate>])   // these tiles and the selection
   public var pixelTiles: [Layer.ID: Set<TileCoordinate>]? { get } // .pixels/.pixelsAndSelection payload; nil otherwise
   public var affectsSelection: Bool { get }                   // .selection, .pixelsAndSelection, .structure → true
   ```
   `merged(with:)` table (symmetric): pixels+pixels → pixels(∪); selection+selection → selection; pixels+selection → pixelsAndSelection(tiles); pixelsAndSelection + pixels/selection/pixelsAndSelection → pixelsAndSelection(∪); anything + structure → structure. (`CompositeHistoryItem` picks this up unchanged, for example 0020's commit = pixels + selection.)

7. **`Core/History/SelectionHistoryItem.swift`** (new) — the lightweight item for selection-only changes (chosen over `DocumentSnapshotHistoryItem` so that undoing a selection step re-uploads no tiles and reports `.selection`):
   ```swift
   public struct SelectionHistoryItem: HistoryItem {
       public init(name: String, icon: HistoryIcon, before: Selection?, after: Selection?)
       // change = .selection; isNoOp = (before == after); byteCost = HistoryCost.selectionBytes(before:after:)
       // apply: state.selection = after; revert: state.selection = before (never touches pixels)
   }
   ```
   Used here for "Select All", "Deselect", "Invert Selection" and by 0014–0016/0019 for "Rectangle Select", "Ellipse Select", "Lasso Select", "Magic Wand", "Move Selection". Pixel + selection steps (0018 Erase Selection, which erases and then deselects, as in Paint.NET; 0020 commit) use `CompositeHistoryItem` with a `TileDiffHistoryItem` and a `SelectionHistoryItem`.

8. **`Core/History/HistoryCost.swift`** (extend 0008):
   - `static func selectionBytes(before: Selection?, after: Selection?) -> Int` = Σ byte counts of partial-tile storages (`tileStorageIdentities`) present on only one side + `pathByteEstimate` of each side whose path is not the identical object (`!==`) of the other side's path (a `nil` side contributes 0). Examples: `nil` → Select All = Select All's `pathByteEstimate` only (full tiles have no storage); undo/redo shares the same values, so cost is fixed at init.
   - `unsharedTileBytes(before:after:)` (used by `DocumentSnapshotHistoryItem`) additionally adds `selectionBytes(before.selection, after.selection)`, so structural steps that change the selection account for it.

9. **`Core/Operations/SelectionCommands.swift`** (new) — the Edit-menu commands as pure functions on `DocumentState`:
   ```swift
   public enum SelectionCommand: CaseIterable, Sendable {
       case selectAll, deselect, invertSelection
       public var name: String          // "Select All", "Deselect", "Invert Selection" (Paint.NET spelling; history step and menu title)
       public var icon: HistoryIcon     // .selectAll, .deselect, .invertSelection
       public func isEnabled(in state: DocumentState) -> Bool
       public func makeHistoryItem(for state: DocumentState) -> SelectionHistoryItem?   // nil when disabled or a no-op (H-6)
   }
   ```
   - `selectAll`: enabled always (any open document); after = `Selection.all(canvasSize: image.size)`; no-op (nil) if the selection already equals it.
   - `deselect`: enabled iff `selection != nil`; after = `nil`.
   - `invertSelection`: enabled iff `selection != nil` (EditMenu.html: "If there is a selection active"; PRD E-3 / D-40); after = `selection.inverted()` (`nil` when everything was selected, i.e. inverting Select All deselects).

10. **`Core/Rendering/CanvasTransform.swift`** (extend 0003): `var canvasToViewAffine: CGAffineTransform { get }` — the affine map equal to `canvasToView(_:)`, built from `canvasToView` of (0,0), (1,0), (0,1) (`a,b` = image of (1,0) − origin; `c,d` = image of (0,1) − origin; `tx,ty` = origin). Overlays must use it (never flip Y inline, CAN-6).

11. **`Core/Rendering/MarchingAnts.swift`** (new) — pure display decisions for CAN-7 / NF-7:
    ```swift
    public enum MarchingAnts {
        public static let lineWidth: CGFloat = 1            // points
        public static let dashPattern: [CGFloat] = [4, 4]   // points; black dashes over a solid white line
        public static let phasePeriod: CGFloat = 8          // = sum of the dash pattern
        public static let animationDuration: TimeInterval = 0.5   // one phase period
        public enum Mode: String, Sendable { case hidden, animated, `static` }
        public static func mode(hasSelection: Bool, reduceMotion: Bool) -> Mode
        public static func viewPath(for selection: Selection, transform: CanvasTransform) -> CGPath  // selection.path transformed by canvasToViewAffine
    }
    ```
    `mode`: no selection → `.hidden`; Reduce Motion → `.static`; else `.animated`.

12. **`Core/Tools/ToolContext.swift`** (extend 0006/0009): `var selection: Selection? { get }` (the document's current selection, for 0014+ selection tools). `paintClipMask` keeps its 0009 signature and now returns `selection?.mask` (an implementation may return `nil` when `mask.isFull`: `BlendOps.mul255(c, 255) == c` for all `c`, so it is pixel-identical — tested). Painting tools are unchanged: Paintbrush, Pencil, and Eraser already capture `paintClipMask` at mouse-down (TOOL-B is satisfied by feeding the hook). `PaintDotMacTests/Support/FakeToolContext.swift`: `selection` reads its `DocumentState.selection`; `paintClipMask` becomes `get { clipMaskOverride ?? state.selection?.mask } set { clipMaskOverride = newValue }` so 0009/0011 tests that assign it still compile and pass.

### Platform glue (AppKit; covered by UI tests and manual checks)

13. **`Canvas/CanvasToolSession.swift`** (extend): `selection` → `undoBridge.state.selection`; `paintClipMask` → as above.

14. **`Canvas/MarchingAntsOverlay.swift`** (new) — `final class MarchingAntsOverlay: NSView`, layer-backed, same frame as `CanvasView`, inserted in the canvas container **above `CanvasView` and below `ToolOverlayView`**, `hitTest(_:) → nil`.
    - Two `CAShapeLayer`s with `path = MarchingAnts.viewPath(...)`, no fill, `lineWidth` 1: a solid white layer and on top a black layer with `lineDashPattern = [4, 4]`. Layers' `contentsScale` = window backing scale; implicit animations disabled for path changes (`CATransaction.setDisableActions(true)`).
    - `.animated`: a `CABasicAnimation(keyPath: "lineDashPhase")` from 0 to `phasePeriod`, `duration` 0.5 s, `repeatCount = .infinity`, on the black layer (render-server driven, no per-frame main-thread work). `.static`: remove the animation, phase 0. `.hidden`: both paths `nil`.
    - `func update(selection: Selection?, transform: CanvasTransform)`, called by `DocumentWindowController` (a) when `onStateChange` reports `change.affectsSelection`, (b) after `UndoBridge.reset` (open / Revert), (c) after every transform change (the same hook where 0006 redraws `ToolOverlayView`), and (d) when Reduce Motion changes.
    - Reduce Motion: `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, observed via `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` on `NSWorkspace.shared.notificationCenter`; in `#if DEBUG` builds a `-UITestReduceMotion YES|NO` launch argument overrides it (item 17).
    - Accessibility: the view is an accessibility element with identifier `canvas.marchingAnts`, label "Selection Outline", value = `Mode.rawValue` (`"hidden"`, `"animated"`, `"static"`) so UI tests can assert CAN-7/NF-7.

15. **`Document/DocumentWindowController.swift`** (extend):
    - Creates and owns the `MarchingAntsOverlay`; extends 0008's `onStateChange` switch for the new cases: `.pixels` → unchanged; `.selection` → ants only (no tile upload); `.pixelsAndSelection` → tiles + ants; `.structure` → unchanged + ants.
    - Responder-chain actions (target nil from the menu; the window controller sits in the main window's chain, so they work while a floating panel is key): `@objc func selectAll(_:)`, `@objc func deselect(_:)`, `@objc func invertSelection(_:)`. Each: if `AppModel.dispatcher.isGestureInProgress` → return; call `undoBridge.prepareForNavigation?()` (commit the active tool's pending edit; once 0020 lands, this call carries `PendingEditReason.command`, so floating pixels record "Finish Pixels" before the selection step, while undo/redo/jump/save never finish them; nothing in this spec changes for that); `if let item = command.makeHistoryItem(for: undoBridge.state) { undoBridge.perform(item) }`.
    - `validateMenuItem(_:)` (or `validateUserInterfaceItem`): enabled iff `!isGestureInProgress && command.isEnabled(in: undoBridge.state)`. A focused text field (options bar) keeps handling ⌘A itself, as it is first in the key window's chain.

16. **`App/MainMenu.swift`** (extend 0001): Edit menu, after the existing **Select All** (⌘A, `selectAll(_:)`), add **Deselect** (key `d`, ⌘, action `deselect(_:)`) and **Invert Selection** (key `i`, ⌘, action `invertSelection(_:)`), target nil. Identifiers `menu.edit.selectAll`, `menu.edit.deselect`, `menu.edit.invertSelection`. (0018 inserts Erase Selection / Fill Selection between Deselect and Invert Selection, as in Paint.NET's Edit menu.)

17. **`App/LaunchOptions.swift`** + `AppDelegate` (extend 0001; `#if DEBUG` use only, parser always compiled and unit-tested):
    - `-UITestSelectRect "x,y,w,h"` → `initialSelectionRect: PixelRect?` (four comma-separated integers, `w, h > 0`; anything else → `nil`, ignored). After each `-UITestOpen` document finishes loading, the app sets its initial state to `DocumentState(image:, selection: Selection(rect:canvasSize:))` through `undoBridge.reset(state:base: .openImage)` — not a history step, document stays clean. Lets UI tests exercise clipping before 0014 adds selection tools.
    - `-UITestReduceMotion YES|NO` → `reduceMotionOverride: Bool?` (same boolean parsing as `-UITestResetDefaults`).
18. `project.yml`: no target changes; run `xcodegen generate` after adding files. No PRD.md change is needed: the product decisions this spec relies on (empty selection = none, Deselect/Invert disabled without a selection, selection steps mark the document edited, the two debug hooks) are already PRD E-3, §4 Testing, and D-40.

### Performance (NF-1, NF-4)
- Select All and Deselect are O(tile count) with no pixel storage; Invert touches only partial tiles. Clipping costs one tile-enum lookup + `mul255` per painted pixel. NF-4: a selection step costs only the partial mask tiles it does not share (65,536 B each) plus a small path estimate.
- Targets on a 4000×3000 canvas (192 tiles), Debug test build, gated at 3×: Select All < 5 ms; Invert of an ellipse selection < 50 ms; rasterizing a full-canvas ellipse < 100 ms; a Paintbrush segment with an ellipse selection stays within 0009's NF-1 gate (48 ms mean per event).

## Acceptance criteria
- [ ] The five combine modes follow the normative table exactly for all 65,536 `(a, b)` pairs. → `SelectionCombineModeTests.exhaustiveTable`
- [ ] Selection algebra holds on masks: A∪A = A, A∩A = A, A∖A = ∅, A⊕A = ∅, invert twice = identity, De Morgan, A⊕B = (A∪B)∖(A∩B) per pixel, union/intersect commutative and associative, replace = operand. → `SelectionAlgebraPropertyTests.*`
- [ ] Tile fast paths (empty/full) give the same coverage as the per-pixel algebra. → `SelectionMaskTests.fastPathsMatchPerPixelOracle`
- [ ] Masks normalize (all-0 → empty, all-255 → full), keep out-of-canvas bytes 0, and compute tight bounds. → `SelectionMaskTests.normalization`, `.edgeTileOutOfCanvasStaysZero`, `.boundsAreTight`
- [ ] Rasterization puts shapes at the right place in canvas coordinates (y down), across tile boundaries, with exact rectangle coverage and antialiased curved edges. → `MaskRasterizerTests.*`
- [ ] Selection paths combine with CoreGraphics booleans; inverted selections include the canvas border; empty results are `nil`. → `SelectionTests.*`
- [ ] With no selection the whole image is editable; Select All paints pixel-identically to no selection. → `SelectionClippingIntegrationTests.noSelectionPaintsEverywhere`, `.selectAllIsPixelIdenticalToNoSelection`
- [ ] Paintbrush, Pencil, and Eraser change only pixels inside the selection, scaled by edge coverage (TOOL-B). → `SelectionClippingIntegrationTests.paintbrushClippedToRect`, `.paintbrushAntialiasedEdgeScales`, `.pencilClippedToRect`, `.eraserClippedToRect`, `.invertedSelectionClipsOutside`; real app → `SelectionUITests.testPaintingIsClippedToSelection`
- [ ] Select All ⌘A, Deselect ⌘D, Invert Selection ⌘I exist in the Edit menu with those titles and shortcuts; Deselect and Invert are disabled without a selection; Select All is enabled with a document. → `MainMenuTests.editMenuSelectionItems`, `SelectionCommandTests.enablement`, `SelectionUITests.testMenuEnablementAndShortcuts`
- [ ] Each command is one history step named "Select All" / "Deselect" / "Invert Selection" with icons `.selectAll`/`.deselect`/`.invertSelection`; undo/redo restore the exact selection; no-op commands add no step. → `SelectionCommandTests.*`, `SelectionHistoryIntegrationTests.*`, `SelectionUITests.testSelectionStepsInHistory`
- [ ] Selection steps report `.selection` (no tile re-upload); `HistoryChange.merged` follows the table; snapshot items carry the selection. → `HistoryChangeTests.mergeTable`, `SelectionHistoryItemTests.*`, `SelectionHistoryIntegrationTests.snapshotItemRestoresSelection`
- [ ] Selection history cost counts only unshared mask tiles and path estimates. → `HistoryCostTests.selectionBytes*`
- [ ] Marching ants are drawn along the selection outline through `CanvasTransform`, animated normally, static under Reduce Motion, hidden without a selection (CAN-7, NF-7). → `MarchingAntsTests.*`, `CanvasTransformTests.canvasToViewAffineMatchesFunction`, `SelectionUITests.testAntsModeFollowsSelection`, `SelectionUITests.testReduceMotionMakesAntsStatic`; look → manual
- [ ] The new launch hooks parse as specified. → `LaunchOptionsTests.selectRect*`, `.reduceMotion*`
- [ ] Performance targets met within the 3× gate. → `SelectionPerformanceTests.*`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report. → quality-gate launch smoke (`quality-gate.sh`)

## Edge cases
- **1×1 image:** Select All → one `.full` tile, bounds (0,0,1,1); invert → `nil`; paint clipped correctly. → `SelectionTests.oneByOneCanvas`
- **Non-multiple-of-256 sizes (e.g. 300×257) and wide strips (65,535×1):** edge tiles keep out-of-canvas bytes 0 through invert/combine; `.full` edge tiles report 255 only in-canvas; `coverage` outside size = 0. → `SelectionMaskTests.edgeTileOutOfCanvasStaysZero`, `.wideStripGrid`
- **Largest images:** Select All / Deselect / Invert-of-Select-All on 65,535×65,535 allocate no tile bytes (`partialTileCount == 0`) and finish quickly. → `SelectionMaskTests.hugeSelectAllHasNoStorage`
- **Paths outside or partly outside the canvas, zero-area, or non-finite:** clipped to the canvas; nothing left → `nil` (no selection, no crash). → `SelectionTests.pathOutsideCanvasIsNil`, `.zeroAreaPathIsNil`, `.nonFiniteRectIsNil`, `.partlyOutsideIsClipped`
- **Combination producing nothing** (A⊕A, A∖A, disjoint ∩, invert of full) → `nil`. → `SelectionTests.emptyResultsAreNil`
- **Size mismatch** between masks/selections: returns the existing value unchanged (no trap). → `SelectionMaskTests.sizeMismatchReturnsSelf`, `SelectionTests.sizeMismatchReturnsExisting`
- **Shape spanning 4 tiles** (rect (250,250,20,20)) → correct coverage on both sides of each tile seam. → `MaskRasterizerTests.rectAcrossTileSeams`
- **Semi-transparent pixels** under a partial-coverage edge: the Paintbrush result uses straight-alpha Normal with `Sa = mul255(color.a, mul255(strokeCov, maskCov))` (0009). → `SelectionClippingIntegrationTests.paintbrushAntialiasedEdgeScales`
- **Command during a stroke / with a pending edit:** during a mouse gesture the items are disabled and actions no-op; otherwise the pending edit commits first (its own step), then the selection step. → `SelectionUITests` covers enabled states; commit ordering → `SelectionHistoryIntegrationTests.pendingStrokeCommitsBeforeCommand` (Core sequence with `FakeToolContext` + `PaintbrushTool.commit` then the command item)
- **Undo of a paint step does not change the selection, undo of a selection step does not change pixels.** → `SelectionHistoryIntegrationTests.pixelAndSelectionUndoAreIndependent`
- **Budget folding (H-5) over selection steps**: folded steps' selections remain correct at the base. → `SelectionHistoryIntegrationTests.budgetFoldingKeepsSelectionState`
- **Text field focused:** ⌘A selects the field's text, not the image (responder chain). → manual (focus-dependent responder behavior; covered by a quick check).
- **Zoom extremes (1 %, 3200 %) and 1×/2× backing scale:** ants path follows the transform. → `MarchingAntsTests.viewPathAtZoomExtremes`; look → manual
- **Revert To Saved / reopen:** selection reset to `nil`; ants hidden. → `SelectionUITests.testAntsModeFollowsSelection` (reopen path) + manual Revert
- **Document dirty state:** a selection step makes the document edited; undoing back to the saved step makes it clean again (0008 rules). → `UndoBridgeTests.selectionStepTogglesEdited`

## Test plan
- **Unit — `PaintDotMacTests/Model/SelectionCombineModeTests.swift`:**
  - `exhaustiveTable`: for all `a, b ∈ 0…255`, each mode equals the table computed inline in the test (`b`, `max`, `a − min`, `min`, `max − min`).
  - `displayNames`: `["Replace", "Add (Union)", "Subtract", "Intersect", "Invert (Xor)"]` in `allCases` order.
- **Unit — `PaintDotMacTests/Model/SelectionMaskTests.swift`** (oracle: a per-pixel `[UInt8]` reference mask in the test target, `ReferenceMask`):
  - `emptyAndFull`: `init(size: 300×300)` → `isEmpty`, bounds `.zero`, `coverage(299,299) == 0`; `.full(size: 300×300)` → `isFull`, `coverage(299,299) == 255`, `coverage(300,0) == 0`, `coverage(-1,0) == 0`, bounds (0,0,300,300), `partialTileCount == 0`.
  - `normalization`: builder with all 255 → every tile `.full`; all 0 → `.empty`; one pixel 1 at (10,10) → tile (0,0) `.partial`, others `.empty`, bounds (10,10,1,1).
  - `boundsAreTight`: coverage non-zero only at (5,7) and (600,300) on 700×400 → bounds (5,7,596,294).
  - `edgeTileOutOfCanvasStaysZero`: 300×257, random partial mask (seeded) → after `inverted()` and `combined(.xor, with: full)`, every storage byte at tile-local positions outside the canvas is 0; in-canvas bytes equal `255 − v`.
  - `wideStripGrid`: 65,535×1 full mask → 256 tiles, `coverage(65_534, 0) == 255`, `(65_535, 0) == 0`.
  - `invertTwiceIsIdentity` (fixed example; the property version is below).
  - `fastPathsMatchPerPixelOracle`: for every mode and every pair of tile kinds (empty, full, partial random, partial at an edge tile), result coverage equals `ReferenceMask` per pixel.
  - `unchangedTilesShareStorage`: `a.combined(with: empty, .union)` → each partial tile's storage `===` a's; `inverted()` of an all-empty/full mask allocates nothing.
  - `hugeSelectAllHasNoStorage`: `.full(65_535×65_535).inverted()` → `isEmpty`, `partialTileCount == 0` (and Select All has `tileStorageIdentities.isEmpty`).
  - `sizeMismatchReturnsSelf`: 100×100 mask combined with a 50×50 mask (every mode) → `==` the original.
  - `conformsToBrushClipMask`: `(mask as any BrushClipMask).coverage(x:y:)` equals `coverage`, `bounds` equals `bounds`.
- **Unit — `PaintDotMacTests/Model/MaskRasterizerTests.swift`:**
  - `integerRectIsExact` (antialiased and aliased): rect (10,20,5,5) on 64×64 → exactly 25 pixels 255 at x 10…14, y 20…24; all others 0 (proves no Y flip: y 20…24 counted from the top).
  - `halfPixelRectCoverage`: rect (10.5, 0, 2, 1) antialiased → (10,0) = 128 (`255 × 0.5 = 127.5` → 128), (11,0) = 255, (12,0) = 128, (9,0) = 0, (13,0) = 0; quarter-pixel corner (0.25,0.25,…) → `round(255 × 0.75 × 0.75)` = 143 at (0,0).
  - `aliasedRectUsesPixelCenters`: rect (10.4, 0, 2.2, 1) aliased → columns `ceil(9.9) = 10 ..< ceil(12.1) = 13` → x 10,11,12 are 255; 9 and 13 are 0.
  - `rectAcrossTileSeams`: rect (250,250,20,20) on 512×512 → pixels (250…269, 250…269) are 255 in all four tiles, (249,250) and (270,250) are 0; tiles (0,0),(1,0),(0,1),(1,1) `.partial`.
  - `triangleOrientation` (general path, catches Y flips): wedge (0,0)→(100,0)→(100,10) on 128×128 → pixel (95,2) == 255, (95,97) == 0, (2,95) == 0.
  - `circleAntialiased`: circle center (64,64) r 40 on 128×128 → pixels with center distance < 39 are 255, > 41 are 0, edge pixels strictly between 0 and 255 exist; Σ coverage / 255 within 0.5 % of π·40².
  - `circleAliasedIsBinary`: same circle aliased → every value ∈ {0, 255}; 255-pixel count within 1 % of π·40².
  - `largeCircleSpanningManyTiles`: circle r 1000 on 4000×3000 → interior tiles `.full`, far tiles `.empty`, edge tiles `.partial`.
  - `emptyAndNonFiniteInputs`: empty path, NaN-containing path, 0×0 size → empty mask, no crash.
  - `hugeRectUsesTileShortcut`: integer rect (0,0,65_535,65_535) on 65,535×65,535 (both modes) → `isFull`, `partialTileCount == 0`; rect (100,100,1000,1000) on 4000×3000 → tiles fully inside `.full`, tiles crossed by an edge `.partial`, coverage equals the per-pixel formula at every pixel of the edge tiles.
- **Unit — `PaintDotMacTests/Model/SelectionTests.swift`:**
  - `selectAll`: 300×200 → path bounding box (0,0,300,200), `mask.isFull`, bounds (0,0,300,200).
  - `rectInitClipsToCanvas` / `partlyOutsideIsClipped`: rect (−10,−10,30,30) on 100×100 → bounds (0,0,20,20), path bounding box (0,0,20,20).
  - `pathOutsideCanvasIsNil`, `zeroAreaPathIsNil` (a line path), `nonFiniteRectIsNil`, `emptyResultsAreNil` (A⊕A, A∖A, disjoint ∩, `all().inverted()`).
  - `invertedIncludesCanvasBorder`: rect (10,10,20,20) on 100×100 inverted → path bounding box (0,0,100,100); `path.contains((5,5))` true, `contains((20,20))` false; mask (20,20) 0, (5,5) 255.
  - `combinePaths`: A = rect (0,0,40,40), B = rect (20,20,40,40) on 100×100 → union contains (10,10) and (50,50), bbox (0,0,60,60); exclude contains (10,10), not (30,30) nor (50,50); intersect contains (30,30) only, bbox (20,20,20,20); xor contains (10,10) and (50,50), not (30,30); replace == B. Masks: union bounds (0,0,60,60) with (30,30)=255; xor (30,30)=0, (10,10)=255.
  - `nilOperandsActAsEmpty`: `combine(nil, B, .union)` == B (mask), `combine(nil, B, .exclude)` == nil, `combine(nil, B, .intersect)` == nil, `combine(nil, B, .xor)` mask == B's; `combine(A, nil, .union)` == A.
  - `sizeMismatchReturnsExisting`: `combine(A100, B50, .union, canvasSize: 100×100)` == A100.
  - `oneByOneCanvas`, `equalityUsesMaskAndPath`, `maskOutlineInit` (`init?(mask:outline:)` stores the mask unchanged; empty mask → nil).
- **Property — `PaintDotMacTests/Model/SelectionAlgebraPropertyTests.swift`** (`SeededRandom`, 200 iterations, seed printed on failure; random masks on random sizes 1…700 × 1…700 made of random tile kinds, random bytes, and random rects/ellipses rasterized through `MaskRasterizer`): `unionIdempotent`, `intersectIdempotent`, `excludeSelfIsEmpty`, `xorSelfIsEmpty`, `invertTwiceIsIdentity`, `deMorgan` (both forms), `xorEqualsUnionMinusIntersect` (per pixel `xor = union − intersect`), `excludePlusIntersectIsA`, `unionIntersectCommutativeAssociative`, `replaceIsOperand`, `matchesReferenceOracle` (every mode vs `ReferenceMask` per pixel); and on `Selection` values: `selectionInvertTwiceRestoresMask`, `combineResultNilIffMaskEmpty`.
- **Unit — `PaintDotMacTests/History/HistoryChangeTests.swift`** (extend 0008's): `mergeTable` — every pair of the five shapes (pixels, selection, pixelsAndSelection, structure, plus a second pixels with different tiles) gives the table result and is symmetric; `affectsSelection` and `pixelTiles` per case.
- **Unit — `PaintDotMacTests/History/SelectionHistoryItemTests.swift`:** `applyRevert` (state with image + selection A; item before A after B → apply gives B, image tiles `sharesStorage` unchanged; revert gives A); `noOpWhenEqual` (A→A, nil→nil); `changeIsSelection`; `byteCost` equals `HistoryCost.selectionBytes`.
- **Unit — `PaintDotMacTests/History/HistoryCostTests.swift`** (extend): `selectionBytesSelectAll` (nil → all = `all.pathByteEstimate`; the test counts path elements itself with `applyWithBlock` and checks `64 + 32 × n`); `selectionBytesPartialTiles` (ellipse (0,0,512,512) on 512×512 → 4 partial tiles; nil → it = 4 × 65,536 + estimate); `selectionBytesSharedStorage` (A → A.combined(with: emptyOperand…) sharing storage → only path estimates); `snapshotIncludesSelection` (`unsharedTileBytes` of states differing only in selection == `selectionBytes`).
- **Unit — `PaintDotMacTests/Operations/SelectionCommandTests.swift`:** `names` ("Select All", "Deselect", "Invert Selection") and `icons`; `enablement` (no selection: selectAll true, deselect false, invert false; with selection: all true); `selectAllItem` (nil → item after == `Selection.all`); `selectAllWhenAllSelectedIsNoOp` (returns nil); `deselectItem` (A → nil); `deselectWithoutSelectionIsNil`; `invertItem` (rect A → after mask == `A.mask.inverted()`); `invertOfAllDeselects` (after == nil, item non-nil, name "Invert Selection").
- **Unit — `PaintDotMacTests/Rendering/CanvasTransformTests.swift`** (extend): `canvasToViewAffineMatchesFunction` — for zooms {0.01, 0.5, 1, 3, 32}, backing {1, 2}, 100 seeded points: `p.applying(affine)` equals `canvasToView(p)` within 1e-9.
- **Unit — `PaintDotMacTests/Rendering/MarchingAntsTests.swift`:** `modeTable` (nil → hidden regardless of reduceMotion; selection + reduceMotion false → animated; true → static); `constants` (dash [4,4], period 8, duration 0.5, width 1); `viewPathFollowsTransform` (rect selection (10,10,20,20), transform zoom 2 backing 2 → view path bbox == `canvasRectToView((10,10,20,20))` standardized); `viewPathAtZoomExtremes` (1 % and 3200 % → bbox matches `canvasToView` of the corners, finite).
- **Unit — `PaintDotMacTests/App/LaunchOptionsTests.swift`** (extend): `selectRectParses` ("10,20,30,40" → (10,20,30,40)); `selectRectRejects` ("10,20,0,5", "a,b,c,d", "1,2,3", missing value → nil, and the next argument still parses normally); `reduceMotionParses` (YES/true/1 → true, NO → false, absent → nil); existing cases unchanged.
- **Unit — `PaintDotMacTests/App/MainMenuTests.swift`** (extend 0001's): `editMenuSelectionItems` — Edit menu contains, in order after "Select All" (⌘A, `selectAll:`), "Deselect" (key "d", `.command`, action `deselect:`) and "Invert Selection" (key "i", `.command`, `invertSelection:`), with identifiers `menu.edit.selectAll/deselect/invertSelection`; no other item uses ⌘D or ⌘I.
- **Unit — `PaintDotMacTests/Document/UndoBridgeTests.swift`** (extend): `selectionStepTogglesEdited` (perform Select All → `onEditedChange(true)`, undo → `false`); `selectionChangeCallback` (`onStateChange` receives `.selection`).
- **Integration — `PaintDotMacTests/Integration/SelectionClippingIntegrationTests.swift`** (headless: `FakeToolContext` with an opaque white 100×100 "Background", `HistoryStack`, real tools; expected pixels hand-computed from 0009's formulas):
  - `noSelectionPaintsEverywhere`: Paintbrush black, width 6, hardness 100, AA, drag (2.5,50.5)→(97.5,50.5) → (5,50) and (95,50) `(0,0,0,255)`.
  - `paintbrushClippedToRect`: selection = rect (40,0,20,100); same stroke → (45,50) black; (35,50) and (65,50) white `(255,255,255,255)`; (40,50) and (59,50) black; (39,50) and (60,50) white.
  - `paintbrushAntialiasedEdgeScales`: selection = rect (40.5,0,20,100) (edge pixel 40 coverage 128) → (40,50): effCov = `mul255(255,128)` = 128, `Sa = 128`, 0009 Normal over opaque white: `fa = 128·255 + 255·127 = 65025`, `outA = 255`, `outC = (255·255·127 + 32512) / 65025 = 127` → `(127,127,127,255)`; (41,50) black; (60,50) also `(127,127,127,255)`; (39,50) and (61,50) white.
  - `selectAllIsPixelIdenticalToNoSelection`: same random stroke (seeded) on two copies, one with `Selection.all`, one without → identical tiles; and `mul255(c, 255) == c` for all `c`.
  - `pencilClippedToRect`: Pencil (0.5,10.5)→(99.5,10.5) with rect (40,0,20,100) → only x 40…59 on row 10 changed.
  - `eraserClippedToRect`: Eraser width 10, primary alpha 255, rect (40,0,20,100) → (50,50) `(0,0,0,0)`-erased per 0011 (`a == 0`), (30,50) unchanged white.
  - `invertedSelectionClipsOutside`: rect (40,0,20,100) inverted → stroke changes (5,50), not (50,50).
  - `clipCapturedAtMouseDown`: change the fake's selection mid-stroke → the stroke still uses the mouse-down mask (0009 contract).
- **Integration — `PaintDotMacTests/Integration/SelectionHistoryIntegrationTests.swift`** (UndoBridge or `HistoryStack` + `DocumentState`): `selectAllDeselectInvertSession` (Select All → Invert (→ nil) → undo → undo → redo → redo; after each, `state.selection` equals the expected value and step names are `["Open Image", "Select All", "Invert Selection"]`); `noOpCommandsAddNoStep` (Deselect with none, Select All twice); `pixelAndSelectionUndoAreIndependent` (rect select → paint → undo paint: selection still rect; undo select: pixels unchanged vs after-undo-paint); `snapshotItemRestoresSelection` (a `DocumentSnapshotHistoryItem` whose before has selection A and after nil → revert restores A); `budgetFoldingKeepsSelectionState` (tiny budget, several selection + paint steps → after folding, undo to base gives the selection of the last folded step); `pendingStrokeCommitsBeforeCommand`; `randomSessionUndoRedoIdentity` (property, seeded, 100 sessions of random commands/strokes/rect selections: undo all then redo all reproduces identical tiles and `==` selections at every step).
- **UI tests — `PaintDotMacUITests/SelectionUITests.swift`** (`UITestApp`; 200×200 opaque white PNG fixture):
  - `testMenuEnablementAndShortcuts`: open fixture → Edit menu "Select All" enabled, "Deselect" and "Invert Selection" disabled; ⌘A → "Deselect" and "Invert Selection" enabled, "Undo Select All" present; ⌘D → disabled again, "Undo Deselect".
  - `testSelectionStepsInHistory`: ⌥⌘2 (History panel) → ⌘A, ⌘I, ⌘Z → `historyRow.1` label "Select All", `historyRow.2` label "Invert Selection" value "undone"; ⌘D after the undo → `historyRow.2` label "Deselect".
  - `testAntsModeFollowsSelection`: `canvas.marchingAnts` value "hidden" → ⌘A → "animated" → ⌘I (inverting all → none) → "hidden" → ⌘Z → "animated".
  - `testReduceMotionMakesAntsStatic`: launch with `extraArguments: ["-UITestReduceMotion", "YES"]` → ⌘A → value "static".
  - `testPaintingIsClippedToSelection`: launch with `["-UITestSelectRect", "50,50,100,100"]` → `canvas.marchingAnts` "animated"; B; width 20 via `toolOptions.width`; drag horizontally across the whole canvas view through its vertical center (normalized x 0.02→0.98, y 0.5; the image is centered by the initial transform, so this crosses image row 100); ⌘S, read the PNG → (100,100) `(0,0,0,255)`, (20,100) and (180,100) white. ⌘I; drag vertically through the center (x 0.5, y 0.02→0.98); ⌘S, read → (100,20) and (100,180) black, (100,60) white (inside the original rect, now deselected).
- **Performance — `PaintDotMacTests/Performance/SelectionPerformanceTests.swift`** (XCTest `measure` + explicit timing, gated at 3× the targets above, numbers reported in Verification status): `selectAll4000x3000`, `invertEllipse4000x3000`, `rasterizeEllipse4000x3000`, `paintbrushSegmentWithSelection` (0009's width-50 segment benchmark with an ellipse selection installed).
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build, zero warnings, all tests pass with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open a photo, ⌘A: black/white dashed ants run around the image edge and visibly move; at 100 % on a Retina display the line is crisp and sits exactly on the image border; zoom to 3200 % and 10 %, pan: ants stay glued to the edge with no lag or jitter.
  2. System Settings › Accessibility › Display › Reduce motion on: ants stop moving immediately (no relaunch); off: they resume.
  3. Launch a Debug build with `-UITestSelectRect 50,50,300,200`, paint across the edge with a soft wide brush: the edge is smooth (antialiased), nothing changes outside; ⌘I and paint: only outside changes; the ants show both the rectangle and the canvas border.
  4. Click the options-bar width field and press ⌘A: the field text is selected and no "Select All" history step appears.
  5. Dark mode and light mode: ants are visible on white, black, and mid-grey images.
  6. Activity Monitor: with a selection on screen and the app idle, CPU stays near 0 % (animation runs in the render server).

## Open questions
None. The four questions an earlier draft raised (empty selection = no selection; Deselect and Invert Selection disabled without a selection, Select All a no-op when everything is selected; selection steps mark the document edited; the `-UITestSelectRect` / `-UITestReduceMotion` debug hooks) are settled by PRD E-3, §4 Testing, and D-40, and the spec applies them as written above.

## Out of scope
- Selection tools and their options (Selection Mode picker, modifier keys, Paint.NET's Ctrl/Alt/right-button mapping, Pixelated/Antialiased quality, blue selection tint while a selection tool is active, Enter / click-off-canvas to deselect), Zoom to Selection ⇧⌘B, and the status-bar selection size → **0014** (Rectangle/Ellipse, `SelectionToolOptions`), **0015** (Lasso), **0016** (Magic Wand, `FloodFill`, mask outline tracing).
- Paint.NET's per-tool "Selection Clipping Mode" (pixelated vs antialiased clipping): v1.0 always clips with the 8-bit antialiased mask (AGENTS rule 8, FX-D).
- Erase Selection / Fill Selection → **0018**; Move Selection → **0019**; Move Selected Pixels and floating pixels → **0020**; Cut/Copy/Paste → **0021**; Crop to Selection → **0022**; Gradient/Paint Bucket/effects clipping → **0023**, **0017**, **0031** (they read `DocumentState.selection` / `paintClipMask`).
- Transforming or dropping the selection on canvas-size changes → the specs that change the canvas size (0022, 0035–0037).
- Saving selections in files (Paint.NET doesn't; `.ora` has no selection).
- Shortcut-table centralization → **0045**; VoiceOver audit → **0049**.
