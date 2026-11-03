import Foundation
import MessageStore

enum ComposerPlan {
    static let trayLimit = 10

    static func hasContent(draft: String, editing: ChatMessage?, hasFiles: Bool) -> Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let editing { return hasText && draft != editing.body }
        return hasFiles || hasText
    }

    // Conversations shows a file only when the body is exactly its link, so each file goes alone and the caption last.
    @MainActor static func dispatch<File>(_ files: [File], caption: String, sendFile: @MainActor (File) async -> Bool,
                                          sendCaption: @MainActor (String) async -> Bool) async -> (files: Int, caption: Bool) {
        for (index, file) in files.enumerated() {
            guard await sendFile(file) else { return (index, false) }
        }
        guard !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (files.count, false) }
        return (files.count, await sendCaption(caption))
    }

    // A quote on a file would put fallback text before its link, so a reply rides on the caption.
    struct ReplyPlan {
        let firstFile: ChatMessage?
        let caption: ChatMessage?

        init(caption text: String, reply: ChatMessage?, filesAloneCanReply: (ChatMessage) -> Bool) {
            let captionless = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            firstFile = captionless ? reply.flatMap { filesAloneCanReply($0) ? $0 : nil } : nil
            caption = captionless ? nil : reply
        }

        func clearsReply(after sent: (files: Int, caption: Bool)) -> Bool { sent.caption || (firstFile != nil && sent.files > 0) }
    }

    static func trayPlaceholder(reply: ChatMessage?, filesAloneCanReply: (ChatMessage) -> Bool) -> String {
        guard let reply, ReplyPlan(caption: "", reply: reply, filesAloneCanReply: filesAloneCanReply).firstFile == nil else { return "Add a caption…" }
        return "Add a caption to reply…"
    }
}
