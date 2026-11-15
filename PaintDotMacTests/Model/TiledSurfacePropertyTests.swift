import Foundation
import Testing

@testable import PaintDotMac

/// Seeded random operations on a 700×530 surface (not a multiple of 256) against a plain
/// flat `[UInt8]` reference. Expected values come from the reference model — never from the
/// surface under test.
struct TiledSurfacePropertyTests {
    private let size = PixelSize(width: 700, height: 530)

    // MARK: - Shared machinery

    private func refModel() -> [UInt8] { [UInt8](repeating: 0, count: 700 * 530 * 4) }

    /// ~30% fully zero pixels, the rest random bytes.
    private func randomWriteBytes(_ rng: inout SeededRandom, width: Int, height: Int) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) {
            if rng.int(in: 0...9) < 3 {
                result.append(contentsOf: [0, 0, 0, 0])
            } else {
                let color = rng.color()
                result.append(contentsOf: [color.red, color.green, color.blue, color.alpha])
            }
        }
        return result
    }

    private func refRead(_ reference: [UInt8], in rect: PixelRect) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: rect.width * rect.height * 4)
        let clipped = rect.intersection(size.bounds)
        guard !clipped.isEmpty else { return result }
        for y in clipped.minY..<clipped.maxY {
            for x in clipped.minX..<clipped.maxX {
                let source = (y * size.width + x) * 4
                let destination = ((y - rect.y) * rect.width + (x - rect.x)) * 4
                for byte in 0..<4 { result[destination + byte] = reference[source + byte] }
            }
        }
        return result
    }

    private func refWrite(_ reference: inout [UInt8], bytes: [UInt8], to rect: PixelRect) {
        let clipped = rect.intersection(size.bounds)
        guard !clipped.isEmpty else { return }
        for y in clipped.minY..<clipped.maxY {
            for x in clipped.minX..<clipped.maxX {
                let source = ((y - rect.y) * rect.width + (x - rect.x)) * 4
                let destination = (y * size.width + x) * 4
                for byte in 0..<4 { reference[destination + byte] = bytes[source + byte] }
            }
        }
    }

    private func refFill(_ reference: inout [UInt8], color: ColorRGBA8, rect: PixelRect) {
        let clipped = rect.intersection(size.bounds)
        guard !clipped.isEmpty else { return }
        for y in clipped.minY..<clipped.maxY {
            for x in clipped.minX..<clipped.maxX {
                let destination = (y * size.width + x) * 4
                reference[destination] = color.red
                reference[destination + 1] = color.green
                reference[destination + 2] = color.blue
                reference[destination + 3] = color.alpha
            }
        }
    }

    /// One random operation applied to both the surface and the reference.
    private func applyRandomOperation(_ surface: inout TiledSurface, reference: inout [UInt8],
                                      rng: inout SeededRandom) {
        switch rng.int(in: 0...3) {
        case 0:
            let point = PixelPoint(x: rng.int(in: -100...(size.width + 100)),
                                   y: rng.int(in: -100...(size.height + 100)))
            let color: ColorRGBA8 = rng.int(in: 0...9) < 3 ? .clear : rng.color()
            surface.setPixel(color, at: point)
            if size.bounds.contains(point) {
                refFill(&reference, color: color,
                        rect: PixelRect(x: point.x, y: point.y, width: 1, height: 1))
            }
        case 1:
            let rect = rng.rect(around: size, maxSide: 600)
            let bytes = randomWriteBytes(&rng, width: rect.width, height: rect.height)
            surface.writePixels(bytes, to: rect)
            refWrite(&reference, bytes: bytes, to: rect)
        case 2:
            let rect = rng.int(in: 0...1) == 0 ? rng.rect(around: size, maxSide: 600) : nil
            let color: ColorRGBA8 = rng.int(in: 0...9) < 3 ? .clear : rng.color()
            surface.fill(color, in: rect)
            refFill(&reference, color: color, rect: rect ?? size.bounds)
        default:
            surface.releaseTransparentTiles()  // pixels unchanged; nothing to mirror
        }
    }

    // MARK: - Tests

    @Test(arguments: [UInt64(0x5EED_0001), 0x5EED_0002])
    func randomOperationsMatchFlatReference(defaultSeed: UInt64) {
        let seed = SeededRandom.resolvedSeed(default: defaultSeed)
        var rng = SeededRandom(seed: seed)
        var surface = TiledSurface(size: size)
        var reference = refModel()
        for step in 0..<300 {
            applyRandomOperation(&surface, reference: &reference, rng: &rng)
            #expect(surface.readPixels(in: surface.bounds) == reference,
                    "step \(step): full read must match the reference — \(rng.comment)")
            let rect = rng.rect(around: size, maxSide: 600)
            #expect(surface.readPixels(in: rect) == refRead(reference, in: rect),
                    "step \(step): padded read of \(rect) must match — \(rng.comment)")
        }
    }

    @Test
    func edgeTilePaddingStaysZero() {
        let seed = SeededRandom.resolvedSeed(default: 0x5EED_0003)
        var rng = SeededRandom(seed: seed)
        var surface = TiledSurface(size: size)
        var reference = refModel()
        for step in 0..<300 {
            applyRandomOperation(&surface, reference: &reference, rng: &rng)
            for coordinate in surface.allocatedTileCoordinates {
                let area = surface.pixelRect(of: coordinate)
                let isEdge = area.width != Tile.size || area.height != Tile.size
                guard isEdge, let tile = surface.tile(at: coordinate) else { continue }
                // Row-wise memcmp: padding is whole runs of zero bytes.
                var paddingOk = true
                let rowBytes = Tile.size * 4
                tile.bytes.withUnsafeBytes { raw in
                    for y in 0..<Tile.size where paddingOk {
                        let row = raw[y * rowBytes ..< (y + 1) * rowBytes]
                        let insideWidth = y < area.height ? area.width * 4 : 0
                        paddingOk = row.dropFirst(insideWidth).allSatisfy { $0 == 0 }
                    }
                }
                #expect(paddingOk, "step \(step): edge tile \(coordinate) padding — \(rng.comment)")
            }
        }
    }

    @Test
    func sparsenessInvariant() {
        let seed = SeededRandom.resolvedSeed(default: 0x5EED_0004)
        var rng = SeededRandom(seed: seed)
        var surface = TiledSurface(size: size)
        var reference = refModel()
        for _ in 0..<300 {
            applyRandomOperation(&surface, reference: &reference, rng: &rng)
        }
        surface.releaseTransparentTiles()
        for coordinate in surface.allocatedTileCoordinates {
            let hasNonZero = surface.tile(at: coordinate).map { !$0.isFullyTransparent } ?? false
            #expect(hasNonZero, "allocated tile \(coordinate) must hold a non-zero byte — \(rng.comment)")
        }
        for row in 0..<surface.tileRows {
            for column in 0..<surface.tileColumns {
                let coordinate = TileCoordinate(column: column, row: row)
                let area = surface.pixelRect(of: coordinate)
                var referenceHasNonZero = false
                scan: for y in area.minY..<area.maxY {
                    for x in area.minX..<area.maxX {
                        let base = (y * size.width + x) * 4
                        if reference[base] != 0 || reference[base + 1] != 0
                            || reference[base + 2] != 0 || reference[base + 3] != 0 {
                            referenceHasNonZero = true
                            break scan
                        }
                    }
                }
                let allocated = surface.tile(at: coordinate) != nil
                if !referenceHasNonZero {
                    #expect(!allocated, "all-zero tile \(coordinate) must be unallocated — \(rng.comment)")
                }
            }
        }
    }

    @Test
    func copiesAreIndependent() {
        let seed = SeededRandom.resolvedSeed(default: 0x5EED_0005)
        var rng = SeededRandom(seed: seed)
        var surface = TiledSurface(size: size)
        var reference = refModel()
        var snapshots: [(surface: TiledSurface, reference: [UInt8], step: Int)] = []
        for step in 0..<300 {
            if step % 25 == 0 {
                snapshots.append((surface: surface, reference: reference, step: step))
            }
            applyRandomOperation(&surface, reference: &reference, rng: &rng)
            for snapshot in snapshots {
                #expect(snapshot.surface.readPixels(in: snapshot.surface.bounds) == snapshot.reference,
                        "snapshot taken at step \(snapshot.step) must still match — \(rng.comment)")
            }
        }
    }

    @Test
    func changedTilesCoversEveryModifiedPixel() {
        let seed = SeededRandom.resolvedSeed(default: 0x5EED_0006)
        var rng = SeededRandom(seed: seed)
        var surface = TiledSurface(size: size)
        var reference = refModel()
        for step in 0..<300 {
            let generationBefore = surface.generation
            let before = reference
            applyRandomOperation(&surface, reference: &reference, rng: &rng)
            let changed = Set(surface.changedTiles(since: generationBefore))
            for row in 0..<surface.tileRows {
                for column in 0..<surface.tileColumns {
                    let area = surface.pixelRect(of: TileCoordinate(column: column, row: row))
                    var tileChanged = false
                    scan: for y in area.minY..<area.maxY {
                        for x in area.minX..<area.maxX {
                            let base = (y * size.width + x) * 4
                            if Array(before[base ..< base + 4]) != Array(reference[base ..< base + 4]) {
                                tileChanged = true
                                break scan
                            }
                        }
                    }
                    if tileChanged {
                        #expect(changed.contains(TileCoordinate(column: column, row: row)),
                                "step \(step): modified tile (\(column), \(row)) must be reported — \(rng.comment)")
                    }
                }
            }
        }
    }

    @Test
    func pngRoundTrip() throws {
        let seed = SeededRandom.resolvedSeed(default: 0x5EED_0007)
        var rng = SeededRandom(seed: seed)
        for index in 0..<20 {
            let width = rng.int(in: 1...600)
            let height = rng.int(in: 1...400)
            let surface = TestImages.surface(width: width, height: height) { _, _ in
                if rng.int(in: 0...99) < 20 {
                    // ~20% alpha-0 pixels with a random non-zero color (FMT-B preserves them).
                    return ColorRGBA8(red: rng.byte(), green: rng.byte(), blue: rng.byte(), alpha: 0)
                }
                return rng.color()
            }
            let cgImage = try #require(surface.makeCGImage(), "image \(index) must build a CGImage — \(rng.comment)")
            let data = TestImages.encode(cgImage, as: .png)
            let decoded = try ImageDecoder.decode(data, limits: ImageLimits(memoryCapBytes: .max))
            #expect(decoded.surface == surface, "image \(index) (\(width)×\(height)) must round-trip exactly — \(rng.comment)")
            #expect(decoded.dpi == 96, "image \(index): untagged DPI defaults to 96 — \(rng.comment)")
        }
    }
}
