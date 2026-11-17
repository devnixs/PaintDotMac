import Foundation
import Testing

@testable import PaintDotMac

/// The shared golden-image helper for 0024, 0026, 0027, 0031+ (spec 0024 item 11).
///
/// The workflow is always **oracle first**: `assertGolden` compares the GPU output with
/// the CPU oracle (±tolerance) on every run; only then does it compare against (or
/// record) the checked-in PNG in `PaintDotMacTests/Golden/`. A recording run can never
/// pass — it records the PNG and fails with an instruction to rerun — and it refuses to
/// record while the oracle disagrees, so a golden file can only ever capture output the
/// CPU reference already approved. Goldens stay well under 1 MB (AGENTS.md) and are
/// located through `#filePath`, so no bundle resource is required.
struct GoldenComparison: Equatable, Sendable {
    /// Largest single-channel delta over the image (0 when identical).
    let maxChannelDelta: Int
    /// Pixels with any channel delta > tolerance.
    let mismatchCount: Int
    /// Up to 10 mismatches, row-major.
    let firstMismatches: [(x: Int, y: Int, expected: ColorRGBA8, actual: ColorRGBA8)]

    var passed: Bool { mismatchCount == 0 }

    /// Tuples never conform to `Equatable`, so the comparison is explicit.
    static func == (lhs: GoldenComparison, rhs: GoldenComparison) -> Bool {
        lhs.maxChannelDelta == rhs.maxChannelDelta
            && lhs.mismatchCount == rhs.mismatchCount
            && lhs.firstMismatches.count == rhs.firstMismatches.count
            && zip(lhs.firstMismatches, rhs.firstMismatches).allSatisfy {
                $0.x == $1.x && $0.y == $1.y && $0.expected == $1.expected && $0.actual == $1.actual
            }
    }
}

enum GoldenImage {
    /// PRD §4 / AGENTS.md: ±1 per channel tolerates GPU differences.
    static let defaultTolerance = 1

    /// `<repo>/PaintDotMacTests/Golden/` (AGENTS.md *Testing expectations*), located
    /// through `#filePath` (this file lives in `PaintDotMacTests/Support/`).
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Support/
            .deletingLastPathComponent()   // PaintDotMacTests/
            .appendingPathComponent("Golden", isDirectory: true)
    }

    /// Golden files are `<name>.png` (AGENTS.md): PNG data read by 0002's
    /// `ImageDecoder`, committed under 1 MB.
    static func url(for name: String) -> URL {
        directory.appendingPathComponent("\(name).png")
    }

    /// `RECORD_GOLDENS=1` (`TEST_RUNNER_RECORD_GOLDENS=1` for `xcodebuild test`).
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["RECORD_GOLDENS"] == "1"
    }

    enum RecordDecision: Equatable {
        case write
        case refuse(maxChannelDelta: Int, mismatchCount: Int)
    }

    // MARK: - Pure comparison

    /// Straight RGBA8 buffers of equal size. With `ignoreRGBWhereAlphaZero` (the golden
    /// default) pixels whose actual **and** expected alpha are 0 compare alpha only —
    /// color stored under alpha 0 is never displayed (NF-9). A count that doesn't match
    /// `width × height` fails without crashing.
    static func compare(_ actual: [ColorRGBA8], to expected: [ColorRGBA8], width: Int, height: Int,
                        tolerance: Int = defaultTolerance,
                        ignoreRGBWhereAlphaZero: Bool = true) -> GoldenComparison {
        let count = width * height
        guard actual.count == count, expected.count == count else {
            return GoldenComparison(
                maxChannelDelta: 255, mismatchCount: max(actual.count, expected.count),
                firstMismatches: [])
        }
        var maxDelta = 0
        var mismatchCount = 0
        var first: [(x: Int, y: Int, expected: ColorRGBA8, actual: ColorRGBA8)] = []
        for index in 0..<count {
            let a = actual[index]
            let e = expected[index]
            let alphaOnly = ignoreRGBWhereAlphaZero && a.alpha == 0 && e.alpha == 0
            var pixelMax = abs(Int(a.alpha) - Int(e.alpha))
            if !alphaOnly {
                pixelMax = max(pixelMax, abs(Int(a.red) - Int(e.red)),
                               abs(Int(a.green) - Int(e.green)), abs(Int(a.blue) - Int(e.blue)))
            }
            maxDelta = max(maxDelta, pixelMax)
            if pixelMax > tolerance {
                mismatchCount += 1
                if first.count < 10 {
                    first.append((x: index % width, y: index / width, expected: e, actual: a))
                }
            }
        }
        return GoldenComparison(maxChannelDelta: maxDelta, mismatchCount: mismatchCount,
                                firstMismatches: first)
    }

    /// Records an `Issue` (with the first mismatches) unless `compare` passes.
    static func expectMatch(_ actual: [ColorRGBA8], _ expected: [ColorRGBA8],
                            width: Int, height: Int, tolerance: Int = defaultTolerance,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        let comparison = compare(actual, to: expected, width: width, height: height,
                                 tolerance: tolerance)
        guard !comparison.passed else { return }
        Issue.record("""
            \(comparison.mismatchCount) pixel(s) differ beyond ±\(tolerance) \
            (max channel delta \(comparison.maxChannelDelta)); \
            first mismatches: \(comparison.firstMismatches.map { "(\($0.x), \($0.y)) expected \($0.expected) got \($0.actual)" })
            """, sourceLocation: sourceLocation)
    }

    /// Pure: record only when the oracle agrees with the actual output.
    static func recordDecision(actual: [ColorRGBA8], oracle: [ColorRGBA8], width: Int, height: Int,
                               tolerance: Int) -> RecordDecision {
        let comparison = compare(actual, to: oracle, width: width, height: height,
                                 tolerance: tolerance)
        return comparison.passed
            ? .write
            : .refuse(maxChannelDelta: comparison.maxChannelDelta,
                      mismatchCount: comparison.mismatchCount)
    }

    // MARK: - The golden workflow

    /// Always checks `actual` against `oracle` (±tolerance) first. Not recording: load
    /// `Golden/<name>.png` (missing → an `Issue` explaining how to record) and compare
    /// ±tolerance. Recording: refuse when the oracle check failed; otherwise write
    /// `actual` as PNG and record an `Issue` so a recording run never passes.
    static func assertGolden(_ actual: [ColorRGBA8], width: Int, height: Int, named name: String,
                             oracle: [ColorRGBA8], tolerance: Int = defaultTolerance,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        switch recordDecision(actual: actual, oracle: oracle, width: width, height: height,
                              tolerance: tolerance) {
        case .refuse(let maxDelta, let mismatches):
            Issue.record("""
                Golden \(name): the CPU oracle disagrees with the actual output \
                (\(mismatches) pixel(s) beyond ±\(tolerance), max delta \(maxDelta)); \
                nothing recorded.
                """, sourceLocation: sourceLocation)
            return
        case .write:
            break
        }
        if isRecording {
            do {
                try FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: true)
                try writePNG(actual, width: width, height: height, to: url(for: name))
            } catch {
                Issue.record("Could not write Golden/\(name): \(error)",
                             sourceLocation: sourceLocation)
                return
            }
            Issue.record("Recorded \(name) — rerun without RECORD_GOLDENS",
                         sourceLocation: sourceLocation)
            return
        }
        let url = url(for: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record("""
                Golden \(name) missing; record it with RECORD_GOLDENS=1 \
                (TEST_RUNNER_RECORD_GOLDENS=1 for xcodebuild) after the oracle check passes.
                """, sourceLocation: sourceLocation)
            return
        }
        guard let expected = try? readPNG(url) else {
            Issue.record("Golden \(name) could not be decoded", sourceLocation: sourceLocation)
            return
        }
        expectMatch(actual, expected.pixels, width: width, height: height,
                    tolerance: tolerance, sourceLocation: sourceLocation)
    }

    // MARK: - PNG I/O (straight alpha, sRGB — 0005's writer and 0002's reader, FMT-B)

    /// The writer `assertGolden` uses: 0005's `ImageEncoder` at the document DPI, no
    /// premultiplication, straight alpha preserved.
    static func writePNG(_ pixels: [ColorRGBA8], width: Int, height: Int, to url: URL) throws {
        let size = PixelSize(width: width, height: height)
        var bytes = [UInt8](repeating: 0, count: pixels.count * 4)
        for (index, color) in pixels.enumerated() {
            let offset = index * 4
            bytes[offset] = color.red
            bytes[offset + 1] = color.green
            bytes[offset + 2] = color.blue
            bytes[offset + 3] = color.alpha
        }
        let surface = bytes.withUnsafeBytes { buffer in
            TiledSurface(size: size, rgba8: buffer, bytesPerRow: width * 4)
        }
        let data = try ImageEncoder.encode(surface, size: size, dpi: LayeredImage.defaultDPI,
                                           as: .png)
        try data.write(to: url)
    }

    /// 0002's `ImageDecoder` — straight alpha preserved (FMT-B).
    static func readPNG(_ url: URL) throws -> (pixels: [ColorRGBA8], width: Int, height: Int) {
        let decoded = try ImageDecoder.decode(Data(contentsOf: url))
        let surface = decoded.surface
        let bytes = surface.readPixels(in: surface.bounds)
        var pixels = [ColorRGBA8](repeating: .clear, count: surface.size.width * surface.size.height)
        bytes.withUnsafeBytes { buffer in
            for index in pixels.indices {
                let offset = index * 4
                pixels[index] = ColorRGBA8(red: buffer[offset], green: buffer[offset + 1],
                                           blue: buffer[offset + 2], alpha: buffer[offset + 3])
            }
        }
        return (pixels, surface.size.width, surface.size.height)
    }
}
