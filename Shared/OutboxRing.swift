import Foundation
import notify

// Anyone may post a Darwin notification, so the ring only makes a running app look again at its own store. Its name
// starts with the App Group, so development and released builds never ring each other.
enum OutboxRing {
    static var name: String { SharedStorage.group + ".outbox.changed" }

    static func ring() { notify_post(name) }

    @MainActor final class Listener {
        private var token: Int32 = NOTIFY_TOKEN_INVALID
        private let rung: @MainActor () -> Void

        init(rung: @escaping @MainActor () -> Void) { self.rung = rung }

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
