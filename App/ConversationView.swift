import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A picked video comes across as a file so a large clip never sits in memory twice.
private struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "." + (received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension))
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

struct ConversationView: View {
    @Bindable var model: AppModel
    let chatID: String
    @State private var draft = ""
    @State private var showingPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var importingFile = false
    @State private var attaching = false
    @State private var query = ""
    @State private var showingSearch = false
    @State private var starredOnly = false
    @State private var retryMessageID: String?
    @State private var replyingTo: ChatMessage?
    @State private var reviewDismissed = false
    @FocusState private var composing: Bool

    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var title: String { AppModel.displayName(for: chatID, title: model.chats.first(where: { $0.id == chatID })?.title) }
    private var isGroup: Bool { model.isGroup(chatID) }
    private var encryptionRoute: ChatRoute { isGroup ? .groupDetails(chatID) : .encryption(chatID) }

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
                               attachment: message.attachment.map { TimelineAttachment(name: $0.name, mediaType: $0.mediaType, size: $0.size, width: $0.width, height: $0.height,
                                                                                       localURL: model.attachmentFiles[message.id]) },
                               sentAt: message.sentAt, status: message.transportState.flatMap { TimelineMessage.Status(rawValue: $0.rawValue) },
                               reply: message.reply.map { TimelineReply(author: authorName($0.senderID), body: $0.body) },
                               securityNotice: !model.isDemo && message.encryptionProfile == nil ? "Not encrypted" : nil,
                               reactions: emoji.map { TimelineReaction(emoji: $0, count: counts[$0]!, isSelected: selected.contains($0)) },
                               canReact: model.canReact(to: message),
                               reactionUnavailableReason: reactionUnavailableReason(message),
                               author: isGroup && !message.isOutgoing ? message.senderID : nil)
    }

    /// One line under the disabled reaction row; mirrors the checks in `AppModel.canReact`.
    private func reactionUnavailableReason(_ message: ChatMessage) -> String? {
        guard !model.canReact(to: message) else { return nil }
        if model.isDemo { return "Sample messages can't be reacted to" }
        guard message.encryptionProfile == "modern" || message.encryptionProfile == "legacy" else { return "This message isn't encrypted" }
        if isGroup { return model.canSend(to: chatID) ? "This message has no group identity yet" : "Join the group to react" }
        guard let overview = model.encryptionOverview else { return "Checking \(title)'s encryption version…" }
        if overview.profile == .modern, !message.wireIDAuthenticated { return "This message has no authenticated identity" }
        return message.wireID == nil ? "This message has no identity to react to" : "Reactions aren't available for this message"
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

    /// The composer text becomes the caption; the file is reduced and sealed before it is queued.
    private func attach(_ prepare: @escaping () async throws -> PreparedAttachment) {
        guard !attaching else { return }
        attaching = true
        let caption = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { attaching = false }
            do {
                let prepared = try await prepare()
                if await model.sendAttachment(prepared, caption: caption, to: chatID), draft.trimmingCharacters(in: .whitespacesAndNewlines) == caption { draft = "" }
            } catch {
                model.error = (error as? LocalizedError)?.errorDescription ?? "This file could not be attached."
            }
        }
    }

    private func attach(photo item: PhotosPickerItem) {
        let limit = model.attachmentLimit
        attach {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { throw AttachmentPreparer.Failure.unreadable }
                defer { try? FileManager.default.removeItem(at: movie.url) }
                return try await AttachmentPreparer.prepareVideo(movie.url, name: "video", limit: limit)
            }
            guard let data = try await item.loadTransferable(type: Data.self) else { throw AttachmentPreparer.Failure.unreadable }
            return try AttachmentPreparer.prepareImage(data, name: "photo", limit: limit)
        }
    }

    private func attach(file result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        let limit = model.attachmentLimit
        attach { try await AttachmentPreparer.prepare(fileURL: url, name: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension), limit: limit) }
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
                NavigationLink(value: ChatRoute.details(chatID)) {
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
                    if !model.isDemo { NavigationLink(value: encryptionRoute) { Label(isGroup ? "Group details" : "Encryption", systemImage: isGroup ? "person.2" : "lock.shield") } }
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
        .onChange(of: model.conversationIntent) { _, intent in
            // Chat Details pops back and leaves what it wants opened here.
            switch intent {
            case .search(let id) where id == chatID: model.conversationIntent = nil; composing = false; showingSearch = true
            case .starred(let id) where id == chatID: model.conversationIntent = nil; starredOnly = true
            default: break
            }
        }
        .onChange(of: model.encryptionNeedsReview) { reviewDismissed = false }
        .onChange(of: model.encryptionStatus) { reviewDismissed = false }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.item]) { attach(file: $0) }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            attach(photo: item)
        }
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
                NavigationLink(value: encryptionRoute) { Text("Review device").frame(maxWidth: .infinity).padding(.vertical, 4) }
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
                    if model.canSendAttachments, !isGroup {
                        Menu {
                            Button("Photo or Video", systemImage: "photo.on.rectangle") { showingPhotoPicker = true }
                            Button("File", systemImage: "doc") { importingFile = true }
                        } label: {
                            if attaching { ProgressView().frame(width: 34, height: 34) }
                            else { Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).frame(width: 34, height: 34).contentShape(Circle()) }
                        }
                        .disabled(attaching || model.isSending)
                        .padding(.leading, 5).padding(.bottom, 5)
                        .accessibilityLabel("Attach a file").accessibilityIdentifier("attachFile")
                    }
                    TextField(placeholder, text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.leading, model.canSendAttachments && !isGroup ? 4 : 16).padding(.vertical, 11)
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
