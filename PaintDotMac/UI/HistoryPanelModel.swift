import Foundation
import Observation

/// The History panel's document binding (spec 0010): holds the active document's
/// `HistoryListModel` and forwards commands to its `UndoBridge`. One instance, owned by
/// `AppModel`, shared by the single app-wide History panel (0006, APP-2).
///
/// It follows the active document by observing the owning `AppModel`'s
/// `activeSessionGeneration` (`withObservationTracking`, re-armed after each change) and
/// rebinding to `activeSession?.undoBridge` — `windowDidBecomeMain` sets the session
/// (including tab switches) and the close path clears it, so the panel follows window
/// switches and tab switches alike. It refreshes after every history change of the bound
/// document by observing that bridge's `historyRevision` — 0008 bumps it once per
/// operation, after both the stack and the `NSUndoManager` are updated, so the panel
/// rebuilds exactly once per user action (H-3: menu, panel, and canvas cannot diverge).
///
/// Jumping goes through `UndoBridge.jump(to:)`, never straight to the `HistoryStack`:
/// the jump replays `undoManager.undo()`/`redo()` so the Edit menu titles stay exact, and
/// first commits any pending tool edit through `prepareForNavigation` — exactly like
/// Edit > Undo (⌘Z). The canvas redraws through 0008's `onStateChange`; the panel never
/// touches pixels.
@MainActor
@Observable
final class HistoryPanelModel {
    /// The rows and current index to render.
    private(set) var model: HistoryListModel = .empty
    /// +1 per rebuild, for the tests that count refreshes (one per history change).
    private(set) var refreshCount: Int = 0

    /// Weak: the document owns its bridge, so a closed document is never kept alive.
    @ObservationIgnored private weak var bridge: UndoBridge?
    @ObservationIgnored private weak var appModel: AppModel?

    /// Chain markers: re-arming (or rebinding) bumps the token, and an in-flight chain
    /// whose token no longer matches is stale and retires without refreshing. This keeps
    /// exactly one live chain each, even when the panel rebinds A → B → A.
    @ObservationIgnored private var sessionToken = 0
    @ObservationIgnored private var revisionToken = 0

    /// The currently bound bridge (`nil` with no active document); exposed for tests.
    var boundBridge: UndoBridge? { bridge }

    /// Starts unbound and unobserved (the integration tests' `HistoryPanelModel()`).
    /// `AppModel.init` creates one and immediately calls `follow(_:)`.
    init() {}

    /// Follows `appModel`'s active session — called once by the owning `AppModel` at the
    /// end of its `init` (leaking `self` earlier would be a definite-initialization
    /// violation).
    func follow(_ appModel: AppModel) {
        self.appModel = appModel
        observeActiveSession()
    }

    /// Rebuilds from the (weakly held) bridge; `.empty` when it is gone.
    func refresh() {
        if let bridge {
            model = HistoryListModel(stack: bridge.history)
        } else {
            model = .empty
        }
        refreshCount += 1
    }

    /// Binds to the active document's bridge, or `nil` for "no document" (H-2, D-36).
    func bind(to newBridge: UndoBridge?) {
        observeActiveSession()   // re-arm the active-session observer
        if bridge !== newBridge {
            bridge = newBridge
            observeHistoryRevision()
        }
        refresh()
    }

    /// A row click: Paint.NET's toggle rule via `HistoryListModel.jumpTarget`, then
    /// 0008's jump (one merged canvas change, one revision bump, exact Edit-menu state).
    func clickRow(_ index: Int) {
        guard let target = model.jumpTarget(forClickedRow: index) else { return }
        bridge?.jump(to: target)
    }

    /// The panel's Undo button — 0008's path, so it behaves exactly like Edit > Undo (⌘Z).
    func undo() { bridge?.undo() }

    /// The panel's Redo button — exactly like Edit > Redo (⇧⌘Z).
    func redo() { bridge?.redo() }

    // MARK: - Observation (re-armed after each change)

    private func observeActiveSession() {
        guard let appModel else { return }
        sessionToken += 1
        let token = sessionToken
        withObservationTracking {
            _ = appModel.activeSessionGeneration
        } onChange: { [weak self, weak appModel] in
            // Observation notifies on the main actor: `activeSessionGeneration` is only
            // ever mutated from `@MainActor` code (`AppModel.setActiveSession`).
            MainActor.assumeIsolated {
                guard let self, self.sessionToken == token else { return }
                // `bind` re-arms this observer (bumping the token, retiring this chain).
                self.bind(to: appModel?.activeSession?.undoBridge)
            }
        }
    }

    private func observeHistoryRevision() {
        guard let bridge else { return }
        revisionToken += 1
        let token = revisionToken
        withObservationTracking {
            _ = bridge.historyRevision
        } onChange: { [weak self, weak bridge] in
            MainActor.assumeIsolated {
                // A rebinding bumps the token; the superseded chain retires silently.
                guard let self, self.revisionToken == token, self.bridge === bridge else { return }
                // `historyRevision` bumps after the stack is updated, and once for a
                // whole jump — one rebuild per user action.
                self.refresh()
                self.observeHistoryRevision()
            }
        }
    }
}
