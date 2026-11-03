import SwiftUI
import OMEMO

extension AppModel {
    nonisolated static func displayName(for chatID: String, title: String?) -> String {
        ContactName.display(for: chatID, title: title)
    }

    // Stored device trust decides, not the socket: queued messages are sealed for trusted devices while offline too. A
    // failed refresh never changes it.
    func trustSummary(for chatID: String) -> ConversationTrust {
        // The samples read as a verified chat would; the chat list says they are samples.
        if isDemo { return ConversationTrust(level: .verified, subtitle: "Encrypted · Verified") }
        return ConversationTrust(chatCapabilities(chatID).encryption, isGroup: isGroup(chatID), members: groupChats[chatID]?.members.count ?? 0)
    }
}

enum ConversationIntent: Equatable {
    case search(chatID: String), starred(chatID: String)
}

enum DetailsHeroMetrics {
    #if os(iOS)
    static let avatar: CGFloat = 96, top: CGFloat = 35, bottom: CGFloat = 36
    static let title = Font.title.weight(.bold)
    #else
    static let avatar: CGFloat = 64, top: CGFloat = 8, bottom: CGFloat = 12
    static let title = Font.title2.weight(.bold)
    #endif
}

struct ChatDetailsView: View {
    @Bindable var model: AppModel
    let chatID: String
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .title3) private var tileGlyphHeight: CGFloat = 24

    private var title: String { model.chatName(for: chatID) }
    private var isGroup: Bool { model.isGroup(chatID) }

    var body: some View {
        GroupedList {
            // In the header, outside the section's rounded background: as its last row the section's corner mask would
            // clip their bottom corners.
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
                // Rooms and the account itself are never linked to a contact.
                if !isGroup, chatID != model.accountID {
                    ChatContactRow(model: model, chatID: chatID)
                }
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
                .padding(.top, DetailsHeroMetrics.top)
                .padding(.bottom, DetailsHeroMetrics.bottom)
            }
            if !isGroup, chatID != model.accountID {
                ChatBlockingSection(model: model, chatID: chatID, name: title)
            }
        }
        .groupedListStyle()
        .toolbarTitleDisplayMode(.inline)
    }

    private var hero: some View {
        VStack(spacing: 6) {
            ChatAvatar(key: chatID, name: title, image: model.avatar(for: chatID), isGroup: isGroup, size: DetailsHeroMetrics.avatar)
                .task(id: "\(chatID)|\(model.session.isReady)") { await model.loadAvatar(for: chatID) }
            Text(title).font(DetailsHeroMetrics.title).padding(.top, 6)
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
        #if os(macOS)
        // A long name or address wraps in the narrow inspector; its lines stay centred under the avatar.
        .multilineTextAlignment(.center)
        #endif
        .padding(.vertical, 10)
    }

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
            // The two symbols differ in height, so the glyph box and tile height are fixed.
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3.weight(.medium)).frame(height: tileGlyphHeight)
                Text(title).font(.footnote.weight(.semibold))
            }
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 60)
            .foregroundStyle(.tint)
            .background(Color.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

extension AppModel {
    func chatCapabilities(_ chatID: String) -> ChatCapabilities {
        let group = groupChats[chatID]
        // Retained ciphertext alone is not a review: a carbon from another own client or a removed device's message
        // stays retained with nothing to approve.
        return ChatCapabilities.derive(isDemo: isDemo, isGroup: group != nil, knowledge: encryptionKnowledge(for: chatID),
                                       reviewPending: encryptionAttention.heldForTrust.contains(chatID),
                                       groupJoined: group?.joined == true,
                                       groupIssue: group?.issue, uploadAvailable: canSendAttachments, sessionReady: session.isReady)
    }
}
