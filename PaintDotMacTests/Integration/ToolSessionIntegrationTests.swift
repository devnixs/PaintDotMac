import AppKit
import Foundation
import Testing
@testable import PaintDotMac

/// The tool session end-to-end without a window (spec 0006 *Test plan*, hosted): shortcut →
/// Zoom, click/Option-click through the dispatcher into the fake navigation, shortcut → Pan,
/// drag → pan calls, and `previousToolID`.
@MainActor
@Suite(.serialized)
struct ToolSessionIntegrationTests {
    @Test func zoomThenPanSession() throws {
        let suiteName = "ToolSessionIntegrationTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: UserDefaults(suiteName: suiteName)!)
        let context = FakeToolContext()
        model.dispatcher.setContext(context)
        #expect(model.activeToolID == .pan)

        // "z" selects the Zoom tool.
        #expect(model.dispatcher.handleShortcut(
            charactersIgnoringModifiers: "z", modifiers: [], isRepeat: false,
            timestamp: 0, keyWindow: .document, textInputHasFocus: false))
        #expect(model.activeToolID == .zoom)
        #expect(context.nav.setZoomCalls.isEmpty)

        // Click at view (100, 200) → zoom 1.5 anchored there.
        let down = CGPoint(x: 100, y: 200)
        click(in: model, at: down, context: context)
        #expect(context.nav.setZoomCalls == [ZoomCall(zoom: 1.5, anchor: down)])

        // Option-click → 2/3 (the fake transform stays at 1.0).
        click(in: model, at: down, context: context, modifiers: [.option])
        #expect(context.nav.setZoomCalls.count == 2)
        #expect(context.nav.setZoomCalls.last?.zoom == 2.0 / 3.0)

        // "h" → Pan; a drag pans.
        #expect(model.dispatcher.handleShortcut(
            charactersIgnoringModifiers: "h", modifiers: [], isRepeat: false,
            timestamp: 10, keyWindow: .document, textInputHasFocus: false))
        #expect(model.activeToolID == .pan)
        #expect(model.previousToolID == .zoom)
        model.dispatcher.pointerDown(pointerInput(.left, at: CGPoint(x: 100, y: 100), context: context))
        model.dispatcher.pointerDragged(pointerInput(.left, at: CGPoint(x: 160, y: 120), context: context, dragged: true))
        model.dispatcher.pointerUp(pointerInput(.left, at: CGPoint(x: 160, y: 120), context: context))
        // The tool replays the final pointer position before ending (as in PanToolTests).
        #expect(context.nav.panCalls
                    == [.begin(CGPoint(x: 100, y: 100)), .continue(CGPoint(x: 160, y: 120)),
                        .continue(CGPoint(x: 160, y: 120)), .end])
    }

    private func click(in model: AppModel, at viewLocation: CGPoint, context: FakeToolContext,
                       modifiers: ToolModifiers = []) {
        let input = pointerInput(.left, at: viewLocation, context: context, modifiers: modifiers)
        model.dispatcher.pointerDown(input)
        model.dispatcher.pointerUp(input)
    }

    /// The window's become-main/close notifications drive the model's active session
    /// (spec 0006: `windowDidBecomeMain` promotes, `windowWillClose` retires). The
    /// notification is posted by hand: a headless window never becomes main.
    @Test func windowMainAndClosePathsDriveTheActiveSession() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { HeadlessAssertions.closeAllDocuments(); HeadlessAssertions.noVisibleWindows(); fixtures.removeAll() }
            let url = try fixtures.writePNG(named: "session-lifecycle.png", width: 64, height: 64) { _, _ in
                ColorRGBA8(red: 1, green: 1, blue: 1)
            }
            let harness = try await DocumentHarness.open(url)

            let session = try #require(harness.windowController.toolSession)
            #expect(harness.appModel.activeSession !== session)

            NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification,
                                            object: harness.window)
            pumpMainRunLoop()
            #expect(harness.appModel.activeSession === session,
                    "become-main promotes the window's own session")

            harness.close()
            harness.discardAppModelSuite()
            pumpMainRunLoop()
            #expect(harness.appModel.activeSession == nil,
                    "the close path retires the window's session")
            HeadlessAssertions.closeAllDocuments()
            HeadlessAssertions.noVisibleWindows()
        }
    }

    private func pointerInput(_ button: ToolPhysicalButton, at viewLocation: CGPoint,
                              context: FakeToolContext, modifiers: ToolModifiers = [],
                              dragged: Bool = false) -> ToolPointerInput {
        ToolPointerInput(
            physicalButton: button,
            location: context.nav.transform.viewToCanvas(viewLocation),
            viewLocation: viewLocation,
            modifiers: modifiers,
            clickCount: dragged ? 0 : 1,
            pressure: 1.0,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
    }
}
