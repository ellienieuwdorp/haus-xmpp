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

/// What Chat Details asks the conversation to open once it has popped back.
enum ConversationIntent: Equatable {
    case search(chatID: String), starred(chatID: String)
}

/// The trust capsule under a details hero; the small symbol keeps it a balanced pill.
struct TrustPill: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .imageScale(.small)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(minHeight: 26)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct ChatDetailsView: View {
    @Bindable var model: AppModel
    let chatID: String
    @Environment(\.dismiss) private var dismiss

    private var title: String { AppModel.displayName(for: chatID, title: model.chats.first(where: { $0.id == chatID })?.title) }
    private var isGroup: Bool { model.isGroup(chatID) }

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    ChatAvatar(key: chatID, name: title, image: model.avatars[chatID], isGroup: isGroup, size: 96)
                        .task(id: chatID) { await model.loadAvatar(for: chatID) }
                    Text(title).font(.title.weight(.bold)).padding(.top, 6)
                    Text(chatID).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    if !model.isDemo {
                        let trust = model.trustSummary(for: chatID)
                        TrustPill(text: trust.pill, systemImage: trust.level == .verified ? "checkmark.shield" : trust.icon, color: trust.color)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                HStack(spacing: 8) {
                    tile("Search", systemImage: "magnifyingglass") { leave(with: .search(chatID: chatID)) }
                    tile("Starred", systemImage: "star") { leave(with: .starred(chatID: chatID)) }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            Section {
                NavigationLink(value: isGroup ? ChatRoute.groupDetails(chatID) : .encryption(chatID)) {
                    HStack {
                        Label {
                            Text(isGroup ? "Group details" : "Devices & Encryption").foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: isGroup ? "person.2" : "key").foregroundStyle(.white)
                                .frame(width: 30, height: 30).background(.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        Spacer()
                        if let count = deviceCount { Text(count).foregroundStyle(.secondary) }
                    }
                }
                .accessibilityIdentifier("encryptionDetails")
            }
        }
        .listStyle(.insetGrouped)
        .toolbarTitleDisplayMode(.inline)
    }

    /// Pop back to the conversation and let it open the requested mode.
    private func leave(with intent: ConversationIntent) {
        model.conversationIntent = intent
        dismiss()
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
