import XCTest

/// Stream E on the local lab (docs/development/notification-actions.md): a trusted peer's message banners while another
/// chat is open, and Reply from Notification Center, with the app in the background, sends an encrypted answer the peer
/// decrypts and echoes. Uses the app's primary storage, because notification actions are off in isolated UI-test stores,
/// so it runs only when explicitly selected on a disposable simulator with disposable lab accounts.
final class NotificationActionLabUITests: XCTestCase {
    @MainActor func testForegroundBannerAndBackgroundReply() throws {
        continueAfterFailure = false
        let (app, peer) = try launchLab()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let other = otherChat(peer)
        connect(app)
        app.returnToChats()
        trustPeer(app, peer: peer, other: other)

        // The peer waits 8 s before echoing: open the other chat meanwhile, so the echo is news somewhere else.
        let marker = "Banner check \(UUID().uuidString.prefix(6))"
        send(app, marker)
        app.navigationBars.buttons["BackButton"].tap()
        let otherRow = app.buttons["chat.\(other)"]
        XCTAssertTrue(otherRow.waitForExistence(timeout: 5)); otherRow.tap()
        XCTAssertTrue(app.navigationBars.buttons["BackButton"].waitForExistence(timeout: 5))
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 40), "the echo shows a banner while another chat is open")
        capture(XCUIScreen.main.screenshot(), "Foreground banner for another chat")
        XCTAssertTrue(banner.waitForNonExistence(timeout: 15), "the banner goes away on its own")
        backgroundReply(app, springboard: springboard, peer: peer, marker: marker)
    }

    /// While a background action's connection is online the server pushes nothing for what it delivers there, so the
    /// action presents those messages itself before it releases the lease, as the extension would. The host drives the
    /// setup, because the peer's echo timing cannot keep one message unread and land another on the suspended app from
    /// here: with the app signed in on the lab, a one-shot peer message banners in front of the chat list
    /// (`XMPP_ACTION_TARGET`), Home, then a second one-shot message (`XMPP_ACTION_EXPECT`) reaches the hibernated
    /// session. This step then uses Mark as Read on the first; the second must appear in Notification Center.
    @MainActor func testMarkAsReadPresentsWhatArrivedOnTheActionsConnection() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["XMPP_NOTIFICATION_ACTION_LAB"] == "1", let target = env["XMPP_ACTION_TARGET"], let expected = env["XMPP_ACTION_EXPECT"] else {
            throw XCTSkip("Host-driven lab step: requires XMPP_ACTION_TARGET and XMPP_ACTION_EXPECT set up as documented")
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.002))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.75)))
        let cell = { (text: String) in springboard.buttons.matching(NSPredicate(format: "identifier == 'ListCell' AND label CONTAINS %@", text)).firstMatch }
        XCTAssertTrue(cell(target).waitForExistence(timeout: 10))
        capture(XCUIScreen.main.screenshot(), "Before Mark as Read")
        XCTAssertFalse(cell(expected).exists, "nothing alerted for the second message yet: the app is not running and the lab has no push")
        XCTAssertTrue(revealActions(cell(target), springboard: springboard))
        springboard.buttons["Mark as Read"].tap()
        XCTAssertTrue(cell(expected).waitForExistence(timeout: 30), "the message that arrived on the action's connection alerts")
        capture(XCUIScreen.main.screenshot(), "Arrival presented by the action")
        XCTAssertTrue(cell(target).waitForNonExistence(timeout: 10), "the read message's notification is removed")
    }

    // MARK: Steps

    @MainActor private func launchLab() throws -> (XCUIApplication, String) {
        let env = ProcessInfo.processInfo.environment
        guard env["XMPP_NOTIFICATION_ACTION_LAB"] == "1", let user = env["HAUS_LAB_USERNAME"], let password = env["HAUS_LAB_PASSWORD"],
              let peer = env["XMPP_OMEMO_PEER"] else {
            throw XCTSkip("Requires a disposable simulator, lab accounts and an echo peer started with --echo --typing")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-lab-ui-test", "-request-notification-permission"]
        app.launchEnvironment = ["HAUS_LAB_USERNAME": user, "HAUS_LAB_PASSWORD": password]
        for key in ["HAUS_LAB_HOST", "HAUS_LAB_CA_DER"] { if let value = env[key] { app.launchEnvironment[key] = value } }
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        return (app, peer)
    }

    private func otherChat(_ peer: String) -> String {
        "notification-other@" + (peer.split(separator: "@").last.map(String.init) ?? "localhost")
    }

    /// Creates the other chat, then a trusted round trip with the peer: only a message from an accepted device gets
    /// Reply and Mark as Read. Ends in the peer's chat.
    @MainActor private func trustPeer(_ app: XCUIApplication, peer: String, other: String) {
        startChat(app, with: other)
        app.navigationBars.buttons["BackButton"].tap()
        startChat(app, with: peer)
        let first = "Trust check \(UUID().uuidString.prefix(6))"
        send(app, first)
        app.openEncryptionDetails()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "encryptionDevice."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        for _ in 0..<20 {
            let pending = rows.matching(NSPredicate(format: "label CONTAINS %@", "Review required")).firstMatch
            if !pending.exists { break }
            pending.tap()
            XCTAssertTrue(app.buttons["Accept without verifying"].waitForExistence(timeout: 5))
            app.buttons["Accept without verifying"].tap()
            XCTAssertTrue(app.navigationBars["Devices & Encryption"].waitForExistence(timeout: 5))
        }
        app.closeEncryptionDetails()
        let echoedFirst = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"),
                                                    object: app.textViews.containing(NSPredicate(format: "value == %@", first)))
        wait(for: [echoedFirst], timeout: 40)
    }

    @MainActor private func backgroundReply(_ app: XCUIApplication, springboard: XCUIApplication, peer: String, marker: String) {
        // Background, then Reply from Notification Center: the app handles it without coming to the front.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackgroundSuspended, timeout: 30) || app.state == .runningBackground)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.002))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.75)))
        let listed = springboard.buttons.matching(NSPredicate(format: "identifier == 'ListCell' AND label CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(listed.waitForExistence(timeout: 10))
        capture(XCUIScreen.main.screenshot(), "Notification Center")
        XCTAssertTrue(revealActions(listed, springboard: springboard), "the message category offers Reply")
        let reply = springboard.buttons["Reply"]
        XCTAssertTrue(springboard.buttons["Mark as Read"].exists)
        capture(XCUIScreen.main.screenshot(), "Notification actions")
        reply.tap()
        let field = springboard.textFields.firstMatch.exists ? springboard.textFields.firstMatch : springboard.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let answer = "Reply from notification \(UUID().uuidString.prefix(6))"
        field.typeText(answer)
        capture(XCUIScreen.main.screenshot(), "Reply typed")
        let sendButton = springboard.buttons["Send"]
        if sendButton.exists { sendButton.tap() } else { field.typeText("\n") }
        // The background action connects, marks the message read and sends; it has at most 20 s of network time.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 25))
        XCTAssertFalse(springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Couldn't send your reply")).firstMatch.exists)
        capture(XCUIScreen.main.screenshot(), "After the background reply")

        app.activate()
        let chat = app.buttons["chat.\(peer)"]
        for _ in 0..<4 where !chat.waitForExistence(timeout: 3) { app.returnToChats() }
        XCTAssertTrue(chat.waitForExistence(timeout: 10)); chat.tap()
        let sent = app.textViews.containing(NSPredicate(format: "value == %@", answer))
        XCTAssertTrue(sent.firstMatch.waitForExistence(timeout: 10), "the reply is in the chat")
        XCTAssertTrue(serverHeldLabel.evaluate(with: sent.firstMatch) || sent.firstMatch.label.contains("Sending, not yet confirmed"),
                      "sent on the background connection, not waiting: \(sent.firstMatch.label)")
        // The peer decrypted it: its echo comes back (live or from the archive on this reconnect).
        let echoed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: sent)
        wait(for: [echoed], timeout: 40)
        capture(app.screenshot(), "Reply and its echo")
    }

    /// A person long-presses; on the iOS 26.5 simulator a synthesized long press only shrinks the platter, so this
    /// uses the other system path to the same actions: a short left swipe, then View.
    @MainActor private func revealActions(_ notification: XCUIElement, springboard: XCUIApplication) -> Bool {
        notification.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: notification.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.5)))
        let view = springboard.buttons["View"]
        guard view.waitForExistence(timeout: 3) else {
            let attachment = XCTAttachment(string: springboard.debugDescription); attachment.lifetime = .keepAlways; add(attachment)
            return false
        }
        view.tap()
        return springboard.buttons["Reply"].waitForExistence(timeout: 3)
    }

    @MainActor private func startChat(_ app: XCUIApplication, with address: String) {
        let existing = app.buttons["chat.\(address)"]
        if existing.exists { existing.tap(); return }
        app.buttons["newConversation"].tap()
        app.textFields["newChatAddress"].tap()
        app.textFields["newChatAddress"].typeText(address)
        app.buttons["startChat"].tap()
        let input = app.textFields["messageComposer"].exists ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
    }

    @MainActor private func send(_ app: XCUIApplication, _ text: String) {
        let input = app.textFields["messageComposer"].exists ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        input.tap(); input.typeText(text)
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.textViews.containing(NSPredicate(format: "value == %@", text)).firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor private func connect(_ app: XCUIApplication) {
        app.buttons["Settings"].tap(); app.buttons["Connect to local lab"].tap()
        let consent = app.switches["labConsent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        consent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["Connect"].tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Connected")).firstMatch.waitForExistence(timeout: 25))
    }

    @MainActor private func capture(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
