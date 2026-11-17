import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// Cut/Copy/Paste end to end behind the real `UndoBridge` + `HistoryStack` + the real
/// 0020 tool, with a `ClipboardController` on a private pasteboard (spec 0021 *Test
/// plan*, integration). Windows are covered by `ClipboardWindowIntegrationTests`; this
/// suite exercises the shared static command paths the window controller calls.
@MainActor
struct PasteIntegrationTests {
    private func red(_ x: Int = 0, _ y: Int = 0) -> ColorRGBA8 {
        ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
    }

    /// A 400×300 white document whose fake transform shows the whole canvas
    /// (origin (0, 0) placement), plus the 0020 dispatcher wiring (commands commit
    /// floating pixels first, 0020 item 9) and a private-pasteboard clipboard.
    @MainActor
    private struct Fixture {
        var context: BridgeToolContext
        var dispatcher: ToolDispatcher
        var tool: MoveSelectedPixelsTool
        var clipboard: ClipboardController
        var pasteboard: NSPasteboard
        let alerts = RecordingAlertPresenter()

        func finish() { pasteboard.releaseGlobally() }

        var bridge: UndoBridge { context.bridge }

        /// The window controller's Paste action, minus the window: the shared static
        /// path with the fake's visible rect and secondary color.
        func paste(expandChoice: PasteCanvasChoice? = nil) {
            let prompt = expandChoice.map { ScriptedPasteExpandPrompt(choice: $0) }
            DocumentWindowController.performPaste(
                bridge: bridge, clipboard: clipboard,
                visibleCanvasRect: context.transform.visibleCanvasRect,
                prompt: prompt, alerts: alerts, limits: .standard,
                background: ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255))
            // The controller's post-step policy (0020 item 10): floating pixels select
            // their tool.
            if let id = FloatingPixelsPolicy.toolToActivate(
                hasFloatingPixels: bridge.state.floatingPixels != nil,
                activeTool: dispatcher.activeToolID) {
                dispatcher.selectTool(id)
            }
        }

        func copy() {
            DocumentWindowController.performCopy(bridge: bridge, clipboard: clipboard,
                                                 alerts: alerts)
        }

        func event(_ x: Double, _ y: Double, t: Double = 1) -> ToolEvent {
            let location = CGPoint(x: x, y: y)
            return ToolEvent(location: location,
                             viewLocation: context.transform.canvasToView(location),
                             button: .primary, modifiers: [],
                             clickCount: 1, pressure: 1, timestamp: t)
        }

        func drag(from: CGPoint, to: CGPoint) {
            tool.mouseDown(event(from.x, from.y, t: 1), context: context)
            tool.mouseDragged(event(to.x, to.y, t: 2), context: context)
            tool.mouseUp(event(to.x, to.y, t: 3), context: context)
        }

        var names: [String] { bridge.history.steps.map(\.name) }
        var layer: TiledSurface { bridge.state.image.layers[0].surface }
    }

    private func fixture(size: PixelSize, base: HistoryBaseStep = .openImage,
                         image: LayeredImage? = nil) -> Fixture {
        let context = BridgeToolContext(image: image ?? LayeredImage.blank(size: size, fill: .white),
                                        base: base)
        context.nav.transform = CanvasTransform(
            imageSize: size, viewSize: CGSize(width: CGFloat(size.width) * 2,
                                              height: CGFloat(size.height) * 2),
            backingScale: 1, zoom: 1,
            center: CGPoint(x: Double(size.width) / 2, y: Double(size.height) / 2))
        let dispatcher = ToolDispatcher(registry: .standard())
        dispatcher.setContext(context)
        context.bridge.prepareForNavigation = { [weak dispatcher, weak context] in
            guard let dispatcher, let context else { return }
            dispatcher.resolvePendingEdit(for: context.bridge.pendingEditReason)
        }
        let pasteboard = makePrivatePasteboard()
        return Fixture(context: context, dispatcher: dispatcher,
                       tool: MoveSelectedPixelsTool(),
                       clipboard: ClipboardController(pasteboard: pasteboard),
                       pasteboard: pasteboard)
    }

    /// Puts an opaque `color` image on the fixture's pasteboard as PNG (dpi 72).
    private func putOnClipboard(_ f: Fixture, width: Int, height: Int,
                                color: ColorRGBA8 = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)) throws {
        let surface = TestImages.surface(width: width, height: height) { _, _ in color }
        let (png, tiff) = try ClipboardImageCodec.encode(surface, dpi: 72)
        f.clipboard.pasteboard.setData(png, forType: .png)
        f.clipboard.pasteboard.setData(tiff, forType: .tiff)
    }

    /// Activates Move Selected Pixels exactly like the window's policy after the paste.
    private func activateMoveTool(_ f: Fixture) {
        f.tool.activate(context: f.context)
    }

    // MARK: - Copy

    @Test func copyWritesBothTypes() throws {
        let f = fixture(size: PixelSize(width: 400, height: 300))
        defer { f.finish() }
        f.copy()
        #expect(types(of: f.pasteboard) == [ClipboardImageCodec.pngType, ClipboardImageCodec.tiffType])
        #expect(f.clipboard.canPaste == true)
        let read = try #require(readPNG(from: f.pasteboard))
        #expect(read.width == 400 && read.height == 300)
        let decoded = try ImageDecoder.decode(f.pasteboard.data(forType: .png)!, limits: .standard)
        TestImages.expectPixels(decoded.surface, match: { _, _ in .white })
        #expect(f.names == ["Open Image"], "Copy never records a step")
    }

    // MARK: - Paste: floating pixels, undo/redo, Escape, move

    @Test func pasteCreatesFloatingPixels() throws {
        let f = fixture(size: PixelSize(width: 400, height: 300))
        defer { f.finish() }
        try putOnClipboard(f, width: 50, height: 40)
        f.paste()
        #expect(f.names == ["Open Image", "Paste"])
        #expect(f.bridge.state.selection?.bounds == PixelRect(x: 0, y: 0, width: 50, height: 40))
        let floating = try #require(f.bridge.state.floatingPixels)
        #expect(floating.sourceRect == PixelRect(x: 0, y: 0, width: 50, height: 40))
        TestImages.expectPixels(floating.underlay, match: { _, _ in .white },
                                "the underlay keeps the pre-paste layer")
        TestImages.expectPixels(f.layer, match: { x, y in
            x < 50 && y < 40 ? self.red() : .white
        }, "the live layer shows the pasted pixels")
        #expect(f.dispatcher.activeToolID == .moveSelectedPixels,
                "FloatingPixelsPolicy activates Move Selected Pixels")
    }

    @Test func pasteUndoRedo() throws {
        let f = fixture(size: PixelSize(width: 400, height: 300))
        defer { f.finish() }
        try putOnClipboard(f, width: 50, height: 40)
        f.paste()
        let floating = try #require(f.bridge.state.floatingPixels)

        f.bridge.undo()
        TestImages.expectPixels(f.layer, match: { _, _ in .white })
        #expect(f.bridge.state.selection == nil)
        #expect(f.bridge.state.floatingPixels == nil)
        #expect(f.bridge.history.currentIndex == 0, "history at \"Open Image\"")

        f.bridge.redo()
        #expect(f.bridge.state.floatingPixels == floating, "the exact floating paste returns")
        TestImages.expectPixels(f.layer, match: { x, y in
            x < 50 && y < 40 ? self.red() : .white
        })
    }

    @Test func pasteEscapeCancels() throws {
        let f = fixture(size: PixelSize(width: 400, height: 300))
        defer { f.finish() }
        try putOnClipboard(f, width: 50, height: 40)
        f.paste()
        activateMoveTool(f)
        f.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 20, y: 20))
        #expect(f.names == ["Open Image", "Paste", "Move Pixels"])

        // Escape cancels the whole floating session (0020): back before "Paste".
        #expect(f.tool.keyDown(ToolKeyEvent(key: .escape, characters: "", modifiers: [],
                                            isRepeat: false), context: f.context))
        #expect(f.bridge.history.currentIndex == 0, "current step is \"Open Image\"")
        #expect(f.names == ["Open Image", "Paste", "Move Pixels"],
                "the pasted steps stay redoable")
        TestImages.expectPixels(f.layer, match: { _, _ in .white })
        #expect(f.bridge.state.selection == nil)
        #expect(f.bridge.state.floatingPixels == nil)
        // Two redo steps.
        f.bridge.redo()
        #expect(f.bridge.history.steps[f.bridge.history.currentIndex].name == "Paste")
        f.bridge.redo()
        #expect(f.bridge.history.steps[f.bridge.history.currentIndex].name == "Move Pixels")
    }

    @Test func pasteMoveCommit() throws {
        let f = fixture(size: PixelSize(width: 400, height: 300))
        defer { f.finish() }
        try putOnClipboard(f, width: 50, height: 40)
        f.paste()
        activateMoveTool(f)
        f.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60))
        f.tool.commit(context: f.context)  // Return: "Finish Pixels"
        #expect(f.names == ["Open Image", "Paste", "Move Pixels", "Finish Pixels"])
        TestImages.expectPixels(f.layer, match: { x, y in
            (100..<150).contains(x) && (50..<90).contains(y) ? self.red() : .white
        }, "red exactly at the moved rect; the original paste spot was never erased")
        #expect(f.bridge.state.selection?.bounds == PixelRect(x: 100, y: 50, width: 50, height: 40))
    }

    @Test func secondDragAfterPasteLeavesNoResidue() throws {
        // Regression (the 0020 gap fixed with 0021): the first move of a SECOND gesture
        // into a live floating session must re-render the previously drawn destination,
        // or the first drag's block stays burnt into the layer. Session started by
        // Paste (external to the tool), dragged twice, still live after both.
        let f = fixture(size: PixelSize(width: 400, height: 300))
        defer { f.finish() }
        try putOnClipboard(f, width: 40, height: 30)
        f.paste()
        activateMoveTool(f)
        f.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 10))  // to (50, 0)
        #expect(f.names == ["Open Image", "Paste", "Move Pixels"])
        f.drag(from: CGPoint(x: 70, y: 20), to: CGPoint(x: 70, y: 60))  // then (50, 40)
        #expect(f.names == ["Open Image", "Paste", "Move Pixels", "Move Pixels"])
        TestImages.expectPixels(f.layer, match: { x, y in
            (50..<90).contains(x) && (40..<70).contains(y) ? self.red() : .white
        }, "the first drag's destination (50..<90, 0..<30) was re-rendered, no residue")
        f.tool.commit(context: f.context)
        #expect(f.names.last == "Finish Pixels")
    }

    // MARK: - E-6 expand / keep

    @Test func expandIsPartOfPasteStep() throws {
        let f = fixture(size: PixelSize(width: 300, height: 200))
        defer { f.finish() }
        let original = f.bridge.state.image
        try putOnClipboard(f, width: 400, height: 250)
        f.paste(expandChoice: .expandCanvas)
        #expect(f.bridge.state.image.size == PixelSize(width: 400, height: 250))
        #expect(f.names == ["Open Image", "Paste"], "one step carries the expansion")

        activateMoveTool(f)
        f.tool.commit(context: f.context)
        TestImages.expectPixels(f.layer, match: { _, _ in self.red() },
                                "the whole expanded canvas is covered by the paste")
        f.bridge.undo()  // "Finish Pixels"
        f.bridge.undo()  // "Paste" (snapshot reverts the canvas too)
        #expect(f.bridge.state.image.size == PixelSize(width: 300, height: 200))
        #expect(f.bridge.state.image == original)
        #expect(f.bridge.state.selection == nil)
        #expect(f.bridge.state.floatingPixels == nil)
    }

    @Test func keepCanvasSizeClipsOnCommit() throws {
        let f = fixture(size: PixelSize(width: 300, height: 200))
        defer { f.finish() }
        try putOnClipboard(f, width: 400, height: 250)
        f.paste(expandChoice: .keepCanvasSize)
        #expect(f.bridge.state.image.size == PixelSize(width: 300, height: 200))
        #expect(f.bridge.state.selection?.bounds == PixelRect(x: 0, y: 0, width: 300, height: 200),
                "the outline clips to the canvas")
        activateMoveTool(f)
        f.tool.commit(context: f.context)
        TestImages.expectPixels(f.layer, match: { _, _ in self.red() }, "every pixel red")
        #expect(f.layer.allocatedTileCount <= 2,
                "no tile was allocated beyond the 300×200 canvas")
    }

    // MARK: - Paste into New Image (step level; the document path is the window suite)

    @Test func pasteIntoNewImageIgnoresClipboardDPI() throws {
        let size = PixelSize(width: 123, height: 45)
        let pattern: (Int, Int) -> ColorRGBA8 = { x, y in
            ColorRGBA8(red: UInt8((x * 3) % 256), green: UInt8((y * 5) % 256),
                       blue: 99, alpha: 255)
        }
        let surface = TestImages.surface(width: size.width, height: size.height, pattern)
        // "72-DPI pHYs" clipboard PNG — the DPI must not reach the new document.
        let (png, _) = try ClipboardImageCodec.encode(surface, dpi: 72)
        let f = fixture(size: size, base: .newImage,
                        image: NewImageRequest(size: size, dpi: NewImageDefaults.fallbackDPI).makeImage())
        defer { f.finish() }
        f.clipboard.pasteboard.setData(png, forType: .png)

        f.paste()
        #expect(f.names == ["New Image", "Paste"])
        #expect(f.bridge.state.image.size == size)
        #expect(f.bridge.state.image.dpi == 96, "the clipboard DPI is ignored (D-30)")
        activateMoveTool(f)
        f.tool.commit(context: f.context)
        TestImages.expectPixels(f.layer, match: pattern,
                                "the committed layer equals the clipboard pattern")
    }

    // MARK: - Sequencing

    @Test func pasteWithPendingFloatingCommitsFirst() throws {
        let f = fixture(size: PixelSize(width: 400, height: 300))
        defer { f.finish() }
        try putOnClipboard(f, width: 50, height: 40)
        f.paste()
        activateMoveTool(f)
        f.paste()  // the pending floating session records "Finish Pixels" first
        #expect(f.names == ["Open Image", "Paste", "Finish Pixels", "Paste"])
    }

    // MARK: - Performance sanity (gross-regression gate only)

    @Test func pasteLargeImageIsReasonable() throws {
        let size = PixelSize(width: 4000, height: 3000)
        let surface = TestImages.surface(width: size.width, height: size.height) { x, y in
            ColorRGBA8(red: UInt8(truncatingIfNeeded: x &* 7 &+ y),
                       green: UInt8(truncatingIfNeeded: y &* 3), blue: 12, alpha: 255)
        }
        let (png, _) = try ClipboardImageCodec.encode(surface, dpi: 96)
        let f = fixture(size: size)
        defer { f.finish() }
        f.clipboard.pasteboard.setData(png, forType: .png)
        // Read + full paste through the real bridge, timed on Debug (NF gate: gross
        // regression only — report the measured time in the spec's Verification status).
        let elapsed = ContinuousClock().measure { f.paste() }
        #expect(f.names == ["Open Image", "Paste"])
        #expect(elapsed < .seconds(3), "read + paste of a 4000×3000 PNG took \(elapsed)")
    }

    // MARK: - Cut → Paste round trip

    @Test func cutThenPasteRoundTrip() throws {
        let pattern: (Int, Int) -> ColorRGBA8 = { x, y in
            ColorRGBA8(red: UInt8(x % 251), green: UInt8(y % 197), blue: 77, alpha: 255)
        }
        let image = LayeredImage(surface: TestImages.surface(width: 100, height: 100) { x, y in
            pattern(x, y)
        })
        let f = fixture(size: PixelSize(width: 100, height: 100), image: image)
        defer { f.finish() }
        f.context.performHistory(SelectionHistoryItem(
            name: "setup", icon: .generic, before: nil,
            after: Selection(rect: CGRect(x: 20, y: 20, width: 30, height: 30),
                             canvasSize: PixelSize(width: 100, height: 100))))
        // Cut: clipboard written first, then the history step (0021 item 7).
        DocumentWindowController.performCut(bridge: f.bridge, clipboard: f.clipboard,
                                            alerts: f.alerts)
        #expect(f.alerts.alerts.isEmpty)
        #expect(f.names == ["Open Image", "setup", "Cut"])
        f.paste()
        activateMoveTool(f)
        f.tool.commit(context: f.context)  // Return: "Finish Pixels"
        #expect(f.names == ["Open Image", "setup", "Cut", "Paste", "Finish Pixels"])
        let layer = f.layer
        for y in 0..<30 {
            for x in 0..<30 {
                #expect(layer.pixel(at: PixelPoint(x: x, y: y)) == pattern(x + 20, y + 20),
                        "pasted block at (\(x), \(y)) holds the original (20 + \(x), 20 + \(y))")
            }
        }
        #expect(layer.pixel(at: PixelPoint(x: 35, y: 35)) == ColorRGBA8(red: 0, green: 0,
                                                                        blue: 0, alpha: 0),
                "the cut area outside the pasted rect stays erased")
        #expect(layer.pixel(at: PixelPoint(x: 49, y: 49)) == ColorRGBA8(red: 0, green: 0,
                                                                        blue: 0, alpha: 0))
        #expect(layer.pixel(at: PixelPoint(x: 50, y: 50)) == pattern(50, 50),
                "outside the cut the layer is untouched")
    }
}
