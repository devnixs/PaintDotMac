import Foundation
import Testing

@testable import PaintDotMac

struct HistoryStackTests {
    private func coord(_ column: Int, _ row: Int) -> TileCoordinate {
        TileCoordinate(column: column, row: row)
    }

    private func whiteImage(_ width: Int = 512, _ height: Int = 512) -> LayeredImage {
        .blank(size: PixelSize(width: width, height: height), fill: .white)
    }

    /// A one-tile paint step (525,312 accounted bytes with the per-step overhead).
    private func paintStep(on before: LayeredImage? = nil,
                           x: Int, y: Int) throws -> (TileDiffHistoryItem, LayeredImage) {
        let before = before ?? whiteImage()
        var after = before
        fillRect(&after, layer: 0, rect: PixelRect(x: x, y: y, width: 4, height: 4),
                 color: ColorRGBA8(red: UInt8(x % 250), green: 3, blue: 7))
        let diff = try TileDiff.between(before: before, after: after)
        return (TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush, diff: diff), after)
    }

    /// The five-step disjoint-tile session used by the jump tests: step paints
    /// `rect(x: 4 + 8·i, y: 4, 4×4)` on top of the previous state. The base travels with
    /// the items: a diff only ever runs on the state pair it captured (same layer IDs).
    private func paintSession() throws -> (base: LayeredImage, items: [TileDiffHistoryItem]) {
        var states: [LayeredImage] = [whiteImage(1024, 512)]
        var items: [TileDiffHistoryItem] = []
        for i in 0..<5 {
            let before = states[states.count - 1]
            var after = before
            fillRect(&after, layer: 0, rect: PixelRect(x: 4 + 8 * i, y: 4, width: 4, height: 4),
                     color: ColorRGBA8(red: UInt8(200 - 30 * i), green: 10, blue: 10))
            let diff = try TileDiff.between(before: before, after: after)
            items.append(TileDiffHistoryItem(name: "Paintbrush \(i)", icon: .paintbrush,
                                             diff: diff))
            states.append(after)
        }
        return (states[0], items)
    }

    /// A fresh stack with the session performed and standing at `index`.
    private func session(at index: Int, _ state: inout DocumentState) throws -> HistoryStack {
        let (base, items) = try paintSession()
        return session(at: index, &state, base: base, items: items)
    }

    private func session(at index: Int, _ state: inout DocumentState,
                         base: LayeredImage,
                         items: [TileDiffHistoryItem]) -> HistoryStack {
        var stack = HistoryStack(base: .openImage)
        state = DocumentState(image: base)
        for item in items { stack.perform(item, on: &state) }
        while stack.currentIndex > index { _ = stack.undo(&state) }
        return stack
    }

    @Test func initialOpenImageStep() throws {
        let stack = HistoryStack(base: .openImage)
        #expect(stack.steps.count == 1)
        let step = try #require(stack.steps.first)
        #expect(step.name == "Open Image")
        #expect(step.icon == .openImage)
        #expect(step.isBase)
        #expect(step.item == nil)
        #expect(step.id == 0)
        #expect(stack.currentIndex == 0)
        #expect(stack.canUndo == false)
        #expect(stack.canRedo == false)
        #expect(stack.undoStep == nil)
        #expect(stack.redoStep == nil)
        #expect(stack.totalBytes == 0)
        #expect(stack.currentStepID == 0)
        #expect(stack.isAtSavedState, "a freshly opened file is clean (APP-9)")
        #expect(stack.savedStepID == 0)
    }

    @Test func initialNewImageStep() throws {
        let stack = HistoryStack(base: .newImage)
        let step = try #require(stack.steps.first)
        #expect(step.name == "New Image")
        #expect(step.icon == .newImage)
        #expect(stack.isAtSavedState, "an untouched new image is clean (APP-9, D-30)")
    }

    @Test func defaultBudget() {
        #expect(HistoryStack(base: .openImage).budgetBytes == 1_073_741_824)  // "1 GB" (H-6)
        #expect(HistoryStack.defaultBudgetBytes == 1_073_741_824)
        #expect(HistoryStack(base: .openImage, budgetBytes: -5).budgetBytes == 0)
    }

    @Test func commitUndoRedo() throws {
        var stack = HistoryStack(base: .openImage)
        let beforeImage = whiteImage()
        let (item, afterImage) = try paintStep(on: beforeImage, x: 10, y: 10)
        let layerID = try #require(beforeImage.layers.first?.id)
        var state = DocumentState(image: beforeImage)
        // The live-drawing pattern: the pixels are already in the state the tool drew.
        state.image = afterImage

        let result = stack.commit(item)
        #expect(result.recordedStepID == 1)
        #expect(result.discardedRedoStepIDs.isEmpty)
        #expect(result.droppedStepIDs.isEmpty)
        #expect(stack.currentIndex == 1)
        #expect(stack.undoStep?.name == "Paintbrush")
        #expect(stack.totalBytes == 525_312)  // 2 × 262,144 + 1,024
        #expect(stack.isAtSavedState == false)

        let change = stack.undo(&state)
        #expect(change == .pixels([layerID: [coord(0, 0)]]))
        assertMatches(state.image, ReferenceCanvas(image: beforeImage), "undo restores exactly")
        #expect(stack.redoStep?.name == "Paintbrush")
        #expect(stack.isAtSavedState, "back at the saved step")

        let redoChange = stack.redo(&state)
        #expect(redoChange == .pixels([layerID: [coord(0, 0)]]))
        assertMatches(state.image, ReferenceCanvas(image: afterImage), "redo restores exactly")
    }

    @Test func performAppliesThenRecords() throws {
        var stack = HistoryStack(base: .openImage)
        let start = whiteImage()
        let (item, afterImage) = try paintStep(on: start, x: 20, y: 20)
        var state = DocumentState(image: start)
        let result = stack.perform(item, on: &state)
        #expect(result.recordedStepID != nil)
        assertMatches(state.image, ReferenceCanvas(image: afterImage), "perform applies")
        #expect(stack.steps.count == 2)
    }

    @Test func commitDiscardsRedo() {
        var stack = HistoryStack(base: .openImage)
        var state = DocumentState(image: whiteImage())
        let stepA = FakeHistoryItem(name: "A", byteCost: 1_000, after: "A")
        let stepB = FakeHistoryItem(name: "B", byteCost: 2_000, before: "A", after: "B")
        let stepC = FakeHistoryItem(name: "C", byteCost: 3_000, before: "B", after: "C")
        let stepD = FakeHistoryItem(name: "D", byteCost: 4_000, before: "A", after: "D")

        stack.perform(stepA, on: &state)
        stack.perform(stepB, on: &state)
        stack.perform(stepC, on: &state)
        stack.undo(&state)
        stack.undo(&state)
        #expect(stack.currentIndex == 1)
        // Undo changes no bytes: the redo steps are only subtracted by the next commit.
        #expect(stack.totalBytes == 1_000 + 2_000 + 3_000 + 3 * 1_024)

        let result = stack.commit(stepD)
        #expect(result.discardedRedoStepIDs == [2, 3])
        #expect(stack.steps.map(\.name) == ["Open Image", "A", "D"])
        #expect(stack.totalBytes == 1_000 + 4_000 + 2 * 1_024)
        #expect(result.recordedStepID == 4)
    }

    @Test func noOpItemIsIgnored() throws {
        var stack = HistoryStack(base: .openImage)
        let image = whiteImage()
        let emptyDiff = try TileDiff.between(before: image, after: image)
        let noOp = TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush, diff: emptyDiff)
        var state = DocumentState(image: image)

        let result = stack.commit(noOp)
        #expect(result.recordedStepID == nil)
        #expect(result.discardedRedoStepIDs.isEmpty)
        #expect(result.droppedStepIDs.isEmpty)
        #expect(stack.steps.count == 1)
        #expect(stack.totalBytes == 0)
        #expect(stack.isAtSavedState, "a no-op edit does not dirty the document (H-6)")

        let performResult = stack.perform(noOp, on: &state)
        #expect(performResult.recordedStepID == nil)
        #expect(stack.steps.count == 1)
        #expect(state.image == image, "perform must not even apply a no-op")
    }

    @Test func undoAtBaseAndRedoAtTopAreNoOps() throws {
        var stack = HistoryStack(base: .openImage)
        var state = DocumentState(image: whiteImage())
        let baseline = ReferenceCanvas(image: state.image)

        #expect(stack.undo(&state) == nil)
        #expect(stack.redo(&state) == nil)
        assertMatches(state.image, baseline, "state bytes unchanged")

        let (item, _) = try paintStep(on: state.image, x: 5, y: 5)
        stack.perform(item, on: &state)
        #expect(stack.redo(&state) == nil, "redo at the newest step does nothing")
        #expect(stack.currentIndex == 1)
        stack.undo(&state)
        #expect(stack.undo(&state) == nil, "undo at the base step does nothing")
        #expect(stack.currentIndex == 0)
    }

    @Test func jumpEqualsRepeatedUndoRedo() throws {
        // States S0…S5 (the session bases) and their oracles — all from one
        // `paintSession()` chain, so every item runs on its captured state pair.
        let (base, sessionItems) = try paintSession()
        var bases: [LayeredImage] = [base]
        for item in sessionItems {
            var state = DocumentState(image: bases[bases.count - 1])
            item.apply(to: &state)
            bases.append(state.image)
        }
        let oracles = bases.map { ReferenceCanvas(image: $0) }

        for from in 0...5 {
            for to in 0...5 {
                // One chain feeds both stacks, so the two states carry equal layer IDs.
                var jumped = DocumentState(image: base)
                var jumpStack = session(at: from, &jumped, base: base, items: sessionItems)
                var stepped = DocumentState(image: base)
                var stepStack = session(at: from, &stepped, base: base, items: sessionItems)

                let changes = jumpStack.jump(to: to, &jumped)
                while stepStack.currentIndex > to { _ = stepStack.undo(&stepped) }
                while stepStack.currentIndex < to { _ = stepStack.redo(&stepped) }

                #expect(jumped.image == stepped.image, "jump \(from)→\(to) equals repeated steps")
                assertMatches(jumped.image, oracles[to], "state after jump \(from)→\(to)")
                #expect(jumpStack.currentIndex == to)
                #expect(changes.count == abs(from - to))
            }
        }
    }

    @Test func jumpOutOfRangeIsNoOp() throws {
        var state = DocumentState(image: whiteImage(1024, 512))
        var stack = try session(at: 2, &state)
        #expect(stack.jump(to: -1, &state).isEmpty)
        #expect(stack.jump(to: stack.steps.count, &state).isEmpty)
        #expect(stack.jump(to: stack.currentIndex, &state).isEmpty)
        #expect(stack.currentIndex == 2)
    }

    @Test func stepIDsAreNeverReused() throws {
        var stack = HistoryStack(base: .openImage, budgetBytes: 1_048_576)
        var state = DocumentState(image: whiteImage())
        var recorded: [HistoryStep.ID] = [stack.currentStepID]  // base = 0
        var seenElsewhere: [HistoryStep.ID] = []
        for i in 0..<6 {
            let (item, _) = try paintStep(on: state.image, x: 4 + i, y: 4)
            let result = stack.perform(item, on: &state)
            if let id = result.recordedStepID { recorded.append(id) }
            seenElsewhere.append(contentsOf: result.droppedStepIDs)
            seenElsewhere.append(contentsOf: result.discardedRedoStepIDs)
            stack.undo(&state)  // so the next commit discards redo too
            let (again, _) = try paintStep(on: state.image, x: 40 + i, y: 4)
            let second = stack.perform(again, on: &state)
            if let id = second.recordedStepID { recorded.append(id) }
            seenElsewhere.append(contentsOf: second.droppedStepIDs)
            seenElsewhere.append(contentsOf: second.discardedRedoStepIDs)
        }
        _ = stack.setBudget(525_312)
        #expect(recorded == (0...recorded.count - 1).map { $0 },
                "IDs strictly increase and are never reused: \(recorded)")
        let recordedSet = Set(recorded)
        #expect(Set(seenElsewhere).isSubset(of: recordedSet),
                "dropped and discarded IDs are previously issued ones")
    }

    @Test func savedMarker() throws {
        var stack = HistoryStack(base: .openImage, budgetBytes: 1_000_000_000)
        var state = DocumentState(image: whiteImage())
        let (itemA, _) = try paintStep(on: state.image, x: 4, y: 4)
        stack.perform(itemA, on: &state)
        let (itemB, _) = try paintStep(on: state.image, x: 8, y: 4)
        stack.perform(itemB, on: &state)
        let step2 = stack.currentStepID
        #expect(step2 == 2)

        stack.markSaved(stepID: step2)
        #expect(stack.savedStepID == step2)
        stack.undo(&state)
        #expect(stack.isAtSavedState == false)
        stack.redo(&state)
        #expect(stack.isAtSavedState)

        stack.undo(&state)
        let (itemC, _) = try paintStep(on: state.image, x: 12, y: 4)
        let result = stack.perform(itemC, on: &state)
        #expect(result.discardedRedoStepIDs == [step2])
        #expect(stack.savedStepID == nil, "the saved state is no longer reachable")
        #expect(stack.isAtSavedState == false)

        stack.markSaved(stepID: 999)
        #expect(stack.savedStepID == nil)
        stack.clearSavedState()
        #expect(stack.savedStepID == nil)
    }
}
