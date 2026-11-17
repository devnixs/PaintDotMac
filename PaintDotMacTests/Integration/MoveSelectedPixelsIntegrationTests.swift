import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import PaintDotMac

/// The whole Move Selected Pixels stack (real `UndoBridge` + `HistoryStack` + the real
/// tool through a `BridgeToolContext`, spec 0020 *Test plan*): undo walks back through
/// the floating steps; commands finish first; Escape cancels the session exactly
/// (D-47a), including after budget folding (H-5); save never finishes; and a random
/// property sweep proves undo-all/redo-all identity. 8 × 8 layer
/// `L(x, y) = (x·30, y·30, 100, 255)`; the transform runs at zoom 8 so Paint.NET's 6-pt
/// nub radius leaves a nub-free interior (unit-suite rationale).
@MainActor
struct MoveSelectedPixelsIntegrationTests {
    private let size = PixelSize(width: 8, height: 8)

    private func l(_ x: Int, _ y: Int) -> ColorRGBA8 {
        ColorRGBA8(red: UInt8((30 * x) % 256), green: UInt8((30 * y) % 256), blue: 100, alpha: 255)
    }

    private func surface() -> TiledSurface {
        var surface = TiledSurface(size: size)
        for y in 0..<8 {
            for x in 0..<8 {
                surface.setPixel(l(x, y), at: PixelPoint(x: x, y: y))
            }
        }
        return surface
    }

    private func fixture(budgetBytes: Int = HistoryStack.defaultBudgetBytes) throws
        -> (MoveSelectedPixelsTool, BridgeToolContext, ToolDispatcher)
    {
        let context = BridgeToolContext(image: LayeredImage(surface: surface()),
                                        base: .newImage, budgetBytes: budgetBytes)
        context.nav.transform = CanvasTransform(
            imageSize: size, viewSize: CGSize(width: 64, height: 64),
            backingScale: 1, zoom: 8, center: CGPoint(x: 4, y: 4))
        if let selection = Selection(rect: CGRect(x: 2, y: 2, width: 3, height: 3),
                                     canvasSize: size) {
            context.performHistory(SelectionHistoryItem(name: "setup", icon: .generic,
                                                        before: nil, after: selection))
        }
        let tool = MoveSelectedPixelsTool()
        tool.activate(context: context)
        // The window controller's wiring (0020 item 9): navigation routes through the
        // dispatcher with the bridge's current reason.
        let dispatcher = ToolDispatcher(registry: .standard())
        dispatcher.setContext(context)
        context.bridge.prepareForNavigation = { [weak dispatcher, weak context] in
            guard let dispatcher, let context else { return }
            dispatcher.resolvePendingEdit(for: context.bridge.pendingEditReason)
        }
        return (tool, context, dispatcher)
    }

    private func event(_ context: BridgeToolContext, _ x: Double, _ y: Double,
                       button: ToolMouseButton = .primary,
                       modifiers: ToolModifiers = [], seed: Int = 0) -> ToolEvent {
        let location = CGPoint(x: x, y: y)
        return ToolEvent(location: location,
                         viewLocation: context.transform.canvasToView(location),
                         button: button, modifiers: modifiers,
                         clickCount: 1, pressure: 1, timestamp: Double(seed + 1))
    }

    private func drag(_ tool: MoveSelectedPixelsTool, _ context: BridgeToolContext,
                      from: CGPoint, to: CGPoint,
                      button: ToolMouseButton = .primary,
                      modifiers: ToolModifiers = []) {
        tool.mouseDown(event(context, from.x, from.y, button: button, modifiers: modifiers),
                       context: context)
        tool.mouseDragged(event(context, to.x, to.y, button: button, modifiers: modifiers),
                          context: context)
        tool.mouseUp(event(context, to.x, to.y, button: button, modifiers: modifiers),
                     context: context)
    }

    private func names(_ context: BridgeToolContext) -> [String] {
        context.bridge.history.steps.map(\.name)
    }

    // MARK: - Undo/redo through a session

    @Test func undoRedoThroughSession() throws {
        let (tool, context, _) = try fixture()
        let bridge = context.bridge
        let original = context.stateSnapshot
        drag(tool, context, from: CGPoint(x: 3, y: 3), to: CGPoint(x: 5, y: 3))   // +2
        let afterMove1 = context.stateSnapshot
        drag(tool, context, from: CGPoint(x: 5, y: 3), to: CGPoint(x: 5, y: 5))   // +2 y
        let afterMove2 = context.stateSnapshot
        // Shift-rotate 90°: angles are measured in the session's local space (shifted
        // by the two moves), so these points sit at local 0° and 90° around the center.
        drag(tool, context, from: CGPoint(x: 8.5, y: 5.5), to: CGPoint(x: 5.5, y: 8.5),
             button: .secondary, modifiers: .shift)
        let afterRotate = context.stateSnapshot
        #expect(tool.keyDown(ToolKeyEvent(key: .returnKey, characters: "", modifiers: [],
                                          isRepeat: false), context: context))
        let afterFinish = context.stateSnapshot
        #expect(names(context)
                    == ["New Image", "setup", "Move Pixels", "Move Pixels",
                        "Rotate Pixels", "Finish Pixels"])

        bridge.undo()  // Finish → floating again (angle 90), pixels unchanged (H-3)
        let restored = try #require(context.floatingPixels)
        // Local-space rotation: the Shift-snapped session sits exactly on 90°.
        #expect(abs(restored.session.angle - 90) <= 1e-9)
        #expect(context.stateSnapshot.image == afterRotate.image, "undoing Finish keeps pixels")
        bridge.undo()  // rotate undone → the unrotated move-2 state
        #expect(context.stateSnapshot == afterMove2)
        bridge.undo()  // move 2 undone → move 1 only
        #expect(context.stateSnapshot == afterMove1)
        bridge.undo()  // move 1 undone → original pixels and selection, nothing floating
        #expect(context.stateSnapshot.image == original.image)
        #expect(context.stateSnapshot.selection == original.selection)
        #expect(context.floatingPixels == nil)

        let states = [afterMove1, afterMove2, afterRotate, afterFinish]
        for (index, expected) in states.enumerated() {
            bridge.redo()
            #expect(context.stateSnapshot == expected, "redo \(index + 1) is byte-identical")
        }
    }

    @Test func commandFinishesFirst() throws {
        let (_, context, dispatcher) = try fixture()
        let bridge = context.bridge
        #expect(dispatcher.selectTool(.moveSelectedPixels))
        guard let tool = dispatcher.activeTool as? MoveSelectedPixelsTool else {
            Issue.record("expected the Move Selected Pixels tool")
            return
        }
        drag(tool, context, from: CGPoint(x: 3, y: 3), to: CGPoint(x: 5, y: 3))
        // The Deselect path: `prepareForNavigation` (reason `.command`) then the command.
        bridge.prepareForNavigation?()
        if let item = SelectionCommand.deselect.makeHistoryItem(for: bridge.state) {
            bridge.perform(item)
        }
        #expect(names(context).suffix(3) == ["Finish Pixels", "Deselect"]
                    || names(context) == ["New Image", "setup", "Move Pixels",
                                          "Finish Pixels", "Deselect"])
        #expect(context.floatingPixels == nil)
    }

    // MARK: - Escape (whole-session cancel)

    @Test func escapeCancelsExactly() throws {
        let (tool, context, _) = try fixture()
        let bridge = context.bridge
        let original = context.stateSnapshot
        drag(tool, context, from: CGPoint(x: 3, y: 3), to: CGPoint(x: 5, y: 3))
        drag(tool, context, from: CGPoint(x: 5, y: 3), to: CGPoint(x: 5, y: 5))
        // Rotate: the angle is measured in the session's local space (translated by
        // the two moves), so these points sit at local 0° and 90° around the center —
        // Shift-snapping leaves exactly 90°.
        drag(tool, context, from: CGPoint(x: 8.5, y: 5.5), to: CGPoint(x: 5.5, y: 8.5),
             button: .secondary, modifiers: .shift)
        #expect(bridge.history.currentIndex == 4)
        #expect(tool.keyDown(ToolKeyEvent(key: .escape, characters: "", modifiers: [],
                                          isRepeat: false), context: context))
        #expect(bridge.history.currentIndex == 1,
                "a jump back to the session start (the selection step precedes the lift)")
        #expect(context.stateSnapshot.image == original.image, "pixels exactly pre-session")
        #expect(context.stateSnapshot.selection == original.selection)
        #expect(context.floatingPixels == nil)
        #expect(bridge.history.canRedo, "the session's steps remain for redo")
        #expect(bridge.history.steps.count == 5, "base + setup + three redo steps")
    }

    @Test func escapeAfterBudgetFold() throws {
        // A ~700 KB budget folds the first (lift) step into the base while later small
        // steps survive (H-5), so Escape must restore through a new step, not a jump.
        let (tool, context, _) = try fixture(budgetBytes: 700_000)
        let bridge = context.bridge
        drag(tool, context, from: CGPoint(x: 3, y: 3), to: CGPoint(x: 5, y: 3))
        drag(tool, context, from: CGPoint(x: 5, y: 3), to: CGPoint(x: 5, y: 5))
        let stepsBefore = bridge.history.steps.count
        #expect(tool.keyDown(ToolKeyEvent(key: .escape, characters: "", modifiers: [],
                                          isRepeat: false), context: context))
        #expect(bridge.history.steps.last?.name == "Move Pixels",
                "a restoring step, not a jump")
        #expect(bridge.history.steps.count >= stepsBefore, "nothing lost by the fold")
        #expect(context.floatingPixels == nil)
        // Pixels and selection equal their exact pre-session values.
        for y in 2..<5 {
            for x in 2..<5 {
                #expect(context.image.activeLayer.surface
                            .pixel(at: PixelPoint(x: x, y: y)) == l(x, y), "(\(x), \(y))")
            }
        }
        #expect(context.selection?.bounds == PixelRect(x: 2, y: 2, width: 3, height: 3))
    }

    // MARK: - Save

    @Test func saveKeepsFloating() throws {
        let (tool, context, _) = try fixture()
        let bridge = context.bridge
        drag(tool, context, from: CGPoint(x: 3, y: 3), to: CGPoint(x: 5, y: 3))
        let steps = bridge.history.steps.count
        bridge.prepareForSave()
        #expect(bridge.history.steps.count == steps, "save records no step (D-47c)")
        #expect(context.floatingPixels != nil, "still floating afterwards")
        // The PNG contains the rendered layer: the hole is transparent, the destination
        // carries the moved pixels.
        let data = try ImageEncoder.encode(context.image, as: .png)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let cg = try #require(CGContext(
            data: &bytes, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cg.draw(decoded, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        func pixel(_ x: Int, _ y: Int) -> (r: Int, a: Int) {
            let offset = (y * 8 + x) * 4
            return (Int(bytes[offset]), Int(bytes[offset + 3]))
        }
        #expect(pixel(2, 2).a == 0, "the hole saves transparent")
        #expect(pixel(4, 2).a == 255 && pixel(4, 2).r == Int(l(2, 2).red),
                "the moved pixel landed in the file")
        #expect(pixel(0, 0).r == Int(l(0, 0).red))
        _ = tool
    }

    // MARK: - Random sessions (property)

    @Test(arguments: 0..<100)
    func randomSessionsUndoRedoIdentity(caseNumber: Int) throws {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(
            default: 0x2020_0020_0000 &+ UInt64(caseNumber)))
        let canvas = PixelSize(width: 600, height: 400)
        let context = BridgeToolContext(image: LayeredImage.blank(size: canvas, fill: .white),
                                        base: .newImage)
        context.nav.transform = CanvasTransform(
            imageSize: canvas, viewSize: CGSize(width: 600, height: 400),
            backingScale: 1, zoom: 1, center: CGPoint(x: 300, y: 200))
        let tool = MoveSelectedPixelsTool()
        tool.activate(context: context)
        // A random selection to start. (The no-selection → Select-All path would add a
        // second step inside one gesture, so every case starts selected; the Select-All
        // path itself is covered in MoveSelectedPixelsToolTests.)
        if let selection = Selection(rect: CGRect(x: Double(rng.int(in: 0...400)),
                                                  y: Double(rng.int(in: 0...250)),
                                                  width: Double(rng.int(in: 1...200)),
                                                  height: Double(rng.int(in: 1...150))),
                                     canvasSize: canvas) {
            context.performHistory(SelectionHistoryItem(name: "setup", icon: .generic,
                                                        before: nil, after: selection))
        }
        let base = context.stateSnapshot
        // The state first seen sitting on each recorded step id — the redo walk later
        // compares against it (jumps and redo-branch discarding make step ids the only
        // stable alignment across the random sequence).
        var stateByStepID: [HistoryStep.ID: DocumentState] = [:]
        func noteState() {
            let history = context.bridge.history
            let index = history.currentIndex
            guard history.steps.indices.contains(index),
                  history.steps[index].item != nil else { return }
            stateByStepID[history.steps[index].id] = context.stateSnapshot
        }
        noteState()
        var timestamp = 0.0
        func event(_ p: CGPoint, _ button: ToolMouseButton, _ modifiers: ToolModifiers)
            -> ToolEvent
        {
            timestamp += 1
            return ToolEvent(location: p, viewLocation: context.transform.canvasToView(p),
                             button: button, modifiers: modifiers,
                             clickCount: 1, pressure: 1, timestamp: timestamp)
        }
        for _ in 0..<rng.int(in: 1...6) {
            switch rng.int(in: 0...4) {
            case 0, 1:  // drag (any hitTest gesture), sometimes ⌘
                let start = CGPoint(x: rng.double(in: 0...600), y: rng.double(in: 0...400))
                let end = CGPoint(x: rng.double(in: 0...600), y: rng.double(in: 0...400))
                let modifiers: ToolModifiers = rng.int(in: 0...3) == 0 ? .command : []
                tool.mouseDown(event(start, .primary, modifiers), context: context)
                tool.mouseDragged(event(CGPoint(x: (start.x + end.x) / 2,
                                                y: (start.y + end.y) / 2),
                                        .primary, modifiers), context: context)
                tool.mouseUp(event(end, .primary, modifiers), context: context)
            case 2:  // rotate drag, sometimes Shift
                let start = CGPoint(x: rng.double(in: 0...600), y: rng.double(in: 0...400))
                let end = CGPoint(x: rng.double(in: 0...600), y: rng.double(in: 0...400))
                let modifiers: ToolModifiers = rng.int(in: 0...1) == 0 ? .shift : []
                tool.mouseDown(event(start, .secondary, modifiers), context: context)
                tool.mouseUp(event(end, .secondary, modifiers), context: context)
            case 3:  // nudge
                let keys: [ToolKey] = [.leftArrow, .rightArrow, .upArrow, .downArrow]
                let modifiers: ToolModifiers = rng.int(in: 0...2) == 0 ? .command : []
                _ = tool.keyDown(ToolKeyEvent(key: keys[rng.int(in: 0...3)],
                                              characters: "", modifiers: modifiers,
                                              isRepeat: false), context: context)
            default:  // finish or escape
                if rng.int(in: 0...1) == 0 {
                    tool.commit(context: context)
                } else {
                    _ = tool.keyDown(ToolKeyEvent(key: .escape, characters: "",
                                                  modifiers: [], isRepeat: false),
                                     context: context)
                }
            }
            // H-6: no-op gestures record no step — only new step positions are noted.
            noteState()
        }

        // Undo all → the base state exactly.
        let bridge = context.bridge
        var guardCount = 0
        while bridge.history.canUndo, guardCount < 100 {
            bridge.undo()
            guardCount += 1
        }
        #expect(context.stateSnapshot.image == base.image,
                "case \(caseNumber): undo-all restored the pixels (seed \(rng.seed))")
        #expect(context.stateSnapshot.selection == nil,
                "case \(caseNumber): undo-all undid the setup selection (seed \(rng.seed))")
        #expect(context.floatingPixels == nil)
        // Redo step by step → the exact state first recorded at each step id (Escape
        // jumps and redo-branch discarding make step ids the only stable alignment).
        var compared = 0
        var redoGuard = 0
        while bridge.history.canRedo, redoGuard < 200 {
            bridge.redo()
            redoGuard += 1
            let index = bridge.history.currentIndex
            let stepID = bridge.history.steps[index].id
            if let expected = stateByStepID[stepID] {
                let got = context.stateSnapshot
                #expect(got.image == expected.image,
                        "case \(caseNumber): redo step \(stepID) pixels")
                #expect(got.selection == expected.selection,
                        "case \(caseNumber): redo step \(stepID) selection")
                #expect(got.floatingPixels == expected.floatingPixels,
                        "case \(caseNumber): redo step \(stepID) floating")
                compared += 1
            }
        }
        #expect(compared > 0, "case \(caseNumber): the walk compared a recorded step")
    }
}

private extension BridgeToolContext {
    /// A snapshot of the whole undoable state (`state` is a value; this names the use).
    var stateSnapshot: DocumentState { bridge.state }
}
