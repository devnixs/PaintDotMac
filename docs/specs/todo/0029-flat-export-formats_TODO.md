# 0029 — Save and open JPEG (with quality and size estimate), HEIC, TIFF, BMP, and GIF; open WebP; flatten layered images on export

> Source: PRD.md §5.11 F-3 (JPEG with a quality slider and a live file-size estimate on export), F-4 (HEIC), F-5 (TIFF, BMP, GIF first frame), F-6 (WebP: read now, write in 0063), FMT-A (multi-layer → flat: confirm and flatten on export only), FMT-B (save always embeds sRGB; EXIF orientation not written back; color under alpha 0 preserved), FMT-D (animated GIF/WebP open as the first frame, no warning), §5.11 "Saving" (⌘S keeps the document's format with the FMT-A confirmation; new documents default to `.ora`), APP-5 (per-document DPI written to flat files), APP-8 (default JPEG quality, exposed in 0046), §3 use case 2 ("export a JPEG at a chosen quality"), §12 D-6, D-7, D-16 (CPU compositor for export), D-24, D-33.
> Paint.NET references: JPEG save token API, https://paintdotnet.github.io/apidocs/api/PaintDotNet.IJpegFileTypeSaveToken.html (Quality range **0–100**, default **95**; chroma subsampling default 4:2:0); Paint.NET's flatten-on-save prompt has the buttons **Flatten** and **Cancel** (forum-documented, https://forums.getpaint.net/topic/4463-saving-layered-files-as-a-jpeg/, https://forums.getpaint.net/topic/107865-undo-flattening/). Paint.NET's own docs page for saving (`/doc/latest/SaveImage.html`) returned 404 on 2026-11-05, so the dialog wording below is ours (see *Open questions*).
> Milestone: M3
> Depends on: 0028-openraster-save-and-open (and through it 0024 multi-layer documents and `.layeredImageNeedsFlatten`, 0012 `CPUCompositor.flattened`, 0008 history-driven edited state and save hook, 0005 `FileFormat`/`ImageEncoder`/`SaveAction`/save glue, 0004 `AppSettings`, 0002 `ImageDecoder`, 0001 `project.yml` document types)

## Context

Not yet implemented; there is no application code. This spec builds on these names from earlier specs (don't add parallel types):

- **0002** `Core/IO/ImageDecoder.swift`: `ImageDecoder.decode(_:limits:) -> DecodedImage` / `decodeImage(from:limits:) -> LayeredImage` already decode **any** ImageIO-readable format (content-sniffed, not by type name), take frame 0 of animated images (FMT-D), convert ICC/CMYK/gray/16-bit/float to straight sRGB RGBA8, apply EXIF orientation, read DPI (default 96), and refuse truncated data (`CGImageSourceGetStatusAtIndex == .statusComplete`). 0002 Out of scope: "Document types and UTIs for HEIC, TIFF, BMP, GIF, and WebP, and their export (0029). The decoder already reads them." `Core/IO/ImageCodecError.swift` (`unrecognizedFormat`, `corrupt`, `limitExceeded`, 0005's `unsupportedWriteFormat(FileFormat)` and `encodingFailed`, 0024's `layeredImageNeedsFlatten`, 0028's archive errors).
- **0005** `Core/IO/FileFormat.swift` (`enum FileFormat: String, CaseIterable, Sendable`, `utType`, `typeIdentifier`, `preferredFilenameExtension`, `displayName`, `canRead`, `canWrite`, `init?(typeIdentifier:)`, `init?(fileExtension:)`, `writableFormats`, `defaultNewDocumentFormat`, `saveAction(for:) -> SaveAction`, `suggestedFilename(original:untitledName:format:)`), `enum SaveAction { case writeInPlace(FileFormat), saveAs(offering:suggested:) }`, `Core/IO/ImageEncoder.swift` (`encode(_ surface: TiledSurface, size:dpi:as:) throws(ImageCodecError) -> Data` — PNG via `CGImageDestination`, straight `.last` RGBA through a `CGDataProvider`, sRGB color space so the profile is embedded, DPI in `kCGImagePropertyDPIWidth/Height` + pHYs; `encode(_ image: LayeredImage, as:)`), `Document/PaintDocument.swift` (`writableTypes(for:)`, `fileNameExtension(forType:saveOperation:)`, `data(ofType:)`, `saveDocument(_:)` switching on `saveAction`, `prepareSavePanel(_:)`), `PaintDotMacUITests/Support/UITestApp.swift` (`saveThroughPanel(directory:name:)`, `decodePNG(at:)`). 0005 interim rule 2 ("JPEG-backed documents can't be saved in place yet … 0029 completes this: it makes JPEG writable (with its quality dialog), so ⌘S then writes JPEG in place") and interim rule 5 ("0029's `SavePlan` replaces this with flatten-on-export through `CPUCompositor`") are completed here.
- **0008** `PaintDocument.save(to:ofType:for:completionHandler:)` override that calls `undoBridge.prepareForNavigation?()` before `super` (commits a pending tool edit); `PaintDocument.image` forwards to `undoBridge.state.image`; edited state follows history; `.saveOperation`/`.saveAsOperation` mark the saved step, `.saveToOperation` and autosave don't.
- **0012** `Core/Rendering/CPUCompositor.swift`: `CPUCompositor().flattened(_ image: LayeredImage) -> TiledSurface` (visible layers with opacity > 0, bottom → top through `BlendOps`; starts transparent; unallocated result tiles stay unallocated).
- **0024** `ImageCodecError.layeredImageNeedsFlatten` (interim: a multi-layer PNG save throws "This image has more than one layer."; "0029 removes this case"), Layers menu "Add New Layer" ⇧⌘N (`menu.layers.addNewLayer`), Image > Flatten ⇧⌘F, tests `ImageEncoderTests.multiLayerNeedsFlatten`, `LayersMenuUITests.testMultiLayerSaveShowsFlattenHint`.
- **0028** `FileFormat.openRaster` (first case; `typeIdentifier "org.openraster.ora"`, `displayName "OpenRaster"`, `supports` reading/writing any layer count), `defaultNewDocumentFormat == .openRaster`, `FileFormat.suggestedSaveFormat(for:)` (document's format when writable, else `defaultNewDocumentFormat`), `PaintDocument.readableTypes = FileFormat.allCases.filter(\.canRead).map(\.typeIdentifier)`, `prepareSavePanel` relying on `NSDocument`'s built-in file-format popup (item titles "OpenRaster image"/"PNG image"; 0028 states that this spec replaces it), `CFBundleDocumentTypes` order ORA, PNG, JPEG (all `Editor`), `UTExportedTypeDeclarations` for ORA, `UITestFixtures.writeOpenRaster(…)`, `UITestApp.saveThroughPanel(directory:name:format:)` (selects a built-in popup item by title), `OpenRasterUITests`, tests `PaintDocumentOpenRasterTests.pngSaveOfLayeredImageSuggestsOra`, `FileFormatTests.suggestedSaveFormat`, `SmokeTests.documentTypes` (renamed from 0001's `documentTypesMapPNGAndJPEGToPaintDocument`), and `PaintDocumentSavingTests.writableTypesAreAllWritableFormats` (renamed from 0005's `writableTypesArePNGOnly`).
- **0004** `Core/Settings/AppSettings.swift` (`settings.*` keys, `.appSettingsDidChange`), `LaunchOptions.resettableKeyPrefixes` already contains `"settings."`.

ImageIO facts measured on the author's Mac (macOS 26.6, 2026-11-05) with a probe script; the implementer can rely on them and the tests below re-check them:

- `CGImageDestinationCopyTypeIdentifiers()` contains `public.jpeg`, `public.png`, `public.heic`, `public.tiff`, `com.microsoft.bmp`, `com.compuserve.gif`, **not** `org.webmproject.webp` (so WebP write is impossible through ImageIO here; F-6 "write only if the OS supports it" → 0063). `CGImageSourceCopyTypeIdentifiers()` contains `org.webmproject.webp` and `public.heic`.
- **TIFF** written from a straight `.last` sRGB `CGImage` is read back as straight `.last` with **byte-identical** RGBA, including the color under alpha 0, with or without LZW compression (`kCGImagePropertyTIFFCompression = 5`); DPI 300 → 300; profile "sRGB IEC61966-2.1".
- **BMP** from a `.last` image is written 32 bpp with alpha and reads back byte-identical (including alpha-0 colors); from a `.noneSkipLast` image it is written 24 bpp. DPI 300 reads back as 299.9994 (pixels-per-metre rounding). **No ICC profile** is written.
- **GIF**: ImageIO's own alpha cut-off is 64 (alpha ≥ 64 → opaque, < 64 → transparent), it drops the color of semi-transparent pixels to the palette, writes no DPI, and its palette quantizer is **exact for an image with 200 distinct opaque colors + transparency**, but **not** for 255 or 256 colors (384 byte differences in a 16×16 test).
- **HEIC** encodes straight RGBA with alpha (lossy), keeps DPI 300 and the sRGB profile.
- **JPEG** ignores alpha (we must flatten first); output is byte-for-byte **deterministic** for the same input and properties (so a size estimate made with the same encoder call equals the saved file size exactly); chroma subsampling is 4:2:0 (`0x22`) for quality < 1.0 and 4:4:4 (`0x11`) at quality 1.0; a 6000×4000 image encodes in ≈ 0.04 s at quality 0.95 (≈ 0.13 s at 1.0) on an M-series Mac.
- **WebP**: a hand-built lossless (VP8L) still image and a hand-built animated (`VP8X` + `ANIM` + 2 × `ANMF`) image decode through ImageIO; the animated one reports 2 frames and frame 0 is the first frame's color. The recipe is in *Test plan → Test support*.

## User story

As a PaintDotMac user, I can open HEIC, TIFF, BMP, GIF, and WebP images (animated GIF/WebP as their first frame), and save my image as JPEG, HEIC, TIFF, BMP, or GIF as well as PNG and OpenRaster. When I save a JPEG I choose the quality with a slider and see how big the file will be before I confirm. When my image has several layers and I save it to a flat format, PaintDotMac asks "Flatten image?" and writes a flattened copy while my layers stay intact in the open document. ⌘S on an opened JPEG writes the JPEG in place (after the quality dialog) instead of forcing Save As.

## Scope & changes

### Core (pure, unit-tested; imports only Foundation, CoreGraphics, ImageIO, UniformTypeIdentifiers, Accelerate)

1. **`Core/IO/FileFormat.swift`** (extend 0005/0028):
   - Cases, in this declaration order (also the order of the save panel's format popup): `case openRaster, png, jpeg, heic, tiff, bmp, gif, webp`.

     | case | `typeIdentifier` (`utType`) | `preferredFilenameExtension` | other extensions read by `init(fileExtension:)` (case-insensitive) | `displayName` | `canRead` | writable |
     |---|---|---|---|---|---|---|
     | `.heic` | `public.heic` (`.heic`) | `heic` | `heif` | "HEIC" | true | iff the encoder is available |
     | `.tiff` | `public.tiff` (`.tiff`) | `tiff` | `tif` | "TIFF" | true | true |
     | `.bmp` | `com.microsoft.bmp` (`.bmp`) | `bmp` | `dib` | "BMP" | true | true |
     | `.gif` | `com.compuserve.gif` (`.gif`) | `gif` | — | "GIF" | true | true |
     | `.webp` | `org.webmproject.webp` (`.webP`) | `webp` | — | "WebP" | true | **false** (0063) |

     `.jpeg` becomes writable (0005's `canWrite == false` → true). `init?(typeIdentifier:)` additionally maps the alias `"public.heif"` → `.heic` (HEIF files open as HEIC documents and ⌘S writes HEIC into them).
   - **Encoder availability.** Add in the same file:
     ```swift
     struct ImageIOCapabilities: Equatable, Sendable {
         let destinationTypes: Set<String>
         /// CGImageDestinationCopyTypeIdentifiers(), read once (static let).
         static let current: ImageIOCapabilities
         func canEncode(_ format: FileFormat) -> Bool   // format.typeIdentifier ∈ destinationTypes (.openRaster → true: our own ZIP + PNG)
     }
     ```
     `func canWrite(using capabilities: ImageIOCapabilities) -> Bool`: `.webp` false; otherwise `capabilities.canEncode(self)`. 0005's `canWrite` becomes `canWrite(using: .current)`. `static func writableFormats(using: ImageIOCapabilities) -> [FileFormat]` (declaration order); 0005's `writableFormats` = `writableFormats(using: .current)` → `[.openRaster, .png, .jpeg, .heic, .tiff, .bmp, .gif]` on a normal Mac.
   - New properties: `var supportsLayers: Bool` (only `.openRaster`), `var alphaSupport: AlphaSupport` (`enum AlphaSupport { case full, binary, none }`: ORA/PNG/HEIC/TIFF/BMP/WebP `.full`, GIF `.binary`, JPEG `.none`), `var isLossy: Bool` (JPEG, HEIC, and GIF's palette reduction → true; others false).
   - `static func suggestedSaveFormat(for documentFormat: FileFormat?, layerCount: Int, capabilities: ImageIOCapabilities = .current) -> FileFormat` (replaces 0028's one-argument version, which is removed; its only callers, 0028's `saveAction(for:)` and `PaintDocument.prepareSavePanel`, are updated here): `layerCount > 1` → `.openRaster` (the brief's ".ora default for layered images"); else the document's format when `canWrite(using:)`; else `defaultNewDocumentFormat` (`.openRaster`). `saveAction(for:layerCount:capabilities:)` (0005's signature gains the two defaulted parameters) uses it for `suggested`, and offers `writableFormats(using:)`. A writable document format still yields `.writeInPlace` regardless of the layer count (⌘S keeps the document's format, PRD §5.11; the FMT-A confirmation is handled by `SavePlan`).

2. **`Core/IO/ImageCodecError.swift`** (extend):
   - **Remove** 0024's `case layeredImageNeedsFlatten` (its description and recovery suggestion, and 0028's updated suggestion). Multi-layer flat saves now flatten on export.
   - Add `case encoderUnavailable(FileFormat)` → description "This Mac can't save %@ images." (format `displayName`), recovery suggestion "Choose another format with File > Save As…". Used when `ImageIOCapabilities` lacks the format (HEIC on a Mac without the HEVC encoder) or `CGImageDestinationCreateWithData` returns nil for a format we expected to be available.
   - `unsupportedWriteFormat(.webp)` keeps 0005's text ("PaintDotMac can't save images in the WebP format yet.").

3. **`Core/IO/ImageEncoder.swift`** (extend 0005/0028):
   ```swift
   struct ExportOptions: Equatable, Sendable {
       var jpegQuality: Int = AppSettings.defaultJPEGQuality   // 0...100, clamped on use
   }
   enum ImageEncoder {
       static let heicQuality: Double = 0.90                   // see Open questions 5
       static let gifAlphaThreshold: UInt8 = 128               // see Open questions 3
       static func encode(_ surface: TiledSurface, size: PixelSize, dpi: Double, as format: FileFormat,
                          options: ExportOptions = .init(),
                          capabilities: ImageIOCapabilities = .current) throws(ImageCodecError) -> Data
       static func encode(_ image: LayeredImage, as format: FileFormat,
                          options: ExportOptions = .init(),
                          capabilities: ImageIOCapabilities = .current) throws(ImageCodecError) -> Data
       /// FMT-A: the pixels a flat format writes. Exactly one layer that is visible, opacity 255, blend mode .normal →
       /// that layer's surface unchanged (keeps the color under alpha 0, D-33); otherwise CPUCompositor().flattened(image).
       static func exportSurface(of image: LayeredImage) -> TiledSurface
       /// JPEG: straight RGBA → opaque RGB over white. Per channel c' = (c·a + 255·(255 − a) + 127) / 255 (integer division); alpha 255.
       static func compositeOverWhite(_ pixel: ColorRGBA8) -> ColorRGBA8
       /// GIF: a ≥ gifAlphaThreshold → (r,g,b,255); else (0,0,0,0).
       static func binarizeAlpha(_ pixel: ColorRGBA8, threshold: UInt8) -> ColorRGBA8
   }
   ```
   - Layered entry point: `.openRaster` → 0028's `OpenRasterCodec` (unchanged). Every other writable format → `encode(exportSurface(of: image), size: image.size, dpi: image.dpi, as:, options:)` — **no layer-count error any more** (0005 interim rule 5 and 0024's error are gone). Zero layers still throws `.encodingFailed`. The document is never modified by export (FMT-A "flatten on export only").
   - Order of checks in the surface entry point: `.webp` (or any `canRead`-only format) → `.unsupportedWriteFormat(format)`; `!capabilities.canEncode(format)` → `.encoderUnavailable(format)`; then encode. `CGImageDestinationCreateWithData` returning nil → `.encoderUnavailable(format)`; `CGImageDestinationFinalize` returning false → `.encodingFailed`.
   - All formats: one contiguous buffer built from the surface as in 0005 (absent tiles → `(0,0,0,0)`), wrapped in a `CGImage` through a `CGDataProvider` with color space `CGColorSpace(name: CGColorSpace.sRGB)` (embeds the sRGB profile where the format can carry one, FMT-B), properties `kCGImagePropertyDPIWidth/Height = dpi`, no orientation property (files are written upright, orientation 1, FMT-B). Never premultiply. Per format:
     - **JPEG (F-3):** each pixel through `compositeOverWhite` (Paint.NET also writes transparent areas as white; see *Open questions* 2), `CGImage` with `CGImageAlphaInfo.noneSkipLast`; property `kCGImageDestinationLossyCompressionQuality = Double(clamp(options.jpegQuality, 0...100)) / 100`. Chroma subsampling, Huffman tables, and progressive mode are ImageIO's defaults (no extra keys; 4:2:0 below quality 100, 4:4:4 at 100, matching Paint.NET's 4:2:0 default). `kCGImagePropertyJFIFDictionary` carries the DPI too (`kCGImagePropertyJFIFXDensity/YDensity = Int(dpi.rounded())`, `kCGImagePropertyJFIFDensityUnit = 1`) in addition to the generic DPI keys.
     - **HEIC (F-4):** straight `.last` RGBA, `kCGImageDestinationLossyCompressionQuality = heicQuality`. Alpha is kept.
     - **TIFF (F-5):** straight `.last` RGBA, lossless, `kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]` (LZW). Alpha and the color under alpha 0 are kept exactly.
     - **BMP (F-5):** if every pixel has alpha 255 → `.noneSkipLast` (ImageIO writes 24 bpp); otherwise straight `.last` (32 bpp with alpha). BMP can't carry the sRGB profile through ImageIO (see *Open questions* 4); untagged files reopen as sRGB (FMT-B), so pixels round-trip exactly.
     - **GIF (F-5):** each pixel through `binarizeAlpha(_, threshold: gifAlphaThreshold)` so the transparency rule is ours and deterministic (ImageIO's own cut-off is 64), then `.last`; one frame; ImageIO builds the palette (color quantization is ImageIO's). GIF stores no DPI; reopening gives 96 (0002 default).
   - `encode(_:as: .png)` is unchanged from 0005 (byte-exact).

4. **`Core/IO/SavePlan.swift`** (new) — the pure FMT-A/JPEG-dialog decision:
   ```swift
   enum SaveOperationKind: Equatable, Sendable { case save, saveAs, saveTo, autosave }
   struct SaveTarget: Equatable, Sendable { var url: URL; var format: FileFormat }
   struct SavePlan: Equatable, Sendable {
       var format: FileFormat
       var flattens: Bool                    // layerCount > 1 && !format.supportsLayers
       var needsFlattenConfirmation: Bool
       var needsJPEGOptions: Bool
       static func make(format: FileFormat, layerCount: Int, operation: SaveOperationKind, target: SaveTarget,
                        confirmedFlattenTarget: SaveTarget?,
                        capabilities: ImageIOCapabilities = .current) throws(ImageCodecError) -> SavePlan
   }
   ```
   Rules (checked in this order):
   - A read-only format (`.webp`) → throw `.unsupportedWriteFormat(format)`; a format whose encoder is missing (`!format.canWrite(using: capabilities)`, e.g. HEIC) → throw `.encoderUnavailable(format)`.
   - `flattens = layerCount > 1 && !format.supportsLayers`.
   - `.autosave` → no confirmation and no dialog (0047 writes `.ora`; an autosave never prompts).
   - `needsFlattenConfirmation = flattens && !(operation == .save && confirmedFlattenTarget == target)`. I.e. the confirmation is asked **once per document session per target**: after the user confirms "Flatten" for a file/format, later ⌘S to that same file in that format doesn't ask again until the document is closed; Save As and Save To always ask (see *Open questions* 1).
   - `needsJPEGOptions = format == .jpeg && operation != .autosave` — the JPEG dialog appears on every JPEG save, including ⌘S (see *Open questions* 6).
   - The mapping from `NSDocument.SaveOperationType` to `SaveOperationKind` lives in the document glue (below), never in Core (no AppKit in Core).

5. **`Core/IO/JPEGSizeEstimator.swift`** (new) — F-3 live estimate, off the main actor, debounced, cancellable, latest-request-wins:
   ```swift
   actor JPEGSizeEstimator {
       typealias Encode = @Sendable (_ surface: TiledSurface, _ size: PixelSize, _ dpi: Double, _ quality: Int) throws -> Int
       init(image: LayeredImage, debounce: Duration = .milliseconds(150),
            encode: @escaping Encode = { try ImageEncoder.encode($0, size: $1, dpi: $2, as: .jpeg,
                                                                 options: ExportOptions(jpegQuality: $3)).count })
       /// nil when superseded by a newer call or cancelled; .failure on an encoder error.
       func estimate(quality: Int) async -> Result<Int, ImageCodecError>?
       static func formatted(byteCount: Int, locale: Locale = .current) -> String
   }
   ```
   - Each call increments a generation counter and records it; then `try await Task.sleep(for: debounce)` (cancellation → return nil); if a newer call arrived meanwhile → nil (it never encodes). The flattened source (`ImageEncoder.exportSurface(of: image)`) is computed **once**, lazily, inside the actor and cached. Check `Task.isCancelled` and the generation again before and after encoding; a stale result is dropped (nil). The estimate uses exactly the save path (`ImageEncoder.encode(…, as: .jpeg, …)` with the document's DPI), so the estimate **equals** the saved file's byte count (ImageIO JPEG output is deterministic, see Context).
   - `formatted(byteCount:locale:)`: `n < 1000` → "`n` bytes"; else `kb = (Double(n) / 1000).rounded()`, if `kb < 1000` → "`kb` KB" (integer, grouping separator per locale); else "`x.y` MB" with exactly one fraction digit of `Double(n) / 1_000_000` (rounded half-even by `NumberFormatter`, decimal separator per locale). Decimal (Finder) units. en_US examples: 512 → "512 bytes", 999 → "999 bytes", 1_000 → "1 KB", 123_456 → "123 KB", 999_499 → "999 KB", 999_500 → "1.0 MB", 3_181_950 → "3.2 MB", 18_287_139 → "18.3 MB". de_DE: 3_181_950 → "3,2 MB".

6. **`Core/Settings/AppSettings.swift`** (extend 0004): `static let defaultJPEGQuality = 95` (Paint.NET's default, API docs above); `Key.jpegQuality = "settings.jpegQuality"`; `var jpegQuality: Int { get nonmutating set }` — missing or non-integer → 95; stored values are clamped to 0…100 on read; the setter clamps, writes, and posts `.appSettingsDidChange` with `userInfo["key"] = Key.jpegQuality`. This is the **default** for the JPEG dialog; 0046's Settings window edits it. The dialog doesn't write it (see platform glue).

### Platform glue (UI tests + hosted tests)

7. **`PaintDotMac/UI/JPEGOptionsDialog.swift`** (new): SwiftUI view + a small `@MainActor @Observable final class JPEGOptionsModel` (in the same file; holds `quality: Int`, `sizeText: String`, owns the `JPEGSizeEstimator`, and on every quality change cancels the previous estimate `Task` and starts a new one; it applies a result only if it is non-nil). Presented as a **sheet** on the document window (`windowForSheet`), app-modal if there is no window. Contents, top to bottom:
   - Window/sheet title "JPEG Options" (Paint.NET calls its dialog "Save Configuration"; see *Open questions* 7).
   - "Quality:" `Slider(0...100, step 1)` + an integer text field (0–100; out-of-range or non-numeric input reverts to the last valid value on commit) — both bound to `quality`.
   - "File size:" label showing `JPEGSizeEstimator.formatted(byteCount:)`, "Calculating…" while an estimate is pending, "Unavailable" after a failure.
   - Buttons "Cancel" (Esc, `.cancelAction`) and "OK" (Return, `.defaultAction`). OK is enabled while an estimate is pending.
   - Initial quality: the quality last used for **this document in this session** if any, else `AppSettings().jpegQuality` (95 by default). OK stores the chosen quality in the document (`lastJPEGQuality`, not persisted) and does not change `settings.jpegQuality`.
   - Accessibility identifiers: `jpegOptionsDialog` (sheet), `jpegOptions.quality` (slider), `jpegOptions.qualityField`, `jpegOptions.fileSize` (the value text, e.g. "123 KB"), `jpegOptions.ok`, `jpegOptions.cancel`.
   - VoiceOver: slider label "Quality", value "`n`"; file-size label "Estimated file size".

8. **`PaintDotMac/Document/PaintDocument.swift`** (extend 0005/0008/0028):
   - `readableTypes` stays 0028's derived list, now `["org.openraster.ora", "public.png", "public.jpeg", "public.heic", "public.tiff", "com.microsoft.bmp", "com.compuserve.gif", "org.webmproject.webp"]` plus `"public.heif"` appended (alias).
   - `writableTypes(for:)` → `FileFormat.writableFormats(using: capabilities).map(\.typeIdentifier)` for every operation (`capabilities` is an internal `var capabilities: ImageIOCapabilities = .current` so hosted tests can inject a Mac without HEIC).
   - `fileNameExtension(forType:saveOperation:)`: `FileFormat(typeIdentifier:)?.preferredFilenameExtension` (now covers the new formats).
   - `saveDocument(_:)`: `FileFormat.saveAction(for: FileFormat(typeIdentifier: fileType ?? ""), layerCount: image.layers.count, capabilities: capabilities)` — JPEG, HEIC (if available), TIFF, BMP, GIF write in place; WebP (and HEIC without an encoder) go through Save As.
   - **Save panel format popup (decision).** 0028 relies on `NSDocument`'s built-in accessory, which preselects the document's current `fileType`; that can't express "layered → `.ora`". Replace it with our own accessory (the only visible difference is that item titles are our `displayName`s): `override var shouldRunSavePanelWithAccessoryView: Bool { false }`; `prepareSavePanel(_:)` adds an accessory view with "Format:" and an `NSPopUpButton` (accessibility identifier `savePanel.format`) whose items are `writableFormats(using:)` by `displayName`, preselecting `FileFormat.suggestedSaveFormat(for: currentFormat, layerCount:, capabilities:)`; it sets `savePanel.allowedContentTypes = [selected.utType]`, `allowsOtherFileTypes = false`, and `nameFieldStringValue = FileFormat.suggestedFilename(original: fileURL?.lastPathComponent, untitledName: displayName, format: selected)`; `directoryURL` as before. Changing the popup updates `allowedContentTypes` and replaces the name field's extension (`suggestedFilename(original: <current name field>, …)`). `override var fileTypeFromLastRunSavePanel: String?` returns the popup's selected `typeIdentifier`. Results: an untitled or layered document suggests `<name>.ora` with "OpenRaster" selected; a single-layer opened JPEG suggests `photo.jpg` with "JPEG" selected; a single-layer WebP suggests `<name>.ora` (WebP isn't writable; `defaultNewDocumentFormat`).
   - **FMT-A + JPEG options in the save funnel.** Extend 0008's `save(to:ofType:for:completionHandler:)` override. After `prepareForNavigation`:
     1. Map the operation: `.saveOperation` → `.save`, `.saveAsOperation` → `.saveAs`, `.saveToOperation` → `.saveTo`, `.autosaveInPlaceOperation`/`.autosaveElsewhereOperation`/`.autosaveAsOperation` → `.autosave`.
     2. `SavePlan.make(format: FileFormat(typeIdentifier: typeName), layerCount: image.layers.count, operation:, target: SaveTarget(url: url, format:), confirmedFlattenTarget: confirmedFlattenTarget)`. A thrown `ImageCodecError` → `completionHandler(error)` (NSDocument's standard error alert; document stays open and edited).
     3. If `needsFlattenConfirmation`: an `NSAlert` sheet — messageText **"Flatten image?"**, informativeText **"The <displayName> format doesn't support layers. The saved file will contain a flattened copy of the image. The layers in this document are kept."**, buttons **"Flatten"** (first, default, Return) and **"Cancel"** (Esc). Cancel → `completionHandler(CocoaError(.userCancelled))` (NSDocument shows nothing; a close or quit in progress is aborted; nothing is written).
     4. If `needsJPEGOptions`: present `JPEGOptionsDialog`; Cancel → `completionHandler(CocoaError(.userCancelled))`; OK → `pendingExportOptions = ExportOptions(jpegQuality: quality)`.
     5. Call `super.save(to:ofType:for:)`; in its completion, clear `pendingExportOptions`; on success with `plan.flattens`, set `confirmedFlattenTarget = target` (only for `.save`/`.saveAs`); pass the error through.
     - `data(ofType:)` encodes with `ImageEncoder.encode(image, as: format, options: pendingExportOptions ?? ExportOptions(jpegQuality: AppSettings().jpegQuality), capabilities: capabilities)`.
     - `confirmedFlattenTarget: SaveTarget?` and `lastJPEGQuality: Int?` are plain stored properties: they live for the document's session, are never persisted, and are not affected by undo.
     - The document's layers and history are untouched by a flattened export. After a successful `.save`/`.saveAs`, 0008 marks the saved step, so the document is clean and its `fileType` is the flat format (a later ⌘S writes that format again, without the flatten prompt for the same target).
   - Encoding stays synchronous in `data(ofType:)` on the main actor (as 0005); JPEG encode of a 24 MP image is ≈ 0.05 s plus the CPU flatten. 0048 revisits async writing.

9. **`project.yml`** — Info.plist `CFBundleDocumentTypes`, after 0028's ORA, PNG, JPEG entries, append (all `NSDocumentClass: $(PRODUCT_MODULE_NAME).PaintDocument`, `LSHandlerRank: Alternate` like 0001's):
   - `"HEIC image"`, `LSItemContentTypes: [public.heic, public.heif]`, `Editor`;
   - `"TIFF image"`, `[public.tiff]`, `Editor`;
   - `"BMP image"`, `[com.microsoft.bmp]`, `Editor`;
   - `"GIF image"`, `[com.compuserve.gif]`, `Editor`;
   - `"WebP image"`, `[org.webmproject.webp]`, **`Viewer`**.
   All are system UTIs: no new `UTImportedTypeDeclarations`. The JPEG entry stays `Editor`. Add the new files and run `xcodegen generate`.

10. **Tests and helpers to update** (because behavior intentionally changes):
    - 0005 (as already updated by 0028): `FileFormatTests.capabilities`, `.saveActionForJPEGIsSaveAs` → `saveActionForJPEGWritesInPlace` (`.writeInPlace(.jpeg)`), `ImageEncoderTests.unsupportedWriteFormat` → uses `.webp`; `PaintDocumentSavingTests.writableTypesAreAllWritableFormats` (0028's name; no rename) → expects the seven writable identifiers, `.dataOfTypeJPEGThrows` → `dataOfTypeWebPThrows`, `.jpegDocumentSaveActionIsSaveAs` → removed (covered below); `SaveUITests.jpegSaveGoesThroughSaveAsPNG` (as modified by 0028) → replaced by `ExportFormatsUITests.testJPEGSaveInPlaceShowsOptions`.
    - 0024: `ImageEncoderTests.multiLayerNeedsFlatten` → removed (replaced by `layeredExportFlattens`); `LayersMenuUITests.testMultiLayerSaveShowsFlattenHint` → rewritten to expect the "Flatten image?" sheet, click Cancel, window still open and edited.
    - 0028: `FileFormatTests.capabilities`/`saveAction*` expectations for the new case list; `FileFormatTests.suggestedSaveFormat` → replaced by `suggestedSaveFormatRules`; `ImageCodecErrorTests.archiveMessages` drops its `.layeredImageNeedsFlatten` assertion; `PaintDocumentOpenRasterTests.pngSaveOfLayeredImageSuggestsOra` → `pngSaveOfLayeredImageFlattens` (data is the composite); `PaintDocumentOpenRasterTests.readableAndWritableTypes` and `SmokeTests.documentTypes` (eight entries, in the order above); `OpenRasterUITests.testNewImageSavesAsOpenRasterAndReopens` reads the selected title of `savePanel.format` ("OpenRaster") instead of the built-in popup's "OpenRaster image"; `OpenRasterUITests.testSaveAsOffersOpenRasterAndPNG` checks `savePanel.format` for "OpenRaster" and "PNG" and selects "OpenRaster".
    - `PaintDotMacUITests/Support/UITestApp.swift`: add `decodeImage(at:) -> (width, height, rgba: [UInt8], dpi: Double, profileName: String?, typeIdentifier: String, frameCount: Int)` (ImageIO in the runner; straight RGBA via a `.last` sRGB vImage/`CGContext`-free conversion like 0005's `decodePNG`, which now forwards to it); `selectSaveFormat(_ displayName: String)` (clicks `savePanel.format` and the item). Change 0028's existing `saveThroughPanel(directory:name:format:)` (no new overload) to select through `selectSaveFormat`, and update the callers 0028 made pass `"PNG image"` (0008's `SaveUITests.saveAsNewImageWritesWhitePNG`, 0021's `ClipboardUITests.testPasteIntoNewImageWithoutDocument`) to pass `"PNG"`.
    - `PaintDotMacTests/Support/TestImages.swift`: add `webPLossless(width:height:color:) -> Data` and `animatedWebP(frames: [ColorRGBA8]) -> Data` (recipe below).
    - `PaintDotMac/Core/IO/FileFormat.swift`'s doc comments: drop the "0029 adds …" notes.

11. **PRD:** not edited by this spec (batch rule). The decisions listed under *Open questions* need recording in PRD §5.11/§12 once confirmed.

## Acceptance criteria

- [ ] HEIC, HEIF, TIFF, BMP, GIF, and WebP files open from File > Open, the Dock, and `-UITestOpen`; animated GIF and WebP open as their first frame without a warning (FMT-D). → `FileFormatTests.newFormatsMapping`, `ImageDecoderFormatTests.*`, `PaintDocumentFormatTests.readsEveryFormat`, `ExportFormatsUITests.testOpensEveryReadableFormat`
- [ ] Save As offers OpenRaster, PNG, JPEG, HEIC (when the Mac can encode it), TIFF, BMP, and GIF, and never WebP. → `FileFormatTests.writableFormatsDependOnCapabilities`, `PaintDocumentFormatTests.writableTypes`, `ExportFormatsUITests.testSaveAsFormatPopup`
- [ ] Save As preselects OpenRaster for a layered image and the document's own writable format for a single-layer image, with the matching extension in the name field. → `FileFormatTests.suggestedSaveFormatRules`, `ExportFormatsUITests.testSaveAsFormatPopup`, `.testLayeredSaveAsDefaultsToOpenRaster`
- [ ] Saving to JPEG shows the JPEG Options dialog with Quality 0–100, default 95 (Paint.NET), and a live "File size:" estimate that updates as the slider moves; the estimate equals the saved file size; Cancel writes nothing. → `JPEGSizeEstimatorTests.*`, `AppSettingsTests.jpegQuality*`, `ExportFormatsUITests.testSaveAsJPEGWithQuality`, `.testJPEGOptionsCancelWritesNothing`
- [ ] JPEG output: transparent areas become white (`compositeOverWhite`), sRGB profile and DPI embedded, orientation 1, quality maps to ImageIO `q/100`, decoded pixels within the PSNR bounds. → `ImageEncoderFormatTests.jpeg*`
- [ ] ⌘S on an opened JPEG shows the JPEG Options dialog and rewrites the JPEG in place (no Save panel); the dialog starts at the quality last used for the document in this session. → `FileFormatTests.saveActionForJPEGWritesInPlace`, `ExportFormatsUITests.testJPEGSaveInPlaceShowsOptions`
- [ ] TIFF and BMP (32-bit when any alpha < 255, 24-bit when opaque) round-trip byte-exact including alpha and the color under alpha 0; GIF keeps exact colors for small palettes and binarizes alpha at 128; HEIC keeps alpha and stays within its PSNR bound; DPI round-trips for JPEG/HEIC/TIFF/BMP; sRGB profile embedded for JPEG/HEIC/TIFF/GIF. → `ImageEncoderFormatTests.*`, `ImageEncoderFormatPropertyTests.*`
- [ ] FMT-A: saving a multi-layer image to any flat format asks "Flatten image?" (Flatten / Cancel); Flatten writes `CPUCompositor().flattened(image)` (JPEG: over white) and leaves the document's layers and history unchanged; Cancel writes nothing and keeps the document edited; ⌘S to the same file later doesn't ask again in this session, Save As does. → `SavePlanTests.*`, `ImageEncoderTests.layeredExportFlattens`, `PaintDocumentFormatTests.flattenOnExport*`, `ExportFormatsUITests.testFlattenPromptOnSave`
- [ ] Saving `.ora` never asks to flatten; autosave never prompts. → `SavePlanTests.openRasterNeverFlattens`, `.autosaveNeverPrompts`
- [ ] Encoder failures (WebP write, HEIC unavailable, finalize failure, unwritable folder) show an alert, leave the document open and edited, and leave no partial file. → `ImageEncoderFormatTests.failurePaths`, `SavePlanTests.unwritableFormatsThrow`, `PaintDocumentFormatTests.heicUnavailableFallsBackToSaveAs`, `.writeFailureKeepsDocumentEdited`
- [ ] `.layeredImageNeedsFlatten` no longer exists, and 0024/0028 tests that relied on it are updated as listed in Scope 10. → build + `ImageCodecErrorTests.messages`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality-gate launch smoke).

## Edge cases

- **Alpha in JPEG:** `(255,0,0,128)` → `(255,127,127)`; `(x,y,z,0)` → `(255,255,255)`; `(10,20,30,255)` unchanged before compression. Sparse tiles (all `(0,0,0,0)`) → white.
- **Quality extremes:** 0 → ImageIO quality 0.0 (valid, tiny file); 100 → 1.0 (4:4:4, largest). Field input "-1", "101", "abc", "" → reverts to the last valid value. Stored `settings.jpegQuality` of 150 or "x" → read as 100 / 95.
- **Estimate races:** dragging the slider fires many changes; only the last one encodes after the 150 ms debounce; closing the dialog (OK or Cancel) cancels the running task; an estimate that finishes after the dialog closed is ignored (no crash, no UI update). A huge image (65,535 × 1, or 24 MP) shows "Calculating…" until the background encode finishes; the dialog stays responsive (encode is off the main actor).
- **Estimate failure** (encoder throws) → "Unavailable"; OK still saves (and then reports the save error through NSDocument if it fails again).
- **Single layer that is hidden or has opacity < 255 or a non-Normal blend mode** → exported through `CPUCompositor` (hidden → fully transparent / white for JPEG). A single visible opaque Normal layer keeps alpha-0 colors exactly (PNG/TIFF/BMP).
- **All layers hidden** → exported fully transparent (white JPEG); still asks to flatten when there are > 1 layers.
- **GIF:** alpha 127 → transparent, 128 → opaque; semi-transparent colors lose their alpha; > 200 distinct colors are quantized by ImageIO (not exact; bounded in tests). GIF reopens at 96 DPI.
- **BMP:** no ICC profile; image reopens as sRGB (untagged), pixels exact; DPI within 0.01.
- **HEIC unavailable** (capabilities lack `public.heic`): HEIC isn't offered in Save As; ⌘S on an opened HEIC goes to Save As with `.ora` suggested; a direct `data(ofType: "public.heic")` throws `.encoderUnavailable(.heic)` ("This Mac can't save HEIC images.").
- **WebP-backed document:** ⌘S → Save As (WebP not writable); `data(ofType: "org.webmproject.webp")` throws `.unsupportedWriteFormat(.webp)`.
- **HEIF file** (`public.heif`) opens; ⌘S writes HEIC data to the same `.heif` URL.
- **Save As then cancel in the flatten or JPEG dialog:** nothing is written; the document keeps its old URL, type, and edited state; a close/quit that triggered the save is aborted.
- **Close prompt "Save…" on a layered JPEG document:** the flatten prompt appears (unless already confirmed for that file this session), then the JPEG dialog; Cancel in either aborts the close.
- **Confirmed target and later Save As to a different file/format:** asks again; ⌘S afterwards to the new file doesn't (target updated after the successful Save As).
- **Layer count drops to 1 (Flatten/Merge) after confirming:** no prompt (nothing to flatten); grows again: no prompt for the confirmed target.
- **Very large export** (APP-10 sizes): buffer sizes computed in `Int` after `ImageLimits` accepted the size; ImageIO failure → `.encodingFailed` alert, no crash.
- **Unwritable folder / disk full:** NSDocument's standard alert; safe-save leaves no truncated file.
- **EXIF-rotated JPEG** reopened and re-saved: written upright with orientation 1 (0002 applied the rotation on open).

## Test plan

Expected values come from hand calculation, the formulas above, the format specs, or byte-level inspection of the written file — never from running the code under test and pasting its output. Seeded tests use `SeededRandom` and print the seed on failure.

**Test support.**
- `TestImages.webPLossless(width:height:color:)` builds a RIFF/WEBP file with one `VP8L` chunk whose bitstream is (bits written LSB-first): `0x2f` (8 bits), `width − 1` (14), `height − 1` (14), `alpha_is_used = 1` (1), `version = 0` (3), `transform present = 0` (1), `color cache = 0` (1), `meta prefix codes = 0` (1), then five prefix codes in the order green, red, blue, alpha, distance, each a *simple code* with one 8-bit symbol: bits `1` (simple), `0` (one symbol), `1` (first symbol is 8 bits), then the symbol (8 bits) — the symbols are `g, r, b, a, 0`. Single-symbol codes take zero bits per pixel, so no pixel data follows; pad to a byte. Chunk = `"VP8L"` + LE32 length + data (+ pad byte if odd); file = `"RIFF"` + LE32(4 + body length) + `"WEBP"` + body. (Verified: 1×1 `(255,0,0,255)` → `UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEChA/wvQ/wIAAA==` decodes through ImageIO to `(255,0,0,255)`.)
- `TestImages.animatedWebP(frames:)`: body = `VP8X` chunk (10 bytes: flags `0x12` = animation + alpha, 3 reserved bytes, canvas width − 1 and height − 1 as LE24) + `ANIM` chunk (LE32 background color 0, LE16 loop count 0) + one `ANMF` chunk per frame (LE24 x/2 = 0, LE24 y/2 = 0, LE24 width − 1, LE24 height − 1, LE24 duration = 100, 1 flags byte = 0, then a `VP8L` chunk as above). (Verified: frames red, blue → ImageIO reports 2 frames, frame 0 red, frame 1 blue.)
- Test-side `PSNR(a:b:)` over RGB of opaque pixels: `10·log10(255² / MSE)`.
- Test-side `JPEGMarkers` walker (SOI, then segments with big-endian lengths until SOS) to read the SOF0/SOF2 sampling factors and the APP0 JFIF density.

**Unit tests**
- `PaintDotMacTests/IO/FileFormatTests.swift` (update 0005/0028):
  - `newFormatsMapping`: the table in Scope 1 exactly (identifiers, extensions incl. "HEIF", "TIF", "DIB" → case; "public.heif" → `.heic`; `displayName`s); `allCases == [.openRaster, .png, .jpeg, .heic, .tiff, .bmp, .gif, .webp]`.
  - `capabilities`: every case `canRead`; `.webp.canWrite(using: all) == false`; `.jpeg` writable; `supportsLayers` only `.openRaster`; `alphaSupport` per the table; `isLossy` JPEG/HEIC/GIF.
  - `writableFormatsDependOnCapabilities`: with all six ImageIO types → `[.openRaster, .png, .jpeg, .heic, .tiff, .bmp, .gif]`; without `public.heic` → same minus `.heic`; with an empty set → `[.openRaster]`. `ImageIOCapabilities.current.canEncode(.png) == true` (real system).
  - `suggestedSaveFormatRules`: (nil, 1) → `.openRaster`; (.png, 1) → `.png`; (.jpeg, 1) → `.jpeg`; (.jpeg, 2) → `.openRaster`; (.webp, 1) → `.openRaster`; (.heic, 1, no HEIC) → `.openRaster`; (.gif, 3) → `.openRaster`.
  - `saveActionForJPEGWritesInPlace`: `saveAction(for: .jpeg, layerCount: 1)` and `(… layerCount: 3)` → `.writeInPlace(.jpeg)`; `.webp` → `.saveAs(offering: all seven, suggested: .openRaster)`; `.heic` without HEIC → `.saveAs(offering: without heic, suggested: .openRaster)`.
- `PaintDotMacTests/IO/SavePlanTests.swift`:
  - `singleLayerNoPrompt`: PNG, 1 layer, `.save` → `flattens false`, no confirmation, no JPEG dialog.
  - `multiLayerFlatNeedsConfirmation`: each of PNG/JPEG/HEIC/TIFF/BMP/GIF with 2 layers and `.save`/`.saveAs`/`.saveTo` → `flattens`, `needsFlattenConfirmation`.
  - `confirmedTargetSkipsOnSave`: confirmed = target → `.save` no confirmation; `.saveAs` and `.saveTo` still confirm; a different URL or format → confirms.
  - `openRasterNeverFlattens`: `.openRaster`, 5 layers → `flattens false`, no confirmation.
  - `autosaveNeverPrompts`: JPEG, 3 layers, `.autosave` → no confirmation, no JPEG dialog (`flattens` true).
  - `jpegAlwaysNeedsOptions`: JPEG 1 layer `.save`, `.saveAs`, `.saveTo` → `needsJPEGOptions`; other formats never.
  - `unwritableFormatsThrow`: `.webp` → `.unsupportedWriteFormat(.webp)`; `.heic` with capabilities lacking HEIC → `.encoderUnavailable(.heic)`.
- `PaintDotMacTests/IO/ImageEncoderTests.swift` (extend):
  - `compositeOverWhiteValues`: `(255,0,0,128)` → `(255,127,127,255)`; `(0,0,0,0)` and `(10,20,30,0)` → `(255,255,255,255)`; `(10,20,30,255)` → unchanged; `(0,0,0,1)` → `(254,254,254,255)` (hand: (0 + 255·254 + 127)/255 = 254); exhaustive check over all `c, a` in 0…255 against the formula written independently in the test with `Double` rounding `(c·a + 255·(255−a))/255` rounded half-up (equal for every pair).
  - `binarizeAlphaValues`: alpha 127 → `(0,0,0,0)`; 128 → `(r,g,b,255)`; 0 with color → `(0,0,0,0)`; 255 unchanged.
  - `exportSurfaceSingleOpaqueLayerIsIdentity`: one visible 255 Normal layer with `(10,20,30,0)` pixels → returned surface equals the layer's (same tile storage, `sharesStorage`).
  - `exportSurfaceUsesCompositor`: one hidden layer → 0 allocated tiles; one layer opacity 128 → equals `CPUCompositor().flattened`.
  - `layeredExportFlattens`: 0024's three-layer fixture (white Background; red opacity 128; blue hidden) → `encode(image, as: .png)` decodes to `(255,127,127,255)` everywhere; `as: .tiff` same; `as: .jpeg` decodes within ±3 per channel of `(255,127,127)`; the `LayeredImage` value passed in is unchanged (3 layers, identical tiles).
  - `zeroLayersFails`: `.encodingFailed`.
- `PaintDotMacTests/IO/ImageEncoderFormatTests.swift` (new):
  - `tiffRoundTripIsByteExact`: 0005's 300×200 pattern with every alpha value (including alpha 0 with color) → TIFF → `ImageDecoder.decode` → identical bytes; the file's TIFF dictionary has compression 5; DPI 300 → 300 ±0.01; profile name contains "sRGB".
  - `bmp32RoundTripIsByteExact`: same pattern → BMP: byte 28–29 of the file (`biBitCount`) == 32; decoded bytes identical; DPI 300 within 0.01.
  - `bmpOpaqueIs24Bit`: an opaque 257×3 image → `biBitCount == 24`; decoded identical (alpha 255).
  - `gifSmallPaletteExact`: 300×20 image with 16 distinct opaque colors plus transparent `(0,0,0,0)` pixels → GIF → decoded identical; `CGImageSourceGetCount == 1`; decoded DPI 96.
  - `gifAlphaThreshold`: a 256×1 row with color `(255,0,0)` and alpha = x → decoded alpha is 0 for x < 128 and 255 for x ≥ 128, color `(255,0,0)` where opaque.
  - `gifLargePaletteBounded`: 64×64 smooth gradient (4096 colors) → GIF → decodes at the same size, all alpha 255, PSNR ≥ 25 dB.
  - `jpegProperties`: 640×480 smooth gradient at dpi 300, quality 95 → `JPEGMarkers` finds SOI, APP0 JFIF with density unit 1 and 300×300, an ICC profile (decoded profile name contains "sRGB"), Y sampling `0x22`; quality 100 → `0x11`; no orientation property or orientation 1; `CGImageSourceGetType == public.jpeg`.
  - `jpegQualityOrdering`: same image at 10, 50, 95, 100 → sizes strictly increasing; PSNR at 95 ≥ 38 dB, at 50 ≥ 30 dB, at 100 ≥ 45 dB (smooth gradient fixture: R = x mod 256, G = y mod 256, B = 128).
  - `jpegQualityClamped`: quality −5 encodes identically to 0, 150 identically to 100 (byte equal).
  - `jpegIsDeterministic`: two encodes of the same input → equal `Data`.
  - `jpegTransparentBecomesWhite`: 64×64 all `(0,0,0,0)` → every decoded pixel ≥ 250 per channel.
  - `heicRoundTrip`: 512×512 smooth gradient with a left half at alpha 255 and right half at alpha 128 → HEIC → decodes at 512×512; PSNR (RGB, opaque half) ≥ 35 dB; alpha within ±8 of 255 / 128 in the interior (≥ 8 px from the edge); DPI 300 ±0.01; profile contains "sRGB". Skipped? **No** — if `ImageIOCapabilities.current` lacks HEIC the test asserts `.encoderUnavailable(.heic)` instead, so it never skips.
  - `orientationNotWritten`: a JPEG fixture with EXIF orientation 6 opened with `ImageDecoder` then encoded as JPEG/TIFF → re-decoded properties have no orientation or 1, and the size is the rotated size.
  - `failurePaths`: `.webp` → `.unsupportedWriteFormat(.webp)`; capabilities without `com.microsoft.bmp` → `.encoderUnavailable(.bmp)`; an internal `finalize:` seam (`(CGImageDestination) -> Bool`, default `CGImageDestinationFinalize`) returning false → `.encodingFailed`.
  - `messages`: `ImageCodecError.encoderUnavailable(.heic).errorDescription == "This Mac can't save HEIC images."`, recovery suggestion "Choose another format with File > Save As…".
- `PaintDotMacTests/IO/ImageDecoderFormatTests.swift` (new; reads through 0002's decoder):
  - `decodesWebPLossless`: `webPLossless(300, 200, (12,34,56,200))` → 300×200, every pixel `(12,34,56,200)`.
  - `animatedWebPFirstFrame`: frames red, blue → `(255,0,0,255)`.
  - `animatedGIFFirstFrame` (0002 already covers; re-asserted at 300×300 via ImageIO-built 2-frame GIF).
  - `heifAliasOpens`: HEIC data decodes; `FileFormat(typeIdentifier: "public.heif") == .heic`.
- `PaintDotMacTests/IO/JPEGSizeEstimatorTests.swift`:
  - `estimateEqualsSavedSize`: 640×480 gradient, dpi 300; `estimate(quality: 80)` (debounce `.zero`) == `ImageEncoder.encode(image, as: .jpeg, options: .init(jpegQuality: 80)).count`.
  - `estimateUsesFlattenedComposite`: 2-layer image → equals encoding `exportSurface(of:)`.
  - `newerRequestSupersedes`: debounce 200 ms, counting encoder; call q=10 and q=90 concurrently (`async let`) → the q=10 call returns nil, q=90 returns `.success`, the encoder ran exactly once with quality 90.
  - `cancellationReturnsNil`: start a call in a `Task`, cancel it during the debounce → nil and the encoder never ran.
  - `staleResultDropped`: encoder gated by a continuation; start q=10 (debounce `.zero`), wait until encoding started, start q=20, release the gate → q=10 returns nil, q=20 returns success.
  - `flattenComputedOnce`: three sequential estimates → the injected flatten counter (internal seam) is 1.
  - `encoderErrorReported`: encoder throws `.encodingFailed` → `.failure(.encodingFailed)`.
  - `formattedValues`: every example listed in Scope 5 for en_US and the de_DE example.
- `PaintDotMacTests/Settings/AppSettingsTests.swift` (extend): `jpegQualityDefault` (95), `jpegQualityRoundTrip` (set 40 → new instance reads 40; stored integer 40), `jpegQualityClamped` (set 150 → 100; stored "x" → 95; stored −3 → 0), `jpegQualitySetterPostsNotification` (`userInfo["key"] == "settings.jpegQuality"` once).

**Round-trip and property tests** (`PaintDotMacTests/IO/ImageEncoderFormatPropertyTests.swift`, 20 seeds each, size 1…400 per side, dpi 1…1000):
- `losslessFormatsRoundTrip`: random straight RGBA (20% alpha 0 with random color, 20% alpha 255) → TIFF and BMP → decode → identical pixels and size, DPI within 0.05 (BMP 0.05).
- `gifRoundTripRule`: random images using a random palette of ≤ 16 colors and random alpha → GIF → decode equals `binarizeAlpha` of the input (transparent pixels compare as `(0,0,0,0)`).
- `jpegRoundTripBound`: random smooth images (bilinear interpolation of a random 4×4 color grid) at quality 95 → PSNR ≥ 35 dB vs `compositeOverWhite` of the input.

**Golden-image tests:** none (no new blending; export composites through 0012/0024's tested `CPUCompositor`; JPEG/HEIC are checked by PSNR, lossless formats byte-exact).

**Integration tests**
- `PaintDotMacTests/Document/PaintDocumentFormatTests.swift` (`@MainActor`, app-hosted; documents built in code, never shown):
  - `readsEveryFormat`: for each of HEIC, TIFF, BMP, GIF, WebP (generated in the test) → `read(from:ofType:)` with its identifier → one "Background" layer, the expected size, and the expected pixel at (0,0) (exact for TIFF/BMP/GIF/WebP; ±8 for HEIC).
  - `readableTypes`: the list in Scope 8 exactly.
  - `writableTypes`: with real capabilities → the seven identifiers in order; with an injected no-HEIC capabilities → six.
  - `fileNameExtensions`: each writable identifier → its preferred extension.
  - `dataOfTypeWebPThrows`: `.unsupportedWriteFormat(.webp)`.
  - `heicUnavailableFallsBackToSaveAs`: document read from HEIC with injected no-HEIC capabilities → `saveAction` is `.saveAs` suggesting `.openRaster`; `data(ofType: "public.heic")` throws `.encoderUnavailable(.heic)`.
  - `flattenOnExportLeavesDocumentIntact`: 3-layer document (via 0024's operations), `data(ofType: "public.png")` → decodes to the composite; afterwards `image.layers.count == 3`, history step count and names unchanged, `isDocumentEdited` unchanged.
  - `flattenOnExportSaveMarksClean`: a 2-layer edited document, `save(to: tmp.png, ofType: "public.png", for: .saveAsOperation)` with the flatten prompt bypassed through an internal test seam (`saveConfirmationPresenter` returning `.proceed`) → no error, clean, `fileType == "public.png"`, `confirmedFlattenTarget == SaveTarget(url: tmp.png, format: .png)`, layers still 2.
  - `cancelledConfirmationWritesNothing`: presenter returns `.cancel` → completion error is `CocoaError(.userCancelled)`, no file at the URL, document still edited with its old `fileURL`/`fileType`.
  - `jpegSaveUsesChosenQuality`: presenter returns quality 30 → saved file equals `ImageEncoder.encode(image, as: .jpeg, options: .init(jpegQuality: 30))` byte for byte; `lastJPEGQuality == 30`; `settings.jpegQuality` (private suite) unchanged.
  - `autosaveDoesNotPrompt`: `.autosaveElsewhereOperation` → the presenter is never called.
  - `writeFailureKeepsDocumentEdited`: save as TIFF into a 0o555 temp directory → error, no file, still edited.
- `PaintDotMacTests/Integration/ExportSessionIntegrationTests.swift` (headless Core): New Image 600×400 white → Add New Layer → paint a red rectangle on it via 0009's `BrushStroke`/`TileDiffHistoryItem` → `SavePlan` for `.jpeg` says flatten + options → `ImageEncoder.encode(as: .jpeg, quality 95)` → decode: rectangle interior red ±6, background white ±3; same for `.gif` (exact: two colors), `.tiff` (exact), `.bmp` (exact, 24-bit because opaque); document still 2 layers; undo the stroke → TIFF export is all white.

**UI tests** (`PaintDotMacUITests/ExportFormatsUITests.swift`; `UITestApp`, `-UITestResetDefaults YES`, fixtures generated at test time in a per-test temp dir; files verified with `decodeImage(at:)`):
- `testOpensEveryReadableFormat`: for each of `photo.heic` (64×48), `scan.tiff` (300×200), `old.bmp` (40×30), `anim.gif` (2 frames, first red), `still.webp` (`webPLossless(20,10,…)`), `anim.webp` (red, blue) → launch with `-UITestOpen` → a window with `canvas`, `statusBar.imageSize` shows the size; no alert. For the GIF and animated WebP, ⇧⌘S → save as PNG → decoded pixel (0,0) is red (first frame).
- `testSaveAsFormatPopup`: open `single.png` → ⇧⌘S → `savePanel.format` shows "PNG" and the name field "single.png"; its items are exactly "OpenRaster", "PNG", "JPEG", "HEIC", "TIFF", "BMP", "GIF" (HEIC omitted if the runner's `CGImageDestinationCopyTypeIdentifiers` lacks it) and no "WebP"; select "TIFF" → name field "single.tiff"; Cancel.
- `testSaveAsTIFFBMPGIFHEIC`: fixture 300×200 with alpha-0-with-color, semi-transparent, and opaque pixels (≤ 16 colors) → for each of TIFF, BMP, GIF, HEIC: ⇧⌘S, choose the format, save → no flatten prompt, no JPEG dialog; the file's type identifier matches; TIFF/BMP pixels equal the fixture exactly; GIF equals `binarizeAlpha` of the fixture; HEIC size matches; the window title shows the new file name.
- `testSaveAsJPEGWithQuality`: open `photo.png` (640×480 gradient) → ⇧⌘S → "JPEG" → Save → `jpegOptionsDialog` appears; `jpegOptions.qualityField` reads "95"; within 5 s `jpegOptions.fileSize` matches `^[0-9,.]+ (bytes|KB|MB)$`; record it; type "10" into the field + Return → within 5 s the label differs and is smaller; click `jpegOptions.ok` → `photo.jpg` exists, is JPEG, 640×480, and its byte count rounds to the shown label (|bytes − label×1000| ≤ 500 for KB); a second export at 95 is larger.
- `testJPEGOptionsCancelWritesNothing`: ⇧⌘S → JPEG → Save → `jpegOptions.cancel` → no `.jpg` file in the temp dir; window title unchanged; document not marked saved.
- `testJPEGSaveInPlaceShowsOptions` (replaces 0005's `jpegSaveGoesThroughSaveAsPNG`): open `photo.jpg`; paint one stroke (B, drag) to dirty it; ⌘S → no save panel, `jpegOptionsDialog` appears at "95"; set 60, OK → `photo.jpg` modification date advances, still JPEG, same size; stroke again, ⌘S → the dialog starts at "60"; Cancel → file unchanged since the previous save, document still edited.
- `testLayeredSaveAsDefaultsToOpenRaster`: open `single.png`, ⇧⌘N (Add New Layer) → ⇧⌘S → `savePanel.format` shows "OpenRaster", name "single.ora"; Cancel.
- `testFlattenPromptOnSave`: open `base.png` (opaque blue 200×150); ⇧⌘N; paint a stroke on the new layer; ⌘S → a sheet with "Flatten image?" and buttons "Flatten" and "Cancel"; Cancel → `base.png` unchanged (bytes), window still edited; ⌘S → Flatten → `base.png` contains the stroke over blue (sampled along the stroke, ±0 for PNG), `layersList` still has 2 rows; paint again, ⌘S → no flatten sheet, file updated; ⇧⌘S → choose "JPEG", save as `base.jpg` → flatten sheet appears again → Flatten → JPEG dialog → OK → `base.jpg` exists.
- 0024's `LayersMenuUITests.testMultiLayerSaveShowsFlattenHint` (rewritten as Scope 10 says) and 0005/0028 save UI tests stay green.

**Performance:** not an NF target. `JPEGSizeEstimatorPerformanceTests.testEstimate24MP` (XCTest): 6000×4000 single-layer image, one estimate at quality 95 with debounce `.zero` completes in < 1.5 s (Debug; ≈ 30× the measured raw encode, so only gross regressions fail); report the measured number in Verification status.

**Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.

**Manual verification**
1. Open a real iPhone HEIC photo (with a depth map/portrait if available) → it opens upright; save as JPEG at 95 and compare with Preview: colors match, Preview's Inspector shows sRGB and the DPI.
2. In the JPEG dialog drag the slider quickly from 100 to 0 on a 24 MP image → the UI never stalls, "Calculating…" appears briefly, and the final number matches Finder's "Get Info" size (decimal KB/MB) after saving.
3. Save a transparent-background image as JPEG → open in Preview: transparent areas are white.
4. Save as GIF and BMP and open both in Preview and a web browser → the image looks right; the GIF's soft edges are hard-edged (binary alpha).
5. VoiceOver on the JPEG dialog: the slider reads "Quality, 95", the size label reads "Estimated file size, … KB"; Tab reaches slider, field, Cancel, OK.
6. Dark mode: the JPEG dialog and the save panel's "Format:" accessory are legible and aligned.

## Open questions

Recommendations below are already applied in the spec; each needs the user's confirmation and a PRD §5.11/§12 entry.

1. **FMT-A confirmation frequency.** PRD says ⌘S writes the own format "with the FMT-A confirmation"; it doesn't say how often. **Recommended:** ask once per document session per target (file URL + format); ⌘S to the same target afterwards doesn't ask; Save As/Save To always ask; nothing is persisted. (Paint.NET avoids the repeat by flattening the document itself as an undoable step, which PRD FMT-A rules out.)
2. **JPEG transparency.** **Recommended:** composite onto white with `c' = (c·a + 255·(255−a) + 127)/255` (Paint.NET's output is white too, as reported by its users; not stated in its docs).
3. **GIF transparency threshold.** **Recommended:** our own fixed threshold 128 (alpha ≥ 128 opaque) instead of ImageIO's implicit 64, no dithering option, palette by ImageIO. Paint.NET exposes "Transparency threshold" and dithering options in its GIF dialog; PRD F-5 doesn't ask for them.
4. **BMP and FMT-B "Saving always embeds an sRGB profile".** ImageIO writes no profile into BMP (and GIF's profile handling is ImageIO's). **Recommended:** accept this exception for BMP (untagged files are read as sRGB, so pixels round-trip exactly) and note it in FMT-B; BMP is 32-bit with alpha when any pixel is non-opaque, else 24-bit (Paint.NET's "Auto" bit depth behaves the same way).
5. **HEIC quality.** PRD F-4 asks for no options. **Recommended:** fixed quality 0.90, no dialog in v1.0 (a HEIC options dialog could reuse `JPEGOptionsDialog` later).
6. **When the JPEG dialog appears.** **Recommended:** on every JPEG save (⌘S and Save As, also from the close prompt's Save…), starting at the quality last used for the document this session, else `settings.jpegQuality` (95); the dialog never changes `settings.jpegQuality` (that is APP-8's "default JPEG quality", edited in 0046). Paint.NET's quality range is 0–100 (API docs), so the slider is 0–100, not 1–100.
7. **Dialog and prompt wording.** Paint.NET's docs page for saving was unavailable. **Recommended:** sheet title "JPEG Options" with "Quality:" and "File size:"; flatten prompt "Flatten image?" / "The <format> format doesn't support layers. The saved file will contain a flattened copy of the image. The layers in this document are kept." with "Flatten" and "Cancel".

Settled (implementation-level, stated in Scope 8): this spec replaces `NSDocument`'s built-in save-panel format popup (used by 0028) with its own "Format:" accessory.

## Out of scope

- WebP **writing** (F-6 P1) → 0063.
- TGA, DDS, ICO (F-7, P2).
- Options dialogs for HEIC, TIFF (compression choice), BMP (bit depth), GIF (dithering/threshold), and JPEG chroma-subsampling choice; a compressed-preview of the JPEG on the canvas (Paint.NET shows one).
- Multi-frame/animated export (PRD §2.2 non-goal).
- Import as layer, Paste into New Layer, drag and drop (FMT-C) → 0030.
- The Settings window control for the default JPEG quality → 0046 (this spec adds only the `settings.jpegQuality` key).
- Crash-recovery autosave format → 0047. Asynchronous saving/progress → 0048.
- Preserving EXIF/GPS metadata from the source file on re-save (not required by the PRD; files are written with DPI, profile, and orientation 1 only).
