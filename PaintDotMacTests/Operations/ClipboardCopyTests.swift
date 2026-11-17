import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `ClipboardCopy` — Copy (whole layer / selection with coverage-weighted alpha) and Cut
/// (Copy + 0018's Erase Selection + deselect, one "Cut" step) (spec 0021 *Test plan*).
struct ClipboardCopyTests {
    private func patternSurface(width: Int, height: Int) -> TiledSurface {
        TestImages.surface(width: width, height: height) { x, y in
            ColorRGBA8(red: UInt8(x % 256), green: UInt8(y % 256), blue: UInt8((x &+ y) % 256),
                       alpha: 255)
        }
    }

    /// A seeded 300×300 layer (crosses a tile edge) including alpha-0 pixels with a real
    /// color (FMT-B: the color must survive Copy).
    private func seededSurface(seed: UInt64 = 77) -> TiledSurface {
        var rng = SeededRandom(seed: seed)
        return TestImages.surface(width: 300, height: 300) { _, _ in
            var color = rng.color()
            if color.alpha == 0 { color = ColorRGBA8(red: color.red, green: color.green,
                                                     blue: color.blue, alpha: 0) }
            return color
        }
    }

    @Test func copyWithoutSelectionCopiesWholeLayer() {
        let surface = seededSurface()
        let state = DocumentState(image: LayeredImage(surface: surface))
        let copied = ClipboardCopy.copiedSurface(from: state)
        #expect(copied.size == surface.size)
        #expect(copied.readPixels(in: copied.bounds) == surface.readPixels(in: surface.bounds),
                "pixel-exact, alpha-0 colors included")
    }

    @Test func copyRectSelection() throws {
        let surface = patternSurface(width: 600, height: 400)
        let selection = try #require(Selection(rect: CGRect(x: 250, y: 100, width: 20, height: 30),
                                               canvasSize: surface.size, antialiased: false))
        let state = DocumentState(image: LayeredImage(surface: surface), selection: selection)
        let copied = ClipboardCopy.copiedSurface(from: state)
        #expect(copied.size == PixelSize(width: 20, height: 30))
        #expect(copied.pixel(at: .zero) == surface.pixel(at: PixelPoint(x: 250, y: 100)))
        #expect(copied.pixel(at: PixelPoint(x: 19, y: 29))
                == surface.pixel(at: PixelPoint(x: 269, y: 129)))
    }

    @Test func copyEllipseWeightsAlphaByCoverage() throws {
        let surface = TestImages.surface(width: 64, height: 64) { _, _ in
            ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 255)
        }
        let ellipse = CGMutablePath()
        ellipse.addEllipse(in: CGRect(x: 8, y: 8, width: 48, height: 40))
        let selection = try #require(Selection(path: ellipse, canvasSize: surface.size))
        let state = DocumentState(image: LayeredImage(surface: surface), selection: selection)
        let copied = ClipboardCopy.copiedSurface(from: state)
        #expect(copied.size == selection.bounds.size)
        let mask = selection.mask
        for y in 0..<copied.size.height {
            for x in 0..<copied.size.width {
                let coverage = mask.coverage(x: selection.bounds.minX + x,
                                             y: selection.bounds.minY + y)
                let pixel = copied.pixel(at: PixelPoint(x: x, y: y))
                if coverage == 0 {
                    #expect(pixel == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0),
                            "(\(x), \(y)) outside the mask")
                } else {
                    // 0009's rounding rule, applied independently.
                    let t = UInt32(255) * UInt32(coverage) + 128
                    let expectedAlpha = UInt8(((t >> 8) + t) >> 8)
                    #expect(pixel.alpha == expectedAlpha, "(\(x), \(y)) mul255(255, \(coverage))")
                    #expect(pixel.alpha == BlendOps.mul255(255, coverage))
                    #expect(ColorRGBA8(red: pixel.red, green: pixel.green, blue: pixel.blue, alpha: 255)
                            == ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 255),
                            "(\(x), \(y)) keeps the RGB")
                }
            }
        }
    }

    @Test func semiTransparentSourceTimesCoverage() throws {
        let size = PixelSize(width: 4, height: 4)
        let surface = TestImages.surface(width: 4, height: 4) { _, _ in
            ColorRGBA8(red: 9, green: 9, blue: 9, alpha: 128)
        }
        // A uniform half-coverage mask (the builder 0016 uses).
        let mask = SelectionMask(size: size) { _, _ in 128 }
        let selection = try #require(Selection(mask: mask, outline: CGPath(rect: CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height)), transform: nil)))
        let state = DocumentState(image: LayeredImage(surface: surface), selection: selection)
        let copied = ClipboardCopy.copiedSurface(from: state)
        #expect(copied.pixel(at: .zero)
                == ColorRGBA8(red: 9, green: 9, blue: 9, alpha: BlendOps.mul255(128, 128)))
        #expect(BlendOps.mul255(128, 128) == 64, "the 0009 rounding rule")
    }

    @Test func copyDoesNotChangeDocument() throws {
        let surface = seededSurface(seed: 21)
        let selection = try #require(Selection(rect: CGRect(x: 40, y: 40, width: 100, height: 100),
                                               canvasSize: PixelSize(width: 300, height: 300)))
        let state = DocumentState(image: LayeredImage(surface: surface), selection: selection)
        let before = state
        _ = ClipboardCopy.copiedSurface(from: state)
        #expect(state == before, "Copy is pure: pixels and selection untouched")
    }

    // MARK: - Cut

    private func cutFixture() throws -> (DocumentState, Selection) {
        let surface = patternSurface(width: 100, height: 90)
        let selection = try #require(Selection(rect: CGRect(x: 10, y: 10, width: 30, height: 25),
                                               canvasSize: surface.size, antialiased: false))
        return (DocumentState(image: LayeredImage(surface: surface), selection: selection), selection)
    }

    @Test func cutErasesAndDeselects() throws {
        let (state, selection) = try cutFixture()
        let (surface, item) = try #require(ClipboardCopy.cut(state))
        #expect(surface.readPixels(in: surface.bounds)
                == ClipboardCopy.copiedSurface(from: state).readPixels(in: surface.bounds),
                "Cut's clipboard surface equals Copy's")
        #expect(item.name == "Cut")
        #expect(item.icon == .cut)
        #expect(item.isNoOp == false)

        var after = state
        item.apply(to: &after)
        let layer = after.image.layers[0]
        // Selected region: exactly 0018's Erase Selection on the same state.
        let expected = EraseSelection.erase(state.image.layers[0].surface, mask: selection.mask).surface
        TestImages.expectPixels(layer.surface, match: { x, y in
            expected.pixel(at: PixelPoint(x: x, y: y))
        }, "Cut erases like Erase Selection")
        #expect(layer.surface.pixel(at: PixelPoint(x: 20, y: 20))
                == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0), "opaque → (0,0,0,0)")
        // Pixels outside the selection are untouched (selection bounds are (10,10,30,25)).
        #expect(layer.surface.pixel(at: PixelPoint(x: 9, y: 40))
                == state.image.layers[0].surface.pixel(at: PixelPoint(x: 9, y: 40)))
        #expect(after.selection == nil, "the selection is cleared")
    }

    @Test func cutOfTransparentRegionIsStillAStep() throws {
        let surface = TiledSurface(size: PixelSize(width: 40, height: 40))  // all (0,0,0,0)
        let selection = try #require(Selection(rect: CGRect(x: 4, y: 4, width: 12, height: 12),
                                               canvasSize: surface.size))
        let state = DocumentState(image: LayeredImage(surface: surface), selection: selection)
        let item = try #require(ClipboardCopy.cut(state)?.item)
        #expect(item.isNoOp == false, "the deselect makes the step non-empty (H-6)")
        var after = state
        item.apply(to: &after)
        #expect(after.selection == nil)
    }

    @Test func cutUndoRedo() throws {
        let (state, _) = try cutFixture()
        let item = try #require(ClipboardCopy.cut(state)?.item)
        var history = HistoryStack(base: .openImage)
        var live = state
        history.perform(item, on: &live)
        #expect(history.steps.map(\.name) == ["Open Image", "Cut"])
        _ = history.undo(&live)
        #expect(live == state, "undo restores pixels and selection exactly")
        _ = history.redo(&live)
        var expected = state
        item.apply(to: &expected)
        #expect(live == expected, "redo re-applies exactly")
    }

    @Test func cutWithoutSelectionIsNil() {
        let surface = patternSurface(width: 40, height: 40)
        #expect(ClipboardCopy.cut(DocumentState(image: LayeredImage(surface: surface))) == nil)
    }
}
