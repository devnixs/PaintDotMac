import CoreGraphics
import Testing

@testable import PaintDotMac

/// `FloodFillStencil` (spec 0016 *Test plan*): the padded-word bit storage, runs,
/// set algebra, the binary `SelectionMask` conversion, and the pixel-edge outline
/// (vertex counts and exact fill-back under both fill rules, rasterized and pointwise).
struct FloodFillStencilTests {
    private func stencil(_ size: PixelSize, _ points: [(Int, Int)]) -> FloodFillStencil {
        var result = FloodFillStencil(size: size)
        for (x, y) in points { result.insert(PixelPoint(x: x, y: y)) }
        return result
    }

    /// The path's subpaths as vertex lists (`move` + `addLine` points, no closing point).
    private func subpaths(of path: CGPath) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        path.applyWithBlock { elementPtr in
            let element = elementPtr.pointee
            switch element.type {
            case .moveToPoint:
                if !current.isEmpty { result.append(current) }
                current = [element.points[0]]
            case .addLineToPoint:
                current.append(element.points[0])
            case .closeSubpath:
                break
            default:
                Issue.record("unexpected path element \(element.type.rawValue)")
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: Basics

    @Test func basics() {
        // 70 × 3 — row padding: bit 69 of row 0 must not leak into row 1.
        var s = FloodFillStencil(size: PixelSize(width: 70, height: 3))
        s.insert(PixelPoint(x: 69, y: 0))
        #expect(s.contains(PixelPoint(x: 69, y: 0)))
        #expect(!s.contains(PixelPoint(x: 0, y: 1)), "padded rows stay separate")
        #expect(!s.contains(PixelPoint(x: 5, y: 0)))
        #expect(s.count == 1)
        #expect(s.bounds == PixelRect(x: 69, y: 0, width: 1, height: 1))

        // Out-of-range inserts are no-ops.
        for p in [PixelPoint(x: -1, y: 0), PixelPoint(x: 70, y: 0),
                  PixelPoint(x: 0, y: 3), PixelPoint(x: 0, y: -2)] {
            s.insert(p)
        }
        #expect(s.count == 1)
        #expect(!s.contains(PixelPoint(x: -1, y: 0)), "contains is false outside")

        s.insert(PixelPoint(x: 0, y: 1))
        s.insert(PixelPoint(x: 1, y: 1))
        s.insert(PixelPoint(x: 4, y: 1))
        s.insert(PixelPoint(x: 7, y: 1))
        s.insert(PixelPoint(x: 8, y: 1))
        s.insert(PixelPoint(x: 69, y: 1))
        #expect(s.runs(inRow: 1) == [0..<2, 4..<5, 7..<9, 69..<70])
        #expect(s.runs(inRow: 0) == [69..<70])
        #expect(s.runs(inRow: 2) == [])
        #expect(s.runs(inRow: -1) == [])
        #expect(s.runs(inRow: 3) == [])
        #expect(s.bounds == PixelRect(x: 0, y: 0, width: 70, height: 2))

        // Set algebra on two hand patterns.
        let a = stencil(PixelSize(width: 10, height: 4),
                        [(0, 0), (1, 0), (2, 0), (5, 1), (6, 1), (9, 3)])
        let b = stencil(PixelSize(width: 10, height: 4),
                        [(1, 0), (2, 0), (3, 0), (6, 1), (7, 1), (9, 3)])
        let allPoints = (0..<10).flatMap { x in (0..<4).map { (x, $0) } }
        for (x, y) in allPoints {
            let p = PixelPoint(x: x, y: y)
            let inA = a.contains(p), inB = b.contains(p)
            #expect(a.intersection(b).contains(p) == (inA && inB), "intersection \(p)")
            #expect(a.union(b).contains(p) == (inA || inB), "union \(p)")
            #expect(a.subtracting(b).contains(p) == (inA && !inB), "subtracting \(p)")
        }

        // Size mismatch is a defined no-op.
        let other = stencil(PixelSize(width: 10, height: 5), [(1, 0)])
        #expect(a.intersection(other) == a)
        #expect(a.union(other) == a)
        #expect(a.subtracting(other) == a)
    }

    // MARK: SelectionMask conversion

    @Test func selectionMaskMatchesStencil() throws {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0016_5701))
        let comment = rng.comment
        let size = PixelSize(width: 300, height: 257)
        // A fully set tile, empty tiles, and a mixed edge tile — deterministic so the
        // tile classification is checkable.
        var s = FloodFillStencil(size: size)
        for y in 0...255 {
            for x in 0...255 { s.insert(PixelPoint(x: x, y: y)) }
        }
        // Tile (1,1) is the edge tile: row 256, columns 256…299 in canvas.
        s.insert(PixelPoint(x: 299, y: 256))
        let mask = s.selectionMask()
        #expect(mask.size == size)
        for y in 0...size.height - 1 {
            for x in 0...size.width - 1 {
                let expected: UInt8 = s.contains(PixelPoint(x: x, y: y)) ? 255 : 0
                #expect(mask.coverage(x: x, y: y) == expected, "(\(x), \(y))")
            }
        }
        #expect(mask.tile(at: TileCoordinate(column: 0, row: 0)) == .full)
        #expect(mask.tile(at: TileCoordinate(column: 1, row: 0)) == .empty)
        #expect(mask.tile(at: TileCoordinate(column: 0, row: 1)) == .empty)
        if case .partial(let storage) = mask.tile(at: TileCoordinate(column: 1, row: 1)) {
            #expect(storage.bytes[0 * 256 + 43] == 255, "(299, 256)")
            #expect(storage.bytes[0 * 256 + 44] == 0, "out-of-canvas byte stays 0")
            #expect(storage.bytes[1 * 256 + 0] == 0, "out-of-canvas row stays 0")
        } else {
            Issue.record("edge tile should be partial — \(comment)")
        }

        // The spec's seeded random pass: density ~40 % over the whole 300 × 257
        // (across the tile seams), compared pointwise.
        var random = FloodFillStencil(size: size)
        for y in 0...size.height - 1 {
            for x in 0...size.width - 1 where rng.next() % 10 < 4 {
                random.insert(PixelPoint(x: x, y: y))
            }
        }
        let randomMask = random.selectionMask()
        for y in 0...size.height - 1 {
            for x in 0...size.width - 1 {
                let expected: UInt8 = random.contains(PixelPoint(x: x, y: y)) ? 255 : 0
                #expect(randomMask.coverage(x: x, y: y) == expected, "(\(x), \(y)) — \(comment)")
            }
        }
    }

    @Test func fullStencilIsAllFullTiles() {
        var s = FloodFillStencil(size: PixelSize(width: 600, height: 600))
        for y in 0...599 {
            for x in 0...599 { s.insert(PixelPoint(x: x, y: y)) }
        }
        #expect(s.count == 600 * 600)
        let mask = s.selectionMask()
        #expect(mask.isFull)
        #expect(mask.partialTileCount == 0, "no byte storage at all")
        let points = subpaths(of: s.outline())
        #expect(points.count == 1)
        #expect(points.first == [CGPoint(x: 0, y: 0), CGPoint(x: 600, y: 0),
                                 CGPoint(x: 600, y: 600), CGPoint(x: 0, y: 600)])
    }

    // MARK: Outline

    @Test func outlineVertexCounts() {
        // A 10 × 10 square at (2, 3): one subpath, 4 points, clockwise on screen.
        var square = FloodFillStencil(size: PixelSize(width: 20, height: 20))
        for y in 3...12 {
            for x in 2...11 { square.insert(PixelPoint(x: x, y: y)) }
        }
        let squarePaths = subpaths(of: square.outline())
        #expect(squarePaths.count == 1)
        #expect(squarePaths.first == [CGPoint(x: 2, y: 3), CGPoint(x: 12, y: 3),
                                      CGPoint(x: 12, y: 13), CGPoint(x: 2, y: 13)])

        // Square with a 2 × 2 hole: two loops, four corners each.
        var ring = square
        for y in 7...8 {
            for x in 6...7 {
                ring.words[y * ring.wordsPerRow + (x >> 6)] &= ~(UInt64(1) << UInt64(x & 63))
            }
        }
        let ringPaths = subpaths(of: ring.outline())
        #expect(ringPaths.count == 2, "outer + hole")
        #expect(ringPaths.allSatisfy { $0.count == 4 })

        // L-shape: 1 subpath, 6 corners.
        let lShape = stencil(PixelSize(width: 8, height: 8), [(0, 0), (0, 1), (1, 1)])
        let lPaths = subpaths(of: lShape.outline())
        #expect(lPaths.count == 1)
        #expect(lPaths.first?.count == 6)

        // Two pixels touching at a corner: two separate loops, 8 corner points total.
        let diagonal = stencil(PixelSize(width: 8, height: 8), [(0, 0), (1, 1)])
        let diagonalPaths = subpaths(of: diagonal.outline())
        #expect(diagonalPaths.count == 2)
        #expect(diagonalPaths.map(\.count).reduce(0, +) == 8)

        // Empty stencil → empty path.
        let empty = FloodFillStencil(size: PixelSize(width: 4, height: 4))
        #expect(empty.outline().isEmpty)
    }

    @Test func outlineRasterizesBackExactly() throws {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0016_0771))
        let comment = rng.comment
        let shapes: [(PixelSize, Int)] = [
            (PixelSize(width: 64, height: 64), 100),
            (PixelSize(width: 300, height: 257), 40),
            (PixelSize(width: 37, height: 5), 30),
            (PixelSize(width: 1, height: 1), 10),
            (PixelSize(width: 260, height: 252), 20),
        ]
        var caseNumber = 0
        for (size, count) in shapes {
            for _ in 0...count - 1 {
                defer { caseNumber += 1 }
                var s = FloodFillStencil(size: size)
                switch caseNumber % 4 {
                case 0: // random density 10…90 %
                    let threshold = UInt64(rng.int(in: 10...90)) * 1000 / 100
                    for y in 0...size.height - 1 {
                        for x in 0...size.width - 1 where rng.next() % 1000 < threshold {
                            s.insert(PixelPoint(x: x, y: y))
                        }
                    }
                case 1: // ring (a filled rect with a hole) or single pixel
                    if size.width > 8, size.height > 8 {
                        let rect = PixelRect(x: 1, y: 1, width: size.width - 3,
                                             height: size.height - 3)
                        for y in rect.minY...max(rect.minY, rect.maxY - 1) {
                            for x in rect.minX...max(rect.minX, rect.maxX - 1) {
                                s.insert(PixelPoint(x: x, y: y))
                            }
                        }
                        let hole = PixelRect(x: 4, y: 4, width: 2, height: 2)
                        if rect.contains(hole) {
                            for y in hole.minY...hole.maxY - 1 {
                                for x in hole.minX...hole.maxX - 1 {
                                    s.words[y * s.wordsPerRow + (x >> 6)] &=
                                        ~(UInt64(1) << UInt64(x & 63))
                                }
                            }
                        }
                    } else {
                        s.insert(PixelPoint(x: rng.int(in: 0...size.width - 1),
                                            y: rng.int(in: 0...size.height - 1)))
                    }
                case 2: // checkerboard blobs
                    for y in 0...size.height - 1 {
                        for x in 0...size.width - 1 where (x & 1) == (y & 1) {
                            s.insert(PixelPoint(x: x, y: y))
                        }
                    }
                default: // full canvas or empty
                    if rng.next() % 2 == 0 {
                        for y in 0...size.height - 1 {
                            for x in 0...size.width - 1 { s.insert(PixelPoint(x: x, y: y)) }
                        }
                    }
                }
                let outline = s.outline()
                let expected = s.selectionMask()
                guard !s.isEmpty else {
                    #expect(outline.isEmpty, "empty stencil, empty outline — \(comment)")
                    continue
                }
                // Both rasterizations equal the binary mask — hard edges, no AA ramp.
                MaskRasterizer.rasterize(outline, size: size, antialiased: true)
                    .matches(expected, "antialiased rasterize — case \(caseNumber) \(comment)")
                MaskRasterizer.rasterize(outline, size: size, antialiased: false)
                    .matches(expected, "pixelated rasterize — case \(caseNumber) \(comment)")
                // Pointwise containment under both fill rules on small shapes.
                if size.width * size.height <= 4096 {
                    for y in 0...size.height - 1 {
                        for x in 0...size.width - 1 {
                            let center = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                            let inside = s.contains(PixelPoint(x: x, y: y))
                            #expect(outline.contains(center, using: .winding,
                                                    transform: .identity)
                                        == inside,
                                    "winding (\(x), \(y)) — case \(caseNumber) \(comment)")
                            #expect(outline.contains(center, using: .evenOdd,
                                                     transform: .identity)
                                        == inside,
                                    "evenOdd (\(x), \(y)) — case \(caseNumber) \(comment)")
                        }
                    }
                }
            }
        }
    }

    @Test func onePixelImage() {
        var s = FloodFillStencil(size: PixelSize(width: 1, height: 1))
        s.insert(PixelPoint(x: 0, y: 0))
        #expect(s.count == 1)
        #expect(s.bounds == PixelRect(x: 0, y: 0, width: 1, height: 1))
        #expect(s.runs(inRow: 0) == [0..<1])
        let mask = s.selectionMask()
        #expect(mask.isFull)
        let paths = subpaths(of: s.outline())
        #expect(paths.count == 1)
        #expect(paths.first == [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                                CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)])
    }

    @Test func wideStrip() {
        // 65,535 × 1 with alternating runs (3 set, 1 clear).
        let width = 65_535
        var s = FloodFillStencil(size: PixelSize(width: width, height: 1))
        for x in 0...width - 1 where x % 4 != 3 {
            s.insert(PixelPoint(x: x, y: 0))
        }
        let runs = s.runs(inRow: 0)
        var expectedRuns: [Range<Int>] = []
        var start = 0
        while start < width {
            let end = min(start + 3, width)
            expectedRuns.append(start..<end)
            start += 4
        }
        #expect(runs == expectedRuns)
        #expect(s.count == expectedRuns.reduce(0) { $0 + $1.count })
        let mask = s.selectionMask()
        for x in 0...width - 1 {
            #expect(mask.coverage(x: x, y: 0) == (x % 4 != 3 ? 255 : 0), "x = \(x)")
        }
        #expect(subpaths(of: s.outline()).count == expectedRuns.count,
                "one loop per run")
    }

    @Test func sizeOverflowIsSafe() {
        // The mocked overflow check the fill consults before allocating (no real
        // allocation, no trap).
        #expect(FloodFillStencil.storageWordCount(width: .max, height: .max) == nil)
        #expect(FloodFillStencil.storageWordCount(width: 1 << 40, height: 1 << 40) == nil)
        #expect(FloodFillStencil.storageWordCount(width: -1, height: 4) == nil)
        #expect(FloodFillStencil.wordsPerRow(width: 65_535) == 1024)
        #expect(FloodFillStencil.storageWordCount(width: 65_535, height: 65_535)
                    == 1024 * 65_535)
    }

    @Test func fromSelectionMask() {
        // 0017's hook: bit set iff coverage > 0.
        let mask = SelectionMask(size: PixelSize(width: 300, height: 2)) { x, y in
            if x < 10 { return 255 }
            if x < 20 { return 1 }
            if x < 30 { return 0 }
            return 254
        }
        let stencil = FloodFillStencil.from(mask)
        for y in 0...1 {
            for x in 0...299 {
                let coverage = mask.coverage(x: x, y: y)
                #expect(stencil.contains(PixelPoint(x: x, y: y)) == (coverage > 0),
                        "(\(x), \(y)) coverage \(coverage)")
            }
        }
        #expect(stencil.count == 2 * (10 + 10 + (300 - 30)))
    }

    @Test func fromFullTilesAndRoundTrip() {
        // `.full` tiles (coverage 255 in-canvas, none out-of-canvas) must convert to
        // set bits — 0017's limit stencil reads masks whose interior tiles are `.full`
        // (e.g. every `selectionMask()` of a large region, or Select All).
        let full = SelectionMask(size: PixelSize(width: 300, height: 300)) { _, _ in 255 }
        #expect(full.isFull)
        let fullStencil = FloodFillStencil.from(full)
        #expect(fullStencil.count == 300 * 300)
        #expect(fullStencil.bounds == PixelRect(x: 0, y: 0, width: 300, height: 300))

        // Round trip: `from(stencil.selectionMask()) == stencil` for stencils that mix
        // `.full`, `.empty`, and `.partial` tiles (blobs over a filled background).
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0016_FFFF))
        let comment = rng.comment
        let sizes = [PixelSize(width: 600, height: 600), PixelSize(width: 300, height: 257),
                     PixelSize(width: 256, height: 256), PixelSize(width: 513, height: 511)]
        for caseNumber in 0...23 {
            let size = sizes[caseNumber % sizes.count]
            var s = FloodFillStencil(size: size)
            if caseNumber % 3 != 1 {
                // Filled background → interior `.full` tiles.
                for y in 0...size.height - 1 {
                    for x in 0...size.width - 1 { s.insert(PixelPoint(x: x, y: y)) }
                }
            }
            // Punch random holes and islands so `.partial` tiles appear too.
            for _ in 0..<8 {
                let rect = PixelRect(x: rng.int(in: 0...size.width - 1),
                                     y: rng.int(in: 0...size.height - 1),
                                     width: rng.int(in: 1...60), height: rng.int(in: 1...60))
                let set = rng.next() % 2 == 0
                for y in rect.minY...min(rect.maxY - 1, size.height - 1) {
                    for x in rect.minX...min(rect.maxX - 1, size.width - 1) {
                        let word = y * s.wordsPerRow + (x >> 6)
                        let bit = UInt64(1) << UInt64(x & 63)
                        if set { s.words[word] |= bit } else { s.words[word] &= ~bit }
                    }
                }
            }
            let mask = s.selectionMask()
            #expect(FloodFillStencil.from(mask) == s, "round trip case \(caseNumber) — \(comment)")
        }
    }
}

private extension SelectionMask {
    /// Pointwise comparison against another mask (the test's own loop — `==` is exact
    /// too, but this names which pixels differ).
    func matches(_ other: SelectionMask, _ comment: String) {
        guard size == other.size else {
            Issue.record("size mismatch \(size) vs \(other.size): \(comment)")
            return
        }
        var firstMismatch: String?
        for y in 0..<size.height {
            for x in 0..<size.width where coverage(x: x, y: y) != other.coverage(x: x, y: y) {
                firstMismatch = "(\(x), \(y)): \(coverage(x: x, y: y)) != \(other.coverage(x: x, y: y))"
                break
            }
            if firstMismatch != nil { break }
        }
        if let firstMismatch {
            Issue.record("coverage mismatch at \(firstMismatch): \(comment)")
        }
    }
}
