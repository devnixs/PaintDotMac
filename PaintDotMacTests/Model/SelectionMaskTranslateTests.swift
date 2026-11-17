import Foundation
import Testing

@testable import PaintDotMac

/// `SelectionMask.translated(dx:dy:)` (spec 0019) against the per-pixel oracle
/// `coverage(x − dx, y − dy)` — the same loop the test writes out — plus the tile
/// sharing contract and a seeded property test.
struct SelectionMaskTranslateTests {
    private static let defaultSeed: UInt64 = 0x0019_0019_0000_0001

    /// The reference: every in-canvas pixel equals `coverage(x − dx, y − dy)` of the
    /// source (0 outside).
    private func oracle(_ mask: SelectionMask, _ dx: Int, _ dy: Int) -> SelectionMask {
        SelectionMask(size: mask.size) { x, y in
            mask.coverage(x: x - dx, y: y - dy)
        }
    }

    private func equal(_ lhs: SelectionMask, _ rhs: SelectionMask, _ comment: Comment) {
        guard lhs.size == rhs.size else {
            Issue.record("size mismatch \(lhs.size) vs \(rhs.size) \(comment)")
            return
        }
        for y in 0..<lhs.size.height {
            for x in 0..<lhs.size.width {
                let a = lhs.coverage(x: x, y: y)
                let b = rhs.coverage(x: x, y: y)
                if a != b {
                    Issue.record("(\(x), \(y)): \(a) ≠ \(b) \(comment)")
                    return
                }
            }
        }
    }

    /// A 512 × 512 mask whose region (100, 100, 120, 120) holds seeded random partial
    /// bytes (0…255) — inside tile (0, 0), so a +256 shift lands inside tile (1, 0).
    private func randomRegionMask(seed: UInt64) -> SelectionMask {
        var rng = SeededRandom(seed: seed)
        return SelectionMask(size: PixelSize(width: 512, height: 512)) { x, y in
            (100..<220).contains(x) && (100..<220).contains(y) ? rng.byte() : 0
        }
    }

    // MARK: - Named cases

    @Test func translateByOnePartial() throws {
        let mask = randomRegionMask(seed: Self.defaultSeed)
        let shifted = mask.translated(dx: 1, dy: 0)
        equal(shifted, oracle(mask, 1, 0), "per-pixel equals the oracle")
        for y in 0..<mask.size.height {
            #expect(shifted.coverage(x: 0, y: y) == 0, "column 0 is 0")
        }
        #expect(shifted.size == mask.size)
    }

    @Test func translateByTileMultipleSharesStorage() throws {
        let mask = randomRegionMask(seed: Self.defaultSeed)
        let shifted = mask.translated(dx: 256, dy: 0)
        // The seeded region lives inside tile (0, 0); shifting a whole tile moves it to
        // (1, 0) — the same storage object, no copy.
        let keysBefore = Set(mask.tileStorageIdentities.keys)
        let keysAfter = Set(shifted.tileStorageIdentities.keys)
        #expect(keysAfter == keysBefore, "no partial storage was copied or dropped")
        if case .partial(let storage) = shifted.tile(at: TileCoordinate(column: 1, row: 0)) {
            #expect(keysBefore.contains(ObjectIdentifier(storage)), "the tile is shared")
        } else {
            Issue.record("tile (1, 0) should hold the shared partial storage")
        }
        // A `.full` tile stays `.full` under a whole-tile shift.
        let full = SelectionMask.full(size: PixelSize(width: 1024, height: 256))
        let fullShifted = full.translated(dx: 256, dy: 0)
        #expect(fullShifted.tile(at: TileCoordinate(column: 1, row: 0)) == .full)
        #expect(fullShifted.tile(at: TileCoordinate(column: 0, row: 0)) == .empty,
                "the vacated tile is empty")
        // The identity shift returns the same storages.
        #expect(Set(mask.translated(dx: 0, dy: 0).tileStorageIdentities.keys) == keysBefore)
    }

    @Test func translateOffCanvasIsEmpty() {
        let mask = randomRegionMask(seed: Self.defaultSeed)
        #expect(mask.translated(dx: -300, dy: 0).isEmpty)
    }

    @Test func translateExtremeOffsetsEmptyNeverCrash() {
        // The tool clamps a drag to ±1 000 000 px; the mask must survive even the whole
        // `Int` range without trapping (tile re-indexing stays in bounds).
        let mask = randomRegionMask(seed: Self.defaultSeed)
        for shift in [(1_000_000, 0), (-1_000_000, 0), (0, 1_000_000), (0, -1_000_000),
                      (1_000_000, -999_936), // both a tile and a byte offset at the clamp
                      (Int.max, Int.max), (Int.min, Int.min), (Int.max, Int.min)] {
            let shifted = mask.translated(dx: shift.0, dy: shift.1)
            #expect(shifted.isEmpty, "shift \(shift) empties a 512-wide mask")
            #expect(shifted.size == mask.size)
        }
    }

    @Test func translateAcrossTileSeams() {
        // A full tile at (0, 0) of a 512 × 512 canvas shifted by (128, 128) straddles
        // tiles (0, 0)…(1, 1).
        var tiles = [SelectionMaskTile](repeating: .empty, count: 4)
        tiles[0] = .full
        let mask = SelectionMask(size: PixelSize(width: 512, height: 512), tiles: tiles)
        let shifted = mask.translated(dx: 128, dy: 128)
        for y in [128, 255, 256, 383] {
            for x in [128, 255, 256, 383] {
                #expect(shifted.coverage(x: x, y: y) == 255, "coverage at (\(x), \(y))")
            }
        }
        #expect(shifted.coverage(x: 127, y: 127) == 0)
        #expect(shifted.coverage(x: 384, y: 384) == 0)
    }

    // MARK: - Property

    @Test(arguments: [SeededRandom.resolvedSeed(default: Self.defaultSeed)])
    func propertyRandomMasksAndShifts(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        for iteration in 0..<200 {
            let width = rng.int(in: 1...700)
            let height = rng.int(in: 1...700)
            let size = PixelSize(width: width, height: height)
            let mask = SelectionMask(size: size) { _, _ in rng.byte() }
            let dx = rng.int(in: -800...800)
            let dy = rng.int(in: -800...800)
            let shifted = mask.translated(dx: dx, dy: dy)
            equal(shifted, oracle(mask, dx, dy),
                  "iteration \(iteration): \(size) shifted (\(dx), \(dy)) \(rng.comment)")
            // Round-tripping back equals the original restricted to the pixels whose
            // shifted position was on the canvas.
            let back = shifted.translated(dx: -dx, dy: -dy)
            for y in 0..<height {
                for x in 0..<width {
                    let sx = x + dx, sy = y + dy
                    guard sx >= 0, sy >= 0, sx < width, sy < height else { continue }
                    if back.coverage(x: x, y: y) != mask.coverage(x: x, y: y) {
                        Issue.record("round trip (\(x), \(y)) \(rng.comment)")
                        return
                    }
                }
            }
        }
    }
}
