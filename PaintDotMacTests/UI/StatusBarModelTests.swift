import Foundation
import Testing
@testable import PaintDotMac

/// `@MainActor`, with a throwaway `UserDefaults` suite and a private `NotificationCenter`
/// per test — never the user's preferences (AGENTS.md *Headless testing*).
@MainActor
@Suite(.serialized)
struct StatusBarModelTests {
    private func makeModel(image: (Int, Int) = (800, 600), dpi: Double = 96,
                           zoom: Double = 0.5, defaults: UserDefaults,
                           center: NotificationCenter) -> StatusBarModel {
        StatusBarModel(imageSize: PixelSize(width: image.0, height: image.1),
                       dpi: dpi, zoom: zoom,
                       settings: AppSettings(defaults: defaults, notificationCenter: center),
                       notificationCenter: center)
    }

    private func makeSuite() throws -> (defaults: UserDefaults, name: String) {
        let name = "StatusBarModelTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    private func removeSuite(_ name: String) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    }

    /// Waits for the `.main`-queue notification observer to land (bounded).
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func initialStrings() throws {
        let suite = try makeSuite()
        defer { removeSuite(suite.name) }
        let model = makeModel(defaults: suite.defaults, center: NotificationCenter())
        #expect(model.cursorText == "")
        #expect(model.selectionSizeText == "")
        #expect(model.imageSizeText == "800 × 600")
        #expect(model.zoomText == "50%")
        #expect(model.unit == .pixels)
    }

    @Test func cursorFloorsAndNegative() throws {
        let suite = try makeSuite()
        defer { removeSuite(suite.name) }
        let model = makeModel(defaults: suite.defaults, center: NotificationCenter())
        model.setCursor(canvasPoint: CGPoint(x: 12.7, y: 3.2))
        #expect(model.cursorText == "12, 3")
        model.setCursor(canvasPoint: CGPoint(x: -0.5, y: -0.01))
        #expect(model.cursorText == "-1, -1")
        model.setCursor(canvasPoint: CGPoint(x: 800, y: 600))
        #expect(model.cursorText == "800, 600")
        model.setCursor(canvasPoint: nil)
        #expect(model.cursorText == "")
    }

    @Test func unitChangesStrings() async throws {
        let suite = try makeSuite()
        defer { removeSuite(suite.name) }
        let model = makeModel(defaults: suite.defaults, center: NotificationCenter())
        model.selectUnit(.inches)
        await waitUntil { model.unit == .inches }
        // 800/96 = 8.33; 600/96 = 6.25; 96/96 = 1.00; 192/96 = 2.00.
        #expect(model.imageSizeText == "8.33 × 6.25")
        model.setCursor(canvasPoint: CGPoint(x: 96, y: 192))
        #expect(model.cursorText == "1.00, 2.00")
        model.selectUnit(.centimeters)
        await waitUntil { model.unit == .centimeters }
        // 800/96·2.54 = 21.17; 600/96·2.54 = 15.88 (15.875, half away from zero).
        #expect(model.imageSizeText == "21.17 × 15.88")
        #expect(model.unit == .centimeters)
        #expect(suite.defaults.string(forKey: AppSettings.Key.measurementUnit) == "cm")
    }

    @Test func unitChangePropagates() async throws {
        let suite = try makeSuite()
        defer { removeSuite(suite.name) }
        let center = NotificationCenter()
        let first = makeModel(defaults: suite.defaults, center: center)
        let second = makeModel(defaults: suite.defaults, center: center)
        first.selectUnit(.inches)
        await waitUntil { second.unit == .inches }
        #expect(second.unit == .inches)
        #expect(suite.defaults.string(forKey: AppSettings.Key.measurementUnit) == "in")
    }

    @Test func selectionSizeIsEmptyUntilSet() throws {
        let suite = try makeSuite()
        defer { removeSuite(suite.name) }
        let model = makeModel(defaults: suite.defaults, center: NotificationCenter())
        #expect(model.selectionSizeText == "")
        model.selectionSize = PixelSize(width: 10, height: 20)
        #expect(model.selectionSizeText == "10 × 20")
    }

    @Test func pathologicalDPIShowsFallback() throws {
        // A `LayeredImage`-legal but pathological DPI (finite, > 0) must not trap the
        // status-bar strings. The image size (800 px → 8×10¹⁹ centesimal, beyond `Int`)
        // falls back to the raw pixel count; the cursor (12 px → 1.2×10¹⁸ centesimal,
        // still inside `Int`) keeps the digit path (review fix).
        let suite = try makeSuite()
        defer { removeSuite(suite.name) }
        let model = makeModel(dpi: 1e-15, defaults: suite.defaults, center: NotificationCenter())
        model.selectUnit(.inches)
        #expect(model.unit == .inches)
        #expect(model.imageSizeText == "800 × 600")
        // 12 px → 1.2×10¹⁸ centesimal, still inside `Int`: the digit path runs on huge
        // values without trapping (the digits themselves are floating-point fuzz).
        model.setCursor(canvasPoint: CGPoint(x: 12.7, y: 3.2))
        let parts = model.cursorText.split(separator: ", ")
        #expect(parts.count == 2, "cursor text \(model.cursorText)")
        for part in parts {
            let halves = part.split(separator: ".")
            #expect(halves.count == 2 && halves[1].count == 2
                    && halves[0].allSatisfy(\.isNumber), "cursor text \(model.cursorText)")
        }
    }

    @Test func zoomUpdates() throws {
        let suite = try makeSuite()
        defer { removeSuite(suite.name) }
        let model = makeModel(defaults: suite.defaults, center: NotificationCenter())
        model.zoom = 1.0 / 8.0
        #expect(model.zoomText == "13%")
    }
}
