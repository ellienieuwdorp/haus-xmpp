import Foundation
import MessageStore

/// Foreground banners (wave 2, stream E). While the app is in front and holds the transport lease it claims every
/// candidate its own connection committed, exactly as it always dismissed them, but first posts the extension's own
/// requests for the ones that are news somewhere else: same identifiers, threads, categories and text, so a banner and
/// a later extension run can never both show one message. Mute and read state need no rule here: a muted chat or a
/// message at or below the read pointer never became a candidate.
extension NotificationPlanner {
    /// How old a message may be and still show a banner. Older candidates are history the connection caught up on.
    public static let foregroundWindow: TimeInterval = 600

    /// The extension's plan for the candidates a foreground banner may show, messages and reactions (plan D8) alike:
    /// not the chat the user is reading (`LifecycleSignals.readingChat`: it is on screen), and nothing older than
    /// `window`. Claims the whole batch; what is not posted is dismissed. There is no deferred-chats summary in front
    /// of the app.
    public static func foreground(_ batch: MessageNotification, accountID: String, readingChatID: String?, now: Date,
                                  window: TimeInterval = foregroundWindow) -> NotificationPlan {
        let shown = batch.candidates.filter { $0.chatID != readingChatID && now.timeIntervalSince($0.sentAt) <= window }
        let reactions = batch.reactions.filter { $0.chatID != readingChatID && now.timeIntervalSince($0.reactedAt) <= window }
        let plan = plan(MessageNotification(candidates: shown, claimed: [], previewsEnabled: batch.previewsEnabled, reactions: reactions),
                        accountID: accountID)
        return NotificationPlan(requests: plan.requests, claimed: batch.claimed, summarizesDeferredChats: false)
    }
}

extension NotificationPresenter {
    /// The app's foreground claim, under its transport lease. With `presents` false (catching up, no notification
    /// permission) every candidate is dismissed without a banner. Otherwise the foreground plan is posted, best effort,
    /// and then exactly the claimed rows are deleted; a burst beyond the per-run cap dismisses the rest. Returns how
    /// many requests were posted.
    @discardableResult
    public func presentForeground(store: MessageStore, accountID: String, readingChatID: String?, presents: Bool,
                                  now: Date = Date()) async throws -> Int {
        guard presents else {
            try await store.dismissPendingMessageNotifications(accountID: accountID)
            return 0
        }
        let batch = try await store.pendingNotifications(accountID: accountID)
        guard !batch.claimed.isEmpty || batch.deferredCount > 0 else { return 0 }
        let plan = NotificationPlanner.foreground(batch, accountID: accountID, readingChatID: readingChatID, now: now)
        var posted = 0
        for request in plan.requests {
            // The message is in the app already: a banner that fails to post is not worth keeping the candidate for.
            if (try? await withTimeout(addTimeout, { try await posting.add(request) })) != nil { posted += 1 }
        }
        try await store.removeNotificationCandidates(accountID: accountID, keys: plan.claimed)
        if batch.deferredCount > 0 { try await store.dismissPendingMessageNotifications(accountID: accountID) }
        return posted
    }
}
