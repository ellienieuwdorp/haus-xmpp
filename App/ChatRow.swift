import SwiftUI
#if os(iOS)
import UIKit
#endif

/// One chat in the chat list: avatar, name, time, preview with the last message's status, typing, unread count and pin.
/// The iPhone's list and the Mac's sidebar both draw it.
struct ChatRow: View {
    let chat: ChatSummary
    let isGroup: Bool
    var avatar: PlatformImage? = nil
    /// Who is typing in this chat; the preview gives way to it while it lasts.
    var typing: [String]? = nil
    /// The iPhone's 52 pt; the Mac sidebar's rows are smaller.
    var avatarSize: CGFloat = 52

    private static let dayMonth: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd/MM"; return f }()

    private var timeLabel: String? {
        guard let date = chat.lastMessageAt else { return nil }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let weekAgo = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: .now)), date >= weekAgo {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return Self.dayMonth.string(from: date)
    }

    /// Same marks as the bubble footer, drawn static and neutral: read is the filled rings, not a colour.
    private var stateGlyph: Text? {
        guard chat.lastMessageIsOutgoing else { return nil }
        let status: TimelineMessage.Status
        switch chat.lastMessageState {
        case .queued?: status = .queued
        case .submitting?: status = .submitting
        case .unconfirmed?: status = .unconfirmed
        case .failed?: status = .failed
        // Archive and carbon copies have no outbox row: the server already holds them.
        case .serverAccepted?, nil:
            status = chat.lastMessageReceipt == .displayed ? .displayed : chat.lastMessageReceipt == .delivered ? .delivered : .serverAccepted
        }
        #if os(iOS)
        let scale = UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: MessageStatusArt.designHeight) / MessageStatusArt.designHeight
        #else
        // The Mac has no Dynamic Type; the mark keeps its design size.
        let scale: CGFloat = 1
        #endif
        // Sits the ring on the text's x-height rather than its baseline.
        #if os(iOS)
        let image = MessageStatusArt.image(MessageStatusGlyph.glyph(for: status), scale: scale).withBaselineOffset(fromBottom: scale)
        #else
        let image = MessageStatusArt.image(MessageStatusGlyph.glyph(for: status), scale: scale)
        #endif
        return Text(Image(platformImage: image)).accessibilityLabel(status.accessibilityDescription)
    }

    private var preview: Text {
        let body = Text(chat.preview.isEmpty ? "Start a conversation" : chat.preview)
        guard let stateGlyph else { return body }
        return stateGlyph + Text(" ") + body
    }

    var body: some View {
        HStack(spacing: 12) {
            ChatAvatar(key: chat.id, name: chat.displayTitle, image: avatar, isGroup: isGroup, size: avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(chat.displayTitle).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    // Follows the name rather than leading the time, whose width changes from row to row.
                    if chat.notification.isMuted() {
                        Text(Image(systemName: "bell.slash.fill")).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    Spacer(minLength: 8)
                    if let timeLabel {
                        Text(timeLabel).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // The preview keeps its lines while hidden, so the row never changes height.
                    preview.font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(typing == nil ? 1 : 0)
                        .accessibilityHidden(typing != nil)
                        .overlay(alignment: .topLeading) {
                            if let typing {
                                Text(TypingTracker.description(typing, isGroup: isGroup))
                                    .font(.subheadline).foregroundStyle(Color(platform: AccentTheme.current.tint)).lineLimit(1)
                                    .transition(.opacity)
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: typing)
                    // One trailing slot under the time: the unread count, else the pin, so both stay right-aligned
                    // down the list. An unread pinned row still sits in the pinned group at the top.
                    if chat.unreadCount > 0 {
                        UnreadPill(count: chat.unreadCount)
                    } else if chat.isPinned {
                        Text(Image(systemName: "pin.fill")).font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// Incoming messages after the read pointer, in the row's trailing column under the time: a small accent capsule
/// that sits on the preview's first line, so it never changes the row's height. It takes the sent-bubble pair, measured
/// at 4.5:1 for text in both appearances (the tint with white text was 3.5:1 in dark mode).
struct UnreadPill: View {
    let count: Int
    @ScaledMetric(relativeTo: .footnote) private var height: CGFloat = 18

    var body: some View {
        Text(count > 999 ? "999+" : "\(count)")
            .font(.footnote.weight(.semibold)).monospacedDigit()
            .foregroundStyle(Color(platform: AccentTheme.current.bubbleText))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(minWidth: height, minHeight: height, maxHeight: height)
            .background(Color(platform: AccentTheme.current.bubble), in: Capsule())
            .fixedSize()
            .accessibilityLabel("\(count) unread")
    }
}
