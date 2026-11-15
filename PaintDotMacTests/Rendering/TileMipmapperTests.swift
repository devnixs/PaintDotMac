import Testing
@testable import PaintDotMac

/// Premultiplication and the box mip chain (spec 0003). All expected values are
/// hand-computed with the spec's formulas.
struct TileMipmapperTests {
    // MARK: - premultiplied

    @Test(arguments: [
        // (255·128 + 127)/255 = 32767/255 = 128.49 → 128.
        (ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 128), ColorRGBA8(red: 128, green: 0, blue: 0, alpha: 128)),
        // Fully opaque → unchanged.
        (ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 255), ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 255)),
        // (10·1 + 127)/255 = 137/255 = 0.
        (ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 1), ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 1)),
        // (255·1 + 127)/255 = 1.49 → 1.
        (ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 1), ColorRGBA8(red: 1, green: 1, blue: 1, alpha: 1)),
    ])
    func premultiplyHandValues(_ input: ColorRGBA8, _ expected: ColorRGBA8) {
        #expect(TileMipmapper.premultiplied(input) == expected)
    }

    @Test func premultiplyZeroesTransparent() {
        // Stored RGB under alpha 0 never survives: (255·0 + 127)/255 = 0.
        #expect(TileMipmapper.premultiplied(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 0)) == .clear)
    }

    // MARK: - box downsample

    @Test func boxDownsampleHandValues() {
        // A 2×2 block of premultiplied texels:
        //   (255,0,0,255)   (0,0,255,255)
        //   (0,0,0,0)       (255,255,255,255)
        // r: (255 + 0 + 0 + 255 + 2)/4 = 512/4 = 128
        // g: (0 + 0 + 0 + 255 + 2)/4 = 257/4 = 64
        // b: (0 + 255 + 0 + 255 + 2)/4 = 512/4 = 128
        // a: (255 + 255 + 0 + 255 + 2)/4 = 767/4 = 191
        var source = [ColorRGBA8](repeating: .clear, count: 256 * 256)
        source[0] = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)     // already premultiplied (opaque)
        source[1] = ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255)
        source[256 + 1] = .white
        let premultiplied = TileMipmapper.paddedPremultipliedTile(from: source, validWidth: 256, validHeight: 256)
        let chain = TileMipmapper.mipChain(level0: premultiplied, baseLevel: 0)
        #expect(chain[1][0] == ColorRGBA8(red: 128, green: 64, blue: 128, alpha: 191))
    }

    @Test func mipChainSizes() throws {
        let opaqueWhite = TileMipmapper.paddedPremultipliedTile(
            from: [ColorRGBA8](repeating: .white, count: 256 * 256), validWidth: 256, validHeight: 256
        )
        let base0 = TileMipmapper.mipChain(level0: opaqueWhite, baseLevel: 0)
        #expect(base0.count == 7)
        for (level, levelTexels) in base0.enumerated() {
            let edge = TiledSurface.tileSize >> level
            #expect(levelTexels.count == edge * edge, "level \(level)")
        }
        let base4 = TileMipmapper.mipChain(level0: opaqueWhite, baseLevel: 4)
        #expect(base4.count == 3)
        #expect(base4[0].count == 16 * 16)
        #expect(base4[1].count == 8 * 8)
        #expect(base4[2].count == 4 * 4)
    }

    @Test func uniformTileStaysUniform() {
        let color = ColorRGBA8(red: 10, green: 200, blue: 30, alpha: 255)
        let tile = TileMipmapper.paddedPremultipliedTile(
            from: [ColorRGBA8](repeating: color, count: 256 * 256), validWidth: 256, validHeight: 256
        )
        let chain = TileMipmapper.mipChain(level0: tile, baseLevel: 0)
        for levelTexels in chain {
            #expect(levelTexels.allSatisfy { $0 == color })
        }
    }

    // MARK: - padding

    @Test func paddingIsTransparent() {
        var source = [ColorRGBA8](repeating: .clear, count: 256 * 256)
        for y in 0..<50 {
            for x in 0..<100 { source[y * 256 + x] = .white }
        }
        let level0 = TileMipmapper.paddedPremultipliedTile(from: source, validWidth: 100, validHeight: 50)
        // Level 0: everything outside 100×50 is transparent.
        #expect(level0[50 * 256 + 100] == .clear)
        #expect(level0[49 * 256 + 100] == .clear)
        #expect(level0[50 * 256 + 99] == .clear)
        #expect(level0[49 * 256 + 99] == .white)

        let chain = TileMipmapper.mipChain(level0: level0, baseLevel: 0)
        let level1 = chain[1]
        // Level-1 texel (49, 0) averages level-0 (98, 99) × (0, 1): all white → white.
        #expect(level1[0 * 128 + 49] == .white)
        // Level-1 texel (50, 0) averages level-0 (100, 101): both padding → transparent.
        #expect(level1[0 * 128 + 50] == .clear)
        let level2 = chain[2]
        // Level-2 texel (24, 0) averages level-1 (48, 49): both white → white.
        #expect(level2[0 * 64 + 24] == .white)
        // Level-2 texel (25, 0) averages level-1 (50, 51): both zero → zero.
        #expect(level2[0 * 64 + 25] == .clear)
    }

    // MARK: - iterative rounding

    @Test func iterativeRounding() {
        // The rule is the box of the **previous level**, not a direct 4×4 average.
        // Level-0 red values, per 2×2 cell (2×2 cells of the tile, rest zero):
        //
        //   cell A rows 0–1, cols 0–1: 1 1 / 1 0   → level 1 = (1+1+1+0+2)/4 = 5/4 = 1
        //     (direct 4×4 average over cols 0–3 rows 0–3 with zeros: 3/16 → 0 — different!)
        //   cell B rows 0–1, cols 2–3: 0 0 / 0 0   → level 1 = 0
        //   level 2 texel (0, 0) = box of level-1 (0, 0), (1, 0), (0, 1), (1, 1)
        //     = (1 + 0 + 0 + 0 + 2)/4 = 3/4 = 0.
        //
        // Asymmetric extra case, cell C rows 4–5, cols 4–5: 3 1 / 1 1 → (3+1+1+1+2)/4 = 8/4 = 2
        //   (a plain truncating average (6)/4 = 1 would be wrong — round half up matters).
        var source = [ColorRGBA8](repeating: .clear, count: 256 * 256)
        func setRed(_ value: UInt8, x: Int, y: Int) {
            source[y * 256 + x] = ColorRGBA8(red: value, green: 0, blue: 0, alpha: 255)
        }
        setRed(1, x: 0, y: 0); setRed(1, x: 1, y: 0); setRed(1, x: 0, y: 1); setRed(0, x: 1, y: 1)
        setRed(3, x: 4, y: 4); setRed(1, x: 5, y: 4); setRed(1, x: 4, y: 5); setRed(1, x: 5, y: 5)
        // Alpha 255 everywhere in those cells so red survives; make the untouched region
        // fully transparent (already .clear).
        let level0 = TileMipmapper.paddedPremultipliedTile(from: source, validWidth: 256, validHeight: 256)
        let chain = TileMipmapper.mipChain(level0: level0, baseLevel: 0)
        // premultiply(1, 0, 0, 255) = red 1; (0, 0, 0, 255) = red 0.
        #expect(chain[1][0 * 128 + 0].red == 1, "cell A level 1")
        #expect(chain[1][0 * 128 + 1].red == 0, "cell B level 1")
        #expect(chain[2][0 * 64 + 0].red == 0, "iterative level 2 = (1 + 0 + 0 + 0 + 2)/4 = 0")
        #expect(chain[1][2 * 128 + 2].red == 2, "cell C level 1 = (3+1+1+1+2)/4 = 2")
    }
}
