import Foundation
import Testing

@testable import PaintDotMac

/// Random layer-command sequences through a real `HistoryStack` (spec 0024 *Test plan*):
/// 100 seeded runs — every intermediate state stays consistent, undo-all returns to the
/// exact initial state, redo-all to the exact final one (L-1, H-1, H-3).
struct LayerOperationsPropertyTests {
    @Test(arguments: [0, 1, 2, 3])
    func randomSequencesUndoRedo(shard: Int) throws {
        let baseSeed = SeededRandom.resolvedSeed(default: 0x24C0FFEE)
        for run in 0..<25 {
            let seed = baseSeed &+ UInt64(shard * 25 + run)
            var random = SeededRandom(seed: seed)
            let size = run % 5 == 4
                ? PixelSize(width: 300, height: 300)
                : PixelSize(width: 64, height: 64)

            // 1–4 layers of sparse random tiles with random properties.
            let layerCount = random.int(in: 1...4)
            var layers: [Layer] = []
            for index in 0..<layerCount {
                var surface = TiledSurface(size: size)
                for row in 0..<surface.tileRows {
                    for column in 0..<surface.tileColumns where random.int(in: 0...2) > 0 {
                        var tile = Tile()
                        let originX = column * TiledSurface.tileSize
                        let originY = row * TiledSurface.tileSize
                        for y in stride(from: 0, to: 256, by: 37) {
                            for x in stride(from: 0, to: 256, by: 41)
                            where originX + x < size.width && originY + y < size.height {
                                tile.setPixel(random.color(), x: x, y: y)
                            }
                        }
                        surface.setTile(tile, at: TileCoordinate(column: column, row: row))
                    }
                }
                layers.append(Layer(name: "L\(index)", surface: surface,
                                    isVisible: random.int(in: 0...3) > 0,
                                    opacity: UInt8(random.int(in: 0...255))))
            }
            var state = DocumentState(image: LayeredImage(size: size, layers: layers,
                                                          activeLayerIndex: random.int(in: 0...(layerCount - 1))))
            var stack = HistoryStack(base: .newImage, budgetBytes: HistoryStack.defaultBudgetBytes)

            // The undo/redo walk must restore the EXACT step states (full `DocumentState`,
            // `activeLayerIndex` included). Go to Layer switches are not history steps, so
            // a switch before the first command or after the last one lives outside the
            // recorded states — H-6/D-34 makes every layer step restore the active pointer
            // of that step, overwriting whatever a hand switch moved it to in between.
            // Hence the walk is compared against the first/last *performed* states, not
            // `state` itself. (Comparing only `image.layers` here would let a revert that
            // drops the active pointer pass — this is the H-6 premise, not a weakened one.)
            var firstPerformed: DocumentState?
            var lastPerformed: DocumentState?

            for step in 0..<20 {
                // Random Go to Layer switches: plain active-index moves (not history).
                if random.int(in: 0...3) == 0,
                   let focusStep = [ActiveLayerStep.above, .below].randomElement(using: &random) {
                    state.image.activeLayerIndex = focusStep.targetIndex(in: state.image)
                        ?? state.image.activeLayerIndex
                }
                let enabled = LayerCommand.allCases.filter { $0.isEnabled(in: state) }
                guard let command = enabled.randomElement(using: &random),
                      let item = command.makeHistoryItem(for: state) else { continue }
                _ = stack.perform(item, on: &state)
                if firstPerformed == nil { firstPerformed = item.before }
                lastPerformed = item.after

                // Every intermediate state stays consistent.
                #expect(state.image.isConsistent, "seed \(seed) run \(run) step \(step)")
                #expect(Set(state.image.layers.map { $0.id }).count == state.image.layers.count,
                        "seed \(seed) run \(run) step \(step)")
                #expect(state.image.size == size)
            }
            // Add New Layer and Duplicate are always enabled, so a run always performs
            // at least one step and both anchors exist.
            let firstBefore = try #require(firstPerformed, "seed \(seed) run \(run)")
            let lastAfter = try #require(lastPerformed, "seed \(seed) run \(run)")

            // A digest, not `#expect(state == expected)` — Swift Testing's operand
            // reflection of a full multi-layer `DocumentState` is hundreds of MB.
            func expectEqual(_ state: DocumentState, _ expected: DocumentState, _ what: String) {
                if state != expected {
                    func digest(_ s: DocumentState) -> String {
                        "count \(s.image.layers.count), active \(s.image.activeLayerIndex), "
                            + "ids \(s.image.layers.map(\.id).map(String.init(describing:))), "
                            + "selection \(s.selection == nil ? "nil" : "set"), "
                            + "floating \(s.floatingPixels == nil ? "nil" : "set")"
                    }
                    Issue.record(Comment(rawValue:
                        "\(what), seed \(seed) run \(run): got \(digest(state)), expected \(digest(expected))"))
                }
            }
            while stack.canUndo { stack.undo(&state) }
            expectEqual(state, firstBefore, "undo-all mismatch")
            while stack.canRedo { stack.redo(&state) }
            expectEqual(state, lastAfter, "redo-all mismatch")
        }
    }
}
