import AppKit
import Foundation
import Testing

@testable import PaintDotMac

/// The bridge with a fresh Foundation `UndoManager` (`groupsByEvent = false`), real
/// Foundation classes only — no windows (spec 0008 *Document glue tests*).
@MainActor
final class BridgeFixture {
    let before: LayeredImage
    let bridge: UndoBridge
    var changes: [HistoryChange] = []
    var editedFlags: [Bool] = []
    var events: [String] = []
    private var nextPaintX = 5

    init(budget: Int = 1_000_000_000, groupsByEvent: Bool = false) {
        var surface = TiledSurface(size: PixelSize(width: 512, height: 512))
        surface.fill(.white)
        before = LayeredImage(surface: surface)
        // The production manager class: `undo()`/`redo()` fire `prepareForNavigation`
        // before the run, exactly like the app's menu ⌘Z / ⇧⌘Z path.
        let manager = NavigationUndoManager()
        manager.groupsByEvent = groupsByEvent
        bridge = UndoBridge(state: DocumentState(image: before), base: .openImage,
                            budgetBytes: budget, undoManager: manager)
        bridge.onStateChange = { [weak self] change in
            self?.changes.append(change)
            self?.events.append("state")
        }
        bridge.onEditedChange = { [weak self] isEdited in
            self?.editedFlags.append(isEdited)
            self?.events.append("edited")
        }
    }

    var undoManager: UndoManager { bridge.undoManager }

    func setPrepare(_ hook: @escaping @MainActor () -> Void) {
        bridge.prepareForNavigation = hook
    }

    /// Draws one 4×4 rect live and commits it as a "Paintbrush"-named step.
    @discardableResult
    func commitPaint(_ name: String, icon: HistoryIcon = .paintbrush) throws -> TileDiffHistoryItem {
        let x = nextPaintX
        nextPaintX += 16
        let imageBefore = bridge.state.image
        bridge.updateLiveState { state in
            fillRect(&state.image, layer: 0, rect: PixelRect(x: x, y: 5, width: 4, height: 4),
                     color: ColorRGBA8(red: UInt8(x), green: 1, blue: 1))
        }
        let diff = try TileDiff.between(before: imageBefore, after: bridge.state.image)
        let item = TileDiffHistoryItem(name: name, icon: icon, diff: diff)
        bridge.commit(item)
        return item
    }

    /// The before-state oracle of a freshly drawn (uncommitted) rect.
    func preparePaint(_ name: String) throws -> (TileDiffHistoryItem, LayeredImage) {
        let x = nextPaintX
        nextPaintX += 16
        let imageBefore = bridge.state.image
        bridge.updateLiveState { state in
            fillRect(&state.image, layer: 0, rect: PixelRect(x: x, y: 5, width: 4, height: 4),
                     color: ColorRGBA8(red: UInt8(x), green: 1, blue: 1))
        }
        let diff = try TileDiff.between(before: imageBefore, after: bridge.state.image)
        return (TileDiffHistoryItem(name: name, icon: .paintbrush, diff: diff), imageBefore)
    }
}

@MainActor
struct UndoBridgeTests {
    @Test func freshBridgeHasNothingToUndo() throws {
        let fixture = BridgeFixture()
        #expect(fixture.bridge.history.canUndo == false)
        #expect(fixture.undoManager.canUndo == false)
        #expect(fixture.undoManager.canRedo == false)
        #expect(fixture.undoManager.undoMenuItemTitle == "Undo")
        #expect(fixture.undoManager.redoMenuItemTitle == "Redo")
        #expect(fixture.bridge.historyRevision == 0)
    }

    @Test func commitNamesUndo() throws {
        let fixture = BridgeFixture()
        try fixture.commitPaint("Paintbrush")
        #expect(fixture.undoManager.canUndo)
        #expect(fixture.undoManager.undoMenuItemTitle == "Undo Paintbrush")
        #expect(fixture.undoManager.undoActionName == "Paintbrush")
    }

    @Test func menuUndoRedoSyncsStack() throws {
        // ⌘Z on the manager must move the stack (H-3: the menu and the stack agree).
        let fixture = BridgeFixture()
        try fixture.commitPaint("Eraser", icon: .eraser)
        fixture.undoManager.undo()
        #expect(fixture.bridge.history.currentIndex == 0)
        fixture.undoManager.redo()
        #expect(fixture.bridge.history.currentIndex == 1)
        #expect(fixture.undoManager.undoMenuItemTitle == "Undo Eraser")
    }

    @Test func menuUndoRevertsState() throws {
        let fixture = BridgeFixture()
        let (item, beforeImage) = try fixture.preparePaint("Paintbrush")
        fixture.bridge.commit(item)
        let afterImage = fixture.bridge.state.image
        fixture.changes.removeAll()
        fixture.editedFlags.removeAll()

        fixture.undoManager.undo()
        assertMatches(fixture.bridge.state.image, ReferenceCanvas(image: beforeImage),
                      "undo restores the before pixels")
        #expect(fixture.bridge.history.currentIndex == 0)
        #expect(fixture.undoManager.redoMenuItemTitle == "Redo Paintbrush")
        #expect(fixture.changes == [item.change])
        #expect(fixture.editedFlags == [false])  // back at the saved step

        fixture.changes.removeAll()
        fixture.editedFlags.removeAll()
        fixture.undoManager.redo()
        assertMatches(fixture.bridge.state.image, ReferenceCanvas(image: afterImage),
                      "redo restores the after pixels")
        #expect(fixture.editedFlags == [true])
        #expect(fixture.changes == [item.change])
    }

    @Test func commitAfterUndoClearsRedoInBoth() throws {
        let fixture = BridgeFixture()
        try fixture.commitPaint("A")
        fixture.undoManager.undo()
        #expect(fixture.bridge.history.canRedo && fixture.undoManager.canRedo)
        try fixture.commitPaint("B")
        #expect(fixture.bridge.history.canRedo == false)
        #expect(fixture.undoManager.canRedo == false)
    }

    @Test func jumpUsesUndoManager() throws {
        let fixture = BridgeFixture()
        for name in ["Step 1", "Step 2", "Step 3", "Step 4"] {
            try fixture.commitPaint(name)
        }
        let final = fixture.bridge.state.image

        fixture.bridge.jump(to: 1)
        #expect(fixture.bridge.history.currentIndex == 1)
        #expect(fixture.undoManager.undoMenuItemTitle == "Undo Step 1")
        #expect(fixture.undoManager.redoMenuItemTitle == "Redo Step 2")

        fixture.bridge.jump(to: 4)
        #expect(fixture.bridge.history.currentIndex == 4)
        assertMatches(fixture.bridge.state.image, ReferenceCanvas(image: final),
                      "jumping back restores the final pixels")
        #expect(fixture.undoManager.canRedo == false)

        // Out of range and no-op jumps change nothing.
        fixture.bridge.jump(to: -1)
        fixture.bridge.jump(to: 9)
        fixture.bridge.jump(to: 4)
        #expect(fixture.bridge.history.currentIndex == 4)
    }

    @Test func budgetDropRemovesOldestActions() throws {
        // Budget fits exactly one 525,312-byte step → the second commit folds the first.
        let fixture = BridgeFixture(budget: 525_312)
        try fixture.commitPaint("Step 1")
        try fixture.commitPaint("Step 2")
        #expect(fixture.bridge.history.steps.map(\.name) == ["Open Image", "Step 2"])

        // The manager mirrors the stack: the dropped step is unreachable and never titled.
        #expect(fixture.undoManager.undoActionName == "Step 2")
        #expect(fixture.undoManager.canUndo == fixture.bridge.history.canUndo)
        fixture.undoManager.undo()
        #expect(fixture.bridge.history.currentIndex == 0)
        #expect(fixture.undoManager.canUndo == false,
                "no leftover action may undo past the folded base")
        #expect(fixture.undoManager.canRedo == fixture.bridge.history.canRedo)
    }

    @Test func noOpItemRegistersNothing() throws {
        let fixture = BridgeFixture()
        let revision = fixture.bridge.historyRevision
        let empty = try TileDiff.between(before: fixture.bridge.state.image,
                                         after: fixture.bridge.state.image)
        fixture.bridge.commit(TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush,
                                                  diff: empty))
        fixture.bridge.perform(TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush,
                                                   diff: empty))
        #expect(fixture.undoManager.canUndo == false)
        #expect(fixture.bridge.history.steps.count == 1)
        #expect(fixture.changes.isEmpty)
        #expect(fixture.editedFlags.isEmpty)
        #expect(fixture.bridge.historyRevision == revision)
    }

    @Test func prepareForNavigationRunsFirst() throws {
        let fixture = BridgeFixture()
        fixture.setPrepare { fixture.events.append("prepare") }
        try fixture.commitPaint("Step 1")
        fixture.events.removeAll()

        fixture.undoManager.undo()
        #expect(fixture.events.first == "prepare",
                "the hook runs before the state changes: \(fixture.events)")
        #expect(fixture.events.contains("state"))
        fixture.events.removeAll()

        fixture.undoManager.redo()
        #expect(fixture.events.first == "prepare")
        fixture.events.removeAll()

        // A 3-step jump calls it exactly once, before the first step.
        try fixture.commitPaint("Step 2")
        try fixture.commitPaint("Step 3")
        try fixture.commitPaint("Step 4")
        fixture.events.removeAll()
        fixture.bridge.jump(to: 1)  // three undos
        let prepares = fixture.events.filter { $0 == "prepare" }
        #expect(prepares.count == 1, "jump calls the hook once: \(fixture.events)")
        #expect(fixture.events.first == "prepare")
    }

    @Test func pendingEditCommittedByUndoKeepsMirrorIntact() throws {
        // Edge case "Undo while a tool has an uncommitted edit": `prepareForNavigation`
        // commits the pending stroke BEFORE the manager's run, and the run then undoes
        // exactly that step. Regression guard: a registration made DURING the run joins
        // the run's redo group and is never re-pushed on the undo side, so the manager
        // would report `canUndo == false` forever while the stack still holds steps.
        let fixture = BridgeFixture()
        try fixture.commitPaint("Step A")
        let afterA = fixture.bridge.state.image
        let (itemB, _) = try fixture.preparePaint("Step B")  // live-drawn, uncommitted
        let afterB = fixture.bridge.state.image
        var pending = true
        fixture.setPrepare {
            guard pending else { return }
            pending = false
            fixture.bridge.commit(itemB)  // what 0009's `Tool.commit` will do
        }

        fixture.undoManager.undo()  // menu ⌘Z path: manager.undo() directly
        #expect(fixture.bridge.history.currentIndex == 1,
                "the undone step is the one just committed")
        assertMatches(fixture.bridge.state.image, ReferenceCanvas(image: afterA),
                      "B is undone; back to the after-A state")
        #expect(fixture.undoManager.canUndo == fixture.bridge.history.canUndo,
                "mirror canUndo survives the hook commit")
        #expect(fixture.undoManager.canRedo == fixture.bridge.history.canRedo)
        #expect(fixture.undoManager.undoActionName == "Step A")
        #expect(fixture.undoManager.redoActionName == "Step B")
        #expect(fixture.undoManager.groupingLevel == 0, "no unbalanced undo group")

        // ⇧⌘Z re-applies B; a second ⌘Z undoes it; a third undoes A — the flow that
        // dead-ended permanently when commits landed inside the run.
        fixture.undoManager.redo()
        #expect(fixture.bridge.history.currentIndex == 2)
        assertMatches(fixture.bridge.state.image, ReferenceCanvas(image: afterB),
                      "redo restores B")
        fixture.undoManager.undo()
        #expect(fixture.bridge.history.currentIndex == 1)
        fixture.undoManager.undo()
        #expect(fixture.bridge.history.currentIndex == 0)
        #expect(fixture.undoManager.canUndo == false)
        #expect(fixture.undoManager.canUndo == fixture.bridge.history.canUndo)
        fixture.undoManager.undo()  // harmless at the base
        #expect(fixture.bridge.history.currentIndex == 0)
    }

    @Test func revisionBumpsOncePerOperation() throws {
        let fixture = BridgeFixture()
        var revision = fixture.bridge.historyRevision

        try fixture.commitPaint("Step 1")
        revision += 1
        #expect(fixture.bridge.historyRevision == revision, "recorded commit")

        let empty = try TileDiff.between(before: fixture.bridge.state.image,
                                         after: fixture.bridge.state.image)
        fixture.bridge.commit(TileDiffHistoryItem(name: "No-op", icon: .paintbrush, diff: empty))
        #expect(fixture.bridge.historyRevision == revision, "no-op never bumps")

        fixture.undoManager.undo()
        revision += 1
        #expect(fixture.bridge.historyRevision == revision, "single undo")
        fixture.bridge.redo()
        revision += 1
        #expect(fixture.bridge.historyRevision == revision, "single redo")

        try fixture.commitPaint("Step 2")
        try fixture.commitPaint("Step 3")
        try fixture.commitPaint("Step 4")
        revision += 3
        #expect(fixture.bridge.historyRevision == revision)
        #expect(fixture.bridge.history.currentIndex == 4)

        fixture.changes.removeAll()
        fixture.bridge.jump(to: 1)  // replays three undos
        revision += 1
        #expect(fixture.bridge.historyRevision == revision, "a moving jump bumps once")
        #expect(fixture.changes.count == 1, "one merged state change")
        let merged = try #require(fixture.changes.first)
        let layerID = try #require(fixture.bridge.state.image.layers.first?.id)
        #expect(merged == .pixels([layerID: [
            TileCoordinate(column: 0, row: 0),  // every 4×4 rect sits inside tile (0,0)
        ]]), "the merged change of the three undone steps")

        fixture.bridge.jump(to: fixture.bridge.history.currentIndex)
        #expect(fixture.bridge.historyRevision == revision, "a no-move jump does not bump")

        // Budget drops: bump only when steps actually drop.
        fixture.bridge.jump(to: 4)  // back at the top so steps become foldable
        revision += 1
        #expect(fixture.bridge.historyRevision == revision)
        fixture.bridge.setBudget(1_000_000_000)
        #expect(fixture.bridge.historyRevision == revision, "setBudget that drops nothing")
        fixture.bridge.setBudget(525_312)  // folds until only the current step survives
        revision += 1
        #expect(fixture.bridge.historyRevision == revision, "setBudget that drops bumps")

        fixture.bridge.markSaved(stepID: fixture.bridge.history.currentStepID)
        revision += 1
        #expect(fixture.bridge.historyRevision == revision, "markSaved")

        fixture.bridge.reset(state: DocumentState(image: fixture.before), base: .newImage)
        revision += 1
        #expect(fixture.bridge.historyRevision == revision, "reset")
    }

    @Test func resetClearsEverything() throws {
        let fixture = BridgeFixture()
        try fixture.commitPaint("Step 1")
        try fixture.commitPaint("Step 2")
        var fresh = TiledSurface(size: PixelSize(width: 256, height: 256))
        fresh.fill(.black)

        fixture.bridge.reset(state: DocumentState(image: LayeredImage(surface: fresh)),
                             base: .openImage)
        #expect(fixture.bridge.history.canUndo == false)
        #expect(fixture.bridge.history.canRedo == false)
        #expect(fixture.undoManager.canUndo == false)
        #expect(fixture.undoManager.canRedo == false)
        #expect(fixture.bridge.history.steps.map(\.name) == ["Open Image"])
        #expect(fixture.changes.contains(.structure), "reset refreshes the canvas")
        #expect(fixture.editedFlags.last == false, "a reset document is clean")
    }

    @Test func eventGroupedNaming() throws {
        // groupsByEvent == true (the app): the bridge registers inside the event group the
        // test opens, and the name lands on that group.
        let fixture = BridgeFixture(groupsByEvent: true)
        fixture.undoManager.beginUndoGrouping()
        try fixture.commitPaint("Paintbrush")
        fixture.undoManager.endUndoGrouping()
        #expect(fixture.undoManager.undoActionName == "Paintbrush")
        #expect(fixture.undoManager.canUndo)
    }

    @Test func markSavedSyncsEditedState() throws {
        let fixture = BridgeFixture()
        try fixture.commitPaint("Step 1")
        #expect(fixture.editedFlags.last == true)
        fixture.bridge.markSaved(stepID: fixture.bridge.history.currentStepID)
        #expect(fixture.editedFlags.last == false)
        // Undo past the saved step dirties again.
        fixture.undoManager.undo()
        #expect(fixture.editedFlags.last == true)
    }

    @Test func setBudgetFiresCallbacksOnlyWhenDropping() throws {
        let fixture = BridgeFixture()
        try fixture.commitPaint("Step 1")
        fixture.editedFlags.removeAll()
        fixture.bridge.setBudget(1_000_000_000)
        #expect(fixture.editedFlags.isEmpty)
        fixture.bridge.setBudget(0)  // current step stays; nothing droppable at index 1
        #expect(fixture.editedFlags.isEmpty)
    }

    // MARK: - Selection steps (spec 0013)

    @Test func selectionStepTogglesEdited() throws {
        let fixture = BridgeFixture()
        let item = try #require(SelectionCommand.selectAll.makeHistoryItem(for: fixture.bridge.state))
        fixture.bridge.perform(item)
        #expect(fixture.editedFlags.last == true, "a selection step marks the document edited")
        fixture.undoManager.undo()
        #expect(fixture.editedFlags.last == false, "undoing back to the saved step makes it clean")
    }

    @Test func selectionChangeCallback() throws {
        let fixture = BridgeFixture()
        let item = try #require(SelectionCommand.selectAll.makeHistoryItem(for: fixture.bridge.state))
        fixture.bridge.perform(item)
        #expect(fixture.changes.contains(.selection), "the canvas learns .selection (no tiles)")
        #expect(fixture.bridge.state.selection
                == Selection.all(canvasSize: fixture.bridge.state.image.size))
        fixture.undoManager.undo()
        #expect(fixture.bridge.state.selection == nil)
    }

    // MARK: - Pending-edit reasons (spec 0020)

    /// The hook sees `.historyNavigation` during undo, redo, and once per jump, `.save`
    /// during `prepareForSave()`, and `.command` when called directly and afterwards —
    /// the window controller forwards exactly this value to the dispatcher (item 9).
    @Test func pendingEditReason() throws {
        let fixture = BridgeFixture()
        var seen: [PendingEditReason] = []
        fixture.setPrepare { seen.append(fixture.bridge.pendingEditReason) }

        try fixture.commitPaint("A")
        try fixture.commitPaint("B")
        try fixture.commitPaint("C")

        #expect(seen.isEmpty, "recording steps never runs the hook")

        fixture.undoManager.undo()
        #expect(seen == [.historyNavigation], "undo → navigation")
        fixture.undoManager.redo()
        #expect(seen == [.historyNavigation, .historyNavigation], "redo → navigation")

        seen.removeAll()
        fixture.bridge.jump(to: 0)
        #expect(seen == [.historyNavigation], "a 3-step jump calls the hook exactly once")

        seen.removeAll()
        fixture.bridge.prepareForSave()
        #expect(seen == [.save])

        seen.removeAll()
        fixture.bridge.prepareForNavigation?()
        #expect(seen == [.command], "direct calls (Edit commands) are `.command`")
        #expect(fixture.bridge.pendingEditReason == .command, "…and it resets afterwards")
    }
}
