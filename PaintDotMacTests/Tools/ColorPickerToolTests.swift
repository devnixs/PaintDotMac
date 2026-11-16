import CoreGraphics
import Testing

@testable import PaintDotMac

/// `ColorPickerTool` through `FakeToolContext` (spec 0012 *Test plan*): slot choice
/// (TOOL-A), floor mapping, live drag, ⌘-forced Image sampling, sampling-size option,
/// After Click switching, the no-history-step rule, cursor, and TOOL-C persistence.
@MainActor
struct ColorPickerToolTests {
    private let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
    private let green = ColorRGBA8(red: 0, green: 255, blue: 0, alpha: 255)
    private let blue = ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255)

    private func event(_ location: CGPoint, button: ToolMouseButton = .primary,
                       modifiers: ToolModifiers = []) -> ToolEvent {
        ToolEvent(location: location, viewLocation: location, button: button,
                  modifiers: modifiers, clickCount: 1, pressure: 1, timestamp: 0)
    }

    private func context(image: LayeredImage) -> FakeToolContext {
        FakeToolContext(image: image)
    }

    /// 64×64: red for `x < 21`, green for `21 ≤ x < 42`, blue for `x ≥ 42`, opaque.
    private func columnsImage() -> LayeredImage {
        let surface = TestImages.surface(width: 64, height: 64) { x, _ in
            x < 21 ? red : (x < 42 ? green : blue)
        }
        return LayeredImage(surface: surface)
    }

    /// 8×8: opaque red for `x < 5`, opaque green for `x ≥ 5`.
    private func splitImage() -> LayeredImage {
        let surface = TestImages.surface(width: 8, height: 8) { x, _ in
            x < 5 ? red : green
        }
        return LayeredImage(surface: surface)
    }

    /// 3×3: 4 opaque red pixels at the top-left, the rest clear.
    private func fourRedPixels() -> LayeredImage {
        let surface = TestImages.surface(width: 3, height: 3) { x, y in
            x < 2 && y < 2 ? red : .clear
        }
        return LayeredImage(surface: surface)
    }

    /// Bottom opaque red, active top `(0,0,255,128)` — Layer gives `(0,0,255,128)`,
    /// Image gives `(127,0,128,255)` (hand calc in `CPUCompositorTests`).
    private func twoLayerImage() -> LayeredImage {
        let size = PixelSize(width: 8, height: 8)
        let bottom = Layer(name: "Bottom",
                           surface: TestImages.surface(width: 8, height: 8) { _, _ in red })
        let top = Layer(name: "Top",
                        surface: TestImages.surface(width: 8, height: 8) { _, _ in
                            ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 128)
                        })
        return LayeredImage(size: size, layers: [bottom, top], activeLayerIndex: 1)
    }

    // MARK: - Slots (TOOL-A)

    @Test func leftClickSetsPrimaryOnly() {
        let context = context(image: columnsImage())
        let tool = ColorPickerTool()
        tool.mouseDown(event(CGPoint(x: 5.5, y: 5.5)), context: context)
        tool.mouseUp(event(CGPoint(x: 5.5, y: 5.5)), context: context)
        #expect(context.colors.primary == red)
        #expect(context.colors.secondary == .white, "the other color is unchanged")
        #expect(context.setColorCalls.map(\.slot) == [.primary, .primary])
        #expect(context.setColorCalls.allSatisfy { $0.color == red })
    }

    @Test func rightClickSetsSecondaryOnly() {
        let context = context(image: columnsImage())
        let tool = ColorPickerTool()
        tool.mouseDown(event(CGPoint(x: 50.5, y: 5.5), button: .secondary), context: context)
        tool.mouseUp(event(CGPoint(x: 50.5, y: 5.5), button: .secondary), context: context)
        #expect(context.colors.secondary == blue)
        #expect(context.colors.primary == .black, "the other color is unchanged")
    }

    @Test func clickAtFractionalPointUsesFloor() {
        let context = context(image: splitImage())
        let tool = ColorPickerTool()
        // (4.999, 0.2) → pixel (4, 0): red. A rounding mapping would give (5, ·) = green.
        tool.mouseDown(event(CGPoint(x: 4.999, y: 0.2)), context: context)
        #expect(context.colors.primary == red)
        // (-0.01, 0) → x = -1 → outside: nothing changes.
        let before = context.colors
        tool.mouseDown(event(CGPoint(x: -0.01, y: 0)), context: context)
        #expect(context.colors == before)
    }

    // MARK: - Live drag

    @Test func dragUpdatesLive() {
        let context = context(image: columnsImage())
        let tool = ColorPickerTool()
        tool.mouseDown(event(CGPoint(x: 5.5, y: 30)), context: context)
        #expect(context.colors.primary == red, "the down point picks immediately")
        tool.mouseDragged(event(CGPoint(x: 30.5, y: 30)), context: context)
        #expect(context.colors.primary == green, "the color follows the drag")
        tool.mouseUp(event(CGPoint(x: 50.5, y: 30)), context: context)
        #expect(context.colors.primary == blue, "the final color is the mouse-up point")
    }

    @Test func dragOutsideCanvasKeepsLastColor() {
        let context = context(image: columnsImage())
        let tool = ColorPickerTool()
        tool.mouseDown(event(CGPoint(x: 5.5, y: 30)), context: context)
        tool.mouseDragged(event(CGPoint(x: -50, y: -50)), context: context)
        tool.mouseUp(event(CGPoint(x: -50, y: -50)), context: context)
        #expect(context.colors.primary == red)
    }

    // MARK: - Modes

    @Test func commandClickSamplesImage() {
        let context = context(image: twoLayerImage())
        let tool = ColorPickerTool()
        tool.mouseDown(event(CGPoint(x: 4.5, y: 4.5)), context: context)
        #expect(context.colors.primary == ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 128),
                "plain click samples the active layer's raw pixel")
        tool.mouseUp(event(CGPoint(x: 4.5, y: 4.5), modifiers: [.command]), context: context)
        #expect(context.colors.primary
                    == ColorRGBA8(red: 127, green: 0, blue: 128, alpha: 255),
                "⌘ forces Image sampling (PRD §5.12: Paint.NET's Ctrl → ⌘)")
    }

    @Test func imageModeOptionIsHonored() {
        let context = context(image: twoLayerImage())
        context.memoryOptions.setValue("image", for: ColorPickerTool.samplingModeKey)
        let tool = ColorPickerTool()
        tool.mouseDown(event(CGPoint(x: 4.5, y: 4.5)), context: context)
        #expect(context.colors.primary
                    == ColorRGBA8(red: 127, green: 0, blue: 128, alpha: 255))
    }

    @Test func samplingSizeOptionIsUsed() {
        let context = context(image: fourRedPixels())
        context.memoryOptions.setValue(SamplingSize.region3, for: ColorPickerTool.samplingSizeKey)
        let tool = ColorPickerTool()
        tool.mouseDown(event(CGPoint(x: 1.5, y: 1.5)), context: context)
        // 4 of 9 pixels opaque red: alpha-weighted average → (255, 0, 0, 113).
        #expect(context.colors.primary == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 113))
    }

    // MARK: - Picking is not a history step

    @Test func pickingIsNotAHistoryStep() throws {
        let context = context(image: columnsImage())
        let imageBefore = context.image
        let generationsBefore = context.image.layers.map(\.surface.generation)
        let tool = ColorPickerTool()
        tool.mouseDown(event(CGPoint(x: 5.5, y: 30)), context: context)
        tool.mouseDragged(event(CGPoint(x: 30.5, y: 30)), context: context)
        tool.mouseUp(event(CGPoint(x: 50.5, y: 30)), context: context)
        #expect(context.history.steps.count == 1, "only the base step exists")
        #expect(context.history.currentIndex == 0)
        #expect(context.history.isAtSavedState, "the document stays unedited (0008)")
        #expect(context.image == imageBefore, "no pixel changed")
        #expect(context.image.layers.map(\.surface.generation) == generationsBefore)
        #expect(context.imageUpdates == 0, "updateImage was never called")
    }

    // MARK: - Cursor / pending edit

    @Test func cursorIsCrosshair() {
        let tool = ColorPickerTool()
        #expect(tool.cursor(at: CGPoint(x: 1, y: 1), modifiers: []) == .crosshair)
        #expect(tool.cursor(at: CGPoint(x: -5, y: 300), modifiers: [.command]) == .crosshair)
        #expect(tool.cursor(at: nil, modifiers: []) == .arrow)
        #expect(tool.hasPendingEdit == false, "before")
        let context = context(image: splitImage())
        tool.mouseDown(event(CGPoint(x: 1.5, y: 1.5)), context: context)
        #expect(tool.hasPendingEdit == false, "during")
        tool.mouseUp(event(CGPoint(x: 1.5, y: 1.5)), context: context)
        #expect(tool.hasPendingEdit == false, "after")
    }

    // MARK: - After click

    @Test func afterClickDoNotSwitch() {
        let context = context(image: columnsImage())
        context.previousToolID = .paintbrush
        let tool = ColorPickerTool()   // default: doNotSwitch
        tool.mouseDown(event(CGPoint(x: 5.5, y: 5)), context: context)
        tool.mouseUp(event(CGPoint(x: 5.5, y: 5)), context: context)
        #expect(context.activatedTools == [])
    }

    @Test func afterClickSwitchToPrevious() {
        let context = context(image: columnsImage())
        context.previousToolID = .paintbrush
        context.memoryOptions.setValue(ColorPickerAfterClick.switchToPreviousTool,
                                       for: ColorPickerTool.afterClickKey)
        let tool = ColorPickerTool()
        tool.mouseDown(event(CGPoint(x: 5.5, y: 5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 8.5, y: 5)), context: context)
        #expect(context.activatedTools == [], "the switch waits for mouse-up")
        tool.mouseUp(event(CGPoint(x: 12.5, y: 5)), context: context)
        #expect(context.activatedTools == [.paintbrush], "requested exactly once, on mouseUp")
    }

    @Test func afterClickSwitchToPencil() {
        let context = context(image: columnsImage())
        context.previousToolID = .paintbrush
        context.memoryOptions.setValue(ColorPickerAfterClick.switchToPencil,
                                       for: ColorPickerTool.afterClickKey)
        let tool = ColorPickerTool()
        tool.mouseDown(event(CGPoint(x: 5.5, y: 5)), context: context)
        tool.mouseDragged(event(CGPoint(x: 8.5, y: 5)), context: context)
        #expect(context.activatedTools == [])
        tool.mouseUp(event(CGPoint(x: 12.5, y: 5)), context: context)
        #expect(context.activatedTools == [.pencil])
    }

    @Test func afterClickWithoutPreviousDoesNotSwitch() {
        let context = context(image: columnsImage())
        context.previousToolID = nil
        context.memoryOptions.setValue(ColorPickerAfterClick.switchToPreviousTool,
                                       for: ColorPickerTool.afterClickKey)
        let tool = ColorPickerTool()
        tool.mouseDown(event(CGPoint(x: 5.5, y: 5)), context: context)
        tool.mouseUp(event(CGPoint(x: 5.5, y: 5)), context: context)
        #expect(context.activatedTools == [])
    }

    @Test func afterClickOutsideCanvasDoesNotSwitch() {
        let context = context(image: columnsImage())
        context.previousToolID = .paintbrush
        context.memoryOptions.setValue(ColorPickerAfterClick.switchToPencil,
                                       for: ColorPickerTool.afterClickKey)
        let tool = ColorPickerTool()
        tool.mouseDown(event(CGPoint(x: -5, y: -5)), context: context)
        tool.mouseUp(event(CGPoint(x: -5, y: -5)), context: context)
        #expect(context.activatedTools == [], "a gesture that never touched the canvas switches nothing")
        #expect(context.colors == .default, "and changes no color")
    }

    /// A previous tool that is the Color Picker itself behaves as "no previous tool".
    @Test func previousToolIsColorPickerDoesNotSwitch() {
        let context = context(image: columnsImage())
        context.previousToolID = .colorPicker
        context.memoryOptions.setValue(ColorPickerAfterClick.switchToPreviousTool,
                                       for: ColorPickerTool.afterClickKey)
        let tool = ColorPickerTool()
        tool.mouseDown(event(CGPoint(x: 5.5, y: 5)), context: context)
        tool.mouseUp(event(CGPoint(x: 5.5, y: 5)), context: context)
        #expect(context.activatedTools == [])
    }

    // MARK: - Options (TOOL-C, PRD D-28)

    @Test func optionsPersistAndDefault() throws {
        let context = context(image: splitImage())
        // Fresh store → the PRD D-28 defaults.
        #expect(context.memoryOptions.value(ColorPickerTool.samplingSizeKey) == .singlePixel)
        #expect(context.memoryOptions.value(ColorPickerTool.samplingModeKey) == "layer")
        #expect(context.memoryOptions.value(ColorPickerTool.afterClickKey) == .doNotSwitch)

        // Setting each persists under `tool.colorPicker.<option>` with the stored raw value.
        context.memoryOptions.setValue(SamplingSize.region11, for: ColorPickerTool.samplingSizeKey)
        context.memoryOptions.setValue("image", for: ColorPickerTool.samplingModeKey)
        context.memoryOptions.setValue(ColorPickerAfterClick.switchToPencil,
                                       for: ColorPickerTool.afterClickKey)
        #expect(context.memoryOptions.storedValue(forKey: "tool.colorPicker.samplingSize") as? Int == 11)
        #expect(context.memoryOptions.storedValue(forKey: "tool.colorPicker.samplingMode") as? String == "image")
        #expect(context.memoryOptions.storedValue(forKey: "tool.colorPicker.afterClick") as? String == "switchToPencil")

        // A new tool instance reads them back: size 11 averages (100×100 red/white strip),
        // mode image reads the composite, after click switches to the Pencil.
        let surface = TestImages.surface(width: 100, height: 100) { x, _ in
            x < 5 ? red : .white
        }
        let context2 = FakeToolContext(image: LayeredImage(surface: surface))
        context2.memoryOptions.setStoredValue(11, forKey: "tool.colorPicker.samplingSize")
        context2.memoryOptions.setStoredValue("layer", forKey: "tool.colorPicker.samplingMode")
        context2.previousToolID = .paintbrush
        context2.memoryOptions.setStoredValue("switchToPencil", forKey: "tool.colorPicker.afterClick")
        let tool = ColorPickerTool()
        tool.mouseDown(event(CGPoint(x: 4.5, y: 4.5)), context: context2)
        // Single pixel would be pure red; the sampling square (x −1…9, y −1…9, clipped
        // to the 10×10 corner) is half red, half white: S_a = 100·255 = 25500,
        // S_G = 50·255·255 = 3251250 → (2·3251250 + 25500)/51000 = 128; A = 255.
        #expect(tool.id == .colorPicker)
        tool.mouseUp(event(CGPoint(x: 4.5, y: 4.5)), context: context2)
        #expect(context2.colors.primary == ColorRGBA8(red: 255, green: 128, blue: 128, alpha: 255))
        #expect(context2.activatedTools == [.pencil])
    }

    @Test func invalidStoredOptionsFallBack() {
        // Bad raw values → the defaults: size 7 → Single pixel, mode "foo" → Layer,
        // afterClick "" → Do not switch tool.
        let context = context(image: fourRedPixels())
        context.memoryOptions.setStoredValue(7, forKey: "tool.colorPicker.samplingSize")
        context.memoryOptions.setStoredValue("foo", forKey: "tool.colorPicker.samplingMode")
        context.memoryOptions.setStoredValue("", forKey: "tool.colorPicker.afterClick")
        context.previousToolID = .paintbrush
        let tool = ColorPickerTool()
        // Size fell back to Single pixel: the center pixel (1,1) is red, not the average.
        tool.mouseDown(event(CGPoint(x: 1.5, y: 1.5)), context: context)
        #expect(context.colors.primary == red)
        tool.mouseUp(event(CGPoint(x: 1.5, y: 1.5)), context: context)
        #expect(context.activatedTools == [], "afterClick '' fell back to Do not switch tool")

        // Mode "foo" falls back to Layer: the raw top-layer pixel, not the composite.
        let layeredContext = self.context(image: twoLayerImage())
        layeredContext.memoryOptions.setStoredValue("foo", forKey: "tool.colorPicker.samplingMode")
        let tool2 = ColorPickerTool()
        tool2.mouseDown(event(CGPoint(x: 4.5, y: 4.5)), context: layeredContext)
        #expect(layeredContext.colors.primary
                    == ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 128))
    }

    @Test func identityAndDescriptorWiring() {
        let tool = ColorPickerTool()
        #expect(tool.id == .colorPicker)
        #expect(tool.id.rawValue == "colorPicker")
        #expect(tool.displayName == "Color Picker")
        #expect(tool.shortcutKey == "k")
    }
}
