import Foundation
import Testing

@testable import PaintDotMac

/// `FloodFill.fill` (spec 0016 *Test plan*). Oracles: a test-target per-pixel 4-neighbour
/// BFS and a per-pixel global check, both built only on `FloodColorMetric.matches`
/// (the independently verified metric); small fixtures are hand-listed.
struct FloodFillTests {
    private func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> ColorRGBA8 {
        ColorRGBA8(red: UInt8(r), green: UInt8(g), blue: UInt8(b), alpha: UInt8(a))
    }

    private func source(_ surface: TiledSurface) -> FloodFillSource {
        FloodFillSource.layer(surface)
    }

    /// Independent 4-connected flood oracle (queue + explicit neighbour set).
    private func bfsOracle(_ source: FloodFillSource, seed: PixelPoint,
                           tolerance: FloodTolerance) -> Set<PixelPoint> {
        let seedColor = source.pixel(at: seed)
        var visited: Set<PixelPoint> = [seed]
        var queue = [seed]
        var head = 0
        while head < queue.count {
            let point = queue[head]
            head += 1
            for neighbor in [PixelPoint(x: point.x - 1, y: point.y),
                             PixelPoint(x: point.x + 1, y: point.y),
                             PixelPoint(x: point.x, y: point.y - 1),
                             PixelPoint(x: point.x, y: point.y + 1)] {
                guard neighbor.x >= 0, neighbor.y >= 0,
                      neighbor.x < source.size.width, neighbor.y < source.size.height,
                      !visited.contains(neighbor),
                      FloodColorMetric.matches(seed: seedColor,
                                               candidate: source.pixel(at: neighbor),
                                               tolerance: tolerance)
                else { continue }
                visited.insert(neighbor)
                queue.append(neighbor)
            }
        }
        return visited
    }

    private func globalOracle(_ source: FloodFillSource, seed: PixelPoint,
                              tolerance: FloodTolerance) -> Set<PixelPoint> {
        let seedColor = source.pixel(at: seed)
        var result: Set<PixelPoint> = []
        for y in 0..<source.size.height {
            for x in 0..<source.size.width {
                let point = PixelPoint(x: x, y: y)
                if FloodColorMetric.matches(seed: seedColor, candidate: source.pixel(at: point),
                                            tolerance: tolerance) {
                    result.insert(point)
                }
            }
        }
        return result
    }

    /// Pointwise comparison of the stencil against an oracle pixel set.
    private func expectStencil(_ stencil: FloodFillStencil?, equals expected: Set<PixelPoint>,
                               size: PixelSize, _ comment: Comment) throws {
        let stencil = try #require(stencil, "fill returned nil — \(comment)")
        #expect(stencil.size == size, "stencil size — \(comment)")
        var missing: [PixelPoint] = []
        var extra: [PixelPoint] = []
        for y in 0..<size.height {
            for x in 0..<size.width {
                let point = PixelPoint(x: x, y: y)
                if stencil.contains(point) != expected.contains(point) {
                    if stencil.contains(point) { extra.append(point) } else { missing.append(point) }
                }
            }
        }
        #expect(missing.isEmpty,
                "expected-but-missing \(missing.prefix(5).map(\.description)) — \(comment)")
        #expect(extra.isEmpty,
                "unexpected-extra \(extra.prefix(5).map(\.description)) — \(comment)")
    }

    private func gridSource(size: PixelSize, _ colorAt: (Int, Int) -> ColorRGBA8)
        -> FloodFillSource
    {
        var surface = TiledSurface(size: size)
        for y in 0..<size.height {
            for x in 0..<size.width {
                surface.setPixel(colorAt(x, y), at: PixelPoint(x: x, y: y))
            }
        }
        return source(surface)
    }

    // MARK: Hand fixtures

    @Test func diagonalNeighboursAreNotConnected() throws {
        // 4 × 4 black, white at (1,1) and (2,2) — they touch only at a corner.
        let fixture = gridSource(size: PixelSize(width: 4, height: 4)) { x, y in
            (x == 1 && y == 1) || (x == 2 && y == 2) ? .white : .black
        }
        let seed = PixelPoint(x: 1, y: 1)
        let contiguous = FloodFill.fill(fixture, from: seed, tolerance: FloodTolerance(percent: 0),
                                        mode: .contiguous)
        try expectStencil(contiguous, equals: [seed], size: fixture.size, "contiguous")
        let global = FloodFill.fill(fixture, from: seed, tolerance: FloodTolerance(percent: 0),
                                    mode: .global)
        try expectStencil(global, equals: [seed, PixelPoint(x: 2, y: 2)],
                          size: fixture.size, "global")
    }

    @Test func spanScanCoversConcaveShapes() throws {
        // A nested-spiral maze ("#" white on black, "." black). The span fill's
        // above/below rescans must reach every pocket, including runs that open left of
        // the parent span; the maze also contains an isolated 2-cell pocket (row 7,
        // x 7–8) that a correct 4-connected fill must NOT reach from (0,0).
        let rows = [
            "################",
            "#..............#",
            "#.############.#",
            "#.#..........#.#",
            "#.#.########.#.#",
            "#.#.#......#.#.#",
            "#.#.#.####.#.#.#",
            "#.#.#.#..#.#.#.#",
            "#.#.#.####.#.#.#",
            "#.#.#......#.#.#",
            "#.#.########.#.#",
            "#.#..........#.#",
            "#.############.#",
            "#..............#",
            "################",
            "................",
        ]
        let fixture = gridSource(size: PixelSize(width: 16, height: 16)) { x, y in
            Array(rows[y])[x] == "#" ? .white : .black
        }
        let tolerance = FloodTolerance(percent: 0)
        // The hand-listed set = every "#" reachable from (0,0); the BFS oracle computes
        // it independently of the span logic.
        let fromCorner = FloodFill.fill(fixture, from: PixelPoint(x: 0, y: 0),
                                        tolerance: tolerance, mode: .contiguous)
        try expectStencil(fromCorner,
                          equals: bfsOracle(fixture, seed: PixelPoint(x: 0, y: 0),
                                            tolerance: tolerance),
                          size: fixture.size, "maze from (0,0)")
        // The isolated pocket holds exactly its two cells.
        let pocket = FloodFill.fill(fixture, from: PixelPoint(x: 7, y: 7),
                                    tolerance: tolerance, mode: .contiguous)
        try expectStencil(pocket, equals: [PixelPoint(x: 7, y: 7), PixelPoint(x: 8, y: 7)],
                          size: fixture.size, "isolated pocket")
    }

    @Test func toleranceGradient() throws {
        // 64 × 1 row, R = 4x (0…252), G = B = 0, opaque.
        let fixture = gridSource(size: PixelSize(width: 64, height: 1)) { x, _ in
            rgba(4 * x, 0, 0, 255)
        }
        let seed = PixelPoint(x: 0, y: 0)
        func selected(_ percent: Int) throws -> Set<PixelPoint> {
            let stencil = FloodFill.fill(fixture, from: seed,
                                         tolerance: FloodTolerance(percent: percent),
                                         mode: .contiguous)
            let result = try #require(stencil)
            var points: Set<PixelPoint> = []
            for x in 0..<64 where result.contains(PixelPoint(x: x, y: 0)) { points.insert(PixelPoint(x: x, y: 0)) }
            return points
        }
        // 0 %: only the seed. 50 %: single-channel d ≤ 128 → 4x ≤ 128 → x ≤ 32; the
        // chain breaks at x = 33 (d = 132). 100 %: everything.
        #expect(try selected(0) == [seed])
        #expect(try selected(50) == Set((0...32).map { PixelPoint(x: $0, y: 0) }))
        #expect(try selected(100) == Set((0..<64).map { PixelPoint(x: $0, y: 0) }))
    }

    @Test func unallocatedTilesReadTransparent() throws {
        // 1024 × 1024 fully transparent (no tiles allocated) with one opaque red
        // 10 × 10 square; the transparent region around it is one 4-connected set.
        var surface = TiledSurface(size: PixelSize(width: 1024, height: 1024))
        surface.fill(rgba(255, 0, 0, 255), in: PixelRect(x: 500, y: 500, width: 10, height: 10))
        let stencil = FloodFill.fill(source(surface), from: PixelPoint(x: 0, y: 0),
                                     tolerance: FloodTolerance(percent: 0), mode: .contiguous)
        let result = try #require(stencil)
        #expect(result.count == 1024 * 1024 - 100)
        #expect(!result.contains(PixelPoint(x: 505, y: 505)))
        #expect(result.contains(PixelPoint(x: 1023, y: 1023)))
    }

    // MARK: Seeded randomized oracles

    private func randomFixture(size: PixelSize, rng: inout SeededRandom) -> FloodFillSource {
        let noise = rng.next() % 4 == 0
        let palette: [ColorRGBA8] = noise ? [] : (0..<rng.int(in: 2...4)).map { _ in rng.color() }
        var surface = TiledSurface(size: size)
        for y in 0...size.height - 1 {
            for x in 0...size.width - 1 {
                let color = noise ? rng.color() : palette[rng.int(in: 0...palette.count - 1)]
                surface.setPixel(color, at: PixelPoint(x: x, y: y))
            }
        }
        return source(surface)
    }

    @Test func contiguousMatchesBFSOracle() throws {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0016_C001))
        let sizes = [PixelSize(width: 64, height: 64), PixelSize(width: 300, height: 257)]
        let percents = [0, 10, 25, 50, 75, 100]
        for caseNumber in 0...299 {
            let size = sizes[caseNumber % sizes.count]
            let fixture = randomFixture(size: size, rng: &rng)
            let seed = PixelPoint(x: rng.int(in: 0...size.width - 1),
                                  y: rng.int(in: 0...size.height - 1))
            let percent = percents[rng.int(in: 0...percents.count - 1)]
            let stencil = FloodFill.fill(fixture, from: seed,
                                         tolerance: FloodTolerance(percent: percent),
                                         mode: .contiguous)
            try expectStencil(stencil, equals: bfsOracle(fixture, seed: seed,
                                                         tolerance: FloodTolerance(percent: percent)),
                              size: size,
                              "case \(caseNumber) seed \(seed) \(percent) % \(rng.comment)")
        }
    }

    @Test func globalMatchesPerPixelOracle() throws {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0016_6001))
        let sizes = [PixelSize(width: 64, height: 64), PixelSize(width: 300, height: 257)]
        let percents = [0, 10, 25, 50, 75, 100]
        for caseNumber in 0...119 {
            let size = sizes[caseNumber % sizes.count]
            let fixture = randomFixture(size: size, rng: &rng)
            let seed = PixelPoint(x: rng.int(in: 0...size.width - 1),
                                  y: rng.int(in: 0...size.height - 1))
            let percent = percents[rng.int(in: 0...percents.count - 1)]
            let tolerance = FloodTolerance(percent: percent)
            let stencil = FloodFill.fill(fixture, from: seed, tolerance: tolerance, mode: .global)
            try expectStencil(stencil, equals: globalOracle(fixture, seed: seed, tolerance: tolerance),
                              size: size, "case \(caseNumber) \(percent) %")
            // The concurrent row-band run is bit-identical across runs (the sequential
            // definition is the per-pixel oracle above).
            let again = FloodFill.fill(fixture, from: seed, tolerance: tolerance, mode: .global)
            #expect(stencil == again, "concurrency determinism case \(caseNumber)")
        }
    }

    @Test func seedAlwaysIncluded() throws {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0016_5EED))
        for _ in 0..<100 {
            let size = PixelSize(width: 32, height: 32)
            let fixture = randomFixture(size: size, rng: &rng)
            let seed = PixelPoint(x: rng.int(in: 0...31), y: rng.int(in: 0...31))
            let stencil = try #require(
                FloodFill.fill(fixture, from: seed, tolerance: FloodTolerance(percent: 0),
                               mode: .contiguous))
            #expect(stencil.contains(seed), "seed \(seed) must be selected")
            #expect(stencil.count >= 1)
        }
    }

    // MARK: Guards, limit, cancellation

    @Test func seedOutsideReturnsNil() {
        let fixture = gridSource(size: PixelSize(width: 64, height: 64)) { _, _ in .white }
        for seed in [PixelPoint(x: -1, y: 0), PixelPoint(x: 64, y: 0),
                     PixelPoint(x: 0, y: 64), PixelPoint(x: -5, y: -5)] {
            #expect(FloodFill.fill(fixture, from: seed, tolerance: FloodTolerance(percent: 50),
                                   mode: .contiguous) == nil, "\(seed)")
            #expect(FloodFill.fill(fixture, from: seed, tolerance: FloodTolerance(percent: 50),
                                   mode: .global) == nil, "\(seed) global")
        }
    }

    @Test func limitIsABarrier() throws {
        // Solid white, limit = everything except the 1-px wall column x = 32.
        let size = PixelSize(width: 64, height: 64)
        let fixture = gridSource(size: size) { _, _ in .white }
        var limit = FloodFillStencil(size: size)
        for y in 0..<64 {
            for x in 0..<64 where x != 32 {
                limit.insert(PixelPoint(x: x, y: y))
            }
        }
        let tolerance = FloodTolerance(percent: 100)
        let contiguous = try #require(
            FloodFill.fill(fixture, from: PixelPoint(x: 5, y: 5), tolerance: tolerance,
                           mode: .contiguous, limit: limit))
        #expect(contiguous.count == 64 * 32, "columns 0…31 only")
        #expect(!contiguous.contains(PixelPoint(x: 33, y: 5)))
        let global = try #require(
            FloodFill.fill(fixture, from: PixelPoint(x: 5, y: 5), tolerance: tolerance,
                           mode: .global, limit: limit))
        #expect(global == limit, "global = the limit itself")
        #expect(FloodFill.fill(fixture, from: PixelPoint(x: 32, y: 5), tolerance: tolerance,
                               mode: .contiguous, limit: limit) == nil,
                "seed outside the limit")
    }

    @Test func limitSizeMismatchReturnsNil() {
        let fixture = gridSource(size: PixelSize(width: 64, height: 64)) { _, _ in .white }
        let limit = FloodFillStencil(size: PixelSize(width: 64, height: 63))
        #expect(FloodFill.fill(fixture, from: PixelPoint(x: 5, y: 5),
                               tolerance: FloodTolerance(percent: 50),
                               mode: .contiguous, limit: limit) == nil)
        #expect(FloodFill.fill(fixture, from: PixelPoint(x: 5, y: 5),
                               tolerance: FloodTolerance(percent: 50),
                               mode: .global, limit: limit) == nil)
    }

    /// Thread-safe call counter (global mode calls `isCancelled` from several bands).
    private final class CancelCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        func bump() -> Int {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            return calls
        }
    }

    @Test func cancellationReturnsNil() {
        let fixture = gridSource(size: PixelSize(width: 64, height: 64)) { _, _ in .white }
        for mode in [FloodMode.contiguous, .global] {
            // True on the first call.
            #expect(FloodFill.fill(fixture, from: PixelPoint(x: 5, y: 5),
                                   tolerance: FloodTolerance(percent: 50), mode: mode,
                                   isCancelled: { true }) == nil, "\(mode)")
            // True after a few calls — no partial stencil escapes.
            let counter = CancelCounter()
            let stencil = FloodFill.fill(fixture, from: PixelPoint(x: 5, y: 5),
                                         tolerance: FloodTolerance(percent: 50), mode: mode,
                                         isCancelled: { counter.bump() >= 2 })
            #expect(stencil == nil, "\(mode): cancellation mid-fill returns nil, no partial")
        }
    }

    @Test func hugeSizeDoesNotAllocate() {
        // APP-10: the fill guards the stencil allocation with the overflow check.
        let mock = FloodFillSource(size: PixelSize(width: .max, height: .max), tiles: [])
        #expect(FloodFill.fill(mock, from: PixelPoint(x: 0, y: 0),
                               tolerance: FloodTolerance(percent: 50), mode: .contiguous) == nil)
        #expect(FloodFill.fill(mock, from: PixelPoint(x: 0, y: 0),
                               tolerance: FloodTolerance(percent: 50), mode: .global) == nil)
        // Beyond `ImageLimits.maximumSide` but without a word-count overflow: still
        // `nil`, never the `FloodFillStencil.init` precondition (real documents of any
        // size are gated by APP-10 first; this pins the mocked-source contract).
        for size in [PixelSize(width: 100_000, height: 1), PixelSize(width: 1, height: 100_000),
                     PixelSize(width: 70_000, height: 70_000),
                     PixelSize(width: 65_536, height: 65_536)] {
            let oversized = FloodFillSource(size: size, tiles: [])
            #expect(FloodFill.fill(oversized, from: PixelPoint(x: 0, y: 0),
                                   tolerance: FloodTolerance(percent: 50),
                                   mode: .contiguous) == nil, "\(size)")
            #expect(FloodFill.fill(oversized, from: PixelPoint(x: 0, y: 0),
                                   tolerance: FloodTolerance(percent: 50),
                                   mode: .global) == nil, "\(size) global")
        }
        // The maximum legal size passes the guards (no allocation is attempted by the
        // guard itself; `storageWordCount` succeeds at 65,535 × 65,535).
        #expect(FloodFillStencil.storageWordCount(width: 65_535, height: 65_535) != nil)
    }

    @Test func globalFillSmallAndOversizedBandHeights() throws {
        // The row-band split (`bandCount = min(height, cores · 4)`,
        // `bandHeight = ⌈height / bandCount⌉`) makes the LAST bands start past the
        // image whenever ceil overshoots — 1-px-tall, odd-height, and
        // `cores · 4 + 1`-tall images are the shapes that hit it. Each fill must equal
        // the per-pixel oracle, and repeated concurrent runs must be bit-identical.
        let coreBand = ProcessInfo.processInfo.activeProcessorCount * 4
        let sizes = [PixelSize(width: 1, height: 1), PixelSize(width: 64, height: 1),
                     PixelSize(width: 7, height: 1), PixelSize(width: 9, height: 5),
                     PixelSize(width: 33, height: 3), PixelSize(width: 9, height: coreBand + 1),
                     PixelSize(width: 9, height: 2 * coreBand + 3)]
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0016_B4D0))
        let comment = rng.comment
        for (index, size) in sizes.enumerated() {
            let fixture = randomFixture(size: size, rng: &rng)
            let seed = PixelPoint(x: rng.int(in: 0...size.width - 1),
                                  y: rng.int(in: 0...size.height - 1))
            let tolerance = FloodTolerance(percent: [0, 50, 100][index % 3])
            let expected = globalOracle(fixture, seed: seed, tolerance: tolerance)
            let first = try #require(
                FloodFill.fill(fixture, from: seed, tolerance: tolerance, mode: .global))
            try expectStencil(first, equals: expected, size: size,
                              "band case \(index) \(size) \(comment)")
            for _ in 0..<7 {
                let again = try #require(
                    FloodFill.fill(fixture, from: seed, tolerance: tolerance, mode: .global))
                #expect(again == first, "band case \(index) \(size) determinism — \(comment)")
            }
        }
    }
}
