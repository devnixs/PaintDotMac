import Foundation
import Testing

@testable import PaintDotMac

/// Random layer-command sequences through a real `HistoryStack` (spec 0024 *Test plan*):
/// 100 seeded runs — every intermediate state stays consistent, undo-all returns to the
/// exact initial state, redo-all to the exact final one (L-1, H-1, H-3).
struct LayerOperationsPropertyTests {
    @Test(arguments: [0, 1, 2, 3])
    func randomSequencesUndoRedo(shard: Int) {
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
            let initial = state
            var stack = HistoryStack(base: .newImage, budgetBytes: HistoryStack.defaultBudgetBytes)

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

                // Every intermediate state stays consistent.
                #expect(state.image.isConsistent, "seed \(seed) run \(run) step \(step)")
                #expect(Set(state.image.layers.map { $0.id }).count == state.image.layers.count,
                        "seed \(seed) run \(run) step \(step)")
                #expect(state.image.size == size)
            }
            let final = state

            // Go to Layer switches are not history steps, so the undo/redo walk
            // restores pixels, properties, identities, and order but not the
            // active pointer the test moved by hand. Per-step active targeting is
            // pinned in ActiveLayerStepTests / LayerOperationsTests.
            func stackContents(of s: DocumentState) -> [Layer] { s.image.layers }
            while stack.canUndo { stack.undo(&state) }
            #expect(stackContents(of: state) == stackContents(of: initial),
                    "undo-all mismatch, seed \(seed) run \(run)")
            #expect(state.selection == initial.selection && state.floatingPixels == initial.floatingPixels)
            while stack.canRedo { stack.redo(&state) }
            #expect(stackContents(of: state) == stackContents(of: final),
                    "redo-all mismatch, seed \(seed) run \(run)")
        }
    }
}
