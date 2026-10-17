import MessageStore
import XCTest
@testable import HausXMPP

/// What the Mac's Message menu acts on: per command, the newest loaded message whose own menu offers that action.
final class LastMessageTargetsTests: XCTestCase {
    private let sentAt = Date(timeIntervalSince1970: 1_789_380_000)

    private func received(_ id: String, canReact: Bool = true, unreadable: UnreadableReason? = nil, retracted: Bool = false) -> TimelineMessage {
        TimelineMessage(id: id, body: unreadable == nil && !retracted ? "Hello" : "", isOutgoing: false, isStarred: false, sentAt: sentAt,
                        canReact: canReact, isRetracted: retracted, unreadable: unreadable)
    }

    private func sent(_ id: String, canEdit: Bool) -> TimelineMessage {
        TimelineMessage(id: id, body: "On my way", isOutgoing: true, isStarred: false, sentAt: sentAt, status: .serverAccepted, canEdit: canEdit)
    }

    func testEachCommandTakesTheNewestMessageOfferingIt() {
        let targets = LastMessageTargets(messages: [received("r1"), sent("s1", canEdit: true), received("r2", canReact: false), sent("s2", canEdit: false)])
        XCTAssertEqual(targets.reply?.id, "r2", "the newest received message, whoever spoke last")
        XCTAssertEqual(targets.edit?.id, "s1", "the newest own message that can still be edited")
        XCTAssertEqual(targets.react?.id, "r1", "the newest received message that takes reactions")
        XCTAssertEqual(targets.star?.id, "s2", "the newest message of either side")
    }

    /// Placeholders are notices: an unreadable message offers only its encryption details, an unsent one only its star.
    func testPlaceholdersAreSkippedForWhatTheyDoNotOffer() {
        let targets = LastMessageTargets(messages: [received("readable"), received("unsent", retracted: true), received("unreadable", unreadable: .decryptFailed)])
        XCTAssertEqual(targets.reply?.id, "readable")
        XCTAssertEqual(targets.react?.id, "readable")
        XCTAssertEqual(targets.star?.id, "unsent")
        XCTAssertNil(targets.edit)
    }

    /// A focused message is the only target: an own message can be replied to, and a command it does not offer stays
    /// off instead of acting on another message.
    func testAFocusedMessageIsTheOnlyTarget() {
        let own = LastMessageTargets(focused: sent("s1", canEdit: true))
        XCTAssertEqual(own.reply?.id, "s1")
        XCTAssertEqual(own.edit?.id, "s1")
        XCTAssertEqual(own.star?.id, "s1")
        XCTAssertNil(own.react, "this sent message takes no reactions")
        let unsent = LastMessageTargets(focused: received("unsent", retracted: true))
        XCTAssertNil(unsent.reply)
        XCTAssertNil(unsent.react)
        XCTAssertNil(unsent.edit)
        XCTAssertEqual(unsent.star?.id, "unsent")
    }

    func testAnEmptyChatHasNoTargets() {
        XCTAssertEqual(LastMessageTargets(messages: []), LastMessageTargets(messages: [received("x", unreadable: .decryptFailed)]))
        XCTAssertNil(LastMessageTargets(messages: []).star)
    }
}
