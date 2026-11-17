import Foundation
import Testing

@testable import PaintDotMac

/// `LayerPropertiesDialogModel` (spec 0025 item 9): live-preview applies, the Cancel/OK
/// contract, and the opacity field's parse table. The `apply` spy is a plain box class
/// the closure appends to (the assertions read only the recorded values).
@MainActor
struct LayerPropertiesDialogModelTests {
    fileprivate final class SpyBox: @unchecked Sendable {
        var calls: [LayerProperties] = []
    }

    private let original = LayerProperties(name: "L", isVisible: true, opacity: 255,
                                           blendMode: .normal)

    private func makeModel() -> (LayerPropertiesDialogModel, SpyBox) {
        let spy = SpyBox()
        let model = LayerPropertiesDialogModel(layerID: Layer.ID(), original: original) {
            spy.calls.append($0)
        }
        return (model, spy)
    }

    @Test func livePreviewCallsApply() {
        let (model, spy) = makeModel()
        model.edited.name = "X"
        model.edited.isVisible = false
        model.edited.opacity = 128
        model.edited.blendMode = .normal
        // Every change calls apply with the *full* edited properties, in order.
        #expect(spy.calls.count == 4)
        #expect(spy.calls[0] == LayerProperties(name: "X", isVisible: true, opacity: 255,
                                                blendMode: .normal))
        #expect(spy.calls[1] == LayerProperties(name: "X", isVisible: false, opacity: 255,
                                                blendMode: .normal))
        #expect(spy.calls[2] == LayerProperties(name: "X", isVisible: false, opacity: 128,
                                                blendMode: .normal))
        // Setting the *same* blend mode re-applies the same value (a popup choice is a
        // user action; the no-op is filtered later, at `ok()` — H-6).
        #expect(spy.calls[3] == spy.calls[2])
        // The slider and the field always show the same value.
        #expect(model.opacityText == "128")
    }

    @Test func opacitySliderKeepsFieldInStep() {
        let (model, _) = makeModel()
        model.edited.opacity = 0
        #expect(model.opacityText == "0")
        model.edited.opacity = 255
        #expect(model.opacityText == "255")
    }

    @Test func fieldCommitParsesAndResyncs() {
        let (model, spy) = makeModel()
        model.opacityText = "300"
        model.commitOpacityText()
        #expect(model.edited.opacity == 255)
        #expect(model.opacityText == "255", "the field shows the clamped value")
        model.opacityText = "abc"
        model.commitOpacityText()
        #expect(model.edited.opacity == 255, "garbage keeps the last valid value")
        #expect(spy.calls.isEmpty, "a rejected or clamped-to-same field applies nothing")
        model.opacityText = "100"
        model.commitOpacityText()
        #expect(model.edited.opacity == 100)
        #expect(spy.calls.count == 1, "a real field change previews once")
        #expect(spy.calls.first?.opacity == 100)
    }

    @Test func cancelRestoresOriginal() {
        let (model, spy) = makeModel()
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.edited.name = "Paper"
        model.edited.opacity = 100
        model.edited.isVisible = false
        model.cancel()
        // The last apply argument == original (all four fields); Cancel records nothing.
        #expect(spy.calls.last == original)
        #expect(spy.calls.count == 4, "three previews + one restore")
        #expect(dismissed, "Cancel closes the sheet")
    }

    @Test func okBuildsSingleStep() throws {
        let (model, spy) = makeModel()
        var dismissed = false
        var committed: LayerPropertiesHistoryItem?
        model.onDismiss = { dismissed = true }
        model.onCommit = { committed = $0 }
        model.edited.opacity = 128
        model.edited.name = "Glass"
        let built = try #require(model.ok())
        #expect(built.name == "Layer Properties")
        #expect(built.icon == .layerProperties)
        #expect(built.before == original)
        #expect(built.after == LayerProperties(name: "Glass", isVisible: true, opacity: 128,
                                                blendMode: .normal))
        #expect(dismissed, "OK closes the sheet")
        #expect(committed?.after == built.after, "the presenter commits the same item")
        _ = spy

        // No edits → the item is a no-op (the stack records nothing — H-6).
        let (quiet, _) = makeModel()
        #expect(quiet.ok()?.isNoOp == true)
    }

    @Test func blendModeListIsImplementedModes() {
        let (model, _) = makeModel()
        #expect(model.blendModeOptions.map(\.displayName) == BlendMode.allCases.map(\.displayName))
        // Only implemented modes today (D-15); the list grows with 0026/0027.
        #expect(model.blendModeOptions.map(\.displayName) == ["Normal"])
    }

    /// The spec's Edge-cases table, fallback 77.
    @Test(arguments: [
        ("", UInt8(77)), ("abc", UInt8(77)), ("-5", UInt8(0)), ("300", UInt8(255)),
        ("127.5", UInt8(128)), (" 42 ", UInt8(42)), ("0", UInt8(0)), ("255", UInt8(255)),
        ("255.4", UInt8(255)), ("256", UInt8(255)), ("127.49", UInt8(127)),
    ])
    func parseOpacity(text: String, expected: UInt8) {
        #expect(LayerPropertiesDialogModel.parseOpacity(text, fallback: 77) == expected)
    }
}
