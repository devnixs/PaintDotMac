import Foundation
import Testing

@testable import PaintDotMac

/// `LayerMove` (spec 0025 item 4): the drag-reorder move — one step named after its
/// direction, the moved layer active, the adjacency rule equal to 0024's up/down swap,
/// and an exact `HistoryStack` round-trip that never copies tile storage.
struct LayerOperationsMoveTests {
    private func image(active: Int = 0) -> LayeredImage {
        let size = PixelSize(width: 8, height: 8)
        let layers = ["A", "B", "C", "D"].enumerated().map { index, name in
            var surface = TiledSurface(size: size)
            surface.setPixel(ColorRGBA8(red: UInt8(index * 30), green: 0, blue: 0, alpha: 255),
                             at: PixelPoint(x: 1, y: 1))
            return Layer(name: name, surface: surface)
        }
        return LayeredImage(size: size, layers: layers, activeLayerIndex: active)
    }

    private func names(_ image: LayeredImage) -> [String] { image.layers.map(\.name) }

    @Test func multiPositionMoveUp() throws {
        var state = DocumentState(image: image(active: 0))
        let item = try #require(LayerMove.makeHistoryItem(from: 0, to: 2, for: state))
        #expect(item.name == "Move Layer Up")
        #expect(item.icon == .layerMove)
        #expect(item.change == .structure)
        #expect(item.after.image.layers.count == 4)
        item.apply(to: &state)
        #expect(names(state.image) == ["B", "C", "A", "D"])
        #expect(state.image.activeLayerIndex == 2, "the dragged layer stays selected")
        #expect(state.image.isConsistent)
        #expect(item.after.selection == item.before.selection)
        #expect(item.after.floatingPixels == nil)
        item.revert(&state)
        #expect(names(state.image) == ["A", "B", "C", "D"])
        #expect(state.image.activeLayerIndex == 0)
    }

    @Test func multiPositionMoveDown() throws {
        var state = DocumentState(image: image(active: 3))
        let item = try #require(LayerMove.makeHistoryItem(from: 3, to: 0, for: state))
        #expect(item.name == "Move Layer Down")
        item.apply(to: &state)
        #expect(names(state.image) == ["D", "A", "B", "C"])
        #expect(state.image.activeLayerIndex == 0)
    }

    @Test func degenerateInputsGiveNil() {
        let state = DocumentState(image: image())
        #expect(LayerMove.applied(from: 1, to: 1, in: state.image) == nil)
        #expect(LayerMove.makeHistoryItem(from: 1, to: 1, for: state) == nil)
        #expect(LayerMove.applied(from: -1, to: 2, in: state.image) == nil)
        #expect(LayerMove.applied(from: 0, to: 4, in: state.image) == nil)
        #expect(LayerMove.applied(from: 4, to: 0, in: state.image) == nil)
        #expect(LayerMove.makeHistoryItem(from: 9, to: 0, for: state) == nil)
    }

    /// `|to − from| == 1` with the active layer moved equals 0024's swap (spec item 4).
    @Test func adjacentMatchesLayerCommand() {
        for active in 0..<4 {
            let base = image(active: active)
            if active < 3 {
                let moved = LayerMove.applied(from: active, to: active + 1, in: base)
                #expect(moved == LayerCommand.moveLayerUp.applied(to: base), "up from \(active)")
            }
            if active > 0 {
                let moved = LayerMove.applied(from: active, to: active - 1, in: base)
                #expect(moved == LayerCommand.moveLayerDown.applied(to: base), "down from \(active)")
            }
        }
    }

    @Test func undoRedoThroughHistoryStack() throws {
        let start = image(active: 1)
        var state = DocumentState(image: start)
        var stack = HistoryStack(base: .openImage)
        let item = try #require(LayerMove.makeHistoryItem(from: 1, to: 3, for: state))
        let result = stack.perform(item, on: &state)
        #expect(result.recordedStepID != nil)
        #expect(names(state.image) == ["A", "C", "D", "B"])
        #expect(state.image.activeLayerIndex == 3)
        // No pixel copies: every layer keeps its id and tile storage (spec item 4).
        for layer in start.layers {
            let index = try #require(state.image.layerIndex(for: layer.id))
            let coordinate = TileCoordinate(column: 0, row: 0)
            let original = try #require(layer.surface.tile(at: coordinate))
            let moved = try #require(state.image.layers[index].surface.tile(at: coordinate))
            #expect(original.sharesStorage(with: moved), "layer \(layer.name) storage shared")
        }

        _ = stack.undo(&state)
        #expect(names(state.image) == ["A", "B", "C", "D"])
        #expect(state.image.activeLayerIndex == 1)
        _ = stack.redo(&state)
        #expect(names(state.image) == ["A", "C", "D", "B"])
        #expect(state.image.activeLayerIndex == 3)
    }

    /// A painted move round-trips pixels exactly (the snapshot shares tile storage).
    @Test func undoRestoresPaintedPixelsExactly() throws {
        var start = image(active: 0)
        start.layers[0].surface.setPixel(.black, at: PixelPoint(x: 3, y: 3))
        var state = DocumentState(image: start)
        var stack = HistoryStack(base: .openImage)
        let item = try #require(LayerMove.makeHistoryItem(from: 0, to: 3, for: state))
        _ = stack.perform(item, on: &state)
        #expect(state.image.layers[3].surface.pixel(at: PixelPoint(x: 3, y: 3)) == .black)
        _ = stack.undo(&state)
        #expect(state.image == start)
        _ = stack.redo(&state)
        #expect(state.image.layers[3].surface.pixel(at: PixelPoint(x: 3, y: 3)) == .black)
    }
}
