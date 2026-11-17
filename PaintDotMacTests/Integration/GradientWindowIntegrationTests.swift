import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import PaintDotMac

/// The Gradient at window level (spec 0023 *Test plan*, headless): documents through
/// `DocumentHarness` (never shown), a fresh-suite `AppModel`, canvas input through
/// `harness.dragCanvas`, keys through `harness.shortcut`/`harness.keyDown`, the options bar
/// and Finish button through the accessibility tree; pixels checked by saving and decoding
/// the file. The fixture is a 4000 × 1000 opaque white PNG. Zoom is pinned to the backing
/// scale (0019/0022 lesson: a never-shown window's fit-zoom is a layout race).
@MainActor
@Suite(.serialized)
struct GradientWindowIntegrationTests {
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

    private func openWhiteFixture(_ fixtures: FixtureFiles) async throws -> DocumentHarness {
        let url = try fixtures.writePNG(named: "gradient-fixture.png",
                                        width: 4000, height: 1000) { _, _ in .white }
        let harness = try await DocumentHarness.open(url)
        harness.window.setContentSize(NSSize(width: 1000, height: 800))
        // Pin the zoom to the backing scale so canvas↔view is exactly 1 px per point
        // (the fit-zoom race on never-shown windows, 0022 CAN-6).
        let backing = harness.canvasView.transform.backingScale
        harness.canvasView.navigation?.setZoom(
            backing,
            anchoredAtView: CGPoint(x: harness.canvasView.bounds.midX,
                                    y: harness.canvasView.bounds.midY))
        harness.document.undoBridge.undoManager.groupsByEvent = false
        harness.appModel.setActiveSession(harness.windowController.toolSession)
        pumpMainRunLoop()
        return harness
    }

    /// Saves through the document (no sheet) and decodes the file's pixels.
    private func savedPixels(_ harness: DocumentHarness) async throws
        -> (Int, Int) -> ColorRGBA8
    {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests.gradient.\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try await saveDocument(harness.document, to: url, ofType: "public.png",
                               for: .saveAsOperation)
        let data = try #require(try? Data(contentsOf: url))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return { x, y in
            let offset = (y * width + x) * 4
            return ColorRGBA8(red: bytes[offset], green: bytes[offset + 1],
                              blue: bytes[offset + 2], alpha: bytes[offset + 3])
        }
    }

    private func names(_ harness: DocumentHarness) -> [String] {
        harness.document.undoBridge.history.steps.map(\.name)
    }

    /// View points of an image-space point (the harness zoom is pinned to 1 px per point).
    private func view(_ harness: DocumentHarness, _ x: Double, _ y: Double) -> CGPoint {
        harness.viewPoint(forImagePoint: CGPoint(x: x, y: y))
    }

    /// The drag of the acceptance: image (1000, 500) → (3000, 500) — 25 % → 75 % of the
    /// width at mid-height.
    private func drawGradient(_ harness: DocumentHarness) {
        harness.dragCanvas(from: view(harness, 1000, 500), to: view(harness, 3000, 500))
        pumpMainRunLoop()
    }

    private func enabledState(_ harness: DocumentHarness, _ identifier: String) -> Bool? {
        guard let content = harness.window.contentView else { return nil }
        return AX.withAccessibilityClient { AX.enabledState(inRoot: content, identifier: identifier) }
    }

    private func axValue(_ harness: DocumentHarness, _ identifier: String) -> String? {
        guard let content = harness.window.contentView else { return nil }
        return AX.withAccessibilityClient {
            guard let element = AX.first(inRoot: content, identifier: identifier) else {
                return nil
            }
            return AX.value(of: element)
        }
    }

    private func axPresent(_ harness: DocumentHarness, _ identifier: String) -> Bool {
        guard let content = harness.window.contentView else { return false }
        return AX.withAccessibilityClient {
            AX.first(inRoot: content, identifier: identifier) != nil
        }
    }

    // MARK: - Tests

    @Test func pressingGSelectsGradientAndShowsOptions() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }

            let pressed = harness.shortcut("g")
            #expect(pressed, "single-key g is consumed by the shortcut router")
            pumpMainRunLoop()
            let activeTool = harness.appModel.activeToolID
            #expect(activeTool == .gradient, "g selects the Gradient")

            // The options bar exposes the five controls.
            for id in ["toolOptions.gradientType", "toolOptions.gradientMode",
                       "toolOptions.antialiasing", "toolOptions.blendMode",
                       "toolOptions.finish"] {
                let present = axPresent(harness, id)
                #expect(present, "\(id) present")
            }
            let typeValue = axValue(harness, "toolOptions.gradientType")
            #expect(typeValue == "Linear")
            let modeValue = axValue(harness, "toolOptions.gradientMode")
            #expect(modeValue == "Color Mode")
            let blendValue = axValue(harness, "toolOptions.blendMode")
            #expect(blendValue == "Normal")
            let antialiasing = harness.appModel.toolOptions.value(GradientOptions.keys().antialiasing)
            #expect(antialiasing, "Antialiasing defaults on")
            // Finish shows for the Gradient and is disabled while idle.
            let finishState = enabledState(harness, "toolOptions.finish")
            #expect(finishState == false, "Finish shows disabled while idle")

            // Transparency Mode greys out the blend-mode popup (not used, D-50c).
            harness.appModel.toolOptions.setValue(GradientMode.transparency,
                                                  for: GradientOptions.keys().mode)
            pumpMainRunLoop()
            let blendDisabled = enabledState(harness, "toolOptions.blendMode")
            #expect(blendDisabled == false, "blend mode is unused in Transparency Mode")
            harness.appModel.toolOptions.setValue(GradientMode.color,
                                                  for: GradientOptions.keys().mode)
            pumpMainRunLoop()
            let blendEnabled = enabledState(harness, "toolOptions.blendMode")
            #expect(blendEnabled == true, "blend mode is live again in Color Mode")
        }
    }

    @Test func drawCommitUndoRedo() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }

            let pressed = harness.shortcut("g")
            #expect(pressed, "single-key g is consumed by the shortcut router")
            drawGradient(harness)
            let finishLive = enabledState(harness, "toolOptions.finish")
            #expect(finishLive == true, "Finish is enabled while the gradient is pending")

            harness.keyDown("\r", keyCode: 36)
            pumpMainRunLoop()
            let historyNames = names(harness)
            #expect(historyNames.last == "Gradient")
            let undoManager = harness.document.undoBridge.undoManager
            let undoTitle = undoManager.undoMenuItemTitle
            #expect(undoTitle == "Undo Gradient")

            var at = try await savedPixels(harness)
            #expect(at(100, 500) == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255))
            #expect(at(3900, 500) == ColorRGBA8(red: 255, green: 255, blue: 255, alpha: 255))
            let mid = Int(at(2000, 500).red)
            #expect((100...155).contains(mid), "mid ramp red in 100…155, got \(mid)")
            for x in stride(from: 1000, through: 3000, by: 50) {
                let a = Int(at(x, 500).red)
                let b = Int(at(x + 50, 500).red)
                #expect(b >= a, "row 500 non-decreasing at x = \(x)")
            }
            #expect(at(2000, 10) == at(2000, 990), "perpendicular invariance")

            harness.document.undoBridge.undo()
            pumpMainRunLoop()
            let redoTitle = undoManager.redoMenuItemTitle
            #expect(redoTitle == "Redo Gradient")
            at = try await savedPixels(harness)
            for x in [100, 1000, 2000, 3000, 3900] {
                #expect(at(x, 500) == .white, "undo leaves (x, 500) white at x = \(x)")
            }
            harness.document.undoBridge.redo()
            pumpMainRunLoop()
            let redoNames = names(harness)
            #expect(redoNames.last == "Gradient")
            at = try await savedPixels(harness)
            #expect(at(100, 500) == ColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255))
        }
    }

    @Test func escapeDiscards() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openWhiteFixture(fixtures)
            defer { finish(harness) }

            let pressed = harness.shortcut("g")
            #expect(pressed, "single-key g is consumed by the shortcut router")
            drawGradient(harness)
            harness.keyDown("\u{1b}", keyCode: 53)
            pumpMainRunLoop()
            let escapeNames = names(harness)
            #expect(!escapeNames.contains("Gradient"))
            let escapeUndoTitle = harness.document.undoBridge.undoManager.undoMenuItemTitle
            #expect(escapeUndoTitle != "Undo Gradient")
            let at = try await savedPixels(harness)
            #expect(at(100, 500) == .white)
            #expect(at(2000, 500) == .white)
        }
    }

    @Test func gradientClippedToSelection() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let url = try fixtures.writePNG(named: "gradient-fixture.png",
                                            width: 4000, height: 1000) { _, _ in .white }
            let harness = try await DocumentHarness.open(url)
            harness.window.setContentSize(NSSize(width: 1000, height: 800))
            let backing = harness.canvasView.transform.backingScale
            harness.canvasView.navigation?.setZoom(
                backing,
                anchoredAtView: CGPoint(x: harness.canvasView.bounds.midX,
                                        y: harness.canvasView.bounds.midY))
            harness.document.undoBridge.undoManager.groupsByEvent = false
            harness.appModel.setActiveSession(harness.windowController.toolSession)
            harness.windowController.setInitialSelection(
                PixelRect(x: 1000, y: 250, width: 2000, height: 500))
            pumpMainRunLoop()
            defer { finish(harness) }

            let pressed = harness.shortcut("g")
            #expect(pressed, "single-key g is consumed by the shortcut router")
            drawGradient(harness)
            harness.keyDown("\r", keyCode: 36)
            pumpMainRunLoop()
            let historyNames = names(harness)
            #expect(historyNames.last == "Gradient")
            let at = try await savedPixels(harness)
            #expect(at(500, 500) == .white, "left of the selection")
            #expect(at(3500, 500) == .white, "right of the selection")
            #expect(at(2000, 100) == .white, "above the selection")
            #expect(at(1200, 500) != .white, "inside the selection: the ramp landed")
        }
    }
}
