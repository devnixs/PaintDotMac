import Foundation
import Testing

@testable import PaintDotMac

struct ImageCodecErrorTests {
    @Test func messages() throws {
        let unsupported = ImageCodecError.unrecognizedFormat
        #expect(unsupported.errorDescription == "The file isn\u{2019}t a supported image.")
        #expect(unsupported.recoverySuggestion == nil)

        let corrupt = ImageCodecError.corrupt
        #expect(corrupt.errorDescription == "The image is damaged or incomplete.")
        #expect(corrupt.recoverySuggestion == "The file may be truncated or corrupted.")

        let tooWide = ImageCodecError.limitExceeded(.dimensionsOutOfRange(width: 70_000, height: 1))
        #expect(tooWide.errorDescription == "The image is too large.")
        #expect(tooWide.recoverySuggestion
                == "Images can be up to 65,535 \u{00D7} 65,535 pixels. This one is 70,000 \u{00D7} 1 pixels.")

        let noPixels = ImageCodecError.limitExceeded(.dimensionsOutOfRange(width: 0, height: 5))
        #expect(noPixels.errorDescription == "The image has no pixels.")
        #expect(noPixels.recoverySuggestion == nil)

        let overflow = ImageCodecError.limitExceeded(.byteCountOverflow(width: Int.max, height: 2))
        #expect(overflow.errorDescription == "The image is too large.")
        #expect(overflow.recoverySuggestion?.contains("can\u{2019}t be held in memory") == true)

        let capped = ImageCodecError.limitExceeded(
            .exceedsMemoryCap(requiredBytes: 17_179_344_900, capBytes: 1_073_741_824))
        #expect(capped.errorDescription == "The image is too large.")
        let suggestion = try #require(capped.recoverySuggestion)
        #expect(suggestion.hasPrefix("Opening it needs "))
        #expect(suggestion.contains(", but the limit is "))
        #expect(suggestion.hasSuffix("."))

        // Numbers keep thousands separators regardless of the machine's region settings.
        #expect(tooWide.recoverySuggestion?.contains("65,535") == true)
    }
}
