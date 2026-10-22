import SwiftUI
import UIKit
import XCTest
@testable import HausXMPP

/// Send empties the composer's real text view along with the draft. SwiftUI pushes a cleared draft into the field
/// only in its next update; a keyboard edit landing before then used to write the whole sent text back.
@MainActor
final class ComposerClearTests: XCTestCase {
    /// The composer's field as `ConversationComposer` builds it.
    private struct Field: View {
        @Bindable var state: ComposerState
        var body: some View {
            TextField("Message", text: $state.draft, axis: .vertical)
                .lineLimit(1...5)
                .background(FieldAnchor { [state] in state.fieldAnchor = $0 })
        }
    }

    private var window: UIWindow!
    private var state: ComposerState!
    private var field: UITextView!

    override func setUp() async throws {
        state = ComposerState()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        // A window outside a scene cannot become key, and the field could not take the keyboard.
        window.windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        window.rootViewController = UIHostingController(rootView: Field(state: state))
        window.makeKeyAndVisible()
        settle()
        field = try XCTUnwrap(state.fieldAnchor.flatMap(ComposerState.textView(behind:)))
        XCTAssertTrue(field.becomeFirstResponder())
        settle()
    }

    override func tearDown() async throws {
        field?.resignFirstResponder()
        window.isHidden = true
        window = nil
        state = nil
        field = nil
    }

    /// Lets SwiftUI run its update pass.
    private func settle() { RunLoop.main.run(until: .now + 0.3) }

    private func assertEmpty(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.draft, "", file: file, line: line)
        XCTAssertEqual(field.text, "", file: file, line: line)
        XCTAssertTrue(field.isFirstResponder, "the keyboard stays up", file: file, line: line)
    }

    func testAKeyboardEditBeforeTheUpdateCannotBringTheTextBack() {
        field.insertText("see you tomorrow")
        settle()
        XCTAssertEqual(state.draft, "see you tomorrow")
        state.clearDraft()
        // Any keyboard edit makes SwiftUI read the field's text back into the draft.
        field.delegate?.textViewDidChange?(field)
        settle()
        assertEmpty()
    }

    func testAWordStillBeingComposedIsNotCommittedBack() {
        field.insertText("see you ")
        field.setMarkedText("tomor", selectedRange: NSRange(location: 5, length: 0))
        settle()
        XCTAssertEqual(state.draft, "see you tomor")
        state.clearDraft()
        field.unmarkText()
        settle()
        assertEmpty()
    }

    func testTypingAfterTheClearStartsAFreshDraft() {
        field.insertText("first")
        settle()
        state.clearDraft()
        field.insertText("second")
        settle()
        XCTAssertEqual(state.draft, "second")
        XCTAssertEqual(field.text, "second")
    }

    /// A failed send puts its text back into the emptied field.
    func testAFailureStillPutsTheTextBack() {
        field.insertText("see you tomorrow")
        settle()
        state.clearDraft()
        settle()
        state.draft = "see you tomorrow"
        settle()
        XCTAssertEqual(field.text, "see you tomorrow")
    }
}
