import AppKit
import SwiftUI
import Testing

@testable import PaintDotMac

/// The Layers panel and the Layer Properties dialog at window level (spec 0025 *Test
/// plan*, headless): the real `NSHostingView(LayersPanelView)` inside the app-wide Layers
/// `NSPanel` (built by `PanelController`, never ordered on screen), driven through its
/// accessibility tree — row clicks and checkbox toggles are accessibility presses, the
/// same actions a mouse click takes. The dialog is presented through the
/// `layerPropertiesPresenter` seam with a recording presenter that keeps the
/// `NSHostingController` without showing a window; its model is the double-click / OK /
/// Cancel path itself.
@MainActor
@Suite(.serialized)
struct LayersPanelWindowIntegrationTests {
    private struct Fixture {
        let harness: DocumentHarness
        let panelController: PanelController
        /// The Layers panel's hosting view — the accessibility root.
        let root: NSView
        @MainActor var panel: LayersPanelModel { harness.appModel.layersPanel }
        @MainActor var bridge: UndoBridge { harness.document.undoBridge }
    }

    /// The recording `SheetPresenting`: keeps the controller (no window is ever shown),
    /// vends `isPresenting`, and runs the dismiss completion on `dismiss()`.
    final class RecordingSheetPresenter: SheetPresenting {
        private(set) var isPresenting = false
        private(set) var presentCount = 0
        private(set) var presented: NSViewController?
        private var completion: (() -> Void)?

        func present(_ controller: NSViewController, on window: NSWindow,
                     completion: @escaping () -> Void) {
            presentCount += 1
            guard !isPresenting else { return }   // a second present is a no-op
            presented = controller
            self.completion = completion
            isPresenting = true
        }

        func dismiss() {
            guard isPresenting else { return }
            isPresenting = false
            presented = nil
            let completion = self.completion
            self.completion = nil
            completion?()
        }
    }

    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    private func finish(_ fixture: Fixture) {
        fixture.harness.close()
        fixture.harness.discardAppModelSuite()
        cleanup()
    }

    /// A 200 × 150 opaque white PNG, the real Layers panel's hosting view as the AX root,
    /// and the window's session installed as the active one.
    private func setUp(_ fixtures: FixtureFiles) async throws -> Fixture {
        let url = try fixtures.writePNG(named: "layers-panel-fixture.png",
                                        width: 200, height: 150) { _, _ in .white }
        let harness = try await DocumentHarness.open(url)
        harness.document.undoBridge.undoManager.groupsByEvent = false
        let panelController = PanelController(model: harness.appModel)
        let root = try #require(panelController.panels[.layers]?.contentView)
        // Give the never-shown panel a real content size and force a layout pass so the
        // `List` realizes its rows off screen (their AX elements exist only after the
        // hosting collection view lays out).
        panelController.panels[.layers]?.setContentSize(NSSize(width: 260, height: 480))
        root.layoutSubtreeIfNeeded()
        harness.appModel.setActiveSession(harness.windowController.toolSession)
        pumpMainRunLoop()
        return Fixture(harness: harness, panelController: panelController, root: root)
    }

    private func addLayer(_ fixture: Fixture) async throws {
        fixture.harness.perform(NSSelectorFromString("addNewLayer:"))
        // The panel refreshes through the coalesced task; let it drain, then render.
        try await Task.sleep(for: .milliseconds(10))
        pumpMainRunLoop()
    }

    private func rowNames(_ fixture: Fixture) -> [String] {
        fixture.harness.appModel.historyPanel.model.rows.map(\.name)
    }

    // MARK: - AX helpers

    /// `layerRow.<index>` identifiers in tree order (top to bottom).
    private func rowIdentifiers(_ root: NSView) async -> [String] {
        try? await Task.sleep(for: .milliseconds(10))
        pumpMainRunLoop()
        return AX.withAccessibilityClient {
            guard let list = AX.first(inRoot: root, identifier: "layersList") else {
                Issue.record("no layersList element")
                return []
            }
            var collected: [String] = []
            AX.walk(list) { element in
                if let id = AX.identifier(of: element), id.hasPrefix("layerRow.") {
                    collected.append(id)
                }
            }
            return collected
        }
    }

    private func rowFacts(_ root: NSView, _ identifier: String) async
        -> (label: String?, value: String?, selected: Bool)?
    {
        try? await Task.sleep(for: .milliseconds(10))
        pumpMainRunLoop()
        return AX.withAccessibilityClient {
            guard let element = AX.first(inRoot: root, identifier: identifier) else {
                return nil
            }
            return (AX.label(of: element), AX.value(of: element), AX.isSelected(element))
        }
    }

    private func values(_ root: NSView) async -> [String?] {
        var collected: [String?] = []
        for index in 0..<3 {
            collected.append(await rowFacts(root, "layerRow.\(index)")?.value)
        }
        return collected
    }

    @discardableResult
    private func press(_ root: NSView, _ identifier: String) async -> Bool {
        try? await Task.sleep(for: .milliseconds(10))
        pumpMainRunLoop()
        let pressed = AX.withAccessibilityClient {
            guard let element = AX.first(inRoot: root, identifier: identifier) else {
                Issue.record("no accessibility element \(identifier)")
                return false
            }
            return AX.press(element)
        }
        // Drain the coalesced panel refresh the action may have queued, then render.
        try? await Task.sleep(for: .milliseconds(10))
        pumpMainRunLoop()
        return pressed
    }

    private func checkboxValue(_ root: NSView, _ index: Int) async -> Int? {
        try? await Task.sleep(for: .milliseconds(10))
        pumpMainRunLoop()
        return AX.withAccessibilityClient {
            guard let element = AX.first(inRoot: root,
                                         identifier: "layerVisibility.\(index)") else {
                return nil
            }
            return AX.valueNumber(of: element)
        }
    }

    // MARK: - Listing

    @Test func panelListsLayersTopFirst() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let fixture = try await setUp(fixtures)
            defer { finish(fixture) }
            try await addLayer(fixture)
            try await addLayer(fixture)

            let historyBefore = rowNames(fixture)
            let identifiers = AX.withAccessibilityClient { AX.identifiers(inRoot: fixture.root) }
            #expect(identifiers.contains("layersPanel"), "panel root identifier")
            #expect(identifiers.contains("layersList"))
            for index in 0..<3 {
                #expect(identifiers.contains("layerRow.\(index)"))
                #expect(identifiers.contains("layerVisibility.\(index)"))
                #expect(identifiers.contains("layerThumbnail.\(index)"))
            }
            #expect(identifiers.isSuperset(of: ["layers.add", "layers.delete", "layers.duplicate",
                                                "layers.mergeDown", "layers.moveUp",
                                                "layers.moveDown", "layers.properties"]))

            // Tree order = visual order = top layer first.
            #expect(await rowIdentifiers(fixture.root)
                    == ["layerRow.2", "layerRow.1", "layerRow.0"])
            let topRow = await rowFacts(fixture.root, "layerRow.2")
            #expect(topRow?.label == "Layer 3", "actual label: \(topRow?.label ?? "nil")")
            let middleRow = await rowFacts(fixture.root, "layerRow.1")
            #expect(middleRow?.label == "Layer 2", "actual label: \(middleRow?.label ?? "nil")")
            #expect(await rowFacts(fixture.root, "layerRow.0")?.label == "Background")
            // The newest layer is active: highlighted and value "active".
            #expect(topRow?.value == "active", "actual value: \(topRow?.value ?? "nil")")
            #expect(topRow?.selected == true)
            let bottomRow = await rowFacts(fixture.root, "layerRow.0")
            #expect(bottomRow?.value == "inactive",
                    "actual value: \(bottomRow?.value ?? "nil")")
            #expect(rowNames(fixture) == historyBefore, "listing adds no step")
        }
    }

    // MARK: - Row click selects (no step, no edit)

    @Test func clickRowSelectsLayer() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let fixture = try await setUp(fixtures)
            defer { finish(fixture) }
            try await addLayer(fixture)
            try await addLayer(fixture)
            let historyBefore = rowNames(fixture)

            #expect(await press(fixture.root, "layerRow.0"))
            #expect(fixture.bridge.state.image.activeLayerIndex == 0)
            let actualValues = await values(fixture.root)
            #expect(actualValues == ["active", "inactive", "inactive"],
                    "actual values: \(actualValues)")
            #expect(rowNames(fixture) == historyBefore,
                    "a row click adds no step: \(rowNames(fixture))")

            #expect(await press(fixture.root, "layerRow.1"))
            #expect(fixture.bridge.state.image.activeLayerIndex == 1)
            await press(fixture.root, "layerRow.1")   // already active
            #expect(rowNames(fixture) == historyBefore)
        }
    }

    // MARK: - Visibility checkbox

    @Test func visibilityCheckboxAddsHistoryStep() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let fixture = try await setUp(fixtures)
            defer { finish(fixture) }
            try await addLayer(fixture)
            try await addLayer(fixture)
            #expect(await checkboxValue(fixture.root, 0) == 1)

            #expect(await press(fixture.root, "layerVisibility.0"))
            #expect(await checkboxValue(fixture.root, 0) == 0)
            #expect(rowNames(fixture).last == "Hide Layer")
            #expect(await rowFacts(fixture.root, "layerRow.2")?.value == "active",
                    "the checkbox never changes the active layer")

            fixture.harness.window.undoManager?.undo()
            try await Task.sleep(for: .milliseconds(10))
            pumpMainRunLoop()
            #expect(await checkboxValue(fixture.root, 0) == 1)
            #expect(fixture.harness.window.undoManager?.redoMenuItemTitle == "Redo Hide Layer")
            fixture.harness.window.undoManager?.redo()
            try await Task.sleep(for: .milliseconds(10))
            pumpMainRunLoop()
            #expect(await checkboxValue(fixture.root, 0) == 0)

            // Re-check → "Show Layer".
            #expect(await press(fixture.root, "layerVisibility.0"))
            #expect(rowNames(fixture).last == "Show Layer")
        }
    }

    // MARK: - Drag-reorder

    /// The List's `.onMove` calls `LayersPanelModel.move(displaySource:displayDestination:)`
    /// verbatim — this drives that method on the app's real panel model.
    @Test func dragReorders() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let fixture = try await setUp(fixtures)
            defer { finish(fixture) }
            try await addLayer(fixture)
            try await addLayer(fixture)
            let historyBefore = rowNames(fixture).count

            // Drag the top row (display position 0) to the bottom: layer 2 lands at
            // index 1 — one "Move Layer Down" step, the moved layer active.
            fixture.panel.move(displaySource: IndexSet(integer: 0), displayDestination: 2)
            #expect(fixture.bridge.state.image.layers.map(\.name)
                    == ["Background", "Layer 3", "Layer 2"])
            #expect(fixture.bridge.state.image.activeLayerIndex == 1)
            let movedActiveRow = await rowFacts(fixture.root, "layerRow.1")
            #expect(movedActiveRow?.value == "active",
                    "actual value: \(movedActiveRow?.value ?? "nil")")
            #expect(rowNames(fixture).count == historyBefore + 1)
            #expect(rowNames(fixture).last == "Move Layer Down")

            fixture.harness.window.undoManager?.undo()
            try await Task.sleep(for: .milliseconds(10))
            pumpMainRunLoop()
            #expect(fixture.bridge.state.image.layers.map(\.name)
                    == ["Background", "Layer 2", "Layer 3"])
            // Undo marks the row undone; the History row itself stays (0010).
            #expect(rowNames(fixture).count == historyBefore + 1)
            #expect(rowNames(fixture).last == "Move Layer Down")

            // A no-op drop records nothing.
            fixture.panel.move(displaySource: IndexSet(integer: 1), displayDestination: 2)
            #expect(rowNames(fixture).count == historyBefore + 1)
        }
    }

    // MARK: - Footer buttons

    @Test func footerButtons() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let fixture = try await setUp(fixtures)
            defer { finish(fixture) }
            // One layer: only Add, Duplicate and Properties are enabled — exactly the
            // menu's table (0024: Duplicate works on a lone layer).
            #expect(AX.enabledState(inRoot: fixture.root, identifier: "layers.add") == true)
            #expect(AX.enabledState(inRoot: fixture.root,
                                    identifier: "layers.properties") == true)
            #expect(AX.enabledState(inRoot: fixture.root,
                                    identifier: "layers.duplicate") == true)
            for id in ["layers.delete", "layers.mergeDown",
                       "layers.moveUp", "layers.moveDown"] {
                #expect(AX.enabledState(inRoot: fixture.root, identifier: id) == false,
                        "\(id) disabled with one layer")
            }

            #expect(await press(fixture.root, "layers.add"))
            #expect(rowNames(fixture).last == "Add New Layer")
            #expect(await rowIdentifiers(fixture.root) == ["layerRow.1", "layerRow.0"])
            #expect(AX.enabledState(inRoot: fixture.root,
                                    identifier: "layers.moveUp") == false,
                    "top layer cannot move up")
            #expect(await press(fixture.root, "layers.moveDown"))
            #expect(rowNames(fixture).last == "Move Layer Down")
            #expect(await rowFacts(fixture.root, "layerRow.0")?.value == "active",
                    "the moved layer (now bottom) is active")
            #expect(await press(fixture.root, "layers.duplicate"))
            #expect(rowNames(fixture).last == "Duplicate Layer")
            #expect(fixture.panel.model.rows.count == 3)
            #expect(await press(fixture.root, "layers.mergeDown"))
            #expect(rowNames(fixture).last == "Merge Layer Down")
            #expect(fixture.panel.model.rows.count == 2)
            #expect(await press(fixture.root, "layers.delete"))
            #expect(rowNames(fixture).last == "Delete Layer")
            #expect(fixture.panel.model.rows.count == 1)
            #expect(AX.enabledState(inRoot: fixture.root,
                                    identifier: "layers.delete") == false)
        }
    }

    // MARK: - Double-click opens Layer Properties

    @Test func doubleClickOpensProperties() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let fixture = try await setUp(fixtures)
            defer { finish(fixture) }
            try await addLayer(fixture)
            let recorder = RecordingSheetPresenter()
            fixture.harness.windowController.layerPropertiesPresenter = recorder
            let historyBefore = rowNames(fixture)

            // The row's double-click handler (spec §5.12): openProperties for layer 1.
            fixture.panel.openProperties(index: 1)
            #expect(recorder.presentCount == 1)
            #expect(recorder.isPresenting)
            #expect(fixture.panel.isDocumentBusy, "the panel is busy while the sheet is up")
            #expect(fixture.bridge.state.image.activeLayerIndex == 1,
                    "the double-clicked layer becomes active")

            // The dialog carries the clicked layer's four fields; the blend list holds
            // only implemented modes.
            let dialogView = try #require(
                (recorder.presented as? NSHostingController<LayerPropertiesDialogView>)?.rootView)
            let model = dialogView.model
            #expect(model.edited.name == "Layer 2")
            #expect(model.edited.isVisible == true)
            #expect(model.edited.opacity == 255)
            #expect(model.opacityText == "255")
            #expect(model.blendModeOptions == [.normal])

            // (The dialog's own layout/AX needs a visible sheet — out of the headless
            // test harness's reach; its fields are asserted through the shared model,
            // and `LayerPropertiesDialog`'s identifiers through the view code.)

            // Busy: a second Layer Properties is a no-op, the menu item validates off,
            // and panel rows do nothing.
            fixture.harness.perform(NSSelectorFromString("showLayerProperties:"))
            #expect(recorder.presentCount == 1)
            #expect(!fixture.harness.isEnabled(NSSelectorFromString("showLayerProperties:")))
            await press(fixture.root, "layerRow.0")
            #expect(fixture.bridge.state.image.activeLayerIndex == 1, "row clicks are ignored")
            #expect(rowNames(fixture) == historyBefore, "busy actions add no step")

            // Cancel (the dialog's Cancel button calls exactly this): closes, restores,
            // records no step.
            model.cancel()
            #expect(!recorder.isPresenting)
            #expect(!fixture.panel.isDocumentBusy)
            #expect(fixture.bridge.state.image.layers[1].name == "Layer 2")
            #expect(rowNames(fixture) == historyBefore)
        }
    }

    // MARK: - Live preview, Cancel, OK

    @Test func propertiesOKAndCancel() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let fixture = try await setUp(fixtures)
            defer { finish(fixture) }
            try await addLayer(fixture)
            let recorder = RecordingSheetPresenter()
            fixture.harness.windowController.layerPropertiesPresenter = recorder
            let backgroundID = fixture.bridge.state.image.layers[0].id

            fixture.panel.openProperties(index: 0)
            var model = try #require(
                (recorder.presented as? NSHostingController<LayerPropertiesDialogView>)?.rootView)
                .model
            let historyBefore = rowNames(fixture)

            // Live preview: the panel row label shows the typed name immediately; no step.
            model.edited.name = "Paper"
            model.edited.opacity = 100
            #expect(fixture.bridge.state.image.layers[0].name == "Paper")
            #expect(fixture.bridge.state.image.layers[0].opacity == 100)
            #expect(model.opacityText == "100", "slider and field stay in step")
            #expect(await rowFacts(fixture.root, "layerRow.0")?.label == "Paper")
            #expect(rowNames(fixture) == historyBefore)

            // Cancel restores every field, records nothing.
            model.cancel()
            #expect(fixture.bridge.state.image.layers[0].name == "Background")
            #expect(fixture.bridge.state.image.layers[0].opacity == 255)
            #expect(await checkboxValue(fixture.root, 0) == 1)
            #expect(rowNames(fixture) == historyBefore)
            #expect(!recorder.isPresenting)

            // Open again for the same layer: the dialog starts from the current state.
            fixture.panel.openProperties(index: 0)
            model = try #require(
                (recorder.presented as? NSHostingController<LayerPropertiesDialogView>)?.rootView)
                .model
            #expect(model.edited.name == "Background")
            #expect(model.opacityText == "255")
            model.edited.name = "Paper"
            model.edited.opacity = 100
            #expect(model.ok() != nil, "OK commits")
            #expect(!recorder.isPresenting)
            #expect(rowNames(fixture).count == historyBefore.count + 1)
            #expect(rowNames(fixture).last == "Layer Properties")
            #expect(fixture.bridge.state.image.layerIndex(for: backgroundID) == 0)

            // Undo / redo round-trip through the window's undo manager.
            fixture.harness.window.undoManager?.undo()
            pumpMainRunLoop()
            #expect(fixture.bridge.state.image.layers[0].name == "Background")
            #expect(fixture.bridge.state.image.layers[0].opacity == 255)
            fixture.harness.window.undoManager?.redo()
            pumpMainRunLoop()
            #expect(fixture.bridge.state.image.layers[0].name == "Paper")
            #expect(fixture.bridge.state.image.layers[0].opacity == 100)

            // OK with no changes records nothing (H-6).
            fixture.panel.openProperties(index: 0)
            model = try #require(
                (recorder.presented as? NSHostingController<LayerPropertiesDialogView>)?.rootView)
                .model
            let stepsBefore = rowNames(fixture).count
            #expect(model.ok()?.isNoOp == true)
            #expect(rowNames(fixture).count == stepsBefore,
                    "a no-change OK adds no History row")
        }
    }

    // MARK: - Following the active document

    @Test func panelFollowsActiveDocument() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let fixture = try await setUp(fixtures)
            defer { finish(fixture) }
            try await addLayer(fixture)
            #expect(fixture.panel.model.rows.count == 2)

            // A second document rewired onto the same shared `AppModel` — what the real
            // app has — then its session becomes active (the `windowDidBecomeMain` path).
            let other = try #require(DocumentHarness.newImage(
                presenter: ScriptedNewImagePresenter(steps: [.ok]),
                pasteboard: makePrivatePasteboard()))
            defer {
                other.close()
                other.discardAppModelSuite()
            }
            other.windowController.appModel = fixture.harness.appModel
            fixture.harness.appModel.setActiveSession(other.windowController.toolSession)
            pumpMainRunLoop()
            #expect(fixture.panel.model.rows.count == 1, "the new document shows one row")
            #expect(fixture.panel.model.rows.first?.name == "Background")

            fixture.harness.appModel.setActiveSession(fixture.harness.windowController.toolSession)
            pumpMainRunLoop()
            #expect(fixture.panel.model.rows.count == 2, "document A's rows are back")

            other.close()
            pumpMainRunLoop()
            #expect(fixture.panel.model.rows.count == 2, "closing B leaves A bound")
        }
    }
}
