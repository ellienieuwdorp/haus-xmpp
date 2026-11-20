import Foundation
import CSQLite
import Darwin
import os

// Opening, parking and closing a store's SQLite connection, and the transport lease over it.
extension MessageStore {
    enum State {
        case open(Connection)
        // SQLite closed for suspension (`park`); the next call reopens the same file.
        case parked
        case closed
    }

    // The one way a store's connection opens, at first and again after `park`: returns it with its `user_version`. A
    // store first opened while the process is parked would stay open into suspension, so both refuse alike.
    static func connect(url: URL, create: Bool) throws -> (Connection, Int) {
        guard mayOpen else { throw MessageStoreError.suspended }
        let connection = try Connection(url: url, create: create)
        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.execute("PRAGMA synchronous = FULL")
        return (connection, try connection.query("PRAGMA user_version").first?[0].integer ?? 0)
    }

    // A parked store reopens here, never migrating: only the file it first opened, at the schema it had then, and only
    // while the process allows it (`reopeningAllowed`, checked in `connect`).
    var connection: Connection {
        get throws {
            switch state {
            case .open(let live) where live.isOpen: return live
            case .closed: throw MessageStoreError.closed
            case .open, .parked: return try reopen()
            }
        }
    }

    private func reopen() throws -> Connection {
        guard FileIdentity(path: url.path) == fileIdentity else { throw MessageStoreError.replaced }
        let (live, version) = try Self.connect(url: url, create: false)
        let refusal: MessageStoreError? = if FileIdentity(path: url.path) != fileIdentity { .replaced }
            else if version < schemaVersion { .upgradeRequired(version) }
            else if version > schemaVersion { .unsupportedSchema(version) }
            else { nil }
        // The refusal is what the caller needs; a connection that fails to close here closes in its deinit.
        if let refusal { try? live.close(); throw refusal }
        state = .open(live)
        return live
    }

    /// Closes SQLite so the process holds no lock on the database or its sidecars while it may be suspended; the next
    /// call reopens it (refused with `suspended` while `reopeningAllowed` is off). The transport lock file stays open and
    /// unlocked, so a later lease locks the same inode. Refused with `parkingRefused` while this store holds the lease
    /// or SQLite is inside a transaction. A closed or parked store is left as it is.
    public func park() throws {
        guard case .open(let live) = state else { return }
        guard !transportOwnership.isHeld, !live.inTransaction else { throw MessageStoreError.parkingRefused }
        try live.close()
        state = .parked
    }

    /// Whether a store may open its database, at first or again after `park`, for every store in this process. While it
    /// is off a new store and a call to a parked store throw `suspended`; stores already open are unaffected. On by default.
    public static var reopeningAllowed: Bool {
        get { reopening.withLock { $0 } }
        set { reopening.withLock { $0 = newValue } }
    }
    private static let reopening = OSAllocatedUnfairLock(initialState: true)
    // Package tests run in parallel in one process, so a test closes the gate for its own task only.
    @TaskLocal static var reopeningOverride: Bool?
    static var mayOpen: Bool { reopeningOverride ?? reopeningAllowed }

    /// Whether any SQLite connection this package opened in this process is open right now, from any thread.
    public static var processHasOpenConnection: Bool { Connection.open.withLock { $0 > 0 } }

    /// Parks every store of this process (`park`), including one opened while this runs. False when any refused or
    /// failed; the others are parked anyway.
    public static func parkAll() async -> Bool {
        var visited: [MessageStore] = [], parked = true
        while let next = living.withLock({ $0.compactMap(\.store) }).first(where: { store in !visited.contains { $0 === store } }) {
            visited.append(next)
            do { try await next.park() } catch { parked = false }
        }
        return parked
    }

    // Every store of this process, so `parkAll` reaches ones the app does not hold itself.
    private static let living = OSAllocatedUnfairLock(initialState: [LivingStore]())
    private struct LivingStore: Sendable { weak var store: MessageStore? }

    nonisolated func track() {
        Self.living.withLock { stores in
            stores.removeAll { $0.store == nil }
            stores.append(LivingStore(store: self))
        }
    }

    /// Acquires a nonblocking kernel lock shared by the app and extensions. Process termination
    /// releases it automatically; a suspended owner retains it and contenders must defer transport.
    /// Reading/opening a database never recovers or modifies another owner's active submissions.
    public func acquireTransportOwnership() throws {
        _ = try connection
        try transportOwnership.acquire()
        // A restore or directory move replaced the file while this connection waited: it must not write into, or
        // connect for, data nobody will read again.
        guard FileIdentity(path: url.path) == fileIdentity else {
            try transportOwnership.release()
            throw MessageStoreError.replaced
        }
    }

    /// Whether this store holds the transport lease right now. A caller that gave it up, or never got it, reads false.
    public var holdsTransportOwnership: Bool { transportOwnership.isHeld }

    /// Whether any store in this process holds a transport lock, or is taking one, right now. Readable from any thread
    /// without awaiting a store: what the app checks as its background time runs out. Never false while one is held.
    public static var processHoldsTransportLock: Bool { TransportOwnership.locked.withLock { $0 > 0 } }

    /// Stop and join all socket, sender and crypto work first; this must complete before deleting or replacing the
    /// database or its sidecars. Idempotent; later operations throw `closed`. Holding the lease, interrupted submissions
    /// are marked first and the kernel lock goes last, after SQLite closed, whatever failed; the first failure is thrown.
    public func close() throws {
        if case .closed = state { return }
        guard transportOwnership.isHeld else { return try shut() }
        let marked = Result { try markSubmissionsUnconfirmed() }
        let closed = Result { try shut() }
        try transportOwnership.release()
        try marked.get()
        try closed.get()
    }

    // For good: a failed close keeps the connection, so closing again retries it.
    private func shut() throws {
        if case .open(let live) = state { try live.close() }
        state = .closed
    }

    /// Containing-app migration only. Stop and join all work and close every other connection first. SQLite closes before
    /// the synchronous directory rename while the same transport-lock inode stays held. The store is unusable afterwards,
    /// even if the move fails; reopening either location is the caller's decision.
    public func closeForMigration(_ move: @Sendable () throws -> Void) throws {
        try requireTransportOwnership()
        let moved = Result { try shut(); try move() }
        try transportOwnership.release()
        try moved.get()
    }

    /// Caller MUST stop and join every socket and sender first. Invalidates attempt tokens. The kernel lock is released
    /// even when marking interrupted submissions fails (a busy database, a full disk): every owner marks them after
    /// acquiring (`recoverInterruptedSubmissions`), and the failure is thrown once the lock is free. A transaction a failed
    /// rollback left open would keep SQLite's locks, so that connection closes first; the next call reopens the store.
    public func releaseTransportOwnership() throws {
        try requireTransportOwnership()
        let marked = Result { try markSubmissionsUnconfirmed() }
        // The marking failure is what is thrown; a connection that fails to close here closes in its deinit.
        if case .failure = marked, case .open(let live) = state, live.inTransaction { try? live.close() }
        try transportOwnership.release()
        try marked.get()
    }

    private func markSubmissionsUnconfirmed() throws {
        try connection.transaction {
            try connection.execute("UPDATE outbox SET state='unconfirmed',attempt_id=NULL WHERE state='submitting'")
            try connection.execute("UPDATE outgoing_updates SET state='unconfirmed',attempt_id=NULL WHERE state='submitting'")
        }
    }

    func requireTransportOwnership() throws {
        guard transportOwnership.isHeld else { throw MessageStoreError.transportOwnershipRequired }
    }
}

// No timer lease: suspension must not let another process send concurrently with a live socket. The sidecar is
// never removed, so all owners lock the same inode. CLOEXEC prevents inheritance into launched helpers; process death
// closes the descriptor and releases ownership.
final class TransportOwnership: @unchecked Sendable {
    // Counted before the kernel call so the count never reads lower than the truth.
    static let locked = OSAllocatedUnfairLock(initialState: 0)
    private let descriptor: Int32
    private(set) var isHeld = false
    init(url: URL) throws {
        let lockPath = url.resolvingSymlinksInPath().path + ".transport-lock"
        descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw MessageStoreError.database(code: errno, message: "Unable to open transport lock") }
    }
    func acquire() throws {
        if isHeld { return }
        Self.locked.withLock { $0 += 1 }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Self.locked.withLock { $0 -= 1 }
            if code == EWOULDBLOCK { throw MessageStoreError.transportOwnedElsewhere }
            throw MessageStoreError.database(code: code, message: "Unable to acquire transport lock")
        }
        isHeld = true
    }
    // Held until the kernel confirms the unlock.
    func release() throws {
        guard isHeld else { return }
        guard flock(descriptor, LOCK_UN) == 0 else {
            throw MessageStoreError.database(code: errno, message: "Unable to release transport lock")
        }
        isHeld = false
        Self.locked.withLock { $0 -= 1 }
    }
    deinit {
        // Closing the descriptor drops a lock still held.
        Darwin.close(descriptor)
        if isHeld { Self.locked.withLock { $0 -= 1 } }
    }
}
