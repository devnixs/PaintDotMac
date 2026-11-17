import CoreGraphics
import XCTest

@testable import PaintDotMac

/// NF-1 / NF-4 for Crop to Selection (spec 0022): the crop is O(destination pixels) with
/// a full-tile fast path, run `DispatchQueue.concurrentPerform` over destination tiles.
/// Target: 4000×3000 single opaque layer, rectangle selection (1000, 700, 2000, 1500)
/// (unaligned) → `croppedState` < 150 ms in the Debug test build; the gate allows 3×
/// (450 ms). The median of three `makeHistoryItem` + `HistoryStack.perform` runs is
/// printed for the spec's Verification status (0048 tightens to the real target).
final class CropToSelectionPerformanceTests: XCTestCase {

    private static let size = PixelSize(width: 4000, height: 3000)

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// An opaque white 4000×3000 document with the unaligned rectangle selection.
    private func fixture() -> DocumentState {
        var surface = TiledSurface(size: Self.size)
        surface.fill(.white)
        let selection = Selection(
            rect: CGRect(x: 1000, y: 700, width: 2000, height: 1500),
            canvasSize: Self.size)!
        return DocumentState(image: LayeredImage(surface: surface), selection: selection)
    }

    func testCrop4000x3000() {
        let base = fixture()
        var timings: [Double] = []
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let item = CropToSelection.makeHistoryItem(for: base)
            var live = base
            var stack = HistoryStack(base: .newImage)
            if let item {
                stack.perform(item, on: &live)
            } else {
                XCTFail("the crop recorded no step")
                return
            }
            XCTAssertEqual(live.image.size, PixelSize(width: 2000, height: 1500))
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let value = median(timings)
        print("CropToSelectionPerformanceTests.crop4000x3000: \(String(format: "%.3f", value)) ms (gate 450)")
        XCTAssertLessThanOrEqual(value, 450)
    }
}
