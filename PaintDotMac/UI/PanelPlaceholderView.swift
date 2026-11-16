import SwiftUI

/// The "Not available yet." placeholder panel content (PRD APP-2, D-36) shown by Layers
/// until its spec lands (0025); Tools, History, and Colors have real content (0006, 0010,
/// 0007).
struct PanelPlaceholderView: View {
    static let message = "Not available yet."

    /// The root accessibility identifier, exposed for `PanelControllerTests` and the
    /// integration placeholder check.
    static func accessibilityIdentifierValue(for kind: PanelKind) -> String {
        kind.accessibilityIdentifier
    }

    let kind: PanelKind

    var body: some View {
        Text(Self.message)
            .foregroundStyle(.secondary)
            .frame(width: 200, height: 200)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.message)
            .accessibilityIdentifier(Self.accessibilityIdentifierValue(for: kind))
    }
}
