import Testing
@testable import PaintDotMac

/// Seeded property tests (spec 0014 *Test plan*, 300 iterations): the geometry invariants
/// for random drags, and perform → undo → redo restoring the exact masks under random
/// combine modes.
@MainActor
struct SelectionToolPropertyTests {
    private func event(_ x: Double, _ y: Double, _ t: TimeInterval) -> ToolEvent {
        ToolEvent(location: CGPoint(x: x, y: y), viewLocation: .zero, button: .primary,
                  modifiers: [], clickCount: 1, pressure: 1, timestamp: t)
    }

    private func geometry(_ mode: SelectionDrawMode, ratio: SelectionRatio,
                          size: PixelSize) -> RectangleSelectGeometry {
        RectangleSelectGeometry(drawMode: mode, ratio: ratio, fixedPixelSize: size)
    }

    @Test(arguments: [SeededRandom.resolvedSeed(default: 0x0014_0014_0014_0014)])
    func geometryInvariants(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        for _ in 0..<300 {
            let image = PixelSize(width: rng.int(in: 1...300), height: rng.int(in: 1...300))
            let a = PixelPoint(x: rng.int(in: -50...350), y: rng.int(in: -50...350))
            let b = PixelPoint(x: rng.int(in: -50...350), y: rng.int(in: -50...350))
            let shift = rng.next() % 2 == 0
            let ratio = SelectionRatio(width: Double(rng.int(in: 1...4)),
                                       height: Double(rng.int(in: 1...4)))
            let modes: [SelectionDrawMode] = [.normal, .fixedRatio, .fixedSize]
            let mode = modes[Int(rng.next() % 3)]
            let fixed = PixelSize(width: rng.int(in: 1...400), height: rng.int(in: 1...400))
            let r = RectangleSelectGeometry.rect(
                anchor: a, current: b, constrainSquare: shift,
                geometry: geometry(mode, ratio: ratio, size: fixed), imageSize: image)
            let comment = Comment("\(comment(image: image, a: a, b: b, shift: shift, mode: mode, ratio: ratio)) \(rng.comment)")
            guard let r else { continue }
            #expect(r.width >= 1 && r.height >= 1, "sides ≥ 1 \(comment)")
            #expect(PixelRect(origin: .zero, size: image).contains(r), "clipped \(comment)")

            let interior = r.minX > 0 && r.minY > 0
                && r.maxX < image.width && r.maxY < image.height
            switch mode {
            case .normal:
                let aInside = (0..<image.width).contains(a.x) && (0..<image.height).contains(a.y)
                let bInside = (0..<image.width).contains(b.x) && (0..<image.height).contains(b.y)
                if !shift, aInside, bInside {
                    #expect(r.contains(a) && r.contains(b), "covers both pixels \(comment)")
                }
                if shift, interior {
                    #expect(r.width == r.height, "Shift square when not clipped \(comment)")
                }
            case .fixedRatio:
                if interior {
                    // Before clipping, w : h tracks the ratio within one pixel.
                    #expect(abs(Double(r.width) / Double(r.height)
                                    - ratio.width / ratio.height)
                                <= 1.0 / Double(min(r.width, r.height)),
                            "ratio \(r.width)/\(r.height) vs \(ratio) \(comment)")
                }
            case .fixedSize:
                #expect(r == PixelRect(x: b.x, y: b.y, width: fixed.width, height: fixed.height)
                            .intersection(PixelRect(origin: .zero, size: image)),
                        "the fixed size follows the pointer \(comment)")
            }
        }
    }

    private func comment(image: PixelSize, a: PixelPoint, b: PixelPoint, shift: Bool,
                         mode: SelectionDrawMode, ratio: SelectionRatio) -> String {
        "image=\(image) a=\(a) b=\(b) shift=\(shift) mode=\(mode) ratio=\(ratio)"
    }

    @Test(arguments: [SeededRandom.resolvedSeed(default: 0x0014_0014_0014_0015)])
    func combineUndoRedo(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        for iteration in 0..<300 {
            let context = FakeToolContext(size: PixelSize(width: 64, height: 48))
            let tool = RectangleSelectTool()
            // Sometimes start from a pixelated existing selection.
            if rng.next() % 2 == 0 {
                let existing = Selection(
                    rect: CGRect(x: 0, y: 0, width: 12, height: 9),
                    canvasSize: context.image.size, antialiased: false)
                context.performHistory(SelectionHistoryItem(name: "setup", icon: .generic,
                                                            before: nil, after: existing))
            }
            let mode = SelectionCombineMode.allCases[Int(rng.next() % 5)]
            context.memoryOptions.setValue(mode, for: SelectionToolOptions.combineMode)
            let a = PixelPoint(x: rng.int(in: -8...70), y: rng.int(in: -8...54))
            let b = PixelPoint(x: rng.int(in: -8...70), y: rng.int(in: -8...54))
            let before = context.selection?.mask
            let stepsBefore = context.history.steps.count

            let t0 = 1.0
            tool.mouseDown(event(Double(a.x) + 0.4, Double(a.y) + 0.4, t0), context: context)
            tool.mouseDragged(event(Double(b.x) + 0.4, Double(b.y) + 0.4, t0 + 0.2), context: context)
            tool.mouseUp(event(Double(b.x) + 0.4, Double(b.y) + 0.4, t0 + 0.4), context: context)

            let recorded = context.history.steps.count > stepsBefore
            let comment: Comment = "seed=\(seed) iteration=\(iteration) mode=\(mode) a=\(a) b=\(b)"
            guard recorded else {
                // A reset / clear/no-selection case: the state must be untouched or nil.
                #expect(context.selection?.mask == before || context.selection == nil,
                        "no-step change keeps or clears the mask \(comment)")
                if mode == .replace {
                    // Replace either emits, or clears (no step only when nothing was set).
                    #expect(!(before != nil && context.selection?.mask == before),
                            "a Replace that changes nothing must have emitted \(comment)")
                }
                continue
            }
            let after = context.selection?.mask
            context.navigateForTests { history, state in _ = history.undo(&state) }
            #expect(context.selection?.mask == before, "undo restores the exact mask \(comment)")
            context.navigateForTests { history, state in _ = history.redo(&state) }
            #expect(context.selection?.mask == after, "redo restores the exact mask \(comment)")
        }
    }

    @Test(arguments: [SeededRandom.resolvedSeed(default: 0x0014_0014_0014_0016)])
    func unionThenExcludeSameRectIsEmpty(seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        for _ in 0..<300 {
            let context = FakeToolContext(size: PixelSize(width: 48, height: 40))
            let tool = RectangleSelectTool()
            let a = PixelPoint(x: rng.int(in: 0...40), y: rng.int(in: 0...32))
            var b = PixelPoint(x: rng.int(in: 0...40), y: rng.int(in: 0...32))
            if a == b { b = PixelPoint(x: b.x + 1, y: b.y + 1) }   // a real drag (hasMoved)

            context.memoryOptions.setValue(SelectionCombineMode.union,
                                           for: SelectionToolOptions.combineMode)
            tool.mouseDown(event(Double(a.x) + 0.4, Double(a.y) + 0.4, 1.0), context: context)
            tool.mouseDragged(event(Double(b.x) + 0.4, Double(b.y) + 0.4, 1.2), context: context)
            tool.mouseUp(event(Double(b.x) + 0.4, Double(b.y) + 0.4, 1.4), context: context)
            let unioned = context.selection

            context.memoryOptions.setValue(SelectionCombineMode.exclude,
                                           for: SelectionToolOptions.combineMode)
            tool.mouseDown(event(Double(a.x) + 0.4, Double(a.y) + 0.4, 2.0), context: context)
            tool.mouseDragged(event(Double(b.x) + 0.4, Double(b.y) + 0.4, 2.2), context: context)
            tool.mouseUp(event(Double(b.x) + 0.4, Double(b.y) + 0.4, 2.4), context: context)
            #expect(context.selection == nil, "A ∖ A = ∅ (seed 0x\(String(seed, radix: 16)))")
            #expect(unioned != nil)
        }
    }
}
