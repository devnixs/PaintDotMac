import AppKit
import Foundation
import Testing

@testable import PaintDotMac

/// Document glue: the edited state follows the history, the save bookkeeping marks the
/// saved step, and Save commits a pending tool edit (spec 0008 *Document glue tests* —
/// real Foundation `UndoManager`, no windows except where one is the subject).
@MainActor
struct PaintDocumentHistoryTests {
    private func pngData(_ width: Int = 16, _ height: Int = 12) throws -> Data {
        let fixtures = try FixtureFiles()
        defer { fixtures.removeAll() }
        let url = try fixtures.makePNG(named: "doc.png", width: width, height: height,
                                       rgba: (30, 40, 50, 255))
        return try Data(contentsOf: url)
    }

    private func openedDocument() throws -> PaintDocument {
        let document = PaintDocument()
        try document.read(from: try pngData(), ofType: "public.png")
        return document
    }

    /// Draws a red 4×4 rect at (0,0) live and commits it, like a tool would.
    private func commitRedEdit(_ document: PaintDocument, x: Int = 0) throws {
        let bridge = document.undoBridge
        let before = bridge.state.image
        bridge.updateLiveState { state in
            fillRect(&state.image, layer: 0, rect: PixelRect(x: x, y: 0, width: 4, height: 4),
                     color: ColorRGBA8(red: 255, green: 0, blue: 0))
        }
        let diff = try TileDiff.between(before: before, after: bridge.state.image)
        bridge.commit(TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush, diff: diff))
    }

    @Test func openedDocumentIsClean() throws {
        let document = try openedDocument()
        #expect(document.isDocumentEdited == false)
        #expect(document.hasUndoManager == false,
                "NSDocument must never observe undo (0008)")
        #expect(document.undoBridge.history.steps.map(\.name) == ["Open Image"])
        #expect(document.undoBridge.history.savedStepID == 0)
        #expect(document.image.layers.count == 1)
        #expect(document.image.size == PixelSize(width: 16, height: 12))
    }

    @Test func editDirtiesAndUndoCleans() throws {
        let document = try openedDocument()
        try commitRedEdit(document)
        #expect(document.isDocumentEdited, "a step dirties the document")
        document.undoBridge.undo()
        #expect(document.isDocumentEdited == false, "undoing the step cleans it")
        document.undoBridge.redo()
        #expect(document.isDocumentEdited)
    }

    @Test func saveClearsAtCurrentStep() throws {
        let document = try openedDocument()
        try commitRedEdit(document)
        #expect(document.isDocumentEdited)

        let token = document.changeCountToken(for: .saveOperation)
        document.updateChangeCount(withToken: token, for: .saveOperation)
        #expect(document.isDocumentEdited == false)
        #expect(document.undoBridge.history.savedStepID
                == document.undoBridge.history.currentStepID)

        document.undoBridge.undo()
        #expect(document.isDocumentEdited, "undoing past the saved step dirties again")
        document.undoBridge.redo()
        #expect(document.isDocumentEdited == false)
    }

    @Test func editDuringSaveStaysDirty() throws {
        let document = try openedDocument()
        let token = document.changeCountToken(for: .saveOperation)
        try commitRedEdit(document)  // an edit made while the async save was running
        document.updateChangeCount(withToken: token, for: .saveOperation)
        #expect(document.isDocumentEdited,
                "an edit made during the save keeps the document dirty")
        #expect(document.undoBridge.history.savedStepID == 0,
                "the token's step (the base) is marked saved, not the new current")
        document.undoBridge.undo()
        #expect(document.isDocumentEdited == false, "undo back to the saved base")
    }

    @Test func autosaveAndSaveToDoNotClear() throws {
        let document = try openedDocument()
        try commitRedEdit(document)
        let token = document.changeCountToken(for: .autosaveElsewhereOperation)

        document.updateChangeCount(withToken: token, for: .autosaveElsewhereOperation)
        #expect(document.isDocumentEdited, "autosave never clears the edited state")
        #expect(document.undoBridge.history.savedStepID == 0)

        document.updateChangeCount(withToken: token, for: .saveToOperation)
        #expect(document.isDocumentEdited, "File > Save To never clears either")
        #expect(document.undoBridge.history.savedStepID == 0)
    }

    @Test func newImageIsCleanWithNewImageBase() throws {
        // The rewritten step-4 path: the controller resets the bridge with base .newImage.
        let document = PaintDocument()
        document.undoBridge.reset(state: DocumentState(
            image: NewImageRequest(size: PixelSize(width: 16, height: 12), dpi: 96).makeImage()
        ), base: .newImage)
        #expect(document.undoBridge.history.steps.map(\.name) == ["New Image"])
        #expect(document.isDocumentEdited == false, "an untouched new image is clean (APP-9)")

        // `PaintDocument(type:)` — what `makeUntitledDocument(ofType:)` calls.
        let typed = try PaintDocument(type: "public.png")
        #expect(typed.undoBridge.history.steps.map(\.name) == ["New Image"])
        #expect(typed.isDocumentEdited == false)
    }

    @Test func saveCommitsPendingEdit() async throws {
        let document = try openedDocument()
        let bridge = document.undoBridge
        var hookRan = false
        bridge.prepareForNavigation = {
            // Stand-in for 0009's in-progress stroke: draw and commit through the bridge.
            hookRan = true
            let before = bridge.state.image
            bridge.updateLiveState { state in
                fillRect(&state.image, layer: 0,
                         rect: PixelRect(x: 0, y: 0, width: 4, height: 4), color: ColorRGBA8(red: 255, green: 0, blue: 0))
            }
            if let diff = try? TileDiff.between(before: before, after: bridge.state.image) {
                bridge.commit(TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush,
                                                  diff: diff))
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("pending.png")
        try await saveDocument(document, to: url, ofType: "public.png", for: .saveAsOperation)

        #expect(hookRan, "save runs prepareForNavigation before writing")
        #expect(bridge.history.steps.map(\.name) == ["Open Image", "Paintbrush"])
        let decoded = try FixtureFiles.decodePNG(at: url)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = (y * decoded.width + x) * 4
            return Array(decoded.pixels[offset..<offset + 4])
        }
        #expect(pixel(1, 1) == [255, 0, 0, 255], "the committed stroke is in the file")
        #expect(pixel(10, 10) == [30, 40, 50, 255], "the rest of the file is the opened image")
        #expect(document.isDocumentEdited == false, "the save marked the current step saved")
    }

    @Test func revertResetsHistory() async throws {
        let document = try openedDocument()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("revert.png")
        try await saveDocument(document, to: url, ofType: "public.png", for: .saveAsOperation)

        try commitRedEdit(document)
        try commitRedEdit(document, x: 8)  // a distinct edit; the same rect would be a no-op
        #expect(document.undoBridge.history.steps.count == 3)

        try document.revert(toContentsOf: url, ofType: "public.png")
        #expect(document.undoBridge.history.steps.map(\.name) == ["Open Image"])
        #expect(document.isDocumentEdited == false)
        #expect(document.undoBridge.undoManager.canUndo == false)
    }

    @Test func windowControllerSuppliesBridgeUndoManager() throws {
        let document = try openedDocument()
        document.makeWindowControllers()
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController
        )
        let window = try #require(controller.window)
        #expect(controller.windowWillReturnUndoManager(window) === document.undoBridge.undoManager)
        HeadlessAssertions.noVisibleWindows()
        document.close()
    }
}
