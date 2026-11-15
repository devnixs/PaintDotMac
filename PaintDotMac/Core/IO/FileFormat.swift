import Foundation
import UniformTypeIdentifiers

/// A document file format (spec 0005; PRD §5.11). 0028 adds `.openRaster`; 0029 adds HEIC,
/// TIFF, BMP, GIF, and WebP and makes `.jpeg` writable. `canWrite` is the single source for
/// whether ⌘S writes in place or the document goes through Save As….
enum FileFormat: String, CaseIterable, Sendable {
    case png
    case jpeg

    var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        }
    }

    var typeIdentifier: String { utType.identifier }

    var preferredFilenameExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }

    var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        }
    }

    var canRead: Bool {
        switch self {
        case .png, .jpeg: true
        }
    }

    var canWrite: Bool {
        switch self {
        case .png: true
        case .jpeg: false  // 0029 adds JPEG writing (F-3)
        }
    }

    /// Exact identifier first, then a `UTType` conforming to one case's type ("public.png"
    /// and e.g. "com.apple.png" → `.png`); anything else → `nil`.
    init?(typeIdentifier: String) {
        if let exact = Self.allCases.first(where: { $0.typeIdentifier == typeIdentifier }) {
            self = exact
            return
        }
        guard let type = UTType(typeIdentifier),
              let match = Self.allCases.first(where: { type.conforms(to: $0.utType) })
        else { return nil }
        self = match
    }

    /// Case-insensitive; "jpg", "jpeg", and "jpe" are the JPEG spellings PNG/JPEG documents
    /// use; any other extension (including "gif" and "") → `nil`.
    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg", "jpe": self = .jpeg
        default: return nil
        }
    }

    /// The formats the save panel offers, in declaration order.
    static var writableFormats: [FileFormat] { allCases.filter(\.canWrite) }

    /// New documents' format (interim rule 1; 0028 changes this to `.openRaster`, PRD D-6).
    static var defaultNewDocumentFormat: FileFormat { .png }

    /// The §5.11 "Saving" decision for a document: untitled → the save panel; a writable
    /// format → in place; a readable-but-unwritable format (JPEG until 0029) → Save As…
    /// offering only the writable formats, suggested `defaultNewDocumentFormat`.
    static func saveAction(for documentFormat: FileFormat?) -> SaveAction {
        guard let documentFormat else {
            return .saveAs(offering: writableFormats, suggested: defaultNewDocumentFormat)
        }
        if documentFormat.canWrite { return .writeInPlace(documentFormat) }
        return .saveAs(offering: writableFormats, suggested: defaultNewDocumentFormat)
    }

    /// The save panel's suggested name: only the last extension is replaced
    /// ("archive.tar.jpg" → "archive.tar.png", ".hidden" → ".hidden.png" because a leading
    /// dot is not an extension); untitled documents get `untitledName + ".png"`.
    static func suggestedFilename(original: String?, untitledName: String, format: FileFormat) -> String {
        let base = original.map { ($0 as NSString).deletingPathExtension } ?? untitledName
        return base + "." + format.preferredFilenameExtension
    }
}

/// What ⌘S does for a document (`FileFormat.saveAction(for:)`).
enum SaveAction: Equatable, Sendable {
    /// Write the document's own format to its current URL — no panel.
    case writeInPlace(FileFormat)
    /// Run the save panel offering `offering`, with `suggested` preselected.
    case saveAs(offering: [FileFormat], suggested: FileFormat)
}
