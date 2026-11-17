import Foundation
import Testing

@testable import PaintDotMac

/// `LayerCommand.applied(to:)` (spec 0024 L-1 / IMG-5): names, icons, the enablement
/// table, and the exact stack/pixel/identity effects of every command. Hand values come
/// from 0009's Normal formula.
struct LayerOperationsTests {
    // MARK: - Fixtures

    private func solid(_ color: ColorRGBA8, width: Int = 64, height: Int = 64,
                       name: String = "Background") -> Layer {
        Layer(name: name, surface: LayeredImage.blank(size: PixelSize(width: width, height: height),
                                                      fill: color).layers[0].surface)
    }

    private func image(_ layers: [Layer], active: Int) -> LayeredImage {
        LayeredImage(size: layers[0].size, layers: layers, activeLayerIndex: active)
    }

    /// A seeded layer with real pixels.
    private func seeded(_ name: String, seed: UInt64, width: Int = 64, height: Int = 64,
                        isVisible: Bool = true, opacity: UInt8 = 255) -> Layer {
        var random = SeededRandom(seed: seed)
        let surface = TestImages.surface(width: width, height: height) { _, _ in random.color() }
        return Layer(name: name, surface: surface, isVisible: isVisible, opacity: opacity)
    }

    /// Untouched layers keep their `id` and share every allocated tile's storage.
    private func expectShares(before: Layer, after: Layer, _ comment: String = "",
                              sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(before.id == after.id, "layer identity \(comment)",
                sourceLocation: sourceLocation)
        for coordinate in before.surface.allocatedTileCoordinates {
            guard let oldTile = before.surface.tile(at: coordinate),
                  let newTile = after.surface.tile(at: coordinate) else {
                Issue.record("tile \(coordinate) vanished (\(comment))",
                             sourceLocation: sourceLocation)
                continue
            }
            #expect(oldTile.sharesStorage(with: newTile),
                    "tile \(coordinate) copied (\(comment))", sourceLocation: sourceLocation)
        }
    }

    private func expectConsistent(_ result: LayeredImage?, from before: LayeredImage,
                                  sourceLocation: SourceLocation = #_sourceLocation) throws {
        let image = try #require(result, sourceLocation: sourceLocation)
        #expect(image.isConsistent, sourceLocation: sourceLocation)
        #expect(image.size == before.size, sourceLocation: sourceLocation)
        #expect(image.dpi == before.dpi, sourceLocation: sourceLocation)
    }

    // MARK: - Names, icons, enablement

    @Test func namesAndIcons() {
        #expect(LayerCommand.allCases == [.addNewLayer, .deleteLayer, .duplicateLayer,
                                          .mergeLayerDown, .moveLayerUp, .moveLayerDown, .flatten])
        let expected: [(LayerCommand, String, HistoryIcon)] = [
            (.addNewLayer, "Add New Layer", .layerAdd),
            (.deleteLayer, "Delete Layer", .layerDelete),
            (.duplicateLayer, "Duplicate Layer", .layerDuplicate),
            (.mergeLayerDown, "Merge Layer Down", .layerMerge),
            (.moveLayerUp, "Move Layer Up", .layerMove),
            (.moveLayerDown, "Move Layer Down", .layerMove),
            (.flatten, "Flatten", .flatten),
        ]
        for (command, name, icon) in expected {
            #expect(command.name == name)
            #expect(command.icon == icon)
        }
    }

    @Test func enablementTable() {
        let one = image([solid(.white)], active: 0)
        let three = image([solid(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)), solid(ColorRGBA8(red: 0, green: 200, blue: 0, alpha: 255)), solid(ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255))], active: 1)
        let bottom = image([solid(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)), solid(ColorRGBA8(red: 0, green: 200, blue: 0, alpha: 255)), solid(ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255))], active: 0)
        let top = image([solid(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)), solid(ColorRGBA8(red: 0, green: 200, blue: 0, alpha: 255)), solid(ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255))], active: 2)
        func state(_ image: LayeredImage) -> DocumentState { DocumentState(image: image) }
        for command in LayerCommand.allCases {
            let n1 = command.isEnabled(in: state(one))
            let middle = command.isEnabled(in: state(three))
            let first = command.isEnabled(in: state(bottom))
            let last = command.isEnabled(in: state(top))
            switch command {
            case .addNewLayer, .duplicateLayer:
                #expect(n1 && middle && first && last, "\(command.rawValue)")
            case .deleteLayer, .flatten:
                #expect(!n1 && middle && first && last, "\(command.rawValue)")
            case .mergeLayerDown, .moveLayerDown:
                #expect(!n1 && middle && !first && last, "\(command.rawValue)")
            case .moveLayerUp:
                #expect(!n1 && middle && first && !last, "\(command.rawValue)")
            }
        }
    }

    // MARK: - Add New Layer

    @Test func addInsertsAboveActive() throws {
        let before = image([solid(.white, width: 300, height: 200)], active: 0)
        let after = try #require(LayerCommand.addNewLayer.applied(to: before))
        try expectConsistent(after, from: before)
        #expect(after.layers.count == 2)
        let added = after.layers[1]
        #expect(added.name == "Layer 2")
        #expect(added.surface.allocatedTileCount == 0)
        #expect(added.surface.pixel(at: PixelPoint(x: 0, y: 0)) == .clear)
        #expect(added.surface.pixel(at: PixelPoint(x: 299, y: 199)) == .clear)
        #expect(added.isVisible && added.opacity == 255 && added.blendMode == .normal)
        #expect(added.id != before.layers[0].id)
        #expect(after.activeLayerIndex == 1)
        expectShares(before: before.layers[0], after: after.layers[0])
    }

    @Test func addFromMiddle() throws {
        let before = image([solid(.white, name: "A"), solid(.black, name: "B"),
                            seeded("C", seed: 7)], active: 0)
        let after = try #require(LayerCommand.addNewLayer.applied(to: before))
        try expectConsistent(after, from: before)
        #expect(after.layers.map(\.name) == ["A", "Layer 4", "B", "C"])
        #expect(after.activeLayerIndex == 1)
        #expect(after.layers[2].id == before.layers[1].id)
        expectShares(before: before.layers[1], after: after.layers[2])
        expectShares(before: before.layers[2], after: after.layers[3])
    }

    // MARK: - Delete Layer

    @Test func deleteTopActivatesBelow() throws {
        let before = image([solid(.white, name: "A"), solid(.black, name: "B"),
                            seeded("C", seed: 8)], active: 2)
        let after = try #require(LayerCommand.deleteLayer.applied(to: before))
        try expectConsistent(after, from: before)
        #expect(after.layers.map(\.id) == [before.layers[0].id, before.layers[1].id])
        #expect(after.activeLayerIndex == 1)
    }

    @Test func deleteMiddle() throws {
        let before = image([solid(.white, name: "A"), solid(.black, name: "B"),
                            seeded("C", seed: 9)], active: 1)
        let after = try #require(LayerCommand.deleteLayer.applied(to: before))
        try expectConsistent(after, from: before)
        #expect(after.layers.map(\.id) == [before.layers[0].id, before.layers[2].id])
        #expect(after.activeLayerIndex == 0)
    }

    @Test func deleteBottomActivatesNewBottom() throws {
        let before = image([solid(.white, name: "A"), solid(.black, name: "B"),
                            seeded("C", seed: 10)], active: 0)
        let after = try #require(LayerCommand.deleteLayer.applied(to: before))
        try expectConsistent(after, from: before)
        #expect(after.layers.map(\.id) == [before.layers[1].id, before.layers[2].id])
        #expect(after.activeLayerIndex == 0)
    }

    @Test func deleteDisabledWithOneLayer() {
        let single = image([solid(.white)], active: 0)
        #expect(LayerCommand.deleteLayer.applied(to: single) == nil)
        #expect(LayerCommand.deleteLayer.makeHistoryItem(for: DocumentState(image: single)) == nil)
    }

    // MARK: - Duplicate Layer

    @Test func duplicateCopiesAbove() throws {
        let ink = seeded("Ink", seed: 0x1234, isVisible: false, opacity: 77)
        let before = image([ink, solid(.black, name: "Other")], active: 0)
        let after = try #require(LayerCommand.duplicateLayer.applied(to: before))
        try expectConsistent(after, from: before)
        #expect(after.layers.count == 3)
        let copy = after.layers[1]
        #expect(copy.name == "Ink copy")
        #expect(copy.opacity == 77)
        #expect(!copy.isVisible)
        #expect(copy.blendMode == .normal)
        #expect(copy.surface == ink.surface)
        for coordinate in ink.surface.allocatedTileCoordinates {
            #expect(ink.surface.tile(at: coordinate)!.sharesStorage(with: copy.surface.tile(at: coordinate)!),
                    "tile \(coordinate) not shared")
        }
        #expect(copy.id != ink.id)
        #expect(after.activeLayerIndex == 1)
        #expect(after.layers[2].id == before.layers[1].id)
    }

    // MARK: - Merge Layer Down

    private func flat(_ color: ColorRGBA8, name: String, isVisible: Bool = true,
                      opacity: UInt8 = 255) -> Layer {
        var surface = TiledSurface(size: PixelSize(width: 4, height: 4))
        surface.fill(color)
        return Layer(name: name, surface: surface, isVisible: isVisible, opacity: opacity)
    }

    @Test func mergeDownHandValues() throws {
        // (0,0,255,128) over (255,0,0,255): fa = 128·255 + 255·127 = 65025,
        // outA 255, r = (255·255·127 + fa/2)/fa = 127, b = (255·128·255 + fa/2)/fa = 128.
        let lower = flat(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255),
                         name: "Lower", isVisible: false, opacity: 200)
        let upper = flat(ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 128), name: "Upper")
        let before = image([lower, upper], active: 1)
        let after = try #require(LayerCommand.mergeLayerDown.applied(to: before))
        try expectConsistent(after, from: before)
        #expect(after.layers.count == 1)
        let merged = after.layers[0]
        #expect(merged.surface.pixel(at: PixelPoint(x: 2, y: 2))
                == ColorRGBA8(red: 127, green: 0, blue: 128, alpha: 255))
        #expect(merged.name == "Lower")
        #expect(merged.opacity == 200)
        #expect(!merged.isVisible)
        #expect(merged.id == lower.id)
        #expect(after.activeLayerIndex == 0)
    }

    @Test func mergeDownUsesUpperOpacity() throws {
        let lower = flat(.white, name: "Lower")
        let upper = flat(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255),
                         name: "Upper", opacity: 128)
        let after = try #require(LayerCommand.mergeLayerDown
            .applied(to: image([lower, upper], active: 1)))
        #expect(after.layers[0].surface.pixel(at: PixelPoint(x: 1, y: 1))
                == ColorRGBA8(red: 255, green: 127, blue: 127, alpha: 255))
    }

    @Test func mergeDownTwoSemiTransparent() throws {
        // (0,0,255,128) over (255,0,0,128): fa = 128·255 + 128·127 = 48896,
        // outA = (48896+127)/255 = 192, r = 85, b = 170.
        let lower = flat(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 128), name: "Lower")
        let upper = flat(ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 128), name: "Upper")
        let after = try #require(LayerCommand.mergeLayerDown
            .applied(to: image([lower, upper], active: 1)))
        #expect(after.layers[0].surface.pixel(at: PixelPoint(x: 0, y: 0))
                == ColorRGBA8(red: 85, green: 0, blue: 170, alpha: 192))
    }

    @Test func mergeDownHiddenUpperStillMerges() throws {
        // Paint.NET 3.36 renders the upper layer regardless of its visibility (D-51).
        let lower = flat(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255), name: "Lower")
        let upper = flat(ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255), name: "Upper",
                         isVisible: false)
        let after = try #require(LayerCommand.mergeLayerDown
            .applied(to: image([lower, upper], active: 1)))
        #expect(after.layers[0].surface.pixel(at: PixelPoint(x: 3, y: 3))
                == ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255))
    }

    @Test func mergeDownDisabledAtBottom() {
        let before = image([solid(.white), solid(.black)], active: 0)
        #expect(LayerCommand.mergeLayerDown.applied(to: before) == nil)
        #expect(LayerCommand.mergeLayerDown
            .makeHistoryItem(for: DocumentState(image: before)) == nil)
    }

    @Test func mergeDownMiddleOfThree() throws {
        let before = image([seeded("A", seed: 11), seeded("B", seed: 12), seeded("C", seed: 13)],
                           active: 2)
        let after = try #require(LayerCommand.mergeLayerDown.applied(to: before))
        try expectConsistent(after, from: before)
        #expect(after.layers.count == 2)
        #expect(after.layers[0].id == before.layers[0].id)
        #expect(after.layers[1].id == before.layers[1].id)   // keeps the LOWER identity
        #expect(after.activeLayerIndex == 1)
        expectShares(before: before.layers[0], after: after.layers[0], "layer 0 untouched")
    }

    // MARK: - Move Layer Up / Down

    @Test func moveUp() throws {
        let a = solid(.white, name: "A"), b = solid(.black, name: "B"), c = seeded("C", seed: 14)
        let after = try #require(LayerCommand.moveLayerUp.applied(to: image([a, b, c], active: 1)))
        try expectConsistent(after, from: image([a, b, c], active: 1))
        #expect(after.layers.map(\.id) == [a.id, c.id, b.id])
        #expect(after.activeLayerIndex == 2)
    }

    @Test func moveDown() throws {
        let a = solid(.white, name: "A"), b = solid(.black, name: "B"), c = seeded("C", seed: 15)
        let after = try #require(LayerCommand.moveLayerDown.applied(to: image([a, b, c], active: 1)))
        #expect(after.layers.map(\.id) == [b.id, a.id, c.id])
        #expect(after.activeLayerIndex == 0)
    }

    @Test func moveDisabledAtEnds() {
        let bottom = image([solid(.white), solid(.black)], active: 0)
        let top = image([solid(.white), solid(.black)], active: 1)
        #expect(LayerCommand.moveLayerDown.applied(to: bottom) == nil)
        #expect(LayerCommand.moveLayerUp.applied(to: top) == nil)
    }

    // MARK: - Flatten

    @Test func flattenThreeLayers() throws {
        let bottom = solid(.white, width: 300, height: 200, name: "Background")
        let middle = solid(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255),
                           width: 300, height: 200, name: "Red").modified { $0.opacity = 128 }
        let top = solid(ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255),
                        width: 300, height: 200, name: "Blue").modified { $0.isVisible = false }
        let before = image([bottom, middle, top], active: 1)
        let after = try #require(LayerCommand.flatten.applied(to: before))
        try expectConsistent(after, from: before)
        #expect(after.layers.count == 1)
        let flatLayer = after.layers[0]
        // White ⊕ red@128 = (255, 127, 127, 255); the hidden layer is discarded.
        #expect(flatLayer.surface.pixel(at: PixelPoint(x: 299, y: 199))
                == ColorRGBA8(red: 255, green: 127, blue: 127, alpha: 255))
        #expect(flatLayer.name == "Background")
        #expect(flatLayer.id == bottom.id)
        #expect(flatLayer.isVisible && flatLayer.opacity == 255 && flatLayer.blendMode == .normal)
        #expect(after.activeLayerIndex == 0)
        #expect(flatLayer.surface == CPUCompositor().flattened(before))
    }

    @Test func flattenUsesBottomName() throws {
        let before = image([solid(.white, name: "Base"), solid(.black, name: "Top")], active: 1)
        let after = try #require(LayerCommand.flatten.applied(to: before))
        #expect(after.layers[0].name == "Base")
    }

    @Test func flattenAllHidden() throws {
        var hidden1 = solid(.white, name: "A")
        hidden1.isVisible = false
        var hidden2 = solid(.black, name: "B")
        hidden2.isVisible = false
        let after = try #require(LayerCommand.flatten.applied(to: image([hidden1, hidden2], active: 1)))
        #expect(after.layers[0].surface.allocatedTileCount == 0)
    }

    @Test func flattenDisabledWithOneLayer() {
        let single = image([solid(.white)], active: 0)
        #expect(LayerCommand.flatten.applied(to: single) == nil)
        #expect(LayerCommand.flatten.makeHistoryItem(for: DocumentState(image: single)) == nil)
    }
}

private extension Layer {
    /// A property-tweaked copy (fixtures).
    func modified(_ body: (inout Layer) -> Void) -> Layer {
        var copy = self
        body(&copy)
        return copy
    }
}
