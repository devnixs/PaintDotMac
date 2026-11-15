import Foundation
import Testing

@testable import PaintDotMac

/// The app-model color state and its persistence (C-1): every mutation writes through the
/// injected store, the active slot never does, and a relaunch reads the same colors.
@MainActor
struct AppModelColorsTests {
    private let suiteName = "AppModelColorsTests.\(UUID().uuidString)"

    private var defaults: UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not open the throwaway suite")
            return UserDefaults.standard
        }
        return defaults
    }

    private func cleanUp() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> AppModel {
        AppModel(defaults: defaults, colorStore: ColorSelectionStore(defaults: defaults))
    }

    private func color(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int = 255) -> ColorRGBA8 {
        ColorRGBA8(red: UInt8(red), green: UInt8(green), blue: UInt8(blue), alpha: UInt8(alpha))
    }

    @Test func startsFromDefaultsOnACleanSuite() {
        defer { cleanUp() }
        let model = makeModel()
        #expect(model.colors == .default)
        #expect(model.colors.primary == .black)
        #expect(model.colors.secondary == .white)
        #expect(model.activeColorSlot == .primary)
        #expect(model.colorsPanelExpanded == false)
    }

    @Test func loadsPersistedColorsOnInit() {
        defer { cleanUp() }
        let store = ColorSelectionStore(defaults: defaults)
        store.save(ColorSelection(primary: color(51, 102, 204, 128), secondary: color(255, 0, 0)))
        store.savePanelExpanded(true)
        let model = makeModel()
        #expect(model.colors.primary == color(51, 102, 204, 128))
        #expect(model.colors.secondary == color(255, 0, 0))
        #expect(model.colorsPanelExpanded == true)
    }

    @Test func everyMutationPersists() {
        defer { cleanUp() }
        let model = makeModel()
        let reload: () -> ColorSelection = {
            ColorSelectionStore(defaults: self.defaults).load()
        }

        model.swapColors()
        #expect(reload() == model.colors, "swapColors persists")

        model.setColor(color(10, 20, 30, 40), for: .secondary)
        #expect(reload() == model.colors, "setColor persists")

        model.setColorChannel(.red, to: 200)
        #expect(reload() == model.colors, "setColorChannel persists")
        #expect(model.colors.primary.red == 200)

        #expect(model.applyHex("#123456"))
        #expect(reload() == model.colors, "applyHex persists")
        #expect(ColorSelectionStore(defaults: defaults).load().primary == color(18, 52, 86))

        model.applyWheel(hue: 200, saturation: 60, to: .primary)
        #expect(reload() == model.colors, "applyWheel persists")

        model.resetColors()
        #expect(reload() == .default, "resetColors persists")

        model.setColorsPanelExpanded(true)
        #expect(ColorSelectionStore(defaults: defaults).loadPanelExpanded() == true)
    }

    @Test func invalidHexDoesNotWrite() {
        defer { cleanUp() }
        let model = makeModel()
        model.setColor(color(51, 102, 204), for: .primary)
        let before = defaults.string(forKey: "colors.primary")
        #expect(before == "#3366CCFF")
        #expect(!model.applyHex("bad"))
        #expect(defaults.string(forKey: "colors.primary") == before)
        #expect(model.colors.primary == color(51, 102, 204))
    }

    @Test func activeSlotNotPersisted() {
        defer { cleanUp() }
        let model = makeModel()
        model.setActiveColorSlot(.secondary)
        #expect(model.activeColorSlot == .secondary)
        #expect(makeModel().activeColorSlot == .primary, "every launch starts with Primary active")
        #expect(model.colors == .default)
    }

    @Test func switchActiveColorSlotTogglesAndIsNotPersisted() {
        defer { cleanUp() }
        let model = makeModel()
        model.setColor(color(51, 102, 204), for: .primary)
        let storedColorsBefore = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("colors.")
        }
        let primaryBefore = defaults.string(forKey: "colors.primary")

        model.switchActiveColorSlot()
        #expect(model.activeColorSlot == .secondary)
        #expect(model.colors == ColorSelection(primary: color(51, 102, 204), secondary: .white))
        #expect(defaults.string(forKey: "colors.primary") == primaryBefore)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("colors.") }
                == storedColorsBefore, "C writes no colors.* key")
        #expect(makeModel().activeColorSlot == .primary)

        model.switchActiveColorSlot()
        #expect(model.activeColorSlot == .primary)
    }

    @Test func colorEditsFollowTheActiveSlot() {
        defer { cleanUp() }
        let model = makeModel()
        model.setColor(color(51, 102, 204), for: .primary)
        model.switchActiveColorSlot()
        model.setColorChannel(.red, to: 0)
        #expect(model.colors.secondary == color(0, 255, 255))
        #expect(model.colors.primary == color(51, 102, 204))
        #expect(model.colorEditor.value(of: .red) == 0, "the panel reads the active slot")
        #expect(model.colorEditor.value(of: .red, slot: .primary) == 51)
    }

    @Test func editorStateIsExposedForThePanel() {
        defer { cleanUp() }
        let model = makeModel()
        model.setColor(color(51, 102, 204), for: .primary)
        #expect(model.colorEditor.value(of: .hue) == 220)
        #expect(model.colorEditor.hsv[.secondary] == HSVColor(hue: 0, saturation: 0, value: 100))
    }
}
