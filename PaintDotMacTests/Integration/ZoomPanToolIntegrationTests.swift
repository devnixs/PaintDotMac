import AppKit
import Testing
@testable import PaintDotMac

/// The Zoom and Pan tools driving the real window through synthesized events (spec 0006
/// *Test plan*, headless): status-bar zoom after clicks, the zoom rectangle, pan deltas, and
/// "view tools never dirty the document".
@MainActor
@Suite(.serialized)
struct ZoomPanToolIntegrationTests {
    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }

    private func openFixture(_ fixtures: FixtureFiles) async throws -> DocumentHarness {
        let url = try fixtures.writePNG(named: "zoompan-tool.png", width: 4000, height: 2000) { _, _ in
            ColorRGBA8(red: 20, green: 220, blue: 90)
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

    private func zoomPercent(_ harness: DocumentHarness) -> Int? {
        Int(harness.statusBar.zoomText.dropLast())
    }

    @Test func zoomToolClickAndOptionClick() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }

            harness.perform(#selector(DocumentWindowController.actualSize(_:)))
            #expect(harness.statusBar.zoomText == "100%")

            #expect(harness.shortcut("z"))
            let center = CGPoint(x: harness.canvasView.bounds.midX,
                                 y: harness.canvasView.bounds.midY)
            harness.clickCanvas(at: center)
            #expect(harness.statusBar.zoomText == "150%")

            harness.clickCanvas(at: center, modifiers: [.option])
            #expect(harness.statusBar.zoomText == "100%")

            // The right button zooms out: 100 % → 67 %.
            harness.clickCanvas(at: center, button: .right)
            #expect(zoomPercent(harness) == 67)
        }
    }

    @Test func zoomToolRectangle() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }

            harness.perform(#selector(DocumentWindowController.actualSize(_:)))
            #expect(harness.shortcut("z"))
            let size = harness.canvasView.bounds.size
            harness.dragCanvas(
                from: CGPoint(x: size.width * 0.45, y: size.height * 0.45),
                to: CGPoint(x: size.width * 0.55, y: size.height * 0.55),
                steps: 8
            )
            let percent = try #require(zoomPercent(harness))
            #expect(percent > 300, "the 10 % rectangle magnifies to fill the view (got \(percent) %)")
        }
    }

    @Test func panToolDrags() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }

            harness.perform(#selector(DocumentWindowController.actualSize(_:)))
            #expect(harness.shortcut("h"))
            let scale = harness.window.backingScaleFactor
            let before = harness.canvasView.transform.center.x
            let center = CGPoint(x: harness.canvasView.bounds.midX,
                                 y: harness.canvasView.bounds.midY)
            harness.dragCanvas(from: center, to: CGPoint(x: center.x + 120, y: center.y))
            let after = harness.canvasView.transform.center.x
            // Content follows the pointer: +120 pt of view movement at zoom 1 is
            // 120 × backingScale canvas pixels leftward.
            #expect(abs((before - after) - 120 * scale) <= 1,
                    "dragged \(before - after) canvas px, expected \(120 * scale)")
            #expect(harness.statusBar.zoomText == "100%", "pan never zooms")
        }
    }

    @Test func zoomAndPanDoNotDirtyDocument() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures)
            defer { finish(harness) }

            let imageBefore = harness.document.image
            harness.perform(#selector(DocumentWindowController.actualSize(_:)))
            #expect(harness.shortcut("z"))
            let center = CGPoint(x: harness.canvasView.bounds.midX,
                                 y: harness.canvasView.bounds.midY)
            harness.clickCanvas(at: center)
            #expect(harness.shortcut("h"))
            harness.dragCanvas(from: center, to: CGPoint(x: center.x + 80, y: center.y - 40))

            #expect(harness.document.isDocumentEdited == false)
            #expect(harness.document.image == imageBefore)
        }
    }
}
