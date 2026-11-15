import AppKit
import CoreGraphics

/// Temporary stand-in for the canvas: draws the decoded image centered at native size, scaled
/// down to fit. 0003 replaces it with the Metal `CanvasView`, which must keep the `canvas`
/// accessibility identifier and the `"<width> × <height>"` value format, so VoiceOver and the
/// integration tests keep working.
@MainActor
final class PlaceholderImageView: NSView {
    private let image: CGImage

    /// A view that accepts no first responder and implements no edit actions, so
    /// Cut/Copy/Paste/Select All stay disabled while a document is open.
    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier(Self.accessibilityIdentifierValue)
        setAccessibilityLabel("Canvas")
        setAccessibilityValue(Self.accessibilityValue(imageSize: CGSize(width: image.width, height: image.height)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")  // the app loads no nibs; nothing can reach this
    }

    // MARK: - Accessibility contract (kept by CanvasView in 0003)

    static let accessibilityIdentifierValue = "canvas"

    /// The pixel size with U+00D7 and single spaces, for example `"64 × 48"`.
    static func accessibilityValue(imageSize: CGSize) -> String {
        "\(Int(imageSize.width)) × \(Int(imageSize.height))"
    }

    override var acceptsFirstResponder: Bool { false }

    // MARK: - Drawing

    /// The view is not flipped, so drawing through the current `CGContext` shows the image
    /// upright.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(bounds)

        let imageSize = CGSize(width: image.width, height: image.height)
        let rect = Self.imageRect(imageSize: imageSize, in: bounds)
        guard !rect.isEmpty else { return }
        context.interpolationQuality = rect.size == imageSize ? .none : .high
        context.draw(image, in: rect)
    }

    // MARK: - Layout

    /// Scales the image to fit `bounds`, never upscales, and centers it; the origin is floored,
    /// the size is not rounded. Returns `.zero` for empty bounds or a degenerate image, and
    /// never NaN or negative sizes.
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
