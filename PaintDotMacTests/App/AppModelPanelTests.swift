import Foundation
import Testing
@testable import PaintDotMac

/// Panel visibility persistence in `AppModel` (spec 0006 *Test plan*; APP-2, D-12). Every
/// test uses its own `UserDefaults` suite — never the user's preferences (AGENTS.md).
@MainActor
@Suite(.serialized)
struct AppModelPanelTests {
    private func makeSuite(_ name: String = #function) -> (UserDefaults, String) {
        let suiteName = "AppModelPanelTests.\(name).\(UUID().uuidString)"
        #expect(UserDefaults(suiteName: suiteName) != nil)
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private func discard(_ suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    @Test func defaultVisibleTrue() {
        let (suite, name) = makeSuite()
        defer { discard(name) }
        let model = AppModel(defaults: suite)
        for kind in PanelKind.allCases {
            #expect(model.isPanelVisible(kind), "\(kind.rawValue) defaults to visible")
        }
    }

    @Test func togglePersists() {
        let (suite, name) = makeSuite()
        defer { discard(name) }
        let model = AppModel(defaults: suite)
        model.togglePanel(.tools)
        #expect(suite.bool(forKey: "panel.tools.visible") == false)
        #expect(AppModel(defaults: suite).isPanelVisible(.tools) == false,
                "a fresh model reads the hidden state (relaunch)")
        AppModel(defaults: suite).togglePanel(.tools)
        #expect(AppModel(defaults: suite).isPanelVisible(.tools) == true)
        #expect(model.isPanelVisible(.history), "other panels are untouched")
    }

    @Test func setPanelVisiblePersistsForEveryKind() {
        let (suite, name) = makeSuite()
        defer { discard(name) }
        let model = AppModel(defaults: suite)
        for kind in PanelKind.allCases {
            model.setPanelVisible(kind, false)
            #expect(AppModel(defaults: suite).isPanelVisible(kind) == false)
        }
    }

    @Test func nonBoolStoredReadsVisible() {
        let (suite, name) = makeSuite()
        defer { discard(name) }
        suite.set("x", forKey: "panel.tools.visible")
        #expect(AppModel(defaults: suite).isPanelVisible(.tools) == true,
                "a garbage stored value falls back to the visible default")
    }
}
