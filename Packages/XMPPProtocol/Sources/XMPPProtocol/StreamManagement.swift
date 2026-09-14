import Foundation

public struct XMPPStreamJournalEntry: Codable, Sendable, Equatable {
    public let sequence: UInt64
    public let xml: String
    public let messageID: String?
    public init(sequence: UInt64, xml: String, messageID: String?) { self.sequence = sequence; self.xml = xml; self.messageID = messageID }
}

/// Persist this opaque snapshot atomically. Journal entries are exact wire bytes, never plaintext inputs.
public struct XMPPStreamManagementSnapshot: Codable, Sendable, Equatable {
    public var revision: Int
    public var accountID: String
    public var fullJID: String
    public var streamID: String?
    public var expiresAt: Date?
    public var resumeTimeoutSeconds: UInt32?
    public var inboundHandled: UInt64
    public var outboundSent: UInt64
    public var outboundAcknowledged: UInt64
    public var journal: [XMPPStreamJournalEntry]
    public init(revision: Int, accountID: String, fullJID: String, streamID: String?, expiresAt: Date?, inboundHandled: UInt64,
                outboundSent: UInt64, outboundAcknowledged: UInt64, journal: [XMPPStreamJournalEntry], resumeTimeoutSeconds: UInt32? = nil) {
        self.resumeTimeoutSeconds = resumeTimeoutSeconds
        self.revision = revision; self.accountID = accountID; self.fullJID = fullJID; self.streamID = streamID; self.expiresAt = expiresAt
        self.inboundHandled = inboundHandled; self.outboundSent = outboundSent; self.outboundAcknowledged = outboundAcknowledged; self.journal = journal
    }
}

public protocol XMPPStreamManagementPersistence: Sendable {
    func load() async throws -> XMPPStreamManagementSnapshot?
    func permitsResumption(_ snapshot: XMPPStreamManagementSnapshot) async throws -> Bool
    /// CAS against expectedRevision, committing acknowledged message state in the same transaction.
    func save(_ snapshot: XMPPStreamManagementSnapshot, expectedRevision: Int?, acknowledgedMessageIDs: [String]) async throws
}

public extension XMPPStreamManagementPersistence {
    /// Raw protocol fixtures may replay their journal. Encrypted applications must revalidate saved recipient trust.
    func permitsResumption(_ snapshot: XMPPStreamManagementSnapshot) async throws -> Bool { true }
}

public struct XMPPInboundToken: Sendable, Equatable {
    public let session: UUID
    public let sequence: UInt64
}

public enum XMPPStreamManagementError: Error, Sendable { case invalidState, invalidAcknowledgement, journalFull, staleToken }

actor XMPPAsyncGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        if !occupied { occupied = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func leave() {
        if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() }
    }
}

/// The gate serializes persistence despite actor reentrancy. Failed saves never publish a candidate.
actor StreamManagement {
    let persistence: any XMPPStreamManagementPersistence
    private let gate = XMPPAsyncGate()
    private var snapshot: XMPPStreamManagementSnapshot?
    private var active = false
    private var received: UInt64 = 0
    private var completed: Set<UInt64> = []
    private var session = UUID()
    init(_ persistence: any XMPPStreamManagementPersistence) { self.persistence = persistence }

    func restore(accountID: String) async throws -> XMPPStreamManagementSnapshot? {
        await gate.enter()
        do {
            let loaded = try await persistence.load()
            if let loaded {
                guard loaded.accountID == accountID, OMEMOWire.bareJID(loaded.fullJID) == accountID,
                      loaded.fullJID.contains("/"), loaded.streamID.map(validArchiveID) ?? true, loaded.revision > 0,
                      loaded.outboundSent >= loaded.outboundAcknowledged,
                      loaded.outboundSent - loaded.outboundAcknowledged == UInt64(loaded.journal.count),
                      loaded.journal.count <= 2_000,
                      loaded.journal.enumerated().allSatisfy({ $0.element.sequence == loaded.outboundAcknowledged + UInt64($0.offset) + 1 }),
                      loaded.journal.reduce(0, { $0 + $1.xml.utf8.count }) <= 4_194_304 else { throw XMPPStreamManagementError.invalidState }
            }
            snapshot = loaded; active = false; completed = []; session = UUID()
            received = loaded?.inboundHandled ?? 0
            let candidate: XMPPStreamManagementSnapshot?
            if let loaded, loaded.streamID != nil, loaded.expiresAt.map({ $0 > Date() }) ?? true,
               try await persistence.permitsResumption(loaded) { candidate = loaded } else { candidate = nil }
            await gate.leave()
            return candidate
        } catch { await gate.leave(); throw error }
    }

    func enable(accountID: String, fullJID: String, streamID: String?, expiresAt: Date?, resumeTimeoutSeconds: UInt32? = nil) async throws {
        await gate.enter()
        do {
            guard (snapshot?.revision ?? 0) < Int.max else { throw XMPPStreamManagementError.invalidState }
            var next = XMPPStreamManagementSnapshot(revision: 1, accountID: accountID, fullJID: fullJID, streamID: streamID,
                                                   expiresAt: expiresAt, inboundHandled: 0, outboundSent: 0, outboundAcknowledged: 0, journal: [])
            next.resumeTimeoutSeconds = resumeTimeoutSeconds
            next.revision = (snapshot?.revision ?? 0) + 1
            try await persistence.save(next, expectedRevision: snapshot?.revision, acknowledgedMessageIDs: [])
            snapshot = next; received = 0; completed = []; active = true; session = UUID()
            await gate.leave()
        } catch { await gate.leave(); throw error }
    }

    func record(_ xml: String) async throws {
        await gate.enter()
        do {
            guard active, var next = snapshot else { await gate.leave(); return }
            guard next.journal.count < 2_000, next.journal.reduce(xml.utf8.count, { $0 + $1.xml.utf8.count }) <= 4_194_304,
                  next.outboundSent < UInt64.max else { throw XMPPStreamManagementError.journalFull }
            var parser = XMLStreamFramer()
            let frames = try parser.feed(Data(("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>" + xml).utf8))
            guard frames.count == 2, case .element(let node) = frames.last else { throw XMPPStreamManagementError.invalidState }
            guard ["message", "presence", "iq"].contains(node.name), node.namespace == "jabber:client" else { throw XMPPStreamManagementError.invalidState }
            next.outboundSent += 1
            next.journal.append(.init(sequence: next.outboundSent, xml: xml, messageID: node.name == "message" ? node.attributes["id"] : nil))
            try await commit(next)
            await gate.leave()
        } catch { await gate.leave(); throw error }
    }

    func acknowledge(_ h: UInt32, resumed: Bool = false) async throws -> [XMPPStreamJournalEntry] {
        await gate.enter()
        do {
            guard (active || resumed), var next = snapshot else { throw XMPPStreamManagementError.invalidState }
            let delta = UInt64(h &- UInt32(truncatingIfNeeded: next.outboundAcknowledged))
            guard delta <= UInt64(next.journal.count) else { throw XMPPStreamManagementError.invalidAcknowledgement }
            let ids = next.journal.prefix(Int(delta)).compactMap(\.messageID)
            next.journal.removeFirst(Int(delta)); next.outboundAcknowledged += delta
            if let timeout = next.resumeTimeoutSeconds {
                next.expiresAt = Date().addingTimeInterval(Double(timeout))
            }
            try await commit(next, acknowledged: ids)
            if resumed { active = true }
            await gate.leave()
            return next.journal
        } catch { await gate.leave(); throw error }
    }

    func receive() throws -> XMPPInboundToken? {
        guard active else { return nil }
        guard received < UInt64.max, received - (snapshot?.inboundHandled ?? 0) < 2_000 else { throw XMPPStreamManagementError.journalFull }
        received += 1
        return .init(session: session, sequence: received)
    }

    func handled(_ token: XMPPInboundToken) async throws {
        await gate.enter()
        do {
            guard active, token.session == session, var next = snapshot,
                  token.sequence <= received else { throw XMPPStreamManagementError.staleToken }
            if token.sequence <= next.inboundHandled { await gate.leave(); return }
            completed.insert(token.sequence)
            while next.inboundHandled < UInt64.max, completed.contains(next.inboundHandled + 1) { next.inboundHandled += 1 }
            if next.inboundHandled != snapshot?.inboundHandled {
                try await commit(next)
                completed = completed.filter { $0 > next.inboundHandled }
            }
            await gate.leave()
        } catch { await gate.leave(); throw error }
    }

    func permitsReplay() async throws -> Bool {
        guard let snapshot else { return false }
        return try await persistence.permitsResumption(snapshot)
    }

    func handledCount() -> UInt32 { UInt32(truncatingIfNeeded: snapshot?.inboundHandled ?? 0) }
    private func commit(_ value: XMPPStreamManagementSnapshot, acknowledged: [String] = []) async throws {
        guard (snapshot?.revision ?? 0) < Int.max else { throw XMPPStreamManagementError.invalidState }
        var next = value; next.revision = (snapshot?.revision ?? 0) + 1
        try await persistence.save(next, expectedRevision: snapshot?.revision, acknowledgedMessageIDs: acknowledged)
        snapshot = next
    }
}
