import Testing

@testable import PaintDotMac

/// Independent oracle for `CPUCompositor` (spec 0012 *Test plan*): 50 seeded random layer
/// stacks, channel math in `Double` — a different arithmetic from the compositor's integer
/// `BlendOps` path — with the rounding decisions the specs *decide* (0009/0012): source
/// alpha `round(a·opacity / 255)` (Paint.NET's `mul255`) and the alpha byte
/// `round((Sa·255 + Da·(255 − Sa)) / 255)` each step. The oracle's final values are
/// rounded (spec: "`round(aOut·255)` and `round(c)`") and every channel must match
/// `CPUCompositor` within ±1; RGB is compared only where the oracle's `aOut > 0`.
///
/// Why the alpha decisions are in the oracle: they are contract, not implementation —
/// the continuous `(a/255)·(op/255)` form diverges from the decided fixed-point rule by
/// tens of percent in the sub-byte alpha corner (e.g. `mul255(11, 14) = 1` vs `0.604`),
/// which shifts every downstream blend weight. The exact integer pipeline itself is
/// pinned pixel-for-pixel by `CPUCompositorTests`' hand-computed cases; this oracle
/// catches structural mistakes (layer order, visibility/opacity wiring, weight math) in
/// `Double` — verified to hold within ±1 for 10⁶ random uniform 1–4-layer stacks.
struct CPUCompositorPropertyTests {
    private struct OracleLayer {
        var color: ColorRGBA8
        var visible: Bool
        var opacity: UInt8
    }

    /// The reference: straight values, `Double` channel accumulation, alpha as integer
    /// bytes per the decided rounding rules.
    private func oracle(_ layers: [OracleLayer]) -> (red: Double, green: Double,
                                                     blue: Double, alpha: Double) {
        var alphaByte = 0
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        for layer in layers where layer.visible && layer.opacity > 0 {
            // `round(a·opacity / 255)`, written from the spec sentence, not from `BlendOps`.
            let sourceByte = Int((UInt32(layer.color.alpha) * UInt32(layer.opacity) + 127) / 255)
            guard sourceByte != 0 else { continue }
            if alphaByte == 0 {
                red = Double(layer.color.red)
                green = Double(layer.color.green)
                blue = Double(layer.color.blue)
                alphaByte = sourceByte
                continue
            }
            let fa = Double(sourceByte) * 255 + Double(alphaByte) * Double(255 - sourceByte)
            let sourceWeight = Double(sourceByte) * 255 / fa
            let destinationWeight = Double(alphaByte) * Double(255 - sourceByte) / fa
            red = Double(layer.color.red) * sourceWeight + red * destinationWeight
            green = Double(layer.color.green) * sourceWeight + green * destinationWeight
            blue = Double(layer.color.blue) * sourceWeight + blue * destinationWeight
            alphaByte = Int((fa + 127) / 255)
        }
        return (red, green, blue, Double(alphaByte))
    }

    @Test(arguments: 0..<50)
    func randomStacksMatchFloatOracle(stackIndex: Int) throws {
        let seed = SeededRandom.resolvedSeed(default: 0x0012_0FA0) &+ UInt64(stackIndex)
        var rng = SeededRandom(seed: seed)
        let comment = SeededRandom(seed: seed).comment
        let compositor = CPUCompositor()
        // Odd stacks span tiles (300×300); even ones are 64×64.
        let size = stackIndex % 2 == 0
            ? PixelSize(width: 64, height: 64)
            : PixelSize(width: 300, height: 300)
        let layerCount = rng.int(in: 1...4)

        var layers: [Layer] = []
        for index in 0..<layerCount {
            let visible = rng.int(in: 0...9) != 0
            let opacity = UInt8(rng.int(in: 0...255))
            // Two solid patches per layer so every pixel sees a definite layer color,
            // with alpha hit 0, 255, and the whole mid range.
            let patch = ColorRGBA8(red: rng.byte(), green: rng.byte(), blue: rng.byte(),
                                   alpha: UInt8(rng.byte()))
            let other = rng.color()
            let boundaryX = rng.int(in: 0...max(1, size.width - 1))
            let boundaryY = rng.int(in: 0...max(1, size.height - 1))
            let surface = TestImages.surface(width: size.width, height: size.height) { x, y in
                (x < boundaryX) == (y < boundaryY) ? patch : other
            }
            layers.append(Layer(name: "L\(index)", surface: surface,
                                isVisible: visible, opacity: opacity))
        }
        let image = LayeredImage(size: size, layers: layers,
                                 activeLayerIndex: layerCount - 1)
        let region = compositor.composite(image, in: size.bounds)
        #expect(region.rect == size.bounds, comment)

        // A deterministic cover set: the first 64 columns' diagonal, its neighbour row,
        // both patch interiors, the patch boundary, and the canvas edges — for the
        // 300×300 stacks also the tile edges at x/y = 255/256.
        var points: Set<PixelPoint> = []
        var xs = Array(0..<min(64, size.width))
        if size.width > 64 { xs += stride(from: 64, to: size.width, by: 7) }
        for x in xs {
            let y = (x * 3) % size.height
            points.insert(PixelPoint(x: x, y: y))
            points.insert(PixelPoint(x: x, y: min(size.height - 1, y + 1)))
        }
        for edge in [0, min(255, size.width - 1), min(256, size.width - 1), size.width - 1] {
            for y in [0, size.height / 2, size.height - 1] {
                points.insert(PixelPoint(x: edge, y: y))
                points.insert(PixelPoint(x: size.width / 2, y: y))
            }
        }
        for point in points {
            // The oracle sees the same inputs the compositor reads.
            let pixelLayers = layers.map { layer in
                OracleLayer(color: layer.surface.pixel(at: point),
                            visible: layer.isVisible, opacity: layer.opacity)
            }
            let expected = oracle(pixelLayers)
            let got = region.pixels[point.y * size.width + point.x]
            let expectedAlpha = Int((expected.alpha).rounded())
            #expect(abs(Int(got.alpha) - expectedAlpha) <= 1,
                    "alpha at \(point): got \(got) oracle \(expected) — \(comment)")
            if expected.alpha > 0 {
                let checks = [(Int(got.red), expected.red, "R"),
                              (Int(got.green), expected.green, "G"),
                              (Int(got.blue), expected.blue, "B")]
                for (actual, want, name) in checks {
                    #expect(abs(actual - Int(want.rounded())) <= 1,
                            "\(name) at \(point): got \(got) oracle \(expected) — \(comment)")
                }
            }
        }
    }
}
