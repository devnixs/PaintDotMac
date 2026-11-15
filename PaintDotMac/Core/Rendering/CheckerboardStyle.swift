import Foundation

/// Checkerboard behind transparent image areas (spec 0003, CAN-4). Paint.NET's colors, fixed
/// size in **points** — the squares do not scale with zoom. `CheckerboardStyle.standard` is
/// used directly until 0046 makes the style a setting.
struct CheckerboardStyle: Equatable, Sendable {
    /// Square side in points; > 0.
    var squareSize: Double
    var lightColor: ColorRGBA8   // opaque
    var darkColor: ColorRGBA8    // opaque

    /// Paint.NET's light checkerboard: 8 pt squares, #FFFFFF and #CCCCCC, top-left light.
    static let standard = CheckerboardStyle(
        squareSize: 8,
        lightColor: ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255),
        darkColor: ColorRGBA8(red: 204, green: 204, blue: 204, alpha: 255)
    )

    init(squareSize: Double, lightColor: ColorRGBA8, darkColor: ColorRGBA8) {
        self.squareSize = squareSize
        self.lightColor = lightColor
        self.darkColor = darkColor
    }

    /// The color of device pixel `(dx, dy)` for an image whose top-left device pixel is
    /// `(ox, oy)`. The same formula `Canvas.metal` implements: `floor` division by
    /// `squareSize · backingScale` so negative offsets alternate correctly, light when
    /// `i + j` is even.
    func color(deviceX dx: Int, deviceY dy: Int, imageOrigin: (x: Int, y: Int), backingScale: Double) -> ColorRGBA8 {
        let side = squareSize * backingScale
        guard side.isFinite, side > 0 else { return lightColor }
        let i = floor((Double(dx) - Double(imageOrigin.x)) / side)
        let j = floor((Double(dy) - Double(imageOrigin.y)) / side)
        // Parity of `i + j` for integers held as Doubles; `truncatingRemainder` keeps the
        // sign of a negative sum, so compare against 0 after taking its magnitude.
        let parity = abs((i + j).truncatingRemainder(dividingBy: 2))
        return parity == 0 ? lightColor : darkColor
    }
}
