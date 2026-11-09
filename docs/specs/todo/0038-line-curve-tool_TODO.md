# 0038 — Add the Line / Curve tool (editable Bézier nubs, dash styles, arrowheads) and the shared editable-shape infrastructure

> Source: PRD.md §5.3 T-18 ("Line / Curve — O — Editable Bézier handles before committing. Dash styles and arrowheads."), §5.3 intro (O group: Line / Curve → Shapes, D-13/D-35/D-41 cycling), TOOL-A (left = primary, right / Control-left = secondary), TOOL-B (confined to the selection), TOOL-C (settings persist), APP-4 (tool options bar, Finish button), §5.12 (`[` / `]` brush width), NF-9 (straight RGBA8), NF-4 (undo stores changed tiles only), H-6 / D-34 (no-op edits add no step), D-15 (tool blend list = implemented layer blend modes), D-17 (`UserBlendOps`), D-19 (CoreGraphics allowed in Core). Paint.NET docs: Line/Curve Tool, https://paint.net/doc/latest/LineCurveTool.html (old URL https://www.getpaint.net/doc/latest/LineCurveTool.html); Tool Bar, https://paint.net/doc/latest/Toolbar.html (Brush Width, Antialiasing, Blend Mode, Finish).
> Milestone: M5
> Depends on: 0037-flip-and-rotate-image (ordering only); functionally on 0023-gradient-tool (pending-edit + handles precedent, `GradientGeometry.snapped`), 0020 (`PendingEditReason`, `prepareForHistoryNavigation`), 0013 (selection clip), 0009 (`BlendOps`, `BrushOptions.widthRange`, `BrushWidthAdjustable`, `BrushClipMask`), 0008 (history), 0006 (tool framework), and through them 0002/0003/0007.

## Context

Not yet implemented: there is no application code. This spec builds on these types from lower-numbered specs (use their exact names and signatures):

- **0002**: `ColorRGBA8` (`.clear`), `PixelRect` (half-open), `PixelSize`, `TileCoordinate`, `TiledSurface` (256×256 sparse COW tiles; `pixel(at:)`, `tile(at:)`/`setTile(_:at:)`, `Tile.sharesStorage(with:)`, `generation`/`changedTiles(since:)`), `Layer` (`id`, `surface`), `LayeredImage` (`size`, `layers`, `activeLayerIndex`), `BlendMode`.
- **0003 / 0013**: `CanvasTransform` (`canvasToView(_:)`, `viewToCanvas(_:)`, view space = AppKit points, bottom-left origin) and `canvasToViewAffine` (overlays must use it; never flip Y inline).
- **0006**: `@MainActor protocol Tool` (`hasPendingEdit`, `activate`/`deactivate` (default commits), `mouseDown/Dragged/Up/Moved`, `keyDown` default (Return/Enter → commit, Escape → cancel while pending), `cursor(at:modifiers:)`, `commit(context:)`, `cancel(context:)`, `optionsDidChange(context:)`), `ToolEvent` (`location` canvas space Double top-left y-down; `viewLocation`; `button` `.primary/.secondary` with Control-left → `.secondary`; `modifiers`; `clickCount`), `ToolKey`/`ToolKeyEvent` (arrow keys), `ToolContext` (`image`, `transform`, `options`, `setOverlay(_:)`, `invalidateCursor()`), `ToolOverlay`, `ToolCursor`, `ToolID.lineCurve`, descriptor row `lineCurve | Line / Curve | o | textAndShape | line.diagonal | supportsPendingEdits true` (unchanged here), `ToolRegistry.standard()`, `ToolOptionKey(tool:name:defaultValue:range:)`, `ToolOptionStore`, `ToolOptionValue` (String raw-value enums opt in), `InMemoryToolOptionStore`, `ToolDispatcher.commitPendingEdit()`, `UI/ToolOptionsBar.swift` (`ToolOptionsContent`; Finish `toolOptions.finish` visible iff `supportsPendingEdits`, enabled iff pending), `Canvas/ToolOverlayView.swift`, `FakeToolContext`.
- **0007**: `ToolContext.colors: ColorSelection` (`.primary` default black, `.secondary` default white).
- **0008**: `TileDiff.between(before:after:layerID:candidates:)`, `TileDiffHistoryItem(name:icon:diff:)` (no step when the diff is empty), `HistoryIcon.lineCurve` (already a case; 0010 already maps it to `line.diagonal`), `ToolContext.commitHistory(_:)`, `ToolContext.updateImage(_:)`, `UndoBridge`.
- **0009**: `BlendOps.mul255`, `BlendOps.blend(_:dst:src:opacity:)` (Normal = exact straight source-over; `Sa == 0` → `dst` unchanged), `BrushOptions.widthRange` (1…2000) and default width 2, `protocol BrushClipMask`, `ToolContext.paintClipMask`, `BrushWidthAdjustable` (`[`/`]` step ±1 through `CanvasInputRouter`), the `toolOptions.width` / `.width.decrease` / `.width.increase` / `.antialiasing` / `.blendMode` control patterns.
- **0013**: `Selection`/`SelectionMask` (a `BrushClipMask`), `paintClipMask` = `selection?.mask`, debug hook `-UITestSelectRect x,y,w,h`.
- **0020**: `Tool.prepareForHistoryNavigation(context:)` (default: commit a pending edit), `PendingEditReason` (`.command`, `.historyNavigation`, `.save`). This tool keeps both defaults.
- **0023** (closest precedent, mirror it): `GradientTool`'s state machine (idle → drawing → editing ⇄ dragging handle), capture-at-gesture-start of `layerID`/`before`/`clip`/colors, re-render from `before` on every change, `touchedTiles` union, commit via `TileDiff.between(... candidates: touchedTiles)`, cancel writes `before` back, overlay case + drawing in `ToolOverlayView`, and `GradientGeometry.snapped(_:anchor:)` (15° snap preserving length) and `GradientGeometry.handleHitRadius` (6 view points). Reuse `GradientGeometry.snapped` — do not duplicate it.

Paint.NET behavior being mirrored (LineCurveTool.html, quoted or paraphrased):
- Drawing: "click where the line begins and drag the mouse pointer to the end point." On release "four control nubs appear on the line"; you "drag the control nubs to a new location" to make a curve.
- Curve types in Paint.NET 4+: Straight, Spline ("cubic spline interpolation", passes through every nub) and Bézier ("the curve will extend from the first or origin Control Nub to the last or destination Control Nub"; the middle nubs shape it without being touched). **PRD T-18 says "Editable Bézier handles", so this spec implements the Bézier type only** (Open question 1).
- Shift "constrains the line to angles that are multiples of 15 degrees."
- "Left button draws in the Primary color; right button draws in the Secondary color."
- Commit ("finish"): "Press Enter", "Click outside the current Line/Curve", "Click the Finish button in the Tool Bar", "Draw a new Line/Curve". (Toolbar.html: "The keyboard shortcut for the Finish button is the Enter key.")
- Moving the whole shape: "Arrow keys move the shape one pixel per press. Holding Ctrl moves it 10 pixels per press" (Ctrl → ⌘ per §5.12).
- Options: Brush Width (`[` / `]`), line style: "can be either solid or a combination of dashes and dots", caps: "flat (normal), one of two arrow head types, or rounded"; Antialiasing ("If disabled, the edges of the path of the tool will be snapped to the nearest pixel"); Blend Mode ("mimic the tool being applied to a layer immediately above the active layer").
- Not mirrored in v1.0 (Out of scope / Open question 1): Spline and Straight curve types, the pulsing Move handle, right-drag rotation, Alt "draw from center", Paint.NET's tool-only Overwrite blend mode.

## User story

As a PaintDotMac user, I press **O**, set the brush width, a dash style, start/end caps (flat, arrow, filled arrow, rounded), antialiasing, and a blend mode in the tool options bar, and drag on the canvas: a straight line in the primary color (secondary with right-drag) appears, confined to the selection, with four nubs. I drag the end nubs to move the endpoints, the two middle nubs (Bézier control points) or the line itself to bend it into a curve, hold Shift to snap angles to 15°, nudge it with the arrow keys, and change options live. Return, Finish, switching tools, or clicking away commits it as one "Line/Curve" history step that ⌘Z undoes; Escape discards it.

## Scope & changes

### Core (headless, unit-tested) — shared infrastructure reused by 0039 Shapes and partly 0040 Text

- **`PaintDotMac/Core/Tools/Shapes/ShapeStrokeStyle.swift`** (new, pure):
  ```swift
  enum DashStyle: String, CaseIterable, Sendable, ToolOptionValue {
      case solid, dash, dot, dashDot, dashDotDot
      var displayName: String          // "Solid", "Dash", "Dot", "Dash Dot", "Dash Dot Dot"
      /// On/off lengths in units of the stroke width (GDI+ DashStyle patterns, which Paint.NET 3.x used):
      /// solid [], dash [3,1], dot [1,1], dashDot [3,1,1,1], dashDotDot [3,1,1,1,1,1].
      var unitPattern: [Double]
  }
  enum LineCapStyle: String, CaseIterable, Sendable, ToolOptionValue {
      case flat, arrow, filledArrow, rounded
      var displayName: String          // "Flat", "Arrow", "Arrow (Filled)", "Rounded"
  }
  struct ShapeStrokeStyle: Sendable, Equatable {
      var width: Double                // clamped to BrushOptions.widthRange (1…2000); non-finite → 2
      var dashStyle: DashStyle
      var startCap: LineCapStyle
      var endCap: LineCapStyle
      static let `default` = ShapeStrokeStyle(width: 2, dashStyle: .solid, startCap: .flat, endCap: .flat)
      func clamped() -> ShapeStrokeStyle
      /// Absolute dash lengths = unitPattern × width (empty for solid).
      var dashLengths: [CGFloat] { get }
  }
  struct Arrowhead: Sendable, Equatable {
      var tip: CGPoint; var baseCenter: CGPoint; var leftWing: CGPoint; var rightWing: CGPoint
  }
  enum ArrowheadGeometry {
      /// Head length and full head width: 5 × max(width, 2) (GDI+ AdjustableArrowCap(5, 5) scaled by
      /// the pen width, with a floor so 1-px lines get a visible 10-px head).
      static func size(forWidth w: Double) -> Double
      /// `direction` = outward tangent at the endpoint (need not be normalized; zero → nil).
      /// u = normalized direction, n = (−u.y, u.x); baseCenter = tip − L·u; leftWing = baseCenter + n·(L/2); rightWing = baseCenter − n·(L/2).
      static func arrowhead(tip: CGPoint, direction: CGVector, width: Double) -> Arrowhead?
  }
  enum ShapeStrokeBuilder {
      /// The filled outline (nonzero fill rule) to rasterize for a stroked open path with this style:
      /// 1. Trim: for each end whose cap is .filledArrow, the stroked path is shortened so it ends at the point of
      ///    the curve whose distance from the tip is L/2 (bisection on the Bézier parameter, 40 iterations,
      ///    deterministic), so the line never pokes out of the triangle's tip.
      /// 2. Dash: solid → as is; else `path.copy(dashingWithPhase: 0, lengths: dashLengths)`.
      /// 3. Outline: `.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .round, miterLimit: 10)`
      ///    (each dash gets butt ends; caps below apply only to the two ends of the whole path).
      /// 4. Caps (added as extra subpaths, unioned by the nonzero rule): .rounded → a circle of diameter `width`
      ///    centered on the endpoint; .filledArrow → the closed triangle (tip, leftWing, rightWing);
      ///    .arrow → the open polyline leftWing → tip → rightWing stroked with `width`, butt caps, round join; .flat → nothing.
      static func outline(for path: CGPath, start: CGPoint, startTangent: CGVector,
                          end: CGPoint, endTangent: CGVector, style: ShapeStrokeStyle) -> CGPath
  }
  ```
  Caps use the endpoint's outward tangent: at the start `start − (first control point ≠ start)`, at the end `end − (last control point ≠ end)`, falling back through the other control points; all coincident → no cap (and no trim).

- **`PaintDotMac/Core/Tools/Shapes/ShapeRasterizer.swift`** (new, pure; CoreGraphics only, D-19):
  ```swift
  /// One coverage layer of a shape: a filled outline painted in one color. 0039 passes [outline, fill] etc.
  struct ShapePaint: Sendable { var path: CGPath; var fillRule: CGPathFillRule; var color: ColorRGBA8 }
  struct ShapeRenderParameters: Sendable {
      var paints: [ShapePaint]          // composited in order (later on top)
      var antialiasing: Bool
      var blendMode: BlendMode
  }
  enum ShapeRasterizer {
      /// 8-bit coverage of `path` for the pixels of `region` (row-major, region.width × region.height bytes).
      static func coverage(of path: CGPath, fillRule: CGPathFillRule, antialiasing: Bool, in region: PixelRect) -> [UInt8]
      /// Pixel bounds a set of paints can touch: union of path.boundingBoxOfPath expanded by 1 px, rounded out, ∩ canvas.
      static func bounds(of paints: [ShapePaint], canvas: PixelSize) -> PixelRect
      /// Rewrites `surface` from `before` for every tile in `bounds ∩ clip.bounds`; returns the visited tiles.
      static func render(_ parameters: ShapeRenderParameters, before: TiledSurface, into surface: inout TiledSurface,
                         clip: (any BrushClipMask)?) -> Set<TileCoordinate>
      /// One output pixel (exposed for tests): s = shape pixel, c = clip coverage.
      static func composePixel(before: ColorRGBA8, coverages: [UInt8], colors: [ColorRGBA8], clip c: UInt8,
                               blendMode: BlendMode) -> ColorRGBA8
  }
  ```
  - **Coverage via CoreGraphics.** For each 256×256 tile (or `region`) create an alpha-only bitmap `CGContext(data:, width:, height:, bitsPerComponent: 8, bytesPerRow: width, space: nil, bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)` (reuse one buffer per render; if alpha-only creation returns nil on this OS, use DeviceGray `.none`, fill white on black, same result). Clear to 0, `setShouldAntialias(antialiasing)`, `setAllowsAntialiasing(antialiasing)`, then map canvas → bitmap with exactly: `translateBy(x: 0, y: CGFloat(region.height)); scaleBy(x: 1, y: -1); translateBy(x: −region.minX, y: −region.minY)` (canvas is top-left y-down; CG bitmaps are bottom-left — this is the only Y flip, pinned by `coverageIsNotUpsideDown`). `addPath`, `fillPath(using: fillRule)` with opaque fill, read bytes row by row (bitmap row 0 = canvas row `region.minY` after the flip; verify with the test). Antialiasing off = CG aliased fill (pixel centers inside the path).
  - **Compose.** Shape pixel `s` starts `.clear`; for each paint `i` with coverage `k_i > 0`: `s = BlendOps.blend(.normal, dst: s, src: (color_i.rgb, mul255(color_i.a, k_i)))`. Then `Sa = mul255(s.a, c)`; if `Sa == 0` → `before` bit-for-bit; else result `BlendOps.blend(blendMode, dst: before, src: (s.r, s.g, s.b, Sa))`. (Paint.NET: the shape is drawn on its own layer and blended "as if … immediately above the active layer".) Clip: `c = clip?.coverage(x:y:) ?? 255`; with antialiasing off, `c = c >= 128 ? 255 : 0` (same rule as 0023's `effectiveClip`, call `GradientRenderer.effectiveClip`).
  - **`render`** = 0023's tile discipline: build each tile in `bounds ∩ clip.bounds` from `before.tile(at:)` (absent = clear); if equal to the before tile, `setTile` the **before** tile (shared storage); outside the region `surface` keeps/receives `before`'s tiles. Pure function of `(parameters, before, clip)`. Per-tile work may run concurrently (`DispatchQueue.concurrentPerform`) with deterministic output; each worker owns its own bitmap buffer.
  - Empty `paints`, empty bounds, or a path with non-finite coordinates → render returns `[]` and the caller restores `before`.

- **`PaintDotMac/Core/Tools/Shapes/EditableShape.swift`** (new, pure value types + one `@MainActor` editor class reused by 0039):
  ```swift
  enum ShapeHandleKind: Sendable, Equatable { case endpoint, control }   // 0039 adds .corner, .edge
  struct ShapeHandle: Sendable, Equatable { var position: CGPoint; var kind: ShapeHandleKind }
  /// What ShapeHandlesOverlay draws (canvas space).
  struct ShapeHandlesOverlayModel: Sendable, Equatable {
      var handles: [ShapeHandle]
      var guides: [ShapeGuide]          // thin dashed lines, e.g. start→control1, end→control2
      var activeHandle: Int?            // drawn highlighted while dragged
  }
  struct ShapeGuide: Sendable, Equatable { var from: CGPoint; var to: CGPoint }
  /// Geometry that a tool edits through handles. LineCurveGeometry (below) is the first conformer; 0039 adds its shapes.
  protocol EditableShapeGeometry: Sendable, Equatable {
      var handles: [ShapeHandle] { get }
      var guides: [ShapeGuide] { get }
      var isDegenerate: Bool { get }
      mutating func moveHandle(_ index: Int, to point: CGPoint, constrained: Bool)   // constrained = Shift
      mutating func translate(by delta: CGVector)
      /// Parameter of the body point nearest `viewPoint`, if within `tolerance` view points (nil = not on the body).
      func bodyHit(atView viewPoint: CGPoint, transform: CanvasTransform, tolerance: Double) -> Double?
      /// Drag that started on the body at parameter t (from bodyHit) with the original geometry; delta in canvas units.
      mutating func dragBody(from original: Self, parameter t: Double, delta: CGVector)
  }
  enum ShapeHit: Sendable, Equatable { case handle(Int), body(Double), none }
  enum ShapeHitTesting {
      static let handleHitRadius: Double = GradientGeometry.handleHitRadius   // 6 view points
      /// Nearest handle within the radius (view distance via transform.canvasToView); ties → the higher index
      /// (drawn on top); else bodyHit with tolerance max(4, widthInView / 2 + 2); else .none.
      static func hit<G: EditableShapeGeometry>(_ geometry: G, atView p: CGPoint, transform: CanvasTransform,
                                                strokeWidth: Double) -> ShapeHit
  }
  /// What a pending shape captured at gesture start (fixed until commit/cancel), as 0023 does.
  struct ShapeEditCapture: Sendable {
      let layerID: Layer.ID
      let before: TiledSurface
      let clip: (any BrushClipMask)?
      let color: ColorRGBA8             // primary, or secondary for a .secondary gesture (TOOL-A)
      let secondaryColor: ColorRGBA8    // the other slot (0039 uses it for fills)
  }
  enum ShapeEditPhase: Sendable, Equatable {
      case idle, drawing, editing
      case draggingHandle(Int)
      case draggingBody(parameter: Double, grab: CGPoint)   // grab = pointer at mouse-down (canvas)
  }
  @MainActor final class EditableShapeEditor<Geometry: EditableShapeGeometry> {
      typealias Renderer = (Geometry, ShapeEditCapture) -> ShapeRenderParameters?   // nil = nothing to draw
      init(historyName: String, icon: HistoryIcon)
      private(set) var phase: ShapeEditPhase
      private(set) var geometry: Geometry?
      private(set) var capture: ShapeEditCapture?
      private(set) var touchedTiles: Set<TileCoordinate>
      var hasPendingEdit: Bool { phase != .idle }
      /// Starts a pending shape: captures layer, before, clip and colors; returns false (stays idle) when the
      /// active layer index is invalid.
      func begin(_ geometry: Geometry, button: ToolMouseButton, context: any ToolContext) -> Bool
      func setPhase(_ phase: ShapeEditPhase)
      func update(_ geometry: Geometry, render: Renderer, context: any ToolContext)   // re-render from before + overlay
      func rerender(render: Renderer, context: any ToolContext)                       // options changed
      func commit(render: Renderer, context: any ToolContext)
      func cancel(context: any ToolContext)
  }
  ```
  - **Enum growth (0039).** 0039 adds `ShapeHandleKind.corner`/`.edge` and `ShapeEditPhase.rotating`. This spec may write exhaustive `switch`es over them (in `LineCurveTool` and `ShapeHandlesOverlay`); 0039 owns adding the new `case` branches to those switches (listed exactly in 0039 "Changes to 0038's code"). Don't add `default:` branches to dodge that update, and don't add the 0039 cases here.
  - **Re-render** (`update`/`rerender`): layer index of `capture.layerID` (gone → `cancel`); `params = isDegenerate ? nil : render(geometry, capture)`; inside `context.updateImage`: `nil` → write `before` back into the layer; else `ShapeRasterizer.render(params, before:, into: &img.layers[i].surface, clip: capture.clip)`. `touchedTiles.formUnion(result)`. Then `context.setOverlay(.shapeHandles(ShapeHandlesOverlayModel(handles:, guides:, activeHandle:)))` (`activeHandle` = index while `draggingHandle`).
  - **`commit`**: degenerate → `cancel`. Else `diff = TileDiff.between(before: capture.before, after: layer.surface, layerID:, candidates: touchedTiles)`; `context.commitHistory(TileDiffHistoryItem(name: historyName, icon: icon, diff: diff))` (empty diff → no step, D-34); overlay nil; reset to `idle` (geometry, capture, touchedTiles cleared).
  - **`cancel`**: write `before` back (pixel-identical; every tile `sharesStorage` or both absent), no history, overlay nil, `idle`.
  - **`Core/Tools/ToolContext.swift`** (extend 0006's `ToolOverlay`): `case shapeHandles(ShapeHandlesOverlayModel)`.

- **`PaintDotMac/Core/Tools/LineCurveTool.swift`** (new):
  - **Geometry** `struct LineCurveGeometry: EditableShapeGeometry` with `start, control1, control2, end: CGPoint` (one cubic Bézier; handles in this order: `[start (.endpoint), control1 (.control), control2 (.control), end (.endpoint)]`; guides `start→control1`, `end→control2`).
    - `static func straight(from s: CGPoint, to e: CGPoint) -> LineCurveGeometry`: `control1 = s + (e − s)/3`, `control2 = s + 2(e − s)/3` (a uniformly parameterized straight segment, so a fresh line is exactly straight).
    - `isDegenerate`: any non-finite coordinate, or all four points equal.
    - `var path: CGPath` (move to start, `addCurve(to: end, control1:, control2:)`); `point(at t:)` = cubic Bézier formula.
    - `moveHandle(i, to: p, constrained:)`: endpoints — unconstrained: the endpoint moves to `p` **and its adjacent control point moves by the same delta** (keeps the curve's shape at that end, Paint.NET-like); constrained (Shift): `p` is replaced by `GradientGeometry.snapped(p, anchor: otherEndpoint)` first. Control points — move alone; constrained: snapped against their own endpoint (control1 → start, control2 → end).
    - `translate(by:)`: all four points.
    - `bodyHit`: flatten into 64 equal-t segments, map with `transform.canvasToView`, nearest point on any segment; return the interpolated `t` if its distance ≤ tolerance.
    - `dragBody(from original, parameter t, delta d)`: `t` clamped to [0.1, 0.9]; curve-drag weights (as in Inkscape's curve dragging): `w = 0` if t ≤ 1/6; `w = ((6t − 1)/2)³ / 2` if t ≤ 1/2; `w = 1 − ((6(1 − t) − 1)/2)³ / 2` if t ≤ 5/6; else `1`. `control1 = original.control1 + d·(1 − w)/(3t(1 − t)²)`, `control2 = original.control2 + d·w/(3t²(1 − t))`; endpoints unchanged. Then `point(at: t) == original.point(at: t) + d` exactly in real arithmetic (the curve passes through the dragged point).
  - **Options** (TOOL-C): `struct LineCurveOptions: Equatable, Sendable { var stroke: ShapeStrokeStyle; var antialiasing: Bool; var blendMode: BlendMode; static let `default` = (ShapeStrokeStyle.default, true, .normal); @MainActor static func load(from:) ; @MainActor func save(to:) }`. Keys: `tool.lineCurve.width` (Double, default 2, range `BrushOptions.widthRange`), `tool.lineCurve.dashStyle` (raw String, `solid`), `tool.lineCurve.startCap` (raw, `flat`), `tool.lineCurve.endCap` (raw, `flat`), `tool.lineCurve.antialiasing` (Bool, true), `tool.lineCurve.blendMode` (raw, `normal`). Missing/unknown → defaults; width clamped on load.
  - **Render closure**: `ShapeRenderParameters(paints: [ShapePaint(path: ShapeStrokeBuilder.outline(for: g.path, start:, startTangent:, end:, endTangent:, style: options.stroke), fillRule: .winding, color: capture.color)], antialiasing:, blendMode:)`. Options are read from `context.options` at every render.
  - **State machine** (`final class LineCurveTool: Tool, BrushWidthAdjustable`, `id = .lineCurve`; owns `EditableShapeEditor<LineCurveGeometry>(historyName: "Line/Curve", icon: .lineCurve)`):
    - `hasPendingEdit` = editor's.
    - **`mouseDown`**, idle: ignore non-finite locations; `begin(.straight(from: loc, to: loc), button:)` → phase `drawing`; nothing is drawn (degenerate).
    - **`mouseDown`**, editing: `ShapeHitTesting.hit(geometry, atView: event.viewLocation, transform:, strokeWidth:)`: `.handle(i)` → `draggingHandle(i)` (either button; the color stays the one captured at creation); `.body(t)` → `draggingBody(parameter: t, grab: event.location)` and remember the original geometry; `.none` → `commit` ("click outside … commits"), then start a new line as in idle with this event's button ("Draw a new Line/Curve").
    - **`mouseDragged`**: `drawing` → geometry = `.straight(from: start, to: shift ? GradientGeometry.snapped(loc, anchor: start) : loc)`; `draggingHandle(i)` → `moveHandle(i, to: loc, constrained: shift)`; `draggingBody` → `dragBody(from: original, parameter: t, delta: loc − grab)`. Each calls `update` (re-render + overlay).
    - **`mouseUp`**: apply the drag once more; `drawing` with a degenerate result (click without drag) → `cancel` (no step, idle); otherwise → `editing`.
    - **`keyDown`**: arrow keys while pending and not mid-gesture → `translate` by 1 px (10 px with ⌘; Paint.NET Ctrl) in the arrow's canvas direction (Up = −y), re-render, return true; everything else → 0006's default (Return/Enter commit, Escape cancel). Arrow keys while idle → false.
    - **`commit` / `cancel`**: in `drawing`/dragging phases apply the last pointer location first (as `mouseUp`), then the editor's commit/cancel. Callers as in 0023: Return/Enter, Finish (`dispatcher.commitPendingEdit()`), tool switch (`deactivate` default) and document switch, `prepareForHistoryNavigation` default before undo/redo/jump/save, `PendingEditReason.command` before Edit/Image/Layers commands, click away.
    - **`optionsDidChange`** while pending → `rerender` (width, dash, caps, antialiasing, blend mode update live).
    - **`adjustBrushWidth(by:context:)`** (`[`/`]`): `width = clamp(width + delta, 1…2000)`, persisted; re-render a pending line.
    - **Cursor**: `.closedHand` while dragging a handle or the body; `.openHand` when `mouseMoved` found a handle or the body under the pointer (flag + `invalidateCursor()` on change, as 0023); else `.crosshair` on canvas, `.arrow` off canvas.
    - **`deactivate`**: default (commit) then `setOverlay(nil)`.
  - **`Core/Tools/ToolRegistry.swift`** (modify): register `.lineCurve → LineCurveTool()` in `standard()`. The O group now has one implemented tool (O selects Line / Curve; 0039 adds Shapes to the cycle).

### Platform glue (AppKit/SwiftUI; UI tests and manual checks)

- **`PaintDotMac/Canvas/ShapeHandlesOverlay.swift`** (new): `enum ShapeHandlesOverlay { static func draw(_ model: ShapeHandlesOverlayModel, transform: CanvasTransform, in ctx: CGContext) }`, called by `ToolOverlayView` for `.shapeHandles`. Points mapped with `transform.canvasToViewAffine`. Guides: 1 pt line, black dashed [3,3] over white solid. Handles: `.endpoint` → 10 pt circle, `.control` → 8 pt circle; white fill, 1 pt black stroke; `activeHandle` filled light blue (`NSColor.controlAccentColor` at 50%). Handles stay constant size in view points at every zoom/backing scale. No logic beyond drawing (the model and transform math are in Core).
- **`Canvas/ToolOverlayView.swift`** (extend): route `.shapeHandles` to `ShapeHandlesOverlay.draw`.
- **`UI/ToolOptionsBar.swift`** (extend `ToolOptionsContent`): case `.lineCurve`, left to right:
  - **Brush width** field + −/+ (0009 pattern; identifiers `toolOptions.width`, `toolOptions.width.decrease`, `toolOptions.width.increase`).
  - **Dash style** popup (`DashStyle.allCases`, labels `displayName`, each item with a small drawn preview), `toolOptions.dashStyle`.
  - **Start cap** / **End cap** popups (`LineCapStyle.allCases`), `toolOptions.startCap`, `toolOptions.endCap`.
  - **Antialiasing** toggle `toolOptions.antialiasing`; **Blend mode** popup `toolOptions.blendMode` (implemented `BlendMode` cases in L-3 order, 0009 pattern).
  - Finish (`toolOptions.finish`) appears (descriptor already `supportsPendingEdits: true`) and is enabled while a line is pending.
  - Changes save through `LineCurveOptions.save` and trigger `optionsDidChange` (live re-render).
- **Tools panel**: `tool.lineCurve` appears automatically (implemented tools only).
- `project.yml`: no change beyond new files (new folder `Core/Tools/Shapes/` is under the existing source glob); run `xcodegen generate`.
- **No PRD edit in this spec** (sub-agent rule). Open questions 1–3 ask the user to confirm decisions that should then be recorded next to T-18 in PRD §5.3 / §12.

## Acceptance criteria

- [ ] Pressing O selects Line / Curve; the options bar shows Brush width 2, Dash style "Solid", Start cap "Flat", End cap "Flat", Antialiasing on, Blend mode "Normal", and a disabled Finish button. → `LineCurveUITests.pressingOSelectsLineCurveAndShowsOptions`, `LineCurveToolTests.defaultsAndRegistration`
- [ ] Dragging draws a straight line in the primary color (secondary with right-drag / Control-drag) with four nubs; nothing is committed until finished. → `LineCurveToolTests.drawShowsFourHandlesAndIsPending`, `.secondaryDragUsesSecondaryColor`
- [ ] Coverage of straight lines is exact for widths 1, 2, 3 (antialiased and aliased) and dashes/caps/arrowheads produce the hand-computed pixels. → `ShapeRasterizerTests.*`, `ShapeStrokeStyleTests.*`
- [ ] Dragging an endpoint, a control nub, or the line body reshapes the curve live, always re-rendered from the original pixels; Shift snaps to 15°; arrow keys move the shape 1 px (⌘: 10 px). → `LineCurveGeometryTests.*`, `LineCurveToolTests.handleDragRerendersFromBefore`, `.bodyDragBends`, `.shiftSnaps`, `.arrowKeysMove`
- [ ] Return, Finish, tool switch, and clicking away commit exactly one "Line/Curve" step (icon `lineCurve`); Escape restores the layer with no step; a click without drag adds nothing. → `LineCurveToolTests.returnCommits`, `.deactivateCommits`, `.clickAwayCommitsAndStartsNew`, `.escapeCancels`, `.clickWithoutDragAddsNoStep`; `LineCurveUITests.drawLineSavePNG`, `.escapeDiscards`
- [ ] Changing an option (width, dash, caps, antialiasing, blend mode) or pressing `[`/`]` while pending re-renders live. → `LineCurveToolTests.optionChangeRerendersPending`, `.bracketKeysResizePending`
- [ ] The line is confined to the selection (antialiased mask edge with antialiasing on, threshold 128 off). → `ShapeRasterizerTests.clipPartialCoverage`, `LineCurveIntegrationTests.selectionClipsLine`, `LineCurveUITests.lineClippedToSelection`
- [ ] Undo while editing first commits the line, then undoes it; undo/redo restore exact before/after tiles. → `LineCurveIntegrationTests.undoWhileEditingCommitsFirst`, `.undoRedoRoundTrip`
- [ ] Options persist under `tool.lineCurve.*`. → `LineCurveToolTests.optionsRoundTripThroughStore`, `LineCurveUITests.optionsPersistAcrossRelaunch`
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Click without drag** → no line, no step, idle. → `clickWithoutDragAddsNoStep`
- **Both endpoints dragged onto each other** with distinct controls → a loop still renders (not degenerate); all four points equal → renders nothing; committing then = cancel. → `LineCurveToolTests.degeneratePendingCommitsNothing`
- **Line partly or entirely off-canvas**: only canvas tiles are visited; endpoints may be anywhere finite. → `ShapeRasterizerTests.offCanvasPartsIgnored`
- **Non-finite coordinates** (NaN/∞ events) → ignored on mouseDown; degenerate geometry renders nothing. → `LineCurveGeometryTests.nonFiniteIsDegenerate`
- **Huge width** (2000) and huge canvas: coverage is computed per tile with a fixed 256×256 buffer per worker, memory independent of canvas size. → `ShapeRasterizerTests.width2000CompletesAndIsBounded`
- **Width 1 aliased diagonal**: every column between the endpoints has ≥ 1 covered pixel (no gaps). → `ShapeRasterizerTests.aliasedDiagonalHasNoGaps`
- **Arrowhead on a zero-length tangent** (control coincides with endpoint) → falls back to the next distinct point; all coincident → no cap. → `ShapeStrokeStyleTests.capTangentFallback`
- **Filled arrow longer than the line** (short line, wide head): trim bisection clamps at the curve's other end; no crash, triangle still drawn. → `ShapeStrokeStyleTests.trimLongerThanLine`
- **Color alpha 0** or clip coverage 0 everywhere → no change, no step. → `LineCurveIntegrationTests.noOpAddsNoStep`
- **Tile boundaries**: a line across x = 255/256 is continuous. → `ShapeRasterizerTests.continuousAcrossTileBoundary`
- **Hidden active layer**: still writes the active layer (as 0009/0023).
- **Active layer deleted while pending** → next re-render/commit cancels without history.
- **Undo/redo/save/commands while pending** → commit first (0020 defaults). **Second button mid-gesture** → ignored by 0006's dispatcher. **Arrow keys mid-drag** → ignored (false).
- **1×1 canvas** → draws without crash.

## Test plan

Expected values are hand-computed. `P = (0,0,0,255)`, `W = (255,255,255,255)`. Coverage tests call `ShapeRasterizer.coverage` directly on `ShapeStrokeBuilder.outline(...)` of a straight `LineCurveGeometry` path, region (0,0,64,32) unless stated. "≈128" means 126…129 (CoreGraphics area coverage of half a pixel; the only tolerance used, because CG's antialiasing sampler is not bit-specified).

- **Unit — `PaintDotMacTests/Tools/Shapes/ShapeRasterizerTests.swift`:**
  - `antialiasedWidth1Centered`: (10,10.5)→(50,10.5), width 1, flat: row 10, x 10…49 = 255; x 9 and 50 = 0; rows 9 and 11 = 0.
  - `antialiasedWidth1OnPixelBoundary`: (10,10)→(50,10), width 1: rows 9 and 10, x 10…49 ≈128; rows 8, 11 = 0.
  - `antialiasedWidth2`: (10,10)→(50,10), width 2: rows 9, 10 (x 10…49) = 255; rows 8, 11 = 0; x 9 and 50 = 0.
  - `antialiasedWidth3Odd`: y 10.5, width 3 → rows 9…11 = 255, rows 8, 12 = 0; y 10, width 3 → rows 9, 10 = 255, rows 8, 11 ≈128.
  - `aliasedWidths`: antialiasing off: width 1 at y 10.25 → row 10 = 255, all others 0; width 2 at y 10 → rows 9, 10 = 255; width 3 at y 10.2 → rows 9…11 = 255, row 8 and 12 = 0; every value is 0 or 255.
  - `verticalMatchesHorizontalTransposed`: (10.5,10)→(10.5,50) width 1 is the transpose of `antialiasedWidth1Centered`.
  - `coverageIsNotUpsideDown`: (0,2.5)→(64,2.5) width 1 in region (0,0,64,32) → row 2 = 255, row 29 = 0; region (0,100,64,32) with the line at y 102.5 → bitmap row index 2 = 255.
  - `diagonalAreaMatchesLength`: (0,0)→(100,100), width 4, AA, region 0…128: Σcoverage/255 within 1.5% of 100√2·4 = 565.69.
  - `aliasedDiagonalHasNoGaps`: (0.5,0.5)→(60.5,30.5) width 1 aliased: every column 1…59 has ≥ 1 pixel = 255.
  - `dashPatternsWidth2`: (0,10)→(40,10), width 2, rows 9/10: Dash → x 0…5 = 255, 6…7 = 0, 8…13 = 255, 14…15 = 0; Dot → 0…1 on, 2…3 off, 4…5 on; Dash Dot → 0…5 on, 6…7 off, 8…9 on, 10…11 off, 12…17 on; Dash Dot Dot → 0…5 on, 6…7 off, 8…9 on, 10…11 off, 12…13 on, 14…15 off, 16…21 on ("on" = 255, "off" = 0).
  - `dashPatternWidth1`: (0,10.5)→(20,10.5), width 1, Dash → row 10: x 0…2 = 255, 3 = 0, 4…6 = 255, 7 = 0.
  - `roundedCap`: (10,10)→(30,10), width 4: flat → (8,10) = 0 and (9,10) = 0; rounded start → (9,10) = 255 (square fully inside the radius-2 disc around (10,10)), (8,10) in 1…254, (7,10) = 0.
  - `filledArrowPixels`: (10,10)→(110,10), width 2, end cap Arrow (Filled), region (0,0,128,32): (101,9) = 255, (102,12) = 255, (108,6) = 0, (110,10) = 0, (109,9) in 1…254; stroke rows 9/10 at x 50 = 255.
  - `openArrowPixels`: same with Arrow, width 1 at y 10: (102,12) < 128 (interior of the V is empty), (100,5) > 0 (wing end), (60,9) and (60,10) ≈128 (line itself).
  - `composeNormal`: `composePixel(before: W, coverages: [255], colors: [P], clip: 255, .normal) == P`; coverage 128 → `(127,127,127,255)`; over `.clear` with coverage 128 → `(0,0,0,128)`; color alpha 0 → `W` bit-for-bit; clip 0 → before.
  - `composeTwoPaintsInOrder` (for 0039): coverages [255,255], colors [(255,0,0,255), (0,0,255,128)] over W → shape pixel = blend(.normal, red, blue α128) = (127,0,128,255) → result `(127,0,128,255)`.
  - `clipPartialCoverage`: P line coverage 255, clip 128, AA on over W → `(127,127,127,255)`; AA off, clip 127 → W; clip 128 → P.
  - `offCanvasPartsIgnored`: 100×100 canvas, line (−50,50)→(150,50) width 2 → returned tiles == {(0,0)}; pixels (0,49),(99,50) = P.
  - `continuousAcrossTileBoundary`: 512×20 W, line (0,10)→(512,10) width 2 → every x in 0…511 rows 9/10 = P.
  - `noAllocationOutsideShape`: 600×600 absent-tile surface, short line inside tile (0,0) → only that tile allocated; others `sharesStorage`/absent.
  - `width2000CompletesAndIsBounded`: 4000×3000 W, line (0,1500)→(4000,1500) width 2000 → completes; pixel (2000,1500) = P, (2000,499) = W, (2000,501) = P.
  - `renderIsPureFunctionOfBefore` (property, 200 seeded random geometry/style pairs on 300×300 random images, seed printed): render A then B == render B from before.
  - `integerTranslationShiftsCoverage` (property, 100 seeds): translating the geometry by integer (dx,dy) shifts coverage exactly (±1 per pixel).
  - `dashedNeverExceedsSolid` (property, 100 seeds): per pixel, dashed coverage ≤ solid coverage + 1.
- **Unit — `PaintDotMacTests/Tools/Shapes/ShapeStrokeStyleTests.swift`:**
  - `dashPatterns`: `unitPattern` per case as listed; `dashLengths` for width 2.5 Dash = [7.5, 2.5]; solid → [].
  - `displayNames`: "Solid", "Dash", "Dot", "Dash Dot", "Dash Dot Dot"; "Flat", "Arrow", "Arrow (Filled)", "Rounded".
  - `clamping`: width 0 → 1, 5000 → 2000, NaN → 2.
  - `arrowheadSize`: width 1 → 10, 2 → 10, 6 → 30.
  - `arrowheadGeometry`: tip (110,10), direction (1,0), width 2 → base (100,10), left (100,15), right (100,5); tip (10,10), direction (−1,0) → base (20,10), left (20,5), right (20,15); width 6, direction (1,0) → left (80,25), right (80,−5); direction (3,4) width 2 at tip (0,0) → base (−6,−8), left (−10,−5), right (−2,−11) (within 1e-9); zero direction → nil.
  - `capTangentFallback`: control1 == start → start tangent uses control2; all four equal → no caps, outline empty.
  - `filledArrowTrim`: straight (10,10)→(110,10), Arrow (Filled) end, width 2 → the trimmed stroke's end x = 105 ± 1e-6 (L/2 = 5 from the tip); `trimLongerThanLine`: line (0,0)→(4,0), width 10 (L = 50) → no crash, outline bounds contain the triangle.
- **Unit — `PaintDotMacTests/Tools/Shapes/LineCurveGeometryTests.swift`:**
  - `straightControlsAtThirds`: (0,0)→(30,0) → controls (10,0), (20,0); `point(at: 0.5) == (15,0)`; points at t = k/10 equal (3k, 0) (uniform).
  - `bendAtMidpoint`: from straight (0,0)→(30,0), `dragBody(t: 0.5, delta: (0,12))` → control1 (10,16), control2 (20,16); `point(at: 0.5) == (15,12)`.
  - `bendWeights`: t = 0.25 → w = 0.0078125; control1 offset = d·2.351851851…, control2 offset = d·0.0555…; t = 0.1 (≤1/6) → control2 unchanged; t = 0.95 clamps to 0.9 (w = 1) → control1 unchanged.
  - `bendPassesThroughPointer` (property, 500 seeded t ∈ [0.1, 0.9], random geometry/delta): `point(at: t) − original.point(at: t) == delta` within 1e-6.
  - `moveEndpointCarriesControl`: move end (30,0)→(30,10) → end (30,10), control2 (20,10), control1 unchanged.
  - `shiftConstrainsEndpointAndControls`: start (0,0), move end to (100,3) constrained → end ≈ (√10009, 0); control1 moved to (5,9) constrained → snapped against start at 60°, length √106.
  - `translate`: all four points shift by (3,−2).
  - `bodyHit`: identity-ish transform (100%, backing 1): point 3 pt off the middle of a horizontal line → t ≈ 0.5 (±0.02); 10 pt off with width 2 → nil; width 40 (tolerance 22 pt) → hit; at 400% zoom tolerance stays in view points.
  - `nonFiniteIsDegenerate`; `allEqualIsDegenerate`; loop (start == end, controls distinct) is not degenerate.
- **Unit — `PaintDotMacTests/Tools/Shapes/ShapeHitTestingTests.swift`:** handle within 6 pt → `.handle(i)`; two handles in range → nearer; exact tie → higher index; handle beats body; neither → `.none`; at 400% zoom radius unchanged in view points.
- **Unit — `PaintDotMacTests/Tools/LineCurveToolTests.swift`** (`FakeToolContext`, 300×300 W `DocumentState`, `InMemoryToolOptionStore`, default colors, transform 100% backing 1 so view ↔ canvas is a known flip):
  - `defaultsAndRegistration`: empty store → `LineCurveOptions.default`; `ToolRegistry.standard().isImplemented(.lineCurve)`; `shortcutGroup(for: "o") == [.lineCurve]`.
  - `optionsRoundTripThroughStore`: save width 7.5, `.dashDot`, `.arrow`, `.filledArrow`, AA false → keys `tool.lineCurve.width == 7.5`, `.dashStyle == "dashDot"`, `.startCap == "arrow"`, `.endCap == "filledArrow"`, `.antialiasing == false`, `.blendMode == "normal"`; reloaded equal; unknown `"zigzag"` → `.solid`.
  - `drawShowsFourHandlesAndIsPending`: down (50,100), drag (250,100), up → overlay `.shapeHandles` with handles [(50,100) endpoint, (50+200/3,100) control, (50+400/3,100) control, (250,100) endpoint] (±1e-9) and guides start→control1, end→control2; pending; no `commitHistory`; width 2 covers [99,101] → rows 99 and 100 = P for x 50…249; rows 98 and 101 = W; x 49 and 250 = W.
  - `secondaryDragUsesSecondaryColor`: secondary-button drag with primary (255,0,0,255), secondary (0,0,255,255) → (150,100) == (0,0,255,255).
  - `handleDragRerendersFromBefore`: draw, drag end handle twice → pixels equal a fresh render of the final geometry from the white surface (no accumulation).
  - `bodyDragBends`: draw (50,100)→(250,100); mouse down at canvas (150,100) (on the body), drag to (150,160), up → geometry `point(at: 0.5) == (150,160)`; pixel (150,159) or (150,160) == P; (150,100) == W.
  - `shiftSnaps`: drag (100,100)→(200,105) with Shift → end == (100 + √10025, 100) within 1e-9.
  - `arrowKeysMove`: pending line, `.rightArrow` → +1 x, handled true; `.downArrow` with `.command` → +10 y; idle → returns false.
  - `optionChangeRerendersPending`: store `.dash` + `optionsDidChange` → row 100 pixels follow the dash pattern; `bracketKeysResizePending`: `adjustBrushWidth(by: +1)` → width 3 persisted, pending render uses width 3.
  - `returnCommits`: Return → one `commitHistory` named "Line/Curve", icon `.lineCurve`, non-empty diff; not pending; overlay nil. `deactivateCommits`. `escapeCancels`: layer pixel-identical (tiles `sharesStorage`), no commit.
  - `clickAwayCommitsAndStartsNew`: pending, down at (20,250) far from handles/body → one commit, new `drawing` begun at (20,250).
  - `clickWithoutDragAddsNoStep`; `degeneratePendingCommitsNothing` (drag all handles onto one point, Return → no commit, pixels W).
  - `respectsClipHook`: clip mask x < 150 → 255 else 0 → after commit, all pixels with x ≥ 150 are W.
  - `colorsCapturedAtCreation`: change `colors.primary` while pending and re-render (option change) → line keeps the original color (as 0023).
- **Integration — `PaintDotMacTests/Integration/LineCurveIntegrationTests.swift`** (0005 New Image 800×600 W, `UndoBridge`, forwarding `ToolContext`, `LineCurveTool`):
  - `undoRedoRoundTrip`: draw + bend + Return → history `["New Image", "Line/Curve"]`; undo → all tiles equal original; redo → equal snapshot; 50 seeded random lines (widths, dashes, caps, AA, button) each undo/redo identity (seed printed).
  - `undoWhileEditingCommitsFirst`: pending line, `undoBridge.undo()` through the 0020 hook → pixels W, redo available named "Line/Curve".
  - `noOpAddsNoStep`: primary alpha 0 → no step; selection outside the line → no step.
  - `selectionClipsLine`: `Selection(rect: (100,100,200,200))`, line (0,200)→(800,200) width 10 → pixels outside the rect W, (200,200) P.
- **UI — `PaintDotMacUITests/LineCurveUITests.swift`** (fixture 4000×1000 opaque white via `UITestApp.makePNG`, reset defaults):
  - `pressingOSelectsLineCurveAndShowsOptions`: type `o` → `tool.lineCurve` selected; `toolOptions.width` "2", `toolOptions.dashStyle` "Solid", `toolOptions.startCap` "Flat", `toolOptions.endCap` "Flat", `toolOptions.antialiasing` on, `toolOptions.blendMode` "Normal"; `toolOptions.finish` exists, disabled.
  - `drawLineSavePNG`: `o`; set `toolOptions.width` to 40; `dragOnCanvas(from: (0.25, 0.5), to: (0.75, 0.5))`; `toolOptions.finish` enabled; Return → History row "Line/Curve", Edit menu "Undo Line/Curve"; ⌘S; read the PNG: column x = 2000 has ≥ 36 pixels exactly `(0,0,0,255)` within rows 440…560; (2000,300), (2000,700), (500,500), (3500,500) are white. ⌘Z, ⌘S, reread → (2000,500) white.
  - `escapeDiscards`: draw, Escape → no "Line/Curve" row; ⌘S → column 2000 all white.
  - `lineClippedToSelection`: launch with `-UITestSelectRect 1500,0,1000,1000`; draw as above; Return; ⌘S → (1200,500) white, (2000,500) black.
  - `optionsPersistAcrossRelaunch`: choose Dash style "Dash" and End cap "Arrow (Filled)", quit, relaunch without reset → both popups show those values.
- **Performance** — `PaintDotMacTests/Performance/LineCurvePerformanceTests.swift` (XCTest `measure`, report only): re-render of a width-50 dashed Bézier spanning a 4000×3000 layer (handle-drag responsiveness, NF-1); record in Verification status. NF-4: diffs hold only touched tiles.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green (clean build, no warnings, all tests pass, none skipped, UI tests ran, launch smoke).
- **Manual verification:**
  1. At 100% and 800% on 1× and 2× displays: nubs keep their on-screen size; guides from endpoints to control nubs are visible on white, black, and photos.
  2. Drag each nub and the line body: the curve follows smoothly without lag on a 4000×3000 image; the cursor is an open hand over nubs/body and a closed hand while dragging.
  3. Every dash style and cap at widths 1, 5, 30 looks clean (no gaps or protruding line at filled arrow tips; open arrows form a clear V).
  4. Antialiasing off gives hard, pixel-snapped edges; on gives smooth edges.
  5. Right-drag and Control-drag draw in the secondary color; Shift snaps to 15°; arrow keys and ⌘-arrow nudge.
  6. With a soft ellipse selection, the line fades at the edge with antialiasing on.

## Open questions

1. **Curve model and editing gestures.** PRD T-18 says "Editable Bézier handles". This spec implements a single cubic Bézier with Paint.NET 4+'s four fixed nubs (two endpoints, two control points), adds Inkscape-style "drag the line itself to bend it", and arrow-key nudging. It does **not** offer Paint.NET's Spline/Straight curve-type option, does not add extra control points (Paint.NET 3.x style), and omits the Move handle, right-drag rotation, and Alt "draw from center". Recommended: yes for v1.0; record next to T-18 in PRD §5.3 / §12.
2. **Undo while a line is pending.** As with the Gradient (0023), ⌘Z first commits the pending line and then undoes it, so the whole line disappears in one step (Paint.NET 4+ instead records each nub edit as its own step while editing). Recommended: keep the 0023 behavior for consistency.
3. **Dash style list, cap names, arrow size.** Paint.NET's docs don't list them. This spec uses the GDI+ set Paint.NET 3.x used — Solid, Dash, Dot, Dash Dot, Dash Dot Dot (patterns ×width, butt-ended dashes) — caps Flat, Arrow, Arrow (Filled), Rounded, and arrowheads 5 × max(width, 2) long and wide. Recommended: yes; record in PRD T-18.

## Out of scope

- Shapes tool, shape catalog, fill modes (0039 — reuses `EditableShapeEditor`, `ShapeRasterizer`, `ShapeStrokeStyle`, `ShapeHandlesOverlay`); Text tool (0040 — reuses only `ShapeRasterizer`/`ShapePaint`/`ShapeRenderParameters`).
- Spline / Straight curve types, extra control points, Move handle, rotation, draw-from-center (Open question 1); extended shape library (0058).
- Live recoloring of a pending line on palette changes (captured at creation, as 0023 Open question 2).
- Blend modes beyond those implemented (0026/0027/0059 extend the list automatically); Paint.NET's Overwrite mode.
- Tablet pressure (0055).
