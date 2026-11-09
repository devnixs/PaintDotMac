# 0005 — Create new images and save documents as PNG

> Source: PRD.md §5.11 F-2 (PNG write), §5.11 "Saving" (P0), FMT-B (save always embeds sRGB), §5.1 APP-9 (New Image dialog), APP-10 (limits), APP-5 (per-document DPI written to flat files), §5.12 (⌘N / ⌘S / ⇧⌘S), §8 M0 exit criterion ("Can open, view, and re-save an image"), §12 D-6, D-7, D-8, D-10, D-24, D-30 (New Image DPI range, clipboard DPI ignored, untouched new image clean), D-33 (alpha-0 color preserved). Paint.NET: https://paint.net/doc/latest/FileMenu.html (New: "800 x 600 pixels", the clipboard image's size when the clipboard holds an image, "a single white layer"; Save writes the current file name and format, an "Untitled" image asks for a file name first; Close and Exit prompt when there are unsaved changes).
> Milestone: M0
> Depends on: 0004-zoom-pan-and-status-bar (and through it 0001, 0002, 0003)

## Context

Not yet implemented; there is no application code. This spec uses the types that earlier M0 specs create, with their exact names and signatures; don't add a parallel type:

- 0001: `PaintDotMac/Document/PaintDocument.swift` (`NSDocument` subclass that reads PNG/JPEG), `Document/DocumentWindowController.swift`, `App/AppDelegate.swift`, `App/MainMenu.swift` (main menu built in code), `App/LaunchOptions.swift` (`-UITestOpen`, `-ApplePersistenceIgnoreState`, `-UITestResetDefaults`), Info.plist document types for PNG and JPEG in `project.yml`, `PaintDotMacUITests/Support/UITestApp.swift`.
- 0002: `Core/Model/PixelSize.swift` (`PixelSize`, `PixelRect`, `PixelPoint`), `Core/Model/ColorRGBA8.swift`, `Core/Model/TiledSurface.swift` (256×256 sparse copy-on-write tiles), `Core/Model/Layer.swift` (id, name, isVisible, opacity `UInt8`, blendMode, surface), `Core/Model/BlendMode.swift` (`.normal`), `Core/Model/LayeredImage.swift` (size, dpi, layers, activeLayerIndex), `Core/Model/ImageLimits.swift` (APP-10: sides 1–65,535, w×h×4 overflow, injectable memory cap with `byteCount == memoryCapBytes` allowed; `validate(width:height:)` throws `ImageLimitError`), `Core/IO/ImageDecoder.swift` and `Core/IO/ImageCodecError.swift` (ImageIO → straight sRGB RGBA8, DPI, ICC conversion; the color under alpha-0 pixels of straight-alpha sources is preserved, FMT-B/D-33). `PaintDocument` holds its pixels as a `LayeredImage` (called `image` below).
- 0004: `UI/StatusBarModel.swift` / `UI/StatusBarView.swift` (accessibility `statusBar.imageSize`); `LaunchOptions.resettableKeyPrefixes` includes `settings.`.
- `PaintDotMacTests/Support/TestImages.swift` and `SeededRandom.swift` (0002).

What is missing after 0004: File > New does nothing useful, documents can't be written, and the saving rules of PRD §5.11 aren't applied. PRD §5.11 "Saving": "`autosavesInPlace` is off, so a JPEG is never silently re-encoded. Crash-recovery autosave (NF-5) writes `.ora` to the system autosave location. ⌘S writes the document in its own format … New documents default to `.ora`. Closing a document with unsaved changes asks whether to save." In M0 only PNG can be written. `.ora` arrives in 0028, JPEG/HEIC/TIFF/BMP/GIF writing in 0029, crash-recovery autosave in 0047, and history (the source of "edited" state) in 0008.

### Interim rules this spec defines (until later specs replace them)

1. **New documents are PNG.** `FileFormat.defaultNewDocumentFormat == .png`; 0028 changes it to `.ora`.
2. **JPEG-backed documents can't be saved in place yet.** ⌘S on a document opened from a JPEG behaves exactly like File > Save As…: the save panel opens, it offers only PNG, the suggested name is the original base name with `.png`, and the suggested folder is the JPEG's folder. The JPEG on disk is never touched. After a successful save, the document's `fileURL` and `fileType` are the new PNG, so a later ⌘S writes that PNG in place. 0029 completes this: it makes JPEG writable (with its quality dialog), so ⌘S then writes JPEG in place.
3. **Edited state (superseded by 0008).** History doesn't exist yet (0008), so nothing can change pixels in this spec. The **only** source of unsaved changes is File > New…: a document created through the New Image dialog is marked edited (`updateChangeCount(.changeDone)`) so the close and quit prompts are reachable and testable now. Opened PNG/JPEG documents are always clean in this spec. A successful save clears the edited state. **0008 supersedes this rule:** the edited state follows history, so an untouched new image (only the base "New Image" step) is clean and closes without a prompt (PRD APP-9, D-30). 0008 removes the `.changeDone` call and rewrites this spec's affected tests (`PaintDocumentSavingTests.newDocumentIsEditedUntilSaved`, `SaveUITests.closeNewImage*`, `.quitWithUnsavedNewImagePrompts`); the close-prompt UI tests that need a real edit move to 0009 (Paintbrush).
4. **No autosave at all until 0047.** `autosavesInPlace` returns `false` (permanent) and `autosavingFileType` returns `nil` (interim, so `NSDocument` never writes a PNG autosave; 0047 returns the `.ora` type there).
5. **Single-layer export.** Until 0024 a document always has exactly one layer, and the PNG writer encodes that layer's surface. If a document ever has a different number of layers, writing throws `ImageCodecError.encodingFailed` (alert, no crash). 0029's `SavePlan` replaces this with flatten-on-export through `CPUCompositor`.

## User story

As a PaintDotMac user, I can press ⌘N, confirm or change the width, height, and resolution in the New Image dialog (prefilled with my clipboard image's size), and get a white "Background" image. I can save any document as a PNG that keeps exact pixels (including transparency), its DPI, and an sRGB profile. ⌘S re-saves an opened PNG in place, an opened JPEG goes through Save As to PNG instead of being re-encoded, and closing or quitting with an unsaved new image asks me whether to save.

## Scope & changes

### Core (pure, unit-tested; no AppKit/SwiftUI imports)

- **`PaintDotMac/Core/IO/FileFormat.swift`** (new):
  ```swift
  public enum FileFormat: String, CaseIterable, Sendable {
      case png, jpeg            // 0028 adds .openRaster; 0029 adds heic, tiff, bmp, gif, webp
      public var utType: UTType                        // .png, .jpeg
      public var typeIdentifier: String { get }        // "public.png", "public.jpeg"
      public var preferredFilenameExtension: String    // "png", "jpg"
      public var displayName: String                   // "PNG", "JPEG"
      public var canRead: Bool                         // png true, jpeg true
      public var canWrite: Bool                        // png true, jpeg false (0029 → true)
      public init?(typeIdentifier: String)             // exact identifier or a UTType that conforms to one case's utType; otherwise nil
      public init?(fileExtension: String)              // case-insensitive: png → .png; jpg, jpeg, jpe → .jpeg; otherwise nil
      public static var writableFormats: [FileFormat]  // allCases.filter(\.canWrite), in declaration order → [.png]
      public static var defaultNewDocumentFormat: FileFormat { .png }   // 0028 → .openRaster
      public static func saveAction(for documentFormat: FileFormat?) -> SaveAction
      public static func suggestedFilename(original: String?, untitledName: String, format: FileFormat) -> String
  }
  public enum SaveAction: Equatable, Sendable {
      case writeInPlace(FileFormat)
      case saveAs(offering: [FileFormat], suggested: FileFormat)
  }
  ```
  - `saveAction(for:)`: `nil` (untitled) → `.saveAs(offering: writableFormats, suggested: defaultNewDocumentFormat)`; a format with `canWrite` → `.writeInPlace(format)`; a format without `canWrite` → `.saveAs(offering: writableFormats, suggested: defaultNewDocumentFormat)`.
  - `suggestedFilename`: replaces only the last extension of `original` with `format.preferredFilenameExtension` ("photo.jpg" → "photo.png", "archive.tar.jpg" → "archive.tar.png", "noext" → "noext.png", ".hidden" → ".hidden.png"); `original == nil` → `untitledName + "." + ext` ("Untitled.png").
- **`PaintDotMac/Core/IO/ImageEncoder.swift`** (new):
  ```swift
  public enum ImageEncoder {
      /// Encodes straight 8-bit sRGB RGBA pixels. Throws ImageCodecError.unsupportedWriteFormat(format) when !format.canWrite.
      public static func encode(_ surface: TiledSurface, size: PixelSize, dpi: Double, as format: FileFormat) throws(ImageCodecError) -> Data
      /// Document-level entry point; interim rule 5 (exactly one layer, else .encodingFailed).
      public static func encode(_ image: LayeredImage, as format: FileFormat) throws(ImageCodecError) -> Data
  }
  ```
  PNG implementation:
  - Copy the surface into one contiguous straight-RGBA8 buffer (absent sparse tiles → `(0,0,0,0)`), row by row, with `width × 4` bytes per row, computing sizes in `Int` after `ImageLimits` has accepted the size.
  - Wrap it in a `CGImage` through a `CGDataProvider` (no `CGContext`; a bitmap context would premultiply and lose straight-alpha precision): 8 bits per component, 32 bits per pixel, `CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)` with big-endian/default byte order (bytes R, G, B, A in memory), color space `CGColorSpace(name: CGColorSpace.sRGB)`. The sRGB color space makes ImageIO embed the sRGB profile (FMT-B "Saving always embeds an sRGB profile").
  - Write with `CGImageDestinationCreateWithData(…, UTType.png.identifier, 1, nil)` and add the image with properties `kCGImagePropertyDPIWidth`/`kCGImagePropertyDPIHeight = dpi`, and in `kCGImagePropertyPNGDictionary` `kCGImagePropertyPNGXPixelsPerMeter`/`kCGImagePropertyPNGYPixelsPerMeter = Int((dpi / 0.0254).rounded())` (96 DPI → 3780, 72 → 2835, 300 → 11811). `CGImageDestinationFinalize` returning false → `.encodingFailed`.
  - Never premultiply, never drop the color of fully transparent pixels, never convert to another color space.
- **`PaintDotMac/Core/IO/ImageCodecError.swift`** (0002's enum, extended): add `case unsupportedWriteFormat(FileFormat)` and `case encodingFailed`, with user-facing descriptions "PaintDotMac can't save images in the %@ format yet." (format `displayName`) and "The image couldn't be saved." Keep it `Equatable`.
- **Straight alpha end to end:** the round-trip tests below decode with 0002's `ImageDecoder`, which keeps straight values and preserves the color under alpha 0 for straight sources (FMT-B, D-33); the PNG written here is straight (`.last`), so the round trip is byte-exact. NF-9 requires straight storage. Don't loosen the tests.
- **`PaintDotMac/Core/Model/NewImageDefaults.swift`** (new). Holds the dialog's pure logic:
  ```swift
  public struct NewImageRequest: Equatable, Sendable {
      public var size: PixelSize
      public var dpi: Double
      /// One layer named "Background", visible, opacity 255, blend mode .normal, every pixel (255,255,255,255);
      /// activeLayerIndex 0; image.dpi = dpi.
      public func makeImage() -> LayeredImage
  }
  public enum NewImageDefaults {
      public static let fallbackSize = PixelSize(width: 800, height: 600)
      public static let fallbackDPI: Double = 96
      public static let backgroundLayerName = "Background"
      public static let dpiRange: ClosedRange<Double> = 1...10_000          // PRD APP-9, D-30; decimals allowed
      /// Clipboard size when each side is in 1...65_535, else fallbackSize. DPI is always fallbackDPI:
      /// the clipboard image's DPI is ignored (PRD APP-9, D-30).
      public static func initialRequest(clipboardImageSize: (width: Int, height: Int)?) -> NewImageRequest
      /// Reads only the image header through CGImageSource (no full decode). PNG data first, then TIFF;
      /// unreadable data → try the next; nothing readable → nil.
      public static func clipboardImageSize(pngData: Data?, tiffData: Data?) -> (width: Int, height: Int)?
  }
  public struct NewImageForm: Equatable, Sendable {
      public var widthText: String, heightText: String, resolutionText: String
      public init(request: NewImageRequest)        // "800", "600", "96"; DPI shown without a trailing ".0" ("96", "72.5")
      public func validate(limits: ImageLimits, locale: Locale = .current) -> Result<NewImageRequest, NewImageValidationError>
  }
  public enum NewImageValidationError: Error, Equatable, Sendable {
      case invalidWidth, invalidHeight, invalidResolution
      case tooLarge(width: Int, height: Int)       // ImageLimits refused the size (memory cap or w×h×4 overflow)
      public var message: String
  }
  ```
  Validation rules, applied in order width → height → resolution → limits, reporting the first failure:
  - Width and height: trim whitespace; the text must be ASCII digits only (no sign, no decimal point, no grouping separator) and the value must be in 1...65_535. Otherwise `.invalidWidth` / `.invalidHeight`.
  - Resolution: trim whitespace; accept digits with at most one decimal separator, which may be "." or the locale's decimal separator; parse to a finite `Double` in `dpiRange`. Otherwise `.invalidResolution`.
  - Limits: call 0002's `limits.validate(width:height:)` with the injected `limits`. Don't re-implement the rule. Any thrown `ImageLimitError` → `.tooLarge(width:height:)`.
  - Messages (exact): `.invalidWidth` "Width must be a whole number from 1 to 65,535 pixels."; `.invalidHeight` "Height must be a whole number from 1 to 65,535 pixels."; `.invalidResolution` "Resolution must be a number from 1 to 10,000 pixels/inch."; `.tooLarge` "The image is too large. An image of <w> × <h> pixels needs more memory than PaintDotMac allows." (the first sentence is 0002's `ImageCodecError` alert title for limit errors; `<w>`/`<h>` formatted like 0002's limit messages, an `en_US` decimal `NumberFormatter`, so 65535 is "65,535"; U+00D7).
  - `makeImage()` fills the surface with 0002's `TiledSurface.fill(.white)`, which shares one copy-on-write white tile across fully covered tiles (0002's `fillSharesInteriorTileStorage`).

### Platform glue (covered by UI tests and document-level tests)

- **`PaintDotMac/UI/NewImageDialog.swift`** (new): a SwiftUI view bound to a `NewImageForm`. Window title "New Image". Layout, top to bottom:
  - "Pixel size" group: "Width:" `[field]` "pixels", "Height:" `[field]` "pixels";
  - "Resolution:" `[field]` "pixels/inch";
  - buttons "Cancel" (Esc, `.cancelAction`) and "OK" (Return, `.defaultAction`).

  The width field has focus when the dialog opens, with its text selected. Accessibility identifiers: `newImageDialog` (the window), `newImage.width`, `newImage.height`, `newImage.resolution`, `newImage.ok`, `newImage.cancel`. The view holds no validation logic. On OK it calls `form.validate(limits:)` through a closure that the presenter supplies.
- **`PaintDotMac/Document/PaintDocumentController.swift`** (new; 0001 uses the plain `NSDocumentController`). The `NSDocumentController` subclass is instantiated in `AppDelegate.applicationWillFinishLaunching(_:)` before anything touches `NSDocumentController.shared`, so it becomes the shared controller. It overrides `newDocument(_:)`:
  1. Read `NSPasteboard.general`: the data for `.png` and `.tiff` → `NewImageDefaults.clipboardImageSize` → `initialRequest`. File URLs are not considered.
  2. Present `NewImageDialog` in an app-modal `NSPanel` (`NSHostingController`, `NSApp.runModal(for:)`), so it also works with no document open.
  3. On OK, `validate(limits: <app's ImageLimits>)`. On failure, show an `NSAlert` (message = `error.message`, button "OK") and keep the dialog open with the typed values unchanged. On success, stop the modal session.
  4. Create the document with `makeUntitledDocument(ofType: FileFormat.defaultNewDocumentFormat.typeIdentifier)`, set its `image = request.makeImage()`, `addDocument`, `makeWindowControllers()`, `showWindows()`, then `updateChangeCount(.changeDone)` (interim rule 3).
  5. On Cancel, nothing happens and no document is created.
- **No untitled document at launch:** 0001's `applicationShouldOpenUntitledFile(_:)` returns `false` permanently, and this spec keeps it; an empty launch still shows only the menu bar, and new images come only from File > New… (⌘N). `PaintDocument.init(type:)` (reached through `makeUntitledDocument(ofType:)` in step 4) starts with 0002's placeholder image, which step 4 replaces before any window is made.
- **`PaintDotMac/Document/PaintDocument.swift`** (extend):
  - `override class var autosavesInPlace: Bool { false }` (permanent, PRD §5.11; already set by 0001).
  - Remove 0001's `validateUserInterfaceItem(_:)` override that disabled Save/Save As/Save To/Revert/Duplicate, so `NSDocument`'s standard validation applies. Replace 0001's `PaintDocumentTests.saveActionsAreDisabled` with `saveActionsAreEnabled` (below).
  - `override var autosavingFileType: String? { nil }` (interim rule 4).
  - `override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String]` returns `FileFormat.writableFormats.map(\.typeIdentifier)` for every operation.
  - `override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String?` returns `FileFormat(typeIdentifier:)?.preferredFilenameExtension`, falling back to `super`.
  - `override func data(ofType typeName: String) throws -> Data`: `FileFormat(typeIdentifier:)` (an unknown identifier throws `ImageCodecError.encodingFailed`), then `ImageEncoder.encode(image, as:)`. Errors propagate so `NSDocument` shows its standard error alert. The document stays open and keeps its edited state.
  - `override func saveDocument(_ sender: Any?)`: switch on `FileFormat.saveAction(for: FileFormat(typeIdentifier: fileType ?? ""))` when `fileURL != nil`. `.writeInPlace` → `super.saveDocument(sender)`; `.saveAs` → `saveAs(sender)`. Untitled documents go through `super`, which already runs the save panel.
  - `override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool`: `allowedContentTypes = FileFormat.writableFormats.map(\.utType)`, `nameFieldStringValue = FileFormat.suggestedFilename(original: fileURL?.lastPathComponent, untitledName: displayName, format: .png)`, and `directoryURL = fileURL?.deletingLastPathComponent()` when there is a file URL. `NSDocument` keeps its default behavior for the format accessory, which now lists only PNG. Returns `true`.
  - The Save As save type is PNG (`fileTypeFromLastRunSavePanel` = "public.png"). After any successful save `NSDocument` updates `fileURL`/`fileType` and clears the edited state.
  - Close and quit prompts are `NSDocument`'s standard ones ("Do you want to save the changes made to the document “Untitled”?" with Save… / Don't Save / Cancel). Don't add custom code.
- **`PaintDotMac/App/MainMenu.swift`** (extend 0001's File menu). The items must be exactly:
  - "New…" ⌘N → `newDocument(_:)`;
  - "Open…" ⌘O (0001);
  - "Close" ⌘W → `performClose(_:)`;
  - "Save" ⌘S → `saveDocument(_:)`;
  - "Save As…" ⇧⌘S → `saveDocumentAs(_:)`.

  0001 already has these items with these shortcuts; this spec gives 0001's placeholder "New…" its `newDocument(_:)` action and adds accessibility identifiers `menu.file.new`, `menu.file.save`, `menu.file.saveAs`. Update 0001's tests: `MainMenuTests.placeholdersHaveNoAction` now lists only Settings…; `MainMenuTests.fileMenuItems` expects New… → `newDocument(_:)`; `LaunchUITests.testMenuBarAndPlaceholderEnablement` expects New…, Save, and Save As… enabled with a document open, and replaces its "press ⌘S and ⌘N: no sheet" step with "press ⌘N, then Escape: the New Image dialog appears and closes, `documentWindows.count == 1`".
- **`project.yml`**: in the Info.plist `CFBundleDocumentTypes`, the PNG type is listed **first** with `CFBundleTypeRole = Editor`, so `NSDocumentController.defaultType` is `public.png`. JPEG also becomes `Editor` (0001 declared both as `Viewer`; writability is decided by `writableTypes(for:)`, and 0029 enables it). Both use `NSDocumentClass = $(PRODUCT_MODULE_NAME).PaintDocument`. **Update 0001's `SmokeTests.documentTypesMapPNGAndJPEGToPaintDocument`** (in `PaintDotMacTests/SmokeTests.swift`): it now expects `CFBundleTypeRole == "Editor"` for both entries, PNG first, `LSHandlerRank == "Alternate"` unchanged (0028 later renames it to `SmokeTests.documentTypes`). Add the new files and run `xcodegen generate`.
- **`PaintDotMacUITests/Support/UITestApp.swift`** (extend). Add these helpers:
  - `setPasteboardImage(width:height:)`, which writes a generated PNG with `NSPasteboard.general` from the runner;
  - `clearPasteboard()`;
  - `saveThroughPanel(directory:name:)`, which works in the save sheet: select the name field (`textFields["saveAsNameTextField"]`), type the name, press ⇧⌘G, type the directory, press Return, then click "Save";
  - `decodePNG(at:)`, which uses ImageIO in the runner to return the size, straight RGBA bytes, DPI, and profile name.
- PRD: no change. Every rule here is already in PRD §5.11 / APP-9 / APP-10; the interim rules are sequencing only.

## Acceptance criteria

- [ ] File > New… (⌘N) opens the "New Image" dialog prefilled with 800 / 600 / 96 when the clipboard holds no image → `NewImageDefaultsTests.fallbackWhenNoClipboard`, `NewImageUITests.newImageDefaultsWithoutClipboard`.
- [ ] With an image on the clipboard, Width and Height are prefilled with its pixel size (PNG preferred over TIFF) and Resolution is 96 → `NewImageDefaultsTests.clipboardSizeUsed`, `.pngPreferredOverTIFF`, `.tiffUsedWhenPNGUnreadable`, `NewImageUITests.newImageUsesClipboardSize`.
- [ ] OK creates an untitled document with one visible layer "Background", opacity 255, Normal, every pixel opaque white, the chosen size and DPI. The status bar shows the size → `NewImageRequestTests.makeImageProducesWhiteBackground`, `NewImageUITests.newImageDefaultsWithoutClipboard`.
- [ ] Cancel creates nothing → `NewImageUITests.newImageCancelCreatesNothing`.
- [ ] Invalid width/height/resolution and sizes refused by `ImageLimits` show an alert, keep the dialog open with the typed values, and never crash → `NewImageFormTests.*`, `NewImageUITests.newImageRejectsInvalidWidth`.
- [ ] PNG save writes straight-alpha RGBA that decodes byte-exact (including semi-transparent pixels and the color of fully transparent pixels) → `ImageEncoderTests.pngRoundTripIsByteExact`, `.allAlphaValuesRoundTrip`, `ImageEncoderPropertyTests.randomImagesRoundTrip`.
- [ ] Saved PNGs embed an sRGB profile and the document DPI (pHYs, pixels per meter) → `ImageEncoderTests.embedsSRGBProfile`, `.writesPHYsForDPI`, `PaintDocumentSavingTests.displayP3InputSavesAsSRGB`.
- [ ] `autosavesInPlace` is false, and no autosave is written before 0047 → `PaintDocumentSavingTests.autosaveSettings`.
- [ ] ⌘S on an opened PNG writes PNG in place without a panel, and the pixels and DPI are preserved → `PaintDocumentSavingTests.saveInPlaceRewritesPNG`, `SaveUITests.reSaveOpenedPNG`.
- [ ] ⌘S on an opened JPEG opens Save As offering only PNG, named `<base>.png`. The JPEG file is unchanged. Afterwards the document is the PNG and ⌘S writes in place → `FileFormatTests.saveActionForJPEGIsSaveAs`, `FileFormatTests.suggestedFilename*`, `SaveUITests.jpegSaveGoesThroughSaveAsPNG`.
- [ ] Closing (⌘W) or quitting (⌘Q) with an unsaved new image asks whether to save. Don't Save closes, Cancel keeps it open, and Save… saves a PNG → `SaveUITests.closeNewImageDontSave`, `.closeNewImageCancel`, `.closeNewImageSave`, `.quitWithUnsavedNewImagePrompts`.
- [ ] Opened, unmodified documents close without a prompt → `SaveUITests.openedPNGClosesWithoutPrompt`.
- [ ] Write failures (unsupported type, unwritable folder) show an error and leave the document open → `PaintDocumentSavingTests.dataOfTypeJPEGThrows`, `.writeToReadOnlyDirectoryFails`, manual step 4.
- [ ] File menu items and shortcuts are exactly as listed → `SaveUITests.fileMenuItems`.
- [ ] M0 exit: open a fixture PNG, view it, and re-save it with identical decoded pixels → `SaveUITests.reSaveOpenedPNG`.
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report. → quality-gate launch smoke.
- [ ] An empty launch still opens no untitled document. → 0001's `LaunchUITests.testEmptyLaunchShowsMenuBarOnly` (unchanged), `AppDelegateTests.noUntitledDocumentAndNoTerminateOnLastClose`.
- [ ] Save and Save As… are enabled for an open document (0001's disabling override is gone). → `PaintDocumentSavingTests.saveActionsAreEnabled`, `LaunchUITests.testMenuBarAndPlaceholderEnablement`.

- [ ] PNG and JPEG document types map to `PaintDocument` with the Editor role, PNG listed first; 0001's smoke test is updated accordingly. → `SmokeTests.documentTypesMapPNGAndJPEGToPaintDocument`.

## Edge cases

- **Sizes:** 1×1 new image; 65,535×1 (valid, 262 KB); 65,536 on either side (invalid width/height alert); 65,535×65,535 (≈17.2 GB, refused by the memory cap with the too-large alert, never an allocation attempt). Sizes crossing 256-pixel tile boundaries (257×257) are filled completely, with no unfilled edge tiles.
- **Text input:** empty, whitespace, "-5", "12.5" for width, "1,024", "abc", "nan", "inf", "1e3" → the matching invalid alert. A resolution of "72,5" is accepted only when the locale's decimal separator is ",".
- **Clipboard:** no image; non-image data (text); corrupt PNG bytes with a valid TIFF (the TIFF size is used); both corrupt (fallback); an image larger than 65,535 on a side (fallback 800×600); a huge clipboard image (only the header is read, never decoded).
- **Transparency:** alpha 0 with non-zero RGB, alpha 1, alpha 254 must round-trip exactly; sparse (untouched) tiles encode as (0,0,0,0).
- **DPI:** 96 → pHYs 3780 ppm; 72 → 2835; 300 → 11811; 72.5 → 2854. Decoding a PNG without pHYs gives 96 (0002). Re-saving a 300 DPI PNG keeps 300 (±0.05 after ppm rounding).
- **Color profile:** a Display P3 PNG is converted to sRGB on open (0002) and saved with an sRGB profile, never P3.
- **Save As cancelled** (from ⌘S on a JPEG or from the close prompt's Save…): nothing is written, the document keeps its URL, type, and edited state, and the close is aborted.
- **Saving over an existing file:** the standard `NSSavePanel` replace confirmation; `NSDocument` safe-saves (temp file, then replace), so a failure never leaves a truncated target.
- **Unwritable folder / disk full:** `NSDocument`'s standard error alert, the document stays open and edited, and no partial file is left.
- **Layer count ≠ 1** (impossible before 0024): `ImageCodecError.encodingFailed` alert, no crash.
- **File deleted underneath an opened PNG, then ⌘S:** `NSDocument` writes a new file at the URL (standard behavior), with no crash.
- **The New dialog with no document window open** works (app-modal), and so does opening it while another document window is key.
- **Quit with several unsaved new images:** `NSDocumentController`'s standard review-changes flow.
- **Performance:** PNG encoding runs synchronously in `data(ofType:)` on the main actor. This is acceptable in M0 and not covered by an NF target. 0048 revisits asynchronous writing.

## Test plan

Expected values come from the PRD, the PNG specification (pHYs unit 1 = metre; ppm = round(dpi / 0.0254)), or hand-built fixtures, never from running the code under test.

- **Unit tests**
  - `PaintDotMacTests/IO/FileFormatTests.swift`:
    - `typeIdentifiers`: `.png.typeIdentifier == "public.png"` and `.jpeg.typeIdentifier == "public.jpeg"`. `FileFormat(typeIdentifier:)` maps "public.png" → `.png`, "public.jpeg" → `.jpeg`, "public.tiff" → nil, "com.example.unknown" → nil.
    - `fileExtensions`: "png", "PNG" → `.png`; "jpg", "jpeg", "JPG", "jpe" → `.jpeg`; "gif", "" → nil.
    - `capabilities`: both formats `canRead`; `.png.canWrite == true`, `.jpeg.canWrite == false`; `writableFormats == [.png]`; `defaultNewDocumentFormat == .png`; `preferredFilenameExtension` "png"/"jpg".
    - `saveActionUntitled`: `saveAction(for: nil) == .saveAs(offering: [.png], suggested: .png)`.
    - `saveActionForPNGWritesInPlace`: `== .writeInPlace(.png)`.
    - `saveActionForJPEGIsSaveAs`: `== .saveAs(offering: [.png], suggested: .png)`.
    - `suggestedFilenameReplacesExtension`: "photo.jpg" → "photo.png", "archive.tar.jpg" → "archive.tar.png", "noext" → "noext.png", ".hidden" → ".hidden.png".
    - `suggestedFilenameUntitled`: (nil, "Untitled") → "Untitled.png".
  - `PaintDotMacTests/Model/NewImageDefaultsTests.swift`:
    - `fallbackWhenNoClipboard`: `initialRequest(clipboardImageSize: nil) == NewImageRequest(size: 800×600, dpi: 96)`.
    - `clipboardSizeUsed`: (123, 45) → 123×45 @96.
    - `clipboardSizeBounds`: (1,1) and (65_535, 1) kept; (65_536, 10), (0, 10), (10, -1) → 800×600.
    - `clipboardImageSizeReadsPNG`: a 123×45 PNG made with `TestImages` → (123, 45).
    - `pngPreferredOverTIFF`: PNG 10×10 + TIFF 20×20 → (10, 10).
    - `tiffUsedWhenPNGUnreadable`: garbage PNG bytes + TIFF 20×20 → (20, 20).
    - `nothingReadable`: (nil, nil) → nil; garbage + garbage → nil; UTF-8 text bytes → nil.
    - `formInitialText`: `NewImageForm(request: 800×600 @96)` → "800", "600", "96"; @72.5 → "72.5".
  - `PaintDotMacTests/Model/NewImageFormTests.swift` (injected `ImageLimits` with a memory cap of 1_000_000 bytes, plus the default limits where stated):
    - `validDefaults`: "800","600","96" → `.success(800×600 @96)`; " 800 " trimmed → success.
    - `widthInvalid`: each of "", "0", "65536", "-5", "12.5", "abc", "1,024", "1e3" → `.failure(.invalidWidth)`.
    - `heightInvalid`: same inputs in the height field → `.invalidHeight`.
    - `widthCheckedBeforeHeight`: width "0", height "0" → `.invalidWidth`.
    - `resolutionValid`: "1", "72", "300.5", "10000" accepted with those values.
    - `resolutionInvalid`: "0", "0.5", "10000.01", "abc", "", "nan", "inf" → `.invalidResolution`.
    - `resolutionLocaleSeparator`: "72,5" with `Locale(identifier: "de_DE")` → 72.5; with `en_US` → `.invalidResolution`.
    - `memoryCap`: "500","500" (exactly 1_000_000 bytes; 0002's cap is inclusive) → success; "501","500" → `.tooLarge(width: 501, height: 500)`.
    - `extremeSideAccepted`: "65535","1" with the default limits → success.
    - `messagesExact`: each `message` equals the strings in Scope; `.tooLarge(width: 65535, height: 65535).message == "The image is too large. An image of 65,535 × 65,535 pixels needs more memory than PaintDotMac allows."`.
  - `PaintDotMacTests/Model/NewImageRequestTests.swift`:
    - `makeImageProducesWhiteBackground` (800×600 @96): `layers.count == 1`; the layer has name "Background", `isVisible`, opacity 255, blend mode `.normal`; `activeLayerIndex == 0`; image size 800×600 and dpi 96; **every** pixel == (255,255,255,255) (full scan).
    - `makeImageTileEdges`: 1×1, 257×257, and 65_535×1 are each white at every pixel (full scan).
  - `PaintDotMacTests/IO/ImageEncoderTests.swift`:
    - `pngSignature`: the first 8 bytes are `89 50 4E 47 0D 0A 1A 0A`.
    - `pngRoundTripIsByteExact`: a hand-built 300×200 surface (crossing the 256 tile boundary) with pixels (x % 256, y % 256, (x+y) % 256, (x*7+y) % 256) → encode → `ImageDecoder` → same size and identical bytes at every pixel.
    - `allAlphaValuesRoundTrip`: a 256×256 surface where pixel (x, y) = (y, 255 − y, (x*3) % 256, x), so every alpha 0…255 occurs with many colors, including alpha 0 with non-zero RGB → byte-exact.
    - `straightAlphaNotPremultiplied`: a 1×1 (200, 100, 50, 1) → decodes to exactly (200, 100, 50, 1).
    - `sparseSurfaceEncodesTransparent`: an untouched 300×300 surface → all (0,0,0,0).
    - `onePixel`: a 1×1 opaque red round-trips.
    - `embedsSRGBProfile`: a test-side PNG chunk walker (`PaintDotMacTests/Support/PNGChunks.swift`: signature check, then length/type/data/CRC records) finds an `iCCP` or `sRGB` chunk, and `CGImageSourceCopyPropertiesAtIndex` reports a `kCGImagePropertyProfileName` containing "sRGB".
    - `writesPHYsForDPI`: dpi 96 / 72 / 300 / 72.5 → a pHYs chunk with unit byte 1 and x == y == 3780 / 2835 / 11811 / 2854, each ±1 ppm (ImageIO may round differently); decoding through `ImageDecoder` gives a dpi within 0.05 of the input.
    - `unsupportedWriteFormat`: `encode(…, as: .jpeg)` throws `.unsupportedWriteFormat(.jpeg)`.
    - `multiLayerRefused`: a `LayeredImage` with two layers (built directly) → `.encodingFailed`; with zero layers → `.encodingFailed`.
- **Round-trip and property tests** (`PaintDotMacTests/IO/ImageEncoderPropertyTests.swift`): `randomImagesRoundTrip` over 25 seeds from `SeededRandom` (the seed is printed on failure): random size 1…600 per side, random RGBA bytes with 20% of pixels forced to alpha 0 (random RGB) and 20% to alpha 255, random dpi in 1…1000 → encode → decode → identical pixels, identical size, dpi within 0.05.
- **Golden-image tests:** none. No rendering or blending changes; the codec is checked byte-exact against hand-built inputs.
- **Integration tests**
  - `PaintDotMacTests/Integration/NewImageSaveIntegrationTests.swift` (headless Core): `newImageRoundTrip`: `NewImageForm("640","480","300").validate` → `makeImage` → `ImageEncoder.encode(image, as: .png)` → `ImageDecoder` → 640×480, one layer, all pixels (255,255,255,255), dpi within 0.05 of 300.
  - `PaintDotMacTests/Document/PaintDocumentSavingTests.swift` (`@MainActor`, app-hosted; documents are created in code and never shown):
    - `autosaveSettings`: `PaintDocument.autosavesInPlace == false`; `doc.autosavingFileType == nil`.
    - `saveActionsAreEnabled`: for a PNG-read document, `validateUserInterfaceItem` returns true for `NSMenuItem`s with `saveDocument:` and `saveDocumentAs:` (replaces 0001's `saveActionsAreDisabled`).
    - `writableTypesArePNGOnly`: for a PNG-read and a JPEG-read document, `writableTypes(for:)` == ["public.png"] for `.saveOperation`, `.saveAsOperation`, and `.saveToOperation`.
    - `fileNameExtension`: "public.png" → "png".
    - `dataOfTypePNGRoundTrips`: a document read from a fixture PNG (`TestImages`, 300 DPI, semi-transparent pixels) → `data(ofType: "public.png")` → decodes to identical pixels, with pHYs 11811 ±1.
    - `dataOfTypeJPEGThrows`: throws `ImageCodecError.unsupportedWriteFormat(.jpeg)`.
    - `displayP3InputSavesAsSRGB`: open a Display P3 tagged PNG fixture generated in the test → saved data's profile name contains "sRGB" and not "P3".
    - `saveInPlaceRewritesPNG`: read a temp-dir PNG fixture, `save(to: fileURL, ofType: "public.png", for: .saveOperation)` (await completion) → no error; decoded file pixels equal the fixture; `isDocumentEdited == false`.
    - `newDocumentIsEditedUntilSaved`: a document from `NewImageRequest` with `.changeDone` applied as the controller does → `isDocumentEdited == true`; after `save(to:ofType:for: .saveAsOperation)` to a temp URL → false, `fileURL` == that URL, `fileType == "public.png"`.
    - `jpegDocumentSaveActionIsSaveAs`: a JPEG-read document → `FileFormat.saveAction(for: FileFormat(typeIdentifier: doc.fileType!))` is `.saveAs` (the menu glue itself is covered by the UI test).
    - `writeToReadOnlyDirectoryFails`: save to a URL inside a temp directory with permissions 0o555 → the completion reports an error; no file exists at the URL; the document's `fileURL` is unchanged.
- **UI tests** (`PaintDotMacUITests/NewImageUITests.swift`, `PaintDotMacUITests/SaveUITests.swift`; fixtures are generated at test time in a temp dir via `UITestApp`):
  - `newImageDefaultsWithoutClipboard`: `clearPasteboard()`, launch, ⌘N → `newImageDialog` exists; field values "800", "600", "96"; press Return → a new document window with `canvas`, title "Untitled", and `statusBar.imageSize` equal to 0004's formatting of 800×600.
  - `newImageUsesClipboardSize`: `setPasteboardImage(width: 123, height: 45)`, ⌘N → "123", "45", "96"; click `newImage.ok` → `statusBar.imageSize` shows 123×45.
  - `newImageCancelCreatesNothing`: count windows, ⌘N, click `newImage.cancel` (and, in a second pass, press Esc) → dialog gone and window count unchanged.
  - `newImageRejectsInvalidWidth`: ⌘N, type "65536" into `newImage.width`, OK → an alert whose text is the `.invalidWidth` message; click OK → `newImageDialog` is still shown and the width field still reads "65536"; fix it to "64", OK → a document 64×600.
  - `fileMenuItems`: the File menu contains "New…", "Open…", "Close", "Save", and "Save As…", in that order among the visible items, all enabled with a document open. (Key equivalents ⌘N, ⌘O, ⌘W, ⌘S, ⇧⌘S and actions are asserted exactly in the unit test `MainMenuTests.fileMenuItems`.)
  - `closeNewImageDontSave`: ⌘N, Return, ⌘W → a sheet with "Don't Save"; click it → the window is gone, and no file is written into the test temp dir.
  - `closeNewImageCancel`: ⌘N, Return, ⌘W → sheet → "Cancel" → the window is still open.
  - `closeNewImageSave`: ⌘N, Return, ⌘W → sheet → "Save…" → `saveThroughPanel(directory: tmp, name: "new.png")` → the window closes; `decodePNG(tmp/new.png)` gives 800×600, all sampled pixels (corners, center, (255,255), (256,256)) == (255,255,255,255), DPI within 0.05 of 96, and a profile name containing "sRGB".
  - `quitWithUnsavedNewImagePrompts`: ⌘N, Return, ⌘Q → a save prompt appears; "Cancel" → the app is still running (`app.state == .runningForeground`) with the document window open.
  - `openedPNGClosesWithoutPrompt`: launch with `-UITestOpen <fixture.png>`, ⌘W → the window closes with no sheet.
  - `reSaveOpenedPNG` (M0 exit): the fixture is a 300×200 PNG with semi-transparent and alpha-0 pixels at 300 DPI, copied to temp. Record its decoded pixels. Launch with `-UITestOpen`, ⌘S → no sheet appears within 2 s, and the file's modification date advances. Decode → pixels identical to the recorded ones, DPI within 0.05 of 300, profile "sRGB".
  - `jpegSaveGoesThroughSaveAsPNG`: fixture `photo.jpg` in temp; record its bytes. Launch with `-UITestOpen`, ⌘S → a save sheet appears whose name field reads "photo.png"; save into the same temp dir → `photo.png` exists and decodes to the JPEG's pixel size; `photo.jpg`'s bytes are unchanged; the window title is "photo.png". ⌘S again → no sheet, and `photo.png`'s modification date advances.
- **Performance:** not applicable. This spec touches no NF-1–NF-4 path; save time is revisited in 0048.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: a clean build with no warnings, every test passes with none skipped, the UI tests ran, and the launch smoke passes.
- **Manual verification**
  1. Light and dark mode: the New Image dialog's labels ("Width:", "Height:", "pixels", "Resolution:", "pixels/inch") line up; Tab moves Width → Height → Resolution → buttons; Return = OK, Esc = Cancel.
  2. Copy a region with ⌃⇧⌘4, then press ⌘N in PaintDotMac → the dialog shows the screenshot's pixel size.
  3. Save a new image and a re-saved semi-transparent PNG, open both in Preview → colors look the same as in PaintDotMac, transparency is intact, and Preview's Inspector shows 96 (or the source) DPI and the sRGB IEC61966-2.1 profile.
  4. Save As into a read-only folder (for example `/System` or a folder with write permission removed in Finder) → a standard "couldn't be saved" alert appears, and the document stays open and edited.
  5. Open a JPEG, press ⌘S, and cancel the panel → the window title is still the JPEG, and the JPEG's modification date in Finder is unchanged.

## Out of scope

- `.ora` saving/opening and "new documents default to `.ora`" → 0028 (it flips `defaultNewDocumentFormat`).
- JPEG/HEIC/TIFF/BMP/GIF writing, the JPEG quality dialog, the FMT-A flatten confirmation, `SavePlan`, and making ⌘S write JPEG in place → 0029.
- Crash-recovery autosave (`autosavingFileType` → `.ora`) → 0047.
- History, the "New Image"/"Open Image" base step, and history-driven edited state → 0008.
- Flatten-on-export through `CPUCompositor` for multi-layer documents → 0012/0024/0029.
- Paste into New Image and clipboard image decoding → 0021 (it may reuse `NewImageDefaults.clipboardImageSize` or replace it with `ClipboardImageCodec`).
- Print size and units in the New dialog, "Maintain aspect ratio", and the memory-size estimate (Paint.NET extras that APP-9 doesn't require).
- Asynchronous/background saving and save progress → 0048 if needed.
- Settings for defaults (APP-8) → 0046.
