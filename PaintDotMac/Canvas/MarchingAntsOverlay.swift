import AppKit

/// The marching-ants selection outline (spec 0013; PRD CAN-7, NF-7): a layer-backed view
/// with the canvas's frame, inserted above `CanvasView` and below `ToolOverlayView`,
/// `hitTest` → `nil` so it never eats events.
///
/// Two `CAShapeLayer`s draw `MarchingAnts.viewPath`: a solid white underline and, on top,
/// a black layer dashed `[4, 4]`. `.animated` runs a `lineDashPhase` 0 → 8 animation on
/// the black layer (render-server driven — idle CPU stays near 0 %); `.static` (Reduce
/// Motion) removes it with phase 0; `.hidden` clears both paths.
@MainActor
final class MarchingAntsOverlay: NSView {
    /// Test seam (AGENTS *Headless testing*, no launch hooks): `nil` follows
    /// `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
    var reduceMotionOverride: Bool? {
        didSet { applyMode() }
    }

    /// Internal for the integration test that checks the animation (0013).
    private(set) var dashLayer: CAShapeLayer?

    private let underlineLayer = CAShapeLayer()
    private var selection: Selection?
    private var reduceMotionObserver: NotificationObserverBox?
    private(set) var mode: MarchingAnts.Mode = .hidden

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        configure(underlineLayer)
        layer?.addSublayer(underlineLayer)
        let dashes = CAShapeLayer()
        configure(dashes)
        layer?.addSublayer(dashes)
        dashLayer = dashes
        setAccessibilityElement(true)
        setAccessibilityIdentifier("canvas.marchingAnts")
        setAccessibilityLabel("Selection Outline")
        setAccessibilityValue(MarchingAnts.Mode.hidden.rawValue)
        // Reduce Motion changes take effect without a relaunch (NF-7).
        reduceMotionObserver = NotificationObserverBox(
            center: NSWorkspace.shared.notificationCenter,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        ) { [weak self] in
            MainActor.assumeIsolated { self?.applyMode() }
        }
    }

    private func configure(_ shapeLayer: CAShapeLayer) {
        shapeLayer.fillColor = NSColor.clear.cgColor
        shapeLayer.lineWidth = MarchingAnts.lineWidth
        shapeLayer.strokeColor = NSColor.clear.cgColor
    }

    override var isFlipped: Bool { false }   // like `CanvasView`: view space, y up

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale()
    }

    /// Re-reads the selection outline under the current transform. Called by
    /// `DocumentWindowController` on selection-affecting state changes (including
    /// `reset` — open / Revert), after every transform change, and on Reduce Motion flips.
    func update(selection: Selection?, transform: CanvasTransform) {
        self.selection = selection
        let path = selection.map { MarchingAnts.viewPath(for: $0, transform: transform) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        underlineLayer.path = path
        dashLayer?.path = path
        CATransaction.commit()
        applyBackingScale()
        applyMode()
    }

    /// `.animated`: `lineDashPhase` 0 → `phasePeriod` every 0.5 s, forever; `.static`:
    /// no animation, phase 0; `.hidden`: no stroke at all.
    private func applyMode() {
        let hasSelection = selection != nil
        let reduceMotion = reduceMotionOverride
            ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let newMode = MarchingAnts.mode(hasSelection: hasSelection, reduceMotion: reduceMotion)
        guard let dashLayer else { return }
        self.mode = newMode
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch newMode {
        case .hidden:
            underlineLayer.strokeColor = NSColor.clear.cgColor
            dashLayer.strokeColor = NSColor.clear.cgColor
            dashLayer.lineDashPattern = []
            dashLayer.removeAnimation(forKey: Self.phaseAnimationKey)
            dashLayer.lineDashPhase = 0
        case .static:
            underlineLayer.strokeColor = NSColor.white.cgColor
            dashLayer.strokeColor = NSColor.black.cgColor
            dashLayer.lineDashPattern = MarchingAnts.dashPattern.map { NSNumber(value: Double($0)) }
            dashLayer.removeAnimation(forKey: Self.phaseAnimationKey)
            dashLayer.lineDashPhase = 0
        case .animated:
            underlineLayer.strokeColor = NSColor.white.cgColor
            dashLayer.strokeColor = NSColor.black.cgColor
            dashLayer.lineDashPattern = MarchingAnts.dashPattern.map { NSNumber(value: Double($0)) }
            if dashLayer.animation(forKey: Self.phaseAnimationKey) == nil {
                let animation = CABasicAnimation(keyPath: "lineDashPhase")
                animation.fromValue = 0
                animation.toValue = MarchingAnts.phasePeriod
                animation.duration = MarchingAnts.animationDuration
                animation.repeatCount = .infinity
                animation.isRemovedOnCompletion = false
                dashLayer.add(animation, forKey: Self.phaseAnimationKey)
            }
        }
        CATransaction.commit()
        setAccessibilityValue(newMode.rawValue)
    }

    private static let phaseAnimationKey = "lineDashPhase"

    private func applyBackingScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shapeLayer in [underlineLayer, dashLayer].compactMap({ $0 }) {
            shapeLayer.contentsScale = scale
        }
        layer?.contentsScale = scale
        CATransaction.commit()
    }
}
