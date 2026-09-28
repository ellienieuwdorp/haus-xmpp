import XCTest
import UIKit
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
    private(set) var budgets: [NotificationActionBudget] = []
    func beginNotificationAction(account: String, chatID: String, budget: NotificationActionBudget) async -> Bool {
        steps.append("begin"); budgets.append(budget); return begins
    }
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


@MainActor private final class LeaseState { var held = true; var aborts = 0 }

/// The system's background time as a test controls it: expiry is triggered by hand, and every call is logged.
@MainActor private final class FakeBackgroundTime: NotificationActionBackgroundTime {
    var remaining: TimeInterval
    private(set) var log: [String] = []
    private var expiration: (@MainActor () -> Void)?
    init(remaining: TimeInterval = 30) { self.remaining = remaining }
    func begin(expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        self.expiration = expiration
        log.append("task-begin")
        return UIBackgroundTaskIdentifier(rawValue: 7)
    }
    func end(_ task: UIBackgroundTaskIdentifier) { log.append("task-end") }
    func note(_ step: String) { log.append(step) }
    /// What UIKit does when the time runs out: call the handler on the main thread.
    func expire() { log.append("expire"); expiration?() }
}

@MainActor final class NotificationActionTests: XCTestCase {
    private let account = "alice@example.org"
    private lazy var incoming = StoredMessage(id: UUID().uuidString, accountID: account, chatID: "bob@example.org", senderID: "bob@example.org",
                                              body: "Synthetic", encryptionProfile: "modern")
    private let budget = NotificationActionBudget(start: .now, backgroundTimeRemaining: 30)
    private func request(_ kind: NotificationActionRequest.Kind, account: String? = nil) throws -> NotificationActionRequest {
        NotificationActionRequest(destination: try XCTUnwrap(NotificationDestination(accountID: account ?? self.account, messageID: incoming.id)), kind: kind)
    }

    // MARK: Decision logic

    func testMarkAsReadMovesThePointerClearsAndFlushesWithoutSending() async throws {
        let environment = FakeActionEnvironment(accounts: [account], message: incoming)
        let outcome = await NotificationActionHandler.perform(try request(.markRead), budget: budget, in: environment)
        XCTAssertEqual(outcome, .markedRead)
        XCTAssertEqual(environment.steps, ["authorize", "resolve", "authorize", "begin", "read", "clear", "flush", "end"])
        XCTAssertTrue(environment.enqueued.isEmpty)
        XCTAssertTrue(environment.reported.isEmpty)
    }

    func testReplyReadsFirstThenQueuesThroughTheOutboxAndClearsAStaleFailure() async throws {
        let environment = FakeActionEnvironment(accounts: [account], message: incoming)
        let outcome = await NotificationActionHandler.perform(try request(.reply("On my way")), budget: budget, in: environment)
        XCTAssertEqual(outcome, .replySent)
        XCTAssertEqual(environment.steps, ["authorize", "resolve", "authorize", "begin", "read", "clear", "authorize", "enqueue", "deliver", "report", "end"])
        XCTAssertEqual(environment.enqueued, ["On my way"])
        XCTAssertEqual(environment.reported, [false])
    }

    func testAHeldReplyStaysQueuedAndTheUserIsTold() async throws {
        let environment = FakeActionEnvironment(accounts: [account], message: incoming)
        environment.delivery = .held
        let outcome = await NotificationActionHandler.perform(try request(.reply("Hi")), budget: budget, in: environment)
        XCTAssertEqual(outcome, .replyHeld)
        XCTAssertEqual(environment.enqueued, ["Hi"], "the reply is saved exactly once and never re-sent another way")
        XCTAssertEqual(environment.reported, [true])
        XCTAssertEqual(environment.steps.last, "end")
    }

    func testAReplyThatCannotBeSavedIsReported() async throws {
        let environment = FakeActionEnvironment(accounts: [account], message: incoming)
        environment.enqueueFails = true
        let outcome = await NotificationActionHandler.perform(try request(.reply("Hi")), budget: budget, in: environment)
        XCTAssertEqual(outcome, .replyFailed)
        XCTAssertEqual(environment.reported, [true])
        XCTAssertFalse(environment.steps.contains("deliver"))
        XCTAssertEqual(environment.steps.last, "end")
    }

    func testAFailedReadDoesNotStopTheReply() async throws {
        let environment = FakeActionEnvironment(accounts: [account], message: incoming)
        environment.readFails = true
        let outcome1 = await NotificationActionHandler.perform(try request(.reply("Hi")), budget: budget, in: environment)
        XCTAssertEqual(outcome1, .replySent)
        XCTAssertFalse(environment.steps.contains("clear"))
        let markOnly = FakeActionEnvironment(accounts: [account], message: incoming)
        markOnly.readFails = true
        let outcome2 = await NotificationActionHandler.perform(try request(.markRead), budget: budget, in: markOnly)
        XCTAssertEqual(outcome2, .unavailable)
    }

    func testNoStorageTouchesNothingAndReportsAReply() async throws {
        let environment = FakeActionEnvironment(accounts: [account], message: incoming)
        environment.begins = false
        let outcome3 = await NotificationActionHandler.perform(try request(.reply("Hi")), budget: budget, in: environment)
        XCTAssertEqual(outcome3, .unavailable)
        XCTAssertEqual(environment.steps, ["authorize", "resolve", "authorize", "begin", "report"])
        XCTAssertEqual(environment.reported, [true])
    }

    // MARK: Destination resolution and rejection

    func testSignedOutAnotherAccountOrAnUnknownMessageIsRejectedBeforeAnythingIsTouched() async throws {
        let signedOut = FakeActionEnvironment(accounts: [nil], message: incoming)
        let outcome4 = await NotificationActionHandler.perform(try request(.reply("Hi")), budget: budget, in: signedOut)
        XCTAssertEqual(outcome4, .rejected)
        XCTAssertEqual(signedOut.steps, ["authorize"])

        // A notification issued for another account never resolves under the current one.
        let otherAccount = FakeActionEnvironment(accounts: [account], message: incoming)
        let outcome5 = await NotificationActionHandler.perform(try request(.markRead, account: "mallory@example.org"), budget: budget, in: otherAccount)
        XCTAssertEqual(outcome5, .rejected)
        XCTAssertEqual(otherAccount.steps, ["authorize"])

        let unknown = FakeActionEnvironment(accounts: [account], message: nil)
        let outcome6 = await NotificationActionHandler.perform(try request(.markRead), budget: budget, in: unknown)
        XCTAssertEqual(outcome6, .rejected)
        XCTAssertFalse(unknown.steps.contains("begin"))

        // Switched accounts while resolving.
        let switched = FakeActionEnvironment(accounts: [account, "carol@example.org"], message: incoming)
        let outcome7 = await NotificationActionHandler.perform(try request(.markRead), budget: budget, in: switched)
        XCTAssertEqual(outcome7, .rejected)
        XCTAssertFalse(switched.steps.contains("begin"))
    }

    func testSigningOutDuringTheActionSavesNoReplyAndStillReleasesTheTransport() async throws {
        let environment = FakeActionEnvironment(accounts: [account, account, nil], message: incoming)
        let outcome8 = await NotificationActionHandler.perform(try request(.reply("Hi")), budget: budget, in: environment)
        XCTAssertEqual(outcome8, .rejected)
        XCTAssertTrue(environment.enqueued.isEmpty)
        XCTAssertEqual(environment.steps.last, "end")
    }

    // MARK: Budget and background time

    func testTheBudgetStartsAtTheCallbackAndLeavesTheTeardownInsideTheSystemsTime() {
        let start = ContinuousClock.now
        // A background launch: about 30 s. The network part ends at 20 s and 9 s stay for the teardown.
        let launch = NotificationActionBudget(start: start, backgroundTimeRemaining: 30)
        XCTAssertEqual(launch.deadline - start, .seconds(20))
        XCTAssertLessThanOrEqual(launch.deadline + NotificationActionBudget.teardown - start, .seconds(30))
        // Less time left (a quiesce or a queued action used some): the deadline moves in, never past it.
        XCTAssertEqual(NotificationActionBudget(start: start, backgroundTimeRemaining: 21).deadline - start, .seconds(12))
        XCTAssertEqual(NotificationActionBudget(start: start, backgroundTimeRemaining: 5).deadline, start, "no network at all")
        XCTAssertEqual(NotificationActionBudget(start: start, backgroundTimeRemaining: -1).deadline, start)
        // In front of the app UIKit reports an unlimited value; only the cap applies.
        XCTAssertEqual(NotificationActionBudget(start: start, backgroundTimeRemaining: .greatestFiniteMagnitude).deadline - start, .seconds(20))
        // The waits before connecting share one 6 s bound and never pass the deadline.
        XCTAssertEqual(launch.leaseDeadline(from: start) - start, .seconds(6))
        XCTAssertEqual(launch.leaseDeadline(from: start + .seconds(17)), launch.deadline)
        XCTAssertEqual(launch.remaining(at: start + .seconds(18), atMost: .seconds(3)), .seconds(2))
        XCTAssertEqual(launch.remaining(at: start + .seconds(25), atMost: .seconds(3)), .zero)
        // Presenting what arrived ends 2 s before the reserved teardown does.
        XCTAssertEqual(launch.presentationTimeout(at: launch.deadline), .seconds(4))
        XCTAssertEqual(launch.presentationTimeout(at: launch.deadline + .seconds(5)), .seconds(2))
        XCTAssertEqual(launch.presentationTimeout(at: launch.deadline + .seconds(8)), .zero)
    }

    func testTheHandlerGetsTheBudgetMeasuredWhenTheCallbackArrived() async throws {
        let environment = FakeActionEnvironment(accounts: [account], message: incoming)
        _ = await NotificationActionHandler.perform(try request(.markRead), budget: budget, in: environment)
        XCTAssertEqual(environment.budgets, [budget])

        let time = FakeBackgroundTime(remaining: 21)
        let center = NotificationActionCenter(time: time, reportRejectedReply: {})
        var received: NotificationActionBudget?
        center.handler = { _, budget in received = budget; return .markedRead }
        let before = ContinuousClock.now
        await center.perform(try request(.markRead))
        let deadline = try XCTUnwrap(received).deadline
        XCTAssertGreaterThanOrEqual(deadline, before + .seconds(12))
        XCTAssertLessThanOrEqual(deadline, ContinuousClock.now + .seconds(12))
    }

    /// The lease goes back (the action's `end`) before the background task ends, and the task ends exactly once.
    func testTheTransportIsReleasedBeforeTheBackgroundTaskEnds() async throws {
        let time = FakeBackgroundTime()
        let center = NotificationActionCenter(time: time, reportRejectedReply: {})
        let environment = FakeActionEnvironment(accounts: [account], message: incoming)
        center.handler = { request, budget in
            let outcome = await NotificationActionHandler.perform(request, budget: budget, in: environment)
            environment.steps.forEach(time.note)
            return outcome
        }
        let outcome = await center.perform(try request(.reply("Hi")))
        XCTAssertEqual(outcome, .replySent)
        XCTAssertEqual(time.log.first, "task-begin")
        XCTAssertEqual(Array(time.log.suffix(2)), ["end", "task-end"])
        XCTAssertEqual(time.log.filter { $0 == "task-end" }.count, 1)
    }

    /// Expiry while the action holds the lease: the connection is closed but the task is left to expire, so the
    /// system terminates the process (which frees the kernel lock) instead of suspending a lease owner.
    func testExpiryNeverEndsTheTaskWhileTheLeaseIsHeld() async throws {
        let time = FakeBackgroundTime()
        let center = NotificationActionCenter(time: time, reportRejectedReply: {})
        let lease = LeaseState()
        center.abort = { lease.aborts += 1; return lease.held }
        let (gate, open) = AsyncStream<Void>.makeStream()
        center.handler = { _, _ in
            for await _ in gate { break }
            return .markedRead
        }
        let markRead = try request(.markRead)
        let running = Task { await center.perform(markRead) }
        while !time.log.contains("task-begin") { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        time.expire()
        XCTAssertEqual(lease.aborts, 1)
        XCTAssertEqual(time.log, ["task-begin", "expire"], "not ended over a held lease")
        lease.held = false
        open.yield()
        _ = await running.value
        XCTAssertEqual(time.log, ["task-begin", "expire", "task-end"])
    }

    func testExpiryWithoutTheLeaseEndsTheTaskOnce() async throws {
        let time = FakeBackgroundTime()
        let center = NotificationActionCenter(time: time, reportRejectedReply: {})
        center.abort = { false }
        let (gate, open) = AsyncStream<Void>.makeStream()
        center.handler = { _, _ in
            for await _ in gate { break }
            return .markedRead
        }
        let markRead = try request(.markRead)
        let running = Task { await center.perform(markRead) }
        while !time.log.contains("task-begin") { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        time.expire()
        XCTAssertEqual(time.log, ["task-begin", "expire", "task-end"])
        open.yield()
        _ = await running.value
        XCTAssertEqual(time.log.filter { $0 == "task-end" }.count, 1)
    }

    // MARK: Rejected replies

    /// Before the first unlock the keychain cannot be read, so the account does not authorize: the reply is rejected,
    /// nothing is touched, and the content-free notice tells the user it was not sent. The same for a sign-out, another
    /// account, a message that no longer resolves, or a model that never registered in time.
    func testARejectedReplyPostsTheContentFreeNoticeAndARejectedReadDoesNot() async throws {
        let time = FakeBackgroundTime()
        var notices = 0
        let center = NotificationActionCenter(time: time, reportRejectedReply: { notices += 1 })
        let locked = FakeActionEnvironment(accounts: [nil], message: incoming)
        center.handler = { request, budget in await NotificationActionHandler.perform(request, budget: budget, in: locked) }
        let replied = await center.perform(try request(.reply("Hi")))
        XCTAssertEqual(replied, .rejected)
        XCTAssertEqual(locked.steps, ["authorize"], "nothing was read, saved or sent")
        XCTAssertEqual(notices, 1)
        let read = await center.perform(try request(.markRead))
        XCTAssertEqual(read, .rejected)
        XCTAssertEqual(notices, 1, "a rejected Mark as Read has nothing to report")

        let sent = FakeActionEnvironment(accounts: [account], message: incoming)
        center.handler = { request, budget in await NotificationActionHandler.perform(request, budget: budget, in: sent) }
        let ok = await center.perform(try request(.reply("Hi")))
        XCTAssertEqual(ok, .replySent)
        XCTAssertEqual(notices, 1)

        let noModel = NotificationActionCenter(time: FakeBackgroundTime(), reportRejectedReply: { notices += 1 })
        let unhandled = await noModel.perform(try request(.reply("Hi")), waitingForHandler: .milliseconds(100))
        XCTAssertEqual(unhandled, .rejected)
        XCTAssertEqual(notices, 2)
    }

    func testTheRejectedReplyNoticeShowsInFrontOfTheAppAndNamesNothing() {
        let notice = ForegroundPresentation.Request(identifier: NotificationActionCopy.replyRejectedIdentifier, isRemote: false,
                                                    categoryIdentifier: NotificationIdentity.noticeCategory, threadIdentifier: "",
                                                    playsSound: true, accountScope: nil)
        XCTAssertEqual(ForegroundPresentation.options(for: notice, accountID: account, openChatID: "bob@example.org"), [.banner, .list, .sound])
        XCTAssertEqual(ForegroundPresentation.options(for: notice, accountID: "", openChatID: nil), [.banner, .list, .sound], "also when signed out")
        var remote = notice
        remote.isRemote = true
        XCTAssertEqual(ForegroundPresentation.options(for: remote, accountID: account, openChatID: nil), [])
        XCTAssertFalse(NotificationActionCopy.replyRejected.contains("Open the chat"))
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
