import Foundation
import MessageStore
import XMPPProtocol

// The server drops stanzas from blocked addresses (XEP-0191), but what arrived before the block or slipped through is
// still stored.
extension MessageNotification {
    /// `claimed` is unchanged, so a run deletes the blocked candidates' rows without posting them.
    public func excludingBlocked(_ blocklist: XMPPBlocklist) -> MessageNotification {
        guard !blocklist.isEmpty else { return self }
        let shown = candidates.filter { !blocklist.blocks($0.senderID) && ($0.isGroup || !blocklist.blocks($0.chatID)) }
        let reactions = reactions.filter { !blocklist.blocks($0.actor.id) && ($0.isGroup || !blocklist.blocks($0.chatID)) }
        return MessageNotification(candidates: shown, claimed: claimed, deferredCount: deferredCount, deferredChatCount: deferredChatCount,
                                   previewsEnabled: previewsEnabled, reactions: reactions)
    }
}
