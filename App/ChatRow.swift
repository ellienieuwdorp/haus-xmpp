import MessageStore
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ChatRow: View {
    let chat: ChatSummary
    let isGroup: Bool
    var avatar: PlatformImage? = nil
    var typing: [String]? = nil
    var avatarSize: CGFloat = 52
    var isBlocked = false

    // Short on screen; VoiceOver says the long form ("Monday" for "Mon", "21 November" for "21/11").
    static func timeLabel(_ date: Date, now: Date, calendar: Calendar, locale: Locale = .autoupdatingCurrent, spoken: Bool = false) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = spoken ? style.hour().minute() : style.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(time) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return spoken ? "Yesterday at \(date.formatted(time))" : "Yesterday"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo {
            return date.formatted(style.weekday(spoken ? .wide : .abbreviated))
        }
        guard spoken else {
            return date.formatted(.verbatim("\(day: .twoDigits)/\(month: .twoDigits)", locale: locale, timeZone: calendar.timeZone, calendar: calendar))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(style.day().month(.wide)) }
        return date.formatted(style.day().month(.wide).year())
    }

    private var lastStatus: TimelineMessage.Status? {
        guard chat.lastMessageIsOutgoing else { return nil }
        switch chat.lastMessageState {
        case .queued?: return .queued
        case .submitting?: return .submitting
        case .unconfirmed?: return .unconfirmed
        case .failed?: return .failed
        // Archive and carbon copies have no outbox row: the server already holds them.
        case .serverAccepted?, nil:
            return chat.lastMessageReceipt == .displayed ? .displayed : chat.lastMessageReceipt == .delivered ? .delivered : .serverAccepted
        }
    }

    // Read is the filled rings, not a colour.
    private func glyph(_ status: TimelineMessage.Status) -> Text {
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
        return Text(Image(platformImage: image))
    }

    private var preview: Text {
        if isBlocked { return Text("Blocked") }
        let text = chat.preview.isEmpty ? "Start a conversation" : chat.preview
        guard let status = lastStatus else { return Text(text) }
        // A label on the glyph alone is dropped when the row's button combines its text.
        return Text("\(glyph(status)) \(text)").accessibilityLabel("\(status.accessibilityDescription) \(text)")
    }

    var body: some View {
        HStack(spacing: 12) {
            ChatAvatar(key: chat.id, name: chat.displayTitle, image: avatar, isGroup: isGroup, size: avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(chat.displayTitle).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    // Follows the name rather than leading the time, whose width changes from row to row.
                    if isBlocked {
                        Text(Image(systemName: "hand.raised.fill")).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                    } else if chat.notification.isMuted() {
                        Text(Image(systemName: "bell.slash.fill")).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    Spacer(minLength: 8)
                    if let date = chat.lastMessageAt {
                        Text(Self.timeLabel(date, now: .now, calendar: .current))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                            .accessibilityLabel(Self.timeLabel(date, now: .now, calendar: .current, spoken: true))
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
                    // One trailing slot under the time (unread count, else pin) keeps both right-aligned down the list.
                    if chat.unreadCount > 0, !isBlocked {
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

// Sits on the preview's first line, so it never changes the row's height. The sent-bubble pair measures 4.5:1 for text
// in both appearances.
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
