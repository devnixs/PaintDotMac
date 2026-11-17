import AppKit

extension ToolCursor {
    /// The AppKit cursor for a tool cursor (`zoomIn`/`zoomOut` are the macOS 15 magnifier
    /// cursors; `resize` is the macOS 15 frame-resize cursor; the 0019 move/rotate cursors
    /// are SF Symbols rendered once at 16 pt with the hotspot at the center — the cursor
    /// images are not rotated with the frame in v1.0).
    @MainActor
    var nsCursor: NSCursor {
        switch self {
        case .arrow: .arrow
        case .crosshair: .crosshair
        case .zoomIn: .zoomIn
        case .zoomOut: .zoomOut
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .iBeam: .iBeam
        case .move: ToolCursors.move
        case .rotate: ToolCursors.rotate
        case .resize(let handle):
            NSCursor.frameResize(position: handle.frameResizePosition, directions: .all)
        }
    }
}

extension TransformHandle {
    /// The frame-resize position matching the nub (the view is not flipped, so canvas
    /// top is screen top).
    var frameResizePosition: NSCursor.FrameResizePosition {
        switch self {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        }
    }
}

/// The Move-tool cursors, built once (spec 0019).
@MainActor
private enum ToolCursors {
    static let move = symbolCursor("arrow.up.and.down.and.arrow.left.and.right")
    static let rotate = symbolCursor("arrow.clockwise")

    /// The SF Symbol rendered opaque black at 16 pt with the hotspot at the center;
    /// a missing symbol (not a user path on macOS 15) falls back to the arrow.
    private static func symbolCursor(_ symbolName: String) -> NSCursor {
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return .arrow }
        let size = symbol.size
        guard size.width > 0, size.height > 0 else { return .arrow }
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        // Tint the template black: cursors have no template rendering.
        NSColor.black.setFill()
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }
}
