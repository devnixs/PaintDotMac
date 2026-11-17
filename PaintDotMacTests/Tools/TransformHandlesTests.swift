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

    @Test func hitTestZoomExtremes() throws {
        // 25 %: the 6 pt nub radius is 24 canvas px; the 20 pt corridor is 80 canvas px.
        // 800 %: the nub radius shrinks to 0.75 canvas px, the corridor to 2.5.
        let session = try session()
        func hit(_ canvasPoint: CGPoint, zoom: Double) -> TransformGesture {
            let toView = CGAffineTransform(scaleX: zoom, y: zoom)
            return TransformHandles.hitTest(viewPoint: canvasPoint.applying(toView),
                                            session: session, canvasToView: toView,
                                            button: .primary)
        }
        #expect(hit(point(132, 20), zoom: 0.25) == .scale(.topRight),
                "22 canvas px from the TR nub is 5.5 view points at 25 %")
        #expect(hit(point(140, 45), zoom: 0.25) == .rotate,
                "30 canvas px right of the frame: 7.5 view points — corridor, no nub")
        #expect(hit(point(110.5, 20.5), zoom: 8) == .scale(.topRight),
                "0.71 canvas px from the nub is 5.7 view points at 800 %")
        #expect(hit(point(112, 22), zoom: 8) == .rotate,
                "2.8 canvas px from the nub (22.6 view) but 16 view from the edge")
    }

    @Test func hitTestRotatedScaledSlabCenterDependsOnZoom() throws {
        // Review fix (spec 0019): the window-level rotate → scale → nudge chain, classified
        // at the hit radii a fixture can actually present. Source (50, 80, 100, 40);
        // rotate +90° about (100, 100) with the right button (drag (150, 100) → (100, 150));
        // drag the rotated BR nub (canvas (80, 150)) to canvas (100, 170) — under the 90°
        // rotation that canvas vector is local (+20, −20), so the frame becomes a 20 × 120
        // canvas slab, centered (110, 110); then the ⌘→ nudge (+10, 0) centers it (120, 110).
        var session = try #require(TransformSession(
            sourceBounds: CGRect(x: 50, y: 80, width: 100, height: 40)))
        session = session.applying(.rotate, from: point(150, 100), to: point(100, 150),
                                   modifiers: [])
        #expect(abs(session.angle - 90) <= 1e-9, "the right-drag chain rotates +90°")
        let br = session.canvasPosition(of: .bottomRight)
        #expect(abs(br.x - 80) <= 1e-9 && abs(br.y - 150) <= 1e-9,
                "the rotated frame's BR nub sits at canvas (80, 150)")
        session = session.applying(.scale(.bottomRight), from: point(80, 150),
                                   to: point(100, 170), modifiers: [])
        session = session.translatedBy(dx: 10, dy: 0)
        let top = session.canvasPosition(of: .top)
        let bottom = session.canvasPosition(of: .bottom)
        #expect(abs(top.x - 130) <= 1e-9 && abs(top.y - 110) <= 1e-9, "top nub (130, 110)")
        #expect(abs(bottom.x - 110) <= 1e-9 && abs(bottom.y - 110) <= 1e-9,
                "bottom nub (110, 110) — 10 canvas px from the center (120, 110)")
        func hit(_ canvasPoint: CGPoint, zoom: Double) -> TransformGesture {
            let toView = CGAffineTransform(scaleX: zoom, y: zoom)
            return TransformHandles.hitTest(viewPoint: canvasPoint.applying(toView),
                                            session: session, canvasToView: toView,
                                            button: .primary)
        }
        // 100 % (the zoom the window test drives): the center is 10 pt from the nubs —
        // past the 6 pt radius — inside the frame → translate ("Move Selection").
        #expect(hit(point(120, 110), zoom: 1) == .translate)
        // 50 % (a headless fixture's initial-layout zoom): the same press is 5 view
        // points from the nubs → the nub beats the interior (Paint.NET's order), and the
        // exact-distance tie resolves in `allCases` order → `.top` ("Scale Selection").
        #expect(hit(point(120, 110), zoom: 0.5) == .scale(.top))
    }

    /// Review verdict (spec 0019, reported while reviewing 0022): the suspected
    /// device-space/point-space mismatch on Retina does **not** exist — proven here.
    /// The hit test and the drawn nubs use `CanvasTransform.canvasToViewAffine`, which
    /// is `deviceToView ∘ canvasToDevice`: the ÷`backingScale` cancels the device scale,
    /// so its output is AppKit POINTS (scale `zoom ÷ backingScale` per axis) — the same
    /// space `ToolEvent.viewLocation` (from `convert(_:from:)`) arrives in and the space
    /// the overlay draws in. This test recomputes that map from the closed-form
    /// definitions documented on `CanvasTransform` (0003) — never from
    /// `canvasToViewAffine` itself — at backing 1 × 2 and zoom 0.25 × 1 × 8, and pins
    /// nub precedence, the center-vs-nub tie, and the rotate corridor in point space.
    /// A future change that feeds device-space projections (or device-space presses)
    /// into `hitTest` goes red at backing 2.
    @Test func hitTestIsViewPointSpaceAtEveryZoomAndBacking() throws {
        // Frame (360, 270, 80, 60) in an 800 × 600 image, image centered in a 640 × 480 pt
        // view; center is 30 canvas px from the top/bottom nubs, 40 from the sides.
        let session = try #require(TransformSession(
            sourceBounds: CGRect(x: 360, y: 270, width: 80, height: 60)))
        for backing in [1.0, 2.0] {
            for zoom in [0.25, 1.0, 8.0] {
                let transform = CanvasTransform(imageSize: PixelSize(width: 800, height: 600),
                                                viewSize: CGSize(width: 640, height: 480),
                                                backingScale: backing, zoom: zoom,
                                                center: CGPoint(x: 400, y: 300))
                // The documented closed form: drawable = round(view · s);
                // o = round(drawable/2 − center · zoom);
                // view point = ((o.x + p.x·zoom)/s, viewHeight − (o.y + p.y·zoom)/s).
                let ox = ((640 * backing).rounded() / 2 - 400 * zoom).rounded()
                let oy = ((480 * backing).rounded() / 2 - 300 * zoom).rounded()
                func view(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: (ox + p.x * zoom) / backing,
                            y: 480 - (oy + p.y * zoom) / backing)
                }
                let affine = transform.canvasToViewAffine
                let space = "backing \(backing) zoom \(zoom)"
                // 1. The affine IS that point-space map (the ÷backing cancellation).
                for p in [point(0, 0), point(360, 270), point(400, 300), point(799.5, 599.5)] {
                    let want = view(p)
                    let got = p.applying(affine)
                    #expect(abs(want.x - got.x) <= 1e-9 && abs(want.y - got.y) <= 1e-9,
                            "canvasToViewAffine off point \(p): \(got) ≠ \(want) (\(space))")
                }
                func hit(_ canvasPoint: CGPoint) -> TransformGesture {
                    TransformHandles.hitTest(viewPoint: view(canvasPoint), session: session,
                                             canvasToView: affine, button: .primary)
                }
                // 2. A press exactly on a drawn nub hits that nub at every zoom/backing.
                for handle in TransformHandle.allCases {
                    #expect(hit(session.canvasPosition(of: handle)) == .scale(handle),
                            "nub \(handle) (\(space))")
                }
                // 3. Center vs nub: the nubs are 30·zoom/s view points away — inside the
                // 6 pt grab only at backing 2 × zoom 0.25, where the nub must beat the
                // interior (Paint.NET's order) and the exact top/bottom tie resolves to
                // `.top`. Everywhere else the press is interior → translate.
                if 30 * zoom / backing <= 6 {
                    #expect(hit(point(400, 300)) == .scale(.top),
                            "nub beats the interior (\(space))")
                } else {
                    #expect(hit(point(400, 300)) == .translate,
                            "interior beats the nubs (\(space))")
                }
                // 4. The rotate corridor is 20 VIEW points at every zoom/backing: 19 pt
                // above the top edge (canvas offset 19·s/zoom) rotates, 21 pt translates.
                #expect(hit(point(400, 270 - 19 * backing / zoom)) == .rotate,
                        "19 view pt outside the edge (\(space))")
                #expect(hit(point(400, 270 - 21 * backing / zoom)) == .translate,
                        "21 view pt outside the edge (\(space))")
            }
        }
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
