import Foundation

@testable import PaintDotMac

/// A `HistoryItem` with exact `byteCost`, name, and `change`, whose `apply`/`revert` set
/// `state.image.layers[0].name` to the `after`/`before` strings (spec 0008 *Test support*) —
/// lets the budget and bridge tests use hand-computed costs and observable state.
///
/// A session's items form a chain (`before` = the previous item's `after`), so undoing to the
/// base reproduces the original layer name and a dropped-step oracle is readable from the name.
struct FakeHistoryItem: HistoryItem {
    let name: String
    var icon: HistoryIcon = .generic
    let byteCost: Int
    var change: HistoryChange = .structure
    var before: String = "Background"
    let after: String

    func apply(to state: inout DocumentState) {
        state.image.layers[0].name = after
    }

    func revert(_ state: inout DocumentState) {
        state.image.layers[0].name = before
    }
}
