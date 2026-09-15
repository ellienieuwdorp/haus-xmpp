import SwiftUI
import OMEMO

/// One-line trust state for the conversation header and details pill.
struct ConversationTrust {
    enum Level { case verified, encrypted, review, other }
    let level: Level
    let subtitle: String

    var needsReview: Bool { level == .review }
    var icon: String {
        switch level {
        case .verified, .encrypted: "lock"
        case .review: "exclamationmark.shield"
        case .other: "lock.open"
        }
    }
    var color: Color {
        switch level {
        case .verified: .green
        case .encrypted: .secondary
        case .review: .orange
        case .other: .secondary
        }
    }
    var pill: String {
        switch level {
        case .verified: "Encrypted · Verified"
        case .encrypted: "Encrypted"
        case .review: "Needs review"
        case .other: subtitle
        }
    }
}

extension AppModel {
    /// A stored title, unless it is just the address; then the local part reads as the name.
    nonisolated static func displayName(for chatID: String, title: String?) -> String {
        if let title, !title.isEmpty, title != chatID { return title }
        return chatID.split(separator: "@", maxSplits: 1).first.map(String.init) ?? chatID
    }

    func trustSummary(for chatID: String) -> ConversationTrust {
        if isDemo { return ConversationTrust(level: .encrypted, subtitle: "Sample conversation") }
        if encryptionNeedsReview {
            return ConversationTrust(level: .review, subtitle: isGroup(chatID) ? "Devices need review" : "New device needs review")
        }
        if isGroup(chatID) {
            guard let group = groupChats[chatID], group.joined, group.issue == nil else { return ConversationTrust(level: .other, subtitle: encryptionStatus) }
            return ConversationTrust(level: .encrypted, subtitle: "\(group.members.count) members · Encrypted")
        }
        // Stored device trust decides, whatever the socket is doing; a chat with usable trusted
        // devices is encrypted while offline too, because queued messages are sealed for them.
        let theirs = encryptionOverview?.devices.filter { $0.jid == chatID && $0.active } ?? []
        guard theirs.contains(where: \.trust.permitsEncryption) else {
            return ConversationTrust(level: .other, subtitle: encryptionStatus)
        }
        let verified = !theirs.isEmpty && theirs.allSatisfy { $0.trust == .verified }
        return ConversationTrust(level: verified ? .verified : .encrypted, subtitle: verified ? "Encrypted · Verified" : "Encrypted")
    }
}

/// Initial-letter circle in the contact's stable hue; a glyph for rooms.
struct ChatAvatar: View {
    let name: String
    var isGroup = false
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color(uiColor: AvatarPalette.color(for: name)))
            if isGroup {
                Image(systemName: "person.2.fill").font(.system(size: size * 0.42, weight: .medium))
            } else {
                Text(name.prefix(1).uppercased()).font(.system(size: size * 0.42, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ChatDetailsView: View {
    @Bindable var model: AppModel
    let chatID: String
    var search: () -> Void = {}
    var starred: () -> Void = {}
    var openEncryption: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    private var title: String { AppModel.displayName(for: chatID, title: model.chats.first(where: { $0.id == chatID })?.title) }
    private var isGroup: Bool { model.isGroup(chatID) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 6) {
                        ChatAvatar(name: title, isGroup: isGroup, size: 96)
                        Text(title).font(.title.weight(.bold)).padding(.top, 6)
                        Text(chatID).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                        if !model.isDemo {
                            let trust = model.trustSummary(for: chatID)
                            Label(trust.pill, systemImage: trust.level == .verified ? "checkmark.shield" : trust.icon)
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .foregroundStyle(trust.color)
                                .background(trust.color.opacity(0.14), in: Capsule())
                                .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    HStack(spacing: 8) {
                        tile("Search", systemImage: "magnifyingglass", action: search)
                        tile("Starred", systemImage: "star", action: starred)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                Section {
                    Button {
                        openEncryption()
                    } label: {
                        HStack {
                            Label {
                                Text(isGroup ? "Group details" : "Devices & Encryption").foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: isGroup ? "person.2" : "key").foregroundStyle(.white)
                                    .frame(width: 30, height: 30).background(.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            Spacer()
                            if let count = deviceCount { Text(count).foregroundStyle(.secondary) }
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("encryptionDetails")
                }
            }
            .listStyle(.insetGrouped)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var deviceCount: String? {
        if isGroup, let members = model.groupChats[chatID]?.members.count { return "\(members) members" }
        guard let devices = model.encryptionOverview?.devices.filter({ $0.jid == chatID && $0.active }).count else { return nil }
        return "\(devices) \(devices == 1 ? "device" : "devices")"
    }

    private func tile(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3.weight(.medium))
                Text(title).font(.footnote.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 8)
            .foregroundStyle(.tint)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
