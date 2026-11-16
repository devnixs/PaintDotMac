import Testing
@testable import PaintDotMac

/// `SelectionSizeDisplay.size` (spec 0014 *Test plan*): the live preview wins (clipped),
/// then the committed selection bounds, else nothing.
struct SelectionSizeDisplayTests {
    private let image = PixelSize(width: 100, height: 80)

    private func preview(_ rect: PixelRect) -> SelectionShapePreview {
        SelectionShapePreview(shape: .rectangle, rect: rect, hidesCurrentSelection: true)
    }

    @Test func previewWinsAndClips() {
        #expect(SelectionSizeDisplay.size(
            preview: preview(PixelRect(x: 90, y: 70, width: 30, height: 30)),
            selectionBounds: PixelRect(x: 0, y: 0, width: 5, height: 5),
            imageSize: image) == PixelSize(width: 10, height: 10))
    }

    @Test func previewFullyOutsideIsNil() {
        #expect(SelectionSizeDisplay.size(
            preview: preview(PixelRect(x: 200, y: 200, width: 10, height: 10)),
            selectionBounds: PixelRect(x: 0, y: 0, width: 5, height: 5),
            imageSize: image) == nil)
    }

    @Test func boundsWithoutPreview() {
        #expect(SelectionSizeDisplay.size(preview: nil,
                                          selectionBounds: PixelRect(x: 1, y: 2, width: 3, height: 4),
                                          imageSize: image) == PixelSize(width: 3, height: 4))
    }

    @Test func nothingSelected() {
        #expect(SelectionSizeDisplay.size(preview: nil, selectionBounds: nil,
                                          imageSize: image) == nil)
    }
}
