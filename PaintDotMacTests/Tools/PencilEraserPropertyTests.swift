import Foundation
import Testing

@testable import PaintDotMac

/// Round-trip and property tests for the two tools (spec 0011 *Test plan*): 200 seeded
/// strokes on a random-noise 300×300 layer, both tools, random colors/alphas/options —
/// the 0008 revert/apply identity (byte-identical both ways), the Eraser's pixel
/// invariants (alpha never rises, RGB survives while alpha > 0, full erase is
/// `(0,0,0,0)`), and the Pencil's containment in the union of the `PixelLine`s of its
/// event pixels. All expectations are written from the spec text, never from the tools.
@MainActor
struct PencilEraserPropertyTests {
    private func event(_ location: CGPoint) -> ToolEvent {
        ToolEvent(location: location, viewLocation: .zero, button: .primary,
                  modifiers: [], clickCount: 1, pressure: 1, timestamp: 0)
    }

    private struct Stroke {
        var context: FakeToolContext
        var preStroke: LayeredImage
        var postStroke: LayeredImage
        var points: [CGPoint]
    }

    /// One seeded random stroke run through the real tool, committed to the fake's stack.
    private func runStroke(isEraser: Bool, random: inout SeededRandom,
                           noiseImage: LayeredImage, size: PixelSize) -> Stroke {
        let context = FakeToolContext(size: size)
        context.updateImage { $0 = noiseImage }
        let color = random.color()
        context.colors = ColorSelection(primary: color, secondary: color)
        let keys = BrushOptions.keys(for: .eraser)
        context.options.setValue(random.double(in: 1 ... 60), for: keys.width)
        context.options.setValue(random.int(in: 0 ... 100), for: keys.hardness)
        context.options.setValue(random.int(in: 0 ... 1) == 0, for: keys.antialiasing)

        let pointCount = random.int(in: 2 ... 20)
        var points: [CGPoint] = []
        points.reserveCapacity(pointCount)
        for _ in 0 ..< pointCount {
            // Mostly on-canvas, sometimes well off it on either side.
            points.append(CGPoint(x: random.double(in: -60 ... Double(size.width) + 60),
                                  y: random.double(in: -60 ... Double(size.height) + 60)))
        }
        let preStroke = context.image
        let tool: any Tool = isEraser ? EraserTool() : PencilTool()
        tool.mouseDown(event(points[0]), context: context)
        for point in points.dropFirst().dropLast() {
            tool.mouseDragged(event(point), context: context)
        }
        tool.mouseUp(event(points[points.count - 1]), context: context)
        return Stroke(context: context, preStroke: preStroke, postStroke: context.image,
                      points: points)
    }

    /// The union of the Bresenham lines through the mapped event pixels — the Pencil's
    /// candidate changed set, computed independently of the tool.
    private func lineUnion(of points: [CGPoint]) -> Set<PixelPoint> {
        let mapped = points.compactMap { PencilTool.pixel(for: $0) }
        var union: Set<PixelPoint> = []
        if let first = mapped.first { union.insert(first) }
        for index in 1 ..< mapped.count {
            PixelLine.forEachPixel(from: mapped[index - 1], to: mapped[index]) {
                union.insert($0)
            }
        }
        return union
    }

    @Test func revertApplyIdentity() {
        let seed = SeededRandom.resolvedSeed(default: 0x0011_0011_0011_0011)
        var random = SeededRandom(seed: seed)
        let size = PixelSize(width: 300, height: 300)
        // One random-noise base layer; every stroke starts from a COW copy of it.
        let noise = TestImages.surface(width: size.width, height: size.height) { _, _ in
            random.color()
        }
        let noiseImage = LayeredImage(surface: noise)

        for iteration in 0 ..< 200 {
            let isEraser = random.int(in: 0 ... 1) == 0
            let detail = "seed=0x\(String(seed, radix: 16, uppercase: true)) "
                + "iteration=\(iteration) eraser=\(isEraser)"
            let stroke = runStroke(isEraser: isEraser, random: &random,
                                   noiseImage: noiseImage, size: size)
            let union = isEraser ? nil : lineUnion(of: stroke.points)

            for y in 0 ..< size.height {
                for x in 0 ..< size.width {
                    let point = PixelPoint(x: x, y: y)
                    let before = stroke.preStroke.layers[0].surface.pixel(at: point)
                    let after = stroke.postStroke.layers[0].surface.pixel(at: point)
                    if isEraser {
                        #expect(after.alpha <= before.alpha,
                                "eraser never raises alpha at \(point) (\(detail))")
                        if after.alpha > 0 {
                            #expect(after.red == before.red && after.green == before.green
                                        && after.blue == before.blue,
                                    "eraser keeps RGB while alpha > 0 at \(point) (\(detail))")
                        } else if before != after {
                            #expect(after == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0),
                                    "fully erased → (0,0,0,0) at \(point) (\(detail))")
                        }
                    } else if before != after {
                        #expect(union?.contains(point) == true,
                                "pencil changed a pixel outside its line union at \(point) (\(detail))")
                    }
                }
            }

            if stroke.context.history.steps.count == 2 {
                stroke.context.navigateForTests { history, state in _ = history.undo(&state) }
                #expect(stroke.context.image == stroke.preStroke,
                        "the revert restores the stroke-start state byte-identically (\(detail))")
                stroke.context.navigateForTests { history, state in _ = history.redo(&state) }
                #expect(stroke.context.image == stroke.postStroke,
                        "re-applying gives the byte-identical stroke result (\(detail))")
            } else {
                #expect(stroke.postStroke == stroke.preStroke,
                        "no step recorded only when nothing changed (H-6) (\(detail))")
            }
        }
    }
}
