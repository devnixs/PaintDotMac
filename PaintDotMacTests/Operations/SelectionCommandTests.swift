import Foundation
import Testing

@testable import PaintDotMac

/// `SelectionCommand` names, icons, enablement, and no-op rules (spec 0013; E-3, D-40,
/// H-6).
struct SelectionCommandTests {
    private func state(selection: Selection? = nil, side: Int = 100) -> DocumentState {
        var surface = TiledSurface(size: PixelSize(width: side, height: side))
        surface.fill(.white)
        return DocumentState(image: LayeredImage(surface: surface), selection: selection)
    }

    private func rectSelection(side: Int = 100) -> Selection {
        Selection(rect: CGRect(x: 10, y: 10, width: 20, height: 20),
                  canvasSize: PixelSize(width: side, height: side))!
    }

    @Test func names() {
        #expect(SelectionCommand.selectAll.name == "Select All")
        #expect(SelectionCommand.deselect.name == "Deselect")
        #expect(SelectionCommand.invertSelection.name == "Invert Selection")
    }

    @Test func icons() {
        #expect(SelectionCommand.selectAll.icon == .selectAll)
        #expect(SelectionCommand.deselect.icon == .deselect)
        #expect(SelectionCommand.invertSelection.icon == .invertSelection)
    }

    @Test func enablement() {
        let empty = state()
        #expect(SelectionCommand.selectAll.isEnabled(in: empty))
        #expect(!SelectionCommand.deselect.isEnabled(in: empty))
        #expect(!SelectionCommand.invertSelection.isEnabled(in: empty))

        let withSelection = state(selection: rectSelection())
        for command in SelectionCommand.allCases {
            #expect(command.isEnabled(in: withSelection), "\(command.name)")
        }
    }

    @Test func selectAllItem() throws {
        let state = self.state()
        let item = try #require(SelectionCommand.selectAll.makeHistoryItem(for: state))
        #expect(item.after == Selection.all(canvasSize: PixelSize(width: 100, height: 100)))
        #expect(item.before == nil)
        #expect(item.name == "Select All")
        #expect(!item.isNoOp)
    }

    @Test func selectAllWhenAllSelectedIsNoOp() {
        let state = self.state(selection: .all(canvasSize: PixelSize(width: 100, height: 100)))
        #expect(SelectionCommand.selectAll.makeHistoryItem(for: state) == nil,
                "already selected: no step (H-6)")
    }

    @Test func deselectItem() throws {
        let selection = rectSelection()
        let item = try #require(SelectionCommand.deselect
            .makeHistoryItem(for: state(selection: selection)))
        #expect(item.after == nil)
        #expect(item.before == selection)
        #expect(item.name == "Deselect")
    }

    @Test func deselectWithoutSelectionIsNil() {
        #expect(SelectionCommand.deselect.makeHistoryItem(for: state()) == nil)
    }

    @Test func invertItem() throws {
        let selection = rectSelection()
        let item = try #require(SelectionCommand.invertSelection
            .makeHistoryItem(for: state(selection: selection)))
        #expect(item.after?.mask == selection.mask.inverted())
        #expect(item.name == "Invert Selection")
    }

    @Test func invertOfAllDeselects() throws {
        let all = Selection.all(canvasSize: PixelSize(width: 100, height: 100))
        let item = try #require(SelectionCommand.invertSelection
            .makeHistoryItem(for: state(selection: all)))
        #expect(item.after == nil, "inverting Select All deselects")
        #expect(!item.isNoOp)
        #expect(item.name == "Invert Selection")
    }
}
