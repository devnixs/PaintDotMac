# 0058 — Add Paint.NET 5's extended shape library to the Shapes tool (Polygons & Stars, Arrows, Callouts, Symbols)

> Source: PRD.md §5.3 T-20 ("Extended shape library (arrows, stars, callouts, and so on)" — O — P1), T-19 (the Shapes tool this extends), §5.3 intro (O group, D-13/D-35/D-41), §8 v1.x ("extended shapes"), TOOL-C (settings persist), NF-9 (straight RGBA8), H-6 / D-34 (no-op edits add no step), D-19 (CoreGraphics in Core). Paint.NET docs: Shapes Tool, https://paint.net/doc/latest/ShapeTools.html (old URL https://www.getpaint.net/doc/latest/ShapeTools.html, revision of 27 Feb 2024): "Preset Shapes" (29 shapes in five groups) and "Pressing A cycles through the shapes when the Shapes tool is active ( Shift + A cycles backwards )".
> Milestone: v1.x
> Depends on: 0051-use-case-acceptance-tests (v1.0 complete; its UI helpers `choosePopUpItem`, `calibrateCanvas`, `dragPixels`, `actualSize`, `selectTool`, `setPrimaryColor` are reused). Builds directly on 0039-shapes-tool (`ShapeCatalog`, `ShapeKind`, `ShapeCatalogGroup`, `ShapesGeometry`, `ShapePaintPlan`, `ShapesOptions`, `ShapesTool`, the `toolOptions.shapeType` popup), 0038 (`ShapeRasterizer`, `ShapePaint`, `ShapeRenderParameters`, `EditableShapeEditor`), 0045 (`ShortcutTable` entries `shapes.nextShape` / `shapes.previousShape`), 0049 (accessibility labels of options-bar controls).

## Context

Not yet implemented: there is no application code. When this spec starts, 0039 has shipped the Shapes tool with Paint.NET 5's **Basic** group only (`0039-shapes-tool_TODO.md:38-63`):

- `enum ShapeCatalogGroup: String, CaseIterable, Sendable { case basic }` with the comment "0058 adds polygonsAndStars, arrows, callouts, symbols" (`0039…:40`).
- `enum ShapeKind: String, CaseIterable, Sendable, ToolOptionValue` with 8 cases `rectangle, roundedRectangle, ellipse, diamond, trapezoid, parallelogram, triangle, rightTriangle`, `displayName`, `group` (all `.basic`), `usesCornerRadius` (`0039…:41-47`).
- `enum ShapeCatalog` with `defaultCornerRadius`, `cornerRadiusRange`, `next(after:backward:)` (order = `ShapeKind.allCases`, wrapping), `unitPolygon(for:) -> [CGPoint]?` (unit square, u right, v down; nil for rectangle / rounded rectangle / ellipse), `localPath(for:in:cornerRadius:) -> CGPath?` (maps `x = box.minX + u·(box.maxX − box.minX)`, `y = box.minY + v·(box.maxY − box.minY)`, so a flipped `TransformBox` mirrors the shape; nil for a non-finite box or a side < 1e-9) (`0039…:48-63`). 0039 says "adding a kind (0058) means adding a case, its name, its group, and its unit polygon or builder".
- `ShapePaintPlan.paints(shape:mode:stroke:color:otherColor:)` turns any closed `CGPath` into the outline band (inside the shape), the full fill, or inset fill + band (`0039…:65-90`). It is shape-agnostic, so the new shapes need **no change** to it, to `ShapesGeometry`, to `ShapesTool`'s state machine, or to commit/history.
- The `toolOptions.shapeType` popup lists `ShapeKind.allCases` flat with a 16×16 preview of each from `ShapeCatalog.localPath` (`0039…:144`). 0051's use case 5 chooses "Rectangle" in it with `choosePopUpItem("toolOptions.shapeType", "Rectangle")` (`0051-use-case-acceptance-tests_TODO.md:90`), so item titles must stay plain shape names.
- A / Shift+A: `ShapesTool.keyDown` steps `ShapeCatalog.next(after:backward:)`; 0045 routes the keys through `ShortcutTable` entries `shapes.nextShape` (A) and `shapes.previousShape` (⇧A) (`0045-shortcut-audit_TODO.md:248-249,301`). Cycling therefore covers whatever `allCases` contains.

Paint.NET 5 behavior mirrored (ShapeTools.html, "Preset Shapes"; the page lists names but shows the shapes only as icons in "ShapeToolsDropdown.png"):

| Group | Shapes, in Paint.NET's order |
|---|---|
| Basic (0039) | Rectangle, Rounded Rectangle, Ellipse, Diamond, Trapezoid, Parallelogram, Triangle, Right Angle Triangle |
| Polygons & Stars | Pentagon, Hexagon, Heptagon, Octagon, Three-point Star, Four-point Star, Five-point Star, Six-point Star |
| Arrows | Arrow, Notched Arrow, Pentagon Arrow, Chevron Arrow |
| Callouts | Rectangular Callout, Rounded Rectangle Callout, Ellipse Callout, Cloud Callout |
| Symbols | Lightning Bolt, Check Mark, Multiply, Gear, Heart |

The docs give no proportions, so the exact geometry below is this spec's definition (Open question 2). The drop-down is grouped under group headings, and A / Shift+A cycle through all 29 shapes.

## User story

As a PaintDotMac user annotating a screenshot, I open the Shape type popup in the Shapes tool and see all 29 Paint.NET shapes under the headings Basic, Polygons & Stars, Arrows, Callouts, and Symbols, each with a small preview. I pick "Arrow" (or press A repeatedly to step through every shape, Shift+A to go back), drag a box, and get a right-pointing block arrow that fills the box and can be resized, flipped, moved, rotated, outlined, filled, or both, and committed as one "Shapes" step, exactly like a rectangle.

## Scope & changes

### Core (headless, unit-tested) — `PaintDotMac/Core/Tools/Shapes/ShapeCatalog.swift` (modify)

1. **`ShapeCatalogGroup`** gains cases, in this order (raw values frozen, persisted nowhere but used in accessibility identifiers):
   ```swift
   enum ShapeCatalogGroup: String, CaseIterable, Sendable {
       case basic, polygonsAndStars, arrows, callouts, symbols
       var displayName: String   // "Basic", "Polygons & Stars", "Arrows", "Callouts", "Symbols"
   }
   ```
2. **`ShapeKind`** gains 21 cases appended **after** `rightTriangle`, in the table order (raw values frozen; they are stored in `tool.shapes.shapeType`):
   `pentagon, hexagon, heptagon, octagon, threePointStar, fourPointStar, fivePointStar, sixPointStar, arrow, notchedArrow, pentagonArrow, chevronArrow, rectangularCallout, roundedRectangleCallout, ellipseCallout, cloudCallout, lightningBolt, checkMark, multiply, gear, heart`.
   - `displayName`: "Pentagon", "Hexagon", "Heptagon", "Octagon", "Three-point Star", "Four-point Star", "Five-point Star", "Six-point Star", "Arrow", "Notched Arrow", "Pentagon Arrow", "Chevron Arrow", "Rectangular Callout", "Rounded Rectangle Callout", "Ellipse Callout", "Cloud Callout", "Lightning Bolt", "Check Mark", "Multiply", "Gear", "Heart" (Paint.NET doc spelling; Open question 1).
   - `group`: per the table. Invariant: `allCases` is grouped contiguously in `ShapeCatalogGroup.allCases` order.
   - `usesCornerRadius` stays `true` only for `.roundedRectangle` (Open question 3).
3. **`ShapeCatalog`** additions:
   ```swift
   /// Kinds of one group, in allCases order. Never empty.
   static func kinds(in group: ShapeCatalogGroup) -> [ShapeKind]
   /// Unit-square path (u right, v down, bounding box exactly (0,0)–(1,1)) for kinds that need curves or
   /// boolean operations; nil for every other kind. Built once and cached (static let dictionary).
   static func unitCurvePath(for kind: ShapeKind) -> CGPath?
   ```
   - Every kind has **exactly one** source: a CGRect primitive (rectangle, roundedRectangle, ellipse — unchanged from 0039), `unitPolygon(for:)`, or `unitCurvePath(for:)`.
   - `localPath(for:in:cornerRadius:)`: for a `unitCurvePath` kind returns `unitPath.copy(using: &m)` with `m = CGAffineTransform(a: box.maxX − box.minX, b: 0, c: 0, d: box.maxY − box.minY, tx: box.minX, ty: box.minY)` (the same mapping as polygons, so a flipped box mirrors the shape); polygons are mapped exactly as in 0039. Degenerate/non-finite boxes → nil, unchanged.
   - `next(after:backward:)` is unchanged code; with the new cases it walks all 29 kinds (Heart → Rectangle forward, Rectangle → Heart backward).
   - **Invariant for all 29 kinds:** the tight bounding box (`boundingBoxOfPath`) of `localPath` equals the standardized box (within 1e-6 of the box size), i.e. every shape touches all four sides of the dragged box.

4. **Exact unit geometry** (v down; "→ normalized" means: build the points, then map their bounding box linearly onto (0,0)–(1,1), independently in u and v; polygon vertices in exactly this order, each polygon = `move` + `addLine`s + `closeSubpath`; values below are the normalized ones, rounded to 6 decimals in the spec — the implementation computes them from the formulas, the tests compare to these numbers within 1e-6). Unit areas are hand-computed (shoelace for polygons; analytic or 4000×4000-sample integration for curves) and are the test oracles.

   **Polygons & Stars** — regular polygons: vertex k = `(cos θk, sin θk)`, `θk = θ0 + 2πk/n`, `θ0 = −π/2` for odd n (a point on top), `−π/2 + π/n` for even n (a flat edge on top), k = 0…n−1, → normalized. Stars: 2n vertices alternating outer radius 1 and inner radius r, vertex k at angle `−π/2 + πk/n` (k = 0 is the top point), → normalized.

   | Kind | Definition | Normalized vertices | Unit area |
   |---|---|---|---|
   | pentagon | n = 5 | (0.5,0) (1,0.381966) (0.809017,1) (0.190983,1) (0,0.381966) | 0.690983 |
   | hexagon | n = 6 | (0.75,0) (1,0.5) (0.75,1) (0.25,1) (0,0.5) (0.25,0) | 0.75 |
   | heptagon | n = 7 | (0.5,0) (0.900969,0.198062) (1,0.643104) (0.722521,1) (0.277479,1) (0,0.643104) (0.099031,0.198062) | 0.738250 |
   | octagon | n = 8 | (0.707107,0) (1,0.292893) (1,0.707107) (0.707107,1) (0.292893,1) (0,0.707107) (0,0.292893) (0.292893,0) | 0.828427 |
   | threePointStar | n = 3, r = 0.35 | (0.5,0) (0.675,0.55) (1,1) (0.5,0.9) (0,1) (0.325,0.55) | 0.35 |
   | fourPointStar | n = 4, r = 0.4 | (0.5,0) (0.641421,0.358579) (1,0.5) (0.641421,0.641421) (0.5,1) (0.358579,0.641421) (0,0.5) (0.358579,0.358579) | 0.282843 |
   | fivePointStar | n = 5, r = (3 − √5)/2 = 0.381966 (regular pentagram) | (0.5,0) (0.618034,0.381966) (1,0.381966) (0.690983,0.618034) (0.809017,1) (0.5,0.763932) (0.190983,1) (0.309017,0.618034) (0,0.381966) (0.381966,0.381966) | 0.326238 |
   | sixPointStar | n = 6, r = 1/√3 = 0.577350 (regular hexagram) | (0.5,0) (0.666667,0.25) (1,0.25) (0.833333,0.5) (1,0.75) (0.666667,0.75) (0.5,1) (0.333333,0.75) (0,0.75) (0.166667,0.5) (0,0.25) (0.333333,0.25) | 0.5 |

   **Arrows** (all point right, +u; given directly, no normalization):

   | Kind | Vertices | Unit area |
   |---|---|---|
   | arrow | (0,0.25) (0.6,0.25) (0.6,0) (1,0.5) (0.6,1) (0.6,0.75) (0,0.75) — shaft half the box height, head 40% of the width | 0.5 |
   | notchedArrow | arrow's 7 vertices + (0.15,0.5) (a V notch in the tail) | 0.4625 |
   | pentagonArrow | (0,0) (0.75,0) (1,0.5) (0.75,1) (0,1) | 0.875 |
   | chevronArrow | (0,0) (0.75,0) (1,0.5) (0.75,1) (0,1) (0.25,0.5) | 0.75 |

   **Callouts** — body in the top 75% of the box, tail down-left. Shared tail triangle `T = (0.25,0.5) (0.45,0.5) (0.15,1)` (its base lies inside every body, so the union is one outline; the part below v = 0.75 is the triangle (0.2,0.75) (0.3,0.75) (0.15,1), area 0.0125).

   | Kind | Definition | Unit area |
   |---|---|---|
   | rectangularCallout | polygon (0,0) (1,0) (1,0.75) (0.3,0.75) (0.15,1) (0.2,0.75) (0,0.75) (= rect ∪ T) | 0.7625 |
   | roundedRectangleCallout | `unitCurvePath`: `CGPath(roundedRect: (0,0,1,0.75), cornerWidth: 0.1, cornerHeight: 0.1)` `.union(T, using: .winding)` | 0.75 − (4 − π)·0.01 + 0.0125 = 0.753916 |
   | ellipseCallout | `unitCurvePath`: ellipse in (0,0,1,0.75) `.union(T, using: .winding)` | 0.606416 (integrated) |
   | cloudCallout | `unitCurvePath`: body = union of the ellipse centered (0.5,0.4) with radii (0.3,0.2) and six circles of radius 0.2 centered (0.25,0.25), (0.5,0.2), (0.8,0.3), (0.7,0.55), (0.4,0.55), (0.2,0.45); plus two separate "thought bubble" circles of radius 0.05 centered (0.2,0.84) and (0.1,0.95) (disjoint from the body and each other). Built with successive `union(_:using: .winding)`. Bounding box: left = circle (0.2,0.45) → 0, right = circle (0.8,0.3) → 1, top = circle (0.5,0.2) → 0, bottom = bubble (0.1,0.95) → 1. | 0.588060 (integrated; body alone 0.572350) |

   **Symbols:**

   | Kind | Definition | Unit area |
   |---|---|---|
   | lightningBolt | polygon (0.3,0) (0.8,0) (0.55,0.38) (1,0.38) (0,1) (0.35,0.58) (0.1,0.58) | 0.377 |
   | checkMark | polygon (0,0.6) (0.15,0.45) (0.4,0.7) (0.85,0) (1,0.15) (0.4,1) | 0.27375 |
   | multiply | polygon (0.2,0) (0.5,0.3) (0.8,0) (1,0.2) (0.7,0.5) (1,0.8) (0.8,1) (0.5,0.7) (0.2,1) (0,0.8) (0.3,0.5) (0,0.2) — an X with 45° arms | 0.56 |
   | gear | `unitCurvePath`: 8 teeth. Outer polygon of 32 vertices centered (0.5,0.5): for tooth k = 0…7 with center angle `φk = −90° + 45°·k`, the vertices at angles `φk − 15°` (radius 0.4), `φk − 7.5°` (radius `0.5 / cos 7.5°` = 0.504314), `φk + 7.5°` (same), `φk + 15°` (radius 0.4) — so tooth tips are flat and the outermost tip edges lie exactly on u, v = 0 and 1. First tooth: (0.396472,0.113630) (0.434174,0) (0.565826,0) (0.603528,0.113630). Then `.subtracting(circle center (0.5,0.5) radius 0.15, using: .winding)` (the axle hole). | 0.568907 (shoelace 0.639593 − π·0.15²) |
   | heart | `unitCurvePath`: move (0.5,1); cubic curves (control1, control2, end): ((0.1,0.7), (0,0.5), (0,0.3)); ((0,0.12), (0.12,0), (0.25,0)); ((0.38,0), (0.5,0.1), (0.5,0.22)); ((0.5,0.1), (0.62,0), (0.75,0)); ((0.88,0), (1,0.12), (1,0.3)); ((1,0.5), (0.9,0.7), (0.5,1)); close. Symmetric about u = 0.5; lobes touch v = 0 at u = 0.25 and 0.75; the dip is at (0.5,0.22). | 0.707860 (integrated) |

   - None of these polygons self-intersects (checked by hand; pinned by `ShapeCatalogTests.polygonsAreSimple`). All are non-convex or convex simple polygons, so `.winding` and even-odd agree.
   - Boolean results (`union`, `subtracting`, macOS 13+, CoreGraphics — allowed in Core by D-19) are computed once in unit space and cached; mapping to a box is one affine copy, so re-rendering a pending shape during a nub drag costs no boolean operations.

5. **No change** to `ShapePaintPlan`, `ShapesGeometry`, `ShapesOptions` (unknown stored raw values still load as `.rectangle`; the new raw values load as their kinds), `ShapesTool`'s gestures, A / Shift+A handling, `EditableShapeEditor`, commit/cancel, or history: each committed shape is still one "Shapes" step (`HistoryIcon.shapes`), a no-op adds no step, Escape restores `before`. Multi-subpath shapes (Cloud Callout's bubbles, Gear's hole) go through the same `outlineBand`/`insetFill` boolean operations, so the outline traces every subpath (including inside the hole) and stays inside the shape.

### Platform glue (AppKit/SwiftUI; UI tests and manual checks)

6. **`PaintDotMac/UI/ToolOptions/ShapeTypePopUp.swift`** (new; it replaces the inline `toolOptions.shapeType` popup that 0039 builds in `UI/ToolOptionsBar.swift` (`0039…:144`), which now hosts this view — one implementation): an `NSViewRepresentable` around `NSPopUpButton` (pull-down off) so the grouped menu is native. Menu layout: for each `ShapeCatalogGroup` in order, `NSMenuItem.sectionHeader(title: group.displayName)` (macOS 14+, non-selectable), then one item per `ShapeCatalog.kinds(in:)` with `title = kind.displayName`, `image` = 16×16 template preview stroked from `ShapeCatalog.localPath(for:in: box (1.5,1.5)–(14.5,14.5), cornerRadius: 3)` at 1 pt (filled shapes' previews are outlines too), `representedObject = kind.rawValue`, `identifier = "toolOptions.shapeType.<rawValue>"`. Group headers have identifier `toolOptions.shapeType.group.<group rawValue>`. A separator item precedes every header except the first. The popup keeps identifier `toolOptions.shapeType`, its 0039/0049 accessibility label unchanged, and shows the selected kind's title + preview as its value. Choosing an item saves through `ShapesOptions.save` and calls `optionsDidChange` (live re-render of a pending shape), exactly as 0039. When the stored kind changes from elsewhere (A / Shift+A) the popup's selection follows (it observes the tool's options model as 0039's popup does).
   - Accessibility (0049): the popup keeps its existing catalog entry (`toolOptions.shapeType`, "Shape type", `selectedTitle`); its menu items and section headers are menu content, which 0049 does not catalogue (0049's audit runs with menus closed), so no catalog change.
   - The menu structure is computed by a pure, unit-tested `ShapeCatalog.menuSections: [(group: ShapeCatalogGroup, kinds: [ShapeKind])]` (Core), so the view only renders it.
7. `project.yml`: no change beyond the new file; run `xcodegen generate`.
8. **No PRD edit in this spec** (sub-agent rule). Open questions 1–4 record the decisions to add next to T-20 in PRD §5.3 / §12 once confirmed.

### Updated tests owned by 0039 (they assert the Basic-only catalog and must change in this spec)

- `ShapeCatalogTests.kindsAndNames` → now asserts all 29 cases (see below). `ShapeCatalogTests.nextWraps` → `next(after: .heart) == .rectangle`, backward from `.rectangle` = `.heart`, `next(after: .rightTriangle) == .pentagon`.
- `ShapesToolTests.optionsRoundTripThroughStore`: its unknown-value probe `"hexagon"` is now a valid kind; change it to `"decagon"` → `.rectangle`, and add `"hexagon"` → `.hexagon`.
- `ShapesToolTests.aKeyCyclesShapes`: the step "Shift+`a` again → `rightTriangle`" becomes "→ `heart`".
- `ShapeCoverageTests.aliasedIsBinary` and `renderIsPureFunctionOfBefore` iterate `ShapeKind.allCases` (29 kinds) instead of the Basic list.
- Everything else in 0039's and 0051's suites runs unchanged.

## Acceptance criteria

- [ ] The catalog has exactly 29 kinds in Paint.NET's order, with the names and groups in the table; raw values are stable; each kind has exactly one geometry source. → `ShapeCatalogTests.kindsAndNames`, `.groupsAreContiguous`, `.kindsInGroup`, `.exactlyOneSource`
- [ ] The Shape type popup shows five headed groups (Basic, Polygons & Stars, Arrows, Callouts, Symbols) with the shapes of each in order, a preview per item, and choosing any item selects that shape. → `ShapeCatalogTests.menuSections`, `ShapeLibraryUITests.pickerIsGroupedAndSelects`
- [ ] A cycles forward and Shift+A backward through all 29 shapes in catalog order, wrapping between Heart and Rectangle. → `ShapeCatalogTests.nextWraps`, `.fullCycleVisitsAll`, `ShapesToolTests.aKeyCyclesShapes`, `ShapeLibraryUITests.aKeyCyclesAcrossGroups`
- [ ] Every new shape's unit geometry matches this spec's vertices / curve definitions, touches all four sides of the box, and its filled coverage matches the hand-computed area and inside/outside sample pixels; aliased coverage is binary. → `ShapeCatalogTests.unitPolygons`, `.unitCurvePaths`, `.boundingBoxIsBox`, `.polygonsAreSimple`, `ShapeLibraryCoverageTests.*`
- [ ] Outline, Filled Shape, and Filled Shape with Outline work for every new shape: the outline stays inside the shape, and Filled Shape with Outline in one color equals Filled Shape. → `ShapeLibraryCoverageTests.outlineInsideFill`, `.outlinePlusInsetEqualsFill`, `.arrowOutlineWidth2`, `.gearHoleOutlined`
- [ ] A flipped box mirrors asymmetric shapes (an arrow dragged past its left nub points left). → `ShapeLibraryCoverageTests.flippedArrowPointsLeft`, `ShapeLibraryToolTests.dragPastOppositeFlipsArrow`
- [ ] Drawing one shape from each new group (Hexagon, Arrow, Rectangular Callout, Multiply) and saving gives the expected pixels in the PNG; each is one "Shapes" history step that undo/redo round-trips. → `ShapeLibraryIntegrationTests.oneShapePerGroupSavedPNG`, `.undoRedoEveryKind`, `ShapeLibraryUITests.drawOneShapePerGroupSavePNG`
- [ ] Commit/cancel/history semantics are 0039's, unchanged (one "Shapes" step; Escape no step; no-op no step). → `ShapeLibraryToolTests.commitAndCancelPerGroup`, existing `ShapesToolTests.*`, `ShapesIntegrationTests.*`
- [ ] New raw values persist under `tool.shapes.shapeType` and reload. → `ShapeLibraryToolTests.newKindsPersist`, `ShapeLibraryUITests.newKindPersistsAcrossRelaunch`
- [ ] 0039's and 0051's suites stay green (with the five updated 0039 assertions listed above). The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Stored kind from a newer/older build** unknown (e.g. `"star7"`) → `.rectangle` (0039 rule). → `ShapeLibraryToolTests.newKindsPersist`
- **Non-square boxes** stretch every shape (circles in Gear/Heart/Cloud become ellipses, stars become squashed); this is intended (Paint.NET shapes stretch to the box). Shift keeps a square box. → `ShapeLibraryCoverageTests.nonSquareBoxStretches`
- **Tiny boxes** (1×1, 2×3, 1×200) with multi-subpath and boolean shapes → render without crash; aliased coverage binary; covered pixels ⊆ box. → `ShapeLibraryCoverageTests.tinyBoxes`
- **Very wide outline** (width ≥ half the smaller side) → band = whole shape, inset fill empty (0039 rule), including Gear (the hole stays empty) and Cloud Callout (bubbles fully outline-colored). → `ShapeLibraryCoverageTests.wideOutlineEqualsShape`
- **Gear hole**: Filled Shape leaves the hole at the layer's `before` pixels; the center pixel of a 64×64 gear is untouched. → `ShapeLibraryCoverageTests.gearHoleOutlined`
- **Cloud bubbles** are separate subpaths: both get an outline in Shape Outline mode and stay disjoint from the body. → `ShapeLibraryCoverageTests.cloudBubblesOutlined`
- **Rotated library shapes** (right-drag, 0039) render through the same `rigid` transform; a rotated arrow at 90° points down. → `ShapeLibraryToolTests.rotatedArrowPointsDown`
- **Corner size** while a non–Rounded Rectangle kind (including Rounded Rectangle Callout) is selected → the field is disabled and the value is ignored (Open question 3). → `ShapeLibraryToolTests.cornerRadiusIgnoredForCallout`
- **Cycling mid-gesture / with modifiers / key repeat** → unchanged 0039/0045 rules (ignored). Covered by `ShapesToolTests.aKeyCyclesShapes`.
- **Huge shape** (4000×3000 Cloud Callout, Filled Shape with Outline, width 40) → completes; per-tile coverage, memory independent of canvas size. → `ShapeLibraryCoverageTests.hugeCloudCompletes`

## Test plan

Expected values are hand-computed, independent of CoreGraphics: polygon areas by the shoelace formula, curve areas by 4000×4000 point sampling of the analytic definitions above, sample pixels by checking that the pixel and its 1 px neighbourhood lie entirely inside or outside the analytic shape. Conventions as in 0039: `W = (255,255,255,255)`, `P = (0,0,0,255)`, `R = (255,0,0,255)`, `B = (0,0,255,255)`; coverage via `ShapeRasterizer.coverage(of:fillRule: .winding, antialiasing:, in:)` on the paths from `ShapePaintPlan.paints(...)` for `ShapesGeometry.creating(...)`; "box64" = box (0,0)–(64,64) in region (0,0,64,64), so unit area × 4096 = pixel area; a sample pixel listed as "in" is fully covered (255) and "out" is 0, both chosen at least 1 px away from any edge.

- **Unit — `PaintDotMacTests/Tools/Shapes/ShapeCatalogTests.swift`** (extend 0039's file):
  - `kindsAndNames`: `ShapeKind.allCases.map(\.rawValue)` equals the 29 raw values in order (8 Basic from 0039, then the 21 listed); `displayName`s exactly as listed; `group` per the table; `usesCornerRadius` true only for `.roundedRectangle`; `ShapeCatalogGroup.allCases.map(\.displayName) == ["Basic", "Polygons & Stars", "Arrows", "Callouts", "Symbols"]`.
  - `groupsAreContiguous`: walking `allCases`, the group index never decreases.
  - `kindsInGroup`: `kinds(in:)` counts 8, 8, 4, 4, 5 and first/last `.rectangle/.rightTriangle`, `.pentagon/.sixPointStar`, `.arrow/.chevronArrow`, `.rectangularCallout/.cloudCallout`, `.lightningBolt/.heart`.
  - `menuSections`: 5 sections in group order whose kinds concatenate to `allCases`.
  - `nextWraps`: as listed under "Updated tests". `fullCycleVisitsAll`: 29 forward steps from `.rectangle` visit every kind once and return to `.rectangle`; 29 backward steps likewise in reverse order; backward is the inverse of forward for every kind.
  - `exactlyOneSource`: for each kind, exactly one of {rectangle/roundedRectangle/ellipse, `unitPolygon != nil`, `unitCurvePath != nil`} holds; curve kinds are exactly roundedRectangleCallout, ellipseCallout, cloudCallout, gear, heart.
  - `unitPolygons`: every polygon kind's vertex list equals the table within 1e-6 (count and order).
  - `unitCurvePaths`: heart path elements: 1 move to (0.5,1), 6 `addCurve`s with exactly the listed points, 1 close; gear/callout paths non-nil and non-empty.
  - `boundingBoxIsBox`: for all 29 kinds, `localPath(for:in: box (10,20)–(74,52), cornerRadius: 20)!.boundingBoxOfPath` equals (10,20,64,32) within 1e-6 (curves: tight box, not control points).
  - `polygonsAreSimple`: test-side O(n²) segment-intersection check on every unit polygon → no two non-adjacent edges intersect; each polygon's |shoelace area| equals the table (±1e-6).
  - `flippedMirrors`: arrow `localPath` in a box with minX 64, maxX 0 equals the unit arrow mirrored about u = 0.5 (vertex (1,0.5) maps to x 0).
- **Unit — `PaintDotMacTests/Tools/Shapes/ShapeLibraryCoverageTests.swift`** (new):
  - `filledAreas` (box64, Filled Shape, AA on): Σc/255 within 1% of unit area × 4096 for each new kind — pentagon 2830.27, hexagon 3072, heptagon 3023.87, octagon 3393.24, threePointStar 1433.60, fourPointStar 1158.52, fivePointStar 1336.27, sixPointStar 2048, arrow 2048, notchedArrow 1894.40, pentagonArrow 3584, chevronArrow 3072, rectangularCallout 3123.20, roundedRectangleCallout 3088.04, ellipseCallout 2483.88, cloudCallout 2408.69, lightningBolt 1544.19, checkMark 1121.28, multiply 2293.76, gear 2330.24, heart 2899.39. Aliased: count of 255s within 2% of the same numbers.
  - `samplePixels` (box64, Filled Shape, AA on and off; "in" = 255, "out" = 0):
    | Kind | in | out |
    |---|---|---|
    | pentagon, hexagon, heptagon, octagon | (32,32), (32,8), (32,56), (8,32) | (2,2), (61,2), (2,61), (61,61) |
    | threePointStar | (32,32), (32,8), (16,48) | (8,32), (56,32), (2,2) |
    | fourPointStar | (32,32), (32,8), (8,32) | (2,2), (61,61) |
    | fivePointStar | (32,32), (32,8), (32,20) | (32,56), (2,2), (61,2) |
    | sixPointStar | (32,32), (32,8), (32,56) | (56,32), (2,2) |
    | arrow | (32,32), (8,32), (56,32), (48,16) | (32,8), (32,56), (2,2) |
    | notchedArrow | (32,32), (56,32), (48,16) | (2,32) (the notch), (32,8), (32,56) |
    | pentagonArrow | (32,32), (32,8), (8,32) | (61,2), (61,61) |
    | chevronArrow | (32,32), (32,8), (56,32) | (8,32), (2,32), (61,2) |
    | rectangularCallout | (32,32), (32,8), (8,32), (14,51) (tail) | (32,56), (2,61), (61,61) |
    | roundedRectangleCallout | (32,32), (32,8), (8,32) | (0,0), (32,56), (61,61) |
    | ellipseCallout | (32,32), (32,8), (8,32), (56,32) | (32,56), (2,2), (61,2) |
    | cloudCallout | (32,32), (32,8), (16,16), (13,54) and (6,61) (the bubbles) | (32,56), (2,2), (61,61), (32,52), (20,58) (between body and bubbles) |
    | lightningBolt | (32,32), (32,8), (16,16) | (32,56), (56,32), (2,2) |
    | checkMark | (48,16), (16,48), (32,44) | (32,8), (56,32), (2,2) |
    | multiply | (32,32), (16,16), (48,16), (16,48) | (32,8), (32,56), (8,32), (56,32) |
    | gear | (32,8), (32,56), (8,32), (56,32) | (32,32) (hole), (2,2), (61,61) |
    | heart | (32,32), (32,56), (8,32), (56,32), (16,8), (48,8) (the lobes) | (2,2), (61,2), (2,61), (32,4) (above the dip) |
  - `outlineInsideFill` (property; all 29 kinds × widths {1, 2, 5} × AA on/off, box64 and box (3,5)–(90,47)): every outline-band coverage ≤ the filled coverage of the same pixel + 1, and no covered pixel lies outside the box.
  - `outlinePlusInsetEqualsFill` (all 29 kinds, width 3, AA on, box64): rendering Filled Shape with Outline with `color == otherColor == P` over W equals rendering Filled Shape with P, each channel within ±2 (the seam between inset fill and band is under fully covered band pixels).
  - `arrowOutlineWidth2` (box64, Shape Outline, width 2, aliased; hand-derived as "pixel center inside the arrow and within 2 px of its outline"): row 32 (shaft middle): exactly x 0, 1 (tail edge) and 61, 62, 63 (tip) = 255, x 2…60 = 0; column 8: exactly y 16, 17 (top shaft edge at v 0.25 → y 16) and 46, 47 = 255; row 4: x 37 = 0 (outside), x 38, 39 = 255 (the head's vertical back edge at x = 0.6·64 = 38.4), x 40, 41 = 255 (the slanted edge's band), x 42…63 = 0; (45,32) = 0 (head interior).
  - `gearHoleOutlined` (box64, width 2, AA on): Filled Shape → c(32,32) = 0 (hole radius 9.6 px); Shape Outline → c(32,32) = 0, c(32,23) = 255 (hole edge at y 22.4; band covers y 22.4…24.4 on the material side), c(32,4) = 0 (tooth interior beyond the 2 px band: tooth spans y 0…7.3).
  - `cloudBubblesOutlined` (box64, Shape Outline, width 1, AA on): both bubbles (radius 3.2 px, centers (12.8,53.76) and (6.4,60.8)) have Σc/255 within 10% of the annulus area π(3.2² − 2.2²) = 16.97 each (measured over their own 8×8 windows); (20,58) and (32,52) are 0.
  - `flippedArrowPointsLeft`: `ShapesGeometry(session: TransformSession(sourceBounds: (0,0,64,64)))` then `moveHandle(7 /* left */, to: (128,32), constrained: false)` → box minX 128, maxX 64 (x = 128 − 64u); region (64,0,64,64), fill, AA: tip pixel c(64,32) > 0; (125,32) = 255 (tail end of the shaft, u 0.04); (125,2) = 0; (86,8) = 255 (head, u 0.65, v 0.13); (120,8) = 0 (above the shaft).
  - `nonSquareBoxStretches`: Five-point Star in box (0,0)–(128,64): Σc/255 within 1% of 0.326238·8192 = 2672.54; heart in (0,0)–(64,128): within 1% of 5798.79.
  - `tinyBoxes`: every kind in boxes 1×1, 2×3, 1×200, 200×1 at (5,5), AA on/off: completes; covered pixels ⊆ the box; AA-off values ∈ {0,255}.
  - `wideOutlineEqualsShape`: box (10,10)–(30,30), width 12, every new kind: band coverage == fill coverage (±1); `insetFill` bounding box empty.
  - `hugeCloudCompletes`: 4000×3000 W, cloudCallout box (0,0)–(4000,3000), Filled Shape with Outline width 40, color P, otherColor B, rendered with `ShapeRasterizer.render` → (2000,1200) = B (body interior: unit (0.5,0.4)), (2000,15) = P (the top of circle (0.5,0.2) is at y 0; band 0…40), (0,0) = W, (400,2850) = B (bubble (0.1,0.95) center), (3990,2990) = W.
- **Unit — `PaintDotMacTests/Tools/ShapeLibraryToolTests.swift`** (new; `FakeToolContext`, 300×300 W, `InMemoryToolOptionStore`, 0039's "draw" = down (50.4,60.2) → (149.6,120.4), box (50,60)–(150,120)):
  - `newKindsPersist`: for each of the 21 new kinds, `ShapesOptions(kind:).save` → `tool.shapes.shapeType == rawValue`, reload equal; `"star7"` → `.rectangle`.
  - `commitAndCancelPerGroup` (hexagon, arrow, rectangularCallout, multiply, gear; Filled Shape): draw → pending, pixels changed, no `commitHistory`; Return → exactly one `commitHistory` named "Shapes", icon `.shapes`; draw again, Escape → layer tiles `sharesStorage` with before, no commit.
  - `dragPastOppositeFlipsArrow`: arrow, fill; drag the right nub (150,90) to (0,90) → box minX 50, maxX 0 (x = 50 − 50u, the tip is now at x 0); (2,90) = P (head near the tip, u 0.95), (45,90) = P (shaft, u 0.09), (48,62) = W (u 0.03, v 0.04: above the shaft), (100,90) = W (old shaft area).
  - `rotatedArrowPointsDown`: arrow, fill, box (50,60)–(150,120); right-drag from (200,90) to (100,190) (0039's 90° rotation) → frame ≈ (70,40)–(130,140); the tip (unit (1,0.5)) is at ≈ (100,140): c(100,137) is black within ±1; (100,43) (tail middle) black; (72,135) (beside the tip) = W ±1.
  - `cornerRadiusIgnoredForCallout`: roundedRectangleCallout with cornerRadius 0 and 1000 → identical pixels.
  - `pickerChangeRerendersPendingLibraryShape`: pending rectangle (Shape Outline, width 2: (50,60) = P); store kind `.heart` + `optionsDidChange` → (50,60) = W (outside the heart's corner), (100,90) = W (interior), still pending; store drawMode `.fill` + `optionsDidChange` → (100,90) = P.
- **Integration — `PaintDotMacTests/Integration/ShapeLibraryIntegrationTests.swift`** (0005 New Image 400×300 W, `UndoBridge`, forwarding `ToolContext`, `ShapesTool`, Filled Shape, AA off, primary P):
  - `oneShapePerGroupSavedPNG`: draw hexagon in box (20,20)–(120,120), arrow in (140,20)–(240,120), rectangularCallout in (260,20)–(360,120), multiply in (20,160)–(120,260) (each: drag with 0039's snapped corner points, Return); history `["New Image", "Shapes", "Shapes", "Shapes", "Shapes"]`; save with 0005's `ImageEncoder` (PNG) to a temp URL, decode with `ImageDecoder`; assert: hexagon in (70,70), (30,70), out (22,22), (118,118); arrow in (150,70) (shaft), (230,70) (near tip), out (150,30), (150,110); callout in (310,50) (body), (282,97) (tail: unit (0.225,0.775), where the tail spans u 0.195…0.285), out (272,104) (left of the tail: unit (0.125,0.845), tail spans 0.181…0.243), (350,110); multiply in (70,210), (35,175), out (70,170), (35,210); every pixel elsewhere = W; every pixel is exactly W or P (aliased).
  - `undoRedoEveryKind`: for each of the 21 new kinds (and 3 seeded random options each: mode, width 1…20, dash, AA, button, box, optional rotation; seed printed): draw + Return → one "Shapes" step; undo → tiles equal the original; redo → equal the committed snapshot; the diff's tile set ⊆ the tiles touched by the shape's (rotated) bounding box.
- **UI — `PaintDotMacUITests/ShapeLibraryUITests.swift`** (new; fixture 400×300 opaque white via `UITestApp.makePNG`, `resetDefaults: true`, `UITestApp.useCaseArguments`, 0051 helpers):
  - `pickerIsGroupedAndSelects`: `selectTool("shapes")`; click `toolOptions.shapeType`; the open menu contains the five headers `toolOptions.shapeType.group.basic` … `.symbols` with titles "Basic", "Polygons & Stars", "Arrows", "Callouts", "Symbols" in that vertical order, and 29 selectable items whose titles in vertical order equal the catalog; each header is above its group's items; press Escape. `choosePopUpItem("toolOptions.shapeType", "Five-point Star")` → value "Five-point Star"; `toolOptions.cornerRadius` disabled; then "Rounded Rectangle" → enabled.
  - `aKeyCyclesAcrossGroups`: choose "Right Angle Triangle"; click the canvas once (focus; no step); type `a` → popup "Pentagon"; Shift+`a` → "Right Angle Triangle"; choose "Rectangle"; Shift+`a` → "Heart"; `a` → "Rectangle".
  - `drawOneShapePerGroupSavePNG`: `actualSize()`; `map = calibrateCanvas(imageWidth: 400, imageHeight: 300)`; `clearCanvasOfPanels(map:)`; `setPrimaryColor(hex: "000000")`; `choosePopUpItem("toolOptions.drawMode", "Filled Shape")`; `setCheckbox("toolOptions.antialiasing", on: false)`; for (name, from, to) in [("Hexagon", (20,20), (120,120)), ("Arrow", (140,20), (240,120)), ("Rectangular Callout", (260,20), (360,120)), ("Multiply", (20,160), (120,260))]: `choosePopUpItem("toolOptions.shapeType", name)`, `dragPixels(from:to:map:)`, click `toolOptions.finish`; `historyRowNames()` ends with four "Shapes"; ⌘S; read the PNG: the same in/out samples as `oneShapePerGroupSavedPNG` (they keep ≥ 3 px from every edge, so the ±1 px from snapping pixel-center drags does not matter); pixels outside the four boxes (outset 2 px) are W. ⌘Z → three "Shapes" rows; ⌘S; the Multiply samples are W.
  - `newKindPersistsAcrossRelaunch`: choose "Gear", quit, relaunch with `resetDefaults: false` → popup value "Gear".
- **Performance** — extend `PaintDotMacTests/Performance/ShapesPerformanceTests.swift` (XCTest `measure`, report only): re-render of a pending antialiased Filled Shape with Outline Cloud Callout and Gear, width 20, dashed, spanning 4000×3000 (NF-1 nub-drag responsiveness); `unitCurvePath` is cached, so per-render time should be within 1.5× of 0039's ellipse number — record both in the Verification status. NF-4 unchanged (diffs hold touched tiles only).
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green (clean build, no warnings, all tests pass, none skipped, UI tests ran, launch smoke).
- **Manual verification:**
  1. Open the Shape type popup in light and dark mode: five group headings, 29 previews that are legible template images, and the selected item's preview in the closed popup.
  2. Draw every new shape at 100% and 800% in all three draw modes, widths 1, 8, 40, AA on/off: shapes fill the dragged box, outlines stay inside, no fill fringe outside the outline, the Gear's hole and the Cloud's bubbles are outlined, and Shift draws them undistorted.
  3. Resize, flip past the opposite nub, move, rotate (Shift 15°), and nudge an Arrow, a Five-point Star, and a Cloud Callout on a 4000×3000 image: no lag.
  4. Press A repeatedly with the Shapes tool active: the popup steps through all 29 shapes and wraps; Shift+A goes back.
  5. Compare each shape side by side with Paint.NET 5's (on Windows, if available) and note proportion differences for Open question 2.

## Open questions

1. **Display names.** The Paint.NET docs page lists "Pentagon (5), Hexagon (6), Heptagon (7) & Octagon (8)" and "Three-point Star … Six-point Star"; the in-app drop-down labels aren't shown as text. This spec uses "Pentagon", "Hexagon", "Heptagon", "Octagon", "Three-point Star", "Four-point Star", "Five-point Star", "Six-point Star", "Arrow", "Notched Arrow", "Pentagon Arrow", "Chevron Arrow", "Rectangular Callout", "Rounded Rectangle Callout", "Ellipse Callout", "Cloud Callout", "Lightning Bolt", "Check Mark", "Multiply", "Gear", "Heart" (no point counts in parentheses, lowercase "point" as in the docs). Recommended: yes; record in PRD T-20.
2. **Exact proportions.** Paint.NET's docs show the shapes only as icons, so this spec defines every shape's geometry itself (the tables in Scope item 4): regular polygons and stars normalized to fill the box (odd polygons point up, even ones flat on top), star inner radii 0.35 / 0.4 / pentagram 0.381966 / hexagram 0.577350, right-pointing arrows (shaft half the height, head 40% of the width), callouts with the body in the top 75% and a tail down-left, an 8-tooth gear with a 0.15 hole, a two-lobe Bézier heart, a seven-lobe cloud with two thought bubbles. Every shape touches all four sides of the dragged box. Recommended: accept these proportions for v1.x and adjust later only if a side-by-side comparison with Paint.NET shows a clear mismatch; record "geometry as defined in spec 0058" in PRD T-20.
3. **Corner size for Rounded Rectangle Callout.** Paint.NET's docs tie Corner Size to the Rounded Rectangle. This spec gives the Rounded Rectangle Callout a fixed corner radius of 10% of the box width/height (it scales with the box) and keeps the Corner size field disabled for it. Recommended: yes.
4. **Grouped picker.** The Shape type popup shows non-selectable group headings (Basic, Polygons & Stars, Arrows, Callouts, Symbols) with separators, like Paint.NET 5's grouped drop-down; A / Shift+A cycle across all groups in that order and wrap between Heart and Rectangle. Recommended: yes; record in PRD T-20 and §5.12 next to the A / Shift+A line.

## Out of scope

- Custom shapes (Paint.NET's XAML shape files / plug-in shapes) and any shape not in Paint.NET 5's built-in list.
- Fill Styles (patterns), Selection Quality, movable rotation point, live recoloring — as 0039 (Open question 3/5 there).
- Changes to Line / Curve (0038), Text (0040), or to the Shapes tool's gestures and history semantics (0039).
- Shortcut-table changes: 0045's `shapes.nextShape` / `shapes.previousShape` already cover A / Shift+A.
- Tablet pressure (0055).
