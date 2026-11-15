import CoreGraphics
import Foundation

/// A tool (AGENTS.md rule 6, spec 0006). Tools are `final class`es holding gesture state —
/// one instance per `ToolID` for the app's lifetime, created lazily by `ToolRegistry`.
/// Tools never import AppKit and never read `NSEvent`; the dispatcher converts events to
/// `ToolEvent`/`ToolKeyEvent` first.
@MainActor
protocol Tool: AnyObject {
    var id: ToolID { get }
    /// True while the tool owns typing (the Text tool while editing). Default `false`.
    var capturesKeyboard: Bool { get }
    /// Uncommitted editable state: a shape, text, floating pixels, or an in-progress stroke.
    var hasPendingEdit: Bool { get }

    func activate(context: any ToolContext)
    /// Default: commit a pending edit (Paint.NET commits when you switch tools).
    func deactivate(context: any ToolContext)
    func mouseDown(_ event: ToolEvent, context: any ToolContext)
    func mouseDragged(_ event: ToolEvent, context: any ToolContext)
    func mouseUp(_ event: ToolEvent, context: any ToolContext)
    /// Hover feedback. Default: no-op.
    func mouseMoved(_ event: ToolEvent, context: any ToolContext)
    /// Modifier keys changed. Default: re-query the cursor.
    func flagsChanged(_ modifiers: ToolModifiers, context: any ToolContext)
    /// Return true when consumed. Default: Return/Enter commits and Escape cancels a pending
    /// edit.
    func keyDown(_ event: ToolKeyEvent, context: any ToolContext) -> Bool
    /// Composed text (the Text tool, 0040). Default: no-op.
    func insertText(_ text: String, context: any ToolContext)
    /// `location nil` = the pointer is outside the canvas.
    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor
    /// Finish button, Return, tool switch, document switch; later also undo and save
    /// (0008/0009 call it). Default: no-op.
    func commit(context: any ToolContext)
    /// Escape; must leave the tool idle with no partial edit. Default: no-op.
    func cancel(context: any ToolContext)
    /// An option changed while the tool is active (live-edited shapes/text restyle).
    func optionsDidChange(context: any ToolContext)
}

extension Tool {
    var capturesKeyboard: Bool { false }
    var hasPendingEdit: Bool { false }

    func activate(context: any ToolContext) {}

    func deactivate(context: any ToolContext) {
        if hasPendingEdit { commit(context: context) }
    }

    func mouseMoved(_ event: ToolEvent, context: any ToolContext) {}

    func flagsChanged(_ modifiers: ToolModifiers, context: any ToolContext) {
        context.invalidateCursor()
    }

    func keyDown(_ event: ToolKeyEvent, context: any ToolContext) -> Bool {
        switch event.key {
        case .returnKey, .enter:
            guard hasPendingEdit else { return false }
            commit(context: context)
            return true
        case .escape:
            guard hasPendingEdit else { return false }
            cancel(context: context)
            return true
        default:
            return false
        }
    }

    func insertText(_ text: String, context: any ToolContext) {}

    func cursor(at location: CGPoint?, modifiers: ToolModifiers) -> ToolCursor { .arrow }

    func commit(context: any ToolContext) {}

    func cancel(context: any ToolContext) {}

    func optionsDidChange(context: any ToolContext) {}

    var descriptor: ToolDescriptor { ToolRegistry.descriptor(for: id) }
    var displayName: String { descriptor.displayName }
    var shortcutKey: Character { descriptor.shortcutKey }
}
