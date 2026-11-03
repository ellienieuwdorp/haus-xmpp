import XCTest

extension XCUIApplication {
    // Reuse this namespace across launches in one test; never share fixtures with the preview.
    func isolateMessageStorage() {
        for key in ["HAUS_LAB_HOST", "HAUS_LAB_CA_DER"] {
            if let value = ProcessInfo.processInfo.environment[key] { launchEnvironment[key] = value }
        }
        launchEnvironment["XMPP_UI_TEST_STORE"] = UUID().uuidString
    }

    func openEncryptionDetails() {
        buttons["chatDetails"].tap()
        let row = buttons["encryptionDetails"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        // A device row tapped mid-transition is swallowed, so wait for the push to land.
        let page = navigationBars.matching(NSPredicate(format: "identifier IN %@", ["Devices & Encryption", "Group details"])).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
    }

    func closeEncryptionDetails() {
        for _ in 0..<2 {
            let back = navigationBars.buttons["BackButton"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
        }
    }
}

nonisolated(unsafe) let serverHeldLabel = NSPredicate(format: "label CONTAINS 'Sent' OR label CONTAINS 'Delivered' OR label CONTAINS 'Read'")

extension XCUIApplication {
    // Waiting for one exact state (running or suspended) runs out its whole timeout whenever the app lands in the other.
    func waitForBackground(timeout: TimeInterval = 10) -> Bool {
        let background = NSPredicate { object, _ in
            [.runningBackground, .runningBackgroundSuspended].contains((object as? XCUIApplication)?.state)
        }
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: background, object: self)], timeout: timeout) == .completed
    }

    func returnToChats() {
        if navigationBars["Settings"].exists, buttons["Done"].exists { buttons["Done"].tap(); return }
        if buttons["Chats"].exists { buttons["Chats"].tap(); return }
        if buttons["BackButton"].exists { buttons["BackButton"].tap() }
    }
}
