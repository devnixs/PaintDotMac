import Foundation

/// Which tool to activate when the document state changes underneath the tools
/// (spec 0020 item 10): floating pixels belong to Move Selected Pixels, so undoing
/// "Finish Pixels" with the Paintbrush active brings the pixels back **and** selects the
/// tool that owns them; the same hook makes 0021's Paste land in this tool. `nil` = keep
/// the active tool.
enum FloatingPixelsPolicy {
    static func toolToActivate(hasFloatingPixels: Bool, activeTool: ToolID) -> ToolID? {
        guard hasFloatingPixels, activeTool != .moveSelectedPixels else { return nil }
        return .moveSelectedPixels
    }
}
