import Foundation
import Testing
@testable import PaintDotMac

/// Expected values from spec 0005 *Scope* (identifiers, extensions, capabilities) and
/// PRD §5.11 "Saving" (save-action rules) — none computed by the code under test.
struct FileFormatTests {
    @Test func typeIdentifiers() {
        #expect(FileFormat.png.typeIdentifier == "public.png")
        #expect(FileFormat.jpeg.typeIdentifier == "public.jpeg")
        #expect(FileFormat(typeIdentifier: "public.png") == .png)
        #expect(FileFormat(typeIdentifier: "public.jpeg") == .jpeg)
        #expect(FileFormat(typeIdentifier: "public.tiff") == nil)
        #expect(FileFormat(typeIdentifier: "com.example.unknown") == nil)
    }

    @Test func fileExtensions() {
        #expect(FileFormat(fileExtension: "png") == .png)
        #expect(FileFormat(fileExtension: "PNG") == .png)
        #expect(FileFormat(fileExtension: "jpg") == .jpeg)
        #expect(FileFormat(fileExtension: "jpeg") == .jpeg)
        #expect(FileFormat(fileExtension: "JPG") == .jpeg)
        #expect(FileFormat(fileExtension: "jpe") == .jpeg)
        #expect(FileFormat(fileExtension: "gif") == nil)
        #expect(FileFormat(fileExtension: "") == nil)
    }

    @Test func capabilities() {
        #expect(FileFormat.png.canRead)
        #expect(FileFormat.jpeg.canRead)
        #expect(FileFormat.png.canWrite == true)
        #expect(FileFormat.jpeg.canWrite == false)  // 0029 flips this
        #expect(FileFormat.writableFormats == [.png])
        #expect(FileFormat.defaultNewDocumentFormat == .png)  // 0028 → .openRaster
        #expect(FileFormat.png.preferredFilenameExtension == "png")
        #expect(FileFormat.jpeg.preferredFilenameExtension == "jpg")
        #expect(FileFormat.png.displayName == "PNG")
        #expect(FileFormat.jpeg.displayName == "JPEG")
    }

    // MARK: - Save actions (PRD §5.11 "Saving")

    @Test func saveActionUntitled() {
        #expect(FileFormat.saveAction(for: nil) == .saveAs(offering: [.png], suggested: .png))
    }

    @Test func saveActionForPNGWritesInPlace() {
        #expect(FileFormat.saveAction(for: .png) == .writeInPlace(.png))
    }

    @Test func saveActionForJPEGIsSaveAs() {
        // A JPEG is never silently re-encoded (D-6): ⌘S behaves like Save As….
        #expect(FileFormat.saveAction(for: .jpeg) == .saveAs(offering: [.png], suggested: .png))
    }

    // MARK: - Suggested names

    @Test func suggestedFilenameReplacesExtension() {
        func suggested(_ original: String) -> String {
            FileFormat.suggestedFilename(original: original, untitledName: "Untitled", format: .png)
        }
        #expect(suggested("photo.jpg") == "photo.png")
        #expect(suggested("archive.tar.jpg") == "archive.tar.png")  // only the last extension
        #expect(suggested("noext") == "noext.png")
        #expect(suggested(".hidden") == ".hidden.png")  // a leading dot is not an extension
    }

    @Test func suggestedFilenameUntitled() {
        #expect(FileFormat.suggestedFilename(original: nil, untitledName: "Untitled",
                                             format: .png) == "Untitled.png")
    }
}
