#if canImport(Intents) && canImport(UserNotifications)
import Foundation
import Intents
import MessageStore
import Testing
import UserNotifications
@testable import MessagingCore

private let me = NotificationCommunication.Person(handle: "me@example.org", displayName: "me", avatarHash: nil)

@Test func directChatIntentCarriesTheSenderHandleNameAvatarAndThread() throws {
    let communication = NotificationCommunication(sender: .init(handle: "peer@example.org", displayName: "Peer", avatarHash: "abc"),
                                                  conversationIdentifier: "thread-1", account: me, body: "Hi")
    var asked: [String] = []
    let intent = CommunicationNotification.intent(communication) { hash in asked.append(hash); return Data([0x89, 0x50, 0x4E, 0x47]) }
    let sender = try #require(intent.sender)
    #expect(sender.personHandle?.value == "peer@example.org" && sender.personHandle?.type == .unknown)
    #expect(sender.displayName == "Peer" && sender.image != nil && sender.customIdentifier == "peer@example.org")
    #expect(intent.conversationIdentifier == "thread-1")
    #expect(intent.speakableGroupName == nil && intent.recipients == nil && intent.content == nil)
    #expect(asked == ["abc"])
    // No cached copy: the system draws its own monogram; nothing fails.
    #expect(CommunicationNotification.intent(communication) { _ in nil }.sender?.image == nil)
}

@Test func groupIntentNamesTheRoomAndEveryKnownRecipientIncludingTheAccount() throws {
    let communication = NotificationCommunication(sender: .init(handle: "bob@x", displayName: "Bob", avatarHash: nil), conversationIdentifier: "thread-2",
                                                  account: me, groupName: "Book club", groupAvatarHash: "room",
                                                  otherRecipients: [.init(handle: "carol@x", displayName: "Carol", avatarHash: nil)], body: "Hi all")
    let intent = CommunicationNotification.intent(communication) { _ in nil }
    #expect(intent.speakableGroupName?.spokenPhrase == "Book club")
    #expect(intent.recipients?.map { $0.personHandle?.value } == ["me@example.org", "carol@x"])
    #expect(intent.recipients?.first?.isMe == true && intent.sender?.displayName == "Bob")
}

@Test func planContentKeepsEverythingTheRequestCarries() {
    let request = PlannedNotification(identifier: "m-1", threadIdentifier: "t", title: "Peer", body: "Hi", playsSound: true, destination: nil, badge: 3)
    let content = UserNotificationPoster.content(for: request)
    #expect(content.title == "Peer" && content.body == "Hi" && content.threadIdentifier == "t" && content.badge == 3 && content.sound != nil)
    #expect(UserNotificationPoster.content(for: request, body: "Only the text").body == "Only the text")
    #expect(UserNotificationPoster.content(for: PlannedNotification(identifier: "m-2", threadIdentifier: "t", title: "", body: "New message",
                                                                    playsSound: false, destination: nil)).badge == nil)
}
#endif
