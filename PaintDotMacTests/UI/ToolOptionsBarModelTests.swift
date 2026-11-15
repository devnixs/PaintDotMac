import Testing
@testable import PaintDotMac

/// The tool options bar's pure decisions (spec 0006 *Test plan*): which tools show Finish,
/// and when it is enabled.
@MainActor
struct ToolOptionsBarModelTests {
    @Test func finishVisibility() {
        let pendingTools: [ToolID] = [.moveSelectedPixels, .text, .lineCurve, .shapes]
        for id in ToolID.allCases {
            let descriptor = ToolRegistry.descriptor(for: id)
            if pendingTools.contains(id) {
                #expect(ToolOptionsBar.showsFinish(for: descriptor), "\(id.rawValue) holds edits")
            } else {
                #expect(!ToolOptionsBar.showsFinish(for: descriptor), "\(id.rawValue) shows no Finish")
            }
        }
        #expect(ToolID.allCases.count == 19)
    }

    @Test(arguments: [false, true])
    func finishEnabledMirrorsFlag(_ hasPendingEdit: Bool) {
        #expect(ToolOptionsBar.finishEnabled(hasPendingEdit: hasPendingEdit) == hasPendingEdit)
    }
}
