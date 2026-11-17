import Foundation
import Testing

@testable import PaintDotMac

/// `LayerPropertiesHistoryItem` (spec 0025 item 2): apply/revert round-trip on one layer,
/// the Paint.NET names, the no-op rule, cost/change — and the H-6 guarantee that a
/// property/visibility undo never moves the active layer.
struct LayerPropertiesHistoryItemTests {
    private func layered(nameCount: Int = 2, active: Int = 0,
                         selection: Selection? = nil) -> DocumentState {
        let size = PixelSize(width: 16, height: 16)
        let layers = (0..<nameCount).map { index in
            var surface = TiledSurface(size: size)
            surface.fill(ColorRGBA8(red: UInt8(index * 40), green: 10, blue: 200, alpha: 255))
            return Layer(name: "L\(index)", surface: surface)
        }
        return DocumentState(image: LayeredImage(size: size, layers: layers,
                                                 activeLayerIndex: active),
                             selection: selection)
    }

    @Test func applyRevertRoundTrip() throws {
        var state = layered(nameCount: 2)
        let layerID = state.image.layers[1].id
        let before = LayerProperties(name: "L", isVisible: true, opacity: 255, blendMode: .normal)
        let after = LayerProperties(name: "X", isVisible: false, opacity: 128, blendMode: .normal)
        let item = LayerPropertiesHistoryItem(name: "Layer Properties", icon: .layerProperties,
                                              layerID: layerID, before: before, after: after)
        let untouchedSurface = state.image.layers[0].surface

        item.apply(to: &state)
        let edited = state.image.layers[1]
        #expect(edited.properties == after)
        #expect(state.image.layers[1].id == layerID)
        // Layer 0 untouched, exactly equal, and pixels never move (storage shared).
        #expect(state.image.layers[0].properties
                    == LayerProperties(name: "L0", isVisible: true, opacity: 255,
                                       blendMode: .normal))
        for row in 0..<state.image.layers[0].surface.tileRows {
            for column in 0..<state.image.layers[0].surface.tileColumns {
                let coordinate = TileCoordinate(column: column, row: row)
                let left = untouchedSurface.tile(at: coordinate)
                let right = state.image.layers[0].surface.tile(at: coordinate)
                switch (left, right) {
                case (nil, nil): continue
                case let (left?, right?): #expect(left.sharesStorage(with: right))
                default: Issue.record("tile presence changed")
                }
            }
        }

        item.revert(&state)
        #expect(state.image.layers[1].properties == before)
    }

    @Test func visibilityNamesAndRoundTrip() {
        let id = Layer.ID()
        let shown = LayerProperties(name: "A", isVisible: true, opacity: 255, blendMode: .normal)
        var hidden = shown
        hidden.isVisible = false
        let hide = LayerPropertiesHistoryItem.visibility(layerID: id, before: shown, after: hidden)
        #expect(hide.name == "Hide Layer")
        #expect(hide.icon == .layerVisibility)
        let show = LayerPropertiesHistoryItem.visibility(layerID: id, before: hidden, after: shown)
        #expect(show.name == "Show Layer")
        #expect(show.icon == .layerVisibility)
        let properties = LayerPropertiesHistoryItem.properties(layerID: id, before: shown,
                                                               after: hidden)
        #expect(properties.name == "Layer Properties")
        #expect(properties.icon == .layerProperties)
    }

    @Test func noOpWhenEqual() {
        let id = Layer.ID()
        let value = LayerProperties(name: "A", isVisible: true, opacity: 9, blendMode: .normal)
        let item = LayerPropertiesHistoryItem.properties(layerID: id, before: value, after: value)
        #expect(item.isNoOp)

        var stack = HistoryStack(base: .openImage)
        var state = layered(nameCount: 2)
        let result = stack.perform(item, on: &state)
        // H-6: nothing recorded — no step id, no new step.
        #expect(result.recordedStepID == nil)
        #expect(stack.steps.count == 1)
    }

    @Test func costAndChange() {
        let id = Layer.ID()
        let before = LayerProperties(name: "A", isVisible: true, opacity: 255, blendMode: .normal)
        var after = before
        after.opacity = 1
        let item = LayerPropertiesHistoryItem.properties(layerID: id, before: before, after: after)
        #expect(item.byteCost == 0)
        #expect(item.change == .structure)
    }

    /// H-6 (spec acceptance): undoing a property or visibility step never changes the
    /// active layer or the selection — hide layer 0, click layer 2, ⌘Z: layer 0 shows
    /// again and layer 2 stays active.
    @Test func keepsActiveLayerAndSelection() throws {
        let selection = try #require(
            Selection(rect: CGRect(x: 2, y: 2, width: 6, height: 6),
                      canvasSize: PixelSize(width: 16, height: 16)))
        var state = layered(nameCount: 3, active: 2, selection: selection)
        let layerID = state.image.layers[0].id
        let before = state.image.layers[0].properties
        var after = before
        after.isVisible = false
        let item = LayerPropertiesHistoryItem.visibility(layerID: layerID, before: before,
                                                         after: after)
        var stack = HistoryStack(base: .openImage)
        _ = stack.perform(item, on: &state)
        #expect(state.image.activeLayerIndex == 2)
        #expect(state.image.layers[0].isVisible == false)

        _ = stack.undo(&state)
        #expect(state.image.activeLayerIndex == 2, "undo keeps the clicked layer active (H-6)")
        #expect(state.selection == selection)
        #expect(state.image.layers[0].isVisible == true)

        _ = stack.redo(&state)
        #expect(state.image.activeLayerIndex == 2)
        #expect(state.selection == selection)
    }
}
