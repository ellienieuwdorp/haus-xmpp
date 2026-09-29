import XCTest

final class LabConnectionUITests: XCTestCase {
    @MainActor func testLiveTLSLoginDoesNotSendWithoutApprovedDevices() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let user = env["HAUS_LAB_USERNAME"], let password = env["HAUS_LAB_PASSWORD"] else {
            throw XCTSkip("Opt-in live lab test: provide disposable HAUS_LAB_USERNAME/PASSWORD and trust the lab CA in the simulator.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-lab-ui-test"]
        app.launchEnvironment = ["HAUS_LAB_USERNAME": user, "HAUS_LAB_PASSWORD": password]
        app.isolateMessageStorage()
        app.launch()
        app.buttons["Settings"].tap()
        app.buttons["Connect to local lab"].tap()
        XCTAssertTrue(app.switches["labConsent"].waitForExistence(timeout: 5))
        app.switches["labConsent"].coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Connect"].isEnabled)
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Connected")).firstMatch.waitForExistence(timeout: 25))
        app.returnToChats()
        app.buttons["New conversation"].tap()
        let recipient = app.textFields["newChatAddress"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 5))
        recipient.tap()
        recipient.typeText(user + "@localhost")
        app.buttons["startChat"].tap()
        let field = app.textFields["messageComposer"]
        let input = field.exists ? field : app.textViews["messageComposer"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Live simulator TLS smoke")
        app.buttons["sendMessage"].tap()
        // The bubble is a local echo; its state is what proves nothing left without approved devices.
        let bubble = app.textViews.containing(NSPredicate(format: "value == %@", "Live simulator TLS smoke")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        XCTAssertTrue(bubble.label.contains("Waiting to send"))
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["New conversation"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Offline")).firstMatch.waitForExistence(timeout: 5))
    }
}
