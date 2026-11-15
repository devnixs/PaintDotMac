import Metal
import Testing
@testable import PaintDotMac

/// Offscreen Metal rendering helpers for the canvas tests: real device, `.bgra8Unorm`
/// managed/shared target, readback, and pixel comparison. GPU tests **fail** — never skip —
/// when Metal is missing (the quality gate forbids skipped tests).
enum MetalTestTarget {
    static func makeDevice() throws -> MTLDevice {
        try #require(
            MTLCreateSystemDefaultDevice(),
            "no Metal device on this Mac — the canvas requires Metal (CAN-6)"
        )
    }

    static func makeCommandQueue(_ device: MTLDevice) throws -> MTLCommandQueue {
        try #require(device.makeCommandQueue(), "could not create a command queue")
    }

    /// `.bgra8Unorm` render target. `.managed` only exists on Intel Macs; on Apple Silicon
    /// (unified memory) the equivalent for CPU readback is `.shared`.
    static func makeTarget(_ device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: max(1, width), height: max(1, height), mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        return try #require(device.makeTexture(descriptor: descriptor), "could not create a target texture")
    }

    /// Encode one frame into a fresh target, wait, and read back `width × height` RGBA
    /// device pixels, row-major, y counting from the top.
    @MainActor
    static func render(_ frame: CanvasFrame, with renderer: MetalCanvasRenderer,
                       device: MTLDevice, width: Int, height: Int) throws -> [ColorRGBA8] {
        let queue = try makeCommandQueue(device)
        let target = try makeTarget(device, width: width, height: height)
        let commandBuffer = try #require(queue.makeCommandBuffer(), "could not create a command buffer")
        renderer.encode(frame, to: target, in: commandBuffer)
        if !device.hasUnifiedMemory, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        target.getBytes(
            &bytes, bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
        )
        return (0..<(width * height)).map { index in
            ColorRGBA8(
                red: bytes[index * 4 + 2], green: bytes[index * 4 + 1],
                blue: bytes[index * 4], alpha: bytes[index * 4 + 3]
            )
        }
    }

    /// Compares two device buffers of `width × height` pixels (row-major, top-down).
    /// Reports the mismatch count plus the first mismatches with their device coordinates
    /// and channel, through `TestImages.expectColor` (the per-pixel check).
    static func assertPixelsMatch(_ actual: [ColorRGBA8],
                                  match expected: [ColorRGBA8],
                                  width: Int, height: Int,
                                  tolerance: Int = 1,
                                  _ comment: Comment? = nil,
                                  sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.count == expected.count,
                "buffer length \(actual.count) != \(expected.count)\(suffix(comment))",
                sourceLocation: sourceLocation)
        guard actual.count == expected.count else { return }
        var mismatchCount = 0
        var samples: [(Int, Int)] = []
        for index in actual.indices {
            if !withinTolerance(actual[index], expected[index], tolerance) {
                mismatchCount += 1
                if samples.count < 10 {
                    samples.append((index % width, index / width))
                }
            }
        }
        guard mismatchCount > 0 else { return }
        for (x, y) in samples {
            TestImages.expectColor(
                actual[y * width + x], expected[y * width + x], tolerance: tolerance,
                "device pixel (\(x), \(y)) of \(width)×\(height); \(mismatchCount) mismatches total\(suffix(comment))",
                sourceLocation: sourceLocation
            )
        }
    }

    private static func suffix(_ comment: Comment?) -> String {
        comment.map { " — \($0)" } ?? ""
    }

    private static func withinTolerance(_ actual: ColorRGBA8, _ expected: ColorRGBA8, _ tolerance: Int) -> Bool {
        abs(Int(actual.red) - Int(expected.red)) <= tolerance
            && abs(Int(actual.green) - Int(expected.green)) <= tolerance
            && abs(Int(actual.blue) - Int(expected.blue)) <= tolerance
            && abs(Int(actual.alpha) - Int(expected.alpha)) <= tolerance
    }
}
