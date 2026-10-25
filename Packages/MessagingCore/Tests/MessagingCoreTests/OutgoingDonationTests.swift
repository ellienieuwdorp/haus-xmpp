import Foundation
import Testing
@testable import MessagingCore

#if canImport(Intents)
import Intents

struct OutgoingDonationTests {
    @Test func aDirectSendDonatesTheChatAsTheOnlyRecipientOutgoingWithoutText() throws {
        let conversation = OutgoingConversation.direct(accountID: "me@x", chatID: "peer@x", displayName: "Peer", avatarHash: "abc")
        var asked: [String] = []
        let intent = OutgoingDonation.intent(conversation) { asked.append($0); return Data([0x89, 0x50, 0x4E, 0x47]) }
        #expect(intent.conversationIdentifier == NotificationIdentity.thread(accountID: "me@x", chatID: "peer@x"))
        let recipient = try #require(intent.recipients?.first)
        #expect(intent.recipients?.count == 1 && recipient.personHandle?.value == "peer@x" && recipient.personHandle?.type == .unknown)
        // The same person the incoming notification names.
        let incoming = CommunicationPerson.person(.init(handle: "peer@x", displayName: "Peer", avatarHash: nil), accountID: "me@x", image: nil)
        #expect(recipient.customIdentifier == incoming.customIdentifier && recipient.displayName == "Peer" && recipient.image != nil)
        #expect(intent.sender == nil && intent.content == nil && intent.speakableGroupName == nil)
        #expect(asked == ["abc"])
        let interaction = OutgoingDonation.interaction(for: intent)
        #expect(interaction.direction == .outgoing && interaction.groupIdentifier == intent.conversationIdentifier)
    }

    @Test func aRoomSendNamesTheRoomAndItsMembersButNeverTheAccount() {
        let members: [NotificationCommunication.Person] = (0..<12).map { .init(handle: "m\($0)@x", displayName: "M\($0)", avatarHash: nil) }
        let conversation = OutgoingConversation.room(accountID: "me@x", room: "room@muc.x", title: "Book club", avatarHash: "room",
                                                     members: [.init(handle: "me@x", displayName: "me", avatarHash: nil)] + members)
        let intent = OutgoingDonation.intent(conversation) { $0 == "room" ? Data([1]) : nil }
        #expect(intent.speakableGroupName?.spokenPhrase == "Book club")
        #expect(intent.recipients?.count == 8 && intent.recipients?.contains { $0.personHandle?.value == "me@x" } == false)
        #expect(intent.recipients?.allSatisfy { $0.isMe == false } == true)
        #expect(intent.__image(forParameterNamed: "speakableGroupName") != nil)
    }

    @Test func previewsOffOrSuggestionsOffDonateNothing() {
        #expect(OutgoingDonation.isAllowed(previews: true, suggestions: true))
        #expect(!OutgoingDonation.isAllowed(previews: false, suggestions: true))
        #expect(!OutgoingDonation.isAllowed(previews: true, suggestions: false))
    }

    @Test func donationAndDeletionFailuresNeverThrowAndDeletionReportsSuccess() async {
        let probe = InteractionLog()
        await OutgoingDonation.donate([.direct(accountID: "me@x", chatID: "a@x", displayName: "A", avatarHash: nil),
                                       .direct(accountID: "me@x", chatID: "b@x", displayName: "B", avatarHash: nil)],
                                      avatar: { _ in nil }, donate: { interaction in
            probe.add(interaction.groupIdentifier ?? "")
            if probe.count == 1 { throw CocoaError(.featureUnsupported) }
        })
        #expect(probe.values == [NotificationIdentity.thread(accountID: "me@x", chatID: "a@x"), NotificationIdentity.thread(accountID: "me@x", chatID: "b@x")])
        let deleted = InteractionLog()
        await CommunicationHistory.deleteConversations(["t1", "t2"]) { identifier in
            deleted.add(identifier)
            throw CocoaError(.featureUnsupported)
        }
        #expect(deleted.values == ["t1", "t2"])
        #expect(await CommunicationHistory.deleteAll { } == true)
        #expect(await CommunicationHistory.deleteAll { throw CocoaError(.featureUnsupported) } == false)
    }
}

private final class InteractionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    var values: [String] { lock.withLock { seen } }
    var count: Int { lock.withLock { seen.count } }
    func add(_ value: String) { lock.withLock { seen.append(value) } }
}
#endif
