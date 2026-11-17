import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `Selection.transformed(_:by:antialiased:)` (spec 0019): integer translations use the
/// pixel-exact mask shift, everything else re-rasterizes the transformed outline.
/// "Equals" compares the normative mask pixel-for-pixel plus the path's bounding box —
/// `Selection ==` additionally demands CGPath structure equality, which differs between
/// boolean-clipped and directly-built outlines by construction.
@MainActor
struct SelectionTransformTests {
    private let canvas = PixelSize(width: 200, height: 200)

    private func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    private func rectSelection(_ rect: CGRect, antialiased: Bool = true) throws -> Selection {
        try #require(Selection(rect: rect, canvasSize: canvas, antialiased: antialiased))
    }

    private func session(_ rect: CGRect) throws -> TransformSession {
        try #require(TransformSession(sourceBounds: rect))
    }

    // MARK: - Integer translation uses the mask shift

    @Test func integerTranslateUsesMaskShift() throws {
        // A seeded random antialiased mask through `init?(mask:outline:)` — the Magic
        // Wand-style source the pixel-exact shift must handle. The outline (and the
        // mask's non-zero region) sit away from the edges so the shift keeps the path
        // on-canvas.
        var rng = SeededRandom(seed: 0x0019_0019_0000_0002)
        let mask = SelectionMask(size: canvas) { x, y in
            (20..<170).contains(x) && (20..<170).contains(y) ? rng.byte() : 0
        }
        let source = try #require(Selection(
            mask: mask,
            outline: CGPath(rect: CGRect(x: 20, y: 20, width: 150, height: 150),
                            transform: nil)))
        let moved = try session(CGRect(x: 20, y: 20, width: 150, height: 150))
            .translatedBy(dx: 7, dy: -3)
        #expect(moved.integerTranslation?.dx == 7 && moved.integerTranslation?.dy == -3)
        let result = try #require(Selection.transformed(source, by: moved, antialiased: true))
        #expect(result.mask == mask.translated(dx: 7, dy: -3), "exact mask shift")
        let box = result.path.boundingBoxOfPath
        let sourceBox = source.path.boundingBoxOfPath
        #expect(abs(box.minX - (sourceBox.minX + 7)) <= 1e-9
                    && abs(box.minY - (sourceBox.minY - 3)) <= 1e-9
                    && abs(box.maxX - (sourceBox.maxX + 7)) <= 1e-9
                    && abs(box.maxY - (sourceBox.maxY - 3)) <= 1e-9,
                "path bbox moved by (7, −3)")
    }

    // MARK: - Scale / rotate re-rasterize

    @Test func scaleRectReRasterizes() throws {
        let source = try rectSelection(CGRect(x: 50, y: 50, width: 100, height: 100))
        let scaled = try session(CGRect(x: 50, y: 50, width: 100, height: 100))
            .applying(.scale(.bottomRight), from: point(150, 150), to: point(200, 200),
                      modifiers: [])
        let result = try #require(Selection.transformed(source, by: scaled, antialiased: true))
        let expected = try rectSelection(CGRect(x: 50, y: 50, width: 150, height: 150))
        #expect(result.mask == expected.mask, "equals Selection(rect: (50, 50, 150, 150))")
    }

    @Test func rotateRectQuarterTurn() throws {
        let source = try rectSelection(CGRect(x: 50, y: 80, width: 100, height: 40))
        let session = try session(CGRect(x: 50, y: 80, width: 100, height: 40))
        // Center (100, 100): (150, 100) → (100, 150) is +90°.
        let rotated = session.applying(.rotate, from: point(150, 100), to: point(100, 150),
                                       modifiers: [])
        let result = try #require(Selection.transformed(source, by: rotated, antialiased: true))
        #expect(result.bounds == PixelRect(x: 80, y: 50, width: 40, height: 100),
                "bounds (80, 50, 40, 100)")
        #expect(result.mask.coverage(x: 100, y: 100) == 255)
        #expect(result.mask.coverage(x: 85, y: 55) == 255)
        #expect(result.mask.coverage(x: 75, y: 100) == 0)
        #expect(result.mask.coverage(x: 130, y: 100) == 0)
        let axisAligned = try rectSelection(CGRect(x: 80, y: 50, width: 40, height: 100))
        for y in 0..<200 {
            for x in 0..<200 {
                let a = Int(result.mask.coverage(x: x, y: y))
                let b = Int(axisAligned.mask.coverage(x: x, y: y))
                #expect(abs(a - b) <= 1, "(\(x), \(y)): \(a) vs \(b)")
            }
        }
    }

    @Test func pixelatedGivesBinary() throws {
        let source = try rectSelection(CGRect(x: 50, y: 50, width: 100, height: 100))
        let session = try session(CGRect(x: 50, y: 50, width: 100, height: 100))
        // +45° about the center (100, 100).
        let rotated = session.applying(
            .rotate, from: point(150, 100),
            to: point(100 + 50 * cos(.pi / 4), 100 + 50 * sin(.pi / 4)), modifiers: [])
        let pixelated = try #require(Selection.transformed(source, by: rotated,
                                                           antialiased: false))
        var antialiasedHasGray = false
        for y in 0..<200 {
            for x in 0..<200 {
                let value = pixelated.mask.coverage(x: x, y: y)
                #expect(value == 0 || value == 255, "pixelated (\(x), \(y)) = \(value)")
            }
        }
        let smooth = try #require(Selection.transformed(source, by: rotated,
                                                        antialiased: true))
        for y in 0..<200 where !antialiasedHasGray {
            for x in 0..<200 {
                let value = smooth.mask.coverage(x: x, y: y)
                if value != 0 && value != 255 { antialiasedHasGray = true; break }
            }
        }
        #expect(antialiasedHasGray, "antialiased rotation produces partial coverage")
    }

    // MARK: - Off-canvas behavior

    @Test func offCanvasIsNil() throws {
        let source = try rectSelection(CGRect(x: 50, y: 50, width: 100, height: 100))
        let session = try session(CGRect(x: 50, y: 50, width: 100, height: 100))
            .translatedBy(dx: 500, dy: 0)
        #expect(Selection.transformed(source, by: session, antialiased: true) == nil)
    }

    @Test func sessionSourceKeepsOffCanvasParts() throws {
        let source = try rectSelection(CGRect(x: 50, y: 50, width: 100, height: 100))
        let session = try session(CGRect(x: 50, y: 50, width: 100, height: 100))
            .translatedBy(dx: 120, dy: 0)
        let result = try #require(Selection.transformed(source, by: session, antialiased: true))
        #expect(result.bounds == PixelRect(x: 170, y: 50, width: 30, height: 100),
                "only the on-canvas part remains")
        // The same session translated back to a total of (0, 0) restores the source
        // exactly — the session kept the un-clipped-by-this-move source outline.
        let back = session.translatedBy(dx: -120, dy: 0)
        #expect(back.integerTranslation?.dx == 0 && back.integerTranslation?.dy == 0)
        let restored = try #require(Selection.transformed(source, by: back, antialiased: true))
        #expect(restored == source, "exact restoration within the session")
    }
}
