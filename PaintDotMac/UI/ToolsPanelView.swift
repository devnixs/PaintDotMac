import SwiftUI

/// The floating Tools panel (PRD APP-2; Paint.NET ToolsWindow.html; spec 0006): the groups
/// that have implemented tools, in Paint.NET order, separated by dividers; each a
/// two-column grid of 28×28 pt symbol buttons. Clicking makes a tool active; the active icon
/// is highlighted; the tooltip is "Name (Key)".
struct ToolsPanelView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    Divider()
                }
                grid(section)
            }
        }
        .padding(6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolsPanel")
    }

    /// Only groups with at least one implemented tool appear (this spec: View, with Zoom
    /// and Pan).
    private var sections: [[ToolDescriptor]] {
        ToolPanelGroup.allCases.compactMap { group in
            let tools = model.implementedTools.filter { $0.group == group }
            return tools.isEmpty ? nil : tools
        }
    }

    private func grid(_ tools: [ToolDescriptor]) -> some View {
        LazyVGrid(
            columns: [GridItem(.fixed(Self.buttonSize), spacing: 4),
                      GridItem(.fixed(Self.buttonSize), spacing: 4)],
            alignment: .leading, spacing: 4
        ) {
            ForEach(tools, id: \.id) { descriptor in
                toolButton(descriptor)
            }
        }
    }

    private static let buttonSize: CGFloat = 28

    private func toolButton(_ descriptor: ToolDescriptor) -> some View {
        let isActive = model.activeToolID == descriptor.id
        return Button {
            model.selectTool(descriptor.id)
        } label: {
            Image(systemName: descriptor.symbolName)
                .font(.system(size: 16))
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .background(
                    isActive ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(descriptor.helpText)
        .accessibilityLabel(descriptor.displayName)
        .accessibilityIdentifier("tool.\(descriptor.id.rawValue)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
