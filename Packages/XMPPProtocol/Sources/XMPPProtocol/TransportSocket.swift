import Foundation
import Network

// The client's NWConnection, readable from any thread; `lock` guards `connection`. NWConnection's cancel and start may
// be called from any thread, and its callbacks run on `queue`.
final class TransportSocket: @unchecked Sendable {
    let queue: DispatchQueue
    private let lock = NSLock()
    private var connection: NWConnection?

    init(label: String) { queue = DispatchQueue(label: label) }

    func set(_ connection: NWConnection?) { lock.withLock { self.connection = connection } }

    func cancel() { lock.withLock { connection }?.cancel() }
}

extension XMPPClient {
    /// Cancels the socket at once from any context: no farewell, and no wait for the actor. For a deadline that cannot
    /// wait for `disconnectAndWait`; the reader then ends the stream as for any socket failure, so the owner still joins
    /// its consumer and reader as usual.
    public nonisolated func abort() {
        socket.cancel()
    }

    /// Whether a message written on this stream still waits for the server's XEP-0198 acknowledgement.
    public func awaitsAcknowledgement() async -> Bool {
        guard isOnline, smOffered, let streamManagement else { return false }
        return await streamManagement.awaitsMessageAcknowledgement()
    }
}
