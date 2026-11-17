import Foundation
import Metal
import Testing
@testable import PaintDotMac

/// GPU golden tests (spec 0003): a real Metal device renders offscreen into `.bgra8Unorm`
/// targets and the readback is compared against the independent
/// `CanvasReferenceRenderer` (±1 per channel) or against hand-computed exact values.
/// Background color in these tests is (50, 60, 70) — distinct from the checkerboard.
@MainActor
struct MetalCanvasRendererTests {
    static let background = CanvasReferenceRenderer.testBackground

    // MARK: - Fixtures and helpers

    private func makeRenderer(_ device: MTLDevice, budget: Int = 512 << 20) throws -> MetalCanvasRenderer {
        try MetalCanvasRenderer(device: device, textureBudgetBytes: budget)
    }

    private func transform(image: PixelSize, drawable: (width: Int, height: Int), scale: Double,
                           zoom: Double, center: CGPoint) -> CanvasTransform {
        CanvasTransform(
            imageSize: image,
            viewSize: CGSize(width: Double(drawable.width) / scale, height: Double(drawable.height) / scale),
            backingScale: scale, zoom: zoom, center: center
        )
    }

    /// A transform that shows the whole image: target = ceil(image · zoom), image centered.
    private func wholeImageTransform(_ image: PixelSize, zoom: Double, scale: Double) -> CanvasTransform {
        transform(
            image: image,
            drawable: (width: Int(ceil(Double(image.width) * zoom)), height: Int(ceil(Double(image.height) * zoom))),
            scale: scale, zoom: zoom,
            center: CGPoint(x: Double(image.width) / 2, y: Double(image.height) / 2)
        )
    }

    private func render(image: LayeredImage, canvasTransform: CanvasTransform, renderer: MetalCanvasRenderer,
                        device: MTLDevice, opacityCheck: Bool = true) throws -> [ColorRGBA8] {
        let frame = CanvasFrame(image: image, transform: canvasTransform, backgroundColor: Self.background)
        let drawable = canvasTransform.drawableSize
        return try MetalTestTarget.render(frame, with: renderer, device: device,
                                          width: drawable.width, height: drawable.height)
    }

    private func assertMatchesOracle(_ actual: [ColorRGBA8], image: LayeredImage, canvasTransform: CanvasTransform,
                                     checkerboard: CheckerboardStyle = .standard,
                                     _ comment: Comment? = nil,
                                     sourceLocation: SourceLocation = #_sourceLocation) {
        let expected = CanvasReferenceRenderer.render(image: image, transform: canvasTransform,
                                                      checkerboard: checkerboard,
                                                      backgroundColor: Self.background)
        MetalTestTarget.assertPixelsMatch(actual, match: expected,
                                          width: canvasTransform.drawableSize.width,
                                          height: canvasTransform.drawableSize.height,
                                          tolerance: 1, comment, sourceLocation: sourceLocation)
    }

    private func opaque(_ seed: UInt64, width: Int, height: Int) -> LayeredImage {
        var random = SeededRandom(seed: seed)
        return LayeredImage(surface: TestImages.surface(width: width, height: height) { _, _ in
            ColorRGBA8(red: random.byte(), green: random.byte(), blue: random.byte(), alpha: 255)
        })
    }

    // MARK: - Actual size (CAN-6)

    @Test func actualSizeIsOneToOne1x() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let pixels: [[ColorRGBA8]] = [
            [ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255), ColorRGBA8(red: 0, green: 255, blue: 0, alpha: 255),
             ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255)],
            [ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 128), .clear,
             ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 255)],
        ]
        let image = LayeredImage(surface: TestImages.surface(width: 3, height: 2) { x, y in pixels[y][x] })
        let canvasTransform = transform(image: PixelSize(width: 3, height: 2), drawable: (7, 6), scale: 1,
                                        zoom: 1, center: CGPoint(x: 1.5, y: 1))
        let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        func pixel(_ x: Int, _ y: Int) -> ColorRGBA8 { output[y * 7 + x] }
        func expect(_ x: Int, _ y: Int, _ color: ColorRGBA8, _ comment: Comment? = nil,
                    sourceLocation: SourceLocation = #_sourceLocation) {
            TestImages.expectColor(pixel(x, y), color, sourceLocation: sourceLocation)
        }
        // origin = (3.5 − 1.5, 3 − 1) = (2, 2).
        #expect(canvasTransform.imageOriginInDevice.x == 2)
        #expect(canvasTransform.imageOriginInDevice.y == 2)
        expect(2, 2, ColorRGBA8(red: 255, green: 0, blue: 0), "image pixel (0, 0)")
        expect(3, 2, ColorRGBA8(red: 0, green: 255, blue: 0), "image pixel (1, 0)")
        expect(4, 2, ColorRGBA8(red: 0, green: 0, blue: 255), "image pixel (2, 0)")
        // white·128/255 + (1 − 128/255)·255 = 255 over the light square.
        expect(2, 3, ColorRGBA8(red: 255, green: 255, blue: 255), "half-alpha white over light checker")
        expect(3, 3, ColorRGBA8(red: 255, green: 255, blue: 255), "fully transparent over light checker")
        expect(4, 3, ColorRGBA8(red: 10, green: 20, blue: 30), "image pixel (2, 1)")
        expect(0, 0, Self.background, "background top-left")
        expect(6, 5, Self.background, "background bottom-right")
    }

    @Test func actualSizeIsOneToOne2x() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let pixels: [[ColorRGBA8]] = [
            [ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255), ColorRGBA8(red: 0, green: 255, blue: 0, alpha: 255),
             ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255)],
            [ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 128), .clear,
             ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 255)],
        ]
        let image = LayeredImage(surface: TestImages.surface(width: 3, height: 2) { x, y in pixels[y][x] })
        // 3.5 × 3 points at 2× → the same 7 × 6 device output as the 1× test.
        let canvasTransform = transform(image: PixelSize(width: 3, height: 2), drawable: (7, 6), scale: 2,
                                        zoom: 1, center: CGPoint(x: 1.5, y: 1))
        #expect(canvasTransform.imageOriginInDevice.x == 2)
        #expect(canvasTransform.imageOriginInDevice.y == 2)
        let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        func pixel(_ x: Int, _ y: Int) -> ColorRGBA8 { output[y * 7 + x] }
        TestImages.expectColor(pixel(2, 2), ColorRGBA8(red: 255, green: 0, blue: 0))
        TestImages.expectColor(pixel(3, 2), ColorRGBA8(red: 0, green: 255, blue: 0))
        TestImages.expectColor(pixel(4, 2), ColorRGBA8(red: 0, green: 0, blue: 255))
        TestImages.expectColor(pixel(2, 3), ColorRGBA8(red: 255, green: 255, blue: 255))
        TestImages.expectColor(pixel(4, 3), ColorRGBA8(red: 10, green: 20, blue: 30))
        TestImages.expectColor(pixel(0, 0), Self.background)
        // One image pixel = one device pixel at 100 % on 2× too.
        assertMatchesOracle(output, image: image, canvasTransform: canvasTransform, "Retina actual size")
    }

    @Test func integerZoomGivesExactBlocks() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = opaque(0xB10C, width: 4, height: 4)
        for scale in [1.0, 2.0] {
            for zoom in [2.0, 3.0, 8.0, 32.0] {
                let side = Int(ceil(4 * zoom))
                let canvasTransform = transform(image: PixelSize(width: 4, height: 4), drawable: (side, side),
                                                scale: scale, zoom: zoom, center: CGPoint(x: 2, y: 2))
                let origin = canvasTransform.imageOriginInDevice
                let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
                for deviceY in 0..<side {
                    for deviceX in 0..<side {
                        let source = image.layers[0].surface.pixel(
                            at: PixelPoint(x: Int(floor(Double(deviceX - origin.x) / zoom)),
                                           y: Int(floor(Double(deviceY - origin.y) / zoom)))
                        )
                        // Opaque pixels composite with no blending — exact, and the blocks
                        // start on whole device pixels (origin + k·n).
                        TestImages.expectColor(output[deviceY * side + deviceX], source,
                                               "zoom \(zoom) scale \(scale) at (\(deviceX), \(deviceY))")
                    }
                }
            }
        }
    }

    // MARK: - Nearest neighbor above 100 % (CAN-3)

    @Test func nearestNeighborAbove100() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = LayeredImage(surface: TestImages.surface(width: 2, height: 1) { x, _ in
            x == 0 ? .black : .white
        })
        let canvasTransform = transform(image: PixelSize(width: 2, height: 1), drawable: (16, 8), scale: 1,
                                        zoom: 8, center: CGPoint(x: 1, y: 0.5))
        let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        for x in 0..<8 {
            // Hard edges: no intermediate gray anywhere (proves no linear filtering).
            TestImages.expectColor(output[x], .black, "column \(x)")
            TestImages.expectColor(output[8 + x], .white, "column \(8 + x)")
        }
    }

    @Test func nonIntegerZoomMatchesOracle() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = opaque(0xC0FFEE, width: 7, height: 5)
        for zoom in [4.0 / 3.0, 7.0 / 3.0] {
            for scale in [1.0, 2.0] {
                let canvasTransform = wholeImageTransform(PixelSize(width: 7, height: 5), zoom: zoom, scale: scale)
                let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
                assertMatchesOracle(output, image: image, canvasTransform: canvasTransform, "zoom \(zoom) scale \(scale)")
            }
        }
    }

    // MARK: - Downsampling below 100 % (CAN-3)

    @Test func powerOfTwoZoomOutIsBoxAverage() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let checker = LayeredImage(surface: TestImages.surface(width: 64, height: 64) { x, y in
            (x + y) % 2 == 0 ? .black : .white
        })
        for zoom in [0.5, 0.25, 0.125] {
            let side = Int(64 * zoom)
            let canvasTransform = transform(image: PixelSize(width: 64, height: 64), drawable: (side, side),
                                            scale: 1, zoom: zoom, center: CGPoint(x: 32, y: 32))
            let output = try render(image: checker, canvasTransform: canvasTransform, renderer: renderer, device: device)
            let average = ColorRGBA8(red: 128, green: 128, blue: 128, alpha: 255)
            // Every device pixel is fully covered (image exactly fills the target): the
            // box average of black+white pairs is (128 ± 1) — nearest neighbor would give
            // 0 or 255.
            MetalTestTarget.assertPixelsMatch(output, match: [ColorRGBA8](repeating: average, count: side * side),
                                              width: side, height: side, tolerance: 1, "zoom \(zoom)")
        }
        // A smooth seeded random image against the oracle at the same zooms.
        let smooth = LayeredImage(surface: TestImages.surface(width: 64, height: 64) { x, y in
            ColorRGBA8(red: UInt8((x &* 4 &+ y) % 256), green: UInt8((y &* 3) % 256),
                       blue: UInt8((x &+ y &* 2) % 256), alpha: 255)
        })
        for zoom in [0.5, 0.25, 0.125] {
            let canvasTransform = wholeImageTransform(PixelSize(width: 64, height: 64), zoom: zoom, scale: 1)
            let output = try render(image: smooth, canvasTransform: canvasTransform, renderer: renderer, device: device)
            assertMatchesOracle(output, image: smooth, canvasTransform: canvasTransform, "smooth zoom \(zoom)")
        }
    }

    @Test func arbitraryZoomOutMatchesOracle() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        var random = SeededRandom(seed: 0xA11CE)
        let image = LayeredImage(surface: TestImages.surface(width: 300, height: 200) { _, _ in
            let alphas: [UInt8] = [0, 64, 128, 192, 255]
            return ColorRGBA8(red: random.byte(), green: random.byte(), blue: random.byte(),
                              alpha: alphas[random.int(in: 0...4)])
        })
        for zoom in [0.9, 0.7, 0.33, 0.2, 0.05, 0.01] {
            for scale in [1.0, 2.0] {
                let canvasTransform = wholeImageTransform(PixelSize(width: 300, height: 200), zoom: zoom, scale: scale)
                let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
                assertMatchesOracle(output, image: image, canvasTransform: canvasTransform, "zoom \(zoom) scale \(scale)")
            }
        }
    }

    @Test func noSeamsAcrossTileBoundaries() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        // A horizontal + vertical gradient crossing the tile edges at 256 and 512.
        let image = LayeredImage(surface: TestImages.surface(width: 700, height: 600) { x, y in
            ColorRGBA8(red: UInt8(x % 256), green: UInt8(y % 256), blue: UInt8((x ^ y) % 256), alpha: 255)
        })
        for zoom in [0.75, 0.33, 1.5, 2.0] {
            let canvasTransform = transform(image: PixelSize(width: 700, height: 600), drawable: (600, 400),
                                            scale: 1, zoom: zoom, center: CGPoint(x: 350, y: 300))
            let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
            assertMatchesOracle(output, image: image, canvasTransform: canvasTransform, "zoom \(zoom) full target")
            // Explicit: the device columns/rows adjacent to the tile edges (canvas 256, 512).
            let expected = CanvasReferenceRenderer.render(image: image, transform: canvasTransform,
                                                          backgroundColor: Self.background)
            for canvasEdge in [256.0, 512.0] {
                let edge = canvasToDeviceFor(canvasTransform, x: canvasEdge, y: 300)
                for column in [Int(floor(edge.x)) - 1, Int(floor(edge.x)), Int(floor(edge.x)) + 1] {
                    guard (0..<600).contains(column) else { continue }
                    for row in [0, 200, 399] {
                        let index = row * 600 + column
                        TestImages.expectColor(output[index], expected[index], tolerance: 1,
                                               "across canvas x = \(canvasEdge), column \(column) row \(row)")
                    }
                }
            }
        }
    }

    private func canvasToDeviceFor(_ canvasTransform: CanvasTransform, x: Double, y: Double) -> CGPoint {
        canvasTransform.canvasToDevice(CGPoint(x: x, y: y))
    }

    @Test func transparentColorDoesNotFringe() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        // Left half opaque blue; right half stored red UNDER ALPHA 0 — must never show or
        // bleed into zoomed-out neighbors (premultiply first).
        let image = LayeredImage(surface: TestImages.surface(width: 64, height: 64) { x, _ in
            x < 32 ? ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255)
                   : ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 0)
        })
        for zoom in [0.5, 0.33] {
            let canvasTransform = wholeImageTransform(PixelSize(width: 64, height: 64), zoom: zoom, scale: 1)
            let side = canvasTransform.drawableSize
            let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
            assertMatchesOracle(output, image: image, canvasTransform: canvasTransform, "zoom \(zoom)")
            // Blue over a gray checkerboard has r = g; any leaked red makes r > g.
            for (index, color) in output.enumerated() where abs(Int(color.red) - Int(color.green)) > 1 {
                Issue.record("red fringe at device (\(index % side.width), \(index / side.width)): \(color), zoom \(zoom)")
            }
        }
    }

    // MARK: - Checkerboard and background (CAN-4)

    @Test func checkerboardBehindTransparency1x() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = LayeredImage.blank(size: PixelSize(width: 64, height: 64), fill: .clear)
        let canvasTransform = transform(image: PixelSize(width: 64, height: 64), drawable: (64, 64), scale: 1,
                                        zoom: 1, center: CGPoint(x: 32, y: 32))   // origin (0, 0)
        let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        func pixel(_ x: Int, _ y: Int) -> ColorRGBA8 { output[y * 64 + x] }
        for y in 0..<8 {
            for x in 0..<8 {
                TestImages.expectColor(pixel(x, y), .white, "square (0, 0) at (\(x), \(y))")
            }
        }
        TestImages.expectColor(pixel(8, 0), ColorRGBA8(red: 204, green: 204, blue: 204))
        // At zoom 4 the square side is still 8 device pixels (not scaled by zoom).
        let zoomed = transform(image: PixelSize(width: 64, height: 64), drawable: (64, 64), scale: 1,
                               zoom: 4, center: CGPoint(x: 8, y: 8))
        let zoomedOutput = try render(image: image, canvasTransform: zoomed, renderer: renderer, device: device)
        TestImages.expectColor(zoomedOutput[7], .white, "device 7 still light square at zoom 4")
        TestImages.expectColor(zoomedOutput[8], ColorRGBA8(red: 204, green: 204, blue: 204), "device 8 dark at zoom 4")
    }

    @Test func checkerboardBehindTransparency2x() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = LayeredImage.blank(size: PixelSize(width: 64, height: 64), fill: .clear)
        // 32×32 points at 2× → 64×64 device; origin (0, 0).
        let canvasTransform = transform(image: PixelSize(width: 64, height: 64), drawable: (64, 64), scale: 2,
                                        zoom: 1, center: CGPoint(x: 32, y: 32))
        let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        func pixel(_ x: Int, _ y: Int) -> ColorRGBA8 { output[y * 64 + x] }
        for x in [0, 8, 15] {
            TestImages.expectColor(pixel(x, 0), .white, "device x = \(x) (side is 16 device px)")
        }
        TestImages.expectColor(pixel(16, 0), ColorRGBA8(red: 204, green: 204, blue: 204))
    }

    @Test func checkerboardMovesWithImage() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = LayeredImage.blank(size: PixelSize(width: 64, height: 64), fill: .clear)
        let atZero = transform(image: PixelSize(width: 64, height: 64), drawable: (64, 64), scale: 1,
                               zoom: 1, center: CGPoint(x: 32, y: 32))
        let shifted = transform(image: PixelSize(width: 64, height: 64), drawable: (64, 64), scale: 1,
                                zoom: 1, center: CGPoint(x: 35, y: 32))   // +3 canvas px → origin −3
        let outputA = try render(image: image, canvasTransform: atZero, renderer: renderer, device: device)
        let outputB = try render(image: image, canvasTransform: shifted, renderer: renderer, device: device)
        #expect(shifted.imageOriginInDevice.x == -3)
        // The pattern moves −3 device px: B(x − 3) shows what A shows at x.
        for y in 0..<64 {
            for x in 3..<64 {
                TestImages.expectColor(outputB[y * 64 + (x - 3)], outputA[y * 64 + x], tolerance: 0,
                                       "shifted checkerboard at (\(x), \(y))")
            }
        }
    }

    @Test func backgroundOutsideImage() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = LayeredImage.blank(size: PixelSize(width: 10, height: 10), fill: .black)
        let canvasTransform = transform(image: PixelSize(width: 10, height: 10), drawable: (40, 40), scale: 1,
                                        zoom: 1, center: CGPoint(x: 5, y: 5))   // origin (15, 15)
        let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        let drawn = canvasTransform.drawnImageRectInDevice
        #expect(drawn == PixelRect(x: 15, y: 15, width: 10, height: 10))
        for y in 0..<40 {
            for x in 0..<40 where !drawn.contains(PixelPoint(x: x, y: y)) {
                TestImages.expectColor(output[y * 40 + x], Self.background, "outside image at (\(x), \(y))")
            }
        }
    }

    // MARK: - Alpha and layer properties

    @Test func semiTransparentOverCheckerboard() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = LayeredImage.blank(size: PixelSize(width: 64, height: 64),
                                       fill: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 128))
        let canvasTransform = transform(image: PixelSize(width: 64, height: 64), drawable: (64, 64), scale: 1,
                                        zoom: 1, center: CGPoint(x: 32, y: 32))
        let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        // Over the light square: (1 − 128/255) · 255 = 127; over the dark one: · 204 = 101.6 → 102.
        TestImages.expectColor(output[0], ColorRGBA8(red: 127, green: 127, blue: 127), tolerance: 1, "light square")
        TestImages.expectColor(output[8], ColorRGBA8(red: 102, green: 102, blue: 102), tolerance: 1, "dark square")
        assertMatchesOracle(output, image: image, canvasTransform: canvasTransform, "full target")
    }

    @Test func layerOpacityApplied() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        var image = LayeredImage.blank(size: PixelSize(width: 64, height: 64), fill: .black)
        image.layers[0].opacity = 128
        let canvasTransform = transform(image: PixelSize(width: 64, height: 64), drawable: (64, 64), scale: 1,
                                        zoom: 1, center: CGPoint(x: 32, y: 32))
        let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        // Same values as the semi-transparent test: 127 over light, 102 over dark.
        TestImages.expectColor(output[0], ColorRGBA8(red: 127, green: 127, blue: 127), tolerance: 1)
        TestImages.expectColor(output[8], ColorRGBA8(red: 102, green: 102, blue: 102), tolerance: 1)
        assertMatchesOracle(output, image: image, canvasTransform: canvasTransform, "opacity 128")

        image.layers[0].opacity = 0
        let transparentOutput = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        let expected = CanvasReferenceRenderer.render(image: image, transform: canvasTransform,
                                                      backgroundColor: Self.background)
        MetalTestTarget.assertPixelsMatch(transparentOutput, match: expected, width: 64, height: 64, tolerance: 0,
                                          "opacity 0 → checkerboard only")
    }

    @Test func hiddenLayerShowsCheckerboardOnly() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        var image = LayeredImage.blank(size: PixelSize(width: 64, height: 64),
                                       fill: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        image.layers[0].isVisible = false
        let canvasTransform = transform(image: PixelSize(width: 64, height: 64), drawable: (64, 64), scale: 1,
                                        zoom: 1, center: CGPoint(x: 32, y: 32))
        let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        let expected = CanvasReferenceRenderer.render(image: image, transform: canvasTransform,
                                                      backgroundColor: Self.background)
        MetalTestTarget.assertPixelsMatch(output, match: expected, width: 64, height: 64, tolerance: 0,
                                          "hidden layer → checkerboard everywhere inside the image")
        #expect(renderer.statistics.tilesUploadedLastFrame == 0)
    }

    // MARK: - Tile upload policy (AGENTS rule 3)

    @Test func uploadsOnlyVisibleTiles() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = LayeredImage.blank(size: PixelSize(width: 2048, height: 2048), fill: .black)
        let canvasTransform = transform(image: PixelSize(width: 2048, height: 2048), drawable: (512, 512), scale: 1,
                                        zoom: 1, center: CGPoint(x: 1024, y: 1024))
        _ = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 4)
        #expect(renderer.statistics.residentTileCount == 4)
        _ = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 0)
    }

    @Test func sparseTilesAreNotUploaded() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        var surface = TiledSurface(size: PixelSize(width: 1024, height: 1024))
        surface.setTile(Tile(filledWith: ColorRGBA8(red: 200, green: 10, blue: 10, alpha: 255)),
                        at: TileCoordinate(column: 1, row: 1))
        let image = LayeredImage(surface: surface)
        // Whole 1024² visible → tiles (0,0), (1,0), (0,1), (1,1).
        let canvasTransform = transform(image: PixelSize(width: 1024, height: 1024), drawable: (1024, 1024), scale: 1,
                                        zoom: 1, center: CGPoint(x: 512, y: 512))
        let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 1)
        #expect(renderer.statistics.residentTileCount == 1)
        // The sparse areas show the checkerboard; the allocated tile its color.
        TestImages.expectColor(output[10 * 1024 + 10], .white, "sparse tile → light checker square")
        TestImages.expectColor(output[300 * 1024 + 300], ColorRGBA8(red: 200, green: 10, blue: 10))
        assertMatchesOracle(output, image: image, canvasTransform: canvasTransform, "sparse image")
    }

    @Test func changedTileIsReuploadedAlone() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = LayeredImage.blank(size: PixelSize(width: 1024, height: 1024), fill: .black)
        let canvasTransform = transform(image: PixelSize(width: 1024, height: 1024), drawable: (1024, 1024), scale: 1,
                                        zoom: 1, center: CGPoint(x: 512, y: 512))
        _ = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        var edited = image
        edited.layers[0].surface.setPixel(ColorRGBA8(red: 7, green: 123, blue: 200, alpha: 255),
                                          at: PixelPoint(x: 10, y: 10))
        let output = try render(image: edited, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 1)
        TestImages.expectColor(output[10 * 1024 + 10], ColorRGBA8(red: 7, green: 123, blue: 200))
        assertMatchesOracle(output, image: edited, canvasTransform: canvasTransform, "after edit")
        _ = try render(image: edited, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 0)
    }

    @Test func offscreenChangeUploadsWhenVisible() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = LayeredImage.blank(size: PixelSize(width: 2048, height: 2048), fill: .black)
        // View showing only tile (0, 0).
        let nearOrigin = transform(image: PixelSize(width: 2048, height: 2048), drawable: (256, 256), scale: 1,
                                   zoom: 1, center: CGPoint(x: 128, y: 128))
        _ = try render(image: image, canvasTransform: nearOrigin, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 1)
        var edited = image
        edited.layers[0].surface.setPixel(ColorRGBA8(red: 250, green: 250, blue: 0, alpha: 255),
                                          at: PixelPoint(x: 2000, y: 2000))   // tile (7, 7), not visible
        _ = try render(image: edited, canvasTransform: nearOrigin, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 0)
        // Pan so tile (7, 7) is visible → it uploads with the new pixels.
        let overTile = transform(image: PixelSize(width: 2048, height: 2048), drawable: (256, 256), scale: 1,
                                 zoom: 1, center: CGPoint(x: 1920, y: 1920))
        let output = try render(image: edited, canvasTransform: overTile, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 1)
        assertMatchesOracle(output, image: edited, canvasTransform: overTile, "tile (7, 7) after pan")
    }

    @Test func olderSurfaceForcesFullReupload() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = LayeredImage.blank(size: PixelSize(width: 1024, height: 1024), fill: .black)
        let canvasTransform = transform(image: PixelSize(width: 1024, height: 1024), drawable: (512, 512), scale: 1,
                                        zoom: 1, center: CGPoint(x: 256, y: 256))
        _ = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 4)
        var newer = image
        newer.layers[0].surface.setPixel(.white, at: PixelPoint(x: 5, y: 5))
        newer.layers[0].surface.setPixel(.white, at: PixelPoint(x: 300, y: 5))   // two generations
        _ = try render(image: newer, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 2)
        // The copy taken at the older generation: same layer id, lower generation.
        let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 4)
        assertMatchesOracle(output, image: image, canvasTransform: canvasTransform, "old pixels restored")
    }

    /// A lineage break (here: an older `generation`) marks every resident tile stale and
    /// forgets its base level. Tiles outside the view stay resident-but-stale — their GPU
    /// memory is still allocated, so `residentTextureBytes` and the budget must keep
    /// counting the real texture sizes, not zero.
    @Test func staleResidentsKeepAccountedBytes() throws {
        let device = try MetalTestTarget.makeDevice()
        let fullTileBytes = (256 * 256 + 128 * 128 + 64 * 64 + 32 * 32 + 16 * 16 + 8 * 8 + 4 * 4) * 4
        let renderer = try makeRenderer(device)
        let image = LayeredImage.blank(size: PixelSize(width: 1024, height: 1024), fill: .black)
        // Frame 1: tiles (0,0)…(1,1) resident at base level 0.
        let fourTiles = transform(image: PixelSize(width: 1024, height: 1024), drawable: (512, 512), scale: 1,
                                  zoom: 1, center: CGPoint(x: 256, y: 256))
        _ = try render(image: image, canvasTransform: fourTiles, renderer: renderer, device: device)
        #expect(renderer.statistics.residentTextureBytes == 4 * fullTileBytes)
        // Advance the surface's generation, then pan to a one-tile view.
        var newer = image
        newer.layers[0].surface.setPixel(.white, at: PixelPoint(x: 5, y: 5))
        newer.layers[0].surface.setPixel(.white, at: PixelPoint(x: 300, y: 5))
        let oneTile = transform(image: PixelSize(width: 1024, height: 1024), drawable: (256, 256), scale: 1,
                                zoom: 1, center: CGPoint(x: 128, y: 128))
        _ = try render(image: newer, canvasTransform: oneTile, renderer: renderer, device: device)
        #expect(renderer.statistics.residentTileCount == 4)
        #expect(renderer.statistics.residentTextureBytes == 4 * fullTileBytes)
        // Render the older copy: generation went backwards → all four marked stale and
        // their base levels forgotten; only the visible tile (0,0) re-uploads. The other
        // three keep their allocated (base-level-0 sized) textures resident.
        _ = try render(image: image, canvasTransform: oneTile, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 1)
        #expect(renderer.statistics.residentTileCount == 4)
        #expect(renderer.statistics.residentTextureBytes == 4 * fullTileBytes,
                "stale-but-resident textures must stay counted at their allocated size")
    }

    @Test func invalidateAllReuploadsVisibleTiles() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = LayeredImage.blank(size: PixelSize(width: 1024, height: 1024), fill: .black)
        let canvasTransform = transform(image: PixelSize(width: 1024, height: 1024), drawable: (512, 512), scale: 1,
                                        zoom: 1, center: CGPoint(x: 256, y: 256))
        _ = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 4)
        renderer.invalidateAll()
        _ = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 4)
        // A new image with a different layer id but the same size re-uploads.
        var replaced = image
        replaced.layers[0] = Layer(name: replaced.layers[0].name, surface: replaced.layers[0].surface)
        _ = try render(image: replaced, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 4)
    }

    @Test func zoomedOutUploadsCoarseBaseLevel() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = LayeredImage.blank(size: PixelSize(width: 4096, height: 4096), fill: .black)
        let canvasTransform = transform(image: PixelSize(width: 4096, height: 4096), drawable: (256, 256), scale: 1,
                                        zoom: 1.0 / 16.0, center: CGPoint(x: 2048, y: 2048))
        _ = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.lastFrameLevel == 4)
        let range = try #require(canvasTransform.visibleTileRange)
        #expect(range.count == renderer.statistics.residentTileCount)
        for coordinate in range.coordinates {
            #expect(renderer.statistics.baseLevel(of: coordinate) == 4, "tile \(coordinate)")
        }
        let bytesPerTile = (16 * 16 + 8 * 8 + 4 * 4) * 4
        #expect(renderer.statistics.residentTextureBytes == renderer.statistics.residentTileCount * bytesPerTile)
    }

    @Test func zoomingInUpgradesBaseLevel() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = LayeredImage.blank(size: PixelSize(width: 4096, height: 4096), fill: .black)
        let zoomedOut = transform(image: PixelSize(width: 4096, height: 4096), drawable: (256, 256), scale: 1,
                                  zoom: 1.0 / 16.0, center: CGPoint(x: 2048, y: 2048))
        _ = try render(image: image, canvasTransform: zoomedOut, renderer: renderer, device: device)
        let zoomedIn = transform(image: PixelSize(width: 4096, height: 4096), drawable: (256, 256), scale: 1,
                                 zoom: 1, center: CGPoint(x: 130, y: 130))   // tiles (0…1)²
        _ = try render(image: image, canvasTransform: zoomedIn, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 4)
        for row in 0...1 {
            for column in 0...1 {
                #expect(renderer.statistics.baseLevel(of: TileCoordinate(column: column, row: row)) == 0)
            }
        }
        // Zooming back out: nothing at all uploads — the four upgraded tiles keep their
        // level-4 content inside their chain, and the other 252 stayed resident at base 4.
        _ = try render(image: image, canvasTransform: zoomedOut, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 0)
        for row in 0...1 {
            for column in 0...1 {
                #expect(renderer.statistics.baseLevel(of: TileCoordinate(column: column, row: row)) == 0)
            }
        }
    }

    /// Moving the window between a 1× and a 2× display keeps the zoom and the tiles: the
    /// same drawable size at the same zoom shows the same tiles, so the scale change itself
    /// must not upload (or invalidate) anything — only `viewSize` changes.
    @Test func backingScaleChangeKeepsTextures() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = opaque(0x5CA1, width: 1024, height: 1024)
        // 512 device pixels: 512 pt at 1×, 256 pt at 2× — same zoom, center and drawable.
        let at1x = transform(image: PixelSize(width: 1024, height: 1024), drawable: (512, 512), scale: 1,
                             zoom: 0.5, center: CGPoint(x: 512, y: 512))
        let at2x = transform(image: PixelSize(width: 1024, height: 1024), drawable: (512, 512), scale: 2,
                             zoom: 0.5, center: CGPoint(x: 512, y: 512))
        #expect(at1x.drawableSize == at2x.drawableSize)
        _ = try render(image: image, canvasTransform: at1x, renderer: renderer, device: device)
        let uploadsAfter1x = renderer.statistics.tilesUploadedLastFrame
        #expect(uploadsAfter1x > 0)
        let output = try render(image: image, canvasTransform: at2x, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 0, "backing-scale change re-uploads nothing")
        assertMatchesOracle(output, image: image, canvasTransform: at2x, "2× frame after 1×")
    }

    @Test func evictsNonVisibleTilesOverBudget() throws {
        let device = try MetalTestTarget.makeDevice()
        let fullTileBytes = (256 * 256 + 128 * 128 + 64 * 64 + 32 * 32 + 16 * 16 + 8 * 8 + 4 * 4) * 4
        #expect(fullTileBytes == 349_504)
        let renderer = try makeRenderer(device, budget: 3 * fullTileBytes)
        let image = LayeredImage.blank(size: PixelSize(width: 1024, height: 1024), fill: .black)
        for row in 0..<4 {
            let canvasTransform = transform(image: PixelSize(width: 1024, height: 1024), drawable: (256, 256), scale: 1,
                                            zoom: 1, center: CGPoint(x: 128, y: Double(row * 256 + 128)))
            _ = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
            let visible = TileCoordinate(column: 0, row: row)
            #expect(renderer.statistics.baseLevel(of: visible) != nil, "visible tile resident (row \(row))")
            #expect(renderer.statistics.residentTextureBytes <= 3 * fullTileBytes, "row \(row)")
            // Budget ≥ one tile, so the visible set alone never exceeds it.
        }
        // Eviction is least-recently-**drawn**: after rows 0…3, the four different tiles
        // need four budgets of one — row 0 (drawn first, never again) is the one evicted,
        // and rows 1 and 2 stay resident.
        #expect(renderer.statistics.baseLevel(of: TileCoordinate(column: 0, row: 0)) == nil,
                "the least recently drawn tile is evicted first")
        #expect(renderer.statistics.baseLevel(of: TileCoordinate(column: 0, row: 1)) != nil)
        #expect(renderer.statistics.baseLevel(of: TileCoordinate(column: 0, row: 2)) != nil)
        #expect(renderer.statistics.baseLevel(of: TileCoordinate(column: 0, row: 3)) != nil)
        #expect(renderer.statistics.residentTileCount == 3)
    }

    // MARK: - Extremes

    @Test func extremesTinyImage() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = LayeredImage.blank(size: PixelSize(width: 1, height: 1),
                                       fill: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        // 3200 % → a 32×32 red block, exact.
        let maxZoom = transform(image: PixelSize(width: 1, height: 1), drawable: (32, 32), scale: 1,
                                zoom: 32, center: CGPoint(x: 0.5, y: 0.5))
        #expect(maxZoom.imageOriginInDevice == (x: 0, y: 0))
        let zoomedIn = try render(image: image, canvasTransform: maxZoom, renderer: renderer, device: device)
        MetalTestTarget.assertPixelsMatch(zoomedIn, match: [ColorRGBA8](
            repeating: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255), count: 32 * 32
        ), width: 32, height: 32, tolerance: 0, "1×1 at 3200 %")
        // 1 % → one device pixel of partial coverage.
        let minZoom = transform(image: PixelSize(width: 1, height: 1), drawable: (4, 4), scale: 1,
                                zoom: 0.01, center: CGPoint(x: 0.5, y: 0.5))
        #expect(minZoom.drawnImageRectInDevice == PixelRect(x: 2, y: 2, width: 1, height: 1))
        let zoomedOut = try render(image: image, canvasTransform: minZoom, renderer: renderer, device: device)
        assertMatchesOracle(zoomedOut, image: image, canvasTransform: minZoom, "1×1 at 1 %")
    }

    @Test func extremesHugeSparseImageAtMaxZoom() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        var surface = TiledSurface(size: PixelSize(width: 65_535, height: 1))
        var lastTile = Tile()
        lastTile.setPixel(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255), x: 253, y: 0)   // global 65 533
        lastTile.setPixel(ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255), x: 254, y: 0)   // global 65 534
        surface.setTile(lastTile, at: TileCoordinate(column: 255, row: 0))
        let image = LayeredImage(surface: surface)
        let canvasTransform = transform(image: PixelSize(width: 65_535, height: 1), drawable: (128, 64), scale: 1,
                                        zoom: 32, center: CGPoint(x: 65_534, y: 0.5))
        let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        // Float-precision guard: exact 32-px blocks at the oracle positions, far from 0.
        assertMatchesOracle(output, image: image, canvasTransform: canvasTransform, "65 535 px wide at 3200 %")
        TestImages.expectColor(output[32 * 64 + 40], ColorRGBA8(red: 255, green: 0, blue: 0), "red block")
        TestImages.expectColor(output[32 * 64 + 80], ColorRGBA8(red: 0, green: 0, blue: 255), "blue block")
        TestImages.expectColor(output[32 * 64 + 120], Self.background, "past the image end")
    }

    @Test func extremesZeroSizeTargetAndScrolledOut() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let image = LayeredImage.blank(size: PixelSize(width: 100, height: 100), fill: .white)
        // A transform whose viewSize is 0×0 encodes nothing; statistics stay unchanged.
        let degenerate = CanvasTransform(imageSize: PixelSize(width: 100, height: 100), viewSize: .zero,
                                         backingScale: 1, zoom: 1, center: CGPoint(x: 50, y: 50))
        let statsBefore = renderer.statistics
        let target = try MetalTestTarget.makeTarget(device, width: 8, height: 8)
        let queue = try MetalTestTarget.makeCommandQueue(device)
        let commandBuffer = try #require(queue.makeCommandBuffer())
        renderer.encode(CanvasFrame(image: image, transform: degenerate, backgroundColor: Self.background),
                        to: target, in: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(renderer.statistics == statsBefore)
        // Scrolled far out: pure background, zero uploads.
        let scrolledOut = transform(image: PixelSize(width: 100, height: 100), drawable: (100, 100), scale: 1,
                                    zoom: 1, center: CGPoint(x: -10_000, y: -10_000))
        let output = try render(image: image, canvasTransform: scrolledOut, renderer: renderer, device: device)
        MetalTestTarget.assertPixelsMatch(output, match: [ColorRGBA8](repeating: Self.background, count: 10_000),
                                          width: 100, height: 100, tolerance: 0, "scrolled out")
        #expect(renderer.statistics.tilesUploadedLastFrame == 0)
    }

    // MARK: - Library failure

    /// A bundle without a metallib must fail with a thrown error, never a crash.
    final class BundleWithoutMetalLibrary {}

    @Test func initThrowsWithoutLibrary() throws {
        let device = try MetalTestTarget.makeDevice()
        #expect(throws: CanvasRendererError.libraryUnavailable) {
            try MetalCanvasRenderer(
                device: device, bundle: Bundle(for: BundleWithoutMetalLibrary.self),
                targetPixelFormat: .bgra8Unorm, textureBudgetBytes: 512 << 20
            )
        }
    }

    /// The uniforms struct must have `size == stride`: `setVertexBytes` copies `stride`
    /// bytes from a stack temporary that is only `size` bytes, and before the explicit
    /// trailing padding every frame read 8 bytes past its own stack slot (AddressSanitizer
    /// caught the out-of-bounds read inside the AGX driver). Removing `_padding` from
    /// `CanvasUniforms` fails this test.
    @Test func uniformStructHasNoTrailingStridePadding() {
        #expect(MetalCanvasRenderer.uniformLayoutIsSound,
                "CanvasUniforms size/stride mismatch makes setVertexBytes read past the stack slot")
    }

    // MARK: - Multi-layer compositing (spec 0024)

    /// The 0024 oracle: the straight multi-layer composite through the pixel entry.
    private func compositedOracle(_ image: LayeredImage, canvasTransform: CanvasTransform,
                                  checkerboard: CheckerboardStyle = .standard) -> [ColorRGBA8] {
        let composite = CPUCompositor().composite(image, in: image.size.bounds)
        return CanvasReferenceRenderer.render(pixels: composite.pixels, size: image.size,
                                              opacity: 1, isVisible: true,
                                              transform: canvasTransform, checkerboard: checkerboard,
                                              backgroundColor: Self.background)
    }

    private func expectComposited(_ actual: [ColorRGBA8], image: LayeredImage,
                                  canvasTransform: CanvasTransform, _ comment: Comment? = nil,
                                  sourceLocation: SourceLocation = #_sourceLocation) {
        MetalTestTarget.assertPixelsMatch(actual, match: compositedOracle(image, canvasTransform: canvasTransform),
                                          width: canvasTransform.drawableSize.width,
                                          height: canvasTransform.drawableSize.height,
                                          tolerance: 1, comment, sourceLocation: sourceLocation)
    }

    private func seededLayer(_ name: String, seed: UInt64, width: Int, height: Int,
                             isVisible: Bool = true, opacity: UInt8 = 255) -> Layer {
        var random = SeededRandom(seed: seed)
        let surface = TestImages.surface(width: width, height: height) { _, _ in
            let color = random.color()
            return ColorRGBA8(red: color.red, green: color.green, blue: color.blue,
                              alpha: random.byte())
        }
        return Layer(name: name, surface: surface, isVisible: isVisible, opacity: opacity)
    }

    @Test func multiLayerOracleAcceptsZooms() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let size = PixelSize(width: 700, height: 500)
        let image = LayeredImage(size: size,
                                 layers: [seededLayer("A", seed: 0xA1, width: 700, height: 500),
                                          seededLayer("B", seed: 0xB2, width: 700, height: 500, opacity: 128),
                                          seededLayer("C", seed: 0xC3, width: 700, height: 500, isVisible: false)],
                                 activeLayerIndex: 1)
        for (zoom, scale) in [(1.0, 1.0), (0.5, 1.0), (1.0 / 3.0, 1.0), (2.0, 2.0)] {
            let canvasTransform = wholeImageTransform(size, zoom: zoom, scale: scale)
            let output = try render(image: image, canvasTransform: canvasTransform,
                                    renderer: renderer, device: device)
            expectComposited(output, image: image, canvasTransform: canvasTransform,
                             "zoom \(zoom) scale \(scale)")
        }
    }

    @Test func multiLayerOpacityAndVisibilityMix() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let size = PixelSize(width: 300, height: 300)
        var image = LayeredImage(size: size,
                                 layers: [seededLayer("A", seed: 0xD1, width: 300, height: 300),
                                          seededLayer("B", seed: 0xD2, width: 300, height: 300, opacity: 200),
                                          seededLayer("C", seed: 0xD3, width: 300, height: 300, isVisible: false)],
                                 activeLayerIndex: 0)
        let canvasTransform = wholeImageTransform(size, zoom: 1, scale: 1)
        var output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        expectComposited(output, image: image, canvasTransform: canvasTransform, "initial mix")
        // Hide the bottom, show the top → a new oracle for the new frame.
        image.layers[0].isVisible = false
        image.layers[2].isVisible = true
        output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        expectComposited(output, image: image, canvasTransform: canvasTransform, "visibility toggled")
        image.layers[1].opacity = 40
        output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        expectComposited(output, image: image, canvasTransform: canvasTransform, "opacity changed")
    }

    @Test func multiLayerEditRebuildsOnlyChangedTile() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        func flat(_ color: ColorRGBA8) -> Layer {
            var surface = TiledSurface(size: PixelSize(width: 1024, height: 1024))
            surface.fill(color)
            return Layer(name: "L", surface: surface)
        }
        let image = LayeredImage(size: PixelSize(width: 1024, height: 1024),
                                 layers: [flat(.white), flat(.black), flat(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))], activeLayerIndex: 2)
        // 512 device px at zoom 0.5 → the whole 4×4 tile grid.
        let canvasTransform = transform(image: PixelSize(width: 1024, height: 1024),
                                        drawable: (512, 512), scale: 1, zoom: 0.5,
                                        center: CGPoint(x: 512, y: 512))
        _ = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 16)
        #expect(renderer.statistics.layerTilesCopiedLastFrame == 16 * 3,
                "16 composite tiles × 3 contributing layers")
        var edited = image
        edited.layers[1].surface.setPixel(ColorRGBA8(red: 0, green: 200, blue: 0, alpha: 255), at: PixelPoint(x: 2 * 256 + 5, y: 1 * 256 + 5))
        let output = try render(image: edited, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 1)
        #expect(renderer.statistics.layerTilesCopiedLastFrame == 3)
        expectComposited(output, image: edited, canvasTransform: canvasTransform, "after one-tile edit")
        _ = try render(image: edited, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 0)
        #expect(renderer.statistics.layerTilesCopiedLastFrame == 0)
    }

    @Test func activeLayerSwitchRebuildsNothing() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let size = PixelSize(width: 600, height: 600)
        let image = LayeredImage(size: size,
                                 layers: [seededLayer("A", seed: 0xE1, width: 600, height: 600),
                                          seededLayer("B", seed: 0xE2, width: 600, height: 600)],
                                 activeLayerIndex: 0)
        let canvasTransform = wholeImageTransform(size, zoom: 1, scale: 1)
        let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        var switched = image
        switched.activeLayerIndex = 1
        let output2 = try render(image: switched, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 0, "active layer is not composited")
        #expect(output == output2)
    }

    @Test func structureChangeRebuildsVisible() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let size = PixelSize(width: 600, height: 600)   // 3×3 tiles
        let image = LayeredImage(size: size,
                                 layers: [seededLayer("A", seed: 0xF1, width: 600, height: 600)],
                                 activeLayerIndex: 0)
        let canvasTransform = wholeImageTransform(size, zoom: 1, scale: 1)
        _ = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 9)
        // A structure change (new layer above) rebuilds every visible tile.
        var stacked = image
        stacked.layers.append(seededLayer("B", seed: 0xF2, width: 600, height: 600, opacity: 100))
        stacked.activeLayerIndex = 1
        let output = try render(image: stacked, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 9)
        expectComposited(output, image: stacked, canvasTransform: canvasTransform, "after add")
        // `invalidateAll` (undo-style whole-image replacement) re-uploads too.
        renderer.invalidateAll()
        _ = try render(image: stacked, canvasTransform: canvasTransform, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 9)
    }

    @Test func zoomWithinFullChainRebuildsNothing() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let size = PixelSize(width: 1024, height: 1024)
        let image = LayeredImage.blank(size: size, fill: .black)
        let full = transform(image: size, drawable: (1024, 1024), scale: 1, zoom: 1,
                             center: CGPoint(x: 512, y: 512))
        _ = try render(image: image, canvasTransform: full, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 16)
        var edited = image
        edited.layers[0].surface.setPixel(.white, at: PixelPoint(x: 300, y: 300))
        _ = try render(image: edited, canvasTransform: full, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 1)
        // Zoom to 50 %: the full 0…6 chains survive → nothing rebuilds.
        let half = transform(image: size, drawable: (512, 512), scale: 1, zoom: 0.5,
                             center: CGPoint(x: 512, y: 512))
        let output = try render(image: edited, canvasTransform: half, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 0, "full chains survive the zoom")
        for coordinate in try #require(half.visibleTileRange).coordinates {
            #expect(renderer.statistics.baseLevel(of: coordinate) == 0)
        }
        expectComposited(output, image: edited, canvasTransform: half, "50 % after zoom")
    }

    @Test func emptyStackShowsCheckerboard() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let size = PixelSize(width: 300, height: 300)
        let image = LayeredImage(size: size,
                                 layers: [seededLayer("A", seed: 0x1A, width: 300, height: 300, isVisible: false),
                                          seededLayer("B", seed: 0x1B, width: 300, height: 300, opacity: 0)],
                                 activeLayerIndex: 0)
        let canvasTransform = wholeImageTransform(size, zoom: 1, scale: 1)
        let output = try render(image: image, canvasTransform: canvasTransform, renderer: renderer, device: device)
        // Checkerboard inside the image rect, background outside — the invisible-layer oracle.
        assertMatchesOracle(output, image: image, canvasTransform: canvasTransform, "no visible layer")
        #expect(renderer.statistics.residentTileCount == 0, "no composite textures for an empty stack")
    }

    @Test func rendersNothingForZeroSizeCanvas() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let size = PixelSize(width: 64, height: 64)
        let image = LayeredImage.blank(size: size, fill: .black)
        let good = transform(image: size, drawable: (64, 64), scale: 1, zoom: 1,
                             center: CGPoint(x: 32, y: 32))
        _ = try render(image: image, canvasTransform: good, renderer: renderer, device: device)
        #expect(renderer.statistics.tilesUploadedLastFrame == 1)
        #expect(renderer.lastFrameSize == CGSize(width: 64, height: 64))
        let before = renderer.statistics
        // A zero-size canvas (view being created/collapsed) encodes nothing.
        let zero = transform(image: size, drawable: (0, 0), scale: 1, zoom: 1,
                             center: CGPoint(x: 32, y: 32))
        let frame = CanvasFrame(image: image, transform: zero, backgroundColor: Self.background)
        let queue = try MetalTestTarget.makeCommandQueue(device)
        let target = try MetalTestTarget.makeTarget(device, width: 4, height: 4)
        let commandBuffer = try #require(queue.makeCommandBuffer())
        renderer.encode(frame, to: target, in: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(renderer.statistics == before, "a zero-size frame changes nothing")
        #expect(renderer.lastFrameSize == CGSize(width: 64, height: 64),
                "the zero-size frame must not touch lastFrameSize")
    }

    @Test func fiftyPercentBuildsFullChains() throws {
        let device = try MetalTestTarget.makeDevice()
        let renderer = try makeRenderer(device)
        let size = PixelSize(width: 4096, height: 4096)
        let image = LayeredImage.blank(size: size, fill: .black)
        // 50 % (level 1 ≤ 2): base level 0 — the whole 0…6 chain per tile.
        let half = transform(image: size, drawable: (256, 256), scale: 1, zoom: 0.5,
                             center: CGPoint(x: 128, y: 128))
        _ = try render(image: image, canvasTransform: half, renderer: renderer, device: device)
        let range = try #require(half.visibleTileRange)
        let fullTileBytes = (256 * 256 + 128 * 128 + 64 * 64 + 32 * 32 + 16 * 16 + 8 * 8 + 4 * 4) * 4
        #expect(range.count == 4)
        #expect(renderer.statistics.residentTextureBytes == range.count * fullTileBytes)
        // 10 % (level 3): fresh tiles are built at base level 3 (4 levels, not 7);
        // tiles already resident with a full chain keep it.
        let coarse = transform(image: size, drawable: (256, 256), scale: 1, zoom: 0.1,
                               center: CGPoint(x: 128, y: 128))
        _ = try render(image: image, canvasTransform: coarse, renderer: renderer, device: device)
        let coarseRange = try #require(coarse.visibleTileRange)
        var sawCoarseChain = false
        for coordinate in coarseRange.coordinates {
            guard let base = renderer.statistics.baseLevel(of: coordinate) else { continue }
            #expect(base == 3 || base == 0, "tile \(coordinate) base \(base)")
            sawCoarseChain = sawCoarseChain || base == 3
        }
        #expect(sawCoarseChain, "tiles outside the first view must be built at base 3")
        // The byte accounting follows the base levels exactly.
        let expectedBytes = renderer.statistics.baseLevels.values.reduce(0) { total, base in
            total + (base...6).reduce(0) { sum, level in
                let side = 256 >> level
                return sum + side * side * 4
            }
        }
        #expect(renderer.statistics.residentTextureBytes == expectedBytes)
    }
}
