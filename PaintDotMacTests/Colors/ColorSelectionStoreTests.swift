import Foundation
import Testing

@testable import PaintDotMac

/// `colors.*` persistence (C-1: colors are app-wide and persisted), on a throwaway suite per
/// test (AGENTS.md *Headless testing*). Expected values are hand-written, never read back out
/// of the implementation.
@MainActor
struct ColorSelectionStoreTests {
    private let suiteName = "ColorSelectionStoreTests.\(UUID().uuidString)"

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

    private func color(_ red: Int, _ green: Int, _ blue: Int, _ alpha: Int = 255) -> ColorRGBA8 {
        ColorRGBA8(red: UInt8(red), green: UInt8(green), blue: UInt8(blue), alpha: UInt8(alpha))
    }

    @Test func missingKeysLoadDefaults() {
        defer { cleanUp() }
        let store = ColorSelectionStore(defaults: defaults)
        #expect(store.load() == .default)
        #expect(store.load() == ColorSelection(primary: .black, secondary: .white))
    }

    @Test func saveLoadRoundTrip() {
        defer { cleanUp() }
        let store = ColorSelectionStore(defaults: defaults)
        for pair in [
            (color(51, 102, 204, 255), color(9, 8, 7, 0)),
            (color(1, 2, 3, 128), color(255, 255, 255, 1)),
            (.black, .white),
        ] {
            let selection = ColorSelection(primary: pair.0, secondary: pair.1)
            store.save(selection)
            #expect(store.load() == selection, "\(selection) must survive a save/load")
        }
    }

    @Test func storesEightDigitUppercase() {
        defer { cleanUp() }
        let store = ColorSelectionStore(defaults: defaults)
        store.save(ColorSelection(primary: color(51, 102, 204, 255), secondary: color(1, 2, 3, 7)))
        #expect(defaults.string(forKey: "colors.primary") == "#3366CCFF")
        #expect(defaults.string(forKey: "colors.secondary") == "#01020307")
    }

    @Test func corruptValuesFallBackPerSlot() {
        defer { cleanUp() }
        defaults.set("#ZZZZZZ", forKey: "colors.primary")
        defaults.set("#3366CC80", forKey: "colors.secondary")
        let loaded = ColorSelectionStore(defaults: defaults).load()
        #expect(loaded.primary == .black, "a bad primary never resets a good secondary")
        #expect(loaded.secondary == color(51, 102, 204, 128))
    }

    @Test func wrongTypeFallsBack() {
        defer { cleanUp() }
        defaults.set(42, forKey: "colors.primary")
        defaults.set(Data([1, 2, 3]), forKey: "colors.secondary")
        let loaded = ColorSelectionStore(defaults: defaults).load()
        #expect(loaded.primary == .black)
        #expect(loaded.secondary == .white)
    }

    @Test func sixDigitStoredValueReadsOpaque() {
        defer { cleanUp() }
        defaults.set("#3366CC", forKey: "colors.primary")
        #expect(ColorSelectionStore(defaults: defaults).load().primary == color(51, 102, 204, 255))
    }

    @Test func panelExpandedRoundTrip() {
        defer { cleanUp() }
        let store = ColorSelectionStore(defaults: defaults)
        #expect(store.loadPanelExpanded() == false, "Paint.NET opens collapsed")
        store.savePanelExpanded(true)
        #expect(ColorSelectionStore(defaults: defaults).loadPanelExpanded() == true)
        store.savePanelExpanded(false)
        #expect(ColorSelectionStore(defaults: defaults).loadPanelExpanded() == false)
        defaults.set("yes", forKey: "colors.panelExpanded")
        #expect(ColorSelectionStore(defaults: defaults).loadPanelExpanded() == false,
                "a non-Bool value falls back to the default")
    }

    @Test func keyNamesAreTheDocumentedOnes() {
        #expect(ColorSelectionStore.primaryKey == "colors.primary")
        #expect(ColorSelectionStore.secondaryKey == "colors.secondary")
        #expect(ColorSelectionStore.panelExpandedKey == "colors.panelExpanded")
    }
}
