import XCTest
import UserNotifications
import MessagingCore
@testable import HausXMPP

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

    // A chat is pushed; its details, and the pages under them, open in a sheet over it with that page already pushed.
    func testARouteToAChatsPageOpensItsDetailsWithThatPageOnTop() throws {
        XCTAssertNil(ChatDetailsRequest(.chat("alex@example.org")))
        let details = try XCTUnwrap(ChatDetailsRequest(.details("alex@example.org")))
        XCTAssertEqual(details.chatID, "alex@example.org")
        XCTAssertEqual(details.path, [])
        for page in [ChatRoute.encryption("alex@example.org"), .groupDetails("trail@rooms.example.org")] {
            let request = try XCTUnwrap(ChatDetailsRequest(page))
            XCTAssertEqual(request.path, [page])
        }
        XCTAssertEqual(ChatDetailsRequest(.groupDetails("trail@rooms.example.org"))?.chatID, "trail@rooms.example.org")
    }
}
