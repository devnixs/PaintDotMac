import Foundation
import Testing

@testable import PaintDotMac

/// The pure row mapping and click decisions of the History panel (spec 0010, PRD H-1/H-2).
/// Expected values are hand-computed from the spec's rules.
struct HistoryListModelTests {
    private func steps(_ names: [(Int, String, HistoryIcon)]) -> [(id: HistoryStep.ID, name: String, icon: HistoryIcon)] {
        names.map { (id: $0.0, name: $0.1, icon: $0.2) }
    }

    private func openImage(_ count: Int, current: Int) -> HistoryListModel {
        var list: [(Int, String, HistoryIcon)] = [(0, "Open Image", .openImage)]
        for id in 1..<count { list.append((id, "Paintbrush", .paintbrush)) }
        return HistoryListModel(steps: steps(list), currentIndex: current)
    }

    @Test func rowsMirrorStepsInOrder() {
        let model = HistoryListModel(
            steps: steps([(0, "Open Image", .openImage),
                          (1, "Paintbrush", .paintbrush),
                          (2, "Paintbrush", .paintbrush)]),
            currentIndex: 2)
        #expect(model.rows.count == 3)
        #expect(model.rows.map(\.index) == [0, 1, 2])
        #expect(model.rows.map(\.name) == ["Open Image", "Paintbrush", "Paintbrush"])
        #expect(model.rows.map(\.icon) == [.openImage, .paintbrush, .paintbrush])
        #expect(model.rows.map(\.id) == [0, 1, 2])
        #expect(model.currentIndex == 2)
    }

    @Test func rowStatesAroundCurrentIndex() {
        func states(_ model: HistoryListModel) -> [HistoryRowState] { model.rows.map(\.state) }
        let expected = { (current: Int) in
            (0..<5).map { $0 < current ? HistoryRowState.done : $0 == current ? .current : .undone }
        }
        for current in [2, 0, 4] {
            let model = openImage(5, current: current)
            #expect(states(model) == expected(current), "states with current \(current)")
            #expect(model.rows.filter(\.isCurrent).count == 1, "exactly one current")
            #expect(model.currentIndex == current)
            #expect(model.rows.map(\.accessibilityValue)
                        == expected(current).map(\.rawValue), "accessibility values")
            #expect(model.rows.map(\.isUndone) == expected(current).map { $0 == .undone })
        }
        #expect(HistoryRowState.done.rawValue == "done")
        #expect(HistoryRowState.current.rawValue == "current")
        #expect(HistoryRowState.undone.rawValue == "undone")
    }

    @Test func canUndoCanRedoAtEnds() {
        #expect((openImage(3, current: 0).canUndo, openImage(3, current: 0).canRedo) == (false, true))
        #expect((openImage(3, current: 1).canUndo, openImage(3, current: 1).canRedo) == (true, true))
        #expect((openImage(3, current: 2).canUndo, openImage(3, current: 2).canRedo) == (true, false))
        let baseOnly = openImage(1, current: 0)
        #expect((baseOnly.canUndo, baseOnly.canRedo) == (false, false))
        #expect((HistoryListModel.empty.canUndo, HistoryListModel.empty.canRedo) == (false, false))
        #expect(HistoryListModel.empty.rows.isEmpty)
    }

    @Test func clickOtherRowJumpsToIt() {
        let model = openImage(5, current: 2)
        #expect(model.jumpTarget(forClickedRow: 0) == 0)
        #expect(model.jumpTarget(forClickedRow: 3) == 3)
        #expect(model.jumpTarget(forClickedRow: 4) == 4)
        #expect(model.jumpTarget(forClickedRow: 1) == 1)
    }

    @Test func clickCurrentRowStepsBackOnce() {
        let model = openImage(5, current: 3)
        #expect(model.jumpTarget(forClickedRow: 3) == 2)
    }

    @Test func clickCurrentBaseRowIsNoOp() {
        let model = openImage(5, current: 0)
        #expect(model.jumpTarget(forClickedRow: 0) == nil)
        #expect(openImage(1, current: 0).jumpTarget(forClickedRow: 0) == nil)
    }

    /// Paint.NET's toggle: clicking the *same* row repeatedly alternates between it and the
    /// previous state — the pure rule reproduces it exactly.
    @Test func toggleSequenceMatchesPaintNET() {
        var current = 4
        var currents: [Int] = []
        for _ in 0..<4 {
            // The model reflects the state the user sees before each click.
            guard let target = openImage(5, current: current).jumpTarget(forClickedRow: 3) else {
                Issue.record("clicking row 3 must jump")
                return
            }
            current = target
            currents.append(current)
        }
        #expect(currents == [3, 2, 3, 2])
    }

    @Test func outOfRangeClickIsNil() {
        let model = openImage(5, current: 2)
        #expect(model.jumpTarget(forClickedRow: -1) == nil)
        #expect(model.jumpTarget(forClickedRow: model.rows.count) == nil)
        #expect(model.jumpTarget(forClickedRow: -100) == nil)
        #expect(model.jumpTarget(forClickedRow: 9_999) == nil)
        #expect(HistoryListModel.empty.jumpTarget(forClickedRow: 0) == nil)
    }

    @Test func currentIndexIsClamped() {
        let three = steps([(0, "Open Image", .openImage), (1, "A", .paintbrush), (2, "B", .eraser)])
        #expect(HistoryListModel(steps: three, currentIndex: 7).currentIndex == 2)
        #expect(HistoryListModel(steps: three, currentIndex: -1).currentIndex == 0)
        #expect(HistoryListModel(steps: three, currentIndex: 7).rows.map(\.state)
                    == [.done, .done, .current])
        #expect(HistoryListModel(steps: three, currentIndex: -1)
                    == HistoryListModel(steps: three, currentIndex: 0))
        #expect(HistoryListModel(steps: [], currentIndex: 0) == .empty)
        #expect(HistoryListModel(steps: [], currentIndex: -1) == .empty)
        #expect(HistoryListModel(steps: [], currentIndex: 5) == .empty)
    }

    /// H-5 drop: indices re-base, the surviving steps keep their stable IDs, and the
    /// current row stays on the same step.
    @Test func rowIDsAreStableAcrossDrop() throws {
        let a = HistoryListModel(
            steps: steps([(0, "Open Image", .openImage), (5, "A", .paintbrush),
                          (6, "B", .paintbrush), (7, "C", .paintbrush)]),
            currentIndex: 3)
        let b = HistoryListModel(
            steps: steps([(0, "Open Image", .openImage), (6, "B", .paintbrush),
                          (7, "C", .paintbrush)]),
            currentIndex: 2)
        let row7a = try #require(a.rows.first { $0.id == 7 })
        let row7b = try #require(b.rows.first { $0.id == 7 })
        #expect(row7a.index == 3)
        #expect(row7b.index == 2)
        #expect(row7a.state == .current)
        #expect(row7b.state == .current)
        #expect(a.rows.first { $0.id == 6 }?.state == .done)
        #expect(b.rows.first { $0.id == 6 }?.state == .done)
        #expect(a.rows.first?.id == 0)
        #expect(b.rows.first?.id == 0)
    }

    @Test func initFromStackMatchesManualInit() {
        var stack = HistoryStack(base: .openImage)
        var state = DocumentState(image: .blank(size: PixelSize(width: 4, height: 4), fill: .white))
        stack.commit(FakeHistoryItem(name: "A", icon: .paintbrush, byteCost: 0, after: "a"))
        stack.commit(FakeHistoryItem(name: "B", icon: .eraser, byteCost: 0, after: "b"))
        stack.jump(to: 1, &state)
        #expect(HistoryListModel(stack: stack)
                    == HistoryListModel(
                        steps: steps([(0, "Open Image", .openImage),
                                      (1, "A", .paintbrush),
                                      (2, "B", .eraser)]),
                        currentIndex: 1))
    }

    /// Seeded property test (0002's `SeededRandom`): over 500 random
    /// `(count, current, clickIndex)` triples — exactly one `.current` row, the states
    /// follow the index rule, and `jumpTarget` is nil or in range and never the current
    /// index.
    @Test func randomJumpsKeepInvariants() {
        var rng = SeededRandom(seed: SeededRandom.resolvedSeed(default: 0x0010_5EED))
        for _ in 0..<500 {
            let count = rng.int(in: 1...50)
            let current = rng.int(in: 0...count - 1)
            // Clicks include out-of-range indices on both ends.
            let click = rng.int(in: (-2)...(count + 1))
            var list: [(id: HistoryStep.ID, name: String, icon: HistoryIcon)]
                = [(0, "Open Image", .openImage)]
            for id in 1..<count { list.append((id, "Paintbrush", .paintbrush)) }
            let model = HistoryListModel(steps: list, currentIndex: current)
            let states = model.rows.map(\.state)
            #expect(states.filter { $0 == .current }.count == 1, "\(rng.comment)")
            var ruleHolds = true
            for index in states.indices {
                let expected: HistoryRowState
                if index < current { expected = .done }
                else if index == current { expected = .current }
                else { expected = .undone }
                if states[index] != expected { ruleHolds = false }
            }
            #expect(ruleHolds, "index rule \(rng.comment)")
            let target = model.jumpTarget(forClickedRow: click)
            if let target {
                #expect(model.rows.indices.contains(target), "target in range \(rng.comment)")
                #expect(target != current, "a jump always moves \(rng.comment)")
                #expect(target == (click == current ? current - 1 : click), "\(rng.comment)")
            } else {
                #expect(click < 0 || click >= count || (click == 0 && current == 0),
                        "nil only out of range or the current base row \(rng.comment)")
            }
        }
    }
}
