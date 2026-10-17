import AppKit
import MessageStore
import QuickLook
import SwiftUI

/// The open chat. The timeline (`MacTimeline`) opens at the newest message in its first frame, follows the bottom while
/// the reader is there, keeps the reader's row through older pages and resizes, and pages in older history near the top;
/// the composer (`MacComposer`) sits below it. A bubble's right-click menu, its hover toolbar and its VoiceOver actions
/// perform the shared menu's actions (`MacMessageHandlers`), with the iPhone's retry and unsend dialogs. Links in
/// bubbles open through `LinkOpening`, and preview cards show as on the iPhone. Photos and videos show as framed stills
/// and files as a line; a click opens one in Quick Look, or asks for its download when it is not on this Mac yet.
/// Search and the starred filter list a slice of the chat under bars at the top (`MacConversationFindBars`); search
/// hides the composer, as on the iPhone, and a reply or an edit in it waits there until search closes.
struct MacConversationView: View {
    @Bindable var model: AppModel
    let chatID: String
    /// The timeline's rows and scroll position; made when the view first appears.
    @State private var timeline: MacTimelineController?
    /// Rows laid out in the viewport now (LazyVStack's prefetch may add a row just past the edge), so the start of
    /// reading marks the newest one the user can see. Not observed: rows scrolling in and out must not rebuild the
    /// whole timeline, and only the `readingStarts` change reads it.
    @State private var visibleRows = VisibleRows()
    /// A message's Report, waiting for its confirmation.
    @State private var blockRequest: BlockRequest?
    @State private var retryMessageID: String?
    @State private var unsendMessageID: String?
    /// A phone link was clicked: Call, Send Message or Copy.
    @State private var phoneLink: PhoneLink?
    /// A link could not be opened, so it was copied; the alert says why.
    @State private var copiedReason: String?
    /// An `xmpp:…?join` link to a group this account is not in: the join flow, with its address filled in.
    @State private var joiningGroup: String?
    /// The file shown in Quick Look.
    @State private var quickLook: URL?
    /// The composer's reply or edit, set by message actions.
    @State private var composerIntent = MacComposerIntent()
    /// Files are being dragged over the chat and it would take them.
    @State private var dropTargeted = false
    /// Bumped by Find; the find bar's field takes focus on each change.
    @State private var findRequests = 0
    /// The bubbles' `openURL`, one for the view's life: a new action on each update of this view would change every
    /// row's environment and run all their bodies again. What it performs is set while the view is shown: it holds this
    /// view, whose state holds it.
    @State private var linkAction = MacLinkAction()
    #if DEBUG
    @State private var debugToken = UUID()
    #endif

    private var title: String { AppModel.displayName(for: chatID, title: model.chats.first { $0.id == chatID }?.title) }
    private var presenter: ConversationPresenter { ConversationPresenter(source: model, chatID: chatID, title: title) }
    private var isGroup: Bool { model.isGroup(chatID) }
    /// Where Encryption details goes: the inspector's page for this chat's devices, or a group's details.
    private var encryptionRoute: ChatRoute { isGroup ? .groupDetails(chatID) : .encryption(chatID) }

    private var debugDropHighlight: Bool {
        #if DEBUG
        MacDebugHooks.tour.dropHighlight
        #else
        false
        #endif
    }

    /// The failed message the retry dialog is for was a file failed when encryption was set up again: its key is gone,
    /// so the store refuses a retry and the dialog only explains.
    private var retryIsImpossible: Bool {
        retryMessageID.flatMap { id in model.messages.first { $0.id == id }?.rejection } == MessageStore.encryptionResetRejection
    }

    var body: some View {
        let presenter = presenter
        Group {
            // Built only once this chat's first page is loaded, so the scroll view's initial offset is the tail of
            // real content, not of an empty stack.
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
                                      title: AppModel.displayName(for: chatID, title: model.chats.first { $0.id == chatID }?.title))
            }
            // Esc in the timeline, or in a bubble's text: closes the find bar, as Esc in its field does, or else the
            // starred filter; with neither open, keyboard focus goes to the composer.
            timeline.onEscape = { [weak timeline, composerIntent] in
                guard let timeline else { return }
                if timeline.isFiltered { timeline.closeFilter() } else { composerIntent.focusComposer() }
            }
            self.timeline = timeline
        }
        .onDisappear {
            linkAction.perform = { _ in }
            MacComposer.endEditing(composerIntent, account: model.accountID, chatID: chatID)
        }
        // Its own view, so only it reads the messages: this view's body never reruns for a new message.
        .overlay { if let timeline { MacEmptyNotice(timeline: timeline, presenter: presenter) } }
        // The Message menu's targets; their own view too, as they change with the messages.
        .background {
            if let timeline {
                MacMessageCommandsSource(model: model, chatID: chatID, timeline: timeline, presenter: presenter, handlers: messageHandlers)
            }
        }
        .safeAreaInset(edge: .top) {
            // Sending, or reading, waits on a device nobody decided on (the iPhone shows a card in the chat); the
            // banner's review sheet decides each waiting device by its fingerprint.
            MacDeviceReviewBanner(model: model, chatID: chatID, title: title)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // A blocked chat says so and offers Unblock in place of the composer. The timeline's frame ends above it,
            // so the timeline follows the composer's height as it does the window's (`MacTimelineController.resized`).
            if model.isBlocked(chatID) {
                BlockedChatBar(model: model, chatID: chatID, name: title)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            } else if timeline?.searching != true {
                MacComposer(model: model, chatID: chatID, intent: composerIntent, focusTimeline: timeline.map { timeline in { timeline.requestKeyboardFocus() } })
            }
        }
        // Files dropped anywhere in the chat but on the find bars join the composer's tray; a drop during search closes
        // it, as a reply does.
        .onDrop(of: MacAttachmentDrop.types, delegate: MacAttachmentDrop(model: model, chatID: chatID, intent: composerIntent, targeted: $dropTargeted))
        .overlay { if dropTargeted || debugDropHighlight { MacAttachmentDropHighlight() } }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let timeline { MacConversationFindBars(timeline: timeline, focusRequests: findRequests) }
        }
        .focusedSceneValue(\.conversationFind, findCommands)
        #if DEBUG
        .onAppear { if MacUnobtrusive.isOn { let view = self; MacDebugHooks.tour.conversationFind.append((debugToken, { view.findCommands })) } }
        .onDisappear { MacDebugHooks.tour.conversationFind.removeAll { $0.token == debugToken } }
        #endif
        .onChange(of: model.conversationIntent, initial: true) { _, intent in
            // The details' Search and Starred tiles leave what they want opened here, as on the iPhone. Applied in a turn
            // of its own: the timeline scrolls as the filter changes, which it may not do inside a view update.
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
        // A tour step performing a message action as its menu item would (`MacDebugHooks`).
        .onChange(of: MacDebugHooks.tour.messageRequest) { _, request in
            guard let request, let message = presenter.timelineMessages.first(where: { $0.id == request.messageID }) else { return }
            // No Copy: a run must leave the Mac's pasteboard alone.
            let kinds: [String: MessageAction.Kind] = ["reply": .reply, "edit": .edit, "star": .star, "retry": .retry, "unsend": .unsend,
                                                       "encryption": .encryptionDetails, "report": .report]
            if request.verb == "react" { messageHandlers.react(request.argument, message) }
            if let kind = kinds[request.verb] { perform(kind, on: message, link: nil) }
            MacDebugHooks.log("composer intent: replying to \(composerIntent.replyingTo?.id ?? "none"), editing \(composerIntent.editing?.id ?? "none")")
        }
        #endif
        // Closed by the root when the selection moves on or the window closes: SwiftUI may build the detail column more
        // than once for one selection, and a late disappearance would close the chat the new view just opened.
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

    /// Performs a link from a bubble or a card. Where it goes is `LinkOpening`'s decision, shared with the iPhone; web
    /// pages always open in the default browser.
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

    /// What a bubble's menu, toolbar and VoiceOver actions do here; the iPhone's `ConversationView` does the same.
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
        // The menu's first link item: Call for a phone number, what a click does otherwise.
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

    /// A click on a photo, video or file: Quick Look once it is here, else its download (a file waiting for a click, or
    /// a failed one).
    private func openAttachment(of message: TimelineMessage) {
        guard let attachment = message.attachment, !message.showsPlaceholder else { return }
        if let url = attachment.localURL { quickLook = url } else if attachment.download.canRequest { model.downloadAttachment(message.id) }
    }

    /// What Find in Conversation and View > Starred Messages act on.
    private var findCommands: MacConversationFindCommands? {
        timeline.map { timeline in
            MacConversationFindCommands(find: find, starredOnly: timeline.starredOnly, setStarredOnly: { timeline.setStarredOnly($0) })
        }
    }

    /// Opens search, or moves keyboard focus back into its field when it is open.
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
        let contactName = isGroup ? nil : title
        return MacTimeline(controller: timeline, contactName: contactName) { row in
            MacTimelineRow(row: row, isGroup: timeline.isGroup, contactName: contactName, handlers: messageHandlers, openAttachment: { openAttachment(of: row.message) })
                .equatable()
                .modifier(MacFindResult(timeline: timeline, id: row.message.id))
                .onAppear {
                    visibleRows.ids.insert(row.message.id)
                    markIfReading(row.message.id, presenter: presenter)
                    // Fetched on display, never at insert, under the model's policy (setting, contact, demo).
                    if row.message.wantsLinkPreview { model.linkPreviewDisplayed(row.message.id) }
                    // As on the iPhone: a file not on disk yet is fetched on sight when its chat allows it.
                    if row.message.attachment?.localURL == nil, row.message.attachment != nil, !row.message.showsPlaceholder {
                        model.attachmentDisplayed(row.message.id)
                    }
                }
                .onDisappear { visibleRows.ids.remove(row.message.id) }
        }
        // The user started reading this chat (the app active, its window key and visible, the screen unlocked, the user
        // not idle): what was already on screen counts as seen now (critique G3).
        .onChange(of: model.readingStarts) { _, _ in
            guard let shown = timeline.rows.last(where: { visibleRows.ids.contains($0.message.id) && presenter.marksDisplayed($0.message.id) }) else { return }
            markIfReading(shown.message.id, presenter: presenter)
        }
    }

    /// The newest received message marks the chat read when it shows. The model marks it only while the user reads
    /// this chat (`LifecycleSignals.readsOpenChat`, from `MacLifecycle`), so a row appearing in a window behind other
    /// apps marks nothing; the start of reading marks it then.
    private func markIfReading(_ id: String, presenter: ConversationPresenter) {
        guard presenter.marksDisplayed(id) else { return }
        Task { await model.markDisplayed(id) }
    }
}

/// What an empty timeline says (`ConversationPresenter.emptyNotice`) under the open filters; a filter that has found
/// nothing yet waits for the earlier messages it is loading.
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

/// The header's line under the chat's name, by the iPhone's rules: who is typing, else the contact's last seen
/// (`LastSeen.headerLabel`: a 1:1 chat with known activity, never a blocked one), else nothing. The trust state stays
/// in the details and the review banner, as on the iPhone, so the line never flickers between the two. Its own view:
/// typing and presence change often and must not rerun the conversation's body.
private struct MacConversationSubtitle: View {
    let model: AppModel
    let chatID: String
    /// Ticks while a relative "Last seen" shows, so "just now" and "today" roll over on their own.
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

/// Publishes the Message menu's commands for the open chat, from the rows the timeline already built: the message with
/// the timeline's keyboard focus, else the last messages. Under search or the starred filter those rows are a slice,
/// so the last messages come from the whole chat: "last message" stays the chat's.
private struct MacMessageCommandsSource: View {
    let model: AppModel
    let chatID: String
    let timeline: MacTimelineController
    let presenter: ConversationPresenter
    let handlers: MacMessageHandlers
    #if DEBUG
    @State private var debugToken = UUID()
    #endif

    private var commands: MacMessageCommands {
        // `items` is the observed list the rows go into, so a change of rows reruns whatever reads this.
        _ = timeline.items
        // The message with the timeline's keyboard focus, while the timeline has it. The reader may have scrolled it
        // away since, so a command brings it back into view, ringed, before acting on it.
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
            #if DEBUG
            .onAppear { if MacUnobtrusive.isOn { let source = self; MacDebugHooks.tour.messageCommands.append((debugToken, { source.commands })) } }
            // SwiftUI may build this view twice and take the copies down in any order; the newest one left counts.
            .onDisappear { MacDebugHooks.tour.messageCommands.removeAll { $0.token == debugToken } }
            #endif
    }
}

/// A clicked phone link's choices.
private struct PhoneLink {
    let number: String
    let call: URL
    let message: URL
}

/// A plain reference holder, so changing it never invalidates the view that owns it.
@MainActor private final class VisibleRows {
    var ids: Set<String> = []
}

/// An `openURL` action that keeps its identity while what it does is set again.
@MainActor private final class MacLinkAction {
    var perform: (URL) -> Void = { _ in }

    private(set) lazy var action = OpenURLAction { [weak self] url in
        MainActor.assumeIsolated { self?.perform(url) }
        return .handled
    }
}
