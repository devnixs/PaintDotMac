import AppKit
import Foundation
import Metal
import Testing
@testable import PaintDotMac

/// Headless integration tests for the canvas in the real window (spec 0003 *Test plan*):
/// fixtures opened through `DocumentHarness`, windows built but never shown. Exact on-screen
/// pixels are covered by `MetalCanvasRendererTests`; these prove the window controller wires
/// the document into a `CanvasView` with the right transform and checkerboard path.
@MainActor
@Suite(.serialized)
struct CanvasIntegrationTests {
    /// Finds a view by accessibility identifier in a content view hierarchy (inclusive).
    private func views(in root: NSView, identifier: String) -> [NSView] {
        var found: [NSView] = []
        if root.accessibilityIdentifier() == identifier { found.append(root) }
        for child in root.subviews { found.append(contentsOf: views(in: child, identifier: identifier)) }
        return found
    }

    @Test func canvasShowsOpenedImage() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }

            let url = try fixtures.writePNG(named: "canvas-fixture.png", width: 64, height: 48) { _, _ in
                ColorRGBA8(red: 200, green: 100, blue: 50)
            }
            let harness = try await DocumentHarness.open(url)
            harness.window.setContentSize(NSSize(width: 1000, height: 800))
            let content = try #require(harness.window.contentView)
            let canvases = views(in: content, identifier: "canvas")
            #expect(canvases.count == 1)
            let canvas = try #require(canvases.first as? CanvasView)
            #expect(canvas.accessibilityValue() as? String == "64 × 48")
            #expect(canvas.isMetalAvailable)
            #expect(views(in: content, identifier: "canvas.unavailable").isEmpty)
            cleanup()
        }
    }

    @Test func smallImageOpensAt100Percent() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }

            let url = try fixtures.writePNG(named: "small.png", width: 64, height: 48) { _, _ in
                ColorRGBA8(red: 30, green: 120, blue: 220)
            }
            let harness = try await DocumentHarness.open(url)
            harness.window.setContentSize(NSSize(width: 1000, height: 800))
            let canvas = try #require(harness.windowController.canvasView)
            #expect(canvas.transform.zoom == 1)
            #expect(canvas.transform.center == CGPoint(x: 32, y: 24))
            // Centered: the left/right and top/bottom view-space margins match within 1 pt
            // (the origin is rounded to a device pixel, so an odd drawable can be off by one).
            let rect = canvas.transform.canvasRectToView(
                CGRect(x: 0, y: 0, width: 64, height: 48)
            )
            let view = canvas.transform.viewSize
            #expect(abs(rect.minX - (view.width - rect.maxX)) <= 1)
            #expect(abs(rect.minY - (view.height - rect.maxY)) <= 1)
            cleanup()
        }
    }

    @Test func largeImageOpensFittedAndCentered() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }

            let url = try fixtures.writePNG(named: "large.png", width: 6000, height: 4000) { _, _ in
                ColorRGBA8(red: 7, green: 8, blue: 9)
            }
            let harness = try await DocumentHarness.open(url)
            let canvas = try #require(harness.windowController.canvasView)
            let transform = canvas.transform
            // The zoom is exactly the fit zoom for the canvas drawable (never above 100 %):
            // recomputed from the transform's own drawable geometry, not from the code path.
            let drawable = transform.drawableSize
            let expected = min(1.0, min(Double(drawable.width) / 6000.0, Double(drawable.height) / 4000.0))
            #expect(transform.zoom == expected)
            #expect(transform.zoom < 1)
            #expect(transform.center == CGPoint(x: 3000, y: 2000))
            // The image fills the drawable's constrained axis (± 1 device pixel)…
            let drawnWidth = (6000.0 * transform.zoom).rounded()
            let drawnHeight = (4000.0 * transform.zoom).rounded()
            #expect(abs(drawnWidth - Double(drawable.width)) <= 1 || abs(drawnHeight - Double(drawable.height)) <= 1)
            // …and is centered: the device margins on each axis match within 1 pixel.
            let origin = transform.imageOriginInDevice
            let leftMargin = Double(origin.x)
            let rightMargin = Double(drawable.width) - (Double(origin.x) + drawnWidth)
            let topMargin = Double(origin.y)
            let bottomMargin = Double(drawable.height) - (Double(origin.y) + drawnHeight)
            #expect(abs(leftMargin - rightMargin) <= 1)
            #expect(abs(topMargin - bottomMargin) <= 1)
            cleanup()
        }
    }

    @Test func checkerboardVisibleThroughTransparentPixels() async throws {
        try await TestRunGate.withLock {
            let fixtures = try FixtureFiles()
            defer { cleanup(); fixtures.removeAll() }

            let url = try fixtures.writePNG(named: "half-transparent.png", width: 200, height: 200) { x, _ in
                x < 100 ? ColorRGBA8(red: 220, green: 30, blue: 30) : ColorRGBA8.clear
            }
            let harness = try await DocumentHarness.open(url)
            let canvas = try #require(harness.windowController.canvasView)
            let transform = canvas.transform
            let width = transform.drawableSize.width
            let height = transform.drawableSize.height
            // Render the window's canvas state offscreen, exactly as draw() builds it.
            let frame = try #require(canvas.currentCanvasFrame())
            let device = try MetalTestTarget.makeDevice()
            let renderer = try MetalCanvasRenderer(device: device)
            let output = try MetalTestTarget.render(frame, with: renderer, device: device,
                                                    width: width, height: height)
            let origin = transform.imageOriginInDevice
            func pixel(canvasX: Int, canvasY: Int) -> ColorRGBA8 {
                output[(origin.y + canvasY) * width + origin.x + canvasX]
            }
            let left = pixel(canvasX: 50, canvasY: 100)
            TestImages.expectColor(left, ColorRGBA8(red: 220, green: 30, blue: 30), tolerance: 1, "opaque left half")
            // The transparent right half shows both checkerboard colors (8-pt squares,
            // over 100 canvas px = at least 12 squares at zoom 1).
            var sawWhite = false
            var sawGray = false
            for canvasY in 0..<200 {
                for canvasX in 100..<200 {
                    let p = pixel(canvasX: canvasX, canvasY: canvasY)
                    if near(p, ColorRGBA8.white) { sawWhite = true }
                    if near(p, ColorRGBA8(red: 204, green: 204, blue: 204)) { sawGray = true }
                }
            }
            #expect(sawWhite, "right half must show the #FFFFFF checkerboard square")
            #expect(sawGray, "right half must show the #CCCCCC checkerboard square")
            cleanup()
        }
    }

    private func near(_ color: ColorRGBA8, _ target: ColorRGBA8) -> Bool {
        abs(Int(color.red) - Int(target.red)) <= 1 && abs(Int(color.green) - Int(target.green)) <= 1
            && abs(Int(color.blue) - Int(target.blue)) <= 1
    }

    private func cleanup() {
        HeadlessAssertions.closeAllDocuments()
        HeadlessAssertions.noVisibleWindows()
    }
}
