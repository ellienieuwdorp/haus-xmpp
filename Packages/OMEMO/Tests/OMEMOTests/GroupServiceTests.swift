import Foundation
import XCTest
import MessageStore
import XMPPProtocol
@testable import OMEMO

private actor RoomFixture {
    let room = "private@conference.localhost"
    var members = ["alice@localhost", "bob@localhost"]
    func setMembers(_ values: [String]) { members = values }
    func snapshot(_ requested: String) throws -> XMPPGroupRoomSnapshot {
        guard requested == room else { throw XMPPGroupError.unsupportedRoom }
        return try .init(room: room, members: members, revision: 1, joined: true)
    }
}
private struct GroupTransport: OMEMOGroupTransport {
    let base: TestTransport
    let room: RoomFixture
    func refreshGroupRoom(_ requested: String) async throws -> XMPPGroupRoomSnapshot { try await room.snapshot(requested) }
    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async throws -> [UInt32] { try await base.fetchOMEMODevices(for: jid, profile: profile) }
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle { try await base.fetchOMEMOBundle(for: jid, deviceID: deviceID, profile: profile) }
    func publishOMEMODevices(_ devices: [UInt32], profile: XMPPOMEMOProfile) async throws { try await base.publishOMEMODevices(devices, profile: profile) }
    func publishOMEMOBundle(_ bundle: XMPPOMEMOBundle) async throws { try await base.publishOMEMOBundle(bundle) }
}

@MainActor final class GroupServiceTests: XCTestCase {
    func testGroupMessageAuthenticatesRoomAndSenderAndRejectsDirectSubstitution() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let room = RoomFixture(), roomID = "private@conference.localhost"
        let at = GroupTransport(base: f.aTransport, room: room), bt = GroupTransport(base: f.bTransport, room: room)
        let outgoing = StoredMessage(id: "group-one", accountID: f.alice, chatID: roomID, senderID: f.alice, body: "Private group", isOutgoing: true)
        try await f.aStore.upsertChat(accountID: f.alice, chatID: roomID, title: "Private group")
        _ = try await f.aStore.enqueueOutgoing(outgoing)
        try await f.a.prepareGroupMessage(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
        let prepared = try await f.a.outgoingGroupEnvelope(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
        XCTAssertEqual(prepared.members, [f.alice, f.bob])
        let replay = try await f.a.canReplay(account: f.alice, xml: XMPPClient.encryptedMessageXML(to: roomID, envelope: prepared.envelope, id: outgoing.id))
        XCTAssertFalse(replay)
        do {
            _ = try await f.b.receive(account: f.bob, message: f.message(prepared.envelope), transport: f.bTransport)
            XCTFail("A group ciphertext must not authenticate as a DM")
        } catch { XCTAssertEqual(error as? OMEMOError, .invalidContent) }
        let incoming = try XMPPEncryptedGroupMessage(id: outgoing.id, room: roomID, occupant: roomID + "/nickname", sender: f.alice, envelope: prepared.envelope)
        let inserted = try await f.b.receiveGroup(account: f.bob, message: incoming, transport: bt)
        XCTAssertTrue(inserted)
        let messages = try await f.bStore.messages(accountID: f.bob, chatID: roomID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.senderID, f.alice)
        XCTAssertEqual(messages.first?.body, outgoing.body)
        let duplicate = try await f.b.receiveGroup(account: f.bob, message: incoming, transport: bt)
        XCTAssertFalse(duplicate)
        let control = try await f.bStore.claimNextUpdate(accountID: f.bob)
        XCTAssertEqual(control?.update.chatID, f.alice)
        XCTAssertEqual(control?.update.kind, .keyTransport)
    }

    func testAllThreeMembersReceiveAndUntrustedGroupRemainsDiscoverable() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let carol = "carol@localhost", roomID = "private@conference.localhost", room = RoomFixture()
        await room.setMembers([f.alice, f.bob, carol])
        let cStore = try f.openStore("carol.sqlite")
        try await cStore.acquireTransportOwnership()
        let c = OMEMOService(store: cStore, protection: f.protection)
        let ct = GroupTransport(base: TestTransport(account: carol, server: f.server), room: room)
        let at = GroupTransport(base: f.aTransport, room: room)
        try await c.initialize(account: carol, transport: ct)
        let overview = try await f.a.refreshGroupDevices(account: f.alice, room: roomID, transport: at)
        XCTAssertTrue(overview.needsTrust)
        for device in overview.devices where device.active { try await f.a.setTrust(account: f.alice, deviceID: device.id, trust: .accepted) }
        try await f.aStore.upsertChat(accountID: f.alice, chatID: roomID, title: "Three members")
        let outgoing = StoredMessage(id: "three-members", accountID: f.alice, chatID: roomID, senderID: f.alice, body: "Also for the offline member", isOutgoing: true)
        _ = try await f.aStore.enqueueOutgoing(outgoing)
        try await f.a.prepareGroupMessage(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
        let prepared = try await f.a.outgoingGroupEnvelope(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
        XCTAssertEqual(Set(prepared.envelope.keys.compactMap(\.recipientJID)), Set([f.bob, carol]))
        let received = try XMPPEncryptedGroupMessage(id: outgoing.id, room: roomID, occupant: roomID + "/alice", sender: f.alice, envelope: prepared.envelope, provenance: .roomArchive)
        do { _ = try await c.receiveGroup(account: carol, message: received, transport: ct); XCTFail("Unknown fingerprint") }
        catch { XCTAssertEqual(error as? OMEMOError, .trustRequired) }
        let pending = try await c.pendingConversations(account: carol)
        XCTAssertEqual(pending[roomID], 1)
        let devices = try await c.refreshGroupDevices(account: carol, room: roomID, transport: ct).devices
        for device in devices where device.jid == f.alice && device.active { try await c.setTrust(account: carol, deviceID: device.id, trust: .accepted) }
        // The author left before this member fetched room history; authenticated archive
        // identity and previously approved key still allow historical decryption.
        await room.setMembers([f.bob, carol])
        _ = try await c.refreshGroupDevices(account: carol, room: roomID, transport: ct)
        try await c.retryPendingIncoming(account: carol, transport: ct)
        let stored = try await cStore.messages(accountID: carol, chatID: roomID)
        XCTAssertEqual(stored.first?.body, outgoing.body)
        let after = try await c.pendingConversations(account: carol)
        XCTAssertNil(after[roomID])
        await room.setMembers([f.alice, f.bob, carol])
        let bobReceived = try await f.b.receiveGroup(account: f.bob, message: received, transport: GroupTransport(base: f.bTransport, room: room))
        XCTAssertTrue(bobReceived)
    }

    func testGroupReactionsUseRoomAssignedIDReplaceFullSetsAndNeverCreateBubbles() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let room = RoomFixture(), roomID = "private@conference.localhost"
        let at = GroupTransport(base: f.aTransport, room: room), bt = GroupTransport(base: f.bTransport, room: room)
        try await f.aStore.upsertChat(accountID: f.alice, chatID: roomID, title: "Private group")
        let outgoing = StoredMessage(id: "reactable-group", accountID: f.alice, chatID: roomID, senderID: f.alice, body: "React privately", isOutgoing: true)
        _ = try await f.aStore.enqueueOutgoing(outgoing)
        try await f.a.prepareGroupMessage(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
        let saved = try await f.a.outgoingGroupEnvelope(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
        do { _ = try await f.a.queueReactions(account: f.alice, chatID: roomID, messageID: outgoing.id, reactions: ["👍"]); XCTFail("No room assignment yet") }
        catch { XCTAssertEqual(error as? OMEMOError, .unsupportedEncryptedReactions) }
        let reflected = try XMPPEncryptedGroupMessage(id: outgoing.id, room: roomID, occupant: roomID + "/alice", sender: f.alice, envelope: saved.envelope, roomStanzaID: "room-assigned-target")
        _ = try await f.a.receiveGroup(account: f.alice, message: reflected, transport: at)
        _ = try await f.b.receiveGroup(account: f.bob, message: reflected, transport: bt)
        let messages = try await f.bStore.messages(accountID: f.bob, chatID: roomID)
        let target = try XCTUnwrap(messages.first)
        for values in [["👍", "❤️"], ["❤️"], []] {
            let updateID = try await f.b.queueReactions(account: f.bob, chatID: roomID, messageID: target.id, reactions: values)
            let update = try await f.bStore.reactionUpdate(accountID: f.bob, updateID: updateID)
            XCTAssertEqual(update?.targetWireID, "room-assigned-target")
            let direct = try await f.b.prepareAvailableUpdates(account: f.bob, transport: f.bTransport)
            XCTAssertFalse(direct.messageIDs.contains(updateID), "group reactions are sealed only against a checked membership")
            try await f.b.prepareGroupReaction(account: f.bob, updateID: updateID, room: roomID, transport: bt)
            let reaction = try await f.b.outgoingGroupReactionEnvelope(account: f.bob, updateID: updateID, room: roomID, transport: bt)
            let replay = try await f.b.canReplay(account: f.bob, xml: XMPPClient.encryptedMessageXML(to: roomID, envelope: reaction.envelope, id: updateID))
            XCTAssertFalse(replay)
            let incoming = try XMPPEncryptedGroupMessage(id: updateID, room: roomID, occupant: roomID + "/bob", sender: f.bob, envelope: reaction.envelope)
            _ = try await f.a.receiveGroup(account: f.alice, message: incoming, transport: at)
            let projected = try await f.a.reactions(account: f.alice, chatID: roomID, messageID: outgoing.id)
            XCTAssertEqual(projected.first?.actorID, f.bob)
            XCTAssertEqual(projected.first?.reactions, values.sorted())
            let timeline = try await f.aStore.reactionsForChat(accountID: f.alice, chatID: roomID, messageIDs: [outgoing.id])
            XCTAssertEqual(timeline[outgoing.id]?.first?.reactions, values.sorted())
            let bubbles = try await f.aStore.messages(accountID: f.alice, chatID: roomID)
            XCTAssertEqual(bubbles.count, 1)
            let duplicated = try await f.a.receiveGroup(account: f.alice, message: incoming, transport: at)
            XCTAssertFalse(duplicated)
        }
    }

    func testFreshInstallationCanDiscardPriorGroupArchiveWithoutItsDeviceKey() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let room = RoomFixture(), roomID = "private@conference.localhost"
        let at = GroupTransport(base: f.aTransport, room: room), bt = GroupTransport(base: f.bTransport, room: room)
        try await f.aStore.upsertChat(accountID: f.alice, chatID: roomID, title: "Group")
        let outgoing = StoredMessage(id: "before-new-phone", accountID: f.alice, chatID: roomID, senderID: f.alice, body: "Old group archive", isOutgoing: true)
        _ = try await f.aStore.enqueueOutgoing(outgoing)
        try await f.a.prepareGroupMessage(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
        let prepared = try await f.a.outgoingGroupEnvelope(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
        let newStore = try f.openStore("new-phone.sqlite")
        try await newStore.acquireTransportOwnership()
        let fresh = OMEMOService(store: newStore, protection: f.protection)
        try await fresh.initialize(account: f.bob, transport: bt)
        let archive = try XMPPEncryptedGroupMessage(id: outgoing.id, room: roomID, occupant: roomID + "/historical", sender: f.alice, envelope: prepared.envelope, provenance: .ownArchive)
        do { _ = try await fresh.receiveGroup(account: f.bob, message: archive, transport: bt); XCTFail("New device was not a recipient") }
        catch { XCTAssertEqual(error as? OMEMOError, .notForThisDevice) }
        let durable = try await fresh.hasDurableGroupDisposition(account: f.bob, message: archive)
        XCTAssertTrue(durable)
        let known = try await fresh.knownGroupRooms(account: f.bob)
        XCTAssertTrue(known.isEmpty)
        let pending = try await newStore.pendingEncryptedIncoming(accountID: f.bob)
        XCTAssertTrue(pending.isEmpty)
    }

    func testOfflineMemberWithoutDevicesAndRejectedDeviceBlockWholeGroup() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let room = RoomFixture(), roomID = "private@conference.localhost"
        let transport = GroupTransport(base: f.aTransport, room: room)
        let message = StoredMessage(id: "blocked-group", accountID: f.alice, chatID: roomID, senderID: f.alice, body: "Do not partially encrypt", isOutgoing: true)
        try await f.aStore.upsertChat(accountID: f.alice, chatID: roomID, title: "Private group")
        _ = try await f.aStore.enqueueOutgoing(message)
        await room.setMembers([f.alice, f.bob, "offline@localhost"])
        do { try await f.a.prepareGroupMessage(account: f.alice, messageID: message.id, room: roomID, transport: transport); XCTFail() }
        catch { XCTAssertEqual(error as? OMEMOError, .noDevices) }
        let absent = try await f.aStore.encryptedOutgoing(accountID: f.alice, messageID: message.id)
        XCTAssertNil(absent)
        await room.setMembers([f.alice, f.bob])
        let devices = try await f.a.overview(account: f.alice, peer: f.bob).devices
        let bob = try XCTUnwrap(devices.first { $0.jid == f.bob && $0.active })
        try await f.a.setTrust(account: f.alice, deviceID: bob.id, trust: .rejected)
        do { try await f.a.prepareGroupMessage(account: f.alice, messageID: message.id, room: roomID, transport: transport); XCTFail() }
        catch { XCTAssertEqual(error as? OMEMOError, .trustRequired) }
        try await f.a.setTrust(account: f.alice, deviceID: bob.id, trust: .accepted)
        try await f.a.prepareGroupMessage(account: f.alice, messageID: message.id, room: roomID, transport: transport)
        let before = try await f.aStore.encryptedOutgoing(accountID: f.alice, messageID: message.id)
        await room.setMembers([f.alice])
        do { _ = try await f.a.outgoingGroupEnvelope(account: f.alice, messageID: message.id, room: roomID, transport: transport); XCTFail() } catch {}
        let after = try await f.aStore.encryptedOutgoing(accountID: f.alice, messageID: message.id)
        XCTAssertEqual(before, after)
    }
}
