import CoreGraphics

/// The pixel-format abstraction (Q-2). v1 has exactly one case; there are no 16-bit or P3
/// code paths. Every byte-size calculation goes through `bytesPerPixel`.
enum PixelFormat: Hashable, Sendable {
    /// 8 bits per channel, R G B A byte order, sRGB, straight (non-premultiplied) alpha. NF-9.
    case rgba8

    var bytesPerPixel: Int { 4 }

    var isPremultiplied: Bool { false }

    var colorSpaceName: CFString { CGColorSpace.sRGB }

    /// `CGBitmapInfo` for a `CGImage` that holds this format: `CGImageAlphaInfo.last`,
    /// default byte order.
    var cgBitmapInfo: CGBitmapInfo {
        CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
    }
}
