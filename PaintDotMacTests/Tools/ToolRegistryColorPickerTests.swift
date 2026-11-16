import Testing

@testable import PaintDotMac

/// The Color Picker's registry wiring (spec 0012 *Test plan*): key `k` → `.colorPicker`,
/// the implemented list, and the descriptor.
@MainActor
struct ToolRegistryColorPickerTests {
    @Test func kResolvesToColorPicker() {
        let registry = ToolRegistry.standard()
        #expect(registry.shortcutGroup(for: "k") == [.colorPicker], "its own single-tool key group")
        var resolver = ToolShortcutResolver()
        #expect(resolver.resolve(key: "k", shift: false, group: registry.shortcutGroup(for: "k"),
                                 activeTool: .paintbrush, timestamp: 100) == .colorPicker)
        // Within 1 s while it is active: the one-member group stays the Color Picker.
        #expect(resolver.resolve(key: "k", shift: false, group: registry.shortcutGroup(for: "k"),
                                 activeTool: .colorPicker, timestamp: 100.5) == .colorPicker)
    }

    @Test func implementedOrderAndDescriptor() {
        let registry = ToolRegistry.standard()
        #expect(registry.implementedIDs
                    == [.rectangleSelect, .ellipseSelect, .zoom, .pan, .paintbrush, .eraser,
                        .pencil, .colorPicker])
        #expect(registry.implementedIDs.filter { $0 == .colorPicker }.count == 1)
        #expect(registry.isImplemented(.colorPicker))
        #expect(registry.makeTool(.colorPicker) is ColorPickerTool)
        let descriptor = ToolRegistry.descriptor(for: .colorPicker)
        #expect(descriptor.displayName == "Color Picker")
        #expect(descriptor.shortcutKey == "k")
        #expect(descriptor.symbolName == "eyedropper")
        #expect(descriptor.helpText == "Color Picker (K)")
        #expect(registry.defaultToolID == .paintbrush, "registration does not change the start tool")
    }
}
