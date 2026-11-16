import XCTest

@testable import PaintDotMac

/// Spec 0012 *Performance*: `PixelSampler.sample` in Image mode on a 4000×3000 three-layer
/// image at the largest size (51×51) must composite only the sampled rect — the gated
/// target is a mean well under 5 ms per sample (a full-image composite would be three
/// orders of magnitude slower; the gate fails above 50 ms). `measure` tracks an Xcode
/// baseline. NF-1/NF-2 are unaffected: the CPU compositor is not on the display path.
final class ColorPickerPerformanceTests: XCTestCase {

    private static let seed: UInt64 = 0x0012_0012_0000_0051

    /// One 4000×3000 opaque noise buffer (a 512×512 seeded block tiled — deterministic),
    /// reused to build three fully allocated layers.
    private func threeLayerImage() -> LayeredImage {
        let width = 4000, height = 3000
        var rng = SeededRandom(seed: Self.seed)
        let blockSide = 512
        var block = [UInt8](repeating: 0, count: blockSide * blockSide * 4)
        for offset in stride(from: 0, to: block.count, by: 4) {
            block[offset] = rng.byte()
            block[offset + 1] = rng.byte()
            block[offset + 2] = rng.byte()
            block[offset + 3] = 255
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for row in 0..<height {
            var column = 0
            while column < width {
                let chunkWidth = min(blockSide, width - column)
                let rowStart = (row % blockSide) * blockSide * 4
                for x in 0..<chunkWidth {
                    let pixel = rowStart + x * 4
                    bytes.append(contentsOf: block[pixel..<pixel + 4])
                }
                column += chunkWidth
            }
        }
        func surface() -> TiledSurface {
            bytes.withUnsafeBytes { raw in
                TiledSurface(size: PixelSize(width: width, height: height),
                             rgba8: raw, bytesPerRow: width * 4)
            }
        }
        let size = PixelSize(width: width, height: height)
        let layers = [
            Layer(name: "A", surface: surface()),
            Layer(name: "B", surface: surface(), opacity: 128),
            Layer(name: "C", surface: surface()),
        ]
        return LayeredImage(size: size, layers: layers, activeLayerIndex: 2)
    }

    /// 400 seeded 51×51 Image-mode samples around the canvas middle; returns
    /// (mean, p95, max) milliseconds.
    private func sampleLatencyStats() -> (mean: Double, p95: Double, max: Double) {
        let image = threeLayerImage()
        var rng = SeededRandom(seed: Self.seed &+ 7)
        var timings: [Double] = []
        timings.reserveCapacity(400)
        for _ in 0..<400 {
            let point = PixelPoint(x: rng.int(in: 400...3500), y: rng.int(in: 400...2500))
            let start = DispatchTime.now().uptimeNanoseconds
            let color = PixelSampler.sample(image, at: point, size: .region51, mode: .image)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            XCTAssertNotNil(color, "the sample point is inside the canvas")
            timings.append(elapsed)
        }
        let sorted = timings.sorted()
        let mean = timings.reduce(0, +) / Double(timings.count)
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        return (mean, p95, sorted.last ?? 0)
    }

    func testImageSampleLatency() {
        let stats = sampleLatencyStats()
        print("ColorPickerPerformanceTests.testImageSampleLatency: mean "
              + String(format: "%.3f", stats.mean) + " ms, p95 "
              + String(format: "%.3f", stats.p95) + " ms, max "
              + String(format: "%.3f", stats.max) + " ms "
              + "(4000×3000, 3 fully allocated layers, Image mode, 51 x 51 region)")
        XCTAssertLessThanOrEqual(stats.mean, 5,
                                 "mean sample latency over the 5 ms gate — only the 51×51 "
                                 + "rect may be composited, never the whole image")
        XCTAssertLessThanOrEqual(stats.max, 50,
                                 "worst sample latency over the 50 ms hard gate")
    }

    /// Baseline block for Xcode's performance tracking (self-contained per iteration).
    func testMeasureImageSample() {
        let image = threeLayerImage()
        measure {
            for index in 0..<20 {
                let point = PixelPoint(x: 1000 + index * 37, y: 900 + index * 29)
                _ = PixelSampler.sample(image, at: point, size: .region51, mode: .image)
            }
        }
    }
}
