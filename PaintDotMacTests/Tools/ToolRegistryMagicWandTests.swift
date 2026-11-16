import Testing
@testable import PaintDotMac

/// The 0016 registry rows (PRD D-13): Magic Wand completes the S group —
/// Rectangle → Lasso → Ellipse → Magic Wand.
@MainActor
struct ToolRegistryMagicWandTests {
    @Test func sGroupIsComplete() {
        let registry = ToolRegistry.standard()
        #expect(registry.shortcutGroup(for: "s")
                    == [.rectangleSelect, .lassoSelect, .ellipseSelect, .magicWand])
        #expect(registry.makeTool(.magicWand) is MagicWandTool)
        #expect(registry.isImplemented(.magicWand))
    }
}
