import Foundation
import Metal
import simd

/// One frame's inputs for `MetalCanvasRenderer.encode(_:to:in:)`.
struct CanvasFrame {
    var image: LayeredImage
    var transform: CanvasTransform
    var checkerboard: CheckerboardStyle = .standard
    /// Opaque sRGB color shown outside the image (PRD APP-7: resolved from the current
    /// appearance by the caller).
    var backgroundColor: ColorRGBA8
}

/// What the renderer last did — used by tests and 0048's performance work.
struct CanvasRendererStatistics: Equatable, Sendable {
    var residentTileCount: Int
    /// Σ bytes of all resident tile textures (all mip levels).
    var residentTextureBytes: Int
    var tilesUploadedLastFrame: Int
    /// Composite tiles built last frame × their contributing layers (0024 NF-1).
    var layerTilesCopiedLastFrame: Int = 0
    /// The level `L` the last encoded frame used.
    var lastFrameLevel: Int
    /// Per resident tile with a known mip base level.
    var baseLevels: [TileCoordinate: Int] = [:]

    func baseLevel(of tile: TileCoordinate) -> Int? { baseLevels[tile] }
}

enum CanvasRendererError: Error, Equatable, Sendable {
    case libraryUnavailable
    case functionMissing(String)
    case pipelineCreationFailed(String)
}

/// The display compositor (spec 0003; PRD §4 Rendering, D-16: Metal for display, the CPU
/// compositor of 0012 is the reference). Draws the whole layer stack over the
/// checkerboard: 0024 replaced the single-layer upload path with the multi-layer
/// `MetalCompositor`, so resident textures hold **composite** tiles — one per visible,
/// stale, contributed 256×256 tile — and the frame uniform opacity is always 1 (layer
/// visibility and opacity live inside the composite). Every other 0003 behavior —
/// transform, checkerboard, sampling, intermediate, seam-free tiling, texture lifetime,
/// budget, `invalidateAll`, errors — is kept. Imports Metal only — no MetalKit, no
/// AppKit — so it renders headlessly into any texture.
@MainActor
final class MetalCanvasRenderer {
    /// The Apple GPU 2D texture size limit; the intermediate is bumped one mip level coarser
    /// per axis until it fits.
    static let maximumIntermediateDimension = 16_384

    /// Mirrors `CanvasUniforms` in `Canvas.metal` — keep both in sync.
    ///
    /// `setVertexBytes`/`setFragmentBytes` copy `MemoryLayout.stride` (112) bytes from the
    /// value, but a Swift stack temporary is only `MemoryLayout.size` bytes; without the
    /// explicit trailing filler (`_padding`, matching the C struct's implicit trailing pad,
    /// which Swift does not round to the 16-byte alignment) every frame read 8 bytes past
    /// its own stack slot. AddressSanitizer caught that out-of-bounds read inside the AGX
    /// driver's `setVertexBytes` memcpy — it is the root cause of the flaky `objc_release`
    /// test-host crashes. `uniformLayoutIsSound` refuses the mismatched layouts.
    private struct CanvasUniforms {
        var quadRect: simd_float4
        var intermediateOriginDevice: simd_float2
        var targetSize: simd_float2
        var checkerOrigin: simd_int2
        var intermediateSize: simd_uint2
        var validTexelSize: simd_uint2
        var devicePerTexel: Float
        var opacity: Float
        var checkerSide: Float
        var isNearest: Float
        var checkerLightR: Float
        var checkerLightG: Float
        var checkerLightB: Float
        var checkerLightA: Float
        var checkerDarkR: Float
        var checkerDarkG: Float
        var checkerDarkB: Float
        var checkerDarkA: Float
        /// Aligns `size` with `stride` (the C layout's 112-byte rounded size). Never read
        /// by the shader; the MSL struct's implicit pad sits at the same offset.
        var _padding: (Float, Float) = (0, 0)
    }

    /// True only when a `setVertexBytes(&uniforms, length: stride, …)` read stays inside
    /// the value's own allocation (the bug condition above).
    static var uniformLayoutIsSound: Bool {
        MemoryLayout<CanvasUniforms>.size == MemoryLayout<CanvasUniforms>.stride
    }

    private struct Resident {
        let texture: MTLTexture
        /// `nil` after a full refresh ("base level forgotten") until the tile is re-uploaded.
        var baseLevel: Int?
        /// Bytes the texture actually occupies (all mip levels of the level it was allocated
        /// at) — kept even when `baseLevel` is forgotten, so `residentTextureBytes` and the
        /// budget eviction never lose track of a stale-but-still-allocated texture.
        let allocatedBytes: Int
        var isStale: Bool
        var lastDrawnFrame: UInt64
    }

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    /// The 0024 multi-layer composite builder (same metallib as the quad pipeline).
    private let compositor: MetalCompositor
    private let targetPixelFormat: MTLPixelFormat
    private let textureBudgetBytes: Int
    private let tileStorageMode: MTLStorageMode
    /// Decides which composite tiles are stale (0024 item 5); replaces 0003's
    /// single-layer generation tracking.
    private var tracker = CompositeChangeTracker()
    /// 1×1 transparent texture bound for the no-contributing-layer checkerboard pass.
    private let clearTexture: MTLTexture

    private var resident: [TileCoordinate: Resident] = [:]
    /// Textures replaced or dropped; released only after the frame that dropped them completes.
    private var retired: [(texture: MTLTexture, frame: UInt64)] = []
    private var intermediate: MTLTexture?
    private var frameIndex: UInt64 = 0

    /// The canvas drawable size of the last frame that encoded, `nil` before the first.
    /// A zero-size frame (target or canvas) returns before it and never overwrites this.
    private(set) var lastFrameSize: CGSize?

    private(set) var statistics = CanvasRendererStatistics(
        residentTileCount: 0, residentTextureBytes: 0, tilesUploadedLastFrame: 0, lastFrameLevel: 0
    )

    convenience init(device: MTLDevice,
                     targetPixelFormat: MTLPixelFormat = .bgra8Unorm,
                     textureBudgetBytes: Int = 512 << 20) throws {
        // The app's default metallib lives in this class's bundle, which works both in the
        // app and in the hosted unit tests.
        try self.init(device: device, bundle: Bundle(for: MetalCanvasRenderer.self),
                      targetPixelFormat: targetPixelFormat, textureBudgetBytes: textureBudgetBytes)
    }

    /// Test-visible seam: a bundle without a metallib must fail with `.libraryUnavailable`,
    /// never crash.
    init(device: MTLDevice, bundle: Bundle,
         targetPixelFormat: MTLPixelFormat, textureBudgetBytes: Int) throws {
        let library: any MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: bundle)
        } catch {
            throw CanvasRendererError.libraryUnavailable
        }
        guard let vertex = library.makeFunction(name: "canvas_vertex") else {
            throw CanvasRendererError.functionMissing("canvas_vertex")
        }
        guard let fragment = library.makeFunction(name: "canvas_fragment") else {
            throw CanvasRendererError.functionMissing("canvas_fragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = targetPixelFormat
        let pipeline: MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw CanvasRendererError.pipelineCreationFailed(String(describing: error))
        }

        self.device = device
        self.pipeline = pipeline
        self.compositor = try MetalCompositor(device: device, library: library)
        self.targetPixelFormat = targetPixelFormat
        self.textureBudgetBytes = textureBudgetBytes
        self.tileStorageMode = device.hasUnifiedMemory ? .shared : .managed

        let clearDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        clearDescriptor.usage = .shaderRead
        clearDescriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let clearTexture = device.makeTexture(descriptor: clearDescriptor) else {
            throw CanvasRendererError.pipelineCreationFailed("could not allocate the clear texture")
        }
        clearTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
            withBytes: [UInt8](repeating: 0, count: 4), bytesPerRow: 4
        )
        self.clearTexture = clearTexture
    }

    /// Forget every resident texture's contents (whole-image replacement: revert, 0008's
    /// `.structure` history changes). Pixel edits never need it — `encode` finds them through
    /// the `CompositeChangeTracker`.
    func invalidateAll() {
        for entry in resident.values {
            retired.append((texture: entry.texture, frame: frameIndex))
        }
        resident.removeAll()
        tracker.reset()
        refreshStatistics(uploaded: statistics.tilesUploadedLastFrame, level: statistics.lastFrameLevel)
    }

    /// Draw one frame into `target`. A zero-size target — or a zero-size canvas (view of
    /// 0×0 while the window is being created) — encodes nothing and changes nothing.
    func encode(_ frame: CanvasFrame, to target: MTLTexture, in commandBuffer: MTLCommandBuffer) {
        guard target.width > 0, target.height > 0 else { return }
        let transform = frame.transform
        let canvasDrawable = transform.drawableSize
        guard canvasDrawable.width > 0, canvasDrawable.height > 0 else { return }
        frameIndex += 1
        let frameNumber = frameIndex
        lastFrameSize = CGSize(width: canvasDrawable.width, height: canvasDrawable.height)
        compositor.beginFrame()

        // 1a. Change tracking through 0024's `CompositeChangeTracker` — no dirty set
        // that callers must fill or clear. Runs every frame.
        switch tracker.update(for: frame.image) {
        case .all:
            for coordinate in [TileCoordinate](resident.keys) {
                resident[coordinate]?.isStale = true
                resident[coordinate]?.baseLevel = nil
            }
        case .tiles(let coordinates):
            for coordinate in coordinates {
                resident[coordinate]?.isStale = true
            }
        }

        // 2–5. Composite tiles, intermediate, and quad parameters happen first: Metal
        // allows only one active encoder per command buffer, and the background pass is
        // the last one.
        var uploads = 0
        var usedLevel = CanvasSampling.forZoom(transform.zoom).level
        var quadTexture: MTLTexture?
        var quadUniforms: CanvasUniforms?
        let drawnRect = transform.drawnImageRectInDevice
        if let range = transform.visibleTileRange, !drawnRect.isEmpty {
            // An image with no contributing layer anywhere (none visible, or all at
            // opacity 0) shows checkerboard only — and keeps no composite textures.
            let hasVisibleLayer = frame.image.layers.contains { $0.isVisible && $0.opacity > 0 }
            if !hasVisibleLayer {
                for coordinate in [TileCoordinate](resident.keys) {
                    dropResident(coordinate, frame: frameNumber)
                }
                var uniforms = Self.checkerUniforms(frame: frame, target: target)
                uniforms.opacity = 0
                uniforms.isNearest = 1
                uniforms.devicePerTexel = 1
                uniforms.validTexelSize = simd_uint2(1, 1)
                uniforms.intermediateSize = simd_uint2(1, 1)
                quadTexture = clearTexture
                quadUniforms = uniforms
            } else if let intermediate = prepareIntermediate(
                range: range, level: &usedLevel, image: frame.image,
                commandBuffer: commandBuffer, frame: frameNumber, uploads: &uploads
            ) {
                quadTexture = intermediate
                quadUniforms = Self.frameUniforms(
                    frame: frame, target: target, range: range, level: usedLevel,
                    intermediate: intermediate
                )
            }
            // When prepareIntermediate returns nil the GPU could not provide a texture:
            // draw the background only, never crash.
        }

        // 2. Background pass (and the image quad) — one render encoder.
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = target
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(frame.backgroundColor.red) / 255,
            green: Double(frame.backgroundColor.green) / 255,
            blue: Double(frame.backgroundColor.blue) / 255,
            alpha: Double(frame.backgroundColor.alpha) / 255
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            refreshStatistics(uploaded: 0, level: statistics.lastFrameLevel)
            return
        }
        if let quadTexture, var quadUniforms {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&quadUniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&quadUniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
            encoder.setFragmentTexture(quadTexture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()

        // 6. A texture replaced this frame may still be read by an in-flight command buffer;
        // release it only after this frame completes.
        commandBuffer.addCompletedHandler { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reapRetired(completedThrough: frameNumber)
            }
        }

        // 7. Texture budget: evict least recently drawn non-visible tiles.
        evictOverBudget(visible: transform.visibleTileRange)
        refreshStatistics(uploaded: uploads, level: usedLevel)
    }

    // MARK: - Per-frame helpers

    /// Builds the composite textures the visible range needs and builds/clears/fills the
    /// intermediate texture; returns it, or `nil` when the GPU could not provide one
    /// (graceful skip).
    private func prepareIntermediate(range: TileRange, level: inout Int, image: LayeredImage,
                                     commandBuffer: MTLCommandBuffer,
                                     frame frameNumber: UInt64, uploads: inout Int) -> MTLTexture? {
        let tileSide = TiledSurface.tileSize
        // Level bump so the intermediate never exceeds the 2D texture limit per axis.
        while level < CanvasSampling.maximumLevel,
              range.columns.count * (tileSide >> level) > Self.maximumIntermediateDimension
                || range.rows.count * (tileSide >> level) > Self.maximumIntermediateDimension {
            level += 1
        }
        let texelSide = tileSide >> level

        // 3. Composite per tile: visible tiles that are new, stale, or too coarse. The
        // 0024 base-level policy: `B = 0` for `L ≤ 2` (zoom ≥ 25 %) so the full 0…6
        // chain survives zoom and pan; `B = L` below 25 % bounds memory for huge images
        // (as 0003). A resident tile with base ≤ the needed level is reused as is.
        let baseLevel = level <= 2 ? 0 : level
        for coordinate in range.coordinates {
            guard MetalCompositor.contributingLayers(of: image, at: coordinate).isEmpty == false else {
                dropResident(coordinate, frame: frameNumber)   // now empty → no texture
                continue
            }
            if let existing = resident[coordinate], !existing.isStale,
               let existingBase = existing.baseLevel, existingBase <= level {
                resident[coordinate]?.lastDrawnFrame = frameNumber
                continue
            }
            guard let texture = compositor.makeTileTexture(baseLevel: baseLevel),
                  compositor.encodeTile(coordinate, of: image, baseLevel: baseLevel,
                                        into: texture, commandBuffer: commandBuffer)
            else { continue }   // GPU could not provide buffers for this tile — skip it
            if let previous = resident[coordinate] {
                retired.append((texture: previous.texture, frame: frameNumber))
            }
            resident[coordinate] = Resident(texture: texture, baseLevel: baseLevel,
                                            allocatedBytes: Self.textureBytes(baseLevel: baseLevel),
                                            isStale: false, lastDrawnFrame: frameNumber)
            uploads += 1
        }

        // 4. Intermediate: grow-only reuse, cleared, then exact texel copies per tile.
        let width = range.columns.count * texelSide
        let height = range.rows.count * texelSide
        let texture: MTLTexture
        if let existing = intermediate, existing.width >= width, existing.height >= height {
            texture = existing
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead, .renderTarget]
            descriptor.storageMode = .private
            guard let created = device.makeTexture(descriptor: descriptor) else { return nil }
            intermediate = created
            texture = created
        }
        let clearPass = MTLRenderPassDescriptor()
        clearPass.colorAttachments[0].texture = texture
        clearPass.colorAttachments[0].loadAction = .clear
        clearPass.colorAttachments[0].storeAction = .store
        clearPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let clearEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: clearPass) else {
            return nil
        }
        clearEncoder.endEncoding()
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return texture }
        for coordinate in range.coordinates {
            guard let entry = resident[coordinate], let base = entry.baseLevel, base <= level else { continue }
            blit.copy(
                from: entry.texture, sourceSlice: 0, sourceLevel: level - base,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: texelSide, height: texelSide, depth: 1),
                to: texture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(
                    x: (coordinate.column - range.columns.lowerBound) * texelSide,
                    y: (coordinate.row - range.rows.lowerBound) * texelSide, z: 0
                )
            )
        }
        blit.endEncoding()
        return texture
    }

    private func dropResident(_ coordinate: TileCoordinate, frame frameNumber: UInt64) {
        guard let entry = resident.removeValue(forKey: coordinate) else { return }
        retired.append((texture: entry.texture, frame: frameNumber))
    }

    /// Static per-frame uniforms shared by both passes.
    private static func checkerUniforms(frame: CanvasFrame, target: MTLTexture) -> CanvasUniforms {
        let transform = frame.transform
        let origin = transform.imageOriginInDevice
        let drawn = transform.drawnImageRectInDevice
        let checker = frame.checkerboard
        return CanvasUniforms(
            quadRect: simd_float4(Float(drawn.x), Float(drawn.y), Float(drawn.width), Float(drawn.height)),
            intermediateOriginDevice: .zero,
            targetSize: simd_float2(Float(target.width), Float(target.height)),
            checkerOrigin: simd_int2(Int32(truncatingIfNeeded: origin.x), Int32(truncatingIfNeeded: origin.y)),
            intermediateSize: .zero,
            validTexelSize: .zero,
            devicePerTexel: 1,
            opacity: 1,
            checkerSide: Float(checker.squareSize * transform.backingScale),
            isNearest: 1,
            checkerLightR: Float(checker.lightColor.red) / 255,
            checkerLightG: Float(checker.lightColor.green) / 255,
            checkerLightB: Float(checker.lightColor.blue) / 255,
            checkerLightA: Float(checker.lightColor.alpha) / 255,
            checkerDarkR: Float(checker.darkColor.red) / 255,
            checkerDarkG: Float(checker.darkColor.green) / 255,
            checkerDarkB: Float(checker.darkColor.blue) / 255,
            checkerDarkA: Float(checker.darkColor.alpha) / 255
        )
    }

    private static func frameUniforms(frame: CanvasFrame, target: MTLTexture, range: TileRange,
                                      level: Int, intermediate: MTLTexture) -> CanvasUniforms {
        let transform = frame.transform
        let origin = transform.imageOriginInDevice
        let tileSide = TiledSurface.tileSize
        // Large-magnitude math in Double; the GPU only sees values relative to the target.
        let firstColumn = range.columns.lowerBound
        let firstRow = range.rows.lowerBound
        let intermediateOrigin = simd_float2(
            Float(Double(origin.x) + Double(firstColumn * tileSide) * transform.zoom),
            Float(Double(origin.y) + Double(firstRow * tileSide) * transform.zoom)
        )
        let scale = Double(1 << level)
        let validWidth = min(
            ceil((Double(transform.imageSize.width) - Double(firstColumn * tileSide)) / scale),
            Double(intermediate.width)
        )
        let validHeight = min(
            ceil((Double(transform.imageSize.height) - Double(firstRow * tileSide)) / scale),
            Double(intermediate.height)
        )
        var uniforms = checkerUniforms(frame: frame, target: target)
        uniforms.intermediateOriginDevice = intermediateOrigin
        uniforms.intermediateSize = simd_uint2(
            UInt32(truncatingIfNeeded: intermediate.width), UInt32(truncatingIfNeeded: intermediate.height)
        )
        uniforms.validTexelSize = simd_uint2(
            UInt32(clamping: Int(clampedDouble: validWidth)), UInt32(clamping: Int(clampedDouble: validHeight))
        )
        uniforms.devicePerTexel = Float(transform.zoom * scale)
        // Layer opacity and visibility are inside the composite now (0024 item 6).
        uniforms.opacity = 1
        uniforms.isNearest = CanvasSampling.forZoom(transform.zoom) == .nearest ? 1 : 0
        return uniforms
    }

    private func evictOverBudget(visible: TileRange?) {
        var bytes = residentByteCount()
        guard bytes > textureBudgetBytes else { return }
        let visibleSet = Set(visible?.coordinates ?? [])
        for (coordinate, entry) in resident.sorted(by: { $0.value.lastDrawnFrame < $1.value.lastDrawnFrame }) {
            guard bytes > textureBudgetBytes else { break }
            guard !visibleSet.contains(coordinate) else { continue }
            bytes -= entry.allocatedBytes
            resident.removeValue(forKey: coordinate)
            retired.append((texture: entry.texture, frame: frameIndex))
        }
    }

    private func reapRetired(completedThrough frame: UInt64) {
        retired.removeAll { $0.frame <= frame }
    }

    /// Texture bytes of one tile allocated at `baseLevel`: Σ (256 >> k)² · 4 for every
    /// level from `baseLevel` to the last one the chain carries.
    private static func textureBytes(baseLevel: Int) -> Int {
        var side = TiledSurface.tileSize >> baseLevel
        var bytes = 0
        for _ in baseLevel...CanvasSampling.maximumLevel {
            bytes += side * side * PixelFormat.rgba8.bytesPerPixel
            side /= 2
        }
        return bytes
    }

    private func residentByteCount() -> Int {
        resident.values.reduce(0) { $0 + $1.allocatedBytes }
    }

    private func refreshStatistics(uploaded: Int, level: Int) {
        var baseLevels: [TileCoordinate: Int] = [:]
        baseLevels.reserveCapacity(resident.count)
        for (coordinate, entry) in resident {
            if let base = entry.baseLevel { baseLevels[coordinate] = base }
        }
        statistics = CanvasRendererStatistics(
            residentTileCount: resident.count,
            residentTextureBytes: residentByteCount(),
            tilesUploadedLastFrame: uploaded,
            layerTilesCopiedLastFrame: compositor.layerTilesCopiedLastFrame,
            lastFrameLevel: level,
            baseLevels: baseLevels
        )
    }
}
