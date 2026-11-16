import AppKit
import SwiftUI
import Testing
@testable import PaintDotMac

/// The four floating panels in the real app wiring (spec 0006 *Test plan*, headless): the
/// Window menu toggles, the close button, persistence, the showing rule, and the
/// placeholder text. In test-host mode no panel is ever ordered on screen.
@MainActor
@Suite(.serialized)
struct PanelsIntegrationTests {
    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    private func openFixture(_ fixtures: FixtureFiles, named name: String) async throws -> DocumentHarness {
        let url = try fixtures.writePNG(named: name, width: 4000, height: 2000) { _, _ in
            ColorRGBA8(red: 40, green: 120, blue: 200)
        }
        let harness = try await DocumentHarness.open(url)
        harness.window.setContentSize(NSSize(width: 1000, height: 800))
        return harness
    }

    private func finish(_ harness: DocumentHarness) {
        harness.close()
        harness.discardAppModelSuite()
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    private func windowMenuItem(_ kind: PanelKind) throws -> NSMenuItem {
        let menu = MainMenu.make()
        let windowItem = try #require(
            menu.items.first { $0.identifier == MainMenu.windowMenuIdentifier })
        let submenu = try #require(windowItem.submenu)
        return try #require(submenu.items.first { $0.identifier == kind.menuItemIdentifier })
    }

    @Test func windowMenuTogglesAllFourPanels() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, named: "panels.png")
            defer { finish(harness) }

            let delegate = try #require(NSApp.delegate as? AppDelegate)
            let priorModel = delegate.appModel
            let priorCurrent = PanelController.current
            let controller = PanelController(model: harness.appModel)
            delegate.appModel = harness.appModel
            defer {
                delegate.appModel = priorModel
                PanelController.current = priorCurrent
            }

            for kind in PanelKind.allCases {
                let item = try windowMenuItem(kind)
                // Shown (default) → toggle hides. (`validateMenuItem` refreshes the state.)
                #expect(controller.shouldShow(kind), "\(kind.rawValue) starts shown")
                #expect(delegate.validateMenuItem(item))
                #expect(item.state == .on)
                delegate.togglePanel(item)
                controller.refresh()
                #expect(controller.shouldShow(kind) == false, "\(kind.rawValue) hid")
                #expect(delegate.validateMenuItem(item))
                #expect(item.state == .off)
                // Toggle again → shown.
                delegate.togglePanel(item)
                controller.refresh()
                #expect(controller.shouldShow(kind) == true)
                #expect(delegate.validateMenuItem(item))
                #expect(item.state == .on)
            }
            #expect(controller.panels[.tools]?.title == "Tools")
            #expect(controller.panels[.history]?.title == "History")
            #expect(controller.panels[.layers]?.title == "Layers")
            #expect(controller.panels[.colors]?.title == "Colors")
        }
    }

    @Test func panelCloseButtonHides() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, named: "panels.png")
            defer { finish(harness) }

            let controller = PanelController(model: harness.appModel)
            let toolsPanel = try #require(controller.panels[.tools])
            #expect(controller.windowShouldClose(toolsPanel) == false)
            #expect(controller.shouldShow(.tools) == false)
            harness.appModel.togglePanel(.tools)
            #expect(controller.shouldShow(.tools) == true)
        }
    }

    @Test func panelVisibilityPersistsForNewModel() {
        let suiteName = "PanelsIntegrationTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let suite = UserDefaults(suiteName: suiteName)!
        let model = AppModel(defaults: suite)
        model.setPanelVisible(.layers, false)
        let relaunched = AppModel(defaults: suite)
        #expect(relaunched.isPanelVisible(.layers) == false)
        #expect(relaunched.isPanelVisible(.tools) == true)
    }

    @Test func panelsHiddenWithoutDocuments() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, named: "panels.png")
            defer { finish(harness) }

            let controller = PanelController(model: harness.appModel)
            let delegate = try #require(NSApp.delegate as? AppDelegate)
            let priorModel = delegate.appModel
            let priorCurrent = PanelController.current
            delegate.appModel = harness.appModel
            defer {
                delegate.appModel = priorModel
                PanelController.current = priorCurrent
            }
            let item = try windowMenuItem(.tools)

            controller.refresh()
            #expect(controller.shouldShow(.tools) == true)
            #expect(delegate.validateMenuItem(item))

            harness.close()
            harness.discardAppModelSuite()
            controller.refresh()
            #expect(controller.shouldShow(.tools) == false, "no documents, no panels")
            #expect(!delegate.validateMenuItem(item), "the Tools item is disabled")

            // Open again → shown.
            let reopened = try await openFixture(fixtures, named: "panels.png")
            defer {
                reopened.close()
                reopened.discardAppModelSuite()
            }
            controller.model.setPanelVisible(.tools, true)
            controller.refresh()
            #expect(controller.shouldShow(.tools) == true)
            HeadlessAssertions.closeAllDocuments()
            HeadlessAssertions.noVisibleWindows()
        }
    }

    @Test func panelsNeverShownInTestHost() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, named: "panels.png")
            defer { finish(harness) }

            let controller = PanelController(model: harness.appModel)
            controller.refresh()
            #expect(controller.lastAppliedVisibility[.tools] == true)
            let panel = try #require(controller.panels[.tools])
            #expect(!panel.isVisible, "test-host mode never orders a panel on screen")
        }
    }

    @Test func placeholderText() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, named: "panels.png")
            defer { finish(harness) }

            let controller = PanelController(model: harness.appModel)
            // Colors has real content since 0007 and History since 0010; only Layers is a
            // placeholder now (D-36).
            for kind in [PanelKind.layers] {
                let panel = try #require(controller.panels[kind])
                let content = try #require(panel.contentView)
                pumpMainRunLoop()
                let shows = AX.withAccessibilityClient {
                    AX.containsStaticText(inRoot: content, PanelPlaceholderView.message)
                }
                #expect(shows, "\(kind.rawValue) shows the placeholder text (D-36)")
            }
        }
    }

    @Test func optionsBarInEveryWindow() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let first = try await openFixture(fixtures, named: "bar-one.png")
            let second = try await openFixture(fixtures, named: "bar-two.png")
            defer { finish(first); finish(second) }

            @MainActor func subviews(of view: NSView) -> [NSView] {
                view.subviews.flatMap { [$0] + subviews(of: $0) }
            }

            for harness in [first, second] {
                let content = try #require(harness.window.contentView)
                let all = subviews(of: content)
                let bar = try #require(
                    all.first { $0 is NSHostingView<AnyView> }, "no hosted tool options bar")
                let canvas = try #require(
                    all.first { $0.accessibilityIdentifier() == "canvas" }, "no canvas")
                let statusBar = try #require(
                    all.first { $0 is NSHostingView<StatusBarView> }, "no hosted status bar")
                #expect(bar.frame.minY > canvas.frame.minY, "the options bar sits above the canvas")
                #expect(statusBar.frame.minY < canvas.frame.minY, "the status bar sits below it")
                // The bar carries its accessibility identifier for later specs.
                let identifiers = AX.withAccessibilityClient { AX.identifiers(inRoot: bar) }
                #expect(identifiers.contains("toolOptionsBar"))
            }
        }
    }

    /// Closing the last document window re-runs the visibility rule on its own — the
    /// controller's `willClose` observation, not a caller's `refresh()` (APP-2).
    @Test func closingTheLastDocumentWindowHidesThePanelsWithoutManualRefresh() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, named: "panels-close.png")
            defer { harness.discardAppModelSuite() }

            let priorCurrent = PanelController.current
            defer { PanelController.current = priorCurrent }
            let controller = PanelController(model: harness.appModel)
            controller.refresh()
            #expect(controller.lastAppliedVisibility[.tools] == true)

            harness.close()
            harness.discardAppModelSuite()
            pumpMainRunLoop()
            #expect(controller.lastAppliedVisibility[.tools] == false,
                    "the window close path re-ran the visibility rule")
            HeadlessAssertions.closeAllDocuments()
            HeadlessAssertions.noVisibleWindows()
        }
    }
}
