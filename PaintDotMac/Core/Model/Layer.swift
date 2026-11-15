import Foundation

/// One image layer (PRD §5.3, L-2). Index 0 in `LayeredImage.layers` is the bottom layer.
/// `==` compares every property, including pixels (through `TiledSurface.==`).
struct Layer: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var isVisible: Bool
    /// 0–255, as in Paint.NET (L-2).
    var opacity: UInt8
    var blendMode: BlendMode
    var surface: TiledSurface

    init(id: UUID = UUID(), name: String, surface: TiledSurface,
         isVisible: Bool = true, opacity: UInt8 = 255, blendMode: BlendMode = .normal) {
        self.id = id
        self.name = name
        self.surface = surface
        self.isVisible = isVisible
        self.opacity = opacity
        self.blendMode = blendMode
    }

    var size: PixelSize { surface.size }
}
