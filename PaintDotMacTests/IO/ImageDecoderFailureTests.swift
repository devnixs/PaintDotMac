import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PaintDotMac

private let unlimited = ImageLimits(memoryCapBytes: .max)

/// Every malformed input produces the specified error — never a trap.
struct ImageDecoderFailureTests {
    private var patternPNG: Data {
        TestImages.encode(
            TestImages.cgImage(width: 64, height: 64,
                               bytes: TestImages.rgbaBytes(width: 64, height: 64) { x, y in
                                   ColorRGBA8(red: UInt8(truncatingIfNeeded: x &* 3),
                                              green: UInt8(truncatingIfNeeded: y &* 5),
                                              blue: UInt8(truncatingIfNeeded: (x ^ y) &* 7),
                                              alpha: 255)
                               }),
            as: .png)
    }

    @Test func emptyData() {
        #expect(throws: ImageCodecError.unrecognizedFormat) { try ImageDecoder.decode(Data(), limits: unlimited) }
    }

    @Test func randomBytes() {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0xDA7A_0001))
        var bytes = Data("JUNK".utf8)
        for _ in 0..<996 { bytes.append(rng.byte()) }
        #expect(throws: ImageCodecError.unrecognizedFormat) {
            try ImageDecoder.decode(bytes, limits: unlimited)
        }
    }

    @Test func textFile() {
        #expect(throws: ImageCodecError.unrecognizedFormat) {
            try ImageDecoder.decode(Data("hello".utf8), limits: unlimited)
        }
    }

    @Test func headerOnlyPNG() {
        #expect(throws: ImageCodecError.corrupt) {
            try ImageDecoder.decode(TestImages.pngHeaderOnly(width: 10, height: 10), limits: unlimited)
        }
    }

    @Test func truncatedPNG() {
        let data = patternPNG
        #expect(throws: ImageCodecError.corrupt) {
            try ImageDecoder.decode(data.prefix(data.count / 2), limits: unlimited)
        }
    }

    @Test func pngWithoutIEND() {
        let data = patternPNG
        #expect(throws: ImageCodecError.corrupt) {
            try ImageDecoder.decode(data.dropLast(12), limits: unlimited)
        }
    }

    @Test func damagedIDAT() {
        var bytes = [UInt8](patternPNG)
        for index in 60..<200 { bytes[index] = 0xAA }
        #expect(throws: ImageCodecError.corrupt) {
            try ImageDecoder.decode(Data(bytes), limits: unlimited)
        }
    }

    @Test(arguments: [0.95, 0.5, 0.2])
    func truncatedBaselineJPEG(fraction: Double) throws {
        let data = TestImages.encode(
            TestImages.cgImage(width: 300, height: 200,
                               bytes: TestImages.rgbaBytes(width: 300, height: 200) { x, y in
                                   ColorRGBA8(red: UInt8(truncatingIfNeeded: x &* 3 &+ y),
                                              green: UInt8(truncatingIfNeeded: y &* 7),
                                              blue: UInt8(truncatingIfNeeded: x &* y),
                                              alpha: 255)
                               }),
            as: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
        let cut = data.prefix(Int(Double(data.count) * fraction))
        #expect(throws: ImageCodecError.corrupt) {
            try ImageDecoder.decode(cut, limits: unlimited)
        }
    }

    @Test func truncatedProgressiveJPEG() throws {
        let data = TestImages.encode(
            TestImages.cgImage(width: 300, height: 200,
                               bytes: TestImages.rgbaBytes(width: 300, height: 200) { x, y in
                                   ColorRGBA8(red: UInt8(truncatingIfNeeded: x &* y),
                                              green: UInt8(truncatingIfNeeded: x &- y),
                                              blue: UInt8(truncatingIfNeeded: x &+ y &* 3),
                                              alpha: 255)
                               }),
            as: .jpeg,
            properties: [kCGImagePropertyJFIFIsProgressive: true,
                         kCGImageDestinationLossyCompressionQuality: 0.9])
        let cut = data.prefix(data.count / 2)
        #expect(throws: ImageCodecError.corrupt) {
            try ImageDecoder.decode(cut, limits: unlimited)
        }
    }

    @Test func oversizedHeaderIsRefusedBeforeDecoding() {
        // Limits are checked before integrity: the header reads 70,000 px.
        #expect(throws: ImageCodecError.limitExceeded(.dimensionsOutOfRange(width: 70_000, height: 1))) {
            try ImageDecoder.decode(TestImages.pngHeaderOnly(width: 70_000, height: 1), limits: unlimited)
        }
    }

    @Test func hugeHeaderAgainstCap() {
        #expect(throws: ImageCodecError.limitExceeded(
            .exceedsMemoryCap(requiredBytes: 17_179_344_900, capBytes: 1_073_741_824))) {
            try ImageDecoder.decode(
                TestImages.pngHeaderOnly(width: 65_535, height: 65_535),
                limits: ImageLimits(memoryCapBytes: 1 << 30))
        }
    }

    @Test func memoryCapIsEnforced() throws {
        let data = TestImages.encode(
            TestImages.cgImage(width: 16, height: 16,
                               bytes: [UInt8](repeating: 0x40, count: 16 * 16 * 4)),
            as: .png)
        #expect(throws: ImageCodecError.limitExceeded(
            .exceedsMemoryCap(requiredBytes: 1_024, capBytes: 1_023))) {
            try ImageDecoder.decode(data, limits: ImageLimits(memoryCapBytes: 1_023))
        }
        // Exactly at the cap decodes.
        let decoded = try ImageDecoder.decode(data, limits: ImageLimits(memoryCapBytes: 1_024))
        #expect(decoded.surface.size == PixelSize(width: 16, height: 16))
    }

    @Test func pngWithTrailingBytes() throws {
        let data = patternPNG + Data(repeating: 0x55, count: 100)
        let decoded = try ImageDecoder.decode(data, limits: unlimited)
        let plain = try ImageDecoder.decode(patternPNG, limits: unlimited)
        #expect(decoded.surface == plain.surface)
    }
}
