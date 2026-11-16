import Foundation
import Testing

@testable import PaintDotMac

/// The `NSUndoManager` mirror invariant (H-3): after every bridge operation the manager's
/// `canUndo`/`canRedo` and action names match the stack exactly.
@MainActor
struct UndoBridgePropertyTests {
    @Test(arguments: (0..<100).map { UInt64(bitPattern: 0xF00D_0000 &+ Int64($0)) })
    func managerMirrorsStack(seed: UInt64) throws {
        var rng = SeededRandom(seed: seed)
        var surface = TiledSurface(size: PixelSize(width: 256, height: 256))
        surface.fill(.white)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let bridge = UndoBridge(
            state: DocumentState(image: LayeredImage(surface: surface)),
            base: .openImage,
            budgetBytes: rng.int(in: 0...20_000),
            undoManager: undoManager
        )

        var serial = 0
        for step in 0..<50 {
            let comment: Comment = "\(rng.comment) step \(step)"
            switch rng.int(in: 0...9) {
            case 0...4:
                serial += 1
                bridge.perform(FakeHistoryItem(name: "S\(serial)",
                                               byteCost: rng.int(in: 0...3_000),
                                               after: "S\(serial)"))
            case 5:
                undoManager.undo()
            case 6:
                undoManager.redo()
            case 7:
                bridge.jump(to: rng.int(in: -1...bridge.history.steps.count))
            default:
                bridge.setBudget(rng.int(in: 0...20_000))
            }

            #expect(undoManager.canUndo == bridge.history.canUndo, comment)
            #expect(undoManager.canRedo == bridge.history.canRedo, comment)
            #expect(undoManager.undoActionName
                    == (bridge.history.undoStep?.name ?? ""), "\(comment) undo name")
            #expect(undoManager.redoActionName
                    == (bridge.history.redoStep?.name ?? ""), "\(comment) redo name")
        }
    }
}
