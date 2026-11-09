# 0035 — Resize the image (⌘R) by percentage, pixel size, or print size, with four resampling modes

> Source: PRD.md §5.5 IMG-2 ("Resize Image: by percentage or absolute size, keep aspect ratio, resampling choice (bicubic, bilinear, nearest-neighbor, supersampling)", P0); §5.12 (Resize Image Ctrl+R → ⌘R); §5.1 APP-10 / §12 D-8, D-32 (image limits, refused with an alert); APP-5 / §12 D-7 (per-document DPI, in/cm derived from it); APP-9 / D-30 (DPI range 1–10,000); §5.7 H-6 / §12 D-34 (no-op edits add no step); NF-4 (history memory), NF-6 (resampling has unit tests), NF-9 (straight storage, premultiplied only for math); §8 M4 (use case 2: "… sharpen, resize, and export a JPEG"); AGENTS.md architecture rules 1–4 and 7.
> Paint.NET docs (fetched 2026-11-07; `getpaint.net/doc/latest/…` redirects to `paint.net/doc/latest/…`): Image menu, "Resize" section — https://paint.net/doc/latest/ImageMenu.html (the separate `ResizeImageDialog.html` page returns 404). Quoted below.
> Milestone: M4
> Depends on: 0031-effect-framework-and-first-adjustments (`UndoBridge.isBusy`, `EffectProgressView`, the 0.5 s progress-sheet rule, menu order), and through it 0002 (`ImageLimits`), 0004 (`MeasurementUnit`, `AppSettings`), 0005 (dialog/validation pattern), 0008 (`DocumentSnapshotHistoryItem`, `UndoBridge`), 0013 (selection), 0020 (`Resampler`, `ResamplingMode`), 0021 (`CanvasTransform.withImageSize(_:)` and the `.structure` hook), 0022 (Image menu), 0024 (layers, Flatten as the last Image item), 0025 (sheet pattern).

## Context

Not yet implemented (specs only, no application code). What exists after 0001–0034:

- **`Core/Rendering/Resampler.swift` (0020, `docs/specs/todo/0020-move-selected-pixels_TODO.md:33-62`)**: `enum ResamplingMode: String, CaseIterable, Sendable { case nearestNeighbor, bilinear }` with `displayName` ("Nearest Neighbor", "Bilinear") and the comment "0035 adds bicubic, supersampling"; `enum Resampler` with `epsilon = 1e-9`, `mode(for:)` (D-21), `destinationBounds(sourceRect:transform:mode:)`, `resample(_:sourceOrigin:transform:mode:destination:)`, `sample(_:sourceOrigin:at:mode:)`. Sampling geometry: destination pixel centre `(x + 0.5, y + 0.5)` mapped through the inverse transform; nearest = `floor`; bilinear = premultiplied 2×2 with `u = p.x − 0.5`, weights `(1−fx)`, `fx`, **pixels outside the source read as transparent** (edges fade), alpha `min(255, Int(A + 0.5))`, colour `Int(Pc / A + 0.5)`, alpha 0 → `(0,0,0,0)`. That edge rule is right for floating pixels but wrong for Resize Image (the border would fade to half-transparent), so this spec adds a whole-surface resize with **clamped** edges next to it.
- **`ImageLimits` (0002, `0002…_TODO.md:63-95`)**: `validate(width:height:format:) throws(ImageLimitError) -> Int` (sides 1…65,535, overflow, `byteCount <= memoryCapBytes`); "Specs 0005 (New Image), 0021 (paste), and 0035/0036 (resize) call the same `validate`." `PaintDocument.imageLimits` honours the Debug hook `-UITestMemoryCapBytes`.
- **`LayeredImage` (0002)**: `size`, `dpi: Double` (finite, > 0), `layers` (bottom first), `activeLayerIndex`, `isConsistent`; `TiledSurface` (`init(size:)`, `readPixels(in:)`, `writePixels(_:to:)`, `tile(at:)`/`setTile(_:at:)`, `releaseTransparentTiles()`, `Tile.sharesStorage(with:)`).
- **History (0008)**: `HistoryIcon.resizeImage` already exists (`0008…_TODO.md:53`); `DocumentSnapshotHistoryItem(name:icon:before:after:)` is reserved for "resize image 0035" (`:83`), `change == .structure`, `byteCost = HistoryCost.unsharedTileBytes(before:after:)`. 0024/M3 rule: snapshot ops assume `floatingPixels == nil` and carry the selection; every canvas-size command calls `undoBridge.prepareForNavigation?()` first.
- **View (0021 `0021…_TODO.md:168,195`)**: `CanvasTransform.withImageSize(_:)` keeps the zoom and re-centres; the `.structure` branch of `onStateChange` applies it whenever the state's size differs from the transform's. Reused unchanged (for the resize and its undo/redo).
- **Image menu (0022 `0022…_TODO.md:78-82`, 0024 `:169`)**: `menu.image` contains "Crop to Selection" ⇧⌘X, then a separator and "Flatten" ⇧⌘F as the last item. 0022's comment reserves a slot for "0035 (Resize…)".
- **0031** (`0031…_TODO.md:254-280`): `UndoBridge.isBusy` (disables document commands, Undo/Redo, Save, History panel, canvas input while true), `UI/EffectProgressView.swift` (identifier `effectProgress`, determinate bar `effectProgress.bar`, Cancel `effectProgress.cancel` / Escape), and the rule "present the progress sheet if a run hasn't finished 0.5 s after it started". Resize Image is **not** an `ImageEffect` (it changes the canvas size and every layer; AGENTS rule 5 is about effects), but it reuses the busy flag and the progress sheet.
- **Units (0004)**: `MeasurementUnit` (`.pixels/.inches/.centimeters`, `sanitizedDPI`), `AppSettings.measurementUnit`. **New Image (0005)**: `NewImageForm` text-field validation pattern and messages ("Width must be a whole number from 1 to 65,535 pixels.", "The image is too large. …").

**Paint.NET behavior mirrored** (ImageMenu.html, quoted): "Use Image → Resize, or press Ctrl + R." "The 'New size' at the top shows the uncompressed size, which is the RAM needed to edit the image." "**By percentage**: Changes size by a percentage. **By absolute size**: Sets a new Height and/or Width. **Maintain aspect ratio**: When checked, changing Width adjusts Height proportionally, and the reverse." "Print size depends on resolution (DPI) … Pixel Size / DPI = Print Size … a two-inch print width at 96 DPI requires 192 pixels." Resampling list in Paint.NET 5 (eight entries, "default is Bicubic"): "**Bicubic** (default): Balances smoothness and sharpness. Also called Catmull-Rom", Bicubic (Smooth), "**Bilinear**: Linear (triangle/tent) interpolation", "Bilinear (Low Quality): Weighted average of the nearest four pixels in a 2x2 grid", Adaptive (Sharp), Lanczos, "**Fant**: Weighted average when reducing; equivalent to Bilinear when enlarging", "**Nearest Neighbor**: Picks the closest pixel." Plus a "Gamma Correction" checkbox. The PRD scopes the list to **Bicubic, Bilinear, Nearest Neighbor, Supersampling** — "Supersampling" is the Paint.NET 3.x/4.x name of the area-averaging resampler (Paint.NET 3.36 `Surface.SuperSamplingFitSurface`: area average when shrinking, Bicubic otherwise). Paint.NET's Resize applies to every layer of the image ("This menu contains commands that affect all layers").

## User story

As a PaintDotMac user, I press ⌘R (Image ▸ Resize…), choose **By percentage** (100 by default) or **By absolute size** (pixel width/height, or print width/height in inches or centimetres with a resolution), keep **Maintain aspect ratio** checked so the other side follows, pick **Bicubic** (default), **Bilinear**, **Nearest Neighbor**, or **Supersampling**, and click OK. Every layer is resized; the window keeps its zoom and re-centres the image; the status bar shows the new size; History shows one "Resize Image" step that ⌘Z undoes exactly. Sizes beyond the image limits show an alert instead of crashing, and a long resize shows a progress sheet I can cancel.

## Scope & changes

### Core — resampling (pure, headless, unit-tested)

1. **`Core/Rendering/Resampler.swift`** (extend 0020; existing behavior and call sites unchanged):
   ```swift
   public enum ResamplingMode: String, CaseIterable, Sendable {
       case nearestNeighbor, bilinear, bicubic, supersampling   // raw values frozen
       public var displayName: String   // "Nearest Neighbor", "Bilinear", "Bicubic", "Supersampling"
   }
   extension Resampler {
       /// Catmull-Rom (Paint.NET 5 docs: "Bicubic … Also called Catmull-Rom").
       public static let bicubicA: Double = -0.5
       /// Keys cubic kernel with a = bicubicA. |t| ≤ 1: (a+2)|t|³ − (a+3)|t|² + 1; 1 < |t| < 2: a|t|³ − 5a|t|² + 8a|t| − 4a; else 0.
       public static func cubicWeight(_ t: Double) -> Double
       /// The mode actually used to resize from `source` to `destination` size (see "Supersampling").
       public static func effectiveResizeMode(_ mode: ResamplingMode, from source: PixelSize, to destination: PixelSize) -> ResizeKernel
       /// One axis of a separable resize: for each destination index, the (clamped source index, weight) taps,
       /// duplicates merged, weights summing to 1 (± 1e-12). Exposed for tests.
       public static func axisTaps(sourceLength: Int, destinationLength: Int, kernel: ResizeKernel) -> [[ResizeTap]]
       /// Whole-surface resize, clamped edges, premultiplied math. Checks cancellation between bands and
       /// reports progress (0…1, monotonic, last call 1.0). Pure; safe off the main actor.
       public static func resize(_ source: TiledSurface, to size: PixelSize, mode: ResamplingMode,
                                 progress: (@Sendable (Double) -> Void)? = nil) throws(CancellationError) -> TiledSurface
   }
   public enum ResizeKernel: Sendable, Equatable { case nearest, bilinear, bicubic, areaAverage }
   public struct ResizeTap: Sendable, Equatable { public let index: Int; public let weight: Double }
   ```
   - **Geometry (all kernels):** per axis `s = Double(sourceLength) / Double(destinationLength)`; destination index `k` has its centre at source coordinate `p = (k + 0.5) · s`; `u = p − 0.5`; values within `epsilon` of an integer snap (0020's rule), so integer ratios are exact.
   - **Nearest:** source index `floor((2k + 1) · sourceLength / (2 · destinationLength))` computed in **integer arithmetic** (no floating-point rounding risk), copied straight — colour under alpha 0 is preserved exactly (D-33). E.g. 2→4: 0,0,1,1; 4→3: 0,2,3; 3→2: 0,2.
   - **Bilinear:** `x0 = floor(u)`, `f = u − x0`, taps `(x0, 1−f)`, `(x0+1, f)`; indices **clamped** to `0…sourceLength−1` (edge pixels repeat; nothing outside reads as transparent). This is the classic 2×2 interpolation (Paint.NET 5 calls it "Bilinear (Low Quality)"; see Open question 3).
   - **Bicubic:** `x0 = floor(u)`, `f = u − x0`, taps `(x0−1, W(1+f))`, `(x0, W(f))`, `(x0+1, W(1−f))`, `(x0+2, W(2−f))` with `W = cubicWeight`, indices clamped and merged. Weights may be negative (ringing).
   - **Area average (Supersampling's shrink kernel):** destination index `k` covers source interval `[k·s, (k+1)·s)`; tap weight for source pixel `i` = `overlap([i, i+1), interval) / s`. Never reads outside the source.
   - **Supersampling → kernel** (`effectiveResizeMode`): `.areaAverage` when `destination.width ≤ source.width && destination.height ≤ source.height` (shrinking, or one axis unchanged — area average at ratio 1 is the identity on that axis); otherwise `.bicubic` (Paint.NET 3.36/4 "Supersampling" behavior; Open question 2). The other modes map 1:1 (`.nearestNeighbor → .nearest`, `.bilinear → .bilinear`, `.bicubic → .bicubic`).
   - **Premultiplied, separable, exact:** for non-nearest kernels, work in `Double` with premultiplied channels `(r·a, g·a, b·a, a)`. Horizontal pass over the source rows a band needs, then vertical pass; intermediate values are **not** clamped or rounded between passes (so the result equals the 2-D tensor-product formula). Final per pixel: `A` = alpha sum; `alpha = clamp(floor(A + 0.5), 0, 255)`; if `alpha == 0` → `(0,0,0,0)`; else each colour `= clamp(floor(P / A + 0.5), 0, 255)` (unrounded `A`; `A ≥ 0.5` here). Fully transparent neighbours never bleed colour; bicubic overshoot is clamped; a negative alpha sum becomes clear.
   - **Banding and memory:** process destination rows in bands of one tile row (256 rows). For each band compute the source row range from the vertical taps, run the horizontal pass only for those rows (buffer `rows × newWidth × 4` Doubles), then the vertical pass, then write whole destination tiles with `writePixels`/`setTile`. Within a band, columns of destination tiles run with `DispatchQueue.concurrentPerform` (per-pixel independent → bit-identical to serial). Never allocate a full-image Double buffer. Finish with `releaseTransparentTiles()`.
   - **Fast paths:** same size → return `source` unchanged (tiles shared; all kernels are the identity at ratio 1 — `W(0)=1`, `W(±1)=W(2)=0`, bilinear `f = 0`); a source with no allocated tiles → `TiledSurface(size:)` with no tiles.
   - **Cancellation and progress:** `Task.isCancelled` is checked before each band (and every 64 rows inside a band); on cancel throw `CancellationError` (no partial result escapes). `progress` is called after each band with `bandsDone / totalBands`.
   - **Affine path (0020's `resample`/`sample`):** `.bicubic` uses the same cubic kernel with 0020's transparent-outside rule (4×4 neighbourhood, premultiplied, same rounding); `.supersampling` is evaluated as `.bilinear` there (point sampling has no footprint). `mode(for:)` still returns only nearest/bilinear (D-21), so floating pixels are unaffected. `destinationBounds` outsets by 2 px for `.bicubic`.

### Core — the operation and the form (pure, unit-tested)

2. **`Core/Operations/ResizeImage.swift`** (new):
   ```swift
   public struct ResizeImageRequest: Equatable, Sendable {
       public var size: PixelSize
       public var dpi: Double                 // finite, 1…10,000 (APP-9 range)
       public var resampling: ResamplingMode
   }
   public enum ResizeImageError: Error, Equatable, Sendable { case limitExceeded(ImageLimitError) }
   public enum ResizeImage {
       public static let name = "Resize Image"            // history step + dialog title (Paint.NET spelling)
       public static let menuTitle = "Resize…"            // Image menu item (Paint.NET: "Resize...")
       public static let icon: HistoryIcon = .resizeImage
       public static func isNoOp(_ request: ResizeImageRequest, for state: DocumentState) -> Bool  // same size && same dpi
       /// Validates with `limits`, then resizes every layer (sequentially; each layer internally parallel).
       /// Returns nil for a no-op. Progress spans all layers: (layerIndex + layerFraction) / layerCount.
       public static func resizedState(_ state: DocumentState, request: ResizeImageRequest, limits: ImageLimits,
                                       progress: (@Sendable (Double) -> Void)?) async throws -> DocumentState?
       public static func makeHistoryItem(before: DocumentState, after: DocumentState) -> DocumentSnapshotHistoryItem
   }
   ```
   - **Validation first:** `limits.validate(width:height:)` on `request.size` before any allocation; a failure throws `ResizeImageError.limitExceeded`.
   - **Layers:** every layer in order, **including hidden layers**, gets `Resampler.resize(layer.surface, to: request.size, mode: request.resampling)`; `id`, `name`, `isVisible`, `opacity`, `blendMode` and `activeLayerIndex` unchanged; `dpi = request.dpi`. Result `isConsistent`.
   - **DPI-only change** (same size, different DPI, e.g. print-size edits that round back to the same pixels): layers are reused unchanged (tiles shared), only `dpi` changes; selection kept; still one "Resize Image" step.
   - **Selection:** when the size changes, the after-state has `selection = nil` (Paint.NET deselects; Open question 1). The before-state keeps it, so undo restores it.
   - **Floating pixels:** precondition `state.floatingPixels == nil` (the command calls `prepareForNavigation` first); the after-state has `floatingPixels == nil`.
   - **History:** `DocumentSnapshotHistoryItem(name: "Resize Image", icon: .resizeImage, before:, after:)`; `.structure`; cost per 0008/0013.
   - Throws `CancellationError` when cancelled (from the resampler).

3. **`Core/Operations/ResizeImageForm.swift`** (new) — all dialog state and arithmetic, so the SwiftUI view only binds:
   ```swift
   public enum ResizeBy: String, Sendable { case percentage, absoluteSize }
   public enum PrintUnit: String, CaseIterable, Sendable { case inches, centimeters   // "inches"/"centimeters"; resolution "pixels/inch"/"pixels/centimeter"
   }
   public struct ResizeImageForm: Equatable, Sendable {
       public init(imageSize: PixelSize, dpi: Double, layerCount: Int, unit: MeasurementUnit)
       public var resampling: ResamplingMode          // default .bicubic (Paint.NET 5 default)
       public var resizeBy: ResizeBy                  // default .percentage
       public var maintainAspectRatio: Bool           // default true
       public private(set) var percentageText: String // "100"
       public private(set) var widthText, heightText: String              // pixels
       public private(set) var printWidthText, printHeightText: String    // 2 decimals
       public private(set) var resolutionText: String                      // up to 2 decimals, trailing zeros trimmed ("96", "37.8")
       public private(set) var printUnit: PrintUnit   // .centimeters when unit == .centimeters, else .inches
       public mutating func setPercentageText(_:)
       public mutating func setWidthText(_:); mutating func setHeightText(_:)
       public mutating func setPrintWidthText(_:); mutating func setPrintHeightText(_:)
       public mutating func setResolutionText(_:); mutating func setPrintUnit(_:)
       public mutating func setMaintainAspectRatio(_:); mutating func setResizeBy(_:)
       public var pixelFieldsEnabled: Bool            // resizeBy == .absoluteSize
       public var newSizeBytes: Int?                  // w × h × 4 × layerCount of the current candidate (nil when unparsable/overflow)
       public func validate(limits: ImageLimits) -> Result<ResizeImageRequest, ResizeImageValidationError>
   }
   public enum ResizeImageValidationError: Error, Equatable, Sendable {
       case invalidPercentage, invalidWidth, invalidHeight, invalidPrintWidth, invalidPrintHeight, invalidResolution
       case tooLarge(width: Int, height: Int)
       public var message: String
   }
   ```
   - **Initial values:** percentage "100"; width/height = image size; resolution = image DPI in the print unit (cm: `dpi / 2.54`); print size = `pixels / dpi` (in) or `pixels / dpi · 2.54` (cm), 2 decimals half away from zero ("." separator, like 0004).
   - **Rounding of every computed pixel value:** `max(1, Int((v).rounded(.toNearestOrAwayFromZero)))`.
   - **Percentage edits** (only meaningful in `.percentage`): a whole number ≥ 1 → width = round(oldW · p / 100), height = round(oldH · p / 100) (aspect always kept in percentage mode, as in Paint.NET); print fields recomputed from the new pixels and the current resolution. The pixel/print fields are shown disabled but updated.
   - **Width edit** (absolute): parsed width w → if aspect kept, height = round(w · oldH / oldW); print fields follow. **Height edit** symmetric. Aspect ratio is always the **original image's** ratio (not the last typed pair), so repeated edits don't drift.
   - **Print width edit:** pixels = round(print · dpi) (in) or round(print / 2.54 · dpi) (cm), then as a width edit (aspect), then the print height is recomputed; the print width field keeps the typed text. **Print height** symmetric.
   - **Resolution edit:** keeps the **print size** and recomputes the pixel size from it (pixels = round(print · newDPI)) — Open question 4. Resolution units follow `printUnit`.
   - **Print unit change:** converts the displayed print sizes and resolution (96 ppi ↔ "37.8" pixels/centimeter); pixels unchanged.
   - **Unparsable text** in any field: that field keeps the typed text; dependent fields keep their last values; `validate` reports it.
   - **Switching to absolute size** keeps the current computed values in the fields; switching back to percentage recomputes from the percentage.
   - **Validation** (order: percentage (if percentage mode) → width → height → print width → print height → resolution → limits). Width/height: ASCII digits only, 1…65,535. Percentage: ASCII digits, ≥ 1, and the resulting sides must be ≤ 65,535 (else `.invalidWidth`/`.invalidHeight`). Print sizes: a finite decimal > 0 ("." or the locale's separator). Resolution: a finite decimal whose DPI (cm × 2.54) lies in 1…10,000. Limits: `limits.validate` → any `ImageLimitError` → `.tooLarge`. The request's DPI is the parsed resolution converted to pixels/inch (unchanged DPI if the text was never edited — no float drift: keep the original `Double` until the resolution field is edited).
   - **Messages (exact):** `.invalidPercentage` "Percentage must be a whole number greater than 0."; `.invalidWidth` "Width must be a whole number from 1 to 65,535 pixels."; `.invalidHeight` "Height must be a whole number from 1 to 65,535 pixels."; `.invalidPrintWidth` "Print width must be a number greater than 0."; `.invalidPrintHeight` "Print height must be a number greater than 0."; `.invalidResolution` "Resolution must be a number from 1 to 10,000 pixels/inch."; `.tooLarge` "The image is too large. An image of <w> × <h> pixels needs more memory than PaintDotMac allows." (same formatting as 0005: `en_US` grouping, U+00D7).

### Platform glue (AppKit/SwiftUI; UI tests, hosted tests, manual checks)

4. **`App/MainMenu.swift`** (extend 0022/0024): in `menu.image`, directly after "Crop to Selection" and before the Flatten separator: **"Resize…"** key `r`, modifiers ⌘, action `resizeImage(_:)`, target nil, identifier `menu.image.resizeImage`. (0036 inserts "Canvas Size…" `menu.image.resizeCanvas` after it; 0037 inserts its Flip/Rotate group after that.) The full Image menu after this spec is: Crop to Selection ⇧⌘X, Resize… ⌘R, separator, Flatten ⇧⌘F. Update `MainMenuTests.imageMenuItems` to that exact list; `noDuplicateShortcuts` must still pass.

4a. **`Core/Operations/ImageCommandRule.swift`** (new, pure) — the one enablement rule shared by every whole-image command from here on (0035 Resize, 0036 Canvas Size, 0037 Flip/Rotate); same shape as 0031's `EffectMenuRule` without the effect-only parameters:
   ```swift
   public enum ImageCommandRule {
       /// hasDocument && !isGestureInProgress && !isBusy && !hasSheet
       public static func isEnabled(hasDocument: Bool, isGestureInProgress: Bool, isBusy: Bool, hasSheet: Bool) -> Bool
   }
   ```

5. **`UI/ResizeImageDialog.swift`** (new, SwiftUI, hosted in a sheet per 0025's pattern: `NSHostingController`, `window.beginSheet`, sheet delegate returns a private `UndoManager`). Title "Resize Image". Binds an `@Observable ResizeImageDialogModel` (same file) that wraps `ResizeImageForm` and calls its setters; no arithmetic in the view. Layout top to bottom (Paint.NET order):
   - "New size: <bytes>" (`ByteCountFormatter`, `.memory` style, from `newSizeBytes`; "—" when nil) — `resizeImage.newSize`.
   - "Resampling:" pop-up `resizeImage.resampling` with items in order Bicubic, Bilinear, Nearest Neighbor, Supersampling.
   - Radio "By percentage:" `resizeImage.byPercentage` + field `resizeImage.percentage` + "%".
   - Radio "By absolute size" `resizeImage.byAbsoluteSize`; checkbox "Maintain aspect ratio" `resizeImage.maintainAspectRatio`.
   - "Pixel size" group: "Width:" `resizeImage.width` "pixels", "Height:" `resizeImage.height` "pixels".
   - "Print size" group: "Width:" `resizeImage.printWidth`, "Height:" `resizeImage.printHeight` (unit label "inches"/"centimeters"), "Resolution:" `resizeImage.resolution` + pop-up `resizeImage.resolutionUnit` ("pixels/inch", "pixels/centimeter").
   - Buttons "Cancel" (`resizeImage.cancel`, Escape) and "OK" (`resizeImage.ok`, Return).
   - Fields commit on every keystroke to the model (so dependents update live, as in Paint.NET). Pixel/print/resolution controls disabled in percentage mode; the percentage field disabled in absolute mode. The percentage field has focus with its text selected when the sheet opens. Root identifier `resizeImageDialog`.
   - The dialog's settings are not remembered between openings (each opens with the defaults above; Open question 5).

6. **`Document/ResizeImageCommand.swift`** (new, `@MainActor`) — the testable command driver:
   ```swift
   @MainActor enum ResizeImageCommand {
       enum Outcome: Equatable { case applied, noOp, cancelled, stale, failed(ResizeImageError) }
       /// Window-controller entry (static for hosted tests): nil when ignored (`ImageCommandRule` false: gesture in
       /// progress, bridge.isBusy, sheet attached) — then prepareForNavigation is NOT called; else calls
       /// bridge.prepareForNavigation?() exactly once (reason .command) and returns the initial form.
       static func begin(bridge: UndoBridge, gestureInProgress: Bool, hasSheet: Bool, unit: MeasurementUnit) -> ResizeImageForm?
       /// Precondition: begin() already ran (no floating pixels). Sets bridge.isBusy = true for the run.
       static func run(bridge: UndoBridge, request: ResizeImageRequest, limits: ImageLimits,
                       onProgress: @escaping @MainActor (Double) -> Void) async -> Outcome
   }
   ```
   - If `ResizeImage.isNoOp` → `.noOp` (no step, busy never set).
   - Capture `before = bridge.state` and `stepID = bridge.history.currentStepID`; `bridge.isBusy = true`; run `ResizeImage.resizedState` in `Task.detached(priority: .userInitiated)` (cancellation of the awaiting task is forwarded); progress hops to the main actor.
   - On success: `bridge.isBusy = false`; if `bridge.history.currentStepID != stepID` → `.stale` (defensive; busy blocks edits); else `bridge.perform(ResizeImage.makeHistoryItem(before:after:))` → `.applied` (the `.structure` change reaches 0021's `withImageSize` hook).
   - `CancellationError` → `bridge.isBusy = false`, `.cancelled`, state untouched. `ResizeImageError` → `.failed`.

7. **`Document/DocumentWindowController.swift`** (extend):
   - `@objc func resizeImage(_:)`: `guard let form = ResizeImageCommand.begin(bridge: undoBridge, gestureInProgress: AppModel.shared.dispatcher.isGestureInProgress, hasSheet: window?.attachedSheet != nil, unit: AppSettings().measurementUnit)` (`begin` returns nil while busy, mid-gesture, or with a sheet; otherwise it runs `undoBridge.prepareForNavigation?()` — reason `.command`: floating pixels record "Finish Pixels", 0038–0040 commit shapes/text — and builds `ResizeImageForm(imageSize:dpi:layerCount:unit:)` from `undoBridge.state`); present the sheet.
   - OK: `form.validate(limits: PaintDocument.imageLimits)`; failure → `NSAlert` (message = `error.message`, button "OK") as a sheet on the dialog sheet; the dialog stays open with the typed values. Success → close the dialog, start `ResizeImageCommand.run` in a `Task` stored on the controller; after **0.5 s** without finishing present 0031's `EffectProgressView` (item 16) as a sheet with the title "Resize Image", the command's progress fraction, and a Cancel/Escape action that cancels the task. 0031 defines the view's title as a plain string (its effect path passes `effect.name`) with the fraction and the cancel action supplied by the presenter, so the view is reused as is — no second progress view and no change to it. Dismiss on finish. `.failed` → alert with the `.tooLarge` message (reached only if the limits changed in between). Cancel/Escape in the dialog → close, no change.
   - `validateMenuItem`: `resizeImage(_:)` enabled iff `ImageCommandRule.isEnabled(hasDocument: true, isGestureInProgress: AppModel.shared.dispatcher.isGestureInProgress, isBusy: undoBridge.isBusy, hasSheet: window?.attachedSheet != nil)`. It does not require a selection.
   - `windowShouldClose` while the resize runs: cancel the task (the state was never touched, so nothing to restore), clear busy, then the normal close flow.
   - No change to `onStateChange`: 0021's `.structure` branch applies `withImageSize`, updates the canvas, status bar size, ants (selection gone).

8. `project.yml`: no target changes; run `xcodegen generate` (new files). No PRD/AGENTS edits in this spec (sub-agent rule); decisions to confirm are under Open questions.

### Performance (NF-4; resize has no NF target)
- Memory: the band buffer is bounded (`rows needed × newWidth × 32 bytes`); the history step costs all old + all new tiles (`unsharedTileBytes`). Targets in the Debug test build: 4000×3000 opaque single layer → 2000×1500 Bicubic < 1.5 s, Supersampling < 1.0 s, Nearest < 0.3 s; 4000×3000 → 6000×4500 Bicubic < 4 s. Gate at 3× each; report measured numbers in Verification status.

## Acceptance criteria

- [ ] Image ▸ **Resize…** ⌘R sits after Crop to Selection and before the Flatten separator; disabled while busy, mid-gesture, or with a sheet attached. → `MainMenuTests.imageMenuItems`, `.noDuplicateShortcuts`, `ImageCommandRuleTests.enablement`; UI `ResizeImageUITests.testOpenAndCancel`
- [ ] `ResamplingMode` has exactly nearestNeighbor, bilinear, bicubic, supersampling with Paint.NET display names; the dialog lists Bicubic, Bilinear, Nearest Neighbor, Supersampling and defaults to Bicubic. → `ResamplerResizeTests.modesAndNames`, `ResizeImageFormTests.defaults`
- [ ] Nearest Neighbor picks the source pixel under each destination centre (integer formula) and preserves colour under alpha 0. → `ResamplerResizeTests.nearestUpscale2x`, `.nearest4to3`, `.nearestKeepsColorUnderZeroAlpha`
- [ ] Bilinear and Bicubic use clamped edges, premultiplied math, and the stated rounding; hand-computed 2×2 → 4×4 values match exactly. → `ResamplerResizeTests.bilinear2x2to4x4`, `.bicubic2x2to4x4`, `.cubicWeights`, `.axisTapsBicubic2to4`, `.premultipliedNoBleed`, `.bicubicOvershootClamped`, `.downscale4to2`
- [ ] Supersampling area-averages when shrinking (4×4 → 2×2 exact means; 3 → 2 fractional overlaps) and falls back to Bicubic when either side grows. → `ResamplerResizeTests.supersampling4x4to2x2`, `.supersampling3to2`, `.supersamplingEnlargeUsesBicubic`, `.effectiveModeTable`
- [ ] Resizing keeps dimensions, works across tile seams, handles sparse layers, and matches a naive per-pixel oracle. → `ResamplerResizeTests.matchesOracleAcrossSeams`, `.sparseStaysSparse`, `ResamplerResizePropertyTests.randomResizesMatchOracle`
- [ ] Every layer (hidden too) is resized; layer properties and active layer are kept; DPI is the request's; the selection is cleared; one "Resize Image" step (`.resizeImage`, `.structure`). → `ResizeImageTests.allLayersResized`, `.layerPropertiesKept`, `.selectionCleared`, `.historyItem`, `.dpiOnlyChange`
- [ ] Same size and DPI adds no step. → `ResizeImageTests.noOp`, `ResizeImageCommandTests.noOpAddsNoStep`
- [ ] Undo restores size, pixels, layers, DPI and selection exactly; redo restores the resized state. → `ResizeImageIntegrationTests.undoRedoRoundTrip`; UI `testAbsoluteSizeNearestUndoRedo`
- [ ] Sizes outside 1…65,535 or beyond the memory cap are refused with the exact alert, the dialog stays open, nothing changes, nothing crashes. → `ResizeImageFormTests.validation*`, `ResizeImageTests.limitsCheckedBeforeAllocation`; UI `testInvalidWidthAlert`, `testTooLargeAlert`
- [ ] Percentage, aspect ratio, print size, resolution and unit arithmetic follow the rules above. → `ResizeImageFormTests.*`; UI `testPercentageSupersampling`, `testResolutionChangesPixelsAndDPI`
- [ ] The resize runs off the main actor with monotonic progress, can be cancelled with no change, and blocks the document while running. → `ResamplerResizeTests.cancellation`, `.progressMonotonic`, `ResizeImageCommandTests.cancelLeavesStateUntouched`, `.busyFlagLifecycle`, `.staleResultDiscarded`; manual 2
- [ ] A pending edit is committed before the dialog opens. → `ResizeImageCommandTests.commitsPendingEditFirst`
- [ ] After a resize (and its undo/redo) the zoom stays and the image is re-centred; the status bar shows the new size. → 0021's `CanvasTransformNavigationTests.withImageSize*` (reused), `ResizeImageIntegrationTests.undoRedoRoundTrip` (`.structure` received); UI `testAbsoluteSizeNearestUndoRedo` (`statusBar.zoom` unchanged)
- [ ] Performance targets met within the 3× gate. → `ResizeImagePerformanceTests.*`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **1×1 source → any size:** every destination pixel equals the source pixel (all kernels; clamped taps). → `ResamplerResizeTests.oneByOneUpscale`
- **Any → 1×1:** Nearest picks the centre pixel (`floor(W/2)`, `floor(H/2)`); Supersampling = the premultiplied mean of all pixels. → `.downscaleToOnePixel`
- **Extreme aspect** 65,535×1 → 1,000×1 (Supersampling) and 1×1 → 65,535×1 (Bicubic): completes; markers at both ends correct; no full-image Double buffer. → `.extremeAspect`
- **Rounded side becomes 0** (1% of 50 px): clamped to 1. → `ResizeImageFormTests.percentageClampsToOne`
- **Percentage producing > 65,535 px:** `.invalidWidth`/`.invalidHeight`. → `.validationPercentageTooLarge`
- **Memory cap** (Debug `-UITestMemoryCapBytes`): `.tooLarge` alert. → `.validationTooLarge`, UI `testTooLargeAlert`
- **Transparent/semi-transparent pixels:** `(255,0,0,255)` next to `(0,0,255,0)`: bilinear 2→4 gives `(255,0,0,255)`, `(255,0,0,191)`, `(255,0,0,64)`, `(0,0,0,0)`; bicubic gives `(255,0,0,255)`, `(255,0,0,203)`, `(255,0,0,52)`, `(0,0,0,0)` — no blue bleed. → `.premultipliedNoBleed`
- **Bicubic overshoot:** gray `[0,255]` 2→4 → `[0, 52, 203, 255]` (−17.9 and 272.9 clamped). → `.bicubicOvershootClamped`
- **Empty (no tiles) layer:** result has no tiles. → `.sparseStaysSparse`
- **Same size, different resampling:** no-op (no step). **Same size, different DPI:** DPI-only step, tiles shared. → `ResizeImageTests.noOp`, `.dpiOnlyChange`
- **Cancel in the dialog / Escape:** no change, no step. **Cancel on the progress sheet:** no change, no step, busy cleared. → `ResizeImageCommandTests.cancelLeavesStateUntouched`; UI `testOpenAndCancel`
- **Window closed during the run:** task cancelled, no crash, normal close prompt. → manual 3
- **⌘R mid-gesture, while an effect runs (busy), or with a sheet attached:** disabled / `begin` returns nil. → `ImageCommandRuleTests.enablement`, `ResizeImageCommandTests.ignoredWhileBusyOrGesture`
- **Floating pixels / uncommitted shape or text:** committed before the dialog opens (one extra step even if the dialog is then cancelled — same as opening an effect dialog in 0031). → `.commitsPendingEditFirst`
- **Invalid DPI text** ("0", "abc", "20000", cm "4000" → 10,160 dpi): `.invalidResolution`. → `.validationResolution`
- **Locale decimal separator** "37,8" accepted only when the locale uses ","; width "1,024" rejected. → `.validationLocale`
- **Undo budget (H-5):** a big resize step is counted like any snapshot step; no special case.

## Test plan

Expected values below are hand-computed (and double-checked with an independent script while writing this spec), never taken from the code under test. Gray opaque pixels written as one number `v` mean `(v,v,v,255)`. Rounding is `floor(x + 0.5)` then clamp 0…255.

- **Unit — `PaintDotMacTests/Rendering/ResamplerResizeTests.swift`:**
  - `modesAndNames`: `ResamplingMode.allCases` raw values `["nearestNeighbor","bilinear","bicubic","supersampling"]`; display names "Nearest Neighbor", "Bilinear", "Bicubic", "Supersampling".
  - `cubicWeights`: `cubicWeight(0) == 1`, `(1) == 0`, `(2) == 0`, `(0.25) == 0.8671875`, `(0.75) == 0.2265625`, `(1.25) == −0.0703125`, `(1.75) == −0.0234375` (exact in binary), symmetric for negatives, `(2.5) == 0`.
  - `axisTapsBicubic2to4`: `axisTaps(sourceLength: 2, destinationLength: 4, kernel: .bicubic)` merged per source index = `[[0: 1.0703125, 1: −0.0703125], [0: 0.796875, 1: 0.203125], [0: 0.203125, 1: 0.796875], [0: −0.0703125, 1: 1.0703125]]`; bilinear 2→4 = `[[0:1],[0:0.75,1:0.25],[0:0.25,1:0.75],[1:1]]`; every row sums to 1.
  - `bilinear2x2to4x4`: source `[[0,100],[200,40]]` (rows y=0,1) → expected rows `[0,25,75,100]`, `[50,59,76,85]`, `[150,126,79,55]`, `[200,160,80,40]` (exact values 58.75, 76.25, 126.25, 78.75 before rounding).
  - `bicubic2x2to4x4`: same source → `[0,10,80,113]`, `[37,50,78,91]`, `[167,138,74,45]`, `[227,178,72,23]` (pre-rounding: −22.379 (clamped), 9.963, 80.193, 112.535 / 37.307, 50.210, 78.228, 91.130 / 166.912, 137.603, 73.960, 44.651 / 226.598, 177.849, 71.995, 23.246).
  - `downscale4to2`: 4×1 `[0,85,170,255]` → bilinear `[43,213]` (42.5, 212.5); bicubic `[37,218]` (37.1875, 217.8125); supersampling `[43,213]`; nearest `[85,255]` (indices 1, 3).
  - `nearestUpscale2x`: 2×2 distinct colours → 4×4 with each source pixel replicated in a 2×2 block. `nearest4to3`: 4×1 `[a,b,c,d]` → `[a,c,d]`; 3→2 → `[p0,p2]`.
  - `nearestKeepsColorUnderZeroAlpha`: `(10,20,30,0)` replicated unchanged.
  - `premultipliedNoBleed`: 2×1 `[(255,0,0,255),(0,0,255,0)]` → 4×1, bilinear `[(255,0,0,255),(255,0,0,191),(255,0,0,64),(0,0,0,0)]`, bicubic `[(255,0,0,255),(255,0,0,203),(255,0,0,52),(0,0,0,0)]`.
  - `bicubicOvershootClamped`: 2×1 `[0,255]` → 4×1 `[0,52,203,255]`; bilinear `[0,64,191,255]`; bilinear 2→3 `[0,128,255]` (127.5 rounds up).
  - `supersampling4x4to2x2`: 4×4 gray `v(x,y) = 10 + 10x + 40y` → `[[35,55],[115,135]]`; with alpha: top-left 2×2 block `(200,0,0,255)`, `(200,0,0,255)`, `(0,0,0,0)`, `(0,0,0,0)` → `(200,0,0,128)` (A = 127.5 → 128; colour 200).
  - `supersampling3to2`: 3×1 `[0,90,255]` → `[30,200]` (weights (1, 0.5)/1.5 and (0.5, 1)/1.5).
  - `supersamplingEnlargeUsesBicubic`: 2×2 → 4×4 Supersampling equals the `bicubic2x2to4x4` expectation; 4×2 → 2×4 (width shrinks, height grows) also bicubic.
  - `effectiveModeTable`: (supersampling, 100×100 → 50×50) `.areaAverage`; (→ 100×50) `.areaAverage`; (→ 101×50) `.bicubic`; (→ 100×100) `.areaAverage`; other modes map 1:1.
  - `identityIsUnchanged`: each mode, same size → returned surface tiles `sharesStorage` with the source.
  - `oneByOneUpscale`: 1×1 `(9,8,7,200)` → 5×3 all `(9,8,7,200)` for all modes.
  - `downscaleToOnePixel`: 3×3 → 1×1 nearest = pixel (1,1); supersampling of gray 0…80 step 10 = 40.
  - `matchesOracleAcrossSeams`: 600×300 seeded random (seed printed) with ~30% alpha-0 pixels → 257×513 and 1000×97 per mode; every pixel equals a naive oracle in the test target (`PaintDotMacTests/Rendering/ResizeReference.swift`: direct per-pixel 2-D tensor-product loops written from this spec's formulas, not calling `axisTaps`) — exact for nearest, **±1 per channel** for bilinear/bicubic/supersampling (summation order may differ).
  - `sparseStaysSparse`: 1024×1024 with no tiles → 300×300 no tiles; with only tile (0,0) allocated → 2048×2048 nearest: tiles outside the upscaled area are unallocated.
  - `extremeAspect`: 65,535×1 gray ramp `x % 256` → 1,000×1 supersampling: pixel 0 equals the oracle mean of source 0…65.535 window (±1); 1×1 → 65,535×1 bicubic: all equal.
  - `cancellation`: resize 4000×4000 in a `Task`, cancel after the first progress call → throws `CancellationError`; progress called fewer than `totalBands` times.
  - `progressMonotonic`: 1000×1000 → 600×600: progress values strictly increasing, last == 1.0, count == 3 (bands of 256 destination rows).
  - `affineBicubicTransparentOutside`: 0020-style `sample(at:)` with `.bicubic` on a 1×1 opaque red at the pixel centre → `(255,0,0,255)`; at 2 px outside → `(0,0,0,0)`; `.supersampling` sample equals `.bilinear` sample at (1.0, 0.5) for 0020's `bilinearIgnoresColorUnderZeroAlpha` fixture.
- **Round-trip / property — `PaintDotMacTests/Rendering/ResamplerResizePropertyTests.swift`:** `randomResizesMatchOracle` — 40 seeded iterations (seed printed): random source 1…400 per side, random target 1…500, random mode → result size == target; all pixels within ±1 of the oracle (nearest exact); alpha-0 result pixels are `(0,0,0,0)` for non-nearest modes; `upThenDownNearestIsIdentity` — nearest ×3 then ÷3 returns identical bytes.
- **Unit — `PaintDotMacTests/Operations/ResizeImageTests.swift`:** `allLayersResized` (3 layers, one hidden, 8×6 → 16×12 nearest: every layer's pixel (2x,2y) == source (x,y)); `layerPropertiesKept` (ids, names, visibility, opacity 77, blend mode, `activeLayerIndex 1`, `isConsistent`); `selectionCleared` (selection rect before → after `selection == nil`; before-state keeps it); `historyItem` (name "Resize Image", icon `.resizeImage`, change `.structure`); `noOp` (same size + same DPI → `isNoOp`, `resizedState` returns nil, for every mode); `dpiOnlyChange` (same size, dpi 96 → 300: tiles share storage, dpi 300, selection kept); `limitsCheckedBeforeAllocation` (cap 1,023, request 16×16 → throws `.limitExceeded(.exceedsMemoryCap(requiredBytes: 1024, capBytes: 1023))`; 65,536 wide → `.dimensionsOutOfRange`); `progressSpansLayers` (2 layers → progress reaches 0.5 after the first layer, ends at 1.0, monotonic).
- **Unit — `PaintDotMacTests/Operations/ResizeImageFormTests.swift`:** `defaults` (800×600 @96, unit px → "100", "800", "600", print "8.33"/"6.25" in, resolution "96", `.inches`, `.bicubic`, `.percentage`, aspect on; unit cm → print "21.17"/"15.88" cm, resolution "37.8"); `percentage` (50 → 400×300, print "4.17"/"3.13"; 33 on 800×600 → 264×198; 1 on 50×50 → 1×1 `percentageClampsToOne`); `aspectWidthEdit` (absolute, width "1000" → height "750"; width "333" → 250 (249.75); aspect off → height unchanged); `aspectHeightEdit` (height "301" → width 401 (401.33)); `noDriftOnRepeatedEdits` (width 333 → 250, then width 800 → height 600); `printWidthEdit` (in: "2" @96 → width 192, height 144; cm: "5.08" @96 → 192); `resolutionEditKeepsPrintSize` (print 8.33 in kept; resolution "192" → 1600×1200; text "8.33" unchanged, internal print size uses the unrounded 800/96); `unitSwitch` (96 ppi → "37.8" ppcm; print "8.33" → "21.17"; pixels unchanged); `unparsableKeepsDependents` (width "abc" → height stays 600; `validate` → `.invalidWidth`); `newSizeBytes` (800×600, 3 layers → 5,760,000); `validationOrder` (bad percentage and bad width in percentage mode → `.invalidPercentage`); `validationPercentageTooLarge` (65,535×10 at 200% → `.invalidWidth`); `validationResolution` ("0", "abc", "20000", cm "4000" → `.invalidResolution`; cm "3937" → valid, dpi 9999.98); `validationTooLarge` (cap 1,023, 16×16 → `.tooLarge(16,16)`, message exact); `validationLocale` (de_DE: "37,8" ok; "1,024" width invalid); `requestDPIUnchangedWhenNotEdited` (dpi 72.27 → request dpi exactly 72.27); `messagesExact` (all seven strings).
- **Unit — `PaintDotMacTests/Operations/ImageCommandRuleTests.swift`:** `enablement` — `ImageCommandRule.isEnabled` over all 16 combinations of (hasDocument, isGestureInProgress, isBusy, hasSheet) → true only for `(true, false, false, false)`. (0036 and 0037 reuse this rule and test.)
- **Hosted — `PaintDotMacTests/Document/ResizeImageCommandTests.swift`** (`@MainActor`, real `UndoBridge`): `appliesOneStep` (400×300 → 200×150 bicubic: `.applied`, history ends "Resize Image", `state.image.size == 200×150`, `onStateChange` got `.structure`); `noOpAddsNoStep`; `busyFlagLifecycle` (true while awaiting, false after applied/cancelled/failed); `cancelLeavesStateUntouched` (cancel the awaiting task right after start on a 4000×4000 image → `.cancelled`, state tiles `sharesStorage` with before, no step); `staleResultDiscarded` (simulate a step recorded during the run via a test hook on the bridge → `.stale`, no resize step); `commitsPendingEditFirst` (`ResizeImageCommand.begin` calls `prepareForNavigation` exactly once before building the form; a fake commit recording "Finish Pixels" precedes "Resize Image" after `run`); `ignoredWhileBusyOrGesture` (`begin` returns nil and calls no `prepareForNavigation` when `bridge.isBusy`, `gestureInProgress`, or `hasSheet` is true).
- **Integration — `PaintDotMacTests/Operations/ResizeImageIntegrationTests.swift`:** `undoRedoRoundTrip` — "New Image" 1000×700 white; a "Paintbrush" `TileDiffHistoryItem` (red rect (100,100,50,50)); a "Rectangle Select"; Add New Layer (0024); run the command 1000×700 → 500×350 supersampling, dpi 96 → names `["New Image","Paintbrush","Rectangle Select","Add New Layer","Resize Image"]`; pixel (60,60) == red (area of red block 100…149 → 50…74.5), (300,300) white; undo → size 1000×700, every tile of both layers equal (storage shared) to before, selection restored, dpi 96; redo → equals the resized state.
- **Menu — `PaintDotMacTests/App/MainMenuTests.swift`:** `imageMenuItems` now exactly `[Crop to Selection ⇧⌘X (cropToSelection:, menu.image.cropToSelection), Resize… ⌘R (key "r", [.command], resizeImage:, menu.image.resizeImage), separator, Flatten ⇧⌘F (flattenImage:, menu.image.flatten)]`; 0024's `imageMenuFlattenLast` and `noDuplicateShortcuts` pass.
- **UI — `PaintDotMacUITests/ResizeImageUITests.swift`** (fixture `UITestFixtures.writePNG` 400×300, pixel `(x % 256, y % 256, 128, 255)`, 96 DPI unless stated):
  - `testOpenAndCancel`: ⌘R → `resizeImageDialog` appears; `resizeImage.percentage` "100", `resizeImage.resampling` "Bicubic", `resizeImage.width` disabled; Escape → gone, `statusBar.imageSize` "400 × 300", no new `historyRow`.
  - `testAbsoluteSizeNearestUndoRedo`: note `statusBar.zoom`; ⌘R, click `byAbsoluteSize`, type "800" into width → height reads "600"; resampling "Nearest Neighbor"; OK → `statusBar.imageSize` "800 × 600", zoom unchanged, History row "Resize Image"; ⌘S, decode → (0,0) and (1,1) == `(0,0,128,255)`, (2,0) == `(1,0,128,255)`, (799,599) == `(143,43,128,255)`; ⌘Z → "400 × 300"; ⇧⌘Z → "800 × 600".
  - `testPercentageSupersampling`: fixture 400×300 of 2×2 blocks with constant colours `(bx·10 % 256, by·10 % 256, 0, 255)` per block (bx = x/2); ⌘R, percentage "50", Supersampling, OK → "200 × 150"; save, decode → (x,y) == `(x·10 % 256, y·10 % 256, 0, 255)` at 4 sample points (exact: area average of a constant block).
  - `testResolutionChangesPixelsAndDPI`: ⌘R, absolute, resolution "192" → width "800", height "600" (print size kept); OK → "800 × 600"; ⌘S, decode → DPI within 0.05 of 192.
  - `testInvalidWidthAlert`: ⌘R, absolute, width "65536", OK → alert text "Width must be a whole number from 1 to 65,535 pixels."; OK → dialog still shown with "65536"; Cancel.
  - `testTooLargeAlert`: launch with `-UITestMemoryCapBytes 500000`; ⌘R, percentage "200", OK → alert "The image is too large. An image of 800 × 600 pixels needs more memory than PaintDotMac allows."; image unchanged.
  - `testSelectionClearedAndRestored`: launch with `-UITestSelectRect 10,10,50,50`; ⌘R, percentage "50", OK → Edit ▸ Deselect disabled (D-40: no selection); ⌘Z → Deselect enabled.
- **Performance — `PaintDotMacTests/Performance/ResizeImagePerformanceTests.swift`** (XCTest `measure`): `testBicubicDown4000x3000` (< 4.5 s gate), `testSupersamplingDown4000x3000` (< 3 s), `testNearestDown4000x3000` (< 0.9 s), `testBicubicUp4000x3000To6000x4500` (< 12 s). Report numbers.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build, no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open a photo, ⌘R, 50% Bicubic, then ⌘Z, 50% Supersampling: both look smooth; Nearest Neighbor at 50% shows aliasing (expected). Enlarge a small pixel-art image 400% with Nearest Neighbor: crisp blocks.
  2. Open a ~12000×8000 image, ⌘R to 200% (if within the memory cap) or 150%: a progress sheet appears after ~0.5 s; Escape → image unchanged, no History row; repeat and let it finish → one "Resize Image" row; while it runs the canvas ignores clicks and Undo is disabled.
  3. Start a long resize and close the window: no crash; the normal close prompt (if edited) appears.
  4. In the dialog switch the resolution unit to pixels/centimeter and back: values convert; edit print width in centimetres: pixel width follows; uncheck Maintain aspect ratio and set 300×100: the image stretches.
  5. A transparent PNG with soft edges resized with Bicubic shows no dark/colored fringes.

## Open questions

1. **Selection after Resize Image.** This spec clears the selection (as Paint.NET does after a resize, as far as can be checked without its current source), and undo restores it. The alternative is scaling the selection with the image. Recommended: clear it, as written. Needs a PRD §5.5 IMG-2 / §12 entry.
2. **What "Supersampling" does when enlarging.** Paint.NET 5 no longer has "Supersampling"; Paint.NET 3.x/4.x's Supersampling area-averages when shrinking and uses Bicubic otherwise (Paint.NET 5's closest equivalent, "Fant", uses Bilinear when enlarging). This spec uses area average when neither side grows, else Bicubic. Recommended: yes, as written.
3. **Bilinear/Bicubic when shrinking.** This spec implements the classic point-sampled 2×2 Bilinear and 4×4 Catmull-Rom Bicubic (a = −0.5), which alias on strong reductions; Paint.NET 5's "Bilinear"/"Bicubic" widen the kernel when shrinking (its 2×2 version is listed as "Bilinear (Low Quality)"). Supersampling is the quality choice for shrinking. Recommended: keep the simple kernels in v1.0 (exact, testable), as written.
4. **Editing the resolution.** This spec keeps the print size and recomputes the pixel size when the resolution changes (so 96 → 192 DPI doubles the pixels), and when the pixel size is edited the resolution is kept. Recommended: yes, as written (Paint.NET/Photoshop behavior with resampling on).
5. **Remembering dialog settings.** Each opening starts at By percentage 100%, Bicubic, Maintain aspect ratio on; nothing is remembered. Paint.NET 5's Gamma Correction checkbox and its extra resamplers (Bicubic (Smooth), Adaptive, Lanczos, Fant, Bilinear (Low Quality)) are not offered (PRD scopes four modes). Recommended: yes, as written.
6. **Initial print unit.** The print-size unit starts as centimetres when the status-bar unit (APP-5) is cm, otherwise inches. Recommended: yes, as written.

## Out of scope

- Resize Canvas ⇧⌘R (0036), Flip/Rotate (0037), Auto-crop (0061).
- Resizing a single layer (Paint.NET has no such command; v1.x layer transforms are 0060).
- Gamma-correct (linear-light) resampling, Lanczos, Fant, Adaptive, Bicubic (Smooth) (not in the PRD).
- Changing DPI without resampling (a separate "Image ▸ Resolution" command does not exist in Paint.NET's v1.0 scope here).
- Moving shortcuts into `ShortcutTable` (0045); remembering dialog values across launches.
