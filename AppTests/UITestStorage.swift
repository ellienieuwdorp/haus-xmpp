import XCTest

extension XCUIApplication {
    /// Reuse this namespace across launches in one test; never share fixtures with the preview.
    func isolateMessageStorage() {
        for key in ["XMPP_LAB_HOST", "XMPP_LAB_CA_DER"] {
            if let value = ProcessInfo.processInfo.environment[key] { launchEnvironment[key] = value }
        }
        launchEnvironment["XMPP_UI_TEST_STORE"] = UUID().uuidString
    }
}
