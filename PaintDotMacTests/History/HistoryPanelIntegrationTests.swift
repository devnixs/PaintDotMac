import Foundation
import Testing

@testable import PaintDotMac

/// The History panel against the real 0008 stack: a `HistoryPanelModel` bound to a real
/// `UndoBridge`, driven by `PaintbrushTool` strokes through `BridgeToolContext` (spec 0010
/// *Test plan*, PRD H-1/H-2/H-3/H-5). All state expectations are computed from the spec's
/// rules; pixel expectations from the strokes themselves (opaque black, width 10,
/// antialiasing off, on a 300×300 white image).
@MainActor
@Suite(.serialized)
struct HistoryPanelIntegrationTests {
    private let image300 = PixelSize(width: 300, height: 300)

    /// A bridge on white 300×300 (base "Open Image"), one bound `HistoryPanelModel`, the
    /// stroke options pinned: width 10, antialiasing off, primary opaque black.
    private func makeFixture(budgetBytes: Int = HistoryStack.defaultBudgetBytes)
        -> (BridgeToolContext, HistoryPanelModel)
    {
        let context = BridgeToolContext(size: image300, budgetBytes: budgetBytes)
        let keys = BrushOptions.keys(for: .paintbrush)
        context.options.setValue(10.0, for: keys.width)
        context.options.setValue(false, for: keys.antialiasing)
        #expect(context.colors.primary == .black, ".default's primary is opaque black")
        let panel = HistoryPanelModel()
        panel.bind(to: context.bridge)
        return (context, panel)
    }

    /// The layer's full RGBA buffer — the byte-for-byte pixel oracle.
    private func snapshot(_ context: BridgeToolContext) -> [UInt8] {
        let surface = context.bridge.state.image.layers[0].surface
        return surface.readPixels(in: PixelRect(x: 0, y: 0, width: surface.size.width,
                                                height: surface.size.height))
    }

    private func pixel(_ context: BridgeToolContext, _ x: Int, _ y: Int) -> ColorRGBA8 {
        context.bridge.state.image.layers[0].surface.pixel(at: PixelPoint(x: x, y: y))
    }

    private func assertRowStates(_ panel: HistoryPanelModel, _ states: [HistoryRowState],
                                 _ comment: Comment = Comment("")) {
        #expect(panel.model.rows.map(\.state) == states, comment)
    }

    // MARK: - H-1: rows mirror the steps

    @Test func strokesAppendPaintbrushRows() {
        let (context, panel) = makeFixture()
        #expect(panel.model.rows.map(\.name) == ["Open Image"])
        #expect(panel.model.rows[0].state == .current)

        context.stroke(y: 50)
        context.stroke(y: 150)
        context.stroke(y: 250)

        #expect(panel.model.rows.map(\.name)
                    == ["Open Image", "Paintbrush", "Paintbrush", "Paintbrush"])
        #expect(panel.model.rows.map(\.id) == [0, 1, 2, 3])
        #expect(panel.model.rows[0].icon == .openImage)
        #expect(panel.model.rows.dropFirst().allSatisfy { $0.icon == .paintbrush })
        #expect(panel.model.rows.last?.state == .current)
        assertRowStates(panel, [.done, .done, .done, .current])
    }

    // MARK: - H-2: jumping restores exact pixels

    @Test func jumpRestoresExactTiles() throws {
        let (context, panel) = makeFixture()
        context.stroke(y: 50)
        let s1 = snapshot(context)
        context.stroke(y: 150)
        let s2 = snapshot(context)
        context.stroke(y: 250)
        let s3 = snapshot(context)
        let base = Array(repeating: UInt8(0xFF), count: 300 * 300 * 4)
        #expect(s1 != base && s1 != s2 && s2 != s3, "the strokes differ from each other")

        panel.clickRow(1)
        #expect(snapshot(context) == s1, "row 1 shows exactly state S1")
        assertRowStates(panel, [.done, .current, .undone, .undone])

        panel.clickRow(0)
        #expect(snapshot(context) == base, "row 0 is the opened (all-white) image")
        assertRowStates(panel, [.current, .undone, .undone, .undone])

        panel.clickRow(3)   // multi-step redo in one jump
        #expect(snapshot(context) == s3)
        assertRowStates(panel, [.done, .done, .done, .current])

        panel.clickRow(2)
        #expect(snapshot(context) == s2)
        assertRowStates(panel, [.done, .done, .current, .undone])
    }

    // MARK: - H-3: the undo manager and Edit menu agree with the panel

    @Test func jumpKeepsUndoManagerInSync() throws {
        let (context, panel) = makeFixture()
        context.stroke(y: 50)
        context.stroke(y: 150)
        context.stroke(y: 250)
        let s3 = snapshot(context)
        let manager = context.bridge.undoManager

        panel.clickRow(1)
        #expect(manager.canUndo)
        #expect(manager.canRedo)
        #expect(manager.undoMenuItemTitle == "Undo Paintbrush")
        #expect(manager.redoMenuItemTitle == "Redo Paintbrush")

        panel.clickRow(0)
        #expect(!manager.canUndo)
        #expect(manager.canRedo)
        #expect(manager.redoMenuItemTitle == "Redo Paintbrush")

        // The redo stack the jump built is exact: three redos land on S3.
        manager.redo()
        manager.redo()
        manager.redo()
        #expect(context.bridge.history.currentIndex == 3)
        #expect(panel.model.currentIndex == 3)
        #expect(snapshot(context) == s3)
        #expect(!manager.canRedo)
        #expect(manager.undoMenuItemTitle == "Undo Paintbrush")
    }

    // MARK: - one refresh per operation

    @Test func undoRedoRefreshPanel() {
        let (context, panel) = makeFixture()
        context.stroke(y: 50)
        context.stroke(y: 150)
        context.stroke(y: 250)
        let manager = context.bridge.undoManager

        let revisionBeforeUndo = context.bridge.historyRevision
        let refreshesBeforeUndo = panel.refreshCount
        manager.undo()
        #expect(panel.model.currentIndex == 2)
        #expect(panel.model.rows[3].state == .undone)
        #expect(panel.refreshCount - refreshesBeforeUndo == 1, "one refresh per undo")
        #expect(context.bridge.historyRevision - revisionBeforeUndo == 1)

        let refreshesBeforeRedo = panel.refreshCount
        let revisionBeforeRedo = context.bridge.historyRevision
        manager.redo()
        #expect(panel.model.currentIndex == 3)
        #expect(panel.model.rows[3].state == .current)
        #expect(panel.refreshCount - refreshesBeforeRedo == 1, "one refresh per redo")
        #expect(context.bridge.historyRevision - revisionBeforeRedo == 1)

        let refreshesBeforeJump = panel.refreshCount
        let revisionBeforeJump = context.bridge.historyRevision
        panel.clickRow(0)   // a 3-step jump
        #expect(panel.model.currentIndex == 0)
        #expect(panel.refreshCount - refreshesBeforeJump == 1, "one refresh for a whole jump")
        #expect(context.bridge.historyRevision - revisionBeforeJump == 1)
    }

    // MARK: - new action discards the grey rows

    @Test func newStrokeDiscardsUndoneRows() {
        let (context, panel) = makeFixture()
        context.stroke(y: 50)
        let s1 = snapshot(context)
        context.stroke(y: 150)
        context.stroke(y: 250)

        panel.clickRow(1)
        assertRowStates(panel, [.done, .current, .undone, .undone])

        context.stroke(y: 200)
        #expect(panel.model.rows.map(\.name) == ["Open Image", "Paintbrush", "Paintbrush"])
        #expect(!panel.model.rows.contains { $0.isUndone }, "the grey rows are gone")
        #expect(panel.model.rows.last?.state == .current)
        #expect(!context.bridge.undoManager.canRedo)

        #expect(snapshot(context) != s1)
        #expect(pixel(context, 100, 150) == .white, "the discarded 150 stroke is gone")
        #expect(pixel(context, 100, 250) == .white, "the discarded 250 stroke is gone")
        #expect(pixel(context, 100, 200) == .black, "the new 200 stroke is on the new branch")
    }

    // MARK: - H-5: budget drops disappear from the panel

    @Test func budgetDropRemovesOldestRows() throws {
        // Each stroke crosses x = 256, so each diff covers exactly tiles (0,0) and (1,0):
        // 4 tile buffers + step overhead = 1,049,600 accounted bytes; two fit in 2,500,000,
        // three don't (0008's rule), so strokes 1 and 2 fold into the base.
        let (context, panel) = makeFixture(budgetBytes: 2_500_000)
        context.stroke(y: 40)
        context.stroke(y: 80)
        context.stroke(y: 120)   // first drop folds stroke 1 into the base
        let id3 = try #require(context.bridge.history.steps.last?.id)
        context.stroke(y: 160)   // second drop folds stroke 2
        let id4 = try #require(context.bridge.history.steps.last?.id)

        #expect(panel.model.rows.map(\.name) == ["Open Image", "Paintbrush", "Paintbrush"])
        #expect(panel.model.rows.map(\.id) == [0, id3, id4], "the ids strokes 3 and 4 got")
        #expect(panel.model.rows[0].name == "Open Image")
        #expect(panel.model.rows.last?.state == .current)
        #expect(context.bridge.history.totalBytes == 2 * 1_049_600)

        // Clicking the re-based rows never crashes; row 0 stays the base step.
        panel.clickRow(1)
        #expect(panel.model.rows[0].state == .done)
        #expect(panel.model.rows[1].state == .current)
        panel.clickRow(0)
        #expect(panel.model.currentIndex == 0)
        #expect(panel.model.rows.count == 3)
        #expect(panel.model.rows[0].state == .current)
    }

    // MARK: - no document

    @Test func emptyModelWhenNoDocument() {
        let panel = HistoryPanelModel()
        #expect(panel.model == .empty)
        panel.bind(to: nil)
        #expect(panel.model == .empty)
        panel.undo()      // no-ops that must not crash
        panel.redo()
        panel.clickRow(0)
        #expect(panel.model == .empty)
    }

    /// The panel holds the bridge weakly: a closed document is never kept alive, and the
    /// next refresh falls back to `.empty`.
    @Test func bridgeIsHeldWeakly() {
        var context: BridgeToolContext? = BridgeToolContext(size: PixelSize(width: 8, height: 8))
        let panel = HistoryPanelModel()
        panel.bind(to: context?.bridge)
        #expect(panel.model.rows.map(\.name) == ["Open Image"])
        context = nil
        panel.refresh()
        #expect(panel.boundBridge == nil, "the last strong reference dropped")
        #expect(panel.model == .empty)
    }
}
