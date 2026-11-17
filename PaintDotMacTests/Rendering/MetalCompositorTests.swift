import Foundation
import Metal
import Testing
@testable import PaintDotMac

/// The multi-layer Metal display compositor (spec 0024 item 4; PRD D-16, NF-6): parity
/// with `CPUCompositor.compositeTile` within ±1 per channel, per-layer opacity/blend
/// kernels, and the premultiplied mip levels against `TileMipmapper`'s CPU chain.
/// GPU tests **fail** — never skip — when Metal is missing (AGENTS.md *Headless testing*).
@MainActor
struct MetalCompositorTests {
    // MARK: - Fixtures

    private func makeCompositor(_ device: MTLDevice) throws -> MetalCompositor {
        let library = try #require(try? device.makeDefaultLibrary(bundle: Bundle(for: MetalCompositor.self)),
                                   "could not load the app Metal library")
        return try MetalCompositor(device: device, library: library)
    }

    private func layer(name: String, surface: TiledSurface, isVisible: Bool = true,
                       opacity: UInt8 = 255) -> Layer {
        Layer(name: name, surface: surface, isVisible: isVisible, opacity: opacity)
    }

    private func image(_ layers: [Layer], active: Int = 0) -> LayeredImage {
        LayeredImage(size: layers[0].size, layers: layers, activeLayerIndex: active)
    }

    /// The tile's in-canvas size (edge tiles clipped, as `TiledSurface` stores them).
    private func validSize(of tile: TileCoordinate, image: LayeredImage) -> (w: Int, h: Int) {
        let side = TiledSurface.tileSize
        let rect = PixelRect(x: tile.column * side, y: tile.row * side, width: side, height: side)
            .intersection(image.size.bounds)
        return (rect.width, rect.height)
    }

    /// Extracts the tile's in-canvas `w × h` region from a 256×256 GPU readback.
    private func validRegion(_ gpu: [ColorRGBA8], width w: Int, height h: Int) -> [ColorRGBA8] {
        var out = [ColorRGBA8]()
        out.reserveCapacity(w * h)
        for y in 0..<h { out.append(contentsOf: gpu[(y * 256)..<(y * 256 + w)]) }
        return out
    }

    private func bytesToColors(_ bytes: [UInt8]) -> [ColorRGBA8] {
        stride(from: 0, to: bytes.count, by: 4).map { offset in
            ColorRGBA8(red: bytes[offset], green: bytes[offset + 1],
                       blue: bytes[offset + 2], alpha: bytes[offset + 3])
        }
    }

    /// A readable tile-chain texture: same shape and usage as
    /// `MetalCompositor.makeTileTexture` but `.shared` storage, so `getBytes` is legal
    /// in tests (production tiles are `.private` and never read back).
    private func readableTileTexture(_ device: MTLDevice, baseLevel: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: TiledSurface.tileSize >> baseLevel,
            height: TiledSurface.tileSize >> baseLevel, mipmapped: true)
        descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        descriptor.storageMode = .shared
        descriptor.mipmapLevelCount = TileMipmapper.levelCount - baseLevel
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    /// CPU chain input for one tile: `paddedPremultipliedTile` consumes 256-stride
    /// straight tile bytes (the `TiledSurface` storage layout, like production's
    /// uploads), while `compositeTile` returns tight clipped pixels — re-stride edge
    /// tiles before premultiplying.
    private func cpuPadded(_ tight: [ColorRGBA8], validWidth: Int,
                           validHeight: Int) -> [ColorRGBA8] {
        var stride = tight
        if validWidth < TiledSurface.tileSize || validHeight < TiledSurface.tileSize {
            stride = [ColorRGBA8](repeating: .clear, count: 256 * 256)
            for y in 0..<validHeight {
                for x in 0..<validWidth { stride[y * 256 + x] = tight[y * validWidth + x] }
            }
        }
        return TileMipmapper.paddedPremultipliedTile(from: stride, validWidth: validWidth,
                                                     validHeight: validHeight)
    }

    private func readLevel(_ texture: MTLTexture, level: Int, side: Int) -> [ColorRGBA8] {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        texture.getBytes(&bytes, bytesPerRow: side * 4,
                         from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: level)
        return bytesToColors(bytes)
    }

    private func expectNoMismatches(_ comparison: GoldenComparison, _ context: String,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(comparison.mismatchCount == 0,
                """
                maxΔ \(comparison.maxChannelDelta), \(comparison.mismatchCount) mismatches, \
                first: \(comparison.firstMismatches) [\(context)]
                """,
                sourceLocation: sourceLocation)
    }

    /// The composite of one tile both ways; fails when only one of them has a tile.
    private func compareTile(_ compositor: MetalCompositor, _ cpu: CPUCompositor,
                             _ tile: TileCoordinate, _ stack: LayeredImage,
                             sourceLocation: SourceLocation = #_sourceLocation) throws {
        let gpu = compositor.compositeTilePixels(tile, of: stack)
        let reference = cpu.compositeTile(tile, of: stack)
        switch (gpu, reference) {
        case (nil, nil): return
        case (nil, .some):
            Issue.record("GPU produced nothing where CPU composited a tile [\(tile)]",
                         sourceLocation: sourceLocation)
        case (.some, nil):
            Issue.record("GPU composited a tile where CPU has none [\(tile)]",
                         sourceLocation: sourceLocation)
        case let (.some(gpuPixels), .some(cpuPixels)):
            let size = validSize(of: tile, image: stack)
            let comparison = GoldenImage.compare(
                validRegion(gpuPixels, width: size.w, height: size.h),
                to: cpuPixels, width: size.w, height: size.h, tolerance: 1)
            #expect(comparison.mismatchCount == 0,
                    """
                    tile \(tile): maxΔ \(comparison.maxChannelDelta), \
                    \(comparison.mismatchCount) mismatches, first: \(comparison.firstMismatches)
                    """,
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: - Random parity

    @Test func randomStacksMatchCPU() throws {
        let device = try MetalTestTarget.makeDevice()
        let compositor = try makeCompositor(device)
        let cpu = CPUCompositor()
        let queue = try MetalTestTarget.makeCommandQueue(device)
        let target = try readableTileTexture(device, baseLevel: 0)
        let size = PixelSize(width: 600, height: 600)   // 3×3 tiles, (2,2) is an edge tile
        let alphas: [UInt8] = [0, 1, 64, 128, 200, 255]
        let seed = SeededRandom.resolvedSeed(default: 0xC0FFEE24)
        for stackIndex in 0..<30 {
            var random = SeededRandom(seed: seed &+ UInt64(stackIndex))
            var layers: [Layer] = []
            for index in 0..<random.int(in: 1...10) {
                // Sparse: ~1 tile in 4 unallocated; pixels fully transparent, opaque, random.
                var surface = TiledSurface(size: size)
                for row in 0..<surface.tileRows {
                    for column in 0..<surface.tileColumns where random.int(in: 0...3) > 0 {
                        var tile = Tile()
                        let originX = column * 256
                        let originY = row * 256
                        for y in stride(from: 0, to: 256, by: 13) {
                            for x in stride(from: 0, to: 256, by: 17)
                            where originX + x < size.width && originY + y < size.height {
                                let alpha = random.int(in: 0...2) == 0 ? alphas[random.int(in: 0...5)]
                                    : (random.int(in: 0...1) == 0 ? UInt8(255) : random.byte())
                                tile.setPixel(ColorRGBA8(red: random.byte(), green: random.byte(),
                                                         blue: random.byte(), alpha: alpha),
                                              x: x, y: y)
                            }
                        }
                        surface.setTile(tile, at: TileCoordinate(column: column, row: row))
                    }
                }
                layers.append(layer(name: "L\(index)", surface: surface,
                                    isVisible: random.int(in: 0...3) > 0,
                                    opacity: alphas[random.int(in: 0...5)]))
            }
            let stack = image(layers, active: layers.count - 1)
            for row in 0..<3 {
                for column in 0..<3 {
                    let tile = TileCoordinate(column: column, row: row)
                    try compareTile(compositor, cpu, tile, stack)
                    // Mip parity for the same tile: level 0 and every downsampled level
                    // equal `TileMipmapper`'s CPU chain.
                    let buffer = try #require(queue.makeCommandBuffer())
                    let built = compositor.encodeTile(tile, of: stack, baseLevel: 0,
                                                      into: target, commandBuffer: buffer)
                    buffer.commit()
                    buffer.waitUntilCompleted()
                    guard let cpuPixels = cpu.compositeTile(tile, of: stack) else {
                        #expect(!built, "tile \(tile): encoded with no CPU composite")
                        continue
                    }
                    let valid = validSize(of: tile, image: stack)
                    let padded = cpuPadded(cpuPixels, validWidth: valid.w, validHeight: valid.h)
                    let chain = TileMipmapper.mipChain(level0: padded, baseLevel: 0)
                    for level in 0..<7 {
                        let side = 256 >> level
                        let comparison = GoldenImage.compare(
                            readLevel(target, level: level, side: side),
                            to: chain[level], width: side, height: side, tolerance: 1)
                        #expect(comparison.mismatchCount == 0,
                                """
                                stack \(stackIndex) tile \(tile) level \(level): maxΔ \(comparison.maxChannelDelta), \
                                \(comparison.mismatchCount) mismatches, first: \(comparison.firstMismatches) (seed \(seed))
                                """)
                    }
                }
            }
        }
    }

    @Test func mipLevelsForRandomTile() throws {
        let device = try MetalTestTarget.makeDevice()
        let compositor = try makeCompositor(device)
        let size = PixelSize(width: 600, height: 600)
        var random = SeededRandom(seed: 0xD1FF)
        let bottom = layer(name: "B", surface: TestImages.surface(width: size.width, height: size.height) { _, _ in
            random.color()
        })
        let middle = layer(name: "M",
                           surface: TestImages.surface(width: size.width, height: size.height) { _, _ in
            random.color().with(alpha: random.int(in: 0...1) == 0 ? 96 : 224)
        }, opacity: 128)
        let top = layer(name: "T",
                        surface: TestImages.surface(width: size.width, height: size.height) { _, _ in
            random.color()
        }, isVisible: false)
        try expectMipLevelsMatch(compositor, CPUCompositor(),
                                 TileCoordinate(column: 1, row: 1),
                                 image([bottom, middle, top], active: 1), device)
    }

    private func expectMipLevelsMatch(_ compositor: MetalCompositor, _ cpu: CPUCompositor,
                                      _ tile: TileCoordinate, _ stack: LayeredImage,
                                      _ device: MTLDevice) throws {
        guard let cpuPixels = cpu.compositeTile(tile, of: stack) else {
            Issue.record("fixture tile must composite")
            return
        }
        let queue = try MetalTestTarget.makeCommandQueue(device)
        let buffer = try #require(queue.makeCommandBuffer())
        let target = try readableTileTexture(device, baseLevel: 0)
        #expect(compositor.encodeTile(tile, of: stack, baseLevel: 0, into: target, commandBuffer: buffer))
        buffer.commit()
        buffer.waitUntilCompleted()
        let size = validSize(of: tile, image: stack)
        let padded = cpuPadded(cpuPixels, validWidth: size.w, validHeight: size.h)
        let chain = TileMipmapper.mipChain(level0: padded, baseLevel: 0)
        #expect(chain.count == 7)
        for level in 0..<7 {
            let side = 256 >> level
            let comparison = GoldenImage.compare(
                readLevel(target, level: level, side: side),
                to: chain[level], width: side, height: side, tolerance: 1)
            #expect(comparison.mismatchCount == 0,
                    "level \(level): maxΔ \(comparison.maxChannelDelta), \(comparison.mismatchCount) mismatches, first: \(comparison.firstMismatches)")
        }
    }

    // MARK: - Hand values

    @Test func handValuesExact() throws {
        let device = try MetalTestTarget.makeDevice()
        let compositor = try makeCompositor(device)
        let size = PixelSize(width: 1, height: 1)
        let coord = TileCoordinate(column: 0, row: 0)
        func solid(_ color: ColorRGBA8, name: String, isVisible: Bool = true,
                   opacity: UInt8 = 255) -> Layer {
            var surface = TiledSurface(size: size)
            surface.setPixel(color, at: PixelPoint(x: 0, y: 0))
            return layer(name: name, surface: surface, isVisible: isVisible, opacity: opacity)
        }
        func composite(_ layers: [Layer]) throws -> ColorRGBA8 {
            let stack = image(layers, active: layers.count - 1)
            return try #require(compositor.compositeTilePixels(coord, of: stack))[0]
        }
        // (0,0,255,128) over (255,0,0,128) → (85,0,170,192).
        #expect(try composite([solid(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 128), name: "L"),
                               solid(ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 128), name: "U")])
                == ColorRGBA8(red: 85, green: 0, blue: 170, alpha: 192))
        // Red at layer opacity 128 over white → (255,127,127,255).
        #expect(try composite([solid(.white, name: "L"),
                               solid(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255), name: "U", opacity: 128)])
                == ColorRGBA8(red: 255, green: 127, blue: 127, alpha: 255))
        // (0,0,0,64) over white → (191,191,191,255).
        #expect(try composite([solid(.white, name: "L"),
                               solid(ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 64), name: "U")])
                == ColorRGBA8(red: 191, green: 191, blue: 191, alpha: 255))
        // Alpha-0 color under a layer keeps the lower pixel bit-identical.
        #expect(try composite([solid(ColorRGBA8(red: 1, green: 2, blue: 3, alpha: 200), name: "L"),
                               solid(ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 0), name: "U")])
                == ColorRGBA8(red: 1, green: 2, blue: 3, alpha: 200))
        // Hidden top ignored; opacity-0 top ignored.
        #expect(try composite([solid(.white, name: "L"),
                               solid(.black, name: "U", isVisible: false)]) == .white)
        #expect(try composite([solid(.white, name: "L"),
                               solid(.black, name: "U", opacity: 0)]) == .white)
        // In-canvas coverage + padding: 64×64 canvas inside the 256² tile.
        let canvas = PixelSize(width: 64, height: 64)
        var lower = TiledSurface(size: canvas)
        lower.fill(.white)
        var upper = TiledSurface(size: canvas)
        upper.fill(ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        let stack = image([layer(name: "W", surface: lower),
                           layer(name: "R", surface: upper, opacity: 128)], active: 1)
        let gpu = try #require(compositor.compositeTilePixels(coord, of: stack))
        #expect(gpu[0] == ColorRGBA8(red: 255, green: 127, blue: 127, alpha: 255))
        #expect(gpu[63 * 256 + 63] == ColorRGBA8(red: 255, green: 127, blue: 127, alpha: 255),
                "last in-canvas pixel")
        #expect(gpu[64 * 256 + 63] == .clear, "first padded row stays 0")
        #expect(gpu[64 * 256 + 64] == .clear, "padding beyond the canvas stays 0")
        try compareTile(compositor, CPUCompositor(), coord, stack)
    }

    @Test func contributingLayersRule() throws {
        let device = try MetalTestTarget.makeDevice()
        let compositor = try makeCompositor(device)
        let size = PixelSize(width: 64, height: 64)
        let coord = TileCoordinate(column: 0, row: 0)
        func surface(_ allocate: Bool) -> TiledSurface {
            let surface = TiledSurface(size: size)
            guard allocate else { return surface }
            var filled = surface
            filled.fill(.white)
            return filled
        }
        let stack = image([
            layer(name: "allocated", surface: surface(true)),
            layer(name: "hidden", surface: surface(true), isVisible: false),
            layer(name: "opacity0", surface: surface(true), opacity: 0),
            layer(name: "unallocated", surface: surface(false)),
            layer(name: "top", surface: surface(true)),
        ], active: 4)
        // Excludes hidden, opacity-0, unallocated; bottom → top indices.
        #expect(MetalCompositor.contributingLayers(of: stack, at: coord) == [0, 4])
        let queue = try MetalTestTarget.makeCommandQueue(device)
        let buffer = try #require(queue.makeCommandBuffer())
        let target = try readableTileTexture(device, baseLevel: 0)
        #expect(compositor.encodeTile(coord, of: stack, baseLevel: 0, into: target, commandBuffer: buffer))
        buffer.commit()
        buffer.waitUntilCompleted()
        // Nothing contributes → encode false and no pixels.
        let empty = image([layer(name: "hidden", surface: surface(true), isVisible: false),
                           layer(name: "unallocated", surface: surface(false))])
        let emptyBuffer = try #require(queue.makeCommandBuffer())
        #expect(!compositor.encodeTile(coord, of: empty, baseLevel: 0, into: target, commandBuffer: emptyBuffer))
        #expect(compositor.compositeTilePixels(coord, of: empty) == nil)
    }

    @Test func baseLevelChain() throws {
        let device = try MetalTestTarget.makeDevice()
        let compositor = try makeCompositor(device)
        let cpu = CPUCompositor()
        var random = SeededRandom(seed: 0xBA5E)
        let bottom = layer(name: "B", surface: TestImages.surface(width: 300, height: 300) { _, _ in
            random.color()
        })
        let top = layer(name: "T",
                        surface: TestImages.surface(width: 300, height: 300) { _, _ in random.color() },
                        opacity: 128)
        let stack = image([bottom, top], active: 1)
        let tile = TileCoordinate(column: 1, row: 1)   // the 44×44 edge tile
        // Probe: the GPU 256² accumulator must match the CPU tight tile re-strided
        // to 256 before the mip chain is compared.
        let gpuFull = try #require(compositor.compositeTilePixels(tile, of: stack))
        let cpuTight = try #require(cpu.compositeTile(tile, of: stack))
        var cpuStride256 = [ColorRGBA8](repeating: .clear, count: 256 * 256)
        for y in 0..<44 {
            for x in 0..<44 { cpuStride256[y * 256 + x] = cpuTight[y * 44 + x] }
        }
        let probe = GoldenImage.compare(gpuFull, to: cpuStride256, width: 256, height: 256,
                                        tolerance: 1)
        #expect(probe.mismatchCount == 0,
                "tight edge tile: maxΔ \(probe.maxChannelDelta), \(probe.mismatchCount) mismatches")
        let queue = try MetalTestTarget.makeCommandQueue(device)
        let buffer = try #require(queue.makeCommandBuffer())
        let target = try readableTileTexture(device, baseLevel: 3)
        #expect(target.width == 32 && target.height == 32)
        #expect(target.mipmapLevelCount == 4)
        #expect(compositor.encodeTile(tile, of: stack, baseLevel: 3, into: target, commandBuffer: buffer))
        buffer.commit()
        buffer.waitUntilCompleted()
        guard let cpuPixels = cpu.compositeTile(tile, of: stack) else {
            Issue.record("edge tile must composite")
            return
        }
        let padded = cpuPadded(cpuPixels, validWidth: 44, validHeight: 44)
        let chain = TileMipmapper.mipChain(level0: padded, baseLevel: 3)
        #expect(chain.count == 4)
        for (index, cpuLevel) in chain.enumerated() {
            let side = 32 >> index
            let comparison = GoldenImage.compare(
                readLevel(target, level: index, side: side),
                to: cpuLevel, width: side, height: side, tolerance: 1)
            let detail = comparison.firstMismatches.prefix(3)
                .map { "(\($0.x),\($0.y)) gpu \($0.actual) cpu \($0.expected)" }
                .joined(separator: " ")
            #expect(comparison.mismatchCount == 0,
                    "base-3 level \(3 + index): maxΔ \(comparison.maxChannelDelta), \(comparison.mismatchCount) mismatches, \(detail)")
        }
    }

    @Test func edgeTilePadding() throws {
        let device = try MetalTestTarget.makeDevice()
        let compositor = try makeCompositor(device)
        var random = SeededRandom(seed: 0xED6E)
        let stack = image([layer(name: "A",
                                 surface: TestImages.surface(width: 300, height: 300) { _, _ in random.color() })])
        let coord = TileCoordinate(column: 1, row: 1)
        let gpu = try #require(compositor.compositeTilePixels(coord, of: stack))
        // Straight blend: padding texels beyond 44×44 are exactly (0, 0, 0, 0).
        for y in 0..<256 {
            for x in 0..<256 where x >= 44 || y >= 44 {
                #expect(gpu[y * 256 + x] == .clear, "straight padding (\(x), \(y))")
            }
        }
        // Premultiplied texture: same beyond the valid region.
        let queue = try MetalTestTarget.makeCommandQueue(device)
        let buffer = try #require(queue.makeCommandBuffer())
        let target = try readableTileTexture(device, baseLevel: 0)
        #expect(compositor.encodeTile(coord, of: stack, baseLevel: 0, into: target, commandBuffer: buffer))
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0xFF, count: 256 * 256 * 4)
        target.getBytes(&bytes, bytesPerRow: 256 * 4,
                        from: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0)
        for y in 0..<256 {
            for x in 0..<256 where x >= 44 || y >= 44 {
                let offset = (y * 256 + x) * 4
                #expect(bytes[offset] == 0 && bytes[offset + 1] == 0
                            && bytes[offset + 2] == 0 && bytes[offset + 3] == 0,
                        "premultiplied padding (\(x), \(y))")
            }
        }
    }

    @Test func everyBlendModeHasKernel() throws {
        let device = try MetalTestTarget.makeDevice()
        let library = try #require(try? device.makeDefaultLibrary(bundle: Bundle(for: MetalCompositor.self)))
        for mode in BlendMode.allCases {
            #expect(library.makeFunction(name: mode.rawValue) != nil,
                    "missing blend kernel for \(mode.rawValue)")
        }
        #expect(library.makeFunction(name: "compositor_premultiply") != nil)
        #expect(library.makeFunction(name: "compositor_downsample") != nil)
    }

    @Test func uniformLayoutIsSound() {
        // `LayerBlendUniforms` mirrors the MSL `LayerBlendUniforms` (simd_int2 has
        // 8-byte alignment): opacity at 0, validSize at 8, stride 16.
        #expect(MemoryLayout<LayerBlendUniforms>.offset(of: \LayerBlendUniforms.opacity) == 0)
        #expect(MemoryLayout<LayerBlendUniforms>.offset(of: \LayerBlendUniforms.validSize) == 8)
        #expect(MemoryLayout<LayerBlendUniforms>.stride == 16)
    }

    @Test func hundredLayers() throws {
        let device = try MetalTestTarget.makeDevice()
        let compositor = try makeCompositor(device)
        let cpu = CPUCompositor()
        let size = PixelSize(width: 1, height: 1)
        // 100 layers of (255, 255, 255, 3) over transparent.
        var layers: [Layer] = []
        for index in 0..<100 {
            var surface = TiledSurface(size: size)
            surface.setPixel(ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 3),
                             at: PixelPoint(x: 0, y: 0))
            layers.append(layer(name: "W\(index)", surface: surface))
        }
        let stack = image(layers, active: 99)
        let coord = TileCoordinate(column: 0, row: 0)

        // 100-layer blend == CPU reference (±1).
        let gpu = try #require(compositor.compositeTilePixels(coord, of: stack))
        let reference = try #require(cpu.compositeTile(coord, of: stack))
        #expect(gpu[0].distance(to: reference[0]) <= 1,
                "100-layer blend \(gpu[0]) vs \(reference[0])")

        // baseLevel 3: a 32…4 four-level texture; the encode succeeds.
        let queue = try MetalTestTarget.makeCommandQueue(device)
        let buffer = try #require(queue.makeCommandBuffer())
        let target = try readableTileTexture(device, baseLevel: 3)
        let levelCount = target.mipmapLevelCount
        #expect(levelCount == 4, "100 layers at base 3: levels 3…6")
        #expect(compositor.encodeTile(coord, of: stack, baseLevel: 3, into: target, commandBuffer: buffer))
        buffer.commit()
        buffer.waitUntilCompleted()
        // The levels equal the CPU chain built at base level 3 from the CPU composite.
        let padded = cpuPadded(reference, validWidth: 1, validHeight: 1)
        let chain = TileMipmapper.mipChain(level0: padded, baseLevel: 3)
        for (index, cpuLevel) in chain.enumerated() {
            let side = 256 >> (3 + index)
            let comparison = GoldenImage.compare(
                readLevel(target, level: index, side: side),
                to: cpuLevel, width: side, height: side, tolerance: 1)
            expectNoMismatches(comparison, "base-3 level \(3 + index)")
        }
    }
}

private extension ColorRGBA8 {
    func with(alpha newAlpha: UInt8) -> ColorRGBA8 {
        ColorRGBA8(red: red, green: green, blue: blue, alpha: newAlpha)
    }

    func distance(to other: ColorRGBA8) -> Int {
        max(abs(Int(red) - Int(other.red)), abs(Int(green) - Int(other.green)),
            abs(Int(blue) - Int(other.blue)), abs(Int(alpha) - Int(other.alpha)))
    }
}
