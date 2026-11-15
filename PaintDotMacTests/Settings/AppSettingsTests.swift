import Foundation
import Testing
@testable import PaintDotMac

/// Each test uses its own throwaway suite and removes it afterwards — never the user's
/// preferences, never a relaunch (AGENTS.md *Headless testing*).
@Suite(.serialized)
struct AppSettingsTests {
    private func makeSuite() throws -> (defaults: UserDefaults, name: String) {
        let name = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (defaults, name)
    }

    private func removeSuite(_ name: String) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    }

    @Test func defaultIsPixels() throws {
        let suite = try makeSuite()
        defer { removeSuite(suite.name) }
        #expect(AppSettings(defaults: suite.defaults).measurementUnit == .pixels)
    }

    @Test func roundTrip() throws {
        let suite = try makeSuite()
        defer { removeSuite(suite.name) }
        let settings = AppSettings(defaults: suite.defaults)  // setter is nonmutating
        settings.measurementUnit = .centimeters
        #expect(AppSettings(defaults: suite.defaults).measurementUnit == .centimeters)
        #expect(suite.defaults.string(forKey: AppSettings.Key.measurementUnit) == "cm")
    }

    @Test func unknownValueReadsAsPixels() throws {
        let suite = try makeSuite()
        defer { removeSuite(suite.name) }
        suite.defaults.set("furlong", forKey: AppSettings.Key.measurementUnit)
        #expect(AppSettings(defaults: suite.defaults).measurementUnit == .pixels)
    }

    @Test func setterPostsNotification() throws {
        let suite = try makeSuite()
        defer { removeSuite(suite.name) }
        let center = NotificationCenter()
        // Boxed for the `@Sendable` observer; delivery happens on one queue, so plain
        // access is enough for the test.
        final class Box: @unchecked Sendable { var notifications: [Notification] = [] }
        let received = Box()
        let token = center.addObserver(forName: .appSettingsDidChange, object: nil, queue: nil) {
            received.notifications.append($0)
        }
        defer { center.removeObserver(token) }

        AppSettings(defaults: suite.defaults, notificationCenter: center)
            .measurementUnit = .inches

        #expect(received.notifications.count == 1)
        let note = try #require(received.notifications.first)
        #expect(note.userInfo?[AppSettings.changedKeyUserInfoKey] as? String
                == "settings.measurementUnit")
    }
}
