import Foundation

/// Locale-independent number formatting shared by the limit and size messages (spec 0002's
/// `ImageCodecError`, spec 0005's `NewImageValidationError`): thousands separators that must
/// not follow the machine's region settings, so an alert reads the same everywhere.
enum ValueFormatting {
    /// `65535` → `"65,535"`, always the `en_US` decimal style.
    static func decimal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
