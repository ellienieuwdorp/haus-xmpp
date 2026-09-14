import XCTest

extension XCUIApplication {
    /// Reuse this namespace across launches in one test; never share fixtures with the preview.
    func isolateMessageStorage() {
        launchEnvironment["XMPP_UI_TEST_STORE"] = UUID().uuidString
    }
}
