import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `Resampler` against hand-computed expected values (spec 0020 *Test plan*) — transforms
/// are literal `CGAffineTransform(a:b:c:d:tx:ty:)`, independent of 0019. Never pasted
/// from the code under test.
struct ResamplerTests {
    private func color(_ r: Int, _ g: Int, _ b: Int, _ a: Int = 255) -> ColorRGBA8 {
        ColorRGBA8(red: UInt8(r), green: UInt8(g), blue: UInt8(b), alpha: UInt8(a))
    }

    private func clear() -> ColorRGBA8 { .clear }

    /// A surface of `width × height` with distinct opaque colours `s(i, j)` (i = column,
    /// j = row), placed at the origin.
    private func surface(_ width: Int, _ height: Int,
                         _ s: (_ i: Int, _ j: Int) -> ColorRGBA8) -> TiledSurface {
        var surface = TiledSurface(size: PixelSize(width: width, height: height))
        for j in 0..<height {
            for i in 0..<width {
                surface.setPixel(s(i, j), at: PixelPoint(x: i, y: j))
            }
        }
        return surface
    }

    /// `destination` pixels decoded from `resample`, indexed by absolute canvas point.
    private func pixels(_ bytes: [UInt8], _ destination: PixelRect) -> (Int, Int) -> ColorRGBA8 {
        { x, y in
            let offset = ((y - destination.minY) * destination.width
                          + (x - destination.minX)) * 4
            return ColorRGBA8(red: bytes[offset], green: bytes[offset + 1],
                              blue: bytes[offset + 2], alpha: bytes[offset + 3])
        }
    }

    private func t(_ a: Double, _ b: Double, _ c: Double, _ d: Double,
                   _ tx: Double, _ ty: Double) -> CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    // MARK: - mode(for:) — D-21

    @Test func modeSelectionTable() {
        #expect(Resampler.mode(for: .identity) == .nearestNeighbor)
        #expect(Resampler.mode(for: CGAffineTransform(translationX: 3, y: -2)) == .nearestNeighbor)
        #expect(Resampler.mode(for: t(2, 0, 0, 2, 0, 0)) == .nearestNeighbor)
        #expect(Resampler.mode(for: t(-1, 0, 0, 1, 4, 0)) == .nearestNeighbor, "flip")
        #expect(Resampler.mode(for: t(2, 0, 0, 2, 0.5, 0)) == .bilinear, "integer scale + .5 tx")
        #expect(Resampler.mode(for: t(0.5, 0, 0, 0.5, 0, 0)) == .bilinear)
        #expect(Resampler.mode(for: t(1.5, 0, 0, 1, 0, 0)) == .bilinear)
        #expect(Resampler.mode(for: t(0, 1, -1, 0, 0, 0)) == .bilinear, "90° has b/c ≠ 0")
        #expect(Resampler.mode(for: t(2 + 1e-10, 0, 0, 1, 0, 0)) == .nearestNeighbor,
                "within epsilon of an integer is that integer")
        #expect(Resampler.mode(for: t(1, 1e-12, -1e-12, 1, 2, 3)) == .nearestNeighbor,
                "off-integer b/c within epsilon keep the integer path")
        #expect(Resampler.mode(for: t(0, 0, 0, 0, 0, 0)) == .bilinear, "a/d zero are not integers here")
    }

    // MARK: - Nearest neighbor

    @Test func nearestTranslate() {
        // 3×2, six distinct opaque colours; s(i, j) = (30 + 30i, 60j + 20, 200 − 40j… — any
        // distinct scheme; keep it explicit:
        let s = { (i: Int, j: Int) in self.color(10 * i + 1, 20 * j + 2, 100, 255) }
        let source = surface(3, 2, s)
        let move = CGAffineTransform(translationX: 3, y: -2)
        let destination = PixelRect(x: 3, y: -2, width: 3, height: 2)
        let bytes = Resampler.resample(source, sourceOrigin: .zero, transform: move,
                                       mode: .nearestNeighbor, destination: destination)
        let at = pixels(bytes, destination)
        for j in 0..<2 {
            for i in 0..<3 {
                #expect(at(3 + i, -2 + j) == s(i, j), "byte-identical at (\(i), \(j))")
            }
        }
        // A destination that cannot receive a sample is all transparent.
        let empty = PixelRect(x: 2, y: -2, width: 1, height: 2)
        let emptyBytes = Resampler.resample(source, sourceOrigin: .zero, transform: move,
                                            mode: .nearestNeighbor, destination: empty)
        let emptyAt = pixels(emptyBytes, empty)
        #expect(emptyAt(2, -2) == clear())
        #expect(emptyAt(2, -1) == clear())
    }

    @Test func nearestScale2x() {
        let a = color(255, 0, 0), b = color(0, 255, 0), c = color(0, 0, 255), d = color(0, 0, 0)
        let source = surface(2, 2) { i, j in
            if i == 0, j == 0 { a } else if i == 1, j == 0 { b }
            else if i == 0, j == 1 { c } else { d }
        }
        // Source origin (10, 10): x' = 2x − 10 maps the source rect (10,10,2,2) to
        // (10,10,4,4).
        let bytes = Resampler.resample(source, sourceOrigin: PixelPoint(x: 10, y: 10),
                                       transform: t(2, 0, 0, 2, -10, -10),
                                       mode: .nearestNeighbor,
                                       destination: PixelRect(x: 10, y: 10, width: 4, height: 4))
        let at = pixels(bytes, PixelRect(x: 10, y: 10, width: 4, height: 4))
        let rows: [[ColorRGBA8]] = [[a, a, b, b], [a, a, b, b], [c, c, d, d], [c, c, d, d]]
        for (row, expectRow) in rows.enumerated() {
            for (column, expect) in expectRow.enumerated() {
                #expect(at(10 + column, 10 + row) == expect,
                        "pixel replication at (\(column), \(row))")
            }
        }
    }

    @Test func nearestFlip() {
        let a = color(11, 1, 1), b = color(22, 2, 2), c = color(33, 3, 3)
        let source = surface(3, 1) { i, _ in [a, b, c][i] }
        let bytes = Resampler.resample(source, sourceOrigin: .zero, transform: t(-1, 0, 0, 1, 3, 0),
                                       mode: .nearestNeighbor,
                                       destination: PixelRect(x: 0, y: 0, width: 3, height: 1))
        let at = pixels(bytes, PixelRect(x: 0, y: 0, width: 3, height: 1))
        #expect(at(0, 0) == c)
        #expect(at(1, 0) == b)
        #expect(at(2, 0) == a)
    }

    // MARK: - Exact rotations (bilinear, snapped)

    /// 16 distinct opaque colours on a 4×4 source.
    private func source16() -> (TiledSurface, (Int, Int) -> ColorRGBA8) {
        let s = { (i: Int, j: Int) in self.color(16 * i + 7, 16 * j + 3, 128, 255) }
        return (surface(4, 4, s), s)
    }

    @Test func rotate90Exact() {
        let (source, s) = source16()
        let destination = PixelRect(x: 0, y: 0, width: 4, height: 4)
        // +90° about (2, 2): x' = 4 − y, y' = x.
        let matrix = t(0, 1, -1, 0, 4, 0)
        #expect(Resampler.mode(for: matrix) == .bilinear)
        let bytes = Resampler.resample(source, sourceOrigin: .zero, transform: matrix,
                                       mode: .bilinear, destination: destination)
        let at = pixels(bytes, destination)
        for y in 0..<4 {
            for x in 0..<4 {
                #expect(at(x, y) == s(y, 3 - x), "dest(\(x), \(y)) = s(\(y), \(3 - x))")
            }
        }
        // Bilinear's destination bounds are the exact box plus the 1 px support ring,
        // and the ring is fully transparent (nothing outside the source bleeds in).
        let ring = Resampler.destinationBounds(sourceRect: PixelRect(x: 0, y: 0, width: 4, height: 4),
                                               transform: matrix, mode: .bilinear)
        #expect(ring == PixelRect(x: -1, y: -1, width: 6, height: 6))
        let ringBytes = Resampler.resample(source, sourceOrigin: .zero, transform: matrix,
                                           mode: .bilinear, destination: ring)
        let ringAt = pixels(ringBytes, ring)
        for y in ring.minY..<ring.maxY {
            for x in ring.minX..<ring.maxX {
                if x >= 0, x < 4, y >= 0, y < 4 { continue }
                #expect(ringAt(x, y) == clear(), "ring pixel (\(x), \(y))")
            }
        }

        // The same rotation built with cos/sin (entries off by ~1e-16): snapping gives
        // byte-identical output.
        let built = CGAffineTransform.identity
            .translatedBy(x: 2, y: 2)
            .rotated(by: .pi / 2)
            .translatedBy(x: -2, y: -2)
        let builtBytes = Resampler.resample(source, sourceOrigin: .zero, transform: built,
                                            mode: .bilinear, destination: destination)
        #expect(builtBytes == bytes, "snapping makes the computed matrix exact")
    }

    @Test func rotate180Exact() {
        let (source, s) = source16()
        let destination = PixelRect(x: 0, y: 0, width: 4, height: 4)
        let matrix = t(-1, 0, 0, -1, 4, 4)
        let bytes = Resampler.resample(source, sourceOrigin: .zero, transform: matrix,
                                       mode: .bilinear, destination: destination)
        let at = pixels(bytes, destination)
        for y in 0..<4 {
            for x in 0..<4 {
                #expect(at(x, y) == s(3 - x, 3 - y))
            }
        }
    }

    @Test func rotate270Exact() {
        let (source, s) = source16()
        let destination = PixelRect(x: 0, y: 0, width: 4, height: 4)
        let matrix = t(0, -1, 1, 0, 0, 4)
        let bytes = Resampler.resample(source, sourceOrigin: .zero, transform: matrix,
                                       mode: .bilinear, destination: destination)
        let at = pixels(bytes, destination)
        for y in 0..<4 {
            for x in 0..<4 {
                #expect(at(x, y) == s(3 - y, x))
            }
        }
    }

    @Test func rotate90OddLength() {
        let a = color(200, 10, 10), b = color(10, 200, 10), c = color(10, 10, 200)
        let source = surface(3, 1) { i, _ in [a, b, c][i] }
        let sourceRect = PixelRect(x: 5, y: 5, width: 3, height: 1)
        // +90° about (6.5, 5.5): x' = 12 − y, y' = x − 1.
        let matrix = t(0, 1, -1, 0, 12, -1)
        let bounds = Resampler.destinationBounds(sourceRect: sourceRect, transform: matrix,
                                                 mode: .bilinear)
        let bytes = Resampler.resample(source, sourceOrigin: PixelPoint(x: 5, y: 5),
                                       transform: matrix, mode: .bilinear, destination: bounds)
        let at = pixels(bytes, bounds)
        #expect(at(6, 4) == a)
        #expect(at(6, 5) == b)
        #expect(at(6, 6) == c)
        for y in bounds.minY..<bounds.maxY {
            for x in bounds.minX..<bounds.maxX {
                if x == 6 && (y == 4 || y == 5 || y == 6) { continue }  // the strip itself
                #expect(at(x, y) == clear(), "off-strip pixel (\(x), \(y)) is clear")
            }
        }
    }

    // MARK: - Bilinear

    @Test func bilinearScale2xEdges() {
        // 2×1 [black, white] at (0,0), forced bilinear, destination (−1,−1,6,4).
        let black = color(0, 0, 0), white = color(255, 255, 255)
        let source = surface(2, 1) { i, _ in i == 0 ? black : white }
        let destination = PixelRect(x: -1, y: -1, width: 6, height: 4)
        let bytes = Resampler.resample(source, sourceOrigin: .zero, transform: t(2, 0, 0, 2, 0, 0),
                                       mode: .bilinear, destination: destination)
        let at = pixels(bytes, destination)
        // Per-axis weights 0.75/0.25, transparent outside, alpha Int(A + 0.5), colour
        // Int(P/A + 0.5) — hand-computed, e.g. x = −1: A = 0.1875·255 = 47.8125 → 48;
        // x = 0: A = 0.5625·255 = 143.4375 → 143; x = 1: A = 191.25 → 191,
        // P = 0.5625·255·255 → C = 63.75 → 64; x = 2 mirror; x = 3: (143, 255); x = 4:
        // (48, 255).
        func gray(_ x: Int, _ y: Int) -> (Int, Int) {
            let p = at(x, y)
            return (Int(p.alpha), Int(p.red))
        }
        for y in [0, 1] {
            #expect(gray(-1, y) == (48, 0), "column −1, row \(y)")
            #expect(gray(0, y) == (143, 0))
            #expect(gray(1, y) == (191, 64))
            #expect(gray(2, y) == (191, 191))
            #expect(gray(3, y) == (143, 255))
            #expect(gray(4, y) == (48, 255))
        }
        // Row y = −1 mirrors from above: (1, −1) weights 0.25·… of row 0 → (64, 64).
        #expect(gray(1, -1) == (64, 64))
    }

    @Test func bilinearHalfPixelRotation() {
        // 2×1 opaque red at (0,0), +90° about (1, 0.5): x' = 1.5 − y, y' = x − 0.5.
        let red = color(255, 0, 0)
        let source = surface(2, 1) { _, _ in red }
        let bytes = Resampler.resample(source, sourceOrigin: .zero,
                                       transform: t(0, 1, -1, 0, 1.5, -0.5),
                                       mode: .bilinear,
                                       destination: PixelRect(x: 0, y: 0, width: 1, height: 1))
        // dest(0,0) centre → p = (1.0, 1.0): four quarter samples, two inside the source
        // → A = 0.25·255 + 0.25·255 = 127.5 → 128, colour stays 255.
        #expect(bytes.count == 4)
        #expect(ColorRGBA8(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes[3])
                    == color(255, 0, 0, 128))
    }

    @Test func bilinearIgnoresColorUnderZeroAlpha() {
        // [(255,0,0,255), (0,0,255,0)] sampled at (1.0, 0.5): the alpha-0 neighbour
        // contributes only its (zero) premultiplied colour — a straight average would
        // give (128, 0, 128, 128), the premultiplied result is (255, 0, 0, 128).
        let source = surface(2, 1) { i, _ in i == 0 ? color(255, 0, 0, 255) : color(0, 0, 255, 0) }
        let got = Resampler.sample(source, sourceOrigin: .zero, at: CGPoint(x: 1.0, y: 0.5),
                                   mode: .bilinear)
        #expect(got == color(255, 0, 0, 128))
    }

    @Test func fullyTransparentResultIsClear() {
        let (source, _) = source16()
        // Far outside the source: nothing lands.
        let far = Resampler.resample(source, sourceOrigin: .zero,
                                     transform: CGAffineTransform(translationX: 1000, y: 1000),
                                     mode: .nearestNeighbor,
                                     destination: PixelRect(x: 0, y: 0, width: 3, height: 3))
        #expect(far.allSatisfy { $0 == 0 })
        // A non-invertible transform is a defined all-clear no-op.
        let flat = Resampler.resample(source, sourceOrigin: .zero, transform: t(0, 0, 0, 0, 1, 1),
                                      mode: .bilinear,
                                      destination: PixelRect(x: 0, y: 0, width: 4, height: 4))
        #expect(flat.allSatisfy { $0 == 0 })
    }

    @Test func resampleMatchesPerPixelSample() throws {
        // Property: `resample` bytes == per-pixel `sample` for every destination pixel of
        // random affine transforms of random tiled sources.
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x2020_0020_0001))
        for caseNumber in 0..<50 {
            let width = rng.int(in: 1...300), height = rng.int(in: 1...300)
            var source = TiledSurface(size: PixelSize(width: width, height: height))
            let fill = PixelRect(x: rng.int(in: -10...max(0, width - 1)),
                                 y: rng.int(in: -10...max(0, height - 1)),
                                 width: rng.int(in: 1...width + 20),
                                 height: rng.int(in: 1...height + 20))
            source.fill(rng.color(), in: fill.intersection(source.bounds))
            let originX = rng.int(in: -40...40), originY = rng.int(in: -40...40)
            let angle = rng.double(in: -(.pi)...(.pi))
            let scale = rng.double(in: 0.3...3.0)
            let transform = CGAffineTransform(translationX: Double(rng.int(in: -120...120)),
                                              y: Double(rng.int(in: -120...120)))
                .rotated(by: angle)
                .scaledBy(x: scale, y: scale)
            let origin = PixelPoint(x: originX, y: originY)
            let destination = Resampler.destinationBounds(
                sourceRect: source.bounds, transform: transform, mode: .bilinear)
                .intersection(PixelRect(x: -300, y: -300, width: 900, height: 900))
            let bytes = Resampler.resample(source, sourceOrigin: origin, transform: transform,
                                           mode: .bilinear, destination: destination)
            let at = pixels(bytes, destination)
            let inverse = transform.inverted()
            var firstMismatch: (Int, Int)?
            outer: for y in destination.minY..<destination.maxY {
                for x in destination.minX..<destination.maxX {
                    let centre = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                        .applying(inverse)
                    let expected = Resampler.sample(source, sourceOrigin: origin, at: centre,
                                                    mode: .bilinear)
                    if at(x, y) != expected {
                        firstMismatch = (x, y)
                        break outer
                    }
                }
            }
            #expect(firstMismatch == nil,
                    "case \(caseNumber): first mismatch \(String(describing: firstMismatch)) seed \(rng.seed)")
        }
    }

    @Test func destinationBoundsCoverSupport() throws {
        // Property: every non-clear sample lies inside `destinationBounds` (nearest and
        // bilinear).
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x2020_0020_0002))
        for caseNumber in 0..<50 {
            let width = rng.int(in: 1...64), height = rng.int(in: 1...64)
            var source = TiledSurface(size: PixelSize(width: width, height: height))
            source.fill(rng.color(), in: source.bounds)
            let angle = rng.double(in: -(.pi)...(.pi))
            let transform = CGAffineTransform(translationX: Double(rng.int(in: -90...90)),
                                              y: Double(rng.int(in: -90...90)))
                .rotated(by: angle)
                .scaledBy(x: rng.double(in: 0.25...2.5), y: rng.double(in: 0.25...2.5))
            for mode in [ResamplingMode.bilinear, .nearestNeighbor] {
                let bounds = Resampler.destinationBounds(sourceRect: source.bounds,
                                                         transform: transform, mode: mode)
                let probe = bounds.union(PixelRect(x: bounds.minX - 2, y: bounds.minY - 2,
                                                   width: bounds.width + 4,
                                                   height: bounds.height + 4))
                let bytes = Resampler.resample(source, sourceOrigin: .zero, transform: transform,
                                               mode: mode, destination: probe)
                let at = pixels(bytes, probe)
                var violation: (Int, Int)?
                outer: for y in probe.minY..<probe.maxY {
                    for x in probe.minX..<probe.maxX where at(x, y).alpha != 0 {
                        if !bounds.contains(PixelPoint(x: x, y: y)) {
                            violation = (x, y)
                            break outer
                        }
                    }
                }
                #expect(violation == nil,
                        "case \(caseNumber) \(mode): support leaked at \(String(describing: violation)), seed \(rng.seed)")
            }
        }
    }
}
