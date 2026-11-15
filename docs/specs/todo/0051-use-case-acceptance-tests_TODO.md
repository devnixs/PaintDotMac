# 0051 — Prove the five key use cases end to end and gate v1.0 on P0 test coverage

> Source: PRD.md §3 *Key use cases* 1–5; §8 M7 exit criterion "All P0 requirements met" (and the M2/M4/M5 exit criteria that name use cases 1–3); §9 *Success criteria* ("All five key use cases (§3) can be done without leaving the app"); §4 *Testing* (headless tests only); §5 requirement tables (every P0 ID); §6 NF-1…NF-9; §12 D-3, D-11, D-12, D-13, D-16, D-17, D-18, D-29, D-34, D-37, D-40. AGENTS.md *Testing expectations*, *Architecture rules* 1–2.
> Milestone: M7 (Polish, v1.0) — the last v1.0 spec.
> Depends on: 0050-app-icon-and-bundle-size (and through the chain every spec 0001–0049; the use cases touch 0004, 0005, 0006, 0007, 0010, 0011, 0013, 0014, 0018, 0020, 0021, 0022, 0024–0030, 0031–0035, 0037–0040, 0042, 0045, 0047).

## Context

Every earlier spec tests its own feature. Nothing yet proves that the five §3 use cases work as one uninterrupted session through the real UI, and nothing proves that every P0 requirement is covered by at least one test. That is what M7's exit criterion ("All P0 requirements met") and §9 require. This spec adds no product behavior. It adds:

1. five headless end-to-end integration tests, one per use case. Each drives the real UI code in-process, the way a user would (menu actions, key shortcuts through the real key monitor, Tools/History/Layers/Colors panel controls, the tool options bar, dialogs through their presenters, canvas drags as synthesized events), never shows a window, and checks **exact pixels**, computed independently in the test target, on the exported file or a private pasteboard;
2. a headless **P0 coverage** test that parses `PRD.md`, collects every P0 requirement key, and fails if any key isn't mapped to at least one existing test function;
3. the few harness helpers the tests need. No launch hook is added (PRD §4 Testing).

What exists (exact names from earlier specs; checked against 0001–0050):

- **Headless harness** in `PaintDotMacTests/Support/` (0001 onward): `DocumentHarness` (`open`, `newImage`, `perform`, `isEnabled`, `key`, `shortcut(_:in:)`, `clickCanvas`/`dragCanvas`, `viewPoint(forImagePoint:)`, `canvasView`, `statusBar`, `appModel`, `useClipboard`, `runMenuItem(_:_:_:)`), `FixtureFiles` (`makePNG`, `writePNG(width:height:pixel:properties:)`, `writeOpenRaster`, `decodePNG`, `decodeImage(at:)`, `savePanelFormatTitles`), `PrivatePasteboard` (`makePrivatePasteboard`, `writeImage(width:height:pixel:asTIFFOnly:to:)`, `readPNG(from:)`, `types(of:)`), `ScriptedPresenters` (`ScriptedNewImagePresenter`, `RecordingAlertPresenter`, `ScriptedPasteExpandPrompt`, `ScriptedOpenPanelPresenter`, `ScriptedSaveConfirmationPresenter`), the recording `SheetPresenting` (0025), `ColorsPanelHarness` (0007), `HeadlessAssertions`, and `SeededRandom` (0002). Panels and dialogs are built offscreen and reached through their models and accessibility elements.
- **No launch hooks** (PRD §4 Testing): test configuration is injected in-process (a fresh-suite `AppModel`, `reduceMotionOverride`, `imageLimitsOverride`, …). The use-case tests need none of these except a fresh-suite `AppModel` (primary black, secondary white, default tool options).
- **Window sizing**: the tests set each offscreen window's content size to 1000×700 pt with `window.setContentSize` (no hook needed), then perform Actual Size; image pixels map to view points through `viewPoint(forImagePoint:)` (0004), so there is no on-screen calibration.
- **Accessibility identifiers and models** used here: `canvas`, `documentWindow`, `tool.<id>`, `toolOptions.width`, `.endCap`, `.drawMode`, `.blendMode`, `.antialiasing`, `.fontSize`, `.finish` (0038–0040), `colors.hex` (0007), `historyList`, `historyRow.<i>` (label = step name, value `current`/`done`/`undone`; 0010), `layerRow.<i>` (0 = bottom; label = name; 0025), `layerProperties.blendMode`, `.opacityField`, `.ok` (0025), `statusBar.cursor` ("x, y" or ""), `statusBar.selectionSize` ("W × H"), `statusBar.imageSize` ("W × H"), `statusBar.zoom` ("100%") (0004/0014), `effectDialog`, `effectDialog.ok`, `effectDialog.progress` ("idle"), `effectDialog.levels.inputWhite` (0033), `effectDialog.curve.mode`, `.curve.plot`, `.curve.coordinates` (0034), `effectDialog.hue.field`, `.saturation.field` (0032), `effectDialog.amount.field` (0042), `resizeImageDialog`, `resizeImage.percentage`, `.resampling`, `.ok` (0035), `jpegOptionsDialog`, `jpegOptions.qualityField`, `.fileSize`, `.ok` (0029), `savePanel.format` (0029).
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

All new code is test code. **No app code change and no product behavior change.**

### 1. No launch hook

An earlier draft's window-size launch hook is not needed: the tests size the offscreen window themselves (`window.setContentSize(1000×700)`), and nothing is ever shown.

### 2. Harness additions (test support, `PaintDotMacTests`)

New file **`PaintDotMacTests/Acceptance/UseCaseHarness.swift`** (a `@MainActor final class UseCaseHarness` wrapping a `DocumentHarness` and a fresh-suite `AppModel`). Each helper drives the same code path the UI does:

- `func actualSize()`: performs Actual Size and asserts `statusBar.zoomText == "100%"`.
- `func dragPixels(from: (Int, Int), to: (Int, Int))` and `func clickPixel(_ x: Int, _ y: Int)`: synthesized mouse events at `viewPoint(forImagePoint: (x + 0.5, y + 0.5))` through `CanvasInputRouter`, so pixel-exact tools (Pencil, Rectangle Select) get exactly the intended pixels on any backing scale. Before each, it sends a `mouseMoved` to the same point and asserts `statusBar.cursorText == "x, y"` (a cheap check that the mapping is right).
- `func selectTool(_ id: String)`: invokes the accessibility press of `tool.<id>` in the Tools panel's hosting view and asserts the tool is active. **Use-case tests pick tools with the Tools panel**; UC-5 also uses one key shortcut, through `shortcut(_:)` with the document window as key window.
- `func choosePopUpItem(_ identifier: String, _ title: String)`, `func replaceText(_ identifier: String, with text: String)`, `func setCheckbox(_ identifier: String, on: Bool)`: find the control by accessibility identifier in the options bar, dialog, or panel under test, set it through its binding (pop-up: select the item whose title matches; text: set and commit the field as Return/Tab does; checkbox: toggle only if needed), and assert the control's value afterwards.
- `func setPrimaryColor(hex: String)`: makes the primary slot active and commits the hex through the Colors panel's hex field binding (0007), then asserts `colors.primary`'s value contains the hex.
- `func press(_ identifier: String)`: the control's accessibility press (for example `toolOptions.finish`, `effectDialog.ok`, `layerProperties.ok`).
- `func historyRowNames() -> [String]` and `func historyRowValues() -> [String]` from the History panel model; `func pressHistoryRow(_ i: Int)` presses `historyRow.<i>`.
- `func saveAs(_ name: String, format: FileFormat) -> URL`: prepares (never runs) a save panel, asserts `savePanel.format` offers the format, then saves with `save(to:ofType:for: .saveAsOperation)` into the per-test temp directory, answering any flatten or JPEG prompt through `ScriptedSaveConfirmationPresenter` as the step says.
- `func saveInPlaceAndDecode(_ url: URL, expected: UseCaseImage) -> UseCaseImage`: `save(to: url, ofType: fileType, for: .saveOperation)` (the ⌘S path), then decodes; the caller asserts equality with a diff message (first 10 mismatching pixels with coordinates).
- `func copyAndReadPasteboard() -> UseCaseImage`: performs Copy (or Copy Merged) against the harness's private pasteboard and decodes its PNG. The user's clipboard is never touched.
- `struct UseCaseImage: Equatable { let width: Int; let height: Int; var rgba: [UInt8] }` with `subscript(x:y:) -> Px`, `func firstMismatches(against:limit:) -> [String]`, and inits from `decodeImage(at:)` / `readPNG(from:)`.

### 3. Oracles and fixtures (pure Swift, `PaintDotMacTests/Acceptance/`)

The oracles must be **independent** of the code under test, so although the test target can `@testable import` the app, these files never call app types: they are fresh transcriptions of the formulas cited in *Context*, in Foundation-only code.

- **`PaintDotMacTests/Acceptance/UseCaseOracles.swift`**: `enum UseCaseOracles` with
  - `mul255`, `compose(dst:src:opacity:f:)` (0026's exact-rounding `G`, `Sa = mul255(src.a, opacity)`, `Sa == 0` returns `dst`), `normal`, `multiply`, `screen` channel functions;
  - `invert(_:)`, `levels(inputHigh:)` (0033 `Apply` with inLow 0, outLow 0, outHigh 255, gamma 1, with Float math as written there), `curveTable128to192: [UInt8: UInt8]` (only the five asserted entries; asking for any other entry traps in the test, by design);
  - `hueSaturation(_:hue:saturation:lightness:)` (0032's integer formula, line by line);
  - `sharpen(_ image: UseCaseImage, amount:)` (direct disk definition: offsets with `u² + v² ≤ ((2r+1)² + 2) / 4`, clipped to the image, per channel R, G, B, A: sorted samples, `k = area / 2`, `m = k == 0 ? s[0] : min(255, s[k−1] + 1)`, `out = n < 0 ? 0 : min(255, n / 2)` with `n = 3c − m`);
  - `flipHorizontal`, `rotate90Clockwise` (`dst(x', y') = src(y', H − 1 − x')`, size H×W; cross-checked against 0037's pixel-map table), `crop(_:x:y:w:h:)`, `fillRect`, `setPixels`.
- **`PaintDotMacTests/Acceptance/UseCaseFixtures.swift`**: `enum UseCaseFixtures` with one pixel function per fixture (below), written with `FixtureFiles.writePNG(width:height:pixel:properties:)` at 96 DPI into the test's temp directory, plus `UseCaseImage` builders for the same functions. Generated texture uses `SeededRandom` (0002) with seed **51**, printed in every pixel-assert failure message.

### 4. The five use-case tests (headless integration, `PaintDotMacTests`)

All live in **`PaintDotMacTests/Acceptance/UseCases/`**. Each is a Swift Testing `@Suite(.serialized) @MainActor struct` with one test; it builds a `UseCaseHarness` (fresh-suite `AppModel`, offscreen window sized 1000×700 pt), stops at the first failed `#require`, and ends with `HeadlessAssertions.closeAllDocuments()` and `noVisibleWindows()`. Nothing is ever shown on screen. Menu shortcuts named below (⌘L, ⇧⌘U, …) mean performing that menu item's action through `harness.perform`; dialogs are captured by the recording `SheetPresenting` and driven through `replaceText`/`choosePopUpItem`/`press`, after waiting for the effect render to complete (`effectDialog.progress` "idle"). Every step that adds history asserts the **exact** row list afterwards (`historyRowNames()`), so an extra or missing step fails right where it happens. Expected pixels come only from `UseCaseOracles` applied to the fixture, or to an image the test already verified at an earlier stage. Coordinates below are image pixels.

#### UC-1 `UseCase1ScreenshotAnnotationTests.useCase1CropAnnotateExportPNG`

Fixture `screenshot.png`, 480×320, opaque. Base white (255,255,255) except: title bar rows 0…39 (236,236,236); traffic lights x 12…23 / 32…43 / 52…63, y 14…25 in (255,95,87) / (254,188,46) / (40,200,64); sidebar x 0…79, y 40…319 (245,245,247); "text lines" x 100…299, y 60…67 and x 100…259, y 80…87 in (30,30,30); gray button x 300…419, y 160…219 (128,128,128); blue block x 100…219, y 220…279 (0,122,255).

1. Open the fixture, `actualSize()`.
2. **Crop.** `selectTool("rectangleSelect")`, `dragPixels(from: (80,40), to: (479,279))` → `statusBar.selectionSize` "400 × 240". Image ▸ Crop to Selection (its menu action) → `statusBar.imageSize` "400 × 240"; rows `["Open Image", "Rectangle Select", "Crop to Selection"]`. In cropped coordinates C = fixture shifted by (−80, −40): text lines at x 20…219, y 20…27 and x 20…179, y 40…47; button x 220…339, y 120…179; blue x 20…139, y 180…239.
3. **Arrow.** `setPrimaryColor(hex: "FF0000")`; `selectTool("lineCurve")`; `replaceText("toolOptions.width", with: "6")`; `choosePopUpItem("toolOptions.endCap", "Arrow (Filled)")`; antialiasing stays on; `dragPixels(from: (240,70), to: (380,70))`; `press("toolOptions.finish")` → rows + `"Line/Curve"`.
4. **Text.** `setPrimaryColor(hex: "000000")`; `selectTool("text")`; `replaceText("toolOptions.fontSize", with: "24")`; `clickPixel(30, 80)`; type `Bug` (each key through `shortcut`, which returns false while the Text tool edits, then `key` to the canvas, as in 0040); ⌘↩ → rows + `"Text"`.
5. **Highlight.** `setPrimaryColor(hex: "FFFF00")`; `selectTool("shapes")`; `choosePopUpItem("toolOptions.shapeType", "Rectangle")`; `choosePopUpItem("toolOptions.drawMode", "Filled Shape")`; `choosePopUpItem("toolOptions.blendMode", "Multiply")`; `setCheckbox("toolOptions.antialiasing", on: false)`; `dragPixels(from: (200,100), to: (360,200))`; `press("toolOptions.finish")` → rows + `"Shapes"`.
6. **Export.** `saveAs("annotated", format: .png)` (the document has one layer, so no flatten prompt) → `decodeImage(at: …/annotated.png)`.

Assertions on the exported file (E), with C the cropped fixture:
- 400×240, DPI 96, profile name contains "sRGB", type `public.png`, 1 frame.
- **Highlight (exact colors, ±1 px position):** shape corners snap to whole pixels by rounding half away from zero (0039), so each edge may land 1 px off. For every pixel in x 203…357, y 103…197: `E == (C.r·255+127)/255 …` i.e. `multiply(C, (255,255,0))` = `(C.r, C.g, 0, 255)`. Spot values: (280,150) == (128,128,0,255) (button), (210,110) == (255,255,0,255) (white). For every pixel in the 2-px ring just outside x 197…363, y 97…203 (i.e. the rect x 197…363 × y 97…203 minus x 199…361 × y 99…201): `E == C`.
- **Arrow (exact color, tolerant geometry):** column x 300 (shaft) has a run of 5–7 consecutive pixels exactly (255,0,0,255) inside y 63…77, and no red outside y 60…80. Column x 360 (20 px behind the tip; head half-width there ≈ 10 px, from 0038's 5 × max(6,2) = 30 px head) has ≥ 14 consecutive exactly red pixels. Columns x ≤ 233 and x ≥ 387 contain no pixel with r > 200 && g < 60 in y 40…100.
- **Text (bounded):** inside the box B = x 22…190, y 62…150, ≥ 150 pixels differ from C, ≥ 10 are exactly (0,0,0,255), and every pixel that differs from C has r == g == b (black text antialiased on white gives only grays). Font rasterization varies with the macOS version, so the test asserts no exact glyph pixels.
- **Nothing else changed:** every pixel outside B, outside the arrow allowance box x 234…386 × y 40…100, and outside the highlight box x 197…363 × y 97…203 equals C exactly. This proves the crop offset pixel-for-pixel.

#### UC-2 `UseCase2PhotoAdjustExportJPEGTests.useCase2AdjustSharpenResizeExportJPEG`

Fixture `photo.png`, 400×300, opaque, "photo-like". Background pixel (x, y) = `(clamp(x·255/399 + n), clamp(y·255/299 + n), clamp(160 − (x+y)/8 + n), 255)`, where `n` is SeededRandom(51) noise in −12…12 drawn once per pixel in row-major order, so the texture is seeded and deterministic. Four flat blocks overwrite it: B1 x 20…179, y 20…119 = (157,101,0); B2 x 220…379, y 20…119 = (0,151,200); B3 x 20…179, y 160…259 = (101,101,101); B4 x 220…379, y 160…259 = (250,157,151). The block colors were chosen so that after Levels every channel lands on a Curves table entry that 0034's tests pin down. A PNG keeps the oracle inputs exact. JPEG decoding is covered by 0002/0029, see Open question 3.

Every stage is captured with `copyAndReadPasteboard()` (Copy with no selection copies the whole layer and adds no history step, per 0021). `I_k` is the copy after stage k. `I_0` must equal the fixture exactly, which proves the copy path is lossless.

1. Open the fixture, `actualSize()`; `I_0`.
2. **Levels** ⌘L → type `200⇥` into `effectDialog.levels.inputWhite`; wait for `effectDialog.progress` "idle"; `effectDialog.ok` → rows `["Open Image", "Levels"]`. **`I_1 == levels(inputHigh: 200)` applied to `I_0`, every pixel exactly.** Blocks: B1 (200,128,0), B2 (0,192,255), B3 (128,128,128), B4 (255,200,192).
3. **Curves** ⇧⌘M → `choosePopUpItem("effectDialog.curve.mode", "RGB")`; Red, Green, Blue stay checked; a synthesized click on the plot view at offset (128, 63) from its top-left corner → `effectDialog.curve.coordinates` "(128, 192)" and the plot value lists (128, 192) for all three channels; wait idle; OK → rows + `"Curves"`. `I_2` block interiors (all pixels of the block) are exact: B1 (238,192,0), B2 (0,235,255), B3 (192,192,192), B4 (255,238,235). Elsewhere `I_2` is used as observed, because only those five table entries are independently pinned.
4. **Hue / Saturation** ⇧⌘U → `replaceText("effectDialog.hue.field", with: "30")`, `replaceText("effectDialog.saturation.field", with: "130")`, Lightness stays 0; wait idle; OK → rows + `"Hue / Saturation"`. **`I_3 == hueSaturation(I_2, hue: 30, saturation: 130, lightness: 0)` exactly, every pixel.** Blocks (hand-computed from 0032's formula): B1 (182,255,0), B2 (0,127,255), B3 (191,191,191), B4 (255,247,229).
5. **Sharpen** Effects ▸ Photo ▸ Sharpen… (`runMenuItem("Effects", "Photo", "Sharpen…")`) → `replaceText("effectDialog.amount.field", with: "3")`; wait idle; OK → rows + `"Sharpen"`. **`I_4 == sharpen(I_3, amount: 3)` exactly, every pixel** (0042: the GPU equals the oracle with 0 differences). Block interiors at least 3 px from a block edge: each channel `c → c == 0 ? 0 : (c == 255 ? 255 : c − 1)` (flat median = c + 1, the 3.36 quirk): B1 (181,255,0), B2 (0,126,255), B3 (190,190,190), B4 (255,246,228).
6. **Resize** ⌘R → `resizeImageDialog`; `resizeImage.resampling` is "Bicubic" (the default); `replaceText("resizeImage.percentage", with: "50")`; `press("resizeImage.ok")` → `statusBar.imageSize` "200 × 150"; rows + `"Resize Image"`. `I_5` is 200×150. Block interiors in output coordinates (B1 x 13…86, y 13…56; B2 x 113…186, y 13…56; B3 x 13…86, y 83…126; B4 x 113…186, y 83…126) equal the step 5 block colors **±1 per channel** (0035's bicubic weights are normalized and computed in `Double`, so a constant input stays constant up to rounding).
7. **Export JPEG at a chosen quality.** `saveAs("photo-edited", format: .jpeg)` → the scripted presenter is asked for the JPEG quality; through the dialog's `JPEGOptionsModel` it sets 70, waits (≤ 5 s) until the size label matches `^[0-9,.]+ (bytes|KB|MB)$` and the estimate for 70 is complete, records it as L, and answers OK.

Assertions on `photo-edited.jpg` (J): type `public.jpeg`, 200×150, DPI 96, profile contains "sRGB"; byte count matches L under 0029's rounding rule (|bytes − L·1000| ≤ 500 for KB, exact for bytes, ±500,000 for MB); block cores (each block interior inset by a further 6 px: B1 x 19…80, y 19…50, and so on) are within **±6 per channel** of the `I_5` block colors (JPEG at quality 70 with 4:2:0 on flat regions far from edges; the stated tolerance, never widened). Also, a second export of the same document at quality 95 (`photo-95.jpg`, same flow) is larger than J, which proves the chosen quality was used.

#### UC-3 `UseCase3LayerCompositeTests.useCase3ImportBlendSaveReopenORA`

Fixtures, all 160×120: `base.png` (x, y) = (x·255/159, y·255/119, 96, 255) (integer division); `shade.png` = (200,150,100,255) for x < 80, else (60,120,240,255); `glow.png` = (255,220,0, x·255/159), where alpha 0 at x = 0 carries color (255,220,0,0). The `FixtureFiles` writer must keep straight color under alpha 0. If it can't, the test writes that column as (0,0,0,0) and the oracle uses that, see Edge cases.

1. Open `base.png`, `actualSize()`; the Layers and History panel models are bound to the document.
2. Layers ▸ Import From File… with `ScriptedOpenPanelPresenter` returning `shade.png` → `layerRow.1` label "shade" (0030 names the layer after the file). Again with `glow.png` → `layerRow.2` "glow". Rows `["Open Image", "Import From File", "Import From File"]`.
3. Open Layer Properties for `layerRow.1` (its double-click action; the dialog is captured by the recording `SheetPresenting`) → `choosePopUpItem("layerProperties.blendMode", "Multiply")` → `press("layerProperties.ok")`. Same for `layerRow.2` → "Screen"; `replaceText("layerProperties.opacityField", with: "128")`; OK. Rows + `"Layer Properties"`, `"Layer Properties"`.
4. **Composite before saving:** Edit ▸ Copy Merged → private-pasteboard image P1. Oracle: `K = compose(compose(base, shade, 255, multiply), glow, 128, screen)` per pixel. **P1 == K exactly.** Spot values (hand-computed): (80,60) = (86,102,90,255) (base (128,128,96) → multiply (30,60,90) → screen with Sa = mul255(128,128) = 64); (40,30) = (76,61,38,255); (0, y): glow Sa = 0, so the pixel is `multiply(base, (200,150,100))`.
5. **Save .ora:** `saveAs("composite", format: .openRaster)` → `composite.ora` exists; `isDocumentEdited == false` (so ⌘W would not prompt); close the document.
6. **Reopen:** `DocumentHarness.open(composite.ora)` → one document; `layerRow.0` "base", `.1` "shade", `.2` "glow"; open Layer Properties for each row in turn and read `layerProperties.blendMode` / `.opacityField` ("Normal"/"255", "Multiply"/"255", "Screen"/"128"), cancelling each time; rows `["Open Image"]`.
7. Copy Merged → P2. **P2 == K exactly** (round trip; opacity 128 → 0.502 → 128 per D-18).

#### UC-4 `UseCase4ClipboardRoundTripTests.useCase4PasteEditCopy`

Clipboard source S, 120×80, straight RGBA: x < 20 → (0,0,0,0); 20 ≤ x < 40 → (255,0,0,128) (channel values 0/255 only, so a premultiplied PNG round trip is exact); x ≥ 40 → (x·2, y·3, 200, 255).

1. **No** document open. Write S to the harness's private pasteboard (`writeImage(width: 120, height: 80, pixel: S, to:)`).
2. Edit ▸ Paste into New Image (its action on the document controller, `showsWindows = false`) → one document; `statusBar.imageSize` "120 × 80"; rows `["New Image", "Paste"]`. Return (`key("\r")` to the canvas) → rows + `"Finish Pixels"`. Deselect → rows + `"Deselect"`.
3. `actualSize()`.
4. Adjustments ▸ Invert Colors (⇧⌘I) → + `"Invert Colors"`.
5. `selectTool("pencil")`; primary is black after reset (0007); `dragPixels(from: (10,70), to: (100,70))` → + `"Pencil"`.
6. `selectTool("rectangleSelect")`; `dragPixels(from: (60,10), to: (79,29))` → + `"Rectangle Select"`; ⌫ (through `shortcut`) → + `"Erase Selection"`; `statusBar.selectionSize` "" (Erase Selection deselects, 0018).
7. Copy (no selection: the whole layer) → the private pasteboard's types contain `public.png` and `public.tiff`; its PNG = Q.

Oracle: `W = compose(white 120×80, S, 255, normal)` (white Background plus the Normal-composited paste: x < 20 → (255,255,255,255); 20…39 → (255,127,127,255) by hand; x ≥ 40 → S); then `invert`; then pixels (10…100, 70) = (0,0,0,255); then x 60…79 × y 10…29 = (0,0,0,0). **Q equals that exactly, 120×80, including the alpha-0 rectangle.** Spot values: (5,5) = (0,0,0,255); (30,5) = (0,128,128,255); (50,40) = (155,135,55,255); (70,20) = (0,0,0,0); (50,70) = (0,0,0,255).

#### UC-5 `UseCase5UndoHistoryTests.useCase5UndoAndHistoryJump`

Fixture `steps.png`, 64×48, opaque white. `S_k` is the oracle state after step k (`S_0` = fixture). Every check is `saveInPlaceAndDecode(steps.png, expected: S_k)`, exact size and every pixel. The History panel is shown.

1. Open the fixture, `actualSize()`, `setPrimaryColor(hex: "FF0000")`, then `shortcut("p")` with the document window as key window and the canvas as first responder → the Pencil is active (the one key shortcut in the suite).
2. Steps, each followed by an `S_k` check and the full row list:
   1. Pencil `dragPixels((4,10), (40,10))` → "Pencil" (row 10, x 4…40 red).
   2. `selectTool("rectangleSelect")`, `dragPixels((8,20), (23,35))` → "Rectangle Select" (`S_2 == S_1`; `statusBar.selectionSize` "16 × 16").
   3. ⌥⌫ → "Fill Selection" (x 8…23, y 20…35 red).
   4. ⌘D → "Deselect".
   5. ⇧⌘I → "Invert Colors" (white → (0,0,0,255), red → (0,255,255,255)).
   6. Image ▸ Flip Horizontal → "Flip Horizontal".
   7. Rotate 90° Clockwise (⌘]) → "Rotate 90° Clockwise" (48×64).
   8. `selectTool("pencil")`, `clickPixel(5,5)` → "Pencil".
   9–28. 20 more Pencil clicks at (2 + 2i, 60), i = 0…19 → 20 rows "Pencil". One check of `S_28` after the last click. Row count 29.
3. **Undo:** `perform(undo)` ×20 → `S_8`; the undo manager's `undoMenuItemTitle` is "Undo Pencil". Then one undo at a time → `S_7` … `S_0`, checking each state. Before each undo the title is "Undo <row name>" ("Undo Rotate 90° Clockwise", …, "Undo Pencil"). At `S_0`: row 0 `current`, rows 1…28 `undone`, Undo disabled.
4. **Redo:** `perform(redo)` ×3 → `S_3`; the redo title reads "Redo Deselect".
5. **History panel jumps:** `pressHistoryRow(7)` → `S_7`, row values `done`×7, `current`, `undone`×21. `pressHistoryRow(28)` → `S_28`. `pressHistoryRow(0)` → `S_0`. `pressHistoryRow(5)` → `S_5`.
6. **A new action discards the undone steps (H-2):** at `S_5` (64×48), `clickPixel(20,20)` with the Pencil → rows = the first 6 names + "Pencil" (7 rows), row 6 `current`; Redo disabled; pixels = `S_5` with (20,20) red. Undo → `S_5`, row 6 `undone`.

### 5. Headless P0 coverage test (test target, Swift Testing)

- **`PaintDotMacTests/Acceptance/PRDRequirementParser.swift`** (test support, Foundation only): `struct PRDRequirementParser { static func p0Keys(in markdown: String) -> Set<String>; static func useCaseKeys(in markdown: String) -> [String] }`. Rules, all line-based:
  1. **Priority tables:** a table whose header row's **last** cell is `Pri`. Each data row whose first cell matches `^[A-Z]+-[A-Z0-9]+$` and whose last cell contains `P0` (so `P0 / P1` counts, as for F-6) contributes that ID. Tables without a `Pri` last header cell are ignored, so §10's "R-4 … Hold to the P0 list" is not a requirement.
  2. **Bold P0 labels:** every match of `\*\*([^*]+?) \(P0\)` contributes the trimmed label (`TOOL-A`…`TOOL-C`, `FX-A`…`FX-E`, `FMT-A`…`FMT-E`, `Saving`). A line matching `^(.+?) \*\*\(P0\)\*\*` contributes its prefix (`All adjustments`).
  3. **Effects table:** the table under `### 5.9` whose header has a cell `v1.0 (P0)`. Each name in that column (split on `, `, trimmed, empty skipped) contributes `effect:<name>` (`effect:Gaussian Blur`, … , `effect:Clouds`).
  4. **NF table:** the table under `## 6.` with header `| ID | Category | Requirement |`. Every `NF-n` row counts as P0 (Open question 1).
  5. **Use cases:** the numbered list under `### Key use cases` → `UC-1`…`UC-n`.
  As of this spec the PRD yields 101 P0 keys (68 table IDs, 14 bold labels, "All adjustments", 9 effects, NF-1…NF-9) and UC-1…UC-5.
- **`PaintDotMacTests/Acceptance/P0CoverageMap.swift`**: `enum P0CoverageMap { static let entries: [(key: String, tests: [String])] }`. Each test reference is `"<FileStem>/<functionName>"`, for example `"CropToSelectionWindowIntegrationTests/menuEnablement"`. It's an array of tuples rather than a dictionary literal, so duplicate keys are reported by the test instead of trapping. The implementer fills it from the acceptance criteria of `docs/specs/done/*_COMPLETED.md` (every criterion names its tests, and every spec header names its requirement IDs), choosing for each key the tests that actually prove it, with a window-level integration test included wherever one exists. Minimum required entries (verified against those specs when filling the map): `UC-1` → `UseCase1ScreenshotAnnotationTests/useCase1CropAnnotateExportPNG` (and UC-2…UC-5 likewise); `IMG-1`, `T-17`, `T-18`, `T-19`, `F-2` include UC-1; `ADJ-7`, `ADJ-4`, `ADJ-5`, `effect:Sharpen`, `IMG-2`, `F-3` include UC-2; `L-2`, `L-3`, `L-6`, `F-1`, `FMT-E`, `E-2` include UC-3; `E-2`, `E-5`, `ADJ-6`, `T-13`, `E-4` include UC-4; `E-1`, `H-1`, `H-2`, `H-3`, `IMG-4` include UC-5. NF-1…NF-3 map to 0048's benchmark tests (`PaintbrushFrameBenchmarks/…`, `OpenBenchmarks/testOpen24MPJPEG`, `PanZoomBenchmarks/testPanZoom10Layer4K`, `GaussianBlurBenchmarks/testRadius20On24MP`) plus their Debug performance tests; NF-4 to 0048's `MemoryBenchmarks/testBudgetBoundsFootprint` and 0046's `UndoBudgetLiveTests/loweringDropsOldestInAllDocuments`; NF-5 to 0047's `AutosaveRecoveryTests/recoversTitledPNG` and `AutosaveDocumentTests/autosaveWritesExactOpenRaster`; NF-7 and APP-7 to 0049's `AccessibilityLintIntegrationTests/…`, `AccessibilityCatalogIntegrationTests/…`, and `DisplayOptionsIntegrationTests/…`; NF-8 to 0050's bundle check, which is a script, not a Swift test: reference it as `"script:.agents/skills/spec-implementer/scripts/check-app-bundle.sh#--self-test"` (plus `BundleInfoTests/marketingVersionIsSemantic` and `AppIconTests/iconSourceIsSmall`).
- **`PaintDotMacTests/Acceptance/P0CoverageTests.swift`** (`@Suite struct P0CoverageTests`). The repo root is found from `#filePath` by walking up to the first directory that contains both `PRD.md` and `project.yml`. If it isn't found, the test fails with the paths it tried (never skipped). Tests:
  - `everyP0RequirementIsMapped`: `p0Keys(PRD) ∪ useCaseKeys(PRD) − mapped keys` is empty. The failure lists each missing key.
  - `noStaleOrDuplicateKeys`: every mapped key is in that set, and no key appears twice.
  - `everyReferencedTestExists`: for each reference, exactly one `<FileStem>.swift` exists under `PaintDotMacTests/` or `PaintDotMacBenchmarks/` (0048), and its text matches `func\s+<functionName>\s*\(`. A reference of the form `script:<repo-relative path>#<token>` instead requires that file to exist and contain `<token>` (used only for NF-8's `check-app-bundle.sh`). The failure lists each bad reference with the reason (file missing, ambiguous file, function missing, token missing).
  - `everyKeyHasATest`: no entry has an empty `tests` array.
  - `useCasesMapToTheirEndToEndTests`: `UC-n` includes `UseCase<n>…Tests/useCase<n>…`, for n = 1…5.
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

(Headless runs are faster than the old UI-driven budgets; keep the budgets as upper bounds.)

Determinism controls, all mandatory:
- offscreen window content size 1000×700 pt set by the test; `actualSize()` before pixel-addressed input;
- pixel targets mapped through `viewPoint(forImagePoint:)` and checked with `statusBar.cursorText`;
- a fresh-suite `AppModel` per test (primary black, secondary white, default tool options); the hosted app never restores state;
- seed 51 for all generated texture, printed in failure messages; no random effect is used;
- asynchronous work (effect renders, JPEG estimates, saves) is awaited by completion or a predicate with a 10 s timeout, never a fixed sleep;
- tools are picked with the Tools panel, and pending edits are committed with `toolOptions.finish` or ⌘↩;
- a private pasteboard per test (never `NSPasteboard.general`), released at the end;
- fixtures go in a per-test temp directory, deleted at the end.

### 7. Project and docs

- `project.yml`: no change; the source globs pick up `PaintDotMacTests/Acceptance/` and `PaintDotMacTests/Acceptance/UseCases/`. Run `xcodegen generate`.
- PRD.md: no change by this spec. Open questions 1–3 may add §12 rows; the batch owner records them.
- AGENTS.md *Testing expectations*: add one line, "Every P0 requirement in PRD.md must be listed in `PaintDotMacTests/Acceptance/P0CoverageMap.swift` with at least one test; `P0CoverageTests` fails otherwise."

## Acceptance criteria

- [ ] UC-1 runs through the real UI code in-process (no window shown): Rectangle Select drag → Crop to Selection → Line/Curve with a filled arrowhead → Text → a Shapes highlight rectangle (Filled Shape, Multiply) → Save As PNG; the exported PNG is 400×240 at 96 DPI with sRGB, its highlight pixels equal the Multiply oracle, its arrow/text regions meet the stated bounds, and every other pixel equals the cropped fixture → `UseCase1ScreenshotAnnotationTests.useCase1CropAnnotateExportPNG`
- [ ] UC-2: Levels, Curves, Hue / Saturation and Sharpen each produce the oracle's pixels (Levels, Hue / Saturation and Sharpen every pixel; Curves on the pinned block values); Resize 50% Bicubic gives 200×150 with block interiors ±1; the JPEG export at quality 70 is 200×150, 96 DPI, sRGB, block cores ±6, its size matches the dialog's estimate, and the quality-95 export is larger → `UseCase2PhotoAdjustExportJPEGTests.useCase2AdjustSharpenResizeExportJPEG`
- [ ] UC-3: two images imported as layers, set to Multiply/255 and Screen/128 in Layer Properties; Copy Merged equals the composition oracle exactly before saving and after an `.ora` save → close → reopen, with names, order, blend modes and opacities preserved → `UseCase3LayerCompositeTests.useCase3ImportBlendSaveReopenORA`
- [ ] UC-4: Paste into New Image from a clipboard PNG with transparent and semi-transparent pixels, Invert Colors, a Pencil line, Erase Selection, then Copy; the clipboard holds PNG and TIFF and the PNG equals the oracle exactly, including alpha 0 → `UseCase4ClipboardRoundTripTests.useCase4PasteEditCopy`
- [ ] UC-5: 28 steps (including selection, structural and size-changing steps); every state restored exactly by Undo one step at a time and by Redo; History panel jumps to rows 7, 28, 0, 5 restore exact pixels with correct done/current/undone values; Undo/Redo titles name the step; a new action after a jump discards the undone rows and disables Redo → `UseCase5UndoHistoryTests.useCase5UndoAndHistoryJump`
- [ ] Every P0 key parsed from PRD.md (priority tables, bold P0 labels, P0 effects, NF rows) and every §3 use case maps to at least one test function that exists in the source tree; stale, duplicate, empty, or dangling entries fail with a list → `P0CoverageTests.everyP0RequirementIsMapped`, `.noStaleOrDuplicateKeys`, `.everyReferencedTestExists`, `.everyKeyHasATest`, `.useCasesMapToTheirEndToEndTests`, `.parserFindsSentinelsInRealPRD`
- [ ] The PRD parser follows the stated rules, including the exclusions → `PRDRequirementParserTests.*`
- [ ] The oracles reproduce the hand-computed values in this spec → `UseCaseOracleTests.*`
- [ ] Each use-case test finishes within 3× its budget, and the measured times are recorded → the timing assertion in each test; Verification status

## Edge cases

- **1× vs 2× backing:** the offscreen window's backing scale may be 1 or 2; `viewPoint(forImagePoint:)` uses the window's real transform, and the `statusBar.cursorText` check before each input fails with a message naming the pixel if the mapping is off, never a silent off-by-one.
- **Focus:** commits go through `toolOptions.finish`/⌘↩, and UC-5's single key shortcut is sent with the document window as key window and the canvas as first responder.
- **Asynchronous work:** effect previews (wait for the render to complete), the JPEG estimate (wait for the estimate for the chosen quality), and saves (completion handler) are all awaited.
- **Clean-document save:** if NSDocument skips writing a clean document, its file already holds the current state, and the decode still matches.
- **Alpha-0 color in fixtures:** `FixtureFiles.writePNG` writes straight RGBA via ImageIO. If the implementer finds the writer premultiplies (losing color under alpha 0), `glow.png`'s x = 0 column and UC-4's x < 20 columns are already chosen so the oracle result doesn't depend on that color (Sa = 0 leaves the destination; Normal over white with alpha 0 gives white). Semi-transparent source pixels use only channel values 0/255, so premultiplication round-trips exactly.
- **Text rendering differences** between macOS versions: UC-1 asserts a bounded region, a minimum count, exact black presence, and gray-only antialiasing, never glyph pixels.
- **Shape and line rounding:** ±1 px positional tolerance (half-away rounding of the pointer location in 0039, raw location for Line/Curve in 0038); colors stay exact; check pixels are ≥ 3 px inside or outside an edge.
- **Earlier specs' unresolved questions:** the UC-2 Sharpen expectation follows 0042's normative definition (including the `+1` quirk, 0042 Open question 2), and UC-4 follows 0021's recommended answers 3–4. If either was resolved differently when built, update the oracle to the shipped, PRD-recorded behavior and say so in the Verification status. Never loosen a tolerance to absorb a difference.
- **PRD evolution:** a new P0 row fails `everyP0RequirementIsMapped` until mapped; a removed row fails `noStaleOrDuplicateKeys`; a renamed test fails `everyReferencedTestExists`. This is intended.
- **PRD/project not found** from `#filePath` (for example tests run from an archive): fail with the searched paths, never skip.
- **A failed use-case step** stops the test (`#require`), and the cleanup still closes documents, deletes fixtures, and releases the private pasteboard.

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
- **Oracle self-tests — `PaintDotMacTests/Acceptance/UseCaseOracleTests.swift`** (Swift Testing; it guards the oracles with hand values from this spec): `levels(200)` of 157/101/151/250/0 → 200/128/192/255/0; `hueSaturation` of (238,192,0), (0,235,255), (192,192,192), (255,238,235) at 30/130/0 → (182,255,0), (0,127,255), (191,191,191), (255,247,229); identity 0/100/0 → input; `sharpen` of a flat 9×9 image of value 100 (alpha 255), amount 3 → every pixel 99, alpha 255; flat 0 → 0; flat 255 → 255; a 1×1 image → unchanged; `compose(normal)` (255,0,0,128) over white → (255,127,127,255); `compose(multiply)` base (128,128,96,255) with (60,120,240,255) → (30,60,90,255); then `screen` with (255,220,0,128) at opacity 128 → (86,102,90,255); `compose` with Sa = 0 returns dst bit-identically; `rotate90Clockwise` of a 3×2 labelled image gives the 0037 pixel-map table's result; `flipHorizontal` twice = identity.
- **Integration (headless) — `PaintDotMacTests/Acceptance/UseCases/`**: the five tests in Scope §4, each asserting the history row list after every step and the exact pixels listed there.
- **Round-trip/property:** UC-3 covers the `.ora` round trip of the composite end to end, and UC-5 covers undo → redo → jump identity end to end. The per-feature property tests stay in their specs.
- **Performance:** the per-test wall-time guard (3× budget). No NF metric is measured here (0048 owns NF-1…NF-3).
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build, no warnings, all tests pass, none skipped, no crash report during the run. Also run `--sanitizers --release` at the end of the batch, as AGENTS.md requires; sanitizers report UNAVAILABLE on this Mac, which isn't a failure.
- **Manual verification** (§9's qualitative criteria can't be automated):
  1. Do use cases 1–5 by hand on a real screenshot, a real camera JPEG, three real photos, and a real clipboard image from another app (Preview/Safari). Each completes without leaving the app, and the results open correctly in Preview (PNG/JPEG) and Krita or GIMP (`.ora`).
  2. Give a Paint.NET user the app with no instructions and ask them to find every P0 tool and menu item (§9). Note anything they couldn't find.
  3. Record each use-case test's wall time in the Verification status.

## Open questions

None. All former open questions were approved by the user on 2026-11-15 ("accept all") and are recorded in PRD §12 as D-77. The recommendations quoted there are the binding behavior and are already written into this spec.

## Out of scope

- New product behavior of any kind. A use case that fails because a feature is wrong is fixed in that feature's code, with the fix recorded against its spec ID.
- Measuring NF-1…NF-3 (0048), the accessibility audit (0049), and bundle size (0050). This spec only maps them in the coverage table.
- P1/P2 requirements (0052–0069), docked panels (0052), and WebP export (0063).
- Krita/GIMP interoperability automation (manual step 1; 0028 owns the `.ora` format tests).
