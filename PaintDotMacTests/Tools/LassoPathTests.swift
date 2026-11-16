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
