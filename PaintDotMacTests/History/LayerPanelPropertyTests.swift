import Foundation
import Testing

@testable import PaintDotMac

/// Round-trip property test (spec 0025 *Test plan*): 100 seeded sessions of random
/// visibility toggles, property changes, and `LayerMove` steps through `HistoryStack`
/// over 1–6-layer images. Undo-all must restore the start state exactly (layer ids,
/// order, properties, and tile *storage*), redo-all the end state, and undoing a
/// property/visibility step must never move the active layer (H-6).
struct LayerPanelPropertyTests {
    @Test(arguments: 0..<100)
    func sessionsRoundTrip(index: Int) throws {
        var generator = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x1ACE57 + UInt64(index)))
        let comment = generator.comment
        let size = PixelSize(width: 32, height: 32)
        let count = Int(generator.next() % 6 + 1)
        let layers = (0..<count).map { layerIndex -> Layer in
            var surface = TiledSurface(size: size)
            // Half the layers start empty (sparse); the rest carry a few pixels.
            if generator.next() % 2 == 0 {
                for _ in 0..<8 {
                    let value = generator.next()
                    surface.setPixel(
                        ColorRGBA8(red: UInt8(truncatingIfNeeded: value),
                                   green: UInt8(truncatingIfNeeded: value >> 16),
                                   blue: UInt8(truncatingIfNeeded: value >> 32),
                                   alpha: 255),
                        at: PixelPoint(x: Int(value % 32), y: Int((value >> 8) % 32)))
                }
            }
            return Layer(name: "L\(layerIndex)", surface: surface,
                         isVisible: generator.next() % 4 != 0)
        }
        var state = DocumentState(image: LayeredImage(size: size, layers: layers,
                                                      activeLayerIndex: Int(generator.next() % UInt64(count))))
        let start = state
        var stack = HistoryStack(base: .openImage)

        // A random sequence of the panel's three kinds of steps, each built from the
        // *current* state exactly like the panel does.
        enum Kind: Equatable { case visibility, properties, move }
        var performed: [Kind] = []
        for _ in 0..<12 {
            switch generator.next() % 3 {
            case 0: // visibility toggle
                let index = Int(generator.next() % UInt64(state.image.layers.count))
                guard let item = LayerListModel(image: state.image)
                    .visibilityToggle(forLayerIndex: index, in: state.image) else { continue }
                _ = stack.perform(item, on: &state)
                performed.append(.visibility)
            case 1: // property change
                let index = Int(generator.next() % UInt64(state.image.layers.count))
                let layer = state.image.layers[index]
                var after = layer.properties
                after.name += "•"          // never equal → never a no-op
                after.opacity = UInt8(generator.next() % 256)
                let item = LayerPropertiesHistoryItem.properties(layerID: layer.id,
                                                                 before: layer.properties,
                                                                 after: after)
                _ = stack.perform(item, on: &state)
                performed.append(.properties)
            default: // drag reorder
                let layerCount = state.image.layers.count
                guard layerCount > 1 else { continue }
                let from = Int(generator.next() % UInt64(layerCount))
                let to = Int(generator.next() % UInt64(layerCount))
                guard let item = LayerMove.makeHistoryItem(from: from, to: to, for: state)
                else { continue }
                _ = stack.perform(item, on: &state)
                performed.append(.move)
            }
        }
        let end = state
        try #require(!performed.isEmpty, "fixture keeps progress \(comment)")

        // Undo everything. Property/visibility undos must keep the active layer (H-6).
        while stack.canUndo {
            let isPropertyStep = performed.last == .visibility || performed.last == .properties
            let activeBeforeUndo = state.image.activeLayerIndex
            _ = stack.undo(&state)
            if isPropertyStep {
                #expect(state.image.activeLayerIndex == activeBeforeUndo,
                        "undoing a property/visibility step moved the active layer (\(comment))")
            }
            performed.removeLast()
        }
        assertEqualStates(state, start, comment)

        // Redo everything.
        while stack.canRedo {
            _ = stack.redo(&state)
        }
        assertEqualStates(state, end, comment)
    }

    /// Ids, order, properties, pixel values, and *tile storage* all equal.
    private func assertEqualStates(_ state: DocumentState, _ expected: DocumentState,
                                   _ comment: Comment,
                                   sourceLocation: SourceLocation = #_sourceLocation) {
        let got = state.image
        let want = expected.image
        #expect(got.layers.map(\.id) == want.layers.map(\.id), "layer ids \(comment)",
                sourceLocation: sourceLocation)
        #expect(got.activeLayerIndex == want.activeLayerIndex, "active index \(comment)",
                sourceLocation: sourceLocation)
        #expect(state.selection == expected.selection, "selection \(comment)",
                sourceLocation: sourceLocation)
        #expect(state.floatingPixels == nil, "floating pixels \(comment)",
                sourceLocation: sourceLocation)
        for (index, layer) in want.layers.enumerated() {
            let other = got.layers[index]
            #expect(other.properties == layer.properties, "properties \(index) \(comment)",
                    sourceLocation: sourceLocation)
            let surface = layer.surface
            for row in 0..<surface.tileRows {
                for column in 0..<surface.tileColumns {
                    let coordinate = TileCoordinate(column: column, row: row)
                    let lhs = surface.tile(at: coordinate)
                    let rhs = other.surface.tile(at: coordinate)
                    switch (lhs, rhs) {
                    case (nil, nil): continue
                    case let (lhs?, rhs?):
                        #expect(lhs.sharesStorage(with: rhs),
                                "tile \(coordinate) storage \(comment)",
                                sourceLocation: sourceLocation)
                    default:
                        Issue.record("tile \(coordinate) presence differs \(comment)",
                                     sourceLocation: sourceLocation)
                    }
                }
            }
        }
    }
}
