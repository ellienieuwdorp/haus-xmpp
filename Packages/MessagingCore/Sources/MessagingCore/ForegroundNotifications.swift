import Foundation
import MessageStore
import XMPPProtocol

/// Foreground banners. While the app is in front and holds the transport lease it claims every
/// candidate its own connection committed, exactly as it always dismissed them, but first posts the extension's own
/// requests for the ones that are news somewhere else: same identifiers, threads, categories and text, so a banner and
/// a later extension run can never both show one message. Mute and read state need no rule here: a muted chat or a
/// message at or below the read pointer never became a candidate.
extension NotificationPlanner {
    /// How old a message may be and still show a banner. Older candidates are history the connection caught up on.
    public static let foregroundWindow: TimeInterval = 600

    /// The extension's plan for the candidates a foreground banner may show, messages and reactions alike:
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

    /// What a desktop app caught up on after waking or launching (`AttentionRules.holdsCatchUpBanners`): the batch
    /// holds one candidate per chat (`MessageStore.pendingNotifications(perChat: 1)`), its newest with "and N more",
    /// and each becomes one request whatever its age, so a night's messages are one banner per chat and not one per
    /// message. Not the chat the user is reading. A chat's reactions alert only when none of its messages does, and
    /// then only the newest. Chats past the run's cap get the deferred-chats summary, as an extension run's would.
    /// Claims the whole batch.
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
    /// The app's foreground claim, under its transport lease. With `presents` false (catching up, no notification
    /// permission) every candidate is dismissed without a banner. Otherwise the foreground plan is posted, best effort,
    /// and then exactly the claimed rows are deleted; a burst beyond the per-run cap dismisses the rest. Returns how
    /// many requests were posted. Nothing from an address in `blocklist` gets a banner.
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

    /// A desktop app's claim once a connection's catch-up and read-state sync are in: one banner per chat for
    /// everything held meanwhile (`NotificationPlanner.caughtUp`), under the transport lease. With `presents` false (no
    /// notification permission) every candidate is dismissed. Returns how many requests were posted.
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

    /// Posts a claim's plan, best effort, then deletes exactly the claimed rows; anything the batch deferred is
    /// dismissed.
    private func post(_ plan: NotificationPlan, batch: MessageNotification, store: MessageStore, accountID: String) async throws -> Int {
        var posted = 0
        for request in plan.requests {
            // The message is in the app already: a banner that fails to post is not worth keeping the candidate for.
            if (try? await add(request, store: store, accountID: accountID, { request in
                try await withTimeout(addTimeout) { try await posting.add(request) }
            })) != nil { posted += 1 }
        }
        try await store.removeNotificationCandidates(accountID: accountID, keys: plan.claimed)
        if batch.deferredCount > 0 { try await store.dismissPendingMessageNotifications(accountID: accountID) }
        return posted
    }
}
