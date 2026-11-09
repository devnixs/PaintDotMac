# 0052 — Dock panels into document windows or float them as utility panels

> Source: PRD.md §5.1 APP-3 (P1: "Panels can be docked to the window or floated as utility panels (`NSPanel`). Their positions are remembered."), APP-2 (the four v1.0 floating panels, Window menu ⌥⌘1–4, frame autosave), APP-8 (Reset Panel Positions, delivered by 0046); PRD §5.12 (Show Tools/History/Layers/Colors ⌥⌘1–4); PRD §8 v1.x ("docked panels"); PRD §12 D-5, D-36, D-37. Paint.NET has no docking (its tool windows always float, https://www.getpaint.net/doc/latest/MainWindow.html), so the docking behavior below is PaintDotMac's own and is listed under Open questions.
> Milestone: v1.x
> Depends on: 0051-use-case-acceptance-tests (and through it everything up to v1.0). It extends 0006 (`PanelKind`, `PanelController`, `AppModel` panel visibility, Window menu), 0007 (`ColorsPanelView`, More/Less), 0010 (`HistoryPanelModel`/`HistoryPanelView`), 0025 (`LayersPanelModel`/`LayersPanelView`), 0045 (`ShortcutTable`, `MainMenuShortcutTests`), 0046 (`PanelController.resetPanelPositions`), and 0049 (`AccessibilityCatalog`, `AccessibilityText`, `KeyboardNavigationPlan`).

## Context

What exists before this spec (all from earlier specs; references are to the specs):

- **0006** `PaintDotMac/App/PanelController.swift` (`docs/specs/todo/0006-tool-framework-and-panels_TODO.md:277-285`):
  - `enum PanelKind: String, CaseIterable { case tools, history, layers, colors }` with `title`, `menuKeyEquivalent`, `frameAutosaveName` (`"panel.tools"` …), `visibilityDefaultsKey` (`"panel.tools.visible"` …), `accessibilityIdentifier` (`toolsPanel`, `historyPanel`, `layersPanel`, `colorsPanel`), `menuItemIdentifier` (`menu.window.panel.<kind>`), and the pure `static func defaultFrame(for:size:visibleFrame:) -> CGRect`.
  - `@MainActor final class PanelController: NSObject, NSWindowDelegate` builds one floating `NSPanel` per kind (`[.titled, .closable, .utilityWindow]`, `isFloatingPanel`, `hidesOnDeactivate`, `becomesKeyOnlyIfNeeded`, window identifier `panel.<kind>`), hosts `makeContent(for:)` in an `NSHostingView`, and applies the **showing rule** in `refresh()`: a panel is on screen iff `appModel.isPanelVisible(kind)` and at least one `documentWindow` is open. The close button hides (`setPanelVisible(kind, false)`).
  - `AppModel` (`0006…:275`): `isPanelVisible(_:)`, `setPanelVisible(_:_:)`, `togglePanel(_:)`, persisted as `panel.<kind>.visible` (default `true`). `activeSession`/`activeSessionGeneration` follow the main document window.
  - Window menu (`0006…:286`): Minimize ⌘M, Zoom, —, Tools ⌥⌘1, History ⌥⌘2, Layers ⌥⌘3, Colors ⌥⌘4, —, Bring All to Front; checkmark = visible; enabled iff a document window is open. `MainMenuTests.windowMenuHasPanelToggles` asserts this exact order.
  - `CanvasInputRouter.handleShortcutKeyDown` (`0006…:289`) classifies the key window as `.document` (identifier `documentWindow`), `.panel` (one of the four `NSPanel`s), or `.other` (`ToolKeyWindowKind`, `0006…:169`).
  - `DocumentWindowController` content (`0006…:307`): vertical stack `ToolOptionsBar` (30 pt) / canvas container (`CanvasView` + `ToolOverlayView`) / status bar (0004).
- **0007** hosts `ColorsPanelView` in the `.colors` panel; **More »/« Less** (`colors.moreLess`) resizes the panel to the hosting view's `fittingSize`, keeping the top-left corner fixed (`0007…:92`).
- **0010** `UI/HistoryPanelModel.swift` (`0010…:117-123`): one instance owned by `AppModel`; `bind(to bridge: UndoBridge?)`; it **follows the active document** by observing `AppModel.activeSessionGeneration`.
- **0025** `UI/LayersPanelModel.swift` (`0025…:124-128`): one instance owned by `AppModel` (`layersPanel`); `bind(to session: CanvasToolSession?)`; follows the active document the same way.
- **0045** `Core/Shortcuts/ShortcutTable.swift`; `MainMenuShortcutTests.everyItemMatchesTable` requires every identified menu item without a table entry to have `keyEquivalent == ""` (`0045…:381`).
- **0046** `PanelController.resetPanelPositions(visibleFrame:)` moves all four panels to `PanelKind.defaultFrame`, leaves visibility unchanged, and is called by Settings' **Reset Panel Positions** button (`0046…:113-119`, `0046…:139`).
- **0001/0007** `LaunchOptions.resettableKeyPrefixes == ["tool.", "panel.", "NSWindow Frame panel.", "colors.", "settings."]`; every key this spec adds starts with `panel.`, so `-UITestResetDefaults` already clears it (D-37).

What is missing: APP-3. Panels can only float. This spec lets each panel be **docked** into the document windows or **floated** as today, remembers which, and remembers the dock sizes.

### The design in one paragraph

Docking is an **app-wide layout** applied to every document window: when a panel is docked, every document window (each window tab, too) shows its own copy of that panel inside the window, and its floating `NSPanel` is hidden. **Tools** docks into a fixed-width **left dock column**. **History**, **Layers**, and **Colors** dock into a resizable **right dock column**, stacked top to bottom in that order (no tabs). The user docks and floats panels with **commands**, not drag and drop: a **Dock** button in each floating panel's title bar, a **Float** button in each docked panel's header, and a **Window > Docked Panels** submenu. The tool options bar and the status bar stay full width; the canvas gets the space between the dock columns. Docked Tools and Colors show the same app-wide state as their floating versions. Docked History and Layers show **the document of the window they are docked in**, so two side-by-side windows each show their own history and layers. Which panels are docked, the right dock's width, and the History/Layers split are pure `Core` state persisted under `panel.*`.

## User story

As a PaintDotMac user, I can dock the Tools, History, Layers, and Colors panels into my document window (so they move, resize, go full screen, and tab with it) or float them as separate utility panels, as I prefer. I choose per panel, the choice and the dock sizes survive relaunch, and Settings > Reset Panel Positions brings back the default floating layout.

## Scope & changes

### Core (pure, unit-tested; `Core` imports Foundation/CoreGraphics only)

1. **Move `PanelKind` into Core.** New file `PaintDotMac/Core/Panels/PanelKind.swift` holds the `enum PanelKind: String, CaseIterable, Sendable` declaration and its pure members from 0006 (`title`, `frameAutosaveName`, `visibilityDefaultsKey`, `accessibilityIdentifier`, `menuItemIdentifier`, `defaultFrame(for:size:visibleFrame:)`), unchanged. Any member that uses an AppKit type (for example a modifier-flag mask on `menuKeyEquivalent`) stays in `App/PanelController.swift` as `extension PanelKind`. Same module, so no call site changes; 0006's `PanelKindTests` must pass unchanged. Add pure members:
   - `var dockSide: DockSide` — `.tools → .left`; `.history, .layers, .colors → .right`.
   - `var dockedDefaultsKey: String` — `"panel.<rawValue>.docked"`.
   - `var dockedAccessibilityIdentifier: String` — `"dock.<rawValue>"` (the docked pane's container; the hosted panel view inside keeps its own identifier, e.g. `historyPanel`).
   - `var dockMenuItemIdentifier: String` — `"menu.window.dock.<rawValue>"`.
   - `var isFlexibleInDock: Bool` — `true` for `.history`, `.layers` (share the right column's free height); `false` for `.colors` (always its fitting height) and `.tools` (its column is exactly its fitting size).

2. **`PaintDotMac/Core/Panels/PanelLayout.swift`** (new):
   ```swift
   public enum DockSide: String, Sendable, CaseIterable { case left, right }

   public struct PanelLayout: Equatable, Sendable {
       public static let defaultRightDockWidth: Double = 240
       public static let rightDockWidthRange: ClosedRange<Double> = 180...480
       public static let defaultHistoryFraction: Double = 0.4
       public static let historyFractionRange: ClosedRange<Double> = 0.15...0.85
       public static let `default` = PanelLayout()          // all floating, 240, 0.4

       public private(set) var dockedPanels: Set<PanelKind>  // empty by default
       public private(set) var rightDockWidth: Double
       public private(set) var historyFraction: Double      // History's share of the flexible height when History and Layers are both docked

       public init(dockedPanels: Set<PanelKind> = [], rightDockWidth: Double = defaultRightDockWidth,
                   historyFraction: Double = defaultHistoryFraction)   // clamps both numbers; non-finite → default
       public func isDocked(_ kind: PanelKind) -> Bool
       public mutating func setDocked(_ kind: PanelKind, _ docked: Bool)
       public mutating func dockAll()
       public mutating func floatAll()
       public mutating func setRightDockWidth(_ w: Double)     // clamp to range; non-finite → ignored (unchanged)
       public mutating func setHistoryFraction(_ f: Double)    // clamp to range; non-finite → ignored
       /// Docked AND visible panels on `side`, in PanelKind.allCases order (right: history, layers, colors).
       public func shownDockedPanels(on side: DockSide, visible: (PanelKind) -> Bool) -> [PanelKind]
       /// True iff the floating NSPanel for `kind` should be on screen (0006's rule plus "not docked").
       public func showsFloatingPanel(_ kind: PanelKind, visible: Bool, hasDocumentWindow: Bool) -> Bool
   }
   ```

3. **`PaintDotMac/Core/Panels/PanelLayoutStore.swift`** (new): `struct PanelLayoutStore { init(defaults: UserDefaults); func load() -> PanelLayout; func save(_ layout: PanelLayout) }`.
   - Keys: `panel.<kind>.docked` (Bool, one per kind), `panel.dock.rightWidth` (Double), `panel.dock.historyFraction` (Double). `static let allKeys: [String]` lists the six keys.
   - `load()`: a missing key or a value of the wrong type uses that field's default (other fields unaffected); a stored number is clamped by `PanelLayout.init`; NaN/∞ → default. Never throws or traps.
   - `save(_:)` writes all six keys (Bools for every kind, so a later default change can't silently re-dock panels).
   - `panel.<kind>.visible` stays owned by 0006's `AppModel`; this store never reads or writes it.

4. **`PaintDotMac/Core/Panels/DockGeometry.swift`** (new) — all numbers in points, y measured **top-down** inside a column (the AppKit column view is flipped):
   ```swift
   public struct DockMetrics: Sendable, Equatable {
       public var headerHeight: Double = 22
       public var dividerThickness: Double = 1
       public var minFlexibleContentHeight: Double = 80
       public var minCanvasWidth: Double = 200
       public static let standard = DockMetrics()
   }
   public struct DockPaneFrame: Equatable, Sendable { public let kind: PanelKind; public let headerY: Double; public let contentY: Double; public let contentHeight: Double }
   public struct DockColumnLayout: Equatable, Sendable { public let panes: [DockPaneFrame]; public let fits: Bool; public let historyLayersDividerY: Double? }

   public enum DockColumnGeometry {
       /// `fittingHeights` gives the content height of each non-flexible pane (Colors: hosting view fittingSize.height).
       public static func layout(panes: [PanelKind], columnHeight: Double, fittingHeights: [PanelKind: Double],
                                 historyFraction: Double, metrics: DockMetrics = .standard) -> DockColumnLayout
       public static func minimumHeight(panes: [PanelKind], fittingHeights: [PanelKind: Double], metrics: DockMetrics = .standard) -> Double
       /// Maps a drag of the History/Layers divider to a new fraction (clamped to the range and so both panes keep ≥ minFlexibleContentHeight).
       public static func historyFraction(forDividerY y: Double, panes: [PanelKind], columnHeight: Double,
                                          fittingHeights: [PanelKind: Double], metrics: DockMetrics = .standard) -> Double
   }
   ```
   Rules for `layout` (n = panes.count, k = flexible panes):
   - Panes are laid out in the given order from y = 0: header `[y, y+22)`, content `[y+22, y+22+h)`, then a 1 pt divider before the next pane (none after the last).
   - Free flexible height `F = H − Σ fittingHeights(fixed panes) − n·22 − (n−1)·1`.
   - k = 2 (History and Layers): `history = (F × fraction).rounded()` (schoolbook rounding), clamped to `[80, F − 80]`; `layers = F − history`. k = 1: that pane gets F. k = 0: fixed panes at their fitting heights from the top; the rest of the column is empty.
   - If `F < 80·k`, every flexible pane gets 80 and `fits = false` (the column overflows and clips; the window minimum size, item 9, normally prevents this). Otherwise `fits = true` (k = 0: `fits = H ≥ Σ(22 + fitting) + (n−1)`).
   - `historyLayersDividerY` = the y of the divider between History and Layers when both are present, else `nil`.
   - `minimumHeight = Σ fittingHeights(fixed) + n·22 + (n−1)·1 + 80·k` (0 for no panes).
   ```swift
   public struct DockWidths: Equatable, Sendable { public let left: Double?; public let right: Double? }   // nil = column absent
   public struct DockWindowResolution: Equatable, Sendable { public let windowFrame: CGRect; public let rightDockWidth: Double?; public let canvasWidth: Double }

   public enum DockWindowGeometry {
       /// Content width the window needs: present columns + one divider per present column + minCanvasWidth.
       public static func requiredContentWidth(_ widths: DockWidths, metrics: DockMetrics = .standard) -> Double
       /// Called when the docked set changes. `currentFrame` is the window frame (macOS document windows have no side borders, so frame width == content width).
       public static func resolve(currentFrame: CGRect, widths: DockWidths, visibleFrame: CGRect?, canResize: Bool,
                                  metrics: DockMetrics = .standard) -> DockWindowResolution
   }
   ```
   Rules for `resolve`: let `R = requiredContentWidth`.
   - If `currentFrame.width ≥ R`: frame unchanged.
   - Else if `canResize` and `visibleFrame != nil`: `newWidth = min(R, visibleFrame.width)`; `x = currentFrame.minX`; if `x + newWidth > vf.maxX` then `x = vf.maxX − newWidth`; then `x = max(x, vf.minX)`. y and height unchanged. (The window grows to the right, or shifts left at the screen edge.)
   - Otherwise (full screen, `canResize == false`, or no screen) the frame is unchanged.
   - If the resulting width is still `< R`, the right dock (when present) shrinks by the deficit, but not below `rightDockWidthRange.lowerBound` (180). This shrink is **for this window only and is not persisted**.
   - `canvasWidth = frame.width − (left ?? 0) − (right' ?? 0) − dividers`, which may be below `minCanvasWidth` (≥ 0, never negative: clamp at 0) on tiny screens. No trap.

### App and UI glue (AppKit/SwiftUI; covered by hosted and UI tests)

5. **`App/AppModel.swift`** (modify):
   - `@ObservationIgnored let panelLayoutStore: PanelLayoutStore` (from the injected `defaults`), observable `private(set) var panelLayout: PanelLayout` loaded at init.
   - `func setPanelDocked(_ kind: PanelKind, _ docked: Bool)` — changes placement **and** sets `setPanelVisible(kind, true)` (the user asked to see it in its new place); saves. No-op (and no save) if the placement is already that value and the panel is visible.
   - `func dockAllPanels()` / `func floatAllPanels()` — change placement only; visibility unchanged; save.
   - `func setRightDockWidth(_:)`, `func setHistoryFraction(_:)` — update and save (callers invoke them on mouse-up only, item 8).
   - `func resetPanelLayout()` — `panelLayout = .default`, save.
   - ⌥⌘1–4 (`togglePanel`) is unchanged: it toggles **visibility** and never changes placement. A hidden docked panel stays docked and reappears docked.

6. **`App/PanelContentFactory.swift`** (new, `@MainActor enum PanelContentFactory`): `static func makeView(for kind: PanelKind, binding: PanelContentBinding) -> AnyView` with `enum PanelContentBinding { case activeDocument; case window(CanvasToolSession) }`. It returns the same SwiftUI views 0006/0007/0010/0025 host today (`ToolsPanelView(model: AppModel.shared)`, `ColorsPanelView(…)` with 0007's exact arguments, `HistoryPanelView(model:)`, `LayersPanelView(model:)`). `.activeDocument` uses `AppModel.shared.historyPanel` / `.layersPanel` (follow the active document, as today). `.window(session)` creates a **new** `HistoryPanelModel(followsActiveDocument: false)` bound with `bind(to: session.undoBridge)` and a new `LayersPanelModel(followsActiveDocument: false)` bound with `bind(to: session)`; the returned view owns them. Tools and Colors ignore the binding (app-wide state). `PanelController.makeContent(for:)` now calls `makeView(for:binding: .activeDocument)`.

7. **`UI/HistoryPanelModel.swift`** (0010) and **`UI/LayersPanelModel.swift`** (0025) (modify): add `init(…, followsActiveDocument: Bool = true)`. When `false`, the model never observes `AppModel.activeSessionGeneration`; it stays bound to whatever `bind(to:)` received (held weakly, as today). Every command (row click, Undo/Redo buttons, Add/Delete/Duplicate/Merge/Move layer, visibility, properties, drag reorder) already acts on the **bound** bridge/session: 0025's `perform(_:)` sends the menu action with `NSApp.sendAction(_:to:from:)` targeted at the **bound** document's `DocumentWindowController` (`0025…:131`), so a docked Layers panel edits its own window's document with no change to that path. Busy state (`isDocumentBusy`, 0031) comes from the bound bridge.

8. **`Document/DocumentDockController.swift`** (new, `@MainActor final class`), one per `DocumentWindowController`:
   - Builds the window's middle row as an `NSSplitView` (vertical dividers, `dividerStyle = .thin`, identifier `dock.split`) with up to three arranged subviews: left dock column (identifier `dock.left`), the existing canvas container, right dock column (identifier `dock.right`). The tool options bar stays above and the status bar below, both full window width. Columns that have no shown panels are removed from the split view (not just collapsed), so the canvas gets the full width.
   - Holding priorities: columns 260, canvas container 250, so window resizes change only the canvas width. The left column's width = docked Tools hosting view's `fittingSize.width` (not resizable: `splitView(_:constrainMinCoordinate:…)`/`constrainMaxCoordinate` pin it). The right column's width = `panelLayout.rightDockWidth` (or the per-window shrunk width from item 9), user-resizable between 180 and 480 via the divider; on mouse-up (`splitViewDidResizeSubviews` while `NSEvent.pressedMouseButtons != 0` → remember, then commit on the next event with no button pressed, or via the split view's own mouse-up) it calls `AppModel.shared.setRightDockWidth(_:)` once. Other open windows pick the new width up through observation.
   - Observes `AppModel.shared.panelLayout` and visibility (`withObservationTracking`, re-armed after each change, coalesced to one apply per run-loop turn) and calls `apply()`: computes `shownDockedPanels(on:)` for both sides, creates/removes docked panes, keeps existing pane hosting views (no rebuild when only sizes change, so list scroll positions and SwiftUI state survive), and runs item 9.
   - Each docked pane is a container `NSView` (identifier `kind.dockedAccessibilityIdentifier`, e.g. `dock.history`) holding a `DockedPanelHeader` (item 10) and an `NSHostingView` of `PanelContentFactory.makeView(for: kind, binding: .window(session))`.
   - The right column is `Document/DockColumnView.swift` (new, flipped `NSView`): it positions its panes from `DockColumnGeometry.layout(…)` in `layout()`, using each fixed pane's hosting `fittingSize.height` (Colors; so More »/« Less changes the Colors pane height and re-lays out the column — instead of 0007's panel resize, which only applies while Colors floats). The History/Layers divider (1 pt line, 7 pt hit area, `NSCursor.resizeUpDown`, identifier `dock.right.historyLayersDivider`) is dragged by the view itself: during the drag it re-lays out with `historyFraction(forDividerY:…)` locally; on mouse-up it calls `AppModel.shared.setHistoryFraction(_:)` once.

9. **Window sizing when the dock changes** (`DocumentDockController.apply()`):
   - When the set of present columns grows, call `DockWindowGeometry.resolve(currentFrame: window.frame, widths:, visibleFrame: window.screen?.visibleFrame, canResize: !window.styleMask.contains(.fullScreen))` and, if the frame changed, `window.setFrame(_, display: true, animate: false)`. Apply the returned `rightDockWidth` to this window's column only.
   - Floating a panel (columns shrink) never shrinks the window; the canvas widens.
   - Update `window.contentMinSize`: width = `requiredContentWidth`, height = max(0001's minimum, toolbar 30 + `DockColumnGeometry.minimumHeight(right panes)` + status bar height, toolbar + Tools fitting height + status bar). If the window is currently shorter than the new minimum height, grow it downwards within `visibleFrame` (same clamping idea as width; pure helper `DockWindowGeometry.resolveHeight(currentFrame:requiredContentHeight:visibleFrame:canResize:)` with the analogous rules — top edge fixed, then shift up at the bottom screen edge).
   - The canvas view's frame change goes through 0004's `CanvasView.setFrameSize` → `CanvasTransform.resized(to:)` (keeps zoom and view-center point, re-clamps). Zoom to Window (⌘B) uses the canvas bounds, so it fits the image into the space between the docks with no extra code.

10. **`UI/DockedPanelHeader.swift`** (new, SwiftUI in an `NSHostingView`, 22 pt high): the panel title (`kind.title`, `.font(.subheadline.weight(.semibold))`, secondary background bar), then two borderless icon buttons on the trailing side:
    - **Float** — SF Symbol `macwindow.on.rectangle`, tooltip "Float", accessibility label "Float \(title) Panel", identifier `dock.<kind>.float` → `AppModel.shared.setPanelDocked(kind, false)`.
    - **Close** — SF Symbol `xmark`, tooltip "Close", accessibility label "Close \(title) Panel", identifier `dock.<kind>.close` → `AppModel.shared.setPanelVisible(kind, false)` (same as the floating panel's close button).
    - Root identifier `dock.<kind>.header`.
    - For the narrow Tools column (≈ 72 pt), the title is omitted when it doesn't fit (`ViewThatFits`), buttons stay.

11. **`App/PanelController.swift`** (modify, 0006/0007/0046):
    - `refresh()` uses `appModel.panelLayout.showsFloatingPanel(kind, visible:, hasDocumentWindow:)`. A docked panel's `NSPanel` is ordered out but **not moved**, so its frame autosave (`NSWindow Frame panel.<kind>`) keeps the last floating frame and floating it again puts it back exactly there. Observe `panelLayout` (re-armed `withObservationTracking`) and call `refresh()` on change.
    - Each floating panel gets an `NSTitlebarAccessoryViewController` (`layoutAttribute = .trailing`) with one borderless button: SF Symbol `sidebar.left` for Tools, `sidebar.right` for the others; tooltip "Dock"; accessibility label "Dock \(title) Panel"; identifier `panel.<kind>.dock`; action `AppModel.shared.setPanelDocked(kind, true)`.
    - 0007's Colors More/Less panel resize runs only while Colors floats (docked: the column relayout of item 8 handles it).
    - `resetPanelPositions(visibleFrame:)` (0046) additionally calls `appModel.resetPanelLayout()` **first** (all panels float again, dock width 240, History fraction 0.4), then sets the floating frames as 0046 specifies. With `visibleFrame == nil` it still resets the layout but moves no frames (0046's no-op rule applies to frames only). Visibility stays unchanged.
    - `CanvasInputRouter`'s key-window classification is unchanged: a docked panel lives in the document window, so its key window is `.document` and single-key tool shortcuts keep working after clicking a docked button or row, as long as no text field has focus (Colors hex field: `textInputHasFocus` already blocks them).

12. **`App/MainMenu.swift`** (modify): the Window menu becomes Minimize ⌘M, Zoom, —, Tools ⌥⌘1, History ⌥⌘2, Layers ⌥⌘3, Colors ⌥⌘4, **Docked Panels ▸**, —, Bring All to Front.
    - Submenu "Docked Panels" (parent identifier `menu.window.dockedPanels`): **Tools**, **History**, **Layers**, **Colors** (identifiers `menu.window.dock.<kind>`, action `toggleDockedPanel(_:)`, `representedObject = kind.rawValue`, checkmark = docked), —, **Dock All Panels** (`menu.window.dockAll`, action `dockAllPanels(_:)`), **Float All Panels** (`menu.window.floatAll`, action `floatAllPanels(_:)`).
    - No key equivalents (0045: identified items without a `ShortcutTable` entry must have `keyEquivalent == ""`; no table change, `docs/shortcuts.md` unchanged).
    - **`App/AppDelegate.swift`** implements the three actions (forwarding to `AppModel`: `toggleDockedPanel` → `setPanelDocked(kind, !isDocked(kind))`) and their `validateMenuItem`: enabled iff a document window is open (same rule as the ⌥⌘1–4 toggles); `toggleDockedPanel` state `.on` iff docked; Dock All disabled when all four are docked, Float All disabled when none is.
    - Update 0006's `MainMenuTests.windowMenuHasPanelToggles` to the new order.

13. **`PaintDotMacUITests/Support/UITestApp.swift`** (modify): add `func chooseSubmenuItem(_ menu: String, _ submenu: String, _ item: String)` (click menu bar item → hover/click the submenu item → click the item) and `func dockPane(_ kind: String, in window: XCUIElement? = nil) -> XCUIElement` (descendant with identifier `dock.<kind>` of `window ?? documentWindows.firstMatch`).

14. **`Core/Accessibility/AccessibilityCatalog.swift`** (0049, modify): docked copies keep 0049's contract. The hosted panel views inside a docked pane keep their identifiers (`toolsPanel`, `historyPanel`, `layersPanel`, `colorsPanel`, `tool.<id>`, `historyRow.<index>`, `layerRow.<index>`, `colors.*`, …), labels, values, and `KeyboardNavigationPlan`s unchanged; `AccessibilityCatalog.entry(matching:)` already resolves them regardless of which window hosts them. Add these entries (catalog order = the order below; `isSelectable` false; value `.none` unless stated):
    - surface `.documentWindow`, after the status-bar entries: `dock.split` group "Dock"; `dock.left` group "Left Dock"; `dock.right` group "Right Dock"; `dock.<id>` group, dynamic label "panel title" (`PanelKind.title`: "Tools", "History", "Layers", "Colors"); `dock.<id>.header` group, dynamic "panel title"; `dock.<id>.float` button, dynamic "Float <panel title> Panel"; `dock.<id>.close` button, dynamic "Close <panel title> Panel"; `dock.right.historyLayersDivider` group "History and Layers divider" (hidden from Tab order, like 0049's `curvePlotNotFocusable` rule — it is a pointer-only splitter).
    - surface `.toolsPanel` / `.historyPanel` / `.layersPanel` / `.colorsPanel` (one exact entry each, appended after that surface's existing entries): `panel.tools.dock` button "Dock Tools Panel", `panel.history.dock` "Dock History Panel", `panel.layers.dock` "Dock Layers Panel", `panel.colors.dock` "Dock Colors Panel".
    - The formatted labels come from one new helper `AccessibilityText.dockButtonLabel(_ verb: String, panelTitle: String) -> String` (`"Float"`, `"History"` → `"Float History Panel"`), used by `DockedPanelHeader` and the title-bar accessory; the views don't format inline.
    - `KeyboardNavigationPlan` (0049): the docked Float/Close buttons are reachable by Full Keyboard Access in header order (Float, then Close) before the pane's own plan; no other plan changes.

15. No `project.yml` change beyond new files under existing source folders; run `xcodegen generate` after adding files. No PRD change in this spec (its open questions go to the user first).

## Acceptance criteria

- [ ] Each of the four panels can be docked from Window > Docked Panels and from the floating panel's title-bar Dock button, and floated from the same submenu and from the docked header's Float button. Docking shows the panel in every open document window and hides its floating panel; floating does the reverse. → `DockablePanelsUITests.testDockAndFloatEachPanelFromMenu`, `.testDockAndFloatWithHeaderButtons`, `PanelControllerDockTests.dockedPanelIsNotOnScreen`
- [ ] Tools docks to the left column; History, Layers, Colors dock to the right column, top to bottom in that order, with Colors at its fitting height and History/Layers sharing the rest by the saved fraction. → `DockColumnGeometryTests.*`, `PanelLayoutTests.shownDockedPanelsOrder`, `DocumentDockControllerTests.columnsAndOrder`
- [ ] Docked History and Layers show the document of their own window; Tools and Colors show app-wide state in every window. → `DocumentDockControllerTests.dockedHistoryIsPerWindow`, `HistoryPanelModelPinnedTests.*`, `LayersPanelModelPinnedTests.*`, `DockablePanelsUITests.testTwoWindowsEachShowOwnHistory`
- [ ] Docked panels work: tool buttons select tools, history rows jump, layer rows select, Colors edits colors; single-key tool shortcuts still work after clicking a docked panel. → `DockablePanelsUITests.testDockedPanelsAreFunctional`
- [ ] ⌥⌘1–4 and the header Close button toggle a docked panel's visibility without changing its placement; a column with no shown panels disappears and the canvas widens. → `AppModelPanelLayoutTests.toggleKeepsPlacement`, `DockablePanelsUITests.testToggleDockedPanelVisibility`
- [ ] Docking/floating a single panel makes it visible; Dock All / Float All change placement only. → `AppModelPanelLayoutTests.dockSetsVisible`, `.dockAllKeepsVisibility`
- [ ] Placement, right dock width, and History fraction persist across relaunch under `panel.*` keys and are cleared by `-UITestResetDefaults`. → `PanelLayoutStoreTests.*`, `PanelLayoutStorePropertyTests.roundTrip`, `DockablePanelsUITests.testLayoutPersistsAcrossRelaunch`
- [ ] A floated panel returns to its last floating frame. → `PanelControllerDockTests.floatRestoresFrame`
- [ ] Docking never covers the canvas: the window widens (clamped to the screen) when needed, floating never shrinks the window, window resizes change only the canvas width, and the canvas keeps zoom and center on resize. → `DockWindowGeometryTests.*`, `DocumentDockControllerTests.windowGrowsWhenNarrow`, `.windowUnchangedWhenWideEnough`, `.floatDoesNotShrinkWindow`, `DockablePanelsUITests.testCanvasSitsBetweenDocks`
- [ ] Dragging the right dock divider or the History/Layers divider persists once on mouse-up and applies to all open windows. → `DocumentDockControllerTests.widthChangePropagates`; manual (drag feel)
- [ ] Settings > Reset Panel Positions floats every panel, resets the dock width and fraction, moves floating panels to their default frames, and keeps visibility. → `PanelControllerResetTests.resetFloatsDockedPanels`, `.resetWithoutScreenStillResetsLayout`, `DockablePanelsUITests.testResetPanelPositionsFloatsAll`
- [ ] Docked panes keep 0049's accessibility contract: the hosted panel views keep their identifiers, labels, and values, and every new dock control (`dock.*`, `panel.<kind>.dock`) has a catalog entry and a non-empty specific label. → `AccessibilityCatalogTests.dockEntries`, `AccessibilityTextTests.dockButtonLabel`, `DockablePanelsUITests.testDockedPanesMatchCatalog`
- [ ] Window menu order and the Docked Panels submenu (titles, identifiers, checkmarks, enabling, no key equivalents) are exact. → `MainMenuTests.windowMenuHasPanelToggles`, `.dockedPanelsSubmenu`, `DockMenuValidationTests.*`, 0045's `MainMenuShortcutTests.everyItemMatchesTable`
- [ ] With no `panel.*.docked` keys (upgrade from v1.0 or fresh install), every panel floats exactly as in v1.0. → `PanelLayoutStoreTests.missingKeysAllFloat`; every existing panel UI test keeps passing unchanged
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **No document window:** dock commands are disabled (as ⌥⌘1–4); state changes from Settings' reset still apply and are used by the next window.
- **Window tabs:** each tab is its own `documentWindow` with its own dock; switching tabs shows that tab's own History/Layers. Merging/splitting tabs keeps each window's dock. → manual + `DocumentDockControllerTests.dockedHistoryIsPerWindow`
- **Full screen:** the window can't resize; the right dock shrinks to fit (not below 180, not persisted); the canvas may go below 200 pt but never negative. → `DockWindowGeometryTests.fullScreenShrinksDockOnly`
- **Tiny screen / negative-origin secondary screen:** growth clamped to `visibleFrame`, shifting left at the right edge, never left of `vf.minX`. → `DockWindowGeometryTests.clampedAtRightEdge`, `.negativeOriginScreen`, `.tinyScreenShrinksDock`
- **No screen (`window.screen == nil`):** frame unchanged, dock shrink rule applies. → `DockWindowGeometryTests.noScreen`
- **Column too short for its panes** (`F < 80·k`): flexible panes get 80 pt each, `fits == false`, clipped, no trap; the min-size rule (item 9) normally prevents this. → `DockColumnGeometryTests.tooShort`
- **Only Colors docked on the right:** Colors at the top at fitting height, the rest empty. → `DockColumnGeometryTests.colorsOnly`
- **Colors More »/« Less while docked:** the Colors pane height changes, History/Layers absorb it; if the column becomes too short, the window grows (item 9). → `DocumentDockControllerTests.colorsExpandRelayouts`
- **Corrupt defaults:** wrong types, NaN, ∞, out-of-range values → per-field default or clamp. → `PanelLayoutStoreTests.*`
- **Closing a window with docked History/Layers:** the pinned models hold the bridge weakly and are released with the window; no observation of a closed document survives. → `HistoryPanelModelPinnedTests.releasedWithWindow`
- **Effect running (busy) in one window:** that window's docked Layers/History show disabled controls; other windows' docks stay enabled. → `LayersPanelModelPinnedTests.busyIsPerDocument`
- **Pending tool edit (floating pixels, text, shape) when clicking a docked History/Layers control:** goes through the same `prepareForNavigation`/commit path as the floating panels (0010/0025), on the bound document. → covered by 0010/0025's tests on the shared models; `DockablePanelsUITests.testDockedPanelsAreFunctional` checks a jump after a stroke.
- **Rapid toggling** (dock/float many times): pane hosting views are created/removed without leaks of observers; floating `NSPanel` instances are reused (never recreated). → `PanelControllerDockTests.panelInstancesReused`, `DocumentDockControllerTests.repeatedToggleIsStable`
- **Undo inside docked panel text fields** (Colors hex): ⌘Z in the field edits the field (the field editor's undo), not document history — same as floating today. → manual

## Test plan

- **Unit tests** (Swift Testing):
  - `PaintDotMacTests/Panels/PanelKindDockTests.swift`: `dockSides` (tools → left, others right); `keysAndIdentifiers` (`panel.tools.docked` …, `dock.tools` …, `menu.window.dock.tools` …); `flexibility` (history, layers true; tools, colors false); every new key passes `LaunchOptions.shouldReset(key:)`.
  - `PaintDotMacTests/Panels/PanelLayoutTests.swift`: `defaultIsAllFloating` (empty set, 240, 0.4); `dockAndFloat` (dock history → isDocked true, others false; float → false); `dockAllFloatAll`; `idempotent` (docking twice = once); `widthClamped` (100 → 180, 999 → 480, 300 → 300, `.nan` → unchanged); `fractionClamped` (0 → 0.15, 1 → 0.85, `.infinity` → unchanged); `initClamps` (`PanelLayout(rightDockWidth: .nan)` → 240); `shownDockedPanelsOrder` (dock colors, history, layers in that call order → right side `[history, layers, colors]`; with layers hidden → `[history, colors]`; left `[]`; dock tools → left `[tools]`); `showsFloatingPanelRule` (truth table over docked × visible × hasDocumentWindow: only `!docked && visible && hasDoc` is true).
  - `PaintDotMacTests/Panels/PanelLayoutStoreTests.swift` (fresh `UserDefaults(suiteName:)` per test, removed afterwards): `missingKeysAllFloat` (empty suite → `.default`); `roundTrip` (dock tools + layers, width 300, fraction 0.6 → save → new store load equals); `saveWritesAllSixKeys` (exact key set == `allKeys`, Bool values false for floating kinds); `wrongTypes` (`panel.history.docked = "yes"`, `panel.dock.rightWidth = "wide"` → history floating, width 240, other fields from their keys); `nonFinite` (`panel.dock.historyFraction = Double.nan` → 0.4); `outOfRange` (width 50 → 180, fraction 0.99 → 0.85); `doesNotTouchVisibility` (save leaves `panel.history.visible` absent/unchanged).
  - `PaintDotMacTests/Panels/DockColumnGeometryTests.swift` (hand-computed): `allThree` (H 600, Colors fitting 200, fraction 0.4 → F = 600 − 200 − 66 − 2 = 332; History header 0, content 22, height 133; Layers header 156, content 178, height 199; Colors header 378, content 400, height 200; divider y 155; fits); `historyAndColors` (H 600 → History content height 355, Colors header 378); `historyOnly` (H 500 → content 478); `colorsOnly` (H 600, fitting 200 → Colors header 0, content 22, height 200, fits); `tooShort` (H 300, all three → History 80, Layers 80, fits false); `fractionClampsToMinimum` (H 300, History+Layers, fraction 0.15 → F = 300 − 44 − 1 = 255, history = round(38.25) = 38 → clamped 80, layers 175); `minimumHeight` (all three, fitting 200 → 200 + 66 + 2 + 160 = 428; none → 0); `dividerDragMapsToFraction` (allThree, divider dragged to y 222 → history content = 200 → fraction 200/332 ≈ 0.6024 (±1e-9)); `dividerDragClamps` (y 10 → 0.15 bound or the 80 pt bound, whichever is larger: 80/332 ≈ 0.241 → 0.241; y 590 → (332 − 80)/332 ≈ 0.759).
  - `PaintDotMacTests/Panels/DockWindowGeometryTests.swift`: `requiredWidth` (left 72 + right 240 → 72 + 240 + 2 + 200 = 514; right only → 441; none → 200); `windowUnchangedWhenWideEnough` (frame (100,100,600,500) → same, right 240, canvas 600 − 72 − 240 − 2 = 286); `clampedAtRightEdge` (frame (1000,100,400,500), vf (0,0,1440,875), both → (926,100,514,500), canvas 200); `growsInPlace` (frame (100,100,400,500) → (100,100,514,500)); `negativeOriginScreen` (vf (−1920,0,1920,1080), frame (−500,100,400,500) → x −514, width 514); `tinyScreenShrinksDock` (vf (0,0,450,800), frame (0,0,400,500), both → width 450, right 180, canvas 450 − 72 − 180 − 2 = 196); `fullScreenShrinksDockOnly` (canResize false, frame (0,0,400,800) → unchanged, right 180, canvas 146); `noScreen` (visibleFrame nil → frame unchanged); `canvasNeverNegative` (frame width 100, both → canvas 0); `resolveHeight` cases (grow down; shift up at bottom edge; clamp to vf height; full screen unchanged).
- **Round-trip and property tests:** `PaintDotMacTests/Panels/PanelLayoutStorePropertyTests.swift` — 500 seeded random op sequences (0002's `SeededRandom`, seed printed on failure) over `setDocked`/`dockAll`/`floatAll`/`setRightDockWidth(random incl. NaN, negatives, huge)`/`setHistoryFraction(…)`: after each op the invariants hold (width ∈ range, fraction ∈ range) and `save` → `load` returns an equal layout.
- **Hosted unit tests** (`@MainActor`, injected `AppModel` on a suite; remove `NSWindow Frame panel.*` from `.standard` before and after, like 0006):
  - `PaintDotMacTests/App/AppModelPanelLayoutTests.swift`: `dockSetsVisible` (hide history, `setPanelDocked(.history, true)` → docked and visible, both persisted); `toggleKeepsPlacement` (docked layers, `togglePanel(.layers)` twice → still docked, visible flips); `dockAllKeepsVisibility` (colors hidden → dockAll → colors docked and still hidden); `resetPanelLayout` (→ `.default`, keys rewritten); `layoutObservable` (a `withObservationTracking` on `panelLayout` fires on dock).
  - `PaintDotMacTests/App/PanelControllerDockTests.swift`: `dockedPanelIsNotOnScreen` (open a hidden-window test document controller, dock history → `panel(.history).isVisible == false`, others visible); `floatRestoresFrame` (set history frame F, dock, float → frame == F and `NSWindow Frame panel.history` still decodes to F); `titlebarDockButton` (each panel has exactly one titlebar accessory whose button identifier is `panel.<kind>.dock`; performing its action docks that kind); `panelInstancesReused` (dock/float 20× → same `NSPanel` object identity).
  - `PaintDotMacTests/App/PanelControllerResetTests.swift` (0046's file, extend): `resetFloatsDockedPanels` (dock all, width 400 → reset → layout `.default`, all four floating panels on screen at `defaultFrame`, visibility unchanged); `resetWithoutScreenStillResetsLayout` (`visibleFrame: nil` → layout `.default`, frames unchanged).
  - `PaintDotMacTests/App/MainMenuTests.swift` (extend): `windowMenuHasPanelToggles` (new order incl. "Docked Panels"); `dockedPanelsSubmenu` (titles Tools, History, Layers, Colors, separator, Dock All Panels, Float All Panels; identifiers as item 12; all `keyEquivalent == ""`).
  - `PaintDotMacTests/Accessibility/AccessibilityCatalogTests.swift` (0049, extend): `dockEntries` — the catalog contains exactly the entries of item 14 with those roles/labels; `entry(matching: "dock.history.float")` is the `dock.<id>.float` pattern; `entry(matching: "panel.colors.dock")` has surface `.colorsPanel` and label "Dock Colors Panel"; 0049's `identifiersAreUnique`, `labelsAreNotIdentifiers`, `buttonsHaveLabels`, `tabOrderIsCatalogOrder` keep passing. `AccessibilityTextTests.dockButtonLabel` (`("Float","History")` → "Float History Panel"; `("Dock","Tools")` → "Dock Tools Panel"; `("Close","Colors")` → "Close Colors Panel").
  - `PaintDotMacTests/App/DockMenuValidationTests.swift`: no document window → all disabled; with one → enabled; checkmark tracks `isDocked`; Dock All disabled when all docked, Float All disabled when none docked.
  - `PaintDotMacTests/UI/HistoryPanelModelPinnedTests.swift`: two `UndoBridge`s A and B; `HistoryPanelModel(followsActiveDocument: false)` bound to A; set `AppModel.activeSession` to B's session → model still shows A's rows (record a step on A → row count +1; on B → unchanged); `releasedWithWindow` (drop A → model shows `.empty`, no crash, `refreshCount` stops changing).
  - `PaintDotMacTests/UI/LayersPanelModelPinnedTests.swift`: same pinning check with layer rows; Add New Layer from the pinned model adds a layer to A, not to the active B; `busyIsPerDocument` (A busy → pinned-A buttons disabled, pinned-B enabled).
  - `PaintDotMacTests/Document/DocumentDockControllerTests.swift` (real `DocumentWindowController` with a 200×150 image, window not ordered front, frame (100,100,800,600) on a stubbed visible frame): `columnsAndOrder` (dock all → `dock.left` contains `dock.tools`; `dock.right` contains `dock.history`, `dock.layers`, `dock.colors` with increasing y in the flipped column); `canvasWidthShrinks` (dock history → canvas container width == 800 − 240 − 1); `windowUnchangedWhenWideEnough`; `windowGrowsWhenNarrow` (frame width 400, dock all → width 514); `floatDoesNotShrinkWindow`; `widthChangePropagates` (two controllers; `setRightDockWidth(300)` → both right columns 300 after one run-loop turn); `dockedHistoryIsPerWindow` (two controllers with distinct documents; commit a step in A → A's docked History has 2 rows, B's has 1); `colorsExpandRelayouts` (toggle Colors expanded → Colors pane height == hosting fitting height; History+Layers heights shrink by the delta); `repeatedToggleIsStable` (dock/float history 50× → exactly 0 or 1 `dock.history` subview, observers not accumulating: an apply counter increments once per change).
- **Integration tests:** not applicable beyond the hosted tests above — this spec changes no pixels or history; the per-window History/Layers bindings are exercised against real `UndoBridge`s in the pinned-model and dock-controller tests.
- **UI tests** (`PaintDotMacUITests/DockablePanelsUITests.swift`; launch with 400×300 PNG fixtures from `UITestApp.makePNG`, `-UITestResetDefaults YES` unless stated):
  1. `testDockAndFloatEachPanelFromMenu`: for each of Tools, History, Layers, Colors: `chooseSubmenuItem("Window", "Docked Panels", <Kind>)` → `dockPane(kind)` exists inside the document window, `app.windows["panel.<kind>"]` doesn't exist, the submenu item is checked; choose it again → floating window `panel.<kind>` exists, `dock.<kind>` gone, unchecked.
  2. `testDockAndFloatWithHeaderButtons`: for each kind: click `panel.<kind>.dock` in the floating panel → `dock.<kind>` exists; click `dock.<kind>.float` → floating again.
  3. `testToggleDockedPanelVisibility`: dock Layers only → `dock.right` exists; ⌥⌘3 → `dock.layers` and `dock.right` gone, `canvas` frame wider than before; ⌥⌘3 → back; click `dock.layers.close` → gone and Window > Layers unchecked.
  4. `testDockedPanelsAreFunctional`: Dock All Panels; click `tool.paintbrush` in `dock.tools` → selected; drag on canvas → `historyRow.1` in `dock.history`; click `historyRow.0` → `historyRow.1` greyed/undone (0010's accessibility value); press `e` → `tool.eraser` selected (tool key after clicking a docked row); click `colors.swap` in `dock.colors` → `colors.primary` value changes; ⇧⌘N → `layerRow.1` in `dock.layers`.
  5. `testTwoWindowsEachShowOwnHistory`: open two fixtures; dock History; both `documentWindows` have `dock.history`; paint in window 1 → its `dock.history` has `historyRow.1`, window 2's has only `historyRow.0`.
  6. `testLayoutPersistsAcrossRelaunch`: dock History and Colors; terminate; `launch(opening:resetDefaults: false)` → `dock.history`, `dock.colors` exist, `panel.tools` and `panel.layers` float.
  7. `testCanvasSitsBetweenDocks`: Dock All → `canvas.frame.minX ≥ dock.left.frame.maxX` and `canvas.frame.maxX ≤ dock.right.frame.minX`; window width ≥ 514.
  8. `testResetPanelPositionsFloatsAll`: Dock All; open Settings (⌘,), click Reset Panel Positions (`settings.resetPanelPositions`), close Settings → all four `panel.<kind>` windows exist, no `dock.*` panes.
  9. `testDockedPanesMatchCatalog`: Dock All Panels; using 0049's `UITestApp.loadCatalog()`, inside the document window every descendant with a non-empty identifier matches a catalog entry; `dock.history` contains `historyPanel` with label "History" and `historyRow.0`'s label/value as in 0049's `testHistoryPanelMatchesCatalog`; `dock.layers.float` label "Float Layers Panel"; Float All → floating `panel.layers` window's `panel.layers.dock` label "Dock Layers Panel".
- **Performance:** no NF-1–NF-4 target changes. Docked panels in inactive windows only observe their own document, so a stroke in one window rebuilds only that window's History/Layers. 0048's measurements stay green; no new `measure` test.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes. 0006/0007/0010/0025/0045/0046 tests still pass (with the two menu-order updates named above).
- **Manual verification** (feel and system behaviors UI tests can't judge):
  1. **Divider drag feel:** drag the right dock divider slowly and quickly — the canvas resizes smoothly with no flicker, the divider stops at 180 and 480 pt, the image stays centered (0004's resize rule). Release → a second open window adopts the width.
  2. **History/Layers divider:** drag it — resize cursor shows, both panes stop at 80 pt, list scroll positions are kept.
  3. **Window live resize** with both docks: only the canvas changes width; docks keep their width.
  4. **Full screen** (⌃⌘F) with Dock All: panels are inside the full-screen window; floating panels (if any) are not shown on top of other spaces.
  5. **Window tabs** (Window > Merge All Windows): each tab shows its own History/Layers; switching tabs doesn't flash.
  6. **Small screen / second display:** move a narrow window to the right edge, Dock All → it widens leftward and stays on screen; on a display left of the main one as well.
  7. **Dark mode and Increase Contrast:** header bar, dividers, and icons are legible in light and dark (APP-7).
  8. **Title-bar Dock button** on the utility panels looks native (size, alignment, hover) and the tooltip reads "Dock".
  9. **VoiceOver:** the Float/Close/Dock buttons announce "Float History Panel", etc.

## Open questions

Per the open-questions policy, the recommended answer is applied throughout this spec; each needs the user's confirmation (and then a PRD §5.1 APP-3 / §12 update).

1. **How does the user dock and undock a panel?** Paint.NET has no docking to mirror. Options: (a) explicit commands — a Dock button in each floating panel's title bar, a Float button in each docked panel's header, and a Window > Docked Panels submenu (with Dock All / Float All); (b) drag a panel's title bar onto the window edge to dock, and drag a docked header out to float; (c) both. **Recommended (applied): (a).** It is deterministic, keyboard- and VoiceOver-accessible, and fully UI-testable; drag-to-dock can be added later on top of the same `PanelLayout` model.
2. **Where do docked panels go, and stacked or tabbed?** **Recommended (applied):** Tools in a fixed-width left column; History, Layers, Colors stacked (not tabbed) in that order in one resizable right column; fixed order and sides (not user-configurable). Alternatives: everything in one right column; tabs within the column; user-chosen side and order.
3. **What is the default layout for new installs and v1.0 upgrades?** **Recommended (applied):** all panels float, exactly as in v1.0 (D-5); docking is opt-in.
4. **What does Settings > Reset Panel Positions do once docking exists?** **Recommended (applied):** it restores the whole default layout — floats every docked panel, resets the dock width (240 pt) and History/Layers split (40%), and moves floating panels to their default frames; visibility is unchanged and the button keeps its label "Reset Panel Positions".
5. **What content does a docked History/Layers panel show in a window that isn't the active one, and what happens to the window when docking needs space?** **Recommended (applied):** each window's docked History and Layers show that window's own document (Tools and Colors are app-wide); when a window is too narrow for its docks, it widens (clamped to the screen) rather than squeezing the canvas below 200 pt, and floating never shrinks the window.

## Out of scope

- Drag-to-dock / drag-to-undock, user-reorderable or user-sided docks, tabbed dock panes, collapsing panes to their headers (see Open questions 1–2).
- Per-window dock layouts (the layout is app-wide).
- Changes to panel contents or behavior (0006, 0007, 0010, 0025), keyboard shortcuts (0045 table unchanged; no dock shortcuts), or Settings window layout (0046's button is reused).
- Pixel grid and rulers (0053), palettes and screen eyedropper in the Colors panel (0054).
- Windows app parity (PaintDotMac is macOS-only).
