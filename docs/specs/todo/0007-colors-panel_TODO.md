# 0007 — Add the Colors panel with primary/secondary colors, swap, reset, wheel, sliders, hex, and alpha

> Source: PRD.md §5.10 C-1 (swap X, reset D, **C switches which slot the panel edits**), C-2; §5.1 APP-2 (Colors panel, ⌥⌘4); §5.3 TOOL-A (primary/secondary); §5.12 (single-key shortcuts, Ctrl → ⌘, Alt → ⌥; "Switch active color slot: C"); §4 Testing row; §12 D-5, D-20, D-31 (C switches the active slot), D-37 (`-UITestResetDefaults` clears `colors.`). Paint.NET docs: Colors Window <https://paint.net/doc/latest/ColorsWindow.html>, Keyboard & Mouse Commands <https://paint.net/doc/latest/KeyboardMouseCommands.html>, Working with Palettes <https://paint.net/doc/latest/WorkingWithPalettes.html> (palette files only, cited for the hex byte-order note below).
> Milestone: M1
> Depends on: 0006-tool-framework-and-panels (`AppModel`, `PanelController`/`PanelKind.colors`, Window menu ⌥⌘4, `ToolRegistry`, `CanvasInputRouter` single-key handling, `UITestApp`); 0002-tiled-surface-and-image-decoding (`ColorRGBA8`).

## Context

Not yet implemented: there is no application code yet. When this spec starts, these exist from earlier specs (use their exact names and signatures; read the done specs first):

- `PaintDotMac/Core/Model/ColorRGBA8.swift` (0002): straight-alpha sRGB 8-bit color, `struct ColorRGBA8: Hashable, Sendable { var red, green, blue, alpha: UInt8 }` with `init(red:green:blue:alpha: UInt8 = 255)` and `static let clear`, `black`, `white`. Do **not** create a second color type. Tuples like (51,102,204,128) in this spec mean `ColorRGBA8(red: 51, green: 102, blue: 204, alpha: 128)`; a 3-tuple has alpha 255.
- `PaintDotMac/App/AppModel.swift` (0006): `@MainActor @Observable` app-wide state (active tool, panel visibility).
- `PaintDotMac/App/PanelController.swift` (0006): four floating `NSPanel`s keyed by `PanelKind` (`.tools`, `.history`, `.layers`, `.colors`), Window menu toggle "Colors" ⌥⌘4, frame autosave. 0006 hosts placeholder content in the `.colors` panel; this spec replaces it.
- `PaintDotMac/Core/Tools/ToolRegistry.swift` (0006): single-letter tool keys (S, M, Z, H, F, G, B, E, P, K, L, R, T, O) and `ToolShortcutGate.allows(modifiers:keyWindow:textInputHasFocus:toolCapturesKeyboard:gestureInProgress:)`, the one gate for every single-key shortcut. `PaintDotMac/Canvas/CanvasInputRouter.swift` (0006): `static func handleShortcutKeyDown(_:model:)`, which calls the tool lookup first. **X**, **D**, and **C** are not tool keys.
- `PaintDotMac/Core/Tools/ToolContext.swift` (0006): protocol through which tools read app state; 0006 reserves `var colors: ColorSelection { get }` for this spec. Its conformers are `Canvas/CanvasToolSession.swift` and the test double `PaintDotMacTests/Support/FakeToolContext.swift`.
- `PaintDotMac/App/LaunchOptions.swift` (0001) with the `#if DEBUG` hooks `-UITestOpen`, `-ApplePersistenceIgnoreState`, `-UITestResetDefaults`, and `resettableKeyPrefixes` (`["tool.", "panel.", "NSWindow Frame panel.", "settings."]` after 0004); `PaintDotMacUITests/Support/UITestApp.swift` (0001: `launch(opening:resetDefaults:extraArguments:)`; 0006 helpers).

### Paint.NET behavior this mirrors (from the cited docs)

- The Colors window holds two color "slots", **Primary** and **Secondary**, drawn as overlapping squares (primary in front, upper left). One slot is **active**; clicking the other square makes it active. Edits from the wheel/sliders/hex go to the active slot.
- A double-headed arrow swaps Primary and Secondary; shortcut **X**.
- A small black/white icon at the lower left resets to **black primary, white secondary**. Paint.NET documents no key for this; PaintDotMac adds **D** per PRD C-1.
- Color wheel: left-click installs the color into the **active** slot, right-click into the **inactive** slot. Ctrl-drag changes Hue only, Alt-drag changes Saturation only, Ctrl+Shift-drag snaps Hue to 15° steps. With PRD §5.12 (Ctrl → ⌘, Alt → ⌥) these become ⌘-drag, ⌥-drag, ⇧⌘-drag.
- A **More »** button expands the window to show RGB, HSV, and opacity sliders and an editable hex box for the active slot; in the expanded state the button reads **« Less** and collapses it again.
- Paint.NET's **C** key switches the active slot; PaintDotMac keeps it (PRD C-1, §5.12, D-31). Its 96-color palette is C-3 (spec 0054).
- Paint.NET's palette **files** store colors as `AARRGGBB`. The hex box in PaintDotMac uses the CSS order `RRGGBB` / `RRGGBBAA` (decided for this backlog); palette-file I/O in 0054 handles its own order.

Color changes are **not** history steps (Paint.NET doesn't record them either), and colors are **app-wide**, not per document: switching documents never changes them.

## User story

As a PaintDotMac user, I see my primary and secondary colors in the Colors panel, swap them with X or the arrow button, reset them to black/white with D or the reset button, and pick exact colors with the color wheel, RGB/HSV/Alpha sliders, or by typing a hex code. My colors are still there the next time I launch the app.

## Scope & changes

### Core (pure Swift, unit-tested; no AppKit/SwiftUI imports)

- **`PaintDotMac/Core/Model/ColorSelection.swift`** (new):
  - `enum ColorSlot: String, CaseIterable, Sendable { case primary, secondary; var other: ColorSlot }`.
  - `struct ColorSelection: Equatable, Sendable { var primary: ColorRGBA8; var secondary: ColorRGBA8 }` with `static let defaultPrimary = ColorRGBA8.black`, `static let defaultSecondary = ColorRGBA8.white`, `static let `default``, `subscript(slot: ColorSlot) -> ColorRGBA8 { get set }`, `mutating func swap()`, `mutating func reset()` (sets both defaults).
  - `enum ColorKeyCommand: Equatable, Sendable { case swap, reset, switchSlot }` with `static func command(forCharactersIgnoringModifiers characters: String, command: Bool, option: Bool, control: Bool) -> ColorKeyCommand?`. Returns `.swap` for `"x"`/`"X"`, `.reset` for `"d"`/`"D"`, and `.switchSlot` for `"c"`/`"C"` (PRD C-1, §5.12, D-31) only when `command`, `option`, and `control` are all false (Shift and Caps Lock are ignored). Everything else returns `nil` (so ⌘X, ⌘D, and ⌘C keep reaching the menu).
  - `@MainActor struct ColorSelectionStore` (main-actor isolated rather than `Sendable`, because it holds a `UserDefaults` and is only used from `AppModel`) wrapping an injected `UserDefaults` (tests pass `UserDefaults(suiteName: "ColorSelectionStoreTests-\(UUID())")`): `init(defaults: UserDefaults = .standard)`, `func load() -> ColorSelection`, `func save(_ selection: ColorSelection)`, `func loadPanelExpanded() -> Bool`, `func savePanelExpanded(_:)`. Keys (static constants on the store):
    - `colors.primary` — `String`, always `#RRGGBBAA` uppercase (via `ColorHex.format(_:includeAlpha: true)`).
    - `colors.secondary` — same format.
    - `colors.panelExpanded` — `Bool`, default `false` (Paint.NET opens in the compact "Less" state).
    - `load()` parses each key with `ColorHex.parse`; a missing key, a non-`String` value, or an unparseable string falls back to that slot's default **independently** (a bad secondary never resets a good primary). A stored 6-digit value is read with alpha 255.

- **`PaintDotMac/Core/Model/HSVColor.swift`** (new): `struct HSVColor: Equatable, Sendable { var hue: Double; var saturation: Double; var value: Double }`. Hue is in degrees `[0, 360)`, saturation and value in `[0, 100]` (Paint.NET's H 0–360, S 0–100, V 0–100 scales). `init(hue:saturation:value:)` normalizes: hue `h.truncatingRemainder(dividingBy: 360)`, `+ 360` if negative, NaN/∞ → 0; saturation and value clamped to `0...100`, NaN → 0.
  - `init(rgb: ColorRGBA8)` (alpha ignored). With `r, g, b` as `Double` in 0–255, `mx = max`, `mn = min`, `d = mx − mn`:
    - `value = mx / 255 × 100`
    - `saturation = mx == 0 ? 0 : d / mx × 100`
    - `hue = 0` if `d == 0`; else if `mx == r`: `60 × ((g − b) / d)`; else if `mx == g`: `60 × ((b − r) / d + 2)`; else: `60 × ((r − g) / d + 4)`; then `+ 360` if negative. (Ties: check `r` first, then `g`.)
    - No rounding: components stay `Double`.
  - `func rgb(alpha: UInt8) -> ColorRGBA8`: `s = saturation / 100`, `v = value / 100`, `c = v × s`, `hp = hue / 60`, `sector = min(max(Int(hp.rounded(.down)), 0), 5)`, `x = c × (1 − |hp.truncatingRemainder(dividingBy: 2) − 1|)`, `m = v − c`; `(r1, g1, b1)` = sector 0 `(c, x, 0)`, 1 `(x, c, 0)`, 2 `(0, c, x)`, 3 `(0, x, c)`, 4 `(x, 0, c)`, 5 `(c, 0, x)`; each channel = `UInt8(clamping: Int(((ch + m) × 255).rounded(.toNearestOrAwayFromZero)))`. **Rounding rule: half away from zero** (127.5 → 128).
  - `var displayHue: Int { Int(hue.rounded(.toNearestOrAwayFromZero)) }` (may be 360 for hue ≥ 359.5; that is fine, the slider range is 0–360), and `displaySaturation`, `displayValue` likewise.

- **`PaintDotMac/Core/Model/ColorHex.swift`** (new): `enum ColorHex`:
  - `struct Parsed: Equatable { var red, green, blue: UInt8; var alpha: UInt8? }` (`alpha == nil` for 6-digit input).
  - `static func parse(_ text: String) -> Parsed?`. Rules, in order: trim leading/trailing whitespace and newlines; drop **one** optional leading `#`; the rest must be **exactly 6 or 8** characters, each an ASCII `0-9`, `a-f`, or `A-F` (case-insensitive; no `0x` prefix, no inner spaces, no 3- or 4-digit CSS shorthand, no full-width digits); byte order is `RRGGBB` or `RRGGBBAA`. Anything else returns `nil`.
  - `static func format(_ color: ColorRGBA8, includeAlpha: Bool) -> String` → `#RRGGBB` or `#RRGGBBAA`, uppercase, zero-padded.
  - `static func displayString(_ color: ColorRGBA8) -> String` → 6 digits when `alpha == 255`, otherwise 8 digits (what the hex field shows).

- **`PaintDotMac/Core/Model/ColorChannel.swift`** (new): `enum ColorChannel: String, CaseIterable, Sendable { case red, green, blue, hue, saturation, value, alpha }` with `var range: ClosedRange<Int>` (red/green/blue/alpha `0...255`, hue `0...360`, saturation/value `0...100`) and `var label: String` ("Red", "Green", "Blue", "Hue", "Saturation", "Value", "Alpha"; abbreviated "R", "G", "B", "H", "S", "V", "A" are allowed as visible labels if the full name is the accessibility label).

- **`PaintDotMac/Core/Model/ColorEditorState.swift`** (new): the pure editing model behind the panel. Keeps a **per-slot HSV cache** so the hue survives grays and black (otherwise dragging Saturation to 0 and back would lose the hue, and the wheel/Hue slider would be dead on black).
  - `struct ColorEditorState: Equatable, Sendable { private(set) var selection: ColorSelection; var activeSlot: ColorSlot; private(set) var hsv: [ColorSlot: HSVColor] }` — `init(selection:)` sets `activeSlot = .primary` and computes both caches with `HSVColor(rgb:)`. The active slot is **not** persisted; every launch starts with Primary active.
  - `func value(of channel: ColorChannel, slot: ColorSlot? = nil) -> Int` — RGB/alpha from `selection[slot]`, HSV from the cache's display values (`slot` defaults to `activeSlot`).
  - `mutating func set(_ channel: ColorChannel, to value: Int)` on the active slot. The value is clamped to `channel.range`. Red/green/blue → replace that channel, then re-sync the cache from RGB (rule below). Hue/saturation/value → update that cache component (as `Double(value)`), then `selection[slot] = cache.rgb(alpha: current alpha)`. Alpha → change alpha only, cache untouched.
  - `mutating func setColor(_ color: ColorRGBA8, for slot: ColorSlot)` — external set (hex, Color Picker tool in 0012). Re-syncs that slot's cache. **Re-sync rule:** `new = HSVColor(rgb:)`; if `new.value == 0`, keep the old hue and saturation (only value becomes 0); else if `new.saturation == 0`, keep the old hue; otherwise take `new` as is.
  - `@discardableResult mutating func applyHex(_ text: String) -> Bool` — `ColorHex.parse`; on `nil` returns `false` and changes nothing; 6 digits keep the active slot's current alpha; 8 digits set alpha too; then `setColor(_:for: activeSlot)`; returns `true`.
  - `mutating func applyWheel(hue: Double, saturation: Double, to slot: ColorSlot)` — sets the cache's hue and saturation (normalized as in `HSVColor.init`). **Decision (the PRD and Paint.NET's docs are silent; the wheel is drawn at value 100, C-2):** if the slot's cached `value` is 0, it becomes 100 first, so clicking the wheel with the default black primary yields the clicked color instead of staying black. Alpha is kept. Then writes RGB.
  - `mutating func swap()` — swaps `selection` and swaps the two caches. `mutating func reset()` — `selection.reset()`, caches become exactly `HSVColor(hue: 0, saturation: 0, value: 0)` and `HSVColor(hue: 0, saturation: 0, value: 100)`. Neither changes `activeSlot`.
  - `mutating func switchActiveSlot()` — `activeSlot = activeSlot.other` (the C key, C-1). Colors and caches are unchanged.

- **`PaintDotMac/Core/Model/ColorWheelGeometry.swift`** (new): pure mapping between wheel points and hue/saturation, in **view coordinates with y pointing down** (SwiftUI). Hue 0° (red) is at 3 o'clock and hue increases **counterclockwise** on screen (90° at 12 o'clock, 180° at 9 o'clock, 270° at 6 o'clock). The center is saturation 0 and the rim is saturation 100. The wheel is drawn at value 100.
  - `static func hueSaturation(at point: CGPoint, center: CGPoint, radius: Double) -> (hue: Double, saturation: Double)?` — `dx = x − cx`, `dy = cy − y`; `dist = hypot(dx, dy)`; returns `nil` if `radius <= 0`; hue `atan2(dy, dx)` in degrees normalized to `[0, 360)` (hue 0 when `dist == 0`); saturation `min(dist / radius, 1) × 100`. Points outside the rim clamp to saturation 100 (dragging may leave the wheel).
  - `static func point(hue: Double, saturation: Double, center: CGPoint, radius: Double) -> CGPoint` — inverse, for the marker.
  - `enum Constraint { case free, hueOnly, saturationOnly, hueSnapped }` with `static func constraint(command: Bool, option: Bool, shift: Bool) -> Constraint`: ⇧⌘ → `.hueSnapped`; ⌘ → `.hueOnly`; ⌥ → `.saturationOnly`; else `.free` (⌥ with ⌘ → `.hueOnly`).
  - `static func constrained(hue: Double, saturation: Double, current: HSVColor, constraint: Constraint) -> (hue: Double, saturation: Double)` — `.hueOnly`: `(hue, current.saturation)`; `.saturationOnly`: `(current.hue, saturation)`; `.hueSnapped`: `((hue / 15).rounded(.toNearestOrAwayFromZero) × 15` normalized so 360 → 0, `current.saturation)`; `.free`: unchanged. Constraints apply to the whole drag, re-evaluated on each drag event from that event's modifiers.

- **`PaintDotMac/Core/Rendering/ColorWheelImage.swift`** (new): `enum ColorWheelImage { static func makePixels(diameter: Int) -> [ColorRGBA8] }` and `static func makeCGImage(diameter: Int) -> CGImage?` (CoreGraphics only). Pixel `(px, py)` samples at its center `(px + 0.5, py + 0.5)` with `center = (diameter/2, diameter/2)` and `radius = diameter/2`; its RGB is `HSVColor(hue:saturation:value: 100).rgb(alpha: 255)` from `ColorWheelGeometry.hueSaturation`, its alpha is `round(255 × clamp(radius − dist + 0.5, 0, 1))` (a one-pixel antialiased rim, transparent outside). `diameter <= 0` returns `[]`/`nil`. Rendering the view from this image guarantees the drawn colors match the hit-testing geometry.

### Platform glue (AppKit/SwiftUI; covered by UI tests and manual checks)

- **`PaintDotMac/App/AppModel.swift`** (modify): add `private(set) var colorEditor: ColorEditorState`, `var colors: ColorSelection { colorEditor.selection }`, `var colorsPanelExpanded: Bool`, and an injected `ColorSelectionStore` (new init parameter with default `ColorSelectionStore()`; tests inject a suite-backed store). Mutating methods `swapColors()`, `resetColors()`, `setColor(_:for:)`, `setColorChannel(_:to:)`, `applyHex(_:) -> Bool`, `applyWheel(hue:saturation:to:)`, `setActiveColorSlot(_:)`, `switchActiveColorSlot()`, `setColorsPanelExpanded(_:)`. The active slot is not persisted. Every method that changes `colors` saves through the store immediately (UserDefaults writes are cheap; no debounce). `init` loads colors and the expanded flag from the store.
- **`PaintDotMac/Core/Tools/ToolContext.swift`** (modify): add the requirement 0006 reserved, `var colors: ColorSelection { get }` (read-only; 0012 adds the setter path through `AppModel.setColor`). `CanvasToolSession` returns `AppModel.colors`; `FakeToolContext` gets a settable `var colors: ColorSelection = .default`. 0009 reads `colors.primary`/`colors.secondary` at stroke start (TOOL-A).
- **`PaintDotMac/Canvas/CanvasInputRouter.swift`** (modify): in `handleShortcutKeyDown(_:model:)`, after `model.dispatcher.handleShortcut(...)` returns `false`, if `ToolShortcutGate.allows(...)` is true (the same inputs the tool lookup used: document window or Colors/Tools panel key, no text field focused, no ⌘/⌥/⌃, no capturing tool, no gesture), call `ColorKeyCommand.command(forCharactersIgnoringModifiers:command:option:control:)` and run `AppModel.swapColors()` / `resetColors()` / `switchActiveColorSlot()`, consuming the event. Key repeat (`isARepeat`) is consumed but ignored for X, D, and C, so holding X doesn't flicker. No menu items are added (Paint.NET has none).
- **`PaintDotMac/UI/ColorsPanelView.swift`** (new): SwiftUI content of the Colors panel, bound to `AppModel`. Root accessibility identifier `colorsPanel` (0006 put it on the placeholder view's root; this view replaces that view, so there is exactly one element with this identifier).
  - **Compact ("Less") layout**, top to bottom: the primary/secondary swatch pair (overlapping squares, primary upper-left in front) with the swap arrow button at its upper right and the reset button (small black/white squares) at its lower left; the color wheel; the **More »** button.
  - **Expanded ("More") layout** adds, below the wheel: the hex field labeled "Hex"; sliders Red, Green, Blue; Hue, Saturation, Value; Alpha. Each slider has a numeric text field next to it. The button reads **« Less**.
  - Swatches draw the color over a small checkerboard so alpha is visible. The active slot gets a 2-pt accent-colored outline. Clicking a swatch makes it the active slot. Accessibility: identifiers `colors.primary` / `colors.secondary`, labels "Primary color" / "Secondary color", **accessibility value = `ColorHex.format(color, includeAlpha: true)`** (always 8 digits, e.g. `#000000FF`), plus the `.isSelected` trait on the active one.
  - Swap button: identifier `colors.swap`, label "Swap colors", help tooltip "Swap Colors (X)". Reset button: identifier `colors.reset`, label "Reset colors", tooltip "Reset to Default Colors (D)". More/Less button: identifier `colors.moreLess`, titles exactly `More »` and `« Less`; toggling calls `setColorsPanelExpanded` and the panel resizes to fit, keeping its top-left corner fixed (resize the `NSPanel` from the hosting view's `fittingSize` in `PanelController`; the frame autosave keeps working).
  - Hex field: identifier `colors.hex`, shows `ColorHex.displayString` of the active slot. Commits on Return and on losing focus via `AppModel.applyHex`; when that returns `false` (invalid), the field reverts to the current display string — no alert, no beep, no color change. Escape reverts without committing. While the field is being edited, outside changes (X/D, wheel) don't overwrite the user's typing; it refreshes when editing ends.
  - Sliders: identifiers `colors.red`, `colors.green`, `colors.blue`, `colors.hue`, `colors.saturation`, `colors.value`, `colors.alpha`; numeric fields `colors.redField` … `colors.alphaField`. Integer steps over `ColorChannel.range`. Each is a custom-drawn track (a gradient showing the channel's range with the other components fixed; the hue track shows the hue spectrum at the current S and V; the alpha track draws over a checkerboard) with a thumb, and **must expose itself to accessibility as an adjustable slider** (`.accessibilityRepresentation { Slider(...) }` or equivalent) so XCUITest's `adjust(toNormalizedSliderPosition:)` and VoiceOver increment/decrement work. Numeric fields accept integers only; values are clamped to the range; non-numeric input reverts on commit (Return/focus loss).
- **`PaintDotMac/UI/ColorWheelView.swift`** (new): draws `ColorWheelImage.makeCGImage(diameter: pointDiameter × backingScale)` (regenerated only when the size or backing scale changes; cache it), a circular marker at `ColorWheelGeometry.point(…)` for the **active slot's** cached hue/saturation, and handles input with an `NSViewRepresentable` (or SwiftUI gesture plus an `NSEvent` modifier read) so it receives left, right, and Control-click drags with modifier flags. Left drag → `applyWheel(…, to: activeSlot)`; right drag or Control-drag → `applyWheel(…, to: activeSlot.other)` (Paint.NET "inactive slot"), both through `ColorWheelGeometry.constrained` with the drag's current modifiers. The constraint's `current` is the target slot's cached HSV at drag start. Identifier `colors.wheel`, label "Color wheel", value "Hue <h>°, Saturation <s>%".
- **`PaintDotMac/App/PanelController.swift`** (modify): host `ColorsPanelView` in the `.colors` panel instead of 0006's `PanelPlaceholderView`. Panel title "Colors". Update 0006's `PanelsUITests.testPlaceholderText` and `PanelControllerTests.placeholderIdentifiers` to drop `colorsPanel` (History and Layers keep their placeholders).
- **`PaintDotMac/App/LaunchOptions.swift`** (modify): `resettableKeyPrefixes` becomes exactly `["tool.", "panel.", "NSWindow Frame panel.", "colors.", "settings."]` (PRD §4 Testing row, D-37), so `-UITestResetDefaults` also removes `colors.primary`, `colors.secondary`, and `colors.panelExpanded`.
- **`PaintDotMacUITests/Support/UITestApp.swift`** (modify): the persistence test relaunches with 0001's `launch(opening:resetDefaults: false, …)`; add a helper `openColorsPanel()` that toggles Window > Colors (⌥⌘4) only if `colorsPanel` is not on screen, and `expandColorsPanel()` that clicks `colors.moreLess` if its title is `More »`.
- `project.yml`: no target changes; new files are picked up by the existing source globs. Run `xcodegen generate`.
- No PRD change: C-1/§5.12 (C key, D-31) and the §4 reset list (D-37) already say this.

### Cross-cutting rules respected

No pixel changes (nothing goes through history); Core files import only Foundation/CoreGraphics; UI on `@MainActor`; single-key shortcuts (X, D, C) only through 0006's `ToolShortcutGate` (AGENTS.md rule 9); no `NSColorPanel` (D-20). NF-1 to NF-4 are unaffected.

## Acceptance criteria

- [ ] On first launch (clean defaults) the primary color is opaque black and the secondary is opaque white. → `ColorSelectionStoreTests.missingKeysLoadDefaults`, `ColorsPanelUITests.testDefaultColors`
- [ ] Pressing X (no text field focused) swaps primary and secondary; the swap button does the same. → `ColorSelectionTests.swapExchangesSlots`, `ColorEditorStateTests.swapAlsoSwapsHSVCaches`, `ColorsPanelUITests.testSwapWithXAndButton`
- [ ] Pressing D resets to black/white; the reset button does the same. → `ColorSelectionTests.resetRestoresDefaults`, `ColorEditorStateTests.resetSetsExactCaches`, `ColorsPanelUITests.testResetWithDAndButton`
- [ ] Pressing C switches the active slot (the outlined, selected swatch) without changing either color; edits then go to the other slot; the active slot is not persisted (C-1, D-31). → `ColorKeyCommandTests.cSwitchesSlot`, `ColorEditorStateTests.switchActiveSlotTogglesOnly`, `AppModelColorsTests.switchActiveColorSlotTogglesAndIsNotPersisted`, `ColorsPanelUITests.testCSwitchesActiveSlot`
- [ ] X, D, and C with ⌘/⌥/⌃ do nothing (⌘X, ⌘D, ⌘C keep their menu meanings), and X/D/C are not tool keys. → `ColorKeyCommandTests.modifiersBlock`, `ColorKeyCommandTests.xDAndCAreNotToolKeys`
- [ ] Typing X, D, or C into the hex field types text and does not swap, reset, or switch slots. → `ColorsPanelUITests.testTypingInHexFieldDoesNotTriggerShortcuts`
- [ ] HSV↔RGB conversion follows the formulas above with half-away-from-zero rounding. → `HSVColorTests.*`, `HSVColorPropertyTests.rgbToHSVToRGBIsIdentity`
- [ ] The hex field accepts `#RRGGBB`/`RRGGBB` (keeps alpha) and `#RRGGBBAA`/`RRGGBBAA` (sets alpha), case-insensitive with surrounding whitespace; any other input reverts the field and leaves the color unchanged. → `ColorHexTests.*`, `ColorEditorStateTests.applyHex*`, `ColorsPanelUITests.testHexEntryUpdatesActiveSlotAndSliders`, `ColorsPanelUITests.testInvalidHexReverts`
- [ ] RGB, HSV, and Alpha sliders and their numeric fields edit the active slot; H 0–360, S/V 0–100, R/G/B/Alpha 0–255. → `ColorEditorStateTests.set*`, `ColorChannelTests.ranges`, `ColorsPanelUITests.testRedSliderEditsPrimary`
- [ ] The hue is preserved through grays and black (Saturation 0 → back, Value 0 → back). → `ColorEditorStateTests.hueSurvivesZeroSaturation`, `.hueAndSaturationSurviveBlack`, `.externalGrayKeepsHue`
- [ ] Clicking a swatch makes it active; edits then go to that slot only. → `ColorEditorStateTests.editsTargetActiveSlotOnly`, `ColorsPanelUITests.testSecondarySlotEditing`
- [ ] The color wheel maps hue around the circle (0° at 3 o'clock, counterclockwise) and saturation along the radius; drawn colors match the hit-testing; left click sets the active slot, right/Control-click the inactive slot; ⌘ hue only, ⌥ saturation only, ⇧⌘ 15° hue snap; clicking the wheel on black yields a visible color. → `ColorWheelGeometryTests.*`, `ColorWheelImageTests.*`, `ColorEditorStateTests.applyWheel*`, `ColorsPanelUITests.testWheelClickSetsPrimary`; right-click and modifier drags → manual (XCUITest can't hold modifiers during a drag reliably)
- [ ] More »/« Less toggles the slider/hex section, and the state is persisted. → `ColorSelectionStoreTests.panelExpandedRoundTrip`, `ColorsPanelUITests.testMoreLessToggles`
- [ ] Colors are app-wide and persist across relaunch under `colors.primary` / `colors.secondary` as `#RRGGBBAA`; corrupt stored values fall back per slot. → `ColorSelectionStoreTests.*`, `AppModelColorsTests.*`, `ColorsPanelUITests.testColorsPersistAcrossRelaunch`
- [ ] `-UITestResetDefaults` clears every `colors.*` key; the prefix list is exactly `["tool.", "panel.", "NSWindow Frame panel.", "colors.", "settings."]` (D-37). → `LaunchOptionsColorsKeysTests.prefixListIsFinal`, `.resetClearsColorKeys`; every `ColorsPanelUITests` test starts from black/white
- [ ] Color changes create no history steps and don't mark documents edited. → `ColorsPanelUITests.testColorChangeDoesNotDirtyDocument`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Hex input:** empty, `#` only, 3/4/5/7/9+ digits, non-hex letters, `0x` prefix, inner spaces, two `#`, non-ASCII digits → `parse` returns `nil`, field reverts, color unchanged. Leading/trailing whitespace and newlines are trimmed. Lowercase accepted; display is always uppercase.
- **Alpha:** 6-digit hex keeps alpha; hue/saturation/value/RGB edits keep alpha; swatches show alpha over a checkerboard; alpha 0 is allowed (a fully transparent primary is legal, as in Paint.NET).
- **HSV extremes:** hue 360 ≡ 0; hue values like 359.9 stay in sector 5; `hp` exactly 6 can't select a seventh sector (clamped); NaN/∞ inputs normalize to 0; S/V outside 0–100 clamp.
- **Gray/black:** RGB→HSV of a gray gives hue 0 but the editor keeps the cached hue; black keeps cached hue and saturation; wheel on a slot with value 0 sets value 100.
- **Wheel:** zero-size view (`radius <= 0`) → no-op; drag outside the rim clamps to saturation 100; exact center (`dist == 0`) → saturation 0 and the target slot's cached hue is kept (the view passes the cached hue instead of geometry's 0). → `ColorEditorStateTests.applyWheelAtCenterKeepsHue`
- **Persistence:** missing keys, wrong types (`Int`, `Data`), unparseable strings, and 6-digit strings are all handled per slot without crashing. Writes happen on every change; the last value wins.
- **Focus:** X/D/C do nothing while any text field (hex, numeric fields, later the Text tool) has focus. Key repeat is ignored.
- **Numeric fields:** out-of-range numbers clamp (e.g. `300` in Red → 255, `-5` → 0); non-numeric input reverts.
- **No document open:** 0006 hides every panel and no eligible window is key, so X/D/C don't fire (0006's gate returns false for `.other`); colors stay persisted and reappear with the next document. `AppModel` color methods don't depend on a document.
- **Panel hidden:** X/D/C still work when the Colors panel is hidden (the document window is key); reopening shows the current colors and active slot.

## Test plan

Expected values below are hand-computed from the formulas in this spec; never paste outputs of the code under test.

- **Unit tests** (`PaintDotMacTests/Colors/`):
  - `HSVColorTests.swift`
    - `rgbToHSVPrimaries`: (255,0,0) → (0,100,100); (0,255,0) → (120,100,100); (0,0,255) → (240,100,100); (255,255,0) → (60,100,100); (0,255,255) → (180,100,100); (255,0,255) → (300,100,100). Compare with tolerance 1e-9.
    - `rgbToHSVGraysAndBlack`: (0,0,0) → (0,0,0); (255,255,255) → (0,0,100); (128,128,128) → hue 0, sat 0, value 50.19607843137255 (±1e-9).
    - `rgbToHSVNonIntegerHue`: (255,128,0) → hue 30.11764705882353, s 100, v 100; (255,0,128) → hue 329.88235294117646; (51,102,204) → (220, 75, 80) (±1e-9).
    - `hsvToRGBExactSectors`: (210,50,80) → (102,153,204); (220,75,80) → (51,102,204); (60,50,100) → (255,255,128); (300,100,100) → (255,0,255); alpha argument passed through (e.g. 77).
    - `hsvToRGBRoundsHalfAwayFromZero`: (30,100,100) → (255,128,0) (green is 127.5); (0,100,50) → (128,0,0).
    - `hsvToRGBEdges`: (360,100,100) → (255,0,0); (359.9,100,100) → (255,0,0); (−120,100,100) normalizes to 240 → (0,0,255); (any hue, 0, 100) → (255,255,255); (any, any, 0) → (0,0,0); NaN hue → treated as 0; S 150 → clamped 100; V −5 → 0.
    - `displayValuesRound`: hue 359.6 → displayHue 360; 30.1176 → 30; value 50.196 → 50; 12.5 → 13.
  - `HSVColorPropertyTests.swift` — `rgbToHSVToRGBIsIdentity`: for every (r,g,b) on the grid `stride(0...255, by: 5)` cubed plus the corners and 100,000 `SeededRandom` colors (seed printed on failure), `HSVColor(rgb: c).rgb(alpha: c.a) == c` exactly.
  - `ColorHexTests.swift`
    - `parsesSixDigits`: `"#3366CC"`, `"3366cc"`, `"  #3366Cc\n"` → (51,102,204, alpha nil).
    - `parsesEightDigits`: `"#3366CC80"` → (51,102,204,128); `"00000000"` → (0,0,0,0).
    - `rejectsInvalid` (each `nil`): `""`, `"#"`, `"#FFF"`, `"#FFFF"`, `"#FFFFF"`, `"#FFFFFFF"`, `"#FFFFFFFFF"`, `"#GG0000"`, `"0x3366CC"`, `"#33 66CC"`, `"##3366CC"`, `"#３３６６ＣＣ"` (full-width).
    - `formats`: (0,0,0,255) → `"#000000"` / `"#000000FF"`; (10,11,255,1) → `"#0A0BFF"` / `"#0A0BFF01"`.
    - `displayStringDependsOnAlpha`: alpha 255 → 6 digits; alpha 128 → 8 digits.
    - `formatParseRoundTrip`: 10,000 seeded colors, `parse(format(c, includeAlpha: true))` returns exactly c.
  - `ColorChannelTests.swift` — `ranges`: R/G/B/Alpha `0...255`, Hue `0...360`, S/V `0...100`; `labels` match the strings above.
  - `ColorSelectionTests.swift` — `defaultsAreBlackAndWhite`; `swapExchangesSlots` (swap twice = identity); `resetRestoresDefaults` (from arbitrary colors, including non-255 alpha); `subscriptReadsAndWrites`; `slotOther`.
  - `ColorKeyCommandTests.swift` — `xSwaps` (`"x"`, `"X"`), `dResets` (`"d"`, `"D"`), `cSwitchesSlot` (`"c"`, `"C"` → `.switchSlot`); `modifiersBlock` (⌘X, ⌘D, ⌘C, ⌥X, ⌃D, ⌃C → nil); `otherKeysIgnored` (`"v"`, `"xx"`, `""`, `"b"` → nil); `xDAndCAreNotToolKeys`: `ToolShortcutResolver.toolKey(fromCharactersIgnoringModifiers:)` (0006) returns nil for `"x"`, `"d"`, `"c"`, and none of them is in `ToolRegistry.allShortcutKeys`.
  - `ColorEditorStateTests.swift`
    - `initComputesCaches`; `activeSlotDefaultsToPrimary`.
    - `setRGBChannel`: primary black, set red 255 → (255,0,0,255), hue 0, S 100, V 100; `setClampsToRange`: red 300 → 255, hue 400 → 360 (≡ 0, RGB of hue 0).
    - `setHSVChannels`: from (51,102,204) (cache ≈ 220/75/80) set hue 0 → (204,51,51) (h0 s75 v80: c 0.6, x 0, m 0.2). Then value 100 → (255,64,64) (c 0.75, m 0.25; 63.75 → 64).
    - `hueSurvivesZeroSaturation`: from (51,102,204): set saturation 0 → (204,204,204), `value(of: .hue)` still 220; set saturation 75 → (51,102,204).
    - `hueAndSaturationSurviveBlack`: from black (cache 0,0,0): set hue 120 → still (0,0,0), hue shows 120; set saturation 100 → still black; set value 100 → (0,255,0).
    - `externalGrayKeepsHue`: cache (220,75,80); `setColor((128,128,128,255))` → cache hue 220, S 0, V ≈50.196; `setColor(black)` from cache (220,75,80) → cache (220,75,0).
    - `alphaEditDoesNotTouchHSV`: set alpha 10 → RGB unchanged, alpha 10, caches equal before/after.
    - `applyHexSixDigitsKeepsAlpha`: primary alpha 100, `applyHex("#FF0000")` → (255,0,0,100), returns true; `applyHexEightDigitsSetsAlpha`: `"#00FF0080"` → (0,255,0,128); `applyHexInvalidIsNoOp`: `"nope"` → returns false, state `==` before.
    - `editsTargetActiveSlotOnly`: activeSlot = .secondary, set red 0 → secondary (0,255,255,255), primary unchanged.
    - `applyWheelOnBlackSetsValue100`: default state, `applyWheel(hue: 0, saturation: 100, to: .primary)` → (255,0,0,255); `applyWheel(hue: 120, saturation: 50, to: .secondary)` on white → (128,255,128) (V 100: c=0.5, x=0, m=0.5; green 255, red/blue 127.5 → 128); `applyWheelKeepsAlpha`.
    - `applyWheelAtCenterKeepsHue`: cache (220,75,80); `applyWheel(hue: 220, saturation: 0, to: .primary)` (what the view passes at the exact center) → (204,204,204), hue still 220; then `set(.saturation, 75)` → (51,102,204).
    - `swapAlsoSwapsHSVCaches`: caches swap with colors; activeSlot unchanged. `resetSetsExactCaches`: caches `(0,0,0)` and `(0,0,100)` after reset from arbitrary state.
    - `switchActiveSlotTogglesOnly`: from primary (51,102,204) / secondary white, `switchActiveSlot()` → `activeSlot == .secondary`, `selection` and both caches `==` before; `set(.red, 0)` → secondary (0,255,255), primary still (51,102,204); `switchActiveSlot()` again → `.primary`.
  - `ColorWheelGeometryTests.swift` (center (100,100), radius 100, y down)
    - `cardinalPoints`: (200,100) → (0,100); (100,0) → (90,100); (0,100) → (180,100); (100,200) → (270,100).
    - `diagonalAndHalfRadius`: (150,100) → (0,50); (150,50) → (45, 70.71067811865476) (±1e-9).
    - `clampsOutsideRim`: (300,100) → (0,100). `centerIsZeroSaturation`: (100,100) → (0,0). `zeroRadiusReturnsNil`.
    - `pointInverse`: `point(hue: 90, saturation: 50)` → (100,50); round trip for 1,000 seeded (h, s) within 1e-9 (skip s = 0 for hue).
    - `constraintFromModifiers`: (⌘) → hueOnly, (⌥) → saturationOnly, (⇧⌘) → hueSnapped, (⇧) → free, none → free.
    - `constrained`: current (200, 40, 80); hueOnly(10, 90) → (10, 40); saturationOnly(10, 90) → (200, 90); hueSnapped(52, 90) → (45, 40); hueSnapped(353, 90) → (0, 40); hueSnapped(7.5, 90) → (15, 40).
  - `ColorWheelImageTests.swift` (diameter 101 unless stated: radius 50.5, center (50.5, 50.5), so pixel (50,50) samples the exact center; pixels are row-major, `index = py × diameter + px`)
    - `centerIsWhite`: pixel (50,50) → (255,255,255,255).
    - `eastEdgeIsRed`: pixel (99,50) samples (99.5,50.5): dist 49, hue 0, s = 49/50.5 = 0.970297, m = 0.029703 → 7.574 → 8; alpha clamp(50.5 − 49 + 0.5) = 1. Assert (255,8,8,255).
    - `northIsHue90`: pixel (50,1) samples (50.5,1.5): dy 49, hue 90, same s; sector 1: x = 0.485149, r = (x + m) × 255 = 131.29 → 131. Assert (131,255,8,255).
    - `cornersAreTransparent`: pixels (0,0) and (100,100) → alpha 0.
    - `rimIsAntialiased` (diameter 100: radius 50, center (50,50)): pixel (99,50) samples (99.5,50.5): dist √2450.5 = 49.50253 → alpha round(255 × 0.99747) = 254. Assert alpha 254.
    - `zeroDiameter`: `makePixels(diameter: 0)` is empty and `makeCGImage(diameter: 0)` is nil.
    - `matchesGeometry`: for 500 seeded interior pixels (dist ≤ radius − 1), the pixel RGB equals `HSVColor(geometry(sample), value: 100).rgb(alpha: 255)` exactly.
  - `ColorSelectionStoreTests.swift` (fresh suite per test, removed in teardown)
    - `missingKeysLoadDefaults`; `saveLoadRoundTrip` (including alpha 0 and 128); `storesEightDigitUppercase`: after saving (51,102,204,255) the raw `string(forKey: "colors.primary")` is `"#3366CCFF"`.
    - `corruptValuesFallBackPerSlot`: primary `"#ZZZZZZ"`, secondary `"#3366CC80"` → primary default black, secondary (51,102,204,128); `wrongTypeFallsBack`: primary stored as `Int 42` → black.
    - `sixDigitStoredValueReadsOpaque`: `"#3366CC"` → alpha 255.
    - `panelExpandedRoundTrip`: default false; save true → load true.
  - `AppModelColorsTests.swift` (`@MainActor`, injected suite store)
    - `loadsPersistedColorsOnInit`; `everyMutationPersists`: after `swapColors`, `resetColors`, `setColorChannel(.red, 200)`, `applyHex("#123456")`, `applyWheel`, a **new** `ColorSelectionStore` on the same suite loads the same colors each time; `invalidHexDoesNotWrite`: raw stored string unchanged after `applyHex("bad")`; `activeSlotNotPersisted`: set `.secondary`, new `AppModel` on the same store → `.primary`; `switchActiveColorSlotTogglesAndIsNotPersisted`: `switchActiveColorSlot()` → `.secondary`, `colors` unchanged, the raw `colors.primary`/`colors.secondary` strings unchanged and no other `colors.*` key written; again → `.primary`.
  - `LaunchOptionsColorsKeysTests.swift` (suite `LaunchOptionsColorsKeysTests.\(UUID())`, removed afterwards): `prefixListIsFinal`: `LaunchOptions.resettableKeyPrefixes == ["tool.", "panel.", "NSWindow Frame panel.", "colors.", "settings."]`; `resetClearsColorKeys`: suite with `colors.primary`, `colors.secondary`, `colors.panelExpanded`, `tool.zoom.testOption`, `panel.tools.visible`, `NSWindow Frame panel.colors`, `settings.measurementUnit`, and `unrelated.key` → after `LaunchOptions.resetDefaults(in:domainName:)` the persistent domain's keys are exactly `["unrelated.key"]`. 0006's `LaunchOptionsPanelKeysTests.resetCoversPanelAndToolKeys` doesn't assert the list and stays unchanged.
- **Round-trip and property tests:** `HSVColorPropertyTests.rgbToHSVToRGBIsIdentity`, `ColorHexTests.formatParseRoundTrip`, `ColorWheelGeometryTests.pointInverse`, `ColorWheelImageTests.matchesGeometry`, swap-twice identity — all seeded via `SeededRandom` with the seed printed on failure.
- **Golden-image tests:** none (the wheel image is checked against the geometry oracle above instead).
- **Integration tests:** `AppModelColorsTests` covers the app-model + persistence path headlessly. No document or history involvement.
- **UI tests** (`PaintDotMacUITests/ColorsPanelUITests.swift`; launch with a small PNG fixture generated at test time and `-UITestResetDefaults`; `openColorsPanel()` first; tests that need sliders/hex call `expandColorsPanel()`; key presses go to the document window, e.g. `app.windows.firstMatch.typeKey("x", modifierFlags: [])` after clicking the canvas with the Pan tool selected (press H first so the click doesn't paint once tools exist):
  - `testDefaultColors`: `colors.primary` value `#000000FF`, `colors.secondary` value `#FFFFFFFF`, and `colors.primary` is selected.
  - `testSwapWithXAndButton`: press X → primary `#FFFFFFFF`, secondary `#000000FF`; click `colors.swap` → back to the defaults.
  - `testResetWithDAndButton`: expand, set hex `#FF0000` + Return, press D → defaults; set hex again, click `colors.reset` → defaults.
  - `testHexEntryUpdatesActiveSlotAndSliders`: type `#3366CC` + Return in `colors.hex` → primary `#3366CCFF`; `colors.redField`/`greenField`/`blueField` values `51`/`102`/`204`; `hueField` `220`, `saturationField` `75`, `valueField` `80`; `alphaField` `255`. Then `3366cc80` + Return → primary `#3366CC80`, `alphaField` `128`, hex field shows `#3366CC80`.
  - `testInvalidHexReverts`: with primary `#3366CC`, type `XYZ` + Return → hex field value back to `#3366CC`, primary still `#3366CCFF`.
  - `testSecondarySlotEditing`: click `colors.secondary` (becomes selected), hex `#00FF00` + Return → secondary `#00FF00FF`, primary still `#000000FF`.
  - `testTypingInHexFieldDoesNotTriggerShortcuts`: focus `colors.hex`, select all, type `xdc` (no Return) → swatches unchanged (`#000000FF`/`#FFFFFFFF`), `colors.primary` still selected, and field contains `xdc`; press Escape → field shows `#000000`.
  - `testCSwitchesActiveSlot`: press C → `colors.secondary` is selected and `colors.primary` is not; both values unchanged; expand, type `#00FF00` + Return in `colors.hex` → secondary `#00FF00FF`, primary still `#000000FF`; click the canvas (Pan tool) and press C → `colors.primary` selected again.
  - `testRedSliderEditsPrimary`: `colors.red.adjust(toNormalizedSliderPosition: 1.0)` → primary `#FF0000FF` and `redField` `255`.
  - `testWheelClickSetsPrimary`: click `colors.wheel` at normalized offset (0.97, 0.5) → `hueField` `0`, `saturationField` ≥ 90, `valueField` `100`, primary value starts with `#FF`.
  - `testMoreLessToggles`: `colors.moreLess` title `More »` and `colors.hex` absent; click → title `« Less`, `colors.hex` and all seven sliders exist; click → collapsed again.
  - `testColorsPersistAcrossRelaunch`: hex `#123456` + Return, terminate, relaunch **without** `-UITestResetDefaults` → primary `#123456FF`; press D to clean up.
  - `testColorChangeDoesNotDirtyDocument`: open fixture, press X, change hex → the document window is not marked edited (`window.isDocumentEdited` via the close-button `AXDocumentEdited` / no unsaved dot; closing the window with ⌘W shows no save sheet).
- **Performance:** not applicable (no canvas/compositing/history change).
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification** (can't be automated reliably):
  1. Wheel look: hue ring smooth, white center, crisp antialiased rim on Retina and 1× displays; red at 3 o'clock, yellow/green going counterclockwise toward the top.
  2. Drag the wheel: the marker follows the cursor, the active swatch and sliders update live; dragging outside the wheel pins to the rim.
  3. ⌘-drag changes hue only (marker stays on its circle), ⌥-drag changes saturation only (marker stays on its spoke), ⇧⌘-drag snaps hue in 15° steps.
  4. Right-click and Control-click on the wheel set the inactive slot.
  5. Slider tracks show the right gradients and update while dragging the wheel; the alpha track and swatches show a checkerboard under translucent colors.
  6. More »/« Less resizes the panel with its top-left corner fixed; the panel's position survives a relaunch.
  7. Light and dark mode: labels, fields, outlines, and the active-slot highlight are legible.
  8. X, D, and C work while the Colors or Tools panel is the key window, and do nothing while typing in any numeric field. After C, the outline moves to the other swatch.
  9. VoiceOver reads "Primary color, #000000FF" and can increment/decrement a slider.

## Out of scope

- C-3 default 96-color palette, palette save/load, and C-4 screen eyedropper (`NSColorSampler`) → 0054.
- Picking colors from the canvas → Color Picker tool, 0012 (it calls `AppModel.setColor(_:for:)`).
- Painting with primary/secondary (TOOL-A) → 0009 and later tool specs.
- Docking the Colors panel (APP-3) → 0052. Moving X/D/C into the shortcut table → 0045.
- Color management beyond sRGB (NF-9); colors are 8-bit sRGB straight alpha.
