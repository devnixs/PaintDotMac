# 0051 — Prove the five key use cases end to end and gate v1.0 on P0 test coverage

> Source: PRD.md §3 *Key use cases* 1–5; §8 M7 exit criterion "All P0 requirements met" (and the M2/M4/M5 exit criteria that name use cases 1–3); §9 *Success criteria* ("All five key use cases (§3) can be done without leaving the app"); §4 *Testing* (launch hooks); §5 requirement tables (every P0 ID); §6 NF-1…NF-9; §12 D-3, D-11, D-12, D-13, D-16, D-17, D-18, D-29, D-34, D-37, D-40. AGENTS.md *Testing expectations*, *Architecture rules* 1–2.
> Milestone: M7 (Polish, v1.0) — the last v1.0 spec.
> Depends on: 0050-app-icon-and-bundle-size (and through the chain every spec 0001–0049; the use cases touch 0004, 0005, 0006, 0007, 0010, 0011, 0013, 0014, 0018, 0020, 0021, 0022, 0024–0030, 0031–0035, 0037–0040, 0042, 0045, 0047).

## Context

Every earlier spec tests its own feature. Nothing yet proves that the five §3 use cases work as one uninterrupted session through the real UI, and nothing proves that every P0 requirement is covered by at least one test. That is what M7's exit criterion ("All P0 requirements met") and §9 require. This spec adds no product behavior. It adds:

1. five end-to-end XCUITests, one per use case. Each drives only real UI (menus, key shortcuts, Tools/History/Layers/Colors panels, tool options bar, dialogs, save/open panels, canvas drags) and checks **exact pixels**, computed independently in the test target, on the exported file or the clipboard;
2. a headless **P0 coverage** test that parses `PRD.md`, collects every P0 requirement key, and fails if any key isn't mapped to at least one existing test function;
3. the few harness helpers and one `#if DEBUG` launch hook the tests need to be deterministic.

What exists (exact names from earlier specs; checked against 0001–0050):

- **Harness** `PaintDotMacUITests/Support/UITestApp.swift`: 0001 (`app`, `fixtureDirectory`, `makePNG(named:width:height:rgba:)`, `launch(opening:resetDefaults:extraArguments:)` + 0047's `ignoresPersistentState: Bool = true` (0049 adds `appearance:`/`keyboardUIMode:` parameters, unused here), `documentWindows`, `canvas`, `menuItem(_:_:)`, `chooseMenuItem(_:_:)`, `dragOnCanvas(from:to:holdDuration:)`, `waitForDocumentWindowCount(_:timeout:)`, `tearDown()`, 10 s waits, never `XCTSkip`); 0006 (`isToolSelected(_:)`, `panel(_:)`, `statusValue(_:)`); 0007 (`openColorsPanel()`); 0005/0021 (`setPasteboardImage(width:height:pixel:asTIFFOnly:)` — 0005's `(width:height:)` extended by 0021 with `pixel:` and `asTIFFOnly:`, `clearPasteboard()`, `pasteboardPNG()`, `pasteboardTypes()`); 0028/0029 (`saveThroughPanel(directory:name:format:)` — 0028 added `format:` to 0005's `(directory:name:)`, `selectSaveFormat(_:)`, `decodeImage(at:)` → width, height, straight RGBA, dpi, profileName, typeIdentifier, frameCount); 0030 (`openThroughPanel(file:)` for the **import** sheet, `openAllThroughPanel(directory:)`); 0041 (`chooseMenuItem(_ menu:, _ submenu:, _ item:)`).
- **Fixtures** `PaintDotMacUITests/Support/UITestFixtures.swift` (0002: `writePNG(width:height:pixel:properties:)` with a per-pixel closure; 0028: `writeOpenRaster`).
- **Launch hooks** in `PaintDotMac/App/LaunchOptions.swift` (`#if DEBUG`): `-UITestOpen`, `-ApplePersistenceIgnoreState`, `-UITestResetDefaults` (prefixes `tool.`, `panel.`, `NSWindow Frame panel.`, `colors.`, `settings.`), `-UITestSelectRect`, `-UITestReduceMotion` (0013/0049), `-UITestDiscardSavedState`, `-UITestAutosaveDelay` (0047), `-UITestEffectSeed` (0043), `-UITestMemoryCapBytes` (0002), `-UITestUndoLimitPreset` (0046), `-PerfFrameProbe` (0048), `-UITestIncreaseContrast`, `-UITestReduceTransparency`, `-UITestAppearance`, `-UITestDumpAccessibilityCatalog` (0049). None of them fixes the document window size, so `-UITestWindowContentSize` is new (no duplicate). **The use-case tests use only `-UITestOpen`, `-UITestResetDefaults`, `-ApplePersistenceIgnoreState`, `-UITestReduceMotion YES`, `-UITestDiscardSavedState YES`, and the new `-UITestWindowContentSize`.** They don't use `-UITestSelectRect` or any other hook that replaces a user action.
- **Window sizing**: `DocumentWindowController.initialContentSize(imageSize:visibleFrameSize:)` (0001) sizes the window from the image (minimum 480×360 pt). A new window opens in the Zoom to Window state; ⌘0 is Actual Size, and 100% is one image pixel per device pixel (0004, D-29). The canvas is centered when the image is smaller than the view.
- **Accessibility identifiers** used here: `canvas`, `documentWindow`, `tool.<id>`, `toolOptions.width`, `.endCap`, `.drawMode`, `.blendMode`, `.antialiasing`, `.fontSize`, `.finish` (0038–0040), `colors.hex` (0007), `historyList`, `historyRow.<i>` (label = step name, value `current`/`done`/`undone`; 0010), `layerRow.<i>` (0 = bottom; label = name; 0025), `layerProperties.blendMode`, `.opacityField`, `.ok` (0025), `statusBar.cursor` ("x, y" or ""), `statusBar.selectionSize` ("W × H"), `statusBar.imageSize` ("W × H"), `statusBar.zoom` ("100%") (0004/0014), `effectDialog`, `effectDialog.ok`, `effectDialog.progress` ("idle"), `effectDialog.levels.inputWhite` (0033), `effectDialog.curve.mode`, `.curve.plot`, `.curve.coordinates` (0034), `effectDialog.hue.field`, `.saturation.field` (0032), `effectDialog.amount.field` (0042), `resizeImageDialog`, `resizeImage.percentage`, `.resampling`, `.ok` (0035), `jpegOptionsDialog`, `jpegOptions.qualityField`, `.fileSize`, `.ok` (0029), `savePanel.format` (0029).
- **Normative pixel math** the oracles transcribe (cited, never derived by running app code): `mul255(a,b) = (a·b + 127) / 255` (0009); the exact-rounding composition `G` plus the per-channel `F` for Multiply and Screen (0026 *Context*, 0027 table); Normal = `G` with `F(A,B) = B` (0009/0026); Invert Colors `(255−R, 255−G, 255−B, A)` (0031); Levels `Level.Apply` (0033 item "apply"); the Curves table entries asserted by 0034's tests for the spline through (0,0), (128,192), (255,255): 0→0, 128→192, 192→235, 200→238, 255→255; Hue / Saturation's integer-exact formula (0032 item 7); Sharpen's disk median with the 3.36 `+1` quirk and `n = 3c − m; out = n < 0 ? 0 : min(255, n/2)` (0042 *Context*); Erase Selection → `(0,0,0,0)` (0018); Pencil = exact Bresenham, no antialiasing, pixel = `floor` of the canvas point (0011); Rectangle Select from pixel a to pixel b inclusive (0014); Flip/Rotate pixel maps (0037); Crop to Selection to the selection's bounds (0022); Paste into New Image = white "Background" plus the clipboard pixels Normal-composited (0021 Open questions 3–4, recommended answers); ORA opacity `round(x/255, 3)` ↔ `round(f·255)` (D-18).

PRD §3 use cases (quoted):
1. Open a screenshot, crop it, add arrows, text, and highlight rectangles, then export a PNG.
2. Open a photo, adjust levels, curves, and hue/saturation, sharpen, resize, and export a JPEG at a chosen quality.
3. Build a simple composite from several images on separate layers, using blend modes and opacity.
4. Paste from the clipboard into a new image, edit it, and copy the result back to the clipboard.
5. Undo any number of steps, or jump back to any earlier state from the History panel.

## User story

As the author shipping v1.0, I run the quality gate and it fails if any of the five everyday workflows breaks anywhere along the chain, or if a P0 requirement in `PRD.md` has no test proving it. Green means v1.0 is done.

## Scope & changes

All new code is test code or `#if DEBUG` launch-hook glue. **No `Core` change and no product behavior change.**

### 1. Launch hook: fixed window size (platform glue, `#if DEBUG`)

- **`PaintDotMac/App/LaunchOptions.swift`** (extend): `-UITestWindowContentSize <W>x<H>` → `windowContentSizeOverride: CGSize?`. A value matching `^[0-9]{3,5}x[0-9]{3,5}$` with both sides in 320…10000 is kept; anything else (missing value, `0x0`, `abcx100`, `1000×700` with U+00D7, `100x100` below the minimum) gives `nil`. The parsing is a pure `static func parseWindowContentSize(_ value: String?) -> CGSize?`.
- **`PaintDotMac/Document/DocumentWindowController.swift`** (extend, `#if DEBUG` only): when `LaunchOptions.current.windowContentSizeOverride` (0046's shared `LaunchOptions.current`) is non-nil, every new document window uses it as its content size instead of `initialContentSize(...)`, clamped to the screen's `visibleFrame` (a smaller screen gets the largest size that fits). It is still centered on first show. Release builds don't contain the code.
- No new persisted defaults, so `resettableKeyPrefixes` doesn't change.

### 2. Harness additions (platform glue, UI test target)

New file **`PaintDotMacUITests/Support/UITestApp+UseCases.swift`** (an `extension UITestApp`). None of the helpers below exists in 0001–0050's harness (checked by name and job; 0004's `actualSize()` and 0006's `selectTool` are app-side model methods, not harness helpers), so all are added here:

- `static let useCaseArguments = ["-UITestReduceMotion", "YES", "-UITestDiscardSavedState", "YES", "-UITestWindowContentSize", "1000x700"]`. Every use-case test launches with `resetDefaults: true` plus these arguments.
- `func actualSize()`: presses ⌘0 and waits until `statusBar.zoom` is `"100%"`.
- `struct CanvasPixelMap { var origin: CGPoint; var pointsPerPixel: CGFloat; var imageSize: (Int, Int) }` plus `func calibrateCanvas(imageWidth:imageHeight:) -> CanvasPixelMap`. It requires 100% zoom. `pointsPerPixel = canvas.frame.width / CGFloat(canvas.screenshot().image cgImage width)` (0003's backing-scale method). It hovers the canvas center, parses `statusBar.cursor` ("x, y") as (cx, cy), and sets `origin = hoverPoint − (cx + 0.5, cy + 0.5) · pointsPerPixel` in screen points. Call it again after every change to the image size (crop, resize, rotate), because the canvas re-centers.
- `func coordinate(forPixel x: Int, _ y: Int, map: CanvasPixelMap) -> XCUICoordinate`: computes the screen point of the pixel's center, hovers it, and reads `statusBar.cursor`. If the value isn't exactly `"x, y"`, it corrects by the difference × `pointsPerPixel` and retries, then tries the four ±0.5-point nudges. After 4 failed attempts it calls `XCTFail("pixel (x, y) not reachable: cursor reads …")`. The result is a verified coordinate, so pixel-exact tools (Pencil, Rectangle Select) get exactly the intended pixels on 1× and 2× displays.
- `func dragPixels(from: (Int, Int), to: (Int, Int), map:)`: `coordinate(forPixel:)` for both ends, then `press(forDuration: 0.1, thenDragTo:)`. `func clickPixel(_:_:map:)` does the same as a click.
- `func clearCanvasOfPanels(map:)`: computes the image's screen rect (`origin`, `imageSize · pointsPerPixel`, outset by 20 pt). For each visible floating panel (`toolsPanel`, `historyPanel`, `layersPanel`, `colorsPanel`) whose frame intersects it, drags the panel's title bar (the top 10 pt of its frame) horizontally until it no longer intersects, toward the nearer screen edge. It fails with a clear message if that's not possible. Call it after every calibration.
- `func choosePopUpItem(_ identifier: String, _ title: String)`: clicks the pop-up, clicks the menu item with that title, and asserts the pop-up's value is `title`.
- `func replaceText(_ identifier: String, with text: String, commit: String = "\r")`: clicks the field, presses ⌘A, types `text + commit`.
- `func setCheckbox(_ identifier: String, on: Bool)`: clicks only if the current value differs, then asserts it.
- `func setPrimaryColor(hex: String)`: `openColorsPanel()`, makes sure the primary slot is the one being edited (0007's `colors.primary`), `replaceText("colors.hex", with: hex)`, and asserts the `colors.primary` value contains the hex. Closes nothing.
- `func selectTool(_ id: String)`: clicks `tool.<id>` in the Tools panel and asserts `isToolSelected(id)`. **Use-case tests pick tools with the Tools panel**, because a single-key shortcut would be typed into whatever text field still has focus after an options-bar edit. Use case 5 also uses one key shortcut, from a state where no field has focus.
- `func historyRowNames() -> [String]` (labels of `historyRow.0…n` in order) and `func historyRowValues() -> [String]`. `func waitForHistoryRowCount(_ n: Int)`.
- `func openDocumentThroughPanel(file: URL)`: ⌘O, ⇧⌘G, types the full path, Return, clicks "Open" (the open panel, not 0030's import sheet).
- `func saveInPlaceAndDecode(_ url: URL, expected: UITestImage, timeout: TimeInterval = 5) -> UITestImage`: presses ⌘S, then polls `decodeImage(at:)` every 0.2 s until the decoded pixels equal `expected` or the timeout passes. It returns the last decoded image, and the caller asserts equality with a diff message (first 10 mismatching pixels with coordinates). Polling covers the asynchronous write and a clean document whose file already holds the current state.
- `func copyAndReadPasteboard(timeout: TimeInterval = 5) -> UITestImage`: `clearPasteboard()`, ⌘C, then polls `pasteboardPNG()` until it's non-nil.
- `struct UITestImage: Equatable { let width: Int; let height: Int; var rgba: [UInt8] }` with `subscript(x:y:) -> RGBA` (`typealias RGBA = (UInt8, UInt8, UInt8, UInt8)` wrapped in a small `Equatable` struct `Px`), `func firstMismatches(against:limit:) -> [String]`, and an init from the existing `decodeImage`/`pasteboardPNG` tuples. Put it in the same file (0021's `pasteboardPNG()` and 0029's `decodeImage(at:)` return tuples, which `UITestImage.init` wraps; neither defines an image struct).

### 3. Oracles and fixtures (pure Swift, UI test target)

The UI test target can't import the app, and the oracles must be **independent** anyway. So these are fresh transcriptions of the formulas cited in *Context*, in Foundation-only code:

- **`PaintDotMacUITests/Support/UseCaseOracles.swift`**: `enum UseCaseOracles` with
  - `mul255`, `compose(dst:src:opacity:f:)` (0026's exact-rounding `G`, `Sa = mul255(src.a, opacity)`, `Sa == 0` returns `dst`), `normal`, `multiply`, `screen` channel functions;
  - `invert(_:)`, `levels(inputHigh:)` (0033 `Apply` with inLow 0, outLow 0, outHigh 255, gamma 1, with Float math as written there), `curveTable128to192: [UInt8: UInt8]` (only the five asserted entries; asking for any other entry traps in the test, by design);
  - `hueSaturation(_:hue:saturation:lightness:)` (0032's integer formula, line by line);
  - `sharpen(_ image: UITestImage, amount:)` (direct disk definition: offsets with `u² + v² ≤ ((2r+1)² + 2) / 4`, clipped to the image, per channel R, G, B, A: sorted samples, `k = area / 2`, `m = k == 0 ? s[0] : min(255, s[k−1] + 1)`, `out = n < 0 ? 0 : min(255, n / 2)` with `n = 3c − m`);
  - `flipHorizontal`, `rotate90Clockwise` (`dst(x', y') = src(y', H − 1 − x')`, size H×W; cross-checked against 0037's pixel-map table), `crop(_:x:y:w:h:)`, `fillRect`, `setPixels`.
- **`PaintDotMacUITests/Support/UseCaseFixtures.swift`**: `enum UseCaseFixtures` with one pixel function per fixture (below), written with `UITestFixtures.writePNG(width:height:pixel:properties:)` at 96 DPI into the test's `fixtureDirectory`, plus `UITestImage` builders for the same functions. It also holds `struct UITestSeededRandom` (SplitMix64; `init(seed:)` records the seed, and every pixel-assert failure message includes `seed=<n>`). The seed for every use-case fixture is **51**. The UI target can't see `PaintDotMacTests/Support/SeededRandom.swift`.

### 4. The five use-case tests (UI test target)

All live in **`PaintDotMacUITests/UseCases/`**. Each is a `@MainActor final class …: XCTestCase` with `continueAfterFailure = false`, one `UITestApp` per test (`setUp`/`tearDown`), and launches with `UITestApp.useCaseArguments`. Every step that adds history asserts the **exact** row list afterwards (`historyRowNames()`), so an extra or missing step fails right where it happens. Expected pixels come only from `UseCaseOracles` applied to the fixture, or to an image the test already verified at an earlier stage. Coordinates below are image pixels.

#### UC-1 `UseCase1ScreenshotAnnotationUITests.testUseCase1CropAnnotateExportPNG`

Fixture `screenshot.png`, 480×320, opaque. Base white (255,255,255) except: title bar rows 0…39 (236,236,236); traffic lights x 12…23 / 32…43 / 52…63, y 14…25 in (255,95,87) / (254,188,46) / (40,200,64); sidebar x 0…79, y 40…319 (245,245,247); "text lines" x 100…299, y 60…67 and x 100…259, y 80…87 in (30,30,30); gray button x 300…419, y 160…219 (128,128,128); blue block x 100…219, y 220…279 (0,122,255).

1. Launch with the fixture, `actualSize()`, `calibrateCanvas(480, 320)`, `clearCanvasOfPanels`.
2. **Crop.** `selectTool("rectangleSelect")`, `dragPixels(from: (80,40), to: (479,279))` → `statusBar.selectionSize` "400 × 240". Image ▸ Crop to Selection (via the menu, then the same again with ⇧⌘X is *not* repeated) → `statusBar.imageSize` "400 × 240"; rows `["Open Image", "Rectangle Select", "Crop to Selection"]`. Recalibrate (400×240). In cropped coordinates C = fixture shifted by (−80, −40): text lines at x 20…219, y 20…27 and x 20…179, y 40…47; button x 220…339, y 120…179; blue x 20…139, y 180…239.
3. **Arrow.** `setPrimaryColor(hex: "FF0000")`; `selectTool("lineCurve")`; `replaceText("toolOptions.width", with: "6")`; `choosePopUpItem("toolOptions.endCap", "Arrow (Filled)")`; antialiasing stays on; `dragPixels(from: (240,70), to: (380,70))`; click `toolOptions.finish` → rows + `"Line/Curve"`.
4. **Text.** `setPrimaryColor(hex: "000000")`; `selectTool("text")`; `replaceText("toolOptions.fontSize", with: "24")`; `clickPixel(30, 80)`; type `Bug`; ⌘↩ → rows + `"Text"`.
5. **Highlight.** `setPrimaryColor(hex: "FFFF00")`; `selectTool("shapes")`; `choosePopUpItem("toolOptions.shapeType", "Rectangle")`; `choosePopUpItem("toolOptions.drawMode", "Filled Shape")`; `choosePopUpItem("toolOptions.blendMode", "Multiply")`; `setCheckbox("toolOptions.antialiasing", on: false)`; `dragPixels(from: (200,100), to: (360,200))`; click `toolOptions.finish` → rows + `"Shapes"`.
6. **Export.** ⇧⌘S → `saveThroughPanel(directory: fixtureDirectory, name: "annotated", format: "PNG")` → `decodeImage(at: …/annotated.png)`.

Assertions on the exported file (E), with C the cropped fixture:
- 400×240, DPI 96, profile name contains "sRGB", type `public.png`, 1 frame.
- **Highlight (exact colors, ±1 px position):** shape corners snap to whole pixels by rounding half away from zero (0039), so each edge may land 1 px off. For every pixel in x 203…357, y 103…197: `E == (C.r·255+127)/255 …` i.e. `multiply(C, (255,255,0))` = `(C.r, C.g, 0, 255)`. Spot values: (280,150) == (128,128,0,255) (button), (210,110) == (255,255,0,255) (white). For every pixel in the 2-px ring just outside x 197…363, y 97…203 (i.e. the rect x 197…363 × y 97…203 minus x 199…361 × y 99…201): `E == C`.
- **Arrow (exact color, tolerant geometry):** column x 300 (shaft) has a run of 5–7 consecutive pixels exactly (255,0,0,255) inside y 63…77, and no red outside y 60…80. Column x 360 (20 px behind the tip; head half-width there ≈ 10 px, from 0038's 5 × max(6,2) = 30 px head) has ≥ 14 consecutive exactly red pixels. Columns x ≤ 233 and x ≥ 387 contain no pixel with r > 200 && g < 60 in y 40…100.
- **Text (bounded):** inside the box B = x 22…190, y 62…150, ≥ 150 pixels differ from C, ≥ 10 are exactly (0,0,0,255), and every pixel that differs from C has r == g == b (black text antialiased on white gives only grays). Font rasterization varies with the macOS version, so the test asserts no exact glyph pixels.
- **Nothing else changed:** every pixel outside B, outside the arrow allowance box x 234…386 × y 40…100, and outside the highlight box x 197…363 × y 97…203 equals C exactly. This proves the crop offset pixel-for-pixel.

#### UC-2 `UseCase2PhotoAdjustExportJPEGUITests.testUseCase2AdjustSharpenResizeExportJPEG`

Fixture `photo.png`, 400×300, opaque, "photo-like". Background pixel (x, y) = `(clamp(x·255/399 + n), clamp(y·255/299 + n), clamp(160 − (x+y)/8 + n), 255)`, where `n` is UITestSeededRandom(51) noise in −12…12 drawn once per pixel in row-major order, so the texture is seeded and deterministic. Four flat blocks overwrite it: B1 x 20…179, y 20…119 = (157,101,0); B2 x 220…379, y 20…119 = (0,151,200); B3 x 20…179, y 160…259 = (101,101,101); B4 x 220…379, y 160…259 = (250,157,151). The block colors were chosen so that after Levels every channel lands on a Curves table entry that 0034's tests pin down. A PNG keeps the oracle inputs exact. JPEG decoding is covered by 0002/0029, see Open question 3.

Every stage is captured with `copyAndReadPasteboard()` (⌘C with no selection copies the whole layer and adds no history step, per 0021). `I_k` is the copy after stage k. `I_0` must equal the fixture exactly, which proves the copy path is lossless.

1. Launch with the fixture, `actualSize()`; `I_0`.
2. **Levels** ⌘L → type `200⇥` into `effectDialog.levels.inputWhite`; wait for `effectDialog.progress` "idle"; `effectDialog.ok` → rows `["Open Image", "Levels"]`. **`I_1 == levels(inputHigh: 200)` applied to `I_0`, every pixel exactly.** Blocks: B1 (200,128,0), B2 (0,192,255), B3 (128,128,128), B4 (255,200,192).
3. **Curves** ⇧⌘M → `choosePopUpItem("effectDialog.curve.mode", "RGB")`; Red, Green, Blue stay checked; click the plot at offset (128, 63) from its top-left corner → `effectDialog.curve.coordinates` "(128, 192)" and the plot value lists (128, 192) for all three channels; wait idle; OK → rows + `"Curves"`. `I_2` block interiors (all pixels of the block) are exact: B1 (238,192,0), B2 (0,235,255), B3 (192,192,192), B4 (255,238,235). Elsewhere `I_2` is used as observed, because only those five table entries are independently pinned.
4. **Hue / Saturation** ⇧⌘U → `replaceText("effectDialog.hue.field", with: "30", commit: "\t")`, `replaceText("effectDialog.saturation.field", with: "130", commit: "\t")`, Lightness stays 0; wait idle; OK → rows + `"Hue / Saturation"`. **`I_3 == hueSaturation(I_2, hue: 30, saturation: 130, lightness: 0)` exactly, every pixel.** Blocks (hand-computed from 0032's formula): B1 (182,255,0), B2 (0,127,255), B3 (191,191,191), B4 (255,247,229).
5. **Sharpen** Effects ▸ Photo ▸ Sharpen… (`chooseMenuItem("Effects", "Photo", "Sharpen…")`) → `replaceText("effectDialog.amount.field", with: "3", commit: "\t")`; wait idle; OK → rows + `"Sharpen"`. **`I_4 == sharpen(I_3, amount: 3)` exactly, every pixel** (0042: the GPU equals the oracle with 0 differences). Block interiors at least 3 px from a block edge: each channel `c → c == 0 ? 0 : (c == 255 ? 255 : c − 1)` (flat median = c + 1, the 3.36 quirk): B1 (181,255,0), B2 (0,126,255), B3 (190,190,190), B4 (255,246,228).
6. **Resize** ⌘R → `resizeImageDialog`; `resizeImage.resampling` is "Bicubic" (the default); `replaceText("resizeImage.percentage", with: "50", commit: "\t")`; `resizeImage.ok` → `statusBar.imageSize` "200 × 150"; rows + `"Resize Image"`. `I_5` is 200×150. Block interiors in output coordinates (B1 x 13…86, y 13…56; B2 x 113…186, y 13…56; B3 x 13…86, y 83…126; B4 x 113…186, y 83…126) equal the step 5 block colors **±1 per channel** (0035's bicubic weights are normalized and computed in `Double`, so a constant input stays constant up to rounding).
7. **Export JPEG at a chosen quality.** ⇧⌘S → `saveThroughPanel(directory:, name: "photo-edited", format: "JPEG")` → `jpegOptionsDialog`; `replaceText("jpegOptions.qualityField", with: "70")`; within 5 s `jpegOptions.fileSize` matches `^[0-9,.]+ (bytes|KB|MB)$` and stays unchanged for 1 s; record it as L; `jpegOptions.ok`.

Assertions on `photo-edited.jpg` (J): type `public.jpeg`, 200×150, DPI 96, profile contains "sRGB"; byte count matches L under 0029's rounding rule (|bytes − L·1000| ≤ 500 for KB, exact for bytes, ±500,000 for MB); block cores (each block interior inset by a further 6 px: B1 x 19…80, y 19…50, and so on) are within **±6 per channel** of the `I_5` block colors (JPEG at quality 70 with 4:2:0 on flat regions far from edges; the stated tolerance, never widened). Also, a second export of the same document at quality 95 (`photo-95.jpg`, same flow) is larger than J, which proves the chosen quality was used.

#### UC-3 `UseCase3LayerCompositeUITests.testUseCase3ImportBlendSaveReopenORA`

Fixtures, all 160×120: `base.png` (x, y) = (x·255/159, y·255/119, 96, 255) (integer division); `shade.png` = (200,150,100,255) for x < 80, else (60,120,240,255); `glow.png` = (255,220,0, x·255/159), where alpha 0 at x = 0 carries color (255,220,0,0). The UITestFixtures writer must keep straight color under alpha 0. If it can't, the test writes that column as (0,0,0,0) and the oracle uses that, see Edge cases.

1. Launch with `base.png`, `actualSize()`, show the Layers panel (⌥⌘3 if `layersPanel` isn't on screen) and the History panel.
2. Layers ▸ Import From File… → `openThroughPanel(file: shade.png)` → `layerRow.1` label "shade" (0030 names the layer after the file). Again with `glow.png` → `layerRow.2` "glow". Rows `["Open Image", "Import From File", "Import From File"]`.
3. Double-click `layerRow.1` → `choosePopUpItem("layerProperties.blendMode", "Multiply")` → `layerProperties.ok`. Double-click `layerRow.2` → "Screen"; `replaceText("layerProperties.opacityField", with: "128")`; OK. Rows + `"Layer Properties"`, `"Layer Properties"`.
4. **Composite before saving:** Edit ▸ Copy Merged (⇧⌘C) → pasteboard image P1. Oracle: `K = compose(compose(base, shade, 255, multiply), glow, 128, screen)` per pixel. **P1 == K exactly.** Spot values (hand-computed): (80,60) = (86,102,90,255) (base (128,128,96) → multiply (30,60,90) → screen with Sa = mul255(128,128) = 64); (40,30) = (76,61,38,255); (0, y): glow Sa = 0, so the pixel is `multiply(base, (200,150,100))`.
5. **Save .ora:** ⇧⌘S → `saveThroughPanel(directory:, name: "composite", format: "OpenRaster")` → `composite.ora` exists. ⌘W closes the window with no unsaved-changes prompt (`documentWindows.count == 0`).
6. **Reopen:** `openDocumentThroughPanel(file: composite.ora)` → one document window; `layerRow.0` "base", `.1` "shade", `.2` "glow"; double-click each row in turn and read `layerProperties.blendMode` / `.opacityField` ("Normal"/"255", "Multiply"/"255", "Screen"/"128"), clicking Cancel each time; rows `["Open Image"]`.
7. Copy Merged → P2. **P2 == K exactly** (round trip; opacity 128 → 0.502 → 128 per D-18).

#### UC-4 `UseCase4ClipboardRoundTripUITests.testUseCase4PasteEditCopy`

Clipboard source S, 120×80, straight RGBA: x < 20 → (0,0,0,0); 20 ≤ x < 40 → (255,0,0,128) (channel values 0/255 only, so a premultiplied PNG round trip is exact); x ≥ 40 → (x·2, y·3, 200, 255).

1. Launch with **no** document. `setPasteboardImage(width: 120, height: 80, pixel: S)`.
2. Edit ▸ Paste into New Image (⌥⌘V) → one document window; `statusBar.imageSize` "120 × 80"; rows `["New Image", "Paste"]`. Press Return → rows + `"Finish Pixels"`. ⌘D → rows + `"Deselect"`.
3. `actualSize()`, `calibrateCanvas(120, 80)`, `clearCanvasOfPanels`.
4. Adjustments ▸ Invert Colors (⇧⌘I) → + `"Invert Colors"`.
5. `selectTool("pencil")`; primary is black after reset (0007); `dragPixels(from: (10,70), to: (100,70))` → + `"Pencil"`.
6. `selectTool("rectangleSelect")`; `dragPixels(from: (60,10), to: (79,29))` → + `"Rectangle Select"`; ⌫ → + `"Erase Selection"`; `statusBar.selectionSize` "" (Erase Selection deselects, 0018).
7. ⌘C (no selection: the whole layer) → `pasteboardTypes()` contains `public.png` and `public.tiff`; `pasteboardPNG()` = Q.

Oracle: `W = compose(white 120×80, S, 255, normal)` (white Background plus the Normal-composited paste: x < 20 → (255,255,255,255); 20…39 → (255,127,127,255) by hand; x ≥ 40 → S); then `invert`; then pixels (10…100, 70) = (0,0,0,255); then x 60…79 × y 10…29 = (0,0,0,0). **Q equals that exactly, 120×80, including the alpha-0 rectangle.** Spot values: (5,5) = (0,0,0,255); (30,5) = (0,128,128,255); (50,40) = (155,135,55,255); (70,20) = (0,0,0,0); (50,70) = (0,0,0,255).

#### UC-5 `UseCase5UndoHistoryUITests.testUseCase5UndoAndHistoryJump`

Fixture `steps.png`, 64×48, opaque white. `S_k` is the oracle state after step k (`S_0` = fixture). Every check is `saveInPlaceAndDecode(steps.png, expected: S_k)`, exact size and every pixel. The History panel is shown.

1. Launch, `actualSize()`, `calibrateCanvas(64, 48)`, `clearCanvasOfPanels`, `setPrimaryColor(hex: "FF0000")`, click the canvas window's title bar to make it key (no field focused), then press `p` → `isToolSelected("pencil")` (the one key shortcut in the suite).
2. Steps, each followed by an `S_k` check and the full row list:
   1. Pencil `dragPixels((4,10), (40,10))` → "Pencil" (row 10, x 4…40 red).
   2. `selectTool("rectangleSelect")`, `dragPixels((8,20), (23,35))` → "Rectangle Select" (`S_2 == S_1`; `statusBar.selectionSize` "16 × 16").
   3. ⌥⌫ → "Fill Selection" (x 8…23, y 20…35 red).
   4. ⌘D → "Deselect".
   5. ⇧⌘I → "Invert Colors" (white → (0,0,0,255), red → (0,255,255,255)).
   6. Image ▸ Flip Horizontal → "Flip Horizontal".
   7. ⌘] → "Rotate 90° Clockwise" (48×64); recalibrate (48, 64) and `clearCanvasOfPanels`.
   8. `selectTool("pencil")`, `clickPixel(5,5)` → "Pencil".
   9–28. 20 more Pencil clicks at (2 + 2i, 60), i = 0…19 → 20 rows "Pencil". One check of `S_28` after the last click. Row count 29.
3. **Undo through ⌘Z:** ⌘Z ×20 → `S_8`; Edit menu's first item title "Undo Pencil". Then one ⌘Z at a time → `S_7` … `S_0`, checking each state. Before each ⌘Z the Edit menu title is "Undo <row name>" ("Undo Rotate 90° Clockwise", …, "Undo Pencil"). At `S_0`: row 0 `current`, rows 1…28 `undone`, Edit ▸ Undo disabled.
4. **Redo:** ⇧⌘Z ×3 → `S_3`; the Edit menu reads "Redo Deselect".
5. **History panel jumps:** click `historyRow.7` → `S_7`, row values `done`×7, `current`, `undone`×21. Click `historyRow.28` → `S_28`. Click `historyRow.0` → `S_0`. Click `historyRow.5` → `S_5`.
6. **A new action discards the undone steps (H-2):** at `S_5` (64×48, recalibrate), `clickPixel(20,20)` with the Pencil → rows = the first 6 names + "Pencil" (7 rows), row 6 `current`; Edit ▸ Redo disabled; pixels = `S_5` with (20,20) red. ⌘Z → `S_5`, row 6 `undone`.

### 5. Headless P0 coverage test (test target, Swift Testing)

- **`PaintDotMacTests/Acceptance/PRDRequirementParser.swift`** (test support, Foundation only): `struct PRDRequirementParser { static func p0Keys(in markdown: String) -> Set<String>; static func useCaseKeys(in markdown: String) -> [String] }`. Rules, all line-based:
  1. **Priority tables:** a table whose header row's **last** cell is `Pri`. Each data row whose first cell matches `^[A-Z]+-[A-Z0-9]+$` and whose last cell contains `P0` (so `P0 / P1` counts, as for F-6) contributes that ID. Tables without a `Pri` last header cell are ignored, so §10's "R-4 … Hold to the P0 list" is not a requirement.
  2. **Bold P0 labels:** every match of `\*\*([^*]+?) \(P0\)` contributes the trimmed label (`TOOL-A`…`TOOL-C`, `FX-A`…`FX-E`, `FMT-A`…`FMT-E`, `Saving`). A line matching `^(.+?) \*\*\(P0\)\*\*` contributes its prefix (`All adjustments`).
  3. **Effects table:** the table under `### 5.9` whose header has a cell `v1.0 (P0)`. Each name in that column (split on `, `, trimmed, empty skipped) contributes `effect:<name>` (`effect:Gaussian Blur`, … , `effect:Clouds`).
  4. **NF table:** the table under `## 6.` with header `| ID | Category | Requirement |`. Every `NF-n` row counts as P0 (Open question 1).
  5. **Use cases:** the numbered list under `### Key use cases` → `UC-1`…`UC-n`.
  As of this spec the PRD yields 101 P0 keys (68 table IDs, 14 bold labels, "All adjustments", 9 effects, NF-1…NF-9) and UC-1…UC-5.
- **`PaintDotMacTests/Acceptance/P0CoverageMap.swift`**: `enum P0CoverageMap { static let entries: [(key: String, tests: [String])] }`. Each test reference is `"<FileStem>/<functionName>"`, for example `"CropToSelectionUITests/testMenuEnablement"`. It's an array of tuples rather than a dictionary literal, so duplicate keys are reported by the test instead of trapping. The implementer fills it from the acceptance criteria of `docs/specs/done/*_COMPLETED.md` (every criterion names its tests, and every spec header names its requirement IDs), choosing for each key the tests that actually prove it, with a UI test included wherever one exists. Minimum required entries (verified against those specs when filling the map): `UC-1` → `UseCase1ScreenshotAnnotationUITests/testUseCase1CropAnnotateExportPNG` (and UC-2…UC-5 likewise); `IMG-1`, `T-17`, `T-18`, `T-19`, `F-2` include UC-1; `ADJ-7`, `ADJ-4`, `ADJ-5`, `effect:Sharpen`, `IMG-2`, `F-3` include UC-2; `L-2`, `L-3`, `L-6`, `F-1`, `FMT-E`, `E-2` include UC-3; `E-2`, `E-5`, `ADJ-6`, `T-13`, `E-4` include UC-4; `E-1`, `H-1`, `H-2`, `H-3`, `IMG-4` include UC-5. NF-1…NF-3 map to 0048's benchmark tests (`PaintbrushFrameBenchmarks/…`, `OpenBenchmarks/testOpen24MPJPEG`, `PanZoomBenchmarks/testPanZoom10Layer4K`, `GaussianBlurBenchmarks/testRadius20On24MP`) plus their Debug performance tests; NF-4 to 0048's `MemoryBenchmarks/testBudgetBoundsFootprint` and 0046's `UndoBudgetLiveTests/loweringDropsOldestInAllDocuments`; NF-5 to 0047's `CrashRecoveryUITests/testRecoversDocumentsAfterKill` and `AutosaveRecoveryTests/recoversTitledPNG`; NF-7 and APP-7 to 0049's `AccessibilityAuditUITests/…` and `KeyboardNavigationUITests/…`; NF-8 to 0050's bundle check, which is a script, not a Swift test: reference it as `"script:.agents/skills/spec-implementer/scripts/check-app-bundle.sh#--self-test"` (plus `BundleInfoTests/marketingVersionIsSemantic` and `AppIconTests/iconSourceIsSmall`).
- **`PaintDotMacTests/Acceptance/P0CoverageTests.swift`** (`@Suite struct P0CoverageTests`). The repo root is found from `#filePath` by walking up to the first directory that contains both `PRD.md` and `project.yml`. If it isn't found, the test fails with the paths it tried (never skipped). Tests:
  - `everyP0RequirementIsMapped`: `p0Keys(PRD) ∪ useCaseKeys(PRD) − mapped keys` is empty. The failure lists each missing key.
  - `noStaleOrDuplicateKeys`: every mapped key is in that set, and no key appears twice.
  - `everyReferencedTestExists`: for each reference, exactly one `<FileStem>.swift` exists under `PaintDotMacTests/`, `PaintDotMacUITests/`, or `PaintDotMacBenchmarks/` (0048; all three exist at this point), and its text matches `func\s+<functionName>\s*\(`. A reference of the form `script:<repo-relative path>#<token>` instead requires that file to exist and contain `<token>` (used only for NF-8's `check-app-bundle.sh`). The failure lists each bad reference with the reason (file missing, ambiguous file, function missing, token missing).
  - `everyKeyHasATest`: no entry has an empty `tests` array.
  - `useCasesMapToTheirEndToEndTests`: `UC-n` includes `UseCase<n>…UITests/testUseCase<n>…`, for n = 1…5.
  - `parserFindsSentinelsInRealPRD`: the real PRD's keys ⊇ {APP-1, APP-10, T-17, H-6, F-6, TOOL-C, FX-D, FMT-E, Saving, All adjustments, effect:Clouds, NF-8} and ∩ {APP-3, APP-8, T-20, L-4, H-4, C-3, F-7, R-4, effect:Radial Blur, TOOL-D} = ∅; count ≥ 95; `useCaseKeys` == UC-1…UC-5.
- **`PaintDotMacTests/Acceptance/PRDRequirementParserTests.swift`**: parser unit tests on inline markdown snippets, listed in the Test plan.

### 6. Runtime budget and flakiness controls

| Test | Budget (M1, Debug) | Hard fail at (3×) |
|---|---|---|
| UC-1 | 75 s | 225 s |
| UC-2 | 90 s | 270 s |
| UC-3 | 75 s | 225 s |
| UC-4 | 45 s | 135 s |
| UC-5 | 150 s | 450 s |
| Use-case suite total | ≤ 7.5 min | — |
| P0 coverage + parser tests | < 1 s | 5 s |

Each use-case test measures its wall time and fails only past the 3× column, a gross-regression guard. The measured numbers go into the Verification status.

Flakiness controls, all mandatory:
- fixed window: `-UITestWindowContentSize 1000x700` (every fixture fits at 100% on 1× and 2× displays);
- `actualSize()` before every calibration;
- pixel targets verified by hovering and reading `statusBar.cursor`;
- floating panels dragged off the image;
- `-UITestResetDefaults YES` (primary black, secondary white, default tool options, default panel frames), `-ApplePersistenceIgnoreState YES`, `-UITestDiscardSavedState YES` (no recovery prompt from an earlier crashed run), `-UITestReduceMotion YES` (static ants);
- seed 51 for all generated texture, printed in failure messages; no random effect is used, so `-UITestEffectSeed` isn't needed;
- every wait is a predicate wait with a 10 s timeout (5 s for pasteboard and file polls), never a fixed sleep except the 1 s "label stable" check in UC-2;
- tools are picked with the Tools panel, and pending edits are committed with `toolOptions.finish` or ⌘↩, never with a bare Return that a focused field could swallow;
- the pasteboard is cleared before every read, and in `tearDown`;
- fixtures go in a per-test temp directory, deleted in `tearDown`.

### 7. Project and docs

- `project.yml`: no change; the source globs pick up `PaintDotMacUITests/UseCases/`, `PaintDotMacUITests/Support/`, and `PaintDotMacTests/Acceptance/`. Run `xcodegen generate`.
- PRD.md: no change by this spec. Open questions 1–4 may add §12 rows, and the new `-UITestWindowContentSize` hook belongs in the §4 *Testing* row; the batch owner records them.
- AGENTS.md *Testing expectations*: add one line, "Every P0 requirement in PRD.md must be listed in `PaintDotMacTests/Acceptance/P0CoverageMap.swift` with at least one test; `P0CoverageTests` fails otherwise."

## Acceptance criteria

- [ ] UC-1 runs through real UI only: Rectangle Select drag → Crop to Selection → Line/Curve with a filled arrowhead → Text → a Shapes highlight rectangle (Filled Shape, Multiply) → Save As PNG; the exported PNG is 400×240 at 96 DPI with sRGB, its highlight pixels equal the Multiply oracle, its arrow/text regions meet the stated bounds, and every other pixel equals the cropped fixture → `UseCase1ScreenshotAnnotationUITests.testUseCase1CropAnnotateExportPNG`
- [ ] UC-2: Levels, Curves, Hue / Saturation and Sharpen each produce the oracle's pixels (Levels, Hue / Saturation and Sharpen every pixel; Curves on the pinned block values); Resize 50% Bicubic gives 200×150 with block interiors ±1; the JPEG export at quality 70 is 200×150, 96 DPI, sRGB, block cores ±6, its size matches the dialog's estimate, and the quality-95 export is larger → `UseCase2PhotoAdjustExportJPEGUITests.testUseCase2AdjustSharpenResizeExportJPEG`
- [ ] UC-3: two images imported as layers, set to Multiply/255 and Screen/128 in Layer Properties; Copy Merged equals the composition oracle exactly before saving and after an `.ora` save → close → reopen, with names, order, blend modes and opacities preserved → `UseCase3LayerCompositeUITests.testUseCase3ImportBlendSaveReopenORA`
- [ ] UC-4: Paste into New Image from a clipboard PNG with transparent and semi-transparent pixels, Invert Colors, a Pencil line, Erase Selection, then Copy; the clipboard holds PNG and TIFF and the PNG equals the oracle exactly, including alpha 0 → `UseCase4ClipboardRoundTripUITests.testUseCase4PasteEditCopy`
- [ ] UC-5: 28 steps (including selection, structural and size-changing steps); every state restored exactly by ⌘Z one step at a time and by ⇧⌘Z; History panel jumps to rows 7, 28, 0, 5 restore exact pixels with correct done/current/undone values; Edit menu titles name the step; a new action after a jump discards the undone rows and disables Redo → `UseCase5UndoHistoryUITests.testUseCase5UndoAndHistoryJump`
- [ ] Every P0 key parsed from PRD.md (priority tables, bold P0 labels, P0 effects, NF rows) and every §3 use case maps to at least one test function that exists in the source tree; stale, duplicate, empty, or dangling entries fail with a list → `P0CoverageTests.everyP0RequirementIsMapped`, `.noStaleOrDuplicateKeys`, `.everyReferencedTestExists`, `.everyKeyHasATest`, `.useCasesMapToTheirEndToEndTests`, `.parserFindsSentinelsInRealPRD`
- [ ] The PRD parser follows the stated rules, including the exclusions → `PRDRequirementParserTests.*`
- [ ] The oracles reproduce the hand-computed values in this spec → `UseCaseOracleTests.*`
- [ ] `-UITestWindowContentSize` parses as specified and sizes new document windows in Debug builds only → `LaunchOptionsTests.windowContentSize`, `DocumentWindowControllerTests.windowContentSizeOverride`, `UseCase4ClipboardRoundTripUITests` (window content size asserted at launch: canvas window frame width ≥ 1000 pt, or the clamped screen width)
- [ ] Each use-case test finishes within 3× its budget, and the measured times are recorded → the timing assertion in each test; Verification status
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **1× vs 2× displays:** `pointsPerPixel` is 1 or 0.5. Hover verification handles both, and on 2× fractional points reach every pixel. If the event system rounds to whole points, the ±0.5-point nudges reach the other parity. If a pixel is still unreachable, the test fails with a message naming the pixel and the cursor reading, never a silent off-by-one.
- **Small screen:** the window size is clamped to the visible frame. All fixtures need at most 480×320 device pixels (240×160 pt on 2×, 480×320 pt on 1×), which fits in a clamped window down to a 1280×800 screen. On a smaller visible frame, `calibrateCanvas` fails with "image not fully visible at 100%" rather than producing wrong coordinates.
- **Panels over the canvas:** `clearCanvasOfPanels` moves them; if a panel can't be moved clear, the test fails naming the panel.
- **Focus:** a field keeps keyboard focus after `replaceText`. Tool choice goes through the Tools panel and commits go through `toolOptions.finish`/⌘↩, so no keystroke lands in the wrong place. UC-5's single key shortcut is pressed after making the document window key.
- **Asynchronous work:** effect previews (wait for `effectDialog.progress` "idle"), the JPEG estimate (wait for a stable label), saves (poll the file), and the pasteboard (poll) are all awaited by predicate.
- **Clean-document ⌘S:** if NSDocument skips writing a clean document, its file already holds the current state, and the poll still matches.
- **Alpha-0 color in fixtures:** `UITestFixtures.writePNG` writes straight RGBA via ImageIO. If the implementer finds the writer premultiplies (losing color under alpha 0), `glow.png`'s x = 0 column and UC-4's x < 20 columns are already chosen so the oracle result doesn't depend on that color (Sa = 0 leaves the destination; Normal over white with alpha 0 gives white). Semi-transparent source pixels use only channel values 0/255, so premultiplication round-trips exactly.
- **Text rendering differences** between macOS versions: UC-1 asserts a bounded region, a minimum count, exact black presence, and gray-only antialiasing, never glyph pixels.
- **Shape and line rounding:** ±1 px positional tolerance (half-away rounding of the pointer location in 0039, raw location for Line/Curve in 0038); colors stay exact; check pixels are ≥ 3 px inside or outside an edge.
- **Earlier specs' unresolved questions:** the UC-2 Sharpen expectation follows 0042's normative definition (including the `+1` quirk, 0042 Open question 2), and UC-4 follows 0021's recommended answers 3–4. If either was resolved differently when built, update the oracle to the shipped, PRD-recorded behavior and say so in the Verification status. Never loosen a tolerance to absorb a difference.
- **PRD evolution:** a new P0 row fails `everyP0RequirementIsMapped` until mapped; a removed row fails `noStaleOrDuplicateKeys`; a renamed test fails `everyReferencedTestExists`. This is intended.
- **PRD/project not found** from `#filePath` (for example tests run from an archive): fail with the searched paths, never skip.
- **A failed use-case step** stops the test (`continueAfterFailure = false`), and `tearDown` still terminates the app and deletes fixtures and the pasteboard contents.

## Test plan

- **Unit — `PaintDotMacTests/Acceptance/PRDRequirementParserTests.swift`** (Swift Testing; inline snippets):
  - `priorityTableP0Rows`: a `| ID | Requirement | Pri |` table with rows A-1 P0, A-2 P1, A-3 `P0 / P1`, A-4 P2 → {A-1, A-3}.
  - `nonPriorityTablesIgnored`: a `| # | Item | Notes |` table with a row `R-4 … P0 list` → ∅; a `| ID | Tool | Key | Notes | Pri |` table (5 columns, last `Pri`) is parsed.
  - `boldLabels`: `- **TOOL-A (P0):** x`, `- **FMT-E (P0) OpenRaster details.** y`, `- **Saving (P0).** z`, `- **TOOL-D (P1):** w` → {TOOL-A, FMT-E, Saving}.
  - `allAdjustmentsParagraph`: `All adjustments **(P0)**: apply …` → {All adjustments}.
  - `effectsColumn`: a §5.9-style table with `| Blurs | Gaussian Blur, Motion Blur | Radial |` and `| Artistic | | Ink Sketch |` → {effect:Gaussian Blur, effect:Motion Blur}.
  - `nfTable`: `## 6.` with `| ID | Category | Requirement |` rows NF-1, NF-2 → {NF-1, NF-2}; the same table under another heading is ignored.
  - `useCases`: `### Key use cases` with items 1.–3. → [UC-1, UC-2, UC-3]; a numbered list elsewhere is ignored.
  - `malformedRowsSkipped`: rows with too few cells or a lowercase ID are ignored without crashing.
- **Unit — `PaintDotMacTests/Acceptance/P0CoverageTests.swift`**: the six tests in Scope §5 (these are the gate).
- **Unit — `PaintDotMacTests/App/LaunchOptionsTests.swift`** (extend): `windowContentSize`: `["-UITestWindowContentSize", "1000x700"]` → 1000×700; `"320x320"` → kept; `"10000x10000"` → kept; `"319x700"`, `"1000x10001"`, `"0x0"`, `"abcx100"`, `"1000×700"` (U+00D7), `"1000x"`, a missing value at the end → nil; coexists with `-UITestOpen`.
- **Unit — `PaintDotMacTests/Document/DocumentWindowControllerTests.swift`** (extend 0001's): `windowContentSizeOverride`: with an override of 1000×700 and a 4000×3000 image, the content size is 1000×700; without one it equals `initialContentSize`; an override larger than a 800×600 visible frame is clamped to it.
- **Oracle self-tests — `PaintDotMacUITests/UseCases/UseCaseOracleTests.swift`** (XCTestCase that never launches the app; it guards the oracles with hand values from this spec): `levels(200)` of 157/101/151/250/0 → 200/128/192/255/0; `hueSaturation` of (238,192,0), (0,235,255), (192,192,192), (255,238,235) at 30/130/0 → (182,255,0), (0,127,255), (191,191,191), (255,247,229); identity 0/100/0 → input; `sharpen` of a flat 9×9 image of value 100 (alpha 255), amount 3 → every pixel 99, alpha 255; flat 0 → 0; flat 255 → 255; a 1×1 image → unchanged; `compose(normal)` (255,0,0,128) over white → (255,127,127,255); `compose(multiply)` base (128,128,96,255) with (60,120,240,255) → (30,60,90,255); then `screen` with (255,220,0,128) at opacity 128 → (86,102,90,255); `compose` with Sa = 0 returns dst bit-identically; `rotate90Clockwise` of a 3×2 labelled image gives the 0037 pixel-map table's result; `flipHorizontal` twice = identity.
- **UI — `PaintDotMacUITests/UseCases/`**: the five tests in Scope §4, each asserting the history row list after every step and the exact pixels listed there.
- **Round-trip/property:** UC-3 covers the `.ora` round trip of the composite at the UI level, and UC-5 covers undo → redo → jump identity at the UI level. The per-feature property tests stay in their specs.
- **Performance:** the per-test wall-time guard (3× budget). No NF metric is measured here (0048 owns NF-1…NF-3).
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build, no warnings, all tests pass, none skipped, UI tests ran (including the five use cases), launch smoke passes. Also run `--sanitizers --release` at the end of the batch, as AGENTS.md requires; sanitizers report UNAVAILABLE on this Mac, which isn't a failure.
- **Manual verification** (§9's qualitative criteria can't be automated):
  1. Do use cases 1–5 by hand on a real screenshot, a real camera JPEG, three real photos, and a real clipboard image from another app (Preview/Safari). Each completes without leaving the app, and the results open correctly in Preview (PNG/JPEG) and Krita or GIMP (`.ora`).
  2. Give a Paint.NET user the app with no instructions and ask them to find every P0 tool and menu item (§9). Note anything they couldn't find.
  3. Run the five use-case tests on a 1× external display and on the built-in 2× display. Both pass.
  4. Record each use-case test's wall time in the Verification status.

## Open questions

Recommended answers are already applied in this spec. The batch owner confirms them with the user and records them in PRD §12.

1. **Are all NF-1…NF-9 rows P0?** The §6 table has no priority column. Recommended: yes. M7's scope is the "performance pass against the NF targets", §9 names NF-1…NF-3, and no NF row is marked later, so the coverage test treats every NF row as P0. (Alternative: add a `Pri` column to §6.)
2. **Which non-ID P0 statements count as requirements?** Recommended: the bold `(P0)` labels (TOOL-*, FX-*, FMT-*, "Saving"), the "All adjustments **(P0)**" paragraph, and each P0 effect name in §5.9 get their own coverage keys. §5.12's shortcut table has no priority and is covered by 0045's own `prdTableHasNoUnmappedRows`, so it isn't duplicated here.
3. **Use case 2 starts from a PNG "photo", not a JPEG.** A lossless input keeps every downstream oracle exact. Opening JPEGs is covered by 0002/0029, and the use case still ends with a JPEG export at a chosen quality. Recommended: yes. (Alternative: open a JPEG and verify only with tolerances from step 1 on.)
4. **New Debug-only launch hook `-UITestWindowContentSize WxH`** (fixed window size for deterministic UI tests). Recommended: yes, and list it in PRD §4 *Testing* next to the other hooks.

## Out of scope

- New product behavior of any kind. A use case that fails because a feature is wrong is fixed in that feature's code, with the fix recorded against its spec ID.
- Measuring NF-1…NF-3 (0048), the accessibility audit (0049), and bundle size (0050). This spec only maps them in the coverage table.
- P1/P2 requirements (0052–0069), docked panels (0052), and WebP export (0063).
- Krita/GIMP interoperability automation (manual step 1; 0028 owns the `.ora` format tests).
