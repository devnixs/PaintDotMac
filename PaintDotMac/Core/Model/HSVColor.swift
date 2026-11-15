import Foundation

/// HSV on Paint.NET's scales — hue 0–360°, saturation and value 0–100 (C-2). Every value is
/// normalized on the way in, so a stored `HSVColor` is always usable and never a trap.
struct HSVColor: Equatable, Sendable {
    /// `[0, 360)` degrees.
    var hue: Double
    /// `[0, 100]`.
    var saturation: Double
    /// `[0, 100]`.
    var value: Double

    static let hueTurn: Double = 360
    static let percentFull: Double = 100
    private static let channelFull: Double = 255
    private static let degreesPerSector: Double = 60

    init(hue: Double, saturation: Double, value: Double) {
        self.hue = Self.normalizedHueDegrees(hue)
        self.saturation = Self.clampedPercent(saturation)
        self.value = Self.clampedPercent(value)
    }

    /// The forward conversion, alpha ignored. Ties check red first, then green, then blue.
    init(rgb: ColorRGBA8) {
        let red = Double(rgb.red)
        let green = Double(rgb.green)
        let blue = Double(rgb.blue)
        let maxChannel = max(red, green, blue)
        let minChannel = min(red, green, blue)
        let delta = maxChannel - minChannel

        var degrees: Double = 0
        if delta != 0 {
            if maxChannel == red {
                degrees = Self.degreesPerSector * ((green - blue) / delta)
            } else if maxChannel == green {
                degrees = Self.degreesPerSector * ((blue - red) / delta + 2)
            } else {
                degrees = Self.degreesPerSector * ((red - green) / delta + 4)
            }
        }
        hue = Self.normalizedHueDegrees(degrees)
        saturation = maxChannel == 0 ? 0 : delta / maxChannel * Self.percentFull
        value = maxChannel / Self.channelFull * Self.percentFull
    }

    /// The inverse conversion. Rounding is **half away from zero** (127.5 → 128), the rule that
    /// makes `HSVColor(rgb: c).rgb(alpha: c.alpha) == c` for every 8-bit color.
    func rgb(alpha: UInt8) -> ColorRGBA8 {
        let chroma = value / Self.percentFull * (saturation / Self.percentFull)
        let huePosition = hue / Self.degreesPerSector
        let sector = min(max(Int(huePosition.rounded(.down)), 0), 5)
        let secondary = chroma * (1 - abs(huePosition.truncatingRemainder(dividingBy: 2) - 1))
        let match = value / Self.percentFull - chroma

        let first: Double
        let second: Double
        let third: Double
        switch sector {
        case 0: (first, second, third) = (chroma, secondary, 0)
        case 1: (first, second, third) = (secondary, chroma, 0)
        case 2: (first, second, third) = (0, chroma, secondary)
        case 3: (first, second, third) = (0, secondary, chroma)
        case 4: (first, second, third) = (secondary, 0, chroma)
        default: (first, second, third) = (chroma, 0, secondary)
        }
        return ColorRGBA8(red: Self.quantize(first + match),
                          green: Self.quantize(second + match),
                          blue: Self.quantize(third + match),
                          alpha: alpha)
    }

    /// Slider readouts. A hue of 359.5 or more displays as 360 — the Hue slider's range is
    /// 0–360, so that is on scale.
    var displayHue: Int { Self.display(hue) }
    var displaySaturation: Int { Self.display(saturation) }
    var displayValue: Int { Self.display(value) }

    /// Wraps into `[0, 360)`; NaN and infinity become 0.
    static func normalizedHueDegrees(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let wrapped = degrees.truncatingRemainder(dividingBy: hueTurn)
        return wrapped < 0 ? wrapped + hueTurn : wrapped
    }

    static func clampedPercent(_ percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        return min(max(percent, 0), percentFull)
    }

    private static func display(_ percent: Double) -> Int {
        Int(percent.rounded(.toNearestOrAwayFromZero))
    }

    private static func quantize(_ component: Double) -> UInt8 {
        let scaled = component * channelFull
        guard scaled.isFinite else { return 0 }
        return UInt8(clamping: Int(scaled.rounded(.toNearestOrAwayFromZero)))
    }
}
