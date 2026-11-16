import Foundation
import Testing

@testable import PaintDotMac

/// `SelectionMask` tile algebra, normalization, bounds, and the `BrushClipMask` hook
/// (spec 0013 *Test plan*). The oracle is `ReferenceMask`, computed from the tests' own
/// coverage grids.
struct SelectionMaskTests {
    private static let seed: UInt64 = 0x0013_0013_0013_0013

    private func randomGrid(_ rng: inout SeededRandom, width: Int, height: Int) -> [UInt8] {
        (0..<(width * height)).map { _ in rng.byte() }
    }

    /// A seeded random mask plus its reference oracle (out-of-canvas coverage 0 on both).
    private func randomPair(_ rng: inout SeededRandom, size: PixelSize)
        -> (SelectionMask, ReferenceMask) {
        let grid = randomGrid(&rng, width: size.width, height: size.height)
        let mask = SelectionMask(size: size) { x, y in grid[y * size.width + x] }
        let reference = ReferenceMask(size: size) { x, y in grid[y * size.width + x] }
        return (mask, reference)
    }

    @Test func emptyAndFull() {
        let size = PixelSize(width: 300, height: 300)
        let empty = SelectionMask(size: size)
        #expect(empty.isEmpty)
        #expect(empty.bounds == .zero)
        #expect(empty.coverage(x: 299, y: 299) == 0)
        #expect(empty.partialTileCount == 0)
        #expect(empty.tileStorageIdentities.isEmpty)

        let full = SelectionMask.full(size: size)
        #expect(full.isFull)
        #expect(full.coverage(x: 299, y: 299) == 255)
        #expect(full.coverage(x: 300, y: 0) == 0, "outside size is 0")
        #expect(full.coverage(x: -1, y: 0) == 0)
        #expect(full.bounds == PixelRect(x: 0, y: 0, width: 300, height: 300))
        #expect(full.partialTileCount == 0)
        #expect(full.tileStorageIdentities.isEmpty)
    }

    @Test func normalization() {
        let all255 = SelectionMask(size: PixelSize(width: 300, height: 300)) { _, _ in 255 }
        #expect(all255.isFull, "every tile normalizes to .full")
        #expect(all255.tiles.allSatisfy { if case .full = $0 { return true }; return false })

        let all0 = SelectionMask(size: PixelSize(width: 300, height: 300)) { _, _ in 0 }
        #expect(all0.isEmpty, "every tile normalizes to .empty")

        let onePixel = SelectionMask(size: PixelSize(width: 300, height: 300)) { x, y in
            x == 10 && y == 10 ? 1 : 0
        }
        if case .partial = onePixel.tile(at: TileCoordinate(column: 0, row: 0)) {} else {
            Issue.record("tile (0,0) must be .partial")
        }
        let othersPartial = onePixel.tiles.dropFirst().contains { if case .partial = $0 { true } else { false } }
        #expect(!othersPartial, "only tile (0,0) carries storage")
        #expect(onePixel.bounds == PixelRect(x: 10, y: 10, width: 1, height: 1))
    }

    @Test func boundsAreTight() {
        let mask = SelectionMask(size: PixelSize(width: 700, height: 400)) { x, y in
            (x == 5 && y == 7) || (x == 600 && y == 300) ? 7 : 0
        }
        #expect(mask.bounds == PixelRect(x: 5, y: 7, width: 596, height: 294))
    }

    @Test func invertTwiceIsIdentity() {
        var rng = SeededRandom(seed: Self.seed)
        let (mask, reference) = randomPair(&rng, size: PixelSize(width: 300, height: 257))
        let twice = mask.inverted().inverted()
        #expect(twice == mask, "fixed-example round trip")
        reference.inverted().inverted().matches(twice, comment: rng.comment)
    }

    @Test func edgeTileOutOfCanvasStaysZero() throws {
        var rng = SeededRandom(seed: Self.seed &+ 1)
        let size = PixelSize(width: 300, height: 257)   // edge tiles on the right and bottom
        let (mask, reference) = randomPair(&rng, size: size)

        func assertInvariant(_ result: SelectionMask, label: String) {
            for row in 0..<result.gridRows {
                for column in 0..<result.gridColumns {
                    guard case .partial(let storage) = result.tile(
                        at: TileCoordinate(column: column, row: row)) else { continue }
                    for y in 0..<256 {
                        for x in 0..<256 {
                            let canvasX = column * 256 + x
                            let canvasY = row * 256 + y
                            let inside = canvasX < size.width && canvasY < size.height
                            let value = storage.bytes[y * 256 + x]
                            if !inside {
                                #expect(value == 0,
                                        "\(label): out-of-canvas byte at tile(\(column),\(row)) (\(x),\(y))")
                            }
                        }
                    }
                }
            }
        }

        let inverted = mask.inverted()
        assertInvariant(inverted, label: "inverted")
        let xorFull = mask.combined(with: .full(size: size), mode: .xor)
        assertInvariant(xorFull, label: "xor full")
        // In-canvas bytes equal 255 − v.
        reference.inverted().matches(inverted, comment: rng.comment)
        reference.combined(with: ReferenceMask(size: size) { _, _ in 255 }, mode: .xor)
            .matches(xorFull, comment: rng.comment)
    }

    @Test func wideStripGrid() {
        let strip = SelectionMask.full(size: PixelSize(width: 65_535, height: 1))
        #expect(strip.tiles.count == 256, "256 columns × 1 row")
        #expect(strip.coverage(x: 65_534, y: 0) == 255)
        #expect(strip.coverage(x: 65_535, y: 0) == 0)
    }

    @Test(.timeLimit(.minutes(1))) func fastPathsMatchPerPixelOracle() {
        var rng = SeededRandom(seed: Self.seed &+ 2)
        let size = PixelSize(width: 300, height: 300)   // 2×2 grid with two edge tiles
        let partial = randomGrid(&rng, width: size.width, height: size.height)
        let edgeGrid = randomGrid(&rng, width: size.width, height: size.height)

        // Tile kinds: empty (all-0), full (all-255), partial-random, partial-at-an-edge-tile
        // (zero elsewhere — only tile (1,1) of a 300×300 grid is an edge tile).
        func mask(_ grid: @escaping (Int, Int) -> UInt8) -> (SelectionMask, ReferenceMask) {
            (SelectionMask(size: size, coverage: grid), ReferenceMask(size: size, coverage: grid))
        }
        let kinds: [(SelectionMask, ReferenceMask)] = [
            mask { _, _ in 0 },
            mask { _, _ in 255 },
            mask { x, y in partial[y * size.width + x] },
            mask { x, y in x >= 256 && y >= 256 ? edgeGrid[y * size.width + x] : 0 },
        ]
        for (index, a) in kinds.enumerated() {
            for (otherIndex, b) in kinds.enumerated() {
                for mode in SelectionCombineMode.allCases {
                    let result = a.0.combined(with: b.0, mode: mode)
                    let expected = a.1.combined(with: b.1, mode: mode)
                    expected.matches(result,
                                     comment: "kind \(index)×\(otherIndex) mode \(mode.rawValue)")
                    // Normalization is exact: the result must also equal the builder's.
                    #expect(result == SelectionMask(size: size, coverage: expected.coverage),
                            "result must be normalized (\(index)×\(otherIndex) \(mode.rawValue))")
                }
            }
        }
    }

    @Test func unchangedTilesShareStorage() {
        var rng = SeededRandom(seed: Self.seed &+ 3)
        let (mask, _) = randomPair(&rng, size: PixelSize(width: 300, height: 300))
        let union = mask.combined(with: SelectionMask(size: mask.size), mode: .union)
        for coordinate in [TileCoordinate(column: 0, row: 0), TileCoordinate(column: 1, row: 1)] {
            let original = mask.tile(at: coordinate)
            let resultTile = union.tile(at: coordinate)
            switch (original, resultTile) {
            case (.partial(let a), .partial(let b)):
                #expect(a === b, "the unchanged tile must reuse its storage at \(coordinate)")
            default:
                Issue.record("expected partial tiles at \(coordinate)")
            }
        }
        #expect(SelectionMask(size: PixelSize(width: 500, height: 500)).inverted().partialTileCount == 0,
                "inverting an all-empty mask allocates nothing")
        #expect(SelectionMask.full(size: PixelSize(width: 500, height: 500)).inverted().partialTileCount == 0,
                "inverting an all-full mask allocates nothing")
    }

    @Test(.timeLimit(.minutes(1))) func hugeSelectAllHasNoStorage() {
        let huge = PixelSize(width: 65_535, height: 65_535)
        let all = SelectionMask.full(size: huge)
        #expect(all.tileStorageIdentities.isEmpty)
        let inverted = all.inverted()
        #expect(inverted.isEmpty)
        #expect(inverted.partialTileCount == 0)
    }

    @Test func sizeMismatchReturnsSelf() {
        var rng = SeededRandom(seed: Self.seed &+ 4)
        let (mask, _) = randomPair(&rng, size: PixelSize(width: 100, height: 100))
        let small = SelectionMask.full(size: PixelSize(width: 50, height: 50))
        for mode in SelectionCombineMode.allCases {
            #expect(mask.combined(with: small, mode: mode) == mask, "\(mode.rawValue)")
        }
    }

    @Test func conformsToBrushClipMask() {
        var rng = SeededRandom(seed: Self.seed &+ 5)
        let (mask, _) = randomPair(&rng, size: PixelSize(width: 300, height: 300))
        let clip = mask as any BrushClipMask
        #expect(clip.bounds == mask.bounds)
        for sample in [(0, 0), (299, 299), (150, 7), (300, 0), (-3, 5)] {
            #expect(clip.coverage(x: sample.0, y: sample.1) == mask.coverage(x: sample.0, y: sample.1))
        }
    }
}
