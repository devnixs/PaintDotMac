import Foundation

/// The complete undoable document state (spec 0008 Scope §1). Every history item mutates
/// only a `DocumentState` — anything that becomes undoable later is added *here*, never
/// beside it. Later specs add their undoable state the same way.
///
/// **Selection invariant (0013):** `selection == nil` means "no selection — the whole
/// image is editable"; otherwise `selection.canvasSize == image.size` (asserted by
/// `UndoBridge` after each mutation). Operations that change the canvas size (0022,
/// 0035–0037) are responsible for transforming or dropping the selection in their
/// snapshot.
struct DocumentState: Sendable, Equatable {
    var image: LayeredImage
    /// The active selection, or `nil` when the whole image is editable (E-3, D-40).
    var selection: Selection?
    /// Pixels lifted by Move Selected Pixels (or pasted, 0021) that float over the
    /// layer until finished (spec 0020 item 3). Invariant (asserted by `UndoBridge`):
    /// `floatingPixels == nil || (image.layerIndex(for: floatingPixels.layerID) != nil
    /// && floatingPixels.underlay.size == image.size)`. Snapshot operations (layer or
    /// canvas-size changes) only run with `floatingPixels == nil` because commands
    /// finish the session first (0020 item 9).
    var floatingPixels: FloatingPixels?

    init(image: LayeredImage, selection: Selection? = nil,
         floatingPixels: FloatingPixels? = nil) {
        self.image = image
        self.selection = selection
        self.floatingPixels = floatingPixels
    }
}
