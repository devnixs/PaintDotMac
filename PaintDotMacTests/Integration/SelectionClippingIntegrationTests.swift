import AppKit
import Foundation
import Testing

@testable import PaintDotMac

/// TOOL-B through `FakeToolContext` (spec 0013 *Test plan*, headless): the real Paintbrush,
/// Pencil, and Eraser with a real selection installed on the fake's `DocumentState`.
/// Expected pixels are hand-computed from 0009's formulas (coverage → `mul255` clip →
/// `BlendOps.normal` / `EraseOps.erase`).
@MainActor
struct SelectionClippingIntegrationTests {
    private let size = PixelSize(width: 100, height: 100)

    private func whiteContext() -> FakeToolContext {
        FakeToolContext(size: size, background: .white)
    }

    private func pixel(_ context: FakeToolContext, _ x: Int, _ y: Int) -> ColorRGBA8 {
        context.image.layers[0].surface.pixel(at: PixelPoint(x: x, y: y))
    }

    private func event(_ location: CGPoint, button: ToolMouseButton = .primary) -> ToolEvent {
        ToolEvent(location: location, viewLocation: .zero, button: button,
                  modifiers: [], clickCount: 1, pressure: 1, timestamp: 0)
    }

    private func setBrush(_ context: FakeToolContext, tool: ToolID, width: Double,
                          hardness: Int, antialiasing: Bool) {
        let keys = BrushOptions.keys(for: tool)
        context.options.setValue(width, for: keys.width)
        context.options.setValue(hardness, for: keys.hardness)
        context.options.setValue(antialiasing, for: keys.antialiasing)
    }

    /// Installs a selection on the fake's state through a real history step.
    @discardableResult
    private func installSelection(_ context: FakeToolContext, rect: CGRect,
                                  inverted: Bool = false) throws -> Selection {
        let base = try #require(Selection(rect: rect, canvasSize: size))
        let selection = inverted ? try #require(base.inverted()) : base
        context.performHistory(SelectionHistoryItem(name: "Rectangle Select",
                                                    icon: .rectangleSelect,
                                                    before: nil, after: selection))
        return selection
    }

    private func drag(_ tool: any Tool, from: CGPoint, to: CGPoint,
                      context: FakeToolContext, steps: Int = 4) {
        tool.mouseDown(event(from), context: context)
        for step in 1...steps {
            let fraction = Double(step) / Double(steps)
            let point = CGPoint(x: from.x + (to.x - from.x) * fraction,
                                y: from.y + (to.y - from.y) * fraction)
            tool.mouseDragged(event(point), context: context)
        }
        tool.mouseUp(event(to), context: context)
    }

    private let black = ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255)
    private var white: ColorRGBA8 { .white }

    // MARK: - Paintbrush

    @Test func noSelectionPaintsEverywhere() throws {
        let context = whiteContext()
        #expect(context.paintClipMask == nil, "no selection, nothing clips")
        setBrush(context, tool: .paintbrush, width: 6, hardness: 100, antialiasing: true)
        let tool = PaintbrushTool()
        drag(tool, from: CGPoint(x: 2.5, y: 50.5), to: CGPoint(x: 97.5, y: 50.5),
             context: context)
        #expect(pixel(context, 5, 50) == black, "(5, 50) painted")
        #expect(pixel(context, 95, 50) == black, "(95, 50) painted")
    }

    @Test func paintbrushClippedToRect() throws {
        let context = whiteContext()
        try installSelection(context, rect: CGRect(x: 40, y: 0, width: 20, height: 100))
        setBrush(context, tool: .paintbrush, width: 6, hardness: 100, antialiasing: true)
        let tool = PaintbrushTool()
        drag(tool, from: CGPoint(x: 2.5, y: 50.5), to: CGPoint(x: 97.5, y: 50.5),
             context: context)
        #expect(pixel(context, 45, 50) == black)
        #expect(pixel(context, 40, 50) == black, "first covered column")
        #expect(pixel(context, 59, 50) == black, "last covered column")
        #expect(pixel(context, 39, 50) == white, "one pixel before the selection")
        #expect(pixel(context, 60, 50) == white, "one pixel past the selection")
        #expect(pixel(context, 35, 50) == white)
        #expect(pixel(context, 65, 50) == white)
    }

    @Test func paintbrushAntialiasedEdgeScales() throws {
        // Edge pixel 40: overlap 0.5 → coverage round(255 × 0.5) = 128 (0.25 right edge).
        let context = whiteContext()
        try installSelection(context, rect: CGRect(x: 40.5, y: 0, width: 20, height: 100))
        #expect(context.state.selection?.mask.coverage(x: 40, y: 50) == 128)
        setBrush(context, tool: .paintbrush, width: 6, hardness: 100, antialiasing: true)
        let tool = PaintbrushTool()
        drag(tool, from: CGPoint(x: 2.5, y: 50.5), to: CGPoint(x: 97.5, y: 50.5),
             context: context)
        // effCov = mul255(255, 128) = 128; Sa = mul255(255, 128) = 128; Normal over
        // opaque white: fa = 128·255 + 255·127 = 65025, outA = 255,
        // outC = (0 + 255·255·127 + 32512)/65025 = 127 → (127, 127, 127, 255).
        let edge = pixel(context, 40, 50)
        #expect(edge == ColorRGBA8(red: 127, green: 127, blue: 127, alpha: 255),
                "half-covered edge pixel scales the stroke")
        #expect(pixel(context, 41, 50) == black, "fully inside")
        let rightEdge = pixel(context, 60, 50)
        #expect(rightEdge == ColorRGBA8(red: 127, green: 127, blue: 127, alpha: 255))
        #expect(pixel(context, 39, 50) == white)
        #expect(pixel(context, 61, 50) == white)
    }

    @Test func selectAllIsPixelIdenticalToNoSelection() throws {
        var rng = SeededRandom(seed: 0x0013_C11B)
        // `mul255(c, 255) == c` for all c — the identity behind the session's `isFull`
        // shortcut.
        for c in UInt8.min...UInt8.max {
            #expect(BlendOps.mul255(c, 255) == c, "mul255(\(c), 255)")
        }
        let points = (0..<8).map { _ in
            CGPoint(x: rng.double(in: 10...90), y: rng.double(in: 10...90))
        }
        func run(_ installSelectAll: Bool) -> [UInt64] {
            let context = whiteContext()
            if installSelectAll {
                context.performHistory(SelectionHistoryItem(
                    name: "Select All", icon: .selectAll, before: nil,
                    after: .all(canvasSize: size)))
            }
            setBrush(context, tool: .paintbrush, width: 7, hardness: 60, antialiasing: true)
            let tool = PaintbrushTool()
            tool.mouseDown(event(points[0]), context: context)
            for point in points.dropFirst() { tool.mouseDragged(event(point), context: context) }
            tool.mouseUp(event(points[5]), context: context)
            return context.image.layers[0].surface.allocatedTileCoordinates
                .sorted()
                .map { coordinate -> UInt64 in
                    guard let tile = context.image.layers[0].surface.tile(at: coordinate) else {
                        return 0
                    }
                    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
                    for byte in tile.bytes {
                        hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
                    }
                    return hash
                }
        }
        #expect(run(true) == run(false), "Select All paints pixel-identically to no selection")
    }

    // MARK: - Pencil and Eraser

    @Test func pencilClippedToRect() throws {
        let context = whiteContext()
        try installSelection(context, rect: CGRect(x: 40, y: 0, width: 20, height: 100))
        let tool = PencilTool()
        drag(tool, from: CGPoint(x: 0.5, y: 10.5), to: CGPoint(x: 99.5, y: 10.5),
             context: context, steps: 20)
        var changedColumns: [Int] = []
        for x in 0..<100 where pixel(context, x, 10) != white { changedColumns.append(x) }
        #expect(changedColumns == Array(40...59), "only the selection's columns changed")
    }

    @Test func eraserClippedToRect() throws {
        let context = whiteContext()
        context.colors = ColorSelection(primary: ColorRGBA8(red: 0, green: 0, blue: 0,
                                                            alpha: 255), secondary: .black)
        try installSelection(context, rect: CGRect(x: 40, y: 0, width: 20, height: 100))
        setBrush(context, tool: .eraser, width: 10, hardness: 100, antialiasing: true)
        let tool = EraserTool()
        tool.mouseDown(event(CGPoint(x: 50.5, y: 50.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 50.5, y: 50.5)), context: context)
        let erased = pixel(context, 50, 50)
        #expect(erased.alpha == 0, "fully erased → (0, 0, 0, 0) per 0011")
        #expect(erased == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0))
        #expect(pixel(context, 30, 50) == white, "outside the selection nothing erased")
    }

    @Test func invertedSelectionClipsOutside() throws {
        let context = whiteContext()
        try installSelection(context, rect: CGRect(x: 40, y: 0, width: 20, height: 100),
                             inverted: true)
        setBrush(context, tool: .paintbrush, width: 6, hardness: 100, antialiasing: true)
        let tool = PaintbrushTool()
        drag(tool, from: CGPoint(x: 2.5, y: 50.5), to: CGPoint(x: 97.5, y: 50.5),
             context: context)
        #expect(pixel(context, 5, 50) == black, "outside the rect is now selected")
        #expect(pixel(context, 50, 50) == white, "inside the rect is now clipped")
    }

    @Test func clipCapturedAtMouseDown() throws {
        // The stroke keeps the mouse-down mask even when the selection changes mid-stroke
        // (0009's contract).
        let context = whiteContext()
        let first = try #require(Selection(rect: CGRect(x: 0, y: 0, width: 50, height: 100),
                                           canvasSize: size))
        context.performHistory(SelectionHistoryItem(name: "Rectangle Select",
                                                    icon: .rectangleSelect,
                                                    before: nil, after: first))
        setBrush(context, tool: .paintbrush, width: 6, hardness: 100, antialiasing: true)
        let tool = PaintbrushTool()
        let start = CGPoint(x: 2.5, y: 50.5)
        tool.mouseDown(event(start), context: context)
        tool.mouseDragged(event(CGPoint(x: 40, y: 50.5)), context: context)
        // Swap the selection to the other half while the stroke is live.
        let second = try #require(Selection(rect: CGRect(x: 50, y: 0, width: 50, height: 100),
                                            canvasSize: size))
        context.performHistory(SelectionHistoryItem(name: "Rectangle Select",
                                                    icon: .rectangleSelect,
                                                    before: first, after: second))
        tool.mouseDragged(event(CGPoint(x: 97.5, y: 50.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 97.5, y: 50.5)), context: context)
        #expect(pixel(context, 5, 50) == black, "the mouse-down mask let the left half through")
        #expect(pixel(context, 95, 50) == white, "the mid-stroke change did not leak in")
    }
}
