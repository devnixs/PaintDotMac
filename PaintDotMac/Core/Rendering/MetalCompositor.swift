import Foundation
import Metal

/// Mirrors `LayerBlendUniforms` in `Blend.metal` — keep both in sync. `validSize` is the
/// tile's in-canvas size; the MSL struct's explicit pad pins both fields' offsets, and
/// `MetalCompositorTests.uniformLayoutIsSound` pins the Swift offset.
struct LayerBlendUniforms {
    var opacity: UInt32
    var validSize: SIMD2<UInt32>
}

/// The multi-layer Metal display compositor (spec 0024 item 4; PRD §4 *Rendering*, D-16).
/// Builds one composite tile texture — straight stack blended per the 0009 formulas by
/// the kernels in `Blend.metal`, then premultiplied and mipmapped exactly like 0003's
/// `TileMipmapper` upload path — inside the frame's command buffer. The CPU reference is
/// `CPUCompositor` (0012); the golden and random tests pin the parity at ±1 per channel
/// (integer math makes them bit-exact in practice). Imports Metal only — no AppKit.
@MainActor
final class MetalCompositor {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    /// One compute pipeline per `BlendMode` case, function name = `rawValue` (AGENTS.md
    /// *Code style*); `everyBlendModeHasKernel` proves the kernels exist.
    private let blendPipelines: [BlendMode: MTLComputePipelineState]
    private let premultiplyPipeline: MTLComputePipelineState
    private let downsamplePipeline: MTLComputePipelineState
    private let storageOptions: MTLResourceOptions

    /// Staging buffers (one contributing layer's 256 KB tile each) and accumulator
    /// buffers (256² `uchar4`), pooled — but a buffer returns to the pool only in the
    /// command buffer's completed handler (hopping to the main actor), so an in-flight
    /// frame never shares one.
    private var stagingPool: [MTLBuffer] = []
    private var accumulatorPool: [MTLBuffer] = []
    /// The full-chain 256² premultiply target used when `baseLevel > 0`, with its cached
    /// single-level `.rgba8Uint` views. `@unchecked Sendable` purely to cross the
    /// completed-handler boundary (the same box pattern 0003 uses): the pool and every
    /// use stay on the main actor, and an in-flight frame never shares one.
    private struct Transient: @unchecked Sendable {
        let texture: MTLTexture
        let levelViews: [MTLTexture]
    }
    /// A frame's pooled staging/accumulator buffers as one `@unchecked Sendable` box
    /// (main-actor discipline as for `Transient`).
    private struct PooledResources: @unchecked Sendable {
        let staging: [MTLBuffer]
        let accumulator: MTLBuffer
    }
    private var transientPool: [Transient] = []

    /// Σ contributing layers over the composite tiles `encodeTile` built since the last
    /// `beginFrame()` — 0024's NF-1 visibility (the renderer copies it into
    /// `CanvasRendererStatistics.layerTilesCopiedLastFrame`).
    private(set) var layerTilesCopiedLastFrame: Int = 0

    /// Resets the per-frame counter (called by `MetalCanvasRenderer` at frame start).
    func beginFrame() { layerTilesCopiedLastFrame = 0 }

    /// One pipeline per `BlendMode.allCases` (function name = `rawValue`) plus
    /// premultiply and downsample. A missing function throws `.functionMissing(name)`;
    /// the canvas then follows 0003's error handling.
    init(device: MTLDevice, library: MTLLibrary) throws(CanvasRendererError) {
        func pipeline(_ name: String) throws(CanvasRendererError) -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw .functionMissing(name)
            }
            do { return try device.makeComputePipelineState(function: function) }
            catch { throw .pipelineCreationFailed(String(describing: error)) }
        }
        var blends: [BlendMode: MTLComputePipelineState] = [:]
        for mode in BlendMode.allCases {
            blends[mode] = try pipeline(mode.rawValue)
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw .pipelineCreationFailed("could not create the compositor command queue")
        }
        self.device = device
        self.commandQueue = commandQueue
        self.blendPipelines = blends
        self.premultiplyPipeline = try pipeline("compositor_premultiply")
        self.downsamplePipeline = try pipeline("compositor_downsample")
        self.storageOptions = device.hasUnifiedMemory ? .storageModeShared : .storageModeManaged
    }

    /// Indices (bottom → top) of layers that contribute to `tile`: visible, opacity > 0,
    /// and with an allocated tile at `coordinate`. Pure; empty for a coordinate outside
    /// the tile grid.
    nonisolated static func contributingLayers(of image: LayeredImage, at tile: TileCoordinate) -> [Int] {
        let side = TiledSurface.tileSize
        let columns = (image.size.width + side - 1) / side
        let rows = (image.size.height + side - 1) / side
        guard (0..<columns).contains(tile.column), (0..<rows).contains(tile.row) else { return [] }
        return image.layers.indices.filter { index in
            let layer = image.layers[index]
            return layer.isVisible && layer.opacity > 0
                && layer.surface.tile(at: tile) != nil
            }
    }

    /// Encodes the composite of `tile` into `target` — a `(256 >> baseLevel)²`
    /// `.rgba8Unorm` texture with `7 − baseLevel` mip levels, holding the premultiplied
    /// composite at its levels 0…(6 − baseLevel), i.e. the tile's levels
    /// `baseLevel`…6 — into `commandBuffer`. Returns false (encodes nothing) when no
    /// layer contributes.
    func encodeTile(_ tile: TileCoordinate, of image: LayeredImage, baseLevel: Int,
                    into target: MTLTexture, commandBuffer: MTLCommandBuffer) -> Bool {
        guard Self.contributingLayers(of: image, at: tile).isEmpty == false else { return false }
        var transient: Transient?
        if baseLevel > 0 {
            guard let pooled = dequeueTransient() else { return false }
            // Return the transient through the completed handler right away — every path
            // out of `encode` (including a mid-encode resource failure) gives it back.
            commandBuffer.addCompletedHandler { [weak self] _ in
                Task { @MainActor [weak self] in self?.transientPool.append(pooled) }
            }
            transient = pooled
        }
        return encode(tile, of: image, baseLevel: baseLevel, into: target,
                      commandBuffer: commandBuffer, transient: transient)
    }

    /// Synchronous straight-alpha readback of one composite tile (commit +
    /// waitUntilCompleted). For tests and diagnostics only — never called on the display
    /// path. `nil` when no layer contributes. The 256×256 result is the accumulator
    /// straight after the blend kernels (premultiply never escapes; padding stays 0).
    func compositeTilePixels(_ tile: TileCoordinate, of image: LayeredImage) -> [ColorRGBA8]? {
        guard Self.contributingLayers(of: image, at: tile).isEmpty == false,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let accumulator = makeBuffer(Tile.byteCount),
              let chain = makeTileTexture(baseLevel: 0),
              let chainViews = Self.uintViews(of: chain) else { return nil }
        // Dedicated buffers, never pooled: the readback below must own them until the
        // command buffer completes (no `addCompletedHandler` recycles them).
        guard encode(tile, of: image, baseLevel: 0, into: chain, commandBuffer: commandBuffer,
                     transient: nil, dedicatedAccumulator: accumulator, dedicatedViews: chainViews) else { return nil }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let contents = accumulator.contents()
        let bytes = contents.bindMemory(to: UInt8.self, capacity: Tile.byteCount)
        var pixels = [ColorRGBA8](repeating: .clear,
                                  count: TiledSurface.tileSize * TiledSurface.tileSize)
        for index in pixels.indices {
            let offset = index * 4
            pixels[index] = ColorRGBA8(red: bytes[offset], green: bytes[offset + 1],
                                       blue: bytes[offset + 2], alpha: bytes[offset + 3])
        }
        return pixels
    }

    // MARK: - Encoding

    /// The 0024 item 4 algorithm:
    /// (1) contributors (already checked by the caller),
    /// (2) each contributing layer's tile bytes → a staging buffer (CPU copy into shared
    /// memory), (3) blit-zero the accumulator, (4) one kernel per contributing layer
    /// bottom → top with `opacity` and the tile's in-canvas `validSize`,
    /// (5) `compositor_premultiply` into level 0 of a full-chain 256² texture (the target
    /// itself when `baseLevel == 0`, else the transient) and `compositor_downsample`
    /// level by level down to 6, (6) for `baseLevel > 0` a blit of the transient's
    /// levels `baseLevel`…6 into the target's levels 0…(6 − baseLevel).
    ///
    /// Pooled buffers (display path) return through the completed handler; dedicated
    /// buffers (readback path) stay owned by the caller.
    private func encode(_ tile: TileCoordinate, of image: LayeredImage, baseLevel: Int,
                        into target: MTLTexture, commandBuffer: MTLCommandBuffer,
                        transient: Transient?,
                        dedicatedAccumulator: MTLBuffer? = nil,
                        dedicatedViews: [MTLTexture]? = nil) -> Bool {
        let contributors = Self.contributingLayers(of: image, at: tile)
        guard !contributors.isEmpty else { return false }
        let side = TiledSurface.tileSize
        let validWidth = min(side, image.size.width - tile.column * side)
        let validHeight = min(side, image.size.height - tile.row * side)

        // (2) Staging.
        var staging: [MTLBuffer] = []
        staging.reserveCapacity(contributors.count)
        for layerIndex in contributors {
            guard let buffer = dedicatedAccumulator == nil ? dequeueStaging() : makeBuffer(Tile.byteCount),
                  // `contributingLayers` guarantees the tile exists.
                  let layerTile = image.layers[layerIndex].surface.tile(at: tile)
            else { return false }
            let contents = buffer.contents()
            layerTile.withUnsafeBytes { source in
                if let base = source.baseAddress { memcpy(contents, base, Tile.byteCount) }
            }
            staging.append(buffer)
        }
        // (3) Accumulator.
        let accumulator = dedicatedAccumulator ?? dequeueAccumulator()
        guard let accumulator else { return false }

        // Pooled buffers live until the frame completes; then they hop back to the pool
        // — never reused by an in-flight frame.
        let displayPath = dedicatedAccumulator == nil
        if displayPath {
            layerTilesCopiedLastFrame += contributors.count
            let pooled = PooledResources(staging: staging, accumulator: accumulator)
            commandBuffer.addCompletedHandler { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.stagingPool.append(contentsOf: pooled.staging)
                    self.accumulatorPool.append(pooled.accumulator)
                }
            }
        }

        let chainViews = dedicatedViews ?? (baseLevel == 0 ? Self.uintViews(of: target) : transient?.levelViews)
        guard let chainViews, chainViews.count == TileMipmapper.levelCount else { return false }

        guard let zero = commandBuffer.makeBlitCommandEncoder() else { return false }
        zero.fill(buffer: accumulator, range: 0..<Tile.byteCount, value: 0)
        zero.endEncoding()

        // (4–5) Blend kernels, premultiply, and the mip chain — one compute encoder.
        guard let compute = commandBuffer.makeComputeCommandEncoder() else { return false }
        var uniforms = LayerBlendUniforms(opacity: 0,
                                          validSize: SIMD2(UInt32(validWidth), UInt32(validHeight)))
        for (slot, layerIndex) in contributors.enumerated() {
            let layer = image.layers[layerIndex]
            guard let pipeline = blendPipelines[layer.blendMode] else { return false }
            uniforms.opacity = UInt32(layer.opacity)
            compute.setComputePipelineState(pipeline)
            compute.setBuffer(accumulator, offset: 0, index: 0)
            compute.setBuffer(staging[slot], offset: 0, index: 1)
            compute.setBytes(&uniforms, length: MemoryLayout<LayerBlendUniforms>.stride, index: 2)
            Self.dispatch(compute, pipeline, width: side, height: side)
        }
        // (5) Premultiply into level 0 (`opacity` is unused by the kernel; `validSize`
        // zeroes the edge-tile padding).
        uniforms.opacity = 255
        compute.setComputePipelineState(premultiplyPipeline)
        compute.setBuffer(accumulator, offset: 0, index: 0)
        compute.setBytes(&uniforms, length: MemoryLayout<LayerBlendUniforms>.stride, index: 1)
        compute.setTexture(chainViews[0], index: 0)
        Self.dispatch(compute, premultiplyPipeline, width: side, height: side)
        // …and downsample level by level down to 6 (the transient/target chain is always
        // the full 0…6 chain; the coarse target receives the tail by blit below).
        for level in 0..<CanvasSampling.maximumLevel {
            compute.setComputePipelineState(downsamplePipeline)
            compute.setTexture(chainViews[level], index: 0)
            compute.setTexture(chainViews[level + 1], index: 1)
            let dstSide = side >> (level + 1)
            Self.dispatch(compute, downsamplePipeline, width: dstSide, height: dstSide)
        }
        compute.endEncoding()

        // (6) `baseLevel > 0`: blit the transient's coarse tail into the target. (The
        // transient returns to its pool through the completed handler `encodeTile`
        // registered when it was dequeued.)
        if baseLevel > 0, let transient {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
            var coarseSide = side >> baseLevel
            for level in baseLevel..<TileMipmapper.levelCount {
                blit.copy(from: transient.texture, sourceSlice: 0, sourceLevel: level,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: coarseSide, height: coarseSide, depth: 1),
                          to: target, destinationSlice: 0, destinationLevel: level - baseLevel,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                coarseSide /= 2
            }
            blit.endEncoding()
        }
        return true
    }

    // MARK: - Pools and GPU resources

    private func dequeueStaging() -> MTLBuffer? {
        stagingPool.popLast() ?? makeBuffer(Tile.byteCount)
    }

    private func dequeueAccumulator() -> MTLBuffer? {
        accumulatorPool.popLast() ?? makeBuffer(Tile.byteCount)
    }

    private func makeBuffer(_ length: Int) -> MTLBuffer? {
        device.makeBuffer(length: length, options: storageOptions)
    }

    private func dequeueTransient() -> Transient? {
        if let pooled = transientPool.popLast() { return pooled }
        guard let texture = makeTileTexture(baseLevel: 0),
              let levelViews = Self.uintViews(of: texture) else { return nil }
        return Transient(texture: texture, levelViews: levelViews)
    }

    /// A tile texture of `baseLevel`'s chain: `(256 >> baseLevel)²` pixels,
    /// `7 − baseLevel` mip levels, sampleable and integer-viewable.
    func makeTileTexture(baseLevel: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: TiledSurface.tileSize >> baseLevel,
            height: TiledSurface.tileSize >> baseLevel,
            mipmapped: true
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        descriptor.storageMode = .private
        descriptor.mipmapLevelCount = TileMipmapper.levelCount - baseLevel
        return device.makeTexture(descriptor: descriptor)
    }

    /// One `.rgba8Uint` view per mip level so the kernels read and write exact integers
    /// with no float conversion (spec 0024 item 3). The views inherit the texture's
    /// usage (`.shaderRead | .shaderWrite | .pixelFormatView`).
    private static func uintViews(of texture: MTLTexture) -> [MTLTexture]? {
        var views: [MTLTexture] = []
        views.reserveCapacity(texture.mipmapLevelCount)
        for level in 0..<texture.mipmapLevelCount {
            guard let view = texture.makeTextureView(
                pixelFormat: .rgba8Uint, textureType: .type2D,
                levels: level..<(level + 1), slices: 0..<1
            ) else { return nil }
            views.append(view)
        }
        return views
    }

    private static func dispatch(_ encoder: MTLComputeCommandEncoder,
                                 _ pipeline: MTLComputePipelineState,
                                 width: Int, height: Int) {
        let groupSide = max(8, min(16, Int(Double(pipeline.maxTotalThreadsPerThreadgroup).squareRoot())))
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(
                                    width: min(groupSide, width),
                                    height: min(groupSide, height), depth: 1))
    }
}
