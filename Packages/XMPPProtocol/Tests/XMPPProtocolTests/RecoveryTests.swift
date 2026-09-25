import Foundation
import Testing
@testable import XMPPProtocol

private actor SnapshotStore: XMPPStreamManagementPersistence {
    var value: XMPPStreamManagementSnapshot?
    var acknowledged: [String] = []
    var reject = false
    var resumeAllowed = true
    func load() -> XMPPStreamManagementSnapshot? { value }
    func save(_ snapshot: XMPPStreamManagementSnapshot, expectedRevision: Int?, acknowledgedMessageIDs: [String]) throws {
        if reject { throw XMPPStreamManagementError.invalidState }
        guard value?.revision == expectedRevision else { throw XMPPStreamManagementError.invalidState }
        value = snapshot; acknowledged += acknowledgedMessageIDs
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
    #expect(await sm.handledCount() == 0)
    try await sm.handled(message)
    #expect(await sm.handledCount() == 2)
}

@Test func failedCheckpointDoesNotAdvanceAdvertisedHandledCounter() async throws {
    let store = SnapshotStore()
    let manager = StreamManagement(store)
    _ = try await manager.restore(accountID: "a@example.org")
    try await manager.enable(accountID: "a@example.org", fullJID: "a@example.org/r", streamID: "resume", expiresAt: nil)
    let token = try #require(await manager.receive())
    await store.rejectSaves(true)
    await #expect(throws: XMPPStreamManagementError.self) { try await manager.handled(token) }
    #expect(await manager.handledCount() == 0)
    await store.rejectSaves(false)
    try await manager.handled(token)
    #expect(await manager.handledCount() == 1)
}

@Test func resumeRestoresExactJournalAndHandlesUInt32Rollover() async throws {
    let store = SnapshotStore()
    let start = UInt64(UInt32.max)
    await store.seed(.init(revision: 7, accountID: "a@example.org", fullJID: "a@example.org/r", streamID: "resume", expiresAt: nil,
                           inboundHandled: 99, outboundSent: start + 2, outboundAcknowledged: start,
                           journal: [.init(sequence: start + 1, xml: "<message id='a'/>", messageID: "a"), .init(sequence: start + 2, xml: "<message id='b'/>", messageID: "b")]))
    let sm = StreamManagement(store)
    #expect(try await sm.restore(accountID: "a@example.org")?.inboundHandled == 99)
    let remaining = try await sm.acknowledge(0, resumed: true)
    #expect(remaining.map(\.xml) == ["<message id='b'/>"])
    #expect(await store.acknowledged == ["a"])
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

@Test func archiveQueriesGetTheLongerTimeoutAndTheEventBufferOutlastsTheStreamCeiling() {
    #expect(XMPPClient.archiveQueryTimeout == .seconds(60))
    #expect(XMPPClient.iqTimeout == .seconds(15))
    #expect(XMPPClient.archiveQueryTimeout > XMPPClient.iqTimeout)
    #expect(XMPPClient.eventBufferLimit == 4096)
    // Content plus barrier per message: the buffer outlasts stream management's 2,000-stanza ceiling.
    #expect(XMPPClient.eventBufferLimit >= 2 * 2_000)
}
