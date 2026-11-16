import Testing

@testable import PaintDotMac

/// `PixelSampler` (spec 0012 *Test plan*). Expected values are hand-computed from the
/// spec's alpha-weighted averaging rule (`c = (2·S_c + S_a) / (2·S_a)`,
/// `a = (2·S_a + n) / (2·n)`, integer division) and the compositor contract — never from
/// running the code under test.
struct PixelSamplerTests {
    private let sampler = CPUCompositor()

    private func solid(_ color: ColorRGBA8, _ width: Int, _ height: Int) -> LayeredImage {
        .blank(size: PixelSize(width: width, height: height), fill: color)
    }

    private func point(_ x: Int, _ y: Int) -> PixelPoint { PixelPoint(x: x, y: y) }

    // MARK: - Geometry

    @Test func sampleRectClipping() throws {
        let canvas = PixelSize(width: 10, height: 10)
        #expect(PixelSampler.sampleRect(center: point(0, 0), size: .region3,
                                        canvas: canvas)
                    == PixelRect(x: 0, y: 0, width: 2, height: 2))
        #expect(PixelSampler.sampleRect(center: point(5, 5), size: .region51,
                                        canvas: canvas)
                    == PixelRect(x: 0, y: 0, width: 10, height: 10))
        #expect(PixelSampler.sampleRect(center: point(10, 3), size: .singlePixel,
                                        canvas: canvas) == nil)
        #expect(PixelSampler.sampleRect(center: point(-1, 0), size: .singlePixel,
                                        canvas: canvas) == nil)
        #expect(PixelSampler.sampleRect(center: point(4, 4), size: .singlePixel,
                                        canvas: canvas)
                    == PixelRect(x: 4, y: 4, width: 1, height: 1))
        // Unclipped interior square: h = (n − 1) / 2.
        #expect(PixelSampler.sampleRect(center: point(100, 100), size: .region11,
                                        canvas: PixelSize(width: 200, height: 200))
                    == PixelRect(x: 95, y: 95, width: 11, height: 11))
    }

    @Test func samplingSizeRawValuesAndDisplayNames() {
        #expect(SamplingSize.allCases.map(\.rawValue) == [1, 3, 5, 11, 31, 51])
        #expect(SamplingSize.allCases.map(\.displayName)
                    == ["Single pixel", "3 x 3 region", "5 x 5 region", "11 x 11 region",
                        "31 x 31 region", "51 x 51 region"])
        #expect(SamplingMode.allCases.map(\.rawValue) == ["layer", "image"])
        #expect(SamplingMode.allCases.map(\.displayName) == ["Layer", "Image"])
    }

    // MARK: - Single pixel

    @Test func singlePixelReturnsStoredPixelExactly() throws {
        // A transparent pixel keeps its stored RGB — no averaging, no zeroing.
        let stored = ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 0)
        let image = solid(stored, 8, 8)
        #expect(PixelSampler.sample(image, at: point(4, 4), size: .singlePixel,
                                    mode: .layer, compositor: sampler) == stored)
        let opaque = ColorRGBA8(red: 1, green: 2, blue: 3, alpha: 4)
        let opaqueImage = TestImages.surface(width: 4, height: 4) { _, _ in opaque }
        let opaqueLayered = LayeredImage(surface: opaqueImage)
        #expect(PixelSampler.sample(opaqueLayered, at: point(0, 0), size: .singlePixel,
                                    mode: .layer, compositor: sampler) == opaque)
    }

    // MARK: - Averaging

    @Test func uniformAreaReturnsSameColor() {
        let image = solid(ColorRGBA8(red: 12, green: 34, blue: 56, alpha: 255), 100, 100)
        for size in SamplingSize.allCases {
            #expect(PixelSampler.sample(image, at: point(50, 50), size: size, mode: .layer,
                                        compositor: sampler)
                        == ColorRGBA8(red: 12, green: 34, blue: 56, alpha: 255),
                    "\(size.displayName)")
        }
    }

    /// Hand calc: 3×3 area, 4 opaque red, 5 `(0,0,0,0)`. `S_a = 1020`, `S_R = 255·1020`.
    /// `R = (2·260100 + 1020)/2040 = 255`, `A = (2·1020 + 9)/18 = 113` → `(255,0,0,113)`.
    /// A straight (unweighted) average would give `R = 113` — this test fails for it.
    @Test func alphaWeightedNotStraightAverage() throws {
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        let surface = TestImages.surface(width: 3, height: 3) { x, y in
            x < 2 && y < 2 ? red : .clear   // exactly 4 opaque red pixels
        }
        let image = LayeredImage(surface: surface)
        let sampled = try #require(PixelSampler.sample(image, at: point(1, 1), size: .region3,
                                                       mode: .layer, compositor: sampler))
        #expect(sampled == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 113))
    }

    /// Hand calc (spec 0012): clipped to the 4 pixels of the 2×2 canvas; `S_a = 510`;
    /// `R = 108375/510 = 212.5 → 213`; `G = 43350/510 = 85`; `B = 65025/510 = 127.5 → 128`;
    /// `A = 510/4 = 127.5 → 128` → `(213, 85, 128, 128)`.
    @Test func alphaWeightedWithEdgeClippingAndRounding() throws {
        let surface = TestImages.surface(width: 2, height: 2) { x, y in
            switch (x, y) {
            case (0, 0): ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
            case (1, 0): ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 85)
            case (0, 1): ColorRGBA8(red: 0, green: 255, blue: 0, alpha: 0)
            default: ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 170)
            }
        }
        let image = LayeredImage(surface: surface)
        let sampled = try #require(PixelSampler.sample(image, at: point(0, 0), size: .region3,
                                                       mode: .layer, compositor: sampler))
        #expect(sampled == ColorRGBA8(red: 213, green: 85, blue: 128, alpha: 128))
    }

    @Test func fullyTransparentAreaIsClear() {
        let image = solid(ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 0), 20, 20)
        #expect(PixelSampler.sample(image, at: point(10, 10), size: .region5, mode: .layer,
                                    compositor: sampler) == .clear)
    }

    /// Hand calc: 51×51 at `(0, 0)` on 100×100 clips to 26×26 = 676 pixels, 13 columns of
    /// white → 338 of 676. All opaque: `S_a = 676·255 = 172380`;
    /// `R = (2·255·172380·338/676…` → `255·338/676 = 127.5 → 128`; `A = 255`.
    @Test func largestAreaAtCornerUsesClippedCount() throws {
        let surface = TestImages.surface(width: 100, height: 100) { x, _ in
            x < 13 ? .white : .black
        }
        let image = LayeredImage(surface: surface)
        let sampled = try #require(PixelSampler.sample(image, at: point(0, 0), size: .region51,
                                                       mode: .layer, compositor: sampler))
        #expect(sampled == ColorRGBA8(red: 128, green: 128, blue: 128, alpha: 255))
    }

    /// Hand calc: 3×3 at `(256, 256)` spans four tiles; only tile (1, 1) is allocated
    /// (opaque green), so 4 of the 9 clipped pixels are green, 5 clear. `S_a = 1020`,
    /// `n = 9` → `A = (2·1020 + 9)/18 = 113` → `(0, 255, 0, 113)`.
    @Test func areaAcrossTileBoundary() throws {
        let surface = TestImages.surface(width: 512, height: 512) { x, y in
            x >= 256 && y >= 256 ? ColorRGBA8(red: 0, green: 255, blue: 0, alpha: 255) : .clear
        }
        #expect(surface.allocatedTileCoordinates == [TileCoordinate(column: 1, row: 1)])
        let image = LayeredImage(surface: surface)
        let sampled = try #require(PixelSampler.sample(image, at: point(256, 256), size: .region3,
                                                       mode: .layer, compositor: sampler))
        #expect(sampled == ColorRGBA8(red: 0, green: 255, blue: 0, alpha: 113))
    }

    @Test func oneByOneImage() {
        let image = solid(ColorRGBA8(red: 9, green: 8, blue: 7, alpha: 255), 1, 1)
        #expect(PixelSampler.sample(image, at: point(0, 0), size: .region51, mode: .layer,
                                    compositor: sampler)
                    == ColorRGBA8(red: 9, green: 8, blue: 7, alpha: 255))
        #expect(PixelSampler.sample(image, at: point(0, 0), size: .region51, mode: .image,
                                    compositor: sampler)
                    == ColorRGBA8(red: 9, green: 8, blue: 7, alpha: 255))
    }

    // MARK: - Modes

    private func twoLayerFixture() -> LayeredImage {
        let size = PixelSize(width: 8, height: 8)
        let bottom = Layer(name: "Bottom",
                           surface: TestImages.surface(width: 8, height: 8) { _, _ in
                               ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
                           })
        let top = Layer(name: "Top",
                        surface: TestImages.surface(width: 8, height: 8) { _, _ in
                            ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 128)
                        })
        return LayeredImage(size: size, layers: [bottom, top], activeLayerIndex: 1)
    }

    /// Layer mode returns the active layer's stored pixel `(0,0,255,128)`; Image mode
    /// returns the composite `(127,0,128,255)` (hand calc in `CPUCompositorTests`).
    @Test func layerVsImageMode() {
        let image = twoLayerFixture()
        #expect(PixelSampler.sample(image, at: point(4, 4), size: .singlePixel, mode: .layer,
                                    compositor: sampler)
                    == ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 128))
        #expect(PixelSampler.sample(image, at: point(4, 4), size: .singlePixel, mode: .image,
                                    compositor: sampler)
                    == ColorRGBA8(red: 127, green: 0, blue: 128, alpha: 255))
    }

    @Test func layerModeIgnoresVisibilityAndOpacity() {
        var image = twoLayerFixture()
        image.layers[image.activeLayerIndex].isVisible = false
        #expect(PixelSampler.sample(image, at: point(4, 4), size: .singlePixel, mode: .layer,
                                    compositor: sampler)
                    == ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 128))
        image.layers[image.activeLayerIndex].opacity = 10
        #expect(PixelSampler.sample(image, at: point(4, 4), size: .region3, mode: .layer,
                                    compositor: sampler)
                    == ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 128))
        // …and Image mode excludes the hidden layer: composite of the red bottom only.
        #expect(PixelSampler.sample(image, at: point(4, 4), size: .singlePixel, mode: .image,
                                    compositor: sampler)
                    == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))
    }

    @Test func imageModeWithAllLayersHidden() {
        var image = twoLayerFixture()
        for index in image.layers.indices { image.layers[index].isVisible = false }
        #expect(PixelSampler.sample(image, at: point(4, 4), size: .singlePixel, mode: .image,
                                    compositor: sampler) == .clear)
        // …no white background, and Layer mode still reads the raw active pixel.
        #expect(PixelSampler.sample(image, at: point(4, 4), size: .region3, mode: .image,
                                    compositor: sampler) == .clear)
    }

    @Test func imageModeSinglePixelIsExactComposite() {
        // Single pixel + Image mode composites exactly, no averaging: the same
        // (127, 0, 128, 255) the compositor produces.
        let image = twoLayerFixture()
        #expect(PixelSampler.sample(image, at: point(0, 7), size: .singlePixel, mode: .image,
                                    compositor: sampler)
                    == ColorRGBA8(red: 127, green: 0, blue: 128, alpha: 255))
    }

    // MARK: - Defensive states

    @Test func outsideCanvasReturnsNil() {
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        let image = solid(red, 10, 10)
        let outside: [PixelPoint] = [point(-1, 0), point(0, -1), point(10, 0), point(0, 10),
                                     point(1000, 1000)]
        for mode in [SamplingMode.layer, .image] {
            for size in SamplingSize.allCases {
                for p in outside {
                    #expect(PixelSampler.sample(image, at: p, size: size, mode: mode,
                                                compositor: sampler) == nil,
                            "(\(p), \(size.rawValue), \(mode.rawValue)) must be nil")
                }
            }
        }
    }

    /// The zero-layers / out-of-range-active-index states are only reachable by mutating a
    /// constructed image (`LayeredImage.init` preconditions them); `sample` must still
    /// return nil, never trap.
    @Test func defensiveStates() {
        var noLayers = solid(.white, 4, 4)
        noLayers.layers = []
        #expect(PixelSampler.sample(noLayers, at: point(1, 1), size: .singlePixel,
                                    mode: .layer, compositor: sampler) == nil)
        #expect(PixelSampler.sample(noLayers, at: point(1, 1), size: .region3,
                                    mode: .image, compositor: sampler) == nil)

        var badIndex = solid(.white, 4, 4)
        badIndex.activeLayerIndex = 5
        #expect(PixelSampler.sample(badIndex, at: point(1, 1), size: .singlePixel,
                                    mode: .layer, compositor: sampler) == nil)
        badIndex.activeLayerIndex = -1
        #expect(PixelSampler.sample(badIndex, at: point(1, 1), size: .region3,
                                    mode: .image, compositor: sampler) == nil)
    }

    @Test func averagePublicMathMatchesSpecRule() {
        // `average` directly: two pixels (255,0,0,200) and (0,255,0,50):
        // S_a = 250, S_R = 51000, S_G = 12750.
        // R = (2·51000+250)/500 = 204; G = (2·12750+250)/500 = 51 (51.5 → trunc 51);
        // A = (500+2)/4 = 125.
        let avg = PixelSampler.average([
            ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 200),
            ColorRGBA8(red: 0, green: 255, blue: 0, alpha: 50),
        ])
        #expect(avg == ColorRGBA8(red: 204, green: 51, blue: 0, alpha: 125))
    }
}
