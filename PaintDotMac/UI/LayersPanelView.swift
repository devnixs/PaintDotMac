import SwiftUI

/// The Layers panel content (spec 0025 item 8, PRD L-5, APP-2): one row per layer, top
/// layer first — thumbnail, name, visibility checkbox — with the active row highlighted,
/// drag-to-reorder, and Paint.NET's seven footer buttons. Hosted by `PanelController` in
/// the app-wide Layers panel (⌥⌘3), replacing 0006's placeholder (D-36).
///
/// The view renders `LayerListModel` / `LayersPanelModel` and forwards clicks; every
/// decision lives in the models. Selection follows `model.activeIndex`, not a SwiftUI
/// selection binding (0010's approach), and the checkbox never writes state itself — its
/// action calls `toggleVisibility` and the model refresh sets the value back. Rows drag
/// via `.draggable`/`.dropDestination` (the `ScrollView`/`LazyVStack` container of 0010 —
/// `List`'s collection view never realizes its rows in a never-shown panel, so its rows
/// would vend no accessibility tree for the headless tests).
struct LayersPanelView: View {
    static let panelWidth: CGFloat = 260
    static let panelHeight: CGFloat = 340
    /// Paint.NET's thumbnail box (40 pt; the renderer fills it at 2×).
    static let thumbnailSide: CGFloat = 40

    let model: LayersPanelModel

    /// The rows/enablement list the view renders (keeps the body free of `model.model`).
    private var list: LayerListModel { model.model }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(list.rows) { row in
                            LayerRowView(row: row, thumbnail: model.thumbnails[row.id],
                                         busy: model.isDocumentBusy,
                                         onSelect: { model.selectLayer(index: row.index) },
                                         onOpenProperties: { model.openProperties(index: row.index) },
                                         onToggleVisibility: { model.toggleVisibility(index: row.index) })
                                .id(row.id)
                                // Drag-to-reorder (L-5): the row carries its layer id;
                                // dropping on a row routes the same
                                // `move(displaySource:displayDestination:)` call
                                // SwiftUI's `List.onMove` would make.
                                .draggable(row.id.uuidString)
                                .dropDestination(for: String.self) { items, _ in
                                    guard let payload = items.first,
                                          let source = list.rows.firstIndex(
                                            where: { $0.id.uuidString == payload }),
                                          let targetRow = list.rows.firstIndex(
                                            where: { $0.id == row.id })
                                    else { return false }
                                    // `List.onMove` semantics: dropping on a row inserts
                                    // before it when dragging up, after it down.
                                    model.move(
                                        displaySource: IndexSet(integer: source),
                                        displayDestination: source < targetRow ? targetRow + 1
                                                                                : targetRow)
                                    return true
                                }
                        }
                    }
                }
                .disabled(model.isDocumentBusy)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Layers")
                .accessibilityIdentifier("layersList")
                Divider()
                HStack(spacing: 8) {
                    footerButton(title: "Add New Layer", symbolName: "plus.square.on.square",
                                 identifier: "layers.add",
                                 enabled: isEnabled(.addNewLayer)) { model.perform(.addNewLayer) }
                    footerButton(title: "Delete Layer", symbolName: "minus.square",
                                 identifier: "layers.delete",
                                 enabled: isEnabled(.deleteLayer)) { model.perform(.deleteLayer) }
                    footerButton(title: "Duplicate Layer", symbolName: "square.on.square",
                                 identifier: "layers.duplicate",
                                 enabled: isEnabled(.duplicateLayer)) { model.perform(.duplicateLayer) }
                    footerButton(title: "Merge Layer Down", symbolName: "square.stack.3d.down.right",
                                 identifier: "layers.mergeDown",
                                 enabled: isEnabled(.mergeLayerDown)) { model.perform(.mergeLayerDown) }
                    footerButton(title: "Move Layer Up", symbolName: "arrow.up",
                                 identifier: "layers.moveUp",
                                 enabled: isEnabled(.moveLayerUp)) { model.perform(.moveLayerUp) }
                    footerButton(title: "Move Layer Down", symbolName: "arrow.down",
                                 identifier: "layers.moveDown",
                                 enabled: isEnabled(.moveLayerDown)) { model.perform(.moveLayerDown) }
                    footerButton(title: "Layer Properties", symbolName: "slider.horizontal.3",
                                 identifier: "layers.properties",
                                 enabled: isEnabled(.layerProperties)) { model.perform(.layerProperties) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(width: Self.panelWidth, height: Self.panelHeight)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("layersPanel")
            .onChange(of: list.activeIndex) { _, activeIndex in
                // Keep the active row in view when the active layer changes (menu Go to
                // Layer, undo, or a click beyond the visible rows).
                guard let activeIndex,
                      let row = list.rows.first(where: { $0.index == activeIndex })
                else { return }
                proxy.scrollTo(row.id, anchor: .center)
            }
        }
    }

    private func isEnabled(_ command: LayerPanelCommand) -> Bool {
        list.isEnabled(command) && !model.isDocumentBusy
    }

    /// A footer icon button, same shape as 0010's: tooltip and accessibility label are
    /// the Paint.NET names.
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

/// One row (spec 0025 item 8): 40 pt thumbnail over the baked-in checkerboard, the name
/// (one line, truncated in the middle), and the trailing visibility checkbox. Single
/// click selects (the accessibility default action takes the same path, NF-7), double
/// click opens Layer Properties; the checkbox click never selects the row.
private struct LayerRowView: View {
    let row: LayerRow
    let thumbnail: CGImage?
    let busy: Bool
    let onSelect: @MainActor () -> Void
    let onOpenProperties: @MainActor () -> Void
    let onToggleVisibility: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 6) {
            thumbnailView
                .accessibilityElement()
                .accessibilityIdentifier("layerThumbnail.\(row.index)")
                .accessibilityLabel("Thumbnail")
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Toggle(isOn: Binding(get: { row.isVisible }, set: { _ in onToggleVisibility() })) {
                Text("Visible: \(row.name)")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(busy)
            .accessibilityLabel("Visible: \(row.name)")
            .accessibilityIdentifier("layerVisibility.\(row.index)")
        }
        .contentShape(Rectangle())
        // Double first, then single — SwiftUI matches the higher count first, so a
        // double click opens properties and does not also fire a plain selection.
        .onTapGesture(count: 2) { onOpenProperties() }
        .onTapGesture(count: 1) { onSelect() }
        .padding(.vertical, 2)
        .background(row.isActive ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                                 : AnyShapeStyle(Color.clear))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("layerRow.\(row.index)")
        .accessibilityLabel(row.name)
        .accessibilityValue(row.accessibilityValue)
        // A plain group does not vend its accessibility value; the button trait makes
        // VoiceOver (and the AX tests) read "active"/"inactive" off the row itself.
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(row.isActive ? .isSelected : AccessibilityTraits())
        .accessibilityAction { onSelect() }
    }

    /// The 40×40 box: the CGImage drawn aspect-fit and centered inside a 1 px
    /// `separatorColor` border; a neutral placeholder rectangle until the first render
    /// arrives (spec item 8, manual 2).
    @ViewBuilder private var thumbnailView: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color(nsColor: .quaternaryLabelColor)
            }
        }
        .frame(width: LayersPanelView.thumbnailSide, height: LayersPanelView.thumbnailSide)
        .overlay {
            Rectangle().strokeBorder(Color(nsColor: .separatorColor))
        }
    }
}
