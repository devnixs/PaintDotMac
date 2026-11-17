import AppKit
import Foundation
import Testing

@testable import PaintDotMac

/// The hosted command path `DocumentWindowController.runCropToSelection(bridge:
/// gestureInProgress:)` (spec 0022 *Test plan*): the gesture guard and the pending-edit
/// commit, on a bare `UndoBridge` — no window, nothing shown.
@MainActor
@Suite(.serialized)
struct CropToSelectionCommandTests {
    private static let size = PixelSize(width: 30, height: 30)

    /// A 30×30 document with an identifiable pixel pattern.
    private func source(_ x: Int, _ y: Int) -> ColorRGBA8 {
        ColorRGBA8(red: UInt8((x * 7) % 251), green: UInt8((y * 11) % 241), blue: 9, alpha: 255)
    }

    private func bridge(selection: Selection?) -> UndoBridge {
        let surface = TestImages.surface(width: Self.size.width, height: Self.size.height, source)
        let image = LayeredImage(surface: surface)
        return UndoBridge(state: DocumentState(image: image, selection: selection),
                          base: .newImage,
                          budgetBytes: HistoryStack.defaultBudgetBytes)
    }

    private func names(_ bridge: UndoBridge) -> [String] {
        bridge.history.steps.map(\.name)
    }

    @Test func ignoredDuringGesture() {
        let selection = Selection(rect: CGRect(x: 4, y: 4, width: 8, height: 8),
                                  canvasSize: Self.size)!
        let bridge = bridge(selection: selection)
        var prepareCalls = 0
        bridge.prepareForNavigation = { prepareCalls += 1 }
        DocumentWindowController.runCropToSelection(bridge: bridge, gestureInProgress: true)
        #expect(prepareCalls == 0, "a gesture-in-progress ignores the command entirely")
        #expect(names(bridge) == ["New Image"])
        #expect(bridge.state.image.size == Self.size)
    }

    @Test func commitsPendingEditFirst() throws {
        // A fake floating-pixels commit (0020's "Finish Pixels" step): the selection
        // moves from (0, 0, 10, 10) to (20, 20, 10, 10) before the crop reads the state.
        let before = Selection(rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                               canvasSize: Self.size)!
        let after = Selection(rect: CGRect(x: 20, y: 20, width: 10, height: 10),
                              canvasSize: Self.size)!
        let bridge = bridge(selection: before)
        var prepareCalls = 0
        bridge.prepareForNavigation = { [weak bridge] in
            prepareCalls += 1
            bridge?.perform(SelectionHistoryItem(name: "Finish Pixels",
                                                 icon: .moveSelectedPixels,
                                                 before: before, after: after))
        }
        DocumentWindowController.runCropToSelection(bridge: bridge, gestureInProgress: false)
        #expect(prepareCalls == 1)
        #expect(names(bridge) == ["New Image", "Finish Pixels", "Crop to Selection"])
        let state = bridge.state
        #expect(state.image.size == PixelSize(width: 10, height: 10))
        // The crop used the committed selection: source at offset (20, 20).
        TestImages.expectPixels(state.image.layers[0].surface) { i, j in
            self.source(20 + i, 20 + j)
        }
        #expect(state.selection?.mask.isFull == true)
    }

    @Test func noSelectionIsNoOp() {
        let bridge = bridge(selection: nil)
        var prepareCalls = 0
        bridge.prepareForNavigation = { prepareCalls += 1 }
        DocumentWindowController.runCropToSelection(bridge: bridge, gestureInProgress: false)
        #expect(prepareCalls == 1, "the commit hook still runs (the state must be committed)")
        #expect(names(bridge) == ["New Image"])
        #expect(bridge.state.image.size == Self.size)
    }
}
