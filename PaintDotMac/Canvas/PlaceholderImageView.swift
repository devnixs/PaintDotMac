import AppKit
import CoreGraphics

/// Temporary stand-in for the canvas: draws the active layer of the document image centered
/// at native size, scaled down to fit. 0003 replaces it with the Metal `CanvasView`, which
/// must keep the `canvas` accessibility identifier and the `"<width> × <height>"` value
/// format (the decoded size, `PixelSize.description`), so VoiceOver and the integration
/// tests keep working.
@MainActor
final class PlaceholderImageView: NSView {
    private let image: LayeredImage
    private let imageGraphics: CGImage?

    /// A view that accepts no first responder and implements no edit actions, so
    /// Cut/Copy/Paste/Select All stay disabled while a document is open.
    init(image: LayeredImage) {
        self.image = image
        self.imageGraphics = image.activeLayer.surface.makeCGImage()
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier(Self.accessibilityIdentifierValue)
        setAccessibilityLabel("Canvas")
        setAccessibilityValue(image.size.description)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")  // the app loads no nibs; nothing can reach this
    }

    // MARK: - Accessibility contract (kept by CanvasView in 0003)

    static let accessibilityIdentifierValue = "canvas"

    override var acceptsFirstResponder: Bool { false }

    // MARK: - Drawing

    /// The view is not flipped, so drawing through the current `CGContext` shows the image
    /// upright.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(bounds)

        guard let imageGraphics else { return }
        let imageSize = CGSize(width: image.size.width, height: image.size.height)
        let rect = Self.imageRect(imageSize: imageSize, in: bounds)
        guard !rect.isEmpty else { return }
        context.interpolationQuality = rect.size == imageSize ? .none : .high
        context.draw(imageGraphics, in: rect)
    }

    // MARK: - Layout

    /// Scales the image to fit `bounds`, never upscales, and centers it; the origin is
    /// floored, the size is not rounded. Returns `.zero` for empty bounds or a degenerate
    /// image, and never NaN or negative sizes.
    static func imageRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }
        let scale = min(1, bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(
            x: bounds.origin.x + ((bounds.width - size.width) / 2).rounded(.down),
            y: bounds.origin.y + ((bounds.height - size.height) / 2).rounded(.down)
        )
        return CGRect(origin: origin, size: size)
    }
}
