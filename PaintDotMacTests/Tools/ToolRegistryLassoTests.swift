import Testing
@testable import PaintDotMac

/// The 0015 registry rows (PRD D-13): Lasso Select registers in the S group between
/// Rectangle and Ellipse Select.
@MainActor
struct ToolRegistryLassoTests {
    @Test func sGroupOrder() {
        let registry = ToolRegistry.standard()
        #expect(registry.shortcutGroup(for: "s")
                    == [.rectangleSelect, .lassoSelect, .ellipseSelect])
        #expect(registry.makeTool(.lassoSelect) is LassoSelectTool)
    }
}
