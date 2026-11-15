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
                                                            visibleFrameSize: screen, backingScale: 1)
                == CGSize(width: 480, height: 360))
    }

    @Test func initialContentSizeFitsMediumImage() {
        #expect(DocumentWindowController.initialContentSize(imageSize: CGSize(width: 800, height: 600),
                                                            visibleFrameSize: screen, backingScale: 1)
                == CGSize(width: 800, height: 600))
    }

    @Test func initialContentSizeCapsLargeImage() {
        #expect(DocumentWindowController.initialContentSize(imageSize: CGSize(width: 4000, height: 3000),
                                                            visibleFrameSize: screen, backingScale: 1)
                == CGSize(width: 1152, height: 720))
    }

    /// Edge case: a 1×1 image still opens at the 480×360 minimum.
    @Test func initialContentSizeOnePixelImageUsesMinimum() {
        #expect(DocumentWindowController.initialContentSize(imageSize: CGSize(width: 1, height: 1),
                                                            visibleFrameSize: screen, backingScale: 1)
                == CGSize(width: 480, height: 360))
    }

    @Test func initialContentSizeMixedAxes() {
        // x: max(1000, 480) = 1000 ≤ 1152 → 1000. y: max(200, 360) = 360 → 360.
        #expect(DocumentWindowController.initialContentSize(imageSize: CGSize(width: 1000, height: 200),
                                                            visibleFrameSize: screen, backingScale: 1)
                == CGSize(width: 1000, height: 360))
    }

    @Test func initialContentSizeTinyScreenKeepsMinimum() {
        // maximum = (400, 320) < minimum, so the 480×360 minimum wins.
        #expect(DocumentWindowController.initialContentSize(imageSize: CGSize(width: 4000, height: 3000),
                                                            visibleFrameSize: CGSize(width: 500, height: 400), backingScale: 1)
                == CGSize(width: 480, height: 360))
    }

    /// 0003: the 100 % definition counts one image pixel as one *device* pixel, so the
    /// image size is divided by the backing scale before 0001's formula.
    @Test func initialContentSizeRetinaFitsAtActualSize() {
        // 2000×1600 px ÷ 2 = 1000×800 pt ≤ maximum (2048, 1152) → exactly that: the image
        // shows at 100 % without large empty margins.
        #expect(DocumentWindowController.initialContentSize(imageSize: CGSize(width: 2000, height: 1600),
                                                            visibleFrameSize: CGSize(width: 2560, height: 1440),
                                                            backingScale: 2)
                == CGSize(width: 1000, height: 800))
    }

    @Test func initialContentSizeRetinaSmallImageUsesMinimum() {
        // 64×48 ÷ 2 = 32×24 pt < the (480, 360) minimum.
        #expect(DocumentWindowController.initialContentSize(imageSize: CGSize(width: 64, height: 48),
                                                            visibleFrameSize: CGSize(width: 2560, height: 1440),
                                                            backingScale: 2)
                == CGSize(width: 480, height: 360))
    }

    @Test func initialContentSizeScale1Unchanged() {
        // 2000×1600 pt: x stays, y caps at floor(1440 × 0.8) = 1152 — 0001's result.
        #expect(DocumentWindowController.initialContentSize(imageSize: CGSize(width: 2000, height: 1600),
                                                            visibleFrameSize: CGSize(width: 2560, height: 1440),
                                                            backingScale: 1)
                == CGSize(width: 2000, height: 1152))
    }

    /// A zero (or negative, or NaN) backing scale is treated as 1 — never a divide-by-zero.
    @Test func initialContentSizeInvalidScaleTreatedAs1() {
        #expect(DocumentWindowController.initialContentSize(imageSize: CGSize(width: 2000, height: 1600),
                                                            visibleFrameSize: CGSize(width: 2560, height: 1440),
                                                            backingScale: 0)
                == CGSize(width: 2000, height: 1152))
        #expect(DocumentWindowController.initialContentSize(imageSize: CGSize(width: 2000, height: 1600),
                                                            visibleFrameSize: CGSize(width: 2560, height: 1440),
                                                            backingScale: -2)
                == CGSize(width: 2000, height: 1152))
        #expect(DocumentWindowController.initialContentSize(imageSize: CGSize(width: 2000, height: 1600),
                                                            visibleFrameSize: CGSize(width: 2560, height: 1440),
                                                            backingScale: .nan)
                == CGSize(width: 2000, height: 1152))
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
