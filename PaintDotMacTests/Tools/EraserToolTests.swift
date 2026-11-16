import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `EraserTool` through `FakeToolContext` (spec 0011 *Test plan*): strength from the
/// color slot (T-12), the BrushEngine-given shape (0009), the destination-out pixel rule
/// on real strokes, per-tool option persistence (TOOL-C), `[`/`]` stepping, the brush
/// outline (D-38), and commit/cancel semantics (H-6).
@MainActor
struct EraserToolTests {
    /// The 64×64 opaque `(200,100,50,255)` canvas the spec's tests assume.
    private static let base = ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 255)

    private func event(_ location: CGPoint, button: ToolMouseButton = .primary,
                       modifiers: ToolModifiers = []) -> ToolEvent {
        ToolEvent(location: location, viewLocation: .zero, button: button,
                  modifiers: modifiers, clickCount: 1, pressure: 1, timestamp: 0)
    }

    private func makeContext(width: Int = 64, height: Int = 64) -> FakeToolContext {
        FakeToolContext(size: PixelSize(width: width, height: height), background: Self.base)
    }

    private func pixel(_ context: FakeToolContext, _ x: Int, _ y: Int) -> ColorRGBA8 {
        context.image.layers[0].surface.pixel(at: PixelPoint(x: x, y: y))
    }

    /// Sets this Eraser's options through the store (the tool re-reads at mouse-down).
    private func setOptions(_ context: FakeToolContext, width: Double? = nil,
                            hardness: Int? = nil, antialiasing: Bool? = nil) {
        let keys = BrushOptions.keys(for: .eraser)
        if let width { context.options.setValue(width, for: keys.width) }
        if let hardness { context.options.setValue(hardness, for: keys.hardness) }
        if let antialiasing { context.options.setValue(antialiasing, for: keys.antialiasing) }
    }

    // MARK: - Shape and pixel rule

    @Test func aliasedHardPixel() {
        let context = makeContext()
        setOptions(context, width: 1, antialiasing: false)
        let tool = EraserTool()
        tool.mouseDown(event(CGPoint(x: 10.5, y: 10.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 10.5, y: 10.5)), context: context)
        #expect(pixel(context, 10, 10) == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0),
                "fully erased → (0,0,0,0)")
        var onlyOne = true
        for y in 0 ..< 64 {
            for x in 0 ..< 64 where x != 10 || y != 10 {
                if pixel(context, x, y) != Self.base { onlyOne = false }
            }
        }
        #expect(onlyOne, "the aliased width-1 footprint is exactly one pixel")
    }

    @Test func strengthFromColorSlot() {
        let context = makeContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 9, green: 9, blue: 9, alpha: 60),
                                        secondary: ColorRGBA8(red: 9, green: 9, blue: 9, alpha: 120))
        setOptions(context, width: 5, antialiasing: false)
        let tool = EraserTool()
        tool.mouseDown(event(CGPoint(x: 10.5, y: 10.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 10.5, y: 10.5)), context: context)
        #expect(pixel(context, 10, 10) == ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 195),
                "primary alpha 60 → 255 − 60 = 195; RGB irrelevant")

        tool.mouseDown(event(CGPoint(x: 30.5, y: 30.5), button: .secondary), context: context)
        tool.mouseUp(event(CGPoint(x: 30.5, y: 30.5), button: .secondary), context: context)
        #expect(pixel(context, 30, 30) == ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 135),
                "secondary alpha 120 → 135")

        tool.mouseDown(event(CGPoint(x: 50.5, y: 50.5), modifiers: [.control]), context: context)
        tool.mouseUp(event(CGPoint(x: 50.5, y: 50.5), modifiers: [.control]), context: context)
        #expect(pixel(context, 50, 50) == ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 135),
                "Control-left (delivered as .secondary) uses the secondary slot")
    }

    @Test func aliasedIgnoresHardness() {
        func erased(hardness: Int) -> TiledSurface {
            let context = makeContext()
            setOptions(context, width: 9, hardness: hardness, antialiasing: false)
            let tool = EraserTool()
            tool.mouseDown(event(CGPoint(x: 32.5, y: 32.5)), context: context)
            tool.mouseDragged(event(CGPoint(x: 40.5, y: 32.5)), context: context)
            tool.mouseUp(event(CGPoint(x: 40.5, y: 32.5)), context: context)
            return context.image.layers[0].surface
        }
        let soft = erased(hardness: 0), hard = erased(hardness: 100)
        var identical = true
        for y in 0 ..< 64 {
            for x in 0 ..< 64 where soft.pixel(at: PixelPoint(x: x, y: y))
                != hard.pixel(at: PixelPoint(x: x, y: y)) {
                identical = false
            }
        }
        #expect(identical, "antialiasing off → hardness is ignored (Paint.NET)")
        let surface = soft
        for y in 0 ..< 64 {
            for x in 0 ..< 64 {
                let value = surface.pixel(at: PixelPoint(x: x, y: y))
                #expect(value == Self.base || value == .init(red: 0, green: 0, blue: 0, alpha: 0),
                        "aliased full-strength pixels are binary at (\(x), \(y))")
            }
        }
    }

    @Test func antialiasedEdgeHandValues() {
        // 0009's profile at width 20 → R = 10.5, click at (32.5, 32.5), then `EraseOps`.
        // Distances along y = 32: pixel (x, 32) center (x + 0.5, 32.5) → d = x − 32.
        func run(hardness: Int) -> FakeToolContext {
            let context = makeContext()
            setOptions(context, width: 20, hardness: hardness, antialiasing: true)
            let tool = EraserTool()
            tool.mouseDown(event(CGPoint(x: 32.5, y: 32.5)), context: context)
            tool.mouseUp(event(CGPoint(x: 32.5, y: 32.5)), context: context)
            return context
        }
        let half = run(hardness: 50)
        #expect(pixel(half, 32, 32) == .init(red: 0, green: 0, blue: 0, alpha: 0))
        #expect(pixel(half, 37, 32) == .init(red: 0, green: 0, blue: 0, alpha: 0),
                "d = 5, coverage 255")
        #expect(pixel(half, 40, 32) == .init(red: 200, green: 100, blue: 50, alpha: 137),
                "d = 8, coverage 118")
        #expect(pixel(half, 41, 32) == .init(red: 200, green: 100, blue: 50, alpha: 204),
                "d = 9, coverage 51")
        #expect(pixel(half, 42, 32) == .init(red: 200, green: 100, blue: 50, alpha: 249),
                "d = 10, coverage 6")
        #expect(pixel(half, 43, 32) == Self.base, "d = 11 ≥ R → untouched")

        let full = run(hardness: 100)
        #expect(pixel(full, 40, 32) == .init(red: 0, green: 0, blue: 0, alpha: 0))
        #expect(pixel(full, 41, 32) == .init(red: 0, green: 0, blue: 0, alpha: 0))
        #expect(pixel(full, 42, 32) == .init(red: 200, green: 100, blue: 50, alpha: 127),
                "d = 10, coverage 128")
        #expect(pixel(full, 43, 32) == Self.base)
    }

    @Test func overlappingDabsDoNotCompound() {
        let context = makeContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 9, green: 9, blue: 9, alpha: 128),
                                        secondary: .white)
        setOptions(context, width: 5, antialiasing: false)
        let tool = EraserTool()
        tool.mouseDown(event(CGPoint(x: 10.5, y: 32.5)), context: context)
        // Back and forth over the same span three times: every pass recomposes from the
        // before-stroke pixel, so the alpha is the single-pass value everywhere.
        for x in [40.5, 10.5, 40.5, 10.5, 40.5] {
            tool.mouseDragged(event(CGPoint(x: x, y: 32.5)), context: context)
        }
        tool.mouseUp(event(CGPoint(x: 40.5, y: 32.5)), context: context)
        var touched = 0
        for y in 0 ..< 64 {
            for x in 0 ..< 64 {
                let value = pixel(context, x, y)
                guard value != Self.base else { continue }
                touched += 1
                #expect(value == ColorRGBA8(red: 200, green: 100, blue: 50, alpha: 127),
                        "255 − 128 = 127 exactly at (\(x), \(y)), never lower")
            }
        }
        #expect(touched > 30, "the sweep left a mark to check")
    }

    @Test func rgbUntouchedWhilePartial() {
        let context = makeContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 9, green: 9, blue: 9, alpha: 200),
                                        secondary: .white)
        setOptions(context, width: 30, hardness: 40, antialiasing: true)
        let tool = EraserTool()
        tool.mouseDown(event(CGPoint(x: 20.5, y: 20.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 45.5, y: 40.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 20.5, y: 45.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 25.5, y: 25.5)), context: context)
        for y in 0 ..< 64 {
            for x in 0 ..< 64 {
                let value = pixel(context, x, y)
                #expect(value.red == 200 && value.green == 100 && value.blue == 50,
                        "strength 200 can never fully erase — RGB survives at (\(x), \(y))")
            }
        }
    }

    @Test func crossesTileBoundary() throws {
        let context = makeContext(width: 512, height: 512)
        setOptions(context, width: 1, antialiasing: false)
        let tool = EraserTool()
        tool.mouseDown(event(CGPoint(x: 246.5, y: 100.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 266.5, y: 100.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 266.5, y: 100.5)), context: context)
        #expect(pixel(context, 250, 100) == .init(red: 0, green: 0, blue: 0, alpha: 0),
                "erased left of the boundary")
        #expect(pixel(context, 262, 100) == .init(red: 0, green: 0, blue: 0, alpha: 0),
                "erased right of the boundary")
        let item = try #require(context.history.steps[1].item as? TileDiffHistoryItem)
        #expect(Set(item.diff.entries.map(\.coordinate))
                    == Set([TileCoordinate(column: 0, row: 0), TileCoordinate(column: 1, row: 0)]),
                "both crossed tiles, nothing else")
    }

    /// A test clip that lets only `x < 3` through (0013 will pass the selection mask here).
    private struct ClipLeftThree: BrushClipMask {
        let bounds = PixelRect(x: 0, y: 0, width: 64, height: 64)
        func coverage(x: Int, y: Int) -> UInt8 { x < 3 ? 255 : 0 }
    }

    @Test func respectsClipHook() {
        let context = makeContext()
        context.paintClipMask = ClipLeftThree()
        setOptions(context, width: 5, antialiasing: false)
        let tool = EraserTool()
        tool.mouseDown(event(CGPoint(x: 2.5, y: 32.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 2.5, y: 32.5)), context: context)
        var erasedCount = 0
        for y in 0 ..< 64 {
            for x in 0 ..< 64 {
                let value = pixel(context, x, y)
                if value == .init(red: 0, green: 0, blue: 0, alpha: 0) {
                    #expect(x < 3, "erased pixel at (\(x), \(y)) inside the clip")
                    erasedCount += 1
                } else {
                    #expect(value == Self.base)
                }
            }
        }
        #expect(erasedCount > 0, "the clip still lets the in-selection pixels erase")
    }

    // MARK: - Options (TOOL-C)

    @Test func optionsPersistIndependently() {
        let context = makeContext()
        let eraserKeys = BrushOptions.keys(for: .eraser)
        let brushKeys = BrushOptions.keys(for: .paintbrush)
        context.options.setValue(37.0, for: eraserKeys.width)
        context.options.setValue(5.0, for: brushKeys.width)

        let tool = EraserTool()
        tool.activate(context: context)
        #expect(tool.options.width == 37, "the Eraser reads its own width")
        #expect(BrushOptions.load(from: context.options, tool: .paintbrush).width == 5,
                "the Paintbrush keeps its own value")

        // Defaults match the Paintbrush's (2 / 75 / on) on a fresh store.
        let fresh = makeContext()
        let defaults = BrushOptions.load(from: fresh.options, tool: .eraser)
        #expect(defaults.width == 2 && defaults.hardness == 75 && defaults.antialiasing == true)

        // Adjusting the Eraser never writes the Paintbrush's keys or `tool.eraser.blendMode`.
        tool.adjustBrushWidth(by: 1, context: context)
        #expect(context.memoryOptions.storedValue(forKey: "tool.eraser.blendMode") == nil,
                "the Eraser has no blend mode (D-27)")
        #expect(context.memoryOptions.storedValue(forKey: "tool.paintbrush.width") as? Double == 5)
        let second = EraserTool()
        second.activate(context: context)
        #expect(second.options.width == 38, "a new tool instance reads the persisted width")
    }

    @Test func bracketKeysChangeWidth() {
        let context = makeContext()
        let eraserKeys = BrushOptions.keys(for: .eraser)
        let brushKeys = BrushOptions.keys(for: .paintbrush)
        context.options.setValue(9.0, for: brushKeys.width)
        let tool = EraserTool()
        tool.adjustBrushWidth(by: 1, context: context)
        #expect(context.options.value(eraserKeys.width) == 3, "default 2 → 3")
        tool.adjustBrushWidth(by: -1, context: context)
        #expect(context.options.value(eraserKeys.width) == 2, "back to 2")
        #expect(context.options.value(brushKeys.width) == 9, "the Paintbrush width is untouched")
    }

    // MARK: - History semantics (H-6)

    @Test func zeroStrengthIsEmptyStroke() {
        let context = makeContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 9, green: 9, blue: 9, alpha: 0),
                                        secondary: .white)
        let baseline = context.image
        setOptions(context, width: 20)
        let tool = EraserTool()
        tool.mouseDown(event(CGPoint(x: 20.5, y: 20.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 40.5, y: 40.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 40.5, y: 40.5)), context: context)
        #expect(context.image == baseline, "strength 0 changes nothing")
        #expect(context.history.steps.map(\.name) == ["New Image"], "no step (H-6)")
    }

    @Test func cancelMidStrokeRestores() {
        let context = makeContext()
        setOptions(context, width: 20)
        let baseline = context.image
        let tool = EraserTool()
        tool.mouseDown(event(CGPoint(x: 20.5, y: 20.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 40.5, y: 40.5)), context: context)
        #expect(tool.hasPendingEdit)
        tool.cancel(context: context)
        #expect(context.image == baseline, "pixel-identical to before the stroke")
        #expect(context.history.steps.map(\.name) == ["New Image"], "no step")
        #expect(!tool.hasPendingEdit)
    }

    @Test func undoRedo() {
        let context = makeContext()
        setOptions(context, width: 10, antialiasing: false)
        let preStroke = context.image
        let tool = EraserTool()
        tool.mouseDown(event(CGPoint(x: 10.5, y: 10.5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 50.5, y: 50.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 50.5, y: 50.5)), context: context)
        let postStroke = context.image
        #expect(postStroke != preStroke, "the stroke erased something")

        context.navigateForTests { history, state in _ = history.undo(&state) }
        #expect(context.image == preStroke, "undo restores the exact stroke-start pixels")
        context.navigateForTests { history, state in _ = history.redo(&state) }
        #expect(context.image == postStroke, "redo restores the exact stroke result")
    }

    @Test func historyName() {
        let context = makeContext()
        setOptions(context, width: 4, antialiasing: false)
        let tool = EraserTool()
        tool.mouseDown(event(CGPoint(x: 6.5, y: 6.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 6.5, y: 6.5)), context: context)
        #expect(context.history.steps.count == 2)
        #expect(context.history.steps[1].name == "Eraser")
        #expect(context.history.steps[1].icon == .eraser)
    }

    // MARK: - Outline and cursor (D-38)

    @Test func outlineUsesEraserWidth() {
        let context = makeContext()
        let eraserKeys = BrushOptions.keys(for: .eraser)
        context.options.setValue(30.0, for: eraserKeys.width)
        context.options.setValue(5.0, for: BrushOptions.keys(for: .paintbrush).width)
        let tool = EraserTool()
        tool.activate(context: context)
        tool.mouseMoved(event(CGPoint(x: 20, y: 20)), context: context)
        #expect(context.overlays.last == .some(.brushOutline(CGRect(x: 5, y: 5, width: 30, height: 30))),
                "the outline tracks the Eraser's own width (30), not the Paintbrush's (5)")
        tool.adjustBrushWidth(by: 1, context: context)
        #expect(context.overlays.last == .some(.brushOutline(CGRect(x: 4.5, y: 4.5,
                                                                   width: 31, height: 31))),
                "`[`/`]` resize the outline immediately")
        #expect(tool.cursor(at: CGPoint(x: 20, y: 20), modifiers: []) == .crosshair)
        tool.deactivate(context: context)
        #expect(context.overlays.last == .some(nil), "the outline disappears on deactivate")
    }
}
