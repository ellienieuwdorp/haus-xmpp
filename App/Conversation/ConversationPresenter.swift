import Foundation
import MessageStore
import OMEMO
import XMPPProtocol

/// What a conversation reads from the app model. `AppModel` provides it; the presenter only reads, so a view built
/// on it keeps observing exactly the model properties it touches.
@MainActor
protocol ConversationSource: AnyObject {
    var accountID: String { get }
    var isDemo: Bool { get }
    /// The open chat's loaded window, oldest first.
    var messages: [ChatMessage] { get }
    /// The chat `messages` belongs to; nil while a load is pending.
    var messagesLoadedFor: String? { get }
    var messageReactions: [String: [AuthenticatedReaction]] { get }
    var messageReceipts: [String: MessageEventKind] { get }
    var attachmentFiles: [String: URL] { get }
    var attachmentDownloads: [String: AttachmentDownloadState] { get }
    /// Our own link preview fetches, keyed by `LinkDetection.cacheKey`.
    var linkPreviews: [String: FetchedLinkPreview] { get }
    /// GET hosts of our upload slots, which never get a preview (`StoredMessage.linkPreviewCandidate`).
    var linkPreviewUploadHosts: Set<String> { get }
    var encryptionOverview: EncryptionOverview? { get }
    var openChatTyping: [String]? { get }
    func isGroup(_ chatID: String) -> Bool
    func canSend(to chatID: String) -> Bool
    func canReact(to message: StoredMessage) -> Bool
    func canRevise(_ message: StoredMessage) -> Bool
    func isBackfilling(chat: String) -> Bool
    /// A message is on screen: fetch its link preview if policy allows. Never called at insert time.
    func linkPreviewDisplayed(_ messageID: String)
}

/// Everything the open conversation shows that is derived from the model: which messages are listed under the current
/// search or starred filter, the timeline rows built from them, who is typing, and what an empty chat says. A value
/// rebuilt with each view update, so nothing here is cached or can go stale.
@MainActor
struct ConversationPresenter {
    let source: any ConversationSource
    let chatID: String
    private let currentTitle: () -> String
    var searchTerm: String
    var starredOnly: Bool
    var showingSearch: Bool

    /// `title` is read only where a line needs it, so a view that asks for an author line does not start observing the
    /// chat list.
    init(source: any ConversationSource, chatID: String, title: @escaping @autoclosure () -> String,
         searchTerm: String = "", starredOnly: Bool = false, showingSearch: Bool = false) {
        self.source = source
        self.chatID = chatID
        currentTitle = title
        self.searchTerm = searchTerm
        self.starredOnly = starredOnly
        self.showingSearch = showingSearch
    }

    /// The chat's display name, for quotes of the peer and the typing line of a direct chat.
    var title: String { currentTitle() }

    var isGroup: Bool { source.isGroup(chatID) }

    /// The loaded messages the timeline lists: all of them, or those matching the search or the starred filter.
    var messages: [ChatMessage] {
        source.messages.filter { message in
            (!starredOnly || message.isStarred) && (searchTerm.isEmpty || message.body.localizedCaseInsensitiveContains(searchTerm))
        }
    }

    /// The quote's author line: "you" for own messages, the sender in a group, the chat's name otherwise.
    func authorName(_ sender: String) -> String {
        sender == source.accountID ? "you" : (isGroup ? sender : title)
    }

    var emptyNotice: (title: String, systemImage: String)? {
        Self.emptyNotice(isEmpty: messages.isEmpty, loadedFor: source.messagesLoadedFor, chatID: chatID, searchTerm: searchTerm, starredOnly: starredOnly)
    }

    /// What an empty timeline says, or nil to leave it blank. Only an actual empty chat says so: while this chat's
    /// first page is pending, or the loaded page is still another chat's, the timeline stays blank.
    static func emptyNotice(isEmpty: Bool, loadedFor: String?, chatID: String, searchTerm: String,
                            starredOnly: Bool) -> (title: String, systemImage: String)? {
        guard isEmpty, loadedFor == chatID else { return nil }
        if !searchTerm.isEmpty { return ("No matching messages", "magnifyingglass") }
        return starredOnly ? ("No starred messages", "star") : ("No messages yet", "bubble.left")
    }

    /// The server's older history is being fetched for this chat. Search and the starred filter show a slice of
    /// history, so they show no loading cell.
    var loadingEarlier: Bool { !showingSearch && !starredOnly && source.isBackfilling(chat: chatID) }

    var timelineMessages: [TimelineMessage] {
        let messages = messages
        // One set per pass keeps the quoted-unsent lookup linear.
        let retracted = Set(source.messages.lazy.filter(\.isRetracted).map(\.id))
        // Quoted messages that are loaded: their kind and, once on disk, their file, for the quote's still.
        let quoted = Set(messages.lazy.compactMap { $0.reply?.messageID })
        var sources: [String: ChatMessage] = [:]
        if !quoted.isEmpty {
            for loaded in source.messages where quoted.contains(loaded.id) { sources[loaded.id] = loaded }
        }
        return messages.map { timelineMessage($0, retracted: retracted, sources: sources) }
    }

    /// The quote's still for a photo or video: its slot is kept from the reply snapshot's media type (or the loaded
    /// source's), so the bubble does not widen when the file downloads or an earlier page loads; the image itself
    /// shows once the source is loaded and on disk. Anything else quotes text alone.
    private func quoteStill(of reply: MessageReply, sources: [String: ChatMessage]) -> TimelineAttachment? {
        let source = sources[reply.messageID]
        guard let mediaType = reply.mediaType ?? source?.attachment?.mediaType,
              mediaType.hasPrefix("image/") || mediaType.hasPrefix("video/") else { return nil }
        return TimelineAttachment(name: source?.attachment?.name ?? "", mediaType: mediaType, size: source?.attachment?.size ?? 0,
                                  width: source?.attachment?.width, height: source?.attachment?.height,
                                  localURL: source?.attachment == nil ? nil : self.source.attachmentFiles[reply.messageID])
    }

    private func timelineMessage(_ message: ChatMessage, retracted: Set<String>, sources: [String: ChatMessage]) -> TimelineMessage {
        var counts: [String: Int] = [:]
        var selected: Set<String> = []
        for update in source.messageReactions[message.id] ?? [] {
            for emoji in update.reactions {
                counts[emoji, default: 0] += 1
                if update.actorID == source.accountID { selected.insert(emoji) }
            }
        }
        let emoji = counts.keys.sorted {
            let left = TimelineReaction.choices.firstIndex(of: $0) ?? Int.max
            let right = TimelineReaction.choices.firstIndex(of: $1) ?? Int.max
            return left == right ? $0 < $1 : left < right
        }
        // A quote keeps its snapshot text unless the quoted message has since been unsent.
        let quotedUnsent = message.reply.map { retracted.contains($0.messageID) } ?? false
        if let unreadable = message.unreadableReason {
            // A notice, not content: no quote, no reactions, no edits. An own send from another device keeps its
            // server-held check (receipts cannot project onto it); an incoming one shows no status.
            return TimelineMessage(id: message.id, body: "", isOutgoing: message.isOutgoing, isStarred: message.isStarred,
                                   sentAt: message.sentAt, status: status(message), author: isGroup && !message.isOutgoing ? message.senderID : nil,
                                   unreadable: unreadable)
        }
        let canRevise = source.canRevise(message)
        var shown = TimelineMessage(id: message.id, body: message.body, isOutgoing: message.isOutgoing, isStarred: message.isStarred,
                               attachment: message.attachment.map { TimelineAttachment(name: $0.name, mediaType: $0.mediaType, size: $0.size, width: $0.width, height: $0.height,
                                                                                       localURL: source.attachmentFiles[message.id],
                                                                                       download: source.attachmentDownloads[message.id] ?? .loading) },
                               sentAt: message.sentAt, status: status(message),
                               failure: message.transportState == .failed ? message.rejection.map { RejectionCopy.reason($0, isGroup: isGroup) } : nil,
                               reply: message.reply.map { TimelineReply(author: authorName($0.senderID), body: quotedUnsent ? "Message unsent" : $0.body,
                                                                        thumbnail: quotedUnsent ? nil : quoteStill(of: $0, sources: sources)) },
                               securityNotice: !source.isDemo && message.encryptionProfile == nil ? "Not encrypted" : nil,
                               reactions: message.isRetracted ? [] : emoji.map { TimelineReaction(emoji: $0, count: counts[$0]!, isSelected: selected.contains($0)) },
                               canReact: !message.isRetracted && source.canReact(to: message),
                               reactionUnavailableReason: message.isRetracted ? nil : reactionUnavailableReason(message),
                               author: isGroup && !message.isOutgoing ? message.senderID : nil,
                               isRetracted: message.isRetracted, isEdited: message.isEdited, canEdit: canRevise && !message.body.isEmpty, canUnsend: canRevise)
        (shown.linkPreview, shown.wantsLinkPreview) = linkPreview(for: message)
        return shown
    }

    /// The message's card: the preview it carries (the sender's, or ours frozen when it was sent) while that link is
    /// still in the body, else our fetch for its first previewable link. A carried preview shows whatever the fetch
    /// setting says; it brings its own image or none. `wanted` is true when the first previewable link has no card yet.
    private func linkPreview(for message: ChatMessage) -> (preview: TimelineLinkPreview?, wanted: Bool) {
        guard message.attachment == nil, !message.isRetracted, message.unreadableReason == nil else { return (nil, false) }
        let links = LinkScan.previewableURLs(in: message.body, uploadHosts: source.linkPreviewUploadHosts)
        guard let first = links.first else { return (nil, false) }
        if let carried = message.linkPreview, let url = links.first(where: { $0.absoluteString == carried.url }),
           let host = LinkDetection.displayHost(for: url) {
            let size = carried.imageData.flatMap { LinkScan.pixelSize(of: $0) }
            // Neither a title nor a readable image: nothing to draw, and nothing to fetch either, since it carried one.
            guard carried.title != nil || size != nil else { return (nil, false) }
            return (TimelineLinkPreview(url: url, host: host, title: carried.title, summary: carried.summary,
                                        image: size == nil ? nil : carried.imageData.map(TimelineLinkPreview.Image.data), imageAlt: carried.imageAlt,
                                        variant: TimelineLinkPreview.variant(imageWidth: size?.width, imageHeight: size?.height),
                                        imageAspectRatio: size.map { Double($0.width) / Double($0.height) }), false)
        }
        guard let fetched = source.linkPreviews[LinkDetection.cacheKey(for: first)], fetched.title != nil || fetched.imageFile != nil,
              let host = LinkDetection.displayHost(for: first) else { return (nil, true) }
        let size = fetched.imageFile == nil ? nil : fetched.imageWidth.flatMap { width in fetched.imageHeight.map { (width, $0) } }
        let variant = TimelineLinkPreview.variant(imageWidth: size?.0, imageHeight: size?.1)
        return (TimelineLinkPreview(url: first, host: host, title: fetched.title, summary: fetched.summary,
                                    image: variant == .text ? nil : fetched.imageFile.map(TimelineLinkPreview.Image.file), imageAlt: fetched.imageAlt,
                                    variant: variant, imageAspectRatio: variant == .text ? nil : size.map { Double($0.0) / Double($0.1) }), false)
    }

    /// Search and the starred filter show a slice of history, so nobody is shown typing at its end.
    var typing: TimelineTyping? {
        guard !showingSearch, !starredOnly, let names = source.openChatTyping, let first = names.first else { return nil }
        return TimelineTyping(author: isGroup ? names.map { ContactName.display(for: $0, title: nil) }.joined(separator: ", ") : nil, colorKey: first,
                              accessibilityLabel: TypingTracker.description(isGroup ? names : [title]))
    }

    /// A dashed ring while the outbox works, one ringed check once the server holds it, two rings once the
    /// peer confirmed delivery, filled once read (the glyphs stay the footer's neutral colour). Own messages
    /// from the archive or a carbon have no outbox row: the server already holds them, so they start at the
    /// single check.
    private func status(_ message: ChatMessage) -> TimelineMessage.Status? {
        guard message.isOutgoing else { return nil }
        let transport = message.transportState ?? .serverAccepted
        guard transport == .serverAccepted else { return TimelineMessage.Status(rawValue: transport.rawValue) }
        switch source.messageReceipts[message.id] {
        case .displayed?: return .displayed
        case .delivered?: return .delivered
        default: return .serverAccepted
        }
    }

    /// One line under the disabled reaction row; mirrors the checks in `AppModel.canReact`.
    private func reactionUnavailableReason(_ message: ChatMessage) -> String? {
        guard !source.canReact(to: message) else { return nil }
        if source.isDemo { return "Sample messages can't be reacted to" }
        guard message.encryptionProfile == "modern" || message.encryptionProfile == "legacy" else { return "This message isn't encrypted" }
        if isGroup { return source.canSend(to: chatID) ? "This message has no group identity yet" : "Join the group to react" }
        guard let overview = source.encryptionOverview else { return "Checking \(title)'s encryption version…" }
        if overview.profile == .modern, !message.wireIDAuthenticated { return "This message has no authenticated identity" }
        return message.wireID == nil ? "This message has no identity to react to" : "Reactions aren't available for this message"
    }

    /// Whether a received message coming on screen moves the read marker. Only the newest received message is marked;
    /// XEP-0333 makes a marker cover everything before it. A placeholder carries no wire ID, so the newest readable
    /// received message is the one the peer hears about; the newest received message of any kind is where this chat's
    /// read pointer goes.
    func marksDisplayed(_ id: String) -> Bool {
        id == source.messages.last(where: { !$0.isOutgoing && $0.unreadableReason == nil })?.id
            || id == source.messages.last(where: { !$0.isOutgoing })?.id
    }
}
