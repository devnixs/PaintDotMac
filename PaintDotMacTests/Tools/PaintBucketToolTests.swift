import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `PaintBucketTool` against `FakeToolContext` (spec 0017 *Test plan*): the flood
/// semantics (contiguous / global / Shift / tolerance via 0016), TOOL-A colors, the
/// selection barrier and clipping (TOOL-B), Fill = Selection, sampling, the one-step
/// history contract (D-34), and the property test. The line fixture is a 20 × 20 white
/// image with a black column at x = 10.
@MainActor
struct PaintBucketToolTests {
    private let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
    private let blue = ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255)

    private func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> ColorRGBA8 {
        ColorRGBA8(red: UInt8(r), green: UInt8(g), blue: UInt8(b), alpha: UInt8(a))
    }

    private func event(_ x: Double, _ y: Double,
                       button: ToolMouseButton = .primary,
                       modifiers: ToolModifiers = []) -> ToolEvent {
        ToolEvent(location: CGPoint(x: x, y: y), viewLocation: .zero, button: button,
                  modifiers: modifiers, clickCount: 1, pressure: 1, timestamp: 1)
    }

    private func keyEvent(_ key: ToolKey) -> ToolKeyEvent {
        ToolKeyEvent(key: key, characters: "", modifiers: [], isRepeat: false)
    }

    /// 20 × 20 white with a black vertical line at x = 10.
    private func lineContext() -> FakeToolContext {
        let context = FakeToolContext(size: PixelSize(width: 20, height: 20), background: .white)
        context.updateImage { image in
            image.layers[0].surface.fill(.black, in: PixelRect(x: 10, y: 0, width: 1, height: 20))
        }
        return context
    }

    /// Aliased fill (the binary-edge tests pin pixels; the feather is tested separately).
    private func setAliased(_ context: FakeToolContext) {
        context.memoryOptions.setValue(false, for: PaintBucketOptions.antialiasingKey)
    }

    private func setSelection(_ context: FakeToolContext, _ selection: Selection?) {
        context.performHistory(SelectionHistoryItem(name: "setup", icon: .generic,
                                                    before: nil, after: selection))
    }

    private func pixelatedRect(_ context: FakeToolContext, _ rect: PixelRect) -> Selection? {
        Selection(rect: CGRect(x: Double(rect.x), y: Double(rect.y),
                               width: Double(rect.width), height: Double(rect.height)),
                  canvasSize: context.image.size, antialiased: false)
    }

    private func pixel(_ context: FakeToolContext, _ x: Int, _ y: Int, layer: Int = 0)
        -> ColorRGBA8
    {
        context.image.layers[layer].surface.pixel(at: PixelPoint(x: x, y: y))
    }

    // MARK: Flood semantics

    @Test func contiguousStopsAtBorder() {
        let context = lineContext()
        setAliased(context)
        context.colors = ColorSelection(primary: red, secondary: blue)
        PaintBucketTool().mouseDown(event(3.5, 3.5), context: context)
        for y in 0..<20 {
            for x in 0..<20 {
                let want = x < 10 ? red : (x == 10 ? ColorRGBA8.black : ColorRGBA8.white)
                #expect(pixel(context, x, y) == want, "(\(x), \(y))")
            }
        }
    }

    @Test func globalFillsDisconnectedAreas() {
        let context = lineContext()
        setAliased(context)
        context.colors = ColorSelection(primary: red, secondary: blue)
        context.memoryOptions.setValue(FloodMode.global,
                                       for: FloodToolOptions.floodMode(for: .paintBucket))
        PaintBucketTool().mouseDown(event(3.5, 3.5), context: context)
        for y in 0..<20 {
            for x in 0..<20 {
                let want = x == 10 ? ColorRGBA8.black : red
                #expect(pixel(context, x, y) == want, "(\(x), \(y))")
            }
        }
    }

    @Test func shiftClickIsGlobal() {
        let context = lineContext()
        setAliased(context)
        context.colors = ColorSelection(primary: red, secondary: blue)
        PaintBucketTool().mouseDown(event(3.5, 3.5, modifiers: [.shift]), context: context)
        for y in 0..<20 {
            for x in 0..<20 {
                let want = x == 10 ? ColorRGBA8.black : red
                #expect(pixel(context, x, y) == want, "(\(x), \(y))")
            }
        }
        // The stored option stays Contiguous — Shift steers this click only.
        #expect(context.memoryOptions.value(
            FloodToolOptions.floodMode(for: .paintBucket)) == .contiguous)
    }

    @Test func toleranceZeroIsExact() {
        let context = FakeToolContext(size: PixelSize(width: 20, height: 20), background: .white)
        context.updateImage { image in
            image.layers[0].surface.setPixel(rgba(254, 255, 255, 255),
                                             at: PixelPoint(x: 7, y: 7))
        }
        setAliased(context)
        context.colors = ColorSelection(primary: red, secondary: blue)
        context.memoryOptions.setValue(FloodMode.global,
                                       for: FloodToolOptions.floodMode(for: .paintBucket))
        context.memoryOptions.setValue(0, for: FloodToolOptions.tolerance(for: .paintBucket))
        PaintBucketTool().mouseDown(event(3.5, 3.5), context: context)
        #expect(pixel(context, 7, 7) == rgba(254, 255, 255, 255), "one step off is not exact")
        for y in 0..<20 {
            for x in 0..<20 where !(x == 7 && y == 7) {
                #expect(pixel(context, x, y) == red, "(\(x), \(y))")
            }
        }
    }

    @Test func toleranceHundredFillsAll() {
        let context = lineContext()
        setAliased(context)
        context.colors = ColorSelection(primary: red, secondary: blue)
        context.memoryOptions.setValue(100,
                                       for: FloodToolOptions.tolerance(for: .paintBucket))
        PaintBucketTool().mouseDown(event(3.5, 3.5), context: context)
        for y in 0..<20 {
            for x in 0..<20 {
                #expect(pixel(context, x, y) == red, "(\(x), \(y))")
            }
        }
    }

    @Test func regionMatchesFloodFillOracle() throws {
        // 50 seeded 32 × 32 images of 4 palette colors × random tolerance/mode/seed; the
        // painted pixels are exactly 0016's stencil for the same inputs (its metric is
        // tested there — this pins the wiring). The fill color is off-palette so
        // "painted" is unambiguous.
        var rng = SeededRandom(seed: 0x0017_0017_0000_0049)
        let palette: [ColorRGBA8] = [.white, .black, red, blue]
        let fill = rgba(0, 255, 0, 255)
        for iteration in 0..<50 {
            let size = PixelSize(width: 32, height: 32)
            var surface = TiledSurface(size: size)
            for y in 0..<32 {
                for x in 0..<32 {
                    surface.setPixel(palette[rng.int(in: 0...3)], at: PixelPoint(x: x, y: y))
                }
            }
            let context = FakeToolContext(image: LayeredImage(surface: surface))
            context.colors = ColorSelection(primary: fill, secondary: fill)
            setAliased(context)
            let floodMode: FloodMode = rng.int(in: 0...1) == 0 ? .contiguous : .global
            context.memoryOptions.setValue(floodMode,
                                           for: FloodToolOptions.floodMode(for: .paintBucket))
            let tolerancePercent = rng.int(in: 0...100)
            context.memoryOptions.setValue(tolerancePercent,
                                           for: FloodToolOptions.tolerance(for: .paintBucket))
            let seed = PixelPoint(x: rng.int(in: 0...31), y: rng.int(in: 0...31))
            PaintBucketTool().mouseDown(event(Double(seed.x) + 0.5, Double(seed.y) + 0.5),
                                        context: context)
            let oracle = try #require(FloodFill.fill(FloodFillSource.layer(surface),
                                                    from: seed,
                                                    tolerance: FloodTolerance(
                                                        percent: tolerancePercent),
                                                    mode: floodMode))
            for y in 0..<32 {
                for x in 0..<32 {
                    let point = PixelPoint(x: x, y: y)
                    #expect((pixel(context, x, y) == fill) == oracle.contains(point),
                            "iteration \(iteration) seed (\(seed.x), \(seed.y)) tolerance \(tolerancePercent) \(floodMode.displayName) at (\(x), \(y))")
                }
            }
        }
    }

    // MARK: TOOL-A — buttons pick colors

    @Test func buttonsPickColors() {
        func filled(_ button: ToolMouseButton, _ modifiers: ToolModifiers) -> ColorRGBA8 {
            let context = FakeToolContext(background: .white)
            setAliased(context)
            context.colors = ColorSelection(primary: red, secondary: blue)
            PaintBucketTool().mouseDown(event(5.5, 5.5, button: button, modifiers: modifiers),
                                        context: context)
            return pixel(context, 5, 5)
        }
        #expect(filled(.primary, []) == red, "left = primary")
        #expect(filled(.secondary, []) == blue, "right = secondary")
        #expect(filled(.primary, [.control]) == blue, "Control-left = secondary")
    }

    // MARK: TOOL-B — the selection barrier and clip

    @Test func floodStopsAtSelection() {
        // Pixelated clip x < 8, AA on: the feather ring at x = 8 is masked to 0.
        let context = FakeToolContext(size: PixelSize(width: 20, height: 20), background: .white)
        setSelection(context, pixelatedRect(context, PixelRect(x: 0, y: 0, width: 8, height: 20)))
        context.memoryOptions.setValue(true, for: PaintBucketOptions.antialiasingKey)
        context.colors = ColorSelection(primary: red, secondary: blue)
        PaintBucketTool().mouseDown(event(3.5, 3.5), context: context)
        for y in 0..<20 {
            for x in 0..<20 {
                #expect(pixel(context, x, y) == (x < 8 ? red : ColorRGBA8.white), "(\(x), \(y))")
            }
        }

        // Traversal: two bands joined only through unselected columns 8…11 — Contiguous
        // never crosses them; Global fills both.
        func bandContext(global: Bool) -> FakeToolContext {
            let bands = FakeToolContext(size: PixelSize(width: 20, height: 20),
                                        background: .white)
            setAliased(bands)
            let path = CGMutablePath()
            path.addRect(CGRect(x: 0, y: 0, width: 8, height: 20))
            path.addRect(CGRect(x: 12, y: 0, width: 8, height: 20))
            setSelection(bands, Selection(path: path, canvasSize: bands.image.size,
                                          antialiased: false))
            bands.colors = ColorSelection(primary: red, secondary: blue)
            bands.memoryOptions.setValue(global ? FloodMode.global : FloodMode.contiguous,
                                         for: FloodToolOptions.floodMode(for: .paintBucket))
            PaintBucketTool().mouseDown(event(3.5, 3.5), context: bands)
            return bands
        }
        let contiguous = bandContext(global: false)
        let global = bandContext(global: true)
        for y in 0..<20 {
            for x in 0..<20 {
                let wantContiguous = x < 8 ? red : ColorRGBA8.white
                #expect(pixel(contiguous, x, y) == wantContiguous,
                        "contiguous (\(x), \(y)) — the flood must not cross unselected pixels")
                let wantGlobal = (x < 8 || x >= 12) ? red : ColorRGBA8.white
                #expect(pixel(global, x, y) == wantGlobal, "global (\(x), \(y))")
            }
        }
    }

    @Test func antialiasedSelectionEdgeScalesCoverage() {
        // Clip: 255 for x < 8, 128 at x == 8, else 0. Black on white with effCov 128:
        // Sa = 128, fa = 65 025 → R = G = B = (255·255·127 + 32 512)/65 025 = 127.
        let context = FakeToolContext(size: PixelSize(width: 20, height: 20), background: .white)
        setAliased(context)
        var bytes = [UInt8](repeating: 0, count: SelectionMaskTileStorage.byteCount)
        for y in 0..<20 {
            for x in 0..<8 { bytes[y * Tile.size + x] = 255 }
            bytes[y * Tile.size + 8] = 128
        }
        let mask = SelectionMask(size: context.image.size,
                                 tiles: [.partial(SelectionMaskTileStorage(bytes: bytes))])
        setSelection(context, Selection(mask: mask, outline: CGPath(rect: .zero, transform: nil)))
        context.colors = ColorSelection(primary: .black, secondary: .white)
        PaintBucketTool().mouseDown(event(3.5, 3.5), context: context)
        for y in 0..<20 {
            #expect(pixel(context, 8, y) == rgba(127, 127, 127, 255), "(8, \(y))")
            #expect(pixel(context, 9, y) == ColorRGBA8.white, "(9, \(y)) — outside the clip")
        }
    }

    @Test func clickOutsideSelectionIsNoOp() {
        let context = FakeToolContext(size: PixelSize(width: 20, height: 20), background: .white)
        setAliased(context)
        setSelection(context, pixelatedRect(context, PixelRect(x: 0, y: 0, width: 8, height: 20)))
        context.colors = ColorSelection(primary: red, secondary: blue)
        PaintBucketTool().mouseDown(event(15.5, 5.5), context: context)
        #expect(context.history.steps.map(\.name) == ["New Image", "setup"])
        #expect(context.imageUpdates == 0)
    }

    @Test func fillSelectionClickOutsideSelectionIsNoOp() {
        // Fill = Selection: the click itself must still land inside the selection
        // (spec 0017 step 4 runs before the fillMode branch) — outside it nothing is
        // filled, no step is added, and no image update happens.
        let context = FakeToolContext(size: PixelSize(width: 20, height: 20), background: .white)
        setAliased(context)
        context.memoryOptions.setValue(PaintBucketFillMode.selection,
                                       for: PaintBucketOptions.fillModeKey)
        setSelection(context, pixelatedRect(context, PixelRect(x: 0, y: 0, width: 8, height: 20)))
        context.colors = ColorSelection(primary: red, secondary: blue)
        PaintBucketTool().mouseDown(event(15.5, 5.5), context: context)
        #expect(context.history.steps.map(\.name) == ["New Image", "setup"])
        #expect(context.imageUpdates == 0)
        for y in 0..<20 {
            for x in 0..<20 {
                #expect(pixel(context, x, y) == ColorRGBA8.white, "(\(x), \(y))")
            }
        }
    }

    // MARK: Fill = Selection

    @Test func fillSelectionModeIgnoresTolerance() {
        let context = lineContext()
        context.memoryOptions.setValue(PaintBucketFillMode.selection,
                                       for: PaintBucketOptions.fillModeKey)
        context.memoryOptions.setValue(0, for: FloodToolOptions.tolerance(for: .paintBucket))
        setSelection(context, pixelatedRect(context, PixelRect(x: 5, y: 0, width: 10, height: 20)))
        context.colors = ColorSelection(primary: red, secondary: blue)
        PaintBucketTool().mouseDown(event(7.5, 3.5), context: context)
        for y in 0..<20 {
            for x in 0..<20 {
                let want = (5...14).contains(x) ? red
                    : (x == 10 ? ColorRGBA8.black : ColorRGBA8.white)
                #expect(pixel(context, x, y) == want, "(\(x), \(y))")
            }
        }
        #expect(context.history.steps.last?.name == "Paint Bucket")
    }

    @Test func fillSelectionWithoutSelectionFillsLayer() {
        let context = lineContext()
        context.memoryOptions.setValue(PaintBucketFillMode.selection,
                                       for: PaintBucketOptions.fillModeKey)
        context.colors = ColorSelection(primary: red, secondary: blue)
        PaintBucketTool().mouseDown(event(10.5, 10.5), context: context)
        for y in 0..<20 {
            for x in 0..<20 {
                #expect(pixel(context, x, y) == red, "(\(x), \(y))")
            }
        }
    }

    // MARK: Sampling

    @Test func imageSamplingWritesActiveLayerOnly() {
        func twoLayerContext() -> FakeToolContext {
            let size = PixelSize(width: 20, height: 20)
            var bottom = TiledSurface(size: size)
            bottom.fill(.white)
            bottom.fill(.black, in: PixelRect(x: 10, y: 0, width: 1, height: 20))
            let image = LayeredImage(size: size, layers: [
                Layer(name: "Bottom", surface: bottom),
                Layer(name: "Top", surface: TiledSurface(size: size)),
            ], activeLayerIndex: 1)
            let context = FakeToolContext(image: image)
            setAliased(context)
            context.colors = ColorSelection(primary: red, secondary: blue)
            return context
        }

        // Image sampling reads the composite: the black line stops the flood and the
        // write lands only on the (transparent) active top layer.
        let imageSampling = twoLayerContext()
        imageSampling.memoryOptions.setValue(SamplingMode.image,
                                             for: FloodToolOptions.samplingMode(
                                                for: .paintBucket))
        PaintBucketTool().mouseDown(event(3.5, 3.5), context: imageSampling)
        for y in 0..<20 {
            for x in 0..<20 {
                let wantTop = x < 10 ? red : ColorRGBA8.clear
                #expect(pixel(imageSampling, x, y, layer: 1) == wantTop, "top (\(x), \(y))")
                let wantBottom = x == 10 ? ColorRGBA8.black : ColorRGBA8.white
                #expect(pixel(imageSampling, x, y, layer: 0) == wantBottom,
                        "bottom (\(x), \(y)) must stay untouched")
            }
        }

        // Layer sampling reads the active layer: uniformly transparent, so the
        // transparent seed matches everything and the whole top fills.
        let layerSampling = twoLayerContext()
        PaintBucketTool().mouseDown(event(3.5, 3.5), context: layerSampling)
        for y in 0..<20 {
            for x in 0..<20 {
                #expect(pixel(layerSampling, x, y, layer: 1) == red, "top (\(x), \(y))")
            }
        }
    }

    // MARK: History contract

    @Test func historyUndoRedo() {
        let context = lineContext()
        setAliased(context)
        context.colors = ColorSelection(primary: red, secondary: blue)
        let before = context.image.layers[0].surface
        PaintBucketTool().mouseDown(event(3.5, 3.5), context: context)
        let after = context.image.layers[0].surface

        #expect(context.history.steps.map(\.name) == ["New Image", "Paint Bucket"])
        #expect(context.history.steps[1].icon == .paintBucket)

        context.navigateForTests { history, state in _ = history.undo(&state) }
        #expect(context.image.layers[0].surface == before, "undo restores the layer exactly")
        context.navigateForTests { history, state in _ = history.redo(&state) }
        #expect(context.image.layers[0].surface == after, "redo re-applies it")
    }

    @Test func multiTileFillIsOneStepAndUndoIsExact() {
        // A contiguous fill crossing the 256-tile boundary touches six tiles of the
        // 600 × 600 layer — still exactly ONE "Paint Bucket" step, and undo/redo
        // restore and re-apply the exact per-tile storage across the boundary.
        let context = FakeToolContext(size: PixelSize(width: 600, height: 600),
                                      background: .white)
        context.updateImage { image in
            image.layers[0].surface.fill(.black,
                                         in: PixelRect(x: 300, y: 0, width: 1, height: 600))
        }
        setAliased(context)
        context.colors = ColorSelection(primary: red, secondary: blue)
        let before = context.image.layers[0].surface
        PaintBucketTool().mouseDown(event(5.5, 5.5), context: context)
        let after = context.image.layers[0].surface
        #expect(after.pixel(at: PixelPoint(x: 255, y: 300)) == red, "tile column 0")
        #expect(after.pixel(at: PixelPoint(x: 256, y: 300)) == red, "tile column 1")
        #expect(after.pixel(at: PixelPoint(x: 299, y: 599)) == red, "tile (1, 2)")
        #expect(after.pixel(at: PixelPoint(x: 300, y: 300)) == ColorRGBA8.black, "the border")
        #expect(after.pixel(at: PixelPoint(x: 301, y: 300)) == ColorRGBA8.white)
        #expect(context.history.steps.map(\.name) == ["New Image", "Paint Bucket"],
                "six touched tiles, one step")
        #expect(context.history.steps[1].icon == .paintBucket)
        context.navigateForTests { history, state in _ = history.undo(&state) }
        #expect(context.image.layers[0].surface == before,
                "undo restores every touched tile exactly")
        context.navigateForTests { history, state in _ = history.redo(&state) }
        #expect(context.image.layers[0].surface == after, "redo re-applies the exact result")
    }

    @Test func noOpClicksAddNoStep() {
        func check(_ label: String, _ context: FakeToolContext, _ event: ToolEvent,
                   names: [String] = ["New Image"]) {
            let generation = context.image.layers[0].surface.generation
            PaintBucketTool().mouseDown(event, context: context)
            #expect(context.history.steps.map(\.name) == names, "click \(label)")
            #expect(context.image.layers[0].surface.generation == generation,
                    "\(label) — generation unchanged")
        }
        // Color alpha 0.
        let transparent = FakeToolContext(background: .white)
        setAliased(transparent)
        transparent.colors = ColorSelection(primary: rgba(255, 0, 0, 0), secondary: .white)
        check("alpha 0", transparent, event(5.5, 5.5))
        // White on white with Normal.
        let sameColor = FakeToolContext(background: .white)
        setAliased(sameColor)
        sameColor.colors = ColorSelection(primary: .white, secondary: .black)
        check("white on white", sameColor, event(5.5, 5.5))
        // Fully clipped: the click lands where the selection's coverage is 0.
        let clipped = FakeToolContext(background: .white)
        setAliased(clipped)
        setSelection(clipped, pixelatedRect(clipped, PixelRect(x: 0, y: 0, width: 8, height: 64)))
        clipped.colors = ColorSelection(primary: red, secondary: blue)
        check("fully clipped", clipped, event(20.5, 5.5), names: ["New Image", "setup"])
    }

    @Test func offCanvasClickIsNoOp() {
        let locations: [(Double, Double)] = [(-1, 5), (20, 5), (5, 20), (.nan, 3),
                                             (.infinity, 3), (-.infinity, 3), (3, .nan),
                                             (3, .infinity)]
        for (x, y) in locations {
            let context = lineContext()
            context.colors = ColorSelection(primary: red, secondary: blue)
            let generation = context.image.layers[0].surface.generation
            let updatesBefore = context.imageUpdates
            PaintBucketTool().mouseDown(event(x, y), context: context)
            #expect(context.history.steps.map(\.name) == ["New Image"], "(\(x), \(y))")
            #expect(context.imageUpdates == updatesBefore, "(\(x), \(y))")
            #expect(context.image.layers[0].surface.generation == generation, "(\(x), \(y))")
        }
    }

    @Test func noActiveLayerIsNoOp() {
        let context = lineContext()
        context.colors = ColorSelection(primary: red, secondary: blue)
        // An active index that names no layer — the tool must bail before touching it.
        context.updateImage { image in image.activeLayerIndex = image.layers.count }
        let updatesAfterSetup = context.imageUpdates
        let generation = context.image.layers[0].surface.generation
        PaintBucketTool().mouseDown(event(3.5, 3.5), context: context)
        #expect(context.history.steps.map(\.name) == ["New Image"])
        #expect(context.imageUpdates == updatesAfterSetup)
        #expect(context.image.layers[0].surface.generation == generation)
    }

    @Test func cursorIsCrosshair() {
        let tool = PaintBucketTool()
        let context = lineContext()
        setAliased(context)
        context.colors = ColorSelection(primary: red, secondary: blue)
        #expect(tool.cursor(at: CGPoint(x: 5, y: 5), modifiers: []) == .crosshair)
        #expect(tool.cursor(at: nil, modifiers: []) == .arrow)
        tool.mouseDown(event(3.5, 3.5), context: context)
        #expect(tool.hasPendingEdit == false)
        #expect(tool.keyDown(keyEvent(.escape), context: context) == false)
        #expect(tool.keyDown(keyEvent(.returnKey), context: context) == false)
        #expect(context.history.steps.map(\.name) == ["New Image", "Paint Bucket"])
    }

    @Test func unallocatedTilesAllocatedOnlyWhenWritten() {
        let context = FakeToolContext(size: PixelSize(width: 600, height: 600))
        setAliased(context)
        setSelection(context, pixelatedRect(context, PixelRect(x: 10, y: 10,
                                                               width: 20, height: 20)))
        context.colors = ColorSelection(primary: red, secondary: blue)
        PaintBucketTool().mouseDown(event(15.5, 15.5), context: context)
        let surface = context.image.layers[0].surface
        #expect(surface.allocatedTileCoordinates == [TileCoordinate(column: 0, row: 0)])
        for y in 0..<40 {
            for x in 0..<40 {
                let inside = (10...29).contains(x) && (10...29).contains(y)
                #expect(surface.pixel(at: PixelPoint(x: x, y: y))
                            == (inside ? red : ColorRGBA8.clear), "(\(x), \(y))")
            }
        }
    }

    // MARK: Property test

    /// 200 seeded random fills: every resulting pixel equals the independent oracle
    /// (flood wiring + naive 3×3 feather + restated 0009 compose), so a feathered fill
    /// never changes a pixel whose coverage is 0; undo restores the exact tiles and redo
    /// re-applies the exact result.
    @Test func undoRedoProperty() {
        func mul255(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((UInt32(a) * UInt32(b) + 127) / 255)
        }
        func feather(_ k: Int) -> UInt8 { UInt8((510 * k + 9) / 18) }
        func normalCompose(dst: ColorRGBA8, color: ColorRGBA8, coverage: UInt8) -> ColorRGBA8 {
            let sa = (Int(color.alpha) * Int(coverage) + 127) / 255
            guard sa > 0 else { return dst }
            let da = Int(dst.alpha)
            let fa = sa * 255 + da * (255 - sa)
            let halfFa = fa / 2
            let inverse = 255 - sa
            func channel(_ sc: Int, _ dc: Int) -> UInt8 {
                UInt8((sc * sa * 255 + dc * da * inverse + halfFa) / fa)
            }
            return ColorRGBA8(red: channel(Int(color.red), Int(dst.red)),
                              green: channel(Int(color.green), Int(dst.green)),
                              blue: channel(Int(color.blue), Int(dst.blue)),
                              alpha: UInt8((fa + 127) / 255))
        }

        var rng = SeededRandom(seed: 0x0017_0017_0000_0050)
        let size = PixelSize(width: 64, height: 64)
        for iteration in 0..<200 {
            var palette: [ColorRGBA8] = []
            for _ in 0..<3 {
                palette.append(rgba(Int(rng.byte()), Int(rng.byte()),
                                    Int(rng.byte()), Int(rng.byte())))
            }
            var surface = TiledSurface(size: size)
            for y in 0..<64 {
                for x in 0..<64 {
                    surface.setPixel(palette[rng.int(in: 0...2)], at: PixelPoint(x: x, y: y))
                }
            }
            let context = FakeToolContext(image: LayeredImage(surface: surface))
            let fillMode: PaintBucketFillMode = rng.int(in: 0...1) == 0 ? .similarColor : .selection
            let floodMode: FloodMode = rng.int(in: 0...1) == 0 ? .contiguous : .global
            let tolerancePercent = rng.int(in: 0...100)
            let antialiasing = rng.int(in: 0...1) == 0
            context.memoryOptions.setValue(fillMode, for: PaintBucketOptions.fillModeKey)
            context.memoryOptions.setValue(floodMode,
                                           for: FloodToolOptions.floodMode(for: .paintBucket))
            context.memoryOptions.setValue(tolerancePercent,
                                           for: FloodToolOptions.tolerance(for: .paintBucket))
            context.memoryOptions.setValue(antialiasing,
                                           for: PaintBucketOptions.antialiasingKey)
            let primary = rgba(Int(rng.byte()), Int(rng.byte()), Int(rng.byte()), Int(rng.byte()))
            let secondary = rgba(Int(rng.byte()), Int(rng.byte()), Int(rng.byte()),
                                 Int(rng.byte()))
            context.colors = ColorSelection(primary: primary, secondary: secondary)
            let button: ToolMouseButton = rng.int(in: 0...1) == 0 ? .primary : .secondary
            let modifiers: ToolModifiers = rng.int(in: 0...4) == 0 ? [.shift] : []
            let color = button == .secondary || modifiers.contains(.control)
                ? secondary : primary

            var selection: Selection?
            if rng.int(in: 0...2) == 0 {
                let x = rng.int(in: 0...60)
                let y = rng.int(in: 0...60)
                let width = rng.int(in: 1...(64 - x))
                let height = rng.int(in: 1...(64 - y))
                selection = pixelatedRect(context, PixelRect(x: x, y: y,
                                                             width: width, height: height))
                setSelection(context, selection)
            }

            let seed = PixelPoint(x: rng.int(in: 0...63), y: rng.int(in: 0...63))
            let before = context.image.layers[0].surface
            let stepsBefore = context.history.steps.count
            PaintBucketTool().mouseDown(event(Double(seed.x) + 0.5, Double(seed.y) + 0.5,
                                              button: button, modifiers: modifiers),
                                        context: context)
            let after = context.image.layers[0].surface
            let clip = selection?.mask

            // The naive oracle: coverage from the flood (or the mask for Fill = Selection),
            // the 3×3 feather counted by hand, the clip, then the restated compose.
            var outsideClip = false
            if let clip, clip.coverage(x: seed.x, y: seed.y) == 0 { outsideClip = true }
            var region: FloodFillStencil?
            if !outsideClip, fillMode == .similarColor {
                let mode = modifiers.contains(.shift) ? FloodMode.global : floodMode
                region = FloodFill.fill(FloodFillSource.layer(before), from: seed,
                                        tolerance: FloodTolerance(percent: tolerancePercent),
                                        mode: mode,
                                        limit: selection.map { FloodFillStencil.from($0.mask) })
                if region?.isEmpty == true { region = nil }
            }

            for y in 0..<64 {
                for x in 0..<64 {
                    let point = PixelPoint(x: x, y: y)
                    var coverage: UInt8 = 0
                    if !outsideClip {
                        if fillMode == .selection {
                            coverage = clip?.coverage(x: x, y: y) ?? 255
                        } else if let region {
                            if region.contains(point) {
                                coverage = 255
                            } else if antialiasing {
                                var neighbours = 0
                                for dy in -1...1 {
                                    for dx in -1...1 where dx != 0 || dy != 0 {
                                        if region.contains(PixelPoint(x: x + dx, y: y + dy)) {
                                            neighbours += 1
                                        }
                                    }
                                }
                                coverage = feather(neighbours)
                            }
                        }
                    }
                    let effective = mul255(coverage, clip?.coverage(x: x, y: y) ?? 255)
                    let sourceAlpha = mul255(color.alpha, effective)
                    let dst = before.pixel(at: point)
                    let want = sourceAlpha == 0
                        ? dst
                        : normalCompose(dst: dst, color: color, coverage: effective)
                    // A feathered fill never changes a pixel whose effective coverage
                    // is 0; every other pixel equals the restated compose exactly.
                    #expect(after.pixel(at: point) == want,
                            "iteration \(iteration) (\(x), \(y)) fillMode \(fillMode.rawValue) flood \(floodMode.rawValue) tolerance \(tolerancePercent) aa \(antialiasing) seed (\(seed.x), \(seed.y))")
                }
            }

            if context.history.steps.count > stepsBefore {
                context.navigateForTests { history, state in _ = history.undo(&state) }
                #expect(context.image.layers[0].surface == before,
                        "iteration \(iteration) undo restores the exact tiles")
                context.navigateForTests { history, state in _ = history.redo(&state) }
                #expect(context.image.layers[0].surface == after,
                        "iteration \(iteration) redo re-applies the exact result")
            } else {
                #expect(after == before, "iteration \(iteration) no-op click wrote pixels")
            }
        }
    }
}
