import UIKit
import XCTest
@testable import HausXMPP

/// Where the reader stays across timeline updates: the loading-earlier cell above the oldest message appears and leaves
/// without moving them, and only their own send pulls them back from history.
@MainActor
final class TimelinePositionTests: XCTestCase {
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
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>? { collectionView.dataSource as? UICollectionViewDiffableDataSource<Int, String> }

    private func messages(_ range: ClosedRange<Int>) -> [TimelineMessage] {
        range.map { TimelineMessage(id: "m\($0)", body: "Message \($0)" + ($0.isMultiple(of: 7) ? ", long enough to wrap onto a second line of the bubble." : ""),
                                    isOutgoing: $0.isMultiple(of: 3), isStarred: false) }
    }

    /// The first visible message and its distance from the top edge.
    private func readerPosition() throws -> (id: String, distance: CGFloat) {
        let path = try XCTUnwrap(collectionView.indexPathsForVisibleItems.sorted().first { dataSource?.itemIdentifier(for: $0) != TimelineItems.loadingEarlierID })
        let id = try XCTUnwrap(dataSource?.itemIdentifier(for: path))
        return (id, try XCTUnwrap(collectionView.layoutAttributesForItem(at: path)).frame.minY - collectionView.contentOffset.y)
    }

    private func distance(of id: String) throws -> CGFloat {
        let path = try XCTUnwrap(dataSource?.indexPath(for: id))
        return try XCTUnwrap(collectionView.layoutAttributesForItem(at: path)).frame.minY - collectionView.contentOffset.y
    }

    /// Stands in for the list while the reader's finger moves it, or while it coasts after a fling.
    private final class ReaderScroll: UIScrollView {
        var fingerDown = false
        var coasting = false
        override var isDragging: Bool { fingerDown }
        override var isDecelerating: Bool { coasting }
    }

    /// Older history is asked for a few screens before the reader reaches the oldest loaded message, and only by their
    /// own scroll: opening at the newest message, or any other programmatic move, never pages. The threshold itself is
    /// `TimelineScrollPolicyTests`'; this checks the controller asks with the scrolling view's own position and state.
    func testOnlyTheReadersScrollNearTheTopAsksForOlderMessages() throws {
        var asked = 0
        controller.onReachTop = { asked += 1 }
        controller.update(messages: messages(1...100), onToggleStar: { _ in })
        let top = -collectionView.adjustedContentInset.top
        let bottom = collectionView.contentOffset.y
        XCTAssertGreaterThan(bottom - top, 3000, "the window is several screens tall")
        // UIKit reports a programmatic move to the very top as a scroll, with nobody dragging.
        collectionView.contentOffset.y = top
        XCTAssertEqual(asked, 0)

        let reader = ReaderScroll()
        reader.contentInset = collectionView.adjustedContentInset
        let cases: [(dragging: Bool, decelerating: Bool, offset: CGFloat, asks: Bool, line: UInt)] = [
            (true, false, top + 300, true, #line),
            (false, true, top + 300, true, #line),
            (true, false, top, true, #line),
            (true, false, top + 3000, false, #line),
            (true, false, bottom, false, #line),
            (false, false, top + 300, false, #line),
        ]
        for scroll in cases {
            asked = 0
            reader.fingerDown = scroll.dragging
            reader.coasting = scroll.decelerating
            reader.contentOffset.y = scroll.offset
            collectionView.delegate?.scrollViewDidScroll?(reader)
            XCTAssertEqual(asked, scroll.asks ? 1 : 0, line: scroll.line)
        }
    }

    func testOnlyAnOwnSendReturnsFromHistoryToTheNewestMessage() throws {
        var shown = messages(1...100)
        controller.update(messages: shown, onToggleStar: { _ in })
        collectionView.contentOffset.y = 300
        collectionView.layoutIfNeeded()
        let before = try readerPosition()

        // A peer's message arriving while the reader is up in history leaves them where they are.
        shown.append(TimelineMessage(id: "incoming", body: "From the peer", isOutgoing: false, isStarred: false))
        controller.update(messages: shown, onToggleStar: { _ in })
        XCTAssertEqual(try distance(of: before.id), before.distance, accuracy: 0.5)

        shown.append(TimelineMessage(id: "sent", body: "Back to the bottom", isOutgoing: true, isStarred: false))
        controller.update(messages: shown, onToggleStar: { _ in })
        collectionView.layoutIfNeeded()
        let sent = try XCTUnwrap(dataSource?.indexPath(for: "sent"))
        XCTAssertTrue(collectionView.indexPathsForVisibleItems.contains(sent), "sending returns to the newest message")
    }

    func testHeaderComesAndGoesAboveTheOldestMessageWithoutMovingTheReader() throws {
        controller.update(messages: messages(1...100), onToggleStar: { _ in })
        // Near the top of the loaded window, where reaching the top starts a backfill.
        collectionView.contentOffset.y = 300
        collectionView.layoutIfNeeded()
        let before = try readerPosition()

        controller.update(messages: messages(1...100), loadingEarlier: true, onToggleStar: { _ in })
        XCTAssertEqual(dataSource?.snapshot().itemIdentifiers.first, TimelineItems.loadingEarlierID)
        XCTAssertEqual(collectionView.numberOfItems(inSection: 0), 101)
        XCTAssertEqual(try distance(of: before.id), before.distance, accuracy: 0.5)

        // The committed page arrives while the cell still shows, then the backfill ends.
        controller.update(messages: messages(-99...100), loadingEarlier: true, onToggleStar: { _ in })
        XCTAssertEqual(dataSource?.snapshot().itemIdentifiers.prefix(2), [TimelineItems.loadingEarlierID, "m-99"])
        XCTAssertEqual(try distance(of: before.id), before.distance, accuracy: 0.5)
        controller.update(messages: messages(-99...100), onToggleStar: { _ in })
        XCTAssertNil(dataSource?.indexPath(for: TimelineItems.loadingEarlierID))
        XCTAssertEqual(try distance(of: before.id), before.distance, accuracy: 0.5)
    }

    func testHeaderAtTheVeryTopLeavesTheReaderAtTheTopOrOnTheSameMessage() throws {
        controller.update(messages: messages(1...100), loadingEarlier: true, onToggleStar: { _ in })
        // Scrolled all the way up: the loading cell itself is the first visible item.
        let top = -collectionView.adjustedContentInset.top
        collectionView.contentOffset.y = top
        collectionView.layoutIfNeeded()
        let first = try XCTUnwrap(collectionView.indexPathsForVisibleItems.sorted().first)
        XCTAssertEqual(dataSource?.itemIdentifier(for: first), TimelineItems.loadingEarlierID)
        XCTAssertEqual(try readerPosition().id, "m1")

        // A committed page lands under the cell: the reader stays on m1 and the new history is above, off screen.
        let before = try distance(of: "m1")
        controller.update(messages: messages(-99...100), loadingEarlier: true, onToggleStar: { _ in })
        XCTAssertEqual(try distance(of: "m1"), before, accuracy: 0.5)

        // A backfill that brought nothing for this chat ends while the cell is on screen: nothing is above the oldest
        // message any more, so the list rests at its top instead of leaving a blank gap.
        controller.update(messages: messages(1...100), loadingEarlier: true, onToggleStar: { _ in })
        collectionView.contentOffset.y = top
        collectionView.layoutIfNeeded()
        controller.update(messages: messages(1...100), onToggleStar: { _ in })
        XCTAssertEqual(collectionView.contentOffset.y, top, accuracy: 0.5)
        XCTAssertEqual(dataSource?.snapshot().itemIdentifiers.first, "m1")
    }
}
