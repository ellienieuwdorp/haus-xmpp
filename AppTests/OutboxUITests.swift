import XCTest

final class OutboxUITests: XCTestCase {
    @MainActor func testOfflineEncryptedQueueSurvivesRelaunchAndDoesNotReplayUnconfirmed() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let user = env["XMPP_LAB_USERNAME"], let password = env["XMPP_LAB_PASSWORD"], let peer = env["XMPP_OMEMO_PEER"] else {
            throw XCTSkip("Requires disposable local OMEMO peer")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-lab-ui-test"]
        app.launchEnvironment = ["XMPP_LAB_USERNAME": user, "XMPP_LAB_PASSWORD": password]
        app.isolateMessageStorage(); app.launch()
        func connect() {
            app.buttons["Settings"].tap(); app.buttons["Connect to local lab"].tap()
            let consent = app.switches["labConsent"]
            XCTAssertTrue(consent.waitForExistence(timeout: 5))
            consent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            app.buttons["Connect"].tap()
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Connected to lab")).firstMatch.waitForExistence(timeout: 25))
        }
        connect(); app.buttons["Disconnect"].tap(); app.buttons["Chats"].tap()
        app.buttons["newConversation"].tap()
        app.textFields["name@server"].tap(); app.textFields["name@server"].typeText(peer)
        app.buttons["Create conversation"].tap()
        let input = app.textFields["messageComposer"].exists ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        input.tap()
        let marker = "Queued encrypted \(UUID().uuidString.prefix(6))"
        input.typeText(marker); app.buttons["sendMessage"].tap()
        let messages = app.textViews.containing(NSPredicate(format: "value == %@", marker))
        XCTAssertTrue(messages.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(messages.firstMatch.label.contains("Waiting to send"))
        app.terminate(); app.launch()
        let chat = app.buttons["chat.\(peer)"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10)); chat.tap()
        XCTAssertTrue(messages.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(messages.firstMatch.label.contains("Waiting to send"))
        app.navigationBars.buttons["BackButton"].tap(); connect()
        app.buttons["Chats"].tap(); chat.tap()
        app.buttons["encryptionDetails"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "encryptionDevice."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20))
        for _ in 0..<20 {
            let pending = rows.matching(NSPredicate(format: "label CONTAINS %@", "Review required")).firstMatch
            if !pending.exists { break }
            if !pending.isHittable { app.swipeUp() }
            pending.tap()
            XCTAssertTrue(app.buttons["Accept without verifying"].waitForExistence(timeout: 5))
            app.buttons["Accept without verifying"].tap()
            XCTAssertTrue(app.navigationBars["Encryption"].waitForExistence(timeout: 5))
        }
        app.buttons["Done"].tap()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: messages)], timeout: 30)
        let sent = messages.matching(NSPredicate(format: "label CONTAINS %@", "Delivery unconfirmed")).firstMatch
        XCTAssertTrue(sent.exists)
        app.terminate(); app.launch(); connect()
        app.buttons["Chats"].tap(); chat.tap()
        XCTAssertEqual(messages.count, 2)
        let duplicate = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 2"), object: messages)
        duplicate.isInverted = true; wait(for: [duplicate], timeout: 3)
        sent.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Retry message"].waitForExistence(timeout: 5))
        app.buttons["Retry message"].tap()
        XCTAssertTrue(app.buttons["Send again"].waitForExistence(timeout: 5)); app.buttons["Send again"].tap()
        // The independent peer rejects replay of the exact ciphertext; no second echo bubble.
        let retriedDuplicate = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > 2"), object: messages)
        retriedDuplicate.isInverted = true; wait(for: [retriedDuplicate], timeout: 3)
        XCTAssertTrue(sent.exists)
        app.navigationBars.buttons["BackButton"].tap(); app.buttons["Settings"].tap(); app.buttons["Disconnect"].tap()
    }
}
