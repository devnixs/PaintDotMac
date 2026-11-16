import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import PaintDotMac

/// Headless integration tests for zoom, pan, and the status bar (spec 0004 *Test plan*):
/// fixtures opened through `DocumentHarness`, windows built but never shown, content size
/// 1000×800. Zoom commands go through `perform`, reaching `DocumentWindowController` the way
/// the menu does. Each test resets the shared unit preference to Pixels (AGENTS.md:
/// preferences only through `AppDefaults.shared`, a throwaway suite in test-host mode).
@MainActor
@Suite(.serialized)
struct ZoomPanStatusBarIntegrationTests {
    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    /// Waits for the shared-unit notification to reach another window's model (bounded).
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func resetUnit() {
        AppSettings().measurementUnit = .pixels
    }

    private func openFixture(_ fixtures: FixtureFiles, name: String,
                             width: Int, height: Int, dpi: Int? = nil,
                             contentSize: NSSize? = NSSize(width: 1000, height: 800)) async throws -> DocumentHarness {
        var properties: [CFString: Any] = [:]
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        let url = try fixtures.writePNG(named: name, width: width, height: height,
                                        pixel: { _, _ in ColorRGBA8(red: 10, green: 20, blue: 30) },
                                        properties: properties)
        let harness = try await DocumentHarness.open(url)
        if let contentSize {
            harness.window.setContentSize(contentSize)
        }
        return harness
    }

    /// The percent number the status bar shows, parsed from `zoomText`.
    private func zoomPercent(_ harness: DocumentHarness) -> Int? {
        Int(harness.statusBar.zoomText.dropLast())
    }

    // MARK: - Status bar fields

    @Test func statusBarFields() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            resetUnit()

            let harness = try await openFixture(fixtures, name: "fields.png",
                                                width: 4000, height: 2000)
            let statusBar = harness.statusBar
            #expect(statusBar.imageSizeText == "4000 × 2000")
            #expect(statusBar.selectionSizeText == "")
            #expect(statusBar.zoomText.hasSuffix("%"))
            #expect(statusBar.unit == .pixels)

            // The hosted SwiftUI view exposes the accessibility identifiers VoiceOver and
            // later specs rely on. SwiftUI only vends its accessibility elements while an
            // accessibility client is active — exactly what the `AXEnhancedUserInterface`
            // flag signals — so set it for the lookup (restored after), as VoiceOver does.
            let content = try #require(harness.window.contentView)
            let hosting = try #require(
                subviews(of: content).first { $0 is NSHostingView<StatusBarView> },
                "the content view has no hosted status bar"
            )
            let identifiers = AX.withAccessibilityClient { accessibilityIdentifiers(of: hosting) }
            for id in ["statusBar.cursor", "statusBar.selectionSize", "statusBar.imageSize",
                       "statusBar.zoom", "statusBar.units"] {
                #expect(identifiers.contains(id), "missing accessibility element \(id): \(identifiers)")
            }
            cleanup()
        }
    }

    // MARK: - Open state, Actual Size, Zoom to Window

    @Test func opensFittedAndActualSize() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            resetUnit()

            // No resize yet: assert the state the window opened in (CAN-6, D-29).
            let harness = try await openFixture(fixtures, name: "fitted.png",
                                                width: 4000, height: 2000, contentSize: nil)
            let canvas = harness.canvasView
            // The open zoom is the fit for the canvas drawable at open time, below 100 %,
            // recomputed here from the transform's own geometry (independent oracle).
            let open = canvas.transform
            let openFit = min(1.0, Double(open.drawableSize.width) / 4000.0,
                              Double(open.drawableSize.height) / 2000.0)
            #expect(open.zoom == openFit)
            #expect(open.zoom < 1)
            let openPercent = try #require(zoomPercent(harness))
            #expect(openPercent < 100)

            // At 1000×800: Zoom to Window → Actual Size (100 %) → Zoom to Window returns
            // the same fitted zoom exactly.
            harness.window.setContentSize(NSSize(width: 1000, height: 800))
            harness.perform(#selector(DocumentWindowController.zoomToWindow(_:)))
            let z0 = canvas.transform.zoom
            #expect(z0 < 1)
            #expect(canvas.transform.center == CGPoint(x: 2000, y: 1000))
            harness.perform(#selector(DocumentWindowController.actualSize(_:)))
            #expect(harness.statusBar.zoomText == "100%")
            harness.perform(#selector(DocumentWindowController.zoomToWindow(_:)))
            #expect(canvas.transform.zoom == z0)
            cleanup()
        }
    }

    @Test func smallImageOpensAtActualSize() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            resetUnit()

            let harness = try await openFixture(fixtures, name: "small.png",
                                                width: 64, height: 64)
            #expect(harness.statusBar.zoomText == "100%")
            cleanup()
        }
    }

    // MARK: - Zoom commands step the presets

    @Test func zoomCommandsStepPresets() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            resetUnit()

            let harness = try await openFixture(fixtures, name: "steps.png",
                                                width: 4000, height: 2000)
            @MainActor func zoomText() -> String { harness.statusBar.zoomText }
            harness.perform(#selector(DocumentWindowController.actualSize(_:)))
            #expect(zoomText() == "100%")
            harness.perform(#selector(DocumentWindowController.zoomIn(_:)))
            #expect(zoomText() == "150%")
            harness.perform(#selector(DocumentWindowController.zoomIn(_:)))
            #expect(zoomText() == "200%")
            harness.perform(#selector(DocumentWindowController.zoomOut(_:)))
            #expect(zoomText() == "150%")
            harness.perform(#selector(DocumentWindowController.zoomOut(_:)))
            #expect(zoomText() == "100%")
            harness.perform(#selector(DocumentWindowController.zoomOut(_:)))
            #expect(zoomText() == "67%")
            harness.perform(#selector(DocumentWindowController.zoomOut(_:)))
            #expect(zoomText() == "50%")
            harness.perform(#selector(DocumentWindowController.zoomOut(_:)))
            #expect(zoomText() == "33%")
            harness.perform(#selector(DocumentWindowController.zoomIn(_:)))
            #expect(zoomText() == "50%")
            cleanup()
        }
    }

    @Test func viewMenuActionsZoom() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            resetUnit()

            let harness = try await openFixture(fixtures, name: "menu.png",
                                                width: 4000, height: 2000)
            let viewMenu = try #require(
                MainMenu.make().items.first { $0.identifier == MainMenu.viewMenuIdentifier }?.submenu
            )
            let zoomActions: [Selector] = [MainMenu.zoomInAction, MainMenu.zoomOutAction,
                                           MainMenu.zoomToWindowAction, MainMenu.zoomToSelectionAction,
                                           MainMenu.actualSizeAction]
            var itemsByAction: [String: NSMenuItem] = [:]
            for item in viewMenu.items {
                if let action = item.action, zoomActions.contains(action),
                   itemsByAction[NSStringFromSelector(action)] == nil {
                    // The menu finds the document window's controller (first responder chain).
                    #expect(harness.target(for: action) === harness.windowController,
                            "no target for \(NSStringFromSelector(action))")
                    itemsByAction[NSStringFromSelector(action)] = item
                }
            }
            #expect(itemsByAction.count == 5,
                    "Zoom to Selection (0014) joins the routed View actions")

            @MainActor func performItem(_ selector: String) throws {
                let item = try #require(itemsByAction[selector], "no menu item for \(selector)")
                harness.perform(try #require(item.action))
            }
            @MainActor func zoomText() -> String { harness.statusBar.zoomText }
            try performItem("actualSize:")
            #expect(zoomText() == "100%")
            try performItem("zoomIn:")
            #expect(zoomText() == "150%")
            try performItem("zoomOut:")
            #expect(zoomText() == "100%")
            try performItem("zoomToWindow:")
            let canvas = harness.canvasView
            let fit = min(1.0, Double(canvas.transform.drawableSize.width) / 4000.0,
                          Double(canvas.transform.drawableSize.height) / 2000.0)
            #expect(canvas.transform.zoom == fit)
            try performItem("actualSize:")
            #expect(zoomText() == "100%")
            cleanup()
        }
    }

    // MARK: - Limits

    @Test func zoomInDisabledAtMaximum() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            resetUnit()

            let harness = try await openFixture(fixtures, name: "limits.png",
                                                width: 4000, height: 2000)
            let zoomIn = #selector(DocumentWindowController.zoomIn(_:))
            let zoomOut = #selector(DocumentWindowController.zoomOut(_:))
            harness.perform(#selector(DocumentWindowController.actualSize(_:)))
            for _ in 0..<11 { harness.perform(zoomIn) }  // 100 % → 3200 % is 11 up-stops
            #expect(harness.statusBar.zoomText == "3200%")
            #expect(harness.isEnabled(zoomIn) == false)
            #expect(harness.isEnabled(zoomOut) == true)
            // Invoking anyway is a no-op (disabled item guard + clamp).
            harness.perform(zoomIn)
            #expect(harness.statusBar.zoomText == "3200%")

            harness.perform(#selector(DocumentWindowController.zoomToWindow(_:)))
            var steps = 0
            while harness.isEnabled(zoomOut), steps < 30 {
                harness.perform(zoomOut)
                steps += 1
            }
            #expect(harness.statusBar.zoomText == "1%")
            #expect(harness.isEnabled(zoomOut) == false)
            cleanup()
        }
    }

    // MARK: - Scroll and Space

    @Test func commandScrollZooms() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            resetUnit()

            let harness = try await openFixture(fixtures, name: "cmdscroll.png",
                                                width: 4000, height: 2000)
            harness.perform(#selector(DocumentWindowController.actualSize(_:)))
            harness.scroll(dx: 0, dy: 50, precise: false, modifiers: .command)
            #expect(harness.canvasView.transform.zoom != 1)
            cleanup()
        }
    }

    @Test func pinchZoomsAroundPointer() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            resetUnit()

            let harness = try await openFixture(fixtures, name: "pinch.png",
                                                width: 4000, height: 2000)
            let canvas = harness.canvasView
            harness.perform(#selector(DocumentWindowController.actualSize(_:)))
            // Anchor away from the view center: the canvas point under the pointer must
            // stay there through the pinch (CAN-2; the hand check is the anchor rule).
            let anchor = CGPoint(x: canvas.bounds.minX + 120, y: canvas.bounds.minY + 90)
            let anchorCanvas = canvas.transform.viewToCanvas(anchor)
            harness.pinch(magnification: 0.5, at: anchor)
            #expect(harness.statusBar.zoomText == "150%")
            let moved = canvas.transform.canvasToView(anchorCanvas)
            let slack = 0.5 / canvas.transform.backingScale + 1e-9
            #expect(abs(moved.x - anchor.x) <= slack, "anchor drifted to \(moved)")
            #expect(abs(moved.y - anchor.y) <= slack, "anchor drifted to \(moved)")
            // Every input path clamps to CAN-1's 3200 % — pinch included.
            harness.pinch(magnification: 1000, at: anchor)
            #expect(harness.statusBar.zoomText == "3200%")
            harness.pinch(magnification: -0.5, at: anchor)
            #expect(harness.statusBar.zoomText == "1600%")
            cleanup()
        }
    }

    @Test func scrollPans() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            resetUnit()

            let harness = try await openFixture(fixtures, name: "scrollpan.png",
                                                width: 4000, height: 2000)
            harness.perform(#selector(DocumentWindowController.actualSize(_:)))
            let center = CGPoint(x: harness.canvasView.bounds.midX,
                                 y: harness.canvasView.bounds.midY)
            harness.moveMouse(toView: center)
            let y1 = try #require(cursorY(of: harness.statusBar.cursorText))
            harness.scroll(dx: 0, dy: 100, precise: true, modifiers: [])
            harness.moveMouse(toView: center)
            let y2 = try #require(cursorY(of: harness.statusBar.cursorText))
            #expect(abs(y2 - y1) >= 50)
            #expect(harness.statusBar.zoomText == "100%")
            cleanup()
        }
    }

    @Test func spaceDragPans() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            resetUnit()

            let harness = try await openFixture(fixtures, name: "spacedrag.png",
                                                width: 4000, height: 2000)
            let canvas = harness.canvasView
            harness.perform(#selector(DocumentWindowController.actualSize(_:)))
            let before = canvas.transform
            let navigation = try #require(harness.windowController.navigation)

            harness.keyDown(" ", keyCode: CanvasNavigation.spaceKeyCode)
            #expect(navigation.spacePan.phase == .armed)
            let start = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
            canvas.mouseDown(with: harness.mouse(.leftMouseDown, at: canvas.convert(start, to: nil)))
            #expect(navigation.spacePan.phase == .panning)
            let dragged = CGPoint(x: start.x + 100, y: start.y)  // +100 view points in x
            canvas.mouseDragged(with: harness.mouse(.leftMouseDragged,
                                                    at: canvas.convert(dragged, to: nil)))
            // `mouseDragged` tracks the cursor for the status bar too (spec pointer
            // tracking: mouseMoved AND mouseDragged set the cursor field).
            #expect(harness.statusBar.cursorPixel != nil)
            canvas.mouseUp(with: harness.mouse(.leftMouseUp, at: canvas.convert(dragged, to: nil)))
            #expect(navigation.spacePan.phase == .armed)  // Space still held
            harness.keyUp(" ", keyCode: CanvasNavigation.spaceKeyCode)
            #expect(navigation.spacePan.phase == .idle)

            // Content follows the pointer by 100 view points: Δcenter = 100·s/zoom canvas
            // px (0004's `panned` rule; the transform's own scale and zoom).
            let after = canvas.transform
            let expected = 100 * before.backingScale / before.zoom
            #expect(abs((before.center.x - after.center.x) - expected) <= 1)
            #expect(after.zoom == before.zoom)
            cleanup()
        }
    }

    @Test func spaceWithModifierDoesNotPan() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            resetUnit()

            let harness = try await openFixture(fixtures, name: "spacemod.png",
                                                width: 4000, height: 2000)
            let canvas = harness.canvasView
            harness.perform(#selector(DocumentWindowController.actualSize(_:)))
            let navigation = try #require(harness.windowController.navigation)
            let before = canvas.transform

            // Space with ⌘/⌥/⌃ is a system shortcut, never the temporary pan — the gate
            // is `CanvasNavigation.keyDown`'s modifier check (spec edge case, driven here
            // through the real `CanvasView.keyDown` override with synthesized events).
            for modifiers in [NSEvent.ModifierFlags.command, .option, .control] {
                harness.keyDown(" ", keyCode: CanvasNavigation.spaceKeyCode, modifiers: modifiers)
                #expect(navigation.spacePan.phase == .idle, "Space+\(modifiers) armed the pan")
                // Un-armed, the next mouse down must not pan either.
                let start = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
                canvas.mouseDown(with: harness.mouse(.leftMouseDown,
                                                     at: canvas.convert(start, to: nil)))
                #expect(navigation.spacePan.phase == .idle)
                canvas.mouseUp(with: harness.mouse(.leftMouseUp,
                                                   at: canvas.convert(start, to: nil)))
                harness.keyUp(" ", keyCode: CanvasNavigation.spaceKeyCode, modifiers: modifiers)
                #expect(navigation.spacePan.phase == .idle)
            }
            #expect(canvas.transform == before, "a modified Space press moved the canvas")
            cleanup()
        }
    }

    @Test func losingKeyFocusResetsSpacePan() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            resetUnit()

            let harness = try await openFixture(fixtures, name: "resign.png",
                                                width: 4000, height: 2000)
            let navigation = try #require(harness.windowController.navigation)
            harness.keyDown(" ", keyCode: CanvasNavigation.spaceKeyCode)
            #expect(navigation.spacePan.phase == .armed)
            // The canvas window resigns key (⌘-Tab away): the pan state must never stay
            // armed — the observer is `CanvasNavigation`'s `didResignKeyNotification`.
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification,
                                            object: harness.window)
            await waitUntil { navigation.spacePan.phase == .idle }
            #expect(navigation.spacePan.phase == .idle)
            cleanup()
        }
    }

    // MARK: - Cursor and units

    @Test func cursorPosition() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            resetUnit()

            let harness = try await openFixture(fixtures, name: "cursor.png",
                                                width: 4000, height: 2000)
            harness.perform(#selector(DocumentWindowController.actualSize(_:)))
            let viewPoint = harness.viewPoint(forImagePoint: CGPoint(x: 2000.5, y: 1000.5))
            harness.moveMouse(toView: viewPoint)
            #expect(harness.statusBar.cursorText == "2000, 1000")
            harness.mouseExited()
            #expect(harness.statusBar.cursorText == "")
            cleanup()
        }
    }

    @Test func unitsUseDocumentDPI() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            resetUnit()

            let harness = try await openFixture(fixtures, name: "dpi96.png",
                                                width: 4000, height: 2000)
            // A metadata-free PNG reads 96 DPI (APP-5).
            #expect(harness.document.image.dpi == 96)
            harness.statusBar.selectUnit(.inches)
            #expect(harness.statusBar.imageSizeText == "41.67 × 20.83")
            harness.statusBar.selectUnit(.centimeters)
            #expect(harness.statusBar.imageSizeText == "105.83 × 52.92")
            harness.statusBar.selectUnit(.pixels)
            #expect(harness.statusBar.imageSizeText == "4000 × 2000")
            harness.close()

            let highDPI = try await openFixture(fixtures, name: "dpi300.png",
                                                width: 600, height: 300, dpi: 300)
            #expect(highDPI.document.image.dpi == 300)
            highDPI.statusBar.selectUnit(.inches)
            #expect(highDPI.statusBar.imageSizeText == "2.00 × 1.00")
            highDPI.statusBar.selectUnit(.centimeters)
            #expect(highDPI.statusBar.imageSizeText == "5.08 × 2.54")
            cleanup()
        }
    }

    @Test func unitPersistsForNewWindows() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            resetUnit()

            let harness = try await openFixture(fixtures, name: "persist.png",
                                                width: 4000, height: 2000)
            harness.statusBar.selectUnit(.inches)
            #expect(AppSettings().measurementUnit == .inches)
            harness.close()

            // A new window's model reads the persisted value at creation — what a relaunch
            // does (AGENTS.md: persistence tests use defaults, not relaunches).
            let reopened = try await openFixture(fixtures, name: "persist.png",
                                                 width: 4000, height: 2000)
            #expect(reopened.statusBar.unit == .inches)
            #expect(reopened.statusBar.imageSizeText == "41.67 × 20.83")
            cleanup()
        }
    }

    @Test func twoWindowsShareUnit() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            resetUnit()

            let first = try await openFixture(fixtures, name: "share-a.png",
                                              width: 4000, height: 2000)
            let second = try await openFixture(fixtures, name: "share-b.png",
                                               width: 64, height: 64)
            first.statusBar.selectUnit(.centimeters)
            await waitUntil { second.statusBar.unit == .centimeters }
            #expect(second.statusBar.unit == .centimeters)
            cleanup()
        }
    }

    // MARK: - Structure

    @Test func noScrollBars() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            resetUnit()

            let harness = try await openFixture(fixtures, name: "noscrollers.png",
                                                width: 4000, height: 2000)
            harness.perform(#selector(DocumentWindowController.actualSize(_:)))
            for view in subviews(of: try #require(harness.window.contentView)) {
                #expect(!(view is NSScrollView), "the window contains \(type(of: view))")
                #expect(!(view is NSScroller), "the window contains a scroller")
            }
            cleanup()
        }
    }

    @Test func zoomItemsHaveNoTargetWithoutDocument() async throws {
        await TestRunGate.withLock {
            HeadlessAssertions.closeAllDocuments()
            for selector in [MainMenu.zoomInAction, MainMenu.zoomOutAction,
                             MainMenu.zoomToWindowAction, MainMenu.actualSizeAction] {
                #expect(NSApp.target(forAction: selector, to: nil, from: nil) == nil,
                        "something responds to \(NSStringFromSelector(selector)) with no document")
            }
            HeadlessAssertions.noVisibleWindows()
        }
    }

    // MARK: - Helpers

    private func subviews(of root: NSView) -> [NSView] {
        var all: [NSView] = [root]
        for child in root.subviews { all.append(contentsOf: subviews(of: child)) }
        return all
    }

    /// All accessibility identifiers in an element subtree.
    ///
    /// With an accessibility client active (`AXEnhancedUserInterface` on `NSApp`), SwiftUI
    /// vends its elements as internal `AccessibilityNode` objects that answer the AppKit
    /// accessibility selectors but do not declare `NSAccessibilityProtocol` conformance, so
    /// the walk goes through `perform` — which works for AppKit views and SwiftUI nodes alike.
    private func accessibilityIdentifiers(of element: Any) -> Set<String> {
        guard let node = element as? NSObject else { return [] }
        var found: Set<String> = []
        if let identifier = a11yValue(node, "accessibilityIdentifier") as? String,
           !identifier.isEmpty {
            found.insert(identifier)
        }
        let children = a11yValue(node, "accessibilityChildren") as? [Any] ?? []
        for child in children { found.formUnion(accessibilityIdentifiers(of: child)) }
        return found
    }

    private func a11yValue(_ node: NSObject, _ selectorName: String) -> Any? {
        let selector = Selector((selectorName))
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue()
    }

    /// The y component of a `"x, y"` cursor string.
    private func cursorY(of text: String) -> Double? {
        let parts = text.split(separator: ",")
        guard parts.count == 2 else { return nil }
        return Double(parts[1].trimmingCharacters(in: .whitespaces))
    }
}
