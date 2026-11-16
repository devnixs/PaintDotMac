import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// Property tests for the selection algebra (spec 0013 *Test plan*): random masks built
/// from random byte grids (and rects/ellipses rasterized through `MaskRasterizer`) are
/// checked against `ReferenceMask` and against each other. 200 iterations; the seed is
/// printed on failure.
struct SelectionAlgebraPropertyTests {
    private static let defaultSeed: UInt64 = 0x0013_AC00_0000_0001

    /// A random mask plus its independent per-pixel oracle.
    private func randomPair(_ rng: inout SeededRandom) -> (SelectionMask, ReferenceMask) {
        let size = PixelSize(width: rng.int(in: 1...700), height: rng.int(in: 1...700))
        switch rng.int(in: 0...3) {
        case 0:   // random bytes
            let grid = (0..<(size.width * size.height)).map { _ in rng.byte() }
            return (SelectionMask(size: size) { x, y in grid[y * size.width + x] },
                    ReferenceMask(size: size) { x, y in grid[y * size.width + x] })
        case 1:   // biased sparse/full bytes
            let grid = (0..<(size.width * size.height)).map { _ in
                switch rng.int(in: 0...3) {
                case 0: UInt8(0)
                case 1: UInt8(255)
                default: rng.byte()
                }
            }
            return (SelectionMask(size: size) { x, y in grid[y * size.width + x] },
                    ReferenceMask(size: size) { x, y in grid[y * size.width + x] })
        case 2:   // a random rect, rasterized through the fast path
            let rect = CGRect(x: rng.double(in: -20...Double(size.width)),
                              y: rng.double(in: -20...Double(size.height)),
                              width: rng.double(in: 0...Double(size.width + 40)),
                              height: rng.double(in: 0...Double(size.height + 40)))
            let mask = MaskRasterizer.rasterize(CGPath(rect: rect, transform: nil),
                                                size: size, antialiased: true)
            return (mask, ReferenceMask(size: size) { x, y in mask.coverage(x: x, y: y) })
        default:  // a random ellipse, rasterized through the general path
            let rect = CGRect(x: rng.double(in: -20...Double(size.width)),
                              y: rng.double(in: -20...Double(size.height)),
                              width: rng.double(in: 0...Double(size.width + 40)),
                              height: rng.double(in: 0...Double(size.height + 40)))
            let mask = MaskRasterizer.rasterize(
                CGPath(ellipseIn: rect.standardized, transform: nil),
                size: size, antialiased: true)
            return (mask, ReferenceMask(size: size) { x, y in mask.coverage(x: x, y: y) })
        }
    }

    /// A pair of same-size masks.
    private func randomPairPair(_ rng: inout SeededRandom)
        -> (SelectionMask, ReferenceMask, SelectionMask, ReferenceMask) {
        let (a, aRef) = randomPair(&rng)
        let (bRaw, _) = randomPair(&rng)
        // Force b onto a's size by re-deriving it from a's size.
        let b: SelectionMask
        let bRef: ReferenceMask
        if bRaw.size == a.size {
            b = bRaw
            bRef = ReferenceMask(size: a.size) { x, y in bRaw.coverage(x: x, y: y) }
        } else {
            let grid = (0..<(a.size.width * a.size.height)).map { _ in rng.byte() }
            b = SelectionMask(size: a.size) { x, y in grid[y * a.size.width + x] }
            bRef = ReferenceMask(size: a.size) { x, y in grid[y * a.size.width + x] }
        }
        return (a, aRef, b, bRef)
    }

    private func iterate(_ body: (_ rng: inout SeededRandom, _ comment: Comment) -> Void) {
        let seed = SeededRandom.resolvedSeed(default: Self.defaultSeed)
        for iteration in 0..<200 {
            var rng = SeededRandom(seed: seed &+ UInt64(iteration))
            body(&rng, rng.comment)
        }
    }

    // MARK: - Mask algebra

    @Test(.timeLimit(.minutes(2))) func matchesReferenceOracle() {
        iterate { rng, comment in
            let (a, aRef, b, bRef) = randomPairPair(&rng)
            for mode in SelectionCombineMode.allCases {
                aRef.combined(with: bRef, mode: mode)
                    .matches(a.combined(with: b, mode: mode),
                             comment: Comment("\(comment) mode=\(mode.rawValue)"))
            }
            aRef.inverted().matches(a.inverted(), comment: Comment("\(comment) invert"))
        }
    }

    @Test(.timeLimit(.minutes(2))) func unionIdempotent() {
        iterate { rng, comment in
            let (a, _, _, _) = randomPairPair(&rng)
            #expect(a.combined(with: a, mode: .union) == a, "\(comment)")
        }
    }

    @Test(.timeLimit(.minutes(2))) func intersectIdempotent() {
        iterate { rng, comment in
            let (a, _, _, _) = randomPairPair(&rng)
            #expect(a.combined(with: a, mode: .intersect) == a, "\(comment)")
        }
    }

    @Test(.timeLimit(.minutes(2))) func excludeSelfIsEmpty() {
        iterate { rng, comment in
            let (a, _, _, _) = randomPairPair(&rng)
            #expect(a.combined(with: a, mode: .exclude).isEmpty, "\(comment)")
        }
    }

    @Test(.timeLimit(.minutes(2))) func xorSelfIsEmpty() {
        iterate { rng, comment in
            let (a, _, _, _) = randomPairPair(&rng)
            #expect(a.combined(with: a, mode: .xor).isEmpty, "\(comment)")
        }
    }

    @Test(.timeLimit(.minutes(2))) func invertTwiceIsIdentity() {
        iterate { rng, comment in
            let (a, _, _, _) = randomPairPair(&rng)
            #expect(a.inverted().inverted() == a, "\(comment)")
        }
    }

    @Test(.timeLimit(.minutes(2))) func deMorgan() {
        iterate { rng, comment in
            let (a, _, b, _) = randomPairPair(&rng)
            #expect(a.combined(with: b, mode: .union).inverted()
                    == a.inverted().combined(with: b.inverted(), mode: .intersect),
                    "¬(A∨B) = ¬A∧¬B — \(comment)")
            #expect(a.combined(with: b, mode: .intersect).inverted()
                    == a.inverted().combined(with: b.inverted(), mode: .union),
                    "¬(A∧B) = ¬A∨¬B — \(comment)")
        }
    }

    @Test(.timeLimit(.minutes(2))) func xorEqualsUnionMinusIntersect() {
        iterate { rng, comment in
            let (a, aRef, b, bRef) = randomPairPair(&rng)
            let xor = a.combined(with: b, mode: .xor)
            let unionMinusIntersect = a.combined(with: b, mode: .union)
                .combined(with: a.combined(with: b, mode: .intersect), mode: .exclude)
            #expect(xor == unionMinusIntersect, "\(comment)")
            // …and per pixel against the oracle.
            aRef.combined(with: bRef, mode: .union)
                .combined(with: aRef.combined(with: bRef, mode: .intersect), mode: .exclude)
                .matches(xor, comment: comment)
        }
    }

    @Test(.timeLimit(.minutes(2))) func excludePlusIntersectIsA() {
        iterate { rng, comment in
            let (a, aRef, _, bRef) = randomPairPair(&rng)
            let exclude = aRef.combined(with: bRef, mode: .exclude)
            let intersect = aRef.combined(with: bRef, mode: .intersect)
            // a = exclude ⊎ intersect is a disjoint split: arithmetic addition (never
            // overflows: (a − min) + min = a), not the max-based union.
            let sum = ReferenceMask(size: aRef.size) { x, y in
                exclude.coverage(x, y) &+ intersect.coverage(x, y)
            }
            sum.matches(a, comment: comment)
        }
    }

    @Test(.timeLimit(.minutes(2))) func unionIntersectCommutativeAssociative() {
        iterate { rng, comment in
            let (a, _, b, _) = randomPairPair(&rng)
            let (c, _) = randomPair(&rng)
            let cOnASize = c.size == a.size ? c
                : SelectionMask(size: a.size) { x, y in c.coverage(x: x, y: y) }
            #expect(a.combined(with: b, mode: .union) == b.combined(with: a, mode: .union),
                    "union commutative — \(comment)")
            #expect(a.combined(with: b, mode: .intersect) == b.combined(with: a, mode: .intersect),
                    "intersect commutative — \(comment)")
            #expect(a.combined(with: b, mode: .union).combined(with: cOnASize, mode: .union)
                    == a.combined(with: b.combined(with: cOnASize, mode: .union), mode: .union),
                    "union associative — \(comment)")
            #expect(a.combined(with: b, mode: .intersect).combined(with: cOnASize, mode: .intersect)
                    == a.combined(with: b.combined(with: cOnASize, mode: .intersect), mode: .intersect),
                    "intersect associative — \(comment)")
        }
    }

    @Test(.timeLimit(.minutes(2))) func replaceIsOperand() {
        iterate { rng, comment in
            let (a, _, b, _) = randomPairPair(&rng)
            #expect(a.combined(with: b, mode: .replace) == b, "\(comment)")
        }
    }

    // MARK: - Selection values

    @Test(.timeLimit(.minutes(2))) func selectionInvertTwiceRestoresMask() throws {
        iterate { rng, comment in
            let (mask, _) = randomPair(&rng)
            let outline = CGPath(rect: CGRect(origin: .zero,
                                              size: CGSize(width: mask.size.width,
                                                           height: mask.size.height)),
                                 transform: nil)
            guard let selection = Selection(mask: mask, outline: outline) else { return }
            guard let inverted = selection.inverted() else {
                // Only a full mask inverts to nil.
                #expect(mask.isFull, "only a full selection inverts to nil — \(comment)")
                return
            }
            let back = inverted.inverted()
            #expect(back?.mask == selection.mask, "\(comment)")
        }
    }

    @Test(.timeLimit(.minutes(2))) func combineResultNilIffMaskEmpty() throws {
        iterate { rng, comment in
            let (a, _, b, _) = randomPairPair(&rng)
            let outline = CGPath(rect: CGRect(x: 0, y: 0, width: a.size.width, height: a.size.height),
                                 transform: nil)
            let selectionA = Selection(mask: a, outline: outline)
            let selectionB = Selection(mask: b, outline: outline)
            for mode in SelectionCombineMode.allCases {
                let combined = Selection.combine(selectionA, selectionB, mode: mode,
                                                 canvasSize: a.size)
                let maskEmpty = a.combined(with: b, mode: mode).isEmpty
                #expect((combined == nil) == maskEmpty,
                        "\(mode.rawValue): nil ⟺ empty mask — \(comment)")
                if let combined {
                    #expect(combined.canvasSize == a.size, "\(comment)")
                    #expect(!combined.mask.isEmpty, "\(comment)")
                }
            }
        }
    }
}
