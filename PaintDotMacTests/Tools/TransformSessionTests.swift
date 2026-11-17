import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `TransformSession` geometry — translate composition, rotation about the frame center
/// with Shift snapping and normalization, scaling in the frame's own axes (⌥ about the
/// center, Shift proportions, flips through zero), and the integer-translation
/// detection. Expected values hand-computed from spec 0019 / Paint.NET `MoveToolBase`.
@MainActor
struct TransformSessionTests {
    private func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    private func session(_ x: Double, _ y: Double, _ w: Double, _ h: Double) throws
        -> TransformSession
    {
        try #require(TransformSession(sourceBounds: CGRect(x: x, y: y, width: w, height: h)))
    }

    private func translate(_ session: TransformSession, _ dx: Int, _ dy: Int)
        -> TransformSession
    {
        session.applying(.translate, from: .zero, to: point(Double(dx), Double(dy)),
                         modifiers: [])
    }

    private func boxClose(_ session: TransformSession, _ minX: Double, _ minY: Double,
                          _ maxX: Double, _ maxY: Double, _ comment: Comment = Comment("")) {
        let box = session.box
        #expect(abs(box.minX - minX) <= 1e-9 && abs(box.minY - minY) <= 1e-9
                    && abs(box.maxX - maxX) <= 1e-9 && abs(box.maxY - maxY) <= 1e-9,
                "box \(box.minX), \(box.minY), \(box.maxX), \(box.maxY) ≠ \(minX), \(minY), \(maxX), \(maxY) \(comment)")
    }

    // MARK: - Init

    @Test func initRejectsDegenerate() {
        #expect(TransformSession(sourceBounds: CGRect(x: 0, y: 0, width: 0, height: 10)) == nil,
                "zero width")
        #expect(TransformSession(sourceBounds: CGRect(x: 0, y: 0, width: 10, height: 0)) == nil)
        #expect(TransformSession(sourceBounds: CGRect(x: 0, y: 0, width: .nan as CGFloat,
                                                      height: 10)) == nil, "NaN")
        #expect(TransformSession(sourceBounds: CGRect(x: .nan as CGFloat, y: 0, width: 10,
                                                      height: 10)) == nil)
    }

    // MARK: - Translate

    @Test func translateComposes() throws {
        let session = try session(0, 0, 100, 50)
        let roundTrip = translate(translate(session, 4, -1), -4, 1)
        #expect(roundTrip.integerTranslation?.dx == 0
                    && roundTrip.integerTranslation?.dy == 0)
        let t = roundTrip.outlineTransform
        #expect(abs(t.a - 1) <= 1e-9 && abs(t.b) <= 1e-9 && abs(t.c) <= 1e-9
                    && abs(t.d - 1) <= 1e-9 && abs(t.tx) <= 1e-9 && abs(t.ty) <= 1e-9,
                "outlineTransform is the identity within 1e-9")
    }

    // MARK: - Rotate

    @Test func rotateQuarterTurn() throws {
        // Session (0, 0, 100, 50), center (50, 25); (100, 25) → (50, 75) is +90°.
        let session = try session(0, 0, 100, 50)
        let rotated = session.applying(.rotate, from: point(100, 25), to: point(50, 75),
                                       modifiers: [])
        #expect(abs(rotated.angle - 90) <= 1e-9)
        let expected: [(Double, Double)] = [(75, -25), (75, 75), (25, 75), (25, -25)]
        for (corner, want) in zip(rotated.canvasCorners, expected) {
            #expect(abs(corner.x - want.0) <= 1e-9 && abs(corner.y - want.1) <= 1e-9,
                    "corner \(corner) ≠ \(want)")
        }
    }

    @Test func rotateShiftSnapsTotal() throws {
        // Angle already 10°; a gesture from the 10° ray to the 47° ray is a raw delta
        // of 37° (total 47) — with Shift the total snaps to 45.
        let session = try session(0, 0, 100, 50)
        let ray10 = point(50 + 50 * cos(10 * .pi / 180), 25 + 50 * sin(10 * .pi / 180))
        let withAngle10 = session.applying(
            .rotate, from: point(100, 25), to: ray10, modifiers: [])
        #expect(abs(withAngle10.angle - 10) <= 1e-6)
        let total47 = withAngle10.applying(
            .rotate, from: ray10,
            to: point(50 + 50 * cos(47 * .pi / 180), 25 + 50 * sin(47 * .pi / 180)),
            modifiers: [])
        #expect(abs(total47.angle - 47) <= 1e-6, "unsnapped control")
        let snapped = withAngle10.applying(
            .rotate, from: ray10,
            to: point(50 + 50 * cos(47 * .pi / 180), 25 + 50 * sin(47 * .pi / 180)),
            modifiers: [.shift])
        #expect(abs(snapped.angle - 45) <= 1e-9)
    }

    @Test func angleNormalization() throws {
        let session = try session(0, 0, 100, 50)
        func quarter(_ s: TransformSession) -> TransformSession {
            s.applying(.rotate, from: point(150, 25), to: point(50, 125), modifiers: [])
        }
        let once = quarter(session)
        let twice = quarter(quarter(session))
        let thrice = quarter(twice)
        let fourTimes = quarter(thrice)
        #expect(abs(once.angle - 90) <= 1e-9, "one quarter turn → 90")
        #expect(abs(twice.angle - 180) <= 1e-9, "two quarter turns → 180, never −180")
        #expect(abs(thrice.angle + 90) <= 1e-9, "three → −90")
        #expect(abs(fourTimes.angle) <= 1e-9, "four → 0")
    }

    // MARK: - Scale

    @Test func scaleCornerBR() throws {
        let session = try session(0, 0, 100, 50)
        // BR nub at (100, 50) dragged by (+50, +25).
        let scaled = session.applying(.scale(.bottomRight), from: point(100, 50),
                                      to: point(150, 75), modifiers: [])
        boxClose(scaled, 0, 0, 150, 75)
    }

    @Test func scaleEdgeRightFlip() throws {
        let session = try session(0, 0, 100, 50)
        // Right nub dragged −150: the box passes the left edge… no — the right edge
        // runs past the (fixed) left edge into a flip.
        let scaled = session.applying(.scale(.right), from: point(100, 25),
                                      to: point(-50, 25), modifiers: [])
        #expect(abs(scaled.box.minX - 0) <= 1e-9)
        #expect(abs(scaled.box.maxX + 50) <= 1e-9, "maxX −50")
        let t = scaled.outlineTransform
        let mapsRight = point(100, 0).applying(t)
        let mapsLeft = point(0, 0).applying(t)
        #expect(abs(mapsRight.x + 50) <= 1e-9 && abs(mapsRight.y) <= 1e-9, "(100,0) → (−50,0)")
        #expect(abs(mapsLeft.x) <= 1e-9 && abs(mapsLeft.y) <= 1e-9, "(0,0) → (0,0)")
    }

    @Test func scaleThroughZeroFlips() throws {
        let session = try session(0, 0, 100, 50)
        let zero = session.applying(.scale(.right), from: point(100, 25),
                                    to: point(0, 25), modifiers: [])
        #expect(abs(zero.box.maxX - 0) <= 1e-9, "width 0")
        let corners = zero.canvasCorners
        #expect(abs(corners[0].x - corners[3].x) <= 1e-9 && abs(corners[1].x - corners[2].x) <= 1e-9,
                "corners collinear: TL/BL and TR/BR share x")
        let flipped = session.applying(.scale(.right), from: point(100, 25),
                                       to: point(-1, 25), modifiers: [])
        #expect(abs(flipped.box.maxX + 1) <= 1e-9, "maxX −1")
    }

    @Test func scaleAboutCenter() throws {
        let session = try session(0, 0, 100, 50)
        // ⌥ right nub +10: right edge +10, left edge −10.
        let scaled = session.applying(.scale(.right), from: point(100, 25),
                                      to: point(110, 25), modifiers: [.option])
        #expect(abs(scaled.box.minX + 10) <= 1e-9, "minX −10")
        #expect(abs(scaled.box.maxX - 110) <= 1e-9, "maxX 110")
    }

    @Test func scaleShiftCorner() throws {
        let session = try session(0, 0, 100, 50)
        // ⇧ BR (+100, 0): candidate 200 × 50 → sx 2, sy 1 → s 1 → box unchanged.
        let clampedOut = session.applying(.scale(.bottomRight), from: point(100, 50),
                                          to: point(200, 50), modifiers: [.shift])
        boxClose(clampedOut, 0, 0, 100, 50, "s = 1 keeps the R0 box")
        // ⇧ BR (+100, +50): candidate 200 × 100 → s = 2 → 200 × 100.
        let scaled = session.applying(.scale(.bottomRight), from: point(100, 50),
                                      to: point(200, 100), modifiers: [.shift])
        boxClose(scaled, 0, 0, 200, 100)
        // ⇧ on an EDGE nub is ignored (Paint.NET allowConstrain = false).
        let edge = session.applying(.scale(.right), from: point(100, 25),
                                    to: point(200, 25), modifiers: [.shift])
        boxClose(edge, 0, 0, 200, 50, "edge nub: unconstrained")
    }

    @Test func scaleShiftUsesSessionStartAspect() throws {
        // Aspect of R0 (2:1), not of the current box.
        let session = try session(0, 0, 100, 50)
        let widened = translate(session, 0, 0)
            .applying(.scale(.right), from: point(100, 25), to: point(200, 25), modifiers: [])
        boxClose(widened, 0, 0, 200, 50)
        let constrained = widened.applying(.scale(.bottomRight), from: point(200, 50),
                                           to: point(200, 100), modifiers: [.shift])
        // Candidate (0, 0, 200, 100): sx 2, sy 2 → s 2 → 200 × 100 (R0 aspect 2:1).
        boxClose(constrained, 0, 0, 200, 100)
    }

    @Test func scaleInRotatedFrame() throws {
        // Rotated +90° about the center; a BR drag by the canvas vector (0, 20) is the
        // local vector (+20, 0) → the box grows in its own width axis only.
        let session = try session(0, 0, 100, 50)
        let rotated = session.applying(.rotate, from: point(150, 25), to: point(50, 125),
                                       modifiers: [])
        let br = rotated.canvasPosition(of: .bottomRight)
        let scaled = rotated.applying(.scale(.bottomRight), from: br,
                                      to: point(br.x, br.y + 20), modifiers: [])
        #expect(abs((scaled.box.maxX - scaled.box.minX) - 120) <= 1e-9, "width 120")
        #expect(abs((scaled.box.maxY - scaled.box.minY) - 50) <= 1e-9, "height 50")
    }

    // MARK: - Composition order (translate/rotate in canvas space)

    /// The rigid rotation by `degrees` about `center` computed from the rotation
    /// definition (raw trigonometry) — deliberately not a `CGAffineTransform` chain, so
    /// an expectation can never inherit a composition-order bug from the code under test.
    private func manualRotate(_ point: CGPoint, about center: CGPoint, _ degrees: Double)
        -> CGPoint
    {
        let radians = degrees * Double.pi / 180
        let dx = point.x - center.x, dy = point.y - center.y
        return CGPoint(x: center.x + dx * cos(radians) - dy * sin(radians),
                       y: center.y + dx * sin(radians) + dy * cos(radians))
    }

    @Test func translateAfterRotateMovesAlongCanvasAxes() throws {
        // Rotate +90° about (50, 25), then translate by (10, 0). Paint.NET translates in
        // document coordinates, so every corner moves by exactly (+10, 0) on the canvas
        // — not along the rotated frame's local axes.
        let session = try session(0, 0, 100, 50)
        let center = point(50, 25)
        let rotated = session.applying(.rotate, from: point(100, 25), to: point(50, 75),
                                       modifiers: [])
        let moved = rotated.translatedBy(dx: 10, dy: 0)
        let base = [point(0, 0), point(100, 0), point(100, 50), point(0, 50)]
        let expected = base
            .map { manualRotate($0, about: center, 90) }
            .map { CGPoint(x: $0.x + 10, y: $0.y) }
        let got = moved.canvasCorners
        for (corner, want) in zip(got, expected) {
            #expect(abs(corner.x - want.x) <= 1e-9 && abs(corner.y - want.y) <= 1e-9,
                    "corner \(corner) ≠ \(want)")
        }
        #expect(moved.integerTranslation == nil, "rotation + translation is no translation")
    }

    @Test func rotateAfterTranslateRotatesAboutMovedCenter() throws {
        // Translate (40, 0) first: the frame's center moves to (90, 25), and the
        // rotation must be about that moved center.
        let session = try session(0, 0, 100, 50)
        let moved = session.translatedBy(dx: 40, dy: 0)
        let center = point(90, 25)
        let rotated = moved.applying(.rotate, from: point(140, 25), to: point(90, 65),
                                     modifiers: [])
        #expect(abs(rotated.angle - 90) <= 1e-9)
        let base = [point(0, 0), point(100, 0), point(100, 50), point(0, 50)]
        let expected = base
            .map { CGPoint(x: $0.x + 40, y: $0.y) }
            .map { manualRotate($0, about: center, 90) }
        let got = rotated.canvasCorners
        for (corner, want) in zip(got, expected) {
            #expect(abs(corner.x - want.x) <= 1e-9 && abs(corner.y - want.y) <= 1e-9,
                    "corner \(corner) ≠ \(want)")
        }
    }

    @Test func translateIgnoresShift() throws {
        // Shift constrains rotate and corner scale only; translate has no constraint.
        let session = try session(0, 0, 100, 50)
        let plain = session.applying(.translate, from: .zero, to: point(7.4, -2.6),
                                     modifiers: [])
        let shifted = session.applying(.translate, from: .zero, to: point(7.4, -2.6),
                                       modifiers: [.shift])
        #expect(shifted == plain)
        #expect(plain.integerTranslation?.dx == 7 && plain.integerTranslation?.dy == -3)
    }

    // MARK: - Integer-translation detection

    @Test func integerTranslationDetection() throws {
        let session = try session(0, 0, 100, 50)
        func rotate(_ s: TransformSession, clockwise: Bool) -> TransformSession {
            s.applying(.rotate, from: point(150, 25),
                       to: clockwise ? point(50, 125) : point(50, -75), modifiers: [])
        }
        let thereAndBack = rotate(rotate(session, clockwise: true), clockwise: false)
        #expect(thereAndBack.integerTranslation?.dx == 0
                    && thereAndBack.integerTranslation?.dy == 0,
                "rotate +90 then −90 is an integer (zero) translation within tolerance")
        let scaled = session.applying(.scale(.bottomRight), from: point(100, 50),
                                      to: point(150, 75), modifiers: [])
        #expect(scaled.integerTranslation == nil, "a ×1.5 scale is not a translation")
        let moved = translate(session, 7, -3).integerTranslation
        #expect(moved?.dx == 7 && moved?.dy == -3)
    }
}
