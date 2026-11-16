import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PaintDotMac

/// The four floating panels (spec 0006 *Test plan*; APP-2, D-36): configuration, the pure
/// showing rule, close-button persistence, the test-host frame autosave mapping, and the
/// placeholder content. In test-host mode nothing is ever ordered on screen.
@MainActor
@Suite(.serialized)
struct PanelControllerTests {
    private func makeController() -> (PanelController, AppModel, String) {
        let suiteName = "PanelControllerTests.\(UUID().uuidString)"
        let model = AppModel(defaults: UserDefaults(suiteName: suiteName)!)
        return (PanelController(model: model), model, suiteName)
    }

    @Test func panelsConfigured() throws {
        let (controller, _, suiteName) = makeController()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        #expect(Set(controller.panels.keys) == Set(PanelKind.allCases))
        for kind in PanelKind.allCases {
            let panel = try #require(controller.panels[kind])
            #expect(panel.isFloatingPanel)
            #expect(panel.hidesOnDeactivate)
            #expect(panel.becomesKeyOnlyIfNeeded)
            #expect(panel.isReleasedWhenClosed == false)
            #expect(panel.title == kind.title)
            #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            #expect(panel.identifier?.rawValue == "panel.\(kind.rawValue)")
            // Test-host mode maps the autosave name (never the user's `panel.<kind>` frame).
            #expect(panel.frameAutosaveName == "test.panel.\(kind.rawValue)")
            let closable = panel.styleMask.contains(.closable)
            let titled = panel.styleMask.contains(.titled)
            #expect(closable && titled)
            if kind.isResizable {
                #expect(panel.styleMask.contains(.resizable))
            } else {
                #expect(!panel.styleMask.contains(.resizable), "Tools has a fixed size")
            }
        }
    }

    @Test func hiddenWithoutDocumentWindows() throws {
        let (controller, _, suiteName) = makeController()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        // No document is open in this test (`.serialized` suite, cleanup in every sibling).
        controller.refresh()
        for kind in PanelKind.allCases {
            #expect(controller.shouldShow(kind) == false)
            #expect(controller.lastAppliedVisibility[kind] == false)
        }
    }

    @Test func closeButtonPersistsHidden() throws {
        let (controller, model, suiteName) = makeController()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let panel = try #require(controller.panels[.tools])
        #expect(controller.windowShouldClose(panel) == false, "the close button hides, never destroys")
        #expect(model.isPanelVisible(.tools) == false)
        #expect(model.isPanelVisible(.history), "only the closed kind hides")
        model.togglePanel(.tools)
        #expect(model.isPanelVisible(.tools) == true)
    }

    @Test func frameAutosaveWritten() throws {
        let (controller, _, suiteName) = makeController()
        defer {
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame test.panel.tools")
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        let panel = try #require(controller.panels[.tools])
        #expect(panel.frameAutosaveName == "test.panel.tools")
        panel.setFrame(CGRect(x: 60, y: 70, width: 80, height: 120), display: false)
        #expect(UserDefaults.standard.string(forKey: "NSWindow Frame test.panel.tools") != nil,
                "AppKit persists under the test-mapped name")
        #expect(UserDefaults.standard.string(forKey: "NSWindow Frame panel.tools") == nil,
                "never under the user's autosave name")
    }

    @Test func placeholderContent() throws {
        let (controller, _, suiteName) = makeController()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        #expect(PanelPlaceholderView.message == "Not available yet.")
        // Colors has the real Colors panel since 0007 and History the real panel since
        // 0010, so only Layers is a placeholder.
        for kind in [PanelKind.layers] {
            let panel = try #require(controller.panels[kind])
            let hosting = try #require(panel.contentView)
            #expect(String(describing: hosting).contains("NSHostingView"))
            let ids = AX.withAccessibilityClient { AX.identifiers(inRoot: hosting) }
            #expect(ids.contains(PanelPlaceholderView.accessibilityIdentifierValue(for: kind)),
                    "\(kind.rawValue) placeholder exposes its identifier")
        }
        #expect(PanelPlaceholderView.accessibilityIdentifierValue(for: .history) == "historyPanel")
    }
}
