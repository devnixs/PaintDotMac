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
        for bounds in [CGRect(x: 0, y: 0, width: 0, height: 100),
                       CGRect(x: 0, y: 0, width: 100, height: 0)] {
            let rect = PlaceholderImageView.imageRect(imageSize: CGSize(width: 64, height: 48), in: bounds)
            #expect(rect == .zero)
            #expect(![rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].contains { $0.isNaN })
        }
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
}
