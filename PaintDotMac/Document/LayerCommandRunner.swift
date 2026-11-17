import Foundation

/// App-side glue for the Layers menu and Image > Flatten (spec 0024 item 8): one place
/// for the pending-edit-commit → snapshot-step order that every layer command and the
/// Go to Layer switch share, testable without a window.
@MainActor
enum LayerCommandRunner {
    /// Commits the pending tool edit first, then performs the command's item. Returns
    /// false when disabled.
    ///
    /// The pending edit is committed **before** the item is built, so floating pixels
    /// land on the old active layer as their own "Finish Pixels" step first and
    /// `state.floatingPixels` is nil when the snapshot is taken (Paint.NET finishes Move
    /// Selected Pixels before a layer command; 0020 item 9 — in production
    /// `commitPendingEdit` is `undoBridge.prepareForNavigation?()`, whose
    /// `pendingEditReason` is `.command`).
    @discardableResult
    static func run(_ command: LayerCommand, bridge: UndoBridge,
                    commitPendingEdit: () -> Void) -> Bool {
        commitPendingEdit()
        guard let item = command.makeHistoryItem(for: bridge.state) else { return false }
        bridge.perform(item)
        return true
    }

    /// Commits the pending edit, then sets `activeLayerIndex` through
    /// `bridge.updateLiveState` — no history step, no change-count change, and no canvas
    /// redraw needed: the composite doesn't depend on the active layer (0024 item 7).
    /// Returns false when there is no layer in that direction.
    @discardableResult
    static func goTo(_ step: ActiveLayerStep, bridge: UndoBridge,
                     commitPendingEdit: () -> Void) -> Bool {
        commitPendingEdit()
        guard let target = step.targetIndex(in: bridge.state.image) else { return false }
        bridge.updateLiveState { $0.image.activeLayerIndex = target }
        return true
    }
}
