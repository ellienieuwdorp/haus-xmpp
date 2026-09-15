import XCTest

extension XCUIApplication {
    /// Reuse this namespace across launches in one test; never share fixtures with the preview.
    func isolateMessageStorage() {
        for key in ["XMPP_LAB_HOST", "XMPP_LAB_CA_DER"] {
            if let value = ProcessInfo.processInfo.environment[key] { launchEnvironment[key] = value }
        }
        launchEnvironment["XMPP_UI_TEST_STORE"] = UUID().uuidString
    }

    /// The conversation header opens chat details; the encryption sheet is one row inside.
    func openEncryptionDetails() {
        buttons["chatDetails"].tap()
        let row = buttons["encryptionDetails"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
    }
}

extension XCUIApplication {
    /// The root is always Chats; close the Settings sheet or pop a conversation to get back to it.
    func returnToChats() {
        if navigationBars["Settings"].exists, buttons["Done"].exists { buttons["Done"].tap(); return }
        if buttons["Chats"].exists { buttons["Chats"].tap(); return }
        if buttons["BackButton"].exists { buttons["BackButton"].tap() }
    }
}
