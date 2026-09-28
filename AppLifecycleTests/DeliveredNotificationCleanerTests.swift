import XCTest
import UserNotifications
import MessagingCore
@testable import HausXMPP

/// Which delivered requests go when messages are read: their own identifiers, and older requests that name them,
/// never another account's or another chat's.
final class DeliveredNotificationCleanerTests: XCTestCase {
    private let account = "synthetic@localhost"

    private func request(_ identifier: String, thread: String = "", destination: NotificationDestination?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.threadIdentifier = thread
        if let destination { content.userInfo = [NotificationDestination.userInfoKey: destination.payload] }
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    func testReadMessagesRemoveTheirOwnAndNamingRequestsOnly() throws {
        let read = UUID().uuidString, unread = UUID().uuidString
        let named = DeliveredNotificationCleaner.Delivered(request("gateway-1", destination: NotificationDestination(accountID: account, messageID: read)), accountID: account)
        let stillUnread = DeliveredNotificationCleaner.Delivered(request("gateway-2", destination: NotificationDestination(accountID: account, messageID: unread)), accountID: account)
        // The same message id under another account's scope is not this account's notification.
        let otherAccount = DeliveredNotificationCleaner.Delivered(request("gateway-3", destination: NotificationDestination(accountID: "other@localhost", messageID: read)), accountID: account)
        let generic = DeliveredNotificationCleaner.Delivered(request("fallback", destination: nil), accountID: account)
        XCTAssertEqual(named.messageID, read)
        XCTAssertNil(otherAccount.messageID)
        XCTAssertNil(generic.messageID)
        let identifiers = DeliveredNotificationCleaner.identifiers(accountID: account, readMessageIDs: [read], delivered: [named, stillUnread, otherAccount, generic])
        XCTAssertEqual(Set(identifiers), ["gateway-1", NotificationIdentity.message(accountID: account, messageID: read)])
    }

    func testAReactionsOwnTargetNeverCountsAsAReadMessage() throws {
        let mine = UUID().uuidString
        // A reaction notification names this account's reacted-to message for the tap; reading does not make it stale here.
        let reaction = DeliveredNotificationCleaner.Delivered(
            request("r-1", destination: NotificationDestination(accountID: account, messageID: mine, kind: .reaction)), accountID: account)
        XCTAssertNil(reaction.messageID)
        XCTAssertEqual(DeliveredNotificationCleaner.identifiers(accountID: account, readMessageIDs: [mine], delivered: [reaction]),
                       [NotificationIdentity.message(accountID: account, messageID: mine)])
    }

    func testAReadPlaceholderIsRemovedByItsReference() throws {
        let placeholder = "unreadable-" + String(repeating: "ab", count: 32)
        func referenced(_ identifier: String, _ reference: NotificationReference?) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            if let reference { content.userInfo = [NotificationReference.userInfoKey: reference.payload] }
            return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        }
        let mine = DeliveredNotificationCleaner.Delivered(referenced("p-1", .placeholder(accountID: account, messageID: placeholder)), accountID: account)
        let foreign = DeliveredNotificationCleaner.Delivered(referenced("p-2", .placeholder(accountID: "other@localhost", messageID: placeholder)), accountID: account)
        let retained = DeliveredNotificationCleaner.Delivered(referenced("p-3", .retained(accountID: account)), accountID: account)
        let reaction = DeliveredNotificationCleaner.Delivered(referenced("p-4", .reaction(accountID: account, targetMessageID: UUID().uuidString)), accountID: account)
        XCTAssertEqual(mine.messageID, placeholder)
        XCTAssertNil(foreign.messageID)
        XCTAssertNil(retained.messageID)
        XCTAssertNil(reaction.messageID, "a reaction's target is our own message; reading says nothing about it")
        XCTAssertEqual(Set(DeliveredNotificationCleaner.identifiers(accountID: account, readMessageIDs: [placeholder], delivered: [mine, foreign, retained, reaction])),
                       ["p-1", NotificationIdentity.message(accountID: account, messageID: placeholder)])
    }

    func testOpeningAChatRemovesOnlyItsThread() {
        let thread = NotificationIdentity.thread(accountID: account, chatID: "peer@localhost")
        let delivered = [
            DeliveredNotificationCleaner.Delivered(identifier: "a", threadIdentifier: thread, messageID: nil),
            DeliveredNotificationCleaner.Delivered(identifier: "b", threadIdentifier: NotificationIdentity.thread(accountID: account, chatID: "else@localhost"), messageID: nil),
            DeliveredNotificationCleaner.Delivered(identifier: "c", threadIdentifier: NotificationIdentity.thread(accountID: "other@localhost", chatID: "peer@localhost"), messageID: nil),
        ]
        XCTAssertEqual(DeliveredNotificationCleaner.threadIdentifiers(accountID: account, chatID: "peer@localhost", delivered: delivered), ["a"])
    }
}
