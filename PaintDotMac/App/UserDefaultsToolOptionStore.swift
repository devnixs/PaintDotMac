import Foundation
import Observation

/// The tool options store over `UserDefaults` (TOOL-C; AGENTS.md rule 6).
///
/// `storedValue(forKey:)` reads the observable `revision` first, so SwiftUI views that read
/// options (the tool options bar) re-render on any change — tools write through
/// `context.options`, so `[`/`]` (0009) update the bar immediately.
@MainActor
@Observable
final class UserDefaultsToolOptionStore: ToolOptionStore {
    private let defaults: UserDefaults

    /// Bumped by every write; the read hook below makes SwiftUI observe it.
    private(set) var revision: Int = 0

    /// Called after a write with the changed defaults key; `AppModel` forwards to
    /// `dispatcher.optionsDidChange()`.
    var onChange: @MainActor (String) -> Void

    init(defaults: UserDefaults, onChange: @escaping @MainActor (String) -> Void = { _ in }) {
        self.defaults = defaults
        self.onChange = onChange
    }

    func storedValue(forKey key: String) -> Any? {
        _ = revision
        return defaults.object(forKey: key)
    }

    func setStoredValue(_ value: Any?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        revision += 1
        onChange(key)
    }
}
