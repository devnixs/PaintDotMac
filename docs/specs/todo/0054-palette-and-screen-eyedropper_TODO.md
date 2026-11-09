# 0054 — Add the 96-color palette (load/save/reset, Add Color) and the screen eyedropper to the Colors panel

> Source: PRD.md §5.10 C-3 ("Default palette of 96 colors (Paint.NET style). Palettes can be saved and loaded.", P1), C-4 ("An eyedropper that picks colors from anywhere on screen (`NSColorSampler`).", P1), C-1 (colors app-wide, persisted, not history steps); §5.1 APP-2; §5.12 / AGENTS.md rule 9; §4 Testing row (debug hooks); §8 v1.x; §12 D-20 (custom SwiftUI color controls), D-26 (v1.x planned), D-31 (active slot), D-37 (`-UITestResetDefaults` clears `colors.`).
> Paint.NET docs: Working with Palettes <https://paint.net/doc/latest/WorkingWithPalettes.html>, Colors Window <https://paint.net/doc/latest/ColorsWindow.html>. Default palette list: transcribed from a palette file saved by Paint.NET (`PaintNet.txt` in Cyotek's ColorPicker test data, <https://www.cyotek.com/downloads/view/Cyotek.Windows.Forms.ColorPicker-1.0.2.0.zip/Cyotek.Windows.Forms.ColorPicker/Cyotek.Windows.Forms.ColorPicker.Tests/data/PaintNet.txt>); see Open question 1.
> Milestone: v1.x
> Depends on: 0051-use-case-acceptance-tests (end of v1.0; everything below exists). Directly builds on 0007 (Colors panel), 0045 (ShortcutTable), 0049 (AccessibilityCatalog / KeyboardNavigationPlan), 0052 (Colors pane may be docked).

## Context

Not yet implemented. When this spec starts, these exist (read the done specs; their real names win over this list if they differ):

- **0007** `PaintDotMac/Core/Model/ColorSelection.swift` (`ColorSlot` `.primary/.secondary` with `.other`, `ColorSelection`, `ColorKeyCommand`, `@MainActor struct ColorSelectionStore` with keys `colors.primary`, `colors.secondary`, `colors.panelExpanded`), `Core/Model/ColorHex.swift` (`format(_:includeAlpha:)`, CSS order `#RRGGBBAA`), `Core/Model/ColorEditorState.swift` (`setColor(_:for:)`, `activeSlot`), `App/AppModel.swift` (`colorEditor`, `colors`, `setColor(_:for:)`, `colorsPanelExpanded`, injected `ColorSelectionStore`), `UI/ColorsPanelView.swift` (compact "Less" / expanded "More" layouts, `colors.moreLess`, swatch ids `colors.primary/secondary` whose accessibility value is `#RRGGBBAA`), `UI/ColorWheelView.swift`, `App/LaunchOptions.swift` (`resettableKeyPrefixes` = `["tool.", "panel.", "NSWindow Frame panel.", "colors.", "settings."]`), `PaintDotMacUITests/Support/UITestApp.swift` (`launch(opening:resetDefaults:extraArguments:)`, `openColorsPanel()`, `expandColorsPanel()`). 0007 explicitly defers C-3/C-4 to this spec (`0007…:232`) and notes that Paint.NET palette **files** use `AARRGGBB`, unlike the hex box (`0007…:26`).
- **0012** Color Picker tool picks from the canvas only and defers the screen eyedropper here (`0012…:185`).
- **0045** `Core/Shortcuts/ShortcutTable.swift` (`ShortcutEntry`, contexts incl. `.pointer` documentation rows in section `.canvasAndPointer`, `docs/shortcuts.md` generated from the table).
- **0049** `Core/Accessibility/AccessibilityCatalog.swift` (`AccessibilityEntry`, surface `.colorsPanel`, roles, value formats incl. `colorHex8`), `KeyboardNavigationPlan.swift` (colorsPanel compact/expanded Tab order), `Core/Accessibility/AccessibilityText.swift` (`colorHelp(_:)`), `PaintDotMacUITests/Support/AuditExclusions.swift`, `AccessibilityCatalogUITests.testNoUncataloguedOrUnlabelledControls` (fails for any uncatalogued identifier — so every identifier added here must be catalogued in the same change).
- **0052** may host `ColorsPanelView` in the right dock column (width 180–480 pt); the view must lay out at any width in that range.

### Paint.NET behavior this mirrors (cited pages)

- "Paint.NET palettes contain 96 colors." In the compact Colors window only the **first 32** are visible; expanded (More ») shows all **96**. (Colors Window, Working with Palettes)
- "Left click on a color shade to load it into the **Active** color slot. Right clicking will load the color shade into the **Inactive** color slot." (Colors Window). Note: the slot is the active/inactive slot (D-31), not always primary/secondary. Control-click = right-click (0006 convention).
- **Add Color**: clicking the Add Color icon (tinted with the active color) starts an insertion mode; the palette surround blinks; clicking a palette location replaces that swatch with the active color; clicking the icon again exits the mode. (Working with Palettes). Paint.NET documents **no** Shift-click or Ctrl-click on swatches; none is added here.
- **Palette menu** (swatch icon): the custom palettes found in the palettes folder (click a name to load it), **Save Current Palette As...**, **Open Palettes Folder** (creates the folder if missing), **Reset to Default Palette**. (Working with Palettes)
- **File format**: plain text `*.txt`; "Lines that start with a semicolon are comments"; one color per line, 8 hex digits `aarrggbb`; "If there are less than [96], the remaining color slots will be set to white (FFFFFFFF). If there are more, then the remaining colors will be ignored." (Working with Palettes). Paint.NET stores palettes in `Documents\Paint.NET User Files\Palettes`; the Mac equivalent here is `~/Library/Application Support/PaintDotMac/Palettes`.
- Paint.NET has **no** screen-wide eyedropper; C-4 is a PaintDotMac addition using `NSColorSampler`.

Palette and color changes are **not** history steps and don't mark documents edited (C-1; Paint.NET doesn't record them either). The current palette is app-wide and persisted.

## User story

As a PaintDotMac user, I see Paint.NET's 96-color palette in the Colors panel (32 compact, 96 expanded); clicking a swatch loads it into the active color slot and right-clicking into the other slot; I can replace swatches with my current color, save my palette under a name, load it again or any Paint.NET `.txt` palette dropped in the palettes folder, reset to the default, and pick a color from anywhere on my screen with the eyedropper button.

## Scope & changes

### Core (pure Swift, Foundation only, unit-tested)

1. **`PaintDotMac/Core/Model/Palette.swift`** (new)
   ```swift
   public struct Palette: Equatable, Sendable {
       public static let colorCount = 96
       public static let compactCount = 32
       public static let padColor = ColorRGBA8.white            // FFFFFFFF
       public private(set) var colors: [ColorRGBA8]             // invariant: count == 96
       public init(colors: [ColorRGBA8])                        // pads with padColor / truncates to 96
       public static let paintNETDefault: Palette               // the literal list below
       public subscript(index: Int) -> ColorRGBA8 { get }       // precondition 0..<96 (invariant; callers check isValidIndex)
       public static func isValidIndex(_ i: Int) -> Bool
       public mutating func replace(at index: Int, with color: ColorRGBA8)  // no-op for invalid index
   }
   ```
   **`paintNETDefault`** is a literal array (not generated), `AARRGGBB` order, row-major, 16 per row as listed:
   ```
   row 0: FF000000 FF404040 FFFF0000 FFFF6A00 FFFFD800 FFB6FF00 FF4CFF00 FF00FF21 FF00FF90 FF00FFFF FF0094FF FF0026FF FF4800FF FFB200FF FFFF00DC FFFF006E
   row 1: FFFFFFFF FF808080 FF7F0000 FF7F3300 FF7F6A00 FF5B7F00 FF267F00 FF007F0E FF007F46 FF007F7F FF004A7F FF00137F FF21007F FF57007F FF7F006E FF7F0037
   row 2: FFA0A0A0 FF303030 FFFF7F7F FFFFB27F FFFFE97F FFDAFF7F FFA5FF7F FF7FFF8E FF7FFFC5 FF7FFFFF FF7FC9FF FF7F92FF FFA17FFF FFD67FFF FFFF7FED FFFF7FB6
   row 3: FFC0C0C0 FF606060 FF7F3F3F FF7F593F FF7F743F FF6D7F3F FF527F3F FF3F7F47 FF3F7F62 FF3F7F7F FF3F647F FF3F497F FF503F7F FF6B3F7F FF7F3F76 FF7F3F5B
   row 4: 80000000 80404040 80FF0000 80FF6A00 80FFD800 80B6FF00 804CFF00 8000FF21 8000FF90 8000FFFF 800094FF 800026FF 804800FF 80B200FF 80FF00DC 80FF006E
   row 5: 80FFFFFF 80808080 807F0000 807F3300 807F6A00 805B7F00 80267F00 80007F0E 80007F46 80007F7F 80004A7F 8000137F 8021007F 8057007F 807F006E 807F0037
   ```
   Structure (for reviewers): rows 0–1 = black/dark gray/white/gray + 14 hues at ~25.7° steps, full and half value; rows 2–3 = light grays + tints and dark muted shades; rows 4–5 = rows 0–1 repeated with alpha `0x80` (128). Index 0 = black, 16 = white, 64 = (0,0,0,128).

2. **`PaintDotMac/Core/IO/PaletteFileCodec.swift`** (new)
   ```swift
   public enum PaletteFileError: Error, Equatable, Sendable {
       case tooLarge(byteCount: Int)    // > maxByteCount
       case notText                     // undecodable bytes or contains U+0000
       case noColors                    // zero valid color lines
   }
   public enum PaletteLine: Equatable, Sendable { case color(ColorRGBA8), blankOrComment, malformed }
   public struct PaletteDecodeResult: Equatable, Sendable {
       public let palette: Palette
       public let colorLineCount: Int       // valid color lines in the file (may exceed 96)
       public let malformedLineNumbers: [Int] // 1-based; for logging only, never shown
   }
   public enum PaletteFileCodec {
       public static let maxByteCount = 1_048_576
       public static let header: [String]     // the 7 comment lines below, exactly
       public static func parseLine(_ line: Substring) -> PaletteLine
       public static func decode(_ data: Data) throws(PaletteFileError) -> PaletteDecodeResult
       public static func encode(_ palette: Palette) -> Data
   }
   ```
   **Decoding rules** (in order):
   - `data.count > maxByteCount` → `.tooLarge`.
   - Text decoding: UTF-8 BOM `EF BB BF` → strip, decode UTF-8; `FF FE` → UTF-16LE; `FE FF` → UTF-16BE; otherwise UTF-8. Decoding failure, or any U+0000 in the text → `.notText`. Empty data decodes to "" (→ `.noColors`).
   - Split into lines on `\r\n`, `\n`, or a lone `\r` (all three may be mixed in one file). A trailing line terminator does not create an extra line. Line numbers are 1-based.
   - `parseLine`: (a) cut at the first `;` (everything from it on is a comment, so `FF112233 ; red` is a color and `;FF112233` is a comment); (b) trim spaces, tabs, and other `CharacterSet.whitespaces`; (c) empty → `.blankOrComment`; (d) the rest must be **exactly 8** ASCII hex digits (case-insensitive) → `AARRGGBB` → `ColorRGBA8(red: RR, green: GG, blue: BB, alpha: AA)`; or **exactly 6** → `RRGGBB` with alpha 255 (Open question 3); (e) anything else (`#`/`0x` prefix, inner spaces, 7/9 digits, non-hex, full-width digits, two colors on one line) → `.malformed`, line skipped.
   - Colors are taken in file order; the first 96 fill the palette; further color lines are counted but ignored; fewer than 96 are padded with `FFFFFFFF` (`Palette.init(colors:)`).
   - `colorLineCount == 0` → `.noColors` (Open question 3).
   **Encoding rules:** UTF-8, no BOM, CRLF line endings (as Paint.NET writes on Windows), every line terminated (final CRLF included). Content = the 7 `header` lines, then 96 lines of uppercase `AARRGGBB`. `header` is exactly:
   ```
   ; Paint.NET Palette File
   ; Lines that start with a semicolon are comments
   ; Colors are written as 8-digit hexadecimal numbers: aarrggbb
   ; For example, this would specify green: FF00FF00
   ; The alpha ('aa') value specifies how transparent a color is. FF is fully opaque, 00 is fully transparent.
   ; A palette must consist of ninety six (96) colors. If there are less than this, the remaining color
   ; slots will be set to white (FFFFFFFF). If there are more, then the remaining colors will be ignored.
   ```
   (Kept verbatim from Paint.NET's own files so palettes are interchangeable; it is only a comment.)

3. **`PaintDotMac/Core/IO/PaletteLibrary.swift`** (new) — the palettes folder, with injectable URL and `FileManager`:
   ```swift
   public struct PaletteLibraryEntry: Equatable, Sendable { public let name: String; public let url: URL }
   public enum PaletteNameError: Error, Equatable, Sendable { case empty, invalidCharacters, leadingDot, tooLong }
   public enum PaletteName {
       public static func validate(_ raw: String) -> Result<String, PaletteNameError>
       public static func fileName(for name: String) -> String          // name + ".txt"
       public static func displayName(forFileName: String) -> String?   // strips a final ".txt" (case-insensitive); nil if not .txt
   }
   public enum PaletteLibraryError: Error, Equatable, Sendable {
       case file(PaletteFileError), unreadable, folderUnavailable, writeFailed(String)
   }
   public struct PaletteLibrary: Sendable {
       public let folderURL: URL
       public init(folderURL: URL)
       public static func defaultFolderURL(applicationSupport: URL) -> URL   // <appSupport>/PaintDotMac/Palettes
       public func ensureFolder() throws(PaletteLibraryError) -> URL          // createDirectory(withIntermediateDirectories: true)
       public func entries() -> [PaletteLibraryEntry]                         // never throws; missing folder → []
       public func existingEntry(named: String) -> PaletteLibraryEntry?       // case-insensitive name match
       public func load(_ url: URL) throws(PaletteLibraryError) -> PaletteDecodeResult
       public func save(_ palette: Palette, name: String) throws(PaletteLibraryError) -> URL  // ensureFolder + atomic write; overwrites
   }
   ```
   - `PaletteName.validate`: trim whitespace/newlines; empty → `.empty`; contains `/`, `:`, or U+0000 → `.invalidCharacters`; starts with `.` → `.leadingDot`; `fileName(for:).utf8.count > 255` → `.tooLong`; else `.success(trimmed)`.
   - `entries()`: non-recursive `contentsOfDirectory(at:includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey], options: [.skipsHiddenFiles])`; keep regular files (symlinks resolved) whose `displayName(forFileName:)` is non-nil and non-empty; sort by name with `localizedStandardCompare`. Rescanned every time the palette menu opens (no caching, no file watching).
   - `load`: file size checked through `.fileSizeKey` before reading (`> maxByteCount` → `.file(.tooLarge)`); read failure → `.unreadable`; then `PaletteFileCodec.decode`, errors wrapped as `.file(_)`.
   - `save`: `Data.write(to:options: .atomic)`; failure → `.writeFailed(error.localizedDescription)`. The caller confirms overwriting (UI); `save` itself overwrites.

4. **`PaintDotMac/Core/Model/PaletteGridGeometry.swift`** (new) — pure layout/hit-testing for the swatch grid, view coordinates **y down** (SwiftUI):
   - `columns = 16`, `gap = 1.0` pt; `visibleCount(expanded: Bool) -> Int` (32 / 96); `rows(expanded:)` (2 / 6).
   - `swatchSide(forWidth w: Double) -> Double` = `clamp(floor((w − 15 × gap) / 16), 8, 16)`; `w <= 0` → 8.
   - `size(expanded:side:) -> CGSize` = `(16 × side + 15 × gap, rows × side + (rows − 1) × gap)`.
   - `cellRect(index:side:) -> CGRect?` (nil for invalid index): column `i % 16`, row `i / 16`, origin `(col × (side + gap), row × (side + gap))`.
   - `index(at p: CGPoint, side:, expanded:) -> Int?`: nil if `p.x < 0`, `p.y < 0`, or beyond `size`; else `col = min(Int(p.x / (side + gap)), 15)`, `row = Int(p.y / (side + gap))`; a point in the gap after a cell belongs to that cell; nil if `row × 16 + col >= visibleCount`.

5. **`PaintDotMac/Core/Model/PaletteInteraction.swift`** (new)
   ```swift
   public enum PaletteSwatchAction: Equatable, Sendable {
       case loadColor(into: ColorSlot)   // normal click
       case replaceSwatch                // Add Color mode
   }
   public enum PaletteInteraction {
       /// isSecondaryClick = right button or Control-left (0006 convention)
       public static func action(isSecondaryClick: Bool, addColorModeActive: Bool, activeSlot: ColorSlot) -> PaletteSwatchAction
   }
   ```
   Normal mode: primary click → `.loadColor(into: activeSlot)`, secondary → `.loadColor(into: activeSlot.other)`. Add Color mode (either button) → `.replaceSwatch` (with the **active** slot's color); the mode ends after one replacement (Open question 4).

6. **`PaintDotMac/Core/Model/ScreenColorConversion.swift`** (new) — quantizes the sampler's sRGB components:
   `public static func rgba8(red: Double, green: Double, blue: Double, alpha: Double) -> ColorRGBA8` — each component: NaN → 0; clamp to `0...1` (extended-sRGB values from wide-gamut displays clip); `UInt8(Int((c × 255).rounded(.toNearestOrAwayFromZero)))` — **half away from zero**, the same rule as 0007's `HSVColor` (0.5/255 boundaries: 127.5 → 128).

7. **`ColorSelectionStore`** (modify, `Core/Model/ColorSelection.swift`): add key `colors.palette` (`String`) with `func loadPalette() -> Palette` and `func savePalette(_:)`. Stored value = `String(decoding: PaletteFileCodec.encode(palette), as: UTF8.self)`. Load: missing key, non-`String`, or any decode error → `Palette.paintNETDefault`; otherwise the decoded palette (so a stored value is read with the same rules as a file). The `colors.` prefix means `-UITestResetDefaults` already clears it (D-37); `resettableKeyPrefixes` is unchanged.

8. **`PaintDotMac/Core/Shortcuts/ShortcutTable.swift`** (modify, 0045): add two documentation rows in section `.canvasAndPointer`, context `.pointer`, no bindings:
   | id | action | gesture | Paint.NET | status / notes |
   |---|---|---|---|---|
   | `colors.paletteActive` | Load palette color into the active slot | click swatch | Left click | matchesPaintNET |
   | `colors.paletteInactive` | Load palette color into the inactive slot | right-click or ⌃-click swatch | Right click | remapped — "⌃-click = right-click (R-3)." |
   Regenerate `docs/shortcuts.md` the way 0045 prescribes (`RECORD_SHORTCUT_DOCS=1`), and add both rows to 0045's `ShortcutTableTests.everyRowLiteral` literal at the same position. No key shortcut is added for the eyedropper or the palette (Paint.NET has none).

9. **`PaintDotMac/Core/Accessibility/AccessibilityCatalog.swift`** and **`KeyboardNavigationPlan.swift`** (modify, 0049) — `colorsPanel` entries, in visual order after `colors.wheel`:
   - `colors.palette` group "Palette"; `colors.palette.<index>` button, label `.dynamic("Palette color <n>")` with `n = index + 1`, value `colorHex8` (accessibility value `ColorHex.format(c, includeAlpha: true)`), help `AccessibilityText.colorHelp(c)`.
   - `colors.paletteMenu` button "Palette menu"; `colors.addColor` button "Add color" (`isSelectable: true` — `.isSelected` while the mode is on); `colors.screenEyedropper` button "Pick color from screen".
   - Tab order (compact and expanded): insert `colors.paletteMenu, colors.addColor, colors.screenEyedropper` immediately before `colors.moreLess`. Palette swatches are **not** in Tab order (96 stops; same treatment as the wheel, 0049); they are reachable through VoiceOver.
   - `AuditExclusions.swift`: `colors.palette.<index>` gets the `.contrast` exclusion with the same reason as `colors.primary` ("displays arbitrary colors being edited; values available as text").
   - New `AccessibilitySurface` case `savePaletteAlert` (appended after `pasteExpandAlert`), entries in Tab order: `colors.savePalette.name` textField "Palette name" (value `text`), `colors.savePalette.cancel` button "Cancel", `colors.savePalette.save` button "Save"; `KeyboardNavigationPlan.plan(for: .savePaletteAlert)`: initial `colors.savePalette.name`, tabOrder `[name, cancel, save]`, default `colors.savePalette.save`, cancel `colors.savePalette.cancel`. The palette menu's items (`colors.paletteMenu.*`) are menu items and are not catalogued (0049 catalogues no menus; `PaletteUITests.testLoadPaletteFromMenu` checks their titles).
   - Update the exact-plan tests `KeyboardNavigationPlanTests` (colorsPanel compact/expanded) and keep `AccessibilityCatalogTests.identifiersAreUnique` green.

### Platform glue (AppKit/SwiftUI; UI tests + manual checks)

10. **`PaintDotMac/App/AppModel.swift`** (modify) — new state and methods (all `@MainActor`, none touch documents or history):
    - `private(set) var palette: Palette` (loaded from the store in `init`), `private(set) var isAddingPaletteColor = false`, `private(set) var isSamplingScreen = false`, injected `paletteLibrary: PaletteLibrary` and `screenSampler: any ScreenColorSampling` (init parameters with production defaults).
    - `clickPaletteSwatch(index:isSecondaryClick:)` — ignores invalid indices; resolves `PaletteInteraction.action`; `.loadColor(slot)` → `setColor(palette[index], for: slot)` (0007 path; persists colors); `.replaceSwatch` → `palette.replace(at:with: colors[activeSlot])`, `isAddingPaletteColor = false`, `store.savePalette`.
    - `toggleAddPaletteColor()`, `cancelAddPaletteColor()` (Escape while the Colors panel is key, closing/hiding the panel, and starting the screen sampler all cancel the mode).
    - `loadPalette(_ result: PaletteDecodeResult)` → `palette = result.palette`, save; `resetPalette()` → `paintNETDefault`, save. Neither changes primary/secondary or the active slot.
    - `pickScreenColor()` — if `isSamplingScreen` return; cancel Add Color mode; `isSamplingScreen = true`; `screenSampler.sample { color in … }`; on the main actor: `isSamplingScreen = false`; `color != nil` → `setColor(color, for: colorEditor.activeSlot)` (Open question 2); `nil` (Escape/cancel) → nothing changes.
11. **`PaintDotMac/App/ScreenColorSampling.swift`** (new)
    ```swift
    @MainActor protocol ScreenColorSampling { func sample(completion: @escaping @MainActor (ColorRGBA8?) -> Void) }
    @MainActor final class SystemScreenColorSampler: ScreenColorSampling   // wraps NSColorSampler
    @MainActor final class FixedScreenColorSampler: ScreenColorSampling    // #if DEBUG; returns a preset value or nil asynchronously
    ```
    `SystemScreenColorSampler.sample`: keeps a strong reference to one `NSColorSampler` for the session; calls `show(selectionHandler:)`. In the handler (which may run off the main thread): `nil` → cancel; otherwise `color.usingColorSpace(.sRGB)` (AppKit/ColorSync conversion from the sampled display's color space to sRGB with the default rendering intent; `nil` if not convertible → treated as cancel), read `redComponent`/`greenComponent`/`blueComponent`/`alphaComponent` as `Double`, convert with `ScreenColorConversion.rgba8` **before** hopping (so no `NSColor` crosses actors), then `Task { @MainActor in completion(rgba) }`. Sampled screen colors are opaque in practice (alpha 255).
    **Permissions:** `NSColorSampler` is the system-provided picker and is expected to work **without** Screen Recording permission (that is its purpose versus ScreenCaptureKit/`CGWindowListCreateImage`). Do not call `CGRequestScreenCaptureAccess`/`CGPreflightScreenCaptureAccess`, add no Info.plist usage string, and use no capture API. Verified only by the manual check below (no authoritative Apple statement was found during spec writing).
12. **`PaintDotMac/App/LaunchOptions.swift`** (modify, `#if DEBUG`):
    - `-UITestPalettesFolder <path>` → `PaletteLibrary(folderURL: path)` instead of the default, and `PaletteFolderRevealer` (item 14) becomes a no-op that only calls `ensureFolder()` (so UI tests never open Finder or touch the real folder).
    - `-UITestScreenSample <value>` → `FixedScreenColorSampler`; `value` is `#RRGGBB`/`#RRGGBBAA` (parsed with `ColorHex.parse`; 6 digits → alpha 255) or `cancel` (returns nil); unparseable → ignored (system sampler). Missing value or a value starting with `-` follows 0001's argument rules.
    - Production default folder: `PaletteLibrary.defaultFolderURL(applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])` — the array is never empty for the user domain on macOS (comment, no force unwrap: use `.first ?? homeDirectoryForCurrentUser/Library/Application Support`).
13. **`PaintDotMac/UI/ColorsPanelView.swift`** (modify) and **`PaintDotMac/UI/PaletteGridView.swift`** (new):
    - Layout: below the wheel (compact) / below the sliders (expanded): the palette grid (`colors.palette`; 32 swatches compact, 96 expanded, `PaletteGridGeometry.swatchSide(forWidth:)` of the available width), then one row with three icon buttons and the existing More »/« Less button: **palette menu** (SF Symbol `swatchpalette`, tooltip "Palette"), **Add Color** (SF Symbol `plus.square.fill`, tinted with the active slot's color drawn over a checkerboard, tooltip "Add Color"), **eyedropper** (SF Symbol `eyedropper`, tooltip "Pick Color from Screen"), then `colors.moreLess`. Works at any width 180–480 pt (0052 dock) and floating; the floating panel still resizes to `fittingSize` on More/Less (0007).
    - `PaletteGridView`: an `NSViewRepresentable` (needs right-click and Control-click) drawing each swatch over a 4-pt checkerboard (alpha visible) with a 1-pt `swatchBorder` (0049 `ThemeColors`); hit-testing via `PaletteGridGeometry.index(at:…)`; `mouseDown` (left, no ⌃) → `clickPaletteSwatch(index:isSecondaryClick: false)`; `rightMouseDown` or ⌃-left → `true`. Each swatch is an accessibility child element (`NSAccessibilityElement`, role button, identifier `colors.palette.<index>`, label "Palette color <n>", value `#RRGGBBAA`, help `colorHelp`, press action = primary click) so XCUITest can click and read them. While Add Color mode is on, the grid's outline blinks (accent color, 0.5 s period) — static accent outline under Reduce Motion (0049 `MotionPolicy`).
    - Escape while the Colors panel is key and Add Color mode is on → `cancelAddPaletteColor()`.
    - Eyedropper button disabled while `isSamplingScreen`.
14. **`PaintDotMac/UI/PaletteMenuController.swift`** (new, AppKit) — builds an `NSMenu` each time the palette button is clicked (`menu.popUp(positioning:at:in:)` under the button):
    - one item per `paletteLibrary.entries()` (title = entry name, identifier `colors.paletteMenu.palette.<i>` in sorted order), then a separator (omitted when there are no entries);
    - **Save Current Palette As...** (`colors.paletteMenu.save`), **Open Palettes Folder** (`colors.paletteMenu.openFolder`), **Reset to Default Palette** (`colors.paletteMenu.reset`). Titles exactly as Paint.NET (with three ASCII dots as Paint.NET writes them).
    - Load item → `paletteLibrary.load(url)` → `AppModel.loadPalette`; error → `NSAlert` (warning) message `The palette “<name>” couldn’t be opened.`, informative text by error: `.file(.tooLarge)` "The file is larger than 1 MB.", `.file(.notText)` "The file isn’t a text file.", `.file(.noColors)` "The file doesn’t contain any colors.", `.unreadable` "The file couldn’t be read."; palette unchanged.
    - Save → an app-modal `NSAlert` "Save Palette" with an accessory `NSTextField` (identifier `colors.savePalette.name`, placeholder "Palette name", default value empty), buttons **Save** (`colors.savePalette.save`, default) and **Cancel** (`colors.savePalette.cancel`). On Save: `PaletteName.validate`; invalid → keep the alert open with informative text by error (`.empty` "Enter a name.", `.invalidCharacters` "The name can’t contain “/” or “:”.", `.leadingDot` "The name can’t start with a period.", `.tooLong` "The name is too long."); if `existingEntry(named:)` exists → second alert `A palette named “<name>” already exists. Do you want to replace it?` buttons **Replace** / **Cancel** (Cancel returns to nothing saved); then `save`; failure → alert `The palette couldn’t be saved.` with the error text.
    - Open Palettes Folder → `PaletteFolderRevealer.reveal(library)`: `ensureFolder()` then `NSWorkspace.shared.open(folderURL)` (Finder); `ensureFolder` failure → alert `The Palettes folder couldn’t be created.`.
    - Reset → `AppModel.resetPalette()`, no confirmation (Paint.NET has none).
15. **`PaintDotMacUITests/Support/UITestApp.swift`** (modify): `makePalettesFolder() -> URL` (fresh temp dir, removed in teardown), `writePaletteFixture(_ text: String, name: String, in: URL)`, `openPaletteMenu()`, `paletteSwatch(_ index: Int) -> XCUIElement`.
16. `project.yml`: no changes (source globs). Run `xcodegen generate`.
17. **PRD:** no edit in this spec (sub-agent rule). Reported to the orchestrator: PRD §4 Testing row should list `-UITestPalettesFolder` and `-UITestScreenSample`; C-3/C-4 could cite the folder and file rules, and the answers to the Open questions below.

### Cross-cutting rules respected
No pixel changes, nothing goes through history; Core files import Foundation/CoreGraphics only; UI on `@MainActor`, `NSColorSampler` callback hops to the main actor with a `Sendable` `ColorRGBA8`; no `NSColorPanel` (D-20); no new single-key shortcuts (AGENTS.md rule 9). NF-1–NF-4 unaffected.

## Acceptance criteria

- [ ] On first launch the palette is Paint.NET's default 96 colors exactly as listed. → `PaletteTests.defaultPaletteExactValues`, `ColorSelectionStoreTests.missingPaletteLoadsDefault`, `PaletteUITests.testDefaultPaletteShown`
- [ ] Compact shows the first 32 swatches; expanded shows all 96. → `PaletteGridGeometryTests.visibleCounts`, `PaletteUITests.testCompactAndExpandedSwatchCounts`
- [ ] Click loads the swatch into the active slot; right-click / ⌃-click into the inactive slot; after C (switch slot) the targets swap. → `PaletteInteractionTests.*`, `AppModelPaletteTests.clickLoadsActiveAndSecondaryLoadsInactive`, `PaletteUITests.testClickAndRightClickSwatch`, `PaletteUITests.testClickFollowsActiveSlot`
- [ ] Add Color replaces the clicked swatch with the active color, ends the mode, persists; Escape or the button again cancels. → `AppModelPaletteTests.addColorReplacesAndEnds`, `.addColorCancel`, `PaletteUITests.testAddColorReplacesSwatch`
- [ ] Palette files: `;` comments (whole-line and inline), blank lines, CRLF/LF/CR, BOMs, 8-digit `AARRGGBB` and 6-digit lines, malformed lines skipped, fewer than 96 padded with white, more than 96 truncated; empty-of-colors / too large / binary files are refused with an alert and no change. → `PaletteFileCodecTests.*`, `PaletteLibraryTests.*`, `PaletteUITests.testLoadInvalidPaletteShowsAlert`
- [ ] Save Current Palette As... writes `<name>.txt` into the palettes folder in Paint.NET's format (header, 96 uppercase lines, CRLF); name validation and overwrite confirmation work. → `PaletteFileCodecTests.encodeExactBytes`, `PaletteNameTests.*`, `PaletteLibraryTests.saveWritesAtomicallyAndOverwrites`, `PaletteUITests.testSavePaletteWritesFile`, `.testSaveExistingNameAsksToReplace`
- [ ] The palette menu lists `.txt` files in the folder by name (sorted), loading one replaces the palette; Reset to Default Palette restores the default; Open Palettes Folder creates the folder. → `PaletteLibraryTests.entriesFilterAndSort`, `PaletteUITests.testLoadPaletteFromMenu`, `.testResetToDefault`, `.testOpenPalettesFolderCreatesFolder`
- [ ] Default folder is `~/Library/Application Support/PaintDotMac/Palettes`. → `PaletteLibraryTests.defaultFolderPath`
- [ ] The palette persists across relaunch under `colors.palette`; corrupt values fall back to the default; `-UITestResetDefaults` clears it. → `ColorSelectionStoreTests.palette*`, `PaletteUITests.testPalettePersistsAcrossRelaunch`
- [ ] The eyedropper button picks a screen color into the active slot (sRGB, 8-bit, half-away-from-zero); cancel changes nothing; a second click while sampling is ignored. → `ScreenColorConversionTests.*`, `AppModelPaletteTests.pickScreenColor*`, `PaletteUITests.testEyedropperSetsActiveSlot`, `.testEyedropperCancelKeepsColor`; real `NSColorSampler` → manual 1–4
- [ ] No Screen Recording prompt or permission is needed for the eyedropper. → manual 3 (TCC can't be asserted in tests)
- [ ] Palette and eyedropper actions create no history steps and don't mark documents edited. → `PaletteUITests.testPaletteActionsDoNotDirtyDocument`
- [ ] Every new control is catalogued with labels; Tab order includes the three buttons. → `AccessibilityCatalogTests.paletteEntries`, `.savePaletteAlertEntries`, `KeyboardNavigationPlanTests.colorsPanel*`, `.savePaletteAlertPlan`, `AccessibilityCatalogUITests.testColorsPanelMatchesCatalog`, `.testSavePaletteAlertMatchesCatalog` (new: palette menu → Save Current Palette As... → the three `colors.savePalette.*` elements match the dumped catalog; Cancel), `.testNoUncataloguedOrUnlabelledControls`
- [ ] `ShortcutTable` documents the two pointer gestures. → `ShortcutTableTests.paletteRowsDocumented`, `.everyRowLiteral` (updated), `ShortcutDocsTests.docsFileMatchesTable`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- Palette file: 0 bytes, only comments, only malformed lines → `.noColors` alert. 97+ colors → first 96. 1 color → index 0 set, 1–95 white. Alpha `00` entries are legal (transparent swatch over checkerboard). Lowercase hex accepted; written uppercase. Trailing whitespace, tabs, inline comments. Mixed line endings. UTF-16 files (Notepad "Unicode") with BOM. UTF-8 without BOM. Invalid UTF-8 / NUL bytes → `.notText`. Exactly 1 MiB accepted; 1 MiB + 1 → `.tooLarge` (checked from file size before reading).
- Folder: missing (menu lists no palettes; Save and Open Palettes Folder create it); unreadable entries skipped; non-`.txt` files, hidden files, subfolders, `.TXT` (accepted, shown without extension), a file named `.txt` (empty name → skipped); a file deleted between menu open and click → `.unreadable` alert.
- Names: whitespace-only, `/`, `:`, leading `.`, 251+ UTF-8 bytes; emoji and accents allowed; `Mine` vs existing `mine.txt` → replace confirmation (case-insensitive file system).
- Add Color mode + switching slot (C) → replacement uses the slot active at click time. Mode + Load/Reset palette → mode cancelled first. Index out of range → no-op.
- Eyedropper: Escape → nil → no change; non-convertible color → treated as cancel; extended-range components clamp; NaN → 0; repeated clicks while showing → ignored; Add Color mode is cancelled when sampling starts; no document open → button still works (colors are app-wide).
- Narrow dock (180 pt) → swatch side clamps to 8 pt minimum; wide (480 pt) → 16 pt maximum, grid left-aligned.
- Stored `colors.palette` with fewer lines / wrong type / garbage → decode rules / default; never crashes.

## Test plan

Expected values are hand-derived from the rules above; never paste code output.

- **Unit tests** (`PaintDotMacTests/Colors/` unless noted)
  - `PaletteTests`: `defaultPaletteExactValues` — the test holds its own literal list of the 96 `AARRGGBB` strings (copied from this spec, parsed in the test with a tiny local hex parser) and compares every index; spot checks index 0 (0,0,0,255), 3 (255,106,0,255), 16 (255,255,255,255), 63 (127,63,91,255), 64 (0,0,0,128), 95 (127,0,55,128). `initPadsWithWhite` (2 colors → 94 × (255,255,255,255) after); `initTruncates` (100 colors → first 96); `initEmpty` → 96 white; `replaceInRange` / `replaceOutOfRangeIsNoOp` (−1, 96); `isValidIndex` (0, 95 true; −1, 96 false).
  - `PaletteFileCodecTests` (`PaintDotMacTests/IO/`):
    - `parseLine`: `"FF112233"` → (0x11,0x22,0x33,255); `"80aabbcc"` → (170,187,204,128); `"  FF112233\t"` → color; `"FF112233 ; red"` → color; `"; comment"`, `";FF112233"`, `""`, `"   "` → blankOrComment; `"112233"` → (17,34,51,255); malformed: `"#FF112233"`, `"0xFF112233"`, `"FF11 2233"`, `"FF11223"`, `"FF1122334"`, `"GG112233"`, `"FF112233 FF445566"`, full-width `"ＦＦ112233"`.
    - `decodePaintNETSample`: the full Paint.NET-format text (header + the 96 default lines, CRLF) → `palette == .paintNETDefault`, `colorLineCount == 96`, no malformed lines.
    - `decodeLineEndings`: the same 3 colors with `\n`, `\r\n`, `\r`, and mixed → identical palettes; no trailing terminator → same result.
    - `decodeBOMs`: UTF-8 BOM, UTF-16LE BOM, UTF-16BE BOM encodings of `"FF010203\r\nFF040506\r\n"` → colors (1,2,3) and (4,5,6), index 2 white.
    - `decodeShortPadsWhite`: 1 line `FF00FF00` → index 0 (0,255,0,255), indices 1–95 (255,255,255,255).
    - `decodeLongTruncates`: 100 lines `FF0000nn` (nn = 00…63 hex of line index) → index 95 = (0,0,95,255), `colorLineCount == 100`.
    - `decodeSkipsMalformed`: lines `FF000001`, `garbage`, `FF000002`, `#FF000003` → colors 1, 2 at indices 0, 1; `malformedLineNumbers == [2, 4]`.
    - `decodeErrors`: empty `Data()` → `.noColors`; only comments → `.noColors`; `[0xFF, 0xFE, 0x00]` style invalid / bytes `[0x46, 0x00, 0x46]` (NUL) → `.notText`; invalid UTF-8 `[0xC3, 0x28]` → `.notText`; `maxByteCount + 1` bytes of `"F"` → `.tooLarge(byteCount: 1_048_577)`; exactly `maxByteCount` bytes made of valid lines → decodes.
    - `encodeExactBytes`: `encode(.paintNETDefault)` equals the UTF-8 bytes of the 7 header lines + 96 default lines, each followed by `"\r\n"` (expected string assembled in the test from its own literals); first bytes are not a BOM; byte count = sum of line lengths + 2 × 103.
    - `encodeUppercase`: palette with (10,11,255,1) at 0 → second-to-header line `"010A0BFF"`.
    - `roundTrip`: 500 `SeededRandom` palettes (random RGBA per entry, seed printed on failure) → `decode(encode(p)).palette == p`.
  - `PaletteNameTests`: `"  Mine  "` → `"Mine"`; `""`, `"   "` → `.empty`; `"a/b"`, `"a:b"` → `.invalidCharacters`; `".hidden"` → `.leadingDot`; 251 ASCII chars → `.tooLong` (255 bytes with ".txt" = ok at 251? 251 + 4 = 255 → ok; 252 → `.tooLong`) — assert both; `"Café 🎨"` → ok; `fileName(for: "Mine") == "Mine.txt"`; `displayName(forFileName:)`: `"A.txt"` → `"A"`, `"A.TXT"` → `"A"`, `"A.txt.txt"` → `"A.txt"`, `"A.pal"` → nil, `".txt"` → `""`.
  - `PaletteLibraryTests` (`PaintDotMacTests/IO/`, temp folder per test): `defaultFolderPath` (`/tmp/x` → `/tmp/x/PaintDotMac/Palettes`); `entriesMissingFolderIsEmpty`; `entriesFilterAndSort` (files `b.txt`, `A.TXT`, `c.pal`, `.hidden.txt`, folder `d.txt/`, `.txt`, `item 10.txt`, `item 2.txt` → names `["A", "b", "item 2", "item 10"]`); `existingEntryCaseInsensitive`; `loadValid`; `loadTooLargeFromSize` (sparse 2 MiB file via `FileHandle.truncate` → `.file(.tooLarge)`); `loadMissingIsUnreadable`; `saveCreatesFolderAndFile` (folder absent before; after: file bytes == `encode(p)`); `saveWritesAtomicallyAndOverwrites` (save twice with different palettes → second content; no temp files left in the folder); `saveFailure` (folder path is an existing regular file → `.folderUnavailable` or `.writeFailed`, no crash).
  - `PaletteGridGeometryTests`: `visibleCounts` (32/96; rows 2/6); `swatchSide` (width 191 → (191−15)/16 = 11; 180 → floor(10.3125) = 10; 100 → 8 (clamp); 480 → 16 (clamp); 0 → 8); `size` (side 10, expanded → (175, 65)); `cellRect` (index 17, side 10 → (11, 11, 10, 10); 96 → nil); `indexAt` (side 10: (0,0) → 0; (10.5, 0) gap → 0; (11, 0) → 1; (174, 0) → 15; (0, 11) → 16; compact (0, 22) → nil (row 2 not visible), expanded → 32; (−1, 0) → nil; (176, 0) → nil).
  - `PaletteInteractionTests`: activeSlot .primary: primary click → `.loadColor(into: .primary)`, secondary → `.loadColor(into: .secondary)`; activeSlot .secondary: primary → `.secondary`, secondary → `.primary`; addColor mode, both buttons → `.replaceSwatch`.
  - `ScreenColorConversionTests`: (1, 0, 0, 1) → (255,0,0,255); (0.5, 0.5, 0.5, 1) → 127.5 → (128,128,128,255); (0.25, 0.75, 0.1, 1) → (63.75→64, 191.25→191, 25.5→26, 255); (127/255, 128/255, 0, 1) → (127,128,0,255) exactly; (−0.1, 1.2, .nan, 0.5) → (0,255,0,128) (0.5 × 255 = 127.5 → 128); (0.001, 0.999, 0.002, 1) → (0,255,1,255) (0.255→0, 254.745→255, 0.51→1).
  - `ColorSelectionStoreTests` (extend): `missingPaletteLoadsDefault`; `paletteRoundTrip` (save modified palette → new store loads equal); `paletteStoredAsFileText` (raw string starts with `"; Paint.NET Palette File\r\n"` and contains `"\r\nFF000000\r\n"`); `paletteCorruptFallsBack` (`"garbage"` → default; `Int 42` → default); `paletteShortStoredValuePads` (`"FF00FF00"` → index 0 green, rest white).
  - `AppModelPaletteTests` (`@MainActor`, suite-backed store, temp `PaletteLibrary`, `FixedScreenColorSampler`): `clickLoadsActiveAndSecondaryLoadsInactive` (index 2 → primary (255,0,0,255); secondary click index 17 → secondary (128,128,128,255)); `clickFollowsActiveSlot` (after `switchActiveColorSlot()`, primary click index 2 → secondary red, primary unchanged); `addColorReplacesAndEnds` (primary (51,102,204,255), toggle, click index 5 → palette[5] == that color, `isAddingPaletteColor == false`, colors unchanged, new store loads palette[5] equal); `addColorCancel` (toggle twice → off; toggle + `cancelAddPaletteColor` → off; palette unchanged); `loadAndResetDoNotChangeColors`; `invalidIndexIgnored` (−1, 96, palette and colors unchanged); `pickScreenColorSetsActiveSlot` (sampler returns (1,2,3,255); with active .secondary → secondary set, primary unchanged, persisted); `pickScreenColorCancel` (nil → all unchanged, `isSamplingScreen == false` afterwards); `pickScreenColorReentrancy` (sampler that holds its completion: second `pickScreenColor()` doesn't call `sample` again — call count 1); `pickScreenColorCancelsAddMode`.
  - `ShortcutTableTests` (extend, 0045): `paletteRowsDocumented` — `entry(id: "colors.paletteActive")` and `"colors.paletteInactive"` exist, context `.pointer`, no bindings, gestures "click swatch" / "right-click or ⌃-click swatch"; existing conflict/duplicate tests stay green.
  - 0049's `AccessibilityCatalogTests` / `KeyboardNavigationPlanTests` (extend): `paletteEntries` — new colorsPanel identifiers present with the labels above, in visual order after `colors.wheel`; `savePaletteAlertEntries` — the three `colors.savePalette.*` entries with surface `.savePaletteAlert`; `savePaletteAlertPlan` — initial name field, tabOrder [name, cancel, save], default save, cancel cancel (0049's `dialogsHaveDefaultAndCancel` style); colorsPanel compact plan `[colors.primary, colors.secondary, colors.swap, colors.reset, colors.paletteMenu, colors.addColor, colors.screenEyedropper, colors.moreLess]`; expanded inserts the 0049 hex/slider list before `colors.paletteMenu`.
- **Round-trip / property tests:** `PaletteFileCodecTests.roundTrip`, `ColorSelectionStoreTests.paletteRoundTrip` (seeded, seed printed).
- **Golden-image tests:** none (no image rendering).
- **Integration tests:** `AppModelPaletteTests` exercises store + library + sampler headlessly (save via library, reload in a new `AppModel`, pick, persist).
- **UI tests** (`PaintDotMacUITests/PaletteUITests.swift`; every test launches with a small generated PNG fixture, `-UITestResetDefaults`, `-UITestPalettesFolder <fresh temp dir>`, and opens the Colors panel; tests needing 96 swatches call `expandColorsPanel()`):
  - `testDefaultPaletteShown`: `colors.palette.0` value `#000000FF`, `.2` `#FF0000FF`, `.16` `#FFFFFFFF`, `.31` `#7F0037FF` (the hex box/accessibility use CSS order `RRGGBBAA`).
  - `testCompactAndExpandedSwatchCounts`: compact — `colors.palette.31` exists, `.32` doesn't; expanded — `.95` exists (value `#7F003780`), `.96` doesn't.
  - `testClickAndRightClickSwatch`: click `.2` → `colors.primary` `#FF0000FF`; right-click `.11` → `colors.secondary` `#0026FFFF`, primary unchanged.
  - `testClickFollowsActiveSlot`: press C (canvas focused, Pan tool), click `.2` → secondary `#FF0000FF`, primary `#000000FF`.
  - `testAddColorReplacesSwatch`: set hex `#3366CC`; click `colors.addColor` (now selected) → click `.5` → `.5` value `#3366CCFF`, `colors.addColor` not selected; relaunch without reset (keep the folder argument) → `.5` still `#3366CCFF`.
  - `testSavePaletteWritesFile`: Add Color into `.0` with `#123456`; palette menu → "Save Current Palette As..." → type `Mine` in `colors.savePalette.name` → Save → the test reads `<folder>/Mine.txt`: begins with `"; Paint.NET Palette File\r\n"`, contains 103 CRLF-terminated lines, line 8 is `FF123456`, line 9 `FF404040`.
  - `testSaveExistingNameAsksToReplace`: pre-write `Mine.txt` (1 color); save as `mine` → replace alert appears; Cancel → file unchanged (byte compare); again → Replace → file has 103 lines.
  - `testSaveInvalidNameKeepsDialog`: name `a/b` → Save → alert still shown with "The name can’t contain “/” or “:”."; Cancel → no file in folder.
  - `testLoadPaletteFromMenu`: fixture `Warm.txt` = `"; test\r\nFFFF0000\nFF00FF00\r80112233\r\n"` and `Cool.txt`; open menu → items "Cool", "Warm" in that order before "Save Current Palette As..."; choose Warm → `.0` `#FF0000FF`, `.1` `#00FF00FF`, `.2` `#11223380`, `.3` `#FFFFFFFF`; primary/secondary unchanged.
  - `testLoadInvalidPaletteShowsAlert`: fixture `Bad.txt` = `"; only comments\n"` → choose → alert "The palette “Bad” couldn’t be opened." with "The file doesn’t contain any colors."; OK → `.0` still `#000000FF`.
  - `testResetToDefault`: load Warm, then "Reset to Default Palette" → `.0` `#000000FF`, `.2` `#FF0000FF`.
  - `testOpenPalettesFolderCreatesFolder`: launch with `-UITestPalettesFolder <tmp>/sub/Palettes` (absent) → menu "Open Palettes Folder" → the folder exists (FileManager in the test), no Finder window required.
  - `testPalettePersistsAcrossRelaunch`: load Warm, terminate, relaunch without `-UITestResetDefaults` → `.0` `#FF0000FF`; relaunch with reset → `.0` `#000000FF`.
  - `testEyedropperSetsActiveSlot`: launch with `-UITestScreenSample #3366CC` → click `colors.screenEyedropper` → primary `#3366CCFF`; press C, click again → secondary `#3366CCFF`.
  - `testEyedropperCancelKeepsColor`: `-UITestScreenSample cancel` → click → primary `#000000FF`, secondary `#FFFFFFFF`; button enabled again.
  - `testPaletteActionsDoNotDirtyDocument`: click swatch, Add Color, load, reset, eyedropper → document not edited (0007's check: ⌘W closes with no save sheet); History list has only its base row.
- **Performance:** not applicable.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification** (real `NSColorSampler`, Finder, visuals — not automatable):
  1. Click the eyedropper (no `-UITestScreenSample`): the system magnifier loupe appears; click a pure-red area of another app (e.g. a Safari page with `#FF0000`) → the active slot becomes `#FF0000FF` (±1 per channel on a wide-gamut display).
  2. Compare with Digital Color Meter set to "Display in sRGB" on several colors (UI chrome, a photo) → PaintDotMac's value is within ±2 per channel.
  3. On a Mac where PaintDotMac has never been granted Screen Recording: the eyedropper works, no permission prompt appears, PaintDotMac does not appear in System Settings › Privacy & Security › Screen & System Audio Recording, and no recording indicator shows. If macOS does prompt, record it and stop (spec assumption broken; report).
  4. Press Escape while the loupe is showing → colors unchanged; the button is enabled again. Pick from a second display with a different color profile → sensible sRGB value.
  5. Open Palettes Folder opens Finder at `~/Library/Application Support/PaintDotMac/Palettes`; copy a palette saved by Paint.NET (Windows) there → it appears in the menu and loads identically; a palette saved by PaintDotMac opens in Paint.NET on Windows.
  6. Swatch grid looks crisp at 1× and 2×, translucent swatches (rows 4–5) show the checkerboard, Add Color outline blinks (static under Reduce Motion), Add Color icon is tinted with the active color; light/dark mode; docked at 180 pt and 480 pt widths (0052) and floating.
  7. VoiceOver reads "Palette color 3, #FF0000FF" and its help "Red 255, Green 0, Blue 0, Alpha 255".

## Open questions

Recommended answers are applied in the spec above; the user should confirm.

1. **Default palette source.** The 96 colors are transcribed from a palette file saved by Paint.NET (third-party test fixture), not from Paint.NET's source or a fresh install; its first four entries match the docs' example, but the docs' example shows `FF23FFBD` as the fifth line where the transcribed list has `FFFFD800` (the doc sample looks illustrative). Rows 4–5 are rows 0–1 at alpha 128. *Recommended:* use the transcribed list; optionally confirm with Paint.NET 5 › Colors › Palette › Reset to Default Palette › Save Current Palette As… and diff.
2. **Eyedropper target slot.** Paint.NET has no screen eyedropper. *Recommended:* the picked color goes into the **active** slot (like a left-click on a palette swatch), alpha 255; no keyboard shortcut and no menu item, only the Colors panel button.
3. **Palette file leniency.** Paint.NET's docs only define 8-digit `aarrggbb` lines and whole-line `;` comments. *Recommended:* also accept 6-digit `RRGGBB` lines (opaque) and inline `; …` comments, silently skip malformed lines, and refuse a file with **zero** colors (alert, palette unchanged) instead of loading 96 white swatches; files over 1 MB are refused.
4. **Add Color mode duration.** The docs say a click replaces a swatch and clicking the icon again exits the mode, without saying whether the mode ends after one replacement. *Recommended:* the mode ends after one replacement (and on Escape, the icon, loading/resetting a palette, or starting the eyedropper).
5. **Save/Load UI.** Paint.NET saves by name into the palettes folder and loads from the folder list; it has no file dialogs. *Recommended:* mirror that exactly (name prompt with overwrite confirmation, CRLF Paint.NET-format files, no "Open Palette…" file dialog — users drop files into the folder via Open Palettes Folder); palette edits/loads/resets are not undoable and need no confirmation.

## Out of scope

- Picking colors from the canvas → Color Picker tool (0012). Docking the Colors panel → 0052.
- Palette formats other than Paint.NET `.txt` (`.aco`, `.gpl`, `.ase`), multiple palettes per file, palette names inside files, drag-and-drop of colors onto swatches, swatch reordering, live folder watching.
- Undo of palette changes; per-document palettes.
- Color management beyond sRGB 8-bit (NF-9).
