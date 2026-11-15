import Foundation
import Testing

/// Floating-point equality with a tolerance. This toolchain's Swift Testing has no
/// `#expect(_ == _ accuracy:)` form, so the color tests call this instead: a failure records
/// both values, which is what makes a broken conversion diagnosable. NaN never passes.
func expectClose(_ actual: Double, _ expected: Double, tolerance: Double = 1e-9,
                 message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    let difference = abs(actual - expected)
    guard !(difference <= tolerance) else { return }
    let prefix = message.isEmpty ? "" : "\(message): "
    Issue.record("\(prefix)expected \(expected) ±\(tolerance), got \(actual)",
                 sourceLocation: sourceLocation)
}
