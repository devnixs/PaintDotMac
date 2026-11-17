import Foundation

/// A layer property or visibility change (spec 0025 item 2, PRD L-2, H-6). The step sets
/// exactly one layer's four `LayerProperties` fields; pixels, other layers, the selection,
/// and `activeLayerIndex` are untouched — the layer stack does not change, so by H-6
/// undoing the step must not switch the active layer (hide layer 0, click layer 2, ⌘Z:
/// layer 0 shows again, layer 2 stays active). `DocumentSnapshotHistoryItem` would
/// restore the whole state and switch back, which is why this dedicated item exists.
///
/// `change` is `.structure`: visibility, opacity, and blend mode change the composite
/// everywhere, so the canvas does a full refresh (0008 maps `.structure` to
/// `invalidateAll()`). `byteCost` is 0 — the step stores two small value structs and the
/// stack adds `stepOverheadBytes`. Callers finish floating pixels first (0025 item 7), so
/// a property step is never recorded while `floatingPixels != nil`.
struct LayerPropertiesHistoryItem: HistoryItem {
    let name: String
    let icon: HistoryIcon
    let layerID: Layer.ID
    let before: LayerProperties
    let after: LayerProperties

    init(name: String, icon: HistoryIcon, layerID: Layer.ID,
         before: LayerProperties, after: LayerProperties) {
        self.name = name
        self.icon = icon
        self.layerID = layerID
        self.before = before
        self.after = after
    }

    var byteCost: Int { 0 }
    var change: HistoryChange { .structure }
    /// H-6: setting every field to its current value adds no step.
    var isNoOp: Bool { before == after }

    func apply(to state: inout DocumentState) { set(after, in: &state) }

    func revert(_ state: inout DocumentState) { set(before, in: &state) }

    private func set(_ properties: LayerProperties, in state: inout DocumentState) {
        // `HistoryStack` only applies an item to the state it was recorded on, where the
        // layer exists; a missing ID is a caller bug (loud in debug, no release trap).
        guard let index = state.image.layerIndex(for: layerID) else {
            assertionFailure("LayerPropertiesHistoryItem layer \(layerID) is not in the document")
            return
        }
        state.image.layers[index].properties = properties
    }
}

extension LayerPropertiesHistoryItem {
    /// The Layer Properties dialog's OK step (PRD L-2, D-34): one "Layer Properties"
    /// entry no matter which fields changed.
    static func properties(layerID: Layer.ID, before: LayerProperties,
                           after: LayerProperties) -> Self {
        Self(name: "Layer Properties", icon: .layerProperties,
             layerID: layerID, before: before, after: after)
    }

    /// The row's visibility checkbox (LayersMenu.html "Toggle Layer Visibility"): named
    /// after the direction, exactly Paint.NET's history spellings. Only `isVisible`
    /// differs between `before` and `after`.
    static func visibility(layerID: Layer.ID, before: LayerProperties,
                           after: LayerProperties) -> Self {
        Self(name: after.isVisible ? "Show Layer" : "Hide Layer", icon: .layerVisibility,
             layerID: layerID, before: before, after: after)
    }
}
