import Foundation

/// The app's preferences, kept away from the user's real preferences while the hosted tests run
/// (the test host has the app's bundle ID; AGENTS.md *Headless testing*).
///
/// **Contract for every later spec:** app code reads and writes preferences only through
/// `AppDefaults.shared` (or an injected `UserDefaults` whose default argument is
/// `AppDefaults.shared`), never `UserDefaults.standard`, and passes every `setFrameAutosaveName`
/// / `frameAutosaveName` through `frameAutosaveName(_:)`. Unit tests still inject their own
/// `UserDefaults(suiteName:)`.
enum AppDefaults {
    /// The throwaway suite used instead of `.standard` in test-host mode.
    static let testSuiteName = "com.thera-engineering.paintdotmac.headless-tests"

    /// Prefix for frame autosave names in test-host mode.
    static let testFrameAutosavePrefix = "test."

    /// AppKit always writes window frame autosaves to `UserDefaults.standard` under this key
    /// prefix, regardless of which suite the app itself uses.
    private static let standardWindowFrameKeyPrefix = "NSWindow Frame "

    /// `.standard` normally; in test-host mode a throwaway suite whose persistent domain is
    /// removed when it is first created, so every test run starts clean.
    ///
    /// `nonisolated(unsafe)` is justified because `UserDefaults` is documented as thread-safe
    /// (it is not declared `Sendable` only because it hands out mutable values); the value
    /// itself is assigned exactly once, before any reader can observe it.
    nonisolated(unsafe) static let shared: UserDefaults = {
        guard TestHost.isActive else { return .standard }
        // `suiteName:` returns nil only for suite names that cannot form a valid domain;
        // fall back to the standard defaults rather than crash.
        guard let defaults = UserDefaults(suiteName: testSuiteName) else { return .standard }
        defaults.removePersistentDomain(forName: testSuiteName)
        return defaults
    }()

    /// Returns `name` normally and `"test." + name` in test-host mode, keeping test runs away
    /// from the user's real window and panel frames.
    static func frameAutosaveName(_ name: String) -> String {
        guard TestHost.isActive else { return name }
        _ = cleanedStandardTestFrames
        return testFrameAutosavePrefix + name
    }

    /// On first use in test-host mode, removes every `.standard` key that starts with
    /// `NSWindow Frame test.` left over from earlier runs.
    private static let cleanedStandardTestFrames: Void = {
        let prefix = standardWindowFrameKeyPrefix + testFrameAutosavePrefix
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }()
}
