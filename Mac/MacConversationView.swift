import AppKit
import MessageStore
import QuickLook
import SwiftUI

// Search hides the composer, as on the iPhone; a reply or an edit started meanwhile waits there until search closes.
struct MacConversationView: View {
    @Bindable var model: AppModel
    let chatID: String
    @State private var timeline: MacTimelineController?
    @State private var blockRequest: BlockRequest?
    @State private var retryMessageID: String?
    @State private var unsendMessageID: String?
    @State private var phoneLink: PhoneLink?
    @State private var copiedReason: String?
    @State private var joiningGroup: String?
    @State private var quickLook: URL?
    @State private var composerIntent = MacComposerIntent()
    @State private var dropTargeted = false
    @State private var findRequests = 0
    // One action for the view's life: a new one on each update would change every row's environment and rerun their
    // bodies. It holds this view, whose state holds it.
    @State private var linkAction = MacLinkAction()

    private var title: String { model.chatName(for: chatID) }
    private var presenter: ConversationPresenter { ConversationPresenter(source: model, chatID: chatID, title: title) }
    private var isGroup: Bool { model.isGroup(chatID) }
    private var encryptionRoute: ChatRoute { isGroup ? .groupDetails(chatID) : .encryption(chatID) }

    private var debugDropHighlight: Bool {
        #if DEBUG
        MacDebugHooks.tour.dropHighlight
        #else
        false
        #endif
    }

    // A file that failed when encryption was set up again has lost its key, so the store refuses a retry.
    private var retryIsImpossible: Bool {
        retryMessageID.flatMap { id in model.messages.first { $0.id == id }?.rejection } == MessageStore.encryptionResetRejection
    }

    var body: some View {
        let presenter = presenter
        Group {
            // Built once the first page has loaded, so the scroll view's initial offset is the tail of real content.
            if let timeline, timeline.isLoaded {
                self.timeline(timeline, presenter: presenter)
            } else {
                Color.clear
            }
        }
        .onAppear {
            linkAction.perform = { open($0) }
            guard timeline == nil else { return }
            let model = model, chatID = chatID
            let timeline = MacTimelineController(model: model, chatID: chatID) {
                ConversationPresenter(source: model, chatID: chatID,
                                      title: model.chatName(for: chatID))
            }
            timeline.onEscape = { [weak timeline, composerIntent] in
                guard let timeline else { return }
                if timeline.isFiltered { timeline.closeFilter() } else { composerIntent.focusComposer() }
            }
            timeline.onTab = { [weak timeline, composerIntent] in
                guard let timeline else { return }
                if timeline.searching || model.isBlocked(chatID) {
                    timeline.table.view.window?.selectNextKeyView(timeline.table.table)
                } else {
                    composerIntent.focusComposer()
                }
            }
            timeline.onShown = { message in
                markIfReading(message.id)
                // Fetched on display, never at insert, under the model's policy (setting, contact, demo).
                if message.wantsLinkPreview { model.linkPreviewDisplayed(message.id) }
                // As on the iPhone: a file not on disk yet is fetched on sight when its chat allows it.
                if message.attachment?.localURL == nil, message.attachment != nil, !message.showsPlaceholder {
                    model.attachmentDisplayed(message.id)
                }
            }
            self.timeline = timeline
        }
        .onDisappear {
            linkAction.perform = { _ in }
            MacComposer.endEditing(composerIntent, account: model.accountID, chatID: chatID)
        }
        // Its own view, so only it reads the messages: this view's body never reruns for a new message.
        .overlay { if let timeline { MacEmptyNotice(timeline: timeline, presenter: presenter) } }
        // The menu bar's targets; their own views too, as they change with the messages and the filters.
        .background {
            if let timeline {
                MacMessageCommandsSource(model: model, chatID: chatID, timeline: timeline, presenter: presenter, handlers: messageHandlers)
                MacFindCommandsSource(timeline: timeline, find: find)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // The banner's review sheet decides each device that sending or reading waits on, by its fingerprint.
            VStack(spacing: 0) {
                MacDeviceReviewBanner(model: model, chatID: chatID, title: title)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { timeline?.table.setBars(banner: $0) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if model.isBlocked(chatID) {
                    BlockedChatBar(model: model, chatID: chatID, name: title)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                } else if timeline?.searching != true {
                    MacComposer(model: model, chatID: chatID, intent: composerIntent, focusTimeline: timeline.map { timeline in { timeline.requestKeyboardFocus() } })
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { timeline?.table.setBars(bottom: $0) }
        }
        // A drop during search closes it, as a reply does.
        .onDrop(of: MacAttachmentDrop.types, delegate: MacAttachmentDrop(model: model, chatID: chatID, intent: composerIntent, targeted: $dropTargeted))
        .overlay { if dropTargeted || debugDropHighlight { MacAttachmentDropHighlight() } }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let timeline { MacConversationFindBars(timeline: timeline, focusRequests: findRequests) }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { timeline?.table.setBars(find: $0) }
        }
        .onChange(of: model.conversationIntent, initial: true) { _, intent in
            // Applied in a turn of its own: the timeline scrolls as the filter changes, which it may not do inside a
            // view update.
            switch intent {
            case .search(let id) where id == chatID:
                model.conversationIntent = nil
                DispatchQueue.main.async { find() }
            case .starred(let id) where id == chatID:
                model.conversationIntent = nil
                DispatchQueue.main.async { timeline?.setStarredOnly(true) }
            default: break
            }
        }
        // A reply or an edit needs the composer, which search hides; as on the iPhone, it closes search.
        .onChange(of: composerIntent.focusRequests) { _, _ in timeline?.setSearching(false) }
        .blockConfirmation(model: model, request: $blockRequest)
        .confirmationDialog(retryIsImpossible ? "This file can’t be sent" : "Send this message again?", isPresented: Binding(
            get: { retryMessageID != nil }, set: { if !$0 { retryMessageID = nil } }
        ), titleVisibility: .visible, presenting: retryMessageID) { id in
            if retryIsImpossible {
                Button("OK", role: .cancel) { retryMessageID = nil }
            } else {
                Button("Send again") {
                    Task { await model.retryMessage(id) }
                    retryMessageID = nil
                }
                Button("Cancel", role: .cancel) { retryMessageID = nil }
            }
        } message: { id in
            if retryIsImpossible {
                Text(RejectionCopy.reason(MessageStore.encryptionResetRejection, isGroup: isGroup))
            } else if let rejection = model.messages.first(where: { $0.id == id })?.rejection {
                Text("It wasn't delivered. \(RejectionCopy.reason(rejection, isGroup: isGroup)) Sending again only helps once that has changed.")
            } else {
                Text("The recipient may already have it. Sending again could create a duplicate.")
            }
        }
        .confirmationDialog("Unsend this message?", isPresented: Binding(
            get: { unsendMessageID != nil }, set: { if !$0 { unsendMessageID = nil } }
        ), titleVisibility: .visible, presenting: unsendMessageID) { id in
            Button("Unsend", role: .destructive) {
                Task { await model.unsend(messageID: id) }
                if composerIntent.editing?.id == id { composerIntent.cancelEditing() }
                unsendMessageID = nil
            }
            Button("Cancel", role: .cancel) { unsendMessageID = nil }
        } message: { _ in
            Text("It disappears here. \(title) may still see it if their app doesn't support unsending.")
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(title)
        .background { MacConversationSubtitle(model: model, chatID: chatID) }
        .quickLookPreview($quickLook)
        #if DEBUG
        .onChange(of: MacDebugHooks.tour.messageRequest) { _, request in
            guard let request, let message = presenter.timelineMessages.first(where: { $0.id == request.messageID }) else { return }
            // No Copy: a run must leave the Mac's pasteboard alone.
            let kinds: [String: MessageAction.Kind] = ["reply": .reply, "edit": .edit, "star": .star, "retry": .retry, "unsend": .unsend,
                                                       "encryption": .encryptionDetails, "report": .report]
            if request.verb == "react" { messageHandlers.react(request.argument, message) }
            if request.verb == "select-text" || request.verb == "pick-emoji" { timeline?.table.debugRequest(request.verb, messageID: message.id) }
            if let kind = kinds[request.verb] { perform(kind, on: message, link: nil) }
            MacDebugHooks.log("composer intent: replying to \(composerIntent.replyingTo?.id ?? "none"), editing \(composerIntent.editing?.id ?? "none")")
        }
        .onChange(of: MacDebugHooks.tour.hoveredMessage) { _, _ in timeline?.table.debugHoverChanged() }
        #endif
        // Closed by the window when the selection moves on or the window closes: SwiftUI may build the content pane
        // more than once for one selection, and a late disappearance would close the chat the new view just opened.
        .task(id: [chatID, model.accountID]) { await model.openChat(chatID) }
        .environment(\.openURL, linkAction.action)
        .confirmationDialog(phoneLink?.number ?? "", isPresented: Binding(get: { phoneLink != nil }, set: { if !$0 { phoneLink = nil } }),
                            titleVisibility: .visible, presenting: phoneLink) { link in
            Button("Call") { NSWorkspace.shared.open(link.call) }
            Button("Send message") { NSWorkspace.shared.open(link.message) }
            Button("Copy") { copy(link.number) }
        }
        .alert("Copied", isPresented: Binding(get: { copiedReason != nil }, set: { if !$0 { copiedReason = nil } }), presenting: copiedReason) { _ in
            Button("OK") {}
        } message: { Text($0) }
        .sheet(isPresented: Binding(get: { joiningGroup != nil }, set: { if !$0 { joiningGroup = nil } })) {
            NavigationStack {
                GroupJoinView(model: model, room: joiningGroup ?? "") { room in
                    joiningGroup = nil
                    model.requestRoute(.chat(room))
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { joiningGroup = nil } } }
            }
            .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 420)
            .themedRoot()
        }
    }

    private func open(_ url: URL) {
        switch LinkOpening.destination(for: url, inAppBrowser: false) {
        case .web(let page, _), .map(let page):
            NSWorkspace.shared.open(page)
        case .phone(let number, let call, let message):
            phoneLink = PhoneLink(number: number, call: call, message: message)
        case .mail(let mail, let address):
            if !NSWorkspace.shared.open(mail) { copied(address, because: "No mail app is set up on this Mac, so the address was copied.") }
        case .chat(let address):
            guard address != chatID else { return }
            if model.isGroup(address) { model.requestRoute(.chat(address)); return }
            Task { if let chat = await model.createChat(address) { model.requestRoute(.chat(chat)) } }
        case .group(let room):
            if !model.isGroup(room) { joiningGroup = room } else if room != chatID { model.requestRoute(.chat(room)) }
        case .unsupported:
            copied(LinkOpening.copyText(for: url), because: "This link can’t be opened here, so it was copied.")
        }
    }

    private var messageHandlers: MacMessageHandlers {
        MacMessageHandlers(perform: { kind, message, link in perform(kind, on: message, link: link) },
                           react: { emoji, message in Task { await model.toggleReaction(emoji, messageID: message.id) } })
    }

    private func perform(_ kind: MessageAction.Kind, on message: TimelineMessage, link: URL?) {
        switch kind {
        case .reply:
            guard let stored = model.messages.first(where: { $0.id == message.id }) else { return }
            composerIntent.reply(to: stored)
        case .edit:
            guard let stored = model.messages.first(where: { $0.id == message.id }) else { return }
            composerIntent.edit(stored)
        case .copy: copy(message.body)
        case .star: Task { await model.toggleStar(message.id) }
        case .retry: retryMessageID = message.id
        case .unsend: unsendMessageID = message.id
        case .encryptionDetails: model.requestRoute(encryptionRoute)
        case .report: blockRequest = BlockRequest(kind: .report, chatID: chatID, name: title, messageID: message.id)
        case .openLink:
            guard let link else { return }
            if case .phone(_, let call, _) = LinkOpening.destination(for: link, inAppBrowser: false) { NSWorkspace.shared.open(call) } else { open(link) }
        case .messageNumber:
            guard let link, case .phone(_, _, let message) = LinkOpening.destination(for: link, inAppBrowser: false) else { return }
            NSWorkspace.shared.open(message)
        case .copyLink: if let link { copy(LinkOpening.copyText(for: link)) }
        // The row selects its own text; the menus share a link through the system's share menu.
        case .selectText, .shareLink: break
        }
    }

    private func openAttachment(of message: TimelineMessage) {
        guard let attachment = message.attachment, !message.showsPlaceholder else { return }
        if let url = attachment.localURL { quickLook = url } else if attachment.download.canRequest { model.downloadAttachment(message.id) }
    }

    private func find() {
        timeline?.setSearching(true)
        findRequests += 1
    }

    private func copied(_ text: String, because reason: String) {
        copy(text)
        copiedReason = reason
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func timeline(_ timeline: MacTimelineController, presenter: ConversationPresenter) -> some View {
        MacTimeline(controller: timeline, contactName: isGroup ? nil : title, handlers: messageHandlers,
                    openAttachment: { openAttachment(of: $0) }, openLink: { linkAction.perform($0) })
        // Reading started (app active, window key and visible, screen unlocked, user not idle): what was already on
        // screen counts as seen now.
        .onChange(of: model.readingStarts) { _, _ in
            let shownIDs = timeline.table.visibleMessageIDs
            guard let shown = timeline.rows.last(where: { shownIDs.contains($0.message.id) && presenter.marksDisplayed($0.message.id) }) else { return }
            markIfReading(shown.message.id)
        }
    }

    // The model marks only while the user reads this chat (`LifecycleSignals.readsOpenChat`), so a row appearing in a
    // window behind other apps marks nothing until reading starts.
    private func markIfReading(_ id: String) {
        guard presenter.marksDisplayed(id) else { return }
        Task { await model.markDisplayed(id) }
    }
}

// A filter that has found nothing yet waits for the earlier messages it is loading.
private struct MacEmptyNotice: View {
    let timeline: MacTimelineController
    let presenter: ConversationPresenter

    var body: some View {
        if let notice = timeline.filtered(presenter).emptyNotice {
            if timeline.isFiltered, timeline.loadingAll {
                ProgressView().controlSize(.small)
            } else {
                ContentUnavailableView(notice.title, systemImage: notice.systemImage)
            }
        }
    }
}

// The trust state stays in the details and the review banner, so the line never flickers between the two. Its own
// view: typing and presence change often and must not rerun the conversation's body.
private struct MacConversationSubtitle: View {
    let model: AppModel
    let chatID: String
    // Ticks so a relative "Last seen" rolls over on its own.
    @State private var clock = Date.now

    private var subtitle: String {
        let isGroup = model.isGroup(chatID), isBlocked = model.isBlocked(chatID)
        if !isBlocked, let typing = model.typing[chatID], !typing.isEmpty { return TypingTracker.description(typing, isGroup: isGroup) }
        return LastSeen.headerLabel(model.openChatLastSeen, isGroup: isGroup, isBlocked: isBlocked, now: clock, calendar: .autoupdatingCurrent) ?? ""
    }

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .navigationSubtitle(subtitle)
            .task(id: model.openChatLastSeen) {
                clock = .now
                guard case .lastSeen = model.openChatLastSeen else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    clock = .now
                }
            }
    }
}

// Under search or the starred filter the rows are a slice, so "last message" comes from the whole chat.
private struct MacMessageCommandsSource: View {
    let model: AppModel
    let chatID: String
    let timeline: MacTimelineController
    let presenter: ConversationPresenter
    let handlers: MacMessageHandlers
    @State private var menuToken = UUID()

    private var commands: MacMessageCommands {
        // `items` is the observed list the rows go into, so a change of rows reruns whatever reads this.
        _ = timeline.items
        // The reader may have scrolled the focused message away, so a command brings it back into view before acting.
        if timeline.hasKeyboardFocus, let id = timeline.focusedID, let focused = timeline.rows.first(where: { $0.message.id == id })?.message {
            let handlers = handlers, timeline = timeline
            let revealing = MacMessageHandlers(perform: { kind, message, link in
                timeline.reveal(message.id)
                handlers.perform(kind, message, link)
            }, react: { emoji, message in
                timeline.reveal(message.id)
                handlers.react(emoji, message)
            })
            return MacMessageCommands(targets: LastMessageTargets(focused: focused), isFocused: true, isBlocked: model.isBlocked(chatID), handlers: revealing)
        }
        let messages = timeline.isFiltered ? presenter.timelineMessages : timeline.rows.map(\.message)
        return MacMessageCommands(targets: LastMessageTargets(messages: messages), isFocused: false, isBlocked: model.isBlocked(chatID), handlers: handlers)
    }

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .focusedSceneValue(\.macMessageCommands, commands)
            .onAppear { let source = self; MacMenuTargets.shared.messageCommands.append((menuToken, { source.commands })) }
            .onDisappear { MacMenuTargets.shared.messageCommands.removeAll { $0.token == menuToken } }
    }
}

// Made with the timeline, so the menu bar sees the starred filter change.
private struct MacFindCommandsSource: View {
    let timeline: MacTimelineController
    let find: () -> Void
    @State private var menuToken = UUID()

    private var commands: MacConversationFindCommands {
        let timeline = timeline
        return MacConversationFindCommands(find: find, starredOnly: timeline.starredOnly, setStarredOnly: { timeline.setStarredOnly($0) })
    }

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .focusedSceneValue(\.conversationFind, commands)
            .onAppear { let source = self; MacMenuTargets.shared.conversationFind.append((menuToken, { source.commands })) }
            .onDisappear { MacMenuTargets.shared.conversationFind.removeAll { $0.token == menuToken } }
    }
}

private struct PhoneLink {
    let number: String
    let call: URL
    let message: URL
}

@MainActor private final class MacLinkAction {
    var perform: (URL) -> Void = { _ in }

    private(set) lazy var action = OpenURLAction { [weak self] url in
        MainActor.assumeIsolated { self?.perform(url) }
        return .handled
    }
}
