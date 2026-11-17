import CoreGraphics
import Foundation

/// The resampling filters (spec 0020 item 1; PRD D-21). 0035 adds `bicubic` and
/// `supersampling` as new cases plus one kernel each in `sampleBilinear`'s sibling —
/// call sites (`FloatingPixels`, the Resize dialogs) never change.
enum ResamplingMode: String, CaseIterable, Sendable {
    case nearestNeighbor
    case bilinear

    /// Paint.NET's spelling (its resampling dropdown).
    var displayName: String {
        switch self {
        case .nearestNeighbor: "Nearest Neighbor"
        case .bilinear: "Bilinear"
        }
    }
}

/// Point-sampling resampler for affine transforms of straight RGBA8 surfaces
/// (spec 0020 item 1; PRD T-5, D-21). Pure and `Sendable` — every function is a value
/// in, value out, safe to call from any thread.
///
/// Sampling geometry (both modes): destination pixel `(x, y)` is evaluated at its
/// centre `(x + 0.5, y + 0.5)`; `p = transform.inverted()` of that point, minus
/// `sourceOrigin`, is the source-local point (source pixel centres at `i + 0.5`).
/// Pixels outside the source read as `(0, 0, 0, 0)`. A non-invertible transform yields
/// all-transparent output — a defined no-op (0019's minimum box size prevents it in
/// practice).
///
/// **Snapping:** any coordinate within `epsilon` of an integer is treated as that
/// integer before every `floor`, so 90° rotations and exact scales built with
/// `cos`/`sin`/`atan2` (entries off by ~1e-16) still hit pixel centres exactly.
enum Resampler {
    static let epsilon: Double = 1e-9

    /// D-21: nearest-neighbor iff the transform is an integer translation/scale with no
    /// rotation (|b| ≤ ε, |c| ≤ ε, `a` and `d` non-zero integers — negative = flip — and
    /// `tx`, `ty` integers); otherwise bilinear.
    static func mode(for transform: CGAffineTransform) -> ResamplingMode {
        func isInteger(_ value: Double) -> Bool {
            value.isFinite && abs(value - value.rounded(.toNearestOrAwayFromZero)) <= epsilon
        }
        guard abs(transform.b) <= epsilon, abs(transform.c) <= epsilon,
              isInteger(transform.a), isInteger(transform.d),
              abs(transform.a) > epsilon, abs(transform.d) > epsilon,
              isInteger(transform.tx), isInteger(transform.ty) else { return .bilinear }
        return .nearestNeighbor
    }

    /// Destination pixels that can receive a non-zero sample: the bounding box of
    /// `sourceRect` (outset by 1 px for bilinear, 0 px for nearest) mapped through
    /// `transform`, rounded outward (floor of the min, ceil of the max). Not clipped;
    /// `.zero` for an empty rect or a non-finite mapping.
    static func destinationBounds(sourceRect: PixelRect, transform: CGAffineTransform,
                                  mode: ResamplingMode) -> PixelRect {
        guard !sourceRect.isEmpty else { return .zero }
        let outset = mode == .bilinear ? 1.0 : 0.0
        let left = Double(sourceRect.minX) - outset
        let top = Double(sourceRect.minY) - outset
        let right = Double(sourceRect.maxX) + outset
        let bottom = Double(sourceRect.maxY) + outset
        let corners = [
            CGPoint(x: left, y: top), CGPoint(x: right, y: top),
            CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom),
        ].map { $0.applying(transform) }
        guard corners.allSatisfy({ $0.componentsAreFinite }) else { return .zero }
        let minX = floor(corners.map(\.x).min()!)
        let maxX = ceil(corners.map(\.x).max()!)
        let minY = floor(corners.map(\.y).min()!)
        let maxY = ceil(corners.map(\.y).max()!)
        guard let width = Int(exactly: maxX - minX), let height = Int(exactly: maxY - minY),
              width >= 0, height >= 0 else { return .zero }
        return PixelRect(x: Int(minX), y: Int(minY), width: width, height: height)
    }

    /// One sample at a source-canvas point (source pixel (0,0) sits at `sourceOrigin`).
    /// The per-pixel oracle path for tests; `resample` runs the same math off band
    /// buffers.
    static func sample(_ source: TiledSurface, sourceOrigin: PixelPoint, at point: CGPoint,
                       mode: ResamplingMode) -> ColorRGBA8 {
        let local = CGPoint(x: point.x - Double(sourceOrigin.x),
                            y: point.y - Double(sourceOrigin.y))
        switch mode {
        case .nearestNeighbor:
            return nearestPixel(source, local: local)
        case .bilinear:
            let u = snap(local.x) - 0.5
            let v = snap(local.y) - 0.5
            let x0 = Int(clamped(floor(u)))
            let y0 = Int(clamped(floor(v)))
            let fx = snap(u) - Double(x0)
            let fy = snap(v) - Double(y0)
            let samples = [
                (pixel: bilinearPixel(source, x: x0, y: y0),
                 weight: (1 - fx) * (1 - fy)),
                (pixel: bilinearPixel(source, x: x0 + 1, y: y0),
                 weight: fx * (1 - fy)),
                (pixel: bilinearPixel(source, x: x0, y: y0 + 1),
                 weight: (1 - fx) * fy),
                (pixel: bilinearPixel(source, x: x0 + 1, y: y0 + 1),
                 weight: fx * fy),
            ]
            return combine(samples)
        }
    }

    /// Resamples `source` (its pixel (0,0) sits at canvas `sourceOrigin`) through
    /// `transform` (source canvas coordinates → destination canvas coordinates) into
    /// `destination` — tightly packed straight RGBA8, `destination.width ×
    /// destination.height × 4` bytes, row-major, row 0 at `destination.minY`.
    ///
    /// Runs in 256-row bands on `DispatchQueue.concurrentPerform`, reading the source
    /// band each band needs once with `readPixels(in:)` — no per-pixel `pixel(at:)` in
    /// the inner loop (NF-1).
    static func resample(_ source: TiledSurface, sourceOrigin: PixelPoint,
                         transform: CGAffineTransform, mode: ResamplingMode,
                         destination: PixelRect) -> [UInt8] {
        let byteCount = destination.width * destination.height * 4
        var output = [UInt8](repeating: 0, count: max(0, byteCount))
        guard destination.width > 0, destination.height > 0 else { return output }
        // `inverted()` silently yields the identity for a non-invertible matrix, so the
        // determinant is checked first: a degenerate transform renders nothing (a nub
        // dragged to zero width shows a transparent box).
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard determinant.isFinite, abs(determinant) > 0,
              [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
                  .allSatisfy(\.isFinite) else { return output }
        let inverse = transform.inverted()
        guard [inverse.a, inverse.b, inverse.c, inverse.d, inverse.tx, inverse.ty]
            .allSatisfy(\.isFinite) else { return output }  // non-invertible → all transparent

        let bandRows = 256
        let bandCount = (destination.height + bandRows - 1) / bandRows
        let width = destination.width
        // One box per band: each `concurrentPerform` task fills its own box and the
        // bands merge serially after the barrier — the unchecked-box pattern of
        // 0013's `SelectionMaskTileBox`.
        let boxes = (0..<bandCount).map { _ in ResampleBandBox() }
        DispatchQueue.concurrentPerform(iterations: bandCount) { band in
            let firstRow = band * bandRows
            let lastRow = min(destination.height, firstRow + bandRows)
            // The band's inverse image in source-canvas coordinates, rounded outward and
            // widened by 1 px (bilinear's neighbour ring); intersected with the source,
            // this is every pixel the band can read.
            let bandTop = Double(destination.minY + firstRow)
            let bandBottom = Double(destination.minY + lastRow)
            let left = Double(destination.minX)
            let right = Double(destination.maxX)
            let inverseCorners = [
                CGPoint(x: left, y: bandTop), CGPoint(x: right, y: bandTop),
                CGPoint(x: right, y: bandBottom), CGPoint(x: left, y: bandBottom),
            ].map { $0.applying(inverse) }
            let margin = mode == .bilinear ? 1.0 : 0.0
            let needLeft = floor(inverseCorners.map(\.x).min()! - margin)
            let needRight = ceil(inverseCorners.map(\.x).max()! + margin)
            let needTop = floor(inverseCorners.map(\.y).min()! - margin)
            let needBottom = ceil(inverseCorners.map(\.y).max()! + margin)
            guard needRight > needLeft, needBottom > needTop,
                  let readX = Int(exactly: needLeft - Double(sourceOrigin.x)),
                  let readY = Int(exactly: needTop - Double(sourceOrigin.y)),
                  let readW = Int(exactly: needRight - needLeft),
                  let readH = Int(exactly: needBottom - needTop) else { return }
            // `pixels` is surface-local: the band's canvas needs shift by −`sourceOrigin`
            // before clipping to the source surface.
            let readRect = PixelRect(x: readX, y: readY, width: readW, height: readH)
                .intersection(source.bounds)
            guard !readRect.isEmpty else { return }  // the band samples nothing
            let pixels = source.readPixels(in: readRect)

            var bandBytes = [UInt8](repeating: 0, count: (lastRow - firstRow) * width * 4)
            for row in firstRow..<lastRow {
                let destY = Double(destination.minY + row) + 0.5
                var outIndex = (row - firstRow) * width * 4
                for column in 0..<width {
                    let destX = Double(destination.minX + column) + 0.5
                    let point = CGPoint(x: destX, y: destY).applying(inverse)
                    let local = CGPoint(x: point.x - Double(sourceOrigin.x),
                                        y: point.y - Double(sourceOrigin.y))
                    let color: ColorRGBA8
                    switch mode {
                    case .nearestNeighbor:
                        color = sampleBandNearest(pixels, readRect: readRect, local: local)
                    case .bilinear:
                        color = sampleBandBilinear(pixels, readRect: readRect, local: local)
                    }
                    bandBytes[outIndex] = color.red
                    bandBytes[outIndex + 1] = color.green
                    bandBytes[outIndex + 2] = color.blue
                    bandBytes[outIndex + 3] = color.alpha
                    outIndex += 4
                }
            }
            boxes[band].bytes = bandBytes
        }
        for (band, box) in boxes.enumerated() {
            guard !box.bytes.isEmpty else { continue }  // band sampled nothing
            let start = band * bandRows * width * 4
            output.replaceSubrange(start..<(start + box.bytes.count), with: box.bytes)
        }
        return output
    }

    /// One mutable band buffer for a parallel `resample` pass (see `SelectionMaskTileBox`).
    private final class ResampleBandBox: @unchecked Sendable {
        var bytes: [UInt8] = []
    }

    // MARK: - Sampling kernels

    /// Coordinates within `epsilon` of an integer are that integer.
    private static func snap(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        return abs(value - rounded) <= epsilon ? rounded : value
    }

    private static func nearestPixel(_ source: TiledSurface, local: CGPoint) -> ColorRGBA8 {
        guard let x = Int(exactly: floor(snap(local.x))),
              let y = Int(exactly: floor(snap(local.y))) else { return .clear }
        return source.pixel(at: PixelPoint(x: x, y: y))
    }

    private static func bilinearPixel(_ source: TiledSurface, x: Int, y: Int) -> ColorRGBA8 {
        source.pixel(at: PixelPoint(x: x, y: y))
    }

    /// `floor` of a possibly astronomically large (but finite) Double → an `Int` that
    /// will fail `Int(exactly:)` lookups downstream rather than trap.
    private static func clamped(_ value: Double) -> Double {
        value < -1e18 ? -1e18 : (value > 1e18 ? 1e18 : value)
    }

    /// Premultiplied, weights-sum-to-1 combination (spec 0020 item 1): `A = Σ w·a`,
    /// `Pc = Σ w·c·a`; alpha rounds half up, the colour un-premultiplies with the
    /// *unrounded* `A`. Alpha 0 → `(0,0,0,0)`, so colour under alpha 0 never bleeds.
    private static func combine(_ samples: [(pixel: ColorRGBA8, weight: Double)]) -> ColorRGBA8 {
        var alpha = 0.0
        var premultipliedRed = 0.0
        var premultipliedGreen = 0.0
        var premultipliedBlue = 0.0
        for sample in samples {
            let weight = sample.weight
            let a = Double(sample.pixel.alpha)
            alpha += weight * a
            premultipliedRed += weight * a * Double(sample.pixel.red)
            premultipliedGreen += weight * a * Double(sample.pixel.green)
            premultipliedBlue += weight * a * Double(sample.pixel.blue)
        }
        let outAlpha = min(255, Int(alpha + 0.5))
        guard outAlpha > 0, alpha > 0 else { return .clear }
        func channel(_ premultiplied: Double) -> UInt8 {
            UInt8(min(255, Int(premultiplied / alpha + 0.5)))
        }
        return ColorRGBA8(red: channel(premultipliedRed),
                          green: channel(premultipliedGreen),
                          blue: channel(premultipliedBlue),
                          alpha: UInt8(outAlpha))
    }

    // MARK: - Band-buffer sampling (the `resample` inner loop)

    /// Reads one pixel from the band buffer by source-local index; outside it (which,
    /// for points the band can reach, means outside the source) is `.clear` —
    /// `pixel(at:)` semantics.
    private static func bandPixel(_ pixels: [UInt8], readRect: PixelRect,
                                  localX: Int, localY: Int) -> ColorRGBA8 {
        guard readRect.contains(PixelPoint(x: localX, y: localY)) else { return .clear }
        let offset = ((localY - readRect.minY) * readRect.width
                      + (localX - readRect.minX)) * 4
        return ColorRGBA8(red: pixels[offset], green: pixels[offset + 1],
                          blue: pixels[offset + 2], alpha: pixels[offset + 3])
    }

    private static func sampleBandNearest(_ pixels: [UInt8], readRect: PixelRect,
                                          local: CGPoint) -> ColorRGBA8 {
        guard let x = Int(exactly: floor(snap(local.x))),
              let y = Int(exactly: floor(snap(local.y))) else { return .clear }
        return bandPixel(pixels, readRect: readRect, localX: x, localY: y)
    }

    private static func sampleBandBilinear(_ pixels: [UInt8], readRect: PixelRect,
                                           local: CGPoint) -> ColorRGBA8 {
        let u = snap(local.x) - 0.5
        let v = snap(local.y) - 0.5
        let x0 = Int(clamped(floor(u)))
        let y0 = Int(clamped(floor(v)))
        let fx = snap(u) - Double(x0)
        let fy = snap(v) - Double(y0)
        return combine([
            (pixel: bandPixel(pixels, readRect: readRect, localX: x0, localY: y0),
             weight: (1 - fx) * (1 - fy)),
            (pixel: bandPixel(pixels, readRect: readRect, localX: x0 + 1, localY: y0),
             weight: fx * (1 - fy)),
            (pixel: bandPixel(pixels, readRect: readRect, localX: x0, localY: y0 + 1),
             weight: (1 - fx) * fy),
            (pixel: bandPixel(pixels, readRect: readRect, localX: x0 + 1, localY: y0 + 1),
             weight: fx * fy),
        ])
    }
}
