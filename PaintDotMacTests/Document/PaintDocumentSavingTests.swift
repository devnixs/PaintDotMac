import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PaintDotMac

/// Document-level save tests (spec 0005): documents built in code, never shown; writes go to
/// throwaway URLs under the system temporary directory.
@MainActor
@Suite(.serialized)
struct PaintDocumentSavingTests {
    private func pngData(width: Int, height: Int, dpi: Double? = nil,
                         pixel: @escaping (Int, Int) -> ColorRGBA8) throws -> Data {
        let image = TestImages.cgImage(width: width, height: height,
                                       bytes: TestImages.rgbaBytes(width: width, height: height, pixel))
        var properties: [CFString: Any] = [:]
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        return TestImages.encode(image, as: .png, properties: properties)
    }

    private func jpegData(width: Int, height: Int) throws -> Data {
        let image = TestImages.cgImage(width: width, height: height,
                                       bytes: TestImages.rgbaBytes(width: width, height: height) { x, y in
                                           ColorRGBA8(red: UInt8(x % 256), green: UInt8(y % 256), blue: 128)
                                       })
        return TestImages.encode(image, as: .jpeg,
                                 properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
    }

    /// Reads a document the way `NSDocument` does (without a file on disk).
    private func readDocument(_ data: Data, as type: String) throws -> PaintDocument {
        let document = PaintDocument()
        try document.read(from: data, ofType: type)
        return document
    }

    /// The deterministic semi-transparent + alpha-0 pattern used by the round-trip fixtures.
    private static func mixedPixel(_ x: Int, _ y: Int) -> ColorRGBA8 {
        let alpha: UInt8 = (x + y) % 7 == 0 ? 0 : UInt8((x &* 3 &+ y) % 256)
        return ColorRGBA8(red: UInt8(x % 256), green: UInt8(255 &- y % 256), blue: UInt8((x &+ y) % 256), alpha: alpha)
    }

    // MARK: - Configuration

    /// Interim rules 4: autosavesInPlace is off (permanent) and no autosave type exists
    /// before 0047.
    @Test func autosaveSettings() {
        #expect(PaintDocument.autosavesInPlace == false)
        #expect(PaintDocument().autosavingFileType == nil)
    }

    /// 0001's disabling override is gone: `NSDocument`'s standard validation applies.
    @Test func saveActionsAreEnabled() throws {
        let document = try readDocument(pngData(width: 8, height: 8) { _, _ in .white }, as: "public.png")
        for name in ["saveDocument:", "saveDocumentAs:"] {
            let item = NSMenuItem(title: name, action: NSSelectorFromString(name), keyEquivalent: "")
            #expect(document.validateUserInterfaceItem(item) == true, "\(name) must be enabled")
        }
    }

    @Test func writableTypesArePNGOnly() throws {
        let pngDocument = try readDocument(pngData(width: 8, height: 8) { _, _ in .white }, as: "public.png")
        let jpegDocument = try readDocument(jpegData(width: 8, height: 8), as: "public.jpeg")
        for document in [pngDocument, jpegDocument] {
            for operation in [NSDocument.SaveOperationType.saveOperation,
                              .saveAsOperation, .saveToOperation] {
                #expect(document.writableTypes(for: operation) == ["public.png"],
                        "operation \(operation.rawValue)")
            }
        }
    }

    @Test func fileNameExtension() throws {
        let document = try readDocument(pngData(width: 8, height: 8) { _, _ in .white }, as: "public.png")
        #expect(document.fileNameExtension(forType: "public.png",
                                           saveOperation: .saveOperation) == "png")
    }

    /// Save As… for an untitled (new) document names the file "Untitled.png" and offers only
    /// PNG; with no fileURL the folder is left to `NSSavePanel`.
    @Test func prepareSavePanelUntitled() throws {
        let document = PaintDocument()
        // 0008: the state arrives through the bridge (what step 4 of `newDocument` does).
        document.undoBridge.reset(
            state: DocumentState(
                image: NewImageRequest(size: PixelSize(width: 16, height: 12), dpi: 96).makeImage()
            ),
            base: .newImage
        )
        let panel = NSSavePanel()
        #expect(document.prepareSavePanel(panel))
        #expect(panel.nameFieldStringValue == "Untitled.png")
        #expect(panel.allowedContentTypes == [.png])
    }

    // MARK: - data(ofType:)

    /// A 300 DPI fixture with semi-transparent and alpha-0 pixels re-encodes byte-exact, and
    /// the file carries pHYs 11811 ±1.
    @Test func dataOfTypePNGRoundTrips() throws {
        let source = try pngData(width: 300, height: 200, dpi: 300, pixel: Self.mixedPixel)
        let document = try readDocument(source, as: "public.png")
        let saved = try document.data(ofType: "public.png")

        let decoded = try ImageDecoder.decode(saved)
        TestImages.expectPixels(decoded.surface, match: Self.mixedPixel)
        let phys = try #require(PNGChunks.chunks(in: saved, named: "pHYs").first)
        let ppm = Int(phys.data[0]) << 24 | Int(phys.data[1]) << 16 | Int(phys.data[2]) << 8 | Int(phys.data[3])
        #expect(abs(ppm - 11_811) <= 1, "pHYs X is \(ppm)")
    }

    /// JPEG arrives in 0029; the write throws the typed error so `NSDocument` alerts.
    @Test func dataOfTypeJPEGThrows() throws {
        let document = try readDocument(jpegData(width: 8, height: 8), as: "public.jpeg")
        #expect(throws: ImageCodecError.unsupportedWriteFormat(.jpeg)) {
            try document.data(ofType: "public.jpeg")
        }
    }

    /// An unknown type identifier (`.ora` before 0028, a garbage string) throws
    /// `ImageCodecError.encodingFailed` (spec *Scope*, `data(ofType:)`), never
    /// `NSDocument`'s base-class behavior.
    @Test func dataOfTypeUnknownTypeThrows() throws {
        let document = try readDocument(pngData(width: 8, height: 8) { _, _ in .white }, as: "public.png")
        for name in ["public.tiff", "com.example.unknown"] {
            #expect(throws: ImageCodecError.encodingFailed, "\(name) must be refused") {
                try document.data(ofType: name)
            }
        }
    }

    /// `data(ofType:)` is `nonisolated` because AppKit may encode on a background save
    /// queue; the model snapshot re-hops to the main thread and the returned bytes are the
    /// same as the main-thread call.
    @Test func dataOfTypeFromBackgroundQueue() async throws {
        let document = try readDocument(
            pngData(width: 8, height: 6, dpi: 300, pixel: Self.mixedPixel), as: "public.png")
        nonisolated(unsafe) let snapshotSource = document
        let saved = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try snapshotSource.data(ofType: "public.png") })
            }
        }
        let decoded = try ImageDecoder.decode(saved)
        TestImages.expectPixels(decoded.surface, match: Self.mixedPixel)
    }

    // MARK: - ⌘S routing (interim rule 2)

    /// Records `saveAs(_:)` instead of running the panel (a panel can never run in a test).
    final class RecordingSaveAsDocument: PaintDocument {
        private(set) var saveAsCalls = 0
        override func saveAs(_ sender: Any?) { saveAsCalls += 1 }
    }

    /// ⌘S on a JPEG-backed document behaves exactly like File > Save As… (interim rule 2,
    /// PRD §5.11): `save(_:)` (the Swift name of `saveDocument:`) routes to `saveAs(_:)`
    /// and never writes the JPEG URL. ⌘S on a file-backed PNG goes to `super` (write in
    /// place, no Save As). The PNG check runs first: on a build whose routing is broken,
    /// the JPEG `super` path ends in AppKit's error alert, which must never gate the run.
    @Test func saveDocumentRoutesJPEGThroughSaveAs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A PNG-backed document goes to `super` (in place, no panel): `saveAs` is not called.
        let pngBytes = try pngData(width: 8, height: 8) { _, _ in .white }
        let pngURL = directory.appendingPathComponent("photo.png")
        try pngBytes.write(to: pngURL)
        let pngDocument = RecordingSaveAsDocument()
        try pngDocument.read(from: pngBytes, ofType: "public.png")
        pngDocument.fileURL = pngURL
        pngDocument.fileType = "public.png"
        pngDocument.save(nil)
        #expect(pngDocument.saveAsCalls == 0, "⌘S on a PNG must write in place")

        let jpegBytes = try jpegData(width: 8, height: 8)
        let jpegURL = directory.appendingPathComponent("photo.jpg")
        try jpegBytes.write(to: jpegURL)
        let jpegDocument = RecordingSaveAsDocument()
        try jpegDocument.read(from: jpegBytes, ofType: "public.jpeg")
        jpegDocument.fileURL = jpegURL
        jpegDocument.fileType = "public.jpeg"
        jpegDocument.save(nil)
        #expect(jpegDocument.saveAsCalls == 1, "⌘S on a JPEG must open Save As…")
        #expect(try Data(contentsOf: jpegURL) == jpegBytes, "the JPEG on disk changed")
        // Give AppKit's write a moment to land before the temp directory is removed.
        try await Task.sleep(for: .milliseconds(100))
    }

    /// FMT-B/D-24: a Display P3 source converts to sRGB on open (0002) and saves with an
    /// sRGB profile, never P3.
    @Test func displayP3InputSavesAsSRGB() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let image = TestImages.cgImage(
            width: 8, height: 8,
            bytes: TestImages.rgbaBytes(width: 8, height: 8) { _, _ in ColorRGBA8(red: 200, green: 30, blue: 90) },
            colorSpace: p3)
        let document = try readDocument(TestImages.encode(image, as: .png), as: "public.png")
        let saved = try document.data(ofType: "public.png")
        let profileName = try #require(FixtureFiles.profileName(of: saved))
        #expect(profileName.contains("sRGB"), "profile is \(profileName)")
        #expect(!profileName.contains("P3"), "profile is \(profileName)")
    }

    // MARK: - Saving files

    @Test func saveInPlaceRewritesPNG() async throws {
        let data = try pngData(width: 64, height: 48, dpi: 300, pixel: Self.mixedPixel)
        let url = try TestImages.temporaryFile(named: "in-place.png", contents: data)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try readDocument(data, as: "public.png")

        // The path `saveDocument(_:)` takes for a PNG document: `.writeInPlace`, no panel.
        try await saveDocument(document, to: url, ofType: "public.png", for: .saveOperation)

        let decoded = try FixtureFiles.decodePNG(at: url)
        #expect(decoded.width == 64, "decoded file lost its pixels")
        #expect(decoded.height == 48)
        let original = try ImageDecoder.decode(data)
        #expect(decoded.pixels == original.surface.readPixels(in: original.surface.bounds))
        #expect(document.isDocumentEdited == false)
    }

    /// 0008 supersedes 0005's interim rule 3: the edited state follows history only, so a
    /// document built through the New path (step 4's `undoBridge.reset`) is clean (APP-9,
    /// D-30) and stays clean through a Save As.
    @Test func newDocumentIsCleanAndStaysCleanAfterSaveAs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Untitled.png")

        let document = PaintDocument()
        // Step 4 of `PaintDocumentController.newDocument(_:)`, verbatim (0008 item 11).
        document.undoBridge.reset(state: DocumentState(
            image: NewImageRequest(size: PixelSize(width: 16, height: 12), dpi: 96).makeImage()
        ), base: .newImage)
        #expect(document.isDocumentEdited == false)
        #expect(document.undoBridge.history.steps.map(\.name) == ["New Image"])

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await saveDocument(document, to: url, ofType: "public.png", for: .saveAsOperation)

        #expect(document.isDocumentEdited == false)
        #expect(document.fileURL == url)
        #expect(document.fileType == "public.png")
    }

    /// A JPEG-backed document's ⌘S maps to Save As… (the panel itself is covered by
    /// `SaveIntegrationTests.jpegSavePreparesPNGPanel`).
    @Test func jpegDocumentSaveActionIsSaveAs() throws {
        let document = try readDocument(jpegData(width: 8, height: 8), as: "public.jpeg")
        document.fileType = "public.jpeg"  // what opening a file sets
        let fileType = try #require(document.fileType)
        #expect(FileFormat.saveAction(for: FileFormat(typeIdentifier: fileType))
                == .saveAs(offering: [.png], suggested: .png))
    }

    /// An unwritable folder: the completion reports an error, no file appears, and the
    /// document keeps its URL.
    @Test func writeToReadOnlyDirectoryFails() async throws {
        let fileManager = FileManager.default
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? fileManager.removeItem(at: directory)
        }

        let document = try readDocument(pngData(width: 8, height: 8) { _, _ in .white }, as: "public.png")
        let url = directory.appendingPathComponent("nope.png")
        await #expect(throws: (any Error).self) {
            try await saveDocument(document, to: url, ofType: "public.png", for: .saveOperation)
        }
        #expect(!fileManager.fileExists(atPath: url.path), "a partial file was written")
        #expect(document.fileURL == nil, "the document adopted a URL it could not write")
    }
}
