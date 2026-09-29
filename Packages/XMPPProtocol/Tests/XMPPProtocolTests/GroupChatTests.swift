import Foundation
import Testing
@testable import XMPPProtocol

private func groupNode(_ xml: String) throws -> XMPPProtocol.XMLNode {
    var parser = XMLStreamFramer()
    let frames = try parser.feed(Data(("<stream:stream xmlns:stream='http://etherx.jabber.org/streams' xmlns='jabber:client'>" + xml).utf8))
    guard case .element(let node) = frames.last else { throw XMPPIQError.malformedResponse }
    return node
}
private let groupRoom = "room@conference.example.test"
private let groupAlice = "alice@example.test"
private let groupBob = "bob@example.test"
private func groupEnvelope() -> XMPPOMEMOEnvelope {
    .init(profile: .modern, senderDeviceID: 1, keys: [.init(recipientJID: groupBob, deviceID: 2, keyExchange: true, data: Data([1]))], payload: Data([2]))
}
@Test func groupDiscoveryRequiresNonanonymousMembersOnlyAndStrictAffiliationLists() throws {
    func discovery(_ features: [String]) throws -> XMPPProtocol.XMLNode {
        try groupNode("<iq from='\(groupRoom)'><query xmlns='\(GroupChatWire.disco)'>" + features.map { "<feature var='\($0)'/>" }.joined() + "</query></iq>")
    }
    try GroupChatWire.checkFeatures(discovery(["muc_nonanonymous", "muc_membersonly", "urn:xmpp:sid:0"]), room: groupRoom)
    for features in [["muc_nonanonymous"], ["muc_semianonymous", "muc_membersonly"], ["muc_nonanonymous", "muc_membersonly", "muc_open"]] {
        #expect(throws: (any Error).self) { try GroupChatWire.checkFeatures(discovery(features), room: groupRoom) }
    }
    for affiliation in ["member", "admin", "owner"] {
        let reply = try groupNode("<iq from='\(groupRoom)'><query xmlns='\(GroupChatWire.admin)'><item affiliation='\(affiliation)' jid='offline@example.test'/></query></iq>")
        #expect(try GroupChatWire.members(reply, room: groupRoom, affiliation: affiliation) == ["offline@example.test"])
        #expect(throws: (any Error).self) { try GroupChatWire.members(reply, room: "other@conference.example.test", affiliation: affiliation) }
    }
    #expect(throws: (any Error).self) { try XMPPGroupRoomSnapshot(room: groupRoom, members: [groupAlice, groupAlice], revision: 0, joined: true) }
}
@Test func groupPresenceBindsRealIdentityAndInvalidatesMembershipRevision() throws {
    var state = GroupRoomState(members: [groupAlice], nickname: "self")
    let own = try groupNode("<presence from='\(groupRoom)/self' to='\(groupAlice)/phone'><x xmlns='\(GroupChatWire.user)'><item affiliation='member' jid='\(groupAlice)/phone'/><status code='110'/></x></presence>")
    GroupChatWire.applyPresence(own, room: groupRoom, account: groupAlice, state: &state)
    #expect(state.joined)
    #expect(state.revision == 1)
    let added = try groupNode("<presence from='\(groupRoom)/new'><x xmlns='\(GroupChatWire.user)'><item affiliation='member' jid='\(groupBob)'/></x></presence>")
    GroupChatWire.applyPresence(added, room: groupRoom, account: groupAlice, state: &state)
    #expect(state.occupants[groupRoom + "/new"] == groupBob)
    #expect(!state.members.contains(groupBob)) // Mapping alone does not create membership.
    let unavailable = try groupNode("<presence from='\(groupRoom)/self' type='unavailable'/>")
    GroupChatWire.applyPresence(unavailable, room: groupRoom, account: groupAlice, state: &state)
    #expect(!state.joined)
    #expect(state.occupants[groupRoom + "/self"] == nil)
}
@Test func liveGroupRejectsUnknownNicknameAndConflictingRealJID() throws {
    let xml = try GroupChatWire.outgoing(room: groupRoom, envelope: groupEnvelope(), id: "g1")
        .replacingOccurrences(of: "to='\(groupRoom)'", with: "from='\(groupRoom)/nick' to='\(groupBob)'")
    var state = GroupRoomState(members: [groupAlice, groupBob], occupants: [groupRoom + "/nick": groupAlice], joined: true)
    let message = try GroupChatWire.message(groupNode(xml), account: groupBob, room: groupRoom, state: state)
    #expect(message.sender == groupAlice)
    let conflict = xml.replacingOccurrences(of: "</message>", with: "<x xmlns='\(GroupChatWire.user)'><item jid='mallory@example.test'/></x></message>")
    #expect(throws: (any Error).self) { try GroupChatWire.message(groupNode(conflict), account: groupBob, room: groupRoom, state: state) }
    state.occupants = [:]
    #expect(throws: (any Error).self) { try GroupChatWire.message(groupNode(xml), account: groupBob, room: groupRoom, state: state) }
}

@Test func groupPresenceAcceptsConsistentMultipleResourcesAndRejectsMixedIdentities() throws {
    func presence(_ entries: [(String, String)]) throws -> XMPPProtocol.XMLNode {
        let items = entries.map { "<item jid='\($0.0)' affiliation='\($0.1)' role='moderator'/>" }.joined()
        return try groupNode("<presence from='\(groupRoom)/self' to='\(groupAlice)/phone'><x xmlns='\(GroupChatWire.user)'>\(items)<status code='100'/><status code='110'/></x></presence>")
    }
    var state = GroupRoomState(members: [groupAlice], nickname: "self")
    GroupChatWire.applyPresence(try presence([(groupAlice + "/old", "owner"), (groupAlice + "/phone", "owner"), (groupAlice + "/tablet", "owner")]), room: groupRoom, account: groupAlice, state: &state)
    #expect(state.joined)
    #expect(state.occupants[groupRoom + "/self"] == groupAlice)
    GroupChatWire.applyPresence(try presence([(groupAlice + "/phone", "owner"), (groupBob, "owner")]), room: groupRoom, account: groupAlice, state: &state)
    #expect(!state.joined)
    #expect(state.occupants[groupRoom + "/self"] == nil)
    GroupChatWire.applyPresence(try presence([(groupAlice + "/phone", "owner"), (groupAlice + "/old", "member")]), room: groupRoom, account: groupAlice, state: &state)
    #expect(!state.joined)
}
@Test func groupArchiveRequiresScopedWrapperAndHistoricalRealJID() throws {
    let xml = try GroupChatWire.outgoing(room: groupRoom, envelope: groupEnvelope(), id: "archived")
        .replacingOccurrences(of: "to='\(groupRoom)'", with: "from='\(groupRoom)/reused-nick'")
    let mapped = xml.replacingOccurrences(of: "<message ", with: "<message xmlns='jabber:client' ").replacingOccurrences(of: "</message>", with: "<x xmlns='\(GroupChatWire.user)'><item jid='\(groupAlice)/old-device'/></x></message>")
    func wrapper(_ body: String, from: String = groupRoom) throws -> XMPPProtocol.XMLNode {
        try groupNode("<message from='\(from)' to='\(groupBob)/phone'><result xmlns='urn:xmpp:mam:2' queryid='q1' id='server-id'><forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='2026-09-14T20:00:00Z'/>\(body)</forwarded></result></message>")
    }
    var query = ArchiveQuery(queryID: "q1", accountBareJID: groupBob, accountFullJID: groupBob + "/phone", limit: 10)
    query.room = groupRoom; query.knownRooms = [groupRoom]
    var rejected = query
    try rejected.receive(wrapper(xml.replacingOccurrences(of: "<message ", with: "<message xmlns='jabber:client' ")))
    #expect(rejected.messages.first?.rejectedContent == .unverifiableEncryptedGroup)
    #expect(rejected.messages.first?.rejectionArchive == groupRoom)
    #expect(throws: (any Error).self) { try query.receive(wrapper(mapped, from: "evil.example.test")) }
    try query.receive(wrapper(mapped))
    #expect(query.messages.first?.encryptedGroupMessage?.sender == groupAlice)
    #expect(query.messages.first?.encryptedGroupMessage?.provenance == .roomArchive)
    #expect(query.messages.first?.message == nil)
}

@Test func groupStanzaReferencesRequireExactRoomAuthorityAndRejectAmbiguity() throws {
    let wrong = try groupNode("<message><stanza-id xmlns='urn:xmpp:sid:0' by='attacker@example.test' id='fake'/></message>")
    #expect(try GroupChatWire.stanzaID(wrong, room: groupRoom) == nil)
    #expect(try GroupChatWire.stanzaID(wrong, room: groupRoom, archiveID: "archive-cursor") == nil)
    let good = try groupNode("<message><stanza-id xmlns='urn:xmpp:sid:0' by='\(groupRoom)' id='assigned'/></message>")
    #expect(try GroupChatWire.stanzaID(good, room: groupRoom, archiveID: "assigned") == "assigned")
    #expect(throws: (any Error).self) { try GroupChatWire.stanzaID(good, room: groupRoom, archiveID: "conflicting") }
    let duplicates = try groupNode("<message><stanza-id xmlns='urn:xmpp:sid:0' by='\(groupRoom)' id='one'/><stanza-id xmlns='urn:xmpp:sid:0' by='\(groupRoom)' id='two'/></message>")
    #expect(throws: (any Error).self) { try GroupChatWire.stanzaID(duplicates, room: groupRoom) }
}

@Test func ownArchiveCanDiscoverPreviouslyUnknownRoomWithoutTrustingHistoricalNickname() throws {
    let wire = try GroupChatWire.outgoing(room: groupRoom, envelope: groupEnvelope(), id: "old-device-message")
        .replacingOccurrences(of: "<message ", with: "<message xmlns='jabber:client' ")
        .replacingOccurrences(of: "to='\(groupRoom)'", with: "from='\(groupRoom)/historical'")
    let mapped = wire.replacingOccurrences(of: "</message>", with: "<x xmlns='\(GroupChatWire.user)'><item jid='\(groupAlice)'/></x></message>")
    func wrapper(_ content: String) throws -> XMPPProtocol.XMLNode {
        try groupNode("<message from='\(groupBob)' to='\(groupBob)/new-phone'><result xmlns='urn:xmpp:mam:2' queryid='fresh' id='archive'><forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='2026-09-14T20:00:00Z'/>\(content)</forwarded></result></message>")
    }
    var query = ArchiveQuery(queryID: "fresh", accountBareJID: groupBob, accountFullJID: groupBob + "/new-phone", limit: 10)
    #expect(query.knownRooms.isEmpty)
    var rejected = query
    try rejected.receive(wrapper(wire))
    #expect(rejected.messages.first?.encryptedGroupMessage == nil)
    #expect(rejected.messages.first?.rejectedContent == .unverifiableEncryptedGroup)
    #expect(rejected.messages.first?.rejectionArchive == groupBob)
    try query.receive(wrapper(mapped))
    #expect(query.messages.first?.encryptedGroupMessage?.room == groupRoom)
    #expect(query.messages.first?.encryptedGroupMessage?.sender == groupAlice)
}

@Test func groupMessagesRecordFallbackBodyPresence() throws {
    let xml = try GroupChatWire.outgoing(room: groupRoom, envelope: groupEnvelope(), id: "g1")
        .replacingOccurrences(of: "to='\(groupRoom)'", with: "from='\(groupRoom)/nick' to='\(groupBob)'")
    let withBody = xml.replacingOccurrences(of: "</message>", with: "<body>fallback</body></message>")
    let state = GroupRoomState(members: [groupAlice, groupBob], occupants: [groupRoom + "/nick": groupAlice], joined: true)
    #expect(try !GroupChatWire.message(groupNode(xml), account: groupBob, room: groupRoom, state: state).hasFallbackBody)
    #expect(try GroupChatWire.message(groupNode(withBody), account: groupBob, room: groupRoom, state: state).hasFallbackBody)

    let own = try GroupChatWire.outgoing(room: groupRoom, envelope: groupEnvelope(), id: "g2")
        .replacingOccurrences(of: "<message ", with: "<message from='\(groupAlice)/phone' ")
    let ownWithBody = own.replacingOccurrences(of: "</message>", with: "<body>fallback</body></message>")
    let archived = try GroupChatWire.archivedMessage(groupNode(own), account: groupAlice, archiveRoom: nil, knownRooms: [])
    let archivedWithBody = try GroupChatWire.archivedMessage(groupNode(ownWithBody), account: groupAlice, archiveRoom: nil, knownRooms: [])
    #expect(archived.provenance == .ownArchive && !archived.hasFallbackBody)
    #expect(archivedWithBody.hasFallbackBody)
    // Retained envelopes encoded before the field existed still decode, as "no hint".
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(archivedWithBody)) as? [String: Any])
    #expect(json["hasFallbackBody"] as? Bool == true)
    json.removeValue(forKey: "hasFallbackBody")
    let legacy = try JSONDecoder().decode(XMPPEncryptedGroupMessage.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(!legacy.hasFallbackBody && legacy.envelope == archivedWithBody.envelope)
}

@Test func sendsAndKeyDistributionReadMembershipEvenWithoutPresenceChanges() throws {
    // Adding or removing a member who is not in the room sends no presence (XEP-0045 §9.3, §9.4), so an
    // unchanged revision must still cost one read on every path except archive paging.
    let members = [groupAlice, groupBob]
    var state = GroupRoomState()
    #expect(state.refreshDecision(reusingValidation: false) == .readTwice)
    #expect(state.refreshDecision(reusingValidation: true) == .readTwice)
    state.markValidated(members)
    #expect(state.refreshDecision(reusingValidation: false) == .readOnceExpecting(members))
    #expect(state.refreshDecision(reusingValidation: true) == .cached)
    // Occupant presence and our own nickname change both invalidate the cache for archive paging too.
    let occupant = try groupNode("<presence from='\(groupRoom)/bob'><x xmlns='\(GroupChatWire.user)'><item affiliation='member' jid='\(groupBob)'/></x></presence>")
    GroupChatWire.applyPresence(occupant, room: groupRoom, account: groupAlice, state: &state)
    #expect(state.refreshDecision(reusingValidation: true) == .readOnceExpecting(members))
    state.markValidated(members)
    #expect(state.refreshDecision(reusingValidation: true) == .cached)
    state.requestNickname("n")
    #expect(state.refreshDecision(reusingValidation: false) == .readOnceExpecting(members))
    #expect(state.refreshDecision(reusingValidation: true) == .readOnceExpecting(members))
    // An empty validated membership is never trusted as a cache.
    let empty = GroupRoomState(members: [], revision: 4, validatedRevision: 4)
    #expect(empty.refreshDecision(reusingValidation: true) == .readTwice)
    #expect(empty.refreshDecision(reusingValidation: false) == .readTwice)
}

@Test func aRefreshThatMustReadNeverJoinsOneThatMayAnswerFromTheCache() {
    let reading = GroupRoomRefreshKey(room: groupRoom, reusesValidation: false)
    let caching = GroupRoomRefreshKey(room: groupRoom, reusesValidation: true)
    #expect(GroupRoomRefreshKey.joinable(room: groupRoom, reusingValidation: false) == [reading])
    #expect(GroupRoomRefreshKey.joinable(room: groupRoom, reusingValidation: true) == [reading, caching])
}
