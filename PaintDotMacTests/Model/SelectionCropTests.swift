import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `SelectionMask.cropped(to:)` and `Selection.translatedAndCropped(to:)` (spec 0022,
/// extending 0013). Expected values are hand-written.
struct SelectionCropTests {
    private static let small = PixelSize(width: 6, height: 6)

    /// The hand coverage table from `CropToSelectionTests.nonRectangularMaskHandValues`.
    private func handMask() -> SelectionMask {
        SelectionMask(size: Self.small) { x, y in
            if x == 1, y == 1 { 255 }
            else if x == 3, y == 2 { 128 }
            else if x == 2, y == 4 { 1 }
            else { 0 }
        }
    }

    @Test func maskCroppedHandValues() {
        let cropped = handMask().cropped(to: PixelRect(x: 1, y: 1, width: 3, height: 4))
        #expect(cropped.size == PixelSize(width: 3, height: 4))
        #expect(cropped.coverage(x: 0, y: 0) == 255)
        #expect(cropped.coverage(x: 2, y: 1) == 128)
        #expect(cropped.coverage(x: 1, y: 3) == 1)
        var onlyThose = true
        for y in 0..<4 {
            for x in 0..<3 {
                let expected: UInt8 = switch (x, y) {
                case (0, 0): 255
                case (2, 1): 128
                case (1, 3): 1
                default: 0
                }
                if cropped.coverage(x: x, y: y) != expected { onlyThose = false }
            }
        }
        #expect(onlyThose, "every other coverage is 0")
        #expect(cropped.bounds == PixelRect(x: 0, y: 0, width: 3, height: 4))
    }

    private func storage(_ tile: SelectionMaskTile) -> SelectionMaskTileStorage? {
        if case .partial(let storage) = tile { storage } else { nil }
    }

    @Test func maskCroppedReusesAlignedTiles() throws {
        // Tile (1, 1) of a 600×600 mask is `.partial` (a 64-px checkerboard); the aligned
        // crop (256, 256, 300, 256) keeps it as destination tile (0, 0) — same storage.
        let mask = SelectionMask(size: PixelSize(width: 600, height: 600)) { x, y in
            x >= 256 && x < 512 && y >= 256 && y < 512
                ? (x / 64 + y / 64).isMultiple(of: 2) ? 255 : 0
                : 0
        }
        let source = try #require(storage(mask.tiles[1 * 3 + 1]))
        let cropped = mask.cropped(to: PixelRect(x: 256, y: 256, width: 300, height: 256))
        let destination = try #require(storage(cropped.tiles[0]))
        #expect(destination === source, "aligned full destination tile reuses the storage")
        #expect(cropped.tileStorageIdentities.keys.contains(ObjectIdentifier(source)))
        #expect(mask.tileStorageIdentities.keys.contains(ObjectIdentifier(source)))
    }

    @Test func maskCroppedNormalizesFull() {
        // Left 100 columns unselected, everything right of x = 100 covered: source tile
        // (0, 0) is `.partial`, but the crop starting at x = 100 is all-255.
        let mask = SelectionMask(size: PixelSize(width: 600, height: 600)) { x, _ in
            x >= 100 ? 255 : 0
        }
        let cropped = mask.cropped(to: PixelRect(x: 100, y: 0, width: 400, height: 300))
        #expect(cropped.isFull)
        for tile in cropped.tiles {
            if case .full = tile { continue }
            Issue.record("tile not normalized to .full: \(tile)")
        }
    }

    @Test func maskCroppedEdgeOutOfCanvasZero() {
        let mask = SelectionMask.full(size: PixelSize(width: 600, height: 600))
        let cropped = mask.cropped(to: PixelRect(x: 0, y: 0, width: 300, height: 257))
        #expect(cropped.size == PixelSize(width: 300, height: 257))
        #expect(cropped.coverage(x: 299, y: 256) == 255)
        #expect(cropped.coverage(x: 0, y: 256) == 255)
        #expect(cropped.coverage(x: 300, y: 0) == 0, "out of canvas reads 0")
        #expect(cropped.coverage(x: 0, y: 257) == 0)
        #expect(cropped.isFull)
    }

    @Test func selectionTranslatedPath() throws {
        let selection = try #require(Selection(
            mask: .full(size: PixelSize(width: 100, height: 100)),
            outline: CGPath(rect: CGRect(x: 10, y: 20, width: 30, height: 40), transform: nil)))
        let cropped = try #require(selection.translatedAndCropped(to: PixelRect(x: 5, y: 5,
                                                                                width: 90, height: 90)))
        #expect(cropped.canvasSize == PixelSize(width: 90, height: 90))
        #expect(cropped.path.boundingBoxOfPath == CGRect(x: 5, y: 15, width: 30, height: 40))
        #expect(cropped.mask.isFull)
    }

    @Test func croppedToEmptyIsNil() throws {
        let mask = SelectionMask(size: PixelSize(width: 100, height: 100)) { x, y in
            x < 10 && y < 10 ? 255 : 0
        }
        let selection = try #require(Selection(
            mask: mask, outline: CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                        transform: nil)))
        #expect(selection.translatedAndCropped(to: PixelRect(x: 50, y: 50, width: 20, height: 20)) == nil)
    }
}
