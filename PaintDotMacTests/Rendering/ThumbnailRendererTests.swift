import Foundation
import Testing

@testable import PaintDotMac

/// `ThumbnailRenderer` (spec 0025 item 6): the fitted-size table, hand-computed checker
/// composites, the premultiplied box average, the tile-boundary walk against an
/// independent reference, and cancellation.
struct ThumbnailRendererTests {
    private func filled(_ size: PixelSize, _ color: ColorRGBA8) -> TiledSurface {
        var surface = TiledSurface(size: size)
        surface.fill(color)
        return surface
    }

    private func pixel(_ image: ThumbnailImage, _ x: Int, _ y: Int) -> ColorRGBA8 {
        image.pixels[y * image.size.width + x]
    }

    // MARK: - fittedSize (hand values, spec item 6)

    @Test func fittedSize() {
        func fitted(_ w: Int, _ h: Int) -> PixelSize {
            ThumbnailRenderer.fittedSize(for: PixelSize(width: w, height: h))
        }
        #expect(fitted(800, 600) == PixelSize(width: 80, height: 60))
        #expect(fitted(600, 800) == PixelSize(width: 60, height: 80))
        #expect(fitted(80, 80) == PixelSize(width: 80, height: 80))
        #expect(fitted(1, 1) == PixelSize(width: 80, height: 80))
        #expect(fitted(65535, 1) == PixelSize(width: 80, height: 1))
        #expect(fitted(1, 65535) == PixelSize(width: 1, height: 80))
        #expect(fitted(3, 2) == PixelSize(width: 80, height: 53))
    }

    // MARK: - Sampling

    @Test func opaqueRedLayer() throws {
        let surface = filled(PixelSize(width: 160, height: 160),
                             ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        let image = try ThumbnailRenderer().render(surface)
        #expect(image.size == PixelSize(width: 80, height: 80))
        #expect(Set(image.pixels) == [ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)])
    }

    /// An empty layer is pure checkerboard: `CheckerboardStyle.standard` colors, 4 px
    /// squares, top-left light (edge case: no allocated tile memory is read — the
    /// surface has no tiles at all).
    @Test func transparentLayerIsCheckerboard() throws {
        let surface = TiledSurface(size: PixelSize(width: 160, height: 160))
        let image = try ThumbnailRenderer().render(surface)
        let light = CheckerboardStyle.standard.lightColor
        let dark = CheckerboardStyle.standard.darkColor
        #expect(light == .white)
        #expect(dark == ColorRGBA8(red: 204, green: 204, blue: 204, alpha: 255))
        #expect(pixel(image, 0, 0) == light)
        #expect(pixel(image, 3, 3) == light)
        #expect(pixel(image, 4, 0) == dark)
        #expect(pixel(image, 4, 4) == light)
    }

    /// 8×8 half-alpha blue upscaled (nearest) over the checker: hand values from the
    /// spec's worked example — premul B = round(255×128/255) = 128, then
    /// `out = src_premul + checker × 127/255` rounded to nearest.
    @Test func halfAlphaOverChecker() throws {
        let surface = filled(PixelSize(width: 8, height: 8),
                             ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 128))
        let image = try ThumbnailRenderer().render(surface)
        #expect(image.size == PixelSize(width: 80, height: 80))
        #expect(pixel(image, 0, 0) == ColorRGBA8(red: 127, green: 127, blue: 255, alpha: 255))
        // (4, 0) sits over #CCCCCC: 204×127/255 = 101.6 → 102; 128 + 101.6 = 229.6 → 230.
        #expect(pixel(image, 4, 0) == ColorRGBA8(red: 102, green: 102, blue: 230, alpha: 255))
    }

    /// 2×1 white|black opaque fitted into box 1: one bin averages both pixels;
    /// 127.5 rounds half up to 128.
    @Test func boxAverage() throws {
        var surface = TiledSurface(size: PixelSize(width: 2, height: 1))
        surface.setPixel(.white, at: PixelPoint(x: 0, y: 0))
        surface.setPixel(.black, at: PixelPoint(x: 1, y: 0))
        let image = try ThumbnailRenderer().render(surface, box: 1)
        #expect(image.size == PixelSize(width: 1, height: 1))
        #expect(image.pixels == [ColorRGBA8(red: 128, green: 128, blue: 128, alpha: 255)])
    }

    /// 2×1 [opaque red, fully transparent green] into box 1: the average is taken over
    /// **premultiplied** colors, so the transparent pixel's green does not bleed.
    /// premul avg = (127.5, 0, 0, 127.5); over white → (255, 128, 128).
    @Test func premultipliedAverage() throws {
        var surface = TiledSurface(size: PixelSize(width: 2, height: 1))
        surface.setPixel(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255),
                         at: PixelPoint(x: 0, y: 0))
        surface.setPixel(ColorRGBA8(red: 0, green: 255, blue: 0, alpha: 0),
                         at: PixelPoint(x: 1, y: 0))
        let image = try ThumbnailRenderer().render(surface, box: 1)
        #expect(image.pixels == [ColorRGBA8(red: 255, green: 128, blue: 128, alpha: 255)])
    }

    /// A thumbnail shows the layer's own pixels — visibility, opacity, and blend mode
    /// are the *layer's* fields and the renderer only ever sees the surface, so a
    /// hidden opacity-0 layer's thumbnail equals the visible one's (edge case).
    @Test func ignoresLayerProperties() throws {
        let surface = filled(PixelSize(width: 40, height: 40),
                             ColorRGBA8(red: 7, green: 128, blue: 200, alpha: 255))
        let visible = Layer(name: "v", surface: surface)
        let hidden = Layer(name: "h", surface: surface, isVisible: false, opacity: 0)
        let renderer = ThumbnailRenderer()
        let left = try renderer.render(visible.surface)
        let right = try renderer.render(hidden.surface)
        #expect(left == right)
    }

    /// 600×300 seeded random (tiles on both sides of the 256 boundary, sparse holes)
    /// against an independent straightforward implementation of the spec's rule —
    /// exact equality.
    @Test func crossesTileBoundaryMatchesReference() throws {
        var generator = SeededRandom(seed: 0x5EED2026)
        var surface = TiledSurface(size: PixelSize(width: 600, height: 300))
        for y in stride(from: 0, to: 300, by: 3) {
            for x in stride(from: 0, to: 600, by: 2) {
                let value = generator.next()
                let color = ColorRGBA8(red: UInt8(truncatingIfNeeded: value),
                                       green: UInt8(truncatingIfNeeded: value >> 8),
                                       blue: UInt8(truncatingIfNeeded: value >> 16),
                                       alpha: UInt8(truncatingIfNeeded: value >> 32))
                surface.setPixel(color, at: PixelPoint(x: x, y: y))
            }
        }
        let reference = Self.referenceRender(surface)
        let actual = try ThumbnailRenderer().render(surface)
        #expect(actual.size == reference.size)
        var mismatches = 0
        for index in actual.pixels.indices where actual.pixels[index] != reference.pixels[index] {
            if mismatches < 4 {
                let x = index % actual.size.width, y = index / actual.size.width
                Issue.record("(\(x), \(y)): got \(actual.pixels[index]), want \(reference.pixels[index])")
            }
            mismatches += 1
        }
        #expect(mismatches == 0)
    }

    /// A cancelled task's render throws `CancellationError` (checked once per row).
    @Test func cancellationThrows() async {
        let surface = filled(PixelSize(width: 4000, height: 3000), .white)
        let task = Task.detached(priority: .utility) { () -> Bool in
            do {
                _ = try ThumbnailRenderer().render(surface)
                return false
            } catch is CancellationError {
                return true
            } catch {
                Issue.record("unexpected error \(error)")
                return false
            }
        }
        task.cancel()
        let threw = await task.value
        #expect(threw, "the render must notice the cancellation and throw")
    }

    // MARK: - Reference implementation

    /// The spec's rule, implemented directly (no tiles, no bin precomputation): source
    /// pixel centers inside the bin rect are averaged **premultiplied** in Float, in
    /// the same row-major order the renderer accumulates them, then composited over the
    /// checkerboard — the exact-value oracle for `crossesTileBoundaryMatchesReference`.
    private static func referenceRender(_ surface: TiledSurface) -> ThumbnailImage {
        let out = ThumbnailRenderer.fittedSize(for: surface.size)
        let w = surface.size.width, h = surface.size.height
        let downscale = Double(out.width) < Double(w) || Double(out.height) < Double(h)
        func starts(_ source: Int, _ thumb: Int) -> [Int] {
            (0...thumb).map { t in
                min(source, max(0, Int(ceil(Double(t) * Double(source) / Double(thumb) - 0.5))))
            }
        }
        let xs = starts(w, out.width), ys = starts(h, out.height)
        let light = CheckerboardStyle.standard.lightColor
        let dark = CheckerboardStyle.standard.darkColor
        var pixels: [ColorRGBA8] = []
        pixels.reserveCapacity(out.width * out.height)
        for ty in 0..<out.height {
            for tx in 0..<out.width {
                var sumR = Float(0), sumG = Float(0), sumB = Float(0), sumA = Float(0)
                var count = Float(0)
                if downscale {
                    for sy in ys[ty]..<max(ys[ty], ys[ty + 1]) {
                        for sx in xs[tx]..<max(xs[tx], xs[tx + 1]) {
                            let c = surface.pixel(at: PixelPoint(x: sx, y: sy))
                            let fa = Float(c.alpha)
                            let scale = fa / 255
                            sumR += Float(c.red) * scale
                            sumG += Float(c.green) * scale
                            sumB += Float(c.blue) * scale
                            sumA += fa
                            count += 1
                        }
                    }
                } else {
                    let sx = min(w - 1, max(0, Int(floor((Double(tx) + 0.5) * Double(w) / Double(out.width)))))
                    let sy = min(h - 1, max(0, Int(floor((Double(ty) + 0.5) * Double(h) / Double(out.height)))))
                    let c = surface.pixel(at: PixelPoint(x: sx, y: sy))
                    let fa = Float(c.alpha)
                    let scale = fa / 255
                    sumR = Float(c.red) * scale
                    sumG = Float(c.green) * scale
                    sumB = Float(c.blue) * scale
                    sumA = fa
                    count = 1
                }
                let checker = ((tx / 4 + ty / 4) & 1 == 0) ? light : dark
                let r: Float, g: Float, b: Float, a: Float
                if count == 0 {
                    r = 0; g = 0; b = 0; a = 0
                } else {
                    r = sumR / count; g = sumG / count; b = sumB / count; a = sumA / count
                }
                let inverse = (255 - a) / 255
                func compose(_ premul: Float, _ checkerValue: UInt8) -> UInt8 {
                    UInt8(min(255, max(0, (premul + Float(checkerValue) * inverse + 0.5).rounded(.down))))
                }
                pixels.append(ColorRGBA8(red: compose(r, checker.red),
                                         green: compose(g, checker.green),
                                         blue: compose(b, checker.blue),
                                         alpha: 255))
            }
        }
        return ThumbnailImage(size: out, pixels: pixels)
    }
}
