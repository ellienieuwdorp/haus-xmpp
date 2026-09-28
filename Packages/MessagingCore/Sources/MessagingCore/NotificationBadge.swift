import Foundation
import MessageStore

/// The app icon badge: unread messages (read state, plan D6) outside muted chats (plan D7). One pure rule, used by the
/// extension on its empty suppression content and posted requests, and by the app whenever unread totals change.
public enum NotificationBadge {
    /// Chats muted at `now` do not count; a mentions-only chat counts all of its unread messages.
    public static func count(unread: [String: Int], settings: [String: ChatNotificationSetting], now: Date = Date()) -> Int {
        unread.reduce(0) { total, entry in
            settings[entry.key]?.isMuted(at: now) == true ? total : total + max(0, entry.value)
        }
    }

    /// The account's badge from the store's unread counts and chat settings.
    public static func count(store: MessageStore, accountID: String, now: Date = Date()) async throws -> Int {
        count(unread: try await store.unreadCounts(accountID: accountID),
              settings: try await store.chatNotificationSettings(accountID: accountID), now: now)
    }
}
