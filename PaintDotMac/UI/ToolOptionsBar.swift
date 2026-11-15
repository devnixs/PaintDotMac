import AppKit
import SwiftUI

/// The tool options bar (PRD APP-4; Paint.NET Toolbar.html; spec 0006), at the top of every
/// document window: the Tool chooser, the active tool's options, and the Finish button.
/// Zoom and Pan have no options (Paint.NET shows none for them).
struct ToolOptionsBar: View {
    /// Fixed height in points; the window controller reserves it above the canvas.
    static let barHeight: CGFloat = 30

    let model: AppModel
    /// Text fields of later specs call this on Return/Escape so tool keys work again
    /// right after editing a value (`DocumentWindowController` restores first responder).
    var onEndEditing: () -> Void = {}

    /// Pure helpers, asserted by `ToolOptionsBarModelTests`.
    static func showsFinish(for descriptor: ToolDescriptor) -> Bool {
        descriptor.supportsPendingEdits
    }

    static func finishEnabled(hasPendingEdit: Bool) -> Bool { hasPendingEdit }

    var body: some View {
        let descriptor = ToolRegistry.descriptor(for: model.activeToolID)
        HStack(spacing: 8) {
            Picker(selection: Binding(
                get: { model.activeToolID },
                set: { model.selectTool($0) }
            )) {
                ForEach(model.implementedTools, id: \.id) { tool in
                    Label(tool.displayName, systemImage: tool.symbolName).tag(tool.id)
                }
            } label: {
                Label(descriptor.displayName, systemImage: descriptor.symbolName)
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("toolOptions.tool")
            .accessibilityValue(descriptor.displayName)

            Divider()

            ToolOptionsContent(toolID: model.activeToolID, model: model)

            Spacer()

            if Self.showsFinish(for: descriptor) {
                Button("Finish") {
                    model.dispatcher.commitPendingEdit()
                }
                .disabled(!Self.finishEnabled(hasPendingEdit: model.hasPendingToolEdit))
                .accessibilityIdentifier("toolOptions.finish")
                .accessibilityLabel("Finish")
                .accessibilityHint("Commits the pending edit to the canvas (Enter)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.barHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolOptionsBar")
    }
}

/// One `case` per tool that has options, hand-built controls reading and writing through
/// `model.toolOptions` (identifiers `toolOptions.<option>`). 0009/0011/0012… add theirs;
/// this spec's tools (Zoom, Pan) have none.
struct ToolOptionsContent: View {
    let toolID: ToolID
    let model: AppModel

    var body: some View {
        switch toolID {
        case .zoom, .pan:
            // Paint.NET shows no Zoom/Pan options.
            EmptyView()
        default:
            // Options arrive with each tool's spec (0009 Paintbrush, 0012 Color Picker, …).
            EmptyView()
        }
    }
}
