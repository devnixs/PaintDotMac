import Foundation
import Metal
import XCTest
@testable import PaintDotMac

/// NF-2 performance (spec 0003): warm pan frames of a fitted 24 MP image must stay under
/// 16 ms per frame on the author's M-series Mac (the gate fails only past 48 ms, the 3×
/// gross-regression rule); the cold first frame is reported and fails only past 1 s
/// (NF-1's "open in under 1 s" budget). Measured numbers go into the spec's Verification
/// status. NF-2 impact statement: canvas redraws are upload-free once warm (tiles are
/// cached per mip base level) and on-demand (`isPaused`, no idle frames); the multi-layer
/// part of NF-2 is measured in 0024 and 0048.
@MainActor
final class CanvasRenderPerformanceTests: XCTestCase {
    private let imageSize = PixelSize(width: 6000, height: 4000)
    private let targetSize = (width: 2560, height: 1600)
    private let warmFrameMillisecondsLimit = 16.0
    private let grossRegressionMillisecondsLimit = 48.0
    private let coldFrameSecondsLimit = 1.0

    private func makeDevice() throws -> MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device on this Mac")
    }

    /// A seeded random opaque 24 MP image (the fixture is built once per test).
    private func make24MPImage() -> LayeredImage {
        var random = SeededRandom(seed: 0x50E2F24)
        var surface = TiledSurface(size: imageSize)
        // Fill tile by tile to keep the generator sequential; every tile allocated.
        for row in 0...((imageSize.height - 1) / TiledSurface.tileSize) {
            for column in 0...((imageSize.width - 1) / TiledSurface.tileSize) {
                var bytes = [UInt8](repeating: 0, count: Tile.byteCount)
                for tileY in 0..<TiledSurface.tileSize {
                    let y = row * TiledSurface.tileSize + tileY
                    guard y < imageSize.height else { break }
                    let usableWidth = min(TiledSurface.tileSize,
                                          imageSize.width - column * TiledSurface.tileSize)
                    for tileX in 0..<usableWidth {
                        let offset = (tileY * TiledSurface.tileSize + tileX) * 4
                        bytes[offset] = random.byte()
                        bytes[offset + 1] = random.byte()
                        bytes[offset + 2] = random.byte()
                        bytes[offset + 3] = 255
                    }
                }
                surface.setTile(Tile(bytes: bytes), at: TileCoordinate(column: column, row: row))
            }
        }
        return LayeredImage(surface: surface)
    }

    private func fittedTransform(viewSize: CGSize, scale: Double, centerX: Double) -> CanvasTransform {
        var transform = CanvasTransform.initial(imageSize: imageSize, viewSize: viewSize, backingScale: scale)
        transform.center = CGPoint(x: centerX, y: Double(imageSize.height) / 2)
        return transform
    }

    /// The per-frame render context. A real app creates the command queue once with the
    /// view and draws into the reused drawables; the harness likewise creates queue and
    /// target once per test so the measured frames only cover what the app does per frame.
    private func makeRenderContext(_ device: MTLDevice) throws -> (MTLCommandQueue, MTLTexture) {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: targetSize.width, height: targetSize.height, mipmapped: false)
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

    /// Cold: a fresh renderer, first frame including every upload. Reported only; fails only
    /// past the 1 s open budget.
    func testColdFrame24MP() throws {
        let device = try makeDevice()
        let image = make24MPImage()
        let viewSize = CGSize(width: targetSize.width, height: targetSize.height)
        let transform = fittedTransform(viewSize: viewSize, scale: 1,
                                        centerX: Double(imageSize.width) / 2)
        let context = try makeRenderContext(device)
        var worstSeconds = 0.0
        measure(metrics: [XCTClockMetric()]) {
            let renderer = try! MetalCanvasRenderer(device: device)
            let start = ContinuousClock.now
            try! renderOnce(renderer, image: image, transform: transform, context: context)
            worstSeconds = max(worstSeconds, start.duration(to: .now).seconds)
        }
        print("spec 0003 NF-2 cold frame 24 MP: worst \(Int(worstSeconds * 1000)) ms")
        XCTAssertLessThan(worstSeconds, coldFrameSecondsLimit,
                          "cold first frame exceeded the 1 s open budget")
    }

    /// Warm: after a warm-up frame, pan the center by 37 canvas px per frame (no uploads —
    /// the whole image is inside the visible set at fit zoom) and render. < 16 ms target,
    /// gate fails past 48 ms; every warm frame must upload nothing.
    func testWarmFrame24MP() throws {
        let device = try makeDevice()
        let image = make24MPImage()
        let viewSize = CGSize(width: targetSize.width, height: targetSize.height)
        let context = try makeRenderContext(device)
        let renderer = try MetalCanvasRenderer(device: device)
        var transform = fittedTransform(viewSize: viewSize, scale: 1, centerX: Double(imageSize.width) / 2)
        try renderOnce(renderer, image: image, transform: transform, context: context)   // warm-up

        var frameTimes: [Double] = []
        measure(metrics: [XCTClockMetric()]) {
            let start = ContinuousClock.now
            transform.center.x += 37
            try! renderOnce(renderer, image: image, transform: transform, context: context)
            XCTAssertEqual(renderer.statistics.tilesUploadedLastFrame, 0,
                           "warm pan frames must not upload tiles")
            frameTimes.append(start.duration(to: .now).seconds * 1000)
        }
        let average = frameTimes.reduce(0, +) / Double(frameTimes.count)
        print("spec 0003 NF-2 warm pan frame 24 MP: average \(average) ms over \(frameTimes.count) frames")
        XCTAssertLessThan(average, grossRegressionMillisecondsLimit,
                          "warm pan frame regressed past the 3× limit")
        // The NF-2 target itself: the median warm frame under 16 ms (60 fps).
        let sorted = frameTimes.sorted()
        let median = sorted[sorted.count / 2]
        XCTAssertLessThan(median, warmFrameMillisecondsLimit,
                          "warm pan frame missed the 16 ms / 60 fps NF-2 target (median \(median) ms)")
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
