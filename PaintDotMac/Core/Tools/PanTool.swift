import CoreGraphics
import Foundation

/// The Pan tool (T-8, spec 0006; Paint.NET ViewTools.html): click and drag with the left or
/// right mouse button moves the canvas. Reuses 0004's `CanvasNavigating` pan (content follows
/// the pointer, clamped), so an image smaller than the view stays centered and nothing
/// crashes. Never touches pixels, history, or the edited state.
@MainActor
final class PanTool: Tool {
    let id: ToolID = .pan

    private var isDragging = false

    func mouseDown(_ event: ToolEvent, context: any ToolContext) {
        context.navigation.beginPan(atView: event.viewLocation)
        isDragging = true
        context.invalidateCursor()
    }

    func mouseDragged(_ event: ToolEvent, context: any ToolContext) {
        guard isDragging else { return }
        // `viewLocation` only: the canvas point under the pointer moves while panning.
        context.navigation.continuePan(toView: event.viewLocation)
    }

    func mouseUp(_ event: ToolEvent, context: any ToolContext) {
        guard isDragging else { return }
        context.navigation.continuePan(toView: event.viewLocation)
        context.navigation.endPan()
        isDragging = false
        context.invalidateCursor()
    }

    func cancel(context: any ToolContext) {
        guard isDragging else { return }
        context.navigation.endPan()  // the view stays where it is; panning has no undo
        isDragging = false
    }

    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor {
        isDragging ? .closedHand : .openHand
    }
}
