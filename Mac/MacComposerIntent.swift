import Observation

/// What the open chat's composer is doing besides holding a draft: replying to a message or editing one. Message
/// actions (the bubble's menu, the hover toolbar, menu commands) set it; the composer reads it, shows the reply or edit
/// bar, and clears it after a send or a cancel. One per open conversation, owned by `MacConversationView`.
@MainActor @Observable final class MacComposerIntent {
    /// The message a send quotes. Never set together with `editing`.
    private(set) var replyingTo: ChatMessage?
    /// The message a send replaces. Never set together with `replyingTo`.
    private(set) var editing: ChatMessage?
    /// Bumped whenever the composer should take keyboard focus; the composer focuses its text view on each change.
    private(set) var focusRequests = 0

    func reply(to message: ChatMessage) {
        editing = nil
        replyingTo = message
        focusComposer()
    }

    /// The composer fills its draft with the message's body when this changes to a message.
    func edit(_ message: ChatMessage) {
        replyingTo = nil
        editing = message
        focusComposer()
    }

    func cancelReply() { replyingTo = nil }
    func cancelEditing() { editing = nil }

    func focusComposer() { focusRequests += 1 }
}
