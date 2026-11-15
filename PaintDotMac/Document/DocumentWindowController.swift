import AppKit
import CoreGraphics

/// One window per document (APP-1). Built in code with no nib; 0003 replaces the placeholder
/// content view with the Metal `CanvasView`.
@MainActor
final class DocumentWindowController: NSWindowController {
    /// Native window tabs: `.automatic` follows the user's "Prefer tabs when opening documents"
    /// setting, and the shared tabbing identifier lets Window > Merge All Windows tab documents
    /// together (PRD §5.1 APP-1, D-36).
    static let tabbingIdentifier = "com.thera-engineering.paintdotmac.document"

    /// Tests and later code find document windows with this identifier, separate from the
    /// floating panels 0006 adds.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("documentWindow")

    /// One image pixel counts as one point.
    private static let minimumContentSize = CGSize(width: 480, height: 360)
    private static let visibleFrameFraction: CGFloat = 0.8

    init(image: LayeredImage) {
        let contentSize = Self.initialContentSize(
            imageSize: CGSize(width: image.size.width, height: image.size.height),
            visibleFrameSize: NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.tabbingMode = .automatic
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.identifier = Self.windowIdentifier
        window.minSize = CGSize(width: 320, height: 240)

        let canvas = PlaceholderImageView(image: image)
        canvas.frame = NSRect(origin: .zero, size: contentSize)
        canvas.autoresizingMask = [.width, .height]
        window.contentView = canvas

        super.init(window: window)
        shouldCascadeWindows = true
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")  // the app loads no nibs; nothing can reach this
    }

    /// The window content size for an image of `imageSize` on a screen whose visible frame is
    /// `visibleFrameSize`: per axis, `min(max(image, minimum), max(maximum, minimum))` with
    /// `maximum = floor(visible × 0.8)` and `minimum = (480, 360)`.
    static func initialContentSize(imageSize: CGSize, visibleFrameSize: CGSize) -> CGSize {
        let maximum = CGSize(
            width: (visibleFrameSize.width * visibleFrameFraction).rounded(.down),
            height: (visibleFrameSize.height * visibleFrameFraction).rounded(.down)
        )
        let minimum = minimumContentSize
        return CGSize(
            width: min(max(imageSize.width, minimum.width), max(maximum.width, minimum.width)),
            height: min(max(imageSize.height, minimum.height), max(maximum.height, minimum.height))
        )
    }
}
