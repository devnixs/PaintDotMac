import CoreGraphics
import Foundation
import Testing
@testable import PaintDotMac

/// The pure `LassoPath` rules (spec 0015 *Test plan*): view-space point thinning, the
/// always-kept final point, the degeneracy rule, and the even-odd normalization of the
/// closed path (independent expectations from the PRD T-2 / D-39 rules).
struct LassoPathTests {
    @Test func thinningInViewSpace() {
        var path = LassoPath()
        // View x = 0, 0.4, 0.9, 1.0, 1.5, 2.0 with canvas points = view / 2.
        for viewX in [0.0, 0.4, 0.9, 1.0, 1.5, 2.0] {
            path.appendFreeform(CGPoint(x: viewX / 2, y: 0), view: CGPoint(x: viewX, y: 0))
        }
        #expect(path.points
                    == [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 1.0, y: 0)])
        #expect(path.lastViewPoint == CGPoint(x: 2.0, y: 0))
    }

    @Test func finalPointAlwaysKept() {
        var path = LassoPath()
        path.appendFreeform(CGPoint(x: 0, y: 0), view: CGPoint(x: 0, y: 0))
        path.appendFreeform(CGPoint(x: 10, y: 0), view: CGPoint(x: 10, y: 0))
        // The release point 0.3 view points away is still appended (no thinning).
        path.appendFinal(CGPoint(x: 10.3, y: 0), view: CGPoint(x: 10.3, y: 0))
        #expect(path.points == [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
                                CGPoint(x: 10.3, y: 0)])
        // A release exactly on the last point never duplicates it.
        path.appendFinal(CGPoint(x: 10.3, y: 0), view: CGPoint(x: 20, y: 0))
        #expect(path.points.count == 3)
        #expect(path.lastViewPoint == CGPoint(x: 10.3, y: 0),
                "the rejected duplicate leaves the kept point's view location")
    }

    @Test func degenerateCases() throws {
        func makePath(_ pts: [CGPoint]) -> LassoPath {
            var path = LassoPath()
            for p in pts { path.appendVertex(p, view: p) }
            return path
        }
        let cases: [[CGPoint]] = [
            [],
            [CGPoint(x: 3, y: 4)],
            [CGPoint(x: 3, y: 4), CGPoint(x: 9, y: 1)],
            [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5)],
            [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5), CGPoint(x: 10, y: 10)],
        ]
        for pts in cases {
            let path = makePath(pts)
            #expect(path.isDegenerate, "\(pts) degenerate")
            #expect(path.closedPath() == nil, "\(pts) closedPath nil")
        }
        let triangle = makePath([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
                                 CGPoint(x: 0, y: 10)])
        #expect(!triangle.isDegenerate)
        #expect(triangle.closedPath() != nil)
        // A figure eight has zero signed area but is not degenerate.
        let eight = makePath([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10),
                              CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10)])
        #expect(!eight.isDegenerate)
        #expect(eight.closedPath() != nil)
    }

    /// A pentagram visited in star order encloses its center twice; the even-odd
    /// normalization removes the center — under **both** fill rules afterwards (proves the
    /// path was normalized, not merely filled differently).
    @Test func pentagramCenterIsHoleEvenOdd() throws {
        var path = LassoPath()
        for k in [0, 2, 4, 1, 3] {
            let angle = (-90.0 + 72.0 * Double(k)) * .pi / 180.0
            path.appendVertex(CGPoint(x: 32 + 20 * cos(angle), y: 32 + 20 * sin(angle)),
                              view: .zero)
        }
        let closed = try #require(path.closedPath())
        #expect(closed.contains(CGPoint(x: 32.5, y: 15.5), using: .winding), "tip winding")
        #expect(closed.contains(CGPoint(x: 32.5, y: 15.5), using: .evenOdd), "tip even-odd")
        #expect(!closed.contains(CGPoint(x: 31.5, y: 31.5), using: .winding), "center hole winding")
        #expect(!closed.contains(CGPoint(x: 31.5, y: 31.5), using: .evenOdd), "center hole even-odd")
    }

    /// The degeneracy tolerance is the spec's exact `1e-9 × max(1, |pf − p0|)`: a point
    /// whose cross product sits just below the threshold is collinear (degenerate), one
    /// just above is not. With `p0 = (0, 0)`, `pf = (10, 0)` the bound is `1e-8`, so
    /// `(5, 1e-10)` (cross `1e-9`) is degenerate and `(5, 1e-7)` (cross `1e-6`) is not.
    @Test func collinearityToleranceBoundary() {
        func makePath(_ pts: [CGPoint]) -> LassoPath {
            var path = LassoPath()
            for p in pts { path.appendVertex(p, view: p) }
            return path
        }
        let justBelow = makePath([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
                                  CGPoint(x: 5, y: 1e-10)])
        #expect(justBelow.isDegenerate, "cross 1e-9 ≤ 1e-8 tolerance → click rule")
        let justAbove = makePath([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
                                  CGPoint(x: 5, y: 1e-7)])
        #expect(!justAbove.isDegenerate, "cross 1e-6 > 1e-8 tolerance → a real sliver")
        #expect(justAbove.closedPath() != nil)
    }

    /// An hourglass (self-crossing quadrilateral) visited A → B → C → D. Hand-derived:
    /// with A(10, 10), B(30, 10), C(10, 26), D(30, 26) the diagonals B→C (y = 34 − 0.8x)
    /// and D→A (y = 2 + 0.8x) cross at (20, 18), splitting the plane into four lobes: the
    /// top (20.5, 11.5) and bottom (20.5, 24.5) triangles are covered once (selected),
    /// the left (12.5, 18.5) is covered twice in **opposite** directions (even crossings
    /// → parity out; winding nets 0 → out) and the right (26.5, 18.5) zero times. For a
    /// quadrilateral both rules agree — the pentagram's winding-2 center
    /// (`pentagramCenterIsHoleEvenOdd`) is where the rules differ; this pins that the
    /// closed path is the four-lobe figure, not a convex hull or a dropped loop. No
    /// half-integer scanline ray passes through a vertex (y ∈ {10, 26}) and no edge
    /// crossing lands on a center, so containment is exact.
    @Test func hourglassNormalizesToEvenOdd() throws {
        var path = LassoPath()
        for p in [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10),
                  CGPoint(x: 10, y: 26), CGPoint(x: 30, y: 26)] {
            path.appendVertex(p, view: p)
        }
        let closed = try #require(path.closedPath())
        #expect(closed.contains(CGPoint(x: 20.5, y: 11.5), using: .winding), "single top")
        #expect(!closed.contains(CGPoint(x: 12.5, y: 18.5), using: .winding),
                "opposite-direction double coverage nets winding 0 → not selected")
        #expect(closed.contains(CGPoint(x: 20.5, y: 24.5), using: .winding), "single bottom")
        #expect(!closed.contains(CGPoint(x: 26.5, y: 18.5), using: .winding), "zero right")
    }

    /// A clockwise (negative signed area) simple outline encloses the same region after
    /// normalization as the counter-clockwise one — normalization must not drop or flip
    /// the interior of a simple contour (the even-odd rule is orientation-independent).
    @Test func reversedOutlineEnclosesSameRegion() throws {
        func closed(_ pts: [CGPoint]) -> CGPath? {
            var path = LassoPath()
            for p in pts { path.appendVertex(p, view: p) }
            return path.closedPath()
        }
        let ccw = try #require(closed([CGPoint(x: 2, y: 2), CGPoint(x: 10, y: 2),
                                       CGPoint(x: 10, y: 10), CGPoint(x: 2, y: 10)]))
        let cw = try #require(closed([CGPoint(x: 2, y: 2), CGPoint(x: 2, y: 10),
                                      CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 2)]))
        for point in [CGPoint(x: 5.5, y: 5.5), CGPoint(x: 2.5, y: 9.5),
                      CGPoint(x: 9.5, y: 2.5)] {
            #expect(ccw.contains(point, using: .winding) == cw.contains(point, using: .winding),
                    "\(point) agrees for both orientations")
            #expect(cw.contains(point, using: .winding), "clockwise interior \(point)")
        }
        for point in [CGPoint(x: 1.5, y: 5.5), CGPoint(x: 10.5, y: 5.5),
                      CGPoint(x: 5.5, y: 10.5)] {
            #expect(!cw.contains(point, using: .winding), "clockwise exterior \(point)")
        }
    }

    @Test func closedPathEndsAtStart() throws {
        var path = LassoPath()
        for p in [CGPoint(x: 2, y: 2), CGPoint(x: 10, y: 2), CGPoint(x: 10, y: 10)] {
            path.appendVertex(p, view: p)
        }
        let closed = try #require(path.closedPath())
        #expect(closed.boundingBoxOfPath == CGRect(x: 2, y: 2, width: 8, height: 8))
        // The straight closing line (10,10) → (2,2) makes the triangle below y = x.
        #expect(closed.contains(CGPoint(x: 9, y: 3), using: .evenOdd))
        #expect(!closed.contains(CGPoint(x: 3, y: 9), using: .evenOdd))
    }
}
