import Foundation
import Testing
@testable import PaintDotMac

/// `UserDefaultsToolOptionStore` (spec 0006 *Test plan*, TOOL-C): persistence across
/// instances (relaunch), the revision bump, and the change callback. Every test runs on its
/// own throwaway suite.
@MainActor
@Suite(.serialized)
struct UserDefaultsToolOptionStoreTests {
    private func makeSuite() -> (UserDefaults, String) {
        let suiteName = "UserDefaultsToolOptionStoreTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    @Test func persistsAcrossInstances() {
        let (suite, name) = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let key = ToolOptionKey(tool: .zoom, name: "testOption", defaultValue: 0)
        let storeA = UserDefaultsToolOptionStore(defaults: suite)
        storeA.setValue(7, for: key)
        let storeB = UserDefaultsToolOptionStore(defaults: suite)
        #expect(storeB.value(key) == 7, "TOOL-C: the next launch reads the value")
        #expect(suite.object(forKey: "tool.zoom.testOption") as? Int == 7)
    }

    @Test func onChangeAndRevision() {
        let (suite, name) = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let key = ToolOptionKey(tool: .zoom, name: "testOption", defaultValue: 0)
        var changedKeys: [String] = []
        let store = UserDefaultsToolOptionStore(defaults: suite)
        store.onChange = { changedKeys.append($0) }
        let revisionBefore = store.revision
        store.setValue(1, for: key)
        #expect(store.revision == revisionBefore + 1)
        #expect(changedKeys == ["tool.zoom.testOption"])
        store.removeValue(for: key)
        #expect(store.revision == revisionBefore + 2)
        #expect(changedKeys.count == 2)
        #expect(store.value(key) == 0, "removal restores the default")
    }
}
