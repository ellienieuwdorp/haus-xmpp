import AppKit
import SwiftUI

/// One message: the day header above it when the day changes, the sender's name in a group, and the bubble. The
/// bubble carries the message's menu (`MacMessageMenu`), on a right-click and from the hover toolbar beside it.
struct MacTimelineRow: View {
    let row: TimelineRow
    let isGroup: Bool
    let handlers: MacMessageHandlers
    let openAttachment: () -> Void
    @Environment(\.appearance) private var appearance
    @Environment(\.openURL) private var openURL
    @State private var hovering = false
    @State private var choosingEmoji = false
    @State private var selectAllRequests = 0
    /// Whether the gutter on the bubble's outer side holds the hover toolbar; in a narrow window it sits on the bubble.
    @State private var toolbarFitsBeside = true

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
                bubble
                if !message.reactions.isEmpty {
                    // Into the bubble's 6 pt bottom padding only, clear of the footer, with 2 pt kept below so the pills
                    // stay clear of the next message, as on the iPhone.
                    MacReactionRow(reactions: message.reactions, react: message.canReact ? { react($0) } : nil)
                        .padding(.horizontal, 10)
                        .padding(.top, -3)
                        .padding(.bottom, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
        }
        .padding(.top, row.startsRun && row.dateHeader == nil ? 8 : 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.accessibilityDescription)
        .accessibilityActions { accessibilityActions }
        #if DEBUG
        .onChange(of: MacDebugHooks.tour.messageRequest) { _, request in
            guard let request, request.messageID == message.id else { return }
            switch request.verb {
            case "select-text": perform(.selectText, link: nil)
            case "pick-emoji": choosingEmoji = true
            default: break
            }
        }
        #endif
    }

    private var bubble: some View {
        BubbleWidth {
            MacBubble(message: message, accent: appearance.accent, openAttachment: openAttachment, selectAllRequests: selectAllRequests,
                      textMenu: textMenu, cardMenu: { menu(link: $0) })
                .contextMenu { menu(link: nil) }
                .popover(isPresented: $choosingEmoji, arrowEdge: .top) {
                    MacEmojiPicker(message: message) { emoji in
                        choosingEmoji = false
                        react(emoji)
                    }
                }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            // The room between the bubble's outer edge and the scroll view's, in the bubble's own coordinates.
            guard let visible = proxy.bounds(of: .scrollView) else { return true }
            let room = message.isOutgoing ? -visible.minX : visible.maxX - proxy.size.width
            return room >= MacMessageToolbarSize.maximumWidth + 6 + 4
        } action: { toolbarFitsBeside = $0 }
        .overlay(alignment: toolbarFitsBeside ? (message.isOutgoing ? .leading : .trailing) : (message.isOutgoing ? .topLeading : .topTrailing)) {
            toolbar
        }
    }

    /// The menu's actions, then the file's, one per link and one per quick reaction, as on the iPhone.
    @ViewBuilder private var accessibilityActions: some View {
        ForEach(MessageActionMenu.items(for: message), id: \.kind) { item in
            Button(MacMessageMenu.title(for: item)) { perform(item.kind, link: nil) }
        }
        if let attachment = MessageActionMenu.attachmentAction(for: message) {
            Button(attachment.title, action: openAttachment)
        }
        ForEach(Array(message.links.enumerated()), id: \.offset) { _, link in
            Button(MessageActionMenu.linkAccessibilityTitle(for: link)) { openURL(link.url) }
        }
        ForEach(MessageActionMenu.reactionToggles(for: message), id: \.emoji) { toggle in
            Button(toggle.title) { react(toggle.emoji) }
        }
        MacAttachmentMenuItems(message: message)
    }

    private func textMenu(_ link: URL?) -> NSMenu {
        MacMessageNSMenu.make(MacMessageMenu(message: message, link: link), perform: perform, react: react, moreReactions: { choosingEmoji = true })
    }

    /// Beside the bubble in the gutter, on its outer side, centred on it; where the gutter is too narrow, over the
    /// bubble's top outer corner instead, so it never runs past the window's edge. Always laid out and only faded in,
    /// so a menu opened from it stays attached when the pointer moves into the menu and off the row.
    private var toolbar: some View {
        let replies = MessageActionMenu.items(for: message).contains { $0.kind == .reply }
        #if DEBUG
        let forced = MacDebugHooks.tour.hoveredMessage == message.id
        #else
        let forced = false
        #endif
        let shown = hovering || choosingEmoji || forced
        return MacMessageToolbar(message: message, react: { choosingEmoji = true },
                                 reply: replies ? { perform(.reply, link: nil) } : nil) { menu(link: nil) }
            .fixedSize()
            // Beside: 6 pt outside the bubble's leading edge (sent) or trailing edge (received). On the corner: 6 pt in
            // from that edge, centred on the bubble's top edge. Each guide from the size alone, as the second would
            // otherwise read the first.
            .alignmentGuide(.leading) { [beside = toolbarFitsBeside] in beside ? $0.width + 6 : -6 }
            .alignmentGuide(.trailing) { [beside = toolbarFitsBeside] in beside ? -6 : $0.width + 6 }
            .alignmentGuide(.top) { $0.height / 2 }
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .animation(.easeOut(duration: 0.12), value: shown)
    }

    private func menu(link: URL?) -> some View {
        MacMessageMenuContent(menu: MacMessageMenu(message: message, link: link), perform: perform, react: react, moreReactions: { choosingEmoji = true })
    }

    /// Select Text stays in the row, where the text view is; everything else goes to the conversation.
    private func perform(_ kind: MessageAction.Kind, link: URL?) {
        if kind == .selectText { selectAllRequests += 1 } else { handlers.perform(kind, message, link) }
    }

    private func react(_ emoji: String) { handlers.react(emoji, message) }
}

/// Caps the bubble at `min(560, 0.84 × width, width − 32)`, letting shorter bubbles hug
/// their text.
struct BubbleWidth: Layout {
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
struct MacBubble<CardMenu: View>: View {
    let message: TimelineMessage
    let accent: AccentTheme
    let openAttachment: () -> Void
    @Environment(\.openQuotedMessage) private var openQuotedMessage
    /// Bumped by Select Text.
    let selectAllRequests: Int
    /// The message's menu for a right-click on the text, with the link's items when it lands on one.
    let textMenu: (URL?) -> NSMenu
    /// The message's menu for a right-click on the preview card, which is a link too.
    @ViewBuilder let cardMenu: (URL) -> CardMenu
    @Environment(\.openURL) private var openURL

    private var textColor: Color { message.isOutgoing ? Color(platform: accent.bubbleText) : .primary }
    private var metaColor: Color { message.isOutgoing ? Color(platform: accent.bubbleText.withAlphaComponent(0.75)) : .secondary }
    /// The preview card's fill: the iPhone's reply-quote panel fill (`AccentTheme.panelFill`).
    private var panelFill: Color { Color(platform: accent.panelFill(outgoing: message.isOutgoing)) }

    private var showsMedia: Bool { message.attachment?.showsPreview == true && !message.showsPlaceholder }

    /// The text with its links (`TimelineMessage.links`) as link runs; a placeholder has none and is a quiet italic.
    private var text: NSAttributedString {
        let body = NSFont.preferredFont(forTextStyle: .body)
        let font = message.showsPlaceholder ? NSFont(descriptor: body.fontDescriptor.withSymbolicTraits(.italic), size: 0) ?? body : body
        let color: NSColor = switch (message.isOutgoing, message.showsPlaceholder) {
        case (true, false): accent.bubbleText
        case (true, true): accent.bubbleText.withAlphaComponent(0.75)
        case (false, false): .labelColor
        case (false, true): .secondaryLabelColor
        }
        let text = NSMutableAttributedString(string: message.displayedText, attributes: [.font: font, .foregroundColor: color])
        for link in message.links where NSMaxRange(link.range) <= text.length {
            text.addAttribute(.link, value: link.url, range: link.range)
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
                // A click on the quote shows the quoted message, paging it in when it is older than the loaded window.
                .contentShape(Rectangle())
                .onTapGesture { if let id = reply.messageID { openQuotedMessage(id) } }
                .pointerStyle(.link)
                .help("Show the quoted message")
                .accessibilityAction(named: "Show Quoted Message") { if let id = reply.messageID { openQuotedMessage(id) } }
            }
            if let attachment = message.attachment, !message.showsPlaceholder {
                Button(action: openAttachment) {
                    if attachment.showsPreview {
                        MacMediaPreview(attachment: attachment, tint: metaColor)
                            // Framed by the bubble colour, as on the iPhone: 3 pt to the bubble's edges.
                            .padding(.horizontal, -MacMediaPreview.edge)
                            .padding(.top, message.reply == nil ? -MacMediaPreview.top : 0)
                    } else {
                        // The name, then the size once it is here or where its download stands, as on the iPhone.
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(attachment.name.isEmpty ? attachment.kindLabel : attachment.name).foregroundStyle(textColor)
                                Text(attachment.localURL == nil ? attachment.downloadDetail
                                     : attachment.size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file) : attachment.mediaType)
                                    .font(.caption).foregroundStyle(metaColor)
                            }
                        } icon: {
                            Image(systemName: "doc").foregroundStyle(textColor)
                        }
                        .font(.callout)
                    }
                }
                .buttonStyle(.plain)
                .modifier(MacAttachmentDragSource(attachment: attachment))
                .help(attachment.localURL == nil ? attachment.downloadDetail : "Open in Quick Look")
            }
            if let preview = message.linkPreview, !message.showsPlaceholder {
                MacLinkPreviewCard(preview: preview, fill: panelFill, textColor: textColor, metaColor: metaColor)
                    .contextMenu { cardMenu(preview.url) }
                    .padding(.horizontal, -4)
            }
            if !message.displayedText.isEmpty {
                // Links are underlined, in the accent on received bubbles and in the text colour on the accent-filled sent ones.
                MacBubbleText(text: text, linkColor: message.isOutgoing ? accent.bubbleText : accent.tint, selectAllRequests: selectAllRequests,
                              menu: textMenu, openLink: { openURL($0) })
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
            // Laid out on every message and shown only when starred, as on the iPhone, so starring never widens the bubble.
            Image(systemName: "star.fill").font(.caption2)
                .opacity(message.isStarred ? 1 : 0)
                .accessibilityHidden(true)
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
/// into a single "+N" pill, as on the iPhone; the row's VoiceOver label still reads them all. Where the user can react,
/// a click on a pill adds that emoji as theirs, or takes theirs back.
struct MacReactionRow: View {
    let reactions: [TimelineReaction]
    /// Nil where the message takes no reactions: the pills only show.
    var react: ((String) -> Void)? = nil

    var body: some View {
        // The longest row that fits: every pill, then one fewer plus "+N", and so on.
        ViewThatFits(in: .horizontal) {
            ForEach((1...reactions.count).reversed(), id: \.self) { shown in
                HStack(spacing: 4) {
                    ForEach(reactions.prefix(shown), id: \.emoji) { reaction in
                        if let react {
                            Button { react(reaction.emoji) } label: { pill(reaction.emoji, count: reaction.count > 1 ? "\(reaction.count)" : nil) }
                                .buttonStyle(.plain)
                                .help(MessageActionMenu.reactionTitle(reaction.emoji, selected: reaction.isSelected))
                                .accessibilityLabel(reaction.accessibilityDescription)
                        } else {
                            pill(reaction.emoji, count: reaction.count > 1 ? "\(reaction.count)" : nil)
                                .accessibilityLabel(reaction.accessibilityDescription)
                        }
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
        .contentShape(Capsule())
    }
}

/// A photo's or video's still in the bubble, sized as the iPhone sizes it: 274 pt wide inside a 280 pt bubble (a 3 pt
/// frame of bubble colour), its height following the picture between 114 and 334 pt, corners concentric with the
/// bubble's. Until the file is here the frame keeps that size and says where the download stands.
struct MacMediaPreview: View {
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
struct MacQuoteStill: View {
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
struct MacTypingRow: View {
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
