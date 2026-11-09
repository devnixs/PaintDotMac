# 0040 — Add the Text tool: type editable text that is rasterized onto the active layer on commit

> Source: PRD.md §5.3 T-17 (Text, key T: font, size, bold, italic, underline, alignment, antialiasing; system font list through Core Text, default system font 12 pt; editable until committed by switching tools, ⌘↩, or clicking outside; rasterized, not text layers), §12 D-25, TOOL-A (primary color), TOOL-B (confined to the selection), TOOL-C (options persist), §5.12 and AGENTS.md rule 9 (single-key shortcuts don't fire while typing), H-6 / D-34 (no-op edits add no step), APP-5 / D-7 (per-document DPI), §8 M5 exit criterion ("Use case 1 works fully"), AGENTS.md rule 1 (CoreText is allowed in `Core`).
> Paint.NET docs (fetched 2026-11-07): Text tool — https://www.getpaint.net/doc/latest/TextTool.html (served at https://www.paint.net/doc/latest/TextTool.html).
> Milestone: M5 (Shapes & Text)
> Depends on: 0006 (tool framework, `insertText`, `capturesKeyboard`, `ToolShortcutGate`), 0007 (colors), 0008 (history, `UndoBridge`), 0009 (`BlendOps`, `BrushClipMask`, options-bar patterns), 0013 (selection clip, `-UITestReduceMotion`), 0018 (⌫ menu-item suppression while a tool captures the keyboard), 0019 (`ToolCursor.move`), 0020 (`PendingEditReason`, `prepareForHistoryNavigation`), 0023 (pending-edit/live re-render precedent), 0024 (`GoldenImage`), 0038 (`ShapeRasterizer`, `ShapePaint`, `ShapeRenderParameters` — the shared path-fill rasterizer; nothing else from 0038), 0039 (ordering only, M5).

## Context

Not yet implemented: there is no Text tool. 0006 already reserves everything the tool plugs into (spec `docs/specs/todo/0006-tool-framework-and-panels_TODO.md`):

- `Tool.capturesKeyboard` (default false) and `Tool.insertText(_:context:)` (default no-op), §Core `Tool.swift` (0006 lines 108–125). `ToolShortcutGate.allows(…, toolCapturesKeyboard:, …)` blocks every single-key shortcut while a tool captures the keyboard (0006 line 169). 0007 (X/D/C), 0009 (`[`/`]`), and 0018 (⌫/⌦/⌥⌫, menu validation false while `activeTool.capturesKeyboard`) all go through this gate.
- `CanvasInputRouter.keyDown`: Space goes to the tool (not to Space-pan) while `capturesKeyboard`; other keys go to `dispatcher.keyDown(ToolKeyEvent)`, and if that returns `false` and the tool captures the keyboard, to `canvasView.interpretKeyEvents([event])`, whose `insertText(_:)` forwards to `dispatcher.insertText` (0006 lines 292–296). 0006 explicitly leaves IME support to this spec (0006 line 503).
- The `text` descriptor row exists: `Text | t | textAndShape | textformat | supportsPendingEdits true` (0006 line 158), so the Finish button already appears for it. `HistoryIcon.text` exists (0008 line 52). `ToolCursor.iBeam` exists (0006); `.move` comes from 0019.
- Pending-edit lifecycle: tool switch → `deactivate` (default commits); Finish → `commit`; undo/redo/jump/save → `prepareForHistoryNavigation` (0020, default commits); Edit/Image/Layer commands → `prepareForNavigation` with reason `.command` → `commit` (0013, 0018, 0020, 0022, 0035, 0037 already promise "0038–0040 commit pending shapes/text").
- Live re-render from a `before` snapshot and a single `TileDiffHistoryItem` on commit is the Gradient pattern (0023 item "State machine", lines 109–121); this spec follows it.
- 0038 creates `Core/Tools/Shapes/ShapeRasterizer.swift`: `struct ShapePaint(path:fillRule:color:)`, `struct ShapeRenderParameters(paints:antialiasing:blendMode:)`, and `ShapeRasterizer.render(_:before:into:clip:) -> Set<TileCoordinate>` (per-256×256-tile CoreGraphics alpha-only coverage, rewrite from `before`, clip via `GradientRenderer.effectiveClip`, unchanged tiles keep `before`'s storage). Text glyphs are CGPaths, so this spec fills them with that rasterizer, **unchanged** — its API already takes the fill rule, `before`, clip, antialiasing, and blend mode. **Not reused from 0038/0039:** `EditableShapeEditor`, `EditableShapeGeometry`, `ShapeHandle`/`ShapeHandlesOverlay`/`ToolOverlay.shapeHandles`, `ShapeStrokeStyle`, `ShapeEditPhase` — text has no handles; its caret, bounds, and move nub use this spec's own `ToolOverlay.textEditing` and `TextEditingOverlay`, and its session state lives in `TextTool`.
- **Color capture in 0023/0038/0039.** `GradientTool`, `LineCurveTool`, and `ShapesTool` capture colors at gesture start (`ShapeEditCapture.color`/`.secondaryColor` for 0038/0039) and re-render on `optionsDidChange` from those captured values. This spec's live recolor uses a **separate** hook (item 13), so those tools are never re-rendered or recolored by a palette change.

Paint.NET behavior being mirrored (Text tool page, quoted):
- "This tool allows text to be typed onto the current layer using the Primary color." "Change the color of the text by changing the Primary color in the Colors Window."
- Toolbar: Font, Size ("will support values in between integers like 18.3pt"), "four basic formatting options for text: Bold, Italic, Underline & Strikeout", Align Left / Center Align / Align Right ("the direction that typed text will extend away from the initial cursor position"), rendering mode (Smooth / Sharp (Modern) / Sharp (Classic)), Antialiasing on/off.
- "While typing, notice the presence of a pulsing four-way arrow icon below and to the right of the blinking text cursor. This is called a control nub." "Click and drag the … Move Icon … using either Mouse Button to reposition the text." "When the Move Icon is clicked and held, the keyboard arrow keys ↑ ← ↓ → can be used to move the text per-pixel."
- "press the Esc key or click Finish in the Tool Bar to render the text to the layer." "When text is rendered to the layer it no longer exists as text characters, but only as pixels."
- Size units: "Text rendered in points will be scaled according to the image DPI"; "One point is equal to 1/72 of an inch"; the alternative unit "Fixed (96 DPI)". (The page also says "the approximate pixel height will be number of points * image DPI / 96"; that conflicts with 1 pt = 1/72 in and is treated as approximate. See Open question 2.)

PaintDotMac scope per PRD T-17: Font, Size, Bold, Italic, Underline, Alignment, Antialiasing (plus Blend mode, Open question 3). Strikeout, rendering modes, and the Fixed (96 DPI) unit are not in T-17 and are out of scope.

## User story

As a PaintDotMac user, I press **T**, pick a font, size, style, and alignment in the tool options bar, click on the canvas, and type. The text appears live in the primary color with a blinking caret; Backspace, Delete, the arrow keys, and Return (new line) edit it, and typing letters like B or E never switches tools. I drag the move nub to reposition the text, change the options to restyle it live, and finish with ⌘↩, Finish, Escape, a click outside the text, or by switching tools. The text becomes pixels on the active layer, clipped to my selection, as one "Text" history step that ⌘Z undoes.

## Scope & changes

### Core (pure Swift; `Core/Tools/Text/` and `Core/Tools/`; imports Foundation, CoreGraphics, CoreText only; unit-tested)

1. **`Core/Tools/Text/TextOptions.swift`** (new):
   ```swift
   enum TextAlignment: String, CaseIterable, Sendable, ToolOptionValue { case left, center, right }   // "Align Left", "Center Align", "Align Right"
   struct TextOptions: Equatable, Sendable {
       var fontFamily: String        // "" = the system font ("System Font")
       var size: Double              // points; sizeRange 1...2000; decimals allowed (18.3)
       var bold: Bool; var italic: Bool; var underline: Bool
       var alignment: TextAlignment
       var antialiasing: Bool
       var blendMode: BlendMode
       static let sizeRange = 1.0...2000.0
       static let `default` = TextOptions(fontFamily: "", size: 12, bold: false, italic: false, underline: false,
                                          alignment: .left, antialiasing: true, blendMode: .normal)
       static let sizePresets: [Double] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72, 84, 96, 108, 144, 192, 216, 288]
       @MainActor static func load(from store: any ToolOptionStore) -> TextOptions
       @MainActor func save(to store: any ToolOptionStore)
   }
   ```
   Keys (0006 `ToolOptionKey`, TOOL-C): `tool.text.fontFamily` (String, ""), `tool.text.size` (Double, 12, range `sizeRange`; non-finite → 12, out of range clamped), `tool.text.bold`/`.italic`/`.underline` (Bool, false), `tool.text.alignment` (raw String, `left`; unknown → `.left`), `tool.text.antialiasing` (Bool, true), `tool.text.blendMode` (`BlendMode` raw value; unknown → `.normal`, 0009 pattern). `tool.` is already in `LaunchOptions.resettableKeyPrefixes`.
   - `static func pixelsPerEm(points: Double, dpi: Double) -> Double` = `points × dpi / 72` (Open question 2), clamped to `1...65_535`; non-finite or ≤ 0 DPI → uses 96. Examples: 12 pt @ 96 DPI → 16 px; 12 pt @ 72 → 12; 12 pt @ 300 → 50; 2000 pt @ 96 → 2666.67.

2. **`Core/Tools/Text/SystemFontCatalog.swift`** (new):
   - `static func familyNames() -> [String]`: `CTFontManagerCopyAvailableFontFamilyNames()`, dropping names that start with `"."` (hidden system families), deduplicated, sorted with `localizedStandardCompare`. Cached after the first call (`static let`).
   - `static let systemFontDisplayName = "System Font"` (first entry of the font popup, stored as `""`).
   - `static func resolve(family: String, pixelsPerEm: Double, bold: Bool, italic: Bool) -> ResolvedTextFont`:
     ```swift
     struct ResolvedTextFont: @unchecked Sendable {   // CTFont is immutable and thread-safe
         let font: CTFont; let syntheticBold: Bool; let syntheticItalic: Bool
     }
     ```
     Base font: `""` → `CTFontCreateUIFontForLanguage(.system, pixelsPerEm, nil)`; otherwise `CTFontCreateWithFontDescriptor` of a descriptor with `kCTFontFamilyNameAttribute = family` at `pixelsPerEm`; if the family isn't installed (the created font's family name ≠ `family`) → fall back to the system font (the stored option is left unchanged). Then request the traits (`kCTFontTraitBold`, `kCTFontTraitItalic`) with `CTFontCreateCopyWithSymbolicTraits`; when the copy fails or lacks a requested trait, keep the closest font that has the other trait and set `syntheticBold`/`syntheticItalic` for the missing one (Paint.NET/DirectWrite synthesizes missing styles too).
   - Font sizes are passed to Core Text **in image pixels** (the layout space is canvas pixels, 1 unit = 1 px).

3. **`Core/Tools/Text/TextEditBuffer.swift`** (new): the pure editing model (no Core Text).
   ```swift
   struct TextEditBuffer: Equatable, Sendable {
       private(set) var text: String              // committed characters, "\n" = line break
       private(set) var caret: Int                // UTF-16 offset into `displayText`, always on a grapheme boundary
       private(set) var markedRange: NSRange?     // IME composition inside displayText (nil = none)
       var displayText: String { get }            // == text with the marked string spliced in (what is laid out)
       mutating func insert(_ s: String)          // replaces marked text if any, then inserts at caret; "\r\n" and "\r" → "\n"; other control characters (U+0000–U+001F except \n, U+007F) removed
       mutating func setMarkedText(_ s: String, selectedRange: NSRange)  // empty s == unmark with nothing inserted
       mutating func unmarkText()                 // marked string becomes regular text
       mutating func deleteBackward()             // one grapheme cluster before the caret (a "\n" joins lines); at 0: no-op
       mutating func deleteForward()              // one grapheme cluster after the caret; at end: no-op
       mutating func moveLeft(); mutating func moveRight()   // one grapheme cluster, clamped; never splits "e\u{301}" or emoji ZWJ sequences
       mutating func moveToLineStart(); mutating func moveToLineEnd()
       mutating func moveToTextStart(); mutating func moveToTextEnd()
       mutating func setCaret(_ utf16Offset: Int) // snapped down to the previous grapheme boundary, clamped to 0...count
       var lineIndexOfCaret: Int { get }; var lines: [Substring] { get }   // split on "\n", keeps empty lines ("a\n" → ["a", ""])
   }
   ```
   Up/Down need layout and are done by `TextTool` with `TextLayout.caretIndex(…)` (item 4). While `markedRange != nil`, the movement and delete methods are not called (the input method owns those keys; item 7).

4. **`Core/Tools/Text/TextLayoutEngine.swift`** (new): Core Text layout → glyph outlines → path; caret geometry.
   ```swift
   struct TextLayoutRequest: Equatable, Sendable {
       var text: String; var anchor: PixelPoint; var options: TextOptions; var dpi: Double
       var underlineRange: NSRange?   // marked text: drawn underlined in the overlay only, never rasterized differently
   }
   struct TextLayout: @unchecked Sendable {        // immutable Core Text objects
       let lines: [TextLine]                      // one per "\n"-separated line, even if empty
       let lineHeight: Double; let ascent: Double; let descent: Double
       let bounds: CGRect                         // canvas space, union of line boxes (min width 1 px)
       let glyphPath: CGPath                      // canvas space, y down; all glyph outlines + underline rects; nonzero winding
       func caretRect(atUTF16 offset: Int) -> CGRect          // x = caret x, width 0, y = line top, height = lineHeight
       func caretIndex(nearest point: CGPoint) -> Int         // click → offset (line by y, then CTLineGetStringIndexForPosition)
       func caretIndex(fromUTF16 offset: Int, lineDelta: Int, preferredX: Double) -> Int   // Up (−1) / Down (+1)
   }
   struct TextLine: @unchecked Sendable { let utf16Range: NSRange; let ctLine: CTLine; let origin: CGPoint /* baseline-left, canvas */; let width: Double }
   enum TextLayoutEngine { static func layout(_ request: TextLayoutRequest) -> TextLayout }
   ```
   Rules (all coordinates canvas pixels, top-left origin, y down):
   - Font: `SystemFontCatalog.resolve(family:, pixelsPerEm: TextOptions.pixelsPerEm(points: size, dpi:), bold:, italic:)`. `ascent`, `descent`, `leading` = `CTFontGetAscent/Descent/Leading` of the resolved **base** font; `lineHeight = ascent + descent + leading`.
   - Lines: split on `"\n"` only (no wrapping; text may run off the canvas). Each line is a `CTLine` from an attributed string with `kCTFontAttributeName` = base font (`kCTUnderlineStyleAttributeName` is **not** used; underline is drawn by us, below). Core Text's font cascade substitutes fallback fonts for characters the base font lacks; each `CTRun` carries its own font (e.g. "あ" in Helvetica → a Hiragino run). Missing glyphs in every font render as the font's `.notdef` glyph as Core Text supplies it.
   - Line width `w = CTLineGetTypographicBounds` width (includes trailing spaces). Line `i` origin: `y = anchor.y + (ascent + Double(i) × lineHeight).rounded()` (baseline), `x = anchor.x` (left), `(anchor.x − w/2).rounded()` (center), `(anchor.x − w).rounded()` (right). `anchor` is the integer pixel where the text was placed: the top of the first line box at the alignment edge.
   - Glyph outlines: for each run, `CTRunGetGlyphs`/`CTRunGetPositions`, `CTFontCreatePathForGlyph(runFont, glyph, &t)` with `t` = translate(origin + position) · scale(1, −1) (Core Text glyph space is y-up). Synthetic italic: shear `c = −tan(12°)` applied in glyph space before the flip (slants right). Synthetic bold: the glyph path is replaced by `path.union(path.copy(strokingWithWidth: pixelsPerEm / 24, lineCap: .round, lineJoin: .round, miterLimit: 10))` (`CGPath.union`, macOS 13+). Glyphs without an outline (`CTFontCreatePathForGlyph` → nil, e.g. color emoji bitmaps) are skipped: they render nothing (Edge cases).
   - Underline: per non-empty line, a rect from `x` to `x + w` with top at `baseline − CTFontGetUnderlinePosition(base)` − thickness/2 and height `max(1, CTFontGetUnderlineThickness(base))`, added to `glyphPath` (so it is clipped, blended, and antialiased exactly like glyphs).
   - `bounds`: union over lines of `(lineX, anchor.y + i × lineHeight (rounded as above minus ascent), max(w, 1), lineHeight)`; an empty text has bounds `(anchor.x, anchor.y, 1, lineHeight)` (alignment applied to a width-1 line).
   - Caret: `caretRect(atUTF16:)` finds the line containing the offset (an offset right after `"\n"` belongs to the next line), `x = lineX + CTLineGetOffsetForStringIndex(ctLine, offset − lineStart, nil)`; empty line → `lineX`.
   - `caretIndex(fromUTF16:lineDelta:preferredX:)`: target line = current ± 1; above the first line → 0, below the last → end of text (macOS convention); else `CTLineGetStringIndexForPosition` at `preferredX − lineX`, snapped to a grapheme boundary.

5. **Rasterization (Core; reuse 0038 unchanged).** `Core/Tools/Text/TextLayoutEngine.swift` also defines `enum TextRasterizer { static func render(_ layout: TextLayout, color: ColorRGBA8, options: TextOptions, clip: (any BrushClipMask)?, before: TiledSurface, into surface: inout TiledSurface) -> Set<TileCoordinate> }`, a thin wrapper that returns exactly
   `ShapeRasterizer.render(ShapeRenderParameters(paints: [ShapePaint(path: layout.glyphPath, fillRule: .winding, color: color)], antialiasing: options.antialiasing, blendMode: options.blendMode), before: before, into: &surface, clip: clip)`
   (an empty `glyphPath` → `[]` and `surface` is left as `before`, per 0038's empty-bounds rule). With one paint, 0038's compose gives per pixel `Sa = mul255(mul255(color.a, coverage), c)` with `c` = clip coverage (thresholded at 128 when antialiasing is off, `GradientRenderer.effectiveClip`), `Sa == 0` → `before` bit-for-bit, else `BlendOps.blend(options.blendMode, dst: before, src: (r, g, b, Sa))`. Only tiles in `ShapeRasterizer.bounds(of:canvas:)` ∩ clip bounds are visited, one 256×256 tile at a time (memory bounded even for 2000 pt text on a 65,535-px canvas). No second path rasterizer and no change to `ShapeRasterizer`.
   - Coverage semantics (needed for the oracle): antialiased = CoreGraphics area coverage of the path in an 8-bit alpha-only bitmap (`CGContext` `alphaOnly`, `setShouldAntialias(true)`, `interpolationQuality` irrelevant); aliased = `setShouldAntialias(false)` (coverage 0 or 255). No font smoothing/subpixel/hinting is involved because glyphs are filled as paths.

6. **`Core/Tools/Text/CaretBlink.swift`** (new): `enum CaretBlink { static let period = 1.0; static func isVisible(secondsSinceLastEdit t: Double, reduceMotion: Bool) -> Bool }` — `reduceMotion` → always true; else `t < 0` or `t.truncatingRemainder(dividingBy: period) < period / 2` → true (on for 0.5 s, off for 0.5 s, restarting "on" after every edit or caret move).

7. **`Core/Tools/Text/TextEditCommand.swift`** (new): the commands the input system sends (Cocoa `doCommand(by:)` selector names), mapped in Core so the mapping is testable:
   ```swift
   enum TextEditCommand: Sendable, Equatable {
       case newline, deleteBackward, deleteForward, moveLeft, moveRight, moveUp, moveDown,
            lineStart, lineEnd, textStart, textEnd
       init?(selectorName: String)
   }
   ```
   Table: `insertNewline:`, `insertLineBreak:`, `insertNewlineIgnoringFieldEditor:` → `.newline`; `deleteBackward:`, `deleteBackwardByDecomposingPreviousCharacter:` → `.deleteBackward`; `deleteForward:` → `.deleteForward`; `moveLeft:`, `moveBackward:` → `.moveLeft`; `moveRight:`, `moveForward:` → `.moveRight`; `moveUp:` → `.moveUp`; `moveDown:` → `.moveDown`; `moveToBeginningOfLine:`, `moveToLeftEndOfLine:` → `.lineStart`; `moveToEndOfLine:`, `moveToRightEndOfLine:` → `.lineEnd`; `moveToBeginningOfDocument:`, `moveToBeginningOfParagraph:` → `.textStart`; `moveToEndOfDocument:`, `moveToEndOfParagraph:` → `.textEnd`. Everything else (`insertTab:`, `deleteWordBackward:`, `moveWordLeft:`, selection-extending moves, `cancelOperation:`, …) → `nil` = ignored silently (no beep, no text change). Word moves and text-range selection are out of scope.

8. **`Core/Tools/TextTool.swift`** (new) — `@MainActor final class TextTool: Tool, TextInputTool`, `id = .text`. Registered in `ToolRegistry.standard()` (`.text: { TextTool() }`); update 0006's `standardRegistersZoomAndPan`/later `implementedIDs` expectations to include `.text`.
   - New protocol in the same file (the router talks to it; `NSRange` is Foundation):
     ```swift
     @MainActor protocol TextInputTool: Tool {
         var isEditingText: Bool { get }
         var markedRange: NSRange? { get }                 // UTF-16, in the pending text
         var selectedRange: NSRange { get }                // caret, length 0
         func setMarkedText(_ text: String, selectedRange: NSRange, context: any ToolContext)
         func unmarkText(context: any ToolContext)
         func perform(_ command: TextEditCommand, context: any ToolContext)
         func caretRectInCanvas(forUTF16Range range: NSRange) -> CGRect?   // for IME candidate window placement
         func substring(forUTF16Range range: NSRange) -> String?
     }
     ```
   - **State:** `idle` or `editing(Session)`, where `Session` holds `layerID`, `before: TiledSurface` (COW snapshot of the active layer at session start), `clip` (from `context.paintClipMask`, captured at session start and fixed, 0023 precedent), `anchor: PixelPoint`, `buffer: TextEditBuffer`, `preferredX: Double?` (sticky column for Up/Down, reset by any other edit or horizontal move), `touchedTiles: Set<TileCoordinate>` (union of every render), `nubDrag: (startAnchor: PixelPoint, startLocation: CGPoint)?`, `lastEdit: TimeInterval` (for the blink, from `ProcessInfo.systemUptime` via an injectable clock).
   - `hasPendingEdit` = `capturesKeyboard` = `isEditingText` = state is `editing` (even with empty text, so tool keys type characters right after placing the caret).
   - **Re-render** (after every edit, nub move, option change, or color change): inside `context.updateImage`: restore `touchedTiles` from `before`, then `TextRasterizer.render(layout, color: context.colors.primary, options:, clip:, before:, into:)` and add the result to `touchedTiles`; then publish the overlay (item 9). Triggers: `insertText`/`perform`/IME calls, nub moves, `optionsDidChange(context:)`, and `colorsDidChange(context:)` (item 13). Color is always the **primary** color, read at every re-render (Open question 5), whichever mouse button placed the text (Paint.NET: "using the Primary color").
   - **`mouseDown`** (either button; `.secondary` is treated the same):
     - `editing`, on the nub (`TextEditingGeometry.hitsNub`, item 9) → start `nubDrag`; cursor `.move`.
     - `editing`, inside `transform.canvasRectToView(layout.bounds).insetBy(dx: −4, dy: −4)` (view points) → `buffer.setCaret(layout.caretIndex(nearest: event.location))` (unmarks pending IME text first); no new session.
     - `editing`, elsewhere ("click outside", D-25) → `commit(context:)`, then start a new session at this point (Paint.NET behavior: the click places a new caret).
     - `idle` → if the active layer index is invalid, ignore; else start a session: `anchor = PixelPoint(x: Int(floor(location.x + 0.5)), y: Int(floor(location.y + 0.5)))` (round half up; non-finite or |v| > 1e9 → ignored), capture `layerID`, `before`, `clip`; empty buffer; publish the overlay. Nothing is rasterized (empty text).
   - **`mouseDragged`** with `nubDrag`: `anchor = startAnchor + round(location − startLocation)` per axis; re-render. Other drags: ignored. **`mouseUp`**: ends `nubDrag`.
   - **`keyDown(_:context:) -> Bool`** (overrides 0006's default; called by the dispatcher before `interpretKeyEvents`):
     - not editing → `false` (shortcuts and the default behaviors don't apply: nothing is pending).
     - `markedRange != nil` → `false` for every key (the input method handles Return, Escape, arrows, Delete during composition).
     - `nubDrag` in progress and an arrow key → move `anchor` by 1 px in that direction (and `startAnchor` with it so the drag stays consistent); `true`.
     - `.returnKey`/`.enter` **with `.command`** → `commit`; `true` (D-25 ⌘↩).
     - `.escape` → `commit`; `true` (Paint.NET: "press the Esc key … to render the text to the layer"; Open question 1). **Mechanism (no 0006 change):** 0006's dispatcher calls `activeTool.cancel(context:)` for Escape only while a mouse gesture is in progress (here: a nub drag → `cancel` reverts the drag, below); otherwise it forwards Escape to `activeTool.keyDown`, and this override replaces 0006's protocol-extension default (Escape → cancel) for `TextTool` only. Escape (`"\u{1b}"`) isn't in `ToolRegistry.allShortcutKeys`, so 0006's local monitor passes it through, and because `keyDown` returns `true`, `interpretKeyEvents` (`cancelOperation:`) isn't reached. Every other tool keeps 0006's default (0023/0038/0039: Escape cancels).
     - everything else → `false`, so the router calls `interpretKeyEvents`, which produces `insertText` (characters, Space, Tab is a command) or `doCommand(by:)` → `TextEditCommand` → `perform`.
     - ⌘-chords other than ⌘↩ never reach here as text: the menu handles its key equivalents first (see item 11).
   - **`insertText(_:context:)`**: `buffer.insert`; re-render; reset blink. `perform(.newline)` inserts `"\n"`; `.deleteBackward`/`.deleteForward`/moves call the buffer; `.moveUp`/`.moveDown` use `layout.caretIndex(fromUTF16:lineDelta:preferredX:)` with `preferredX` = the current caret x if nil. Edits that don't change the buffer (Backspace at 0) do nothing.
   - **`commit(context:)`** (⌘↩, Escape, Finish, click outside, `deactivate` on tool switch, document switch, `prepareForHistoryNavigation` before undo/redo/jump/save (0020 default), `.command` before Edit/Image/Layers commands): `unmarkText` (composition is accepted as typed), end any `nubDrag` at its current position, final re-render, `diff = TileDiff.between(before: before, after: layer.surface, layerID:, candidates: touchedTiles)`, `context.commitHistory(TileDiffHistoryItem(name: "Text", icon: .text, diff: diff))` (empty diff → no step, H-6/D-34: empty or whitespace-only text without underline, color alpha 0, fully clipped, fully off-canvas), clear the overlay, `idle`. If the layer `layerID` no longer exists (impossible through the UI because layer commands commit first; defensive) → `idle` without history.
   - **`cancel(context:)`**: only reached from 0006's "Escape during a gesture" (a nub drag): reverts the drag (`anchor = startAnchor`, re-render), text stays pending (0020 `escapeDuringDragCancelsOnlyDrag` precedent). When no drag is in progress (defensive callers), discard: restore `before` into the layer inside `updateImage` (pixel-identical, no history), clear the overlay, `idle`.
   - `prepareForHistoryNavigation`: 0020's default (commit), so ⌘Z while typing first records "Text" and then undoes it (Paint.NET also has no per-keystroke undo inside the text tool).
   - **`optionsDidChange(context:)`**: re-read `TextOptions.load`; if editing, re-render live (font, size, style, alignment, antialiasing, blend mode all apply to the whole pending text; Paint.NET has no per-character styling).
   - **`cursor(at:modifiers:)`**: `nil` → `.arrow`; over the nub or during `nubDrag` → `.move`; otherwise `.iBeam`.
   - `deactivate`: default (commit), then `setOverlay(nil)`.
   - `TextInputTool` members map to the buffer; `caretRectInCanvas(forUTF16Range:)` = `layout.caretRect(atUTF16: range.location)` with height = line height; `substring` returns the `displayText` slice or `nil` when out of range.

9. **Overlay geometry (Core).** `Core/Tools/ToolContext.swift` (extend 0006's `ToolOverlay`): `case textEditing(TextEditingPreview)` with
   ```swift
   struct TextEditingPreview: Equatable, Sendable {
       var caretRect: CGRect            // canvas
       var bounds: CGRect               // canvas, layout.bounds
       var markedUnderlineRects: [CGRect]   // canvas, one per line the marked range spans (empty when none)
       var lastEditUptime: TimeInterval
       var text: String                 // displayText, for accessibility only
   }
   enum TextEditingGeometry {
       static let nubSize: CGFloat = 14             // view points
       static let nubOffset = CGVector(dx: 10, dy: -10)   // from the caret's bottom point, view space (y up)
       static func nubCenter(caretRect: CGRect, transform: CanvasTransform) -> CGPoint      // view space
       static func hitsNub(viewPoint: CGPoint, caretRect: CGRect, transform: CanvasTransform) -> Bool  // distance ≤ nubSize/2 + 2
   }
   ```
   The nub follows the caret, below and to the right of it (Paint.NET). `caretBottom` = `transform.canvasToView(CGPoint(x: caretRect.minX, y: caretRect.maxY))`.

### Platform glue (AppKit/SwiftUI; UI tests and manual checks)

10. **`Canvas/TextEditingOverlay.swift`** (new): `final class TextEditingOverlay: NSView` (same frame as `CanvasView`, unflipped like `ToolOverlayView`, `hitTest(_:) → nil`), added by `DocumentWindowController` above `ToolOverlayView`. `ToolOverlayView` forwards `.textEditing(p)` to it (and clears it for any other overlay). Draws in view space:
    - the caret: a 1 pt wide (rounded to device pixels) vertical line from `transform.canvasRectToView(caretRect)`, black with a 1 pt white halo so it shows on any background, visible per `CaretBlink.isVisible(secondsSinceLastEdit:reduceMotion:)`;
    - a dashed 1 pt bounds rectangle (`canvasRectToView(bounds)` outset by 2 pt, white under black `[3, 3]`, static) so the editable area is visible;
    - the marked-text underline rects (2 pt, accent color) during IME composition;
    - the nub: a 14 pt rounded square with the `arrow.up.and.down.and.arrow.left.and.right` SF Symbol at `nubCenter`. Static (no pulsing) — Paint.NET pulses it; we don't animate anything but the caret.
    - Blink: a `Timer` at 0.25 s only while `.textEditing` is shown and Reduce Motion is off; invalidated otherwise. Reduce Motion = `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, observed via `accessibilityDisplayOptionsDidChangeNotification`, overridden by 0013's `-UITestReduceMotion` (`LaunchOptions.reduceMotionOverride`). Redraws on overlay and transform changes (0006 hook).
    - Accessibility: `setAccessibilityElement(true)`, role `.textArea`, identifier `canvas.textEditing`, value = `preview.text`; hidden (`isHidden = true`, not in the tree) when not editing.

11. **Input: `NSTextInputClient` on `CanvasView`** (decision). In `Canvas/TextEditingOverlay.swift`, `extension CanvasView: NSTextInputClient`, forwarding to `AppModel.shared.dispatcher.activeTool as? TextInputTool` when `isEditingText` (otherwise inert: `hasMarkedText` false, `insertText` ignored):
    - `insertText(_:replacementRange:)` → `dispatcher.insertText` (string from `String`/`NSAttributedString`); `setMarkedText(_:selectedRange:replacementRange:)` → `setMarkedText`; `unmarkText` → `unmarkText`; `hasMarkedText`, `markedRange`, `selectedRange` → the tool; `validAttributesForMarkedText` → `[]`; `attributedSubstring(forProposedRange:actualRange:)` → `substring`; `characterIndex(for:)` → `NSNotFound`; `firstRect(forCharacterRange:actualRange:)` → `caretRectInCanvas` → `transform.canvasRectToView` → `convert(_:to: nil)` → `window.convertToScreen`; `doCommand(by:)` → `TextEditCommand(selectorName: NSStringFromSelector(sel))` → `perform`, `nil` → ignored (no `NSBeep`).
    - On commit/cancel/tool switch the router calls `inputContext?.discardMarkedText()` and `NSTextInputContext.current?.invalidateCharacterCoordinates()` when the caret moves.
    - **Why `NSTextInputClient` instead of the plain `insertText` path:** without it, `interpretKeyEvents` can't show marked text, so dead keys (⌥E then E → é, ⌥U then U → ü) and every input method (Japanese, Chinese, Korean, emoji & symbols viewer, dictation) silently fail or insert raw characters. Mac users expect these in any text field. The cost is one extension of ~15 small methods; all logic stays in Core (`TextEditBuffer`, `TextEditCommand`). 0006's `textInputHasFocus` predicate already excludes `CanvasView`, so this conformance doesn't disable tool shortcuts when the Text tool is idle.
    - Router (`Canvas/CanvasInputRouter.swift`, extend 0006): unchanged order: `dispatcher.keyDown` first, then `interpretKeyEvents` when it returns false and `activeTool.capturesKeyboard`. Space and Tab go the same way. With the Text tool editing, the local shortcut monitor's gate is false (`toolCapturesKeyboard`), so T/B/E/S/…/X/D/C/[/]/⌫/⌥⌫ type or edit instead of acting (AGENTS.md rule 9, 0018).
    - Menu key equivalents (⌘Z, ⌘S, ⌘A, ⌘C, ⌘V, ⌘D, ⌘B, …) still work and commit the pending text first through the existing `prepareForNavigation`/`prepareForSave` hooks (Open question 4). Clicking the canvas makes it first responder (0006), so typing resumes after using the options bar.

12. **`UI/ToolOptionsBar.swift`** (extend `ToolOptionsContent`): case `.text`, left to right, reading/writing through `model.toolOptions` with `TextOptions.load/save`, each write reaching the active tool through 0006's `UserDefaultsToolOptionStore` onChange → `dispatcher.optionsDidChange()` (no extra call); text fields call `onEndEditing` on Return/Escape so the canvas gets focus back:
    - **Font** popup (`Picker`, `.menu`): "System Font", divider, `SystemFontCatalog.familyNames()`; each item rendered in its own font is out of scope (plain names). Identifier `toolOptions.font`, value = the display name. A stored family that isn't installed shows "System Font" (the stored value is kept).
    - **Size**: editable combo — `TextField` (number format, up to 2 decimals) plus a `Menu` of `sizePresets`. Identifier `toolOptions.fontSize`; invalid input reverts; out-of-range input clamps to 1…2000.
    - **Bold**, **Italic**, **Underline** toggle buttons (SF Symbols `bold`, `italic`, `underline`; `.help("Bold")` etc.). Identifiers `toolOptions.bold`, `toolOptions.italic`, `toolOptions.underline`.
    - **Alignment**: segmented control with `text.alignleft`, `text.aligncenter`, `text.alignright` ("Align Left", "Center Align", "Align Right"). Identifier `toolOptions.alignment`.
    - **Antialiasing** toggle (0009 pattern, `toolOptions.antialiasing`), **Blend mode** popup (0009 pattern, implemented `BlendMode` cases, `toolOptions.blendMode`).
    - **Finish** (0006, `toolOptions.finish`) is enabled while editing.

13. **Colors (live recolor; Open question 5).** A dedicated hook, separate from `optionsDidChange`, so palette changes never re-render or recolor tools that capture colors at creation (0023 Gradient, 0038 Line / Curve, 0039 Shapes) and never trigger their full re-render while the color wheel is dragged:
    - `Core/Tools/Tool.swift` (extend 0006): new requirement `func colorsDidChange(context: any ToolContext)` with a protocol-extension default **no-op**. Only `TextTool` implements it (re-render if editing; idle → nothing). `GradientTool`, `LineCurveTool`, `ShapesTool`, and every other tool keep the default.
    - `Core/Tools/ToolDispatcher.swift` (extend 0006): `func colorsDidChange()` → `activeTool.colorsDidChange(context:)` when a context exists (same shape as `optionsDidChange()`).
    - `App/AppModel.swift` (extend 0007): every method that changes `colors` (`swapColors`, `resetColors`, `setColor(_:for:)`, `setColorChannel(_:to:)`, `applyHex(_:)` when it returns true, `applyWheel(hue:saturation:to:)`) calls `dispatcher.colorsDidChange()` after saving, only when `colors` actually changed; `setActiveColorSlot`/`switchActiveColorSlot` (no color change) don't. `AppModel` does **not** call `dispatcher.optionsDidChange()` for color changes; `optionsDidChange` stays tool options only (0006's `toolOptions` onChange).
    - `PaintDotMacTests/Support/StubTool.swift` (extend 0006): record `"colorsDidChange"`.

14. `project.yml`: no target changes; run `xcodegen generate` after adding the files. No PRD.md change in this spec (sub-agent rule); Open questions 1–5 need PRD T-17/§12 entries once confirmed.

## Acceptance criteria

- [ ] Pressing T selects the Text tool; the options bar shows Font "System Font", Size 12, Bold/Italic/Underline off, Align Left, Antialiasing on, Blend mode Normal, Finish disabled. → `TextToolTests.defaultsMatchSpec`, `TextUITests.pressingTShowsOptions`
- [ ] Options persist under `tool.text.*`, sanitized on load. → `TextOptionsTests.roundTrip`, `.sanitizesStoredValues`
- [ ] Point size converts to pixels at the document DPI (px/em = pt × DPI / 72). → `TextOptionsTests.pixelsPerEm`
- [ ] The font list comes from Core Text, hides dot-prefixed families, and starts with "System Font"; bold/italic use real faces when present and are synthesized otherwise. → `SystemFontCatalogTests.*`
- [ ] Layout metrics, line breaks on Return, alignment, and caret positions are deterministic and match Core Text font metrics. → `TextLayoutEngineTests.*`
- [ ] Rasterized coverage matches an independent supersampling oracle (antialiased) and pixel-center oracle (aliased). → `TextRasterGoldenTests.*`
- [ ] Editing operations (insert, Backspace, Delete, arrows, Up/Down, line start/end, newline, grapheme clusters, IME marked text) behave as specified. → `TextEditBufferTests.*`, `TextToolTests.upDownUsesPreferredX`, `.markedTextLifecycle`
- [ ] Click places the caret; text renders live in the primary color, re-rendered from the original pixels after every edit and option change. → `TextToolTests.clickPlacesCaretAndTypingRendersLive`, `.optionChangeRerendersFromBefore`, `.primaryColorChangeRerenders`
- [ ] A palette change re-renders pending text in the new primary color through `Tool.colorsDidChange`; pending Gradient, Line / Curve, and Shapes edits keep their creation colors and aren't re-rendered. → `TextToolTests.primaryColorChangeRerenders`, `ToolDispatcherTests.colorsDidChangeForwarded`, `AppModelToolTests.colorChangesNotifyColorsDidChangeOnly`, `GradientToolTests.colorChangeDoesNotRecolorPending`, `LineCurveToolTests.colorsDidChangeIsNoOp`, `ShapesToolTests.colorsDidChangeIsNoOp`
- [ ] ⌘↩, Escape, Finish, tool switch, and a click outside commit exactly one "Text" step; a click inside moves the caret; Return inserts a line. → `TextToolTests.commandReturnCommits`, `.escapeCommits`, `.deactivateCommits`, `.clickOutsideCommitsAndStartsNew`, `.clickInsideMovesCaret`, `.returnInsertsNewline`; `TextUITests.typeCommitUndoRedoAndSave`
- [ ] Empty or invisible text commits no step. → `TextToolTests.emptyCommitAddsNoStep`
- [ ] Dragging the nub moves the text; arrow keys nudge it by 1 px while the nub is held; Escape during the drag reverts only the drag. → `TextToolTests.nubDragMovesText`, `.arrowNudgeDuringNubDrag`, `.escapeDuringNubDragRevertsDrag`
- [ ] Undo/redo restore the exact pixels; undo or save while editing commits first. → `TextIntegrationTests.undoRedoExact`, `.undoWhileEditingCommitsFirst`, `.saveWhileEditingCommitsFirst`
- [ ] Text is clipped to the selection (TOOL-B) and respects the blend mode. → `TextToolTests.respectsClipHook`, `TextRasterGoldenTests.normalBlendOverSemiTransparent`
- [ ] Tool shortcuts and ⌫/⌥⌫/X/D/[/] don't fire while typing; Space types a space. → `TextToolTests.capturesKeyboardWhileEditing`, `ToolDispatcherTests.textToolBlocksShortcutsWhileEditing`; `TextUITests.toolKeysTypeWhileEditing`
- [ ] Characters the font lacks render through a fallback font. → `TextLayoutEngineTests.fallbackFontForMissingGlyphs`
- [ ] Input-method selectors map to edit commands; unknown selectors are ignored. → `TextEditCommandTests.*`
- [ ] Caret blinks 0.5 s on / 0.5 s off and is steady under Reduce Motion. → `CaretBlinkTests.*`; manual 3
- [ ] Dead keys and an input method compose text. → manual 2 (XCUITest can't drive input methods reliably)
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Empty session** (click, then commit): no step, layer untouched. → `TextToolTests.emptyCommitAddsNoStep`
- **Whitespace only:** no ink → no step; with Underline on, the underline is ink → a "Text" step. → `.whitespaceOnly`, `.underlinedSpacesCommit`
- **Primary color alpha 0:** renders nothing; commit adds no step. → `.zeroAlphaAddsNoStep`
- **Text partly or fully off-canvas** (click near the edge, right alignment at x = 0, nub dragged away): only on-canvas pixels change; fully off → no step; no crash. Anchor outside the canvas is allowed. → `.offCanvasClipsSafely`
- **Huge size** (2000 pt at 300 DPI → clamped 65,535 px/em) on a small canvas: completes, touches only canvas tiles. → `TextRasterizerTests.hugeSizeTouchesOnlyCanvasTiles`
- **Very long text** (10,000 characters on one line): renders; tiles visited are bounded by the canvas. → `TextPerformanceTests` (also used for the timing)
- **Grapheme clusters:** "e\u{301}", "🇫🇷", "👩‍👩‍👧" move and delete as one unit. → `TextEditBufferTests.graphemeClusters`
- **CR/LF and control characters** in pasted/IME input: `\r\n`, `\r` → `\n`; other controls dropped. → `TextEditBufferTests.normalizesInput`
- **Color emoji** (no outlines): occupy their advance but render no ink (documented limitation; Paint.NET Smooth mode draws them in color, which straight single-color rasterized text can't). → `TextLayoutEngineTests.colorEmojiHasNoInk`
- **Uninstalled stored font family:** falls back to the system font; no crash. → `SystemFontCatalogTests.missingFamilyFallsBack`
- **Family without bold/italic face:** synthesized; ink differs from regular. → `TextRasterizerTests.syntheticStylesChangeInk`
- **Up on the first line / Down on the last:** caret to text start / end. → `TextLayoutEngineTests.upDownAtEdges`
- **IME composition active when committing / switching tools / clicking outside:** the marked text is accepted as typed, then committed. → `TextToolTests.markedTextLifecycle`
- **Escape during IME composition:** goes to the input method (cancels the composition), doesn't commit. → `.keysPassToInputMethodWhileMarked`
- **Escape during a nub drag:** reverts only the drag. → `.escapeDuringNubDragRevertsDrag`
- **Active layer hidden:** text still renders into it (same as other tools). **Layer removed while editing** (defensive): commit/re-render → `idle`, no history, no crash. → `.layerRemovedEndsSession`
- **Document DPI 72 / 300:** size scales (12 pt → 12 px / 50 px em). → `TextOptionsTests.pixelsPerEm`, `TextLayoutEngineTests.dpiScalesLayout`
- **Non-finite click location:** ignored (0006 drops non-finite events; the tool also guards). → `.nonFiniteLocationIgnored`
- **Zoom/pan while editing** (pinch, scroll): overlay follows (glue redraw); text unchanged. → manual 1
- **Document switch / window close while editing:** 0006's `setContext` → `deactivate` commits into the old document. → `TextToolTests.deactivateCommits`; manual 5
- **Menu commands while editing** (⌘A, ⌘D, ⌘V, Image/Layers menus): commit "Text" first, then act. → `TextIntegrationTests.commandCommitsFirst`

## Test plan

Expected values come from Core Text font metrics queried directly in the test (an independent path from `CTLine` layout), hand calculation, or the oracles described; never from running the code under test and pasting its output. Deterministic font: **Helvetica** (`/System/Library/Fonts/Helvetica.ttc`, ships with every macOS 15 install, has Regular, Bold, Oblique, Bold Oblique, no CJK). Fallback test character: "あ" (U+3042), covered by Hiragino Sans, which ships with macOS 15.

- **Unit — `PaintDotMacTests/Tools/Text/TextOptionsTests.swift`:**
  - `defaults`: empty store → `TextOptions.default`.
  - `roundTrip`: save `("Helvetica", 18.3, bold, italic, underline, .right, AA false, .normal)` → keys `tool.text.fontFamily == "Helvetica"`, `tool.text.size == 18.3`, …, `tool.text.alignment == "right"`; `load` returns the same value.
  - `sanitizesStoredValues`: size 0 → 1, 5000 → 2000, NaN → 12, −3 → 1; alignment `"justify"` → `.left`; blendMode `"foo"` → `.normal`.
  - `pixelsPerEm`: (12, 96) → 16; (12, 72) → 12; (12, 300) → 50; (18.3, 96) → 24.4 (±1e-9); (2000, 96) → 2666.666…; (2000, 300) → 8333.33…; (1, 1) → 1 (clamp); (12, 0) and (12, .nan) → 16 (96 fallback); (2000, 65_535) → 65,535 (clamp).
- **Unit — `PaintDotMacTests/Tools/Text/SystemFontCatalogTests.swift`:** `listsInstalledFamilies` (contains "Helvetica" and "Hiragino Sans"; no entry starts with "."; sorted per `localizedStandardCompare`; no duplicates); `systemFontDefault` (`resolve(family: "", pixelsPerEm: 16, …)` → `CTFontGetSize == 16` and its family equals `CTFontCreateUIFontForLanguage(.system, 16, nil)`'s family); `realBoldItalic` (Helvetica bold → PostScript name "Helvetica-Bold", italic → "Helvetica-Oblique", both → "Helvetica-BoldOblique", no synthetic flags); `missingFamilyFallsBack` ("NoSuchFamily-0040" → system font family, no crash); `synthesizesMissingTraits` (pick at runtime the first installed family in `familyNames()` whose regular face fails `CTFontCreateCopyWithSymbolicTraits(…, kCTFontTraitBold, …)` — e.g. "Zapfino"; if none exists, the test uses a descriptor-created font with the trait request forced through an internal `resolve(font:bold:italic:)` overload and asserts the flags are set).
- **Unit — `PaintDotMacTests/Tools/Text/TextEditBufferTests.swift`:** `insertAndCaret` ("abc" → caret 3; moveLeft ×2, insert "X" → "aXbc", caret 2); `deleteBackwardAndForward` (at 0 no-op; at end deleteForward no-op; "ab|c" ⌫ → "a|c", ⌦ → "a|"); `newlineSplitsAndJoins` (insert "\n" in "ab|cd" → lines ["ab","cd"], caret 3; ⌫ → "abcd"); `trailingNewlineKeepsEmptyLine` ("a\n" → lines ["a", ""]); `lineStartEnd` (caret in second line of "ab\ncde" at 4 → lineStart 3, lineEnd 6; textStart 0, textEnd 6); `graphemeClusters` ("e\u{301}x": moveRight from 0 → 2 (UTF-16), ⌫ at 2 → "x"; "🇫🇷" is 4 UTF-16 units and moves/deletes as one; ZWJ family as one; `setCaret(1)` inside "🇫🇷" snaps to 0); `normalizesInput` ("a\r\nb\rc\u{7}" → "a\nb\nc"); `markedTextLifecycle` (insert "ab", setMarked("´", (1,0)) → displayText "ab´", markedRange (2,1); setMarked("é") replaces it; unmark → text "abé", markedRange nil; setMarked("x") then insert("y") → "abéy" (insert replaces marked); setMarked("") → no marked range, text unchanged).
  - Property (seeded 500 random op sequences over a 20-character alphabet incl. "\n", "é" decomposed, and an emoji; seed printed): caret always on a grapheme boundary within 0…utf16 count; `displayText == text` whenever `markedRange == nil`; lines joined by "\n" == text.
- **Unit — `PaintDotMacTests/Tools/Text/TextEditCommandTests.swift`:** every selector in item 7's table maps to its case (table-driven, literal); `"insertTab:"`, `"deleteWordBackward:"`, `"cancelOperation:"`, `"moveWordLeft:"`, `"moveLeftAndModifySelection:"`, `""` → nil.
- **Unit — `PaintDotMacTests/Tools/Text/TextLayoutEngineTests.swift`** (Helvetica, 12 pt @ 96 DPI = 16 px/em unless stated; oracle `f = CTFontCreateWithName("Helvetica", 16, nil)`):
  - `metricsMatchFont`: `ascent == CTFontGetAscent(f)`, `descent`, `lineHeight == ascent + descent + CTFontGetLeading(f)` (exact Double equality).
  - `singleLineWidthMatchesAdvances`: "Hello": `lines[0].width` == sum of `CTFontGetAdvancesForGlyphs` for the glyphs of "Hello" from `CTFontGetGlyphsForCharacters` (±1e-6; Helvetica has no kerning applied by default in CTLine for this pair set — if CT applies kerning the oracle adds `kCTKernAttributeName`-free shaping via `CTFontGetAdvancesForGlyphs` only, so the test text uses "Hill" if "Hello" differs; the implementer picks a string without kerning pairs and documents it).
  - `baselinesAndAnchor`: anchor (10, 20): line 0 baseline y == 20 + round(ascent); text "a\nb\n" → 3 lines, line i baseline == 20 + round(ascent + i × lineHeight); bounds.minY == 20, bounds.height == 3 × lineHeight (±1e-9 against the rounding formula).
  - `alignment`: "Hill" with anchor x 100: left → `lines[0].origin.x == 100`; center → `== (100 − w/2).rounded()`; right → `== (100 − w).rounded()`; multi-line "a\nwww" centered → each line centered on 100 independently.
  - `caretPositions`: "Hill" left at x 10: caretRect(0).minX == 10; caretRect(4).minX == 10 + w; caretRect(1).minX == 10 + advance("H"); "ab\ncd": caretRect(3) is on line 1 at x 10 (start of line), caretRect(2) on line 0 at the end; empty text: caretRect(0) == (10, 20, 0, lineHeight).
  - `caretIndexNearest`: point at the middle of "i" in "Hill" → 1 or 2, whichever half is clicked (left half → 1, right half → 2); below the last line → index on the last line; x left of the line → line start.
  - `upDownAtEdges`: "abc\nd": from 1 Up → 0; from 4 Down → 5; Down from 1 with preferredX at x of index 1 → 5 (end of shorter line "d" when x beyond its width).
  - `dpiScalesLayout`: same text at DPI 192 → `ascent` and widths exactly 2× the 96 DPI values (±1e-6).
  - `fallbackFontForMissingGlyphs`: "Aあ" in Helvetica → `CTLineGetGlyphRuns` count ≥ 2, the run containing "あ" has a font whose family ≠ "Helvetica", and `glyphPath.boundingBoxOfPath` extends past the "A" advance (non-empty outline for "あ").
  - `colorEmojiHasNoInk`: "😀" → width > 0, `glyphPath.isEmpty`.
  - `underlineAddsRect`: "Hill" underline on → `glyphPath` bounding box bottom ≥ baseline − underlinePosition + thickness/2 − 1e-6; off → bounding box bottom equals the glyph-only oracle path's bottom (oracle path built in the test from `CTFontCreatePathForGlyph` + advances).
- **Golden/oracle — `PaintDotMacTests/Tools/Text/TextRasterGoldenTests.swift`** (layer 120×60 transparent `(0,0,0,0)` or opaque white as stated; color opaque black; Helvetica 24 pt @ 96 DPI = 32 px/em; text "Ag&" at anchor (4, 4)):
  - Oracle `TextCoverageOracle` (test target): rebuilds the glyph outlines independently from `CTFontGetGlyphsForCharacters`, `CTFontGetAdvancesForGlyphs`, and `CTFontCreatePathForGlyph` (no `CTLine`; "Ag&" has no kerning pairs in Helvetica's default shaping — asserted first by comparing the oracle's advances to `layout.lines[0].width`) and computes per-pixel coverage by 16×16 supersampling with `CGPath.contains(_:using: .winding)` → `round(255 × inside / 256)`.
  - `antialiasedMatchesOracle`: render onto transparent → resulting alpha per pixel vs oracle: every pixel |Δ| ≤ 24 and ≥ 99 % of pixels |Δ| ≤ 8, total ink (sum of alpha) within 1 % of the oracle's; RGB of every pixel with alpha > 0 is `(0,0,0)`.
  - `aliasedMatchesPixelCenters`: AA off → every alpha is 0 or 255; pixels where the oracle's pixel-center `contains` disagrees ≤ 2 % of the oracle's ink pixels.
  - `normalBlendOverSemiTransparent`: background `(200,100,50,128)`, color `(0,0,255,255)`: for every pixel, result == `BlendOps.blend(.normal, dst: bg, src: (0,0,255, coverage))` where `coverage` is the rendered coverage measured from the same text on a transparent layer (exact equality).
  - `colorAlphaScalesCoverage`: color alpha 128 → each result alpha == `mul255(128, coverage)` (exact).
  - Goldens: the antialiased transparent render is stored as `PaintDotMacTests/Golden/text_Ag_helvetica24.png` only via `RECORD_GOLDENS=1` after the oracle checks pass, and compared with `GoldenImage` ±1 (catches regressions in clipping/blend plumbing; the oracle is the source of truth if the OS font changes — then re-record after the oracle passes).
- **Unit — `PaintDotMacTests/Tools/Text/TextRasterizerTests.swift`:** `hugeSizeTouchesOnlyCanvasTiles` (300×300 layer, 2000 pt @ 300 DPI "W" at (0,0) → returned tiles ⊆ the canvas's single tile; completes); `syntheticStylesChangeInk` (Helvetica regular "Hill" with forced `syntheticBold` → total ink > regular's ink × 1.15; forced `syntheticItalic` → ink bounding box of the top row shifted right of the bottom row, ink total within 5 % of regular); `rerenderFromBeforeIsIdempotent` (render twice with the same layout from the same `before` → identical surfaces).
- **Unit — `PaintDotMacTests/Tools/Text/CaretBlinkTests.swift`:** t = 0, 0.49 → visible; 0.5, 0.99 → hidden; 1.0 → visible; −1 → visible; any t with `reduceMotion` → visible.
- **Unit — `PaintDotMacTests/Tools/Text/TextEditingGeometryTests.swift`:** identity-ish transform (100 %, 1×): caretRect (10, 20, 0, 16) → nubCenter == `canvasToView((10, 36)) + (10, −10)`; at 400 % the offset stays 10 pt (view space) while the caret bottom scales; `hitsNub` true at the center and at 8.9 pt, false at 9.1 pt.
- **Unit — `PaintDotMacTests/Tools/TextToolTests.swift`** (`FakeToolContext` 200×100 opaque white, primary black, Helvetica via store, `InMemoryToolOptionStore`, fixed clock):
  - `defaultsMatchSpec`: empty store → `TextOptions.default`; `ToolRegistry.standard().isImplemented(.text)`; `descriptor(for: .text).supportsPendingEdits`; not editing → `capturesKeyboard == false`, `hasPendingEdit == false`.
  - `clickPlacesCaretAndTypingRendersLive`: down/up at (20.4, 30.6) → editing, anchor (20, 31), overlay `.textEditing` with caretRect.minX 20, `capturesKeyboard`; `insertText("Hi")` → pixels inside `layout.bounds` contain black-ish (alpha 255, R < 128) pixels and every pixel outside `bounds.insetBy(-2,-2)` is still white; no `commitHistory` yet.
  - `returnInsertsNewline`: keyDown(.returnKey) → `false` (goes to interpretKeyEvents); `perform(.newline)` → 2 lines, caret on line 1.
  - `commandReturnCommits`: keyDown(.returnKey + `.command`) → `true`, one `commitHistory` named "Text", icon `.text`, non-empty diff; idle; overlay nil.
  - `escapeCommits`: Escape → `true`, one "Text" commit.
  - `deactivateCommits`, `finishCommits` (`dispatcher.commitPendingEdit()`): one commit each.
  - `clickOutsideCommitsAndStartsNew`: editing "Hi" at (20,31), down at (150, 80) (outside bounds + 4 pt) → one commit, new session anchored (150, 80), empty.
  - `clickInsideMovesCaret`: "Hill" then down inside the bounds near the left edge → caret 0, no commit, same anchor.
  - `emptyCommitAddsNoStep`, `whitespaceOnly`, `underlinedSpacesCommit`, `zeroAlphaAddsNoStep` (as in Edge cases; "no step" = `commitHistory` called with an empty diff or not at all, and pixels unchanged).
  - `optionChangeRerendersFromBefore`: type "Hill", store size 48 + `optionsDidChange` → pixels equal a fresh 48 pt render onto the original white layer (exact); store size back to 12 → pixels equal the 12 pt render (no leftover ink from the 48 pt render).
  - `primaryColorChangeRerenders`: set `colors.primary = (255,0,0,255)` + `colorsDidChange(context:)` → pixels equal a fresh red render of the same layout onto the original white layer (exact); idle `colorsDidChange` → no `updateImage` call.
  - `upDownUsesPreferredX`: "abcdef\nab\nabcdef" caret at 5 → Down → line 1 end (offset 9) → Down → offset 15 (same x as 5 via preferredX).
  - `markedTextLifecycle`: setMarkedText("´") → `markedRange` (n,1), overlay `markedUnderlineRects` non-empty; `commit` → text includes "´", one commit; new session: setMarkedText("か") then `deactivate` → committed with "か".
  - `keysPassToInputMethodWhileMarked`: with marked text, keyDown for `.escape`, `.returnKey`+`.command`, `.leftArrow`, `.delete` → all `false`, still editing.
  - `nubDragMovesText`: type "Hi" at (20,31); mouseDown at the nub's canvas position (computed with `TextEditingGeometry` and the context transform), drag by (+30.4, +10.6) → anchor (50, 42); pixels equal a fresh render at (50, 42) on the original layer; cursor `.move`.
  - `arrowNudgeDuringNubDrag`: during the drag, `.rightArrow` → anchor x + 1, returns `true`.
  - `escapeDuringNubDragRevertsDrag`: through `ToolDispatcher` (Escape during a gesture calls `cancel`): anchor back to (20, 31), still editing "Hi".
  - `respectsClipHook`: `paintClipMask` = x < 40 → 255 else 0; text "WWWWWW" from (10, 10) at 24 pt; after commit every pixel with x ≥ 40 is white, and some pixel with x < 40 is not.
  - `offCanvasClipsSafely`: right-aligned at (0, 10) → commit adds no step; text at (190, 90) → only on-canvas pixels differ, no crash.
  - `capturesKeyboardWhileEditing`: while editing, `ToolShortcutGate.allows(…, toolCapturesKeyboard: tool.capturesKeyboard, …) == false`; after commit `true`.
  - `layerRemovedEndsSession`, `nonFiniteLocationIgnored`, `cursorRoles` (nil → `.arrow`, canvas → `.iBeam`, nub → `.move`).
- **Unit — `PaintDotMacTests/Tools/ToolDispatcherTests.swift`** (extend): `textToolBlocksShortcutsWhileEditing` (real `TextTool`, editing: `handleShortcut("b")` → `false` and the active tool stays `.text`; `insertText("b")` reaches the tool's buffer; after ⌘↩, `handleShortcut("b")` → Paintbrush). `colorsDidChangeForwarded`: stub active → `dispatcher.colorsDidChange()` → stub records `"colorsDidChange"` and **not** `"optionsDidChange"`; no context → nothing recorded.
- **Unit — `PaintDotMacTests/App/AppModelToolTests.swift`** (extend 0006): `colorChangesNotifyColorsDidChangeOnly`: with a `StubTool` active, each of `swapColors()`, `resetColors()`, `setColor(_:for:)`, `applyHex("#112233")` → exactly one `"colorsDidChange"` and no `"optionsDidChange"`; `applyHex("bad")` and `switchActiveColorSlot()` → nothing.
- **Regression — capture-at-creation tools ignore palette changes** (same files as their specs, extended here): `GradientToolTests.colorChangeDoesNotRecolorPending`, `LineCurveToolTests.colorsDidChangeIsNoOp`, `ShapesToolTests.colorsDidChangeIsNoOp`: pending edit, set `FakeToolContext.colors.primary` to (255,0,0,255), call `tool.colorsDidChange(context:)` and then `tool.optionsDidChange(context:)` → layer pixels unchanged (every tile `sharesStorage` with the pre-call surface or equal), and the later commit still uses the creation colors.
- **Integration — `PaintDotMacTests/Integration/TextIntegrationTests.swift`** (headless `DocumentState` 400×200 white via 0005 New Image helper, `UndoBridge` base `.newImage`, a `ToolContext` double forwarding `updateImage`/`commitHistory`, the 0020 `prepareForNavigation` hook wired to `dispatcher.resolvePendingEdit(for:)`):
  - `undoRedoExact`: type "Hello" + ⌘↩ → history names `["New Image", "Text"]`; snapshot A; undo → every tile equal to the white base (sharesStorage or equal); redo → equals A.
  - `undoWhileEditingCommitsFirst`: editing "Hi", `undoBridge.undo()` → the "Text" step was committed then undone: pixels white, redo available named "Text".
  - `saveWhileEditingCommitsFirst`: editing "Hi", `prepareForSave()` → history ends with "Text"; tool idle.
  - `commandCommitsFirst`: editing, then the Select All command path (`prepareForNavigation` reason `.command`, `SelectionCommand.selectAll`) → steps end `"Text", "Select All"`.
  - `twoSessionsTwoSteps`: type, click outside, type, ⌘↩ → two "Text" steps; undo once removes only the second text's pixels.
- **UI — `PaintDotMacUITests/TextUITests.swift`** (fixtures generated at test time with `UITestFixtures.writePNG`, `-UITestResetDefaults`):
  - `pressingTShowsOptions`: type `t` → `tool.text` selected; `toolOptions.font` "System Font", `toolOptions.fontSize` "12", `toolOptions.bold`/`.italic`/`.underline` off, `toolOptions.alignment` "Align Left", `toolOptions.antialiasing` on, `toolOptions.blendMode` "Normal", `toolOptions.finish` disabled.
  - `typeCommitUndoRedoAndSave`: open a 4000×1000 opaque white PNG (opens fitted, spanning the view width, so normalized canvas offsets map to image coordinates ≈ x × 4000); `t`; set `toolOptions.fontSize` to 200 and press Return; click the canvas at normalized (0.25, 0.5) (≈ image (1000, 500)); `canvas.textEditing` exists; type `Hello`; `canvas.textEditing` value == "Hello"; `toolOptions.finish` enabled; press ⌘↩ → History row "Text", Edit menu "Undo Text", `canvas.textEditing` gone; ⌘S; read the PNG with ImageIO: ≥ 2,000 non-white pixels, all of them inside x ∈ [940, 2000], y ∈ [460, 900] (200 pt @ 96 DPI = 266.7 px/em: cap height ≈ 190 px and "Hello" ≈ 2.4 em ≈ 640 px wide in the system font, plus ±60 px for click placement at fit zoom); no non-white pixel in the rest of the image. ⌘Z, ⌘S, reread → all white. ⇧⌘Z → "Text" row again.
  - `toolKeysTypeWhileEditing`: click to place, type `bes xd[]` → `tool.text` still selected (no Paintbrush/Eraser/Rectangle Select switch, colors unchanged: `colors.primary` value unchanged), `canvas.textEditing` value == "bes xd[]"; press ⌫ twice → value "bes xd" (⌫ edited text; Edit menu has no "Undo Erase Selection"). ⌘↩, then `b` → `tool.paintbrush` selected.
  - `escapeCommitsAndClickOutsideStartsNew`: place, type `A`, Escape → History "Text"; place, type `B`, click elsewhere on the canvas → a second "Text" row and `canvas.textEditing` value "" (new empty session).
  - `toolSwitchCommits`: place, type `A`, click `tool.paintbrush` in the Tools panel → History "Text".
  - `optionsPersistAcrossRelaunch`: set Bold on, size 36, Center Align; quit; relaunch without reset → values restored.
- **Performance — `PaintDotMacTests/Performance/TextPerformanceTests.swift`** (XCTest `measure`): re-render of a pending 20-line × 80-character text at 24 pt @ 96 DPI on a 4000×3000 opaque layer (the per-keystroke cost; NF-1 responsiveness); and a single 10,000-character line at 12 pt. Report only; gate at 3× a 50 ms target for the 20-line case. NF-4: the history item holds only the changed tiles.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green (clean build, no warnings, all tests pass, none skipped, UI tests ran, launch smoke).
- **Manual verification:**
  1. At 100 %, 400 %, and 25 % zoom on 1× and 2× displays: caret, dashed bounds, and nub track the text while typing, panning, pinching; the nub sits below-right of the caret and dragging it moves the text smoothly.
  2. Dead keys: ⌥E then E → "é"; ⌥U then O → "ö" (U.S. layout). Japanese – Romaji input: type "kana", the composition shows underlined, the candidate window appears next to the caret, Return accepts it without committing the text; Escape cancels the composition. Emoji & Symbols viewer (⌃⌘Space) inserts a character (color emoji render nothing; expected).
  3. Caret blinks about once a second; with System Settings > Accessibility > Display > Reduce motion on, the caret is steady.
  4. Fonts: pick several families from the Font popup (e.g. Helvetica, Times New Roman, Menlo, a family without bold such as Zapfino with Bold on): the pending text restyles live; bold/italic/underline look right; antialiasing off gives hard pixel edges.
  5. Switch to another document window (or tab) while editing: the text is committed into the first document as "Text".
  6. With a selection active, text outside it is clipped; marching ants stay visible.

## Open questions

1. **Escape: commit or cancel?** Paint.NET's Text tool page says "press the Esc key or click Finish in the Tool Bar to render the text to the layer" (Esc **commits**), whereas 0006's default and the other editable tools (Gradient, Move Selected Pixels, Line / Curve, Shapes) treat Escape as cancel. PRD T-17/D-25 list the commit gestures (tool switch, ⌘↩, click outside) but are silent on Escape. **Recommended and applied:** Escape commits, as in Paint.NET (discarding typed text on a stray Escape is destructive, and ⌘Z removes the committed text in one step). Escape during a nub drag reverts only the drag; during IME composition it goes to the input method.
2. **Size units and the pixel conversion.** PRD T-17 says "12 pt" but doesn't define the conversion, and Paint.NET's page is inconsistent ("scaled according to the image DPI", 1 pt = 1/72 in, yet "pixel height ≈ points × DPI / 96"). **Recommended and applied:** sizes are points at the document DPI, em size in pixels = pt × DPI / 72 (12 pt @ 96 DPI = 16 px, matching Paint.NET's "Fixed (96 DPI)" output at 96 DPI and Windows/macOS typography). No "Fixed (96 DPI)" unit option in v1.0.
3. **Blend mode option.** Paint.NET's Text toolbar has the tool blend mode, but PRD T-17's option list doesn't name it. **Recommended and applied:** include the Blend mode popup with the same list as the Paintbrush (D-15), default Normal.
4. **Clipboard and other menu shortcuts while typing.** Paint.NET lets you type; it is unclear whether ⌘V should paste text into the pending text. **Recommended and applied:** v1.0 has no text clipboard in the Text tool; every menu command (⌘V, ⌘C, ⌘A, ⌘Z, …) commits the pending text first and then acts on the image, like every other pending edit.
5. **Changing the primary color while text is pending.** Paint.NET re-colors the pending text live; 0023 captures colors at creation for the Gradient. **Recommended and applied:** the pending text always uses the current primary color and re-renders when it changes (AppModel calls `dispatcher.colorsDidChange()` on color changes; only `TextTool` implements `Tool.colorsDidChange`, so the Gradient, Line / Curve, and Shapes keep their creation colors).

## Out of scope

- Strikeout, the three Paint.NET rendering modes (Smooth / Sharp (Modern) / Sharp (Classic)), the "Fixed (96 DPI)" size unit, per-character styling, text wrapping in a box, text layers / re-editing committed text (PRD T-17: rasterized only).
- Text-range selection (Shift+arrows, drag-select), word-wise moves/deletes, text clipboard (Open question 4), undo inside the pending text.
- Color emoji rendering (bitmap glyphs render no ink).
- Font popup items drawn in their own typeface; recent-fonts list.
- Tablet pressure (0055); Line/Curve and Shapes (0038, 0039). This spec reuses 0038's `ShapeRasterizer` unchanged and none of the editable-shape types.
- Use-case 1 end-to-end acceptance test (0051).
