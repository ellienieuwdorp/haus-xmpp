import Foundation
import notify
import MessagingCore

// Any process may post the payload-free ring, so it only makes the extension read the request only this build can
// write. Its name starts with the App Group, so development and released builds never ring each other.
enum ExtensionGiveWay {
    static var ringName: String { SharedStorage.group + ".extension.give-way" }

    struct Files: Sendable {
        private let mailbox: GroupMailbox
        var directory: URL { mailbox.directory }

        init(groupRoot: URL) { mailbox = GroupMailbox(directory: groupRoot.appending(path: "GiveWay", directoryHint: .isDirectory)) }

        func saveRequest(_ request: GiveWayRequest) throws { try mailbox.save(request, as: "request.json") }
        func request() -> GiveWayRequest? { mailbox.read("request.json") }
        func removeRequest() { mailbox.remove("request.json") }
        func saveTakeover(_ takeover: GiveWayTakeover) throws { try mailbox.save(takeover, as: "takeover.json") }
        func takeover() -> GiveWayTakeover? { mailbox.read("takeover.json") }
    }

    // One lease wait: `leaseBusy` on each busy attempt, `leaseTaken` once held and only where the app then presents
    // what the extension left (it lets the extension suppress the push), `withdraw` when the wait ends without it.
    struct Ask: Sendable {
        let files: Files
        private let ring: @Sendable () -> Void
        private(set) var request: GiveWayRequest?

        init(files: Files, ring: @escaping @Sendable () -> Void = { notify_post(ExtensionGiveWay.ringName) }) {
            self.files = files; self.ring = ring
        }

        mutating func leaseBusy(now: Date = Date()) {
            if let request, now >= request.sentAt, now.timeIntervalSince(request.sentAt) < GiveWayHandshake.refreshInterval { return }
            let next = GiveWayRequest(nonce: request?.nonce ?? UUID().uuidString, sentAt: now)
            guard (try? files.saveRequest(next)) != nil else { return }
            request = next
            ring()
        }

        func leaseTaken(now: Date = Date()) {
            guard let request else { return }
            // An unsaved takeover makes the extension fall back: nothing is lost.
            try? files.saveTakeover(GiveWayTakeover(nonce: request.nonce, takenAt: now))
        }

        func withdraw() {
            guard let request, files.request()?.nonce == request.nonce else { return }
            files.removeRequest()
        }
    }

    struct Channel: GiveWayChannel {
        let files: Files
        func latestRequest() -> GiveWayRequest? { files.request() }
        func latestTakeover() -> GiveWayTakeover? { files.takeover() }
    }

    // For one extension run: each ring rechecks the request, and `start` does too, for one saved before it listened.
    final class Listener: @unchecked Sendable {
        // Guards `token`.
        private let lock = NSLock()
        private var token: Int32 = NOTIFY_TOKEN_INVALID
        private let giveWay: GiveWaySwitch
        private let queue = DispatchQueue(label: "haus.xmpp.give-way")

        init(_ giveWay: GiveWaySwitch) { self.giveWay = giveWay }

        // False when the ring cannot be observed; the run then never gives way, and the app waits for its end.
        func start() -> Bool {
            let registered = lock.withLock { () -> Bool in
                guard token == NOTIFY_TOKEN_INVALID else { return true }
                let status = notify_register_dispatch(ExtensionGiveWay.ringName, &token, queue) { [giveWay] _ in giveWay.check() }
                guard status == NOTIFY_STATUS_OK else { token = NOTIFY_TOKEN_INVALID; return false }
                return true
            }
            if registered { giveWay.check() }
            return registered
        }

        func stop() {
            lock.withLock {
                guard token != NOTIFY_TOKEN_INVALID else { return }
                notify_cancel(token)
                token = NOTIFY_TOKEN_INVALID
            }
        }

        deinit { stop() }
    }
}
