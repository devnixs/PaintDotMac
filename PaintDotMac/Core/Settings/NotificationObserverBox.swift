import Foundation

/// A `NotificationCenter` block observer that removes itself when deallocated, usable from
/// `@MainActor` classes: deallocating a property in a nonisolated deinit is allowed, but
/// *accessing* a non-Sendable one is not — so the removal lives in this box's own (plain,
/// nonisolated) `deinit`, not in the owning class's.
///
/// The handler must be `@Sendable`; handlers written for `@MainActor` work start it with
/// `Task { @MainActor [weak owner] in ... }`.
final class NotificationObserverBox {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, name: Notification.Name, object: Any?,
         handler: @escaping @Sendable () -> Void) {
        self.center = center
        self.token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            handler()
        }
    }

    deinit {
        center.removeObserver(token)
    }
}
