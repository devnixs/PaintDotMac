import Foundation
import Testing

@testable import PaintDotMac

/// encode → read round trips over seeded random surfaces (spec 0021 *Test plan*): the PNG
/// path is byte-exact, the TIFF path exact in size and opaque pixels, and the
/// Copy→clipboard→Paste-pixels identity holds for random rect selections.
struct ClipboardRoundTripTests {
    private struct Seed {
        var seed: UInt64
        var width: Int
        var height: Int
        var pixels: [ColorRGBA8]

        /// 20 % of the pixels are alpha 0 with random RGB (the FMT-B "color under alpha 0"
        /// case), the rest random RGBA.
        init(seed: UInt64) {
            var rng = SeededRandom(seed: seed)
            self.seed = seed
            width = rng.int(in: 1...600)
            height = rng.int(in: 1...600)
            pixels = (0..<(width * height)).map { _ in
                var color = rng.color()
                if rng.int(in: 0...4) == 0 { color = ColorRGBA8(red: color.red, green: color.green,
                                                                blue: color.blue, alpha: 0) }
                return color
            }
        }

        var surface: TiledSurface {
            TestImages.surface(width: width, height: height) { x, y in pixels[y * width + x] }
        }

        var description: String { "seed \(seed) (\(width)×\(height))" }
    }

    private func pixels(of surface: TiledSurface) -> [UInt8] {
        surface.readPixels(in: surface.bounds)
    }

    @Test(arguments: (0..<25).map { UInt64(0xC0FFEE &+ $0 * 7_919) })
    func pngRoundTripIsByteExact(seed: UInt64) throws {
        let fixture = Seed(seed: seed)
        let (png, _) = try ClipboardImageCodec.encode(fixture.surface, dpi: 96)
        let result = ClipboardImageCodec.read(ClipboardContents(pngData: png), limits: .standard,
                                              readFile: { _ throws -> Data in throw CocoaError(.fileReadUnknown) })
        let image = try result.get()
        #expect(image.size == fixture.surface.size, "\(fixture.description)")
        #expect(pixels(of: image.surface) == pixels(of: fixture.surface), "\(fixture.description)")
    }

    @Test(arguments: (0..<25).map { UInt64(0xBEEF &+ $0 * 6_113) })
    func tiffRoundTripMatchesSizeAndOpaquePixels(seed: UInt64) throws {
        let fixture = Seed(seed: seed)
        let (_, tiff) = try ClipboardImageCodec.encode(fixture.surface, dpi: 96)
        let result = ClipboardImageCodec.read(ClipboardContents(tiffData: tiff), limits: .standard,
                                              readFile: { _ throws -> Data in throw CocoaError(.fileReadUnknown) })
        let image = try result.get()
        #expect(image.size == fixture.surface.size, "\(fixture.description)")
        for y in 0..<fixture.height {
            for x in 0..<fixture.width {
                let source = fixture.pixels[y * fixture.width + x]
                guard source.alpha == 255 else { continue }
                TestImages.expectColor(image.surface.pixel(at: PixelPoint(x: x, y: y)), source,
                                       "opaque (\(x), \(y)) in \(fixture.description)")
            }
        }
    }

    /// Copy → encode → read: the bytes equal the selected layer region exactly (the same
    /// rule `ClipboardCopy.copiedSurface` produces, checked as data).
    @Test(arguments: (0..<25).map { UInt64(0xD00D &+ $0 * 4_093) })
    func copyPasteIdentity(seed: UInt64) throws {
        var rng = SeededRandom(seed: seed)
        let size = PixelSize(width: rng.int(in: 1...300), height: rng.int(in: 1...300))
        let surface = TestImages.surface(width: size.width, height: size.height) { _, _ in rng.color() }
        // A random rect fully inside the canvas (`Selection` is never empty, 0013).
        let selectionRect = PixelRect(
            x: rng.int(in: 0...(size.width - 1)), y: rng.int(in: 0...(size.height - 1)),
            width: 0, height: 0)
        let width = rng.int(in: 1...(size.width - selectionRect.x))
        let height = rng.int(in: 1...(size.height - selectionRect.y))
        let selection = try #require(Selection(
            rect: PixelRect(x: selectionRect.x, y: selectionRect.y, width: width, height: height).cgRect,
            canvasSize: size, antialiased: false))
        let state = DocumentState(image: LayeredImage(surface: surface), selection: selection)
        let copied = ClipboardCopy.copiedSurface(from: state)
        #expect(copied.size == selection.bounds.size)

        let (png, _) = try ClipboardImageCodec.encode(copied, dpi: 96)
        let result = ClipboardImageCodec.read(ClipboardContents(pngData: png), limits: .standard,
                                              readFile: { _ throws -> Data in throw CocoaError(.fileReadUnknown) })
        let image = try result.get()
        // Non-antialiased → coverage 255 inside → the region's pixels pass through.
        #expect(pixels(of: image.surface) == surface.readPixels(in: selection.bounds),
                "seed \(seed) region \(selection.bounds)")
    }
}
