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

    func testKeycapsAreListedAndSkinTonesFoundByName() {
        XCTAssertTrue(EmojiCatalog.all.contains { $0.emoji == "1\u{FE0F}\u{20E3}" })
        XCTAssertFalse(EmojiCatalog.all.contains { $0.emoji == "👍🏽" }, "tones only in a search")
        let thumbs = EmojiCatalog.search("thumbs up").map(\.emoji)
        XCTAssertEqual(Array(thumbs.prefix(6)), ["👍", "👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"])
        XCTAssertEqual(EmojiCatalog.search("thumbs up medium-dark").map(\.emoji), ["👍🏾"])
        // A text-presentation base takes the tone without its selector.
        XCTAssertTrue(EmojiCatalog.search("white up pointing index dark").contains { $0.emoji == "\u{261D}\u{1F3FF}" })
        for entry in EmojiCatalog.search("skin tone") { XCTAssertTrue(MessageContent.isEmoji(entry.emoji), entry.name) }
    }

    func testAnEmojiTypedIntoTheSearchIsItsOwnResult() {
        // Joiner sequences have no name to search by.
        XCTAssertEqual(EmojiCatalog.search("🏳️‍🌈").map(\.emoji), ["🏳️‍🌈"])
        XCTAssertEqual(EmojiCatalog.search(" 👩🏽‍💻 🫶 👩🏽‍💻").map(\.emoji), ["👩🏽‍💻", "🫶"])
        XCTAssertEqual(EmojiCatalog.search("👍").first?.name, "thumbs up sign")
        // The text form of a pictograph means its emoji; a plain digit is not one.
        XCTAssertEqual(EmojiCatalog.search("\u{2764}").map(\.emoji), ["❤️"])
        XCTAssertFalse(EmojiCatalog.search("1").contains { $0.emoji.hasPrefix("1") })
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
