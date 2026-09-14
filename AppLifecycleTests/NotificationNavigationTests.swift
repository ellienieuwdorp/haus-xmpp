import XCTest
import UserNotifications
import MessagingCore
@testable import XMPPiOS

@MainActor final class NotificationNavigationTests: XCTestCase {
    func testColdLaunchKeepsLatestValidTapAndIgnoresDismissOrMalformedMetadata() async throws {
        let navigation = NotificationNavigation()
        let first = try XCTUnwrap(NotificationDestination(accountID: "synthetic", messageID: UUID().uuidString))
        let latest = try XCTUnwrap(NotificationDestination(accountID: "synthetic", messageID: UUID().uuidString))
        navigation.receive(userInfo: [NotificationDestination.userInfoKey: first.payload], actionIdentifier: UNNotificationDefaultActionIdentifier)
        navigation.receive(userInfo: [NotificationDestination.userInfoKey: latest.payload], actionIdentifier: UNNotificationDefaultActionIdentifier)
        navigation.receive(userInfo: [NotificationDestination.userInfoKey: first.payload], actionIdentifier: UNNotificationDismissActionIdentifier)
        navigation.receive(userInfo: [NotificationDestination.userInfoKey: ["url": "https://invalid.example"]], actionIdentifier: UNNotificationDefaultActionIdentifier)
        var iterator = navigation.taps.makeAsyncIterator()
        let buffered = await iterator.next()
        XCTAssertEqual(buffered, latest)
    }
}
