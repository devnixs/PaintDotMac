import Foundation
import Testing

@testable import PaintDotMac

struct HistoryItemTests {
    private func coord(_ column: Int, _ row: Int) -> TileCoordinate {
        TileCoordinate(column: column, row: row)
    }

    private func whiteImage(_ width: Int, _ height: Int, layers: Int = 1) -> LayeredImage {
        let surfaces: [TiledSurface] = (0..<layers).map { _ in
            var surface = TiledSurface(size: PixelSize(width: width, height: height))
            surface.fill(.white)
            return surface
        }
        return LayeredImage(size: PixelSize(width: width, height: height), layers: surfaces.map {
            Layer(name: "Layer", surface: $0)
        }, activeLayerIndex: 0)
    }

    @Test func tileDiffItemForwards() throws {
        let before = whiteImage(512, 512)
        var after = before
        let layerID = try #require(before.layers.first?.id)
        fillRect(&after, layer: 0, rect: PixelRect(x: 10, y: 10, width: 20, height: 20),
                 color: .black)
        let diff = try TileDiff.between(before: before, after: after)
        let item = TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush, diff: diff)
        #expect(item.name == "Paintbrush")
        #expect(item.icon == .paintbrush)
        #expect(item.byteCost == 524_288)
        #expect(item.change == .pixels([layerID: [coord(0, 0)]]))
        #expect(item.isNoOp == false)

        let emptyDiff = try TileDiff.between(before: before, after: before)
        let noOp = TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush, diff: emptyDiff)
        #expect(noOp.isNoOp, "an empty diff is a no-op (H-6)")
        #expect(noOp.byteCost == 0)
    }

    @Test func snapshotItemRoundTrip() throws {
        let beforeImage = whiteImage(400, 300)

        var afterSurfaces: [TiledSurface] = []
        for _ in 0..<2 {
            var surface = TiledSurface(size: PixelSize(width: 512, height: 512))
            surface.fill(.white)
            afterSurfaces.append(surface)
        }
        var afterImage = LayeredImage(
            size: PixelSize(width: 512, height: 512),
            layers: [
                Layer(name: "Background", surface: afterSurfaces[0]),
                Layer(name: "Layer 2", surface: afterSurfaces[1]),
            ],
            activeLayerIndex: 0
        )
        afterImage.activeLayerIndex = 1

        let before = DocumentState(image: beforeImage)
        let after = DocumentState(image: afterImage)
        let item = DocumentSnapshotHistoryItem(name: "Add New Layer", icon: .layerAdd,
                                              before: before, after: after)
        // 4 before buffers (one shared interior + three distinct edge tiles) + 2 after
        // buffers (one shared fill per layer), none shared across the states.
        #expect(item.byteCost == (4 + 2) * 262_144)
        #expect(item.change == .structure)
        #expect(item.isNoOp == false)

        var state = after
        item.revert(&state)
        #expect(state.image.size == PixelSize(width: 400, height: 300))
        #expect(state.image.layers.count == 1)
        #expect(state.image.layers[0].name == "Layer")
        #expect(state.image.activeLayerIndex == 0)
        assertMatches(state.image, ReferenceCanvas(image: beforeImage), "revert restores pixels")

        item.apply(to: &state)
        #expect(state.image == afterImage, "apply restores the after state exactly")
    }

    @Test func compositeOrder() throws {
        let before = whiteImage(512, 512)
        let red = ColorRGBA8(red: 255, green: 0, blue: 0)
        let blue = ColorRGBA8(red: 0, green: 0, blue: 255)
        let layerID = try #require(before.layers.first?.id)

        var mid = before
        fillRect(&mid, layer: 0, rect: PixelRect(x: 10, y: 10, width: 20, height: 20), color: red)
        var last = mid
        fillRect(&last, layer: 0, rect: PixelRect(x: 10, y: 10, width: 20, height: 20), color: blue)

        let diffA = try TileDiff.between(before: before, after: mid)
        let diffB = try TileDiff.between(before: mid, after: last)
        let itemA = TileDiffHistoryItem(name: "A", icon: .paintbrush, diff: diffA)
        let itemB = TileDiffHistoryItem(name: "B", icon: .paintbrush, diff: diffB)
        let composite = CompositeHistoryItem(name: "Paintbrush", icon: .paintbrush,
                                            items: [itemA, itemB])

        var state = DocumentState(image: before)
        composite.apply(to: &state)
        #expect(state.image.layers[0].surface.pixel(at: PixelPoint(x: 15, y: 15)) == blue,
                "apply runs items in order")
        composite.revert(&state)
        #expect(state.image.layers[0].surface.pixel(at: PixelPoint(x: 15, y: 15)) == .white,
                "revert runs items in reverse order")
        assertMatches(state.image, ReferenceCanvas(image: before), "composite round trip")

        #expect(composite.byteCost == diffA.byteCost + diffB.byteCost)
        #expect(composite.change == .pixels([layerID: [coord(0, 0)]]),
                "merged change of both diffs")
        #expect(composite.isNoOp == false)
    }

    @Test func compositeEmptyIsNoOp() {
        let composite = CompositeHistoryItem(name: "Move Selection", icon: .moveSelection,
                                            items: [])
        #expect(composite.isNoOp)
        #expect(composite.byteCost == 0)
    }

    @Test func compositeOfNoOpsIsNoOp() throws {
        let image = whiteImage(512, 512)
        let empty = try TileDiff.between(before: image, after: image)
        let a = TileDiffHistoryItem(name: "A", icon: .paintbrush, diff: empty)
        let b = TileDiffHistoryItem(name: "B", icon: .eraser, diff: empty)
        let composite = CompositeHistoryItem(name: "Step", icon: .generic, items: [a, b])
        #expect(composite.isNoOp, "an all-no-op composite is a no-op")
    }

    @Test func historyChangeMerging() {
        let layerA = UUID()
        let layerB = UUID()
        let left = HistoryChange.pixels([layerA: [coord(0, 0)], layerB: [coord(1, 1)]])
        let right = HistoryChange.pixels([layerA: [coord(1, 0)], layerB: [coord(1, 1)]])
        #expect(left.merged(with: right)
                == .pixels([layerA: [coord(0, 0), coord(1, 0)], layerB: [coord(1, 1)]]),
                "pixels ∪ pixels unions per layer")
        #expect(left.merged(with: .structure) == .structure)
        #expect(HistoryChange.structure.merged(with: right) == .structure)
        #expect(HistoryChange.structure.merged(with: .structure) == .structure)
    }

    @Test func historyIconRawValues() throws {
        let all = HistoryIcon.allCases
        #expect(Set(all.map(\.rawValue)).count == all.count, "raw values are unique")
        for icon in all {
            #expect(icon.rawValue == String(describing: icon),
                    "raw value equals the case name (\(icon))")
        }
        let toolCases: [HistoryIcon] = [
            .rectangleSelect, .lassoSelect, .ellipseSelect, .magicWand, .moveSelectedPixels,
            .moveSelection, .paintBucket, .gradient, .paintbrush, .eraser, .pencil,
            .cloneStamp, .recolor, .text, .lineCurve, .shapes,
        ]
        for icon in toolCases {
            #expect(ToolID(rawValue: icon.rawValue) != nil,
                    "\(icon.rawValue) is a ToolID raw value")
        }
        for tool in [ToolID.colorPicker, .zoom, .pan] {
            #expect(HistoryIcon(rawValue: tool.rawValue) == nil,
                    "\(tool.rawValue) never records steps")
        }
    }

    @Test func tileDiffKeepsActiveLayer() throws {
        // H-6 / D-34: a diff on layer 0 never touches `activeLayerIndex`.
        var image = whiteImage(512, 512, layers: 2)
        image.activeLayerIndex = 1
        var edited = image
        fillRect(&edited, layer: 0, rect: PixelRect(x: 10, y: 10, width: 20, height: 20),
                 color: .black)
        let diff = try TileDiff.between(before: image, after: edited)
        #expect(diff.entries.count == 1)

        var state = DocumentState(image: edited)
        diff.revert(&state.image)
        #expect(state.image.activeLayerIndex == 1, "undo does not switch layers")
        diff.apply(to: &state.image)
        #expect(state.image.activeLayerIndex == 1, "redo does not switch layers")
    }
}
