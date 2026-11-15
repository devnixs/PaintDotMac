import Foundation

/// Layer blend modes. The raw value is the Metal function name (AGENTS.md *Code style*);
/// specs 0026, 0027, and 0059 add cases.
enum BlendMode: String, CaseIterable, Codable, Sendable {
    case normal

    var displayName: String {
        switch self {
        case .normal: "Normal"
        }
    }
}
