import SwiftUI

struct ConversationView: View {
    @Bindable var model: AppModel
    let chatID: String
    @State private var draft = ""
    @State private var query = ""
    @State private var showingSearch = false
    @State private var sheet: Sheet?
    @State private var pendingSheet: Sheet?
    @State private var starredOnly = false
    @State private var retryMessageID: String?
    @State private var replyingTo: ChatMessage?
    @State private var reviewDismissed = false
    @FocusState private var composing: Bool

    private enum Sheet: String, Identifiable {
        case details, encryption
        var id: String { rawValue }
    }

    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var title: String { AppModel.displayName(for: chatID, title: model.chats.first(where: { $0.id == chatID })?.title) }
    private var isGroup: Bool { model.isGroup(chatID) }

    private var messages: [ChatMessage] {
        model.messages.filter { message in
            (!starredOnly || message.isStarred) && (searchTerm.isEmpty || message.body.localizedCaseInsensitiveContains(searchTerm))
        }
    }

    private func authorName(_ sender: String) -> String {
        sender == model.accountID ? "you" : (isGroup ? sender : title)
    }

    private func timelineMessage(_ message: ChatMessage) -> TimelineMessage {
        var counts: [String: Int] = [:]
        var selected: Set<String> = []
        for update in model.messageReactions[message.id] ?? [] {
            for emoji in update.reactions {
                counts[emoji, default: 0] += 1
                if update.actorID == model.accountID { selected.insert(emoji) }
            }
        }
        let emoji = counts.keys.sorted {
            let left = TimelineReaction.choices.firstIndex(of: $0) ?? Int.max
            let right = TimelineReaction.choices.firstIndex(of: $1) ?? Int.max
            return left == right ? $0 < $1 : left < right
        }
        return TimelineMessage(id: message.id, body: message.body, isOutgoing: message.isOutgoing, isStarred: message.isStarred,
                               sentAt: message.sentAt, status: message.transportState.flatMap { TimelineMessage.Status(rawValue: $0.rawValue) },
                               reply: message.reply.map { TimelineReply(author: authorName($0.senderID), body: $0.body) },
                               securityNotice: !model.isDemo && message.encryptionProfile == nil ? "Not encrypted" : nil,
                               reactions: emoji.map { TimelineReaction(emoji: $0, count: counts[$0]!, isSelected: selected.contains($0)) },
                               canReact: model.canReact(to: message),
                               author: isGroup && !message.isOutgoing ? message.senderID : nil)
    }

    private var placeholder: String {
        if model.isDemo { return "Message" }
        if model.encryptionNeedsReview { return "Sending paused until you review" }
        return model.session.isReady ? "Message" : "Message · sends when connected"
    }

    private func send() {
        let text = draft
        let account = model.accountID
        let reply = replyingTo
        Task {
            if await model.send(text, to: chatID, replyingTo: reply), draft == text, model.accountID == account {
                draft = ""
                if replyingTo?.id == reply?.id { replyingTo = nil }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showingSearch {
                ConversationSearchBar(query: $query) {
                    showingSearch = false
                    query = ""
                }
                .frame(height: 56)
                .padding(.horizontal, 4)
                if !searchTerm.isEmpty {
                    Text(messages.isEmpty ? "No results in this conversation" : "\(messages.count) \(messages.count == 1 ? "message" : "messages") found")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }
            }
            if starredOnly {
                HStack {
                    Label("Starred messages", systemImage: "star.fill").font(.caption)
                    Spacer()
                    Button("Show all") { starredOnly = false }
                }.padding(.horizontal).padding(.vertical, 8)
            }
            if !model.isDemo, model.encryptionNeedsReview, !reviewDismissed {
                trustReviewCard
            }
            ConversationTimeline(messages: messages.map(timelineMessage), onToggleStar: { id in Task { await model.toggleStar(id) } }, onRetryMessage: { retryMessageID = $0 }, onReply: { id in
                guard let message = model.messages.first(where: { $0.id == id }) else { return }
                replyingTo = message
                showingSearch = false
                query = ""
                composing = true
            }, onReaction: { id, emoji in
                Task { await model.toggleReaction(emoji, messageID: id) }
            })
            .overlay {
                // Only an actual empty chat says so; while a load is pending the timeline stays blank.
                if messages.isEmpty, model.messagesLoadedFor == chatID {
                    ContentUnavailableView(!searchTerm.isEmpty ? "No matching messages" : (starredOnly ? "No starred messages" : "No messages yet"),
                                           systemImage: !searchTerm.isEmpty ? "magnifyingglass" : (starredOnly ? "star" : "bubble.left"))
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { sheet = .details } label: {
                    // Name only: trust lives in Chat Details and the review card, so the header never flickers.
                    HStack(spacing: 9) {
                        ChatAvatar(name: title, isGroup: isGroup, size: 36)
                        Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    }
                    // Leading toolbar items size to content; give the header a fixed width so the name isn't squeezed out.
                    .frame(width: 236, height: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityHint("Shows conversation details")
                .accessibilityIdentifier("chatDetails")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Search messages", systemImage: "magnifyingglass") { composing = false; showingSearch = true }
                    Button("Starred messages", systemImage: "star") { starredOnly = true }
                    if !model.isDemo { Button(isGroup ? "Group details" : "Encryption", systemImage: isGroup ? "person.2" : "lock.shield") { sheet = .encryption } }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Conversation options")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !showingSearch { composer }
        }
        .confirmationDialog("Send this message again?", isPresented: Binding(
            get: { retryMessageID != nil }, set: { if !$0 { retryMessageID = nil } }
        ), titleVisibility: .visible, presenting: retryMessageID) { id in
            Button("Send again") {
                Task { await model.retryMessage(id) }
                retryMessageID = nil
            }
            Button("Cancel", role: .cancel) { retryMessageID = nil }
        } message: { _ in
            Text("The recipient may already have it. Sending again could create a duplicate.")
        }
        .sheet(item: $sheet, onDismiss: {
            // Swapping the item while a sheet is up is unreliable; present the next one after dismissal.
            if let next = pendingSheet { pendingSheet = nil; sheet = next }
        }) { item in
            switch item {
            case .details:
                ChatDetailsView(model: model, chatID: chatID,
                                search: { sheet = nil; composing = false; showingSearch = true },
                                starred: { sheet = nil; starredOnly = true },
                                openEncryption: { pendingSheet = .encryption; sheet = nil })
            case .encryption:
                if isGroup { GroupDetailsView(model: model, room: chatID) }
                else { EncryptionDetailsView(model: model, chatID: chatID) }
            }
        }
        .onChange(of: model.encryptionNeedsReview) { reviewDismissed = false }
        .onChange(of: model.encryptionStatus) { reviewDismissed = false }
        .task(id: [chatID, model.accountID]) { await model.openChat(chatID) }
        .onDisappear { model.closeChat(chatID) }
    }

    private var trustReviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(.orange)
                    .frame(width: 36, height: 36).background(.orange.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(isGroup ? "Devices need review" : "\(title) added a new device").font(.subheadline.weight(.semibold))
                    Text("Check its fingerprint before sending. Until then, nothing you write here leaves this iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button { sheet = .encryption } label: { Text("Review device").frame(maxWidth: .infinity).padding(.vertical, 4) }
                    .buttonStyle(.borderedProminent)
                Button { reviewDismissed = true } label: { Text("Later").frame(maxWidth: .infinity).padding(.vertical, 4) }
                    .buttonStyle(.bordered)
            }
            .buttonBorderShape(.capsule)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 8).padding(.top, 4)
    }

    private var composer: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                if let reply = replyingTo {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Replying to \(authorName(reply.senderID))").font(.footnote.weight(.semibold)).foregroundStyle(.tint)
                            Text(reply.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button { replyingTo = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Cancel reply").accessibilityIdentifier("cancelReply")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14).padding(.vertical, 4)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                HStack(alignment: .bottom, spacing: 4) {
                    TextField(placeholder, text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.leading, 16).padding(.vertical, 11)
                        .focused($composing)
                        .accessibilityIdentifier("messageComposer")
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold))
                    }
                    .buttonStyle(CircularGlassButtonStyle(diameter: 34))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending || !model.canSend(to: chatID))
                    .accessibilityLabel("Send message").accessibilityIdentifier("sendMessage")
                }
                .frame(minHeight: 44)
                // A capsule at one line; the same radius keeps five lines readable.
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}
