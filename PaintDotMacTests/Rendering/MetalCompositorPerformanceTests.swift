import Foundation
import Metal
import XCTest

@testable import PaintDotMac

/// NF-1 / NF-2 measurements for the multi-layer display compositor (spec 0024): a
/// 3840×2160 document with 10 fully allocated layers, rendered into an offscreen
/// 2560×1600 target (a 1280×800-point window at 2×). Reported numbers go into the
/// spec's Verification status; the gates are deliberately loose (3×) — optimization is 0048.
@MainActor
final class MetalCompositorPerformanceTests: XCTestCase {
    private static var shared: (image: LayeredImage, device: MTLDevice)?

    private let imageSize = PixelSize(width: 3840, height: 2160)
    private let targetSize = (width: 2560, height: 1600)
    private let zooms: [Double] = [0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0, 2.0, 4.0]

    /// The 10-layer document is built once per process (≈ 350 MB of shared tiles).
    private func fixture() throws -> (image: LayeredImage, device: MTLDevice) {
        if let shared = Self.shared { return shared }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        var layers: [Layer] = []
        let opacities: [UInt8] = [255, 200, 128, 255, 96, 255, 255, 64, 180, 255]
        for index in 0..<10 {
            var random = SeededRandom(seed: 0xFEED_0000 &+ UInt64(index))
            var surface = TiledSurface(size: imageSize)
            for row in 0...((imageSize.height - 1) / TiledSurface.tileSize) {
                for column in 0...((imageSize.width - 1) / TiledSurface.tileSize) {
                    var tile = Tile()
                    tile.withUnsafeMutableBytes { raw in
                        let bytes = raw.bindMemory(to: UInt8.self)
                        for y in 0..<TiledSurface.tileSize {
                            let canvasY = row * TiledSurface.tileSize + y
                            guard canvasY < imageSize.height else { break }
                            let usable = min(TiledSurface.tileSize,
                                             imageSize.width - column * TiledSurface.tileSize)
                            for x in 0..<usable {
                                let offset = (y * TiledSurface.tileSize + x) * 4
                                bytes[offset] = random.byte()
                                bytes[offset + 1] = random.byte()
                                bytes[offset + 2] = random.byte()
                                bytes[offset + 3] = y % 3 == 0 ? 255 : random.byte()
                            }
                        }
                    }
                    surface.setTile(tile, at: TileCoordinate(column: column, row: row))
                }
            }
            layers.append(Layer(name: "L\(index)", surface: surface,
                                isVisible: index != 3 && index != 7,
                                opacity: opacities[index]))
        }
        let image = LayeredImage(size: imageSize, layers: layers, activeLayerIndex: 9)
        Self.shared = (image, device)
        return (image, device)
    }

    private func makeContext(_ device: MTLDevice) throws -> (MTLCommandQueue, MTLTexture) {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: targetSize.width, height: targetSize.height,
            mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        return (queue, try XCTUnwrap(device.makeTexture(descriptor: descriptor)))
    }

    private func renderOnce(_ renderer: MetalCanvasRenderer, image: LayeredImage,
                            transform: CanvasTransform,
                            context: (queue: MTLCommandQueue, target: MTLTexture)) throws {
        let buffer = try XCTUnwrap(context.queue.makeCommandBuffer())
        renderer.encode(CanvasFrame(image: image, transform: transform,
                                    backgroundColor: CanvasReferenceRenderer.testBackground),
                        to: context.target, in: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    private func transform(zoom: Double, centerX: Double) -> CanvasTransform {
        CanvasTransform(
            imageSize: imageSize,
            viewSize: CGSize(width: Double(targetSize.width) / 2,
                             height: Double(targetSize.height) / 2),
            backingScale: 2, zoom: zoom,
            center: CGPoint(x: centerX, y: Double(imageSize.height) / 2))
    }

    /// NF-2: 120 frames alternating pan (+37 device px) and the 0004 zoom presets.
    /// Target ≤ 16.7 ms/frame; gate ≤ 50 ms.
    func testPanZoom10Layer4K() throws {
        let image = try fixture().image
        let device = try fixture().device
        let renderer = try MetalCanvasRenderer(device: device)
        let context = try makeContext(device)
        for zoom in zooms {   // warm-up: one frame at every zoom
            try renderOnce(renderer, image: image,
                           transform: transform(zoom: zoom, centerX: Double(imageSize.width) / 2),
                           context: context)
        }
        var frameTimes: [Double] = []
        let frames = 120
        measure(metrics: [XCTClockMetric()],
                options: { let o = XCTMeasureOptions(); o.iterationCount = 1; return o }()) {
            var centerX = Double(imageSize.width) / 2
            for frame in 0..<frames {
                let zoom = zooms[frame / 2 % zooms.count]
                if frame % 2 == 0 { centerX += 37.0 / zoom }
                centerX = min(max(centerX, 1), Double(imageSize.width) - 1)
                let start = ContinuousClock.now
                try! renderOnce(renderer, image: image,
                                transform: transform(zoom: zoom, centerX: centerX),
                                context: context)
                frameTimes.append(start.duration(to: .now).seconds * 1000)
            }
        }
        let average = frameTimes.reduce(0, +) / Double(frameTimes.count)
        let median = frameTimes.sorted()[frameTimes.count / 2]
        print("spec 0024 NF-2 pan/zoom 10-layer 4K: average \(average) ms, "
              + "median \(median) ms over \(frames) frames")
        XCTAssertLessThan(average, 50.0, "pan/zoom frame averaged over 3× the 16.7 ms target")
    }

    /// NF-1 impact: one-tile paint edit + frame at 100 %; gate ≤ 50 ms.
    func testSingleTileEditFrame() throws {
        var image = try fixture().image
        let device = try fixture().device
        let renderer = try MetalCanvasRenderer(device: device)
        let context = try makeContext(device)
        let full = transform(zoom: 1, centerX: 1024)
        try renderOnce(renderer, image: image, transform: full, context: context)
        var frameTimes: [Double] = []
        var block = 0
        measure(metrics: [XCTClockMetric()],
                options: { let o = XCTMeasureOptions(); o.iterationCount = 8; return o }()) {
            let start = ContinuousClock.now
            block += 1
            let origin = (block % 20) * 256 + 4   // one tile per iteration
            for y in 0..<10 {
                for x in 0..<10 {
                    image.layers[9].surface.setPixel(.white, at: PixelPoint(x: origin + x, y: 4 + y))
                }
            }
            try! renderOnce(renderer, image: image, transform: full, context: context)
            frameTimes.append(start.duration(to: .now).seconds * 1000)
        }
        let average = frameTimes.reduce(0, +) / Double(frameTimes.count)
        print("spec 0024 NF-1 single-tile edit frame (10 layers, 4K, 100 %): average \(average) ms")
        XCTAssertLessThan(average, 50.0, "single-tile edit frame past the 3× gate")
    }

    /// Whole-visible-area recomposite at fit zoom after `invalidateAll()`; gate ≤ 2 s.
    func testFullRecomposite10Layer4K() throws {
        let image = try fixture().image
        let device = try fixture().device
        let renderer = try MetalCanvasRenderer(device: device)
        let context = try makeContext(device)
        let fit = CanvasTransform.initial(
            imageSize: imageSize,
            viewSize: CGSize(width: Double(targetSize.width) / 2,
                             height: Double(targetSize.height) / 2),
            backingScale: 2)
        var frameTimes: [Double] = []
        measure(metrics: [XCTClockMetric()],
                options: { let o = XCTMeasureOptions(); o.iterationCount = 3; return o }()) {
            let start = ContinuousClock.now
            renderer.invalidateAll()
            try! renderOnce(renderer, image: image, transform: fit, context: context)
            frameTimes.append(start.duration(to: .now).seconds * 1000)
        }
        let average = frameTimes.reduce(0, +) / Double(frameTimes.count)
        print("spec 0024 full recomposite 10-layer 4K (fit): average \(average) ms, "
              + "worst \(frameTimes.max() ?? 0) ms")
        XCTAssertLessThan(average, 2000.0, "full recomposite past the 2 s gate")
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
