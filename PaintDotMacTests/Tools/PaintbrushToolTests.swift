import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `PaintbrushTool` through `FakeToolContext` (spec 0009 *Test plan*): defaults, persistence,
/// color choice (TOOL-A), width stepping, commit/cancel/pending-edit semantics, and the
/// brush outline (D-38).
@MainActor
struct PaintbrushToolTests {
    private func event(_ location: CGPoint, button: ToolMouseButton = .primary,
                       modifiers: ToolModifiers = []) -> ToolEvent {
        ToolEvent(location: location, viewLocation: .zero, button: button,
                  modifiers: modifiers, clickCount: 1, pressure: 1, timestamp: 0)
    }

    private func makeContext(width: Int = 64, height: Int = 64) -> FakeToolContext {
        FakeToolContext(size: PixelSize(width: width, height: height))
    }

    // MARK: - Identity and options

    @Test func defaultsMatchPaintNET() {
        let context = makeContext()
        let loaded = BrushOptions.load(from: context.options, tool: .paintbrush)
        #expect(loaded.width == 2)
        #expect(loaded.hardness == 75)
        #expect(loaded.antialiasing == true)
        #expect(loaded.blendMode == .normal)
        let tool = PaintbrushTool()
        #expect(tool.id == .paintbrush)
        #expect(tool.id.rawValue == "paintbrush")
        #expect(tool.displayName == "Paintbrush")
        #expect(tool.shortcutKey == "b")
    }

    @Test func optionsRoundTripThroughStore() throws {
        let context = makeContext()
        let keys = BrushOptions.keys(for: .paintbrush)
        let tool = PaintbrushTool()
        var options = BrushOptions.default
        options.width = 37.5
        options.hardness = 20
        options.antialiasing = false
        options.save(to: context.options, tool: .paintbrush)
        #expect(context.memoryOptions.storedValue(forKey: "tool.paintbrush.width") as? Double == 37.5)
        #expect(context.memoryOptions.storedValue(forKey: "tool.paintbrush.hardness") as? Int == 20)
        #expect(context.memoryOptions.storedValue(forKey: "tool.paintbrush.antialiasing") as? Bool == false)
        _ = keys

        let reloaded = BrushOptions.load(from: context.options, tool: .paintbrush)
        #expect(reloaded.width == 37.5)
        #expect(reloaded.hardness == 20)
        #expect(reloaded.antialiasing == false)
        #expect(reloaded.blendMode == .normal)

        // Prefixes are independent: the same store reads defaults for the Eraser.
        let eraser = BrushOptions.load(from: context.options, tool: .eraser)
        #expect(eraser == BrushOptions.default)
        _ = tool
    }

    @Test func outOfRangeStoredOptionsAreClamped() {
        let context = makeContext()
        context.memoryOptions.setStoredValue(5000.0, forKey: "tool.paintbrush.width")
        #expect(BrushOptions.load(from: context.options, tool: .paintbrush).width == 2000)
        context.memoryOptions.setStoredValue(0.0, forKey: "tool.paintbrush.width")
        #expect(BrushOptions.load(from: context.options, tool: .paintbrush).width == 1)
        context.memoryOptions.setStoredValue(-3.0, forKey: "tool.paintbrush.width")
        #expect(BrushOptions.load(from: context.options, tool: .paintbrush).width == 1)
        context.memoryOptions.setStoredValue(Double.nan, forKey: "tool.paintbrush.width")
        #expect(BrushOptions.load(from: context.options, tool: .paintbrush).width == 2)
        context.memoryOptions.setStoredValue(-5, forKey: "tool.paintbrush.hardness")
        #expect(BrushOptions.load(from: context.options, tool: .paintbrush).hardness == 0)
        context.memoryOptions.setStoredValue(400, forKey: "tool.paintbrush.hardness")
        #expect(BrushOptions.load(from: context.options, tool: .paintbrush).hardness == 100)
        context.memoryOptions.setStoredValue("foo", forKey: "tool.paintbrush.blendMode")
        #expect(BrushOptions.load(from: context.options, tool: .paintbrush).blendMode == .normal)
    }

    // MARK: - Color choice (TOOL-A)

    @Test func colorChoice() {
        let context = makeContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255), secondary: ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255))
        let tool = PaintbrushTool()
        func painted() -> ColorRGBA8 {
            context.image.layers[0].surface.pixel(at: PixelPoint(x: 10, y: 10))
        }
        func reset() {
            // `updateImage` is the fake's only image writer; a bare `state.image` write
            // would desynchronize the shared stroke storage (see `FakeToolContext`).
            context.updateImage { $0 = .blank(size: $0.size, fill: .clear) }
        }

        tool.mouseDown(event(CGPoint(x: 10.5, y: 10.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 10.5, y: 10.5)), context: context)
        #expect(painted() == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255), "left button paints primary")

        reset()
        tool.mouseDown(event(CGPoint(x: 10.5, y: 10.5), button: .secondary), context: context)
        tool.mouseUp(event(CGPoint(x: 10.5, y: 10.5), button: .secondary), context: context)
        #expect(painted() == ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255), "right button (dispatcher's .secondary) paints secondary")

        reset()
        tool.mouseDown(event(CGPoint(x: 10.5, y: 10.5), modifiers: [.control]), context: context)
        tool.mouseUp(event(CGPoint(x: 10.5, y: 10.5), modifiers: [.control]), context: context)
        #expect(painted() == ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255), "defensive primary+.control maps to secondary")

        reset()
        tool.mouseDown(event(CGPoint(x: 10.5, y: 10.5)), context: context)
        // A secondary-button event mid-stroke (the dispatcher keeps delivering the original
        // button; even a mislabeled one must not change the frozen color — the drag below
        // carries .secondary but the stroke color was fixed at mouse-down).
        tool.mouseDragged(event(CGPoint(x: 10.5, y: 11.5), button: .secondary), context: context)
        tool.mouseUp(event(CGPoint(x: 10.5, y: 11.5), button: .secondary), context: context)
        #expect(painted() == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255), "the mouse-down button decides the color for the stroke")
    }

    // MARK: - Width stepping

    @Test func widthStepping() {
        let context = makeContext(width: 200, height: 64)
        let widthKey = BrushOptions.keys(for: .paintbrush).width
        let tool = PaintbrushTool()
        context.options.setValue(2.0, for: widthKey)
        tool.adjustBrushWidth(by: 1, context: context)
        #expect(context.options.value(widthKey) == 3)
        context.options.setValue(1.0, for: widthKey)
        tool.adjustBrushWidth(by: -1, context: context)
        #expect(context.options.value(widthKey) == 1, "clamped at 1")
        context.options.setValue(2000.0, for: widthKey)
        tool.adjustBrushWidth(by: 1, context: context)
        #expect(context.options.value(widthKey) == 2000, "clamped at 2000")
        context.options.setValue(6.5, for: widthKey)
        tool.adjustBrushWidth(by: 1, context: context)
        #expect(context.options.value(widthKey) == 7.5, "decimals step in whole units")

        // A width change mid-stroke applies to the NEXT stroke only.
        context.options.setValue(10.0, for: widthKey)
        tool.mouseDown(event(CGPoint(x: 100, y: 32.5)), context: context)
        context.options.setValue(140.0, for: widthKey)
        tool.mouseDragged(event(CGPoint(x: 130, y: 32.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 130, y: 32.5)), context: context)
        var reference = LayeredImage.blank(size: PixelSize(width: 200, height: 64), fill: .clear)
        let plainTool = PaintbrushTool()
        let fake = makeContext(width: 200, height: 64)
        fake.options.setValue(10.0, for: widthKey)
        plainTool.mouseDown(event(CGPoint(x: 100, y: 32.5)), context: fake)
        plainTool.mouseUp(event(CGPoint(x: 130, y: 32.5)), context: fake)
        reference = fake.image
        let livePixels = context.image.layers[0].surface
        let frozenPixels = reference.layers[0].surface
        var identical = true
        for y in 0..<64 {
            for x in 0..<200 where livePixels.pixel(at: PixelPoint(x: x, y: y))
                != frozenPixels.pixel(at: PixelPoint(x: x, y: y)) {
                identical = false
            }
        }
        #expect(identical, "the live stroke kept the mouse-down width")
    }

    // MARK: - Pending edit, commit, cancel

    private func downDragUp(_ tool: PaintbrushTool, _ context: FakeToolContext) {
        tool.mouseDown(event(CGPoint(x: 10, y: 10)), context: context)
        tool.mouseDragged(event(CGPoint(x: 20, y: 15)), context: context)
        tool.mouseDragged(event(CGPoint(x: 30, y: 20)), context: context)
    }

    @Test func hasPendingEditOnlyDuringStroke() {
        let context = makeContext()
        let tool = PaintbrushTool()
        #expect(!tool.hasPendingEdit)
        tool.mouseDown(event(CGPoint(x: 10, y: 10)), context: context)
        #expect(tool.hasPendingEdit)
        tool.mouseDragged(event(CGPoint(x: 20, y: 15)), context: context)
        #expect(tool.hasPendingEdit)
        tool.mouseUp(event(CGPoint(x: 25, y: 20)), context: context)
        #expect(!tool.hasPendingEdit)

        let commitTool = PaintbrushTool()
        downDragUp(commitTool, context)
        #expect(commitTool.hasPendingEdit)
        commitTool.commit(context: context)
        #expect(!commitTool.hasPendingEdit)

        let cancelTool = PaintbrushTool()
        downDragUp(cancelTool, context)
        cancelTool.cancel(context: context)
        #expect(!cancelTool.hasPendingEdit)
    }

    @Test func cancelMidStrokeRestores() {
        let context = makeContext()
        let baseline = context.image
        let tool = PaintbrushTool()
        downDragUp(tool, context)
        tool.cancel(context: context)
        #expect(context.image == baseline, "layer identical to before the stroke")
        // Previously absent tiles are absent again.
        #expect(context.image.layers[0].surface.allocatedTileCoordinates.isEmpty)
        #expect(context.history.steps.map(\.name) == ["New Image"])
    }

    @Test func commitMidStrokeCreatesStep() {
        let context = makeContext()
        let tool = PaintbrushTool()
        downDragUp(tool, context)
        tool.commit(context: context)
        #expect(context.history.steps.map(\.name) == ["New Image", "Paintbrush"])
        #expect(context.history.steps[1].icon == .paintbrush)
        // A further mouseUp after the commit adds nothing.
        tool.mouseUp(event(CGPoint(x: 35, y: 25)), context: context)
        #expect(context.history.steps.count == 2)
    }

    @Test func deactivateMidStrokeRecordsOneStep() {
        let context = makeContext()
        let tool = PaintbrushTool()
        downDragUp(tool, context)
        tool.deactivate(context: context)
        #expect(context.history.steps.map(\.name) == ["New Image", "Paintbrush"])
        #expect(context.overlays.contains(nil), "the outline is hidden on deactivate")
    }

    @Test func secondMouseDownDuringStrokeIgnored() {
        let context = makeContext()
        let tool = PaintbrushTool()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255), secondary: ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255))
        tool.mouseDown(event(CGPoint(x: 10, y: 10)), context: context)
        let updatesAfterDown = context.imageUpdates
        tool.mouseDown(event(CGPoint(x: 40, y: 40), button: .secondary), context: context)
        #expect(context.imageUpdates == updatesAfterDown, "the second down is fully ignored")
        tool.mouseUp(event(CGPoint(x: 40, y: 40)), context: context)
        // The stroke kept the primary color and its own pixels.
        #expect(context.image.layers[0].surface.pixel(at: PixelPoint(x: 10, y: 10)).alpha == 255)
    }

    @Test func strokeIsOneStepEvenWhenNothingChanged() {
        // A fully off-canvas stroke: pending during the gesture, empty diff at mouse-up →
        // no step (H-6), but the pending flag behaved.
        let context = makeContext()
        let tool = PaintbrushTool()
        tool.mouseDown(event(CGPoint(x: -500, y: -500)), context: context)
        #expect(tool.hasPendingEdit)
        tool.mouseUp(event(CGPoint(x: -480, y: -500)), context: context)
        #expect(!tool.hasPendingEdit)
        #expect(context.history.steps.map(\.name) == ["New Image"])
    }

    // MARK: - Outline and cursor (D-38)

    @Test func outlineFollowsPointer() {
        let context = makeContext()
        let tool = PaintbrushTool()
        context.options.setValue(20.0, for: BrushOptions.keys(for: .paintbrush).width)
        tool.activate(context: context)
        tool.mouseMoved(event(CGPoint(x: 10.25, y: 30.5)), context: context)
        #expect(context.overlays.last == .some(.brushOutline(CGRect(x: 0.25, y: 20.5, width: 20, height: 20))))
        tool.mouseDown(event(CGPoint(x: 50, y: 50)), context: context)
        tool.mouseDragged(event(CGPoint(x: 50, y: 50)), context: context)
        #expect(context.overlays.last == .some(.brushOutline(CGRect(x: 40, y: 40, width: 20, height: 20))))
        tool.mouseUp(event(CGPoint(x: 50, y: 50)), context: context)
        tool.deactivate(context: context)
        #expect(context.overlays.last == .some(nil))
    }

    @Test func outlineTracksWidthChanges() {
        let context = makeContext()
        let keys = BrushOptions.keys(for: .paintbrush)
        let tool = PaintbrushTool()
        tool.activate(context: context)   // default width 2, AA on
        tool.mouseMoved(event(CGPoint(x: 10, y: 10)), context: context)
        #expect(context.overlays.last == .some(.brushOutline(CGRect(x: 9, y: 9, width: 2, height: 2))))
        tool.adjustBrushWidth(by: 1, context: context)
        #expect(context.overlays.last == .some(.brushOutline(CGRect(x: 8.5, y: 8.5, width: 3, height: 3))))
        // Antialiasing off → the circle snaps to the pixels a click paints.
        context.memoryOptions.setStoredValue(false, forKey: keys.antialiasing.defaultsKey)
        tool.optionsDidChange(context: context)
        #expect(context.overlays.last == .some(.brushOutline(CGRect(x: 9, y: 9, width: 3, height: 3))))
    }

    @Test func cursorIsCrosshairOnCanvas() {
        let tool = PaintbrushTool()
        #expect(tool.cursor(at: CGPoint(x: 5, y: 5), modifiers: []) == .crosshair)
        #expect(tool.cursor(at: nil, modifiers: []) == .arrow)
    }
}
