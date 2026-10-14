import Foundation
import MessageStore
import XMPPProtocol

// MARK: Link previews

// What the conversation asks of the model for link previews (docs/development/link-previews.md): fetches through
// `linkPreviewCenter` under `LinkPreviewPolicy`.
extension AppModel {
    /// Our own fetch results for the signed-in account, keyed by `LinkDetection.cacheKey`.
    var linkPreviews: [String: FetchedLinkPreview] {
        linkPreviewCenter.account == accountID ? linkPreviewCenter.results : [:]
    }

    /// GET hosts of our upload slots, as far as the open chat shows them: the hosts of the files we sent there.
    var linkPreviewUploadHosts: Set<String> {
        Set(messages.lazy.filter(\.isOutgoing).compactMap { $0.attachment?.url.flatMap(URL.init(string:))?.host()?.lowercased() })
    }

    /// A message with a link is on screen (iOS cell configure or prefetch, Mac row appear): fetch its preview if the
    /// setting, the sender and the cache allow. Never called at insert time, so archive catch-up causes no burst.
    func linkPreviewDisplayed(_ messageID: String) {
        guard let message = messages.first(where: { $0.id == messageID }),
              let url = message.linkPreviewCandidate(uploadHosts: linkPreviewUploadHosts), LinkDetection.isFetchable(url),
              // A preview that came with the message (the sender's, or the one we sent) shows instead.
              message.linkPreview?.url != url.absoluteString,
              LinkPreviewPolicy.mayFetch(for: message, account: accountID, fetchesPreviews: LinkSettings.shared.fetchPreviews, isDemo: isDemo,
                                         roster: linkPreviewRosterEntry) else { return }
        useLinkPreviewAccount()
        linkPreviewCenter.request(url)
    }

    private func useLinkPreviewAccount() {
        linkPreviewCenter.use(account: isDemo ? "" : accountID, folder: linkPreviewFolder)
    }
}
