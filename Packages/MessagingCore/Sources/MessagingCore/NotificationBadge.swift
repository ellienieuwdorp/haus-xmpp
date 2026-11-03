import Foundation
import MessageStore
import XMPPProtocol

/// The one badge rule for the extension and the app.
public enum NotificationBadge {
    /// Muted and blocked chats do not count; a mentions-only chat counts all its unread messages.
    public static func count(unread: [String: Int], settings: [String: ChatNotificationSetting], blocklist: XMPPBlocklist = XMPPBlocklist(),
                             now: Date = Date()) -> Int {
        unread.reduce(0) { total, entry in
            settings[entry.key]?.isMuted(at: now) == true || blocklist.blocks(entry.key) ? total : total + max(0, entry.value)
        }
    }

    public static func count(store: MessageStore, accountID: String, blocklist: XMPPBlocklist = XMPPBlocklist(), now: Date = Date()) async throws -> Int {
        count(unread: try await store.unreadCounts(accountID: accountID),
              settings: try await store.chatNotificationSettings(accountID: accountID), blocklist: blocklist, now: now)
    }
}
