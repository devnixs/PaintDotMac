import SwiftUI

/// The document window's status bar (spec 0004, APP-5), hosted in an `NSHostingView` under
/// the canvas. Field order mirrors Paint.NET: cursor, selection size, image size, then
/// (right-aligned) the units popup and the zoom. System colors only, so light/dark follow
/// the appearance automatically.
///
/// VoiceOver reads the `.accessibilityValue` ("Cursor Position, 12, 34"); the identifiers
/// are the integration tests' anchors (0045 audits them).
struct StatusBarView: View {
    /// Fixed status-bar height in points (APP-5); the window controller reserves it below
    /// the canvas.
    static let statusBarHeight: CGFloat = 22

    @Bindable var model: StatusBarModel

    var body: some View {
        HStack(spacing: 12) {
            field(id: "statusBar.cursor", label: "Cursor Position", text: model.cursorText,
                  symbol: "cursorarrow")
            field(id: "statusBar.selectionSize", label: "Selection Size",
                  text: model.selectionSizeText, symbol: "selection.pin.in.out")
            field(id: "statusBar.imageSize", label: "Image Size", text: model.imageSizeText,
                  symbol: "photo")
            Spacer()
            Picker("Units", selection: Binding(
                get: { model.unit },
                set: { model.selectUnit($0) }
            )) {
                ForEach(MeasurementUnit.allCases, id: \.self) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("statusBar.units")
            .accessibilityLabel("Units")
            field(id: "statusBar.zoom", label: "Zoom", text: model.zoomText, symbol: nil)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 8)
        .frame(height: Self.statusBarHeight)
    }

    @ViewBuilder
    private func field(id: String, label: String, text: String, symbol: String?) -> some View {
        HStack(spacing: 3) {
            if let symbol {
                // Decorative: the label carries the meaning, VoiceOver must not read the icon.
                Image(systemName: symbol)
            }
            Text(text)
        }
        // One merged element per field: VoiceOver reads "Cursor Position, 12, 34", and a
        // field whose text is empty (selection size, no cursor yet) still vends an element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(text)
        .accessibilityIdentifier(id)
    }
}
