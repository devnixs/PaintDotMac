import Foundation

/// One Layers-panel row (spec 0025 item 5, PRD L-5): a layer in **display order**
/// (top layer first) with what the row renders and the accessibility value exposes.
/// `index` is the layer's index in `LayeredImage.layers` (0 = bottom) — stable across
/// reorders-in-place, so it drives the accessibility identifiers (`layerRow.<index>`).
struct LayerRow: Identifiable, Sendable, Equatable {
    let id: Layer.ID
    /// Index in `LayeredImage.layers` (0 = bottom); used in accessibility ids.
    let index: Int
    let name: String
    let isVisible: Bool
    let isActive: Bool
    /// The value VoiceOver and the integration tests read: "active" / "inactive".
    var accessibilityValue: String { isActive ? "active" : "inactive" }
}

/// The Layers panel's footer-button commands (spec 0025 item 5, L-1). The six layer
/// commands are 0024's menu actions by another route; `.layerProperties` opens the
/// dialog (0025 item 9). The panel forwards every one — it never re-implements an
/// operation, so menu and panel stay identical.
enum LayerPanelCommand: String, CaseIterable, Sendable {
    case addNewLayer
    case deleteLayer
    case duplicateLayer
    case mergeLayerDown
    case moveLayerUp
    case moveLayerDown
    case layerProperties
}

/// The Layers panel's whole view model (spec 0025 item 5): the pure mapping from the
/// document's layer stack to display-order rows plus every click, checkbox, drag, and
/// button decision, so the SwiftUI view only renders and forwards (0010's pattern).
///
/// Display order is Paint.NET's: the top layer first, so `rows[0].index ==
/// layers.count - 1`. A document image that somehow isn't `isConsistent` still yields
/// rows for the layers present with the active index clamped into range — the panel
/// must never crash (defensive, like 0010's `HistoryListModel`).
struct LayerListModel: Sendable, Equatable {
    /// Display order: top layer first.
    let rows: [LayerRow]
    /// The active layer's **layer** index (0 = bottom); nil when there are no rows.
    let activeIndex: Int?

    /// Maps a document image. `activeIndex` clamps out-of-range indices into
    /// `layers.indices`; an empty stack yields no rows and `activeIndex == nil`.
    init(image: LayeredImage) {
        let layers = image.layers
        let clamped = layers.isEmpty ? nil
            : min(max(image.activeLayerIndex, 0), layers.count - 1)
        self.activeIndex = clamped
        self.rows = layers.enumerated().reversed().map { index, layer in
            LayerRow(id: layer.id, index: index, name: layer.name,
                     isVisible: layer.isVisible, isActive: index == clamped)
        }
    }

    private init(rows: [LayerRow], activeIndex: Int?) {
        self.rows = rows
        self.activeIndex = activeIndex
    }

    /// No document bound: no rows, every command disabled (D-36).
    static let empty = LayerListModel(rows: [], activeIndex: nil)

    /// Enablement table (spec item 5; equals 0024's `LayerCommand.isEnabled(in:)` for the
    /// six layer commands — `LayerListModelTests.enablementMatchesMenuValidation` proves
    /// it): `i = activeIndex`, `n = layers.count`.
    func isEnabled(_ command: LayerPanelCommand) -> Bool {
        guard let activeIndex, !rows.isEmpty else { return false }
        switch command {
        case .addNewLayer, .duplicateLayer, .layerProperties:
            return true
        case .deleteLayer:
            return rows.count > 1
        case .mergeLayerDown, .moveLayerDown:
            return activeIndex > 0
        case .moveLayerUp:
            return activeIndex < rows.count - 1
        }
    }

    /// The display position of layer index `i` (`count - 1 - i`), nil if out of range.
    func displayPosition(ofLayerIndex i: Int) -> Int? {
        guard rows.indices.contains(i) else { return nil }
        return rows.count - 1 - i
    }

    /// The layer index shown at display position `p` (`count - 1 - p`), nil if out of range.
    func layerIndex(atDisplayPosition p: Int) -> Int? {
        guard (0..<rows.count).contains(p) else { return nil }
        return rows.count - 1 - p
    }

    /// SwiftUI `List.onMove` semantics in display order: `source` must contain exactly one
    /// position; `destination` is the display index the item is inserted before
    /// (`0...count`). Returns the (from, to) **layer** indices, or nil for a
    /// multi-selection, out-of-range input, or a no-op drop (edge cases: dropping a row
    /// onto itself or into the gap next to it does nothing).
    func moveTarget(displaySource: IndexSet, displayDestination: Int) -> (from: Int, to: Int)? {
        guard displaySource.count == 1, let s = displaySource.first,
              (0..<rows.count).contains(s),
              (0...rows.count).contains(displayDestination)
        else { return nil }
        // `List.onMove`'s destination is the index *after* removal for a downward move;
        // converting back: the item lands at display position `D - 1` when moved down.
        let p = displayDestination > s ? displayDestination - 1 : displayDestination
        let count = rows.count
        guard p != s, (0..<count).contains(p) else { return nil }
        return (from: count - 1 - s, to: count - 1 - p)
    }

    /// The visibility step for clicking the checkbox of layer `index`, or nil if out of
    /// range. The item carries only `isVisible` flipped; the active layer never changes.
    func visibilityToggle(forLayerIndex index: Int, in image: LayeredImage)
        -> LayerPropertiesHistoryItem?
    {
        guard image.layers.indices.contains(index) else { return nil }
        let layer = image.layers[index]
        var after = layer.properties
        after.isVisible.toggle()
        return .visibility(layerID: layer.id, before: layer.properties, after: after)
    }
}
