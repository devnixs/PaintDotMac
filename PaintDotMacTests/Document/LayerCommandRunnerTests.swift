import AppKit
import Foundation
import Testing

@testable import PaintDotMac

/// `LayerCommandRunner` (spec 0024 item 8) against a real `UndoBridge` with
/// `NavigationUndoManager` and `groupsByEvent = false` (0010's test convention): step
/// names, the pending-edit-first order, and the history-free Go to Layer switch.
@MainActor
struct LayerCommandRunnerTests {
    private func fixture(layers: Int = 1, size: PixelSize = PixelSize(width: 300, height: 300))
        -> UndoBridge
    {
        var imageLayers: [Layer] = []
        for index in 0..<layers {
            var surface = TiledSurface(size: size)
            surface.fill(.white)
            imageLayers.append(Layer(name: index == 0 ? "Background" : "Layer \(index + 1)",
                                     surface: surface))
        }
        let manager = NavigationUndoManager()
        manager.groupsByEvent = false
        return UndoBridge(state: DocumentState(
            image: LayeredImage(size: size, layers: imageLayers,
                                activeLayerIndex: layers - 1)),
            base: .newImage, budgetBytes: HistoryStack.defaultBudgetBytes,
            undoManager: manager)
    }

    @Test func runPerformsOneStep() throws {
        let bridge = fixture()
        var editedFlags: [Bool] = []
        bridge.onEditedChange = { editedFlags.append($0) }
        #expect(LayerCommandRunner.run(.addNewLayer, bridge: bridge, commitPendingEdit: {}))
        #expect(bridge.history.steps.map(\.name) == ["New Image", "Add New Layer"])
        #expect(bridge.undoManager.undoMenuItemTitle == "Undo Add New Layer")
        #expect(bridge.undoManager.undoActionName == "Add New Layer")
        #expect(bridge.state.image.layers.count == 2)
        #expect(editedFlags == [true], "the command marks the document edited")
    }

    @Test func disabledReturnsFalse() throws {
        let bridge = fixture(layers: 1)
        #expect(!LayerCommandRunner.run(.deleteLayer, bridge: bridge, commitPendingEdit: {}))
        #expect(bridge.history.steps.map(\.name) == ["New Image"])
        #expect(!bridge.undoManager.canUndo)
    }

    @Test func commitsPendingEditFirst() throws {
        let bridge = fixture()
        // The production shape: `commitPendingEdit` is `prepareForNavigation`, here
        // committing a 1-tile "Paintbrush" diff on layer 0.
        let commitPaintbrush: () -> Void = {
            let before = bridge.state.image
            bridge.updateLiveState { state in
                fillRect(&state.image, layer: 0, rect: PixelRect(x: 5, y: 5, width: 4, height: 4),
                         color: .black)
            }
            let diff = try? TileDiff.between(before: before, after: bridge.state.image)
            if let diff {
                bridge.commit(TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush, diff: diff))
            }
        }
        #expect(LayerCommandRunner.run(.duplicateLayer, bridge: bridge,
                                       commitPendingEdit: commitPaintbrush))
        #expect(bridge.history.steps.map(\.name) == ["New Image", "Paintbrush", "Duplicate Layer"])
        // The duplicate (now active, index 1) contains the committed pixel.
        #expect(bridge.state.image.layers[1].surface.pixel(at: PixelPoint(x: 6, y: 6)) == .black)
        #expect(bridge.state.image.activeLayerIndex == 1)
    }

    @Test func goToIsNotAHistoryStep() throws {
        let bridge = fixture(layers: 2)
        var editedFlags: [Bool] = []
        bridge.onEditedChange = { editedFlags.append($0) }
        #expect(bridge.state.image.activeLayerIndex == 1)
        let revisionBefore = bridge.historyRevision
        #expect(LayerCommandRunner.goTo(.below, bridge: bridge, commitPendingEdit: {}))
        #expect(bridge.state.image.activeLayerIndex == 0)
        #expect(bridge.history.steps.count == 1, "Go to is not a history step")
        #expect(bridge.historyRevision == revisionBefore)
        #expect(!bridge.undoManager.canUndo)
        #expect(editedFlags.isEmpty, "Go to never changes the edited state (D-51)")
        // Already at the bottom.
        #expect(!LayerCommandRunner.goTo(.below, bridge: bridge, commitPendingEdit: {}))
        #expect(LayerCommandRunner.goTo(.above, bridge: bridge, commitPendingEdit: {}))
        #expect(bridge.state.image.activeLayerIndex == 1)
        #expect(!LayerCommandRunner.goTo(.above, bridge: bridge, commitPendingEdit: {}))
    }
}
