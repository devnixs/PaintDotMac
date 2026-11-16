import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `MagicWandTool` against `FakeToolContext` (spec 0016 *Test plan*): the click result,
/// the modes and options, the history contract, and the property test. Fixture A =
/// white 64 × 64 with red `(255,0,0,255)` squares at (10,10,20,20) and (40,40,16,16).
@MainActor
struct MagicWandToolTests {
    private func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> ColorRGBA8 {
        ColorRGBA8(red: UInt8(r), green: UInt8(g), blue: UInt8(b), alpha: UInt8(a))
    }

    private func event(_ x: Double, _ y: Double, _ t: TimeInterval = 1.0,
                       button: ToolMouseButton = .primary,
                       modifiers: ToolModifiers = []) -> ToolEvent {
        ToolEvent(location: CGPoint(x: x, y: y), viewLocation: .zero, button: button,
                  modifiers: modifiers, clickCount: 1, pressure: 1, timestamp: t)
    }

    private func keyEvent(_ key: ToolKey) -> ToolKeyEvent {
        ToolKeyEvent(key: key, characters: "", modifiers: [], isRepeat: false)
    }

    private func red(_ color: ColorRGBA8) -> Bool {
        color == rgba(255, 0, 0, 255)
    }

    /// Fixture A on the context's layer, written through `updateImage` (no extra step).
    private func paintFixtureA(_ context: FakeToolContext) {
        context.updateImage { image in
            image.layers[0].surface.fill(rgba(255, 0, 0, 255),
                                         in: PixelRect(x: 10, y: 10, width: 20, height: 20))
            image.layers[0].surface.fill(rgba(255, 0, 0, 255),
                                         in: PixelRect(x: 40, y: 40, width: 16, height: 16))
        }
    }

    private func contextWithFixtureA() -> FakeToolContext {
        let context = FakeToolContext(background: .white)
        paintFixtureA(context)
        return context
    }

    private func setExisting(_ context: FakeToolContext, _ rect: PixelRect) {
        let selection = Selection(rect: CGRect(x: Double(rect.x), y: Double(rect.y),
                                               width: Double(rect.width),
                                               height: Double(rect.height)),
                                  canvasSize: context.image.size, antialiased: false)
        context.performHistory(SelectionHistoryItem(name: "setup", icon: .generic,
                                                    before: nil, after: selection))
    }

    private func coverage(_ selection: Selection?, _ x: Int, _ y: Int) -> UInt8 {
        selection?.mask.coverage(x: x, y: y) ?? 0
    }

    /// The first red square as a pixel predicate.
    private func firstSquare(_ x: Int, _ y: Int) -> Bool {
        (10...29).contains(x) && (10...29).contains(y)
    }

    private func secondSquare(_ x: Int, _ y: Int) -> Bool {
        (40...55).contains(x) && (40...55).contains(y)
    }

    // MARK: Click behavior

    @Test func clickSelectsContiguousRegion() throws {
        let context = contextWithFixtureA()
        let tool = MagicWandTool()
        tool.mouseDown(event(15.3, 15.7), context: context)

        #expect(context.history.steps.map(\.name) == ["New Image", "Magic Wand"])
        #expect(context.history.steps[1].icon == .magicWand)
        let selection = try #require(context.selection)
        for y in 0...63 {
            for x in 0...63 {
                #expect(selection.mask.coverage(x: x, y: y)
                            == (firstSquare(x, y) ? 255 : 0), "(\(x), \(y))")
            }
        }
    }

    @Test func shiftClickIsGlobal() throws {
        let context = contextWithFixtureA()
        let tool = MagicWandTool()
        tool.mouseDown(event(15, 15, modifiers: [.shift]), context: context)
        let selection = try #require(context.selection)
        for y in 0...63 {
            for x in 0...63 {
                #expect(selection.mask.coverage(x: x, y: y)
                            == ((firstSquare(x, y) || secondSquare(x, y)) ? 255 : 0),
                        "shift-click (\(x), \(y))")
            }
        }
    }

    @Test func storedGlobalMode() throws {
        let context = contextWithFixtureA()
        context.memoryOptions.setValue(FloodMode.global,
                                       for: FloodToolOptions.floodMode(for: .magicWand))
        let tool = MagicWandTool()
        tool.mouseDown(event(15, 15), context: context)
        let selection = try #require(context.selection)
        for y in 0...63 {
            for x in 0...63 {
                #expect(selection.mask.coverage(x: x, y: y)
                            == ((firstSquare(x, y) || secondSquare(x, y)) ? 255 : 0),
                        "stored global (\(x), \(y))")
            }
        }
    }

    @Test func toleranceOptionIsUsed() throws {
        // 64 × 1 gradient row R = 4x (see `FloodFillTests.toleranceGradient`).
        func gradientContext() -> FakeToolContext {
            var surface = TiledSurface(size: PixelSize(width: 64, height: 1))
            for x in 0...63 {
                surface.setPixel(rgba(4 * x, 0, 0, 255), at: PixelPoint(x: x, y: 0))
            }
            let context = FakeToolContext(image: LayeredImage(surface: surface))
            return context
        }
        for (percent, expected) in [(0, 1), (50, 33), (100, 64)] {
            let context = gradientContext()
            context.memoryOptions.setValue(percent,
                                           for: FloodToolOptions.tolerance(for: .magicWand))
            let tool = MagicWandTool()
            tool.mouseDown(event(0.5, 0.5), context: context)
            let selection = try #require(context.selection, "percent \(percent)")
            #expect(selection.mask.bounds.width == expected, "percent \(percent)")
            var count = 0
            for x in 0...63 where selection.mask.coverage(x: x, y: 0) == 255 { count += 1 }
            #expect(count == expected, "percent \(percent)")
        }
    }

    @Test func samplingLayerVsImage() throws {
        // Bottom (active) opaque white; top a black square (20,20,10,10) over clear.
        let size = PixelSize(width: 64, height: 64)
        var bottomSurface = TiledSurface(size: size)
        bottomSurface.fill(.white)
        var topSurface = TiledSurface(size: size)
        topSurface.fill(.black, in: PixelRect(x: 20, y: 20, width: 10, height: 10))
        let image = LayeredImage(size: size, layers: [
            Layer(name: "Bottom", surface: bottomSurface),
            Layer(name: "Top", surface: topSurface),
        ], activeLayerIndex: 0)

        // Layer sampling: the active layer is uniformly white → the whole canvas.
        let layerContext = FakeToolContext(image: image)
        let tool = MagicWandTool()
        layerContext.memoryOptions.setValue(FloodMode.global,
                                            for: FloodToolOptions.floodMode(for: .magicWand))
        tool.mouseDown(event(5.5, 5.5), context: layerContext)
        #expect(layerContext.selection?.mask.isFull == true, "whole canvas from white")

        // Image sampling: the composite has a black square → excluded.
        let imageContext = FakeToolContext(image: image)
        imageContext.memoryOptions.setValue(FloodMode.global,
                                            for: FloodToolOptions.floodMode(for: .magicWand))
        imageContext.memoryOptions.setValue(SamplingMode.image,
                                            for: FloodToolOptions.samplingMode(for: .magicWand))
        tool.mouseDown(event(5.5, 5.5), context: imageContext)
        let selection = try #require(imageContext.selection)
        for y in 0...63 {
            for x in 0...63 {
                let inSquare = (20...29).contains(x) && (20...29).contains(y)
                #expect(selection.mask.coverage(x: x, y: y) == (inSquare ? 0 : 255),
                        "image sampling (\(x), \(y))")
            }
        }

        // Hiding the top layer brings the whole canvas back under Image sampling.
        var unhidden = image
        unhidden.layers[1].isVisible = false
        let hiddenContext = FakeToolContext(image: unhidden)
        hiddenContext.memoryOptions.setValue(FloodMode.global,
                                             for: FloodToolOptions.floodMode(for: .magicWand))
        hiddenContext.memoryOptions.setValue(SamplingMode.image,
                                             for: FloodToolOptions.samplingMode(for: .magicWand))
        tool.mouseDown(event(5.5, 5.5), context: hiddenContext)
        #expect(hiddenContext.selection?.mask.isFull == true, "hidden layer not composited")
    }

    @Test func combineModes() throws {
        // Existing A = (0,0,16,16) pixelated; wand region B = first red square.
        let a: (Int, Int) -> Bool = { x, y in (0...15).contains(x) && (0...15).contains(y) }
        let b: (Int, Int) -> Bool = firstSquare
        struct ModeCase {
            let picker: SelectionCombineMode
            let button: ToolMouseButton
            let modifiers: ToolModifiers
            let expected: (Bool, Bool) -> Bool
        }
        let cases: [ModeCase] = [
            .init(picker: .replace, button: .primary, modifiers: [],
                  expected: { _, bb in bb }),
            .init(picker: .replace, button: .primary, modifiers: [.command],
                  expected: { aa, bb in aa || bb }),
            .init(picker: .replace, button: .primary, modifiers: [.option],
                  expected: { aa, bb in aa && !bb }),
            .init(picker: .replace, button: .secondary, modifiers: [.option],
                  expected: { aa, bb in aa && bb }),
            .init(picker: .replace, button: .secondary, modifiers: [.command],
                  expected: { aa, bb in aa != bb }),
            .init(picker: .intersect, button: .primary, modifiers: [],
                  expected: { aa, bb in aa && bb }),
        ]
        for (index, testCase) in cases.enumerated() {
            let context = contextWithFixtureA()
            setExisting(context, PixelRect(x: 0, y: 0, width: 16, height: 16))
            context.memoryOptions.setValue(testCase.picker, for: SelectionToolOptions.combineMode)
            let tool = MagicWandTool()
            tool.mouseDown(event(15.5, 15.5, button: testCase.button,
                                 modifiers: testCase.modifiers), context: context)
            let selection = try #require(context.selection, "case \(index)")
            for y in 0...63 {
                for x in 0...63 {
                    let expected = testCase.expected(a(x, y), b(x, y))
                    #expect(selection.mask.coverage(x: x, y: y) == (expected ? 255 : 0),
                            "case \(index) (\(x), \(y))")
                }
            }
        }

        // Exclude of a region covering the selection → nil (no selection) with one step.
        let excludeAll = contextWithFixtureA()
        setExisting(excludeAll, PixelRect(x: 12, y: 12, width: 6, height: 6))
        let stepsBefore = excludeAll.history.steps.count
        MagicWandTool().mouseDown(event(15.5, 15.5, modifiers: [.option]), context: excludeAll)
        #expect(excludeAll.selection == nil, "exclude leaves nothing")
        #expect(excludeAll.history.steps.count == stepsBefore + 1)

        // Xor of an equal region → nil.
        let xorEqual = contextWithFixtureA()
        setExisting(xorEqual, PixelRect(x: 10, y: 10, width: 20, height: 20))
        MagicWandTool().mouseDown(event(15.5, 15.5, button: .secondary, modifiers: [.command]),
                                  context: xorEqual)
        #expect(xorEqual.selection == nil, "A ⊕ A is nothing")
    }

    @Test func shiftWithCommandIsGlobalUnion() throws {
        let context = contextWithFixtureA()
        setExisting(context, PixelRect(x: 0, y: 0, width: 4, height: 4))
        let tool = MagicWandTool()
        tool.mouseDown(event(15.5, 15.5, modifiers: [.command, .shift]), context: context)
        let selection = try #require(context.selection)
        for y in 0...63 {
            for x in 0...63 {
                let expected = (x <= 3 && y <= 3) || firstSquare(x, y) || secondSquare(x, y)
                #expect(selection.mask.coverage(x: x, y: y) == (expected ? 255 : 0),
                        "⌘⇧ (\(x), \(y))")
            }
        }
    }

    @Test func outlineFollowsPixelEdges() throws {
        let context = contextWithFixtureA()
        MagicWandTool().mouseDown(event(15.5, 15.5), context: context)
        let selection = try #require(context.selection)
        #expect(selection.path.boundingBoxOfPath == CGRect(x: 10, y: 10, width: 20, height: 20))
        #expect(selection.path.contains(CGPoint(x: 10.5, y: 10.5), using: .winding,
                                        transform: .identity))
        #expect(!selection.path.contains(CGPoint(x: 9.5, y: 10.5), using: .winding,
                                         transform: .identity))
    }

    // MARK: History contract

    @Test func historyStepUndoRedo() throws {
        let context = contextWithFixtureA()
        let before = context.selection
        let tool = MagicWandTool()
        tool.mouseDown(event(15.5, 15.5), context: context)
        let after = context.selection
        #expect(context.history.steps.map(\.name) == ["New Image", "Magic Wand"])

        context.navigateForTests { history, state in _ = history.undo(&state) }
        #expect(context.selection == before)
        context.navigateForTests { history, state in _ = history.redo(&state) }
        #expect(context.selection == after)
    }

    @Test func noOpUnionAddsNoStep() {
        let context = contextWithFixtureA()
        let tool = MagicWandTool()
        tool.mouseDown(event(15.5, 15.5), context: context)
        let steps = context.history.steps.count
        #expect(context.history.steps.map(\.name).last == "Magic Wand")
        // ⌘-click inside the already-selected region: same mask → no step (D-34).
        tool.mouseDown(event(20.5, 20.5, modifiers: [.command]), context: context)
        #expect(context.history.steps.count == steps, "no-op union adds no step")
        #expect(context.history.steps.filter { $0.name == "Magic Wand" }.count == 1)
    }

    @Test func clickOutsideCanvasDoesNothing() {
        let context = contextWithFixtureA()
        setExisting(context, PixelRect(x: 0, y: 0, width: 8, height: 8))
        let steps = context.history.steps.count
        let existing = context.selection
        let tool = MagicWandTool()
        for location in [CGPoint(x: -0.5, y: 3), CGPoint(x: 64, y: 3),
                         CGPoint(x: CGFloat.nan, y: 3), CGPoint(x: 1e9, y: 3),
                         CGPoint(x: 3, y: -0.25), CGPoint(x: 3, y: 64)] {
            tool.mouseDown(event(location.x, location.y), context: context)
        }
        #expect(context.history.steps.count == steps)
        #expect(context.selection == existing)
    }

    @Test func dragAddsOnlyOneStep() throws {
        let context = contextWithFixtureA()
        let tool = MagicWandTool()
        tool.mouseDown(event(15.5, 15.5), context: context)
        tool.mouseDragged(event(35, 35), context: context)
        tool.mouseDragged(event(50, 50), context: context)
        tool.mouseUp(event(50, 50), context: context)
        #expect(context.history.steps.count == 2, "one click, one step")
        let selection = try #require(context.selection)
        for y in 0...63 {
            for x in 0...63 {
                #expect(selection.mask.coverage(x: x, y: y) == (firstSquare(x, y) ? 255 : 0),
                        "region of the mouseDown pixel (\(x), \(y))")
            }
        }
    }

    @Test func returnDeselects() {
        let context = contextWithFixtureA()
        let tool = MagicWandTool()
        #expect(!tool.keyDown(keyEvent(.returnKey), context: context),
                "no selection → not consumed, no step")
        #expect(context.history.steps.count == 1)
        tool.mouseDown(event(15.5, 15.5), context: context)
        #expect(tool.keyDown(keyEvent(.returnKey), context: context))
        #expect(context.history.steps.map(\.name) == ["New Image", "Magic Wand", "Deselect"])
        #expect(context.selection == nil)
        #expect(tool.keyDown(keyEvent(.enter), context: context) == false, "already empty")
    }

    // MARK: Options

    @Test func optionsDefaultsAndPersistence() throws {
        let context = FakeToolContext()
        // Defaults.
        #expect(context.options.value(FloodToolOptions.tolerance(for: .magicWand)) == 50)
        #expect(context.options.value(FloodToolOptions.floodMode(for: .magicWand)) == .contiguous)
        #expect(context.options.value(FloodToolOptions.samplingMode(for: .magicWand)) == .layer)
        // Exact defaults keys (TOOL-C).
        #expect(FloodToolOptions.tolerance(for: .magicWand).defaultsKey
                    == "tool.magicWand.tolerance")
        #expect(FloodToolOptions.floodMode(for: .magicWand).defaultsKey
                    == "tool.magicWand.floodMode")
        #expect(FloodToolOptions.samplingMode(for: .magicWand).defaultsKey
                    == "tool.magicWand.samplingMode")
        #expect(FloodToolOptions.tolerance(for: .paintBucket).defaultsKey
                    == "tool.paintBucket.tolerance")
        #expect(FloodToolOptions.floodMode(for: .paintBucket).defaultsKey
                    == "tool.paintBucket.floodMode")
        #expect(FloodToolOptions.samplingMode(for: .paintBucket).defaultsKey
                    == "tool.paintBucket.samplingMode")

        // Out-of-range tolerance clamps on read; garbage falls back to the default.
        context.memoryOptions.setStoredValue(150, forKey: "tool.magicWand.tolerance")
        #expect(context.options.value(FloodToolOptions.tolerance(for: .magicWand)) == 100)
        context.memoryOptions.setStoredValue(-3, forKey: "tool.magicWand.tolerance")
        #expect(context.options.value(FloodToolOptions.tolerance(for: .magicWand)) == 0)
        context.memoryOptions.setStoredValue("bogus", forKey: "tool.magicWand.floodMode")
        #expect(context.options.value(FloodToolOptions.floodMode(for: .magicWand)) == .contiguous)
        context.memoryOptions.setStoredValue("global", forKey: "tool.magicWand.floodMode")
        #expect(context.options.value(FloodToolOptions.floodMode(for: .magicWand)) == .global)
        context.memoryOptions.setStoredValue("image", forKey: "tool.magicWand.samplingMode")
        #expect(context.options.value(FloodToolOptions.samplingMode(for: .magicWand)) == .image)
        // Back to the defaults for the click below (the stored "global" above would
        // otherwise widen the region to both squares).
        context.memoryOptions.setValue(FloodMode.contiguous,
                                       for: FloodToolOptions.floodMode(for: .magicWand))

        // The selection mode lives in the shared key (0014, D-44d).
        context.memoryOptions.setValue(SelectionCombineMode.union,
                                       for: SelectionToolOptions.combineMode)
        #expect(context.options.value(SelectionToolOptions.combineMode) == .union)
        paintFixtureA(context)
        setExisting(context, PixelRect(x: 0, y: 0, width: 4, height: 4))
        MagicWandTool().mouseDown(event(15.5, 15.5), context: context)
        let selection = try #require(context.selection)
        #expect(selection.bounds == PixelRect(x: 0, y: 0, width: 30, height: 30),
                "picker Union applied from the shared key")
    }

    @Test func onePixelImage() throws {
        let context = FakeToolContext(size: PixelSize(width: 1, height: 1), background: .white)
        MagicWandTool().mouseDown(event(0.5, 0.5), context: context)
        let selection = try #require(context.selection)
        #expect(selection.mask.isFull)
        #expect(selection.bounds == PixelRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func noPendingEdit() {
        let context = contextWithFixtureA()
        let tool = MagicWandTool()
        tool.mouseDown(event(15.5, 15.5), context: context)
        let steps = context.history.steps.count
        let selection = context.selection
        #expect(!tool.hasPendingEdit)
        #expect(!tool.keyDown(keyEvent(.escape), context: context))
        tool.deactivate(context: context)
        tool.cancel(context: context)
        #expect(context.history.steps.count == steps, "no step from deactivate/cancel")
        #expect(context.selection == selection)
    }

    @Test func effectiveFloodModeTable() {
        #expect(FloodToolOptions.effectiveFloodMode(stored: .contiguous, modifiers: [])
                    == .contiguous)
        #expect(FloodToolOptions.effectiveFloodMode(stored: .contiguous, modifiers: [.shift])
                    == .global)
        #expect(FloodToolOptions.effectiveFloodMode(stored: .global, modifiers: [])
                    == .global)
        #expect(FloodToolOptions.effectiveFloodMode(
            stored: .contiguous, modifiers: [.command, .option, .control]) == .contiguous)
    }

    // MARK: Property: undo/redo round-trips

    @Test func undoRedoProperty() throws {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0016_6E11))
        let comment = rng.comment
        let size = PixelSize(width: 64, height: 64)
        for run in 0...99 {
            let palette = (0..<3).map { _ in rng.color() }
            var surface = TiledSurface(size: size)
            for y in 0...63 {
                for x in 0...63 {
                    surface.setPixel(palette[rng.int(in: 0...2)], at: PixelPoint(x: x, y: y))
                }
            }
            let context = FakeToolContext(image: LayeredImage(surface: surface))
            let tool = MagicWandTool()
            let initial = context.selection
            var snapshots: [SelectionMask?] = []

            let pickerModes = SelectionCombineMode.allCases
            let modifierSets: [ToolModifiers] = [[], [.command], [.option], [.shift],
                                                 [.command, .shift]]
            for _ in 0...rng.int(in: 0...4) {
                context.memoryOptions.setValue(pickerModes[rng.int(in: 0...4)],
                                               for: SelectionToolOptions.combineMode)
                context.memoryOptions.setValue(rng.int(in: 0...100),
                                               for: FloodToolOptions.tolerance(for: .magicWand))
                context.memoryOptions.setValue(rng.next() % 2 == 0 ? FloodMode.contiguous : .global,
                                               for: FloodToolOptions.floodMode(for: .magicWand))
                let stepsBefore = context.history.steps.count
                tool.mouseDown(event(Double(rng.int(in: 0...63)) + 0.5,
                                     Double(rng.int(in: 0...63)) + 0.5,
                                     modifiers: modifierSets[rng.int(in: 0...(modifierSets.count - 1))]),
                               context: context)
                // D-34: a no-op click records no step — snapshot only real steps, or
                // the redo walk below would not line up with the history.
                if context.history.steps.count > stepsBefore {
                    snapshots.append(context.selection?.mask)
                }
            }
            for _ in snapshots {
                context.navigateForTests { history, state in _ = history.undo(&state) }
            }
            #expect(context.selection == initial, "run \(run) undo-all — \(comment)")
            for (index, mask) in snapshots.enumerated() {
                context.navigateForTests { history, state in _ = history.redo(&state) }
                #expect(context.selection?.mask == mask, "run \(run) redo \(index) — \(comment)")
            }
        }
    }
}
