import Foundation
import Testing

@testable import PaintDotMac

/// `SelectionHistoryItem` (spec 0013): selection-only steps that never touch pixels.
struct SelectionHistoryItemTests {
    private func whiteImage(_ side: Int = 512) -> LayeredImage {
        var surface = TiledSurface(size: PixelSize(width: side, height: side))
        surface.fill(.white)
        return LayeredImage(surface: surface)
    }

    private func rectSelection(_ rect: PixelRect, canvas: Int = 512) -> Selection {
        Selection(rect: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                  canvasSize: PixelSize(width: canvas, height: canvas))!
    }

    @Test func applyRevert() throws {
        let a = rectSelection(PixelRect(x: 10, y: 10, width: 50, height: 50))
        let b = Selection.all(canvasSize: PixelSize(width: 512, height: 512))
        let image = whiteImage()
        var state = DocumentState(image: image, selection: a)
        let tileBefore = try #require(image.layers[0].surface.tile(at: TileCoordinate(column: 0, row: 0)))
        let item = SelectionHistoryItem(name: "Rectangle Select", icon: .rectangleSelect,
                                        before: a, after: b)
        item.apply(to: &state)
        #expect(state.selection == b)
        let tileAfter = try #require(state.image.layers[0].surface
            .tile(at: TileCoordinate(column: 0, row: 0)))
        #expect(tileAfter.sharesStorage(with: tileBefore), "apply touches no pixels")
        item.revert(&state)
        #expect(state.selection == a)
        #expect(state.image == image)
    }

    @Test func noOpWhenEqual() {
        let a = rectSelection(PixelRect(x: 10, y: 10, width: 50, height: 50))
        #expect(SelectionHistoryItem(name: "Select All", icon: .selectAll,
                                     before: a, after: a).isNoOp)
        #expect(SelectionHistoryItem(name: "Deselect", icon: .deselect,
                                     before: nil, after: nil).isNoOp)
        #expect(!SelectionHistoryItem(name: "Deselect", icon: .deselect,
                                      before: a, after: nil).isNoOp)
    }

    @Test func changeIsSelection() {
        let a = rectSelection(PixelRect(x: 10, y: 10, width: 50, height: 50))
        #expect(SelectionHistoryItem(name: "Select All", icon: .selectAll,
                                     before: nil, after: a).change == .selection)
    }

    @Test func byteCostMatchesHistoryCost() {
        let a = rectSelection(PixelRect(x: 10, y: 10, width: 50, height: 50))
        let b = Selection.all(canvasSize: PixelSize(width: 512, height: 512))
        let item = SelectionHistoryItem(name: "Invert Selection", icon: .invertSelection,
                                        before: a, after: b)
        #expect(item.byteCost == HistoryCost.selectionBytes(before: a, after: b))
    }
}
