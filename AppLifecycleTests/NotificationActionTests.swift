import XCTest
import UserNotifications
import MessageStore
import MessagingCore
@testable import HausXMPP

/// Records every step an action takes instead of touching storage, the network or Notification Center.
@MainActor private final class FakeActionEnvironment: NotificationActionEnvironment {
    enum Failure: Error { case storage }
    var accounts: [String?]
    var message: StoredMessage?
    var begins = true
    var readFails = false
    var enqueueFails = false
    var delivery = ReplyDelivery.sent
    private(set) var steps: [String] = []
    private(set) var enqueued: [String] = []
    private(set) var reported: [Bool] = []

    /// `accounts` answers successive authorization checks; the last answer repeats.
    init(accounts: [String?], message: StoredMessage?) { self.accounts = accounts; self.message = message }

    func authorizedNotificationAccount() -> String? {
        steps.append("authorize")
        return accounts.count > 1 ? accounts.removeFirst() : accounts.first ?? nil
    }
    func resolveNotificationMessage(_ destination: NotificationDestination, account: String) async -> StoredMessage? {
        steps.append("resolve"); return message
    }
    func beginNotificationAction(account: String, chatID: String) async -> Bool { steps.append("begin"); return begins }
    func markNotificationMessageRead(_ message: StoredMessage) async throws {
        steps.append("read")
        if readFails { throw Failure.storage }
    }
    func clearReadNotifications(for message: StoredMessage) async { steps.append("clear") }
    func enqueueNotificationReply(_ text: String, to message: StoredMessage) async throws -> String {
        steps.append("enqueue")
        if enqueueFails { throw Failure.storage }
        enqueued.append(text)
        return "reply-id"
    }
    func deliverNotificationReply(_ messageID: String, account: String) async -> ReplyDelivery { steps.append("deliver"); return delivery }
    func flushNotificationAction(account: String) async { steps.append("flush") }
    func reportNotificationReply(failed: Bool, for message: StoredMessage) async { steps.append("report"); reported.append(failed) }
    func endNotificationAction() async { steps.append("end") }
}

@MainActor final class NotificationActionTests: XCTestCase {
    private let account = "alice@example.org"
    private lazy var incoming = StoredMessage(id: UUID().uuidString, accountID: account, chatID: "bob@example.org", senderID: "bob@example.org",
                                              body: "Synthetic", encryptionProfile: "modern")
    private func request(_ kind: NotificationActionRequest.Kind, account: String? = nil) throws -> NotificationActionRequest {
        NotificationActionRequest(destination: try XCTUnwrap(NotificationDestination(accountID: account ?? self.account, messageID: incoming.id)), kind: kind)
    }

    // MARK: Decision logic

    func testMarkAsReadMovesThePointerClearsAndFlushesWithoutSending() async throws {
        let environment = FakeActionEnvironment(accounts: [account], message: incoming)
        let outcome = await NotificationActionHandler.perform(try request(.markRead), in: environment)
        XCTAssertEqual(outcome, .markedRead)
        XCTAssertEqual(environment.steps, ["authorize", "resolve", "authorize", "begin", "read", "clear", "flush", "end"])
        XCTAssertTrue(environment.enqueued.isEmpty)
        XCTAssertTrue(environment.reported.isEmpty)
    }

    func testReplyReadsFirstThenQueuesThroughTheOutboxAndClearsAStaleFailure() async throws {
        let environment = FakeActionEnvironment(accounts: [account], message: incoming)
        let outcome = await NotificationActionHandler.perform(try request(.reply("On my way")), in: environment)
        XCTAssertEqual(outcome, .replySent)
        XCTAssertEqual(environment.steps, ["authorize", "resolve", "authorize", "begin", "read", "clear", "authorize", "enqueue", "deliver", "report", "end"])
        XCTAssertEqual(environment.enqueued, ["On my way"])
        XCTAssertEqual(environment.reported, [false])
    }

    func testAHeldReplyStaysQueuedAndTheUserIsTold() async throws {
        let environment = FakeActionEnvironment(accounts: [account], message: incoming)
        environment.delivery = .held
        let outcome = await NotificationActionHandler.perform(try request(.reply("Hi")), in: environment)
        XCTAssertEqual(outcome, .replyHeld)
        XCTAssertEqual(environment.enqueued, ["Hi"], "the reply is saved exactly once and never re-sent another way")
        XCTAssertEqual(environment.reported, [true])
        XCTAssertEqual(environment.steps.last, "end")
    }

    func testAReplyThatCannotBeSavedIsReported() async throws {
        let environment = FakeActionEnvironment(accounts: [account], message: incoming)
        environment.enqueueFails = true
        let outcome = await NotificationActionHandler.perform(try request(.reply("Hi")), in: environment)
        XCTAssertEqual(outcome, .replyFailed)
        XCTAssertEqual(environment.reported, [true])
        XCTAssertFalse(environment.steps.contains("deliver"))
        XCTAssertEqual(environment.steps.last, "end")
    }

    func testAFailedReadDoesNotStopTheReply() async throws {
        let environment = FakeActionEnvironment(accounts: [account], message: incoming)
        environment.readFails = true
        let outcome1 = await NotificationActionHandler.perform(try request(.reply("Hi")), in: environment)
        XCTAssertEqual(outcome1, .replySent)
        XCTAssertFalse(environment.steps.contains("clear"))
        let markOnly = FakeActionEnvironment(accounts: [account], message: incoming)
        markOnly.readFails = true
        let outcome2 = await NotificationActionHandler.perform(try request(.markRead), in: markOnly)
        XCTAssertEqual(outcome2, .unavailable)
    }

    func testNoStorageTouchesNothingAndReportsAReply() async throws {
        let environment = FakeActionEnvironment(accounts: [account], message: incoming)
        environment.begins = false
        let outcome3 = await NotificationActionHandler.perform(try request(.reply("Hi")), in: environment)
        XCTAssertEqual(outcome3, .unavailable)
        XCTAssertEqual(environment.steps, ["authorize", "resolve", "authorize", "begin", "report"])
        XCTAssertEqual(environment.reported, [true])
    }

    // MARK: Destination resolution and rejection

    func testSignedOutAnotherAccountOrAnUnknownMessageIsRejectedBeforeAnythingIsTouched() async throws {
        let signedOut = FakeActionEnvironment(accounts: [nil], message: incoming)
        let outcome4 = await NotificationActionHandler.perform(try request(.reply("Hi")), in: signedOut)
        XCTAssertEqual(outcome4, .rejected)
        XCTAssertEqual(signedOut.steps, ["authorize"])

        // A notification issued for another account never resolves under the current one.
        let otherAccount = FakeActionEnvironment(accounts: [account], message: incoming)
        let outcome5 = await NotificationActionHandler.perform(try request(.markRead, account: "mallory@example.org"), in: otherAccount)
        XCTAssertEqual(outcome5, .rejected)
        XCTAssertEqual(otherAccount.steps, ["authorize"])

        let unknown = FakeActionEnvironment(accounts: [account], message: nil)
        let outcome6 = await NotificationActionHandler.perform(try request(.markRead), in: unknown)
        XCTAssertEqual(outcome6, .rejected)
        XCTAssertFalse(unknown.steps.contains("begin"))

        // Switched accounts while resolving.
        let switched = FakeActionEnvironment(accounts: [account, "carol@example.org"], message: incoming)
        let outcome7 = await NotificationActionHandler.perform(try request(.markRead), in: switched)
        XCTAssertEqual(outcome7, .rejected)
        XCTAssertFalse(switched.steps.contains("begin"))
    }

    func testSigningOutDuringTheActionSavesNoReplyAndStillReleasesTheTransport() async throws {
        let environment = FakeActionEnvironment(accounts: [account, account, nil], message: incoming)
        let outcome8 = await NotificationActionHandler.perform(try request(.reply("Hi")), in: environment)
        XCTAssertEqual(outcome8, .rejected)
        XCTAssertTrue(environment.enqueued.isEmpty)
        XCTAssertEqual(environment.steps.last, "end")
    }

    // MARK: Parsing the response

    func testOnlyAMessageNotificationWithADestinationAndTextBecomesAnAction() throws {
        let destination = try XCTUnwrap(NotificationDestination(accountID: account, messageID: incoming.id))
        let info: [AnyHashable: Any] = [NotificationDestination.userInfoKey: destination.payload]
        let message = NotificationIdentity.messageCategory
        XCTAssertEqual(NotificationActionRequest(userInfo: info, categoryIdentifier: message, actionIdentifier: NotificationActionIdentifier.markRead, text: nil)?.kind, .markRead)
        XCTAssertEqual(NotificationActionRequest(userInfo: info, categoryIdentifier: message, actionIdentifier: NotificationActionIdentifier.reply, text: "Yes")?.kind, .reply("Yes"))
        XCTAssertNil(NotificationActionRequest(userInfo: info, categoryIdentifier: message, actionIdentifier: NotificationActionIdentifier.reply, text: " \n"))
        XCTAssertNil(NotificationActionRequest(userInfo: info, categoryIdentifier: message, actionIdentifier: NotificationActionIdentifier.reply,
                                               text: String(repeating: "a", count: 16_385)))
        XCTAssertNil(NotificationActionRequest(userInfo: info, categoryIdentifier: message, actionIdentifier: UNNotificationDefaultActionIdentifier, text: nil))
        // Review, placeholder, summary and fallback requests have no actions even if a response names one.
        for category in [NotificationIdentity.noticeCategory, NotificationIdentity.fallbackCategory] {
            XCTAssertNil(NotificationActionRequest(userInfo: info, categoryIdentifier: category, actionIdentifier: NotificationActionIdentifier.markRead, text: nil))
        }
        XCTAssertNil(NotificationActionRequest(userInfo: [:], categoryIdentifier: message, actionIdentifier: NotificationActionIdentifier.markRead, text: nil))
        XCTAssertNil(NotificationActionRequest(userInfo: [NotificationDestination.userInfoKey: ["url": "https://invalid.example"]], categoryIdentifier: message,
                                               actionIdentifier: NotificationActionIdentifier.markRead, text: nil))
        XCTAssertFalse(String(describing: NotificationActionRequest(destination: destination, kind: .reply("Secret"))).contains("Secret"))
    }

    func testOnlyTheMessageCategoryOffersReplyAndMarkAsReadWithoutAuthentication() throws {
        let categories = Dictionary(uniqueKeysWithValues: NotificationCategories.all.map { ($0.identifier, $0) })
        let message = try XCTUnwrap(categories[NotificationIdentity.messageCategory])
        XCTAssertEqual(message.actions.map(\.identifier), [NotificationActionIdentifier.reply, NotificationActionIdentifier.markRead])
        XCTAssertEqual(message.actions.map(\.title), ["Reply", "Mark as Read"])
        let reply = try XCTUnwrap(message.actions.first as? UNTextInputNotificationAction)
        XCTAssertEqual(reply.textInputPlaceholder, "Message")
        XCTAssertTrue(message.actions.allSatisfy { !$0.options.contains(.authenticationRequired) && !$0.options.contains(.foreground) })
        XCTAssertEqual(categories[NotificationIdentity.noticeCategory]?.actions.count, 0)
        XCTAssertEqual(categories[NotificationIdentity.fallbackCategory]?.actions.count, 0)
    }

    /// The host app registered the categories at launch: the system, not just the value, has Reply and Mark as Read.
    func testTheSystemHasTheMessageCategoryActions() async throws {
        var registered: Set<UNNotificationCategory> = []
        for _ in 0..<20 {
            registered = await UNUserNotificationCenter.current().notificationCategories()
            if !registered.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let message = try XCTUnwrap(registered.first { $0.identifier == NotificationIdentity.messageCategory })
        XCTAssertEqual(message.actions.map(\.identifier), [NotificationActionIdentifier.reply, NotificationActionIdentifier.markRead])
        XCTAssertEqual(Set(registered.map(\.identifier)), [NotificationIdentity.messageCategory, NotificationIdentity.noticeCategory,
                                                             NotificationIdentity.fallbackCategory])
    }

    func testAFailedReplyNoticeOpensItsChatButActionButtonsNeverRoute() throws {
        let destination = try XCTUnwrap(NotificationDestination(accountID: account, messageID: incoming.id))
        XCTAssertEqual(NotificationNavigation.destination(userInfo: [NotificationNavigation.replyFailureKey: destination.payload],
                                                          actionIdentifier: UNNotificationDefaultActionIdentifier), destination)
        XCTAssertNil(NotificationNavigation.destination(userInfo: [NotificationDestination.userInfoKey: destination.payload],
                                                        actionIdentifier: NotificationActionIdentifier.markRead))
    }

    // MARK: Foreground banners

    private func banner(chat: String, category: String = NotificationIdentity.messageCategory, remote: Bool = false,
                        sound: Bool = true, account: String? = nil) -> ForegroundPresentation.Request {
        let owner = account ?? self.account
        return ForegroundPresentation.Request(isRemote: remote, categoryIdentifier: category,
                                              threadIdentifier: NotificationIdentity.thread(accountID: owner, chatID: chat), playsSound: sound,
                                              accountScope: NotificationDestination(accountID: owner, messageID: UUID().uuidString)?.accountScope)
    }

    func testTheOpenChatNeverBannersAndOtherChatsDo() {
        let options = { (request: ForegroundPresentation.Request, open: String?) in
            ForegroundPresentation.options(for: request, accountID: self.account, openChatID: open)
        }
        XCTAssertEqual(options(banner(chat: "bob@example.org"), "bob@example.org"), [])
        XCTAssertEqual(options(banner(chat: "carol@example.org"), "bob@example.org"), [.banner, .list, .sound])
        XCTAssertEqual(options(banner(chat: "carol@example.org"), nil), [.banner, .list, .sound], "on the chat list every chat banners")
        XCTAssertEqual(options(banner(chat: "carol@example.org", sound: false), nil), [.banner, .list])
        // A review or failed-reply notice for another chat shows too; it is still about that chat.
        XCTAssertEqual(options(banner(chat: "carol@example.org", category: NotificationIdentity.noticeCategory), nil), [.banner, .list, .sound])
    }

    func testRemoteFallbackAndForeignRequestsStayHidden() {
        let options = { (request: ForegroundPresentation.Request) in
            ForegroundPresentation.options(for: request, accountID: self.account, openChatID: nil)
        }
        XCTAssertEqual(options(banner(chat: "carol@example.org", remote: true)), [], "the gateway placeholder and the extension's remote content")
        XCTAssertEqual(options(banner(chat: "carol@example.org", category: NotificationIdentity.fallbackCategory)), [])
        XCTAssertEqual(options(banner(chat: "carol@example.org", category: "")), [])
        XCTAssertEqual(options(banner(chat: "carol@example.org", account: "mallory@example.org")), [])
        var unscoped = banner(chat: "carol@example.org")
        unscoped.accountScope = nil
        XCTAssertEqual(options(unscoped), [])
        XCTAssertEqual(ForegroundPresentation.options(for: banner(chat: "carol@example.org"), accountID: "", openChatID: nil), [], "signed out")
    }
}
