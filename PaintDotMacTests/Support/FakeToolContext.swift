import AppKit
import Foundation
@testable import PaintDotMac

/// One recorded `setZoom` call.
struct ZoomCall: Equatable {
    var zoom: Double
    var anchor: CGPoint
}

/// Records every `CanvasNavigating` call without moving anything (spec 0006 test support).
/// `transform` is settable so tests pin the geometry; later specs extend it.
@MainActor
final class FakeCanvasNavigation: CanvasNavigating {
    enum PanCall: Equatable {
        case begin(CGPoint)
        case `continue`(CGPoint)
        case end
    }

    var transform: CanvasTransform
    private(set) var setZoomCalls: [ZoomCall] = []
    private(set) var panCalls: [PanCall] = []

    /// Image 4000×3000, view 800×600 pt, backing scale 1, zoom 1, centered (the 0006 test
    /// default).
    static let defaultTransform = CanvasTransform(
        imageSize: PixelSize(width: 4000, height: 3000),
        viewSize: CGSize(width: 800, height: 600),
        backingScale: 1,
        zoom: 1,
        center: CGPoint(x: 2000, y: 1500)
    )

    init(transform: CanvasTransform = FakeCanvasNavigation.defaultTransform) {
        self.transform = transform
    }

    func setZoom(_ zoom: Double, anchoredAtView viewPoint: CGPoint) {
        setZoomCalls.append(ZoomCall(zoom: zoom, anchor: viewPoint))
    }

    func beginPan(atView viewPoint: CGPoint) { panCalls.append(.begin(viewPoint)) }

    func continuePan(toView viewPoint: CGPoint) { panCalls.append(.continue(viewPoint)) }

    func endPan() { panCalls.append(.end) }
}

/// The `ToolContext` for unit tests (spec 0006 test support): an
/// `InMemoryToolOptionStore`, a `FakeCanvasNavigation`, a 64×64 `LayeredImage`, recorded
/// activation/overlay/cursor calls, and a settable `previousToolID`. Since 0008 it also
/// owns a real `HistoryStack` (base `.newImage`) and a `DocumentState`, so tools exercise
/// the official history path. Later specs extend it with their added requirements.
@MainActor
final class FakeToolContext: ToolContext {
    /// The fake's undoable document state; `image` is `state.image`.
    private(set) var state: DocumentState
    /// The recorded history of `performHistory`/`commitHistory` calls.
    private(set) var history: HistoryStack
    /// The concrete fake (settable `transform`, recorded calls); `navigation` is the
    /// protocol-typed witness.
    let nav = FakeCanvasNavigation()
    var navigation: any CanvasNavigating { nav }
    /// The concrete store (tests assert on it); `options` is the protocol-typed witness.
    let memoryOptions = InMemoryToolOptionStore()
    var options: any ToolOptionStore { memoryOptions }
    var image: LayeredImage { state.image }
    var transform: CanvasTransform { nav.transform }
    var previousToolID: ToolID?
    /// Settable so a tool test can drive one pair of colors (0007).
    var colors: ColorSelection = .default

    private(set) var activatedTools: [ToolID] = []
    private(set) var overlays: [ToolOverlay?] = []
    private(set) var cursorInvalidations = 0

    init(size: PixelSize = PixelSize(width: 64, height: 64)) {
        state = DocumentState(image: .blank(size: size, fill: .clear))
        history = HistoryStack(base: .newImage)
    }

    func activateTool(_ id: ToolID) { activatedTools.append(id) }

    func setOverlay(_ overlay: ToolOverlay?) { overlays.append(overlay) }

    func invalidateCursor() { cursorInvalidations += 1 }

    func commitHistory(_ item: any HistoryItem) {
        history.commit(item)
    }

    func performHistory(_ item: any HistoryItem) {
        history.perform(item, on: &state)
    }

    func updateImage(_ body: (inout LayeredImage) -> Void) {
        body(&state.image)
    }
}
