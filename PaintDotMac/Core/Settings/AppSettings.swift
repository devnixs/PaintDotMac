import Foundation

extension Notification.Name {
    /// Posted after any `AppSettings` property changes; `userInfo["key"]` carries the
    /// changed `AppSettings.Key` raw value. Every open window observes it (spec 0004, APP-5;
    /// 0046's Settings window posts through the same mechanism).
    static let appSettingsDidChange = Notification.Name("PaintDotMac.appSettingsDidChange")
}

/// Minimal typed app settings (spec 0004; 0046 completes this type). Defaults to
/// `AppDefaults.shared` (0001), so hosted tests write only to the throwaway suite.
///
/// `@unchecked Sendable` is justified: the only stored property is a `UserDefaults`, which
/// Apple documents as thread-safe (it is not declared `Sendable` only because it vends
/// mutable values); the same justification `AppDefaults.shared` carries.
struct AppSettings: @unchecked Sendable {
    enum Key {
        static let measurementUnit = "settings.measurementUnit"
    }

    /// The `userInfo` key carrying the changed key's raw value in
    /// `.appSettingsDidChange` notifications.
    static let changedKeyUserInfoKey = "key"

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    init(defaults: UserDefaults = AppDefaults.shared,
         notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    /// App-wide, as in Paint.NET: missing or unknown stored values read as Pixels
    /// (Paint.NET's default).
    var measurementUnit: MeasurementUnit {
        get {
            guard let raw = defaults.string(forKey: Key.measurementUnit),
                  let unit = MeasurementUnit(rawValue: raw)
            else { return .pixels }
            return unit
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Key.measurementUnit)
            notificationCenter.post(
                name: .appSettingsDidChange,
                object: self,
                userInfo: [Self.changedKeyUserInfoKey: Key.measurementUnit]
            )
        }
    }
}
