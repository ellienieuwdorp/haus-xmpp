import Foundation
import MessageStore

/// The read-state tests count what a notification run would present and then consume it, as the whole-batch claim did
/// before per-message delivery: how many messages, and the newest one.
struct NotificationBatch {
    let messageCount: Int
    let latest: StoredMessage?
}

extension MessageStore {
    func takeMessageNotification(accountID: String) throws -> NotificationBatch {
        let batch = try pendingNotifications(accountID: accountID)
        try removeNotificationCandidates(accountID: accountID, keys: batch.claimed)
        let latest = batch.candidates.last.flatMap { candidate -> StoredMessage? in
            if case let .message(message) = candidate.content { return message } else { return nil }
        }
        return NotificationBatch(messageCount: batch.claimed.count + batch.deferredCount, latest: latest)
    }
}
