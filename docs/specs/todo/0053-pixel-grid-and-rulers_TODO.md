# 0053 — Add View > Pixel Grid and View > Rulers: a crisp contrast-adaptive pixel grid at ≥ 200 % and unit-aware rulers with cursor and selection markers

> Source: PRD.md §5.2 CAN-5 ("An optional pixel grid at high zoom, plus rulers", P1), CAN-6 (100 % = one image pixel per device pixel; D-29), §5.1 APP-5 (units px/in/cm from the per-document DPI, persisted unit; D-7), APP-7 (light/dark), §6 NF-1 (canvas frame rate), NF-7 (accessibility, Increase Contrast), §5.12 (Ctrl → ⌘, Alt → ⌥, Mac reserved shortcuts win), §8 (v1.x), §12 D-26, D-37.
> Paint.NET references: View menu — https://www.getpaint.net/doc/latest/ViewMenu.html (served from https://paint.net/doc/latest/ViewMenu.html): "The Pixel Grid overlays the current image with a grid where each cell is exactly one pixel in size … The same menu command can be used to toggle the grid off again … The Pixel Grid is not visible below 200% magnification." "Rulers: This menu command shows or hides rulers along the top and left edges of the image canvas. The rulers are always set to the current Units of Measurement … When a selection is active, its bounding rectangle will be highlighted in the rulers." Toolbar — https://paint.net/doc/latest/Toolbar.html (same wording; grid and rulers are also toolbar toggles). Keyboard shortcuts — https://paint.net/doc/latest/KeyboardMouseCommands.html: the View section lists only Zoom In (Ctrl + +), Zoom Out (Ctrl + -), Zoom to Window (Ctrl + B), Zoom to Selection (Ctrl + Shift + B), Actual Size (Ctrl + 0); **no shortcut is documented for Pixel Grid or Rulers** (see Open questions 1–2).
> Milestone: v1.x
> Depends on: 0051-use-case-acceptance-tests (and through it every v1.0 spec; this spec builds directly on 0003, 0004, 0013/0014, 0024, 0045, 0046, 0049).

## Context

There is no application code yet; everything below names the files and types the earlier specs create.

- **Canvas rendering (0003, `docs/specs/todo/0003-metal-canvas-rendering_TODO.md:44-135`).** `Core/Rendering/CanvasTransform.swift` is the single source of every coordinate conversion. Device space is top-left, y down; `imageOriginInDevice = (ox, oy)` is an integer device pixel; `canvasToDevice(c) = (ox + c.x · zoom, oy + c.y · zoom)`; `zoom` is device pixels per image pixel (1.0 = 100 %); `drawableSize`, `drawnImageRectInDevice`, `visibleCanvasRect` exist (`0003…:53-79`). The display pass `canvas_fragment` in `Core/Rendering/Shaders/Canvas.metal` reads the intermediate texture with nearest sampling at `zoom ≥ 1` as `t = floor((position.xy − origin) / devicePerTexel)`, composites over the checkerboard, and leaves device pixels outside `drawnImageRectInDevice` at the clear color (`0003…:120-128`). `CanvasUniforms` is mirrored in Swift in `MetalCanvasRenderer.swift` (`0003…:122`). `CanvasFrame` (`0003…:130-135`) carries `image`, `transform`, `checkerboard`, `backgroundColor`; 0024 (`0024…:143`) switches the renderer to the multi-layer composite and keeps the final pass; 0046 (`0046…:104`) adds `CanvasView.checkerboard` as a uniform-only change ("doesn't call `invalidateAll()`"). This spec follows that uniform-only pattern for the grid.
- **Navigation, units, status bar (0004, `0004…:58-120`).** `CanvasTransform+Navigation.resized(to:)` keeps zoom and the view-center point on a view resize (`0004…:63`, `:97`). `MeasurementUnit` (`.pixels "px"`, `.inches "in"`, `.centimeters "cm"`; `displayName` "Pixels"/"Inches"/"Centimeters"; `sanitizedDPI`; `value(fromPixels:dpi:)`; `format(pixels:dpi:)`) at `0004…:76-81`. `AppSettings` (keys `settings.*`, `.appSettingsDidChange` with `userInfo["key"]`) at `0004…:83-87`; 0046 completes it with `allKeys` (5 entries, test `allKeysArePrefixed`, `0046…:71`, `:238`). `CanvasView`'s tracking area sets `StatusBarModel.cursorPixel` from `viewToCanvas` on move/drag and `nil` on exit (`0004…:100`). View menu (`menu.view`): Zoom In, Zoom Out, Zoom to Window, (0014) Zoom to Selection, Actual Size, separator, Enter Full Screen (`0004…:104-110`, `0014…:175`).
- **Selection (0013/0014).** `Selection.bounds: PixelRect` = tight bounds of the mask (`0013…:61`, `:104`); `DocumentState.selection`; `DocumentWindowController` reacts to `change.affectsSelection` (`0013…:190`).
- **Window content (0006 `…:307`, 0013 `…:187`).** Content = vertical stack `ToolOptionsBar` (30 pt) / canvas container (`CanvasView`, `MarchingAntsOverlay`, `ToolOverlayView`, and the later overlays 0020 `TransformHandlesOverlay`, 0038 `ShapeHandlesOverlay`, 0040 `TextEditingOverlay`, all with the canvas view's frame) / status bar.
- **Shortcuts (0045, `0045…:36-116`, `:158-165`).** `ShortcutTable.entries` is the single source; menu items get chords via `MainMenu.item(_:action:identifier:)` + `applyShortcut`; `ShortcutKey.character` currently allows `"a"…"z", "0"…"9", "=", "-", "+", "[", "]", ","` (`0045…:42`); `SystemReservedShortcuts.chords` (`0045…:283-285`); `docs/shortcuts.md` must be byte-identical to `ShortcutMarkdown.render()`. ⌘R is Resize… (`image.resizeImage`), ⇧⌘R is Canvas Size…; neither ⌘' nor ⌥⌘R appears anywhere in the table or the reserved list.
- **Theme (0049, `0049…:130-172`).** `Core/Rendering/AppearancePalette.swift` (`ColorRole`, `PaletteValue`, `AppearancePalette.value(for:increaseContrast:)`, `isAppearanceNeutral`, `backgroundRole`, `minimumContrast`), `UI/Theme/ThemeColors.swift` (`nsColor`, `resolved`), `DisplayAccessibilityOptions.increaseContrast`, `App/AccessibilityDisplayMonitor.swift`, `Core/Accessibility/AccessibilityCatalog.swift` (every UI identifier catalogued), `SourceAuditTests.noHardCodedColorsInUI`. Neutral roles are `.fixed` and identical with and without Increase Contrast (`AppearancePaletteTests.neutralRolesAreFixed`).
- **Missing:** no pixel grid, no rulers, no View menu toggles, no persisted view toggles.

## User story

As a PaintDotMac user doing pixel-precise work, I can turn on View > Pixel Grid and, once I zoom to 200 % or more, see a one-device-pixel grid between every image pixel that stays visible on black, white, colored, and transparent areas; and I can turn on View > Rulers to get rulers along the top and left of the canvas in my current unit (pixels, inches, or centimeters), with 0 at the image's top-left corner, tick spacing that adapts to the zoom, a marker following my pointer, and the selection's bounds highlighted. Both toggles are remembered across launches.

## Scope & changes

### Core (headless, unit-tested; no AppKit/SwiftUI)

1. **`PaintDotMac/Core/Rendering/PixelGrid.swift`** (new):
   ```swift
   public enum PixelGridState: String, Sendable, CaseIterable { case off, belowZoom, visible }
   public struct PixelGridLines: Equatable, Sendable {
       public var columns: [Int]   // device x of each vertical line, ascending, each in [drawn.minX, drawn.maxX)
       public var rows: [Int]      // device y of each horizontal line, ascending, each in [drawn.minY, drawn.maxY)
       public var span: PixelRect  // = transform.drawnImageRectInDevice; lines are drawn only inside it
       public static let empty: PixelGridLines
       /// One byte per device column (0..<drawableWidth) then per device row (0..<drawableHeight): 1 = line, 0 = no line.
       public func flags(drawableWidth: Int, drawableHeight: Int) -> [UInt8]
   }
   public struct PixelGridStyle: Equatable, Sendable {
       public var lineOpacity: UInt8                         // 128 normally, 255 with Increase Contrast
       public var darkColor: ColorRGBA8                      // AppearancePalette .pixelGridDark  (#000000FF)
       public var lightColor: ColorRGBA8                     // AppearancePalette .pixelGridLight (#FFFFFFFF)
       public static func standard(increaseContrast: Bool) -> PixelGridStyle
       /// Final opaque color of a grid pixel drawn over the already composited opaque pixel `under`.
       public func lineColor(over under: ColorRGBA8) -> ColorRGBA8
   }
   public enum PixelGrid {
       public static let minimumZoom: Double = 2.0           // 200 % (Paint.NET: "not visible below 200% magnification")
       public static func state(isEnabled: Bool, zoom: Double) -> PixelGridState
       public static func lines(for transform: CanvasTransform) -> PixelGridLines
   }
   ```
   - `state`: `!isEnabled` → `.off`; `zoom ≥ minimumZoom − 1e-9` → `.visible`; else `.belowZoom`. Zoom is 0003's device-pixels-per-image-pixel, so per CAN-6 the threshold is 200 % on every backing scale.
   - `lines(for:)`: `.empty` (span = `drawnImageRectInDevice`) when `zoom < minimumZoom − 1e-9`, the image is 0 wide/high, or the drawn rect is empty. Otherwise, with `(ox, oy) = imageOriginInDevice`, `z = zoom`, image size `(iw, ih)`: **interior lines only** — vertical line `i ∈ 1…iw−1` occupies device column `c_i = Int(((Double(ox) + Double(i) · z − 0.5) − 1e-9).rounded(.up))`, which is the first device column that 0003's nearest sampling assigns to image column `i`. Rows likewise with `oy`, `j ∈ 1…ih−1`. Keep only lines inside `span` (`span.minX ≤ c < span.maxX`). Iterate only the `i` that can be visible: `i` from `max(1, Int(floor((Double(span.minX − ox)) / z)))` to `min(iw − 1, Int(ceil(Double(span.maxX − ox) / z)) + 1)`, then filter — never loop over the whole image width. No line at the image's outer edges (the canvas surround already shows them; an edge line would hide a whole image column at 200 %).
   - `flags`: an array of `drawableWidth + drawableHeight` bytes; index `c` (column) and `drawableWidth + r` (row) set to 1. Values outside the drawable are ignored.
   - `PixelGridStyle.standard`: `lineOpacity = increaseContrast ? 255 : 128`; colors from `AppearancePalette.value(for: .pixelGridDark/.pixelGridLight, increaseContrast:)` (both `.fixed`).
   - `lineColor(over:)` — integer formula the shader mirrors (±1): `lum = 2126·r + 7152·g + 722·b` (Rec. 709 weights × 10 000 on the stored sRGB bytes); `line = lum ≥ 1_275_000 ? darkColor : lightColor` (threshold = 127.5 × 10 000); per channel `out = (under · (255 − a) + line · a + 127) / 255` (integer division, `a = lineOpacity`); `out.a = 255`. The grid is display-only: it never touches `LayeredImage`, history, exports, the clipboard, or `CPUCompositor`.

2. **`PaintDotMac/Core/Rendering/RulerLayout.swift`** (new):
   ```swift
   public enum RulerAxis: Sendable { case horizontal, vertical }
   public enum RulerTickKind: Sendable, Equatable { case major, medium, minor }
   public struct RulerTick: Equatable, Sendable {
       public var position: Double     // points from the ruler's leading (horizontal) or top (vertical) edge = canvas view's left/top edge
       public var kind: RulerTickKind
       public var label: String?       // majors only
   }
   public struct RulerScale: Equatable, Sendable {
       public var majorStep: Double    // in the unit (px, in, or cm)
       public var subdivisions: Int    // minor intervals per major interval (1 = majors only)
       public var decimals: Int        // label decimals
   }
   public enum RulerLayout {
       public static let thickness: Double = 20             // points
       public static let minimumMajorSpacing: Double = 64   // points between labelled ticks
       public static func scale(unit: MeasurementUnit, dpi: Double, zoom: Double, backingScale: Double) -> RulerScale
       public static func ticks(axis: RulerAxis, transform: CanvasTransform, unit: MeasurementUnit, dpi: Double) -> [RulerTick]
       public static func markerPosition(axis: RulerAxis, canvasCoordinate: Double, transform: CanvasTransform) -> Double?
       public static func highlight(axis: RulerAxis, selectionBounds: PixelRect?, transform: CanvasTransform) -> ClosedRange<Double>?
       public static func label(_ value: Double, decimals: Int) -> String
       public static func accessibilityValue(unit: MeasurementUnit, scale: RulerScale, cursorPixel: Int?, dpi: Double) -> String
   }
   ```
   - **Units:** `pixelsPerUnit` = 1 (px), `dpi` (in), `dpi / 2.54` (cm), with `dpi = MeasurementUnit.sanitizedDPI(dpi)`; `pointsPerUnit = zoom / backingScale · pixelsPerUnit` (backing scale ≤ 0 or non-finite → 1).
   - **`scale`:** candidates `m · 10^k` for `m ∈ {1, 2, 5}` and `k ∈ −3…6`, built exactly (`k ≥ 0`: `Double(m) · pow(10, k)`; `k < 0`: `Double(m) / pow(10, −k)`), ascending; for `.pixels` only `k ≥ 0`. `majorStep` = the smallest candidate with `candidate · pointsPerUnit ≥ minimumMajorSpacing − 1e-9`; if none qualifies, the largest (5 000 000). `decimals = max(0, −k)` of the chosen candidate. `subdivisions`: `m = 1` → 10, `m = 2` → 4, `m = 5` → 5; except `.pixels` with `k = 0` (steps 1, 2, 5 px), where it is 1, 2, 5 so minor ticks stay on whole pixels. (With the 64-pt minimum, minor spacing is always ≥ 6.4 pt, so no further suppression rule is needed.)
   - **`ticks`:** along the axis use `o = ox` / `oy`, `L = drawableSize.width` / `.height`, `s = backingScale`; `devicePerUnit = zoom · pixelsPerUnit`; tick index `n` has value `u_n = Double(n) · majorStep / Double(subdivisions)` and device position `d_n = (Double(o) + u_n · devicePerUnit).rounded()` (to nearest, ties away from zero — crisp on whole device pixels). Generate `n` from `floor(−o / (devicePerUnit · step/sub)) − 1` to `ceil((L − o) / (devicePerUnit · step/sub)) + 1`; keep ticks with `0 ≤ d_n < L`; `position = d_n / s`. Kind: `n % subdivisions == 0` → `.major` with `label(u_n, decimals:)`; else if `subdivisions` is even and `n % (subdivisions / 2) == 0` → `.medium`; else `.minor`. The rulers span the whole canvas view, so values left of / above the image are negative; 0 is the image's top-left corner (canvas origin).
   - **`label`:** the value rounded half away from zero to `decimals` digits, printed with exactly `decimals` digits, `"."` decimal separator, ASCII `"-"` for negatives, no unit suffix (Paint.NET's rulers show bare numbers); negative zero prints as `"0"` (or `"0.00"` etc.).
   - **`markerPosition`:** `d = (canvasToDevice(axis coordinate)).rounded()`; `nil` when `d < 0` or `d ≥ L` or the coordinate is non-finite; else `d / s`. The caller passes the pointer's continuous canvas coordinate.
   - **`highlight`:** `nil` for `nil` or empty bounds; else start `= (o + minX · zoom).rounded()`, end `= (o + maxX · zoom).rounded()` (`minY`/`maxY` for vertical), clamped to `[0, L]`; `nil` when `end ≤ start` after clamping; else `(start / s)…(end / s)`.
   - **`accessibilityValue`:** `"<unit displayName>, ticks every <label(majorStep, decimals)>"`, plus `", cursor <unit.format(pixels: cursorPixel, dpi:)>"` when `cursorPixel` is non-nil. Examples: `"Pixels, ticks every 100, cursor 250"`, `"Inches, ticks every 0.05"`.

3. **`PaintDotMac/Core/Rendering/RulerMetrics.swift`** (new) — the pure layout of the canvas area:
   ```swift
   public struct CanvasAreaLayout: Equatable, Sendable {
       public var canvas: CGRect, horizontalRuler: CGRect?, verticalRuler: CGRect?, corner: CGRect?
       public static func make(containerSize: CGSize, rulersVisible: Bool) -> CanvasAreaLayout
   }
   ```
   Bottom-left container coordinates (AppKit, the container is not flipped), `t = RulerLayout.thickness`, `w`, `h` = container size (negative/non-finite → 0). Hidden: `canvas = (0, 0, w, h)`, rulers/corner `nil`. Visible: `canvas = (t', 0, max(0, w − t'), max(0, h − t'))` with `t' = min(t, w, h)`, `horizontalRuler = (t', h − t', max(0, w − t'), t')`, `verticalRuler = (0, 0, t', max(0, h − t'))`, `corner = (0, h − t', t', t')`.

4. **`PaintDotMac/Core/Settings/AppSettings.swift`** (extend 0004/0046): `Key.showPixelGrid = "settings.showPixelGrid"`, `Key.showRulers = "settings.showRulers"`; `var showPixelGrid: Bool { get nonmutating set }` and `var showRulers: Bool { get nonmutating set }` — read `defaults.object(forKey:) as? Bool ?? false` (missing or non-Bool → false, Paint.NET's default is off); setters write and post `.appSettingsDidChange` with their key, like every other setter. `allKeys` becomes 7 entries (`… , showPixelGrid, showRulers`). Both keys start with `settings.`, so 0001/0004's `LaunchOptions.resettableKeyPrefixes` already resets them for UI tests (D-37); no new prefix. They are app-wide (every window follows them, as in Paint.NET) and are **not** shown in the Settings window (0046) — the View menu is their only UI.

5. **`PaintDotMac/Core/Shortcuts/ShortcutTable.swift`** (extend 0045):
   - `ShortcutKey.character` additionally accepts `"'"` (`menuKeyEquivalent "'"`, glyph `"'"`); update the doc comment.
   - Two rows in the **View** section, after `view.actualSize` and before `view.enterFullScreen`:
     | id | action | menu identifier | bindings | Paint.NET | status / notes |
     |---|---|---|---|---|---|
     | view.pixelGrid | Pixel Grid | `menu.view.pixelGrid` | ⌘' ⓜ | — | macStandard — "Paint.NET's docs list no shortcut; ⌘' matches Photoshop's Show Grid (0053 Q1)." |
     | view.rulers | Rulers | `menu.view.rulers` | ⌥⌘R ⓜ | — | macStandard — "Paint.NET's docs list no shortcut; ⌘R is Resize… (Ctrl + R), so Rulers uses ⌥⌘R (0053 Q2)." |
   - Regenerate `docs/shortcuts.md` from `ShortcutMarkdown.render()` (0045's byte-identity test).

6. **`PaintDotMac/Core/Rendering/AppearancePalette.swift`** (extend 0049): new `ColorRole` cases
   - neutral (content overlay, `.fixed`, identical in both contrast settings): `pixelGridDark` #000000FF, `pixelGridLight` #FFFFFFFF;
   - app chrome (normal / Increase Contrast): `rulerBackground` windowBackgroundColor / same; `rulerBorder` separatorColor / secondaryLabelColor; `rulerTick` secondaryLabelColor / labelColor; `rulerText` labelColor / same (minimum contrast 4.5 on `rulerBackground`); `rulerMarker` controlAccentColor / labelColor; `rulerSelectionHighlight` controlAccentColor α 0.25 / α 0.40. `backgroundRole` of every `ruler*` role except `rulerBackground` is `.rulerBackground`.

7. **`PaintDotMac/Core/Accessibility/AccessibilityCatalog.swift`** (extend 0049): add `case ruler` to `AccessibilityRoleKind` (0049's UI-test role mapping gains `ruler → .ruler`) and `case rulerScale, pixelGridState` to `AccessibilityValueFormat` (UI-test regexes: rulerScale `^(Pixels|Inches|Centimeters), ticks every [0-9.]+(, cursor -?[0-9.]+)?$`; pixelGridState `^(off|belowZoom|visible)$`). Entries, surface `.documentWindow`, inserted after `canvas.marchingAnts` in this order: `ruler.horizontal` (role `.ruler`, label "Horizontal Ruler", value `.format(.rulerScale)`, produced by `RulerLayout.accessibilityValue`), `ruler.vertical` ("Vertical Ruler", same), `canvas.pixelGrid` (role `.group`, label "Pixel Grid", value `.format(.pixelGridState)` = `PixelGridState.rawValue`). The View menu items `menu.view.pixelGrid` / `menu.view.rulers` are **not** catalogued (0049: menus are covered by `MainMenuTests.everyItemHasTitle`). None of the three is in the document window's Tab order (`KeyboardNavigationPlan` unchanged: rulers and the grid indicator are not focusable).

### Rendering (Metal; Core, GPU-tested headlessly)

8. **`PaintDotMac/Core/Rendering/MetalCanvasRenderer.swift`** (extend 0003/0024/0046/0048): `CanvasFrame` gains `var pixelGrid: PixelGridStyle? = nil` (`nil` = no grid). Per frame, when `pixelGrid != nil` and `PixelGrid.lines(for: transform)` is non-empty, the renderer fills a reused `MTLBuffer` (`storageModeShared`, grown only when `drawableWidth + drawableHeight` exceeds its length) with `lines.flags(...)` — rebuilt only when the transform or drawable size changed since the last frame — and binds it to the final pass. Uniforms (`CanvasUniforms` in Swift and `Canvas.metal`, kept in sync) gain `gridEnabled: uint` (0/1), `gridOpacity: float` (`lineOpacity / 255`), `gridDark: float4`, `gridLight: float4`, `drawableWidth: uint`. Toggling the grid or crossing 200 % never re-uploads or rebuilds tiles (it is a uniform/buffer change, like 0046's checkerboard). With `pixelGrid == nil` the output is byte-identical to the renderer without this spec.

9. **`PaintDotMac/Core/Rendering/Shaders/Canvas.metal`** (extend): in the final display fragment (0003's `canvas_fragment` as modified by 0024/0048), after the image-over-checkerboard composite yields the opaque `out`: if `gridEnabled` and (`flags[x] == 1` or `flags[drawableWidth + y] == 1`) for the fragment's integer device coordinates, then `under = round(out.rgb · 255)`, `lum = dot(under, float3(0.2126, 0.7152, 0.0722))`, `line = lum ≥ 127.5 ? gridDark : gridLight`, `out.rgb = (under · (1 − gridOpacity) + line.rgb · 255 · gridOpacity) / 255`. Pixels outside `drawnImageRectInDevice` are still never shaded, so the grid never touches the surround. Exactly one device pixel wide on every backing scale, never antialiased, never scaled with zoom.

### Platform glue (AppKit; hosted tests, UI tests, manual checks)

10. **`PaintDotMac/Canvas/CanvasView.swift`** (extend): `var showsPixelGrid: Bool = false` and `var increaseContrast: Bool = false`, each `didSet { needsDisplay = true }` only on change (no `invalidateAll()`); `draw(_:)` passes `pixelGrid = PixelGrid.state(isEnabled: showsPixelGrid, zoom: transform.zoom) == .visible ? PixelGridStyle.standard(increaseContrast:) : nil` into `CanvasFrame`. Pointer moves/drags/exits that already update `StatusBarModel.cursorPixel` (0004) also call `onPointerCanvasPoint?(CGPoint?)` with the continuous `transform.viewToCanvas(point)` (nil on exit).

11. **`PaintDotMac/Canvas/PixelGridStateView.swift`** (new) — following 0013's `MarchingAntsOverlay` pattern: a transparent, layer-free `NSView` with the canvas view's frame, `hitTest(_:) → nil`, draws nothing, `isAccessibilityElement = true`, role `.group`, identifier `canvas.pixelGrid`, label "Pixel Grid", value `PixelGridState.rawValue`; `func update(isEnabled: Bool, zoom: Double)`. Inserted with the other overlays.

12. **`PaintDotMac/Canvas/RulerView.swift`** (new) — `final class RulerView: NSView`, `isFlipped == true` (so a tick's `position` is the drawing coordinate along the axis for both axes), `init(axis: RulerAxis)`. Not `NSRulerView` (that requires an `NSScrollView`; v1.0 has none, CAN-6). State: `transform: CanvasTransform`, `unit: MeasurementUnit`, `dpi: Double`, `pointerCanvasPoint: CGPoint?`, `selectionBounds: PixelRect?`, `increaseContrast: Bool`; each setter → `needsDisplay = true`. `draw(_:)`, all colors from `ThemeColors` (0049): fill `rulerBackground`; `rulerSelectionHighlight` band across the ruler's thickness for `RulerLayout.highlight`; ticks from `RulerLayout.ticks` as filled rects exactly `1 / backingScale` pt wide (one device pixel), at the far edge from the canvas… i.e. growing from the edge that touches the canvas: lengths major = full thickness, medium = 50 %, minor = 25 %, color `rulerTick`; labels for majors in `NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)`, color `rulerText`, drawn 2 pt after the tick (horizontal: left-aligned to the right of the tick, at the top; vertical: rotated −90° so it reads bottom-to-top, just below the tick); a 1-device-pixel `rulerBorder` line on the edge that touches the canvas; the pointer marker from `RulerLayout.markerPosition` as a 1-device-pixel full-thickness line in `rulerMarker`. Accessibility: element, role `.ruler`, identifier `ruler.horizontal` / `ruler.vertical`, label "Horizontal Ruler" / "Vertical Ruler", value `RulerLayout.accessibilityValue(unit:scale:cursorPixel: floor of the pointer's canvas x (y), dpi:)`. Mouse events on rulers are ignored (`hitTest` returns self but `mouseDown` does nothing; no tool events, no guides). Redraws on `viewDidChangeEffectiveAppearance` and `viewDidChangeBackingProperties`.

13. **`PaintDotMac/Canvas/CanvasAreaView.swift`** (new) — the canvas container `NSView` (not flipped) that `DocumentWindowController` puts between `ToolOptionsBar` and the status bar. It owns the canvas stack (the `CanvasView` and every overlay sibling sharing its frame: `PixelGridStateView`, `MarchingAntsOverlay`, `ToolOverlayView`, `TransformHandlesOverlay`, `ShapeHandlesOverlay`, `TextEditingOverlay`), the two `RulerView`s, and a corner `NSView` (fill `rulerBackground`, not an accessibility element). `var rulersVisible: Bool { didSet { needsLayout = true } }`; `layout()` applies `CanvasAreaLayout.make(containerSize: bounds.size, rulersVisible:)` (rulers and corner `isHidden` when `nil`, so they leave the accessibility tree). Resizing the canvas view goes through 0004's existing `setFrameSize → resized(to:)` path (zoom and the view-center canvas point are kept, as for a window resize).

14. **`PaintDotMac/Document/DocumentWindowController.swift`** (extend): builds `CanvasAreaView`; on init and on `.appSettingsDidChange` for `showPixelGrid` / `showRulers` / `measurementUnit` it sets `canvasView.showsPixelGrid`, `canvasArea.rulersVisible`, and the rulers' `unit`; wherever it forwards a new transform to `ToolOverlayView` / `MarchingAntsOverlay` (0006/0013) it also updates both rulers' `transform` and `PixelGridStateView.update`; `onStateChange` updates the rulers' `dpi` (`LayeredImage.dpi`, e.g. after 0035 Resize Image changes resolution) and, when `change.affectsSelection` or after `UndoBridge.reset`, their `selectionBounds` (`DocumentState.selection?.bounds`); `canvasView.onPointerCanvasPoint` updates both rulers' `pointerCanvasPoint`; 0049's `AccessibilityDisplayMonitor` updates `increaseContrast` on the canvas view and rulers.

15. **`PaintDotMac/App/MainMenu.swift`** (extend): in the View menu after "Actual Size": separator, **"Pixel Grid"** (`menu.view.pixelGrid`, action `togglePixelGrid(_:)`), **"Rulers"** (`menu.view.rulers`, action `toggleRulers(_:)`), then 0001's separator and Enter Full Screen. Created through 0045's `item(_:action:identifier:)` so the chords come from `ShortcutTable` (no literal key equivalent). Targets `nil`.

16. **`PaintDotMac/App/ViewToggleCommands.swift`** (new) — `@MainActor final class ViewToggleCommands: NSObject, NSMenuItemValidation`, owned by `AppDelegate` with an injected `AppSettings`; `AppDelegate` forwards `togglePixelGrid(_:)` / `toggleRulers(_:)` and `validateMenuItem(_:)` for those two identifiers to it (the app delegate is in the responder chain, so the items work with or without a document window and with a panel key). Toggle flips the setting; validation sets `state = .on/.off` from the setting and returns `true`. Pure decision exposed for tests: `static func menuState(for identifier: String, settings: AppSettings) -> NSControl.StateValue?`.

17. **`project.yml`**: no change (existing source globs pick up the new files). Run `xcodegen generate`.

18. **PRD:** no change by this spec (CAN-5 is delivered as written). The answers to the Open questions below must be recorded in PRD §5.2 CAN-5, §5.12, and §12 when the user confirms them.

## Acceptance criteria

- [ ] View menu shows, after Actual Size and a separator, "Pixel Grid" (⌘') and "Rulers" (⌥⌘R), then a separator and Enter Full Screen; both show a checkmark exactly when on; both work with no document open. → `MainMenuTests.viewMenuItems` (updated), `ViewToggleCommandsTests.*`, UI `PixelGridAndRulersUITests.testViewMenuItems`
- [ ] The two chords come from `ShortcutTable`, conflict with nothing (menu, single keys, macOS reserved), and appear in `docs/shortcuts.md`. → `ShortcutConflictTests` on the real table (expects `[]`), `ShortcutTableTests.everyRowLiteral` (updated), `.viewRowsIncludeGridAndRulers`, `ShortcutKeyTests.apostrophe`, `ShortcutDocsTests.docsFileMatchesTable`
- [ ] With Pixel Grid on, the grid appears at zoom ≥ 200 % and is absent below 200 %; with it off, nothing is drawn at any zoom. → `PixelGridTests.state*`, `MetalCanvasRendererTests.pixelGridHiddenBelow200`, `.pixelGridOffIsByteIdentical`, UI `testPixelGridFollowsZoomThreshold`
- [ ] Grid lines lie exactly on image pixel boundaries, are exactly one device pixel wide on 1× and 2× backing scales, at integer and non-integer zooms, only between image pixels (no outer edge lines), and only over the image. → `PixelGridTests.lines*`, `MetalCanvasRendererTests.pixelGrid400Percent1x`, `.pixelGrid2xBacking`, `.pixelGridNonIntegerZoom`, `.pixelGridNeverTouchesSurround`
- [ ] Grid lines stay visible over black, white, mid-gray, saturated colors, and transparency (checkerboard), using `pixelGridDark`/`pixelGridLight` at 50 % (100 % with Increase Contrast). → `PixelGridTests.lineColor*`, `MetalCanvasRendererTests.pixelGridContrast*`, `AppearancePaletteTests.pixelGridRolesNeutral`; manual 1–2
- [ ] Toggling the grid or crossing 200 % uploads no tiles. → `MetalCanvasRendererTests.gridChangeUploadsNoTiles`
- [ ] Rulers appear along the top and left of the canvas (20 pt) with a corner square, shrinking the canvas view by the ruler thickness; hiding them restores the full canvas. → `CanvasAreaLayoutTests.*`, `CanvasAreaViewTests.*`, UI `testRulersToggleShrinksCanvas`
- [ ] Rulers use the current unit and the document DPI, 0 at the image's top-left, negative outside it, with 1-2-5 major steps chosen so labels are ≥ 64 pt apart at the current zoom and backing scale, ticks on whole device pixels. → `RulerLayoutTests.scale*`, `.ticks*`, `.label*`, UI `testRulersFollowUnit`, `testRulerStepFollowsZoom`
- [ ] A marker follows the pointer on both rulers and its accessibility value matches the status-bar cursor; the selection's bounding range is highlighted. → `RulerLayoutTests.marker*`, `.highlight*`, `RulerViewTests.*`, UI `testRulerCursorMatchesStatusBar`, `testRulerHighlightsSelection`
- [ ] Both toggles persist across relaunch, are app-wide (every open window follows), and are cleared by `-UITestResetDefaults`. → `AppSettingsTests.viewToggles*`, `.allKeysArePrefixed` (7 keys), UI `testTogglesPersistAcrossRelaunch`, `testTogglesApplyToAllWindows`
- [ ] Rulers and grid indicator are catalogued and use `ThemeColors` only. → `AccessibilityCatalogTests.rulerAndPixelGridEntries` (0049, extended), `PixelGridAndRulersUITests.testRulersMatchCatalog`, `SourceAuditTests.noHardCodedColorsInUI`, `ThemeColorsAppearanceTests.contentRolesMeetContrast` (covers `rulerText`)
- [ ] The grid never appears in saved files, the clipboard, or history. → by construction (display-only `CanvasFrame` field) and `PixelGridExportUITest`-free: `IntegrationTests.gridOnSaveRoundTripUnchanged` (see Test plan)
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **1×1 / 1×N images:** no vertical lines when `iw = 1`, no horizontal lines when `ih = 1`; `lines` is empty for 1×1. → `PixelGridTests.oneByOneHasNoLines`, `.oneWideHasRowsOnly`
- **0 × 0 view or drawable (minimized, mid-layout):** `lines` → `.empty`, `ticks` → `[]`, marker/highlight → `nil`; no crash. → `PixelGridTests.emptyDrawable`, `RulerLayoutTests.emptyDrawable`
- **Container smaller than the ruler thickness:** `CanvasAreaLayout` clamps (`t' = min(20, w, h)`), never negative sizes. → `CanvasAreaLayoutTests.tinyContainer`
- **Huge image partially visible (65 535 px wide at 3200 %):** only visible lines/ticks are generated (bounded by drawable size, not image size). → `PixelGridTests.onlyVisibleLines`, `.hugeImageAt3200IsBounded`, `RulerLayoutTests.tickCountBounded`
- **Exactly 200 % and 199.99 %:** visible / below. Pinch can land on non-integer zooms (e.g. 250 %) — lines still sit on the shader's pixel boundaries. → `PixelGridTests.stateAtThreshold`, `.nonIntegerZoomMatchesNearestSampling`
- **Floating error at exact boundaries** (e.g. `ox + i·z − 0.5` integral): the `− 1e-9` keeps the line on the first column of pixel `i`. → `PixelGridTests.exactHalfBoundary`
- **Invalid DPI (0, NaN, negative):** treated as 96 through `MeasurementUnit.sanitizedDPI`. → `RulerLayoutTests.invalidDPIFallsBackTo96`
- **Extreme DPI / zoom:** very high DPI at 3200 % hits the smallest candidate 0.001 (3 decimals); 1 % at 2× hits large pixel steps (20 000); nothing beyond the candidate range crashes. → `RulerLayoutTests.smallestCandidate`, `.largestCandidate`
- **Negative values and negative zero:** labels "-20", "0" (never "-0"). → `RulerLayoutTests.labelNegativeZero`, `.negativeTicks`
- **Pointer outside the canvas view or over a ruler:** marker hidden; accessibility value has no cursor part. → `RulerLayoutTests.markerOutsideIsNil`, `RulerViewTests.noPointerNoCursorInValue`
- **No selection / empty selection / selection fully off-screen:** no highlight. → `RulerLayoutTests.highlightNilCases`
- **Unit change while rulers are hidden:** applied when shown. **DPI change (Resize Image resolution):** rulers redraw on the state change. → `RulerViewTests.unitAndDPIUpdate`
- **Stored non-Bool value** for `settings.showPixelGrid` (e.g. a string): reads false. → `AppSettingsTests.viewTogglesNonBoolReadsFalse`
- **Toggling rulers mid-gesture** (via ⌥⌘R during a drag): the canvas resizes through `resized(to:)`; the gesture continues in view space with the new transform (no crash). → manual 6
- **Initial window size with rulers on:** the window is sized as before (0003's `initialContentSize`), so an image that just fits may open below 100 % by Zoom to Window; accepted. → `CanvasAreaViewTests.initialFitUsesCanvasSize`
- **Dark mode / Increase Contrast:** chrome roles follow the system; the grid's neutral colors don't. → `ThemeColorsAppearanceTests` (extended); manual 3

## Test plan

Expected values below are hand-computed from the formulas in this spec and 0003's transform; never paste output from the code under test.

- **Unit — `PaintDotMacTests/Rendering/PixelGridTests.swift`** (Swift Testing):
  - `stateOffWhenDisabled` (zoom 32 → `.off`); `stateAtThreshold` (enabled: 2.0 → `.visible`, 1.9999 → `.belowZoom`, 1.0 → `.belowZoom`, 32 → `.visible`).
  - `lines400Percent1x`: image 4×3, view 40×30 pt, backing 1, zoom 4, center (2, 1.5) → `ox = 12`, `oy = 9`; columns `[16, 20, 24]`, rows `[13, 17]`, span `(12, 9, 16, 12)`.
  - `lines2xBackingSameDevice`: same image, view 20×15 pt, backing 2, zoom 4 → identical columns/rows (device-pixel based).
  - `nonIntegerZoomMatchesNearestSampling`: image 4×3, view 40×30, backing 1, zoom 2.5, center (2, 1.5) → `ox = 15`, `oy = 11`; columns `[17, 20, 22]`, rows `[13, 16]`.
  - `onlyVisibleLines`: image 1000×1000, view 100×100, backing 1, zoom 4, center (500, 500) → `ox = −1950`; columns = `2, 6, …, 98` (25 values), rows the same.
  - `hugeImageAt3200IsBounded`: image 65 535×65 535, view 200×100 pt, backing 2, zoom 32, center (30 000.5, 30 000.5) → every column lies in `[0, 400)`, consecutive columns differ by exactly 32, count ≤ 13; rows likewise in `[0, 200)`.
  - `oneByOneHasNoLines`, `oneWideHasRowsOnly` (image 1×3 at zoom 4 → columns `[]`, rows 2 values), `belowThresholdIsEmpty` (zoom 1.5), `emptyDrawable` (view 0×0), `exactHalfBoundary` (zoom 2.5 case above: column for i=1 is 17, not 18).
  - `flagsLayout`: the 4×3 @400 % case, `flags(drawableWidth: 40, drawableHeight: 30)` has length 70, ones exactly at indices 16, 20, 24, 40+13, 40+17.
  - `lineColorOverWhite` (255,255,255 / a 128 → (127,127,127,255)); `lineColorOverBlack` (→ (128,128,128,255)); `lineColorMidGrayThreshold` ((128,128,128) → dark → (64,64,64); (127,127,127) → light → (191,191,191)); `lineColorOverRed` ((255,0,0) → light → (255,128,128)); `lineColorIncreaseContrast` (a 255: white → (0,0,0), black → (255,255,255)); `standardStyle` (opacity 128 / 255, colors #000000FF / #FFFFFFFF).
- **Unit — `PaintDotMacTests/Rendering/RulerLayoutTests.swift`:**
  - `scalePixels`: (zoom, backing) → (step, subdivisions): (1, 1) → (100, 10); (1, 2) → (200, 4); (32, 1) → (2, 2); (32, 2) → (5, 5); (8, 1) → (10, 10); (3, 1) → (50, 5); (0.5, 1) → (200, 4); (0.01, 1) → (10 000, 10); (0.01, 2) → (20 000, 4); decimals 0 throughout.
  - `scaleInches`: dpi 96, zoom 1, backing 1 → (1, 10, decimals 0); zoom 32, backing 1 → (0.05, 5, decimals 2). `scaleCentimeters`: dpi 96, zoom 1, backing 1 → (2, 4, 0); zoom 0.25, backing 2 → (20, 4, 0).
  - `smallestCandidate`: inches, dpi 10 000, zoom 32, backing 1 → step 0.001, decimals 3, subdivisions 10. `largestCandidate`: pixels, zoom 0.01, backing 2, `minimumMajorSpacing` unchanged, synthetic `pointsPerUnit` small enough via zoom 0.0001 passed directly to `scale` → 5 000 000.
  - `ticksHorizontalPixels`: image 800×600, view 400×300, backing 1, zoom 1, center (400, 300) → `ox = −200`; 40 ticks; majors at positions 0, 100, 200, 300 with labels "200", "300", "400", "500"; mediums at 50, 150, 250, 350; first minor at 10.
  - `ticksVerticalPixels`: same transform, vertical (`oy = −150`) → first tick position 0 is a medium (value 150); majors at 50, 150, 250 labelled "200", "300", "400".
  - `ticksInches2x`: image 960×480, dpi 96, view 960×480, backing 2, zoom 2, center (480, 240) → `ox = 0`; 100 ticks; majors at 0, 96, …, 864 labelled "0"…"9"; tick n = 1 at 9.5 (device 19.2 → 19), n = 3 at 29 (57.6 → 58).
  - `ticksCentimetersNegative`: image 400×400, dpi 96, view 400×400, backing 2, zoom 0.25, center (200, 200) → `ox = 350`; majors at 80.5 ("-20"), 175 ("0"), 269.5 ("20"), 364 ("40"); mediums at values −10, 10, 30; no tick for −40 (device −28).
  - `label*`: (0.1 + 0.2, 1) → "0.3"; (0.10, 2) → "0.10"; (−0.0, 0) → "0"; (−20, 0) → "-20"; (2.675, 2) → "2.68" (half away from zero computed on the decimal value, implement via `(v · 10^d).rounded(.toNearestOrAwayFromZero)`; assert "2.68" only if the implementation scales first — the test instead uses 0.125 with 2 decimals → "0.13" and 1.5 with 0 → "2", which are exact in binary).
  - `marker*`: pixel transform above: canvas x 250.3 → 50; −300 → nil; 600 → nil (device 400 = L); inch transform (backing 2): 10.25 → 10.5 (device 20.5 ties away → 21); NaN → nil.
  - `highlight*`: pixel transform: bounds x 150 w 300 → 0…250; x 700 w 50 → nil; nil / empty bounds → nil; vertical with y 200 h 100 → 50…150.
  - `accessibilityValue*`: `"Pixels, ticks every 100, cursor 250"`; inches step 0.05 without cursor → `"Inches, ticks every 0.05"`; inches cursor pixel 250 at 96 DPI → `"Inches, ticks every 1, cursor 2.60"`.
  - `invalidDPIFallsBackTo96` (dpi 0 and NaN give the same scale as 96), `emptyDrawable`, `tickCountBounded` (pixels at zoom 32/backing 2 on a 3000-pt view → count ≤ 3000 / 6.4 + 3).
- **Unit — `PaintDotMacTests/Rendering/CanvasAreaLayoutTests.swift`:** `hidden` (800×600 → canvas (0,0,800,600), others nil); `visible` (800×600 → canvas (20,0,780,580), horizontal (20,580,780,20), vertical (0,0,20,580), corner (0,580,20,20)); `tinyContainer` (10×30 → t' 10: canvas (10,0,0,20), horizontal (10,20,0,10)); `zeroAndNegative` (−5×0 → all sizes 0, no negatives).
- **Unit — `PaintDotMacTests/Settings/AppSettingsTests.swift`** (extend 0004/0046, private suite): `viewTogglesDefaultOff`; `viewTogglesRoundTrip` (set both true → second instance reads true; stored as Bool); `viewTogglesNonBoolReadsFalse` (`"yes"` string → false); `viewTogglesPost` (each setter posts once with its key); `allKeysArePrefixed` updated to 7 unique keys, each reset by `LaunchOptions.shouldReset(key:)`.
- **Unit — Shortcuts (extend 0045):** `ShortcutKeyTests.apostrophe` (`.character("'")` → menuKeyEquivalent "'", glyph "'", `KeyChord(.character("'"), [.command]).displayString == "⌘'"`); `ShortcutTableTests.viewRowsIncludeGridAndRulers` (rows `view.pixelGrid` ⌘' and `view.rulers` ⌥⌘R in that order between `view.actualSize` and `view.enterFullScreen`, status `.macStandard`, menu identifiers as above); 0045's `ShortcutTableTests.everyRowLiteral` literal gains the same two rows at that position (independent re-statement); the real-table conflict check still returns `[]`; `ShortcutDocsTests.docsFileMatchesTable` with the regenerated file.
- **Unit — `PaintDotMacTests/Accessibility/AccessibilityCatalogTests.swift`** (extend 0049): `rulerAndPixelGridEntries` — `entry(matching: "ruler.horizontal")` role `.ruler`, label "Horizontal Ruler", value `.format(.rulerScale)`; same for `ruler.vertical`; `canvas.pixelGrid` role `.group`, label "Pixel Grid", value `.format(.pixelGridState)`; all three surface `.documentWindow`, in that order directly after `canvas.marchingAnts`; `entry(matching: "menu.view.rulers") == nil`; 0049's `identifiersAreUnique`/`tabOrderIsCatalogOrder` still pass.
- **Unit — `PaintDotMacTests/Rendering/AppearancePaletteTests.swift`** (extend 0049): `pixelGridRolesNeutral` (both `.fixed` #000000FF / #FFFFFFFF in both contrast settings; `isAppearanceNeutral` true); `rulerRolesMapped` (each `ruler*` role → the token/alpha in item 6 for both settings; `backgroundRole` = `.rulerBackground`; `minimumContrast(.rulerText) == 4.5`). 0049's `everyRoleMapped`, `contentRolesMeetContrast` (four appearances) cover the new roles automatically.
- **GPU — `PaintDotMacTests/Rendering/MetalCanvasRendererTests.swift`** (extend; headless offscreen target; oracle = 0003's `CanvasReferenceRenderer` output post-processed by new `PaintDotMacTests/Support/PixelGridReference.swift`, which finds line columns independently by scanning device columns `d` and marking `d` when `floor((d + 0.5 − ox) / z) ≠ floor((d − 0.5 − ox) / z)` and the new index is in `1…iw−1` (same for rows), then applies its own float re-statement of the luminance/opacity formula; tolerance ±1 per channel):
  - `pixelGrid400Percent1x`: opaque white 4×3 image, view 40×30 pt @1×, zoom 4 → device columns 16, 20, 24 and rows 13, 17 inside the image are (127,127,127) ±1; column 15 and 17 are (255,255,255); surround pixels (e.g. (5, 5)) equal the background color.
  - `pixelGrid2xBacking`: same at 20×15 pt @2× → identical device output.
  - `pixelGridNonIntegerZoom`: zoom 2.5 case → lines at columns 17, 20, 22, rows 13, 16; matches the reference over the whole target.
  - `pixelGridContrastBlackWhite`: 8×2 image, left 4 columns black, right 4 white, zoom 4 → line pixels over black are (128,128,128) ±1, over white (127,127,127) ±1.
  - `pixelGridContrastColorsAndTransparency`: 4×1 image red / (128,128,128) / (127,127,127) / transparent, zoom 8 → vertical line pixels inside each cell's first column match `lineColor(over:)` of the composited pixel ((255,128,128), (64,64,64), (191,191,191), and over the checkerboard light square (127,127,127) / dark square 204 → (102,102,102)) ±1.
  - `pixelGridIncreaseContrast`: style opacity 255 → over white exactly (0,0,0) ±1, over black (255,255,255) ±1.
  - `pixelGridHiddenBelow200`: `PixelGrid.state(...)` at zoom 1.5 gives `nil` style → output byte-identical to a frame without the grid.
  - `pixelGridOffIsByteIdentical`: same frame rendered with `pixelGrid = nil` before and after this spec's code path → identical bytes (and identical to the reference without grid post-processing).
  - `pixelGridNeverTouchesSurround`: image 4×4 centered in a 100×100 target at zoom 4 → every pixel outside `drawnImageRectInDevice` equals the background.
  - `gridChangeUploadsNoTiles`: render, toggle grid style on, render, change zoom 2 → 4 (already uploaded level), render → `tilesUploadedLastFrame == 0` for the second and third frames.
- **Hosted — `PaintDotMacTests/Canvas/RulerViewTests.swift`** (`@MainActor`): `accessibilityIdentityAndRole` (identifiers, labels, role `.ruler`); `valueWithCursor` (pixel transform, pointer canvas (250.3, 10) → horizontal value `"Pixels, ticks every 100, cursor 250"`, vertical `"… cursor 10"`); `noPointerNoCursorInValue`; `unitAndDPIUpdate` (set `.inches`, dpi 96 → value starts `"Inches, ticks every 1"`); `isFlipped` true.
- **Hosted — `PaintDotMacTests/Canvas/CanvasAreaViewTests.swift`:** `layoutMatchesCanvasAreaLayout` (800×600, visible → `CanvasView` frame (20,0,780,580), every overlay sibling has the same frame, rulers/corner frames as computed; hidden → rulers `isHidden`); `rulersToggleResizesTransform` (canvas `transform.viewSize` changes 800×600 → 780×580, zoom and center unchanged — 0004's `resized(to:)`); `initialFitUsesCanvasSize`.
- **Hosted — `PaintDotMacTests/App/ViewToggleCommandsTests.swift`:** `toggleFlipsSetting` (each action flips its key in a private suite and posts); `menuState` (`.on`/`.off` per setting; unrelated identifier → nil); `enabledWithoutDocument` (`validateMenuItem` true). `MainMenuTests.viewMenuItems` (0004/0014/0045) updated to: Zoom In, (hidden alternate), Zoom Out, Zoom to Window, Zoom to Selection, Actual Size, separator, Pixel Grid (`'`/⌘), Rulers (`r`/⌥⌘), separator, Enter Full Screen.
- **Hosted — `PaintDotMacTests/Canvas/PixelGridStateViewTests.swift`:** identifier/label; `update(isEnabled: true, zoom: 2)` → value "visible"; `(true, 1)` → "belowZoom"; `(false, 4)` → "off"; `hitTest` nil.
- **Integration — `PaintDotMacTests/Integration/PixelGridIntegrationTests.swift`:** `gridOnSaveRoundTripUnchanged`: build a 16×16 document, set `AppSettings.showPixelGrid = true` (private suite), render a frame at zoom 4 through `MetalCanvasRenderer` (grid visible), then encode via `ImageEncoder` PNG and decode → pixels identical to the original, history has only the base step.
- **UI — `PaintDotMacUITests/PixelGridAndRulersUITests.swift`** (fixtures generated at test time via `UITestFixtures.writePNG`; default `resetDefaults: true`):
  - `testViewMenuItems`: View menu titles in order end with "Actual Size", "Pixel Grid", "Rulers", "Enter Full Screen" (separators skipped); both toggles enabled with no document (launch empty).
  - `testPixelGridFollowsZoomThreshold`: open 64×64; ⌘0 → `statusBar.zoom` "100%"; `canvas.pixelGrid` value "off"; ⌘' → "belowZoom"; ⌘= twice → zoom "200%", value "visible"; ⌘− → "belowZoom"; View > Pixel Grid → "off".
  - `testRulersToggleShrinksCanvas`: open 64×64; record `canvas` frame; ⌥⌘R → `ruler.horizontal` and `ruler.vertical` exist; canvas frame minX +20 and height −20 (±1 pt), width −20; ⌥⌘R → rulers don't exist, frame restored (±1).
  - `testRulersFollowUnit`: rulers on; `statusBar.units` → Inches → `ruler.horizontal` value starts "Inches, ticks every"; → Centimeters → "Centimeters"; → Pixels → "Pixels".
  - `testRulerCursorMatchesStatusBar`: open 400×300, rulers on, ⌘0; hover the canvas at (0.3, 0.6) normalized → parse x, y from `statusBar.cursor` ("x, y") → horizontal value ends ", cursor <x>", vertical ", cursor <y>"; hover a ruler (outside the canvas) → neither value contains "cursor".
  - `testRulerStepFollowsZoom`: open 400×300, rulers on, ⌘0 → read step A from the value; ⌘= until "3200%" → step B; assert B < A and both in {1, 2, 5}×10^k.
  - `testRulerHighlightsSelection`: rulers on, launch with `-UITestSelectRect 10,10,50,40` (0013 hook) — assert the rulers exist and the app stays up; the highlight itself is checked by `RulerLayoutTests.highlight*` and manual 4.
  - `testTogglesPersistAcrossRelaunch`: turn both on, terminate, relaunch `resetDefaults: false` → rulers exist, `canvas.pixelGrid` ≠ "off"; terminate, relaunch with `resetDefaults: true` → rulers absent, grid "off".
  - `testRulersMatchCatalog`: rulers and grid on; for `ruler.horizontal`, `ruler.vertical`, `canvas.pixelGrid`: element type/label as the dumped catalog (0049 `UITestApp.loadCatalog()`), value matches the format regex; 0049's `testNoUncataloguedOrUnlabelledControls` for the document window still passes with rulers shown.
  - `testTogglesApplyToAllWindows`: two fixtures; ⌥⌘R in one → both windows' `ruler.horizontal` exist.
- **Performance (NF-1):** `PaintDotMacTests/Performance/PixelGridPerformanceTests.swift` (XCTest `measure`): `PixelGrid.lines` + `flags` for a 6016×3384 drawable at zoom 2 (≈ 4 700 lines) and `RulerLayout.ticks` for a 3000-pt ruler — gate at 5 ms each (gross regression); report the numbers in Verification status. The grid adds no texture work, so 0048's NF-1 paint/pan frame-time tests are re-run unchanged with the grid on (`settings.showPixelGrid = YES` launch argument via `-settings.showPixelGrid YES` user-defaults argument) and must stay within their targets; report the numbers.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build with no warnings, all tests pass with none skipped, UI tests ran, launch smoke passes.
- **Manual verification** (look and feel can't be asserted by accessibility):
  1. Open a photo on a Retina display, turn on View > Pixel Grid, zoom to 200 %, 400 %, 1600 %, and a pinch-zoom like 270 %: lines are one device pixel, perfectly sharp, exactly between pixels, never blurry or doubled; no outer border line. At 150 % no grid. Repeat on a 1× external display (move the window).
  2. Paint black, white, mid-gray (#808080 and #7F7F7F), red, and fully transparent areas; the grid stays visible over all of them (dark lines on light pixels, light lines on dark pixels) and over both checkerboard squares.
  3. Switch Light/Dark and enable Increase Contrast: rulers follow the appearance and stay legible; the grid lines become fully opaque with Increase Contrast; the image and checkerboard are unchanged.
  4. Turn on Rulers: 0 sits exactly at the image's top-left corner in both rulers, values are negative outside; switch units px/in/cm in the status bar and the numbers change accordingly (96-DPI image: 1 in = 96 px); a selection's extent is highlighted on both rulers; the pointer marker tracks smoothly while moving and dragging.
  5. Pan and pinch-zoom with rulers and grid on: rulers and grid move in lockstep with the image with no lag or shimmer; labels never overlap.
  6. Toggle ⌥⌘R while dragging a brush stroke: no crash; the stroke finishes normally.
  7. VoiceOver: the rulers announce "Horizontal Ruler"/"Vertical Ruler" with unit, step, and cursor.

## Open questions

Recommended answers are applied throughout the spec; confirm or change them before implementation, and record the decision in PRD §5.2 CAN-5, §5.12, and §12.

1. **Pixel Grid shortcut.** Paint.NET's current docs (ViewMenu, Toolbar, KeyboardMouseCommands pages) list **no** shortcut for Pixel Grid (the planning brief's "Ctrl + '" could not be verified in the docs). *Recommended (applied): ⌘' (Photoshop's Show Grid; free in 0045's table and not macOS-reserved).*
2. **Rulers shortcut.** Paint.NET's docs list no shortcut for Rulers either; the commonly assumed Ctrl + R is Paint.NET's Resize Image, which PaintDotMac maps to ⌘R (PRD §5.12). *Recommended (applied): ⌥⌘R (free in the table, not reserved; Photoshop-style ⌘R is taken by Resize…).* Alternative: no shortcut.
3. **Scope and persistence of the toggles.** PRD is silent. *Recommended (applied): app-wide (all windows follow, like the unit in APP-5), persisted in `settings.showPixelGrid` / `settings.showRulers`, both default off (Paint.NET's default), toggled only from the View menu (not in the Settings window).*
4. **Grid look and threshold.** Paint.NET says only "not visible below 200 %". *Recommended (applied): visible at zoom ≥ 200 % as defined by CAN-6 (device pixels per image pixel, so on Retina 200 % = one image pixel per point); interior lines only (no line on the image's outer edges); exactly one device pixel; color per pixel black or white chosen by Rec. 709 luminance of what is underneath (threshold 127.5), at 50 % opacity, 100 % with Increase Contrast.*
5. **Ruler details.** Paint.NET's docs give no metrics. *Recommended (applied): 20 pt thick with a corner square; 1-2-5 major steps at least 64 pt apart, minor ticks (10/4/5 per major, whole pixels only in px), medium ticks at half; bare numeric labels without a unit suffix, negative values outside the image, vertical labels rotated to read bottom-to-top; a 1-device-pixel pointer marker in the accent color; the selection's bounding range highlighted (Paint.NET's documented behavior); clicking a ruler does nothing (no guides).*

## Out of scope

- Units of Measurement items in the View menu (Paint.NET has three checkboxes there); the unit stays in 0004's status-bar popup (APP-5) and 0046's Settings default.
- Guides dragged out of rulers, a configurable grid size/color, snapping to the grid — not in the PRD.
- Toolbar toggle buttons for grid/rulers (Paint.NET has them in its toolbar; PaintDotMac has no main toolbar in v1.x).
- Docked panels and any window-layout change outside the canvas area → **0052** (the rulers belong to the canvas area and move with it).
- Scroll bars (none in v1.0, CAN-6).
