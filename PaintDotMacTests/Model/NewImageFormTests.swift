import Foundation
import Testing
@testable import PaintDotMac

/// Validation rules from spec 0005 *Scope* (order width → height → resolution → limits,
/// ASCII digits, one locale-aware decimal separator, APP-10 limits) with the exact alert
/// messages. Expected values by hand, never from the code under test.
struct NewImageFormTests {
    /// 1 MB cap: 500×500×4 = 1,000,000 bytes fits exactly (0002's cap is inclusive).
    private let cap1M = ImageLimits(memoryCapBytes: 1_000_000)
    private let enUS = Locale(identifier: "en_US")

    private func form(_ width: String, _ height: String, _ resolution: String) -> NewImageForm {
        var form = NewImageForm(request: NewImageRequest(size: PixelSize(width: 800, height: 600), dpi: 96))
        form.widthText = width
        form.heightText = height
        form.resolutionText = resolution
        return form
    }

    @Test func validDefaults() throws {
        let request = try #require(form("800", "600", "96").validate(limits: .standard).success)
        #expect(request == NewImageRequest(size: PixelSize(width: 800, height: 600), dpi: 96))
        let trimmed = try #require(form(" 800 ", " 600 ", " 96 ").validate(limits: .standard).success)
        #expect(trimmed == NewImageRequest(size: PixelSize(width: 800, height: 600), dpi: 96))
    }

    // MARK: - Width and height

    /// "99999999999999999999999" is digits-only but overflows `Int` — the conversion must
    /// fail cleanly, never trap.
    private static let rejectedTexts: [String] = ["", "0", "65536", "-5", "12.5", "abc", "1,024", "1e3",
                                                  "99999999999999999999999"]

    @Test(arguments: rejectedTexts) func widthInvalid(_ text: String) {
        #expect(form(text, "600", "96").validate(limits: .standard)
                == .failure(.invalidWidth), "width \"\(text)\" must be refused")
    }

    @Test(arguments: NewImageFormTests.rejectedTexts) func heightInvalid(_ text: String) {
        #expect(form("800", text, "96").validate(limits: .standard)
                == .failure(.invalidHeight), "height \"\(text)\" must be refused")
    }

    @Test func widthCheckedBeforeHeight() {
        #expect(form("0", "0", "96").validate(limits: .standard) == .failure(.invalidWidth))
    }

    // MARK: - Resolution

    @Test(arguments: ["1", "72", "300.5", "10000"]) func resolutionValid(_ text: String) throws {
        let expectedDPI = try #require(Double(text))
        let request = try #require(form("8", "6", text).validate(limits: .standard).success)
        #expect(request.dpi == expectedDPI)
    }

    @Test(arguments: ["0", "0.5", "10000.01", "abc", "", "nan", "inf"]) func resolutionInvalid(_ text: String) {
        #expect(form("800", "600", text).validate(limits: .standard)
                == .failure(.invalidResolution), "resolution \"\(text)\" must be refused")
    }

    @Test func resolutionLocaleSeparator() {
        // "72,5" is a decimal comma: accepted under de_DE, refused under en_US.
        let german = form("800", "600", "72,5").validate(limits: .standard, locale: Locale(identifier: "de_DE"))
        #expect(german == .success(NewImageRequest(size: PixelSize(width: 800, height: 600), dpi: 72.5)))
        #expect(form("800", "600", "72,5").validate(limits: .standard, locale: enUS)
                == .failure(.invalidResolution))
    }

    // MARK: - Limits (0002's rule, injected)

    @Test func memoryCap() throws {
        // 500 × 500 × 4 == 1,000,000 == the cap: allowed (0002's cap is inclusive).
        let exact = try #require(form("500", "500", "96").validate(limits: cap1M).success)
        #expect(exact.size == PixelSize(width: 500, height: 500))
        #expect(form("501", "500", "96").validate(limits: cap1M)
                == .failure(.tooLarge(width: 501, height: 500)))
    }

    @Test func extremeSideAccepted() throws {
        // 65,535 × 1 is 262 KB — legal under the app's standard limits (APP-10).
        let request = try #require(form("65535", "1", "96").validate(limits: .standard).success)
        #expect(request.size == PixelSize(width: 65_535, height: 1))
    }

    @Test func resolutionCheckedBeforeLimits() {
        // An over-cap size with a bad resolution reports the resolution.
        #expect(form("501", "500", "0").validate(limits: cap1M) == .failure(.invalidResolution))
    }

    // MARK: - Messages (exact, spec *Scope*)

    @Test func messagesExact() {
        #expect(NewImageValidationError.invalidWidth.message
                == "Width must be a whole number from 1 to 65,535 pixels.")
        #expect(NewImageValidationError.invalidHeight.message
                == "Height must be a whole number from 1 to 65,535 pixels.")
        #expect(NewImageValidationError.invalidResolution.message
                == "Resolution must be a number from 1 to 10,000 pixels/inch.")
        #expect(NewImageValidationError.tooLarge(width: 65535, height: 65535).message
                == "The image is too large. An image of 65,535 \u{00D7} 65,535 pixels needs more memory than PaintDotMac allows.")
        #expect(NewImageValidationError.tooLarge(width: 501, height: 500).message
                == "The image is too large. An image of 501 \u{00D7} 500 pixels needs more memory than PaintDotMac allows.")
    }
}
