import Foundation
import MessageStore

/// What a composer's Send does with its draft, its files and its reply, shared by the iPhone and the Mac composers.
/// No UIKit or AppKit here.
enum ComposerPlan {
    /// Files one send may carry.
    static let trayLimit = 10

    /// Whether Send has something to send: text that is not only whitespace, or files. An edit needs text that differs
    /// from the message it rewrites.
    static func hasContent(draft: String, editing: ChatMessage?, hasFiles: Bool) -> Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let editing { return hasText && draft != editing.body }
        return hasFiles || hasText
    }

    /// Each file as its own message with no body, then the caption last: Conversations shows a file only when the
    /// body is exactly its link. Stops at the first refusal and reports how many files went and whether the caption did.
    @MainActor static func dispatch<File>(_ files: [File], caption: String, sendFile: @MainActor (File) async -> Bool,
                                          sendCaption: @MainActor (String) async -> Bool) async -> (files: Int, caption: Bool) {
        for (index, file) in files.enumerated() {
            guard await sendFile(file) else { return (index, false) }
        }
        guard !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (files.count, false) }
        return (files.count, await sendCaption(caption))
    }

    /// Which part of a send carries the composer's reply. A quote on a file would put fallback text before its link,
    /// so a reply rides on the caption. With no caption, the first file carries the bare reply reference where the
    /// chat allows one (`filesAloneCanReply`); elsewhere the files go and the reply stays in the composer for a caption.
    struct ReplyPlan {
        /// What the first file replies to; later files never carry a reply.
        let firstFile: ChatMessage?
        /// What the caption replies to; nil when there is no caption to send.
        let caption: ChatMessage?

        init(caption text: String, reply: ChatMessage?, filesAloneCanReply: (ChatMessage) -> Bool) {
            let captionless = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            firstFile = captionless ? reply.flatMap { filesAloneCanReply($0) ? $0 : nil } : nil
            caption = captionless ? nil : reply
        }

        /// Whether the reply is done once `dispatch` reports what went: its caption, or a file that carried it.
        func clearsReply(after sent: (files: Int, caption: Bool)) -> Bool { sent.caption || (firstFile != nil && sent.files > 0) }
    }

    /// The field's prompt while files wait in the tray: files alone go without a reply they cannot carry, so it says
    /// before Send that the reply needs a caption.
    static func trayPlaceholder(reply: ChatMessage?, filesAloneCanReply: (ChatMessage) -> Bool) -> String {
        guard let reply, ReplyPlan(caption: "", reply: reply, filesAloneCanReply: filesAloneCanReply).firstFile == nil else { return "Add a caption…" }
        return "Add a caption to reply…"
    }
}
