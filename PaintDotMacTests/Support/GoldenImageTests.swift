import Foundation
import Testing

@testable import PaintDotMac

/// `GoldenImage` (spec 0024 item 11): ±1 comparison, alpha-0 RGB handling, size-mismatch
/// safety, the record/refuse decision, and the exact PNG round trip.
struct GoldenImageTests {
    private func grid(_ color: ColorRGBA8) -> [ColorRGBA8] {
        Array(repeating: color, count: 6)
    }

    @Test func identicalPasses() {
        let comparison = GoldenImage.compare(grid(.white), to: grid(.white), width: 3, height: 2)
        #expect(comparison.passed)
        #expect(comparison.maxChannelDelta == 0)
        #expect(comparison.firstMismatches.isEmpty)
    }

    @Test func deltaOnePasses() {
        let expected = grid(.white)
        var actual = grid(.white)
        actual[4] = ColorRGBA8(red: 254, green: 255, blue: 255, alpha: 255)
        let comparison = GoldenImage.compare(actual, to: expected, width: 3, height: 2)
        #expect(comparison.passed)
        #expect(comparison.maxChannelDelta == 1)
    }

    @Test func deltaTwoFails() {
        let expected = grid(.white)
        var actual = grid(.white)
        actual[4] = ColorRGBA8(red: 253, green: 255, blue: 255, alpha: 255)   // (x, y) = (1, 1)
        let comparison = GoldenImage.compare(actual, to: expected, width: 3, height: 2)
        #expect(!comparison.passed)
        #expect(comparison.mismatchCount == 1)
        let first = comparison.firstMismatches.first
        #expect(first?.x == 1)
        #expect(first?.y == 1)
        #expect(first?.expected == ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255))
        #expect(first?.actual == ColorRGBA8(red: 253, green: 255, blue: 255, alpha: 255))
    }

    @Test func alphaZeroRGBIgnored() {
        let expected = grid(ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0))
        let actual = grid(ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 0))
        #expect(GoldenImage.compare(actual, to: expected, width: 3, height: 2).passed)
        #expect(GoldenImage.compare(actual, to: expected, width: 3, height: 2,
                                    ignoreRGBWhereAlphaZero: false).passed == false)
        // Only one side transparent → RGB still compared.
        let half = grid(ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 1))
        #expect(GoldenImage.compare(actual, to: half, width: 3, height: 2).passed == false)
    }

    @Test func sizeMismatchFails() {
        let comparison = GoldenImage.compare(grid(.white), to: grid(.white) + [white()],
                                             width: 3, height: 2)
        #expect(comparison.passed == false)
    }

    private func white() -> ColorRGBA8 { .white }

    @Test func recordDecisionRefusesWhenOracleDisagrees() {
        let oracle = grid(.white)
        var actual = grid(.white)
        actual[0] = ColorRGBA8(red: 250, green: 255, blue: 255, alpha: 255)
        #expect(GoldenImage.recordDecision(actual: actual, oracle: oracle, width: 3, height: 2,
                                           tolerance: 1)
                == .refuse(maxChannelDelta: 5, mismatchCount: 1))
    }

    @Test func recordDecisionWritesWhenOracleAgrees() {
        #expect(GoldenImage.recordDecision(actual: grid(.white), oracle: grid(.white),
                                           width: 3, height: 2, tolerance: 1) == .write)
    }

    /// Write → decode with the same writer `assertGolden` uses: straight alpha is
    /// preserved bit-for-bit, including color under alpha 0 (FMT-B, NF-9).
    @Test func pngRoundTripIsExact() throws {
        let pixels = [
            ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 10),
            ColorRGBA8(red: 10, green: 20, blue: 30, alpha: 0),
            ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255),
            .clear,
            ColorRGBA8(red: 7, green: 123, blue: 200, alpha: 254),
            ColorRGBA8(red: 128, green: 128, blue: 128, alpha: 128),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoldenImageRoundTrip.\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try GoldenImage.writePNG(pixels, width: 3, height: 2, to: url)
        let read = try GoldenImage.readPNG(url)
        #expect(read.width == 3)
        #expect(read.height == 2)
        #expect(read.pixels == pixels)
    }
}
