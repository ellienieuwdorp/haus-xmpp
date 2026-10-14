import Foundation
import XCTest
import MessageStore
import XMPPProtocol
import OMEMOCrypto
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
    /// When set, every room read and key lookup is recorded.
    var log: TransportLog? = nil
    /// When set, room reads fail (recorded first), as for a room that cannot be read right now.
    var roomUnavailable = false
    /// When set, key lookups fail (recorded first), as when offline.
    var keysUnavailable = false
    func refreshGroupRoom(_ requested: String) async throws -> XMPPGroupRoomSnapshot {
        await log?.record(.refreshRoom(requested))
        if roomUnavailable { throw OMEMOError.unavailable }
        return try await room.snapshot(requested)
    }
    func fetchOMEMODevices(for jid: String, profile: XMPPOMEMOProfile) async throws -> [UInt32] {
        await log?.record(.devices(jid, profile))
        if keysUnavailable { throw OMEMOError.unavailable }
        return try await base.fetchOMEMODevices(for: jid, profile: profile)
    }
    func fetchOMEMOBundle(for jid: String, deviceID: UInt32, profile: XMPPOMEMOProfile) async throws -> XMPPOMEMOBundle {
        await log?.record(.bundle(jid, deviceID, profile))
        if keysUnavailable { throw OMEMOError.unavailable }
        return try await base.fetchOMEMOBundle(for: jid, deviceID: deviceID, profile: profile)
    }
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
        } catch { XCTAssertEqual(error as? OMEMOError, .undecryptable) }
        // The substituted copy is a quiet placeholder in the DM, never content; the room copy still decrypts below.
        let substituted = try await f.bStore.messages(accountID: f.bob, chatID: f.alice)
        XCTAssertEqual(substituted.map(\.unreadableReason), [.decryptFailed])
        let incoming = try XMPPEncryptedGroupMessage(id: outgoing.id, room: roomID, occupant: roomID + "/nickname", sender: f.alice, envelope: prepared.envelope)
        let inserted = try await f.b.receiveGroup(account: f.bob, message: incoming, transport: bt)
        XCTAssertTrue(inserted)
        let messages = try await f.bStore.messages(accountID: f.bob, chatID: roomID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.senderID, f.alice)
        XCTAssertEqual(messages.first?.body, outgoing.body)
        // The room copy alerts once, as a room message from its authenticated sender; the DM substitute is unreadable.
        let alerts = try await f.bStore.pendingNotifications(accountID: f.bob)
        let group = alerts.candidates.filter(\.isGroup)
        XCTAssertEqual(group.map(\.chatID), [roomID])
        XCTAssertEqual(group.first?.senderID, f.alice)
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
        let received = try XMPPEncryptedGroupMessage(id: outgoing.id, room: roomID, occupant: roomID + "/alice", sender: f.alice, envelope: prepared.envelope,
                                                     provenance: .roomArchive, hasFallbackBody: true)
        do { _ = try await c.receiveGroup(account: carol, message: received, transport: ct); XCTFail("Unknown fingerprint") }
        catch { XCTAssertEqual(error as? OMEMOError, .trustRequired) }
        // An unapproved sender's room message alerts once in the room, without content.
        let review = try await cStore.pendingNotifications(accountID: carol)
        XCTAssertEqual(review.candidates.map(\.content), [.pendingEncrypted])
        XCTAssertEqual(review.candidates.first?.chatID, roomID)
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
            let projected = try await f.aStore.reactions(accountID: f.alice, chatID: roomID, messageID: outgoing.id)
            XCTAssertEqual(projected.first?.actorID, f.bob)
            XCTAssertEqual(projected.first?.reactions, values.sorted())
            let timeline = try await f.aStore.eventsForChat(accountID: f.alice, chatID: roomID, messageIDs: [outgoing.id])
            XCTAssertEqual(timeline[outgoing.id]?.compactMap(AuthenticatedReaction.init).first?.reactions, values.sorted())
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
        let silent = try await newStore.messages(accountID: f.bob, chatID: roomID)
        XCTAssertTrue(silent.isEmpty)
        // With a body fallback the envelope would have been a message: it leaves a placeholder in the room.
        let hinted = try XMPPEncryptedGroupMessage(id: outgoing.id, room: roomID, occupant: roomID + "/historical", sender: f.alice,
                                                   envelope: prepared.envelope, provenance: .ownArchive, hasFallbackBody: true)
        let before = try await fresh.hasDurableGroupDisposition(account: f.bob, message: hinted)
        XCTAssertFalse(before)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        do { _ = try await fresh.receiveGroup(account: f.bob, message: hinted, transport: bt, sentAt: stamp); XCTFail("New device was not a recipient") }
        catch { XCTAssertEqual(error as? OMEMOError, .notForThisDevice) }
        let rows = try await newStore.messages(accountID: f.bob, chatID: roomID)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.unreadableReason, .notForThisDevice)
        XCTAssertEqual(rows.first?.isOutgoing, false)
        XCTAssertEqual(rows.first?.senderID, f.alice)
        XCTAssertEqual(rows.first?.sentAt, stamp)
        let after = try await fresh.hasDurableGroupDisposition(account: f.bob, message: hinted)
        XCTAssertTrue(after)
        do { _ = try await fresh.receiveGroup(account: f.bob, message: hinted, transport: bt); XCTFail("New device was not a recipient") }
        catch { XCTAssertEqual(error as? OMEMOError, .notForThisDevice) }
        let repeated = try await newStore.messages(accountID: f.bob, chatID: roomID)
        XCTAssertEqual(repeated.count, 1)
        let stillUnknown = try await fresh.knownGroupRooms(account: f.bob)
        XCTAssertTrue(stillUnknown.isEmpty)
        let reference = try await newStore.reactionReference(accountID: f.bob, messageID: try XCTUnwrap(rows.first).id)
        XCTAssertNil(reference)
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

    /// The user's Don't Trust on another device of their own account leaves it out of group sends, as 1:1 chats leave it
    /// out. An undecided own device (a changed identity included) and another member's rejected device still hold the group.
    func testRejectedOwnDeviceIsLeftOutWhileOtherHoldsRemain() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let room = RoomFixture(), roomID = "private@conference.localhost"
        let transport = GroupTransport(base: f.aTransport, room: room)
        let secondStore = try f.openStore("alice-second.sqlite")
        try await secondStore.acquireTransportOwnership()
        let second = OMEMOService(store: secondStore, protection: f.protection)
        try await second.initialize(account: f.alice, transport: f.aTransport)
        try await f.a.maintainLocalAdvertisement(account: f.alice, profile: .modern, transport: f.aTransport)
        let secondID = try await second.localIdentity(account: f.alice, profile: .modern).deviceID
        try await f.aStore.upsertChat(accountID: f.alice, chatID: roomID, title: "Private group")
        func queue() async throws -> String {
            let message = StoredMessage(id: UUID().uuidString, accountID: f.alice, chatID: roomID, senderID: f.alice, body: "Hi", isOutgoing: true)
            _ = try await f.aStore.enqueueOutgoing(message)
            return message.id
        }
        func expectHeld(_ id: String, _ reason: String) async throws {
            do { try await f.a.prepareGroupMessage(account: f.alice, messageID: id, room: roomID, transport: transport); XCTFail(reason) }
            catch { XCTAssertEqual(error as? OMEMOError, .trustRequired, reason) }
        }

        let first = try await queue()
        try await expectHeld(first, "an undecided own device needs review")
        let own = try await f.a.ownDevices(account: f.alice).filter { $0.deviceID == secondID && $0.profile == .modern && $0.active }
        XCTAssertEqual(own.map(\.trust), [.undecided])
        try await f.a.setTrust(account: f.alice, deviceIDs: own.map(\.id), trust: .rejected)
        let overview = try await f.a.refreshGroupDevices(account: f.alice, room: roomID, transport: transport)
        XCTAssertFalse(overview.needsTrust)
        try await f.a.prepareGroupMessage(account: f.alice, messageID: first, room: roomID, transport: transport)
        let prepared = try await f.a.outgoingGroupEnvelope(account: f.alice, messageID: first, room: roomID, transport: transport)
        XCTAssertFalse(prepared.envelope.keys.contains { $0.recipientJID == f.alice && $0.deviceID == secondID })
        XCTAssertTrue(prepared.envelope.keys.contains { $0.recipientJID == f.bob })

        // The exclusion is the account's own decision only: Bob's rejected device keeps holding the group.
        let bob = try XCTUnwrap(overview.devices.first { $0.jid == f.bob && $0.active })
        try await f.a.setTrust(account: f.alice, deviceID: bob.id, trust: .rejected)
        try await expectHeld(try await queue(), "another member's rejected device holds the group")
        try await f.a.setTrust(account: f.alice, deviceID: bob.id, trust: .accepted)

        // The rejected device publishes a new identity under the same ID: a new undecided record, reviewed again.
        let replacement = try OMEMOEngine(profile: .modern, deviceID: secondID).bundle()
        await f.server.publish(f.alice, XMPPOMEMOBundle(profile: .modern, deviceID: secondID, identityKey: replacement.identityKey,
                                                        signedPreKeyID: replacement.signedPreKeyID, signedPreKey: replacement.signedPreKey,
                                                        signedPreKeySignature: replacement.signedPreKeySignature, preKeys: replacement.preKeys))
        try await expectHeld(try await queue(), "a changed own identity needs review")
    }

    /// In a room, as in a direct chat: a blocked member device's message is a quiet placeholder in the room on arrival, and
    /// its room message kept for review before the block drains to the same outcome on the next retry.
    func testBlockedMemberDeviceLeavesQuietRoomPlaceholdersAndNothingPending() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let room = RoomFixture(), roomID = "private@conference.localhost"
        let at = GroupTransport(base: f.aTransport, room: room), bt = GroupTransport(base: f.bTransport, room: room)
        try await f.aStore.upsertChat(accountID: f.alice, chatID: roomID, title: "Private group")
        var messages: [XMPPEncryptedGroupMessage] = []
        for (index, body) in ["Before the block", "After the block"].enumerated() {
            let outgoing = StoredMessage(id: "group-\(index)", accountID: f.alice, chatID: roomID, senderID: f.alice, body: body, isOutgoing: true)
            _ = try await f.aStore.enqueueOutgoing(outgoing)
            try await f.a.prepareGroupMessage(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
            let prepared = try await f.a.outgoingGroupEnvelope(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
            messages.append(try XMPPEncryptedGroupMessage(id: outgoing.id, room: roomID, occupant: roomID + "/alice", sender: f.alice,
                                                          envelope: prepared.envelope, hasFallbackBody: true))
        }
        let bobsView = try await f.b.overview(account: f.bob, peer: f.alice).devices
        let author = try XCTUnwrap(bobsView.first { $0.jid == f.alice && $0.active })
        try await f.b.setTrust(account: f.bob, deviceID: author.id, trust: .undecided)
        do { _ = try await f.b.receiveGroup(account: f.bob, message: messages[0], transport: bt); XCTFail("Trust undecided") }
        catch { XCTAssertEqual(error as? OMEMOError, .trustRequired) }
        try await f.b.setTrust(account: f.bob, deviceID: author.id, trust: .rejected)
        let arrived = try await f.b.receiveGroup(account: f.bob, message: messages[1], transport: bt)
        XCTAssertFalse(arrived)
        let durable = try await f.b.hasDurableGroupDisposition(account: f.bob, message: messages[1])
        XCTAssertTrue(durable)
        try await f.b.retryPendingIncoming(account: f.bob, transport: bt)
        let pending = try await f.bStore.pendingEncryptedIncoming(accountID: f.bob)
        XCTAssertTrue(pending.isEmpty)
        let rows = try await f.bStore.messages(accountID: f.bob, chatID: roomID)
        XCTAssertEqual(rows.map(\.unreadableReason), [.rejectedDevice, .rejectedDevice])
        XCTAssertTrue(rows.allSatisfy { $0.body.isEmpty && $0.senderID == f.alice })
        let alerts = try await f.bStore.pendingNotifications(accountID: f.bob).candidates
        XCTAssertTrue(alerts.isEmpty)
    }

    /// An approved member's room message kept only while the room is read waits for that read, not for a review: however
    /// many rows strangers already hold, only the account ceiling bounds it, so it still decrypts in a room Bob only reads.
    func testApprovedMemberStillDecryptsOnceStrangersFillTheirShare() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let room = RoomFixture(), roomID = "private@conference.localhost"
        let at = GroupTransport(base: f.aTransport, room: room), bt = GroupTransport(base: f.bTransport, room: room)
        for index in 0..<MessageStore.pendingLimits.strangerCeiling {
            try await f.bStore.retainEncryptedIncoming(accountID: f.bob, sender: f.bob, digest: "filler-\(index)", wire: Data([1]))
        }
        let outgoing = StoredMessage(id: "group-one", accountID: f.alice, chatID: roomID, senderID: f.alice, body: "Read the room first", isOutgoing: true)
        try await f.aStore.upsertChat(accountID: f.alice, chatID: roomID, title: "Private group")
        _ = try await f.aStore.enqueueOutgoing(outgoing)
        try await f.a.prepareGroupMessage(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
        let prepared = try await f.a.outgoingGroupEnvelope(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
        let incoming = try XMPPEncryptedGroupMessage(id: outgoing.id, room: roomID, occupant: roomID + "/alice", sender: f.alice,
                                                     envelope: prepared.envelope, hasFallbackBody: true)
        let inserted = try await f.b.receiveGroup(account: f.bob, message: incoming, transport: bt)
        XCTAssertTrue(inserted)
        let rows = try await f.bStore.messages(accountID: f.bob, chatID: roomID)
        XCTAssertEqual(rows.map(\.body), [outgoing.body])
        XCTAssertEqual(rows.map(\.unreadableReason), [nil])
    }

    /// A room row kept before room messages recorded their `<body/>` hint drains like a direct one once its member device
    /// is blocked: a quiet placeholder, not a message that silently vanishes.
    func testBlockedMemberRowKeptBeforeTheBodyHintStillLeavesAPlaceholder() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let room = RoomFixture(), roomID = "private@conference.localhost"
        let at = GroupTransport(base: f.aTransport, room: room), bt = GroupTransport(base: f.bTransport, room: room)
        try await f.aStore.upsertChat(accountID: f.alice, chatID: roomID, title: "Private group")
        let outgoing = StoredMessage(id: "group-old", accountID: f.alice, chatID: roomID, senderID: f.alice, body: "Kept long ago", isOutgoing: true)
        _ = try await f.aStore.enqueueOutgoing(outgoing)
        try await f.a.prepareGroupMessage(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
        let prepared = try await f.a.outgoingGroupEnvelope(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
        let message = try XMPPEncryptedGroupMessage(id: outgoing.id, room: roomID, occupant: roomID + "/alice", sender: f.alice,
                                                    envelope: prepared.envelope, hasFallbackBody: true)
        let bobsView = try await f.b.overview(account: f.bob, peer: f.alice).devices
        let author = try XCTUnwrap(bobsView.first { $0.jid == f.alice && $0.active })
        try await f.b.setTrust(account: f.bob, deviceID: author.id, trust: .undecided)
        do { _ = try await f.b.receiveGroup(account: f.bob, message: message, transport: bt); XCTFail("Trust undecided") }
        catch { XCTAssertEqual(error as? OMEMOError, .trustRequired) }
        // Rewrite the kept row as an older build wrote it: no hint in the retained stanza.
        let retained = try await f.bStore.pendingEncryptedIncoming(accountID: f.bob, sender: f.alice)
        let kept = try XCTUnwrap(retained.first)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: kept.wire) as? [String: Any])
        var stanza = try XCTUnwrap(json["message"] as? [String: Any])
        stanza["hasFallbackBody"] = nil
        json["message"] = stanza
        let replaced = try await f.bStore.replacePendingEncryptedIncomingContext(accountID: f.bob, sender: f.alice, digest: kept.digest,
            expectedWire: kept.wire, wire: try JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(replaced)
        try await f.b.setTrust(account: f.bob, deviceID: author.id, trust: .rejected)
        try await f.b.retryPendingIncoming(account: f.bob, transport: bt)
        let pending = try await f.bStore.pendingEncryptedIncoming(accountID: f.bob)
        XCTAssertTrue(pending.isEmpty)
        let rows = try await f.bStore.messages(accountID: f.bob, chatID: roomID)
        XCTAssertEqual(rows.map(\.unreadableReason), [.rejectedDevice])
    }

    /// Carol's second installation joins a room Bob already knows and sends before Bob has seen that device.
    private func carolSecondDeviceMessage(_ f: ServiceFixture, room: RoomFixture, roomID: String, carol: String,
                                          provenance: XMPPGroupProvenance = .liveOccupant) async throws -> (XMPPEncryptedGroupMessage, String) {
        let secondStore = try f.openStore("carol-second.sqlite")
        try await secondStore.acquireTransportOwnership()
        let second = OMEMOService(store: secondStore, protection: f.protection)
        let st = GroupTransport(base: TestTransport(account: carol, server: f.server), room: room)
        try await second.initialize(account: carol, transport: st)
        for device in try await second.refreshGroupDevices(account: carol, room: roomID, transport: st).devices where device.active {
            try await second.setTrust(account: carol, deviceID: device.id, trust: .accepted)
        }
        let body = "From Carol's new device"
        try await secondStore.upsertChat(accountID: carol, chatID: roomID, title: "Room")
        let outgoing = StoredMessage(id: "carol-second", accountID: carol, chatID: roomID, senderID: carol, body: body, isOutgoing: true)
        _ = try await secondStore.enqueueOutgoing(outgoing)
        try await second.prepareGroupMessage(account: carol, messageID: outgoing.id, room: roomID, transport: st)
        let prepared = try await second.outgoingGroupEnvelope(account: carol, messageID: outgoing.id, room: roomID, transport: st)
        let message = try XMPPEncryptedGroupMessage(id: outgoing.id, room: roomID, occupant: roomID + "/carol", sender: carol,
                                                    envelope: prepared.envelope, provenance: provenance)
        return (message, body)
    }

    func testUnknownSenderDeviceInAKnownRoomRefreshesOnlyThatSender() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let carol = "carol@localhost", roomID = "private@conference.localhost", room = RoomFixture()
        await room.setMembers([f.alice, f.bob, carol])
        let cStore = try f.openStore("carol.sqlite")
        try await cStore.acquireTransportOwnership()
        let c = OMEMOService(store: cStore, protection: f.protection)
        try await c.initialize(account: carol, transport: GroupTransport(base: TestTransport(account: carol, server: f.server), room: room))
        // Bob already knows the room and every member device, and has approved them.
        let bt = GroupTransport(base: f.bTransport, room: room)
        for device in try await f.b.refreshGroupDevices(account: f.bob, room: roomID, transport: bt).devices where device.active {
            try await f.b.setTrust(account: f.bob, deviceID: device.id, trust: .accepted)
        }
        let (message, body) = try await carolSecondDeviceMessage(f, room: room, roomID: roomID, carol: carol)
        let log = TransportLog()
        let counting = GroupTransport(base: f.bTransport, room: room, log: log)
        do { _ = try await f.b.receiveGroup(account: f.bob, message: message, transport: counting); XCTFail("New device needs a trust decision") }
        catch { XCTAssertEqual(error as? OMEMOError, .trustRequired) }
        let calls = await log.calls
        XCTAssertEqual(calls, [.devices(carol, .modern), .bundle(carol, message.envelope.senderDeviceID, .modern)])
        let pending = try await f.bStore.pendingEncryptedIncoming(accountID: f.bob)
        XCTAssertEqual(pending.map(\.reason), [.trustPending])
        let durable = try await f.b.hasDurableGroupDisposition(account: f.bob, message: message)
        XCTAssertTrue(durable)
        let (_, state) = try await f.b.load(f.bob)
        let added = try XCTUnwrap(state.devices.last { $0.jid == carol && $0.deviceID == message.envelope.senderDeviceID })
        XCTAssertEqual(added.trust, .undecided)
        XCTAssertFalse(added.identityChanged)
        try await f.b.setTrust(account: f.bob, deviceID: added.id, trust: .accepted)
        try await f.b.retryPendingIncoming(account: f.bob, transport: counting)
        let stored = try await f.bStore.messages(accountID: f.bob, chatID: roomID)
        XCTAssertEqual(stored.map(\.body), [body])
        let after = await log.calls
        XCTAssertFalse(after.contains(.refreshRoom(roomID)))
    }

    func testKeysPendingGroupRowIsRetriedAfterTrustOnceItsDeviceBecameKnownElsewhere() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let carol = "carol@localhost", roomID = "private@conference.localhost", room = RoomFixture()
        await room.setMembers([f.alice, f.bob, carol])
        let cStore = try f.openStore("carol.sqlite")
        try await cStore.acquireTransportOwnership()
        let c = OMEMOService(store: cStore, protection: f.protection)
        try await c.initialize(account: carol, transport: GroupTransport(base: TestTransport(account: carol, server: f.server), room: room))
        let bt = GroupTransport(base: f.bTransport, room: room)
        for device in try await f.b.refreshGroupDevices(account: f.bob, room: roomID, transport: bt).devices where device.active {
            try await f.b.setTrust(account: f.bob, deviceID: device.id, trust: .accepted)
        }
        let (message, body) = try await carolSecondDeviceMessage(f, room: room, roomID: roomID, carol: carol, provenance: .roomArchive)
        // The sender device's keys cannot be fetched (offline): the ciphertext waits for keys.
        do { _ = try await f.b.receiveGroup(account: f.bob, message: message, transport: GroupTransport(base: f.bTransport, room: room, keysUnavailable: true)); XCTFail("Keys were unavailable") }
        catch {}
        var reasons = try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).map(\.reason)
        XCTAssertEqual(reasons, [.keysPending])
        // A full room refresh adds Carol's second device, undecided.
        _ = try await f.b.refreshGroupDevices(account: f.bob, room: roomID, transport: bt)
        // The connection retry skips the row without work, but it now waits for a trust decision.
        let log = TransportLog()
        try await f.b.retryPendingIncoming(account: f.bob, transport: GroupTransport(base: f.bTransport, room: room, log: log))
        let calls = await log.calls
        XCTAssertEqual(calls, [])
        reasons = try await f.bStore.pendingEncryptedIncoming(accountID: f.bob).map(\.reason)
        XCTAssertEqual(reasons, [.trustPending])
        let (_, state) = try await f.b.load(f.bob)
        let added = try XCTUnwrap(state.devices.last { $0.jid == carol && $0.deviceID == message.envelope.senderDeviceID })
        XCTAssertEqual(added.trust, .undecided)
        // Accepting the device retries trust-pending rows only (as the app does), and that finds this one.
        try await f.b.setTrust(account: f.bob, deviceID: added.id, trust: .accepted)
        try await f.b.retryPendingIncoming(account: f.bob, transport: bt, reasons: [.trustPending])
        let stored = try await f.bStore.messages(accountID: f.bob, chatID: roomID)
        XCTAssertEqual(stored.map(\.body), [body])
        let remaining = try await f.bStore.pendingEncryptedIncoming(accountID: f.bob)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRetryReadsAnUnknownRoomOncePerPass() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let roomID = "private@conference.localhost", room = RoomFixture()
        let at = GroupTransport(base: f.aTransport, room: room)
        for device in try await f.a.refreshGroupDevices(account: f.alice, room: roomID, transport: at).devices where device.active {
            try await f.a.setTrust(account: f.alice, deviceID: device.id, trust: .accepted)
        }
        try await f.aStore.upsertChat(accountID: f.alice, chatID: roomID, title: "Room")
        var messages: [XMPPEncryptedGroupMessage] = []
        for (index, text) in ["First to an unread room", "Second to an unread room"].enumerated() {
            let outgoing = StoredMessage(id: "unknown-room-\(index)", accountID: f.alice, chatID: roomID, senderID: f.alice, body: text, isOutgoing: true)
            _ = try await f.aStore.enqueueOutgoing(outgoing)
            try await f.a.prepareGroupMessage(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
            let prepared = try await f.a.outgoingGroupEnvelope(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
            messages.append(try XMPPEncryptedGroupMessage(id: outgoing.id, room: roomID, occupant: roomID + "/alice", sender: f.alice,
                                                          envelope: prepared.envelope, provenance: .roomArchive, hasFallbackBody: true))
        }
        // Bob has never read this room and cannot read it now: both messages are retained.
        let unreadable = GroupTransport(base: f.bTransport, room: room, roomUnavailable: true)
        for message in messages {
            do { _ = try await f.b.receiveGroup(account: f.bob, message: message, transport: unreadable); XCTFail("Room was unreadable") } catch {}
        }
        var pending = try await f.bStore.pendingEncryptedIncoming(accountID: f.bob)
        XCTAssertEqual(pending.count, 2)
        // The sender device is trusted; only the room read is missing. Nothing here needs the user's review.
        let alerts = try await f.bStore.pendingNotifications(accountID: f.bob)
        XCTAssertTrue(alerts.candidates.isEmpty)
        // One retry pass reads the still-unreadable room once, not once per row, and reports the failure.
        let log = TransportLog()
        do { try await f.b.retryPendingIncoming(account: f.bob, transport: GroupTransport(base: f.bTransport, room: room, log: log, roomUnavailable: true)); XCTFail("Room was unreadable") }
        catch {}
        let calls = await log.calls
        XCTAssertEqual(calls.filter { $0 == .refreshRoom(roomID) }.count, 1)
        pending = try await f.bStore.pendingEncryptedIncoming(accountID: f.bob)
        XCTAssertEqual(pending.count, 2)
        // Once the room can be read, the next pass decrypts both.
        try await f.b.retryPendingIncoming(account: f.bob, transport: GroupTransport(base: f.bTransport, room: room))
        let stored = try await f.bStore.messages(accountID: f.bob, chatID: roomID)
        XCTAssertEqual(stored.map(\.body), ["First to an unread room", "Second to an unread room"])
    }

    func testLiveOccupantOutsideStoredMembershipStillRefreshesTheRoom() async throws {
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let carol = "carol@localhost", roomID = "private@conference.localhost", room = RoomFixture()
        // Bob knows the room as Alice and Bob only.
        let bt = GroupTransport(base: f.bTransport, room: room)
        for device in try await f.b.refreshGroupDevices(account: f.bob, room: roomID, transport: bt).devices where device.active {
            try await f.b.setTrust(account: f.bob, deviceID: device.id, trust: .accepted)
        }
        // Carol joins and speaks live: stored membership cannot vouch for her, so the room is read again.
        await room.setMembers([f.alice, f.bob, carol])
        let cStore = try f.openStore("carol.sqlite")
        try await cStore.acquireTransportOwnership()
        let c = OMEMOService(store: cStore, protection: f.protection)
        try await c.initialize(account: carol, transport: GroupTransport(base: TestTransport(account: carol, server: f.server), room: room))
        let (message, _) = try await carolSecondDeviceMessage(f, room: room, roomID: roomID, carol: carol)
        let log = TransportLog()
        do { _ = try await f.b.receiveGroup(account: f.bob, message: message, transport: GroupTransport(base: f.bTransport, room: room, log: log)); XCTFail("New member needs a trust decision") }
        catch { XCTAssertEqual(error as? OMEMOError, .trustRequired) }
        let calls = await log.calls
        XCTAssertTrue(calls.contains(.refreshRoom(roomID)))
        let known = try await f.b.knownGroupRooms(account: f.bob)
        XCTAssertEqual(known[roomID], [f.alice, f.bob, carol])
        let pending = try await f.bStore.pendingEncryptedIncoming(accountID: f.bob)
        XCTAssertEqual(pending.count, 1)
    }
}

extension GroupServiceTests {
    /// Rooms are modern only: the preview rides with the room message and is stored for its authenticated sender.
    func testGroupMessageCarriesItsPreview() async throws {
        let preview = StoredLinkPreview(url: "https://example.org/news", title: "Council approves", imageData: Data([0xFF, 0xD8]),
                                        imageType: "image/jpeg", source: .own)
        var received = preview; received.source = .sender
        let f = try ServiceFixture(); addTeardownBlock { try await f.cleanup() }
        try await f.initialize(.modern)
        let room = RoomFixture(), roomID = "private@conference.localhost"
        let at = GroupTransport(base: f.aTransport, room: room), bt = GroupTransport(base: f.bTransport, room: room)
        let outgoing = StoredMessage(id: "group-one", accountID: f.alice, chatID: roomID, senderID: f.alice, body: "Read https://example.org/news", isOutgoing: true,
                                     linkPreview: preview)
        try await f.aStore.upsertChat(accountID: f.alice, chatID: roomID, title: "Private group")
        _ = try await f.aStore.enqueueOutgoing(outgoing)
        try await f.a.prepareGroupMessage(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
        let mine = try await f.aStore.message(accountID: f.alice, messageID: outgoing.id)
        XCTAssertEqual(mine?.linkPreview, preview)
        let prepared = try await f.a.outgoingGroupEnvelope(account: f.alice, messageID: outgoing.id, room: roomID, transport: at)
        let incoming = try XMPPEncryptedGroupMessage(id: outgoing.id, room: roomID, occupant: roomID + "/alice", sender: f.alice, envelope: prepared.envelope)
        let inserted = try await f.b.receiveGroup(account: f.bob, message: incoming, transport: bt)
        XCTAssertTrue(inserted)
        let stored = try await f.bStore.messages(accountID: f.bob, chatID: roomID).first
        XCTAssertEqual(stored?.linkPreview, received)
    }
}
