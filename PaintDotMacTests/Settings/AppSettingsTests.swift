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

    // MARK: - Undo budget (spec 0008, NF-4)

    @Test func undoBudgetDefault() throws {
        let suite = try makeSuite()
        defer { removeSuite(suite.name) }
        #expect(AppSettings(defaults: suite.defaults).undoBudgetBytes == 1_073_741_824)
        #expect(AppSettings(defaults: suite.defaults).undoBudgetBytes
                == HistoryStack.defaultBudgetBytes)
    }

    @Test func undoBudgetReadsStoredValue() throws {
        let suite = try makeSuite()
        defer { removeSuite(suite.name) }
        suite.defaults.set(5_000_000, forKey: "settings.undoBudgetBytes")
        #expect(AppSettings(defaults: suite.defaults).undoBudgetBytes == 5_000_000)
    }

    @Test func undoBudgetNegativeFallsBack() throws {
        let suite = try makeSuite()
        defer { removeSuite(suite.name) }
        suite.defaults.set(-1, forKey: AppSettings.Key.undoBudgetBytes)
        #expect(AppSettings(defaults: suite.defaults).undoBudgetBytes
                == HistoryStack.defaultBudgetBytes)
    }

    @Test func undoBudgetWrongTypeFallsBack() throws {
        let suite = try makeSuite()
        defer { removeSuite(suite.name) }
        suite.defaults.set("abc", forKey: AppSettings.Key.undoBudgetBytes)
        #expect(AppSettings(defaults: suite.defaults).undoBudgetBytes
                == HistoryStack.defaultBudgetBytes)
    }

    @Test func undoBudgetKeyHasSettingsPrefix() {
        #expect(AppSettings.Key.undoBudgetBytes == "settings.undoBudgetBytes")
    }

    @Test func undoBudgetSetterWritesAndNotifies() throws {
        let suite = try makeSuite()
        defer { removeSuite(suite.name) }
        let center = NotificationCenter()
        final class Box: @unchecked Sendable { var notifications: [Notification] = [] }
        let received = Box()
        let token = center.addObserver(forName: .appSettingsDidChange, object: nil, queue: nil) {
            received.notifications.append($0)
        }
        defer { center.removeObserver(token) }

        AppSettings(defaults: suite.defaults, notificationCenter: center)
            .undoBudgetBytes = 2_000
        #expect(suite.defaults.object(forKey: AppSettings.Key.undoBudgetBytes) as? Int == 2_000)
        #expect(received.notifications.count == 1)
    }
}
