import AppKit
import SwiftUI

// The cell hosts this at its record's `extrasFrame` and the measurer sizes the same view (`MacExtrasSizer`), so the
// two agree.
struct MacBubbleExtrasContent: View {
    let message: TimelineMessage
    let accent: AccentTheme
    let openAttachment: () -> Void
    let openQuote: (String) -> Void
    let menu: (URL?) -> MacMessageMenuContent

    private var textColor: Color { message.isOutgoing ? Color(platform: accent.bubbleText) : .primary }
    private var metaColor: Color { message.isOutgoing ? Color(platform: accent.bubbleText.withAlphaComponent(0.75)) : .secondary }
    private var panelFill: Color { Color(platform: accent.panelFill(outgoing: message.isOutgoing)) }

    @MainActor static func sizing(_ message: TimelineMessage) -> MacBubbleExtrasContent {
        MacBubbleExtrasContent(message: message, accent: .current, openAttachment: {}, openQuote: { _ in }, menu: { link in
            MacMessageMenuContent(menu: MacMessageMenu(message: message, link: link), perform: { _, _ in }, react: { _ in }, moreReactions: {})
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MacTimelineMetrics.partSpacing) {
            if let reply = message.reply {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(reply.author).font(.caption.weight(.semibold))
                        Text(reply.body).font(.caption).lineLimit(2)
                    }
                    .foregroundStyle(textColor.opacity(0.85))
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Capsule().fill(textColor.opacity(0.5)).frame(width: 2) }
                    if let still = reply.thumbnail {
                        Spacer(minLength: 0)
                        MacQuoteStill(attachment: still, tint: metaColor)
                    }
                }
                // A click on the quote shows the quoted message, paging it in when it is older than the loaded window.
                .contentShape(Rectangle())
                .onTapGesture { if let id = reply.messageID { openQuote(id) } }
                .pointerStyle(.link)
                .help("Show the quoted message")
                .contextMenu { menu(nil) }
            }
            if let attachment = message.attachment {
                Button(action: openAttachment) {
                    if attachment.showsPreview {
                        MacMediaPreview(attachment: attachment, tint: metaColor)
                            // Framed by the bubble colour, as on the iPhone: 3 pt to the bubble's edges.
                            .padding(.horizontal, -MacMediaPreview.edge)
                            .padding(.top, message.reply == nil ? -MacMediaPreview.top : 0)
                    } else {
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
                // Not a stop of its own in the window's keyboard focus: the keyboard opens the file from the message's
                // menu.
                .focusable(false)
                .modifier(MacAttachmentDragSource(attachment: attachment))
                .help(attachment.localURL == nil ? attachment.downloadDetail : "Open in Quick Look")
                .contextMenu { menu(nil) }
            }
            if let preview = message.linkPreview {
                MacLinkPreviewCard(preview: preview, fill: panelFill, textColor: textColor, metaColor: metaColor)
                    .contextMenu { menu(preview.url) }
                    .padding(.horizontal, -4)
            }
        }
    }
}

// The row's VoiceOver element speaks for all of it.
struct MacBubbleExtras: View {
    let content: MacBubbleExtrasContent
    let contentWidth: CGFloat
    let openLink: (URL) -> Void

    var body: some View {
        content
            // A reused cell hosts another message's: nothing it decoded or held for the last one carries over.
            .id(content.message.id)
            .frame(width: contentWidth, alignment: .leading)
            .padding(.horizontal, MacTimelineMetrics.bubblePaddingH)
            .padding(.top, MacTimelineMetrics.bubbleTop)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.openURL, OpenURLAction { url in
                openLink(url)
                return .handled
            })
            .accessibilityHidden(true)
    }
}

// Sized as on the iPhone; until the file is here the frame keeps that size and says where the download stands.
struct MacMediaPreview: View {
    let attachment: TimelineAttachment
    let tint: Color
    @State private var image: NSImage?

    nonisolated static let width: CGFloat = 274
    // From the bubble's content edge to its outer edge, less the 3 pt frame.
    nonisolated static let edge: CGFloat = 9
    nonisolated static let top: CGFloat = 5

    nonisolated static func height(for attachment: TimelineAttachment) -> CGFloat {
        min(334, max(114, (width / attachment.aspectRatio).rounded()))
    }

    init(attachment: TimelineAttachment, tint: Color) {
        self.attachment = attachment
        self.tint = tint
        // A still decoded before shows in the first frame, so a row that comes back never blinks.
        _image = State(initialValue: attachment.localURL.flatMap(AttachmentThumbnails.cached(for:)))
    }

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
        .frame(width: Self.width, height: Self.height(for: attachment))
        .clipShape(RoundedRectangle(cornerRadius: 16 - 3, style: .continuous))
        .contentShape(Rectangle())
        .task(id: attachment.localURL) {
            guard image == nil, let url = attachment.localURL else { return }
            let decoded = await AttachmentThumbnails.image(for: url, mediaType: attachment.mediaType)
            if !Task.isCancelled { image = decoded }
        }
    }
}

// Its slot is there from the first frame, so the quote never widens when the file arrives.
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
            let decoded = await AttachmentThumbnails.image(for: url, mediaType: attachment.mediaType)
            if !Task.isCancelled { image = decoded }
        }
    }
}

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
        .padding(.horizontal, MacTimelineMetrics.sidePadding)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(typing.accessibilityLabel)
    }
}

struct MacLoadingEarlierRow: View {
    static let label = "Loading earlier messages"

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(Self.label + "…").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label)
    }
}
