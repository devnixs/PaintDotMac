import AppKit

extension ToolCursor {
    /// The AppKit cursor for a tool cursor (`zoomIn`/`zoomOut` are the macOS 15 magnifier
    /// cursors).
    var nsCursor: NSCursor {
        switch self {
        case .arrow: .arrow
        case .crosshair: .crosshair
        case .zoomIn: .zoomIn
        case .zoomOut: .zoomOut
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .iBeam: .iBeam
        }
    }
}
