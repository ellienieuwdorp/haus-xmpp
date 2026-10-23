import XCTest
@testable import HausXMPP

/// The chat list's order, which the iPhone list, the Mac sidebar and the Mac's Go to Chat (⌘1 to ⌘9) share, and moving
/// to the next or previous chat from the keyboard.
final class ChatListOrderTests: XCTestCase {
    private func chat(_ id: String, pinned: Bool = false, at minutes: Double?) -> ChatSummary {
        ChatSummary(id: id, title: id, preview: "", isPinned: pinned, lastMessageAt: minutes.map { Date(timeIntervalSince1970: $0 * 60) })
    }

    func testPinnedFirstThenNewestWithTiesInStoreOrder() {
        let chats = [chat("old", at: 1), chat("quiet", at: nil), chat("pinnedOld", pinned: true, at: 2), chat("new", at: 9),
                     chat("tieA", at: 5), chat("pinnedNew", pinned: true, at: 8), chat("tieB", at: 5)]
        XCTAssertEqual(ChatListOrder.sorted(chats).map(\.id), ["pinnedNew", "pinnedOld", "new", "tieA", "tieB", "old", "quiet"])
    }

    func testNeighbourWrapsAroundAndStartsAtAnEnd() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(ChatListOrder.neighbour(of: "a", in: ids, forward: true), "b")
        XCTAssertEqual(ChatListOrder.neighbour(of: "c", in: ids, forward: true), "a")
        XCTAssertEqual(ChatListOrder.neighbour(of: "a", in: ids, forward: false), "c")
        XCTAssertEqual(ChatListOrder.neighbour(of: "b", in: ids, forward: false), "a")
        // Nothing selected, or a chat no longer listed: the first going forward, the last going back.
        XCTAssertEqual(ChatListOrder.neighbour(of: nil, in: ids, forward: true), "a")
        XCTAssertEqual(ChatListOrder.neighbour(of: "gone", in: ids, forward: false), "c")
        XCTAssertEqual(ChatListOrder.neighbour(of: "a", in: ["a"], forward: true), "a")
        XCTAssertNil(ChatListOrder.neighbour(of: nil, in: [], forward: true))
    }
}
