import AppKit
import Testing
@testable import PaintDotMac

/// Hosted AppKit unit tests for `CanvasView` (spec 0003 *Test plan*): no window is created,
/// so the backing scale is 1 (no window → scale 1) and nothing is ever shown.
@MainActor
@Suite(.serialized)
struct CanvasViewTests {
    @Test func initialZoomSmallImage() throws {
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        view.image = LayeredImage.blank(size: PixelSize(width: 800, height: 600), fill: .black)
        #expect(view.transform.zoom == 1)
        #expect(view.transform.center == CGPoint(x: 400, y: 300))
    }

    @Test func initialZoomLargeImage() throws {
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        view.image = LayeredImage.blank(size: PixelSize(width: 4000, height: 3000), fill: .black)
        #expect(view.transform.zoom == 0.25)
        #expect(view.transform.center == CGPoint(x: 2000, y: 1500))
    }

    @Test func initialZoomAppliedAfterFirstNonZeroLayout() throws {
        let view = CanvasView(frame: .zero)
        view.image = LayeredImage.blank(size: PixelSize(width: 4000, height: 3000), fill: .black)
        // Zero size: nothing laid out yet → the zoom stays the 100 % default.
        #expect(view.transform.zoom == 1)
        view.setFrameSize(NSSize(width: 1000, height: 800))
        #expect(view.transform.zoom == 0.25)
        #expect(view.transform.center == CGPoint(x: 2000, y: 1500))
        // A later resize keeps zoom and center; only the view size follows.
        view.setFrameSize(NSSize(width: 500, height: 400))
        #expect(view.transform.zoom == 0.25)
        #expect(view.transform.center == CGPoint(x: 2000, y: 1500))
        #expect(view.transform.viewSize == NSSize(width: 500, height: 400))
    }

    @Test func accessibilityContract() throws {
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        view.image = LayeredImage.blank(size: PixelSize(width: 800, height: 600), fill: .black)
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .image)
        #expect(view.accessibilityIdentifier() == "canvas")
        #expect(view.accessibilityLabel() == "Canvas")
        #expect(view.accessibilityValue() as? String == "800 × 600")
        view.image = LayeredImage.blank(size: PixelSize(width: 30, height: 20), fill: .black)
        #expect(view.accessibilityValue() as? String == "30 × 20")
    }

    @Test func isNotFlipped() throws {
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        // View space is bottom-left origin, as CanvasTransform documents.
        #expect(view.isFlipped == false)
    }

    /// A view created without a Metal device is not available, records a failure for the
    /// window controller to log, and never crashes when asked to draw (the window
    /// controller shows the `canvas.unavailable` label instead of this view).
    @Test func metalUnavailableWithoutDevice() throws {
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 100, height: 80), device: nil)
        #expect(!view.isMetalAvailable)
        #expect(view.metalFailure != nil)
        view.image = LayeredImage.blank(size: PixelSize(width: 10, height: 10), fill: .black)
        view.draw()   // must do nothing, not crash
    }

    /// Backing properties changing (window dragged between displays) keeps the zoom and the
    /// center and only re-resolves the backing scale (edge case "Backing-scale change").
    @Test func backingPropertiesChangeKeepsZoom() throws {
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        view.image = LayeredImage.blank(size: PixelSize(width: 4000, height: 3000), fill: .black)
        let before = view.transform
        #expect(before.zoom == 0.25)
        view.viewDidChangeBackingProperties()
        #expect(view.transform.zoom == before.zoom)
        #expect(view.transform.center == before.center)
        // No window → scale stays 1; the point of the test is that nothing else changed.
        #expect(view.transform.backingScale == 1)
        #expect(view.transform.viewSize == before.viewSize)
    }
}
