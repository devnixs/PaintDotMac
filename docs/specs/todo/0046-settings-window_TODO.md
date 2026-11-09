# 0046 — Add the Settings window (⌘,) for default units, checkerboard, undo memory limit, default JPEG quality, and resetting panel positions

> Source: PRD.md §5.1 APP-8 ("Settings window: default units, checkerboard style, undo memory limit, default JPEG quality, and the option to restore panel positions"), APP-5 (the unit "is chosen from a status-bar popup and persisted; its default comes from Settings"), APP-2 (panel frames remembered with frame autosave names); §5.4 H-5 / H-6 (dropping oldest steps; "1 GB" = 1 GiB); §6 NF-4 (configurable undo budget, default 1 GB); §5.2 CAN-4 (checkerboard); §12 D-4, D-9, D-23 (Settings built in M7), D-34; brief decision 32. Paint.NET: Settings dialog, https://www.getpaint.net/doc/latest/SettingsDialog.html (now served from https://paint.net/doc/latest/SettingsDialog.html). Its Canvas tab has a **"Transparency Checkerboard Brightness"** control that sets "the brightness of the transparency indicator (aka checkerboard)". The page lists no range or default. Paint.NET has no setting for checkerboard colors or size.
> Milestone: M7
> Depends on: 0045-shortcut-audit. Through it, this spec builds on 0001 (`MainMenu`, `LaunchOptions`, `UITestApp`), 0003 (`CheckerboardStyle`, `CanvasFrame`, `MetalCanvasRenderer`, `CanvasView`, `CanvasReferenceRenderer`), 0004 (`AppSettings`, `.appSettingsDidChange`, `MeasurementUnit`, `StatusBarModel`), 0006 (`PanelController`, `PanelKind.defaultFrame`), 0008 (`HistoryStack.setBudget`, `UndoBridge.setBudget`, `AppSettings.undoBudgetBytes`), 0009 (Paintbrush, for UI tests), 0010 (History panel rows), 0029 (`AppSettings.jpegQuality`, JPEG Options dialog), and 0031 (`UndoBridge.isBusy`).

## Context

There is no application code yet. The specs this one builds on define the following pieces (names are from those specs and win over any other naming):

- **`PaintDotMac/Core/Settings/AppSettings.swift`** was created by 0004 (`docs/specs/todo/0004-zoom-pan-and-status-bar_TODO.md:83-87`).
  - `struct AppSettings: @unchecked Sendable` wraps an injected `UserDefaults`, via `init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default)`.
  - It declares `enum Key`, `Notification.Name.appSettingsDidChange` (`userInfo["key"]` = the changed key), and `measurementUnit` (`settings.measurementUnit`; missing or unknown → `.pixels`).
  - 0008 added `undoBudgetBytes` (`settings.undoBudgetBytes`, `docs/specs/todo/0008-history-stack-and-undo-bridge_TODO.md:174`). Its default is `HistoryStack.defaultBudgetBytes` = 1_073_741_824, and a missing, non-integer, or negative stored value reads as the default. It has no UI.
  - 0029 added `jpegQuality` (`settings.jpegQuality`, `static let defaultJPEGQuality = 95`, `docs/specs/todo/0029-flat-export-formats_TODO.md:138`). A missing or non-integer value reads as 95, and stored values are clamped to 0…100 on read. The setter clamps, writes, and posts. The JPEG Options dialog starts at the document's last quality this session, else at `AppSettings().jpegQuality`, and it never writes the key (`0029…:147`).
- **The status bar (0004)** follows one key across every window. `StatusBarModel.unit` is initialized from `AppSettings().measurementUnit` and observes `.appSettingsDidChange`. `selectUnit` writes the key, so all windows update (`0004…:87`, `:113-116`).
- **Checkerboard (0003, `0003…:30`, `:107-118`, `:133`).**
  - `struct CheckerboardStyle: Equatable, Sendable { squareSize: Double (points), lightColor, darkColor: ColorRGBA8 }`, with `static let standard` = 8 pt, #FFFFFF / #CCCCCC.
  - `CanvasFrame.checkerboard` defaults to `.standard`. The 0003 spec says: "`CheckerboardStyle.standard` is used directly until 0046 makes the style a setting (via `AppSettings`)."
  - `CanvasView.draw(_:)` builds the `CanvasFrame` (`0003…:164-168`). The checkerboard is a shader uniform, so changing it needs only a redraw, not a tile re-upload.
- **Panels (0006, `0006…:278-284`).**
  - `PanelKind` has `frameAutosaveName` (`"panel.tools"` …) and a pure `static func defaultFrame(for:size:visibleFrame:)` (16 pt margins, in Paint.NET's layout).
  - At launch, `PanelController` calls `setFrameUsingName(kind.frameAutosaveName)`. If that fails, it uses `defaultFrame(…, visibleFrame: NSScreen.main?.visibleFrame)`, then `setFrameAutosaveName`, so AppKit stores the frame under `NSWindow Frame panel.<kind>`.
  - The Tools panel size is its content's fitting size.
- **History budget (0008, `0008…:158-171`, `:205-210`).** `HistoryStack.setBudget(_:)` stores `max(0, bytes)`, enforces the budget (folding `steps[1]` into the base while `totalBytes > budgetBytes && currentIndex >= 2`), and returns the dropped IDs. `UndoBridge.setBudget(_:)` forwards to it, removes the dropped steps' `NSUndoManager` actions, and bumps `historyRevision`. 0008's Out of scope line 390 says: "Settings UI for the undo budget and live budget changes across open documents (0046, calling `UndoBridge.setBudget`)."
- **Menu (0001, `0001…:113`).** The app menu's "Settings…" item has key `,` with ⌘ and a `nil` action (a "placeholder → 0046"), and `MainMenuTests.placeholdersHaveNoAction` asserts that. 0045 moved all key equivalents into `Core/Shortcuts/ShortcutTable.swift` (row `app.settings`, ⌘,, status macStandard), gave the item the identifier `menu.app.settings`, and registered ⌘, in `SystemReservedShortcuts` with owner `app.settings`.
- **`LaunchOptions.resettableKeyPrefixes`** = `["tool.", "panel.", "NSWindow Frame panel.", "colors.", "settings."]` (0007). Every key this spec adds starts with `settings.`, so `-UITestResetDefaults` already clears them.
- **0006's `CanvasInputRouter`** classifies any non-document, non-panel key window as `.other`, so single-key tool shortcuts don't fire while the Settings window is key.

What's missing is the Settings window itself, settings for the checkerboard, and the live effect of changing the undo budget, the checkerboard, and the panel positions on what is already open.

## User story

As a PaintDotMac user, I choose **PaintDotMac > Settings…** (⌘,) and get one small Settings window. In it I can:

- pick my default units;
- make the transparency checkerboard lighter or darker and change its square size, with every open canvas redrawing at once;
- set how much memory undo history may use, with open documents dropping their oldest steps right away if the new limit is lower;
- set the quality the JPEG dialog starts at;
- move all four floating panels back to their default positions with one button.

Everything is saved and applies again after relaunch.

## Scope & changes

### Core (pure, unit-tested)

1. **`PaintDotMac/Core/Rendering/CheckerboardStyle.swift`** (extend 0003; existing members unchanged)
   ```swift
   enum CheckerboardBrightness: String, CaseIterable, Sendable {   // raw values are persisted
       case light, medium, dark
       var displayName: String            // "Light", "Medium", "Dark"
       var lightColor: ColorRGBA8         // light #FFFFFF, medium #999999, dark #4D4D4D (all opaque)
       var darkColor: ColorRGBA8          // light #CCCCCC, medium #808080, dark #333333 (all opaque)
   }
   enum CheckerboardSize: String, CaseIterable, Sendable {         // raw values are persisted
       case small, medium, large
       var displayName: String            // "Small", "Medium", "Large"
       var points: Double                 // 4, 8, 16
   }
   extension CheckerboardStyle {
       init(brightness: CheckerboardBrightness, size: CheckerboardSize)
   }
   ```
   - `CheckerboardStyle(brightness: .light, size: .medium) == .standard`. This is tested.
   - The `color(deviceX:deviceY:imageOrigin:backingScale:)` formula and the shader are unchanged. Only the uniform values differ.

2. **`PaintDotMac/Core/Settings/AppSettings.swift`** (complete it). Keep every existing member, key, and read rule from 0004, 0008, and 0029 exactly as specified there, so that their tests keep passing. Add the following:
   - **Keys.**
     - `Key.checkerboardBrightness = "settings.checkerboardBrightness"` and `Key.checkerboardSize = "settings.checkerboardSize"`.
     - `static let allKeys: [String]` = `[measurementUnit, checkerboardBrightness, checkerboardSize, undoBudgetBytes, jpegQuality]`. Every key starts with `"settings."`.
   - **`var checkerboardBrightness: CheckerboardBrightness { get nonmutating set }`.** A missing or unknown raw value reads as `.light`.
   - **`var checkerboardSize: CheckerboardSize { get nonmutating set }`.** A missing or unknown raw value reads as `.medium`.
   - **`var checkerboardStyle: CheckerboardStyle { get }`** returns `CheckerboardStyle(brightness:size:)` built from the two properties above.
   - **`undoBudgetBytes` setter.** It now clamps to `max(0, newValue)` before writing (the reads stay 0008's). Changing the budget isn't limited to the presets in the popup.
   - **Notifications.** Every setter (new and existing) writes the value and then posts `.appSettingsDidChange` on the injected center with `userInfo["key"] = <its Key>`. It posts on every set, even when the value didn't change, which keeps 0004's behavior. Observers must be idempotent.
   - **`enum UndoLimitOption: Hashable, Sendable`** (same file). This is the pure model behind the popup.
     - `static let presetBytes: [Int]` = `[268_435_456, 536_870_912, 1_073_741_824, 2_147_483_648, 4_294_967_296, 8_589_934_592]` (256 MB, 512 MB, 1 GB, 2 GB, 4 GB, 8 GB; binary units per H-6).
     - `static func options(storedBytes: Int, extraPresetBytes: Int? = nil) -> [Int]` returns the presets, plus `extraPresetBytes` when it is non-nil and > 0 (the DEBUG hook below), plus `storedBytes` when it isn't already in the list. The result is de-duplicated and sorted ascending.
     - `static func label(bytes: Int) -> String`. Let `GiB = 1_073_741_824` and `MiB = 1_048_576`. The rules:
       - `bytes % GiB == 0` and `bytes > 0` → `"\(bytes / GiB) GB"`.
       - `bytes ≥ GiB` → one decimal of `Double(bytes) / GiB`, rounded half away from zero, then `" GB"` (for example 1_610_612_736 → `"1.5 GB"`).
       - `bytes % MiB == 0` → `"\(bytes / MiB) MB"`. This includes 0 → `"0 MB"`.
       - Anything else → one decimal of `Double(bytes) / MiB`, then `" MB"` (5_000_000 → `"4.8 MB"`).
       - The decimal separator is always `"."` (the app is English-only, as in 0004).
     - Use `Int` arithmetic, which is 64-bit on all supported Macs.

### Platform glue (AppKit/SwiftUI; hosted tests and UI tests)

3. **`PaintDotMac/App/AppSettingsObserver.swift`** (new) is a small reusable subscription, `@MainActor final class AppSettingsObserver`.
   - `init(center: NotificationCenter = .default, keys: Set<String>, handler: @escaping @MainActor (String) -> Void)` adds an observer for `.appSettingsDidChange`. It calls `handler(key)` on the main actor only when `userInfo["key"]` is in `keys`.
   - It removes the observer in `deinit`, and it doesn't retain its owner (callers capture `[weak self]`).
   - All the live-update wiring below uses it, so each piece can be tested against a private center.

4. **Undo limit, live (NF-4, H-5).** `PaintDotMac/Document/PaintDocument.swift` (extend):
   - `PaintDocument` owns an `AppSettingsObserver` for `[Key.undoBudgetBytes]`, created when its `undoBridge` is created.
   - On change it calls `undoBridge.setBudget(AppSettings().undoBudgetBytes)`.
   - The change applies **immediately** to every open document, even while `undoBridge.isBusy` (0031) or mid-gesture. Folding steps into the base never changes live pixels, the current step, or redo steps (0008's rule is `currentIndex >= 2`), so an in-flight stroke or effect still commits normally.
   - The History panel (0010) refreshes through `historyRevision`. The edited state follows 0008's saved-marker folding rules.
   - Raising the limit never brings dropped steps back. There is no confirmation alert (see Open question 4).
   - For tests, add `init`-time injection: `PaintDocument` reads `AppSettings` through a `static var settingsProvider: () -> AppSettings = { AppSettings() }` (internal; tests swap it in and restore it), and through an observer center that defaults to `.default`. 0008 creates the bridge with `AppSettings().undoBudgetBytes` and has no injection point (`0008…:217`), so this provider is the one mechanism; 0008's initial-budget read switches to `Self.settingsProvider().undoBudgetBytes`.

5. **Checkerboard, live (CAN-4).**
   - **`PaintDotMac/Canvas/CanvasView.swift`** (extend 0003): add `var checkerboard: CheckerboardStyle = .standard { didSet { if checkerboard != oldValue { needsDisplay = true } } }`. `draw(_:)` passes it into `CanvasFrame.checkerboard`. It doesn't call `invalidateAll()`: the tiles' textures don't depend on the checkerboard.
   - **`PaintDotMac/Document/DocumentWindowController.swift`** (extend): when the canvas is created, set `canvasView.checkerboard = AppSettings().checkerboardStyle`. Own an `AppSettingsObserver` for `[Key.checkerboardBrightness, Key.checkerboardSize]` that reassigns it. So new and open windows always show the current style.
   - Layer thumbnails (0025 `ThumbnailRenderer`) keep `CheckerboardStyle.standard` (see Out of scope).

6. **Default units (APP-5).**
   - The Settings popup edits **the same key** `settings.measurementUnit` that the status bar uses. Per 0004 that key is app-wide and live, so choosing a unit in Settings immediately updates every open window's `statusBar.units` and is the unit for new windows.
   - A unit chosen in a status bar also updates the Settings popup, through the model's observer (step 8).
   - No new key is added. This is the reading of APP-5 recorded in Open question 3.

7. **Reset panel positions (APP-8, APP-2).** `PaintDotMac/App/PanelController.swift` (extend 0006):
   - When each panel is built, record `defaultSize[kind]`, the size 0006 passes to `defaultFrame` when no autosaved frame exists (the panel's initial content size; for Tools, its fitting size).
   - Add `func resetPanelPositions(visibleFrame: CGRect? = NSScreen.main?.visibleFrame)`. For every kind, it calls `panel.setFrame(PanelKind.defaultFrame(for: kind, size: defaultSize[kind], visibleFrame: vf), display: true)`.
     - It does this whether the panel is currently shown or hidden. A hidden panel reappears at the default frame when it is next shown.
     - With frame autosave active, AppKit rewrites `NSWindow Frame panel.<kind>` with the new frame, so the reset survives relaunch.
     - Panel **visibility** (`panel.<kind>.visible`) is unchanged.
     - With `visibleFrame == nil` (no screen), it does nothing.
   - Expose it through `AppDelegate` as `@objc func resetPanelPositions(_ sender: Any?)` for the Settings view to call (through the model's injected closure, step 8).

8. **`PaintDotMac/UI/SettingsView.swift`** (new) contains the SwiftUI view and its model.
   - **The model.** `@MainActor @Observable final class SettingsModel`.
     - `init(settings: AppSettings = AppSettings(), center: NotificationCenter = .default, extraUndoPresetBytes: Int? = LaunchOptions.current.undoLimitExtraPresetBytes, resetPanelPositions: @escaping @MainActor () -> Void)`.
     - It has observable `unit: MeasurementUnit`, `checkerboardBrightness`, `checkerboardSize`, `undoBudgetBytes: Int`, and `jpegQuality: Int`.
     - Each property's `didSet` writes through to `settings`, but only when the new value differs from the stored one, which avoids feedback loops.
     - An `AppSettingsObserver` on `AppSettings.allKeys` re-reads the changed value, so edits made elsewhere (the status bar) show up in the window.
     - `var undoLimitOptions: [Int]` returns `UndoLimitOption.options(storedBytes: undoBudgetBytes, extraPresetBytes:)`.
     - `func resetPanels()` calls the closure.
   - **The view.** `struct SettingsView: View` is a single-pane `Form` with `.formStyle(.grouped)`, fixed width 460 pt. Its sections and controls, top to bottom:

     | Section | Label | Control | Values | Default | Key | Accessibility ID |
     |---|---|---|---|---|---|---|
     | Units | "Default units:" | `Picker`, `.menu` | Pixels, Inches, Centimeters (0004 `displayName`) | Pixels | `settings.measurementUnit` | `settings.units` |
     | Canvas | "Checkerboard brightness:" | `Picker`, `.menu` | Light, Medium, Dark | Light | `settings.checkerboardBrightness` | `settings.checkerboardBrightness` |
     | Canvas | "Checkerboard size:" | `Picker`, `.menu` | Small, Medium, Large | Medium | `settings.checkerboardSize` | `settings.checkerboardSize` |
     | History | "Undo memory limit:" | `Picker`, `.menu` | `undoLimitOptions` labelled by `UndoLimitOption.label` | 1 GB | `settings.undoBudgetBytes` | `settings.undoLimit` |
     | Saving | "Default JPEG quality:" | `Slider(0...100, step: 1)` + integer `TextField` | 0–100 | 95 | `settings.jpegQuality` | `settings.jpegQuality` (slider), `settings.jpegQualityField` (field) |
     | Panels | (none) | `Button("Reset Panel Positions")` | (none) | (none) | `NSWindow Frame panel.*` | `settings.resetPanelPositions` |

   - **Footnotes** in secondary text:
     - Under the Units picker: "Also changes the units shown in open windows."
     - Under the undo limit: "When the limit is reached, the oldest history steps are removed."
     - Under the Reset button: "Moves the Tools, History, Layers, and Colors panels back to their default places."
   - **JPEG field input.** The field accepts integers 0–100. Out-of-range, non-numeric, or empty input reverts to the last valid value on commit, the same rule as 0029's dialog. Slider and field are bound to the same value.
   - **VoiceOver.** Each control's label is its visible label without the colon ("Default units", "Checkerboard brightness", "Checkerboard size", "Undo memory limit", "Default JPEG quality", "Reset Panel Positions"); the JPEG text field is "Default JPEG quality value" (0049's field-label rule, so slider and field are distinguishable). The slider's value is `"<n>"`.

9. **`PaintDotMac/App/SettingsWindowController.swift`** (new): `@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate`.
   - The window is an `NSWindow` with `contentViewController = NSHostingController(rootView: SettingsView(model:))`.
     - Style mask `[.titled, .closable]` (not resizable, not miniaturizable). Title "Settings".
     - `identifier = NSUserInterfaceItemIdentifier("settingsWindow")`, `isReleasedWhenClosed = false`, `tabbingMode = .disallowed`, `collectionBehavior` includes `.fullScreenAuxiliary`.
     - No frame autosave. It is centered (`center()`) the first time it is shown in each launch, and keeps its position until quit.
   - `func show()` calls `showWindow(nil)` and `window?.makeKeyAndOrderFront(nil)`. It makes the window key, unlike the panels.
   - There is a single instance, owned lazily by `AppDelegate`. Choosing Settings… while the window is open brings it to the front and doesn't create a second one.
   - Closing it (the red button or ⌘W) only orders it out. Every control has already written its value, so there's no OK or Cancel, as is usual for Mac settings windows.
   - ⌘W works because `.closable` windows handle `performClose:`.

10. **Menu.** `PaintDotMac/App/AppDelegate.swift` and `App/MainMenu.swift`:
    - Add `@objc func showSettingsWindow(_ sender: Any?)` on `AppDelegate`. It creates the controller on first use and calls `show()`.
    - Give the "Settings…" item (identifier `menu.app.settings`, added by 0045) that action (target `nil`, so the responder chain reaches the app delegate). It is enabled at all times, with or without documents.
    - Keep its key equivalent coming from 0045's `ShortcutTable` (⌘,). Don't add a second definition.
    - Update 0001's `MainMenuTests.placeholdersHaveNoAction`: 0005 already wired New…, so Settings… was the last placeholder — delete that test and add `settingsItemOpensSettings` (below). 0045 already gave the item the identifier `menu.app.settings` and the table row `app.settings` (⌘,); its `MainMenuShortcutTests` check key equivalents, not actions, so they need no change.

11. **`PaintDotMac/App/LaunchOptions.swift`** (extend 0001, `#if DEBUG` only):
    - Add `static let current: LaunchOptions`: in Debug `LaunchOptions(arguments: ProcessInfo.processInfo.arguments)`, in Release `LaunchOptions(arguments: [])` (so every hook reads nil/false). No earlier spec defines a shared instance; this one is the accessor later hooks use (0048's `perfFrameProbeOutput`, 0051's `windowContentSizeOverride`). Existing hook reads stay as their specs wrote them. Test: `LaunchOptionsTests.currentIsEmptyForTestRunner` — in the hosted unit tests (launched without hook arguments) `LaunchOptions.current.undoLimitExtraPresetBytes == nil` and `fixtureURLs == []`.
    - Add `-UITestUndoLimitPreset <bytes>`, parsed into `undoLimitExtraPresetBytes: Int?`. Only positive integers are accepted; anything else is ignored.
    - It adds one extra item to the Undo memory limit popup so that UI tests can pick a tiny limit (1 MiB, labelled "1 MB") through the real UI.
    - In Release, `undoLimitExtraPresetBytes` is always nil.

12. **`project.yml`.** Nothing changes beyond the new files, which the existing source globs pick up. Run `xcodegen generate`.

13. **PRD.** This spec makes no changes to it (the sub-agent may not edit it). The decisions recorded under *Open questions* need to go into PRD §12 once the user confirms them.

## Acceptance criteria

**Menu and window**
- [ ] PaintDotMac > Settings… (⌘,) is enabled with or without open documents and opens one window titled "Settings" (identifier `settingsWindow`). Choosing it again doesn't create a second window. ⌘W closes it. → `MainMenuTests.settingsItemOpensSettings`, `SettingsWindowControllerTests.singleInstance`, `SettingsUITests.testCommandCommaOpensSingleSettingsWindow`
- [ ] While the Settings window is key, single-key tool shortcuts don't fire. → `SettingsUITests.testToolKeysIgnoredInSettings`

**Default units**
- [ ] The window shows Default units (Pixels by default). Changing it updates every open window's status-bar units at once, and new windows use it. It persists across relaunch. → `SettingsModelTests.unitWritesThrough`, `SettingsUITests.testDefaultUnitsAppliesToOpenWindows`, `SettingsUITests.testSettingsPersistAcrossRelaunch`
- [ ] A unit chosen in a status bar shows up in the open Settings window. → `SettingsModelTests.externalChangeUpdatesModel`, `SettingsUITests.testStatusBarUnitUpdatesSettings`

**Checkerboard**
- [ ] Checkerboard brightness is Light, Medium, or Dark, with the exact colors in step 1 (default Light = #FFFFFF / #CCCCCC). Checkerboard size is Small (4 pt), Medium (8 pt, default), or Large (16 pt). Defaults equal `CheckerboardStyle.standard`. → `CheckerboardStyleSettingsTests.*`, `AppSettingsTests.checkerboard*`
- [ ] Changing either setting redraws every open canvas with the new style, without re-uploading tiles, and new windows use it. → `MetalCanvasRendererTests.customCheckerboardMatchesOracle`, `MetalCanvasRendererTests.checkerboardChangeUploadsNoTiles`, `CanvasCheckerboardBindingTests.*`, `SettingsUITests.testCheckerboardBrightnessRedrawsCanvas`

**Undo memory limit**
- [ ] The Undo memory limit offers 256 MB, 512 MB, 1 GB (default), 2 GB, 4 GB, and 8 GB, plus the stored value labelled per `UndoLimitOption.label` when it isn't one of those. → `UndoLimitOptionTests.*`
- [ ] Lowering the limit applies at once to every open document: the oldest steps are dropped (never the base step, the current step, or redo steps) and disappear from the History panel. Raising it drops nothing. → `UndoBudgetLiveTests.*`, `SettingsUITests.testLoweringUndoLimitDropsOldSteps`

**JPEG quality**
- [ ] Default JPEG quality is 0–100 (default 95) through a slider and field. Invalid field input reverts. The JPEG Options dialog of a document that has no last-used quality starts at that value. → `SettingsModelTests.jpegQualityClampsAndWrites`, `SettingsUITests.testDefaultJPEGQualityUsedByDialog`, `SettingsUITests.testJPEGFieldRejectsInvalidInput`

**Panel positions**
- [ ] Reset Panel Positions moves all four panels to `PanelKind.defaultFrame`, leaves their visibility unchanged, and the reset positions persist across relaunch. → `PanelControllerResetTests.*`, `SettingsUITests.testResetPanelPositions`

**Persistence, notifications, and smoke**
- [ ] Every setting persists under its `settings.*` key and is cleared by `-UITestResetDefaults`. Every setter posts `.appSettingsDidChange` with its key. → `AppSettingsTests.allKeysArePrefixed`, `AppSettingsTests.everySetterPosts`, `AppSettingsTests.roundTripAll`, `SettingsUITests.testSettingsPersistAcrossRelaunch`, `SettingsUITests.testResetDefaultsRestoresSettings`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Corrupt stored values.**
  - `settings.checkerboardBrightness = "neon"` or an `Int` → `.light`. `settings.checkerboardSize = 7` → `.medium`.
  - Undo and JPEG values are read per 0008 and 0029 (negative or garbage budget → 1 GiB; JPEG 150 → 100, "x" → 95).
  - The window opens with those effective values and doesn't crash. → `AppSettingsTests.checkerboardUnknownFallsBack`, `SettingsModelTests.initReadsEffectiveValues`
- **Stored budget not in the presets** (for example 5_000_000 written by a test or an older build): the popup shows an extra "4.8 MB" item, selected. Picking a preset removes it from the list on the next render. → `UndoLimitOptionTests.storedCustomIsListedSorted`, `SettingsModelTests.customBudgetListed`
- **Budget 0** (only reachable by writing defaults): reads 0, label "0 MB". Every document keeps only base + current step (0008 rule). → `UndoBudgetLiveTests.zeroBudgetKeepsBaseAndCurrent`
- **Lowering while undone:** with the current step at index 1, nothing is dropped (`currentIndex >= 2`). Redo steps are never dropped. → `UndoBudgetLiveTests.redoStepsSurviveLowering`
- **Dropping the saved step** flips edited state per 0008's folding rules. No crash, and the document shows as edited. → `UndoBudgetLiveTests.droppingSavedStepMarksEdited`
- **Lowering during an effect run or mid-stroke:** the budget applies immediately, and the in-flight commit then records normally and is itself subject to enforcement. → `UndoBudgetLiveTests.loweringDuringPendingCommit`
- **No documents open:** changing any setting only writes defaults. The next document picks up the undo budget and checkerboard at creation. → `UndoBudgetLiveTests.newDocumentUsesCurrentBudget`, `CanvasCheckerboardBindingTests.newCanvasUsesCurrentStyle`
- **Closed documents:** an observer whose owner has been deallocated never fires (no crash on change after closing). → `AppSettingsObserverTests.deallocatedObserverDoesNotFire`
- **Reset panels with no screen** (`visibleFrame == nil`): nothing happens. **With hidden panels:** frames are set, visibility is unchanged, and they show at the default frame when toggled on. → `PanelControllerResetTests.noScreenIsNoOp`, `.hiddenPanelsResetWithoutShowing`
- **Same-value writes:** the model doesn't write when the value is unchanged, so selecting the current item posts nothing and observers don't loop. → `SettingsModelTests.noWriteForSameValue`
- **The Settings window and sheets:** opening Settings while a document has a sheet (JPEG dialog, New Image) is allowed. The window is independent and not modal. Changing JPEG quality while a JPEG dialog is open doesn't change that open dialog (it read its start value when it opened). → `manual` (window/sheet interplay; covered partly by `testDefaultJPEGQualityUsedByDialog`)
- **Full screen:** the Settings window can appear over a full-screen document window (`.fullScreenAuxiliary`). → manual

## Test plan

All unit tests use Swift Testing. They isolate `UserDefaults(suiteName: "<Suite>.\(UUID())")`, remove the suite afterwards, and use a private `NotificationCenter()`.

### Unit tests

- **`PaintDotMacTests/Rendering/CheckerboardStyleSettingsTests.swift`**
  - `brightnessColors`: exact RGBA for each case per step 1 (light 255/204, medium 153/128, dark 77/51; all alpha 255, r == g == b).
  - `sizePoints`: 4 / 8 / 16.
  - `defaultEqualsStandard`: `CheckerboardStyle(brightness: .light, size: .medium) == .standard`.
  - `largeSizeColorAt2x`: `CheckerboardStyle(brightness: .dark, size: .large).color(deviceX: 31, deviceY: 0, imageOrigin: (0, 0), backingScale: 2)` is the light color #4D4D4D, and at x = 32 it's #333333 (side = 32 device px, hand-computed).
  - `smallSizeColorAt1x`: small at 1× gives x 3 → light, x 4 → dark, (4, 4) → light.
  - `rawValuesStable`: raw values are `"light", "medium", "dark"` and `"small", "medium", "large"`.
  - `displayNames`.
- **`PaintDotMacTests/Settings/AppSettingsTests.swift`** (extend 0004/0008/0029's suite; existing tests unchanged)
  - `checkerboardDefaults`: `.light` and `.medium`; `checkerboardStyle == .standard`.
  - `checkerboardRoundTrip`: set `.dark` and `.small`; a new `AppSettings` on the same suite reads them; the stored strings are `"dark"` and `"small"`; `checkerboardStyle == CheckerboardStyle(brightness: .dark, size: .small)`.
  - `checkerboardUnknownFallsBack`: `"neon"` → `.light`; `Int` 7 under the size key → `.medium`.
  - `undoBudgetSetterClampsNegative`: set −5 → stored 0, reads 0. Set 2_147_483_648 → reads 2_147_483_648.
  - `allKeysArePrefixed`: `allKeys` has 5 unique entries, all with prefix `"settings."`, and `LaunchOptions.shouldReset(key:)` is true for each.
  - `everySetterPosts`: for each of the five setters, set a value and assert exactly one `.appSettingsDidChange` arrives on the private center with `userInfo["key"]` equal to that key. Also check that the setter posts on a same-value set (documented behavior).
  - `roundTripAll`: set every property to a non-default value (cm, medium, large, 536_870_912, 40); a second instance reads all five identically.
- **`PaintDotMacTests/Settings/UndoLimitOptionTests.swift`**
  - `presets`: equal to the six values listed.
  - `labels`:
    - 268_435_456 → "256 MB", 536_870_912 → "512 MB", 1_073_741_824 → "1 GB", 8_589_934_592 → "8 GB";
    - 1_048_576 → "1 MB", 0 → "0 MB", 5_000_000 → "4.8 MB", 1_610_612_736 → "1.5 GB", 1_073_741_825 → "1.0 GB";
    - 1_572_864 → "1.5 MB".
  - `storedPresetNotDuplicated`: `options(storedBytes: 1 GiB).count == 6`.
  - `storedCustomIsListedSorted`: `options(storedBytes: 5_000_000)` = `[5_000_000] + presets`.
  - `extraPresetIncluded`: `options(storedBytes: 1 GiB, extraPresetBytes: 1_048_576).first == 1_048_576` and count 7. With `extraPresetBytes: 0` or nil, count is 6.

### Hosted tests (`@MainActor`, app host)

- **`PaintDotMacTests/App/AppSettingsObserverTests.swift`**
  - `firesOnlyForObservedKeys`: post with key A then key B; a handler observing {A} gets `["A"]`.
  - `ignoresOtherCenters`.
  - `deallocatedObserverDoesNotFire`: set the observer to nil, then post; the handler count stays 0.
- **`PaintDotMacTests/Document/UndoBudgetLiveTests.swift`** builds two `PaintDocument`s with the injected `settingsProvider`, the private suite and center, a 64×64 image, and a fixed budget. It commits real `TileDiffHistoryItem`s, each touching one tile (cost 525_312 including the 1_024 overhead, per 0008's numbers).
  - `loweringDropsOldestInAllDocuments`: start at a 1 GiB budget. Doc A has 3 steps, doc B has 2. Set `settings.undoBudgetBytes = 1_048_576` through `AppSettings`. Then:
    - A's steps are [Open Image, step3]. Its `historyRevision` increased by exactly 1. Undo once restores the pixels of the state after step 2 (oracle: a snapshot taken at commit time).
    - B's steps are [base, step2].
    - `undoManager.canUndo` matches `history.canUndo` in both.
  - `raisingDropsNothing`: after lowering, raise to 8 GiB. Step counts are unchanged.
  - `redoStepsSurviveLowering`: 3 steps, undo twice, lower to 0. Nothing is dropped and `canRedo` is true.
  - `zeroBudgetKeepsBaseAndCurrent`: 3 steps, lower to 0 → steps [base, step3].
  - `droppingSavedStepMarksEdited`: mark saved at step 1, commit 2 more, lower to 1 MiB. `isDocumentEdited == true`, and `history.savedStepID` follows 0008's rule (nil or base as specified there).
  - `loweringDuringPendingCommit`: lower to 1 MiB while a `BrushStroke` is begun but not ended. Ending it records the step and enforcement then leaves [base, newStep].
  - `newDocumentUsesCurrentBudget`: with settings at 536_870_912, a new document's `history.budgetBytes == 536_870_912`.
- **`PaintDotMacTests/Canvas/CanvasCheckerboardBindingTests.swift`** (the hosted `DocumentWindowController` with a 16×16 transparent image; skipped only if Metal is unavailable, and that skip is reported as a failure by the gate, so it must run on the dev Mac):
  - `newCanvasUsesCurrentStyle`: settings dark+large before window creation → `canvasView.checkerboard == CheckerboardStyle(brightness: .dark, size: .large)`.
  - `changeUpdatesOpenCanvas`: change brightness to `.medium` → the canvas style updates and `needsDisplay` is true.
  - `unrelatedKeyDoesNotTouchCanvas`: changing `jpegQuality` leaves `checkerboard` identical.
- **`PaintDotMacTests/Rendering/MetalCanvasRendererTests.swift`** (extend 0003/0024)
  - `customCheckerboardMatchesOracle`: a 32×32 fully transparent image at zoom 1, 1× and 2× backing, styles (dark, small) and (medium, large). Every device pixel equals `CanvasReferenceRenderer` with the same style, exactly. Also check spot values by hand: device (0, 0) = light color, and device (side, 0) = dark color.
  - `semiTransparentOverCustomCheckerboard`: one pixel (255, 0, 0, 128) over the dark light-square #4D4D4D → expected `round(255·128/255 + (1 − 128/255)·77)` per channel (hand-computed R = 166, G = B = 38), ±1.
  - `checkerboardChangeUploadsNoTiles`: render, change `CanvasFrame.checkerboard`, render again → `tilesUploadedLastFrame == 0` and the output differs.
- **`PaintDotMacTests/App/PanelControllerResetTests.swift`** (injected `AppModel` on a suite; remove `NSWindow Frame panel.*` keys from `.standard` before and after, as 0006's tests do):
  - `resetMovesAllToDefault`: move every panel to an arbitrary frame (`setFrame`), call `resetPanelPositions(visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))`. Each panel's frame equals `PanelKind.defaultFrame(for:size:visibleFrame:)` with its recorded default size. Also check by hand: History's origin x = 1440 − 16 − w and y = 875 − 16 − h.
  - `resetPersists`: after reset, `UserDefaults.standard.string(forKey: "NSWindow Frame panel.history")` decodes (`NSRectFromString` of its first four fields) to the default frame.
  - `hiddenPanelsResetWithoutShowing`: hide Layers, reset → frame is the default, `isPanelVisible(.layers) == false`, and the panel isn't on screen.
  - `noScreenIsNoOp`: `resetPanelPositions(visibleFrame: nil)` leaves frames unchanged.
- **`PaintDotMacTests/UI/SettingsModelTests.swift`**
  - `initReadsEffectiveValues`: with corrupt stored values, the model shows the effective values.
  - `unitWritesThrough`: `model.unit = .inches` → `AppSettings.measurementUnit == .inches` and one notification.
  - `externalChangeUpdatesModel`: write `.centimeters` through a separate `AppSettings` on the same suite and center → `model.unit == .centimeters` with no extra write (notification count 1).
  - `noWriteForSameValue`: assign the current value → 0 notifications.
  - `jpegQualityClampsAndWrites`: set 150 → stored 100, model 100.
  - `customBudgetListed`: stored 5_000_000 → `undoLimitOptions.first == 5_000_000`.
  - `resetPanelsCallsClosure`: called once.
- **`PaintDotMacTests/App/SettingsWindowControllerTests.swift`**
  - `windowConfigured`: title "Settings", identifier `settingsWindow`, style mask has `.titled`/`.closable` and not `.resizable`, `isReleasedWhenClosed == false`, `tabbingMode == .disallowed`.
  - `singleInstance`: calling `AppDelegate.showSettingsWindow` twice gives exactly one window with that identifier in `NSApp.windows`.
  - `closeOrdersOut`: after `performClose`, `isVisible == false` and showing again reuses the same window object.
- **`PaintDotMacTests/App/MainMenuTests.swift`** (extend), `settingsItemOpensSettings`: the app menu's "Settings…" item has action `#selector(AppDelegate.showSettingsWindow(_:))`, target nil, identifier `menu.app.settings`, key equivalent "," with `[.command]` (from `ShortcutTable`).
- **`PaintDotMacTests/App/LaunchOptionsTests.swift`** (extend):
  - `undoLimitPresetParsed`: `["-UITestUndoLimitPreset", "1048576"]` → 1_048_576.
  - `"abc"`, `"0"`, `"-5"`, or a missing value → nil.

### Integration (headless)

Covered by `UndoBudgetLiveTests` above, which runs a real document session (commit, lower the limit, undo, assert pixels) through `PaintDocument` and `UndoBridge`.

### UI tests: `PaintDotMacUITests/SettingsUITests.swift`

All tests use `UITestApp` and launch with `-UITestResetDefaults YES` unless stated. Fixtures are generated at test time with `UITestFixtures.writePNG` / `writeJPEG`. The Settings window is opened with ⌘, unless stated, and found as `app.windows["settingsWindow"]`.

- **Opening and focus**
  - `testCommandCommaOpensSingleSettingsWindow`: with no document open, the menu item `menuItem("PaintDotMac", "Settings…")` is enabled. Press ⌘, → one `settingsWindow` exists, and all six controls exist by identifier. Press ⌘, again → there's still one. Press ⌘W → none.
  - `testToolKeysIgnoredInSettings`: open a 64×64 PNG; the active tool is Paintbrush. Open Settings and click into `settings.jpegQualityField`, type "e" (Eraser key) → close Settings → `tool.paintbrush` is still selected (0006 selection state).
- **Units**
  - `testDefaultUnitsAppliesToOpenWindows`: open two 4000×2000 96-DPI fixtures. In Settings, set `settings.units` to "Inches" → both windows' `statusBar.units` read "Inches" and `statusBar.imageSize` reads "41.67 × 20.83". Open a third fixture → "Inches".
  - `testStatusBarUnitUpdatesSettings`: open Settings and a fixture. Choose Centimeters in the status bar → `settings.units` value "Centimeters".
- **Checkerboard**
  - `testCheckerboardBrightnessRedrawsCanvas`: open a 64×64 fully transparent PNG (at 100 % it's centered in the canvas).
    - Take `canvas.screenshot()` and sample the pixel at the canvas center: each RGB component ≥ 190 (light checkerboard; tolerance for color management).
    - Set `settings.checkerboardBrightness` to "Dark" → after redraw (poll up to 2 s) the same pixel's components are all ≤ 90.
    - Set "Light" again → ≥ 190.
- **Undo memory limit**
  - `testLoweringUndoLimitDropsOldSteps`: launch with `-UITestUndoLimitPreset 1048576` and a 64×64 opaque white PNG.
    - Make three short Paintbrush drags inside the image near the canvas center (`dragOnCanvas` from (0.48, 0.5) to (0.52, 0.5)). Each touches only tile (0, 0), costing 525_312 bytes.
    - The History list shows 4 rows (Open Image + 3 × Paintbrush).
    - In Settings, choose "1 MB" in `settings.undoLimit` → the History list shows 2 rows ("Open Image", "Paintbrush"). Edit > Undo is enabled once; after one ⌘Z, Undo is disabled.
    - Set "1 GB" → still 2 rows.
- **JPEG quality**
  - `testDefaultJPEGQualityUsedByDialog`: in Settings, type "50" + Return in `settings.jpegQualityField` → the slider value reads 50. Close Settings.
    - Open a 64×64 JPEG fixture, paint one stroke, press ⌘S → the JPEG Options sheet's `jpegOptions.qualityField` value is "50". Cancel.
  - `testJPEGFieldRejectsInvalidInput`: type "150" + Return → the field reverts to "95". Type "abc" + Return → "95".
- **Panel positions**
  - `testResetPanelPositions`: open a fixture and record the History panel's frame (`app.windows["panel.history"].frame`, the default after reset).
    - Drag its title bar by (−200, +150) and check the frame changed by ≥ 100 pt.
    - In Settings, click `settings.resetPanelPositions` → the frame equals the recorded one within 1 pt, and all four panels are still visible.
    - Terminate and relaunch with `resetDefaults: false` → the History frame still equals the recorded one within 1 pt.
- **Persistence and reset**
  - `testSettingsPersistAcrossRelaunch`: set units "Centimeters", brightness "Medium", size "Large", undo limit "2 GB", JPEG 40.
    - Terminate and relaunch with `resetDefaults: false`, then open Settings → all five values read back (popup values "Centimeters", "Medium", "Large", "2 GB"; field "40").
    - A newly opened fixture shows `statusBar.units` "Centimeters".
  - `testResetDefaultsRestoresSettings`: after the above, relaunch with the default reset → Pixels, Light, Medium, 1 GB, 95.

### Performance

None of NF-1 to NF-4's measured paths change. A checkerboard change re-renders one frame without uploads (asserted by `checkerboardChangeUploadsNoTiles`).

### Quality gate

`.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: a clean build with no warnings, every test passing with none skipped, UI tests run, and the launch smoke passing. Warn the user not to use the Mac while the UI tests run.

### Manual verification

1. **⌘, and window behavior.** Open Settings in light and dark mode and check the grouped form is legible, labels align, and footnotes are secondary text. Open it over a full-screen document window and check it appears in that Space.
2. **Checkerboard look.** On a Retina display, with a transparent image open at 100 %, 400 %, and 25 %, cycle brightness and size and check that squares are sharp, anchored to the image's top-left, unchanged in size while zooming, and that all open windows switch at once. Layer thumbnails stay light (expected).
3. **Undo limit feel.** With a large image and many strokes, lower the limit to 256 MB and check the History panel shrinks immediately without a hang. Undo still works down to the new oldest step.
4. **Panel reset on a second display.** With panels moved to a second screen, Reset Panel Positions puts them on the main screen's default corners.
5. **VoiceOver.** VoiceOver reads each control's label and the JPEG slider value.

## Open questions

Each question below has its recommended answer applied in this spec and needs the user's confirmation, after which it should be recorded in PRD §12.

1. **What "checkerboard style" offers.** Paint.NET 5 offers only a "Transparency Checkerboard Brightness" control on its Canvas tab (paint.net/doc/latest/SettingsDialog.html; no range documented), and no color or size choice. **Recommended (applied):** two popups, **Checkerboard brightness** Light (#FFFFFF/#CCCCCC, default) / Medium (#999999/#808080) / Dark (#4D4D4D/#333333), and **Checkerboard size** Small 4 pt / Medium 8 pt (default) / Large 16 pt. The alternatives are a continuous brightness slider like Paint.NET's, or brightness only.
2. **What "the option to restore panel positions" means.** It could be (a) a button that moves the panels back to their default positions now, or (b) a "Remember panel positions" toggle. **Recommended (applied):** (a), a "Reset Panel Positions" button. Panel frames stay remembered by frame autosave as APP-2 requires. The reset moves all four panels (shown or hidden) to `PanelKind.defaultFrame` on the main screen, persists, and doesn't change which panels are visible.
3. **Default units vs the status-bar unit.** APP-5 says the unit "is chosen from a status-bar popup and persisted; its default comes from Settings". 0004 already made that one app-wide key, live in all windows. **Recommended (applied):** Settings edits the same `settings.measurementUnit` key, so changing it also changes the unit in every open window, and a status-bar change shows in Settings. The alternative is a separate "default for new windows" key, with status-bar changes kept per window or session.
4. **Lowering the undo limit.** **Recommended (applied):** it applies immediately to all open documents, dropping their oldest steps per H-5 without a confirmation alert, with the presets 256 MB, 512 MB, 1 GB (default), 2 GB, 4 GB, and 8 GB. A stored non-preset value is shown as an extra item. The alternatives are confirming before steps would be dropped, or applying only to new documents.
5. **Window layout.** Paint.NET's Settings dialog has tabs (User Interface, Canvas, Tools, …). **Recommended (applied):** a single-pane grouped form titled "Settings" (sections Units, Canvas, History, Saving, Panels), since there are only five settings. No OK/Cancel buttons: changes apply as you make them.

## Out of scope

- The other settings in Paint.NET's dialog (theme, language, canvas border color and shadow, tool defaults, hardware acceleration, color management, updates, plugins, diagnostics): PRD §2.2 / not in APP-8.
- Layer thumbnails (0025 `ThumbnailRenderer`) keep `CheckerboardStyle.standard`. Only the canvas follows the setting.
- The memory cap for image size (`ImageLimits`, 0002), which is not exposed in Settings.
- Disk-backed history instead of dropping steps (H-4, 0062).
- Docking panels (APP-3, 0052). Showing hidden panels as part of a reset.
- Autosave and crash recovery settings (0047, NF-5). Accessibility and appearance work beyond standard SwiftUI controls (0049).
- Shortcut definitions (0045's `ShortcutTable` stays the single source; this spec only wires the action).
