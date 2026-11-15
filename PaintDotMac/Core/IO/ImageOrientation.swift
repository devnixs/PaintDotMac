import Accelerate
import Foundation

/// EXIF/TIFF orientation values, identical to `CGImagePropertyOrientation` (FMT-B, D-33).
/// The orientation is applied to the pixels on open and never written back on save.
enum ImageOrientation: Int, Sendable {
    case up = 1
    case upMirrored = 2
    case down = 3
    case downMirrored = 4
    case leftMirrored = 5
    case right = 6
    case rightMirrored = 7
    case left = 8

    /// `nil` or any value outside 1…8 is treated as `.up`.
    init(exifValue: Int?) {
        self = ImageOrientation(rawValue: exifValue ?? 1) ?? .up
    }

    /// True for orientations 5–8, where the display axes swap.
    var swapsDimensions: Bool {
        switch self {
        case .leftMirrored, .right, .rightMirrored, .left: true
        default: false
        }
    }

    func orientedSize(_ size: PixelSize) -> PixelSize {
        swapsDimensions ? PixelSize(width: size.height, height: size.width) : size
    }

    /// The reference mapping: which source pixel lands at `point` in the oriented image
    /// (`w`, `h` = source size).
    func sourcePoint(forDestination point: PixelPoint, sourceSize: PixelSize) -> PixelPoint {
        let w = sourceSize.width
        let h = sourceSize.height
        let x = point.x
        let y = point.y
        return switch self {
        case .up: PixelPoint(x: x, y: y)
        case .upMirrored: PixelPoint(x: w - 1 - x, y: y)
        case .down: PixelPoint(x: w - 1 - x, y: h - 1 - y)
        case .downMirrored: PixelPoint(x: x, y: h - 1 - y)
        case .leftMirrored: PixelPoint(x: y, y: x)
        case .right: PixelPoint(x: y, y: h - 1 - x)
        case .rightMirrored: PixelPoint(x: w - 1 - y, y: h - 1 - x)
        case .left: PixelPoint(x: w - 1 - y, y: x)
        }
    }

    /// Reorients a tightly packed RGBA8 buffer and returns the new pixels and size — exactly
    /// the pixels `sourcePoint` defines. vImage does the movement (fast in Debug builds;
    /// the ARGB8888 functions only move 4-byte pixels, so they work for RGBA).
    /// `nil` only when vImage refuses (sizes < 1 are programmer errors); the decoder maps
    /// it to `.corrupt`.
    func apply(to pixels: [UInt8], size: PixelSize) -> (pixels: [UInt8], size: PixelSize)? {
        guard !swapsDimensions else {
            // 5–8 are a rotation, optionally followed by a reflection.
            let clockwiseRotations: UInt8
            let reflection: Reflection?
            switch self {
            // Verified on this Mac: `vImageRotate90_ARGB8888`'s `clockwise = 3` is a visual
            // clockwise quarter turn (buffer row order flips the handedness), 1 is CCW.
            case .left: (clockwiseRotations, reflection) = (1, nil)                      // 90° CCW
            case .right: (clockwiseRotations, reflection) = (3, nil)                     // 90° CW
            case .leftMirrored: (clockwiseRotations, reflection) = (3, .horizontal)
            case .rightMirrored: (clockwiseRotations, reflection) = (3, .vertical)
            default: return (pixels, orientedSize(size))
            }
            // Derivation against `sourcePoint`: a 90° CW rotation gives
            // dst(x, y) = src(y, h−1−x) (orientation 6's rule); reflecting the result
            // horizontally yields orientation 5's rule and vertically yields 7's. A 90° CCW
            // rotation gives dst(x, y) = src(w−1−y, x) (orientation 8's rule).
            guard var rotated = Self.rotate(pixels, size: size, clockwiseQuarters: clockwiseRotations)
            else { return nil }
            if let reflection {
                guard Self.reflect(&rotated.pixels, size: rotated.size, axis: reflection) else { return nil }
            }
            return rotated
        }
        switch self {
        case .up: return (pixels, size)
        case .upMirrored, .downMirrored:
            var result = pixels
            let axis: Reflection = self == .upMirrored ? .horizontal : .vertical
            guard Self.reflect(&result, size: size, axis: axis) else { return nil }
            return (result, size)
        case .down:
            return Self.rotate(pixels, size: size, clockwiseQuarters: 2)
        default:
            return (pixels, size)  // handled by the swap branch above
        }
    }

    private enum Reflection { case horizontal, vertical }

    private static func rotate(_ pixels: [UInt8], size: PixelSize, clockwiseQuarters: UInt8)
        -> (pixels: [UInt8], size: PixelSize)? {
        var source = pixels
        var destination = [UInt8](repeating: 0, count: pixels.count)
        let swapped = clockwiseQuarters % 2 == 1
        let outSize = PixelSize(
            width: swapped ? size.height : size.width,
            height: swapped ? size.width : size.height
        )
        let status: Int = source.withUnsafeMutableBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
                var src = vImage_Buffer(data: sourceBytes.baseAddress,
                                        height: vImagePixelCount(size.height),
                                        width: vImagePixelCount(size.width),
                                        rowBytes: size.width * 4)
                var dst = vImage_Buffer(data: destinationBytes.baseAddress,
                                        height: vImagePixelCount(outSize.height),
                                        width: vImagePixelCount(outSize.width),
                                        rowBytes: outSize.width * 4)
                var background = Pixel_8888(0, 0, 0, 0)  // unused: the source covers every pixel
                return vImageRotate90_ARGB8888(&src, &dst, clockwiseQuarters,
                                               &background,
                                               vImage_Flags(kvImageNoFlags))
            }
        }
        guard status == kvImageNoError else { return nil }
        return (destination, outSize)
    }

    private static func reflect(_ pixels: inout [UInt8], size: PixelSize, axis: Reflection) -> Bool {
        let status: Int = pixels.withUnsafeMutableBytes { bytes in
            var buffer = vImage_Buffer(data: bytes.baseAddress,
                                       height: vImagePixelCount(size.height),
                                       width: vImagePixelCount(size.width),
                                       rowBytes: size.width * 4)
            switch axis {
            case .horizontal:
                return vImageHorizontalReflect_ARGB8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
            case .vertical:
                return vImageVerticalReflect_ARGB8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
            }
        }
        return status == kvImageNoError
    }
}
