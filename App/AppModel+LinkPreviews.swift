import Foundation
import MessageStore
import XMPPProtocol

// MARK: Link previews

// What the conversation and the composer ask of the model for link previews (docs/development/link-previews.md):
// fetches through `linkPreviewCenter` under `LinkPreviewPolicy`, and the composer's preview with the image reduced to
// what we send.
extension AppModel: ComposerLinkPreviewSource {
    /// Our own fetch results for the signed-in account, keyed by `LinkDetection.cacheKey`.
    var linkPreviews: [String: FetchedLinkPreview] {
        linkPreviewCenter.account == accountID ? linkPreviewCenter.results : [:]
    }

    /// Reads the hosts of the account's stored files (`linkPreviewUploadHosts`) once per account, before its timelines
    /// are published; a failed read is tried again on the next load.
    func loadLinkPreviewHosts(store: MessageStore, account: String) async {
        guard !account.isEmpty, linkPreviewHostsAccount != account else { return }
        linkPreviewHostsAccount = account
        let stored = try? await store.attachmentHosts(accountID: account)
        guard accountID == account else { return }
        guard let stored else { linkPreviewHostsAccount = nil; return }
        noteLinkPreviewHosts(stored)
    }

    /// Adds hosts that serve the account's files: a slot just taken, or files in a timeline being published.
    func noteLinkPreviewHosts(_ hosts: Set<String>) {
        guard !hosts.isSubset(of: linkPreviewUploadHosts) else { return }
        linkPreviewUploadHosts.formUnion(hosts)
    }

    func noteLinkPreviewHosts(of messages: [ChatMessage]) {
        noteLinkPreviewHosts(Set(messages.compactMap { $0.attachment?.url.flatMap { URL(string: $0) }?.host()?.lowercased() }))
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

    func composerLinkPreview(for url: URL) async -> ComposerLinkPreview.Content? {
        guard !isDemo, LinkSettings.shared.fetchPreviews, let host = LinkDetection.displayHost(for: url) else { return nil }
        useLinkPreviewAccount()
        guard let fetched = await linkPreviewCenter.preview(for: url) else { return nil }
        let thumbnail = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let file = fetched.imageFile, let data = try? Data(contentsOf: file) else { return nil }
            return LinkPreviewImaging.sentThumbnail(from: data, maximumBytes: MessageContent.LinkMetadata.maximumSentImageBytes)
        }.value
        return ComposerLinkPreview.Content(url: url, host: host, title: fetched.title, summary: fetched.summary,
                                           imageAlt: fetched.imageAlt, thumbnail: thumbnail)
    }

    /// The own preview `send` may store with `body`: ours, for the first previewable link of the body, within the
    /// bounds we send. Anything else is dropped rather than sent.
    static func acceptedOwnLinkPreview(_ preview: StoredLinkPreview?, body: String, uploadHosts: Set<String>) -> StoredLinkPreview? {
        guard let preview, preview.source == .own,
              LinkDetection.previewableURLs(in: body, uploadHosts: uploadHosts).first?.absoluteString == preview.url,
              preview.title != nil || preview.imageData != nil,
              (preview.imageData?.count ?? 0) <= MessageContent.LinkMetadata.maximumSentImageBytes,
              (preview.imageData == nil) == (preview.imageType == nil) else { return nil }
        return preview
    }

    private func useLinkPreviewAccount() {
        linkPreviewCenter.use(account: isDemo ? "" : accountID, folder: linkPreviewFolder)
    }
}
