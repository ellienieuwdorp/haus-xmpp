import Foundation
import MessageStore
import XMPPProtocol

/// The account's server drops stanzas from addresses it blocked (XEP-0191), but what arrived before the block, or from
/// a server that let something through, still sits in the store. Nothing from a blocked address alerts or badges.
extension MessageNotification {
    /// The batch without messages and reactions from blocked addresses, and without a blocked direct chat's messages.
    /// `claimed` is unchanged, so a run deletes their candidate rows without posting them.
    public func excludingBlocked(_ blocklist: XMPPBlocklist) -> MessageNotification {
        guard !blocklist.isEmpty else { return self }
        let shown = candidates.filter { !blocklist.blocks($0.senderID) && ($0.isGroup || !blocklist.blocks($0.chatID)) }
        let reactions = reactions.filter { !blocklist.blocks($0.actor.id) && ($0.isGroup || !blocklist.blocks($0.chatID)) }
        return MessageNotification(candidates: shown, claimed: claimed, deferredCount: deferredCount, deferredChatCount: deferredChatCount,
                                   previewsEnabled: previewsEnabled, reactions: reactions)
    }
}
