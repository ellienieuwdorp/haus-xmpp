import MessageStore
import XCTest
import XMPPProtocol
@testable import HausXMPP

/// Who our own fetch runs for (docs/development/link-previews.md, engineering default 3; owner decision 2026-10-07:
/// never for non-contacts, no option).
final class LinkPreviewPolicyTests: XCTestCase {
    private static let account = "me@example.org"

    private func message(from sender: String, outgoing: Bool = false, chat: String = "alex@example.org") -> StoredMessage {
        StoredMessage(id: UUID().uuidString, accountID: Self.account, chatID: chat, senderID: sender, body: "https://example.net/a",
                      isOutgoing: outgoing, encryptionProfile: "modern")
    }

    func testOnlyOwnMessagesAndContactsWithASubscriptionAreFetchedFor() {
        let roster: [String: LinkPreviewPolicy.RosterEntry] = [
            "to@example.org": .item(.to), "from@example.org": .item(.from), "both@example.org": .item(.both),
            "pending@example.org": .item(.none),
        ]
        let loaded: (String) -> LinkPreviewPolicy.RosterEntry = { roster[$0] ?? .absent }
        let cases: [(message: StoredMessage, roster: (String) -> LinkPreviewPolicy.RosterEntry, expected: Bool, line: UInt)] = [
            (message(from: Self.account, outgoing: true), { _ in .notLoaded }, true, #line),
            // Sent from another of our devices (a carbon or the archive).
            (message(from: Self.account), loaded, true, #line),
            (message(from: "to@example.org"), loaded, true, #line),
            (message(from: "from@example.org"), loaded, true, #line),
            (message(from: "Both@Example.org"), loaded, true, #line),
            // A request we or they have not answered yet.
            (message(from: "pending@example.org"), loaded, false, #line),
            (message(from: "stranger@example.org"), loaded, false, #line),
            // Before this connection's roster arrived nobody is a contact.
            (message(from: "both@example.org"), { _ in .notLoaded }, false, #line),
            // A group: a contact's real address counts; an occupant known only by nickname never does.
            (message(from: "both@example.org", chat: "room@conference.example.org"), loaded, true, #line),
            (message(from: "room@conference.example.org/both", chat: "room@conference.example.org"), { _ in .item(.both) }, false, #line),
        ]
        for (message, roster, expected, line) in cases {
            XCTAssertEqual(LinkPreviewPolicy.mayFetch(for: message, account: Self.account, fetchesPreviews: true, isDemo: false, roster: roster),
                           expected, message.senderID, line: line)
        }
    }

    /// The setting off, or the sample conversations: never, not even for our own messages.
    func testTheSettingAndDemoModeStopEveryFetch() {
        let own = message(from: Self.account, outgoing: true)
        XCTAssertFalse(LinkPreviewPolicy.mayFetch(for: own, account: Self.account, fetchesPreviews: false, isDemo: false) { _ in .item(.both) })
        XCTAssertFalse(LinkPreviewPolicy.mayFetch(for: own, account: Self.account, fetchesPreviews: true, isDemo: true) { _ in .item(.both) })
    }
}
