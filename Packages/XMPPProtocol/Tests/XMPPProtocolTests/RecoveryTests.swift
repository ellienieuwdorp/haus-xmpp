import Foundation
import Testing
@testable import XMPPProtocol

private actor SnapshotStore: XMPPStreamManagementPersistence {
    var value: XMPPStreamManagementSnapshot?
    var acknowledged: [String] = []
    var reject = false
    var resumeAllowed = true
    var saves = 0
    func load() -> XMPPStreamManagementSnapshot? { value }
    func save(_ snapshot: XMPPStreamManagementSnapshot, expectedRevision: Int?, acknowledgedMessageIDs: [String]) throws {
        if reject { throw XMPPStreamManagementError.invalidState }
        guard value?.revision == expectedRevision else { throw XMPPStreamManagementError.invalidState }
        value = snapshot; acknowledged += acknowledgedMessageIDs; saves += 1
    }
    func permitsResumption(_ snapshot: XMPPStreamManagementSnapshot) -> Bool { resumeAllowed }
    func setResumeAllowed(_ allowed: Bool) { resumeAllowed = allowed }
    func rejectSaves(_ reject: Bool) { self.reject = reject }
    func seed(_ snapshot: XMPPStreamManagementSnapshot) { value = snapshot }
}

@Test func streamJournalPersistsBeforeWriteAndRejectsImpossibleAcknowledgement() async throws {
    let store = SnapshotStore()
    let sm = StreamManagement(store)
    _ = try await sm.restore(accountID: "a@example.org")
    try await sm.enable(accountID: "a@example.org", fullJID: "a@example.org/r", streamID: "resume", expiresAt: nil)
    let xml = "<message id='original'><encrypted xmlns='urn:xmpp:omemo:2'/></message>"
    try await sm.record(xml)
    #expect(await store.value?.journal.first?.xml == xml)
    await #expect(throws: XMPPStreamManagementError.self) { try await sm.acknowledge(2) }
    #expect(await store.value?.journal.count == 1)
    #expect(try await sm.acknowledge(1).isEmpty)
    #expect(await store.acknowledged == ["original"])
}

@Test func streamAcknowledgementNeverPassesUndurableInboundMessage() async throws {
    let sm = StreamManagement(SnapshotStore())
    _ = try await sm.restore(accountID: "a@example.org")
    try await sm.enable(accountID: "a@example.org", fullJID: "a@example.org/r", streamID: "resume", expiresAt: nil)
    let message = try #require(await sm.receive()), iq = try #require(await sm.receive())
    try await sm.handled(iq)
    #expect(try await sm.flushHandled() == 0)
    try await sm.handled(message)
    #expect(try await sm.flushHandled() == 2)
}

@Test func failedFlushKeepsAdvertisedCounterAtPersistedValue() async throws {
    let store = SnapshotStore()
    let manager = StreamManagement(store)
    _ = try await manager.restore(accountID: "a@example.org")
    try await manager.enable(accountID: "a@example.org", fullJID: "a@example.org/r", streamID: "resume", expiresAt: nil)
    let token = try #require(await manager.receive())
    await store.rejectSaves(true)
    try await manager.handled(token)
    await #expect(throws: XMPPStreamManagementError.self) { try await manager.flushHandled() }
    #expect(await manager.persistedHandledCount() == 0)
    #expect(await store.value?.inboundHandled == 0)
    await store.rejectSaves(false)
    #expect(try await manager.flushHandled() == 1)
    #expect(await store.value?.inboundHandled == 1)
}

@Test func iqStanzasOccupyOutboundSlotsWithoutBytes() async throws {
    let store = SnapshotStore()
    let sm = StreamManagement(store)
    _ = try await sm.restore(accountID: "a@example.org")
    try await sm.enable(accountID: "a@example.org", fullJID: "a@example.org/r", streamID: "resume", expiresAt: nil)
    try await sm.record("<message id='m'/>")
    try await sm.record("<iq type='get' id='q'><ping xmlns='urn:xmpp:ping'/></iq>")
    try await sm.record("<presence/>")
    let journal = try #require(await store.value?.journal)
    #expect(journal.map(\.kind) == [.message, .iq, .presence])
    #expect(journal[1].xml == nil)
    #expect(journal[0].xml == "<message id='m'/>" && journal[2].xml == "<presence/>")
    #expect(await store.value?.outboundSent == 3)
    #expect(journal.count == 3)
    let remaining = try await sm.acknowledge(1)
    #expect(remaining == [journal[2]])
    #expect(await store.value?.journal.count == 2)
    #expect(await store.acknowledged == ["m"])
    #expect(try await sm.acknowledge(3).isEmpty)
    #expect(await store.value?.journal.isEmpty == true)
    await #expect(throws: XMPPStreamManagementError.invalidAcknowledgement) { try await sm.acknowledge(4) }
}

@Test func legacySnapshotDecodesAndNeverReplaysItsIQBytes() async throws {
    let json = """
    {"revision":3,"accountID":"a@example.org","fullJID":"a@example.org/r","streamID":"resume","inboundHandled":0,
     "outboundSent":2,"outboundAcknowledged":0,"journal":[
      {"sequence":1,"xml":"<message id='a'/>","messageID":"a"},
      {"sequence":2,"xml":"<iq type='set' id='old'/>"}]}
    """
    let legacy = try JSONDecoder().decode(XMPPStreamManagementSnapshot.self, from: Data(json.utf8))
    #expect(legacy.journal.map(\.kind) == [.message, .iq])
    #expect(legacy.journal[1].xml == "<iq type='set' id='old'/>")
    let store = SnapshotStore()
    await store.seed(legacy)
    let sm = StreamManagement(store)
    #expect(try await sm.restore(accountID: "a@example.org") != nil)
    let remaining = try await sm.acknowledge(0, resumed: true)
    #expect(remaining.map(\.xml) == ["<message id='a'/>"])
    // A kind-less presence row derives .presence and stays replayable.
    let presence = try JSONDecoder().decode(XMPPStreamJournalEntry.self, from: Data(#"{"sequence":1,"xml":"<presence/>"}"#.utf8))
    #expect(presence.kind == .presence)
}

@Test func journalEntriesRoundTripWithoutIQBytes() throws {
    let entries: [XMPPStreamJournalEntry] = [.init(sequence: 1, kind: .message, xml: "<message id='m'/>", messageID: "m"),
                                             .init(sequence: 2, kind: .iq, xml: nil, messageID: nil),
                                             .init(sequence: 3, kind: .presence, xml: "<presence/>", messageID: nil)]
    let data = try JSONEncoder().encode(entries)
    #expect(try JSONDecoder().decode([XMPPStreamJournalEntry].self, from: data) == entries)
    let iqJSON = try #require(String(data: JSONEncoder().encode(entries[1]), encoding: .utf8))
    #expect(!iqJSON.contains("xml"))
}

private func enabledManager(_ store: SnapshotStore) async throws -> StreamManagement {
    let sm = StreamManagement(store)
    _ = try await sm.restore(accountID: "a@example.org")
    try await sm.enable(accountID: "a@example.org", fullJID: "a@example.org/r", streamID: "resume", expiresAt: nil)
    return sm
}

@Test func handledStaysInMemoryUntilAFlushPointAndIsNeverAdvertisedAhead() async throws {
    let store = SnapshotStore()
    let sm = try await enabledManager(store)
    #expect(await store.saves == 1)
    let t1 = try #require(await sm.receive()), t2 = try #require(await sm.receive()), t3 = try #require(await sm.receive())
    try await sm.handled(t1)
    try await sm.handled(t2)
    #expect(await store.saves == 1)
    #expect(await sm.persistedHandledCount() == 0)
    #expect(try await sm.flushHandled() == 2)
    #expect(await store.saves == 2)
    #expect(await store.value?.inboundHandled == 2)
    try await sm.handled(t3)
    #expect(await sm.persistedHandledCount() == 2)
    #expect(await store.value?.inboundHandled == 2)
    try await sm.record("<message id='x'/>")
    #expect(await store.value?.inboundHandled == 3)
    let saves = await store.saves
    #expect(try await sm.flushHandled() == 3)
    #expect(await store.saves == saves)
}

@Test func singleHandledFlushesAtTheBound() async throws {
    let store = SnapshotStore()
    let sm = try await enabledManager(store)
    var tokens: [XMPPInboundToken] = []
    for _ in 0..<64 { tokens.append(try #require(await sm.receive())) }
    for token in tokens.prefix(63) { try await sm.handled(token) }
    #expect(await store.saves == 1)
    #expect(await sm.persistedHandledCount() == 0)
    try await sm.handled(tokens[63])
    #expect(await store.saves == 2)
    #expect(await sm.persistedHandledCount() == 64)
}

@Test func batchedHandledCommitsOnceAndRejectsStaleOrForeignTokens() async throws {
    let store = SnapshotStore()
    let sm = try await enabledManager(store)
    var tokens: [XMPPInboundToken] = []
    for _ in 0..<100 { tokens.append(try #require(await sm.receive())) }
    try await sm.handled(tokens)
    #expect(await store.saves == 2)
    #expect(await sm.persistedHandledCount() == 100)
    let next = try #require(await sm.receive())
    await #expect(throws: XMPPStreamManagementError.staleToken) { try await sm.handled([next, XMPPInboundToken(session: UUID(), sequence: 1)]) }
    await #expect(throws: XMPPStreamManagementError.staleToken) { try await sm.handled([next, XMPPInboundToken(session: next.session, sequence: 999)]) }
    #expect(await store.saves == 2)
    // Nothing from a rejected batch was inserted.
    #expect(try await sm.flushHandled() == 100)
    #expect(await store.saves == 2)

    let fresh = SnapshotStore()
    let manager = try await enabledManager(fresh)
    let t1 = try #require(await manager.receive()), t2 = try #require(await manager.receive()), t3 = try #require(await manager.receive())
    try await manager.handled([t3, t1])
    #expect(await manager.persistedHandledCount() == 1)
    try await manager.handled([t2])
    #expect(await manager.persistedHandledCount() == 3)
}

@Test func restoreRejectsJournalsOverTheReplayableOrTotalCaps() async throws {
    func seeded(_ journal: [XMPPStreamJournalEntry]) async throws -> XMPPStreamManagementSnapshot? {
        let store = SnapshotStore()
        await store.seed(.init(revision: 1, accountID: "a@example.org", fullJID: "a@example.org/r", streamID: "resume", expiresAt: nil,
                               inboundHandled: 0, outboundSent: UInt64(journal.count), outboundAcknowledged: 0, journal: journal))
        return try await StreamManagement(store).restore(accountID: "a@example.org")
    }
    let messages = (1...2_001).map { XMPPStreamJournalEntry(sequence: UInt64($0), kind: .message, xml: "<message id='\($0)'/>", messageID: "\($0)") }
    await #expect(throws: XMPPStreamManagementError.invalidState) { _ = try await seeded(messages) }
    let iqs = (1...5_001).map { XMPPStreamJournalEntry(sequence: UInt64($0), kind: .iq, xml: nil, messageID: nil) }
    await #expect(throws: XMPPStreamManagementError.invalidState) { _ = try await seeded(iqs) }
    var mixed = Array(iqs.prefix(4_999))
    mixed.append(.init(sequence: 5_000, kind: .message, xml: "<message id='last'/>", messageID: "last"))
    #expect(try await seeded(mixed) != nil)
    let bytesless = [XMPPStreamJournalEntry(sequence: 1, kind: .message, xml: nil, messageID: "m")]
    await #expect(throws: XMPPStreamManagementError.invalidState) { _ = try await seeded(bytesless) }
}

@Test func receiveWindowCountsAgainstInMemoryHandled() async throws {
    let store = SnapshotStore()
    let sm = try await enabledManager(store)
    var tokens: [XMPPInboundToken] = []
    for _ in 0..<2_000 { tokens.append(try #require(await sm.receive())) }
    await #expect(throws: XMPPStreamManagementError.journalFull) { _ = try await sm.receive() }
    for token in tokens.prefix(10) { try await sm.handled(token) }
    #expect(await store.value?.inboundHandled == 0)
    #expect(try await sm.receive() != nil)
}

@Test func recordStillCapsReplayableEntriesButAdmitsIQsBeyondThem() async throws {
    let store = SnapshotStore()
    let sm = try await enabledManager(store)
    for index in 0..<2_000 { try await sm.record("<message id='\(index)'/>") }
    await #expect(throws: XMPPStreamManagementError.journalFull) { try await sm.record("<presence/>") }
    try await sm.record("<iq type='get' id='q'/>")
    #expect(await store.value?.journal.count == 2_001)
    #expect(await store.value?.journal.last?.kind == .iq)
}

@Test func resumeRestoresExactJournalAndHandlesUInt32Rollover() async throws {
    let store = SnapshotStore()
    let start = UInt64(UInt32.max)
    await store.seed(.init(revision: 7, accountID: "a@example.org", fullJID: "a@example.org/r", streamID: "resume", expiresAt: nil,
                           inboundHandled: 99, outboundSent: start + 3, outboundAcknowledged: start,
                           journal: [.init(sequence: start + 1, xml: "<message id='a'/>", messageID: "a"),
                                     .init(sequence: start + 2, kind: .iq, xml: nil, messageID: nil),
                                     .init(sequence: start + 3, xml: "<message id='b'/>", messageID: "b")]))
    let sm = StreamManagement(store)
    #expect(try await sm.restore(accountID: "a@example.org")?.inboundHandled == 99)
    #expect(await sm.persistedHandledCount() == 99)
    let remaining = try await sm.acknowledge(0, resumed: true)
    #expect(remaining.map(\.xml) == ["<message id='b'/>"])
    #expect(await store.acknowledged == ["a"])
    #expect(await store.value?.journal.count == 2)
    // The iq slot is trimmed by the server's count but never returned for replay or acknowledged as a message.
    #expect(try await sm.acknowledge(1).map(\.messageID) == ["b"])
    #expect(await store.acknowledged == ["a"])
    #expect(await store.value?.journal.count == 1)
    await #expect(throws: XMPPStreamManagementError.self) { try await sm.acknowledge(UInt32.max) }
}

private func recoveryNode(_ xml: String) throws -> XMPPProtocol.XMLNode {
    var parser = XMLStreamFramer()
    let frames = try parser.feed(Data(("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>" + xml).utf8))
    guard case .element(let node) = frames.last else { throw XMPPIQError.malformedResponse }
    return node
}
private func archived(from: String = "a@example.org", query: String = "query", inner: String = "<message xmlns='jabber:client' from='b@example.org/r' to='a@example.org/r'><body>hello</body></message>") -> String {
    "<message from='\(from)' to='a@example.org/r'><result xmlns='urn:xmpp:mam:2' queryid='\(query)' id='archive-1'><forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='2026-09-14T12:00:00Z'/>\(inner)</forwarded></result></message>"
}

@Test func archiveRejectsForeignSendersWrongQueriesNestedWrappersAndUnrelatedInnerActors() throws {
    var query = ArchiveQuery(queryID: "query", accountBareJID: "a@example.org", accountFullJID: "a@example.org/r", limit: 100)
    for xml in [archived(from: "evil@example.org"), archived(query: "other"), archived(inner: "<message xmlns='jabber:client' from='evil@example.org' to='victim@example.org'><body>forged</body></message>"), archived(inner: "<message xmlns='jabber:client' from='b@example.org/r' to='a@example.org/r'><received xmlns='urn:xmpp:carbons:2'/><body>forged</body></message>")] {
        #expect(throws: XMPPIQError.self) { try query.receive(recoveryNode(xml)) }
    }
    #expect(query.messages.isEmpty)
    try query.receive(recoveryNode(archived()))
    #expect(query.messages.first?.message?.body == "hello")
    #expect(throws: XMPPIQError.self) { try query.receive(recoveryNode(archived())) }
}

@Test func archiveCursorMustMatchDurablyReturnedLastResultAndCannotMakeNoProgress() throws {
    var query = ArchiveQuery(queryID: "query", accountBareJID: "a@example.org", accountFullJID: "a@example.org/r", limit: 1)
    try query.receive(recoveryNode(archived()))
    let valid = try recoveryNode("<iq type='result'><fin xmlns='urn:xmpp:mam:2' complete='true'><set xmlns='http://jabber.org/protocol/rsm'><last>archive-1</last></set></fin></iq>")
    #expect(try query.finish(valid).lastID == "archive-1")
    let forged = try recoveryNode("<iq type='result'><fin xmlns='urn:xmpp:mam:2'><set xmlns='http://jabber.org/protocol/rsm'><last>unseen</last></set></fin></iq>")
    #expect(throws: XMPPIQError.self) { try query.finish(forged) }
}

@Test func revokedTrustBlocksRestoredJournalAndResumeReplay() async throws {
    let store = SnapshotStore()
    await store.seed(.init(revision: 1, accountID: "a@example.org", fullJID: "a@example.org/r", streamID: "resume", expiresAt: nil,
                           inboundHandled: 0, outboundSent: 1, outboundAcknowledged: 0,
                           journal: [.init(sequence: 1, xml: "<message id='a'/>", messageID: "a")]))
    let sm = StreamManagement(store)
    await store.setResumeAllowed(false)
    #expect(try await sm.restore(accountID: "a@example.org") == nil)
    #expect(await store.value?.journal.count == 1)
    await store.setResumeAllowed(true)
    #expect(try await sm.restore(accountID: "a@example.org") != nil)
    _ = try await sm.acknowledge(0, resumed: true)
    await store.setResumeAllowed(false)
    #expect(try await !sm.permitsReplay())
    await #expect(throws: XMPPStreamManagementError.self) { try await sm.restore(accountID: "other@example.org") }
}

@Test func outgoingReplayDecoderCannotSubstituteSenderOrAcceptPlaintext() throws {
    let envelope = XMPPOMEMOEnvelope(profile: .modern, senderDeviceID: 1,
                                     keys: [.init(recipientJID: "b@example.org", deviceID: 2, keyExchange: false, data: Data([1]))], payload: Data([2]))
    let xml = try XMPPClient.encryptedMessageXML(to: "b@example.org", envelope: envelope, id: "saved")
    let decoded = try XMPPClient.decodeOutgoingEncryptedMessageXML(xml, from: "a@example.org")
    #expect(decoded.from == "a@example.org")
    #expect(decoded.envelope == envelope)
    #expect(throws: XMPPIQError.self) { try XMPPClient.decodeOutgoingEncryptedMessageXML(xml.replacingOccurrences(of: "<message ", with: "<message from='other@example.org' "), from: "a@example.org") }
    #expect(throws: XMPPIQError.self) { try XMPPClient.decodeOutgoingEncryptedMessageXML("<message to='b@example.org'><body>plaintext</body></message>", from: "a@example.org") }
}

@Test func archiveNormalizesOnlyTrustedMissingRecipientAndAcceptsRedactedPositions() throws {
    var query = ArchiveQuery(queryID: "query", accountBareJID: "a@example.org", accountFullJID: "a@example.org/r", limit: 2)
    try query.receive(recoveryNode(archived(inner: "<message xmlns='jabber:client' from='b@example.org'><body>hello</body></message>")))
    #expect(query.messages.first?.message?.to == "a@example.org")
    let redacted = "<message><result xmlns='urn:xmpp:mam:2' queryid='query' id='redacted'><forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='2026-09-14T12:00:00Z'/></forwarded></result></message>"
    try query.receive(recoveryNode(redacted))
    #expect(query.messages.last?.archiveID == "redacted")
    #expect(query.messages.last?.message == nil)
}
