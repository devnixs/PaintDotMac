import AppKit
import CoreGraphics
import SwiftUI

/// One window per document (APP-1). Built in code with no nib; the content view is a stack of
/// the Metal `CanvasView` (0003) filling the window above the SwiftUI status bar (0004,
/// APP-5), or a label in place of the canvas when Metal is unavailable.
@MainActor
final class DocumentWindowController: NSWindowController, NSMenuItemValidation {
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
    private(set) weak var canvasView: CanvasView?

    /// The document window's status bar state (0004, APP-5).
    private(set) var statusBarModel: StatusBarModel

    /// The window's zoom/pan controller (0004); `nil` when Metal is unavailable (no canvas).
    private(set) var navigation: CanvasNavigation?

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

        // The status bar (APP-5): a fixed-height strip at the bottom of the content view;
        // the canvas fills the rest. Built before `super.init` (Swift requires every stored
        // property initialized there).
        statusBarModel = StatusBarModel(imageSize: image.size, dpi: image.dpi, zoom: 1)
        super.init(window: window)

        let statusBarHeight = StatusBarView.statusBarHeight
        let canvasFrame = NSRect(x: 0, y: statusBarHeight,
                                 width: contentSize.width,
                                 height: max(0, contentSize.height - statusBarHeight))
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))

        let model = statusBarModel
        let statusBar = NSHostingView(rootView: StatusBarView(model: model))
        statusBar.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: statusBarHeight)
        statusBar.autoresizingMask = [.width]

        let canvas = CanvasView(frame: canvasFrame)
        if canvas.isMetalAvailable {
            canvas.autoresizingMask = [.width, .height]
            canvasView = canvas
            // Space and later tool keys need the canvas in the responder chain first.
            window.initialFirstResponder = canvas
        } else {
            NSLog("PaintDotMac: Metal canvas unavailable: \(String(describing: canvas.metalFailure))")
            let placeholder = Self.metalUnavailableLabel()
            placeholder.frame = canvasFrame
            placeholder.autoresizingMask = [.width, .height]
            container.addSubview(placeholder)
        }
        if let canvasView { container.addSubview(canvasView) }
        container.addSubview(statusBar)
        window.contentView = container
        if let canvasView {
            // Only valid once the view joined the window.
            window.makeFirstResponder(canvasView)
        }

        if let canvasView {
            // One hook covers every transform change — initial zoom, resize, navigation —
            // keeping the status-bar zoom in step (APP-5).
            canvasView.onTransformChange = { [weak model] transform in
                model?.zoom = transform.zoom
            }
            navigation = CanvasNavigation(canvasView: canvasView, statusBar: model)
            // Assigning the image after the view joined the window lets the initial zoom
            // use the window's real backing scale (CAN-6).
            canvasView.image = image
        }

        shouldCascadeWindows = true
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")  // the app loads no nibs; nothing can reach this
    }

    // MARK: - Zoom commands (View menu, spec 0004)

    @objc func zoomIn(_ sender: Any?) { navigation?.zoomIn() }

    @objc func zoomOut(_ sender: Any?) { navigation?.zoomOut() }

    @objc func zoomToWindow(_ sender: Any?) { navigation?.zoomToWindow() }

    @objc func actualSize(_ sender: Any?) { navigation?.actualSize() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(zoomIn(_:)): return navigation?.canZoomIn ?? false
        case #selector(zoomOut(_:)): return navigation?.canZoomOut ?? false
        default: return true
        }
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
