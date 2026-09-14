import Foundation
import MessageStore
import Testing
@testable import MessagingCore

@Test func notificationPreviewsRespectPrivacyAndBoundUntrustedDisplayText() {
    let message = StoredMessage(id: "one", accountID: "a", chatID: "peer", senderID: "peer",
        body: "\u{202E}" + String(repeating: "👩🏽‍💻", count: 300), encryptionProfile: "modern")
    let hidden = NotificationPreview(MessageNotification(latest: message, chatTitle: "Private sender", messageCount: 1, conversationCount: 1, previewsEnabled: false))
    #expect(hidden.title == "XMPP" && hidden.body == "New message" && !hidden.includesMessageText)
    #expect(!hidden.threadIdentifier.contains("peer"))
    let visible = NotificationPreview(MessageNotification(latest: message, chatTitle: "Peer", messageCount: 1, conversationCount: 1, previewsEnabled: true))
    #expect(visible.title == "Peer" && visible.includesMessageText)
    #expect(visible.body.count <= 241 && visible.body.utf8.count <= 1024 && !visible.body.contains("\u{202E}"))
    #expect(visible.body.hasPrefix("👩🏽‍💻") && visible.body.hasSuffix("…"))
    #expect(visible.threadIdentifier == hidden.threadIdentifier)
    let multiple = NotificationPreview(MessageNotification(latest: message, chatTitle: "Peer", messageCount: 3, conversationCount: 2, previewsEnabled: true))
    #expect(multiple.title == "3 new messages" && multiple.body == "In 2 conversations")
    #expect(!multiple.includesMessageText && multiple.threadIdentifier.isEmpty)
    let empty = NotificationPreview(MessageNotification(latest: nil, chatTitle: nil, messageCount: 0, conversationCount: 0, previewsEnabled: true))
    #expect(!empty.hasNewMessage && !empty.includesMessageText)
}

@Test func notificationPreviewBoundsAnOversizedSingleGrapheme() {
    let oversized = "a" + String(repeating: "\u{0301}", count: 3000)
    #expect(oversized.count == 1)
    let message = StoredMessage(id: "combining", accountID: "a", chatID: "peer", senderID: "peer",
        body: oversized, encryptionProfile: "modern")
    let preview = NotificationPreview(MessageNotification(latest: message, chatTitle: oversized,
        messageCount: 1, conversationCount: 1, previewsEnabled: true))
    #expect(preview.body == "…" && preview.title == "…")
    #expect(preview.body.utf8.count <= 1024 && preview.title.utf8.count <= 320)
}
