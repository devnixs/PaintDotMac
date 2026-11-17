import Foundation
import Testing

@testable import PaintDotMac

/// `CPUCompositor.merged(_:onto:)` (spec 0024 item 2): Paint.NET Merge Layer Down's
/// tile sharing, sparseness, padding, and exact equality with the two-layer composite
/// when the lower layer is plain.
struct CPUCompositorMergeTests {
    private func layer(name: String, size: PixelSize, isVisible: Bool = true,
                       opacity: UInt8 = 255,
                       tiles: [TileCoordinate: Tile] = [:],
                       fill: ((Int, Int) -> ColorRGBA8)? = nil) -> Layer {
        var surface = TiledSurface(size: size)
        for (coordinate, tile) in tiles { surface.setTile(tile, at: coordinate) }
        if let fill {
            for y in 0..<size.height {
                for x in 0..<size.width {
                    surface.setPixel(fill(x, y), at: PixelPoint(x: x, y: y))
                }
            }
        }
        return Layer(name: name, surface: surface, isVisible: isVisible, opacity: opacity)
    }

    private func tile(_ color: ColorRGBA8) -> Tile { Tile(filledWith: color) }

    @Test func opacityZeroSharesLowerTiles() {
        let lower = layer(name: "L", size: PixelSize(width: 300, height: 300)) { _, _ in
            ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 255)
        }
        let upper = layer(name: "U", size: PixelSize(width: 300, height: 300),
                          opacity: 0) { x, y in
            ColorRGBA8(red: 200, green: UInt8(x % 200), blue: UInt8(y % 200), alpha: 255)
        }
        let result = CPUCompositor().merged(upper, onto: lower)
        #expect(result.size == lower.size)
        for coordinate in lower.surface.allocatedTileCoordinates {
            #expect(lower.surface.tile(at: coordinate)!
                .sharesStorage(with: result.tile(at: coordinate)!), "tile \(coordinate)")
        }
    }

    @Test func upperEmptyTileSharesLower() {
        // 600×600 (3×3 tiles); the upper layer has only tile (1,1) allocated.
        var upperTiles: [TileCoordinate: Tile] = [:]
        upperTiles[TileCoordinate(column: 1, row: 1)] = tile(ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255))
        let lower = layer(name: "L", size: PixelSize(width: 600, height: 600)) { _, _ in
            ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255)
        }
        let upper = layer(name: "U", size: PixelSize(width: 600, height: 600), tiles: upperTiles)
        let result = CPUCompositor().merged(upper, onto: lower)
        for coordinate in lower.surface.allocatedTileCoordinates {
            if coordinate == TileCoordinate(column: 1, row: 1) {
                #expect(!lower.surface.tile(at: coordinate)!
                    .sharesStorage(with: result.tile(at: coordinate)!), "blended tile shared?")
                #expect(result.tile(at: coordinate)!.pixel(x: 0, y: 0)
                        == ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255))
            } else {
                #expect(lower.surface.tile(at: coordinate)!
                    .sharesStorage(with: result.tile(at: coordinate)!), "tile \(coordinate)")
            }
        }
    }

    @Test func transparentOverEmptyStaysSparse() {
        let lower = layer(name: "L", size: PixelSize(width: 300, height: 300))   // fully sparse
        // An allocated tile that only stores color under alpha 0.
        var upperTile = Tile()
        upperTile.setPixel(ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 0), x: 10, y: 10)
        let upper = layer(name: "U", size: PixelSize(width: 300, height: 300),
                          tiles: [TileCoordinate(column: 0, row: 0): upperTile])
        let result = CPUCompositor().merged(upper, onto: lower)
        #expect(result.allocatedTileCount == 0)
    }

    @Test func zeroAlphaKeepsLowerBitIdentical() {
        let lower = layer(name: "L", size: PixelSize(width: 4, height: 4)) { _, _ in
            ColorRGBA8(red: 1, green: 2, blue: 3, alpha: 200)
        }
        let upper = layer(name: "U", size: PixelSize(width: 4, height: 4)) { _, _ in
            ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 0)
        }
        let result = CPUCompositor().merged(upper, onto: lower)
        #expect(result.pixel(at: PixelPoint(x: 2, y: 2))
                == ColorRGBA8(red: 1, green: 2, blue: 3, alpha: 200))
    }

    @Test func edgeTilePaddingZero() throws {
        // 300×300: tile (1,1) has a 44×44 in-canvas area; everything beyond stays 0.
        let lower = layer(name: "L", size: PixelSize(width: 300, height: 300)) { _, _ in
            ColorRGBA8(red: 7, green: 7, blue: 7, alpha: 255)
        }
        let upper = layer(name: "U", size: PixelSize(width: 300, height: 300)) { x, y in
            ColorRGBA8(red: UInt8((x * 3) % 256), green: UInt8((y * 5) % 256), blue: 128,
                       alpha: x % 2 == 0 ? 255 : 64)
        }
        let result = CPUCompositor().merged(upper, onto: lower)
        let edge = TileCoordinate(column: 1, row: 1)
        let mergedTile = try #require(result.tile(at: edge))
        #expect(mergedTile.pixel(x: 43, y: 43)
                == result.pixel(at: PixelPoint(x: 299, y: 299)), "last valid pixel")
        for y in 44..<256 {
            for x in 44..<256 where (x < 64 || y < 64) {   // sample the padding border
                #expect(mergedTile.pixel(x: x, y: y) == .clear, "padding (\(x), \(y))")
            }
        }
    }

    @Test func mergeMatchesTwoLayerCompositeWhenLowerIsPlain() throws {
        // 50 seeded pairs: merged pixels equal `flattened` of the two-layer image with
        // the upper layer forced visible (exact, not ±1). The lower layer is opaque
        // ("plain"): below alpha 0 the two references legitimately differ — `merged`
        // keeps the lower layer's stored bits bit-for-bit (NF-9: never displayed),
        // `flattened` starts from transparent and produces `(0, 0, 0, 0)`.
        var random = SeededRandom(seed: 0x5ED9E)
        let size = PixelSize(width: 300, height: 300)
        let alphas: [UInt8] = [0, 1, 64, 128, 200, 255]
        for round in 0..<50 {
            let lowerOpacity: UInt8 = 255
            let upperOpacity = alphas[random.int(in: 1...5)]
            let lower = layer(name: "L", size: size, opacity: lowerOpacity) { _, _ in
                random.color().with(alpha: 255)
            }
            let upper = layer(name: "U", size: size, opacity: upperOpacity) { x, y in
                // Half-transparent upper with random holes (alpha 0).
                random.color().with(alpha: (x + y + round) % 4 == 0 ? 0 : random.byte())
            }
            let merged = CPUCompositor().merged(upper, onto: lower)
            var visibleUpper = upper
            visibleUpper.isVisible = true
            let image = LayeredImage(size: size, layers: [lower, visibleUpper],
                                     activeLayerIndex: 1)
            let composite = CPUCompositor().flattened(image)
            var mismatch: String?
            if merged != composite {
                outer: for y in 0..<size.height {
                    for x in 0..<size.width {
                        let point = PixelPoint(x: x, y: y)
                        let a = merged.pixel(at: point)
                        let b = composite.pixel(at: point)
                        if a != b {
                            mismatch = "(\(x), \(y)): merged \(a) vs flattened \(b)"
                            break outer
                        }
                    }
                }
            }
            #expect(mismatch == nil, "round \(round): \(mismatch ?? "")")
        }
    }
}

private extension ColorRGBA8 {
    func with(alpha newAlpha: UInt8) -> ColorRGBA8 {
        ColorRGBA8(red: red, green: green, blue: blue, alpha: newAlpha)
    }
}
