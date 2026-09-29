import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The draft lives outside `ConversationView`'s state so typing only invalidates the composer, never the timeline.
@MainActor @Observable final class ComposerState {
    var draft = ""
    /// Focus requested by the conversation; the composer lives in its own hosting controller, where a parent `@FocusState` cannot reach.
    /// The text keyboard and the attachment panel take turns: asking for one puts the other away.
    var focused = false { didSet { if focused { attachmentsOpen = false } } }
    /// The attachment panel stands in for the keyboard while this is true.
    var attachmentsOpen = false { didSet { if attachmentsOpen { focused = false } } }
    /// Presents the panel through a responder the timeline controller hosts; never observed.
    @ObservationIgnored let attachmentKeyboard = AttachmentKeyboard()
    /// Picked files waiting for Send. Owned by the open conversation, so leaving the chat drops them.
    var tray: [PendingAttachment] = []
    /// True from Send until the last file and the caption are queued; the tray is frozen meanwhile.
    var dispatching = false
    /// Counts Sends, so a rail pick that was still preparing when Send took the tray stays out of the next message.
    @ObservationIgnored var sends = 0
    static let trayLimit = 10

    /// Each file as its own message with no body, then the caption last: Conversations shows a file only when the
    /// body is exactly its link. Stops at the first refusal and reports how many files went and whether the caption did.
    static func dispatch<File>(_ files: [File], caption: String, sendFile: @MainActor (File) async -> Bool,
                               sendCaption: @MainActor (String) async -> Bool) async -> (files: Int, caption: Bool) {
        for (index, file) in files.enumerated() {
            guard await sendFile(file) else { return (index, false) }
        }
        guard !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (files.count, false) }
        return (files.count, await sendCaption(caption))
    }
}

// ponytail: tray items keep the prepared bytes in memory, up to trayLimit × AttachmentTransfer.maximumBytes;
// stage them to disk if large video picks show memory pressure.
struct PendingAttachment: Identifiable {
    let id = UUID()
    let prepared: PreparedAttachment
    let preview: UIImage?
    /// The library photo it came from when picked on the panel's rail, so the rail can show and undo the pick.
    var assetIdentifier: String? = nil
}

struct ConversationView: View {
    @Bindable var model: AppModel
    let chatID: String
    @State private var composerState = ComposerState()
    @State private var showingPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importingFile = false
    @State private var attaching = false
    /// Rail picks prepare one after another so the tray keeps tap order.
    @State private var assetPicks: Task<Void, Never>?
    @State private var query = ""
    @State private var showingSearch = false
    @State private var starredOnly = false
    @State private var retryMessageID: String?
    @State private var unsendMessageID: String?
    @State private var replyingTo: ChatMessage?
    /// The own message whose text is in the composer; sending queues a correction instead of a message.
    @State private var editing: ChatMessage?
    @State private var reviewDismissed = false
    /// The floating banners' height, handed to the timeline as top safe area so its first message clears them.
    @State private var bannerHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var title: String { AppModel.displayName(for: chatID, title: model.chats.first(where: { $0.id == chatID })?.title) }
    private var isGroup: Bool { model.isGroup(chatID) }
    /// Ticks while a relative "Last seen" is shown so "just now" and "today" roll over on their own.
    @State private var lastSeenClock = Date.now
    /// The header subtitle; nil keeps the header to the name alone.
    private var lastSeenLabel: String? {
        guard !isGroup, let state = model.openChatLastSeen else { return nil }
        return LastSeen.label(state, now: lastSeenClock, calendar: .autoupdatingCurrent)
    }
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
        if let unreadable = message.unreadableReason {
            // A notice, not content: no quote, no reactions, no edits. An own send from another device keeps its
            // server-held check (receipts cannot project onto it); an incoming one shows no status.
            return TimelineMessage(id: message.id, body: "", isOutgoing: message.isOutgoing, isStarred: message.isStarred,
                                   sentAt: message.sentAt, status: status(message), author: isGroup && !message.isOutgoing ? message.senderID : nil,
                                   unreadable: unreadable)
        }
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

    /// Search and the starred filter show a slice of history, so nobody is shown typing at its end.
    private var timelineTyping: TimelineTyping? {
        guard !showingSearch, !starredOnly, let names = model.openChatTyping, let first = names.first else { return nil }
        return TimelineTyping(author: isGroup ? names.map { AppModel.displayName(for: $0, title: nil) }.joined(separator: ", ") : nil, colorKey: first,
                              accessibilityLabel: TypingTracker.description(isGroup ? names : [title]))
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

    /// A dashed ring while the outbox works, one ringed check once the server holds it, two rings once the
    /// peer confirmed delivery, filled once read (the glyphs stay the footer's neutral colour). Own messages
    /// from the archive or a carbon have no outbox row: the server already holds them, so they start at the
    /// single check.
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
        let chatID = chatID
        let files = state.tray
        state.attachmentsOpen = false
        state.sends += 1
        state.dispatching = true
        Task {
            defer { state.dispatching = false }
            // A quote on a file would put fallback text before its link, so the reply rides on the caption only;
            // with no caption it stays in the composer.
            let sent = await ComposerState.dispatch(files, caption: text, sendFile: { item in
                guard model.accountID == account, await model.sendAttachment(item.prepared, to: chatID) else { return false }
                state.tray.removeAll { $0.id == item.id }
                return true
            }, sendCaption: { text in
                model.accountID == account ? await model.send(text, to: chatID, replyingTo: reply) : false
            })
            if sent.caption, state.draft == text, model.accountID == account {
                state.draft = ""
                if replyingTo?.id == reply?.id { replyingTo = nil }
            }
        }
    }

    /// Picking never sends: each file is reduced into the tray, in pick order. One that is too large or unreadable
    /// shows why and is left out; the rest still land.
    private func addToTray(_ jobs: [() async throws -> PreparedAttachment]) {
        guard !jobs.isEmpty, !attaching else { return }
        let state = composerState
        let room = ComposerState.trayLimit - state.tray.count
        if jobs.count > room { model.error = "You can attach up to \(ComposerState.trayLimit) files at a time." }
        attaching = true
        Task {
            defer { attaching = false }
            for job in jobs.prefix(max(0, room)) {
                do {
                    let prepared = try await job()
                    state.tray.append(PendingAttachment(prepared: prepared, preview: await AttachmentThumbnails.preview(of: prepared)))
                } catch {
                    model.error = (error as? LocalizedError)?.errorDescription ?? "This file could not be attached."
                }
            }
        }
    }

    /// A tap on the panel's rail. Picks queue behind each other, so a quick second tap lands second.
    private func attach(asset: PHAsset) async {
        let state = composerState
        let limit = model.attachmentLimit
        let previous = assetPicks
        let sends = state.sends
        let pick = Task { @MainActor in
            await previous?.value
            // Send took the tray while this pick waited; it must not land in the next message unasked.
            guard state.sends == sends else { return }
            guard state.tray.count < ComposerState.trayLimit else {
                model.error = "You can attach up to \(ComposerState.trayLimit) files at a time."
                return
            }
            do {
                let prepared = try await AttachmentPreparer.prepare(asset: asset, limit: limit)
                let preview = await AttachmentThumbnails.preview(of: prepared)
                guard state.sends == sends else { return }
                state.tray.append(PendingAttachment(prepared: prepared, preview: preview, assetIdentifier: asset.localIdentifier))
            } catch {
                model.error = (error as? LocalizedError)?.errorDescription ?? "This photo could not be attached."
            }
        }
        assetPicks = pick
        await pick.value
    }

    private func attach(capture: CameraCapture) {
        let limit = model.attachmentLimit
        addToTray([{ try await AttachmentPreparer.prepare(capture: capture, limit: limit) }])
    }

    private func attach(files result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else { return }
        let limit = model.attachmentLimit
        addToTray(urls.map { url in { try await AttachmentPreparer.prepare(fileURL: url, name: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension), limit: limit) } })
    }

    var body: some View {
        // One layer: the timeline runs under the navigation bar and the banners; UIKit insets it by that safe area.
        ZStack {
            ConversationTimeline(messages: timelineMessages, typing: timelineTyping,
                                 loadingEarlier: !showingSearch && !starredOnly && model.isBackfilling(chat: chatID), topBannerHeight: bannerHeight, composer: showingSearch ? nil : AnyView(composer), onToggleStar: { id in Task { await model.toggleStar(id) } }, onRetryMessage: { retryMessageID = $0 }, onReply: { id in
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
            }, onUnsend: { composerState.focused = false; unsendMessageID = $0 }, onOpenEncryption: { model.requestRoute(encryptionRoute) }, onDisplayed: { id in
                // Only the newest received message is marked; XEP-0333 makes a marker cover everything before it.
                // A placeholder carries no wire ID, so the newest readable received message is the one the peer hears
                // about; the newest received message of any kind is where this chat's read pointer goes.
                guard id == model.messages.last(where: { !$0.isOutgoing && $0.unreadableReason == nil })?.id
                        || id == model.messages.last(where: { !$0.isOutgoing })?.id else { return }
                Task { await model.markDisplayed(id) }
            }, onRestoreComposerFocus: { composerState.focused = true }, onReachTop: { Task { await model.loadOlderMessages() } },
            attachmentKeyboard: composerState.attachmentKeyboard)
            // The controller pins the composer to the keyboard itself and insets the messages to match.
            .ignoresSafeArea(.keyboard)
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            .overlay {
                // Only an actual empty chat says so; while a load is pending the timeline stays blank.
                if messages.isEmpty, model.messagesLoadedFor == chatID {
                    ContentUnavailableView(!searchTerm.isEmpty ? "No matching messages" : (starredOnly ? "No starred messages" : "No messages yet"),
                                           systemImage: !searchTerm.isEmpty ? "magnifyingglass" : (starredOnly ? "star" : "bubble.left"))
                }
            }
            // Banners float over the timeline as a bar, so messages scroll under them and blur like under the navigation
            // bar. SwiftUI keeps that inset to itself (the timeline ignores the top safe area), so its height is passed on.
            .safeAreaBar(edge: .top, spacing: 0) {
                banners
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.25), value: bannerState)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bannerHeight = $0 }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        // No toolbar background: a material strip cut messages off flat at its bottom edge. The bar stays transparent
        // and the timeline's soft scroll-edge effect dissolves messages beneath it and the banners, as Signal does on
        // iOS 26; Reduce Transparency turns that effect into the system's opaque bar. The system's adaptive dark flip
        // over a wide sent bubble is kept: pinning the bar's scheme left a black title on the dimmed accent.
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: ChatRoute.details(chatID)) {
                    // Name only: trust lives in Chat Details and the review card, so the header never flickers.
                    HStack(spacing: 9) {
                        ChatAvatar(key: chatID, name: title, image: model.avatars[chatID], isGroup: isGroup, size: 36)
                            .task(id: "\(chatID)|\(model.session.isReady)") { await model.loadAvatar(for: chatID) }
                        if let lastSeenLabel {
                            // Known activity: a smaller name over the subtitle, centred in the same row so the avatar stays put.
                            VStack(alignment: .leading, spacing: 1) {
                                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                Text(lastSeenLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    .contentTransition(.opacity)
                            }
                            .transition(.opacity)
                        } else {
                            Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: lastSeenLabel)
                    .task(id: model.openChatLastSeen) {
                        lastSeenClock = .now
                        guard case .lastSeen = model.openChatLastSeen else { return }
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(30))
                            lastSeenClock = .now
                        }
                    }
                    // Leading toolbar items size to content; give the header a fixed width so the name isn't squeezed out.
                    .frame(width: 236, height: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(lastSeenLabel.map { "\(title), \($0)" } ?? title)
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
        .onChange(of: model.encryptionIncomingReview) { reviewDismissed = false }
        .onChange(of: model.encryptionStatus) { reviewDismissed = false }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItems, maxSelectionCount: max(1, ComposerState.trayLimit - composerState.tray.count),
                      selectionBehavior: .ordered, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { attach(files: $0) }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            let limit = model.attachmentLimit
            addToTray(items.map { item in { try await AttachmentPreparer.prepare(photo: item, limit: limit) } })
        }
        // Files picked for one chat never follow the view to another.
        .onChange(of: [chatID, model.accountID]) {
            composerState.attachmentsOpen = false
            composerState.tray = []
        }
        // The list's search and compose bar goes with the push instead of lingering over the composer after it.
        .toolbarVisibility(.hidden, for: .bottomBar)
        // Before the first frame: a cached page puts the newest messages on screen as the push starts.
        .onAppear { model.prepareChat(chatID) }
        .task(id: [chatID, model.accountID]) { await model.openChat(chatID) }
        .onDisappear { model.closeChat(chatID) }
    }

    /// Hosted inside the timeline controller, outside this view's environment, so the accent travels with it.
    private var composer: some View {
        ConversationComposer(model: model, chatID: chatID, state: composerState, replyingTo: $replyingTo, editing: editing, attaching: attaching,
                             authorName: authorName, onSend: send, onCancelEditing: cancelEditing,
                             onPickPhoto: { showingPhotoPicker = true }, onPickFile: { importingFile = true },
                             onAttachAsset: { await attach(asset: $0) }, onAttachCapture: { attach(capture: $0) })
            .tint(Color(uiColor: AccentTheme.current.tint))
    }

    private var showsReview: Bool { !model.isDemo && (model.encryptionNeedsReview || model.encryptionIncomingReview) && !reviewDismissed }
    /// Which banners are up; a change animates them in or out.
    private var bannerState: [Bool] { [showingSearch, starredOnly, showsReview] }
    /// Banners slide down from under the bar as they fade in; Reduce Motion keeps only the fade.
    private var bannerTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    /// Search, the starred filter and the trust review float on glass over the timeline, below the navigation bar.
    @ViewBuilder private var banners: some View {
        if showingSearch || starredOnly || showsReview {
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    if showingSearch {
                        VStack(spacing: 0) {
                            ConversationSearchBar(query: $query) {
                                showingSearch = false
                                query = ""
                            }
                            .padding(.horizontal, 4)
                            if !searchTerm.isEmpty {
                                Text(messages.isEmpty ? "No results in this conversation" : "\(messages.count) \(messages.count == 1 ? "message" : "messages") found")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16).padding(.bottom, 10)
                            }
                        }
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .transition(bannerTransition)
                    }
                    if starredOnly {
                        HStack {
                            Label("Starred messages", systemImage: "star.fill").font(.caption)
                            Spacer()
                            Button("Show all") { starredOnly = false }
                                .font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .padding(.leading, 16).padding(.trailing, 14)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .transition(bannerTransition)
                    }
                    if showsReview { trustReviewCard.transition(bannerTransition) }
                }
            }
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 8)
            .transition(bannerTransition)
        }
    }

    private var trustReviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(.orange)
                    .frame(width: 36, height: 36).background(.orange.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    if model.encryptionNeedsReview {
                        Text(isGroup ? "Devices need review" : "\(title) added a new device").font(.subheadline.weight(.semibold))
                        Text("Check its fingerprint before sending. Until then, nothing you write here leaves this iPhone.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        // Only reading waits: the messages came from a device in the version this chat does not send with.
                        Text("Messages waiting for review").font(.subheadline.weight(.semibold))
                        Text("They come from a device you haven’t reviewed yet. Check its fingerprint to read them.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
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
    @Environment(\.colorScheme) private var colorScheme
    let authorName: (String) -> String
    let onSend: () -> Void
    let onCancelEditing: () -> Void
    let onPickPhoto: () -> Void
    let onPickFile: () -> Void
    let onAttachAsset: (PHAsset) async -> Void
    let onAttachCapture: (CameraCapture) -> Void
    /// Counts presses of "+", so the haptic answers the finger and not a programmatic close.
    @State private var attachPresses = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isGroup: Bool { model.isGroup(chatID) }

    /// The tray is set aside while an edit rewrites text; attaching then is off.
    private var showsTray: Bool { editing == nil && !state.tray.isEmpty }

    private var placeholder: String {
        if !model.isDemo, model.encryptionNeedsReview { return "Sending paused until you review" }
        return showsTray ? "Add a caption…" : "Message"
    }

    private var canSend: Bool {
        guard !model.isSending, !state.dispatching, model.canSend(to: chatID) else { return false }
        if let editing { return !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.draft != editing.body }
        return showsTray || !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Rail picks in tray order: the order the panel numbers them in.
    private var selectedAssetIDs: [String] { state.tray.compactMap(\.assetIdentifier) }

    private var panelActions: AttachmentPanelActions {
        let state = state
        let model = model
        return AttachmentPanelActions(select: onAttachAsset, deselect: { id in
            guard !state.dispatching else { return }
            state.tray.removeAll { $0.assetIdentifier == id }
        }, capture: onAttachCapture, photos: onPickPhoto, files: onPickFile, refuse: { model.error = $0 },
        dismissed: { state.attachmentsOpen = false }, restore: { if !state.attachmentsOpen { state.attachmentsOpen = true } })
    }

    /// A separate 44pt glass circle left of the field. The glyph turns into an ×; its circle never changes size.
    private var attachButton: some View {
        Button {
            attachPresses += 1
            state.attachmentsOpen.toggle()
        } label: {
            ZStack {
                if attaching, !state.attachmentsOpen { ProgressView() }
                else {
                    Image(systemName: "plus").font(.system(size: 20, weight: .semibold))
                        .rotationEffect(.degrees(state.attachmentsOpen ? 135 : 0))
                        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.3), value: state.attachmentsOpen)
                }
            }
        }
        .buttonStyle(CircularGlassButtonStyle(diameter: 44, tinted: false))
        // Closing always works; opening waits for anything that is still changing the tray or the text.
        .disabled(!state.attachmentsOpen && (editing != nil || state.dispatching || attaching || model.isSending))
        .sensoryFeedback(.impact(weight: .light), trigger: attachPresses)
        .accessibilityLabel(state.attachmentsOpen ? "Close attachments" : "Add attachment")
        .accessibilityHint(state.attachmentsOpen ? "" : "Shows recent photos, the camera and files")
        .accessibilityIdentifier("attachFile")
    }

    var body: some View {
        let showsAttach = !isGroup && model.canSendAttachments
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
                HStack(alignment: .bottom, spacing: 8) {
                    if showsAttach { attachButton }
                    VStack(alignment: .leading, spacing: 0) {
                        if showsTray { AttachmentTray(items: state.tray, frozen: state.dispatching) { id in state.tray.removeAll { $0.id == id } } }
                        HStack(alignment: .bottom, spacing: 4) {
                            TextField(placeholder, text: $state.draft, axis: .vertical)
                                .lineLimit(1...5)
                                .padding(.leading, 16).padding(.vertical, 11)
                                .focused($focused)
                                .accessibilityIdentifier("messageComposer")
                            Button(action: onSend) {
                                Image(systemName: editing == nil ? "arrow.up" : "checkmark").font(.system(size: 17, weight: .bold))
                            }
                            .buttonStyle(CircularGlassButtonStyle(diameter: 34))
                            .disabled(!canSend)
                            .accessibilityLabel(editing == nil ? "Send message" : "Save edit").accessibilityIdentifier("sendMessage")
                        }
                        .frame(minHeight: 44)
                    }
                    // A capsule at one line; the same radius keeps five lines and the tray readable.
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
        }
        // Glass that grew past control size (a tray, a long draft) keeps the light or dark look it had when it grew,
        // and an appearance change does not re-resolve it; only new glass does. The draft lives in `state`, and focus
        // is handed to the new field below.
        .id(colorScheme)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .onChange(of: colorScheme) { if focused { Task { focused = true } } }
        // Opening the panel leaves the field alone: the panel's responder takes over from it in one keyboard animation.
        .onChange(of: state.focused) { _, wanted in if wanted || !state.attachmentsOpen { focused = wanted } }
        .onChange(of: state.attachmentsOpen) { _, open in
            if open { state.attachmentKeyboard.open(actions: panelActions, selection: selectedAssetIDs, trayCount: state.tray.count) }
            // A close on the way to the text field is left to the field, which swaps the keyboards in one animation.
            else if !state.focused { state.attachmentKeyboard.close() }
        }
        .onChange(of: selectedAssetIDs + [String(state.tray.count)]) {
            state.attachmentKeyboard.update(selection: selectedAssetIDs, trayCount: state.tray.count)
        }
        .onChange(of: showsAttach) { _, shown in if !shown { state.attachmentsOpen = false } }
        .onChange(of: state.draft) { _, draft in model.draftChanged(draft, in: chatID) }
        .onChange(of: focused) { _, isFocused in state.focused = isFocused }
    }
}

/// Picked files above the caption field, scrolling sideways, each with its own remove button.
struct AttachmentTray: View {
    let items: [PendingAttachment]
    /// While Send works through the tray, removing an item could no longer stop it going out.
    let frozen: Bool
    let onRemove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if items.count > 1 {
                Text("\(items.count) attachments").font(.caption).foregroundStyle(.secondary).padding(.leading, 14)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in tile(item, index: index) }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.top, 10)
        .accessibilityIdentifier("attachmentTray")
    }

    private func tile(_ item: PendingAttachment, index: Int) -> some View {
        let attachment = item.prepared
        let kind = attachment.mediaType.hasPrefix("image/") ? "Photo" : attachment.mediaType.hasPrefix("video/") ? "Video" : attachment.name
        // Photos all share one name, so the position tells VoiceOver users which one a control means.
        let label = items.count > 1 ? "\(kind), \(index + 1) of \(items.count)" : kind
        return Group {
            if let preview = item.preview {
                // Fill a fixed square rather than framing the image, so its accessibility frame is the tile's.
                Color.clear.frame(width: 64, height: 64)
                    .overlay { Image(uiImage: preview).resizable().scaledToFill() }
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                        if attachment.mediaType.hasPrefix("video/") {
                            Image(systemName: "video.fill").font(.caption2).foregroundStyle(.white).shadow(radius: 2).padding(6)
                        }
                    }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill").font(.title3).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.name).font(.footnote.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 10).padding(.trailing, 30)
                .frame(width: 168, height: 64, alignment: .leading)
                .background(Color(uiColor: .tertiarySystemFill))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .overlay(alignment: .topTrailing) {
            Button { onRemove(item.id) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 20))
                    .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.55))
                    .padding(4)
                    .frame(width: 44, height: 44, alignment: .topTrailing).contentShape(Rectangle())
            }
            .disabled(frozen)
            .accessibilityLabel("Remove \(label)").accessibilityIdentifier("removeAttachment")
        }
    }
}
