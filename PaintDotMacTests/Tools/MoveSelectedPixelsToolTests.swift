import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `MoveSelectedPixelsTool` against `FakeToolContext` (spec 0020 *Test plan*): 8 × 8
/// layer `L(x, y) = (x·30, y·30, 100, 255)`, rect selection (2, 2, 3, 3) unless stated,
/// base "New Image". Events carry canvas `location` and the derived `viewLocation`
/// (0019's helper idiom). The transform runs at zoom 8 (view 64 × 64 pt): Paint.NET's
/// 6-pt nub radius must not swallow the whole 3 × 3 box, so view points sit 8 px per
/// canvas pixel while every assertion below stays in canvas pixels (drag points are
/// unchanged from the plan).
@MainActor
struct MoveSelectedPixelsToolTests {
    private let size = PixelSize(width: 8, height: 8)

    private func l(_ x: Int, _ y: Int) -> ColorRGBA8 {
        ColorRGBA8(red: UInt8((30 * x) % 256), green: UInt8((30 * y) % 256), blue: 100, alpha: 255)
    }

    private func makeContext() -> FakeToolContext {
        var image = LayeredImage.blank(size: size, fill: .clear)
        for y in 0..<8 {
            for x in 0..<8 {
                image.activeLayer.surface.setPixel(l(x, y), at: PixelPoint(x: x, y: y))
            }
        }
        let context = FakeToolContext(image: image)
        context.nav.transform = CanvasTransform(
            imageSize: size, viewSize: CGSize(width: 64, height: 64),
            backingScale: 1, zoom: 8, center: CGPoint(x: 4, y: 4))
        return context
    }

    /// Activated tool + selection `rect` through a "setup" step; step-name assertions
    /// drop the setup with `names(afterSetup:)`.
    private func activated(rect: CGRect?) throws -> (MoveSelectedPixelsTool, FakeToolContext) {
        let context = makeContext()
        if let rect, let selection = Selection(rect: rect, canvasSize: size) {
            context.performHistory(SelectionHistoryItem(name: "setup", icon: .generic,
                                                        before: nil, after: selection))
        }
        let tool = MoveSelectedPixelsTool()
        tool.activate(context: context)
        return (tool, context)
    }

    private func event(_ context: FakeToolContext, _ x: Double, _ y: Double,
                       button: ToolMouseButton = .primary,
                       modifiers: ToolModifiers = []) -> ToolEvent {
        let location = CGPoint(x: x, y: y)
        return ToolEvent(location: location,
                         viewLocation: context.transform.canvasToView(location),
                         button: button, modifiers: modifiers,
                         clickCount: 1, pressure: 1, timestamp: 1)
    }

    private func key(_ key: ToolKey, _ modifiers: ToolModifiers = [],
                     repeat_: Bool = false) -> ToolKeyEvent {
        ToolKeyEvent(key: key, characters: "", modifiers: modifiers, isRepeat: repeat_)
    }

    /// down → (optional intermediate points) → up.
    private func drag(_ tool: MoveSelectedPixelsTool, _ context: FakeToolContext,
                      from: CGPoint, via: [CGPoint] = [], to: CGPoint,
                      button: ToolMouseButton = .primary,
                      modifiers: ToolModifiers = []) {
        tool.mouseDown(event(context, from.x, from.y, button: button, modifiers: modifiers),
                       context: context)
        for point in via {
            tool.mouseDragged(event(context, point.x, point.y, button: button,
                                    modifiers: modifiers), context: context)
        }
        tool.mouseUp(event(context, to.x, to.y, button: button, modifiers: modifiers),
                     context: context)
    }

    private func names(_ context: FakeToolContext) -> [String] {
        context.history.steps.map(\.name)
    }

    private func names(afterSetup context: FakeToolContext) -> [String] {
        Array(names(context).dropFirst(2))
    }

    private func pixel(_ context: FakeToolContext, _ x: Int, _ y: Int) -> ColorRGBA8 {
        context.image.activeLayer.surface.pixel(at: PixelPoint(x: x, y: y))
    }

    private func rectSelection(_ x: Double, _ y: Double, _ w: Double, _ h: Double) throws
        -> Selection
    {
        try #require(Selection(rect: CGRect(x: x, y: y, width: w, height: h), canvasSize: size))
    }

    private func preview(_ context: FakeToolContext) throws -> TransformHandlesPreview {
        guard case .transformHandles(let preview)? = context.lastOverlay else {
            Issue.record("expected a .transformHandles overlay, got \(String(describing: context.lastOverlay))")
            struct NotHandles: Error {}
            throw NotHandles()
        }
        return preview
    }

    // MARK: - Drags and steps

    @Test func dragRecordsOneStep() throws {
        let (tool, context) = try activated(rect: CGRect(x: 2, y: 2, width: 3, height: 3))
        let toolOverlayBefore = try preview(context)
        #expect(toolOverlayBefore.outline == nil && !toolOverlayBefore.hidesCurrentSelection)
        tool.mouseDown(event(context, 3, 3), context: context)
        tool.mouseDragged(event(context, 5, 3), context: context)
        let live = try preview(context)
        #expect(live.hidesCurrentSelection, "the live outline replaces the ants mid-drag")
        #expect(live.outline != nil)
        tool.mouseDragged(event(context, 7, 3), context: context)
        tool.mouseUp(event(context, 7, 3), context: context)
        #expect(names(afterSetup: context) == ["Move Pixels"])
        // Pixels as `FloatingPixelsTests.moveAndBackIsIdentity` at +4.
        for row in 2..<5 {
            #expect(pixel(context, 6, row) == l(2, row), "column 6")
            #expect(pixel(context, 7, row) == l(3, row), "column 7")
            #expect(pixel(context, 2, row) == .clear, "hole column 2")
            #expect(pixel(context, 4, row) == .clear, "hole column 4")
        }
        #expect(pixel(context, 5, 2) == l(5, 2), "outside hole and destination: unchanged")
        #expect(pixel(context, 0, 0) == l(0, 0))
        let floating = try #require(context.floatingPixels)
        #expect(floating.session.integerTranslation?.dx == 4
                    && floating.session.integerTranslation?.dy == 0)
        #expect(floating.resamplingMode == .nearestNeighbor)
        // Mask/bounds (not whole-`Selection ==`): the outline path keeps the unclipped
        // shifted rect; the mask — normative — is clipped like a fresh rect.
        #expect(context.selection?.mask == (try rectSelection(6, 2, 2, 3)).mask,
                "the selection moved with the pixels, clipped to the canvas")
        #expect(context.selection?.bounds == PixelRect(x: 6, y: 2, width: 2, height: 3))
        #expect(tool.hasPendingEdit)
        let idle = try preview(context)
        #expect(idle.outline == nil && !idle.hidesCurrentSelection)
    }

    @Test func secondDragAddsStep() throws {
        let (tool, context) = try activated(rect: CGRect(x: 2, y: 2, width: 3, height: 3))
        drag(tool, context, from: CGPoint(x: 3, y: 3), to: CGPoint(x: 7, y: 3))
        // Second drag (+0, +2) from inside the moved frame.
        drag(tool, context, from: CGPoint(x: 7, y: 3), to: CGPoint(x: 7, y: 5))
        #expect(names(afterSetup: context) == ["Move Pixels", "Move Pixels"])
        let floating = try #require(context.floatingPixels)
        #expect(floating.session.integerTranslation?.dx == 4
                    && floating.session.integerTranslation?.dy == 2)
        #expect(pixel(context, 6, 4) == l(2, 2), "second move stacked onto the first")
        #expect(pixel(context, 2, 2) == .clear, "the hole stays")
        // Regression (0021's first-drag fix): the second gesture's first move must
        // re-render the first drag's destination too — the strip of the first
        // destination (6, 2, 3, 3, clipped to the canvas at x = 7) that the second
        // destination no longer covers returns to the layer's own pixels.
        #expect(pixel(context, 6, 2) == l(6, 2), "no residue at the first destination")
        #expect(pixel(context, 7, 3) == l(7, 3), "no residue at the first destination")
    }

    /// Edge case "Tile boundaries" at the step level: on a 600 × 400 canvas the hole
    /// (columns 250–269, straddling tiles (0,0) and (1,0)) and the destination (columns
    /// 550–569, tile (2,0)) share no tile — the committed step's diff must cover BOTH
    /// regions, or undo leaves the un-vacated source behind.
    @MainActor
    @Test func crossTileDragRecordsFullStep() throws {
        let canvas = PixelSize(width: 600, height: 400)
        func color(_ x: Int, _ y: Int) -> ColorRGBA8 {
            ColorRGBA8(red: UInt8(x % 256), green: UInt8(y % 256), blue: 77, alpha: 255)
        }
        var image = LayeredImage.blank(size: canvas, fill: .clear)
        for y in 0..<400 {
            for x in 0..<600 {
                image.activeLayer.surface.setPixel(color(x, y), at: PixelPoint(x: x, y: y))
            }
        }
        let context = FakeToolContext(image: image)
        context.nav.transform = CanvasTransform(
            imageSize: canvas, viewSize: CGSize(width: 600, height: 400),
            backingScale: 1, zoom: 1, center: CGPoint(x: 300, y: 200))
        context.performHistory(SelectionHistoryItem(name: "setup", icon: .generic, before: nil,
                                                    after: try #require(
                                                        Selection(rect: CGRect(x: 250, y: 10,
                                                                                width: 20, height: 20),
                                                                    canvasSize: canvas))))
        let original = context.image.activeLayer.surface
        let tool = MoveSelectedPixelsTool()
        tool.activate(context: context)
        drag(tool, context, from: CGPoint(x: 260, y: 20), to: CGPoint(x: 560, y: 20))
        #expect(names(context) == ["New Image", "setup", "Move Pixels"])
        // Live after the committed step (apply re-lands the diff tiles): hole punched
        // across tile (0,0) and (1,0), pixels at tile (2,0).
        #expect(pixel(context, 250, 10) == .clear, "hole, tile (0,0)")
        #expect(pixel(context, 269, 29) == .clear, "hole, tile (1,0)")
        #expect(pixel(context, 550, 10) == color(250, 10), "destination, tile (2,0)")
        #expect(pixel(context, 569, 29) == color(269, 29), "destination, tile (2,0)")
        #expect(pixel(context, 249, 29) == color(249, 29), "outside: unchanged")
        #expect(pixel(context, 570, 10) == color(570, 10), "outside: unchanged")
        // Undo → byte-identical original (the diff carried the hole tiles too); redo →
        // the moved state.
        context.navigateForTests { history, state in _ = history.undo(&state) }
        #expect(context.image.activeLayer.surface == original, "undo restores the hole tile")
        var expected = original
        expected.fill(.clear, in: PixelRect(x: 250, y: 10, width: 20, height: 20))
        expected.writePixels(
            original.readPixels(in: PixelRect(x: 250, y: 10, width: 20, height: 20)),
            to: PixelRect(x: 550, y: 10, width: 20, height: 20))
        context.navigateForTests { history, state in _ = history.redo(&state) }
        #expect(context.image.activeLayer.surface == expected,
                "redo re-lands hole AND destination")
    }

    @Test func clickAddsNoPixelStep() throws {
        let (tool, context) = try activated(rect: CGRect(x: 2, y: 2, width: 3, height: 3))
        drag(tool, context, from: CGPoint(x: 3, y: 3), to: CGPoint(x: 3, y: 3))
        #expect(names(afterSetup: context) == [], "no movement → no step (H-6)")
        #expect(context.floatingPixels == nil)
        #expect(!tool.hasPendingEdit)
        for y in 2..<5 {
            for x in 2..<5 {
                #expect(pixel(context, x, y) == l(x, y), "pixels untouched at (\(x), \(y))")
            }
        }
    }

    @Test func returnFinishes() throws {
        let (tool, context) = try activated(rect: CGRect(x: 2, y: 2, width: 3, height: 3))
        drag(tool, context, from: CGPoint(x: 3, y: 3), to: CGPoint(x: 7, y: 3))
        let stateAfterMove = context.stateSnapshotForTests
        #expect(tool.keyDown(key(.returnKey), context: context))
        #expect(names(afterSetup: context).last == "Finish Pixels")
        #expect(context.floatingPixels == nil)
        #expect(!tool.hasPendingEdit)
        // The finish changes no pixels and no selection.
        #expect(context.image.activeLayer.surface
                    == stateAfterMove.image.activeLayer.surface)
        #expect(context.selection == stateAfterMove.selection)
        // Return with nothing pending → not handled.
        #expect(!tool.keyDown(key(.returnKey), context: context))
    }

    @Test func commitFinishes() throws {
        let (tool, context) = try activated(rect: CGRect(x: 2, y: 2, width: 3, height: 3))
        drag(tool, context, from: CGPoint(x: 3, y: 3), to: CGPoint(x: 7, y: 3))
        tool.commit(context: context)
        #expect(names(afterSetup: context).last == "Finish Pixels")
        #expect(context.floatingPixels == nil)
        // Commit with nothing pending records nothing.
        let stepsBefore = context.history.steps.count
        tool.commit(context: context)
        #expect(context.history.steps.count == stepsBefore)
    }

    @Test func deactivateFinishes() throws {
        let (tool, context) = try activated(rect: CGRect(x: 2, y: 2, width: 3, height: 3))
        drag(tool, context, from: CGPoint(x: 3, y: 3), to: CGPoint(x: 7, y: 3))
        tool.deactivate(context: context)
        #expect(names(afterSetup: context).last == "Finish Pixels")
        #expect(context.floatingPixels == nil)
        #expect(context.lastOverlay == nil, "the overlay is gone")
    }

    @Test func contextSwitchFinishesOldDocument() throws {
        let dispatcher = ToolDispatcher(registry: .standard())
        let contextA = makeContext()
        contextA.performHistory(SelectionHistoryItem(name: "setup", icon: .generic,
                                                     before: nil,
                                                     after: try rectSelection(2, 2, 3, 3)))
        dispatcher.setContext(contextA)
        #expect(dispatcher.selectTool(.moveSelectedPixels))
        guard let tool = dispatcher.activeTool as? MoveSelectedPixelsTool else {
            Issue.record("expected MoveSelectedPixelsTool")
            return
        }
        drag(tool, contextA, from: CGPoint(x: 3, y: 3), to: CGPoint(x: 5, y: 3))
        #expect(contextA.floatingPixels != nil)
        let contextB = makeContext()
        dispatcher.setContext(contextB)
        #expect(names(contextA).last == "Finish Pixels",
                "0006's setContext deactivates in the old document → Finish there")
        #expect(contextA.floatingPixels == nil)
        #expect(names(contextB) == ["New Image"], "the new document is untouched")
    }

    @Test func noSelectionSelectsAllFirst() throws {
        let (tool, context) = try activated(rect: nil)
        drag(tool, context, from: CGPoint(x: 3, y: 3), to: CGPoint(x: 4, y: 3))
        #expect(names(context) == ["New Image", "Select All", "Move Pixels"])
        // The whole layer lifted and moved (+1, 0): column 0 is the vacated edge.
        for y in 0..<8 {
            #expect(pixel(context, 0, y) == .clear, "column 0 clear at row \(y)")
            #expect(pixel(context, 7, y) == l(6, y), "column 7 carries column 6")
        }
        #expect(context.selection?.mask == (try rectSelection(1, 0, 7, 8)).mask)
        #expect(context.selection?.bounds == PixelRect(x: 1, y: 0, width: 7, height: 8))
    }

    // MARK: - ⌘ duplicates

    @Test func commandDragDuplicates() throws {
        let (tool, context) = try activated(rect: CGRect(x: 2, y: 2, width: 3, height: 3))
        drag(tool, context, from: CGPoint(x: 3, y: 3), to: CGPoint(x: 7, y: 3),
             modifiers: .command)
        // No hole: the original stays and a copy landed at +4.
        for row in 2..<5 {
            #expect(pixel(context, 2, row) == l(2, row), "original intact")
            #expect(pixel(context, 4, row) == l(4, row), "original intact")
            #expect(pixel(context, 6, row) == l(2, row), "copy at +4")
        }
        // A second ⌘-drag (net +2) stamps the current rendering and copies again.
        drag(tool, context, from: CGPoint(x: 7, y: 3), to: CGPoint(x: 5, y: 3),
             modifiers: .command)
        for row in 2..<5 {
            #expect(pixel(context, 2, row) == l(2, row), "first copy stays")
            #expect(pixel(context, 4, row) == l(2, row), "second copy lands at +2")
            #expect(pixel(context, 7, row) == l(3, row), "first copy still visible at 7")
        }
        #expect(names(afterSetup: context) == ["Move Pixels", "Move Pixels"])
    }

    // MARK: - Rotate / scale / flip gestures

    @Test func shiftRightDragRotates90Exactly() throws {
        let (tool, context) = try activated(rect: CGRect(x: 2, y: 2, width: 4, height: 4))
        // Right button always rotates; Shift snaps the total angle to 15° steps — here
        // the endpoints are exactly +90° about the box centre (4, 4).
        drag(tool, context, from: CGPoint(x: 8, y: 4), to: CGPoint(x: 4, y: 8),
             button: .secondary, modifiers: .shift)
        #expect(names(afterSetup: context) == ["Rotate Pixels"])
        let floating = try #require(context.floatingPixels)
        #expect(abs(floating.session.angle - 90) < 1e-9)
        for y in 2..<6 {
            for x in 2..<6 {
                #expect(pixel(context, x, y) == l(y, 7 - x),
                        "dest(\(x), \(y)) = L(\(y), \(7 - x))")
            }
        }
        #expect(pixel(context, 1, 1) == l(1, 1), "outside the rect unchanged")
        #expect(pixel(context, 6, 6) == l(6, 6))
        #expect(floating.resamplingMode == .bilinear, "rotation is never on the nearest path")
    }

    @Test func scaleSnapsToWholePixels() throws {
        let (tool, context) = try activated(rect: CGRect(x: 2, y: 2, width: 3, height: 3))
        drag(tool, context, from: CGPoint(x: 5, y: 3.5), to: CGPoint(x: 6.4, y: 3.5))
        let floating = try #require(context.floatingPixels)
        #expect(floating.session.canvasPosition(of: .right).x == 6,
                "the fractional point snapped: box maxX 6 exactly")
        #expect(floating.resamplingMode == .bilinear, "a 4/3 scale is not integral")
        #expect(names(afterSetup: context) == ["Scale Pixels"])
    }

    @Test func cornerDrag2xIsPixelReplication() throws {
        let (tool, context) = try activated(rect: CGRect(x: 2, y: 2, width: 2, height: 2))
        drag(tool, context, from: CGPoint(x: 4, y: 4), to: CGPoint(x: 6.2, y: 5.8))
        let floating = try #require(context.floatingPixels)
        #expect(floating.resamplingMode == .nearestNeighbor, "2× stays on the nearest path")
        // Each source pixel becomes a 2 × 2 block: (2+i, 2+j) → (2+2i…3+2i, 2+2j…3+2j).
        for sourceY in 0..<2 {
            for sourceX in 0..<2 {
                for offset in [0, 1] {
                    for offsetY in [0, 1] {
                        #expect(pixel(context, 2 + sourceX * 2 + offset,
                                      2 + sourceY * 2 + offsetY) == l(2 + sourceX, 2 + sourceY))
                    }
                }
            }
        }
        #expect(names(afterSetup: context) == ["Scale Pixels"])
    }

    @Test func flipThroughOppositeNub() throws {
        let (tool, context) = try activated(rect: CGRect(x: 2, y: 2, width: 3, height: 3))
        // Right nub (5, 3.5) dragged past the left edge to (−1, 3.5): the box flips
        // (x' = 4 − x); the source column 4 lands at −1 — off-canvas, kept floating.
        drag(tool, context, from: CGPoint(x: 5, y: 3.5), to: CGPoint(x: -1, y: 3.5))
        let floating = try #require(context.floatingPixels)
        #expect(floating.resamplingMode == .nearestNeighbor, "the flip is an integer mirror")
        #expect(floating.destinationBounds == PixelRect(x: 0, y: 2, width: 2, height: 3),
                "the flipped box spans (−1…2), clipped at 0")
        for y in 2..<5 {
            #expect(pixel(context, 1, y) == l(2, y), "column 1 = L(2, y)")
            #expect(pixel(context, 0, y) == l(3, y), "column 0 = L(3, y)")
            #expect(pixel(context, 2, y) == .clear, "hole")
            #expect(pixel(context, 4, y) == .clear, "hole")
            #expect(pixel(context, 5, y) == l(5, y), "outside unchanged")
        }
        // Column 4's pixels are off-canvas but survive in the source.
        for y in 2..<5 {
            #expect(floating.source.pixel(at: PixelPoint(x: 2, y: y - 2)) == l(4, y),
                    "source column 4 kept while floating")
        }
    }

    // MARK: - Arrow keys

    @Test func nudgeSteps() throws {
        let (tool, context) = try activated(rect: CGRect(x: 2, y: 2, width: 3, height: 3))
        #expect(tool.keyDown(key(.rightArrow), context: context))
        #expect(names(afterSetup: context) == ["Move Pixels"])
        for y in 2..<5 {
            #expect(pixel(context, 3, y) == l(2, y), "+1: column 3 carries column 2")
            #expect(pixel(context, 2, y) == .clear, "+1: hole at column 2")
        }
        #expect(tool.keyDown(key(.rightArrow, .command), context: context))
        let floating = try #require(context.floatingPixels)
        #expect(floating.session.integerTranslation?.dx == 11
                    && floating.session.integerTranslation?.dy == 0, "⌘→ is +10 px")
        #expect(floating.destinationBounds.isEmpty, "wholly off-canvas…")
        // …yet nothing is lost: the source is complete (D-47).
        #expect(floating.source.pixel(at: PixelPoint(x: 0, y: 0)) == l(2, 2))
        // The layer shows only the hole.
        for y in 2..<5 {
            for x in 2..<5 {
                #expect(pixel(context, x, y) == .clear, "hole (\(x), \(y))")
            }
        }
        #expect(tool.keyDown(key(.rightArrow, repeat_: true), context: context),
                "auto-repeat is a step too")
        #expect(names(afterSetup: context)
                    == ["Move Pixels", "Move Pixels", "Move Pixels"])
        #expect(tool.keyDown(key(.downArrow), context: context))
        #expect(floating.source.pixel(at: PixelPoint(x: 0, y: 0)) == l(2, 2))
        // Nudges are ignored while a drag tracks.
        tool.mouseDown(event(context, 3, 3), context: context)
        let steps = context.history.steps.count
        #expect(tool.keyDown(key(.leftArrow), context: context), "consumed…")
        #expect(context.history.steps.count == steps, "…but no step mid-drag")
        tool.mouseUp(event(context, 3, 3), context: context)
        #expect(context.history.steps.count == steps)
    }

    // MARK: - Escape and navigation

    @Test func escapeDuringDragCancelsOnlyDrag() throws {
        let (tool, context) = try activated(rect: CGRect(x: 2, y: 2, width: 3, height: 3))
        drag(tool, context, from: CGPoint(x: 3, y: 3), to: CGPoint(x: 5, y: 3))  // +2
        let stateAfterFirst = context.stateSnapshotForTests
        tool.mouseDown(event(context, 5, 3), context: context)
        tool.mouseDragged(event(context, 8, 3), context: context)  // live +3 → session +5
        #expect(pixel(context, 7, 2) == l(2, 2), "the live drag is visible")
        tool.cancel(context: context)  // Escape mid-gesture
        #expect(context.image.activeLayer.surface
                    == stateAfterFirst.image.activeLayer.surface,
                "only the drag rolled back")
        #expect(context.selection == stateAfterFirst.selection)
        let floating = try #require(context.floatingPixels)
        #expect(floating.session.integerTranslation?.dx == 2
                    && floating.session.integerTranslation?.dy == 0, "the session stays floating")
        #expect(names(afterSetup: context) == ["Move Pixels"], "no step from the cancelled drag")
        #expect(tool.hasPendingEdit, "still floating → still pending")
    }

    @Test func escapeWithoutFloatingNotHandled() throws {
        let (tool, context) = try activated(rect: CGRect(x: 2, y: 2, width: 3, height: 3))
        #expect(!tool.keyDown(key(.escape), context: context))
        tool.cancel(context: context)
        #expect(names(afterSetup: context) == [])
        #expect(context.floatingPixels == nil)
    }

    @Test func navigationCancelsDrag() throws {
        let (tool, context) = try activated(rect: CGRect(x: 2, y: 2, width: 3, height: 3))
        drag(tool, context, from: CGPoint(x: 3, y: 3), to: CGPoint(x: 5, y: 3))
        let preDrag = context.stateSnapshotForTests
        tool.mouseDown(event(context, 5, 3), context: context)
        tool.mouseDragged(event(context, 9, 6), context: context)
        tool.prepareForHistoryNavigation(context: context)
        #expect(context.image.activeLayer.surface == preDrag.image.activeLayer.surface,
                "the drag's pixels are gone")
        #expect(context.selection == preDrag.selection)
        #expect(names(afterSetup: context) == ["Move Pixels"], "and it recorded nothing")
        #expect(context.floatingPixels?.session.integerTranslation?.dx == 2
                    && context.floatingPixels?.session.integerTranslation?.dy == 0,
                "the session itself stays floating")
    }

    @Test func navigationKeepsFloating() throws {
        let (tool, context) = try activated(rect: CGRect(x: 2, y: 2, width: 3, height: 3))
        drag(tool, context, from: CGPoint(x: 3, y: 3), to: CGPoint(x: 5, y: 3))
        let before = context.stateSnapshotForTests
        tool.prepareForHistoryNavigation(context: context)
        #expect(names(afterSetup: context) == ["Move Pixels"], "no Finish step from navigation")
        #expect(context.floatingPixels != nil, "the pixels keep floating (D-47c)")
        #expect(context.stateSnapshotForTests == before)
    }

    // MARK: - Cursor

    @Test func cursorRoles() throws {
        let (tool, context) = try activated(rect: CGRect(x: 2, y: 2, width: 3, height: 3))
        func hover(_ x: Double, _ y: Double) {
            tool.mouseMoved(event(context, x, y), context: context)
        }
        hover(3, 3)  // inside the frame
        #expect(tool.cursor(at: context.transform.canvasToView(CGPoint(x: 3, y: 3)),
                            modifiers: []) == .move)
        let nub = CGPoint(x: 5, y: 3.5)
        hover(nub.x, nub.y)  // the right nub
        #expect(tool.cursor(at: context.transform.canvasToView(nub), modifiers: [])
                    == .resize(.right))
        let corridor = CGPoint(x: 6.15, y: 3.5)
        hover(corridor.x, corridor.y)  // just outside the right edge, past the nub radius
        #expect(tool.cursor(at: context.transform.canvasToView(corridor), modifiers: [])
                    == .rotate)
        #expect(tool.cursor(at: context.transform.canvasToView(corridor),
                            modifiers: [.shift]) == .rotate, "modifiers keep the role")
        #expect(tool.cursor(at: nil, modifiers: []) == .arrow)
        // Outside frame, nubs, corridor → the plain move arrow (a drag Selects All).
        let far = CGPoint(x: 3, y: 3)
        context.performHistory(SelectionHistoryItem(name: "deselect", icon: .generic,
                                                    before: context.selection, after: nil))
        hover(far.x, far.y)
        #expect(tool.cursor(at: context.transform.canvasToView(far), modifiers: []) == .move)
    }
}

private extension FakeToolContext {
    /// A snapshot to compare whole-state equality with (`state` is already a value; this
    /// names the intent).
    var stateSnapshotForTests: DocumentState { state }
}
