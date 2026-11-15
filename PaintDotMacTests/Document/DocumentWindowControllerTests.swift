import AppKit
import CoreGraphics
import Testing
@testable import PaintDotMac

@MainActor
@Suite(.serialized)
struct DocumentWindowControllerTests {
    /// All values below are hand-computed with
    /// `result = min(max(image, (480, 360)), max(floor(visible × 0.8), (480, 360)))`.
    private let screen = CGSize(width: 1440, height: 900) // maximum = (1152, 720)

    @Test func initialContentSizeSmallImageUsesMinimum() {
        #expect(DocumentWindowController.initialContentSize(imageSize: CGSize(width: 64, height: 48),
                                                            visibleFrameSize: screen)
                == CGSize(width: 480, height: 360))
    }

    @Test func initialContentSizeFitsMediumImage() {
        #expect(DocumentWindowController.initialContentSize(imageSize: CGSize(width: 800, height: 600),
                                                            visibleFrameSize: screen)
                == CGSize(width: 800, height: 600))
    }

    @Test func initialContentSizeCapsLargeImage() {
        #expect(DocumentWindowController.initialContentSize(imageSize: CGSize(width: 4000, height: 3000),
                                                            visibleFrameSize: screen)
                == CGSize(width: 1152, height: 720))
    }

    /// Edge case: a 1×1 image still opens at the 480×360 minimum.
    @Test func initialContentSizeOnePixelImageUsesMinimum() {
        #expect(DocumentWindowController.initialContentSize(imageSize: CGSize(width: 1, height: 1),
                                                            visibleFrameSize: screen)
                == CGSize(width: 480, height: 360))
    }

    @Test func initialContentSizeMixedAxes() {
        // x: max(1000, 480) = 1000 ≤ 1152 → 1000. y: max(200, 360) = 360 → 360.
        #expect(DocumentWindowController.initialContentSize(imageSize: CGSize(width: 1000, height: 200),
                                                            visibleFrameSize: screen)
                == CGSize(width: 1000, height: 360))
    }

    @Test func initialContentSizeTinyScreenKeepsMinimum() {
        // maximum = (400, 320) < minimum, so the 480×360 minimum wins.
        #expect(DocumentWindowController.initialContentSize(imageSize: CGSize(width: 4000, height: 3000),
                                                            visibleFrameSize: CGSize(width: 500, height: 400))
                == CGSize(width: 480, height: 360))
    }

    @Test func windowSupportsTabbing() throws {
        let image = LayeredImage.blank(size: PixelSize(width: 10, height: 10),
                                       fill: ColorRGBA8(red: 255, green: 0, blue: 0))
        let controller = DocumentWindowController(image: image)
        let window = try #require(controller.window)
        #expect(window.tabbingMode == .automatic)
        #expect(window.tabbingIdentifier == "com.thera-engineering.paintdotmac.document")
        #expect(window.minSize == CGSize(width: 320, height: 240))
        #expect(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable]))
        window.close()
    }
}
