import Foundation
import Metal
import Testing
@testable import PaintDotMac

/// Recorded goldens for the Metal compositor (spec 0024 item 11, PRD NF-6): always
/// oracle-checked against `CPUCompositor` first; the file is compared (or recorded, with
/// `TEST_RUNNER_RECORD_GOLDENS=1`, never passing the run that records).
@MainActor
struct MetalCompositorGoldenTests {
    private func makeCompositor(_ device: MTLDevice) throws -> MetalCompositor {
        let library = try #require(try? device.makeDefaultLibrary(bundle: Bundle(for: MetalCompositor.self)),
                                   "could not load the app Metal library")
        return try MetalCompositor(device: device, library: library)
    }

    /// Assembles the full straight composite of `image` from `compositeTilePixels` of
    /// every tile (the GPU's own output, tile by tile).
    private func assemble(compositor: MetalCompositor, image: LayeredImage) throws -> [ColorRGBA8] {
        let size = image.size
        var output = [ColorRGBA8](repeating: .clear, count: size.width * size.height)
        for row in 0..<((size.height + 255) / 256) {
            for column in 0..<((size.width + 255) / 256) {
                guard let tile = compositor.compositeTilePixels(
                    TileCoordinate(column: column, row: row), of: image) else { continue }
                let validWidth = min(256, size.width - column * 256)
                let validHeight = min(256, size.height - row * 256)
                for y in 0..<validHeight {
                    for x in 0..<validWidth {
                        output[(row * 256 + y) * size.width + column * 256 + x] = tile[y * 256 + x]
                    }
                }
            }
        }
        return output
    }

    @Test func normalStack300() throws {
        let device = try MetalTestTarget.makeDevice()
        let compositor = try makeCompositor(device)
        let size = PixelSize(width: 300, height: 300)
        // 1: opaque horizontal gradient (every tile allocated).
        let gradient = TestImages.surface(width: 300, height: 300) { x, y in
            ColorRGBA8(red: UInt8(x % 256), green: UInt8(y % 256),
                       blue: UInt8((x + y) / 2 % 256), alpha: 255)
        }
        // 2: red disc, opacity 200.
        let disc = TestImages.surface(width: 300, height: 300) { x, y in
            let dx = x - 150, dy = y - 120
            return dx * dx + dy * dy <= 90 * 90
                ? ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255) : .clear
        }
        // 3: blue diagonal band at (0, 0, 255, 128).
        let band = TestImages.surface(width: 300, height: 300) { x, y in
            abs(x - y) <= 30 ? ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 128) : .clear
        }
        // 4: hidden green.
        let green = TestImages.surface(width: 300, height: 300) { x, y in
            x % 7 < 3 ? ColorRGBA8(red: 0, green: 200, blue: 0, alpha: 255) : .clear
        }
        // 5: only tile (1, 1) allocated (the 44×44 edge tile).
        var sparse = TiledSurface(size: size)
        var tile = Tile()
        for y in 0..<256 {
            for x in 0..<256 where (x + y) % 5 == 0 && x < 44 && y < 44 {
                tile.setPixel(ColorRGBA8(red: 20, green: 220, blue: 240, alpha: 200), x: x, y: y)
            }
        }
        sparse.setTile(tile, at: TileCoordinate(column: 1, row: 1))
        let image = LayeredImage(size: size,
                                 layers: [Layer(name: "Gradient", surface: gradient),
                                          Layer(name: "Disc", surface: disc, opacity: 200),
                                          Layer(name: "Band", surface: band),
                                          Layer(name: "Green", surface: green, isVisible: false),
                                          Layer(name: "Sparse", surface: sparse)],
                                 activeLayerIndex: 4)
        let actual = try assemble(compositor: compositor, image: image)
        let oracle = CPUCompositor().composite(image, in: size.bounds).pixels
        GoldenImage.assertGolden(actual, width: 300, height: 300,
                                 named: "compositor-normal-stack-300", oracle: oracle)
    }

    @Test func canvasTenLayersAt50Percent() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try MetalCanvasRenderer(device: device)
        let size = PixelSize(width: 512, height: 512)
        var layers: [Layer] = []
        for index in 0..<10 {
            var random = SeededRandom(seed: 0xC0FFEE &+ UInt64(index))
            let surface = TestImages.surface(width: 512, height: 512) { _, _ in random.color() }
            layers.append(Layer(name: "L\(index)", surface: surface,
                                opacity: UInt8(255 - index * 20)))
        }
        let image = LayeredImage(size: size, layers: layers, activeLayerIndex: 9)
        let transform = CanvasTransform(
            imageSize: size, viewSize: CGSize(width: 256, height: 256),
            backingScale: 1, zoom: 0.5, center: CGPoint(x: 256, y: 256))
        let frame = CanvasFrame(image: image, transform: transform,
                                backgroundColor: CanvasReferenceRenderer.testBackground)
        let actual = try MetalTestTarget.render(frame, with: renderer, device: device,
                                                width: 256, height: 256)
        let composite = CPUCompositor().composite(image, in: size.bounds)
        let oracle = CanvasReferenceRenderer.render(pixels: composite.pixels, size: size,
                                                    opacity: 1, isVisible: true,
                                                    transform: transform,
                                                    backgroundColor: CanvasReferenceRenderer.testBackground)
        GoldenImage.assertGolden(actual, width: 256, height: 256,
                                 named: "canvas-ten-layers-50", oracle: oracle)
    }
}
