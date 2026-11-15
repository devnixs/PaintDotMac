import Foundation
import Testing

@testable import PaintDotMac

/// Deterministic SplitMix64 generator for property tests (spec 0002 *Test support*). Every
/// property test uses a fixed default seed (runs stay reproducible), calls
/// `resolvedSeed(default:)`, and includes `comment` in each `#expect` so a failure prints
/// the seed. `xcodebuild` passes an override as `TEST_RUNNER_PAINTDOTMAC_TEST_SEED=…`.
struct SeededRandom: RandomNumberGenerator, Sendable {
    let seed: UInt64
    private var state: UInt64

    init(seed: UInt64) {
        self.seed = seed
        state = seed
    }

    /// SplitMix64, exactly as documented in the spec.
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    var comment: Comment {
        let hex = String(seed, radix: 16, uppercase: true)
        return "seed=0x\(hex) — rerun with PAINTDOTMAC_TEST_SEED=0x\(hex)"
    }

    /// `"42" → 42`, `"0x2A" → 42`, garbage and `nil` → nil.
    static func parseSeed(_ text: String?) -> UInt64? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        if text.lowercased().hasPrefix("0x") {
            return UInt64(text.dropFirst(2), radix: 16)
        }
        return UInt64(text)
    }

    static func resolvedSeed(default seed: UInt64) -> UInt64 {
        let environment = ProcessInfo.processInfo.environment
        let override = environment["PAINTDOTMAC_TEST_SEED"]
            ?? environment["TEST_RUNNER_PAINTDOTMAC_TEST_SEED"]
        return parseSeed(override) ?? seed
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        let count = range.upperBound - range.lowerBound + 1
        precondition(count > 0, "empty range \(range)")
        return range.lowerBound + Int(next() % UInt64(count))
    }

    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }

    mutating func color() -> ColorRGBA8 {
        ColorRGBA8(red: byte(), green: byte(), blue: byte(), alpha: byte())
    }

    /// A random rect that may extend past `size` on any side (for clipping tests), with
    /// width and height 0…`maxSide`.
    mutating func rect(around size: PixelSize, maxSide: Int) -> PixelRect {
        PixelRect(
            x: int(in: -maxSide...size.width),
            y: int(in: -maxSide...size.height),
            width: int(in: 0...maxSide),
            height: int(in: 0...maxSide)
        )
    }
}
