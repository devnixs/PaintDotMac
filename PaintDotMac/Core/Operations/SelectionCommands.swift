import Foundation

/// The Edit-menu selection commands as pure functions on `DocumentState` (spec 0013;
/// PRD E-3 / D-40, Paint.NET EditMenu.html). "No selection" is `nil`; a selection that
/// covers no pixels is no selection; Deselect and Invert Selection are disabled when
/// nothing is selected; Select All is a no-op when the whole image is already selected
/// (H-6).
enum SelectionCommand: CaseIterable, Sendable {
    case selectAll
    case deselect
    case invertSelection

    /// Paint.NET spelling (history step and menu title).
    var name: String {
        switch self {
        case .selectAll: "Select All"
        case .deselect: "Deselect"
        case .invertSelection: "Invert Selection"
        }
    }

    var icon: HistoryIcon {
        switch self {
        case .selectAll: .selectAll
        case .deselect: .deselect
        case .invertSelection: .invertSelection
        }
    }

    func isEnabled(in state: DocumentState) -> Bool {
        switch self {
        case .selectAll: true   // any open document
        case .deselect, .invertSelection: state.selection != nil
        }
    }

    /// `nil` when disabled or a no-op (H-6: a no-op adds no step).
    func makeHistoryItem(for state: DocumentState) -> SelectionHistoryItem? {
        guard isEnabled(in: state) else { return nil }
        let after: Selection?
        switch self {
        case .selectAll:
            after = .all(canvasSize: state.image.size)
        case .deselect:
            after = nil
        case .invertSelection:
            after = state.selection?.inverted()
        }
        guard state.selection != after else { return nil }
        return SelectionHistoryItem(name: name, icon: icon,
                                    before: state.selection, after: after)
    }
}
