import SwiftUI

/// The History panel content (spec 0010; PRD H-1/H-2, APP-2): one row per history step —
/// icon and name — with the current step highlighted, undone steps greyed, and Undo/Redo
/// buttons at the foot. Hosted by `PanelController` in the app-wide History panel
/// (⌥⌘2), replacing 0006's placeholder (D-36). Current Paint.NET has no Rewind / Fast
/// Forward buttons, so neither does this panel.
///
/// The view renders `HistoryListModel` and forwards clicks; every decision lives in the
/// Core model. Selection follows the model's `currentIndex`, not SwiftUI list selection,
/// so a no-op click leaves the highlight unchanged.
struct HistoryPanelView: View {
    static let panelWidth: CGFloat = 220
    static let panelHeight: CGFloat = 260

    let panel: HistoryPanelModel

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(panel.model.rows) { row in
                            HistoryRowView(row: row) { panel.clickRow($0) }
                                .id(row.id)   // 0008's step ID: stable across H-5 drops
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("History")
                .accessibilityIdentifier("historyList")
                Divider()
                HStack(spacing: 8) {
                    footerButton(title: "Undo", symbolName: "arrow.uturn.backward",
                                 identifier: "history.undo", enabled: panel.model.canUndo) {
                        panel.undo()
                    }
                    footerButton(title: "Redo", symbolName: "arrow.uturn.forward",
                                 identifier: "history.redo", enabled: panel.model.canRedo) {
                        panel.redo()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(width: Self.panelWidth, height: Self.panelHeight)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("historyPanel")
            .onChange(of: panel.model.currentIndex) { _, index in
                // Keep the row the canvas shows in view (0064's ⌘Z march included).
                guard panel.model.rows.indices.contains(index) else { return }
                proxy.scrollTo(panel.model.rows[index].id, anchor: .center)
            }
        }
    }

    private func footerButton(title: String, symbolName: String, identifier: String,
                              enabled: Bool, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbolName)
        }
        .help(title)
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

/// One row: 16 pt tool icon, step name, state styling, and the click. The whole row is
/// the hit target; the button's default action is what VoiceOver's press performs, so
/// accessibility and mouse clicks take the same `clickRow` path (NF-7).
private struct HistoryRowView: View {
    let row: HistoryRow
    let onClick: @MainActor (Int) -> Void

    var body: some View {
        Button {
            onClick(row.index)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: row.icon.symbolName)
                    .font(.system(size: 16))
                    .frame(width: 20)
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .background(background)
        .foregroundStyle(foreground)
        .accessibilityIdentifier("historyRow.\(row.index)")
        .accessibilityLabel(row.name)
        .accessibilityValue(row.accessibilityValue)
        .accessibilityAddTraits(row.isCurrent ? .isSelected : AccessibilityTraits())
    }

    /// `.current`: Paint.NET's selection highlight (accent background). `.undone`: a grey
    /// band with secondary content, legible in light and dark mode (APP-7).
    private var background: AnyShapeStyle {
        switch row.state {
        case .done: AnyShapeStyle(Color.clear)
        case .current: AnyShapeStyle(Color.accentColor)
        case .undone: AnyShapeStyle(Color.secondary.opacity(0.15))
        }
    }

    private var foreground: AnyShapeStyle {
        switch row.state {
        case .done: AnyShapeStyle(.primary)
        case .current: AnyShapeStyle(Color.white)
        case .undone: AnyShapeStyle(.secondary)
        }
    }
}
