import Foundation
import Testing

@testable import PaintDotMac

/// `StrokeCoverageBuffer` (spec 0009): per-canvas-row coverage rows, absent row = all 0,
/// `raise` keeps the maximum, `touchedTiles` reports the tiles (`x >> 8`, `row`) of every
/// raised pixel.
struct StrokeCoverageBufferTests {
    @Test func absentRowsReadZeroAndRaiseKeepsMax() {
        var buffer = StrokeCoverageBuffer()
        #expect(buffer.coverage(x: 0, y: 0) == 0)
        #expect(buffer.coverage(x: 1000, y: 700) == 0)
        #expect(buffer.touchedTiles.isEmpty)

        let raised = buffer.raise(x: 300, y: 260, to: 40)
        #expect(raised)
        #expect(buffer.coverage(x: 300, y: 260) == 40)
        let equal = buffer.raise(x: 300, y: 260, to: 40)
        #expect(!equal, "equal cannot raise")
        let lower = buffer.raise(x: 300, y: 260, to: 39)
        #expect(!lower, "lower cannot raise")
        let higher = buffer.raise(x: 300, y: 260, to: 41)
        #expect(higher)
        #expect(buffer.coverage(x: 300, y: 260) == 41)
        #expect(buffer.coverage(x: 301, y: 260) == 0, "neighbours stay 0")
        #expect(buffer.touchedTiles == [TileCoordinate(column: 1, row: 1)],
                "one tile touched at (300, 260)")
    }

    @Test func rowsArePerCoordinateAndRemoveAllClears() {
        var buffer = StrokeCoverageBuffer()
        buffer.raise(x: 5, y: 5, to: 200)                       // tile (0,0)
        buffer.raise(x: 515, y: 5, to: 128)                     // tile (2,0)
        #expect(buffer.touchedTiles
                    == Set([TileCoordinate(column: 0, row: 0), TileCoordinate(column: 2, row: 0)]))
        buffer.removeAll()
        #expect(buffer.coverage(x: 5, y: 5) == 0)
        #expect(buffer.coverage(x: 515, y: 5) == 0)
        #expect(buffer.touchedTiles.isEmpty)
    }
}
