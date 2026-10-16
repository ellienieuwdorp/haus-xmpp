import AppKit
import QuickLook
import SwiftUI

/// The open chat, read-only. A placeholder until the Mac has its own timeline and composer: it shows the rows the
/// shared presenter builds, in a SwiftUI `LazyVStack` that opens at the newest message in its first frame (scrolling
/// there after layout shows a visible jump) and follows the bottom while the reader is there. No paging, no prepend
/// hold, no composer yet. A bubble's right-click menu has the shared menu's Copy and Report. Links in bubbles open
/// through `LinkOpening`, and preview cards show as on the iPhone. Photos and videos show as framed stills and files
/// as a line; a click opens one in Quick Look, or asks for its download when it is not on this Mac yet.
struct MacConversationView: View {
    @Bindable var model: AppModel
    let chatID: String
    /// Opens the chat's details, where its devices are reviewed.
    var showDetails: () -> Void = {}
    @State private var nearBottom = true
    /// Rows laid out in the viewport now (LazyVStack's prefetch may add a row just past the edge), so the start of
    /// reading marks the newest one the user can see. Not observed: rows scrolling in and out must not rebuild the
    /// whole timeline, and only the `readingStarts` change reads it.
    @State private var visibleRows = VisibleRows()
    /// A message's Report, waiting for its confirmation.
    @State private var blockRequest: BlockRequest?
    /// A phone link was clicked: Call, Send Message or Copy.
    @State private var phoneLink: PhoneLink?
    /// A link could not be opened, so it was copied; the alert says why.
    @State private var copiedReason: String?
    /// An `xmpp:…?join` link to a group this account is not in: the join flow, with its address filled in.
    @State private var joiningGroup: String?
    /// The file shown in Quick Look.
    @State private var quickLook: URL?

    private var title: String { AppModel.displayName(for: chatID, title: model.chats.first { $0.id == chatID }?.title) }
    private var presenter: ConversationPresenter { ConversationPresenter(source: model, chatID: chatID, title: title) }

    var body: some View {
        let presenter = presenter
        Group {
            // Built only once this chat's first page is loaded, so the scroll view's initial offset is the tail of
            // real content, not of an empty stack.
            if model.messagesLoadedFor == chatID {
                timeline(presenter)
            } else {
                Color.clear
            }
        }
        .overlay {
            if let notice = presenter.emptyNotice {
                ContentUnavailableView(notice.title, systemImage: notice.systemImage)
            }
        }
        .safeAreaInset(edge: .top) {
            // Messages from a device nobody decided on wait, encrypted, until the user reviews it (the iPhone shows a
            // card in the chat); the review itself is on the details' Devices & Encryption page.
            if !model.isDemo, model.trustSummary(for: chatID).needsReview {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                    Text("New messages wait until you review this chat's devices.").font(.callout)
                    Spacer(minLength: 8)
                    Button("Review Devices…", action: showDetails)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 16).padding(.top, 8)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Where the composer will be: a blocked chat says so and offers Unblock.
            if model.isBlocked(chatID) {
                BlockedChatBar(model: model, chatID: chatID, name: title)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .blockConfirmation(model: model, request: $blockRequest)
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(title)
        .navigationSubtitle(model.trustSummary(for: chatID).pill)
        .toolbar {
            // The contact's picture before the name, as the iPhone's header shows it; a click opens the details.
            ToolbarItem(placement: .navigation) {
                Button(action: showDetails) {
                    ChatAvatar(key: chatID, name: title, image: model.avatars[chatID], isGroup: model.isGroup(chatID), size: 28)
                }
                .buttonStyle(.plain)
                .help("Show the chat's details")
                .accessibilityLabel("Chat Details")
                .task(id: "\(chatID)|\(model.session.isReady)") { await model.loadAvatar(for: chatID) }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .quickLookPreview($quickLook)
        // Closed by the root when the selection moves on or the window closes: SwiftUI may build the detail column more
        // than once for one selection, and a late disappearance would close the chat the new view just opened.
        .task(id: [chatID, model.accountID]) { await model.openChat(chatID) }
        .environment(\.openURL, OpenURLAction { url in open(url); return .handled })
        .confirmationDialog(phoneLink?.number ?? "", isPresented: Binding(get: { phoneLink != nil }, set: { if !$0 { phoneLink = nil } }),
                            titleVisibility: .visible, presenting: phoneLink) { link in
            Button("Call") { NSWorkspace.shared.open(link.call) }
            Button("Send message") { NSWorkspace.shared.open(link.message) }
            Button("Copy") { copy(link.number) }
        }
        .alert("Copied", isPresented: Binding(get: { copiedReason != nil }, set: { if !$0 { copiedReason = nil } }), presenting: copiedReason) { _ in
            Button("OK") {}
        } message: { Text($0) }
        .sheet(isPresented: Binding(get: { joiningGroup != nil }, set: { if !$0 { joiningGroup = nil } })) {
            NavigationStack {
                GroupJoinView(model: model, room: joiningGroup ?? "") { room in
                    joiningGroup = nil
                    model.requestRoute(.chat(room))
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { joiningGroup = nil } } }
            }
            .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 420)
            .themedRoot()
        }
    }

    /// Performs a link from a bubble or a card. Where it goes is `LinkOpening`'s decision, shared with the iPhone; web
    /// pages always open in the default browser.
    private func open(_ url: URL) {
        switch LinkOpening.destination(for: url, inAppBrowser: false) {
        case .web(let page, _), .map(let page):
            NSWorkspace.shared.open(page)
        case .phone(let number, let call, let message):
            phoneLink = PhoneLink(number: number, call: call, message: message)
        case .mail(let mail, let address):
            if !NSWorkspace.shared.open(mail) { copied(address, because: "No mail app is set up on this Mac, so the address was copied.") }
        case .chat(let address):
            guard address != chatID else { return }
            if model.isGroup(address) { model.requestRoute(.chat(address)); return }
            Task { if let chat = await model.createChat(address) { model.requestRoute(.chat(chat)) } }
        case .group(let room):
            if !model.isGroup(room) { joiningGroup = room } else if room != chatID { model.requestRoute(.chat(room)) }
        case .unsupported:
            copied(LinkOpening.copyText(for: url), because: "This link can’t be opened here, so it was copied.")
        }
    }

    /// A click on a photo, video or file: Quick Look once it is here, else its download (a file waiting for a click, or
    /// a failed one).
    private func openAttachment(of message: TimelineMessage) {
        guard let attachment = message.attachment, !message.showsPlaceholder else { return }
        if let url = attachment.localURL { quickLook = url } else if attachment.download.canRequest { model.downloadAttachment(message.id) }
    }

    private func copied(_ text: String, because reason: String) {
        copy(text)
        copiedReason = reason
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func timeline(_ presenter: ConversationPresenter) -> some View {
        let rows = TimelineItems.rows(for: presenter.timelineMessages)
        let typing = presenter.typing
        let tail = rows.last?.message.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.message.id) { row in
                        MacTimelineRow(row: row, isGroup: presenter.isGroup, report: { id in
                            blockRequest = BlockRequest(kind: .report, chatID: chatID, name: title, messageID: id)
                        }, openAttachment: { openAttachment(of: row.message) })
                            .id(row.message.id)
                            .onAppear {
                                visibleRows.ids.insert(row.message.id)
                                markIfReading(row.message.id, presenter: presenter)
                                // Fetched on display, never at insert, under the model's policy (setting, contact, demo).
                                if row.message.wantsLinkPreview { model.linkPreviewDisplayed(row.message.id) }
                                // As on the iPhone: a file not on disk yet is fetched on sight when its chat allows it.
                                if row.message.attachment?.localURL == nil, row.message.attachment != nil, !row.message.showsPlaceholder {
                                    model.attachmentDisplayed(row.message.id)
                                }
                            }
                            .onDisappear { visibleRows.ids.remove(row.message.id) }
                    }
                    if let typing {
                        MacTypingRow(typing: typing).id(TimelineItems.typingID)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .scrollTargetLayout()
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < TimelineScrollPolicy.nearBottomDistance
            } action: { _, isNear in nearBottom = isNear }
            // Rule 3, simplified: a new tail (or the typing bubble) follows when the reader was at the bottom or sent it.
            .onChange(of: [tail, typing == nil ? nil : TimelineItems.typingID]) { _, _ in
                let ownSend = rows.last?.message.isOutgoing ?? false
                guard nearBottom || ownSend else { return }
                let target = typing == nil ? tail : TimelineItems.typingID
                if let target { proxy.scrollTo(target, anchor: .bottom) }
            }
            // The user started reading this chat (the app active, its window key and visible, the screen unlocked,
            // the user not idle): what was already on screen counts as seen now (critique G3).
            .onChange(of: model.readingStarts) { _, _ in
                guard let shown = rows.last(where: { visibleRows.ids.contains($0.message.id) && presenter.marksDisplayed($0.message.id) }) else { return }
                markIfReading(shown.message.id, presenter: presenter)
            }
        }
    }

    /// The newest received message marks the chat read when it shows. The model marks it only while the user reads
    /// this chat (`LifecycleSignals.readsOpenChat`, from `MacLifecycle`), so a row appearing in a window behind other
    /// apps marks nothing; the start of reading marks it then.
    private func markIfReading(_ id: String, presenter: ConversationPresenter) {
        guard presenter.marksDisplayed(id) else { return }
        Task { await model.markDisplayed(id) }
    }
}

/// One message: the day header above it when the day changes, the sender's name in a group, and the bubble.
private struct MacTimelineRow: View {
    let row: TimelineRow
    let isGroup: Bool
    let report: (String) -> Void
    let openAttachment: () -> Void
    @Environment(\.appearance) private var appearance
    @Environment(\.openURL) private var openURL

    private var message: TimelineMessage { row.message }

    var body: some View {
        VStack(spacing: 2) {
            if let header = row.dateHeader {
                Text(header)
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                    .padding(.vertical, 10)
            }
            if row.startsRun, let author = message.author {
                Text(ContactName.display(for: author, title: nil))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(platform: AvatarPalette.color(for: author)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
            }
            // The pills are the bubble's sibling, not part of it, so they never widen it: the bubble's width comes from
            // what it holds alone.
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 0) {
                BubbleWidth {
                    MacBubble(message: message, accent: appearance.accent, openAttachment: openAttachment)
                        .contextMenu { menu }
                }
                if !message.reactions.isEmpty {
                    // Into the bubble's 6 pt bottom padding only, clear of the footer, with 2 pt kept below so the pills
                    // stay clear of the next message, as on the iPhone.
                    MacReactionRow(reactions: message.reactions)
                        .padding(.horizontal, 10)
                        .padding(.top, -3)
                        .padding(.bottom, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
        }
        .padding(.top, row.startsRun && row.dateHeader == nil ? 8 : 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.accessibilityDescription)
        .accessibilityActions {
            menu
            if let attachment = message.attachment, !message.showsPlaceholder, attachment.localURL != nil || attachment.download.canRequest {
                Button(attachment.localURL == nil ? "Download" : "Open \(attachment.kindLabel)", action: openAttachment)
            }
            // One action per link, as on the iPhone.
            ForEach(Array(message.links.enumerated()), id: \.offset) { _, link in
                Button(MessageActionMenu.linkAccessibilityTitle(for: link)) { openURL(link.url) }
            }
        }
    }

    /// The shared menu's items the Mac performs so far.
    @ViewBuilder private var menu: some View {
        ForEach(MessageActionMenu.items(for: message).filter { [.copy, .report].contains($0.kind) }, id: \.kind) { item in
            Button(item.kind == .report ? item.title + "…" : item.title, systemImage: item.symbol) {
                switch item.kind {
                case .copy:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.body, forType: .string)
                case .report: report(message.id)
                default: break
                }
            }
        }
    }
}

/// Caps the bubble at `min(560, 0.84 × width, width − 32)`, letting shorter bubbles hug
/// their text.
private struct BubbleWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let bubble = subviews.first else { return .zero }
        let width = proposal.width ?? 600
        let cap = max(120, min(560, width * 0.84, width - 32))
        // The bubble's ideal width is its longest line; the footer's spacer adds nothing to it.
        let fitted = min(bubble.sizeThatFits(.unspecified).width, cap)
        return bubble.sizeThatFits(ProposedViewSize(width: fitted, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Text, quote, attachment line and the quiet footer (edited, security notice, time, status mark) inside the bubble.
/// Reaction pills are `MacReactionRow`, hung off its outer bottom corner by the row.
private struct MacBubble: View {
    let message: TimelineMessage
    let accent: AccentTheme
    let openAttachment: () -> Void

    private var textColor: Color { message.isOutgoing ? Color(platform: accent.bubbleText) : .primary }
    private var metaColor: Color { message.isOutgoing ? Color(platform: accent.bubbleText.withAlphaComponent(0.75)) : .secondary }
    /// The preview card's fill: the iPhone's reply-quote panel fill (`AccentTheme.panelFill`).
    private var panelFill: Color { Color(platform: accent.panelFill(outgoing: message.isOutgoing)) }
    /// Links are underlined, in the accent on received bubbles and in the text colour on the accent-filled sent ones.
    private var linkColor: Color { message.isOutgoing ? textColor : Color(platform: accent.tint) }

    private var showsMedia: Bool { message.attachment?.showsPreview == true && !message.showsPlaceholder }

    /// The text with its links (`TimelineMessage.links`) as link runs; a placeholder has none.
    private var text: AttributedString {
        let shown = message.displayedText
        var text = AttributedString(shown)
        for link in message.links {
            guard let written = Range(link.range, in: shown), let range = Range(written, in: text) else { continue }
            text[range].link = link.url
            text[range].swiftUI.underlineStyle = .single
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reply = message.reply, !message.showsPlaceholder {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(reply.author).font(.caption.weight(.semibold))
                        Text(reply.body).font(.caption).lineLimit(2)
                    }
                    .foregroundStyle(textColor.opacity(0.85))
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Capsule().fill(textColor.opacity(0.5)).frame(width: 2) }
                    // A quoted photo or video keeps its still at the trailing edge, as on the iPhone.
                    if let still = reply.thumbnail {
                        Spacer(minLength: 0)
                        MacQuoteStill(attachment: still, tint: metaColor)
                    }
                }
            }
            if let attachment = message.attachment, !message.showsPlaceholder {
                Button(action: openAttachment) {
                    if attachment.showsPreview {
                        MacMediaPreview(attachment: attachment, tint: metaColor)
                            // Framed by the bubble colour, as on the iPhone: 3 pt to the bubble's edges.
                            .padding(.horizontal, -MacMediaPreview.edge)
                            .padding(.top, message.reply == nil ? -MacMediaPreview.top : 0)
                    } else {
                        Label(attachment.name.isEmpty ? attachment.kindLabel : attachment.name, systemImage: "doc")
                            .font(.callout)
                            .foregroundStyle(textColor)
                    }
                }
                .buttonStyle(.plain)
                .help(attachment.localURL == nil ? attachment.downloadDetail : "Open in Quick Look")
            }
            if let preview = message.linkPreview, !message.showsPlaceholder {
                MacLinkPreviewCard(preview: preview, fill: panelFill, textColor: textColor, metaColor: metaColor)
                    .padding(.horizontal, -4)
            }
            if !message.displayedText.isEmpty {
                Text(text)
                    .font(.body)
                    .italic(message.showsPlaceholder)
                    .foregroundStyle(message.showsPlaceholder ? metaColor : textColor)
                    .tint(linkColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        // A photo fixes the bubble's width, as on the iPhone: a caption wraps under it rather than widening it.
        .frame(width: showsMedia ? MacMediaPreview.width - 2 * MacMediaPreview.edge : nil)
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
        .background(message.isOutgoing ? accent.swatch : Color.tertiaryFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if message.isStarred {
                Image(systemName: "star.fill").font(.caption2).accessibilityHidden(true)
            }
            if message.showsFooterText {
                Text(message.footerText).font(.caption2)
            }
            if let glyph = message.statusGlyph {
                Image(platformImage: MessageStatusArt.image(glyph, scale: 1))
                    .renderingMode(.template)
                    .frame(width: MessageStatusArt.slotWidth, height: MessageStatusArt.designHeight, alignment: .trailing)
            }
        }
        .foregroundStyle(metaColor)
    }
}

/// One line of reaction pills, as wide as they need. When they do not all fit the width offered, the last ones fold
/// into a single "+N" pill, as on the iPhone; the row's VoiceOver label still reads them all.
private struct MacReactionRow: View {
    let reactions: [TimelineReaction]

    var body: some View {
        // The longest row that fits: every pill, then one fewer plus "+N", and so on.
        ViewThatFits(in: .horizontal) {
            ForEach((1...reactions.count).reversed(), id: \.self) { shown in
                HStack(spacing: 4) {
                    ForEach(reactions.prefix(shown), id: \.emoji) { reaction in
                        pill(reaction.emoji, count: reaction.count > 1 ? "\(reaction.count)" : nil)
                            .accessibilityLabel(reaction.accessibilityDescription)
                    }
                    if shown < reactions.count { pill(nil, count: "+\(reactions.count - shown)") }
                }
            }
        }
    }

    /// The user's own reaction looks like anyone else's; its label says "including you".
    private func pill(_ emoji: String?, count: String?) -> some View {
        HStack(spacing: 2) {
            if let emoji { Text(emoji) }
            if let count { Text(count).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
        }
        .font(.caption)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.background, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5) }
    }
}

/// A photo's or video's still in the bubble, sized as the iPhone sizes it: 274 pt wide inside a 280 pt bubble (a 3 pt
/// frame of bubble colour), its height following the picture between 114 and 334 pt, corners concentric with the
/// bubble's. Until the file is here the frame keeps that size and says where the download stands.
private struct MacMediaPreview: View {
    let attachment: TimelineAttachment
    let tint: Color
    @State private var image: NSImage?

    static let width: CGFloat = 274
    /// From the bubble's content edge to its outer edge, less the 3 pt frame.
    static let edge: CGFloat = 9
    static let top: CGFloat = 5

    init(attachment: TimelineAttachment, tint: Color) {
        self.attachment = attachment
        self.tint = tint
        // A still decoded before shows in the first frame, so a row that comes back never blinks.
        _image = State(initialValue: attachment.localURL.flatMap(AttachmentThumbnails.cached(for:)))
    }

    private var height: CGFloat { min(334, max(114, (Self.width / attachment.aspectRatio).rounded())) }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                if attachment.isVideo {
                    Image(systemName: "play.circle.fill").font(.system(size: 40)).foregroundStyle(.white).shadow(radius: 4)
                }
            } else if attachment.localURL == nil, attachment.download != .loading {
                VStack(spacing: 6) {
                    Image(systemName: attachment.download == .failed ? "arrow.clockwise.circle"
                          : attachment.download == .mismatch || attachment.download == .tooLarge ? "exclamationmark.circle" : "arrow.down.circle")
                        .font(.title)
                    Text(attachment.downloadDetail).font(.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(tint)
                .padding(8)
            } else if attachment.localURL == nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: attachment.isVideo ? "video" : "photo").font(.title).foregroundStyle(tint)
            }
        }
        .frame(width: Self.width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16 - 3, style: .continuous))
        .contentShape(Rectangle())
        .task(id: attachment.localURL) {
            guard image == nil, let url = attachment.localURL else { return }
            image = await AttachmentThumbnails.image(for: url, mediaType: attachment.mediaType)
        }
    }
}

/// The small still of a quoted photo or video. Its slot is there from the first frame, so the quote never widens when
/// the file arrives; until then it holds the kind's symbol on a quiet fill.
private struct MacQuoteStill: View {
    let attachment: TimelineAttachment
    let tint: Color
    @State private var image: NSImage?

    init(attachment: TimelineAttachment, tint: Color) {
        self.attachment = attachment
        self.tint = tint
        _image = State(initialValue: attachment.localURL.flatMap(AttachmentThumbnails.cached(for:)))
    }

    var body: some View {
        ZStack {
            Rectangle().fill(tint.opacity(0.2))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: attachment.isVideo ? "video" : "photo").font(.caption).foregroundStyle(tint)
            }
        }
        .frame(width: TimelineReply.thumbnailSide, height: TimelineReply.thumbnailSide)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
        .task(id: attachment.localURL) {
            guard image == nil, let url = attachment.localURL else { return }
            image = await AttachmentThumbnails.image(for: url, mediaType: attachment.mediaType)
        }
    }
}

/// Someone is typing: a received-style bubble of dots after the newest message.
private struct MacTypingRow: View {
    let typing: TimelineTyping

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let author = typing.author {
                Text(author).font(.caption.weight(.semibold))
                    .foregroundStyle(Color(platform: AvatarPalette.color(for: typing.colorKey)))
                    .padding(.leading, 12)
            }
            Image(systemName: "ellipsis")
                .font(.body.weight(.bold)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.tertiaryFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .symbolEffect(.variableColor.iterative, options: .repeating)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(typing.accessibilityLabel)
    }
}

/// A clicked phone link's choices.
private struct PhoneLink {
    let number: String
    let call: URL
    let message: URL
}

/// A plain reference holder, so changing it never invalidates the view that owns it.
@MainActor private final class VisibleRows {
    var ids: Set<String> = []
}
