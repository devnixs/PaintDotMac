import Foundation

/// Length units for the status bar (spec 0004, APP-5, D-7). Inches and centimeters derive
/// from the document's single DPI (`LayeredImage.dpi`).
enum MeasurementUnit: String, CaseIterable, Sendable {
    case pixels = "px"
    case inches = "in"
    case centimeters = "cm"

    /// Paint.NET's popup spellings.
    var displayName: String {
        switch self {
        case .pixels: return "Pixels"
        case .inches: return "Inches"
        case .centimeters: return "Centimeters"
        }
    }

    /// Paint.NET's fallback for a missing or malformed DPI (APP-5).
    static func sanitizedDPI(_ dpi: Double) -> Double {
        dpi.isFinite && dpi > 0 ? dpi : 96
    }

    func value(fromPixels pixels: Double, dpi: Double) -> Double {
        let resolved = Self.sanitizedDPI(dpi)
        switch self {
        case .pixels: return pixels
        case .inches: return pixels / resolved
        case .centimeters: return pixels / resolved * 2.54
        }
    }

    /// The status-bar text for one measurement: an integer for pixels; inches/centimeters
    /// rounded half away from zero to two decimals, printed with exactly two decimals and a
    /// "." separator regardless of locale (the app is English-only, PRD §2.2 — a "," would
    /// collide with the coordinate separator). A value that rounds to −0 prints "0.00".
    func format(pixels: Int, dpi: Double) -> String {
        let value = value(fromPixels: Double(pixels), dpi: dpi)
        switch self {
        case .pixels:
            return String(pixels)
        case .inches, .centimeters:
            let scaled = (value * 100).rounded(.toNearestOrAwayFromZero)
            // A pathological DPI (a `LayeredImage` may carry any finite positive DPI, e.g.
            // 1e-15 from a malformed file) or an extreme cursor coordinate makes `scaled`
            // infinite or a finite Double beyond `Int`'s range; the conversion must never
            // trap — show the raw pixel count rather than crash or print "inf".
            guard scaled.isFinite, scaled >= -9.0e18, scaled <= 9.0e18 else {
                return String(pixels)
            }
            guard scaled != 0 else { return "0.00" }
            let sign = scaled < 0 ? "-" : ""
            let magnitude = Int(scaled.signorm())
            return "\(sign)\(magnitude / 100).\(String(format: "%02d", magnitude % 100))"
        }
    }

    func formatPoint(_ p: PixelPoint, dpi: Double) -> String {
        "\(format(pixels: p.x, dpi: dpi)), \(format(pixels: p.y, dpi: dpi))"
    }

    func formatSize(_ s: PixelSize, dpi: Double) -> String {
        "\(format(pixels: s.width, dpi: dpi)) × \(format(pixels: s.height, dpi: dpi))"
    }
}

private extension Double {
    /// `abs` that survives `Double.greatestFiniteMagnitude` (a raw `Int(scaled)` argument
    /// must never overflow the `Int` conversion below).
    func signorm() -> Double { self < 0 ? -self : self }
}
