import Foundation
import MessageStore
import XMPPProtocol

/// What a `SessionEngine` leaves to its owner: what the interface shows, platform work and app policy. Each member
/// runs on the main actor at the point named, and has a default, so an owner implements only what it uses.
@MainActor public protocol SessionEngineDelegate: AnyObject {
    /// False once the owner no longer wants a transport (a background transition, a quit).
    var wantsTransport: Bool { get }
    /// An extra condition for an outbox pass beyond a ready session holding the lease.
    var mayDrainOutbox: Bool { get }
    /// The rooms joined on this connection, whose queued group messages a pass sends.
    var joinedRooms: Set<String> { get }
    func nickname(in room: String, account: String) -> String
    func uploadsFresh(account: String) -> Bool
    /// Seconds of background time for named transport work, ended by the returned closure; nil when none is needed.
    func backgroundActivity(_ name: String) -> (@MainActor () -> Void)?

    /// The connection was reset: everything shown for it goes.
    func sessionEngineDidReset()
    /// The lease was just taken; throwing refuses it, and the engine releases it again.
    func ownershipAcquired(store: MessageStore) async throws
    /// After the lease is held and before the stream opens.
    func ownershipReady(store: MessageStore, account: String) async
    func leaseReleased(_ released: Bool)
    /// A foreground acquisition found the lease busy, once per attempt.
    func leaseBusy()
    /// A wait that met a busy lease ended, holding the lease or not.
    func leaseWaitEnded(acquired: Bool)
    /// A quiesce passed its deadline and hard-closed the transport: cancel outside work that can be cancelled.
    func quiesceDeadlinePassed()
    /// Still running after the hard close, by name; the lease stays held until they end.
    func quiesceStuck(_ work: [String])
    /// Work of the delegate's own that keeps a background grace open, such as an upload in flight.
    var holdsGrace: Bool { get }
    /// A background grace began holding the stream for the outbox.
    func graceStarted()
    /// The grace is over and the quiesce follows; the lease and the stream (unless lost) are still held.
    func graceEnding(_ end: GraceEnd) async
    /// Show, or withdraw, the content-free notice that a message is still unsent.
    func unsentNotice(_ visible: Bool)
    /// Every transport state, after the engine's own bookkeeping for it.
    func connectionChanged(_ state: XMPPConnectionState)
    /// The stream is online, before setup starts.
    func streamOnline(client: XMPPClient?, resumed: Bool) async
    /// Any event the engine does not consume itself.
    func received(_ event: XMPPEvent, token: UUID) async

    func setupStep(_ step: String)
    func setupReady()
    /// At `.ready`, before the outbox starts.
    func readyRefresh() async
    /// After the outbox started, beside the roster fetch and the room rejoins.
    func outboxStartedAtReady(account: String, client: XMPPClient, token: UUID) async
    func catchUpChanged(_ progress: CatchUpProgress?)
    func walkFinished(account: String, client: XMPPClient, token: UUID)
    func setupSettled()
    /// A half-alive session: the engine disconnects after this returns.
    func setupFailed(step: String, detail: String) async
    func uploadDiscoveryStarted(discovers: Bool)
    func uploadsDiscovered(_ discovery: Result<XMPPUploadService?, any Error>, account: String, token: UUID) async

    func roomRejoining(_ room: String, members: [String])
    func roomRejoined(_ room: String, joined: Bool)
    func roomRejoinFailed(_ room: String, error: any Error)
    func rejoinPassEnded(token: UUID, joined: Set<String>)

    func outboxHooks(token: UUID) -> OutboxDrain.Hooks
    func outboxPassEnded(_ result: Result<Set<String>, any Error>, token: UUID) async
    /// A pass ended with nothing more requested on this connection.
    func outboxIdle(token: UUID)

    /// Before an inbound stanza is processed.
    func inboundArrived(_ event: XMPPEvent, token: UUID)
    /// Processed under the current generation, before a stored outcome's flush.
    func inboundProcessed(_ event: XMPPEvent, token: UUID)
    /// Processed under the current generation, after a stored outcome's flush.
    func inboundSettled(_ event: XMPPEvent, outcome: InboundProcessor.Outcome, token: UUID) async
    func inboundFailed(_ event: XMPPEvent, error: any Error)
}

extension SessionEngineDelegate {
    public var wantsTransport: Bool { true }
    public var mayDrainOutbox: Bool { true }
    public var joinedRooms: Set<String> { [] }
    public func nickname(in room: String, account: String) -> String { String(account.prefix { $0 != "@" }) }
    public func uploadsFresh(account: String) -> Bool { false }
    public func backgroundActivity(_ name: String) -> (@MainActor () -> Void)? { nil }
    public func sessionEngineDidReset() {}
    public func ownershipAcquired(store: MessageStore) {}
    public func ownershipReady(store: MessageStore, account: String) {}
    public func leaseReleased(_ released: Bool) {}
    public func leaseBusy() {}
    public func leaseWaitEnded(acquired: Bool) {}
    public func quiesceDeadlinePassed() {}
    public func quiesceStuck(_ work: [String]) {}
    public var holdsGrace: Bool { false }
    public func graceStarted() {}
    public func graceEnding(_ end: GraceEnd) {}
    public func unsentNotice(_ visible: Bool) {}
    public func connectionChanged(_ state: XMPPConnectionState) {}
    public func streamOnline(client: XMPPClient?, resumed: Bool) {}
    public func received(_ event: XMPPEvent, token: UUID) {}
    public func setupStep(_ step: String) {}
    public func setupReady() {}
    public func readyRefresh() {}
    public func outboxStartedAtReady(account: String, client: XMPPClient, token: UUID) {}
    public func catchUpChanged(_ progress: CatchUpProgress?) {}
    public func walkFinished(account: String, client: XMPPClient, token: UUID) {}
    public func setupSettled() {}
    public func setupFailed(step: String, detail: String) {}
    public func uploadDiscoveryStarted(discovers: Bool) {}
    public func uploadsDiscovered(_ discovery: Result<XMPPUploadService?, any Error>, account: String, token: UUID) {}
    public func roomRejoining(_ room: String, members: [String]) {}
    public func roomRejoined(_ room: String, joined: Bool) {}
    public func roomRejoinFailed(_ room: String, error: any Error) {}
    public func rejoinPassEnded(token: UUID, joined: Set<String>) {}
    public func outboxHooks(token: UUID) -> OutboxDrain.Hooks { OutboxDrain.Hooks() }
    public func outboxPassEnded(_ result: Result<Set<String>, any Error>, token: UUID) {}
    public func outboxIdle(token: UUID) {}
    public func inboundArrived(_ event: XMPPEvent, token: UUID) {}
    public func inboundProcessed(_ event: XMPPEvent, token: UUID) {}
    public func inboundSettled(_ event: XMPPEvent, outcome: InboundProcessor.Outcome, token: UUID) {}
    public func inboundFailed(_ event: XMPPEvent, error: any Error) {}
}
