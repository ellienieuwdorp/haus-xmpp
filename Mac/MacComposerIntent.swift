import Observation

@MainActor @Observable final class MacComposerIntent {
    private(set) var replyingTo: ChatMessage?
    private(set) var editing: ChatMessage?
    // A counter, so a repeated request still changes it; the composer focuses its text view on each change.
    private(set) var focusRequests = 0

    func reply(to message: ChatMessage) {
        editing = nil
        replyingTo = message
        focusComposer()
    }

    func edit(_ message: ChatMessage) {
        replyingTo = nil
        editing = message
        focusComposer()
    }

    func cancelReply() { replyingTo = nil }
    func cancelEditing() { editing = nil }

    func focusComposer() { focusRequests += 1 }
}
