import SwiftUI
import OMEMO

/// One-line trust state for the details pill, presented from `ChatCapabilities.encryption`.
struct ConversationTrust {
    /// `pending`: nothing stored yet. No pill is drawn (its height is kept), so "not known yet" never reads as "off".
    enum Level { case verified, encrypted, review, pending, other }
    let level: Level
    let subtitle: String

    var needsReview: Bool { level == .review }
    var icon: String {
        switch level {
        case .verified, .encrypted, .pending: "lock"
        case .review: "exclamationmark.shield"
        case .other: "lock.open"
        }
    }
    var color: Color {
        switch level {
        case .verified: .green
        case .encrypted: .secondary
        case .review: .orange
        case .pending, .other: .secondary
        }
    }
    var pill: String {
        switch level {
        case .verified: "Encrypted · Verified"
        case .encrypted: "Encrypted"
        case .review: "Needs review"
        case .pending, .other: subtitle
        }
    }
}

extension AppModel {
    /// A stored title, unless it is just the address; then the local part reads as the name.
    nonisolated static func displayName(for chatID: String, title: String?) -> String {
        if let title, !title.isEmpty, title != chatID { return title }
        return chatID.split(separator: "@", maxSplits: 1).first.map(String.init) ?? chatID
    }

    /// Stored device trust decides, whatever the socket is doing: a chat with usable trusted devices is encrypted
    /// while offline too, because queued messages are sealed for them. A failed refresh never changes it.
    func trustSummary(for chatID: String) -> ConversationTrust {
        if isDemo { return ConversationTrust(level: .encrypted, subtitle: "Sample conversation") }
        let group = isGroup(chatID)
        switch chatCapabilities(chatID).encryption {
        case .pending:
            return ConversationTrust(level: .pending, subtitle: "")
        case .needsReview:
            return ConversationTrust(level: .review, subtitle: group ? "Devices need review" : "New device needs review")
        case .unavailable(let reason):
            return ConversationTrust(level: .other, subtitle: reason)
        case .encrypted(let verified):
            if group { return ConversationTrust(level: verified ? .verified : .encrypted, subtitle: "\(groupChats[chatID]?.members.count ?? 0) members · Encrypted") }
            return ConversationTrust(level: verified ? .verified : .encrypted, subtitle: verified ? "Encrypted · Verified" : "Encrypted")
        }
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
        // Label's default icon gap reads as two separate things at footnote size.
        HStack(spacing: 3) { Image(systemName: systemImage); Text(text) }
            .accessibilityElement(children: .combine)
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
    @ScaledMetric(relativeTo: .title3) private var tileGlyphHeight: CGFloat = 24

    private var title: String { AppModel.displayName(for: chatID, title: model.chats.first(where: { $0.id == chatID })?.title) }
    private var isGroup: Bool { model.isGroup(chatID) }

    var body: some View {
        List {
            // Hero and tiles are the section's header, outside its rounded background: as the last row they
            // lost their outer bottom corners to the section's larger corner mask.
            Section {
                NavigationLink(value: isGroup ? ChatRoute.groupDetails(chatID) : .encryption(chatID)) {
                    HStack {
                        Label {
                            Text(isGroup ? "Group details" : "Devices & Encryption").foregroundStyle(.primary)
                        } icon: {
                            DetailsIconTile(systemName: isGroup ? "person.2" : "key")
                        }
                        Spacer()
                        if let count = deviceCount { Text(count).foregroundStyle(.secondary) }
                    }
                }
                .accessibilityIdentifier("encryptionDetails")
                ChatNotificationRow(model: model, chatID: chatID)
            } header: {
                VStack(spacing: 0) {
                    hero
                    HStack(spacing: 8) {
                        tile("Search", systemImage: "magnifyingglass") { leave(with: .search(chatID: chatID)) }
                        tile("Starred", systemImage: "star") { leave(with: .starred(chatID: chatID)) }
                    }
                }
                // Undo the header's secondary caption styling, and keep the old sections' spacing.
                .foregroundStyle(.primary)
                .textCase(nil)
                .listRowInsets(EdgeInsets())
                .padding(.top, 35)
                .padding(.bottom, 36)
            }
        }
        .listStyle(.insetGrouped)
        .toolbarTitleDisplayMode(.inline)
    }

    private var hero: some View {
        VStack(spacing: 6) {
            ChatAvatar(key: chatID, name: title, image: model.avatars[chatID], isGroup: isGroup, size: 96)
                .task(id: "\(chatID)|\(model.session.isReady)") { await model.loadAvatar(for: chatID) }
            Text(title).font(.title.weight(.bold)).padding(.top, 6)
            Text(chatID).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            if !model.isDemo {
                let trust = model.trustSummary(for: chatID)
                // Pending keeps the pill's height, so the hero never shifts when the stored answer arrives.
                TrustPill(text: trust.level == .pending ? "Encrypted" : trust.pill,
                          systemImage: trust.level == .verified ? "checkmark.shield" : trust.icon, color: trust.color)
                    .opacity(trust.level == .pending ? 0 : 1)
                    .accessibilityHidden(trust.level == .pending)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    /// Pop back to the conversation and let it open the requested mode.
    private func leave(with intent: ConversationIntent) {
        model.conversationIntent = intent
        dismiss()
    }

    private var deviceCount: String? {
        if isGroup, let members = model.groupChats[chatID]?.members.count { return "\(members) members" }
        guard let devices = model.chatCapabilities(chatID).deviceCount else { return nil }
        return "\(devices) \(devices == 1 ? "device" : "devices")"
    }

    private func tile(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // A fixed glyph box and tile height: the two symbols differ in height, which made the tiles 60 and 60.67.
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3.weight(.medium)).frame(height: tileGlyphHeight)
                Text(title).font(.footnote.weight(.semibold))
            }
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 60)
            .foregroundStyle(.tint)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
