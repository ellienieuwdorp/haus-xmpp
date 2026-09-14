import SwiftUI

struct ConversationView: View {
    @Bindable var model: AppModel
    let chatID: String
    @State private var draft = ""
    @State private var query = ""
    @State private var showingSearch = false
    @State private var showingEncryption = false
    @State private var starredOnly = false
    @State private var retryMessageID: String?
    @State private var replyingTo: ChatMessage?
    @FocusState private var composing: Bool

    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var messages: [ChatMessage] {
        model.messages.filter { message in
            (!starredOnly || message.isStarred) && (searchTerm.isEmpty || message.body.localizedCaseInsensitiveContains(searchTerm))
        }
    }

    private func authorName(_ sender: String) -> String {
        sender == model.accountID ? "you" : (model.chats.first(where: { $0.id == chatID })?.title ?? sender)
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
                               canReact: model.canReact(to: message))
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
            } else {
                if model.isDemo {
                    Label("Sample conversation", systemImage: "flask").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                } else {
                    Button { showingEncryption = true } label: {
                        Label(model.encryptionStatus, systemImage: model.encryptionNeedsReview ? "exclamationmark.shield" : "lock")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            .frame(maxWidth: .infinity).frame(minHeight: 44)
                    }.buttonStyle(.plain).accessibilityIdentifier("encryptionDetails")
                }
            }
            if starredOnly {
                HStack {
                    Label("Starred messages", systemImage: "star.fill").font(.caption)
                    Spacer()
                    Button("Show all") { starredOnly = false }
                }.padding(.horizontal).padding(.bottom, 8)
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
                if messages.isEmpty {
                    ContentUnavailableView(!searchTerm.isEmpty ? "No matching messages" : (starredOnly ? "No starred messages" : "No messages yet"),
                                           systemImage: !searchTerm.isEmpty ? "magnifyingglass" : (starredOnly ? "star" : "bubble.left"))
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(model.chats.first(where: { $0.id == chatID })?.title ?? chatID)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Search messages", systemImage: "magnifyingglass") { composing = false; showingSearch = true }
                    Button("Starred messages", systemImage: "star") { starredOnly = true }
                    if !model.isDemo { Button("Encryption", systemImage: "lock.shield") { showingEncryption = true } }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Conversation options")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !showingSearch {
              VStack(spacing: 0) {
                if let reply = replyingTo {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: 3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Replying to \(authorName(reply.senderID))").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                            Text(reply.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button { replyingTo = nil } label: { Image(systemName: "xmark").font(.body) .frame(width: 44, height: 44) }
                            .accessibilityLabel("Cancel reply").accessibilityIdentifier("cancelReply")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16).padding(.trailing, 4).padding(.top, 10)
                }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(model.isDemo ? "Message" : (model.isConnected ? "Message" : "Message · sends when connected"), text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 15).padding(.vertical, 11)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
                    .focused($composing)
                    .accessibilityIdentifier("messageComposer")
                Button {
                    let text = draft
                    let account = model.accountID
                    let reply = replyingTo
                    Task {
                        if await model.send(text, to: chatID, replyingTo: reply), draft == text, model.accountID == account {
                            draft = ""
                            if replyingTo?.id == reply?.id { replyingTo = nil }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(CircularGlassButtonStyle(diameter: 44))
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
                .accessibilityLabel("Send message").accessibilityIdentifier("sendMessage")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
              }
              .background(.bar)
            }
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
        .sheet(isPresented: $showingEncryption) { EncryptionDetailsView(model: model, chatID: chatID) }
        .task(id: chatID) { await model.openChat(chatID) }
        .onDisappear { model.closeChat(chatID) }
    }
}
