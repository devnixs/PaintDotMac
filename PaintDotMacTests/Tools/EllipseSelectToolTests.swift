import Foundation
import Testing
@testable import PaintDotMac

/// `EllipseSelectTool` masks and options (spec 0014 *Test plan*): the antialiased and
/// pixelated circle masks with their symmetry and coverage totals, the clipped ellipse
/// past the canvas edge, and the draw-mode options being Ellipse's no-op.
@MainActor
struct EllipseSelectToolTests {
    private func event(_ x: Double, _ y: Double, _ t: TimeInterval,
                       modifiers: ToolModifiers = []) -> ToolEvent {
        ToolEvent(location: CGPoint(x: x, y: y), viewLocation: .zero, button: .primary,
                  modifiers: modifiers, clickCount: 1, pressure: 1, timestamp: t)
    }

    private func dragCircle(_ context: FakeToolContext, shift: Bool = false) {
        // The 20 × 20 rect (10,10,20,20): a circle of radius 10 centered at (20,20).
        let tool = EllipseSelectTool()
        if shift { tool.flagsChanged([.shift], context: context) }
        tool.mouseDown(event(10.4, 10.4, 1.0), context: context)
        tool.mouseDragged(event(29.4, 29.4, 1.1), context: context)
        tool.mouseUp(event(29.4, 29.4, 1.2, modifiers: shift ? [.shift] : []), context: context)
    }

    @Test func antialiasedMask() throws {
        let context = FakeToolContext()   // default quality: Antialiased
        dragCircle(context)
        #expect(context.history.steps.map(\.name) == ["New Image", "Ellipse Select"])
        #expect(context.history.steps[1].icon == .ellipseSelect)
        let selection = try #require(context.selection)

        // Center fully covered; the bounding-rect corners fully outside.
        #expect(selection.mask.coverage(x: 20, y: 20) == 255)
        for corner in [(10, 10), (29, 10), (10, 29), (29, 29)] {
            #expect(selection.mask.coverage(x: corner.0, y: corner.1) == 0, "\(corner)")
        }
        // Mirror symmetry about the vertical, horizontal, and both edge axes of the rect.
        var fractional = 0
        var total = 0.0
        for y in 10...29 {
            for x in 10...29 {
                let m = selection.mask.coverage(x: x, y: y)
                #expect(m == selection.mask.coverage(x: 39 - x, y: y), "mirror x (\(x), \(y))")
                #expect(m == selection.mask.coverage(x: x, y: 39 - y), "mirror y (\(x), \(y))")
                #expect(m == selection.mask.coverage(x: y, y: x), "mirror diagonal (\(x), \(y))")
                if m > 0, m < 255 { fractional += 1 }
            }
        }
        for y in 0..<64 {
            for x in 0..<64 {
                total += Double(selection.mask.coverage(x: x, y: y)) / 255.0
            }
        }
        #expect(fractional > 0, "Antialiased leaves edge pixels strictly between 0 and 255")
        // Σ coverage ≈ the circle area π · 10² = 314.16 within 1 %.
        #expect(abs(total - Double.pi * 100) < Double.pi, "total coverage \(total)")
    }

    @Test func pixelatedMask() throws {
        let context = FakeToolContext()
        context.memoryOptions.setValue(SelectionQuality.pixelated, for: SelectionToolOptions.quality)
        dragCircle(context)
        let selection = try #require(context.selection)
        var filled = 0
        for y in 10...29 {
            for x in 10...29 {
                let m = selection.mask.coverage(x: x, y: y)
                #expect(m == 0 || m == 255, "Pixelated edge at (\(x), \(y)) is \(m)")
                #expect(m == selection.mask.coverage(x: 39 - x, y: y))
                #expect(m == selection.mask.coverage(x: x, y: 39 - y))
                if m == 255 { filled += 1 }
            }
        }
        // A radius-10 disc holds ≈ 314 whole pixels; Pixelated must land within 3 %.
        #expect(abs(Double(filled) - 314.0) <= 314.0 * 0.03, "filled \(filled)")
    }

    @Test func ellipsePastEdge() throws {
        // Circle centered (60,60), r 20, clipped to the 64 × 64 canvas.
        let context = FakeToolContext()
        let tool = EllipseSelectTool()
        tool.mouseDown(event(40.4, 40.4, 1.0), context: context)
        tool.mouseDragged(event(79.4, 79.4, 1.1), context: context)
        tool.mouseUp(event(79.4, 79.4, 1.2), context: context)
        let selection = try #require(context.selection)
        #expect(selection.bounds == PixelRect(x: 40, y: 40, width: 24, height: 24))
        // Pixel center (63.5, 63.5): 3.5² + 3.5² = 24.5 < 400 → fully covered.
        #expect(selection.mask.coverage(x: 63, y: 63) == 255)
        // Pixel center (40.5, 40.5): 19.5² × 2 = 760.5 > 400 → uncovered.
        #expect(selection.mask.coverage(x: 40, y: 40) == 0)
    }

    @Test func shiftCircleAndOptionsIgnored() throws {
        let context = FakeToolContext()
        context.memoryOptions.setValue(SelectionDrawMode.fixedSize, for: SelectionToolOptions.drawMode)
        let rectOf = { (overlay: ToolOverlay??) -> PixelRect? in
            guard case .selectionShape(let preview)? = overlay ?? nil else { return nil }
            return preview.rect
        }
        let tool = EllipseSelectTool()
        // Shift from the mouse-down event: the Paint.NET circle (−2,−1,11,11).
        tool.mouseDown(event(0.4, 0.4, 1.0, modifiers: [.shift]), context: context)
        tool.mouseDragged(event(6.4, 8.4, 1.1, modifiers: [.shift]), context: context)
        #expect(rectOf(context.overlays.last) == PixelRect(x: -2, y: -1, width: 11, height: 11))
        tool.mouseUp(event(6.4, 8.4, 1.2, modifiers: [.shift]), context: context)

        // Without Shift the free ellipse follows the pointer — the Fixed Size option (the
        // default 4 × 3 Inches) has no effect on Ellipse Select.
        let context2 = FakeToolContext()
        context2.memoryOptions.setValue(SelectionDrawMode.fixedSize, for: SelectionToolOptions.drawMode)
        let tool2 = EllipseSelectTool()
        tool2.mouseDown(event(0.4, 0.4, 1.0), context: context2)
        tool2.mouseDragged(event(20.4, 20.4, 1.1), context: context2)
        #expect(rectOf(context2.overlays.last) == PixelRect(x: 0, y: 0, width: 21, height: 21))
    }
}
