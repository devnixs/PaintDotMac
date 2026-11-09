# 0034 — Add Curves (⇧⌘M) with Luminosity and RGB transfer maps and an interactive curve editor

> Source: PRD.md §5.8 (ADJ-4 "Curves (luminosity and RGB)", P0; shared rule "All adjustments (P0): apply to the active layer and selection, show a live canvas preview while the dialog is open, and support Cancel and 'Repeat last' (⌘F)"), §5.9 FX-A, FX-B, FX-C, FX-D, FX-E, §5.12 (row "Hue/Saturation / Levels / Curves — Ctrl+Shift+U / Ctrl+L / Ctrl+Shift+M — ⇧⌘U / ⌘L / ⇧⌘M"), §12 D-22; AGENTS.md architecture rules 1, 2, 4, 5, 7, 8.
> Paint.NET docs (fetched 2026-11-07; `getpaint.net/doc/latest/Curves.html` redirects to https://paint.net/doc/latest/Curves.html): Luminosity is the default mode; to edit colors "select "RGB" from the drop-down list at the top of the dialog"; in RGB mode the Red, Green and Blue channels are edited individually or together through the checkboxes at the bottom of the dialog; "Control points are added by clicking anywhere on the curve where no Control point exists."; points are moved by dragging and the curve stays continuous through every point; "Control points are removed by right-clicking on the point."; the horizontal axis is "the intensity input", the vertical axis "the intensity output"; shortcut "Ctrl + Shift + M". The page lists no numeric ranges, presets or limits, so everything below comes from Paint.NET's source (FX-E fallback).
> Paint.NET 3.36 source (mirror https://github.com/rivy/OpenPDN, the same mirror 0032/0033 cite): `src/Effects/CurvesEffect.cs`, `src/Effects/CurvesEffectConfigToken.cs` (`MakeUop`, default token), `src/Effects/CurvesEffectConfigDialog.cs`, `src/Core/CurveControl.cs` (mouse handling, drawing), `src/Core/CurveControlLuminosity.cs`, `src/Core/CurveControlRgb.cs`, `src/Core/SplineInterpolator.cs`, `src/Core/UnaryPixelOps.cs` (`LuminosityCurve`, `ChannelCurve`), `src/Core/ColorBgra.cs` (`GetIntensityByte`, `FromBgraClamped`), `src/Core/Utility.cs` (`ClampToByte(double)`), `src/Menus/AdjustmentsMenu.cs` (Ctrl+Shift+M), `src/Strings/Strings.resx` ("Curves", "Transfer Map", "Luminosity", "RGB", "Red", "Green", "Blue", "&Reset", "Tip: Right-click to remove control points.", "({0}, {1})"). All formulas and interaction rules below are transcribed from these files.
> Milestone: M4
> Depends on: 0033-levels-and-auto-level (custom schema kind pattern `.levels`, `EffectPreparation`/`prepare` hook, custom dialog control in `UI/EffectControls/`), and through it 0032 (`ChannelLookupTable` + `channelLookup` kernel, `BlackAndWhite.intensity`), 0031 (effect framework), 0024 (`GoldenImage`), 0013 (selection), 0008 (history).

## Context

No application code exists yet; the names below are the ones the earlier specs fix.

- **0031** (effect framework): `ImageEffect` (`id`, `name`, `category`, `parameters`, `shortcut: EffectShortcut?`, `historyIcon`, `alphaMode`, `inputPadding(for:)`, `makeOutput(input:values:context:)`; `menuTitle` = `name + "…"` when it has parameters), `EffectParameter` (`Kind` with `integer/double/bool/choice/color/angle/seed`; its comment reserves "0034 adds `.curve` (with their own value cases and dialog controls)"), `EffectParameterValue`, `EffectParameterValues` (typed getters, `setting(_:to:schema:)`, `normalized(for:)`), `EffectParameterText.format/parse`, `EffectSchemaValidator`, `EffectRegistry.standard` (Adjustments sorted by name), `EffectParameterMemory` (in-session, remembered on OK only; shared Repeat slot), `EffectMaskBlend` (FX-D), `CoreImageBridge` (color management off: kernels see the 8-bit encoded values as `k/255`), `EffectRenderContext` (`ciRect`, `colorKernel(_:)`, `kernel(_:)`), `Core/Rendering/Shaders/EffectKernels.metal` (stitchable CI kernels), `EffectRunner`, `Document/EffectSessionController.swift` (`update(_:to:)`, preview via `updateLiveState`, one `TileDiffHistoryItem` named `effect.name` on OK, exact restore on Cancel), `UI/EffectDialogView.swift` + `EffectDialogModel` (`effectDialog`, `effectDialog.<id>`, `effectDialog.progress` "rendering"/"idle", `effectDialog.ok`, `effectDialog.cancel`), Adjustments menu built from the registry (`menu.adjustments.<id>`), Effects ▸ Repeat ⌘F. Test support: `PaintDotMacTests/Effects/Reference/` + `ReferenceEffectRenderer`, `GoldenImage.compare` (±1), `SeededRandom`, `TestImages`, `UITestApp`, `UITestFixtures.writePNG`, `-UITestSelectRect`.
- **0032**: `EffectParameterEditor` (every `EffectSessionController.update(_:to:)` goes through it, so `.curve` values are normalized by item 3's rule on every path; Curves keeps the default `ImageEffect.parameterRules == []`), `ChannelLookupTable` (`red/green/blue: [UInt8]` × 256, `identity`, `isIdentity`, `apply(_ c: ColorRGBA8)`, `makeImage() -> CIImage` = 256×1 RGBA8 nearest-sampled, `apply(to:context:)` with the `channelLookup` general kernel), `BlackAndWhite.intensity(r:g:b:)` = Paint.NET `GetIntensityByte` `(7471·B + 38470·G + 19595·R) >> 16`, and the `blackAndWhite` kernel's integer intensity expression.
- **0033**: the custom-kind pattern this spec follows exactly for `.curve`: `EffectParameter.Kind.levels(defaultValue:)` + `EffectParameterValue.levels(_)` + typed getter `levels(_:)` (missing/mistyped → `assertionFailure` + identity), normalization through the value's own `normalized()`, `EffectParameterText.format` → `""` / `parse` → `nil`, validator check "default == default.normalized()", `EffectDialogView` renders the kind's control full-width without the `"<label>:"` row label, `EffectDialogModel` forwards control edits as `update(id, to: .levels(new))`; the dialog control's logic lives in a pure Core value type (`LevelsEditor`) and the SwiftUI control in `UI/EffectControls/LevelsControl.swift` only renders and forwards; channel-mask checkboxes are view state, all ticked each time the dialog opens, not part of the value. 0033 also adds `ImageEffect.prepare(values:source:selection:) -> EffectPreparation` (`.render(values)` / `.noChange`), called by `EffectRunner` before the first chunk. 0033 uses 0032's `ChannelLookupTable` for Levels (`LevelsMapping.lut(for:)`) and adds no kernel. `EffectRegistry.standard` after 0033 = `[InvertColors(), BrightnessContrast(), BlackAndWhite(), HueSaturation(), Posterize(), Sepia(), Levels(), AutoLevel()]`.
- Adjustments menu after 0033: "Auto-Level", "Black and White", "Brightness / Contrast…", "Hue / Saturation…", "Invert Colors", "Levels…", "Posterize…", "Sepia".

**Paint.NET behavior mirrored (3.36 source, verified):**

| Aspect | Paint.NET 3.36 |
|---|---|
| Name / menu / shortcut | `CurvesEffect.Name` "Curves", category Adjustment, configurable ("Curves…"), Ctrl+Shift+M |
| Default | mode **Luminosity**, one curve with control points (0,0) and (255,255) (identity) |
| Modes | `ColorTransferMode.Luminosity` ("Luminosity": one curve), `ColorTransferMode.Rgb` ("RGB": Red, Green, Blue curves) |
| Points | per channel a `SortedList<int,int>`: integer x 0…255 unique and sorted, integer y 0…255; endpoints x = 0 and x = 255 always exist and can't be removed |
| Curve | natural cubic spline (`SplineInterpolator`, Numerical Recipes §3.3) through the points, evaluated at x = 0…255 in `double`, then `ClampToByte(double)` (> 255 → 255, < 0 → 0, else **truncate**) |
| Luminosity apply | `LuminosityCurve`: `lumi = GetIntensityByte`, `diff = Curve[lumi] − lumi`, each of R, G, B `+= diff` clamped to 0…255, alpha kept (a shift, not a rescale) |
| RGB apply | `ChannelCurve`: `(CurveR[R], CurveG[G], CurveB[B], A)` |
| Dialog | header "Transfer Map", mode drop-down, coordinates label "(x, y)", 256×256 plot, channel checkboxes (Luminosity: one checkbox, checked and disabled; RGB: Red, Green, Blue, all checked initially), help text "Tip: Right-click to remove control points.", buttons Reset, OK, Cancel |

## User story

As a Paint.NET switcher, I press ⇧⌘M and the Curves dialog shows a diagonal line on a grid. I click on the line to add a point and drag it up: the canvas brightens the mid-tones live. I right-click a point to remove it, or press Reset to start over. I switch the drop-down to RGB, untick Green and Blue, and bend only the red curve. OK records one "Curves" step that ⌘Z undoes; ⌘F repeats it; Cancel restores my image exactly. With a selection active, only the selected pixels change, with soft edges.

## Scope & changes

Cross-cutting rules (unchanged from 0031): every pixel change goes through `EffectSessionController` → `UndoBridge`; `Core` imports no AppKit/SwiftUI; straight 8-bit sRGB, math on encoded values; GPU rendering through `CoreImageBridge` with a CPU oracle in the test target (±1, expected 0); one schema-generated dialog — the `.curve` kind gets its own control, as 0031 foresaw and 0033 did for `.levels`, still no per-effect dialog (AGENTS rule 5); rendering off the main actor, cancellable, chunked.

### Core (pure, headless, unit-tested)

1. **`Core/Effects/CurveSpline.swift`** (new) — the point model and Paint.NET's spline.
   ```swift
   public struct CurvePoint: Hashable, Sendable {
       public var x: Int      // input 0…255
       public var y: Int      // output 0…255
       public init(x: Int, y: Int)
   }
   /// One channel's control points: x strictly increasing, unique, first x == 0, last x == 255, every y in 0…255, 2…256 points.
   public struct CurvePoints: Hashable, Sendable {
       public private(set) var points: [CurvePoint]
       public static let identity: CurvePoints                       // [(0,0), (255,255)]
       public init(normalizing points: [CurvePoint])                 // see "Normalization" below
       public func index(ofX x: Int) -> Int?                          // SortedList.IndexOfKey
       public mutating func set(x: Int, y: Int)                       // SortedList indexer: insert or replace the point at x (x, y clamped to 0…255)
       public mutating func remove(at index: Int)                     // precondition: 0 < points[index].x < 255 (endpoints are never removed)
       public var transferTable: [UInt8]                              // 256 entries, CurveSpline(points).transferTable()
       public var isIdentityTable: Bool                               // transferTable[i] == i for every i
   }
   public struct CurveSpline: Sendable {
       public init(_ points: CurvePoints)                             // PreCompute (below)
       public let secondDerivatives: [Double]                         // y2
       public func value(at x: Double) -> Double                      // Interpolate (below)
       public func transferTable() -> [UInt8]                         // [clampToByte(value(at: Double(i))) for i in 0…255]
       public static func clampToByte(_ v: Double) -> UInt8           // v > 255 → 255; v < 0 → 0; else UInt8(v) (truncation); NaN → 0
   }
   ```
   **Normalization (`CurvePoints.init(normalizing:)`, also the `.curve` parameter normalization):** clamp every x and y to 0…255; for duplicate x keep the **last** occurrence (SortedList assignment semantics); sort by x; if x = 0 is missing insert (0, 0); if x = 255 is missing insert (255, 255). Result always satisfies the invariants (≤ 256 points follows from unique integer x).
   **`PreCompute` (transcribed; `xa`/`ya` = the points as `Double`, `n` = count ≥ 2):**
   ```
   u[0] = 0; y2[0] = 0
   for i in 1 ..< n−1 {
       wx = xa[i+1] − xa[i−1]
       sig = (xa[i] − xa[i−1]) / wx
       p = sig · y2[i−1] + 2.0
       y2[i] = (sig − 1.0) / p
       ddydx = (ya[i+1] − ya[i]) / (xa[i+1] − xa[i]) − (ya[i] − ya[i−1]) / (xa[i] − xa[i−1])
       u[i] = (6.0 · ddydx / wx − sig · u[i−1]) / p
   }
   y2[n−1] = 0
   for i in stride(from: n−2, through: 0, by: −1) { y2[i] = y2[i] · y2[i+1] + u[i] }
   ```
   (Natural spline: second derivative 0 at both ends. With n = 2 the first loop doesn't run and the curve is the straight line through the endpoints.)
   **`Interpolate(x)` (transcribed):** bisection `klo = 0, khi = n−1; while khi − klo > 1 { k = (khi + klo) >> 1; if xa[k] > x { khi = k } else { klo = k } }`; `h = xa[khi] − xa[klo]`, `a = (xa[khi] − x) / h`, `b = (x − xa[klo]) / h`; return `a·ya[klo] + b·ya[khi] + ((a³ − a)·y2[klo] + (b³ − b)·y2[khi]) · (h·h) / 6.0` — written as `(a*a*a - a)` and `(b*b*b - b)` in `Double`, in exactly this operand order, so the results are bit-identical to the C#. At a control point `a` or `b` is exactly 0/1, so the table holds the point's y exactly.
   The table is built on the CPU in `Double` and uploaded as a lookup image, so the GPU never evaluates the spline (no `double` needed in Metal; GPU = CPU exactly).

2. **`Core/Effects/Adjustments/Curves.swift`** (new) — the value type and the effect.
   ```swift
   public enum CurveMode: String, CaseIterable, Sendable { case luminosity, rgb
       public var title: String          // "Luminosity", "RGB" (Strings.resx ColorTransferMode.*)
       public var channels: [CurveChannel]   // luminosity → [.luminosity]; rgb → [.red, .green, .blue]
   }
   public enum CurveChannel: String, CaseIterable, Sendable { case luminosity, red, green, blue
       public var title: String          // "Luminosity", "Red", "Green", "Blue"
   }
   public struct CurvesValue: Hashable, Sendable {
       public var mode: CurveMode
       public var luminosity: CurvePoints
       public var red: CurvePoints
       public var green: CurvePoints
       public var blue: CurvePoints
       public static let identity: CurvesValue        // .luminosity, all four CurvePoints.identity
       public subscript(channel: CurveChannel) -> CurvePoints { get set }
       public func normalized() -> CurvesValue          // re-normalizes each CurvePoints (init(normalizing:))
       public var isIdentity: Bool                      // every channel of the ACTIVE mode has an identity transfer table
       public mutating func reset(mode: CurveMode)      // ResetControlPoints: every channel of that mode → .identity (mask ignored, as 3.36)
   }
   public enum CurvesTransfer: Equatable, Sendable {
       case luminosity([UInt8])                         // 256 entries
       case rgb(ChannelLookupTable)                     // 0032
   }
   public struct Curves: ImageEffect { … }
   ```
   - `Curves`: `id "curves"`, `name "Curves"` (menu "Curves…", history step "Curves", icon `.adjustment`), `.adjustment`, `shortcut EffectShortcut(key: "m", modifiers: [.command, .shift])` (PRD §5.12), `alphaMode .straight`, `inputPadding 0`, parameters `[EffectParameter(id: "curve", label: "Transfer Map", kind: .curve(defaultValue: .identity))]`.
   - `public static func transfer(for value: CurvesValue) -> CurvesTransfer` — `MakeUop`: Luminosity → `.luminosity(value.luminosity.transferTable)`; RGB → `.rgb(ChannelLookupTable(red: value.red.transferTable, green: value.green.transferTable, blue: value.blue.transferTable))`. Only the active mode's curves are used; the other mode's points are carried along untouched (*Open questions* 2).
   - `public static func applyLuminosity(_ table: [UInt8], to c: ColorRGBA8) -> ColorRGBA8` — `LuminosityCurve.Apply`: `I = BlackAndWhite.intensity(r:g:b:)`; `diff = Int(table[I]) − I`; `(clamp(R + diff), clamp(G + diff), clamp(B + diff), A)` with `clamp` to 0…255 (`FromBgraClamped`). CPU convenience used by tests and docs; the GPU kernel inlines the same integer math.
   - `prepare(values:source:selection:)` (0033 hook): `values.curve("curve").isIdentity` → `.noChange` (the result would be byte-identical; skips the render); else `.render(values)`.
   - `makeOutput`: switch `transfer(for: values.curve("curve"))`:
     - `.rgb(lut)` → `try lut.apply(to: input, context: context)` (0032's `channelLookup` kernel, unchanged).
     - `.luminosity(table)` → `try context.kernel("luminosityCurve").apply(extent: context.ciRect(context.outputRect), roiCallback: { index, rect in index == 0 ? rect : CGRect(x: 0, y: 0, width: 256, height: 1) }, arguments: [input, ChannelLookupTable(red: table, green: table, blue: table).makeImage()])`; a nil result → `EffectError.renderFailed`.
   - Color under alpha 0 is transformed like any other color (0031 *Open questions* 4): Luminosity with an inverted curve maps `(0,0,0,0)` to `(255,255,255,0)` and allocates those tiles; curves with `table[0] == 0` keep unallocated tiles unallocated (all-zero output tiles stay `nil`, 0031 item 8).

3. **`Core/Effects/EffectParameter.swift`** (extend 0031/0033, same pattern as `.levels`):
   - `EffectParameter.Kind.curve(defaultValue: CurvesValue = .identity)`; `EffectParameterValue.curve(CurvesValue)`; typed getter `public func curve(_ id: String) -> CurvesValue` (missing/mistyped → `assertionFailure` + `.identity`).
   - Normalization: `.curve(v)` → `.curve(v.normalized())`; a wrong-case value → the default.
   - `EffectParameterText.format` returns `""` and `parse` returns `nil` for `.curve`.
   - `EffectSchemaValidator`: a `.curve` default must equal `default.normalized()`.

4. **`Core/Effects/CurveEditor.swift`** (new) — the curve control's interaction logic as a pure value type, a transcription of `CurveControl.OnMouseDown/OnMouseMove/OnMouseUp/OnMouseLeave` + `CurvesEffectConfigDialog`'s mask/reset/mode handling. All coordinates are **curve units** (x, y in 0…255); the SwiftUI control converts view points with `curvePoint(forView:size:)`.
   ```swift
   public enum CurveMouseButton: Sendable { case primary, secondary }   // secondary = right-click or Control-click
   public struct CurveEditor: Equatable, Sendable {
       public init(value: CurvesValue)                    // value.normalized(); masks all true; nothing hovered; coordinates nil
       public private(set) var value: CurvesValue
       public var mode: CurveMode { get }
       public mutating func setMode(_ mode: CurveMode)    // value.mode = mode; clears hover; each mode keeps its own mask (3.36 keeps one control per mode)
       public func isMasked(_ channel: CurveChannel) -> Bool
       public func isMaskEditable(_ channel: CurveChannel) -> Bool   // false for .luminosity (checkbox checked and disabled)
       public mutating func setMasked(_ channel: CurveChannel, _ on: Bool)   // ignored for .luminosity
       public mutating func reset()                       // value.reset(mode: mode); hover cleared
       public private(set) var hoveredPointIndex: [CurveChannel: Int]  // pointsNearMousePerChannel (drawing: larger white-filled point)
       public private(set) var coordinates: CurvePoint?   // lastKey/lastValue for the "(x, y)" label; nil after exit
       public var coordinatesText: String                 // "(\(x), \(y))" or "" (Strings.resx "({0}, {1})")
       public var isTracking: Bool { get }
       public static func curvePoint(forView p: CGPoint, size: CGSize) -> CurvePoint   // view y-down, top-left origin
       public mutating func mouseMoved(to p: CurvePoint)  // hover (not tracking)
       public mutating func mouseDown(at p: CurvePoint, button: CurveMouseButton)
       public mutating func mouseDragged(to p: CurvePoint)
       public mutating func mouseUp(button: CurveMouseButton)
       public mutating func mouseExited()
       public var accessibilityValue: String              // e.g. "Luminosity: (0, 0), (128, 192), (255, 255)"; RGB: "Red: …; Green: …; Blue: …" (only the active mode's channels)
   }
   ```
   **View → curve mapping (`OnMouseMove`'s `mx`/`my`):** `x = Int(clamp(0.5 + p.x · 255 / (w − 1), 0, 255))`, `y = Int(clamp(0.5 + 255 − p.y · 255 / (h − 1), 0, 255))` in `Double` (truncation after the clamp; `w`, `h` = plot size, both ≥ 2).
   **Private state** (per active mode's channels `C`): `tracking = false`, `lastKey = −1`, `lastValue = −1`, `ptSave: [CurveChannel: CurvePoint?]`, `effectChannel: [CurveChannel: Bool]`, `hovered: [CurveChannel: Int?]`.
   **Hover (`mouseMoved`, and the non-tracking branch of every move):** for each channel `c` of the mode: if masked, `hovered[c]` = the index `i` with the smallest `(x_i − p.x)² + (y_i − p.y)²` among those `< 30` (strict; the first index wins a tie), else nil. Then `lastKey = p.x`, `lastValue = p.y`, `coordinates = p`.
   **`mouseDown(at p, button)`:** first run Hover at `p` (a pure model has no implicit preceding mouse-move; with a real mouse WinForms always delivers one, so this is equivalent). Then `ptSave[c] = nil` for all `c`; `tracking = (button == .primary)`; `lastKey = p.x`; `anyNear = false`; for each `c`: `hasPoint = hovered[c] != nil`; `effectChannel[c] = hasPoint`; `anyNear = anyNear || hasPoint`; if `masked(c) && hasPoint && 0 < key && key < 255` (key = that point's x) → `points[c].remove(at: hovered[c])`. If `!anyNear` → `effectChannel[c] = true` for all `c`. Then run **Move** at `p`. (So: a secondary click on a point removes it and adds nothing; a primary click near a point removes it and re-adds it at the click position, i.e. the point jumps under the pointer; a primary click away from every point adds a point at the click position — not snapped onto the curve — in every masked channel.)
   **Move (`mouseDragged`, or after `mouseDown`):** if `!tracking` → Hover and return. Else for each channel `c` with `masked(c) && effectChannel[c]` (others: `hovered[c] = nil`, untouched):
   ```
   lastIndex = points[c].index(ofX: lastKey)
   if let s = ptSave[c], s.x != p.x {            // dragged away from a point we were covering: put it back
       points[c].set(x: s.x, y: s.y); ptSave[c] = nil
   } else if 0 < lastKey && lastKey < 255 && lastIndex != nil && p.x != lastKey {
       points[c].remove(at: lastIndex!)           // leave the old x (endpoints never move horizontally)
   }
   if let oldIndex = points[c].index(ofX: p.x), p.x != lastKey {
       ptSave[c] = points[c].points[oldIndex]     // dragging onto an existing point: remember it in case we drag on
   }
   points[c].set(x: p.x, y: p.y)                  // p.x, p.y already in 0…255
   hovered[c] = points[c].index(ofX: p.x)
   ```
   then `lastKey = p.x`, `lastValue = p.y`, `coordinates = p`. (Consequences, all Paint.NET's: a point dragged over a neighbour's x temporarily replaces it and the neighbour comes back when the drag moves on; releasing on a neighbour's x keeps only the dragged point; dragging past the plot edge clamps to x/y 0 or 255, so a point dropped on x = 0 or 255 merges into that endpoint, giving it its y; dragging an endpoint vertically moves it, dragging it sideways leaves it in place and drags a new point out of it.)
   **`mouseUp(button)`:** if `button == .primary && tracking` → `tracking = false`, `lastKey = −1`. `coordinates` keeps its last value.
   **`mouseExited`:** `lastKey = −1`, `lastValue = −1`, `coordinates = nil`; hover unchanged.
   **`setMode` / `setMasked` / `reset`:** never touch `tracking` state beyond clearing hover; the control ignores them while `isTracking` (the checkboxes and buttons can't be clicked during a drag anyway).
   The editor never produces an invalid `CurvePoints` (every mutation goes through `set`/`remove`, which keep the invariants); a Debug `assert(value == value.normalized())` after each event documents it.

5. **`Core/Rendering/Shaders/EffectKernels.metal`** (extend 0031/0032) — one general stitchable kernel:
   ```metal
   [[stitchable]] float4 luminosityCurve(coreimage::sampler src, coreimage::sampler lut, coreimage::destination dest)
   ```
   `float4 s = src.sample(src.transform(dest.coord()))`; `int r = clamp(int(rint(s.r * 255)), 0, 255)` (same for g, b); `int i = (7471 * b + 38470 * g + 19595 * r) >> 16` (non-negative, exact); `int t = int(rint(lut.sample(lut.transform(float2(float(i) + 0.5, 0.5))).r * 255))`; `int d = t − i`; return `float4(float(clamp(r + d, 0, 255)) / 255, float(clamp(g + d, 0, 255)) / 255, float(clamp(b + d, 0, 255)) / 255, s.a)`. The `CoreImageBridge` kernel-name list gains `luminosityCurve`; `CoreImageBridgeTests.kernelsLoad` checks it.

6. **`Core/Effects/EffectRegistry.swift`** (extend): `standard` appends `Curves()` (ids `["invertColors","brightnessContrast","blackAndWhite","hueSaturation","posterize","sepia","levels","autoLevel","curves"]`). `adjustments.map(\.name)` = `["Auto-Level", "Black and White", "Brightness / Contrast", "Curves", "Hue / Saturation", "Invert Colors", "Levels", "Posterize", "Sepia"]`.

### Platform glue (covered by integration and UI tests)

7. **`UI/EffectDialogView.swift`** (extend 0031/0033): a `.curve` parameter renders `CurveEditorControl` full-width without the `"<label>:"` row label (the label "Transfer Map" is the control's section header and accessibility label). `EffectDialogModel` owns a `CurveEditor` for that parameter, created from the session's initial value when the dialog opens; after every editor event whose `value` changed it forwards `update("curve", to: .curve(editor.value))`. No other dialog change.

8. **`UI/EffectControls/CurveEditorControl.swift`** (new, SwiftUI; rendering and event forwarding only — every decision is in `CurveEditor`). Root identifier `effectDialog.curve`. Layout, top to bottom (Paint.NET's):
   - Header **"Transfer Map"**.
   - Row: pop-up **mode** `effectDialog.curve.mode` with items "Luminosity", "RGB" → `setMode`; on the right the coordinates label `effectDialog.curve.coordinates` (text and accessibility value = `coordinatesText`).
   - **Plot** `effectDialog.curve.plot`: exactly **256 × 256 pt** (integer-aligned frame inside a 1-pt border, so view points map 1:1 to curve units through `curvePoint(forView:size:)`), drawn with `Canvas`: background `controlBackgroundColor`; dashed grid lines at ¼, ½, ¾ and the dashed diagonal from bottom-left to top-right (label color at 50 % alpha); crosshair guide lines through the pointer while hovering (label color at ~38 % alpha); for each channel of the active mode its curve as a polyline through `(i, clamp(255 − spline.value(at: i), 0, 255))` for i 0…255, colored label color (Luminosity, so it works in dark mode) / red / green / blue at 50 % alpha, line width 2 when masked else 1; each control point as a circle of radius 4 (hovered, white fill), 3 (masked) or 2 (not masked). Input handling: `onContinuousHover` → `mouseMoved`/`mouseExited`; a `DragGesture(minimumDistance: 0)` → `mouseDown(button: .primary)` on start, `mouseDragged` on change, `mouseUp` on end; right-click and Control-click (an `NSViewRepresentable` event catcher or `.onTapGesture` with `.secondary` handling, whichever works on macOS 15) → `mouseDown(button: .secondary)` + `mouseUp(button: .secondary)`. Accessibility: element `effectDialog.curve.plot`, label "Transfer Map", value `editor.accessibilityValue`.
   - Checkbox row: Luminosity mode → one checkbox **"Luminosity"** `effectDialog.curve.luminosity`, checked and disabled; RGB mode → **"Red"** `effectDialog.curve.red`, **"Green"** `effectDialog.curve.green`, **"Blue"** `effectDialog.curve.blue` → `setMasked`. All ticked each time the dialog opens (view state, not remembered).
   - Help text `effectDialog.curve.help`: **"Tip: Right-click or Control-click to remove control points."** (Paint.NET's "Tip: Right-click to remove control points." plus the Mac secondary-click gesture; *Open questions* 1).
   - Button **"Reset"** `effectDialog.curve.reset` → `reset()`. (0031's OK/Cancel stay the dialog's own buttons, to the right of Reset on the same bottom row if the generated layout allows, otherwise Reset sits at the end of the control.)

9. **`Document/EffectSessionController.swift`**: no change (the `.curve` value flows through `update(_:to:)` → 0032's `EffectParameterEditor` → `EffectParameterValues` normalization, and 0033's `prepare`).

10. **`App/MainMenu.swift`**: no code change — the Adjustments menu gains "Curves… ⇧⌘M" (`menu.adjustments.curves`) between "Brightness / Contrast…" and "Hue / Saturation…". Curves runs through 0031's `DocumentWindowController.runEffect(_:)` / `repeatLastEffect(_:)` (guards: no gesture in progress, `!undoBridge.isBusy`, no sheet attached; then `undoBridge.prepareForNavigation?()` with reason `.command` first), so there is no new command path. `MainMenuTests.noDuplicateShortcuts` must stay green (⇧⌘M is not used elsewhere; ⌘M is the reserved Minimize, ⌘E is Merge Layer Down).

11. **`project.yml`**: no change (new files are picked up by the source globs; the kernel lives in the existing `EffectKernels.metal`). Run `xcodegen generate`.

No PRD change in this spec; the open questions below record the decisions applied.

## Acceptance criteria

- [ ] ADJ-4 Luminosity: with the default mode, each pixel is shifted by `Curve[I] − I` (I = `GetIntensityByte`), clamped, alpha unchanged; the curve is Paint.NET's natural cubic spline, truncated to bytes and clamped to 0…255. → `CurveSplineTests.*`, `CurvesTests.luminosityApply*`, `EffectGoldenTests.curvesLuminosityGrid`, `.curvesRandom`
- [ ] ADJ-4 RGB: in RGB mode each channel goes through its own curve, alpha unchanged. → `CurvesTests.rgbTransfer`, `EffectGoldenTests.curvesRGBGrid`
- [ ] The curve editor adds a point on click, moves it on drag, removes it on right-click/Control-click, keeps endpoints, keeps x strictly increasing and unique, never leaves 0…255, edits only ticked channels, and Reset restores the identity for the active mode. → `CurveEditorTests.*`, `CurvesUITests.testLuminosityClickOK`, `.testRightClickRemovesAndReset`, `.testDragPoint`, `.testRGBRedOnly`
- [ ] GPU output equals the CPU oracle within ±1 (expected 0 differences) for both modes, including alpha 0/partial alpha pixels and edge tiles. → `EffectGoldenTests.curves*`, `CoreImageBridgeTests.kernelsLoad`
- [ ] §5.8: live preview without a step; Cancel restores exactly; OK commits one "Curves" step (icon `.adjustment`); identity curves add no step; ⌘F repeats with the same curves and no dialog; values are remembered for the session. → `CurvesSessionIntegrationTests.*`, `CurvesUITests.testRepeat`, `.testCancelRestores`, `.testRememberedOnReopen`
- [ ] Undo/redo of a Curves step restores exact bytes. → `CurvesSessionIntegrationTests.undoRedo`, `CurvesUITests.testLuminosityClickOK`
- [ ] FX-D: with an antialiased selection only selected pixels change, blended by coverage; outside pixels byte-identical. → `CurvesSessionIntegrationTests.selectionClipped`, `EffectGoldenTests.curvesSelectionBlend`
- [ ] `.curve` is a schema kind with normalization, validation and its own dialog control; no Curves-specific dialog. → `CurvesTests.parameterKind*`, `EffectSchemaValidatorTests.curveDefaultMustBeNormalized`, `EffectSchemaValidatorTests.standardRegistryIsValid`
- [ ] Adjustments menu shows "Curves…" with ⇧⌘M at its alphabetical position; no duplicate shortcuts. → `MainMenuEffectsTests.adjustmentsIncludeCurves`, `MainMenuTests.noDuplicateShortcuts`, `CurvesUITests.testMenu`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Identity curves** (default, or after Reset, or a point placed exactly on the diagonal such as (128,128)): `prepare` → `.noChange`; OK adds no step (H-6) but sets Repeat's `lastApplied`. → `CurvesSessionIntegrationTests.identityAddsNoStep`, `CurvesTests.pointOnDiagonalIsIdentity`
- **Overshoot:** points that make the spline exceed 0…255 clamp (e.g. (0,0),(32,255),(64,0),(255,255) → 0 for x 64…218; the table is ≥ 1 again from x 219). → `CurveSplineTests.overshootClamps`
- **Truncation, not rounding:** 190.998 → 190. → `CurveSplineTests.threePoint`
- **Luminosity clamping:** `R + diff` beyond 0…255 clamps per channel, so hue shifts at the extremes exactly as Paint.NET. → `CurvesTests.luminosityApply`
- **Transparent pixels / unallocated tiles:** luminosity/RGB curves with `table[0] == 0` keep `(0,0,0,0)` and leave tiles unallocated; an inverted curve allocates them as `(255,255,255,0)` (0031 OQ 4). → `CurvesSessionIntegrationTests.sparseTiles`
- **Edge tiles** (257×257, 300×200) and 1×1 images: runner invariants hold; LUT index always 0…255. → golden fixtures 600×400 and 257×257
- **Editor limits:** 256 points maximum (unique integer x) — clicking every x fills the table without error; endpoints can't be removed by right-click or by dragging away; dragging outside the plot clamps; all channels unticked → clicks change nothing; Luminosity checkbox can't be unticked. → `CurveEditorTests.*`
- **Malformed values** (from code, never from the UI): duplicate x, out-of-range coordinates, missing endpoints → normalized as item 1. → `CurveSplineTests.normalization`
- **Mode switch mid-session** re-renders with the other mode's curves; switching back restores the earlier curves (both kept in the value). → `CurvesSessionIntegrationTests.modeSwitchRerenders`, `CurveEditorTests.modeSwitchKeepsCurves`
- **Rapid drags:** each changed editor value is forwarded; 0031's debounce/generation logic keeps only the final render. (Inherited; no new code path.)
- **Hidden active layer, floating pixels, busy document, cancellation, GPU failure:** inherited from 0031 unchanged. → `CurvesSessionIntegrationTests.pendingEditFinishedFirst`

## Test plan

Expected values come from Paint.NET's formulas (transcribed above) and hand calculation (shown); the few spline values were double-checked with an independent transcription of `SplineInterpolator` — never from running the code under test.

- **CPU oracle** (`PaintDotMacTests/Effects/Reference/CurvesReference.swift`): its own natural-cubic-spline transcription (written independently of `CurveSpline`: plain arrays, Numerical Recipes loops, `ClampToByte`), `table(points: [(Int, Int)]) -> [UInt8]`, and `apply(_ pixels: [ColorRGBA8], value: CurvesValue) -> [ColorRGBA8]` computing `LuminosityCurve`/`ChannelCurve` per pixel directly (its own intensity expression). `ReferenceEffectRenderer` (0031) gains Curves support through it.
- **Unit — `PaintDotMacTests/Effects/CurveSplineTests.swift`:**
  - `identity`: `CurvePoints.identity.transferTable[i] == i` for all i; `isIdentityTable`.
  - `twoPointLines`: (0,255),(255,0) → table[i] == 255 − i for all i; (0,0),(255,128) → [1] 0 (0.502), [2] 1, [128] 64 (64.251), [254] 127 (127.498), [255] 128.
  - `threePoint` (0,0),(128,192),(255,255): `secondDerivatives == [0, −3/254, 0]` (±1e-12; hand: sig = 128/255, p = 2, ddydx = 63/127 − 3/2 = −255/254, u₁ = 3·ddydx/255 = −3/254, back-substitution y2₁ = u₁). Closed form on [0,128]: S = 192b + (b − b³)·4096/127 with b = x/128; on [128,255]: S = 192a + 255b + (a − a³)·127/4 with a = (255 − x)/127, b = (x − 128)/127. Table: [1] 1 (1.752), [32] 55 (55.559), [64] 108 (96 + 1536/127 = 108.094), [88] 143 (143.69), [100] 159 (159.818), [124] 187 (187.92), [127] **190** (190.998 — truncation, not 191), [128] 192, [129] 192 (192.990), [160] 218, [192] 235 (235.622), [200] 238 (238.888), [224] 246, [254] 254 (254.754), [255] 255. `value(at: 64) == 96 + 1536/127` (±1e-9).
  - `fourPointS` (0,0),(64,32),(192,224),(255,255): y2 ≈ [0, 0.0235303, −0.0237160, 0] (±1e-6); table [16] 4, [32] 9, [50] 20, [64] 32, [96] 74, [100] 80, [124] 121, [128] 128 (128.190), [160] 182, [192] 224, [200] 231, [224] 245.
  - `overshootClamps` (0,0),(32,255),(64,0),(255,255): [8] 95, [16] 178, [24] 235, [32] 255, [40] 228, [48] 166, [56] 85, [64] 0, [80] 0 (−141.4), [128] 0 (−325.1), [200] 0 (−110.7), [240] 148, [255] 255.
  - `oneSidedOvershoot` (0,0),(64,192),(255,255): y2₁ = −6/191 (±1e-12); [100] 255 (256.80), [128] 255 (283.96), [200] 255 (287.30).
  - `knotsExact`: for 50 seeded random point sets (2…12 points), `table[x_i] == y_i` for every control point.
  - `clampToByte`: 255.5 → 255, 254.999 → 254, −0.001 → 0, 0.999 → 0, `.nan` → 0, `.infinity` → 255.
  - `normalization`: [(300,−5),(10,20),(10,30),(−4,7)] → [(0,7),(10,30),(255,0)]; [(100,50)] → [(0,0),(100,50),(255,255)]; [] → identity; `set(x: 300, y: −1)` → point (255,0); `remove(at:)` of an endpoint is a precondition failure (not tested; documented).
  - `matchesReference`: 200 seeded random point sets → `transferTable == CurvesReference.table` exactly.
- **Unit — `PaintDotMacTests/Effects/CurvesTests.swift`:**
  - `metadata`: id "curves", name "Curves", `menuTitle == "Curves…"`, category `.adjustment`, shortcut `m` + [.command, .shift], icon `.adjustment`, `.straight`, `inputPadding == 0`, one parameter id "curve" label "Transfer Map" kind `.curve(defaultValue: .identity)`.
  - `parameterKindNormalization`: `.curve` value with duplicate/out-of-range points normalizes; wrong-case value → `.identity`; `format == ""`, `parse == nil`; typed getter returns the value.
  - `luminosityApply` with the threePoint table: (200,100,50,255) → I 124, table 187, diff 63 → (255,163,113,255); (250,20,20,255) → I 88 (5,817,570 >> 16), table 143, diff 55 → (255,75,75,255); (128,128,128,255) → (192,192,192,255); (10,240,30,128) → I 147, table 208, diff 61 → (71,255,91,128); (0,0,0,0) → (0,0,0,0); (255,255,255,77) → (255,255,255,77).
  - `luminosityApplyInverted` ((0,255),(255,0)): (200,100,50,255) → I 124 → 131, diff 7 → (207,107,57,255); (250,20,20,255) → 167, diff 79 → (255,99,99,255); (0,0,0,0) → (255,255,255,0).
  - `luminosityApplyS` (fourPointS): (200,100,50,255) → table[124] 121, diff −3 → (197,97,47,255).
  - `rgbTransfer`: mode RGB, red = threePoint, green = inverted, blue = identity → `transfer` is `.rgb` with those tables; (200,100,50,255) → (238,155,50,255).
  - `inactiveModeIgnored`: mode Luminosity with non-identity red points → transfer `.luminosity(identity)`, `isIdentity == true`.
  - `pointOnDiagonalIsIdentity`: luminosity [(0,0),(128,128),(255,255)] → `isIdentity`.
  - `prepareNoChangeForIdentity` / `prepareRendersOtherwise`.
  - `resetMode`: reset(.rgb) leaves luminosity points untouched.
- **Unit — `PaintDotMacTests/Effects/CurveEditorTests.swift`** (hand traces of item 4; points written as (x,y) lists):
  - `viewMapping` (size 256×256): (0,0) → (0,255); (255,255) → (255,0); (128,63) → (128,192); (−5,300) → (0,0); (127.4,0) → (127,255); size 512×512: x 511 → 255, x 2 → 1 (0.5 + 510/511 = 1.498).
  - `hoverRadius` with (128,192): hover (131,196) (25) → hovered; (132,196) (32) → none; (133,192) (25) → hovered; (134,192) (36) → none; tie → lower index.
  - `clickAddsPoint`: identity; down primary (128,192), up → luminosity [(0,0),(128,192),(255,255)]; `coordinatesText == "(128, 192)"`.
  - `clickNearPointMovesIt`: then down (130,190) → [(0,0),(130,190),(255,255)].
  - `clickFarAddsPoint`: [(0,0),(128,192),(255,255)], click (64,32) → 4 points, sorted.
  - `dragMovesPoint`: down (128,192), drag (140,200), up → [(0,0),(140,200),(255,255)].
  - `dragAcrossNeighbourRestoresIt`: [(0,0),(100,100),(150,150),(255,255)]; down (100,100), drag (150,120) → [(0,0),(150,120),(255,255)]; drag (160,120) → [(0,0),(150,150),(160,120),(255,255)]; up.
  - `dropOntoNeighbourReplacesIt`: same start; down (100,100), drag (150,120), up → [(0,0),(150,120),(255,255)].
  - `dragOutsideMergesIntoEndpoint`: [(0,0),(128,192),(255,255)]; down (128,192), drag `curvePoint(forView: (−30, 155), size: 256²)` = (0,100) → [(0,100),(255,255)].
  - `endpointDragVertical`: identity; down (0,0), drag (0,40) → [(0,40),(255,255)].
  - `endpointDragSideways`: identity; down (0,0), drag (10,40) → [(0,0),(10,40),(255,255)]; drag (20,50) → [(0,0),(20,50),(255,255)].
  - `secondaryClickRemoves`: [(0,0),(128,192),(255,255)]; down secondary (127,190), up → identity, `isTracking == false`; a subsequent `mouseDragged` changes nothing.
  - `secondaryClickEndpointNoOp`: secondary at (0,0) and at (255,250) → unchanged. `secondaryClickEmptyNoOp`: at (60,200) → unchanged.
  - `maskLimitsChannels` (RGB, only red ticked): click (128,192) → red has 3 points, green/blue identity.
  - `nearPointOnlyEditsChannelsHavingIt` (RGB all ticked, red [(0,0),(128,192),(255,255)], green/blue identity): click (129,190) → red [(0,0),(129,190),(255,255)], green/blue identity; click (64,64) → each of red/green/blue gains (64,64).
  - `allUncheckedNoOp` (RGB, all unticked): click/drag/secondary → value unchanged.
  - `luminosityMaskFixed`: `setMasked(.luminosity, false)` → still masked; `isMaskEditable(.luminosity) == false`.
  - `resetActiveModeOnly` and `modeSwitchKeepsCurves` (luminosity edits survive RGB edits and back; masks per mode kept).
  - `mouseExitClearsCoordinates`: `coordinatesText == ""`.
  - `fillAllX`: click every x 0…255 at y 0 → 256 points, all invariants hold.
  - `accessibilityValue`: "Luminosity: (0, 0), (255, 255)"; RGB "Red: (0, 0), (255, 255); Green: …; Blue: …".
  - `invariantsProperty` (`SeededRandom`, 1,000 sequences × 50 events: random down/drag/up/secondary/hover/exit at curve points from random view points in −20…275, random mode/mask toggles and resets): after every event each channel has x strictly increasing, first x 0, last x 255, y in 0…255, count ≤ 256, and `value == value.normalized()`; seed printed on failure.
- **Unit — `PaintDotMacTests/Effects/EffectSchemaValidatorTests.swift`** (extend): `curveDefaultMustBeNormalized` (stub effect with a `.curve` default containing duplicate x → one problem); `standardRegistryIsValid` still passes with Curves.
- **Unit — `PaintDotMacTests/Effects/EffectRegistryTests.swift`** (update 0031/0032/0033's): `standardContents` = item 6's id list; `adjustmentsSortedByName` = item 6's name list.
- **Unit — `PaintDotMacTests/App/MainMenuEffectsTests.swift`** (extend): `adjustmentsIncludeCurves` — "Curves…" (`m`, ⇧⌘, `menu.adjustments.curves`, `representedObject` "curves") right after "Brightness / Contrast…"; **updates 0031/0032/0033's `adjustmentsItems`** to exactly `[("Auto-Level","l",[.command,.shift],"autoLevel"), ("Black and White","g",[.command,.shift],"blackAndWhite"), ("Brightness / Contrast…","",[],"brightnessContrast"), ("Curves…","m",[.command,.shift],"curves"), ("Hue / Saturation…","u",[.command,.shift],"hueSaturation"), ("Invert Colors","i",[.command,.shift],"invertColors"), ("Levels…","l",[.command],"levels"), ("Posterize…","p",[.command,.shift],"posterize"), ("Sepia","e",[.command,.shift],"sepia")]`; `MainMenuTests.noDuplicateShortcuts` passes. 0031's `EffectsUITests.testMenus`, 0032's `BasicAdjustmentsUITests.testMenus` and 0033's `LevelsUITests.testMenus` assert relative order only and need no change.
- **GPU — `PaintDotMacTests/Rendering/CoreImageBridgeTests.swift`** (extend): `kernelsLoad` includes `luminosityCurve`.
- **Golden — `PaintDotMacTests/Effects/EffectGoldenTests.swift`** (extend; GPU through `CoreImageBridge` + runner vs `CurvesReference`, `GoldenImage.compare` ±1, expected 0 differences, reported): fixture 600×400 seeded random straight RGBA (alpha from {0, 1, 77, 128, 254, 255}) and a 257×257 fixture: `curvesLuminosityGrid` (identity, threePoint, inverted, fourPointS, overshoot, oneSidedOvershoot); `curvesRGBGrid` (red threePoint / green inverted / blue identity; all three overshoot; red only fourPointS); `curvesRandom` (20 seeded `CurvesValue`s, random mode, 2…10 random points per channel, seed printed); `curvesSelectionBlend` (antialiased ellipse selection + luminosity threePoint vs oracle + `MaskBlendReference`). No PNG goldens: the oracle is the golden.
- **Integration — `PaintDotMacTests/Document/CurvesSessionIntegrationTests.swift`** (`@MainActor`, real `UndoBridge`, 600×400 two-layer document, active layer 1, `debounce: .zero`, renderer `CoreImageBridge`): `previewWithoutStep` (update "curve" to luminosity threePoint → live pixels == oracle, no new step, `isBusy`); `cancelRestores` (tiles share storage with the original, no step); `okCommitsOneStep` (one step "Curves", icon `.adjustment`); `undoRedo` (undo → original bytes; redo → oracle bytes); `identityAddsNoStep` (OK on defaults → no step, `effectMemory.lastApplied?.effectID == "curves"`); `editorEditsDriveSession` (a `CurveEditor` clicked at (128,192) → its value forwarded through `update` → live pixels == oracle of luminosity threePoint); `modeSwitchRerenders` (luminosity threePoint, then the same value with mode `.rgb` and red = threePoint → live pixels == RGB oracle; back to `.luminosity` → luminosity oracle); `repeatUsesRememberedCurves` (OK, Repeat → second "Curves" step, pixels == oracle applied twice; reopening yields the remembered value as initial values); `selectionClipped` (rect selection (100,100,200,100) → outside byte-identical, inside == oracle; undo exact); `sparseTiles` (layer with unallocated tiles: threePoint leaves them unallocated; inverted luminosity allocates them as (255,255,255,0)); `pendingEditFinishedFirst` (floating pixels → steps "Finish Pixels", "Curves").
- **UI — `PaintDotMacUITests/CurvesUITests.swift`** (pixel checks by ⌘S and decoding the PNG, as 0031; plot clicks at offsets from the plot's top-left corner, `plot.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx:, dy:))`, which map exactly because the plot is 256×256 pt — the test also asserts the coordinates label to make any mapping drift obvious). Fixture A: 300×200 PNG filled with (128,128,128,255); fixture B: filled with (200,100,50,255).
  - `testMenu`: Adjustments shows "Curves…" with ⇧⌘M between "Brightness / Contrast…" and "Hue / Saturation…".
  - `testLuminosityClickOK` (A): ⇧⌘M → `effectDialog` and `effectDialog.curve` exist; mode pop-up "Luminosity"; `effectDialog.curve.luminosity` checked and disabled; plot value "Luminosity: (0, 0), (255, 255)"; click at (128, 63) → coordinates "(128, 192)", plot value "Luminosity: (0, 0), (128, 192), (255, 255)"; wait `effectDialog.progress` "idle"; OK → last history row "Curves"; ⌘S → (10,10) == (192,192,192,255); ⌘Z → ⌘S → (128,128,128,255).
  - `testRightClickRemovesAndReset` (A): ⇧⌘M, click (128,63) → 3 points; right-click (128,63) → plot value back to identity; click (64,127) → 3 points; click `effectDialog.curve.reset` → identity; Cancel → no new history row.
  - `testDragPoint` (A): ⇧⌘M, click (128,63); press at (128,63) and drag to (64,63) → plot value "Luminosity: (0, 0), (64, 192), (255, 255)"; OK → ⌘S → (10,10) == (255,255,255,255) (spline (0,0),(64,192),(255,255) at 128 = 283.96 → clamped 255).
  - `testRGBRedOnly` (B): ⇧⌘M, mode → "RGB"; checkboxes Red, Green, Blue checked; untick Green and Blue; click (128,63) → plot value "Red: (0, 0), (128, 192), (255, 255); Green: (0, 0), (255, 255); Blue: (0, 0), (255, 255)"; OK → ⌘S → (10,10) == (238,100,50,255) (red table[200] = 238).
  - `testCancelRestores` (B): ⇧⌘M, click (128,63), wait idle, Escape → no new row, ⌘S → (200,100,50,255).
  - `testRepeat` (A): Luminosity click (128,63), OK; Effects menu shows "Repeat Curves"; ⌘F → no sheet, two "Curves" rows; ⌘S → (235,235,235,255) (128 → 192 → table[192] 235).
  - `testRememberedOnReopen` (A): after an OK with (128,192), ⇧⌘M again → plot value contains "(128, 192)"; checkboxes ticked again; Cancel.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build without warnings, all tests pass, none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open a photo, ⇧⌘M: grid, diagonal and the black (white in dark mode) luminosity curve are crisp on Retina; hovering shows the crosshair and "(x, y)"; hovering near a point enlarges it.
  2. Click on the curve and drag up/down: the canvas updates live and smoothly; drag the point past a neighbour and back — the neighbour reappears; drop it on the neighbour — the neighbour is gone; drag a point off the left edge — it merges into the left endpoint.
  3. Right-click and Control-click a middle point: it disappears; right-click an endpoint: nothing happens. Reset → diagonal.
  4. Switch to RGB, untick Green and Blue, bend red: only red changes; switch back to Luminosity: the earlier luminosity curve is still there and the canvas follows the active mode.
  5. Dark mode and VoiceOver: header "Transfer Map", pop-up, checkboxes, help text and Reset are announced; the plot reads "Transfer Map, Luminosity: (0, 0), (255, 255)".

## Open questions

Decided as stated (recommended answers applied in this spec); please confirm and record in PRD.md §5.8/§12:

1. **Removing control points: Paint.NET's gestures only — right-click (and, on the Mac, Control-click) removes a point; there is no "drag the point off the graph to delete it".** In Paint.NET 3.36 dragging past the plot edge clamps to the border, so a point dropped on x = 0 or 255 merges into that endpoint, and a point dropped on a neighbour's x replaces the neighbour. The help text reads "Tip: Right-click or Control-click to remove control points." Alternative: also delete a point when it is dragged outside the plot (as some other editors do). Recommended: mirror Paint.NET, with the Control-click addition.
2. **The Curves value keeps both the Luminosity curve and the three RGB curves, and the session memory/Repeat keeps both; only the active mode is applied.** Paint.NET 3.36 keeps both curves while the dialog is open, but its saved settings hold only the active mode's curve, so after OK in RGB mode, reopening shows a reset Luminosity curve. Alternative: drop the inactive mode's curves on OK. Recommended: keep both (no effect on pixels; less surprising when switching modes).
3. **Clicking within about 5 curve units of an existing point moves that point under the pointer instead of adding a new one, and a click adds the point at the pointer position (not snapped onto the curve)** — Paint.NET 3.36's behavior (hit radius: squared distance < 30 in 0…255 units). Recommended: mirror Paint.NET.

## Out of scope

- Input/output histograms in the Curves dialog (Paint.NET 3.36 has the strings but doesn't show them), curve presets, and saving/loading curves (not in the PRD).
- Keyboard nudging of control points and an adjustable VoiceOver action on the plot (Paint.NET has no keyboard editing; revisit in 0049 accessibility).
- HSV/Lab/per-channel-alpha transfer modes (Paint.NET has only Luminosity and RGB).
- Moving the Curves shortcut into `Core/Shortcuts/ShortcutTable.swift` (0045).
