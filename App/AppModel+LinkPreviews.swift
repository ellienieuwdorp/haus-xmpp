import Foundation
import MessageStore
import OMEMO
import XMPPProtocol

extension AppModel: ComposerLinkPreviewSource {
    var linkPreviews: [String: FetchedLinkPreview] {
        linkPreviewCenter.account == accountID ? linkPreviewCenter.results : [:]
    }

    // Read before the account's timelines are published; a failed read is tried again on the next load.
    func loadLinkPreviewHosts(store: MessageStore, account: String) async {
        guard !account.isEmpty, linkPreviewHostsAccount != account else { return }
        linkPreviewHostsAccount = account
        let stored = try? await store.attachmentHosts(accountID: account)
        guard accountID == account else { return }
        guard let stored else { linkPreviewHostsAccount = nil; return }
        noteLinkPreviewHosts(stored)
    }

    func noteLinkPreviewHosts(_ hosts: Set<String>) {
        guard !hosts.isSubset(of: linkPreviewUploadHosts) else { return }
        linkPreviewUploadHosts.formUnion(hosts)
    }

    func noteLinkPreviewHosts(of messages: [ChatMessage]) {
        noteLinkPreviewHosts(Set(messages.compactMap { $0.attachment?.url.flatMap { URL(string: $0) }?.host()?.lowercased() }))
    }

    // Never called at insert time, so archive catch-up causes no fetch burst.
    func linkPreviewDisplayed(_ messageID: String) {
        guard let message = messages.first(where: { $0.id == messageID }),
              let url = message.linkPreviewCandidate(uploadHosts: linkPreviewUploadHosts), LinkDetection.isFetchable(url),
              // A preview that came with the message shows instead.
              message.linkPreview?.url != url.absoluteString, mayFetchLinkPreview(for: message) else { return }
        useLinkPreviewAccount()
        linkPreviewCenter.request(url)
    }

    func mayFetchLinkPreview(for message: StoredMessage) -> Bool {
        LinkPreviewPolicy.mayFetch(for: message, account: accountID, fetchesPreviews: LinkSettings.shared.fetchPreviews, isDemo: isDemo,
                                   roster: linkPreviewRosterEntry)
    }

    // Only a modern OMEMO seal has somewhere private for a preview (groups always; a direct chat once its version is
    // known). Elsewhere the composer shows no card and fetches nothing.
    func linkPreviewsTravel(to chatID: String) -> Bool {
        isGroup(chatID) || encryptionOverview(for: chatID)?.profile == .modern
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

    // Anything but our own preview of the body's first previewable link, within the send bounds, is dropped.
    static func acceptedOwnLinkPreview(_ preview: StoredLinkPreview?, body: String, uploadHosts: Set<String>) -> StoredLinkPreview? {
        guard let preview, preview.source == .own,
              LinkDetection.previewableURLs(in: body, uploadHosts: uploadHosts).first?.absoluteString == preview.url,
              preview.title != nil || preview.imageData != nil,
              (preview.imageData?.count ?? 0) <= MessageContent.LinkMetadata.maximumSentImageBytes,
              (preview.imageData == nil) == (preview.imageType == nil) else { return nil }
        return preview
    }

    func useLinkPreviewAccount() {
        linkPreviewCenter.use(account: isDemo ? "" : accountID, folder: linkPreviewFolder, cache: linkPreviewCache)
    }
}
