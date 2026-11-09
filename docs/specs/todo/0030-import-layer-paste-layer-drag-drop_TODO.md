# 0030 — Add Import From File, Copy Merged, Paste into New Layer, and image-file drag and drop

> Source: PRD.md §5.4 L-6 (import an image file as a new layer), §5.6 E-2 part b (Copy Merged, Paste into New Layer), E-5 (clipboard formats, via 0021), E-6 (paste larger than the canvas prompts), §5.11 FMT-C (drop image files onto the Dock icon or the app to open them, onto an open window to add them as layers), FMT-B/FMT-D (decoding rules, via 0002/0029), APP-10 (limits), §5.12 (Paste into New Layer ⇧⌘V; general rule Ctrl → ⌘ for Copy Merged), §5.7 H-1/H-6 (step names, one step per command), §3 use case 3, §8 M3 exit criterion, §4 Rendering / D-16 (Copy Merged uses the CPU compositor), §12 D-8, D-11, D-12, D-32, D-34, D-36, D-37, D-40.
> Paint.NET docs (fetched 2026-11-05): Edit menu — https://paint.net/doc/latest/EditMenu.html (Copy Merged, Paste into New Layer); Layers menu — https://paint.net/doc/latest/LayersMenu.html (Import From File).
> Milestone: M3 (exit: use case 3 works)
> Depends on: 0021-clipboard-cut-copy-paste, 0024-layer-stack-and-compositor, 0028-openraster-save-and-open, 0029-flat-export-formats (and transitively 0001, 0002, 0008, 0012, 0013, 0020)

## Context

There is no application code yet; everything below builds on the names fixed by the earlier specs.

- **0001** `App/AppDelegate.swift` deliberately does **not** implement `application(_:open:)` ("Drops on the Dock icon and the app (FMT-C) are spec 0030", 0001 *Scope*). Debug-only `applicationDidFinishLaunching` opens `LaunchOptions.fixtureURLs` sequentially with `NSDocumentController.shared.openDocument(withContentsOf:display:true)` and `NSApp.presentError` on failure. `App/LaunchOptions.swift` parses `-UITestOpen` (repeatable) and `-UITestResetDefaults`; later specs added `-UITestMemoryCapBytes` (0002), `-UITestSelectRect`, `-UITestReduceMotion` (0013).
- **0002** `ImageDecoder.decodeImage(from:limits:) throws(ImageCodecError) -> LayeredImage` and `ImageDecoder.decode(_:limits:) -> DecodedImage` (content sniffed, ICC → sRGB, CMYK/gray/16-bit → 8-bit, EXIF orientation, first frame); `ImageCodecError` (`.unrecognizedFormat`, `.corrupt`, `.limitExceeded(ImageLimitError)`, `LocalizedError` with `errorDescription`/`recoverySuggestion`); `PaintDocument.imageLimits`; `UITestFixtures.writePNG(width:height:pixel:properties:)`, `writeJPEG`, `writeTruncatedPNG()`.
- **0005/0028/0029** `FileFormat` (`allCases`, `canRead`, `utType`, `typeIdentifier`); 0028 `OpenRasterCodec.isZipArchive(_:)` and `OpenRasterCodec.decode(_:limits:) throws(ImageCodecError) -> LayeredImage`; `PaintDocument.read(from:ofType:)` picks ORA vs. ImageDecoder by content. 0029 adds the flat formats (TIFF, BMP, GIF, HEIC read/write, WebP read) to `FileFormat` and `CFBundleDocumentTypes`, so `FileFormat.allCases.filter(\.canRead)` is the full readable list here, and maps the alias `public.heif` → `.heic` (`PaintDocument.readableTypes` appends `"public.heif"`).
- **0008** `DocumentState`, `HistoryItem`, `DocumentSnapshotHistoryItem(name:icon:before:after:)`, `CompositeHistoryItem`, `HistoryIcon` (already has `.paste` and `.importLayer`), `UndoBridge` (`state`, `perform(_:)`, `history.currentStepID`, `prepareForNavigation`).
- **0012/0024** `CPUCompositor` (`composite(_:in:) -> CompositedRegion`, `flattened(_:) -> TiledSurface`; visible layers only, layer opacity and blend mode applied).
- **0013** `Selection` (`bounds`, `mask.coverage(_:)`; `nil` = no selection).
- **0020** `FloatingPixels.paste(_:at:into:baseStepID:)`, `FloatingPixelsHistoryItem`, `MoveSelectedPixelsHistory.stepStartsSession` (finds the session start inside a `CompositeHistoryItem`), `FloatingPixelsPolicy` (Move Selected Pixels activates whenever pixels float), Escape cancels the session by jumping back before its first step, commands record "Finish Pixels" first (`prepareForNavigation`, reason `.command`).
- **0021** `Core/IO/ClipboardImageCodec.swift`, `Core/Operations/ClipboardCopy.swift` (`copiedSurface(from:)`, `cut(_:)`), `Core/Operations/PastePlanner.swift` (`needsExpansionPrompt`, `plan(clipboardSize:canvasSize:visibleCanvasRect:choice:)`, `expandedState(_:to:background:limits:)` — bottom layer's new area = secondary color, others transparent, selection → `nil`), `Core/Operations/PasteStep.swift` (`makeHistoryItem(surface:plan:state:expanded:baseStepID:) -> CompositeHistoryItem`), `Document/ClipboardController.swift` (`shared`, `write(_:dpi:)`, `canPaste`, `readImage(limits:)`), the Paste / E-6 sheet flow and alerts in `DocumentWindowController` (identifiers `pasteExpand.expand|keep|cancel`), the `.structure` branch that calls `CanvasTransform.withImageSize(_:)` when the canvas size changes, and the Edit menu order "Undo, Redo, —, Cut, Copy, Paste, Paste into New Image, —, …" with the note "0030 inserts Copy Merged (after Copy) and Paste into New Layer (after Paste)". UI-test helpers `setPasteboardImage(width:height:pixel:)`, `pasteboardPNG()`, `clearPasteboard()`.
- **0024** `LayerCommand.addNewLayer.applied(to:) -> LayeredImage?` (inserts a transparent "Layer N" at `activeLayerIndex + 1` and makes it active), `LayerNaming.newLayerName(existing:)`, `LayerCommandRunner` (commit pending edit, then perform), Layers menu with the note "0030 'Import From File…' after Merge Layer Down".
- **0025** Layers panel accessibility: `layerRow.<index>` (0 = bottom), label = layer name, value `"active"`/`"inactive"`. **0010** `historyRow.<index>` labels = step names.

What is missing: Copy Merged, Paste into New Layer, Layers > Import From File…, and every form of file drag and drop (window, Dock icon, app icon).

### Paint.NET behavior mirrored

- **Copy Merged (Ctrl+Shift+C → ⇧⌘C):** "copies all layers to the clipboard", so you don't need to flatten first. "If there is an active selection, only the region under selection will be copied. If there is no selection, the entire image is copied." (EditMenu.html). PaintDotMac copies the CPU composite of the **visible** layers (what the user sees; D-16).
- **Paste into New Layer (Ctrl+Shift+V → ⇧⌘V):** "similar to Paste, except that a new layer is created to house the clipboard image." Existing pixels are not overwritten; the new layer is placed directly above the active layer, becomes active before pasting, and stays active (EditMenu.html). The docs don't name the layer; Paint.NET adds a blank layer with the normal generic name, so it is **"Layer N"** (0024's `LayerNaming.newLayerName`). Everything else is Paste (0021): viewport placement, floating pixels with Move Selected Pixels active, and the E-6 expand prompt.
- **Import From File:** "allows one or more external image files to be imported as one or more new layers … a file selector dialog … the image is imported into the current image as a new layer or layers. Note that the canvas may be enlarged to accommodate the new image size if it is larger than the current canvas. This happens automatically as required." (LayersMenu.html). The docs don't state the name or placement; this spec names the layer after the file and places the pixels at the canvas's top-left (Open questions 1–2). No shortcut (Paint.NET has none).
- **Drag and drop:** PRD FMT-C decides it — files dropped onto an open document window become layers (the same code path as Import From File); files dropped onto the Dock icon or the app icon open as documents. (Paint.NET 4+ asks "Open or Add Layer?" on a canvas drop; the PRD chose "add as layer" without a prompt, so there is none.)

## User story

As a PaintDotMac user building a composite (use case 3), I choose Layers > Import From File… (or drag photos from Finder onto my image) and each photo arrives as its own layer named after its file, with the canvas growing if a photo is bigger; one undo takes the import back. I press ⇧⌘V to paste the clipboard image into a fresh layer and drag it into place, and ⇧⌘C to copy what I see — all visible layers merged — inside my selection. Dropping image files onto PaintDotMac's Dock icon opens each one in its own window.

## Scope & changes

### Core (pure, unit-tested; no AppKit)

1. **`PaintDotMac/Core/Operations/ClipboardCopy.swift`** (extend 0021) — Copy Merged:
   ```swift
   extension ClipboardCopy {
       /// Copy Merged (E-2b). Never a history step; never changes the document.
       /// - selection == nil → compositor.flattened(state.image) (size == image.size; hidden layers excluded;
       ///   unallocated composite tiles = transparent black).
       /// - selection != nil → surface of size selection.bounds.size; region = compositor.composite(image, in: bounds);
       ///   for each pixel p with coverage c = selection.mask.coverage(p) and composite pixel s:
       ///   c == 0 → (0,0,0,0); else (s.r, s.g, s.b, BlendOps.mul255(s.a, c)). Output (0,0) = canvas (bounds.x, bounds.y).
       public static func copiedMergedSurface(from state: DocumentState,
                                              compositor: CPUCompositor = CPUCompositor()) -> TiledSurface
   }
   ```
   The masking loop is the same as `copiedSurface(from:)`; extract a private helper `masked(_ pixels: [ColorRGBA8], bounds: PixelRect, mask: SelectionMask) -> TiledSurface` shared by both (Copy's output must stay identical; 0021's tests cover it). Floating pixels need no special case: the caller finishes them first, and the layer already shows them (0020).

2. **`PaintDotMac/Core/Operations/PasteStep.swift`** (extend 0021) — generalize the leading structural part so "Paste Into New Layer" and "Import From File" reuse the one paste-step builder (no parallel floating model):
   ```swift
   extension PasteStep {
       /// `prepared` = the structural state the paste lands in (expanded canvas and/or an added layer), or nil
       /// when the paste needs no structural change. When non-nil, the composite starts with
       /// DocumentSnapshotHistoryItem(name: name, icon: icon, before: state, after: prepared).
       /// Everything else is exactly 0021's item 4 with s0 = prepared ?? state, and every part named `name`
       /// with icon `icon`.
       public static func makeHistoryItem(surface: TiledSurface, origin: PixelPoint, state: DocumentState,
                                          prepared: DocumentState?, baseStepID: HistoryStep.ID,
                                          name: String, icon: HistoryIcon) -> CompositeHistoryItem
   }
   ```
   0021's `makeHistoryItem(surface:plan:state:expanded:baseStepID:)` becomes a one-line forward: `makeHistoryItem(surface:, origin: plan.origin, state:, prepared: expanded, baseStepID:, name: PasteStep.name, icon: .paste)`. Its output must stay identical (0021's `PasteStep`/`PasteIntegrationTests` keep passing unchanged). The floating pixels land on `prepared`'s **active** layer (0020's `paste` uses the active layer), so the prepared state must have the new layer active.

3. **`PaintDotMac/Core/Operations/PasteIntoNewLayer.swift`** (new):
   ```swift
   public enum PasteIntoNewLayer {
       public static let name = "Paste Into New Layer"   // history step name (Paint.NET history spelling)
       /// `base` = PastePlanner.expandedState(...) when the user chose Expand, else the current state.
       /// Precondition: base.floatingPixels == nil (the action ran prepareForNavigation first, 0020/0024 rule).
       /// Returns base with LayerCommand.addNewLayer applied ("Layer N", transparent, above the active layer,
       /// now active), selection and floatingPixels as in `base`.
       public static func preparedState(from base: DocumentState) -> DocumentState
       public static func makeHistoryItem(surface: TiledSurface, plan: PastePlan, state: DocumentState,
                                          expanded: DocumentState?, baseStepID: HistoryStep.ID) -> CompositeHistoryItem
       // = PasteStep.makeHistoryItem(surface:, origin: plan.origin, state:, prepared: preparedState(from: expanded ?? state),
       //                             baseStepID:, name: name, icon: .paste)
   }
   ```
   - One history step **"Paste Into New Layer"** (icon `.paste`): the snapshot part adds the layer (and grows the canvas when expanding), then 0021's pixel, selection, and floating parts on the new layer. Pixels of other layers never change. Undo removes the layer, restores the canvas size and the previous active layer and selection. Escape while floating jumps back before the step (0020), so the new layer disappears too.
   - Placement and the E-6 decision are 0021's `PastePlanner` unchanged (viewport rule; prompt when wider or taller than the canvas; Expand anchored top-left, bottom layer's new area = secondary color).

4. **`PaintDotMac/Core/Operations/ImportLayer.swift`** (new) — L-6 and the window-drop path:
   ```swift
   public struct ImportSource: Equatable, Sendable {
       public var url: URL
       public var layerName: String
       public var surface: TiledSurface        // straight sRGB RGBA8; DPI of the file ignored
   }

   public enum ImportFailureReason: Equatable, Sendable {
       case unsupportedType                     // not an image UTType we can read (txt, folder, …); file never read
       case unreadable                          // readFile threw (permissions, missing, I/O)
       case codec(ImageCodecError)              // unrecognizedFormat, corrupt, limitExceeded
   }
   public struct ImportFailure: Equatable, Sendable { public var url: URL; public var reason: ImportFailureReason }

   public struct ImportBatch: Equatable, Sendable {
       public var sources: [ImportSource]       // in input order, successes only
       public var failures: [ImportFailure]     // in input order
   }

   public enum ImportLayer {
       public static let stepName = "Import From File"
       public static let icon: HistoryIcon = .importLayer

       /// Layer name: url.deletingPathExtension().lastPathComponent; if that is empty or only whitespace,
       /// nil (the caller uses LayerNaming.newLayerName). "Beach.photo.JPG" → "Beach.photo"; ".png" → ".png"
       /// (URL treats a leading dot as part of the name).
       public static func layerName(for url: URL) -> String?

       /// True iff `type` conforms to one of `readableTypes` (FileFormat.readableUTTypes).
       public static func isImportable(_ type: UTType?, readableTypes: [UTType]) -> Bool

       /// One file's pixels. Zip archive (OpenRasterCodec.isZipArchive) → OpenRasterCodec.decode then
       /// CPUCompositor().flattened (Open question 3); otherwise ImageDecoder.decode(_:limits:).surface.
       /// Content is sniffed; the extension is never trusted.
       public static func decode(_ data: Data, limits: ImageLimits) throws(ImageCodecError) -> TiledSurface

       /// Reads and decodes each URL in order. typeOf(url) == nil or not importable → .unsupportedType
       /// (readFile not called). readFile throws → .unreadable. decode throws e → .codec(e).
       public static func load(_ urls: [URL], readableTypes: [UTType], limits: ImageLimits,
                               typeOf: (URL) -> UTType?, readFile: (URL) throws -> Data) -> ImportBatch

       /// nil when every source fits; else (max(canvas.w, max source w), max(canvas.h, max source h)).
       public static func requiredCanvasSize(for sources: [ImportSource], canvas: PixelSize) -> PixelSize?

       /// The single history step for a non-empty batch (precondition: !sources.isEmpty).
       /// - grown = requiredCanvasSize != nil ? PastePlanner.expandedState(state, to:, background:, limits:) : state
       ///   (automatic, no prompt — Paint.NET "happens automatically as required").
       /// - Exactly one source → PasteStep.makeHistoryItem(surface:, origin: (0,0), state:, prepared: P, baseStepID:,
       ///   name: stepName, icon: icon) where P = grown with LayerCommand.addNewLayer applied and the new layer
       ///   renamed to source.layerName. The pixels float (Move Selected Pixels becomes active via 0020's policy),
       ///   selection = the image rect.
       /// - Two or more → DocumentSnapshotHistoryItem(name: stepName, icon: icon, before: state, after: A) where
       ///   A = grown with, for each source in order, addNewLayer + rename + the source's pixels written at (0,0)
       ///   (writePixels, clipped; unallocated source tiles stay unallocated). Layers stack in input order above
       ///   the originally active layer (first file lowest); the last one is active. Selection: unchanged, or nil
       ///   when the canvas grew (expandedState's rule). Nothing floats.
       /// Throws when the grown canvas exceeds `limits`.
       public static func makeHistoryItem(for sources: [ImportSource], state: DocumentState, background: ColorRGBA8,
                                          limits: ImageLimits, baseStepID: HistoryStep.ID) throws(ImageLimitError) -> any HistoryItem

       /// Alert text for failures (nil when failures is empty). Exactly one failure:
       /// message "“<file name>” couldn’t be imported.", informative = reason text (below).
       /// Two or more: message "Some files couldn’t be imported." informative = one line per failure,
       /// "<file name>: <reason text>", at most 10 lines, then "and <n> more." on its own line.
       /// Reason text: .unsupportedType → "It isn’t a supported image file."; .unreadable → "The file couldn’t be
       /// read."; .codec(e) → e.errorDescription (0002's wording).
       public static func failureAlertText(_ failures: [ImportFailure]) -> (message: String, informative: String)?
   }
   ```
   - The **layer name** is `layerName(for:) ?? LayerNaming.newLayerName(existing:)` evaluated on the layers at insertion time. Duplicate names are allowed (Paint.NET allows them).
   - The pixels are always placed at canvas (0,0) — not at the drop point and not by the viewport rule (Open question 2).
   - Multi-file and single-file steps are both exactly **one** history step "Import From File"; the document is marked edited.
   - `decode` never applies the file's DPI to the document (the document keeps its own DPI; D-7).

4b. **`PaintDotMac/Core/IO/FileFormat.swift`** (extend 0029): `static var readableUTTypes: [UTType]` = `allCases.filter(\.canRead).map(\.utType) + [.heif]` — the one list used by the import panel, `LayerImportRunner`, and `CanvasDropHandler`, so `.heif` files (which don't conform to `public.heic`) import like they open (0029's alias). Test: `FileFormatTests.readableUTTypesIncludeHEIFAlias` (the eight `canRead` types in `allCases` order, then `public.heif`; `UTType(filenameExtension: "heif")` conforms to one of them).

5. **`PaintDotMac/Core/Operations/OpenFilesPlanner.swift`** (new) — the pure part of the Dock/app open path:
   ```swift
   public enum OpenFilesPlanner {
       /// Order kept; duplicates removed by url.standardizedFileURL.resolvingSymlinksInPath(); non-file URLs dropped.
       public static func orderedUnique(_ urls: [URL]) -> [URL]
   }
   ```

6. **`PaintDotMac/App/LaunchOptions.swift`** (extend 0001; pure Foundation): `-UITestDropFiles <path>` (repeatable, same parsing rules as `-UITestOpen`: last-argument or followed-by-flag values are ignored) → `dropFileURLs: [URL]` in order. Compiled always, *used* only in `#if DEBUG` (item 11). No new defaults prefix (it persists nothing).

### Platform glue (AppKit; covered by hosted integration tests and UI tests)

7. **`PaintDotMac/Document/LayerImportRunner.swift`** (new, `@MainActor`, the one entry point for menu import and window drops; testable without UI like 0024's `LayerCommandRunner`):
   ```swift
   @MainActor enum LayerImportRunner {
       struct Outcome: Equatable { var importedCount: Int; var failures: [ImportFailure]; var limitError: ImageLimitError? }
       static func run(_ urls: [URL], bridge: UndoBridge, background: ColorRGBA8, limits: ImageLimits,
                       commitPendingEdit: () -> Void,
                       typeOf: (URL) -> UTType? = { try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType },
                       readFile: (URL) throws -> Data = { try Data(contentsOf: $0) }) -> Outcome
   }
   ```
   `run`: `commitPendingEdit()` (floating pixels → "Finish Pixels" on the old layer first) → `ImportLayer.load` with `FileFormat.readableUTTypes` → if no sources, return failures → else `ImportLayer.makeHistoryItem(for:state: bridge.state, background:, limits:, baseStepID: bridge.history.currentStepID)`; a thrown `ImageLimitError` → `limitError`, no step → else `bridge.perform(item)`. Decoding runs synchronously on the main actor, like document reading (0001 `canConcurrentlyReadDocuments == false`); NF-1 is unaffected because no stroke is in progress (gesture guard in item 8).

8. **`PaintDotMac/Document/DocumentWindowController.swift`** (extend; same action pattern as 0013/0021/0024: `guard !AppModel.shared.dispatcher.isGestureInProgress`, `undoBridge.prepareForNavigation?()` first, `validateMenuItem`):
   - **`copyMerged(_:)`:** `ClipboardController.shared.write(ClipboardCopy.copiedMergedSurface(from: undoBridge.state), dpi: image.dpi)`; an encoding error → `NSAlert` "The image couldn’t be copied." with the error's `errorDescription`, "OK"; the pasteboard is unchanged. Enabled iff no gesture is in progress (same as Copy).
   - **`pasteIntoNewLayer(_:)`:** exactly 0021's Paste flow (read, the same failure alerts, the E-6 sheet with the same buttons and identifiers, `PastePlanner.plan`, `expandedState` with the secondary color and limits) but builds `PasteIntoNewLayer.makeHistoryItem(…)`. Cancel in the sheet → nothing. Refactor 0021's Paste action into a private `performPaste(build: (TiledSurface, PastePlan, DocumentState?) -> CompositeHistoryItem)` shared by both, so the two differ only in the builder. Enabled iff no gesture and `ClipboardController.shared.canPaste`.
   - **`importFromFile(_:)`:** `NSOpenPanel` as a window sheet: `title`/`message` "Import From File", `prompt` "Import", `canChooseFiles = true`, `canChooseDirectories = false`, `allowsMultipleSelection = true`, `allowedContentTypes = FileFormat.readableUTTypes`. On OK: `importFiles(panel.urls)`. Enabled iff no gesture.
   - **`importFiles(_ urls: [URL])`** (internal; also called by item 9): `LayerImportRunner.run(urls, bridge: undoBridge, background: AppModel.shared.colors.secondary, limits: PaintDocument.imageLimits, commitPendingEdit: { undoBridge.prepareForNavigation?() })`; then, as a window sheet: `limitError` → alert "The image is too large to import." with informative text = `ImageCodecError.limitExceeded(e).recoverySuggestion`; otherwise `ImportLayer.failureAlertText(outcome.failures)` → an alert with that message/informative text and one "OK" button (shown after the successful files were imported). Redraw, history, Layers panel, and status bar update through the existing `onStateChange(.structure)` path (0008/0021, including `withImageSize` when the canvas grew).
   - Edit-menu and Layers-menu validation for the three new actions as stated.

9. **`PaintDotMac/Canvas/CanvasDropHandler.swift`** (new, `@MainActor final class`) and **`Canvas/CanvasView.swift`** (extend 0003):
   ```swift
   @MainActor final class CanvasDropHandler {
       init(canImport: @escaping () -> Bool, importFiles: @escaping ([URL]) -> Void)
       /// File URLs on the pasteboard, in pasteboard order: readObjects(forClasses: [NSURL], options: [.urlReadingFileURLsOnly: true]).
       static func fileURLs(on pasteboard: NSPasteboard) -> [URL]
       /// .copy iff canImport() and at least one URL's content type is importable (ImportLayer.isImportable,
       /// via resourceValues(.contentTypeKey); no file is opened); else [].
       func dragOperation(for pasteboard: NSPasteboard) -> NSDragOperation
       /// dragOperation == .copy → importFiles(all file URLs, including unsupported ones so they are reported) → true; else false.
       func performDrop(from pasteboard: NSPasteboard) -> Bool
   }
   ```
   - `CanvasView` calls `registerForDraggedTypes([.fileURL])` and implements `draggingEntered`/`draggingUpdated` (return `dropHandler?.dragOperation(for: sender.draggingPasteboard) ?? []`), `prepareForDragOperation` (same check, as Bool), and `performDragOperation` (`dropHandler?.performDrop(from: sender.draggingPasteboard) ?? false`). These are one-line forwards; all decisions live in the handler and in `ImportLayer`.
   - `DocumentWindowController` creates the handler with `canImport = { !dispatcher.isGestureInProgress && window.attachedSheet == nil }` and `importFiles = { [weak self] in self?.importFiles($0) }`, and assigns it to its `CanvasView`. The whole canvas view (image and the gray area around it) is the drop target; the tool options bar and status bar are not.
   - Drops are file URLs only (FMT-C says "image files"); promised files, image data from browsers, and text are not accepted (Out of scope).

10. **`PaintDotMac/App/AppDelegate.swift`** (extend 0001) — Dock icon / app icon / Finder "Open With":
    - Implement `func application(_ application: NSApplication, open urls: [URL])`: `openDocuments(OpenFilesPlanner.orderedUnique(urls))`, where `openDocuments` opens them **sequentially** with `NSDocumentController.shared.openDocument(withContentsOf:display: true)`, starting the next one in the completion handler (deterministic window/tab order, like 0001's fixture loop), and calls `NSApp.presentError(error)` for each failure, then continues. A file that is already open is brought to the front (NSDocumentController's behavior). One window per file (window tabs follow the system setting, D-36).
    - Refactor 0001's Debug fixture loop to call the same `openDocuments(_:)` (behavior unchanged: 0001's tests keep passing).
    - Because the delegate now implements `application(_:open:)`, AppKit routes all `odoc` Apple Events (Dock drops, Finder double-click/Open With, `open -a`, the quality gate's launch smoke) through it; they must still open exactly as before.
    - The Dock icon accepts only the types in `CFBundleDocumentTypes` (0001/0005/0028/0029). Add `SmokeTests.documentTypesCoverReadableFormats` (`PaintDotMacTests/SmokeTests.swift`, next to 0028/0029's exact-list test `SmokeTests.documentTypes`): every `FileFormat` with `canRead` has its `typeIdentifier` in some `LSItemContentTypes` of `Bundle.main`'s `CFBundleDocumentTypes` (an invariant that keeps future formats droppable on the Dock).

11. **Debug drop hook** (`AppDelegate`, `#if DEBUG` only): after the last `-UITestOpen` fixture has opened, if `dropFileURLs` is non-empty, write them as file URLs to a dedicated pasteboard (`NSPasteboard(name: NSPasteboard.Name("com.thera-engineering.paintdotmac.uitest-drop"))`, `clearContents()` then `writeObjects(urls as [NSURL])`) and call the front document window's `CanvasView.dropHandler.performDrop(from:)`. This exercises the real pasteboard → handler → importer path in the running app; only the Finder drag gesture itself is skipped (XCUITest can't drag from Finder; see Manual verification).

12. **`PaintDotMac/App/MainMenu.swift`** (extend 0021/0024):
    - **Edit** menu becomes: Undo, Redo, —, Cut ⌘X, Copy ⌘C, **Copy Merged** ⇧⌘C (`copyMerged(_:)`, `menu.edit.copyMerged`), Paste ⌘V, **Paste into New Layer** ⇧⌘V (`pasteIntoNewLayer(_:)`, `menu.edit.pasteIntoNewLayer`), Paste into New Image ⌥⌘V, —, then the selection items unchanged. Target nil (responder chain).
    - **Layers** menu: **Import From File…** (with the ellipsis, U+2026; no shortcut; `importFromFile(_:)`, `menu.layers.importFromFile`) directly after Merge Layer Down, before the separator that precedes Go to Layer Above (0024's slot; 0025's/0060's items keep their positions).
    - Copy Merged's ⇧⌘C follows PRD §5.12's general rule (Ctrl → ⌘) from Paint.NET's Ctrl+Shift+C; it conflicts with nothing in the app (there is no Format > Show Colors item; Colors is ⌥⌘4). 0045 records it in `docs/shortcuts.md` (Open question 4).
    - Update `MainMenuTests` for the new items, order, key equivalents, and identifiers.

13. **`PaintDotMacUITests/Support/UITestApp.swift`** (extend): `openThroughPanel(file: URL)` for the import sheet (⇧⌘G, type the file's full path, Return, then click "Import") and `openAllThroughPanel(directory: URL)` (⇧⌘G, type the directory path, Return, ⌘A to select every file in a temp directory that contains only the fixtures, click "Import"); `appBundleURL()` = `NSRunningApplication.runningApplications(withBundleIdentifier: "com.thera-engineering.paintdotmac").first?.bundleURL`; `openWithApp(_ urls: [URL])` = `NSWorkspace.shared.open(urls, withApplicationAt: appBundleURL, configuration: NSWorkspace.OpenConfiguration())` awaited (sends the same `odoc` Apple Event as a Dock drop).

14. `project.yml`: no structural change (source globs pick up the new files); run `xcodegen generate`. New files: `Core/Operations/ImportLayer.swift`, `Core/Operations/PasteIntoNewLayer.swift`, `Core/Operations/OpenFilesPlanner.swift`, `Document/LayerImportRunner.swift`, `Canvas/CanvasDropHandler.swift`, and the test files below. PRD: no change by this spec (Open questions 1–5 may add §12 rows; the batch owner records them).

### Accessibility identifiers used by tests
`menu.edit.copyMerged`, `menu.edit.pasteIntoNewLayer`, `menu.layers.importFromFile`; existing `canvas`, `layersList`, `layerRow.<index>`, `historyList`, `historyRow.<index>`, `statusBar.imageSize`, `pasteExpand.*`. The import failure alert's button: `importError.ok`.

## Acceptance criteria

- [ ] **Copy Merged** (⇧⌘C) puts the composite of the visible layers on the clipboard (PNG + TIFF): the whole image without a selection, the selection's bounds masked by its coverage with one; the document and history don't change. → `ClipboardCopyMergedTests.*`, `ClipboardMergedIntegrationTests.copyMergedWritesComposite`, `LayerImportUITests.testCopyMergedCopiesVisibleComposite`
- [ ] **Paste into New Layer** (⇧⌘V) adds "Layer N" directly above the active layer, makes it active, and pastes the clipboard image there as floating pixels (Move Selected Pixels active) at 0021's viewport position; other layers' pixels are unchanged; one step "Paste Into New Layer". → `PasteIntoNewLayerTests.*`, `PasteIntoNewLayerIntegrationTests.*`, `LayerImportUITests.testPasteIntoNewLayer`
- [ ] A clipboard image larger than the canvas shows the E-6 prompt for Paste into New Layer: Expand grows the canvas (top-left anchor, bottom layer's new area = secondary color) within the same step; Keep keeps the size; Cancel does nothing. → `PasteIntoNewLayerIntegrationTests.expandIsPartOfStep`, `.keepCanvasSize`, `LayerImportUITests.testPasteIntoNewLayerLargerExpandAndCancel`
- [ ] Undo after Paste into New Layer restores the exact previous state (layers, active index, canvas size, selection, no floating pixels); redo re-applies it; Escape while floating cancels the whole step. → `PasteIntoNewLayerIntegrationTests.undoRedoExact`, `.escapeCancelsWholeStep`
- [ ] **Layers > Import From File…** imports one or more chosen image files, each as a new layer named after its file (extension removed), stacked in order above the active layer, pixels at the top-left; a single import floats (Move Selected Pixels active), several are placed directly; the last imported layer is active; one step "Import From File". → `ImportLayerTests.*`, `LayerImportRunnerTests.*`, `LayerImportUITests.testImportFromFileSingle`, `.testImportFromFileMultiple`
- [ ] An imported image larger than the canvas grows the canvas automatically (no prompt) to fit, in the same step; one undo restores the old size. → `ImportLayerTests.growsCanvasAutomatically`, `LayerImportRunnerTests.undoRestoresSizeAndLayers`, `LayerImportUITests.testImportLargerGrowsCanvas`
- [ ] Every readable format (ORA, PNG, JPEG, and 0029's TIFF/BMP/GIF/HEIC/WebP) imports (including `.heif`); content is sniffed; a layered `.ora` imports as one layer equal to its composite; the file's DPI is ignored. → `ImportLayerTests.decode*`, `FileFormatTests.readableUTTypesIncludeHEIFAlias`
- [ ] Unsupported, unreadable, corrupt, or over-limit files are not imported; the others in the same batch still are; one alert names each failure; nothing crashes; with no successes there is no history step. → `ImportLayerTests.load*`, `.failureAlertText*`, `LayerImportRunnerTests.partialFailure`, `.allFail`, `.limitExceeded`, `LayerImportUITests.testImportCorruptShowsAlert`
- [ ] Dropping image files onto an open document window imports them as layers through the same path (window drop = Import From File); a drag with no importable file is refused; drops are refused mid-gesture or while a sheet is shown. → `CanvasDropHandlerTests.*`, `LayerImportUITests.testDropHookImportsLayers`, manual 1
- [ ] Dropping image files onto the Dock icon or the app icon opens one document per file, in order; duplicates open once; a bad file shows the standard "couldn’t be opened" alert and the others still open. → `OpenFilesPlannerTests.*`, `AppDelegateOpenTests.*`, `DockOpenUITests.testOpenWithAppOpensEachFile`, `.testOpenWithAppBadFileAlerts`, manual 2–3
- [ ] Menus: Edit has Copy Merged ⇧⌘C after Copy and Paste into New Layer ⇧⌘V after Paste; Layers has Import From File… after Merge Layer Down; enablement as specified. → `MainMenuTests.editMenuClipboardItems`, `.layersMenuImportItem`, `LayerImportUITests.testMenuEnablement`
- [ ] Use case 3 (several images on separate layers with blend modes and opacity) can be done end to end. → `UseCase3IntegrationTests.compositeFromImportedLayers`, manual 4
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke, now through `application(_:open:)`).

## Edge cases

- **Copy Merged with all layers hidden** → a fully transparent surface of the image (or selection-bounds) size is copied; not an error. **With an empty composite tile** → transparent black, no crash.
- **Copy Merged with floating pixels:** `prepareForNavigation` records "Finish Pixels" first; the copy includes them (the layer already shows them).
- **Paste into New Layer when the clipboard has no image** → 0021's "The clipboard doesn’t contain an image." alert, no layer added. Over the limits → 0021's "too large to paste" alert, no change.
- **Paste into New Layer with a selection** → the selection is replaced by the pasted rect (0021); undo restores it.
- **Import of 0 files** (panel cancelled) → nothing. **All files fail** → alert only, no step, not edited.
- **Import grows the canvas beyond `ImageLimits`** → "The image is too large to import." alert, no step. A single file over the limits → `.codec(.limitExceeded)` in the failure alert (decoder refuses before allocating).
- **Import image smaller than the canvas** → placed at (0,0), rest of the new layer transparent. **Same size** → no growth. **Wider only** (e.g. 900×100 onto 800×600) → canvas 900×600.
- **Mixed sizes in one batch** → canvas grows once to the max width and max height of canvas and all sources.
- **Import with floating pixels or a pending tool edit** → committed first ("Finish Pixels" step before "Import From File").
- **Import when the active layer is hidden or not the top layer** → new layers go directly above the active one, visible, opacity 255, Normal.
- **Layer name edge cases:** `photo.JPG` → "photo"; `a.b.png` → "a.b"; `.png` → ".png"; a whitespace-only base name → "Layer N".
- **Wrong extension** (a JPEG named `.png`, an ORA named `.png`) → imported by content (sniffing). A file with an image UTType that decodes as nothing → `.codec(.unrecognizedFormat)`.
- **Truncated PNG** → `.codec(.corrupt)` → alert; other files still import.
- **Folder, text file, or alias to a non-image in a drop** → `.unsupportedType`, reported in the alert; if nothing in the drag is importable, the drag shows the "no drop" cursor and nothing happens.
- **Drop while dragging on the canvas / a sheet is open** → refused (`[]`).
- **Undo/redo across every new step**: identical layers (ids, names, properties, tiles), active index, canvas size, selection, floating state.
- **Dock: the same file twice in one drop, or a file already open** → one window, brought to the front. **Dock drop when no window is open / app not running** → the app launches (no untitled document, 0001) and opens the files.
- **H-5 budget**: a large import is a normal snapshot step; oversized steps are kept (D-34).

## Test plan

Fixtures are generated in the tests with `TestImages` (unit) and `UITestFixtures` (UI). Expected values are hand-computed below.

- **Unit tests**
  - `PaintDotMacTests/Operations/ClipboardCopyMergedTests.swift`
    - `noSelectionCopiesVisibleComposite`: 4×3 image; layer 0 opaque red (255,0,0,255); layer 1 visible, transparent except (1,1) = (0,255,0,255); layer 2 **hidden**, all (0,0,255,255). Result 4×3: (1,1) = (0,255,0,255), every other pixel (255,0,0,255) (blue never appears).
    - `selectionCopiesBoundsMasked`: same image, `Selection(rect: (1,1,2,2))` → 2×2: (0,0) green, (1,0),(0,1),(1,1) red. Then a selection mask with coverage 128 at canvas (1,1) and 255 elsewhere in a 2×2 bounds → output (0,0) = (0,255,0, mul255(255,128) = 128).
    - `zeroCoverageIsTransparentBlack`: a lasso-like mask with coverage 0 at a corner of bounds → that pixel (0,0,0,0).
    - `semiTransparentLayerMatchesCompositor`: layer 1 opacity 128 over red → result equals `CPUCompositor().composite(image, in: full).pixels` (0012/0024's tested oracle) pixel for pixel; and differs from Copy (`copiedSurface`) of the active layer.
    - `allHiddenIsTransparent`: all layers hidden → every pixel (0,0,0,0), size == image size.
    - `copyUnchangedByRefactor`: `copiedSurface(from:)` on 0021's fixtures still yields the 0021 expected values (guards the shared helper).
  - `PaintDotMacTests/Operations/PasteIntoNewLayerTests.swift`
    - `preparedStateAddsLayerAboveActive`: layers [Background, Layer 2], active 0 → prepared layers [Background, Layer 3, Layer 2] (names), active 1, new layer has no allocated tiles, other layers `sharesStorage` true.
    - `itemStructure`: item name "Paste Into New Layer", icon `.paste`, first part `DocumentSnapshotHistoryItem` (before == state, after == prepared), and a `FloatingPixelsHistoryItem(before: nil, …)` part so `MoveSelectedPixelsHistory.stepStartsSession` is true for it.
    - `pastedPixelsOnNewLayerOnly`: 300×200 opaque white background, clipboard 10×10 red, origin (5,7) → after apply: new layer (5..<15, 7..<17) red, (4,7) transparent; Background unchanged (`==` before); selection == rect (5,7,10,10); `floatingPixels?.layerID == new layer id`.
    - `pasteStepForwardIsIdentical`: 0021's `makeHistoryItem(surface:plan:state:expanded:baseStepID:)` output equals the new general builder with `name: "Paste", icon: .paste` (apply both to the same state → identical resulting state and item names).
  - `PaintDotMacTests/Operations/ImportLayerTests.swift`
    - `layerName`: "Beach.JPG" → "Beach"; "a.b.png" → "a.b"; ".png" → ".png"; "   .png" → nil; "noext" → "noext".
    - `isImportable`: `.png`, `.jpeg`, `UTType("org.openraster.ora")` → true; `.plainText`, `.folder`, nil → false.
    - `decodePNG`: 3×2 PNG with known pixels (incl. (10,20,30,0) under alpha 0) → surface pixels equal, size 3×2. `decodeJPEGNamedPNGBytesSniffed`: JPEG bytes → decodes (8×8 solid (200,100,50) within ±2 for JPEG). `decodeOpenRasterFlattens`: `OpenRasterCodec.encode` of 2 layers 4×4 (bottom red opaque, top green at (0,0), top hidden in a second variant) → surface (0,0) green, (1,0) red; hidden variant → (0,0) red. `decodeTruncated` → throws `.corrupt`. `decodeEmpty` → `.unrecognizedFormat`. `decodeOverLimit`: `ImageLimits(memoryCapBytes: 100)` with a 10×10 PNG → `.limitExceeded(.exceedsMemoryCap…)`. `decodeIgnoresDPI`: 300-DPI PNG → only the surface is returned (doc DPI untouched in `growsCanvasAutomatically`'s state).
    - `loadOrderAndFailures`: urls [a.png (ok), b.txt (type .plainText), c.png (readFile throws), d.png (truncated), e.png (ok)] with injected `typeOf`/`readFile` → sources [a, e] with names "a","e"; failures [(b, .unsupportedType), (c, .unreadable), (d, .codec(.corrupt))]; `readFile` was never called for b (spy).
    - `requiredCanvasSize`: canvas 800×600 with sources 100×100 → nil; 900×100 → 900×600; [900×100, 50×700] → 900×700; equal 800×600 → nil.
    - `singleImportFloats`: 300×200 doc (white Background), source "red" 10×10 red → item name "Import From File", icon `.importLayer`; after apply: layers [Background, red], active 1, layer "red" (0..<10,0..<10) red, (10,0) transparent; selection rect (0,0,10,10); `floatingPixels != nil`; Background `==` before.
    - `multiImportStacksInOrder`: layers [Background, Top], active 0; sources [A 4×4 red, B 2×2 blue] → layers [Background, A, B, Top], active 2 (B), A (0..<4)² red, B (0..<2)² blue, `floatingPixels == nil`, selection unchanged (a pre-existing rect selection survives); item is one `DocumentSnapshotHistoryItem` named "Import From File".
    - `growsCanvasAutomatically`: 300×200 doc (opaque white bottom), secondary (0,0,0,255), source 400×250 → size 400×250; bottom (350,0) == (0,0,0,255) and (0,0) white; new layer (399,249) == source pixel; dpi unchanged; selection after (multi case) nil.
    - `growBeyondLimitsThrows`: limits cap 300×200×4 bytes, source 400×250 → throws `ImageLimitError`.
    - `emptyNameFallsBackToLayerN`: source with `layerName(for:) == nil` on [Background] → "Layer 2".
    - `failureAlertTextSingle`: one `.unsupportedType` for notes.txt → ("“notes.txt” couldn’t be imported.", "It isn’t a supported image file."). `failureAlertTextMultiple`: 12 failures → message "Some files couldn’t be imported.", 10 lines "<name>: <reason>" then "and 2 more."; `.codec(.corrupt)` line uses 0002's `errorDescription`. Empty → nil.
  - `PaintDotMacTests/Operations/OpenFilesPlannerTests.swift`: `keepsOrderRemovesDuplicates` ([/t/a.png, /t/b.png, /t/./a.png] → [a, b]); `resolvesSymlinks` (temp symlink to a.png plus a.png → one URL); `dropsNonFileURLs` (https URL removed); `empty`.
  - `PaintDotMacTests/App/LaunchOptionsTests.swift` (extend): `dropFilesRepeatableInOrder`, `dropFilesAtEndIgnored`, `dropFilesFollowedByFlagIgnored`; existing tests unchanged.
  - `PaintDotMacTests/App/MainMenuTests.swift` (extend): `editMenuClipboardItems` (titles in order "Cut","Copy","Copy Merged","Paste","Paste into New Layer","Paste into New Image"; Copy Merged key "c" with [.command, .shift]; Paste into New Layer "v" with [.command, .shift]; identifiers); `layersMenuImportItem` ("Import From File…" index = Merge Layer Down index + 1, no key equivalent, action `importFromFile:`, identifier); `noDuplicateKeyEquivalents` across the menu bar still passes.
- **Round-trip and property tests** (`PaintDotMacTests/Operations/ImportLayerPropertyTests.swift`, `SeededRandom`, seed printed): 200 random cases of (canvas size 1–600 each side, 1–4 layers with random tiles, active index, optional rect selection, 1–3 sources of random size 1–700 with random pixels) → apply `makeHistoryItem` via `HistoryStack.perform`, then undo → state `==` before (layers, ids, tiles, size, selection, floating nil); redo → `==` after; after-state `isConsistent`; layer count +sources.count; every source's pixels found at (0,0) of its layer (sampled 50 pixels); canvas size == `requiredCanvasSize ?? canvas`. Same for `PasteIntoNewLayer` with random plans (keep/expand).
- **Integration tests** (headless, hosted in the app, `@MainActor`):
  - `PaintDotMacTests/Document/LayerImportRunnerTests.swift` (real `UndoBridge`, temp files written with `TestImages`/`ImageEncoder`): `singleFileStep` (history names ["Open Image", "Import From File"], document edited, `floatingPixels != nil`); `commitsPendingEditFirst` (a floating paste exists → history ["Open Image","Paste","Finish Pixels","Import From File"] and the pasted pixels are on the old layer); `partialFailure` (good.png + bad.png truncated → one layer added, `failures == [(bad, .codec(.corrupt))]`); `allFail` (no step, `history.steps.count == 1`, not edited); `limitExceeded` (injected small limits that the growth exceeds → `limitError != nil`, no step); `undoRestoresSizeAndLayers` (grow import then undo → `state == before`, redo → after, `withImageSize` applied: `canvasView.transform.imageSize` follows when a window controller is present — covered in UI test).
  - `PaintDotMacTests/Document/PasteIntoNewLayerIntegrationTests.swift` (unique `NSPasteboard` injected into a `ClipboardController(pasteboard:)`, decision closure instead of the sheet as in 0021's tests): `pastesAboveActive`, `expandIsPartOfStep` (300×200, clipboard 400×250, Expand → size 400×250, layers +1, one step; undo → 300×200 and `==` original), `keepCanvasSize` (size unchanged; commit drops pixels beyond the canvas), `undoRedoExact`, `escapeCancelsWholeStep` (Escape via 0020's tool cancel → layer count back to original, "Paste Into New Layer" is a redo step).
  - `PaintDotMacTests/Document/ClipboardMergedIntegrationTests.swift`: `copyMergedWritesComposite` — the `copyMerged` path with a unique pasteboard → `ClipboardImageCodec.read` of the written PNG equals `copiedMergedSurface` exactly; pasteboard types are exactly [`public.png`, `public.tiff`]; history unchanged.
  - `PaintDotMacTests/Canvas/CanvasDropHandlerTests.swift` (unique pasteboards with `writeObjects([NSURL])`): `fileURLsInOrder`; `acceptsWhenAnyImportable` ([txt, png] → `.copy`); `refusesNoImportable` ([txt], [folder], text-only pasteboard → `[]`); `refusesWhenCannotImport` (`canImport` false → `[]`, `performDrop` false, importer not called); `performDropPassesAllURLsInOrder` (spy receives [txt, png] in order — unsupported ones are reported by the importer).
  - `PaintDotMacTests/App/AppDelegateOpenTests.swift`: `openDocumentsOpensEachInOrder` (two temp PNGs → `NSDocumentController.shared.documents` gains two `PaintDocument`s whose `fileURL`s are in order; close them after); `duplicateOpensOnce`; `badFileContinues` (truncated PNG first, good PNG second → one document opened; error presenter spy (inject a `presentError` closure) called once with an `ImageCodecError.corrupt`).
  - `PaintDotMacTests/Integration/UseCase3IntegrationTests.swift`: `compositeFromImportedLayers` — new 200×100 white image; import three generated files (red 200×100, green 100×100, blue 50×50) in one batch → 4 layers named Background/red/green/blue; set green's blend mode Multiply and blue's opacity 128 through 0025's `LayerProperties`; flatten via `CPUCompositor` → pixel (25,25) equals the hand formula: Multiply(red over white → red (255,0,0), green (0,255,0)) = (0,0,0), then blue at opacity 128 Normal over (0,0,0): (0,0,mul255(255,128)=128) ±1; pixel (150,50) = red; save as `.ora` and reopen → equal `LayeredImage` (names, modes, opacity, pixels); undo ×(steps) back to "New Image".
- **UI tests** (`PaintDotMacUITests/LayerImportUITests.swift`, fixtures generated at test time):
  - `testMenuEnablement`: with a 64×48 fixture and a cleared pasteboard: Copy Merged enabled, Paste into New Layer disabled, Import From File… enabled; after `setPasteboardImage(10,10)` Paste into New Layer enabled.
  - `testCopyMergedCopiesVisibleComposite`: fixture opaque red 64×48; clipboard = a 64×48 image transparent except (0,0) green; ⇧⌘V (Paste into New Layer), Return (Finish Pixels); ⇧⌘C → `pasteboardPNG()` is 64×48 with (0,0) green and (10,10) red; ⌘C (Copy, active layer only) → (10,10) transparent. History has no "Copy" rows.
  - `testPasteIntoNewLayer`: 64×48 fixture; clipboard 10×10 red; ⇧⌘V → `layerRow.1` label "Layer 2" value "active"; History last row "Paste Into New Layer"; tool `tool.moveSelectedPixels` selected; ⌘Z → no `layerRow.1`; ⇧⌘Z → back.
  - `testPasteIntoNewLayerLargerExpandAndCancel`: clipboard 100×80; ⇧⌘V → sheet; `pasteExpand.cancel` → no new row; ⇧⌘V → `pasteExpand.expand` → `statusBar.imageSize` "100 × 80", 2 layer rows; ⌘Z → "64 × 48", 1 row.
  - `testImportFromFileSingle`: write `beach.png` 10×10 blue to a temp dir; Layers > Import From File… → `openThroughPanel(file:)` → `layerRow.1` label "beach", active; History "Import From File"; Move Selected Pixels active; Return (Finish Pixels); ⇧⌘S → `saveThroughPanel(directory: tmp, name: "out.png", format: "PNG")` (0029's `savePanel.format`; a layered image preselects OpenRaster) → 0029's "Flatten image?" sheet → "Flatten" → `decodePNG(tmp/out.png)` → (0,0) blue, (20,20) fixture color.
  - `testImportFromFileMultiple`: temp dir with `a.png` (red 4×4) and `b.png` (green 4×4) only; `openAllThroughPanel(directory:)` → rows `layerRow.1` "a", `layerRow.2` "b" (value "active"); exactly one new History row "Import From File".
  - `testImportLargerGrowsCanvas`: 64×48 fixture; import `big.png` 100×80 → `statusBar.imageSize` "100 × 80" with no prompt; ⌘Z → "64 × 48".
  - `testImportCorruptShowsAlert`: import `UITestFixtures.writeTruncatedPNG()` → alert text contains "couldn’t be imported"; click `importError.ok`; layer and History rows unchanged; app still running.
  - `testDropHookImportsLayers`: launch with fixture + `-UITestDropFiles <a.png> -UITestDropFiles <notes.txt> -UITestDropFiles <b.png>` → layers "a", "b" added in order, one "Import From File" row, and the failure alert names "notes.txt" (window-drop path through the real pasteboard and handler).
- **UI tests** (`PaintDotMacUITests/DockOpenUITests.swift`): `testOpenWithAppOpensEachFile` — launch empty; `openWithApp([one.png, two.jpg, one.png])` → exactly two document windows titled "one.png" and "two.jpg" (window titles/tabs), in that order. `testOpenWithAppBadFileAlerts` — `openWithApp([truncated.png, good.png])` → an alert whose text contains "couldn’t be opened"; dismiss → "good.png" window exists. (`NSWorkspace.open(_:withApplicationAt:)` delivers the same `odoc` event as a Dock drop; if the runner is ever denied that, the test must fail loudly, not skip — report it.)
- **Performance:** not applicable (no canvas/compositor hot path changes; import decode time is bounded by 0002's decoder). NF-4: a single import costs the new layer's tiles (snapshot `unsharedTileBytes`), multi-import likewise; asserted indirectly by `HistoryCost` tests of 0008.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes (now via `application(_:open:)`).
- **Manual verification** (can't be automated: XCUITest cannot drag from Finder or onto the Dock):
  1. Open an image, drag two PNGs from Finder onto the canvas (also onto the gray area around the image): the cursor shows a "+" copy badge; on drop two layers named after the files appear, one History step "Import From File". Drag a `.txt` alone: the cursor shows "no drop" and nothing happens. Drag a `.txt` plus a PNG: the PNG imports and an alert names the `.txt`.
  2. With the app running and no windows open, drag a JPEG and a HEIC from Finder onto the Dock icon: the icon highlights, two windows open. Drag a `.txt` onto the Dock icon: the icon does not highlight.
  3. Quit the app; drag a PNG onto PaintDotMac.app in Finder (and onto the Dock icon of the non-running app): the app launches and opens only that file (no untitled window).
  4. Use case 3: build a composite from three photos via drag and drop, set blend modes and opacity in the Layers panel, Copy Merged a selection and paste it into TextEdit/Preview (File > New from Clipboard) — the pasted image matches what the canvas shows.

## Open questions

Decided as stated (recommended answers applied); the batch owner should confirm with the user and record them in PRD §12.

1. **Imported layer name:** the file name without its extension ("beach.png" → "beach"). Paint.NET's docs don't say. Recommended: yes.
2. **Placement and floating for Import/drop:** pixels at the canvas top-left (0,0); a single file floats with Move Selected Pixels active (like Paste into New Layer, so it can be positioned right away); a multi-file import or drop places all layers directly (one step, nothing floats, last layer active). Not at the drop point. Recommended: yes.
3. **Importing a layered `.ora`:** imported as one layer equal to its composite (visible layers), named after the file. Paint.NET's "one or more new layers" could also mean one layer per source layer; that is deferred. Recommended: composite.
4. **Copy Merged shortcut:** ⇧⌘C (Paint.NET Ctrl+Shift+C under §5.12's Ctrl → ⌘ rule); PRD §5.12's table has no row for it. Recommended: add the row "Copy Merged | Ctrl+Shift+C | ⇧⌘C".
5. **Canvas growth on import is automatic (no E-6 prompt)**, per Paint.NET's Layers menu doc ("This happens automatically as required"); E-6's prompt stays for Paste and Paste into New Layer only. The grown area follows 0021's rule (bottom layer = secondary color, others transparent). Recommended: yes.

## Out of scope

- Paint.NET's "Open or Add Layer?" prompt on canvas drops (PRD FMT-C chose add-as-layer).
- Dropping non-file data (browser images, promised files, text) onto the canvas; dropping files onto the floating panels.
- Import as several layers from a layered file (Open question 3), layer flip/rotate/zoom (0060), Resize Canvas dialog and `CanvasAnchor` (0036; may refactor `PastePlanner.expandedState`, behavior unchanged).
- The Layers panel itself (0025), blend modes (0026/0027), flat-format encoding/decoding details (0029), shortcut audit and `docs/shortcuts.md` (0045).
