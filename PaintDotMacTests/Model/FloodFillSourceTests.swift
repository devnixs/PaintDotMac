import Testing

@testable import PaintDotMac

/// `FloodFillSource` (spec 0016 *Test plan*): Layer sampling reads the active layer's
/// raw stored pixels and shares the tile buffers; Image sampling equals the
/// `CPUCompositor` composite; `make` dispatches on the sampling mode.
struct FloodFillSourceTests {
    private func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> ColorRGBA8 {
        ColorRGBA8(red: UInt8(r), green: UInt8(g), blue: UInt8(b), alpha: UInt8(a))
    }

    @Test func layerSourceIsRawAndShared() {
        // 600 × 600, hidden, opacity 10 — Layer sampling ignores both.
        var surface = TiledSurface(size: PixelSize(width: 600, height: 600))
        surface.fill(rgba(7, 7, 7, 255), in: PixelRect(x: 0, y: 0, width: 512, height: 512))
        surface.setPixel(rgba(10, 20, 30, 0), at: PixelPoint(x: 5, y: 5))
        let layer = Layer(name: "L", surface: surface, isVisible: false, opacity: 10)
        let source = FloodFillSource.layer(layer.surface)

        #expect(source.pixel(at: PixelPoint(x: 5, y: 5)) == rgba(10, 20, 30, 0),
                "raw stored pixel, color under alpha 0 kept (0012 rule)")
        #expect(source.size == PixelSize(width: 600, height: 600))
        for row in 0..<3 {
            for column in 0..<3 {
                let coordinate = TileCoordinate(column: column, row: row)
                let layerTile = layer.surface.tile(at: coordinate)
                let sourceTile = source.tiles[row * source.gridColumns + column]
                #expect((sourceTile != nil) == (layerTile != nil), "\(coordinate)")
                if let layerTile, let sourceTile {
                    #expect(sourceTile.sharesStorage(with: layerTile),
                            "\(coordinate) shares storage (COW copy, nothing allocated)")
                }
            }
        }
        // Unallocated tiles stay nil and read transparent.
        #expect(source.tiles[2] == nil, "the tile at (2,0) was never written")
        #expect(source.pixel(at: PixelPoint(x: 555, y: 5)) == .clear)
    }

    @Test func imageSourceMatchesCompositor() throws {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0016_5001))
        let comment = rng.comment
        let size = PixelSize(width: 300, height: 257)

        func sparseSurface(_ seedOffset: Int) -> TiledSurface {
            var surface = TiledSurface(size: size)
            // Random rectangles so some tile coordinates stay unallocated everywhere.
            for _ in 0..<12 {
                let rect = PixelRect(x: rng.int(in: 0...(size.width - 40)),
                                     y: rng.int(in: 0...(size.height - 40)),
                                     width: rng.int(in: 20...80),
                                     height: rng.int(in: 20...80))
                surface.fill(rng.color(), in: rect)
            }
            _ = seedOffset
            return surface
        }
        let layers = [
            Layer(name: "Bottom", surface: sparseSurface(1), isVisible: true, opacity: 200),
            Layer(name: "Middle", surface: sparseSurface(2), isVisible: true, opacity: 255),
            Layer(name: "Hidden", surface: sparseSurface(3), isVisible: false, opacity: 255),
        ]
        let image = LayeredImage(size: size, layers: layers, activeLayerIndex: 0)
        let compositor = CPUCompositor()
        let source = FloodFillSource.image(image, compositor: compositor)
        let region = compositor.composite(image, in: size.bounds)
        #expect(region.rect == size.bounds)

        for y in 0..<size.height {
            for x in 0..<size.width {
                #expect(source.pixel(at: PixelPoint(x: x, y: y)) == region.pixels[y * size.width + x],
                        "(\(x), \(y)) — \(comment)")
            }
        }
        // Tiles where `compositeTile` is nil stay nil.
        for row in 0..<source.gridRows {
            for column in 0..<source.gridColumns {
                let composite = compositor.compositeTile(
                    TileCoordinate(column: column, row: row), of: image)
                let tile = source.tiles[row * source.gridColumns + column]
                #expect((tile == nil) == (composite == nil), "tile (\(column), \(row))")
            }
        }
    }

    @Test func imageSourceAllHidden() {
        var surface = TiledSurface(size: PixelSize(width: 300, height: 300))
        surface.fill(.white)
        let layers = [
            Layer(name: "A", surface: surface, isVisible: false),
            Layer(name: "B", surface: surface, isVisible: false, opacity: 128),
        ]
        let image = LayeredImage(size: PixelSize(width: 300, height: 300),
                                 layers: layers, activeLayerIndex: 0)
        let source = FloodFillSource.image(image)
        #expect(source.tiles.allSatisfy { $0 == nil }, "every tile nil")
        #expect(source.pixel(at: PixelPoint(x: 0, y: 0)) == .clear)
        #expect(source.pixel(at: PixelPoint(x: 299, y: 299)) == .clear)
    }

    @Test func makeDispatchesOnSampling() {
        let size = PixelSize(width: 40, height: 40)
        var bottomSurface = TiledSurface(size: size)
        bottomSurface.fill(rgba(10, 0, 0, 255))
        var topSurface = TiledSurface(size: size)
        topSurface.fill(rgba(0, 200, 0, 128))
        let image = LayeredImage(size: size, layers: [
            Layer(name: "Bottom", surface: bottomSurface),
            Layer(name: "Top", surface: topSurface, opacity: 128),
        ], activeLayerIndex: 1)

        // `.layer` reads the ACTIVE layer raw (index 1), not the composite.
        let layerSource = FloodFillSource.make(for: image, sampling: .layer)
        #expect(layerSource.pixel(at: PixelPoint(x: 5, y: 5)) == rgba(0, 200, 0, 128))
        // `.image` composites: Bottom under Top at opacity 128 ≠ the raw top pixel.
        let imageSource = FloodFillSource.make(for: image, sampling: .image)
        let composited = CPUCompositor().composite(image, in: size.bounds)
        #expect(imageSource.pixel(at: PixelPoint(x: 5, y: 5)) == composited.pixels[5 * 40 + 5])
        #expect(imageSource.pixel(at: PixelPoint(x: 5, y: 5)) != rgba(0, 200, 0, 128))
    }
}
