import CoreGraphics
import Foundation
import Testing
@testable import PaintDotMac

/// `LassoSelectTool` against `FakeToolContext` (spec 0015 *Test plan*). Expected masks
/// are hand-computed from pixel-center containment (0013's aliased rule) or set algebra
/// on oracle masks — never from the tool. Events carry explicit timestamps; `viewLocation`
/// equals `location` unless stated (the fake's transform is 100 %, backing scale 1).
@MainActor
struct LassoSelectToolTests {
    private func event(_ x: Double, _ y: Double, _ t: TimeInterval,
                       view: CGPoint? = nil,
                       button: ToolMouseButton = .primary,
                       modifiers: ToolModifiers = [],
                       clickCount: Int = 1) -> ToolEvent {
        ToolEvent(location: CGPoint(x: x, y: y),
                  viewLocation: view ?? CGPoint(x: x, y: y),
                  button: button, modifiers: modifiers, clickCount: clickCount,
                  pressure: 1, timestamp: t)
    }

    private func keyEvent(_ key: ToolKey) -> ToolKeyEvent {
        ToolKeyEvent(key: key, characters: "", modifiers: [], isRepeat: false)
    }

    /// Pixelated clipping for the mask assertions.
    private func pixelated(_ context: FakeToolContext) {
        context.memoryOptions.setValue(SelectionQuality.pixelated,
                                       for: SelectionToolOptions.quality)
    }

    /// Install a pixelated existing selection through the history path.
    private func setExisting(_ context: FakeToolContext, _ rect: PixelRect) {
        let selection = Selection(rect: CGRect(x: Double(rect.x), y: Double(rect.y),
                                               width: Double(rect.width),
                                               height: Double(rect.height)),
                                  canvasSize: context.image.size, antialiased: false)
        context.performHistory(SelectionHistoryItem(name: "setup", icon: .generic,
                                                    before: nil, after: selection))
    }

    private func coverage(_ selection: Selection?, _ x: Int, _ y: Int) -> UInt8 {
        selection?.mask.coverage(x: x, y: y) ?? 0
    }

    /// The 0013 aliased rule as an independent oracle: a pixel is selected exactly when
    /// its center lies in the even-odd-normalized outline.
    private func containmentMask(_ vertices: [(Double, Double)],
                                 size: PixelSize) -> ReferenceMask {
        let outline = CGMutablePath()
        let points = vertices.map { CGPoint(x: $0.0, y: $0.1) }
        outline.move(to: points[0])
        for p in points.dropFirst() { outline.addLine(to: p) }
        outline.closeSubpath()
        let closed = outline.normalized(using: .evenOdd)
        return ReferenceMask(size: size) { x, y in
            closed.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5),
                            using: .winding) ? 255 : 0
        }
    }

    /// D-39's even-odd law derived from scratch, with **no CoreGraphics involved**: a
    /// pixel is selected exactly when the ray from its center to +x crosses the closed
    /// polyline an odd number of times (Sutherland–Atkinson half-open edge rule). This is
    /// the independent oracle for self-crossing outlines — `containmentMask` above reuses
    /// `normalized(using: .evenOdd)`, so it cannot catch a wrong normalization itself.
    private func parityMask(_ vertices: [(Double, Double)],
                            size: PixelSize) -> ReferenceMask {
        let n = vertices.count
        return ReferenceMask(size: size) { x, y in
            let cx = Double(x) + 0.5, cy = Double(y) + 0.5
            var crossings = 0
            for i in 0..<n {
                let (x1, y1) = vertices[i]
                let (x2, y2) = vertices[(i + 1) % n]
                if (y1 > cy) != (y2 > cy) {
                    let xHit = x1 + (cy - y1) / (y2 - y1) * (x2 - x1)
                    if cx < xHit { crossings += 1 }
                }
            }
            return crossings % 2 == 1 ? 255 : 0
        }
    }

    private func freeform(_ tool: LassoSelectTool, _ context: FakeToolContext,
                          _ points: [(Double, Double)], modifiers: ToolModifiers = [],
                          button: ToolMouseButton = .primary) {
        var time = 1.0
        tool.mouseDown(event(points[0].0, points[0].1, time,
                             button: button, modifiers: modifiers), context: context)
        for p in points.dropFirst() {
            time += 0.1
            tool.mouseDragged(event(p.0, p.1, time, button: button), context: context)
        }
        tool.mouseUp(event(points[points.count - 1].0, points[points.count - 1].1,
                           time + 0.1, button: button), context: context)
    }

    private func polygonClick(_ tool: LassoSelectTool, _ context: FakeToolContext,
                              _ p: (Double, Double), _ t: TimeInterval,
                              view: CGPoint? = nil, clickCount: Int = 1,
                              modifiers: ToolModifiers = [], pressOnly: Bool = false) {
        tool.mouseDown(event(p.0, p.1, t, view: view, modifiers: modifiers,
                             clickCount: clickCount), context: context)
        if !pressOnly {
            tool.mouseUp(event(p.0, p.1, t + 0.05, view: view), context: context)
        }
    }

    // MARK: - Freeform

    @Test func freeformSquareSelectsInterior() throws {
        let context = FakeToolContext()   // 64 × 64, no selection
        pixelated(context)
        let tool = LassoSelectTool()
        freeform(tool, context, [(2, 2), (10, 2), (10, 10), (2, 10)])

        #expect(context.history.steps.map(\.name) == ["New Image", "Lasso Select"])
        #expect(context.history.steps[1].icon == .lassoSelect)
        for y in 0..<64 {
            for x in 0..<64 {
                let inside = (2...9).contains(x) && (2...9).contains(y)
                #expect(coverage(context.selection, x, y) == (inside ? 255 : 0),
                        "(\(x), \(y)) \(inside ? "inside" : "outside")")
            }
        }
    }

    @Test func openOutlineClosesWithStraightLine() {
        let context = FakeToolContext()
        pixelated(context)
        let tool = LassoSelectTool()
        // Released at (20, 20): the outline closes along the straight line back to (2, 2).
        freeform(tool, context, [(2, 2), (20, 2), (20, 20)])
        #expect(coverage(context.selection, 15, 5) == 255)
        #expect(coverage(context.selection, 5, 15) == 0)
        containmentMask([(2, 2), (20, 2), (20, 20)], size: context.image.size)
            .matches(context.selection?.mask ?? SelectionMask(size: context.image.size),
                     comment: "right-triangle containment oracle")
    }

    @Test func pixelatedMaskIsBinary() throws {
        let context = FakeToolContext()
        pixelated(context)
        let tool = LassoSelectTool()
        freeform(tool, context, [(2, 2), (20, 2), (20, 20)])
        let mask = try #require(context.selection?.mask)
        for y in 0..<64 {
            for x in 0..<64 {
                let value = mask.coverage(x: x, y: y)
                #expect(value == 0 || value == 255, "(\(x), \(y)) = \(value)")
            }
        }
    }

    @Test func antialiasedEdgeIsPartial() {
        let context = FakeToolContext()
        // Default quality is Antialiased; state it explicitly for the spec's test.
        context.memoryOptions.setValue(SelectionQuality.antialiased,
                                       for: SelectionToolOptions.quality)
        let tool = LassoSelectTool()
        freeform(tool, context, [(2.5, 2.5), (10.5, 2.5), (10.5, 10.5), (2.5, 10.5)])
        let mask = context.selection?.mask
        for y in 3...9 {
            for x in 3...9 {
                #expect(mask?.coverage(x: x, y: y) == 255, "interior (\(x), \(y))")
            }
        }
        let edge = mask?.coverage(x: 2, y: 5) ?? 0
        #expect((126...129).contains(Int(edge)), "half-covered edge (2, 5) = \(edge)")
        let corner = mask?.coverage(x: 2, y: 2) ?? 0
        #expect((62...66).contains(Int(corner)), "quarter-covered corner (2, 2) = \(corner)")
        #expect(coverage(context.selection, 12, 12) == 0)
    }

    @Test func pentagramMask() {
        let context = FakeToolContext()
        pixelated(context)
        var vertices: [(Double, Double)] = []
        for k in [0, 2, 4, 1, 3] {
            let angle = (-90.0 + 72.0 * Double(k)) * .pi / 180.0
            vertices.append((32 + 20 * cos(angle), 32 + 20 * sin(angle)))
        }
        let tool = LassoSelectTool()
        freeform(tool, context, vertices)
        // Even-odd: the tip is selected, the doubly enclosed center is a hole (D-39).
        #expect(coverage(context.selection, 32, 15) == 255)
        #expect(coverage(context.selection, 31, 31) == 0)
    }

    /// D-39 end to end against the CG-free `parityMask`: a pentagram and an hourglass
    /// (self-crossing outlines) are compared **pixel by pixel** against the hand-written
    /// even-odd ray-parity law. The pentagram is the rule discriminator: its center
    /// pentagon has winding +2, so a winding-rule raster lights every pixel of it that
    /// parity leaves dark (spot-checked); the hourglass additionally pins the four-lobe
    /// shape of a self-crossing quadrilateral (both rules agree there).
    @Test func selfCrossingOutlinesMatchParityOraclePixelByPixel() throws {
        var star: [(Double, Double)] = []
        for k in [0, 2, 4, 1, 3] {
            let angle = (-90.0 + 72.0 * Double(k)) * .pi / 180.0
            star.append((32 + 20 * cos(angle), 32 + 20 * sin(angle)))
        }
        let context = FakeToolContext()
        pixelated(context)
        freeform(LassoSelectTool(), context, star)
        let starMask = try #require(context.selection?.mask)
        parityMask(star, size: context.image.size).matches(
            starMask, comment: "pentagram pixel-center even-odd parity")
        // The two laws disagree exactly where the outline double-covers: winding-rule
        // fills would light these pixels, so the match above pins even-odd, not CG.
        #expect(coverage(context.selection, 31, 31) == 0, "center pentagon: hole")
        #expect(parityMask(star, size: context.image.size).coverage(31, 31) == 0)

        // Hourglass A(10,10) B(30,10) C(10,26) D(30,26): diagonals cross at (20, 18).
        // Hand-derived even-odd region: top triangle + bottom triangle; the left
        // triangle is covered twice (hole), the right one zero times (outside).
        let hourglass: [(Double, Double)] = [(10, 10), (30, 10), (10, 26), (30, 26)]
        let context2 = FakeToolContext()
        pixelated(context2)
        freeform(LassoSelectTool(), context2, hourglass)
        let glassMask = try #require(context2.selection?.mask)
        parityMask(hourglass, size: context2.image.size).matches(
            glassMask, comment: "hourglass pixel-center even-odd parity")
        #expect(coverage(context2.selection, 20, 11) == 255, "top triangle")
        #expect(coverage(context2.selection, 20, 24) == 255, "bottom triangle")
        #expect(coverage(context2.selection, 12, 18) == 0,
                "oppositely double-covered left lobe is not selected")
        #expect(coverage(context2.selection, 26, 18) == 0, "zero-covered right triangle")
    }

    /// Normalization must be a no-op on the region of a simple clockwise (negative
    /// signed area) outline: the same 8 × 8 square as `freeformSquareSelectsInterior`,
    /// visited in the opposite order, selects exactly the same pixels.
    @Test func clockwiseSimpleOutlineSelectsSameRegion() {
        let context = FakeToolContext()
        pixelated(context)
        freeform(LassoSelectTool(), context,
                 [(2, 2), (2, 10), (10, 10), (10, 2)])   // clockwise
        for y in 0..<64 {
            for x in 0..<64 {
                let inside = (2...9).contains(x) && (2...9).contains(y)
                #expect(coverage(context.selection, x, y) == (inside ? 255 : 0),
                        "clockwise square (\(x), \(y))")
            }
        }
    }

    // MARK: - Polygon

    private func polygonTool(_ context: FakeToolContext) -> LassoSelectTool {
        context.memoryOptions.setValue(LassoMode.polygon.rawValue,
                                       for: LassoSelectTool.lassoModeKey)
        return LassoSelectTool()
    }

    @Test func polygonClicksThenReturn() {
        let context = FakeToolContext()
        pixelated(context)
        let tool = polygonTool(context)
        polygonClick(tool, context, (2, 2), 1.0)
        polygonClick(tool, context, (20, 2), 2.0)
        polygonClick(tool, context, (20, 20), 3.0)
        #expect(tool.hasPendingEdit)
        #expect(tool.keyDown(keyEvent(.returnKey), context: context))
        #expect(!tool.hasPendingEdit)
        #expect(context.history.steps.map(\.name) == ["New Image", "Lasso Select"])
        #expect(coverage(context.selection, 15, 5) == 255)
        #expect(coverage(context.selection, 5, 15) == 0)
    }

    @Test func polygonDoubleClickFinishes() {
        let context = FakeToolContext()
        pixelated(context)
        let tool = polygonTool(context)
        polygonClick(tool, context, (2, 2), 1.0)
        polygonClick(tool, context, (20, 2), 2.0)
        polygonClick(tool, context, (20, 20), 3.0)
        // The double-click's first click already placed the vertex; the second only
        // finishes — no duplicate is added.
        polygonClick(tool, context, (30, 30), 4.0, clickCount: 2, pressOnly: true)
        #expect(tool.path.points.count == 3, "no vertex added by the finishing click")
        tool.mouseUp(event(30, 30, 4.05), context: context)
        #expect(coverage(context.selection, 15, 5) == 255)
        #expect(coverage(context.selection, 5, 15) == 0)
        #expect(context.history.steps.map(\.name) == ["New Image", "Lasso Select"])
    }

    @Test func polygonClickOnFirstVertexCloses() {
        let context = FakeToolContext()
        context.nav.transform = CanvasTransform(
            imageSize: PixelSize(width: 64, height: 64),
            viewSize: CGSize(width: 800, height: 600), backingScale: 1, zoom: 1,
            center: CGPoint(x: 32, y: 32))
        pixelated(context)
        let tool = polygonTool(context)
        polygonClick(tool, context, (10, 10), 1.0)
        polygonClick(tool, context, (26, 10), 2.0)
        polygonClick(tool, context, (18, 24), 3.0)
        let firstView = context.transform.canvasToView(CGPoint(x: 10, y: 10))
        // 4 view points from the first vertex (≥ 3 vertices) → close.
        polygonClick(tool, context, (11, 10), 4.0,
                     view: CGPoint(x: firstView.x + 4, y: firstView.y))
        #expect(!tool.hasPendingEdit, "the polygon closed")
        #expect(context.history.steps.map(\.name) == ["New Image", "Lasso Select"])

        // 7 view points away → a 4th vertex; still editing.
        polygonClick(tool, context, (10, 10), 5.0)
        polygonClick(tool, context, (26, 10), 6.0)
        polygonClick(tool, context, (18, 24), 7.0)
        polygonClick(tool, context, (17, 10), 8.0,
                     view: CGPoint(x: firstView.x + 7, y: firstView.y))
        #expect(tool.hasPendingEdit)
        #expect(tool.path.points.count == 4)
    }

    /// The mode is latched at the first mouseDown of a POLYGON session (spec *Test plan*:
    /// "start with ⌘ held (union), release ⌘ during the drag/polygon → still Union"):
    /// later clicks without the modifier must not re-resolve it. With Replace the (4, 4)
    /// corner of the existing rectangle would be dropped.
    @Test func polygonModeFixedAtFirstMouseDown() {
        let context = FakeToolContext()
        pixelated(context)
        setExisting(context, PixelRect(x: 0, y: 0, width: 16, height: 16))
        let tool = polygonTool(context)
        polygonClick(tool, context, (8, 8), 1.0, modifiers: [.command])   // latches Union
        polygonClick(tool, context, (24, 8), 2.0)                         // ⌘ released
        polygonClick(tool, context, (24, 24), 3.0)
        #expect(tool.keyDown(keyEvent(.returnKey), context: context))
        // Union of A = 0…15 × 0…15 and the triangle (8,8),(24,8),(24,24).
        #expect(coverage(context.selection, 4, 4) == 255, "A survives: Union, not Replace")
        #expect(coverage(context.selection, 22, 12) == 255, "triangle interior added")
        #expect(coverage(context.selection, 10, 22) == 0, "outside both")
        #expect(context.history.steps.map(\.name) == ["New Image", "setup", "Lasso Select"])
    }

    /// The close-snap window is exactly ≤ 6 view points: 6.0 pt closes, 6.5 pt adds a
    /// vertex (the 4/7-pt cases in `polygonClickOnFirstVertexCloses` leave the boundary
    /// itself untested).
    @Test func polygonCloseSnapBoundary() {
        func started() -> (FakeToolContext, LassoSelectTool, CGPoint) {
            let context = FakeToolContext()
            context.nav.transform = CanvasTransform(
                imageSize: PixelSize(width: 64, height: 64),
                viewSize: CGSize(width: 800, height: 600), backingScale: 1, zoom: 1,
                center: CGPoint(x: 32, y: 32))
            pixelated(context)
            let tool = polygonTool(context)
            polygonClick(tool, context, (10, 10), 1.0)
            polygonClick(tool, context, (26, 10), 2.0)
            polygonClick(tool, context, (18, 24), 3.0)
            return (context, tool, context.transform.canvasToView(CGPoint(x: 10, y: 10)))
        }
        // Exactly 6.0 view points from vertex 0 → closes.
        let (context, tool, firstView) = started()
        polygonClick(tool, context, (16, 10), 4.0,
                     view: CGPoint(x: firstView.x + 6.0, y: firstView.y))
        #expect(!tool.hasPendingEdit, "6.0 pt is inside the snap window")
        #expect(context.history.steps.map(\.name) == ["New Image", "Lasso Select"])

        // 6.5 view points → a 4th vertex, still editing.
        let (context2, tool2, firstView2) = started()
        polygonClick(tool2, context2, (16, 10), 4.0,
                     view: CGPoint(x: firstView2.x + 6.5, y: firstView2.y))
        #expect(tool2.hasPendingEdit, "6.5 pt is outside the snap window")
        #expect(tool2.path.points.count == 4)
    }

    /// Two Polygon clicks on the same canvas point store a duplicate vertex; the closed
    /// path then contains a zero-length segment — normalization and rasterization must
    /// handle it and select the triangle of the distinct points.
    @Test func polygonDuplicateVertexIsHarmless() {
        let context = FakeToolContext()
        pixelated(context)
        let tool = polygonTool(context)
        polygonClick(tool, context, (5, 5), 1.0)
        polygonClick(tool, context, (5, 5), 2.0)     // duplicate — appended by design
        polygonClick(tool, context, (20, 5), 3.0)
        polygonClick(tool, context, (20, 21), 4.0)
        #expect(tool.path.points.count == 4)
        #expect(tool.keyDown(keyEvent(.returnKey), context: context))
        containmentMask([(5, 5), (20, 5), (20, 21)], size: context.image.size)
            .matches(context.selection?.mask ?? SelectionMask(size: context.image.size),
                     comment: "duplicate vertex selects the distinct-point triangle")
        #expect(context.history.steps.map(\.name) == ["New Image", "Lasso Select"])
    }

    @Test func polygonDragPositionsVertex() {
        let context = FakeToolContext()
        pixelated(context)
        let tool = polygonTool(context)
        polygonClick(tool, context, (2, 2), 1.0)
        // Press at (20, 2), drag to (30, 2), release → the vertex follows the pointer.
        tool.mouseDown(event(20, 2, 2.0), context: context)
        tool.mouseDragged(event(25, 2, 2.1), context: context)
        tool.mouseDragged(event(30, 2, 2.2), context: context)
        tool.mouseUp(event(30, 2, 2.3), context: context)
        #expect(tool.path.points.count == 2)
        #expect(tool.path.points[1] == CGPoint(x: 30, y: 2))
        #expect(tool.hasPendingEdit)
    }

    @Test func polygonEscapeCancels() {
        let context = FakeToolContext()
        pixelated(context)
        let tool = polygonTool(context)
        polygonClick(tool, context, (2, 2), 1.0)
        polygonClick(tool, context, (20, 2), 2.0)
        polygonClick(tool, context, (20, 20), 3.0)
        #expect(tool.keyDown(keyEvent(.escape), context: context))
        #expect(!tool.hasPendingEdit)
        #expect(context.history.steps.map(\.name) == ["New Image"], "Escape adds no step")
        #expect(context.selection == nil)
        #expect(context.overlays.last == .some(nil), "the overlay is cleared")
    }

    @Test func escapeDuringFreeformCancels() {
        let context = FakeToolContext()
        pixelated(context)
        let tool = LassoSelectTool()
        tool.mouseDown(event(2, 2, 1.0), context: context)
        tool.mouseDragged(event(10, 4, 1.1), context: context)
        #expect(tool.hasPendingEdit)
        #expect(tool.keyDown(keyEvent(.escape), context: context))
        #expect(!tool.hasPendingEdit)
        #expect(context.history.steps.map(\.name) == ["New Image"])
        #expect(context.selection == nil)
        #expect(context.overlays.last == .some(nil))
        // Idle after the cancel: later drags change nothing (the dispatcher swallows
        // events while the mouse is still down).
        let overlayCount = context.overlays.count
        tool.mouseDragged(event(20, 40, 1.2), context: context)
        #expect(context.overlays.count == overlayCount)
    }

    // MARK: - Click rule and modes

    @Test func clickActsLikeSelectionClick() {
        // Replace: a click clears the selection with the "Deselect" step.
        let context = FakeToolContext()
        pixelated(context)
        setExisting(context, PixelRect(x: 4, y: 4, width: 8, height: 8))
        let tool = LassoSelectTool()
        tool.mouseDown(event(30, 30, 1.0), context: context)
        tool.mouseUp(event(30, 30, 1.05), context: context)
        #expect(context.history.steps.map(\.name) == ["New Image", "setup", "Deselect"])
        #expect(context.selection == nil)

        // An append mode: the click does nothing.
        let context2 = FakeToolContext()
        pixelated(context2)
        setExisting(context2, PixelRect(x: 4, y: 4, width: 8, height: 8))
        let tool2 = LassoSelectTool()
        tool2.mouseDown(event(30, 30, 1.0, modifiers: [.command]), context: context2)
        tool2.mouseUp(event(30, 30, 1.05), context: context2)
        #expect(context2.history.steps.map(\.name) == ["New Image", "setup"])
        #expect(context2.selection?.bounds == PixelRect(x: 4, y: 4, width: 8, height: 8))
    }

    @Test func combineModes() throws {
        // Existing A = 0…15 × 0…15, lasso B = 8…23 × 8…23; per-pixel set algebra.
        let a: (Int, Int) -> Bool = { x, y in (0...15).contains(x) && (0...15).contains(y) }
        let b: (Int, Int) -> Bool = { x, y in (8...23).contains(x) && (8...23).contains(y) }
        for mode in SelectionCombineMode.allCases {
            let context = FakeToolContext()
            pixelated(context)
            setExisting(context, PixelRect(x: 0, y: 0, width: 16, height: 16))
            context.memoryOptions.setValue(mode, for: SelectionToolOptions.combineMode)
            let stepsBefore = context.history.steps.count

            let tool = LassoSelectTool()
            freeform(tool, context, [(8, 8), (24, 8), (24, 24), (8, 24)])

            #expect(context.history.steps.count == stepsBefore + 1, "\(mode)")
            #expect(context.history.steps.last?.name == "Lasso Select", "\(mode)")
            for y in 0..<64 {
                for x in 0..<64 {
                    let expected: Bool
                    switch mode {
                    case .replace: expected = b(x, y)
                    case .union: expected = a(x, y) || b(x, y)
                    case .exclude: expected = a(x, y) && !b(x, y)
                    case .intersect: expected = a(x, y) && b(x, y)
                    case .xor: expected = a(x, y) != b(x, y)
                    }
                    #expect(coverage(context.selection, x, y) == (expected ? 255 : 0),
                            "\(mode) at (\(x), \(y))")
                }
            }
        }
    }

    @Test func modeFixedAtFirstMouseDown() {
        // ⌘ at the first mouseDown → Union even though ⌘ is gone by mouseUp.
        let context = FakeToolContext()
        pixelated(context)
        setExisting(context, PixelRect(x: 0, y: 0, width: 16, height: 16))
        let tool = LassoSelectTool()
        tool.mouseDown(event(8, 8, 1.0, modifiers: [.command]), context: context)
        tool.mouseDragged(event(24, 8, 1.1), context: context)
        tool.mouseDragged(event(24, 24, 1.2), context: context)
        tool.mouseUp(event(24, 24, 1.3), context: context)
        #expect(coverage(context.selection, 20, 20) == 255, "union: outside the rect")
        #expect(coverage(context.selection, 4, 4) == 255, "union: inside the rect")

        // The 0014 modifier mapping at the first mouseDown (⌥ = Exclude, ⌥ + right =
        // Intersect, ⌘ + right = Invert).
        struct Case { var button: ToolMouseButton; var modifiers: ToolModifiers
                      var insideBoth: UInt8; var onlyB: UInt8; var onlyA: UInt8 }
        let cases: [Case] = [
            Case(button: .primary, modifiers: [.option], insideBoth: 0, onlyB: 0, onlyA: 255),
            Case(button: .secondary, modifiers: [.option], insideBoth: 255, onlyB: 0, onlyA: 0),
            Case(button: .secondary, modifiers: [.command], insideBoth: 0, onlyB: 255, onlyA: 255),
        ]
        for testCase in cases {
            let context2 = FakeToolContext()
            pixelated(context2)
            setExisting(context2, PixelRect(x: 0, y: 0, width: 16, height: 16))
            let tool2 = LassoSelectTool()
            tool2.mouseDown(event(8, 8, 1.0, button: testCase.button,
                                  modifiers: testCase.modifiers), context: context2)
            tool2.mouseDragged(event(24, 8, 1.1, button: testCase.button), context: context2)
            tool2.mouseDragged(event(24, 24, 1.2, button: testCase.button), context: context2)
            tool2.mouseUp(event(24, 24, 1.3, button: testCase.button), context: context2)
            #expect(coverage(context2.selection, 12, 12) == testCase.insideBoth,
                    "\(testCase.modifiers.rawValue) + \(testCase.button) overlap")
            #expect(coverage(context2.selection, 20, 20) == testCase.onlyB,
                    "\(testCase.modifiers.rawValue) + \(testCase.button) only-B")
            #expect(coverage(context2.selection, 4, 4) == testCase.onlyA,
                    "\(testCase.modifiers.rawValue) + \(testCase.button) only-A")
        }
    }

    // MARK: - History

    @Test func historyStepUndoRedo() throws {
        let context = FakeToolContext()
        pixelated(context)
        let tool = LassoSelectTool()
        freeform(tool, context, [(4, 4), (20, 4), (20, 20), (4, 20)])
        #expect(context.history.steps.map(\.name) == ["New Image", "Lasso Select"])
        #expect(context.history.steps[1].icon == .lassoSelect)
        let after = try #require(context.selection?.mask)

        context.navigateForTests { history, state in _ = history.undo(&state) }
        #expect(context.selection == nil, "undo restores the previous (no) selection")
        context.navigateForTests { history, state in _ = history.redo(&state) }
        #expect(context.selection?.mask == after, "redo re-applies the exact mask")
    }

    @Test func noOpUnionAddsNoStep() throws {
        let context = FakeToolContext()
        pixelated(context)
        setExisting(context, PixelRect(x: 0, y: 0, width: 32, height: 32))
        let stepsBefore = context.history.steps.count
        let tool = LassoSelectTool()
        tool.mouseDown(event(4, 4, 1.0, modifiers: [.command]), context: context)
        tool.mouseDragged(event(12, 4, 1.1), context: context)
        tool.mouseDragged(event(12, 12, 1.2), context: context)
        tool.mouseDragged(event(4, 12, 1.3), context: context)
        tool.mouseUp(event(4, 12, 1.4), context: context)
        // D-34: a Union fully inside the selection is a no-op → no step.
        #expect(context.history.steps.count == stepsBefore)
        #expect(context.selection?.bounds == PixelRect(x: 0, y: 0, width: 32, height: 32))
    }

    @Test func deactivateCommitsPolygon() {
        let context = FakeToolContext()
        pixelated(context)
        let tool = polygonTool(context)
        polygonClick(tool, context, (2, 2), 1.0)
        polygonClick(tool, context, (20, 2), 2.0)
        polygonClick(tool, context, (20, 20), 3.0)
        tool.deactivate(context: context)   // the tool switch keeps the work
        #expect(context.history.steps.map(\.name) == ["New Image", "Lasso Select"])
        #expect(!tool.hasPendingEdit)
    }

    @Test func modeChangeCommitsPolygon() {
        let context = FakeToolContext()
        pixelated(context)
        let tool = polygonTool(context)
        polygonClick(tool, context, (2, 2), 1.0)
        polygonClick(tool, context, (20, 2), 2.0)
        polygonClick(tool, context, (20, 20), 3.0)
        // An unrelated option change mid-polygon commits nothing…
        context.memoryOptions.setValue(SelectionQuality.antialiased,
                                       for: SelectionToolOptions.quality)
        tool.optionsDidChange(context: context)
        #expect(context.history.steps.count == 1)
        // …but changing the Lasso mode finishes the polygon (the work is kept).
        context.memoryOptions.setValue(LassoMode.freeform.rawValue,
                                       for: LassoSelectTool.lassoModeKey)
        tool.optionsDidChange(context: context)
        #expect(context.history.steps.map(\.name) == ["New Image", "Lasso Select"])
        #expect(!tool.hasPendingEdit)
    }

    @Test func commitFinishesPolygon() {
        let context = FakeToolContext()
        pixelated(context)
        let tool = polygonTool(context)
        polygonClick(tool, context, (2, 2), 1.0)
        polygonClick(tool, context, (20, 2), 2.0)
        polygonClick(tool, context, (20, 20), 3.0)
        tool.commit(context: context)   // 0008's prepareForNavigation path
        #expect(context.history.steps.map(\.name) == ["New Image", "Lasso Select"])
        #expect(coverage(context.selection, 15, 5) == 255)
        #expect(!tool.hasPendingEdit)
    }

    @Test func polygonTooFewVerticesActsAsClick() {
        let context = FakeToolContext()
        pixelated(context)
        setExisting(context, PixelRect(x: 4, y: 4, width: 8, height: 8))
        let tool = polygonTool(context)
        polygonClick(tool, context, (2, 2), 1.0)
        polygonClick(tool, context, (20, 2), 2.0)
        #expect(tool.keyDown(keyEvent(.returnKey), context: context))
        #expect(context.history.steps.map(\.name) == ["New Image", "setup", "Deselect"],
                "Replace with 2 vertices is the click rule")

        let context2 = FakeToolContext()
        pixelated(context2)
        setExisting(context2, PixelRect(x: 4, y: 4, width: 8, height: 8))
        let tool2 = polygonTool(context2)
        polygonClick(tool2, context2, (2, 2), 1.0, modifiers: [.command])
        polygonClick(tool2, context2, (20, 2), 2.0)
        _ = tool2.keyDown(keyEvent(.returnKey), context: context2)
        #expect(context2.history.steps.map(\.name) == ["New Image", "setup"],
                "Union with 2 vertices adds no step")
    }

    @Test func polygonDoubleClickFirstIsClick() {
        let context = FakeToolContext()
        pixelated(context)
        let tool = polygonTool(context)
        polygonClick(tool, context, (5, 5), 1.0)
        polygonClick(tool, context, (5, 5), 2.0, clickCount: 2, pressOnly: true)
        tool.mouseUp(event(5, 5, 2.05), context: context)
        // Degenerate finish → the click rule with no selection → nothing at all.
        #expect(context.history.steps.map(\.name) == ["New Image"])
        #expect(!tool.hasPendingEdit)
    }

    // MARK: - Options and transform

    @Test func lassoModeDefaultsAndPersistence() {
        let context = FakeToolContext()
        #expect(context.memoryOptions.value(LassoSelectTool.lassoModeKey) == "freeform",
                "default Freeform")

        context.memoryOptions.setValue("polygon", for: LassoSelectTool.lassoModeKey)
        #expect(context.memoryOptions.storedValue(forKey: "tool.lassoSelect.lassoMode")
                    as? String == "polygon")
        // A fresh tool instance reads the stored mode: a press/release pair stays in
        // editing (Polygon), it does not finish like Freeform.
        let context2 = FakeToolContext()
        context2.memoryOptions.setValue("polygon", for: LassoSelectTool.lassoModeKey)
        let tool = LassoSelectTool()
        tool.mouseDown(event(10, 10, 1.0), context: context2)
        tool.mouseUp(event(10, 10, 1.05), context: context2)
        #expect(tool.hasPendingEdit, "stored Polygon is honored by any instance")

        // An unknown stored string reads as Freeform: press/release finishes → idle.
        let context3 = FakeToolContext()
        context3.memoryOptions.setStoredValue("bogus",
                                              forKey: "tool.lassoSelect.lassoMode")
        let tool3 = LassoSelectTool()
        tool3.mouseDown(event(10, 10, 1.0), context: context3)
        tool3.mouseUp(event(10, 10, 1.05), context: context3)
        #expect(!tool3.hasPendingEdit)
        #expect(context3.history.steps.map(\.name) == ["New Image"])
    }

    @Test func closeSnapUsesCurrentTransform() {
        // 3 vertices placed at 100 %; the view then zooms to 400 %.
        let context = FakeToolContext()
        func transform(zoom: Double) -> CanvasTransform {
            CanvasTransform(imageSize: PixelSize(width: 64, height: 64),
                            viewSize: CGSize(width: 800, height: 600),
                            backingScale: 1, zoom: zoom, center: CGPoint(x: 32, y: 32))
        }
        context.nav.transform = transform(zoom: 1)
        pixelated(context)
        let tool = polygonTool(context)
        polygonClick(tool, context, (10, 10), 1.0)
        polygonClick(tool, context, (26, 10), 2.0)
        polygonClick(tool, context, (18, 24), 3.0)

        context.nav.transform = transform(zoom: 4)
        let firstView = context.transform.canvasToView(CGPoint(x: 10, y: 10))
        // 1 canvas px from vertex 0 = 4 view points at 400 % ≤ 6 → closes.
        let closeCanvas = context.transform.viewToCanvas(
            CGPoint(x: firstView.x + 4, y: firstView.y))
        polygonClick(tool, context, (closeCanvas.x, closeCanvas.y), 4.0,
                     view: CGPoint(x: firstView.x + 4, y: firstView.y))
        #expect(!tool.hasPendingEdit, "4 view points close the snap at 400 %")
        #expect(context.history.steps.map(\.name) == ["New Image", "Lasso Select"])

        // At 100 % the same 7 canvas px = 7 view points > 6 → a 4th vertex.
        let context2 = FakeToolContext()
        context2.nav.transform = transform(zoom: 1)
        pixelated(context2)
        let tool2 = polygonTool(context2)
        polygonClick(tool2, context2, (10, 10), 1.0)
        polygonClick(tool2, context2, (26, 10), 2.0)
        polygonClick(tool2, context2, (18, 24), 3.0)
        let firstView2 = context2.transform.canvasToView(CGPoint(x: 10, y: 10))
        polygonClick(tool2, context2, (17, 10), 4.0,
                     view: CGPoint(x: firstView2.x + 7, y: firstView2.y))
        #expect(tool2.hasPendingEdit)
        #expect(tool2.path.points.count == 4)
    }

    @Test func overlayFollowsGesture() {
        // Freeform: the kept points, no rubber band.
        let context = FakeToolContext()
        let tool = LassoSelectTool()
        tool.mouseDown(event(4, 4, 1.0), context: context)
        tool.mouseDragged(event(12, 4, 1.1), context: context)
        tool.mouseDragged(event(12, 12, 1.2), context: context)
        #expect(context.overlays.last
                    == .some(.lassoPath(points: [CGPoint(x: 4, y: 4), CGPoint(x: 12, y: 4),
                                                 CGPoint(x: 12, y: 12)],
                                        rubberBand: nil)))
        tool.mouseUp(event(12, 12, 1.3), context: context)
        #expect(context.overlays.last == .some(nil))

        // Polygon: mouseMoved sets the rubber band to the hover point.
        let context2 = FakeToolContext()
        let tool2 = polygonTool(context2)
        polygonClick(tool2, context2, (10, 10), 1.0)
        tool2.mouseMoved(event(15, 17, 2.0, clickCount: 0), context: context2)
        #expect(context2.overlays.last
                    == .some(.lassoPath(points: [CGPoint(x: 10, y: 10)],
                                        rubberBand: CGPoint(x: 15, y: 17))))
    }

    // MARK: - Edge cases

    @Test func offCanvasLasso() {
        // Replace with an existing selection → a "Lasso Select" step that clears it.
        let context = FakeToolContext()
        pixelated(context)
        setExisting(context, PixelRect(x: 4, y: 4, width: 8, height: 8))
        let tool = LassoSelectTool()
        freeform(tool, context, [(80, 80), (120, 80), (120, 120), (80, 120)])
        #expect(context.history.steps.map(\.name) == ["New Image", "setup", "Lasso Select"])
        #expect(context.selection == nil, "no canvas pixel covered → no selection")

        // No selection before → no-op, no step.
        let context2 = FakeToolContext()
        pixelated(context2)
        let tool2 = LassoSelectTool()
        freeform(tool2, context2, [(80, 80), (120, 80), (120, 120), (80, 120)])
        #expect(context2.history.steps.map(\.name) == ["New Image"])
        #expect(context2.selection == nil)
    }

    @Test func hugeCoordinatesDoNotCrash() {
        let context = FakeToolContext()
        pixelated(context)
        setExisting(context, PixelRect(x: 4, y: 4, width: 8, height: 8))
        let tool = LassoSelectTool()
        let e = 10_000_000.0
        freeform(tool, context, [(e, e), (e + 40, e), (e + 40, e + 40), (e, e + 40)])
        // Bounds stay Double, the mask clips to nothing: a Replace "Lasso Select"
        // clearing the selection, no crash, no overflow.
        #expect(context.history.steps.map(\.name) == ["New Image", "setup", "Lasso Select"])
        #expect(context.selection == nil)

        // 1e9 — the |value| ≤ 10⁹ Int-conversion bound of the selection gesture, and
        // ~4 × 10¹⁸ Double cross products in `isDegenerate`: still finite, no overflow.
        let context2 = FakeToolContext()
        pixelated(context2)
        setExisting(context2, PixelRect(x: 4, y: 4, width: 8, height: 8))
        let tool2 = LassoSelectTool()
        let g = 1e9
        freeform(tool2, context2,
                 [(g, g), (g + 40, g), (g + 40, g + 40), (g, g + 40)])
        #expect(context2.history.steps.map(\.name)
                    == ["New Image", "setup", "Lasso Select"])
        #expect(context2.selection == nil)

        // Negative far side of the same bound.
        let context3 = FakeToolContext()
        pixelated(context3)
        let tool3 = LassoSelectTool()
        freeform(tool3, context3,
                 [(-g, -g), (-g + 40, -g), (-g + 40, -g + 40), (-g, -g + 40)])
        #expect(context3.history.steps.map(\.name) == ["New Image"])
        #expect(context3.selection == nil)
    }

    @Test func crossesTileBoundaries() {
        // 300 × 300 spans 4 tiles; the diamond crosses every internal grid line.
        let context = FakeToolContext(size: PixelSize(width: 300, height: 300))
        pixelated(context)
        let tool = LassoSelectTool()
        freeform(tool, context, [(150, 10), (290, 150), (150, 290), (10, 150)])
        let mask = context.selection?.mask ?? SelectionMask(size: context.image.size)
        containmentMask([(150, 10), (290, 150), (150, 290), (10, 150)],
                        size: context.image.size)
            .matches(mask, comment: "diamond through four tiles")
    }

    @Test func onePixelImage() {
        let context = FakeToolContext(size: PixelSize(width: 1, height: 1))
        pixelated(context)
        let tool = LassoSelectTool()
        freeform(tool, context, [(-1, -1), (2, -1), (2, 2), (-1, 2)])
        #expect(coverage(context.selection, 0, 0) == 255)
        #expect(context.history.steps.map(\.name) == ["New Image", "Lasso Select"])
    }

    /// Baseline is overlay-recording-bound (the fake keeps 100 000 point-array snapshots,
    /// ≈ 11 s); 40 s leaves headroom while catching per-event normalization/rasterization
    /// (each would run hours across the loop), and the trait's hard time limit fails the
    /// test outright instead of hanging the suite.
    @Test(.timeLimit(.minutes(3)))
    func manyPointsCommit() {
        // A 100 000-point seeded random walk: commit finishes, values stay binary
        // (Pixelated), no crash. Guarding gross regressions, not a tuned benchmark.
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0015_DEAD_BEEF))
        let comment = Comment("\(rng.comment)")
        let context = FakeToolContext()
        pixelated(context)
        let tool = LassoSelectTool()

        var x = 32.0
        var y = 32.0
        let eventsStart = ContinuousClock.now
        var runaway = false
        tool.mouseDown(event(x, y, 1.0), context: context)
        for step in 1...100_000 {
            if rng.next() % 2 == 0 {
                x += rng.next() % 2 == 0 ? 2 : -2
            } else {
                y += rng.next() % 2 == 0 ? 2 : -2
            }
            tool.mouseDragged(event(x, y, 1.0 + Double(step)), context: context)
            // Time bound: a variant that thins→normalizes→rasterizes per event turns
            // the loop O(n²) and trips this; the healthy loop is ~10 s, dominated by
            // the fake's overlay snapshots (the clock read is tens of nanoseconds).
            // The break keeps a regression terminating instead of running for hours.
            if eventsStart.duration(to: ContinuousClock.now) >= .seconds(30) {
                runaway = true
                break
            }
            if step % 8192 == 0 {
                // Structurally: nothing is committed and no selection exists mid-drag —
                // per-event work may not touch the document.
                #expect(context.selection == nil, "no selection mid-drag \(comment)")
                #expect(context.history.steps.count == 1, "no step mid-drag \(comment)")
            }
        }
        let eventsElapsed = eventsStart.duration(to: ContinuousClock.now)
        // The loose timing bound covers the commit (the spec's "commit finishes"): one
        // rasterization of the finished 100 000-point outline, nothing per event.
        let commitStart = ContinuousClock.now
        tool.mouseUp(event(x, y, 100_001.0), context: context)
        let commitElapsed = commitStart.duration(to: ContinuousClock.now)

        #expect(context.history.steps.map(\.name) == ["New Image", "Lasso Select"], comment)
        let mask = context.selection?.mask ?? SelectionMask(size: context.image.size)
        var nonBinary = 0
        for row in 0..<64 {
            for col in 0..<64 where mask.coverage(x: col, y: row) != 0
                && mask.coverage(x: col, y: row) != 255 {
                nonBinary += 1
            }
        }
        #expect(nonBinary == 0, "Pixelated values are 0 or 255 \(comment)")
        #expect(commitElapsed < .seconds(2), "loose commit timing \(comment)")
        // Per-event work is the thinning test plus one append (NF-1): the loop above
        // breaks out at 30 s; finishing all 100 000 events below the bound means every
        // event stayed O(1) (a normal loop measures ~10 s with the fake's overlay
        // snapshots; per-event normalization/rasterization would run hours).
        #expect(!runaway, "loop self-limited — per-event work is not O(1) \(comment)")
        #expect(eventsElapsed < .seconds(30), "per-event work stays O(1) \(comment)")
    }

    // MARK: - Property test

    /// 200 seeded random polygons: apply → undo restores the exact prior mask, redo the
    /// exact result; applying Invert twice with the same lasso restores the original.
    @Test(arguments: [SeededRandom.resolvedSeed(default: 0x0015_0015_0015)])
    func undoRedoProperty(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        let size = PixelSize(width: 64, height: 64)
        for iteration in 0..<200 {
            // Random existing selection: none, or a pixelated rect.
            let existing: Selection? = rng.next() % 3 == 0 ? nil : {
                let rect = PixelRect(x: rng.int(in: 0...40), y: rng.int(in: 0...40),
                                     width: rng.int(in: 4...24), height: rng.int(in: 4...24))
                return Selection(rect: CGRect(x: Double(rect.x), y: Double(rect.y),
                                              width: Double(rect.width),
                                              height: Double(rect.height)),
                                 canvasSize: size, antialiased: false)
            }()
            // Random non-degenerate polygon: 3–12 vertices, ≥ 4 apart (no thinning loss).
            var vertices: [(Double, Double)] = []
            let vertexCount = rng.int(in: 3...12)
            var guardCount = 0
            while vertices.count < vertexCount, guardCount < 200 {
                guardCount += 1
                let p = (rng.double(in: 2...62), rng.double(in: 2...62))
                if vertices.allSatisfy({ hypot(p.0 - $0.0, p.1 - $0.1) >= 4 }) {
                    vertices.append(p)
                }
            }
            let mode = SelectionCombineMode.allCases[rng.int(in: 0...4)]
            let comment = Comment("iter=\(iteration) mode=\(mode) \(rng.comment)")
            guard vertices.count >= 3 else { continue }

            let refA = ReferenceMask(size: size) { x, y in existing?.mask.coverage(x: x, y: y) ?? 0 }
            let refB = containmentMask(vertices, size: size)
            let expected = refA.combined(with: refB, mode: mode)

            let context = FakeToolContext(size: size)
            pixelated(context)
            if let existing {
                context.performHistory(SelectionHistoryItem(name: "setup", icon: .generic,
                                                            before: nil, after: existing))
            }
            context.memoryOptions.setValue(mode, for: SelectionToolOptions.combineMode)
            let stepsBefore = context.history.steps.count

            let tool = LassoSelectTool()
            freeform(tool, context, vertices)

            let changed = expected.bytes != refA.bytes
            if changed {
                #expect(context.history.steps.count == stepsBefore + 1,
                        "coverage changed → one step \(comment)")
                #expect(context.history.steps.last?.name == "Lasso Select", comment)
            } else {
                #expect(context.history.steps.count == stepsBefore,
                        "D-34: no coverage change → no step \(comment)")
            }
            let afterMask = context.selection?.mask ?? SelectionMask(size: size)
            expected.matches(afterMask, comment: "combined mask \(comment)")
            if expected.isEmpty { #expect(context.selection == nil, comment) }
            guard changed else { continue }

            context.navigateForTests { history, state in _ = history.undo(&state) }
            #expect(context.selection?.mask == existing?.mask,
                    "undo restores the exact prior mask \(comment)")
            context.navigateForTests { history, state in _ = history.redo(&state) }
            #expect((context.selection?.mask ?? SelectionMask(size: size)) == afterMask,
                    "redo re-applies the exact result \(comment)")

            if mode == .xor {
                // Invert applied twice with the same lasso restores the original mask.
                let tool2 = LassoSelectTool()
                freeform(tool2, context, vertices)
                let back = context.selection?.mask ?? SelectionMask(size: size)
                refA.matches(back, comment: "xor twice restores the original \(comment)")
                if refA.isEmpty { #expect(context.selection == nil, comment) }
            }
        }
    }
}
