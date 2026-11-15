import CoreGraphics
import Foundation
import ImageIO

/// Everything File > New… needs that isn't UI (spec 0005; PRD APP-9, APP-10, D-10, D-30):
/// the validated request, the dialog's defaults from the clipboard, and the form's text
/// validation.
struct NewImageRequest: Equatable, Sendable {
    var size: PixelSize
    var dpi: Double

    /// One layer named "Background", visible, opacity 255, blend mode `.normal`, every pixel
    /// (255, 255, 255, 255); `activeLayerIndex` 0; `image.dpi = dpi` (PRD APP-9 — Paint.NET's
    /// single white layer). `TiledSurface.fill` shares one copy-on-write white tile across
    /// fully covered tiles, so a new 800×600 image allocates one tile, not eight.
    func makeImage() -> LayeredImage {
        LayeredImage.blank(size: size, dpi: dpi, fill: .white,
                           layerName: NewImageDefaults.backgroundLayerName)
    }
}

enum NewImageDefaults {
    /// Paint.NET's New dialog default (paint.net/doc/latest/FileMenu.html).
    static let fallbackSize = PixelSize(width: 800, height: 600)
    /// Paint.NET's default resolution (APP-5).
    static let fallbackDPI: Double = 96
    static let backgroundLayerName = LayeredImage.defaultLayerName
    /// PRD APP-9 / D-30: 1–10,000 DPI, decimals allowed.
    static let dpiRange: ClosedRange<Double> = 1...10_000

    /// The dialog's opening values: the clipboard image's size when each side is a legal
    /// image side, else 800×600. Resolution is always 96 — the clipboard image's DPI is
    /// ignored (PRD APP-9, D-30).
    static func initialRequest(clipboardImageSize size: (width: Int, height: Int)?) -> NewImageRequest {
        if let size,
           (ImageLimits.minimumSide...ImageLimits.maximumSide).contains(size.width),
           (ImageLimits.minimumSide...ImageLimits.maximumSide).contains(size.height) {
            return NewImageRequest(size: PixelSize(width: size.width, height: size.height),
                                   dpi: fallbackDPI)
        }
        return NewImageRequest(size: fallbackSize, dpi: fallbackDPI)
    }

    /// The clipboard PNG's pixel size, else the TIFF's, else `nil`. Reads only the image
    /// header through `CGImageSource` (`kCGImageSourceShouldCache: false`), never the pixels,
    /// so a huge clipboard image costs microseconds. Unreadable data → try the next type.
    static func clipboardImageSize(pngData: Data?, tiffData: Data?) -> (width: Int, height: Int)? {
        if let pngData, let size = headerSize(pngData) { return size }
        if let tiffData, let size = headerSize(tiffData) { return size }
        return nil
    }

    private static func headerSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache as String: false] as CFDictionary
        ), CGImageSourceGetType(source) != nil,
           let cfProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil),
           let properties = cfProperties as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           width >= 1, height >= 1
        else { return nil }
        return (width, height)
    }
}

/// The New Image dialog's three text fields. Validation lives here (the SwiftUI view holds
/// none); the rules are width → height → resolution → limits, first failure reported.
struct NewImageForm: Equatable, Sendable {
    var widthText: String
    var heightText: String
    var resolutionText: String

    init(request: NewImageRequest) {
        widthText = String(request.size.width)
        heightText = String(request.size.height)
        resolutionText = Self.dpiText(request.dpi)
    }

    /// "96" and "72.5" — whole numbers print without a trailing ".0".
    static func dpiText(_ dpi: Double) -> String {
        if dpi.isFinite, dpi == dpi.rounded(), abs(dpi) < 1e15 { return String(Int(dpi)) }
        return String(dpi)
    }

    func validate(limits: ImageLimits, locale: Locale = .current) -> Result<NewImageRequest, NewImageValidationError> {
        guard let width = wholeNumber(widthText) else { return .failure(.invalidWidth) }
        guard let height = wholeNumber(heightText) else { return .failure(.invalidHeight) }
        guard let dpi = resolution(locale: locale) else { return .failure(.invalidResolution) }
        do {
            // 0002's rule, unchanged (APP-10): dimensions, overflow, memory cap.
            try limits.validate(width: width, height: height)
        } catch {
            return .failure(.tooLarge(width: width, height: height))
        }
        return .success(NewImageRequest(size: PixelSize(width: width, height: height), dpi: dpi))
    }

    /// Trimmed ASCII digits only — no sign, no decimal point, no grouping separator — whose
    /// value is a legal image side. Overflowing digit strings fail the `Int` conversion.
    private func wholeNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(trimmed),
              (ImageLimits.minimumSide...ImageLimits.maximumSide).contains(value)
        else { return nil }
        return value
    }

    /// Digits with at most one decimal separator — "." or the locale's — parsed to a finite
    /// `Double` in `NewImageDefaults.dpiRange`.
    private func resolution(locale: Locale) -> Double? {
        let trimmed = resolutionText.trimmingCharacters(in: .whitespaces)
        let localeSeparator = (locale as NSLocale).decimalSeparator
        var normalized = ""
        var sawSeparator = false
        for character in trimmed {
            if character.isASCII, character.isNumber {
                normalized.append(character)
                continue
            }
            let text = String(character)
            guard !sawSeparator, text == "." || text == localeSeparator else { return nil }
            sawSeparator = true
            normalized.append(".")
        }
        guard !normalized.isEmpty, normalized != ".",
              let value = Double(normalized), value.isFinite,
              NewImageDefaults.dpiRange.contains(value)
        else { return nil }
        return value
    }
}

/// Why the New Image dialog rejected the typed values (the alert's message text).
enum NewImageValidationError: Error, Equatable, Sendable {
    case invalidWidth
    case invalidHeight
    case invalidResolution
    /// `ImageLimits` refused the size (memory cap or width × height × 4 overflow).
    case tooLarge(width: Int, height: Int)

    var message: String {
        let minimumSide = ValueFormatting.decimal(ImageLimits.minimumSide)
        let maximumSide = ValueFormatting.decimal(ImageLimits.maximumSide)
        switch self {
        case .invalidWidth:
            return "Width must be a whole number from \(minimumSide) to \(maximumSide) pixels."
        case .invalidHeight:
            return "Height must be a whole number from \(minimumSide) to \(maximumSide) pixels."
        case .invalidResolution:
            return "Resolution must be a number from \(ValueFormatting.decimal(Int(NewImageDefaults.dpiRange.lowerBound))) "
                + "to \(ValueFormatting.decimal(Int(NewImageDefaults.dpiRange.upperBound))) pixels/inch."
        case .tooLarge(let width, let height):
            // 0002's limit-alert first sentence, then the size that was refused.
            return "The image is too large. An image of \(ValueFormatting.decimal(width)) \u{00D7} "
                + "\(ValueFormatting.decimal(height)) pixels needs more memory than PaintDotMac allows."
        }
    }
}
