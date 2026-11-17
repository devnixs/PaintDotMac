import Foundation
import Testing

@testable import PaintDotMac

/// The gradient kernel (spec 0023 *Test plan*), exact equality against hand-computed
/// values — every expectation is from the spec's formulas or hand arithmetic, never from
/// running the code. "gray k" = (k, k, k, 255); P = (0,0,0,255), S = (255,255,255,255).
private let black = ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255)
private let white = ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255)

private func gray(_ k: UInt8) -> ColorRGBA8 { ColorRGBA8(red: k, green: k, blue: k, alpha: 255) }

/// A brush-clip test double: constant coverage inside `bounds`, 0 outside.
private struct RectMask: BrushClipMask {
    var bounds: PixelRect
    var coverageValue: UInt8 = 255

    func coverage(x: Int, y: Int) -> UInt8 {
        bounds.contains(PixelPoint(x: x, y: y)) ? coverageValue : 0
    }
}

private func transparentSurface(_ width: Int, _ height: Int) -> TiledSurface {
    TiledSurface(size: PixelSize(width: width, height: height))
}

private func filledSurface(_ width: Int, _ height: Int, _ color: ColorRGBA8) -> TiledSurface {
    var surface = transparentSurface(width, height)
    surface.fill(color)
    return surface
}

/// A P→S linear parameter pair across a 256×1 row, etc. — built per test.
private func parameters(type: GradientType = .linear,
                        mode: GradientMode = .color,
                        start: CGPoint, end: CGPoint,
                        startColor: ColorRGBA8 = black, endColor: ColorRGBA8 = white,
                        antialiasing: Bool = true,
                        blendMode: BlendMode = .normal) -> GradientParameters {
    GradientParameters(type: type, mode: mode, start: start, end: end,
                       startColor: startColor, endColor: endColor,
                       antialiasing: antialiasing, blendMode: blendMode)
}

struct GradientRendererTests {
    // MARK: - Weight & lerp

    @Test func weightRounding() {
        #expect(GradientRenderer.weight(0) == 0)
        #expect(GradientRenderer.weight(0.5) == 128)
        #expect(GradientRenderer.weight(0.375) == 96)
        #expect(GradientRenderer.weight(0.625) == 159)
        #expect(GradientRenderer.weight(0.75) == 191)
        #expect(GradientRenderer.weight(0.25) == 64)
        #expect(GradientRenderer.weight(1) == 255)
        #expect(GradientRenderer.weight(-3) == 0)
        #expect(GradientRenderer.weight(7) == 255)
        #expect(GradientRenderer.weight(.nan) == 0)
    }

    @Test func colorLerpIncludesAlpha() throws {
        #expect(GradientRenderer.lerp(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255),
                                      ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 51),
                                      weight: 128)
                    == ColorRGBA8(red: 127, green: 0, blue: 128, alpha: 153))
        var rng = SeededRandom(seed: 0x0023_0201)
        for _ in 0..<1000 {
            let a = rng.color()
            let b = rng.color()
            #expect(GradientRenderer.lerp(a, b, weight: 0) == a)
            #expect(GradientRenderer.lerp(a, b, weight: 255) == b)
        }
    }

    // MARK: - Per-type positions (exact pixels)

    @Test func linearRamp() throws {
        let before = transparentSurface(256, 1)
        var after = before
        let visited = GradientRenderer.render(
            parameters(start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 255.5, y: 0.5)),
            before: before, into: &after, clip: nil)
        #expect(visited == [TileCoordinate(column: 0, row: 0)])
        for x in 0..<256 {
            #expect(after.pixel(at: PixelPoint(x: x, y: 0)) == gray(UInt8(truncatingIfNeeded: x)),
                    "pixel \(x)")
        }
    }

    @Test func linearClampsBeforeStartAndAfterEnd() {
        let before = transparentSurface(300, 1)
        var after = before
        _ = GradientRenderer.render(
            parameters(start: CGPoint(x: 100.5, y: 0.5), end: CGPoint(x: 200.5, y: 0.5)),
            before: before, into: &after, clip: nil)
        #expect(after.pixel(at: PixelPoint(x: 50, y: 0)) == black)
        #expect(after.pixel(at: PixelPoint(x: 150, y: 0)) == gray(128))
        #expect(after.pixel(at: PixelPoint(x: 250, y: 0)) == white)
    }

    @Test func linearIsPerpendicularInvariant() {
        let before = transparentSurface(4, 10)
        var after = before
        _ = GradientRenderer.render(
            parameters(start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 0.5, y: 8.5)),
            before: before, into: &after, clip: nil)
        for x in 0..<4 {
            #expect(after.pixel(at: PixelPoint(x: x, y: 4)) == gray(128))
            #expect(after.pixel(at: PixelPoint(x: x, y: 0)) == black)
            #expect(after.pixel(at: PixelPoint(x: x, y: 9)) == white)
        }
    }

    @Test func reflected() {
        let before = transparentSurface(300, 1)
        var after = before
        _ = GradientRenderer.render(
            parameters(type: .linearReflected,
                       start: CGPoint(x: 100.5, y: 0.5), end: CGPoint(x: 200.5, y: 0.5)),
            before: before, into: &after, clip: nil)
        #expect(after.pixel(at: PixelPoint(x: 0, y: 0)) == white)
        #expect(after.pixel(at: PixelPoint(x: 50, y: 0)) == gray(128))
        #expect(after.pixel(at: PixelPoint(x: 100, y: 0)) == black)
        #expect(after.pixel(at: PixelPoint(x: 150, y: 0)) == gray(128))
        #expect(after.pixel(at: PixelPoint(x: 250, y: 0)) == white)
    }

    @Test func diamondAxisAligned() {
        let before = transparentSurface(101, 101)
        var after = before
        _ = GradientRenderer.render(
            parameters(type: .diamond,
                       start: CGPoint(x: 50.5, y: 50.5), end: CGPoint(x: 58.5, y: 50.5)),
            before: before, into: &after, clip: nil)
        #expect(after.pixel(at: PixelPoint(x: 50, y: 50)) == black)
        #expect(after.pixel(at: PixelPoint(x: 54, y: 50)) == gray(128))
        #expect(after.pixel(at: PixelPoint(x: 52, y: 51)) == gray(96))
        #expect(after.pixel(at: PixelPoint(x: 46, y: 48)) == gray(191))
        #expect(after.pixel(at: PixelPoint(x: 50, y: 58)) == white)
        #expect(after.pixel(at: PixelPoint(x: 60, y: 60)) == white)
    }

    @Test func diamondRotated() {
        let before = transparentSurface(101, 101)
        var after = before
        _ = GradientRenderer.render(
            parameters(type: .diamond,
                       start: CGPoint(x: 50.5, y: 50.5), end: CGPoint(x: 54.5, y: 54.5)),
            before: before, into: &after, clip: nil)
        #expect(after.pixel(at: PixelPoint(x: 52, y: 52)) == gray(128))
        #expect(after.pixel(at: PixelPoint(x: 52, y: 48)) == gray(128))
        #expect(after.pixel(at: PixelPoint(x: 54, y: 50)) == white)
    }

    @Test func radial() {
        let before = transparentSurface(101, 101)
        var after = before
        _ = GradientRenderer.render(
            parameters(type: .radial,
                       start: CGPoint(x: 50.5, y: 50.5), end: CGPoint(x: 58.5, y: 50.5)),
            before: before, into: &after, clip: nil)
        #expect(after.pixel(at: PixelPoint(x: 50, y: 50)) == black)
        #expect(after.pixel(at: PixelPoint(x: 53, y: 54)) == gray(159))  // distance 5 → 0.625
        #expect(after.pixel(at: PixelPoint(x: 50, y: 56)) == gray(191))
        #expect(after.pixel(at: PixelPoint(x: 56, y: 58)) == white)  // distance 10 > 8
        let four = [after.pixel(at: PixelPoint(x: 46, y: 50)),
                    after.pixel(at: PixelPoint(x: 54, y: 50)),
                    after.pixel(at: PixelPoint(x: 50, y: 46)),
                    after.pixel(at: PixelPoint(x: 50, y: 54))]
        #expect(Set(four).count == 1, "radial symmetry")
    }

    @Test func conical() {
        let before = transparentSurface(101, 101)
        var after = before
        _ = GradientRenderer.render(
            parameters(type: .conical,
                       start: CGPoint(x: 50.5, y: 50.5), end: CGPoint(x: 60.5, y: 50.5)),
            before: before, into: &after, clip: nil)
        #expect(after.pixel(at: PixelPoint(x: 60, y: 50)) == black)
        #expect(after.pixel(at: PixelPoint(x: 40, y: 50)) == white)
        #expect(after.pixel(at: PixelPoint(x: 50, y: 60)) == gray(128))
        #expect(after.pixel(at: PixelPoint(x: 50, y: 40)) == gray(128))
        #expect(after.pixel(at: PixelPoint(x: 55, y: 55)) == gray(64))
        // The exact start pixel center: atan2(0, 0) = 0 → P (no special case).
        #expect(after.pixel(at: PixelPoint(x: 50, y: 50)) == black)
    }

    @Test func conicalRotated() {
        let before = transparentSurface(101, 101)
        var after = before
        _ = GradientRenderer.render(
            parameters(type: .conical,
                       start: CGPoint(x: 50.5, y: 50.5), end: CGPoint(x: 50.5, y: 60.5)),
            before: before, into: &after, clip: nil)
        #expect(after.pixel(at: PixelPoint(x: 40, y: 50)) == gray(128))
        #expect(after.pixel(at: PixelPoint(x: 50, y: 40)) == white)
        #expect(after.pixel(at: PixelPoint(x: 60, y: 50)) == gray(128))
    }

    // MARK: - Compose

    @Test func colorModeOverOpaqueUsesNormalBlend() {
        // Pixel (0,0) sits at t = 0.5: start (−0.5, 0.5), end (1.5, 0.5).
        let p = parameters(start: CGPoint(x: -0.5, y: 0.5), end: CGPoint(x: 1.5, y: 0.5),
                           startColor: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255),
                           endColor: ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 51))
        #expect(GradientRenderer.composePixel(before: white, x: 0, y: 0, clip: 255,
                                              parameters: p)
                    == ColorRGBA8(red: 178, green: 102, blue: 179, alpha: 255))
        #expect(GradientRenderer.composePixel(before: .clear, x: 0, y: 0, clip: 255,
                                              parameters: p)
                    == ColorRGBA8(red: 127, green: 0, blue: 128, alpha: 153))
    }

    @Test func endpointColors() throws {
        // Color mode: primary → secondary, reversed swaps.
        #expect(GradientRenderer.endpointColors(mode: .color, primary: black, secondary: white,
                                                reversed: false)
                    == (start: black, end: white))
        #expect(GradientRenderer.endpointColors(mode: .color, primary: black, secondary: white,
                                                reversed: true)
                    == (start: white, end: black))
        // Transparency mode: primary alpha → 255 − secondary alpha (Paint.NET's inverse).
        let primary = ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 200)
        let secondary = ColorRGBA8(red: 40, green: 50, blue: 60, alpha: 100)
        let forward = GradientRenderer.endpointColors(mode: .transparency, primary: primary,
                                                      secondary: secondary, reversed: false)
        #expect(forward.start.alpha == 200)
        #expect(forward.end.alpha == 155)
        let reversed = GradientRenderer.endpointColors(mode: .transparency, primary: primary,
                                                       secondary: secondary, reversed: true)
        #expect(reversed.start.alpha == 155)
        #expect(reversed.end.alpha == 200)
        // The default black/white pair fades opaque → transparent.
        let defaults = GradientRenderer.endpointColors(mode: .transparency, primary: black,
                                                       secondary: white, reversed: false)
        #expect(defaults.start.alpha == 255)
        #expect(defaults.end.alpha == 0)
    }

    // MARK: - Transparency mode

    @Test func transparencyRamp() {
        let before = filledSurface(256, 1, ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        var after = before
        // The default black/white pair through `endpointColors`: α 255 → α 0.
        _ = GradientRenderer.render(
            parameters(mode: .transparency,
                       start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 255.5, y: 0.5),
                       startColor: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                       endColor: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0)),
            before: before, into: &after, clip: nil)
        for x in 0..<256 {
            #expect(after.pixel(at: PixelPoint(x: x, y: 0))
                        == ColorRGBA8(red: 255, green: 0, blue: 0,
                                      alpha: UInt8(255 - x)),
                    "pixel \(x)")
        }
        // Reversed: alpha x.
        let reversedParameters = parameters(
            mode: .transparency,
            start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 255.5, y: 0.5),
            startColor: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0),
            endColor: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255))
        var reversed = before
        _ = GradientRenderer.render(reversedParameters, before: before, into: &reversed,
                                    clip: nil)
        for x in 0..<256 {
            #expect(reversed.pixel(at: PixelPoint(x: x, y: 0))
                        == ColorRGBA8(red: 255, green: 0, blue: 0,
                                      alpha: UInt8(truncatingIfNeeded: x)),
                    "reversed pixel \(x)")
        }
    }

    @Test func transparencyMultipliesExistingAlpha() {
        // Gradient alpha 127 (both ends) over a pixel with alpha 128 → mul255(128, 127) = 64.
        let p = parameters(mode: .transparency,
                           start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 1.5, y: 0.5),
                           startColor: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 127),
                           endColor: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 127))
        let before = filledSurface(1, 1, ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 128))
        var after = before
        _ = GradientRenderer.render(p, before: before, into: &after, clip: nil)
        #expect(after.pixel(at: PixelPoint(x: 0, y: 0))
                    == ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 64))
    }

    @Test func transparencyKeepsRGBUnderZeroAlpha() {
        // D-33: pixel x = 255 of the transparency ramp is (255, 0, 0, 0) — RGB kept.
        let before = filledSurface(256, 1, ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        var after = before
        _ = GradientRenderer.render(
            parameters(mode: .transparency,
                       start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 255.5, y: 0.5),
                       startColor: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                       endColor: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0)),
            before: before, into: &after, clip: nil)
        #expect(after.pixel(at: PixelPoint(x: 255, y: 0))
                    == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 0))
    }

    @Test func transparencyIgnoresBlendMode() {
        // Transparency Mode composes alpha directly (no BlendOps call). Today `BlendMode`
        // has only `.normal`, so this asserts identical output for parameters differing
        // only in `blendMode` — a guard that stays valid when 0026 adds modes.
        let base = parameters(mode: .transparency,
                              start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 255.5, y: 0.5),
                              startColor: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                              endColor: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0))
        var withMode = base
        withMode.blendMode = .normal  // the only implemented mode until 0026
        let original = filledSurface(256, 1, .white)
        var first = original
        var second = original
        _ = GradientRenderer.render(base, before: original, into: &first, clip: nil)
        _ = GradientRenderer.render(withMode, before: original, into: &second, clip: nil)
        #expect(first == second)
    }

    // MARK: - Clip & antialiasing

    @Test func clipPartialCoverage() {
        // t = 0 at pixel (0,0): the start line through the pixel center.
        let p = parameters(start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 1.5, y: 0.5))
        // Color mode at t = 0, coverage 128 (AA on): P blended at alpha mul255(255,128)=128
        // over white → (127,127,127,255).
        #expect(GradientRenderer.composePixel(before: white, x: 0, y: 0, clip: 128,
                                              parameters: p)
                    == ColorRGBA8(red: 127, green: 127, blue: 127, alpha: 255))
        // Transparency mode with the default endpoint colors (start α 255 → end α 0) at
        // coverage 128: t = 0 → target = mul255(255, 255) = 255 → alpha unchanged 255;
        // t = 1 → target = mul255(255, 0) = 0 → alpha (255·127 + 127)/255 = 127.
        let forward = parameters(mode: .transparency,
                                 start: CGPoint(x: -0.5, y: 0.5), end: CGPoint(x: -0.4, y: 0.5),
                                 startColor: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                                 endColor: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0))
        #expect(GradientRenderer.composePixel(before: white, x: -1, y: 0, clip: 128,
                                              parameters: forward)
                    .alpha == 255)
        #expect(GradientRenderer.composePixel(before: white, x: 0, y: 0, clip: 128,
                                              parameters: forward)
                    .alpha == 127)
    }

    @Test func antialiasingOffThresholdsClip() {
        #expect(GradientRenderer.effectiveClip(127, antialiasing: false) == 0)
        #expect(GradientRenderer.effectiveClip(128, antialiasing: false) == 255)
        #expect(GradientRenderer.effectiveClip(1, antialiasing: true) == 1)
        // Rendering with coverage 127 and AA off leaves the pixel equal to before (the
        // pixel takes `before`, the tile keeps its storage).
        let before = filledSurface(1, 1, .white)
        var after = before
        let visited = GradientRenderer.render(
            parameters(start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 1.5, y: 0.5),
                       antialiasing: false),
            before: before, into: &after,
            clip: RectMask(bounds: PixelRect(x: 0, y: 0, width: 1, height: 1),
                           coverageValue: 127))
        #expect(visited == [TileCoordinate(column: 0, row: 0)])
        #expect(after.pixel(at: PixelPoint(x: 0, y: 0)) == .white)
        #expect(after.tile(at: TileCoordinate(column: 0, row: 0))?
                    .sharesStorage(with: before.tile(at: TileCoordinate(column: 0, row: 0))!)
                ?? false)
    }

    @Test func outsideClipBoundsUntouched() {
        let before = filledSurface(600, 300, .white)
        var after = before
        let visited = GradientRenderer.render(
            parameters(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 600, y: 300)),
            before: before, into: &after,
            clip: RectMask(bounds: PixelRect(x: 300, y: 100, width: 40, height: 40)))
        #expect(visited == [TileCoordinate(column: 1, row: 0)],
                "exactly the tiles intersecting the clip bounds")
        for y in stride(from: 0, to: 300, by: 7) {
            for x in stride(from: 0, to: 600, by: 11) {
                let inside = (300..<340).contains(x) && (100..<140).contains(y)
                guard !inside else { continue }
                #expect(after.pixel(at: PixelPoint(x: x, y: y)) == .white,
                        "(\(x), \(y)) outside the clip")
            }
        }
    }

    // MARK: - Robustness

    @Test func continuousAcrossTileBoundary() {
        let before = transparentSurface(512, 1)
        var after = before
        _ = GradientRenderer.render(
            parameters(start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 511.5, y: 0.5)),
            before: before, into: &after, clip: nil)
        let r255 = Int(after.pixel(at: PixelPoint(x: 255, y: 0)).red)
        let r256 = Int(after.pixel(at: PixelPoint(x: 256, y: 0)).red)
        #expect(abs(r255 - r256) <= 1, "no seam at the tile edge (x = 255/256)")
        for x in 1..<512 {
            let previous = Int(after.pixel(at: PixelPoint(x: x - 1, y: 0)).red)
            let current = Int(after.pixel(at: PixelPoint(x: x, y: 0)).red)
            #expect(current >= previous, "non-decreasing at x = \(x)")
        }
    }

    @Test func transparencyOnEmptyLayerAllocatesNothing() throws {
        let before = transparentSurface(300, 300)
        var after = before
        let visited = GradientRenderer.render(
            parameters(mode: .transparency,
                       start: CGPoint(x: 0, y: 0), end: CGPoint(x: 300, y: 300)),
            before: before, into: &after, clip: nil)
        #expect(!visited.isEmpty, "tiles were visited")
        for row in 0..<after.tileRows {
            for column in 0..<after.tileColumns {
                let coordinate = TileCoordinate(column: column, row: row)
                let beforeTile = before.tile(at: coordinate)
                let afterTile = after.tile(at: coordinate)
                if let beforeTile, let afterTile {
                    #expect(afterTile.sharesStorage(with: beforeTile),
                            "tile \(coordinate) keeps its storage")
                } else {
                    #expect(beforeTile == nil && afterTile == nil,
                            "tile \(coordinate) allocated or freed unexpectedly")
                }
            }
        }
        let diff = TileDiff.between(before: before, after: after,
                                    layerID: Layer(name: "layer", surface: before).id)
        #expect(diff.isEmpty)
    }

    @Test func nonFiniteIsDegenerate() {
        let nan = CGPoint(x: Double.nan, y: 0)
        var p = parameters(start: nan, end: CGPoint(x: 10, y: 10))
        #expect(p.isDegenerate)
        let before = filledSurface(16, 16, .white)
        var after = before
        #expect(GradientRenderer.render(p, before: before, into: &after, clip: nil).isEmpty)
        #expect(after == before)
        p.start = CGPoint(x: 0, y: 0)
        p.end = CGPoint(x: 0, y: 0)
        #expect(p.isDegenerate)  // start == end
        #expect(GradientRenderer.render(p, before: before, into: &after, clip: nil).isEmpty)
    }

    @Test func hugeDistanceDoesNotOverflow() {
        // start (0,0), end (1e7, 0): Double math, no overflow; pixel (0,0) weight 0 → P.
        let p = parameters(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1e7, y: 0))
        #expect(!p.isDegenerate)
        let t = GradientRenderer.position(.linear, start: p.start, end: p.end, x: 0, y: 0)
        #expect(GradientRenderer.weight(t) == 0)
        #expect(t.isFinite)
    }

    @Test(arguments: GradientType.allCases)
    func oneByOneCanvas(type: GradientType) throws {
        let before = filledSurface(1, 1, ColorRGBA8(red: 200, green: 40, blue: 90, alpha: 200))
        var after = before
        let p = parameters(type: type, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1))
        let visited = GradientRenderer.render(p, before: before, into: &after, clip: nil)
        #expect(visited == [TileCoordinate(column: 0, row: 0)])
        let expected = GradientRenderer.composePixel(before: before.pixel(at: PixelPoint(x: 0, y: 0)),
                                                     x: 0, y: 0, clip: 255, parameters: p)
        #expect(after.pixel(at: PixelPoint(x: 0, y: 0)) == expected)
    }

    @Test func renderIsPureFunctionOfBefore() throws {
        // Rendering A then B into the same surface equals rendering B straight from
        // `before` — the pending-gradient re-render contract (no accumulation).
        var rng = SeededRandom(seed: 0x0023_0202)
        let seed = 0x0023_0202
        let width = 300, height = 300
        let before = TestImages.surface(width: width, height: height) { _, _ in rng.color() }
        func randomParameters() -> GradientParameters {
            parameters(type: GradientType.allCases.randomElement(using: &rng)!,
                       mode: rng.next() % 2 == 0 ? .color : .transparency,
                       start: CGPoint(x: rng.double(in: -50...350), y: rng.double(in: -50...350)),
                       end: CGPoint(x: rng.double(in: -50...350), y: rng.double(in: -50...350)),
                       startColor: rng.color(), endColor: rng.color(),
                       antialiasing: rng.next() % 2 == 0)
        }
        for iteration in 0..<200 {
            let a = randomParameters()
            let b = randomParameters()
            var sequential = before
            _ = GradientRenderer.render(a, before: before, into: &sequential, clip: nil)
            _ = GradientRenderer.render(b, before: before, into: &sequential, clip: nil)
            var direct = before
            _ = GradientRenderer.render(b, before: before, into: &direct, clip: nil)
            #expect(sequential == direct,
                    "iteration \(iteration) (seed \(seed)) A=\(a) B=\(b)")
        }
    }
}
