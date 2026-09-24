import XCTest
import UIKit
@testable import HausXMPP

@MainActor final class PushTokenCallbackTests: XCTestCase {
    func testUnsolicitedCallbacksKeepNewestIntentAndFenceOlderToken() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["XMPP_UI_TEST_STORE"], UUID(uuidString: fixture) != nil else {
            throw XCTSkip("Synthetic callbacks require the isolated lifecycle test app")
        }
        let stream = PushRegistration.unsolicitedTokens()
        let first = Data(repeating: 0x11, count: 32)
        let latest = Data(repeating: 0x22, count: 32)
        PushRegistration.shared.application(UIApplication.shared, didRegisterForRemoteNotificationsWithDeviceToken: first)
        PushRegistration.shared.application(UIApplication.shared, didRegisterForRemoteNotificationsWithDeviceToken: latest)
        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertEqual(received, latest)
        XCTAssertFalse(PushRegistration.isLatestToken(first))
        XCTAssertTrue(PushRegistration.isLatestToken(latest))
    }
}
