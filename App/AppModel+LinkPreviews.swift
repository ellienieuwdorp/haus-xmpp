import Foundation

// MARK: Link previews

// What the conversation asks of the model for link previews (docs/development/link-previews.md). The fetch center,
// the policy and the composer's preview are built behind these.
extension AppModel {
    /// Our own fetch results, keyed by `LinkDetection.cacheKey`.
    var linkPreviews: [String: FetchedLinkPreview] { [:] }

    /// GET hosts of our upload slots: links to them never get a preview.
    var linkPreviewUploadHosts: Set<String> { [] }

    /// A message with a link is on screen (iOS cell configure or prefetch, Mac row appear): fetch its preview if the
    /// setting, the sender and the cache allow. Never called at insert time.
    func linkPreviewDisplayed(_ messageID: String) {}
}
