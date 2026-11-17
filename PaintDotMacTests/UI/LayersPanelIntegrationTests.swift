import AppKit
import Foundation
import Testing

@testable import PaintDotMac

/// The Layers panel against the real 0008 bridge (spec 0025 *Test plan*, headless,
/// `@MainActor`): a `LayersPanelModel` bound to a real `UndoBridge`
/// (`groupsByEvent = false`, the documented bridge-test convention), 0010's
/// `BridgeToolContext` for the tool paths, and the Layer Properties dialog model driven
/// exactly as the window controller wires it.
@MainActor
@Suite(.serialized)
struct LayersPanelIntegrationTests {
    private let size = PixelSize(width: 64, height: 64)
    private let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
    private let green = ColorRGBA8(red: 0, green: 220, blue: 0, alpha: 255)

    /// A bridge over `layers`; one freshly bound panel.
    private func makeFixture(_ layers: [Layer], active: Int = 0)
        -> (BridgeToolContext, LayersPanelModel)
    {
        let image = LayeredImage(size: size, layers: layers, activeLayerIndex: active)
        let context = BridgeToolContext(image: image, base: .openImage)
        context.bridge.undoManager.groupsByEvent = false
        let panel = LayersPanelModel()
        panel.bind(to: context.bridge)
        return (context, panel)
    }

    private func layer(_ name: String, _ color: ColorRGBA8) -> Layer {
        var surface = TiledSurface(size: size)
        surface.fill(color)
        return Layer(name: name, surface: surface)
    }

    private func stepNames(_ context: BridgeToolContext) -> [String] {
        context.bridge.history.steps.map(\.name)
    }

    /// Lets the main actor drain the panel's coalesced refresh task (the headless test
    /// run loop does not drain main-actor work; the real app's `NSApplication` run loop
    /// does), then spins the loop so the hosted views catch up.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(10))
        pumpMainRunLoop()
    }

    /// Hard-blocks the main thread for `seconds` **without** pumping the run loop: work
    /// already queued on the main actor (a finished thumbnail render's apply task)
    /// stays queued until the block ends.
    @MainActor
    private func blockMainThread(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: - Selection is not an edit (H-6)

    @Test func selectLayerIsNotAHistoryStep() {
        let (context, panel) = makeFixture([layer("A", .white), layer("B", .black)])
        let bridge = context.bridge
        let stepsBefore = bridge.history.steps.count
        let revisionBefore = bridge.historyRevision
        #expect(bridge.history.isAtSavedState)

        panel.selectLayer(index: 1)
        #expect(bridge.state.image.activeLayerIndex == 1)
        #expect(bridge.history.steps.count == stepsBefore)
        #expect(bridge.historyRevision == revisionBefore, "no revision bump: no step")
        #expect(bridge.history.isAtSavedState, "selecting never marks the document edited")
        #expect(panel.model.activeIndex == 1)
        // Display order is top first: row 0 is layer 1 — the active one.
        #expect(panel.model.rows.first?.accessibilityValue == "active")
        #expect(panel.model.rows.last?.accessibilityValue == "inactive")

        panel.selectLayer(index: 1)   // already active: no-op
        panel.selectLayer(index: 5)   // out of range: no-op
        #expect(bridge.state.image.activeLayerIndex == 1)
    }

    // MARK: - Visibility steps

    @Test func toggleVisibilityStepAndComposite() async throws {
        let white = layer("Bottom", .white)
        let red = layer("Top", ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        let (context, panel) = makeFixture([white, red], active: 0)
        let bridge = context.bridge
        let compositor = CPUCompositor()
        func pixel00() -> ColorRGBA8? {
            compositor.compositeTile(TileCoordinate(column: 0, row: 0),
                                     of: bridge.state.image)?.first
        }
        #expect(pixel00() == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))

        panel.toggleVisibility(index: 1)
        #expect(stepNames(context).last == "Hide Layer")
        #expect(pixel00() == .white, "the hidden layer leaves the composite")
        #expect(panel.model.rows[0].isVisible == false)
        #expect(bridge.state.image.activeLayerIndex == 0, "the active layer is untouched")

        #expect(bridge.undoManager.undoMenuItemTitle == "Undo Hide Layer")

        bridge.undo()
        try await settle()
        #expect(pixel00() == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255))
        #expect(panel.model.rows[0].isVisible == true)
        #expect(bridge.undoManager.redoMenuItemTitle == "Redo Hide Layer")

        bridge.redo()
        try await settle()
        #expect(pixel00() == .white)
        #expect(panel.model.rows[0].isVisible == false)

        // Toggle the hidden layer again → "Show Layer".
        panel.toggleVisibility(index: 1)
        #expect(stepNames(context).last == "Show Layer")
    }

    // MARK: - Drag-reorder through the panel

    @Test func moveViaPanel() {
        let (context, panel) = makeFixture([layer("A", .white), layer("B", .black),
                                            layer("C", red)], active: 0)
        let bridge = context.bridge
        // Display rows are [C, B, A]; drag C (position 0) below B (insert before 2) —
        // layer 2 lands at index 1: the layer moved *down*, one "Move Layer Down" step.
        panel.move(displaySource: [0], displayDestination: 2)
        #expect(bridge.state.image.layers.map(\.name) == ["A", "C", "B"])
        #expect(bridge.state.image.activeLayerIndex == 1, "the moved layer is active")
        #expect(stepNames(context).count == 2, "exactly one step")
        #expect(stepNames(context).last == "Move Layer Down")
        bridge.undo()
        pumpMainRunLoop()
        #expect(bridge.state.image.layers.map(\.name) == ["A", "B", "C"])
        #expect(bridge.state.image.activeLayerIndex == 0)
        // A no-op drop records nothing.
        panel.move(displaySource: [1], displayDestination: 2)
        #expect(stepNames(context).count == 2)
    }

    // MARK: - Layer Properties dialog flow (the window controller's wiring)

    @Test func propertiesDialogFlow() throws {
        let (context, _) = makeFixture([layer("A", .white), layer("B", red)], active: 1)
        let bridge = context.bridge
        let layerID = bridge.state.image.layers[1].id
        let original = bridge.state.image.layers[1].properties
        let model = LayerPropertiesDialogModel(layerID: layerID, original: original) { edited in
            bridge.updateLiveState { state in
                guard let index = state.image.layerIndex(for: layerID) else { return }
                state.image.layers[index].properties = edited
            }
        }
        model.onCommit = { bridge.commit($0) }
        let stepsBefore = bridge.history.steps.count

        // Live preview: state shows the edits, no steps.
        model.edited.opacity = 128
        model.edited.name = "Glass"
        #expect(bridge.state.image.layers[1].opacity == 128)
        #expect(bridge.state.image.layers[1].name == "Glass")
        #expect(bridge.history.steps.count == stepsBefore)

        // Cancel restores everything, still no step.
        model.cancel()
        #expect(bridge.state.image.layers[1].properties == original)
        #expect(bridge.history.steps.count == stepsBefore)

        // Repeat and OK → exactly one "Layer Properties" step; undo/redo round-trip.
        model.edited.opacity = 128
        model.edited.name = "Glass"
        #expect(model.ok() != nil)
        #expect(bridge.history.steps.count == stepsBefore + 1)
        #expect(bridge.history.steps.last?.name == "Layer Properties")
        bridge.undo()
        #expect(bridge.state.image.layers[1].properties == original)
        bridge.redo()
        #expect(bridge.state.image.layers[1].opacity == 128)
        #expect(bridge.state.image.layers[1].name == "Glass")
    }

    // MARK: - Pending edits finish first (0020 item 9)

    @Test func panelActionsFinishFloatingPixelsFirst() throws {
        let base = layer("Background", .white)
        var painted = layer("Top", .clear)
        for y in 4..<12 {
            for x in 4..<12 {
                painted.surface.setPixel(.black, at: PixelPoint(x: x, y: y))
            }
        }
        let (context, panel) = makeFixture([base, painted], active: 1)
        let bridge = context.bridge
        context.nav.transform = CanvasTransform(
            imageSize: size, viewSize: CGSize(width: 64, height: 64),
            backingScale: 1, zoom: 4, center: CGPoint(x: 32, y: 32))
        let selection = try #require(
            Selection(rect: CGRect(x: 4, y: 4, width: 8, height: 8), canvasSize: size))
        context.performHistory(SelectionHistoryItem(name: "setup", icon: .generic,
                                                    before: nil, after: selection))
        // The window controller's wiring (0020 item 9).
        let dispatcher = ToolDispatcher(registry: .standard())
        dispatcher.setContext(context)
        context.dispatcher = dispatcher
        #expect(dispatcher.selectTool(.moveSelectedPixels))
        guard let tool = dispatcher.activeTool as? MoveSelectedPixelsTool else {
            Issue.record("expected the Move Selected Pixels tool")
            return
        }
        bridge.prepareForNavigation = { [weak dispatcher, weak context] in
            guard let dispatcher, let context else { return }
            dispatcher.resolvePendingEdit(for: context.bridge.pendingEditReason)
        }
        func event(_ x: Double, _ y: Double, _ seed: Int) -> ToolEvent {
            let location = CGPoint(x: x, y: y)
            return ToolEvent(location: location,
                             viewLocation: context.transform.canvasToView(location),
                             button: .primary, modifiers: [],
                             clickCount: 1, pressure: 1, timestamp: Double(seed + 1))
        }
        func drag(_ from: CGPoint, _ to: CGPoint, _ seed: Int) {
            tool.mouseDown(event(from.x, from.y, seed), context: context)
            tool.mouseDragged(event(to.x, to.y, seed + 100), context: context)
            tool.mouseUp(event(to.x, to.y, seed + 200), context: context)
        }
        let layer0Surface = bridge.state.image.layers[0].surface

        // Float pixels on layer 1, then select layer 0.
        drag(CGPoint(x: 6, y: 6), CGPoint(x: 10, y: 6), 0)   // +4 in x
        #expect(bridge.state.floatingPixels != nil)
        panel.selectLayer(index: 0)
        #expect(stepNames(context).suffix(2) == ["Move Pixels", "Finish Pixels"][...])
        #expect(bridge.state.floatingPixels == nil)
        #expect(bridge.state.image.activeLayerIndex == 0)
        // The moved pixels landed on layer 1; layer 0 is untouched.
        #expect(bridge.state.image.layers[1].surface.pixel(at: PixelPoint(x: 10, y: 6)) == .black)
        #expect(bridge.state.image.layers[0].surface == layer0Surface)

        // Float again on layer 1 (re-select it first), then toggle visibility.
        panel.selectLayer(index: 1)
        drag(CGPoint(x: 10, y: 6), CGPoint(x: 12, y: 6), 1_000)
        #expect(bridge.state.floatingPixels != nil)
        panel.toggleVisibility(index: 0)
        #expect(stepNames(context).suffix(2) == ["Finish Pixels", "Hide Layer"][...])
        #expect(bridge.state.floatingPixels == nil)
        #expect(bridge.state.image.layers[0].isVisible == false)

        // And once more, then drag-reorder through the panel.
        drag(CGPoint(x: 12, y: 6), CGPoint(x: 14, y: 6), 2_000)
        #expect(bridge.state.floatingPixels != nil)
        panel.move(displaySource: [1], displayDestination: 0)
        #expect(stepNames(context).suffix(2) == ["Finish Pixels", "Move Layer Up"][...])
        #expect(bridge.state.floatingPixels == nil)
        // The move's snapshot never captured a floating state (0020 item 9).
        let moveStep = try #require(bridge.history.steps.last)
        let snapshot = try #require(moveStep.item as? DocumentSnapshotHistoryItem)
        #expect(snapshot.before.floatingPixels == nil)
        #expect(snapshot.after.floatingPixels == nil)
    }

    // MARK: - Following documents

    @Test func followsActiveDocument() async throws {
        let panel = LayersPanelModel()
        #expect(panel.model == .empty)
        panel.bind(to: nil as UndoBridge?)
        #expect(panel.refreshCount == 1, "bind to nothing still rebuilds once")

        let (contextA, _) = makeFixture([layer("A1", .white), layer("A2", .black)])
        panel.bind(to: contextA.bridge)
        #expect(panel.model.rows.map(\.name) == ["A2", "A1"])
        let bridgeA = contextA.bridge

        let contextB = BridgeToolContext(
            image: LayeredImage(size: size,
                                layers: [layer("B1", .white), layer("B2", .black),
                                         layer("B3", red)],
                                activeLayerIndex: 2),
            base: .openImage)
        contextB.bridge.undoManager.groupsByEvent = false
        panel.bind(to: contextB.bridge)
        #expect(panel.model.rows.map(\.name) == ["B3", "B2", "B1"])

        panel.bind(to: nil as UndoBridge?)
        #expect(panel.model == .empty)
        for command in LayerPanelCommand.allCases {
            #expect(!panel.model.isEnabled(command), "\(command.rawValue)")
        }

        // One refresh per history change of the bound bridge.
        panel.bind(to: bridgeA)
        pumpMainRunLoop()
        let baseline = panel.refreshCount
        panel.toggleVisibility(index: 0)
        try await settle()
        #expect(panel.refreshCount == baseline + 1,
                "the action's own rebuild; the coalesced task is skipped")
        bridgeA.undo()
        try await settle()
        #expect(panel.refreshCount == baseline + 2)
    }

    // MARK: - Thumbnails

    /// A fixture whose clock the test drives.
    @MainActor
    private final class Clock {
        var now: TimeInterval = 0
    }

    @Test func thumbnailUpdatesAfterEdit() async throws {
        let context = BridgeToolContext(
            image: LayeredImage(size: size,
                                layers: [layer("Bottom", .white), layer("Top", .clear)],
                                activeLayerIndex: 0),
            base: .openImage)
        context.bridge.undoManager.groupsByEvent = false
        let panel = LayersPanelModel()
        let clock = Clock()
        panel.clock = { clock.now }
        panel.bind(to: context.bridge)
        let bridge = context.bridge
        let layer0 = bridge.state.image.layers[0].id
        let layer1 = bridge.state.image.layers[1].id

        func sample(_ id: Layer.ID, _ x: Int, _ y: Int) -> ColorRGBA8? {
            guard let cg = panel.thumbnails[id] else { return nil }
            var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            guard let ctx = CGContext(data: &bytes, width: cg.width, height: cg.height,
                                      bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            let offset = (y * cg.width + x) * 4
            return ColorRGBA8(red: bytes[offset], green: bytes[offset + 1],
                              blue: bytes[offset + 2], alpha: bytes[offset + 3])
        }
        func poll(_ body: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(2)
            while !body(), Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
                pumpMainRunLoop(for: 0.02)
            }
            #expect(body(), "thumbnail condition not met within 2 s")
        }

        // First render (leading edge at t = 0): both layers get thumbnails.
        try await poll { panel.thumbnails[layer0] != nil && panel.thumbnails[layer1] != nil }
        #expect(sample(layer0, 40, 40) == .white)

        // Paint a block on layer 0 (live write + commit), then advance the clock past
        // the throttle window: the sampled pixel becomes the painted color.
        let before = bridge.state.image.layers[0].surface
        bridge.updateLiveState { state in
            for y in 16..<48 {
                for x in 16..<48 {
                    state.image.layers[0].surface.setPixel(green, at: PixelPoint(x: x, y: y))
                }
            }
        }
        let after = bridge.state.image.layers[0].surface
        bridge.commit(TileDiffHistoryItem(name: "Paint", icon: .paintbrush,
                                          diff: TileDiff.between(before: before, after: after,
                                                                 layerID: layer0)))
        clock.now = 1.0   // ≥ 0.25 s after the last render start
        try await poll { sample(layer0, 40, 40) == green }

        // A deleted layer's thumbnail entry is dropped.
        panel.selectLayer(index: 1)
        guard let delete = LayerCommand.deleteLayer.makeHistoryItem(for: bridge.state) else {
            Issue.record("delete should be enabled")
            return
        }
        bridge.perform(delete)
        try await poll { panel.thumbnails[layer1] == nil }
        #expect(panel.thumbnails[layer0] != nil)
    }

    /// Switching documents while a render is in flight (spec edge case): document A's
    /// finished-but-unapplied result must never land in document B's panel. Blocking
    /// the main thread lets A's detached render *complete* while `bind(B)` is still
    /// queued ahead of the apply task, so the apply exercises the superseded-generation
    /// and live-layer checks — not just task cancellation.
    @Test func documentSwitchDropsInFlightThumbnailRender() async throws {
        var wide = TiledSurface(size: PixelSize(width: 1_200, height: 900))
        wide.fill(red)
        let contextA = BridgeToolContext(
            image: LayeredImage(size: PixelSize(width: 1_200, height: 900),
                                layers: [Layer(name: "Wide", surface: wide)],
                                activeLayerIndex: 0),
            base: .openImage)
        contextA.bridge.undoManager.groupsByEvent = false
        let panel = LayersPanelModel()
        let clock = Clock()
        panel.clock = { clock.now }
        panel.bind(to: contextA.bridge)
        let layerA = contextA.bridge.state.image.layers[0].id

        let contextB = BridgeToolContext(
            image: LayeredImage(size: size, layers: [layer("Small", .white)],
                                activeLayerIndex: 0),
            base: .openImage)
        contextB.bridge.undoManager.groupsByEvent = false
        let layerB = contextB.bridge.state.image.layers[0].id

        // A's 1200×900 render finishes in tens of ms in Debug; keep the main thread
        // (and with it the queued apply task) parked well past that, then switch
        // documents without ever yielding the main actor.
        blockMainThread(for: 0.5)
        clock.now = 1.0   // B's first render takes the leading edge at bind time
        panel.bind(to: contextB.bridge)

        func poll(_ body: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !body(), Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
                pumpMainRunLoop(for: 0.02)
            }
            #expect(body(), "document-switch thumbnail condition not met within 3 s")
        }
        try await poll { panel.thumbnails[layerB] != nil }
        // Let any stale apply (and a possible stale trailing render) land, then check
        // the panel holds *only* document B's layers.
        clock.now = 5.0
        try await settle()
        try await settle()
        #expect(panel.thumbnails[layerA] == nil, "document A's thumbnail leaked into B")
        #expect(Set(panel.thumbnails.keys) == [layerB])
    }

    /// A 100-layer document (spec edge: "a 100-layer document scrolls and thumbnails
    /// stream in without beachball"): the first open renders every layer in one
    /// detached batch — bounded, off the main actor, no crash.
    @Test func hundredLayerDocumentStreamsThumbnails() async throws {
        let layers = (0..<100).map { index in
            layer("L\(index)", ColorRGBA8(red: UInt8(index), green: 0, blue: 0, alpha: 255))
        }
        let context = BridgeToolContext(
            image: LayeredImage(size: size, layers: layers, activeLayerIndex: 99),
            base: .openImage)
        context.bridge.undoManager.groupsByEvent = false
        let panel = LayersPanelModel()
        let clock = Clock()
        panel.clock = { clock.now }
        panel.bind(to: context.bridge)

        let deadline = Date().addingTimeInterval(10)
        while panel.thumbnails.count < 100, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            pumpMainRunLoop(for: 0.02)
        }
        #expect(panel.thumbnails.count == 100,
                "only \(panel.thumbnails.count) of 100 thumbnails arrived")
        #expect(Set(panel.thumbnails.keys) == Set(layers.map(\.id)))
    }
}
