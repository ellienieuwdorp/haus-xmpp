import XCTest

extension XCUIApplication {
    /// Reuse this namespace across launches in one test; never share fixtures with the preview.
    func isolateMessageStorage() {
        for key in ["XMPP_LAB_HOST", "XMPP_LAB_CA_DER"] {
            if let value = ProcessInfo.processInfo.environment[key] { launchEnvironment[key] = value }
        }
        launchEnvironment["XMPP_UI_TEST_STORE"] = UUID().uuidString
    }

    /// The conversation header pushes chat details; the encryption page is one row further.
    func openEncryptionDetails() {
        buttons["chatDetails"].tap()
        let row = buttons["encryptionDetails"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
    }

    /// Pop the encryption page and chat details to land back in the conversation.
    func closeEncryptionDetails() {
        for _ in 0..<2 {
            let back = navigationBars.buttons["BackButton"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
        }
    }

    /// The reaction row is inline in the bubble menu; older builds kept it behind a "React" submenu.
    func openReactionRow() {
        let react = buttons["React"]
        if react.waitForExistence(timeout: 2) { react.tap() }
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
