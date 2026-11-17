import CoreGraphics
import Foundation
import Testing

@testable import PaintDotMac

/// `FloatingPixelsHistoryItem` / `MoveSelectedPixelsHistory` (spec 0020 *Test plan*):
/// 8 × 8 layer `L(x, y) = (x·30, y·30, 100, 255)`, rect selection (2, 2, 3,  3); expected
/// values hand-computed, never read back from the code under test.
@MainActor
struct FloatingPixelsHistoryItemTests {
    private func l(_ x: Int, _ y: Int) -> ColorRGBA8 {
        ColorRGBA8(red: UInt8((30 * x) % 256), green: UInt8((30 * y) % 256), blue: 100, alpha: 255)
    }

    private func baseState() -> DocumentState {
        var surface = TiledSurface(size: PixelSize(width: 8, height: 8))
        for y in 0..<8 {
            for x in 0..<8 {
                surface.setPixel(l(x, y), at: PixelPoint(x: x, y: y))
            }
        }
        return DocumentState(image: LayeredImage(surface: surface),
                             selection: Selection(rect: CGRect(x: 2, y: 2, width: 3, height: 3),
                                                  canvasSize: PixelSize(width: 8, height: 8)))
    }

    private func lifted(from state: DocumentState) throws -> FloatingPixels {
        try #require(FloatingPixels.lift(from: state, duplicate: false, baseStepID: 0))
    }

    /// A (+1, 0) move of the lifted pixels — the same sequence the tool's mouse-up runs:
    /// render into a copy, move the selection, keep the floating state.
    private func moved(_ floating: FloatingPixels, from state: DocumentState,
                       dx: Int = 1, dy: Int = 0) -> DocumentState {
        var moved = floating
        moved.session = floating.session.translatedBy(dx: dx, dy: dy)
        var after = state
        moved.render(into: &after.image.activeLayer.surface, region: state.image.size.bounds)
        after.selection = moved.transformedSelection(antialiased: true)
        after.floatingPixels = moved
        return after
    }

    /// Changed pixels in a diff, counted byte-wise against the empty tile.
    private func changedPixels(_ diff: TileDiff) -> Int {
        let empty = Tile()
        return diff.entries.reduce(0) { total, entry in
            let before = entry.before ?? empty
            let after = entry.after ?? empty
            var count = 0
            for offset in stride(from: 0, to: Tile.byteCount, by: 4) {
                if Array(before.bytes[offset..<offset + 4]) != Array(after.bytes[offset..<offset + 4]) {
                    count += 1
                }
            }
            return total + count
        }
    }

    // MARK: - The floating-state item

    @Test func applyRevert() throws {
        let state = baseState()
        let floating = try lifted(from: state)
        let item = FloatingPixelsHistoryItem(name: "Move Pixels", before: nil, after: floating)
        #expect(state.floatingPixels == nil)
        var applied = state
        item.apply(to: &applied)
        #expect(applied.floatingPixels == floating)
        #expect(applied.image == state.image, "the floating item touches no pixels")
        item.revert(&applied)
        #expect(applied == state)

        // "Finish Pixels": f → nil, and back.
        var floatingState = state
        floatingState.floatingPixels = floating
        let finish = MoveSelectedPixelsHistory.finishStep(floating)
        #expect(finish.name == "Finish Pixels")
        var finished = floatingState
        finish.apply(to: &finished)
        #expect(finished.floatingPixels == nil)
        finish.revert(&finished)
        #expect(finished == floatingState, "undoing Finish restores the floating state (H-3)")
    }

    @Test func noOpWhenEqual() throws {
        let floating = try lifted(from: baseState())
        #expect(FloatingPixelsHistoryItem(name: "Move Pixels",
                                          before: floating, after: floating).isNoOp)
        #expect(FloatingPixelsHistoryItem(name: "Move Pixels",
                                          before: nil, after: nil).isNoOp)
        var moved = floating
        moved.session = floating.session.translatedBy(dx: 1, dy: 0)
        #expect(!FloatingPixelsHistoryItem(name: "Move Pixels",
                                           before: floating, after: moved).isNoOp)
    }

    @Test func changeIsSelection() throws {
        let floating = try lifted(from: baseState())
        let item = FloatingPixelsHistoryItem(name: "Move Pixels", before: nil, after: floating)
        #expect(item.change == .selection, "ants + handles redraw, no tile upload")
        #expect(item.icon == .moveSelectedPixels)
    }

    @Test func byteCostLiftVsLater() throws {
        // Lift of a 3×3 rect inside one tile of an 8 × 8 layer: the source tile plus the
        // single holed underlay tile; the tiles outside the hole share storage (NF-4).
        let state = baseState()
        let floating = try lifted(from: state)
        let lift = FloatingPixelsHistoryItem(name: "Move Pixels", before: nil, after: floating)
        #expect(lift.byteCost == 524_288)  // 262 144 source + 262 144 holed tile
        #expect(floating.byteCount == 262_144)

        var moved = floating
        moved.session = floating.session.translatedBy(dx: 1, dy: 0)
        let later = FloatingPixelsHistoryItem(name: "Move Pixels", before: floating, after: moved)
        #expect(later.byteCost == 256)
        #expect(MoveSelectedPixelsHistory.finishStep(floating).byteCost == 256)
    }

    // MARK: - The composite gesture step

    @Test func stepComposition() throws {
        let state = baseState()
        let layerID = state.image.layers[0].id
        let floating = try lifted(from: state)
        let after = moved(floating, from: state)
        // The (+1, 0) move changes only tile (0, 0) of the single-tile layer.
        let tiles: Set<TileCoordinate> = [TileCoordinate(column: 0, row: 0)]
        let step = MoveSelectedPixelsHistory.step(
            named: "Rotate Pixels", before: state, after: after, layerID: layerID,
            candidates: tiles)
        #expect(step.name == "Rotate Pixels")
        #expect(step.icon == .moveSelectedPixels)
        #expect(step.change == .pixelsAndSelection([layerID: tiles]),
                "merged change carries the touched tiles")
        #expect(step.isNoOp == false)
        #expect(step.byteCost == step.items.reduce(0) { $0 + $1.byteCost })

        // Apply/revert round-trip the full state (pixels, selection, floating).
        var check = state
        step.apply(to: &check)
        #expect(check == after)
        step.revert(&check)
        #expect(check == state, "undo restores destination AND source pixels exactly")

        // The diff inside the composite is the hand-checkable (+1, 0) change: destination
        // (3,2,3,3) carries L(2…4, 2…4), vacated (2, 2…4) is clear.
        let diffItem = try #require(step.items.first(where: { $0 is TileDiffHistoryItem })
                                        as? TileDiffHistoryItem)
        #expect(changedPixels(diffItem.diff) == 12,
                "columns 2–5 × 3 rows: hole plus destination, overlap included")
    }

    @Test func gestureNames() {
        #expect(MoveSelectedPixelsHistory.name(for: .translate) == "Move Pixels")
        #expect(MoveSelectedPixelsHistory.name(for: .scale(.right)) == "Scale Pixels")
        #expect(MoveSelectedPixelsHistory.name(for: .rotate) == "Rotate Pixels")
    }

    @Test func stepStartsSession() throws {
        let state = baseState()
        let layerID = state.image.layers[0].id
        let floating = try lifted(from: state)
        let after = moved(floating, from: state)

        // The step that first carries the lift (before nil → after floating) starts it.
        var liftAfter = state
        liftAfter.floatingPixels = floating
        let liftStep = MoveSelectedPixelsHistory.step(
            named: "Move Pixels", before: state, after: liftAfter,
            layerID: layerID, candidates: [])
        #expect(MoveSelectedPixelsHistory.stepStartsSession(
            HistoryStep(id: 1, name: "Move Pixels", icon: .moveSelectedPixels,
                        item: liftStep), id: floating.id))
        // …even when the composite's other items make it the full gesture record.
        #expect(MoveSelectedPixelsHistory.stepStartsSession(
            HistoryStep(id: 2, name: "Move Pixels", icon: .moveSelectedPixels,
                        item: laterStep(state: state, withFloating: floating, after: after)),
            id: floating.id) == false,
            "a gesture over already-floating pixels has before != nil → not the start")
        #expect(!MoveSelectedPixelsHistory.stepStartsSession(
            HistoryStep(id: 3, name: "Move Pixels", icon: .moveSelectedPixels, item: liftStep),
            id: UUID()), "another session's id never matches")
        #expect(!MoveSelectedPixelsHistory.stepStartsSession(
            HistoryStep(id: 0, name: "New Image", icon: .newImage, item: nil),
            id: floating.id), "the base step has no item")
        // The bare floating item answers too (the budget-folded restore step is one).
        #expect(FloatingPixelsHistoryItem(name: "Move Pixels", before: nil,
                                          after: floating).startsSession(floating.id))
    }

    private func laterStep(state: DocumentState, withFloating floating: FloatingPixels,
                           after: DocumentState) -> CompositeHistoryItem {
        var before = state
        before.floatingPixels = floating
        return MoveSelectedPixelsHistory.step(named: "Move Pixels", before: before,
                                              after: after, layerID: state.image.layers[0].id,
                                              candidates: [])
    }
}
