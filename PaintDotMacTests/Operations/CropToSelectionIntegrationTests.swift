import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// Crop to Selection behind the real `UndoBridge` + `HistoryStack` (spec 0022 *Test
/// plan*, integration): the shared static command path the window controller calls, one
/// "Crop to Selection" step after a paint step and a selection step, and an exact
/// undo/redo round trip of size, pixels, layer list, and selection.
@MainActor
struct CropToSelectionIntegrationTests {
    private static let size = PixelSize(width: 1000, height: 700)

    private var red: ColorRGBA8 { ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255) }

    @Test func undoRedoRoundTrip() throws {
        let image = LayeredImage.blank(size: Self.size, fill: .white)
        let bridge = UndoBridge(state: DocumentState(image: image),
                                base: .newImage,
                                budgetBytes: HistoryStack.defaultBudgetBytes)
        // 0008's convention for synchronously driven bridges: one group per step.
        bridge.undoManager.groupsByEvent = false
        var changes: [HistoryChange] = []
        var editedFlags: [Bool] = []
        bridge.onStateChange = { changes.append($0) }
        bridge.onEditedChange = { editedFlags.append($0) }

        // A "Paintbrush"-style pixel step: fill (100, 100, 50, 50) red through a TileDiff.
        let painted = {
            var copy = bridge.state.image
            fillRect(&copy, layer: 0, rect: PixelRect(x: 100, y: 100, width: 50, height: 50),
                     color: self.red)
            return copy
        }()
        let diff = TileDiff.between(before: image.layers[0].surface,
                                    after: painted.layers[0].surface,
                                    layerID: image.layers[0].id)
        #expect(!diff.isEmpty)
        bridge.perform(TileDiffHistoryItem(name: "Paintbrush", icon: .paintbrush, diff: diff))

        // An "Ellipse Select" selection step: ellipse in (80, 90, 300, 200).
        let selection = try #require(Selection(
            path: CGPath(ellipseIn: CGRect(x: 80, y: 90, width: 300, height: 200), transform: nil),
            canvasSize: Self.size))
        bridge.perform(SelectionHistoryItem(name: "Ellipse Select", icon: .ellipseSelect,
                                            before: nil, after: selection))
        let preCrop = bridge.state
        #expect(preCrop.floatingPixels == nil)

        // The command.
        DocumentWindowController.runCropToSelection(bridge: bridge, gestureInProgress: false)
        #expect(bridge.history.steps.map(\.name)
            == ["New Image", "Paintbrush", "Ellipse Select", "Crop to Selection"])
        let cropped = bridge.state
        #expect(cropped.image.size == selection.bounds.size)
        #expect(cropped.image.size != Self.size, "the crop actually changed the size")
        #expect(cropped.selection?.canvasSize == cropped.image.size)
        #expect(changes.last == .structure, "the crop reported .structure")
        #expect(editedFlags.last == true, "the document became edited (not at the saved state)")

        // The painted red inside the ellipse survives at the translated position (the
        // fill rect is (100, 100, 50, 50); (140, 140) is inside it and inside the
        // ellipse — (90/150)² + (50/100)² < 1); the ellipse's corner region (inside the
        // bbox, outside the ellipse) is transparent.
        let origin = selection.bounds
        let surface = cropped.image.layers[0].surface
        #expect(surface.pixel(at: PixelPoint(x: 140 - origin.x, y: 140 - origin.y)) == red)
        #expect(surface.pixel(at: PixelPoint(x: 85 - origin.x, y: 95 - origin.y)).alpha == 0,
                "corner outside the ellipse")

        // Undo: size, every pixel, layer list, and the selection exactly.
        bridge.undo()
        #expect(bridge.state == preCrop)
        #expect(bridge.state.image.size == Self.size)
        #expect(changes.last == .structure, "the undo reported .structure too")
        #expect(editedFlags.last == true,
                "still edited: the Paintbrush and Ellipse Select steps remain")

        // Redo: the cropped state exactly.
        bridge.redo()
        #expect(bridge.state == cropped)
        #expect(editedFlags.last == true)
    }
}
