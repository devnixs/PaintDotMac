# 0055 — Make the Paintbrush and Eraser respond to tablet pen pressure (size and/or opacity)

> Source: PRD.md §5.3 TOOL-D (P1: "Tablet pressure (`NSEvent.pressure`) changes brush width and/or opacity"), T-11 (Paintbrush), T-12 (Eraser; strength = color-slot alpha), TOOL-C (tool settings persist), §12 D-14 (pressure is P1 only), D-38 (continuous strokes, brush-outline cursor), D-27 (Eraser options), H-6 / D-34 (no-op edits add no step), §6 NF-1 (brush latency). Paint.NET docs: https://paint.net/doc/latest/Paintbrush.html ("Pressure Sensitivity" split-button toggle shown between Brush size and Hardness only when a compatible pen is detected; "If Pressure Sensitivity is enabled, pressure on the hardware will be reflected in the thickness of the brush stroke"), https://paint.net/doc/latest/EraserTool.html (the Eraser has the same Pressure Sensitivity option, see 0011 line 20). Pressure → opacity is not built into Paint.NET (forum feature request https://forums.getpaint.net/topic/127243-feature-request-pressure-can-apply-to-brush-opacity-instead-of-brush-size, answered by a developer as "not high up on the list"); PaintDotMac adds it because the PRD requires "width and/or opacity".
> Milestone: v1.x
> Depends on: 0051-use-case-acceptance-tests (v1.0 complete; in particular 0006 `ToolEvent`/`ToolPointerInput`/`CanvasInputRouter`, 0009 `BrushEngine`/`BrushStroke`/`BrushOptions`/`PaintbrushTool`, 0011 `EraserTool`/`EraseOps`, 0013 clip mask, 0045 `ShortcutTable`, 0048 brush performance pass, 0049 `AccessibilityCatalog`)

## Context

Today (once v1.0 is built):

- `ToolEvent.pressure: Double` exists but is "reserved for TOOL-D (0055); always 1.0 until then" (`docs/specs/todo/0006-tool-framework-and-panels_TODO.md:62`). `ToolPointerInput` carries `pressure` too (0006 line 209–211), and `CanvasInputRouter` (0006 line 288–306) builds it from `NSEvent` for `mouseDown/Dragged/Up` and `rightMouseDown/Dragged/Up`, always passing 1.0 (0006 Out of scope, line 508).
- `BrushStroke` (`Core/Tools/BrushEngine.swift`, 0009 line 49–85) sweeps each segment between consecutive events continuously with a **fixed** radius `r = width / 2`: a pixel's coverage from a segment is `profile(d)` with `d` the distance to the closed segment; the stroke keeps `strokeCov = max(...)` per pixel in `StrokeCoverageBuffer` and always recomputes the pixel from its before-stroke value (no darkening within a stroke). `BrushEngine.coverage(distance:options:)` is the antialiased/aliased profile; aliased strokes snap points with `BrushEngine.snappedCenter(_:width:)`.
- `PaintbrushTool` (0009) and `EraserTool` (0011 line 65–68) build one `BrushStroke` per drag with `BrushOptions.load(from:tool:)`; the Eraser composes with `EraseOps.erase(before, strength:, coverage:)`. `PencilTool` (0011) uses `BrushStroke.mark` and is always one pixel.
- 0009 (line 275), 0011 (line 20, 189), 0023, 0038, 0039, 0040, 0048 all defer pressure to this spec.

Paint.NET mirrors: Paint.NET 5's Paintbrush and Eraser have one **Pressure Sensitivity** toggle, which maps pen pressure to **stroke thickness** only. PRD TOOL-D asks for "width and/or opacity", so PaintDotMac's option is a four-way choice (Off / Size / Opacity / Size and Opacity), placed where Paint.NET puts its toggle (between Brush width and Hardness). Pressure response is **linear** in v1.x (no curve editor).

## User story

As a PaintDotMac user with a pen tablet (Wacom, or an iPad with Apple Pencil through Sidecar), I choose **Pressure Sensitivity: Size** (or Opacity, or Size and Opacity) in the Paintbrush or Eraser options, and pressing lightly paints a thinner (or fainter) line while pressing hard paints the full brush width (or full color alpha / eraser strength), with smooth tapers between pen samples. With a mouse or trackpad nothing changes: strokes are identical to before.

## Scope & changes

### Core (pure Swift, unit-tested; no AppKit/SwiftUI imports)

- **`PaintDotMac/Core/Tools/BrushPressure.swift`** (new):
  ```swift
  /// Persisted under tool.<id>.pressureSensitivity (raw value String).
  enum PressureSensitivity: String, CaseIterable, Sendable, ToolOptionValue {
      case off, size, opacity, sizeAndOpacity
      var displayName: String   // "Off", "Size", "Opacity", "Size and Opacity"
      var affectsSize: Bool     // size, sizeAndOpacity
      var affectsOpacity: Bool  // opacity, sizeAndOpacity
  }

  enum BrushPressure {
      /// Fixed in v1.x (linear curve). At pressure 0 the width is 10 % of the brush width.
      static let minimumWidthFraction: Double = 0.1
      /// The option key for a pressure-capable tool (.paintbrush, .eraser; 0056 adds .cloneStamp, 0057 .recolor).
      static func key(for tool: ToolID) -> ToolOptionKey<PressureSensitivity>   // name "pressureSensitivity", default .size
      @MainActor static func load(from store: any ToolOptionStore, tool: ToolID) -> PressureSensitivity
      /// Non-finite → 1.0; otherwise clamped to 0...1.
      static func sanitized(_ pressure: Double) -> Double
      /// width × (f + (1 − f) × p) when sensitivity.affectsSize, else width. p is sanitized first.
      static func width(base width: Double, pressure: Double, sensitivity: PressureSensitivity) -> Double
      /// p when sensitivity.affectsOpacity, else 1.0. p is sanitized first.
      static func opacity(pressure: Double, sensitivity: PressureSensitivity) -> Double
  }
  ```
  - An unknown stored raw value reads as missing → `.size` (0006's `ToolOptionValue` rule, as for `BlendMode`).
  - The mapping is linear in pressure (the v1.x "pressure curve"). The per-point width is **not** clamped to `BrushOptions.widthRange` (1…2000): a pressure width below 1 is allowed and is painted through antialiasing (Paint.NET honours sub-integer sizes the same way); with antialiasing off it becomes `max(1, round(w))` per point (0009's aliased rounding).

- **`PaintDotMac/Core/Tools/PointerPressure.swift`** (new) — turns raw event pressure into `ToolEvent.pressure`, kept out of the router so it is testable:
  ```swift
  enum PointerPhase: Sendable { case down, dragged, up }
  struct PointerPressureTracker: Sendable {
      /// isTabletPoint: the NSEvent is a tablet event (subtype .tabletPoint or type .tabletPoint).
      mutating func pressure(phase: PointerPhase, isTabletPoint: Bool, rawPressure: Double) -> Double
      mutating func reset()
  }
  ```
  Rules: not a tablet event → 1.0 (mouse, and Force Touch trackpad — see Open questions 1). Tablet `down`/`dragged` → `BrushPressure.sanitized(raw)` and remembered as the gesture's last pressure. `up` → the last remembered pressure of the gesture (tablets report 0 on lift-off, which would otherwise taper every stroke's final segment to nothing), or 1.0 if none. `down` starts a new gesture (forgets the previous last pressure); `reset()` after `up`.

- **`PaintDotMac/Core/Tools/BrushEngine.swift`** (extend 0009; existing signatures keep working with unchanged results):
  - `BrushStroke.init(canvasSize:options:clipMask:compose:pressureSensitivity: PressureSensitivity = .off)` — the new trailing parameter is fixed for the stroke. `.off` makes the stroke ignore all pressure values (exactly 0009's behavior).
  - `begin(at p: CGPoint, pressure: Double = 1, on surface: inout TiledSurface) -> PixelRect?` and `extend(to p: CGPoint, pressure: Double = 1, on surface: inout TiledSurface) -> PixelRect?`. `mark`, `cancel`, `makeTileDiff` are unchanged. The stroke stores per point `(location, width_i, opacity_i)` where `width_i = BrushPressure.width(base: options.width, pressure: p_i, sensitivity:)` and `opacity_i = BrushPressure.opacity(pressure: p_i, sensitivity:)`; `begin` stamps the degenerate segment (p, p) with the same values at both ends.
  - Refactor (no behavior change) the profile into `static func coverageFraction(distance: Double, width: Double, hardness: Int) -> Double` (the antialiased `c = min(e, s)` of 0009 line 74–77 with `r = width / 2`) and keep `coverage(distance:options:)` = `UInt8(floor(coverageFraction(...) · 255 + 0.5))` for antialiased options.
  - New pure helper, separately tested:
    ```swift
    /// The point of segment A→B (radii rA, rB, linearly interpolated) where r(t) − |P − S(t)| is largest.
    static func taperedSegmentParameter(point P: CGPoint, a A: CGPoint, b B: CGPoint, radiusA rA: Double, radiusB rB: Double) -> Double
    ```
- **Pressure segment model (normative; tests compute the same values by hand).** For a segment from point A (width `wA`, opacity `oA`) to point B (`wB`, `oB`), with `L = |B − A|`, `Δr = (wB − wA) / 2`:
  - *Equal ends* (`wA == wB` and `oA == oB`, bit-for-bit): exactly 0009's code path with width `wA`, then the coverage byte scaled by opacity as below. With `oA == 1` this is bit-identical to 0009 (the no-regression guarantee). With `.off`, or with all pressures equal to 1, every segment has equal ends with width `options.width` and opacity 1.
  - *Parameter* `t_opt` (the "round cone" closest point: width varies linearly along the segment, so `r(t) − |P − S(t)|` is concave in `t` and has one maximum):
    - `L == 0`: `t_opt = 1` if `wB > wA`, or (`wB == wA` and `oB > oA`); else 0.
    - `|Δr| ≥ L` (one end disc contains the other): `t_opt = Δr > 0 ? 1 : 0`.
    - otherwise: `τ = ((P − A)·(B − A)) / L²` (unclamped), `d⊥ = |P − (A + τ(B − A))|`, `t_opt = clamp(τ + Δr · d⊥ / (L · sqrt(L² − Δr²)), 0, 1)`. (With `Δr = 0` this is 0009's clamped projection.)
  - *Coverage:* `S = A + t_opt(B − A)`, `d = |P − S|`, `w = wA + (wB − wA)·t_opt`, `o = oA + (oB − oA)·t_opt`.
    - Antialiased: `cov = UInt8(floor(coverageFraction(distance: d, width: w, hardness:) · o · 255 + 0.5))`.
    - Aliased (hardness ignored): each end's width is `max(1, round(w_i))` (round half away from zero) and each end point is snapped with `snappedCenter(_:width:)` using its own rounded width; then the same `t_opt` on the snapped segment with those radii; `cov = (d² ≤ (w/2)²) ? UInt8(floor(o · 255 + 0.5)) : 0`.
    - `strokeCov = max(old, cov)` in `StrokeCoverageBuffer`, clip and compose exactly as 0009 (line 80–82). Because opacity only lowers `cov` before the max, a pixel passed over twice in one stroke takes the stronger pass, never a darker sum: **no darkening within a stroke** still holds.
  - *Interpolation:* width and opacity are interpolated linearly between consecutive event points (not per pixel sample along time); pressure is never smoothed; no pressure curve.
  - *Region:* each segment's bounding box is expanded by `max(RA, RB) + 1` (antialiased, `R = w/2 + 0.5`) or `max(rA, rB) + 1` (aliased), clamped to the canvas before converting to `Int` (0009 line 83).
  - Opacity 0 at both ends (pressure 0 in Opacity mode) paints nothing; a stroke that changes nothing yields an empty diff → no history step (H-6).
- **`PaintDotMac/Core/Tools/PaintbrushTool.swift`** (extend 0009): at `mouseDown` read `BrushPressure.load(from: context.options, tool: .paintbrush)` and pass it to `BrushStroke`; pass `event.pressure` to `begin`/`extend` (down, every drag, and up). Re-read in `optionsDidChange`. Brush outline (`BrushOutline`, 0009) keeps showing the full brush width (pressure 1; see Open questions 5). History step name stays "Paintbrush".
- **`PaintDotMac/Core/Tools/EraserTool.swift`** (extend 0011): same as the Paintbrush with `tool: .eraser`. Opacity mode scales the brush coverage, so it scales the erase amount through `EraseOps.erase(before, strength:, coverage:)` unchanged (strength is still the color-slot alpha). History step stays "Eraser".
- **Not pressure-aware** (they keep ignoring `ToolEvent.pressure`): Pencil (Paint.NET's Pencil has no pressure; PRD T-13 "one pixel wide"), Line/Curve, Shapes, Text, Gradient, Paint Bucket, selection tools, Move tools, Color Picker, Zoom, Pan.
- **`Core/Tools/ToolDispatcher.swift`** (0006): no change expected. Its existing mapping copies `ToolPointerInput.pressure` into `ToolEvent.pressure` unchanged; this spec adds a test pinning that.

### Platform glue (AppKit/SwiftUI; covered by UI tests and manual checks)

- **`Canvas/CanvasInputRouter.swift`** (extend 0006): owns one `PointerPressureTracker`. For `mouseDown/Dragged/Up` and `rightMouseDown/Dragged/Up` it sets `ToolPointerInput.pressure = tracker.pressure(phase:, isTabletPoint: event.subtype == .tabletPoint, rawPressure: Double(event.pressure))` (read `subtype` only for mouse-type events, where AppKit defines it). Space-pan and middle-button pan ignore pressure.
- **`Canvas/CanvasView.swift`** (extend): override `tabletPoint(with:)` and forward to the router: while a dispatcher gesture is in progress, it is delivered as `pointerDragged` for the gesture's button at the event's location with `isTabletPoint: true` (a pressure change without movement then extends the stroke with a zero-length segment, which only ever raises coverage). Outside a gesture it is ignored. `tabletProximity` events are not handled (pen eraser-end switching is out of scope).
- **`App/LaunchOptions.swift`** (extend, `#if DEBUG` only): `-UITestPressure <0…1>` makes the router treat every mouse pointer event as a tablet event with that raw pressure (the up phase still follows the tracker rule). This lets UI tests drive the full path without a tablet.
- **`UI/ToolOptionsBar.swift`** (extend 0009/0011): for the Paintbrush and the Eraser, a **Pressure Sensitivity** popup between Brush width and Hardness (Paint.NET's position) with the items "Off", "Size", "Opacity", "Size and Opacity", reading and writing `BrushPressure.key(for:)` through `model.toolOptions`, accessibility identifier `toolOptions.pressureSensitivity`, help text "Pen pressure changes the brush size, opacity, or both". It is always visible (Paint.NET shows its toggle only when a pen is detected; see Open questions 4). Not shown for the Pencil or other tools.
- Persisted keys: `tool.paintbrush.pressureSensitivity`, `tool.eraser.pressureSensitivity` (raw value strings). The `tool.` prefix is already reset by `-UITestResetDefaults` (D-37); no new prefix.
- **`Core/Accessibility/AccessibilityCatalog.swift`** (extend 0049): an exact `.documentWindow` entry `toolOptions.pressureSensitivity`, role `.popUpButton`, label "Pressure Sensitivity" (the visible caption, 0049's `toolOptions.<option>` rule), value `.format(.selectedTitle)`, placed after `toolOptions.width`'s entries in bar order; it joins the document window's Tab order through 0049's "active tool's `toolOptions.*` in bar order" rule (no plan code change).
- No new menu items or shortcuts (0045's `ShortcutTable` unchanged).
- No `project.yml` change beyond new files; run `xcodegen generate`.
- No PRD update in this spec (the batch owner records the answers to the open questions in PRD §5.3 TOOL-D / §12).

## Acceptance criteria

- [ ] With a mouse or trackpad (no tablet events), every stroke of the Paintbrush and the Eraser is bit-identical to 0009/0011, for every Pressure Sensitivity value. → `BrushPressureEngineTests.pressureOneIsBitIdenticalToBaseline`, `BrushPressurePropertyTests.offAndUnitPressureMatchBaseline`, `PointerPressureTrackerTests.mouseEventsAreFullPressure`
- [ ] Tablet pressure reaches tools as `ToolEvent.pressure` in 0…1; non-finite → 1; lift-off keeps the last pressure. → `PointerPressureTrackerTests.*`, `ToolDispatcherPressureTests.pressureIsForwarded`
- [ ] Size mode: width = brush width × (0.1 + 0.9 × pressure), interpolated linearly between events with a correctly tapered outline. → `BrushPressureTests.widthMapping`, `BrushPressureEngineTests.sizeDabHandValues`, `.taperedSegmentHandValues`, `.containedEndDiscCovered`, `TaperedSegmentParameterTests.*`
- [ ] Opacity mode: coverage is scaled by pressure, interpolated between events. → `BrushPressureTests.opacityMapping`, `BrushPressureEngineTests.opacityDabHandValues`, `.opacityTaperHandValues`
- [ ] Size and Opacity applies both. → `BrushPressureEngineTests.sizeAndOpacityHandValue`
- [ ] No darkening within one stroke at any pressure; separate strokes still accumulate. → `BrushPressureEngineTests.varyingOpacityNeverDarkensWithinStroke`, `BrushPressurePropertyTests.revisitNeverLowersPixelBelowSinglePass`
- [ ] Aliased strokes with pressure use per-point `round(width)` and snapping and only 0/opacity-scaled coverage. → `BrushPressureEngineTests.aliasedPressureDab`
- [ ] Eraser: pressure scales size and/or erase amount (strength × pressure in Opacity mode). → `EraserPressureTests.opacityHalvesEraseAmount`, `.sizeModeShrinksEraser`
- [ ] Pencil and other tools ignore pressure. → `PencilToolTests.ignoresPressure`
- [ ] The option persists per tool under `tool.<id>.pressureSensitivity`, default Size, unknown value → Size; the options bar shows it for Paintbrush and Eraser only. → `BrushPressureTests.optionPersistsPerTool`; `PressureUITests.optionShownForBrushAndEraserOnly`, `.optionPersistsAcrossRelaunch`
- [ ] The popup is catalogued for accessibility (0049). → `AccessibilityCatalogTests.pressureSensitivityEntry`, `PressureUITests.optionShownForBrushAndEraserOnly` (asserts label "Pressure Sensitivity")
- [ ] End to end with synthetic pressure, Opacity mode paints at half alpha and Off paints full. → `PressureUITests.syntheticPressureOpacity`
- [ ] Each stroke is still one "Paintbrush"/"Eraser" step; undo/redo restore identical tiles; a stroke that changes nothing adds no step. → `BrushPressurePropertyTests.undoRedoIdentity`, `BrushPressureEngineTests.zeroPressureOpacityAddsNoStep`
- [ ] NF-1: a pressure-varying width-300 stroke stays within the 0009 gate (3×, 48 ms per event). → `PaintbrushPerformanceTests.testStrokeSegmentLatencyWidth300Pressure`
- [ ] Real tablet behaviour (thin-to-thick lines, fades, Sidecar Apple Pencil) → manual (no tablet in CI).
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Mouse / trackpad:** pressure forced to 1.0 → identical to v1.0 (Force Touch pressure ignored, Open questions 1).
- **Lift-off pressure 0** on the up event → replaced by the last pressure (no vanishing tail).
- **Pressure 0 on mouse-down** (some pens): Size mode paints a 10 % dab; Opacity mode paints nothing at that point and fades in.
- **Pressure out of range / NaN / ∞** (driver glitches) → clamped / treated as 1.0.
- **Tiny widths:** width 1, pressure 0 → per-point width 0.1, `R = 0.55`: faint antialiased pixel, no crash, no division by zero (`R > 0` always). Aliased → 1 px.
- **Width 2000 with pressure** on a 4000×3000 canvas: bounding box uses the larger end; no overflow (clamped before `Int` conversion).
- **Zero-length segments with different pressure** (tablet point without motion): end with larger width (then opacity) wins; never lowers coverage.
- **One end disc containing the other** (`|Δr| ≥ L`): handled without `sqrt` of a negative number.
- **Option changed mid-stroke** → next stroke only (snapshot at mouse-down, as 0009).
- **Selection clip, tile boundaries, off-canvas points, cancel with Escape, commit on tool switch / undo / save**: unchanged from 0009/0013 (pressure only changes coverage values before the max).
- **Pen eraser end** behaves like the pen tip (no tool switch; out of scope).

## Test plan

Expected values below were computed by hand from the formulas above (independent of the implementation). Profile: `R = w/2 + 0.5`, `e = clamp(R − d, 0, 1)`, hardness 100 → `c = e`; byte = `floor(c·o·255 + 0.5)`. Normal blending and `EraseOps` values come from 0009/0011's tests.

- **Unit — `PaintDotMacTests/Tools/BrushPressureTests.swift`:**
  - `widthMapping`: base 10, `.size`: p 0 → 1.0; 0.5 → 5.5; 1 → 10; 1.7 → 10; −1 → 1.0; NaN → 10; ∞ → 10. `.opacity` and `.off`: any p → 10. `.sizeAndOpacity` p 0.5 → 5.5. Base 2000, p 0.25 → 650.
  - `opacityMapping`: `.opacity` p 0 → 0; 0.25 → 0.25; 1 → 1; 2 → 1; NaN → 1. `.size`/`.off` → 1 for any p.
  - `sanitized`: −0.5 → 0, 0.3 → 0.3, 1.2 → 1, NaN/±∞ → 1.
  - `optionPersistsPerTool`: empty `InMemoryToolOptionStore` → `.size` for `.paintbrush` and `.eraser`; set `.opacity` for paintbrush → key `tool.paintbrush.pressureSensitivity` holds `"opacity"`, eraser still `.size`; stored `"foo"` → `.size`; `displayName`s are exactly "Off", "Size", "Opacity", "Size and Opacity"; `affectsSize`/`affectsOpacity` truth table.
- **Unit — `PaintDotMacTests/Tools/PointerPressureTrackerTests.swift`:**
  - `mouseEventsAreFullPressure`: `isTabletPoint: false` with raw 0, 0.3, 1 for down/dragged/up → 1.0 each.
  - `tabletPressurePassesThrough`: down 0.42 → 0.42; dragged 0.8 → 0.8; raw 1.3 → 1; raw −0.1 → 0; NaN → 1.
  - `liftOffKeepsLastPressure`: down 0.5, dragged 0.7, up raw 0 → 0.7; up without any tablet down/drag → 1.0.
  - `newGestureForgetsPrevious`: gesture 1 ends at 0.7; gesture 2 mouse (non-tablet) down → 1.0, up raw 0 → 1.0.
- **Unit — `PaintDotMacTests/Tools/TaperedSegmentParameterTests.swift`** (A = (10.5, 50.5), B = (30.5, 50.5), L = 20, rA = 0.5, rB = 5, Δr = 4.5):
  - `onAxisEqualsProjection`: P = (20.5, 50.5) → 0.5 (d⊥ = 0).
  - `offAxisShiftsTowardWiderEnd`: P = (20.5, 53.5) → 0.5 + 4.5·3/(20·√379.75) = 0.534638 (±1e-6).
  - `equalRadiiIsClampedProjection`: rA = rB = 3: P = (5, 52) → 0; P = (40, 49) → 1; P = (15.5, 60) → 0.25.
  - `containedEnd`: A = (20.5, 20.5), B = (22.5, 20.5), rA 0.5, rB 5 (|Δr| ≥ L) → 1 for any P; reversed radii → 0.
  - `zeroLength`: A == B → 1 when rB > rA, 0 otherwise.
  - `maximizesRoundConeOracle` (property, 2 000 seeded cases, seed printed): `r(t_opt) − |P − S(t_opt)|` ≥ the maximum over 10 001 uniform samples of t in [0, 1] minus 1e-9.
- **Unit — `PaintDotMacTests/Tools/BrushPressureEngineTests.swift`** (black opaque color, hardness 100, antialiasing on unless stated; surfaces from `TestImages`):
  - `pressureOneIsBitIdenticalToBaseline`: for each sensitivity value, a seeded 6-point stroke with all pressures 1 on a seeded semi-transparent 300×300 surface equals the same stroke through a `.off` `BrushStroke` (and through 0009's `begin(at:on:)`/`extend(to:on:)` without the pressure argument) tile-for-tile; also identical `touchedTiles`.
  - `constantPressureEqualsSmallerBrush`: `.size`, width 10, all pressures 0.5 → identical surface to a `.off` stroke with width 5.5.
  - `sizeDabHandValues`: 100×100 transparent, `.size`, width 10, `begin((50.5, 50.5), pressure: 0.5)` (w = 5.5, R = 3.25): (50,50) and (52,50) → `(0,0,0,255)`; (53,50) (d = 3) → alpha 64; (54,50) → untouched. Hardness 75, width 20, p 0.5 (w = 11, R = 6): (55,50) (d = 5) → alpha 189; (54,50) → 255; (56,50) → untouched.
  - `taperedSegmentHandValues`: 64×64 transparent, `.size`, width 10, `begin((10.5, 50.5), pressure: 0)`, `extend((30.5, 50.5), pressure: 1)`: (20,50) → alpha 255; (20,53) → alpha 83 (t_opt 0.534638, w 5.811743, d 3.078948; plain projection would give 64); (30,55) → alpha 128 (d = 5 to B, R = 5.5); (10,51) → alpha 7 (t 0.011546, w 1.103914, d 1.026316); (10,52) → untouched.
  - `containedEndDiscCovered`: `.size` width 10, `begin((20.5, 20.5), pressure: 0)`, `extend((22.5, 20.5), pressure: 1)`: (17,20) → alpha 128 (5 px from B); (16,20) → untouched; (27,20) → 128.
  - `opacityDabHandValues`: 100×100 opaque white, `.opacity`, width 10, `begin((50.5, 50.5), pressure: 0.5)`: (50,50) → cov 128 → `(127,127,127,255)`; (55,50) (d 5, e 0.5) → cov 64 → `(191,191,191,255)`.
  - `opacityTaperHandValues`: transparent, `.opacity`, width 10, (10.5, 50.5) p 1 → (30.5, 50.5) p 0: (20,50) → alpha 128 (o 0.5); (20,53) → alpha 128 (Δr = 0, t 0.5); (29,50) → alpha floor(0.05·255 + 0.5) = 13; (30,50) → untouched (o 0).
  - `sizeAndOpacityHandValue`: transparent, `.sizeAndOpacity`, width 10, (10.5, 50.5) p 0 → (30.5, 50.5) p 1: (20,53) → alpha floor(0.326924·0.534638·255 + 0.5) = 45.
  - `varyingOpacityNeverDarkensWithinStroke`: 64×64 opaque white, `.opacity`, width 8: stroke (5.5,32.5) p 1 → (58.5,32.5) p 1 → (5.5,32.5) p 0.5: (32,32) → `(0,0,0,255)` (the return pass, o = 0.754717 → cov 192, is lower and the max keeps 255). Reverse order (0.5 out, 1 back) → also `(0,0,0,255)`. All pressures 0.5, out and back → `(127,127,127,255)`, the single-pass value, not darker. Two separate strokes at 0.5 → `(63,63,63,255)`.
  - `aliasedPressureDab`: antialiasing off, `.size`, width 10, `begin((10.3, 10.3), pressure: 0.5)` (5.5 → 6, even → snapped center (10, 10), r = 3) on a 32×32 transparent surface → exactly the 32 pixels x 7…12, y 7…12 minus (7,7),(12,7),(7,12),(12,12), each `(0,0,0,255)`; `.opacity` p 0.5 width 3 → the 9 pixels x 9…11, y 9…11 at alpha 128.
  - `zeroPressureOpacityAddsNoStep`: `.opacity`, whole stroke at pressure 0 → `makeTileDiff(...).isEmpty`, surface `generation` unchanged.
  - `clipAndPressureCombine`: 0009's `clipMaskScalesCoverage` setup with `.opacity` p 0.5: (10,10) → `(127,127,127,255)`; (18,10) (clip 128, cov mul255(128,128) = 64) → `(191,191,191,255)`; (19…,10) unchanged.
  - `hugePressureBrushIsSafe`: 4000×3000 white, width 2000, (0,1500) p 0 → (4000,1500) p 1 with far-off point (−1e9, −1e9) p 1 appended → no crash; center pixel black; point outside both cones unchanged.
- **Unit — `PaintDotMacTests/Tools/EraserPressureTests.swift`** (0011 surface: opaque `(200,100,50,255)`, primary alpha 255 unless stated, `FakeToolContext` events with `pressure`):
  - `opacityHalvesEraseAmount`: `.opacity`, width 10, hardness 100, click at (32.5,32.5) with pressure 0.5 → (32,32) = `(200,100,50,127)` (cov 128, 0011 `partialCoverage`).
  - `sizeModeShrinksEraser`: `.size`, width 10, pressure 0.5 → (32,32) and (34,32) `(0,0,0,0)`; (35,32) (d 3) cov 64 → `EraseOps.erase(p, strength: 255, coverage: 64)` (compute in the test with 0011's integer formula: newA = (255·(65025 − 16320) + 32512)/65025 = 191) → `(200,100,50,191)`; (36,32) unchanged.
  - `strengthAndPressureMultiply`: primary alpha 120, `.opacity`, p 0.5, antialiasing off, width 5 → center newA = (255·(65025 − 120·128) + 32512)/65025 = 195 → `(200,100,50,195)`.
- **Unit — `PaintDotMacTests/Tools/PaintbrushToolTests.swift`** (extend): `pressureFromEventsReachesStroke`: `.size` stored, width 10; `mouseDown` at (50.5,50.5) pressure 0.5, `mouseUp` same point pressure 0.5 → (53,50) alpha 64 over transparent; `.off` stored → (53,50) alpha 255 (d = 3 < R 5.5). `optionReReadAtMouseDown`: change the stored option mid-stroke → current stroke unchanged, next stroke uses the new value.
- **Unit — `PaintDotMacTests/Tools/PencilToolTests.swift`** (extend): `ignoresPressure`: same stroke with pressures 0.1 and 1 → identical surfaces; no pressure option key read (`InMemoryToolOptionStore` access log has no `pressureSensitivity` key).
- **Unit — `PaintDotMacTests/Tools/ToolDispatcherPressureTests.swift`:** `pressureIsForwarded`: a `StubTool` records events; `pointerDown/Dragged/Up` with pressure 0.25/0.5/0.75 → recorded `ToolEvent.pressure` 0.25/0.5/0.75, including for the right button (`.secondary`).
- **Round-trip and property tests — `PaintDotMacTests/Tools/BrushPressurePropertyTests.swift`** (200 seeded iterations each, seed printed on failure):
  - `offAndUnitPressureMatchBaseline`: random canvas ≤ 400×400, random background, random 1–15-point stroke (some off canvas), width 1–60, hardness 0–100, AA on/off: `.off` with random pressures, and every mode with pressures 1, each equal 0009's stroke exactly.
  - `matchesTaperedOracle`: random pressures in [0,1], random mode: every pixel equals a test-target oracle in **`PaintDotMacTests/Support/BrushCoverageOracle.swift`** (new, shared: 0056/0057 reuse it; API `enum BrushCoverageOracle { static func coverage(points: [(CGPoint, Double)], options: BrushOptions, sensitivity: PressureSensitivity, canvasSize: PixelSize, clip: (any BrushClipMask)?) -> [UInt8] }`, row-major per-pixel `strokeCov` after the clip) that applies the normative segment model above independently (its own `t_opt`, profile, max over segments, clip, Normal formula). Exact equality.
  - `revisitNeverLowersPixelBelowSinglePass`: for random strokes, each pixel's final `strokeCov` equals the max over segments of the per-segment coverage (computed by the oracle), so repeating any segment with lower pressure leaves the surface unchanged.
  - `undoRedoIdentity`: random pressure stroke through `PaintbrushTool` + `FakeToolContext` history: undo → pre-stroke tiles, redo → post-stroke tiles; same for `EraserTool`.
- **Integration — `PaintDotMacTests/Integration/PressureIntegrationTests.swift`** (0009's headless `UndoBridge` setup, 800×600 white): `pressureStrokeIsOneStep`: `.sizeAndOpacity`, a `ToolDispatcher(registry: .standard())` fed `ToolPointerInput`s with pressure 0.2 → 1.0 → up 0 (already tracker-processed as 1.0) → history `["New Image", "Paintbrush"]`; undo → white; redo → identical to the pre-undo pixels. Eraser on a black layer, `.opacity` 0.5 → `["…", "Eraser"]`, alpha 127 at the click.
- **Golden-image tests:** none (exact in-test oracle instead).
- **Unit — `PaintDotMacTests/Accessibility/AccessibilityCatalogTests.swift`** (extend 0049): `pressureSensitivityEntry` — `entry(matching: "toolOptions.pressureSensitivity")` is the exact entry (surface `.documentWindow`, `.popUpButton`, "Pressure Sensitivity", `.format(.selectedTitle)`).
- **UI tests — `PaintDotMacUITests/PressureUITests.swift`** (`UITestApp`, fixture 300×200 PNG `(128,128,128,255)`, `-UITestOpen`, `-UITestResetDefaults`):
  - `optionShownForBrushAndEraserOnly`: Paintbrush (B) → `toolOptions.pressureSensitivity` exists with label "Pressure Sensitivity", value "Size" and items "Off", "Size", "Opacity", "Size and Opacity"; E → exists; P (Pencil) and H (Pan) → does not exist.
  - `optionPersistsAcrossRelaunch`: set Paintbrush to "Opacity", relaunch without reset → "Opacity"; Eraser still "Size".
  - `syntheticPressureOpacity`: launch with `-UITestPressure 0.5`; Paintbrush width 20, Pressure Sensitivity "Opacity", ⌘0, drag through the center; ⌘S and read the file back with ImageIO → center pixel `(64,64,64,255)` (black alpha 128 over gray: (128·255·127 + 32512)/65025 = 64); Edit menu "Undo Paintbrush". Then ⌘Z, set "Off", same drag, save → center `(0,0,0,255)`.
  - `mouseStrokeUnchangedWithPressureOn`: without `-UITestPressure`, "Size and Opacity", width 20, drag → saved center `(0,0,0,255)`.
- **Performance (NF-1) — `PaintDotMacTests/Performance/PaintbrushPerformanceTests.swift`** (extend 0009/0048): `testStrokeSegmentLatencyWidth300Pressure`: 0009's width-300 setup with `.sizeAndOpacity` and seeded pressures varying 0.2–1.0 per event → mean and p95 ≤ 48 ms per `extend`; report numbers. `testStrokeSegmentLatencyWidth50` with `.size` and all pressures 1 → report only (should match the 0009 number, equal-ends fast path).
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification** (needs a pen tablet or an iPad with Apple Pencil via Sidecar; CI has neither):
  1. Paintbrush width 40, Size: press lightly then hard in one stroke → the line grows from about 4 px to 40 px smoothly, with no beads or steps at sample points; lifting off doesn't produce a thin tail.
  2. Opacity: same stroke → fades from faint to the full color; scribbling back and forth in one stroke never gets darker than the hardest press.
  3. Size and Opacity: both effects together. Off: uniform full stroke regardless of pressure.
  4. Eraser on a photo with Size and Opacity: light pressure erases a thin, partial line; hard pressure erases fully.
  5. With a mouse and a Force Touch trackpad (including a deep press): strokes look exactly as before; options bar shows the popup but nothing changes.
  6. Pen held still while changing pressure (tablet point events): the dab grows, never shrinks or flickers.
  7. Fast strokes at width 300 with pressure on a 4000×3000 image: no visible lag compared with Off (NF-1 feel).
  8. Brush outline shows the full width and follows the pen (Open questions 5).

## Open questions

Recommended answers are applied in this spec; the user should confirm each.

1. **Force Touch trackpad pressure — include or exclude?** Force Touch trackpads report a varying `NSEvent.pressure` during clicks and drags, but pressing harder also triggers force-click stages. *Recommended:* exclude; only tablet events (`.tabletPoint` subtype/type) carry pressure, everything else is 1.0.
2. **Option shape and default.** Paint.NET has one on/off Pressure Sensitivity toggle (size only). *Recommended:* a "Pressure Sensitivity" popup with Off / Size / Opacity / Size and Opacity, per tool (`tool.<id>.pressureSensitivity`), default **Size** (closest to Paint.NET with the toggle on; no effect for mouse users).
3. **Minimum width at zero pressure.** *Recommended:* fixed at 10 % of the brush width (`BrushPressure.minimumWidthFraction = 0.1`), linear response, no user-adjustable minimum or curve in v1.x; opacity goes all the way to 0.
4. **When to show the option.** Paint.NET shows its toggle only when a pen is detected. *Recommended:* always show it for the Paintbrush and Eraser (simpler, and testable without a tablet).
5. **Brush outline under pressure.** *Recommended:* the outline keeps showing the full brush width (pressure 1), not the live pressure width.

## Out of scope

- Clone Stamp (0056), which reuses `BrushStroke(…, pressureSensitivity:)` and adds `BrushPressure.key(for: .cloneStamp)`.
- Pressure for the Pencil, Line/Curve, Shapes, Text, Gradient, and other tools.
- Pressure curves, minimum-size/minimum-opacity options, pressure smoothing, tilt, rotation, and tangential pressure.
- Pen eraser-end auto switching (`tabletProximity`, `pointingDeviceType == .eraser`).
- Mouse event coalescing changes (0048 owns input performance).
