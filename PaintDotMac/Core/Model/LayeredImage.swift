import Foundation

/// The document model: a size, one DPI, and an ordered list of layers (PRD §7 Core model,
/// APP-5). Index 0 is the bottom layer, the last is the top (Paint.NET order). Compositing
/// is 0012/0024's job, not this type's.
struct LayeredImage: Equatable, Sendable {
    /// Paint.NET's default (APP-5).
    static let defaultDPI: Double = 96
    /// Paint.NET's name for an opened or new image's layer.
    static let defaultLayerName = "Background"

    var size: PixelSize
    /// Finite and > 0.
    var dpi: Double
    var layers: [Layer]
    var activeLayerIndex: Int

    init(size: PixelSize, dpi: Double = defaultDPI, layers: [Layer], activeLayerIndex: Int) {
        self.size = size
        self.dpi = dpi
        self.layers = layers
        self.activeLayerIndex = activeLayerIndex
        precondition(isConsistent, "LayeredImage is not consistent (size \(size), dpi \(dpi), \(layers.count) layers, active index \(activeLayerIndex))")
    }

    /// One visible, opaque, Normal layer holding `surface`.
    init(surface: TiledSurface, dpi: Double = defaultDPI, layerName: String = defaultLayerName) {
        self.init(size: surface.size, dpi: dpi,
                  layers: [Layer(name: layerName, surface: surface)], activeLayerIndex: 0)
    }

    static func blank(size: PixelSize, dpi: Double = defaultDPI, fill: ColorRGBA8,
                      layerName: String = defaultLayerName) -> LayeredImage {
        var surface = TiledSurface(size: size)
        surface.fill(fill)
        return LayeredImage(surface: surface, dpi: dpi, layerName: layerName)
    }

    var activeLayer: Layer {
        get { layers[activeLayerIndex] }
        set { layers[activeLayerIndex] = newValue }
    }

    /// Layers non-empty, every surface size equals `size`, unique layer ids, a valid active
    /// index, and a valid DPI.
    var isConsistent: Bool {
        guard !layers.isEmpty,
              layers.allSatisfy({ $0.size == size }),
              Set(layers.map(\.id)).count == layers.count,
              layers.indices.contains(activeLayerIndex),
              Self.isValidDPI(dpi)
        else { return false }
        return true
    }

    static func isValidDPI(_ dpi: Double) -> Bool {
        dpi.isFinite && dpi > 0
    }
}
