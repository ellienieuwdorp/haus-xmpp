import SwiftUI
import MessageStore

enum MuteDuration: CaseIterable, Identifiable {
    case oneHour, eightHours, oneDay, oneWeek, always

    var id: Self { self }
    var title: String {
        switch self {
        case .oneHour: "1 hour"
        case .eightHours: "8 hours"
        case .oneDay: "1 day"
        case .oneWeek: "1 week"
        case .always: "Always"
        }
    }
    var dialogTitle: String { self == .always ? title : "For \(title)" }

    func until(from now: Date) -> Date {
        switch self {
        case .oneHour: now.addingTimeInterval(3_600)
        case .eightHours: now.addingTimeInterval(8 * 3_600)
        case .oneDay: now.addingTimeInterval(86_400)
        case .oneWeek: now.addingTimeInterval(7 * 86_400)
        case .always: ChatNotificationSetting.always
        }
    }
}

extension AppModel {
    func muteChat(_ chatID: String, for duration: MuteDuration) async {
        await muteChat(chatID, until: duration.until(from: .now))
    }
}

extension ChatNotificationSetting {
    func summary(isGroup: Bool, now: Date = .now, calendar: Calendar = .current) -> String {
        if let until = mutedUntil, isMuted(at: now) {
            if isMutedAlways { return "Muted" }
            return "Muted until " + Self.untilText(until, now: now, calendar: calendar)
        }
        return level == .mentions && isGroup ? "Mentions only" : "All messages"
    }

    static func untilText(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow, \(time)" }
        if date.timeIntervalSince(now) < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.day().month(.abbreviated).hour().minute()) }
        return date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }
}

// "Until…" opens on 8:00 tomorrow and refuses an end that has already passed.
enum MuteEnd {
    static func suggested(now: Date, calendar: Calendar) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    static func accepts(_ end: Date, now: Date) -> Bool { end > now }
}

// Names the account too, so an end chosen after an account switch mutes nothing.
struct MuteEndRequest: Identifiable {
    let chatID: String
    let account: String
    var id: String { account + "\u{0}" + chatID }
}

struct MuteUntilSheet: View {
    let model: AppModel
    let request: MuteEndRequest
    @Environment(\.dismiss) private var dismiss
    @State private var end: Date

    init(model: AppModel, request: MuteEndRequest, now: Date = .now, calendar: Calendar = .current) {
        self.model = model
        self.request = request
        _end = State(initialValue: MuteEnd.suggested(now: now, calendar: calendar))
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $end, in: Date.now..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .accessibilityIdentifier("muteUntilDate")
                DatePicker("Time", selection: $end, displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("muteUntilTime")
            }
            .groupedFormStyle()
            .navigationTitle("Mute Until")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Mute", action: mute)
                        .disabled(!MuteEnd.accepts(end, now: .now))
                        .accessibilityIdentifier("muteUntilConfirm")
                }
            }
        }
        .macSheetSize(width: 360, height: 500)
    }

    // The sheet may stay open past the chosen time, so the end is checked again at the tap.
    private func mute() {
        guard MuteEnd.accepts(end, now: .now), model.accountID == request.account else { return }
        let end = end, chatID = request.chatID
        dismiss()
        Task { await model.muteChat(chatID, until: end) }
    }
}

// Attached to the row, so on iOS 26 its popover points at the chat being muted.
struct MuteDialog: ViewModifier {
    @Bindable var model: AppModel
    let chat: ChatSummary
    @Binding var muting: String?
    @Binding var choosingEnd: MuteEndRequest?

    func body(content: Content) -> some View {
        content.confirmationDialog("Mute \(chat.displayTitle)?",
                                   isPresented: Binding(get: { muting == chat.id }, set: { if !$0, muting == chat.id { muting = nil } }),
                                   titleVisibility: .visible) {
            ForEach(MuteDuration.allCases) { duration in
                Button(duration.dialogTitle) { Task { await model.muteChat(chat.id, for: duration) } }
            }
            Button("Until…") { choosingEnd = MuteEndRequest(chatID: chat.id, account: model.accountID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New messages still arrive here, without alerts.")
        }
    }
}

// Choosing a level also ends a mute.
struct ChatNotificationRow: View {
    @Bindable var model: AppModel
    let chatID: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var choosingEnd: MuteEndRequest?

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
                Button("Until…") { choosingEnd = MuteEndRequest(chatID: chatID, account: model.accountID) }
            }
        } label: {
            // Accessibility sizes stack the value under the title; side by side, both are cut short.
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
        .sheet(item: $choosingEnd) { request in MuteUntilSheet(model: model, request: request).themedRoot() }
    }

    // A Toggle is how a menu draws the leading checkmark.
    private func choice(_ title: String, selected: Bool, action: @escaping @MainActor () async -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { selected }, set: { _ in Task { await action() } }))
    }
}

// The glyph keeps the default body size: one that follows Dynamic Type draws outside the fixed tile.
struct DetailsIconTile: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: IconTileMetrics.glyph + 2))
            .foregroundStyle(.white)
            .frame(width: IconTileMetrics.side, height: IconTileMetrics.side)
            .background(.tint, in: RoundedRectangle(cornerRadius: IconTileMetrics.radius, style: .continuous))
    }
}
