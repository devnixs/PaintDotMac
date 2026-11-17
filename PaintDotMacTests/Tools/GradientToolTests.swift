import Foundation
import Testing

@testable import PaintDotMac

/// The Gradient tool state machine on `FakeToolContext` (spec 0023 *Test plan*): a
/// 300×300 white image, default colors P/S, options through `InMemoryToolOptionStore`.
@MainActor
struct GradientToolTests {
    private func context() -> FakeToolContext {
        FakeToolContext(size: PixelSize(width: 300, height: 300), background: .white)
    }

    private func event(_ context: FakeToolContext, _ location: CGPoint,
                       button: ToolMouseButton = .primary,
                       modifiers: ToolModifiers = []) -> ToolEvent {
        ToolEvent(location: location,
                  viewLocation: context.transform.canvasToView(location),
                  button: button, modifiers: modifiers,
                  clickCount: 1, pressure: 1, timestamp: 0)
    }

    private func pixel(_ context: FakeToolContext, _ x: Int, _ y: Int) -> ColorRGBA8 {
        context.image.layers[0].surface.pixel(at: PixelPoint(x: x, y: y))
    }

    private func stepNames(_ context: FakeToolContext) -> [String] {
        context.history.steps.map(\.name)
    }

    /// Draws the canonical linear gradient (10,150) → (290,150) and leaves it pending.
    private func drawLinear(_ tool: GradientTool, _ context: FakeToolContext) {
        tool.mouseDown(event(context, CGPoint(x: 10, y: 150)), context: context)
        tool.mouseDragged(event(context, CGPoint(x: 150, y: 150)), context: context)
        tool.mouseDragged(event(context, CGPoint(x: 290, y: 150)), context: context)
        tool.mouseUp(event(context, CGPoint(x: 290, y: 150)), context: context)
    }

    /// The `.gradientHandles` overlay endpoints.
    private func handles(_ context: FakeToolContext) -> (start: CGPoint, end: CGPoint)? {
        guard case .gradientHandles(let start, let end)? = context.lastOverlay else {
            return nil
        }
        return (start, end)
    }

    // MARK: - Defaults & persistence

    @Test func defaultsMatchPaintNET() {
        let store = InMemoryToolOptionStore()
        #expect(GradientOptions.load(from: store) == GradientOptions.default)
        #expect(GradientOptions.default.type == .linear)
        #expect(GradientOptions.default.mode == .color)
        #expect(GradientOptions.default.antialiasing)
        #expect(GradientOptions.default.blendMode == .normal)
        #expect(ToolRegistry.descriptor(for: .gradient).supportsPendingEdits)
        #expect(ToolRegistry.standard().isImplemented(.gradient))
    }

    @Test func optionsRoundTripThroughStore() throws {
        let store = InMemoryToolOptionStore()
        let saved = GradientOptions(type: .conical, mode: .transparency, antialiasing: false,
                                    blendMode: .normal)
        saved.save(to: store)
        #expect(store.storedValue(forKey: "tool.gradient.type") as? String == "conical")
        #expect(store.storedValue(forKey: "tool.gradient.mode") as? String == "transparency")
        #expect(store.storedValue(forKey: "tool.gradient.antialiasing") as? Bool == false)
        #expect(store.storedValue(forKey: "tool.gradient.blendMode") as? String == "normal")
        #expect(GradientOptions.load(from: store) == saved)
        // An unknown raw value reads as the default.
        store.setStoredValue("spiral", forKey: "tool.gradient.type")
        #expect(GradientOptions.load(from: store).type == .linear)
    }

    // MARK: - Drawing

    @Test func drawShowsHandlesAndPending() {
        let context = context()
        let tool = GradientTool()
        tool.mouseDown(event(context, CGPoint(x: 10, y: 150)), context: context)
        tool.mouseDragged(event(context, CGPoint(x: 290, y: 150)), context: context)
        #expect(handles(context)?.start == CGPoint(x: 10, y: 150))
        #expect(handles(context)?.end == CGPoint(x: 290, y: 150))
        #expect(tool.hasPendingEdit)
        tool.mouseUp(event(context, CGPoint(x: 290, y: 150)), context: context)
        #expect(tool.hasPendingEdit, "the gradient stays editable after release")
        #expect(stepNames(context) == ["New Image"], "no commit before commit()")
        #expect(pixel(context, 5, 150) == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                "P at the start")
        #expect(pixel(context, 295, 150) == ColorRGBA8(red: 255, green: 255, blue: 255,
                                                       alpha: 255), "S at the end")
        // Mid-handle is the 50 % point (128) — distinguishes a real ramp from "no-op".
        #expect(pixel(context, 150, 150) == ColorRGBA8(red: 128, green: 128, blue: 128,
                                                       alpha: 255))
    }

    @Test func secondaryDragReverses() {
        let context = context()
        let tool = GradientTool()
        tool.mouseDown(event(context, CGPoint(x: 10, y: 150), button: .secondary),
                       context: context)
        tool.mouseDragged(event(context, CGPoint(x: 290, y: 150), button: .secondary),
                          context: context)
        tool.mouseUp(event(context, CGPoint(x: 290, y: 150), button: .secondary),
                     context: context)
        #expect(pixel(context, 5, 150) == ColorRGBA8(red: 255, green: 255, blue: 255,
                                                     alpha: 255))
        #expect(pixel(context, 295, 150) == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255))
    }

    @Test func rightClickHandleSwapsColors() {
        let context = context()
        let tool = GradientTool()
        drawLinear(tool, context)
        #expect(pixel(context, 5, 150) == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255))
        tool.mouseDown(event(context, CGPoint(x: 290, y: 150), button: .secondary),
                       context: context)
        tool.mouseUp(event(context, CGPoint(x: 290, y: 150), button: .secondary),
                     context: context)
        // Swapped: secondary (white) is now the start color, primary (black) the end.
        #expect(pixel(context, 295, 150) == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255))
        #expect(tool.hasPendingEdit, "still pending")
    }

    @Test func shiftSnapsDuringDrawAndHandleDrag() throws {
        let context = context()
        let tool = GradientTool()
        tool.mouseDown(event(context, CGPoint(x: 100, y: 100)), context: context)
        tool.mouseDragged(event(context, CGPoint(x: 200, y: 105), modifiers: [.shift]),
                          context: context)
        let snapped = try #require(handles(context))
        let expectedX = 100 + Foundation.sqrt(10_025)
        #expect(abs(snapped.end.x - expectedX) < 1e-9)
        #expect(abs(snapped.end.y - 100) < 1e-9)
        tool.mouseUp(event(context, CGPoint(x: 200, y: 105), modifiers: [.shift]),
                     context: context)

        // Drag the end handle with Shift: snapped to a 15° step from the start, length kept.
        let endCanvas = snapped.end
        tool.mouseDown(event(context, endCanvas), context: context)
        tool.mouseDragged(event(context, CGPoint(x: 150, y: 190), modifiers: [.shift]),
                          context: context)
        tool.mouseUp(event(context, CGPoint(x: 150, y: 190), modifiers: [.shift]),
                     context: context)
        let dragged = try #require(handles(context))
        let dx = dragged.end.x - 100
        let dy = dragged.end.y - 100
        let step = GradientGeometry.snapStepDegrees * Double.pi / 180
        let angle = atan2(dy, dx) / step
        #expect(abs(angle - angle.rounded()) < 1e-6, "on a 15° step")
        let radius = hypot(dx, dy)
        #expect(abs(radius - hypot(50, 90)) < 1e-9, "length preserved")
    }

    // MARK: - Handle editing & live options

    @Test func handleDragRerendersFromBefore() throws {
        let context = context()
        let tool = GradientTool()
        drawLinear(tool, context)
        // Grab the start handle twice.
        for target in [CGPoint(x: 50, y: 150), CGPoint(x: 80, y: 200)] {
            let (startCanvas, _) = try #require(handles(context))
            tool.mouseDown(event(context, startCanvas), context: context)
            tool.mouseDragged(event(context, target), context: context)
            tool.mouseUp(event(context, target), context: context)
        }
        let (finalStart, finalEnd) = try #require(handles(context))
        // The live pixels equal a fresh render from the original white surface.
        var reference = filledWhite()
        _ = GradientRenderer.render(
            GradientParameters(type: .linear, mode: .color, start: finalStart, end: finalEnd,
                               startColor: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                               endColor: ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255),
                               antialiasing: true, blendMode: .normal),
            before: filledWhite(), into: &reference, clip: nil)
        #expect(context.image.layers[0].surface == reference, "no accumulation")
    }

    @Test func optionChangeRerendersPending() {
        let context = context()
        let tool = GradientTool()
        drawLinear(tool, context)
        context.memoryOptions.setValue(GradientType.radial, for: GradientOptions.keys().type)
        tool.optionsDidChange(context: context)
        var reference = filledWhite()
        _ = GradientRenderer.render(
            GradientParameters(type: .radial, mode: .color,
                               start: CGPoint(x: 10, y: 150), end: CGPoint(x: 290, y: 150),
                               startColor: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                               endColor: ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255),
                               antialiasing: true, blendMode: .normal),
            before: filledWhite(), into: &reference, clip: nil)
        #expect(context.image.layers[0].surface == reference)
    }

    // MARK: - Commit / cancel

    private func pressReturn(_ tool: GradientTool, _ context: FakeToolContext) -> Bool {
        tool.keyDown(ToolKeyEvent(key: .returnKey, characters: "\r", modifiers: [],
                                  isRepeat: false),
                     context: context)
    }

    @Test func returnCommits() throws {
        let context = context()
        let tool = GradientTool()
        drawLinear(tool, context)
        #expect(pressReturn(tool, context))
        #expect(stepNames(context) == ["New Image", "Gradient"])
        let step = try #require(context.history.undoStep)
        let item = try #require(step.item as? TileDiffHistoryItem)
        #expect(item.icon == .gradient)
        #expect(!item.diff.isEmpty)
        #expect(!tool.hasPendingEdit)
        #expect(context.lastOverlay == nil)
    }

    @Test func deactivateCommits() {
        let context = context()
        let tool = GradientTool()
        drawLinear(tool, context)
        tool.deactivate(context: context)
        #expect(stepNames(context) == ["New Image", "Gradient"])
        #expect(context.lastOverlay == nil)
    }

    @Test func clickOutsideCommitsAndStartsNew() {
        let context = context()
        let tool = GradientTool()
        drawLinear(tool, context)
        tool.mouseDown(event(context, CGPoint(x: 40, y: 40)), context: context)
        #expect(stepNames(context) == ["New Image", "Gradient"], "the pending one committed")
        #expect(tool.hasPendingEdit, "a new gesture started")
        #expect(handles(context)?.start == CGPoint(x: 40, y: 40))
        #expect(handles(context)?.end == CGPoint(x: 40, y: 40))
    }

    @Test func escapeCancels() throws {
        let context = context()
        let tool = GradientTool()
        let before = context.image.layers[0].surface
        drawLinear(tool, context)
        let consumed = tool.keyDown(ToolKeyEvent(key: .escape, characters: "\u{1b}",
                                                 modifiers: [], isRepeat: false),
                                    context: context)
        #expect(consumed)
        #expect(stepNames(context) == ["New Image"], "no step recorded")
        #expect(!tool.hasPendingEdit)
        #expect(context.lastOverlay == nil)
        let after = context.image.layers[0].surface
        for row in 0..<after.tileRows {
            for column in 0..<after.tileColumns {
                let coordinate = TileCoordinate(column: column, row: row)
                let beforeTile = try #require(before.tile(at: coordinate))
                let afterTile = try #require(after.tile(at: coordinate))
                #expect(afterTile.sharesStorage(with: beforeTile),
                        "tile \(coordinate) is the original buffer again")
            }
        }
    }

    @Test func clickWithoutDragAddsNoStep() {
        let context = context()
        let tool = GradientTool()
        tool.mouseDown(event(context, CGPoint(x: 100, y: 100)), context: context)
        tool.mouseUp(event(context, CGPoint(x: 100, y: 100)), context: context)
        #expect(!tool.hasPendingEdit)
        #expect(stepNames(context) == ["New Image"])
        #expect(pixel(context, 100, 100) == .white)
        #expect(context.lastOverlay == nil)
    }

    @Test func degeneratePendingCommitsNothing() {
        let context = context()
        let tool = GradientTool()
        drawLinear(tool, context)
        // Drag the end handle onto the start handle.
        tool.mouseDown(event(context, CGPoint(x: 290, y: 150)), context: context)
        tool.mouseDragged(event(context, CGPoint(x: 10, y: 150)), context: context)
        tool.mouseUp(event(context, CGPoint(x: 10, y: 150)), context: context)
        #expect(tool.hasPendingEdit, "still pending — draggable apart again")
        #expect(pressReturn(tool, context))
        #expect(stepNames(context) == ["New Image"], "a degenerate commit behaves like cancel")
        #expect(pixel(context, 5, 150) == .white)
        #expect(pixel(context, 150, 150) == .white)
    }

    // MARK: - Selection clip

    @Test func respectsClipHook() {
        let context = context()
        context.clipMaskOverride = LeftHalfMask()
        let tool = GradientTool()
        drawLinear(tool, context)
        tool.deactivate(context: context)
        #expect(stepNames(context) == ["New Image", "Gradient"])
        for y in stride(from: 0, to: 300, by: 13) {
            for x in stride(from: 150, to: 300, by: 7) {
                #expect(pixel(context, x, y) == .white, "(\(x), \(y)) outside the clip")
            }
        }
        #expect(pixel(context, 5, 150) == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255))
    }

    // MARK: - Support

    private func filledWhite() -> TiledSurface {
        var surface = TiledSurface(size: PixelSize(width: 300, height: 300))
        surface.fill(.white)
        return surface
    }
}

/// Paints the left half (x < 150) with full coverage.
private struct LeftHalfMask: BrushClipMask {
    var bounds: PixelRect { PixelRect(x: 0, y: 0, width: 300, height: 300) }

    func coverage(x: Int, y: Int) -> UInt8 { x < 150 ? 255 : 0 }
}
