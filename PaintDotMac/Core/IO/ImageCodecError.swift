import Foundation

/// Why an image could not be decoded (spec 0002). `errorDescription` and
/// `recoverySuggestion` are the alert text `NSDocumentController` presents on a failed open.
enum ImageCodecError: Error, Equatable, Sendable, LocalizedError {
    /// ImageIO can't identify the data, or it holds no image.
    case unrecognizedFormat
    /// Damaged, truncated, or undecodable.
    case corrupt
    /// APP-10: the size was refused.
    case limitExceeded(ImageLimitError)
    /// 0005: the document's format can't be written yet (JPEG until 0029).
    case unsupportedWriteFormat(FileFormat)
    /// 0005: the encoder or ImageIO refused to produce the file.
    case encodingFailed
    /// 0024 (interim rule 5): a document with more than one layer can't be written to
    /// PNG until 0029 adds FMT-A's flatten-on-export confirmation. 0029 removes this case.
    case layeredImageNeedsFlatten

    var errorDescription: String? {
        switch self {
        case .unrecognizedFormat: "The file isn\u{2019}t a supported image."
        case .corrupt: "The image is damaged or incomplete."
        case .unsupportedWriteFormat(let format):
            "PaintDotMac can\u{2019}t save images in the \(format.displayName) format yet."
        case .encodingFailed: "The image couldn\u{2019}t be saved."
        case .layeredImageNeedsFlatten: "This image has more than one layer."
        case .limitExceeded(.dimensionsOutOfRange(let width, let height)) where width < 1 || height < 1:
            "The image has no pixels."
        default:
            "The image is too large."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unrecognizedFormat:
            return nil
        case .corrupt:
            return "The file may be truncated or corrupted."
        case .limitExceeded(.dimensionsOutOfRange(let width, let height)):
            guard width >= 1, height >= 1 else { return nil }
            let maximum = Self.decimal(ImageLimits.maximumSide)
            return "Images can be up to \(maximum) \u{00D7} \(maximum) pixels. "
                + "This one is \(Self.decimal(width)) \u{00D7} \(Self.decimal(height)) pixels."
        case .limitExceeded(.byteCountOverflow(let width, let height)):
            return "An image of \(Self.decimal(width)) \u{00D7} \(Self.decimal(height)) pixels "
                + "can\u{2019}t be held in memory."
        case .limitExceeded(.exceedsMemoryCap(let requiredBytes, let capBytes)):
            return "Opening it needs \(Self.byteCount(requiredBytes)) of memory, "
                + "but the limit is \(Self.byteCount(capBytes))."
        case .unsupportedWriteFormat, .encodingFailed:
            return nil
        case .layeredImageNeedsFlatten:
            return "Choose Image > Flatten, then save again. Saving layered images arrives "
                + "with OpenRaster (.ora) support."
        }
    }

    private static func decimal(_ value: Int) -> String { ValueFormatting.decimal(value) }

    private static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
