import XCTest

/// The disposable lab fixture exported to the test runner as `HAUS_LAB_*` and `XMPP_*` (see infra/local/README.md).
struct LabFixture {
    let username: String
    let password: String
    private let environment: [String: String]

    /// Skips the test unless the lab account and every key in `required` are exported.
    init(requiring required: [String] = ["XMPP_OMEMO_PEER"], orSkip reason: String) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let username = environment["HAUS_LAB_USERNAME"], let password = environment["HAUS_LAB_PASSWORD"],
              required.allSatisfy({ environment[$0] != nil }) else { throw XCTSkip(reason) }
        self.username = username
        self.password = password
        self.environment = environment
    }

    subscript(key: String) -> String? { environment[key] }
    /// The echo peer's address; present whenever the default `required` passed.
    var peer: String { environment["XMPP_OMEMO_PEER"] ?? "" }

    /// The app on its own isolated store, signed out, with the lab account filled in for "Connect to local lab".
    @MainActor func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-lab-ui-test"] + arguments
        app.launchEnvironment = ["HAUS_LAB_USERNAME": username, "HAUS_LAB_PASSWORD": password]
        app.isolateMessageStorage()
        app.launch()
        return app
    }
}

extension XCUIApplication {
    /// Signs in to the lab from Settings (opening it if needed) and leaves the sheet open once it reads "Connected".
    func connectToLab(timeout: TimeInterval = 30) {
        if !navigationBars["Settings"].exists { buttons["Settings"].tap() }
        buttons["Connect to local lab"].tap()
        let consent = switches["labConsent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        consent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        // A lab reached through a local proxy (for example `infra/local/slow_link.py`, a slow link) on another port.
        if let port = ProcessInfo.processInfo.environment["HAUS_LAB_PORT"] {
            buttons["Advanced"].tap()
            let host = textFields["serverHost"]
            XCTAssertTrue(host.waitForExistence(timeout: 5))
            host.tap()
            host.typeText("localhost")
            buttons["Direct TLS"].tap()
            textFields["serverPort"].tap()
            textFields["serverPort"].typeText(port)
        }
        buttons["Connect"].tap()
        // The system asks once per install. Stop at whichever comes first rather than waiting out a prompt that
        // already came on an earlier run.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        let connected = staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Connected")).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !allow.exists, !connected.exists { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2)) }
        if allow.exists { allow.tap() }
        XCTAssertTrue(connected.waitForExistence(timeout: max(1, deadline.timeIntervalSinceNow)), "the lab account connects")
    }

    /// The composer; a multiline SwiftUI text field is exposed as a text view on some runtimes.
    var messageComposer: XCUIElement {
        let field = textFields["messageComposer"]
        return field.exists ? field : textViews["messageComposer"]
    }

    /// Starts a direct chat from the Chats root and returns its composer.
    @discardableResult func startChat(with address: String) -> XCUIElement {
        returnToChats()
        buttons["newConversation"].tap()
        textFields["newChatAddress"].tap()
        textFields["newChatAddress"].typeText(address)
        buttons["startChat"].tap()
        // With the address field focused, the first tap on iOS 27 can only end editing.
        if !buttons["chatDetails"].waitForExistence(timeout: 4), buttons["startChat"].exists { buttons["startChat"].tap() }
        let composer = messageComposer
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        return composer
    }

    /// Switches the open Devices & Encryption page to OMEMO 2, the only profile a modern echo peer speaks.
    func selectModernOMEMO() {
        let version = buttons.matching(NSPredicate(format: "label CONTAINS %@", "OMEMO · compatible")).firstMatch
        for _ in 0..<5 { if version.isHittable { break }; swipeUp() }
        XCTAssertTrue(version.isHittable)
        version.tap()
        XCTAssertTrue(buttons["OMEMO 2"].waitForExistence(timeout: 5))
        buttons["OMEMO 2"].tap()
        let rows = encryptionDeviceRows(group: false)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        for _ in 0..<5 { if rows.firstMatch.isHittable { break }; swipeDown() }
    }

    /// Accepts every device awaiting review on the open encryption page, one fingerprint at a time through the same
    /// review a person uses. Accepted is not verified. `onReview` runs with each fingerprint on screen.
    func acceptPendingDevices(group: Bool = false, onReview: () -> Void = {}) {
        let page = navigationBars[group ? "Group details" : "Devices & Encryption"]
        let rows = encryptionDeviceRows(group: group)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20))
        let pending = rows.matching(NSPredicate(format: "label CONTAINS %@", "Review required")).firstMatch
        let accept = buttons["Accept without verifying"]
        var quietScreens = 0
        for _ in 0..<40 {
            guard pending.exists else {
                // A group's member list can run past the screen: look further down twice before calling it done.
                guard group, quietScreens < 2 else { break }
                quietScreens += 1
                swipeUp()
                continue
            }
            quietScreens = 0
            for _ in 0..<5 { if pending.isHittable { break }; swipeUp() }
            // A row sliding under the navigation bar still reports hittable, but the bar takes the tap.
            if pending.frame.midY < page.frame.maxY + 8 { swipeDown() }
            pending.tap()
            // The list reloads after a version change or an acceptance; a tap that lands mid-reload is retried once.
            if !accept.waitForExistence(timeout: 5) { pending.tap() }
            XCTAssertTrue(accept.waitForExistence(timeout: 10))
            onReview()
            accept.tap()
            XCTAssertTrue(page.waitForExistence(timeout: 15))
        }
        XCTAssertFalse(pending.exists, "every device was reviewed")
    }

    private func encryptionDeviceRows(group: Bool) -> XCUIElementQuery {
        buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", group ? "groupDevice." : "encryptionDevice."))
    }
}
