import Foundation
import Testing
@testable import XMPPProtocol

/// Card text is plain text: a sender or a page cannot reorder the host line with bidi controls, hide characters, or
/// break the card's line limits with newlines.
@Test func cardTextDropsControlsAndBidiAndCollapsesWhitespace() {
    let cases: [(String, String?)] = [
        ("  Council\n\napproves\tthe\u{2028}bridge  ", "Council approves the bridge"),
        ("evil\u{202E}gpj.exe\u{2066}x\u{2069}", "evilgpj.exex"),
        ("bell\u{07}\u{1B}[31m red\u{85}line", "bell[31m red line"),
        ("\u{200F}\u{200E}\n \u{0}", nil),
        ("Ünïcødé — 日本語 👍🏽", "Ünïcødé — 日本語 👍🏽"),
    ]
    for (input, expected) in cases {
        #expect(MessageContent.LinkMetadata.plainText(input) == expected, "\(input.debugDescription)")
    }
}
