import AppKit
import SwiftUI
import Testing

@testable import PaintDotMac

/// The Lasso Select tool headless end to end (spec 0015 *Test plan*): documents through
/// `DocumentHarness` (never shown), canvas input through synthesized mouse events, keys
/// through `harness.keyDown`, the options bar, the History panel, and the status bar.
/// Each test ends with `HeadlessAssertions.closeAllDocuments()` and `noVisibleWindows()`.
/// The fixture is generated at test time: a 200 × 200 opaque white PNG.
@MainActor
@Suite(.serialized)
struct LassoSelectIntegrationTests {
    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    private func finish(_ harness: DocumentHarness) {
        harness.close()
        harness.discardAppModelSuite()
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    private func openFixture(_ fixtures: FixtureFiles, name: String) async throws
        -> DocumentHarness
    {
        let url = try fixtures.makePNG(named: name, width: 200, height: 200,
                                       rgba: (255, 255, 255, 255))
        let harness = try await DocumentHarness.open(url)
        harness.window.setContentSize(NSSize(width: 1000, height: 800))
        harness.document.undoBridge.undoManager.groupsByEvent = false
        harness.appModel.setActiveSession(harness.windowController.toolSession)
        pumpMainRunLoop()
        return harness
    }

    /// Rectangle → Lasso within D-13's 1 s window.
    private func selectLasso(_ harness: DocumentHarness) {
        #expect(harness.shortcut("s"))
        #expect(harness.appModel.activeToolID == .rectangleSelect)
        #expect(harness.shortcut("s"))
        #expect(harness.appModel.activeToolID == .lassoSelect)
    }

    private func setPolygonMode(_ harness: DocumentHarness) {
        harness.appModel.toolOptions.setValue(LassoMode.polygon.rawValue,
                                              for: LassoSelectTool.lassoModeKey)
        pumpMainRunLoop()
    }

    private func click(_ harness: DocumentHarness, image x: Double, _ y: Double,
                       modifiers: NSEvent.ModifierFlags = []) {
        harness.clickCanvas(at: harness.viewPoint(forImagePoint: CGPoint(x: x, y: y)),
                            modifiers: modifiers)
        pumpMainRunLoop()
    }

    /// A key to the canvas (Return / Escape reach the active tool's `keyDown`).
    private func keyToCanvas(_ harness: DocumentHarness, _ characters: String,
                             keyCode: UInt16) {
        harness.window.makeFirstResponder(harness.canvasView)
        harness.keyDown(characters, keyCode: keyCode)
        harness.keyUp(characters, keyCode: keyCode)
        pumpMainRunLoop()
    }

    private func historyNames(_ harness: DocumentHarness) -> [String] {
        harness.appModel.historyPanel.model.rows.map(\.name)
    }

    private func hostedToolsPanel(_ model: AppModel) -> NSHostingView<AnyView> {
        let hosting = NSHostingView(rootView: AnyView(ToolsPanelView(model: model)))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        hosting.layoutSubtreeIfNeeded()
        pumpMainRunLoop()
        return hosting
    }

    private func optionValue(_ harness: DocumentHarness, identifier: String) -> String? {
        guard let content = harness.window.contentView else { return nil }
        pumpMainRunLoop()
        return AX.withAccessibilityClient {
            guard let item = AX.first(inRoot: content, identifier: identifier) else { return nil }
            return AX.value(of: item)
        }
    }

    @Test func sKeyCyclesToLasso() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "lasso-cycle.png")
            defer { finish(harness) }

            #expect(harness.shortcut("b"))
            #expect(harness.appModel.activeToolID == .paintbrush)
            #expect(harness.shortcut("s"))
            #expect(harness.appModel.activeToolID == .rectangleSelect)
            #expect(harness.shortcut("s"))
            #expect(harness.appModel.activeToolID == .lassoSelect)

            let hosting = hostedToolsPanel(harness.appModel)
            #expect(AX.isSelected(inRoot: hosting, identifier: "tool.lassoSelect"),
                    "the Tools panel highlights Lasso Select")
        }
    }

    @Test func polygonTriangleSelectsAndUndoes() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "lasso-tri.png")
            defer { finish(harness) }

            selectLasso(harness)
            setPolygonMode(harness)
            click(harness, image: 40, 40)
            click(harness, image: 160, 40)
            click(harness, image: 100, 160)
            keyToCanvas(harness, "\r", keyCode: 36)   // Return closes the polygon

            #expect(historyNames(harness).last == "Lasso Select")
            let sizeText = harness.statusBar.selectionSizeText
            let parts = sizeText.split(separator: " × ")
            #expect(parts.count == 2, "selection size text '\(sizeText)'")
            let width = Int(parts.first ?? "") ?? -1000
            let height = Int(parts.last ?? "") ?? -1000
            #expect(abs(width - 120) <= 2, "width ≈ 120, got '\(sizeText)'")
            #expect(abs(height - 120) <= 2, "height ≈ 120, got '\(sizeText)'")

            harness.window.undoManager?.undo()
            pumpMainRunLoop()
            let model = harness.appModel.historyPanel.model
            #expect(model.rows[model.currentIndex].name == "Open Image")
            #expect(harness.document.undoBridge.state.selection == nil)
            #expect(harness.statusBar.selectionSizeText.isEmpty)
        }
    }

    @Test func polygonEscapeAddsNoStep() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "lasso-esc.png")
            defer { finish(harness) }

            selectLasso(harness)
            setPolygonMode(harness)
            click(harness, image: 40, 40)
            click(harness, image: 160, 40)
            keyToCanvas(harness, "\u{1b}", keyCode: 53)   // Escape cancels

            #expect(historyNames(harness) == ["Open Image"])
            #expect(harness.document.undoBridge.state.selection == nil)
        }
    }

    @Test func straightDragAddsNoLassoStep() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "lasso-line.png")
            defer { finish(harness) }

            selectLasso(harness)
            // Freeform (the default mode): a straight-line drag is degenerate.
            let start = harness.viewPoint(forImagePoint: CGPoint(x: 40, y: 40))
            let end = harness.viewPoint(forImagePoint: CGPoint(x: 160, y: 160))
            harness.canvasPress(at: start)
            for step in 1...4 {
                let fraction = CGFloat(step) / 4
                harness.canvasDrag(to: CGPoint(x: start.x + (end.x - start.x) * fraction,
                                               y: start.y + (end.y - start.y) * fraction))
            }
            pumpMainRunLoop(for: 0.08)
            harness.canvasRelease(at: end)
            pumpMainRunLoop()

            #expect(!historyNames(harness).contains("Lasso Select"))
            #expect(harness.document.undoBridge.state.selection == nil)
        }
    }

    @Test func commandAddsToSelection() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "lasso-union.png")
            defer { finish(harness) }

            selectLasso(harness)
            setPolygonMode(harness)
            click(harness, image: 40, 40)
            click(harness, image: 160, 40)
            click(harness, image: 100, 160)
            keyToCanvas(harness, "\r", keyCode: 36)
            let firstHeight = harness.document.undoBridge.state.selection?.bounds.height
            #expect(firstHeight == 120)

            // ⌘ latches Union at the first mouseDown; the triangle lands near the bottom.
            click(harness, image: 20, 170, modifiers: [.command])
            click(harness, image: 60, 170, modifiers: [.command])
            click(harness, image: 40, 190, modifiers: [.command])
            keyToCanvas(harness, "\r", keyCode: 36)

            #expect(harness.appModel.historyPanel.model.rows.suffix(2).map(\.name)
                        == ["Lasso Select", "Lasso Select"])
            let unionBounds = try #require(harness.document.undoBridge.state.selection?.bounds)
            #expect(abs(unionBounds.height - 150) <= 2, "union height ≈ 150: \(unionBounds)")
            #expect(unionBounds.height > (firstHeight ?? 0), "the union grew the selection")
        }
    }

    @Test func lassoModePersists() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "lasso-mode.png")
            defer { finish(harness) }

            selectLasso(harness)
            #expect(optionValue(harness, identifier: "toolOptions.lassoMode") == "Freeform",
                    "default Freeform (TOOL-C)")
            setPolygonMode(harness)
            #expect(optionValue(harness, identifier: "toolOptions.lassoMode") == "Polygon")

            // A fresh AppModel on the same suite is what a relaunch reads.
            let relaunched = AppModel(defaults: harness.appModel.defaultsForTests)
            #expect(relaunched.toolOptions.value(LassoSelectTool.lassoModeKey) == "polygon")
        }
    }
}
