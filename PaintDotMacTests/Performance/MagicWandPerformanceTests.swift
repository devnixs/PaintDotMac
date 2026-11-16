import XCTest

@testable import PaintDotMac

/// Spec 0016 *Performance* (Debug test run; 0048 tightens these and moves the fill off
/// the main actor). Fixture: a 6000 × 4000 single-layer gradient image
/// (R = ⌊x·255/5999⌋, G = B = 128, opaque) plus 20 seeded opaque black rectangles.
/// Debug gates: 3 s per 24 MP fill, 10 s for the whole click, 20 s for the pathological
/// 1024 × 1024 checkerboard global click; the measured numbers go in the Verification
/// status. Nothing here is on the display path, so NF-1/NF-2 are unaffected.
final class MagicWandPerformanceTests: XCTestCase {
    private static let seed: UInt64 = 0x0016_0016_0000_0051

    private func gradientImage() -> LayeredImage {
        let width = 6000, height = 4000
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let rowStart = y * width
            for x in 0..<width {
                let offset = (rowStart + x) * 4
                bytes[offset] = UInt8(x * 255 / 5999)
                bytes[offset + 1] = 128
                bytes[offset + 2] = 128
                bytes[offset + 3] = 255
            }
        }
        var surface = bytes.withUnsafeBytes { raw in
            TiledSurface(size: PixelSize(width: width, height: height),
                         rgba8: raw, bytesPerRow: width * 4)
        }
        // 20 seeded opaque black rectangles of 50…400 px — holes in the region.
        var rng = SeededRandom(seed: Self.seed)
        for _ in 0..<20 {
            let w = rng.int(in: 50...400), h = rng.int(in: 50...400)
            let x = rng.int(in: 0...(width - w)), y = rng.int(in: 0...(height - h))
            surface.fill(.black, in: PixelRect(x: x, y: y, width: w, height: h))
        }
        return LayeredImage(surface: surface)
    }

    private func timed(_ label: String, _ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let duration = start.duration(to: .now)
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        print("MagicWandPerformance \(label): \(seconds)s")
        return seconds
    }

    func testContiguousFill24MP() throws {
        let image = gradientImage()
        let source = FloodFillSource.make(for: image, sampling: .layer)
        measure {
            let stencil = try! XCTUnwrap(FloodFill.fill(source, from: PixelPoint(x: 0, y: 0),
                                                        tolerance: FloodTolerance(percent: 50),
                                                        mode: .contiguous))
            XCTAssertGreaterThan(stencil.count, 8_000_000, "roughly the left half")
        }
        let seconds = timed("contiguous 24 MP") {
            _ = FloodFill.fill(source, from: PixelPoint(x: 0, y: 0),
                               tolerance: FloodTolerance(percent: 50), mode: .contiguous)
        }
        XCTAssertLessThan(seconds, 3.0, "Debug contiguous 24 MP fill")
    }

    func testGlobalFill24MP() throws {
        let image = gradientImage()
        let source = FloodFillSource.make(for: image, sampling: .layer)
        measure {
            let stencil = try! XCTUnwrap(FloodFill.fill(source, from: PixelPoint(x: 0, y: 0),
                                                        tolerance: FloodTolerance(percent: 50),
                                                        mode: .global))
            XCTAssertGreaterThan(stencil.count, 8_000_000, "every matching pixel")
        }
        let seconds = timed("global 24 MP") {
            _ = FloodFill.fill(source, from: PixelPoint(x: 0, y: 0),
                               tolerance: FloodTolerance(percent: 50), mode: .global)
        }
        XCTAssertLessThan(seconds, 3.0, "Debug global 24 MP fill")
    }

    @MainActor
    func testWholeClick24MP() throws {
        let image = gradientImage()
        let context = FakeToolContext(image: image)
        // An existing rectangle selection + Union: the click also runs
        // `Selection.combine` and a history commit.
        let existing = Selection(rect: CGRect(x: 100, y: 100, width: 4000, height: 2000),
                                 canvasSize: image.size, antialiased: false)
        context.performHistory(SelectionHistoryItem(name: "setup", icon: .generic,
                                                    before: nil, after: existing))
        context.memoryOptions.setValue(SelectionCombineMode.union,
                                       for: SelectionToolOptions.combineMode)
        let tool = MagicWandTool()
        let seconds = timed("whole click 24 MP") {
            tool.mouseDown(ToolEvent(location: CGPoint(x: 0.5, y: 0.5), viewLocation: .zero,
                                     button: .primary, modifiers: [], clickCount: 1,
                                     pressure: 1, timestamp: 1),
                           context: context)
        }
        XCTAssertNotNil(context.selection)
        XCTAssertEqual(context.history.steps.map(\.name).last, "Magic Wand")
        XCTAssertLessThan(seconds, 10.0, "Debug whole click (fill + outline + mask + combine)")
    }

    func testCheckerboardGlobalClick() throws {
        // 1024 × 1024 checkerboard, global at 0 %: 524 288 one-pixel regions, each its
        // own outline loop — the pathological case, gated at 20 s (Debug).
        let size = PixelSize(width: 1024, height: 1024)
        var surface = TiledSurface(size: size)
        for y in 0..<1024 {
            for x in 0..<1024 where (x & 1) == (y & 1) {
                surface.setPixel(.white, at: PixelPoint(x: x, y: y))
            }
        }
        let image = LayeredImage(surface: surface)
        let source = FloodFillSource.make(for: image, sampling: .layer)
        let seconds = timed("checkerboard global") {
            let stencil = try! XCTUnwrap(FloodFill.fill(source, from: PixelPoint(x: 0, y: 0),
                                                        tolerance: FloodTolerance(percent: 0),
                                                        mode: .global))
            XCTAssertEqual(stencil.count, 1024 * 1024 / 2)
            // The whole click path (outline + mask + Selection) too.
            let selection = Selection(mask: stencil.selectionMask(), outline: stencil.outline())
            XCTAssertNotNil(selection)
        }
        XCTAssertLessThan(seconds, 20.0, "Debug checkerboard global click")
    }
}
