import XCTest
@testable import HausXMPP

/// UIKit accepts a pending autocorrection when a finger lands on Send; the simulator never autocorrects, so the
/// rule that undoes it is checked here and the tap itself on a device.
@MainActor final class ComposerSendTextTests: XCTestCase {
    func testOnlyARewrittenLastWordIsUndone() {
        let cases: [(typed: String, current: String, sent: String?)] = [
            ("teh", "the", "teh"),
            ("See you tomorow", "See you tomorrow", "See you tomorow"),
            ("i", "I", "i"),
            ("dont", "don't", "dont"),
            ("alot", "a lot", "alot"),
            ("Same", "Same", nil),
            // Dictation finishing adds words or rewrites more than the last one; that text stands.
            ("hello", "hello world", nil),
            ("hello world", "Hello world.", nil),
        ]
        for (typed, current, sent) in cases {
            XCTAssertEqual(ComposerState.uncorrected(typed: typed, current: current), sent, "\(typed) → \(current)")
        }
    }

    func testSendTakesTheTextFromTheTouchOnce() {
        let state = ComposerState()
        state.draft = "teh"
        state.draftAtSendTouch = (state.draft, .now)
        state.draft = "the"
        XCTAssertEqual(state.draftForSend(), "teh")
        // The next Send without a fresh touch (VoiceOver, a keyboard) sends what is in the field.
        state.draft = "the"
        XCTAssertEqual(state.draftForSend(), "the")
    }
}
