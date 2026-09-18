import XCTest

/// Unsend and edit on an own message, driven through the long-press overlay on sample data.
final class RevisionUITests: XCTestCase {
    @MainActor func testEditThenUnsendOwnMessage() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.isolateMessageStorage()
        app.launch()
        let alex = app.staticTexts["Alex"]
        XCTAssertTrue(alex.waitForExistence(timeout: 15))
        alex.tap()
        let original = "That sounds perfect. Around ten?"
        let outgoing = app.textViews.containing(NSPredicate(format: "value == %@", original)).matching(NSPredicate(format: "label BEGINSWITH %@", "You:")).firstMatch
        XCTAssertTrue(outgoing.waitForExistence(timeout: 10))
        let originalWidth = outgoing.frame.width

        // Edit: the composer takes the text, the send circle becomes a save tick, the bubble updates in place.
        outgoing.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(app.staticTexts["Editing message"].waitForExistence(timeout: 5))
        let composer = app.textFields["messageComposer"].exists ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, original)
        let save = app.buttons["sendMessage"]
        XCTAssertFalse(save.isEnabled, "an unchanged text has nothing to save")
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        composer.typeText(" Sharp.")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let edited = app.textViews.containing(NSPredicate(format: "value == %@", original + " Sharp.")).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 10))
        XCTAssertTrue(edited.label.contains("edited"))
        XCTAssertFalse(app.staticTexts["Editing message"].exists)
        XCTAssertFalse(app.textViews.containing(NSPredicate(format: "value == %@", original)).firstMatch.exists, "an edit never adds a bubble")
        capture(app, "Edited bubble")

        // Unsend: confirmation first, then a quiet placeholder with no reaction row and no text actions.
        edited.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        let unsend = app.buttons["Unsend"]
        XCTAssertTrue(unsend.waitForExistence(timeout: 5))
        unsend.tap()
        let confirm = app.sheets.buttons["Unsend"].exists ? app.sheets.buttons["Unsend"] : app.buttons["Unsend"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let placeholder = app.textViews.containing(NSPredicate(format: "value == %@", "You unsent a message")).firstMatch
        XCTAssertTrue(placeholder.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(placeholder.frame.width, max(originalWidth, 240) + 1)
        capture(app, "Unsent bubble")
        placeholder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Star message"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Edit"].exists)
        XCTAssertFalse(app.buttons["Copy"].exists)
        app.buttons["Dismiss"].firstMatch.tap()

        // The projection survives a relaunch and the chat list preview follows it.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Alex"].waitForExistence(timeout: 10))
        app.staticTexts["Alex"].tap()
        XCTAssertTrue(placeholder.waitForExistence(timeout: 10))
    }

    /// The lab echo peer corrects its echo of a "#edit" message and retracts its echo of a "#unsend"
    /// message, so the inbound half is exercised against real OMEMO traffic.
    @MainActor func testPeerEditsAndUnsendsApplyToTheOriginalBubble() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let user = env["XMPP_LAB_USERNAME"], let password = env["XMPP_LAB_PASSWORD"], let peer = env["XMPP_OMEMO_PEER"] else {
            throw XCTSkip("Requires the lab echo peer")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-lab-ui-test"]
        app.launchEnvironment = ["XMPP_LAB_USERNAME": user, "XMPP_LAB_PASSWORD": password]
        app.isolateMessageStorage()
        app.launch()
        app.buttons["Settings"].tap(); app.buttons["Connect to local lab"].tap()
        let consent = app.switches["labConsent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        consent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["Connect"].tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Connected")).firstMatch.waitForExistence(timeout: 25))
        app.returnToChats(); app.buttons["newConversation"].tap()
        app.textFields["newChatAddress"].tap(); app.textFields["newChatAddress"].typeText(peer)
        app.buttons["startChat"].tap()
        let composer = app.textFields["messageComposer"].exists ? app.textFields["messageComposer"] : app.textViews["messageComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        // As in ReactionUITests: a queued first message before reviewing the peer's devices.
        composer.tap(); composer.typeText("Hello \(UUID().uuidString.prefix(4))"); app.buttons["sendMessage"].tap()
        app.openEncryptionDetails()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "encryptionDevice."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        // The echo peer speaks OMEMO 2 only; same selection steps as ReactionUITests.
        let version = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "OMEMO · compatible")).firstMatch
        for _ in 0..<5 { if version.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(version.isHittable); version.tap()
        XCTAssertTrue(app.buttons["OMEMO 2"].waitForExistence(timeout: 5)); app.buttons["OMEMO 2"].tap()
        for _ in 0..<5 { if rows.firstMatch.isHittable { break }; app.swipeDown() }
        for _ in 0..<20 {
            let pending = rows.matching(NSPredicate(format: "label CONTAINS %@", "Review required")).firstMatch
            if !pending.exists { break }
            for _ in 0..<5 { if pending.isHittable { break }; app.swipeUp() }
            pending.tap()
            XCTAssertTrue(app.buttons["Accept without verifying"].waitForExistence(timeout: 10))
            app.buttons["Accept without verifying"].tap()
            XCTAssertTrue(app.navigationBars["Devices & Encryption"].waitForExistence(timeout: 5))
        }
        app.closeEncryptionDetails()

        // Peer edit: the echo arrives, then its correction rewrites that same bubble.
        let marker = "Draft \(UUID().uuidString.prefix(4))"
        composer.tap(); composer.typeText(marker + " #edit"); app.buttons["sendMessage"].tap()
        let echo = app.textViews.containing(NSPredicate(format: "value == %@", marker + " #edit")).matching(NSPredicate(format: "NOT (label BEGINSWITH %@)", "You:")).firstMatch
        XCTAssertTrue(echo.waitForExistence(timeout: 30))
        let corrected = app.textViews.containing(NSPredicate(format: "value == %@", marker + " (edited by peer)")).firstMatch
        XCTAssertTrue(corrected.waitForExistence(timeout: 30))
        XCTAssertTrue(corrected.label.contains("edited"))
        XCTAssertFalse(echo.exists, "the correction replaced the echo instead of adding a bubble")
        XCTAssertEqual(app.textViews.matching(NSPredicate(format: "label CONTAINS %@", marker)).count, 2, "our message and the peer's edited echo")
        capture(app, "Peer edit applied in place")

        // Peer unsend: the echo becomes the placeholder.
        let second = "Gone \(UUID().uuidString.prefix(4))"
        composer.tap(); composer.typeText(second + " #unsend"); app.buttons["sendMessage"].tap()
        let unsentEcho = app.textViews.containing(NSPredicate(format: "value == %@", "Message unsent")).firstMatch
        XCTAssertTrue(unsentEcho.waitForExistence(timeout: 40))
        XCTAssertFalse(app.textViews.containing(NSPredicate(format: "value == %@", second + " #unsend")).matching(NSPredicate(format: "NOT (label BEGINSWITH %@)", "You:")).firstMatch.exists)
        capture(app, "Peer unsend applied in place")

        // Our own edit and unsend round-trip through the outbox and reach server acceptance.
        let mine = app.textViews.containing(NSPredicate(format: "value == %@", second + " #unsend")).matching(NSPredicate(format: "label BEGINSWITH %@", "You:")).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 5))
        mine.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5)); app.buttons["Edit"].tap()
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap(); composer.typeText(" more"); app.buttons["sendMessage"].tap()
        let edited = app.textViews.containing(NSPredicate(format: "value == %@", second + " #unsend more")).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 10))
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "edited"), object: edited)], timeout: 10)
        edited.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Unsend"].waitForExistence(timeout: 5)); app.buttons["Unsend"].tap()
        let confirm = app.sheets.buttons["Unsend"].exists ? app.sheets.buttons["Unsend"] : app.buttons["Unsend"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.textViews.containing(NSPredicate(format: "value == %@", "You unsent a message")).firstMatch.waitForExistence(timeout: 10))
        capture(app, "Own edit and unsend in the lab")
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
