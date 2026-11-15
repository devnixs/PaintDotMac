import CoreGraphics
import Testing
@testable import PaintDotMac

/// The `Tool` protocol's default implementations (spec 0006 *Test plan*), exercised on a
/// minimal `final class` with only the required members.
@MainActor
struct ToolDefaultsTests {
    /// Conforms with just `id` + the three mouse methods; records commit/cancel calls.
    final class Minimal: Tool {
        let id: ToolID
        var pending = false
        private(set) var commits = 0
        private(set) var cancels = 0

        init(id: ToolID = .zoom) { self.id = id }

        var hasPendingEdit: Bool { pending }
        func mouseDown(_ event: ToolEvent, context: any ToolContext) {}
        func mouseDragged(_ event: ToolEvent, context: any ToolContext) {}
        func mouseUp(_ event: ToolEvent, context: any ToolContext) {}
        func commit(context: any ToolContext) { commits += 1 }
        func cancel(context: any ToolContext) { cancels += 1 }
    }

    private func event(_ key: ToolKey) -> ToolKeyEvent {
        ToolKeyEvent(key: key, characters: "", modifiers: [], isRepeat: false)
    }

    @Test func defaultDeactivateCommitsPending() {
        let context = FakeToolContext()
        let tool = Minimal()
        tool.pending = true
        tool.deactivate(context: context)
        #expect(tool.commits == 1)

        let idle = Minimal()
        idle.deactivate(context: context)
        #expect(idle.commits == 0)
    }

    @Test func defaultKeyDown() {
        let context = FakeToolContext()
        let tool = Minimal()

        tool.pending = true
        #expect(tool.keyDown(event(.returnKey), context: context) == true)
        #expect(tool.commits == 1)
        #expect(tool.keyDown(event(.enter), context: context) == true)
        #expect(tool.commits == 2)
        #expect(tool.keyDown(event(.escape), context: context) == true)
        #expect(tool.cancels == 1)

        tool.pending = false
        #expect(tool.keyDown(event(.returnKey), context: context) == false)
        #expect(tool.keyDown(event(.escape), context: context) == false)
        #expect(tool.keyDown(event(.character("a")), context: context) == false)
        #expect(tool.commits == 2)
        #expect(tool.cancels == 1)
    }

    @Test func defaultCursorIsArrow() {
        let tool = Minimal()
        #expect(tool.cursor(at: nil, modifiers: []) == .arrow)
        #expect(tool.cursor(at: CGPoint(x: 10, y: 20), modifiers: [.shift, .option]) == .arrow)
    }

    @Test func defaultFlagsChangedInvalidatesCursor() {
        let context = FakeToolContext()
        Minimal().flagsChanged(.option, context: context)
        #expect(context.cursorInvalidations == 1)
    }

    @Test func defaultOtherMethodsAreNoOps() {
        let context = FakeToolContext()
        let tool = Minimal()
        tool.activate(context: context)
        tool.mouseMoved(ToolEvent(location: .zero, viewLocation: .zero, button: .primary,
                                  modifiers: [], clickCount: 0, pressure: 1, timestamp: 0),
                        context: context)
        tool.insertText("x", context: context)
        tool.optionsDidChange(context: context)
        #expect(context.cursorInvalidations == 0)
    }

    @Test func descriptorAccessors() {
        let zoom = Minimal(id: .zoom)
        #expect(zoom.displayName == "Zoom")
        #expect(zoom.shortcutKey == "z")
        let line = Minimal(id: .lineCurve)
        #expect(line.displayName == "Line / Curve")
        #expect(line.shortcutKey == "o")
        #expect(line.descriptor.supportsPendingEdits == true)
    }
}
