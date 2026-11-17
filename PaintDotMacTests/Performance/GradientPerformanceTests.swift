import Foundation
import XCTest

@testable import PaintDotMac

/// Full re-render costs for the pending-gradient drag path (spec 0023 *Performance*, NF-1
/// perceived responsiveness; no gate — the numbers go into the spec's Verification status).
/// Fixture: a 4000 × 3000 opaque layer (16 × 12 tiles), generated.
final class GradientPerformanceTests: XCTestCase {
    private func opaqueSurface() -> TiledSurface {
        var surface = TiledSurface(size: PixelSize(width: 4000, height: 3000))
        surface.fill(.white)
        return surface
    }

    private func parameters(_ type: GradientType) -> GradientParameters {
        GradientParameters(type: type, mode: .color,
                           start: CGPoint(x: 100, y: 1500), end: CGPoint(x: 3900, y: 1500),
                           startColor: ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255),
                           endColor: ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255),
                           antialiasing: true, blendMode: .normal)
    }

    func measureRerender(type: GradientType) {
        let before = opaqueSurface()
        measure {
            var surface = before  // COW: shares tiles, no pixel copy
            let visited = GradientRenderer.render(parameters(type), before: before,
                                                  into: &surface, clip: nil)
            XCTAssertEqual(visited.count, 16 * 12)
        }
    }

    func testLinearFullCanvasRerender() {
        measureRerender(type: .linear)
    }

    func testConicalFullCanvasRerender() {
        measureRerender(type: .conical)
    }
}
