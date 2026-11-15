import AppKit
import CoreGraphics

/// One window per document (APP-1). Built in code with no nib; the content view is the Metal
/// `CanvasView` (0003) showing the document image, or a label when Metal is unavailable.
@MainActor
final class DocumentWindowController: NSWindowController {
    /// Native window tabs: `.automatic` follows the user's "Prefer tabs when opening documents"
    /// setting, and the shared tabbing identifier lets Window > Merge All Windows tab documents
    /// together (PRD §5.1 APP-1, D-36).
    static let tabbingIdentifier = "com.thera-engineering.paintdotmac.document"

    /// Tests and later code find document windows with this identifier, separate from the
    /// floating panels 0006 adds.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("documentWindow")

    private static let minimumContentSize = CGSize(width: 480, height: 360)
    private static let visibleFrameFraction: CGFloat = 0.8

    /// The window's canvas, or `nil` when Metal was unavailable and the window shows the
    /// `canvas.unavailable` label instead.
    var canvasView: CanvasView? { window?.contentView as? CanvasView }

    init(image: LayeredImage) {
        let backingScale = NSScreen.main?.backingScaleFactor ?? 1
        let contentSize = Self.initialContentSize(
            imageSize: CGSize(width: image.size.width, height: image.size.height),
            visibleFrameSize: NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900),
            backingScale: backingScale
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

        super.init(window: window)

        let canvas = CanvasView(frame: NSRect(origin: .zero, size: contentSize))
        if canvas.isMetalAvailable {
            // The canvas is the content view and resizes with the window (0004/0006 later
            // insert the status bar and tool options bar around it).
            canvas.autoresizingMask = [.width, .height]
            window.contentView = canvas
            // Assigning the image after the view joined the window lets the initial zoom
            // use the window's real backing scale (CAN-6).
            canvas.image = image
        } else {
            NSLog("PaintDotMac: Metal canvas unavailable: \(String(describing: canvas.metalFailure))")
            window.contentView = Self.metalUnavailableLabel()
        }

        shouldCascadeWindows = true
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")  // the app loads no nibs; nothing can reach this
    }

    /// Shown centered in place of the canvas when no Metal device or renderer is available.
    /// Not reachable on supported hardware; logged by `init`.
    private static func metalUnavailableLabel() -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: "Metal is not available on this Mac.")
        label.setAccessibilityIdentifier("canvas.unavailable")
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    /// The window content size for an image of `imageSize` device pixels on a screen whose
    /// visible frame is `visibleFrameSize` points at `backingScale` device pixels per point.
    /// The image size is first converted to points (`imageSize / backingScale` — at 100 % an
    /// image pixel is one device pixel, CAN-6), then 0001's formula applies unchanged: per
    /// axis `min(max(image, minimum), max(maximum, minimum))` with
    /// `maximum = floor(visible × 0.8)` and `minimum = (480, 360)`. A `backingScale` ≤ 0 or
    /// non-finite is treated as 1.
    static func initialContentSize(imageSize: CGSize, visibleFrameSize: CGSize,
                                   backingScale: CGFloat) -> CGSize {
        let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        let imageSizeInPoints = CGSize(width: imageSize.width / scale, height: imageSize.height / scale)
        let maximum = CGSize(
            width: (visibleFrameSize.width * visibleFrameFraction).rounded(.down),
            height: (visibleFrameSize.height * visibleFrameFraction).rounded(.down)
        )
        let minimum = minimumContentSize
        return CGSize(
            width: min(max(imageSizeInPoints.width, minimum.width), max(maximum.width, minimum.width)),
            height: min(max(imageSizeInPoints.height, minimum.height), max(maximum.height, minimum.height))
        )
    }
}
