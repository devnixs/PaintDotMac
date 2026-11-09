# 0004 — Add zoom, trackpad/Space panning, and the document status bar

> Source: PRD.md §5.2 CAN-1 (except Zoom to Selection, which 0014 adds), CAN-2; PRD.md §5.1 APP-5 (the selection-size field is present but empty until 0014 fills it); PRD.md §5.12 (Zoom In ⌘=, Zoom Out ⌘−, Actual Size ⌘0, Zoom to Window ⌘B); PRD.md §5.2 CAN-6 and §12 D-29 (100% = one image pixel per device pixel, 1% lowest step, no scroll bars in v1.0); PRD.md §12 D-7 (per-document DPI); PRD.md §4 Testing and §12 D-37 (`-UITestResetDefaults` clears `settings.*`); PRD.md §4 (AppKit lifecycle, SwiftUI status bar in `NSHostingView`).
> Paint.NET references: View menu — https://www.getpaint.net/doc/latest/ViewMenu.html (now served from https://paint.net/doc/latest/ViewMenu.html); Status Bar — https://www.getpaint.net/doc/latest/StatusBar.html; zoom presets — Paint.NET 4.x `PaintDotNet/ScaleFactor.cs` (decompiled copy: https://github.com/vaginessa/Paint.Net4/blob/master/PaintDotNet/ScaleFactor.cs) and Paint.NET 3.36 `src/Core/ScaleFactor.cs` (https://github.com/wangdeshui/paint.net/blob/master/src/Core/ScaleFactor.cs).
> Milestone: M0
> Depends on: 0003-metal-canvas-rendering (and through it 0001, 0002)

## Context

No application code exists yet. When this spec starts, these will exist (from sibling specs; use their exact names and signatures, and read their spec files in `docs/specs/done/` first):

- 0001: `PaintDotMac/App/MainMenu.swift` (main menu built in code; its View menu holds Enter Full Screen ⌃⌘F, identifier `menu.view`), `PaintDotMac/App/LaunchOptions.swift` (`-UITestOpen`, `-UITestResetDefaults`, `resettableKeyPrefixes = ["tool.", "panel.", "NSWindow Frame panel."]`), `PaintDotMac/Document/PaintDocument.swift`, `PaintDotMac/Document/DocumentWindowController.swift`, `PaintDotMacUITests/Support/UITestApp.swift` (launches with a fixture generated into a temp dir; menu and canvas helpers).
- 0002: `Core/Model/LayeredImage.swift` (`size: PixelSize`, `dpi`, `layers`, `activeLayerIndex`), `Core/Model/PixelSize.swift` (+ `PixelPoint`, `PixelRect`), `Core/IO/ImageDecoder.swift` (reads DPI from file metadata, default 96; one `dpi: Double` per document). Test support `PaintDotMacUITests/Support/UITestFixtures.swift` (`writePNG(width:height:pixel:properties:)`, which sets DPI through ImageIO properties).
- 0003: `Core/Rendering/CanvasTransform.swift` (`imageSize`, `viewSize`, `backingScale`, `zoom` with `setZoom(_:)`, `center` = canvas point at the view center, a pixel-aligned `imageOriginInDevice`; view ↔ device ↔ canvas ↔ pixel conversions), `Core/Rendering/MetalCanvasRenderer.swift`, `PaintDotMac/Canvas/CanvasView.swift` (`MTKView` subclass, accessibility identifier `canvas`).

(`Core/` = `PaintDotMac/Core/` throughout.)

What is missing: the user can't change the zoom or move around the image, and the document window has no status bar. This spec adds:

1. **Zoom (CAN-1).** 1% to 3200%. View menu items Zoom In, Zoom Out, Zoom to Window, Actual Size, stepping through Paint.NET's preset zoom levels.
2. **Navigation (CAN-2).** Trackpad pinch zooms around the pointer, two-finger scroll (and the mouse wheel) pans, ⌘+scroll zooms around the pointer (Paint.NET's Ctrl+wheel), and holding Space turns the next drag into a pan. The Pan *tool* (H) is 0006, which reuses the pan code written here.
3. **Status bar (APP-5).** Cursor position, selection size (empty until 0014), image size, a units popup (Pixels / Inches / Centimeters, using the document's DPI), and the zoom level.

### Paint.NET behavior mirrored

- **View menu** (ViewMenu.html): "Zoom In … The amount of magnification is increased in fixed steps", "Zoom Out … reduces in fixed steps (e.g. 100%, 67%, 50%, 33%, 25%, 20%…)", "Zoom to Window: If the image is larger than the Editing Window at 100%, it will be reduced to fit within the Editing Window", "Actual Size: This sets the zoom level to 100%". Paint.NET's menu order is Zoom In, Zoom Out, Zoom to Window, Zoom to Selection, Actual Size.
- **Preset steps.** Paint.NET 4's `ScaleFactor.scales` are, as fractions: 1/32, 1/24, 1/16, 1/12, 1/8, 1/6, 1/5, 1/4, 1/3, 1/2, 2/3, 1, 3/2, 2, 3, 4, 5, 6, 8, 12, 16, 24, 32, with `MinValue = 1/100` and `MaxValue = 32/1`. Those bounds are exactly CAN-1's 1%–3200%, and the zoom-out steps match the doc's "100%, 67%, 50%, 33%, 25%, 20%". (The current docs also list Paint.NET 5's finer steps up to 6400%, e.g. 1000%, 1400%; PRD CAN-1 caps the zoom at 3200%, so this spec uses the Paint.NET 4 list.) Paint.NET's own `GetNextSmaller()` can't step below 1/32 (and from 2% it actually jumps *up* to 3.125%); this spec adds `MinValue` 1% as the lowest stop so Zoom Out reaches the CAN-1 minimum and never zooms in.
- **Status bar** (StatusBar.html): "The dimensions of the currently active image (width x height) are displayed using the currently set units of measurement"; cursor "location is measured from the top left corner of the image which is position (0,0). A negative location value indicates the cursor is either above or left of the top left corner of the image"; the units tool offers pixels, inches, or centimeters, default pixels. Paint.NET's editable zoom box, zoom slider, and quick-size icon are not required by APP-5 and are out of scope.

### Zoom units (CAN-6 contract from 0003)

`zoom` is the value 0003's `CanvasTransform` already uses: device pixels per image pixel. Per PRD CAN-6 and D-29 (and Paint.NET on high-DPI displays), 100% means one image pixel per **device** pixel. Every place in this spec that compares a zoom with a view size (fit-to-window, clamping, centering) converts the view size into device pixels through `CanvasTransform.backingScale` (`s`).

View space below is 0003's view space: AppKit points in the canvas view's bounds, origin **bottom-left**, y **up** (`CanvasView.isFlipped == false`). Canvas space is image pixels, origin top-left, y down. So with `H` = view height, `ox`/`oy` = 0003's rounded `imageOriginInDevice`: `viewToCanvas(v) = ((v.x·s − ox) / zoom, ((H − v.y)·s − oy) / zoom)` and `canvasToView(c) = ((ox + c.x·zoom) / s, H − (oy + c.y·zoom) / s)`. The image's top-left corner is at the **top** of the view; a positive view-space `dy` moves content **up**. Every hand value below is computed with these formulas, including 0003's origin rounding (the cases are chosen so the origin is an integer before rounding).

There are **no scroll bars** in v1.0 (PRD CAN-6, D-29): panning is by trackpad/wheel scroll, Space-drag, and the Pan tool (0006).

## User story

As a PaintDotMac user, I can zoom in and out with ⌘= / ⌘−, jump to 100% with ⌘0 or fit the image with ⌘B, pinch or ⌘-scroll to zoom around the pointer, pan with two fingers or by holding Space and dragging, and read the cursor position, image size, and zoom in a status bar at the bottom of the window, in pixels, inches, or centimeters.

## Scope & changes

### Core (pure, unit-tested; no AppKit/SwiftUI)

- **`Core/Rendering/ZoomLevels.swift`** — `enum ZoomLevels` (namespace, all `static`):
  - `static let minimum: Double = 0.01`, `static let maximum: Double = 32.0`.
  - `static let stops: [Double]` — exactly `[0.01, 1/32, 1/24, 1/16, 1/12, 1/8, 1/6, 1/5, 1/4, 1/3, 1/2, 2/3, 1, 3/2, 2, 3, 4, 5, 6, 8, 12, 16, 24, 32]` (24 values, ascending; write each fraction as `1.0 / 32.0` etc. so the doubles are the exact quotients).
  - `static let tolerance: Double = 0.001` (relative).
  - `static func clamp(_ zoom: Double) -> Double` — clamps to `[minimum, maximum]`; a non-finite or ≤ 0 input returns `1.0`.
  - `static func nextLarger(than zoom: Double) -> Double?` — the first stop `s` with `s > zoom * (1 + tolerance)`; `nil` if none (at or within tolerance of 3200%).
  - `static func nextSmaller(than zoom: Double) -> Double?` — the last stop `s` with `s < zoom / (1 + tolerance)`; `nil` if none (at or within tolerance of 1%).
  - `static func canZoomIn(from zoom: Double) -> Bool` / `canZoomOut(from:)` — `nextLarger/nextSmaller != nil`. Used for menu validation.
  - `static func fitZoom(contentSize: CGSize, viewportSize: CGSize, allowsEnlargement: Bool) -> Double` — `min(viewportW / contentW, viewportH / contentH)`, then `min(result, 1.0)` when `allowsEnlargement == false`, then `clamp`. If any dimension of either size is ≤ 0 or non-finite it returns `1.0`. No margin. Both sizes are in the zoom's unit (image pixels vs. viewport device pixels; see Context). Zoom to Window uses `allowsEnlargement: false`; 0014's Zoom to Selection and 0006's Zoom tool rectangle will use `true`.
  - `static func zoom(_ zoom: Double, magnifiedBy magnification: Double) -> Double` — pinch: `clamp(zoom * (1 + magnification))`; if `1 + magnification ≤ 0` or the magnification is non-finite, returns `zoom` unchanged.
  - `static func zoom(_ zoom: Double, scrolledBy deltaY: Double, isPrecise: Bool) -> Double` — ⌘+scroll. Precise (trackpad): `clamp(zoom * pow(2, deltaY / 100))` (100 points of vertical scroll double the zoom). Non-precise (mouse wheel, one call per wheel event): `deltaY > 0` → `nextLarger(than:) ?? zoom`, `deltaY < 0` → `nextSmaller(than:) ?? zoom`, `0` → `zoom`.
  - `static func percentString(_ zoom: Double) -> String` — `"\(Int((zoom * 100).rounded(.toNearestOrAwayFromZero)))%"`, e.g. `1/8` → `"13%"`, `2/3` → `"67%"`, `1/32` → `"3%"`, `32` → `"3200%"`.
- **`Core/Rendering/CanvasTransform+Navigation.swift`** — an extension of 0003's `CanvasTransform` (not a new transform type). All functions return a new value and use the transform's own `viewSize` (points), `imageSize`, and `backingScale` (`s`); "scrolling" means changing `center`:
  - `func clampedScroll() -> CanvasTransform` — per axis, independently, with the visible canvas half-extent `h = viewExtent·s / (2·zoom)`: if the zoomed image extent `imageExtent·zoom` is ≤ the view extent in device pixels `viewExtent·s`, `center` on that axis is `imageExtent / 2` (centered, no panning possible); otherwise `center` is clamped to `[h, imageExtent − h]`, so the image edge never comes inside the view edge. A zero or non-finite view size returns `self` unchanged.
  - `func zoomed(to newZoom: Double, anchoredAt viewPoint: CGPoint) -> CanvasTransform` — `c = viewToCanvas(viewPoint)` and `d = viewToDevice(viewPoint)` before the change; `z' = ZoomLevels.clamp(newZoom)`; new `center = (c.x − (d.x − dw/2) / z', c.y − (d.y − dh/2) / z')` with `(dw, dh)` = `drawableSize`; then `clampedScroll()`. The anchor stays under the pointer up to 0003's origin rounding (≤ ½ device pixel) unless the clamp moves it.
  - `func panned(byView delta: CGVector) -> CanvasTransform` — moves the image content by `delta` view points (content follows the delta: `canvasToView(p)` moves by `+delta` for every canvas point `p`, so `+dy` moves content up): `center.x −= delta.dx·s / zoom`, `center.y += delta.dy·s / zoom`, then `clampedScroll()`.
  - `func fittedToWindow() -> CanvasTransform` — zoom `ZoomLevels.fitZoom(contentSize: imageSize, viewportSize: viewSize × s, allowsEnlargement: false)`, `center = (imageWidth / 2, imageHeight / 2)`, then `clampedScroll()`. This equals 0003's `CanvasTransform.initial` (`min(1, fit)`, CAN-6).
  - `func resized(to newViewSize: CGSize) -> CanvasTransform` — sets `viewSize`, keeps `zoom` and `center` (the canvas point at the old view center is at the new view center), then `clampedScroll()`. Used on window resize. A zero new size returns `self` with only `viewSize` updated.
  - `center` is not rounded here; device-pixel alignment of the drawn image is 0003's rounded `imageOriginInDevice` (CAN-6).
- **`Core/Rendering/SpacePanState.swift`** — `struct SpacePanState` (Equatable), the temporary-pan state machine. 0006's `CanvasInputRouter` reuses it unchanged.
  - `enum Phase { case idle, armed, panning, panningSpaceReleased }`; `private(set) var phase: Phase = .idle`.
  - `mutating func spaceDown(isRepeat: Bool)`: `idle → armed`; repeats are ignored; other phases unchanged.
  - `mutating func spaceUp()`: `armed → idle`, `panning → panningSpaceReleased`, else unchanged.
  - `mutating func mouseDown() -> Bool`: `armed → panning`, returns `true` (this drag pans); else returns `false` and the phase is unchanged (in 0004 a plain drag does nothing; from 0006 it goes to the active tool).
  - `mutating func mouseUp()`: `panning → armed` (Space still held), `panningSpaceReleased → idle`.
  - `mutating func reset()`: → `idle` (window resigns key, app deactivates, document closes).
  - `var isPanning: Bool` (`panning` or `panningSpaceReleased`).
  - `var cursor: PanCursor` with `enum PanCursor { case none, openHand, closedHand }`: `armed → .openHand`, `panning`/`panningSpaceReleased → .closedHand`, `idle → .none` (the canvas shows its normal cursor).
  - Paint.NET-consistent rule: releasing Space mid-drag doesn't end the drag; the pan ends on mouse up.
- **`Core/Rendering/ScrollPanDelta.swift`** — `enum ScrollPanDelta { static func viewDelta(scrollingDeltaX: Double, scrollingDeltaY: Double, isPrecise: Bool) -> CGVector }`: precise deltas are points and pass through; non-precise deltas are lines and are multiplied by `linePoints = 10`. Non-finite components become 0. AppKit has already applied the user's natural-scrolling setting to `scrollingDelta*`; positive `scrollingDeltaY` must move the content **down** (revealing the part of the image above) and positive `scrollingDeltaX` moves it right. Because view space is bottom-left (y up), the result is `(scrollingDeltaX · k, −scrollingDeltaY · k)` with `k = 1` (precise) or `linePoints` (non-precise).
- **`Core/Model/MeasurementUnit.swift`** — `enum MeasurementUnit: String, CaseIterable, Sendable { case pixels = "px", inches = "in", centimeters = "cm" }`:
  - `var displayName: String` — `"Pixels"`, `"Inches"`, `"Centimeters"` (Paint.NET spelling).
  - `static func sanitizedDPI(_ dpi: Double) -> Double` — returns `dpi` if finite and > 0, else `96`.
  - `func value(fromPixels pixels: Double, dpi: Double) -> Double` — px: unchanged; in: `pixels / dpi`; cm: `pixels / dpi * 2.54` (dpi sanitized).
  - `func format(pixels: Int, dpi: Double) -> String` — px: the integer (`"-3"`, `"800"`); in/cm: the value rounded to 2 decimals half away from zero (`(v * 100).rounded(.toNearestOrAwayFromZero) / 100`), printed with exactly two decimals, with `"."` as the decimal separator regardless of locale (the app is English-only, PRD §2.2, and `,` separates the cursor coordinates). Negative zero prints as `"0.00"`.
  - `func formatPoint(_ p: PixelPoint, dpi: Double) -> String` → `"<x>, <y>"`; `func formatSize(_ s: PixelSize, dpi: Double) -> String` → `"<w> × <h>"` (U+00D7, spaces around it).
  - A document has one DPI (0002's `LayeredImage.dpi: Double`), used for both axes.
- **`Core/Settings/AppSettings.swift`** — minimal typed settings (0046 completes it; later specs add properties):
  - `struct AppSettings: @unchecked Sendable` wrapping an injected `UserDefaults` (`init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default)`). (`UserDefaults` is Foundation, allowed in Core.)
  - `enum Key { static let measurementUnit = "settings.measurementUnit" }`.
  - `var measurementUnit: MeasurementUnit { get nonmutating set }` — reads the raw value; missing or unknown → `.pixels` (Paint.NET's default). The setter writes the raw value and posts `Notification.Name.appSettingsDidChange` (declared in this file) on its `notificationCenter` with `userInfo["key"] = Key.measurementUnit`.
  - The unit is app-wide (as in Paint.NET): changing it in one window's status bar updates every open window. Per APP-5, the persisted value is also the default for new windows; 0046's Settings window will edit the same key.
- **`PaintDotMac/App/LaunchOptions.swift`** (0001) — append `"settings."` to `resettableKeyPrefixes`, giving `["tool.", "panel.", "NSWindow Frame panel.", "settings."]` (PRD §4 Testing, D-37; 0007 appends `"colors."`). UI tests now start with the unit at Pixels.

### Platform glue (AppKit/SwiftUI; covered by UI tests and manual checks)

- **`PaintDotMac/Canvas/CanvasNavigation.swift`** — `@MainActor final class CanvasNavigation`, one per document window, owned by `DocumentWindowController`, holding a weak reference to the `CanvasView` and the document's `LayeredImage` size. It is the only code that changes the canvas transform in this spec:
  - Commands: `zoomIn()`, `zoomOut()` (anchored at the view center, `ZoomLevels.nextLarger/nextSmaller`; no-op when `nil`), `actualSize()` (zoom 1.0 anchored at the view center), `zoomToWindow()` (`fittedToWindow`), `setZoom(_:anchoredAtView:)` (for 0006/0014), and `canZoomIn` / `canZoomOut`.
  - Events forwarded by `CanvasView` overrides: `magnify(with:)` → `ZoomLevels.zoom(_:magnifiedBy: event.magnification)` anchored at the event's location in view space (`zoomed(to:anchoredAt:)`); `scrollWheel(with:)` → if `event.modifierFlags` contains `.command`, ⌘+scroll zoom (`ZoomLevels.zoom(_:scrolledBy: event.scrollingDeltaY, isPrecise: event.hasPreciseScrollingDeltas)`) anchored at the pointer, otherwise pan by `ScrollPanDelta.viewDelta(…)`; `keyDown`/`keyUp` for Space (keyCode 49, no modifiers other than Shift/Caps Lock) → `SpacePanState.spaceDown(isRepeat: event.isARepeat)` / `spaceUp()` (Space is consumed only while the canvas is first responder; other keys go up the responder chain); `mouseDown`/`mouseDragged`/`mouseUp` → when `SpacePanState.mouseDown()` returns `true`, each drag pans by the pointer's view-space delta since the previous event (`panned(byView:)`, so the content follows the pointer).
  - Cursor: applies `SpacePanState.cursor` (`NSCursor.openHand` / `.closedHand`, otherwise the canvas's normal arrow) on every state change and in `cursorUpdate`.
  - `reset()` on `NSWindow.didResignKeyNotification` and when the document closes.
  - Window resize: `CanvasView`'s `setFrameSize` (live updates included) calls `resized(to:)`.
  - Initial view: when a document window first lays out the canvas, apply `zoomToWindow()` (so images larger than the window open fitted and smaller ones at 100%, centered — Paint.NET's behavior and CAN-6's min(100%, fit)); the result equals 0003's `CanvasTransform.initial`.
  - After every transform change: assign it to `CanvasView` (0003's API), request a redraw, and push the zoom to the window's `StatusBarModel`.
  - Pointer tracking: an `NSTrackingArea` on `CanvasView` with `.mouseMoved`, `.mouseEnteredAndExited`, `.cursorUpdate`, `.activeInKeyWindow`, `.inVisibleRect`. `mouseMoved` and `mouseDragged` set `StatusBarModel.cursorPixel` to `PixelPoint(x: floor(canvas.x), y: floor(canvas.y))` (through `CanvasTransform.viewToCanvas`; outside the image the values are simply negative or ≥ the size, as in Paint.NET); `mouseExited` sets it to `nil`.
  - `CanvasView` must accept first responder and become the window's initial first responder, so Space and keyboard events reach it.
  - 0006 will put `CanvasInputRouter` between `CanvasView` and the tools; it must keep calling `CanvasNavigation` first for magnify, scroll, and Space-pan, and its `PanTool` reuses `CanvasNavigation.beginPan(atView:)` / `continuePan(toView:)` / `endPan()` — expose these three methods now (the Space-pan path uses them internally).
- **`PaintDotMac/App/MainMenu.swift`** — at the top of 0001's existing **View** menu (`menu.view`), followed by a separator and 0001's Enter Full Screen item, add in Paint.NET order:
  - "Zoom In" — key equivalent `=` with ⌘, action `zoomIn(_:)`; plus a hidden alternate item with `+` (⇧⌘=, so ⌘+ also works) with `isHidden = true`, `allowsKeyEquivalentWhenHidden = true`, same action.
  - "Zoom Out" — `-` with ⌘, action `zoomOut(_:)`.
  - "Zoom to Window" — `b` with ⌘, action `zoomToWindow(_:)`.
  - (0014 inserts "Zoom to Selection" ⇧⌘B here.)
  - "Actual Size" — `0` with ⌘, action `actualSize(_:)`.
  - Targets are `nil` (first responder); give each item a stable `identifier` (`NSUserInterfaceItemIdentifier("menu.view.zoomIn")`, `…zoomOut`, `…zoomToWindow`, `…actualSize`) so 0045 can audit them.
  - 0001's menu has no ⌘B/⌘0/⌘=/⌘− item, so there is no conflict. Update 0001's `MainMenuTests.viewMenuItems` to expect Zoom In, (hidden Zoom In alternate), Zoom Out, Zoom to Window, Actual Size, separator, Enter Full Screen.
- **`PaintDotMac/Document/DocumentWindowController.swift`** — implements `@objc zoomIn(_:)`, `zoomOut(_:)`, `zoomToWindow(_:)`, `actualSize(_:)` forwarding to its `CanvasNavigation`, and `validateMenuItem(_:)` (via `NSMenuItemValidation`): Zoom In enabled iff `canZoomIn`, Zoom Out iff `canZoomOut`, the other two always enabled. With no document window, the actions find no target and AppKit disables the items. Its content view becomes a vertical stack: `CanvasView` (fills) above the status bar (`NSHostingView(rootView: StatusBarView(model:))`, fixed height 22 pt, full width). 0006 adds the tool options bar above the canvas.
- **`PaintDotMac/UI/StatusBarModel.swift`** — `@MainActor @Observable final class StatusBarModel`, one per document window:
  - Inputs: `cursorPixel: PixelPoint?`, `selectionSize: PixelSize?` (always `nil` in 0004; 0014 sets it), `imageSize: PixelSize`, `dpi` (from `LayeredImage.dpi`), `zoom: Double`, `unit: MeasurementUnit` (initialized from `AppSettings().measurementUnit`; observes `.appSettingsDidChange` and re-reads).
  - Outputs (computed, the exact strings shown): `cursorText` (`unit.formatPoint` or `""` when `nil`), `selectionSizeText` (`unit.formatSize` or `""` when `nil`), `imageSizeText`, `zoomText` (`ZoomLevels.percentString`).
  - `func selectUnit(_ unit: MeasurementUnit)` writes `AppSettings.measurementUnit` (which notifies every window).
  - Initialize with an injected `AppSettings` and the same `NotificationCenter` the settings post to, so tests can use a private suite and center.
  - Update `imageSize`/`dpi` when the document's image changes size (nothing in 0004 changes it; 0022/0035/0036 will).
- **`PaintDotMac/UI/StatusBarView.swift`** — SwiftUI `HStack`, `.font(.system(size: 11)).monospacedDigit()`, small SF Symbols before each field: cursor (`cursorarrow`), selection size (`selection.pin.in.out`), image size (`photo`), then a `Spacer`, the units popup, and the zoom text. Exact accessibility:
  - `statusBar.cursor`, `statusBar.selectionSize`, `statusBar.imageSize`, `statusBar.zoom`: each a `Text(model.<field>Text)` with `.accessibilityIdentifier(...)`, `.accessibilityLabel("Cursor Position" / "Selection Size" / "Image Size" / "Zoom")`, and `.accessibilityValue(<the same string>)`. UI tests read `.value`. The selection-size element exists even when its text is empty.
  - `statusBar.units`: `Picker("Units", selection:)` with `.pickerStyle(.menu)`, items titled by `displayName` in the order Pixels, Inches, Centimeters; its binding calls `model.selectUnit`.
  - Follows light/dark appearance automatically (system colors only).
- **Tests support:** UI fixtures with a given size and DPI come from 0002's `UITestFixtures.writePNG(width:height:pixel:properties:)` (`kCGImagePropertyDPIWidth`/`DPIHeight` in `properties`), generated into the temp dir at test time.
- **project.yml:** no target changes; new files sit under existing source globs. Run `xcodegen generate` after adding files.
- **AGENTS.md / PRD.md:** no changes. (The zoom stops and the status-bar formats are recorded in this spec; 0045 copies the shortcuts into `docs/shortcuts.md`.)

## Acceptance criteria

- [ ] Zoom ranges over exactly 1%–3200%; every input path clamps to that range. → `ZoomLevelsTests.clampBounds`, `ZoomLevelsTests.pinchClamps`, `ZoomLevelsTests.preciseScrollZoomClamps`
- [ ] Zoom In / Zoom Out step through the 24 stops (1% as the lowest step per D-29, plus Paint.NET 4's presets) from any current zoom, including non-preset zooms. → `ZoomLevelsTests.stopsAreExact`, `nextLargerFromPresetsAndBetween`, `nextSmallerFromPresetsAndBetween`, `steppingVisitsEveryStop`; UI `ZoomPanStatusBarUITests.testZoomShortcutsStepPresets`
- [ ] View menu shows Zoom In (⌘=), Zoom Out (⌘−), Zoom to Window (⌘B), Actual Size (⌘0) in that order; ⌘+ also zooms in. → UI `testViewMenuItemsAndShortcuts`
- [ ] Zoom In is disabled at 3200% and Zoom Out at 1%. → `ZoomLevelsTests.canZoomAtLimits`; UI `testZoomInDisabledAtMaximum`
- [ ] Actual Size sets 100%; Zoom to Window fits an image larger than the window and shows smaller images at 100%, centered. A new window opens in the Zoom to Window state. → `ZoomLevelsTests.fitZoom*`, `CanvasTransformNavigationTests.fittedToWindowCentersImage`; UI `testOpensFittedAndActualSize`, `testSmallImageOpensAtActualSize`
- [ ] Zoom keyboard commands keep the view center fixed; pinch and ⌘+scroll keep the canvas point under the pointer fixed (unless clamping must move it). → `CanvasTransformNavigationTests.zoomKeepsAnchor`, `zoomKeepsAnchorRandomized`; UI `testCommandScrollZooms`; manual pinch
- [ ] Two-finger scroll / mouse wheel pans; panning can't move the image edge inside the view when the image is larger, and a smaller-than-view axis stays centered. → `CanvasTransformNavigationTests.panMovesContent`, `panClampsAtEdges`, `smallAxisStaysCentered`, `ScrollPanDeltaTests.*`; UI `testScrollPans`
- [ ] Holding Space turns a drag into a pan with open/closed hand cursors; releasing Space mid-drag finishes the drag first; autorepeat is ignored; losing key focus resets it. → `SpacePanStateTests.*`; manual (XCUITest can't hold Space during a drag)
- [ ] Status bar shows cursor position (image pixel under the pointer, (0,0) top-left, negative outside), selection size (empty), image size "W × H", zoom "N%", and a units popup. → `StatusBarModelTests.*`, `MeasurementUnitTests.*`; UI `testStatusBarFields`, `testCursorPosition`
- [ ] Inches and centimeters use the document's DPI (file metadata or 96). → `MeasurementUnitTests.*`; UI `testUnitsUseDocumentDPI`
- [ ] The chosen unit persists across relaunch and applies to all open windows. → `AppSettingsTests.*`, `StatusBarModelTests.unitChangePropagates`; UI `testUnitPersistsAcrossRelaunch`, `testTwoWindowsShareUnit`
- [ ] `-UITestResetDefaults` also clears `settings.*` keys. → `LaunchOptionsTests.settingsKeysAreResettable`, `LaunchOptionsTests.resetDefaultsRemovesSettingsKeys`; UI `testResetDefaultsRestoresPixels`
- [ ] There are no scroll bars (CAN-6, D-29). → `ZoomPanStatusBarUITests.testNoScrollBars`
- [ ] Window resize keeps the zoom and the view-center point, and re-clamps. → `CanvasTransformNavigationTests.resizeKeepsCenter`, `resizeReclamps`; manual (live-resize feel)
- [ ] Core gains no AppKit/SwiftUI imports. → quality-gate import check.
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report. → quality-gate launch smoke.

## Edge cases

- **1×1 image:** opens at 100%, centered; Zoom In works up to 3200% (a 32×32-device-pixel square), still centered. Cursor shows `0, 0` only over that pixel. → `CanvasTransformNavigationTests.tinyImage`
- **65,535 × 65,535 (or 65,535 × 1) image:** `fitZoom` result below 1% clamps to 1%; the image then overflows the view and panning works. → `ZoomLevelsTests.fitZoomHugeClampsToMinimum`, `fitZoomVeryWide`
- **Zero or non-finite sizes** (window minimized, during layout, viewport 0×0): `fitZoom` returns 1.0, `clampedScroll()` with a zero view size returns the transform unchanged and `resized(to: .zero)` changes only `viewSize`; no NaN reaches the transform. → `CanvasTransformNavigationTests.zeroViewSizeIsNoOp`, `ZoomLevelsTests.fitZoomDegenerateInputs`
- **Non-finite or extreme gesture input** (`magnification` ≤ −1, NaN, huge scroll deltas): zoom unchanged or clamped; never NaN. → `ZoomLevelsTests.pinchRejectsInvalid`, `ScrollPanDeltaTests.nonFiniteBecomesZero`
- **Zoom at limits:** ⌘= at 3200% and ⌘− at 1% are disabled (and the actions are no-ops if invoked anyway). Mouse-wheel ⌘+scroll at a limit leaves the zoom unchanged.
- **Values within tolerance of a stop** (e.g. 1.4995 after a pinch) step to the next stop, not to the same one. → `nextLargerFromPresetsAndBetween`
- **Cursor outside the image** shows negative or ≥ size values; outside the canvas view (pointer exited) the field is empty. Fractional canvas coordinates floor (−0.5 → −1). → `StatusBarModelTests.cursorFloorsAndNegative`
- **Invalid DPI** (0, negative, NaN from a malformed file): treated as 96. → `MeasurementUnitTests.invalidDPIFallsBackTo96`
- **Unknown stored unit** (`settings.measurementUnit = "furlong"`): reads as Pixels. → `AppSettingsTests.unknownValueReadsAsPixels`
- **Several windows / tabs:** each has its own zoom, scroll, and cursor; the unit is shared. → `StatusBarModelTests.unitChangePropagates`; manual tabs check
- **Space pressed while another app/window is key, or released after the window lost focus:** `reset()` returns to idle, so the canvas never gets stuck in pan mode. → `SpacePanStateTests.resetFromAnyPhase`
- **Space with ⌘/⌥/⌃ held:** not treated as temporary pan (lets system shortcuts through). → manual (step 3).
- **No document open:** View menu zoom items are disabled. → UI `testZoomItemsDisabledWithoutDocument`.
- **Rounding ties in unit formatting** (e.g. 15.875 cm) round half away from zero → `"15.88"`. → `MeasurementUnitTests.roundsHalfAwayFromZero`

## Test plan

Expected values are computed by hand from the rules above.

- **Unit tests** — `PaintDotMacTests/Rendering/ZoomLevelsTests.swift` (Swift Testing):
  - `stopsAreExact`: `stops.count == 24`, strictly ascending, `stops.first == 0.01`, `stops.last == 32`, contains `1.0`, and equals the literal list in the spec (element-wise `==`).
  - `clampBounds`: `clamp(0.001) == 0.01`, `clamp(100) == 32`, `clamp(0.5) == 0.5`, `clamp(.nan) == 1`, `clamp(.infinity) == 1`, `clamp(-2) == 1`, `clamp(0) == 1`.
  - `nextLargerFromPresetsAndBetween`: `1.0 → 1.5`, `1.2 → 1.5`, `1.4995 → 2.0` (within tolerance of 1.5), `0.2 → 0.25`, `0.01 → 1/32`, `0.02 → 1/32`, `24 → 32`, `31.9 → 32`, `32 → nil`, `31.99 → nil` (within tolerance of 32).
  - `nextSmallerFromPresetsAndBetween`: `1.0 → 2/3`, `0.7 → 2/3`, `0.6667 → 0.5`, `1/32 → 0.01`, `0.02 → 0.01`, `0.035 → 1/32`, `0.0101 → 0.01`, `0.010005 → nil` (within tolerance of 1%), `0.01 → nil`, `32 → 24`, `2.5 → 2`.
  - `steppingVisitsEveryStop`: starting at `0.01`, repeatedly applying `nextLarger` yields `stops.dropFirst()` in order and then `nil`; starting at `32`, `nextSmaller` yields `stops.reversed().dropFirst()` then `nil`.
  - `canZoomAtLimits`: `canZoomIn(from: 32) == false`, `canZoomIn(from: 1) == true`, `canZoomOut(from: 0.01) == false`, `canZoomOut(from: 1/32) == true`.
  - `fitZoomShrinks`: content 4000×3000, viewport 800×600, no enlargement → `0.2`; content 4000×1000, viewport 800×600 → `0.2`; content 1000×4000, viewport 800×600 → `0.15`.
  - `fitZoomNeverEnlargesForWindow`: content 400×300 in 800×600 → `1.0`; with `allowsEnlargement: true` → `2.0`; content 1×1 in 800×600 with enlargement → `32` (clamped).
  - `fitZoomHugeClampsToMinimum`: 65535×65535 in 500×500 → `0.01`. `fitZoomVeryWide`: 65535×1 in 800×600 → `800/65535` (±1e-12).
  - `fitZoomDegenerateInputs`: viewport 0×600, content 0×10, NaN width → `1.0` each.
  - `pinchScales`: `zoom(1, magnifiedBy: 0.5) == 1.5`, `zoom(2, magnifiedBy: -0.25) == 1.5`. `pinchClamps`: `zoom(30, magnifiedBy: 1) == 32`, `zoom(0.011, magnifiedBy: -0.5) == 0.01`. `pinchRejectsInvalid`: `magnifiedBy: -1`, `-3`, `.nan` → zoom unchanged.
  - `preciseScrollZoom`: `zoom(1, scrolledBy: 100, isPrecise: true) == 2`, `scrolledBy: -100` → `0.5`, `scrolledBy: 0` → `1`. `preciseScrollZoomClamps`: `zoom(16, scrolledBy: 500, isPrecise: true) == 32`.
  - `wheelScrollZoomSteps`: `zoom(1, scrolledBy: 3, isPrecise: false) == 1.5` (one stop per event, regardless of magnitude), `scrolledBy: -1` → `2/3`, at `32` with `+1` → `32`, at `0.01` with `-1` → `0.01`.
  - `percentStrings`: `1 → "100%"`, `0.5 → "50%"`, `2/3 → "67%"`, `1/3 → "33%"`, `1/8 → "13%"`, `1/6 → "17%"`, `1/32 → "3%"`, `0.01 → "1%"`, `1.5 → "150%"`, `32 → "3200%"`, `0.2 → "20%"`.
- `PaintDotMacTests/Rendering/CanvasTransformNavigationTests.swift` — build transforms through 0003's `init(imageSize:viewSize:backingScale:zoom:center:)` with backing scale 1 unless stated; view space is bottom-left (y up), view height `H`; assertions use `viewToCanvas`/`canvasToView` with ±1e-9 tolerance (every case has an integer device origin, so 0003's rounding doesn't move it):
  - `zoomKeepsAnchor`: image 4000×3000, view 800×600, zoom 0.5, center (1000, 1000) (so canvas (1000, 1000) is at view (400, 300)); `zoomed(to: 1.0, anchoredAt: (400, 300))` → `zoom == 1.0`, `center == (1000, 1000)`, `viewToCanvas((400, 300)) == (1000, 1000)`. Second case from the same start: anchor view (100, 50) maps to canvas (400, 1500) (device (100, 550), origin (−100, −200)); `zoomed(to: 2.0, anchoredAt: (100, 50))` → `center == (550, 1375)` and `viewToCanvas((100, 50)) == (400, 1500)`.
  - `zoomKeepsAnchorRandomized`: 500 seeded cases (`SeededRandom`, seed printed on failure): image sizes 2000–20000 px, view 400–1600 pt, backing scale 1 or 2, start and end zoom chosen so the zoomed image is larger than the view on both axes at both zooms, anchor anywhere in the view, start center valid, and the anchor's canvas point in the middle 50% of the image (so no clamp moves it) → `canvasToView(anchorCanvasBefore)` is within `0.5 / backingScale + 1e-9` points of the anchor on each axis (0003's origin rounding is at most half a device pixel), and every view corner maps inside `[0, image size]`.
  - `fittedToWindowCentersImage`: 4000×3000 in view 800×600 (scale 1) → zoom 0.2, origin (0, 0), `canvasToView((2000, 1500)) == (400, 300)`, `canvasToView((0, 0)) == (0, 600)` (the image's top-left is the view's top-left corner), `canvasToView((4000, 3000)) == (800, 0)`. With backing scale 2 → zoom 0.4 (drawable 1600×1200) and the same three view-space results. 400×300 in 800×600 (scale 1) → zoom 1, origin (200, 150), `canvasToView((0, 0)) == (200, 450)`, `canvasToView((400, 300)) == (600, 150)`. The zoom equals `CanvasTransform.initial(...)`'s for all three cases.
  - `smallAxisStaysCentered`: 4000×100 at zoom 1 in 800×600, center (2000, 50) → `canvasToView((0, 50)).y == 300`; after `panned(byView: (-100, 200))` → `center.y == 50`, `canvasToView((0, 50)).y == 300` (y can't pan), and `canvasToView((2000, 50)).x == 300` (x panned left by 100).
  - `panMovesContent`: 4000×3000 at zoom 1 in 800×600, center (1000, 1000) (canvas (1000, 1000) at view (400, 300)); `panned(byView: (50, -30))` → `center == (950, 970)` and `canvasToView((1000, 1000)) == (450, 270)` (content moved right 50 and down 30).
  - `panClampsAtEdges`: 4000×3000 at zoom 1 in 800×600. Top-left limit: center (400, 300), so `viewToCanvas((0, 600)) == (0, 0)`; `panned(byView: (100, -100))` (content right and down, which would reveal space above and left of the image) → center stays (400, 300) and `viewToCanvas((0, 600)) == (0, 0)`. Bottom-right limit: center (3600, 2700), so `viewToCanvas((800, 0)) == (4000, 3000)`; `panned(byView: (-100, 100))` → center stays (3600, 2700).
  - `tinyImage`: 1×1 at zoom 32 in 800×600 → center (0.5, 0.5), origin (384, 284), `canvasToView((0.5, 0.5)) == (400, 300)`; `panned(byView: (37, 11))` changes nothing.
  - `resizeKeepsCenter`: 4000×3000 at zoom 1, center (2000, 1500), view 800×600; `resized(to: 1000×500)` → `viewSize == 1000×500`, zoom 1, `viewToCanvas((500, 250)) == (2000, 1500)`.
  - `resizeReclamps`: 4000×3000 at zoom 1, center (3600, 2700) (bottom-right limit) in 800×600; `resized(to: 1000×800)` → `center == (3500, 2600)` and `viewToCanvas((1000, 0)) == (4000, 3000)`.
  - `zeroViewSizeIsNoOp`: with `viewSize == .zero`, `clampedScroll()` returns the input unchanged and `fittedToWindow()` returns zoom 1.0 (`fitZoom` degenerate rule) with finite conversions; `resized(to: .zero)` from 800×600 changes only `viewSize`; no component of any result is NaN.
- `PaintDotMacTests/Rendering/SpacePanStateTests.swift`:
  - `basicPan`: idle → `spaceDown(false)` armed (cursor openHand) → `mouseDown() == true` panning (closedHand) → `mouseUp()` armed → `spaceUp()` idle (cursor none).
  - `releaseSpaceMidDrag`: armed → mouseDown → `spaceUp()` → `.panningSpaceReleased`, `isPanning == true`, cursor closedHand → `mouseUp()` → idle.
  - `mouseDownWithoutSpace`: idle `mouseDown() == false`, phase idle.
  - `autorepeatIgnored`: `spaceDown(isRepeat: true)` from idle stays idle; from armed stays armed.
  - `spaceDuringPanIgnored`: in `.panning`, `spaceDown(false)` keeps `.panning`.
  - `resetFromAnyPhase`: each of the four phases → `reset()` → idle.
- `PaintDotMacTests/Rendering/ScrollPanDeltaTests.swift` (bottom-left view space, so y is negated): `precisePassesThrough`: `(3, -4)` → `(3, 4)`; `nonPreciseUsesLinePoints`: `(1, -2)` → `(10, 20)`; `positiveDeltaYMovesContentDown`: precise `(0, 5)` → `(0, -5)`; `nonFiniteBecomesZero`: `(.nan, .infinity)` → `(0, 0)`.
- `PaintDotMacTests/App/LaunchOptionsTests.swift` (0001's file, extended): `settingsKeysAreResettable`: `resettableKeyPrefixes == ["tool.", "panel.", "NSWindow Frame panel.", "settings."]`; `shouldReset(key: "settings.measurementUnit") == true`, `shouldReset(key: "Settings.measurementUnit") == false`, `shouldReset(key: "settingsX") == false`. `resetDefaultsRemovesSettingsKeys`: in a private suite, set `settings.measurementUnit = "cm"` and `other = 1`; after `resetDefaults(in:domainName:)` the first is nil and `other == 1`.
- `PaintDotMacTests/Model/MeasurementUnitTests.swift`:
  - `rawValuesAndNames`: raw values `px`/`in`/`cm`; display names Pixels/Inches/Centimeters; `allCases` order pixels, inches, centimeters.
  - `pixelsFormat`: `format(pixels: 800, dpi: 96) == "800"`, `-3 → "-3"`, `0 → "0"`.
  - `inchesFormat`: `800 @96 → "8.33"`, `600 @96 → "6.25"`, `600 @300 → "2.00"`, `-1 @96 → "-0.01"`, `0 → "0.00"`.
  - `centimetersFormat`: `800 @96 → "21.17"`, `2000 @96 → "52.92"`, `300 @300 → "2.54"`.
  - `roundsHalfAwayFromZero`: `600 @96` in cm (15.875) → `"15.88"`; `-12 @96` in inches (−0.125) → `"-0.13"`.
  - `negativeZeroPrintsZero`: a value that rounds to −0 (e.g. `-0 px` in inches, or a cm value of −0.001) → `"0.00"`.
  - `formatPointAndSize`: `formatPoint((12, -5), dpi: 96)` in px → `"12, -5"`; `formatSize((800, 600), dpi: 96)` in px → `"800 × 600"`, in inches → `"8.33 × 6.25"`.
  - `invalidDPIFallsBackTo96`: `sanitizedDPI(0) == 96`, `(-72) == 96`, `(.nan) == 96`, `(300) == 300`; `inches.format(pixels: 96, dpi: 0) == "1.00"`.
  - `decimalSeparatorIsLocaleIndependent`: formatting while the process's current locale differs is still `"8.33"` (assert the implementation doesn't take a `Locale`; e.g. format with `String(format:locale: nil)` or manual digits — test by checking no `","` appears in `"8.33"`/`"21.17"` outputs).
- `PaintDotMacTests/Settings/AppSettingsTests.swift` (each test uses `UserDefaults(suiteName: "AppSettingsTests.\(UUID())")` and removes the suite afterwards):
  - `defaultIsPixels`, `roundTrip` (set `.centimeters`, a second `AppSettings` on the same defaults reads `.centimeters`; stored string is `"cm"`), `unknownValueReadsAsPixels` (`"furlong"` → `.pixels`), `setterPostsNotification` (an observer on a private `NotificationCenter` passed to `AppSettings` receives `.appSettingsDidChange` with `userInfo["key"] == "settings.measurementUnit"` exactly once).
- `PaintDotMacTests/UI/StatusBarModelTests.swift` (`@MainActor`, injected settings suite and a private `NotificationCenter`):
  - `initialStrings`: image 800×600, dpi 96, zoom 0.5, cursor nil, unit px → `cursorText == ""`, `selectionSizeText == ""`, `imageSizeText == "800 × 600"`, `zoomText == "50%"`.
  - `cursorFloorsAndNegative`: the model's cursor-from-canvas helper (`setCursor(canvasPoint:)`) with (12.7, 3.2) → `"12, 3"`; (−0.5, −0.01) → `"-1, -1"`; (800, 600) → `"800, 600"`; `setCursor(canvasPoint: nil)` → `""`.
  - `unitChangesStrings`: `selectUnit(.inches)` → `imageSizeText == "8.33 × 6.25"`, cursor (96, 192) → `"1.00, 2.00"`; `.centimeters` → `"21.17 × 15.88"`.
  - `unitChangePropagates`: two models on the same settings suite and private center → `selectUnit(.inches)` on the first updates the second's `unit` to `.inches` (via the notification) and the persisted value is `"in"`.
  - `selectionSizeIsEmptyUntilSet`: `selectionSizeText == ""`; setting `selectionSize = PixelSize(10, 20)` → `"10 × 20"` (the hook 0014 uses).
  - `zoomUpdates`: setting `zoom = 1/8` → `"13%"`.
- **Round-trip / property tests:** `zoomKeepsAnchorRandomized` (above); `zoomInThenOutReturns`: for every stop `s` except the two ends, `nextSmaller(nextLarger(s)!) == s` and `nextLarger(nextSmaller(s)!) == s`; `panRoundTrip`: 200 seeded cases with an image larger than the view, `panned(+d)` then `panned(−d)` restores the transform when neither move hits a clamp.
- **Golden-image tests:** none (no new rendering; 0003 owns canvas pixels).
- **Integration tests:** none headless beyond the above; the navigation is O(1) transform math, and the window glue is covered by the UI tests.
- **UI tests** — `PaintDotMacUITests/ZoomPanStatusBarUITests.swift` (use `UITestApp`; fixtures generated at test time with `UITestFixtures.writePNG`; every launch uses `-UITestResetDefaults YES` unless stated, which now clears `settings.*`, so each test starts at Pixels):
  - `testStatusBarFields`: open a 4000×2000 96-DPI PNG → `statusBar.imageSize` value `"4000 × 2000"`, `statusBar.selectionSize` exists with value `""`, `statusBar.zoom` value ends with `"%"`, `statusBar.units` value `"Pixels"`.
  - `testOpensFittedAndActualSize`: same fixture → initial zoom value `Z0` is < `"100%"` (parse the integer, < 100). ⌘0 → `"100%"`. ⌘B → back to `Z0`.
  - `testSmallImageOpensAtActualSize`: a 64×64 PNG → zoom `"100%"`.
  - `testZoomShortcutsStepPresets`: 4000×2000, ⌘0, then ⌘= → `"150%"`, ⌘= → `"200%"`, ⌘− → `"150%"`, ⌘− → `"100%"`, ⌘− → `"67%"`, ⌘− → `"50%"`, ⌘− → `"33%"`; ⇧⌘= (⌘+) → `"50%"`.
  - `testViewMenuItemsAndShortcuts`: open the View menu → the visible items begin "Zoom In", "Zoom Out", "Zoom to Window", "Actual Size" in that order; from ⌘0 on the 4000×2000 fixture, clicking Zoom In gives `"150%"`, Zoom Out `"100%"`, Zoom to Window the initial fitted value, Actual Size `"100%"`. (Key equivalents and modifiers are asserted exactly in the unit test `MainMenuTests.viewMenuItems`: `=`/⌘, hidden `+`/⇧⌘ alternate, `-`/⌘, `b`/⌘, `0`/⌘.)
  - `testZoomInDisabledAtMaximum`: ⌘0, press ⌘= eleven times → `"3200%"`; View > Zoom In `isEnabled == false`, Zoom Out enabled. Then ⌘B and press ⌘− until Zoom Out is disabled (bounded loop of 30) → zoom value `"1%"`.
  - `testCommandScrollZooms`: ⌘0, then `canvas.perform(withKeyModifiers: .command) { canvas.scroll(byDeltaX: 0, deltaY: 50) }` → zoom value is no longer `"100%"`.
  - `testScrollPans`: ⌘0, hover the canvas center and read `statusBar.cursor` (x1, y1); `canvas.scroll(byDeltaX: 0, deltaY: 100)`; hover the same spot → y2 differs from y1 by ≥ 50 (direction is unit-tested; synthetic events may differ in natural-scrolling handling); zoom still `"100%"`.
  - `testCursorPosition`: ⌘0 on 4000×2000; hover the canvas center → `statusBar.cursor` parses to (x, y) within ±2 of (2000, 1000) (±2 covers 1×/2× displays). Move the pointer off the canvas (hover over the status bar) → cursor value `""`.
  - `testUnitsUseDocumentDPI`: 4000×2000 at 96 DPI: select Inches → image size `"41.67 × 20.83"`; Centimeters → `"105.83 × 52.92"`; Pixels → `"4000 × 2000"`. Then open a 600×300 PNG written with 300 DPI → Inches → `"2.00 × 1.00"`, Centimeters → `"5.08 × 2.54"`.
  - `testUnitPersistsAcrossRelaunch`: select Inches, terminate, relaunch with the same fixture and `launch(opening:resetDefaults: false)` → `statusBar.units` value `"Inches"` and image size `"41.67 × 20.83"`.
  - `testResetDefaultsRestoresPixels`: select Inches, terminate, relaunch with the default `resetDefaults: true` → `statusBar.units` value `"Pixels"` and image size `"4000 × 2000"`.
  - `testNoScrollBars`: open the 4000×2000 fixture at ⌘0 (larger than the window) → the document window contains no element of type `.scrollBar` (`documentWindows.firstMatch.scrollBars.count == 0`).
  - `testZoomItemsDisabledWithoutDocument`: launch with no fixture → View > Zoom In, Zoom Out, Zoom to Window, and Actual Size all have `isEnabled == false`.
  - `testTwoWindowsShareUnit`: launch with two fixtures (`-UITestOpen` twice, 0001's hook opens them in order); change units in one → the other window's `statusBar.units` shows the same value.
- **Performance:** CAN-2 interacts with NF-2 (pan/zoom ≥ 60 fps on a 10-layer 4K document). This spec only changes O(1) transform math; rendering cost is 0003's. No `measure` test here; 0048 measures NF-2. Manual smoothness check below.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build with zero warnings, all tests pass with none skipped, UI tests ran, launch smoke passes.
- **Manual verification** (can't be automated):
  1. Open a 4000×3000 photo on a trackpad Mac. Pinch out and in: zoom follows the fingers smoothly, the point under the fingers stays put, the zoom stops at 1% and 3200%, and the status bar zoom updates continuously.
  2. Two-finger scroll in all directions: the image follows the fingers (with natural scrolling on), stops at the image edges; a small image (64×64) can't be moved and stays centered.
  3. Hold Space: the cursor becomes an open hand; drag: a closed hand and the image follows the pointer; release Space while still dragging: the pan continues until mouse up, then the normal cursor returns. Hold Space, ⌘-Tab away, release, come back: the canvas isn't stuck in pan mode.
  4. With a mouse wheel (if available): wheel pans vertically, Shift+wheel horizontally, ⌘+wheel steps through presets around the pointer.
  5. Resize the window at 400%: the zoom stays, the image center stays in the middle.
  6. Two documents as window tabs: each keeps its own zoom/scroll; switching units in one changes both.
  7. Retina and non-Retina display (or scaled resolution): Actual Size shows one image pixel per device pixel (crisp, no blur); Zoom to Window fits exactly with no scroll.
  8. Dark mode: status bar text and popup are legible; VoiceOver reads "Cursor Position, 12, 34", "Image Size, 4000 × 3000", "Zoom, 100%", and the Units popup.
  9. Pan and zoom a 4000×3000 image: subjectively smooth (60 fps); note any stutter for 0048.

## Out of scope

- Zoom to Selection (⇧⌘B) and filling `statusBar.selectionSize` → 0014.
- The Zoom tool (Z: click, ⌥-click, drag rectangle) and the Pan tool (H) → 0006 (reusing `CanvasNavigation`, `SpacePanState`, and `ZoomLevels.fitZoom(…, allowsEnlargement: true)`).
- Routing mouse events to tools (`CanvasInputRouter`) → 0006.
- Paint.NET's editable zoom box, zoom slider, and quick-size toggle in the status bar; Paint.NET 5's finer zoom steps and 6400%.
- The Settings window and a "default units" control → 0046 (edits `settings.measurementUnit`).
- Pixel grid and rulers → 0053.
- Rendering quality at each zoom (nearest-neighbor, mipmaps, Retina mapping) → 0003.
- Changing a document's DPI (Resize Image dialog) → 0035; New Image DPI field → 0005.
- `docs/shortcuts.md` and the shortcut table → 0045.
