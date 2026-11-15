import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import PaintDotMac

/// Performance guards for decoding (PRD §6 NF-2: opening a 24 MP JPEG is under 1 s; this
/// Debug test run gates at 3 s) and for the tiled surface's copy-on-write discipline
/// (NF-4: per-tile work, not per-pixel copying).
final class ImageDecoderPerformanceTests: XCTestCase {
    // Written once in `setUp` (before any test runs) and read-only afterwards.
    nonisolated(unsafe) private static var jpegData = Data()

    override class func setUp() {
        // A 6,000×4,000 gradient plus filled shapes: not trivially compressible.
        let width = 6_000, height = 4_000
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { fatalError("cannot allocate the fixture context") }  // 96 MB test fixture
        let colors = [CGColor(colorSpace: colorSpace, components: [0.2, 0.4, 0.8, 1.0])!,
                      CGColor(colorSpace: colorSpace, components: [0.9, 0.3, 0.2, 1.0])!]
        for x in 0..<width {
            context.setFillColor(colors[x % 2])
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        for index in 0..<200 {
            let color = CGColor(colorSpace: colorSpace, components: [
                CGFloat(index % 251) / 255, CGFloat((index * 7) % 253) / 255,
                CGFloat((index * 13) % 249) / 255, 1.0,
            ])!
            context.setFillColor(color)
            context.fill(CGRect(x: (index * 97) % (width - 400), y: (index * 173) % (height - 300),
                                width: 400, height: 300))
        }
        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(
                output, UTType.jpeg.identifier as CFString, 1, nil)
        else { fatalError("cannot build the fixture JPEG") }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { fatalError("cannot encode the fixture JPEG") }
        jpegData = output as Data
    }

    /// Stable measurement through `measure` (reported in the spec's Verification status).
    func testDecode24MegapixelJPEG() throws {
        let limits = ImageLimits(memoryCapBytes: .max)
        measure {
            do {
                let decoded = try ImageDecoder.decode(Self.jpegData, limits: limits)
                XCTAssertEqual(decoded.surface.size, PixelSize(width: 6_000, height: 4_000))
            } catch {
                XCTFail("decode failed: \(error)")
            }
        }
    }

    /// One timed decode against NF-2's 1 s open budget (×3 for the Debug test build).
    func testSingleDecodeUnderThreeSeconds() throws {
        let limits = ImageLimits(memoryCapBytes: .max)
        let clock = ContinuousClock()
        let duration = try clock.measure {
            _ = try ImageDecoder.decode(Self.jpegData, limits: limits)
        }
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        NSLog("PaintDotMacPerf: 24 MP JPEG decode took %.3f s", seconds)
        XCTAssertLessThan(seconds, 3.0, "one decode exceeded 3 s (NF-2 × 3, Debug)")
    }

    /// A full 4,000×3,000 write + read through `writePixels`/`readPixels`; a per-pixel
    /// tile-copy regression would push this into minutes.
    func testRegionWriteThroughput() throws {
        let width = 4_000, height = 3_000
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let base = (row * width + column) * 4
                buffer[base] = UInt8(truncatingIfNeeded: column &* 3)
                buffer[base + 1] = UInt8(truncatingIfNeeded: row &* 5)
                buffer[base + 2] = 99
                buffer[base + 3] = 255
            }
        }
        var surface = TiledSurface(size: PixelSize(width: width, height: height))
        let clock = ContinuousClock()
        let duration = clock.measure {
            surface.writePixels(buffer, to: PixelRect(x: 0, y: 0, width: width, height: height))
            let readBack = surface.readPixels(in: surface.bounds)
            XCTAssertEqual(readBack.count, buffer.count)
        }
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        NSLog("PaintDotMacPerf: region write+read throughput took %.3f s", seconds)
        XCTAssertLessThan(seconds, 1.5, "write/read of 48 MB exceeded the 1.5 s regression gate")
    }
}
