import Foundation
import notify

/// A share extension queued messages: it rings the app with a payload-free Darwin notification, as the liveness
/// handshake does (`AppLiveness`). Anyone may post a Darwin notification, so the ring only makes a running app look
/// again at its own store; it carries nothing and changes nothing by itself. The name starts with this build's App
/// Group, so the development and the released app never ring each other.
enum OutboxRing {
    static var name: String { SharedStorage.group + ".outbox.changed" }

    static func ring() { notify_post(name) }

    /// Listens on the main queue for the life of the process.
    @MainActor final class Listener {
        private var token: Int32 = NOTIFY_TOKEN_INVALID
        private let rung: @MainActor () -> Void

        init(rung: @escaping @MainActor () -> Void) { self.rung = rung }

        /// False when the ring cannot be observed; queued shares then wait for the app's next connection.
        func start() -> Bool {
            guard token == NOTIFY_TOKEN_INVALID else { return true }
            let status = notify_register_dispatch(OutboxRing.name, &token, DispatchQueue.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rung() }
            }
            guard status == NOTIFY_STATUS_OK else { token = NOTIFY_TOKEN_INVALID; return false }
            return true
        }
    }
}
