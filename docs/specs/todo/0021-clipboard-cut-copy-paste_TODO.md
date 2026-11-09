# 0021 — Add Cut, Copy, Paste, and Paste into New Image through the system clipboard

> Source: PRD.md §5.6 E-2 (part a: Cut, Copy, Paste, Paste into New Image), E-5 (copy writes PNG + TIFF; paste reads PNG → TIFF → file URLs), E-6 (paste larger than the canvas prompts to expand), E-3 (empty selection = no selection), APP-9 / D-30 (clipboard DPI ignored), APP-10 / D-8 / D-32 (image limits), FMT-B (input converted to sRGB; color under alpha 0 kept), §5.12 (⌘X/⌘C/⌘V, Paste into New Image ⌥⌘V), §3 use case 4, §12 D-11. Paint.NET: https://paint.net/doc/latest/EditMenu.html (Cut, Copy, Paste, Paste into New Image; see *Paint.NET behavior* below).
> Milestone: M2
> Depends on: 0018-erase-and-fill-selection, 0020-move-selected-pixels (and through them 0001–0009, 0013, 0014, 0019)

## Context

Today (after 0001–0020):
- 0001's `App/MainMenu.swift` already has Edit > **Cut** ⌘X `cut(_:)`, **Copy** ⌘C `copy(_:)`, **Paste** ⌘V `paste(_:)`, all with target nil. Nothing implements them, so they are always disabled (0001 `LaunchUITests.testMenuBarAndPlaceholderEnablement`).
- 0002 provides `ImageDecoder.decode(_:limits:) throws(ImageCodecError) -> DecodedImage` (ImageIO → straight sRGB RGBA8, ICC conversion, CMYK/gray/16-bit/float → 8-bit, first frame, EXIF orientation, color under alpha 0 kept for straight sources), `ImageLimits` / `ImageLimitError`, `ImageCodecError` (whose `exceedsMemoryCap` row explicitly lets 0021 add its own wording), `TiledSurface.readPixels(in:)` / `writePixels(_:to:)` / `init(size:rgba8:bytesPerRow:)`, and `UITestFixtures` (UI-test fixture writers).
- 0005 provides `ImageEncoder.encode(_ surface:size:dpi:as: .png)` (straight RGBA, sRGB profile, DPI), `NewImageDefaults` / `NewImageRequest.makeImage()` (white "Background" layer), `PaintDocumentController` (`newDocument(_:)` reads `.png`/`.tiff` from `NSPasteboard.general` for the New Image dialog size), `PaintDocument.imageLimits`, and the UI-test helpers `UITestApp.setPasteboardImage(width:height:)`, `clearPasteboard()`, `saveThroughPanel(directory:name:)`, `decodePNG(at:)`.
- 0008 provides `HistoryItem`, `TileDiffHistoryItem`, `DocumentSnapshotHistoryItem`, `CompositeHistoryItem`, `HistoryIcon` (already has `.cut` and `.paste`), `UndoBridge` (`perform`, `commit`, `reset(state:base:)`, `prepareForNavigation`).
- 0013 provides `Selection` (`init?(rect:canvasSize:)`, `mask: SelectionMask`, `bounds`; `nil` = no selection), `SelectionHistoryItem`, `HistoryChange.selection`/`.pixelsAndSelection`, `SelectionCommand`, and the pattern for Edit-menu actions in `DocumentWindowController` (ignore while `AppModel.shared.dispatcher.isGestureInProgress`; call `undoBridge.prepareForNavigation?()` first; `validateMenuItem`).
- 0009 provides `BlendOps.mul255(_:_:)` (the one 8-bit multiply rounding rule).
- 0018 provides `Core/Operations/EraseSelection.swift`: `EraseSelection.erase(_ surface: TiledSurface, mask: SelectionMask?) -> (surface: TiledSurface, touched: Set<TileCoordinate>)` (selected pixels → alpha scaled by `255 − coverage`, fully erased → `(0,0,0,0)`), `EraseSelection.erasePixel(_:coverage:)`, and `makeHistoryItem(for:)` (the "Erase Selection" composite of a `TileDiffHistoryItem` and a deselecting `SelectionHistoryItem`).
- 0020 provides (all reused, none redefined here): `Core/Model/FloatingPixels.swift` — `FloatingPixels` stored in `DocumentState.floatingPixels` (so undo/redo restores it), with `FloatingPixels.paste(_ surface: TiledSurface, at origin: PixelPoint, into state: DocumentState, baseStepID: HistoryStep.ID) -> FloatingPixels` (identity session, `underlay` = the active layer unchanged, `outline = Selection(rect:canvasSize:)` of the pasted rect) and `render(into:region:)` (Normal blend of the resampled source over `underlay`); `Core/History/FloatingPixelsHistoryItem.swift` — `FloatingPixelsHistoryItem(name:before:after:)` and `MoveSelectedPixelsHistory` (`finishStepName` "Finish Pixels", `stepStartsSession(_:id:)`, which also finds the session start inside a `CompositeHistoryItem`); `Core/Tools/FloatingPixelsPolicy.swift` (`toolToActivate(hasFloatingPixels:activeTool:)`, applied by `DocumentWindowController` after every `onStateChange`, so Move Selected Pixels becomes active whenever pixels float); `PendingEditReason` and `UndoBridge.pendingEditReason` / `prepareForSave()` (commands calling `undoBridge.prepareForNavigation?()` get reason `.command`, which records **"Finish Pixels"** before the command's own step; undo/redo/jump/save never finish floating pixels); `Core/Tools/MoveSelectedPixelsTool.swift` (drag/nudge steps "Move Pixels" / "Scale Pixels" / "Rotate Pixels"; Escape cancels the whole floating session by jumping back to `restore.baseStepID`).

What is missing: no clipboard support at all. Paste into New Image (⌥⌘V) doesn't exist in the menu.

### Paint.NET behavior mirrored (EditMenu.html)
- **Copy (Ctrl+C):** copies the selected region of the active layer; the selection stays. "If there is no selection, the entire layer will be copied."
- **Cut (Ctrl+X):** "remove a selected portion of the active layer AND store a copy of it in the clipboard"; the selection is cleared afterward.
- **Paste (Ctrl+V):** pastes onto the active layer; "Pixels being pasted will overwrite existing pixels in the same location." The pasted pixels become selected and the **Move Selected Pixels** tool activates automatically. If the image is too large for the canvas, "a prompt will appear asking if the canvas should be resized." When zoomed in, "the pixels will be placed within the current viewport, regardless of where it originally came from."
- **Paste into New Image (Ctrl+Alt+V):** creates a new image "exactly the same size as the clipboard image", makes it active, then pastes the clipboard contents into it.
- Copy Merged and Paste into New Layer are **0030**.

## User story

As a PaintDotMac user, I can select part of my image and press ⌘C or ⌘X to put it on the Mac clipboard (as PNG with transparency and as TIFF), paste it with ⌘V as floating pixels I can immediately drag with Move Selected Pixels, be asked whether to expand the canvas when the pasted image is bigger than my canvas, and press ⌥⌘V to turn any clipboard image (from Preview, a screenshot, Finder-copied image file, or another app) into a new document. Undo takes each of these back in one step.

## Scope & changes

### Core (pure, unit-tested; no AppKit)

1. **`PaintDotMac/Core/IO/ClipboardImageCodec.swift`** (new) — PNG/TIFF bytes ↔ surfaces, the read order of E-5, and the "can paste" decision.
   ```swift
   public struct ClipboardImage: Equatable, Sendable {
       public var surface: TiledSurface          // straight sRGB RGBA8, size == surface.size
       public var size: PixelSize { get }
   }

   /// What the pasteboard offers, captured by the platform glue. Pure value; tests build it directly.
   public struct ClipboardContents: Sendable {
       public var pngData: Data?
       public var tiffData: Data?
       public var fileURLs: [URL]                // in pasteboard order; only file URLs
       public init(pngData: Data? = nil, tiffData: Data? = nil, fileURLs: [URL] = [])
   }

   public enum ClipboardReadError: Error, Equatable, Sendable {
       case noImage                              // nothing decodable
       case limitExceeded(ImageLimitError)       // the first candidate that hit the limits
   }

   public enum ClipboardImageCodec {
       /// Pasteboard type identifiers the app writes and reads, in read order.
       public static let pngType = "public.png"
       public static let tiffType = "public.tiff"
       public static let fileURLType = "public.file-url"

       /// E-5 write side: (png, tiff) encodings of `surface`. PNG through 0005's ImageEncoder (straight
       /// RGBA, sRGB profile, `dpi`); TIFF through CGImageDestination (UTType.tiff) from the same CGImage.
       public static func encode(_ surface: TiledSurface, dpi: Double) throws(ImageCodecError) -> (png: Data, tiff: Data)

       /// E-5 read side. Order: pngData → tiffData → each file URL in order (read through `readFile`).
       /// The first candidate that decodes wins. Each candidate goes through 0002's
       /// `ImageDecoder.decode(_:limits:)`, so ICC/CMYK/16-bit/float/gray input becomes 8-bit sRGB and
       /// EXIF orientation is applied (FMT-B). The decoded DPI is ignored (D-30).
       public static func read(_ contents: ClipboardContents, limits: ImageLimits,
                               readFile: (URL) throws -> Data) -> Result<ClipboardImage, ClipboardReadError>

       /// Cheap menu-enablement test (no decoding): true iff `types` contains pngType or tiffType, or any
       /// `fileURLTypes` element conforms to UTType.image.
       public static func canPaste(types: [String], fileURLTypes: [UTType]) -> Bool
   }
   ```
   - `read` details: a candidate that throws `.unrecognizedFormat` or `.corrupt`, or a file URL whose `readFile` throws, is skipped and the next one is tried. A candidate that throws `.limitExceeded(e)` is remembered (first one only) and the next is tried. If no candidate decodes: return `.limitExceeded(firstLimitError)` if one was remembered, else `.noImage`. Empty `Data` counts as unrecognized. File URLs are read in order and only until the first success (later URLs are never read).
   - `encode` details: reuse 0005's straight-RGBA → `CGImage` construction (extract it from `ImageEncoder` into an `internal static func makeCGImage(_ surface: TiledSurface, size: PixelSize) throws(ImageCodecError) -> CGImage` in `ImageEncoder.swift`; PNG output of `ImageEncoder.encode` must stay byte-identical, which 0005's tests already cover). TIFF: `CGImageDestinationCreateWithData(…, UTType.tiff.identifier, 1, nil)`, properties DPI width/height = `dpi`, no compression key (ImageIO default). `CGImageDestinationFinalize == false` → `.encodingFailed`. The PNG keeps alpha exactly (E-5 "PNG (with alpha)"); the TIFF may premultiply internally (ImageIO's choice), so it is exact only for opaque pixels and within ±1 per channel after un-premultiplying for alpha ≥ 128 (tested; PNG is the lossless carrier).
   - `canPaste` must not decode anything; it runs on every menu validation.

2. **`PaintDotMac/Core/Operations/ClipboardCopy.swift`** (new; pure Copy/Cut pixel logic. Kept separate from PastePlanner because it is the write side).
   ```swift
   public enum ClipboardCopy {
       /// Copy (E-2): the pixels to put on the clipboard.
       /// - selection == nil → the whole active layer (size == image.size), pixels unchanged (including the
       ///   color under alpha 0).
       /// - selection != nil → a surface of size selection.bounds.size; for each pixel p in bounds with
       ///   coverage c = selection.mask.coverage(p) and active-layer pixel s:
       ///   c == 0 → (0,0,0,0); otherwise (s.r, s.g, s.b, BlendOps.mul255(s.a, c)).
       ///   Output (0,0) corresponds to canvas (bounds.x, bounds.y).
       public static func copiedSurface(from state: DocumentState) -> TiledSurface

       /// Cut (E-2): enabled iff state.selection != nil. Returns the clipboard surface (same as Copy) and one
       /// history item named "Cut", icon .cut:
       /// CompositeHistoryItem(name: "Cut", icon: .cut, items: [
       ///     TileDiffHistoryItem(name: "Cut", icon: .cut, diff: TileDiff.between(before: layer.surface,
       ///         after: erased.surface, layerID: layer.id, candidates: erased.touched)),
       ///     SelectionHistoryItem(name: "Cut", icon: .cut, before: selection, after: nil)])
       /// where erased = EraseSelection.erase(layer.surface, mask: selection.mask) (0018) on the active layer.
       /// Returns nil when there is no selection.
       public static func cut(_ state: DocumentState) -> (surface: TiledSurface, item: any HistoryItem)?
   }
   ```
   - Copy is never a history step and never changes the document.
   - Cut: if Erase Selection would change no pixels (the selected region is already transparent black), the composite still contains the deselect, so it is still one step "Cut" (the selection changed). It is never a no-op while a selection exists.
   - The pixel part is built only with 0018's `EraseSelection.erase(_:mask:)`; don't reimplement the erase math, and don't reuse 0018's `makeHistoryItem` (its step is named "Erase Selection"; this one must be **"Cut"**).

3. **`PaintDotMac/Core/Operations/PastePlanner.swift`** (new) — placement and the E-6 expand decision.
   ```swift
   public enum PasteCanvasChoice: Sendable { case expandCanvas, keepCanvasSize }

   public struct PastePlan: Equatable, Sendable {
       public var newCanvasSize: PixelSize?      // nil = canvas unchanged
       public var origin: PixelPoint             // top-left of the pasted pixels in (new) canvas coordinates
       public var pastedRect: PixelRect          // PixelRect(origin: origin, size: clipboardSize)
   }

   public enum PastePlanner {
       /// E-6: true iff clipboard width > canvas width or clipboard height > canvas height.
       public static func needsExpansionPrompt(clipboardSize: PixelSize, canvasSize: PixelSize) -> Bool

       /// Placement (Paint.NET "placed within the current viewport"):
       /// - choice == .expandCanvas (only meaningful when needsExpansionPrompt): newCanvasSize =
       ///   (max(cw, iw), max(ch, ih)), anchored top-left; origin = (0, 0).
       /// - otherwise: origin = (0, 0) if canvas point (0, 0) lies inside `visibleCanvasRect` (closed on the
       ///   top-left edges); else origin = (clamp(floor(visible.minX), 0, cw − 1), clamp(floor(visible.minY), 0, ch − 1)).
       /// `visibleCanvasRect` is 0003's CanvasTransform.visibleCanvasRect (canvas coordinates, y down).
       /// A nil choice means "no prompt was needed"; it behaves like .keepCanvasSize.
       public static func plan(clipboardSize: PixelSize, canvasSize: PixelSize,
                               visibleCanvasRect: CGRect, choice: PasteCanvasChoice?) -> PastePlan

       /// E-6 expansion as a document snapshot step (anchor top-left). Every layer grows to newSize with
       /// existing pixels at the same coordinates; the new area of the bottom layer (index 0) is filled with
       /// `background` (the secondary color), other layers' new area stays transparent (0,0,0,0). Layer ids,
       /// names, visibility, opacity, blend mode, dpi, and activeLayerIndex are kept. The selection is set to
       /// nil in the snapshot's after-state (the paste replaces it anyway). Validates newSize with `limits`.
       public static func expandedState(_ state: DocumentState, to newSize: PixelSize,
                                        background: ColorRGBA8, limits: ImageLimits) throws(ImageLimitError) -> DocumentState
   }
   ```
   **Decision (expand fill color):** the bottom layer's new area is the **secondary color** and every other layer's new area is transparent — Paint.NET's Resize Canvas convention. 0036 (Resize Canvas, not yet written) must use the same rule and may refactor `expandedState` to call its `ResizeCanvas` with anchor top-left; the behavior must stay the same.

4. **`PaintDotMac/Core/Operations/PasteStep.swift`** (new) — the "Paste" history step, built only from 0020's types (no parallel floating model).
   ```swift
   public enum PasteStep {
       public static let name = "Paste"
       /// `state` = the document before the paste (no floating pixels: the caller ran prepareForNavigation first).
       /// `expanded` = PastePlanner.expandedState(...) when the user chose Expand, else nil.
       /// `baseStepID` = the history's current step ID before the paste.
       public static func makeHistoryItem(surface: TiledSurface, plan: PastePlan, state: DocumentState,
                                          expanded: DocumentState?, baseStepID: HistoryStep.ID) -> CompositeHistoryItem
   }
   ```
   - `s0 = expanded ?? state`; `floating = FloatingPixels.paste(surface, at: plan.origin, into: s0, baseStepID:)` (0020; `underlay` = `s0`'s active layer unchanged; `outline` = the pasted rect clipped to the canvas, never `nil` because `plan.origin` is inside the canvas).
   - `rendered` = `s0`'s active-layer surface with `floating.render(into:region: floating.destinationBounds)` applied — 0020's model: **the layer always shows the floating pixels** (Normal blend over the unchanged layer, Open question 4); `floating.underlay` keeps the pre-paste layer, so moving the pasted pixels reveals the original pixels, never a hole.
   - Item = `CompositeHistoryItem(name: "Paste", icon: .paste, items: [DocumentSnapshotHistoryItem(name: "Paste", icon: .paste, before: state, after: expanded!)` **only when expanding**`, TileDiffHistoryItem(name: "Paste", icon: .paste, diff: TileDiff.between(before: s0 layer surface, after: rendered, layerID:, candidates: tiles of floating.destinationBounds)), SelectionHistoryItem(name: "Paste", icon: .paste, before: s0.selection, after: floating.outline), FloatingPixelsHistoryItem(name: "Paste", before: nil, after: floating)])`. One step: undo reverts the four parts in reverse order (floating state, selection, pixels, then the canvas size), redo re-applies them. (`expanded!` stands for the non-nil branch; write it with `if let`.)
   - Because the composite contains `FloatingPixelsHistoryItem(before: nil, after: floating)`, 0020's `stepStartsSession` recognizes the Paste step as the start of the floating session.

   **Floating-paste behavior (all of it 0020's, listed for the tests):**
   - After the step, `DocumentState.floatingPixels == floating` and 0020's `FloatingPixelsPolicy` (applied by `DocumentWindowController` after the step's `onStateChange`) makes **Move Selected Pixels** active; this spec doesn't call `selectTool` itself. If Move Selected Pixels was already active with floating pixels, `prepareForNavigation` (reason `.command`) recorded "Finish Pixels" before the paste.
   - Dragging/nudging moves the pasted pixels as 0020 does ("Move Pixels", "Scale Pixels", "Rotate Pixels").
   - Return, Finish, a tool switch, and any command record 0020's **"Finish Pixels"** (no pixel or selection change: the layer already shows them); pixels outside the canvas are dropped then. Undo, redo, History jumps, and save never finish (save writes the layer, which already shows the pasted pixels).
   - **Escape** cancels the whole floating session (0020): it jumps back to the step before "Paste", so pixels, selection, canvas size, and layers equal the pre-paste state, and "Paste" (plus any later moves) becomes redoable. (If H-5 folded the Paste step into the base step, 0020's fallback records a "Move Pixels" step restoring the pre-paste layer of the possibly expanded canvas and the selection before the paste — `nil` when the canvas was expanded.)
   - **One undo right after Paste restores the exact pre-paste state:** pixels, selection, canvas size, layers, `floatingPixels == nil`. Redo restores the floating paste exactly (same origin, same pixels; Move Selected Pixels reselected by the policy).

5. **`Core/Rendering/CanvasTransform+Navigation.swift`** (extend 0004) — **created here** because Paste with Expand is the first operation that changes the canvas size; 0022 (crop) and 0035–0037 reuse it unchanged:
   `func withImageSize(_ size: PixelSize) -> CanvasTransform` — same `viewSize`, `backingScale`, and **zoom**; `imageSize = size`; `center = (size.width / 2, size.height / 2)`; then `clampedScroll()`. Returns `self` when `size == imageSize` (no scroll jump on structure changes that keep the size, e.g. layer ops). Zoom rule: Open question 5.

### Platform glue (AppKit; covered by integration and UI tests)

6. **`PaintDotMac/Document/ClipboardController.swift`** (new) — `@MainActor final class ClipboardController`, the only code that touches `NSPasteboard` for images (0005's `PaintDocumentController.newDocument(_:)` is changed to read through it too).
   ```swift
   @MainActor final class ClipboardController {
       static let shared = ClipboardController(pasteboard: .general)
       init(pasteboard: NSPasteboard)                         // tests pass NSPasteboard.withUniqueName()
       func write(_ surface: TiledSurface, dpi: Double) throws(ImageCodecError)   // clearContents, one NSPasteboardItem with .png and .tiff data
       var canPaste: Bool { get }                             // ClipboardImageCodec.canPaste(types:fileURLTypes:)
       func contents() -> ClipboardContents                   // data(forType: .png), data(forType: .tiff), readObjects(forClasses: [NSURL], options: [.urlReadingFileURLsOnly: true])
       func readImage(limits: ImageLimits) -> Result<ClipboardImage, ClipboardReadError>   // contents() → ClipboardImageCodec.read(readFile: Data(contentsOf:))
       var changeCount: Int { get }                           // pasteboard.changeCount (lets canPaste cache per changeCount)
   }
   ```
   - `canPaste` file-URL check uses `UTType(filenameExtension:)` / `resourceValues(forKeys: [.contentTypeKey])` of each URL; no file is opened. Cache the result per `changeCount` so menu validation stays cheap.
   - `write` puts exactly the two types `public.png` and `public.tiff` on one item (E-5), in that order.

7. **`PaintDotMac/Document/DocumentWindowController.swift`** (extend; same action pattern as 0013 item 15). Responder-chain actions `cut(_:)`, `copy(_:)`, `paste(_:)`:
   - Each: if `AppModel.shared.dispatcher.isGestureInProgress` → return; `undoBridge.prepareForNavigation?()` (reason `.command`, 0020: a floating move/paste records "Finish Pixels" first; any other tool's pending edit is committed).
   - **Copy:** `ClipboardController.shared.write(ClipboardCopy.copiedSurface(from: undoBridge.state), dpi: image.dpi)`. An encoding error → `NSAlert` (message "The selection couldn’t be copied.", informative text = error's `errorDescription`, button "OK"); nothing on the pasteboard changes in that case (encode before `clearContents`).
   - **Cut:** `ClipboardCopy.cut(state)`; write the surface first; only if writing succeeded, `undoBridge.perform(item)`. A write failure → the same alert ("The selection couldn’t be cut.") and no history step.
   - **Paste:** `readImage(limits: PaintDocument.imageLimits)`:
     - `.failure(.noImage)` → alert "The clipboard doesn’t contain an image." (no informative text), no change.
     - `.failure(.limitExceeded(e))` → alert with message "The image is too large to paste." and informative text = 0002's `ImageCodecError.limitExceeded(e).recoverySuggestion`, except that for `.exceedsMemoryCap(r, c)` it reads "Pasting it needs <r> of memory, but the limit is <c>." (same `ByteCountFormatter` formatting as 0002). No change.
     - success → if `PastePlanner.needsExpansionPrompt`: show the **E-6 alert as a window sheet**: message "The image being pasted is larger than the canvas.", informative text "Do you want to expand the canvas to fit it?", buttons in this order "Expand canvas" (default, Return), "Keep canvas size", "Cancel" (Escape). Accessibility identifiers on the buttons: `pasteExpand.expand`, `pasteExpand.keep`, `pasteExpand.cancel`. Cancel → nothing happens (no step, clipboard untouched). Then `PastePlanner.plan(…, visibleCanvasRect: session.transform.visibleCanvasRect, choice:)`; for expansion call `expandedState(…, background: AppModel.shared.colors.secondary, limits:)` — an `ImageLimitError` → the "too large to paste" alert, no change. Build `PasteStep.makeHistoryItem(surface:plan:state: undoBridge.state, expanded:, baseStepID: undoBridge.history.currentStepID)` (item 4) and `undoBridge.perform` it; 0020's policy then activates Move Selected Pixels.
   - `onStateChange` `.structure` branch (0008 item 12, extended here; 0022 and later canvas-size changes rely on it): before the existing image swap / `invalidateAll()` / status-bar update, if `undoBridge.state.image.size != canvasView.transform.imageSize`, set `canvasView.transform = canvasView.transform.withImageSize(undoBridge.state.image.size)` (then 0004's after-transform-change path: status-bar zoom, tool overlay, ants). The same path runs for undo/redo of an expanding Paste.
   - `validateMenuItem`: Copy enabled iff a document is open and no gesture is in progress; Cut iff additionally `state.selection != nil`; Paste iff no gesture and `ClipboardController.shared.canPaste`.

8. **`PaintDotMac/Document/PaintDocumentController.swift`** (extend 0005) — `@objc func pasteIntoNewImage(_:)` (the document controller is the last responder, so this works with or without an open document):
   - Commit the active session's pending edit (`AppModel.shared.dispatcher.commitPendingEdit()`, the `.command` path: floating pixels in the active document get "Finish Pixels"); read the image with `ClipboardController.shared.readImage(limits: PaintDocument.imageLimits)`; failures → the same alerts as Paste (app-modal, since there may be no window).
   - Success → create the document like 0005/0008's New Image path with `NewImageRequest(size: clipboard size, dpi: NewImageDefaults.fallbackDPI)` (96; the clipboard DPI is ignored, D-30): `undoBridge.reset(state: DocumentState(image: request.makeImage()), base: .newImage)`, show its window, make it main, then perform the same "Paste" step as item 7 with origin (0,0) (no prompt is possible: sizes are equal) (0020's policy activates Move Selected Pixels in the new window). Result: history rows "New Image", "Paste"; the document is edited.
   - `validateMenuItem` for it: enabled iff `ClipboardController.shared.canPaste` (with or without a document).
   - `newDocument(_:)` (0005 step 1) now gets the clipboard size from `ClipboardController.shared.contents()` → `NewImageDefaults.clipboardImageSize(pngData:tiffData:)` (unchanged rule: file URLs not considered for New Image).

9. **`PaintDotMac/App/MainMenu.swift`** (extend 0001/0013/0018). Edit menu order becomes (Paint.NET order, separators as shown):
   Undo, Redo, —, Cut ⌘X, Copy ⌘C, Paste ⌘V, **Paste into New Image** ⌥⌘V (`pasteIntoNewImage(_:)`, target nil), —, then the selection items as 0013/0018 left them. 0030 inserts Copy Merged (after Copy) and Paste into New Layer (after Paste). Identifiers: `menu.edit.cut`, `menu.edit.copy`, `menu.edit.paste`, `menu.edit.pasteIntoNewImage`. Update `MainMenuTests` (0001) for the new item and identifiers, and 0001's `LaunchUITests.testMenuBarAndPlaceholderEnablement`: with a fixture open and a cleared pasteboard, Copy is enabled, Cut is disabled, Paste is disabled.

10. **`PaintDotMacUITests/Support/UITestApp.swift`** (extend 0005's helpers): `setPasteboardImage(width:height:pixel:)` overload writing a PNG with a pixel closure (and `asTIFFOnly: Bool = false`, writing only `public.tiff`), `setPasteboardFileURL(_ url: URL)`, `setPasteboardText(_ string: String)`, and `pasteboardPNG() -> (width: Int, height: Int, rgba: [UInt8])?` (reads `public.png` from `NSPasteboard.general` in the runner and decodes it with ImageIO), `pasteboardTypes() -> [String]`. The UI tests set and read the general pasteboard themselves; no launch hook is needed.

11. `project.yml`: add the new files; run `xcodegen generate`. PRD: no change (E-2, E-5, E-6 already state the behavior; open questions below may add rows to §12).

## Acceptance criteria

- [ ] Copy with no selection puts the whole active layer on the clipboard, pixel-exact (including semi-transparent pixels and color under alpha 0). → `ClipboardCopyTests.copyWithoutSelectionCopiesWholeLayer`, `ClipboardUITests.testCopyWholeImage`
- [ ] Copy with a selection copies the selection's bounding box; pixels outside the mask are (0,0,0,0) and antialiased edge pixels have alpha `mul255(a, coverage)`; the document and history don't change. → `ClipboardCopyTests.copyRectSelection`, `.copyEllipseWeightsAlphaByCoverage`, `.copyDoesNotChangeDocument`, `ClipboardUITests.testCopySelection`
- [ ] Copy writes exactly `public.png` and `public.tiff`; the PNG decodes to the copied pixels exactly; the TIFF decodes to the same size and pixels (exact for opaque, ±1 for alpha ≥ 128). → `ClipboardImageCodecTests.encodeWritesLosslessPNG`, `.encodeTIFFRoundTrip`, `ClipboardControllerTests.writePutsPNGAndTIFF`, `ClipboardUITests.testCopyWholeImage`
- [ ] Cut copies like Copy, erases the selected pixels as Erase Selection does, deselects, and is one history step "Cut"; undo restores pixels and selection exactly; redo re-applies. Cut is disabled without a selection. → `ClipboardCopyTests.cutErasesAndDeselects`, `.cutUndoRedo`, `.cutWithoutSelectionIsNil`, `ClipboardUITests.testCutSelection`
- [ ] Paste reads PNG first, then TIFF, then file URLs in order; undecodable candidates are skipped; nothing decodable → "The clipboard doesn’t contain an image." and no change. → `ClipboardImageCodecTests.readOrder*`, `.skipsCorruptPNG`, `.noImage`, `ClipboardUITests.testPasteFromTIFFOnly`, `.testPasteFromFileURL`
- [ ] Pasted images are converted to 8-bit sRGB (Display P3, 16-bit, gray) and EXIF orientation is applied; the clipboard DPI is ignored. → `ClipboardImageCodecTests.displayP3ConvertedToSRGB`, `.sixteenBitReduced`, `.orientationApplied`, `PasteIntegrationTests.pasteIntoNewImageIgnoresClipboardDPI`
- [ ] Paste places the pixels at (0,0) when the canvas top-left is visible, otherwise at the top-left of the visible area; the pasted pixels are selected and floating (`floatingPixels.underlay` = the unchanged layer, the layer shows the pasted pixels), Move Selected Pixels is active, and history gains one step "Paste". → `PastePlannerTests.placement*`, `PasteStepTests.composition`, `PasteIntegrationTests.pasteCreatesFloatingPixels`, `ClipboardUITests.testPasteActivatesMoveSelectedPixels`
- [ ] After Paste, dragging moves the pasted pixels (revealing the original pixels), Return records "Finish Pixels"; one undo right after Paste restores the pre-paste document exactly; redo restores the floating paste; Escape cancels the whole paste. → `PasteIntegrationTests.pasteUndoRedo`, `.pasteMoveCommit`, `.pasteEscapeCancels`, `ClipboardUITests.testPasteMoveAndUndo`
- [ ] A canvas-size change keeps the zoom and re-centers the image (`withImageSize`), including undo/redo of an expanding Paste. → `CanvasTransformNavigationTests.withImageSizeKeepsZoomAndRecenters`, `.withImageSizeSameSizeIsIdentity`; UI `ClipboardUITests.testPasteLargerExpand` (`statusBar.zoom` unchanged)
- [ ] A clipboard image wider or taller than the canvas shows the E-6 prompt ("Expand canvas" / "Keep canvas size" / "Cancel"). Expand grows the canvas to max sizes anchored top-left (bottom layer's new area = secondary color, others transparent) in the same "Paste" step (one undo restores the old size); Keep pastes at the computed origin with pixels beyond the canvas clipped on commit; Cancel changes nothing. → `PastePlannerTests.needsExpansionPrompt`, `.expandPlan`, `.expandedStateFillsBottomLayer`, `PasteIntegrationTests.expandIsPartOfPasteStep`, `.keepCanvasSizeClipsOnCommit`, `ClipboardUITests.testPasteLargerExpand`, `.testPasteLargerKeep`, `.testPasteLargerCancel`
- [ ] Paste into New Image ⌥⌘V creates a new document exactly the clipboard image's size at 96 DPI with history "New Image", "Paste", works with no document open, and is disabled without a clipboard image. → `PasteIntegrationTests.pasteIntoNewImage`, `ClipboardUITests.testPasteIntoNewImageWithoutDocument`, `.testMenuEnablement`
- [ ] A clipboard image beyond `ImageLimits` (or an expansion beyond them) is refused with the "too large to paste" alert, nothing changes, nothing crashes. → `ClipboardImageCodecTests.limitExceededReported`, `PastePlannerTests.expandedStateRespectsLimits`, `ClipboardUITests.testPasteTooLarge`
- [ ] Paste and Paste into New Image are disabled when the clipboard is empty or holds only text / a non-image file URL. → `ClipboardImageCodecTests.canPaste*`, `ClipboardUITests.testMenuEnablement`
- [ ] Menu: Edit has Cut ⌘X, Copy ⌘C, Paste ⌘V, Paste into New Image ⌥⌘V in that order with the listed identifiers. → `MainMenuTests.editMenuClipboardItems`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **1×1 image / 1×1 selection:** Copy yields a 1×1 PNG; Paste of 1×1 onto any canvas works, no prompt.
- **Selection partly outside the layer content / transparent region:** Copy still yields a `bounds`-sized image (all transparent is fine; never an empty image, because a `Selection` is never empty, 0013).
- **Clipboard image exactly the canvas size:** no prompt (strict `>`), origin per placement rule.
- **Only one side larger** (e.g. 900×100 onto 800×600): prompt; Expand → 900×600.
- **Zoomed in / scrolled so that (0,0) is off-screen:** origin = floor of the visible top-left, clamped to `0…cw−1`/`0…ch−1`; the pasted rect may extend beyond the canvas; its selection is clipped to the canvas by `Selection(rect:)`.
- **Canvas smaller than the view (visible rect has negative min):** (0,0) is inside → origin (0,0).
- **Paste while a floating paste/move is pending:** `prepareForNavigation` (reason `.command`) records "Finish Pixels" first, then the new "Paste" step follows.
- **Paste during a mouse gesture:** ignored (menu disabled; key equivalent no-op).
- **Copy while pixels float:** records "Finish Pixels" first (0020: every command finishes), then copies from the layer (which already shows the moved pixels).
- **Clipboard with corrupt PNG and valid TIFF:** TIFF used. **Corrupt PNG and TIFF and an image file URL:** file used. **Several file URLs, first is a text file:** skipped, the first image file used. **File URL to a deleted file:** skipped.
- **Huge clipboard images:** the 0002 decoder validates header dimensions before allocating, so a 70,000-px-wide PNG or one above the memory cap is refused without allocation (limit error alert). Expansion to a size above the cap → same alert, no change.
- **Clipboard premultiplied TIFF (from other apps):** decoded through 0002's documented un-premultiply rounding; fully transparent pixels become (0,0,0,0).
- **Pasteboard write failure / encode failure:** alert, history unchanged (Cut does not erase).
- **Undo/redo across Paste with expansion:** undo restores the old canvas size, layers, selection, and pixels; the status bar size updates (`.structure`).
- **Hidden active layer:** Copy/Cut/Paste still operate on it (Paint.NET does); no special case.
- **No document open:** Cut/Copy/Paste disabled (no responder implements them); Paste into New Image enabled when the clipboard has an image.
- **Pasteboard changes while the app is in the background:** `canPaste` is re-evaluated by `changeCount` on the next validation.

## Test plan

- **Unit tests**
  - `PaintDotMacTests/IO/ClipboardImageCodecTests.swift`:
    - `encodeWritesLosslessPNG`: 3×2 surface with pixels (255,0,0,255), (0,255,0,128), (0,0,255,1), (10,20,30,0), (255,255,255,255), (0,0,0,0) → `encode(dpi: 72)`; decode the PNG with `ImageDecoder.decode` → identical bytes; the PNG has an sRGB profile (`CGImageSourceCopyPropertiesAtIndex` profile name contains "sRGB").
    - `encodeTIFFRoundTrip`: same surface → TIFF decodes to 3×2; opaque pixels exact; (0,255,0,128) within ±1; type identifier of the TIFF data is `public.tiff`.
    - `readOrderPrefersPNG`: PNG of a 2×2 red image and TIFF of a 3×3 blue image → 2×2 red. `readOrderFallsBackToTIFF`: `pngData = Data("junk".utf8)` → the TIFF image. `readOrderFallsBackToFileURL`: no PNG/TIFF, fileURLs [text file, PNG file] → the PNG file's image; `readFile` is called for exactly those two URLs, in order. `readStopsAtFirstSuccess`: two image file URLs → the first; the second is never read (recording closure).
    - `skipsCorruptPNG`: truncated PNG (0002's `TestImages` + truncation) and valid TIFF → TIFF result.
    - `noImage`: empty contents → `.noImage`; text-only file URL → `.noImage`; `readFile` throwing → `.noImage`.
    - `limitExceededReported`: PNG from `TestImages.pngHeaderOnly(width: 70_000, height: 10)` → `.limitExceeded(.dimensionsOutOfRange(70000, 10))`; with `ImageLimits(memoryCapBytes: 100)` and a 10×10 PNG → `.limitExceeded(.exceedsMemoryCap(requiredBytes: 400, capBytes: 100))`; huge PNG followed by a valid TIFF → the TIFF wins.
    - `displayP3ConvertedToSRGB`: a Display P3 PNG of pure P3 red (255,0,0) → sRGB pixel equals what 0002's decoder returns for the same data (same pipeline) and red > 250, green == 0 (P3 red is outside sRGB → clipped).
    - `sixteenBitReduced`: 16-bit RGBA PNG with 0xFFFF/0x8080 values → 255/128. `grayExpanded`: 8-bit gray 77 → (77,77,77,255) (via sRGB-tagged gray as in 0002's tests).
    - `orientationApplied`: 2×1 JPEG-free PNG with orientation 6 (via `TestImages.encode(properties:)`) → result size 1×2.
    - `canPaste`: `["public.png"]` → true; `["public.tiff"]` → true; `["public.utf8-plain-text"]` → false; `[]` → false; file URL types `[.png]` → true, `[.plainText]` → false, `[.plainText, .jpeg]` → true.
  - `PaintDotMacTests/Operations/ClipboardCopyTests.swift`:
    - `copyWithoutSelectionCopiesWholeLayer`: 300×300 layer (crosses a tile edge) with a seeded random pattern including alpha 0 with non-zero color → `copiedSurface` bytes equal the layer's bytes.
    - `copyRectSelection`: 600×400 pattern `(x%256, y%256, (x+y)%256, 255)`, selection `Selection(rect: (250, 100, 20, 30), antialiased: false)` → 20×30 surface; pixel (0,0) == source (250,100); (19,29) == source (269,129).
    - `copyEllipseWeightsAlphaByCoverage`: opaque (200,100,50,255) layer 64×64, ellipse selection (0013 path init) → surface size == `selection.bounds.size`; for every pixel, alpha == `mask.coverage` at the matching canvas pixel (oracle: `(255 * c + 127) / 255` written in the test as the 0009 rule, i.e. compare with `BlendOps.mul255(255, c)` computed independently by the formula); where coverage 0 the pixel is (0,0,0,0); where coverage > 0 the RGB is (200,100,50).
    - `semiTransparentSourceTimesCoverage`: source alpha 128, coverage 128 → alpha `mul255(128,128) == 64`.
    - `copyDoesNotChangeDocument`: state before == state after (pixels, selection).
    - `cutErasesAndDeselects`: rect selection on an opaque image → returned surface equals Copy's; applying the item: selected pixels (0,0,0,0) (matching 0018's Erase Selection result on the same state — compare with 0018's function output), pixels outside unchanged, `selection == nil`; item name "Cut", icon `.cut`, `isNoOp == false`.
    - `cutOfTransparentRegionIsStillAStep`: all-transparent layer with selection → item not a no-op (selection changes).
    - `cutUndoRedo`: `HistoryStack.perform` then `undo` → state identical to before (pixels and selection `==`); `redo` → identical to after.
    - `cutWithoutSelectionIsNil`.
  - `PaintDotMacTests/Operations/PastePlannerTests.swift`:
    - `needsExpansionPrompt`: (800×600 canvas) 800×600 → false; 801×600 → true; 800×601 → true; 10×10 → false.
    - `placementTopLeftVisible`: visible (−50,−20,1000,800) → origin (0,0). `placementZoomedIn`: visible (300.7, 120.2, 100, 80) → origin (300,120). `placementVisibleBeyondCanvas`: visible (900, 700, 50, 50) on 800×600 → origin (799, 599). `placementTopLeftEdgeInclusive`: visible (0,0,10,10) → (0,0).
    - `expandPlan`: canvas 800×600, clipboard 1000×500, `.expandCanvas` → newCanvasSize 1000×600, origin (0,0), pastedRect (0,0,1000,500). `keepPlan`: `.keepCanvasSize` → newCanvasSize nil.
    - `expandedStateFillsBottomLayer`: 2-layer 300×200 image (bottom opaque red, top a single blue pixel at (299,199)), expand to 600×300 with background (0,255,0,255) → bottom: (0..<300, 0..<200) red, (300,0) and (0,200) green; top: (299,199) blue, (300,0) == (0,0,0,0); layer ids/names/opacity/visibility/blend mode/activeLayerIndex and dpi unchanged; selection nil.
    - `expandedStateRespectsLimits`: `ImageLimits(memoryCapBytes: 1000)` and newSize 100×100 → throws `.exceedsMemoryCap`.
- **Round-trip / property tests** (`PaintDotMacTests/IO/ClipboardRoundTripTests.swift`): over 25 seeds from `SeededRandom` (seed printed on failure): random size 1…600, random RGBA (20% alpha 0 with random RGB) → `ClipboardImageCodec.encode` → `read(ClipboardContents(pngData:))` → identical bytes; same via `read(ClipboardContents(tiffData:))` → same size, opaque pixels identical. Copy→Paste identity: random rect selection (non-antialiased) → `copiedSurface` → `encode` → `read` → bytes equal the layer region.
- **Integration tests** (headless; `PaintDotMacTests/Integration/PasteIntegrationTests.swift`, `@MainActor`, using `UndoBridge` + `ClipboardController(pasteboard: .withUniqueName())` + 0020's tool with `FakeToolContext` where a tool is needed):
  - `copyWritesBothTypes` / `ClipboardControllerTests.writePutsPNGAndTIFF`: after `write`, `pasteboard.types` == [.png, .tiff] (as the first item's types), `canPaste == true`; the PNG decodes to the written pixels.
  - `pasteCreatesFloatingPixels`: 400×300 white image, clipboard 50×40 opaque red; perform the Paste path with visible rect covering the canvas → history names ["Open Image", "Paste"]; `selection.bounds == (0,0,50,40)`; `floatingPixels.underlay` all white and `floatingPixels.sourceRect == (0,0,50,40)`; the layer shows red at (0,0)…(49,39) and white elsewhere; `FloatingPixelsPolicy` → active tool `.moveSelectedPixels` (dispatcher with a `FakeToolContext` backed by the bridge).
  - `pasteUndoRedo`: undo → layer white, selection nil, `floatingPixels == nil`, history at "Open Image"; redo → floating state `==` the one before undo, layer red at (0,0)…(49,39).
  - `pasteEscapeCancels`: Paste, drag +10 px ("Move Pixels"), Escape → `currentIndex` back at "Open Image", layer all white, selection nil, `floatingPixels == nil`, two redo steps ("Paste", "Move Pixels").
  - `pasteMoveCommit`: after Paste, drive 0020's tool: drag from (10,10) to (110,60), commit → layer red exactly at (100..<150, 50..<90), white at (0,0) (nothing was erased under the original paste position), selection bounds (100,50,50,40).
  - `expandIsPartOfPasteStep`: 300×200 canvas, clipboard 400×250, choice `.expandCanvas`, secondary (0,0,0,255) → after Paste: size 400×250, history ["Open Image", "Paste"]; commit (0020) → red covers (0..<400, 0..<250); undo of the commit step and the Paste step → size 300×200 and original pixels (`==` the original `LayeredImage`).
  - `keepCanvasSizeClipsOnCommit`: same, `.keepCanvasSize` → size 300×200, selection bounds (0,0,300,200); commit → every pixel red; no crash; tiles outside the canvas never allocated.
  - `pasteIntoNewImage`: clipboard 123×45 with a 72-DPI pHYs and pattern pixels → new document state size 123×45, dpi 96 (`pasteIntoNewImageIgnoresClipboardDPI`), history ["New Image", "Paste"], after commit the layer equals the pattern for opaque pixels.
  - `pasteWithPendingFloatingCommitsFirst`: Paste, Paste again → history ["Open Image", "Paste", "Finish Pixels", "Paste"].
  - `PaintDotMacTests/Operations/PasteStepTests.swift` — `composition`: 8×6 state, 3×2 surface at (1,1), no expansion → item name "Paste", icon `.paste`, 3 sub-items (TileDiff, Selection, FloatingPixels), `MoveSelectedPixelsHistory.stepStartsSession` true for the step and the floating id; `withExpansion` → 4 sub-items, the first a `DocumentSnapshotHistoryItem`; `apply` then `revert` on a `DocumentState` → `==` the original (image, selection, `floatingPixels`).
  - `PaintDotMacTests/Rendering/CanvasTransformNavigationTests.swift` (extend 0004's): `withImageSizeKeepsZoomAndRecenters`: 4000×3000 at zoom 0.5 in view 800×600 → `withImageSize(1000×500)`: zoom 0.5, image 500×250 device px fits → center (500, 250), `canvasToView((500,250)) == (400,300)`; `withImageSize(3000×3000)` at zoom 1 → center clamped per 0004 rules (check `canvasToView((1500,1500)) == (400,300)`); `withImageSizeSameSizeIsIdentity`: returns an equal transform (center unchanged after a pan).
  - `cutThenPasteRoundTrip`: select (20,20,30,30), Cut, Paste (origin (0,0)), commit → layer at (0..<30,0..<30) equals the original (20..<50,20..<50) pixels, and (20..<50) region outside the pasted area is (0,0,0,0).
- **UI tests** (`PaintDotMacUITests/ClipboardUITests.swift`; fixtures generated at test time via `UITestApp`/`UITestFixtures`; each test sets the general pasteboard itself and clears it in `tearDown`):
  - `testMenuEnablement`: `clearPasteboard()`, launch with a 64×48 PNG → Edit menu: Copy enabled, Cut disabled, Paste disabled, Paste into New Image disabled; `setPasteboardText("hi")` → Paste still disabled; `setPasteboardImage(width: 10, height: 10)` → Paste and Paste into New Image enabled; launch with `-UITestSelectRect 0,0,10,10` → Cut enabled.
  - `testCopyWholeImage`: fixture 64×48 with pattern pixels and some alpha 128 pixels; ⌘C → `pasteboardTypes()` contains "public.png" and "public.tiff"; `pasteboardPNG()` is 64×48 with exactly the fixture's bytes.
  - `testCopySelection`: launch with `-UITestSelectRect 10,5,20,15`; ⌘C → pasteboard PNG 20×15 whose (0,0) equals fixture (10,5); History panel still has only "Open Image".
  - `testCutSelection`: `-UITestSelectRect 10,5,20,15`; ⌘X → History row "Cut"; `canvas.marchingAnts` value "hidden"; pasteboard PNG 20×15; ⌘S (via the 0005 flow for PNG) → saved pixel (15,10) is (0,0,0,0), (0,0) unchanged; ⌘Z → History shows "Cut" greyed / undone and ants "animated" again.
  - `testPasteActivatesMoveSelectedPixels`: 200×150 white fixture; `setPasteboardImage(width: 30, height: 20)` (red) ; ⌘V → History row "Paste"; tool `tool.moveSelectedPixels` is selected (accessibility value/selected state as 0006 exposes it); `statusBar.selectionSize` shows 30 × 20; ants "animated".
  - `testPasteMoveAndUndo`: after ⌘V, `dragOnCanvas` from the pasted area's center by a positive offset; press Return; ⌘S → the red block is at the moved position and white at (0,0). Second pass: ⌘V then ⌘Z → History shows only "Open Image" active, saved pixels all white.
  - `testPasteFromTIFFOnly`: `setPasteboardImage(width: 30, height: 20, asTIFFOnly: true)` → ⌘V works ("Paste" row).
  - `testPasteFromFileURL`: write a 25×25 PNG with `UITestFixtures.writePNG`, `setPasteboardFileURL(url)` → ⌘V → "Paste", selection size 25 × 25.
  - `testPasteLargerExpand`: 64×48 fixture, clipboard 100×80; note `statusBar.zoom` → ⌘V → alert with "Expand canvas", "Keep canvas size", "Cancel"; click `pasteExpand.expand` → `statusBar.imageSize` reads 100 × 80 and `statusBar.zoom` is unchanged; ⌘Z → 64 × 48.
  - `testPasteLargerKeep`: click `pasteExpand.keep` → size stays 64 × 48, History "Paste".
  - `testPasteLargerCancel`: click `pasteExpand.cancel` (and second pass: Escape) → no "Paste" row, size unchanged.
  - `testPasteTooLarge`: launch with `-UITestMemoryCapBytes 40000` (0002 hook), clipboard 200×200 → ⌘V → alert "The image is too large to paste."; OK → no history change. ⌥⌘V → same alert, no new window.
  - `testPasteIntoNewImageWithoutDocument`: launch with no document, `setPasteboardImage(width: 123, height: 45)`; ⌥⌘V → a new document window, `statusBar.imageSize` 123 × 45, History rows "New Image", "Paste"; Return; ⌘S via `saveThroughPanel` → decoded PNG is 123×45 with the clipboard's pixels.
- **Unit — menu** (`PaintDotMacTests/App/MainMenuTests.swift`, extend): `editMenuClipboardItems`: titles/order "Cut", "Copy", "Paste", "Paste into New Image"; key equivalents `x`/`c`/`v` with ⌘ and `v` with ⌥⌘; actions `cut(_:)`, `copy(_:)`, `paste(_:)`, `pasteIntoNewImage(_:)`; identifiers as listed; `noDuplicateShortcuts` still passes.
- **Performance:** none of NF-1…NF-4 are targeted. Sanity integration check `pasteLargeImageIsReasonable`: paste a 4000×3000 opaque image (PNG generated in the test) through `read` + Paste in < 3 s on Debug (gross-regression gate only; report the measured time).
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build without warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. In Preview, copy a selection from a photo (⌘C); in PaintDotMac ⌘V → it pastes at the visible top-left and can be dragged; Return commits.
  2. Take a screenshot to the clipboard (⌃⇧⌘4); ⌥⌘V → a new image of the screenshot's pixel size, colors look identical to the screen.
  3. In Finder, copy an image file (⌘C); ⌘V in PaintDotMac → the image pastes.
  4. Copy a semi-transparent selection in PaintDotMac and paste into Pixelmator/Preview (File > New from Clipboard): transparency is preserved.
  5. Copy from a Display P3 image in another app → pasted colors match visually.
  6. The E-6 sheet reads naturally, Return chooses "Expand canvas", Escape cancels.

## Open questions

Decided as stated (recommended answers applied); the batch owner should confirm and record them in PRD §12. (Not questions: the expand fill color is a stated decision in item 3; the floating state lives in `DocumentState` per 0020.)

1. **Cut's erase color and selection.** Paint.NET's EditMenu.html says Cut leaves *transparent white* (#FFFFFF, alpha 0) and clears the selection, while Erase Selection leaves *transparent black*. This spec makes Cut = 0018's Erase Selection pixels (transparent black, D-27 "full erase → transparent black") + Deselect, as one step "Cut". Recommended: keep transparent black (both are invisible; one rule app-wide) and deselect as Paint.NET does.
2. **Cut without a selection.** Paint.NET's docs don't say. This spec disables Cut when nothing is selected (so ⌘X can never silently clear a whole layer), while Copy copies the whole layer. Recommended: yes.
3. **Paste into New Image background.** Following "creates a new image, then pastes", the new image has 0005's white "Background" and the clipboard pixels float above it, so transparent clipboard pixels end up over white. Alternative: the new image's single layer is the clipboard pixels themselves (transparency kept, history base only). Recommended: Paint.NET-faithful (white background + "Paste" step).
4. **Pasted pixels composite (Normal) over the layer instead of overwriting it.** Paint.NET's doc says pasted pixels "will overwrite existing pixels"; 0020 renders floating pixels with a Normal blend over the underlay (identical for opaque clipboard images and for moved pixels, whose underlay has a transparent hole). Recommended: Normal blend (one floating-pixels rule app-wide); overwrite would need a per-session flag in 0020's `FloatingPixels`.
5. **Zoom after a canvas-size change** (Paste with Expand here; Crop in 0022; 0035–0037 later): keep the zoom percentage and re-center the image (`withImageSize`), also on undo/redo; no automatic Zoom to Window (⌘B fits on demand). Recommended: yes. (0022's Open question 2 is the same question; one answer covers both.)

## Out of scope

- Copy Merged and Paste into New Layer (E-2b) → **0030**. Drag and drop of image files → **0030**.
- Copy Selection / Paste Selection (Paint.NET's selection-outline clipboard) — not in the PRD.
- Erase Selection / Fill Selection menu items and their math → **0018** (reused here).
- Floating-pixel rendering, handles, rotation/scale, commit/cancel mechanics → **0020**.
- Resize Canvas dialog and `CanvasAnchor` → **0036** (may refactor `PastePlanner.expandedState` onto it).
- Writing other clipboard flavors (PDF, `NSImage` archives) or reading SVG/PDF from the clipboard.
- Shortcut table centralization → **0045**.
