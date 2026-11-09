# 0006 — Add the tool framework, the floating panels, the tool options bar, and the Zoom and Pan tools

> Source: PRD.md §5.1 APP-2 (four floating `NSPanel`s, Window menu ⌥⌘1–4, frame autosave), APP-4 (tool options bar at the top of each document window); PRD.md §5.3 (single-key shortcuts and group cycling — pressing a key again within 1 second cycles forward, Shift+key cycles backward, the app starts with the Paintbrush and the active tool is not remembered (D-35); D-13 order: **S** Rectangle Select → Lasso Select → Ellipse Select → Magic Wand; **M** Move Selected Pixels → Move Selection; **O** Line / Curve → Shapes), TOOL-C (tool settings persist), T-7 Zoom, T-8 Pan; PRD.md §5.12 (tool keys "active when no text field has focus", panel toggles ⌥⌘1–4); PRD.md §5.1 APP-2 / D-36 (a panel whose spec hasn't landed shows "Not available yet."); PRD.md §4 Testing row (D-37 `-UITestResetDefaults` clears the `tool.`, `panel.`, `colors.`, and `settings.` defaults and panel frames); AGENTS.md architecture rules 1, 6, 7, 9.
> Paint.NET references (the `www.getpaint.net/doc/latest/*` URLs now redirect to `paint.net/doc/latest/*`):
> - Tools Window — https://www.getpaint.net/doc/latest/ToolsWindow.html
> - View tools (Zoom, Pan) — https://www.getpaint.net/doc/latest/ViewTools.html
> - Keyboard & mouse commands — https://www.getpaint.net/doc/latest/KeyboardMouseCommands.html
> - Tool Bar — https://www.getpaint.net/doc/latest/Toolbar.html
> Milestone: M1
> Depends on: 0004-zoom-pan-and-status-bar (and through it 0001, 0002, 0003). 0005 is lower-numbered and already done when this starts; its New Image dialog is used by one UI test.

## Context

No application code exists yet. When this spec starts, the following exist (read their specs in `docs/specs/done/` first and use their exact names; where this spec names a sibling API and the shipped name differs, the shipped name wins and the behavior below stays):

- **0001** — `App/main.swift`, `App/AppDelegate.swift`, `App/MainMenu.swift` (`@MainActor enum MainMenu` with `make()`/`install(in:)`; top-level identifiers `menu.app`, `menu.file`, `menu.edit`, `menu.view`, `menu.window`, `menu.help`; the Window menu is Minimize ⌘M, Zoom, —, Bring All to Front), `App/LaunchOptions.swift` (`resettableKeyPrefixes`: 0001 ships `["tool.", "panel.", "NSWindow Frame panel."]` and 0004 adds `"settings."`; the panel autosave names chosen here must start with `panel.`), `Document/PaintDocument.swift`, `Document/DocumentWindowController.swift` (window identifier `documentWindow`), `PaintDotMacUITests/Support/UITestApp.swift` (`launch(opening:resetDefaults:extraArguments:)`, `makePNG(named:width:height:rgba:)`, `menuItem(_:_:)`, `chooseMenuItem(_:_:)`, `dragOnCanvas(from:to:holdDuration:)`, `waitForDocumentWindowCount(_:timeout:)`). The unit-test target is hosted (`TEST_HOST`), so tests can `@testable import PaintDotMac` and use AppKit.
- **0002** — `Core/Model/LayeredImage.swift`, `Core/Model/PixelSize.swift` (+ `PixelPoint`, `PixelRect`).
- **0003** — `Core/Rendering/CanvasTransform.swift`: `struct CanvasTransform` with `zoom` (device pixels per image pixel; 1.0 = 100 %), `viewSize` (points), `backingScale`, `viewToCanvas(_:)`, `canvasToView(_:)`, `canvasRectToView(_:)`, `visibleCanvasRect`. **View space is AppKit points, origin bottom-left, y up (the `MTKView` is not flipped). Canvas space is image pixels as `Double`, origin top-left, y down; pixel `(i, j)` covers `[i, i+1) × [j, j+1)`.** `Canvas/CanvasView.swift` (`MTKView` subclass, accessibility `canvas`, `acceptsFirstResponder == true`).
- **0004** — `Core/Rendering/ZoomLevels.swift` (`minimum` 0.01, `maximum` 32, `nextLarger(than:) -> Double?`, `nextSmaller(than:) -> Double?`, `fitZoom(contentSize:viewportSize:allowsEnlargement:)` — "0006's Zoom tool rectangle will use `allowsEnlargement: true`", `percentString(_:)`), `Core/Rendering/SpacePanState.swift`, `Canvas/CanvasNavigation.swift` (`@MainActor final class CanvasNavigation`, one per document window, with `setZoom(_:anchoredAtView:)`, `beginPan(atView:)`, `continuePan(toView:)`, `endPan()`, magnify/scroll/Space handling forwarded from `CanvasView`, pointer tracking for the status bar), `UI/StatusBarView.swift` / `UI/StatusBarModel.swift` (`statusBar.zoom`, `statusBar.cursor`), the View menu zoom items. 0004 says: "0006 will put `CanvasInputRouter` between `CanvasView` and the tools; it must keep calling `CanvasNavigation` first for magnify, scroll, and Space-pan, and its `PanTool` reuses `beginPan(atView:)` / `continuePan(toView:)` / `endPan()`."
- **0005** — `UI/NewImageDialog.swift` (identifiers `newImageDialog`, `newImage.width`, `newImage.cancel`; the width field has focus when it opens).

`Core/` = `PaintDotMac/Core/` throughout.

What is missing: there are no tools, no Tools panel, no tool options bar, no tool shortcuts, and no way for later specs (Paintbrush 0009, selection tools 0014+, Move 0019/0020, Line/Curve and Shapes 0038/0039, Text 0040, Color Picker 0012) to plug in. Mouse drags on the canvas do nothing unless Space is held.

### Paint.NET behavior mirrored

- **Tools Window** (ToolsWindow.html): "Clicking a tool icon makes it active"; the active icon is highlighted; "Hovering the mouse pointer over a tool icon shows a tool tip with the keyboard shortcut"; tools are grouped under Selection, Move, View, Fill, Drawing, Photo, and Text and Shape. Its tool order is: Rectangle Select, Lasso Select, Ellipse Select, Magic Wand, Move Selected Pixels, Move Selection, Zoom, Pan, Paint Bucket, Gradient, Paintbrush, Eraser, Pencil, Color Picker, Clone Stamp, Recolor, Text, Line/Curve, Shapes. F5 toggles it (⌥⌘1 here, §5.12).
- **Keys** (KeyboardMouseCommands.html): Rectangle Select "S, or Shift+S ×4"; Lasso "S ×2, or Shift+S ×3"; Ellipse "S ×3, or Shift+S ×2"; Magic Wand "S ×4, or Shift+S"; Move Selected Pixels "M"; Move Selection "M ×2, or Shift+M"; Line/Curve "O"; Shapes "O ×2, or Shift+O"; Zoom Z, Pan H, Paint Bucket F, Gradient G, Paintbrush B, Eraser E, Pencil P, Color Picker K, Clone Stamp L, Recolor R, Text T. "Pressing the shortcut repeatedly will cycle through each of the tools in turn"; presses "should be less than a second apart". So repeated presses cycle forward, Shift+key cycles backward, and a press more than a second after the previous one starts from the group's first (or, with Shift, last) tool.
- **Zoom tool** (ViewTools.html, KeyboardMouseCommands.html): "Use the Left Mouse button to zoom in on the canvas. The Right Mouse button zooms out." "When the Zoom Tool is active, clicking and dragging a rectangle will maximize the specified area in the Editing Window." PRD T-7 maps the zoom-out click to **Option-click** (and right-click keeps working, as in Paint.NET).
- **Pan tool** (ViewTools.html, KeyboardMouseCommands.html): "Click and drag the canvas to move it around within the Editing Window"; "Pan Tool: click and drag with the Left or Right Mouse Button"; "Pan canvas: click and drag with the Middle Mouse Button" (with any tool). Space-to-pan is 0004's.
- **Tool Bar** (Toolbar.html): a row of "settings for the active tool" whose options change with the selected tool; a "Tool choice" drop-down "useful if the Tools Window is closed or hidden"; a **Finish** button that "commits a shape, text, or operation to the canvas, ending live editing", shortcut Enter. Paint.NET's common-actions row (New, Open, Save, Cut, …) and pixel-grid/ruler toggles are not part of APP-4 (menus cover them; grid/rulers are 0053).

## User story

As a PaintDotMac user, I see a floating Tools panel and History, Layers, and Colors panels that I can show or hide from the Window menu (⌥⌘1–4) and that come back where I left them. I pick a tool by clicking it or pressing its letter (pressing S, M, or O again cycles through that key's group), but typing in a text field never switches tools. The tool options bar at the top of the document window shows the active tool and its settings, and settings persist between launches. With the Zoom tool I click to zoom in, Option-click (or right-click) to zoom out, or drag a rectangle to zoom to it; with the Pan tool I drag to move around the image.

## Scope & changes

### Core (pure Swift, no AppKit/SwiftUI; unit-tested)

All types are in `PaintDotMac/Core/Tools/`. The protocol types are `@MainActor` because tools mutate main-actor document state (AGENTS.md rule 7); value types are `Sendable`.

- **`Core/Tools/ToolEvent.swift`** (new):
  ```swift
  enum ToolID: String, CaseIterable, Sendable {
      // Declaration order == Paint.NET Tools window order (used by the panel and by key groups).
      case rectangleSelect, lassoSelect, ellipseSelect, magicWand,
           moveSelectedPixels, moveSelection, zoom, pan, paintBucket, gradient,
           paintbrush, eraser, pencil, colorPicker, cloneStamp, recolor,
           text, lineCurve, shapes
  }
  enum ToolMouseButton: Sendable, Equatable { case primary, secondary }
  struct ToolModifiers: OptionSet, Sendable, Hashable { let rawValue: UInt8
      static let shift, option, control, command }
  struct ToolEvent: Sendable, Equatable {
      var location: CGPoint        // canvas space (0003): image pixels, Double, top-left origin, y down
      var viewLocation: CGPoint    // CanvasView view space (0003): AppKit points, bottom-left origin, y up; for screen-space thresholds
      var button: ToolMouseButton
      var modifiers: ToolModifiers
      var clickCount: Int          // NSEvent.clickCount on mouseDown; 0 for dragged/moved
      var pressure: Double         // reserved for TOOL-D (0055); always 1.0 until then
      var timestamp: TimeInterval  // NSEvent.timestamp
  }
  enum ToolKey: Sendable, Equatable {
      case character(Character)    // lowercased charactersIgnoringModifiers, one Character
      case returnKey, enter, escape, delete, forwardDelete, tab, space,
           leftArrow, rightArrow, upArrow, downArrow
      case other(keyCode: UInt16)
      init(keyCode: UInt16, charactersIgnoringModifiers: String)
  }
  struct ToolKeyEvent: Sendable, Equatable {
      var key: ToolKey; var characters: String; var modifiers: ToolModifiers; var isRepeat: Bool
  }
  ```
  - `ToolKey.init`: key codes Return 36 → `.returnKey`, keypad Enter 76 → `.enter`, Escape 53, Delete (⌫) 51, Forward Delete 117, Tab 48, Space 49, Left 123, Right 124, Down 125, Up 126; otherwise, if `charactersIgnoringModifiers` is exactly one `Character`, `.character(lowercased)`, else `.other(keyCode:)`.
  - **Button mapping rule (TOOL-A, documented here, applied by `ToolDispatcher`):** left button → `.primary`; right button → `.secondary`; **left button with Control → `.secondary` and `.control` stays in `modifiers`** (so 0009's "secondary, or primary + Control" check and 0012's "Control-click arrives as secondary" both hold). The middle button never reaches tools (it pans, see the router).

- **`Core/Tools/ToolContext.swift`** (new) — what a tool may touch. The canvas session of the main document window implements it (`Canvas/CanvasToolSession.swift`); tests use `FakeToolContext`.
  ```swift
  @MainActor protocol ToolContext: AnyObject {
      var image: LayeredImage { get }            // the document's image (read; pixel writes come with 0008 history)
      var transform: CanvasTransform { get }     // current view ↔ canvas mapping
      var navigation: any CanvasNavigating { get }
      var options: any ToolOptionStore { get }   // tool.<id>.<option> (TOOL-C)
      var previousToolID: ToolID? { get }        // the tool that was active before the current one
      func activateTool(_ id: ToolID)            // deferred until the current event handler returns (see dispatcher)
      func setOverlay(_ overlay: ToolOverlay?)   // transient vector feedback drawn above the canvas
      func invalidateCursor()                    // re-query the effective tool's cursor now
  }
  @MainActor protocol CanvasNavigating: AnyObject {
      var transform: CanvasTransform { get }
      func setZoom(_ zoom: Double, anchoredAtView viewPoint: CGPoint)   // 0004 semantics: clamps, keeps the canvas point under viewPoint
      func beginPan(atView viewPoint: CGPoint)
      func continuePan(toView viewPoint: CGPoint)                        // content follows the pointer, clamped (0004)
      func endPan()
  }
  enum ToolOverlay: Sendable, Equatable {
      case zoomRectangle(CGRect)                 // canvas space, standardized
      // Later specs add cases (lasso path, shape handles, …) and draw them in Canvas/ToolOverlayView.swift.
  }
  enum ToolCursor: Sendable, Equatable { case arrow, crosshair, zoomIn, zoomOut, openHand, closedHand, iBeam }
  ```
  - **Reserved extensions (owned by later specs; listed so names don't collide):** 0007 adds `var colors: ColorSelection { get }`; 0008 adds `func commitHistory(_ item: any HistoryItem)`, `func performHistory(_ item: any HistoryItem)`, and `func updateImage(_ body: (inout LayeredImage) -> Void)` (live pixel writes; the app side forwards to `UndoBridge.updateLiveState`); 0009 adds `var paintClipMask: (any BrushClipMask)? { get }` and the `ToolOverlay.brushOutline(CGRect)` case; 0012 adds `func setColor(_ color: ColorRGBA8, for slot: ColorSlot)`; 0013 adds the selection. Each spec that adds a requirement implements it in `CanvasToolSession` and `FakeToolContext`. `activateTool(_:)` and `previousToolID` are defined here, so 0012 doesn't add them.

- **`Core/Tools/Tool.swift`** (new):
  ```swift
  @MainActor protocol Tool: AnyObject {
      var id: ToolID { get }
      var capturesKeyboard: Bool { get }   // true while the tool owns typing (Text tool editing). Default false.
      var hasPendingEdit: Bool { get }     // uncommitted editable state (shape, text, floating pixels, in-progress stroke). Default false.
      func activate(context: any ToolContext)                       // default: no-op
      func deactivate(context: any ToolContext)                     // default: if hasPendingEdit { commit(context:) }
      func mouseDown(_ event: ToolEvent, context: any ToolContext)
      func mouseDragged(_ event: ToolEvent, context: any ToolContext)
      func mouseUp(_ event: ToolEvent, context: any ToolContext)
      func mouseMoved(_ event: ToolEvent, context: any ToolContext) // default: no-op (hover feedback)
      func flagsChanged(_ modifiers: ToolModifiers, context: any ToolContext) // default: context.invalidateCursor()
      func keyDown(_ event: ToolKeyEvent, context: any ToolContext) -> Bool
          // default: .returnKey/.enter with hasPendingEdit → commit, true; .escape with hasPendingEdit → cancel, true; else false
      func insertText(_ text: String, context: any ToolContext)     // default: no-op (Text tool, 0040)
      func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor // default .arrow; location nil = pointer outside canvas
      func commit(context: any ToolContext)                         // default: no-op. Finish button, Return, tool switch, document switch; later also undo and save (0008/0009 call it)
      func cancel(context: any ToolContext)                         // default: no-op. Escape; must leave the tool idle with no partial edit
      func optionsDidChange(context: any ToolContext)               // default: no-op (live-edited shapes/text restyle)
  }
  extension Tool {
      var descriptor: ToolDescriptor { ToolRegistry.descriptor(for: id) }
      var displayName: String { descriptor.displayName }
      var shortcutKey: Character { descriptor.shortcutKey }
  }
  ```
  Tools are `final class`es (they hold gesture state). One instance per tool ID for the app's lifetime, created lazily by the registry factory. Tools never import AppKit and never read `NSEvent`.

- **`Core/Tools/ToolRegistry.swift`** (new):
  - `enum ToolPanelGroup: String, CaseIterable, Sendable { case selection, move, view, fill, drawing, photo, textAndShape }` (Tools window sections, in that order).
  - `struct ToolDescriptor: Sendable, Equatable { let id: ToolID; let displayName: String; let shortcutKey: Character; let group: ToolPanelGroup; let symbolName: String; let supportsPendingEdits: Bool; var helpText: String { "\(displayName) (\(shortcutKey.uppercased()))" } }`.
  - `static let allDescriptors: [ToolDescriptor]` — exactly this table, in this order (== `ToolID.allCases`):

    | id | displayName | key | group | symbolName (SF Symbol) | supportsPendingEdits |
    |---|---|---|---|---|---|
    | rectangleSelect | Rectangle Select | s | selection | `rectangle.dashed` | false |
    | lassoSelect | Lasso Select | s | selection | `lasso` | false |
    | ellipseSelect | Ellipse Select | s | selection | `circle.dashed` | false |
    | magicWand | Magic Wand | s | selection | `wand.and.stars` | false |
    | moveSelectedPixels | Move Selected Pixels | m | move | `arrow.up.and.down.and.arrow.left.and.right` | true |
    | moveSelection | Move Selection | m | move | `selection.pin.in.out` | false |
    | zoom | Zoom | z | view | `magnifyingglass` | false |
    | pan | Pan | h | view | `hand.raised` | false |
    | paintBucket | Paint Bucket | f | fill | `drop.fill` | false |
    | gradient | Gradient | g | fill | `circle.lefthalf.filled` | false |
    | paintbrush | Paintbrush | b | drawing | `paintbrush.pointed` | false |
    | eraser | Eraser | e | drawing | `eraser` | false |
    | pencil | Pencil | p | drawing | `pencil` | false |
    | colorPicker | Color Picker | k | drawing | `eyedropper` | false |
    | cloneStamp | Clone Stamp | l | photo | `seal` | false |
    | recolor | Recolor | r | photo | `paintpalette` | false |
    | text | Text | t | textAndShape | `textformat` | true |
    | lineCurve | Line / Curve | o | textAndShape | `line.diagonal` | true |
    | shapes | Shapes | o | textAndShape | `square.on.circle` | true |

    (Group membership of Color Picker/Clone Stamp/Recolor is inferred from the documented order and headings. "Line / Curve" follows the PRD's spelling. A symbol name that turns out not to exist on macOS 15 may be replaced with a similar one; `ToolSymbolTests` catches it.)
  - `static func descriptor(for id: ToolID) -> ToolDescriptor`.
  - `@MainActor struct ToolRegistry { init(factories: [ToolID: @MainActor () -> any Tool]); static func standard() -> ToolRegistry }`. `standard()` registers the implemented tools. **In this spec: `.zoom` → `ZoomTool()`, `.pan` → `PanTool()`.** Each later tool spec adds one line here.
  - `var implementedIDs: [ToolID]` (in `ToolID.allCases` order); `func isImplemented(_:) -> Bool`; `func makeTool(_ id: ToolID) -> (any Tool)?`.
  - `func shortcutGroup(for key: Character) -> [ToolID]` — the **implemented** tools whose `shortcutKey == key`, in `ToolID.allCases` order. This is D-13's cycle order (S: rectangleSelect, lassoSelect, ellipseSelect, magicWand; M: moveSelectedPixels, moveSelection; O: lineCurve, shapes).
  - `static let allShortcutKeys: Set<Character>` = `{s, m, z, h, f, g, b, e, p, k, l, r, t, o}` (from all descriptors, implemented or not).
  - `var defaultToolID: ToolID` — the first implemented tool in `[.paintbrush, .pan]`, else the first implemented ID. (In this spec: `.pan`; once 0009 registers the Paintbrush, it becomes `.paintbrush` with no further change; 0009 tests that.) **Decision (PRD §5.3, D-35):** the app starts with the Paintbrush (the Pan tool until 0009 lands), and the active tool is not persisted across launches: no `UserDefaults` key stores it.
  - **`struct ToolShortcutGate`** (same file): `static func allows(modifiers: ToolModifiers, keyWindow: ToolKeyWindowKind, textInputHasFocus: Bool, toolCapturesKeyboard: Bool, gestureInProgress: Bool) -> Bool` with `enum ToolKeyWindowKind: Sendable { case document, panel, other }`. Returns `true` only when none of `.command/.option/.control` is held (Shift is allowed), `keyWindow != .other`, and the three flags are `false`. This one gate guards every single-key shortcut (tool letters here; X/D in 0007; `[`/`]` in 0009).
  - **`struct ToolShortcutResolver: Sendable`** (same file): `static let cycleInterval: TimeInterval = 1.0`; private `lastPress: (key: Character, time: TimeInterval)?`. **Decision (PRD §5.3, D-35, matching Paint.NET's "less than a second apart"):** a press less than 1 s after the previous press of the same key cycles forward, Shift+key cycles backward; any other press selects the group's first tool, or with Shift its last tool (Paint.NET: Magic Wand is "Shift+S"), which is the first step of a backward cycle.
    - `static func toolKey(fromCharactersIgnoringModifiers s: String) -> Character?` — `s` lowercased, exactly one `Character`, member of `allShortcutKeys`; else `nil`. (Caps Lock or Shift producing "S" still yields `s`; Shift is read from the modifiers, not the case.)
    - `mutating func resolve(key: Character, shift: Bool, group: [ToolID], activeTool: ToolID, timestamp: TimeInterval) -> ToolID?`:
      1. `let cycling = lastPress?.key == key && timestamp - lastPress!.time < cycleInterval && group.contains(activeTool)`; then record `lastPress = (key, timestamp)`.
      2. `group.isEmpty` → `nil`.
      3. If `cycling`: index of `activeTool` in `group`, `+1` (or `−1` with Shift), wrapping.
      4. Else: `shift ? group.last : group.first`.
    - Auto-repeat presses are not passed to `resolve` (the dispatcher drops them before), so holding S never spins through the group.

- **`Core/Tools/ToolOptionStore.swift`** (new) — TOOL-C, AGENTS.md rule 6:
  ```swift
  protocol ToolOptionValue: Sendable, Equatable { init?(storedValue: Any); var storedValue: Any { get } }
  // Conformances: Bool, Int, Double, String. Enums opt in with `extension X: ToolOptionValue {}` through a default
  // implementation for `RawRepresentable where RawValue == String` (stored as the raw string).
  struct ToolOptionKey<Value: ToolOptionValue>: Sendable, Hashable {
      let tool: ToolID; let name: String; let defaultValue: Value
      init(tool: ToolID, name: String, defaultValue: Value, sanitize: @escaping @Sendable (Value) -> Value = { $0 })
      var defaultsKey: String { "tool.\(tool.rawValue).\(name)" }    // e.g. "tool.paintbrush.width"
      func sanitize(_ value: Value) -> Value
      // == and hash use (tool, name) only.
  }
  extension ToolOptionKey where Value: Comparable { init(tool:name:defaultValue:range: ClosedRange<Value>) } // sanitize clamps
  @MainActor protocol ToolOptionStore: AnyObject {
      func storedValue(forKey key: String) -> Any?
      func setStoredValue(_ value: Any?, forKey key: String)          // nil removes
  }
  extension ToolOptionStore {
      func value<V>(_ key: ToolOptionKey<V>) -> V                     // missing or wrong type → defaultValue; then sanitize
      func setValue<V>(_ value: V, for key: ToolOptionKey<V>)         // stores sanitize(value)
      func removeValue<V>(for key: ToolOptionKey<V>)
  }
  @MainActor final class InMemoryToolOptionStore: ToolOptionStore { /* [String: Any]; tests and previews */ }
  ```
  - `name` must be non-empty and contain no `.` (`precondition` in `init`; a programming error, not user input). A non-finite `Double` read from storage is treated as missing.
  - Integer bridging: `Int(storedValue:)` accepts an `NSNumber`/`Int` that is exactly integral; `Double` accepts any finite number; `Bool` accepts a stored `Bool` (or `NSNumber` 0/1); `String` only a `String`.

- **`Core/Tools/ToolDispatcher.swift`** (new) — `@MainActor final class ToolDispatcher`, the single place that owns tool instances, the active/previous tool, gestures, and shortcut resolution. App-wide (one instance in `AppModel`); the context switches to the main document window's session.
  ```swift
  enum ToolPhysicalButton: Sendable { case left, right }       // the router handles the middle button itself
  struct ToolPointerInput: Sendable, Equatable {
      var physicalButton: ToolPhysicalButton; var location: CGPoint; var viewLocation: CGPoint
      var modifiers: ToolModifiers; var clickCount: Int; var pressure: Double; var timestamp: TimeInterval
  }
  @MainActor final class ToolDispatcher {
      init(registry: ToolRegistry)
      private(set) var activeToolID: ToolID           // starts at registry.defaultToolID
      private(set) var previousToolID: ToolID?
      var activeTool: any Tool                         // lazily created instance
      private(set) var context: (any ToolContext)?
      var isGestureInProgress: Bool { get }
      var hasPendingEdit: Bool { get }                 // activeTool.hasPendingEdit
      var onStateChange: (@MainActor () -> Void)?      // after active/previous/pending changes
      func setContext(_ context: (any ToolContext)?)
      @discardableResult func selectTool(_ id: ToolID) -> Bool
      func requestToolSwitch(_ id: ToolID)             // what CanvasToolSession.activateTool calls
      func pointerDown(_ input: ToolPointerInput)
      func pointerDragged(_ input: ToolPointerInput)
      func pointerUp(_ input: ToolPointerInput)
      func pointerMoved(location: CGPoint, viewLocation: CGPoint, modifiers: ToolModifiers, timestamp: TimeInterval)
      func flagsChanged(_ modifiers: ToolModifiers)
      func keyDown(_ event: ToolKeyEvent) -> Bool
      func insertText(_ text: String)
      func handleShortcut(charactersIgnoringModifiers: String, modifiers: ToolModifiers, isRepeat: Bool,
                          timestamp: TimeInterval, keyWindow: ToolKeyWindowKind, textInputHasFocus: Bool) -> Bool
      func commitPendingEdit()                         // Finish button; later 0008 undo / save call it
      func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor
      func optionsDidChange()
  }
  ```
  Rules:
  - **Selection.** `selectTool(id)`: not implemented → `false`, no change. `id == activeToolID` → `true`, no calls. During a gesture → remembered and applied when the gesture ends (last request wins), returns `true`. Otherwise: `old.deactivate(context:)` (if a context exists; the default commits a pending edit), `previousToolID = old id`, `activeToolID = id`, `new.activate(context:)` (if a context exists), then `onStateChange`.
  - **Tool-requested switches.** `requestToolSwitch(id)` while a tool handler is running is queued and applied right after that handler returns (after the gesture ends if it was called from `mouseDown`/`mouseDragged`), so a tool is never deactivated from inside its own handler. Outside a handler it acts like `selectTool`.
  - **Context.** `setContext(new)` when `new !== context`: if a gesture is in progress, `activeTool.cancel(context: old)` and the gesture is dropped; `activeTool.deactivate(context: old)` (commits pending state into the old document); store `new`; `activeTool.activate(context: new)` if non-nil. Without a context, pointer and key events are ignored (selection and shortcuts still work).
  - **Gestures.** `pointerDown` starts a gesture only when none is in progress (a second button pressed mid-gesture is ignored, as is its up). It maps the button (rule above) and calls `mouseDown`. `pointerDragged`/`pointerUp` are delivered only for the gesture's physical button, with the gesture's mapped `button`; drags or ups without a gesture are ignored. `clickCount` is 0 on dragged events. After `pointerUp` the gesture ends and queued switches apply.
  - **Escape during a gesture.** `keyDown(.escape)` while a gesture is in progress calls `activeTool.cancel(context:)`, marks the gesture cancelled (later drags are swallowed; the matching up only ends the gesture), returns `true`. Otherwise `keyDown` forwards to `activeTool.keyDown` and returns its result (no context → `false`).
  - **Shortcuts.** `handleShortcut(...)`: if `ToolShortcutGate.allows(...)` is false (using `activeTool.capturesKeyboard` and `isGestureInProgress`) → `false`. `toolKey(fromCharactersIgnoringModifiers:)` is `nil` → `false`. Else the key is consumed (`true`): auto-repeat → nothing; otherwise `resolve(key:shift:group:activeTool:timestamp:)` and `selectTool` the result if non-nil (an unimplemented key, e.g. L, is silently consumed — no beep, no switch).
  - **Pending-edit mirroring.** After every forwarded event, compare `hasPendingEdit`/`activeToolID` with the last values and call `onStateChange` on change.
  - `cursor(at:modifiers:)` → `activeTool.cursor(at:modifiers:)`. `optionsDidChange()` → `activeTool.optionsDidChange(context:)` when a context exists.

- **`Core/Tools/ZoomTool.swift`** (new) — T-7. `final class ZoomTool: Tool`, `id = .zoom`, no options.
  - `static let dragThreshold: Double = 3` (view points).
  - State: idle, or pressed `(downViewLocation, downCanvasLocation, button, modifiers)` with `isRectangle`.
  - `mouseDown`: record. `mouseDragged`: once `max(|dx|, |dy|) ≥ dragThreshold` in **view** space (from `downViewLocation`), switch to rectangle mode for the rest of the gesture; in rectangle mode `context.setOverlay(.zoomRectangle(rect))` with `rect` = the standardized canvas rect spanning `downCanvasLocation` and the current `location`.
  - All view-space values here are 0003's view space (bottom-left origin, y up). The rectangle math never flips Y itself: it only goes through `canvasToView`, and `viewCenter` is the same in either orientation.
  - `mouseUp`, rectangle mode: `setOverlay(nil)`; `let target = ZoomTool.rectangleZoom(for: rect, transform: context.navigation.transform)`; `navigation.setZoom(target, anchoredAtView: transform.canvasToView(rect.mid))`; then center the rect: `beginPan(atView: p)`, `continuePan(toView: viewCenter)`, `endPan()` where `p = navigation.transform.canvasToView(rect.mid)` after the zoom and `viewCenter = (viewSize.width / 2, viewSize.height / 2)`. Button and modifiers don't matter in rectangle mode. (0004's clamping may stop the rect short of the exact center near image edges; that's expected.)
  - `mouseUp`, click: `zoomOut = button == .secondary || modifiers.contains(.option)`; `next = zoomOut ? ZoomLevels.nextSmaller(than: z) : ZoomLevels.nextLarger(than: z)` with `z = navigation.transform.zoom`; if `next` is non-nil, `setZoom(next, anchoredAtView: downViewLocation)` (the clicked point stays under the pointer); if `nil` (at 3200 % / 1 %), nothing.
  - `static func rectangleZoom(for rect: CGRect, transform: CanvasTransform) -> Double`: `let minSide = 1 / transform.zoom` (one device pixel in canvas units); `content = (max(rect.width, minSide), max(rect.height, minSide))`; return `ZoomLevels.fitZoom(contentSize: content, viewportSize: transform.viewSize × transform.backingScale, allowsEnlargement: true)` (which clamps to 1 %–3200 %). Not snapped to a preset (Paint.NET "maximizes the specified area").
  - `cancel`: `setOverlay(nil)`, back to idle. `deactivate`: same as cancel (nothing to commit).
  - `cursor`: `.zoomOut` when `modifiers` contains `.option`, else `.zoomIn`.
  - Never touches pixels, history, or the document's edited state.

- **`Core/Tools/PanTool.swift`** (new) — T-8. `final class PanTool: Tool`, `id = .pan`, no options.
  - `mouseDown`: `navigation.beginPan(atView: event.viewLocation)`, dragging = true, `invalidateCursor()`. `mouseDragged`: `continuePan(toView: event.viewLocation)`. `mouseUp`: `continuePan(toView:)` then `endPan()`, dragging = false, `invalidateCursor()`. Both buttons pan (Paint.NET). Uses `viewLocation` only (the canvas location under the pointer stays the same while panning).
  - `cancel`: `endPan()` if dragging (the view stays where it is; panning has no undo), dragging = false.
  - `cursor`: `.closedHand` while dragging, else `.openHand`.
  - Never touches pixels, history, or the edited state.

### Platform glue (AppKit/SwiftUI; UI tests and manual checks)

- **`App/AppModel.swift`** (new) — `@MainActor @Observable final class AppModel`:
  - `static let shared = AppModel()` (created on first use by `AppDelegate`); `init(defaults: UserDefaults = .standard, registry: ToolRegistry = .standard())` for tests. Later specs add init parameters with defaults (0007 adds its color store).
  - `@ObservationIgnored let dispatcher: ToolDispatcher`; observable mirrors `private(set) var activeToolID: ToolID`, `previousToolID: ToolID?`, `hasPendingToolEdit: Bool`, updated from `dispatcher.onStateChange`.
  - `let toolOptions: UserDefaultsToolOptionStore` (below), whose change callback calls `dispatcher.optionsDidChange()`.
  - `func selectTool(_ id: ToolID)` → `dispatcher.selectTool`. `var implementedTools: [ToolDescriptor]`.
  - Active document: `@ObservationIgnored private(set) weak var activeSession: CanvasToolSession?` plus an observable `activeSessionGeneration: Int` bumped on change; `func setActiveSession(_ s: CanvasToolSession?)` calls `dispatcher.setContext(s)`. Panels that show document state (0010, 0025) observe the generation.
  - Panel visibility: `func isPanelVisible(_ kind: PanelKind) -> Bool` (stored observable dictionary, persisted as `panel.<kind>.visible`, default `true` when missing or not a `Bool`), `func setPanelVisible(_:_:)`, `func togglePanel(_:)`.
- **`App/UserDefaultsToolOptionStore.swift`** (new) — `@MainActor @Observable final class UserDefaultsToolOptionStore: ToolOptionStore`: `init(defaults: UserDefaults, onChange: @escaping @MainActor (String) -> Void = { _ in })`; `storedValue(forKey:)` reads `revision` (an observable `Int`) before returning `defaults.object(forKey:)`, so SwiftUI views that read options re-render on any change; `setStoredValue` writes (or removes) and increments `revision`, then calls `onChange(key)`. Tools write options through `context.options`, so `[`/`]` (0009) updates the bar immediately.
- **`App/PanelController.swift`** (new):
  - `enum PanelKind: String, CaseIterable { case tools, history, layers, colors }` with `title` ("Tools", "History", "Layers", "Colors"), `menuKeyEquivalent` ("1"…"4", modifiers ⌥⌘), `frameAutosaveName` (`"panel.tools"`, …), `visibilityDefaultsKey` (`"panel.tools.visible"`, …), `accessibilityIdentifier` (`toolsPanel`, `historyPanel`, `layersPanel`, `colorsPanel`), `menuItemIdentifier` (`menu.window.panel.tools`, …), and the pure `static func defaultFrame(for kind:, size: CGSize, visibleFrame: CGRect) -> CGRect` (Paint.NET's default layout, margin 16 pt): Tools top-left (`x = vf.minX + 16`, `y = vf.maxY − 16 − h`), History top-right (`x = vf.maxX − 16 − w`, `y = vf.maxY − 16 − h`), Layers bottom-right (`x = vf.maxX − 16 − w`, `y = vf.minY + 16`), Colors bottom-left (`x = vf.minX + 16`, `y = vf.minY + 16`).
  - `@MainActor final class PanelController: NSObject, NSWindowDelegate`, owned by `AppDelegate`, holding one `NSPanel` per kind, built at launch:
    - Style `[.titled, .closable, .utilityWindow]` (+ `.resizable` for History, Layers, Colors), `isFloatingPanel = true`, `hidesOnDeactivate = true`, `becomesKeyOnlyIfNeeded = true` (clicking a tool button doesn't take key status from the document window, so tool keys keep working), `collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]`, `isReleasedWhenClosed = false`, `title = kind.title`, window `identifier = NSUserInterfaceItemIdentifier("panel.<kind>")`.
    - Content: `NSHostingView` of `makeContent(for:)` — `.tools` → `ToolsPanelView(model:)`; `.history`, `.layers`, `.colors` → `PanelPlaceholderView(kind:)` (a centered secondary-colored "Not available yet." text, 200×200 pt, root accessibility identifier = `kind.accessibilityIdentifier`; PRD APP-2, D-36). **0007, 0010, 0025 replace their case** with real content; the menu items, shortcuts, and persistence below already work for all four.
    - Frame: `if !panel.setFrameUsingName(kind.frameAutosaveName) { panel.setFrame(defaultFrame(…, visibleFrame: NSScreen.main?.visibleFrame), display: false) }`, then `panel.setFrameAutosaveName(kind.frameAutosaveName)` (AppKit stores `NSWindow Frame panel.<kind>`, which `-UITestResetDefaults` clears). Tools panel size = its content's fitting size, not resizable.
    - **Showing rule:** a panel is on screen iff `appModel.isPanelVisible(kind)` and at least one document window (identifier `documentWindow`) is open. `func refresh()` applies it with `orderFront(nil)` (never `makeKey`) / `orderOut(nil)`; called at launch, after a document window is shown, and after a document window closes (deferred to the next main-actor turn so the closing window is gone).
    - The panel's close button: `windowShouldClose` → `setPanelVisible(kind, false)`, `orderOut`, return `false` (so app quit, which closes windows without this callback, never persists "hidden").
    - `@objc func togglePanel(_ sender: NSMenuItem)` (implemented on `AppDelegate`, forwarding; the item's `representedObject` is the `PanelKind.rawValue`) → `appModel.togglePanel(kind)`, `refresh()`. Menu validation: `state = isPanelVisible ? .on : .off`; enabled iff a document window is open.
- **`App/MainMenu.swift`** (modify): Window menu becomes Minimize ⌘M, Zoom, —, **Tools ⌥⌘1, History ⌥⌘2, Layers ⌥⌘3, Colors ⌥⌘4**, —, Bring All to Front. Action `togglePanel(_:)`, target `nil`, identifiers `menu.window.panel.<kind>`. Update 0001's `MainMenuTests` expectation for the Window menu.
- **`App/AppDelegate.swift`** (modify): create `AppModel.shared` and `PanelController` after the `-UITestResetDefaults` handling; install one local key monitor: `NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in MainActor.assumeIsolated { CanvasInputRouter.handleShortcutKeyDown(event, model: .shared) } ? nil : event }`; implement `togglePanel(_:)` and its `validateMenuItem`.
- **`Canvas/CanvasInputRouter.swift`** (new):
  - `static func handleShortcutKeyDown(_ event: NSEvent, model: AppModel) -> Bool` — the one entry point for single-key shortcuts (0007 adds X/D and 0009 adds `[`/`]` here, after the tool lookup returns `false`). It computes `keyWindow` (`NSApp.keyWindow?.identifier == documentWindow` → `.document`; one of `PanelController`'s panels → `.panel`; else `.other`, which includes sheets, alerts, dialogs, Settings), `textInputHasFocus` (`keyWindow.firstResponder` is an `NSText` — the field editor of any `NSTextField`/SwiftUI `TextField` — or conforms to `NSTextInputClient` and isn't the `CanvasView`), maps `modifierFlags` to `ToolModifiers`, and calls `model.dispatcher.handleShortcut(...)` with `event.charactersIgnoringModifiers`, `event.isARepeat`, `event.timestamp`.
  - `@MainActor final class CanvasInputRouter`, one per document window, owned by `DocumentWindowController`, referencing the `CanvasView`, 0004's `CanvasNavigation`, the window's `CanvasToolSession`, and `AppModel`. `CanvasView`'s event overrides forward to it (replacing 0004's direct forwarding, keeping 0004's order):
    - `magnify`, `scrollWheel` → `CanvasNavigation` unchanged.
    - `keyDown`/`keyUp` for Space → `CanvasNavigation` (0004's `SpacePanState`), **unless** `activeTool.capturesKeyboard` (then Space is typing).
    - `mouseDown`: first `makeFirstResponder(canvasView)`; if this session isn't the dispatcher's context, `model.setActiveSession(session)`; if 0004's Space-pan claims the click (`SpacePanState.mouseDown() == true`), the drag pans exactly as in 0004; otherwise `dispatcher.pointerDown` with `.left`. `mouseDragged`/`mouseUp` go to whichever claimed the down. `rightMouseDown/Dragged/Up` → dispatcher with `.right`. `CanvasView.menu(for:)` returns `nil` so Control-click never shows a context menu.
    - `otherMouseDown/Dragged/Up` with `buttonNumber == 2` (middle button): pans through `CanvasNavigation.beginPan/continuePan/endPan` with the closed-hand cursor, unless a dispatcher gesture is in progress (then ignored). Other buttons are ignored.
    - `mouseMoved` → `dispatcher.pointerMoved` and cursor update (0004's status-bar tracking stays). `flagsChanged` → `dispatcher.flagsChanged` and cursor update.
    - `keyDown` (non-Space, canvas is first responder): `dispatcher.keyDown(ToolKeyEvent)`; if unhandled and `activeTool.capturesKeyboard`, `canvasView.interpretKeyEvents([event])`, with `CanvasView.insertText(_:)` forwarding to `dispatcher.insertText`; otherwise `super.keyDown` (passes up the responder chain).
    - All conversions use `CanvasTransform.viewToCanvas` on `convert(event.locationInWindow, from: nil)` (never inline Y flips; CAN-6). Non-finite results drop the event.
    - **Cursor:** 0004's `SpacePanState.cursor` wins when it isn't `.none`; then the middle-button pan's closed hand; else `dispatcher.cursor(at: canvasPoint or nil, modifiers:)`, applied on `cursorUpdate`, `mouseMoved`, `flagsChanged`, after each pointer event, and when the active tool changes while the pointer is over the canvas. Mapping in `Canvas/ToolCursor+AppKit.swift`: arrow/crosshair/openHand/closedHand/iBeam → the `NSCursor` of that name; `zoomIn`/`zoomOut` → `NSCursor.zoomIn`/`NSCursor.zoomOut` (macOS 15).
- **`Canvas/CanvasToolSession.swift`** (new) — `@MainActor final class CanvasToolSession: ToolContext`, one per document window: `image` from the document, `transform`/`navigation` from 0004's `CanvasNavigation` (which conforms to `CanvasNavigating` in `Canvas/CanvasNavigation+CanvasNavigating.swift`; 0004 exposes `setZoom(_:anchoredAtView:)`, `beginPan(atView:)`, `continuePan(toView:)`, `endPan()`, and this file adds `var transform: CanvasTransform` returning the transform 0004 last assigned to `CanvasView.transform`), `options` = `AppModel.toolOptions`, `previousToolID` = `model.previousToolID`, `activateTool` → `model.dispatcher.requestToolSwitch`, `setOverlay` → `ToolOverlayView`, `invalidateCursor` → router. `DocumentWindowController` calls `AppModel.shared.setActiveSession(session)` on `windowDidBecomeMain` and `setActiveSession(nil)` on close when it is the active one.
- **`Canvas/ToolOverlayView.swift`** (new): transparent `NSView` above `CanvasView` (same frame, `isFlipped == false` like `CanvasView`, so 0003's view-space rects draw without conversion), `hitTest(_:) → nil`, draws `.zoomRectangle(r)` as `transform.canvasRectToView(r)` inset by 0.5 pt: a 1 pt white line under a 1 pt black line dashed `[4, 4]` (static, not animated). Redraws when the overlay changes and after every transform change (hook it where 0004 assigns a new transform to `CanvasView`).
- **`UI/ToolsPanelView.swift`** (new) — SwiftUI, bound to `AppModel`: a vertical stack of the `ToolPanelGroup`s that have at least one implemented tool, in order, separated by `Divider`s; each a two-column grid of 28×28 pt buttons with the descriptor's SF Symbol (16 pt). The active tool's button has an accent-color rounded background and white symbol. **Only implemented tools appear** (this spec: Zoom and Pan, in the View section). Per button: `.help(descriptor.helpText)` ("Zoom (Z)"), `.accessibilityLabel(displayName)`, `.accessibilityIdentifier("tool.\(id.rawValue)")`, `.accessibilityAddTraits(.isSelected)` when active; action `model.selectTool(id)`. Root: `.accessibilityElement(children: .contain).accessibilityIdentifier("toolsPanel")`.
- **`UI/ToolOptionsBar.swift`** (new) — APP-4, SwiftUI, bound to `AppModel`, one per document window, height 30 pt, full width, at the **top** of the content view above the canvas (above `ToolOverlayView`/`CanvasView`; 0004's status bar stays at the bottom). Root identifier `toolOptionsBar`. Left to right:
  1. **Tool** chooser — `Picker` (`.menu` style) labelled with the active tool's symbol and name, listing `model.implementedTools`; identifier `toolOptions.tool`, accessibility value = active display name. Selecting calls `model.selectTool`.
  2. `Divider`, then `ToolOptionsContent(toolID: model.activeToolID, model:)` — a `switch` with one case per tool that has options, `default: EmptyView()`. Zoom and Pan have none (Paint.NET shows no Zoom/Pan options). 0009/0011/0012/… add their cases with hand-built controls reading and writing through `model.toolOptions` (identifiers `toolOptions.<option>`).
  3. `Spacer`, then **Finish** (`toolOptions.finish`) only when `descriptor.supportsPendingEdits`, enabled iff `model.hasPendingToolEdit`, action `dispatcher.commitPendingEdit()`. (No current tool shows it.)
  - The bar takes an `onEndEditing: () -> Void` closure that later specs' text fields call on Return/Escape; `DocumentWindowController` passes `{ window.makeFirstResponder(canvasView) }`, so tool keys work again right after editing a value.
- **`Document/DocumentWindowController.swift`** (modify): content = vertical stack `ToolOptionsBar` (30 pt) / container (`CanvasView` + `ToolOverlayView`) / status bar (0004). Owns `CanvasInputRouter` and `CanvasToolSession`; reports open/close to `PanelController.refresh()` and main-window changes to `AppModel.setActiveSession`.
- **`App/LaunchOptions.swift`**: no change needed (its prefixes already cover `tool.`, `panel.`, `NSWindow Frame panel.`, and 0004's `settings.`; 0007 adds `colors.`, giving the final list `["tool.", "panel.", "NSWindow Frame panel.", "colors.", "settings."]`, D-37). Add the regression test below.
- **Test support** (new):
  - `PaintDotMacTests/Support/FakeToolContext.swift`: `@MainActor final class FakeToolContext: ToolContext` (an `InMemoryToolOptionStore`, a `FakeCanvasNavigation`, a 64×64 `LayeredImage`, recorded `activatedTools: [ToolID]`, `overlays: [ToolOverlay?]`, `cursorInvalidations: Int`, settable `previousToolID`) and `@MainActor final class FakeCanvasNavigation: CanvasNavigating` (settable `transform`; records `setZoomCalls: [(Double, CGPoint)]` and `panCalls: [PanCall]` with `.begin(CGPoint)`, `.continue(CGPoint)`, `.end`; it does not move anything). Later specs extend both.
  - `PaintDotMacTests/Support/StubTool.swift`: `@MainActor final class StubTool: Tool` with configurable `id`, `hasPendingEdit`, `capturesKeyboard`, `keyDownResult`, and an optional `onMouseUp` closure; records every call in order (`calls: [String]`, e.g. `"activate"`, `"mouseDown(primary)"`, `"commit"`) and the received `ToolEvent`s.
  - `UITestApp`: add `func isToolSelected(_ id: String) -> Bool` (`app.descendants(matching: .any)["tool.\(id)"].isSelected`), `func panel(_ identifier: String) -> XCUIElement` (`app.descendants(matching: .any)[identifier]`), and `func statusValue(_ id: String) -> String`.
- **project.yml:** no target changes; new files sit under the existing source globs. Run `xcodegen generate`.
- **PRD.md / AGENTS.md:** no changes. (APP-2, APP-4, T-7, T-8, the key groups, the 1 s cycling with Shift reverse and the start tool (D-35), the placeholder panels (D-36), and the reset prefixes (D-37) are already in the PRD.)

## Acceptance criteria

- [ ] `ToolID` lists all 19 Paint.NET tools in Tools-window order with the exact display names, keys, and groups in the table. → `ToolRegistryTests.descriptorsMatchTable`, `ToolRegistryTests.idsMatchAllCases`
- [ ] The Tools panel shows only implemented tools (Zoom and Pan now), highlights the active tool, and shows "Name (Key)" tooltips; clicking a tool selects it. → `ToolsPanelUITests.testShowsImplementedToolsOnly`, `testClickingToolSelectsIt`; manual tooltip check
- [ ] Single-key shortcuts select tools (Z, H); keys of unimplemented tools are consumed silently; repeated presses within 1 s cycle the S/M/O groups in D-13 order, Shift cycles backward, and after 1 s a press starts again at the group's first tool. → `ToolShortcutResolverTests.*`, `ToolDispatcherTests.shortcutSelectsTool`, `.unimplementedKeyConsumed`, `.autoRepeatIgnored`; `ToolsPanelUITests.testToolKeysSelectTools`
- [ ] Tool shortcuts never fire while a text field has focus, while a sheet/dialog is key, with ⌘/⌥/⌃ held, while a tool captures the keyboard, or during a mouse gesture; they do fire while a floating panel was just clicked. → `ToolShortcutGateTests.*`, `ToolDispatcherTests.shortcutIgnoredDuringGesture`, `.shortcutIgnoredWhileToolCapturesKeyboard`; `ToolsPanelUITests.testShortcutsIgnoredInTextField`, `testShortcutsWorkAfterClickingPanel`
- [ ] Switching tools deactivates the old tool (committing its pending edit) before activating the new one and records the previous tool; tool-requested switches are applied after the handler returns; switching documents commits into the old document. → `ToolDispatcherTests.selectCallsDeactivateThenActivate`, `.switchCommitsPendingEdit`, `.previousToolTracked`, `.requestedSwitchIsDeferred`, `.contextChangeCommitsIntoOldContext`
- [ ] Left = primary, right = secondary, Control-left = secondary with `.control` kept; only one gesture at a time; Escape cancels a gesture and swallows its remaining events. → `ToolDispatcherTests.buttonMapping`, `.secondButtonIgnored`, `.escapeCancelsGesture`, `.orphanEventsIgnored`
- [ ] Return/Enter commits and Escape cancels a pending edit through the default `keyDown`; the Finish button appears only for tools that support pending edits. → `ToolDefaultsTests.*`, `ToolOptionsBarModelTests` (see test plan)
- [ ] Tool options are stored under `tool.<id>.<option>`, survive a new store instance on the same defaults (TOOL-C), fall back to defaults on missing/wrong-typed values, and are clamped. → `ToolOptionStoreTests.*`, `UserDefaultsToolOptionStoreTests.*` (UI-level persistence of a visible option arrives with 0009/0011/0012)
- [ ] Zoom tool: click zooms in one preset around the click point; Option-click and right-click zoom out one preset; at the limits nothing happens; dragging ≥ 3 pt draws a dashed rectangle and zooms so the rectangle fills the view (1 %–3200 %), centered; Escape cancels. → `ZoomToolTests.*`; `ZoomPanToolUITests.testZoomToolClickAndOptionClick`, `testZoomToolRectangle`
- [ ] Pan tool: dragging with either button moves the image with the pointer; open/closed hand cursors. → `PanToolTests.*`; `ZoomPanToolUITests.testPanToolDrags`; manual cursor check
- [ ] Zoom and Pan never change pixels or mark the document edited. → `ZoomToolTests.noDocumentSideEffects`, `PanToolTests.noDocumentSideEffects`; `ZoomPanToolUITests.testZoomAndPanDoNotDirtyDocument`
- [ ] Window menu has Tools ⌥⌘1, History ⌥⌘2, Layers ⌥⌘3, Colors ⌥⌘4 (checkmark = visible); each toggles its floating panel; visibility and frames persist across launches; the close button hides and persists; panels are hidden while no document is open. → `MainMenuTests.windowMenuHasPanelToggles`, `PanelKindTests.*`, `AppModelPanelTests.*`, `PanelControllerTests.*`; `PanelsUITests.*`; manual frame check
- [ ] The tool options bar sits at the top of every document window and shows the active tool in `toolOptions.tool`. → `ToolsPanelUITests.testClickingToolSelectsIt`, `PanelsUITests.testOptionsBarInEveryWindow`
- [ ] The app starts with the Pan tool (the Paintbrush once 0009 registers it) and never persists the active tool (D-35). → `ToolRegistryTests.defaultTool`, `AppModelToolTests.activeToolNotPersisted`
- [ ] History, Layers, and Colors panels show "Not available yet." until their specs land (D-36). → `PanelControllerTests.placeholderIdentifiers`, `PanelsUITests.testPlaceholderText`
- [ ] `-UITestResetDefaults` clears `tool.*`, `panel.*.visible`, `NSWindow Frame panel.*`, and (0004's) `settings.*`, and nothing else. → `LaunchOptionsPanelKeysTests.resetCoversPanelAndToolKeys`
- [ ] Core gains no AppKit/SwiftUI imports (quality-gate check).
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **No document open:** dispatcher context is `nil`; pointer/key events are ignored; tool selection (panel is hidden, but shortcuts can't reach it either because no eligible window is key) is a no-op path that never crashes; Window menu panel items are disabled; panels are ordered out. → `ToolDispatcherTests.noContextIgnoresEvents`, `PanelsUITests.testPanelsHiddenWithoutDocuments`
- **Selecting an unimplemented tool** (`selectTool(.recolor)`): returns `false`, nothing changes. → `ToolDispatcherTests.selectUnimplementedIsNoOp`
- **Selecting the active tool again:** no deactivate/activate, no `onStateChange`. → `.selectSameToolIsNoOp`
- **Tool switch requested twice in one handler:** last request wins. → `.requestedSwitchIsDeferred`
- **Context switch mid-gesture** (window closes while dragging): `cancel` then `deactivate` on the old context, gesture dropped, the late `pointerUp` ignored. → `.contextChangeMidGestureCancels`
- **Second mouse button during a gesture / drag without down / up of another button:** ignored. → `.secondButtonIgnored`, `.orphanEventsIgnored`
- **Shift with Caps Lock**, **"S" from Caps Lock without Shift:** key = `s`, direction from the Shift flag only. → `ToolShortcutResolverTests.capsLockIsNotShift`
- **Cycle window boundary:** 0.999 s cycles; exactly 1.0 s restarts. → `.cycleWindowBoundary`
- **Different key in between** (S, M, S within 1 s): the second S starts at Rectangle Select. → `.otherKeyResetsCycle`
- **Active tool not in the group** although S was the last key (user clicked Pan in the panel in between): S selects the first tool. → `.activeOutsideGroupStartsFresh`
- **Partially implemented group** (only Rectangle Select and Magic Wand): cycles between those two. → `.partialGroupCycles`
- **Zoom click at 3200 % / Option-click at 1 %:** no `setZoom` call. → `ZoomToolTests.noOpAtLimits`
- **Zoom drag just under the threshold** (2.9 pt) → click; exactly 3 pt → rectangle. Threshold is in view points, so it is the same at 1 % and 3200 % and at 1×/2× backing scale. → `ZoomToolTests.dragThreshold`, `.thresholdIndependentOfZoom`
- **Degenerate rectangle** (a 200 × 0 canvas-unit drag): the zero side counts as one device pixel; zoom fits the other side. → `.zeroHeightRectangle`
- **Rectangle larger than the view** → zooms out; tiny rectangle at high zoom → 3200 %. → `.rectangleLargerZoomsOut`, `.rectangleClampsToMaximum`
- **Rectangle drawn right-to-left / bottom-to-top:** standardized. → `.reversedDrag`
- **Escape during a zoom rectangle:** overlay cleared, no zoom; the following mouseUp does nothing. → `.escapeCancelsRectangle`
- **Pan tool on an image smaller than the view:** 0004's clamping keeps it centered; the calls are made, nothing moves; no crash.
- **Space held while the Text tool (0040) captures the keyboard:** Space goes to the tool, not to 0004's pan (router rule; covered when 0040 adds a capturing tool, and here by `ToolDispatcherTests.shortcutIgnoredWhileToolCapturesKeyboard` for the gate).
- **Stored option of the wrong type** (`tool.paintbrush.width = "abc"`), **non-finite double**, **non-integral number for an Int key**, **out-of-range value:** default or clamped. → `ToolOptionStoreTests.*`
- **Panel close button vs app quit:** only the close button persists "hidden"; quitting with panels visible relaunches with them visible. → `PanelsUITests.testPanelVisibilityPersistsAcrossRelaunch`, manual
- **Panel frame saved on a display that's gone:** AppKit's `setFrameUsingName` constrains it on screen; if it fails, the default frame is used. → manual
- **Full-screen document window:** panels float over it (`.fullScreenAuxiliary`). → manual
- **App inactive:** panels hide (`hidesOnDeactivate`) and come back on activation. → manual

## Test plan

Expected values below are worked out by hand from the rules above and 0004's preset list (`… 2/3, 1, 3/2, 2 …`).

- **Unit tests** (Swift Testing, `@MainActor` where needed):
  - `PaintDotMacTests/Tools/ToolEventTests.swift`
    - `toolKeyFromKeyCodes`: (36, "\r") → `.returnKey`; (76, "\u{3}") → `.enter`; (53, "\u{1b}") → `.escape`; (51) → `.delete`; (117) → `.forwardDelete`; (48) → `.tab`; (49, " ") → `.space`; 123/124/125/126 → left/right/down/up; (1, "S") → `.character("s")`; (1, "") → `.other(keyCode: 1)`; (1, "ab") → `.other(keyCode: 1)`.
  - `PaintDotMacTests/Tools/ToolRegistryTests.swift`
    - `idsMatchAllCases`: `allDescriptors.map(\.id) == ToolID.allCases`, 19 entries, IDs unique.
    - `descriptorsMatchTable`: every row of the table (display name, key, group, `supportsPendingEdits`) asserted literally; `helpText` for zoom is `"Zoom (Z)"`, for lineCurve `"Line / Curve (O)"`.
    - `rawValuesAreDefaultsIDs`: `ToolID.rawValue`s equal the brief's IDs (`rectangleSelect`, …, `shapes`).
    - `allShortcutKeys`: equals `{s,m,z,h,f,g,b,e,p,k,l,r,t,o}`; `x` and `d` are not members (0007's keys).
    - `standardRegistersZoomAndPan`: `ToolRegistry.standard().implementedIDs == [.zoom, .pan]` (later tool specs update this list), `makeTool(.zoom) is ZoomTool`, `makeTool(.recolor) == nil`.
    - `shortcutGroupsInCycleOrder` (registry with `StubTool` factories for all 19): `shortcutGroup(for: "s") == [.rectangleSelect, .lassoSelect, .ellipseSelect, .magicWand]`; `"m" == [.moveSelectedPixels, .moveSelection]`; `"o" == [.lineCurve, .shapes]`; `"z" == [.zoom]`; `"x" == []`.
    - `groupsExcludeUnimplemented`: registry with only `.magicWand` and `.rectangleSelect` → `shortcutGroup(for: "s") == [.rectangleSelect, .magicWand]`.
    - `defaultTool`: standard → `.pan`; registry with `.paintbrush` + `.pan` stubs → `.paintbrush`; registry with only `.zoom` → `.zoom`.
  - `PaintDotMacTests/Tools/ToolShortcutResolverTests.swift` (group S = the four selection tools, timestamps in seconds):
    - `toolKeyParsing`: "s" → s, "S" → s, "x" → nil, "" → nil, "ss" → nil, "1" → nil, "[" → nil.
    - `firstPressSelectsFirst`: active `.pan`, S at t=0 → `.rectangleSelect`.
    - `cyclesForward`: then (active updated each time) S at 0.5 → lasso, 0.9 → ellipse, 1.3 → magicWand, 1.7 → rectangleSelect (wrap).
    - `shiftStartsAtLastAndCyclesBackward`: active `.pan`, Shift+S at 0 → `.magicWand`; Shift+S at 0.4 → `.ellipseSelect`; S (no Shift) at 0.8 → `.magicWand`.
    - `cycleWindowBoundary`: active lasso after S at 0; S at 0.999 → ellipse; separately, S at 1.0 → rectangleSelect.
    - `otherKeyResetsCycle`: S at 0 (→ rectangle), M at 0.2 (group M → moveSelectedPixels), S at 0.4 with active moveSelectedPixels → rectangleSelect.
    - `activeOutsideGroupStartsFresh`: S at 0 (→ rectangle), active then set to `.pan` externally, S at 0.3 → rectangleSelect.
    - `partialGroupCycles`: group [rectangleSelect, magicWand]: S, S, S within 1 s from `.pan` → rectangle, magicWand, rectangle.
    - `singleToolGroupStays`: group [zoom], active zoom, Z at 0 and 0.2 → `.zoom` both times.
    - `emptyGroupReturnsNil`: group [] → nil.
    - `capsLockIsNotShift`: characters "S" with `shift: false` behaves as unshifted.
  - `PaintDotMacTests/Tools/ToolShortcutGateTests.swift` — table: (no modifiers, document, false, false, false) → true; same with `.shift` → true; with `.panel` → true; with each of `.command`, `.option`, `.control` → false; `.other` window → false; `textInputHasFocus` → false; `toolCapturesKeyboard` → false; `gestureInProgress` → false.
  - `PaintDotMacTests/Tools/ToolOptionStoreTests.swift` (`InMemoryToolOptionStore`):
    - `defaultsKeyFormat`: `ToolOptionKey(tool: .paintbrush, name: "width", defaultValue: 2.0).defaultsKey == "tool.paintbrush.width"`.
    - `missingReturnsDefault`; `roundTripTypes`: Bool, Int, Double (2.5), String, and a test `enum Mode: String, ToolOptionValue { case a, b }` (stored value is the string `"b"`).
    - `wrongTypeReturnsDefault`: raw `"abc"` under an Int key → default; raw `2.5` under an Int key → default; raw `Double.nan` under a Double key → default; raw `"zzz"` under the enum key → default.
    - `rangeClampsOnReadAndWrite`: key range 1...2000 default 2: `setValue(5000)` stores 2000 (raw read back 2000); raw 0 stored directly → reads 1.
    - `keysEqualByToolAndName`: two keys with the same tool/name and different defaults are `==`; different tool → `!=`.
    - `removeValueRestoresDefault`.
  - `PaintDotMacTests/App/UserDefaultsToolOptionStoreTests.swift` (suite `UserDefaultsToolOptionStoreTests.\(UUID())`, removed afterwards):
    - `persistsAcrossInstances` (TOOL-C): store A sets `tool.zoom.testOption = 7`; a new store B on the same suite reads 7; `defaults.object(forKey: "tool.zoom.testOption") as? Int == 7`.
    - `onChangeAndRevision`: `setValue` increments `revision` by 1 and calls `onChange` once with the key.
  - `PaintDotMacTests/Tools/ToolDefaultsTests.swift` (a minimal `final class` conforming with only the required members, plus `FakeToolContext`):
    - `defaultDeactivateCommitsPending`: `hasPendingEdit = true` → `deactivate` calls `commit` once; `false` → not called.
    - `defaultKeyDown`: pending + `.returnKey` → `commit`, returns true; pending + `.enter` → true; pending + `.escape` → `cancel`, true; not pending + `.returnKey` → false, no calls; `.character("a")` → false.
    - `defaultCursorIsArrow`; `defaultFlagsChangedInvalidatesCursor` (`cursorInvalidations == 1`); `descriptorAccessors` (`displayName`, `shortcutKey` come from the registry table).
  - `PaintDotMacTests/Tools/ToolDispatcherTests.swift` (registry with `StubTool`s for `.pan` (default), `.zoom`, `.rectangleSelect`, `.lassoSelect`, `.ellipseSelect`, `.magicWand`, `.colorPicker`; `FakeToolContext`):
    - `initialStateAndActivation`: `activeToolID == .pan`, `previousToolID == nil`; `setContext(ctx)` → pan stub calls `["activate"]`.
    - `selectCallsDeactivateThenActivate`: select `.zoom` → pan `[…, "deactivate"]`, zoom `["activate"]`, ordered deactivate-before-activate (shared call log); `previousToolID == .pan`; `onStateChange` count 1.
    - `switchCommitsPendingEdit`: pan stub `hasPendingEdit = true` → selecting zoom logs `"commit"` on pan before zoom's `"activate"`.
    - `previousToolTracked`: pan → zoom → colorPicker → `previousToolID == .zoom`; then colorPicker → zoom → `previousToolID == .colorPicker`.
    - `selectSameToolIsNoOp`, `selectUnimplementedIsNoOp` (`.recolor` → false, state unchanged, no calls).
    - `buttonMapping`: `.left` → `mouseDown(primary)`, `.right` → `secondary`, `.left` + `.control` → `secondary` and the received modifiers contain `.control`; drag events carry the gesture's button and `clickCount == 0`.
    - `secondButtonIgnored`: left down, right down, right up, left drag, left up → the tool sees down(primary), dragged, up only.
    - `orphanEventsIgnored`: drag and up without a down → no tool calls.
    - `escapeCancelsGesture`: down, Escape → `cancel` once, `keyDown` returns true; following drag not delivered; up not delivered; a new down afterwards is delivered normally.
    - `escapeWithoutGestureGoesToTool`: Escape → stub `keyDown` receives `.escape`.
    - `requestedSwitchIsDeferred`: stub's `onMouseUp` calls `ctx.activateTool(.zoom)` then `.colorPicker` (via `requestToolSwitch`) and asserts `dispatcher.activeToolID == .pan` inside the handler; after `pointerUp` returns: `activeToolID == .colorPicker`, `previousToolID == .pan`, pan logged `"deactivate"` after `"mouseUp"`. A request made from `mouseDragged` applies only after the gesture's `pointerUp`.
    - `selectDuringGestureDeferred`: down, `selectTool(.zoom)` → still `.pan`; up → `.zoom`.
    - `contextChangeCommitsIntoOldContext`: pan pending; `setContext(ctx2)` → pan `commit` received `ctx1` (identity), then `activate` received `ctx2`.
    - `contextChangeMidGestureCancels`: down on ctx1, `setContext(ctx2)` → `cancel`, `deactivate` on ctx1; `pointerUp` ignored.
    - `noContextIgnoresEvents`: `setContext(nil)` → pointer and `keyDown` produce no tool calls and return false; `selectTool(.zoom)` still works (no activate until a context is set, then `activate` on set).
    - `shortcutSelectsTool`: `handleShortcut("z", [], false, t: 0, .document, false)` → true, active `.zoom`; `"h"` → `.pan`; `"s"` → `.rectangleSelect`.
    - `unimplementedKeyConsumed`: `"l"` → true, active unchanged, no calls.
    - `nonToolKeyNotConsumed`: `"x"`, `"q"`, `"["` → false.
    - `autoRepeatIgnored`: S at 0 → rectangle; S `isRepeat: true` at 0.1 → true, still rectangle.
    - `shortcutIgnoredDuringGesture`: down, then `"z"` → false, active unchanged.
    - `shortcutIgnoredWhileToolCapturesKeyboard`: stub `capturesKeyboard = true` → `"z"` → false; `insertText("z")` reaches the stub.
    - `shortcutIgnoredWithModifiersOrTextFocus`: `"z"` with `.command` → false; with `textInputHasFocus: true` → false; with `.other` → false.
    - `pendingEditMirroring`: stub sets `hasPendingEdit = true` inside `mouseUp` → `onStateChange` fires and `dispatcher.hasPendingEdit == true`; `commitPendingEdit()` calls `commit`.
    - `optionsDidChangeForwarded`; `cursorFromActiveTool`.
  - `PaintDotMacTests/Tools/ZoomToolTests.swift` (`FakeToolContext`; `FakeCanvasNavigation.transform` = image 4000×3000, view 800×600 pt, backing scale 1, zoom 1, center (2000, 1500) unless stated; build events with matching `location = transform.viewToCanvas(viewLocation)`):
    - `clickZoomsInAroundPoint`: down/up at view (100, 200) → `setZoomCalls == [(1.5, (100, 200))]`, no pan calls, `overlays` never non-nil.
    - `optionClickZoomsOut`: with `.option` → `[(2/3, (100, 200))]`. `secondaryClickZoomsOut`: `.secondary` → `[(2/3, …)]`.
    - `zoomFromNonPreset`: zoom 1.2 → click → 1.5; Option-click → 1.0.
    - `noOpAtLimits`: zoom 32 click → no calls; zoom 0.01 Option-click → no calls.
    - `dragThreshold`: drag to (+2.9, +2.9) then up → click behavior (one `setZoom(1.5, down point)`), no overlay; drag to (+3, 0) → rectangle mode (overlay set).
    - `thresholdIndependentOfZoom`: same two cases at zoom 32 and 0.01 and with backing scale 2 → same outcomes.
    - `rectangleZoomMath` (pure `rectangleZoom`): rect (100,100,200,100) at zoom 1, scale 1, view 800×600 → **4.0**; same with backing scale 2 → **8.0**; rect 1600×600 at zoom 1, scale 1 → **0.5**; rect 10×10 at zoom 4 → 80 → **32**; rect 100000×100000 at zoom 0.01 → 0.008 → **0.01**.
    - `zeroHeightRectangle`: rect 200×0 at zoom 1 scale 1 → height counts as 1 → **4.0**.
    - `rectangleGesture` (this test uses center (400, 300) so the drag is on screen: image origin in device = (0, 0), so with 0003's bottom-left view space `canvasToView((x, y)) = (x, 600 − y)`): down at view (100, 500) / canvas (100, 100), drag to view (300, 400) / canvas (300, 200), up there → overlay sequence ends with `.zoomRectangle((100,100,200,100))` then `nil`; `setZoomCalls == [(4.0, (200, 450))]` (the rect's mid (200, 150) in bottom-left view space; a top-left mistake would give (200, 150)); `panCalls == [.begin((200, 450)), .continue((400, 300)), .end]` (the fake doesn't change its transform, so the post-zoom point equals the anchor).
    - `reversedDrag`: from canvas (300,200) to (100,100) (view (300, 400) to (100, 500)) → same overlay rect and calls.
    - `optionDragStillZoomsIn`: rectangle with `.option` → zoom 4.0.
    - `escapeCancelsRectangle`: rectangle in progress, `cancel` → last overlay `nil`, no `setZoom`; a following `mouseUp` → no calls.
    - `cursorFollowsOption`: `cursor(at: .zero, modifiers: [])` → `.zoomIn`; `[.option]` → `.zoomOut`; `[.option, .shift]` → `.zoomOut`.
    - `noDocumentSideEffects`: after click, Option-click, and rectangle gestures, the fake context's image is unchanged (`==` to a copy taken before) and only navigation/overlay/cursor calls were recorded.
  - `PaintDotMacTests/Tools/PanToolTests.swift`:
    - `dragPans`: down at view (100,100), dragged (110,100), (130,105), up (130,105) → `panCalls == [.begin((100,100)), .continue((110,100)), .continue((130,105)), .continue((130,105)), .end]`. Events carry deliberately wrong `location`s (e.g. `.zero`) to prove only `viewLocation` is used.
    - `secondaryButtonPans`: same with `.secondary`.
    - `cursorStates`: idle `.openHand`; after down `.closedHand`; after up `.openHand`; `cursorInvalidations` incremented on down and up.
    - `cancelEndsPan`: down, `cancel` → `.end` recorded once; later dragged → no call.
    - `noDocumentSideEffects`: as for Zoom.
  - `PaintDotMacTests/App/PanelKindTests.swift`: titles, key equivalents "1"…"4", autosave names `panel.tools/history/layers/colors`, visibility keys `panel.<kind>.visible`, accessibility and menu identifiers; every autosave name satisfies `LaunchOptions.shouldReset(key: "NSWindow Frame " + name)` and every visibility key `shouldReset`. `defaultFrames`: visible frame (0, 25, 1440, 875), size 76×120 → Tools (16, 764, 76, 120); size 220×260: History (1204, 624, 220, 260), Layers (1204, 41, 220, 260), Colors (16, 41, 220, 260). Visible frame with origin (−1920, 0, 1920, 1080), size 100×100 → Tools (−1904, 964, 100, 100).
  - `PaintDotMacTests/App/AppModelPanelTests.swift` (suite defaults): `defaultVisibleTrue` (all four); `togglePersists` (toggle tools → `defaults.bool(forKey: "panel.tools.visible") == false`; a new `AppModel` on the suite reports hidden; toggling again → true); `nonBoolStoredReadsVisible` (`"panel.tools.visible" = "x"` → visible).
  - `PaintDotMacTests/App/AppModelToolTests.swift`: `mirrorsDispatcherState` (`selectTool(.zoom)` → `activeToolID == .zoom`, `previousToolID == .pan`); `optionChangeNotifiesActiveTool` (writing through `toolOptions` → active stub's `optionsDidChange` called); `implementedToolsOrder` == `[zoom, pan]` descriptors; `activeToolNotPersisted` (D-35): on a fresh suite, `selectTool(.zoom)`, then a new `AppModel` on the same suite → `activeToolID == .pan`, and the suite's persistent domain is empty (selecting a tool writes nothing).
  - `PaintDotMacTests/App/MainMenuTests.swift` (extend): `windowMenuHasPanelToggles` — the Window menu's items, ignoring AppKit-added ones, are Minimize, Zoom, separator, Tools, History, Layers, Colors, separator, Bring All to Front; the four have `keyEquivalent` "1"…"4", `keyEquivalentModifierMask == [.command, .option]`, action `togglePanel(_:)`, `representedObject` = raw value, identifiers `menu.window.panel.<kind>`.
  - `PaintDotMacTests/App/PanelControllerTests.swift` (hosted, `@MainActor`; injected `AppModel` on a suite; remove `NSWindow Frame panel.*` keys from `.standard` before and after): `panelsConfigured` (four panels; `isFloatingPanel`, `hidesOnDeactivate`, `becomesKeyOnlyIfNeeded`, `frameAutosaveName == "panel.tools"`, …, title, `.fullScreenAuxiliary`); `hiddenWithoutDocumentWindows` (`refresh()` with no document windows → none visible); `closeButtonPersistsHidden` (`windowShouldClose` → returns false, `isPanelVisible(.tools) == false`); `frameAutosaveWritten` (set the Tools panel frame → `UserDefaults.standard.string(forKey: "NSWindow Frame panel.tools") != nil`); `placeholderIdentifiers` (hosting content of history/layers/colors exposes the matching identifier — check the SwiftUI view's identifier via `PanelPlaceholderView(kind:).accessibilityIdentifierValue` exposed as a static helper — and `PanelPlaceholderView.message == "Not available yet."`).
  - `PaintDotMacTests/App/LaunchOptionsPanelKeysTests.swift`: `resetCoversPanelAndToolKeys` — suite with `tool.zoom.testOption`, `panel.history.visible`, `NSWindow Frame panel.colors`, `settings.measurementUnit` (0004's prefix), and `unrelated.key` → after `LaunchOptions.resetDefaults(in:domainName:)` with the suite name, only `unrelated.key` remains (`persistentDomain(forName:)` keys == `["unrelated.key"]`).
  - `PaintDotMacTests/UI/ToolSymbolTests.swift` (hosted): every `allDescriptors` symbol resolves with `NSImage(systemSymbolName:accessibilityDescription:) != nil`.
  - `PaintDotMacTests/UI/ToolOptionsBarModelTests.swift`: `finishVisibility` — the pure helper `ToolOptionsBar.showsFinish(for: ToolDescriptor) -> Bool` is true for moveSelectedPixels, text, lineCurve, shapes and false for the other 15; `finishEnabled(hasPendingEdit:)` mirrors the flag.
  - `PaintDotMacTests/Canvas/CanvasNavigationConformanceTests.swift` (hosted): build 0004's `CanvasNavigation` the way 0004's tests do (offscreen window + `CanvasView` if required), image 4000×3000, view 800×600: through the `CanvasNavigating` existential, `setZoom(2, anchoredAtView: (100, 100))` → `transform.viewToCanvas((100,100))` unchanged (±1e-9) and `transform.zoom == 2`; `beginPan((400,300))`, `continuePan((450,300))`, `endPan()` → `canvasToView` of the previous center point moved by +50 in x (±1e-9).
- **Round-trip / property tests:**
  - `ToolShortcutResolverTests.fullCycleReturnsToStart` (seeded, 200 cases, seed printed): random group size 1–4 (subset of S tools in order), random start active in the group, presses at random intervals < 1 s → after `n = group.count` presses the active tool equals the start; with Shift as well.
  - `ZoomToolTests.clickThenOptionClickRoundTrip`: for every preset `s` except the ends, click (in) then Option-click (out) → `setZoom` targets `nextLarger(s)` then `s` (feeding the first result back into the fake's transform).
  - `ToolOptionStoreTests.randomRoundTrip` (seeded, 200 cases): random Int in the key's range, random finite Double, random Bool/String → `value(key)` after `setValue` equals the input.
- **Golden-image tests:** none (no pixel output; the overlay is a static AppKit drawing checked manually).
- **Integration tests:** `PaintDotMacTests/Integration/ToolSessionIntegrationTests.swift` (hosted): `AppModel` on a suite with the standard registry, a `FakeToolContext` set as context; press "z" via `handleShortcut` → `ZoomTool` active; pointer down/up at view (100, 200) → fake navigation got `setZoom(1.5, (100, 200))`; Option-click → `setZoom(2/3, …)` from a fake transform at 1.0; "h" → Pan; drag → pan calls; `previousToolID == .zoom`.
- **UI tests** (XCUITest; `UITestApp`; fixtures generated at test time; default `resetDefaults: true`; tests never rely on which tool is active at launch):
  - `PaintDotMacUITests/ToolsPanelUITests.swift` (fixture 4000×2000 PNG):
    - `testShowsImplementedToolsOnly`: `toolsPanel` exists; `tool.zoom` and `tool.pan` exist; `tool.recolor` and `tool.cloneStamp` don't (P1 tools; 0056/0057 update this test).
    - `testClickingToolSelectsIt`: click `tool.zoom` → `isToolSelected("zoom")`, not pan; `toolOptions.tool` value "Zoom"; click `tool.pan` → pan selected, value "Pan".
    - `testToolKeysSelectTools`: click the canvas once (focus), type "z" → zoom selected; "h" → pan selected; "l" → pan still selected and the app is running.
    - `testShortcutsWorkAfterClickingPanel`: click `tool.zoom` in the panel, then type "h" → pan selected (the panel didn't take key focus).
    - `testShortcutsIgnoredInTextField`: type "h"; ⌘N; click `newImage.width`, select all, type "z"; the dialog is still open and pan is still selected; click `newImage.cancel` → pan selected.
  - `PaintDotMacUITests/PanelsUITests.swift`:
    - `testWindowMenuTogglesAllFourPanels`: for (identifier, key) in (`toolsPanel`,"1"), (`historyPanel`,"2"), (`layersPanel`,"3"), (`colorsPanel`,"4"): exists; `typeKey(key, modifierFlags: [.command, .option])` → doesn't exist (wait ≤ 2 s); again → exists. Window menu contains items "Tools", "History", "Layers", "Colors".
    - `testPanelCloseButtonHides`: click the Tools panel's close button (`panel.buttons[XCUIIdentifierCloseWindow]` on the window with identifier `panel.tools`) → `toolsPanel` gone; ⌥⌘1 → back.
    - `testPanelVisibilityPersistsAcrossRelaunch`: ⌥⌘3 hides Layers; terminate; relaunch with the same fixture and `resetDefaults: false` → `layersPanel` absent, `toolsPanel` present; ⌥⌘3 → present.
    - `testPanelsHiddenWithoutDocuments`: ⌘W → document window count 0 → `toolsPanel` doesn't exist and Window > Tools is disabled; File > Open the fixture again (0001 helper) → `toolsPanel` exists.
    - `testPlaceholderText` (D-36): `historyPanel`, `layersPanel`, and `colorsPanel` each contain a static text "Not available yet." (0007, 0010, 0025 change this test when they replace their panel).
    - `testOptionsBarInEveryWindow`: open two fixtures → each document window contains a `toolOptionsBar` element whose frame's minY is above the `canvas` frame's minY (bar on top), and the `statusBar.zoom` element is below the canvas.
  - `PaintDotMacUITests/ZoomPanToolUITests.swift` (fixture 4000×2000 PNG):
    - `testZoomToolClickAndOptionClick`: ⌘0 → zoom "100%"; type "z"; click the canvas center → "150%"; Option-click (`XCUIElement.perform(withKeyModifiers: .option) { canvas.click() }`) → "100%"; right-click → "67%".
    - `testZoomToolRectangle`: ⌘0; "z"; `dragOnCanvas(from: (0.45, 0.45), to: (0.55, 0.55))` → zoom value parses to > 300 % (a 10 %-of-view rectangle fills the view ≈ 10×).
    - `testPanToolDrags`: ⌘0; "h"; hover the canvas center, read `statusBar.cursor` x1; drag from the center to center + (120 pt, 0); hover the center again, read x2 → `x1 − x2 ≥ 100` (120 pt = 120 or 240 image px at 100 %); zoom still "100%".
    - `testZoomAndPanDoNotDirtyDocument`: "z", click; "h", drag; ⌘W → no sheet appears (`app.sheets.count == 0` after 1 s) and the document window count becomes 0.
- **Performance:** NF-1/NF-2 — the dispatcher adds O(1) work per mouse event (a struct, a few comparisons, no allocation besides the event value); Zoom/Pan reuse 0004's O(1) transform math. No `measure` test here; 0048 measures the paint path including routing.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` green: clean build with zero warnings, all tests pass with none skipped, UI tests ran, launch smoke passes.
- **Manual verification** (can't be automated):
  1. Cursors: with the Zoom tool, the canvas shows the zoom-in magnifier; holding Option switches to zoom-out and back on release (without moving the mouse). Pan tool: open hand, closed hand while dragging. Holding Space with the Zoom tool shows 0004's hand and pans; releasing restores the magnifier.
  2. Zoom rectangle: dashed black/white rectangle visible on light and dark images; zoomed result is centered on the rectangle (except at image edges).
  3. Middle mouse button (a three-button mouse) drags pan the canvas with any tool.
  4. Panels: on first launch Tools is top-left, History top-right, Layers bottom-right, Colors bottom-left of the main screen; move and resize them, quit, relaunch → same frames. They float above document windows, hide when switching to another app, come back on return, and appear over a full-screen document window.
  5. Click a Tools panel button, then press Z/H: the tool changes (the document window stays key, its title bar stays active).
  6. Tooltips: hover each tool → "Zoom (Z)", "Pan (H)".
  7. Two documents as tabs: switching tabs keeps the selected tool; the options bar is in both.
  8. Dark mode: Tools panel selection highlight, options bar, and placeholder text are legible. VoiceOver reads "Zoom, selected, button".

## Out of scope

- Every tool other than Zoom and Pan (0009 Paintbrush, 0011 Pencil/Eraser, 0012 Color Picker, 0014–0020 selection and move tools, 0017 Paint Bucket, 0023 Gradient, 0038–0040 Line/Curve, Shapes, Text, 0056/0057 P1 tools), each with its options-bar controls.
- Colors panel content and X/D (0007); History panel content (0010); Layers panel content (0025); `ToolContext.colors`, history commit, clip mask, and selection requirements (0007, 0008, 0009, 0013).
- `[`/`]` brush width keys (0009). Text input method (IME) support beyond `interpretKeyEvents` → `insertText` forwarding (0040).
- Docking panels (APP-3, 0052); the "restore panel positions" setting (APP-8, 0046).
- Space-pan, pinch, scroll, View menu zoom items, and the status bar (0004); Zoom to Selection (0014).
- Paint.NET's common-actions toolbar row, pixel grid and rulers toggles (0053), and Paint.NET's "Tool" drop-down shortcut Alt+T.
- Moving shortcuts into `ShortcutTable` and `docs/shortcuts.md` (0045).
- Tablet pressure (`ToolEvent.pressure` stays 1.0; TOOL-D, 0055).
