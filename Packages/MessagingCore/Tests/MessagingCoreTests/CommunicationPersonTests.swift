import Foundation
import MessageStore
import Testing
@testable import MessagingCore
#if canImport(Intents)
import Intents
#endif

private let account = "me@example.org"

/// A direct chat's incoming message with its link state as the store reports it: the contact only while reachable.
private func candidate(chatTitle: String? = "peer@example.org", contact: String? = nil) -> NotificationCandidate {
    let message = StoredMessage(id: "m1", accountID: account, chatID: "peer@example.org", senderID: "peer@example.org", body: "Hi",
                                sentAt: Date(timeIntervalSince1970: 1), encryptionProfile: "modern")
    return NotificationCandidate(key: .message("m1"), accountID: account, chatID: "peer@example.org", chatTitle: chatTitle,
                                 senderID: "peer@example.org", senderContactIdentifier: contact, isGroup: false, sentAt: message.sentAt,
                                 content: .message(message))
}

private func communication(_ candidate: NotificationCandidate, previews: Bool = true) -> NotificationCommunication? {
    NotificationPlanner.plan(MessageNotification(candidates: [candidate], claimed: [candidate.key], previewsEnabled: previews)).requests.first?.communication
}

@Test func theCustomIdentifierIsOpaqueStableAndAccountScoped() {
    let first = CommunicationPerson.identifier(accountID: account, jid: "peer@example.org")
    #expect(first == CommunicationPerson.identifier(accountID: account, jid: "peer@example.org"))
    #expect(first.hasPrefix("p1-") && first.count == 67)
    #expect(!first.contains("peer") && !first.contains("example"))
    #expect(first != CommunicationPerson.identifier(accountID: "other@example.org", jid: "peer@example.org"))
    #expect(first != CommunicationPerson.identifier(accountID: account, jid: "other@example.org"))
}

/// Every link state the store can report, with previews on and off. The store already folds the app's Contacts access
/// into `isReachable` (full access, or limited access that includes the contact); the builder only passes it on.
@Test func theContactIdentifierReachesTheSystemOnlyForAReachableLinkWithPreviewsOn() throws {
    // No link: the JID as an IM-address handle, nothing about Contacts.
    var fields = CommunicationPerson.fields(try #require(communication(candidate())).sender, accountID: account)
    #expect(fields == .init(handle: "peer@example.org", displayName: "peer", contactIdentifier: nil,
                            customIdentifier: CommunicationPerson.identifier(accountID: account, jid: "peer@example.org"), isMe: false,
                            suggestsInstantMessageAddress: true))
    // A link the app cannot read (made without access, deleted, or outside the limited set): the cached name only.
    fields = CommunicationPerson.fields(try #require(communication(candidate(chatTitle: "Peer Example"))).sender, accountID: account)
    #expect(fields.displayName == "Peer Example" && fields.contactIdentifier == nil)
    // A reachable link: the contact too.
    fields = CommunicationPerson.fields(try #require(communication(candidate(chatTitle: "Peer Example", contact: "C-1"))).sender, accountID: account)
    #expect(fields.displayName == "Peer Example" && fields.contactIdentifier == "C-1" && fields.suggestsInstantMessageAddress)
    // Previews off: no person at all, so no name, handle or contact reaches the system.
    #expect(communication(candidate(chatTitle: "Peer Example", contact: "C-1"), previews: false) == nil)
    // The account itself never carries a contact or a suggestion.
    let me = CommunicationPerson.fields(.init(handle: account, displayName: "me", avatarHash: nil, contactIdentifier: "C-me"), accountID: account, isMe: true)
    #expect(me.contactIdentifier == nil && !me.suggestsInstantMessageAddress && me.isMe)
}

@Test func roomMembersAndReactionActorsCarryTheirOwnLinks() throws {
    let message = StoredMessage(id: "g1", accountID: account, chatID: "room@rooms", senderID: "bob@x", body: "Hi", encryptionProfile: "modern")
    let group = NotificationCandidate(key: .message("g1"), accountID: account, chatID: "room@rooms", chatTitle: "Book club", senderID: "bob@x",
                                      senderTitle: "Bob Example", senderContactIdentifier: "C-bob", isGroup: true, sentAt: message.sentAt,
                                      content: .message(message),
                                      groupMembers: [NotificationParticipant(id: "carol@x", title: nil, avatarHash: nil, contactIdentifier: "C-carol")])
    let plan = NotificationPlanner.plan(MessageNotification(candidates: [group], claimed: [group.key], previewsEnabled: true))
    let communication = try #require(plan.requests.first?.communication)
    #expect(communication.sender.contactIdentifier == "C-bob" && communication.sender.displayName == "Bob Example")
    #expect(communication.otherRecipients.map(\.contactIdentifier) == ["C-carol"])
    let target = StoredMessage(id: "t1", accountID: account, chatID: "peer@example.org", senderID: account, body: "Lunch?", isOutgoing: true,
                               encryptionProfile: "modern")
    let reaction = ReactionNotificationCandidate(key: .reaction(sequence: 1), accountID: account, chatID: "peer@example.org", chatTitle: "Peer Example",
                                                 actor: NotificationParticipant(id: "peer@example.org", title: "Peer Example", avatarHash: nil,
                                                                                contactIdentifier: "C-1"),
                                                 isGroup: false, target: target, reactions: ["👍"], reactedAt: Date(timeIntervalSince1970: 2))
    let reacted = NotificationPlanner.plan(MessageNotification(candidates: [], claimed: [reaction.key], previewsEnabled: true, reactions: [reaction]))
    #expect(reacted.requests.first?.communication?.sender.contactIdentifier == "C-1")
}

#if canImport(Intents)
@Test func theIntentPersonUsesTheBuilderFields() {
    let person = CommunicationPerson.person(.init(handle: "peer@example.org", displayName: "Peer", avatarHash: nil), accountID: account, image: nil)
    #expect(person.personHandle?.value == "peer@example.org" && person.personHandle?.type == .unknown)
    #expect(person.customIdentifier == CommunicationPerson.identifier(accountID: account, jid: "peer@example.org"))
    #expect(person.suggestionType == .instantMessageAddress && person.contactIdentifier == nil)
}

@Test func unlinkingDeletesTheConversationsDonations() async {
    actor Seen { var groups: [String] = []; func add(_ group: String) { groups.append(group) } }
    let seen = Seen()
    let thread = NotificationIdentity.thread(accountID: account, chatID: "peer@example.org")
    await CommunicationHistory.deleteConversations([thread]) { await seen.add($0) }
    #expect(await seen.groups == [thread])
    struct Refused: Error {}
    // A failure is logged, never thrown.
    await CommunicationHistory.deleteConversations([thread]) { _ in throw Refused() }
}
#endif
