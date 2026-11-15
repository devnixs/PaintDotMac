import AppKit
import SwiftUI

/// The color wheel (C-2, Paint.NET ColorsWindow.html): the `ColorWheelImage` bitmap — the very
/// numbers `ColorWheelGeometry` hit-tests — with a marker on the **active slot's** cached
/// hue/saturation. Input runs through an `NSView` so the left, right, and Control buttons and
/// the ⌘/⌥/⇧⌘ drag constraints all arrive with their real modifier flags.
struct ColorWheelView: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> ColorWheelNSView {
        ColorWheelNSView(model: model)
    }

    func updateNSView(_ view: ColorWheelNSView, context: Context) {
        view.sync(model: model)
    }
}

/// The wheel's AppKit side (spec 0007). Flipped, so the geometry's view coordinates — y down,
/// hue 0 at 3 o'clock increasing counterclockwise — are the view's own.
@MainActor
final class ColorWheelNSView: NSView {
    static let accessibilityID = "colors.wheel"

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private weak var model: AppModel?
    private var cachedImage: NSImage?
    private var cachedImagePixelSide = 0
    private var lastMarker: HSVColor?
    /// The target slot's cached HSV when the drag began: what a ⌘/⌥/⇧⌘ constraint pins.
    private var dragStartCache: HSVColor?
    private var dragSlot: ColorSlot?

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier(Self.accessibilityID)
        setAccessibilityLabel("Color wheel")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ColorWheelNSView is never loaded from a nib")
    }

    /// `ColorWheelView.updateNSView` hands the new state over: a new marker repaints, and a new
    /// size or backing scale regenerates the cached bitmap.
    func sync(model: AppModel) {
        self.model = model
        let marker = model.colorEditor.hsv[model.activeColorSlot] ?? HSVColor(rgb: .black)
        setAccessibilityValue("Hue \(marker.displayHue)°, Saturation \(marker.displaySaturation)%")
        if marker != lastMarker {
            lastMarker = marker
            needsDisplay = true
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        if let image = wheelImage(side: side) {
            // `respectFlipped` keeps the bitmap upright in this flipped view, so red really is
            // at 3 o'clock and hue 90 at 12 o'clock.
            image.draw(in: wheelRect(side: side), from: .zero, operation: .sourceOver,
                       fraction: 1, respectFlipped: true, hints: nil)
        }
        drawMarker(in: context, side: side)
    }

    private func wheelRect(side: CGFloat) -> NSRect {
        NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side,
               height: side)
    }

    /// Regenerated only when the point size or the backing scale changes (C-2).
    private func wheelImage(side: CGFloat) -> NSImage? {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let pixelSide = Int((side * scale).rounded())
        guard pixelSide > 0 else { return nil }
        if pixelSide != cachedImagePixelSide {
            cachedImage = ColorWheelImage.makeCGImage(diameter: pixelSide).map {
                NSImage(cgImage: $0, size: NSSize(width: side, height: side))
            }
            cachedImagePixelSide = pixelSide
        }
        return cachedImage
    }

    private func drawMarker(in context: CGContext, side: CGFloat) {
        guard let model, let cache = model.colorEditor.hsv[model.activeColorSlot] else { return }
        let rect = wheelRect(side: side)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let point = ColorWheelGeometry.point(hue: cache.hue, saturation: cache.saturation,
                                             center: center, radius: Double(side) / 2)
        let diameter = Self.markerDiameter
        let marker = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                            width: diameter, height: diameter)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(Self.markerLineWidth + 1)
        context.strokeEllipse(in: marker)
        context.setStrokeColor(NSColor.labelColor.cgColor)
        context.setLineWidth(Self.markerLineWidth)
        context.strokeEllipse(in: marker)
    }

    private static let markerDiameter: CGFloat = 11
    private static let markerLineWidth: CGFloat = 1.5

    // MARK: - Input

    override func mouseDown(with event: NSEvent) { beginDrag(event) }
    override func mouseDragged(with event: NSEvent) { continueDrag(event) }
    override func mouseUp(with event: NSEvent) { endDrag() }
    override func rightMouseDown(with event: NSEvent) { beginDrag(event) }
    override func rightMouseDragged(with event: NSEvent) { continueDrag(event) }
    override func rightMouseUp(with event: NSEvent) { endDrag() }

    /// Paint.NET: left installs into the active slot, right (or Control) into the inactive one.
    private func beginDrag(_ event: NSEvent) {
        guard let model else { return }
        let slot = Self.isSecondaryButton(event) ? model.activeColorSlot.other : model.activeColorSlot
        dragSlot = slot
        dragStartCache = model.colorEditor.hsv[slot] ?? HSVColor(rgb: model.colors[slot])
        apply(event)
    }

    private func continueDrag(_ event: NSEvent) {
        guard dragSlot != nil else { return }
        apply(event)
    }

    private func endDrag() {
        dragSlot = nil
        dragStartCache = nil
    }

    private static func isSecondaryButton(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown || event.type == .rightMouseDragged
            || event.modifierFlags.contains(.control)
    }

    /// One pointer event → the slot's new hue/saturation, through that event's constraint.
    private func apply(_ event: NSEvent) {
        guard let model, let slot = dragSlot, let start = dragStartCache else { return }
        let side = min(bounds.width, bounds.height)
        let rect = wheelRect(side: side)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = Double(side) / 2
        let point = convert(event.locationInWindow, from: nil)
        guard point.x.isFinite, point.y.isFinite,
              let sampled = ColorWheelGeometry.hueSaturation(at: point, center: center,
                                                            radius: radius)
        else { return }
        // The exact center has no direction: keep the slot's hue rather than geometry's 0.
        let hue = sampled.saturation == 0 ? start.hue : sampled.hue
        let constraint = ColorWheelGeometry.Constraint.constraint(
            command: event.modifierFlags.contains(.command),
            option: event.modifierFlags.contains(.option),
            shift: event.modifierFlags.contains(.shift)
        )
        let selection = ColorWheelGeometry.constrained(hue: hue, saturation: sampled.saturation,
                                                      current: start, constraint: constraint)
        model.applyWheel(hue: selection.hue, saturation: selection.saturation, to: slot)
    }
}
