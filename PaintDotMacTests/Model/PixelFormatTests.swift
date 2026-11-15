import CoreGraphics
import Testing

@testable import PaintDotMac

@Suite(.serialized)
struct PixelFormatTests {
    @Test func rgba8Properties() {
        let format = PixelFormat.rgba8
        #expect(format.bytesPerPixel == 4)
        #expect(format.isPremultiplied == false)
        #expect(format.colorSpaceName == CGColorSpace.sRGB)
        #expect(format.cgBitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue
                == CGImageAlphaInfo.last.rawValue)
    }
}
