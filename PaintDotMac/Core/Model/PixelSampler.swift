import Foundation

/// Color Picker / Magic Wand sampling areas (spec 0012; PRD T-14, D-28; Paint.NET
/// ColorPicker.html: "one pixel, 3x3, 5x5, 11x11, 31x31 and 51x51"). The raw value is the
/// side length and the stored `tool.colorPicker.samplingSize` value. The menu labels are a
/// stated decision of spec 0012 (Paint.NET's doc page does not spell them out), changeable
/// without affecting behavior.
enum SamplingSize: Int, CaseIterable, Sendable {
    case singlePixel = 1
    case region3 = 3
    case region5 = 5
    case region11 = 11
    case region31 = 31
    case region51 = 51

    var displayName: String {
        self == .singlePixel ? "Single pixel" : "\(rawValue) x \(rawValue) region"
    }
}

/// Where the sample comes from (spec 0012; Paint.NET's "Sample Single Layer" / "Sample All
/// Layers"). Reused by 0016's Magic Wand / Paint Bucket "Sampling" option. Deliberately
/// **not** a `ToolOptionValue` in 0012: `tool.colorPicker.samplingMode` stores the raw
/// `String`, and 0016 adds `extension SamplingMode: ToolOptionValue {}`.
enum SamplingMode: String, CaseIterable, Sendable {
    case layer
    case image

    var displayName: String {
        switch self {
        case .layer: "Layer"
        case .image: "Image"
        }
    }
}

/// The pixel-sampling geometry and averaging of the image-sampling tools (spec 0012;
/// first users: the Color Picker; 0016 reuses it). Pure functions on the model; alpha
/// weighting is premultiplied-style so fully transparent pixels contribute no color and
/// edges of semi-transparent areas do not darken the result (NF-9: straight in, straight
/// out — the weighting is arithmetic, not a stored premultiplied pixel).
enum PixelSampler {
    /// The square `[x − h, x + h] × [y − h, y + h]` with `h = (n − 1) / 2`, intersected
    /// with the canvas; `nil` when `center` lies outside the canvas
    /// (`x < 0 || y < 0 || x ≥ width || y ≥ height`).
    static func sampleRect(center: PixelPoint, size: SamplingSize,
                           canvas: PixelSize) -> PixelRect? {
        guard center.x >= 0, center.y >= 0,
              center.x < canvas.width, center.y < canvas.height else { return nil }
        let half = (size.rawValue - 1) / 2
        return PixelRect(x: center.x - half, y: center.y - half,
                         width: size.rawValue, height: size.rawValue)
            .intersection(canvas.bounds)
    }

    /// Alpha-weighted (premultiplied) average, integer arithmetic (max `2601·255·255 ≈
    /// 1.7×10⁸` fits `Int`): with `n = count`, `S_a = Σ aᵢ` and `S_c = Σ cᵢ·aᵢ`,
    /// `c = (2·S_c + S_a) / (2·S_a)` and `a = (2·S_a + n) / (2·n)` (round half up);
    /// `S_a == 0` → `(0, 0, 0, 0)`. Callers never pass an empty array (spec 0012).
    static func average(_ pixels: [ColorRGBA8]) -> ColorRGBA8 {
        assert(!pixels.isEmpty, "PixelSampler.average requires a non-empty array")
        guard !pixels.isEmpty else { return .clear }
        var sumAlpha = 0
        var sumRed = 0
        var sumGreen = 0
        var sumBlue = 0
        for pixel in pixels {
            let alpha = Int(pixel.alpha)
            sumAlpha += alpha
            sumRed += Int(pixel.red) * alpha
            sumGreen += Int(pixel.green) * alpha
            sumBlue += Int(pixel.blue) * alpha
        }
        guard sumAlpha > 0 else { return .clear }
        let count = pixels.count
        func channel(_ sum: Int) -> UInt8 {
            UInt8(min(255, (2 * sum + sumAlpha) / (2 * sumAlpha)))
        }
        let alpha = UInt8(min(255, (2 * sumAlpha + count) / (2 * count)))
        return ColorRGBA8(red: channel(sumRed), green: channel(sumGreen),
                          blue: channel(sumBlue), alpha: alpha)
    }

    /// Samples `image` at `point`. `nil` when the point is outside the canvas or the image
    /// is in a defensive model state (no layers / out-of-range `activeLayerIndex` — states
    /// only reachable by mutating a constructed image; never a crash).
    /// **Single pixel** returns the source pixel exactly as stored — including the RGB of a
    /// fully transparent pixel. Area sizes average only the pixels inside the clipped
    /// `sampleRect` (count = clipped count, not n²). **Layer** mode reads the active
    /// layer's stored pixels raw — its visibility, opacity, and blend mode are ignored
    /// (Paint.NET samples the layer's own pixels); **Image** mode samples the composite of
    /// the visible layers, compositing only the sampled rect.
    static func sample(_ image: LayeredImage, at point: PixelPoint, size: SamplingSize,
                       mode: SamplingMode,
                       compositor: CPUCompositor = CPUCompositor()) -> ColorRGBA8? {
        guard !image.layers.isEmpty,
              image.layers.indices.contains(image.activeLayerIndex),
              let rect = sampleRect(center: point, size: size, canvas: image.size)
        else { return nil }
        switch mode {
        case .layer:
            let surface = image.layers[image.activeLayerIndex].surface
            if size == .singlePixel { return surface.pixel(at: point) }
            return average(colors(fromRGBA8Bytes: surface.readPixels(in: rect)))
        case .image:
            let region = compositor.composite(image, in: rect)
            if size == .singlePixel { return region.pixels.first ?? .clear }
            return average(region.pixels)
        }
    }

    /// Row-major RGBA8 bytes → pixels. Private helper; byte count is always a multiple of 4.
    private static func colors(fromRGBA8Bytes bytes: [UInt8]) -> [ColorRGBA8] {
        var colors: [ColorRGBA8] = []
        colors.reserveCapacity(bytes.count / 4)
        var offset = 0
        while offset + 3 < bytes.count {
            colors.append(ColorRGBA8(red: bytes[offset], green: bytes[offset + 1],
                                     blue: bytes[offset + 2], alpha: bytes[offset + 3]))
            offset += 4
        }
        return colors
    }
}
