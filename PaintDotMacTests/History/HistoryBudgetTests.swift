import Foundation
import Testing

@testable import PaintDotMac

/// Exact oracles from the budget rule in spec 0008 Scope §7.
struct HistoryBudgetTests {
    private func whiteImage(_ width: Int = 512, _ height: Int = 512) -> LayeredImage {
        .blank(size: PixelSize(width: width, height: height), fill: .white)
    }

    private func coord(_ column: Int, _ row: Int) -> TileCoordinate {
        TileCoordinate(column: column, row: row)
    }

    @Test func dropsOldestTileStep() throws {
        var stack = HistoryStack(base: .openImage, budgetBytes: 1_048_576)
        let base = whiteImage()
        let rect1 = PixelRect(x: 5, y: 5, width: 4, height: 4)
        var oracleStep1 = ReferenceCanvas(image: base)
        oracleStep1.fillRect(rect: rect1, color: ColorRGBA8(red: 255, green: 0, blue: 0), layer: 0)
        var afterStep1 = base
        fillRect(&afterStep1, layer: 0, rect: rect1, color: ColorRGBA8(red: 255, green: 0, blue: 0))
        let diff1 = try TileDiff.between(before: base, after: afterStep1)
        var state = DocumentState(image: afterStep1)
        let first = stack.commit(TileDiffHistoryItem(name: "Step 1", icon: .paintbrush,
                                                     diff: diff1))
        #expect(first.droppedStepIDs.isEmpty)
        #expect(stack.totalBytes == 525_312)
        let id1 = try #require(first.recordedStepID)

        var afterStep2 = afterStep1
        fillRect(&afterStep2, layer: 0, rect: PixelRect(x: 300, y: 5, width: 4, height: 4),
                 color: .black)
        let diff2 = try TileDiff.between(before: afterStep1, after: afterStep2)
        state.image = afterStep2
        let second = stack.commit(TileDiffHistoryItem(name: "Step 2", icon: .eraser,
                                                      diff: diff2))
        // Each step: 2 × 262,144 + 1,024 = 525,312; two exceed 1,048,576 → fold step 1.
        #expect(second.droppedStepIDs == [id1])
        #expect(stack.steps.map(\.name) == ["Open Image", "Step 2"])
        #expect(stack.totalBytes == 525_312)

        let change = stack.undo(&state)
        #expect(change == .pixels([diff2.entries[0].layerID: [coord(1, 0)]]))
        assertMatches(state.image, oracleStep1,
                      "undo stops at the state after the dropped step, not the opened image")
        #expect(stack.canUndo == false)
        #expect(stack.steps[0].name == "Open Image", "the base step keeps its name")
    }

    @Test func keepsSingleOversizedStep() throws {
        var stack = HistoryStack(base: .openImage, budgetBytes: 100)
        let base = whiteImage()
        var after = base
        fillRect(&after, layer: 0, rect: PixelRect(x: 5, y: 5, width: 4, height: 4), color: ColorRGBA8(red: 255, green: 0, blue: 0))
        let diff = try TileDiff.between(before: base, after: after)
        var state = DocumentState(image: after)
        let result = stack.commit(TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush,
                                                      diff: diff))
        #expect(result.recordedStepID != nil)
        #expect(result.droppedStepIDs.isEmpty)
        #expect(stack.totalBytes == 525_312)
        #expect(stack.totalBytes > stack.budgetBytes, "an oversized current step is kept (H-6)")
        #expect(stack.canUndo)
        stack.undo(&state)
        assertMatches(state.image, ReferenceCanvas(image: base), "the oversized step undoes")
    }

    @Test func fakeCostSequence() {
        var stack = HistoryStack(base: .openImage, budgetBytes: 10_000)
        var state = DocumentState(image: whiteImage())
        let a = FakeHistoryItem(name: "A", byteCost: 3_000, after: "A")
        let b = FakeHistoryItem(name: "B", byteCost: 3_000, before: "A", after: "B")
        let c = FakeHistoryItem(name: "C", byteCost: 3_000, before: "B", after: "C")

        let resultA = stack.perform(a, on: &state)
        #expect(stack.totalBytes == 4_024)
        let resultB = stack.perform(b, on: &state)
        #expect(stack.totalBytes == 8_048)
        let resultC = stack.perform(c, on: &state)
        // 12,072 > 10,000 → fold A (the oldest), 8,048 ≤ 10,000.
        #expect(resultC.droppedStepIDs == resultA.recordedStepID.map { [$0] } ?? [])
        #expect(stack.totalBytes == 8_048)
        #expect(stack.steps.map(\.name) == ["Open Image", "B", "C"])

        stack.undo(&state)
        #expect(stack.currentIndex == 1)
        // Budget 0, current index 1 → nothing can fold (never the base, never the current).
        #expect(stack.setBudget(0).isEmpty)

        stack.redo(&state)
        #expect(stack.currentIndex == 2)
        let dropped = stack.setBudget(0)
        #expect(dropped == resultB.recordedStepID.map { [$0] } ?? [])
        #expect(stack.steps.map(\.name) == ["Open Image", "C"])
        #expect(stack.currentIndex == 1)
        #expect(stack.totalBytes == 4_024)
    }

    @Test func redoStepsNeverDroppedByEnforcement() {
        var stack = HistoryStack(base: .openImage, budgetBytes: 1_000_000)
        var state = DocumentState(image: whiteImage())
        for (index, name) in ["A", "B", "C", "D"].enumerated() {
            stack.perform(FakeHistoryItem(name: name, byteCost: 3_000,
                                          before: index == 0 ? "Background" : ["A", "B", "C"][index - 1],
                                          after: name), on: &state)
        }
        stack.undo(&state)
        stack.undo(&state)
        stack.undo(&state)
        #expect(stack.currentIndex == 1)
        #expect(stack.canRedo)
        #expect(stack.setBudget(0).isEmpty, "only steps older than the current one are dropped")
        #expect(stack.canRedo, "redo steps survive until the next commit")
        #expect(stack.totalBytes == 4 * 4_024)
        stack.redo(&state)
        #expect(stack.steps.count == 5)
    }

    @Test func savedMarkerFollowsFold() throws {
        var stack = HistoryStack(base: .openImage, budgetBytes: 4_024)
        var state = DocumentState(image: whiteImage())
        let a = FakeHistoryItem(name: "A", byteCost: 3_000, after: "A")
        let b = FakeHistoryItem(name: "B", byteCost: 3_000, before: "A", after: "B")

        let resultA = stack.perform(a, on: &state)
        stack.markSaved(stepID: try #require(resultA.recordedStepID))
        #expect(stack.isAtSavedState, "A is the current step and was just saved")
        stack.perform(b, on: &state)  // 8,048 > 4,024 → fold A
        #expect(stack.savedStepID == stack.steps[0].id,
                "the folded saved step's state becomes the base")
        stack.undo(&state)
        #expect(stack.currentIndex == 0)
        #expect(stack.isAtSavedState, "at the base, which now IS the saved state")
    }

    @Test func savedAtBaseThenFoldClearsMarker() {
        var stack = HistoryStack(base: .openImage, budgetBytes: 4_024)
        var state = DocumentState(image: whiteImage())
        // savedStepID starts at the base (0).
        stack.perform(FakeHistoryItem(name: "A", byteCost: 3_000, after: "A"), on: &state)
        #expect(stack.savedStepID == 0)
        stack.perform(FakeHistoryItem(name: "B", byteCost: 3_000, before: "A", after: "B"),
                      on: &state)
        #expect(stack.savedStepID == nil,
                "folding past the base makes the saved state unreachable (dirty until saved)")
    }

    @Test func budgetZeroKeepsBaseAndCurrent() throws {
        var stack = HistoryStack(base: .openImage, budgetBytes: 0)
        let base = whiteImage()
        var after = base
        fillRect(&after, layer: 0, rect: PixelRect(x: 5, y: 5, width: 4, height: 4), color: ColorRGBA8(red: 255, green: 0, blue: 0))
        let diff = try TileDiff.between(before: base, after: after)
        let result = stack.commit(TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush,
                                                      diff: diff))
        #expect(result.droppedStepIDs.isEmpty)
        #expect(stack.steps.count == 2, "budget 0 keeps base + current step")
        #expect(stack.totalBytes == 525_312)
    }
}
