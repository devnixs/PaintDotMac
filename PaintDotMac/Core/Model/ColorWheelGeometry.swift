import CoreGraphics
import Foundation

/// Point ↔ (hue, saturation) for the color wheel, in **view coordinates with y pointing down**
/// (C-2). Hue 0° (red) is at 3 o'clock and increases counterclockwise on screen — 90° at 12
/// o'clock, 180° at 9 o'clock, 270° at 6 o'clock — with saturation 0 at the center and 100 at
/// the rim. The wheel is drawn at value 100 from these same numbers
/// (`ColorWheelImage`), so what the user sees is what a click selects.
enum ColorWheelGeometry {
    /// Paint.NET snaps the hue to 15° under ⇧⌘.
    static let hueSnapStep: Double = 15
    private static let degreesPerRadian: Double = 180 / .pi
    private static let radiansPerDegree: Double = Double.pi / 180

    /// What the pointer selects at `point`. `nil` for a degenerate wheel; points outside the
    /// rim clamp to saturation 100, so a drag may leave the wheel. The exact center has no
    /// direction (hue 0 here) — the view passes the target slot's cached hue instead.
    static func hueSaturation(at point: CGPoint, center: CGPoint, radius: Double)
        -> (hue: Double, saturation: Double)? {
        guard radius > 0 else { return nil }
        let dx = Double(point.x - center.x)
        let dy = Double(center.y - point.y)  // y is down, so up on screen is a positive dy
        let distance = (dx * dx + dy * dy).squareRoot()
        let hue = distance == 0 ? 0
            : HSVColor.normalizedHueDegrees(atan2(dy, dx) * degreesPerRadian)
        return (hue, min(distance / radius, 1) * HSVColor.percentFull)
    }

    /// Where a (hue, saturation) pair draws its marker — the inverse of `hueSaturation`.
    static func point(hue: Double, saturation: Double, center: CGPoint, radius: Double)
        -> CGPoint {
        let radians = HSVColor.normalizedHueDegrees(hue) * radiansPerDegree
        let distance = HSVColor.clampedPercent(saturation) / HSVColor.percentFull * radius
        return CGPoint(x: center.x + CGFloat(cos(radians) * distance),
                       y: center.y - CGFloat(sin(radians) * distance))
    }

    /// What a drag may change, from that drag event's modifiers: ⌘ hue only, ⌥ saturation only,
    /// ⇧⌘ hue snapped to 15° (⌥ with ⌘ stays hue-only), anything else free.
    enum Constraint: Sendable, Equatable {
        case free
        case hueOnly
        case saturationOnly
        case hueSnapped

        static func constraint(command: Bool, option: Bool, shift: Bool) -> Constraint {
            if command { return shift ? .hueSnapped : .hueOnly }
            if option { return .saturationOnly }
            return .free
        }
    }

    /// Applies `constraint`, keeping the components it pins at `current` — the target slot's
    /// cached HSV at drag start.
    static func constrained(hue: Double, saturation: Double, current: HSVColor,
                            constraint: Constraint) -> (hue: Double, saturation: Double) {
        switch constraint {
        case .free: (hue, saturation)
        case .hueOnly: (hue, current.saturation)
        case .saturationOnly: (current.hue, saturation)
        case .hueSnapped: (snapped(hue), current.saturation)
        }
    }

    private static func snapped(_ hue: Double) -> Double {
        let steps = (hue / hueSnapStep).rounded(.toNearestOrAwayFromZero)
        // 24 steps is a full turn, which is hue 0 again.
        return HSVColor.normalizedHueDegrees(steps * hueSnapStep)
    }
}
