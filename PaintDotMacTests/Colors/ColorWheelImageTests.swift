import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// The wheel bitmap (C-2): it must be the exact colors `ColorWheelGeometry` hit-tests, with a
/// one-pixel antialiased rim. Expected values are hand-computed from spec 0007's formulas.
struct ColorWheelImageTests {
    /// Diameter 101 → radius 50.5, center (50.5, 50.5): pixel (50, 50) samples the center.
    private static let diameter = 101

    private func pixel(_ px: Int, _ py: Int, diameter: Int = Self.diameter) -> ColorRGBA8 {
        let pixels = ColorWheelImage.makePixels(diameter: diameter)
        #expect(pixels.count == diameter * diameter)
        guard px >= 0, py >= 0, px < diameter, py < diameter else {
            Issue.record("pixel (\(px), \(py)) is outside \(diameter)")
            return .clear
        }
        return pixels[py * diameter + px]
    }

    @Test func centerIsWhite() {
        #expect(pixel(50, 50) == ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255))
    }

    @Test func eastEdgeIsRed() {
        // Pixel (99, 50) samples (99.5, 50.5): dist 49, hue 0, s = 49 / 50.5 = 0.970297,
        // m = 0.029703 → 0.029703 × 255 = 7.57 → 8; alpha clamp(50.5 − 49 + 0.5) = 1.
        #expect(pixel(99, 50) == ColorRGBA8(red: 255, green: 8, blue: 8, alpha: 255))
    }

    @Test func northIsHue90() {
        // Pixel (50, 1) samples (50.5, 1.5): dy 49 → hue 90 (counterclockwise from 3 o'clock),
        // sector 1: x = 0.485149 → r = (0.485149 + 0.029703) × 255 = 131.29 → 131.
        #expect(pixel(50, 1) == ColorRGBA8(red: 131, green: 255, blue: 8, alpha: 255))
    }

    @Test func southIsHue270() {
        // Pixel (50, 99) samples (50.5, 99.5): dy = −49 → hue 270. Sector 4 with s 0.970297:
        // c 0.970297, x 0.485149, m 0.029703 → r = 131.29 → 131, g = 7.57 → 8, b = 255.
        #expect(pixel(50, 99) == ColorRGBA8(red: 131, green: 8, blue: 255, alpha: 255))
    }

    @Test func cornersAreTransparent() {
        #expect(pixel(0, 0).alpha == 0)
        #expect(pixel(100, 100).alpha == 0)
    }

    @Test func rimIsAntialiased() {
        // Diameter 100: radius 50, center (50, 50). Pixel (99, 50) samples (99.5, 50.5):
        // dist = √2450.5 = 49.50253 → alpha = round(255 × (50 − 49.50253 + 0.5)) = 254.
        #expect(pixel(99, 50, diameter: 100).alpha == 254)
        // Pixel (99, 45) samples (99.5, 45.5): dist = √2470.5 = 49.70415 →
        // round(255 × 0.79585) = 203, so the rim really fades rather than stepping.
        #expect(pixel(99, 45, diameter: 100).alpha == 203)
        // Pixel (99, 20) samples (99.5, 20.5): dist ≈ 57.6 → a whole pixel past the rim.
        #expect(pixel(99, 20, diameter: 100).alpha == 0)
    }

    @Test func zeroDiameter() {
        #expect(ColorWheelImage.makePixels(diameter: 0).isEmpty)
        #expect(ColorWheelImage.makePixels(diameter: -4).isEmpty)
        #expect(ColorWheelImage.makeCGImage(diameter: 0) == nil)
        #expect(ColorWheelImage.makeCGImage(diameter: -1) == nil)
    }

    @Test func matchesGeometry() {
        let diameter = Self.diameter
        let pixels = ColorWheelImage.makePixels(diameter: diameter)
        let radius = Double(diameter) / 2
        let center = CGPoint(x: radius, y: radius)
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x5EED_0704))
        for _ in 0..<500 {
            let px = rng.int(in: 0...(diameter - 1))
            let py = rng.int(in: 0...(diameter - 1))
            let sample = CGPoint(x: Double(px) + 0.5, y: Double(py) + 0.5)
            let dx = sample.x - center.x
            let dy = center.y - sample.y
            let dist = (dx * dx + dy * dy).squareRoot()
            guard dist <= radius - 1 else { continue }  // interior only: the rim fades out
            guard let geometry = ColorWheelGeometry.hueSaturation(at: sample, center: center,
                                                                  radius: radius)
            else { Issue.record("an interior sample must map"); continue }
            let expected = HSVColor(hue: geometry.hue, saturation: geometry.saturation, value: 100)
                .rgb(alpha: 255)
            let got = pixels[py * diameter + px]
            let detail = "pixel (\(px), \(py)) is \(got), the geometry says \(expected)"
            #expect(got == expected, "\(detail) — \(rng.comment)")
        }
    }

    /// The image is straight-alpha RGBA8 (rule 4), and CoreGraphics can draw it: the center
    /// lands opaque white and the corners stay transparent over a cleared (transparent) buffer.
    @Test func cgImageCarriesTheSamePixelsAndDraws() throws {
        let diameter = 21
        let pixels = ColorWheelImage.makePixels(diameter: diameter)
        let image = try #require(ColorWheelImage.makeCGImage(diameter: diameter))
        #expect(image.width == diameter)
        #expect(image.height == diameter)
        #expect(image.bitsPerComponent == 8)
        #expect(image.alphaInfo == .last, "straight alpha, not premultiplied")
        let data = try #require(image.dataProvider?.data as Data?)
        #expect(data.count == diameter * diameter * 4)
        let bytes = Array(data)
        for (index, color) in pixels.enumerated() {
            let offset = index * 4
            #expect([bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]]
                    == [color.red, color.green, color.blue, color.alpha],
                    "pixel \(index) must survive into the CGImage unchanged")
        }

        var buffer = [UInt8](repeating: 7, count: diameter * diameter * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: &buffer, width: diameter, height: diameter,
                                             bitsPerComponent: 8, bytesPerRow: diameter * 4,
                                             space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: diameter, height: diameter))
        context.draw(image, in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        let middle = ((diameter / 2) * diameter + diameter / 2) * 4
        #expect([buffer[middle], buffer[middle + 1], buffer[middle + 2], buffer[middle + 3]]
                == [255, 255, 255, 255], "the drawn center is opaque white")
        #expect([buffer[0], buffer[1], buffer[2], buffer[3]] == [0, 0, 0, 0],
                "a corner outside the rim draws nothing")
    }
}
