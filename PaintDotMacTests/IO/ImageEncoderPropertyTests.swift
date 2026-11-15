import Foundation
import Testing
@testable import PaintDotMac

/// Seeded randomized encode → decode round trips (spec 0005 *Test plan*): 25 seeds, random
/// size 1…600 per side, random RGBA with 20 % of pixels forced to alpha 0 (random RGB — the
/// color under full transparency must survive, D-33) and 20 % to alpha 255, random DPI
/// 1…1000. The seed is printed on failure.
struct ImageEncoderPropertyTests {
    @Test(arguments: Array(0..<25)) func randomImagesRoundTrip(_ index: Int) throws {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0xC0FFEE &+ UInt64(index) &* 0x9E37_79B9))
        let comment = rng.comment

        let width = rng.int(in: 1...600)
        let height = rng.int(in: 1...600)
        var pixels: [ColorRGBA8] = []
        pixels.reserveCapacity(width * height)
        for _ in 0..<(width * height) {
            switch rng.int(in: 0...9) {
            case 0:  // 20 % fully transparent with random color
                pixels.append(ColorRGBA8(red: rng.byte(), green: rng.byte(), blue: rng.byte(), alpha: 0))
            case 1:  // 20 % fully opaque
                pixels.append(ColorRGBA8(red: rng.byte(), green: rng.byte(), blue: rng.byte(), alpha: 255))
            default:
                pixels.append(rng.color())
            }
        }
        let dpi = rng.double(in: 1...1000)
        let bytes = pixelsFlatBytes(pixels)
        let surface = bytes.withUnsafeBytes { buffer in
            TiledSurface(size: PixelSize(width: width, height: height), rgba8: buffer, bytesPerRow: width * 4)
        }

        let data = try ImageEncoder.encode(surface, size: PixelSize(width: width, height: height),
                                           dpi: dpi, as: .png)
        let decoded = try ImageDecoder.decode(data, limits: .standard)

        #expect(decoded.surface.size == PixelSize(width: width, height: height), "size \(comment)")
        var mismatches = 0
        var firstMismatch = ""
        for y in 0..<height {
            for x in 0..<width where decoded.surface.pixel(at: PixelPoint(x: x, y: y)) != pixels[y * width + x] {
                if mismatches == 0 {
                    firstMismatch = "(\(x), \(y)): got \(decoded.surface.pixel(at: PixelPoint(x: x, y: y))) "
                        + "expected \(pixels[y * width + x])"
                }
                mismatches += 1
            }
        }
        #expect(mismatches == 0, "\(mismatches) pixel mismatches, first \(firstMismatch) \(comment)")
        // pHYs rounding costs at most half a ppm = 0.0127 DPI; ImageIO's own rounding stays
        // well inside 0.05 (PNG spec: ppm = round(dpi / 0.0254)).
        #expect(abs(decoded.dpi - dpi) <= 0.05, "DPI \(decoded.dpi) vs \(dpi) \(comment)")
    }

    private func pixelsFlatBytes(_ pixels: [ColorRGBA8]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(pixels.count * 4)
        for pixel in pixels {
            bytes.append(contentsOf: [pixel.red, pixel.green, pixel.blue, pixel.alpha])
        }
        return bytes
    }
}
