import SwiftUI

/// The open chat, read-only. A placeholder until Phase 2 builds the Mac timeline and composer: it shows the rows the
/// shared presenter builds, in a SwiftUI `LazyVStack` that opens at the newest message in its first frame
/// (mac-timeline-spike.md, rule 4) and follows the bottom while the reader is there. No paging, no prepend hold, no
/// composer, no message menus yet.
struct MacConversationView: View {
    @Bindable var model: AppModel
    let chatID: String
    /// Opens the chat's details, where its devices are reviewed.
    var showDetails: () -> Void = {}
    @State private var nearBottom = true
    /// Rows laid out in the viewport now, so the start of reading marks the newest one the user can see.
    @State private var visibleRows: Set<String> = []

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
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(title)
        .navigationSubtitle(model.isDemo ? "Sample conversation" : model.trustSummary(for: chatID).pill)
        // Closed by the root when the selection moves on or the window closes: SwiftUI may build the detail column more
        // than once for one selection, and a late disappearance would close the chat the new view just opened.
        .task(id: [chatID, model.accountID]) { await model.openChat(chatID) }
    }

    private func timeline(_ presenter: ConversationPresenter) -> some View {
        let rows = TimelineItems.rows(for: presenter.timelineMessages)
        let typing = presenter.typing
        let tail = rows.last?.message.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.message.id) { row in
                        MacTimelineRow(row: row, isGroup: presenter.isGroup)
                            .id(row.message.id)
                            .onAppear {
                                visibleRows.insert(row.message.id)
                                markIfReading(row.message.id, presenter: presenter)
                            }
                            .onDisappear { visibleRows.remove(row.message.id) }
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
                guard let shown = rows.last(where: { visibleRows.contains($0.message.id) && presenter.marksDisplayed($0.message.id) }) else { return }
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
    @Environment(\.appearance) private var appearance

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
            BubbleWidth {
                MacBubble(message: message, accent: appearance.accent)
            }
            .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
        }
        .padding(.top, row.startsRun && row.dateHeader == nil ? 8 : 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.accessibilityDescription)
    }
}

/// Caps the bubble at `min(560, 0.84 × width, width − 32)` (mac-timeline-spike.md), letting shorter bubbles hug
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

/// Text, quote, attachment line and the quiet footer (edited, security notice, time, status mark) inside the bubble;
/// reaction pills hang off its outer bottom corner and reserve their own space below it.
private struct MacBubble: View {
    let message: TimelineMessage
    let accent: AccentTheme

    private var textColor: Color { message.isOutgoing ? Color(platform: accent.bubbleText) : .primary }
    private var metaColor: Color { message.isOutgoing ? Color(platform: accent.bubbleText.withAlphaComponent(0.75)) : .secondary }

    var body: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                if let reply = message.reply, !message.showsPlaceholder {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(reply.author).font(.caption.weight(.semibold))
                        Text(reply.body).font(.caption).lineLimit(2)
                    }
                    .foregroundStyle(textColor.opacity(0.85))
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Capsule().fill(textColor.opacity(0.5)).frame(width: 2) }
                }
                if let attachment = message.attachment, !message.showsPlaceholder {
                    Label(attachment.name.isEmpty ? attachment.kindLabel : attachment.name,
                          systemImage: attachment.isImage ? "photo" : attachment.isVideo ? "video" : "doc")
                        .font(.callout)
                        .foregroundStyle(textColor)
                }
                if !message.displayedText.isEmpty {
                    Text(message.displayedText)
                        .font(.body)
                        .italic(message.showsPlaceholder)
                        .foregroundStyle(message.showsPlaceholder ? metaColor : textColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                footer
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
            .background(message.isOutgoing ? accent.swatch : Color.tertiaryFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !message.reactions.isEmpty {
                reactions
                    .padding(.top, -6)
                    .padding(message.isOutgoing ? .trailing : .leading, 10)
            }
        }
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

    private var reactions: some View {
        HStack(spacing: 4) {
            ForEach(message.reactions, id: \.emoji) { reaction in
                HStack(spacing: 2) {
                    Text(reaction.emoji)
                    if reaction.count > 1 { Text("\(reaction.count)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                }
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.background, in: Capsule())
                .overlay { Capsule().strokeBorder(reaction.isSelected ? accent.swatch : Color.secondary.opacity(0.3), lineWidth: reaction.isSelected ? 1.5 : 0.5) }
                .accessibilityLabel(reaction.accessibilityDescription)
            }
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
