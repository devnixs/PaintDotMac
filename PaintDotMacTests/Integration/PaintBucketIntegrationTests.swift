import AppKit
import CoreGraphics
import SwiftUI
import Testing

@testable import PaintDotMac

/// The Paint Bucket through the real document, router, options bar, and History
/// (spec 0017 *Test plan*, headless): the fixture (200 × 200 PNG, left half opaque red,
/// right half opaque white) is generated at test time, canvas input goes through
/// `harness.clickCanvas`/`dragCanvas` and keys through `harness.shortcut`, and pixels are
/// checked by saving the document and decoding the file. Each test ends with
/// `HeadlessAssertions.closeAllDocuments()` and `noVisibleWindows()`.
@MainActor
@Suite(.serialized)
struct PaintBucketIntegrationTests {
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
    /// SwiftUI Slider vends (an `NSNumber`, not the `NSString` `AX.value` reads); the
    /// "NN%" string is the tolerance readout (spec 0007's recorded discovery).
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

    /// Saves through the document (no sheet) and decodes the file's pixels.
    private func savedPixels(_ harness: DocumentHarness) async throws
        -> (Int, Int) -> ColorRGBA8
    {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaintDotMacTests.saved.\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try await saveDocument(harness.document, to: url, ofType: "public.png",
                               for: .saveAsOperation)
        let data = try #require(try? Data(contentsOf: url))
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let image = try #require(source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        _ = try #require(context)
        context!.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return { x, y in
            let offset = (y * width + x) * 4
            return ColorRGBA8(red: bytes[offset], green: bytes[offset + 1],
                              blue: bytes[offset + 2], alpha: bytes[offset + 3])
        }
    }

    private func historyNames(_ harness: DocumentHarness) -> [String] {
        harness.appModel.historyPanel.model.rows.map(\.name)
    }

    /// 200 × 200: left half opaque red `(255, 0, 0)`, right half opaque white.
    private func fixturePixel(_ x: Int, _ y: Int) -> ColorRGBA8 {
        x < 100 ? ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255) : .white
    }

    private func selectBucket(_ harness: DocumentHarness) {
        #expect(harness.shortcut("f"))
        #expect(harness.appModel.activeToolID == .paintBucket)
        pumpMainRunLoop()
    }

    // MARK: Tests

    @Test func pressingFSelectsToolAndShowsOptions() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "bucket-options.png",
                                                width: 200, height: 200) { _, _ in .white }
            defer { finish(harness) }

            selectBucket(harness)

            let identifiers = optionIdentifiers(harness)
            for id in ["toolOptions.fillMode", "toolOptions.floodMode",
                       "toolOptions.tolerance", "toolOptions.samplingMode",
                       "toolOptions.antialiasing", "toolOptions.blendMode"] {
                #expect(identifiers.contains(id), "accessibility element \(id)")
            }
            // Paint.NET's defaults (T-9 / APP-4).
            #expect(optionValue(harness, identifier: "toolOptions.fillMode") == "Similar Color")
            #expect(optionValue(harness, identifier: "toolOptions.floodMode") == "Contiguous")
            // The slider vends its *numeric* value; the "%" lives in the readout (0016).
            #expect(rawOptionValue(harness, identifier: "toolOptions.tolerance") == "50")
            #expect(optionValue(harness, identifier: "toolOptions.samplingMode") == "Layer")
            #expect(optionValue(harness, identifier: "toolOptions.blendMode") == "Normal")
            let toggle = optionValue(harness, identifier: "toolOptions.antialiasing") ?? ""
            #expect(toggle == "1" || toggle.lowercased() == "on" || toggle == "checked"
                        || toggle.isEmpty, "antialiasing on (value \(toggle))")
        }
    }

    @Test func selectionFillDisablesFloodAndAntialiasingOptions() async throws {
        // APP-4: Fill = Selection greys out Flood mode, Tolerance, Sampling, and
        // Antialiasing (the selection carries its own AA edge), while the Fill and
        // Blend Mode popups stay live (spec 0017 scope).
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "bucket-disabled.png",
                                                width: 200, height: 200) { _, _ in .white }
            defer { finish(harness) }

            selectBucket(harness)
            let content = try #require(harness.window.contentView)
            let disabledWhileSelection = ["toolOptions.floodMode", "toolOptions.tolerance",
                                          "toolOptions.samplingMode",
                                          "toolOptions.antialiasing"]
            let alwaysEnabled = ["toolOptions.fillMode", "toolOptions.blendMode"]

            // Positive control: Similar Color enables every option (this also proves the
            // elements vend their enabled state at all).
            for id in disabledWhileSelection + alwaysEnabled {
                #expect(AX.enabledState(inRoot: content, identifier: id) == true,
                        "\(id) enabled with Fill = Similar Color")
            }

            // The same write the Fill popup's binding makes.
            harness.appModel.toolOptions.setValue(PaintBucketFillMode.selection,
                                                  for: PaintBucketOptions.fillModeKey)
            pumpMainRunLoop()

            for id in disabledWhileSelection {
                #expect(AX.enabledState(inRoot: content, identifier: id) == false,
                        "\(id) disabled while Fill = Selection")
            }
            for id in alwaysEnabled {
                #expect(AX.enabledState(inRoot: content, identifier: id) == true,
                        "\(id) stays enabled")
            }
        }
    }

    @Test func clickFillsAndUndoes() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "bucket-fill.png",
                                                width: 200, height: 200, pixel: fixturePixel)
            defer { finish(harness) }

            selectBucket(harness)
            harness.clickCanvas(
                at: harness.viewPoint(forImagePoint: CGPoint(x: 150.5, y: 100.5)))
            pumpMainRunLoop()

            #expect(historyNames(harness).last == "Paint Bucket")
            #expect(harness.document.undoBridge.undoManager.undoMenuItemTitle
                        == "Undo Paint Bucket")

            let pixels = try await savedPixels(harness)
            #expect(pixels(150, 100) == .black, "the white half fills with the primary")
            #expect(pixels(50, 100) == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255),
                    "the red half is a different color — untouched")

            harness.perform(NSSelectorFromString("undo:"))
            pumpMainRunLoop()
            #expect(harness.appModel.historyPanel.model.rows.first(where: \.isCurrent)?.name
                        == "Open Image", "undo returns to the base step")
            let restored = try await savedPixels(harness)
            #expect(restored(150, 100) == .white, "undo restores the white")
        }
    }

    @Test func fillIsClippedToSelection() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "bucket-clip.png",
                                                width: 200, height: 200, pixel: fixturePixel)
            defer { finish(harness) }

            // Rectangle Select over the right-half middle region (TOOL-B). The "s" group
            // cycles (0014), so press until Rectangle Select is active, then drag.
            for _ in 0..<4 where harness.appModel.activeToolID != .rectangleSelect {
                #expect(harness.shortcut("s"))
            }
            #expect(harness.appModel.activeToolID == .rectangleSelect)
            // The gesture must outlive Paint.NET's 50 ms too-quick window (0014's
            // `SelectionGesture.outcome`), so press, sleep, drag, release.
            harness.canvasPress(at: harness.viewPoint(forImagePoint: CGPoint(x: 120, y: 80)))
            try await Task.sleep(for: .milliseconds(80))
            harness.canvasDrag(to: harness.viewPoint(forImagePoint: CGPoint(x: 150, y: 100)))
            try await Task.sleep(for: .milliseconds(20))
            harness.canvasDrag(to: harness.viewPoint(forImagePoint: CGPoint(x: 180, y: 120)))
            harness.canvasRelease(at: harness.viewPoint(forImagePoint: CGPoint(x: 180, y: 120)))
            pumpMainRunLoop()
            #expect(harness.document.undoBridge.state.selection?
                        .mask.coverage(x: 150, y: 100) == 255)
            #expect(harness.document.undoBridge.state.selection?
                        .mask.coverage(x: 190, y: 10) == 0,
                        "the drag selects the middle region only")

            selectBucket(harness)
            harness.clickCanvas(
                at: harness.viewPoint(forImagePoint: CGPoint(x: 150.5, y: 100.5)))
            pumpMainRunLoop()

            let pixels = try await savedPixels(harness)
            #expect(pixels(150, 100) == .black, "inside the selection")
            #expect(pixels(190, 10) == .white, "right of and above the selection")
            #expect(pixels(150, 150) == .white, "below the selection, same white area")
            #expect(pixels(50, 100) == ColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255),
                    "the other layer half untouched")
        }
    }

    @Test func optionsPersistForNewModel() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }
            let harness = try await openFixture(fixtures, name: "bucket-persist.png",
                                                width: 200, height: 200) { _, _ in .white }
            defer { finish(harness) }

            selectBucket(harness)
            // The same writes the options bar's bindings make (TOOL-C).
            let options = harness.appModel.toolOptions
            options.setValue(FloodMode.global,
                             for: FloodToolOptions.floodMode(for: .paintBucket))
            options.setValue(PaintBucketFillMode.selection,
                             for: PaintBucketOptions.fillModeKey)
            pumpMainRunLoop()
            #expect(optionValue(harness, identifier: "toolOptions.floodMode") == "Global")
            #expect(optionValue(harness, identifier: "toolOptions.fillMode") == "Selection")

            // A fresh AppModel on the same suite is what a relaunch reads (TOOL-C).
            let relaunched = AppModel(defaults: harness.appModel.defaultsForTests)
            #expect(relaunched.toolOptions.value(
                FloodToolOptions.floodMode(for: .paintBucket)) == .global)
            #expect(relaunched.toolOptions.value(
                PaintBucketOptions.fillModeKey) == .selection)
            #expect(relaunched.toolOptions.value(
                FloodToolOptions.tolerance(for: .paintBucket)) == 50)
        }
    }
}
