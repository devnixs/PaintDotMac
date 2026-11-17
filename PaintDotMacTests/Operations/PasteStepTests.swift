import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// The "Paste" step's composition, its session-start recognition (0020's
/// `stepStartsSession`), and apply/revert identity (spec 0021 *Test plan*).
struct PasteStepTests {
    private func state(size: PixelSize = PixelSize(width: 8, height: 6)) -> DocumentState {
        DocumentState(image: LayeredImage.blank(size: size, fill: .white))
    }

    private func surface(_ color: ColorRGBA8 = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        -> TiledSurface
    {
        TestImages.surface(width: 3, height: 2) { _, _ in color }
    }

    @Test func composition() throws {
        let state = state()
        let plan = PastePlanner.plan(clipboardSize: PixelSize(width: 3, height: 2),
                                     canvasSize: state.image.size,
                                     visibleCanvasRect: CGRect(x: 1, y: 1, width: 6, height: 5),
                                     choice: nil)
        let item = PasteStep.makeHistoryItem(surface: surface(), plan: plan, state: state,
                                             expanded: nil, baseStepID: 0)
        // (3×2 at (1, 1): the visible rect starts at canvas (1, 1).)
        #expect(item.name == "Paste")
        #expect(item.icon == .paste)
        #expect(item.items.count == 3)
        #expect(item.items[0] is TileDiffHistoryItem)
        #expect(item.items[1] is SelectionHistoryItem)
        let floatingItem = try #require(item.items[2] as? FloatingPixelsHistoryItem)
        #expect(floatingItem.before == nil)
        #expect(floatingItem.after != nil, "the step starts the floating session")

        // 0020 recognizes the Paste step as the session start.
        var history = HistoryStack(base: .openImage)
        var mutated = state
        let result = history.perform(item, on: &mutated)
        let stepID = try #require(result.recordedStepID)
        let step = try #require(history.steps.first { $0.id == stepID })
        let floating = try #require(mutated.floatingPixels)
        #expect(MoveSelectedPixelsHistory.stepStartsSession(step, id: floating.id))

        // The layer shows the pasted pixels; the underlay keeps the pre-paste layer.
        let layer = mutated.image.layers[0].surface
        #expect(layer.pixel(at: PixelPoint(x: 1, y: 1))
                == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        #expect(layer.pixel(at: PixelPoint(x: 5, y: 5)) == .white)
        #expect(floating.underlay.pixel(at: PixelPoint(x: 1, y: 1)) == .white,
                "0020's model: the layer shows them, the underlay stays pristine")
        #expect(mutated.selection?.bounds == PixelRect(x: 1, y: 1, width: 3, height: 2))

        // revert restores everything exactly.
        history.undo(&mutated)
        #expect(mutated == state)
    }

    @Test func withExpansion() throws {
        let state = DocumentState(
            image: LayeredImage.blank(size: PixelSize(width: 4, height: 4), fill: .white))
        let expanded = try PastePlanner.expandedState(
            state, to: PixelSize(width: 6, height: 5), background: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255), limits: .standard)
        let plan = PastePlanner.plan(clipboardSize: PixelSize(width: 6, height: 5),
                                     canvasSize: state.image.size,
                                     visibleCanvasRect: CGRect(x: 0, y: 0, width: 4, height: 4),
                                     choice: .expandCanvas)
        let item = PasteStep.makeHistoryItem(surface: surface(), plan: plan, state: state,
                                             expanded: expanded, baseStepID: 0)
        #expect(item.items.count == 4)
        #expect(item.items[0] is DocumentSnapshotHistoryItem,
                "the expansion rides in the same step, first")
        // One apply / one revert: identity across the canvas-size change.
        var forward = state
        item.apply(to: &forward)
        #expect(forward.image.size == PixelSize(width: 6, height: 5))
        #expect(forward.floatingPixels != nil)
        item.revert(&forward)
        #expect(forward == state, "undo restores the old size, pixels, selection, floating")
    }

    @Test func applyRevertIdentity() throws {
        // A pre-existing selection is restored by revert (SelectionHistoryItem before).
        var start = state()
        start.selection = try #require(
            Selection(rect: CGRect(x: 0, y: 0, width: 4, height: 3), canvasSize: start.image.size)
                as Selection?)
        let plan = PastePlanner.plan(clipboardSize: PixelSize(width: 3, height: 2),
                                     canvasSize: start.image.size,
                                     visibleCanvasRect: CGRect(x: 200, y: 100, width: 100, height: 100),
                                     choice: nil)
        let item = PasteStep.makeHistoryItem(surface: surface(), plan: plan, state: start,
                                             expanded: nil, baseStepID: 0)
        var forward = start
        item.apply(to: &forward)
        // Scrolled so (0,0) is off-screen: origin = (7,5) (clamped); the outline clips
        // the (7,5,3,2) rect to the canvas.
        #expect(forward.selection?.bounds == PixelRect(x: 7, y: 5, width: 1, height: 1))
        item.revert(&forward)
        #expect(forward.image == start.image)
        #expect(forward.selection == start.selection)
        #expect(forward.floatingPixels == nil)
    }
}
