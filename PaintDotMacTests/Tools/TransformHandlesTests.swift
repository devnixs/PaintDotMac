import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// Handle geometry: positions, hit-testing (in view points), translation rounding,
/// `ConstrainAngle`, and the arrow-key nudge map — all expected values hand-computed
/// from spec 0019.
@MainActor
struct TransformHandlesTests {
    /// Session over the rect (10, 20, 100, 50) — canvas (10, 20)…(110, 70), center (60, 45).
    private func session() throws -> TransformSession {
        try #require(TransformSession(sourceBounds: CGRect(x: 10, y: 20, width: 100, height: 50)))
    }

    private func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    // MARK: - Handle positions

    @Test func handlePositionsIdentity() throws {
        let session = try session()
        let expected: [(TransformHandle, CGPoint)] = [
            (.topLeft, point(10, 20)), (.top, point(60, 20)), (.topRight, point(110, 20)),
            (.right, point(110, 45)), (.bottomRight, point(110, 70)),
            (.bottom, point(60, 70)), (.bottomLeft, point(10, 70)), (.left, point(10, 45)),
        ]
        for (handle, want) in expected {
            let got = session.canvasPosition(of: handle)
            #expect(abs(got.x - want.x) <= 1e-9 && abs(got.y - want.y) <= 1e-9, "\(handle)")
        }
        let center = session.canvasCenter
        #expect(abs(center.x - 60) <= 1e-9, "center")
        #expect(abs(center.y - 45) <= 1e-9, "center")
    }

    @Test func handlePositionsRotated90() throws {
        // Same session rotated +90° about its center (60, 45).
        var session = try session()
        session = session.applying(.rotate, from: point(160, 45), to: point(60, 145),
                                   modifiers: [])
        let expected: [(TransformHandle, CGPoint)] = [
            (.topLeft, point(85, -5)), (.topRight, point(85, 95)),
            (.bottomRight, point(35, 95)), (.bottomLeft, point(35, -5)),
        ]
        for (handle, want) in expected {
            let got = session.canvasPosition(of: handle)
            #expect(abs(got.x - want.x) <= 1e-9 && abs(got.y - want.y) <= 1e-9,
                    "\(handle) → \(want)")
        }
        #expect(abs(session.angle - 90) <= 1e-9)
    }

    // MARK: - Hit testing

    @Test func hitTestIdentity() throws {
        let session = try session()
        func hit(_ x: Double, _ y: Double,
                 button: ToolMouseButton = .primary) -> TransformGesture {
            TransformHandles.hitTest(viewPoint: point(x, y), session: session,
                                     canvasToView: .identity, button: button)
        }
        #expect(hit(500, 500, button: .secondary) == .rotate, "secondary anywhere")
        #expect(hit(113, 22) == .scale(.topRight), "3.6 pt from the TR nub")
        #expect(hit(60, 45) == .translate, "inside the frame")
        #expect(hit(60, 10) == .rotate, "10 pt above the top edge (corridor), 50 from nubs")
        #expect(hit(60, -20) == .translate, "40 pt above the frame")
        #expect(hit(110, 77) == .rotate, "7 pt from BR: past the nub, inside the corridor")
    }

    @Test func hitTestScalesWithZoom() throws {
        let session = try session()
        let zoom4 = CGAffineTransform(scaleX: 4, y: 4)
        func hit(_ x: Double, _ y: Double) -> TransformGesture {
            TransformHandles.hitTest(viewPoint: point(x, y).applying(zoom4), session: session,
                                     canvasToView: zoom4, button: .primary)
        }
        // Canvas (111, 21) is 1.4 canvas px from the TR nub — 5.7 VIEW points ≤ 6.
        #expect(hit(111, 21) == .scale(.topRight))
        // Canvas (112, 22): 11.3 view points — not a nub, but 8 points from the right
        // edge → corridor rotate.
        #expect(hit(112, 22) == .rotate)
    }

    @Test func hitTestTinyFrame() throws {
        // 1 × 1 selection: all hit circles overlap; nearest wins, ties in allCases order.
        let session = try #require(TransformSession(sourceBounds: CGRect(x: 0, y: 0,
                                                                         width: 1, height: 1)))
        func hit(_ x: Double, _ y: Double) -> TransformGesture {
            TransformHandles.hitTest(viewPoint: point(x, y), session: session,
                                     canvasToView: .identity, button: .primary)
        }
        #expect(hit(0, 0) == .scale(.topLeft), "distance 0 to TL (first in allCases)")
        #expect(hit(0.5, 0) == .scale(.top), "distance 0 to the top nub")
        #expect(hit(30, 30) == .translate, "well outside the corridor")
    }

    @Test func hitTestFlippedFrame() throws {
        // Box flipped in x: minX 110 > maxX 10 — the nub identities follow the box, not
        // the screen (Paint.NET): topRight sits at (maxX, minY) = (10, 20). Built from
        // the (10, 20, 100, 50) frame: left nub dragged to x = 110 (box (110, 110)),
        // then the right nub from (110, 45) to (10, 45) → box (110, 10).
        let base = try #require(TransformSession(sourceBounds: CGRect(x: 10, y: 20,
                                                                      width: 100, height: 50)))
        let passedThrough = base.applying(.scale(.left), from: point(10, 45),
                                          to: point(110, 45), modifiers: [])
        let flipped = passedThrough.applying(.scale(.right), from: point(110, 45),
                                             to: point(10, 45), modifiers: [])
        #expect(abs(flipped.box.minX - 110) <= 1e-9, "minX 110")
        #expect(abs(flipped.box.maxX - 10) <= 1e-9, "maxX 10 (flipped)")
        func hit(_ x: Double, _ y: Double) -> TransformGesture {
            TransformHandles.hitTest(viewPoint: point(x, y), session: flipped,
                                     canvasToView: .identity, button: .primary)
        }
        // The quad corners of the flipped box are (110,20), (10,20), (10,70), (110,70):
        // (60, 45) is still inside → translate (even-odd handles any winding).
        #expect(hit(60, 45) == .translate)
        // (10, 20) sits exactly on the topRight nub → scale(.topRight), not .topLeft.
        #expect(hit(10, 20) == .scale(.topRight))
        #expect(hit(110, 20) == .scale(.topLeft))
    }

    // MARK: - Translation rounding

    @Test func translationRounding() {
        #expect(TransformHandles.translation(from: point(10.2, 10.2),
                                             to: point(13.7, 9.4)) == (dx: 4, dy: -1))
        #expect(TransformHandles.translation(from: .zero,
                                             to: point(-0.5, 0.5)) == (dx: -1, dy: 1))
        #expect(TransformHandles.translation(from: .zero,
                                             to: point(.nan, 5)) == (dx: 0, dy: 0))
        #expect(TransformHandles.translation(from: .zero,
                                             to: point(1e12, 0)) == (dx: 1_000_000, dy: 0))
    }

    // MARK: - ConstrainAngle (Paint.NET)

    @Test func constrainAngle() {
        func constrained(_ degrees: Double) -> Double { TransformHandles.constrainAngle(degrees) }
        #expect(constrained(50) == 45)
        #expect(constrained(52.6) == 60)
        #expect(constrained(52.5) == 60, "a tie goes up")
        #expect(constrained(7.5) == 15, "a tie goes up")
        #expect(constrained(190) == -165)
        #expect(constrained(-10) == -15)
        #expect(constrained(0) == 0)
        #expect(constrained(180) == 180)
    }

    // MARK: - Nudge mapping

    private func key(_ key: ToolKey, _ modifiers: ToolModifiers = []) -> ToolKeyEvent {
        ToolKeyEvent(key: key, characters: "", modifiers: modifiers, isRepeat: false)
    }

    @Test func nudgeMapping() {
        func check(_ event: ToolKeyEvent, _ dx: Int, _ dy: Int, _ comment: Comment) {
            let got = TransformHandles.nudge(for: event)
            #expect(got?.dx == dx && got?.dy == dy, comment)
        }
        check(key(.leftArrow), -1, 0, "←")
        check(key(.rightArrow), 1, 0, "→")
        check(key(.upArrow), 0, -1, "↑")
        check(key(.downArrow), 0, 1, "↓")
        check(key(.rightArrow, .command), 10, 0, "⌘→")
        check(key(.rightArrow, .shift), 1, 0, "⇧→")
        #expect(TransformHandles.nudge(for: key(.character("a"))) == nil)
    }
}
