import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PaintDotMac

/// The Color Picker end-to-end (spec 0012 *Test plan*), headless: documents opened through
/// `DocumentHarness` (never shown), keys through `harness.shortcut`, canvas input through
/// `harness.clickCanvas`, the History panel's model, and TOOL-C persistence through a
/// fresh `AppModel` on the same defaults suite (what a relaunch reads). Fixture: a
/// 200×100 PNG written at test time — left half opaque `#FF0000`, right half opaque
/// `#0000FF`.
@MainActor
@Suite(.serialized)
struct ColorPickerIntegrationTests {
    private let red = ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
    private let blue = ColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255)

    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    private func openFixture(_ fixtures: FixtureFiles) async throws -> DocumentHarness {
        let url = try fixtures.writePNG(named: "picker-fixture.png", width: 200, height: 100) { x, _ in
            x < 100 ? red : blue
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
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 320)
        hosting.layoutSubtreeIfNeeded()
        pumpMainRunLoop()
        return hosting
    }

    /// The options bar's accessibility identifiers visible in the window's content view.
    private func optionIdentifiers(_ harness: DocumentHarness) -> Set<String> {
        guard let content = harness.window.contentView else { return [] }
        pumpMainRunLoop()
        return AX.withAccessibilityClient { AX.identifiers(inRoot: content) }
    }

    @Test func kKeyActivatesColorPicker() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }

            #expect(harness.shortcut("k"))
            #expect(harness.appModel.activeToolID == .colorPicker)
            let hosting = hostedToolsPanel(harness.appModel)
            #expect(AX.withAccessibilityClient
                        { AX.isSelected(inRoot: hosting, identifier: "tool.colorPicker") },
                    "the Tools panel button `tool.colorPicker` carries the selected trait")
            // The crosshair reaches the cursor machinery (T-14 / 0006's mapping).
            #expect(harness.appModel.dispatcher.cursor(at: .zero, modifiers: []) == .crosshair)
            // The options bar shows the three controls.
            let identifiers = optionIdentifiers(harness)
            for id in ["toolOptions.samplingSize", "toolOptions.samplingMode",
                       "toolOptions.afterClick"] {
                #expect(identifiers.contains(id), "accessibility element \(id)")
            }
        }
    }

    @Test func clickPicksPrimaryAndRightClickPicksSecondary() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }

            #expect(harness.shortcut("k"))
            harness.perform(#selector(DocumentWindowController.actualSize(_:)))
            #expect(harness.appModel.colors.primary == .black
                        && harness.appModel.colors.secondary == .white,
                    "the default pair before picking")

            harness.clickCanvas(at: harness.viewPoint(forImagePoint: CGPoint(x: 50, y: 50)))
            #expect(harness.appModel.colors.primary == red, "left click sets primary #FF0000FF")
            #expect(harness.appModel.colors.secondary == .white, "the other color is unchanged")

            harness.clickCanvas(at: harness.viewPoint(forImagePoint: CGPoint(x: 150, y: 50)),
                                button: .right)
            #expect(harness.appModel.colors.secondary == blue,
                    "right click sets secondary #0000FFFF")
            #expect(harness.appModel.colors.primary == red, "primary keeps the first pick")
        }
    }

    @Test func pickingAddsNoHistoryRow() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }

            #expect(harness.shortcut("k"))
            harness.clickCanvas(at: harness.viewPoint(forImagePoint: CGPoint(x: 50, y: 50)))
            harness.clickCanvas(at: harness.viewPoint(forImagePoint: CGPoint(x: 150, y: 50)),
                                button: .right)

            #expect(harness.appModel.historyPanel.model.rows.map(\.name) == ["Open Image"],
                    "picking adds no History row")
            #expect(harness.window.undoManager?.canUndo == false, "Undo is disabled")
            #expect(harness.isEnabled(NSSelectorFromString("undo:")) == false)
            #expect(!harness.document.isDocumentEdited,
                    "edited state follows history (0008), so closing never prompts")
            // The pixels are untouched: the fixture colors still hold.
            #expect(harness.document.image.layers[0].surface
                        .pixel(at: PixelPoint(x: 50, y: 50)) == red)
        }
    }

    @Test func switchToPreviousToolReturnsToPaintbrush() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }

            #expect(harness.shortcut("b"))
            #expect(harness.appModel.activeToolID == .paintbrush)
            #expect(harness.shortcut("k"))
            #expect(harness.appModel.activeToolID == .colorPicker)

            // The options bar's "After click:" binding writes exactly this (TOOL-C):
            // the same `toolOptions` store the SwiftUI Picker's setter calls.
            harness.appModel.toolOptions.setValue(
                ColorPickerAfterClick.switchToPreviousTool, for: ColorPickerTool.afterClickKey)
            #expect(harness.appModel.toolOptions.value(ColorPickerTool.afterClickKey)
                        == .switchToPreviousTool)

            harness.clickCanvas(at: harness.viewPoint(forImagePoint: CGPoint(x: 50, y: 50)))
            pumpMainRunLoop()
            #expect(harness.appModel.colors.primary == red, "the click still picked")
            #expect(harness.appModel.activeToolID == .paintbrush,
                    "\"Switch to previous tool\" returns to the Paintbrush")

            // A new AppModel on the same suite is what a relaunch reads (TOOL-C).
            let relaunched = AppModel(defaults: harness.appModel.defaultsForTests)
            #expect(relaunched.toolOptions.value(ColorPickerTool.afterClickKey)
                        == .switchToPreviousTool)
        }
    }
}
