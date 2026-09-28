import SwiftUI
import MessageStore

/// The mute lengths the chat list and chat details offer.
enum MuteDuration: CaseIterable, Identifiable {
    case oneHour, eightHours, oneWeek, always

    var id: Self { self }
    var title: String {
        switch self {
        case .oneHour: "1 hour"
        case .eightHours: "8 hours"
        case .oneWeek: "1 week"
        case .always: "Always"
        }
    }
    /// The dialog's button: "For 1 hour" … "Always".
    var dialogTitle: String { self == .always ? title : "For \(title)" }

    func until(from now: Date) -> Date {
        switch self {
        case .oneHour: now.addingTimeInterval(3_600)
        case .eightHours: now.addingTimeInterval(8 * 3_600)
        case .oneWeek: now.addingTimeInterval(7 * 86_400)
        case .always: ChatNotificationSetting.always
        }
    }
}

extension ChatNotificationSetting {
    /// The details row's value: "All messages", "Mentions only", "Muted until 14:30" or "Muted".
    func summary(isGroup: Bool, now: Date = .now, calendar: Calendar = .current) -> String {
        if let until = mutedUntil, isMuted(at: now) {
            if isMutedAlways { return "Muted" }
            return "Muted until " + Self.untilText(until, now: now, calendar: calendar)
        }
        return level == .mentions && isGroup ? "Mentions only" : "All messages"
    }

    /// Today's end is a time; within a week, the weekday and time; further out, the date.
    static func untilText(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow, \(time)" }
        if date.timeIntervalSince(now) < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

/// The confirmation dialog that follows the chat list's Mute swipe action. Attached to the row, so on iOS 26 its
/// popover points at the chat being muted rather than at the middle of the list.
struct MuteDialog: ViewModifier {
    @Bindable var model: AppModel
    let chat: ChatSummary
    /// The chat whose Mute action is waiting for a duration; shared by every row.
    @Binding var muting: String?

    func body(content: Content) -> some View {
        content.confirmationDialog("Mute \(chat.displayTitle)?",
                                   isPresented: Binding(get: { muting == chat.id }, set: { if !$0, muting == chat.id { muting = nil } }),
                                   titleVisibility: .visible) {
            ForEach(MuteDuration.allCases) { duration in
                Button(duration.dialogTitle) { Task { await model.muteChat(chat.id, for: duration) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New messages still arrive here, without alerts.")
        }
    }
}

/// Chat and group details: what alerts from this chat. Choosing a level also ends a mute.
struct ChatNotificationRow: View {
    @Bindable var model: AppModel
    let chatID: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var setting: ChatNotificationSetting { model.notificationSetting(for: chatID) }
    private var isGroup: Bool { model.isGroup(chatID) }

    var body: some View {
        let setting = setting, muted = setting.isMuted()
        Menu {
            Section {
                choice("All messages", selected: !muted && (setting.level == .all || !isGroup)) {
                    await model.setNotificationLevel(chatID, .all)
                }
                if isGroup {
                    choice("Mentions only", selected: !muted && setting.level == .mentions) {
                        await model.setNotificationLevel(chatID, .mentions)
                    }
                }
            }
            Section("Mute") {
                if muted {
                    Button("Unmute", systemImage: "bell") { Task { await model.unmuteChat(chatID) } }
                }
                ForEach(MuteDuration.allCases) { duration in
                    Button(duration.title) { Task { await model.muteChat(chatID, for: duration) } }
                }
            }
        } label: {
            // Accessibility sizes stack the value under the title: side by side, both were cut short.
            let large = dynamicTypeSize.isAccessibilitySize
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications").foregroundStyle(.primary)
                        if large { Text(setting.summary(isGroup: isGroup)).foregroundStyle(.secondary) }
                    }
                } icon: {
                    DetailsIconTile(systemName: muted ? "bell.slash" : "bell")
                }
                Spacer(minLength: 8)
                if !large { Text(setting.summary(isGroup: isGroup)).foregroundStyle(.secondary).lineLimit(1) }
                Image(systemName: "chevron.up.chevron.down").imageScale(.small).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Notifications")
        .accessibilityValue(setting.summary(isGroup: isGroup))
        .accessibilityIdentifier("chatNotifications")
    }

    /// A checkmarked menu item: a Toggle is how a menu draws the leading checkmark.
    private func choice(_ title: String, selected: Bool, action: @escaping @MainActor () async -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { selected }, set: { _ in Task { await action() } }))
    }
}

/// The details screens' 30 pt tinted tile. The glyph keeps the body size of the default text setting: a glyph
/// that followed Dynamic Type drew outside the fixed tile at accessibility sizes.
struct DetailsIconTile: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
