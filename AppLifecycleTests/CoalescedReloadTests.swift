import MessageStore
import UIKit
import XCTest
@testable import HausXMPP

@MainActor
final class CoalescedReloadTests: XCTestCase {
    /// A load that parks until the test releases it, so requests can be made "during" a load.
    @MainActor private final class Gate {
        var scopes: [CoalescedReload.Scope] = []
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func load(_ scope: CoalescedReload.Scope) async {
            scopes.append(scope)
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() { waiting.removeFirst().resume() }
        /// Yields until `count` loads have started.
        func started(_ count: Int) async { while scopes.count < count { await Task.yield() } }
    }

    func testBurstDuringLoadCostsTwoLoadsAndUnionsScopes() async {
        let gate = Gate()
        let reload = CoalescedReload { await gate.load($0) }
        let first = Task { await reload.request(.chats) }
        await gate.started(1)
        var finished = 0
        let burst = (0..<200).map { index in
            Task { await reload.request(index.isMultiple(of: 2) ? .chats : .openChat); finished += 1 }
        }
        for _ in 0..<50 { await Task.yield() }
        gate.release()
        // The first caller is done after its own load, not after the follow-up the burst caused.
        await first.value
        await gate.started(2)
        // The load these callers joined predates their request, so none may have returned yet.
        XCTAssertEqual(finished, 0)
        gate.release()
        for task in burst { await task.value }
        XCTAssertEqual(finished, 200)
        XCTAssertEqual(gate.scopes, [.chats, .all])
    }
}

/// The warm page cache behind opening a chat on its newest messages in the first frame.
@MainActor
final class TimelinePageCacheTests: XCTestCase {
    private typealias Cache = AppModel.TimelinePageCache

    private func page(_ chat: String, count: Int, newestAt: TimeInterval = 1000, newestOutgoing: Bool = false) -> AppModel.TimelinePage {
        AppModel.TimelinePage(messages: (1...count).map { index in
            StoredMessage(id: "\(chat)-\(index)", accountID: "a@example.org", chatID: chat, senderID: chat, body: "\(index)",
                          sentAt: Date(timeIntervalSince1970: newestAt - Double(count - index)), isOutgoing: index == count && newestOutgoing)
        })
    }

    private func summary(_ chat: String, newestAt: TimeInterval = 1000, preview: String = "last", outgoing: Bool = false) -> ChatSummary {
        ChatSummary(id: chat, title: chat, preview: preview, isPinned: false, lastMessageAt: Date(timeIntervalSince1970: newestAt), lastMessageIsOutgoing: outgoing)
    }

    func testAPageIsShownOnlyWhileTheListShowsTheSameNewestMessage() {
        var cache = Cache()
        cache.store(page("alex", count: 3), for: summary("alex"), account: "a")
        XCTAssertEqual(cache.page(for: summary("alex"), account: "a")?.messages.map(\.id), ["alex-1", "alex-2", "alex-3"])
        // A newer message, an edited last message or a changed receipt all show as a different list row.
        XCTAssertNil(cache.page(for: summary("alex", newestAt: 1001), account: "a"))
        // The stale entry is gone, not just skipped.
        XCTAssertNil(cache.page(for: summary("alex"), account: "a"))
        cache.store(page("maya", count: 2), for: summary("maya"), account: "a")
        XCTAssertNil(cache.page(for: summary("maya", preview: "edited"), account: "a"))
    }

    func testAPageThatDisagreesWithTheListIsNotKept() {
        var cache = Cache()
        // Read before a message arrived that the list already shows.
        cache.store(page("alex", count: 3, newestAt: 999), for: summary("alex", newestAt: 1000), account: "a")
        XCTAssertNil(cache.page(for: summary("alex", newestAt: 1000), account: "a"))
        cache.store(page("alex", count: 3, newestOutgoing: false), for: summary("alex", outgoing: true), account: "a")
        XCTAssertNil(cache.page(for: summary("alex", outgoing: true), account: "a"))
        cache.store(page("alex", count: 1), for: nil, account: "a")
        XCTAssertNil(cache.page(for: summary("alex"), account: "a"))
    }

    func testPagesNeverCrossAccounts() {
        var cache = Cache()
        cache.store(page("alex", count: 3), for: summary("alex"), account: "a")
        XCTAssertNil(cache.page(for: summary("alex"), account: "b"))
    }

    func testPrefetchAsksForTheTopChatsLackingACurrentPage() {
        var cache = Cache()
        let chats = (1...10).map { summary("chat\($0)") }
        cache.store(page("chat2", count: 2), for: chats[1], account: "a")
        cache.store(page("chat3", count: 2), for: chats[2], account: "a")
        var listed = chats
        listed[2] = summary("chat3", newestAt: 2000)
        let wanted = cache.missing(from: listed, account: "a", excluding: "chat1").map(\.id)
        // chat1 is open, chat2 is current, chat3 moved on; only the first eight are prefetched.
        XCTAssertEqual(wanted, ["chat3", "chat4", "chat5", "chat6", "chat7", "chat8"])
        XCTAssertNil(cache.page(for: listed[2], account: "a"))
        XCTAssertNotNil(cache.page(for: listed[1], account: "a"))
        // Another account's list drops this account's pages, so chat2 is wanted again.
        XCTAssertEqual(cache.missing(from: listed, account: "b", excluding: nil).count, Cache.prefetchCount)
    }
}

/// Opening a chat never flashes "No messages yet" while its first page is on the way.
@MainActor
final class ConversationEmptyNoticeTests: XCTestCase {
    private func notice(isEmpty: Bool = true, loadedFor: String?, search: String = "", starred: Bool = false) -> String? {
        ConversationView.emptyNotice(isEmpty: isEmpty, loadedFor: loadedFor, chatID: "alex", searchTerm: search, starredOnly: starred)?.title
    }

    func testOnlyALoadedEmptyChatSaysSo() {
        XCTAssertNil(notice(loadedFor: nil), "the first page is still loading")
        XCTAssertNil(notice(loadedFor: "maya"), "the loaded page is the previous chat's")
        XCTAssertNil(notice(isEmpty: false, loadedFor: "alex"))
        XCTAssertEqual(notice(loadedFor: "alex"), "No messages yet")
        XCTAssertEqual(notice(loadedFor: "alex", starred: true), "No starred messages")
        XCTAssertEqual(notice(loadedFor: "alex", search: "ten", starred: true), "No matching messages")
        XCTAssertNil(notice(loadedFor: nil, search: "ten"), "a search waits for the load too")
    }
}

/// Offsets are decided inside `update`, so no frame can show a window at the wrong position.
@MainActor
final class TimelineOffsetTests: XCTestCase {
    private var window: UIWindow!
    private var controller: ConversationTimelineController!

    override func setUp() async throws {
        controller = ConversationTimelineController()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
    }

    override func tearDown() async throws {
        window.isHidden = true
        window = nil
        controller = nil
    }

    private var collectionView: UICollectionView { controller.view.subviews.compactMap { $0 as? UICollectionView }.first! }
    private var bottomOffset: CGFloat {
        max(-collectionView.adjustedContentInset.top, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
    }

    private func messages(_ range: ClosedRange<Int>) -> [TimelineMessage] {
        range.map { TimelineMessage(id: "m\($0)", body: "Message \($0)" + ($0.isMultiple(of: 7) ? ", long enough to wrap onto a second line of the bubble." : ""),
                                    isOutgoing: $0.isMultiple(of: 3), isStarred: false) }
    }

    private func identifier(at path: IndexPath) -> String? {
        (collectionView.dataSource as? UICollectionViewDiffableDataSource<Int, String>)?.itemIdentifier(for: path)
    }

    func testFirstContentIsAtTheNewestMessageWhenUpdateReturns() {
        controller.update(messages: messages(151...250), onToggleStar: { _ in })
        XCTAssertEqual(collectionView.numberOfItems(inSection: 0), 100)
        XCTAssertEqual(collectionView.contentOffset.y, bottomOffset, accuracy: 0.5)
        let visible = collectionView.indexPathsForVisibleItems.compactMap(identifier)
        XCTAssertTrue(visible.contains("m250"))
        XCTAssertFalse(visible.contains("m151"))
    }

    func testAnArrivingMessageAtTheTailIsFollowedWhenUpdateReturns() {
        controller.update(messages: messages(151...250), onToggleStar: { _ in })
        controller.update(messages: messages(152...251), onToggleStar: { _ in })
        // Off-window: no slide, so the offset is final at once.
        XCTAssertEqual(collectionView.contentOffset.y, bottomOffset, accuracy: 0.5)
    }
}
