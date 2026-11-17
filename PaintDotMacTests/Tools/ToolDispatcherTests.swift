import CoreGraphics
import Testing
@testable import PaintDotMac

/// `ToolDispatcher`: selection, gestures, button mapping, deferred switches, context
/// changes, shortcuts, and pending-edit mirroring (spec 0006 *Test plan*).
@MainActor
struct ToolDispatcherTests {
    /// The registry used by these tests; `.recolor` and `.paintbrush` stay unimplemented.
    private struct Fixture {
        var dispatcher: ToolDispatcher
        var stubs: [ToolID: StubTool]
        var log: ToolCallLog
        var context: FakeToolContext

        func stub(_ id: ToolID) -> StubTool {
            guard let stub = stubs[id] else {
                Issue.record("no stub for \(id.rawValue)")
                fatalError("test fixture missing \(id.rawValue)")  // test-only
            }
            return stub
        }
    }

    private func fixture() -> Fixture {
        let log = ToolCallLog()
        let ids: [ToolID] = [.pan, .zoom, .rectangleSelect, .lassoSelect, .ellipseSelect,
                             .magicWand, .colorPicker]
        var stubs: [ToolID: StubTool] = [:]
        var factories: [ToolID: @MainActor () -> any Tool] = [:]
        for id in ids {
            let stub = StubTool(id: id, log: log)
            stubs[id] = stub
            factories[id] = { stub }
        }
        let dispatcher = ToolDispatcher(registry: ToolRegistry(factories: factories))
        return Fixture(dispatcher: dispatcher, stubs: stubs, log: log, context: FakeToolContext())
    }

    private func input(_ button: ToolPhysicalButton,
                       location: CGPoint = CGPoint(x: 50, y: 60),
                       viewLocation: CGPoint = CGPoint(x: 50, y: 60),
                       modifiers: ToolModifiers = [], clickCount: Int = 1) -> ToolPointerInput {
        ToolPointerInput(physicalButton: button, location: location, viewLocation: viewLocation,
                         modifiers: modifiers, clickCount: clickCount, pressure: 1.0, timestamp: 0)
    }

    // MARK: - Initial state and activation

    @Test func initialStateAndActivation() {
        let f = fixture()
        #expect(f.dispatcher.activeToolID == .pan)
        #expect(f.dispatcher.previousToolID == nil)
        #expect(f.stub(.pan).calls.isEmpty)
        f.dispatcher.setContext(f.context)
        #expect(f.stub(.pan).calls == ["activate"])
    }

    @Test func selectCallsDeactivateThenActivate() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        var stateChanges = 0
        f.dispatcher.onStateChange = { stateChanges += 1 }
        #expect(f.dispatcher.selectTool(.zoom) == true)
        #expect(f.stub(.pan).calls == ["activate", "deactivate"])
        #expect(f.stub(.zoom).calls == ["activate"])
        // Shared log: pan's deactivate precedes zoom's activate.
        let deactivateIndex = f.log.all.firstIndex(of: "pan:deactivate")
        let activateIndex = f.log.all.firstIndex(of: "zoom:activate")
        #expect(deactivateIndex != nil && activateIndex != nil, "log: \(f.log.all)")
        if let deactivateIndex, let activateIndex {
            #expect(deactivateIndex < activateIndex)
        }
        #expect(f.dispatcher.previousToolID == .pan)
        #expect(stateChanges == 1)
    }

    @Test func switchCommitsPendingEdit() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        f.stub(.pan).hasPendingEdit = true
        f.dispatcher.selectTool(.zoom)
        let entries = f.log.all
        let commitIndex = entries.firstIndex(of: "pan:commit")
        let activateIndex = entries.firstIndex(of: "zoom:activate")
        #expect(commitIndex != nil && activateIndex != nil, "log: \(entries)")
        if let commitIndex, let activateIndex {
            #expect(commitIndex < activateIndex)
        }
    }

    @Test func previousToolTracked() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        f.dispatcher.selectTool(.zoom)
        f.dispatcher.selectTool(.colorPicker)
        #expect(f.dispatcher.previousToolID == .zoom)
        f.dispatcher.selectTool(.zoom)
        #expect(f.dispatcher.previousToolID == .colorPicker)
    }

    @Test func selectSameToolIsNoOp() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        var stateChanges = 0
        f.dispatcher.onStateChange = { stateChanges += 1 }
        #expect(f.dispatcher.selectTool(.pan) == true)
        #expect(f.stub(.pan).calls == ["activate"])
        #expect(f.dispatcher.previousToolID == nil)
        #expect(stateChanges == 0)
    }

    @Test func selectUnimplementedIsNoOp() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        #expect(f.dispatcher.selectTool(.recolor) == false)
        #expect(f.dispatcher.activeToolID == .pan)
        #expect(f.dispatcher.previousToolID == nil)
        #expect(f.log.all == ["pan:activate"])
    }

    // MARK: - Gestures and buttons

    @Test func buttonMapping() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        f.dispatcher.pointerDown(input(.left))
        f.dispatcher.pointerUp(input(.left))
        #expect(f.stub(.pan).receivedEvents.map(\.button) == [.primary, .primary])

        f.dispatcher.pointerDown(input(.right))
        f.dispatcher.pointerUp(input(.right))

        f.dispatcher.pointerDown(input(.left, modifiers: [.control]))
        f.dispatcher.pointerDragged(input(.left, modifiers: [.control], clickCount: 0))
        f.dispatcher.pointerUp(input(.left, modifiers: [.control]))
        let events = f.stub(.pan).receivedEvents
        // down(primary), up(primary), down(secondary), up(secondary),
        // down(secondary+control), dragged(secondary), up(secondary)
        #expect(events.count == 7)
        #expect(events[2].button == .secondary)
        #expect(events[4].button == .secondary)
        #expect(events[4].modifiers.contains(.control),
                "Control-left maps to secondary but keeps .control for TOOL-A/0012 checks")
        // Drag events carry the gesture's button and clickCount 0.
        #expect(events[5].button == .secondary)
        #expect(events[5].clickCount == 0)
        // Downs carry the caller's clickCount.
        #expect(events[0].clickCount == 1)
    }

    @Test func secondButtonIgnored() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        f.dispatcher.pointerDown(input(.left))
        f.dispatcher.pointerDown(input(.right))
        f.dispatcher.pointerUp(input(.right))
        f.dispatcher.pointerDragged(input(.left))
        f.dispatcher.pointerUp(input(.left))
        #expect(f.stub(.pan).calls == ["activate", "mouseDown(primary)", "mouseDragged(primary)",
                                       "mouseUp(primary)"])
    }

    @Test func orphanEventsIgnored() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        f.dispatcher.pointerDragged(input(.left))
        f.dispatcher.pointerUp(input(.left))
        f.dispatcher.pointerUp(input(.right))
        #expect(f.stub(.pan).calls == ["activate"])
    }

    @Test func escapeCancelsGesture() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        f.dispatcher.pointerDown(input(.left))
        let escape = ToolKeyEvent(key: .escape, characters: "\u{1b}", modifiers: [], isRepeat: false)
        #expect(f.dispatcher.keyDown(escape) == true)
        #expect(f.stub(.pan).calls == ["activate", "mouseDown(primary)", "cancel"])
        f.dispatcher.pointerDragged(input(.left))
        f.dispatcher.pointerUp(input(.left))
        // The late drag and up are swallowed…
        #expect(f.stub(.pan).calls.count == 3)
        // …but a new gesture is delivered normally.
        f.dispatcher.pointerDown(input(.left))
        #expect(f.stub(.pan).calls.last == "mouseDown(primary)")
    }

    @Test func escapeWithoutGestureGoesToTool() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        f.stub(.pan).keyDownResult = false
        let escape = ToolKeyEvent(key: .escape, characters: "\u{1b}", modifiers: [], isRepeat: false)
        // No gesture in progress: the event goes to the tool, whose answer decides.
        #expect(f.dispatcher.keyDown(escape) == false)
        #expect(f.stub(.pan).receivedKeyEvents.map(\.key) == [.escape])
        #expect(f.stub(.pan).calls == ["activate", "keyDown(escape)"])
    }

    // MARK: - Deferred switches

    @Test func requestedSwitchIsDeferred() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        let zoom = f.stub(.zoom)
        let pan = f.stub(.pan)
        pan.onMouseUp = { _, _ in
            f.dispatcher.requestToolSwitch(.zoom)
            #expect(f.dispatcher.activeToolID == .pan, "the switch must wait for the handler")
            f.dispatcher.requestToolSwitch(.colorPicker)  // last request wins
        }
        f.dispatcher.pointerDown(input(.left))
        f.dispatcher.pointerUp(input(.left))
        #expect(f.dispatcher.activeToolID == .colorPicker)
        #expect(f.dispatcher.previousToolID == .pan)
        let entries = f.log.all
        let upIndex = entries.firstIndex(of: "pan:mouseUp(primary)")
        let deactivateIndex = entries.firstIndex(of: "pan:deactivate")
        #expect(upIndex != nil && deactivateIndex != nil, "log: \(entries)")
        if let upIndex, let deactivateIndex {
            #expect(upIndex < deactivateIndex)
        }
        #expect(zoom.calls.isEmpty, "the queued .zoom request lost to .colorPicker")
        #expect(f.stub(.colorPicker).calls == ["activate"])
    }

    @Test func requestedSwitchFromDragAppliesAfterGesture() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        f.stub(.pan).onMouseDragged = { _, _ in f.dispatcher.requestToolSwitch(.zoom) }
        f.dispatcher.pointerDown(input(.left))
        f.dispatcher.pointerDragged(input(.left))
        #expect(f.dispatcher.activeToolID == .pan)  // the gesture is still running
        f.dispatcher.pointerUp(input(.left))
        #expect(f.dispatcher.activeToolID == .zoom)
    }

    @Test func selectDuringGestureDeferred() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        f.dispatcher.pointerDown(input(.left))
        #expect(f.dispatcher.selectTool(.zoom) == true)
        #expect(f.dispatcher.activeToolID == .pan)
        f.dispatcher.pointerUp(input(.left))
        #expect(f.dispatcher.activeToolID == .zoom)
    }

    // MARK: - Context changes

    @Test func contextChangeCommitsIntoOldContext() {
        let f = fixture()
        let context2 = FakeToolContext()
        f.dispatcher.setContext(f.context)
        f.stub(.pan).hasPendingEdit = true
        f.dispatcher.setContext(context2)
        let contexts = f.stub(.pan).receivedContexts
        // [activate(ctx1), deactivate(ctx1), commit(ctx1), activate(ctx2)]
        let ids = contexts.compactMap { $0 }
        #expect(ids.count == 4)
        #expect(ids[0] == ObjectIdentifier(f.context))
        #expect(ids[1] == ObjectIdentifier(f.context))
        #expect(ids[2] == ObjectIdentifier(f.context))
        #expect(ids[3] == ObjectIdentifier(context2))
        #expect(f.stub(.pan).calls == ["activate", "deactivate", "commit", "activate"])
    }

    @Test func contextChangeMidGestureCancels() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        f.dispatcher.pointerDown(input(.left))
        f.dispatcher.setContext(FakeToolContext())
        #expect(f.stub(.pan).calls
                    == ["activate", "mouseDown(primary)", "cancel", "deactivate", "activate"],
                    "cancel into the old context, deactivate, activate in the new one")
        f.dispatcher.pointerUp(input(.left))
        #expect(f.stub(.pan).calls.count == 5, "the late mouseUp after a dropped gesture is ignored")
    }

    @Test func sameContextIsIgnored() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        f.dispatcher.setContext(f.context)
        #expect(f.stub(.pan).calls == ["activate"])
    }

    @Test func noContextIgnoresEvents() {
        let f = fixture()
        f.dispatcher.pointerDown(input(.left))
        f.dispatcher.pointerDragged(input(.left))
        f.dispatcher.pointerUp(input(.left))
        let event = ToolKeyEvent(key: .character("q"), characters: "q", modifiers: [], isRepeat: false)
        #expect(f.dispatcher.keyDown(event) == false)
        #expect(f.stub(.pan).calls.isEmpty)
        // Selection works without a context; activation waits for one.
        #expect(f.dispatcher.selectTool(.zoom) == true)
        #expect(f.stub(.zoom).calls.isEmpty)
        f.dispatcher.setContext(f.context)
        #expect(f.stub(.zoom).calls == ["activate"])
    }

    // MARK: - Shortcuts

    @Test func shortcutSelectsTool() {
        let f = fixture()
        #expect(f.dispatcher.handleShortcut(charactersIgnoringModifiers: "z", modifiers: [],
                                            isRepeat: false, timestamp: 0,
                                            keyWindow: .document, textInputHasFocus: false))
        #expect(f.dispatcher.activeToolID == .zoom)
        f.dispatcher.handleShortcut(charactersIgnoringModifiers: "h", modifiers: [],
                                    isRepeat: false, timestamp: 5,
                                    keyWindow: .document, textInputHasFocus: false)
        #expect(f.dispatcher.activeToolID == .pan)
        f.dispatcher.handleShortcut(charactersIgnoringModifiers: "s", modifiers: [],
                                    isRepeat: false, timestamp: 9,
                                    keyWindow: .document, textInputHasFocus: false)
        #expect(f.dispatcher.activeToolID == .rectangleSelect)
    }

    @Test func unimplementedKeyConsumed() {
        let f = fixture()
        #expect(f.dispatcher.handleShortcut(charactersIgnoringModifiers: "l", modifiers: [],
                                            isRepeat: false, timestamp: 0,
                                            keyWindow: .document, textInputHasFocus: false))
        #expect(f.dispatcher.activeToolID == .pan)
        #expect(f.log.all.isEmpty)
    }

    @Test func nonToolKeyNotConsumed() {
        let f = fixture()
        for key in ["x", "q", "["] {
            #expect(f.dispatcher.handleShortcut(charactersIgnoringModifiers: key, modifiers: [],
                                                isRepeat: false, timestamp: 0,
                                                keyWindow: .document,
                                                textInputHasFocus: false) == false,
                    "\(key) must not be consumed")
        }
    }

    /// 0019: the arrow keys arrive as `charactersIgnoringModifiers` `"\u{F70x}"` private
    /// use characters — never tool shortcuts, even though `s` etc. are members.
    @Test func functionKeyCharactersAreNotToolShortcuts() {
        for characters in ["\u{F702}", "\u{F703}", "\u{F700}", "\u{F701}"] {
            #expect(ToolShortcutResolver.toolKey(fromCharactersIgnoringModifiers: characters) == nil)
        }
    }

    @Test func autoRepeatIgnored() {
        let f = fixture()
        f.dispatcher.handleShortcut(charactersIgnoringModifiers: "s", modifiers: [],
                                    isRepeat: false, timestamp: 0,
                                    keyWindow: .document, textInputHasFocus: false)
        #expect(f.dispatcher.activeToolID == .rectangleSelect)
        // Holding S must not spin through the group.
        #expect(f.dispatcher.handleShortcut(charactersIgnoringModifiers: "s", modifiers: [],
                                            isRepeat: true, timestamp: 0.1,
                                            keyWindow: .document, textInputHasFocus: false))
        #expect(f.dispatcher.activeToolID == .rectangleSelect)
    }

    @Test func shortcutIgnoredDuringGesture() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        f.dispatcher.pointerDown(input(.left))
        #expect(f.dispatcher.handleShortcut(charactersIgnoringModifiers: "z", modifiers: [],
                                            isRepeat: false, timestamp: 0,
                                            keyWindow: .document, textInputHasFocus: false) == false)
        #expect(f.dispatcher.activeToolID == .pan)
    }

    @Test func shortcutIgnoredWhileToolCapturesKeyboard() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        f.stub(.pan).capturesKeyboard = true
        #expect(f.dispatcher.handleShortcut(charactersIgnoringModifiers: "z", modifiers: [],
                                            isRepeat: false, timestamp: 0,
                                            keyWindow: .document, textInputHasFocus: false) == false)
        // Typing still reaches the tool.
        f.dispatcher.insertText("z")
        #expect(f.stub(.pan).receivedTexts == ["z"])
    }

    @Test func shortcutIgnoredWithModifiersOrTextFocus() {
        let f = fixture()
        #expect(f.dispatcher.handleShortcut(charactersIgnoringModifiers: "z",
                                            modifiers: .command, isRepeat: false, timestamp: 0,
                                            keyWindow: .document, textInputHasFocus: false) == false)
        #expect(f.dispatcher.handleShortcut(charactersIgnoringModifiers: "z", modifiers: [],
                                            isRepeat: false, timestamp: 0,
                                            keyWindow: .document, textInputHasFocus: true) == false)
        #expect(f.dispatcher.handleShortcut(charactersIgnoringModifiers: "z", modifiers: [],
                                            isRepeat: false, timestamp: 0,
                                            keyWindow: .other, textInputHasFocus: false) == false)
        #expect(f.dispatcher.activeToolID == .pan)
        // Shift is allowed — it cycles the group backward.
        #expect(f.dispatcher.handleShortcut(charactersIgnoringModifiers: "s", modifiers: .shift,
                                            isRepeat: false, timestamp: 0,
                                            keyWindow: .document, textInputHasFocus: false))
        #expect(f.dispatcher.activeToolID == .magicWand)
    }

    // MARK: - Mirroring and forwarding

    @Test func pendingEditMirroring() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        var stateChanges = 0
        f.dispatcher.onStateChange = { stateChanges += 1 }
        #expect(f.dispatcher.hasPendingEdit == false)
        let pan = f.stub(.pan)
        pan.onMouseUp = { _, _ in pan.hasPendingEdit = true }
        f.dispatcher.pointerDown(input(.left))
        #expect(stateChanges == 0)
        f.dispatcher.pointerUp(input(.left))
        // The tool gained a pending edit inside mouseUp; the dispatcher noticed and says so.
        #expect(stateChanges == 1)
        #expect(f.dispatcher.hasPendingEdit == true)
        f.dispatcher.commitPendingEdit()
        #expect(pan.calls.contains("commit"))
    }

    @Test func optionsDidChangeForwarded() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        f.dispatcher.optionsDidChange()
        #expect(f.stub(.pan).calls == ["activate", "optionsDidChange"])
        f.dispatcher.setContext(nil)
        f.dispatcher.optionsDidChange()
        // Clearing the context deactivates the tool; the option change is not forwarded.
        #expect(f.stub(.pan).calls == ["activate", "optionsDidChange", "deactivate"])
    }

    @Test func cursorFromActiveTool() {
        let f = fixture()
        f.stub(.pan).cursorValue = .closedHand
        #expect(f.dispatcher.cursor(at: nil, modifiers: []) == .closedHand)
        f.dispatcher.selectTool(.zoom)
        f.stub(.zoom).cursorValue = .zoomOut
        #expect(f.dispatcher.cursor(at: CGPoint(x: 1, y: 2), modifiers: [.option]) == .zoomOut)
    }

    @Test func pointerMovedAndFlagsForwarded() {
        let f = fixture()
        f.dispatcher.setContext(f.context)
        f.dispatcher.pointerMoved(location: .zero, viewLocation: .zero, modifiers: [],
                                  timestamp: 1)
        // The stub uses the default no-op mouseMoved; flagsChanged invalidates the cursor.
        #expect(f.context.cursorInvalidations == 0)
        f.dispatcher.flagsChanged(.option)
        #expect(f.context.cursorInvalidations == 1)
        let moved = f.stub(.pan).receivedEvents
        #expect(moved.isEmpty, "default mouseMoved must not reach recorded overrides")
    }
}
