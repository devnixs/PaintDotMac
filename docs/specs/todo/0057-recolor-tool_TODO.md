# 0057 — Add the Recolor tool (R): brush strokes that shift colors similar to the secondary color toward the primary color

> Source: PRD.md §5.3 T-16 ("Recolor — R — Replaces the secondary color with the primary color within a tolerance", P1), TOOL-A (left = primary, right-drag or Control-drag = secondary), TOOL-B (painting is confined to the selection), TOOL-C (options persist), TOOL-D (pen pressure, via 0055), §5.3 intro (`[` / `]` brush width), §5.12 (tool key R), §6 NF-1 (brush latency), NF-4 (undo stores changed tiles only), §12 D-26 (v1.x P1 specs), D-35 (tool keys), D-37 (`tool.` prefix reset), D-38 (continuous strokes, no Spacing/Smoothing, brush-outline cursor), D-42/D-43 (Paint.NET 3.36 tolerance metric, no Tolerance Alpha Mode), H-6/D-34 (no-op edits add no step). AGENTS.md rules 1–3, 6–8.
> Paint.NET docs: Recolor Tool, https://paint.net/doc/latest/RecolorTool.html (redirect target of https://www.getpaint.net/doc/latest/RecolorTool.html).
> Paint.NET source consulted (behaviour transcribed below; the implementer writes original Swift, nothing is copied): Paint.NET 3.36 `src/tools/RecoloringTool.cs` and `src/Core/Utility.cs` (`ColorDifference`), mirrored at https://github.com/iamdroppy/openpdn; Paint.NET 4.0 (decompiled) `PaintDotNet/Tools/Recolor/RecolorTool.cs`, `RecolorToolChanges.cs`, `RecolorToolContentRenderer.cs`, `RecolorToolSamplingMode.cs`, mirrored at https://github.com/vaginessa/Paint.Net4.
> Milestone: v1.x
> Depends on: 0051-use-case-acceptance-tests (v1.0 complete; in particular 0006 tool framework, 0007 colors, 0008 history, 0009 `BrushEngine`/`BrushStroke`/`BrushOptions`/`BrushOutline`, 0010 History panel icons, 0013 selection clip, 0016 `FloodTolerance`/`FloodColorMetric`/`FloodToolOptions`, 0045 `ShortcutTable`, 0049 `AccessibilityCatalog`), 0055-tablet-pressure (lower number, built first: `BrushPressure`, `BrushStroke(…, pressureSensitivity:)`). Independent of 0056 (Clone Stamp).

## Context

Today (once 0001–0055 are built):

- `ToolID.recolor` exists, with the registry row `recolor | Recolor | r | photo | paintpalette | false` (`docs/specs/todo/0006-tool-framework-and-panels_TODO.md:157`), but `ToolRegistry.standard()` doesn't register it (`0006…:164-165`), so **R is consumed silently** and the Tools panel doesn't show the tool (`0006…:340`, `:376`, `:412`, `:470`; `0045-shortcut-audit_TODO.md:225` notes "P1 (0057); consumed silently until then.").
- `HistoryIcon.recolor` already exists (`0008-history-stack-and-undo-bridge_TODO.md:50-52`) and 0010 maps it to a symbol.
- 0009 provides everything a brush tool needs (`0009-paintbrush-tool_TODO.md:49-96`): `BrushOptions` (width 1…2000, default 2; hardness 0…100, default 75; antialiasing, default on; `keys(for:)`/`load`/`save` per tool), `BrushStroke` with a **custom per-pixel compose closure** `BrushCompose = (before, coverage) -> ColorRGBA8` that always receives the pixel's **before-stroke** value and its effective coverage 1…255 (stroke max coverage × selection clip), `cancel`, `makeTileDiff`, `BrushWidthAdjustable` (`[`/`]`), `BrushOutline` (brush-outline cursor), `context.paintClipMask` (0013's selection mask).
- 0055 adds `BrushStroke.init(…, pressureSensitivity:)`, `begin(at:pressure:on:)`, `extend(to:pressure:on:)`, `BrushPressure.key(for:)`/`load(from:tool:)`, and the "Pressure Sensitivity" popup (`0055-tablet-pressure_TODO.md:25-97`).
- 0016 provides the tolerance metric the wand and bucket use (`0016-magic-wand-and-flood-fill_TODO.md:30-48`, `:64-75`): `FloodTolerance(percent:)` (Paint.NET 3.36 scaling `Int(t·t·256)` in `Float`, `maxDistance = scaled²·4`), `FloodColorMetric.distance(seed:candidate:)` / `matches(seed:candidate:tolerance:)` (Paint.NET 3.36 `CheckColor`: RGB terms weighted by the **seed's** alpha, plus the squared alpha difference), and `FloodToolOptions.tolerance(for:)` (`"tolerance"`, default 50, range 0…100) (`0016…:110-116`).

### Paint.NET behaviour being mirrored

**Docs (Recolor Tool page).** "Used to replace regions of similar color with another color." Two sampling modes:
- **Sampling Once:** "With the Left Mouse button, the color first clicked is recolored with the Primary color. With the Right Mouse button, it is recolored with the Secondary color."
- **Sampling Secondary Color** ("the same method of recoloring as seen in Paint.NET 3.5x"): left button: the Primary color is the replacement and pixels within tolerance of the Secondary color are replaced; the right button reverses the roles.
- Options: Brush size (decimals, `[` / `]`), Pressure Sensitivity, Hardness ("ignored when Antialiasing is disabled"), Spacing, Tolerance ("At 0 %, only exactly matching colors are replaced. At 100 %, all pixels are recolored, similar to the Paintbrush Tool"), Tolerance Alpha Mode, Path Smoothing, Antialiasing. The brush tip is circular. The page gives no blend mode and no defaults except Tolerance Alpha Mode.

**Paint.NET 4 source** (`RecolorToolSamplingMode { Once, SecondaryColor }`; `RecolorToolChanges`; `RecolorToolContentRenderer`):
- Roles: the mouse button picks `WhichUserColor` (right → Secondary, else Primary). `FillColor` = primary for the left button, secondary for the right. `BasisColor` = secondary for the left button, primary for the right.
- In **SecondaryColor** mode the color to replace is `BasisColor`. In **Once** mode it is the **active layer's** pixel at the first input point (`PointDouble.Truncate`), or transparent black when that point is off the layer.
- The stroke is rendered from the **layer as it was when the stroke started** (`sampleSource = activeLayer.Surface`), never from partially recolored pixels. The output mask = brush stroke mask × color stencil (`FillStencilByColorRenderer(sampleSource, basisColor, tolerance)`), so a pixel is changed only if its original color is within tolerance of the color to replace.
- Content per pixel, all four channels: `out.c = clampToByte(src.c + (fill.c − basis.c))` for c ∈ {B, G, R, A}. This is an **offset shift**: shading and texture variations inside the matched region are preserved, only shifted.
- With Antialiasing on, Paint.NET 4 also feathers the stencil edge (`FeatheredMaskRenderer`); that class's source isn't available (see Open questions 3).

**Paint.NET 3.36 source** (`RecolorTool`, `ToolBarConfigItems.Pen | Antialiasing | Tolerance`, key `'r'`), for comparison: the same per-channel shift `ClampToByte(lifted.c + (replaceWith.c − beingReplaced.c))`, but the pixel's alpha was always kept (Open questions 2), the match used `Utility.ColorDifference` (RGB only, `ceil(sqrt(Σd²/3)) ≤ (int)(tolerance·256)`), `RestrictTolerance()` capped the tolerance at the primary–secondary distance, overlapping dabs within one stroke could compound, and Ctrl/Shift-drag picked or adjusted colors. Paint.NET 4 dropped all of these, and so does PaintDotMac (see *Out of scope*). Antialiased edge pixels were blended with `NormalBlendOp` at the brush coverage and then given back their original alpha (for an opaque pixel this is a linear interpolation at the coverage, which is the rule below). When primary == secondary nothing happened.

## User story

As a PaintDotMac user, I press **R** (or click Recolor in the Tools panel), choose a brush width, hardness, tolerance, and sampling mode in the tool options bar, and drag over a photo: wherever the brush passes, pixels similar to my secondary color take on my primary color, keeping their shading. Right-drag (or Control-drag) does the reverse. Each stroke is one "Recolor" step that ⌘Z undoes.

## Scope & changes

### Core (pure, unit-tested)

1. **`PaintDotMac/Core/Tools/RecolorOps.swift`** (new) — the per-pixel rule and the role selection, with no tool or UI state:
   ```swift
   enum RecolorSamplingMode: String, CaseIterable, Sendable, ToolOptionValue {
       case once, secondaryColor
       var displayName: String          // "Once", "Secondary Color"
   }

   struct RecolorRoles: Equatable, Sendable {
       var basis: ColorRGBA8            // the color being replaced
       var fill: ColorRGBA8             // the replacement color
       var isNoOp: Bool { basis == fill }   // all four channels equal
   }

   enum RecolorOps {
       /// Paint.NET 4 role rules. `onceSample` is the active layer's before-stroke pixel at the first
       /// point (only used in .once mode).
       static func roles(mode: RecolorSamplingMode, button: ToolMouseButton,
                         colors: ColorSelection, onceSample: ColorRGBA8) -> RecolorRoles
       /// The pixel whose color "Once" samples: (floor(x), floor(y)) of the first point; nil when outside the canvas.
       static func samplePixel(at point: CGPoint, canvasSize: PixelSize) -> PixelPoint?
       /// Offset shift, all four channels: clamp(before.c + (fill.c − basis.c), 0, 255).
       static func shifted(_ before: ColorRGBA8, roles: RecolorRoles) -> ColorRGBA8
       /// The BrushCompose rule. Returns `before` exactly when the color doesn't match.
       static func compose(before: ColorRGBA8, roles: RecolorRoles,
                           tolerance: FloodTolerance, coverage: UInt8) -> ColorRGBA8
   }
   ```
   - **Roles** (normative):
     | mode | button | basis | fill |
     |---|---|---|---|
     | `.secondaryColor` | `.primary` (left) | `colors.secondary` | `colors.primary` |
     | `.secondaryColor` | `.secondary` (right / Control-left) | `colors.primary` | `colors.secondary` |
     | `.once` | `.primary` | `onceSample` | `colors.primary` |
     | `.once` | `.secondary` | `onceSample` | `colors.secondary` |
   - **`onceSample`**: the active layer's pixel at `samplePixel(at: firstPoint, canvasSize:)` read **before** the stroke changes anything; `(0,0,0,0)` when `samplePixel` is `nil` (Paint.NET: `ColorBgra.TransparentBlack`). PaintDotMac uses `floor`, so a point at x = −0.5 is off the canvas. Paint.NET truncates toward zero, which maps −0.5 to column 0. The result is the same for every on-canvas point.
   - **Match**: `FloodColorMetric.matches(seed: roles.basis, candidate: before, tolerance:)` (0016; the seed is the color being replaced, so the RGB terms are weighted by the basis alpha). 0 % matches only identical pixels; 100 % matches every pixel (0016 proves the maximum distance is below `256²·4`), which gives Paint.NET's "At 100 %, all pixels are recolored".
   - **Compose** (normative; `m = coverage`, 1…255, already including the brush profile, pressure opacity (0055), and the selection clip (0013), all applied by `BrushStroke`):
     1. If the color doesn't match → return `before` (bit-identical).
     2. `c = shifted(before, roles:)`.
     3. If `m == 255` → return `c`.
     4. Otherwise, per channel (R, G, B, A, each independently, straight values): `out = (before·(255 − m) + c·m + 127) / 255` (integer division; all terms are non-negative). For channels where `c == before` this returns `before` exactly.
   - When `roles.isNoOp`, `shifted` returns `before` for every pixel, so the stroke changes nothing. The tool also skips the stroke early (item 2), as Paint.NET 3.36 did.
2. **`PaintDotMac/Core/Tools/RecolorTool.swift`** (new) — `@MainActor final class RecolorTool: Tool, BrushWidthAdjustable`, `id = .recolor`. It is modelled on 0009's `PaintbrushTool` (same lifecycle, same `updateImage`/`commitHistory` pattern, same handling of a missing layer, hidden layer, and floating pixels):
   - **Options**: `struct RecolorOptions: Equatable, Sendable { var brush: BrushOptions; var tolerance: Int; var samplingMode: RecolorSamplingMode; var pressure: PressureSensitivity }` with `@MainActor static func load(from store: any ToolOptionStore) -> RecolorOptions` / `func save(to:)`:
     - `BrushOptions.load/save(…, tool: .recolor)` → keys `tool.recolor.width` (default 2), `tool.recolor.hardness` (75), `tool.recolor.antialiasing` (true). `blendMode` is ignored and never shown, as on the Eraser (Paint.NET's Recolor has no blend mode).
     - `FloodToolOptions.tolerance(for: .recolor)` → `tool.recolor.tolerance`, default 50, range 0…100 (clamped).
     - `ToolOptionKey<RecolorSamplingMode>(tool: .recolor, name: "samplingMode", defaultValue: .secondaryColor)` → `tool.recolor.samplingMode` (raw strings `"once"`, `"secondaryColor"`; an unknown value reads as missing → `.secondaryColor`). Expose it as `static let samplingModeKey`.
     - `BrushPressure.key(for: .recolor)` → `tool.recolor.pressureSensitivity`, default `.size` (0055's default). (0055's doc comment already lists `.recolor`.)
     - Options are re-read at each `mouseDown` and in `optionsDidChange(context:)`. The `tool.` prefix is already reset by `-UITestResetDefaults` (D-37).
   - **`mouseDown(_:context:)`** (ignored while a stroke is active): snapshot the options (clamped), `context.colors`, the button (`event.button`; Control-left already arrives as `.secondary`, 0006), the active layer's `Layer.ID`, and `context.paintClipMask`. In `.once` mode read `onceSample` from the active layer at `RecolorOps.samplePixel(at: event.location, …)` **before** `begin`. Compute `roles`. If `roles.isNoOp`, remember a "no-op stroke" and do nothing until `mouseUp` (no pixel writes, no step). Otherwise build `BrushStroke(canvasSize:, options: brush, clipMask:, compose: { before, cov in RecolorOps.compose(before: before, roles: roles, tolerance: FloodTolerance(percent: tolerance), coverage: cov) }, pressureSensitivity: pressure)` and call `begin(at: event.location, pressure: event.pressure, on:)` inside `context.updateImage`.
   - **`mouseDragged`**: `extend(to:pressure:on:)`. **`mouseUp`**: `extend` to the up point, then commit. Because `BrushStroke` always composes from the before-stroke pixel and keeps the max coverage, a pixel passed over several times in one stroke is recolored exactly once (no compounding). Separate strokes do build on each other.
   - **Commit**: `diff = stroke.makeTileDiff(from: layer.surface, layerID:)`; `context.commitHistory(TileDiffHistoryItem(name: "Recolor", icon: .recolor, diff: diff))` (0008: an empty diff adds no step, H-6). `commit(context:)` (tool switch, Return, `prepareForNavigation` before undo/redo/save) finishes an in-progress stroke like `mouseUp` at the last point. `cancel(context:)` (Escape) calls `BrushStroke.cancel` inside `updateImage`: the layer is bit-identical and no step is added. `hasPendingEdit` is true only during a stroke.
   - **Cursor/overlay**: crosshair plus `ToolOverlay.brushOutline(BrushOutline.canvasRect(center:options:))` on `mouseMoved`/drag and after width changes, exactly as the Paintbrush (D-38). The outline shows the full width (pressure 1, as in 0055).
   - **Width keys**: `adjustBrushWidth(by:context:)` clamps to 1…2000, saves `tool.recolor.width`, and refreshes the outline. A change during a stroke applies to the next stroke.
3. **`PaintDotMac/Core/Tools/ToolRegistry.swift`** (extend 0006): `standard()` registers `.recolor` → `RecolorTool()`. `implementedIDs` now includes `.recolor`.
4. **`PaintDotMac/Core/Shortcuts/ShortcutTable.swift`** (extend 0045): row `tools.r` keeps status `matchesPaintNET`, and its `notes` become `""` (the tool now exists). Regenerate `docs/shortcuts.md` with `RECORD_SHORTCUT_DOCS=1` (0045's `docsFileMatchesTable` enforces it) and update the `tools.r` row in 0045's `ShortcutTableTests.everyRowLiteral` literal. No new chords: R, ⇧R (a one-tool group: Shift+R also selects Recolor, D-41), `[`/`]`.

### Platform glue (covered by UI tests and manual checks)

5. **`UI/ToolOptionsBar.swift`** (extend 0009/0011/0016/0055): when Recolor is active, show from left to right, with Paint.NET's labels:
   - **Sampling** popup "Once" / "Secondary Color" (Paint.NET's "Sampling: Once" / "Sampling: Secondary Color"), accessibility `toolOptions.recolorSampling`, help "Sampling: Once replaces the color you first click; Secondary Color replaces colors similar to the secondary color". It has its own identifier because the wand's `toolOptions.samplingMode` means Layer/Image.
   - **Brush width** (`toolOptions.width`, `.decrease`, `.increase`), **Pressure Sensitivity** (`toolOptions.pressureSensitivity`), **Hardness** (`toolOptions.hardness`, greyed out while antialiasing is off), **Tolerance** (`toolOptions.tolerance`, accessibility value "NN%"), **Antialiasing** (`toolOptions.antialiasing`). Reuse the existing controls, bound to the `tool.recolor.*` keys.
   - No blend-mode popup, no flood-mode picker, no Layer/Image sampling picker.
6. **Tools panel** (0006): Recolor appears automatically once registered (photo group, after Clone Stamp, tooltip "Recolor (R)", identifier `tool.recolor`).
7. **`Core/Accessibility/AccessibilityCatalog.swift`** (extend 0049): add an exact `.documentWindow` entry `toolOptions.recolorSampling`, role `.popUpButton`, label "Sampling" (visible caption, 0049's `toolOptions.<option>` rule), value `.format(.selectedTitle)`; the other Recolor controls reuse their existing entries (`toolOptions.width`, `.pressureSensitivity`, `.hardness`, `.antialiasing`, `.tolerance`).
8. No new menu items and no `project.yml` change beyond the new files. Run `xcodegen generate` after adding them.
9. **Tests owned by earlier specs that use `.recolor` as "the unimplemented tool"** must keep testing that path: after this spec every `ToolID` is implemented, so rewrite `ToolDispatcherTests.selectUnimplementedIsNoOp`, `ToolDispatcherTests.unimplementedKeyConsumed` (0056 switched it to `"r"`), and `ToolRegistryTests.standardRegistersZoomAndPan` (0006 `:376`, `:412`, `:424`) to build `ToolRegistry(factories:)` from `standard()`'s factories minus `.recolor` (`"r"` → consumed, active unchanged, no calls; `makeTool(.recolor) == nil` on that registry), and update the expected `ToolRegistry.standard().implementedIDs` list. Update `ToolsPanelUITests.testShowsImplementedToolsOnly` so `tool.recolor` now **exists** (0056 owns the `tool.cloneStamp` half).
10. **PRD:** not edited by this spec (sub-agent rule). The batch owner records the answers to the Open questions in PRD §5.3 T-16 and §12 (suggested T-16 notes text: "Sampling: Secondary Color (default) or Once. Width, hardness, antialiasing, pressure, tolerance (Magic Wand metric, default 50 %). Per-channel offset shift (fill − basis) of matching pixels, evaluated against the layer as it was at stroke start.").

## Acceptance criteria

- [ ] Pressing R (no text field focused) selects Recolor. The Tools panel shows and highlights `tool.recolor`, and the options bar shows Sampling, Brush width, Pressure Sensitivity, Hardness, Tolerance, Antialiasing with defaults Secondary Color, 2, Size, 75 %, 50 %, on, and no blend mode. → `RecolorUITests.pressingRSelectsRecolorAndShowsOptions`, `RecolorToolTests.defaultsMatchPaintNET`, `ToolRegistryTests.recolorRegistered`
- [ ] The per-pixel rule is exactly: match by `FloodColorMetric` against the basis, then a per-channel clamped offset shift `before + (fill − basis)` on all four channels, interpolated at the coverage with `(before·(255−m) + c·m + 127)/255`. Non-matching pixels are bit-identical. → `RecolorOpsTests.*`
- [ ] Roles follow the table: Secondary Color mode, left: secondary → primary; right/Control: primary → secondary. Once mode: the layer pixel under the first point → primary (left) or secondary (right); off-canvas first point → transparent black. → `RecolorOpsTests.rolesTable`, `.samplePixelFloorsAndRejectsOffCanvas`, `RecolorToolTests.onceSamplesFirstPoint`, `.onceRightButtonUsesSecondary`, `.onceStartingOffCanvasChangesNothing`
- [ ] Left-drag with default colors (black primary, white secondary) turns white pixels on the stroke black and leaves dissimilar (red) pixels untouched. Right-drag reverses the roles. → `RecolorToolTests.leftDragReplacesSecondaryWithPrimary`, `.rightDragSwapsRoles`, `RecolorUITests.dragRecolorsAndUndoes`
- [ ] Tolerance: 0 % changes only exact matches, 50 % uses the wand's boundary, 100 % changes every covered pixel. → `RecolorToolTests.toleranceOptionIsUsed`
- [ ] Brush width, hardness, antialiasing, and pressure shape the coverage exactly as on the Paintbrush (0009/0055). Partial coverage interpolates. → `RecolorToolTests.antialiasedEdgeInterpolates`, `.pressureOpacityScalesCoverage`, `RecolorPropertyTests.matchesOracle`
- [ ] A pixel crossed several times in one stroke is recolored once; a second stroke builds on the first. → `RecolorToolTests.noCompoundingWithinStroke`, `.secondStrokeCompounds`
- [ ] Recoloring is confined to the selection, scaled by its antialiased mask (TOOL-B). → `RecolorToolTests.clippedToSelection`, `RecolorUITests.recolorIsClippedToSelection`
- [ ] Each effective stroke is one "Recolor" step (icon `recolor`). Undo restores identical tiles, and redo reapplies them. Strokes that change nothing (no match, primary == secondary, all off-canvas) add no step. → `RecolorIntegrationTests.strokeIsOneUndoableStep`, `.noOpStrokesAddNoStep`, `RecolorPropertyTests.undoRedoIdentity`, `RecolorUITests.dragRecolorsAndUndoes`
- [ ] Escape mid-stroke restores the layer bit-identically with no step. Tool switch, Return, undo, and save mid-stroke commit it first. → `RecolorToolTests.cancelMidStrokeRestores`, `.commitMidStrokeCreatesStep`, `RecolorIntegrationTests.undoDuringStrokeCommitsFirst`
- [ ] Options persist under `tool.recolor.*`, independently of the other tools. Bad stored values clamp or fall back. → `RecolorToolTests.optionsRoundTripThroughStore`, `.invalidStoredValues`, `RecolorUITests.optionsPersistAcrossRelaunch`
- [ ] The Sampling popup is catalogued for accessibility (0049). → `AccessibilityCatalogTests.recolorSamplingEntry`, `RecolorUITests.pressingRSelectsRecolorAndShowsOptions`
- [ ] `[` / `]` change the Recolor width and the outline follows. → `RecolorToolTests.widthKeysAdjustAndOutlineFollows`
- [ ] `docs/shortcuts.md` matches the table (the R row has no "consumed silently" note). → `ShortcutDocsTests.docsFileMatchesTable`, `ShortcutTableTests.everyRowLiteral` (updated)
- [ ] Stroke latency meets NF-1 like the Paintbrush. → `RecolorPerformanceTests.testStrokeSegmentLatencyWidth50`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **primary == secondary** (Secondary Color mode), or in Once mode a fill equal to the sampled color: the stroke is a no-op, with no writes and no step.
- **First point off the canvas in Once mode:** basis `(0,0,0,0)`. At tolerance < 100 % opaque pixels don't match (the alpha term alone is 65 025), so nothing changes and there is no step. At 100 % every pixel matches (as in Paint.NET).
- **Transparent basis** (`(0,0,0,0)`): the RGB terms weigh 0, so every alpha-0 pixel matches at 0 % whatever its hidden RGB. The shift then sets the alpha to `0 + fill.a`.
- **Clamping:** channels saturate at 0 and 255 (no wraparound).
- **Alpha shift:** with `fill.a ≠ basis.a`, alpha shifts by the difference (Paint.NET 4; see Open questions 2). With equal alphas (the usual case) alpha is unchanged.
- **Semi-transparent pixels:** the match is weighted by the basis alpha (0016's asymmetric metric). The interpolation works on straight channels.
- **Strokes crossing tile boundaries or the canvas edge, segments far off-canvas:** handled by `BrushStroke` (0009). Off-canvas parts change nothing.
- **Selection:** coverage = stroke coverage × mask. A stroke entirely outside the selection gives an empty diff and no step. Once sampling ignores the selection (it samples the layer pixel even outside it, as Paint.NET does).
- **Width 1 / 2000, sub-integer widths, hardness 0/100, AA off:** as in 0009. Hardness is ignored when AA is off.
- **Pressure 0 in Opacity mode:** coverage 0, so nothing changes.
- **Layer removed or document closed mid-stroke:** as for the Paintbrush (stroke cancelled, no crash).
- **Mouse-down during an active stroke:** ignored.
- **Undo/redo across the step:** tile-identical (property test).

## Test plan

Expected values below are computed by hand from the formulas in *Scope* and 0016's metric (`distance = Σ_RGB ⌊(1 + d²)·basis.a/256⌋ + (basis.a − before.a)²`; 25 % → limit 1024, 50 % → 16 384, 100 % → 262 144).

- **Unit — `PaintDotMacTests/Tools/RecolorOpsTests.swift`:**
  - `rolesTable`: colors primary P = `(1,2,3,255)`, secondary S = `(4,5,6,255)`, sample Q = `(7,8,9,200)`: `(.secondaryColor, .primary)` → basis S, fill P; `(.secondaryColor, .secondary)` → basis P, fill S; `(.once, .primary)` → basis Q, fill P; `(.once, .secondary)` → basis Q, fill S. `isNoOp` is true for P == S and false when only alpha differs.
  - `samplePixelFloorsAndRejectsOffCanvas` (canvas 20×10): (9.99, 5.5) → (9,5); (0, 0) → (0,0); (19.99, 9.99) → (19,9); (−0.5, 5) → nil; (20, 5) → nil; (5, 10) → nil; NaN → nil.
  - `shiftedClamps`: basis `(100,150,200,255)`, fill `(150,100,250,255)`: before `(110,140,190,255)` → `(160,90,240,255)`; before `(240,30,230,255)` → `(255,0,255,255)` (290 and 280 clamp to 255, −20 clamps to 0).
  - `fullCoverageMatch`: same roles, tolerance 50 %, before `(110,140,190,255)` (distance 3 × ⌊101·255/256⌋ = 300) at coverage 255 → `(160,90,240,255)`.
  - `partialCoverageInterpolates`: same, coverage 128 → `(135,115,215,255)` (R `(110·127 + 160·128 + 127)/255 = 34577/255 = 135`, G `29427/255 = 115`, B `54977/255 = 215`, A `65152/255 = 255`).
  - `toleranceBoundaries`: basis `(100,150,200,255)`, before `(110,140,190,255)` (distance 300): matches at 25 % (limit 1024), not at 13 % (limit 64) → returns before bit-identical. Basis `(100,100,100,255)`, before `(101,100,100,255)` (distance 1): not at 0 %. Basis `(0,50,50,255)`: before R = 128 matches at 50 %, R = 129 doesn't (0016's boundary).
  - `hundredPercentMatchesAll`: basis `(100,150,200,255)`, before `(240,30,230,255)` (distance ≥ ⌊19601·255/256⌋ = 19524 > 16384): unchanged at 50 %, and `(255,0,255,255)` at 100 %.
  - `alphaShifts`: basis `(100,150,200,255)`, fill `(150,100,250,128)`, tolerance 50 %: before `(100,150,200,255)` → `(150,100,250,128)`; before `(100,150,200,200)` (distance 0 + 55² = 3025) → `(150,100,250,73)`.
  - `transparentBasis`: basis `(0,0,0,0)`, fill `(255,0,0,255)`, tolerance 0 %: before `(9,9,9,0)` (distance 0) → `(255,9,9,255)`; before `(0,0,0,255)` (distance 65025) → unchanged.
  - `noOpRolesReturnBefore`: basis == fill == `(50,60,70,255)`, tolerance 100 %, 200 seeded random `before` values × coverages {1, 128, 254, 255} → output == before.
  - `interpolationIdentityOnEqualChannel`: for all `o` in 0…255 and all `m` in 1…255, `(o·(255−m) + o·m + 127)/255 == o` (exhaustive).
- **Unit — `PaintDotMacTests/Tools/RecolorToolTests.swift`** (0006's `FakeToolContext` as extended by 0007/0008/0009/0013/0055: `InMemoryToolOptionStore`, `DocumentState` + `HistoryStack` behind `commitHistory`, `ColorSelection`, settable `paintClipMask`, recorded overlays):
  - `defaultsMatchPaintNET`: empty store → width 2, hardness 75, AA true, tolerance 50, `.secondaryColor`, pressure `.size`. Id `"recolor"`, displayName "Recolor", shortcut `r`, `HistoryIcon.recolor` raw value `"recolor"`.
  - `optionsRoundTripThroughStore`: set width 37.5, hardness 20, AA false, tolerance 13, `.once`, `.opacity` → the keys `tool.recolor.width/hardness/antialiasing/tolerance/samplingMode/pressureSensitivity` hold them (`samplingMode` == `"once"`). A new tool instance reads them back. Paintbrush, Eraser, and Magic Wand keys still return their defaults.
  - `invalidStoredValues`: width 5000 → 2000, 0 → 1, NaN → 2; tolerance 150 → 100, −3 → 0; samplingMode `"bogus"` → `.secondaryColor`; pressure `"foo"` → `.size`.
  - `leftDragReplacesSecondaryWithPrimary`: 20×10 opaque image, x < 10 white `(255,255,255,255)`, x ≥ 10 red `(255,0,0,255)`. Default colors (primary black, secondary white), width 4, AA off, tolerance 50. Left drag (1.5,5.0) → (18.5,5.0) (aliased even width: snapped centres (2,5) → (19,5), r = 2). Expected: (5,5) and (5,3) → `(0,0,0,255)`; (0,4) → `(0,0,0,255)` (cap, d² = 2.5); (0,3) white (d² = 4.5); (5,2) and (5,7) white; (15,5) red (distance white→red = 2 × 64771 = 129542, no match). One step "Recolor", icon `.recolor`.
  - `rightDragSwapsRoles`: same image, primary red `(255,0,0,255)`, secondary white. Right drag (`.secondary`) along the same path → (15,5) becomes `(255,255,255,255)` (basis red, fill white, shift (0,+255,+255,0)); (5,5) stays white. A left drag with the same colors turns (5,5) red and leaves (15,5) red. A Control-left event delivered by the dispatcher as `.secondary` behaves like the right drag (`FakeToolContext` event with `button: .secondary, modifiers: [.control]`).
  - `toleranceOptionIsUsed`: 64×3 opaque image, row pixels `(4x, 0, 0, 255)`. Secondary `(0,0,0,255)`, primary `(0,0,100,255)`, width 1, AA off, drag (0.5,1.5) → (63.5,1.5). Tolerance 0 → only (0,1) gets B = 100. 50 → x 0…32 get B = 100 and x 33…63 are unchanged. 100 → all 64. Rows 0 and 2 are unchanged in all cases.
  - `antialiasedEdgeInterpolates`: 100×100 opaque `(110,140,190,255)`, secondary `(100,150,200,255)`, primary `(150,100,250,255)`, width 10, hardness 100, AA on, click (down + up) at (50.5,50.5): (50,50) → `(160,90,240,255)`; (55,50) (coverage 128, 0009's hand value) → `(135,115,215,255)`; (56,50) unchanged.
  - `pressureOpacityScalesCoverage`: same image, colors, and brush; pressure `.opacity`, events with pressure 0.5 → (50,50) coverage `⌊0.5·255 + 0.5⌋ = 128` → `(135,115,215,255)`. With `.off` and pressure 0.5 → `(160,90,240,255)`.
  - `noCompoundingWithinStroke`: same setup, one stroke (40.5,50.5) → (60.5,50.5) → (40.5,50.5) → (60.5,50.5) → (50,50) is `(160,90,240,255)`, not `(210,40,255,255)`, even though `(160,90,240)` is still within 50 % of the basis (distance 3586 + 3586 + 1594 = 8766).
  - `secondStrokeCompounds`: after the single click of `antialiasedEdgeInterpolates`, a second click at the same point → (50,50) = `(210,40,255,255)`. Two steps.
  - `onceSamplesFirstPoint`: 20×10 image, x < 10 `(10,20,30,255)`, x ≥ 10 `(200,200,200,255)`; mode `.once`, primary `(90,80,70,255)`, secondary white, tolerance 0, width 3, AA off, left drag (2.5,5.5) → (17.5,5.5): (5,5) and (5,4) → `(90,80,70,255)`; (5,3) unchanged; (15,5) unchanged `(200,200,200,255)`.
  - `onceRightButtonUsesSecondary`: same image, `.once`, secondary `(0,0,0,255)`, right drag (15.5,5.5) → (2.5,5.5), tolerance 0 → (15,5) → `(0,0,0,255)`; (5,5) unchanged.
  - `onceStartingOffCanvasChangesNothing`: same image, `.once`, tolerance 50, drag (−5,5.5) → (17.5,5.5) → layer unchanged, no step, `commitHistory` not called (or called with an empty diff that adds no step; assert the stack).
  - `noOpWhenColorsEqual`: primary == secondary == white on the white/red image, drag across → layer unchanged, no step, `imageUpdates` unchanged after mouse-down.
  - `clippedToSelection`: 40×20 opaque white, `paintClipMask` test mask x < 18 → 255, x == 18 → 128, x > 18 → 0. Default colors, width 6, hardness 100, AA, drag (2.5,10.5) → (37.5,10.5): (10,10) → `(0,0,0,255)`; (18,10) → `(127,127,127,255)` (m = 128: `(255·127 + 0 + 127)/255 = 127`); x ≥ 19 unchanged. A mask whose bounds exclude the stroke → no step.
  - `cancelMidStrokeRestores`: down + drag, then `cancel` → tiles share storage with or equal the before state, and no step. `commitMidStrokeCreatesStep`: down + drag, then `commit` → one "Recolor" step. `hasPendingEdit` is true only between down and up/commit/cancel.
  - `widthKeysAdjustAndOutlineFollows`: AA, width 2, `mouseMoved` (10,10) → overlay `.brushOutline((9,9,2,2))`; `adjustBrushWidth(by: +1)` → `(8.5,8.5,3,3)` and `tool.recolor.width` == 3; width at 2000 + 1 → stays 2000.
  - `mouseDownDuringStrokeIgnored`: a second `mouseDown` mid-stroke doesn't restart the stroke or resample.
- **Unit — `PaintDotMacTests/Tools/ToolRegistryTests.swift`** (extend): `recolorRegistered`: `standard().makeTool(.recolor) is RecolorTool`, `implementedIDs` contains `.recolor`, `descriptor(for: .recolor)` key `r`. Rewrite 0006's unimplemented-tool tests as described in *Scope* item 9.
- **Property — `PaintDotMacTests/Tools/RecolorPropertyTests.swift`** (`SeededRandom`, seed printed on failure):
  - `matchesOracle`: 200 cases. Random canvas ≤ 300×300 with 2–4 palette colors plus ±12 noise (so regions match partially), random alpha in some cases. Random polyline of 1–12 points (some off-canvas), width 1–60, hardness, AA on/off, tolerance in {0, 13, 50, 87, 100}, mode and button random, random colors (basis sometimes taken from the palette), optional random rectangle clip mask. Oracle: run the same points through a `BrushStroke` with a **recording** compose (returns `before`, records `coverage` per pixel) to get each pixel's effective coverage. Then apply a test-local transcription of the rule (0016-style `Int32` `CheckColor` + shift + interpolation, written independently of `RecolorOps`) to the original pixel. Every pixel must equal the tool's result exactly. Tiles in the diff are exactly the tiles with a changed pixel.
  - `undoRedoIdentity`: 50 runs of 1–4 random strokes through `RecolorTool` + `UndoBridge`: undo all → tiles equal the original; redo all → equal to the state after each stroke.
- **Integration — `PaintDotMacTests/Integration/RecolorIntegrationTests.swift`** (headless, as `PaintbrushIntegrationTests`: an 800×600 white New Image document, `UndoBridge` with base `.newImage`, `groupsByEvent = false`, a `ToolContext` double forwarding to it):
  - `strokeIsOneUndoableStep`: default colors, width 20, drag across the center → history names `["New Image", "Recolor"]`, center pixel `(0,0,0,255)`, undo menu title "Undo Recolor"; undo → all tiles equal white; redo → center black.
  - `noOpStrokesAddNoStep`: primary == secondary; then a stroke over pixels that don't match (primary red, secondary green on the white image, tolerance 0) → history still `["New Image"]`, document not edited.
  - `undoDuringStrokeCommitsFirst`: down + drag, then undo through `UndoBridge` → the stroke is committed as "Recolor" first and then undone (same contract as 0009).
- **Unit — `PaintDotMacTests/Accessibility/AccessibilityCatalogTests.swift`** (extend 0049): `recolorSamplingEntry` — `entry(matching: "toolOptions.recolorSampling")` is `.popUpButton`, "Sampling", `.format(.selectedTitle)`, surface `.documentWindow`.
- **UI tests — `PaintDotMacUITests/RecolorUITests.swift`** (`UITestApp`, `-UITestResetDefaults YES`; fixture generated at test time: 200×200 PNG, left half opaque red `(255,0,0)`, right half opaque white):
  - `pressingRSelectsRecolorAndShowsOptions`: type `r` → `tool.recolor` selected; `toolOptions.recolorSampling` (label "Sampling") value "Secondary Color", `toolOptions.width` "2", `toolOptions.pressureSensitivity` "Size", `toolOptions.hardness` "75%", `toolOptions.tolerance` "50%", `toolOptions.antialiasing` on; `toolOptions.blendMode` does not exist. (The "Recolor (R)" tooltip is checked manually, as 0006 does for tooltips.)
  - `dragRecolorsAndUndoes`: ⌘0; R; set `toolOptions.width` to 30; drag across the canvas at normalized y 0.5 from x 0.05 to 0.95 (default colors: primary black, secondary white) → last `historyRow` "Recolor", Edit menu shows "Undo Recolor"; ⌘S, decode the PNG → (150,100) `(0,0,0,255)`, (50,100) `(255,0,0,255)` (red isn't similar to white), (150,10) `(255,255,255,255)`; ⌘Z → last row "Open Image", save, and (150,100) is white again.
  - `rightDragSwapsRoles`: with the primary slot active, type `FF0000` into `colors.hex` (primary red; secondary stays white). R, width 30, then a Control-drag (left button with ⌃ held, through `UITestApp`'s canvas-drag helper; Control-left reaches the tool as `.secondary`, 0006) across the same line → basis red, fill white. Saved PNG: (50,100) `(255,255,255,255)` (red became white), (150,100) `(255,255,255,255)` (white isn't similar to red, so it's unchanged); last `historyRow` "Recolor".
  - `recolorIsClippedToSelection`: S, drag a rectangle over normalized (0.6,0.4) → (0.9,0.6); R, width 30, drag across the full width at y 0.5 → saved: a pixel inside the selection (150,100) black; (190,10) white; (110,100) (outside the selection, on the stroke) white.
  - `optionsPersistAcrossRelaunch`: set Sampling "Once", tolerance to 0 (slider to minimum), width 12; relaunch without `-UITestResetDefaults`; R → "Once", "0%", "12".
- **Updated UI test:** `ToolsPanelUITests.testShowsImplementedToolsOnly` expects `tool.recolor` to exist.
- **Performance — `PaintDotMacTests/Performance/RecolorPerformanceTests.swift`** (XCTest `measure`): `testStrokeSegmentLatencyWidth50`: 4000×3000 noisy photo-like layer (seeded), width 50, hardness 75, AA, tolerance 50, 240 drag events along a seeded smooth path. Time each `extend` (coverage + match + compose). Gate: mean and p95 ≤ 48 ms (3× NF-1's 16 ms, as 0009). Report mean/p95/max in the Verification status. NF-4: the diff holds only changed tiles (`matchesOracle` asserts it).
- **Shortcut docs:** `ShortcutDocsTests.docsFileMatchesTable` passes after regeneration.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes.
- **Manual verification:**
  1. Open a photo with a blue sky. Set the secondary to a sky blue (Color Picker, right-click) and the primary to orange. R, width 60, tolerance 50 %, drag over the sky: the sky turns orange with its gradient and clouds' shading kept, and buildings/trees in the brush path stay unchanged.
  2. Same at tolerance 10 % (only near-exact pixels change, leaving a speckled result) and 100 % (acts like a soft paintbrush offset).
  3. Sampling Once: start a stroke on a red car, then drag over other colors. Only colors similar to the first-clicked red change.
  4. Antialiasing on, hardness 0: soft edge blending. Antialiasing off: hard-edged result, and hardness is greyed out.
  5. With a tablet (if available), Pressure Sensitivity Size and Opacity behave as on the Paintbrush.
  6. The brush outline follows the pointer at 25 %, 100 %, and 400 % zoom, and `[`/`]` resize it.
  7. Swap colors with X and recolor back: the original colors return approximately (exactly, when no channel clamped).

## Open questions

Each one has the recommended answer already applied in this spec. The batch owner confirms it with the user and records it in PRD §5.3 T-16 / §12.

1. **Sampling modes.** PRD T-16 describes only "replaces the secondary color with the primary color". Paint.NET 4/5 also has **Sampling: Once** (replace the color under the first click). Should PaintDotMac offer both, and which is the default? *Recommended (applied):* offer both ("Once", "Secondary Color"), default **Secondary Color**, matching the PRD wording and Paint.NET 3.5x behaviour.
2. **Alpha handling.** Paint.NET 4/5 shift alpha like the color channels (`a + (fill.a − basis.a)`), so a semi-transparent primary makes recolored pixels more transparent. Paint.NET 3.36 always kept each pixel's alpha. Which one? *Recommended (applied):* Paint.NET 4/5 (shift all four channels). With opaque primary and secondary, both give the same result.
3. **Antialiasing of the color-match edge.** Paint.NET 4/5 with Antialiasing on also feathers the boundary between matching and non-matching colors (`FeatheredMaskRenderer`, source not available). PaintDotMac's Antialiasing only smooths the brush edge, and the color match is binary (as in 3.36). Accept? *Recommended (applied):* yes, a binary match. A feathered match can be a later enhancement.
4. **Pressure Sensitivity and tolerance metric.** Paint.NET's Recolor page lists Pressure Sensitivity (and Tolerance Alpha Mode). Should Recolor get 0055's Pressure Sensitivity popup (default Size), and use the Magic Wand's tolerance metric with no Tolerance Alpha Mode (as D-42/D-43 decided for the wand and bucket)? *Recommended (applied):* yes to both.

## Out of scope

- Paint.NET 3.36 behaviours dropped in Paint.NET 4: `RestrictTolerance` (capping the tolerance at the primary–secondary distance), Ctrl-drag pick-color and Shift-drag adjust-color modifiers, re-recoloring within one stroke.
- Spacing, Path Smoothing (D-38), Tolerance Alpha Mode (D-42/D-43), Selection Quality, and the feathered color-match edge (Open questions 3).
- Image (all-layers) sampling: Recolor reads and writes the active layer only, as in Paint.NET.
- Clone Stamp (0056), pressure internals (0055), and extra blend modes (0059, which don't apply: Recolor has no blend mode).
