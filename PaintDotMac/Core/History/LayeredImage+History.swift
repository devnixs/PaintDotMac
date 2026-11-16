import Foundation

extension LayeredImage {
    /// The index of the layer with this ID, or `nil` when the layer is gone. Tile diffs
    /// capture layer IDs (not indexes) so undo always targets the same layer.
    func layerIndex(for id: Layer.ID) -> Int? {
        layers.firstIndex { $0.id == id }
    }
}
