import AppKit
import CoreGraphics

extension ThumbnailImage {
    /// The one AppKit/CG conversion (spec 0025 item 7): an opaque sRGB bitmap. Every
    /// pixel is fully opaque, so straight and premultiplied agree and
    /// `premultipliedLast` is exact. The `Data` copy backs the provider so the image
    /// owns its bytes after this returns.
    var cgImage: CGImage? {
        var bytes = [UInt8](repeating: 0, count: pixels.count * 4)
        var offset = 0
        for p in pixels {
            bytes[offset] = p.red
            bytes[offset + 1] = p.green
            bytes[offset + 2] = p.blue
            bytes[offset + 3] = p.alpha
            offset += 4
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(width: size.width, height: size.height, bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: size.width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
