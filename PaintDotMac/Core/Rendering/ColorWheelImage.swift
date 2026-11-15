import CoreGraphics
import Foundation

/// The wheel bitmap, generated from `ColorWheelGeometry` at value 100 (C-2) so the drawn colors
/// and the hit-testing can never disagree. Straight-alpha RGBA8 (rule 4) with a one-pixel
/// antialiased rim; `diameter <= 0` produces nothing.
enum ColorWheelImage {
    /// Row-major, `index = py * diameter + px`, y down — the same orientation the view draws in.
    static func makePixels(diameter: Int) -> [ColorRGBA8] {
        guard diameter > 0 else { return [] }
        let radius = Double(diameter) / 2
        let center = CGPoint(x: radius, y: radius)
        var pixels: [ColorRGBA8] = []
        pixels.reserveCapacity(diameter * diameter)
        for py in 0..<diameter {
            for px in 0..<diameter {
                let sample = CGPoint(x: Double(px) + 0.5, y: Double(py) + 0.5)
                let geometry = ColorWheelGeometry.hueSaturation(at: sample, center: center,
                                                                radius: radius)
                let color = HSVColor(hue: geometry?.hue ?? 0,
                                     saturation: geometry?.saturation ?? 0,
                                     value: HSVColor.percentFull).rgb(alpha: 255)
                pixels.append(ColorRGBA8(red: color.red, green: color.green, blue: color.blue,
                                         alpha: rimAlpha(sample: sample, center: center,
                                                          radius: radius)))
            }
        }
        return pixels
    }

    /// 8-bit sRGB straight alpha, ready for `NSImage`/`CGImage` drawing.
    static func makeCGImage(diameter: Int) -> CGImage? {
        let pixels = makePixels(diameter: diameter)
        guard !pixels.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(pixels.count * 4)
        for color in pixels {
            bytes.append(contentsOf: [color.red, color.green, color.blue, color.alpha])
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData)
        else { return nil }
        return CGImage(width: diameter, height: diameter, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: diameter * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// `round(255 × clamp(radius − dist + 0.5, 0, 1))`: fully inside the rim is opaque, fully
    /// outside is clear, and the pixels the rim crosses fade.
    static func rimAlpha(sample: CGPoint, center: CGPoint, radius: Double) -> UInt8 {
        let dx = Double(sample.x - center.x)
        let dy = Double(sample.y - center.y)
        let distance = (dx * dx + dy * dy).squareRoot()
        let coverage = min(max(radius - distance + 0.5, 0), 1)
        return UInt8(clamping: Int((coverage * 255).rounded(.toNearestOrAwayFromZero)))
    }
}
