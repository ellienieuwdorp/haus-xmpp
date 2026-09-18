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

/// The draft lives outside `ConversationView`'s state so typing only invalidates the composer, never the timeline.
@MainActor @Observable final class ComposerState {
    var draft = ""
    /// Focus requested by the conversation; the composer lives in its own hosting controller, where a parent `@FocusState` cannot reach.
    var focused = false
}

struct ConversationView: View {
    @Bindable var model: AppModel
    let chatID: String
    @State private var composerState = ComposerState()
    @State private var showingPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var importingFile = false
    @State private var attaching = false
    @State private var query = ""
    @State private var showingSearch = false
    @State private var starredOnly = false
    @State private var retryMessageID: String?
    @State private var unsendMessageID: String?
    @State private var replyingTo: ChatMessage?
    /// The own message whose text is in the composer; sending queues a correction instead of a message.
    @State private var editing: ChatMessage?
    @State private var reviewDismissed = false

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

    private var timelineMessages: [TimelineMessage] {
        // One set per pass keeps the quoted-unsent lookup linear.
        let retracted = Set(model.messages.lazy.filter(\.isRetracted).map(\.id))
        return messages.map { timelineMessage($0, retracted: retracted) }
    }

    private func timelineMessage(_ message: ChatMessage, retracted: Set<String>) -> TimelineMessage {
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
        // A quote keeps its snapshot text unless the quoted message has since been unsent.
        let quotedUnsent = message.reply.map { retracted.contains($0.messageID) } ?? false
        let canRevise = model.canRevise(message)
        return TimelineMessage(id: message.id, body: message.body, isOutgoing: message.isOutgoing, isStarred: message.isStarred,
                               attachment: message.attachment.map { TimelineAttachment(name: $0.name, mediaType: $0.mediaType, size: $0.size, width: $0.width, height: $0.height,
                                                                                       localURL: model.attachmentFiles[message.id]) },
                               sentAt: message.sentAt, status: status(message),
                               reply: message.reply.map { TimelineReply(author: authorName($0.senderID), body: quotedUnsent ? "Message unsent" : $0.body) },
                               securityNotice: !model.isDemo && message.encryptionProfile == nil ? "Not encrypted" : nil,
                               reactions: message.isRetracted ? [] : emoji.map { TimelineReaction(emoji: $0, count: counts[$0]!, isSelected: selected.contains($0)) },
                               canReact: !message.isRetracted && model.canReact(to: message),
                               reactionUnavailableReason: message.isRetracted ? nil : reactionUnavailableReason(message),
                               author: isGroup && !message.isOutgoing ? message.senderID : nil,
                               isRetracted: message.isRetracted, isEdited: message.isEdited, canEdit: canRevise && !message.body.isEmpty, canUnsend: canRevise)
    }

    private func beginEditing(_ message: ChatMessage) {
        editing = message
        replyingTo = nil
        composerState.draft = message.body
        showingSearch = false
        query = ""
        composerState.focused = true
    }

    private func cancelEditing() {
        if editing != nil { composerState.draft = "" }
        editing = nil
    }

    /// Clock while the outbox works, one check once the server holds it, two once the peer confirmed
    /// delivery, tinted once read. Own messages from the archive or a carbon have no outbox row: the
    /// server already holds them, so they start at the single check.
    private func status(_ message: ChatMessage) -> TimelineMessage.Status? {
        guard message.isOutgoing else { return nil }
        let transport = message.transportState ?? .serverAccepted
        guard transport == .serverAccepted else { return TimelineMessage.Status(rawValue: transport.rawValue) }
        switch model.messageReceipts[message.id] {
        case .displayed?: return .displayed
        case .delivered?: return .delivered
        default: return .serverAccepted
        }
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

    private func send() {
        let state = composerState
        let text = state.draft
        let account = model.accountID
        let reply = replyingTo
        if let editing {
            Task {
                if await model.edit(messageID: editing.id, body: text), state.draft == text, model.accountID == account {
                    state.draft = ""
                    if self.editing?.id == editing.id { self.editing = nil }
                }
            }
            return
        }
        Task {
            if await model.send(text, to: chatID, replyingTo: reply), state.draft == text, model.accountID == account {
                state.draft = ""
                if replyingTo?.id == reply?.id { replyingTo = nil }
            }
        }
    }

    /// The composer text becomes the caption; the file is reduced and sealed before it is queued.
    private func attach(_ prepare: @escaping () async throws -> PreparedAttachment) {
        guard !attaching else { return }
        attaching = true
        let state = composerState
        let caption = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { attaching = false }
            do {
                let prepared = try await prepare()
                if await model.sendAttachment(prepared, caption: caption, to: chatID), state.draft.trimmingCharacters(in: .whitespacesAndNewlines) == caption { state.draft = "" }
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
            ConversationTimeline(messages: timelineMessages, composer: showingSearch ? nil : AnyView(composer), onToggleStar: { id in Task { await model.toggleStar(id) } }, onRetryMessage: { retryMessageID = $0 }, onReply: { id in
                guard let message = model.messages.first(where: { $0.id == id }) else { return }
                cancelEditing()
                replyingTo = message
                showingSearch = false
                query = ""
                composerState.focused = true
            }, onReaction: { id, emoji in
                Task { await model.toggleReaction(emoji, messageID: id) }
            }, onEdit: { id in
                guard let message = model.messages.first(where: { $0.id == id }) else { return }
                beginEditing(message)
            }, onUnsend: { composerState.focused = false; unsendMessageID = $0 }, onDisplayed: { id in
                // Only the newest received message is marked; XEP-0333 makes a marker cover everything before it.
                guard id == model.messages.last(where: { !$0.isOutgoing })?.id else { return }
                Task { await model.markDisplayed(id) }
            }, onRestoreComposerFocus: { composerState.focused = true }, onReachTop: { Task { await model.loadOlderMessages() } })
            // The controller pins the composer to the keyboard itself and insets the messages to match.
            .ignoresSafeArea(.keyboard)
            .ignoresSafeArea(.container, edges: .bottom)
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
                        ChatAvatar(key: chatID, name: title, image: model.avatars[chatID], isGroup: isGroup, size: 36)
                            .task(id: "\(chatID)|\(model.session.isReady)") { await model.loadAvatar(for: chatID) }
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
                    Button("Search messages", systemImage: "magnifyingglass") { composerState.focused = false; showingSearch = true }
                    Button("Starred messages", systemImage: "star") { starredOnly = true }
                    if !model.isDemo { NavigationLink(value: encryptionRoute) { Label(isGroup ? "Group details" : "Encryption", systemImage: isGroup ? "person.2" : "lock.shield") } }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Conversation options")
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
        .confirmationDialog("Unsend this message?", isPresented: Binding(
            get: { unsendMessageID != nil }, set: { if !$0 { unsendMessageID = nil } }
        ), titleVisibility: .visible, presenting: unsendMessageID) { id in
            Button("Unsend", role: .destructive) {
                Task { await model.unsend(messageID: id) }
                if editing?.id == id { cancelEditing() }
                unsendMessageID = nil
            }
            Button("Cancel", role: .cancel) { unsendMessageID = nil }
        } message: { _ in
            Text("It disappears here. \(title) may still see it if their app doesn't support unsending.")
        }
        .onChange(of: model.conversationIntent) { _, intent in
            // Chat Details pops back and leaves what it wants opened here.
            switch intent {
            case .search(let id) where id == chatID: model.conversationIntent = nil; composerState.focused = false; showingSearch = true
            case .starred(let id) where id == chatID: model.conversationIntent = nil; starredOnly = true
            default: break
            }
        }
        // Search and the starred filter read the loaded messages, so they need the whole window rather than the newest page.
        .onChange(of: showingSearch || starredOnly) { _, filtering in if filtering { Task { await model.loadOlderMessages(all: true) } } }
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

    /// Hosted inside the timeline controller, outside this view's environment, so the accent travels with it.
    private var composer: some View {
        ConversationComposer(model: model, chatID: chatID, state: composerState, replyingTo: $replyingTo, editing: editing, attaching: attaching,
                             authorName: authorName, onSend: send, onCancelEditing: cancelEditing,
                             onPickPhoto: { showingPhotoPicker = true }, onPickFile: { importingFile = true })
            .tint(Color(uiColor: AccentTheme.current.tint))
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
}

/// The only view that reads the draft while rendering. Explicit inputs, so a hosting controller can own it later.
struct ConversationComposer: View {
    let model: AppModel
    let chatID: String
    @Bindable var state: ComposerState
    @Binding var replyingTo: ChatMessage?
    let editing: ChatMessage?
    let attaching: Bool
    @FocusState private var focused: Bool
    let authorName: (String) -> String
    let onSend: () -> Void
    let onCancelEditing: () -> Void
    let onPickPhoto: () -> Void
    let onPickFile: () -> Void

    private var isGroup: Bool { model.isGroup(chatID) }

    private var placeholder: String {
        if model.isDemo { return "Message" }
        if model.encryptionNeedsReview { return "Sending paused until you review" }
        return "Message"
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                // The same strip carries a reply target or, in edit mode, the message being rewritten.
                if let reply = replyingTo ?? editing {
                    let isEdit = editing != nil
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(isEdit ? "Editing message" : "Replying to \(authorName(reply.senderID))").font(.footnote.weight(.semibold)).foregroundStyle(.tint)
                            Text(reply.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button { if isEdit { onCancelEditing() } else { replyingTo = nil } } label: {
                            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(isEdit ? "Cancel edit" : "Cancel reply").accessibilityIdentifier(isEdit ? "cancelEdit" : "cancelReply")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14).padding(.vertical, 4)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                HStack(alignment: .bottom, spacing: 4) {
                    if model.canSendAttachments, !isGroup {
                        Menu {
                            Button("Photo or Video", systemImage: "photo.on.rectangle", action: onPickPhoto)
                            Button("File", systemImage: "doc", action: onPickFile)
                        } label: {
                            if attaching { ProgressView().frame(width: 44, height: 44) }
                            else { Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                        }
                        .disabled(attaching || model.isSending)
                        .accessibilityLabel("Attach a file").accessibilityIdentifier("attachFile")
                    }
                    TextField(placeholder, text: $state.draft, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.leading, model.canSendAttachments && !isGroup ? 0 : 16).padding(.vertical, 11)
                        .focused($focused)
                        .accessibilityIdentifier("messageComposer")
                    Button(action: onSend) {
                        Image(systemName: editing == nil ? "arrow.up" : "checkmark").font(.system(size: 17, weight: .bold))
                    }
                    .buttonStyle(CircularGlassButtonStyle(diameter: 34))
                    .disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending || !model.canSend(to: chatID) || (editing != nil && state.draft == editing?.body))
                    .accessibilityLabel(editing == nil ? "Send message" : "Save edit").accessibilityIdentifier("sendMessage")
                }
                .frame(minHeight: 44)
                // A capsule at one line; the same radius keeps five lines readable.
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .onChange(of: state.focused) { _, wanted in focused = wanted }
        .onChange(of: focused) { _, isFocused in state.focused = isFocused }
    }
}
