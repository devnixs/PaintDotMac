import Testing

@testable import PaintDotMac

/// The CPU reference compositor (spec 0012 *Test plan*). Every expected value is the D-16
/// contract computed by hand from Paint.NET's `UserBlendOps` rounding (`mul255`,
/// source-over), never from running the code under test.
struct CPUCompositorTests {
    private let compositor = CPUCompositor()

    private func image(_ layers: [Layer], size: PixelSize) -> LayeredImage {
        LayeredImage(size: size, layers: layers, activeLayerIndex: layers.count - 1)
    }

    private func layer(_ color: ColorRGBA8, size: PixelSize, name: String = "L",
                       visible: Bool = true, opacity: UInt8 = 255) -> Layer {
        Layer(name: name,
              surface: TestImages.surface(width: size.width, height: size.height) { _, _ in color },
              isVisible: visible, opacity: opacity)
    }

    /// A seeded random surface. `opaque` fixes alpha to 255; otherwise every channel
    /// (alpha included) is random.
    private func randomSurface(width: Int, height: Int, seed: UInt64,
                               opaque: Bool = false) -> TiledSurface {
        var rng = SeededRandom(seed: seed)
        return TestImages.surface(width: width, height: height) { _, _ in
            var color = rng.color()
            if opaque { color.alpha = 255 }
            return color
        }
    }

    private func pixel(_ region: CompositedRegion, _ x: Int, _ y: Int) -> ColorRGBA8 {
        region.pixels[(y - region.rect.minY) * region.rect.width + (x - region.rect.minX)]
    }

    // MARK: - Test plan cases

    @Test func emptyImageIsTransparent() {
        let size = PixelSize(width: 300, height: 300)
        let image = image([Layer(name: "Empty", surface: TiledSurface(size: size))], size: size)
        let region = compositor.composite(image, in: size.bounds)
        #expect(region.rect == size.bounds)
        #expect(region.pixels.count == size.width * size.height)
        #expect(Set(region.pixels) == [.clear], "every pixel is (0, 0, 0, 0)")
        let flattened = compositor.flattened(image)
        #expect(flattened.allocatedTileCount == 0, "nothing gets allocated")
    }

    @Test func singleOpaqueLayerIsIdentity() {
        let size = PixelSize(width: 300, height: 300)
        let surface = randomSurface(width: 300, height: 300, seed: 0x0012_0001, opaque: true)
        let image = image([Layer(name: "Noise", surface: surface)], size: size)
        let region = compositor.composite(image, in: size.bounds)
        // Every pixel, exactly (spec: composite equals the layer pixels).
        TestImages.expectPixels(surface) { x, y in
            region.pixels[y * size.width + x]
        }
    }

    @Test func hiddenLayerIsIgnored() {
        let size = PixelSize(width: 8, height: 8)
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        let blue = ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255)
        let image = image([layer(red, size: size, name: "Bottom"),
                           layer(blue, size: size, name: "Top", visible: false)], size: size)
        let region = compositor.composite(image, in: size.bounds)
        #expect(region.pixels.allSatisfy { $0 == red })
    }

    @Test func zeroOpacityLayerIsIgnored() {
        let size = PixelSize(width: 8, height: 8)
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        let blue = ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255)
        let image = image([layer(red, size: size, name: "Bottom"),
                           layer(blue, size: size, name: "Top", opacity: 0)], size: size)
        let region = compositor.composite(image, in: size.bounds)
        #expect(region.pixels.allSatisfy { $0 == red })
    }

    /// Hand calc: `srcA = mul255(255, 128) = 128`; `fa = 128·255 + 255·127 = 65025`,
    /// `outA = (65025+127)/255 = 255`; `R = (255·128·255 + 255·255·127 + 32512)/65025 = 255`;
    /// `G = B = (255·255·127 + 32512)/65025 = 127`.
    @Test func layerOpacityHalfOverWhite() {
        let size = PixelSize(width: 4, height: 4)
        let white = ColorRGBA8.white
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        let image = image([layer(white, size: size, name: "Bottom"),
                           layer(red, size: size, name: "Top", opacity: 128)], size: size)
        let region = compositor.composite(image, in: size.bounds)
        #expect(Set(region.pixels)
                    == [ColorRGBA8(red: 255, green: 127, blue: 127, alpha: 255)])
    }

    @Test func semiTransparentOverTransparent() {
        let size = PixelSize(width: 4, height: 4)
        let blue = ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 128)
        let image = image([layer(blue, size: size)], size: size)
        let region = compositor.composite(image, in: size.bounds)
        // Straight values preserved, not premultiplied.
        #expect(Set(region.pixels) == [blue])
    }

    /// Hand calc: `fa = 128·255 + 255·127 = 65025`, `outA = 255`;
    /// `R = (255·255·127 + 32512)/65025 = 127`; `B = (255·128·255 + 32512)/65025 = 128`.
    @Test func semiTransparentOverOpaque() {
        let size = PixelSize(width: 4, height: 4)
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        let blue = ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 128)
        let image = image([layer(red, size: size, name: "Bottom"),
                           layer(blue, size: size, name: "Top")], size: size)
        let region = compositor.composite(image, in: size.bounds)
        #expect(Set(region.pixels)
                    == [ColorRGBA8(red: 127, green: 0, blue: 128, alpha: 255)])
    }

    /// Hand calc (spec 0012): bottom over clear → `(255,0,0,128)`. Top with layer opacity
    /// 255 keeps `src.a = 128`; `fa = 128·255 + 128·127 = 48896`,
    /// `outA = (48896+127)/255 = 192`, `R = (255·128·127 + 24448)/48896 = 85`,
    /// `B = (255·128·255 + 24448)/48896 = 170` → `(85, 0, 170, 192)`.
    @Test func twoSemiTransparentLayers() {
        let size = PixelSize(width: 4, height: 4)
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 128)
        let blue = ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 128)
        let image = image([layer(red, size: size, name: "Bottom"),
                           layer(blue, size: size, name: "Top")], size: size)
        let region = compositor.composite(image, in: size.bounds)
        #expect(Set(region.pixels)
                    == [ColorRGBA8(red: 85, green: 0, blue: 170, alpha: 192)])
    }

    /// The transparent-destination fast path must equal `BlendOps.blend` **exactly**,
    /// including the Paint.NET fixed-point alpha rule at the sub-byte corner (spec 0012
    /// Verification note 1). Hand calc: `mul255(128, 128) = round(16384/255) = 64`;
    /// `mul255(11, 14) = round(154/255) = 1` — the continuous `(11/255)·(14/255)` weight
    /// would truncate to 0 and drop the contribution entirely.
    @Test func firstContributionScalesAlphaExactly() {
        let size = PixelSize(width: 4, height: 4)
        let half = layer(ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 128),
                         size: size, name: "Half", opacity: 128)
        let withHiddenBottom = image([layer(.white, size: size, name: "Hidden", visible: false),
                                      half], size: size)
        let region = compositor.composite(withHiddenBottom, in: size.bounds)
        #expect(Set(region.pixels)
                    == [ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 64)],
                "first visible contribution lands on transparent dst with scaled alpha")
        let subByte = image([layer(ColorRGBA8(red: 7, green: 7, blue: 7, alpha: 11),
                                   size: size, name: "Faint", opacity: 14)], size: size)
        let faint = compositor.composite(subByte, in: size.bounds)
        #expect(Set(faint.pixels) == [ColorRGBA8(red: 7, green: 7, blue: 7, alpha: 1)],
                "the sub-byte corner stays 1, not 0 — the decided fixed-point rule")
    }

    @Test func regionIsClippedToCanvas() {
        let size = PixelSize(width: 10, height: 10)
        let image = image([layer(.black, size: size)], size: size)
        let clipped = compositor.composite(image, in: PixelRect(x: -5, y: -5, width: 20, height: 20))
        #expect(clipped.rect == PixelRect(x: 0, y: 0, width: 10, height: 10))
        #expect(clipped.pixels.count == 100)
        let outside = compositor.composite(image, in: PixelRect(x: 20, y: 30, width: 5, height: 5))
        #expect(outside.rect.isEmpty)
        #expect(outside.pixels.isEmpty)
    }

    @Test func regionAcrossTileBoundaryMatchesPerPixel() throws {
        let size = PixelSize(width: 600, height: 600)
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 128)
        let image = image([
            Layer(name: "A", surface: randomSurface(width: 600, height: 600, seed: 0x0012_0002)),
            Layer(name: "B", surface: TestImages.surface(width: 600, height: 600) { x, y in
                (x + y) % 3 == 0 ? red : .clear
            }, isVisible: false),
            Layer(name: "C", surface: randomSurface(width: 600, height: 600, seed: 0x0012_0003),
                  opacity: 100),
        ], size: size)
        let rect = PixelRect(x: 250, y: 250, width: 20, height: 20)
        let region = compositor.composite(image, in: rect)
        let flat = compositor.flattened(image)
        for y in rect.minY..<rect.maxY {
            for x in rect.minX..<rect.maxX {
                #expect(pixel(region, x, y) == flat.pixel(at: PixelPoint(x: x, y: y)),
                        "region matches flattened at (\(x), \(y))")
            }
        }
        // The four tiles the 20×20 region at (250, 250) touches.
        let tiles: [TileCoordinate] = [
            TileCoordinate(column: 0, row: 0), TileCoordinate(column: 1, row: 0),
            TileCoordinate(column: 0, row: 1), TileCoordinate(column: 1, row: 1),
        ]
        for coordinate in tiles {
            let pixels = try #require(compositor.compositeTile(coordinate, of: image))
            let area = PixelRect(x: coordinate.column * 256, y: coordinate.row * 256,
                                 width: 256, height: 256).intersection(size.bounds)
            for y in rect.minY..<rect.maxY {
                for x in rect.minX..<rect.maxX where area.contains(PixelPoint(x: x, y: y)) {
                    let tilePixel = pixels[(y - area.minY) * area.width + (x - area.minX)]
                    #expect(pixel(region, x, y) == tilePixel,
                            "region matches compositeTile(\(coordinate)) at (\(x), \(y))")
                }
            }
        }
    }

    @Test func sparseTilesStaySparse() {
        let size = PixelSize(width: 1024, height: 1024)
        var surface = TiledSurface(size: size)
        let painted = PixelPoint(x: 2 * 256 + 5, y: 1 * 256 + 9)
        surface.setPixel(ColorRGBA8(red: 1, green: 2, blue: 3, alpha: 255), at: painted)
        let image = image([Layer(name: "Dot", surface: surface)], size: size)
        let target = TileCoordinate(column: 2, row: 1)
        for row in 0..<4 {
            for column in 0..<4 {
                let coordinate = TileCoordinate(column: column, row: row)
                let pixels = compositor.compositeTile(coordinate, of: image)
                if coordinate == target {
                    #expect(pixels != nil, "the painted tile composites")
                    #expect(pixels?.count == 256 * 256)
                } else {
                    #expect(pixels == nil, "tile (\(column), \(row)) has no allocated tile")
                }
            }
        }
        let flattened = compositor.flattened(image)
        #expect(flattened.allocatedTileCount == 1)
        #expect(flattened.allocatedTileCoordinates == [target])
        #expect(flattened.pixel(at: painted) == ColorRGBA8(red: 1, green: 2, blue: 3, alpha: 255))
    }

    @Test func compositorDoesNotMutateLayers() {
        let size = PixelSize(width: 300, height: 300)
        let before = [
            Layer(name: "A", surface: randomSurface(width: 300, height: 300, seed: 0x0012_0004)),
            Layer(name: "B", surface: randomSurface(width: 300, height: 300, seed: 0x0012_0005)),
        ]
        let image = image(before, size: size)
        _ = compositor.flattened(image)
        _ = compositor.composite(image, in: size.bounds)
        _ = compositor.compositeTile(TileCoordinate(column: 1, row: 0), of: image)
        #expect(image.layers == before, "layers compare equal by value, pixels included")
        #expect(zip(image.layers, before).allSatisfy { $0.surface.generation == $1.surface.generation },
                "no tile was written")
    }

    /// An out-of-grid tile coordinate never reaches `TiledSurface.tile(at:)`'s trap.
    @Test func outOfGridTileCoordinateIsNil() {
        let size = PixelSize(width: 10, height: 10)
        let image = image([layer(.black, size: size)], size: size)
        #expect(compositor.compositeTile(TileCoordinate(column: 1, row: 0), of: image) == nil)
        #expect(compositor.compositeTile(TileCoordinate(column: -1, row: 0), of: image) == nil)
    }

    // MARK: - Helpers
}
