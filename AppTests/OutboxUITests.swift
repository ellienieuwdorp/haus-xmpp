import XCTest

final class OutboxUITests: XCTestCase {
    @MainActor func testOfflineQueueSurvivesRelaunchAndDoesNotReplayUnconfirmed() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let user = env["XMPP_LAB_USERNAME"], let password = env["XMPP_LAB_PASSWORD"] else {
            throw XCTSkip("Opt-in local lab credentials required")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-lab-ui-test"]
        app.launchEnvironment = ["XMPP_LAB_USERNAME": user, "XMPP_LAB_PASSWORD": password]
        app.launch()
        func connect() {
            app.buttons["Settings"].tap()
            app.buttons["Connect to local lab"].tap()
            let consent = app.switches["labConsent"]
            XCTAssertTrue(consent.waitForExistence(timeout: 5))
            consent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            app.buttons["Connect"].tap()
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Connected to lab")).firstMatch.waitForExistence(timeout: 25))
        }
        connect()
        app.buttons["Disconnect"].tap()
        app.buttons["Chats"].tap()
        app.buttons["newConversation"].tap()
        app.textFields["name@server"].tap()
        app.textFields["name@server"].typeText(user + "@localhost")
        app.buttons["Create conversation"].tap()
        app.staticTexts[user + "@localhost"].firstMatch.tap()
        let input = app.textFields["messageComposer"].exists ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        input.tap()
        let marker = "Queued \(UUID().uuidString.prefix(6))"
        input.typeText(marker)
        app.buttons["sendMessage"].tap()
        let message = app.textViews.containing(NSPredicate(format: "value == %@", marker)).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("Waiting to send"))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[user + "@localhost"].firstMatch.waitForExistence(timeout: 10))
        app.staticTexts[user + "@localhost"].firstMatch.tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("Waiting to send"))
        app.navigationBars.buttons["BackButton"].tap()
        connect()
        let count = app.staticTexts["labReceivedCount"]
        expectation(for: NSPredicate(format: "label == %@", "Received lab messages: 1"), evaluatedWith: count)
        waitForExpectations(timeout: 10)
        app.buttons["Chats"].tap()
        app.staticTexts[user + "@localhost"].firstMatch.tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("Delivery unconfirmed"))
        app.terminate()
        app.launch()
        connect()
        // Reconnecting must not automatically replay an uncertain previous send.
        let duplicate = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "Received lab messages: 0"), object: app.staticTexts["labReceivedCount"])
        duplicate.isInverted = true
        wait(for: [duplicate], timeout: 3)
        app.buttons["Chats"].tap()
        app.staticTexts[user + "@localhost"].firstMatch.tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        message.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 1)).withOffset(CGVector(dx: 0, dy: 5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Retry message"].waitForExistence(timeout: 5))
        app.buttons["Retry message"].tap()
        XCTAssertTrue(app.buttons["Send again"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["The recipient may already have it. Sending again could create a duplicate."].exists)
        app.buttons["Send again"].tap()
        app.navigationBars.buttons["BackButton"].tap()
        app.buttons["Settings"].tap()
        expectation(for: NSPredicate(format: "label == %@", "Received lab messages: 1"), evaluatedWith: app.staticTexts["labReceivedCount"])
        waitForExpectations(timeout: 10)
        app.buttons["Disconnect"].tap()
    }
}
