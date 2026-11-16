import AppKit
import Foundation
import Testing

@testable import PaintDotMac

/// App-level undo integration: the window supplies the bridge's `UndoManager` (so the ⌘Z /
/// ⇧⌘Z menu items validate and title from the history), and a scripted editing session
/// round-trips through `HistoryStack` with exact pixel outcomes (spec 0008).
@MainActor
@Suite(.serialized)
struct HistoryIntegrationTests {
    /// The menu's Undo/Redo actions (0001's `MainMenu` items target `undo:` / `redo:`;
    /// `NSWindow` implements both and validates them from its `windowWillReturnUndoManager`).
    private let undoAction = NSSelectorFromString("undo:")
    private let redoAction = NSSelectorFromString("redo:")

    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    // MARK: - Engine-level session (synthetic strokes, official capture pattern)

    @Test func syntheticSessionUndoRedo() throws {
        // 1000×700 New Image via 0005's request; stack base .newImage.
        var state = DocumentState(
            image: NewImageRequest(size: PixelSize(width: 1000, height: 700), dpi: 96).makeImage()
        )
        var stack = HistoryStack(base: .newImage)
        let blankOracle = ReferenceCanvas(image: state.image)
        var oracles: [ReferenceCanvas] = [blankOracle]
        var expectedCost = 0

        /// One synthetic stroke with the documented capture pattern.
        func stroke(layer: Int, _ rect: PixelRect, color: ColorRGBA8) throws {
            let before = state.image
            let touched = fillRect(&state.image, layer: layer, rect: rect, color: color)
            // Generations, not geometry: after a live draw the touched layer's changed tiles
            // are exactly the ones `fillRect` wrote; every other layer gets no candidates.
            var candidateMap: [Layer.ID: Set<TileCoordinate>] = [:]
            for existing in before.layers { candidateMap[existing.id] = [] }
            candidateMap[before.layers[layer].id] = touched
            let diff = try TileDiff.between(before: before, after: state.image,
                                            candidates: candidateMap)
            stack.commit(TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush, diff: diff))
            var oracle = oracles[oracles.count - 1]
            oracle.fillRect(rect: rect, color: color, layer: layer)
            oracles.append(oracle)
            expectedCost += diff.byteCost + HistoryCost.stepOverheadBytes
        }

        try stroke(layer: 0, PixelRect(x: 10, y: 10, width: 20, height: 20),
                   color: ColorRGBA8(red: 255, green: 0, blue: 0))     // tile (0,0)
        try stroke(layer: 0, PixelRect(x: 250, y: 250, width: 10, height: 10),
                   color: ColorRGBA8(red: 0, green: 0, blue: 255))     // tiles (0,0)…(1,1)
        try stroke(layer: 0, PixelRect(x: 990, y: 690, width: 20, height: 20),
                   color: ColorRGBA8(red: 0, green: 255, blue: 0))     // edge tile (3,2)

        // One snapshot step: Add New Layer (empty layer, active index 1).
        let beforeAdd = state
        var appended = state.image
        appended.layers.append(Layer(name: "Layer 2",
                                     surface: TiledSurface(size: state.image.size)))
        appended.activeLayerIndex = 1
        state.image = appended
        let addItem = DocumentSnapshotHistoryItem(name: "Add New Layer", icon: .layerAdd,
                                                  before: beforeAdd, after: state)
        stack.commit(addItem)
        oracles.append(ReferenceCanvas(image: state.image))
        expectedCost += addItem.byteCost + HistoryCost.stepOverheadBytes  // empty layer = 0

        try stroke(layer: 1, PixelRect(x: 10, y: 10, width: 20, height: 20),
                   color: ColorRGBA8(red: 255, green: 0, blue: 0))     // layer 1 tile (0,0)

        #expect(stack.steps.map(\.name)
                == ["New Image", "Paintbrush", "Paintbrush", "Paintbrush",
                    "Add New Layer", "Paintbrush"])
        // Hand-computed: (1 + 4 + 1) × 2 + 1 (layer-1 sparse before) tiles on the before+
        // after sides: (6 × 2 + 1) × 262,144 + 5 × 1,024.
        #expect(expectedCost == (13 * 262_144) + 5 * 1_024)
        #expect(stack.totalBytes == expectedCost)

        // Undo all the way: pixels and layer count equal the blank image again.
        while stack.canUndo { _ = stack.undo(&state) }
        #expect(stack.currentIndex == 0)
        assertMatches(state.image, blankOracle, "undo-all equals the blank new image")
        #expect(state.image.layers.count == 1)
        #expect(state.image.activeLayerIndex == 0)

        // Redo all the way: the final oracle.
        while stack.canRedo { _ = stack.redo(&state) }
        assertMatches(state.image, oracles[oracles.count - 1], "redo-all equals the final state")
        #expect(state.image.layers.count == 2)
        // H-6: the last step painted layer 1; undo steps never switched the active layer.
        #expect(state.image.activeLayerIndex == 1)
    }

    @Test func fourKOneTileStrokeCostsOneTile() throws {
        // NF-4: undo memory is proportional to changed tiles only.
        var surface = TiledSurface(size: PixelSize(width: 4000, height: 3000))
        surface.fill(.white)
        let before = LayeredImage(surface: surface)
        var after = before
        // (1024, 1024) sits wholly inside tile (4, 4); (1000, 1000) would straddle four.
        fillRect(&after, layer: 0, rect: PixelRect(x: 1024, y: 1024, width: 30, height: 30),
                 color: .black)
        let diff = try TileDiff.between(before: before, after: after)
        var stack = HistoryStack(base: .openImage)
        stack.commit(TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush, diff: diff))
        #expect(stack.totalBytes == 525_312, "2 × 262,144 + 1,024, not 48 MB")
    }

    @Test func fullLayerChangeCost() throws {
        var surface = TiledSurface(size: PixelSize(width: 4000, height: 3000))
        surface.fill(.white)
        let before = LayeredImage(surface: surface)
        var afterImage = before
        afterImage.layers[0].surface.fill(ColorRGBA8(red: 255, green: 0, blue: 0))
        let diff = try TileDiff.between(before: before, after: afterImage)
        #expect(diff.entries.count == 192, "16 × 12 tiles")
        #expect(diff.byteCost == 100_663_296, "2 × 192 × 262,144 (edge tiles full size)")
    }

    @Test func toolContextCommitHook() throws {
        let context = FakeToolContext(size: PixelSize(width: 512, height: 512))
        // performHistory of a 1-tile item.
        let before = context.image
        var after = before
        fillRect(&after, layer: 0, rect: PixelRect(x: 4, y: 4, width: 4, height: 4),
                 color: ColorRGBA8(red: 255, green: 0, blue: 0))
        let diff = try TileDiff.between(before: before, after: after)
        context.performHistory(TileDiffHistoryItem(name: "First", icon: .paintbrush, diff: diff))
        assertMatches(context.image, ReferenceCanvas(image: after),
                      "performHistory applied the item to the context state")

        // updateImage + commitHistory of a second item.
        context.updateImage { image in
            fillRect(&image, layer: 0, rect: PixelRect(x: 300, y: 4, width: 4, height: 4),
                     color: ColorRGBA8(red: 0, green: 0, blue: 255))
        }
        let secondDiff = try TileDiff.between(before: after, after: context.image)
        context.commitHistory(TileDiffHistoryItem(name: "Second", icon: .eraser, diff: secondDiff))
        #expect(context.history.steps.map(\.name) == ["New Image", "First", "Second"])

        // A no-op item adds nothing.
        let empty = try TileDiff.between(before: context.image, after: context.image)
        context.commitHistory(TileDiffHistoryItem(name: "No-op", icon: .paintbrush, diff: empty))
        #expect(context.history.steps.count == 3)
    }

    // MARK: - Window/menu integration (headless)

    @Test func freshOpenedDocumentHasNothingToUndo() async throws {
        try await TestRunGate.withLock {
            defer { cleanup() }
            let fixtures = try FixtureFiles()
            defer { fixtures.removeAll() }
            let url = try fixtures.makePNG(named: "fresh.png", width: 24, height: 16,
                                           rgba: (10, 20, 30, 255))
            let harness = try await DocumentHarness.open(url)

            // The window vends the bridge's undo manager (H-3).
            let supplied = harness.windowController.windowWillReturnUndoManager(harness.window)
            let manager = try #require(supplied)
            #expect(manager === harness.document.undoBridge.undoManager)
            #expect(manager.canUndo == false)
            #expect(manager.canRedo == false)
            #expect(manager.undoMenuItemTitle == "Undo")
            #expect(manager.redoMenuItemTitle == "Redo")

            // The menu actions validate off (nothing to undo), so ⌘Z is greyed out.
            #expect(harness.isEnabled(undoAction) == false)
            #expect(harness.isEnabled(redoAction) == false)
            #expect(harness.isEnabled(#selector(UndoManager.undo)) == false)

            // …and the untouched document closes without a prompt (APP-9).
            #expect(harness.document.isDocumentEdited == false)
            harness.discardAppModelSuite()
        }
    }

    @Test func freshNewImageHasNothingToUndo() async throws {
        // APP-9: the rewritten New path produces a clean, base-"New Image" document.
        try await TestRunGate.withLock {
            defer { cleanup() }
            let presenter = ScriptedNewImagePresenter(steps: [.ok])
            let harness = try #require(
                DocumentHarness.newImage(presenter: presenter,
                                         pasteboard: makePrivatePasteboard())
            )
            let supplied = harness.windowController.windowWillReturnUndoManager(harness.window)
            let manager = try #require(supplied)
            #expect(manager === harness.document.undoBridge.undoManager)
            #expect(manager.canUndo == false)
            #expect(manager.canRedo == false)
            #expect(manager.undoMenuItemTitle == "Undo")
            #expect(manager.redoMenuItemTitle == "Redo")
            #expect(harness.isEnabled(undoAction) == false)
            #expect(harness.isEnabled(redoAction) == false)
            #expect(harness.document.undoBridge.history.steps.map(\.name) == ["New Image"])
            #expect(harness.document.isDocumentEdited == false)
            harness.discardAppModelSuite()
        }
    }

    @Test func editedDocumentEnablesUndoThroughTheWindow() async throws {
        // Mutation check for the bridge→window wiring: with one committed step the window's
        // validation of `undo:` flips to true and the title names the step.
        try await TestRunGate.withLock {
            defer { cleanup() }
            let fixtures = try FixtureFiles()
            defer { fixtures.removeAll() }
            let url = try fixtures.makePNG(named: "edited.png", width: 600, height: 520,
                                           rgba: (200, 10, 10, 255))
            let harness = try await DocumentHarness.open(url)
            #expect(harness.isEnabled(undoAction) == false)

            let bridge = harness.document.undoBridge
            let before = bridge.state.image
            bridge.updateLiveState { state in
                fillRect(&state.image, layer: 0,
                         rect: PixelRect(x: 300, y: 300, width: 5, height: 5), color: .white)
            }
            let diff = try TileDiff.between(before: before, after: bridge.state.image)
            bridge.commit(TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush, diff: diff))

            #expect(harness.isEnabled(undoAction) == true)
            #expect(harness.isEnabled(redoAction) == false)
            let manager = harness.window.undoManager
            #expect(manager?.undoMenuItemTitle == "Undo Paintbrush")
            #expect(harness.document.isDocumentEdited)

            // The window's canvas follows the history: ⌘Z through the manager redraws the
            // restored tiles (the bridge's onStateChange assigns `canvasView.image`).
            harness.perform(undoAction)
            #expect(bridge.history.currentIndex == 0)
            #expect(harness.canvasView.image != nil)
            #expect(harness.document.isDocumentEdited == false)
            harness.perform(redoAction)
            #expect(bridge.history.currentIndex == 1)
            harness.discardAppModelSuite()
        }
    }

    @Test func undoShortcutIsHarmlessOnFreshDocument() async throws {
        try await TestRunGate.withLock {
            defer { cleanup() }
            let fixtures = try FixtureFiles()
            defer { fixtures.removeAll() }
            let url = try fixtures.makePNG(named: "harmless.png", width: 300, height: 100,
                                           rgba: (7, 7, 7, 255))
            let harness = try await DocumentHarness.open(url)
            let pixelsBefore = sampledPixels(harness.document.image)
            let statusText = harness.statusBar.imageSizeText

            // What AppKit would send only when enabled, plus the manager directly.
            harness.perform(undoAction)
            harness.perform(redoAction)
            harness.document.undoBridge.undo()
            harness.document.undoBridge.redo()

            #expect(sampledPixels(harness.document.image) == pixelsBefore)
            #expect(harness.statusBar.imageSizeText == statusText)
            #expect(harness.document.isDocumentEdited == false)
            harness.discardAppModelSuite()
        }
    }

    @Test func panelSuppliesCurrentDocumentUndoManager() async throws {
        // A key panel must still route ⌘Z to the current document's bridge (0008 item 13).
        try await TestRunGate.withLock {
            defer { cleanup() }
            let fixtures = try FixtureFiles()
            defer { fixtures.removeAll() }
            let url = try fixtures.makePNG(named: "panel.png", width: 8, height: 8,
                                           rgba: (1, 2, 3, 255))
            let harness = try await DocumentHarness.open(url)
            let controller = PanelController(model: harness.appModel)
            defer {
                for panel in controller.panels.values { panel.orderOut(nil) }
                PanelController.current = nil
            }
            let panel = try #require(controller.panels[.history])
            #expect(controller.windowWillReturnUndoManager(panel)
                    === harness.document.undoBridge.undoManager)

            // With no document the panel returns nil — Undo stays disabled (edge case).
            harness.document.close()
            #expect(controller.windowWillReturnUndoManager(panel) == nil)
            harness.discardAppModelSuite()
        }
    }

    private func sampledPixels(_ image: LayeredImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.size.width * image.size.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            image.layers[0].surface.readPixels(in: image.size.bounds, into: buffer,
                                               bytesPerRow: image.size.width * 4)
        }
        return bytes
    }
}
