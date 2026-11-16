import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `PencilTool` through `FakeToolContext` (spec 0011 *Test plan*): the point → pixel
/// mapping, one-pixel clicks, Bresenham drags, binary coverage, TOOL-A colors including
/// alpha, the no-compounding stroke rule, commit/cancel/pending semantics, options, and
/// the crosshair-without-outline cursor (D-38).
@MainActor
struct PencilToolTests {
    /// The 16×16 opaque white canvas the spec's tests assume.
    private static let white = ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255)

    private func event(_ location: CGPoint, button: ToolMouseButton = .primary,
                       modifiers: ToolModifiers = []) -> ToolEvent {
        ToolEvent(location: location, viewLocation: .zero, button: button,
                  modifiers: modifiers, clickCount: 1, pressure: 1, timestamp: 0)
    }

    private func makeContext(width: Int = 16, height: Int = 16,
                             background: ColorRGBA8 = PencilToolTests.white)
        -> FakeToolContext {
        FakeToolContext(size: PixelSize(width: width, height: height), background: background)
    }

    private func pixel(_ context: FakeToolContext, _ x: Int, _ y: Int) -> ColorRGBA8 {
        context.image.layers[0].surface.pixel(at: PixelPoint(x: x, y: y))
    }

    /// Every pixel that differs from `background`.
    private func changedPoints(_ context: FakeToolContext,
                               background: ColorRGBA8) -> Set<PixelPoint> {
        var changed: Set<PixelPoint> = []
        let surface = context.image.layers[0].surface
        for y in 0 ..< context.image.size.height {
            for x in 0 ..< context.image.size.width
                where surface.pixel(at: PixelPoint(x: x, y: y)) != background {
                changed.insert(PixelPoint(x: x, y: y))
            }
        }
        return changed
    }

    private func points(_ pairs: [(Int, Int)]) -> Set<PixelPoint> {
        Set(pairs.map { PixelPoint(x: $0.0, y: $0.1) })
    }

    // MARK: - Point → pixel mapping

    @Test func pixelMapping() {
        #expect(PencilTool.pixel(for: CGPoint(x: 3.0, y: 4.0)) == PixelPoint(x: 3, y: 4))
        #expect(PencilTool.pixel(for: CGPoint(x: 2.999, y: 4.0)) == PixelPoint(x: 2, y: 4))
        #expect(PencilTool.pixel(for: CGPoint(x: -0.5, y: 0)) == PixelPoint(x: -1, y: 0))
        #expect(PencilTool.pixel(for: CGPoint(x: 1e12, y: -1e12))
                    == PixelPoint(x: 131_071, y: -65_536))
        #expect(PencilTool.pixel(for: CGPoint(x: CGFloat.nan, y: 1)) == nil)
        #expect(PencilTool.pixel(for: CGPoint(x: 1, y: CGFloat.nan)) == nil)
        #expect(PencilTool.pixel(for: CGPoint(x: CGFloat.infinity, y: 1)) == nil)
        #expect(PencilTool.pixel(for: CGPoint(x: 1, y: -CGFloat.infinity)) == nil)
    }

    // MARK: - Clicks and drags

    @Test func clickPaintsOnePixel() {
        let context = makeContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                                        secondary: .white)
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 3.5, y: 4.9)), context: context)
        tool.mouseUp(event(CGPoint(x: 3.5, y: 4.9)), context: context)
        #expect(pixel(context, 3, 4) == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255))
        #expect(changedPoints(context, background: Self.white)
                    == points([(3, 4)]), "exactly the one pixel under the cursor")
    }

    @Test func borderMapping() {
        let first = makeContext()
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 3.0, y: 4.0)), context: first)
        tool.mouseUp(event(CGPoint(x: 3.0, y: 4.0)), context: first)
        #expect(changedPoints(first, background: Self.white) == points([(3, 4)]),
                "a point exactly on a pixel border belongs to the pixel starting there")

        let second = makeContext()
        let other = PencilTool()
        other.mouseDown(event(CGPoint(x: 2.999, y: 4.0)), context: second)
        other.mouseUp(event(CGPoint(x: 2.999, y: 4.0)), context: second)
        #expect(changedPoints(second, background: Self.white) == points([(2, 4)]))
    }

    @Test func dragPaintsBresenhamUnion() {
        let context = makeContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                                        secondary: .white)
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 0.5, y: 0.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 5.5, y: 2.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 5.5, y: 6.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 5.5, y: 6.5)), context: context)
        // PixelLine(0,0→5,2) ∪ PixelLine(5,2→5,6), hand-listed from the spec.
        #expect(changedPoints(context, background: Self.white) == points([
            (0, 0), (1, 0), (2, 1), (3, 1), (4, 2), (5, 2),
            (5, 3), (5, 4), (5, 5), (5, 6),
        ]))
    }

    @Test func noAntialiasing() {
        let context = makeContext()
        let black = ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255)
        context.colors = ColorSelection(primary: black, secondary: .white)
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 1.5, y: 1.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 12.5, y: 9.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 12.5, y: 9.5)), context: context)
        // Binary coverage: every pixel is exactly the stroke result or exactly untouched —
        // never an in-between blend.
        let surface = context.image.layers[0].surface
        for y in 0 ..< 16 {
            for x in 0 ..< 16 {
                let value = surface.pixel(at: PixelPoint(x: x, y: y))
                #expect(value == black || value == Self.white, "aliased pixel (\(x), \(y))")
            }
        }
    }

    // MARK: - Colors (TOOL-A) and alpha behavior

    @Test func primaryAndSecondary() {
        let context = makeContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255),
                                        secondary: ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255))
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 1.5, y: 1.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 1.5, y: 1.5)), context: context)
        #expect(pixel(context, 1, 1) == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255),
                "left click paints the primary color")

        tool.mouseDown(event(CGPoint(x: 2.5, y: 2.5), button: .secondary), context: context)
        tool.mouseUp(event(CGPoint(x: 2.5, y: 2.5), button: .secondary), context: context)
        #expect(pixel(context, 2, 2) == ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255),
                "right click paints the secondary color")

        tool.mouseDown(event(CGPoint(x: 3.5, y: 3.5), modifiers: [.control]), context: context)
        tool.mouseUp(event(CGPoint(x: 3.5, y: 3.5), modifiers: [.control]), context: context)
        #expect(pixel(context, 3, 3) == ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255),
                "Control-left (delivered as .secondary) paints the secondary color")
    }

    @Test func semiTransparentOverWhite() {
        let context = makeContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 128),
                                        secondary: .white)
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 5.5, y: 5.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 5.5, y: 5.5)), context: context)
        // Source-over against the stroke-start pixel: α = 128 + 255×127/255 = 255;
        // G = B = 255×127/255 = 127; R = (255×128 + 255×127)/255 = 255.
        #expect(pixel(context, 5, 5) == ColorRGBA8(red: 255, green: 127, blue: 127, alpha: 255))
    }

    @Test func onTransparent() {
        let context = makeContext(background: .clear)
        context.colors = ColorSelection(primary: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 128),
                                        secondary: .white)
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 4.5, y: 4.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 4.5, y: 4.5)), context: context)
        #expect(pixel(context, 4, 4) == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 128))
    }

    @Test func selfCrossingDoesNotCompound() {
        let context = makeContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 128),
                                        secondary: .white)
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 0.5, y: 0.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 5.5, y: 0.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 0.5, y: 0.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 0.5, y: 0.5)), context: context)
        // The line runs back over itself: each pixel composes once from its before-stroke
        // value ("as if on its own layer"), so all six are the single-paint result.
        for x in 0 ... 5 {
            #expect(pixel(context, x, 0) == ColorRGBA8(red: 255, green: 127, blue: 127, alpha: 255),
                    "pixel (\(x), 0) not darker at the crossing")
        }
    }

    @Test func samePixelDragIsNoOp() {
        let context = makeContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                                        secondary: .white)
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 4.2, y: 4.2)), context: context)
        for index in 0 ..< 50 {
            tool.mouseDragged(event(CGPoint(x: 4.0 + Double(index % 9) / 10.0,
                                            y: 4.3 + Double(index % 6) / 100.0)),
                              context: context)
        }
        tool.mouseUp(event(CGPoint(x: 4.9, y: 4.1)), context: context)
        #expect(changedPoints(context, background: Self.white) == points([(4, 4)]),
                "50 drags inside one pixel mark exactly one pixel")
    }

    @Test func nonFiniteIgnored() {
        let black = ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255)
        let plain = makeContext()
        plain.colors = ColorSelection(primary: black, secondary: .white)
        let toolA = PencilTool()
        toolA.mouseDown(event(CGPoint(x: 0.5, y: 1.5)), context: plain)
        toolA.mouseDragged(event(CGPoint(x: 3.5, y: 1.5)), context: plain)
        toolA.mouseDragged(event(CGPoint(x: 7.5, y: 1.5)), context: plain)
        toolA.mouseUp(event(CGPoint(x: 7.5, y: 1.5)), context: plain)

        let polluted = makeContext()
        polluted.colors = ColorSelection(primary: black, secondary: .white)
        let toolB = PencilTool()
        toolB.mouseDown(event(CGPoint(x: 0.5, y: 1.5)), context: polluted)
        toolB.mouseDragged(event(CGPoint(x: 3.5, y: 1.5)), context: polluted)
        toolB.mouseDragged(event(CGPoint(x: CGFloat.nan, y: 3)), context: polluted)
        toolB.mouseDragged(event(CGPoint(x: CGFloat.infinity, y: 3)), context: polluted)
        toolB.mouseDragged(event(CGPoint(x: 7.5, y: 1.5)), context: polluted)
        toolB.mouseUp(event(CGPoint(x: 7.5, y: 1.5)), context: polluted)

        // Fresh contexts mint fresh layer IDs — compare pixels, not the images.
        var identical = true
        for y in 0 ..< 16 {
            for x in 0 ..< 16 where plain.image.layers[0].surface.pixel(at: PixelPoint(x: x, y: y))
                != polluted.image.layers[0].surface.pixel(at: PixelPoint(x: x, y: y)) {
                identical = false
            }
        }
        #expect(identical, "NaN/∞ events are pure no-ops")
        #expect(polluted.history.steps.map(\.name) == plain.history.steps.map(\.name))
    }

    /// The "own layer" boundary is one stroke: a SECOND mouse-down snapshots the layer
    /// again, so a semi-transparent color composes a second time over the first stroke's
    /// result (every stroke behaves as if it were on its own layer, Pencil.html).
    @Test func secondStrokeRepaintsOverFirstResult() {
        let context = makeContext()
        let redHalf = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 128)
        context.colors = ColorSelection(primary: redHalf, secondary: .white)
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 5.5, y: 5.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 5.5, y: 5.5)), context: context)
        #expect(pixel(context, 5, 5) == ColorRGBA8(red: 255, green: 127, blue: 127, alpha: 255))
        tool.mouseDown(event(CGPoint(x: 5.5, y: 5.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 5.5, y: 5.5)), context: context)
        // Source-over of red@128 onto (255,127,127,255): fa = 128×255 + 255×127 = 65025,
        // outA = 255, R = (255·128·255 + 255·255·127 + 32512)/65025 = 255,
        // G = B = (127·255·127 + 32512)/65025 = 63.
        #expect(pixel(context, 5, 5) == ColorRGBA8(red: 255, green: 63, blue: 63, alpha: 255),
                "the second stroke composes onto the first stroke's result")
        #expect(context.history.steps.map(\.name) == ["New Image", "Pencil", "Pencil"],
                "two strokes, two steps")
    }

    @Test func secondMouseDownIsIgnored() {
        let context = makeContext()
        context.colors = ColorSelection(
            primary: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255),
            secondary: ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255))
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 1.5, y: 1.5)), context: context)
        // A second button pressed mid-stroke must not restart the stroke or switch color.
        tool.mouseDown(event(CGPoint(x: 5.5, y: 5.5), button: .secondary), context: context)
        tool.mouseDragged(event(CGPoint(x: 3.5, y: 3.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 3.5, y: 3.5)), context: context)
        #expect(changedPoints(context, background: Self.white)
                    == points([(1, 1), (2, 2), (3, 3)]),
                "the ignored mouse-down painted nothing and the stroke continued")
        #expect(pixel(context, 5, 5) == Self.white, "no secondary color appeared")
        #expect(context.history.steps.map(\.name) == ["New Image", "Pencil"],
                "one stroke, one step")
    }

    // MARK: - Canvas bounds, tiles, clip

    @Test func crossesTileBoundary() throws {
        let context = makeContext(width: 512, height: 512)
        context.colors = ColorSelection(primary: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                                        secondary: .white)
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 250.5, y: 10.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 260.5, y: 10.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 260.5, y: 10.5)), context: context)
        for x in 250 ... 260 {
            #expect(pixel(context, x, 10) == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                    "pixel (\(x), 10) painted")
        }
        let item = try #require(context.history.steps[1].item as? TileDiffHistoryItem)
        #expect(Set(item.diff.entries.map(\.coordinate))
                    == Set([TileCoordinate(column: 0, row: 0), TileCoordinate(column: 1, row: 0)]),
                "the diff records exactly the two touched tiles")
    }

    @Test func leavesAndReentersCanvas() {
        let context = makeContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                                        secondary: .white)
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 2.5, y: 2.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: -10.5, y: 2.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 8.5, y: 2.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 8.5, y: 2.5)), context: context)
        // The line runs through off-canvas integer space; only in-canvas pixels are painted.
        #expect(changedPoints(context, background: Self.white)
                    == points((0 ... 8).map { ($0, 2) }))
    }

    /// A test clip that lets only `x < 3` through (0013 will pass the selection mask here).
    private struct ClipLeftThree: BrushClipMask {
        let bounds = PixelRect(x: 0, y: 0, width: 16, height: 16)
        func coverage(x: Int, y: Int) -> UInt8 { x < 3 ? 255 : 0 }
    }

    @Test func respectsClipHook() {
        let context = makeContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                                        secondary: .white)
        context.paintClipMask = ClipLeftThree()
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 0.5, y: 0.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 6.5, y: 0.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 6.5, y: 0.5)), context: context)
        #expect(changedPoints(context, background: Self.white)
                    == points([(0, 0), (1, 0), (2, 0)]), "only the clip-allowed pixels")
    }

    // MARK: - History semantics (H-6)

    @Test func emptyStrokeAddsNoStep() {
        let transparentColor = ColorSelection(
            primary: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 0), secondary: .white)

        let onCanvas = makeContext()
        onCanvas.colors = transparentColor
        let alphaTool = PencilTool()
        alphaTool.mouseDown(event(CGPoint(x: 5.5, y: 5.5)), context: onCanvas)
        alphaTool.mouseUp(event(CGPoint(x: 5.5, y: 5.5)), context: onCanvas)
        #expect(onCanvas.history.steps.map(\.name) == ["New Image"],
                "an alpha-0 pencil color changes nothing → no step")
        #expect(onCanvas.image.layers[0].surface.pixel(at: PixelPoint(x: 5, y: 5)) == Self.white)

        let offCanvas = makeContext()
        offCanvas.colors = ColorSelection(primary: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                                          secondary: .white)
        let offTool = PencilTool()
        offTool.mouseDown(event(CGPoint(x: -5.5, y: 3.5)), context: offCanvas)
        offTool.mouseDragged(event(CGPoint(x: -2.5, y: 3.5)), context: offCanvas)
        offTool.mouseUp(event(CGPoint(x: -1.5, y: 3.5)), context: offCanvas)
        #expect(offCanvas.history.steps.map(\.name) == ["New Image"],
                "a stroke entirely at x < 0 records nothing")
    }

    @Test func cancelMidStrokeRestores() {
        let context = makeContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                                        secondary: .white)
        let baseline = context.image
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 2.5, y: 2.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 9.5, y: 6.5)), context: context)
        #expect(tool.hasPendingEdit)
        tool.cancel(context: context)
        #expect(context.image == baseline, "pixel-identical to before the stroke")
        #expect(context.history.steps.map(\.name) == ["New Image"], "no step")
        #expect(!tool.hasPendingEdit)
    }

    @Test func deactivateMidStrokeCommits() {
        let context = makeContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                                        secondary: .white)
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 2.5, y: 2.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 9.5, y: 6.5)), context: context)
        tool.deactivate(context: context)
        #expect(context.history.steps.map(\.name) == ["New Image", "Pencil"],
                "exactly one step")
    }

    @Test func historyName() {
        let context = makeContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                                        secondary: .white)
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 6.5, y: 6.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 6.5, y: 6.5)), context: context)
        #expect(context.history.steps.count == 2)
        #expect(context.history.steps[1].name == "Pencil")
        #expect(context.history.steps[1].icon == .pencil)
    }

    @Test func undoRedo() {
        let context = makeContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                                        secondary: .white)
        let preStroke = context.image
        let tool = PencilTool()
        tool.mouseDown(event(CGPoint(x: 1.5, y: 1.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 12.5, y: 13.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 12.5, y: 13.5)), context: context)
        let postStroke = context.image

        context.navigateForTests { history, state in _ = history.undo(&state) }
        #expect(context.image == preStroke, "undo restores the exact stroke-start pixels")

        context.navigateForTests { history, state in _ = history.redo(&state) }
        #expect(context.image == postStroke, "redo restores the exact stroke result")
    }

    // MARK: - Options and cursor

    @Test func optionsAndPersistence() {
        let context = makeContext()
        #expect(PencilTool.blendModeKey.defaultsKey == "tool.pencil.blendMode")
        #expect(context.options.value(PencilTool.blendModeKey) == .normal, "default Normal")
        #expect(PencilTool.selectableBlendModes == BlendMode.allCases,
                "the offered list equals the Paintbrush's (D-15)")

        context.options.setValue(BlendMode.normal, for: PencilTool.blendModeKey)
        #expect(context.memoryOptions.storedValue(forKey: "tool.pencil.blendMode") as? String
                    == "normal")
        // A new tool over the same store reads the option back at mouse-down.
        context.colors = ColorSelection(primary: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                                        secondary: .white)
        let second = PencilTool()
        second.mouseDown(event(CGPoint(x: 2.5, y: 2.5)), context: context)
        second.mouseUp(event(CGPoint(x: 2.5, y: 2.5)), context: context)
        #expect(pixel(context, 2, 2) == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                "the re-read stroke painted with the re-read option")
    }

    @Test func bracketKeysIgnored() {
        let context = makeContext()
        let tool = PencilTool()
        // 0009's router only steps the width for tools conforming to `BrushWidthAdjustable`;
        // the Pencil must not, so `[`/`]` find nothing to change (no beep, no crash).
        #expect(!(tool is any BrushWidthAdjustable))
        context.colors = ColorSelection(primary: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                                        secondary: .white)
        tool.mouseDown(event(CGPoint(x: 3.5, y: 3.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 3.5, y: 3.5)), context: context)
        // The Pencil writes no width/hardness/antialiasing key — the blend mode is its
        // only option (T-13).
        #expect(context.memoryOptions.storedValue(forKey: "tool.pencil.width") == nil)
        #expect(context.memoryOptions.storedValue(forKey: "tool.pencil.hardness") == nil)
        #expect(context.memoryOptions.storedValue(forKey: "tool.pencil.antialiasing") == nil)
    }

    @Test func cursorIsCrosshairWithoutOutline() {
        let context = makeContext()
        let tool = PencilTool()
        #expect(tool.cursor(at: CGPoint(x: 1, y: 1), modifiers: []) == .crosshair)
        #expect(tool.cursor(at: nil, modifiers: []) == .arrow)
        context.colors = ColorSelection(primary: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                                        secondary: .white)
        tool.mouseMoved(event(CGPoint(x: 4.5, y: 4.5)), context: context)
        tool.mouseDown(event(CGPoint(x: 4.5, y: 4.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 8.5, y: 4.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 8.5, y: 4.5)), context: context)
        #expect(context.overlays.isEmpty, "the Pencil never sets an overlay (D-38)")
    }
}
