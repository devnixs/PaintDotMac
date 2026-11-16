import Foundation

/// How a new selection operand combines with the existing selection (spec 0013;
/// Paint.NET SelectionTools.html modes). The mask algebra below is normative and exact —
/// all 8-bit integer operations, no rounding — so it agrees with the geometric path
/// booleans in the self-case: `A ∖ A = ∅` and `A ⊕ A = ∅` exactly, even on antialiased
/// edges (`a − min(a, a) = 0`, `max − min = 0` for any `a`).
///
/// | mode       | result                        | Paint.NET      |
/// |------------|-------------------------------|----------------|
/// | `replace`  | `b`                           | Replace        |
/// | `union`    | `max(a, b)`                   | Add (Union)    |
/// | `exclude`  | `a − min(a, b)` (= `max(0, a − b)`) | Subtract  |
/// | `intersect`| `min(a, b)`                   | Intersect      |
/// | `xor`      | `max(a, b) − min(a, b)` (= `|a − b|`) | Invert ("xor") |
///
/// These identities hold per pixel and are property-tested (0013):
/// `xor = union − intersect`, `exclude + intersect = a`,
/// `invert(a) = 255 − a = xor(full, a) = exclude(full, a)`, and De Morgan
/// (`255 − max(a, b) = min(255 − a, 255 − b)`).
enum SelectionCombineMode: String, CaseIterable, Sendable {
    case replace
    case union
    case exclude
    case intersect
    case xor

    /// Paint.NET SelectionTools.html names; 0014 shows them in its Selection Mode picker.
    var displayName: String {
        switch self {
        case .replace: "Replace"
        case .union: "Add (Union)"
        case .exclude: "Subtract"
        case .intersect: "Intersect"
        case .xor: "Invert (Xor)"
        }
    }

    /// The exact 8-bit coverage algebra. `a` = existing coverage, `b` = operand coverage.
    func combine(_ a: UInt8, _ b: UInt8) -> UInt8 {
        switch self {
        case .replace: b
        case .union: Swift.max(a, b)
        case .exclude: a &- Swift.min(a, b)
        case .intersect: Swift.min(a, b)
        case .xor: Swift.max(a, b) &- Swift.min(a, b)
        }
    }
}
