import XCTest
import XMPPProtocol
@testable import HausXMPP

/// What the reaction picker offers: every quick choice, nothing the wire layer would refuse, and a search by name.
final class EmojiCatalogTests: XCTestCase {
    func testEveryEntryIsAReactionTheWireAccepts() {
        let entries = EmojiCatalog.all
        XCTAssertGreaterThan(entries.count, 1_000)
        XCTAssertEqual(Set(entries.map(\.emoji)).count, entries.count, "no emoji twice")
        for entry in entries { XCTAssertTrue(MessageContent.isEmoji(entry.emoji), entry.name) }
        // Components only mean something in a sequence.
        XCTAssertFalse(entries.contains { $0.emoji == "\u{1F3FB}" || $0.emoji == "\u{1F1F3}" })
    }

    func testTheQuickChoicesAreInTheCatalogue() {
        let emoji = Set(EmojiCatalog.all.map(\.emoji))
        for choice in TimelineReaction.choices { XCTAssertTrue(emoji.contains(choice), choice) }
    }

    func testFacesComeFirstAndFlagsLast() {
        XCTAssertEqual(EmojiCatalog.all.first?.emoji, "😀")
        XCTAssertTrue(EmojiCatalog.all.last?.name.hasPrefix("flag ") == true)
    }

    func testSearchMatchesEveryWordOfTheName() {
        // Unicode's names: "thumbs up sign", "heavy black heart".
        XCTAssertTrue(EmojiCatalog.search("thumbs up").contains { $0.emoji == "👍" })
        XCTAssertTrue(EmojiCatalog.search("black heart").contains { $0.emoji == "❤️" })
        XCTAssertEqual(EmojiCatalog.search("flag japan").map(\.emoji), ["🇯🇵"])
        XCTAssertTrue(EmojiCatalog.search("no such emoji at all").isEmpty)
        XCTAssertEqual(EmojiCatalog.search("  ").count, EmojiCatalog.all.count)
    }
}
