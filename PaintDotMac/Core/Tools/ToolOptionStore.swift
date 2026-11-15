import Foundation

/// A value storable in a `ToolOptionStore` (TOOL-C; AGENTS.md rule 6).
protocol ToolOptionValue: Sendable, Equatable {
    init?(storedValue: Any)
    var storedValue: Any { get }
}

/// A stored number whose ObjC type is `char` is a `BOOL` — CoreFoundation bridges both
/// `Bool` and `NSNumber(bool:)` to `kCFBoolean`, and a `Bool` must not read as an `Int`
/// (or vice versa): wrong type means the default value.
private func isBooleanNumber(_ number: NSNumber) -> Bool {
    String(cString: number.objCType) == "c"
}

extension Bool: ToolOptionValue {
    init?(storedValue: Any) {
        guard let number = storedValue as? NSNumber else { return nil }
        if isBooleanNumber(number) { self = number.boolValue; return }
        let value = number.doubleValue
        guard value.isFinite else { return nil }
        if value == 0 { self = false; return }
        if value == 1 { self = true; return }
        return nil
    }

    var storedValue: Any { self }
}

extension Int: ToolOptionValue {
    /// Accepts an `NSNumber`/`Int` that is exactly integral; a `Bool` or a fractional
    /// number reads as missing.
    init?(storedValue: Any) {
        guard let number = storedValue as? NSNumber, !isBooleanNumber(number),
              let exact = Self(exactly: number.doubleValue) else { return nil }
        self = exact
    }

    var storedValue: Any { self }
}

extension Double: ToolOptionValue {
    /// Any finite number; a non-finite value read from storage is treated as missing.
    init?(storedValue: Any) {
        guard let number = storedValue as? NSNumber, !isBooleanNumber(number) else { return nil }
        let value = number.doubleValue
        guard value.isFinite else { return nil }
        self = value
    }

    var storedValue: Any { self }
}

extension String: ToolOptionValue {
    init?(storedValue: Any) {
        guard let string = storedValue as? String else { return nil }
        self = string
    }

    var storedValue: Any { self }
}

/// String-raw enums opt in with `extension X: ToolOptionValue {}` and get these defaults
/// (stored as the raw string).
extension RawRepresentable where RawValue == String, Self: ToolOptionValue {
    init?(storedValue: Any) {
        guard let raw = storedValue as? String, let value = Self(rawValue: raw) else { return nil }
        self = value
    }

    var storedValue: Any { rawValue }
}

/// A typed key for one tool option: `tool.<tool>.<name>` (TOOL-C, AGENTS.md rule 6).
/// Equality and hashing use the identity `(tool, name)` only — the default and the sanitizer
/// are behavior, not identity.
struct ToolOptionKey<Value: ToolOptionValue>: Sendable, Hashable {
    let tool: ToolID
    let name: String
    let defaultValue: Value
    private let sanitizeValue: @Sendable (Value) -> Value

    /// `name` is a code constant: non-empty and dot-free, or the `tool.<id>.<option>` key
    /// layout breaks (a programming error, not user input).
    init(tool: ToolID, name: String, defaultValue: Value,
         sanitize: @escaping @Sendable (Value) -> Value = { $0 }) {
        precondition(!name.isEmpty && !name.contains("."),
                     "ToolOptionKey.name must be non-empty and contain no '.' (got \(name.debugDescription))")
        self.tool = tool
        self.name = name
        self.defaultValue = defaultValue
        self.sanitizeValue = sanitize
    }

    /// e.g. `"tool.paintbrush.width"`.
    var defaultsKey: String { "tool.\(tool.rawValue).\(name)" }

    func sanitize(_ value: Value) -> Value { sanitizeValue(value) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tool == rhs.tool && lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(tool)
        hasher.combine(name)
    }
}

extension ToolOptionKey where Value: Comparable {
    /// Reads and writes clamp into `range`.
    init(tool: ToolID, name: String, defaultValue: Value, range: ClosedRange<Value>) {
        self.init(tool: tool, name: name, defaultValue: defaultValue) { value in
            min(max(value, range.lowerBound), range.upperBound)
        }
    }
}

/// Storage behind `ToolOptionKey` (the `UserDefaults`-backed one lives in `App/`; tests and
/// previews use `InMemoryToolOptionStore`).
@MainActor
protocol ToolOptionStore: AnyObject {
    func storedValue(forKey key: String) -> Any?
    /// `nil` removes.
    func setStoredValue(_ value: Any?, forKey key: String)
}

extension ToolOptionStore {
    /// Missing or wrong-typed storage yields the default; the result is always sanitized.
    func value<V>(_ key: ToolOptionKey<V>) -> V {
        guard let raw = storedValue(forKey: key.defaultsKey),
              let parsed = V(storedValue: raw) else {
            return key.sanitize(key.defaultValue)
        }
        return key.sanitize(parsed)
    }

    /// Stores `sanitize(value)` under the key.
    func setValue<V>(_ value: V, for key: ToolOptionKey<V>) {
        setStoredValue(key.sanitize(value).storedValue, forKey: key.defaultsKey)
    }

    func removeValue<V>(for key: ToolOptionKey<V>) {
        setStoredValue(nil, forKey: key.defaultsKey)
    }
}

/// The `[String: Any]` store for tests and previews.
@MainActor
final class InMemoryToolOptionStore: ToolOptionStore {
    private var storage: [String: Any] = [:]

    func storedValue(forKey key: String) -> Any? { storage[key] }

    func setStoredValue(_ value: Any?, forKey key: String) {
        if let value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }
}
