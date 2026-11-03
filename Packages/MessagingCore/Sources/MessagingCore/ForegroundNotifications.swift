import Foundation
import MessageStore
import XMPPProtocol

// The foreground claim posts the extension's own requests (same identifiers, threads, categories and text), so a
// banner and a later extension run never both show one message. Muted chats and read messages never become candidates.
extension NotificationPlanner {
    /// Older candidates are history the connection caught up on.
    public static let foregroundWindow: TimeInterval = 600

    /// Skips the chat being read and anything older than `window`, and claims the whole batch: what is not posted is
    /// dismissed. No deferred-chats summary.
    public static func foreground(_ batch: MessageNotification, accountID: String, readingChatID: String?, now: Date,
                                  window: TimeInterval = foregroundWindow) -> NotificationPlan {
        let shown = batch.candidates.filter { $0.chatID != readingChatID && now.timeIntervalSince($0.sentAt) <= window }
        let reactions = batch.reactions.filter { $0.chatID != readingChatID && now.timeIntervalSince($0.reactedAt) <= window }
        let plan = plan(MessageNotification(candidates: shown, claimed: [], previewsEnabled: batch.previewsEnabled, reactions: reactions),
                        accountID: accountID)
        return NotificationPlan(requests: plan.requests, claimed: batch.claimed, summarizesDeferredChats: false)
    }

    /// Expects one candidate per chat (`pendingNotifications(perChat: 1)`) and posts each whatever its age: one
    /// banner per chat, not per message. Skips the chat being read. A chat's reactions alert only when none of its
    /// messages does, and then only the newest. Chats past the cap get the deferred-chats summary. Claims the batch.
    public static func caughtUp(_ batch: MessageNotification, accountID: String, readingChatID: String?) -> NotificationPlan {
        let shown = batch.candidates.filter { $0.chatID != readingChatID }
        let alerting = Set(shown.map(\.chatID))
        var newestReaction: [String: Int] = [:]
        for (index, reaction) in batch.reactions.enumerated() where reaction.chatID != readingChatID && !alerting.contains(reaction.chatID) {
            newestReaction[reaction.chatID] = index
        }
        let reactions = batch.reactions.enumerated().filter { newestReaction[$0.element.chatID] == $0.offset }.map(\.element)
        return plan(MessageNotification(candidates: shown, claimed: batch.claimed, deferredCount: batch.deferredCount,
                                        deferredChatCount: batch.deferredChatCount, previewsEnabled: batch.previewsEnabled, reactions: reactions),
                    accountID: accountID)
    }
}

extension NotificationPresenter {
    /// Call under the transport lease. With `presents` false every candidate is dismissed. Posts best effort, then
    /// deletes exactly the claimed rows; a burst beyond the per-run cap dismisses the rest. Nothing from `blocklist`
    /// gets a banner. Returns the number posted.
    @discardableResult
    public func presentForeground(store: MessageStore, accountID: String, readingChatID: String?, presents: Bool,
                                  blocklist: XMPPBlocklist = XMPPBlocklist(), now: Date = Date()) async throws -> Int {
        guard presents else {
            try await store.dismissPendingMessageNotifications(accountID: accountID)
            return 0
        }
        let batch = try await store.pendingNotifications(accountID: accountID).excludingBlocked(blocklist)
        guard !batch.claimed.isEmpty || batch.deferredCount > 0 else { return 0 }
        let plan = NotificationPlanner.foreground(batch, accountID: accountID, readingChatID: readingChatID, now: now)
        return try await post(plan, batch: batch, store: store, accountID: accountID)
    }

    /// Call under the transport lease once catch-up and read-state sync are in. With `presents` false every candidate
    /// is dismissed. Returns the number posted.
    @discardableResult
    public func presentCaughtUp(store: MessageStore, accountID: String, readingChatID: String?, presents: Bool) async throws -> Int {
        guard presents else {
            try await store.dismissPendingMessageNotifications(accountID: accountID)
            return 0
        }
        let batch = try await store.pendingNotifications(accountID: accountID, perChat: 1)
        guard !batch.claimed.isEmpty || batch.deferredCount > 0 else { return 0 }
        let plan = NotificationPlanner.caughtUp(batch, accountID: accountID, readingChatID: readingChatID)
        return try await post(plan, batch: batch, store: store, accountID: accountID)
    }

    private func post(_ plan: NotificationPlan, batch: MessageNotification, store: MessageStore, accountID: String) async throws -> Int {
        var posted = 0
        for request in plan.requests {
            // The message is in the app already, so a failed banner does not keep its candidate.
            if (try? await add(request, store: store, accountID: accountID, { request in
                try await withTimeout(addTimeout, clock: clock) { try await posting.add(request) }
            })) != nil { posted += 1 }
        }
        try await store.removeNotificationCandidates(accountID: accountID, keys: plan.claimed)
        if batch.deferredCount > 0 { try await store.dismissPendingMessageNotifications(accountID: accountID) }
        return posted
    }
}
