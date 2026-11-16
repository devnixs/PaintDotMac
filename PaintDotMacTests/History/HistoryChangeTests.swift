import Foundation
import Testing

@testable import PaintDotMac

/// The `HistoryChange` merge table with the 0013 selection cases.
struct HistoryChangeTests {
    private let layerA = UUID()
    private let layerB = UUID()

    private var pixels1: HistoryChange { .pixels([layerA: [TileCoordinate(column: 0, row: 0)]]) }
    private var pixels2: HistoryChange {
        .pixels([layerA: [TileCoordinate(column: 1, row: 0)],
                 layerB: [TileCoordinate(column: 0, row: 1)]])
    }
    private var selection: HistoryChange { .selection }
    private var pixelsAndSelection: HistoryChange {
        .pixelsAndSelection([layerA: [TileCoordinate(column: 0, row: 1)]])
    }
    private var structure: HistoryChange { .structure }

    private var allCases: [HistoryChange] {
        [pixels1, pixels2, selection, pixelsAndSelection, structure]
    }

    @Test func mergeTable() throws {
        let unioned = HistoryChange.pixels([
            layerA: [TileCoordinate(column: 0, row: 0), TileCoordinate(column: 1, row: 0)],
            layerB: [TileCoordinate(column: 0, row: 1)],
        ])

        for lhs in allCases {
            for rhs in allCases {
                let merged = lhs.merged(with: rhs)
                #expect(merged == rhs.merged(with: lhs), "symmetric: \(lhs) + \(rhs)")
                switch (lhs, rhs) {
                case (.structure, _), (_, .structure):
                    #expect(merged == .structure, "\(lhs) + \(rhs)")
                case (.pixels, .pixels):
                    let left = lhs.pixelTiles ?? [:]
                    let right = rhs.pixelTiles ?? [:]
                    var expected = left
                    for (id, tiles) in right { expected[id, default: []].formUnion(tiles) }
                    #expect(merged == .pixels(expected), "pixels ∪ pixels per layer: \(lhs) + \(rhs)")
                case (.selection, .selection):
                    #expect(merged == .selection)
                case (.selection, .pixels), (.pixels, .selection):
                    #expect(merged.pixelTiles != nil, "pixels + selection → pixelsAndSelection")
                    if case .pixelsAndSelection = merged {} else {
                        Issue.record("\(lhs) + \(rhs) must be .pixelsAndSelection")
                    }
                case (.pixelsAndSelection, .selection), (.selection, .pixelsAndSelection):
                    if case .pixelsAndSelection = merged {} else {
                        Issue.record("\(lhs) + \(rhs) must stay .pixelsAndSelection")
                    }
                case (.pixelsAndSelection, .pixels), (.pixels, .pixelsAndSelection):
                    let left = lhs.pixelTiles ?? [:]
                    let right = rhs.pixelTiles ?? [:]
                    var expected = left
                    for (id, tiles) in right { expected[id, default: []].formUnion(tiles) }
                    if case .pixelsAndSelection(let tiles) = merged {
                        #expect(tiles == expected, "pixelsAndSelection ∪ pixels: \(lhs) + \(rhs)")
                    } else {
                        Issue.record("\(lhs) + \(rhs) must stay .pixelsAndSelection")
                    }
                case (.pixelsAndSelection, .pixelsAndSelection):
                    let left = lhs.pixelTiles ?? [:]
                    let right = rhs.pixelTiles ?? [:]
                    var expected = left
                    for (id, tiles) in right { expected[id, default: []].formUnion(tiles) }
                    if case .pixelsAndSelection(let tiles) = merged {
                        #expect(tiles == expected, "tiles union: \(lhs) + \(rhs)")
                    } else {
                        Issue.record("must stay .pixelsAndSelection")
                    }
                default:
                    Issue.record("unhandled pair \(lhs) + \(rhs)")
                }
            }
        }
        // Concrete spot checks.
        #expect(pixels1.merged(with: pixels2) == unioned)
        #expect(pixels1.merged(with: selection)
                == .pixelsAndSelection([layerA: [TileCoordinate(column: 0, row: 0)]]))
        #expect(pixelsAndSelection.merged(with: selection) == pixelsAndSelection)
    }

    @Test func affectsSelectionAndPixelTiles() {
        #expect(pixels1.affectsSelection == false)
        #expect(selection.affectsSelection == true)
        #expect(pixelsAndSelection.affectsSelection == true)
        #expect(structure.affectsSelection == true)

        #expect(pixels1.pixelTiles == [layerA: [TileCoordinate(column: 0, row: 0)]])
        #expect(pixelsAndSelection.pixelTiles == [layerA: [TileCoordinate(column: 0, row: 1)]])
        #expect(selection.pixelTiles == nil)
        #expect(structure.pixelTiles == nil)
    }
}
