# 0010 — Add the History panel: list every step, jump by clicking, grey out undone steps

> Source: PRD.md §5.7 H-1, H-2 (with H-3 and H-5 behavior already provided by 0008), §5.1 APP-2 (History panel, ⌥⌘2), §3 use case 5, §8 M1 exit criterion ("Can draw on an image and undo through the History panel"), §6 NF-7 (VoiceOver labels). Paint.NET docs: [History Window](https://www.getpaint.net/doc/latest/HistoryWindow.html), [Main Window](https://www.getpaint.net/doc/latest/MainWindow.html), [Keyboard & Mouse Commands](https://www.getpaint.net/doc/latest/KeyboardMouseCommands.html).
> Milestone: M1 (Paint)
> Depends on: 0006-tool-framework-and-panels, 0008-history-stack-and-undo-bridge, 0009-paintbrush-tool (and transitively 0001–0005, 0007)

## Context

There is no application code yet. When this spec is built, the earlier specs provide:

- **0008** `PaintDotMac/Core/History/HistoryStack.swift`: `struct HistoryStack` with `steps: [HistoryStep]` (`steps[0]` is the base step "Open Image"/"New Image"), `currentIndex`, `canUndo`, `canRedo`, `undoStep`, `redoStep`, budget-driven folding of the oldest non-base steps into the base (H-5). `struct HistoryStep: Identifiable` has `id: HistoryStep.ID` (`Int`, base = 0, monotonically increasing, never reused, so it is stable across drops and discards), `name`, `icon: HistoryIcon`, `isBase`. `Core/History/HistoryIcon.swift`: `enum HistoryIcon: String, CaseIterable, Sendable` with the cases `openImage`, `newImage`; `rectangleSelect`, `lassoSelect`, `ellipseSelect`, `magicWand`, `moveSelectedPixels`, `moveSelection`, `paintBucket`, `gradient`, `paintbrush`, `eraser`, `pencil`, `cloneStamp`, `recolor`, `text`, `lineCurve`, `shapes`; `selectAll`, `deselect`, `invertSelection`, `eraseSelection`, `fillSelection`, `cut`, `paste`, `cropToSelection`, `resizeImage`, `resizeCanvas`, `flipRotate`, `layerAdd`, `layerDelete`, `layerDuplicate`, `layerMerge`, `layerMove`, `layerProperties`, `flatten`, `importLayer`, `adjustment`, `effect`; `generic`. 0008 gives them no symbols.
- **0008** `PaintDotMac/Document/UndoBridge.swift`: `@MainActor @Observable final class UndoBridge`, one per document: `history: HistoryStack`, `historyRevision: Int` (+1 exactly once per recorded step, undo, redo, moving `jump`, dropping `setBudget`, `markSaved`, `reset`), `undoManager`, `undo()`, `redo()`, `jump(to:)` (replays `undoManager.undo()`/`redo()` so the Edit menu stays exact, calls `prepareForNavigation` once first, and reports one state change and one revision bump at the end), `init(state:base:budgetBytes:undoManager:)`, `commit(_:)`. `Canvas/CanvasToolSession.swift` exposes `undoBridge` (0008). Test support: `PaintDotMacTests/History/Support/FakeHistoryItem.swift`.
- **0006** `PaintDotMac/App/PanelController.swift` with `PanelKind.history`: an app-wide floating `NSPanel`, toggled from Window > History (⌥⌘2), frame remembered by frame autosave name, shown only while a document window is open. It hosts `PanelPlaceholderView` ("Not available yet.", D-36) until this spec. `App/AppModel.swift` is the `@MainActor @Observable` shared state with `activeSession: CanvasToolSession?` and the observable `activeSessionGeneration` that panels showing document state observe. Test doubles: `FakeToolContext`, `FakeCanvasNavigation`, `InMemoryToolOptionStore`.
- **0009** `Core/Tools/PaintbrushTool.swift`: every stroke commits one history step named "Paintbrush" with icon `.paintbrush` through `ToolContext.commitHistory(_:)`, drawing live through `ToolContext.updateImage(_:)`; options `tool.paintbrush.width`, antialiasing, etc.

This spec uses those names as they are. It adds no parallel stack type and no second source of truth for the current position.

### Paint.NET behavior this mirrors

From the Paint.NET [History Window](https://www.getpaint.net/doc/latest/HistoryWindow.html) page:

- The History window lists every action taken on the image, each with the icon of the tool/command that produced it and its name.
- "If an action has been undone, it appears in the list with a grey background." Undone actions can be restored with Redo.
- Clicking an entry rewinds the image to that point. **Clicking the same entry repeatedly toggles between it and the previous entry**, a quick way to see what that action changed.
- Taking a new action after undoing replaces and permanently discards all undone (greyed) steps.
- The window has **Undo** and **Redo** buttons at its foot. Undo undoes the last action listed, and Redo redoes the last undone action.
- Paint.NET 3.x also had "Rewind" (undo all) and "Fast forward" (redo all) buttons. Paint.NET 4.0 and later removed them; the current documentation doesn't list them, and clicking the first or last row does the same job. **PaintDotMac follows current Paint.NET: Undo and Redo buttons only, with no Rewind or Fast Forward buttons.** (Forum note on the removal: https://forums.getpaint.net/topic/29172-where-are-the-undo-and-redo-all-buttons/.)
- The first entry is the base state ("Open Image" for an opened file, "New Image" for a new one). It can't be undone past.

## User story

As a PaintDotMac user, I open the History panel (⌥⌘2) and see every step of the front document: "Open Image" followed by one "Paintbrush" row per stroke, each with an icon. I click an earlier row and the canvas instantly shows the image as it was then. The later rows turn grey, and Edit > Undo/Redo update to match. If I click the same row again, I step back one more state. If I then paint, the grey rows disappear. Switching to another document window switches the list to that document's history.

## Scope & changes

### Core (pure, unit-tested): `PaintDotMac/Core/History/HistoryListModel.swift` (new)

Imports only `Foundation`. The file holds the mapping from history state to panel rows and the click and button decisions, so that the SwiftUI view only renders and forwards.

```swift
public enum HistoryRowState: String, Sendable, Equatable {
    case done      // applied, before the current step
    case current   // the step the canvas is showing now (last applied)
    case undone    // after the current step: shown greyed, discarded by the next new action
}

public struct HistoryRow: Identifiable, Sendable, Equatable {
    public let id: HistoryStep.ID    // 0008's step ID: stable across drops and new steps
    public let index: Int            // position in the current list; 0 = base step
    public let name: String          // HistoryItem.name, e.g. "Paintbrush"
    public let icon: HistoryIcon
    public let state: HistoryRowState
    public var isUndone: Bool { state == .undone }
    public var isCurrent: Bool { state == .current }
    /// Accessibility value used by VoiceOver and UI tests: "current", "done" or "undone".
    public var accessibilityValue: String { state.rawValue }
}

public struct HistoryListModel: Sendable, Equatable {
    public let rows: [HistoryRow]
    public let currentIndex: Int

    /// Pure mapping. `steps` is the full list including the base step at 0; `currentIndex` in 0..<steps.count.
    public init(steps: [(id: HistoryStep.ID, name: String, icon: HistoryIcon)], currentIndex: Int)
    /// Convenience over 0008's HistoryStack: `steps.map { ($0.id, $0.name, $0.icon) }` and `currentIndex`; no mutation.
    public init(stack: HistoryStack)
    /// Empty model: no active document.
    public static let empty: HistoryListModel

    public var canUndo: Bool   // currentIndex > 0
    public var canRedo: Bool   // currentIndex < rows.count - 1

    /// The index to jump to when the user clicks the row at `index` (Paint.NET toggle rule):
    /// - clicking a row other than the current one → that row's index;
    /// - clicking the current row when it isn't the base step → currentIndex - 1 (step back once);
    /// - clicking the current base row (index 0) → nil (no-op);
    /// - an out-of-range index → nil (no-op, no crash).
    public func jumpTarget(forClickedRow index: Int) -> Int?
}
```

- Row state rule: `index < currentIndex` → `.done`; `index == currentIndex` → `.current`; `index > currentIndex` → `.undone`. Exactly one row is `.current` whenever the list isn't empty. The base step is always row 0 and is never `.undone`.
- Row identity is 0008's `HistoryStep.ID`, so SwiftUI keeps row identity when the oldest steps are dropped (H-5) and the indices shift. This spec makes no change to `HistoryStack`.
- Clamping: `init(steps:currentIndex:)` with an out-of-range `currentIndex` clamps it to `0...steps.count-1`; with empty `steps` it produces `.empty` (no rows, `canUndo == false`, `canRedo == false`). This should never happen with a valid stack, but the panel must not crash on it.

### Core: `HistoryIcon` → SF Symbol name: `PaintDotMac/Core/History/HistoryIcon+Symbol.swift` (new)

- `extension HistoryIcon { public var symbolName: String }`, an **exhaustive `switch` with no `default`**, so every case a later spec adds to `HistoryIcon` fails to compile until it gets a symbol. The names are plain strings, so Core doesn't import AppKit. Mapping for all of 0008's cases:

  | Case | Symbol | Case | Symbol |
  |---|---|---|---|
  | `openImage` | `photo` | `newImage` | `doc.badge.plus` |
  | `rectangleSelect` | `rectangle.dashed` | `lassoSelect` | `lasso` |
  | `ellipseSelect` | `circle.dashed` | `magicWand` | `wand.and.stars` |
  | `moveSelectedPixels` | `arrow.up.and.down.and.arrow.left.and.right` | `moveSelection` | `selection.pin.in.out` |
  | `paintBucket` | `drop.fill` | `gradient` | `circle.lefthalf.filled` |
  | `paintbrush` | `paintbrush.pointed` | `eraser` | `eraser` |
  | `pencil` | `pencil` | `cloneStamp` | `seal` |
  | `recolor` | `paintpalette` | `text` | `textformat` |
  | `lineCurve` | `line.diagonal` | `shapes` | `square.on.circle` |
  | `selectAll` | `square.dashed.inset.filled` | `deselect` | `square.dashed` |
  | `invertSelection` | `arrow.left.arrow.right.square` | `eraseSelection` | `delete.left` |
  | `fillSelection` | `square.fill` | `cut` | `scissors` |
  | `paste` | `doc.on.clipboard` | `cropToSelection` | `crop` |
  | `resizeImage` | `arrow.up.left.and.arrow.down.right` | `resizeCanvas` | `aspectratio` |
  | `flipRotate` | `rotate.right` | `layerAdd` | `plus.square.on.square` |
  | `layerDelete` | `minus.square` | `layerDuplicate` | `square.on.square` |
  | `layerMerge` | `square.stack.3d.down.right` | `layerMove` | `arrow.up.arrow.down` |
  | `layerProperties` | `slider.horizontal.3` | `flatten` | `square.stack` |
  | `importLayer` | `square.and.arrow.down` | `adjustment` | `slider.vertical.3` |
  | `effect` | `sparkles` | `generic` | `clock.arrow.circlepath` |

  The tool cases use the same symbols as 0006's `ToolRegistry` table, so a history row and its tool button look alike. A symbol that turns out not to exist on macOS 15 may be replaced with a similar one; `HistoryIconSymbolTests` catches it. Later specs that add a `HistoryIcon` case add its row here.

### Platform glue: `PaintDotMac/UI/HistoryPanelModel.swift` (new)

- `@MainActor @Observable final class HistoryPanelModel` holds the current `HistoryListModel` for the **active document** and forwards commands. One instance, owned by `AppModel` (0006), shared by the single app-wide History panel.
- `func bind(to bridge: UndoBridge?)` holds the bridge **weakly** and recomputes `model`. It follows the active document the way 0006 intends for document panels: it observes `AppModel.activeSessionGeneration` (via `withObservationTracking`, re-armed after each change) and calls `bind(to: AppModel.shared.activeSession?.undoBridge)`. 0006 sets the active session on `windowDidBecomeMain` (including tab switches) and clears it when that window closes. With no bridge it shows `HistoryListModel.empty`, and the Undo/Redo buttons are disabled. Tests call `bind(to:)` directly.
- It refreshes after every history change of the bound document — new step (which also discards undone steps), undo, redo, jump, budget drop (H-5), reset — by observing the bound bridge's `historyRevision` (`withObservationTracking`, re-armed after each change) and rebuilding `model = HistoryListModel(stack: bridge.history)`. 0008 bumps `historyRevision` once per operation, after both the stack and `NSUndoManager` are updated, and once for a whole multi-step jump, so the panel refreshes once per user action. `private(set) var refreshCount: Int` (+1 per rebuild) lets tests count refreshes.
- `func clickRow(_ index: Int)`: computes `model.jumpTarget(forClickedRow:)` and, if non-nil, calls `bridge.jump(to:)` (0008).
- `func undo()` / `func redo()`: call `bridge.undo()` / `bridge.redo()` (0008), which go through `undoManager` exactly like Edit > Undo (⌘Z) and Edit > Redo (⇧⌘Z), so the menu, the panel, and the canvas cannot diverge (H-3). No bridge → no-op.
- **Jumping goes through `UndoBridge.jump(to:)`, never straight to `HistoryStack`.** 0008's `jump` replays `undoManager.undo()`/`redo()` (so `NSUndoManager`'s own stacks and the Edit menu titles stay exact) and first calls `prepareForNavigation`, which commits any pending tool edit exactly as Edit > Undo does (for the Paintbrush there is no pending state between strokes; the shape and text tools later commit through the same path).
- The canvas redraws after a jump through 0008's `onStateChange` (one merged change per jump); the panel does not touch pixels.

### Platform glue: `PaintDotMac/UI/HistoryPanelView.swift` (new)

- A SwiftUI view hosted by `PanelController` in the `PanelKind.history` panel (replacing 0006's `PanelPlaceholderView`). Panel title: **"History"**. Update 0006's `PanelsUITests.testPlaceholderText` and `PanelControllerTests.placeholderIdentifiers` to drop `historyPanel` (only Layers keeps its placeholder).
- Body: a `List` (or `ScrollView` + `LazyVStack`) of `HistoryRow`s, then a footer bar with two icon buttons, **Undo** (`arrow.uturn.backward`) and **Redo** (`arrow.uturn.forward`), with tooltips "Undo" / "Redo", disabled by `canUndo` / `canRedo`. There are no Rewind or Fast Forward buttons (see Context).
- Each row: the icon (`Image(systemName: row.icon.symbolName)`) at 16 pt, then the name. Styling:
  - `.done`: normal text and icon.
  - `.current`: selection highlight (accent background), like the selected row in Paint.NET.
  - `.undone`: greyed. Secondary text and icon colors on a grey background (`Color.secondary.opacity(0.15)` or similar), so they read as "undone" in both light and dark mode (APP-7).
- A single click on a row calls `HistoryPanelModel.clickRow(row.index)`. The whole row is the hit target. Selection is driven by the model (`currentIndex`), not by SwiftUI's own `List` selection, so a click that results in a no-op leaves the highlight unchanged.
- Whenever the current index changes, the list scrolls the current row into view (`ScrollViewReader.scrollTo(row.id)`).
- Accessibility (NF-7 and UI tests):
  - Panel content root: identifier `historyPanel`.
  - List: identifier `historyList`, label "History".
  - Each row: identifier `historyRow.<index>` (`index` = `row.index`, 0 = base step), label = `row.name`, value = `row.accessibilityValue` (`"current"`, `"done"` or `"undone"`), `.isSelected` trait on the current row, and a default accessibility action that calls `clickRow` (so VoiceOver can jump).
  - Footer buttons: identifiers `history.undo` and `history.redo`, labels "Undo" and "Redo".
- Panel visibility and position are owned by 0006 (⌥⌘2, frame autosave). No change here.

### Project

- New files: `Core/History/HistoryListModel.swift`, `Core/History/HistoryIcon+Symbol.swift`, `UI/HistoryPanelModel.swift`, `UI/HistoryPanelView.swift`, `PaintDotMacTests/History/Support/BridgeToolContext.swift`, `PaintDotMacTests/History/HistoryListModelTests.swift`, `PaintDotMacTests/History/HistoryIconSymbolTests.swift`, `PaintDotMacTests/History/HistoryPanelIntegrationTests.swift`, `PaintDotMacUITests/HistoryPanelUITests.swift`. Modified: `App/PanelController.swift` (host the view), `App/AppModel.swift` (own `historyPanel: HistoryPanelModel` and start its active-session observation). Run `xcodegen generate`.
- No PRD change. The Undo/Redo-only button choice mirrors current Paint.NET and adds no new product behavior beyond H-1/H-2.

## Acceptance criteria

- [ ] The History panel lists every step of the active document, base step first ("Open Image" for an opened file, "New Image" for a new one), each with its name and an icon (H-1). → `HistoryListModelTests.rowsMirrorStepsInOrder`, `HistoryPanelIntegrationTests.strokesAppendPaintbrushRows`, `HistoryPanelUITests.testStrokesAppearAsRows`
- [ ] Every `HistoryIcon` case maps to an SF Symbol that exists on macOS 15, and tool cases use the Tools panel's symbols. → `HistoryIconSymbolTests.everyCaseHasAnExistingSymbol`, `.toolCasesMatchToolsPanel`
- [ ] Rows before the current step are `done`, the current step is `current` (highlighted), and later steps are `undone` (greyed) (H-2). → `HistoryListModelTests.rowStatesAroundCurrentIndex`, `HistoryPanelUITests.testClickEarlierRowGreysLaterRows`
- [ ] Clicking a row jumps the document to that state. The canvas pixels equal the pixels saved at that state. → `HistoryPanelIntegrationTests.jumpRestoresExactTiles`, `HistoryPanelUITests.testClickEarlierRowRestoresPixels`
- [ ] Clicking the current row again steps back one state (Paint.NET toggle). Clicking the current base row does nothing. → `HistoryListModelTests.clickCurrentRowStepsBackOnce`, `HistoryListModelTests.clickCurrentBaseRowIsNoOp`, `HistoryPanelUITests.testClickCurrentRowTogglesToPrevious`
- [ ] After a jump, `NSUndoManager` and the Edit menu agree with the panel: "Undo <name of current step>" / "Redo <name of first undone step>", enabled exactly when `canUndo` / `canRedo` (H-3). → `HistoryPanelIntegrationTests.jumpKeepsUndoManagerInSync`, `HistoryPanelUITests.testEditMenuFollowsPanelJump`
- [ ] Edit > Undo / Redo (⌘Z / ⇧⌘Z) update the panel's row states immediately, with exactly one refresh per undo, redo, or jump. → `HistoryPanelIntegrationTests.undoRedoRefreshPanel`, `HistoryPanelUITests.testKeyboardUndoUpdatesRows`
- [ ] The panel's Undo and Redo buttons behave like Edit > Undo/Redo and are disabled at the ends of the history. → `HistoryListModelTests.canUndoCanRedoAtEnds`, `HistoryPanelUITests.testFooterButtons`
- [ ] A new action after a jump discards the greyed steps. They disappear from the list and can't be redone. → `HistoryPanelIntegrationTests.newStrokeDiscardsUndoneRows`, `HistoryPanelUITests.testNewStrokeDiscardsGreyedRows`
- [ ] When the undo budget drops the oldest steps (H-5), they disappear from the panel. The base step stays at row 0, indices are re-based, row IDs of the surviving steps don't change, and the current row stays on the same step. → `HistoryPanelIntegrationTests.budgetDropRemovesOldestRows`, `HistoryListModelTests.rowIDsAreStableAcrossDrop`
- [ ] The panel follows the active document. It shows the front document's history, switches when another document window becomes main, and shows an empty list with disabled buttons when no document is open. → `HistoryPanelUITests.testPanelFollowsActiveDocument`, `HistoryPanelIntegrationTests.emptyModelWhenNoDocument`
- [ ] Out-of-range click indices and an out-of-range current index never crash. → `HistoryListModelTests.outOfRangeClickIsNil`, `HistoryListModelTests.currentIndexIsClamped`
- [ ] Rows expose accessibility identifiers `historyRow.<index>`, labels = step names, and values `current`/`done`/`undone`. The list is `historyList` and the panel root is `historyPanel` (NF-7). → all `HistoryPanelUITests` query by these identifiers
- [ ] The app launches, opens a PNG and a JPEG, and stays up with no crash report (quality gate launch smoke).

## Edge cases

- **Only the base step:** one row ("Open Image" / "New Image") that is `current`. Undo is disabled, Redo is disabled, and clicking the row is a no-op.
- **Current = base after jumping to row 0:** all other rows are `undone`. The canvas equals the opened file exactly. Edit > Undo is disabled and shows the plain title "Undo".
- **Current = last row:** no rows greyed, Redo disabled.
- **Clicking an undone row:** redoes forward to it (multi-step redo in one jump), with one panel refresh.
- **Clicking the current row repeatedly:** alternates between the current index and the one before only if the user clicks the *originally clicked* row each time. The pure rule (`current → current − 1`; any other row → that row) produces exactly Paint.NET's toggle when the same row is clicked repeatedly. Test it explicitly over 4 clicks.
- **Jump while a stroke is in progress:** can't happen with the mouse (the stroke owns the mouse until mouseUp). Undo/Redo shortcuts during a drag are handled by 0008/0009 and are not changed here.
- **Budget drop while some steps are undone:** dropping removes only the oldest *done* steps after the base (0008's rule). Rows are re-based, the greyed rows stay greyed, and IDs are stable.
- **Budget drop that would drop the current step:** not possible by 0008's rule (only steps older than current are dropped). The model still clamps defensively.
- **Document closed while the panel shows it:** 0006 clears or moves the active session, so the model rebinds to the next main document or to `.empty`. It holds the bridge weakly, so a closed document is never kept alive.
- **Very long histories (thousands of steps):** the list is lazy. Building `HistoryListModel` is O(n) with no per-row pixel work.
- **Dark mode / light mode:** greyed and current styles are legible in both (manual check).
- **Window tabs:** switching tabs in a tabbed document window changes the main window, and the panel follows (same notification).

## Test plan

- **Unit tests** (`PaintDotMacTests/History/HistoryListModelTests.swift`, Swift Testing; expected values by hand):
  - `rowsMirrorStepsInOrder`: steps `[(0,"Open Image",.openImage),(1,"Paintbrush",.paintbrush),(2,"Paintbrush",.paintbrush)]`, current 2 → 3 rows, indices `[0,1,2]`, names `["Open Image","Paintbrush","Paintbrush"]`, icons `[.openImage,.paintbrush,.paintbrush]`, ids `[0,1,2]`.
  - `rowStatesAroundCurrentIndex`: 5 steps, current 2 → states `[done, done, current, undone, undone]`. Current 0 → `[current, undone×4]`. Current 4 → `[done×4, current]`. In every case exactly one `current`, and `accessibilityValue` equals the raw strings `"done"`/`"current"`/`"undone"`.
  - `canUndoCanRedoAtEnds`: 3 steps. Current 0 → `(false, true)`. Current 1 → `(true, true)`. Current 2 → `(true, false)`. A single base step → `(false, false)`. `.empty` → `(false, false)`, with zero rows.
  - `clickOtherRowJumpsToIt`: 5 steps, current 2. Clicking 0 → 0, 3 → 3, 4 → 4, 1 → 1.
  - `clickCurrentRowStepsBackOnce`: 5 steps, current 3. Clicking 3 → 2.
  - `clickCurrentBaseRowIsNoOp`: current 0, clicking 0 → `nil`.
  - `toggleSequenceMatchesPaintNET`: start at current 4. Clicking row 3 four times, applying each target as the new current, gives currents `3, 2, 3, 2`.
  - `outOfRangeClickIsNil`: clicking −1 and `rows.count` → `nil`.
  - `currentIndexIsClamped`: 3 steps with current 7 → current 2. With current −1 → current 0. Empty steps → equals `.empty`.
  - `rowIDsAreStableAcrossDrop`: model A from steps with ids `[0,5,6,7]`, current 3. Model B after dropping id 5: steps `[0,6,7]`, current 2. Row with id 7 is index 3 in A and index 2 in B, `current` in both. The id-6 row is `done` in both.
  - `initFromStackMatchesManualInit`: `var stack = HistoryStack(base: .openImage)`, `commit` two 0008 `FakeHistoryItem`s named "A" (icon `.paintbrush`) and "B" (icon `.eraser`), `stack.jump(to: 1, &state)` → `HistoryListModel(stack:)` == `HistoryListModel(steps: [(0,"Open Image",.openImage),(1,"A",.paintbrush),(2,"B",.eraser)], currentIndex: 1)`.
- **Unit tests** (`PaintDotMacTests/History/HistoryIconSymbolTests.swift`):
  - `everyCaseHasAnExistingSymbol`: for every `HistoryIcon.allCases` (0008 makes it `CaseIterable`), `NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: nil)` is non-nil. The test target may import AppKit; Core does not. `HistoryIcon.openImage.symbolName == "photo"`, `.newImage == "doc.badge.plus"`, `.paintbrush == "paintbrush.pointed"` (literal checks against the table).
  - `toolCasesMatchToolsPanel`: for every case whose raw value is a `ToolID` raw value, `icon.symbolName == ToolRegistry.descriptor(for: ToolID(rawValue: icon.rawValue)!).symbolName` (force unwrap allowed in tests).
- **Round-trip / property test** (`HistoryListModelTests.randomJumpsKeepInvariants`, seeded with `SeededRandom` from 0002, seed printed on failure): over 500 random `(count 1…50, current, clickIndex)` triples, check that there is exactly one `current` row, that states follow the index rule, that `jumpTarget` is nil or in range, and that `jumpTarget` is never equal to the current index.
- **Test support** (`PaintDotMacTests/History/Support/BridgeToolContext.swift`, new): `@MainActor final class BridgeToolContext: ToolContext` backed by an `UndoBridge`: `image` → `bridge.state.image`, `updateImage` → `bridge.updateLiveState`, `commitHistory`/`performHistory` → `bridge.commit`/`perform`, `options` = `InMemoryToolOptionStore`, `navigation` = `FakeCanvasNavigation` (0006), settable `colors` (0007), `paintClipMask` nil (0009), and recording no-ops for overlay/cursor/tool switches. A helper `stroke(y:)` sends `mouseDown` at canvas (100, y), `mouseDragged` to (290, y), `mouseUp` at (290, y) to a `PaintbrushTool` with primary-button events.
- **Integration tests** (`PaintDotMacTests/History/HistoryPanelIntegrationTests.swift`, headless, on `@MainActor`: a real `UndoBridge(state: DocumentState(image: .blank(size: 300×300, fill: .white)), base: .openImage, budgetBytes: default, undoManager: m)` with `m.groupsByEvent = false`, a `HistoryPanelModel` bound with `bind(to:)`, strokes through `PaintbrushTool` and `BridgeToolContext`; options `tool.paintbrush.width` 10 and antialiasing off, primary color opaque black):
  - `strokesAppendPaintbrushRows`: 3 horizontal strokes at y = 50, 150, 250 (each crossing the tile boundary at x = 256) → model rows `["Open Image","Paintbrush","Paintbrush","Paintbrush"]`, last row `current`.
  - `jumpRestoresExactTiles`: snapshot the layer's pixels (full RGBA buffer) after each stroke: S0 (base), S1, S2, S3. `HistoryPanelModel.clickRow(1)` → pixels == S1 byte for byte. `clickRow(0)` → == S0 (all `FFFFFFFF`). `clickRow(3)` → == S3. `clickRow(2)` → == S2. Row states after each jump follow the rule.
  - `jumpKeepsUndoManagerInSync`: after `clickRow(1)` with 4 rows, `undoManager.canUndo == true`, `canRedo == true`, `undoMenuItemTitle == "Undo Paintbrush"`, `redoMenuItemTitle == "Redo Paintbrush"`. After `clickRow(0)`: `canUndo == false`, `canRedo == true`. Then `undoManager.redo()` ×3 → current 3 and pixels == S3 (the redo stack built by the jump is exact).
  - `undoRedoRefreshPanel`: `undoManager.undo()` → panel `currentIndex` 2 and row 3 `undone`. `redo()` → back to 3. `refreshCount` increases by exactly 1 per undo and per redo, and by exactly 1 for `clickRow(0)` (a 3-step jump); `bridge.historyRevision` increases by the same amounts.
  - `newStrokeDiscardsUndoneRows`: after `clickRow(1)`, a new stroke at y = 200 → rows `["Open Image","Paintbrush","Paintbrush"]` (3 rows), none `undone`, last `current`, `undoManager.canRedo == false`. Pixels equal S1 plus the new stroke: rows y = 150 and y = 250 are white again, and row y = 200 is black at x = 100.
  - `budgetDropRemovesOldestRows`: a bridge with `budgetBytes: 2_500_000`. Strokes at y = 40, 80, 120, 160 (each from x = 100 to 290, so each touches exactly tiles (0,0) and (1,0)) cost 4 × 262,144 + 1,024 = 1,049,600 accounted bytes each (0008's rule), so two fit (2,099,200) and three don't (3,148,800). After 4 strokes, the rows are `["Open Image","Paintbrush","Paintbrush"]`, the ids are `[0, id3, id4]` (the ids strokes 3 and 4 got, recorded from `bridge.history.steps` right after each stroke), the current row is the last row, and clicking row 1 then row 0 never crashes. Row 0 shows "Open Image". Its pixels follow 0008's base-after-drop behavior, which 0008 asserts.
  - `emptyModelWhenNoDocument`: `HistoryPanelModel` after `bind(to: nil)` → `.empty`, and `undo()`/`redo()`/`clickRow(0)` are no-ops that don't crash. `bridgeIsHeldWeakly`: bind to a bridge, drop the last strong reference → the model's bridge is nil after the next refresh and the model is `.empty`.
- **UI tests** (`PaintDotMacUITests/HistoryPanelUITests.swift`, XCUITest, via `UITestApp` from 0001). The fixture is a 200×200 opaque white PNG generated in a temp dir, opened with `-UITestOpen`, with `-UITestResetDefaults` and `-ApplePersistenceIgnoreState YES`. Show the panel with ⌥⌘2 if it's hidden. Select the Paintbrush (`tool.paintbrush`, or key B). Strokes are made with the `UITestApp` canvas-drag helper inside the `canvas` element. **Pixel oracle: ⌘S (PNG saves in place in its own format, single layer, no dialog), then decode the fixture file in the test with `CGImageSource` and compare full RGBA buffers.** That way no coordinates need predicting:
  - `testStrokesAppearAsRows`: 3 strokes at different heights → `historyRow.0` label "Open Image", `historyRow.1`–`.3` label "Paintbrush", `historyRow.3` value "current", and no `historyRow.4`.
  - `testClickEarlierRowRestoresPixels`: after each stroke, ⌘S and read the buffer → P1, P2, P3 (assert P1 ≠ P2 ≠ P3 and P1 ≠ all-white). Click `historyRow.1`, ⌘S → buffer == P1. Click `historyRow.0`, ⌘S → all pixels `FFFFFFFF`. Click `historyRow.3`, ⌘S → == P3.
  - `testClickEarlierRowGreysLaterRows`: after the click on `historyRow.1`, the values are row 0 "done", row 1 "current", rows 2–3 "undone".
  - `testClickCurrentRowTogglesToPrevious`: with row 3 current, click `historyRow.3` → row 2 "current", row 3 "undone". Click `historyRow.3` again → row 3 "current".
  - `testEditMenuFollowsPanelJump`: after clicking `historyRow.1`, the Edit menu items "Undo Paintbrush" and "Redo Paintbrush" exist and are enabled. After clicking `historyRow.0`, Undo is disabled.
  - `testKeyboardUndoUpdatesRows`: ⌘Z → row 3 "undone", row 2 "current". ⇧⌘Z → row 3 "current".
  - `testFooterButtons`: `history.undo` click → row 2 "current". `history.redo` → row 3 "current", and `history.redo` is disabled. Click `historyRow.0` → `history.undo` disabled.
  - `testNewStrokeDiscardsGreyedRows`: click `historyRow.1`, paint one more stroke → exactly 3 rows (`historyRow.3` doesn't exist), `historyRow.2` label "Paintbrush" value "current", and no row has value "undone". ⌘S → buffer ≠ P2 and ≠ P1. The Edit menu's Redo is disabled.
  - `testPanelFollowsActiveDocument`: with 3 strokes in document A, press ⌘N, then Return (New Image dialog defaults, 0005) → the panel shows exactly one row, `historyRow.0` "New Image" value "current", and `history.undo` and `history.redo` are disabled. Bring A back to front (Window menu item for A, or ⌘\`) → 4 rows again, with row 3 "current". Bring the new document to front and close it with ⌘W (no prompt: it is untouched, APP-9) → the panel shows A's 4 rows.
- **Performance:** not applicable. The panel doesn't affect NF-1 to NF-4. Jumping replays 0008's tile diffs, whose cost 0008 measures.
- **Quality gate:** `.agents/skills/spec-implementer/scripts/quality-gate.sh` is green: clean build with no warnings, every test passes with none skipped, UI tests ran, launch smoke passes. No sanitizer dependency.
- **Manual verification** (look and feel can't be asserted automatically):
  1. Open a photo, paint 5 strokes, and open the History panel (⌥⌘2). Each row shows the paintbrush icon and "Paintbrush", and the first shows the photo icon and "Open Image".
  2. Click row 2. The canvas updates immediately, rows 3–5 have a grey background with dimmed text, and row 2 is highlighted. Check in **light and dark mode** that greyed and current rows are clearly distinguishable.
  3. Click row 2 repeatedly. The canvas flips between states 1 and 2, showing what that stroke changed.
  4. With 60+ strokes, use ⌘Z repeatedly. The list keeps the current row scrolled into view.
  5. Turn VoiceOver on and navigate the list. Each row reads its name and "current"/"done"/"undone", and VO-Space on a row jumps to it.
  6. Move and resize the History panel, quit, and relaunch. The frame is restored (0006 autosave; regression check only).

## Out of scope

- History storage, tile diffs, the budget and dropping, and the base-step names: 0008. The configurable budget in Settings: 0046 (APP-8, NF-4).
- Disk spillover of old steps: H-4, 0062.
- Panel window management, docking, and the Window menu toggles: 0006 (APP-2) and 0052 (APP-3).
- Icons for step kinds that later specs add (selection, layers, effects, and so on): each later spec adds its `HistoryIcon` case and symbol to the exhaustive switch.
- Rewind / Fast Forward buttons (removed in Paint.NET 4+), history thumbnails, and saving history to a file: not planned.
