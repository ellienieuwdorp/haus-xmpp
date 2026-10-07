import XCTest
import MessageStore
import XMPPProtocol
@testable import HausXMPP

/// Files sent with no caption can carry a reply only as a bare XEP-0461 reference inside a modern OMEMO envelope,
/// and only to a message whose wire ID the peer holds: our own sent direct message.
final class FileReplyGateTests: XCTestCase {
    private let account = "me@example.test"
    private let chat = "alex@example.test"

    private func message(outgoing: Bool = true, sent: Bool = true, chatID: String? = nil) -> StoredMessage {
        StoredMessage(id: "m1", accountID: account, chatID: chatID ?? chat, senderID: outgoing ? account : chat, body: "Ten it is",
                      isOutgoing: outgoing, transportState: outgoing && sent ? .serverAccepted : nil)
    }

    private func gate(_ source: StoredMessage, chatID: String? = nil, isGroup: Bool = false, isDemo: Bool = false,
                      profile: XMPPOMEMOProfile?) -> Bool {
        AppModel.filesAloneCanReply(to: source, accountID: account, chatID: chatID ?? chat, isGroup: isGroup, isDemo: isDemo, chatProfile: profile)
    }

    func testOnlyAnOwnSentMessageInAModernChatCarriesTheReply() {
        XCTAssertTrue(gate(message(), profile: .modern))
        // Legacy OMEMO has no envelope: the reference would travel in clear.
        XCTAssertFalse(gate(message(), profile: .legacy))
        // Not known yet, or the loaded overview belongs to another chat (the caller passes nil then).
        XCTAssertFalse(gate(message(), profile: nil))
        // A received message has no wire ID we may reference until CX-4.
        XCTAssertFalse(gate(message(outgoing: false), profile: .modern))
        // An own message with no transport state was never sent, so the peer does not hold its ID.
        XCTAssertFalse(gate(message(sent: false), profile: .modern))
        XCTAssertFalse(gate(message(), isGroup: true, profile: .modern))
        // A message from another chat is never the reply target here.
        XCTAssertFalse(gate(message(chatID: "sam@example.test"), profile: .modern))
    }

    func testSampleChatsFollowTheOwnMessageRuleWithoutEncryption() {
        XCTAssertTrue(gate(message(sent: false), isDemo: true, profile: nil))
        XCTAssertFalse(gate(message(outgoing: false), isDemo: true, profile: nil))
    }

    func testOnlyAnOwnSentDirectMessageHasAWireIDToReference() {
        XCTAssertEqual(AppModel.replyWireID(of: message(), isGroup: false), "m1")
        XCTAssertNil(AppModel.replyWireID(of: message(), isGroup: true))
        XCTAssertNil(AppModel.replyWireID(of: message(outgoing: false), isGroup: false))
        XCTAssertNil(AppModel.replyWireID(of: message(sent: false), isGroup: false))
    }
}
