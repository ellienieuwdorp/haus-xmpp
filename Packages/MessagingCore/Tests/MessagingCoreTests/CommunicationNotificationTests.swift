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
    let intent = CommunicationNotification.intent(communication) { $0 == "room" ? Data([0x89, 0x50, 0x4E, 0x47]) : nil }
    #expect(intent.speakableGroupName?.spokenPhrase == "Book club")
    #expect(intent.recipients?.map { $0.personHandle?.value } == ["me@example.org", "carol@x"])
    #expect(intent.recipients?.first?.isMe == true && intent.sender?.displayName == "Bob")
    // The room's avatar is the image of the group name parameter. These tests run on macOS, where only the
    // string-named form of the accessor exists.
    #expect(intent.__image(forParameterNamed: "speakableGroupName") != nil)
    #expect(CommunicationNotification.intent(communication) { _ in nil }.__image(forParameterNamed: "speakableGroupName") == nil)
}

@Test func planContentKeepsEverythingTheRequestCarries() {
    let request = PlannedNotification(identifier: "m-1", threadIdentifier: "t", title: "Peer", body: "Hi", playsSound: true, destination: nil, badge: 3)
    let content = UserNotificationPoster.content(for: request)
    #expect(content.title == "Peer" && content.body == "Hi" && content.threadIdentifier == "t" && content.badge == 3 && content.sound != nil)
    #expect(UserNotificationPoster.content(for: request, body: "Only the text").body == "Only the text")
    #expect(UserNotificationPoster.content(for: PlannedNotification(identifier: "m-2", threadIdentifier: "t", title: "", body: "New message",
                                                                    playsSound: false, destination: nil)).badge == nil)
}
/// A donation that never answers in time, like a cold Intents service; records what it was given.
private final class DonationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [INInteraction] = []
    var interactions: [INInteraction] { lock.withLock { seen } }
    func record(_ interaction: INInteraction) { lock.withLock { seen.append(interaction) } }
}

@Test func aSlowOrFailedDonationStillAppliesTheCommunicationUpdate() async throws {
    let communication = NotificationCommunication(sender: .init(handle: "bob@x", displayName: "Bob", avatarHash: nil), conversationIdentifier: "thread-9",
                                                  account: me, groupName: "Trail crew", body: "Hi")
    let intent = CommunicationNotification.intent(communication) { _ in nil }
    let plain = UNMutableNotificationContent(); plain.title = "Trail crew"
    let communicated = UNMutableNotificationContent(); communicated.title = "communicated"
    let probe = DonationProbe()
    let clock = ContinuousClock(), start = clock.now
    let slow = await CommunicationNotification.content(plain, intent: intent, donate: { interaction in
        probe.record(interaction)
        await ignoringCancellation(for: .seconds(2))
    }, donationTimeout: .milliseconds(50), update: { _, _ in communicated })
    #expect(slow === communicated, "the update does not wait for, or depend on, the donation")
    #expect(clock.now - start < .seconds(1))
    // The donation is an incoming interaction grouped by conversation, so it can be deleted with it.
    let donated = try #require(probe.interactions.first)
    #expect(donated.direction == .incoming && donated.groupIdentifier == "thread-9")
    struct Refused: Error {}
    let failed = await CommunicationNotification.content(plain, intent: intent, donate: { _ in throw Refused() }, update: { _, _ in communicated })
    #expect(failed === communicated)
    // Without a donation (budget spent) the update still runs; only a failed update posts the plain request.
    #expect(await CommunicationNotification.content(plain, intent: intent, donate: nil, update: { _, _ in communicated }) === communicated)
    #expect(await CommunicationNotification.content(plain, intent: intent, donate: nil, update: { _, _ in throw Refused() }) == nil)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@Test func signingOutOrHidingPreviewsDeletesDonatedConversations() async {
    #expect(CommunicationHistory.purgesDonations(from: AccountPreferences(), to: AccountPreferences(notificationPreviews: false)))
    #expect(!CommunicationHistory.purgesDonations(from: AccountPreferences(notificationPreviews: false), to: AccountPreferences()))
    #expect(!CommunicationHistory.purgesDonations(from: AccountPreferences(), to: AccountPreferences(readReceipts: false)))
    let calls = Counter()
    await CommunicationHistory.deleteAll { calls.increment() }
    struct Refused: Error {}
    // A failure is logged, never thrown: sign-out and the setting go ahead.
    await CommunicationHistory.deleteAll { calls.increment(); throw Refused() }
    #expect(calls.value == 2)
}
#endif
