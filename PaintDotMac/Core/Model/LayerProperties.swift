import Foundation

/// The four editable layer properties (PRD L-2, spec 0025): everything the Layer
/// Properties dialog sets and `LayerPropertiesHistoryItem` records. Pixels (`surface`)
/// and identity (`id`) are deliberately excluded — a property step never touches them.
struct LayerProperties: Equatable, Sendable {
    var name: String
    var isVisible: Bool
    /// 0–255, as in Paint.NET (L-2).
    var opacity: UInt8
    var blendMode: BlendMode
}

extension Layer {
    /// The layer's four properties as one value (spec 0025 item 1). Setting it replaces
    /// the four fields only — `surface` and `id` are untouched.
    var properties: LayerProperties {
        get { LayerProperties(name: name, isVisible: isVisible,
                              opacity: opacity, blendMode: blendMode) }
        set {
            name = newValue.name
            isVisible = newValue.isVisible
            opacity = newValue.opacity
            blendMode = newValue.blendMode
        }
    }
}
