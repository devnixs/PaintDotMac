import AppKit
import SwiftUI
import Testing
@testable import PaintDotMac

/// The floating Tools panel and single-key shortcuts in the real app wiring (spec 0006
/// *Test plan*, headless): documents opened through `DocumentHarness`, panels and shortcuts
/// driven through the app's one entry points, windows never shown.
@MainActor
@Suite(.serialized)
struct ToolsPanelIntegrationTests {
    /// Windows whose teardown the process must never attempt (see
    /// `shortcutsIgnoredInTextField`).
    private static var offscreenFieldEditorWindows: [NSWindow] = []
    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    private func openFixture(_ fixtures: FixtureFiles, named name: String) async throws -> DocumentHarness {
        let url = try fixtures.writePNG(named: name, width: 4000, height: 2000) { _, _ in
            ColorRGBA8(red: 40, green: 120, blue: 200)
        }
        let harness = try await DocumentHarness.open(url)
        harness.window.setContentSize(NSSize(width: 1000, height: 800))
        return harness
    }

    private func finish(_ harness: DocumentHarness) {
        harness.close()
        harness.discardAppModelSuite()
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    private func hostedToolsPanel(_ model: AppModel) -> NSHostingView<AnyView> {
        let hosting = NSHostingView(rootView: AnyView(ToolsPanelView(model: model)))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        hosting.layoutSubtreeIfNeeded()
        pumpMainRunLoop()
        return hosting
    }

    /// The window's `toolOptions.tool` accessibility value (the options bar's Tool chooser).
    private func optionsBarToolValue(_ harness: DocumentHarness) -> String? {
        guard let content = harness.window.contentView else { return nil }
        pumpMainRunLoop()
        return AX.withAccessibilityClient {
            guard let element = AX.first(inRoot: content, identifier: "toolOptions.tool")
            else { return nil }
            return AX.value(of: element)
        }
    }

    @Test func showsImplementedToolsOnly() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, named: "tools-panel.png")
            defer { finish(harness) }

            let hosting = hostedToolsPanel(harness.appModel)
            let identifiers = AX.withAccessibilityClient { AX.identifiers(inRoot: hosting) }
            #expect(identifiers.contains("tool.zoom"))
            #expect(identifiers.contains("tool.pan"))
            #expect(identifiers.contains("toolsPanel"))
            #expect(!identifiers.contains("tool.recolor"), "unimplemented tools never appear")
            #expect(!identifiers.contains("tool.cloneStamp"))
        }
    }

    @Test func clickingToolSelectsIt() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, named: "tools-panel.png")
            defer { finish(harness) }

            let hosting = hostedToolsPanel(harness.appModel)
            #expect(AX.pressButton(inRoot: hosting, identifier: "tool.zoom"),
                    "the accessibility press action fires the button")
            pumpMainRunLoop()
            #expect(harness.appModel.activeToolID == .zoom)
            pumpMainRunLoop()
            #expect(AX.isSelected(inRoot: hosting, identifier: "tool.zoom"),
                    "the pressed button carries the selected trait")
            #expect(optionsBarToolValue(harness) == "Zoom")

            #expect(AX.pressButton(inRoot: hosting, identifier: "tool.pan"))
            pumpMainRunLoop()
            #expect(harness.appModel.activeToolID == .pan)
            #expect(optionsBarToolValue(harness) == "Pan")
        }
    }

    @Test func toolKeysSelectTools() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, named: "tools-panel.png")
            defer { finish(harness) }

            #expect(harness.shortcut("z"))
            #expect(harness.appModel.activeToolID == .zoom)
            #expect(harness.shortcut("h"))
            #expect(harness.appModel.activeToolID == .pan)
            // "l" (Clone Stamp, unimplemented) is consumed silently.
            #expect(harness.shortcut("l"))
            #expect(harness.appModel.activeToolID == .pan)
            // "q" is not a tool key.
            #expect(!harness.shortcut("q"))
        }
    }

    @Test func shortcutsWorkWithPanelKey() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, named: "tools-panel.png")
            defer { finish(harness) }

            let panelController = PanelController(model: harness.appModel)
            defer { panelController.panels.values.forEach { $0.orderOut(nil) } }
            let toolsPanel = try #require(panelController.panels[.tools])
            #expect(harness.shortcut("h", in: toolsPanel))
            #expect(harness.appModel.activeToolID == .pan)
            #expect(harness.shortcut("z", in: toolsPanel))
            #expect(harness.appModel.activeToolID == .zoom)
        }
    }

    /// The PRD §5.12 "no text field has focus" rule must hold on its own: a focused text
    /// field inside the key *document* window suppresses tool keys even though the
    /// window-kind rule would let them through (the `shortcutsIgnoredInTextField` window is
    /// `.other`, so its suppression could ride on the window rule alone). Handing first
    /// responder back to the canvas — the options bar's `onEndEditing` story — restores them.
    @Test func shortcutsIgnoredInDocumentWindowTextField() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, named: "tools-panel.png")
            defer { finish(harness) }

            let openedWithPan = harness.appModel.activeToolID
            #expect(harness.shortcut("h"))
            #expect(openedWithPan == .pan)

            let window = harness.window
            let identifier = window.identifier?.rawValue
            let documentIdentifier = DocumentWindowController.windowIdentifier.rawValue
            #expect(identifier == documentIdentifier)
            let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 150, height: 24))
            window.contentView?.addSubview(field)
            window.makeFirstResponder(field)  // installs the shared field editor
            let suppressed = harness.shortcut("z", in: window)
            #expect(!suppressed,
                    "a focused field editor in the key document window suppresses tool keys")
            let duringField = harness.appModel.activeToolID
            #expect(duringField == .pan)

            // Back to the canvas (what `onEndEditing` does): the CanvasView is deliberately
            // not text input, and closing the window no longer tears down one that owns the
            // field editor (`shortcutsIgnoredInTextField`'s crash postmortem).
            window.makeFirstResponder(harness.canvasView)
            let afterCanvas = harness.shortcut("z", in: window)
            #expect(afterCanvas)
            let toolAfterCanvas = harness.appModel.activeToolID
            #expect(toolAfterCanvas == .zoom)
        }
    }

    @Test func shortcutsIgnoredInTextField() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, named: "tools-panel.png")
            defer { finish(harness) }

            #expect(harness.shortcut("h"))
            #expect(harness.appModel.activeToolID == .pan)

            // An offscreen window of another kind with a focused text field: no tool keys.
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 150, height: 24))
            other.contentView?.addSubview(field)
            other.makeFirstResponder(field)
            #expect(!harness.shortcut("z", in: other), "no tool keys while a text field has focus")
            #expect(harness.appModel.activeToolID == .pan)
            // The window is deliberately never closed: tearing down an offscreen window
            // that owns the shared field editor corrupts AppKit's responder/autorelease
            // state and crashes the test host during a later suite (per-test bisect:
            // 3/3 crash with `other.close()` here, 0/3 without it in the
            // ToolsPanel+ZoomPan pair). It stays headless (never ordered front), so
            // `noVisibleWindows` holds; the stash keeps it alive to process exit, which
            // a short-lived test host can never observe.
            Self.offscreenFieldEditorWindows.append(other)
        }
    }
}
