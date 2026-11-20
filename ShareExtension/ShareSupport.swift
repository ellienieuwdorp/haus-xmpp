import Foundation
import MessageStore
import MessagingCore
import os

extension ShareModel {
    // What `load` and the checks before queueing and connecting read; tests give their own store and account.
    struct Sources {
        var directory: @Sendable () async throws -> URL = { try await SharedStorage.directory(migrate: false) }
        var account: @Sendable () throws -> NotificationAccount? = { try NotificationAccount.load() }
        var encryptionKey: @Sendable () throws -> Data = { try EncryptionKeychain.load(storageID: "primary", allowCreation: false) }
    }
}

struct ShareStateReader: Sendable {
    let store: MessageStore
    let accountID: String

    func states(_ ids: [String]) async -> [String: ShareItemState] {
        var result: [String: ShareItemState] = [:]
        for id in ids { result[id] = ShareItemState(try? await store.message(accountID: accountID, messageID: id)) }
        return result
    }
}

#if os(iOS)
// `performExpiringActivity` holds its assertion while the first call (expired false) blocks. Before suspension a second
// call, on another thread, has expired true: it blocks until `expiring` released the lease and closed SQLite, within
// `backstop`, then lets the first return. The teardown runs on the cooperative pool, never on these threads.
final class ExpiringActivity: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private static let log = Logger(subsystem: "haus.xmpp.ios", category: "share")

    init(_ reason: String, backstop: Duration, expiring: @escaping @Sendable () async -> Void) {
        let done = done
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
            guard expired else {
                done.wait()
                return
            }
            let stopped = DispatchSemaphore(value: 0)
            Task.detached {
                await expiring()
                stopped.signal()
            }
            if stopped.wait(timeout: .now() + .milliseconds(Int(backstop / .milliseconds(1)))) == .timedOut {
                Self.log.fault("share expiry teardown still running at its backstop")
            }
            done.signal()
        }
    }

    func end() { done.signal() }
}
#endif
