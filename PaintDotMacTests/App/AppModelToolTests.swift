import Foundation
import Testing
@testable import PaintDotMac

/// `AppModel`'s tool surface (spec 0006 *Test plan*): the dispatcher mirrors, option-change
/// forwarding, `implementedTools` order, and D-35's "the active tool is not remembered".
@MainActor
@Suite(.serialized)
struct AppModelToolTests {
    private func makeSuite() -> (UserDefaults, String) {
        let suiteName = "AppModelToolTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private func discard(_ suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    /// A model whose registry is `StubTool`s, plus the stubs and a context.
    private func stubbedModel(ids: [ToolID]) -> (AppModel, [ToolID: StubTool], FakeToolContext) {
        var stubs: [ToolID: StubTool] = [:]
        var factories: [ToolID: @MainActor () -> any Tool] = [:]
        for id in ids {
            let stub = StubTool(id: id)
            stubs[id] = stub
            factories[id] = { stub }
        }
        let (suite, _) = makeSuite()
        let model = AppModel(defaults: suite, registry: ToolRegistry(factories: factories))
        return (model, stubs, FakeToolContext())
    }

    @Test func mirrorsDispatcherState() {
        let (suite, name) = makeSuite()
        defer { discard(name) }
        let model = AppModel(defaults: suite)   // standard registry
        // D-35 / spec 0009: the Paintbrush is the start tool.
        #expect(model.activeToolID == .paintbrush)
        #expect(model.previousToolID == nil)
        model.selectTool(.zoom)
        #expect(model.activeToolID == .zoom)
        #expect(model.previousToolID == .paintbrush)
        #expect(model.dispatcher.hasPendingEdit == model.hasPendingToolEdit)
    }

    @Test func optionChangeNotifiesActiveTool() {
        let (model, stubs, context) = stubbedModel(ids: [.pan, .zoom])
        model.dispatcher.setContext(context)
        let key = ToolOptionKey(tool: .pan, name: "testOption", defaultValue: 0)
        model.toolOptions.setValue(5, for: key)
        #expect(stubs[.pan]?.calls == ["activate", "optionsDidChange"])
    }

    @Test func implementedToolsOrder() {
        let (suite, name) = makeSuite()
        defer { discard(name) }
        let model = AppModel(defaults: suite)
        // 0011 registered the Eraser and the Pencil after the Paintbrush; 0012 the Color
        // Picker; 0014 the two selection tools; 0015 the Lasso; 0016 the Magic Wand
        // (ToolID.allCases order puts the selection tools first).
        #expect(model.implementedTools.map(\.id)
                    == [.rectangleSelect, .lassoSelect, .ellipseSelect, .magicWand,
                        .zoom, .pan,
                        .paintbrush, .eraser, .pencil, .colorPicker])
        #expect(model.implementedTools.map(\.displayName)
                    == ["Rectangle Select", "Lasso Select", "Ellipse Select", "Magic Wand",
                        "Zoom", "Pan",
                        "Paintbrush", "Eraser", "Pencil", "Color Picker"])
    }

    /// D-35: selecting a tool writes nothing; a relaunch starts on the default tool.
    @Test func activeToolNotPersisted() {
        let suiteName = "AppModelToolTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let suite = UserDefaults(suiteName: suiteName)!
        let model = AppModel(defaults: suite)
        model.selectTool(.zoom)
        #expect(AppModel(defaults: suite).activeToolID == .paintbrush)
        suite.synchronize()
        #expect(suite.persistentDomain(forName: suiteName)?.isEmpty ?? true,
                "selecting a tool must not write to the suite (D-35)")
    }
}
