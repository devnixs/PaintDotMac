import AppKit
import CoreGraphics
import Testing
@testable import PaintDotMac

@MainActor
@Suite(.serialized)
struct PlaceholderImageViewTests {
    // All expected rects are hand-computed with the *Scope* formula:
    // scale = min(1, bounds.w / image.w, bounds.h / image.h); origin floors the centering offset.

    @Test func imageRectCentersWithoutUpscaling() {
        #expect(PlaceholderImageView.imageRect(imageSize: CGSize(width: 64, height: 48),
                                               in: CGRect(x: 0, y: 0, width: 480, height: 360))
            == CGRect(x: 208, y: 156, width: 64, height: 48))
    }

    @Test func imageRectFloorsHalfPoints() {
        // (481 − 64) / 2 = 208.5 → 208; (361 − 48) / 2 = 156.5 → 156.
        #expect(PlaceholderImageView.imageRect(imageSize: CGSize(width: 64, height: 48),
                                               in: CGRect(x: 0, y: 0, width: 481, height: 361))
            == CGRect(x: 208, y: 156, width: 64, height: 48))
    }

    @Test func imageRectScalesDownToFit() {
        // scale = min(1, 400/800, 400/600) = 0.5 → 400×300, centered vertically.
        #expect(PlaceholderImageView.imageRect(imageSize: CGSize(width: 800, height: 600),
                                               in: CGRect(x: 0, y: 0, width: 400, height: 400))
            == CGRect(x: 0, y: 50, width: 400, height: 300))
    }

    @Test func imageRectWideImage() {
        // scale = min(1, 500/1000, 500/100) = 0.5 → 500×50, centered vertically.
        #expect(PlaceholderImageView.imageRect(imageSize: CGSize(width: 1000, height: 100),
                                               in: CGRect(x: 0, y: 0, width: 500, height: 500))
            == CGRect(x: 0, y: 225, width: 500, height: 50))
    }

    @Test func imageRectRespectsBoundsOrigin() {
        #expect(PlaceholderImageView.imageRect(imageSize: CGSize(width: 64, height: 48),
                                               in: CGRect(x: 10, y: 20, width: 480, height: 360))
            == CGRect(x: 218, y: 176, width: 64, height: 48))
    }

    @Test func imageRectEmptyBounds() {
        // Note: a CGRect cannot carry a negative size (its initializer normalizes one to a
        // positive size), so width/height 0 are the only non-positive bounds representable.
        for bounds in [CGRect(x: 0, y: 0, width: 0, height: 100),
                       CGRect(x: 0, y: 0, width: 100, height: 0)] {
            let rect = PlaceholderImageView.imageRect(imageSize: CGSize(width: 64, height: 48), in: bounds)
            #expect(rect == .zero)
            #expect(![rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].contains { $0.isNaN })
        }
    }

    /// Edge case: a 1×1 image is drawn at 1×1 pt, centered.
    @Test func imageRectOnePixelImageCenters() {
        // scale = 1; origin = (floor((480 − 1) / 2), floor((360 − 1) / 2)) = (239, 179).
        #expect(PlaceholderImageView.imageRect(imageSize: CGSize(width: 1, height: 1),
                                               in: CGRect(x: 0, y: 0, width: 480, height: 360))
            == CGRect(x: 239, y: 179, width: 1, height: 1))
    }

    @Test func imageRectZeroImage() {
        #expect(PlaceholderImageView.imageRect(imageSize: CGSize(width: 0, height: 10),
                                               in: CGRect(x: 0, y: 0, width: 480, height: 360))
            == .zero)
    }

    /// The contract 0003's CanvasView must keep: identifier `canvas`, label `Canvas`, and the
    /// `"<width> × <height>"` value with U+00D7 and single spaces.
    @Test func accessibilityContract() throws {
        let image = try FixtureFiles.solidImage(width: 64, height: 48, rgba: (1, 2, 3, 255))
        let view = PlaceholderImageView(image: image)
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .image)
        #expect(view.accessibilityIdentifier() == "canvas")
        #expect(view.accessibilityLabel() == "Canvas")
        #expect(view.accessibilityValue() as? String == "64 × 48")
    }

    /// `draw` fills the view with the window background and draws the image exactly into
    /// `imageRect`. Pixels are read back from an sRGB RGBA8 bitmap context, so the expected
    /// bytes inside the image rect are the fixture's own color, exactly (opaque 1:1 draw,
    /// sRGB → sRGB, no interpolation).
    @Test func drawsImageExactlyInsideImageRectOverOpaqueBackground() throws {
        let image = try FixtureFiles.solidImage(width: 16, height: 8, rgba: (200, 100, 50, 255))
        let view = PlaceholderImageView(image: image)
        view.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        // Hand-computed: scale = 1; origin = (floor((32 − 16) / 2), floor((32 − 8) / 2)).
        #expect(PlaceholderImageView.imageRect(imageSize: CGSize(width: 16, height: 8), in: view.bounds)
            == CGRect(x: 8, y: 12, width: 16, height: 8))

        var buffer = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let context = try #require(CGContext(
            data: &buffer, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let graphics = try #require(NSGraphicsContext(cgContext: context, flipped: false))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()

        // The view is not flipped; CGContext data row 0 is the topmost row.
        func pixel(x: Int, y: Int) -> [UInt8] {
            let base = (31 - y) * 32 * 4 + x * 4
            return Array(buffer[base ..< base + 4])
        }

        for point in [(16, 16), (8, 12), (23, 19), (8, 19), (23, 12)] {
            #expect(pixel(x: point.0, y: point.1) == [200, 100, 50, 255],
                    "(\(point.0), \(point.1)) lies inside imageRect and must show the image exactly")
        }
        for point in [(0, 0), (31, 31), (7, 16), (16, 11), (24, 16), (16, 20)] {
            let p = pixel(x: point.0, y: point.1)
            #expect(p[3] == 255, "(\(point.0), \(point.1)) must sit on the opaque background fill")
            #expect(p != [200, 100, 50, 255],
                    "(\(point.0), \(point.1)) lies outside imageRect and must not show the image")
        }
    }
}
