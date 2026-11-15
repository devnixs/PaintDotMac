import AppKit
import MetalKit

/// The document canvas: an `MTKView` driven by `MetalCanvasRenderer` (spec 0003). Redraws on
/// demand only — the transform, the image, the size, the backing scale, or the appearance
/// (NF-2: no idle GPU work). It handles no mouse, scroll, or magnify events yet (0004 adds
/// `CanvasNavigation`, 0006 `CanvasInputRouter`), but accepts first responder so later specs
/// can route keys.
///
/// Keeps 0001's accessibility contract: element, role `.image`, identifier `canvas`, label
/// `"Canvas"`, value `"<width> × <height>"` of the current image. The zoom is not exposed
/// here — 0004's `statusBar.zoom` shows it.
@MainActor
final class CanvasView: MTKView {
    /// 0001's placeholder accessibility contract, kept verbatim.
    static let accessibilityIdentifierValue = "canvas"

    /// The document image. Assigning the updated image after an edit is all 0008/0009 need:
    /// the renderer finds changed tiles itself through `changedTiles(since:)`.
    var image: LayeredImage? {
        didSet {
            setAccessibilityValue(image?.size.description ?? "")
            applyInitialZoomIfNeeded()
            needsDisplay = true
        }
    }

    /// The view ↔ device ↔ canvas transform. 0004 drives it; setting it redraws.
    var transform: CanvasTransform {
        didSet {
            onTransformChange?(transform)
            needsDisplay = true
        }
    }

    /// Hook for 0004's status bar; fired whenever `transform` changes.
    var onTransformChange: ((CanvasTransform) -> Void)?

    /// The window's navigation (0004); owns every zoom/pan transform change. Nil for bare
    /// views (unit tests) — navigation events then fall through to the responder chain.
    weak var navigation: CanvasNavigation?

    /// Non-nil when the Metal device and renderer came up. The window controller shows the
    /// `canvas.unavailable` label instead of this view when false.
    private(set) var isMetalAvailable = false
    /// Why Metal failed (logged by the window controller), `nil` when available.
    private(set) var metalFailure: (any Error)?

    private let renderer: MetalCanvasRenderer?
    private let commandQueue: MTLCommandQueue?
    private var didApplyInitialZoom = false

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        var createdRenderer: MetalCanvasRenderer?
        var failure: (any Error)?
        if let device {
            do {
                createdRenderer = try MetalCanvasRenderer(device: device)
            } catch {
                failure = error
            }
        } else {
            failure = CanvasRendererError.libraryUnavailable
        }
        renderer = createdRenderer
        metalFailure = failure
        commandQueue = device?.makeCommandQueue()
        transform = CanvasTransform(
            imageSize: PixelSize(width: 1, height: 1),
            viewSize: frameRect.size,
            backingScale: 1,
            zoom: 1,
            center: CGPoint(x: 0.5, y: 0.5)
        )
        super.init(frame: frameRect, device: device)
        isMetalAvailable = createdRenderer != nil && commandQueue != nil
        colorPixelFormat = .bgra8Unorm
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        framebufferOnly = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier(Self.accessibilityIdentifierValue)
        setAccessibilityLabel("Canvas")
        setAccessibilityValue("")
    }

    /// A canvas on the system default Metal device (`nil` device → `isMetalAvailable == false`).
    convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, device: MTLCreateSystemDefaultDevice())
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("not used")  // the app loads no nibs; nothing can reach this
    }

    override var acceptsFirstResponder: Bool { true }

    /// Re-forget all tile textures (whole-image replacement: revert, 0008's `.structure`
    /// changes) and redraw.
    func invalidateAll() {
        renderer?.invalidateAll()
        needsDisplay = true
    }

    // MARK: - Layout and backing scale

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let navigation {
            // 0004: keep zoom and view-center point, re-clamp (live resize included).
            navigation.viewResized(to: bounds.size)
        } else {
            var updated = transform
            updated.viewSize = bounds.size
            transform = updated
        }
        applyInitialZoomIfNeeded()
    }

    // MARK: - Navigation events (0004)

    override func magnify(with event: NSEvent) {
        guard navigation != nil else { super.magnify(with: event); return }
        navigation?.magnify(magnification: Double(event.magnification),
                            atView: pointInThis(from: event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard navigation != nil else { super.scrollWheel(with: event); return }
        navigation?.scroll(
            deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY),
            isPrecise: event.hasPreciseScrollingDeltas,
            zoomModifiers: event.modifierFlags.contains(.command),
            atView: pointInThis(from: event)
        )
    }

    override func keyDown(with event: NSEvent) {
        guard navigation?.keyDown(event) != true else { return }  // Space consumed
        super.keyDown(with: event)  // other keys go up the responder chain
    }

    override func keyUp(with event: NSEvent) {
        guard navigation?.keyUp(event) != true else { return }
        super.keyUp(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let pans = navigation?.mouseDown(atView: pointInThis(from: event)) ?? false
        if !pans { super.mouseDown(with: event) }  // 0006 routes this to the active tool
    }

    override func mouseDragged(with event: NSEvent) {
        navigation?.mouseDragged(toView: pointInThis(from: event))
        if navigation?.spacePan.isPanning != true { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if navigation?.spacePan.isPanning != true { super.mouseUp(with: event) }
        navigation?.mouseUp()
    }

    override func mouseMoved(with event: NSEvent) {
        navigation?.cursorMoved(toView: pointInThis(from: event))
    }

    override func mouseExited(with event: NSEvent) {
        navigation?.cursorExited()
    }

    override func cursorUpdate(with event: NSEvent) {
        if let navigation { navigation.updateCursor() } else { super.cursorUpdate(with: event) }
    }

    private func pointInThis(from event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    // MARK: - Pointer tracking (0004)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                      .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var canvasBackingScale: Double { Double(window?.backingScaleFactor ?? 1) }

    private func updateBackingScale() {
        var updated = transform
        updated.backingScale = canvasBackingScale
        transform = updated
        applyInitialZoomIfNeeded()
    }

    /// The initial zoom (CAN-6, D-29) is computed once, at the first point where both a
    /// non-zero size and an image exist; later resizes keep the zoom and center.
    private func applyInitialZoomIfNeeded() {
        guard !didApplyInitialZoom, let image, bounds.width > 0, bounds.height > 0 else { return }
        didApplyInitialZoom = true
        transform = CanvasTransform.initial(
            imageSize: image.size, viewSize: bounds.size, backingScale: canvasBackingScale
        )
    }

    // MARK: - Drawing

    /// The frame `draw()` renders. Exposed (internal) so headless integration tests can
    /// render the window's canvas state offscreen. `nil` without an image or renderer.
    func currentCanvasFrame() -> CanvasFrame? {
        guard let image else { return nil }
        return CanvasFrame(
            image: image,
            transform: transform,
            checkerboard: .standard,
            backgroundColor: Self.currentBackgroundColor()
        )
    }

    /// `NSColor.underPageBackgroundColor` resolved for the current appearance and converted
    /// to sRGB (APP-7); refreshed on every redraw, so appearance changes follow the system.
    private static func currentBackgroundColor() -> ColorRGBA8 {
        var resolved: ColorRGBA8?
        NSAppearance.currentDrawing().performAsCurrentDrawingAppearance {
            guard let color = NSColor.underPageBackgroundColor.usingColorSpace(.sRGB),
                  let components = color.cgColor.components, components.count >= 3
            else { return }
            resolved = ColorRGBA8(
                red: UInt8(clamping: Int(clampedDouble: components[0] * 255)),
                green: UInt8(clamping: Int(clampedDouble: components[1] * 255)),
                blue: UInt8(clamping: Int(clampedDouble: components[2] * 255)),
                alpha: UInt8(clamping: Int(clampedDouble: color.cgColor.alpha * 255))
            )
        }
        // A documented appearance always converts; this keeps a failure a plain dark gray
        // instead of a crash or a wrong clear color.
        return resolved ?? ColorRGBA8(red: 50, green: 50, blue: 50, alpha: 255)
    }

    override func draw() {
        guard let renderer, let commandQueue, let frame = currentCanvasFrame(),
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }  // no drawable (window offscreen or minimized): nothing to do
        renderer.encode(frame, to: drawable.texture, in: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
