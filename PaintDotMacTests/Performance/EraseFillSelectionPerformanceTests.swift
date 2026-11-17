import CoreGraphics
import XCTest

@testable import PaintDotMac

/// NF-1 / NF-4 for Erase / Fill Selection (spec 0018): Select All / no-selection work is
/// O(tile count) — erase sets tiles to `nil`, fill shares one tile behind the interior —
/// and an antialiased ellipse loops only over the edge ring's `.partial` tiles,
/// concurrently. Each measurement includes `makeHistoryItem` (the `TileDiff`) and
/// `HistoryStack.perform`. Targets on 4000×3000 in a Debug test build: erase Select All
/// < 10 ms, fill without a selection < 20 ms, ellipse erase/fill < 100 ms each; the gate
/// allows 3×, and the medians are printed for the spec's Verification status (0048
/// tightens to the real targets).
final class EraseFillSelectionPerformanceTests: XCTestCase {

    private static let size = PixelSize(width: 4000, height: 3000)

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func whiteState(selection: Selection? = nil) -> DocumentState {
        var surface = TiledSurface(size: Self.size)
        surface.fill(.white)
        return DocumentState(image: LayeredImage(surface: surface), selection: selection)
    }

    /// Three timed `makeHistoryItem` + `HistoryStack.perform` runs. The fixture is built
    /// once; each run works on a copy-on-write copy of it (tile buffers are shared), so
    /// only the command is measured — not the 50 MB white layer.
    private func measure(base: DocumentState,
                         _ make: (DocumentState) -> (any HistoryItem)?) -> Double {
        var timings: [Double] = []
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let item = make(base)
            var live = base
            var stack = HistoryStack(base: .newImage)
            if let item {
                stack.perform(item, on: &live)
            } else {
                XCTFail("the command recorded no step")
            }
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return median(timings)
    }

    /// Erase Selection with Select All (192 tiles → `nil`, no pixel loop):
    /// target 10 ms, gate 30 ms.
    func testEraseSelectAll4000x3000() {
        let base = whiteState(selection: .all(canvasSize: Self.size))
        let value = measure(base: base) { EraseSelection.makeHistoryItem(for: $0) }
        print("EraseFillSelectionPerformanceTests.eraseSelectAll4000x3000: \(String(format: "%.3f", value)) ms (gate 30)")
        XCTAssertLessThanOrEqual(value, 30)
    }

    /// Fill Selection with no selection (whole layer, one shared tile behind the
    /// interior): target 20 ms, gate 60 ms.
    func testFillNoSelection4000x3000() {
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        let base = whiteState()
        let value = measure(base: base) { FillSelection.makeHistoryItem(for: $0, color: red) }
        print("EraseFillSelectionPerformanceTests.fillNoSelection4000x3000: \(String(format: "%.3f", value)) ms (gate 60)")
        XCTAssertLessThanOrEqual(value, 60)
    }

    /// Erase Selection with a full-canvas antialiased ellipse — pixel work only on the
    /// edge ring, concurrently: target 100 ms, gate 300 ms.
    func testEraseEllipse4000x3000() throws {
        let ellipse = try XCTUnwrap(Selection(
            path: CGPath(ellipseIn: CGRect(x: 0, y: 0, width: Self.size.width,
                                           height: Self.size.height),
                         transform: nil),
            canvasSize: Self.size))
        XCTAssertGreaterThan(ellipse.mask.partialTileCount, 10, "an antialiased edge ring")
        let base = whiteState(selection: ellipse)
        let value = measure(base: base) { EraseSelection.makeHistoryItem(for: $0) }
        print("EraseFillSelectionPerformanceTests.eraseEllipse4000x3000: \(String(format: "%.3f", value)) ms (gate 300)")
        XCTAssertLessThanOrEqual(value, 300)
    }

    /// Fill Selection with the same ellipse: target 100 ms, gate 300 ms.
    func testFillEllipse4000x3000() throws {
        let ellipse = try XCTUnwrap(Selection(
            path: CGPath(ellipseIn: CGRect(x: 0, y: 0, width: Self.size.width,
                                           height: Self.size.height),
                         transform: nil),
            canvasSize: Self.size))
        let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        let base = whiteState(selection: ellipse)
        let value = measure(base: base) { FillSelection.makeHistoryItem(for: $0, color: red) }
        print("EraseFillSelectionPerformanceTests.fillEllipse4000x3000: \(String(format: "%.3f", value)) ms (gate 300)")
        XCTAssertLessThanOrEqual(value, 300)
    }
}
