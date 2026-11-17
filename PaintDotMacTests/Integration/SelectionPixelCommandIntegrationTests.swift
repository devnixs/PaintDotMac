import AppKit
import Foundation
import Testing

@testable import PaintDotMac

/// Erase / Fill Selection end to end behind a real `UndoBridge` (spec 0018 *Test plan*):
/// the scripted user story through `BridgeToolContext`, the pending-edit commit order,
/// the primary color read at invocation time, and a property test proving undo/redo is
/// pixel- and selection-identical across random sessions. The window-level menu/keyboard
/// path is `EraseFillSelectionWindowIntegrationTests`.
@MainActor
@Suite(.serialized)
struct SelectionPixelCommandIntegrationTests {
    private func makeModel(suite: String = #function) -> (model: AppModel, suiteName: String) {
        let suiteName = "SelectionPixelCommandIntegrationTests.\(suite).\(UUID().uuidString)"
        let model = AppModel(defaults: UserDefaults(suiteName: suiteName)!)
        return (model, suiteName)
    }

    private func discard(_ suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    @Test func eraseFillSession() throws {
        let size = PixelSize(width: 200, height: 200)
        let context = BridgeToolContext(size: size, base: .openImage, fill: .white)
        let (model, suiteName) = makeModel()
        defer { discard(suiteName) }
        let bridge = context.bridge
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        model.setColor(red, for: .primary)

        // Rectangle Select (50, 50, 100, 100) — 0014's step.
        let selection = Selection(rect: CGRect(x: 50, y: 50, width: 100, height: 100),
                                  canvasSize: size)!
        bridge.perform(SelectionHistoryItem(name: "Rectangle Select", icon: .rectangleSelect,
                                            before: nil, after: selection))

        func pixel(_ x: Int, _ y: Int) -> ColorRGBA8 {
            bridge.state.image.layers[0].surface.pixel(at: PixelPoint(x: x, y: y))
        }

        // Fill Selection: the selection stays.
        DocumentWindowController.performSelectionPixelCommand(.fillSelection, bridge: bridge, model: model)
        #expect(bridge.state.selection == selection, "Fill keeps the selection active")
        #expect(pixel(100, 100) == red)
        #expect(pixel(50, 50) == red)
        #expect(pixel(20, 20) == .white)

        // Erase Selection: deselected.
        DocumentWindowController.performSelectionPixelCommand(.eraseSelection, bridge: bridge, model: model)
        #expect(bridge.state.selection == nil, "Erase deselects (EditMenu.html)")
        #expect(pixel(100, 100) == .clear)
        #expect(pixel(20, 20) == .white)
        #expect(bridge.history.steps.map(\.name)
                    == ["Open Image", "Rectangle Select", "Fill Selection", "Erase Selection"])
        #expect(bridge.undoManager.undoActionName == "Erase Selection")
        #expect(bridge.undoManager.undoMenuItemTitle == "Undo Erase Selection")

        // Undo Erase: rect red with the ants back (pixels and selection in one step).
        bridge.undo()
        #expect(pixel(100, 100) == red)
        #expect(pixel(20, 20) == .white)
        #expect(bridge.state.selection == selection, "one undo restores pixels and selection")
        // Undo Fill: white again; Fill never touched the selection, so the ants stay.
        bridge.undo()
        TestImages.expectPixels(bridge.state.image.layers[0].surface) { _, _ in .white }
        #expect(bridge.state.selection == selection, "undoing Fill keeps the selection")
        // Undo Rectangle Select: deselected.
        bridge.undo()
        #expect(bridge.state.selection == nil, "undoing the select step restores no selection")

        // Redo ×3: selected, filled, erased again — still deselected.
        bridge.redo()
        #expect(bridge.state.selection == selection)
        bridge.redo()
        #expect(bridge.state.selection == selection)
        #expect(pixel(100, 100) == red)
        bridge.redo()
        #expect(bridge.state.selection == nil)
        #expect(pixel(100, 100) == .clear)
        #expect(pixel(20, 20) == .white)
    }

    @Test func pendingEditCommitsFirst() throws {
        let size = PixelSize(width: 64, height: 64)
        let context = BridgeToolContext(size: size, base: .openImage, fill: .white)
        let (model, suiteName) = makeModel()
        defer { discard(suiteName) }
        let bridge = context.bridge

        // A pending Paintbrush stroke: live-drawn, uncommitted (0009's capture pattern).
        let stub = StubTool(id: .paintbrush)
        stub.hasPendingEdit = true
        let before = bridge.state.image
        bridge.updateLiveState { state in
            state.image.layers[0].surface.setPixel(.black, at: PixelPoint(x: 5, y: 5))
        }
        let strokeItem = TileDiffHistoryItem(
            name: "Paintbrush", icon: .paintbrush,
            diff: TileDiff.between(before: before.layers[0].surface,
                                    after: bridge.state.image.layers[0].surface,
                                    layerID: bridge.state.image.layers[0].id))
        bridge.prepareForNavigation = {
            guard stub.hasPendingEdit else { return }
            stub.hasPendingEdit = false
            stub.commit(context: context)   // what `dispatcher.commitPendingEdit` does
            bridge.commit(strokeItem)
        }

        DocumentWindowController.performSelectionPixelCommand(.eraseSelection, bridge: bridge, model: model)
        #expect(bridge.history.steps.map(\.name)
                    == ["Open Image", "Paintbrush", "Erase Selection"],
                "the pending edit records its own step first")
        #expect(stub.calls.contains("commit"))
        TestImages.expectPixels(bridge.state.image.layers[0].surface) { _, _ in .clear }

        // Undo the erase: the committed stroke pixel survives it.
        bridge.undo()
        #expect(bridge.state.image.layers[0].surface.pixel(at: PixelPoint(x: 5, y: 5)) == .black)
    }

    @Test func primaryReadAtCallTime() throws {
        let size = PixelSize(width: 64, height: 64)
        let context = BridgeToolContext(size: size, base: .openImage, fill: .white)
        let (model, suiteName) = makeModel()
        defer { discard(suiteName) }
        let green = ColorRGBA8(red: 0, green: 200, blue: 0, alpha: 255)
        // Change the primary right before the ⌥⌫ press: the command must see the change.
        model.setColor(green, for: .primary)
        DocumentWindowController.performSelectionPixelCommand(.fillSelection,
                                                              bridge: context.bridge, model: model)
        TestImages.expectPixels(context.bridge.state.image.layers[0].surface) { _, _ in green }
        #expect(context.bridge.history.steps.map(\.name) == ["Open Image", "Fill Selection"])
    }

    @Test func randomUndoRedoIdentity() throws {
        let size = PixelSize(width: 600, height: 400)
        let (model, suiteName) = makeModel()
        defer { discard(suiteName) }
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0018_5EED_0000_0001))
        for _ in 0..<50 {
            let surface0 = TiledSurface(size: size)
            var surface1 = TiledSurface(size: size)
            surface1.fill(ColorRGBA8(red: 250, green: 250, blue: 250, alpha: 255),
                          in: PixelRect(x: 0, y: 0, width: 600, height: 200))
            let context = BridgeToolContext(image: LayeredImage(
                size: size,
                layers: [Layer(name: "Bottom", surface: surface0),
                         Layer(name: "Top", surface: surface1)],
                activeLayerIndex: 1))
            let bridge = context.bridge
            // Recorded state after each action, base first.
            var states = [bridge.state]

            for _ in 0..<rng.int(in: 1...12) {
                let stepBefore = bridge.history.currentIndex
                switch rng.int(in: 0...5) {
                case 0:  // Rectangle Select
                    let rect = randomRect(&rng, size: size)
                    if let selection = Selection(rect: rect, canvasSize: size) {
                        bridge.perform(SelectionHistoryItem(name: "Rectangle Select",
                                                            icon: .rectangleSelect,
                                                            before: bridge.state.selection,
                                                            after: selection))
                    }
                case 1:  // Ellipse Select
                    let rect = randomRect(&rng, size: size)
                    let path = CGPath(ellipseIn: rect, transform: nil)
                    if let selection = Selection(path: path, canvasSize: size) {
                        bridge.perform(SelectionHistoryItem(name: "Ellipse Select",
                                                            icon: .ellipseSelect,
                                                            before: bridge.state.selection,
                                                            after: selection))
                    }
                case 2:  // Deselect
                    if let item = SelectionCommand.deselect.makeHistoryItem(for: bridge.state) {
                        bridge.perform(item)
                    }
                case 3:  // Fill Selection with a random primary (alpha 0 and 128 included)
                    let base = rng.color()
                    let alpha: UInt8 = [UInt8(0), 128, 255, rng.byte()].randomElement(using: &rng) ?? 255
                    let color = ColorRGBA8(red: base.red, green: base.green, blue: base.blue,
                                           alpha: alpha)
                    model.setColor(color, for: .primary)
                    DocumentWindowController.performSelectionPixelCommand(.fillSelection,
                                                                          bridge: bridge, model: model)
                case 4:  // Erase Selection
                    DocumentWindowController.performSelectionPixelCommand(.eraseSelection,
                                                                          bridge: bridge, model: model)
                default:  // Paintbrush stroke through the current clip (0013's session rule)
                    context.paintClipMask = bridge.state.selection?.mask
                    context.stroke(y: rng.int(in: 0...(size.height - 1)))
                }
                // Only a recorded step advances the stack (H-6); `states` stays aligned
                // with the steps, so each undo compares against the right entry.
                if bridge.history.currentIndex > stepBefore { states.append(bridge.state) }
            }

            // Undo everything: every step matches the recorded state.
            var index = states.count - 1
            while bridge.history.canUndo {
                bridge.undo()
                index -= 1
                assertStatesEqual(bridge.state, states[index], seed: rng.seed)
            }
            assertStatesEqual(bridge.state, states[0], seed: rng.seed)
            // Redo everything.
            while bridge.history.canRedo {
                bridge.redo()
                index += 1
                assertStatesEqual(bridge.state, states[index], seed: rng.seed)
            }
            #expect(index == states.count - 1, "seed=0x\(String(rng.seed, radix: 16, uppercase: true))")
        }
    }

    /// A rect that stays inside the canvas (a `Selection` must be non-empty).
    private func randomRect(_ rng: inout SeededRandom, size: PixelSize) -> CGRect {
        let x = rng.int(in: 0...(size.width - 2))
        let y = rng.int(in: 0...(size.height - 2))
        return CGRect(x: x, y: y,
                      width: rng.int(in: 1...(size.width - x)),
                      height: rng.int(in: 1...(size.height - y)))
    }

    private func assertStatesEqual(_ actual: DocumentState, _ expected: DocumentState,
                                   seed: UInt64,
                                   sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual == expected,
                "state mismatch — seed=0x\(String(seed, radix: 16, uppercase: true))",
                sourceLocation: sourceLocation)
    }
}
