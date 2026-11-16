import Foundation
import Testing

@testable import PaintDotMac

struct HistoryPropertyTests {
    private func whiteImage(_ width: Int, _ height: Int) -> LayeredImage {
        .blank(size: PixelSize(width: width, height: height), fill: .white)
    }

    /// 200 seeds × 40 operations on a 600×520 two-layer image (layer 0 opaque white, layer 1
    /// empty). Every reachable state must match the independent `ReferenceCanvas` oracle;
    /// undo/redo indices and step names must match the model; every undo-then-redo pair is a
    /// byte-exact identity. Budget = default (no drops).
    @Test(arguments: (0..<200).map { UInt64(bitPattern: 0xC0FF_EE00 &+ Int64($0)) })
    func randomSessionsMatchOracle(seed: UInt64) throws {
        var rng = SeededRandom(seed: seed)
        let size = PixelSize(width: 600, height: 520)
        var baseSurface = TiledSurface(size: size)
        baseSurface.fill(.white)
        let image = LayeredImage(size: size, layers: [
            Layer(name: "Background", surface: baseSurface),
            Layer(name: "Layer 2", surface: TiledSurface(size: size)),
        ], activeLayerIndex: 0)

        var state = DocumentState(image: image)
        var stack = HistoryStack(base: .newImage)  // default budget: no drops

        // The model: one oracle per committed step (index 0 = base) and the step names.
        var model: [ReferenceCanvas] = [ReferenceCanvas(image: image)]
        var names: [String] = []  // names[i] = step (i+1)'s name
        var expectedIndex = 0

        for step in 0..<40 {
            let roll = rng.int(in: 0...9)
            switch roll {
            case 0...5:  // edit: random layer, rect possibly crossing tiles and the edge
                let layer = rng.int(in: 0...1)
                let rect = PixelRect(
                    x: rng.int(in: 0...(size.width - 1)),
                    y: rng.int(in: 0...(size.height - 1)),
                    width: rng.int(in: 1...300), height: rng.int(in: 1...300)
                )
                let color = ColorRGBA8(
                    red: UInt8(rng.int(in: 0...255)), green: UInt8(rng.int(in: 0...255)),
                    blue: UInt8(rng.int(in: 0...255)),
                    alpha: [UInt8(0), 128, 255][rng.int(in: 0...2)]
                )
                // The documented capture pattern: candidates from the generations.
                let before = state.image
                var candidateMap: [Layer.ID: Set<TileCoordinate>] = [:]
                for existing in state.image.layers {
                    candidateMap[existing.id] = Set(existing.surface
                        .changedTiles(since: existing.surface.generation))  // all-zero before draw
                }
                let touched = fillRect(&state.image, layer: layer, rect: rect, color: color)
                candidateMap[state.image.layers[layer].id] = touched
                let diff = try TileDiff.between(before: before, after: state.image,
                                                candidates: candidateMap)
                let name = "Paintbrush \(step)"
                let result = stack.commit(TileDiffHistoryItem(name: name, icon: .paintbrush,
                                                              diff: diff))
                if result.recordedStepID != nil {  // an identical write is a no-op: no step
                    model = Array(model.prefix(expectedIndex + 1))
                    names = Array(names.prefix(expectedIndex))
                    var oracle = model[expectedIndex]
                    oracle.fillRect(rect: rect, color: color, layer: layer)
                    model.append(oracle)
                    names.append(name)
                    expectedIndex = model.count - 1
                }
            case 6, 7:
                stack.undo(&state)
                expectedIndex = max(0, expectedIndex - 1)
            case 8:
                stack.redo(&state)
                expectedIndex = min(model.count - 1, expectedIndex + 1)
            default:
                let target = rng.int(in: 0...(model.count - 1))
                stack.jump(to: target, &state)
                expectedIndex = target
            }

            let comment: Comment = "\(rng.comment) step \(step) roll \(roll)"
            assertMatches(state.image, model[expectedIndex], comment)
            #expect(stack.currentIndex == expectedIndex, comment)
            #expect(stack.canUndo == (expectedIndex > 0), comment)
            #expect(stack.canRedo == (expectedIndex < model.count - 1), comment)
            #expect(stack.undoStep?.name == (expectedIndex > 0
                                             ? names[expectedIndex - 1] : nil), comment)
            #expect(stack.redoStep?.name == (expectedIndex < model.count - 1
                                             ? names[expectedIndex] : nil), comment)

            // Undo+redo and redo+undo are byte-exact identities on the current state.
            let snapshot = state
            if stack.canUndo {
                _ = stack.undo(&state)
                _ = stack.redo(&state)
                #expect(state.image == snapshot.image, "\(comment): undo+redo identity")
            }
            if stack.canRedo {
                _ = stack.redo(&state)
                _ = stack.undo(&state)
                #expect(state.image == snapshot.image, "\(comment): redo+undo identity")
            }
        }
    }

    /// 300 seeds × 60 operations with `FakeHistoryItem` random costs 0…5,000 and random
    /// budgets 0…20,000 (ops: commit / undo / redo / setBudget). After every operation:
    /// exact byte accounting, the base step keeps ID 0 and its name, the index is in range,
    /// the budget is respected unless the current step alone exceeds it, and the surviving
    /// step names are a suffix-preserving subsequence of the committed ones (drops are
    /// always the oldest). Undoing to the base yields the newest dropped step's state.
    @Test(arguments: (0..<300).map { UInt64(bitPattern: 0xB000_0000 &+ Int64($0)) })
    func budgetInvariants(seed: UInt64) throws {
        var rng = SeededRandom(seed: seed)
        var state = DocumentState(image: whiteImage(600, 520))
        var budget = rng.int(in: 0...20_000)
        var stack = HistoryStack(base: .newImage, budgetBytes: budget)

        var serial = 0
        var committed: [String] = []  // committed step names, commit order (steps 1…)
        var index = 0                 // stack.currentIndex
        var lastFolded: String?       // newest dropped step's name
        var enforced = true           // the last op ran budget enforcement

        for step in 0..<60 {
            let comment = "\(rng.comment) step \(step)"
            switch rng.int(in: 0...9) {
            case 0...5:
                enforced = true
                serial += 1
                let name = "S\(serial)"
                let cost = rng.int(in: 0...5_000)
                let before = index > 0 ? committed[index - 1] : (lastFolded ?? "Background")
                let result = stack.perform(
                    FakeHistoryItem(name: name, byteCost: cost, before: before, after: name),
                    on: &state
                )
                _ = try #require(result.recordedStepID)
                // The commit discarded every redo step after the current one.
                committed = Array(committed.prefix(index))
                committed.append(name)
                index = committed.count
                for _ in result.droppedStepIDs {
                    lastFolded = committed.removeFirst()
                    index -= 1
                }
            case 6, 7:
                // Undo/redo change no bytes and run no enforcement: a redo into the
                // redo branch may sit over budget until the next commit/setBudget
                // (spec: "after each commit/setBudget").
                enforced = false
                if stack.canUndo { _ = stack.undo(&state); index -= 1 }
            case 8:
                enforced = false
                if stack.canRedo { _ = stack.redo(&state); index += 1 }
            default:
                enforced = true
                budget = max(0, budget + rng.int(in: -4_000...4_000))
                for _ in stack.setBudget(budget) {
                    lastFolded = committed.removeFirst()
                    index -= 1
                }
            }

            let expectedTotal = stack.steps.dropFirst().reduce(0) {
                $0 + ($1.item?.byteCost ?? 0) + HistoryCost.stepOverheadBytes
            }
            #expect(stack.totalBytes == expectedTotal, "\(comment) totalBytes")
            #expect(stack.steps[0].id == 0, "\(comment) base keeps ID 0")
            #expect(stack.steps[0].name == "New Image", "\(comment) base name")
            #expect(stack.steps[0].isBase, "\(comment) base has no item")
            #expect(stack.budgetBytes == budget, "\(comment) budget stored")
            #expect(stack.currentIndex == index, "\(comment) model index")
            #expect((0..<stack.steps.count).contains(stack.currentIndex), "\(comment) range")
            if enforced {
                #expect(stack.totalBytes <= stack.budgetBytes || stack.currentIndex < 2,
                        "\(comment): over budget only while the current step cannot fold")
            }
            #expect(stack.steps.dropFirst().map(\.name) == committed,
                    "\(comment) survivors are the model tail")
            #expect(stack.steps.dropFirst().map(\.id)
                    == stack.steps.dropFirst().map(\.id).sorted(),
                    "\(comment) surviving steps stay in commit order")
        }

        // Undoing to the base yields the state of the newest dropped step (or the original).
        while stack.canUndo { _ = stack.undo(&state) }
        #expect(state.image.layers[0].name == (lastFolded ?? "Background"),
                "\(rng.comment): base state equals the newest dropped step's state")
    }
}
