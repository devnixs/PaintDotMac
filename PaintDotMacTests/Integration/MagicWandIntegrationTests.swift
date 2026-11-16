import AppKit
import SwiftUI
import Testing

@testable import PaintDotMac

/// The Magic Wand through the real document, router, options bar, status bar, and History
/// (spec 0016 *Test plan*, headless): fixtures written at test time, canvas input through
/// `harness.clickCanvas`, tool changes through `harness.shortcut`. Each test ends with
/// `HeadlessAssertions.closeAllDocuments()` and `noVisibleWindows()`.
@MainActor
@Suite(.serialized)
struct MagicWandIntegrationTests {
    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    private func finish(_ harness: DocumentHarness) {
        harness.close()
        harness.discardAppModelSuite()
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    private func openFixture(_ fixtures: FixtureFiles, name: String, width: Int, height: Int,
                             pixel: @escaping (Int, Int) -> ColorRGBA8) async throws
        -> DocumentHarness
    {
        AppSettings().measurementUnit = .pixels
        let url = try fixtures.writePNG(named: name, width: width, height: height,
                                        pixel: pixel)
        let harness = try await DocumentHarness.open(url)
        harness.perform(#selector(DocumentWindowController.actualSize(_:)))
        harness.window.setContentSize(NSSize(width: 1000, height: 800))
        harness.document.undoBridge.undoManager.groupsByEvent = false
        harness.appModel.setActiveSession(harness.windowController.toolSession)
        pumpMainRunLoop()
        return harness
    }

    private func optionIdentifiers(_ harness: DocumentHarness) -> Set<String> {
        guard let content = harness.window.contentView else { return [] }
        pumpMainRunLoop()
        return AX.withAccessibilityClient { AX.identifiers(inRoot: content) }
    }

    private func optionValue(_ harness: DocumentHarness, identifier: String) -> String? {
        guard let content = harness.window.contentView else { return nil }
        pumpMainRunLoop()
        return AX.withAccessibilityClient {
            guard let item = AX.first(inRoot: content, identifier: identifier) else { return nil }
            return AX.value(of: item)
        }
    }

    /// The element's raw accessibility value, stringified — the numeric value a
    /// SwiftUI Slider vends (an `NSNumber`, not the `NSString` `AX.value` reads).
    private func rawOptionValue(_ harness: DocumentHarness, identifier: String) -> String? {
        guard let content = harness.window.contentView else { return nil }
        pumpMainRunLoop()
        return AX.withAccessibilityClient {
            var found: String?
            AX.walk(content) { object in
                guard AX.identifier(of: object) == identifier else { return }
                let selector = NSSelectorFromString("accessibilityValue")
                guard found == nil, object.responds(to: selector),
                      let raw = object.perform(selector)?.takeUnretainedValue() else { return }
                found = String(describing: raw)
            }
            return found
        }
    }

    private func historyNames(_ harness: DocumentHarness) -> [String] {
        harness.appModel.historyPanel.model.rows.map(\.name)
    }

    /// White 200 × 200 with one black square at (50, 50, 100, 100).
    private func f1Pixel(_ x: Int, _ y: Int) -> ColorRGBA8 {
        (50..<150).contains(x) && (50..<150).contains(y) ? .black : .white
    }

    /// White 200 × 200 with black squares at (20, 20, 40, 40) and (140, 140, 40, 40).
    private func f2Pixel(_ x: Int, _ y: Int) -> ColorRGBA8 {
        let inFirst = (20..<60).contains(x) && (20..<60).contains(y)
        let inSecond = (140..<180).contains(x) && (140..<180).contains(y)
        return inFirst || inSecond ? .black : .white
    }

    /// S from the Paintbrush cycles the whole group onto the Magic Wand (D-13).
    private func selectWand(_ harness: DocumentHarness) {
        #expect(harness.shortcut("b"))
        #expect(harness.appModel.activeToolID == .paintbrush)
        #expect(harness.shortcut("s"))
        #expect(harness.appModel.activeToolID == .rectangleSelect)
        #expect(harness.shortcut("s"))
        #expect(harness.appModel.activeToolID == .lassoSelect)
        #expect(harness.shortcut("s"))
        #expect(harness.appModel.activeToolID == .ellipseSelect)
        #expect(harness.shortcut("s"))
        #expect(harness.appModel.activeToolID == .magicWand)
        pumpMainRunLoop()
    }

    // MARK: Tests

    @Test func sKeyCyclesToMagicWand() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "wand-cycle.png",
                                                width: 200, height: 150) { _, _ in .white }
            defer { finish(harness) }

            selectWand(harness)

            let identifiers = optionIdentifiers(harness)
            #expect(identifiers.contains("toolOptions.selectionMode"))
            #expect(identifiers.contains("toolOptions.floodMode"))
            #expect(identifiers.contains("toolOptions.tolerance"))
            #expect(identifiers.contains("toolOptions.samplingMode"))
            #expect(!identifiers.contains("toolOptions.selectionQuality"),
                    "the wand result is pixel-aligned; no clipping picker (0016)")
            #expect(!identifiers.contains("toolOptions.drawMode"))
            #expect(optionValue(harness, identifier: "toolOptions.floodMode") == "Contiguous")
            // A SwiftUI Slider vends its *numeric* AX value (the 0007 discovery — string
            // AX values only come from fields/pickers), so the slider answers 50 here and
            // the "50%" string is the trailing readout.
            #expect(rawOptionValue(harness, identifier: "toolOptions.tolerance") == "50")
            #expect(optionValue(harness, identifier: "toolOptions.samplingMode") == "Layer")
            #expect(optionValue(harness, identifier: "toolOptions.selectionMode") == "Replace")

            let hosting = NSHostingView(rootView: AnyView(ToolsPanelView(model: harness.appModel)))
            hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
            hosting.layoutSubtreeIfNeeded()
            pumpMainRunLoop()
            #expect(AX.isSelected(inRoot: hosting, identifier: "tool.magicWand"),
                    "the Tools panel highlights Magic Wand")
        }
    }

    @Test func clickSelectsSquareAndUndoes() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "wand-f1.png",
                                                width: 200, height: 200, pixel: f1Pixel)
            defer { finish(harness) }

            selectWand(harness)
            harness.clickCanvas(at: harness.viewPoint(forImagePoint: CGPoint(x: 100.5, y: 100.5)))
            pumpMainRunLoop()

            #expect(historyNames(harness).last == "Magic Wand")
            #expect(harness.statusBar.selectionSizeText == "100 × 100")
            #expect(harness.document.undoBridge.undoManager.undoMenuItemTitle
                        == "Undo Magic Wand")

            harness.perform(NSSelectorFromString("undo:"))
            pumpMainRunLoop()
            #expect(harness.statusBar.selectionSizeText == "", "undo clears the selection")
            #expect(harness.document.undoBridge.state.selection == nil)

            harness.perform(NSSelectorFromString("redo:"))
            pumpMainRunLoop()
            #expect(harness.statusBar.selectionSizeText == "100 × 100", "redo re-applies")
            #expect(harness.document.undoBridge.state.selection?.bounds
                        == PixelRect(x: 50, y: 50, width: 100, height: 100))
        }
    }

    @Test func shiftClickSelectsGlobally() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "wand-f2.png",
                                                width: 200, height: 200, pixel: f2Pixel)
            defer { finish(harness) }

            selectWand(harness)
            let point = harness.viewPoint(forImagePoint: CGPoint(x: 40.5, y: 40.5))
            harness.clickCanvas(at: point)
            pumpMainRunLoop()
            #expect(harness.statusBar.selectionSizeText == "40 × 40", "contiguous first")

            harness.clickCanvas(at: point, modifiers: [.shift])
            pumpMainRunLoop()
            #expect(harness.statusBar.selectionSizeText == "160 × 160",
                    "Shift-click selects both squares")
            // The Flood mode option is unchanged by the Shift modifier.
            #expect(harness.appModel.toolOptions.value(
                FloodToolOptions.floodMode(for: .magicWand)) == .contiguous)
        }
    }

    @Test func commandClickAddsRegion() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "wand-f2-add.png",
                                                width: 200, height: 200, pixel: f2Pixel)
            defer { finish(harness) }

            selectWand(harness)
            harness.clickCanvas(
                at: harness.viewPoint(forImagePoint: CGPoint(x: 40.5, y: 40.5)))
            pumpMainRunLoop()
            harness.clickCanvas(
                at: harness.viewPoint(forImagePoint: CGPoint(x: 160.5, y: 160.5)),
                modifiers: [.command])
            pumpMainRunLoop()

            #expect(historyNames(harness).filter { $0 == "Magic Wand" }.count == 2)
            #expect(harness.statusBar.selectionSizeText == "160 × 160")
            let selection = try #require(harness.document.undoBridge.state.selection)
            #expect(selection.mask.bounds
                        == PixelRect(x: 20, y: 20, width: 160, height: 160))
            // Both squares are in the mask, the white gap is not.
            #expect(selection.mask.coverage(x: 40, y: 40) == 255)
            #expect(selection.mask.coverage(x: 160, y: 160) == 255)
            #expect(selection.mask.coverage(x: 100, y: 100) == 0)
        }
    }

    @Test func optionsBarAndPersistence() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "wand-persist.png",
                                                width: 200, height: 150) { _, _ in .white }
            defer { finish(harness) }

            selectWand(harness)
            // The same writes the options bar's bindings make (TOOL-C).
            let options = harness.appModel.toolOptions
            options.setValue(FloodMode.global, for: FloodToolOptions.floodMode(for: .magicWand))
            options.setValue(0, for: FloodToolOptions.tolerance(for: .magicWand))
            options.setValue(SamplingMode.image,
                             for: FloodToolOptions.samplingMode(for: .magicWand))
            pumpMainRunLoop()
            #expect(optionValue(harness, identifier: "toolOptions.floodMode") == "Global")
            #expect(rawOptionValue(harness, identifier: "toolOptions.tolerance") == "0")
            #expect(optionValue(harness, identifier: "toolOptions.samplingMode") == "Image")

            // A fresh AppModel on the same suite is what a relaunch reads (TOOL-C).
            let relaunched = AppModel(defaults: harness.appModel.defaultsForTests)
            #expect(relaunched.toolOptions.value(
                FloodToolOptions.floodMode(for: .magicWand)) == .global)
            #expect(relaunched.toolOptions.value(
                FloodToolOptions.tolerance(for: .magicWand)) == 0)
            #expect(relaunched.toolOptions.value(
                FloodToolOptions.samplingMode(for: .magicWand)) == .image)
        }
    }
}
