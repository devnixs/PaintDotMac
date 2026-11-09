# 0063 — Save WebP when ImageIO can encode it (capability-gated, quality dialog, alpha kept)

> Source: PRD.md §5.11 F-6 ("WebP (write only if the OS supports it through ImageIO)", write = P1), FMT-A (flatten on export only), FMT-B (save embeds sRGB, orientation not written), §5.11 "Saving" (⌘S keeps the document's format), §8 v1.x ("WebP export"), AGENTS.md "No third-party dependencies without a written justification" and "Don't add dependencies … without asking first"; §12 D-6, D-33. ImageIO SDK header `CGImageDestination.h:28` (`kCGImageDestinationLossyCompressionQuality`: "in the range 0.0 to 1.0. A value of 1.0 implies lossless compression is desired if destination format supports it").
> Milestone: v1.x
> Depends on: 0051-use-case-acceptance-tests (and through it 0029 `FileFormat`/`ImageIOCapabilities`/`ImageEncoder`/`ExportOptions`/`SavePlan`/`JPEGOptionsDialog`/`JPEGSizeEstimator`/save funnel and `saveConfirmationPresenter` seam, 0046 `AppSettings.jpegQuality`, 0049 accessibility audit of the JPEG dialog, 0001 `LaunchOptions`/`UITestApp`)

## Context

Not yet implemented; there is no application code. 0029 (`docs/specs/todo/0029-flat-export-formats_TODO.md`) made WebP **readable** and deliberately **not writable**:

- `FileFormat.webp` (`org.webmproject.webp`, extension `webp`, display name "WebP", `alphaSupport == .full`) is the last case; `canWrite(using:)` hard-codes `.webp → false` (`0029…:47,59`).
- `ImageIOCapabilities` (in `Core/IO/FileFormat.swift`, `0029…:51-58`) holds `CGImageDestinationCopyTypeIdentifiers()` once in `static let current`, and `canEncode(_:)` answers per format.
- `ImageEncoder.encode(...)` rejects `.webp` first with `.unsupportedWriteFormat(.webp)` ("PaintDotMac can't save images in the WebP format yet."), then `!capabilities.canEncode` → `.encoderUnavailable(format)`, and `CGImageDestinationCreateWithData == nil` → `.encoderUnavailable(format)` (`0029…:92`).
- `SavePlan.make` throws `.unsupportedWriteFormat(.webp)` for the read-only format (`0029…:116`); it has `needsJPEGOptions` (`0029…:120`).
- The JPEG Options sheet (`UI/JPEGOptionsDialog.swift`, `JPEGOptionsModel`, identifiers `jpegOptionsDialog`, `jpegOptions.*`) with a live size estimate from the `JPEGSizeEstimator` actor (`0029…:123-149`); the document remembers `lastJPEGQuality` per session (`0029…:147,164`).
- `PaintDocument.capabilities: ImageIOCapabilities = .current` is an injectable stored property (`0029…:153`); the save funnel calls a test seam `saveConfirmationPresenter` for the flatten prompt and the JPEG dialog (`0029…:302-305`).
- `CFBundleDocumentTypes` has `"WebP image"`, `[org.webmproject.webp]`, role **Viewer** (`0029…:173`).
- Tests that encode today's "WebP is never writable": `FileFormatTests.capabilities`, `.saveActionForJPEGWritesInPlace` (WebP → Save As), `.suggestedSaveFormatRules` ((.webp, 1) → `.openRaster`), `SavePlanTests.unwritableFormatsThrow`, `ImageEncoderTests.unsupportedWriteFormat`, `ImageEncoderFormatTests.failurePaths`, `PaintDocumentFormatTests.dataOfTypeWebPThrows`, `ExportFormatsUITests.testSaveAsFormatPopup` ("no WebP").

**ImageIO WebP write support, measured for this spec** (probe script run outside the repo, 2026-11-08, macOS **26.6.2 (25G83)**, Xcode **26.3 (17C529)**, Swift 6.2.4, Apple silicon):

- `CGImageDestinationCopyTypeIdentifiers()` does **not** contain `org.webmproject.webp`. The full list: `com.adobe.pdf, com.adobe.photoshop-image, com.apple.atx, com.apple.icns, com.compuserve.gif, com.ilm.openexr-image, com.microsoft.bmp, com.microsoft.dds, com.microsoft.ico, com.truevision.tga-image, org.khronos.astc, org.khronos.ktx, org.khronos.ktx2, public.avif, public.heic, public.heics, public.jpeg, public.jpeg-2000, public.pbm, public.png, public.pvr, public.tiff`.
- `CGImageDestinationCreateWithData(data, "org.webmproject.webp", 1, nil)` returns **nil**.
- `CGImageSourceCopyTypeIdentifiers()` **does** contain `org.webmproject.webp` (reading works, as 0029 found).
- The ImageIO SDK headers have **no WebP encoder keys**: `kCGImagePropertyWebPDictionary` holds only read-side animation keys (`LoopCount`, `DelayTime`, `UnclampedDelayTime`, `FrameInfoArray`, `CanvasPixelWidth/Height`). There is no lossless switch; the only documented control is `kCGImageDestinationLossyCompressionQuality`, where 1.0 "implies lossless compression is desired if destination format supports it".

So on every Mac the project currently targets, this spec changes **nothing the user can see**: WebP stays out of Save As and a WebP document's ⌘S goes to Save As. What it adds is the capability-driven path that turns WebP export on automatically, with no OS-version check, on any macOS whose ImageIO lists the WebP encoder, plus tests that prove both paths on any machine through injected capabilities. Adding `libwebp` is **not** part of this spec (PRD F-6 and AGENTS.md forbid a dependency without the user's approval; see *Open questions* 1).

## User story

As a PaintDotMac user on a Mac whose system can encode WebP, I can choose "WebP" in Save As (or press ⌘S on an opened WebP), pick a quality from 0 to 100 with a live file-size estimate, and get a WebP file that keeps transparency; a layered image asks "Flatten image?" first. On a Mac that can't encode WebP (every macOS release up to 26.6 at the time of writing), WebP never appears in Save As, and ⌘S on a WebP opens Save As suggesting OpenRaster, exactly as before.

## Scope & changes

### Core (pure, unit-tested; Foundation, CoreGraphics, ImageIO, UniformTypeIdentifiers only)

1. **`Core/IO/FileFormat.swift`** (extend 0029):
   - `canWrite(using capabilities: ImageIOCapabilities) -> Bool` = `capabilities.canEncode(self)` for **every** case (remove the `.webp → false` special case). `.openRaster` stays always true through `canEncode`. Consequently `writableFormats(using:)` (declaration order) is `[.openRaster, .png, .jpeg, .heic, .tiff, .bmp, .gif, .webp]` when the capabilities contain all seven ImageIO identifiers, and the 0029 seven without WebP when they lack `org.webmproject.webp`. No OS-version check (`#available`, `ProcessInfo.operatingSystemVersion`) anywhere in this feature.
   - `isLossy`: `.webp` → **true** (we always pass a lossy quality; see Scope 3).
   - `suggestedSaveFormat(for:layerCount:capabilities:)` and `saveAction(for:layerCount:capabilities:)` are unchanged in code; they now return `.webp` / `.writeInPlace(.webp)` for a single-layer WebP document when the capabilities can encode WebP (they already defer to `canWrite(using:)`).
   - `ImageIOCapabilities` gains `func removing(_ typeIdentifiers: Set<String>) -> ImageIOCapabilities` (set difference; used by the debug launch hook below and by tests) and `static let webPTypeIdentifier = "org.webmproject.webp"` is **not** added: use `FileFormat.webp.typeIdentifier`.
   - Remove the doc comment "WebP write in 0063".

2. **`Core/IO/ImageCodecError.swift`**: no new case. WebP without an encoder now reports 0029's `.encoderUnavailable(.webp)` → "This Mac can't save WebP images." / "Choose another format with File > Save As…". `.unsupportedWriteFormat` keeps its case and text (no format produces it after this spec; it stays for future read-only formats such as F-7). Every WebP path that threw `.unsupportedWriteFormat(.webp)` in 0029 throws `.encoderUnavailable(.webp)` instead.

3. **`Core/IO/ImageEncoder.swift`** (extend 0029):
   - `ExportOptions` gains `var webPQuality: Int = ImageEncoder.defaultWebPQuality` (0…100, clamped on use). `ImageEncoder.defaultWebPQuality = 95` (see *Open questions* 3).
   - Remove the `.webp`/read-only first check. Order in the surface entry point becomes: `!capabilities.canEncode(format)` → `.encoderUnavailable(format)`; `CGImageDestinationCreateWithData` nil → `.encoderUnavailable(format)` (this is the path an injected "WebP-capable" capabilities value hits on a Mac whose ImageIO can't actually encode WebP: an alert, never a crash); finalize false → `.encodingFailed`.
   - Factor two pure helpers out of 0029's per-format branches (every existing format keeps exactly its 0029 behavior; 0029's tests stay green unchanged):
     ```swift
     /// Per-pixel preparation before encoding: .jpeg → compositeOverWhite, .gif → binarizeAlpha(_, gifAlphaThreshold), every other format → unchanged.
     static func preparedPixel(_ pixel: ColorRGBA8, for format: FileFormat) -> ColorRGBA8
     /// The properties dictionary passed to CGImageDestinationAddImage for `format`.
     static func destinationProperties(for format: FileFormat, dpi: Double, options: ExportOptions) -> [CFString: Any]
     ```
     For `.webp`: pixels unchanged (straight RGBA, `CGImageAlphaInfo.last`, sRGB color space so ImageIO can embed the profile, never premultiplied); properties exactly `kCGImageDestinationLossyCompressionQuality = Double(clamp(options.webPQuality, 0...100)) / 100`, `kCGImagePropertyDPIWidth = dpi`, `kCGImagePropertyDPIHeight = dpi`, and nothing else (no orientation → upright, FMT-B; no JFIF/TIFF dictionaries; no `kCGImagePropertyWebPDictionary`, whose keys are read-only animation metadata). Quality 100 → 1.0, which ImageIO documents as "lossless if the format supports it"; we don't promise lossless (*Open questions* 2). One frame only (PRD §2.2).
   - The layered entry point needs no change: `.webp` is not `supportsLayers`, so it goes through 0029's `exportSurface(of:)` (FMT-A flatten on export; the document is never modified).

4. **`Core/IO/SavePlan.swift`** (extend 0029):
   - Add `var needsWebPOptions: Bool` = `format == .webp && operation != .autosave`. `needsJPEGOptions` unchanged (never true for WebP).
   - Remove the "read-only format → `.unsupportedWriteFormat`" rule; the only refusal is `!format.canWrite(using: capabilities)` → `.encoderUnavailable(format)`.
   - Flatten rules unchanged: a WebP save of a multi-layer image asks "Flatten image?" (the prompt's text uses `displayName` → "The WebP format doesn't support layers. …"), then the WebP dialog.

5. **`Core/IO/JPEGSizeEstimator.swift`** (extend 0029): `init(image:format: FileFormat = .jpeg, debounce:encode:)`. `format` must be `.jpeg` or `.webp` (`precondition`, invariant: only the options dialog constructs it). The default `encode` closure encodes as `format` with `ExportOptions(jpegQuality: q)` for JPEG or `ExportOptions(webPQuality: q)` for WebP. Debounce, supersede, cancel, cached flatten, and `formatted(byteCount:)` are unchanged. A WebP estimate on a Mac without the encoder returns `.failure(.encoderUnavailable(.webp))` (the dialog is never shown there, but the estimator must not crash).

### Platform glue (hosted tests + UI tests)

6. **`PaintDotMac/App/LaunchOptions.swift`** (extend 0001, `#if DEBUG` only): new hook `-UITestDisableEncoders <comma-separated UTIs>` → `static var imageIOCapabilities: ImageIOCapabilities` = `ImageIOCapabilities.current.removing(<parsed set>)`; without the argument (and in Release) it is `.current`. Parsing is a pure static `func parseDisabledEncoders(_ arguments: [String]) -> Set<String>` (trims whitespace, ignores empty items). This lets UI tests exercise the "no WebP encoder" behavior on a Mac that has one.

7. **`PaintDotMac/Document/PaintDocument.swift`** (extend 0029):
   - `var capabilities: ImageIOCapabilities = LaunchOptions.imageIOCapabilities` (was `.current`). Everything that 0029 derives from it (`writableTypes(for:)`, `saveDocument(_:)`'s `saveAction`, the "Format:" accessory items and preselection, `SavePlan.make`, `data(ofType:)`) automatically includes WebP when it is encodable. The `savePanel.format` popup lists "WebP" last.
   - `lastWebPQuality: Int?` (plain stored property, session only, not persisted, not affected by undo), parallel to `lastJPEGQuality`.
   - Save funnel step 4 (0029 `…:161`) generalizes: if `needsJPEGOptions` → JPEG dialog (unchanged); if `needsWebPOptions` → the same dialog with `format: .webp`, initial quality `lastWebPQuality ?? ImageEncoder.defaultWebPQuality`; OK → `lastWebPQuality = q` and `pendingExportOptions = ExportOptions(jpegQuality: <unchanged default>, webPQuality: q)`; Cancel → `CocoaError(.userCancelled)`, nothing written. The flatten prompt (when needed) comes **before** the WebP dialog, as for JPEG.
   - `saveConfirmationPresenter` (0029's internal seam): its quality-options request carries the format and the initial quality (`.qualityOptions(format: FileFormat, initialQuality: Int)` or the equivalent shape 0029 shipped, extended with the format) so hosted tests can tell JPEG and WebP requests apart.
   - `data(ofType:)` default options when `pendingExportOptions` is nil: `ExportOptions(jpegQuality: AppSettings().jpegQuality, webPQuality: ImageEncoder.defaultWebPQuality)`.
   - Info.plist role for `org.webmproject.webp` stays **Viewer** (Info.plist is static and WebP is not writable on current macOS; saving is governed by the `writableTypes(for:)`/`saveDocument(_:)` overrides). If the implementer finds that AppKit refuses an in-place save for a Viewer-role type on a WebP-capable Mac, change the role to `Editor` and record it in the Verification status; no other change.

8. **`PaintDotMac/UI/JPEGOptionsDialog.swift`** (extend 0029; file and type names kept so 0046/0049 references stay valid):
   - `JPEGOptionsModel(format: FileFormat = .jpeg, image:initialQuality:)`; the model owns `JPEGSizeEstimator(image:format:)`.
   - Per format: title "JPEG Options" / **"WebP Options"**; root identifier `jpegOptionsDialog` / **`webpOptionsDialog`**; control identifiers `jpegOptions.quality|qualityField|fileSize|ok|cancel` / **`webpOptions.quality|qualityField|fileSize|ok|cancel`**. Labels ("Quality:", "File size:", "Calculating…", "Unavailable", "Cancel", "OK"), slider 0…100 step 1, field validation, VoiceOver labels ("Quality", "Estimated file size") are identical for both. The WebP dialog never reads or writes `settings.jpegQuality`.
   - Put the per-format strings/identifiers in a pure `struct QualityOptionsPresentation { let title: String; let identifierPrefix: String; static func forFormat(_ format: FileFormat) -> QualityOptionsPresentation }` in `Core/IO/QualityOptionsPresentation.swift` so they are unit-tested.
   - **Accessibility** — `Core/Accessibility/AccessibilityCatalog.swift` / `KeyboardNavigationPlan.swift` (extend 0049): new `AccessibilitySurface` case `webpOptionsDialog` (after `jpegOptionsDialog`) with the same entries as 0049's `jpegOptionsDialog`, prefix `webpOptions`: `webpOptions.quality` slider "Quality" (`integer`), `webpOptions.qualityField` textField "Quality value", `webpOptions.fileSize` staticText "Estimated file size" (`text`), `webpOptions.cancel` button "Cancel", `webpOptions.ok` button "OK"; `KeyboardNavigationPlan.plan(for: .webpOptionsDialog)` = the `jpegOptionsDialog` plan with the prefix swapped. Generate both surfaces' entries from one helper keyed by `QualityOptionsPresentation.identifierPrefix` so they can't drift.

9. **`PaintDotMacUITests/Support/UITestApp.swift`**: add `static var runnerCanEncodeWebP: Bool` = `(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains("org.webmproject.webp")` (the runner runs on the same OS as the app, so this is the app's real capability); `launch(…, disabledEncoders: [String] = [])` passes `-UITestDisableEncoders`. 0029's `decodeImage(at:)` already reports `typeIdentifier`/`frameCount`/`profileName`.

10. **Tests changed because behavior intentionally changes** (all in 0029's files):
    - `FileFormatTests.capabilities`: drop "`.webp.canWrite(using: all) == false`"; with a capabilities value containing the seven ImageIO identifiers `.webp.canWrite == true`, without WebP `false`. `isLossy` now JPEG/HEIC/GIF/WebP.
    - `FileFormatTests.writableFormatsDependOnCapabilities`: "all six ImageIO types" case keeps its expectation (seven formats, no WebP); add the WebP case (Scope 1).
    - `FileFormatTests.saveActionForJPEGWritesInPlace` and `.suggestedSaveFormatRules`: the WebP rows pass an explicit no-WebP capabilities value (so they no longer depend on the machine); WebP-capable rows are in the new tests below.
    - `SavePlanTests.unwritableFormatsThrow`: `.webp` with no-WebP capabilities → `.encoderUnavailable(.webp)` (was `.unsupportedWriteFormat(.webp)`).
    - `ImageEncoderTests.unsupportedWriteFormat` → renamed `webPWithoutEncoderUnavailable`: `.webp` with no-WebP capabilities → `.encoderUnavailable(.webp)`. `ImageEncoderFormatTests.failurePaths`: same replacement for its `.webp` row.
    - `PaintDocumentFormatTests.dataOfTypeWebPThrows` → replaced by `PaintDocumentWebPTests.dataOfTypeWebPMatchesCapability`.
    - `ExportFormatsUITests.testSaveAsFormatPopup`: the expected items are 0029's list plus "WebP" last **iff** `UITestApp.runnerCanEncodeWebP` (still never skipped).

11. `project.yml`: no change besides the new source/test files; run `xcodegen generate`.

12. **PRD**: not edited by this spec (batch rule). Once the open questions are answered, record them in PRD §5.11 F-6 and §12.

## Acceptance criteria

- [ ] WebP is writable exactly when `ImageIOCapabilities` reports `org.webmproject.webp`; there is no OS-version check. → `FileFormatTests.webPWritabilityFollowsCapabilities`, `ImageIOCapabilitiesTests.currentMatchesImageIO`, code review (grep for `#available`/`operatingSystemVersion` in the changed files finds none)
- [ ] With the encoder: Save As lists "WebP" last, ⌘S on a single-layer WebP writes in place, and a layered image suggests OpenRaster. Without it (macOS 26.6 measured): Save As has no "WebP", ⌘S on a WebP goes to Save As with "OpenRaster" preselected and `<name>.ora`, and nothing else changes from 0029. → `FileFormatTests.webPWritabilityFollowsCapabilities`, `PaintDocumentWebPTests.writableTypesFollowCapabilities`, `.webPDocumentSaveAction`, `WebPExportUITests.testWebPHiddenWhenEncoderDisabled`, `.testWebPExportMatchesCapability`
- [ ] Saving WebP shows the "WebP Options" sheet with Quality 0–100 (default 95, then the last value used for the document this session) and a live "File size:" estimate; Cancel writes nothing; OK writes with `kCGImageDestinationLossyCompressionQuality = q/100`. → `ImageEncoderTests.webPDestinationProperties`, `SavePlanTests.webPPlan`, `QualityOptionsPresentationTests.*`, `JPEGSizeEstimatorTests.webPEstimate*`, `PaintDocumentWebPTests.webPSaveRequestsOptions`, `.webPOptionsCancelWritesNothing`, `WebPExportUITests.testWebPExportMatchesCapability`
- [ ] WebP output keeps alpha (straight RGBA, no compositing over white), is upright, one frame, sRGB-tagged. → `ImageEncoderTests.webPPixelsUnchanged`, `ImageEncoderWebPTests.encodeMatchesCapability`
- [ ] Multi-layer → WebP asks "Flatten image?" first and writes the composite; the document keeps its layers; autosave never prompts. → `SavePlanTests.webPPlan`, `PaintDocumentWebPTests.layeredWebPSaveFlattensFirst`, `.autosaveNeverShowsWebPOptions`
- [ ] When capabilities claim WebP but ImageIO can't create the destination, saving fails with "This Mac can't save WebP images.", leaves no file and the document edited — no crash. → `ImageEncoderWebPTests.forcedCapabilityWithoutEncoderFailsCleanly`, `PaintDocumentWebPTests.webPSaveRequestsOptions` (incapable branch)
- [ ] The JPEG dialog, JPEG export, and every 0029 format behave exactly as before. → 0029's suites unchanged except Scope 10, `ImageEncoderTests.preparedPixelMatches0029Rules`
- [ ] The WebP Options sheet is catalogued for accessibility with the JPEG sheet's labels and Tab order. → `AccessibilityCatalogTests.webpOptionsDialogMirrorsJPEG`, `KeyboardNavigationPlanTests.webpOptionsDialogPlan`, `AccessibilityAuditUITests.testAuditWebPOptionsDialogLight/Dark`
- [ ] The `-UITestDisableEncoders` hook removes the listed types in Debug and doesn't exist in Release. → `LaunchOptionsTests.disableEncodersParsing`, `ImageIOCapabilitiesTests.removing`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality-gate launch smoke).

## Edge cases

- **Current macOS (no encoder):** every user-visible behavior equals 0029: no "WebP" item; a WebP document's ⌘S → Save As with OpenRaster; `data(ofType: "org.webmproject.webp")` → `.encoderUnavailable(.webp)` ("This Mac can't save WebP images."), shown by NSDocument's alert; document stays open and edited; no partial file.
- **Capabilities say yes but ImageIO says no** (an injected value, or a future OS whose type list and encoder disagree): `CGImageDestinationCreateWithData` nil → `.encoderUnavailable(.webp)`; no crash, no file.
- **Quality extremes:** 0 → 0.0; 100 → 1.0 (ImageIO may encode losslessly; not asserted); −5 → 0.0; 150 → 1.0. Field input "-1", "101", "abc", "" reverts (0029 rule).
- **Transparency:** fully transparent pixels stay transparent (alpha 0); lossy WebP may change the RGB stored under alpha 0 — the color under alpha 0 is preserved only by lossless formats (FMT-B "when the source provides straight alpha" applies to reading). Semi-transparent alpha is kept within the codec's error (tests: ±8 away from edges).
- **DPI:** the DPI keys are passed; WebP has no standard density field, so a reopened WebP reads either the document DPI (if ImageIO stored it, e.g. as EXIF) or 0002's default 96. Tests accept exactly those two values and the implementer records which one in the Verification status.
- **sRGB profile:** passed through the sRGB `CGColorSpace`; on a capable Mac the test asserts the reopened profile name contains "sRGB". If a future encoder writes no ICC chunk, that test fails and the implementer records it as a FMT-B exception question (like 0029's BMP), without weakening the test silently (*Open questions* 4).
- **Layered WebP save from the close prompt:** flatten prompt → WebP dialog; Cancel in either aborts the close (0029 rule).
- **Opened animated WebP** (first frame, FMT-D) saved as WebP on a capable Mac → one frame (`frameCount == 1`).
- **Huge image (APP-10):** estimator runs off the main actor (0029); encode failure → `.encodingFailed` alert.
- **Release build:** `-UITestDisableEncoders` is ignored (compiled out); capabilities are `.current`.

## Test plan

Expected values come from ImageIO's documented key semantics, hand calculation, and direct calls to `CGImageDestinationCopyTypeIdentifiers()` in the test as an independent oracle — never from running the code under test and pasting output. **No test is skipped**: every test that depends on the machine's WebP encoder computes `let canEncodeWebP = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains("org.webmproject.webp")` and asserts the correct behavior for that value (success path when true, the defined refusal when false). On the measured Mac (macOS 26.6.2) the refusal branch runs; injected capabilities cover the decision logic of the success path everywhere.

Test fixtures: `TestImages` (0002) and `webPLossless`/`animatedWebP` (0029). `capsAll` = `ImageIOCapabilities(destinationTypes: ["public.png","public.jpeg","public.heic","public.tiff","com.microsoft.bmp","com.compuserve.gif","org.webmproject.webp"])`; `capsNoWebP` = `capsAll.removing(["org.webmproject.webp"])`.

**Unit tests**
- `PaintDotMacTests/IO/FileFormatTests.swift` (extend):
  - `webPWritabilityFollowsCapabilities`: `.webp.canWrite(using: capsAll) == true`, `(using: capsNoWebP) == false`; `writableFormats(using: capsAll) == [.openRaster, .png, .jpeg, .heic, .tiff, .bmp, .gif, .webp]`, `(using: capsNoWebP)` == the same without `.webp`; `saveAction(for: .webp, layerCount: 1, capabilities: capsAll) == .writeInPlace(.webp)`; `(…, layerCount: 3, capsAll) == .writeInPlace(.webp)` (⌘S keeps the format; flatten comes from SavePlan); `(…, 1, capsNoWebP) == .saveAs(offering: writableFormats(using: capsNoWebP), suggested: .openRaster)`; `suggestedSaveFormat(for: .webp, layerCount: 1, capabilities: capsAll) == .webp`, `(…, 2, capsAll) == .openRaster`, `(…, 1, capsNoWebP) == .openRaster`; `.webp.isLossy == true`, `.webp.alphaSupport == .full`.
- `PaintDotMacTests/IO/ImageIOCapabilitiesTests.swift` (new):
  - `currentMatchesImageIO`: `ImageIOCapabilities.current.canEncode(.webp) == canEncodeWebP` (oracle computed in the test); `FileFormat.writableFormats(using: .current).contains(.webp) == canEncodeWebP`. The test prints `canEncodeWebP` plus `ProcessInfo.processInfo.operatingSystemVersionString` so the gate log records the machine's answer.
  - `removing`: `capsAll.removing(["org.webmproject.webp", "public.heic"]).destinationTypes == capsAll.destinationTypes.subtracting(those)`; removing an absent identifier is a no-op; removing `[]` returns an equal value.
- `PaintDotMacTests/IO/ImageEncoderTests.swift` (extend):
  - `webPDestinationProperties`: `destinationProperties(for: .webp, dpi: 300, options: ExportOptions(jpegQuality: 10, webPQuality: 80))` has exactly 3 keys: lossy quality `0.80`, DPI width `300`, DPI height `300`; webPQuality 0 → 0.0, 100 → 1.0, −5 → 0.0, 150 → 1.0; no `kCGImagePropertyOrientation`, no `kCGImagePropertyJFIFDictionary`, no `kCGImagePropertyWebPDictionary`. `destinationProperties(for: .jpeg, …same options…)` has lossy quality `0.10` (each format reads its own quality).
  - `webPPixelsUnchanged`: `preparedPixel(p, for: .webp) == p` for `(255,0,0,128)`, `(10,20,30,0)`, `(0,0,0,0)`, `(1,2,3,255)` and for 1,000 `SeededRandom` pixels.
  - `preparedPixelMatches0029Rules`: `.jpeg` → `compositeOverWhite(p)`, `.gif` → `binarizeAlpha(p, threshold: 128)`, `.png/.tiff/.bmp/.heic` → `p`, for the same pixel set (hand values: `(255,0,0,128)` → JPEG `(255,127,127,255)`, GIF `(255,0,0,255)`).
  - `webPWithoutEncoderUnavailable` (renamed from 0029's `unsupportedWriteFormat`): `encode(surface, …, as: .webp, capabilities: capsNoWebP)` throws `.encoderUnavailable(.webp)`.
- `PaintDotMacTests/IO/ImageEncoderWebPTests.swift` (new; real ImageIO; never skipped):
  - `encodeMatchesCapability`: fixture 256×256, R = x, G = y, B = 128; left half alpha 255, right half alpha 128; dpi 300. `encode(…, as: .webp, options: .init(webPQuality: 90))` with `.current`:
    - if `canEncodeWebP`: data starts with `"RIFF"` and bytes 8–11 are `"WEBP"`; `CGImageSourceGetType == "org.webmproject.webp"`; `CGImageSourceGetCount == 1`; `ImageDecoder.decode` → 256×256; PSNR (RGB, opaque half, interior ≥ 8 px from edges and the alpha boundary) ≥ 30 dB; decoded alpha within ±8 of 255 / 128 in those interiors; profile name contains "sRGB"; DPI ∈ {300, 96} (recorded). Quality 10 output is strictly smaller than quality 90 output. Quality 100 → PSNR ≥ 45 dB.
    - else: throws `.encoderUnavailable(.webp)` (the measured outcome on macOS 26.6.2).
  - `layeredExportMatchesCapability`: 0024's three-layer fixture (white Background; red opacity 128; blue hidden) → `encode(image, as: .webp, options: .init(webPQuality: 95))`: capable → decodes within ±4 per channel of `(255,127,127,255)` at interior pixels and the input `LayeredImage` is unchanged (3 layers, identical tiles); incapable → `.encoderUnavailable(.webp)`, input unchanged.
  - `forcedCapabilityWithoutEncoderFailsCleanly`: only when `!canEncodeWebP` (on a capable Mac the same test asserts instead that `capsAll`-forced encode **succeeds**, so it never skips): `encode(…, as: .webp, capabilities: capsAll)` throws `.encoderUnavailable(.webp)` (the `CGImageDestinationCreateWithData == nil` path) — no crash.
- `PaintDotMacTests/IO/SavePlanTests.swift` (extend):
  - `webPPlan`: `capsAll`: 1 layer `.save`/`.saveAs`/`.saveTo` → `needsWebPOptions`, `!needsJPEGOptions`, `!flattens`; 2 layers `.saveAs` → `flattens`, `needsFlattenConfirmation`, `needsWebPOptions`; 2 layers `.save` with `confirmedFlattenTarget == target` → no confirmation, still `needsWebPOptions`; `.autosave` → no options, no confirmation. `capsNoWebP` → throws `.encoderUnavailable(.webp)`. JPEG and PNG plans → `needsWebPOptions == false`.
- `PaintDotMacTests/IO/QualityOptionsPresentationTests.swift` (new): `.jpeg` → title "JPEG Options", prefix "jpegOptions", root `jpegOptionsDialog`; `.webp` → "WebP Options", "webpOptions", `webpOptionsDialog`; other formats are not passed (precondition documented, not tested).
- `PaintDotMacTests/Accessibility/AccessibilityCatalogTests.swift` / `KeyboardNavigationPlanTests.swift` (extend 0049): `webpOptionsDialogMirrorsJPEG` — `entries(for: .webpOptionsDialog)` equals `entries(for: .jpegOptionsDialog)` with `jpegOptions.` → `webpOptions.` (roles, labels, values, order identical); `webpOptionsDialogPlan` — initial `webpOptions.quality` (as 0049's JPEG plan), default `webpOptions.ok`, cancel `webpOptions.cancel`, tabOrder = the JPEG plan's with the prefix swapped.
- `PaintDotMacTests/IO/JPEGSizeEstimatorTests.swift` (extend):
  - `webPEstimateUsesWebPQuality`: injected counting encoder, `format: .webp`, debounce `.zero`: `estimate(quality: 70)` → the encoder received quality 70 once; `.success(count)` equals the injected return value.
  - `webPEstimateMatchesCapability` (default encoder, 64×64 gradient): capable → `.success(n)` where, if two consecutive `ImageEncoder.encode(…, as: .webp, webPQuality: 70)` calls return equal `Data` (checked in the test), `n` equals that byte count, else `n` is within 2% of it (the deterministic branch is expected; the test records which branch ran); incapable → `.failure(.encoderUnavailable(.webp))`.
  - All 0029 estimator tests stay unchanged (default `format: .jpeg`).
- `PaintDotMacTests/App/LaunchOptionsTests.swift` (extend 0001's suite): `disableEncodersParsing`: `["-UITestDisableEncoders", "org.webmproject.webp, public.heic"]` → `{"org.webmproject.webp","public.heic"}`; `"a,,b "` → `{"a","b"}`; argument missing → `[]`; flag without value → `[]`.
- `PaintDotMacTests/IO/ImageCodecErrorTests.swift` (extend `messages`): `.encoderUnavailable(.webp).errorDescription == "This Mac can't save WebP images."`.

**Integration tests** (`PaintDotMacTests/Document/PaintDocumentWebPTests.swift`, `@MainActor`, app-hosted, documents built in code; fixture `still.webp` = `TestImages.webPLossless(width: 40, height: 20, color: (12,34,56,200))` written to a temp dir; `saveConfirmationPresenter` scripted):
- `writableTypesFollowCapabilities`: `capabilities = capsAll` → `writableTypes(for: .saveAsOperation)` = the eight identifiers in declaration order (WebP last); `capsNoWebP` → seven.
- `webPDocumentSaveAction`: document read from `still.webp`: `capsAll` → `saveAction` `.writeInPlace(.webp)`; `capsNoWebP` → `.saveAs` suggesting `.openRaster`; the accessory's computed preselection (`FileFormat.suggestedSaveFormat`) and suggested name `still.ora`.
- `webPSaveRequestsOptions`: `capabilities = canEncodeWebP ? .current : capsAll`, 1-layer edited document, `save(to: tmp/out.webp, ofType: "org.webmproject.webp", for: .saveAsOperation)`; presenter records requests and answers quality 70 → exactly one request, `.qualityOptions(format: .webp, initialQuality: 95)`, no flatten request; `lastWebPQuality == 70`; then:
  - capable: no error; file decodes as WebP, 40×20; document clean, `fileType == "org.webmproject.webp"`; a second save request starts at 70; `settings.jpegQuality` (private suite) unchanged.
  - incapable (measured): completion error `.encoderUnavailable(.webp)`; no file at the URL; document still edited with its old `fileURL`/`fileType`; a second attempt's request still starts at 70 (the choice was remembered on OK).
- `webPOptionsCancelWritesNothing`: presenter answers Cancel → `CocoaError(.userCancelled)`, no file, still edited, `lastWebPQuality == nil` (either capability).
- `layeredWebPSaveFlattensFirst`: 2-layer document, `capabilities = canEncodeWebP ? .current : capsAll`, `.saveAsOperation` to `.webp` → presenter receives the flatten request **then** the WebP options request (order asserted); Cancel at flatten → no options request, nothing written. Capable: Flatten + 90 → file decodes to the composite (±4), document still 2 layers, history unchanged. Incapable: `.encoderUnavailable(.webp)`, document still 2 layers.
- `autosaveNeverShowsWebPOptions`: `.autosaveElsewhereOperation` with `fileType` WebP and `capsAll` → presenter never called (0047 autosave writes `.ora`).
- `dataOfTypeWebPMatchesCapability` (replaces 0029's `dataOfTypeWebPThrows`): real `.current` capabilities: capable → data starts `RIFF…WEBP`; incapable → throws `.encoderUnavailable(.webp)`.
- `jpegFlowUnchanged`: 0029's `jpegSaveUsesChosenQuality` scenario with `capsAll`: the request is `.qualityOptions(format: .jpeg, initialQuality: 95)` and the saved bytes equal `ImageEncoder.encode(image, as: .jpeg, options: .init(jpegQuality: 30))`.

**Golden-image tests:** none (no rendering; WebP is lossy and checked by PSNR).

**UI tests** (`PaintDotMacUITests/WebPExportUITests.swift`; `UITestApp`, `-UITestResetDefaults YES`, fixtures generated per test in a temp dir; `canEncodeWebP = UITestApp.runnerCanEncodeWebP`; none skipped):
- `testWebPHiddenWhenEncoderDisabled` (always exercises the "unsupported" UI, on any Mac): launch with `disabledEncoders: ["org.webmproject.webp"]` and `-UITestOpen still.webp` → canvas, `statusBar.imageSize` "40 × 20"; paint one stroke (B, drag); ⌘S → a save panel appears (no in-place write, no `webpOptionsDialog`); `savePanel.format` selected title "OpenRaster", its items don't include "WebP", name field `still.ora`; Cancel → `still.webp` bytes unchanged, window still edited.
- `testWebPExportMatchesCapability` (no hook): open `alpha.png` (200×100; left half opaque gradient, right half `(0,0,255,128)`):
  - if `canEncodeWebP`: ⇧⌘S → `savePanel.format` items end with "WebP"; select it → name field `alpha.webp`; Save → `webpOptionsDialog` appears; `webpOptions.qualityField` reads "95"; within 5 s `webpOptions.fileSize` matches `^[0-9,.]+ (bytes|KB|MB)$`; type "80" + Return; `webpOptions.ok` → `alpha.webp` exists, `decodeImage(at:)` reports `org.webmproject.webp`, 200×100, `frameCount == 1`, alpha at (150, 50) within ±8 of 128 and at (50, 50) == 255; window title "alpha.webp". Paint a stroke, ⌘S → no save panel, `webpOptionsDialog` starts at "80"; OK → the file's modification date advances.
  - else (measured on macOS 26.6.2): ⇧⌘S → `savePanel.format` items are exactly 0029's list (no "WebP"); Cancel. Then open `still.webp` (File > Open via `-UITestOpen` relaunch), stroke, ⌘S → save panel with "OpenRaster"/`still.ora`; Cancel; `still.webp` unchanged.
- `ExportFormatsUITests.testSaveAsFormatPopup` updated as in Scope 10.
- 0049's accessibility audit: add `AccessibilityAuditUITests.testAuditWebPOptionsDialogLight/Dark` that runs the audit on `webpOptionsDialog` when `canEncodeWebP`, else asserts that "WebP" is absent from `savePanel.format` (never skipped).

**Performance:** none (no NF target; the estimator reuses 0029's measured path).

**Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes. The Verification status records the machine's `canEncodeWebP` (printed by `ImageIOCapabilitiesTests.currentMatchesImageIO`) and therefore which branch of the capability tests ran.

**Manual verification**
1. On the current Mac (macOS 26.6.x): open a WebP from Finder ("Open With" PaintDotMac) → it opens; ⇧⌘S → the Format popup has no "WebP"; ⌘S on the edited WebP opens Save As with OpenRaster selected. Expected: identical to 0029.
2. Only on a macOS release whose ImageIO lists `org.webmproject.webp` (check with the probe `swift -e 'import ImageIO; print((CGImageDestinationCopyTypeIdentifiers() as! [String]).contains("org.webmproject.webp"))'`): save a transparent-background image as WebP at 80 → open it in Safari and Preview: transparency kept, colors match, Preview's Inspector shows sRGB; the shown file size matches Finder's Get Info (decimal units); VoiceOver reads "Quality, 80" and "Estimated file size, … KB" in the WebP Options sheet; dark mode legible.
3. Same Mac as 2: drag the quality slider quickly from 100 to 0 on a 24 MP image → no UI stall, "Calculating…" briefly.

## Open questions

Recommendations below are already applied in the spec; each needs the user's confirmation and a PRD §5.11 F-6 / §12 entry.

1. **libwebp if ImageIO never gains WebP write.** ImageIO on macOS 26.6.2 (Xcode 26.3) can read but not write WebP, so this spec ships a path that is dormant on every current Mac. Should PaintDotMac add `libwebp` (a third-party dependency, which PRD/AGENTS.md require the user to approve) to make WebP export always available? **Recommended: no.** Keep WebP export capability-gated through ImageIO, with no dependency; revisit only if users ask for WebP export.
2. **Lossless WebP option.** ImageIO exposes no WebP-specific lossless key; the only control is `kCGImageDestinationLossyCompressionQuality`, where 1.0 "implies lossless compression is desired if destination format supports it". **Recommended:** no separate "Lossless" checkbox; quality 100 requests lossless implicitly, and the app doesn't promise lossless output.
3. **WebP options dialog and default quality.** **Recommended:** reuse the JPEG Options sheet as "WebP Options" (Quality 0–100 slider + field, live "File size:" estimate, OK/Cancel) on every WebP save (⌘S, Save As, close prompt), starting at the quality last used for the document this session, else **95** (same default as JPEG/Paint.NET's JPEG default; Paint.NET's WebP docs page could not be checked offline), with no persisted default and no Settings window control.
4. **FMT-B sRGB profile for WebP.** If an ImageIO WebP encoder turns out not to embed an ICC profile, should that be accepted as a FMT-B exception (as recommended for BMP in 0029)? **Recommended: yes**, since untagged files are read as sRGB; the capable-branch test asserts the profile and the implementer reports a failure rather than weakening it.

## Out of scope

- Adding `libwebp` or any other WebP encoder (*Open questions* 1).
- Animated WebP export (PRD §2.2 non-goal); WebP metadata (EXIF/XMP) beyond DPI and the profile.
- A Settings window default for WebP quality (0046 covers JPEG only).
- AVIF or other formats ImageIO can write but the PRD doesn't list (F-7 is P2: TGA, DDS, ICO).
- Changing the Info.plist WebP role from Viewer, unless AppKit requires it (Scope 7).
