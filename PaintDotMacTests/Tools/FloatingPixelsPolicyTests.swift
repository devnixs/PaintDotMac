import Testing

@testable import PaintDotMac

/// `FloatingPixelsPolicy.toolToActivate` (spec 0020 *Test plan*): a table over
/// has-floating × all 19 tool IDs.
struct FloatingPixelsPolicyTests {
    @Test(arguments: ToolID.allCases)
    func table(activeTool: ToolID) {
        let expected: ToolID? = activeTool == .moveSelectedPixels ? nil : .moveSelectedPixels
        #expect(FloatingPixelsPolicy.toolToActivate(hasFloatingPixels: true,
                                                    activeTool: activeTool) == expected)
        #expect(FloatingPixelsPolicy.toolToActivate(hasFloatingPixels: false,
                                                    activeTool: activeTool) == nil)
    }

    /// The 0020 acceptance path: undoing "Finish Pixels" with the Paintbrush active
    /// selects Move Selected Pixels; with it already active, nothing changes.
    @Test func undoFinishSwitchesBack() {
        #expect(FloatingPixelsPolicy.toolToActivate(hasFloatingPixels: true,
                                                    activeTool: .paintbrush)
                    == .moveSelectedPixels)
        #expect(FloatingPixelsPolicy.toolToActivate(hasFloatingPixels: true,
                                                    activeTool: .moveSelectedPixels) == nil)
    }
}
