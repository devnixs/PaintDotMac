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
    /// Settable so a test can drive one pair of colors (0007).
    var colors: ColorSelection = .default
    /// The Color Picker's slot writes, in order (spec 0012).
    private(set) var setColorCalls: [(color: ColorRGBA8, slot: ColorSlot)] = []
    /// Settable so a test can install a clip directly (0009). Without an override the
    /// fake reports the document's selection mask as its clip (0013), exactly like
    /// `CanvasToolSession` — except that the fake also clips a full-canvas mask, so
    /// clipping behavior is testable independent of the session's `isFull` shortcut.
    var clipMaskOverride: (any BrushClipMask)?
    var paintClipMask: (any BrushClipMask)? {
        get { clipMaskOverride ?? state.selection?.mask }
        set { clipMaskOverride = newValue }
    }
    /// The document's current selection (0013); tools and the 0014+ selection tools read
    /// it. Mutate it through `performHistory(SelectionHistoryItem…)`.
    var selection: Selection? { state.selection }
    /// Counts `updateImage` calls (0009).
    private(set) var imageUpdates: Int = 0
    /// The image lives in `state.image` (0009): `updateImage` opens `state` to its
    /// closure, so `PaintbrushTool`'s per-event writes land in the one storage and
    /// survive across events — the stroke's `begin` snapshot, its live writes and the
    /// commit's diff all read the same image.
    private var imageStorage: LayeredImage {
        get { state.image }
        set { state.image = newValue }
    }

    private(set) var activatedTools: [ToolID] = []
    private(set) var overlays: [ToolOverlay?] = []
    private(set) var cursorInvalidations = 0

    init(size: PixelSize = PixelSize(width: 64, height: 64), background: ColorRGBA8 = .clear,
         image: LayeredImage? = nil) {
        state = DocumentState(image: image ?? .blank(size: size, fill: background))
        history = HistoryStack(base: .newImage)
    }

    func activateTool(_ id: ToolID) { activatedTools.append(id) }

    /// Applies to the fake's own `colors` and records the call (spec 0012).
    func setColor(_ color: ColorRGBA8, for slot: ColorSlot) {
        colors[slot] = color
        setColorCalls.append((color, slot))
    }

    func setOverlay(_ overlay: ToolOverlay?) { overlays.append(overlay) }

    func invalidateCursor() { cursorInvalidations += 1 }

    func commitHistory(_ item: any HistoryItem) {
        history.commit(item)
    }

    func performHistory(_ item: any HistoryItem) {
        history.perform(item, on: &state)
    }

    func updateImage(_ body: (inout LayeredImage) -> Void) {
        imageUpdates += 1
        body(&state.image)
    }

    /// Runs a navigation step on the fake's `HistoryStack` (tools test undo/redo
    /// without an `UndoBridge`; 0009's property tests).
    func navigateForTests(_ step: (inout HistoryStack, inout DocumentState) -> Void) {
        step(&history, &state)
    }
}
