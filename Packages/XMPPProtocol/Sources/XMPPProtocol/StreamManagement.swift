import Foundation

/// One outbound stanza slot. Every journaled stanza consumes a sequence number because the server
/// counts it in `h`, but only messages and presence keep bytes: an IQ is never replayed on resume.
public struct XMPPStreamJournalEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case message, presence, iq }
    public let sequence: UInt64
    public let kind: Kind
    /// Exact wire bytes for message and presence entries; nil for iq entries, which are never replayed.
    /// Rows written before `kind` existed may still carry iq bytes until they are acknowledged.
    public let xml: String?
    /// Only message entries carry an ID; it is what the persistence layer acknowledges.
    public let messageID: String?

    public init(sequence: UInt64, kind: Kind, xml: String?, messageID: String?) {
        self.sequence = sequence; self.kind = kind; self.xml = xml; self.messageID = messageID
    }

    /// Derives `kind` from the stanza's leading element name and keeps the bytes as given.
    public init(sequence: UInt64, xml: String, messageID: String?) {
        self.init(sequence: sequence, kind: Self.derivedKind(xml: xml, messageID: messageID), xml: xml, messageID: messageID)
    }

    private enum CodingKeys: String, CodingKey { case sequence, kind, xml, messageID }

    /// Rows written before `kind` existed decode with a derived kind; the JSON shape is otherwise unchanged.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        xml = try container.decodeIfPresent(String.self, forKey: .xml)
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? Self.derivedKind(xml: xml, messageID: messageID)
    }

    private static func derivedKind(xml: String?, messageID: String?) -> Kind {
        if messageID != nil { return .message }
        if xml?.hasPrefix("<presence") == true { return .presence }
        if xml?.hasPrefix("<message") == true { return .message }
        return .iq
    }
}

/// Persist this opaque snapshot atomically. Journal entries are exact wire bytes, never plaintext inputs.
public struct XMPPStreamManagementSnapshot: Codable, Sendable, Equatable {
    public var revision: Int
    public var accountID: String
    public var fullJID: String
    public var streamID: String?
    /// The last contact plus `resumeTimeoutSeconds`: where the server's advertised window ends. Resumption is still
    /// attempted after it (`StreamManagement.attemptsResume`).
    public var expiresAt: Date?
    /// The server's `<enabled max='…'/>`, capped at `StreamManagement.maxResumeTimeout`; nil when it named none.
    public var resumeTimeoutSeconds: UInt32?
    /// What this session last announced (presence and CSI). A resume repeats presence only when it changed: every
    /// presence reaches contacts and the account's other resources, and a push-enabled hibernating one is pushed for it.
    public var availability: XMPPAvailability?
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
    /// A token only counts once it matches the live session, so constructing one proves nothing.
    public init(session: UUID, sequence: UInt64) { self.session = session; self.sequence = sequence }
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
///
/// The inbound handled counter lives in memory (`handledContiguous`) and is persisted lazily at flush
/// points. Invariant: an advertised `h` never exceeds the persisted `snapshot.inboundHandled`; the only
/// sources for an advertised value are `flushHandled()` and a restored snapshot. A persisted counter
/// that lags memory only makes the server redeliver stanzas whose dispositions are already durable.
actor StreamManagement {
    static let maxJournalEntries = 5_000
    static let maxReplayableEntries = 2_000
    static let maxReplayableBytes = 4_194_304
    static let inboundWindow: UInt64 = 2_000
    static let handledFlushInterval: UInt64 = 64
    /// Sanity cap on the server's `<enabled max='…'/>` (XEP-0198 sets no bound): a week, far beyond any default
    /// (Prosody 600 s, ejabberd 300 s), so a garbled or absurd value cannot keep a dead session looking alive.
    static let maxResumeTimeout: UInt32 = 604_800
    /// How long after the last contact a resume is still attempted, whatever the server advertised. The advertised
    /// `max` is a floor, not the real lifetime: Prosody's mod_cloud_notify keeps a push-enabled session hibernating up
    /// to 72 h (`push_max_hibernation_timeout`) while answering `max='600'`. A refused resume costs one round trip and
    /// falls through to a fresh bind; a skipped one costs the session's push registration and room occupancy.
    static let resumeAttemptWindow: TimeInterval = 259_200

    let persistence: any XMPPStreamManagementPersistence
    private let gate = XMPPAsyncGate()
    private var snapshot: XMPPStreamManagementSnapshot?
    private var active = false
    private var received: UInt64 = 0
    /// Always >= the persisted `snapshot.inboundHandled`; every member of `completed` is above it.
    private var handledContiguous: UInt64 = 0
    private var completed: Set<UInt64> = []
    private var session = UUID()
    init(_ persistence: any XMPPStreamManagementPersistence) { self.persistence = persistence }

    func restore(accountID: String) async throws -> XMPPStreamManagementSnapshot? {
        await gate.enter()
        do {
            let loaded = try await persistence.load()
            if let loaded {
                let replayable = loaded.journal.filter { $0.xml != nil }
                guard loaded.accountID == accountID, OMEMOWire.bareJID(loaded.fullJID) == accountID,
                      loaded.fullJID.contains("/"), loaded.streamID.map(validArchiveID) ?? true, loaded.revision > 0,
                      loaded.outboundSent >= loaded.outboundAcknowledged,
                      loaded.outboundSent - loaded.outboundAcknowledged == UInt64(loaded.journal.count),
                      loaded.journal.count <= Self.maxJournalEntries,
                      replayable.count <= Self.maxReplayableEntries,
                      loaded.journal.enumerated().allSatisfy({ $0.element.sequence == loaded.outboundAcknowledged + UInt64($0.offset) + 1 }),
                      // A message or presence entry must carry bytes; an iq entry may still carry legacy bytes.
                      loaded.journal.allSatisfy({ $0.kind == .iq || $0.xml != nil }),
                      replayable.reduce(0, { $0 + ($1.xml?.utf8.count ?? 0) }) <= Self.maxReplayableBytes else { throw XMPPStreamManagementError.invalidState }
            }
            snapshot = loaded; active = false; completed = []; session = UUID()
            received = loaded?.inboundHandled ?? 0
            handledContiguous = loaded?.inboundHandled ?? 0
            let candidate: XMPPStreamManagementSnapshot?
            if let loaded, Self.attemptsResume(loaded, now: Date()),
               try await persistence.permitsResumption(loaded) { candidate = loaded } else { candidate = nil }
            await gate.leave()
            return candidate
        } catch { await gate.leave(); throw error }
    }

    /// Whether a saved session is worth a `<resume/>`. `expiresAt` is the last contact plus the server's advertised
    /// timeout, so the last contact is recoverable from it; the attempt window runs from there for the longer of that
    /// timeout and `resumeAttemptWindow`. A snapshot without a recorded timeout is always tried: the server decides.
    static func attemptsResume(_ snapshot: XMPPStreamManagementSnapshot, now: Date) -> Bool {
        guard snapshot.streamID != nil else { return false }
        guard let expiresAt = snapshot.expiresAt, let timeout = snapshot.resumeTimeoutSeconds else { return true }
        let lastContact = expiresAt.addingTimeInterval(-TimeInterval(timeout))
        return now < lastContact.addingTimeInterval(max(TimeInterval(timeout), resumeAttemptWindow))
    }

    /// `resumeTimeoutSeconds` is the server's advertised `max` (capped by the caller); every later commit measures
    /// `expiresAt` from its own time, so it tracks the last contact rather than the last server acknowledgement.
    func enable(accountID: String, fullJID: String, streamID: String?, resumeTimeoutSeconds: UInt32? = nil) async throws {
        await gate.enter()
        do {
            guard (snapshot?.revision ?? 0) < Int.max else { throw XMPPStreamManagementError.invalidState }
            var next = XMPPStreamManagementSnapshot(revision: 1, accountID: accountID, fullJID: fullJID, streamID: streamID,
                                                   expiresAt: nil, inboundHandled: 0, outboundSent: 0, outboundAcknowledged: 0, journal: [])
            next.resumeTimeoutSeconds = resumeTimeoutSeconds
            next.expiresAt = resumeTimeoutSeconds.map { Date().addingTimeInterval(TimeInterval($0)) }
            next.revision = (snapshot?.revision ?? 0) + 1
            try await persistence.save(next, expectedRevision: snapshot?.revision, acknowledgedMessageIDs: [])
            snapshot = next; received = 0; handledContiguous = 0; completed = []; active = true; session = UUID()
            await gate.leave()
        } catch { await gate.leave(); throw error }
    }

    /// Journals one outbound stanza before its socket write. IQs occupy a sequence slot without bytes.
    func record(_ xml: String) async throws {
        await gate.enter()
        do {
            guard active, var next = snapshot else { await gate.leave(); return }
            var parser = XMLStreamFramer()
            let frames = try parser.feed(Data(("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>" + xml).utf8))
            guard frames.count == 2, case .element(let node) = frames.last else { throw XMPPStreamManagementError.invalidState }
            guard node.namespace == "jabber:client", let kind = XMPPStreamJournalEntry.Kind(rawValue: node.name) else { throw XMPPStreamManagementError.invalidState }
            let bytes = kind == .iq ? nil : xml
            guard next.journal.count < Self.maxJournalEntries, next.outboundSent < UInt64.max else { throw XMPPStreamManagementError.journalFull }
            if bytes != nil {
                let replayable = next.journal.filter { $0.xml != nil }
                guard replayable.count < Self.maxReplayableEntries,
                      replayable.reduce(xml.utf8.count, { $0 + ($1.xml?.utf8.count ?? 0) }) <= Self.maxReplayableBytes else {
                    throw XMPPStreamManagementError.journalFull
                }
            }
            next.outboundSent += 1
            next.journal.append(.init(sequence: next.outboundSent, kind: kind, xml: bytes, messageID: kind == .message ? node.attributes["id"] : nil))
            next.inboundHandled = handledContiguous
            try await commit(next)
            await gate.leave()
        } catch { await gate.leave(); throw error }
    }

    /// Trims by the server's count across all entries and returns the replayable (message and
    /// presence) remainder in sequence order. IQ entries are trimmed but never returned.
    ///
    /// On resume the unacknowledged IQ slots are dropped, because the client never retransmits them
    /// and the server never received them (its `h` is below them). The replayable remainder is
    /// renumbered contiguously from the server's count, and `outboundSent` is reset to match, in
    /// the same commit and before any replayed byte is written. The server then counts exactly the
    /// stanzas we retransmit, so later `<a h>` values keep trimming the right entries.
    func acknowledge(_ h: UInt32, resumed: Bool = false) async throws -> [XMPPStreamJournalEntry] {
        await gate.enter()
        do {
            guard (active || resumed), var next = snapshot else { throw XMPPStreamManagementError.invalidState }
            let delta = UInt64(h &- UInt32(truncatingIfNeeded: next.outboundAcknowledged))
            guard delta <= UInt64(next.journal.count) else { throw XMPPStreamManagementError.invalidAcknowledgement }
            let ids = next.journal.prefix(Int(delta)).compactMap(\.messageID)
            next.journal.removeFirst(Int(delta)); next.outboundAcknowledged += delta
            if resumed {
                let base = next.outboundAcknowledged
                next.journal = next.journal.filter { $0.kind != .iq }.enumerated().map { offset, entry in
                    XMPPStreamJournalEntry(sequence: base + UInt64(offset) + 1, kind: entry.kind, xml: entry.xml, messageID: entry.messageID)
                }
                next.outboundSent = base + UInt64(next.journal.count)
            }
            next.inboundHandled = handledContiguous
            try await commit(next, acknowledged: ids)
            if resumed { active = true }
            await gate.leave()
            return next.journal.filter { $0.kind != .iq }
        } catch { await gate.leave(); throw error }
    }

    func receive() throws -> XMPPInboundToken? {
        guard active else { return nil }
        guard received < UInt64.max, received - handledContiguous < Self.inboundWindow else { throw XMPPStreamManagementError.journalFull }
        received += 1
        return .init(session: session, sequence: received)
    }

    /// Records one durable disposition in memory; persists only every `handledFlushInterval` advances.
    func handled(_ token: XMPPInboundToken) async throws {
        await gate.enter()
        do {
            guard active, token.session == session, snapshot != nil,
                  token.sequence <= received else { throw XMPPStreamManagementError.staleToken }
            if token.sequence > handledContiguous {
                completed.insert(token.sequence)
                advanceHandled()
            }
            if let persisted = snapshot?.inboundHandled, handledContiguous - persisted >= Self.handledFlushInterval {
                try await commitHandled()
            }
            await gate.leave()
        } catch { await gate.leave(); throw error }
    }

    /// Records a page's durable dispositions together: validates every token before inserting any,
    /// advances once and commits once when the counter is ahead of the persisted value.
    func handled(_ tokens: [XMPPInboundToken]) async throws {
        await gate.enter()
        do {
            guard active, snapshot != nil,
                  tokens.allSatisfy({ $0.session == session && $0.sequence <= received }) else { throw XMPPStreamManagementError.staleToken }
            for token in tokens where token.sequence > handledContiguous { completed.insert(token.sequence) }
            advanceHandled()
            try await commitHandled()
            await gate.leave()
        } catch { await gate.leave(); throw error }
    }

    /// Persists the in-memory contiguous counter if it moved and returns the persisted value.
    /// The only source for an advertised h. Never commits when SM is inactive or nothing moved.
    func flushHandled() async throws -> UInt32 {
        await gate.enter()
        do {
            if active { try await commitHandled() }
            let persisted = persistedHandledCount()
            await gate.leave()
            return persisted
        } catch { await gate.leave(); throw error }
    }

    /// A deliberate disconnect: persists the handled count and the time of this last contact in one commit, even
    /// when the counter did not move, and returns the persisted count to advertise in a final `<a/>`.
    func detach() async throws -> UInt32 {
        await gate.enter()
        do {
            if active, var next = snapshot {
                next.inboundHandled = handledContiguous
                try await commit(next)
            }
            let persisted = persistedHandledCount()
            await gate.leave()
            return persisted
        } catch { await gate.leave(); throw error }
    }

    /// Records what the session just announced, in the snapshot a later resume starts from.
    func recordAvailability(_ availability: XMPPAvailability) async throws {
        await gate.enter()
        do {
            if active, var next = snapshot, next.availability != availability {
                next.availability = availability
                next.inboundHandled = handledContiguous
                try await commit(next)
            }
            await gate.leave()
        } catch { await gate.leave(); throw error }
    }

    func permitsReplay() async throws -> Bool {
        guard let snapshot else { return false }
        return try await persistence.permitsResumption(snapshot)
    }

    func persistedHandledCount() -> UInt32 { UInt32(truncatingIfNeeded: snapshot?.inboundHandled ?? 0) }

    private func advanceHandled() {
        while handledContiguous < UInt64.max, completed.remove(handledContiguous + 1) != nil { handledContiguous += 1 }
    }

    /// Caller holds the gate.
    private func commitHandled() async throws {
        guard var next = snapshot, next.inboundHandled != handledContiguous else { return }
        next.inboundHandled = handledContiguous
        try await commit(next)
    }

    private func commit(_ value: XMPPStreamManagementSnapshot, acknowledged: [String] = []) async throws {
        guard (snapshot?.revision ?? 0) < Int.max else { throw XMPPStreamManagementError.invalidState }
        var next = value; next.revision = (snapshot?.revision ?? 0) + 1
        // Every commit is contact with the server (a stanza sent or handled, an acknowledgement, a detach).
        if let timeout = next.resumeTimeoutSeconds { next.expiresAt = Date().addingTimeInterval(TimeInterval(timeout)) }
        try await persistence.save(next, expectedRevision: snapshot?.revision, acknowledgedMessageIDs: acknowledged)
        snapshot = next
    }
}
