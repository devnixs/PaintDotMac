import AppKit
import Testing

@testable import PaintDotMac

/// The Colors panel, headless (spec 0007, PRD §5.10 C-1/C-2, D-20, D-31): the panel's
/// accessibility surface, the swap/reset buttons, X/D/C through the router's one entry point, the
/// hex and numeric boxes, the wheel's pointer events, and `More »`/`« Less`. Nothing is ever
/// ordered on screen; `ColorsPanelHarness` owns the throwaway `AppModel` suite.
@MainActor
@Suite(.serialized)
struct ColorsPanelIntegrationTests {
    private func blue() -> ColorRGBA8 { ColorRGBA8(red: 51, green: 102, blue: 204, alpha: 255) }

    private func finish(_ harness: ColorsPanelHarness) {
        harness.dispose()
        HeadlessAssertions.noVisibleWindows()
    }

    // MARK: - C-1: slots, swap, reset

    @Test func swatchesAndButtons() throws {
        let harness = try ColorsPanelHarness(primary: blue(),
                                            secondary: ColorRGBA8(red: 229, green: 136, blue: 34))
        defer { finish(harness) }
        let ids = harness.identifierSet()
        for id in ["colorsPanel", "colors.primary", "colors.secondary", "colors.wheel",
                   "colors.swap", "colors.reset", "colors.more"] {
            #expect(ids.contains(id), "missing \(id): \(ids)")
        }
        #expect(try harness.accessibilityValue("colors.primary") == "#3366CCFF")
        #expect(try harness.accessibilityValue("colors.secondary") == "#E58822FF")
        // Primary is active on launch, so it carries the selection (the heavy outline).
        #expect(try harness.isSelected("colors.primary"))
        #expect(!(try harness.isSelected("colors.secondary")))

        try harness.pressButton("colors.swap")
        #expect(harness.model.colors.primary == ColorRGBA8(red: 229, green: 136, blue: 34))
        #expect(harness.model.colors.secondary == blue())
        #expect(harness.model.activeColorSlot == .primary, "X never moves the outline")

        try harness.pressButton("colors.reset")
        #expect(harness.model.colors == .default)

        // Clicking the other swatch installs it as the active slot.
        try harness.pressButton("colors.secondary")
        #expect(harness.model.activeColorSlot == .secondary)
        #expect(try harness.isSelected("colors.secondary"))
    }

    @Test func colorKeysRunThroughTheRouter() throws {
        let harness = try ColorsPanelHarness(primary: blue(),
                                            secondary: ColorRGBA8(red: 229, green: 136, blue: 34))
        defer { finish(harness) }
        let before = harness.model.colors

        #expect(harness.shortcut("c"))
        #expect(harness.model.activeColorSlot == .secondary)
        #expect(harness.model.colors == before, "C changes no color (D-31)")

        #expect(harness.shortcut("x"))
        #expect(harness.model.colors.primary == before.secondary)
        #expect(harness.model.colors.secondary == before.primary)

        #expect(harness.shortcut("d"))
        #expect(harness.model.colors == .default)
        #expect(harness.model.activeColorSlot == .secondary, "D keeps the active slot")

        // A modifier means it was not the single-key command (⌘X is Cut's menu item).
        let afterReset = harness.model.colors
        #expect(!harness.shortcut("x", modifiers: [.command]))
        #expect(!harness.shortcut("d", modifiers: [.option]))
        #expect(harness.model.colors == afterReset)
    }

    @Test func colorKeysFollowTheKeyWindow() throws {
        let harness = try ColorsPanelHarness(primary: blue())
        defer { finish(harness) }
        // The Colors panel's own window is key (the harness window carries its identifier).
        #expect(harness.shortcut("x", in: harness.window))
        // So is a Tools panel window.
        let tools = harness.makeKeyWindow(identifyingAs: .tools)
        defer { tools.close() }
        #expect(harness.shortcut("d", in: tools))
        #expect(harness.model.colors == .default)
        // Any other window — another app's, a sheet, Settings — does nothing.
        let other = harness.makeKeyWindow()
        defer { other.close() }
        let before = harness.model.colors
        #expect(!harness.shortcut("x", in: other))
        #expect(!harness.shortcut("c", in: other))
        #expect(harness.model.colors == before)
        #expect(harness.model.activeColorSlot == .primary)
    }

    @Test func typingInATextFieldBlocksColorAndToolKeys() throws {
        let harness = try ColorsPanelHarness(primary: blue(), expanded: true)
        defer { finish(harness) }
        let hexField = try #require(harness.textFields().first, "the hex box is not an NSTextField")
        harness.focus(hexField)
        #expect(CanvasInputRouter.hasTextInputFocus(in: harness.window),
                "the hex box's field editor is the window's first responder")
        let before = harness.model.colors
        let tool = harness.model.activeToolID
        #expect(!harness.shortcut("x"))
        #expect(!harness.shortcut("d"))
        #expect(!harness.shortcut("c"))
        #expect(!harness.shortcut("b"), "tool keys stay blocked too")
        #expect(harness.model.colors == before)
        #expect(harness.model.activeToolID == tool)
    }

    // MARK: - C-2: hex, sliders, wheel

    @Test func hexBoxEditsTheActiveSlotAndPersists() throws {
        let harness = try ColorsPanelHarness(primary: blue(), expanded: true)
        defer { finish(harness) }
        // Return commits, exactly as `onSubmit` does.
        harness.fields.beginHexEdit()
        harness.fields.typeHex("#123456")
        harness.fields.commitHex(in: harness.model)
        #expect(harness.model.colors.primary
            == ColorRGBA8(red: 18, green: 52, blue: 86, alpha: 255))
        #expect(harness.fields.hexText(in: harness.model) == "#123456")
        let stored = UserDefaults(suiteName: harness.suiteName)
        #expect(stored?.string(forKey: ColorSelectionStore.primaryKey) == "#123456FF")

        // A bad string changes nothing and the box shows the current color again.
        harness.fields.beginHexEdit()
        harness.fields.typeHex("nope")
        harness.fields.commitHex(in: harness.model)
        #expect(harness.model.colors.primary
            == ColorRGBA8(red: 18, green: 52, blue: 86, alpha: 255))
        #expect(harness.fields.hexText(in: harness.model) == "#123456")

        // Escape reverts.
        harness.fields.beginHexEdit()
        harness.fields.typeHex("FF0000")
        #expect(harness.fields.hexText(in: harness.model) == "FF0000")
        harness.fields.cancelHex()
        #expect(harness.fields.hexText(in: harness.model) == "#123456")
        #expect(harness.model.colors.primary.red == 18)

        // The other slot's hex field edits the other slot.
        harness.model.switchActiveColorSlot()
        harness.fields.beginHexEdit()
        harness.fields.typeHex("0F0F0FFF")
        harness.fields.commitHex(in: harness.model)
        #expect(harness.model.colors.secondary == ColorRGBA8(red: 15, green: 15, blue: 15,
                                                            alpha: 255))
        #expect(harness.model.colors.primary.red == 18)

        // The next launch reads the same pair back.
        let relaunched = try ColorsPanelHarness(reusingSuiteNamed: harness.suiteName)
        defer { finish(relaunched) }
        #expect(relaunched.model.colors == harness.model.colors)
        #expect(relaunched.fields.hexText(in: relaunched.model) == "#123456",
                "a relaunch starts with Primary active, so the box shows the primary")
    }

    @Test func numericBoxesCommitClampAndRevert() throws {
        let harness = try ColorsPanelHarness(primary: blue(), expanded: true)
        defer { finish(harness) }
        let fields = harness.fields
        #expect(fields.text(for: .red, in: harness.model) == "51")

        fields.beginEdit(.red)
        fields.type("200", for: .red)
        #expect(fields.text(for: .red, in: harness.model) == "200", "typing is not overwritten")
        fields.commit(.red, in: harness.model)
        #expect(harness.model.colors.primary.red == 200)
        #expect(fields.text(for: .red, in: harness.model) == "200")

        // Out of range clamps; junk reverts; Escape reverts.
        fields.beginEdit(.red)
        fields.type("300", for: .red)
        fields.commit(.red, in: harness.model)
        #expect(harness.model.colors.primary.red == 255)
        fields.beginEdit(.green)
        fields.type("abc", for: .green)
        fields.commit(.green, in: harness.model)
        #expect(harness.model.colors.primary.green == 102)
        fields.beginEdit(.blue)
        fields.type("9", for: .blue)
        fields.cancel(.blue)
        #expect(harness.model.colors.primary.blue == 204)
        // Hue's scale is 0–360, saturation's 0–100 (C-2).
        fields.beginEdit(.saturation)
        fields.type("-5", for: .saturation)
        fields.commit(.saturation, in: harness.model)
        #expect(harness.model.colorEditor.value(of: .saturation) == 0)

        // A channel edit re-syncs the HSV cache, so the wheel's marker follows.
        #expect(harness.model.colorEditor.hsv[.primary]?.displayHue
                    == harness.model.colorEditor.value(of: .hue))
    }

    @Test func slidersDriveTheModelAndTheFields() throws {
        let harness = try ColorsPanelHarness(primary: blue(), expanded: true)
        defer { finish(harness) }
        // What each slider's binding does.
        harness.model.setColorChannel(.alpha, to: 128)
        #expect(harness.model.colors.primary.alpha == 128)
        #expect(harness.fields.text(for: .alpha, in: harness.model) == "128")
        #expect(harness.fields.hexText(in: harness.model) == "#3366CC80")
        // The slider's own accessibility surface (C-2): adjustable, labelled, identified.
        let labels = labelsByIdentifier(in: harness.hosting)
        #expect(labels["colors.alpha"] == "Alpha")
        harness.model.setColorChannel(.value, to: 50)
        #expect(harness.model.colorEditor.value(of: .value) == 50)
        #expect(labelsByIdentifier(in: harness.hosting)["colors.value"] == "Value")
        // Value 0 keeps hue and saturation in the cache, so raising it again returns the color
        // (alpha rides along: 128, set above).
        harness.model.setColorChannel(.value, to: 0)
        #expect(harness.model.colors.primary == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 128))
        harness.model.setColorChannel(.value, to: 50)
        // HSV(220, 75, 50): c 0.375, x 0.125, m 0.125 → (32, 64, 128).
        #expect(harness.model.colors.primary
            == ColorRGBA8(red: 32, green: 64, blue: 128, alpha: 128))
    }

    @Test func wheelClickSetsActiveSlotFromGeometry() throws {
        let harness = try ColorsPanelHarness(primary: .black,
                                            secondary: ColorRGBA8(red: 229, green: 136, blue: 34))
        defer { finish(harness) }
        // 12 o'clock, halfway out: hue 90, saturation 50, and value rises from black's 0.
        try harness.wheel(.down, hue: 90, saturation: 50)
        try harness.wheel(.up, hue: 90, saturation: 50)
        #expect(harness.model.colorEditor.hsv[.primary]?.displayHue == 90)
        #expect(harness.model.colorEditor.hsv[.primary]?.displaySaturation == 50)
        #expect(harness.model.colorEditor.hsv[.primary]?.displayValue == 100)
        #expect(harness.model.colors.primary
            == ColorRGBA8(red: 191, green: 255, blue: 128, alpha: 255))
        #expect(try harness.accessibilityValue("colors.wheel") == "Hue 90°, Saturation 50%")
        #expect(harness.model.colors.secondary == ColorRGBA8(red: 229, green: 136, blue: 34))

        // Right button → the inactive slot; the active slot's color is untouched.
        try harness.wheel(.down, hue: 200, saturation: 80, button: .right)
        try harness.wheel(.dragged, hue: 210, saturation: 90, button: .right)
        try harness.wheel(.up, hue: 210, saturation: 90, button: .right)
        #expect(harness.model.colorEditor.hsv[.secondary]?.displayHue == 210)
        #expect(harness.model.colorEditor.hsv[.secondary]?.displaySaturation == 90)
        #expect(harness.model.colorEditor.hsv[.primary]?.displayHue == 90)
        #expect(harness.model.colorEditor.hsv[.primary]?.displaySaturation == 50)
        #expect(harness.model.colorEditor.hsv[.primary]?.displayValue == 100)

        // Control-click is Paint.NET's right button.
        try harness.wheel(.down, hue: 30, saturation: 40, button: .leftWithControl)
        try harness.wheel(.up, hue: 30, saturation: 40, button: .leftWithControl)
        #expect(harness.model.colorEditor.hsv[.secondary]?.displayHue == 30)
        #expect(harness.model.colorEditor.hsv[.secondary]?.displaySaturation == 40)
    }

    @Test func wheelDragConstraintsComeFromItsModifiers() throws {
        let harness = try ColorsPanelHarness(primary: .black,
                                            secondary: ColorRGBA8(red: 229, green: 136, blue: 34))
        defer { finish(harness) }
        try harness.wheel(.down, hue: 90, saturation: 50)
        try harness.wheel(.up, hue: 90, saturation: 50)
        // ⌘ drag: hue only, so the marker stays on its circle.
        try harness.wheel(.down, hue: 200, saturation: 10, modifiers: [.command])
        try harness.wheel(.dragged, hue: 250, saturation: 100, modifiers: [.command])
        try harness.wheel(.up, hue: 250, saturation: 100, modifiers: [.command])
        #expect(harness.model.colorEditor.hsv[.primary] == HSVColor(hue: 250, saturation: 50, value: 100))
        // ⇧⌘ drag: hue snapped to 15°, 250 → 255.
        try harness.wheel(.down, hue: 250, saturation: 50, modifiers: [.shift, .command])
        try harness.wheel(.dragged, hue: 262, saturation: 20, modifiers: [.shift, .command])
        try harness.wheel(.up, hue: 262, saturation: 20, modifiers: [.shift, .command])
        #expect(harness.model.colorEditor.hsv[.primary]?.hue == 255)
        #expect(harness.model.colorEditor.hsv[.primary]?.saturation == 50)
        // ⌥ drag: saturation only, so the marker stays on its spoke.
        try harness.wheel(.down, hue: 255, saturation: 50, modifiers: [.option])
        try harness.wheel(.dragged, hue: 10, saturation: 20, modifiers: [.option])
        try harness.wheel(.up, hue: 10, saturation: 20, modifiers: [.option])
        #expect(harness.model.colorEditor.hsv[.primary]?.hue == 255)
        #expect(harness.model.colorEditor.hsv[.primary]?.saturation == 20)
    }

    @Test func wheelCentreAndOutsideRim() throws {
        let harness = try ColorsPanelHarness(primary: .black)
        defer { finish(harness) }
        // A drag outside the rim clamps to saturation 100.
        try harness.wheel(.down, hue: 20, saturation: 140)
        try harness.wheel(.up, hue: 20, saturation: 140)
        #expect(harness.model.colorEditor.hsv[.primary]?.saturation == 100)
        // The exact center has no direction: saturation 0 with the cached hue kept.
        try harness.wheel(.down, hue: 0, saturation: 0)
        try harness.wheel(.up, hue: 0, saturation: 0)
        #expect(harness.model.colorEditor.hsv[.primary]?.displayHue == 20, "the cached hue survived")
        #expect(harness.model.colorEditor.hsv[.primary]?.displaySaturation == 0)
        #expect(harness.model.colors.primary == .white)
        // A zero-radius wheel is a no-op rather than a divide by zero.
        let degenerate = ColorWheelGeometry.hueSaturation(at: .zero, center: .zero, radius: 0)
        #expect(degenerate == nil)
    }

    // MARK: - More » / « Less

    @Test func moreLessResizesAndPersists() throws {
        let harness = try ColorsPanelHarness(primary: blue())
        defer { finish(harness) }
        let collapsed = harness.identifierSet()
        #expect(collapsed.contains("colors.more"))
        #expect(!collapsed.contains(ColorHex.fieldIdentifier), "collapsed hides the hex box")
        #expect(!collapsed.contains(ColorChannel.red.sliderIdentifier))
        #expect(harness.textFields().isEmpty)

        try harness.pressButton("colors.more")
        #expect(harness.model.colorsPanelExpanded)
        let expanded = harness.identifierSet()
        #expect(expanded.contains(ColorHex.fieldIdentifier))
        #expect(expanded.contains("colors.less"))
        for channel in ColorChannel.allCases {
            #expect(expanded.contains(channel.sliderIdentifier), "missing \(channel.sliderIdentifier)")
            #expect(expanded.contains(channel.fieldIdentifier), "missing \(channel.fieldIdentifier)")
        }
        #expect(harness.textFields().count == ColorChannel.allCases.count + 1,
                "one box per channel plus the hex box")
        #expect(UserDefaults(suiteName: harness.suiteName)?.bool(forKey: ColorSelectionStore.panelExpandedKey) == true)

        // The panel window keeps its top-left corner when its content drives a resize (spec 0007).
        // An offscreen window gets no layout pass in test-host mode, so the anchoring rule itself
        // is checked on `PanelWindow`; that the visible panel really grows is manual step 6.
        let anchored = PanelWindow(contentRect: NSRect(x: 300, y: 300, width: 200, height: 200),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        anchored.keepsTopLeftOnResize = true
        let before = anchored.frame
        anchored.setFrame(NSRect(x: 300, y: 300, width: 200, height: 320), display: false)
        #expect(abs(anchored.frame.maxY - before.maxY) < 0.5,
                "the top edge stayed put: \(before) → \(anchored.frame)")
        #expect(abs(anchored.frame.minX - before.minX) < 0.5,
                "the left edge stayed put: \(before) → \(anchored.frame)")
        // A width change is a user's drag: the frame goes where it was told to.
        anchored.setFrame(NSRect(x: 100, y: 100, width: 240, height: 320), display: false)
        #expect(anchored.frame == NSRect(x: 100, y: 100, width: 240, height: 320))
        let plain = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                               styleMask: [.titled], backing: .buffered, defer: false)
        plain.setFrame(NSRect(x: 0, y: 0, width: 100, height: 150), display: false)
        #expect(plain.frame.height == 150, "a panel that does not anchor content behaves as before")

        try harness.pressButton("colors.less")
        #expect(!harness.model.colorsPanelExpanded)
        #expect(UserDefaults(suiteName: harness.suiteName)?.bool(forKey: ColorSelectionStore.panelExpandedKey) == false)

        // Expanded state is app-wide and comes back on the next launch.
        harness.model.setColorsPanelExpanded(true)
        let relaunched = try ColorsPanelHarness(reusingSuiteNamed: harness.suiteName)
        defer { finish(relaunched) }
        #expect(relaunched.model.colorsPanelExpanded)
        #expect(relaunched.identifierSet().contains(ColorHex.fieldIdentifier))
    }

    /// The panel's accessibility labels, the ones VoiceOver reads for the wheel and swatches.
    @Test func accessibilityLabels() throws {
        let harness = try ColorsPanelHarness(primary: blue(), expanded: true)
        defer { finish(harness) }
        harness.model.setColorChannel(.hue, to: 220)
        harness.model.setColorChannel(.saturation, to: 75)
        pumpMainRunLoop()
        let labels = labelsByIdentifier(in: harness.hosting)
        #expect(labels["colors.wheel"] == "Color wheel")
        #expect(labels["colors.primary"] == "Primary color")
        #expect(labels["colors.secondary"] == "Secondary color")
        #expect(labels["colors.swap"] == "Swap colors")
        #expect(labels["colors.reset"] == "Reset colors")
        #expect(labels["colors.hex"] == "Primary color hex")
        #expect(labels["colors.red"] == "Red")
        #expect(labels["colors.alphaField"] == "Alpha")
        #expect(try harness.accessibilityValue("colors.wheel") == "Hue 220°, Saturation 75%")
    }
}

/// Accessibility labels keyed by identifier (the harness's tree, expanded).
@MainActor
private func labelsByIdentifier(in root: NSView) -> [String: String] {
    var found: [String: String] = [:]
    AX.withAccessibilityClient {
        AX.walk(root) { element in
            guard let identifier = AX.identifier(of: element),
                  let label = AX.label(of: element), !label.isEmpty else { return }
            found[identifier] = label
        }
    }
    return found
}
