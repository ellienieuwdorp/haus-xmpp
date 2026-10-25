import XCTest

/// The Share extension on the local lab, from other apps' real share sheets: a link from Safari, photos and a video from
/// Photos, and a file from Files, to one chat and to several. It uses the app's primary storage, because the extension
/// opens the App Group store, so it runs only when explicitly selected on a disposable simulator with disposable lab
/// accounts, two echo peers and the lab CA installed as a trust anchor (`simctl keychain add-root-cert`): the
/// extension has no test CA of its own. The simulator's library holds the photos and the video to share.
final class ShareExtensionLabUITests: XCTestCase {
    /// The app as the lab runs it, and the two peers' addresses. Skips unless the lab is exported.
    @MainActor private func lab() throws -> (XCUIApplication, [String]) {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["XMPP_SHARE_LAB"] == "1", let user = env["HAUS_LAB_USERNAME"], let password = env["HAUS_LAB_PASSWORD"],
              let peer = env["XMPP_OMEMO_PEER"], let second = env["XMPP_SECOND_PEER"] else {
            throw XCTSkip("Requires XMPP_SHARE_LAB=1, a disposable simulator, lab accounts and two echo peers")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-lab-ui-test"]
        app.launchEnvironment = ["HAUS_LAB_USERNAME": user, "HAUS_LAB_PASSWORD": password]
        for key in ["HAUS_LAB_HOST", "HAUS_LAB_CA_DER"] { if let value = env[key] { app.launchEnvironment[key] = value } }
        return (app, [peer, second])
    }

    /// Signs in and makes a trusted round trip with both peers, so their chats exist with accepted devices; each send
    /// also donates the chat for share-sheet suggestions.
    @MainActor func test1PrepareTrustedChats() throws {
        let (app, peers) = try lab()
        app.launch()
        app.connectToLab()
        app.returnToChats()
        for peer in peers {
            app.startChat(with: peer)
            let first = "Share setup \(UUID().uuidString.prefix(6))"
            send(first, in: app)
            app.openEncryptionDetails()
            app.acceptPendingDevices()
            app.closeEncryptionDetails()
            wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"),
                                                 object: app.textViews.containing(NSPredicate(format: "value == %@", first)))], timeout: 40)
            app.navigationBars.buttons["BackButton"].tap()
        }
        capture(XCUIScreen.main, "Chats before sharing")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.waitForBackground())
    }

    /// A link from Safari to the first peer, sent from the extension while the app is in the background.
    @MainActor func test2ShareLinkFromSafari() throws {
        let (_, peers) = try lab()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        safari.open(URL(string: "https://example.org/haus-share-test")!)
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20))
        // The page loads behind the bars; the share sheet only needs its address.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        openShareSheet(in: safari)
        let sheet = chooseHaus(in: safari)
        capture(XCUIScreen.main, "Safari share: picker")
        sheet.chat(peers[0]).tap()
        sheet.next.tap()
        XCTAssertTrue(sheet.text.waitForExistence(timeout: 5))
        XCTAssertTrue((sheet.text.value as? String)?.contains("example.org/haus-share-test") == true, "the link is the message")
        capture(XCUIScreen.main, "Safari share: review")
        sheet.send.tap()
        sheet.waitForResult(peers[0], "Sent")
        capture(XCUIScreen.main, "Safari share: sent")
        sheet.done.tap()
    }

    /// Two photos (a HEIC and a JPEG) and a video from Photos, with a caption, to both peers at once: the files are
    /// prepared while the chats are picked, then each chat gets three files and the caption as its own message.
    @MainActor func test3SharePhotosAndVideoToTwoChats() throws {
        let (_, peers) = try lab()
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.terminate()
        photos.launch()
        let welcome = photos.buttons["Continue"]
        if welcome.waitForExistence(timeout: 4) { welcome.tap() }
        let select = photos.buttons["Select"]
        XCTAssertTrue(select.waitForExistence(timeout: 10))
        select.tap()
        // The library's newest three: the synthetic HEIC, JPEG and video the simulator was given.
        let tiles = photos.images.matching(identifier: "PXGGridLayout-Info").allElementsBoundByIndex.map(\.frame)
            .filter { $0.width > 40 }.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        XCTAssertGreaterThanOrEqual(tiles.count, 3)
        let origin = photos.coordinate(withNormalizedOffset: .zero)
        for tile in tiles.suffix(3) { origin.withOffset(CGVector(dx: tile.midX, dy: tile.midY)).tap() }
        capture(XCUIScreen.main, "Photos: three selected")
        openShareSheet(in: photos)
        let sheet = chooseHaus(in: photos)
        for peer in peers { sheet.chat(peer).tap() }
        capture(XCUIScreen.main, "Photos share: two chats picked")
        sheet.next.tap()
        XCTAssertTrue(sheet.text.waitForExistence(timeout: 5))
        sheet.text.tap()
        sheet.text.typeText("Three from the lab")
        capture(XCUIScreen.main, "Photos share: review with caption")
        let send = sheet.send
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true AND label == 'Send'"), object: send)], timeout: 60)
        send.tap()
        for peer in peers { sheet.waitForResult(peer, "Sent", timeout: 60) }
        capture(XCUIScreen.main, "Photos share: sent to both")
        sheet.done.tap()
    }

    /// A PDF from the Files app (On My iPhone, where the run put a synthetic one) to the second peer: shared by
    /// reference, read through a file coordinator and sent as it is.
    @MainActor func test4ShareFileFromFiles() throws {
        let (_, peers) = try lab()
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.terminate()
        files.launch()
        let browse = files.buttons["Browse"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        browse.tap()
        let onDevice = files.descendants(matching: .any).matching(NSPredicate(format: "label == 'On My iPhone'")).firstMatch
        if !onDevice.waitForExistence(timeout: 5) { browse.tap() }
        XCTAssertTrue(onDevice.waitForExistence(timeout: 5))
        onDevice.tap()
        let document = files.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Synthetic report'")).firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 10))
        document.press(forDuration: 1.2)
        let share = files.buttons["Share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        capture(XCUIScreen.main, "Files: share sheet")
        let sheet = chooseHaus(in: files)
        sheet.chat(peers[1]).tap()
        sheet.next.tap()
        let send = sheet.send
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true AND label == 'Send'"), object: send)], timeout: 30)
        capture(XCUIScreen.main, "Files share: review")
        send.tap()
        sheet.waitForResult(peers[1], "Sent", timeout: 60)
        capture(XCUIScreen.main, "Files share: sent")
        sheet.done.tap()
    }

    /// With the extension only queueing (`-haus-share-queue-only`, as when the lease is busy), a shared link waits in
    /// the outbox, the sheet says so, and the app sends it when it next comes to the front.
    @MainActor func test5QueuedShareSendsWhenTheAppOpens() throws {
        let (app, peers) = try lab()
        app.launchArguments.append("-haus-share-queue-only")
        app.launch()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.waitForBackground())
        let marker = "https://example.org/queued-\(UUID().uuidString.prefix(6))"
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        safari.open(URL(string: marker)!)
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        openShareSheet(in: safari)
        let sheet = chooseHaus(in: safari)
        sheet.chat(peers[1]).tap()
        sheet.next.tap()
        XCTAssertTrue(sheet.send.waitForExistence(timeout: 5))
        sheet.send.tap()
        sheet.waitForResult(peers[1], "Queued", timeout: 20)
        capture(XCUIScreen.main, "Queued share")
        sheet.done.tap()
        // The app in front: its connection drains the outbox, and the peer's echo proves it decrypted the link.
        app.terminate()
        app.launchArguments.removeAll { $0 == "-haus-share-queue-only" }
        app.launch()
        let chat = app.buttons["chat.\(peers[1])"]
        for _ in 0..<4 where !chat.waitForExistence(timeout: 3) { app.returnToChats() }
        chat.tap()
        let bubbles = app.textViews.containing(NSPredicate(format: "value CONTAINS %@", marker))
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: bubbles)], timeout: 40)
        capture(XCUIScreen.main, "Queued share sent by the app")
        app.navigationBars.buttons["BackButton"].tap()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.waitForBackground())
    }

    /// After sends to the first peer (each donated), the share sheet suggests that chat; picking the suggestion opens the
    /// extension on that chat's review card, with the picker one step back.
    @MainActor func test6SuggestedChatIsPreselected() throws {
        let (_, peers) = try lab()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        safari.open(URL(string: "https://example.org/suggested")!)
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        openShareSheet(in: safari)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        capture(XCUIScreen.main, "Share sheet with suggestions")
        let name = String(peers[0].prefix { $0 != "@" })
        let suggestion = safari.collectionViews.cells.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        guard suggestion.waitForExistence(timeout: 5) else {
            throw XCTSkip("The simulator's share sheet showed no conversation suggestion for \(name)")
        }
        suggestion.tap()
        let sheet = ShareSheet(host: safari)
        XCTAssertTrue(sheet.send.waitForExistence(timeout: 15), "the suggestion opens the review card")
        XCTAssertTrue(safari.navigationBars[name].exists || safari.staticTexts[name].exists, "for the suggested chat")
        capture(XCUIScreen.main, "Suggested chat preselected")
        sheet.send.tap()
        sheet.waitForResult(peers[0], "Sent")
        sheet.done.tap()
    }

    /// The picker and the review card as VoiceOver and touch see them, in whatever appearance and text size the
    /// simulator is set to; nothing is sent. Run it again after `simctl ui <udid> appearance dark` and
    /// `content_size accessibility-extra-large` for the review screenshots.
    @MainActor func test7PickerAndReviewAccessibility() throws {
        let (_, peers) = try lab()
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.terminate()
        photos.launch()
        let select = photos.buttons["Select"]
        XCTAssertTrue(select.waitForExistence(timeout: 10))
        select.tap()
        let tiles = photos.images.matching(identifier: "PXGGridLayout-Info").allElementsBoundByIndex.map(\.frame)
            .filter { $0.width > 40 }.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        let origin = photos.coordinate(withNormalizedOffset: .zero)
        for tile in tiles.suffix(2) { origin.withOffset(CGVector(dx: tile.midX, dy: tile.midY)).tap() }
        openShareSheet(in: photos)
        let sheet = chooseHaus(in: photos)
        let row = sheet.chat(peers[0])
        XCTAssertEqual(row.label, String(peers[0].prefix { $0 != "@" }) + ", encrypted", "VoiceOver reads the name and the stored state")
        XCTAssertGreaterThanOrEqual(row.frame.height, 44)
        capture(XCUIScreen.main, "Picker")
        row.tap()
        XCTAssertTrue(row.isSelected, "the row reports its selection")
        XCTAssertEqual(sheet.next.label, "Next")
        XCTAssertGreaterThanOrEqual(min(sheet.next.frame.width, sheet.next.frame.height), 44)
        capture(XCUIScreen.main, "Picker with a chat chosen")
        sheet.next.tap()
        XCTAssertTrue(sheet.send.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(min(sheet.send.frame.width, sheet.send.frame.height), 44)
        let remove = photos.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove '")).firstMatch
        XCTAssertTrue(remove.exists)
        XCTAssertGreaterThanOrEqual(min(remove.frame.width, remove.frame.height), 44)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Send'"), object: sheet.send)], timeout: 30)
        capture(XCUIScreen.main, "Review")
        photos.navigationBars.buttons.firstMatch.tap()
        let cancel = photos.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
    }

    /// The suggestions switch under Privacy: on by default, off deletes the donations (and stays off), on again.
    @MainActor func test8SuggestionsSwitch() throws {
        let (app, _) = try lab()
        app.launch()
        app.buttons["Settings"].tap()
        let toggle = app.switches["shareSuggestions"]
        for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1", "on by default")
        XCTAssertTrue(toggle.label.contains("Suggest chats in Share Sheet"))
        capture(XCUIScreen.main, "Settings: suggestions on")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: toggle)], timeout: 10)
        capture(XCUIScreen.main, "Settings: suggestions off")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)], timeout: 10)
        app.returnToChats()
        XCUIDevice.shared.press(.home)
    }

    // MARK: Steps

    @MainActor private func send(_ text: String, in app: XCUIApplication) {
        let input = app.messageComposer
        input.tap()
        input.typeText(text)
        app.buttons["sendMessage"].tap()
    }

    /// Safari's share button sits in its toolbar, or behind the page menu ("…") in the compact layout.
    @MainActor private func openShareSheet(in host: XCUIApplication) {
        let share = host.buttons.matching(NSPredicate(format: "label == 'Share' OR identifier == 'ShareButton'")).firstMatch
        if share.waitForExistence(timeout: 3), share.isHittable { share.tap(); return }
        let menu = host.buttons.matching(NSPredicate(format: "label IN {'More', 'Page Menu', 'Tab Menu'} OR identifier IN {'MoreButton', 'PageMenuButton'}")).firstMatch
        if menu.waitForExistence(timeout: 3) { menu.tap() }
        else { host.coordinate(withNormalizedOffset: CGVector(dx: 0.855, dy: 0.933)).tap() }
        if !share.waitForExistence(timeout: 5) { print(host.debugDescription) }
        XCTAssertTrue(share.waitForExistence(timeout: 1), "Safari offers Share")
        share.tap()
    }

    /// Haus Dev in the share sheet's app row, scrolling the row if it is further along.
    @MainActor private func chooseHaus(in host: XCUIApplication) -> ShareSheet {
        let haus = host.collectionViews.cells.matching(NSPredicate(format: "label == 'Haus Dev'")).firstMatch
        let row = host.collectionViews.firstMatch
        for _ in 0..<4 where !(haus.exists && haus.isHittable) {
            if haus.exists { break }
            row.swipeLeft()
        }
        XCTAssertTrue(haus.waitForExistence(timeout: 10), "the share sheet offers Haus Dev")
        haus.tap()
        let sheet = ShareSheet(host: host)
        XCTAssertTrue(sheet.anyChat.waitForExistence(timeout: 15), "the extension lists chats")
        return sheet
    }

    @MainActor struct ShareSheet {
        let host: XCUIApplication
        func chat(_ id: String) -> XCUIElement { host.descendants(matching: .any)["shareChat.\(id)"] }
        var anyChat: XCUIElement { host.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'shareChat.'")).firstMatch }
        var next: XCUIElement { host.buttons["shareNext"] }
        var send: XCUIElement { host.buttons["shareSend"] }
        var done: XCUIElement { host.buttons["shareDone"] }
        var text: XCUIElement {
            let field = host.textFields["shareText"]
            return field.exists ? field : host.textViews["shareText"]
        }
        func result(_ id: String) -> XCUIElement { host.descendants(matching: .any)["shareResult.\(id)"] }
        func waitForResult(_ id: String, _ value: String, timeout: TimeInterval = 40) {
            let row = result(id)
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            let reached = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: row)
            XCTAssertEqual(XCTWaiter().wait(for: [reached], timeout: timeout), .completed, "\(id): \(String(describing: row.value))")
        }
    }
}
